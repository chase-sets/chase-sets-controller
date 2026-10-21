[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$sourceRoot = $PSScriptRoot
$root = Join-Path ([IO.Path]::GetTempPath()) ('workspace-db-test-' + [guid]::NewGuid().ToString('N'))
$runtime = Join-Path $root '.orchestrator'
$worktree = Join-Path $root 'fixture'
$artifacts = Join-Path $worktree '.orchestrator/artifacts'
$children = [Collections.Generic.List[object]]::new()

function Assert-True($Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}
function Git([string[]]$Arguments) {
  $output = @(& git.exe -C $worktree @Arguments 2>&1)
  Assert-True ($LASTEXITCODE -eq 0) ($output -join "`n")
  return ($output -join "`n").Trim()
}
function Start-Route([string]$GuardPath, [string[]]$Arguments, [hashtable]$Environment = @{}) {
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = (Get-Process -Id $PID).Path
  $start.WorkingDirectory = $worktree
  $start.UseShellExecute = $false
  $start.CreateNoWindow = $true
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  $start.ArgumentList.Add('-NoProfile')
  $start.ArgumentList.Add('-NonInteractive')
  $start.ArgumentList.Add('-File')
  $start.ArgumentList.Add($GuardPath)
  foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
  foreach ($name in $Environment.Keys) { $start.Environment[$name] = [string]$Environment[$name] }
  $process = [Diagnostics.Process]::Start($start)
  $entry = [pscustomobject]@{
    Process = $process
    Start = $process.StartTime.ToUniversalTime().Ticks
    Out = $process.StandardOutput.ReadToEndAsync()
    Err = $process.StandardError.ReadToEndAsync()
  }
  $children.Add($entry)
  return $entry
}
function Complete-Route($Entry, [int]$ExpectedExit, [int]$TimeoutSeconds = 30) {
  Assert-True ($Entry.Process.WaitForExit($TimeoutSeconds * 1000)) 'route completed within the focused test bound'
  $text = $Entry.Out.GetAwaiter().GetResult() + $Entry.Err.GetAwaiter().GetResult()
  Assert-True ($Entry.Process.ExitCode -eq $ExpectedExit) "expected exit $ExpectedExit, got $($Entry.Process.ExitCode): $text"
  return $text
}
function Common-Arguments([string]$GuardPath, [string]$RouteLane = 'workspace-db-test') {
  @('-Worktree', $worktree, '-Lane', $RouteLane, '-ImmutableHead', $head)
}
function Invoke-Route([string[]]$Extra, [string]$GuardPath = '') {
  if (-not $GuardPath) { $GuardPath = Join-Path $runtime 'invoke-heavy-verifier.ps1' }
  $entry = Start-Route $GuardPath ((Common-Arguments $GuardPath) + $Extra)
  return [pscustomobject]@{ Entry = $entry; Text = Complete-Route $entry 0 }
}
function Get-Receipts {
  @(Get-ChildItem -LiteralPath $artifacts -Filter 'host-heavy-verifier-*.json' -File -ErrorAction SilentlyContinue |
    ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -DateKind String })
}
function Start-DispatchRoute([bool]$Hang = $false) {
  $wrapper = Join-Path $runtime 'dispatch-wrapper.ps1'
  $routePath = Join-Path $runtime 'dispatch-log.jsonl'
  $transcriptPath = Join-Path $runtime 'workspace-db-implementation.jsonl'
  $hangValue = if ($Hang) { '1' } else { '0' }
  $source = @"
`$ErrorActionPreference = 'Stop'
`$self = Get-Process -Id `$PID
`$parentId = [int](Get-CimInstance Win32_Process -Filter "ProcessId = `$PID").ParentProcessId
`$parent = Get-Process -Id `$parentId
`$start = `$self.StartTime.ToUniversalTime()
`$launchId = [guid]::NewGuid().ToString()
`$recordPath = Join-Path '$runtime' "dispatch-launch-`$launchId.json"
`$promptPath = Join-Path '$runtime' "dispatch-heavy-verifier-`$launchId.prompt.txt"
`$record = [ordered]@{
  schemaVersion=4; launchId=`$launchId; laneRole='implementation'; promptPath=`$promptPath; reviewIsolationRoot=`$null
  launcherPid=`$parentId; launcherStartIdentity=`$parent.StartTime.ToUniversalTime().ToString('o'); recordedAt=`$start.AddSeconds(-1).ToString('o'); state='started'
  childPid=`$PID; childStartIdentity=`$start.ToString('o'); worktree='$worktree'; lane='fixture'; identityMode='immutable-head'; branch=`$null; head='$head'
  label='workspace-db-implementation'; transcriptPath='$transcriptPath'
}
`$route = [ordered]@{
  ts=`$start.AddMilliseconds(-1).ToString('o'); kind='dispatch'; dispatchRoutingSchema='watchdog-dispatch-routing/v1'; attemptId='workspace-db-implementation'; label='workspace-db-implementation'; lane='fixture'; laneRole='implementation'; transcript='workspace-db-implementation.jsonl'
  harness='codex'; model='gpt-6-astra'; effort='high'; row='7'; placement='override-Todd'; worktree='$worktree'; branch=`$null; head='$head'
}
[IO.File]::WriteAllText(`$promptPath, 'synthetic workspace DB implementation lane')
[IO.File]::WriteAllText('$transcriptPath', '{"type":"item.completed"}')
[IO.File]::WriteAllText(`$recordPath, (`$record | ConvertTo-Json -Compress))
[IO.File]::WriteAllText('$routePath', ((`$route | ConvertTo-Json -Compress) + "`n"))
`$env:WORKSPACE_DB_HANG = '$hangValue'
try {
  & '$runtime\invoke-heavy-verifier.ps1' -Worktree '$worktree' -Lane 'fixture' -ImmutableHead '$head' -WorkspaceDbTest '@chase-sets/payments' -WorkspaceDbBudgetSeconds $(if ($Hang) { '5' } else { '10' })
  `$code = `$LASTEXITCODE
} finally {
  Remove-Item -LiteralPath `$recordPath, `$promptPath, '$transcriptPath', '$routePath' -Force -ErrorAction SilentlyContinue
}
exit `$code
"@
  [IO.File]::WriteAllText($wrapper, $source)
  return Start-Route $wrapper @{}
}

try {
  New-Item -ItemType Directory -Path $runtime, $artifacts, (Join-Path $worktree 'scripts'),
    (Join-Path $worktree 'bounded-contexts/payments/tests'),
    (Join-Path $worktree 'bounded-contexts/payments/features/payments/api'),
    (Join-Path $worktree 'bounded-contexts/payments/node_modules/.bin') -Force | Out-Null
  foreach ($file in @('invoke-heavy-verifier.ps1', 'heavy-admission-preload.cjs', 'heavy-slot.cjs',
      'heavy-nested-owner.cs', 'heavy-nested-client.cjs', 'heavy-admission-holder-launcher.cjs',
      'dispatch-ownership.ps1', 'workspace-db-test.mjs')) {
    Copy-Item -LiteralPath (Join-Path $sourceRoot $file) -Destination (Join-Path $runtime $file)
  }
  Set-Content -LiteralPath (Join-Path $worktree '.gitignore') @'
.orchestrator/artifacts/
node_modules/
pnpm-lock.yaml
'@
  Set-Content -LiteralPath (Join-Path $worktree 'pnpm-workspace.yaml') "packages:`n  - bounded-contexts/payments"
  Set-Content -LiteralPath (Join-Path $worktree 'package.json') @'
{"name":"workspace-db-fixture","private":true}
'@
  Set-Content -LiteralPath (Join-Path $worktree 'bounded-contexts/payments/package.json') @'
{"name":"@chase-sets/payments","private":true,"scripts":{"test:db":"node ../../scripts/db-body.mjs"}}
'@
  Set-Content -LiteralPath (Join-Path $worktree 'scripts/db-test-preflight.mjs') @'
import fs from "node:fs";
import path from "node:path";
fs.appendFileSync(path.resolve(".orchestrator/artifacts/preflight"), "preflight\n");
'@
  Set-Content -LiteralPath (Join-Path $worktree 'scripts/run-workspaces.mjs') @'
import fs from "node:fs";
import {spawn} from "node:child_process";
import path from "node:path";
import {fileURLToPath} from "node:url";

export function loadTestEnvironment({includeTestDatabaseUrl = false} = {}) {
  if (includeTestDatabaseUrl) process.env.TEST_DATABASE_URL = "fixture://test-db";
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url))) {
  const args = process.argv.slice(2);
  fs.writeFileSync(path.resolve(".orchestrator/artifacts/run-workspaces-args"), JSON.stringify(args));
  if (args.length !== 2 || args[0] !== "test:db*" || args[1] !== "--workspace=@chase-sets/payments") {
    process.stderr.write("fixture run-workspaces received unexpected arguments\n");
    process.exitCode = 2;
  } else {
    loadTestEnvironment({includeTestDatabaseUrl: true});
    const child = spawn(process.execPath, [path.resolve("scripts/db-body.mjs")], {
      cwd: path.resolve("bounded-contexts/payments"),
      env: process.env,
      stdio: "inherit",
      windowsHide: true,
    });
    child.once("error", (error) => { process.stderr.write(`${error}\n`); process.exitCode = 1; });
    child.once("exit", (code, signal) => { process.exitCode = signal ? 1 : (code ?? 1); });
  }
}
'@
  Set-Content -LiteralPath (Join-Path $worktree 'scripts/db-body.mjs') @'
import fs from "node:fs";
import {spawn} from "node:child_process";
import path from "node:path";
const out = path.resolve("../../.orchestrator/artifacts");
if (!process.env.TEST_DATABASE_URL) {
  process.stderr.write("TEST_DATABASE_URL is required by the fixture DB test\n");
  process.exitCode = 4;
  process.exit();
}
fs.appendFileSync(`${out}/body`, "body\n");
if (process.env.WORKSPACE_DB_HANG === "1") {
  const child = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], {stdio: "ignore", windowsHide: true});
  fs.writeFileSync(`${out}/grandchild.pid`, String(child.pid));
  setInterval(() => {}, 1000);
}
'@
  Set-Content -LiteralPath (Join-Path $worktree 'scripts/file-body.mjs') @'
import fs from "node:fs";
import path from "node:path";
if (!process.env.TEST_DATABASE_URL) {
  process.stderr.write("TEST_DATABASE_URL is required by the fixture vitest\n");
  process.exitCode = 4;
  process.exit();
}
fs.writeFileSync(path.resolve("../../.orchestrator/artifacts/file-args"), JSON.stringify(process.argv.slice(2)));
'@
  Set-Content -LiteralPath (Join-Path $worktree 'bounded-contexts/payments/node_modules/.bin/vitest.cmd') @'
@echo off
node "%~dp0\..\..\..\..\scripts\file-body.mjs" %*
'@
  Set-Content -LiteralPath (Join-Path $worktree 'bounded-contexts/payments/features/payments/api/saved-instrument-attempt.db.test.ts') 'export {}'

  & git.exe -C $worktree init -b synthetic-workspace-db | Out-Null
  & git.exe -C $worktree -c user.name='Workspace DB Fixture' -c user.email='workspace-db@example.invalid' add .
  & git.exe -C $worktree -c user.name='Workspace DB Fixture' -c user.email='workspace-db@example.invalid' commit -m 'synthetic workspace db route fixture' | Out-Null
  $head = Git @('rev-parse', 'HEAD')
  & git.exe -C $worktree checkout --detach $head | Out-Null
  Assert-True (-not (Git @('status', '--porcelain', '--untracked-files=all'))) 'fixture is clean before route calls'

  $validFile = 'bounded-contexts/payments/features/payments/api/saved-instrument-attempt.db.test.ts'
  $noFile = Invoke-Route @('-WorkspaceDbTest', '@chase-sets/payments', '-WorkspaceDbBudgetSeconds', '10')
  Assert-True (Test-Path (Join-Path $artifacts 'preflight')) 'no-file route ran DB preflight'
  Assert-True (Test-Path (Join-Path $artifacts 'body')) 'no-file route ran Payments test:db'
  $runWorkspaceArgs = @(Get-Content (Join-Path $artifacts 'run-workspaces-args') -Raw | ConvertFrom-Json)
  Assert-True ($runWorkspaceArgs.Count -eq 2 -and $runWorkspaceArgs[0] -ceq 'test:db*' -and
    $runWorkspaceArgs[1] -ceq '--workspace=@chase-sets/payments') 'no-file route invokes run-workspaces with the exact scoped DB selector'
  $noFileReceipt = @(Get-Receipts | Where-Object workspace -eq '@chase-sets/payments')[0]
  Assert-True ($noFileReceipt -and $noFileReceipt.file -eq $null -and $noFileReceipt.budgetSeconds -eq 10 -and
    $noFileReceipt.timedOut -eq $false -and $noFileReceipt.elapsedMs -ge 0) 'no-file receipt records workspace, null file, budget and elapsed'
  $pnpmShim = Get-Command pnpm -All -CommandType Application | Where-Object Source -like '*\pnpm.CMD' | Select-Object -First 1
  $pnpmScript = Join-Path (Split-Path -Parent $pnpmShim.Source) 'node_modules/pnpm/bin/pnpm.cjs'
  $directIdentity = "verify:test-db`n$($noFileReceipt.executable)`n$pnpmScript`nrun`nverify:test-db"
  $directHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($directIdentity))).ToLowerInvariant()
  Assert-True ($noFileReceipt.commandIdentity -cne $directHash) 'bounded workspace command identity differs from full verify:test-db'

  $fileRun = Invoke-Route @('-WorkspaceDbTest', '@chase-sets/payments', '-WorkspaceDbTestFile', $validFile, '-WorkspaceDbBudgetSeconds', '10')
  $fileReceipt = @(Get-Receipts | Where-Object { $_.workspace -eq '@chase-sets/payments' -and $_.file -eq $validFile })[0]
  Assert-True ($fileReceipt -and $fileReceipt.budgetSeconds -eq 10 -and $fileReceipt.timedOut -eq $false -and $fileReceipt.elapsedMs -ge 0) 'file receipt records workspace, file, budget and elapsed'
  Assert-True ((Get-Content (Join-Path $artifacts 'file-args') -Raw | ConvertFrom-Json)[-1] -ceq $validFile.Substring('bounded-contexts/payments/'.Length)) 'file route passes exactly the workspace-relative file'
  Assert-True ($fileReceipt.arguments -contains $validFile) 'file route receipt contains the fixed file argument'
  Assert-True (-not (Test-Path (Join-Path $runtime 'verify-lock.d'))) 'successful workspace routes release the shared heavy lock'

  $collisionFile = 'bounded-contexts/payments/features/payments/api/other/features/payments/api/saved-instrument-attempt.db.test.ts'
  New-Item -ItemType Directory -Path (Split-Path -Parent (Join-Path $worktree $collisionFile)) -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $worktree $collisionFile) 'export {}'
  & git.exe -C $worktree add $collisionFile
  & git.exe -C $worktree -c user.name='Workspace DB Fixture' -c user.email='workspace-db@example.invalid' commit -m 'add colliding workspace DB filter' | Out-Null
  $head = Git @('rev-parse', 'HEAD')
  $collisionEntry = Start-Route (Join-Path $runtime 'invoke-heavy-verifier.ps1') ((Common-Arguments '') + @('-WorkspaceDbTest','@chase-sets/payments','-WorkspaceDbTestFile',$validFile,'-WorkspaceDbBudgetSeconds','10'))
  Assert-True ($collisionEntry.Process.WaitForExit(30000)) 'colliding filter refusal completed'
  $collisionText = $collisionEntry.Out.GetAwaiter().GetResult() + $collisionEntry.Err.GetAwaiter().GetResult()
  Assert-True ($collisionEntry.Process.ExitCode -ne 0 -and $collisionText -match 'exactly one tracked payments path') 'colliding tracked file filter is refused before execution'
  Assert-True (-not (Test-Path (Join-Path $runtime 'verify-lock.d'))) 'colliding filter refused before lock admission'
  Remove-Item -LiteralPath (Join-Path $worktree $collisionFile) -Force
  & git.exe -C $worktree add -u $collisionFile
  & git.exe -C $worktree -c user.name='Workspace DB Fixture' -c user.email='workspace-db@example.invalid' commit -m 'remove colliding workspace DB filter' | Out-Null
  $head = Git @('rev-parse', 'HEAD')

  $packagePath = Join-Path $worktree 'bounded-contexts/payments/package.json'
  $packageWithDbScript = [IO.File]::ReadAllText($packagePath)
  [IO.File]::WriteAllText($packagePath, '{"name":"@chase-sets/payments","private":true,"scripts":{"test:unit":"node ../../scripts/db-body.mjs"}}')
  & git.exe -C $worktree add $packagePath
  & git.exe -C $worktree -c user.name='Workspace DB Fixture' -c user.email='workspace-db@example.invalid' commit -m 'remove Payments DB script' | Out-Null
  $head = Git @('rev-parse', 'HEAD')
  $missingScriptEntry = Start-Route (Join-Path $runtime 'invoke-heavy-verifier.ps1') ((Common-Arguments '') + @('-WorkspaceDbTest','@chase-sets/payments','-WorkspaceDbBudgetSeconds','10'))
  Assert-True ($missingScriptEntry.Process.WaitForExit(30000)) 'missing DB script refusal completed'
  $missingScriptText = $missingScriptEntry.Out.GetAwaiter().GetResult() + $missingScriptEntry.Err.GetAwaiter().GetResult()
  Assert-True ($missingScriptEntry.Process.ExitCode -ne 0 -and $missingScriptText -match 'no test:db or test:db:\* script') 'missing Payments DB script is fail-closed'
  [IO.File]::WriteAllText($packagePath, $packageWithDbScript)
  & git.exe -C $worktree add $packagePath
  & git.exe -C $worktree -c user.name='Workspace DB Fixture' -c user.email='workspace-db@example.invalid' commit -m 'restore Payments DB script' | Out-Null
  $head = Git @('rev-parse', 'HEAD')

  $invalid = @(
    @{Name='unknown-workspace'; Extra=@('-WorkspaceDbTest','@chase-sets/ordering','-WorkspaceDbBudgetSeconds','10'); Text='ValidateSet'},
    @{Name='outside-workspace'; Extra=@('-WorkspaceDbTest','@chase-sets/payments','-WorkspaceDbTestFile','bounded-contexts/ordering/foo.db.test.ts','-WorkspaceDbBudgetSeconds','10'); Text='normalized repository-relative payments'},
    @{Name='dotdot'; Extra=@('-WorkspaceDbTest','@chase-sets/payments','-WorkspaceDbTestFile','bounded-contexts/payments/../ordering/foo.db.test.ts','-WorkspaceDbBudgetSeconds','10'); Text='normalized repository-relative payments'},
    @{Name='absolute'; Extra=@('-WorkspaceDbTest','@chase-sets/payments','-WorkspaceDbTestFile',(Join-Path $worktree $validFile),'-WorkspaceDbBudgetSeconds','10'); Text='normalized repository-relative payments'},
    @{Name='unc'; Extra=@('-WorkspaceDbTest','@chase-sets/payments','-WorkspaceDbTestFile','\\server\share\foo.db.test.ts','-WorkspaceDbBudgetSeconds','10'); Text='normalized repository-relative payments'},
    @{Name='extended-absolute'; Extra=@('-WorkspaceDbTest','@chase-sets/payments','-WorkspaceDbTestFile','\\?\C:\bounded-contexts\payments\foo.db.test.ts','-WorkspaceDbBudgetSeconds','10'); Text='normalized repository-relative payments'},
    @{Name='wrong-extension'; Extra=@('-WorkspaceDbTest','@chase-sets/payments','-WorkspaceDbTestFile','bounded-contexts/payments/tests/not-a-db.test.ts','-WorkspaceDbBudgetSeconds','10'); Text='normalized repository-relative payments'},
    @{Name='untracked'; Extra=@('-WorkspaceDbTest','@chase-sets/payments','-WorkspaceDbTestFile','bounded-contexts/payments/features/payments/api/untracked.db.test.ts','-WorkspaceDbBudgetSeconds','10'); Text='not tracked'},
    @{Name='case-variant'; Extra=@('-WorkspaceDbTest','@chase-sets/payments','-WorkspaceDbTestFile',$validFile.ToUpperInvariant(),'-WorkspaceDbBudgetSeconds','10'); Text='normalized repository-relative payments'},
    @{Name='blank-file'; Extra=@('-WorkspaceDbTest','@chase-sets/payments','-WorkspaceDbTestFile','', '-WorkspaceDbBudgetSeconds','10'); Text='must not be empty'},
    @{Name='whitespace-file'; Extra=@('-WorkspaceDbTest','@chase-sets/payments','-WorkspaceDbTestFile','   ', '-WorkspaceDbBudgetSeconds','10'); Text='must not be empty'},
    @{Name='budget-zero'; Extra=@('-WorkspaceDbTest','@chase-sets/payments','-WorkspaceDbBudgetSeconds','0'); Text='greater than zero'},
    @{Name='budget-nan'; Extra=@('-WorkspaceDbTest','@chase-sets/payments','-WorkspaceDbBudgetSeconds','NaN'); Text='finite'},
    @{Name='above-max'; Extra=@('-WorkspaceDbTest','@chase-sets/payments','-WorkspaceDbBudgetSeconds','901'); Text='no more than 900'}
  )
  Set-Content -LiteralPath (Join-Path $worktree 'bounded-contexts/payments/features/payments/api/untracked.db.test.ts') 'export {}'
  $foreignLock = Join-Path $runtime 'verify-lock.d'
  New-Item -ItemType Directory -Path $foreignLock -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $foreignLock 'foreign-marker'), 'foreign-lock')
  foreach ($case in $invalid) {
    $entry = Start-Route (Join-Path $runtime 'invoke-heavy-verifier.ps1') ((Common-Arguments '') + $case.Extra)
    Assert-True ($entry.Process.WaitForExit(30000)) "$($case.Name) refusal completed"
    $text = $entry.Out.GetAwaiter().GetResult() + $entry.Err.GetAwaiter().GetResult()
    Assert-True ($entry.Process.ExitCode -ne 0) "$($case.Name) has a nonzero refusal exit"
    Assert-True ($text -match [regex]::Escape($case.Text)) "$($case.Name) gives its closed refusal"
    Assert-True ((Test-Path (Join-Path $runtime 'verify-lock.d')) -and
      (Get-Content (Join-Path $runtime 'verify-lock.d/foreign-marker') -Raw) -eq 'foreign-lock') "$($case.Name) refused before lock admission"
  }
  Remove-Item -LiteralPath (Join-Path $worktree 'bounded-contexts/payments/features/payments/api/untracked.db.test.ts') -Force
  Remove-Item -LiteralPath $foreignLock -Recurse -Force
  Assert-True (@(Get-Receipts).Count -eq 3) 'invalid requests create no receipt'
  Write-Output 'PASS workspace-db route accepted Payments, exact file, closed refusals, receipt identity and pre-admission controls'

  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = (Get-Process -Id $PID).Path; $start.WorkingDirectory = $worktree; $start.UseShellExecute = $false
  $start.CreateNoWindow = $true; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
  foreach ($arg in @('-NoProfile','-NonInteractive','-File',(Join-Path $runtime 'invoke-heavy-verifier.ps1')) + ((Common-Arguments '') + @('-WorkspaceDbTest','@chase-sets/payments','-WorkspaceDbBudgetSeconds','5'))) { $start.ArgumentList.Add($arg) }
  $start.Environment['WORKSPACE_DB_HANG'] = '1'
  $timed = [Diagnostics.Process]::Start($start)
  $timedOut = [pscustomobject]@{ Process=$timed; Out=$timed.StandardOutput.ReadToEndAsync(); Err=$timed.StandardError.ReadToEndAsync() }
  $children.Add($timedOut)
  Assert-True ($timed.WaitForExit(30000)) 'hanging route reaches its budget'
  $timedText = $timedOut.Out.GetAwaiter().GetResult() + $timedOut.Err.GetAwaiter().GetResult()
  Assert-True ($timed.ExitCode -eq 124) "hanging route exits 124: $timedText"
  $timeoutReceipt = @(Get-Receipts | Where-Object timedOut -eq $true)[0]
  Assert-True ($timeoutReceipt -and $timeoutReceipt.exit -eq 124 -and $timeoutReceipt.timedOut -eq $true -and $timeoutReceipt.elapsedMs -ge 5000) 'timeout receipt records timed-out and elapsed budget'
  $grandchildPath = Join-Path $artifacts 'grandchild.pid'
  $markerDeadline = [DateTime]::UtcNow.AddSeconds(5)
  while (-not (Test-Path -LiteralPath $grandchildPath) -and [DateTime]::UtcNow -lt $markerDeadline) { Start-Sleep -Milliseconds 50 }
  Assert-True (Test-Path -LiteralPath $grandchildPath) 'hanging fixture published a descendant before budget expiry'
  $grandchildPid = [int](Get-Content $grandchildPath -Raw)
  Start-Sleep -Milliseconds 250
  Assert-True (-not (Get-Process -Id $grandchildPid -ErrorAction SilentlyContinue)) 'timeout kills the whole child tree'
  Assert-True (-not (Test-Path (Join-Path $runtime 'verify-lock.d'))) 'timeout releases the shared heavy lock'
  Write-Output 'PASS workspace-db timeout kills descendants at budget, records timed-out and releases lock'

  $dispatchEntry = Start-DispatchRoute
  $dispatchText = Complete-Route $dispatchEntry 0
  $dispatchReceipt = @(Get-Receipts | Where-Object { $_.authority -eq 'dispatch-lane' -and $_.timedOut -eq $false } | Select-Object -Last 1)[0]
  Assert-True ($dispatchReceipt -and $dispatchReceipt.route -ceq 'workspace-db-test' -and
    $dispatchReceipt.authority -ceq 'dispatch-lane' -and $dispatchReceipt.launchId -and
    $dispatchReceipt.laneRole -ceq 'implementation' -and $dispatchReceipt.routingRow -eq 7 -and
    $dispatchReceipt.exit -eq 0) "implementation row-7 pass records dispatch authority: $dispatchText"
  Write-Output 'PASS implementation row-7 workspace DB route writes dispatch-lane receipt'

  $dispatchTimedEntry = Start-DispatchRoute $true
  Assert-True ($dispatchTimedEntry.Process.WaitForExit(30000)) 'implementation row-7 timeout reaches its budget'
  $dispatchTimedText = $dispatchTimedEntry.Out.GetAwaiter().GetResult() + $dispatchTimedEntry.Err.GetAwaiter().GetResult()
  Assert-True ($dispatchTimedEntry.Process.ExitCode -eq 124) "implementation row-7 timeout exits 124: $dispatchTimedText"
  $dispatchTimeoutReceipt = @(Get-Receipts | Where-Object { $_.authority -eq 'dispatch-lane' -and $_.timedOut -eq $true } | Select-Object -Last 1)[0]
  Assert-True ($dispatchTimeoutReceipt -and $dispatchTimeoutReceipt.route -ceq 'workspace-db-test' -and
    $dispatchTimeoutReceipt.exit -eq 124 -and $dispatchTimeoutReceipt.nativeExit -ne $null -and
    $dispatchTimeoutReceipt.launchId -and $dispatchTimeoutReceipt.laneRole -ceq 'implementation' -and
    $dispatchTimeoutReceipt.routingRow -eq 7) 'implementation row-7 timeout records native exit alongside 124'
  Assert-True (-not (Test-Path (Join-Path $runtime 'verify-lock.d'))) 'implementation row-7 timeout releases the shared heavy lock'
  Write-Output 'PASS implementation row-7 timeout writes timed-out dispatch-lane receipt with native exit'

  $environmentMutantRuntime = Join-Path $root 'environment-mutant-runtime'
  Copy-Item -LiteralPath $runtime -Destination $environmentMutantRuntime -Recurse
  $environmentMutantRunner = Join-Path $environmentMutantRuntime 'workspace-db-test.mjs'
  $environmentMutantSource = Get-Content -LiteralPath $environmentMutantRunner -Raw
  $environmentMutantSource = $environmentMutantSource -replace '        await runWorkspaces\.loadTestEnvironment\(\{ includeTestDatabaseUrl: true \}\);', '        // MUTANT: skipped product test environment loading'
  [IO.File]::WriteAllText($environmentMutantRunner, $environmentMutantSource)
  Remove-Item -LiteralPath (Join-Path $artifacts 'file-args') -Force -ErrorAction SilentlyContinue
  $environmentMutantEntry = Start-Route (Join-Path $environmentMutantRuntime 'invoke-heavy-verifier.ps1') ((Common-Arguments '') + @('-WorkspaceDbTest','@chase-sets/payments','-WorkspaceDbTestFile',$validFile,'-WorkspaceDbBudgetSeconds','10'))
  Assert-True ($environmentMutantEntry.Process.WaitForExit(30000)) 'environment-loading mutant completed'
  $environmentMutantText = $environmentMutantEntry.Out.GetAwaiter().GetResult() + $environmentMutantEntry.Err.GetAwaiter().GetResult()
  Assert-True ($environmentMutantEntry.Process.ExitCode -ne 0 -and $environmentMutantText -match 'TEST_DATABASE_URL') 'environment-loading mutant was caught by the marker-required fixture'
  Write-Output 'PASS mutant that skips test-environment loading is caught by the marker-required fixture'

  $mutantRuntime = Join-Path $root 'mutant-runtime'
  Copy-Item -LiteralPath $runtime -Destination $mutantRuntime -Recurse
  $mutantGuard = Join-Path $mutantRuntime 'invoke-heavy-verifier.ps1'
  $mutantSource = Get-Content -LiteralPath $mutantGuard -Raw
  $mutantSource = $mutantSource -replace '(?m)^Assert-WorkspaceDbRoute\r?$', '$workspaceDbFile = "bounded-contexts/payments/features/payments/api/mutant.db.test.ts" # MUTANT: skipped file validation'
  [IO.File]::WriteAllText($mutantGuard, $mutantSource)
  $mutantRefusalCases = @(
    'bounded-contexts/payments/features/payments/api/mutant.db.test.ts',
    'bounded-contexts/ordering/features/payments/api/mutant.db.test.ts'
  )
  $mutantAccepted = $false
  foreach ($mutantFile in $mutantRefusalCases) {
    Remove-Item -LiteralPath (Join-Path $artifacts 'file-args') -Force -ErrorAction SilentlyContinue
    $mutantEntry = Start-Route $mutantGuard ((Common-Arguments '') + @('-WorkspaceDbTest','@chase-sets/payments','-WorkspaceDbTestFile',$mutantFile,'-WorkspaceDbBudgetSeconds','10'))
    $mutantText = Complete-Route $mutantEntry 0
    Assert-True (Test-Path (Join-Path $artifacts 'file-args')) "file-validation mutant did not turn refusal into acceptance for ${mutantFile}: $mutantText"
    $mutantAccepted = $true
  }
  Assert-True $mutantAccepted 'file-validation mutant did not turn any refusal into acceptance'
  Write-Output 'PASS mutant that skips file validation is caught by the pre-admission refusal assertion'
} finally {
  foreach ($entry in $children) {
    try {
      $process = $entry.Process
      if ($process -and -not $process.HasExited) {
        if ($process.StartTime.ToUniversalTime().Ticks -eq $entry.Start) { $process.Kill($true); [void]$process.WaitForExit(30000) }
      }
    } catch {}
  }
  if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}
