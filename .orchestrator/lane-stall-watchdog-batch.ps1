[CmdletBinding()]
param(
  [string]$LanesPath,
  [double]$PollSeconds=120,
  [int]$UnchangedPolls=3,
  [double]$WindowSeconds=7200,
  [Parameter(DontShow)][string]$TransportPath=(Join-Path $PSHOME 'pwsh.exe'),
  [Parameter(DontShow)][string]$ReducerScript=(Join-Path $PSScriptRoot 'lane-stall-watchdog.ps1'),
  [Parameter(DontShow)][string]$TestObservedAt,
  [Parameter(DontShow)][string]$DispatchScript,
  [Parameter(DontShow)][switch]$SynchronousDispatch
)
$ErrorActionPreference='Stop'
$identity=[ordered]@{pid=$PID;startIdentity=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')}
$source=$null
$phase='INPUT'
$exitCode=0
$exitReason='WINDOW_EXPIRED'
$lanes=@()
# 8186: a started reducer's own failure is contained per lane under these closed
# codes. Everything else (input loss, transport/reducer absence, start exceptions,
# unfollowable relaunch results) remains a fatal batch TRANSPORT_FAILURE.
$reducerFailureCodes=@('REDUCER_EXIT','RESULT_INVALID','WATCHDOG_RELAUNCH_WINDOW_EXPIRED')
function Report([string]$Event,[hashtable]$Fields=@{}){
  $row=[ordered]@{schemaVersion='watchdog-batch/v1';event=$Event;at=[datetimeoffset]::UtcNow.ToString('o');watcher=$identity;source=$source}
  foreach($key in $Fields.Keys){$row[$key]=$Fields[$key]}
  $row|ConvertTo-Json -Depth 8 -Compress
}
function Native-Path([string]$Path){
  # Only the retained drive-mounted WSL spelling is translated. Native drive
  # colons and spaces are never parsed as lane separators or shell arguments.
  if($Path-cmatch '^/mnt/([a-zA-Z])/(.*)$'){$Path=$Matches[1]+':/'+$Matches[2]}
  if(-not [IO.Path]::IsPathFullyQualified($Path)){throw 'INPUT_PATH'}
  return [IO.Path]::GetFullPath($Path)
}
function Read-Lane($Value){
  $keys=@($Value.PSObject.Properties.Name)
  if($Value.label-isnot[string]-or$Value.label-cnotmatch'^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$'-or
    @($keys|Where-Object{$_-cnotin@('label','runtimeRoot','transcriptPath','progressPath')}).Count-ne0){throw 'INPUT_LANE'}
  $runtime=Native-Path $Value.runtimeRoot
  $transcript=Native-Path $Value.transcriptPath
  if(-not[string]::Equals($transcript,(Join-Path $runtime "$($Value.label).jsonl"),[StringComparison]::OrdinalIgnoreCase)){throw 'INPUT_TRANSCRIPT'}
  $progress=if($Value.progressPath){Native-Path $Value.progressPath}else{$transcript}
  foreach($path in @($transcript,$progress,(Join-Path $runtime "watchdog-lane-$($Value.label).json"))){
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw 'INPUT_MISSING'}
  }
  return [pscustomobject]@{label=$Value.label;runtimeRoot=$runtime;transcriptPath=$transcript;progressPath=$progress;size=(Get-Item -LiteralPath $transcript).Length;progressSize=(Get-Item -LiteralPath $progress).Length;unchanged=0;terminal=$false;unresolved=$false}
}
function Assert-Transport{
  if(-not(Test-Path -LiteralPath $TransportPath -PathType Leaf)-or-not(Test-Path -LiteralPath $ReducerScript -PathType Leaf)){throw 'TRANSPORT_MISSING'}
}
function Observe($Lane,[string]$DetectedAt){
  $start=[Diagnostics.ProcessStartInfo]::new()
  $start.FileName=$TransportPath
  $start.UseShellExecute=$false
  $start.CreateNoWindow=$true
  $start.RedirectStandardOutput=$true
  $start.RedirectStandardError=$true
  $arguments=@('-NoProfile','-NonInteractive','-File',$ReducerScript,'-Label',$Lane.label,
    '-RuntimeRoot',$Lane.runtimeRoot,'-HistoryPath',(Join-Path $Lane.runtimeRoot 'dispatch-log.jsonl'),
    '-TranscriptPath',$Lane.transcriptPath,'-ObservedAt',$DetectedAt)
  if($DispatchScript){$arguments+=@('-DispatchScript',$DispatchScript)}
  if($SynchronousDispatch){$arguments+='-SynchronousDispatch'}
  foreach($argument in $arguments){[void]$start.ArgumentList.Add($argument)}
  $process=$null
  try{
    # A transport start exception is not a reducer failure: it escapes uncontained.
    $process=[Diagnostics.Process]::Start($start)
    $script:lastTransportPid=$process.Id
    $stdout=$process.StandardOutput.ReadToEndAsync()
    $stderr=$process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $output=$stdout.GetAwaiter().GetResult()
    $errorText=$stderr.GetAwaiter().GetResult()
    # Valid JSON cannot launder a failed command into lane health.
    if($process.ExitCode-ne0){
      if($errorText.Contains('WATCHDOG_RELAUNCH_WINDOW_EXPIRED')){throw 'WATCHDOG_RELAUNCH_WINDOW_EXPIRED'}
      throw 'REDUCER_EXIT'
    }
    $result=$null
    try{$result=ConvertFrom-Json -InputObject $output -DateKind String -ErrorAction Stop}catch{throw 'RESULT_INVALID'}
    $statuses=@('LIVE_SLOW','TERMINAL_SUCCESS','TERMINAL_AUTHORITY_STOP','OWNERSHIP_UNKNOWN','OBSERVATION_ONLY','ROUTING_PROVENANCE_REFUSED',
      'RETIRED_MODEL_REQUIRES_REDISPATCH','RESUME_REFUSED','HARNESS_CEILING','NO_QUALIFIED_FALLBACK','DUPLICATE_SKIPPED',
      'LAUNCH_PENDING','LAUNCH_FAILED','RELAUNCHED')
    if($null-eq$result-or$result-is[array]-or$result-isnot[pscustomobject]){throw 'RESULT_INVALID'}
    # A claimed relaunch the batch cannot follow exactly is a shared failure, not a
    # lane diagnosis: a replacement may exist that nobody is watching.
    $followable=$result.relaunch-is[bool]-and$result.relaunch-and$result.status-ceq'RELAUNCHED'-and$result.label-is[string]-and$result.label-cmatch'^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$'
    if(($result.relaunch-eq$true-or$result.status-ceq'RELAUNCHED')-and-not$followable){throw 'RELAUNCH_UNFOLLOWABLE'}
    if($result.schemaVersion-cne'watchdog-observation-result/v1'-or$result.status-isnot[string]-or$result.status-cnotin$statuses-or
      $result.relaunch-isnot[bool]-or$result.relaunch-ne($result.status-ceq'RELAUNCHED')){throw 'RESULT_INVALID'}
    # Do not publish arbitrary reducer text, error messages, or fixture fields.
    return [pscustomobject]@{status=$result.status;relaunch=$result.relaunch;label=$result.label;pid=$process.Id}
  }finally{if($process){$process.Dispose()}}
}
function Note-ReducerFailure($Lane,[string]$DetectedAt,[string]$Code){
  # Lane-labeled diagnosis: the lane stays watched, its cadence resets, and the
  # batch cannot exit zero until a later valid reduction resolves the flag.
  $Lane.unresolved=$true
  $Lane.unchanged=0
  Report 'REDUCER_FAILURE' @{label=$Lane.label;observedAt=$DetectedAt;code=$Code;transportPid=$script:lastTransportPid}
}
function Follow-Relaunch($Lane,$Result){
  # The reducer alone chose/started the replacement. Follow its canonical
  # transcript; a host-supplied session progress path needs membership re-arm.
  $replacement=Read-Lane ([pscustomobject]@{label=$Result.label;runtimeRoot=$Lane.runtimeRoot;transcriptPath=(Join-Path $Lane.runtimeRoot "$($Result.label).jsonl")})
  if(-not$labels.Add($replacement.label)){throw 'RESULT_INVALID'}
  foreach($key in @('label','transcriptPath','progressPath','size','progressSize','unchanged')){$Lane.$key=$replacement.$key}
  Report 'MEMBERSHIP_CHANGED' @{label=$Lane.label;runtimeRoot=$Lane.runtimeRoot;transcriptPath=$Lane.transcriptPath}
}
try{
  if(-not$IsWindows-or$PollSeconds-le0-or[double]::IsNaN($PollSeconds)-or[double]::IsInfinity($PollSeconds)-or
    $UnchangedPolls-lt1-or$WindowSeconds-le0-or[double]::IsNaN($WindowSeconds)-or[double]::IsInfinity($WindowSeconds)){throw 'INPUT_OPTIONS'}
  if(-not$LanesPath-or-not(Test-Path -LiteralPath $LanesPath -PathType Leaf)){throw 'INPUT_MISSING'}
  $bytes=[IO.File]::ReadAllBytes((Native-Path $LanesPath))
  $inputsHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
  $values=ConvertFrom-Json -InputObject ([Text.UTF8Encoding]::new($false,$true).GetString($bytes)) -NoEnumerate
  if($values-isnot[array]-or$values.Count-eq0){throw 'INPUT_LANES'}
  $labels=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $lanes=@(foreach($value in $values){$lane=Read-Lane $value;if(-not$labels.Add($lane.label)){throw 'INPUT_DUPLICATE'};$lane})
  if($TestObservedAt){$instant=[datetimeoffset]::Parse($TestObservedAt);if($instant.Offset-ne[timespan]::Zero){throw 'INPUT_INSTANT'}}
  $phase='TRANSPORT'
  Assert-Transport
  $head=@(& git -C $PSScriptRoot rev-parse HEAD 2>$null)
  $source=@{head=$(if($LASTEXITCODE-eq0-and$head.Count-eq1-and$head[0]-cmatch'^[a-f0-9]{40}$'){$head[0]}else{$null});
    entry=$PSCommandPath;entrySha256=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant();
    reducerSha256=(Get-FileHash -LiteralPath $ReducerScript -Algorithm SHA256).Hash.ToLowerInvariant();transport=$TransportPath}
  $clock=[Diagnostics.Stopwatch]::StartNew()
  Report 'STARTED' @{lanes=@($lanes|Select-Object label,runtimeRoot,transcriptPath,progressPath);pollSeconds=$PollSeconds;
    unchangedPolls=$UnchangedPolls;windowSeconds=$WindowSeconds;inputsSha256=$inputsHash}
  while($clock.Elapsed.TotalSeconds-lt$WindowSeconds){
    Start-Sleep -Seconds ([Math]::Min($PollSeconds,[Math]::Max(0,$WindowSeconds-$clock.Elapsed.TotalSeconds)))
    if($clock.Elapsed.TotalSeconds-ge$WindowSeconds){break}
    $phase='INPUT'
    if((Get-FileHash -LiteralPath $LanesPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()-cne$inputsHash){
      $exitReason='MEMBERSHIP_CHANGED';break
    }
    foreach($lane in $lanes){
      if($lane.terminal){continue}
      $phase='INPUT'
      $size=(Get-Item -LiteralPath $lane.transcriptPath -ErrorAction Stop).Length
      $progressSize=(Get-Item -LiteralPath $lane.progressPath -ErrorAction Stop).Length
      if($size-ne$lane.size-or$progressSize-ne$lane.progressSize){
        # Growth is cadence, not diagnosis: it never clears an unresolved lane error.
        $lane.size=$size;$lane.progressSize=$progressSize;$lane.unchanged=0
        Report 'PROGRESS' @{label=$lane.label;transcriptBytes=$size;progressBytes=$progressSize}
        continue
      }
      $lane.unchanged++
      Report 'UNCHANGED' @{label=$lane.label;unchangedPolls=$lane.unchanged}
      if($lane.unchanged-lt$UnchangedPolls){continue}
      $detectedAt=if($TestObservedAt){$TestObservedAt}else{[datetimeoffset]::UtcNow.ToString('o')}
      $phase='TRANSPORT'
      Assert-Transport # TRANSPORT_GUARD_PER_REDUCTION
      Report 'DETECTED' @{label=$lane.label;observedAt=$detectedAt}
      $result=$null
      $script:lastTransportPid=$null
      try{
        $result=Observe $lane $detectedAt
      }catch{
        if($_.Exception.Message-cnotin$reducerFailureCodes){throw}
        Note-ReducerFailure $lane $detectedAt $_.Exception.Message
      }
      if($null-eq$result){continue}
      Report 'OBSERVATION' @{label=$lane.label;observedAt=$detectedAt;status=$result.status;relaunch=$result.relaunch;transportPid=$result.pid}
      $lane.unchanged=0
      # Only a valid, non-duplicate reduction resolves an earlier lane error.
      if($result.status-cne'DUPLICATE_SKIPPED'){$lane.unresolved=$false}
      # Observation-only, unknown, pending and failed-launch lanes stay watched.
      $lane.terminal=$result.status-cin@('TERMINAL_SUCCESS','TERMINAL_AUTHORITY_STOP')
      if($result.relaunch){Follow-Relaunch $lane $result}
    }
    if(@($lanes|Where-Object{-not$_.terminal}).Count-eq0){$exitReason='ALL_TERMINAL';break}
  }
}catch{
  $exitCode=1;$exitReason='TRANSPORT_FAILURE'
  $code=if($_.Exception.Message-ceq'WATCHDOG_RELAUNCH_WINDOW_EXPIRED'){'WATCHDOG_RELAUNCH_WINDOW_EXPIRED'}else{"${phase}_UNKNOWN"}
  Report 'TRANSPORT_FAILURE' @{code=$code}
}finally{
  # An unresolved lane error is never a successful sweep, whatever ended it.
  $unresolved=@(@($lanes)|Where-Object{$null-ne$_-and$_.unresolved}).Count
  if($unresolved-gt0){$exitCode=1}
  Report 'EXIT' @{reason=$exitReason;exitCode=$exitCode;unresolvedReducerFailures=$unresolved}
}
exit $exitCode
