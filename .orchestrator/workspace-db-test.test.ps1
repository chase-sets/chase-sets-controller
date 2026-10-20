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
function Start-Route([string]$GuardPath, [string[]]$Arguments) {
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
function Common-Arguments([string]$GuardPath) {
  @('-Worktree', $worktree, '-Lane', 'workspace-db-test', '-ImmutableHead', $head)
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

  $invalid = @(
    @{Name='unknown-workspace'; Extra=@('-WorkspaceDbTest','@chase-sets/ordering','-WorkspaceDbBudgetSeconds','10'); Text='ValidateSet'},
    @{Name='outside-workspace'; Extra=@('-WorkspaceDbTest','@chase-sets/payments','-WorkspaceDbTestFile','bounded-contexts/ordering/foo.db.test.ts','-WorkspaceDbBudgetSeconds','10'); Text='normalized repository-relative payments'},
    @{Name='dotdot'; Extra=@('-WorkspaceDbTest','@chase-sets/payments','-WorkspaceDbTestFile','bounded-contexts/payments/../ordering/foo.db.test.ts','-WorkspaceDbBudgetSeconds','10'); Text='normalized repository-relative payments'},
    @{Name='absolute'; Extra=@('-WorkspaceDbTest','@chase-sets/payments','-WorkspaceDbTestFile',(Join-Path $worktree $validFile),'-WorkspaceDbBudgetSeconds','10'); Text='normalized repository-relative payments'},
    @{Name='wrong-extension'; Extra=@('-WorkspaceDbTest','@chase-sets/payments','-WorkspaceDbTestFile','bounded-contexts/payments/tests/not-a-db.test.ts','-WorkspaceDbBudgetSeconds','10'); Text='normalized repository-relative payments'},
    @{Name='untracked'; Extra=@('-WorkspaceDbTest','@chase-sets/payments','-WorkspaceDbTestFile','bounded-contexts/payments/features/payments/api/untracked.db.test.ts','-WorkspaceDbBudgetSeconds','10'); Text='not tracked'},
    @{Name='above-max'; Extra=@('-WorkspaceDbTest','@chase-sets/payments','-WorkspaceDbBudgetSeconds','901'); Text='no more than 900'}
  )
  Set-Content -LiteralPath (Join-Path $worktree 'bounded-contexts/payments/features/payments/api/untracked.db.test.ts') 'export {}'
  foreach ($case in $invalid) {
    $entry = Start-Route (Join-Path $runtime 'invoke-heavy-verifier.ps1') ((Common-Arguments '') + $case.Extra)
    Assert-True ($entry.Process.WaitForExit(30000)) "$($case.Name) refusal completed"
    $text = $entry.Out.GetAwaiter().GetResult() + $entry.Err.GetAwaiter().GetResult()
    Assert-True ($entry.Process.ExitCode -ne 0) "$($case.Name) has a nonzero refusal exit"
    Assert-True ($text -match [regex]::Escape($case.Text)) "$($case.Name) gives its closed refusal"
    Assert-True (-not (Test-Path (Join-Path $runtime 'verify-lock.d'))) "$($case.Name) refused before lock admission"
  }
  Remove-Item -LiteralPath (Join-Path $worktree 'bounded-contexts/payments/features/payments/api/untracked.db.test.ts') -Force
  Assert-True (@(Get-Receipts).Count -eq 2) 'invalid requests create no receipt'
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
  $mutantFile = 'bounded-contexts/payments/features/payments/api/mutant.db.test.ts'
  Remove-Item -LiteralPath (Join-Path $artifacts 'file-args') -Force -ErrorAction SilentlyContinue
  $mutantEntry = Start-Route $mutantGuard ((Common-Arguments '') + @('-WorkspaceDbTest','@chase-sets/payments','-WorkspaceDbTestFile',$mutantFile,'-WorkspaceDbBudgetSeconds','10'))
  $mutantText = Complete-Route $mutantEntry 0
  $mutantCaught = $false
  try {
    Assert-True (-not (Test-Path (Join-Path $artifacts 'file-args'))) 'file-validation mutant escaped the pre-admission refusal assertion'
  } catch { $mutantCaught = $true }
  Assert-True $mutantCaught 'file-validation mutant was caught by the focused refusal assertion'
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
