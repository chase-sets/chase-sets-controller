param([switch]$ClassifierOnly, [switch]$IdentityOnly, [switch]$DerivedOnly, [switch]$LaneEvolutionOnly, [switch]$E2eGateOnly, [switch]$AcceptAnyHeadMutant, [string]$GuardRevision = '')

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot 'routing-data-test-support.ps1')
$routingTestScope=Enter-RoutingDataTestScope
try {

$preloadSource = Join-Path $PSScriptRoot "heavy-admission-preload.cjs"
$clientSource = Join-Path $PSScriptRoot "heavy-slot.cjs"
$guardSource = Join-Path $PSScriptRoot "invoke-heavy-verifier.ps1"
$launcherSource = Join-Path $PSScriptRoot "heavy-admission-holder-launcher.cjs"
$node = Get-Command node -CommandType Application -ErrorAction Stop |
  Select-Object -First 1 -ExpandProperty Source
$pnpmCommandShim = Get-Command pnpm -All -ErrorAction Stop |
  Where-Object { $_.Source -like "*\pnpm.CMD" } |
  Select-Object -First 1
$pnpmCommandText = Get-Content -LiteralPath $pnpmCommandShim.Source -Raw
if ($pnpmCommandText -notmatch '"%~dp0\\(?<relative>[^"]*\\pnpm\.exe)"') {
  throw "unable to resolve the active pnpm.CMD direct binary"
}
$nativePnpm = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $pnpmCommandShim.Source) $Matches.relative))
$alternatePnpm = Get-Command pnpm.exe -All -CommandType Application -ErrorAction Stop |
  Where-Object { -not [string]::Equals([IO.Path]::GetFullPath($_.Source), $nativePnpm, [StringComparison]::OrdinalIgnoreCase) } |
  Select-Object -First 1 -ExpandProperty Source
$pwsh = Get-Command pwsh -CommandType Application -ErrorAction Stop |
  Select-Object -First 1 -ExpandProperty Source
$systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd("\", "/")
$root = Join-Path $systemTemp ("heavy-admission-test-" + [guid]::NewGuid().ToString("N"))
$privateTemp = Join-Path $root "fixture-temp"
$container = Join-Path $root "container with spaces"
$orchestrator = Join-Path $container ".orchestrator"
$preload = Join-Path $orchestrator "heavy-admission-preload.cjs"
$preloadForNode = $preload.Replace("\", "/")
$client = Join-Path $orchestrator "heavy-slot.cjs"
$guard = Join-Path $orchestrator "invoke-heavy-verifier.ps1"
$launcher = Join-Path $orchestrator "heavy-admission-holder-launcher.cjs"
$lock = Join-Path $orchestrator "verify-lock.d"
$ownerPath = Join-Path $lock "owner.json"
$laneA = Join-Path $container "lane-a"
$laneB = Join-Path $container "lane-b"
$startedProcesses = [Collections.Generic.List[object]]::new()
$descendantRelease = $null
New-Item -ItemType Directory -Path $orchestrator, $laneA, $laneB, $privateTemp | Out-Null
Copy-Item -LiteralPath $preloadSource -Destination $preload
Copy-Item -LiteralPath $clientSource -Destination $client
Copy-Item -LiteralPath $guardSource -Destination $guard
if ($GuardRevision) {
  $baseline = @(& git -C (Split-Path -Parent $PSScriptRoot) show "${GuardRevision}:.orchestrator/invoke-heavy-verifier.ps1")
  if ($LASTEXITCODE -ne 0) { throw 'unable to read baseline guard' }
  Set-Content -LiteralPath $guard -Value $baseline
}
Copy-Item -LiteralPath $launcherSource -Destination $launcher
foreach ($dependency in @("heavy-nested-owner.cs", "heavy-nested-client.cjs", "dispatch-ownership.ps1")) {
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot $dependency) -Destination (Join-Path $orchestrator $dependency)
}

function Assert-True($Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}
function Invoke-RepoGit([string]$Worktree, [string[]]$Arguments) {
  $output = @(& git -C $Worktree @Arguments 2>&1)
  if ($LASTEXITCODE -ne 0) {
    throw "fixture git command failed in '$Worktree': git $($Arguments -join ' ')`n$($output -join "`n")"
  }
  return ($output -join "`n").Trim()
}
function Assert-DisposableRoot {
  $resolved = [IO.Path]::GetFullPath($root).TrimEnd("\", "/")
  Assert-True ($resolved.StartsWith($systemTemp + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) "test root stays below system temp"
  Assert-True ((Split-Path -Leaf $resolved) -like "heavy-admission-test-*") "test root has the owned safety prefix"
}
function Wait-Condition([scriptblock]$Condition, [string]$Message, [int]$Attempts = 600) {
  for ($attempt = 0; $attempt -lt $Attempts; $attempt++) {
    if (& $Condition) { return }
    Start-Sleep -Milliseconds 25
  }
  throw "ASSERTION FAILED: timed out waiting for $Message"
}
function Read-Owner {
  if (-not (Test-Path -LiteralPath $ownerPath -PathType Leaf)) { return $null }
  try {
    return Get-Content -LiteralPath $ownerPath -Raw -ErrorAction Stop |
      ConvertFrom-Json -DateKind String -ErrorAction Stop
  } catch {
    return $null
  }
}
function Test-ExactProcess($Identity) {
  try {
    $candidate = Get-Process -Id ([int]$Identity.pid) -ErrorAction Stop
    return $candidate.StartTime.ToUniversalTime().Ticks -eq
      [DateTimeOffset]::Parse([string]$Identity.processStartUtc).ToUniversalTime().Ticks
  } catch {
    return $false
  }
}
function Stop-ExactProcess($Identity) {
  Assert-True (Test-ExactProcess $Identity) "cleanup target retains its exact PID/start identity"
  $candidate = Get-Process -Id ([int]$Identity.pid) -ErrorAction Stop
  Stop-Process -InputObject $candidate -Force
  $candidate.WaitForExit()
}
function Set-CleanAdmissionEnvironment([Diagnostics.ProcessStartInfo]$Start) {
  if ($Start.Environment.ContainsKey("CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_NODE_OPTIONS")) {
    $originalNodeOptions = $Start.Environment["CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_NODE_OPTIONS"]
    if ([string]::IsNullOrEmpty($originalNodeOptions)) {
      [void]$Start.Environment.Remove("NODE_OPTIONS")
    } else {
      $Start.Environment["NODE_OPTIONS"] = $originalNodeOptions
    }
  }
  if ($Start.Environment.ContainsKey("CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_SCRIPT_SHELL")) {
    $originalScriptShell = $Start.Environment["CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_SCRIPT_SHELL"]
    if ([string]::IsNullOrEmpty($originalScriptShell)) {
      [void]$Start.Environment.Remove("npm_config_script_shell")
    } else {
      $Start.Environment["npm_config_script_shell"] = $originalScriptShell
    }
  }
  foreach ($name in @(
      "CHASE_SETS_HEAVY_ADMISSION_CONFIG",
      "CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_NODE_OPTIONS",
      "CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_SCRIPT_SHELL",
      "CHASE_SETS_HEAVY_ADMISSION_PNPM_SCRIPT_SHELL",
      "CHASE_SETS_HEAVY_SLOT_ID",
      "CHASE_SETS_HEAVY_ADMISSION_WARNED_ROOT"
    )) {
    [void]$Start.Environment.Remove($name)
  }
  $Start.Environment["TEMP"] = $privateTemp
  $Start.Environment["TMP"] = $privateTemp
}
function Assert-FreshChildEnvironmentBoundary {
  $admissionNames = @(
    "NODE_OPTIONS",
    "npm_config_script_shell",
    "CHASE_SETS_HEAVY_ADMISSION_CONFIG",
    "CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_NODE_OPTIONS",
    "CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_SCRIPT_SHELL",
    "CHASE_SETS_HEAVY_ADMISSION_PNPM_SCRIPT_SHELL",
    "CHASE_SETS_HEAVY_SLOT_ID"
  )
  $names = @($admissionNames) + @("TEMP", "TMP")
  $parentBefore = [Environment]::GetEnvironmentVariables("Process")
  $probe = [Diagnostics.ProcessStartInfo]::new()
  $probe.Environment["CHASE_SETS_HEAVY_SLOT_ID"] = "0123456789abcdef0123456789abcdef"
  $probe.Environment["CHASE_SETS_HEAVY_ADMISSION_CONFIG"] = "synthetic-config"
  $probe.Environment["CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_NODE_OPTIONS"] = "--synthetic-original-node"
  $probe.Environment["CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_SCRIPT_SHELL"] = "synthetic-original-shell"
  $probe.Environment["CHASE_SETS_HEAVY_ADMISSION_PNPM_SCRIPT_SHELL"] = "node-check-proxy"
  $probe.Environment["NODE_OPTIONS"] = "--require synthetic-heavy-preload.cjs"
  $probe.Environment["npm_config_script_shell"] = "node-check-proxy"
  $probe.Environment["TEMP"] = "synthetic-TEMP"
  $probe.Environment["TMP"] = "synthetic-TMP"
  Set-CleanAdmissionEnvironment $probe
  foreach ($name in @(
      "CHASE_SETS_HEAVY_SLOT_ID",
      "CHASE_SETS_HEAVY_ADMISSION_CONFIG",
      "CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_NODE_OPTIONS",
      "CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_SCRIPT_SHELL",
      "CHASE_SETS_HEAVY_ADMISSION_PNPM_SCRIPT_SHELL"
    )) {
    Assert-True (-not $probe.Environment.ContainsKey($name)) "fresh child retained admission marker $name"
  }
  Assert-True ($probe.Environment["NODE_OPTIONS"] -ceq "--synthetic-original-node") `
    "fresh child did not restore original Node options"
  Assert-True ($probe.Environment["npm_config_script_shell"] -ceq "synthetic-original-shell") `
    "fresh child did not restore original script shell"
  Assert-True ($probe.Environment["TEMP"] -ceq $privateTemp) "fresh child TEMP uses the private fixture directory"
  Assert-True ($probe.Environment["TMP"] -ceq $privateTemp) "fresh child TMP uses the private fixture directory"
  $parentAfter = [Environment]::GetEnvironmentVariables("Process")
  foreach ($name in $names) {
    Assert-True ($parentAfter.Contains($name) -eq $parentBefore.Contains($name)) `
      "fresh-child scrub changed parent presence for $name"
    if ($parentBefore.Contains($name)) {
      Assert-True ([string]$parentAfter[$name] -ceq [string]$parentBefore[$name]) `
        "fresh-child scrub changed parent value for $name"
    }
  }
}
function New-AdmissionConfiguration(
  [string]$Worktree,
  [string]$Lane,
  [hashtable]$Identity = @{}
) {
  $configuration = [ordered]@{
    schemaVersion = 1
    guardPath = [IO.Path]::GetFullPath($guard)
    powershellPath = [IO.Path]::GetFullPath($pwsh)
    containerRoot = [IO.Path]::GetFullPath($container)
    worktree = [IO.Path]::GetFullPath($Worktree)
    lane = $Lane
    originalNodeOptionsPresent = $false
    originalNodeOptions = ""
    originalScriptShellPresent = $false
    originalScriptShell = ""
  }
  if ($Identity.ContainsKey("ImmutableHead")) {
    $configuration.immutableHead = [string]$Identity.ImmutableHead
  } else {
    $configuration.branch = $(if ($Identity.ContainsKey("Branch")) { [string]$Identity.Branch } else { "codex/$Lane" })
    $configuration.head = $(if ($Identity.ContainsKey("ClaimedHead")) {
      [string]$Identity.ClaimedHead
    } else {
      Invoke-RepoGit $Worktree @("rev-parse", "HEAD")
    })
  }
  return [Convert]::ToBase64String(
    [Text.Encoding]::UTF8.GetBytes(($configuration | ConvertTo-Json -Compress))
  )
}
function Start-NodeFixture(
  [string]$Script,
  [string[]]$Arguments,
  [string]$Worktree,
  [string]$Lane,
  [string]$Marker,
  [int]$DelayMilliseconds = 0,
  [hashtable]$ExtraEnvironment = @{},
  [hashtable]$AdmissionIdentity = @{},
  [switch]$Derived
) {
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = $node
  $start.WorkingDirectory = $Worktree
  $start.UseShellExecute = $false
  $start.CreateNoWindow = $true
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  Set-CleanAdmissionEnvironment $start
  [void]$start.ArgumentList.Add($Script)
  foreach ($argument in $Arguments) { [void]$start.ArgumentList.Add($argument) }
  $start.Environment["NODE_OPTIONS"] = "--require=`"$preloadForNode`""
  if (-not $Derived) {
    $start.Environment["CHASE_SETS_HEAVY_ADMISSION_CONFIG"] = New-AdmissionConfiguration $Worktree $Lane $AdmissionIdentity
    $start.Environment["CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_NODE_OPTIONS"] = ""
  }
  $start.Environment["ADMISSION_MARKER"] = $Marker
  $start.Environment["ADMISSION_DELAY_MS"] = "$DelayMilliseconds"
  foreach ($entry in $ExtraEnvironment.GetEnumerator()) {
    $start.Environment[$entry.Key] = [string]$entry.Value
  }
  $process = [Diagnostics.Process]::Start($start)
  $identity = [pscustomobject]@{
    pid = $process.Id
    processStartUtc = $process.StartTime.ToUniversalTime().ToString("o")
  }
  $startedProcesses.Add([pscustomobject]@{ Process = $process; Identity = $identity })
  return [pscustomobject]@{ Process = $process; Identity = $identity }
}
function Start-ShimFixture(
  [string]$Shim,
  [string]$Worktree,
  [string]$Lane,
  [string]$Marker
) {
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = $env:ComSpec
  $start.WorkingDirectory = $Worktree
  $start.UseShellExecute = $false
  $start.CreateNoWindow = $true
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  Set-CleanAdmissionEnvironment $start
  [void]$start.ArgumentList.Add("/d")
  [void]$start.ArgumentList.Add("/c")
  [void]$start.ArgumentList.Add($Shim)
  $start.Environment["NODE_OPTIONS"] = "--require=`"$preloadForNode`""
  $start.Environment["CHASE_SETS_HEAVY_ADMISSION_CONFIG"] = New-AdmissionConfiguration $Worktree $Lane
  $start.Environment["CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_NODE_OPTIONS"] = ""
  $start.Environment["ADMISSION_MARKER"] = $Marker
  $start.Environment["ADMISSION_DELAY_MS"] = "0"
  $start.Environment["ADMISSION_NODE"] = $node
  $start.Environment["ADMISSION_PNPM"] = $pnpmScript
  $process = [Diagnostics.Process]::Start($start)
  $identity = [pscustomobject]@{
    pid = $process.Id
    processStartUtc = $process.StartTime.ToUniversalTime().ToString("o")
  }
  $startedProcesses.Add([pscustomobject]@{ Process = $process; Identity = $identity })
  return [pscustomobject]@{ Process = $process; Identity = $identity }
}
function Start-NativePnpmFixture(
  [string]$Worktree,
  [string]$Lane,
  [string]$ScriptName = "verify:static",
  [string]$Marker = "",
  [string]$Output = ""
) {
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = $nativePnpm
  $start.WorkingDirectory = $Worktree
  $start.UseShellExecute = $false
  $start.CreateNoWindow = $true
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  Set-CleanAdmissionEnvironment $start
  [void]$start.ArgumentList.Add("run")
  [void]$start.ArgumentList.Add($ScriptName)
  $start.Environment["NODE_OPTIONS"] = "--require=`"$preloadForNode`""
  $start.Environment["npm_config_script_shell"] = $node
  $start.Environment["CHASE_SETS_HEAVY_ADMISSION_CONFIG"] = New-AdmissionConfiguration $Worktree $Lane
  $start.Environment["CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_NODE_OPTIONS"] = ""
  $start.Environment["CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_SCRIPT_SHELL"] = ""
  $start.Environment["CHASE_SETS_HEAVY_ADMISSION_PNPM_SCRIPT_SHELL"] = "node-check-proxy"
  if ($Marker) { $start.Environment["ADMISSION_MARKER"] = $Marker }
  if ($Output) { $start.Environment["ADMISSION_OUTPUT"] = $Output }
  $process = [Diagnostics.Process]::Start($start)
  $identity = [pscustomobject]@{
    pid = $process.Id
    processStartUtc = $process.StartTime.ToUniversalTime().ToString("o")
  }
  $startedProcesses.Add([pscustomobject]@{ Process = $process; Identity = $identity })
  return [pscustomobject]@{ Process = $process; Identity = $identity }
}
function Start-RootPnpmFixture(
  [string]$Worktree,
  [string]$Lane,
  [string]$ScriptName,
  [string]$Marker,
  [string]$Output,
  [hashtable]$ExtraEnvironment = @{}
) {
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = $env:ComSpec
  $start.WorkingDirectory = $Worktree
  $start.UseShellExecute = $false
  $start.CreateNoWindow = $true
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  Set-CleanAdmissionEnvironment $start
  [void]$start.ArgumentList.Add("/d")
  [void]$start.ArgumentList.Add("/c")
  [void]$start.ArgumentList.Add($pnpmCommandShim.Source)
  [void]$start.ArgumentList.Add("run")
  [void]$start.ArgumentList.Add($ScriptName)
  $start.Environment["NODE_OPTIONS"] = "--require=`"$preloadForNode`""
  $start.Environment["npm_config_script_shell"] = $node
  $start.Environment["CHASE_SETS_HEAVY_ADMISSION_CONFIG"] = New-AdmissionConfiguration $Worktree $Lane
  $start.Environment["CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_NODE_OPTIONS"] = ""
  $start.Environment["CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_SCRIPT_SHELL"] = ""
  $start.Environment["CHASE_SETS_HEAVY_ADMISSION_PNPM_SCRIPT_SHELL"] = "node-check-proxy"
  $start.Environment["ADMISSION_MARKER"] = $Marker
  $start.Environment["ADMISSION_OUTPUT"] = $Output
  foreach ($entry in $ExtraEnvironment.GetEnumerator()) {
    $start.Environment[$entry.Key] = [string]$entry.Value
  }
  $process = [Diagnostics.Process]::Start($start)
  $identity = [pscustomobject]@{
    pid = $process.Id
    processStartUtc = $process.StartTime.ToUniversalTime().ToString("o")
  }
  $startedProcesses.Add([pscustomobject]@{ Process = $process; Identity = $identity })
  return [pscustomobject]@{ Process = $process; Identity = $identity }
}
function Start-LifecycleFixture(
  [string]$Worktree,
  [string]$Lane,
  [string]$Marker,
  [string]$Output
) {
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = $node
  $start.WorkingDirectory = $Worktree
  $start.UseShellExecute = $false
  $start.CreateNoWindow = $true
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  Set-CleanAdmissionEnvironment $start
  [void]$start.ArgumentList.Add("-c")
  [void]$start.ArgumentList.Add((Join-Path $Worktree "scripts\browser-e2e-probe.mjs"))
  $start.Environment["NODE_OPTIONS"] = "--require=`"$preloadForNode`""
  $start.Environment["CHASE_SETS_HEAVY_ADMISSION_CONFIG"] = New-AdmissionConfiguration $Worktree $Lane
  $start.Environment["CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_NODE_OPTIONS"] = ""
  $start.Environment["CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_SCRIPT_SHELL"] = ""
  $start.Environment["CHASE_SETS_HEAVY_ADMISSION_PNPM_SCRIPT_SHELL"] = "node-check-proxy"
  $start.Environment["npm_lifecycle_event"] = "dev:e2e:probe"
  $start.Environment["npm_lifecycle_script"] = "node ./scripts/browser-e2e-probe.mjs"
  $start.Environment["ADMISSION_MARKER"] = $Marker
  $start.Environment["ADMISSION_OUTPUT"] = $Output
  $process = [Diagnostics.Process]::Start($start)
  $identity = [pscustomobject]@{
    pid = $process.Id
    processStartUtc = $process.StartTime.ToUniversalTime().ToString("o")
  }
  $startedProcesses.Add([pscustomobject]@{ Process = $process; Identity = $identity })
  return [pscustomobject]@{ Process = $process; Identity = $identity }
}
function Start-AlternatePnpmFixture(
  [string]$Worktree,
  [string]$Lane,
  [string]$ScriptName,
  [string]$Marker
) {
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = $alternatePnpm
  $start.WorkingDirectory = $Worktree
  $start.UseShellExecute = $false
  $start.CreateNoWindow = $true
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  Set-CleanAdmissionEnvironment $start
  [void]$start.ArgumentList.Add("run")
  [void]$start.ArgumentList.Add($ScriptName)
  $start.Environment["NODE_OPTIONS"] = "--require=`"$preloadForNode`""
  $start.Environment["npm_config_script_shell"] = $node
  $start.Environment["CHASE_SETS_HEAVY_ADMISSION_CONFIG"] = New-AdmissionConfiguration $Worktree $Lane
  $start.Environment["CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_NODE_OPTIONS"] = ""
  $start.Environment["CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_SCRIPT_SHELL"] = ""
  $start.Environment["CHASE_SETS_HEAVY_ADMISSION_PNPM_SCRIPT_SHELL"] = "node-check-proxy"
  $start.Environment["ADMISSION_MARKER"] = $Marker
  $start.Environment["ADMISSION_DELAY_MS"] = "0"
  $process = [Diagnostics.Process]::Start($start)
  $identity = [pscustomobject]@{
    pid = $process.Id
    processStartUtc = $process.StartTime.ToUniversalTime().ToString("o")
  }
  $startedProcesses.Add([pscustomobject]@{ Process = $process; Identity = $identity })
  return [pscustomobject]@{ Process = $process; Identity = $identity }
}
function Complete-Fixture($Fixture, [int]$ExpectedExit, [string]$Message) {
  Assert-True ($Fixture.Process.WaitForExit(20000)) "$Message exits within 20 seconds"
  $stderr = $Fixture.Process.StandardError.ReadToEnd()
  $stdout = $Fixture.Process.StandardOutput.ReadToEnd()
  Assert-True ($Fixture.Process.ExitCode -eq $ExpectedExit) "$Message exit code is $ExpectedExit (actual $($Fixture.Process.ExitCode); stderr=$stderr; stdout=$stdout)"
  return [pscustomobject]@{ stderr = $stderr; stdout = $stdout }
}

$bodyScript = Join-Path $root "body.cjs"
$pnpmScript = Join-Path $root "pnpm.cjs"
$playwrightDirectory = Join-Path $root "node_modules\playwright"
$vitestDirectory = Join-Path $root "node_modules\vitest"
$playwrightScript = Join-Path $playwrightDirectory "cli.js"
$vitestScript = Join-Path $vitestDirectory "vitest.js"
$outerScript = Join-Path $root "outer.cjs"
$pnpmShim = Join-Path $root "pnpm.cmd"
$descendantScript = Join-Path $root "descendant.cjs"
$descendantWorker = Join-Path $root "descendant-worker.cjs"
$probeScriptA = Join-Path $laneA "scripts\browser-e2e-probe.mjs"
$probeScriptB = Join-Path $laneB "scripts\browser-e2e-probe.mjs"
New-Item -ItemType Directory -Path $playwrightDirectory, $vitestDirectory,
  (Split-Path -Parent $probeScriptA), (Split-Path -Parent $probeScriptB) | Out-Null
$bodySource = @'
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
if (path.resolve(os.tmpdir()) !== path.resolve(process.env.TEMP) ||
    path.resolve(process.env.TEMP) !== path.resolve(process.env.TMP)) {
  throw new Error("fixture Node temp paths do not agree");
}
if (process.env.ADMISSION_OUTPUT) {
  fs.mkdirSync(process.env.ADMISSION_OUTPUT, { recursive: true });
}
fs.writeFileSync(process.env.ADMISSION_MARKER, "body-ran");
if (process.env.ADMISSION_OWNER_SNAPSHOT) {
  fs.copyFileSync(process.env.ADMISSION_OWNER_PATH, process.env.ADMISSION_OWNER_SNAPSHOT);
}
if (process.env.ADMISSION_RELEASE_FILE) {
  const timer = setInterval(() => {
    if (fs.existsSync(process.env.ADMISSION_RELEASE_FILE)) {
      clearInterval(timer);
      process.exit(0);
    }
  }, 20);
} else {
  setTimeout(() => process.exit(0), Number(process.env.ADMISSION_DELAY_MS || 0));
}
'@
$probeSource = @'
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
if (path.resolve(os.tmpdir()) !== path.resolve(process.env.TEMP) ||
    path.resolve(process.env.TEMP) !== path.resolve(process.env.TMP)) {
  throw new Error("fixture Node temp paths do not agree");
}
if (process.env.ADMISSION_OUTPUT) {
  fs.mkdirSync(process.env.ADMISSION_OUTPUT, { recursive: true });
}
fs.writeFileSync(process.env.ADMISSION_MARKER, "probe-body-ran");
if (process.env.ADMISSION_RELEASE_FILE) {
  const timer = setInterval(() => {
    if (fs.existsSync(process.env.ADMISSION_RELEASE_FILE)) {
      clearInterval(timer);
      process.exit(0);
    }
  }, 20);
} else {
  setTimeout(() => process.exit(0), Number(process.env.ADMISSION_DELAY_MS || 0));
}
'@
Set-Content -LiteralPath $bodyScript -Value $bodySource
Copy-Item -LiteralPath $bodyScript -Destination $pnpmScript
Copy-Item -LiteralPath $bodyScript -Destination $playwrightScript
Copy-Item -LiteralPath $bodyScript -Destination $vitestScript
Set-Content -LiteralPath $probeScriptA -Value $probeSource
Set-Content -LiteralPath $probeScriptB -Value $probeSource
Set-Content -LiteralPath $pnpmShim -Value @'
@"%ADMISSION_NODE%" "%ADMISSION_PNPM%" run verify:static
@exit /b %errorlevel%
'@
Set-Content -LiteralPath $outerScript -Value @'
const cp = require("node:child_process");
const result = cp.spawnSync(process.execPath, [process.env.NESTED_PNPM, "run", "verify:static"], {
  cwd: process.cwd(),
  env: process.env,
  stdio: "inherit",
});
process.exit(result.status ?? 74);
'@
Set-Content -LiteralPath $descendantWorker -Value @'
const fs = require("node:fs");
const timer = setInterval(() => {
  if (fs.existsSync(process.env.DESCENDANT_RELEASE_FILE)) {
    clearInterval(timer);
    process.exit(0);
  }
}, 20);
'@
Set-Content -LiteralPath $descendantScript -Value @'
const cp = require("node:child_process");
const fs = require("node:fs");
const child = cp.spawn(process.execPath, [process.env.DESCENDANT_WORKER], {
  detached: true,
  env: process.env,
  stdio: "ignore",
});
child.unref();
fs.writeFileSync(process.env.DESCENDANT_IDENTITY, String(child.pid));
fs.writeFileSync(process.env.ADMISSION_MARKER, "parent-ran");
process.exit(0);
'@
$packageJson = @{
  name = "inert-admission-fixture"
  private = $true
  scripts = @{
    typecheck = "node `"$bodyScript`""
    format = "prettier . --check"
    "test:unit" = "vitest run --config ./vitest.config.ts"
    focused = "vitest run source/focused.test.ts"
    build = "node ./scripts/run-workspaces.mjs build"
    "verify:static" = "node `"$bodyScript`""
    "dev:e2e:probe" = "node ./scripts/browser-e2e-probe.mjs"
    "dev:e2e:probe:alias" = "pnpm run dev:e2e:probe"
    "dev:e2e:probe:nested" = "pnpm run dev:e2e:probe:alias"
  }
} | ConvertTo-Json -Depth 4
Set-Content -LiteralPath (Join-Path $laneA "package.json") -Value $packageJson
Set-Content -LiteralPath (Join-Path $laneB "package.json") -Value $packageJson
foreach ($fixture in @(
    [pscustomobject]@{ Worktree = $laneA; Branch = "codex/lane-a" },
    [pscustomobject]@{ Worktree = $laneB; Branch = "codex/lane-b" }
  )) {
  Invoke-RepoGit $fixture.Worktree @("init", "--initial-branch=$($fixture.Branch)") | Out-Null
  Invoke-RepoGit $fixture.Worktree @("config", "user.name", "Heavy Admission Test") | Out-Null
  Invoke-RepoGit $fixture.Worktree @("config", "user.email", "heavy-admission-test@example.invalid") | Out-Null
  Invoke-RepoGit $fixture.Worktree @("add", "--", "package.json") | Out-Null
  Invoke-RepoGit $fixture.Worktree @("commit", "-m", "admission fixture") | Out-Null
}

function Test-DerivedAdmission {
  $derivedDirectory = Join-Path $root "derived"
  $derivedScript = Join-Path $derivedDirectory "pnpm.cjs"
  $derivedObserver = Join-Path $derivedDirectory "observe.cjs"
  $derivedLane = Join-Path $container "derived-lane"
  $mainFixture = Join-Path $container "main"
  $outsideFixture = "$container-sibling"
  $nonGitFixture = Join-Path $container "non-git"
  New-Item -ItemType Directory -Path $derivedDirectory, $mainFixture, $outsideFixture, $nonGitFixture | Out-Null
  Invoke-RepoGit $laneA @("worktree", "add", "-b", "codex/derived-lane", $derivedLane) | Out-Null
  foreach ($directory in @($mainFixture, $outsideFixture)) {
    Invoke-RepoGit $directory @("init", "--initial-branch=synthetic-passthrough") | Out-Null
  }
  Set-Content -LiteralPath $derivedObserver -Value @'
const cp = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
if (process.env.DERIVED_CHILD === "1") {
  fs.writeFileSync(process.env.DERIVED_CHILD_ENTRY, JSON.stringify({
    nodeOptions: process.env.NODE_OPTIONS, token: process.env.CHASE_SETS_HEAVY_SLOT_ID,
    transport: JSON.parse(Buffer.from(process.env.CHASE_SETS_HEAVY_SLOT_TRANSPORT, "base64").toString("utf8")),
    owner: JSON.parse(fs.readFileSync(process.env.DERIVED_OWNER, "utf8")),
  }));
}
const record = (event) => fs.appendFileSync(process.env.DERIVED_EVENTS,
  JSON.stringify({ event, child: process.env.DERIVED_CHILD === "1", pid: process.pid }) + "\n");
const spawnSync = cp.spawnSync;
cp.spawnSync = function (command, ...args) {
  if (/^git(?:\.exe)?$/i.test(path.basename(command))) {
    record("git");
    if (process.env.DERIVED_FORBID_GIT === "1") throw new Error("unexpected Git invocation");
  }
  return spawnSync.call(this, command, ...args);
};
const mkdtempSync = fs.mkdtempSync;
fs.mkdtempSync = function (prefix, ...args) {
  if (String(prefix).includes("chase-sets-heavy-admission-")) record("admission-root");
  return mkdtempSync.call(this, prefix, ...args);
};
'@
  Set-Content -LiteralPath $derivedScript -Value @'
const cp = require("node:child_process");
const fs = require("node:fs");
const snapshot = () => ({
  pid: process.pid,
  nodeOptions: process.env.NODE_OPTIONS ?? null,
  token: process.env.CHASE_SETS_HEAVY_SLOT_ID ?? null,
  configuration: process.env.CHASE_SETS_HEAVY_ADMISSION_CONFIG ?? null,
  configPresent: Object.hasOwn(process.env, "CHASE_SETS_HEAVY_ADMISSION_CONFIG"),
  warnedRoot: process.env.CHASE_SETS_HEAVY_ADMISSION_WARNED_ROOT ?? null,
  owner: fs.existsSync(process.env.DERIVED_OWNER) ? JSON.parse(fs.readFileSync(process.env.DERIVED_OWNER, "utf8")) : null,
});
const before = snapshot();
if (process.env.DERIVED_TREE === "1") {
  const child = cp.spawnSync(process.execPath, [__filename, "run", "verify"], {
    cwd: process.env.DERIVED_CHILD_CWD,
    env: { ...process.env, DERIVED_TREE: "0", DERIVED_EXIT: "0",
      ...(process.env.DERIVED_TREE_STALE === "1" ? { CHASE_SETS_HEAVY_SLOT_ID: "00000000000000000000000000000000" } : {}),
      ADMISSION_MARKER: process.env.ADMISSION_MARKER + ".child" },
    encoding: "utf8", windowsHide: true,
  });
  process.stdout.write(child.stdout);
  process.stderr.write(child.stderr);
  fs.writeFileSync(process.env.ADMISSION_MARKER + ".result", JSON.stringify({ status: child.status, pid: child.pid }));
}
if (process.env.DERIVED_NESTED === "1" && process.env.DERIVED_CHILD !== "1") {
  const child = cp.spawnSync(process.execPath, [__filename, "run", "verify"], {
    cwd: process.env.DERIVED_CHILD_CWD,
    env: { ...process.env, DERIVED_CHILD: "1", DERIVED_FORBID_GIT: "1",
      ADMISSION_MARKER: process.env.ADMISSION_MARKER + ".child", ADMISSION_RELEASE_FILE: "" },
    encoding: "utf8", windowsHide: true,
  });
  if (child.status !== 0 || child.stdout || child.stderr) {
    throw new Error(`nested child exit=${child.status} stdout=${child.stdout} stderr=${child.stderr}`);
  }
}
fs.writeFileSync(process.env.ADMISSION_MARKER, JSON.stringify({ before, after: snapshot() }));
if (process.env.ADMISSION_RELEASE_FILE) {
  const timer = setInterval(() => {
    if (fs.existsSync(process.env.ADMISSION_RELEASE_FILE)) {
      clearInterval(timer);
      process.exit(Number(process.env.DERIVED_EXIT || 0));
    }
  }, 20);
} else process.exit(Number(process.env.DERIVED_EXIT || 0));
'@
  $derivedPlaywright = Join-Path $derivedDirectory "playwright.js"
  $derivedVitest = Join-Path $derivedDirectory "vitest.js"
  $derivedLight = Join-Path $derivedDirectory "foo.cjs"
  foreach ($script in @($derivedPlaywright, $derivedVitest, $derivedLight)) {
    Copy-Item -LiteralPath $derivedScript -Destination $script
  }
  $derivedNodeOptions = "--require=`"$($derivedObserver.Replace('\', '/'))`" --require=`"$preloadForNode`""
  $heavyShapes = @(
    @{ Script = $derivedScript; Arguments = @("run", "verify"); Kind = "repository-gate" },
    @{ Script = $derivedVitest; Arguments = @("run"); Kind = "vitest-full" },
    @{ Script = $derivedPlaywright; Arguments = @("test"); Kind = "playwright" }
  )
  $derivedFailures = [Collections.Generic.List[string]]::new()
  function Start-DispatchedDerivedFixture($Shape, [string]$Directory, [string]$Marker, [hashtable]$Environment) {
    $inputPath = "$Marker.launch.json"
    $label = "derived-native-$([guid]::NewGuid().ToString('N'))"
    $childCommand = @'
$ErrorActionPreference = "Stop"
$fixture = Get-Content -LiteralPath $env:DERIVED_LAUNCH_INPUT -Raw | ConvertFrom-Json
$record = $null
for ($attempt = 0; $attempt -lt 600; $attempt++) {
  foreach ($file in @(Get-ChildItem -LiteralPath $fixture.RuntimeRoot -Filter 'dispatch-launch-*.json')) {
    try { $candidate = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json } catch { continue }
    if ($candidate.state -ceq 'started' -and $candidate.childPid -eq $PID) {
      $record = $candidate
      [IO.File]::Copy($file.FullName, "$($fixture.Marker).dispatch", $false)
      break
    }
  }
  if ($record) { break }
  Start-Sleep -Milliseconds 25
}
if (-not $record) { throw 'canonical launcher did not publish this native child' }
$start = [Diagnostics.ProcessStartInfo]::new()
$start.FileName = $fixture.Node
$start.WorkingDirectory = $fixture.Directory
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
foreach ($name in @('CHASE_SETS_HEAVY_ADMISSION_CONFIG', 'CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_NODE_OPTIONS',
    'CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_SCRIPT_SHELL', 'CHASE_SETS_HEAVY_ADMISSION_PNPM_SCRIPT_SHELL',
    'CHASE_SETS_HEAVY_SLOT_ID', 'CHASE_SETS_HEAVY_SLOT_TRANSPORT', 'npm_config_script_shell')) {
  [void]$start.Environment.Remove($name)
}
foreach ($property in $fixture.Environment.PSObject.Properties) { $start.Environment[$property.Name] = [string]$property.Value }
$start.Environment['ADMISSION_MARKER'] = $fixture.Marker
$start.ArgumentList.Add($fixture.Script)
foreach ($argument in $fixture.Arguments) { $start.ArgumentList.Add($argument) }
$process = [Diagnostics.Process]::Start($start)
$stdout = $process.StandardOutput.ReadToEndAsync()
$stderr = $process.StandardError.ReadToEndAsync()
@{ pid = $process.Id; processStartUtc = $process.StartTime.ToUniversalTime().ToString('o') } |
  ConvertTo-Json -Compress | Set-Content -LiteralPath "$($fixture.Marker).identity"
$process.WaitForExit()
[Console]::Out.Write($stdout.GetAwaiter().GetResult())
[Console]::Error.Write($stderr.GetAwaiter().GetResult())
$exitCode = $process.ExitCode
for ($attempt = 0; $attempt -lt 600; $attempt++) {
  if (-not (Test-Path -LiteralPath (Join-Path $fixture.RuntimeRoot 'verify-lock.d'))) { break }
  Start-Sleep -Milliseconds 25
}
if (Test-Path -LiteralPath (Join-Path $fixture.RuntimeRoot 'verify-lock.d')) { throw 'derived owner did not drain before dispatch release' }
exit $exitCode
'@
    $parameters = @{
      Harness = 'codex'; Model = 'gpt-6-astra'; Effort = 'high'; LaneRole = 'review'
      PromptFile = $inputPath; Worktree = $Directory; Label = $label
      ExecutablePath = $pwsh; TestRuntimeRoot = $orchestrator; TestTempRoot = $privateTemp
      TestArgumentList = @('-NoProfile', '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childCommand)))
    }
    @{
      Node = $node; Directory = $Directory; Marker = $Marker; Script = $Shape.Script
      Arguments = $Shape.Arguments; Environment = $Environment; RuntimeRoot = $orchestrator
      Dispatcher = (Join-Path $PSScriptRoot 'dispatch-lane.ps1'); Parameters = $parameters
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $inputPath
    $command = '$fixture = Get-Content -LiteralPath $env:DERIVED_LAUNCH_INPUT -Raw | ConvertFrom-Json -AsHashtable; $parameters = $fixture.Parameters; & $fixture.Dispatcher @parameters'
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $pwsh
    $start.WorkingDirectory = $Directory
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    Set-CleanAdmissionEnvironment $start
    $start.Environment['DERIVED_LAUNCH_INPUT'] = $inputPath
    foreach ($argument in @('-NoProfile', '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command)))) {
      $start.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::Start($start)
    $identity = [pscustomobject]@{ pid = $process.Id; processStartUtc = $process.StartTime.ToUniversalTime().ToString('o') }
    $startedProcesses.Add([pscustomobject]@{ Process = $process; Identity = $identity })
    return [pscustomobject]@{
      Process = $process; Identity = $identity
      Transcript = (Join-Path $orchestrator "$label.jsonl"); ErrorLog = (Join-Path $orchestrator "$label.err.log")
    }
  }
  function Invoke-DerivedProbe([scriptblock]$Probe) {
    try { & $Probe } catch {
      $derivedFailures.Add($_.Exception.Message)
      Write-Output "FAIL derived probe: $($_.Exception.Message)"
    }
  }
  function Invoke-DerivedCase([string]$Name, [hashtable]$Shape = $heavyShapes[0], [string]$Directory = $derivedLane,
    [bool]$Admitted = $false, [bool]$Warn = $false, [hashtable]$Extra = @{}, [int]$Exit = 0) {
    $marker = Join-Path $derivedDirectory ([guid]::NewGuid().ToString("N") + ".json")
    $events = "$marker.events"
    $release = "$marker.release"
    $environment = @{
      NODE_OPTIONS = $derivedNodeOptions
      DERIVED_EVENTS = $events
      DERIVED_OWNER = $ownerPath
      DERIVED_EXIT = "$Exit"
      DERIVED_CHILD_CWD = $outsideFixture
      DERIVED_CHILD_ENTRY = "$marker.entry"
    }
    if ($Admitted) { $environment.ADMISSION_RELEASE_FILE = $release }
    foreach ($entry in $Extra.GetEnumerator()) { $environment[$entry.Key] = $entry.Value }
    $dispatched = $Name -ceq 'derived-nested-child-continues'
    $fixture = if ($dispatched) { Start-DispatchedDerivedFixture $Shape $Directory $marker $environment }
      else { Start-NodeFixture $Shape.Script $Shape.Arguments $Directory "derived-lane" $marker 0 $environment @{} -Derived }
    try {
      if ($Admitted) {
        Wait-Condition {
          if ($fixture.Process.HasExited) {
            $entry = if (Test-Path -LiteralPath "$marker.entry") { Get-Content -LiteralPath "$marker.entry" -Raw } else { "absent" }
            $dispatchError = if ($dispatched -and (Test-Path -LiteralPath $fixture.ErrorLog)) { Get-Content -LiteralPath $fixture.ErrorLog -Raw } else { '' }
            throw "$Name exited before body: $($fixture.Process.ExitCode) child-entry=$entry launcher-stdout=$($fixture.Process.StandardOutput.ReadToEnd()) launcher-stderr=$($fixture.Process.StandardError.ReadToEnd()) child-stderr=$dispatchError"
          }
          Test-Path -LiteralPath $marker
        } "$Name admitted body"
      }
    } finally {
      if ($Admitted) {
        Set-Content -LiteralPath $release -Value "release"
        Assert-True ($fixture.Process.WaitForExit(20000)) "$Name exact fixture exits after release"
        Wait-Condition { -not (Test-Path -LiteralPath $lock) } "$Name exact owner drains before next probe"
      }
    }
    $output = Complete-Fixture $fixture $Exit $Name
    if ($dispatched) {
      Write-Output "$Name LAUNCHER stdout=$($output.stdout) stderr=$($output.stderr)"
      $output = @{ stdout = [IO.File]::ReadAllText($fixture.Transcript); stderr = [IO.File]::ReadAllText($fixture.ErrorLog) }
      $fixture.Identity = Get-Content -LiteralPath "$marker.identity" -Raw | ConvertFrom-Json -DateKind String
      $dispatch = Get-Content -LiteralPath "$marker.dispatch" -Raw | ConvertFrom-Json -DateKind String
      . (Join-Path $PSScriptRoot 'dispatch-ownership.ps1')
      $dispatchPath = Join-Path $orchestrator "dispatch-launch-$($dispatch.launchId).json"
      if (Test-Path -LiteralPath $dispatchPath) {
        Assert-True ((Get-DispatchProcessIdentityState $dispatch.launcherPid $dispatch.launcherStartIdentity) -ceq 'dead' -and
          (Get-DispatchProcessIdentityState $dispatch.childPid $dispatch.childStartIdentity) -ceq 'dead') "$Name exact native dispatch has exited before cleanup"
        Assert-True (Remove-DispatchLaunchResources $dispatchPath $dispatch $orchestrator $privateTemp) "$Name canonical exact-owner cleanup"
      }
      $entry = Get-Content -LiteralPath "$marker.entry" -Raw | ConvertFrom-Json
      Assert-True ($entry.transport.launchId -ceq $dispatch.launchId -and $entry.transport.laneRole -ceq $dispatch.laneRole) "$Name transport binds the canonical native dispatch"
      Assert-True (-not (Test-Path -LiteralPath $dispatchPath)) "$Name canonical machinery releases its own record"
      Write-Output "$Name DISPATCH $($dispatch | ConvertTo-Json -Compress)"
    }
    Wait-Condition { -not (Test-Path -LiteralPath $lock) } "$Name exact-owner release"
    Assert-True ($output.stdout -ceq "") "$Name stdout is silent"
    $expectedStderr = if ($Warn) { "heavy-admission: unguarded heavy command outside a lane worktree ($Directory)`n" } else { "" }
    if ($Exit -eq 73) {
      Assert-True ($output.stderr -match "command body was not executed" -and -not (Test-Path -LiteralPath $marker)) "$Name refuses before body"
      if ($Extra.ContainsKey("CHASE_SETS_HEAVY_ADMISSION_CONFIG")) {
        Assert-True ($output.stderr -match "launcher admission configuration was invalid") "$Name uses existing invalid-config refusal"
      }
    } else {
      Assert-True ($output.stderr -ceq $expectedStderr) "$Name exact stderr (actual=$($output.stderr))"
      $snapshot = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json -DateKind String
      if ($Admitted) {
        $top = Invoke-RepoGit $Directory @("rev-parse", "--show-toplevel")
        $head = Invoke-RepoGit $Directory @("rev-parse", "HEAD")
        $branch = Invoke-RepoGit $Directory @("branch", "--show-current")
        $owner = $snapshot.before.owner
        Assert-True ($null -ne $owner) "$Name body has an admission owner"
        Assert-True ([IO.Path]::GetFullPath($owner.worktree) -ceq [IO.Path]::GetFullPath($top) -and
          $owner.lane -ceq (Split-Path -Leaf $top) -and $owner.head -ceq $head -and
          $owner.branch -ceq $(if ($branch) { $branch } else { $null }) -and $owner.gate -ceq $Shape.Kind -and
          $owner.identityMode -ceq $(if ($branch) { "branch" } else { "immutable-head" })) "$Name owner equals native Git identity"
        Assert-True ($snapshot.before.token -ceq $owner.lockId -and $owner.childPid -eq $fixture.Identity.pid -and
          $owner.childProcessStartUtc -ceq $fixture.Identity.processStartUtc -and $owner.state -ceq "attached") "$Name genuine attached process owner"
        Write-Output "$Name OWNER $($owner | ConvertTo-Json -Compress)"
      } else {
        Assert-True ($null -eq $snapshot.before.owner -and $null -eq $snapshot.before.token) "$Name no admission"
      }
      if (-not $Extra.ContainsKey("CHASE_SETS_HEAVY_ADMISSION_CONFIG")) {
        Assert-True ($snapshot.before.nodeOptions -ceq $derivedNodeOptions -and -not $snapshot.before.configPresent) "$Name retains NODE_OPTIONS with truly absent configuration"
      } else {
        Assert-True ($null -eq $snapshot.before.nodeOptions -and $null -eq $snapshot.before.configuration) "$Name launcher restores original environment"
      }
      if ($Extra.DERIVED_NESTED -eq "1") {
        $child = Get-Content -LiteralPath "$marker.child" -Raw | ConvertFrom-Json -DateKind String
        Assert-True ($child.before.nodeOptions -ceq $derivedNodeOptions -and
          $child.before.token -ceq $snapshot.before.token -and
          ($child.before.owner | ConvertTo-Json -Compress) -ceq ($snapshot.before.owner | ConvertTo-Json -Compress) -and
          ($snapshot.after.owner | ConvertTo-Json -Compress) -ceq ($snapshot.before.owner | ConvertTo-Json -Compress)) "$Name one byte-equivalent owner across nested continuation"
      }
    }
    $observed = if (Test-Path -LiteralPath $events) { @(Get-Content -LiteralPath $events | ConvertFrom-Json) } else { @() }
    if ($Exit -eq 73 -and $Extra.ContainsKey("CHASE_SETS_HEAVY_ADMISSION_CONFIG")) {
      Assert-True ($observed.Count -eq 0) "$Name invalid configuration refuses without Git or admission roots"
    }
    Assert-True (@($observed | Where-Object child).Count -eq 0) "$Name nested child has zero Git calls and zero new roots"
    if ($Warn) {
      Assert-True (@($observed | Where-Object event -eq "git").Count -eq 1 -and
        @($observed | Where-Object event -eq "admission-root").Count -eq 0) "$Name exactly one Git preflight, zero admission roots"
    }
    if ($Extra.DERIVED_FORBID_GIT -eq "1") {
      Assert-True ($observed.Count -eq 0) "$Name no Git or new admission root"
    }
    if ($Admitted) {
      Assert-True (@($observed | Where-Object event -eq "admission-root").Count -eq 1) "$Name exactly one admission root"
    }
    Write-Output "PASS $Name"
  }

  function Invoke-DerivedTreeCase([string]$Name, [string]$Directory, [string]$ChildDirectory,
    [bool]$ChildAdmitted = $false, [bool]$StaleToken = $false, [bool]$SameRoot = ($Directory -ceq $ChildDirectory)) {
    $marker = Join-Path $derivedDirectory ([guid]::NewGuid().ToString("N") + ".tree")
    $events = "$marker.events"
    $fixture = Start-NodeFixture $derivedScript @("run", "verify") $Directory "derived-lane" $marker 0 @{
      NODE_OPTIONS = $derivedNodeOptions; DERIVED_EVENTS = $events; DERIVED_OWNER = $ownerPath
      DERIVED_TREE = "1"; DERIVED_CHILD_CWD = $ChildDirectory; DERIVED_EXIT = "29"
      DERIVED_TREE_STALE = $(if ($StaleToken) { "1" } else { "0" })
    } @{} -Derived
    $output = Complete-Fixture $fixture 29 $Name
    Wait-Condition { -not (Test-Path -LiteralPath $lock) } "$Name exact-owner release"
    $parent = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json -DateKind String
    $result = Get-Content -LiteralPath "$marker.result" -Raw | ConvertFrom-Json
    $observed = @(Get-Content -LiteralPath $events | ConvertFrom-Json)
    Assert-True ($output.stdout -ceq "" -and $null -eq $parent.before.owner -and $null -eq $parent.before.token) "$Name parent passes through without admission"
    Assert-True ($parent.before.warnedRoot -cmatch '^[a-f0-9]{64}$' -and
      $parent.before.nodeOptions -ceq $derivedNodeOptions -and -not $parent.before.configPresent) "$Name bounded warning marker and absent-config inheritance"
    $expectedWarning = "heavy-admission: unguarded heavy command outside a lane worktree ($Directory)`n"
    if ($StaleToken) {
      Assert-True ($result.status -eq 73 -and -not (Test-Path -LiteralPath "$marker.child") -and
        $output.stderr.StartsWith($expectedWarning) -and $output.stderr -match "command body was not executed") "$Name inherited warning cannot bypass token refusal"
      Assert-True (@($observed | Where-Object event -eq "git").Count -eq 1 -and
        @($observed | Where-Object event -eq "admission-root").Count -eq 0) "$Name stale child has no Git or new holder"
    } else {
      Assert-True ($result.status -eq 0) "$Name child exits zero (actual=$($result.status); stderr=$($output.stderr))"
      $child = Get-Content -LiteralPath "$marker.child" -Raw | ConvertFrom-Json -DateKind String
      Assert-True ($child.before.pid -eq $result.pid -and $child.before.nodeOptions -ceq $derivedNodeOptions -and
        -not $child.before.configPresent) "$Name child retains preload with truly absent config"
      if ($ChildAdmitted) {
        $owner = $child.before.owner
        $top = Invoke-RepoGit $ChildDirectory @("rev-parse", "--show-toplevel")
        $head = Invoke-RepoGit $ChildDirectory @("rev-parse", "HEAD")
        $branch = Invoke-RepoGit $ChildDirectory @("branch", "--show-current")
        Assert-True ($null -ne $owner -and $owner.state -ceq "attached" -and $owner.childPid -eq $result.pid -and
          $child.before.token -ceq $owner.lockId -and $owner.head -ceq $head -and $owner.branch -ceq $branch -and
          $owner.lane -ceq (Split-Path -Leaf $top) -and $owner.identityMode -ceq "branch" -and
          [IO.Path]::GetFullPath($owner.worktree) -ceq [IO.Path]::GetFullPath($top)) "$Name lane child acquires genuine native Git/process owner"
        Assert-True ($child.before.warnedRoot -ceq $parent.before.warnedRoot -and
          @($observed | Where-Object event -eq "admission-root").Count -eq 1 -and
          @($observed | Where-Object event -eq "git").Count -gt 1) "$Name inherited warning does not suppress lane eligibility or admission"
        Write-Output "$Name OWNER $($owner | ConvertTo-Json -Compress)"
      } else {
        Assert-True ($null -eq $child.before.owner -and $null -eq $child.before.token -and
          @($observed | Where-Object event -eq "admission-root").Count -eq 0 -and
          @($observed | Where-Object event -eq "git").Count -eq 2) "$Name both heavy processes evaluate eligibility without admission"
        if ($SameRoot) {
          Assert-True ($child.before.warnedRoot -ceq $parent.before.warnedRoot) "$Name same rejected root"
        } else {
          Assert-True ($child.before.warnedRoot -cne $parent.before.warnedRoot) "$Name distinct rejected roots"
          $expectedWarning += "heavy-admission: unguarded heavy command outside a lane worktree ($ChildDirectory)`n"
        }
      }
      Assert-True ($output.stderr -ceq $expectedWarning) "$Name exact command-tree stderr (actual=$($output.stderr))"
    }
    Write-Output "PASS $Name parentExit=29 childExit=$($result.status) warningLines=$(@($output.stderr -split "`n" | Where-Object { $_ -like 'heavy-admission: unguarded*' }).Count)"
  }

  foreach ($directory in @($mainFixture, $outsideFixture, $nonGitFixture)) {
    Invoke-DerivedProbe { Invoke-DerivedTreeCase "derived-same-root-child-warns-once" $directory $directory }
  }
  $outsideSubdirectory = Join-Path $outsideFixture "nested"
  New-Item -ItemType Directory -Path $outsideSubdirectory | Out-Null
  Invoke-DerivedProbe { Invoke-DerivedTreeCase "derived-same-worktree-subdirectory-warns-once" $outsideFixture $outsideSubdirectory $false $false $true }
  Invoke-DerivedProbe { Invoke-DerivedTreeCase "derived-outside-to-registered-lane-admits" $outsideFixture $derivedLane $true }
  Invoke-DerivedProbe { Invoke-DerivedTreeCase "derived-distinct-roots-each-warn" $outsideFixture $mainFixture }
  foreach ($directory in @($outsideFixture, $derivedLane)) {
    Invoke-DerivedProbe { Invoke-DerivedTreeCase "derived-warning-never-bypasses-stale-token" $outsideFixture $directory $false $true }
  }

  foreach ($shape in $heavyShapes) { Invoke-DerivedProbe { Invoke-DerivedCase "derived-lane-heavy-admits" $shape $derivedLane $true } }
  $detachedHead = Invoke-RepoGit $derivedLane @("rev-parse", "HEAD")
  Invoke-RepoGit $derivedLane @("checkout", "--detach", $detachedHead) | Out-Null
  try { Invoke-DerivedProbe { Invoke-DerivedCase "derived-lane-detached-immutable-head" $heavyShapes[0] $derivedLane $true } }
  finally { Invoke-RepoGit $derivedLane @("checkout", "codex/derived-lane") | Out-Null }
  foreach ($shape in $heavyShapes) {
    Invoke-DerivedProbe { Invoke-DerivedCase "derived-main-passthrough-warns" $shape $mainFixture $false $true @{} 29 }
    Invoke-DerivedProbe { Invoke-DerivedCase "derived-outside-container-passthrough-warns" $shape $outsideFixture $false $true @{} 29 }
    Invoke-DerivedProbe { Invoke-DerivedCase "derived-non-git-passthrough-warns" $shape $nonGitFixture $false $true @{} 29 }
  }
  foreach ($directory in @($derivedLane, $mainFixture, $outsideFixture, $nonGitFixture)) {
    foreach ($shape in @(
        @{ Script = $derivedLight; Arguments = @() },
        @{ Script = $derivedScript; Arguments = @("--version") },
        @{ Script = $derivedVitest; Arguments = @("run", "one.test.ts") }
      )) {
      Invoke-DerivedProbe {
        Invoke-DerivedCase $(if ($directory -ceq $derivedLane) { "derived-light-command-no-git" } else { "derived-outside-light-silent" }) `
          $shape $directory $false $false @{ DERIVED_FORBID_GIT = "1" }
      }
    }
  }
  $configuration = New-AdmissionConfiguration $derivedLane "derived-lane" @{ Branch = "codex/derived-lane" }
  Invoke-DerivedProbe { Invoke-DerivedCase "config-present-wins-over-derived" $heavyShapes[0] $derivedLane $true $false @{
    CHASE_SETS_HEAVY_ADMISSION_CONFIG = $configuration
  } }
  Invoke-DerivedProbe { Invoke-DerivedCase "config-present-invalid-refuses" $heavyShapes[0] $derivedLane $false $false @{
    CHASE_SETS_HEAVY_ADMISSION_CONFIG = "not-base64-json"
    DERIVED_FORBID_GIT = "1"
  } 73 }
  Invoke-DerivedProbe { Invoke-DerivedCase "config-present-empty-refuses" $heavyShapes[0] $outsideFixture $false $false @{
    CHASE_SETS_HEAVY_ADMISSION_CONFIG = ""
  } 73 }
  Invoke-DerivedProbe { Invoke-DerivedCase "derived-nested-child-continues" $heavyShapes[0] $derivedLane $true $false @{ DERIVED_NESTED = "1" } }
  foreach ($directory in @($derivedLane, $outsideFixture)) {
    Invoke-DerivedProbe { Invoke-DerivedCase "derived-stale-token-never-falls-back" $heavyShapes[0] $directory $false $false @{
      CHASE_SETS_HEAVY_SLOT_ID = "00000000000000000000000000000000"
      DERIVED_FORBID_GIT = "1"
    } 73 }
  }
  $heldMarker = Join-Path $derivedDirectory "held.json"
  $heldRelease = "$heldMarker.release"
  $holder = Start-NodeFixture $pnpmScript @("run", "verify") $laneA "lane-a" $heldMarker 0 @{
    ADMISSION_RELEASE_FILE = $heldRelease
  }
  try {
    Wait-Condition { Test-Path -LiteralPath $heldMarker } "derived held-slot control owner"
    $heldRaw = Get-Content -LiteralPath $ownerPath -Raw
    foreach ($shape in $heavyShapes) {
      $marker = Join-Path $derivedDirectory ([guid]::NewGuid().ToString("N") + ".refused")
      $contender = Start-NodeFixture $shape.Script $shape.Arguments $derivedLane "derived-lane" $marker 0 @{} @{} -Derived
      $output = Complete-Fixture $contender 73 "derived-held-slot-refuses"
      Assert-True ($output.stderr -match "command body was not executed" -and -not (Test-Path -LiteralPath $marker) -and
        (Get-Content -LiteralPath $ownerPath -Raw) -ceq $heldRaw) "derived-held-slot-refuses before body with unchanged genuine owner"
    }
    Write-Output "PASS derived-held-slot-refuses"
  } finally {
    Set-Content -LiteralPath $heldRelease -Value "release"
    Complete-Fixture $holder 0 "derived held-slot control owner" | Out-Null
    Wait-Condition { -not (Test-Path -LiteralPath $lock) } "derived held-slot control release"
  }

  $candidate = [IO.File]::ReadAllText($preload)
  $mutants = @(
    @{ Name = "omitted-derived-admission"; From = '    acquireHeavySlot(kind, {});'; To = '    return;'; Case = { Invoke-DerivedCase "derived-lane-heavy-admits" $heavyShapes[0] $derivedLane $true } },
    @{ Name = "omitted-main-exclusion"; From = 'path.basename(worktree).toLowerCase() === "main"'; To = 'false'; Case = { Invoke-DerivedCase "derived-main-passthrough-warns" $heavyShapes[0] $mainFixture $false $true @{} 29 } },
    @{ Name = "omitted-container-boundary"; From = '!worktree.toLowerCase().startsWith(containerPrefix)'; To = 'false'; Case = { Invoke-DerivedCase "derived-outside-container-passthrough-warns" $heavyShapes[0] $outsideFixture $false $true @{} 29 } },
    @{ Name = "omitted-warning"; From = '        process.stderr.write(`heavy-admission: unguarded heavy command outside a lane worktree (${cwd})\n`);'; To = ''; Case = { Invoke-DerivedCase "derived-non-git-passthrough-warns" $heavyShapes[0] $nonGitFixture $false $true @{} 29 } },
    @{ Name = "omitted-classify-first"; From = '    if (!kind) return;'; To = ''; Case = { Invoke-DerivedCase "derived-light-command-no-git" @{ Script = $derivedLight; Arguments = @() } $derivedLane $false $false @{ DERIVED_FORBID_GIT = "1" } } },
    @{ Name = "omitted-config-precedence"; From = '  if (!Object.hasOwn(process.env, "CHASE_SETS_HEAVY_ADMISSION_CONFIG")) {'; To = '  if (true) {'; Case = { Invoke-DerivedCase "config-present-invalid-refuses" $heavyShapes[0] $derivedLane $false $false @{ CHASE_SETS_HEAVY_ADMISSION_CONFIG = "not-base64-json"; DERIVED_FORBID_GIT = "1" } 73 } },
    @{ Name = "omitted-empty-config-presence"; From = '  if (!Object.hasOwn(process.env, "CHASE_SETS_HEAVY_ADMISSION_CONFIG")) {'; To = '  if (!encoded) {'; Case = { Invoke-DerivedCase "config-present-empty-refuses" $heavyShapes[0] $outsideFixture $false $false @{ CHASE_SETS_HEAVY_ADMISSION_CONFIG = "" } 73 } },
    @{ Name = "omitted-nested-first"; From = '    if (!process.env.CHASE_SETS_HEAVY_SLOT_ID) {'; To = '    if (true) {'; Case = { Invoke-DerivedCase "derived-nested-child-continues" $heavyShapes[0] $derivedLane $true $false @{ DERIVED_NESTED = "1" } } },
    @{ Name = "omitted-node-options-inheritance"; From = '    acquireHeavySlot(kind, {});'; To = '    acquireHeavySlot(kind, {}); delete process.env.NODE_OPTIONS;'; Case = { Invoke-DerivedCase "derived-nested-child-continues" $heavyShapes[0] $derivedLane $true $false @{ DERIVED_NESTED = "1" } } },
    @{ Name = "omitted-warning-deduplication"; From = '        if (process.env.CHASE_SETS_HEAVY_ADMISSION_WARNED_ROOT !== warningRoot) {'; To = '        if (true) {'; Case = { Invoke-DerivedTreeCase "derived-same-root-child-warns-once" $outsideFixture $outsideFixture } },
    @{ Name = "omitted-warning-root-scope"; From = 'process.env.CHASE_SETS_HEAVY_ADMISSION_WARNED_ROOT !== warningRoot'; To = '!process.env.CHASE_SETS_HEAVY_ADMISSION_WARNED_ROOT'; Case = { Invoke-DerivedTreeCase "derived-distinct-roots-each-warn" $outsideFixture $mainFixture } },
    @{ Name = "warning-bypasses-lane-admission"; From = '    if (!process.env.CHASE_SETS_HEAVY_SLOT_ID) {'; To = '    if (process.env.CHASE_SETS_HEAVY_ADMISSION_WARNED_ROOT) return; if (!process.env.CHASE_SETS_HEAVY_SLOT_ID) {'; Case = { Invoke-DerivedTreeCase "derived-outside-to-registered-lane-admits" $outsideFixture $derivedLane $true } },
    @{ Name = "warning-bypasses-token-refusal"; From = '    if (!process.env.CHASE_SETS_HEAVY_SLOT_ID) {'; To = '    if (process.env.CHASE_SETS_HEAVY_ADMISSION_WARNED_ROOT) return; if (!process.env.CHASE_SETS_HEAVY_SLOT_ID) {'; Case = { Invoke-DerivedTreeCase "derived-warning-never-bypasses-stale-token" $outsideFixture $derivedLane $false $true } }
  )
  foreach ($mutant in $mutants) {
    Assert-True ($candidate.Contains($mutant.From)) "$($mutant.Name) source mutation has an anchor"
    $controlFailure = $null
    try { & $mutant.Case | Out-Null } catch { $controlFailure = $_.Exception.Message }
    try {
      [IO.File]::WriteAllText($preload, $candidate.Replace($mutant.From, $mutant.To))
      $failure = $null
      try { & $mutant.Case | Out-Null } catch { $failure = $_.Exception.Message }
      if ($controlFailure) {
        $derivedFailures.Add("$($mutant.Name) discrimination incomplete: true candidate failed: $controlFailure")
        Write-Output "FAIL omission-mutant $($mutant.Name) true-candidate=$controlFailure mutant=$failure"
      } elseif (-not $failure) {
        $derivedFailures.Add("$($mutant.Name) was not detected by its AC probe")
        Write-Output "FAIL omission-mutant $($mutant.Name) was not detected"
      } else {
        Write-Output "PASS omission-mutant $($mutant.Name) detected: $failure"
      }
    } finally {
      [IO.File]::WriteAllText($preload, $candidate)
    }
  }
  Assert-True ($derivedFailures.Count -eq 0) "derived admission failures ($($derivedFailures.Count)):`n$($derivedFailures -join "`n")"
}

function Test-AdmissionGitIdentity {
  # A direct heavy command carrying a branch from an earlier assignment fails
  # in the preload before its body, even when both branches share the commit.
  Invoke-RepoGit $laneA @("checkout", "-b", "codex/lane-a-reused") | Out-Null
  $stalePreloadMarker = Join-Path $root "stale-preload-negative-control.marker"
  $stalePreload = Start-NodeFixture $pnpmScript @("run", "verify:static") $laneA "lane-a" $stalePreloadMarker
  $stalePreloadOutput = Complete-Fixture $stalePreload 73 "stale direct-command branch identity"
  Assert-True ($stalePreloadOutput.stderr -match "does not match the live Git branch" -and
    $stalePreloadOutput.stderr -match "command body was not executed" -and
    -not (Test-Path -LiteralPath $stalePreloadMarker) -and
    -not (Test-Path -LiteralPath $lock)) "stale preload branch refuses before body and owner creation"
  Invoke-RepoGit $laneA @("checkout", "codex/lane-a") | Out-Null

  # Preserve the dispatch claim across an ordinary in-lane commit.
  $staleHeadClaim = Invoke-RepoGit $laneA @("rev-parse", "HEAD")
  Invoke-RepoGit $laneA @("commit", "--allow-empty", "-m", "advance same branch before preload admission") | Out-Null
  $staleHeadMarker = Join-Path $root "stale-preload-head-negative-control.marker"
  $staleHeadPreload = Start-NodeFixture $pnpmScript @("run", "verify:static") $laneA "lane-a" $staleHeadMarker 0 @{} @{
    Branch = "codex/lane-a"
    ClaimedHead = $staleHeadClaim
  }
  Assert-True ($staleHeadPreload.Process.WaitForExit(20000)) 'pinned-H0 probe finishes'
  Write-Output "REPRO pinned-H0 ordinary-commit H0=$staleHeadClaim H1=$(Invoke-RepoGit $laneA @('rev-parse', 'HEAD')) gateExit=$($staleHeadPreload.Process.ExitCode) body=$(Test-Path $staleHeadMarker)"
  Complete-Fixture $staleHeadPreload 0 "same-branch commit retains admission" | Out-Null
  Wait-Condition { -not (Test-Path -LiteralPath $lock) } "advanced-head owner release"
  Assert-True (Test-Path -LiteralPath $staleHeadMarker) "advanced-head body executes"
  Write-Output "PASS pinned-H0 ordinary-commit H0=$staleHeadClaim H1=$(Invoke-RepoGit $laneA @('rev-parse', 'HEAD')) gateExit=$($staleHeadPreload.Process.ExitCode) body=True ownerReleased=True"

  # Detached review admission is explicit and bound to the exact immutable SHA.
  $detachedPreloadHead = Invoke-RepoGit $laneA @("rev-parse", "HEAD")
  Invoke-RepoGit $laneA @("checkout", "--detach", $detachedPreloadHead) | Out-Null
  $detachedPreloadMarker = Join-Path $root "detached-preload-exact.marker"
  $detachedPreload = Start-NodeFixture $pnpmScript @("run", "verify:static") $laneA "lane-a" $detachedPreloadMarker 0 @{} @{
    ImmutableHead = $detachedPreloadHead
  }
  Complete-Fixture $detachedPreload 0 "detached exact-head direct-command admission" | Out-Null
  Wait-Condition { -not (Test-Path -LiteralPath $lock) } "detached exact-head owner release"
  Assert-True ((Test-Path -LiteralPath $detachedPreloadMarker) -and
    -not (Test-Path -LiteralPath $lock)) "detached exact-head preload runs and releases"
  Invoke-RepoGit $laneA @("checkout", "codex/lane-a") | Out-Null

  Write-Output "PASS direct-command branch and detached exact-head identities"
}

function Test-E2eGate {
  $runner = Join-Path $laneA 'scripts/run-e2e-suite.mjs'
  Set-Content $runner @'
import fs from 'node:fs';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
require(process.env.E2E_CLIENT)('playwright');
const owner = JSON.parse(fs.readFileSync(process.env.E2E_OWNER, 'utf8'));
if (owner.lockId !== process.env.CHASE_SETS_HEAVY_SLOT_ID || owner.gate !== 'test:e2e:suite') throw Error('wrong owner');
fs.writeFileSync(process.env.ADMISSION_MARKER, JSON.stringify({args:process.argv.slice(2), owner}));
process.exit(Number(process.env.E2E_EXIT));
'@
  $package = Get-Content (Join-Path $laneA 'package.json') -Raw | ConvertFrom-Json -AsHashtable
  $package.scripts['test:e2e:suite'] = 'node scripts/run-e2e-suite.mjs'
  Set-Content (Join-Path $laneA 'package.json') ($package | ConvertTo-Json -Depth 4)
  Set-Content (Join-Path $laneA '.gitignore') "node_modules/`n.orchestrator/artifacts/"
  Set-Content (Join-Path $laneA 'pnpm-lock.yaml') "lockfileVersion: '9.0'`n`nsettings:`n  autoInstallPeers: true`n  excludeLinksFromLockfile: false`n`nimporters:`n`n  .: {}"
  Invoke-RepoGit $laneA @('add', '.') | Out-Null
  Invoke-RepoGit $laneA @('commit', '-m', 'inert closed e2e gate') | Out-Null
  $head = Invoke-RepoGit $laneA @('rev-parse', 'HEAD')
  foreach ($case in @(
      @{ name='success'; gate='test:e2e:suite'; suite=@('-E2eSuite','marketplace_account'); body=0; exit=0 },
      @{ name='child-failure'; gate='test:e2e:suite'; suite=@('-E2eSuite','marketplace_account'); body=29; exit=29 },
      @{ name='missing-suite'; gate='test:e2e:suite'; suite=@(); body=0; exit=73 },
      @{ name='invalid-suite'; gate='test:e2e:suite'; suite=@('-E2eSuite','marketplace_account;echo'); body=0; exit=1 },
      @{ name='wrong-gate'; gate='test'; suite=@('-E2eSuite','marketplace_account'); body=0; exit=73 }
    )) {
    $marker = Join-Path $root "e2e-$($case.name).json"
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName=$pwsh; $start.WorkingDirectory=$laneA; $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    Set-CleanAdmissionEnvironment $start
    $start.Environment['NODE_OPTIONS']="--require=`"$preloadForNode`""
    $start.Environment['ADMISSION_MARKER']=$marker
    $start.Environment['E2E_CLIENT']=$client; $start.Environment['E2E_OWNER']=$ownerPath; $start.Environment['E2E_EXIT']=[string]$case.body
    foreach ($argument in (@('-NoProfile','-File',$guard,'-Gate',$case.gate,'-Worktree',$laneA,'-Lane','lane-a','-Branch','codex/lane-a','-ClaimedHead',$head,'-ContainerRoot',$container) + $case.suite)) {
      $start.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::Start($start)
    $fixture = [pscustomobject]@{ Process=$process; Identity=@{pid=$process.Id; processStartUtc=$process.StartTime.ToUniversalTime().ToString('o')} }
    $startedProcesses.Add($fixture)
    Complete-Fixture $fixture $case.exit "e2e gate $($case.name)" | Out-Null
    Assert-True (-not (Test-Path $lock)) 'e2e wrapper releases exact owner'
    Assert-True ((Test-Path $marker) -eq ($case.name -in @('success', 'child-failure'))) 'e2e parameter refusal has no body effects'
    if (Test-Path $marker) {
      $observed = Get-Content $marker -Raw | ConvertFrom-Json
      Assert-True (($observed.args -join '|') -ceq '--|marketplace_account' -and $observed.owner.head -ceq $head) 'e2e arguments and exact owner HEAD'
    }
    Write-Output "PASS closed-e2e $($case.name) wrapperExit=$($process.ExitCode) body=$(Test-Path $marker) ownerReleased=True"
  }
}

function Test-LaneEvolution {
  Test-AdmissionGitIdentity
  $h0 = Invoke-RepoGit $laneA @('rev-parse', 'HEAD')
  $base = Invoke-RepoGit $laneA @('rev-parse', 'HEAD~1')
  Invoke-RepoGit $laneA @('checkout', '-b', 'fixture-upstream', $base) | Out-Null
  Set-Content (Join-Path $laneA 'upstream.txt') 'upstream'
  Invoke-RepoGit $laneA @('add', 'upstream.txt') | Out-Null
  Invoke-RepoGit $laneA @('commit', '-m', 'upstream advance') | Out-Null
  Invoke-RepoGit $laneA @('checkout', 'codex/lane-a') | Out-Null
  Invoke-RepoGit $laneA @('rebase', 'fixture-upstream') | Out-Null
  $h1 = Invoke-RepoGit $laneA @('rev-parse', 'HEAD')
  Assert-True ($h0 -cne $h1) 'ordinary rebase rewrites pinned HEAD'

  # Copy the product adapter read-only into the isolated fixture: it calls the
  # container client without configuration, exactly as production does.
  $adapter = Join-Path $laneA 'heavy-slot.mjs'
  $adapterSource = @(
    (Join-Path $PSScriptRoot '../main/scripts/lib/heavy-slot.mjs'),
    (Join-Path $PSScriptRoot '../../main/scripts/lib/heavy-slot.mjs')
  ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
  Assert-True ($null -ne $adapterSource) 'read-only product adapter is available'
  Copy-Item -LiteralPath $adapterSource -Destination $adapter
  $adapterProbe = Join-Path $laneA 'adapter-probe.mjs'
  Set-Content $adapterProbe @'
import { acquireHeavySlot } from './heavy-slot.mjs';
import fs from 'node:fs';
acquireHeavySlot('repository-gate');
fs.writeFileSync(process.env.ADMISSION_MARKER, 'body-ran');
'@
  $foreignHead = Invoke-RepoGit $laneA @('commit-tree', 'HEAD^{tree}', '-m', 'unrelated root history')
  foreach ($entry in @('preload', 'product-adapter')) {
    $script = if ($entry -ceq 'preload') { $pnpmScript } else { $adapterProbe }
    $arguments = if ($entry -ceq 'preload') { @('run', 'verify:static') } else { @() }
    foreach ($case in @(
        @{ name='rebased'; head=$h0; branch='codex/lane-a'; exit=0; message='' },
        @{ name='foreign-head'; head=$foreignHead; branch='codex/lane-a'; exit=73; message='heavy-admission: heavy-verifier: supplied exact launch-time HEAD does not match the live Git HEAD; command body was not executed' },
        @{ name='foreign-branch'; head=$h1; branch='codex/lane-b'; exit=73; message='heavy-admission: heavy-verifier: supplied branch identity does not match the live Git branch; command body was not executed' }
      )) {
      $marker = Join-Path $root "$entry-$($case.name).marker"
      $snapshot = "$marker.owner.json"
      $probe = Start-NodeFixture $script $arguments $laneA 'lane-a' $marker 0 @{ ADMISSION_OWNER_SNAPSHOT=$snapshot; ADMISSION_OWNER_PATH=$ownerPath } @{ Branch=$case.branch; ClaimedHead=$case.head }
      $output = Complete-Fixture $probe $case.exit "$entry $($case.name)"
      Wait-Condition { -not (Test-Path -LiteralPath $lock) } "$entry $($case.name) owner absent"
      Assert-True ((Test-Path $marker) -eq ($case.exit -eq 0)) "$entry $($case.name) body boundary"
      if ($case.exit -eq 0 -and $entry -ceq 'preload') {
        $observed = Get-Content $snapshot -Raw | ConvertFrom-Json
        Assert-True ($observed.head -ceq $h1 -and $observed.branch -ceq 'codex/lane-a' -and $observed.lane -ceq 'lane-a') 'rebased admission records live HEAD, not launch anchor'
      }
      if ($case.message) { Assert-True ($output.stderr.Trim() -ceq ($case.message + '; command body was not executed')) 'refusal remains byte-identical' }
      Write-Output "PASS $entry $($case.name) gateExit=$($probe.Process.ExitCode) body=$(Test-Path $marker) ownerReleased=True"
    }
    $foreignConfig = New-AdmissionConfiguration $laneB 'lane-b'
    $marker = Join-Path $root "$entry-foreign-record.marker"
    $probe = Start-NodeFixture $script $arguments $laneA 'lane-a' $marker 0 @{ CHASE_SETS_HEAVY_ADMISSION_CONFIG=$foreignConfig }
    $output = Complete-Fixture $probe 73 "$entry foreign lane record"
    Assert-True (-not (Test-Path $marker) -and -not (Test-Path $lock)) 'foreign record never executes or owns'
    Assert-True ($output.stderr.Trim() -ceq 'heavy-admission: heavy-verifier: worktree must name the canonical Git worktree root; command body was not executed') 'foreign-worktree refusal remains byte-identical'
    Write-Output "PASS $entry foreign-record gateExit=$($probe.Process.ExitCode) body=False ownerReleased=True"
  }
  Invoke-RepoGit $laneA @('branch', '-m', 'codex/lane-a-saved') | Out-Null
  Invoke-RepoGit $laneA @('checkout', '-b', 'codex/lane-a') | Out-Null
  $marker = Join-Path $root 'recreated-branch.marker'
  $probe = Start-NodeFixture $pnpmScript @('run','verify:static') $laneA 'lane-a' $marker 0 @{} @{ Branch='codex/lane-a'; ClaimedHead=$h0 }
  Complete-Fixture $probe 73 'recreated branch cannot borrow old branch reflog' | Out-Null
  Assert-True (-not (Test-Path $marker) -and -not (Test-Path $lock)) 'recreated branch has no body or owner'
  Invoke-RepoGit $laneA @('checkout', 'codex/lane-a-saved') | Out-Null
  Invoke-RepoGit $laneA @('branch', '-D', 'codex/lane-a') | Out-Null
  Invoke-RepoGit $laneA @('branch', '-m', 'codex/lane-a') | Out-Null
  Write-Output 'PASS recreated-branch gateExit=73 body=False ownerReleased=True'
}

try {
  Assert-DisposableRoot
  Assert-FreshChildEnvironmentBoundary
  if ($AcceptAnyHeadMutant) {
    $source = [IO.File]::ReadAllText($guard)
    $from = 'if ($ClaimedHead -cne $acquiredGitIdentity.Head -and'
    Assert-True ($source.Contains($from)) 'accept-any-head mutant target exists'
    [IO.File]::WriteAllText($guard, $source.Replace($from, 'if ($false -and'))
  }
  if ($LaneEvolutionOnly) { Test-LaneEvolution; return }
  if ($E2eGateOnly) { Test-E2eGate; return }
  if (-not $ClassifierOnly) {
  if ($IdentityOnly) { Test-AdmissionGitIdentity; return }
  $derivedFailure = $null
  try { Test-DerivedAdmission } catch { $derivedFailure = $_ }
  if ($DerivedOnly) {
    if ($derivedFailure) { throw $derivedFailure }
    return
  }

  # Parent-failing probe control: every production-like invocation shape must
  # refuse behind a live different owner before marker or output creation.
  $probeBlockerMarker = Join-Path $root "probe-blocker.marker"
  $probeBlockerRelease = Join-Path $root "probe-blocker.release"
  $probeBlocker = Start-NodeFixture $pnpmScript @("run", "verify:static") $laneA "lane-a" $probeBlockerMarker 0 @{
    ADMISSION_RELEASE_FILE = $probeBlockerRelease
  }
  Wait-Condition {
    if ($probeBlocker.Process.HasExited) {
      throw "probe blocker exited before ownership: exit=$($probeBlocker.Process.ExitCode) stderr=$($probeBlocker.Process.StandardError.ReadToEnd()) stdout=$($probeBlocker.Process.StandardOutput.ReadToEnd())"
    }
    $record = Read-Owner
    $record -and $record.lane -ceq "lane-a" -and $record.state -ceq "attached"
  } "live different owner for browser probe controls"
  $probeBlockerOwner = Get-Content -LiteralPath $ownerPath -Raw
  $probeCases = @(
    [pscustomobject]@{
      Name = "root pnpm run dev:e2e:probe"
      Start = { param($marker, $output) Start-RootPnpmFixture $laneB "lane-b" "dev:e2e:probe" $marker $output }
    },
    [pscustomobject]@{
      Name = "direct node browser-e2e-probe.mjs"
      Start = { param($marker, $output) Start-NodeFixture $probeScriptB @() $laneB "lane-b" $marker 0 @{ ADMISSION_OUTPUT = $output } }
    },
    [pscustomobject]@{
      Name = "native pnpm wrapper"
      Start = { param($marker, $output) Start-NativePnpmFixture $laneB "lane-b" "dev:e2e:probe" $marker $output }
    },
    [pscustomobject]@{
      Name = "JavaScript pnpm wrapper"
      Start = { param($marker, $output) Start-NodeFixture $pnpmScript @("run", "dev:e2e:probe") $laneB "lane-b" $marker 0 @{ ADMISSION_OUTPUT = $output } }
    },
    [pscustomobject]@{
      Name = "nested pnpm alias expansion"
      Start = { param($marker, $output) Start-NodeFixture $pnpmScript @("run", "dev:e2e:probe:nested") $laneB "lane-b" $marker 0 @{ ADMISSION_OUTPUT = $output } }
    },
    [pscustomobject]@{
      Name = "npm lifecycle-script classification"
      Start = { param($marker, $output) Start-LifecycleFixture $laneB "lane-b" $marker $output }
    }
  )
  $probeFailures = [Collections.Generic.List[string]]::new()
  foreach ($case in $probeCases) {
    $caseSlug = $case.Name -replace "[^A-Za-z0-9]+", "-"
    $caseMarker = Join-Path $root "$caseSlug.marker"
    $caseOutput = Join-Path $root "$caseSlug.output"
    $caseFixture = & $case.Start $caseMarker $caseOutput
    $completed = $caseFixture.Process.WaitForExit(20000)
    $caseStderr = $caseFixture.Process.StandardError.ReadToEnd()
    $caseStdout = $caseFixture.Process.StandardOutput.ReadToEnd()
    if (-not $completed -or
        $caseFixture.Process.ExitCode -ne 73 -or
        $caseStderr -notmatch "command body was not executed" -or
        (Test-Path -LiteralPath $caseMarker) -or
        (Test-Path -LiteralPath $caseOutput)) {
      $probeFailures.Add(
        "$($case.Name): completed=$completed exit=$($caseFixture.Process.ExitCode) marker=$(Test-Path -LiteralPath $caseMarker) output=$(Test-Path -LiteralPath $caseOutput) stderr=$caseStderr stdout=$caseStdout"
      )
    }
  }
  Assert-True ((Get-Content -LiteralPath $ownerPath -Raw) -ceq $probeBlockerOwner) "probe contenders leave the live different owner byte-exact"
  Set-Content -LiteralPath $probeBlockerRelease -Value "release"
  Complete-Fixture $probeBlocker 0 "browser probe control blocker" | Out-Null
  Wait-Condition { -not (Test-Path -LiteralPath $lock) } "browser probe control blocker release"
  Assert-True ($probeFailures.Count -eq 0) "all browser probe forms parent-fail before body:`n$($probeFailures -join "`n")"

  # Reversing the launch order gives the probe the same exclusive owner:
  # its inert body starts, and a repository gate refuses before its body.
  $reverseProbeMarker = Join-Path $root "reverse-probe.marker"
  $reverseProbeOutput = Join-Path $root "reverse-probe.output"
  $reverseProbeRelease = Join-Path $root "reverse-probe.release"
  $reverseProbe = Start-RootPnpmFixture $laneB "lane-b" "dev:e2e:probe" $reverseProbeMarker $reverseProbeOutput @{
    ADMISSION_RELEASE_FILE = $reverseProbeRelease
  }
  try {
    Wait-Condition {
      $record = Read-Owner
      $record -and
        $record.lane -ceq "lane-b" -and
        $record.gate -ceq "script-battery" -and
        $record.state -ceq "attached" -and
        (Test-Path -LiteralPath $reverseProbeMarker) -and
        (Test-Path -LiteralPath $reverseProbeOutput)
    } "browser probe owner and inert body"
  } catch {
    $reverseState = if ($reverseProbe.Process.HasExited) {
      "exited=$($reverseProbe.Process.ExitCode) stderr=$($reverseProbe.Process.StandardError.ReadToEnd()) stdout=$($reverseProbe.Process.StandardOutput.ReadToEnd())"
    } else {
      "live owner=$((Read-Owner | ConvertTo-Json -Compress)) marker=$(Test-Path -LiteralPath $reverseProbeMarker) output=$(Test-Path -LiteralPath $reverseProbeOutput)"
    }
    throw "browser probe owner and inert body diagnostic: $reverseState`n$($_.Exception.Message)"
  }
  $reverseGateMarker = Join-Path $root "reverse-gate.marker"
  $reverseGate = Start-NodeFixture $pnpmScript @("run", "verify:static") $laneA "lane-a" $reverseGateMarker
  $reverseGateOutput = Complete-Fixture $reverseGate 73 "repository gate behind browser probe"
  Assert-True ($reverseGateOutput.stderr -match "lane=lane-b branch=codex/lane-b pid=\d+" -and
    $reverseGateOutput.stderr -match "command body was not executed" -and
    -not (Test-Path -LiteralPath $reverseGateMarker)) "reverse-order repository gate parent-fails behind probe"
  Set-Content -LiteralPath $reverseProbeRelease -Value "release"
  Complete-Fixture $reverseProbe 0 "browser probe reverse-order owner" | Out-Null
  Wait-Condition { -not (Test-Path -LiteralPath $lock) } "browser probe reverse-order owner release"
  Assert-True ((Test-Path -LiteralPath $reverseProbeMarker) -and
    (Test-Path -LiteralPath $reverseProbeOutput) -and
    -not (Test-Path -LiteralPath $reverseGateMarker)) "reverse launch order admits exactly one command body"

  }
  # Static inventory covers Windows pnpm/npx aliases, shim-final CLI paths,
  # direct Node binary entrypoints, full-vs-focused Vitest, and builds.
  $classifierScript = Join-Path $root "classifier.cjs"
  $classifierResult = Join-Path $root "classifier-result.json"
  Set-Content -LiteralPath $classifierScript -Value @'
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
if (path.resolve(os.tmpdir()) !== path.resolve(process.env.TEMP) ||
    path.resolve(process.env.TEMP) !== path.resolve(process.env.TMP)) {
  throw new Error("fixture Node temp paths do not agree");
}
const admission = require(process.env.ADMISSION_PRELOAD);
const fullScripts = {
  typecheck: "tsc --noEmit",
  format: "prettier . --check",
  "test:unit": "vitest run --config ./vitest.config.ts",
  focused: "vitest run source/focused.test.ts",
  "dev:e2e:probe": "node ./scripts/browser-e2e-probe.mjs",
  "dev:e2e:probe:alias": "pnpm run dev:e2e:probe",
  "dev:e2e:probe:nested": "pnpm run dev:e2e:probe:alias",
  "test:e2e:direct-suite": "node ./scripts/run-e2e-suite.mjs",
  "suite:alias": "pnpm run test:e2e:direct-suite",
  "suite:node-alias": "node C:/tools/pnpm.cjs run suite:alias",
  "suite:data-node": "node cheap.mjs ./scripts/run-e2e-suite.mjs",
  "suite:data-echo": "echo ./scripts/run-e2e-suite.mjs",
  "suite:data-compound": "node cheap.mjs && echo ./scripts/run-e2e-suite.mjs",
  "suite:data-alias": "pnpm run suite:data-node",
  "suite:data-nested-alias": "pnpm run suite:data-alias",
  "suite:data-pnpm": "echo pnpm run test:e2e:suite",
  "suite:data-node-pnpm": "node cheap.mjs pnpm run test:e2e:suite",
  "suite:data-exec": "pnpm exec node cheap.mjs run test:e2e:suite",
  "lookalike:probe-backup": "node ./scripts/browser-e2e-probe.mjs.backup",
  "lookalike:probe-prefixed": "node ./scripts/not-browser-e2e-probe.mjs",
  "lookalike:suite-backup": "node ./scripts/run-e2e-suite.mjs.backup",
  "lookalike:suite-prefixed": "node ./scripts/not-run-e2e-suite.mjs",
  "probe:cheap": "node ./scripts/health-probe.mjs",
};
const cases = [
  [["node", "C:\\tools\\pnpm.cjs", "run", "verify:static"], "repository-gate"],
  [["node", "C:\\tools\\pnpm.cjs", "--workspace-root", "verify:static"], "repository-gate"],
  [["C:\\tools\\pnpm.exe", "run", "verify:static"], "repository-gate"],
  [["node.exe", "C:\\tools\\pnpm.exe", "run", "verify:static"], "repository-gate"],
  [["node", "C:\\tools\\pnpm.cjs", "test"], "repository-gate"],
  [["node", "C:\\tools\\pnpm.cjs", "run", "test:scripts"], "script-battery"],
  [["node", "C:\\tools\\pnpm.cjs", "run", "build"], "build"],
  [["node", "C:\\tools\\pnpm.cjs", "exec", "playwright", "test"], "playwright"],
  [["node", "C:\\tools\\npx-cli.js", "playwright", "test"], "playwright"],
  [["node", "C:\\repo\\node_modules\\playwright\\cli.js", "test"], "playwright"],
  [["node", "C:\\repo\\node_modules\\@playwright\\test\\cli.js", "test"], "playwright"],
  [["node", "C:\\repo\\node_modules\\vitest\\vitest.mjs", "run", "--config", "vitest.config.ts"], "vitest-full"],
  [["node", "C:\\repo\\node_modules\\vitest\\vitest.mjs", "run", "source\\one.test.ts"], null],
  [["node", "C:\\repo\\scripts\\run-workspaces.mjs", "test", "--concurrency=4"], "script-battery"],
  [["node", "C:\\repo\\scripts\\run-workspaces.mjs", "build"], "build"],
  [["node", "C:\\repo\\scripts\\react-router-build.mjs"], "build"],
  [["node", "C:\\repo\\scripts\\browser-e2e-probe.mjs"], "script-battery"],
  [["node", "C:\\repo\\scripts\\run-e2e-suite.mjs"], "playwright"],
  [["node", "C:\\tools\\pnpm.cjs", "run", "dev:e2e:probe"], "script-battery"],
  [["C:\\tools\\pnpm.exe", "run", "dev:e2e:probe"], "script-battery"],
  [["node.exe", "C:\\tools\\pnpm.exe", "run", "dev:e2e:probe"], "script-battery"],
  [["node", "C:\\tools\\pnpm.cjs", "run", "dev:e2e:probe:nested"], "script-battery"],
  [["node", "C:\\tools\\pnpm.cjs", "run", "test:e2e:direct-suite"], "playwright"],
  [["node", "C:\\tools\\pnpm.cjs", "run", "test:unit"], "vitest-full"],
  [["node", "C:\\tools\\pnpm.cjs", "run", "focused"], null],
  [["node", "C:\\tools\\pnpm.cjs", "run", "typecheck"], null],
  [["node", "C:\\tools\\pnpm.cjs", "run", "format"], null],
  [["node", "C:\\tools\\pnpm.cjs", "run", "probe:cheap"], null],
  [["node", "C:\\repo\\scripts\\health-probe.mjs"], null],
  [["node", "C:\\repo\\scripts\\browser-e2e-probe.mjs.backup"], null],
  [["node", "C:\\repo\\scripts\\not-browser-e2e-probe.mjs"], null],
  [["node", "C:\\repo\\scripts\\run-e2e-suite.mjs.backup"], null],
  [["node", "C:\\repo\\scripts\\not-run-e2e-suite.mjs"], null],
  [["node", "C:\\tools\\pnpm.cjs", "run", "lookalike:probe-backup"], null],
  [["node", "C:\\tools\\pnpm.cjs", "run", "lookalike:probe-prefixed"], null],
  [["node", "C:\\tools\\pnpm.cjs", "run", "lookalike:suite-backup"], null],
  [["node", "C:\\tools\\pnpm.cjs", "run", "lookalike:suite-prefixed"], null],
];
for (const name of ["test:e2e", "test:e2e:deployed", "test:e2e:headed", "test:e2e:suite", "suite:alias", "suite:node-alias"]) {
  for (const prefix of [["node", "C:/tools/pnpm.cjs"], ["C:/tools/pnpm.exe"], ["node", "C:/tools/pnpm.exe"]]) {
    for (const args of [["run", name], ["run-script", name], ["--workspace-root", name], ["--filter", "synthetic", "run", name]]) {
      cases.push([[...prefix, ...args], "playwright"]);
    }
  }
}
cases.push([["node", "C:/tools/pnpm.cjs", "exec", "node", "./scripts/run-e2e-suite.mjs"], "playwright"]);
for (const name of Object.keys(fullScripts).filter((name) => name.startsWith("suite:data-"))) {
  cases.push([["node", "C:/tools/pnpm.cjs", "run", name], null]);
}
cases.push([["node", "cheap.mjs", "./scripts/run-e2e-suite.mjs"], null]);
const results = cases.map(([argv, expected]) => ({
  argv,
  expected,
  actual: admission.classifyCommand(argv, { packageScripts: fullScripts, cwd: process.cwd(), worktree: process.cwd() }),
}));
fs.writeFileSync(process.env.ADMISSION_CLASSIFIER_RESULT, JSON.stringify(results));
// Freeze each script map independently; selecting a workspace is not resolution.
const workspace = "@chase-sets/bounded-context-runtime";
const filtered = ["--filter", workspace, "run", "test"];
const windowsNode = "C:\\Program Files\\nodejs\\node.exe";
const prefixes = [
  ["C:\\Program Files\\pnpm\\pnpm.exe"], // synthetic native shape, not the installed SEA argv
  ["C:\\Program Files\\pnpm\\pnpm.exe", "C:\\Program Files\\pnpm\\pnpm.exe"],
  ...["cjs", "js", "mjs"].map((ext) => [windowsNode, `C:\\Program Files\\pnpm\\pnpm.${ext}`]),
];
const maps = {
  root: { "test:db": "pnpm run verify:test-db" },
  workspace: { test: "vitest run --config ./vitest.config.ts", "test:unit": "vitest run", "test:db": "vitest run" },
  empty: {},
};
let filteredChecks = 0;
function checkFiltered(actual, expected, label) {
  filteredChecks += 1;
  if (actual !== expected) throw new Error(`filtered classification ${label}: expected=${expected} actual=${actual}`);
}
for (const [mapName, scripts] of Object.entries(maps)) {
  const controls = [
    [filtered, "script-battery"],
    [[...filtered, "inline-apply.db.test.ts", "--reporter=verbose"], "script-battery"],
    [[...filtered, "inline-apply.db.test.ts", "--reporter=verbose",
      "--testNamePattern=settles without starting the handler when connect outlasts the hard budget"], "script-battery"],
    [["--filter", "@chase-sets/unknown-exact-name", "run", "test"], "script-battery"],
    [[...filtered, "--filter", "*", "exec", "playwright", "test"], "script-battery"],
    ...["test:unit", "test:db"].map((name) => [["--filter", workspace, "run", name],
      mapName === "workspace" ? "vitest-full" : mapName === "root" && name === "test:db" ? "repository-gate" : null]),
    [["--filter", workspace, "test"], "repository-gate"],
    [["--filter", workspace, "run", "test:fast"], "repository-gate"],
    [["test"], "repository-gate"], [["run", "test"], "repository-gate"],
    [["--filter", "run", "test"], "repository-gate"],
    ...["chase-sets", ".", "", "*", "@chase-sets/*", "./packages/a", "!@chase-sets/a", "@chase-sets/a...", "...@chase-sets/a", "@chase-sets/A", "@chase-sets/a_b", "@other/a"].map((selector) =>
      [["--filter", selector, "run", "test"], "repository-gate"]),
    [["--filter", workspace, "--filter", workspace, "run", "test"], "repository-gate"],
    [["-F", workspace, "run", "test"], "repository-gate"],
    [[`--filter=${workspace}`, "run", "test"], "repository-gate"],
    [["--filter", workspace, "run-script", "test"], "repository-gate"],
    ...["--recursive", "-r", "--workspace-root"].map((option) => [[option, ...filtered], "repository-gate"]),
    [["--dir", "C:\\repo", ...filtered], "repository-gate"],
    [["--filter", workspace, "run", "build"], "build"],
    [["--filter", workspace, "run", "test:scripts"], "script-battery"],
  ];
  for (const prefix of prefixes) {
    for (const [args, expected] of controls) {
      // The SEA duplicate remains in the legacy argument list. Without "run",
      // legacy classification sees the executable as the direct command.
      const seaNoRun = prefix === prefixes[1] &&
        ((args.length === 1 && args[0] === "test") ||
         (args.length === 3 && args[0] === "--filter" && args[1] === workspace && args[2] === "test"));
      checkFiltered(admission.classifyCommand([...prefix, ...args], { packageScripts: scripts }),
        seaNoRun ? null : expected,
        `${mapName} ${JSON.stringify([...prefix, ...args])}`);
    }
  }
  const native = prefixes[1];
  checkFiltered(admission.classifyCommand([native[0], "C:\\Program Files\\pnpm\\.\\pnpm.exe", ...filtered],
    { packageScripts: scripts }), "script-battery", `resolved native duplicate ${mapName}`);
  for (const other of ["C:\\other\\pnpm.exe", "C:\\Program Files\\pnpm\\PNPM.EXE"]) {
    checkFiltered(admission.classifyCommand([native[0], other, ...filtered], { packageScripts: scripts }),
      "repository-gate", `non-duplicate ${mapName} ${other}`);
  }
  checkFiltered(admission.classifyCommand([...native, "run", "coverage:fast"],
    { packageScripts: { ...scripts, "coverage:fast": "pnpm run test:scripts" } }),
    "script-battery", `legacy native ${mapName} coverage:fast`);
  const text = `pnpm --filter ${workspace} run test`;
  const aliases = {
    ...scripts, executed: text, nested: "pnpm run executed",
    data: `echo ${text}`, compound: `node cheap.mjs && echo ${text}`,
    "nested-data": "pnpm run data", "deeper-data": "pnpm run nested-data",
  };
  for (const [command, expected] of [
    [text, "script-battery"], ["pnpm run nested", "script-battery"],
    [`node cheap.mjs && ${text}`, "script-battery"],
    [`echo ${text}`, "repository-gate"], [`node cheap.mjs ${text}`, "repository-gate"],
    ["pnpm run deeper-data", "repository-gate"], ["pnpm run compound", "repository-gate"],
    ["echo pnpm run nested", "repository-gate"],
    ["node cheap.mjs pnpm run nested", "repository-gate"],
    ["pnpm exec node cheap.mjs run nested", "repository-gate"],
    [`"ENV=value" ${text}`, "repository-gate"], [`ENV="a b" ${text}`, "repository-gate"],
    ...["&&", "||", ";"].flatMap((separator) => [
      [`ENV="cheap ${separator} ${text} --reporter=verbose ${separator} tail" node cheap.mjs`, "repository-gate"],
      [`echo 'cheap ${separator} ${text} --reporter=verbose ${separator} tail'`, "repository-gate"],
    ]),
    [`${text} "unterminated`, "repository-gate"],
    [`${text} 'unterminated`, "repository-gate"],
    ["echo pnpm run test:scripts", "script-battery"],
    ["echo run-workspaces.mjs test", "script-battery"],
  ]) checkFiltered(admission.classifyScriptText(command, aliases, new Set()), expected, `${mapName} ${command}`);
  for (const ext of ["cjs", "js", "mjs"]) {
    const script = `C:\\Program Files\\pnpm\\pnpm.${ext}`;
    const shellScript = `"${windowsNode}" "${script}" --filter ${workspace} run test`;
    checkFiltered(admission.classifyScriptText(shellScript, aliases, new Set()), "script-battery", shellScript);
    for (const option of ["-e", "-p", "--eval", "--print", "--title", "--env-file", "--require", "--import", "--inspect-port"]) {
      const argv = [windowsNode, option, script, ...filtered];
      checkFiltered(admission.classifyCommand(argv, { packageScripts: aliases }), null, JSON.stringify(argv));
      const shell = `"${windowsNode}" ${option} "${script}" --filter ${workspace} run test`;
      checkFiltered(admission.classifyScriptText(shell, aliases, new Set()), ext === "mjs" ? null : "repository-gate", shell);
    }
    checkFiltered(admission.classifyCommand(["C:\\tools\\cheap.exe", script, ...filtered], { packageScripts: aliases }),
      "repository-gate", `cheap executable ${ext}`);
    checkFiltered(admission.classifyScriptText(`echo ${shellScript}`, aliases, new Set()),
      ext === "mjs" ? null : "repository-gate", `echo ${shellScript}`);
    for (const lookalike of [`not-pnpm.${ext}`, `pnpm.${ext}.backup`]) {
      checkFiltered(admission.classifyCommand([windowsNode, `C:\\tools\\${lookalike}`, ...filtered], { packageScripts: aliases }), null, lookalike);
    }
  }
}
console.log(`FILTERED_CLASSIFIER checks=${filteredChecks} maps=root,workspace,empty synthetic and SEA-shaped native forms, tails, modes, aliases and frozen controls`);
const runtimeRoot = path.join(path.dirname(process.env.ADMISSION_PRELOAD), "runtime modes with spaces");
fs.mkdirSync(runtimeRoot);
const runtimeProbe = path.join(runtimeRoot, "probe.cjs");
fs.writeFileSync(runtimeProbe, `
const argv = [...process.argv], execArgv = [...process.execArgv];
process.argv = [process.execPath];
const admission = require(process.env.ADMISSION_PRELOAD);
console.log("RUNTIME " + JSON.stringify({argv, execArgv,
  actual: admission.classifyCommand(argv, {packageScripts: {}, execArgv})}));
`);
const runtimeEnv = {...process.env, ADMISSION_RUNTIME_PROBE: runtimeProbe};
const nativeProbe = path.join(runtimeRoot, "native-probe.cjs");
fs.writeFileSync(nativeProbe, `
const argv = [...process.argv], execArgv = [...process.execArgv];
process.argv = [process.execPath];
const admission = require(process.env.ADMISSION_PRELOAD);
console.log("NATIVE " + JSON.stringify({argv, execArgv,
  actual: admission.classifyCommand(argv, {packageScripts: {}, execArgv})}));
process.exit(0);
`);
let nativeChecks = 0;
for (const [args, expected] of [
  [[...filtered, "inline-apply.db.test.ts", "--reporter=verbose"], "script-battery"],
  [["run", "test"], "repository-gate"],
]) {
  const env = {...process.env, NODE_OPTIONS: `--require=${JSON.stringify(nativeProbe)}`};
  for (const name of ["CHASE_SETS_HEAVY_ADMISSION_CONFIG", "CHASE_SETS_HEAVY_SLOT_ID"]) delete env[name];
  const child = require("node:child_process").spawnSync(process.env.ADMISSION_NATIVE_PNPM, args,
    {env, encoding: "utf8", windowsHide: true});
  if (child.error || child.status !== 0) throw new Error(`native runtime exit=${child.status} ${child.error ?? child.stderr}`);
  const lines = child.stdout.split(/\r?\n/).filter((line) => line.startsWith("NATIVE "));
  if (lines.length !== 1) throw new Error(`native runtime expected one observation: ${child.stdout}`);
  const observation = JSON.parse(lines[0].slice(7));
  if (path.resolve(observation.argv[0]) !== path.resolve(process.env.ADMISSION_NATIVE_PNPM) ||
      path.resolve(observation.argv[1]) !== path.resolve(observation.argv[0]) ||
      observation.actual !== expected || JSON.stringify(observation.argv.slice(2)) !== JSON.stringify(args)) {
    throw new Error(`native runtime shape/kind drift: expected=${expected} ${lines[0]}`);
  }
  console.log(`FILTERED_NATIVE_RUNTIME expected=${expected} ${lines[0]}`);
  nativeChecks += 1;
}
console.log(`FILTERED_NATIVE_RUNTIME checks=${nativeChecks} real pnpm.exe SEA argv, no admission config or slot token`);
const evalProbe = "require(process.env.ADMISSION_RUNTIME_PROBE)";
const optionValue = path.join(runtimeRoot, "option value", "pnpm.cjs");
fs.mkdirSync(path.dirname(optionValue));
fs.writeFileSync(optionValue, "");
let runtimeChecks = 0;
function checkRuntime(args, expected, label) {
  const child = require("node:child_process").spawnSync(process.execPath, args,
    {env: runtimeEnv, encoding: "utf8", windowsHide: true});
  if (child.error || child.status !== 0) throw new Error(`${label}: exit=${child.status} ${child.error ?? child.stderr}`);
  const lines = child.stdout.split(/\r?\n/).filter((line) => line.startsWith("RUNTIME "));
  if (lines.length !== 1) throw new Error(`${label}: expected one runtime observation: ${child.stdout}`);
  const observation = JSON.parse(lines[0].slice(8));
  if (observation.actual !== expected) throw new Error(`${label}: expected=${expected} ${lines[0]}`);
  console.log(`${label} ${lines[0]}`);
  runtimeChecks += 1;
  return observation;
}
for (const ext of ["cjs", "js", "mjs"]) {
  const script = path.join(runtimeRoot, `pnpm.${ext}`);
  fs.writeFileSync(script, `import(${JSON.stringify(require("node:url").pathToFileURL(runtimeProbe).href)});`);
  for (const prefix of [[], ["--title", optionValue], ["--title=-e"], ["--require", optionValue]]) {
    const observed = checkRuntime([...prefix, script, ...filtered], "script-battery", `script-${ext}`);
    if (observed.argv[1] !== script) throw new Error("Node script entry was not preserved");
  }
  for (const mode of ["-e", "-p", "--eval", "--print", "-pe"]) {
    const observed = checkRuntime([mode, evalProbe, script, ...filtered], "repository-gate", `${mode}-${ext}`);
    if (observed.argv[1] !== script || observed.execArgv[0] !== mode) throw new Error("Node mode was not normalized as expected");
  }
  for (const prefix of [["--title", optionValue], ["--require", optionValue], ["--env-file", optionValue]]) {
    checkRuntime([...prefix, "-e", evalProbe, script, ...filtered], "repository-gate", `option-value-${ext}`);
  }
  for (const prefix of [[`--eval=${evalProbe}`], ["--print", `--eval=${evalProbe}`]]) {
    checkRuntime([...prefix, script, ...filtered], "repository-gate", `eval-equals-${ext}`);
  }
  for (const mode of ["-e", "-p"]) {
    for (const [name, kind] of [["test:scripts", "script-battery"], ["build", "build"], ["test:fast", "repository-gate"]]) {
      checkRuntime([mode, evalProbe, script, "run", name], kind, `legacy-${mode}-${ext}-${name}`);
    }
  }
}
console.log(`FILTERED_RUNTIME checks=${runtimeChecks} real Node script/eval/print and option-arity controls`);
const source = fs.readFileSync(process.env.ADMISSION_PRELOAD, "utf8");
const duplicateAnchor = 'if (packagedPnpm && isFilteredWorkspaceTest(packagedArguments)) return "script-battery";';
if (source.split(duplicateAnchor).length !== 2) throw new Error("missing unique SEA duplicate mutant anchor");
try {
  fs.writeFileSync(process.env.ADMISSION_PRELOAD, source.replace(duplicateAnchor, "/* MUTANT omitted SEA duplicate eligibility */"));
  const args = [...filtered, "inline-apply.db.test.ts", "--reporter=verbose"];
  const env = {...process.env, NODE_OPTIONS: `--require=${JSON.stringify(nativeProbe)}`};
  for (const name of ["CHASE_SETS_HEAVY_ADMISSION_CONFIG", "CHASE_SETS_HEAVY_SLOT_ID"]) delete env[name];
  const child = require("node:child_process").spawnSync(process.env.ADMISSION_NATIVE_PNPM, args,
    {env, encoding: "utf8", windowsHide: true});
  const line = child.stdout?.split(/\r?\n/).find((entry) => entry.startsWith("NATIVE "));
  if (child.status !== 0 || !line || JSON.parse(line.slice(7)).actual !== "repository-gate") {
    throw new Error(`SEA duplicate mutant survived: exit=${child.status} stdout=${child.stdout} stderr=${child.stderr}`);
  }
  console.log("CLASSIFIER_MUTANT SEA-duplicate-omitted killed by real pnpm.exe: repository-gate instead of script-battery");
} finally {
  fs.writeFileSync(process.env.ADMISSION_PRELOAD, source);
}
const modeAnchor = "(packagedPnpm || nodeScriptMode) && isExecutedPnpm";
if (source.split(modeAnchor).length !== 2) throw new Error("missing unique runtime-mode mutant anchor");
try {
  fs.writeFileSync(process.env.ADMISSION_PRELOAD, source.replace(modeAnchor, "isExecutedPnpm"));
  for (const mode of ["-e", "-p"]) {
    checkRuntime([mode, evalProbe, path.join(runtimeRoot, "pnpm.cjs"), ...filtered], "script-battery", `mode-omitted-${mode}`);
  }
  console.log("CLASSIFIER_MUTANT runtime-mode-omitted killed by real eval/print data gaining script-battery");
} finally {
  fs.writeFileSync(process.env.ADMISSION_PRELOAD, source);
}
for (const [name, before, after, expectedFailure] of [
  ["omit-registered-root", 'if (E2E_SCRIPTS.has(scriptName)) return scriptIsExecuted ? "playwright" : null;', 'if (E2E_SCRIPTS.has(scriptName)) return "script-battery";', "test:e2e:suite"],
  ["suite-data-overmatch", 'return script === "run-e2e-suite.mjs";', 'return tokens.some((token) => basename(token) === "run-e2e-suite.mjs");', "suite:data-node"],
]) {
  if (source.split(before).length !== 2) throw new Error(`missing unique mutant anchor: ${name}`);
  try {
    fs.writeFileSync(process.env.ADMISSION_PRELOAD, source.replace(before, after));
    delete require.cache[require.resolve(process.env.ADMISSION_PRELOAD)];
    const mutant = require(process.env.ADMISSION_PRELOAD);
    const killed = cases.some(([argv, expected]) => argv.includes(expectedFailure) &&
      mutant.classifyCommand(argv, { packageScripts: fullScripts }) !== expected);
    if (!killed) throw new Error(`surviving classifier mutant: ${name}`);
    console.log(`CLASSIFIER_MUTANT ${name} killed by ${expectedFailure}`);
  } finally {
    fs.writeFileSync(process.env.ADMISSION_PRELOAD, source);
  }
}
'@
  $classifierStart = [Diagnostics.ProcessStartInfo]::new()
  $classifierStart.FileName = $node
  $classifierStart.UseShellExecute = $false
  Set-CleanAdmissionEnvironment $classifierStart
  [void]$classifierStart.ArgumentList.Add($classifierScript)
  $classifierStart.Environment["NODE_OPTIONS"] = ""
  [void]$classifierStart.Environment.Remove("CHASE_SETS_HEAVY_ADMISSION_CONFIG")
  $classifierStart.Environment["ADMISSION_PRELOAD"] = $preload
  $classifierStart.Environment["ADMISSION_NATIVE_PNPM"] = $nativePnpm
  $classifierStart.Environment["ADMISSION_CLASSIFIER_RESULT"] = $classifierResult
  $classifierProcess = [Diagnostics.Process]::Start($classifierStart)
  $classifierProcess.WaitForExit()
  Assert-True ($classifierProcess.ExitCode -eq 0) "command-shape classifier fixture executes"
  $classification = Get-Content -LiteralPath $classifierResult -Raw | ConvertFrom-Json
  foreach ($case in $classification) {
    Assert-True ([string]$case.actual -ceq [string]$case.expected) "shape '$($case.argv -join ' ')' classifies as '$($case.expected)' (actual '$($case.actual)')"
  }
  Write-Output "PASS classifier forms=$($classification.Count), eight suite data-position negatives, basename boundaries and two omission/boundary mutants"
  if ($ClassifierOnly) { return }

  $focusedMarker = Join-Path $root "focused.marker"
  $focused = Start-NodeFixture $vitestScript @("run", "source\focused.test.ts") $laneA "lane-a" $focusedMarker
  Complete-Fixture $focused 0 "focused Vitest file" | Out-Null
  Assert-True ((Test-Path -LiteralPath $focusedMarker) -and -not (Test-Path -LiteralPath $lock)) "focused Vitest remains outside the exclusive slot"
  $typeMarker = Join-Path $root "typecheck.marker"
  $typecheck = Start-NodeFixture $pnpmScript @("run", "typecheck") $laneA "lane-a" $typeMarker
  Complete-Fixture $typecheck 0 "focused typecheck" | Out-Null
  Assert-True ((Test-Path -LiteralPath $typeMarker) -and -not (Test-Path -LiteralPath $lock)) "typecheck remains outside the exclusive slot"
  $alternateTypeMarker = Join-Path $root "alternate-pnpm-typecheck.marker"
  $alternateTypecheck = Start-AlternatePnpmFixture $laneB "lane-b" "typecheck" $alternateTypeMarker
  Complete-Fixture $alternateTypecheck 0 "alternate native pnpm cheap script" | Out-Null
  Assert-True ((Test-Path -LiteralPath $alternateTypeMarker) -and
    -not (Test-Path -LiteralPath $lock)) "pnpm script shell delegates cheap lifecycle work outside the slot"

  Test-LaneEvolution
  Test-E2eGate

  # Two inert lanes: a repository gate wins and a direct Playwright body never
  # executes. The refusal includes only bounded owner identity.
  $gateMarker = Join-Path $root "gate.marker"
  $playwrightMarker = Join-Path $root "playwright.marker"
  $gateRelease = Join-Path $root "gate.release"
  $gateOwner = Start-NodeFixture $pnpmScript @("run", "verify:static") $laneA "lane-a" $gateMarker 0 @{
    ADMISSION_RELEASE_FILE = $gateRelease
  }
  try {
    Wait-Condition {
      $record = Read-Owner
      $record -and
        $record.schemaVersion -eq 5 -and
        $record.lane -ceq "lane-a" -and
        $record.identityMode -ceq "branch" -and
        $record.branch -ceq "codex/lane-a" -and
        $record.head -ceq (Invoke-RepoGit $laneA @("rev-parse", "HEAD")).ToLowerInvariant()
    } "schema-v4 Git-bound gate owner"
  } catch {
    if ($gateOwner.Process.HasExited) {
      $gateOwnerError = $gateOwner.Process.StandardError.ReadToEnd()
      throw "schema-v4 gate fixture exited $($gateOwner.Process.ExitCode) before ownership: $gateOwnerError"
    }
    throw
  }
  $playwrightLoser = Start-NodeFixture $playwrightScript @("test") $laneB "lane-b" $playwrightMarker
  $loserOutput = Complete-Fixture $playwrightLoser 73 "direct Playwright contender"
  Assert-True ($loserOutput.stderr -match "lane=lane-a branch=codex/lane-a pid=\d+" -and
    $loserOutput.stderr -match "command body was not executed") "loser returns bounded exact owner identity"
  Set-Content -LiteralPath $gateRelease -Value "release"
  Complete-Fixture $gateOwner 0 "repository gate owner" | Out-Null
  Wait-Condition { -not (Test-Path -LiteralPath $lock) } "repository gate owner release"
  Assert-True ((Test-Path -LiteralPath $gateMarker) -and -not (Test-Path -LiteralPath $playwrightMarker)) "exactly one concurrent command body executes"

  # Exact inter-attempt lock-gap race: lane A releases attempt one; lane B
  # acquires while starting its Playwright body; lane A attempt two is refused.
  $attemptOneMarker = Join-Path $root "attempt-one.marker"
  $attemptOne = Start-NodeFixture $pnpmScript @("run", "verify:static") $laneA "lane-a" $attemptOneMarker 100
  Complete-Fixture $attemptOne 0 "first lane-a attempt" | Out-Null
  Wait-Condition { -not (Test-Path -LiteralPath $lock) } "inter-attempt lock gap"
  $reviewMarker = Join-Path $root "review-playwright.marker"
  $reviewRelease = Join-Path $root "review.release"
  $review = Start-NodeFixture $playwrightScript @("test") $laneB "lane-b" $reviewMarker 0 @{
    ADMISSION_RELEASE_FILE = $reviewRelease
  }
  Wait-Condition { (Test-Path -LiteralPath $reviewMarker) -and (Read-Owner).lane -ceq "lane-b" } "review Playwright admission inside the gap"
  $attemptTwoMarker = Join-Path $root "attempt-two.marker"
  $attemptTwo = Start-NodeFixture $pnpmScript @("run", "verify:static") $laneA "lane-a" $attemptTwoMarker
  $attemptTwoOutput = Complete-Fixture $attemptTwo 73 "second lane-a attempt"
  Assert-True ($attemptTwoOutput.stderr -match "lane=lane-b branch=codex/lane-b pid=\d+") "inter-attempt loser names the review owner"
  Set-Content -LiteralPath $reviewRelease -Value "release"
  Complete-Fixture $review 0 "review Playwright owner" | Out-Null
  Wait-Condition { -not (Test-Path -LiteralPath $lock) } "review owner release"
  Assert-True ((Test-Path -LiteralPath $attemptOneMarker) -and
    (Test-Path -LiteralPath $reviewMarker) -and
    -not (Test-Path -LiteralPath $attemptTwoMarker)) "inter-attempt race never overlaps heavy bodies"

  # A cheap outer Node process keeps the preload. Its nested pnpm child is
  # classified and refused behind another lane's direct Vitest owner.
  $vitestOwnerMarker = Join-Path $root "vitest-owner.marker"
  $vitestRelease = Join-Path $root "vitest.release"
  $vitestOwner = Start-NodeFixture $vitestScript @("run", "--config", "vitest.config.ts") $laneA "lane-a" $vitestOwnerMarker 0 @{
    ADMISSION_RELEASE_FILE = $vitestRelease
  }
  Wait-Condition { $record = Read-Owner; $record -and $record.gate -ceq "vitest-full" } "full Vitest owner"
  $nestedMarker = Join-Path $root "nested-pnpm.marker"
  $nested = Start-NodeFixture $outerScript @() $laneB "lane-b" $nestedMarker 0 @{
    NESTED_PNPM = $pnpmScript
  }
  $nestedOutput = Complete-Fixture $nested 73 "nested pnpm contender"
  Assert-True ($nestedOutput.stderr -match "lane=lane-a" -and -not (Test-Path -LiteralPath $nestedMarker)) "nested pnpm child is guarded before its body"
  $shimMarker = Join-Path $root "pnpm-shim.marker"
  $shim = Start-ShimFixture $pnpmShim $laneB "lane-b" $shimMarker
  $shimOutput = Complete-Fixture $shim 73 "Windows pnpm.cmd shim contender"
  Assert-True ($shimOutput.stderr -match "lane=lane-a" -and -not (Test-Path -LiteralPath $shimMarker)) "Windows shim reaches the same fail-closed admission path"
  $nativePnpmContender = Start-NativePnpmFixture $laneB "lane-b"
  $nativePnpmOutput = Complete-Fixture $nativePnpmContender 73 "native pnpm.exe direct-binary contender"
  Assert-True ($nativePnpmOutput.stderr -match "lane=lane-a" -and
    $nativePnpmOutput.stderr -match "command body was not executed") "native pnpm.exe cannot bypass the shared slot"
  $alternateMarker = Join-Path $root "alternate-native-pnpm.marker"
  $alternatePnpmContender = Start-AlternatePnpmFixture $laneB "lane-b" "verify:static" $alternateMarker
  $alternatePnpmOutput = Complete-Fixture $alternatePnpmContender 73 "alternate native pnpm.exe script-shell contender"
  Assert-True ($alternatePnpmOutput.stderr -match "lane=lane-a" -and
    $alternatePnpmOutput.stderr -match "command body was not executed" -and
    -not (Test-Path -LiteralPath $alternateMarker)) "native pnpm binary that ignores NODE_OPTIONS still cannot start a heavy lifecycle body"
  Set-Content -LiteralPath $vitestRelease -Value "release"
  Complete-Fixture $vitestOwner 0 "full Vitest owner" | Out-Null
  Wait-Condition { -not (Test-Path -LiteralPath $lock) } "Vitest owner release"

  # Forced admission-holder death cannot steal the lock while the guarded
  # direct-binary process remains alive; exact stale recovery follows its exit.
  $forcedMarker = Join-Path $root "forced-owner.marker"
  $forcedRelease = Join-Path $root "forced.release"
  $forcedOwner = Start-NodeFixture $playwrightScript @("test") $laneA "lane-a" $forcedMarker 0 @{
    ADMISSION_RELEASE_FILE = $forcedRelease
  }
  Wait-Condition { $record = Read-Owner; $record -and $record.schemaVersion -eq 5 -and $record.state -ceq "attached" } "attached holder owner"
  Wait-Condition { Test-Path -LiteralPath $forcedMarker -PathType Leaf } "guarded body start before forced holder death"
  $forcedRecord = Read-Owner
  $holderIdentity = [pscustomobject]@{ pid = $forcedRecord.pid; processStartUtc = $forcedRecord.processStartUtc }
  Stop-ExactProcess $holderIdentity
  $forcedRaw = Get-Content -LiteralPath $ownerPath -Raw
  $forcedLoserMarker = Join-Path $root "forced-loser.marker"
  $forcedLoser = Start-NodeFixture $vitestScript @("run") $laneB "lane-b" $forcedLoserMarker
  Complete-Fixture $forcedLoser 73 "contender behind dead holder/live guarded process" | Out-Null
  Assert-True ((Get-Content -LiteralPath $ownerPath -Raw) -ceq $forcedRaw -and
    -not (Test-Path -LiteralPath $forcedLoserMarker)) "dead holder record is byte-exact while guarded process lives"
  Set-Content -LiteralPath $forcedRelease -Value "release"
  Complete-Fixture $forcedOwner 0 "guarded process after holder death" | Out-Null
  $recoveryMarker = Join-Path $root "forced-recovery.marker"
  $recovery = Start-NodeFixture $pnpmScript @("run", "build") $laneB "lane-b" $recoveryMarker
  Complete-Fixture $recovery 0 "exact schema-v4 stale recovery" | Out-Null
  Wait-Condition { -not (Test-Path -LiteralPath $lock) } "schema-v4 recovery release"
  Assert-True (Test-Path -LiteralPath $recoveryMarker) "schema-v4 stale owner recovers only after guarded death"

  # A detached live descendant remains protected after its direct heavy parent
  # exits. The holder releases only when the exact descendant drains.
  $descendantIdentityPath = Join-Path $root "descendant.pid"
  $descendantMarker = Join-Path $root "descendant-parent.marker"
  $descendantRelease = Join-Path $root "descendant.release"
  Copy-Item -LiteralPath $descendantScript -Destination $pnpmScript -Force
  $descendantOwner = Start-NodeFixture $pnpmScript @("run", "verify:static") $laneA "lane-a" $descendantMarker 0 @{
    DESCENDANT_WORKER = $descendantWorker
    DESCENDANT_IDENTITY = $descendantIdentityPath
    DESCENDANT_RELEASE_FILE = $descendantRelease
  }
  Complete-Fixture $descendantOwner 0 "heavy parent with detached descendant" | Out-Null
  Wait-Condition { (Test-Path -LiteralPath $descendantIdentityPath) -and (Test-Path -LiteralPath $lock) } "live detached descendant lock preservation"
  $descendantPid = [int](Get-Content -LiteralPath $descendantIdentityPath -Raw)
  Assert-True (@(Get-Process -Id $descendantPid -ErrorAction SilentlyContinue).Count -eq 1) "detached descendant is live after parent exit"
  $descendantLoserMarker = Join-Path $root "descendant-loser.marker"
  $descendantLoser = Start-NodeFixture $vitestScript @("run") $laneB "lane-b" $descendantLoserMarker
  Complete-Fixture $descendantLoser 73 "contender behind live detached descendant" | Out-Null
  Assert-True (-not (Test-Path -LiteralPath $descendantLoserMarker)) "live descendant prevents contender body"
  Set-Content -LiteralPath $descendantRelease -Value "release"
  Wait-Condition { -not (Test-Path -LiteralPath $lock) } "descendant drain and holder release"

  Write-Output "PASS heavy lane admission classifier and inert discriminators"
  if ($derivedFailure) { throw $derivedFailure }
} finally {
  if (-not [string]::IsNullOrEmpty($descendantRelease) -and (Test-Path -LiteralPath $root)) {
    [IO.File]::WriteAllText($descendantRelease, "release", [Text.UTF8Encoding]::new($false))
  }
  foreach ($entry in $startedProcesses) {
    try {
      if (Test-ExactProcess $entry.Identity) {
        $entry.Process.Kill($true)
        [void]$entry.Process.WaitForExit(5000)
      }
      $entry.Process.Dispose()
    } catch {
      # Cleanup stays bounded to exact fixture identities created above.
    }
  }
  if (Test-Path -LiteralPath $ownerPath -PathType Leaf) {
    try {
      $remainingOwner = Read-Owner
      if ($remainingOwner -and
          [IO.Path]::GetFullPath($container).StartsWith([IO.Path]::GetFullPath($root), [StringComparison]::OrdinalIgnoreCase)) {
        $remainingIdentity = [pscustomobject]@{
          pid = $remainingOwner.pid
          processStartUtc = $remainingOwner.processStartUtc
        }
        if (Test-ExactProcess $remainingIdentity) { Stop-ExactProcess $remainingIdentity }
      }
    } catch {
      # Never broaden cleanup beyond the exact temp-root owner identity.
    }
  }
  if (Test-Path -LiteralPath $root) {
    Assert-DisposableRoot
    Wait-Condition {
      @(
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
          Where-Object { [string]$_.CommandLine -like "*$root*" }
      ).Count -eq 0
    } "all exact temp-root admission holders to exit" 400
    $admissionTempRoots = @(
      Get-ChildItem -LiteralPath $privateTemp -Directory -Filter "chase-sets-heavy-admission-*" -ErrorAction SilentlyContinue
    )
    Assert-True ($admissionTempRoots.Count -eq 0) `
      "test leaves zero chase-sets-heavy-admission roots in its private temp directory"
    Remove-Item -LiteralPath $root -Recurse -Force
  }
}
} finally { Exit-RoutingDataTestScope $routingTestScope }
