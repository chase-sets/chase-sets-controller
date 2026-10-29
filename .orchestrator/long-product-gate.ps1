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
$queuePollSeconds = 30
$queueWaitCapSeconds = 3600
$queueRetentionSeconds = 600
$transientCallerEligibilityRefusal = 'heavy-verifier: caller eligibility: dispatch census evaluation exhausted'
# Three consecutive full census expiries allow two bounded re-presentations
# without making a long gate spin forever; any queued presentation resets it.
$transientRefusalCap = 3
$consecutiveTransientRefusals = 0
$queueWatch = $null
$queueTicket = $null
$previousPresentationSeconds = 0
$presentationWatch = [Diagnostics.Stopwatch]::StartNew()
try {
  while ($true) {
    if ($queueWatch -and $queueWatch.Elapsed.TotalSeconds -ge $queueWaitCapSeconds) {
      $message = "long-product-gate: queued wait cap $queueWaitCapSeconds seconds reached"
      [Console]::Error.WriteLine($message)
      [IO.File]::AppendAllText($stderrPath, "$message`n", [Text.UTF8Encoding]::new($false))
      $exitCode = 73
      break
    }
    $presentationSeconds = $presentationWatch.Elapsed.TotalSeconds
    $process = [Diagnostics.Process]::Start($start)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $presentationOutput = $stdout.GetAwaiter().GetResult()
    $presentationError = $stderr.GetAwaiter().GetResult()
    [IO.File]::AppendAllText($stdoutPath, $presentationOutput, [Text.UTF8Encoding]::new($false))
    [IO.File]::AppendAllText($stderrPath, $presentationError, [Text.UTF8Encoding]::new($false))
    $exitCode = [int]$process.ExitCode
    $process.Dispose(); $process = $null
    $isTransientCallerEligibilityRefusal = $exitCode -eq 73 -and
      @($presentationError -split "`r?`n" | Where-Object { $_ -ceq $transientCallerEligibilityRefusal }).Count -gt 0
    if ($isTransientCallerEligibilityRefusal) {
      if (-not $queueWatch) { $queueWatch = [Diagnostics.Stopwatch]::StartNew() }
      $consecutiveTransientRefusals++
      $ticketLabel = if ($null -ne $queueTicket) { $queueTicket } else { '<none>' }
      $message = "long-product-gate: transient caller-eligibility refusal; re-presenting (ticket=$ticketLabel count=$consecutiveTransientRefusals)"
      [Console]::Error.WriteLine($message)
      [IO.File]::AppendAllText($stderrPath, "$message`n", [Text.UTF8Encoding]::new($false))
      if ($consecutiveTransientRefusals -ge $transientRefusalCap) {
        $message = "long-product-gate: transient caller-eligibility refusal cap $transientRefusalCap reached"
        [Console]::Error.WriteLine($message)
        [IO.File]::AppendAllText($stderrPath, "$message`n", [Text.UTF8Encoding]::new($false))
        break
      }
      $queueSleepMilliseconds = [int](1000 * [Math]::Min($queuePollSeconds, [Math]::Max(0, $queueWaitCapSeconds - $queueWatch.Elapsed.TotalSeconds)))
      [Threading.Thread]::Sleep($queueSleepMilliseconds)
      continue
    }
    if ($exitCode -ne 73 -or -not $presentationError.StartsWith('heavy-verifier: queued;', [StringComparison]::Ordinal)) {
      if ($queueTicket) {
        $admissionTicketMatch = [regex]::Match("$presentationOutput`n$presentationError", '(?m)^heavy-verifier: [^\r\n]*\bticket=([0-9]+)(?:[ ;)]|$)')
        if ($admissionTicketMatch.Success) {
          $admissionTicket = $admissionTicketMatch.Groups[1].Value
          $message = "long-product-gate: admission ticket comparison (previous=$queueTicket current=$admissionTicket)"
          $replacementPossible = $admissionTicket -cne $queueTicket
        } else {
          $message = "long-product-gate: admission ticket comparison unavailable (previous=$queueTicket)"
          $replacementPossible = ($presentationSeconds - $previousPresentationSeconds) -gt $queueRetentionSeconds
        }
        [Console]::Error.WriteLine($message)
        [IO.File]::AppendAllText($stderrPath, "$message`n", [Text.UTF8Encoding]::new($false))
        if ($replacementPossible) {
          $message = "long-product-gate: queue ticket replaced before admission (previous=$queueTicket)"
          [Console]::Error.WriteLine($message)
          [IO.File]::AppendAllText($stderrPath, "$message`n", [Text.UTF8Encoding]::new($false))
        }
      }
      break
    }
    $ticketMatch = [regex]::Match($presentationError, '\Aheavy-verifier: queued; ticket=([0-9]+) ')
    if (-not $ticketMatch.Success) { break }
    $presentedTicket = $ticketMatch.Groups[1].Value
    if ($queueTicket -and $presentedTicket -cne $queueTicket) {
      $message = 'long-product-gate: queue ticket changed'
      [Console]::Error.WriteLine($message)
      [IO.File]::AppendAllText($stderrPath, "$message`n", [Text.UTF8Encoding]::new($false))
      break
    }
    if (-not $queueWatch) {
      $queueWatch = [Diagnostics.Stopwatch]::StartNew()
    }
    if ($null -eq $queueTicket) {
      $queueTicket = $presentedTicket
    }
    $consecutiveTransientRefusals = 0
    $previousPresentationSeconds = $presentationSeconds
    $queueSleepMilliseconds = [int](1000 * [Math]::Min($queuePollSeconds, [Math]::Max(0, $queueWaitCapSeconds - $queueWatch.Elapsed.TotalSeconds)))
    [Threading.Thread]::Sleep($queueSleepMilliseconds)
  }
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
