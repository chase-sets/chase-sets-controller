<#
Host hold/release is separate from dispatch ownership and watchdog history.
Persist Hold and verify its receipt BEFORE stopping the exact launch. Release
requires that receipt's holdId and complete launch binding; it never deletes a
record. There is no expiry, recovery grant, process termination or preemption.
#>
[CmdletBinding()]
param(
  [switch]$Library,
  [ValidateSet('Hold','Release')][string]$Action,
  [Alias('RuntimeRoot')][string]$HoldRuntimeRoot=$PSScriptRoot,
  [Alias('Label')][string]$HoldLabel,
  [Alias('LaunchId')][string]$HoldLaunchId,
  [Alias('AttemptId')][string]$HoldAttemptId,
  [Alias('Worktree')][string]$HoldWorktree,
  [Alias('Head')][string]$HoldHead,
  [string]$HoldId
)
$ErrorActionPreference='Stop'
function Enter-WatchdogHoldLock([string]$Root,[string]$Launch) {
  $key=[IO.Path]::GetFullPath($Root).TrimEnd('\','/').ToUpperInvariant()+"`n"+$Launch
  $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($key)))
  $mutex=[Threading.Mutex]::new($false,"Global\chase-sets-watchdog-hold-$hash")
  try { try { [void]$mutex.WaitOne() } catch [Threading.AbandonedMutexException] {} } catch { $mutex.Dispose();throw }
  return $mutex
}
function Read-WatchdogHold([string]$Root,$Spec) {
  $path=Join-Path $Root "watchdog-hold-$($Spec.launchId).json"
  try {
    $directory=Get-Item -LiteralPath $Root -Force -ErrorAction Stop
    if(-not$directory.PSIsContainer-or$directory.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)){throw 'unsafe root'}
    if(-not(Test-Path -LiteralPath $path)){return [pscustomobject]@{state='absent';path=$path;raw=$null;record=$null}}
    $file=Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if($file.PSIsContainer-or$file.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)-or$file.Length-gt16384){throw 'unsafe hold'}
    $raw=[Text.UTF8Encoding]::new($false,$true).GetString([IO.File]::ReadAllBytes($path))
    $document=[Text.Json.JsonDocument]::Parse($raw)
    try {
      $names=@($document.RootElement.EnumerateObject()|ForEach-Object Name)
      $keys=@('schemaVersion','holdId','launchId','attemptId','worktree','head','state')
      if($names.Count-ne$keys.Count-or@($keys|Where-Object{$_-cnotin$names}).Count){throw 'closed fields'}
    } finally {$document.Dispose()}
    $record=$raw|ConvertFrom-Json -DateKind String
    foreach($key in $keys){if($record.$key-isnot[string]){throw 'hold types'}}
    if($record.schemaVersion-cne'watchdog-host-hold/v1'-or$record.holdId-cnotmatch'^[a-f0-9]{32}$'-or
      $record.launchId-cne$Spec.launchId-or$record.attemptId-cne$Spec.attemptId-or$record.head-cne$Spec.head-or
      -not[string]::Equals([IO.Path]::GetFullPath($record.worktree).TrimEnd('\','/'),[IO.Path]::GetFullPath($Spec.worktree).TrimEnd('\','/'),[StringComparison]::OrdinalIgnoreCase)-or
      $record.state-cnotin@('held','released')){throw 'hold binding'}
    return [pscustomobject]@{state=$record.state;path=$path;raw=$raw;record=$record}
  } catch {return [pscustomobject]@{state='unknown';path=$path;raw=$null;record=$null}}
}
function Write-WatchdogHold([string]$Root,$Spec,[string]$Operation,[string]$ExpectedHoldId) {
  $current=Read-WatchdogHold $Root $Spec
  if($current.state-ceq'unknown'){throw 'WATCHDOG_HOLD_UNKNOWN'}
  if($Operation-ceq'Release'){
    if($current.state-cne'held'-or$ExpectedHoldId-cnotmatch'^[a-f0-9]{32}$'-or$current.record.holdId-cne$ExpectedHoldId){throw 'WATCHDOG_HOLD_RELEASE_REFUSED'}
    $record=$current.record;$record.state='released'
  }else{
    if($current.state-ceq'held'){throw 'WATCHDOG_HOLD_ALREADY_HELD'}
    $record=[ordered]@{schemaVersion='watchdog-host-hold/v1';holdId=[guid]::NewGuid().ToString('N');launchId=$Spec.launchId;attemptId=$Spec.attemptId;worktree=$Spec.worktree;head=$Spec.head;state='held'}
  }
  $temporary="$($current.path).$([guid]::NewGuid().ToString('N')).tmp"
  try {
    $stream=[IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try {$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($record|ConvertTo-Json -Compress));$stream.Write($bytes);$stream.Flush($true)}finally{$stream.Dispose()}
    $again=Read-WatchdogHold $Root $Spec
    if($again.state-cne$current.state-or$again.raw-cne$current.raw){throw 'WATCHDOG_HOLD_REPLACED'}
    [IO.File]::Move($temporary,$current.path,($current.state-cne'absent'))
    return $record
  }finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
}
if($Library){return}
if(-not$Action-or$HoldLabel-cnotmatch'^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$'-or$HoldLaunchId-cnotmatch'^[a-f0-9-]{36}$'-or
  $HoldAttemptId-cnotmatch'^[A-Za-z0-9][A-Za-z0-9._:/-]{0,255}$'-or$HoldHead-cnotmatch'^[a-f0-9]{40}$'-or-not[IO.Path]::IsPathFullyQualified($HoldWorktree)){throw 'WATCHDOG_HOLD_ARGUMENTS'}
$root=[IO.Path]::GetFullPath($HoldRuntimeRoot)
$mutex=Enter-WatchdogHoldLock $root $HoldLaunchId
try {
  $spec=Get-Content -LiteralPath (Join-Path $root "watchdog-lane-$HoldLabel.json") -Raw|ConvertFrom-Json -DateKind String
  if($spec.label-cne$HoldLabel-or$spec.launchId-cne$HoldLaunchId-or$spec.attemptId-cne$HoldAttemptId-or$spec.head-cne$HoldHead-or
    -not[string]::Equals([IO.Path]::GetFullPath($spec.worktree),[IO.Path]::GetFullPath($HoldWorktree),[StringComparison]::OrdinalIgnoreCase)){throw 'WATCHDOG_HOLD_SPEC_MISMATCH'}
  Write-WatchdogHold $root $spec $Action $HoldId|ConvertTo-Json -Compress
}finally{$mutex.ReleaseMutex();$mutex.Dispose()}
