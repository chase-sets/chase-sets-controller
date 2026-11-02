param([switch]$IdentityOnly)

$ErrorActionPreference = "Stop"

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
      "CHASE_SETS_HEAVY_SLOT_ID"
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
  [hashtable]$AdmissionIdentity = @{}
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
  $start.Environment["CHASE_SETS_HEAVY_ADMISSION_CONFIG"] = New-AdmissionConfiguration $Worktree $Lane $AdmissionIdentity
  $start.Environment["CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_NODE_OPTIONS"] = ""
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

  # The preload must forward the dispatch-time HEAD rather than replacing it
  # with the same branch's newer live HEAD at admission.
  $staleHeadClaim = Invoke-RepoGit $laneA @("rev-parse", "HEAD")
  Invoke-RepoGit $laneA @("commit", "--allow-empty", "-m", "advance same branch before preload admission") | Out-Null
  $staleHeadMarker = Join-Path $root "stale-preload-head-negative-control.marker"
  $staleHeadPreload = Start-NodeFixture $pnpmScript @("run", "verify:static") $laneA "lane-a" $staleHeadMarker 0 @{} @{
    Branch = "codex/lane-a"
    ClaimedHead = $staleHeadClaim
  }
  $staleHeadOutput = Complete-Fixture $staleHeadPreload 73 "stale direct-command exact HEAD identity"
  Assert-True ($staleHeadOutput.stderr -match "exact launch-time HEAD does not match the live Git HEAD" -and
    $staleHeadOutput.stderr -match "command body was not executed" -and
    -not (Test-Path -LiteralPath $staleHeadMarker) -and
    -not (Test-Path -LiteralPath $lock)) "stale preload HEAD refuses before body and owner creation"

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

try {
  Assert-DisposableRoot
  Assert-FreshChildEnvironmentBoundary
  if ($IdentityOnly) { Test-AdmissionGitIdentity; return }

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
  [["node", "C:\\repo\\scripts\\run-e2e-suite.mjs"], "script-battery"],
  [["node", "C:\\tools\\pnpm.cjs", "run", "dev:e2e:probe"], "script-battery"],
  [["C:\\tools\\pnpm.exe", "run", "dev:e2e:probe"], "script-battery"],
  [["node.exe", "C:\\tools\\pnpm.exe", "run", "dev:e2e:probe"], "script-battery"],
  [["node", "C:\\tools\\pnpm.cjs", "run", "dev:e2e:probe:nested"], "script-battery"],
  [["node", "C:\\tools\\pnpm.cjs", "run", "test:e2e:direct-suite"], "script-battery"],
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
const results = cases.map(([argv, expected]) => ({
  argv,
  expected,
  actual: admission.classifyCommand(argv, { packageScripts: fullScripts, cwd: process.cwd(), worktree: process.cwd() }),
}));
fs.writeFileSync(process.env.ADMISSION_CLASSIFIER_RESULT, JSON.stringify(results));
'@
  $classifierStart = [Diagnostics.ProcessStartInfo]::new()
  $classifierStart.FileName = $node
  $classifierStart.UseShellExecute = $false
  Set-CleanAdmissionEnvironment $classifierStart
  [void]$classifierStart.ArgumentList.Add($classifierScript)
  $classifierStart.Environment["NODE_OPTIONS"] = ""
  $classifierStart.Environment["CHASE_SETS_HEAVY_ADMISSION_CONFIG"] = ""
  $classifierStart.Environment["ADMISSION_PRELOAD"] = $preload
  $classifierStart.Environment["ADMISSION_CLASSIFIER_RESULT"] = $classifierResult
  $classifierProcess = [Diagnostics.Process]::Start($classifierStart)
  $classifierProcess.WaitForExit()
  Assert-True ($classifierProcess.ExitCode -eq 0) "command-shape classifier fixture executes"
  $classification = Get-Content -LiteralPath $classifierResult -Raw | ConvertFrom-Json
  foreach ($case in $classification) {
    Assert-True ([string]$case.actual -ceq [string]$case.expected) "shape '$($case.argv -join ' ')' classifies as '$($case.expected)' (actual '$($case.actual)')"
  }

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

  Test-AdmissionGitIdentity

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
