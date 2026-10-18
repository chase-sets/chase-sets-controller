[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$guard = Join-Path $PSScriptRoot 'invoke-heavy-verifier.ps1'
$preload = Join-Path $PSScriptRoot 'heavy-admission-preload.cjs'
function Assert-True($Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

$root = Join-Path ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) ('diagnostic-admission-' + [guid]::NewGuid().ToString('N'))
$container = Join-Path $root 'container'
$worktree = Join-Path $container 'lane'
$runtime = Join-Path $container '.orchestrator'
$artifactRoot = Join-Path $worktree '.orchestrator\artifacts'
$lockRoot = Join-Path $runtime 'verify-lock.d'
New-Item -ItemType Directory -Path $worktree, $runtime, $artifactRoot, (Join-Path $worktree 'artifacts') -Force | Out-Null

function Invoke-FixtureGit([string[]]$Arguments) {
  $output = @(& git -C $worktree @Arguments 2>&1)
  if ($LASTEXITCODE -ne 0) { throw "fixture git failed: $($output -join "`n")" }
  return ($output -join "`n").Trim()
}

function Invoke-Child([string[]]$Arguments, [hashtable]$Environment = @{}) {
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = Join-Path $PSHOME 'pwsh.exe'
  $start.UseShellExecute = $false
  $start.CreateNoWindow = $true
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  foreach ($argument in $Arguments) { [void]$start.ArgumentList.Add([string]$argument) }
  foreach ($entry in $Environment.GetEnumerator()) { $start.Environment[$entry.Key] = [string]$entry.Value }
  $process = [Diagnostics.Process]::Start($start)
  $stdout = $process.StandardOutput.ReadToEndAsync()
  $stderr = $process.StandardError.ReadToEndAsync()
  $process.WaitForExit()
  return [pscustomobject]@{ Code = $process.ExitCode; Stdout = $stdout.GetAwaiter().GetResult(); Stderr = $stderr.GetAwaiter().GetResult() }
}

try {
  Set-Content -LiteralPath (Join-Path $worktree '.gitignore') -Value '.orchestrator/'
  Set-Content -LiteralPath (Join-Path $worktree 'seed.txt') -Value 'seed'
  Invoke-FixtureGit @('init', '--initial-branch=codex/test') | Out-Null
  Invoke-FixtureGit @('config', 'user.name', 'Diagnostic Admission Test') | Out-Null
  Invoke-FixtureGit @('config', 'user.email', 'diagnostic-admission@example.invalid') | Out-Null
  Invoke-FixtureGit @('add', '--', '.') | Out-Null
  Invoke-FixtureGit @('commit', '-m', 'fixture') | Out-Null
  $head = Invoke-FixtureGit @('rev-parse', 'HEAD')

  $successRelative = '.orchestrator/artifacts/diagnostic-success.mjs'
  $successPath = Join-Path $worktree ($successRelative -replace '/', '\')
  Set-Content -LiteralPath $successPath -Value @'
import fs from 'node:fs';
fs.writeFileSync(process.env.DIAGNOSTIC_MARKER, 'ran');
process.exitCode = 7;
'@
  $successHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($successPath))).ToLowerInvariant()

  function Invoke-Diagnostic([hashtable]$Overrides = @{}) {
    $parameters = @{
      '-Diagnostic' = 'worst13-no-fit'
      '-DiagnosticScriptPath' = $successRelative
      '-DiagnosticSha256' = $successHash
      '-DiagnosticBudgetSeconds' = '10'
      '-Worktree' = $worktree
      '-Lane' = 'lane-test'
      '-Branch' = 'codex/test'
      '-ClaimedHead' = $head
      '-ContainerRoot' = $container
    }
    foreach ($entry in $Overrides.GetEnumerator()) { $parameters[$entry.Key] = $entry.Value }
    $args = @('-NoProfile', '-NonInteractive', '-File', $guard)
    foreach ($entry in $parameters.GetEnumerator()) { $args += @($entry.Key, [string]$entry.Value) }
    return Invoke-Child $args @{ DIAGNOSTIC_MARKER = (Join-Path $root 'success.marker'); DIAGNOSTIC_PID = (Join-Path $root 'timeout.pid') }
  }

  $success = Invoke-Diagnostic
  $receipt = @(Get-ChildItem -LiteralPath $artifactRoot -Filter 'host-heavy-diagnostic-*.json' -File)
  Assert-True ($success.Code -eq 7 -and (Test-Path (Join-Path $root 'success.marker'))) "declared diagnostic runs through the wrapper (exit=$($success.Code) stdout=$($success.Stdout) stderr=$($success.Stderr))"
  Assert-True ($receipt.Count -eq 1) 'declared diagnostic leaves one durable receipt'
  $successReceipt = Get-Content -LiteralPath $receipt[0].FullName -Raw | ConvertFrom-Json -DateKind String
  Assert-True ($successReceipt.schema -ceq 'host-heavy-diagnostic/v1' -and $successReceipt.diagnostic.name -ceq 'worst13-no-fit' -and
    $successReceipt.diagnostic.scriptPath -ceq $successRelative -and $successReceipt.diagnostic.sha256 -ceq $successHash -and
    $successReceipt.diagnostic.budgetSeconds -eq 10 -and $successReceipt.exit -eq 7 -and $successReceipt.timedOut -eq $false -and
    $successReceipt.start -and $successReceipt.end -and $successReceipt.elapsedMs -ge 0 -and
    $successReceipt.resources.cpuTimeMs -ge 0 -and $successReceipt.resources.peakWorkingSetBytes -gt 0 -and
    $successReceipt.slot.name -ceq 'verify-lock.d' -and -not (Test-Path $lockRoot)) "diagnostic receipt binds timing, exit, resources and released slot ($($successReceipt | ConvertTo-Json -Compress -Depth 8))"
  Write-Output 'PASS diagnostic declared route receipt=1 exit=7 resources=1 released=1'

  foreach ($negative in @(
    @{ Name = 'undeclared'; Values = @{ '-Diagnostic' = 'not-declared' } },
    @{ Name = 'hash-mismatch'; Values = @{ '-DiagnosticSha256' = ('0' * 64) } },
    @{ Name = 'missing-budget'; Values = @{ '-DiagnosticBudgetSeconds' = $null } },
    @{ Name = 'zero-budget'; Values = @{ '-DiagnosticBudgetSeconds' = '0' } },
    @{ Name = 'nonfinite-budget'; Values = @{ '-DiagnosticBudgetSeconds' = 'NaN' } }
  )) {
    $before = @(Get-ChildItem -LiteralPath $artifactRoot -Filter 'host-heavy-diagnostic-*.json' -File).Count
    $parameters = @{}
    foreach ($entry in $negative.Values.GetEnumerator()) { $parameters[$entry.Key] = $entry.Value }
    if ($negative.Name -ceq 'missing-budget') {
      $parameters['-DiagnosticBudgetSeconds'] = $null
    }
    $args = @('-NoProfile', '-NonInteractive', '-File', $guard)
    $base = @{
      '-Diagnostic' = $(if ($negative.Name -ceq 'undeclared') { 'not-declared' } else { 'worst13-no-fit' })
      '-DiagnosticScriptPath' = $successRelative; '-DiagnosticSha256' = $successHash; '-DiagnosticBudgetSeconds' = '10'
      '-Worktree' = $worktree; '-Lane' = 'lane-test'; '-Branch' = 'codex/test'; '-ClaimedHead' = $head; '-ContainerRoot' = $container
    }
    foreach ($entry in $parameters.GetEnumerator()) { if ($null -eq $entry.Value) { [void]$base.Remove($entry.Key) } else { $base[$entry.Key] = $entry.Value } }
    foreach ($entry in $base.GetEnumerator()) { $args += @($entry.Key, [string]$entry.Value) }
    $result = Invoke-Child $args
    $after = @(Get-ChildItem -LiteralPath $artifactRoot -Filter 'host-heavy-diagnostic-*.json' -File).Count
    Assert-True ($result.Code -ne 7 -and $after -eq $before -and -not (Test-Path $lockRoot)) "$($negative.Name) refuses before admission"
  }
  Write-Output 'PASS diagnostic mutants undeclared=1 hash-mismatch=1 missing-budget=1 zero-budget=1 nonfinite-budget=1 pre-admission=1'

  $timeoutRelative = '.orchestrator/artifacts/diagnostic-timeout.mjs'
  $timeoutPath = Join-Path $worktree ($timeoutRelative -replace '/', '\')
  $timeoutPidPath = Join-Path $root 'timeout.pid'
  Set-Content -LiteralPath $timeoutPath -Value @'
import fs from 'node:fs';
import { spawn } from 'node:child_process';
const child = spawn(process.execPath, ['-e', 'setTimeout(() => {}, 10000)'], { windowsHide: true });
fs.writeFileSync(process.env.DIAGNOSTIC_PID, String(child.pid));
setTimeout(() => {}, 10000);
'@
  $timeoutHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($timeoutPath))).ToLowerInvariant()
  $timeout = Invoke-Diagnostic @{ '-DiagnosticScriptPath' = $timeoutRelative; '-DiagnosticSha256' = $timeoutHash; '-DiagnosticBudgetSeconds' = '1'; '-Diagnostic' = 'worst13-no-fit' }
  $timeoutReceipt = @(Get-ChildItem -LiteralPath $artifactRoot -Filter 'host-heavy-diagnostic-*.json' -File | Where-Object { $_.FullName -ne $receipt[0].FullName })
  Assert-True ($timeoutReceipt.Count -eq 1) 'budget overrun leaves a timeout receipt'
  $timeoutRecord = Get-Content -LiteralPath $timeoutReceipt[0].FullName -Raw | ConvertFrom-Json -DateKind String
  $timeoutPid = [int](Get-Content -LiteralPath $timeoutPidPath -Raw)
  Start-Sleep -Milliseconds 100
  Assert-True ($timeoutRecord.timedOut -eq $true -and $timeoutRecord.elapsedMs -ge 900 -and
    $timeoutRecord.resources.peakWorkingSetBytes -gt 0 -and -not (Get-Process -Id $timeoutPid -ErrorAction SilentlyContinue)) 'budget overrun kills the child tree and records it'
  Write-Output 'PASS diagnostic budget-overrun kills-tree=1 receipt=1 resources=1'

  # Exercise the preload receipt writer and the wrapper's binding validator,
  # including the missing-receipt mutant, without acquiring the real slot.
  $slot = 'a' * 32
  $owner = [ordered]@{ lockId=$slot; owner='fixture@host'; pid=1234; processStartUtc='2026-10-18T00:00:00.0000000Z'; state='attached'; childPid=1235; childProcessStartUtc='2026-10-18T00:00:00.0000000Z' }
  New-Item -ItemType Directory -Path $lockRoot -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $lockRoot 'owner.json'), ($owner | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
  $node = (Get-Command node -CommandType Application | Select-Object -First 1).Source
  $command = [ordered]@{ executable=$node; arguments=@('fixture.mjs', 'run') }
  $configuration = [ordered]@{ laneMode=$true; workspaceTest='@chase-sets/ordering'; containerRoot=$container; worktree=$worktree; immutableHead=('a' * 40); expectedCommand=$command }
  $startUtc = '2026-10-18T00:00:00.0000000Z'
  $env:LANE_RECEIPT_CONFIG = $configuration | ConvertTo-Json -Compress -Depth 8
  $env:LANE_RECEIPT_START = $startUtc
  $env:LANE_RECEIPT_SLOT = $slot
  $env:LANE_RECEIPT_PRELOAD = $preload
  Push-Location $worktree
  try { $laneWriterOutput = @(& node -e 'const p=require(process.env.LANE_RECEIPT_PRELOAD); p.writeLaneReceipt(JSON.parse(process.env.LANE_RECEIPT_CONFIG), "script-battery", process.env.LANE_RECEIPT_SLOT, process.env.LANE_RECEIPT_START, Date.now()-100, 0, {userCpuMicroseconds:1,systemCpuMicroseconds:2,maxRssBytes:3});' 2>&1) }
  finally { Pop-Location }
  Remove-Item Env:LANE_RECEIPT_CONFIG,Env:LANE_RECEIPT_START,Env:LANE_RECEIPT_SLOT,Env:LANE_RECEIPT_PRELOAD
  $laneReceiptPath = Join-Path $artifactRoot "lane-heavy-admission-$slot.json"
  Assert-True (Test-Path $laneReceiptPath) "preload retains a durable lane-mode receipt ($($laneWriterOutput -join ' '))"

  $sourceTokens = $null; $sourceErrors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($guard, [ref]$sourceTokens, [ref]$sourceErrors)
  foreach ($name in @('Test-SafeFile', 'Test-UtcIdentity', 'Assert-LaneAdmissionReceipt')) {
    $definition = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name }, $false))[0]
    . ([scriptblock]::Create($definition.Extent.Text))
  }
  $env:CHASE_SETS_LANE_MODE = '1'
  $env:CHASE_SETS_HEAVY_ADMISSION_WORKSPACE_TEST = '@chase-sets/ordering'
  $worktreeFull = $worktree; $lockDirectoryName = 'verify-lock.d'; $command = $node; $arguments = @('fixture.mjs', 'run')
  $acquiredGitIdentity = [pscustomobject]@{ Head=('a' * 40) }
  $owner = [pscustomobject]@{ owner='fixture@host'; pid=1234; lockId=$slot }
  try { Assert-LaneAdmissionReceipt | Out-Null } catch {
    $debugReceipt = Get-Content -LiteralPath $laneReceiptPath -Raw | ConvertFrom-Json -DateKind String
    throw "positive lane receipt binding failed: $($_.Exception.Message) checks=holder:$($debugReceipt.holder.owner -ceq $owner.owner),pid:$([int]$debugReceipt.holder.pid -eq [int]$owner.pid),slot:$($debugReceipt.slot.lockId -ceq $owner.lockId),name:$($debugReceipt.slot.name -ceq $lockDirectoryName),cwd:$([IO.Path]::GetFullPath([string]$debugReceipt.cwd) -ceq $worktreeFull),head:$([string]$debugReceipt.head -ceq [string]$acquiredGitIdentity.Head),exe:$($debugReceipt.command.executable -ceq $command),args:$((@($debugReceipt.command.arguments) -join "`n") -ceq (@($arguments) -join "`n")),start:$(Test-UtcIdentity ([string]$debugReceipt.start)),end:$(Test-UtcIdentity ([string]$debugReceipt.end)),exit:$($debugReceipt.exit.GetType().FullName) raw=$([IO.File]::ReadAllText($laneReceiptPath))"
  }
  Remove-Item -LiteralPath $laneReceiptPath -Force
  $missingReceiptRefused = $false
  try { Assert-LaneAdmissionReceipt | Out-Null } catch { $missingReceiptRefused = $_.Exception.Message -match 'receipt is missing.*binding refused' }
  Assert-True $missingReceiptRefused 'missing receipt fails lane binding'
  Remove-Item Env:CHASE_SETS_LANE_MODE,Env:CHASE_SETS_HEAVY_ADMISSION_WORKSPACE_TEST
  Write-Output 'PASS lane preload receipt holder=1 slot=1 command=1 cwd=1 head=1 missing-receipt-refused=1'
} finally {
  Remove-Item Env:CHASE_SETS_LANE_MODE,Env:LANE_RECEIPT_CONFIG,Env:LANE_RECEIPT_START,Env:LANE_RECEIPT_SLOT,Env:LANE_RECEIPT_PRELOAD -ErrorAction SilentlyContinue
  if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}
