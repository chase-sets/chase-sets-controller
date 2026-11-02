Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($null -eq ("ChaseSets.Controller.CodexBoundaryNative" -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace ChaseSets.Controller {
  public static class CodexBoundaryNative {
    private const uint FILE_SHARE_READ = 0x00000001;
    private const uint FILE_SHARE_WRITE = 0x00000002;
    private const uint FILE_SHARE_DELETE = 0x00000004;
    private const uint OPEN_EXISTING = 3;
    private const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
    private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
    private const uint PROCESS_SET_QUOTA = 0x0100;
    private const uint PROCESS_TERMINATE = 0x0001;

    [StructLayout(LayoutKind.Sequential)]
    private struct BY_HANDLE_FILE_INFORMATION {
      public uint FileAttributes;
      public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
      public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
      public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
      public uint VolumeSerialNumber;
      public uint FileSizeHigh;
      public uint FileSizeLow;
      public uint NumberOfLinks;
      public uint FileIndexHigh;
      public uint FileIndexLow;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
      public long PerProcessUserTimeLimit;
      public long PerJobUserTimeLimit;
      public uint LimitFlags;
      public UIntPtr MinimumWorkingSetSize;
      public UIntPtr MaximumWorkingSetSize;
      public uint ActiveProcessLimit;
      public UIntPtr Affinity;
      public uint PriorityClass;
      public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IO_COUNTERS {
      public ulong ReadOperationCount;
      public ulong WriteOperationCount;
      public ulong OtherOperationCount;
      public ulong ReadTransferCount;
      public ulong WriteTransferCount;
      public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
      public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
      public IO_COUNTERS IoInfo;
      public UIntPtr ProcessMemoryLimit;
      public UIntPtr JobMemoryLimit;
      public UIntPtr PeakProcessMemoryUsed;
      public UIntPtr PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(
      string fileName, uint desiredAccess, uint shareMode, IntPtr securityAttributes,
      uint creationDisposition, uint flagsAndAttributes, IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(
      SafeFileHandle file, out BY_HANDLE_FILE_INFORMATION information);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateJobObjectW(IntPtr attributes, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetInformationJobObject(
      SafeFileHandle job, int informationClass, IntPtr information, uint informationLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern SafeFileHandle OpenProcess(uint access, bool inheritHandle, uint processId);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AssignProcessToJobObject(SafeFileHandle job, SafeFileHandle process);

    public static string GetIdentity(string path) {
      using (SafeFileHandle handle = CreateFileW(
        path, 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, IntPtr.Zero)) {
        if (handle.IsInvalid) {
          throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        BY_HANDLE_FILE_INFORMATION information;
        if (!GetFileInformationByHandle(handle, out information)) {
          throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        return information.VolumeSerialNumber.ToString("x8") + ":" +
          information.FileIndexHigh.ToString("x8") + information.FileIndexLow.ToString("x8");
      }
    }

    public static SafeFileHandle CreateKillOnCloseJob() {
      SafeFileHandle job = CreateJobObjectW(IntPtr.Zero, null);
      if (job.IsInvalid) {
        throw new Win32Exception(Marshal.GetLastWin32Error());
      }
      JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
      limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
      int size = Marshal.SizeOf<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>();
      IntPtr memory = Marshal.AllocHGlobal(size);
      try {
        Marshal.StructureToPtr(limits, memory, false);
        if (!SetInformationJobObject(job, 9, memory, (uint)size)) {
          int error = Marshal.GetLastWin32Error();
          job.Dispose();
          throw new Win32Exception(error);
        }
      } finally {
        Marshal.FreeHGlobal(memory);
      }
      return job;
    }

    public static void AssignProcess(SafeFileHandle job, int processId) {
      using (SafeFileHandle process = OpenProcess(
        PROCESS_SET_QUOTA | PROCESS_TERMINATE, false, checked((uint)processId))) {
        if (process.IsInvalid) {
          throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        if (!AssignProcessToJobObject(job, process)) {
          throw new Win32Exception(Marshal.GetLastWin32Error());
        }
      }
    }
  }
}
'@
}

$script:CodexBoundaryContract = [ordered]@{
  schema = "codex-launch-boundary/v1"
  harnessPath = "C:\Users\ToddS\AppData\Local\Programs\OpenAI\Codex\bin\codex.exe"
  surfaceFixtureRelativePath = "fixtures/codex-launch-boundary-surface-v1.txt"
  surfaceFixtureSha256 = "d81039cb139c2aa3a57010cb6436c30245ab6f7e0c59f5ec5097ed5aff6dbba2"
  referencedSchemaTypes = @(
    "ActivePermissionProfile", "AdditionalFileSystemPermissions", "FileSystemAccessMode",
    "FileSystemPath", "FileSystemSandboxEntry", "NetworkDomainPermission",
    "NetworkRequirements", "SandboxPolicy", "SandboxWorkspaceWrite",
    "WindowsSandboxReadiness"
  )
  emittedConfigKeys = @(
    "approval_policy", "default_permissions", "entries", "exclude_slash_tmp",
    "exclude_tmpdir_env_var", "extends", "fileSystem", "network_access",
    "permissions", "sandbox_mode", "sandbox_workspace_write", "writable_roots"
  )
  emittedFlags = @(
    "--cd", "--ephemeral", "--ignore-rules", "--sandbox", "--skip-git-repo-check",
    "--strict-config"
  )
  featureStates = [ordered]@{
    elevated_windows_sandbox = [ordered]@{ stage = "removed"; enabled = $false }
    experimental_windows_sandbox = [ordered]@{ stage = "removed"; enabled = $false }
    network_proxy = [ordered]@{ stage = "experimental"; enabled = $false }
  }
}

function Throw-CodexBoundaryRefusal {
  param([Parameter(Mandatory)][string]$Code, $CapabilityMatrix)
  $exception = [InvalidOperationException]::new($Code)
  if ($null -ne $CapabilityMatrix) {
    $exception.Data["capabilityMatrix"] = $CapabilityMatrix
  }
  throw $exception
}

function Get-CodexBoundarySha256Bytes {
  param([Parameter(Mandatory)][byte[]]$Bytes)
  return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Get-CodexBoundaryFileSha256 {
  param([Parameter(Mandatory)][string]$LiteralPath)
  return (Get-FileHash -LiteralPath $LiteralPath -Algorithm SHA256).Hash.ToLowerInvariant()
}

function New-CodexBoundaryTempFixture {
  param([Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]+$')][string]$Purpose)
  $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar
  )
  $name = "chase-sets-6721-$Purpose-$([Guid]::NewGuid().ToString('N'))"
  $path = Join-Path $tempParent $name
  [void][IO.Directory]::CreateDirectory($path)
  $item = Get-Item -LiteralPath $path -Force
  if ($item.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint) -or
      $item.Parent.FullName.TrimEnd([IO.Path]::DirectorySeparatorChar) -cne $tempParent -or
      -not $item.Name.StartsWith("chase-sets-6721-$Purpose-", [StringComparison]::Ordinal)) {
    Throw-CodexBoundaryRefusal "codex-boundary-temp-fixture-identity-invalid"
  }
  return $item.FullName
}

function Remove-CodexBoundaryTempFixture {
  param(
    [Parameter(Mandatory)][string]$LiteralPath,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]+$')][string]$Purpose
  )
  $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar
  )
  $resolved = [IO.Path]::GetFullPath($LiteralPath)
  $item = Get-Item -LiteralPath $resolved -Force -ErrorAction SilentlyContinue
  if ($null -eq $item) { return }
  if (-not $item.PSIsContainer -or
      $item.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint) -or
      $item.Parent.FullName.TrimEnd([IO.Path]::DirectorySeparatorChar) -cne $tempParent -or
      -not $item.Name.StartsWith("chase-sets-6721-$Purpose-", [StringComparison]::Ordinal)) {
    Throw-CodexBoundaryRefusal "codex-boundary-temp-cleanup-identity-invalid"
  }
  Remove-Item -LiteralPath $resolved -Recurse -Force
}

function Get-CodexBoundaryMinimalEnvironment {
  param([Parameter(Mandatory)][string]$FixtureRoot)
  $systemRoot = [Environment]::GetEnvironmentVariable("SystemRoot", "Process")
  if ([string]::IsNullOrWhiteSpace($systemRoot)) {
    $systemRoot = [Environment]::GetEnvironmentVariable("SystemRoot", "Machine")
  }
  if ([string]::IsNullOrWhiteSpace($systemRoot)) {
    Throw-CodexBoundaryRefusal "codex-boundary-system-root-unavailable"
  }
  foreach ($relative in @("appdata", "localappdata", "codex-home")) {
    [void][IO.Directory]::CreateDirectory((Join-Path $FixtureRoot $relative))
  }
  return [ordered]@{
    SystemRoot = $systemRoot
    WINDIR = $systemRoot
    TEMP = $FixtureRoot
    TMP = $FixtureRoot
    USERPROFILE = $FixtureRoot
    APPDATA = (Join-Path $FixtureRoot "appdata")
    LOCALAPPDATA = (Join-Path $FixtureRoot "localappdata")
    CODEX_HOME = (Join-Path $FixtureRoot "codex-home")
    PATH = ""
    NO_COLOR = "1"
    TERM = "dumb"
  }
}

function Invoke-CodexBoundaryNativeProcess {
  param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Arguments,
    [Parameter(Mandatory)][string]$FixtureRoot
  )
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = $ExecutablePath
  $start.UseShellExecute = $false
  $start.CreateNoWindow = $true
  $start.RedirectStandardInput = $true
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
  $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
  $start.Environment.Clear()
  foreach ($entry in (Get-CodexBoundaryMinimalEnvironment -FixtureRoot $FixtureRoot).GetEnumerator()) {
    $start.Environment[[string]$entry.Key] = [string]$entry.Value
  }
  foreach ($argument in $Arguments) {
    [void]$start.ArgumentList.Add($argument)
  }

  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $start
  $stdout = [IO.MemoryStream]::new()
  $stderr = [IO.MemoryStream]::new()
  try {
    if (-not $process.Start()) {
      Throw-CodexBoundaryRefusal "codex-boundary-harness-launch-failed"
    }
    $process.StandardInput.Close()
    $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($stdout)
    $stderrTask = $process.StandardError.BaseStream.CopyToAsync($stderr)
    $process.WaitForExit()
    [Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask))
    return [pscustomobject]@{
      exitCode = $process.ExitCode
      stdoutBytes = $stdout.ToArray()
      stderrBytes = $stderr.ToArray()
      processId = $process.Id
    }
  } finally {
    $stdout.Dispose()
    $stderr.Dispose()
    $process.Dispose()
  }
}

function Invoke-CodexBoundaryVersion {
  param([Parameter(Mandatory)][string]$ExecutablePath)
  $fixture = New-CodexBoundaryTempFixture -Purpose "version"
  try {
    $result = Invoke-CodexBoundaryNativeProcess -ExecutablePath $ExecutablePath -Arguments @("--version") -FixtureRoot $fixture
    if ($result.exitCode -ne 0) {
      Throw-CodexBoundaryRefusal "codex-boundary-harness-version-unavailable"
    }
    return [Text.UTF8Encoding]::new($false, $true).GetString($result.stdoutBytes).TrimEnd("`r", "`n")
  } finally {
    Remove-CodexBoundaryTempFixture -LiteralPath $fixture -Purpose "version"
  }
}

function Test-CodexBoundaryNativePe {
  param([Parameter(Mandatory)][string]$LiteralPath)
  $stream = [IO.File]::Open($LiteralPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
  try {
    if ($stream.Length -lt 68) { return $false }
    $reader = [IO.BinaryReader]::new($stream, [Text.Encoding]::ASCII, $true)
    try {
      if ($reader.ReadUInt16() -ne 0x5a4d) { return $false }
      $stream.Position = 0x3c
      $peOffset = $reader.ReadInt32()
      if ($peOffset -lt 64 -or $peOffset -gt ($stream.Length - 4)) { return $false }
      $stream.Position = $peOffset
      return $reader.ReadUInt32() -eq 0x00004550
    } finally {
      $reader.Dispose()
    }
  } finally {
    $stream.Dispose()
  }
}

function Resolve-CodexBoundaryHarnessInternal {
  param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [scriptblock]$VersionReader
  )
  if (-not [IO.Path]::IsPathFullyQualified($ExecutablePath) -or
      -not (Test-Path -LiteralPath $ExecutablePath -PathType Leaf)) {
    Throw-CodexBoundaryRefusal "codex-boundary-harness-absent"
  }
  $item = Get-Item -LiteralPath $ExecutablePath -Force
  if ($item.Extension -cne ".exe" -or
      $item.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint) -or
      -not (Test-CodexBoundaryNativePe -LiteralPath $item.FullName)) {
    Throw-CodexBoundaryRefusal "codex-boundary-harness-not-native"
  }
  $resolvedPath = $item.FullName
  if ($resolvedPath -cne [IO.Path]::GetFullPath($ExecutablePath)) {
    Throw-CodexBoundaryRefusal "codex-boundary-harness-not-native"
  }
  $actualSha256 = Get-CodexBoundaryFileSha256 -LiteralPath $resolvedPath
  $actualVersion = if ($null -ne $VersionReader) {
    & $VersionReader $resolvedPath
  } else {
    Invoke-CodexBoundaryVersion -ExecutablePath $resolvedPath
  }
  if ([string]$actualVersion -cnotmatch '^codex-cli [0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$') {
    Throw-CodexBoundaryRefusal "codex-boundary-harness-version-unavailable"
  }
  return [pscustomobject][ordered]@{
    path = $resolvedPath
    sha256 = $actualSha256
    length = [int64]$item.Length
    version = [string]$actualVersion
  }
}

function Resolve-CodexBoundaryHarness {
  [CmdletBinding()]
  param()
  return Resolve-CodexBoundaryHarnessInternal `
    -ExecutablePath $script:CodexBoundaryContract.harnessPath
}

function Add-CodexBoundarySurfaceAscii {
  param(
    [Parameter(Mandatory)][IO.MemoryStream]$Stream,
    [Parameter(Mandatory)][string]$Text
  )
  $bytes = [Text.UTF8Encoding]::new($false, $true).GetBytes($Text)
  $Stream.Write($bytes, 0, $bytes.Length)
}

function Add-CodexBoundarySurfaceBlock {
  param(
    [Parameter(Mandatory)][IO.MemoryStream]$Stream,
    [Parameter(Mandatory)][string]$Command,
    [Parameter(Mandatory)]$Result
  )
  $base64 = [Convert]::ToBase64String($Result.stdoutBytes)
  $base64Line = if ($base64.Length -eq 0) { "stdout-base64:" } else { "stdout-base64: $base64" }
  Add-CodexBoundarySurfaceAscii -Stream $Stream -Text "command: $Command`nexit-code: $($Result.exitCode)`nstdout-encoding: base64-exact-bytes`nstdout-bytes: $($Result.stdoutBytes.Length)`n$base64Line`nend-command`n"
}

function Add-CodexBoundaryGeneratedFileBlock {
  param(
    [Parameter(Mandatory)][IO.MemoryStream]$Stream,
    [Parameter(Mandatory)][string]$RelativePath,
    [Parameter(Mandatory)][byte[]]$Bytes
  )
  $base64 = [Convert]::ToBase64String($Bytes)
  Add-CodexBoundarySurfaceAscii -Stream $Stream -Text "generated-file: $RelativePath`nfile-encoding: base64-exact-bytes`nfile-bytes: $($Bytes.Length)`nfile-base64: $base64`nend-generated-file`n"
}

function Get-CodexBoundarySurfaceCommandRows {
  return @(
    [pscustomobject]@{ label = "codex.exe --help"; argv = @("--help") },
    [pscustomobject]@{ label = "codex.exe exec --help"; argv = @("exec", "--help") },
    [pscustomobject]@{ label = "codex.exe sandbox --help"; argv = @("sandbox", "--help") },
    [pscustomobject]@{ label = "codex.exe app-server --help"; argv = @("app-server", "--help") },
    [pscustomobject]@{ label = "codex.exe app-server generate-json-schema --help"; argv = @("app-server", "generate-json-schema", "--help") },
    [pscustomobject]@{ label = "codex.exe features list"; argv = @("features", "list") }
  )
}

function ConvertFrom-CodexBoundarySurfaceBytes {
  param([Parameter(Mandatory)][byte[]]$Bytes)
  try {
    $surfaceText = [Text.UTF8Encoding]::new($false, $true).GetString($Bytes)
  } catch {
    Throw-CodexBoundaryRefusal "codex-boundary-surface-malformed"
  }
  $lines = @($surfaceText -split "`n")
  if ($lines.Count -lt 3 -or $lines[0] -cne "codex-launch-boundary-surface/v1" -or
      $lines[1] -cne "payload-encoding: base64-exact-build-bytes" -or
      $lines[-1] -cne "") {
    Throw-CodexBoundaryRefusal "codex-boundary-surface-malformed"
  }
  $commands = [ordered]@{}
  $files = [ordered]@{}
  $index = 2
  while ($index -lt ($lines.Count - 1)) {
    $line = $lines[$index]
    $isCommand = $line.StartsWith("command: ", [StringComparison]::Ordinal)
    $isFile = $line.StartsWith("generated-file: ", [StringComparison]::Ordinal)
    if (-not $isCommand -and -not $isFile) {
      Throw-CodexBoundaryRefusal "codex-boundary-surface-malformed"
    }
    if ($isCommand) {
      if (($index + 5) -ge $lines.Count) { Throw-CodexBoundaryRefusal "codex-boundary-surface-malformed" }
      $label = $line.Substring("command: ".Length)
      $exitMatch = [regex]::Match($lines[$index + 1], '^exit-code: (?<value>0|[1-9][0-9]*)$')
      $lengthMatch = [regex]::Match($lines[$index + 3], '^stdout-bytes: (?<value>0|[1-9][0-9]*)$')
      $payloadMatch = [regex]::Match($lines[$index + 4], '^stdout-base64:(?: (?<value>[A-Za-z0-9+/]*={0,2}))?$')
      if ([string]::IsNullOrWhiteSpace($label) -or $commands.Contains($label) -or
          -not $exitMatch.Success -or
          $lines[$index + 2] -cne "stdout-encoding: base64-exact-bytes" -or
          -not $lengthMatch.Success -or -not $payloadMatch.Success -or
          $lines[$index + 5] -cne "end-command") {
        Throw-CodexBoundaryRefusal "codex-boundary-surface-malformed"
      }
      try { [byte[]]$payloadBytes = [Convert]::FromBase64String($payloadMatch.Groups["value"].Value) }
      catch { Throw-CodexBoundaryRefusal "codex-boundary-surface-malformed" }
      $byteLength = [int64]$lengthMatch.Groups["value"].Value
      if ($payloadBytes.Length -ne $byteLength) { Throw-CodexBoundaryRefusal "codex-boundary-surface-malformed" }
      $commands[$label] = [pscustomobject]@{
        exitCode = [int]$exitMatch.Groups["value"].Value
        bytes = $payloadBytes
      }
      $index += 6
      continue
    }
    if (($index + 4) -ge $lines.Count) { Throw-CodexBoundaryRefusal "codex-boundary-surface-malformed" }
    $label = $line.Substring("generated-file: ".Length)
    $lengthMatch = [regex]::Match($lines[$index + 2], '^file-bytes: (?<value>0|[1-9][0-9]*)$')
    $payloadMatch = [regex]::Match($lines[$index + 3], '^file-base64:(?: (?<value>[A-Za-z0-9+/]*={0,2}))?$')
    if ([string]::IsNullOrWhiteSpace($label) -or $files.Contains($label) -or
        $lines[$index + 1] -cne "file-encoding: base64-exact-bytes" -or
        -not $lengthMatch.Success -or -not $payloadMatch.Success -or
        $lines[$index + 4] -cne "end-generated-file") {
      Throw-CodexBoundaryRefusal "codex-boundary-surface-malformed"
    }
    try { [byte[]]$payloadBytes = [Convert]::FromBase64String($payloadMatch.Groups["value"].Value) }
    catch { Throw-CodexBoundaryRefusal "codex-boundary-surface-malformed" }
    $byteLength = [int64]$lengthMatch.Groups["value"].Value
    if ($payloadBytes.Length -ne $byteLength) { Throw-CodexBoundaryRefusal "codex-boundary-surface-malformed" }
    $files[$label] = $payloadBytes
    $index += 5
  }
  return [pscustomobject]@{ commands = $commands; files = $files }
}

function Get-CodexBoundarySurfaceUtf8 {
  param([Parameter(Mandatory)][byte[]]$Bytes)
  try { return [Text.UTF8Encoding]::new($false, $true).GetString($Bytes) }
  catch { Throw-CodexBoundaryRefusal "codex-boundary-surface-malformed" }
}

function Assert-CodexBoundarySurfaceRequirements {
  param([Parameter(Mandatory)][byte[]]$Bytes)
  $surface = ConvertFrom-CodexBoundarySurfaceBytes -Bytes $Bytes
  $expectedCommands = @((Get-CodexBoundarySurfaceCommandRows).label) + @(
    "codex.exe app-server generate-json-schema --experimental --out <unique-fixture>/generated-schema"
  )
  $expectedFiles = @(
    "codex_app_server_protocol.v2.schemas.json",
    "v2/ConfigReadResponse.json",
    "v2/PermissionProfileListResponse.json",
    "v2/WindowsSandboxReadinessResponse.json"
  )
  if ((@($surface.commands.Keys) -join "`n") -cne ($expectedCommands -join "`n") -or
      (@($surface.files.Keys) -join "`n") -cne ($expectedFiles -join "`n")) {
    Throw-CodexBoundaryRefusal "codex-boundary-surface-drift"
  }
  foreach ($label in $expectedCommands) {
    $command = $surface.commands[$label]
    if ($command.exitCode -ne 0 -or
        ($label -cne $expectedCommands[-1] -and $command.bytes.Length -eq 0)) {
      Throw-CodexBoundaryRefusal "codex-boundary-surface-drift"
    }
  }
  $execHelp = Get-CodexBoundarySurfaceUtf8 -Bytes $surface.commands["codex.exe exec --help"].bytes
  foreach ($flag in $script:CodexBoundaryContract.emittedFlags) {
    if (-not $execHelp.Contains([string]$flag, [StringComparison]::Ordinal)) {
      Throw-CodexBoundaryRefusal "codex-boundary-surface-drift"
    }
  }
  $featureText = Get-CodexBoundarySurfaceUtf8 -Bytes $surface.commands["codex.exe features list"].bytes
  [void](Assert-CodexBoundaryFeatureStatesInternal `
    -FeatureText $featureText `
    -ExpectedStates $script:CodexBoundaryContract.featureStates)

  foreach ($path in $expectedFiles) {
    $jsonText = Get-CodexBoundarySurfaceUtf8 -Bytes $surface.files[$path]
    try { $json = $jsonText | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String -ErrorAction Stop }
    catch { Throw-CodexBoundaryRefusal "codex-boundary-surface-malformed" }
    if ($null -eq $json) { Throw-CodexBoundaryRefusal "codex-boundary-surface-malformed" }
  }
  $aggregateText = Get-CodexBoundarySurfaceUtf8 -Bytes $surface.files["codex_app_server_protocol.v2.schemas.json"]
  $aggregate = $aggregateText | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
  if ($aggregate.definitions -isnot [Collections.IDictionary]) {
    Throw-CodexBoundaryRefusal "codex-boundary-surface-drift"
  }
  foreach ($typeName in $script:CodexBoundaryContract.referencedSchemaTypes) {
    if (-not $aggregate.definitions.Contains([string]$typeName)) {
      Throw-CodexBoundaryRefusal "codex-boundary-surface-drift"
    }
  }
  foreach ($key in $script:CodexBoundaryContract.emittedConfigKeys) {
    if (-not $aggregateText.Contains([string]$key, [StringComparison]::Ordinal)) {
      Throw-CodexBoundaryRefusal "codex-boundary-surface-drift"
    }
  }
  return $true
}

function Get-CodexBoundaryLiveSurfaceBytes {
  param([Parameter(Mandatory)]$Harness)
  $fixture = New-CodexBoundaryTempFixture -Purpose "surface"
  $stream = [IO.MemoryStream]::new()
  try {
    Add-CodexBoundarySurfaceAscii -Stream $stream -Text "codex-launch-boundary-surface/v1`npayload-encoding: base64-exact-build-bytes`n"
    foreach ($row in @(Get-CodexBoundarySurfaceCommandRows)) {
      $result = Invoke-CodexBoundaryNativeProcess -ExecutablePath $Harness.path -Arguments $row.argv -FixtureRoot $fixture
      Add-CodexBoundarySurfaceBlock -Stream $stream -Command $row.label -Result $result
    }
    $schemaRoot = Join-Path $fixture "generated-schema"
    $schemaResult = Invoke-CodexBoundaryNativeProcess `
      -ExecutablePath $Harness.path `
      -Arguments @("app-server", "generate-json-schema", "--experimental", "--out", $schemaRoot) `
      -FixtureRoot $fixture
    Add-CodexBoundarySurfaceBlock `
      -Stream $stream `
      -Command "codex.exe app-server generate-json-schema --experimental --out <unique-fixture>/generated-schema" `
      -Result $schemaResult
    if ($schemaResult.exitCode -ne 0) {
      Throw-CodexBoundaryRefusal "codex-boundary-surface-metadata-unavailable"
    }
    foreach ($relativePath in @(
      "codex_app_server_protocol.v2.schemas.json",
      "v2/ConfigReadResponse.json",
      "v2/PermissionProfileListResponse.json",
      "v2/WindowsSandboxReadinessResponse.json"
    )) {
      $nativeRelative = $relativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)
      $generatedPath = Join-Path $schemaRoot $nativeRelative
      if (-not (Test-Path -LiteralPath $generatedPath -PathType Leaf)) {
        Throw-CodexBoundaryRefusal "codex-boundary-surface-metadata-unavailable"
      }
      Add-CodexBoundaryGeneratedFileBlock `
        -Stream $stream `
        -RelativePath $relativePath `
        -Bytes ([IO.File]::ReadAllBytes($generatedPath))
    }
    return $stream.ToArray()
  } finally {
    $stream.Dispose()
    Remove-CodexBoundaryTempFixture -LiteralPath $fixture -Purpose "surface"
  }
}

function Get-CodexBoundaryFixturePath {
  return Join-Path $PSScriptRoot $script:CodexBoundaryContract.surfaceFixtureRelativePath
}

function Assert-CodexBoundarySurfaceInternal {
  param(
    [Parameter(Mandatory)]$Harness,
    [Parameter(Mandatory)][string]$FixturePath,
    [Parameter(Mandatory)][string]$ExpectedSha256,
    [scriptblock]$LiveSurfaceReader
  )
  if (-not (Test-Path -LiteralPath $fixturePath -PathType Leaf)) {
    Throw-CodexBoundaryRefusal "codex-boundary-surface-drift"
  }
  $fixtureBytes = [IO.File]::ReadAllBytes($fixturePath)
  $fixtureSha256 = Get-CodexBoundarySha256Bytes -Bytes $fixtureBytes
  if ($fixtureSha256 -cne $ExpectedSha256) {
    Throw-CodexBoundaryRefusal "codex-boundary-surface-drift"
  }
  [byte[]]$liveBytes = if ($null -ne $LiveSurfaceReader) {
    & $LiveSurfaceReader $Harness
  } else {
    Get-CodexBoundaryLiveSurfaceBytes -Harness $Harness
  }
  [void](Assert-CodexBoundarySurfaceRequirements -Bytes $liveBytes)
  return $fixtureSha256
}

function Assert-CodexBoundarySurface {
  param([Parameter(Mandatory)]$Harness)
  return Assert-CodexBoundarySurfaceInternal `
    -Harness $Harness `
    -FixturePath (Get-CodexBoundaryFixturePath) `
    -ExpectedSha256 $script:CodexBoundaryContract.surfaceFixtureSha256
}

function Assert-CodexBoundaryFeatureStatesInternal {
  param(
    [Parameter(Mandatory)][string]$FeatureText,
    [Parameter(Mandatory)]$ExpectedStates
  )
  $observed = @{}
  foreach ($line in @($FeatureText -split '\r?\n')) {
    if ($line -match '^([a-z0-9_]+)\s{2,}(.+?)\s{2,}(true|false)$') {
      $observed[$Matches[1]] = [ordered]@{
        stage = $Matches[2].Trim()
        enabled = $Matches[3] -ceq "true"
      }
    }
  }
  foreach ($entry in $ExpectedStates.GetEnumerator()) {
    if (-not $observed.ContainsKey([string]$entry.Key) -or
        [string]$observed[[string]$entry.Key].stage -cne [string]$entry.Value.stage -or
        [bool]$observed[[string]$entry.Key].enabled -ne [bool]$entry.Value.enabled) {
      Throw-CodexBoundaryRefusal "codex-boundary-feature-state-drift"
    }
  }
  return $true
}

function ConvertTo-CodexBoundaryTomlString {
  param([Parameter(Mandatory)][string]$Value)
  return '"' + $Value.Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n') + '"'
}

function Get-CodexBoundaryProfileContent {
  param(
    [Parameter(Mandatory)]$ReadableRootRecords,
    [Parameter(Mandatory)]$WritableRootRecord
  )
  $entries = [Collections.Generic.List[string]]::new()
  $entries.Add('  { path = { type = "special", value = { kind = "root" } }, access = "deny" }')
  $entries.Add('  { path = { type = "special", value = { kind = "minimal" } }, access = "read" }')
  foreach ($root in @($ReadableRootRecords)) {
    $path = ConvertTo-CodexBoundaryTomlString -Value ([string]$root.path)
    $entries.Add("  { path = { type = `"path`", path = $path }, access = `"read`" }")
  }
  $writablePath = ConvertTo-CodexBoundaryTomlString -Value ([string]$WritableRootRecord.path)
  $entries.Add("  { path = { type = `"path`", path = $writablePath }, access = `"write`" }")
  $writableArray = ConvertTo-CodexBoundaryTomlString -Value ([string]$WritableRootRecord.path)
  return @(
    'default_permissions = "chase_sets_boundary"'
    'sandbox_mode = "workspace-write"'
    'approval_policy = "never"'
    '[sandbox_workspace_write]'
    'network_access = false'
    'exclude_tmpdir_env_var = true'
    'exclude_slash_tmp = true'
    "writable_roots = [$writableArray]"
    '[permissions.chase_sets_boundary]'
    'extends = ":read-only"'
    '[permissions.chase_sets_boundary.fileSystem]'
    'entries = ['
    ($entries -join ",`n")
    ']'
    ''
  ) -join "`n"
}

function New-CodexBoundaryProfileRecord {
  param(
    [Parameter(Mandatory)]$Harness,
    [Parameter(Mandatory)][string]$SurfaceSha256,
    [Parameter(Mandatory)][string[]]$ReadableRoots,
    [Parameter(Mandatory)][string]$WritableRoot
  )
  $readableRecords = @($ReadableRoots | ForEach-Object { Get-CodexBoundaryRootRecord -LiteralPath $_ })
  $writableRecord = Get-CodexBoundaryRootRecord -LiteralPath $WritableRoot
  $configContent = Get-CodexBoundaryProfileContent -ReadableRootRecords $readableRecords -WritableRootRecord $writableRecord
  $configBytes = [Text.UTF8Encoding]::new($false).GetBytes($configContent)
  $record = [ordered]@{
    schema = $script:CodexBoundaryContract.schema
    harness = [ordered]@{
      path = $Harness.path; sha256 = $Harness.sha256; length = $Harness.length; version = $Harness.version
    }
    surfaceFixtureSha256 = $SurfaceSha256
    effectiveFeatureStates = $script:CodexBoundaryContract.featureStates
    argvTemplate = @(
      "exec", "--strict-config", "--ignore-rules", "--ephemeral", "--sandbox",
      "workspace-write", "--cd", [string]$writableRecord.path, "--skip-git-repo-check", "<prompt>"
    )
    isolatedCodexHome = [ordered]@{
      semantics = "controller-owned-unique-system-temp-direct-child"
      files = @([ordered]@{
        relativePath = "config.toml"
        sha256 = (Get-CodexBoundarySha256Bytes -Bytes $configBytes)
        byteLength = $configBytes.Length
        contentBase64 = [Convert]::ToBase64String($configBytes)
      })
    }
    readableRoots = [ordered]@{ semantics = "closed-enumerated-final-physical-roots"; roots = $readableRecords }
    writableRoot = [ordered]@{ semantics = "single-final-physical-root"; root = $writableRecord }
    networkPolicy = [ordered]@{
      direct = "deny"; public = "deny"; loopback = "deny-required"; namedPipe = "deny-required"; descendants = "deny-required"
    }
    descendantPolicy = [ordered]@{
      containment = "controller-owned-job-object"
      limitFlags = @("JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE")
      breakaway = "denied"
      assignBeforeEffect = $true
      surviveBoundaryExit = $false
      postExitDetectionAuthority = $false
    }
  }
  $record.profileSha256 = Get-CodexBoundaryProfileSha256 -Record $record
  return [pscustomobject]$record
}

function Resolve-CodexBoundaryRoot {
  param([Parameter(Mandatory)][string]$LiteralPath)
  if (-not [IO.Path]::IsPathFullyQualified($LiteralPath) -or
      -not (Test-Path -LiteralPath $LiteralPath -PathType Container)) {
    Throw-CodexBoundaryRefusal "codex-boundary-root-invalid"
  }
  $fullPath = [IO.Path]::GetFullPath($LiteralPath).TrimEnd(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar
  )
  $cursor = Get-Item -LiteralPath $fullPath -Force
  while ($null -ne $cursor) {
    if ($cursor.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
      Throw-CodexBoundaryRefusal "codex-boundary-root-reparse-ancestor"
    }
    $cursor = $cursor.Parent
  }
  return (Get-Item -LiteralPath $fullPath -Force).FullName
}

function Get-CodexBoundaryRootRecord {
  param([Parameter(Mandatory)][string]$LiteralPath)
  $resolved = Resolve-CodexBoundaryRoot -LiteralPath $LiteralPath
  $identity = [ChaseSets.Controller.CodexBoundaryNative]::GetIdentity($resolved).Split(':', 2)
  return [pscustomobject][ordered]@{
    path = $resolved
    volumeSerialNumber = $identity[0]
    fileId = $identity[1]
  }
}

function ConvertTo-CodexBoundaryCanonicalNode {
  param($Value)
  if ($null -eq $Value) { return $null }
  if ($Value -is [string] -or $Value -is [char] -or $Value -is [bool] -or
      $Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or
      $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or
      $Value -is [int64] -or $Value -is [uint64] -or $Value -is [single] -or
      $Value -is [double] -or $Value -is [decimal]) {
    return $Value
  }
  if ($Value -is [Collections.IDictionary]) {
    $ordered = [ordered]@{}
    $keys = @($Value.Keys | ForEach-Object { [string]$_ })
    [Array]::Sort($keys, [StringComparer]::Ordinal)
    foreach ($key in $keys) {
      $ordered[$key] = ConvertTo-CodexBoundaryCanonicalNode $Value[$key]
    }
    return $ordered
  }
  if ($Value -is [Collections.IEnumerable]) {
    return ,@($Value | ForEach-Object { ConvertTo-CodexBoundaryCanonicalNode $_ })
  }
  $properties = [ordered]@{}
  foreach ($property in $Value.PSObject.Properties) {
    $properties[$property.Name] = $property.Value
  }
  return ConvertTo-CodexBoundaryCanonicalNode $properties
}

function Get-CodexBoundaryProfileSha256 {
  param([Parameter(Mandatory)]$Record)
  $copy = [ordered]@{}
  if ($Record -is [Collections.IDictionary]) {
    foreach ($key in $Record.Keys) {
      if ([string]$key -cne "profileSha256") {
        $copy[[string]$key] = $Record[$key]
      }
    }
  } else {
    foreach ($property in $Record.PSObject.Properties) {
      if ($property.Name -cne "profileSha256") {
        $copy[$property.Name] = $property.Value
      }
    }
  }
  $canonical = ConvertTo-CodexBoundaryCanonicalNode $copy
  $json = $canonical | ConvertTo-Json -Compress -Depth 100
  return Get-CodexBoundarySha256Bytes -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($json))
}

function New-CodexLaunchBoundary {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string[]]$ReadableRoots,
    [Parameter(Mandatory)][string]$WritableRoot
  )
  $harness = Resolve-CodexBoundaryHarness
  $surfaceSha256 = Assert-CodexBoundarySurface -Harness $harness
  foreach ($root in @($ReadableRoots) + @($WritableRoot)) {
    [void](Resolve-CodexBoundaryRoot -LiteralPath $root)
  }
  return New-CodexBoundaryProfileRecord `
    -Harness $harness `
    -SurfaceSha256 $surfaceSha256 `
    -ReadableRoots $ReadableRoots `
    -WritableRoot $WritableRoot
}

function New-CodexBoundaryKillOnCloseJob {
  return [ChaseSets.Controller.CodexBoundaryNative]::CreateKillOnCloseJob()
}

function Add-CodexBoundaryProcessToJob {
  param(
    [Parameter(Mandatory)][Microsoft.Win32.SafeHandles.SafeFileHandle]$Job,
    [Parameter(Mandatory)][int]$ProcessId
  )
  [ChaseSets.Controller.CodexBoundaryNative]::AssignProcess($Job, $ProcessId)
}

function Test-CodexLaunchBoundaryStillValid {
  [CmdletBinding()]
  param([Parameter(Mandatory)]$Boundary)
  $requiredKeys = @(
    "argvTemplate", "descendantPolicy", "effectiveFeatureStates", "harness",
    "isolatedCodexHome", "networkPolicy", "profileSha256", "readableRoots",
    "schema", "surfaceFixtureSha256", "writableRoot"
  )
  $actualKeys = if ($Boundary -is [Collections.IDictionary]) {
    @($Boundary.Keys | ForEach-Object { [string]$_ })
  } else {
    @($Boundary.PSObject.Properties.Name)
  }
  [Array]::Sort($actualKeys, [StringComparer]::Ordinal)
  if (($actualKeys -join "`n") -cne ($requiredKeys -join "`n") -or
      [string]$Boundary.schema -cne $script:CodexBoundaryContract.schema -or
      [string]$Boundary.profileSha256 -cne (Get-CodexBoundaryProfileSha256 -Record $Boundary)) {
    Throw-CodexBoundaryRefusal "codex-boundary-revalidation-drift"
  }
  $harness = Resolve-CodexBoundaryHarness
  if ([string]$Boundary.harness.path -cne $harness.path -or
      [string]$Boundary.harness.sha256 -cne $harness.sha256 -or
      [int64]$Boundary.harness.length -ne $harness.length -or
      [string]$Boundary.harness.version -cne $harness.version) {
    Throw-CodexBoundaryRefusal "codex-boundary-revalidation-drift"
  }
  $surfaceSha256 = Assert-CodexBoundarySurface -Harness $harness
  if ([string]$Boundary.surfaceFixtureSha256 -cne $surfaceSha256) {
    Throw-CodexBoundaryRefusal "codex-boundary-revalidation-drift"
  }
  foreach ($root in @($Boundary.readableRoots.roots) + @($Boundary.writableRoot.root)) {
    $current = Get-CodexBoundaryRootRecord -LiteralPath ([string]$root.path)
    if ($current.path -cne [string]$root.path -or
        $current.volumeSerialNumber -cne [string]$root.volumeSerialNumber -or
        $current.fileId -cne [string]$root.fileId) {
      Throw-CodexBoundaryRefusal "codex-boundary-revalidation-drift"
    }
  }
  return $true
}

Export-ModuleMember -Function @(
  "Resolve-CodexBoundaryHarness",
  "New-CodexLaunchBoundary",
  "Test-CodexLaunchBoundaryStillValid"
)
