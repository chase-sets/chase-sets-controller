[CmdletBinding()]
param(
  [string]$ControllerRoot = (Split-Path -Parent $PSScriptRoot),

  [Parameter(Mandatory)]
  [string]$ExpectedControllerHead,

  # Installed baseline commit. When given, the battery runs the impact scope:
  # the smoke set, the changed tests, every test that reaches a changed file,
  # and the guard discriminators. No baseline, -Scope full, a change to this
  # battery, or a changed runtime file that no test reaches selects the full
  # battery.
  [string]$BaselineHead = "",

  [Parameter(DontShow)]
  [string]$SkillsRoot = (Join-Path $HOME '.claude/skills'),

  [ValidateSet("impact", "full")][string]$Scope = "impact",

  # Repair rounds bind their baseline to a governing BLOCK_FIXABLE receipt on
  # that ancestor head. Omit both fields for an initial candidate, whose
  # baseline remains the installed controller head.
  [ValidateRange(0, [int]::MaxValue)][int]$RepairIssue = 0,
  [string]$RepairHistoryPath = "",

  # Optional externally produced guard-evidence record for issue-6254.
  [string]$EvidenceReceiptPath = "",

  # Optional machine-readable battery result output.
  [string]$ResultPath = "",

  # Optional local prior or downloaded controller CI final.json. CI imports
  # authenticate the run, artifact ZIP digest and orphan source trailer against
  # GitHub (gh read access required), then execute only the missing/ineligible
  # and changed items. Import evidence is retained in this seat's artifacts.
  [string]$PriorResultPath = "",

  # Per-item stop (#9373): one ';'-separated string of required identities that
  # execute under any prior instead of being lent, such as open CI reuse
  # safeguard items (milestone-orchestrator section 7). '' names none. An empty
  # segment or an identity not ordinally in the required inventory refuses
  # BATTERY_NO_REUSE_IDENTITY_UNKNOWN before any item runs.
  [string]$NoReuseIdentity = "",

  # Concurrent items (#120): one ';'-separated string of at most two distinct
  # test:* identities the battery knows at -Scope full. Each listed item that is
  # selected and not reused starts as a child process at loop start; every other
  # item stays serial and in order. '' (the default) runs every item serially.
  # A malformed list refuses BATTERY_CONCURRENT_IDENTITY_* before any item runs.
  [string]$ConcurrentIdentity = "",

  # stop (default): end at the first failure that is neither PREEXISTING nor
  # BASELINE_ALSO_FAILS; the remaining items are recorded as not run. all: run
  # every item regardless.
  [ValidateSet("stop", "all")][string]$OnFailure = "stop",

  [switch]$ValidatePlanOnly,

  # Exact-owner continuation supplied only by invoke-heavy-verifier.ps1 after
  # it has acquired and published the controller-battery owner record.
  [Parameter(DontShow)]
  [switch]$AdmissionOwned
)

$ErrorActionPreference = "Stop"
# Committed canonical path declaration. Optional batteryHostSha256 literals in
# fixtures are diagnostic only: routine bundle updates never require a repin.
$batteryHostPath = 'C:/Users/ToddS/.cache/codex-runtimes/codex-primary-runtime/dependencies/native/powershell/pwsh.exe'
$controller = [IO.Path]::GetFullPath($ControllerRoot)
$runtime = Join-Path $controller ".orchestrator"

# Source-mutation seams used only in a copied battery by the omission suite.
# Reconciliation below never consults these switches.
$planInclusion = [ordered]@{
  "direct:fail-closed-guard-evidence" = $true
  "discriminator:issue-6254" = $true
}

function Stop-Battery([string]$Code) {
  throw "FAIL controller-release-battery: $Code"
}

# Result and baseline-evidence writes stay physically under .orchestrator/artifacts
# (#98). The artifact root is canonical: its parent is resolved once through every
# link above it (a worktree or TEMP below a junction is supported). A path is then
# accepted only when it lies beneath that canonical root and no existing component
# from the root itself through the path is a reparse point (junction, symlink or
# mount). Links at or below the root are refused, never followed, so the
# reparse-free path under the physical root is the physical path a write reaches.
function Resolve-BatteryPhysicalPath([string]$Path) {
  $full = [IO.Path]::GetFullPath($Path).TrimEnd("\", "/")
  $current = [IO.Path]::GetPathRoot($full)
  foreach ($part in $full.Substring($current.Length).Split([char[]]@("\", "/"), [StringSplitOptions]::RemoveEmptyEntries)) {
    $current = [IO.Path]::Combine($current, $part)
    $attributes = $null
    try { $attributes = [IO.File]::GetAttributes($current) } catch [IO.FileNotFoundException], [IO.DirectoryNotFoundException] {}
    if ($null -ne $attributes -and $attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
      # The final target is itself canonical, so the walk continues from it.
      $target = [IO.DirectoryInfo]::new($current).ResolveLinkTarget($true)
      if ($null -ne $target) { $current = $target.FullName }
    }
  }
  return $current.TrimEnd("\", "/")
}

function Assert-BatteryArtifactPath([string]$Root, [string]$Path, [string]$Code) {
  $full = [IO.Path]::GetFullPath($Path).TrimEnd("\", "/")
  if (-not ([string]::Equals($full, $Root, [StringComparison]::OrdinalIgnoreCase) -or
            $full.StartsWith($Root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase))) {
    Stop-Battery $Code
  }
  for ($cursor = $full; -not [string]::IsNullOrEmpty($cursor); $cursor = [IO.Path]::GetDirectoryName($cursor)) {
    $attributes = $null
    try { $attributes = [IO.File]::GetAttributes($cursor) } catch [IO.FileNotFoundException], [IO.DirectoryNotFoundException] {}
    if ($null -ne $attributes -and $attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) { Stop-Battery $Code }
    if ([string]::Equals($cursor, $Root, [StringComparison]::OrdinalIgnoreCase)) { break }
  }
  return $full
}

# Test seam (#98), inert in production: the battery self-test replaces this empty
# body in a copied battery to swap the artifact root between validation and a write.
function Invoke-BatteryArtifactWriteSeam([string]$Path) {}

# Defense in depth (#98): retain the path recheck after the handle-anchored write.
function Confirm-BatteryArtifactWrite([string]$Root, [string]$Path, [string]$Code) {
  [void](Assert-BatteryArtifactPath $Root $Path $Code)
}

# Keep this implementation in the battery: copied-battery controls and release
# hosts must use the same primitive without loading a helper through a swapped path.
function Initialize-BatteryArtifactNative {
  if ('ChaseSets.BatteryArtifactWriter' -as [type]) { return }
  Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
namespace ChaseSets {
  public static class BatteryArtifactWriter {
    [StructLayout(LayoutKind.Sequential)] struct UnicodeString {
      public ushort Length, MaximumLength;
      public IntPtr Buffer;
    }
    [StructLayout(LayoutKind.Sequential)] struct ObjectAttributes {
      public int Length;
      public IntPtr RootDirectory, ObjectName;
      public uint Attributes;
      public IntPtr SecurityDescriptor, SecurityQualityOfService;
    }
    [StructLayout(LayoutKind.Sequential)] struct IoStatus {
      public IntPtr Status, Information;
    }
    [StructLayout(LayoutKind.Sequential)] struct FileInfo {
      public uint Attributes;
      public System.Runtime.InteropServices.ComTypes.FILETIME Creation, Access, Write;
      public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
    [DllImport("ntdll.dll")] static extern int NtCreateFile(out SafeFileHandle handle,
      uint access, ref ObjectAttributes attributes, out IoStatus status, IntPtr size,
      uint fileAttributes, uint share, uint disposition, uint options, IntPtr ea, uint eaLength);
    [DllImport("ntdll.dll")] static extern uint RtlNtStatusToDosError(int status);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern SafeFileHandle CreateFileW(string path, uint access, uint share,
      IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInfo info);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle, StringBuilder path, uint length, uint flags);

    static void Check(SafeFileHandle handle, bool directory) {
      if (!GetFileInformationByHandle(handle, out var info)) throw new Win32Exception(Marshal.GetLastWin32Error());
      if ((info.Attributes & 0x400) != 0 || ((info.Attributes & 0x10) != 0) != directory)
        throw new IOException("Artifact handle is a reparse point or has the wrong type");
      if (!directory && info.Links != 1) throw new IOException("Artifact file has multiple hard links");
    }
    static SafeFileHandle Open(SafeFileHandle parent, string name, bool directory, uint disposition) {
      // Exactly one component. Never allow NT object names, ADS, or traversal.
      if (name.Length == 0 || name == "." || name == ".." || name.IndexOfAny(new[]{'\\','/',':','\0'}) >= 0)
        throw new IOException("Invalid artifact component");
      IntPtr buffer = Marshal.StringToHGlobalUni(name);
      IntPtr unicode = Marshal.AllocHGlobal(Marshal.SizeOf<UnicodeString>());
      try {
        var text = new UnicodeString { Length=checked((ushort)(name.Length*2)), MaximumLength=checked((ushort)(name.Length*2)), Buffer=buffer };
        Marshal.StructureToPtr(text, unicode, false);
        var attributes = new ObjectAttributes { Length=Marshal.SizeOf<ObjectAttributes>(), RootDirectory=parent.DangerousGetHandle(), ObjectName=unicode, Attributes=0x40 };
        // SYNCHRONIZE | FILE_READ_ATTRIBUTES | (LIST_DIRECTORY or GENERIC_WRITE).
        // Directory share Read pins names against rename/delete. Reparse data
        // can still change, but NTFS refuses relative opens through a handle
        // converted to a reparse point (0xC0000280).
        int status = NtCreateFile(out var handle, directory ? 0x100081u : 0x40100080u,
          ref attributes, out _, IntPtr.Zero, 0, directory || disposition != 2u ? 1u : 0u, disposition,
          0x200020u | (directory ? 1u : 0x40u), IntPtr.Zero, 0);
        if (status < 0) { handle?.Dispose(); throw new Win32Exception((int)RtlNtStatusToDosError(status)); }
        try { Check(handle, directory); return handle; } catch { handle.Dispose(); throw; }
      } finally { Marshal.FreeHGlobal(unicode); Marshal.FreeHGlobal(buffer); }
    }
    public static void Write(string root, string path, byte[] bytes, bool directory, bool createNew) {
      if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("Artifact writes require Windows no-follow handles");
      root = Path.GetFullPath(root).TrimEnd('\\', '/');
      path = Path.GetFullPath(path).TrimEnd('\\', '/');
      if (!path.Equals(root, StringComparison.OrdinalIgnoreCase) && !path.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
        throw new IOException("Artifact path escapes root");
      var handles = new List<SafeFileHandle>();
      try {
        // Only ancestors ABOVE artifacts may have been resolved through links.
        // The canonical parent already exists; never create it through a path.
        string parentPath = Path.GetDirectoryName(root);
        string nativeParent = parentPath.StartsWith("\\\\") ? "\\\\?\\UNC\\" + parentPath.Substring(2) : "\\\\?\\" + parentPath;
        var parent = CreateFileW(nativeParent, 0x100081, 1, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
        handles.Add(parent);
        if (parent.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
        Check(parent, true);
        var finalPath = new StringBuilder(32768);
        uint length = GetFinalPathNameByHandleW(parent, finalPath, (uint)finalPath.Capacity, 0);
        if (length == 0 || length >= finalPath.Capacity || !finalPath.ToString().Equals(nativeParent, StringComparison.OrdinalIgnoreCase))
          throw new IOException("Artifact parent handle is not the canonical parent");
        var parts = path.Equals(root, StringComparison.OrdinalIgnoreCase) ? Array.Empty<string>() : Path.GetRelativePath(root, path).Split(Path.DirectorySeparatorChar);
        parent = Open(parent, Path.GetFileName(root), true, 3); // FILE_OPEN_IF
        handles.Add(parent);
        for (int i=0; i<parts.Length; i++) {
          bool isDirectory = directory || i < parts.Length-1;
          // FILE_CREATE preserves CreateNew evidence; existing output files are
          // opened without truncation, checked on-handle, then truncated below.
          var child = Open(parent, parts[i], isDirectory, isDirectory ? 3u : (createNew ? 2u : 3u));
          handles.Add(child);
          parent = child;
        }
        if (!directory) {
          if (parts.Length == 0) throw new IOException("Artifact file cannot be the root");
          using (var stream = new FileStream(parent, FileAccess.Write)) {
            stream.SetLength(0);
            stream.Write(bytes, 0, bytes.Length);
          }
        }
      } finally { for (int i=handles.Count-1; i>=0; i--) handles[i].Dispose(); }
    }
  }
}
'@
}

function Write-BatteryArtifact([string]$Root, [string]$Path, [string]$Code, [byte[]]$Bytes = @(), [switch]$Directory, [switch]$CreateNew) {
  try {
    Initialize-BatteryArtifactNative
    [ChaseSets.BatteryArtifactWriter]::Write($Root, $Path, $Bytes, $Directory.IsPresent, $CreateNew.IsPresent)
  } catch {
    Write-Warning "artifact write refused ($Path): $($_.Exception.Message)"
    Stop-Battery $Code
  }
}

function Test-SameBatteryPath([string]$Left, [string]$Right) {
  try {
    return [string]::Equals(
      [IO.Path]::GetFullPath($Left).TrimEnd("\", "/"),
      [IO.Path]::GetFullPath($Right).TrimEnd("\", "/"),
      [StringComparison]::OrdinalIgnoreCase
    )
  } catch {
    return $false
  }
}

# Fleet-load probe (#8102). Reports whether the platform heavy-verifier slot of
# this container (<container>/.orchestrator/verify-lock.d/owner.json) is held by
# a LIVE owner, using the heavy verifier's own liveness rule: the wrapper pid
# with its process start identity, or (schema 2..5, state started/attached) the
# child pid with its start identity. A stale or unreadable owner.json is never
# load. The battery never takes or waits on that slot. -Holder returns the live
# holder's identity fields and summary string, or $null when the slot is
# vacant, stale or unreadable (#99).
function Test-BatteryProcessIdentityLive([object]$ProcessId, [object]$ProcessStartUtc) {
  if ($ProcessId -isnot [int] -and $ProcessId -isnot [long]) { return $false }
  if ([long]$ProcessId -lt 1 -or [long]$ProcessId -gt [int]::MaxValue) { return $false }
  if ($ProcessStartUtc -isnot [string] -or [string]::IsNullOrWhiteSpace($ProcessStartUtc)) { return $false }
  try {
    $expected = [DateTimeOffset]::Parse($ProcessStartUtc, [Globalization.CultureInfo]::InvariantCulture).ToUniversalTime().Ticks
    $process = @(Get-Process -Id ([int]$ProcessId) -ErrorAction SilentlyContinue)
    if ($process.Count -ne 1) { return $false }
    return $process[0].StartTime.ToUniversalTime().Ticks -eq $expected
  } catch {
    return $false
  }
}

function Get-BatteryFleetLoad([switch]$Holder) {
  $vacant = if ($Holder) { $null } else { "none" }
  $ownerPath = Join-Path (Split-Path -Parent $controller) ".orchestrator\verify-lock.d\owner.json"
  if (-not (Test-Path -LiteralPath $ownerPath -PathType Leaf)) { return $vacant }
  try {
    $openDeadline = [Diagnostics.Stopwatch]::StartNew()
    $stream = $null
    for ($openAttempt = 1; $null -eq $stream; $openAttempt++) {
      try {
        $stream = [IO.File]::Open($ownerPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
      } catch {
        $exception = $_.Exception.GetBaseException()
        $errorCode = [int]$exception.HResult -band 0xffff
        if (-not $IsWindows -or ($exception -isnot [IO.IOException] -and $exception -isnot [UnauthorizedAccessException]) -or
            $errorCode -notin @(5, 32) -or $openAttempt -ge 8 -or $openDeadline.ElapsedMilliseconds -ge 1000) { throw }
        [Threading.Thread]::Sleep([int][Math]::Min(10, [Math]::Max(1, 1000 - $openDeadline.ElapsedMilliseconds)))
        if ($openDeadline.ElapsedMilliseconds -ge 1000) { throw }
      }
    }
    try {
      $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true)
      try { $raw = $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { $stream.Dispose() }
    $owner = $raw | ConvertFrom-Json -DateKind String -ErrorAction Stop
  } catch {
    return $vacant
  }
  if ($null -eq $owner) { return $vacant }
  $wrapperLive = Test-BatteryProcessIdentityLive $owner.pid $owner.processStartUtc
  $childLive = $false
  if (-not $wrapperLive -and ($owner.schemaVersion -is [int] -or $owner.schemaVersion -is [long]) -and
      [long]$owner.schemaVersion -ge 2 -and [long]$owner.schemaVersion -le 5 -and
      ([string]$owner.state) -cin @("started", "attached")) {
    $childLive = Test-BatteryProcessIdentityLive $owner.childPid $owner.childProcessStartUtc
  }
  if (-not ($wrapperLive -or $childLive)) { return $vacant }
  $identity = "lane=$($owner.lane);gate=$($owner.gate);lockId=$($owner.lockId);pid=$($owner.pid);started=$($owner.processStartUtc)"
  if (-not $Holder) { return ($identity -replace '\s', '_') }
  return [pscustomobject][ordered]@{
    identity = ($identity -replace '\s', '_'); lane = [string]$owner.lane; gate = [string]$owner.gate
    lockId = [string]$owner.lockId; pid = $owner.pid; started = [string]$owner.processStartUtc
  }
}

# Per-item holder sampling (#99), evidence only: an item's fleetLoad stays its
# start sample's summary, and sampling never changes classification, outcome,
# reuse or MEASURED_LOAD. Every sample is one Get-BatteryFleetLoad snapshot read
# (a delete-sharing open, read and close), so a sample that overlaps an owner
# publication cannot fail it. An item gets a start sample, in-flight samples
# from one background sampler that the item runner drives independently of the
# child's stdout/stderr (a quiet item is still sampled), and an end sample after
# its child exits: at most cap samples per item, the end sample reserved.
# In-flight intervals double from firstMs to maxMs. When the in-flight budget is
# spent while the item still runs, its in-flight sampling stops and the item
# records truncated. Bounded sampling can miss a brief holder, so an empty holder
# list means none was observed, never that the fleet was vacant.
function New-BatteryFleetSampler([string]$Identity, $StartHolder) {
  $sampler = @{
    identity = $Identity; cap = 64; firstMs = 250; maxMs = 60000
    samples = 0; inFlight = 0; truncated = $false; ended = $false; process = $null
    intervalMs = 0; nextDueTicks = [long]::MaxValue; holders = [Collections.Generic.List[object]]::new()
    summary = $(if ($null -eq $StartHolder) { "none" } else { $StartHolder.identity })
  }
  Add-BatteryFleetObservation $sampler "start" $StartHolder
  return $sampler
}

# Counts one sample and records its holder once, with the holder's identity
# fields and every moment (start, during, end) that observed it. The caller
# holds the sampler lock once the sampler is registered.
function Add-BatteryFleetObservation($Sampler, [string]$Moment, $Holder) {
  $Sampler.samples++
  if ($null -eq $Holder) { return }
  $record = $null
  foreach ($known in $Sampler.holders) { if ($known.identity -ceq $Holder.identity) { $record = $known; break } }
  if ($null -eq $record) {
    $record = [ordered]@{
      identity = $Holder.identity; lane = $Holder.lane; gate = $Holder.gate; lockId = $Holder.lockId; pid = $Holder.pid
      started = $Holder.started; moments = [Collections.Generic.List[string]]::new(); firstSample = $Sampler.samples; lastSample = 0
    }
    $Sampler.holders.Add($record)
  }
  if (-not $record.moments.Contains($Moment)) { $record.moments.Add($Moment) }
  $record.lastSample = $Sampler.samples
}

# The background sampler. Each pass gives every due item one in-flight sample
# and every exited child (concurrent items) its end sample; one snapshot read
# serves all of them. Each in-flight sample prints a FLEET_SAMPLE progress line
# and an exhausted budget prints FLEET_SAMPLE_TRUNCATED once, through the
# battery's host so lines never interleave with the item runner's output.
function Invoke-BatteryFleetSamplerLoop($State) {
  while (-not $State.stop) {
    $notices = [Collections.Generic.List[string]]::new()
    try {
      $due = [Collections.Generic.List[object]]::new()
      $exited = [Collections.Generic.List[object]]::new()
      $now = [DateTime]::UtcNow.Ticks
      [Threading.Monitor]::Enter($State.lock)
      try {
        foreach ($sampler in $State.active) {
          if ($sampler.ended) { continue }
          if ($null -ne $sampler.process -and $sampler.process.HasExited) { $exited.Add($sampler); continue }
          if ($sampler.nextDueTicks -gt $now) { continue }
          if ($sampler.inFlight -ge $sampler.cap - 2) {
            $sampler.truncated = $true
            $sampler.nextDueTicks = [long]::MaxValue
            $notices.Add("FLEET_SAMPLE_TRUNCATED identity=$($sampler.identity) samples=$($sampler.samples) cap=$($sampler.cap)")
            continue
          }
          $due.Add($sampler)
        }
      } finally { [Threading.Monitor]::Exit($State.lock) }
      if ($due.Count -gt 0 -or $exited.Count -gt 0) {
        $holder = Get-BatteryFleetLoad -Holder
        $summary = if ($null -eq $holder) { "none" } else { $holder.identity }
        [Threading.Monitor]::Enter($State.lock)
        try {
          foreach ($sampler in $due) {
            if ($sampler.ended) { continue }
            $sampler.inFlight++
            Add-BatteryFleetObservation $sampler "during" $holder
            $sampler.intervalMs = [Math]::Min($sampler.maxMs, $sampler.intervalMs * 2)
            $sampler.nextDueTicks = [DateTime]::UtcNow.AddMilliseconds($sampler.intervalMs).Ticks
            $notices.Add("FLEET_SAMPLE identity=$($sampler.identity) moment=during sample=$($sampler.samples) holder=$summary")
          }
          foreach ($sampler in $exited) {
            if ($sampler.ended) { continue }
            $sampler.ended = $true
            Add-BatteryFleetObservation $sampler "end" $holder
          }
        } finally { [Threading.Monitor]::Exit($State.lock) }
      }
    } catch {
      $notices.Add("FLEET_SAMPLE_ERROR message=$($_.Exception.Message -creplace '\s+', '_')")
    }
    foreach ($notice in $notices) { $Host.UI.WriteLine($notice) }
    [void]$State.wake.WaitOne(100)
  }
}

# Registers a started item for in-flight sampling; the first registration of a
# run starts the background sampler. A concurrent item passes its child process
# so the sampler takes the end sample as soon as that child exits.
function Start-BatteryFleetSampler($Sampler, $Process = $null) {
  if ($null -eq $fleetSampling.host) {
    $state = @{
      lock = [object]::new(); active = [Collections.Generic.List[object]]::new(); stop = $false
      wake = [Threading.AutoResetEvent]::new($false); controller = $controller
    }
    $definitions = @("Test-BatteryProcessIdentityLive", "Get-BatteryFleetLoad", "Add-BatteryFleetObservation", "Invoke-BatteryFleetSamplerLoop") |
      ForEach-Object { (Get-Command -Name $_ -CommandType Function).ScriptBlock.Ast.Extent.Text }
    $runspace = [runspacefactory]::CreateRunspace($Host)
    $runspace.Open()
    $shell = [powershell]::Create()
    $shell.Runspace = $runspace
    [void]$shell.AddScript('param($State, $Definitions) . ([scriptblock]::Create($Definitions)); $controller = $State.controller; Invoke-BatteryFleetSamplerLoop $State').
      AddArgument($state).AddArgument($definitions -join "`n")
    $fleetSampling.host = @{ state = $state; runspace = $runspace; shell = $shell; async = $shell.BeginInvoke() }
  }
  $state = $fleetSampling.host.state
  [Threading.Monitor]::Enter($state.lock)
  try {
    $Sampler.process = $Process
    $Sampler.intervalMs = $Sampler.firstMs
    $Sampler.nextDueTicks = [DateTime]::UtcNow.AddMilliseconds($Sampler.firstMs).Ticks
    $state.active.Add($Sampler)
  } finally { [Threading.Monitor]::Exit($state.lock) }
}

# Ends an item's sampling after its child has exited and returns the additive
# per-item evidence. The end sample is taken here unless the background sampler
# already took it for an exited concurrent child.
function Complete-BatteryFleetSampler($Sampler) {
  $takeEnd = $true
  if ($null -ne $fleetSampling.host) {
    $state = $fleetSampling.host.state
    [Threading.Monitor]::Enter($state.lock)
    try {
      $takeEnd = -not $Sampler.ended
      $Sampler.ended = $true
      [void]$state.active.Remove($Sampler)
    } finally { [Threading.Monitor]::Exit($state.lock) }
  } elseif ($Sampler.ended) {
    $takeEnd = $false
  }
  if ($takeEnd) {
    $Sampler.ended = $true
    Add-BatteryFleetObservation $Sampler "end" (Get-BatteryFleetLoad -Holder)
  }
  return [ordered]@{ samples = $Sampler.samples; truncated = $Sampler.truncated; holders = @($Sampler.holders) }
}

function Stop-BatteryFleetSamplerHost {
  $samplerHost = $fleetSampling.host
  if ($null -eq $samplerHost) { return }
  $fleetSampling.host = $null
  $samplerHost.state.stop = $true
  [void]$samplerHost.state.wake.Set()
  if (-not $samplerHost.async.AsyncWaitHandle.WaitOne(10000)) { $samplerHost.shell.Stop() }
  $samplerHost.shell.Dispose()
  $samplerHost.runspace.Dispose()
  $samplerHost.state.wake.Dispose()
}

function Assert-BatteryAdmission {
  $token = [string]$env:CHASE_SETS_HEAVY_SLOT_ID
  if ($token -cnotmatch "^[a-f0-9]{32}$") { Stop-Battery "BATTERY_ADMISSION_TOKEN_INVALID" }
  $container = Split-Path -Parent $controller
  # The controller slot, never the platform verifier's (Todd ruling 2026-09-10).
  $lockPath = Join-Path $container ".orchestrator\controller-verify-lock.d"
  $ownerPath = Join-Path $lockPath "owner.json"
  if (-not (Test-Path -LiteralPath $lockPath -PathType Container) -or
      -not (Test-Path -LiteralPath $ownerPath -PathType Leaf)) {
    Stop-Battery "BATTERY_ADMISSION_OWNER_INVALID"
  }
  $deadline = [DateTime]::UtcNow.AddSeconds(10)
  do {
    try {
      $entries = @(Get-ChildItem -LiteralPath $lockPath -Force -ErrorAction Stop)
      if ($entries.Count -eq 1 -and
          (Test-SameBatteryPath $entries[0].FullName $ownerPath) -and
          -not $entries[0].PSIsContainer -and
          (($entries[0].Attributes -band [IO.FileAttributes]::ReparsePoint) -ne [IO.FileAttributes]::ReparsePoint)) {
        $openDeadline = [Diagnostics.Stopwatch]::StartNew()
        $stream = $null
        for ($openAttempt = 1; $null -eq $stream; $openAttempt++) {
          try {
            $stream = [IO.File]::Open($ownerPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
          } catch {
            $exception = $_.Exception.GetBaseException()
            $errorCode = [int]$exception.HResult -band 0xffff
            if (-not $IsWindows -or ($exception -isnot [IO.IOException] -and $exception -isnot [UnauthorizedAccessException]) -or
                $errorCode -notin @(5, 32) -or $openAttempt -ge 8 -or $openDeadline.ElapsedMilliseconds -ge 1000) { throw }
            [Threading.Thread]::Sleep([int][Math]::Min(10, [Math]::Max(1, 1000 - $openDeadline.ElapsedMilliseconds)))
            if ($openDeadline.ElapsedMilliseconds -ge 1000) { throw }
          }
        }
        try {
          $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true)
          try { $raw = $reader.ReadToEnd() } finally { $reader.Dispose() }
        } finally { $stream.Dispose() }
        $owner = $raw | ConvertFrom-Json -DateKind String -ErrorAction Stop
        if ($owner.schemaVersion -eq 4 -and
            $owner.lockId -ceq $token -and
            $owner.gate -ceq "script-battery" -and
            $owner.state -ceq "started" -and
            $owner.identityMode -ceq "branch" -and
            (Test-SameBatteryPath ([string]$owner.worktree) $controller) -and
            $owner.head -ceq $ExpectedControllerHead -and
            $owner.branch -ceq (& git -C $controller branch --show-current 2>$null | Out-String).Trim() -and
            [int]$owner.childPid -eq $PID) {
          $self = Get-Process -Id $PID -ErrorAction Stop
          $wrapper = Get-Process -Id ([int]$owner.pid) -ErrorAction Stop
          $expectedSelf = [DateTimeOffset]::Parse([string]$owner.childProcessStartUtc).ToUniversalTime().Ticks
          $expectedWrapper = [DateTimeOffset]::Parse([string]$owner.processStartUtc).ToUniversalTime().Ticks
          if ($self.StartTime.ToUniversalTime().Ticks -eq $expectedSelf -and
              $wrapper.StartTime.ToUniversalTime().Ticks -eq $expectedWrapper) {
            return
          }
        }
      }
    } catch {}
    Start-Sleep -Milliseconds 25
  } while ([DateTime]::UtcNow -lt $deadline)
  Stop-Battery "BATTERY_ADMISSION_OWNER_INVALID"
}

function Quote-Command([string[]]$Arguments) {
  return @($Arguments | ForEach-Object {
      if ($_ -match '[\s"]') { '"' + $_.Replace('"', '\"') + '"' } else { $_ }
    }) -join " "
}

function Get-BatteryHostIdentity {
  $identity = [ordered]@{
    expectedPath = 'unavailable'; actualPath = 'unavailable'; sha256 = 'unavailable'
    byteLength = 'unavailable'; ProductVersion = 'unavailable'; PSVersion = 'unavailable'
    PSHOME = 'unavailable'; bundleVersion = 'unavailable'
  }
  $diagnostics = [Collections.Generic.List[string]]::new()
  try {
    $source = (& git -C $controller show "${ExpectedControllerHead}:.orchestrator/controller-release-battery.ps1" 2>$null | Out-String)
    if ($LASTEXITCODE -ne 0) { throw 'unreadable candidate blob' }
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$parseErrors)
    if ($parseErrors.Count -ne 0) { throw 'malformed candidate blob' }
    $declarations = @($ast.FindAll({ param($node)
      $node -is [Management.Automation.Language.AssignmentStatementAst] -and
      @($node.Left.FindAll({ param($variable)
        $variable -is [Management.Automation.Language.VariableExpressionAst] -and
        ($variable.VariablePath.UserPath -split ':')[-1] -ieq 'batteryHostPath'
      }, $true)).Count -gt 0
    }, $true))
    if ($declarations.Count -ne 1) { throw 'missing or duplicate path declaration' }
    $declaration = $declarations[0]
    if ($declaration.Parent -ne $ast.EndBlock -or
        $declaration.Left -isnot [Management.Automation.Language.VariableExpressionAst] -or
        $declaration.Left.VariablePath.UserPath -ine 'batteryHostPath' -or
        $declaration.Operator -ne 'Equals' -or
        $declaration.Right -isnot [Management.Automation.Language.CommandExpressionAst] -or
        $declaration.Right.Expression -isnot [Management.Automation.Language.StringConstantExpressionAst] -or
        $declaration.Right.Expression.StringConstantType -notin @('SingleQuoted', 'DoubleQuoted')) {
      throw 'path declaration must be a top-level string literal'
    }
    $literal = $declaration.Right.Expression.Value
    if ([string]::IsNullOrWhiteSpace($literal) -or -not [IO.Path]::IsPathFullyQualified($literal) -or
        $literal.IndexOfAny([IO.Path]::GetInvalidPathChars()) -ge 0) { throw 'invalid absolute path' }
    $identity.expectedPath = [IO.Path]::GetFullPath($literal)
  } catch {
    $diagnostics.Add('BATTERY_HOST_PIN_INVALID')
  }

  # Observations are independent, best-effort and never admission predicates.
  try { $identity.actualPath = [IO.Path]::GetFullPath((Get-Process -Id $PID -ErrorAction Stop).Path) } catch {}
  try { $identity.sha256 = (Get-FileHash -LiteralPath $identity.actualPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant() } catch {}
  try { $identity.byteLength = (Get-Item -LiteralPath $identity.actualPath -Force -ErrorAction Stop).Length } catch {}
  try {
    $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($identity.actualPath).ProductVersion
    if (-not [string]::IsNullOrWhiteSpace($version)) { $identity.ProductVersion = $version }
  } catch {}
  try { $identity.PSVersion = $PSVersionTable.PSVersion.ToString() } catch {}
  if (-not [string]::IsNullOrWhiteSpace($PSHOME)) { $identity.PSHOME = $PSHOME }
  try {
    $metadata = [IO.File]::ReadAllText('C:/Users/ToddS/.cache/codex-runtimes/codex-primary-runtime/runtime.json') | ConvertFrom-Json -ErrorAction Stop
    if ($metadata.bundleVersion -is [string] -and -not [string]::IsNullOrWhiteSpace($metadata.bundleVersion)) {
      $identity.bundleVersion = $metadata.bundleVersion
    }
  } catch {}

  if ($diagnostics.Count -eq 0) {
    try {
      $canonical = Get-Item -LiteralPath $identity.expectedPath -Force -ErrorAction Stop
      if ($canonical.PSIsContainer -or $canonical.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
        $diagnostics.Add('BATTERY_HOST_CANONICAL_INVALID')
      }
    } catch [Management.Automation.ItemNotFoundException] {
      $diagnostics.Add('BATTERY_HOST_CANONICAL_MISSING')
    } catch {
      $diagnostics.Add('BATTERY_HOST_CANONICAL_INVALID')
    }
    if (-not (Test-SameBatteryPath $identity.expectedPath $identity.actualPath)) {
      $diagnostics.Add('BATTERY_HOST_PATH_MISMATCH')
    }
  }
  $script:batteryHostLog = 'BATTERY_HOST_IDENTITY ' + (@($identity.Keys | ForEach-Object { "$_=$($identity[$_])" }) -join '; ')
  Write-Host $script:batteryHostLog
  if ($diagnostics.Count -gt 0) {
    Write-Host "BATTERY_HOST_REFUSED primary=$($diagnostics[0]) diagnostics=$($diagnostics -join ',') PIN=committed canonical path declaration"
    Write-Host ("canonicalCommand=& '" + $identity.expectedPath.Replace("'", "''") + "' -NoProfile -NonInteractive -File '" +
      (Join-Path $runtime 'controller-release-battery.ps1').Replace("'", "''") + "' -ControllerRoot '" +
      $controller.Replace("'", "''") + "' -ExpectedControllerHead $ExpectedControllerHead")
    Stop-Battery $diagnostics[0]
  }
  return [pscustomobject]$identity
}

function New-PlanItem(
  [string]$Identity,
  [string]$Path,
  [string[]]$Arguments
) {
  return [pscustomobject][ordered]@{
    identity = $Identity
    path = $Path
    executable = (Get-Process -Id $PID -ErrorAction Stop).Path
    arguments = $Arguments
    command = ((Get-Process -Id $PID -ErrorAction Stop).Path) + " " + (Quote-Command $Arguments)
  }
}

# Impact scope. References are read from code tokens (comments excluded). An
# orchestrator path is referenced by its name stem, plus its directory when the
# stem is shared across orchestrator directories; any other repository path
# only by an explicit leaf or parent/leaf string.
$batteryCodePattern = '\.(ps1|psm1|cjs|js|mjs|cs|py|sh|vbs)$'
$batterySmokeTests = @(
  ".orchestrator/issue-6997-autonomy-policy.test.ps1",
  ".orchestrator/contract-enforcement.test.ps1",
  ".orchestrator/install-controller-skills.test.ps1",
  ".orchestrator/controller-release-battery.test.ps1",
  ".orchestrator/landing-preflight.test.ps1"
)

function Get-BatteryReferenceKey([string]$Path) {
  $leaf = ($Path -split "/")[-1]
  $key = ($leaf.TrimStart(".") -split "\.")[0]
  if ([string]::IsNullOrEmpty($key)) { return $leaf }
  return $key
}

function Get-BatteryReferenceText([string]$RelativePath) {
  $absolute = Join-Path $controller $RelativePath
  if (-not (Test-Path -LiteralPath $absolute -PathType Leaf)) { return "" }
  if ($RelativePath -cmatch '\.(ps1|psm1)$') {
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($absolute, [ref]$tokens, [ref]$parseErrors)
    if (@($parseErrors).Count -eq 0) {
      return (@($tokens | Where-Object { $_.Kind -ne [Management.Automation.Language.TokenKind]::Comment } |
          ForEach-Object { $_.Text }) -join "`n")
    }
  }
  return [IO.File]::ReadAllText($absolute)
}

function New-BatteryReferenceIndex([string[]]$TreePaths) {
  $keyDirectories = [Collections.Generic.Dictionary[string, Collections.Generic.HashSet[string]]]::new([StringComparer]::OrdinalIgnoreCase)
  $leafDirectories = [Collections.Generic.Dictionary[string, Collections.Generic.HashSet[string]]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($path in $TreePaths) {
    $directory = if ($path.Contains("/")) { $path.Substring(0, $path.LastIndexOf("/")) } else { "" }
    $leaf = ($path -split "/")[-1]
    if (-not $leafDirectories.ContainsKey($leaf)) { $leafDirectories[$leaf] = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase) }
    [void]$leafDirectories[$leaf].Add($directory)
    if ($path -cmatch "^\.orchestrator/") {
      $key = Get-BatteryReferenceKey $path
      if (-not $keyDirectories.ContainsKey($key)) { $keyDirectories[$key] = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase) }
      [void]$keyDirectories[$key].Add($directory)
    }
  }
  $documents = [ordered]@{}
  # The battery names its smoke tests and is never a reader: its own change
  # always runs the battery's full self-test (see the scope selection below).
  foreach ($path in @($TreePaths | Where-Object {
        $_ -cmatch "^\.orchestrator/" -and $_ -cmatch $batteryCodePattern -and
        $_ -cne ".orchestrator/controller-release-battery.ps1"
      })) {
    $text = Get-BatteryReferenceText $path
    $tokenSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($match in [regex]::Matches($text, "[A-Za-z0-9_-]+")) { [void]$tokenSet.Add($match.Value) }
    $documents[$path] = [pscustomobject]@{ text = $text.Replace("\", "/"); tokens = $tokenSet }
  }
  return [pscustomobject]@{ keyDirectories = $keyDirectories; leafDirectories = $leafDirectories; documents = $documents }
}

function Test-BatteryReference($Document, [string]$Path, $Index) {
  $segments = @($Path -split "/")
  $leaf = $segments[-1]
  $parent = if ($segments.Count -gt 1) { $segments[-2].TrimStart(".") } else { "" }
  if ($Path -cmatch "^\.orchestrator/") {
    $key = Get-BatteryReferenceKey $Path
    if (-not $Document.tokens.Contains($key)) { return $false }
    $shared = $Index.keyDirectories.ContainsKey($key) -and $Index.keyDirectories[$key].Count -gt 1
    return (-not $shared -or [string]::IsNullOrEmpty($parent) -or $Document.tokens.Contains($parent))
  }
  $sharedLeaf = $Index.leafDirectories.ContainsKey($leaf) -and $Index.leafDirectories[$leaf].Count -gt 1
  $needle = if ($sharedLeaf -and $segments.Count -gt 1) { $segments[-2] + "/" + $leaf } else { $leaf }
  return $Document.text.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Test-BatteryRuntimePath([string]$Path, [string[]]$TestPaths) {
  if ($Path -cnotmatch "^\.orchestrator/" -or $TestPaths -ccontains $Path) { return $false }
  if ($Path -cmatch "^\.orchestrator/(artifacts|fixtures)/") { return $false }
  return ($Path -cmatch $batteryCodePattern -or $Path -cmatch "^\.orchestrator/[^/]+\.json$")
}

# Per changed path: the orchestrator code files that reference it (transitively
# for a code file; only the direct readers for a skill, contract or data file),
# and the tests or discriminators that reference any of them. A changed test is
# its own impact. A changed runtime path that reaches no test is unreached and
# forces the full battery.
function Get-BatteryImpact([string[]]$Paths, $Index, [string[]]$TestPaths, [string[]]$TreePaths) {
  $tests = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  $unreached = [Collections.Generic.List[string]]::new()
  $byPath = [ordered]@{}
  foreach ($path in $Paths) {
    $reached = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $pathTests = [Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    $queue = [Collections.Generic.Queue[string]]::new()
    $transitive = $path -cmatch $batteryCodePattern
    [void]$reached.Add($path)
    if ($TestPaths -ccontains $path) {
      [void]$pathTests.Add($path)
    } else {
      $queue.Enqueue($path)
    }
    while ($queue.Count -gt 0) {
      $current = $queue.Dequeue()
      foreach ($candidate in @($Index.documents.Keys)) {
        if ($reached.Contains($candidate)) { continue }
        if (-not (Test-BatteryReference $Index.documents[$candidate] $current $Index)) { continue }
        if ($TestPaths -ccontains $candidate) {
          [void]$reached.Add($candidate)
          [void]$pathTests.Add($candidate)
        } elseif ($transitive -or $current -ceq $path) {
          [void]$reached.Add($candidate)
          $queue.Enqueue($candidate)
        }
      }
    }
    if ($pathTests.Count -eq 0 -and ($TreePaths -ccontains $path) -and (Test-BatteryRuntimePath $path $TestPaths)) {
      $unreached.Add($path)
    }
    foreach ($test in $pathTests) { [void]$tests.Add($test) }
    $byPath[$path] = [string[]]@($pathTests)
  }
  return [pscustomobject]@{ tests = $tests; unreached = [string[]]@($unreached); byPath = $byPath }
}

# Normalized failure lines: roots, absolute paths, hex, GUIDs, timestamps and
# long numbers are masked so two runs of one defect compare equal.
function Get-BatteryFailureSignature([string]$Output, [string]$Root) {
  $lines = [Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
  foreach ($line in @($Output -split "\r?\n")) {
    if ($line -notmatch '(?i)(assert|fail|error|exception|refus)') { continue }
    $normalized = $line.Replace($Root, "<ROOT>").Replace($Root.Replace("\", "/"), "<ROOT>")
    $normalized = $normalized -replace '(?i)[A-Z]:[\\/][^\s''"]*', '<PATH>'
    $normalized = $normalized -replace '(?i)\b[0-9a-f]{8}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{12}\b', '<GUID>'
    $normalized = $normalized -replace '\d{4}-\d{2}-\d{2}T[0-9:.]+Z?', '<TIME>'
    $normalized = $normalized -replace '(?i)\b[0-9a-f]{7,}\b', '<HEX>'
    $normalized = $normalized -replace '\d{3,}', '<N>'
    [void]$lines.Add($normalized.Trim())
  }
  return (@($lines) -join "`n")
}

function Get-BatteryCiApi([string]$Endpoint) {
  $json = @(& gh api --method GET "repos/chase-sets/chase-sets-controller/$Endpoint" 2>$null)
  if ($LASTEXITCODE -ne 0) { throw 'CI_API_FAILED' }
  return (($json -join "`n") | ConvertFrom-Json -Depth 40 -DateKind String -ErrorAction Stop)
}

function Save-BatteryCiArtifact([string]$ArtifactId, [string]$Path) {
  # Native stdout redirection preserves the downloaded ZIP bytes (PS 7.4+).
  & gh api --method GET "repos/chase-sets/chase-sets-controller/actions/artifacts/$ArtifactId/zip" > $Path 2>$null
  if ($LASTEXITCODE -ne 0) { throw 'CI_DOWNLOAD_FAILED' }
}

function Test-BatteryCiArguments($CiArguments, $LocalArguments, $Prior) {
  if ($CiArguments -isnot [array] -or $LocalArguments -isnot [array] -or
      $CiArguments.Count -eq 0 -or $CiArguments.Count -ne $LocalArguments.Count) { return $false }
  for ($i = 0; $i -lt $CiArguments.Count; $i++) {
    if ($CiArguments[$i] -isnot [string] -or $LocalArguments[$i] -isnot [string]) { return $false }
    $ciArg = $CiArguments[$i].Replace('{CONTROLLER}', $controller)
    if ($ciArg -ceq $Prior.ci.checkoutHead) { $ciArg = [string]$Prior.controllerHead }
    $localArg = $LocalArguments[$i]
    # Normalize only path-valued elements. Switches, case, order, and empty
    # argument values (notably EvidenceReceiptPath) retain ordinal semantics.
    if ($ciArg -cmatch '^(?:[A-Za-z]:[\\/]|[/\\]|\.\.?[\\/])') { $ciArg = $ciArg.Replace('\', '/') }
    if ($localArg -cmatch '^(?:[A-Za-z]:[\\/]|[/\\]|\.\.?[\\/])') { $localArg = $localArg.Replace('\', '/') }
    if ($ciArg -cne $localArg) { return $false }
  }
  return $true
}

function Import-BatteryCiPrior($Prior, [byte[]]$ReceiptBytes) {
  $runId = [string]$Prior.ci.runId
  if ($runId -cnotmatch '^[1-9][0-9]*$' -or
      [string]$Prior.ci.checkoutHead -cnotmatch '^[a-f0-9]{40}$' -or
      [string]$Prior.ci.runnerHead -cnotmatch '^[a-f0-9]{40}$' -or
      [string]$Prior.ci.productSha -cnotmatch '^[a-f0-9]{40}$') { throw 'CI_IDENTITY_INVALID' }
  $run = Get-BatteryCiApi "actions/runs/$runId"
  if ([string]$run.id -cne $runId -or $run.status -cne 'completed' -or
      $run.repository.full_name -cne 'chase-sets/chase-sets-controller' -or
      $run.head_repository.full_name -cne 'chase-sets/chase-sets-controller' -or
      $run.path -cne '.github/workflows/controller-battery.yml' -or
      $run.head_branch -cne 'main' -or $run.event -cnotin @('push', 'workflow_dispatch') -or
      $run.head_sha -cne $Prior.ci.runnerHead) { throw 'CI_RUN_INVALID' }
  # The path alone does not authenticate a workflow: an arbitrary dispatch
  # branch can rewrite it. Only runners on the trusted main lineage qualify.
  $lineage = Get-BatteryCiApi "compare/$($run.head_sha)...main"
  if ($lineage.status -cnotin @('identical', 'ahead')) { throw 'CI_RUN_INVALID' }
  # A failed run is still useful per-item. Neither its conclusion nor the
  # receipt's aggregate outcome can convert FAIL/LOCAL_ONLY into reusable PASS.
  $listing = Get-BatteryCiApi "actions/runs/$runId/artifacts?per_page=100"
  if ($listing.total_count -gt 100) { throw 'CI_ARTIFACT_LIST_INCOMPLETE' }
  $artifacts = @($listing.artifacts | Where-Object { $_.name -ceq 'controller-battery-result' })
  if ($artifacts.Count -ne 1) { throw 'CI_ARTIFACT_INVALID' }
  $artifact = $artifacts[0]
  if ([string]$artifact.id -cnotmatch '^[1-9][0-9]*$' -or $artifact.expired -ne $false -or
      [string]$artifact.workflow_run.id -cne $runId -or $artifact.workflow_run.head_sha -cne $run.head_sha -or
      [string]$artifact.digest -cnotmatch '^sha256:[a-f0-9]{64}$') { throw 'CI_ARTIFACT_INVALID' }
  $importRoot = Join-Path (Resolve-BatteryPhysicalPath $runtime) 'artifacts'
  $importRoot = Assert-BatteryArtifactPath $importRoot $importRoot 'CI_ARTIFACT_PATH_INVALID'
  $archivePath = Join-Path $importRoot ("controller-ci-$runId-$($artifact.id)-" + [guid]::NewGuid().ToString('N') + '.zip')
  $downloadPath = [IO.Path]::GetTempFileName()
  try {
    if ($downloadPath.StartsWith($importRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'CI_TEMP_PATH_INVALID' }
    Save-BatteryCiArtifact ([string]$artifact.id) $downloadPath
    $archiveBytes = [IO.File]::ReadAllBytes($downloadPath)
    $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($archiveBytes)).ToLowerInvariant()
    if (('sha256:' + $digest) -cne $artifact.digest) { throw 'CI_DIGEST_MISMATCH' }
    $archive = [IO.Compression.ZipArchive]::new([IO.MemoryStream]::new($archiveBytes, $false), [IO.Compression.ZipArchiveMode]::Read)
    try {
      # Do not extract untrusted paths. Compare the exact receipt bytes, not a
      # caller-editable imported JSON envelope or just its self-reported hash.
      $entries = @($archive.Entries | Where-Object { $_.FullName -ceq 'final.json' })
      if ($entries.Count -ne 1) { throw 'CI_RECEIPT_MISMATCH' }
      $stream = $entries[0].Open()
      $memory = [IO.MemoryStream]::new()
      try { $stream.CopyTo($memory); $original = $memory.ToArray() } finally { $stream.Dispose(); $memory.Dispose() }
      if ([Convert]::ToBase64String($original) -cne [Convert]::ToBase64String($ReceiptBytes)) { throw 'CI_RECEIPT_MISMATCH' }
      $logs = @($archive.Entries | Where-Object { $_.FullName -ceq 'controller-ci.log' })
      if ($logs.Count -ne 1) { throw 'CI_RAW_LOG_MISMATCH' }
      $stream = $logs[0].Open()
      try { $rawHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant() }
      finally { $stream.Dispose() }
      if ($rawHash -cne [string]$Prior.rawLog.sha256 -or $logs[0].Length -ne $Prior.rawLog.byteLength) { throw 'CI_RAW_LOG_MISMATCH' }
    } finally { $archive.Dispose() }
    $snapshot = Get-BatteryCiApi "git/commits/$($Prior.ci.checkoutHead)"
    if ($snapshot.sha -cne $Prior.ci.checkoutHead -or @($snapshot.parents).Count -ne 0) { throw 'CI_SNAPSHOT_NOT_ORPHAN' }
    $localTree = & git -C $controller rev-parse "$($Prior.controllerHead)^{tree}" 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]$snapshot.tree.sha -cne [string]$localTree) { throw 'CI_TREE_MISMATCH' }
    $trailers = [regex]::Matches([string]$snapshot.message, '(?m)^Source-Controller-Head: ([a-f0-9]{40})\s*$')
    if ($trailers.Count -ne 1 -or $trailers[0].Groups[1].Value -cne $Prior.controllerHead) { throw 'CI_TRAILER_MISMATCH' }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($row in @($Prior.results)) {
      if ([string]::IsNullOrWhiteSpace([string]$row.identity) -or -not $seen.Add([string]$row.identity)) { throw 'CI_DUPLICATE_ITEM' }
    }
    $seen.Clear()
    foreach ($item in @($Prior.inventory)) {
      if ([string]::IsNullOrWhiteSpace([string]$item.identity) -or -not $seen.Add([string]$item.identity)) { throw 'CI_DUPLICATE_ITEM' }
    }
    $import = [ordered]@{
      schemaVersion='controller-battery-ci-import/v1'; repository='chase-sets/chase-sets-controller'
      workflow='.github/workflows/controller-battery.yml'; runId=$runId; artifactId=[string]$artifact.id
      artifactPath=$archivePath; artifactSha256=$digest; checkoutHead=[string]$Prior.ci.checkoutHead
      controllerHead=[string]$Prior.controllerHead; productSha=[string]$Prior.ci.productSha
      importedUtc=[DateTime]::UtcNow.ToString('o')
    }
    $importPath = [IO.Path]::ChangeExtension($archivePath, '.import.json')
    [void](Assert-BatteryArtifactPath $importRoot $archivePath 'CI_ARTIFACT_PATH_INVALID')
    Invoke-BatteryArtifactWriteSeam $archivePath
    Write-BatteryArtifact $importRoot $archivePath 'CI_ARTIFACT_PATH_INVALID' $archiveBytes -CreateNew
    Confirm-BatteryArtifactWrite $importRoot $archivePath 'CI_ARTIFACT_PATH_INVALID'
    [void](Assert-BatteryArtifactPath $importRoot $importPath 'CI_ARTIFACT_PATH_INVALID')
    Invoke-BatteryArtifactWriteSeam $importPath
    Write-BatteryArtifact $importRoot $importPath 'CI_ARTIFACT_PATH_INVALID' ([Text.UTF8Encoding]::new($false).GetBytes(($import | ConvertTo-Json -Compress))) -CreateNew
    Confirm-BatteryArtifactWrite $importRoot $importPath 'CI_ARTIFACT_PATH_INVALID'
    return [pscustomobject]$import
  } finally {
    # Never delete through artifact paths that could have been swapped.
    [IO.File]::Delete($downloadPath)
  }
}

if ($ExpectedControllerHead -cnotmatch "^[a-f0-9]{40}$") {
  Stop-Battery "BATTERY_EXPECTED_HEAD_INVALID"
}
$liveHead = (& git -C $controller rev-parse HEAD 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $liveHead -cne $ExpectedControllerHead) {
  Stop-Battery "BATTERY_LIVE_HEAD_MOVED"
}

$hostIdentity = Get-BatteryHostIdentity

if (-not $ValidatePlanOnly) {
  if (-not $AdmissionOwned) {
    if (-not [string]::IsNullOrWhiteSpace([string]$env:CHASE_SETS_HEAVY_SLOT_ID)) {
      Stop-Battery "BATTERY_INHERITED_ADMISSION_FORBIDDEN"
    }
    $verifier = Join-Path $runtime "invoke-heavy-verifier.ps1"
    if (-not (Test-Path -LiteralPath $verifier -PathType Leaf) -or
        (Get-Item -LiteralPath $verifier -Force).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
      Stop-Battery "BATTERY_ADMISSION_WRAPPER_UNAVAILABLE"
    }
    $branch = (& git -C $controller branch --show-current 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($branch)) {
      Stop-Battery "BATTERY_BRANCH_IDENTITY_INVALID"
    }
    $lane = Split-Path -Leaf $controller
    & $verifier -ControllerBattery -Worktree $controller -Lane $lane -Branch $branch `
      -ClaimedHead $ExpectedControllerHead -ContainerRoot (Split-Path -Parent $controller) `
      -ControllerBatteryEvidenceReceiptPath $EvidenceReceiptPath `
      -ControllerBatteryResultPath $ResultPath `
      -ControllerBatteryBaselineHead $BaselineHead `
      -ControllerBatteryRepairIssue $RepairIssue `
      -ControllerBatteryRepairHistoryPath $RepairHistoryPath `
      -ControllerBatteryScope $Scope `
      -ControllerBatteryPriorResultPath $PriorResultPath `
      -ControllerBatteryNoReuseIdentity $NoReuseIdentity `
      -ControllerBatteryConcurrentIdentity $ConcurrentIdentity `
      -ControllerBatteryOnFailure $OnFailure
    exit $LASTEXITCODE
  }
  Assert-BatteryAdmission
  # BATTERY_ADMISSION_TEST_HOLD_SEAM
} elseif ($AdmissionOwned) {
  Stop-Battery "BATTERY_PLAN_ONLY_ADMISSION_FORBIDDEN"
}

# Fleet load observed once at admission (#8102); recorded in the plan line, the
# result record, and beside the per-item observation on every RESULT line.
$admissionFleetLoad = Get-BatteryFleetLoad

$treeOutput = & git -C $controller ls-tree -r --name-only $ExpectedControllerHead 2>&1
if ($LASTEXITCODE -ne 0) { Stop-Battery "BATTERY_PLAN_UNREADABLE" }
$tracked = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$treePaths = [string[]]@($treeOutput | ForEach-Object { ([string]$_).Replace("\", "/") })
foreach ($path in @($treeOutput)) {
  $normalized = ([string]$path).Replace("\", "/")
  if ($normalized -cmatch "^\.orchestrator/.+\.test\.ps1$" -or
      $normalized -cmatch "^\.orchestrator/issue-[^/]+-discriminator\.ps1$") {
    [void]$tracked.Add($normalized)
  }
}
$trackedPaths = [string[]]@($tracked)
[Array]::Sort($trackedPaths, [StringComparer]::Ordinal)

$batteryScope = "full"
$scopeReason = "no-baseline"
$batteryChanged = $false
$batteryImpact = $null
$referenceIndex = $null
$changedPaths = @()
if (-not [string]::IsNullOrWhiteSpace($BaselineHead)) {
  if ($BaselineHead -cnotmatch "^[a-f0-9]{40}$") { Stop-Battery "BATTERY_BASELINE_HEAD_INVALID" }
  & git -C $controller merge-base --is-ancestor $BaselineHead $ExpectedControllerHead 2>$null
  if ($LASTEXITCODE -ne 0) { Stop-Battery "BATTERY_BASELINE_NOT_ANCESTOR" }
  $repairContractRequested = $RepairIssue -gt 0 -or -not [string]::IsNullOrWhiteSpace($RepairHistoryPath)
  if ($repairContractRequested) {
    if ($RepairIssue -lt 1 -or [string]::IsNullOrWhiteSpace($RepairHistoryPath)) {
      Stop-Battery "BATTERY_REPAIR_CONTRACT_INCOMPLETE"
    }
    $resolvedRepairHistory = if ([IO.Path]::IsPathRooted($RepairHistoryPath)) {
      [IO.Path]::GetFullPath($RepairHistoryPath)
    } else { [IO.Path]::GetFullPath((Join-Path $controller $RepairHistoryPath)) }
    Import-Module (Join-Path $runtime "review-head-contract.psm1") -Force -DisableNameChecking
    $repairHistory = Read-ExactHeadReviewHistory -Path $resolvedRepairHistory
    if (-not $repairHistory.complete) { Stop-Battery "BATTERY_REPAIR_HISTORY_$($repairHistory.reason)" }
    $repairReceipts = @(Get-ControllerReviewClassifiedHistory -History $repairHistory | Where-Object {
        $_.classification.strict -and $_.classification.valid -and
        [int64]$_.classification.issue -eq $RepairIssue -and
        [string]$_.classification.controllerHead -ceq $BaselineHead -and
        $_.classification.rowKind -ceq "receipt" -and
        [string]$_.classification.reviewAuthority -ceq "governing"
      })
    if ($repairReceipts.Count -ne 1) { Stop-Battery "BATTERY_REPAIR_RECEIPT_AMBIGUOUS" }
    $repairReceipt = $repairReceipts[0].entry.value
    if ([string]$repairReceipt.outcome -cne "BLOCK_FIXABLE") { Stop-Battery "BATTERY_REPAIR_PREDECESSOR_NOT_BLOCK_FIXABLE" }
    if (@($repairReceipt.findingIds).Count -lt 1 -or
        @($repairReceipt.findingIds).Count -ne [int64]$repairReceipt.findings.blocking) {
      Stop-Battery "BATTERY_REPAIR_FINDINGS_MISSING"
    }
    Write-Output "REPAIR_INPUTS -RepairIssue=$RepairIssue -RepairHistoryPath=$RepairHistoryPath"
    Write-Output "REPAIR_RECEIPT issue=$RepairIssue head=$BaselineHead reviewerAttempt=$($repairReceipt.reviewerAttempt) findingIds=$(@($repairReceipt.findingIds) -join ',')"
  } else {
    $installedHead = ''
    try {
      $identityPath = Join-Path $SkillsRoot 'native-db/identity.json'
      $identity = Get-Content -LiteralPath $identityPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
      if ($identity -is [pscustomobject] -and @($identity.PSObject.Properties.Name).Count -eq 2 -and
          $identity.head -is [string] -and [string]$identity.head -cmatch '^[a-f0-9]{40}$' -and
          $identity.digest -is [string] -and [string]$identity.digest -cmatch '^[a-f0-9]{64}$') {
        $installedHead = [string]$identity.head
      }
    } catch {}
    if ($BaselineHead -cne $installedHead) { Stop-Battery 'BATTERY_BASELINE_NOT_INSTALLED' }
  }
  $diffOutput = & git -C $controller diff --no-renames --name-only "$BaselineHead..$ExpectedControllerHead" 2>&1
  if ($LASTEXITCODE -ne 0) { Stop-Battery "BATTERY_BASELINE_UNREADABLE" }
  $changedPaths = @($diffOutput | ForEach-Object { ([string]$_).Replace("\", "/").Trim() } | Where-Object { $_ })
  if ($Scope -ceq "full") {
    $scopeReason = "requested"
  } elseif ($changedPaths.Count -eq 0) {
    $scopeReason = "empty-diff"
  } else {
    # A battery change is proven by the battery's full self-test, whose
    # synthetic children drive every loop, reconcile, result and host path,
    # plus the impact of the change and of everything else changed. -Scope
    # full and the weekly host full battery remain the whole-inventory check.
    $batteryChanged = $changedPaths -ccontains ".orchestrator/controller-release-battery.ps1"
    $referenceIndex = New-BatteryReferenceIndex $treePaths
    $batteryImpact = Get-BatteryImpact $changedPaths $referenceIndex $trackedPaths $treePaths
    if ($batteryImpact.unreached.Count -gt 0) {
      $scopeReason = "unreached:" + ($batteryImpact.unreached -join ",")
    } else {
      $batteryScope = "impact"
      $scopeReason = if ($batteryChanged) { "battery-changed" } else { "reached" }
    }
  }
} elseif ($Scope -ceq "full") {
  $scopeReason = "requested"
}
if ($batteryScope -ceq "impact") {
  $impactTests = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($smokeTest in $batterySmokeTests) { [void]$impactTests.Add($smokeTest) }
  foreach ($impactTest in $batteryImpact.tests) { [void]$impactTests.Add($impactTest) }
  $trackedPaths = [string[]]@($trackedPaths | Where-Object {
      $_ -cmatch "^\.orchestrator/issue-[^/]+-discriminator\.ps1$" -or $impactTests.Contains($_)
    })
}

$requiredItems = [Collections.Generic.List[object]]::new()
$checkerPath = Join-Path $runtime "fail-closed-guard-evidence.test.ps1"
$resolvedReceipt = if ([string]::IsNullOrWhiteSpace($EvidenceReceiptPath)) {
  ""
} elseif ([IO.Path]::IsPathRooted($EvidenceReceiptPath)) {
  [IO.Path]::GetFullPath($EvidenceReceiptPath)
} else {
  [IO.Path]::GetFullPath((Join-Path $controller $EvidenceReceiptPath))
}
$directArgs = @(
  "-NoProfile", "-NonInteractive", "-File", $checkerPath,
  "-Scenario", "BypassMutants",
  "-ExpectedControllerHead", $ExpectedControllerHead
)
$requiredItems.Add((New-PlanItem "direct:fail-closed-guard-evidence" ".orchestrator/fail-closed-guard-evidence.ps1" $directArgs))

foreach ($path in $trackedPaths) {
  $absolute = Join-Path $controller $path
  if ($path -cmatch "^\.orchestrator/(issue-[^/]+)-discriminator\.ps1$") {
    $slug = $Matches[1]
    $identity = "discriminator:$slug"
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
      $absolute,
      [ref]$tokens,
      [ref]$parseErrors
    )
    if (@($parseErrors).Count -ne 0) {
      Stop-Battery "BATTERY_DISCRIMINATOR_INTERFACE_UNREADABLE:$slug"
    }
    $parameterNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($parameter in @($ast.ParamBlock.Parameters)) {
      [void]$parameterNames.Add($parameter.Name.VariablePath.UserPath)
    }
    if ($slug -ceq "issue-6254") {
      if (-not $parameterNames.Contains("ControllerRoot") -or
          -not $parameterNames.Contains("EvidenceReceiptPath") -or
          -not $parameterNames.Contains("ExpectedControllerHead")) {
        Stop-Battery "BATTERY_DISCRIMINATOR_INTERFACE_UNREADABLE:$slug"
      }
      $arguments = @(
        "-NoProfile", "-NonInteractive", "-File", $absolute,
        "-ControllerRoot", $controller,
        "-EvidenceReceiptPath", $resolvedReceipt,
        "-ExpectedControllerHead", $ExpectedControllerHead
      )
    } else {
      $arguments = @("-NoProfile", "-NonInteractive", "-File", $absolute)
      if ($parameterNames.Contains("ControllerRoot")) {
        $arguments += @("-ControllerRoot", $controller)
      } elseif ($parameterNames.Contains("RepositoryRoot")) {
        $arguments += @("-RepositoryRoot", $controller)
      }
    }
    $requiredItems.Add((New-PlanItem $identity $path $arguments))
    continue
  }

  $identity = "test:" + $path.Substring(".orchestrator/".Length)
  $arguments = @("-NoProfile", "-NonInteractive", "-File", $absolute)
  if ($path -ceq ".orchestrator/controller-release-battery.test.ps1" -and -not $batteryChanged) {
    $arguments += @("-ValidatePlanOnly")
  }
  $requiredItems.Add((New-PlanItem $identity $path $arguments))
}

$identitySet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($item in $requiredItems) {
  if (-not $identitySet.Add($item.identity)) { Stop-Battery "BATTERY_PLAN_DUPLICATE:$($item.identity)" }
}
foreach ($requiredDiscriminator in @("discriminator:issue-6254")) {
  if (-not $identitySet.Contains($requiredDiscriminator)) {
    Stop-Battery "BATTERY_DISCRIMINATOR_OMITTED:$($requiredDiscriminator.Substring('discriminator:'.Length))"
  }
}
# The reuse block below never lends a -NoReuseIdentity item.
$noReuseIdentities = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
if ($NoReuseIdentity.Length -gt 0) {
  foreach ($noReuse in $NoReuseIdentity.Split(';')) {
    if (-not $identitySet.Contains($noReuse)) { Stop-Battery "BATTERY_NO_REUSE_IDENTITY_UNKNOWN:$noReuse" }
    [void]$noReuseIdentities.Add($noReuse)
  }
}
# Concurrent items (#120). An entry must be a distinct test:* identity of a test
# file this battery knows at -Scope full; impact selection is applied at run time.
$concurrentIdentities = [Collections.Generic.List[string]]::new()
if ($ConcurrentIdentity.Length -gt 0) {
  $concurrentKnown = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($path in $tracked) {
    if ($path -cmatch '^\.orchestrator/.+\.test\.ps1$') { [void]$concurrentKnown.Add('test:' + $path.Substring('.orchestrator/'.Length)) }
  }
  $concurrentSegments = $ConcurrentIdentity.Split(';')
  if (@($concurrentSegments | Where-Object { $_.Length -eq 0 }).Count -gt 0) { Stop-Battery 'BATTERY_CONCURRENT_IDENTITY_EMPTY_SEGMENT' }
  if ($concurrentSegments.Count -gt 2) { Stop-Battery 'BATTERY_CONCURRENT_IDENTITY_LIMIT' }
  foreach ($segment in $concurrentSegments) {
    if ($segment -cnotlike 'test:*') { Stop-Battery "BATTERY_CONCURRENT_IDENTITY_NOT_TEST:$segment" }
    if (-not $concurrentKnown.Contains($segment)) { Stop-Battery "BATTERY_CONCURRENT_IDENTITY_UNKNOWN:$segment" }
    if ($concurrentIdentities.Contains($segment)) { Stop-Battery "BATTERY_CONCURRENT_IDENTITY_DUPLICATE:$segment" }
    $concurrentIdentities.Add($segment)
  }
}

$selectedItems = [Collections.Generic.List[object]]::new()
foreach ($item in $requiredItems) {
  if ($item.identity -ceq "direct:fail-closed-guard-evidence" -and
      -not $planInclusion["direct:fail-closed-guard-evidence"]) {
    continue
  }
  if ($item.identity -ceq "discriminator:issue-6254" -and
      -not $planInclusion["discriminator:issue-6254"]) {
    continue
  }
  $selectedItems.Add($item)
}

Write-Output "BATTERY_SCOPE scope=$batteryScope baseline=$(if ($BaselineHead) { $BaselineHead } else { 'none' }) changed=$($changedPaths.Count) reason=$scopeReason"
if ($null -ne $batteryImpact) {
  foreach ($path in @($batteryImpact.byPath.Keys | Where-Object { $_ -cmatch "^\.orchestrator/" })) {
    Write-Output "IMPACT path=$path tests=$(@($batteryImpact.byPath[$path] | ForEach-Object { $_.Substring('.orchestrator/'.Length) }) -join ',')"
  }
}
Write-Output "BATTERY_PLAN_BEGIN head=$ExpectedControllerHead required=$($requiredItems.Count) selected=$($selectedItems.Count) fleetLoad=$admissionFleetLoad"
foreach ($item in $requiredItems) {
  Write-Output "REQUIRED identity=$($item.identity) path=$($item.path)"
}
foreach ($item in $selectedItems) {
  Write-Output "PLAN identity=$($item.identity) command=$($item.command)"
}
Write-Output "BATTERY_PLAN_END"

if ($ValidatePlanOnly) {
  Write-Output "PASS controller release battery plan-only head=$ExpectedControllerHead required=$($requiredItems.Count)"
  return
}
$results = [Collections.Generic.List[object]]::new()
$resolvedResult = ""
if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
  try {
    $resolvedResult = if ([IO.Path]::IsPathRooted($ResultPath)) {
      [IO.Path]::GetFullPath($ResultPath)
    } else {
      [IO.Path]::GetFullPath((Join-Path $controller $ResultPath))
    }
    # The canonical root is the physical .orchestrator joined with artifacts, so
    # a link at artifacts itself is still refused below, before and after the
    # root is created; every later result and evidence path is checked against it.
    $artifactRoot = Join-Path (Resolve-BatteryPhysicalPath $runtime) "artifacts"
    $artifactRoot = Assert-BatteryArtifactPath $artifactRoot $artifactRoot "BATTERY_RESULT_PATH_INVALID"
    $resultDirectory = Split-Path -Parent $resolvedResult
    $resultDirectory = Join-Path (Resolve-BatteryPhysicalPath (Split-Path -Parent $resultDirectory)) (Split-Path -Leaf $resultDirectory)
    if ($resultDirectory.TrimEnd("\", "/") -cne $artifactRoot) { Stop-Battery "BATTERY_RESULT_PATH_INVALID" }
    $resolvedResult = Join-Path $artifactRoot ([IO.Path]::GetFileName($resolvedResult))
    $rawPath = [IO.Path]::ChangeExtension($resolvedResult, ".log")
    if ((Test-SameBatteryPath $resolvedResult $rawPath) -or
        [IO.Path]::GetFileName($resolvedResult).IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
      Stop-Battery "BATTERY_RESULT_PATH_INVALID"
    }
    foreach ($outputPath in @($resolvedResult, $rawPath, [IO.Path]::ChangeExtension($resolvedResult, ".timing.txt"))) {
      if ((Test-Path -LiteralPath $outputPath) -and
          ((Get-Item -LiteralPath $outputPath -Force).PSIsContainer -or
           (Get-Item -LiteralPath $outputPath -Force).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint))) {
        Stop-Battery "BATTERY_RESULT_PATH_INVALID"
      }
    }
    Invoke-BatteryArtifactWriteSeam $artifactRoot
    Write-BatteryArtifact $artifactRoot $artifactRoot "BATTERY_RESULT_PATH_INVALID" -Directory
    [void](Assert-BatteryArtifactPath $artifactRoot $artifactRoot "BATTERY_RESULT_PATH_INVALID")
  } catch {
    Stop-Battery "BATTERY_RESULT_PATH_INVALID"
  }
}

# Reuse (#8207). A prior result from this worktree lends its PASS test items to
# this run when the prior head is an ancestor, the host binary and raw log still
# match, the item ran within 24 hours, and the prior..candidate diff reaches
# neither the item nor anything it references. Under either prior, guards and
# -NoReuseIdentity items always execute (#9373).
# CI priors replace that host/path anchor with authenticated GitHub bytes;
# fresh, argument/scope-equivalent items may be carried across an empty impact.
$reusable = @{}
$priorOrder = @{}
if (-not [string]::IsNullOrWhiteSpace($PriorResultPath)) {
  $priorFailure = $null
  try {
    $resolvedPrior = if ([IO.Path]::IsPathRooted($PriorResultPath)) { [IO.Path]::GetFullPath($PriorResultPath) } else { [IO.Path]::GetFullPath((Join-Path $controller $PriorResultPath)) }
    $priorArtifactRoot = [IO.Path]::GetFullPath((Join-Path $runtime "artifacts")).TrimEnd("\", "/")
    if (-not (Test-Path -LiteralPath $resolvedPrior -PathType Leaf)) { throw "PATH" }
    $priorBytes = [IO.File]::ReadAllBytes($resolvedPrior)
    $prior = [Text.Encoding]::UTF8.GetString($priorBytes) | ConvertFrom-Json -DateKind String -ErrorAction Stop
    if ($prior.schemaVersion -cne "controller-battery-result/v1" -or [string]$prior.controllerHead -cnotmatch "^[a-f0-9]{40}$") { throw "SCHEMA" }
    $isCiPrior = $null -ne $prior.PSObject.Properties['ci']
    if (-not $isCiPrior -and (Split-Path -Parent $resolvedPrior).TrimEnd("\", "/") -cne $priorArtifactRoot) { throw "PATH" }
    & git -C $controller merge-base --is-ancestor $prior.controllerHead $ExpectedControllerHead 2>$null
    if ($LASTEXITCODE -ne 0) { throw "NOT_ANCESTOR" }
    $ciImport = $null
    if ($isCiPrior) {
      $ciImport = Import-BatteryCiPrior $prior $priorBytes
    } else {
      if ([string]$hostIdentity.sha256 -ceq "unavailable" -or [string]$prior.hostIdentity.sha256 -cne [string]$hostIdentity.sha256) { throw "HOST_CHANGED" }
      $priorRawPath = Join-Path $controller ([string]$prior.rawLog.relativePath)
      $priorRawHash = ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($priorRawPath)))).ToLowerInvariant()
      if ($priorRawHash -cne [string]$prior.rawLog.sha256) { throw "RAW_LOG_MISMATCH" }
    }
    $priorResultHash = ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($priorBytes))).ToLowerInvariant()
    $priorDiff = @(& git -C $controller diff --no-renames --name-only "$($prior.controllerHead)..$ExpectedControllerHead" 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "DIFF_UNREADABLE" }
    $priorDiff = @($priorDiff | ForEach-Object { ([string]$_).Replace("\", "/").Trim() } | Where-Object { $_ })
    $priorImpactTests = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    if ($priorDiff.Count -gt 0) {
      if (-not $isCiPrior -and $priorDiff -ccontains ".orchestrator/controller-release-battery.ps1") { throw "BATTERY_CHANGED" }
      if ($null -eq $referenceIndex) { $referenceIndex = New-BatteryReferenceIndex $treePaths }
      $priorImpact = Get-BatteryImpact $priorDiff $referenceIndex ([string[]]@($tracked)) $treePaths
      if ($priorImpact.unreached.Count -gt 0) {
        if (-not $isCiPrior) { throw "UNREACHED" }
        # The existing conservative fallback is the whole selected inventory.
        foreach ($item in $selectedItems) { [void]$priorImpactTests.Add($item.path) }
      }
      foreach ($impactTest in $priorImpact.tests) { [void]$priorImpactTests.Add($impactTest) }
      if ($isCiPrior -and $priorDiff -ccontains '.orchestrator/controller-release-battery.ps1') {
        [void]$priorImpactTests.Add('.orchestrator/controller-release-battery.test.ps1')
      }
    }
    $cutoff = [DateTimeOffset]::UtcNow.AddHours(-24)
    foreach ($row in @($prior.results)) {
      $priorOrder[[string]$row.identity] = [long]$row.elapsedMs
      $item = @($selectedItems | Where-Object { $_.identity -ceq [string]$row.identity })
      if ($item.Count -ne 1 -or [string]$row.result -cne "PASS" -or $row.exitCode -ne 0 -or
          $priorImpactTests.Contains($item[0].path)) { continue }
      # Guards (direct:*, discriminator:*) and -NoReuseIdentity items execute.
      if ($item[0].identity -cnotlike 'test:*' -or $noReuseIdentities.Contains($item[0].identity)) { continue }
      $ranAt = [DateTimeOffset]::MinValue
      if (-not [DateTimeOffset]::TryParse([string]$row.startedUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$ranAt) -or
          $ranAt -lt $cutoff) { continue }
      if ($isCiPrior) {
        $ciItem = @($prior.inventory | Where-Object { $_.identity -ceq $row.identity })
        if ($ciItem.Count -ne 1 -or $ciItem[0].path -cne $item[0].path -or
            $prior.scope.kind -cnotin @('full', 'impact') -or $prior.scope.kind -cne $batteryScope -or
            -not (Test-BatteryCiArguments $ciItem[0].arguments $item[0].arguments $prior)) { continue }
        $restricted = $null -ne $ciItem[0].restriction -or $row.identity -cin @($prior.ci.notHermetic)
        $localOnly = $row.identity -cin @($prior.ci.localOnly | ForEach-Object { if ($_ -is [string]) { $_ } else { $_.identity } })
        $loaded = [string]$row.fleetLoad -cne 'none'
        if ($restricted -or $localOnly -or $loaded -or [string]$row.provenance.kind -cne 'execution') { continue }
      } else {
        if ($item[0].identity -ceq 'test:controller-release-battery.test.ps1') { continue }
      }
      $reusable[$item[0].identity] = [pscustomobject]@{
        row = $row; priorHead = [string]$prior.controllerHead; priorResultSha256 = $priorResultHash
        ciImport = $ciImport
      }
    }
  } catch {
    $priorFailure = if ($_.Exception.Message -cmatch "^[A-Z_]+$") { $_.Exception.Message } else { "UNREADABLE" }
  }
  if ($priorFailure) { Stop-Battery "BATTERY_PRIOR_RESULT_INVALID:$priorFailure" }
  $reuseSource = if ($isCiPrior) { "ci:$($ciImport.runId)" } else { 'local' }
  Write-Output "REUSE prior=$($prior.controllerHead) reusable=$($reusable.Count) of=$($selectedItems.Count) source=$reuseSource"
}
# Fast items run first so an early failure is seen early. Timings come from the
# prior result, else from the newest battery result in this worktree's
# artifacts; they order execution only and never affect a verdict.
if ($priorOrder.Count -eq 0) {
  try {
    # Test carriers write thousands of other JSON artifacts here; a 64-byte
    # prefix read finds the newest battery result without parsing them.
    $resultPrefix = '{"schemaVersion":"controller-battery-result/v1"'
    $timingSource = $null
    foreach ($candidateFile in @(Get-ChildItem -LiteralPath (Join-Path $runtime "artifacts") -Filter "*.json" -File -ErrorAction Stop |
        Sort-Object LastWriteTimeUtc -Descending)) {
      $prefix = [byte[]]::new(64)
      $stream = [IO.File]::OpenRead($candidateFile.FullName)
      try { $read = $stream.Read($prefix, 0, 64) } finally { $stream.Dispose() }
      if ([Text.Encoding]::UTF8.GetString($prefix, 0, $read).StartsWith($resultPrefix, [StringComparison]::Ordinal)) {
        $timingSource = Get-Content -LiteralPath $candidateFile.FullName -Raw | ConvertFrom-Json -DateKind String -ErrorAction Stop
        break
      }
    }
    foreach ($row in @($timingSource.results)) { $priorOrder[[string]$row.identity] = [long]$row.elapsedMs }
  } catch {}
}
$executionItems = if ($priorOrder.Count -gt 0) {
  @($selectedItems | Sort-Object -Stable -Property @{ Expression = { if ($priorOrder.ContainsKey($_.identity)) { $priorOrder[$_.identity] } else { 0 } } })
} else { @($selectedItems) }

# Impact runs tell children which orchestrator files changed, so proof arms
# whose guarded file is unchanged may skip (support Test-BatteryProofRelevant).
# A full run clears it and every arm executes.
$env:CHASE_SETS_BATTERY_IMPACT_PATHS = if ($batteryScope -ceq "impact") {
  (@($changedPaths | Where-Object { $_ -cmatch "^\.orchestrator/" }) -join ";")
} else { $null }
if ($batteryScope -ceq "impact" -and [string]::IsNullOrEmpty($env:CHASE_SETS_BATTERY_IMPACT_PATHS)) { $env:CHASE_SETS_BATTERY_IMPACT_PATHS = "none" }

$batteryStartedUtc = [DateTime]::UtcNow.ToString("o")
$batteryClock = [Diagnostics.Stopwatch]::StartNew()
$executionStarted = $false
$batteryFailure = $null
$failureCode = $null
$batteryOutcome = "FAIL"
# Baseline classification (#8207, #98). A failed test item is re-run once on the
# installed baseline in a temporary detached worktree, as soon as it fails. The
# same exit code and the same nonempty normalized failure lines make it
# PREEXISTING. Any other nonzero baseline exit is BASELINE_ALSO_FAILS: evidence
# for the host's decision row, never PASS, PREEXISTING or installable by itself.
# A baseline pass or an item absent at the baseline is a REGRESSION. The run
# continues past PREEXISTING and BASELINE_ALSO_FAILS. Repair baselines are
# unreviewed candidates and are never used.
$baselineRoot = $null
$baselineCreated = $false
# With a result path, each item the baseline actually ran keeps its baseline
# stdout, stderr, exit code and both normalized signatures as files referenced
# from its result row. Retention is evidence only; classification never reads it.
$baselineEvidenceRoot = $null
$baselineEvidenceCount = 0
function Save-BatteryBaselineEvidence([string]$Directory, [string]$Name, [string]$Text, [string]$Identity) {
  $evidencePath = Assert-BatteryArtifactPath $artifactRoot (Join-Path $Directory $Name) "BATTERY_BASELINE_EVIDENCE_PATH_INVALID:$Identity"
  $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
  Invoke-BatteryArtifactWriteSeam $evidencePath
  # CreateNew: retained evidence is never truncated or overwritten.
  Write-BatteryArtifact $artifactRoot $evidencePath "BATTERY_BASELINE_EVIDENCE_PATH_INVALID:$Identity" $bytes -CreateNew
  Confirm-BatteryArtifactWrite $artifactRoot $evidencePath "BATTERY_BASELINE_EVIDENCE_PATH_INVALID:$Identity"
  return [ordered]@{
    # Relative to the canonical root, which may differ from the controller path.
    relativePath = ".orchestrator/artifacts/" + [IO.Path]::GetRelativePath($artifactRoot, $evidencePath).Replace("\", "/")
    byteLength = $bytes.Length
    sha256 = ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))).ToLowerInvariant()
  }
}
function Invoke-BatteryBaselineClassification($Failed, $Item) {
  $classification = "REGRESSION"
  $baselineExit = $null
  $evidence = $null
  if (-not $script:baselineRoot) {
    $script:baselineRoot = Join-Path (Split-Path -Parent $controller) ("{0}-battery-baseline-{1}-{2}" -f [DateTime]::UtcNow.ToString("yyyyMMdd"), $BaselineHead.Substring(0, 12), $PID)
    & git -C $controller worktree add --detach --quiet $script:baselineRoot $BaselineHead 2>&1 | Out-Null
    $script:baselineCreated = $LASTEXITCODE -eq 0
  }
  & git -C $controller cat-file -e "$($BaselineHead):$($Item.path)" 2>$null
  if (-not $script:baselineCreated) {
    $classification = "UNCLASSIFIED"
  } elseif ($LASTEXITCODE -eq 0) {
    $baselineArguments = @($Item.arguments | ForEach-Object {
        if (Test-SameBatteryPath $_ $controller) { $script:baselineRoot }
        elseif ($_ -is [string] -and $_.StartsWith($controller, [StringComparison]::OrdinalIgnoreCase)) { $script:baselineRoot + $_.Substring($controller.Length) }
        else { $_ }
      })
    $baselineRecords = @(& $Item.executable @baselineArguments 2>&1)
    $baselineExit = $LASTEXITCODE
    $baselineOutput = $baselineRecords | Out-String
    $candidateSignature = Get-BatteryFailureSignature $Failed.output $controller
    $baselineSignature = Get-BatteryFailureSignature $baselineOutput $script:baselineRoot
    if ($baselineExit -eq $Failed.exitCode -and $candidateSignature -and $candidateSignature -ceq $baselineSignature) {
      $classification = "PREEXISTING"
    } elseif ($null -ne $baselineExit -and $baselineExit -ne 0) {
      $classification = "BASELINE_ALSO_FAILS"
    }
    if ($resolvedResult) {
      if (-not $script:baselineEvidenceRoot) {
        $script:baselineEvidenceRoot = Join-Path $artifactRoot ("{0}.baseline-{1}" -f [IO.Path]::GetFileNameWithoutExtension($resolvedResult), [guid]::NewGuid().ToString("N").Substring(0, 12))
      }
      $script:baselineEvidenceCount++
      $itemDirectory = Join-Path $script:baselineEvidenceRoot ("{0:D3}-{1}" -f $script:baselineEvidenceCount, ($Failed.identity -creplace '[^A-Za-z0-9._-]', '-'))
      # The root may have been swapped for a link since validation: recheck the
      # whole chain before the directory is created and again before any file.
      $evidenceCode = "BATTERY_BASELINE_EVIDENCE_PATH_INVALID:$($Failed.identity)"
      $itemDirectory = Assert-BatteryArtifactPath $artifactRoot $itemDirectory $evidenceCode
      if (Test-Path -LiteralPath $itemDirectory) { throw "BATTERY_BASELINE_EVIDENCE_EXISTS:$($Failed.identity)" }
      Invoke-BatteryArtifactWriteSeam $itemDirectory
      Write-BatteryArtifact $artifactRoot $itemDirectory $evidenceCode -Directory
      [void](Assert-BatteryArtifactPath $artifactRoot $itemDirectory $evidenceCode)
      # Native stderr lines arrive as ErrorRecords; each stream is kept in order,
      # one LF between lines, apart from the merged text the signature reads.
      $stdoutText = @($baselineRecords | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ }) -join "`n"
      $stderrText = @($baselineRecords | Where-Object { $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { $_.ToString() }) -join "`n"
      $evidence = [ordered]@{
        kind = "baseline-streams"
        stdout = Save-BatteryBaselineEvidence $itemDirectory "stdout.txt" $stdoutText $Failed.identity
        stderr = Save-BatteryBaselineEvidence $itemDirectory "stderr.txt" $stderrText $Failed.identity
        exitCode = Save-BatteryBaselineEvidence $itemDirectory "exit-code.txt" ([string]$baselineExit) $Failed.identity
        candidateSignature = Save-BatteryBaselineEvidence $itemDirectory "candidate-signature.txt" $candidateSignature $Failed.identity
        baselineSignature = Save-BatteryBaselineEvidence $itemDirectory "baseline-signature.txt" $baselineSignature $Failed.identity
      }
    }
  }
  $baselineRow = [ordered]@{ head = $BaselineHead; classification = $classification; exitCode = $baselineExit }
  if ($null -ne $evidence) { $baselineRow.evidence = $evidence }
  $Failed | Add-Member -NotePropertyName baseline -NotePropertyValue $baselineRow
  $evidenceField = if ($null -ne $evidence) { " evidence=" + (Split-Path -Parent $evidence.stdout.relativePath).Replace("\", "/") } else { "" }
  Write-Output "BASELINE identity=$($Failed.identity) classification=$classification baseline=$BaselineHead baselineExit=$baselineExit$evidenceField"
}

# Concurrent items (#120). A listed item starts as a child with the serial
# path's executable, arguments, environment and working directory; priority is
# inherited, stdin is closed and both streams are read asynchronously to
# completion, so a child writing megabytes to either stream never blocks on a
# full pipe. Each child's PID and start time are recorded at start so an abort
# kills only trees this battery started. Children never take an admission slot.
function Start-BatteryConcurrentItem($Item, $Children) {
  $fleet = New-BatteryFleetSampler $Item.identity (Get-BatteryFleetLoad -Holder)
  $handle = [pscustomobject]@{
    item = $Item; process = $null; processId = 0; startTicks = 0L; stdout = $null; stderr = $null
    fleet = $fleet; fleetLoad = $fleet.summary; startedUtc = [DateTime]::UtcNow.ToString("o")
    clock = [Diagnostics.Stopwatch]::StartNew(); startError = $null; collected = $false
  }
  $Children.Add($handle)
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = $Item.executable
  foreach ($argument in @($Item.arguments)) { $start.ArgumentList.Add([string]$argument) }
  $start.WorkingDirectory = (Get-Location -PSProvider FileSystem).ProviderPath
  $start.UseShellExecute = $false
  $start.CreateNoWindow = $true
  $start.RedirectStandardInput = $true
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $start
  try {
    [void]$process.Start()
  } catch {
    $handle.clock.Stop()
    $startException = $_.Exception
    while ($null -ne $startException.InnerException) { $startException = $startException.InnerException }
    $handle.startError = $startException.Message
    $process.Dispose()
    return $handle
  }
  $handle.process = $process
  $handle.processId = $process.Id
  $handle.startTicks = $process.StartTime.ToUniversalTime().Ticks
  $handle.stdout = $process.StandardOutput.ReadToEndAsync()
  $handle.stderr = $process.StandardError.ReadToEndAsync()
  $process.StandardInput.Close()
  Start-BatteryFleetSampler $fleet $process
  return $handle
}

# $null while the child runs (unless -Wait); otherwise its exit code, whole
# stdout then stderr, and the OS-recorded exit instant and duration.
function Read-BatteryConcurrentExit($Handle, [switch]$Wait) {
  if (-not $Wait -and -not $Handle.process.HasExited) { return $null }
  $stdout = $Handle.stdout.GetAwaiter().GetResult()
  $stderr = $Handle.stderr.GetAwaiter().GetResult()
  $Handle.process.WaitForExit()
  $exitTime = $Handle.process.ExitTime.ToUniversalTime()
  return [pscustomobject]@{
    exitCode = $Handle.process.ExitCode
    output = @(@($stdout, $stderr) | Where-Object { -not [string]::IsNullOrEmpty($_) }) -join "`n"
    finishedUtc = $exitTime.ToString("o")
    elapsedMs = [long][Math]::Max(0, [Math]::Round(($exitTime - $Handle.process.StartTime.ToUniversalTime()).TotalMilliseconds))
  }
}

# Records a finished (or, with -Wait, drained) child exactly once as a result row
# under the serial result rules. A failed start is a FAIL row with exit code -1.
function Receive-BatteryConcurrentItem($Handle, [switch]$Wait) {
  if ($Handle.collected) { return }
  $item = $Handle.item
  if ($null -ne $Handle.startError) {
    $exit = [pscustomobject]@{
      exitCode = -1; output = "BATTERY_CONCURRENT_START_FAILED: $($Handle.startError)"
      finishedUtc = [DateTime]::UtcNow.ToString("o"); elapsedMs = $Handle.clock.ElapsedMilliseconds
    }
  } else {
    $exit = Read-BatteryConcurrentExit $Handle -Wait:$Wait
    if ($null -eq $exit) { return }
  }
  $Handle.collected = $true
  $itemFleetSampling = Complete-BatteryFleetSampler $Handle.fleet
  $measuredLoad = ($exit.exitCode -eq 75) -and ($exit.output -cmatch '(?m)^MEASURED_LOAD ')
  $result = [pscustomobject][ordered]@{
    identity = $item.identity
    command = $item.command
    exitCode = $exit.exitCode
    result = if ($exit.exitCode -eq 0) { "PASS" } elseif ($measuredLoad) { "MEASURED_LOAD" } else { "FAIL" }
    fleetLoad = $Handle.fleetLoad
    startedUtc = $Handle.startedUtc
    finishedUtc = $exit.finishedUtc
    elapsedMs = [long]$exit.elapsedMs
    output = ([string]$exit.output).Trim()
    provenance = [ordered]@{kind='execution';command=$item.command;attempt='local-battery';source='local'}
    fleetSampling = $itemFleetSampling
  }
  $results.Add($result)
  Add-BatteryTimingLines $result.identity @("ITEM $($result.identity) elapsedMs=$($result.elapsedMs) concurrent=1")
  $lines = [Collections.Generic.List[string]]::new()
  $lines.Add("RESULT identity=$($result.identity) exitCode=$($result.exitCode) result=$($result.result) fleetLoad=$($result.fleetLoad) startedUtc=$($result.startedUtc) finishedUtc=$($result.finishedUtc) elapsedMs=$($result.elapsedMs)")
  if ($result.output) {
    foreach ($line in @($result.output -split "\r?\n")) { $lines.Add("CHILD identity=$($result.identity) $line") }
  }
  Write-BatteryItemLines $result.identity $lines
  return [pscustomobject]@{ result = $result; item = $item; startFailed = $null -ne $Handle.startError }
}

# Collects exited children (every child with -Drain). A child FAIL with a
# baseline pauses: no serial item starts, every child drains, then each failed
# child is classified in inventory order. Returns the identity that stops new
# serial items (the first stopping failure in inventory order), or $null.
function Invoke-BatteryConcurrentCheckpoint([switch]$Drain, [bool]$Stopped) {
  $failed = [Collections.Generic.List[object]]::new()
  foreach ($handle in @($concurrentChildren)) {
    $received = Receive-BatteryConcurrentItem $handle -Wait:$Drain
    if ($null -ne $received -and $received.result.result -ceq "FAIL") { $failed.Add($received) }
  }
  if ($failed.Count -eq 0) { return $null }
  $byInventory = @{ Expression = { $inventoryIndex[$_.item.identity] } }
  if ($BaselineHead -and $RepairIssue -eq 0 -and -not $Stopped) {
    foreach ($handle in @($concurrentChildren)) {
      $received = Receive-BatteryConcurrentItem $handle -Wait
      if ($null -ne $received -and $received.result.result -ceq "FAIL") { $failed.Add($received) }
    }
    foreach ($received in @($failed | Sort-Object -Stable -Property $byInventory)) {
      if ($received.startFailed) { continue }
      Write-BatteryItemLines $received.item.identity @(Invoke-BatteryBaselineClassification $received.result $received.item)
    }
  }
  $stopping = @($failed | Where-Object {
      -not ($null -ne $_.result.PSObject.Properties["baseline"] -and $_.result.baseline.classification -cin @("PREEXISTING", "BASELINE_ALSO_FAILS"))
    } | Sort-Object -Stable -Property $byInventory)
  if ($OnFailure -ceq "stop" -and $stopping.Count -gt 0) { return $stopping[0].item.identity }
  return $null
}

function Get-BatteryProcessStartTicks([int]$ProcessId) {
  try { return [Diagnostics.Process]::GetProcessById($ProcessId).StartTime.ToUniversalTime().Ticks } catch { return $null }
}

# One Win32_Process snapshot followed by ParentProcessId from the child, keeping
# only descendants created at or after their parent, so a recycled parent id is
# never followed. Each kept descendant is recorded as (PID, start ticks).
function Get-BatteryConcurrentDescendants([int]$RootId) {
  $snapshot = @(Get-CimInstance -ClassName Win32_Process -Property ProcessId, ParentProcessId, CreationDate -ErrorAction Stop)
  $byParent = @{}
  $created = @{}
  foreach ($entry in $snapshot) {
    $created[[int]$entry.ProcessId] = $entry.CreationDate
    $parentId = [int]$entry.ParentProcessId
    if (-not $byParent.ContainsKey($parentId)) { $byParent[$parentId] = [Collections.Generic.List[object]]::new() }
    $byParent[$parentId].Add($entry)
  }
  $tuples = [Collections.Generic.List[object]]::new()
  if (-not $created.ContainsKey($RootId)) { return }
  $seen = [Collections.Generic.HashSet[int]]::new()
  [void]$seen.Add($RootId)
  $queue = [Collections.Generic.Queue[object]]::new()
  $queue.Enqueue([pscustomobject]@{ processId = $RootId; depth = 0 })
  while ($queue.Count -gt 0) {
    $parent = $queue.Dequeue()
    if (-not $byParent.ContainsKey($parent.processId)) { continue }
    $parentCreated = $created[$parent.processId]
    foreach ($entry in $byParent[$parent.processId]) {
      $childId = [int]$entry.ProcessId
      if ($null -eq $parentCreated -or $null -eq $entry.CreationDate -or $entry.CreationDate -lt $parentCreated) { continue }
      if (-not $seen.Add($childId)) { continue }
      $ticks = Get-BatteryProcessStartTicks $childId
      if ($null -eq $ticks) { continue }
      $tuple = [pscustomobject]@{ processId = $childId; startTicks = [long]$ticks; depth = $parent.depth + 1 }
      $tuples.Add($tuple)
      $queue.Enqueue($tuple)
    }
  }
  return $tuples
}

# Re-reads the tuple immediately before its kill; another start time is another
# process and is skipped. A process that exits meanwhile is not an error.
function Stop-BatteryProcessTuple([int]$ProcessId, [long]$StartTicks) {
  try {
    $process = [Diagnostics.Process]::GetProcessById($ProcessId)
    if ($process.StartTime.ToUniversalTime().Ticks -ne $StartTicks) { return $false }
    $process.Kill()
    return $true
  } catch {
    return $false
  }
}

# Kills one started child's tree, deepest first, then the child. A child whose
# PID now has another start time is not this battery's: nothing is killed for
# it. A failed walk still kills the child itself.
function Stop-BatteryConcurrentTree($Handle) {
  $outcome = [pscustomobject]@{ killed = [Collections.Generic.List[string]]::new(); walk = "ok" }
  $liveTicks = Get-BatteryProcessStartTicks $Handle.processId
  if ($null -eq $liveTicks -or $liveTicks -ne $Handle.startTicks) { $outcome.walk = "not-owned"; return $outcome }
  $descendants = @()
  try { $descendants = @(Get-BatteryConcurrentDescendants $Handle.processId) }
  catch { $outcome.walk = "error:" + ($_.Exception.Message -creplace '\s+', '_') }
  # The child may have exited and its PID been reused between the check above and
  # the snapshot, so the walk may have collected a foreign tree. A live child with
  # the recorded start time now proves the snapshot saw this battery's child.
  $afterTicks = Get-BatteryProcessStartTicks $Handle.processId
  if ($null -eq $afterTicks -or $afterTicks -ne $Handle.startTicks) { $outcome.walk = "not-owned-after-walk"; return $outcome }
  foreach ($tuple in @($descendants | Sort-Object -Property depth -Descending -Stable)) {
    if (Stop-BatteryProcessTuple $tuple.processId $tuple.startTicks) { $outcome.killed.Add("$($tuple.processId)@$($tuple.startTicks)") }
  }
  if (Stop-BatteryProcessTuple $Handle.processId $Handle.startTicks) { $outcome.killed.Add("$($Handle.processId)@$($Handle.startTicks)") }
  return $outcome
}

# Abort cleanup, at most once per run: each child still running is killed with
# its own tree and goes to NOT_RUN; a child that already exited is recorded.
# Returns the CONCURRENT_ABORT lines; kills happen before any output.
function Stop-BatteryConcurrentChildren {
  $lines = [Collections.Generic.List[string]]::new()
  if ($concurrentState.cleanupRan) { return ,$lines }
  $concurrentState.cleanupRan = $true
  foreach ($handle in @($concurrentChildren)) {
    if ($handle.collected) { continue }
    if ($null -ne $handle.startError -or ($handle.process.HasExited -and $handle.stdout.IsCompleted -and $handle.stderr.IsCompleted)) {
      [void](Receive-BatteryConcurrentItem $handle -Wait)
      continue
    }
    $handle.collected = $true
    $outcome = if ($handle.process.HasExited) {
      [pscustomobject]@{ killed = @(); walk = "exited" }
    } else { Stop-BatteryConcurrentTree $handle }
    $notRun.Add($handle.item.identity)
    $concurrentState.aborted = $true
    $lines.Add("CONCURRENT_ABORT identity=$($handle.item.identity) pid=$($handle.processId) walk=$($outcome.walk) killed=$(@($outcome.killed) -join ',')")
  }
  return ,$lines
}

# Serial mode writes item lines at once; concurrent mode defers them per item.
function Write-BatteryItemLines([string]$Identity, $Lines) {
  if ($null -eq $deferredItemLines) {
    foreach ($line in @($Lines)) { Write-Output $line }
    return
  }
  if (-not $deferredItemLines.ContainsKey($Identity)) { $deferredItemLines[$Identity] = [Collections.Generic.List[string]]::new() }
  foreach ($line in @($Lines)) { $deferredItemLines[$Identity].Add([string]$line) }
}

function Add-BatteryTimingLines([string]$Identity, $Lines) {
  if ($null -eq $deferredTimingLines) {
    foreach ($line in @($Lines)) { $timingLines.Add([string]$line) }
    return
  }
  if (-not $deferredTimingLines.ContainsKey($Identity)) { $deferredTimingLines[$Identity] = [Collections.Generic.List[string]]::new() }
  foreach ($line in @($Lines)) { $deferredTimingLines[$Identity].Add([string]$line) }
}

# After every child has drained: results, RESULT/CHILD/BASELINE lines and
# timing lines in inventory order, independent of completion order.
function Write-BatteryDeferredLines {
  if ($null -eq $deferredItemLines) { return }
  $ordered = @($results | Sort-Object -Stable -Property @{ Expression = {
        if ($inventoryIndex.ContainsKey($_.identity)) { $inventoryIndex[$_.identity] } else { [int]::MaxValue } } })
  $results.Clear()
  foreach ($result in $ordered) { $results.Add($result) }
  foreach ($inventoryItem in $requiredItems) {
    if ($deferredTimingLines.ContainsKey($inventoryItem.identity)) {
      foreach ($line in $deferredTimingLines[$inventoryItem.identity]) { $timingLines.Add($line) }
    }
    if ($deferredItemLines.ContainsKey($inventoryItem.identity)) {
      foreach ($line in $deferredItemLines[$inventoryItem.identity]) { Write-Output $line }
    }
  }
  $deferredTimingLines.Clear()
  $deferredItemLines.Clear()
}

$timingLines = [Collections.Generic.List[string]]::new()
$fleetSampling = @{ host = $null }
$stoppedAt = $null
$notRun = [Collections.Generic.List[string]]::new()
$concurrentMode = $null -ne $concurrentIdentities -and $concurrentIdentities.Count -gt 0
$concurrentChildren = [Collections.Generic.List[object]]::new()
$concurrentStarted = [Collections.Generic.List[string]]::new()
$concurrentState = [pscustomobject]@{ cleanupRan = $false; aborted = $false }
$concurrentAbortLines = @()
$deferredItemLines = $null
$deferredTimingLines = $null
$inventoryIndex = @{}
if ($concurrentMode) {
  $deferredItemLines = [Collections.Generic.Dictionary[string, Collections.Generic.List[string]]]::new([StringComparer]::Ordinal)
  $deferredTimingLines = [Collections.Generic.Dictionary[string, Collections.Generic.List[string]]]::new([StringComparer]::Ordinal)
  for ($index = 0; $index -lt $requiredItems.Count; $index++) { $inventoryIndex[$requiredItems[$index].identity] = $index }
}
try {
  if ($concurrentMode) {
    $executionIdentities = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($item in $executionItems) { [void]$executionIdentities.Add($item.identity) }
    foreach ($identity in $concurrentIdentities) {
      if (-not $executionIdentities.Contains($identity)) { Write-Output "CONCURRENT_SKIP identity=$identity reason=not-selected" }
    }
    # Listed items start at loop start. A reused listed item keeps its reuse row
    # in the serial loop and is never started.
    foreach ($item in $executionItems) {
      if (-not $concurrentIdentities.Contains($item.identity) -or $reusable.ContainsKey($item.identity)) { continue }
      $executionStarted = $true
      $handle = Start-BatteryConcurrentItem $item $concurrentChildren
      if ($null -eq $handle.startError) {
        $concurrentStarted.Add($item.identity)
        Write-Output "CONCURRENT_START identity=$($item.identity) pid=$($handle.processId) startedUtc=$($handle.startedUtc) fleetLoad=$($handle.fleetLoad)"
      }
    }
  }
  foreach ($item in $executionItems) {
    if (@($concurrentChildren | Where-Object { $_.item.identity -ceq $item.identity }).Count -gt 0) { continue }
    if ($concurrentChildren.Count -gt 0 -and $null -eq $stoppedAt) {
      $concurrentStop = Invoke-BatteryConcurrentCheckpoint -Stopped $false
      if ($null -ne $concurrentStop) { $stoppedAt = $concurrentStop }
    }
    if ($null -ne $stoppedAt) { $notRun.Add($item.identity); continue }
    if ($reusable.ContainsKey($item.identity)) {
      $reuse = $reusable[$item.identity]
      $result = [pscustomobject][ordered]@{
        identity = $item.identity
        command = $item.command
        exitCode = 0
        result = "PASS"
        fleetLoad = [string]$reuse.row.fleetLoad
        startedUtc = [string]$reuse.row.startedUtc
        finishedUtc = [string]$reuse.row.finishedUtc
        elapsedMs = [long]$reuse.row.elapsedMs
        output = "REUSED from $($reuse.priorHead)"
        provenance = [ordered]@{ kind = 'receipt-reuse'; command = $item.command; attempt = 'local-battery'; priorHead = $reuse.priorHead; priorResultSha256 = $reuse.priorResultSha256
          source = $(if ($null -ne $reuse.ciImport) { 'ci:' + $reuse.ciImport.runId } elseif ($reuse.row.provenance.source -clike 'ci:*') { $reuse.row.provenance.source } else { 'local' }) }
      }
      if ($null -ne $reuse.ciImport) { $result.provenance.ci = $reuse.ciImport }
      elseif ($null -ne $reuse.row.provenance.ci) { $result.provenance.ci = $reuse.row.provenance.ci }
      $results.Add($result)
      Write-BatteryItemLines $result.identity @("RESULT identity=$($result.identity) exitCode=0 result=PASS fleetLoad=$($result.fleetLoad) startedUtc=$($result.startedUtc) finishedUtc=$($result.finishedUtc) elapsedMs=$($result.elapsedMs) provenance=receipt-reuse prior=$($reuse.priorHead)")
      continue
    }
    $itemFleetLoad = Get-BatteryFleetLoad -Holder
    $itemFleet = New-BatteryFleetSampler $item.identity $itemFleetLoad
    Start-BatteryFleetSampler $itemFleet
    $startedUtc = [DateTime]::UtcNow.ToString("o")
    $itemClock = [Diagnostics.Stopwatch]::StartNew()
    $executionStarted = $true
    $childTiming = [Collections.Generic.List[string]]::new()
    try {
      $childOutput = & $item.executable @($item.arguments) 2>&1 | ForEach-Object {
          $first = (($_ | Out-String) -split "\r?\n" | Where-Object { $_ } | Select-Object -First 1)
          $childTiming.Add(("+{0}ms {1}" -f $itemClock.ElapsedMilliseconds, $first))
          $_
        } | Out-String
      $exitCode = $LASTEXITCODE
    } finally {
      $itemClock.Stop()
      $finishedUtc = [DateTime]::UtcNow.ToString("o")
      $itemFleetSampling = Complete-BatteryFleetSampler $itemFleet
    }
    # MEASURED_LOAD (#8102): a timed fixture that missed its bound while the
    # platform slot was held for its whole window exits 75 and prints a
    # MEASURED_LOAD line. It is never PASS; unlike FAIL it marks the battery
    # INCOMPLETE_MEASURED_LOAD rather than failed.
    $measuredLoad = ($exitCode -eq 75) -and ($childOutput -cmatch '(?m)^MEASURED_LOAD ')
    $provenance = [ordered]@{kind='execution';command=$item.command;attempt='local-battery';source='local'}
    $result = [pscustomobject][ordered]@{
      identity = $item.identity
      command = $item.command
      exitCode = $exitCode
      result = if ($exitCode -eq 0) { "PASS" } elseif ($measuredLoad) { "MEASURED_LOAD" } else { "FAIL" }
      fleetLoad = $itemFleet.summary
      startedUtc = $startedUtc
      finishedUtc = $finishedUtc
      elapsedMs = $itemClock.ElapsedMilliseconds
      output = $childOutput.Trim()
      provenance = $provenance
      fleetSampling = $itemFleetSampling
    }
    Add-BatteryTimingLines $item.identity (@("ITEM $($item.identity) elapsedMs=$($itemClock.ElapsedMilliseconds)") + @($childTiming))
    $results.Add($result)
    $itemLines = [Collections.Generic.List[string]]::new()
    $itemLines.Add("RESULT identity=$($result.identity) exitCode=$exitCode result=$($result.result) fleetLoad=$($result.fleetLoad) startedUtc=$startedUtc finishedUtc=$finishedUtc elapsedMs=$($result.elapsedMs)")
    if ($result.output) {
      foreach ($line in @($result.output -split "\r?\n")) {
        $itemLines.Add("CHILD identity=$($result.identity) $line")
      }
    }
    Write-BatteryItemLines $result.identity $itemLines
    if ($result.result -ceq "FAIL") {
      if ($item.identity -clike "test:*" -and $BaselineHead -and $RepairIssue -eq 0) {
        Write-BatteryItemLines $item.identity @(Invoke-BatteryBaselineClassification $result $item)
      }
      $baselineAlsoFailed = $null -ne $result.PSObject.Properties["baseline"] -and $result.baseline.classification -cin @("PREEXISTING", "BASELINE_ALSO_FAILS")
      if (-not $baselineAlsoFailed -and $OnFailure -ceq "stop") { $stoppedAt = $item.identity }
    }
  }
  if ($concurrentChildren.Count -gt 0) {
    # Drain: running children are awaited and recorded, never killed.
    $concurrentStop = Invoke-BatteryConcurrentCheckpoint -Drain -Stopped ($null -ne $stoppedAt)
    if ($null -eq $stoppedAt -and $null -ne $concurrentStop) { $stoppedAt = $concurrentStop }
  }
  Write-BatteryDeferredLines

  if ($null -ne $stoppedAt) {
    Write-Output "NOT_RUN count=$($notRun.Count) after=$stoppedAt identities=$($notRun -join ',')"
    Stop-Battery "BATTERY_CHILD_FAILED:$stoppedAt"
  }

  $executed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($result in $results) {
    if (-not $executed.Add($result.identity)) {
      Stop-Battery "BATTERY_RESULT_DUPLICATE:$($result.identity)"
    }
  }
  foreach ($item in $requiredItems) {
    if (-not $executed.Contains($item.identity)) {
      switch ($item.identity) {
        "direct:fail-closed-guard-evidence" {
          Stop-Battery "BATTERY_DIRECT_CHECKER_VALIDATION_OMITTED"
        }
        "discriminator:issue-6254" {
          Stop-Battery "BATTERY_DISCRIMINATOR_OMITTED:issue-6254"
        }
        default { Stop-Battery "BATTERY_RESULT_MISSING:$($item.identity)" }
      }
    }
  }
  foreach ($result in $results) {
    if (-not $identitySet.Contains($result.identity)) {
      Stop-Battery "BATTERY_RESULT_EXTRA:$($result.identity)"
    }
  }
  $preexistingItems = @()
  $baselineAlsoFailsItems = @()
  foreach ($result in $results) {
    if ($result.exitCode -ne 0 -and $result.result -cne "MEASURED_LOAD") {
      if ($null -ne $result.PSObject.Properties["baseline"] -and $result.baseline.classification -ceq "PREEXISTING") {
        $preexistingItems += $result.identity
        continue
      }
      if ($null -ne $result.PSObject.Properties["baseline"] -and $result.baseline.classification -ceq "BASELINE_ALSO_FAILS") {
        $baselineAlsoFailsItems += $result.identity
        continue
      }
      Stop-Battery "BATTERY_CHILD_FAILED:$($result.identity)"
    }
  }
  if ($results.Count -ne $requiredItems.Count) {
    Stop-Battery "BATTERY_RESULT_COUNT_MISMATCH"
  }
  # Only BASELINE_ALSO_FAILS failures remain, alone or with PREEXISTING ones:
  # never PASS, exit 1 and never installable. The baseline also fails but with
  # another exit or signature; the host judges each item in a decision row
  # (Todd 4388/6167918688 item 1). Unequal signatures are never PREEXISTING here.
  if ($baselineAlsoFailsItems.Count -gt 0) {
    $failureCode = "BATTERY_BASELINE_ALSO_FAILS_ONLY:" + ($baselineAlsoFailsItems -join ",")
    $batteryFailure = "FAIL controller-release-battery: $failureCode"
    $batteryOutcome = "FAIL_BASELINE_ALSO_FAILS_ONLY"
    throw $batteryFailure
  }
  # Only PREEXISTING failures remain: never PASS and still exit 1, but a
  # distinct outcome the governing review may accept when each item has an
  # open issue (milestone-orchestrator section 7).
  if ($preexistingItems.Count -gt 0) {
    $failureCode = "BATTERY_PREEXISTING_ONLY:" + ($preexistingItems -join ",")
    $batteryFailure = "FAIL controller-release-battery: $failureCode"
    $batteryOutcome = "FAIL_PREEXISTING_ONLY"
    throw $batteryFailure
  }
  # A FAIL above wins over any MEASURED_LOAD item; reaching here means every item
  # is PASS or MEASURED_LOAD. One MEASURED_LOAD item makes the whole run
  # INCOMPLETE_MEASURED_LOAD: not installable, exit 75, never a PASS line.
  $measuredLoadItems = @($results | Where-Object { $_.result -ceq "MEASURED_LOAD" } | ForEach-Object { $_.identity })
  $batteryOutcome = if ($measuredLoadItems.Count -gt 0) { "INCOMPLETE_MEASURED_LOAD" } else { "PASS" }
} catch {
  $batteryFailure = $_
  $failureCode = $_.Exception.Message -creplace '^FAIL controller-release-battery: ', ''
  if ($batteryOutcome -cnotin @("FAIL_PREEXISTING_ONLY", "FAIL_BASELINE_ALSO_FAILS_ONLY")) { $batteryOutcome = "FAIL" }
} finally {
  # An abort (Stop-Battery or an exception) kills only the trees it started.
  if ($concurrentChildren.Count -gt 0) { $concurrentAbortLines = Stop-BatteryConcurrentChildren }
  Stop-BatteryFleetSamplerHost
  $batteryClock.Stop()
  $batteryFinishedUtc = [DateTime]::UtcNow.ToString("o")
  if ($baselineCreated) { & git -C $controller worktree remove --force $baselineRoot 2>&1 | Out-Null }
}
foreach ($line in @($concurrentAbortLines)) { Write-Output $line }
Write-BatteryDeferredLines
if ($concurrentState.aborted -and $null -eq $batteryFailure) {
  $failureCode = "BATTERY_CONCURRENT_ABORTED"
  $batteryFailure = "FAIL controller-release-battery: $failureCode"
  $batteryOutcome = "FAIL"
}
$measuredLoadItems = @($results | Where-Object { $_.result -ceq "MEASURED_LOAD" } | ForEach-Object { $_.identity })

try {
  if (($executionStarted -or $results.Count -gt 0) -and $resolvedResult) {
    $rawText = @($results | ForEach-Object {
      # A baseline-classified row names its label; the result field stays FAIL.
      $baselineField = if ($null -ne $_.PSObject.Properties["baseline"]) { " baseline=$($_.baseline.classification)" } else { "" }
      "RESULT identity=$($_.identity) exitCode=$($_.exitCode) result=$($_.result) fleetLoad=$($_.fleetLoad) startedUtc=$($_.startedUtc) finishedUtc=$($_.finishedUtc) elapsedMs=$($_.elapsedMs)$baselineField`n$($_.output)"
    }) -join "`n"
    $rawBytes = [Text.UTF8Encoding]::new($false).GetBytes($batteryHostLog + "`n" + $rawText + "`n")
    # A link placed under the root during the run refuses every output write.
    foreach ($outputPath in @($rawPath, $resolvedResult, [IO.Path]::ChangeExtension($resolvedResult, ".timing.txt"))) {
      [void](Assert-BatteryArtifactPath $artifactRoot $outputPath "BATTERY_RESULT_PATH_INVALID")
    }
    Invoke-BatteryArtifactWriteSeam $rawPath
    Write-BatteryArtifact $artifactRoot $rawPath "BATTERY_RESULT_PATH_INVALID" $rawBytes
    Confirm-BatteryArtifactWrite $artifactRoot $rawPath "BATTERY_RESULT_PATH_INVALID"
    $rawHash = ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($rawBytes))).ToLowerInvariant()
    $resultRecord = [ordered]@{
      schemaVersion = "controller-battery-result/v1"
      controllerHead = $ExpectedControllerHead
      hostIdentity = $hostIdentity
      fleetLoad = $admissionFleetLoad
      scope = [ordered]@{ kind = $batteryScope; reason = $scopeReason; baselineHead = $BaselineHead; changedCount = $changedPaths.Count }
      execution = [ordered]@{
        mode = if ($concurrentMode) { "foreground-file-serial-with-concurrent" } else { "foreground-file-serial" }
        outcome = $batteryOutcome
        startedUtc = $batteryStartedUtc
        finishedUtc = $batteryFinishedUtc
        elapsedMs = $batteryClock.ElapsedMilliseconds
        measuredLoadCount = $measuredLoadItems.Count
        requiredCount = $requiredItems.Count
        executedCount = @($results | Where-Object {$_.provenance.kind -ceq 'execution'}).Count
        reusedCount = @($results | Where-Object {$_.provenance.kind -ceq 'receipt-reuse'}).Count
        satisfiedCount = $results.Count
        onFailure = $OnFailure
        notRun = @($notRun)
      }
      inventory = @($requiredItems | ForEach-Object {
        [ordered]@{ identity = $_.identity; path = $_.path; command = $_.command }
      })
      results = @($results | ForEach-Object {
        $row = [ordered]@{
          identity = $_.identity; exitCode = $_.exitCode; result = $_.result; fleetLoad = $_.fleetLoad
          provenance = $_.provenance; startedUtc = $_.startedUtc; finishedUtc = $_.finishedUtc; elapsedMs = $_.elapsedMs
        }
        if ($null -ne $_.PSObject.Properties["fleetSampling"]) { $row.fleetSampling = $_.fleetSampling }
        if ($null -ne $_.PSObject.Properties["baseline"]) { $row.baseline = $_.baseline }
        $row
      })
      rawLog = [ordered]@{
        kind = "raw-log"
        relativePath = ".orchestrator/artifacts/" + [IO.Path]::GetFileName($rawPath)
        byteLength = $rawBytes.Length
        sha256 = $rawHash
      }
    }
    if ($concurrentMode) { $resultRecord.execution.concurrentIdentities = @($concurrentStarted) }
    if ($null -ne $batteryFailure) { $resultRecord.failureCode = $failureCode }
    $resultBytes = [Text.UTF8Encoding]::new($false).GetBytes(($resultRecord | ConvertTo-Json -Compress -Depth 20) + "`n")
    # Diagnostic per-line child timing; not bound by the result record.
    $timingPath = [IO.Path]::ChangeExtension($resolvedResult, ".timing.txt")
    Invoke-BatteryArtifactWriteSeam $timingPath
    $timingBytes = [Text.UTF8Encoding]::new($false).GetBytes(((@($timingLines) -join [Environment]::NewLine) + $(if ($timingLines.Count) { [Environment]::NewLine } else { '' })))
    Write-BatteryArtifact $artifactRoot $timingPath "BATTERY_RESULT_PATH_INVALID" $timingBytes
    Confirm-BatteryArtifactWrite $artifactRoot $timingPath "BATTERY_RESULT_PATH_INVALID"
    Invoke-BatteryArtifactWriteSeam $resolvedResult
    Write-BatteryArtifact $artifactRoot $resolvedResult "BATTERY_RESULT_PATH_INVALID" $resultBytes
    Confirm-BatteryArtifactWrite $artifactRoot $resolvedResult "BATTERY_RESULT_PATH_INVALID"
    Write-Output "BATTERY_RESULT path=$resolvedResult raw=$rawPath"
  }
} catch {
  if ($null -eq $batteryFailure) { throw }
  # A secondary output failure must not replace the original terminal signature.
  Write-Warning "Battery result write failed: $($_.Exception.Message)"
}

function Write-BatteryRecap {
  foreach ($result in @($results | Sort-Object -Property elapsedMs -Descending -Stable)) {
    Write-Output "TIMING identity=$($result.identity) startedUtc=$($result.startedUtc) finishedUtc=$($result.finishedUtc) elapsedMs=$($result.elapsedMs)"
  }
}

if ($null -ne $batteryFailure) {
  if ($batteryOutcome -ceq "FAIL_PREEXISTING_ONLY") {
    Write-Output "FAIL_PREEXISTING_ONLY controller release battery head=$ExpectedControllerHead baseline=$BaselineHead preexisting=$($preexistingItems -join ',')"
  }
  if ($batteryOutcome -ceq "FAIL_BASELINE_ALSO_FAILS_ONLY") {
    Write-Output "FAIL_BASELINE_ALSO_FAILS_ONLY controller release battery head=$ExpectedControllerHead baseline=$BaselineHead baselineAlsoFails=$($baselineAlsoFailsItems -join ',') preexisting=$($preexistingItems -join ',')"
  }
  Write-BatteryRecap
  throw $batteryFailure
}

if ($batteryOutcome -ceq "INCOMPLETE_MEASURED_LOAD") {
  Write-Output "INCOMPLETE_MEASURED_LOAD controller release battery head=$ExpectedControllerHead measured=$($measuredLoadItems -join ',') fleetLoad=$admissionFleetLoad"
  Write-BatteryRecap
  exit 75
}

$executedCount=@($results|Where-Object{$_.provenance.kind-ceq'execution'}).Count;$reusedCount=@($results|Where-Object{$_.provenance.kind-ceq'receipt-reuse'}).Count
Write-Output "PASS controller release battery head=$ExpectedControllerHead required=$($requiredItems.Count) executed=$executedCount reused=$reusedCount satisfied=$($results.Count) direct=1 tests=$(@($requiredItems | Where-Object identity -like 'test:*').Count) discriminators=$(@($requiredItems | Where-Object identity -like 'discriminator:*').Count) startedUtc=$batteryStartedUtc finishedUtc=$batteryFinishedUtc elapsedMs=$($batteryClock.ElapsedMilliseconds)"
Write-BatteryRecap
