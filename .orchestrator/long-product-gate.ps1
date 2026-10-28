<#
.SYNOPSIS
Fixed supervisor for the one long product gate admitted through dispatch-lane.

The supervisor has no command or payload surface. It consumes the exact launch
tuple published by dispatch-lane, invokes only invoke-heavy-verifier.ps1 with
Gate test:scripts, and leaves host observation and dispatch cleanup to the
outer launcher.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$RuntimeRoot,
  [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')][string]$LaunchId,
  [Parameter(Mandatory)][string]$Worktree,
  [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$')][string]$Lane,
  [Parameter(Mandatory)][string]$Branch,
  [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string]$ClaimedHead,
  [Parameter(Mandatory)][string]$ResultPath
)

$ErrorActionPreference = 'Stop'
$dispatchOwnership = Join-Path $PSScriptRoot 'dispatch-ownership.ps1'
if (-not (Test-Path -LiteralPath $dispatchOwnership -PathType Leaf)) { throw 'long-product-gate: dispatch ownership contract is missing' }
. $dispatchOwnership

function Test-SamePath([string]$Left, [string]$Right) {
  return [string]::Equals(
    [IO.Path]::GetFullPath($Left).TrimEnd('\','/'),
    [IO.Path]::GetFullPath($Right).TrimEnd('\','/'),
    [StringComparison]::OrdinalIgnoreCase
  )
}

function Write-AtomicResult($Value) {
  $temporary = "$ResultPath.$([guid]::NewGuid().ToString('N')).tmp"
  try {
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 10 -Compress))
    $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    [IO.File]::Move($temporary, $ResultPath, $true)
  } finally {
    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
  }
}

$runtimeFull = [IO.Path]::GetFullPath($RuntimeRoot).TrimEnd('\','/')
$expectedResult = Join-Path $runtimeFull "long-product-gate-$LaunchId.json"
if (-not (Test-SamePath $ResultPath $expectedResult)) { throw 'long-product-gate: result path is not bound to the launch id' }
if (-not (Test-Path -LiteralPath $runtimeFull -PathType Container)) { throw 'long-product-gate: runtime root is unavailable' }
$worktreeFull = [IO.Path]::GetFullPath($Worktree).TrimEnd('\','/')
$containerRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd('\','/')
if (-not (Test-Path -LiteralPath $worktreeFull -PathType Container) -or
    -not $worktreeFull.StartsWith($containerRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
  throw 'long-product-gate: worktree is not a child of the controller container'
}
$recordPath = Join-Path $runtimeFull "dispatch-launch-$LaunchId.json"
$record = $null
$recordDeadline = [DateTimeOffset]::UtcNow.AddSeconds(30)
while ($null -eq $record -and [DateTimeOffset]::UtcNow -lt $recordDeadline) {
  $candidate = Get-ValidatedDispatchOwnershipRecord $recordPath $runtimeFull ([IO.Path]::GetTempPath())
  if ($candidate -and $candidate.state -ceq 'started') {
    $currentStart = Get-DispatchProcessStartIdentity $PID
    if ([int]$candidate.childPid -eq $PID -and $currentStart -and $candidate.childStartIdentity -ceq $currentStart) {
      $record = $candidate
    }
  }
  if ($null -eq $record) { [Threading.Thread]::Sleep(10) }
}
if ($null -eq $record) { throw 'long-product-gate: exact dispatch owner was not published for this supervisor' }
if ($record.laneRole -cne 'implementation' -or $record.launchId -cne $LaunchId -or
    $record.lane -cne $Lane -or -not (Test-SamePath $record.worktree $worktreeFull) -or
    $record.branch -cne $Branch -or $record.head -cne $ClaimedHead) {
  throw 'long-product-gate: dispatch owner tuple does not match the supervisor handoff'
}
if (Test-Path -LiteralPath $ResultPath -PathType Leaf) { throw 'long-product-gate: result path is already occupied' }

$startedUtc = [DateTime]::UtcNow.ToString('o')
$pending = [ordered]@{
  schema = 'long-product-gate/v1'; status = 'pending'; launchId = $LaunchId
  lane = $Lane; worktree = $worktreeFull; branch = $Branch; head = $ClaimedHead
  gate = 'test:scripts'; startedUtc = $startedUtc; endedUtc = $null
  exit = $null; nativeExit = $null; dispatchReleased = $false; dispatchReleasedUtc = $null
}
Write-AtomicResult $pending

$verifier = Join-Path $PSScriptRoot 'invoke-heavy-verifier.ps1'
if (-not (Test-Path -LiteralPath $verifier -PathType Leaf)) { throw 'long-product-gate: fixed verifier is missing' }
$pwsh = (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1 -ExpandProperty Source)
$start = [Diagnostics.ProcessStartInfo]::new()
$start.FileName = $pwsh
$start.WorkingDirectory = $worktreeFull
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$stdoutPath = Join-Path $runtimeFull "long-product-gate-$LaunchId.stdout.log"
$stderrPath = Join-Path $runtimeFull "long-product-gate-$LaunchId.stderr.log"
foreach ($argument in @('-NoProfile','-NonInteractive','-File',$verifier)) { [void]$start.ArgumentList.Add($argument) }
foreach ($argument in @('-Gate','test:scripts','-Worktree',$worktreeFull,'-Lane',$Lane,'-Branch',$Branch,'-ClaimedHead',$ClaimedHead,'-ContainerRoot',$containerRoot)) { [void]$start.ArgumentList.Add($argument) }
$process = $null
$exitCode = 74
try {
  $process = [Diagnostics.Process]::Start($start)
  $stdout = $process.StandardOutput.ReadToEndAsync()
  $stderr = $process.StandardError.ReadToEndAsync()
  $process.WaitForExit()
  [IO.File]::WriteAllText($stdoutPath, $stdout.GetAwaiter().GetResult(), [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText($stderrPath, $stderr.GetAwaiter().GetResult(), [Text.UTF8Encoding]::new($false))
  $exitCode = [int]$process.ExitCode
  $endedUtc = [DateTime]::UtcNow.ToString('o')
  $terminal = [ordered]@{}
  foreach ($entry in $pending.GetEnumerator()) { $terminal[$entry.Key] = $entry.Value }
  $terminal.status = if ($exitCode -eq 0) { 'verifier-passed' } else { 'incomplete' }
  $terminal.endedUtc = $endedUtc; $terminal.exit = $exitCode; $terminal.nativeExit = $exitCode
  Write-AtomicResult $terminal
  [Console]::Error.WriteLine("long-product-gate: gate=test:scripts status=$($terminal.status) exit=$exitCode result=$ResultPath")
} catch {
  $endedUtc = [DateTime]::UtcNow.ToString('o')
  $terminal = [ordered]@{}
  foreach ($entry in $pending.GetEnumerator()) { $terminal[$entry.Key] = $entry.Value }
  $terminal.status = 'incomplete'; $terminal.endedUtc = $endedUtc; $terminal.exit = 74; $terminal.nativeExit = $null
  Write-AtomicResult $terminal
  [Console]::Error.WriteLine("long-product-gate: supervisor failure type=$($_.Exception.GetType().Name)")
  $exitCode = 74
} finally {
  if ($process) { $process.Dispose() }
}
exit $exitCode
