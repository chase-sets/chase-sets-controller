[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$guard = Join-Path $PSScriptRoot 'invoke-heavy-verifier.ps1'
function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw "ASSERTION FAILED: $Message" } }
function Invoke-Child([string[]]$Arguments, [hashtable]$Environment = @{}) {
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = Join-Path $PSHOME 'pwsh.exe'; $start.UseShellExecute = $false; $start.CreateNoWindow = $true
  $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
  foreach ($argument in $Arguments) { [void]$start.ArgumentList.Add([string]$argument) }
  foreach ($entry in $Environment.GetEnumerator()) { $start.Environment[$entry.Key] = [string]$entry.Value }
  $process = [Diagnostics.Process]::Start($start)
  $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync(); $process.WaitForExit()
  return [pscustomobject]@{ Code = $process.ExitCode; Stdout = $stdout.GetAwaiter().GetResult(); Stderr = $stderr.GetAwaiter().GetResult() }
}

$root = Join-Path ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) ('diagnostic-admission-' + [guid]::NewGuid().ToString('N'))
$container = Join-Path $root 'container'; $worktree = Join-Path $container 'lane'; $runtime = Join-Path $container '.orchestrator'
$artifactRoot = Join-Path $worktree '.orchestrator\artifacts'; $declarationPath = Join-Path $runtime 'diagnostic-declarations.json'; $lockRoot = Join-Path $runtime 'verify-lock.d'
New-Item -ItemType Directory -Path $worktree, $runtime, $artifactRoot -Force | Out-Null
function Invoke-FixtureGit([string[]]$Arguments) {
  $output = @(& git -C $worktree @Arguments 2>&1); if ($LASTEXITCODE -ne 0) { throw "fixture git failed: $($output -join "`n")" }; return ($output -join "`n").Trim()
}
function Get-Sha256([string]$Path) { return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($Path))).ToLowerInvariant() }
function Write-Declaration([string]$RelativePath, [string]$Hash, [double]$Maximum = 4, [bool]$Enabled = $true) {
  [IO.File]::WriteAllText($declarationPath, (@{ schema='host-heavy-diagnostic-declarations/v1'; diagnostics=@{ 'worst13-no-fit'=@{ enabled=$Enabled; kind='standalone-node'; path=$RelativePath; sha256=$Hash; maxBudgetSeconds=$Maximum } } } | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
}
function Invoke-Diagnostic([hashtable]$Overrides = @{}, [string]$MarkerName = 'marker', [hashtable]$ChildEnvironment = @{}) {
  $parameters = [ordered]@{ '-Diagnostic'='worst13-no-fit'; '-DiagnosticScriptPath'=$scriptRelative; '-DiagnosticSha256'=$scriptHash; '-DiagnosticBudgetSeconds'='2'; '-Worktree'=$worktree; '-Lane'='lane-test'; '-Branch'='codex/test'; '-ClaimedHead'=$head; '-ContainerRoot'=$container }
  foreach ($entry in $Overrides.GetEnumerator()) { if ($null -eq $entry.Value) { [void]$parameters.Remove($entry.Key) } else { $parameters[$entry.Key]=$entry.Value } }
  $args=@('-NoProfile','-NonInteractive','-File',$guard); foreach ($entry in $parameters.GetEnumerator()) { $args += @($entry.Key,[string]$entry.Value) }
  $marker=Join-Path $root "$MarkerName.marker"; $environment=@{ DIAGNOSTIC_MARKER=$marker; DIAGNOSTIC_PID=(Join-Path $root "$MarkerName.pid") }; foreach($entry in $ChildEnvironment.GetEnumerator()) { $environment[$entry.Key]=$entry.Value }; $result=Invoke-Child $args $environment
  return [pscustomobject]@{ Result=$result; Marker=$marker; PidPath=(Join-Path $root "$MarkerName.pid") }
}
function Assert-Refused([object]$Case, [string]$ExpectedText) {
  Assert-True ($Case.Result.Code -eq 73) "refused with documented code (actual=$($Case.Result.Code) stderr=$($Case.Result.Stderr))"
  Assert-True ($Case.Result.Stderr -match [regex]::Escape("heavy-verifier: $ExpectedText")) "exact refusal text '$ExpectedText' (stderr=$($Case.Result.Stderr))"
  Assert-True (-not (Test-Path -LiteralPath $Case.Marker)) 'fresh marker proves the diagnostic did not run'
  Assert-True (-not (Test-Path -LiteralPath $lockRoot)) 'refusal released no-acquisition lock'
}

try {
  Set-Content -LiteralPath (Join-Path $worktree '.gitignore') -Value '.orchestrator/'; Set-Content -LiteralPath (Join-Path $worktree 'seed.txt') -Value 'seed'
  Invoke-FixtureGit @('init','--initial-branch=codex/test') | Out-Null; Invoke-FixtureGit @('config','user.name','Diagnostic Admission Test') | Out-Null; Invoke-FixtureGit @('config','user.email','diagnostic-admission@example.invalid') | Out-Null
  Invoke-FixtureGit @('add','--','.') | Out-Null; Invoke-FixtureGit @('commit','-m','fixture') | Out-Null; $head=Invoke-FixtureGit @('rev-parse','HEAD')
  $scriptRelative='.orchestrator/artifacts/diagnostic-success.mjs'; $scriptPath=Join-Path $worktree ($scriptRelative -replace '/','\')
  Set-Content -LiteralPath $scriptPath -Value @'
import fs from 'node:fs';
import { spawn } from 'node:child_process';
const childEnv = { ...process.env };
const children = [1, 2].map(() => spawn(process.execPath, ['-e', 'process.exit(0)'], { windowsHide: true, env: childEnv }));
await Promise.all(children.map((child) => new Promise((resolve, reject) => { child.once('error', reject); child.once('exit', resolve); })));
fs.writeFileSync(process.env.DIAGNOSTIC_MARKER, 'ran-after-child');
fs.writeFileSync(new URL('./diagnostic-success.result.json', import.meta.url), 'result-written-during-run');
process.exitCode = 7;
'@
  $scriptHash=Get-Sha256 $scriptPath; Write-Declaration $scriptRelative $scriptHash

  $resultPath=Join-Path (Split-Path -Parent $scriptPath) 'diagnostic-success.result.json'; Set-Content -LiteralPath $resultPath -Value 'stale-result'
  $staleResult=Invoke-Diagnostic @{} 'stale-result'
  Assert-Refused $staleResult 'diagnostic result file already exists'; Remove-Item -LiteralPath $resultPath -Force
  Write-Output 'PASS diagnostic negative stale-result=1 fresh-marker=1'

  Set-Content -LiteralPath (Join-Path $root 'caller-node-options.cjs') -Value "require('node:fs').writeFileSync('$(Join-Path $root 'caller-node-options.marker')','ran')"
  $success=Invoke-Diagnostic @{} 'success' @{ NODE_OPTIONS="--require=$(Join-Path $root 'caller-node-options.cjs')" }; $receipt=@(Get-ChildItem -LiteralPath $artifactRoot -Filter 'host-heavy-diagnostic-*.json' -File)
  Assert-True ($success.Result.Code -eq 7 -and (Test-Path -LiteralPath $success.Marker)) "declared diagnostic runs (exit=$($success.Result.Code) stderr=$($success.Result.Stderr))"
  Assert-True ($receipt.Count -eq 1) 'declared diagnostic leaves one durable receipt'
  $successReceipt=Get-Content -LiteralPath $receipt[0].FullName -Raw | ConvertFrom-Json -DateKind String
  $resultHash=Get-Sha256 $resultPath
  Assert-True ($successReceipt.schema -ceq 'host-heavy-diagnostic/v1' -and $successReceipt.diagnostic.name -ceq 'worst13-no-fit' -and $successReceipt.diagnostic.kind -ceq 'standalone-node' -and $successReceipt.diagnostic.scriptPath -ceq $scriptRelative -and $successReceipt.diagnostic.sha256 -ceq $scriptHash -and $successReceipt.diagnostic.budgetSeconds -eq 2 -and $successReceipt.containerRoot -ceq ([IO.Path]::GetFullPath($container).TrimEnd('\','/')) -and $successReceipt.declarationSha256 -ceq $scriptHash -and $successReceipt.exit -eq 7 -and $successReceipt.nativeExit -eq 7 -and $successReceipt.timedOut -eq $false -and $successReceipt.resultSha256 -ceq $resultHash -and $successReceipt.resources.peakWorkingSetBytes -gt 0 -and $successReceipt.resources.jobPeakMemoryBytes -ge 0 -and $successReceipt.resources.jobTotalUserTime100ns -ge 0 -and $successReceipt.resources.jobTotalKernelTime100ns -ge 0 -and $successReceipt.resources.jobTotalProcesses -ge 3 -and -not (Test-Path -LiteralPath $lockRoot) -and -not (Test-Path -LiteralPath (Join-Path $root 'caller-node-options.marker'))) 'receipt, result hash, child resources and preload-only NODE_OPTIONS bind'
  Remove-Item -LiteralPath $resultPath -Force
  Write-Output 'PASS diagnostic declared route receipt=1 exit=7 nativeExit=7 resultSha256=1 jobTotalProcesses-ge-3=1 preload-only=1 released=1'

  $negatives=@(
    @{ Name='dotdot'; Override=@{ '-DiagnosticScriptPath'='.orchestrator/artifacts/../diagnostic-success.mjs' }; Text='diagnostic script must be a repository-relative standalone .mjs path' },
    @{ Name='absolute'; Override=@{ '-DiagnosticScriptPath'=$scriptPath }; Text='diagnostic script must be a repository-relative standalone .mjs path' },
    @{ Name='non-mjs'; Override=@{ '-DiagnosticScriptPath'='.orchestrator/artifacts/diagnostic-success.cjs' }; Text='diagnostic script must be a repository-relative standalone .mjs path' },
    @{ Name='infinity'; Override=@{ '-DiagnosticBudgetSeconds'='Infinity' }; Text='diagnostic budget must be finite and greater than zero' },
    @{ Name='negative'; Override=@{ '-DiagnosticBudgetSeconds'='-1' }; Text='diagnostic budget must be finite and greater than zero' },
    @{ Name='zero'; Override=@{ '-DiagnosticBudgetSeconds'='0' }; Text='diagnostic budget must be finite and greater than zero' },
    @{ Name='over-day'; Override=@{ '-DiagnosticBudgetSeconds'='86401' }; Text='diagnostic budget must be finite and greater than zero' },
    @{ Name='missing-budget'; Override=@{ '-DiagnosticBudgetSeconds'=$null }; Text='diagnostic budget is required' },
    @{ Name='above-max'; Override=@{ '-DiagnosticBudgetSeconds'='5' }; Text='diagnostic budget exceeds declared maximum' },
    @{ Name='hash-mismatch'; Override=@{ '-DiagnosticSha256'=('0'*64) }; Text='diagnostic SHA-256 does not match host declaration' },
    @{ Name='undeclared'; Override=@{ '-Diagnostic'='not-declared' }; Text='diagnostic name is not declared' },
    @{ Name='case-sensitive-name'; Override=@{ '-Diagnostic'='Worst13-no-fit' }; Text='diagnostic name is not declared' }
  )
  foreach($negative in $negatives) { Assert-Refused (Invoke-Diagnostic $negative.Override $negative.Name) $negative.Text }
  Write-Output 'PASS diagnostic negatives dotdot=1 absolute=1 non-mjs=1 Infinity=1 negative=1 zero=1 over-day=1 missing-budget=1 above-max=1 hash-mismatch=1 undeclared=1 case-sensitive=1 fresh-markers=12'

  $junctionTarget=Join-Path $root 'junction-target'; New-Item -ItemType Directory -Path $junctionTarget -Force | Out-Null; $junctionScript=Join-Path $junctionTarget 'diagnostic.mjs'; Set-Content -LiteralPath $junctionScript -Value "import fs from 'node:fs'; fs.writeFileSync(process.env.DIAGNOSTIC_MARKER, 'ran');"
  $junctionPath=Join-Path $worktree '.orchestrator\junction'; New-Item -ItemType Junction -Path $junctionPath -Target $junctionTarget | Out-Null; $junctionRelative='.orchestrator/junction/diagnostic.mjs'; $junctionHash=Get-Sha256 $junctionScript; Write-Declaration $junctionRelative $junctionHash
  Assert-Refused (Invoke-Diagnostic @{ '-DiagnosticScriptPath'=$junctionRelative; '-DiagnosticSha256'=$junctionHash } 'junction') 'diagnostic script path contains a reparse point'; Write-Output 'PASS diagnostic negative junction=1 fresh-marker=1'

  Write-Declaration $scriptRelative $scriptHash; $swapScript=Join-Path $root 'swap-diagnostic.ps1'; Set-Content -LiteralPath $swapScript -Value "Start-Sleep -Milliseconds 250; [IO.File]::WriteAllText('$scriptPath', 'import fs from ''node:fs''; fs.writeFileSync(process.env.DIAGNOSTIC_MARKER, ''swapped'');')"
  $swapProcess=Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList @('-NoProfile','-NonInteractive','-File',$swapScript) -WindowStyle Hidden -PassThru; $swapCase=Invoke-Diagnostic @{ '-TestDelayDiagnosticLaunchMilliseconds'='500' } 'hash-to-launch-swap'; $swapProcess.WaitForExit()
  Assert-Refused $swapCase 'declared diagnostic SHA-256 does not match the script'; Write-Output 'PASS diagnostic negative hash-to-launch-swap=1 fresh-marker=1'

  $trackedRelative='tracked-diagnostic-dependency.mjs'; $trackedPath=Join-Path $worktree $trackedRelative
  Set-Content -LiteralPath $trackedPath -Value "import fs from 'node:fs'; export const tracked = true; fs.writeFileSync(process.env.TRACKED_MARKER, 'tracked-ran');"
  Invoke-FixtureGit @('add','--',$trackedRelative) | Out-Null; Invoke-FixtureGit @('commit','-m','tracked diagnostic dependency') | Out-Null; $head=Invoke-FixtureGit @('rev-parse','HEAD')
  Set-Content -LiteralPath $scriptPath -Value "import '../../$trackedRelative'; import fs from 'node:fs'; fs.writeFileSync(process.env.DIAGNOSTIC_MARKER, 'tracked-entry-ran'); process.exitCode=7;"
  $scriptHash=Get-Sha256 $scriptPath; Write-Declaration $scriptRelative $scriptHash
  $trackedCase=Invoke-Diagnostic @{} 'tracked' @{ TRACKED_MARKER=(Join-Path $root 'tracked.marker') }
  $trackedReceipt=@(Get-ChildItem -LiteralPath $artifactRoot -Filter 'host-heavy-diagnostic-*.json' -File | Where-Object FullName -ne $receipt[0].FullName | Sort-Object LastWriteTimeUtc | Select-Object -Last 1)
  $trackedRecord=Get-Content -LiteralPath $trackedReceipt[0].FullName -Raw | ConvertFrom-Json -DateKind String
  $trackedModule=@($trackedRecord.modules | Where-Object path -like "*$trackedRelative")
  Assert-True ($trackedCase.Result.Code -eq 7 -and (Test-Path (Join-Path $root 'tracked.marker')) -and $trackedModule.Count -eq 1 -and $trackedModule[0].sha256 -ceq (Get-Sha256 $trackedPath)) 'tracked dependency is admitted and listed with loaded-byte hash in receipt'
  Write-Output 'PASS diagnostic dependency tracked=admitted receipt-listed=1 module-sha256=file-sha256=1'

  $ignoredRelative='.orchestrator/artifacts/node_modules/dep/index.mjs'; $ignoredPath=Join-Path $worktree ($ignoredRelative -replace '/','\'); $ignoredPackageRoot=Split-Path -Parent $ignoredPath
  New-Item -ItemType Directory -Path $ignoredPackageRoot -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $ignoredPackageRoot 'package.json') -Value '{"type":"module","main":"index.mjs"}'
  Set-Content -LiteralPath $ignoredPath -Value "import fs from 'node:fs'; fs.writeFileSync(process.env.IGNORED_MARKER, 'ignored-ran');"
  Set-Content -LiteralPath $scriptPath -Value "import 'dep'; import fs from 'node:fs'; fs.writeFileSync(process.env.DIAGNOSTIC_MARKER, 'ignored-entry-ran');"
  $scriptHash=Get-Sha256 $scriptPath; Write-Declaration $scriptRelative $scriptHash
  $ignoredCase=Invoke-Diagnostic @{} 'ignored' @{ IGNORED_MARKER=(Join-Path $root 'ignored.marker') }
  $ignoredRefusal="heavy-admission: diagnostic module was not tracked at the bound head or under an admitted node_modules directory: $([IO.Path]::GetFullPath($ignoredPath))"
  $ignoredStderrLines=@($ignoredCase.Result.Stderr.Trim() -split '\r?\n')
  Assert-True ($ignoredCase.Result.Code -eq 73 -and $ignoredStderrLines[0] -ceq $ignoredRefusal -and -not (Test-Path (Join-Path $root 'ignored.marker'))) 'ignored nested dependency is refused before its body runs with exact refusal text'
  Write-Output 'PASS diagnostic dependency ignored-nested-node_modules=refused exit=73 exact-text=1 body=not-run'

  $childRefusalRelative='.orchestrator/artifacts/child-refusal.mjs'; $childRefusalPath=Join-Path $worktree ($childRefusalRelative -replace '/','\')
  Set-Content -LiteralPath $childRefusalPath -Value "import { spawn } from 'node:child_process'; const childEnv={...process.env}; delete childEnv.NODE_OPTIONS; spawn(process.execPath, ['-e', ''], { env: childEnv }); import fs from 'node:fs'; fs.writeFileSync(process.env.DIAGNOSTIC_MARKER, 'child-ran');"
  $scriptRelative=$childRefusalRelative; $scriptPath=$childRefusalPath; $scriptHash=Get-Sha256 $scriptPath; Write-Declaration $scriptRelative $scriptHash
  $childRefusal=Invoke-Diagnostic @{} 'child-refusal'
  Assert-True ($childRefusal.Result.Code -ne 0 -and $childRefusal.Result.Stderr -match [regex]::Escape('heavy-admission: diagnostic child process launch refused because NODE_OPTIONS lacks the diagnostic preload') -and -not (Test-Path $childRefusal.Marker)) 'child process without preload is refused'
  Write-Output 'PASS diagnostic child-without-preload=refused marker=absent'

  $workerRefusalRelative='.orchestrator/artifacts/worker-refusal.mjs'; $workerRefusalPath=Join-Path $worktree ($workerRefusalRelative -replace '/','\')
  Set-Content -LiteralPath $workerRefusalPath -Value "import { Worker } from 'node:worker_threads'; new Worker('setTimeout(() => {}, 10)', { eval: true }); import fs from 'node:fs'; fs.writeFileSync(process.env.DIAGNOSTIC_MARKER, 'worker-ran');"
  $scriptRelative=$workerRefusalRelative; $scriptPath=$workerRefusalPath; $scriptHash=Get-Sha256 $scriptPath; Write-Declaration $scriptRelative $scriptHash
  $workerRefusal=Invoke-Diagnostic @{} 'worker-refusal'
  Assert-True ($workerRefusal.Result.Code -ne 0 -and $workerRefusal.Result.Stderr -match [regex]::Escape('heavy-admission: diagnostic Worker launch refused') -and -not (Test-Path $workerRefusal.Marker)) 'Worker launch is refused'
  Write-Output 'PASS diagnostic worker=refused marker=absent'

  $manifestRemovalRelative='.orchestrator/artifacts/manifest-removal.mjs'; $manifestRemovalPath=Join-Path $worktree ($manifestRemovalRelative -replace '/','\')
  Set-Content -LiteralPath $manifestRemovalPath -Value @'
import fs from 'node:fs';
const configuration = JSON.parse(Buffer.from(process.env.CHASE_SETS_HEAVY_ADMISSION_CONFIG, 'base64').toString('utf8'));
fs.rmSync(`${configuration.diagnostic.moduleManifestPath}-${process.pid}.json`, { force: true });
'@
  $scriptRelative=$manifestRemovalRelative; $scriptPath=$manifestRemovalPath; $scriptHash=Get-Sha256 $scriptPath; Write-Declaration $scriptRelative $scriptHash
  $missingManifest=Invoke-Diagnostic @{} 'missing-manifest'
  Assert-Refused $missingManifest 'diagnostic module manifest is missing'
  Write-Output 'PASS diagnostic manifest=missing exit=73 no-success=1'

  $manifestEntryRelative='.orchestrator/artifacts/manifest-no-entry.mjs'; $manifestEntryPath=Join-Path $worktree ($manifestEntryRelative -replace '/','\')
  Set-Content -LiteralPath $manifestEntryPath -Value @'
import fs from 'node:fs';
const configuration = JSON.parse(Buffer.from(process.env.CHASE_SETS_HEAVY_ADMISSION_CONFIG, 'base64').toString('utf8'));
fs.writeFileSync(`${configuration.diagnostic.moduleManifestPath}-${process.pid}.json`, JSON.stringify({ schema: 'host-heavy-diagnostic-modules/v1', modules: [] }));
'@
  $scriptRelative=$manifestEntryRelative; $scriptPath=$manifestEntryPath; $scriptHash=Get-Sha256 $scriptPath; Write-Declaration $scriptRelative $scriptHash
  $manifestWithoutEntry=Invoke-Diagnostic @{} 'manifest-without-entry'
  Assert-Refused $manifestWithoutEntry 'diagnostic module manifest did not record the declared entry'
  Write-Output 'PASS diagnostic manifest=without-entry exit=73 no-success=1'

  $timeoutRelative='.orchestrator/artifacts/diagnostic-timeout.mjs'; $timeoutPath=Join-Path $worktree ($timeoutRelative -replace '/','\'); Set-Content -LiteralPath $timeoutPath -Value @'
import fs from 'node:fs';
import { spawn } from 'node:child_process';
const childEnv = { ...process.env };
const child = spawn(process.execPath, ['-e', 'setTimeout(() => {}, 120000)'], { detached: true, windowsHide: true, env: childEnv });
child.unref();
fs.writeFileSync(process.env.DIAGNOSTIC_PID, String(child.pid));
setTimeout(() => process.exit(0), 1000);
'@
  $timeoutHash=Get-Sha256 $timeoutPath; Write-Declaration $timeoutRelative $timeoutHash 4; $timeout=Invoke-Diagnostic @{ '-DiagnosticScriptPath'=$timeoutRelative; '-DiagnosticSha256'=$timeoutHash; '-DiagnosticBudgetSeconds'='3' } 'timeout'
  Assert-True ($timeout.Result.Code -eq 124) "timeout uses documented exit 124 (actual=$($timeout.Result.Code) stderr=$($timeout.Result.Stderr))"; $timeoutReceipt=@(Get-ChildItem -LiteralPath $artifactRoot -Filter 'host-heavy-diagnostic-*.json' -File | Sort-Object LastWriteTimeUtc | Select-Object -Last 1); $timeoutRecord=Get-Content -LiteralPath $timeoutReceipt[0].FullName -Raw | ConvertFrom-Json -DateKind String; $timeoutPid=[int](Get-Content -LiteralPath $timeout.PidPath -Raw)
  Assert-True ($timeoutReceipt.Count -eq 1 -and $timeoutRecord.timedOut -eq $true -and $timeoutRecord.exit -eq 124 -and $timeoutRecord.nativeExit -eq 0 -and $timeoutRecord.elapsedMs -ge 2900 -and $timeoutRecord.elapsedMs -lt 6000 -and -not (Get-Process -Id $timeoutPid -ErrorAction SilentlyContinue) -and -not (Test-Path -LiteralPath $lockRoot)) "timeout kills lingering descendant after root native exit 0 within budget bound (receipts=$($timeoutReceipt.Count) timedOut=$($timeoutRecord.timedOut) exit=$($timeoutRecord.exit) nativeExit=$($timeoutRecord.nativeExit) elapsed=$($timeoutRecord.elapsedMs) childAlive=$([bool](Get-Process -Id $timeoutPid -ErrorAction SilentlyContinue)) lock=$([bool](Test-Path -LiteralPath $lockRoot)))"
  Write-Output 'PASS diagnostic timeout root-nativeExit=0 descendant-sleep=120s timedOut=true exit=124 descendant-dead=1 bounded=1 released=1'

  $outside=Invoke-Diagnostic @{ '-ContainerRoot'=(Get-Location).Path } 'outside-container'
  Assert-Refused $outside 'arbitrary commands are fixture-only; use invoke-heavy-verifier.ps1 -Gate or -WorkspaceTest'
  Write-Output 'PASS diagnostic negative outside-container=1 fresh-marker=1'

  $safeRelative='.orchestrator/unsafe-receipt.mjs'; $safePath=Join-Path $worktree ($safeRelative -replace '/','\'); Set-Content -LiteralPath $safePath -Value "import fs from 'node:fs'; fs.writeFileSync(process.env.DIAGNOSTIC_MARKER, 'unsafe-body-ran');"; $safeHash=Get-Sha256 $safePath; Write-Declaration $safeRelative $safeHash
  Remove-Item -LiteralPath $artifactRoot -Recurse -Force; Set-Content -LiteralPath $artifactRoot -Value 'not-a-directory'
  $unsafe=Invoke-Diagnostic @{ '-DiagnosticScriptPath'=$safeRelative; '-DiagnosticSha256'=$safeHash } 'unsafe-receipt'
  Assert-True ($unsafe.Result.Code -eq 73 -and $unsafe.Result.Stderr.Trim() -ceq 'heavy-verifier: receipt directory is unsafe' -and -not (Test-Path (Join-Path $root 'unsafe-receipt.marker'))) 'unsafe receipt path is refused with exact text and diagnostic body is not run'
  Write-Output 'PASS diagnostic negative unsafe-receipt=1 exact-text=1 no-success=1'
} finally { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue } }
