param([switch]$FilteredTestOnly, [switch]$BrowserOnly, [switch]$BrowserBaseline, [switch]$CensusOnly, [switch]$CurrentBindingOnly, [switch]$IdentityOnly, [switch]$LauncherNonReentryOnly, [switch]$Baseline, [switch]$CleanupDiscriminator, [switch]$NestedSmoke, [switch]$NestedOnly, [switch]$MeasurementsAndMutantsOnly, [switch]$MutantsOnly, [ValidateRange(0,11)][int]$MutantStartAt = 0)

$ErrorActionPreference = "Stop"
if ($MutantsOnly) { $MeasurementsAndMutantsOnly = $true }
if ($MeasurementsAndMutantsOnly) { $NestedOnly = $true }
if ($BrowserOnly -or $BrowserBaseline) { $NestedOnly = $true }
if ($FilteredTestOnly) { $NestedOnly = $true }

$controllerRoot = Split-Path -Parent $PSScriptRoot
$clientSource = Join-Path $PSScriptRoot "heavy-slot.cjs"
$guardSource = Join-Path $PSScriptRoot "invoke-heavy-verifier.ps1"
$launcherSource = Join-Path $PSScriptRoot "heavy-admission-holder-launcher.cjs"
$preloadSource = Join-Path $PSScriptRoot "heavy-admission-preload.cjs"
$nestedOwnerSource = Join-Path $PSScriptRoot "heavy-nested-owner.cs"
$nestedClientSource = Join-Path $PSScriptRoot "heavy-nested-client.cjs"
$dispatchOwnershipSource = Join-Path $PSScriptRoot "dispatch-ownership.ps1"
# heavy-slot.cjs as installed before #7941 (per-child PowerShell host probe).
$baselineClientBlob = "71deeaae2c999d377d3d2ffe9b933219d62a06ff"
$node = Get-Command node -CommandType Application -ErrorAction Stop |
  Select-Object -First 1 -ExpandProperty Source
$pnpmCommandShim = Get-Command pnpm -All -ErrorAction Stop |
  Where-Object { $_.Source -like "*\pnpm.CMD" } | Select-Object -First 1
$pnpmCommandText = Get-Content -LiteralPath $pnpmCommandShim.Source -Raw
if ($pnpmCommandText -notmatch '"%~dp0\\(?<relative>[^"]*\\pnpm\.exe)"') {
  throw "unable to resolve the active pnpm.CMD direct binary"
}
$nativePnpm = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $pnpmCommandShim.Source) $Matches.relative))
$pwsh = Get-Command pwsh -CommandType Application -ErrorAction Stop |
  Select-Object -First 1 -ExpandProperty Source
$systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd("\", "/")
$root = Join-Path $systemTemp ("heavy-slot-test-" + [guid]::NewGuid().ToString("N"))
$privateTemp = Join-Path $root "fixture-temp"
$container = Join-Path $root "container with spaces"
$orchestrator = Join-Path $container ".orchestrator"
$guard = Join-Path $orchestrator "invoke-heavy-verifier.ps1"
$client = Join-Path $orchestrator "heavy-slot.cjs"
$launcher = Join-Path $orchestrator "heavy-admission-holder-launcher.cjs"
$preload = Join-Path $orchestrator "heavy-admission-preload.cjs"
$nestedOwner = Join-Path $orchestrator "heavy-nested-owner.cs"
$nestedClient = Join-Path $orchestrator "heavy-nested-client.cjs"
$dispatchOwnership = Join-Path $orchestrator "dispatch-ownership.ps1"
$preloadForNode = $preload.Replace("\", "/")
$lock = Join-Path $orchestrator "verify-lock.d"
$ownerPath = Join-Path $lock "owner.json"
# The dispatch ownership reader rejects "lane-*" names that are not lane-NN,
# so the fixture lane carries a plain name.
$laneName = "nested-slot"
$secondLaneName = "nested-second"
$worktree = Join-Path $container $laneName
$secondWorktree = Join-Path $container $secondLaneName
$fixture = Join-Path $worktree "scripts\fixture.cjs"
$childFixture = Join-Path $worktree "scripts\child.cjs"
$passiveFixture = Join-Path $worktree "scripts\passive.cjs"
$rawClientFixture = Join-Path $worktree "scripts\raw-client.cjs"
$borrowParentFixture = Join-Path $worktree "scripts\borrow-parent.cjs"
$borrowChildFixture = Join-Path $worktree "scripts\borrow-child.cjs"
$startedProcesses = [Collections.Generic.List[object]]::new()
$fixtureStage = "setup"
$bodyFailure = $null
$cleanupFailure = $null
$fixtureHead = $null
$dispatchRecord = $null
$measurements = [Collections.Generic.List[string]]::new()

function Assert-True($Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}
function Assert-DisposableRoot {
  $resolved = [IO.Path]::GetFullPath($root).TrimEnd("\", "/")
  Assert-True ($resolved.StartsWith($systemTemp + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) "test root stays below system temp"
  Assert-True ((Split-Path -Leaf $resolved) -like "heavy-slot-test-*") "test root has the owned safety prefix"
}
function Invoke-FixtureGit([string[]]$Arguments, [string]$Repository = $worktree) {
  $output = @(& git -C $Repository @Arguments 2>&1)
  if ($LASTEXITCODE -ne 0) {
    throw "fixture git command failed: git $($Arguments -join ' ')`n$($output -join "`n")"
  }
  return ($output -join "`n").Trim()
}
function Wait-Condition([scriptblock]$Condition, [string]$Message, [int]$Attempts = 600) {
  for ($attempt = 0; $attempt -lt $Attempts; $attempt++) {
    if (& $Condition) { return }
    Start-Sleep -Milliseconds 25
  }
  throw "ASSERTION FAILED: timed out waiting for $Message"
}
function Assert-ConditionRemains([scriptblock]$Condition, [string]$Message, [int]$Attempts = 600) {
  for ($attempt = 0; $attempt -lt $Attempts; $attempt++) {
    Assert-True (& $Condition) $Message
    Start-Sleep -Milliseconds 25
  }
}
function Read-Owner {
  if (-not (Test-Path -LiteralPath $ownerPath -PathType Leaf)) { return $null }
  try { return Get-Content -LiteralPath $ownerPath -Raw | ConvertFrom-Json -DateKind String } catch { return $null }
}
function Read-OwnerRaw {
  return [Text.UTF8Encoding]::new($false).GetString([IO.File]::ReadAllBytes($ownerPath))
}
function Write-OwnerRaw([string]$Raw) {
  [IO.File]::WriteAllBytes($ownerPath, [Text.UTF8Encoding]::new($false).GetBytes($Raw))
}
function Get-ProcessIdentity([Diagnostics.Process]$Process) {
  return [pscustomobject]@{
    pid = $Process.Id
    processStartUtc = $Process.StartTime.ToUniversalTime().ToString("o")
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
function Write-FixtureDiagnostics([string]$Phase) {
  try {
    $ownerRaw = if (Test-Path -LiteralPath $ownerPath -PathType Leaf) {
      Get-Content -LiteralPath $ownerPath -Raw
    } else {
      $null
    }
    $admissionRoots = @(
      Get-ChildItem -LiteralPath $privateTemp -Directory -Filter "chase-sets-heavy-admission-*" -ErrorAction SilentlyContinue |
        ForEach-Object {
          $entries = @(Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue | ForEach-Object {
              [ordered]@{
                name = $_.Name
                kind = $(if ($_.PSIsContainer) { "directory" } else { "file" })
                length = $(if ($_.PSIsContainer) { $null } else { $_.Length })
                content = $(if (-not $_.PSIsContainer -and $_.Name -ceq "result.json") {
                    Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue
                  } else { $null })
              }
            })
          [ordered]@{ path = $_.FullName; entries = $entries }
        }
    )
    $ownedProcesses = @(
      Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { [string]$_.CommandLine -like "*$root*" } |
        ForEach-Object {
          [ordered]@{
            pid = [int]$_.ProcessId
            parentPid = [int]$_.ParentProcessId
            name = [string]$_.Name
            creationDate = $(if ($_.CreationDate -is [datetime]) { $_.CreationDate.ToUniversalTime().ToString("o") } else { [string]$_.CreationDate })
            commandLine = [string]$_.CommandLine
          }
        }
    )
    $started = @($startedProcesses | ForEach-Object {
        [ordered]@{
          pid = [int]$_.Identity.pid
          processStartUtc = [string]$_.Identity.processStartUtc
          exactLive = Test-ExactProcess $_.Identity
          guardedPid = $(if ($_.GuardedProcess) { $_.GuardedProcess.Id } else { $null })
        }
      })
    [Console]::Error.WriteLine("FIXTURE_DIAGNOSTIC " + ([ordered]@{
          phase = $Phase
          stage = $fixtureStage
          root = $root
          privateTemp = $privateTemp
          lockPresent = Test-Path -LiteralPath $lock -PathType Container
          ownerRaw = $ownerRaw
          admissionRoots = $admissionRoots
          startedProcesses = $started
          rootProcesses = $ownedProcesses
        } | ConvertTo-Json -Depth 8 -Compress))
  } catch {
    [Console]::Error.WriteLine("FIXTURE_DIAGNOSTIC_FAILED phase=$Phase stage=$fixtureStage error=$($_.Exception.Message)")
  }
}
function Get-DescendantProcessRecords([int]$RootPid) {
  $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
  $descendantIds = [Collections.Generic.HashSet[int]]::new()
  [void]$descendantIds.Add($RootPid)
  do {
    $added = $false
    foreach ($candidate in $all) {
      if ($descendantIds.Contains([int]$candidate.ParentProcessId) -and
          $descendantIds.Add([int]$candidate.ProcessId)) {
        $added = $true
      }
    }
  } while ($added)
  return @($all | Where-Object {
      $_.ProcessId -ne $RootPid -and $descendantIds.Contains([int]$_.ProcessId)
    })
}
$admissionEnvironmentNames = @(
  "NODE_OPTIONS",
  "CHASE_SETS_HEAVY_ADMISSION_CONFIG",
  "CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_NODE_OPTIONS",
  "CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_SCRIPT_SHELL",
  "CHASE_SETS_HEAVY_ADMISSION_PNPM_SCRIPT_SHELL",
  "CHASE_SETS_HEAVY_SLOT_ID",
  "CHASE_SETS_HEAVY_SLOT_TRANSPORT"
)
function Set-CleanAdmissionEnvironment([Diagnostics.ProcessStartInfo]$Start, [hashtable]$ExtraEnvironment) {
  foreach ($name in $admissionEnvironmentNames) {
    [void]$Start.Environment.Remove($name)
  }
  $Start.Environment["TEMP"] = $privateTemp
  $Start.Environment["TMP"] = $privateTemp
  foreach ($entry in $ExtraEnvironment.GetEnumerator()) {
    if ($null -eq $entry.Value) { [void]$Start.Environment.Remove($entry.Key) } else { $Start.Environment[$entry.Key] = [string]$entry.Value }
  }
}
function Assert-FreshChildEnvironmentBoundary {
  $names = @($admissionEnvironmentNames) + @("TEMP", "TMP")
  $parentBefore = [Environment]::GetEnvironmentVariables("Process")
  $probe = [Diagnostics.ProcessStartInfo]::new()
  foreach ($name in $admissionEnvironmentNames) { $probe.Environment[$name] = "synthetic-$name" }
  $probe.Environment["TEMP"] = "synthetic-TEMP"
  $probe.Environment["TMP"] = "synthetic-TMP"
  Set-CleanAdmissionEnvironment $probe @{}
  foreach ($name in $admissionEnvironmentNames) {
    Assert-True (-not $probe.Environment.ContainsKey($name)) "fresh child retained admission marker $name"
  }
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

# Exact source mutation: every production anchor must occur exactly once so a
# mutant changes one governing variable and nothing else.
function Set-SourceMutant([string]$Source, [string]$Target, [object[]]$Pairs, [string]$Name) {
  $text = [IO.File]::ReadAllText($Source, [Text.Encoding]::UTF8).Replace("`r`n", "`n")
  if ($Pairs.Count -eq 2 -and $Pairs[0] -is [string] -and $Pairs[1] -is [string]) { $Pairs = ,$Pairs }
  foreach ($pair in $Pairs) {
    Assert-True ($pair -is [array] -and $pair.Count -eq 2) "mutant $Name has a closed replacement pair"
    $production = ([string]$pair[0]).Replace("`r`n", "`n")
    $mutant = ([string]$pair[1]).Replace("`r`n", "`n")
    Assert-True (([regex]::Matches($text, [regex]::Escape($production))).Count -eq 1) `
      "mutant $Name found exactly one production anchor: $($production.Substring(0, [Math]::Min(60, $production.Length)))"
    $text = $text.Replace($production, $mutant)
  }
  [IO.File]::WriteAllText($Target, $text, [Text.UTF8Encoding]::new($false))
}
function Restore-FixtureSources {
  Copy-Item -LiteralPath $clientSource -Destination $client -Force
  Copy-Item -LiteralPath $guardSource -Destination $guard -Force
  Copy-Item -LiteralPath $nestedOwnerSource -Destination $nestedOwner -Force
  Copy-Item -LiteralPath $nestedClientSource -Destination $nestedClient -Force
}
function Set-HolderSpawnMutant([bool]$Detached) {
  $source = [IO.File]::ReadAllText($clientSource, [Text.Encoding]::UTF8).Replace("`r`n", "`n")
  $productionSpawn = @'
    child = childProcess.spawn(
      launcherExecutablePath,
      [holderLauncherPath, admission.powershellPath, ...holderArguments],
      { detached: true, stdio: "ignore", windowsHide: true, env: launcherEnvironment },
    );
'@.Replace("`r`n", "`n")
  $mutantSpawn = @"
    child = childProcess.spawn(
      admission.powershellPath,
      holderArguments,
      { detached: $($Detached.ToString().ToLowerInvariant()), stdio: "ignore", windowsHide: true },
    );
"@.Replace("`r`n", "`n")
  Assert-True (([regex]::Matches($source, [regex]::Escape($productionSpawn))).Count -eq 1) `
    "named holder mutant found exactly one production launcher spawn"
  [IO.File]::WriteAllText($client, $source.Replace($productionSpawn, $mutantSpawn), [Text.UTF8Encoding]::new($false))
}
function Set-RefusedCleanupMutant {
  $source = [IO.File]::ReadAllText($guardSource, [Text.Encoding]::UTF8).Replace("`r`n", "`n")
  $productionCall = "        Complete-RefusedAttachedAdmission"
  Assert-True (([regex]::Matches($source, [regex]::Escape($productionCall))).Count -eq 1) `
    "refused-cleanup mutant found exactly one production call"
  [IO.File]::WriteAllText(
    $guard,
    $source.Replace($productionCall, "        [void]`$null # MUTANT_REMOVED_REFUSED_ADMISSION_CLEANUP"),
    [Text.UTF8Encoding]::new($false)
  )
}

# Windows job-object accounting: exact count of every process that ever ran
# below a root, plus their aggregate CPU. Used only to measure fixtures.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace HeavySlotTest {
  public static class JobAccounting {
    [StructLayout(LayoutKind.Sequential)]
    public struct BasicAccounting {
      public long TotalUserTime; public long TotalKernelTime; public long ThisPeriodTotalUserTime; public long ThisPeriodTotalKernelTime;
      public uint TotalPageFaultCount; public uint TotalProcesses; public uint ActiveProcesses; public uint TotalTerminatedProcesses;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr CreateJobObjectW(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool QueryInformationJobObject(IntPtr job, int informationClass, out BasicAccounting information, int length, IntPtr returnLength);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr handle);
    public static IntPtr Create() { IntPtr job = CreateJobObjectW(IntPtr.Zero, null); if (job == IntPtr.Zero) throw new Exception("CreateJobObjectW failed " + Marshal.GetLastWin32Error()); return job; }
    public static void Assign(IntPtr job, IntPtr process) { if (!AssignProcessToJobObject(job, process)) throw new Exception("AssignProcessToJobObject failed " + Marshal.GetLastWin32Error()); }
    public static BasicAccounting Query(IntPtr job) { BasicAccounting info; if (!QueryInformationJobObject(job, 1, out info, Marshal.SizeOf(typeof(BasicAccounting)), IntPtr.Zero)) throw new Exception("QueryInformationJobObject failed " + Marshal.GetLastWin32Error()); return info; }
    public static void Close(IntPtr job) { CloseHandle(job); }
  }
}
'@ -ReferencedAssemblies @("System.Runtime.InteropServices")

function Start-Fixture(
  [string]$Script = $fixture,
  [hashtable]$ExtraEnvironment = @{},
  [string[]]$PrefixArguments = @(),
  [string[]]$Arguments = @(),
  [string]$WorkingDirectory = $worktree,
  [IntPtr]$Job = [IntPtr]::Zero
) {
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = $node
  $start.WorkingDirectory = $WorkingDirectory
  $start.UseShellExecute = $false
  $start.CreateNoWindow = $true
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  foreach ($argument in $PrefixArguments) { [void]$start.ArgumentList.Add($argument) }
  [void]$start.ArgumentList.Add($Script)
  foreach ($argument in $Arguments) { [void]$start.ArgumentList.Add($argument) }
  Set-CleanAdmissionEnvironment $start $ExtraEnvironment
  $process = [Diagnostics.Process]::Start($start)
  if ($Job -ne [IntPtr]::Zero) { [HeavySlotTest.JobAccounting]::Assign($Job, $process.Handle) }
  $entry = [pscustomobject]@{ Process = $process; Identity = Get-ProcessIdentity $process }
  $startedProcesses.Add($entry)
  return $entry
}
function Start-CmdFixture([string]$Command, [hashtable]$ExtraEnvironment = @{}, [switch]$Inspector) {
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = $env:ComSpec
  $start.WorkingDirectory = $worktree
  $start.UseShellExecute = $false
  $start.CreateNoWindow = $true
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  $start.RedirectStandardInput = $Inspector
  [void]$start.ArgumentList.Add("/d")
  [void]$start.ArgumentList.Add("/v:on")
  [void]$start.ArgumentList.Add("/c")
  [void]$start.ArgumentList.Add($Command)
  Set-CleanAdmissionEnvironment $start $ExtraEnvironment
  $process = [Diagnostics.Process]::Start($start)
  $guardedProcess = $null
  $entry = [pscustomobject]@{
    Process = $process; Identity = Get-ProcessIdentity $process
    GuardedProcess = $null; InspectorPrefix = ""
  }
  $startedProcesses.Add($entry)
  if ($Inspector) {
    Wait-Condition {
      @(
        Get-DescendantProcessRecords $process.Id |
          Where-Object { [string]$_.Name -like "node*" }
      ).Count -ge 2
    } "inspector parent and guarded fixture"
    $nodeProcesses = @(
      Get-DescendantProcessRecords $process.Id |
        Where-Object { [string]$_.Name -like "node*" }
    )
    $nodeIds = [Collections.Generic.HashSet[int]]::new()
    foreach ($candidate in $nodeProcesses) { [void]$nodeIds.Add([int]$candidate.ProcessId) }
    $guarded = $nodeProcesses |
      Where-Object { $nodeIds.Contains([int]$_.ParentProcessId) } |
      Select-Object -First 1
    Assert-True ($null -ne $guarded) "inspector exposes the exact guarded fixture child"
    $guardedProcess = [Diagnostics.Process]::GetProcessById([int]$guarded.ProcessId)
    $entry.GuardedProcess = $guardedProcess
    $inspectorWatch = [Diagnostics.Stopwatch]::StartNew()
    $prefix = [Text.StringBuilder]::new()
    $character = [char[]]::new(1)
    while ($prefix.ToString() -notmatch '(?i)break (on start|in)') {
      $remaining = 5000 - [int]$inspectorWatch.ElapsedMilliseconds
      Assert-True ($remaining -gt 0) "inspector reached its actual initial breakpoint within the existing 5000ms bound: $prefix"
      $read = $process.StandardOutput.ReadAsync($character, 0, 1)
      Assert-True ($read.Wait($remaining) -and $read.Result -eq 1) "inspector published its initial breakpoint: $prefix"
      [void]$prefix.Append($character[0])
    }
    $entry.InspectorPrefix = $prefix.ToString()
    $process.StandardInput.WriteLine("cont")
    $process.StandardInput.Flush()
    while (-not (Test-Path -LiteralPath $ExtraEnvironment.SLOT_EXIT_MARKER) -and $inspectorWatch.ElapsedMilliseconds -lt 5000) {
      Start-Sleep -Milliseconds 25
    }
    $process.StandardInput.Close()
  }
  return $entry
}
function Start-RefusedAttachedFixture($GuardedIdentity, [string]$AdmissionRoot) {
  New-Item -ItemType Directory -Path $AdmissionRoot | Out-Null
  $resultPath = Join-Path $AdmissionRoot "result.json"
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = $pwsh
  $start.WorkingDirectory = $worktree
  $start.UseShellExecute = $false
  $start.CreateNoWindow = $true
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  foreach ($argument in @(
      "-NoProfile", "-NonInteractive", "-File", $guard,
      "-AdmissionKind", "script-battery",
      "-GuardedPid", [string]$GuardedIdentity.pid,
      "-GuardedProcessStartUtc", [string]$GuardedIdentity.processStartUtc,
      "-AdmissionNonce", [guid]::NewGuid().ToString("N"),
      "-AdmissionResultPath", $resultPath,
      "-AdmissionCommand", "synthetic-refused-body",
      "-Worktree", $worktree,
      "-Lane", $laneName,
      "-Branch", "codex/heavy-slot-fixture",
      "-ClaimedHead", (Invoke-FixtureGit @("rev-parse", "HEAD")),
      "-ContainerRoot", $container
    )) {
    [void]$start.ArgumentList.Add($argument)
  }
  Set-CleanAdmissionEnvironment $start @{}
  $process = [Diagnostics.Process]::Start($start)
  $entry = [pscustomobject]@{
    Process = $process
    Identity = Get-ProcessIdentity $process
    AdmissionRoot = $AdmissionRoot
    ResultPath = $resultPath
  }
  $startedProcesses.Add($entry)
  return $entry
}
function Start-GateWrapper([string]$Gate, [string]$Script, [hashtable]$ExtraEnvironment = @{}, [switch]$ImmutableHead) {
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = $pwsh
  $start.WorkingDirectory = $worktree
  $start.UseShellExecute = $false
  $start.CreateNoWindow = $true
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  foreach ($argument in @(
      "-NoProfile", "-NonInteractive", "-File", $guard,
      "-Gate", $Gate,
      "-Worktree", $worktree,
      "-Lane", $laneName,
      "-ContainerRoot", $container,
      "-CommandPath", $node,
      "-CommandArgumentList", $Script
    )) {
    [void]$start.ArgumentList.Add($argument)
  }
  $identityArguments = if ($ImmutableHead) { @("-ImmutableHead", (Invoke-FixtureGit @("rev-parse", "HEAD"))) } else {
    @("-Branch", "codex/heavy-slot-fixture", "-ClaimedHead", (Invoke-FixtureGit @("rev-parse", "HEAD")))
  }
  foreach ($argument in $identityArguments) { [void]$start.ArgumentList.Add($argument) }
  Set-CleanAdmissionEnvironment $start $ExtraEnvironment
  $process = [Diagnostics.Process]::Start($start)
  $entry = [pscustomobject]@{ Process = $process; Identity = Get-ProcessIdentity $process }
  $startedProcesses.Add($entry)
  return $entry
}
  function Invoke-EscapedHandleScenario {
    $gateHolder = Start-GateDriverHolder "test:scripts"
    $wrapperIdentity = [pscustomobject]@{ pid = $gateHolder.Owner.pid; processStartUtc = $gateHolder.Owner.processStartUtc }
    $livingChild = Invoke-NestedChild $gateHolder "escaped-before-kill"
    Assert-True ($livingChild.status -eq 0) "Gate root's child admits before wrapper death (stderr=$($livingChild.stderr))"
    Stop-Process -Id ([int]$wrapperIdentity.pid) -Force
    Wait-Condition { -not (Test-ExactProcess $wrapperIdentity) } "gate wrapper death"
    $connect = Invoke-Driver $gateHolder "escaped-connect" @{ script = "raw-client"; env = @{ RAW_MODE = "connect-only" } }
    $connectDetail = $connect.stdout | ConvertFrom-Json
    Set-Content -LiteralPath (Join-Path $gateHolder.Driver "stop") -Value "stop"
    Wait-Condition { -not (Test-ExactProcess ([pscustomobject]@{pid=$gateHolder.Owner.childPid; processStartUtc=$gateHolder.Owner.childProcessStartUtc})) } "gate root exit" 1200
    Complete-Fixture $gateHolder.Entry -1 "gate wrapper killed" | Out-Null
    $recoveryMarker = Join-Path $root ("escaped-recovery-" + [guid]::NewGuid().ToString("N") + ".marker")
    $recovery = Start-Fixture -ExtraEnvironment @{ SLOT_MARKER = $recoveryMarker }
    Complete-Fixture $recovery 0 "stale recovery after gate wrapper death" | Out-Null
    Wait-Condition { -not (Test-Path -LiteralPath $lock) } "escaped-handle stale recovery release" 1200
    return $connectDetail
  }
function Complete-Fixture($Entry, [int]$ExpectedExit, [string]$Message, [int]$TimeoutMilliseconds = 30000) {
  Assert-True ($Entry.Process.WaitForExit($TimeoutMilliseconds)) "$Message exits within the bound"
  $stderr = $Entry.Process.StandardError.ReadToEnd()
  $stdout = $Entry.Process.StandardOutput.ReadToEnd()
  if ($Entry.PSObject.Properties.Name -contains "InspectorPrefix") { $stdout = $Entry.InspectorPrefix + $stdout }
  Assert-True ($Entry.Process.ExitCode -eq $ExpectedExit) "$Message exit code is $ExpectedExit (actual $($Entry.Process.ExitCode); stderr=$stderr; stdout=$stdout)"
  return [pscustomobject]@{ stderr = $stderr; stdout = $stdout }
}

# Dispatch ownership-v4 fixture: this test process is the dispatch child and
# its live parent is the launcher, so every fixture started below is inside
# the recorded actual child tree. Identities are real; only the record is
# written by the test.
function Get-LiveParentIdentity {
  $parentPid = [int](Get-CimInstance Win32_Process -Filter "ProcessId = $PID" -ErrorAction Stop).ParentProcessId
  $parent = Get-Process -Id $parentPid -ErrorAction Stop
  return [pscustomobject]@{ pid = $parentPid; processStartUtc = $parent.StartTime.ToUniversalTime().ToString("o") }
}
function Write-DispatchOwnership(
  [string]$LaneRole = "implementation",
  [int]$Row = 7,
  [switch]$ImmutableHead,
  [string]$RecordWorktree = $worktree,
  [string]$RecordLane = $laneName,
  [string]$Branch = "codex/heavy-slot-fixture",
  [string]$Head = $fixtureHead,
  [string]$Label = "goal-heavy-slot-fixture",
  [int]$ChildPid = $PID,
  [string]$ChildStartUtc = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString("o"),
  $LauncherIdentity = (Get-LiveParentIdentity)
) {
  $launcher = $LauncherIdentity
  $launchId = [guid]::NewGuid().ToString()
  $recordPath = Join-Path $orchestrator "dispatch-launch-$launchId.json"
  $promptPath = Join-Path $orchestrator "dispatch-heavy-verifier-$launchId.prompt.txt"
  $transcriptPath = Join-Path $orchestrator "$Label.jsonl"
  $isolationRoot = if ($LaneRole -ceq "implementation") { $null } else { Join-Path $privateTemp "chase-sets-$LaneRole-$launchId" }
  $record = [ordered]@{
    schemaVersion = 4
    launchId = $launchId
    laneRole = $LaneRole
    promptPath = $promptPath
    reviewIsolationRoot = $isolationRoot
    launcherPid = [int]$launcher.pid
    launcherStartIdentity = [string]$launcher.processStartUtc
    recordedAt = [DateTimeOffset]::Parse($ChildStartUtc).UtcDateTime.AddTicks(-2).ToString("o")
    state = "started"
    childPid = $ChildPid
    childStartIdentity = $ChildStartUtc
    worktree = $RecordWorktree
    lane = $RecordLane
    identityMode = $(if ($ImmutableHead) { "immutable-head" } else { "branch" })
    branch = $(if ($ImmutableHead) { $null } else { $Branch })
    head = $Head
    label = $Label
    transcriptPath = $transcriptPath
  }
  $raw = $record | ConvertTo-Json -Compress -Depth 4
  [IO.File]::WriteAllText($recordPath, $raw, [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText($promptPath, "fixture prompt", [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText($transcriptPath, "{`"type`":`"item.completed`"}`n", [Text.UTF8Encoding]::new($false))
  $routingRaw = [ordered]@{
    ts=[DateTimeOffset]::Parse($ChildStartUtc).UtcDateTime.AddTicks(-1).ToString('o'); kind='dispatch'; dispatchRoutingSchema='watchdog-dispatch-routing/v1'
    attemptId=$Label; label=$Label; lane=$RecordLane; laneRole='implementation'; transcript="$Label.jsonl"
    harness='codex'; model='gpt-6-astra'; effort='high'; row=[string]$Row; placement='override-Todd'
    worktree=$RecordWorktree; branch=$record.branch; head=$Head
  } | ConvertTo-Json -Compress
  [IO.File]::AppendAllText((Join-Path $orchestrator 'dispatch-log.jsonl'), $routingRaw + "`n")
  return [pscustomobject]@{ Path = $recordPath; PromptPath = $promptPath; TranscriptPath = $transcriptPath; LaunchId = $launchId; Raw = $raw; Record = $record; RoutingRaw = $routingRaw }
}
function Remove-DispatchOwnership($Ownership) {
  $history = Join-Path $orchestrator 'dispatch-log.jsonl'
  if (Test-Path $history) {
    $remaining = @([IO.File]::ReadAllLines($history) | Where-Object { $_ -cne $Ownership.RoutingRaw })
    [IO.File]::WriteAllLines($history, $remaining)
  }
  foreach ($path in @($Ownership.Path, $Ownership.PromptPath, $Ownership.TranscriptPath)) {
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
  }
}
function Test-DeniedRoleClients {
  foreach ($case in @(@{Role='review';Row=12},@{Role='planning';Row=8},@{Role='implementation';Row=13})) {
    $ownership=Write-DispatchOwnership -LaneRole $case.Role -Row $case.Row -Label "denied-$($case.Role)"
    foreach ($kind in $allKinds) {
      $marker=Join-Path $root "denied-$($case.Role)-$kind.marker"
      $entry=Start-Fixture -ExtraEnvironment @{SLOT_ROOT_KIND=$kind;SLOT_MARKER=$marker}
      $output=Complete-Fixture $entry 73 "denied $($case.Role)/$kind"
      Assert-True ($output.stderr -match 'caller eligibility:' -and -not (Test-Path $marker) -and -not (Test-Path $lock)) "direct client has no denied body/reservation: $($output.stderr)"
      Assert-True ([IO.File]::ReadAllText($ownership.Path) -ceq $ownership.Raw) 'direct denial leaves native dispatch unchanged'
      Write-Output "PASS denied direct $($case.Role)/row-$($case.Row)/$kind exit=73 marker=0 owner=0"
    }
    $entry=Start-Fixture -ExtraEnvironment @{CHASE_SETS_HEAVY_SLOT_ID=('f'*32)}
    Complete-Fixture $entry 73 'denied copied token' | Out-Null
    Assert-True (-not (Test-Path $lock)) 'copied token creates no reservation'
    Remove-DispatchOwnership $ownership
  }
}

# Driver holder: a real guarded root that acquires the slot and then runs the
# nested commands this test hands it, so every nested client is an actual live
# descendant of the exact guarded root.
function New-DriverDirectory {
  $driver = Join-Path $root ("driver-" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $driver | Out-Null
  return $driver
}
function Wait-DriverReady([string]$Driver, $Entry, [string]$Message) {
  $readyPath = Join-Path $Driver "ready.json"
  Wait-Condition {
    if ($Entry.Process.HasExited) {
      throw "ASSERTION FAILED: $Message exited $($Entry.Process.ExitCode) before ready: stderr=$($Entry.Process.StandardError.ReadToEnd()) stdout=$($Entry.Process.StandardOutput.ReadToEnd())"
    }
    Test-Path -LiteralPath $readyPath -PathType Leaf
  } "$Message ready" 1200
  return Get-Content -LiteralPath $readyPath -Raw | ConvertFrom-Json
}
function Start-DriverHolder([hashtable]$ExtraEnvironment = @{}, [IntPtr]$Job = [IntPtr]::Zero) {
  $driver = New-DriverDirectory
  $environment = @{ SLOT_DRIVER = $driver }
  foreach ($entry in $ExtraEnvironment.GetEnumerator()) { $environment[$entry.Key] = $entry.Value }
  $entry = Start-Fixture -ExtraEnvironment $environment -Job $Job
  $ready = Wait-DriverReady $driver $entry "driver holder"
  Wait-Condition { $record = Read-Owner; $record -and $record.lockId -ceq $ready.token } "driver holder owner"
  return [pscustomobject]@{ Entry = $entry; Driver = $driver; Ready = $ready; Owner = Read-Owner; OwnerRaw = Read-OwnerRaw }
}
function Start-GateDriverHolder([string]$Gate, [hashtable]$ExtraEnvironment = @{}, [switch]$ImmutableHead) {
  $driver = New-DriverDirectory
  $environment = @{ SLOT_DRIVER = $driver }
  foreach ($entry in $ExtraEnvironment.GetEnumerator()) { $environment[$entry.Key] = $entry.Value }
  $entry = Start-GateWrapper $Gate $fixture $environment -ImmutableHead:$ImmutableHead
  $ready = Wait-DriverReady $driver $entry "gate driver holder"
  Wait-Condition { $record = Read-Owner; $record -and $record.lockId -ceq $ready.token -and $record.state -ceq "started" } "gate driver holder owner"
  $guardedOwner = Read-Owner
  $guarded = [Diagnostics.Process]::GetProcessById([int]$guardedOwner.childPid)
  $startedProcesses.Add([pscustomobject]@{ Process = $guarded; Identity = [pscustomobject]@{ pid = $guardedOwner.childPid; processStartUtc = $guardedOwner.childProcessStartUtc } })
  return [pscustomobject]@{ Entry = $entry; Driver = $driver; Ready = $ready; Owner = Read-Owner; OwnerRaw = Read-OwnerRaw }
}
function Invoke-Driver($Holder, [string]$Id, [hashtable]$Spec, [int]$TimeoutAttempts = 2400) {
  $spec = @{ id = $Id } + $Spec
  $fileId = [Uri]::EscapeDataString($Id)
  $commandPath = Join-Path $Holder.Driver "$fileId.cmd.json"
  $temporaryPath = Join-Path $Holder.Driver "$fileId.cmd.tmp"
  [IO.File]::WriteAllText($temporaryPath, ($spec | ConvertTo-Json -Compress -Depth 6), [Text.UTF8Encoding]::new($false))
  [IO.File]::Move($temporaryPath, $commandPath)
  $resultPath = Join-Path $Holder.Driver "$fileId.result.json"
  Wait-Condition {
    if (-not (Test-ExactProcess ([pscustomobject]@{pid=$Holder.Owner.childPid; processStartUtc=$Holder.Owner.childProcessStartUtc}))) {
      throw "ASSERTION FAILED: guarded driver root $($Holder.Owner.childPid) exited during $Id"
    }
    Test-Path -LiteralPath $resultPath -PathType Leaf
  } "driver result $Id" $TimeoutAttempts
  return Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
}
function Invoke-NestedChild($Holder, [string]$Id, [hashtable]$Environment = @{}, [switch]$Deeper) {
  $childEnvironment = @{}
  foreach ($entry in $Environment.GetEnumerator()) { $childEnvironment[$entry.Key] = $entry.Value }
  if (-not $childEnvironment.ContainsKey("SLOT_MARKER")) {
    $childEnvironment.SLOT_MARKER = Join-Path $Holder.Driver ([guid]::NewGuid().ToString("N") + ".body")
  }
  if ($Deeper) { $childEnvironment["SLOT_DEEPER"] = "1" }
  $result = Invoke-Driver $Holder $Id @{ script = "child"; env = $childEnvironment }
  [Console]::WriteLine("NESTED_PROBE id=$Id rootPid=$($Holder.Owner.childPid) wrapperPid=$($Holder.Owner.pid) clientPid=$($result.pid) exit=$($result.status) ms=$($result.ms) bodyCounter=$(if ($result.stdout -match '"bodyCounter":1') { 1 } else { 0 })")
  if ($result.status -eq 73) {
    Assert-True (-not (Test-Path -LiteralPath $childEnvironment.SLOT_MARKER) -and
      $result.stdout -notmatch '"bodyCounter":1') "refused nested child $Id never executes its body"
    [Console]::WriteLine("NESTED_REFUSAL id=$Id marker=absent stderr=$($result.stderr.Trim())")
  }
  return $result
}
function Invoke-RawRequest($Holder, [string]$Id, [hashtable]$Request, [hashtable]$Environment = @{}) {
  $childEnvironment = @{ RAW_REQUEST = ($Request | ConvertTo-Json -Compress -Depth 4) }
  foreach ($entry in $Environment.GetEnumerator()) { $childEnvironment[$entry.Key] = $entry.Value }
  $result = Invoke-Driver $Holder $Id @{ script = "raw-client"; env = $childEnvironment }
  Assert-True ($result.status -eq 0) "raw client $Id ran (stderr=$($result.stderr))"
  return $result.stdout | ConvertFrom-Json
}
function Invoke-FilteredTestControls {
  function Invoke-FilteredChild($Holder, [string]$Name, [string]$Extension, [string[]]$Arguments, [int]$ExpectedExit) {
    $marker = Join-Path $Holder.Driver "$Name.body"
    $deepMarker = Join-Path $Holder.Driver "$Name.deep.body"
    $result = Invoke-Driver $Holder $Name @{ file="filtered/pnpm.$Extension"; args=$Arguments; env=@{
      SLOT_MARKER=$marker; SLOT_DEEPER="1"; SLOT_DEEPER_KIND="vitest-full"; SLOT_DEEPER_MARKER=$deepMarker
    } }
    Assert-True ($result.status -eq $ExpectedExit) "$Name exit=$ExpectedExit actual=$($result.status) stderr=$($result.stderr)"
    if ($ExpectedExit -eq 0) {
      $body = $result.stdout | ConvertFrom-Json -DateKind String
      $deepBody = $body.deeper.stdout | ConvertFrom-Json -DateKind String
      Assert-True ($body.bodyCounter -eq 1 -and $deepBody.bodyCounter -eq 1 -and $body.deeper.status -eq 0) "$Name child and deeper body execute once"
      foreach ($bodyMarker in @($marker, $deepMarker)) {
        Assert-True ((Get-Content -LiteralPath $bodyMarker -Raw) -ceq $Holder.Owner.lockId) "$Name bodies retain exact owner token"
      }
    } else {
      Assert-True (-not (Test-Path -LiteralPath $marker) -and -not (Test-Path -LiteralPath $deepMarker) -and
        $result.stdout -notmatch '"bodyCounter":1' -and
        $result.stderr -match 'kind repository-gate is not admitted under gate script-battery') "$Name refuses at the unchanged kind boundary before either body"
    }
    Assert-True ((Read-OwnerRaw) -ceq $Holder.OwnerRaw) "$Name retains unchanged exact owner"
    Write-Output "FILTERED_CHAIN name=$Name root=$($Holder.Owner.childPid) wrapper=$($Holder.Owner.pid) child=$($result.pid) exit=$($result.status) childBody=$(if ($ExpectedExit -eq 0) { 1 } else { 0 }) deepBody=$(if ($ExpectedExit -eq 0) { 1 } else { 0 }) owner=$($Holder.Owner.lockId)"
    Write-Output "FILTERED_OUTPUT name=$Name stdout=$($result.stdout) stderr=$($result.stderr)"
  }

  $arguments = @("--filter", "@chase-sets/bounded-context-runtime", "run", "test", "inline-apply.db.test.ts", "--reporter=verbose")
  $environment = @{ SLOT_LAUNCHER_NODE_OPTIONS="--require=`"$preloadForNode`"" }
  $holder = Start-DriverHolder $environment
  Assert-True ($holder.Owner.gate -ceq "script-battery" -and $holder.Ready.transport) "synthetic real owner has signed per-call transport"
  foreach ($extension in @("cjs", "js", "mjs")) {
    Invoke-FilteredChild $holder "candidate-$extension" $extension $arguments 0
  }
  $nativeOptions = "--require=`"$preloadForNode`" --require=`"$($nativeCapture.Replace('\', '/'))`""
  function Invoke-NativeFiltered([string]$Name, [string[]]$Arguments, [int]$ExpectedExit) {
    $result = Invoke-Driver $holder $Name @{ executable=$nativePnpm; args=$Arguments; env=@{
      NODE_OPTIONS=$nativeOptions; SLOT_NATIVE_PRELOAD=$preload
    } }
    Assert-True ($result.status -eq $ExpectedExit) "$Name exit=$ExpectedExit actual=$($result.status) stderr=$($result.stderr)"
    if ($ExpectedExit -eq 0) {
      $body = $result.stdout | ConvertFrom-Json -DateKind String
      Assert-True ($body.bodyCounter -eq 1 -and $body.kind -ceq "script-battery" -and
        [IO.Path]::GetFullPath($body.argv[0]) -ceq [IO.Path]::GetFullPath($body.argv[1]) -and
        $body.token -ceq $holder.Owner.lockId) "$Name real SEA argv, admission and owner token"
    } else {
      Assert-True ($result.stdout -notmatch '"bodyCounter":1' -and
        $result.stderr -match 'kind repository-gate is not admitted under gate script-battery') "$Name refused before capture/body"
    }
    Assert-True ((Read-OwnerRaw) -ceq $holder.OwnerRaw) "$Name retains exact owner"
    Write-Output "FILTERED_NATIVE name=$Name exit=$($result.status) capture=$(if ($ExpectedExit -eq 0) { 1 } else { 0 }) stdout=$($result.stdout) stderr=$($result.stderr)"
  }
  Invoke-NativeFiltered "candidate-native-pnpm" $arguments 0
  Invoke-NativeFiltered "generic-native-negative" @("run", "test") 73
  Set-SourceMutant $preloadSource $preload @(@(
    'if (packagedPnpm && isFilteredWorkspaceTest(packagedArguments)) return "script-battery";',
    '/* MUTANT omitted SEA duplicate eligibility */'
  )) "omit-native-duplicate"
  try {
    Invoke-NativeFiltered "omitted-native-duplicate" $arguments 73
    Write-Output "MUTANT omit-native-duplicate killed: real pnpm.exe exit73 capture0"
  } finally {
    Copy-Item -LiteralPath $preloadSource -Destination $preload -Force
  }
  Invoke-FilteredChild $holder "generic-repository-negative" "cjs" @("run", "test") 73
  Set-SourceMutant $preloadSource $preload @(@(
    'if (allowFilteredTest && isFilteredWorkspaceTest(argumentsList)) return "script-battery";',
    '/* MUTANT omitted exact filtered workspace test classification */'
  )) "omit-filtered-workspace-test"
  try {
    Invoke-FilteredChild $holder "omitted-classification" "cjs" $arguments 73
    Write-Output "MUTANT omit-filtered-workspace-test killed: incident-shaped exit73 body0"
  } finally {
    Copy-Item -LiteralPath $preloadSource -Destination $preload -Force
  }
  Stop-DriverHolder $holder | Out-Null

  Set-SourceMutant $guardSource $guard @(@(
    '"script-battery" = @("script-battery", "vitest-full")',
    '"script-battery" = @("script-battery", "vitest-full", "repository-gate")'
  )) "widen-filtered-test-closure"
  try {
    $weakened = Start-DriverHolder $environment
    Invoke-FilteredChild $weakened "closure-bypass" "cjs" @("run", "test") 0
    Stop-DriverHolder $weakened | Out-Null
    Write-Output "MUTANT widen-filtered-test-closure killed: frozen generic negative executes body1"
  } finally {
    Copy-Item -LiteralPath $guardSource -Destination $guard -Force
  }
  Write-Output "PASS filtered workspace test: real signed owner/child/deeper and native pnpm.exe SEA, generic refusal, omission and closure-bypass mutants, exact release"
}
function Invoke-BrowserAdmissionControls {
  $forms = @(
    @{ Name = "registered-suite"; Script = "pnpm.cjs"; Args = @("run", "test:e2e:suite", "tcgplayer_connector_extension") },
    @{ Name = "direct-suite"; Script = "run-e2e-suite.mjs"; Args = @("tcgplayer_connector_extension") },
    @{ Name = "nested-alias"; Script = "pnpm.cjs"; Args = @("run", "suite:alias") },
    @{ Name = "registered-e2e"; Script = "pnpm.cjs"; Args = @("run", "test:e2e") },
    @{ Name = "registered-deployed"; Script = "pnpm.cjs"; Args = @("run", "test:e2e:deployed") },
    @{ Name = "registered-headed"; Script = "pnpm.cjs"; Args = @("run-script", "test:e2e:headed") },
    @{ Name = "native-pnpm-lifecycle"; Command = "pnpm run test:e2e:suite tcgplayer_connector_extension" }
  )
  if ($BrowserBaseline) { $forms = @($forms[0]) }
  foreach ($form in $forms) {
    $driver = New-DriverDirectory
    $environment = @{
      SLOT_DRIVER = $driver; NODE_OPTIONS = "--require=`"$preloadForNode`""
    }
    if ($form.Command) {
      $configuration = @{
        schemaVersion=1; guardPath=$guard; powershellPath=$pwsh; containerRoot=$container
        worktree=$worktree; lane=$laneName; branch="codex/heavy-slot-fixture"; head=$fixtureHead
        originalNodeOptionsPresent=$false; originalNodeOptions=""
        originalScriptShellPresent=$false; originalScriptShell=""
      }
      $environment.CHASE_SETS_HEAVY_ADMISSION_CONFIG = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($configuration | ConvertTo-Json -Compress)))
      $environment.npm_config_script_shell = $node
      $environment.CHASE_SETS_HEAVY_ADMISSION_PNPM_SCRIPT_SHELL = "node-check-proxy"
      $entry = Start-CmdFixture $form.Command $environment
    } else {
      $entry = Start-Fixture -Script (Join-Path $worktree "scripts/$($form.Script)") -Arguments $form.Args -ExtraEnvironment $environment
    }
    $ready = Wait-DriverReady $driver $entry $form.Name
    $holder = [pscustomobject]@{ Entry=$entry; Driver=$driver; Ready=$ready; Owner=Read-Owner; OwnerRaw=Read-OwnerRaw }
    if ($BrowserBaseline) {
      $browser = Invoke-NestedChild $holder "old-registered-browser" @{ SLOT_KIND="playwright" }
      Assert-True ($holder.Owner.gate -ceq "script-battery" -and $browser.status -eq 73) "old registered suite refuses browser before body"
      Stop-DriverHolder $holder | Out-Null
      Write-Output "BROWSER_OLD_FAIL registered=test:e2e:suite gate=script-battery browserExit=73 body=0"
      return
    }
    Assert-True ($holder.Owner.gate -ceq "playwright") "$($form.Name) acquires the browser gate"
    $marker = Join-Path $driver "browser.body"
    $chain = Invoke-Driver $holder "build-browser" @{ file="run-workspaces.mjs"; args=@("build"); env=@{
      SLOT_KIND="build"; SLOT_DEEPER="1"; SLOT_DEEPER_KIND="playwright"; SLOT_DEEPER_SCRIPT="playwright.js"; SLOT_DEEPER_MARKER=$marker
    } }
    Assert-True ($chain.status -eq 0) "$($form.Name) real build/browser chain accepts: $($chain.stderr)"
    $body = $chain.stdout | ConvertFrom-Json
    $browserBody = $body.deeper.stdout | ConvertFrom-Json
    Assert-True ($body.bodyCounter -eq 1 -and $browserBody.bodyCounter -eq 1 -and $body.deeper.status -eq 0) "build and deep browser execute exactly once"
    Assert-True ((Get-Content -LiteralPath $marker -Raw) -ceq $holder.Owner.lockId -and (Read-OwnerRaw) -ceq $holder.OwnerRaw) "build and browser share one unchanged owner"
    Write-Output "BROWSER_CHAIN form=$($form.Name) gate=$($holder.Owner.gate) build=1 browser=1 exit=0 owner=$($holder.Owner.lockId)"
    Stop-DriverHolder $holder | Out-Null
  }

  # The product caller's one-line dependency is exercised without a preload.
  $caller = Start-DriverHolder @{ SLOT_ROOT_KIND="playwright" }
  $callerChild = Invoke-NestedChild $caller "corrected-explicit-caller" @{ SLOT_KIND="playwright" } -Deeper
  Assert-True ($callerChild.status -eq 0) "explicit browser caller admits without preload"
  Stop-DriverHolder $caller | Out-Null

  $generic = Start-DriverHolder
  $negative = Invoke-NestedChild $generic "generic-battery-browser" @{ SLOT_KIND="playwright" }
  Assert-True ($negative.status -eq 73) "generic battery still refuses browser body"
  Stop-DriverHolder $generic | Out-Null

  Set-SourceMutant $guardSource $guard @(@('"playwright" = @("playwright", "script-battery", "build")', '"playwright" = @("playwright", "script-battery")')) "omit-browser-build-closure"
  $omitted = Start-DriverHolder @{ SLOT_ROOT_KIND="playwright" }
  $omittedChild = Invoke-NestedChild $omitted "omitted-build-closure" @{ SLOT_KIND="build" }
  Assert-True ($omittedChild.status -eq 73) "omitting build closure kills positive"
  Stop-DriverHolder $omitted | Out-Null
  Copy-Item -LiteralPath $guardSource -Destination $guard -Force

  Set-SourceMutant $guardSource $guard @(@('"script-battery" = @("script-battery", "vitest-full")', '"script-battery" = @("script-battery", "vitest-full", "playwright")')) "blanket-browser-boundary"
  $weakened = Start-DriverHolder
  $escaped = Invoke-NestedChild $weakened "blanket-browser-mutant" @{ SLOT_KIND="playwright" }
  Assert-True ($escaped.status -eq 0 -and $escaped.stdout -match '"bodyCounter":1') "blanket browser mutant violates negative"
  Stop-DriverHolder $weakened | Out-Null
  Copy-Item -LiteralPath $guardSource -Destination $guard -Force
  Write-Output "PASS browser admission: registered forms, real build/deep-browser bodies, explicit caller, generic refusal, omission and blanket-boundary mutants"
}
function New-CanonicalRequest($Holder, [hashtable]$Overrides = @{}) {
  $owner = $Holder.Owner
  $request = [ordered]@{
    schemaVersion = 1
    challenge = -join ((1..64) | ForEach-Object { "0123456789abcdef"[(Get-Random -Maximum 16)] })
    pid = "`$SELF_PID"
    kind = "script-battery"
    lockId = [string]$owner.lockId
    lane = [string]$owner.lane
    worktree = [string]$owner.worktree
    branch = $owner.branch
    head = [string]$owner.head
    identityMode = [string]$owner.identityMode
    gate = [string]$owner.gate
    launchId = $dispatchRecord.LaunchId
    laneRole = $dispatchRecord.Record.laneRole
  }
  $result = @{}
  foreach ($key in $request.Keys) { $result[$key] = $request[$key] }
  foreach ($entry in $Overrides.GetEnumerator()) {
    if ($null -eq $entry.Value -and $entry.Key.StartsWith("-")) { $result.Remove($entry.Key.Substring(1)) } else { $result[$entry.Key] = $entry.Value }
  }
  return $result
}
function Stop-DriverHolder($Holder, [int]$ExpectedExit = 0) {
  Set-Content -LiteralPath (Join-Path $Holder.Driver "stop") -Value "stop"
  $output = Complete-Fixture $Holder.Entry $ExpectedExit "driver holder"
  Wait-Condition { -not (Test-Path -LiteralPath $lock) } "driver holder release" 1200
  return $output
}

function Invoke-CensusControls {
  $script:dispatchRecord = Write-DispatchOwnership -Label "goal-census-selected-native"
  $selectedHash = (Get-FileHash -LiteralPath $dispatchRecord.Path -Algorithm SHA256).Hash
  $foreignDriver = Join-Path $root "foreign-driver"
  New-Item -ItemType Directory -Path $foreignDriver | Out-Null
  $foreignScript = Join-Path $secondWorktree "foreign.cjs"
  [IO.File]::WriteAllText($foreignScript, @'
const fs = require('node:fs');
const path = require('node:path');
const cp = require('node:child_process');
const driver = process.env.FOREIGN_DRIVER;
fs.writeFileSync(path.join(driver, 'ready'), JSON.stringify({pid: process.pid,
  worktree: fs.realpathSync(process.cwd()),
  head: cp.execFileSync('git', ['rev-parse', 'HEAD'], {encoding:'utf8'}).trim(),
  branch: cp.execFileSync('git', ['branch', '--show-current'], {encoding:'utf8'}).trim()}));
const timer = setInterval(() => {
  if (fs.existsSync(path.join(driver, 'stop'))) { clearInterval(timer); process.exit(0); }
}, 10);
'@, [Text.UTF8Encoding]::new($false))
  # This is an actual independent native process in its own real repository.
  # The test authors only synthetic ownership records for these actual identities.
  $foreignProcess = Start-Fixture -Script $foreignScript -WorkingDirectory $secondWorktree -ExtraEnvironment @{ FOREIGN_DRIVER=$foreignDriver }
  Wait-Condition { Test-Path -LiteralPath (Join-Path $foreignDriver "ready") } "foreign native process ready"
  $native = Get-Content -LiteralPath (Join-Path $foreignDriver "ready") -Raw | ConvertFrom-Json
  Assert-True ($native.pid -eq $foreignProcess.Identity.pid -and $native.worktree -ieq $secondWorktree -and
    $native.head -ceq $secondHead -and $native.branch -ceq "codex/heavy-slot-second") "foreign child independently reports actual cwd/Git/PID"
  $foreignArgs = @{ RecordWorktree=$secondWorktree; RecordLane=$secondLaneName; Branch=$native.branch; Head=$native.head;
    Label="goal-census-foreign-native"; ChildPid=$foreignProcess.Identity.pid; ChildStartUtc=$foreignProcess.Identity.processStartUtc;
    LauncherIdentity=@{ pid=$PID; processStartUtc=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString("o") } }
  Write-Output "CENSUS_SELECTED raw=$($dispatchRecord.Raw) sha256=$selectedHash"
  Write-Output "CENSUS_FOREIGN_NATIVE $($native | ConvertTo-Json -Compress) start=$($foreignProcess.Identity.processStartUtc) launcher=$PID"

  function Set-ForeignState($Foreign, [string]$State) {
    $record = $Foreign.Raw | ConvertFrom-Json -AsHashtable -DateKind String
    $record.state = $State
    if ($State -ceq "launching") { $record.childPid=$null; $record.childStartIdentity=$null }
    [IO.File]::WriteAllText($Foreign.Path, ($record | ConvertTo-Json -Compress -Depth 4), [Text.UTF8Encoding]::new($false))
  }
  function Assert-CensusBody($Holder, [string]$Name, [int]$Exit, [string]$Reason = "") {
    $result = Invoke-NestedChild $Holder $Name
    Assert-True ($result.status -eq $Exit) "$Name expected $Exit actual $($result.status): $($result.stderr)"
    if ($Exit -eq 0) { Assert-True ($result.stdout -match '"bodyCounter":1') "$Name executes real body" }
    else { Assert-True ($result.stderr -match $Reason) "$Name exact refusal $Reason actual $($result.stderr)" }
    Assert-True ((Get-FileHash -LiteralPath $dispatchRecord.Path -Algorithm SHA256).Hash -ceq $selectedHash) "$Name unchanged selected bytes"
  }

  # Genuine original C# and integrated #7956 wrapper; no policy mutant is used
  # as the before-fix artifact. Each barrier changes just the foreign lifecycle.
  foreach ($source in @(
      @{ Ref="436a548cd8a1b9239ce43c4358a632c9d730261f:.orchestrator/heavy-nested-owner.cs"; Path=$nestedOwner },
      @{ Ref="0c99b24a4586a6c9d9990afa20ddec98e238f2dc:.orchestrator/invoke-heavy-verifier.ps1"; Path=$guard })) {
    $lines = @(& git -C $controllerRoot show $source.Ref)
    Assert-True ($LASTEXITCODE -eq 0) "genuine census baseline source $($source.Ref)"
    [IO.File]::WriteAllText($source.Path, ($lines -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
    Write-Output "CENSUS_BASELINE source=$($source.Ref) blob=$(& git -C $controllerRoot rev-parse $source.Ref)"
  }
  foreach ($transition in @("start", "lifecycle", "scavenged-exit")) {
    $foreign = if ($transition -cne "start") { Write-DispatchOwnership @foreignArgs } else { $null }
    if ($transition -ceq "lifecycle") { Set-ForeignState $foreign "launching" }
    $holder = Start-DriverHolder
    Assert-CensusBody $holder "before-$transition-initial" 0
    if ($transition -ceq "start") { $foreign = Write-DispatchOwnership @foreignArgs }
    elseif ($transition -ceq "lifecycle") { Set-ForeignState $foreign "started" }
    else {
      Set-Content -LiteralPath (Join-Path $foreignDriver "stop") -Value stop
      Complete-Fixture $foreignProcess 0 "baseline foreign native exit" | Out-Null
      Assert-True (-not (Test-ExactProcess $foreignProcess.Identity)) "baseline foreign exact owner exited"
      Remove-DispatchOwnership $foreign
    }
    Assert-CensusBody $holder "before-$transition" 73 "census changed"
    Stop-DriverHolder $holder | Out-Null
    if ($foreign) { Remove-DispatchOwnership $foreign }
  }
  Restore-FixtureSources
  Remove-Item -LiteralPath (Join-Path $foreignDriver "stop"), (Join-Path $foreignDriver "ready") -Force
  $foreignProcess = Start-Fixture -Script $foreignScript -WorkingDirectory $secondWorktree -ExtraEnvironment @{ FOREIGN_DRIVER=$foreignDriver }
  Wait-Condition { Test-Path -LiteralPath (Join-Path $foreignDriver "ready") } "candidate foreign native ready"
  $native = Get-Content -LiteralPath (Join-Path $foreignDriver "ready") -Raw | ConvertFrom-Json
  Assert-True ($native.pid -eq $foreignProcess.Identity.pid -and $native.worktree -ieq $secondWorktree -and $native.head -ceq $secondHead) "candidate foreign actual identity"
  $foreignArgs.ChildPid=$foreignProcess.Identity.pid; $foreignArgs.ChildStartUtc=$foreignProcess.Identity.processStartUtc
  Write-Output "CENSUS_FOREIGN_NATIVE_CANDIDATE $($native | ConvertTo-Json -Compress) start=$($foreignProcess.Identity.processStartUtc) launcher=$PID"
  $holder = Start-DriverHolder
  Assert-CensusBody $holder "candidate-initial" 0
  $foreign = Write-DispatchOwnership @foreignArgs
  Set-ForeignState $foreign "launching"
  Write-Output "CENSUS_FOREIGN raw=$($foreign.Raw)"
  Assert-CensusBody $holder "candidate-foreign-start" 0
  Assert-CensusBody $holder "candidate-foreign-launching" 0
  Set-ForeignState $foreign "started"
  Assert-CensusBody $holder "candidate-foreign-started" 0

  # Routing provenance is an optional closed group on ownership-v4. The
  # native census reader must accept the complete typed group while refusing
  # partial, malformed, and unknown additions without changing selected bytes.
  $completeProvenance = $foreign.Raw | ConvertFrom-Json -AsHashtable -DateKind String
  $completeProvenance.policyGeneration = 1
  $completeProvenance.registryAuthorityDigest = "digest-v287"
  $completeProvenance.family = "astra"
  $completeProvenance.slot = "explicit"
  $completeProvenance.usedLastKnownGood = $false
  $completeProvenanceRaw = $completeProvenance | ConvertTo-Json -Compress -Depth 4
  [IO.File]::WriteAllText($foreign.Path, $completeProvenanceRaw, [Text.UTF8Encoding]::new($false))
  Assert-CensusBody $holder "candidate-foreign-complete-provenance" 0
  $partialProvenance = $completeProvenanceRaw | ConvertFrom-Json -AsHashtable -DateKind String
  $partialProvenance.Remove("slot")
  [IO.File]::WriteAllText($foreign.Path, ($partialProvenance | ConvertTo-Json -Compress -Depth 4), [Text.UTF8Encoding]::new($false))
  Assert-CensusBody $holder "candidate-foreign-partial-provenance" 73 "ownership-record-invalid"
  $malformedProvenance = $completeProvenanceRaw | ConvertFrom-Json -AsHashtable -DateKind String
  $malformedProvenance.policyGeneration = 0
  [IO.File]::WriteAllText($foreign.Path, ($malformedProvenance | ConvertTo-Json -Compress -Depth 4), [Text.UTF8Encoding]::new($false))
  Assert-CensusBody $holder "candidate-foreign-malformed-provenance" 73 "ownership-record-invalid"
  foreach ($malformedCase in @(
      @{Name="policy-overflow"; Field="policyGeneration"; Value=[int64]2147483648},
      @{Name="policy-string"; Field="policyGeneration"; Value="1"},
      @{Name="policy-fraction"; Field="policyGeneration"; Value=1.5},
      @{Name="digest-nonstring"; Field="registryAuthorityDigest"; Value=7},
      @{Name="digest-invalid"; Field="registryAuthorityDigest"; Value="digest with space"},
      @{Name="family-invalid"; Field="family"; Value="Astra"},
      @{Name="slot-invalid"; Field="slot"; Value="codex.primary.extra"},
      @{Name="used-lkg-string"; Field="usedLastKnownGood"; Value="false"})) {
    $malformedCaseRecord = $completeProvenanceRaw | ConvertFrom-Json -AsHashtable -DateKind String
    $malformedCaseRecord[$malformedCase.Field] = $malformedCase.Value
    [IO.File]::WriteAllText($foreign.Path, ($malformedCaseRecord | ConvertTo-Json -Compress -Depth 4), [Text.UTF8Encoding]::new($false))
    Assert-CensusBody $holder "candidate-foreign-malformed-$($malformedCase.Name)" 73 "ownership-record-invalid"
  }
  $unknownProvenance = $completeProvenanceRaw | ConvertFrom-Json -AsHashtable -DateKind String
  $unknownProvenance.unknownRoutingField = $true
  [IO.File]::WriteAllText($foreign.Path, ($unknownProvenance | ConvertTo-Json -Compress -Depth 4), [Text.UTF8Encoding]::new($false))
  Assert-CensusBody $holder "candidate-foreign-unknown-provenance" 73 "ownership-record-invalid"
  $exactlyFiveUnknown = $foreign.Raw | ConvertFrom-Json -AsHashtable -DateKind String
  foreach ($unknownName in @("unknownA", "unknownB", "unknownC", "unknownD", "unknownE")) { $exactlyFiveUnknown[$unknownName] = $true }
  [IO.File]::WriteAllText($foreign.Path, ($exactlyFiveUnknown | ConvertTo-Json -Compress -Depth 4), [Text.UTF8Encoding]::new($false))
  Assert-CensusBody $holder "candidate-foreign-exactly-five-unknown" 73 "ownership-record-invalid"
  [IO.File]::WriteAllText($foreign.Path, $foreign.Raw, [Text.UTF8Encoding]::new($false))

  # The foreign record begins irrelevant, then actually claims the selected
  # target with the same live foreign process. This is refused on the next call.
  $relevant = $foreign.Raw | ConvertFrom-Json -AsHashtable -DateKind String
  $relevant.worktree=$worktree; $relevant.lane=$laneName; $relevant.branch="codex/heavy-slot-fixture"; $relevant.head=$fixtureHead
  [IO.File]::WriteAllText($foreign.Path, ($relevant | ConvertTo-Json -Compress -Depth 4), [Text.UTF8Encoding]::new($false))
  Assert-CensusBody $holder "foreign-becomes-competing" 73 "competing target|duplicate-live-ownership"
  [IO.File]::WriteAllText($foreign.Path, $foreign.Raw, [Text.UTF8Encoding]::new($false))
  Assert-CensusBody $holder "foreign-restored-irrelevant" 0
  foreach ($bad in @(
      @{Name="malformed-foreign"; Raw="{"; Reason="census unknown"},
      @{Name="extra-foreign-field"; Raw=$foreign.Raw.TrimEnd('}') + ',"unknown":true}'; Reason="ownership-record-invalid"},
      @{Name="foreign-record-byte-bound"; Raw=(" " * 65537); Reason="byte bound"})) {
    [IO.File]::WriteAllText($foreign.Path, $bad.Raw, [Text.UTF8Encoding]::new($false))
    Assert-CensusBody $holder $bad.Name 73 $bad.Reason
  }
  [IO.File]::WriteAllText($foreign.Path, $foreign.Raw, [Text.UTF8Encoding]::new($false))
  foreach ($boundCase in @(@{Name="record-count"; Count=63; Content="{}"; Reason="truncated"},
      @{Name="aggregate-bytes"; Count=16; Content=(" " * 65536); Reason="census byte bound"})) {
    $paths = @()
    try {
      for ($i=0; $i -lt $boundCase.Count; $i++) {
        $path = Join-Path $orchestrator "dispatch-launch-$([guid]::NewGuid()).json"
        $paths += $path
        [IO.File]::WriteAllText($path, $boundCase.Content, [Text.UTF8Encoding]::new($false))
      }
      Assert-CensusBody $holder "foreign-$($boundCase.Name)-bound" 73 $boundCase.Reason
    } finally { foreach ($path in $paths) { Remove-Item -LiteralPath $path -Force } }
  }
  $unsafePath = Join-Path $orchestrator "dispatch-launch-$([guid]::NewGuid()).json"
  New-Item -ItemType Junction -Path $unsafePath -Target $secondWorktree | Out-Null
  try { Assert-CensusBody $holder "foreign-unsafe-census-entry" 73 "unsafe" }
  finally { Remove-Item -LiteralPath $unsafePath -Force }
  $duplicateTranscript = $foreign.Raw | ConvertFrom-Json -AsHashtable -DateKind String
  $duplicateTranscript.label=$dispatchRecord.Record.label
  $duplicateTranscript.transcriptPath=Join-Path $orchestrator ("./" + $dispatchRecord.Record.label + ".jsonl")
  [IO.File]::WriteAllText($foreign.Path, ($duplicateTranscript | ConvertTo-Json -Compress -Depth 4), [Text.UTF8Encoding]::new($false))
  Assert-CensusBody $holder "foreign-aliased-duplicate-transcript" 73 "duplicate-live-transcript"
  $aliasPath = Join-Path $container "census-alias"
  New-Item -ItemType Junction -Path $aliasPath -Target $secondWorktree | Out-Null
  $aliasRecord = $foreign.Raw | ConvertFrom-Json -AsHashtable -DateKind String
  $aliasRecord.worktree=$aliasPath; $aliasRecord.lane="census-alias"
  [IO.File]::WriteAllText($foreign.Path, ($aliasRecord | ConvertTo-Json -Compress -Depth 4), [Text.UTF8Encoding]::new($false))
  try { Assert-CensusBody $holder "foreign-unsafe-worktree" 73 "unsafe worktree" }
  finally { Remove-Item -LiteralPath $aliasPath -Force }
  [IO.File]::WriteAllText($foreign.Path, $foreign.Raw, [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText($foreign.TranscriptPath, "{`n", [Text.UTF8Encoding]::new($false))
  Assert-CensusBody $holder "foreign-transcript-unknown-with-unchanged-record" 73 "transcript-state-unknown"
  [IO.File]::WriteAllText($foreign.TranscriptPath, "{`"type`":`"turn.completed`"}`n", [Text.UTF8Encoding]::new($false))
  Assert-CensusBody $holder "foreign-terminal-with-unchanged-record" 0
  [IO.File]::WriteAllText($dispatchRecord.TranscriptPath, "{`"type`":`"turn.completed`"}`n", [Text.UTF8Encoding]::new($false))
  Assert-CensusBody $holder "selected-terminal-with-unchanged-record" 73 "selected dispatch is not active"
  [IO.File]::WriteAllText($dispatchRecord.TranscriptPath, "{`"type`":`"item.completed`"}`n", [Text.UTF8Encoding]::new($false))
  Stop-DriverHolder $holder | Out-Null

  # Pause the real wrapper immediately after its first census capture. Only
  # the disposable copy gets this barrier; ownership selection and native
  # validation run unmodified on both sides of the actual lifecycle transition.
  foreach ($case in @(
      @{Name="before-admission-foreign-change"; Baseline=$true; Relevant=$false; Exit=73},
      @{Name="candidate-admission-foreign-change"; Baseline=$false; Relevant=$false; Exit=0},
      @{Name="candidate-admission-new-competing-claim"; Baseline=$false; Relevant=$true; Exit=73})) {
    Restore-FixtureSources
    if ($case.Baseline) {
      foreach ($source in @(
          @{Ref="436a548cd8a1b9239ce43c4358a632c9d730261f:.orchestrator/heavy-nested-owner.cs"; Path=$nestedOwner},
          @{Ref="0c99b24a4586a6c9d9990afa20ddec98e238f2dc:.orchestrator/invoke-heavy-verifier.ps1"; Path=$guard})) {
        $lines=@(& git -C $controllerRoot show $source.Ref)
        Assert-True ($LASTEXITCODE -eq 0) "admission original source available"
        [IO.File]::WriteAllText($source.Path, ($lines -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
      }
    }
    [IO.File]::WriteAllText($foreign.Path, $foreign.Raw, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($foreign.TranscriptPath, "{`"type`":`"item.completed`"}`n", [Text.UTF8Encoding]::new($false))
    $barrier = Join-Path $root $case.Name
    $sourceText = [IO.File]::ReadAllText($guard)
    $anchor = if($case.Baseline) { '$beforeCensus = [ChaseSets.HeavyAdmission.NestedOwnerServer]::CaptureDispatchCensus($runtimeRoot)' } else { '$before = Get-HeavyCallerAncestry $rootPid $rootStart $oldestLaunch $candidatePids' }
    Assert-True (($sourceText.Split($anchor)).Count -eq 2) "one admission barrier anchor"
    $barrierCode = @'
    [IO.File]::WriteAllText($env:CENSUS_BARRIER + '.ready', 'captured')
    $barrierWatch = [Diagnostics.Stopwatch]::StartNew()
    while (-not [IO.File]::Exists($env:CENSUS_BARRIER + '.go')) {
      if ($barrierWatch.ElapsedMilliseconds -ge 30000) { throw 'test admission barrier expired' }
      Start-Sleep -Milliseconds 10
    }
'@
    [IO.File]::WriteAllText($guard, $sourceText.Replace($anchor, $anchor + "`n" + $barrierCode), [Text.UTF8Encoding]::new($false))
    $marker = Join-Path $root ($case.Name + ".body")
    $entry = Start-GateWrapper "test:scripts" $childFixture @{ CENSUS_BARRIER=$barrier; SLOT_MARKER=$marker }
    Wait-Condition { Test-Path -LiteralPath ($barrier + ".ready") } "actual admission snapshot barrier"
    if ($case.Relevant) {
      [IO.File]::WriteAllText($foreign.Path, ($relevant | ConvertTo-Json -Compress -Depth 4), [Text.UTF8Encoding]::new($false))
    } else { Set-ForeignState $foreign "launching" }
    [IO.File]::WriteAllText($barrier + ".go", "continue")
    $outcome = Complete-Fixture $entry $case.Exit $case.Name
    Write-Output "CENSUS_ADMISSION name=$($case.Name) exit=$($case.Exit) marker=$(Test-Path -LiteralPath $marker) stdout=$($outcome.stdout) stderr=$($outcome.stderr)"
    Assert-True ((Test-Path -LiteralPath $marker) -eq ($case.Exit -eq 0)) "admission transition real body marker"
    if ($case.Exit -eq 0) { Assert-True ($outcome.stdout -match '"bodyCounter":1') "admission candidate real child body" }
    else { Assert-True ($outcome.stderr -match 'census|provable dispatch binding') "admission refusal is ownership"
      Assert-True ($outcome.stdout -notmatch '"bodyCounter":1') "admission refusal no body" }
    Wait-Condition { -not (Test-Path -LiteralPath $lock) } "admission barrier exact release"
  }
  Restore-FixtureSources
  [IO.File]::WriteAllText($foreign.Path, $foreign.Raw, [Text.UTF8Encoding]::new($false))
  $holder = Start-DriverHolder
  Set-Content -LiteralPath (Join-Path $foreignDriver "stop") -Value stop
  Complete-Fixture $foreignProcess 0 "foreign native owner exits in foreground" | Out-Null
  Assert-True (-not (Test-ExactProcess $foreignProcess.Identity)) "exact foreign owner has exited"
  Assert-CensusBody $holder "foreign-exited-with-unchanged-record" 0
  Remove-DispatchOwnership $foreign
  Assert-CensusBody $holder "foreign-scavenged-after-exit" 0
  Stop-DriverHolder $holder | Out-Null
  Remove-DispatchOwnership $dispatchRecord
  $script:dispatchRecord = $null
  Write-Output "PASS census lifecycle native before73/after0, fresh foreign/selected semantics, competing transition and exact foreground exit"
}

function Invoke-CurrentBindingControls {
  # The native test author is the recorded dispatch child. It makes real Git
  # commits after launch, then runs the unmodified product scoped CLI. Only the
  # disposable package's leaf checks are markers; no admission seam replaces
  # the positive path. Product sources are pinned to the observed consumer.
  $product = Join-Path (Split-Path -Parent $controllerRoot) "main"
  $productHead = "50a920d4cede95309dff8c4aead17ed43859ccee"
  foreach ($relative in @("scripts/verify-static-scoped.mjs", "scripts/verify-static-surfaces.mjs",
      "scripts/change-scope.mjs", "scripts/e2e-suites.mjs", "scripts/lib/repo.mjs",
      "scripts/lib/risk-policy-v1.mjs", "scripts/lib/heavy-slot.mjs")) {
    $source = @(& git -C $product show "${productHead}:$relative")
    Assert-True ($LASTEXITCODE -eq 0) "pinned production scoped dependency $relative is available"
    $target = Join-Path $worktree $relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
    [IO.File]::WriteAllText($target, ($source -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
  }
  $leaf = Join-Path $worktree "scripts/binding-leaf.mjs"
  [IO.File]::WriteAllText($leaf, @'
import { appendFileSync } from "node:fs";
import { acquireHeavySlot } from "./lib/heavy-slot.mjs";
acquireHeavySlot("repository-gate");
appendFileSync(process.env.BINDING_MARKER, `${process.argv[2]}:${process.env.CHASE_SETS_HEAVY_SLOT_ID}\n`);
console.log(`BINDING_BODY ${process.argv[2]} pid=${process.pid}`);
'@, [Text.UTF8Encoding]::new($false))
  $package = @{ name = "synthetic-current-binding-control"; private = $true; scripts = @{
      "verify:static:scoped" = "node ./scripts/verify-static-scoped.mjs"
      "verify:static" = "pnpm run format:check && pnpm run check:structure"
      "format:check" = "node ./scripts/binding-leaf.mjs format"
      "check:structure" = "node ./scripts/binding-leaf.mjs structure"
    } }
  [IO.File]::WriteAllText((Join-Path $worktree "package.json"), ($package | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText((Join-Path $worktree ".gitignore"), "node_modules/`npnpm-lock.yaml`n", [Text.UTF8Encoding]::new($false))
  Invoke-FixtureGit @("add", "--", "scripts", "package.json", ".gitignore") | Out-Null
  Invoke-FixtureGit @("commit", "-m", "install pinned scoped CLI in disposable repository") | Out-Null
  $launchHead = Invoke-FixtureGit @("rev-parse", "HEAD")
  Invoke-FixtureGit @("update-ref", "refs/remotes/origin/main", $launchHead) | Out-Null
  $script:dispatchRecord = Write-DispatchOwnership -Head $launchHead -Label "goal-current-binding-native-author"
  $launchBytes = [IO.File]::ReadAllBytes($dispatchRecord.Path)
  $launchHash = (Get-FileHash -LiteralPath $dispatchRecord.Path -Algorithm SHA256).Hash
  [IO.File]::WriteAllText((Join-Path $worktree "scripts/committed-after-launch.txt"), "real post-launch change")
  Invoke-FixtureGit @("add", "--", "scripts/committed-after-launch.txt") | Out-Null
  Invoke-FixtureGit @("commit", "-m", "native author advances after immutable launch snapshot") | Out-Null
  $advancedHead = Invoke-FixtureGit @("rev-parse", "HEAD")
  Assert-True ($advancedHead -cne $launchHead -and (Invoke-FixtureGit @("status", "--porcelain")) -ceq "") "real post-launch commit is new and clean"
  Write-Output "BINDING_INPUT product=$productHead launch=$launchHead current=$advancedHead authorPid=$PID authorStart=$($dispatchRecord.Record.childStartIdentity) launcherPid=$($dispatchRecord.Record.launcherPid) launcherStart=$($dispatchRecord.Record.launcherStartIdentity) launchSha256=$launchHash"

  function Invoke-ScopedBinding([string]$Name, [int]$ExpectedExit) {
    Assert-True ((Invoke-FixtureGit @("status", "--porcelain")) -ceq "") "$Name starts at a clean exact Git identity"
    $inputHead = Invoke-FixtureGit @("rev-parse", "HEAD")
    $inputTree = Invoke-FixtureGit @("write-tree")
    $marker = Join-Path $root "$Name.body"
    $entry = Start-CmdFixture "pnpm run verify:static:scoped" @{ BINDING_MARKER = $marker }
    Wait-Condition {
      if ($entry.Process.HasExited) { throw "scoped $Name exited before owner: $($entry.Process.StandardError.ReadToEnd())" }
      (Read-Owner) -and (Read-Owner).state -ceq "attached"
    } "ordinary scoped $Name actual owner" 1200
    $scopedOwnerRaw = Read-OwnerRaw
    $output = Complete-Fixture $entry $ExpectedExit "ordinary scoped $Name" 60000
    Wait-Condition { -not (Test-Path -LiteralPath $lock) } "scoped $Name exact release" 1200
    $bodies = if (Test-Path -LiteralPath $marker) { @(Get-Content -LiteralPath $marker) } else { @() }
    Write-Output "SCOPED_BINDING name=$Name exit=$ExpectedExit bodies=$($bodies.Count) head=$inputHead indexTree=$inputTree command=pnpm-run-verify:static:scoped pid=$($entry.Identity.pid) start=$($entry.Identity.processStartUtc)"
    Write-Output "SCOPED_OWNER name=$Name raw=$scopedOwnerRaw"
    Write-Output $output.stdout
    Write-Output $output.stderr
    if ($ExpectedExit -eq 0) {
      Assert-True ($bodies.Count -eq 2 -and $bodies[0] -cmatch '^format:[a-f0-9]{32}$' -and
        $bodies[1] -ceq ("structure:" + $bodies[0].Substring(7))) "ordinary scoped children share the actual admitted owner"
    } else {
      Assert-True ($bodies.Count -eq 0 -and $output.stderr -match "no provable dispatch binding") "refused ordinary scoped body markers remain absent"
    }
    Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($dispatchRecord.Path)) -ceq
      [Convert]::ToBase64String($launchBytes)) "original launch bytes remain immutable through $Name"
    Assert-True ((Invoke-FixtureGit @("status", "--porcelain")) -ceq "" -and
      (Invoke-FixtureGit @("rev-parse", "HEAD")) -ceq $inputHead -and
      (Invoke-FixtureGit @("write-tree")) -ceq $inputTree) "$Name preserves clean head/index/worktree inputs"
  }

  # Execute the exact pre-fix wrapper, then the candidate, against the same
  # real native author, unchanged launch bytes, clean Git head and scoped CLI.
  $original = @(& git -C $controllerRoot cat-file blob 3d1a71ebd741e78cb018e16e758971272ba31fb7)
  Assert-True ($LASTEXITCODE -eq 0) "pre-fix wrapper blob is available"
  [IO.File]::WriteAllText($guard, ($original -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
  Invoke-ScopedBinding "before-fix-postcommit" 73
  $diagnosticEntry = Start-GateWrapper "test:scripts" $fixture
  $diagnostic = Complete-Fixture $diagnosticEntry 73 "original binding reason at same actual identity"
  Wait-Condition { -not (Test-Path -LiteralPath $lock) } "original diagnostic release" 1200
  Assert-True ($diagnostic.stderr -match "dispatch identity differs from admitted identity") "actual original wrapper reports the binding reason"
  Write-Output "BINDING_ORIGINAL_DIAGNOSTIC $($diagnostic.stderr)"
  Copy-Item -LiteralPath $guardSource -Destination $guard -Force
  Invoke-ScopedBinding "candidate-postcommit" 0
  Invoke-FixtureGit @("switch", "-c", "codex/current-binding-created") | Out-Null
  Invoke-ScopedBinding "candidate-created-branch" 0
  Invoke-FixtureGit @("checkout", "--detach", $advancedHead) | Out-Null
  Invoke-ScopedBinding "candidate-transient-detached" 0
  Invoke-FixtureGit @("switch", "codex/heavy-slot-fixture") | Out-Null

  # A ready driver is a real admission barrier. Stage and commit a real file
  # while it waits, then make genuine children request the frozen admission.
  $holder = Start-DriverHolder
  foreach ($claim in @(
      @{ Name="stale-launch-head"; Value=@{ head=$launchHead }; Reason="not the admitted head" },
      @{ Name="forged-head"; Value=@{ head=("0" * 40) }; Reason="not the admitted head" },
      @{ Name="forged-branch"; Value=@{ branch="codex/foreign" }; Reason="not the admitted branch" },
      @{ Name="forged-worktree"; Value=@{ worktree=$secondWorktree }; Reason="not the admitted worktree" })) {
    $reply = Invoke-RawRequest $holder $claim.Name (New-CanonicalRequest $holder $claim.Value)
    Assert-True (-not (Test-RawAccepted $reply) -and $reply.reply -match $claim.Reason) "one-variable current identity claim $($claim.Name) refuses"
    Write-Output "BINDING_NEGATIVE name=$($claim.Name) signedBodyAuthority=0 reply=$($reply.reply)"
  }
  [IO.File]::AppendAllText((Join-Path $worktree "scripts/committed-after-launch.txt"), " barrier transition")
  Invoke-FixtureGit @("add", "--", "scripts/committed-after-launch.txt") | Out-Null
  Invoke-FixtureGit @("commit", "-m", "actual transition after admission barrier") | Out-Null
  $barrierHead = Invoke-FixtureGit @("rev-parse", "HEAD")
  $marker = Join-Path $root "after-admission-transition.body"
  $moved = Invoke-NestedChild $holder "postcommit-admission-barrier" @{ SLOT_MARKER=$marker }
  Assert-True ($moved.status -eq 73 -and -not (Test-Path -LiteralPath $marker) -and
    $moved.stdout -notmatch '"bodyCounter":1' -and $moved.stderr -match "HEAD moved") "actual post-admission worktree/index/HEAD transition refuses before body"
  Write-Output "BINDING_BARRIER admitted=$advancedHead current=$barrierHead exit=$($moved.status) marker=absent stderr=$($moved.stderr)"
  Stop-DriverHolder $holder | Out-Null
  Assert-True ((Get-FileHash -LiteralPath $dispatchRecord.Path -Algorithm SHA256).Hash -ceq $launchHash) "transition does not rewrite launch bytes"
  Remove-DispatchOwnership $dispatchRecord

  # An immutable launch at the prior head does not acquire branch semantics.
  Invoke-FixtureGit @("checkout", "--detach", $advancedHead) | Out-Null
  $script:dispatchRecord = Write-DispatchOwnership -ImmutableHead -Head $advancedHead -Label "goal-current-binding-immutable"
  Invoke-FixtureGit @("checkout", "--detach", $barrierHead) | Out-Null
  $immutableMarker = Join-Path $root "immutable-head-moved.body"
  $immutableEntry = Start-Fixture -ExtraEnvironment @{ SLOT_MARKER=$immutableMarker }
  $immutableChild = Complete-Fixture $immutableEntry 73 'immutable launch head moved before acquisition'
  Assert-True (-not (Test-Path -LiteralPath $immutableMarker) -and -not (Test-Path -LiteralPath $lock) -and
    $immutableChild.stdout -notmatch '"bodyCounter":1' -and $immutableChild.stderr -match 'caller eligibility: containing dispatch is stale') "immutable launch refuses new actual detached head before reservation and body"
  Write-Output "BINDING_NEGATIVE name=immutable-launch-head-moved original=$advancedHead current=$barrierHead exit=73 marker=absent"
  Remove-DispatchOwnership $dispatchRecord
  Invoke-FixtureGit @("switch", "codex/heavy-slot-fixture") | Out-Null
  Invoke-FixtureGit @("reset", "--hard", $fixtureHead) | Out-Null
  $script:dispatchRecord = $null
  Write-Output "PASS current canonical binding: real post-launch commit, ordinary scoped before/after, branch creation, transient detach, strict immutable launch and transition barrier"
}
function Test-RawAccepted($Reply) {
  # A signed envelope means the server admitted the raw request.
  return $null -ne $Reply.reply -and $Reply.reply -match '^\{"payload":"' -and $Reply.reply -match '"signature":"'
}
function New-TamperedTransport([string]$Transport, [hashtable]$Overrides) {
  $descriptor = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Transport)) | ConvertFrom-Json
  $table = [ordered]@{}
  foreach ($property in $descriptor.PSObject.Properties) { $table[$property.Name] = $property.Value }
  foreach ($entry in $Overrides.GetEnumerator()) { $table[$entry.Key] = $entry.Value }
  return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($table | ConvertTo-Json -Compress -Depth 4)))
}
function Test-LauncherNonReentry {
  # These claims arrive after startup, without an active preload. Direct
  # acquisition derives live identity; holder scrubbing prevents re-entry.
  $staleConfig = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((@{
    schemaVersion = 1
    guardPath = $guard
    powershellPath = $pwsh
    containerRoot = $container
    worktree = $worktree
    lane = $laneName
    branch = 'codex/previous-lane-assignment'
    head = $fixtureHead
  } | ConvertTo-Json -Compress)))
  foreach ($case in @(
      @{ name = 'malformed'; config = 'deliberately-malformed-synthetic-config' },
      @{ name = 'stale'; config = $staleConfig }
    )) {
    $launcherReentryMarker = Join-Path $root "launcher-non-reentry-$($case.name).marker"
    $launcherReentry = Start-Fixture -ExtraEnvironment @{
      SLOT_MARKER = $launcherReentryMarker
      SLOT_LAUNCHER_NODE_OPTIONS = "--require=`"$preloadForNode`""
      SLOT_LAUNCHER_ADMISSION_CONFIG = $case.config
    }
    Complete-Fixture $launcherReentry 0 "holder launcher inherited-admission non-reentry ($($case.name))" | Out-Null
    Wait-Condition { -not (Test-Path -LiteralPath $lock) } "holder launcher non-reentry release" 1200
    Assert-True (Test-Path -LiteralPath $launcherReentryMarker) "holder launcher does not re-enter inherited admission"
    Write-Output "PASS holder launcher does not re-enter inherited preload/config admission ($($case.name)) gateExit=$($launcherReentry.Process.ExitCode) body=True ownerReleased=True"
  }
}
function New-ForeignPublicKey {
  $key = [Security.Cryptography.ECDsa]::Create([Security.Cryptography.ECCurve+NamedCurves]::nistP256)
  try { return [Convert]::ToBase64String($key.ExportSubjectPublicKeyInfo()) } finally { $key.Dispose() }
}

New-Item -ItemType Directory -Path $orchestrator, (Split-Path -Parent $fixture), $privateTemp, $secondWorktree | Out-Null
Copy-Item -LiteralPath $clientSource -Destination $client
Copy-Item -LiteralPath $guardSource -Destination $guard
Copy-Item -LiteralPath $launcherSource -Destination $launcher
Copy-Item -LiteralPath $preloadSource -Destination $preload
Copy-Item -LiteralPath $nestedOwnerSource -Destination $nestedOwner
Copy-Item -LiteralPath $nestedClientSource -Destination $nestedClient
Copy-Item -LiteralPath $dispatchOwnershipSource -Destination $dispatchOwnership

$fixtureSource = @'
const childProcess = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const acquireHeavySlot = require(path.join(__dirname, "..", "..", ".orchestrator", "heavy-slot.cjs"));

if (path.resolve(os.tmpdir()) !== path.resolve(process.env.TEMP) ||
    path.resolve(process.env.TEMP) !== path.resolve(process.env.TMP)) {
  throw new Error("fixture Node temp paths do not agree");
}

if (process.env.SLOT_EXIT_MARKER) {
  process.on("exit", (code) => fs.writeFileSync(process.env.SLOT_EXIT_MARKER, String(code)));
}
if (process.env.SLOT_LAUNCHER_NODE_OPTIONS) {
  process.env.NODE_OPTIONS = process.env.SLOT_LAUNCHER_NODE_OPTIONS;
}
if (process.env.SLOT_LAUNCHER_ADMISSION_CONFIG) {
  process.env.CHASE_SETS_HEAVY_ADMISSION_CONFIG = process.env.SLOT_LAUNCHER_ADMISSION_CONFIG;
}
const acquireStarted = Date.now();
if (process.env.SLOT_ROOT_KIND) {
  acquireHeavySlot(process.env.SLOT_ROOT_KIND);
} else {
  acquireHeavySlot("script-battery");
}
const acquireMs = Date.now() - acquireStarted;
if (process.env.SLOT_MARKER) {
  fs.writeFileSync(process.env.SLOT_MARKER, process.env.CHASE_SETS_HEAVY_SLOT_ID || "missing-token");
}
if (process.env.SLOT_TRANSPORT_MARKER) {
  fs.writeFileSync(process.env.SLOT_TRANSPORT_MARKER, process.env.CHASE_SETS_HEAVY_SLOT_TRANSPORT || "missing-transport");
}
if (process.env.NESTED_CHILD) {
  const result = childProcess.spawnSync(process.execPath, [process.env.NESTED_CHILD], {
    cwd: process.cwd(),
    env: {
      ...process.env,
      NESTED_CHILD: "",
      NESTED_MARKER: "",
      SLOT_MARKER: process.env.NESTED_MARKER || "",
    },
    stdio: "inherit",
  });
  process.exitCode = result.status ?? 74;
} else if (process.env.SLOT_DRIVER) {
  const driver = process.env.SLOT_DRIVER;
  fs.writeFileSync(path.join(driver, "ready.json"), JSON.stringify({
    pid: process.pid,
    token: process.env.CHASE_SETS_HEAVY_SLOT_ID || null,
    transport: process.env.CHASE_SETS_HEAVY_SLOT_TRANSPORT || null,
    acquireMs,
  }));
  const done = new Set();
  const timer = setInterval(() => {
    if (fs.existsSync(path.join(driver, "stop"))) {
      clearInterval(timer);
      process.exit(0);
    }
    for (const name of fs.readdirSync(driver).filter((entry) => entry.endsWith(".cmd.json")).sort()) {
      if (done.has(name)) continue;
      done.add(name);
      const spec = JSON.parse(fs.readFileSync(path.join(driver, name), "utf8"));
      const env = { ...process.env };
      for (const [key, value] of Object.entries(spec.env || {})) {
        if (value === null) delete env[key];
        else env[key] = String(value);
      }
      const started = Date.now();
      const result = childProcess.spawnSync(spec.executable || process.execPath,
        [...(spec.executable ? [] : [path.join(__dirname, spec.file || `${spec.script}.cjs`)]), ...(spec.args || [])], {
        cwd: process.cwd(),
        env,
        encoding: "utf8",
        timeout: 60000,
      });
      const temporary = path.join(driver, name.replace(".cmd.json", ".result.tmp"));
      fs.writeFileSync(temporary, JSON.stringify({
        id: spec.id,
        status: result.status,
        pid: result.pid,
        signal: result.signal,
        ms: Date.now() - started,
        stdout: result.stdout,
        stderr: result.stderr,
      }));
      fs.renameSync(temporary, path.join(driver, name.replace(".cmd.json", ".result.json")));
    }
  }, 20);
} else if (process.env.SLOT_RELEASE) {
  const timer = setInterval(() => {
    if (fs.existsSync(process.env.SLOT_RELEASE)) {
      clearInterval(timer);
      process.exit(0);
    }
  }, 20);
} else {
  setTimeout(() => process.exit(0), Number(process.env.SLOT_DELAY_MS || 0));
}
'@
if ($Baseline) {
  $fixtureSource = $fixtureSource.Replace('acquireHeavySlot("script-battery");', "")
}
[IO.File]::WriteAllText($fixture, $fixtureSource, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($childFixture, @'
const childProcess = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const acquireHeavySlot = require(path.join(__dirname, "..", "..", ".orchestrator", "heavy-slot.cjs"));
const started = Date.now();
acquireHeavySlot(process.env.SLOT_KIND || "script-battery");
if (process.env.SLOT_REPEAT === "2") acquireHeavySlot(process.env.SLOT_KIND || "script-battery");
const ms = Date.now() - started;
if (process.env.SLOT_MARKER) {
  fs.writeFileSync(process.env.SLOT_MARKER, process.env.CHASE_SETS_HEAVY_SLOT_ID || "missing-token");
}
let deeper = null;
if (process.env.SLOT_DEEPER === "1") {
  const result = childProcess.spawnSync(process.execPath, [process.env.SLOT_DEEPER_SCRIPT ? path.join(__dirname, process.env.SLOT_DEEPER_SCRIPT) : __filename, "test"], {
    cwd: process.cwd(),
    env: { ...process.env, SLOT_DEEPER: "", SLOT_KIND: process.env.SLOT_DEEPER_KIND || process.env.SLOT_KIND, SLOT_MARKER: process.env.SLOT_DEEPER_MARKER || "" },
    encoding: "utf8",
  });
  deeper = { status: result.status, stdout: result.stdout, stderr: result.stderr };
  if (result.status !== 0) process.exitCode = result.status ?? 74;
}
process.stdout.write(JSON.stringify({ pid: process.pid, ms, deeper, bodyCounter: 1 }));
'@, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($passiveFixture, @'
const fs = require("node:fs");
fs.writeFileSync(process.env.SLOT_MARKER, String(process.pid));
setInterval(() => {}, 1000);
'@, [Text.UTF8Encoding]::new($false))
# Raw pipe client: sends exactly the bytes the test composes (one field varied,
# every other field canonical) and reports the reply without interpreting it.
[IO.File]::WriteAllText($rawClientFixture, @'
const net = require("node:net");
const pipeName = `\\\\.\\pipe\\chase-sets-heavy-${process.env.RAW_PIPE_LOCK || process.env.CHASE_SETS_HEAVY_SLOT_ID}`;
const mode = process.env.RAW_MODE || "request";
function finish(result) {
  process.stdout.write(JSON.stringify(result));
  process.exit(0);
}
function requestBytes() {
  if (mode === "oversized") return Buffer.from(`{"schemaVersion":1,"pad":"${"a".repeat(17000)}"}\n`);
  if (mode === "invalid-json") return Buffer.from("{not json\n");
  const request = JSON.parse(process.env.RAW_REQUEST);
  for (const key of Object.keys(request)) {
    if (request[key] === "$SELF_PID") request[key] = process.pid;
  }
  const line = JSON.stringify(request);
  if (mode === "duplicate") return Buffer.from(`${line.slice(0, -1)},"schemaVersion":1}\n`);
  return Buffer.from(mode === "no-newline" ? line : `${line}\n`);
}
const socket = net.connect({ path: pipeName });
let reply = Buffer.alloc(0);
socket.setTimeout(8000);
socket.on("connect", () => {
  if (mode === "connect-only") {
    finish({ connected: true, pid: process.pid });
    return;
  }
  socket.write(requestBytes());
  if (mode === "no-newline") socket.end();
});
socket.on("data", (chunk) => {
  reply = Buffer.concat([reply, chunk]);
  if (reply.includes(0x0a)) {
    finish({ reply: reply.toString("utf8").split("\n")[0], pid: process.pid });
  }
});
socket.on("timeout", () => finish({ error: "timeout", pid: process.pid }));
socket.on("error", (error) => finish({ error: error.code || error.message, pid: process.pid }));
socket.on("close", () => finish({ error: "closed", reply: reply.toString("utf8"), pid: process.pid }));
'@, [Text.UTF8Encoding]::new($false))
# Borrowed client handle: the parent opens the connection, then hands the
# connected socket to a child which sends a canonical request naming itself.
[IO.File]::WriteAllText($borrowParentFixture, @'
const childProcess = require("node:child_process");
const net = require("node:net");
const path = require("node:path");
const pipeName = `\\\\.\\pipe\\chase-sets-heavy-${process.env.CHASE_SETS_HEAVY_SLOT_ID}`;
function ownRequest(callback) {
  const socket = net.connect({ path: pipeName });
  let reply = "";
  socket.on("connect", () => {
    const request = JSON.parse(process.env.RAW_REQUEST);
    for (const key of Object.keys(request)) if (request[key] === "$SELF_PID") request[key] = process.pid;
    socket.write(`${JSON.stringify(request)}\n`);
  });
  socket.on("data", (chunk) => {
    reply += chunk.toString("utf8");
    if (reply.includes("\n")) { socket.destroy(); callback(reply.split("\n")[0]); }
  });
  socket.on("error", (error) => callback(`error:${error.code}`));
}
ownRequest((controlReply) => {
  const socket = net.connect({ path: pipeName });
  socket.on("connect", () => {
    let stdout = "";
    const child = childProcess.spawn(process.execPath, [path.join(__dirname, "borrow-child.cjs")], {
      env: process.env,
      stdio: ["ignore", "pipe", "inherit", socket],
    });
    child.stdout.on("data", (chunk) => { stdout += chunk.toString("utf8"); });
    child.on("exit", () => {
      socket.destroy();
      process.stdout.write(JSON.stringify({ parentPid: process.pid, controlReply, borrowed: stdout.trim() }));
      process.exit(0);
    });
  });
  socket.on("error", (error) => {
    process.stdout.write(JSON.stringify({ parentPid: process.pid, controlReply, borrowed: `error:${error.code}` }));
    process.exit(0);
  });
});
'@, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($borrowChildFixture, @'
const net = require("node:net");
const socket = new net.Socket({ fd: 3, readable: true, writable: true });
const request = JSON.parse(process.env.RAW_REQUEST);
for (const key of Object.keys(request)) if (request[key] === "$SELF_PID") request[key] = process.pid;
let reply = "";
socket.on("data", (chunk) => {
  reply += chunk.toString("utf8");
  if (reply.includes("\n")) {
    process.stdout.write(JSON.stringify({ childPid: process.pid, reply: reply.split("\n")[0] }));
    socket.destroy();
    process.exit(0);
  }
});
socket.on("error", (error) => {
  process.stdout.write(JSON.stringify({ childPid: process.pid, error: error.code || error.message }));
  process.exit(0);
});
socket.write(`${JSON.stringify(request)}\n`);
'@, [Text.UTF8Encoding]::new($false))
Copy-Item -LiteralPath $fixture -Destination (Join-Path $worktree "scripts/pnpm.cjs")
New-Item -ItemType Directory -Path (Join-Path $worktree "scripts/filtered") | Out-Null
foreach ($extension in @("cjs", "js", "mjs")) {
  $inertBody = if ($extension -ceq "mjs") { 'import "../child.cjs";' } else { 'require("../child.cjs");' }
  [IO.File]::WriteAllText((Join-Path $worktree "scripts/filtered/pnpm.$extension"), $inertBody, [Text.UTF8Encoding]::new($false))
}
$nativeCapture = Join-Path $worktree "scripts/native-capture.cjs"
[IO.File]::WriteAllText($nativeCapture, @'
const argv = [...process.argv];
const admission = require(process.env.SLOT_NATIVE_PRELOAD);
process.stdout.write(JSON.stringify({argv, kind: admission.classifyCommand(argv, {packageScripts: {}, execArgv: process.execArgv}),
  token: process.env.CHASE_SETS_HEAVY_SLOT_ID, bodyCounter: 1}));
process.exit(0);
'@, [Text.UTF8Encoding]::new($false))
Copy-Item -LiteralPath $childFixture -Destination (Join-Path $worktree "scripts/playwright.js")
[IO.File]::WriteAllText((Join-Path $worktree "scripts/run-e2e-suite.mjs"), 'import "./fixture.cjs";', [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $worktree "scripts/run-workspaces.mjs"), 'import "./child.cjs";', [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $worktree "package.json"), '{"name":"heavy-slot-fixture","private":true,"scripts":{"test:e2e:suite":"node ./scripts/run-e2e-suite.mjs","suite:alias":"pnpm run suite:direct","suite:direct":"node ./scripts/run-e2e-suite.mjs"}}', [Text.UTF8Encoding]::new($false))
Invoke-FixtureGit @("init", "--initial-branch=codex/heavy-slot-fixture") | Out-Null
Invoke-FixtureGit @("config", "user.name", "Heavy Slot Test") | Out-Null
Invoke-FixtureGit @("config", "user.email", "heavy-slot-test@example.invalid") | Out-Null
Invoke-FixtureGit @("add", "--", "package.json", "scripts") | Out-Null
Invoke-FixtureGit @("commit", "-m", "heavy slot fixture") | Out-Null
$fixtureHead = (Invoke-FixtureGit @("rev-parse", "HEAD")).ToLowerInvariant()
[IO.File]::WriteAllText((Join-Path $secondWorktree "package.json"), '{"name":"heavy-slot-second","private":true}', [Text.UTF8Encoding]::new($false))
Invoke-FixtureGit @("init", "--initial-branch=codex/heavy-slot-second") $secondWorktree | Out-Null
Invoke-FixtureGit @("config", "user.name", "Heavy Slot Test") $secondWorktree | Out-Null
Invoke-FixtureGit @("config", "user.email", "heavy-slot-test@example.invalid") $secondWorktree | Out-Null
Invoke-FixtureGit @("add", "--", "package.json") $secondWorktree | Out-Null
Invoke-FixtureGit @("commit", "-m", "second fixture") $secondWorktree | Out-Null
$secondHead = (Invoke-FixtureGit @("rev-parse", "HEAD") $secondWorktree).ToLowerInvariant()

# Frozen gate/kind closure under test (mirrors invoke-heavy-verifier.ps1).
$expectedKindClosure = [ordered]@{
  "test:scripts" = @("script-battery", "vitest-full")
  "build" = @("build")
  "verify:build" = @("build")
  "check:static" = @("repository-gate", "script-battery", "vitest-full")
  "verify:test" = @("repository-gate", "script-battery", "vitest-full")
  "test" = @("repository-gate", "script-battery", "vitest-full")
  "test:fast" = @("repository-gate", "script-battery", "vitest-full")
  "verify:test-db" = @("repository-gate", "script-battery", "vitest-full")
  "verify:static" = @("repository-gate", "script-battery", "vitest-full")
  "verify" = @("repository-gate", "script-battery", "vitest-full", "build")
  "repository-gate" = @("repository-gate", "script-battery", "vitest-full", "build")
  "script-battery" = @("script-battery", "vitest-full")
  "vitest-full" = @("vitest-full", "script-battery")
  "playwright" = @("playwright", "script-battery", "build")
}
$allKinds = @("repository-gate", "playwright", "vitest-full", "script-battery", "build")

try {
  $fixtureStage = "initial-boundary"
  Assert-DisposableRoot
  Assert-FreshChildEnvironmentBoundary
  if ($LauncherNonReentryOnly) {
    $fixtureStage = "launcher-non-reentry"
    Test-LauncherNonReentry
    return
  }
  if ($CensusOnly -or (-not $CurrentBindingOnly -and -not $IdentityOnly -and -not $Baseline -and -not $NestedOnly -and -not $NestedSmoke)) {
    $fixtureStage = "census-lifecycle"
    Invoke-CensusControls
    if ($CensusOnly) { return }
  }
  if ($CurrentBindingOnly -or (-not $IdentityOnly -and -not $Baseline -and -not $NestedOnly -and -not $NestedSmoke)) {
    $fixtureStage = "current-canonical-binding"
    Test-DeniedRoleClients
    Invoke-CurrentBindingControls
    if ($CurrentBindingOnly) { return }
  }
  if ($IdentityOnly -or (-not $NestedOnly -and -not $NestedSmoke -and -not $Baseline)) {
    $fixtureStage = "detached-branch-protocol"
    Invoke-FixtureGit @("checkout", "--detach", $fixtureHead) | Out-Null
    $dispatchRecord = Write-DispatchOwnership -LaneRole implementation -ImmutableHead
    foreach ($launchMode in @("attached", "started")) {
      $identityHolder = if ($launchMode -ceq "attached") { Start-DriverHolder } else {
        Start-GateDriverHolder "test:scripts" -ImmutableHead
      }
      Assert-True ($identityHolder.Owner.identityMode -ceq "immutable-head" -and
        $null -eq $identityHolder.Owner.branch -and $identityHolder.Owner.head -ceq $fixtureHead) "detached $launchMode owner preserves literal null and exact HEAD"
      $identityChild = Invoke-NestedChild $identityHolder "$launchMode-detached-child"
      $identityDeep = Invoke-NestedChild $identityHolder "$launchMode-detached-deeper" -Deeper
      Assert-True ($identityChild.status -eq 0 -and $identityChild.stdout -match '"bodyCounter":1' -and
        $identityDeep.status -eq 0 -and ($identityDeep.stdout | ConvertFrom-Json).deeper.status -eq 0) "detached $launchMode real child/deeper bodies execute"
      foreach ($badBranch in @("", "codex/heavy-slot-fixture")) {
        $badRequest = New-CanonicalRequest $identityHolder @{ branch = $badBranch }
        $reply = Invoke-RawRequest $identityHolder "$launchMode-branch-$($badBranch.Length)" $badRequest
        Assert-True (-not (Test-RawAccepted $reply) -and $reply.reply -match "branch|identityMode|required field|admitted mode") "detached request rejects non-null branch '$badBranch'"
        $badOwner = $identityHolder.OwnerRaw | ConvertFrom-Json -AsHashtable -DateKind String
        $badOwner.branch = $badBranch
        Write-OwnerRaw ($badOwner | ConvertTo-Json -Compress -Depth 5)
        $refused = Invoke-NestedChild $identityHolder "$launchMode-owner-branch-$($badBranch.Length)"
        Write-OwnerRaw $identityHolder.OwnerRaw
        Assert-True ($refused.status -eq 73 -and $refused.stdout -notmatch '"bodyCounter":1' -and
          $refused.stderr -match "identity fields are malformed") "malformed detached owner refuses 73/body0"
      }
      foreach ($malformed in @(@{ "-branch" = $null }, @{ identityMode = "branch" })) {
        $reply = Invoke-RawRequest $identityHolder ("$launchMode-malformed-" + [guid]::NewGuid().ToString("N")) (New-CanonicalRequest $identityHolder $malformed)
        Assert-True (-not (Test-RawAccepted $reply) -and $reply.reply -match "branch|identityMode|required field|admitted mode") "detached request rejects missing branch or crossed mode"
      }
      Invoke-FixtureGit @("checkout", "codex/heavy-slot-fixture") | Out-Null
      $reattached = Invoke-NestedChild $identityHolder "$launchMode-reattached"
      Assert-True ($reattached.status -eq 73 -and $reattached.stdout -notmatch '"bodyCounter":1') "immutable admission rejects live branch attachment at same HEAD"
      Invoke-FixtureGit @("checkout", "--detach", $fixtureHead) | Out-Null
      $restored = Invoke-NestedChild $identityHolder "$launchMode-restored"
      Assert-True ($restored.status -eq 0 -and $restored.stdout -match '"bodyCounter":1') "restored detached identity admits again"
      Stop-DriverHolder $identityHolder | Out-Null
    }
    Remove-DispatchOwnership $dispatchRecord
    Invoke-FixtureGit @("checkout", "codex/heavy-slot-fixture") | Out-Null
    $dispatchRecord = Write-DispatchOwnership
    $branchHolder = Start-DriverHolder
    $branchChild = Invoke-NestedChild $branchHolder "branch-positive"
    Assert-True ($branchChild.status -eq 0 -and $branchChild.stdout -match '"bodyCounter":1') "branch identity still admits"
    foreach ($badBranch in @($null, "", "codex/other")) {
      $reply = Invoke-RawRequest $branchHolder ("branch-malformed-" + [guid]::NewGuid().ToString("N")) (New-CanonicalRequest $branchHolder @{ branch = $badBranch })
      Assert-True (-not (Test-RawAccepted $reply) -and $reply.reply -match "branch|identityMode|required field|admitted mode") "branch request rejects null, empty, or crossed branch"
    }
    Invoke-FixtureGit @("checkout", "--detach", $fixtureHead) | Out-Null
    $detached = Invoke-NestedChild $branchHolder "branch-became-detached"
    Assert-True ($detached.status -eq 73 -and $detached.stdout -notmatch '"bodyCounter":1') "branch admission rejects same-head detachment"
    Invoke-FixtureGit @("checkout", "codex/heavy-slot-fixture") | Out-Null
    Stop-DriverHolder $branchHolder | Out-Null
    Remove-DispatchOwnership $dispatchRecord
    Write-Output "PASS detached/branch protocol: attached and started roots, real descendants, malformed/null/empty/crossed fields, same-head Git transitions"
    if ($IdentityOnly) { return }
  }
  $dispatchRecord = Write-DispatchOwnership

  if ($FilteredTestOnly -or (-not $NestedOnly -and -not $NestedSmoke -and -not $Baseline)) {
    $fixtureStage = "filtered-workspace-test"
    Invoke-FilteredTestControls
    if ($FilteredTestOnly) { return }
  }

  if ($BrowserOnly -or $BrowserBaseline -or (-not $NestedOnly -and -not $NestedSmoke -and -not $Baseline)) {
    $fixtureStage = "registered-browser-admission"
    Invoke-BrowserAdmissionControls
    if ($BrowserOnly -or $BrowserBaseline) { return }
  }

  if ($NestedSmoke) {
    $smoke = Start-GateDriverHolder "test:scripts"
    $smokeChild = Invoke-NestedChild $smoke "smoke-child"
    $smokeOutput = Stop-DriverHolder $smoke
    Write-Output ($smokeChild | ConvertTo-Json -Compress -Depth 5)
    Write-Output $smokeOutput.stderr
    Assert-True ($smokeChild.status -eq 0) "smoke real descendant accepts"
    return
  }

  if (-not $NestedOnly) {
  if ($Baseline) {
    New-Item -ItemType Directory -Path $lock | Out-Null
    $baselineOwnerRaw = '{"sentinel":"test-local-owner"}'
    [IO.File]::WriteAllText($ownerPath, $baselineOwnerRaw, [Text.UTF8Encoding]::new($false))

    $baselineNc1Marker = Join-Path $root "baseline-nc1.marker"
    $baselineNc1 = Start-Fixture -ExtraEnvironment @{ SLOT_MARKER = $baselineNc1Marker }
    Complete-Fixture $baselineNc1 0 "baseline NC1" | Out-Null
    Assert-True (Test-Path -LiteralPath $baselineNc1Marker) "baseline NC1 body executes"

    $fixtureRelative = "scripts\fixture.cjs"
    foreach ($control in @(
        [pscustomobject]@{ Name = "redirection"; Command = "node $fixtureRelative>$root\baseline-nc2.out" },
        [pscustomobject]@{ Name = "background"; Command = "node $fixtureRelative&exit /b !errorlevel!" },
        [pscustomobject]@{ Name = "grouping"; Command = "(node $fixtureRelative)" }
      )) {
      $marker = Join-Path $root "baseline-nc2-$($control.Name).marker"
      $entry = Start-CmdFixture $control.Command @{ SLOT_MARKER = $marker }
      Complete-Fixture $entry 0 "baseline NC2 $($control.Name)" | Out-Null
      Assert-True (Test-Path -LiteralPath $marker) "baseline NC2 $($control.Name) body executes"
    }

    $baselineNc3Marker = Join-Path $root "baseline-nc3.marker"
    $baselineNc3Exit = Join-Path $root "baseline-nc3.exit"
    $baselineNc3 = Start-CmdFixture "set NODE_OPTIONS=&&node inspect $fixtureRelative" @{
      SLOT_MARKER = $baselineNc3Marker
      SLOT_EXIT_MARKER = $baselineNc3Exit
    } -Inspector
    Complete-Fixture $baselineNc3 0 "baseline NC3 inspector wrapper" | Out-Null
    Assert-True (Test-Path -LiteralPath $baselineNc3Marker) "baseline NC3 body executes"
    Assert-True ((Get-Content -LiteralPath $baselineNc3Exit -Raw) -ceq "0") "baseline NC3 guarded fixture exits 0"
    Assert-True ((Get-Content -LiteralPath $ownerPath -Raw) -ceq $baselineOwnerRaw) "baseline controls leave the test-local owner byte-exact"
    Write-Output "RED heavy slot baseline: NC1 body executed; NC2 3/3 bodies executed; NC3 body executed"
    return
  }

  # Missing and unsafe launchers fail before the guarded body or lock creation.
  $fixtureStage = "launcher-refusal"
  Remove-Item -LiteralPath $launcher -Force
  $missingLauncherMarker = Join-Path $root "missing-launcher.marker"
  $missingLauncher = Start-Fixture -ExtraEnvironment @{ SLOT_MARKER = $missingLauncherMarker }
  $missingLauncherOutput = Complete-Fixture $missingLauncher 73 "missing holder launcher"
  Assert-True ($missingLauncherOutput.stderr -match "command body was not executed" -and
    -not (Test-Path -LiteralPath $missingLauncherMarker) -and
    -not (Test-Path -LiteralPath $lock)) "missing launcher refuses before body and lock creation"
  New-Item -ItemType Directory -Path $launcher | Out-Null
  $unsafeLauncherMarker = Join-Path $root "unsafe-launcher.marker"
  $unsafeLauncher = Start-Fixture -ExtraEnvironment @{ SLOT_MARKER = $unsafeLauncherMarker }
  $unsafeLauncherOutput = Complete-Fixture $unsafeLauncher 73 "unsafe holder launcher"
  Assert-True ($unsafeLauncherOutput.stderr -match "command body was not executed" -and
    -not (Test-Path -LiteralPath $unsafeLauncherMarker) -and
    -not (Test-Path -LiteralPath $lock)) "unsafe launcher refuses before body and lock creation"
  Remove-Item -LiteralPath $launcher -Force
  Copy-Item -LiteralPath $launcherSource -Destination $launcher
  Write-Output "PASS missing and unsafe holder launcher refuse before body execution"

  # The nested-owner runtime is part of the wrapper: a missing source refuses
  # the attached admission before any body runs and creates no lock.
  $fixtureStage = "nested-runtime-refusal"
  Remove-Item -LiteralPath $nestedOwner -Force
  $missingRuntimeMarker = Join-Path $root "missing-nested-runtime.marker"
  $missingRuntime = Start-Fixture -ExtraEnvironment @{ SLOT_MARKER = $missingRuntimeMarker }
  $missingRuntimeOutput = Complete-Fixture $missingRuntime 73 "missing nested-owner runtime"
  Assert-True ($missingRuntimeOutput.stderr -match "nested continuation runtime is absent or unsafe" -and
    -not (Test-Path -LiteralPath $missingRuntimeMarker)) "missing nested-owner source refuses before body"
  Wait-Condition { -not (Test-Path -LiteralPath $lock) } "missing nested-owner runtime leaves no lock"
  Copy-Item -LiteralPath $nestedOwnerSource -Destination $nestedOwner
  Write-Output "PASS missing nested-owner runtime refuses attached admission before body"

  # AC2: an artifact with no preload acquires and publishes its inherited token
  # and the attached-result transport descriptor.
  $fixtureStage = "artifact-owned-acquirer"
  $acquireMarker = Join-Path $root "acquire.marker"
  $acquireTransportMarker = Join-Path $root "acquire-transport.marker"
  $acquireRelease = Join-Path $root "acquire.release"
  $acquirer = Start-Fixture -ExtraEnvironment @{
    SLOT_MARKER = $acquireMarker
    SLOT_TRANSPORT_MARKER = $acquireTransportMarker
    SLOT_RELEASE = $acquireRelease
  }
  Wait-Condition { $record = Read-Owner; $record -and $record.gate -ceq "script-battery" } "artifact-owned acquisition" 1200
  $acquiredOwner = Read-Owner
  $acquiredHolderIdentity = [pscustomobject]@{
    pid = $acquiredOwner.pid
    processStartUtc = $acquiredOwner.processStartUtc
  }
  Wait-Condition { Test-Path -LiteralPath $acquireMarker -PathType Leaf } "artifact body marker" 1200
  Assert-True ((Get-Content -LiteralPath $acquireMarker -Raw) -ceq $acquiredOwner.lockId) "Attach path publishes the exact owner lockId"
  $acquiredTransport = Get-Content -LiteralPath $acquireTransportMarker -Raw
  $acquiredDescriptor = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($acquiredTransport)) | ConvertFrom-Json
  Assert-True ($acquiredDescriptor.schemaVersion -eq 1 -and $acquiredDescriptor.lockId -ceq $acquiredOwner.lockId -and
    @($acquiredDescriptor.PSObject.Properties.Name).Count -eq 5 -and $acquiredDescriptor.publicKey -match '^[A-Za-z0-9+/=]+$') `
    "Attach path publishes the closed transport descriptor for the exact owner"
  $directChildren = @(Get-CimInstance Win32_Process -ErrorAction Stop |
    Where-Object { [int]$_.ParentProcessId -eq $acquirer.Process.Id })
  $launcherChildren = @($directChildren | Where-Object {
      [string]$_.Name -like "node*" -and
      [string]$_.CommandLine -like "*heavy-admission-holder-launcher.cjs*"
    })
  $directPowerShellChildren = @($directChildren | Where-Object { [string]$_.Name -like "pwsh*" })
  Assert-True ($launcherChildren.Count -eq 1) "holder launcher is the guarded Node's one direct Node launcher child"
  Assert-True ($directPowerShellChildren.Count -eq 0) "guarded Node has zero direct PowerShell holder children"
  Set-Content -LiteralPath $acquireRelease -Value "release"
  Complete-Fixture $acquirer 0 "artifact-owned acquirer" | Out-Null
  Assert-True (Test-ExactProcess $acquiredHolderIdentity) "attached admission holder outlives its guarded parent"
  Wait-Condition { -not (Test-Path -LiteralPath $lock) } "artifact-owned release" 1200
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $root "second-acquirer.marker"))) `
    "exact owner lock is physically removed without a second acquirer"
  Write-Output "PASS attached holder survival, one launcher child, zero direct pwsh children, transport descriptor, and physical exact-lock release"

  # The retired direct-holder shape is detected by its actual current
  # PowerShell topology, not by assuming whether Windows keeps that child alive
  # long enough to release its lock. Both lifetime outcomes have occurred on
  # supported PowerShell builds; neither weakens production exact-owner release.
  Set-HolderSpawnMutant $false
  $fixtureStage = "non-detached-mutant"
  $nonDetachedMarker = Join-Path $root "non-detached-mutant.marker"
  $nonDetachedRelease = Join-Path $root "non-detached-mutant.release"
  $nonDetached = Start-Fixture -ExtraEnvironment @{ SLOT_MARKER = $nonDetachedMarker; SLOT_RELEASE = $nonDetachedRelease }
  Wait-Condition { $record = Read-Owner; $record -and (Test-Path -LiteralPath $nonDetachedMarker) } `
    "non-detached predecessor acquisition" 1200
  $nonDetachedOwner = Read-Owner
  $nonDetachedHolderIdentity = [pscustomobject]@{
    pid = $nonDetachedOwner.pid
    processStartUtc = $nonDetachedOwner.processStartUtc
  }
  $mutantChildren = @(Get-CimInstance Win32_Process -ErrorAction Stop |
    Where-Object { [int]$_.ParentProcessId -eq $nonDetached.Process.Id })
  $mutantOwnerProcess = @(Get-CimInstance Win32_Process -Filter "ProcessId = $([int]$nonDetachedOwner.pid)" -ErrorAction Stop)
  Assert-True ($mutantOwnerProcess.Count -eq 1 -and [string]$mutantOwnerProcess[0].Name -like 'pwsh*' -and
    @($mutantChildren | Where-Object { [string]$_.Name -like 'node*' -and [string]$_.CommandLine -like '*heavy-admission-holder-launcher.cjs*' }).Count -eq 0) `
    "non-detached holder mutant was not detected at the changed process boundary"
  Set-Content -LiteralPath $nonDetachedRelease -Value 'release'
  Complete-Fixture $nonDetached 0 "non-detached holder mutant" | Out-Null
  Wait-Condition { -not (Test-ExactProcess $nonDetachedHolderIdentity) } "non-detached predecessor holder death" 1200
  $mutantLeftStaleLock = Test-Path -LiteralPath $lock -PathType Container
  Write-Output "PASS non-detached holder mutant detected by direct-pwsh topology staleLock=$mutantLeftStaleLock"

  # Restore production bytes and use the ordinary guarded recovery path solely
  # to drain the predecessor mutant's now-proven stale disposable lock.
  Copy-Item -LiteralPath $clientSource -Destination $client -Force
  if ($mutantLeftStaleLock) {
    $mutantRecoveryMarker = Join-Path $root "non-detached-mutant-recovery.marker"
    $mutantRecovery = Start-Fixture -ExtraEnvironment @{ SLOT_MARKER = $mutantRecoveryMarker }
    Complete-Fixture $mutantRecovery 0 "non-detached mutant stale recovery" | Out-Null
    Wait-Condition { -not (Test-Path -LiteralPath $lock) } "non-detached mutant recovery release" 1200
  }

  # The tempting direct detached-pwsh shape does not run on this host. If a
  # future host admits and releases it, the settled launcher design must be re-evaluated.
  Set-HolderSpawnMutant $true
  $fixtureStage = "detached-pwsh-mutant"
  $detachedPwshMarker = Join-Path $root "detached-pwsh-mutant.marker"
  $detachedPwsh = Start-Fixture -ExtraEnvironment @{ SLOT_MARKER = $detachedPwshMarker }
  $detachedCompleted = $detachedPwsh.Process.WaitForExit(30000)
  $detachedStderr = $detachedPwsh.Process.StandardError.ReadToEnd()
  $detachedStdout = $detachedPwsh.Process.StandardOutput.ReadToEnd()
  $detachedAchievedPhysicalRelease = $detachedCompleted -and
    $detachedPwsh.Process.ExitCode -eq 0 -and
    (Test-Path -LiteralPath $detachedPwshMarker) -and
    -not (Test-Path -LiteralPath $lock)
  Assert-True (-not $detachedAchievedPhysicalRelease) `
    "detached PowerShell holder achieved admission and physical release; re-evaluate the launcher design"
  Assert-True ($detachedCompleted -and $detachedPwsh.Process.ExitCode -eq 73 -and
    $detachedStderr -match "command body was not executed" -and
    -not (Test-Path -LiteralPath $detachedPwshMarker) -and
    -not (Test-Path -LiteralPath $lock)) `
    "detached PowerShell holder mutant fails closed (stderr=$detachedStderr; stdout=$detachedStdout)"
  Copy-Item -LiteralPath $clientSource -Destination $client -Force
  Write-Output "PASS detached PowerShell holder mutant does not achieve physical release"

  $fixtureStage = "launcher-non-reentry"
  Test-LauncherNonReentry
  }

  # Hold one exact test-local owner (a real driver root) for the NC1-NC4,
  # sibling, nested, writer-entry, record, and raw-protocol controls.
  if (-not $MeasurementsAndMutantsOnly) {
  $fixtureStage = "shared-holder-start"
  $holderMarker = Join-Path $root "holder.marker"
  $holder = Start-DriverHolder @{ SLOT_MARKER = $holderMarker }
  $holderOwner = $holder.Owner
  $holderRaw = $holder.OwnerRaw
  Assert-True ($holder.Ready.token -ceq $holderOwner.lockId -and -not [string]::IsNullOrEmpty($holder.Ready.transport)) "driver holder carries its token and descriptor"

  if (-not $NestedOnly) {
  if ($CleanupDiscriminator) {
    $fixtureStage = "refused-admission-cleanup-mutant"
    Set-RefusedCleanupMutant
    $mutantBodyMarker = Join-Path $root "refused-mutant-body.marker"
    $mutantBody = Start-Fixture -Script $passiveFixture -ExtraEnvironment @{ SLOT_MARKER = $mutantBodyMarker }
    Wait-Condition { Test-Path -LiteralPath $mutantBodyMarker -PathType Leaf } "mutant refused guarded body marker"
    $mutantRoot = Join-Path $privateTemp ("chase-sets-heavy-admission-mutant-" + [guid]::NewGuid().ToString("N"))
    $mutantHolder = Start-RefusedAttachedFixture $mutantBody.Identity $mutantRoot
    Wait-Condition { Test-Path -LiteralPath $mutantHolder.ResultPath -PathType Leaf } "mutant refused admission result" 1200
    $mutantResult = Get-Content -LiteralPath $mutantHolder.ResultPath -Raw | ConvertFrom-Json -DateKind String
    Assert-True ($mutantResult.accepted -eq $false -and $mutantResult.message -match "lock unavailable \(live-owner") `
      "refused-cleanup mutant reaches the real live-owner refusal"
    Assert-True (Test-ExactProcess $mutantBody.Identity) "mutant guarded body retains its exact kill identity"
    $mutantBody.Process.Kill($true)
    Assert-True ($mutantBody.Process.WaitForExit(5000) -and -not (Test-ExactProcess $mutantBody.Identity)) `
      "mutant guarded body reaches exact death"
    Complete-Fixture $mutantHolder 73 "refused-cleanup mutant holder" | Out-Null
    Assert-True (Test-Path -LiteralPath $mutantRoot -PathType Container) `
      "refused-cleanup mutant did not reproduce the exact admission-root residue"
    $mutantEntries = @(Get-ChildItem -LiteralPath $mutantRoot -Force -ErrorAction Stop)
    Assert-True ($mutantEntries.Count -eq 1 -and $mutantEntries[0].Name -ceq "result.json" -and
      -not $mutantEntries[0].PSIsContainer -and
      (($mutantEntries[0].Attributes -band [IO.FileAttributes]::ReparsePoint) -ne [IO.FileAttributes]::ReparsePoint)) `
      "refused-cleanup mutant root contains only its exact regular result"
    Remove-Item -LiteralPath $mutantRoot -Recurse -Force
    Copy-Item -LiteralPath $guardSource -Destination $guard -Force
    Write-Output "MUTANT refused admission exact-death cleanup predecessor=root-retained candidate-required=red"
  }

  # A refused admission publishes its result while the exact guarded body is
  # still alive. If that body is then hard-killed before consuming the result,
  # the refusing holder owns cleanup of only its exact admission root.
  $fixtureStage = "refused-admission-exact-death-cleanup"
  $refusedBodyMarker = Join-Path $root "refused-body.marker"
  $refusedBody = Start-Fixture -Script $passiveFixture -ExtraEnvironment @{ SLOT_MARKER = $refusedBodyMarker }
  Wait-Condition { Test-Path -LiteralPath $refusedBodyMarker -PathType Leaf } "refused guarded body marker"
  $refusedAdmissionRoot = Join-Path $privateTemp ("chase-sets-heavy-admission-refused-" + [guid]::NewGuid().ToString("N"))
  $refusedHolder = Start-RefusedAttachedFixture $refusedBody.Identity $refusedAdmissionRoot
  Wait-Condition { Test-Path -LiteralPath $refusedHolder.ResultPath -PathType Leaf } "refused admission result" 1200
  $refusedResult = Get-Content -LiteralPath $refusedHolder.ResultPath -Raw | ConvertFrom-Json -DateKind String
  Assert-True ($refusedResult.accepted -eq $false -and $refusedResult.message -match "lock unavailable \(live-owner") `
    "refused attached admission records the existing exact live owner"
  Assert-True ((Test-Path -LiteralPath $refusedAdmissionRoot -PathType Container) -and
    -not $refusedHolder.Process.HasExited) "refused admission root remains protected while the guarded body is live"
  Assert-True (Test-ExactProcess $refusedBody.Identity) "refused guarded body retains its exact kill identity"
  $refusedBody.Process.Kill($true)
  Assert-True ($refusedBody.Process.WaitForExit(5000) -and -not (Test-ExactProcess $refusedBody.Identity)) `
    "refused guarded body reaches exact death"
  $refusedHolderOutput = Complete-Fixture $refusedHolder 73 "refused admission cleanup holder"
  Assert-True ($refusedHolderOutput.stderr -match "lock unavailable \(live-owner" -and
    -not (Test-Path -LiteralPath $refusedAdmissionRoot)) `
    "refused holder removes only its exact root after guarded-tree death"
  Write-Output "CONTROL refused admission exact-death cleanup root=removed live=retained owner=unrelated-live"

  $nc1Marker = Join-Path $root "nc1.marker"
  $fixtureStage = "nc1"
  $nc1 = Start-Fixture -ExtraEnvironment @{ SLOT_MARKER = $nc1Marker }
  $nc1Output = Complete-Fixture $nc1 73 "NC1 preload-erased fixture"
  Assert-True (-not (Test-Path -LiteralPath $nc1Marker)) "NC1 body does not execute"
  Assert-True ($nc1Output.stderr -match "command body was not executed") "NC1 refusal is explicit"

  $fixtureRelative = "scripts\fixture.cjs"
  foreach ($control in @(
      [pscustomobject]@{ Name = "redirection"; Command = "node $fixtureRelative>$root\nc2.out" },
      [pscustomobject]@{ Name = "background"; Command = "node $fixtureRelative&exit /b !errorlevel!" },
      [pscustomobject]@{ Name = "grouping"; Command = "(node $fixtureRelative)" }
    )) {
    $fixtureStage = "nc2-$($control.Name)"
    $marker = Join-Path $root "nc2-$($control.Name).marker"
    $entry = Start-CmdFixture $control.Command @{ SLOT_MARKER = $marker }
    Complete-Fixture $entry 73 "NC2 $($control.Name)" | Out-Null
    Assert-True (-not (Test-Path -LiteralPath $marker)) "NC2 $($control.Name) body does not execute"
  }

  $nc3Marker = Join-Path $root "nc3.marker"
  $fixtureStage = "nc3-inspector"
  $nc3ExitMarker = Join-Path $root "nc3.exit"
  $nc3 = Start-CmdFixture "set NODE_OPTIONS=&&node inspect $fixtureRelative" @{
    SLOT_MARKER = $nc3Marker
    SLOT_EXIT_MARKER = $nc3ExitMarker
  } -Inspector
  $nc3Output = Complete-Fixture $nc3 0 "NC3 inspector wrapper"
  Assert-True ($nc3.GuardedProcess.WaitForExit(5000)) "NC3 guarded fixture exits"
  Assert-True ((Get-Content -LiteralPath $nc3ExitMarker -Raw) -ceq "73") "NC3 guarded fixture exit code is 73"
  Assert-True (-not (Test-Path -LiteralPath $nc3Marker)) "NC3 body does not execute"
  Assert-True (($nc3Output.stdout + $nc3Output.stderr) -match "command body was not executed") "NC3 refusal is explicit"

  $nc4Marker = Join-Path $root "nc4.marker"
  $fixtureStage = "nc4-forged-token"
  $nc4 = Start-Fixture -ExtraEnvironment @{
    SLOT_MARKER = $nc4Marker
    CHASE_SETS_HEAVY_SLOT_ID = "0123456789abcdef0123456789abcdef"
  }
  $nc4Output = Complete-Fixture $nc4 73 "NC4 forged token"
  Assert-True (-not (Test-Path -LiteralPath $nc4Marker) -and $nc4Output.stderr -match "command body was not executed") "NC4 forged token does not admit"
  }

  # AC2: the same valid token and descriptor in a process that is not a live
  # descendant of the guarded root is refused by actual ancestry, not by token.
  $fixtureStage = "sibling-valid-token"
  $siblingMarker = Join-Path $root "sibling.marker"
  $sibling = Start-Fixture -Script $childFixture -ExtraEnvironment @{
    SLOT_MARKER = $siblingMarker
    CHASE_SETS_HEAVY_SLOT_ID = $holderOwner.lockId
    CHASE_SETS_HEAVY_SLOT_TRANSPORT = $holder.Ready.transport
  }
  $siblingOutput = Complete-Fixture $sibling 73 "sibling with the valid token and descriptor"
  Assert-True (-not (Test-Path -LiteralPath $siblingMarker) -and
    $siblingOutput.stderr -match "not a live descendant of the guarded root") "same-valid-token sibling is refused by ancestry (stderr=$($siblingOutput.stderr))"
  $borrowedMarker = Join-Path $root "borrowed-token.marker"
  $borrowed = Start-Fixture -Script $childFixture -ExtraEnvironment @{
    SLOT_MARKER = $borrowedMarker
    CHASE_SETS_HEAVY_SLOT_ID = $holderOwner.lockId
  }
  $borrowedOutput = Complete-Fixture $borrowed 73 "borrowed token without descriptor"
  Assert-True (-not (Test-Path -LiteralPath $borrowedMarker) -and
    $borrowedOutput.stderr -match "transport descriptor is missing") "token without descriptor refuses and never falls through to a new holder"
  Assert-True ((Read-OwnerRaw) -ceq $holderRaw) "sibling and borrowed-token refusals leave the owner byte-exact"
  Write-Output "PASS same-valid-token sibling and descriptor-less borrowed token refuse 73 with no body"

  # AC1: a real descendant and a real deeper descendant accept with no host spawn.
  $fixtureStage = "nested-descendants"
  $childMarker = Join-Path $root "nested-child.marker"
  $deeperMarker = Join-Path $root "nested-deeper.marker"
  $nestedChild = Invoke-NestedChild $holder "positive-child" @{ SLOT_MARKER = $childMarker }
  Assert-True ($nestedChild.status -eq 0 -and (Get-Content -LiteralPath $childMarker -Raw) -ceq $holderOwner.lockId) `
    "live descendant accepts through the nested owner (stderr=$($nestedChild.stderr))"
  $nestedDeeper = Invoke-NestedChild $holder "positive-deeper" @{ SLOT_MARKER = $childMarker; SLOT_DEEPER_MARKER = $deeperMarker } -Deeper
  $deeperDetail = $nestedDeeper.stdout | ConvertFrom-Json
  Assert-True ($nestedDeeper.status -eq 0 -and $deeperDetail.deeper.status -eq 0 -and
    (Get-Content -LiteralPath $deeperMarker -Raw) -ceq $holderOwner.lockId) `
    "deeper descendant accepts through the nested owner (stderr=$($nestedDeeper.stderr))"
  foreach ($crossed in @("build", "playwright", "repository-gate")) {
    $crossedMarker = Join-Path $root "crossed-$crossed.marker"
    $crossedResult = Invoke-NestedChild $holder "crossed-$crossed" @{ SLOT_MARKER = $crossedMarker; SLOT_KIND = $crossed }
    Assert-True ($crossedResult.status -eq 73 -and -not (Test-Path -LiteralPath $crossedMarker) -and
      $crossedResult.stderr -match "is not admitted under gate script-battery") "crossed kind $crossed under a script-battery root refuses 73"
  }
  $allowedVitest = Invoke-NestedChild $holder "allowed-vitest-full" @{ SLOT_KIND = "vitest-full" }
  Assert-True ($allowedVitest.status -eq 0) "vitest-full descendant of a script-battery root accepts (stderr=$($allowedVitest.stderr))"
  Write-Output "PASS real descendant, deeper descendant, and allowed vitest-full accept; crossed kinds refuse"

  # Descriptor tampering: the descriptor is transport only. A substituted key
  # cannot verify the wrapper's signature; a foreign lockId or malformed
  # descriptor refuses before any exchange.
  $fixtureStage = "descriptor-tampering"
  $foreignKey = New-ForeignPublicKey
  $substituted = Invoke-NestedChild $holder "key-substituted" @{
    CHASE_SETS_HEAVY_SLOT_TRANSPORT = (New-TamperedTransport $holder.Ready.transport @{ publicKey = $foreignKey })
  }
  Assert-True ($substituted.status -eq 73 -and $substituted.stderr -match "signature did not verify") "key-substituted descriptor refuses 73"
  $foreignLock = Invoke-NestedChild $holder "descriptor-foreign-lock" @{
    CHASE_SETS_HEAVY_SLOT_TRANSPORT = (New-TamperedTransport $holder.Ready.transport @{ lockId = "0123456789abcdef0123456789abcdef" })
  }
  Assert-True ($foreignLock.status -eq 73 -and $foreignLock.stderr -match "names a different owner") "descriptor naming another owner refuses 73"
  $extraDescriptor = Invoke-NestedChild $holder "descriptor-extra-field" @{
    CHASE_SETS_HEAVY_SLOT_TRANSPORT = (New-TamperedTransport $holder.Ready.transport @{ extra = "field" })
  }
  Assert-True ($extraDescriptor.status -eq 73 -and $extraDescriptor.stderr -match "descriptor is not closed") "descriptor with an extra field refuses 73"
  $missingDescriptor = Invoke-NestedChild $holder "descriptor-missing" @{ CHASE_SETS_HEAVY_SLOT_TRANSPORT = $null }
  Assert-True ($missingDescriptor.status -eq 73 -and $missingDescriptor.stderr -match "descriptor is missing") "descendant without descriptor refuses 73"
  Write-Output "PASS descriptor key substitution, foreign lockId, extra field, and absence refuse 73"

  # Writer entries: one valid atomic transition beside an unchanged owner is
  # tolerated; every other entry shape refuses.
  $fixtureStage = "writer-entries"
  $transitionName = "owner.transition.$([guid]::NewGuid().ToString("N")).tmp"
  $transitionPath = Join-Path $lock $transitionName
  [IO.File]::WriteAllText($transitionPath, $holderRaw, [Text.UTF8Encoding]::new($false))
  $transitionChild = Invoke-NestedChild $holder "transition-tolerated"
  Assert-True ($transitionChild.status -eq 0) "valid writer transition beside the unchanged owner is tolerated (stderr=$($transitionChild.stderr))"
  Assert-True ((Get-Content -LiteralPath $transitionPath -Raw) -ceq $holderRaw) "nested path leaves the transition file byte-exact"
  [IO.File]::WriteAllText($transitionPath, '{"malformed":true}', [Text.UTF8Encoding]::new($false))
  $conflictingTransition = Invoke-NestedChild $holder "conflicting-transition"
  Assert-True ($conflictingTransition.status -eq 73 -and $conflictingTransition.stderr -match "transition conflicts") "malformed transition content refuses 73"
  [IO.File]::WriteAllText($transitionPath, $holderRaw, [Text.UTF8Encoding]::new($false))
  Remove-Item -LiteralPath $transitionPath -Force
  $lookalikeNames = @(
    "owner.transition.$([guid]::NewGuid().ToString("N").Substring(1)).tmp",
    "owner.transition.$([guid]::NewGuid().ToString("N").ToUpperInvariant()).tmp",
    "owner.transition.$([guid]::NewGuid().ToString("N")).tmp.bak",
    "owner-transition.$([guid]::NewGuid().ToString("N")).tmp",
    "unrelated.tmp"
  )
  $lookalikeIndex = 0
  foreach ($lookalikeName in $lookalikeNames) {
    $lookalikeIndex += 1
    $lookalikePath = Join-Path $lock $lookalikeName
    [IO.File]::WriteAllText($lookalikePath, $holderRaw, [Text.UTF8Encoding]::new($false))
    $lookalikeChild = Invoke-NestedChild $holder "lookalike-$lookalikeIndex"
    Assert-True ($lookalikeChild.status -eq 73 -and $lookalikeChild.stderr -match "writer entries are unknown") "unexpected lock entry '$lookalikeName' fails closed at the client"
    # The server refuses the same entry independently of the client check.
    $lookalikeRaw = Invoke-RawRequest $holder "lookalike-raw-$lookalikeIndex" (New-CanonicalRequest $holder)
    Assert-True (-not (Test-RawAccepted $lookalikeRaw) -and $lookalikeRaw.reply -match "unknown") "unexpected lock entry '$lookalikeName' fails closed at the server (reply=$($lookalikeRaw.reply))"
    Remove-Item -LiteralPath $lookalikePath -Force
  }
  $directoryTransition = Join-Path $lock "owner.transition.$([guid]::NewGuid().ToString("N")).tmp"
  New-Item -ItemType Directory -Path $directoryTransition | Out-Null
  $directoryChild = Invoke-NestedChild $holder "transition-directory"
  Assert-True ($directoryChild.status -eq 73) "transition-shaped non-file fails closed"
  Remove-Item -LiteralPath $directoryTransition -Force
  $firstTransition = Join-Path $lock "owner.transition.$([guid]::NewGuid().ToString("N")).tmp"
  $secondTransition = Join-Path $lock "owner.transition.$([guid]::NewGuid().ToString("N")).tmp"
  [IO.File]::WriteAllText($firstTransition, $holderRaw, [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText($secondTransition, $holderRaw, [Text.UTF8Encoding]::new($false))
  $multipleChild = Invoke-NestedChild $holder "transition-multiple"
  Assert-True ($multipleChild.status -eq 73) "multiple transition files fail closed"
  Remove-Item -LiteralPath $firstTransition, $secondTransition -Force
  Write-Output "PASS writer transition tolerated; lookalike, directory, and multiple entries refuse at client and server"

  # Owner record: any byte change refuses, including a launching-state variant
  # and a same-shape variant that changes only startedUtc.
  $fixtureStage = "owner-record"
  $launchingRaw = $holderRaw.Replace('"state":"attached"', '"state":"launching"')
  Assert-True ($launchingRaw -cne $holderRaw) "launching variant differs from the live owner"
  Write-OwnerRaw $launchingRaw
  $launchingChild = Invoke-NestedChild $holder "owner-launching"
  Assert-True ($launchingChild.status -eq 73 -and $launchingChild.stderr -match "is not started or attached") "launching owner state refuses 73"
  $startedUtcRaw = [regex]::Replace($holderRaw, '"startedUtc":"([^"]+)"', { param($match) '"startedUtc":"' + ([DateTimeOffset]::Parse($match.Groups[1].Value).AddMilliseconds(1).UtcDateTime.ToString("o")) + '"' })
  Assert-True ($startedUtcRaw -cne $holderRaw) "startedUtc variant differs from the live owner"
  Write-OwnerRaw $startedUtcRaw
  $startedUtcChild = Invoke-NestedChild $holder "owner-started-utc"
  Assert-True ($startedUtcChild.status -eq 73 -and $startedUtcChild.stderr -match "no longer equals the admitted record") "same-shape owner variant refuses 73 by byte inequality"
  Write-OwnerRaw $holderRaw
  $restoredChild = Invoke-NestedChild $holder "owner-restored"
  Assert-True ($restoredChild.status -eq 0) "restoring the exact owner bytes admits again (stderr=$($restoredChild.stderr))"
  foreach ($identityCase in @(
    @{ Name="root-start-mismatch"; Field="childProcessStartUtc"; Value=([DateTimeOffset]::Parse($holderOwner.childProcessStartUtc).UtcDateTime.AddTicks(1).ToString("o")) },
    @{ Name="wrapper-start-mismatch"; Field="processStartUtc"; Value=([DateTimeOffset]::Parse($holderOwner.processStartUtc).UtcDateTime.AddTicks(1).ToString("o")) },
    @{ Name="root-pid-crossed"; Field="childPid"; Value=$PID },
    @{ Name="wrapper-pid-crossed"; Field="pid"; Value=$PID },
    @{ Name="date-only-start"; Field="processStartUtc"; Value="2026-09-12" },
    @{ Name="extra-owner-field"; Field="unknown"; Value=$true }
  )) {
    $variant = $holderRaw | ConvertFrom-Json -AsHashtable -DateKind String
    $variant[$identityCase.Field] = $identityCase.Value
    Write-OwnerRaw ($variant | ConvertTo-Json -Compress -Depth 4)
    $identityResult = Invoke-NestedChild $holder $identityCase.Name
    Assert-True ($identityResult.status -eq 73 -and $identityResult.stdout -eq "") "$($identityCase.Name) refuses 73 before body"
    Write-OwnerRaw $holderRaw
  }
  Write-Output "PASS launching and same-shape owner variants refuse; exact restoration admits"

  # Dispatch record and live Git identity are revalidated per call.
  $fixtureStage = "dispatch-record"
  $changedRecord = $dispatchRecord.Raw.Replace('"state":"started"', '"state":"started" ')
  [IO.File]::WriteAllText($dispatchRecord.Path, $changedRecord, [Text.UTF8Encoding]::new($false))
  $changedRecordChild = Invoke-NestedChild $holder "dispatch-changed"
  Assert-True ($changedRecordChild.status -eq 73 -and $changedRecordChild.stderr -match "dispatch record changed") "changed dispatch record refuses 73"
  [IO.File]::WriteAllText($dispatchRecord.Path, $dispatchRecord.Raw, [Text.UTF8Encoding]::new($false))
  $restoredRecordChild = Invoke-NestedChild $holder "dispatch-restored"
  Assert-True ($restoredRecordChild.status -eq 0) "restored dispatch record admits again (stderr=$($restoredRecordChild.stderr))"
  $lateRecord = Write-DispatchOwnership -Label "goal-heavy-slot-late-competing"
  $lateRecordChild = Invoke-NestedChild $holder "late-competing-record"
  Assert-True ($lateRecordChild.status -eq 73 -and $lateRecordChild.stderr -match "census changed") "new competing dispatch after admission refuses 73"
  Remove-DispatchOwnership $lateRecord
  Remove-Item -LiteralPath $dispatchRecord.Path -Force
  $missingRecordChild = Invoke-NestedChild $holder "dispatch-missing"
  Assert-True ($missingRecordChild.status -eq 73 -and $missingRecordChild.stderr -match "dispatch record absent") "missing dispatch record refuses 73"
  [IO.File]::WriteAllText($dispatchRecord.Path, $dispatchRecord.Raw, [Text.UTF8Encoding]::new($false))
  $fixtureStage = "git-identity"
  Invoke-FixtureGit @("commit", "--allow-empty", "-m", "advance during admission") | Out-Null
  $movedHeadChild = Invoke-NestedChild $holder "head-moved"
  Assert-True ($movedHeadChild.status -eq 73 -and $movedHeadChild.stderr -match "HEAD moved") "moved worktree HEAD refuses 73"
  Invoke-FixtureGit @("reset", "--hard", $fixtureHead) | Out-Null
  $restoredHeadChild = Invoke-NestedChild $holder "head-restored"
  Assert-True ($restoredHeadChild.status -eq 0) "restored exact HEAD admits again (stderr=$($restoredHeadChild.stderr))"
  Invoke-FixtureGit @("checkout", "-q", "--detach", $fixtureHead) | Out-Null
  $detachedChild = Invoke-NestedChild $holder "branch-detached"
  Assert-True ($detachedChild.status -eq 73 -and $detachedChild.stderr -match "branch moved") "detached worktree under a branch admission refuses 73"
  Invoke-FixtureGit @("checkout", "-q", "codex/heavy-slot-fixture") | Out-Null
  Write-Output "PASS changed, missing, and restored dispatch record; moved, restored, and detached Git identity"

  # Raw protocol negatives: one field varies, every other field canonical.
  $fixtureStage = "raw-protocol"
  $rawControl = Invoke-RawRequest $holder "raw-control" (New-CanonicalRequest $holder)
  Assert-True (Test-RawAccepted $rawControl) "canonical raw request from a live descendant is signed (reply=$($rawControl.reply))"
  $repeatedRequest = New-CanonicalRequest $holder
  $firstChallenge = Invoke-RawRequest $holder "first-challenge" $repeatedRequest
  Assert-True (Test-RawAccepted $firstChallenge) "first request challenge is accepted"
  $replayedChallenge = Invoke-RawRequest $holder "repeated-challenge" $repeatedRequest
  Assert-True (-not (Test-RawAccepted $replayedChallenge) -and $replayedChallenge.reply -match "challenge replayed") "reused request challenge refuses"
  $rawCases = @(
    [pscustomobject]@{ Name = "pid-spoof-root"; Overrides = @{ pid = [int]$holder.Ready.pid }; Expect = "not the actual pipe client" },
    [pscustomobject]@{ Name = "pid-spoof-wrapper"; Overrides = @{ pid = [int]$holderOwner.pid }; Expect = "not the actual pipe client" },
    [pscustomobject]@{ Name = "extra-field"; Overrides = @{ extra = "field" }; Expect = "unknown field" },
    [pscustomobject]@{ Name = "missing-field"; Overrides = @{ "-gate" = $null }; Expect = "omitted a required field" },
    [pscustomobject]@{ Name = "foreign-lock"; Overrides = @{ lockId = "0123456789abcdef0123456789abcdef" }; Expect = "not this owner" },
    [pscustomobject]@{ Name = "crossed-kind"; Overrides = @{ kind = "build" }; Expect = "not admitted under gate" },
    [pscustomobject]@{ Name = "unknown-kind"; Overrides = @{ kind = "unknown" }; Expect = "not a classified heavy kind" },
    [pscustomobject]@{ Name = "wrong-head"; Overrides = @{ head = ("0" * 40) }; Expect = "not the admitted head" },
    [pscustomobject]@{ Name = "wrong-worktree"; Overrides = @{ worktree = $secondWorktree }; Expect = "not the admitted worktree" },
    [pscustomobject]@{ Name = "wrong-gate"; Overrides = @{ gate = "build" }; Expect = "not the admitted gate" },
    [pscustomobject]@{ Name = "wrong-role"; Overrides = @{ laneRole = "planning" }; Expect = "not the admitted role" },
    [pscustomobject]@{ Name = "wrong-launch"; Overrides = @{ launchId = [guid]::NewGuid().ToString() }; Expect = "not the admitted dispatch" },
    [pscustomobject]@{ Name = "wrong-lane"; Overrides = @{ lane = $secondLaneName }; Expect = "not the admitted lane" },
    [pscustomobject]@{ Name = "short-challenge"; Overrides = @{ challenge = "abc" }; Expect = "challenge" },
    [pscustomobject]@{ Name = "schema-version"; Overrides = @{ schemaVersion = 2 }; Expect = "schema version" },
    [pscustomobject]@{ Name = "duplicate-field"; Overrides = @{}; Mode = "duplicate"; Expect = "repeated a field" }
  )
  foreach ($case in $rawCases) {
    if ($case.Mode -ceq "duplicate") {
      $duplicateRaw = Invoke-Driver $holder "raw-$($case.Name)" @{ script = "raw-client"; env = @{ RAW_MODE = "duplicate" ; RAW_REQUEST = ((New-CanonicalRequest $holder) | ConvertTo-Json -Compress -Depth 4) } }
      Assert-True ($duplicateRaw.status -eq 0) "duplicate raw client ran"
      $duplicateReply = $duplicateRaw.stdout | ConvertFrom-Json
      Assert-True (-not (Test-RawAccepted $duplicateReply) -and $duplicateReply.reply -match $case.Expect) "raw $($case.Name) refuses ($($duplicateReply.reply))"
      continue
    }
    $rawReply = Invoke-RawRequest $holder "raw-$($case.Name)" (New-CanonicalRequest $holder $case.Overrides)
    Assert-True (-not (Test-RawAccepted $rawReply) -and $rawReply.reply -match $case.Expect) "raw $($case.Name) refuses ($($rawReply.reply))"
  }
  foreach ($mode in @("oversized", "invalid-json", "no-newline")) {
    $modeResult = Invoke-Driver $holder "raw-mode-$mode" @{ script = "raw-client"; env = @{ RAW_MODE = $mode; RAW_REQUEST = ((New-CanonicalRequest $holder) | ConvertTo-Json -Compress -Depth 4) } }
    Assert-True ($modeResult.status -eq 0) "raw mode $mode client ran"
    $modeReply = $modeResult.stdout | ConvertFrom-Json
    Assert-True (-not (Test-RawAccepted $modeReply)) "raw mode $mode is refused (reply=$($modeReply.reply) error=$($modeReply.error))"
  }
  $rawAfterControl = Invoke-RawRequest $holder "raw-control-after" (New-CanonicalRequest $holder)
  Assert-True (Test-RawAccepted $rawAfterControl) "server keeps serving canonical requests after malformed exchanges"
  Write-Output "PASS raw protocol negatives refuse; canonical control before and after is signed"

  # Borrowed client handle: the connection opener, not the payload, is the
  # actual client. The parent's own request is the accepted control.
  $fixtureStage = "borrowed-handle"
  $borrowResult = Invoke-Driver $holder "borrowed-handle" @{ script = "borrow-parent"; env = @{ RAW_REQUEST = ((New-CanonicalRequest $holder) | ConvertTo-Json -Compress -Depth 4) } }
  Assert-True ($borrowResult.status -eq 0) "borrow parent ran (stderr=$($borrowResult.stderr))"
  $borrowDetail = $borrowResult.stdout | ConvertFrom-Json
  Assert-True ($borrowDetail.controlReply -match '^\{"payload":"') "borrow parent's own connection is signed"
  $borrowedChild = $borrowDetail.borrowed | ConvertFrom-Json
  Assert-True ($borrowedChild.reply -match "not the actual pipe client") "borrowed client handle is never consumed (reply=$($borrowedChild.reply))"
  Write-Output "PASS borrowed client handle refused while the opener's own exchange is signed"

  Assert-True ((Read-OwnerRaw) -ceq $holderRaw) "NC1-NC4, sibling, descriptor, writer, record, and raw controls preserve the owner byte-exact"
  $holderStatistics = Stop-DriverHolder $holder
  Write-Output "PASS shared driver holder released after all controls"

  # AC5: a child inherits the validated token and descriptor and continues
  # through the nested owner without acquiring again.
  $fixtureStage = "nested-token"
  $nestedOuterMarker = Join-Path $root "nested-outer.marker"
  $nestedChildMarker = Join-Path $root "nested-child.marker"
  $nested = Start-Fixture -ExtraEnvironment @{
    SLOT_MARKER = $nestedOuterMarker
    NESTED_CHILD = $childFixture
    NESTED_MARKER = $nestedChildMarker
  }
  Wait-Condition { (Read-Owner) -and (Test-Path -LiteralPath $nestedOuterMarker) } "nested owner" 1200
  $nestedOwnerRecord = Read-Owner
  $nestedOwnerRaw = Get-Content -LiteralPath $ownerPath -Raw
  Complete-Fixture $nested 0 "nested artifact tree" | Out-Null
  Assert-True ((Get-Content -LiteralPath $nestedOuterMarker -Raw) -ceq $nestedOwnerRecord.lockId) "outer sees owner token"
  Assert-True ((Get-Content -LiteralPath $nestedChildMarker -Raw) -ceq $nestedOwnerRecord.lockId) "child inherits validated owner token"
  Assert-True ($nestedOwnerRaw -match [regex]::Escape($nestedOwnerRecord.lockId)) "one owner record serves the nested tree"
  Wait-Condition { -not (Test-Path -LiteralPath $lock) } "nested owner release" 1200

  # AC1/NC7: a wrapped gate publishes its lockId and descriptor; the artifact
  # root admits itself and a nested child through the Gate owner.
  $fixtureStage = "wrapped-gate"
  $wrappedMarker = Join-Path $root "wrapped.marker"
  $wrappedChildMarker = Join-Path $root "wrapped-child.marker"
  $wrapped = Start-GateWrapper "test:scripts" $fixture @{ SLOT_MARKER = $wrappedMarker; NESTED_CHILD = $childFixture; NESTED_MARKER = $wrappedChildMarker }
  Wait-Condition { $record = Read-Owner; $record -and $record.gate -ceq "test:scripts" -and $record.state -ceq "started" } "wrapped gate owner" 1200
  $wrappedOwner = Read-Owner
  Wait-Condition { Test-Path -LiteralPath $wrappedMarker -PathType Leaf } "wrapped artifact marker" 1200
  # Node creates the attached-admission result below os.tmpdir(); the verifier
  # accepts it only below its own [IO.Path]::GetTempPath(). Reaching the marker
  # proves both fixture runtimes resolve the same private temp directory.
  Assert-True ((Get-Content -LiteralPath $wrappedMarker -Raw) -ceq $wrappedOwner.lockId) "Gate path publishes the exact owner lockId"
  $wrappedOutput = Complete-Fixture $wrapped 0 "wrapped gate re-entrancy"
  Assert-True ((Get-Content -LiteralPath $wrappedChildMarker -Raw) -ceq $wrappedOwner.lockId) "Gate owner admits the nested child of its root"
  $wrapperSummary = @($wrappedOutput.stderr -split "`r?`n" | Where-Object { $_ -match "^heavy-verifier: nested-owner " })
  Assert-True ($wrapperSummary.Count -eq 1 -and $wrapperSummary[0] -match "served=2 refused=0" -and $wrapperSummary[0] -match "role=implementation") `
    "Gate wrapper reports exactly the root and child continuations (summary=$($wrapperSummary -join '|'))"
  $measurements.Add("MEASURE wrapper-initialization gate=test:scripts $($wrapperSummary[0].Substring('heavy-verifier: nested-owner '.Length))")
  Wait-Condition { -not (Test-Path -LiteralPath $lock) } "wrapped gate release" 1200
  Write-Output "PASS wrapped gate root and nested child admitted through the Gate owner"

  # No record admits an unbound host root. Denied roles and conflicting native
  # identities refuse before reservation; only an eligible unique binding nests.
  $fixtureStage = "binding-negatives"
  function Assert-PreReservationBindingRefusal([string]$Name, [string]$Reason, [object[]]$Ownership) {
    $marker = Join-Path $root "$Name.body"
    $entry = Start-Fixture -ExtraEnvironment @{ SLOT_MARKER = $marker }
    $output = Complete-Fixture $entry 73 $Name
    Assert-True ($output.stderr -match ("caller eligibility: " + $Reason) -and
      -not (Test-Path -LiteralPath $marker) -and -not (Test-Path -LiteralPath $lock) -and
      $output.stdout -notmatch '"bodyCounter":1') "$Name refuses before reservation and body"
    foreach ($ownershipRecord in $Ownership) {
      Assert-True ([IO.File]::ReadAllText($ownershipRecord.Path) -ceq $ownershipRecord.Raw) "$Name preserves native dispatch bytes"
    }
    Write-Output "PASS binding refusal name=$Name exit=73 marker=0 owner=0"
  }
  Remove-DispatchOwnership $dispatchRecord
  $unboundHolder = Start-DriverHolder
  $unboundChild = Invoke-NestedChild $unboundHolder "unbound-child"
  Assert-True ($unboundChild.status -eq 73 -and $unboundChild.stderr -match "no provable dispatch binding") "root without any dispatch record grants no nested authority"
  Stop-DriverHolder $unboundHolder | Out-Null
  $planningRecord = Write-DispatchOwnership -LaneRole "planning" -Label "goal-heavy-slot-planning"
  Assert-PreReservationBindingRefusal "planning-root" 'role=planning routing-row= cannot reserve heavy verification' @($planningRecord)
  Remove-DispatchOwnership $planningRecord
  $reviewRecord = Write-DispatchOwnership -LaneRole "review" -Label "goal-heavy-slot-review"
  Assert-PreReservationBindingRefusal "review-root" 'role=review routing-row= cannot reserve heavy verification' @($reviewRecord)
  Remove-DispatchOwnership $reviewRecord
  $dispatchRecord = Write-DispatchOwnership
  $secondRecord = Write-DispatchOwnership -RecordWorktree $secondWorktree -RecordLane $secondLaneName -Branch "codex/heavy-slot-second" -Head $secondHead -Label "goal-heavy-slot-second"
  Assert-PreReservationBindingRefusal "conflicting-identities-root" 'dispatch identity differs from admitted identity' @($dispatchRecord, $secondRecord)
  Remove-DispatchOwnership $secondRecord
  $reboundHolder = Start-DriverHolder
  $reboundChild = Invoke-NestedChild $reboundHolder "rebound-child"
  Assert-True ($reboundChild.status -eq 0) "single implementation record binds again (stderr=$($reboundChild.stderr))"
  Stop-DriverHolder $reboundHolder | Out-Null
  Write-Output "PASS missing dispatch grants no nested authority; planning/review/conflicting identities refuse before reservation; unique implementation binding admits"

  # Dead wrapper: once the exact holder dies the reserved pipe is gone, no
  # descendant can continue, and the guarded process keeps the lock protected.
  $fixtureStage = "dead-wrapper"
  $deadHolder = Start-DriverHolder
  $deadHolderIdentity = [pscustomobject]@{ pid = $deadHolder.Owner.pid; processStartUtc = $deadHolder.Owner.processStartUtc }
  Assert-True (Test-ExactProcess $deadHolderIdentity) "attached holder identity is exact before termination"
  Stop-Process -Id ([int]$deadHolderIdentity.pid) -Force
  Wait-Condition { -not (Test-ExactProcess $deadHolderIdentity) } "attached holder death"
  $deadChild = Invoke-NestedChild $deadHolder "dead-wrapper-child"
  Assert-True ($deadChild.status -eq 73 -and $deadChild.stderr -match "ENOENT") "descendant of a dead wrapper refuses 73 (stderr=$($deadChild.stderr))"
  $deadConnect = Invoke-Driver $deadHolder "dead-wrapper-connect" @{ script = "raw-client"; env = @{ RAW_MODE = "connect-only" } }
  $deadConnectDetail = $deadConnect.stdout | ConvertFrom-Json
  Assert-True ($deadConnectDetail.error -ceq "ENOENT") "reserved pipe instance does not survive the exact wrapper (connect=$($deadConnect.stdout))"
  Assert-True ((Read-OwnerRaw) -ceq $deadHolder.OwnerRaw) "dead holder record stays byte-exact while the guarded root lives"
  Set-Content -LiteralPath (Join-Path $deadHolder.Driver "stop") -Value "stop"
  Complete-Fixture $deadHolder.Entry 0 "guarded root after holder death" | Out-Null
  $deadRecoveryMarker = Join-Path $root "dead-wrapper-recovery.marker"
  $deadRecovery = Start-Fixture -ExtraEnvironment @{ SLOT_MARKER = $deadRecoveryMarker }
  Complete-Fixture $deadRecovery 0 "stale recovery after dead wrapper" | Out-Null
  Wait-Condition { -not (Test-Path -LiteralPath $lock) } "dead wrapper stale recovery release" 1200
  Write-Output "PASS dead wrapper leaves no reserved pipe, refuses descendants, and recovers only after guarded exit"

  # Escaped server handle (Gate mode): the wrapper's child inherits nothing, so
  # the pipe instance dies with the wrapper even while the child lives.
  $fixtureStage = "escaped-server-handle"
  $escapedProduction = Invoke-EscapedHandleScenario
  Assert-True ($escapedProduction.error -ceq "ENOENT") "production wrapper death removes the pipe while the Gate child lives (connect=$($escapedProduction | ConvertTo-Json -Compress))"
  Write-Output "PASS escaped server handle: pipe instance does not outlive the exact wrapper"

  # Gate/kind closure: every allowed and crossed pair under Attach and Gate roots.
  $fixtureStage = "kind-matrix"
  $matrixRows = [Collections.Generic.List[string]]::new()
  foreach ($rootKind in @("script-battery", "vitest-full", "build", "playwright", "repository-gate")) {
    $matrixHolder = Start-DriverHolder @{ SLOT_ROOT_KIND = $rootKind }
    Assert-True ($matrixHolder.Owner.gate -ceq $rootKind) "attached root records its own kind $rootKind"
    foreach ($claimed in $allKinds) {
      $expected = if (@($expectedKindClosure[$rootKind]) -ccontains $claimed) { 0 } else { 73 }
      $claimResult = Invoke-NestedChild $matrixHolder "matrix-$rootKind-$claimed" @{ SLOT_KIND = $claimed }
      Assert-True ($claimResult.status -eq $expected) "attached root $rootKind x descendant $claimed expected $expected (actual $($claimResult.status); stderr=$($claimResult.stderr))"
      $matrixRows.Add("MATRIX root=attached:$rootKind claimed=$claimed exit=$($claimResult.status)")
    }
    Stop-DriverHolder $matrixHolder | Out-Null
  }
  foreach ($gateCase in @(
      [pscustomobject]@{ Gate = "test:scripts"; RootClaim = "script-battery" },
      [pscustomobject]@{ Gate = "build"; RootClaim = "build" },
      [pscustomobject]@{ Gate = "verify:build"; RootClaim = "build" },
      [pscustomobject]@{ Gate = "check:static"; RootClaim = "repository-gate" },
      [pscustomobject]@{ Gate = "verify:test"; RootClaim = "repository-gate" },
      [pscustomobject]@{ Gate = "test"; RootClaim = "repository-gate" },
      [pscustomobject]@{ Gate = "test:fast"; RootClaim = "repository-gate" },
      [pscustomobject]@{ Gate = "verify:test-db"; RootClaim = "repository-gate" },
      [pscustomobject]@{ Gate = "verify:static"; RootClaim = "repository-gate" },
      [pscustomobject]@{ Gate = "verify"; RootClaim = "repository-gate" }
    )) {
    $gateHolder = Start-GateDriverHolder $gateCase.Gate @{ SLOT_ROOT_KIND = $gateCase.RootClaim }
    foreach ($claimed in $allKinds) {
      $expected = if (@($expectedKindClosure[$gateCase.Gate]) -ccontains $claimed) { 0 } else { 73 }
      $claimResult = Invoke-NestedChild $gateHolder "matrix-gate-$($gateCase.Gate)-$claimed" @{ SLOT_KIND = $claimed }
      Assert-True ($claimResult.status -eq $expected) "gate $($gateCase.Gate) x descendant $claimed expected $expected (actual $($claimResult.status); stderr=$($claimResult.stderr))"
      $matrixRows.Add("MATRIX root=gate:$($gateCase.Gate) claimed=$claimed exit=$($claimResult.status)")
    }
    Set-Content -LiteralPath (Join-Path $gateHolder.Driver "stop") -Value "stop"
    Complete-Fixture $gateHolder.Entry 0 "gate matrix wrapper $($gateCase.Gate)" | Out-Null
    Wait-Condition { -not (Test-Path -LiteralPath $lock) } "gate matrix release $($gateCase.Gate)" 1200
  }
  foreach ($row in $matrixRows) { Write-Output $row }
  Write-Output "PASS gate/kind closure proven for every allowed and crossed pair"
  }

  # AC1 measurement: complete unchanged work (one root, nineteen sequential
  # nested children, one deeper grandchild) under the baseline client at
  # 71deeaae and under the candidate, counted by job-object accounting.
  if (-not $MutantsOnly) {
  $fixtureStage = "measurement"
  $baselineClient = Join-Path $root "heavy-slot.baseline.cjs"
  $baselineGuard = Join-Path $root "invoke-heavy-verifier.baseline.ps1"
  $baselineGuardBytes = & git -C $controllerRoot show '177f2d55176d122b267444c3de240927f98285ff:.orchestrator/invoke-heavy-verifier.ps1' 2>$null
  Assert-True ($LASTEXITCODE -eq 0) "baseline wrapper is readable at the installed baseline"
  [IO.File]::WriteAllText($baselineGuard, (($baselineGuardBytes -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
  $baselineBytes = & git -C $controllerRoot cat-file blob $baselineClientBlob 2>$null
  Assert-True ($LASTEXITCODE -eq 0 -and @($baselineBytes).Count -gt 10) "baseline heavy-slot.cjs blob $baselineClientBlob is readable from the controller repository"
  [IO.File]::WriteAllText($baselineClient, (($baselineBytes -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
  function Measure-NestedRun([string]$Label, [string]$ClientPath, [int]$Count) {
    Copy-Item -LiteralPath $ClientPath -Destination $client -Force
    Copy-Item -LiteralPath $(if ($Label.StartsWith("baseline")) { $baselineGuard } else { $guardSource }) -Destination $guard -Force
    $job = [HeavySlotTest.JobAccounting]::Create()
    try {
      $watch = [Diagnostics.Stopwatch]::StartNew()
      $measureHolder = Start-DriverHolder @{} $job
      $admissionMs = [int]$measureHolder.Ready.acquireMs
      $childMs = [Collections.Generic.List[int]]::new()
      $childOwnMs = [Collections.Generic.List[int]]::new()
      for ($index = 1; $index -le $Count; $index += 1) {
        $result = Invoke-NestedChild $measureHolder "measure-$Label-$index"
        Assert-True ($result.status -eq 0) "measurement child $index admits under $Label (stderr=$($result.stderr))"
        $childMs.Add([int]$result.ms)
        $childOwnMs.Add([int](($result.stdout | ConvertFrom-Json).ms))
      }
      $deeperResult = $null
      if ($Count -gt 0) {
        $deeperResult = Invoke-NestedChild $measureHolder "measure-$Label-deeper" @{} -Deeper
        Assert-True ($deeperResult.status -eq 0) "measurement deeper child admits under $Label (stderr=$($deeperResult.stderr))"
      }
      $holderIdentity = [pscustomobject]@{ pid = $measureHolder.Owner.pid; processStartUtc = $measureHolder.Owner.processStartUtc }
      Stop-DriverHolder $measureHolder | Out-Null
      Wait-Condition {
        -not (Test-ExactProcess $holderIdentity) -and ([HeavySlotTest.JobAccounting]::Query($job)).ActiveProcesses -eq 0
      } "complete measurement job and holder exit $Label" 1200
      $wallMs = $watch.ElapsedMilliseconds
      $accounting = [HeavySlotTest.JobAccounting]::Query($job)
      Assert-True ($accounting.ActiveProcesses -eq 0) "measurement tree fully exited under $Label"
      return [pscustomobject]@{
        Label = $Label
        Count = $Count
        AdmissionMs = $admissionMs
        TotalProcesses = [int]$accounting.TotalProcesses
        CpuMs = [int](($accounting.TotalUserTime + $accounting.TotalKernelTime) / 10000)
        WallMs = $wallMs
        ChildAvgMs = $(if ($childMs.Count) { [int]($childMs | Measure-Object -Average).Average } else { 0 })
        ChildMaxMs = $(if ($childMs.Count) { [int]($childMs | Measure-Object -Maximum).Maximum } else { 0 })
        ChildOwnAvgMs = $(if ($childOwnMs.Count) { [int]($childOwnMs | Measure-Object -Average).Average } else { 0 })
        DeeperMs = $(if ($deeperResult) { [int]$deeperResult.ms } else { 0 })
      }
    } finally {
      [HeavySlotTest.JobAccounting]::Close($job)
      Copy-Item -LiteralPath $clientSource -Destination $client -Force
    }
  }
  $rootOnlyBaseline = Measure-NestedRun "baseline-root-only" $baselineClient 0
  $rootOnlyCandidate = Measure-NestedRun "candidate-root-only" $clientSource 0
  $nestedBaseline = Measure-NestedRun "baseline-nested" $baselineClient 19
  $nestedCandidate = Measure-NestedRun "candidate-nested" $clientSource 19
  $continuations = 19 + 2
  $baselinePerContinuation = ($nestedBaseline.TotalProcesses - $rootOnlyBaseline.TotalProcesses) / $continuations
  $candidatePerContinuation = ($nestedCandidate.TotalProcesses - $rootOnlyCandidate.TotalProcesses) / $continuations
  foreach ($run in @($rootOnlyBaseline, $rootOnlyCandidate, $nestedBaseline, $nestedCandidate)) {
    $measurements.Add("MEASURE run=$($run.Label) children=$($run.Count) admissionMs=$($run.AdmissionMs) totalProcesses=$($run.TotalProcesses) cpuMs=$($run.CpuMs) wallMs=$($run.WallMs) childAvgMs=$($run.ChildAvgMs) childMaxMs=$($run.ChildMaxMs) childOwnAvgMs=$($run.ChildOwnAvgMs) deeperMs=$($run.DeeperMs)")
  }
  $measurements.Add("MEASURE per-continuation baselineProcesses=$([Math]::Round($baselinePerContinuation, 2)) candidateProcesses=$([Math]::Round($candidatePerContinuation, 2)) baselineSpawnedHosts=$([Math]::Round($baselinePerContinuation - 1, 2)) candidateSpawnedHosts=$([Math]::Round($candidatePerContinuation - 1, 2)) baselineCpuMs=$([Math]::Round(($nestedBaseline.CpuMs - $rootOnlyBaseline.CpuMs) / $continuations, 1)) candidateCpuMs=$([Math]::Round(($nestedCandidate.CpuMs - $rootOnlyCandidate.CpuMs) / $continuations, 1))")
  foreach ($line in $measurements) { Write-Output $line }
  # Each continuation is one Node process. The baseline adds one PowerShell
  # host per continuation; the candidate adds none.
  Assert-True ($baselinePerContinuation -ge 2) "baseline spawns at least one host process per continuation (measured $baselinePerContinuation processes per continuation)"
  Assert-True ($candidatePerContinuation -eq 1) "candidate spawns zero host processes per continuation (measured $candidatePerContinuation processes per continuation)"
  Write-Output "PASS zero host-process spawns per nested continuation with complete unchanged work"

  }

  # Per-guard candidate/bypass mutants: one governing variable each, every
  # other input frozen, proving each refusal is load-bearing.
  $fixtureStage = "mutants"
  $mutantRows = [Collections.Generic.List[string]]::new()
  function Invoke-DriverAttack([string]$Attack, $Holder) {
    switch ($Attack) {
      "pid-spoof" {
        $reply = Invoke-RawRequest $Holder "mutant-$Attack" (New-CanonicalRequest $Holder @{ pid = [int]$Holder.Ready.pid })
        return (Test-RawAccepted $reply)
      }
      "ancestry" {
        $siblingEntry = Start-Fixture -Script $childFixture -ExtraEnvironment @{
          CHASE_SETS_HEAVY_SLOT_ID = $Holder.Owner.lockId
          CHASE_SETS_HEAVY_SLOT_TRANSPORT = $Holder.Ready.transport
        }
        Assert-True ($siblingEntry.Process.WaitForExit(30000)) "ancestry mutant sibling exits"
        [void]$siblingEntry.Process.StandardError.ReadToEnd()
        return ($siblingEntry.Process.ExitCode -eq 0)
      }
      "kind" {
        $result = Invoke-NestedChild $Holder "mutant-$Attack" @{ SLOT_KIND = "build" }
        return ($result.status -eq 0)
      }
      "dispatch-record" {
        [IO.File]::WriteAllText($dispatchRecord.Path, $dispatchRecord.Raw.Replace('"state":"started"', '"state":"started" '), [Text.UTF8Encoding]::new($false))
        try {
          $result = Invoke-NestedChild $Holder "mutant-$Attack"
          return ($result.status -eq 0)
        } finally {
          [IO.File]::WriteAllText($dispatchRecord.Path, $dispatchRecord.Raw, [Text.UTF8Encoding]::new($false))
        }
      }
      "git-identity" {
        Invoke-FixtureGit @("commit", "--allow-empty", "-m", "mutant advance") | Out-Null
        try {
          $result = Invoke-NestedChild $Holder "mutant-$Attack"
          return ($result.status -eq 0)
        } finally {
          Invoke-FixtureGit @("reset", "--hard", $fixtureHead) | Out-Null
        }
      }
      "owner-bytes" {
        $variant = [regex]::Replace($Holder.OwnerRaw, '"startedUtc":"([^"]+)"', { param($match) '"startedUtc":"' + ([DateTimeOffset]::Parse($match.Groups[1].Value).AddMilliseconds(1).UtcDateTime.ToString("o")) + '"' })
        Write-OwnerRaw $variant
        try {
          $result = Invoke-NestedChild $Holder "mutant-$Attack"
          return ($result.status -eq 0)
        } finally {
          Write-OwnerRaw $Holder.OwnerRaw
        }
      }
      "writer-entries" {
        $entryPath = Join-Path $lock "unrelated.tmp"
        [IO.File]::WriteAllText($entryPath, "x", [Text.UTF8Encoding]::new($false))
        try {
          $reply = Invoke-RawRequest $Holder "mutant-$Attack" (New-CanonicalRequest $Holder)
          return (Test-RawAccepted $reply)
        } finally {
          Remove-Item -LiteralPath $entryPath -Force
        }
      }
      "request-closure" {
        $reply = Invoke-RawRequest $Holder "mutant-$Attack" (New-CanonicalRequest $Holder @{ extra = "field" })
        return (Test-RawAccepted $reply)
      }
      "signature" {
        $result = Invoke-NestedChild $Holder "mutant-$Attack" @{
          CHASE_SETS_HEAVY_SLOT_TRANSPORT = (New-TamperedTransport $Holder.Ready.transport @{ publicKey = (New-ForeignPublicKey) })
        }
        return ($result.status -eq 0)
      }
      "descriptor-required" {
        $result = Invoke-NestedChild $Holder "mutant-$Attack" @{ CHASE_SETS_HEAVY_SLOT_TRANSPORT = $null }
        return ($result.status -eq 0)
      }
      "challenge" {
        # The replaying server (attacker model) answers every request with the
        # first signed envelope; only the client's challenge check can refuse it.
        $second = Invoke-NestedChild $Holder "mutant-$Attack-twice" @{ SLOT_REPEAT = "2" }
        return ($second.status -eq 0)
      }
      default { throw "unknown attack $Attack" }
    }
  }
  $serverReplayMutant = @(
    @('private bool _disposed;', "private bool _disposed;`n        private byte[] _replayCache;"),
    @('return Encoding.UTF8.GetBytes(envelope);', 'if (_replayCache == null) _replayCache = Encoding.UTF8.GetBytes(envelope); return _replayCache;')
  )
  $mutantCases = @(
    [pscustomobject]@{ Name = "pid-trust"; Attack = "pid-spoof"; Target = "owner"; Pairs = @(
        @('if (actualPid != (uint)request.Pid) { Refuse(token, "request pid is not the actual pipe client"); return null; }', '/* MUTANT pid-trust */')) },
    [pscustomobject]@{ Name = "ancestry-unwalked"; Attack = "ancestry"; Target = "owner"; Pairs = @(
        @('AncestryProbe toRoot = ProcessTree.WalkUp(first, client, binding.RootPid, rootTicks, held, visited, chain);', 'AncestryProbe toRoot = new AncestryProbe { Contained = true, Chain = chain.ToArray() }; /* MUTANT ancestry-unwalked */')) },
    [pscustomobject]@{ Name = "kind-closure"; Attack = "kind"; Target = "owner"; Pairs = @(
        @('if (Array.IndexOf(binding.AllowedKinds, request.Kind) < 0) { Refuse(token, "request kind " + request.Kind + " is not admitted under gate " + binding.Gate); return null; }', '/* MUTANT kind-closure */')) },
    [pscustomobject]@{ Name = "dispatch-bytes"; Attack = "dispatch-record"; Target = "owner"; Pairs = @(
        @('if (!BytesEqual(raw, _dispatchRawBytes)) return "dispatch record changed since admission";', '/* MUTANT dispatch-bytes */'),
        @('!BytesEqual(selectedRaw, selected)) return "selected dispatch absent or changed";', 'false /* MUTANT dispatch-bytes */) return "selected dispatch absent or changed";')) },
    [pscustomobject]@{ Name = "git-identity"; Attack = "git-identity"; Target = "owner"; Pairs = @(
        @('string gitFailure = CheckGitIdentity(binding);', 'string gitFailure = null; /* MUTANT git-identity */')) },
    [pscustomobject]@{ Name = "owner-bytes"; Attack = "owner-bytes"; Target = "owner"; Pairs = @(
        @('if (!BytesEqual(raw, _ownerRawBytes)) return "owner.json no longer equals the admitted record";', '/* MUTANT owner-bytes */')) },
    [pscustomobject]@{ Name = "writer-entries"; Attack = "writer-entries"; Target = "owner"; Pairs = @(
        @('string entries = CheckWriterEntries(binding.LockDirectory);', 'string entries = null; /* MUTANT writer-entries */')) },
    [pscustomobject]@{ Name = "request-closure"; Attack = "request-closure"; Target = "owner"; Pairs = @(
        @('if (Array.IndexOf(RequestFields, property.Name) < 0) { failure = "request carried an unknown field"; return null; }', '/* MUTANT request-closure */'),
        @('if (fields.Count != RequestFields.Length) { failure = "request omitted a required field"; return null; }', 'if (fields.Count < RequestFields.Length) { failure = "request omitted a required field"; return null; }')) },
    [pscustomobject]@{ Name = "client-signature"; Attack = "signature"; Target = "client"; Pairs = @(
        @('if (!verified) return { failure: "nested continuation reply signature did not verify against the admitted key" };', '/* MUTANT client-signature */')) },
    [pscustomobject]@{ Name = "client-descriptor-required"; Attack = "descriptor-required"; Target = "client"; Pairs = @(
        @('if (transportResult.failure) return transportResult.failure;', 'if (transportResult.failure) return null; /* MUTANT client-descriptor-required */')) },
    [pscustomobject]@{ Name = "client-challenge"; Attack = "challenge"; Target = "client"; Pairs = @(
        @('reply.challenge !== challenge ||', '/* MUTANT client-challenge */')) }
  )
  foreach ($case in @($mutantCases | Select-Object -Skip $MutantStartAt)) {
    $target = if ($case.Target -ceq "owner") { $nestedOwner } else { $client }
    $source = if ($case.Target -ceq "owner") { $nestedOwnerSource } else { $clientSource }
    # Candidate: production bytes (plus the attacker-model server for replay).
    Restore-FixtureSources
    if ($case.Attack -ceq "challenge") { Set-SourceMutant $nestedOwnerSource $nestedOwner $serverReplayMutant "server-replay" }
    $candidateHolder = Start-DriverHolder
    $candidateAdmitted = Invoke-DriverAttack $case.Attack $candidateHolder
    Stop-DriverHolder $candidateHolder | Out-Null
    Assert-True (-not $candidateAdmitted) "candidate refuses attack $($case.Attack) for guard $($case.Name)"
    # Bypass: exactly the guard's governing variable changed.
    Restore-FixtureSources
    if ($case.Attack -ceq "challenge") { Set-SourceMutant $nestedOwnerSource $nestedOwner $serverReplayMutant "server-replay" }
    Set-SourceMutant $source $target $case.Pairs $case.Name
    $mutantHolder = Start-DriverHolder
    $mutantAdmitted = Invoke-DriverAttack $case.Attack $mutantHolder
    Stop-DriverHolder $mutantHolder | Out-Null
    Restore-FixtureSources
    Assert-True $mutantAdmitted "bypass mutant $($case.Name) admits attack $($case.Attack) (the production guard is load-bearing)"
    $mutantRows.Add("MUTANT guard=$($case.Name) attack=$($case.Attack) candidate=refused bypass=admitted")
    Write-Output $mutantRows[$mutantRows.Count - 1]
  }
  # Escaped server handle: an inheritable pipe handle survives in the Gate
  # child after the wrapper dies; the production non-inheritable handle does not.
  Set-SourceMutant $nestedOwnerSource $nestedOwner @(@('bInheritHandle = false', 'bInheritHandle = true /* MUTANT inheritable-handle */')) "inheritable-handle"
  $escapedMutant = Invoke-EscapedHandleScenario
  Restore-FixtureSources
  Assert-True ($escapedMutant.error -cne "ENOENT") "inheritable-handle mutant lets the pipe instance outlive the wrapper (connect=$($escapedMutant | ConvertTo-Json -Compress))"
  $mutantRows.Add("MUTANT guard=inheritable-handle attack=escaped-server-handle candidate=pipe-gone bypass=pipe-survives($($escapedMutant.error)$($escapedMutant.connected))")
  # Dispatch role: the wrapper mutant that binds planning lanes grants nested
  # authority to a root under a planning-only record.
  Remove-DispatchOwnership $dispatchRecord
  $planningOnly = Write-DispatchOwnership -LaneRole "planning" -Label "goal-heavy-slot-planning-mutant"
  # One policy mutant admits the unchanged planning role at every protocol
  # boundary. It never relabels the real record as an implementation launch.
  Set-SourceMutant $guardSource $guard @(@('if ($binding.Record -and ($binding.Record.laneRole -cne ''implementation'' -or $binding.Row -eq 13)) {', 'if ($false) { # MUTANT dispatch-role')) "dispatch-role"
  Set-SourceMutant $nestedOwnerSource $nestedOwner @(
    @('if (binding.LaneRole != "implementation" && binding.LaneRole != "review") throw new ArgumentException("binding.LaneRole");', '/* MUTANT dispatch-role */'),
    @('(role != "implementation" && role != "review")', '(false /* MUTANT dispatch-role */)')
  ) "dispatch-role-server"
  Set-SourceMutant $clientSource $client @(
    @('(descriptor.laneRole !== null && descriptor.laneRole !== "implementation" && descriptor.laneRole !== "review")', '(false /* MUTANT dispatch-role */)'),
    @('(reply.dispatch.laneRole !== "implementation" && reply.dispatch.laneRole !== "review")', '(false /* MUTANT dispatch-role */)')
  ) "dispatch-role-client"
  $roleMutantHolder = Start-DriverHolder
  $roleMutantChild = Invoke-NestedChild $roleMutantHolder "mutant-dispatch-role"
  Stop-DriverHolder $roleMutantHolder | Out-Null
  Restore-FixtureSources
  Remove-DispatchOwnership $planningOnly
  $dispatchRecord = Write-DispatchOwnership
  Assert-True ($roleMutantChild.status -eq 0) "dispatch-role mutant admits under a planning-only record (the production role filter is load-bearing)"
  $mutantRows.Add("MUTANT guard=dispatch-role attack=planning-only-record candidate=refused bypass=admitted")
  foreach ($row in $mutantRows) { Write-Output $row }
  Write-Output "PASS per-guard candidate/bypass mutants: every nested authority guard is load-bearing"

  Write-Output "PASS heavy slot artifact acquisition, token identity, refusal, nesting, nested authority, and re-entrancy"
} catch {
  $bodyFailure = $_
  Write-FixtureDiagnostics "body-failure-before-cleanup"
} finally {
  try {
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
    if (Test-Path -LiteralPath $root) {
      Assert-DisposableRoot
      Wait-Condition {
        @(
          Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { [string]$_.CommandLine -like "*$root*" }
        ).Count -eq 0
      } "all exact temp-root artifact holders to exit" 400
      $admissionTempRoots = @(
        Get-ChildItem -LiteralPath $privateTemp -Directory -Filter "chase-sets-heavy-admission-*" -ErrorAction SilentlyContinue
      )
      if ($admissionTempRoots.Count -ne 0) {
        Write-FixtureDiagnostics "cleanup-residue-before-root-removal"
        $cleanupFailure = "ASSERTION FAILED: test leaves zero chase-sets-heavy-admission roots in its private temp directory"
      }
      Remove-Item -LiteralPath $root -Recurse -Force
      Write-Output "FIXTURE_CLEANUP root=$root processes=0 admissionRoots=$($admissionTempRoots.Count) removed=$(-not (Test-Path -LiteralPath $root))"
    }
  } catch {
    if (-not $cleanupFailure) { $cleanupFailure = $_ }
    Write-FixtureDiagnostics "cleanup-exception"
  }
}
if ($bodyFailure) { throw $bodyFailure }
if ($cleanupFailure) { throw $cleanupFailure }
