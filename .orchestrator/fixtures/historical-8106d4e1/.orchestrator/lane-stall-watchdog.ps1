[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$')][string]$Label,
  [string]$RuntimeRoot=$PSScriptRoot,
  [string]$HistoryPath=(Join-Path $PSScriptRoot 'dispatch-log.jsonl'),
  [string]$TranscriptPath,
  [string]$ObservedAt=([DateTime]::UtcNow.ToString('o')),
  [Parameter(DontShow)][string]$ObservationFixture,
  [Parameter(DontShow)][string]$DispatchScript=(Join-Path $PSScriptRoot 'dispatch-lane.ps1'),
  [Parameter(DontShow)][string]$LogScript=(Join-Path $PSScriptRoot 'log-event.ps1'),
  [Parameter(DontShow)][switch]$SynchronousDispatch
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'dispatch-ownership.ps1')
Import-Module (Join-Path $PSScriptRoot 'review-head-contract.psm1') -Force -DisableNameChecking
function Test-ExactKeys($Value,[string[]]$Expected){$actual=@($Value.PSObject.Properties.Name);return $actual.Count-eq$Expected.Count-and@($Expected|Where-Object{$_-cnotin$actual}).Count-eq0}
function Test-Instant($Value){$parsed=[datetimeoffset]::MinValue;return $Value-is[string]-and[datetimeoffset]::TryParse([string]$Value,[ref]$parsed)}
function Get-IdentityState($PidValue,[string]$Start){
  $pidNumber=0;$instant=[datetimeoffset]::MinValue
  if(-not[int]::TryParse([string]$PidValue,[ref]$pidNumber)-or$pidNumber-lt1-or-not[datetimeoffset]::TryParse($Start,[ref]$instant)){return 'ambiguous'}
  try{$candidate=@(Get-Process -Id $pidNumber -ErrorAction SilentlyContinue);if($candidate.Count-eq0){return 'dead'};if($candidate.Count-ne1){return 'ambiguous'};return $(if($candidate[0].StartTime.ToUniversalTime().Ticks-eq$instant.ToUniversalTime().Ticks){'live'}else{'reused'})}catch{return 'ambiguous'}
}
function Get-DescendantState($Spec){
  try{
    $recorded=[datetimeoffset]::Parse([string]$Spec.launcherStartIdentity).ToUniversalTime();$queue=[Collections.Generic.Queue[int]]::new();$seen=[Collections.Generic.HashSet[int]]::new()
    foreach($pidValue in @($Spec.launcherPid,$Spec.childPid)){if($null-ne$pidValue-and$seen.Add([int]$pidValue)){$queue.Enqueue([int]$pidValue)}}
    while($queue.Count-gt0){$parent=$queue.Dequeue();$children=@(Get-CimInstance Win32_Process -Filter "ParentProcessId = $parent" -ErrorAction Stop)
      foreach($child in $children){$pidNumber=0;if(-not[int]::TryParse([string]$child.ProcessId,[ref]$pidNumber)-or$pidNumber-lt1){return 'ambiguous'}
        $created=if($child.CreationDate-is[datetime]){([datetime]$child.CreationDate).ToUniversalTime()}else{[Management.ManagementDateTimeConverter]::ToDateTime([string]$child.CreationDate).ToUniversalTime()}
        $exact=@(Get-CimInstance Win32_Process -Filter "ProcessId = $pidNumber" -ErrorAction Stop);if($exact.Count-ne1){return 'ambiguous'}
        $exactCreated=if($exact[0].CreationDate-is[datetime]){([datetime]$exact[0].CreationDate).ToUniversalTime()}else{[Management.ManagementDateTimeConverter]::ToDateTime([string]$exact[0].CreationDate).ToUniversalTime()}
        if($exactCreated.Ticks-ne$created.Ticks){return 'ambiguous'}
        if($created.Ticks-ge$recorded.Ticks){return 'possible'}
        if($seen.Add($pidNumber)){$queue.Enqueue($pidNumber)}
      }
    }
    return 'none'
  }catch{return 'ambiguous'}
}
function Get-Tail([string]$Path){if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return ''};$text=[IO.File]::ReadAllText($Path);return $text.Substring([Math]::Max(0,$text.Length-16384))}
function Get-ProviderDeathSignature([string]$ErrorTail){
  $lines=@($ErrorTail -split "`r?`n"|ForEach-Object{$_.Trim()}|Where-Object{$_})
  if(@($lines|Where-Object{$_-cin@('provider quota exceeded','provider quota exhausted')}).Count-gt0){return 'PROVIDER_QUOTA'}
  if(@($lines|Where-Object{$_-cin@('session limit reached','session limit exceeded')}).Count-gt0){return 'SESSION_LIMIT'}
  if(@($lines|Where-Object{$_-ceq'stream disconnected'}).Count-gt0){return 'STREAM_DISCONNECTED'}
  if(@($lines|Where-Object{$_-ceq'code-mode host closed'}).Count-gt0){return 'CODE_MODE_HOST_CLOSED'}
  return 'OWNER_DEAD'
}
function Test-AckInstant($Value){$parsed=[datetimeoffset]::MinValue;return $Value-is[string]-and[datetimeoffset]::TryParse([string]$Value,[ref]$parsed)}
function Read-StartAcknowledgement([string]$Path,[string]$RequestIdentity,[string]$ExpectedLabel,[string]$ExpectedWorktree,[string]$ExpectedBranch,[string]$ExpectedHead,[string]$Harness,[string]$Model,[string]$Effort,[long]$Row,[string]$Placement){
  if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
  $ack=Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json -DateKind String -ErrorAction Stop
  $keys=@('schemaVersion','requestIdentity','label','launchId','ownershipRecordPath','worktree','branch','head','harness','model','effort','row','placement','state','childPid','childStartIdentity')
  if(-not(Test-ExactKeys $ack $keys)-or$ack.schemaVersion-cne'dispatch-start-ack/v1'-or$ack.requestIdentity-cne$RequestIdentity-or$ack.label-cne$ExpectedLabel-or
    -not[string]::Equals([IO.Path]::GetFullPath([string]$ack.worktree).TrimEnd('\','/'),[IO.Path]::GetFullPath($ExpectedWorktree).TrimEnd('\','/'),[StringComparison]::OrdinalIgnoreCase)-or
    [string]$ack.branch-cne$ExpectedBranch-or[string]$ack.head-cne$ExpectedHead-or$ack.harness-cne$Harness-or$ack.model-cne$Model-or$ack.effort-cne$Effort-or
    $ack.row-isnot[long]-or$ack.row-ne$Row-or$ack.placement-cne$Placement-or$ack.state-cne'started'-or$ack.launchId-cnotmatch'^[a-f0-9-]{36}$'-or
    $ack.childPid-isnot[long]-or$ack.childPid-lt1-or-not(Test-AckInstant $ack.childStartIdentity)){throw 'WATCHDOG_START_ACK_UNKNOWN'}
  $ownerExpected=Join-Path ([IO.Path]::GetFullPath($RuntimeRoot)) "dispatch-launch-$($ack.launchId).json"
  if(-not[string]::Equals([IO.Path]::GetFullPath([string]$ack.ownershipRecordPath),$ownerExpected,[StringComparison]::OrdinalIgnoreCase)){throw 'WATCHDOG_START_ACK_OWNER_UNKNOWN'}
  return $ack
}
function Resolve-LegacyRoutingProvenance($LegacySpec){
  if(-not(Test-Path -LiteralPath $HistoryPath -PathType Leaf)){return [pscustomobject]@{accepted=$false;reason='MISSING'}}
  $history=Read-ExactHeadReviewHistory -Path $HistoryPath
  if(-not$history.complete){return [pscustomobject]@{accepted=$false;reason="HISTORY_$($history.reason)"}}
  $lane=Split-Path -Leaf ([IO.Path]::GetFullPath([string]$LegacySpec.worktree))
  $transcript=Split-Path -Leaf ([IO.Path]::GetFullPath([string]$LegacySpec.partialReportPath))
  $expectedKeys=@('ts','kind','dispatchRoutingSchema','attemptId','label','lane','laneRole','transcript','harness','model','effort','row','placement','worktree','branch','head')
  $candidates=[Collections.Generic.List[object]]::new()
  foreach($row in @($history.rows)){
    $value=$row.value
    if($null-eq$value.PSObject.Properties['dispatchRoutingSchema']-or[string]$value.dispatchRoutingSchema-cne'watchdog-dispatch-routing/v1'){continue}
    $actual=@($value.PSObject.Properties.Name);$route=0
    if($actual.Count-ne$expectedKeys.Count-or@($expectedKeys|Where-Object{$_-cnotin$actual}).Count-ne0-or-not(Test-Instant $value.ts)-or
      [string]$value.kind-cne'dispatch'-or[string]$value.attemptId-cne[string]$LegacySpec.attemptId-or[string]$value.label-cne[string]$LegacySpec.label-or
      [string]$value.lane-cne$lane-or[string]$value.laneRole-cne'implementation'-or[string]$value.transcript-cne$transcript-or
      [string]$value.harness-cne[string]$LegacySpec.harness-or[string]$value.model-cne[string]$LegacySpec.model-or[string]$value.effort-cne[string]$LegacySpec.effort-or
      -not[int]::TryParse([string]$value.row,[ref]$route)-or$route-lt1-or[string]$value.placement-cnotmatch'^(measured|provisional|override-[a-z0-9._-]+)$'-or
      -not[string]::Equals([IO.Path]::GetFullPath([string]$value.worktree).TrimEnd('\','/'),[IO.Path]::GetFullPath([string]$LegacySpec.worktree).TrimEnd('\','/'),[StringComparison]::OrdinalIgnoreCase)-or
      [string]$value.branch-cne[string]$LegacySpec.branch-or[string]$value.head-cne[string]$LegacySpec.head){continue}
    $candidates.Add([pscustomobject]@{row=[long]$route;placement=[string]$value.placement})
  }
  if($candidates.Count-ne1){return [pscustomobject]@{accepted=$false;reason=$(if($candidates.Count-eq0){'MISSING_OR_MISMATCHED'}else{'AMBIGUOUS'});candidateCount=$candidates.Count}}
  return [pscustomobject]@{accepted=$true;row=[long]$candidates[0].row;placement=[string]$candidates[0].placement}
}

$specPath=Join-Path ([IO.Path]::GetFullPath($RuntimeRoot)) "watchdog-lane-$Label.json"
if(-not(Test-Path -LiteralPath $specPath -PathType Leaf)){throw 'WATCHDOG_UNKNOWN_SPEC_MISSING'}
$spec=Get-Content -LiteralPath $specPath -Raw|ConvertFrom-Json -DateKind String -ErrorAction Stop
$legacyKeys=@('schemaVersion','label','attemptId','relaunchCount','resumeOfLaunchId','harness','model','effort','laneRole','originalPromptPath','partialReportPath','errorPath','worktree','branch','head','launchId','ownershipRecordPath','launcherPid','launcherStartIdentity','childPid','childStartIdentity','state','exitCode','updatedAt')
$keys=@('schemaVersion','label','attemptId','relaunchCount','resumeOfLaunchId','harness','model','effort','row','placement','laneRole','originalPromptPath','partialReportPath','errorPath','worktree','branch','head','launchId','ownershipRecordPath','launcherPid','launcherStartIdentity','childPid','childStartIdentity','state','exitCode','updatedAt')
$legacy=Test-ExactKeys $spec $legacyKeys
if($legacy-and$spec.schemaVersion-ceq'watchdog-lane/v1'){
  $routing=Resolve-LegacyRoutingProvenance $spec
  if(-not$routing.accepted){[pscustomobject]@{schemaVersion='watchdog-observation-result/v1';status='ROUTING_PROVENANCE_REFUSED';relaunch=$false;reason=[string]$routing.reason;candidateCount=$(if($null-ne$routing.PSObject.Properties['candidateCount']){[int]$routing.candidateCount}else{0})}|ConvertTo-Json -Compress;return}
  $spec|Add-Member -NotePropertyName row -NotePropertyValue ([long]$routing.row)
  $spec|Add-Member -NotePropertyName placement -NotePropertyValue ([string]$routing.placement)
  $spec.schemaVersion='watchdog-lane/v2'
}
$supported=@{
  '2|gpt-5.6-terra/medium'=$true;'2|gpt-5.6-luna/medium'=$true;'3|claude-sonnet-5/medium'=$true
  '4|gpt-5.6-sol/high'=$true;'4|gpt-6-astra/high'=$true;'4|gpt-5.6-sol/medium'=$true
  '5|gpt-5.6-sol/high'=$true;'5|gpt-6-astra/high'=$true;'5|gpt-5.6-sol/xhigh'=$true
  '6|claude-opus-5/high'=$true;'6|gpt-6-astra/high'=$true;'6|gpt-5.6-sol/high'=$true
  '7|gpt-5.6-sol/high'=$true;'7|claude-fable-5-1/high'=$true;'7|gpt-6-astra/high'=$true
  '10|gpt-5.6-sol/high'=$true;'10|gpt-6-astra/high'=$true;'10|claude-sonnet-5/high'=$true
  '13|claude-sonnet-5/medium'=$true;'14|claude-fable-5-1/medium'=$true;'14|claude-fable-5-1/high'=$true;'14|gpt-6-astra/high'=$true
  '15|claude-fable-5-1/high'=$true;'15|gpt-6-astra/high'=$true
}
$routeKey="$($spec.row)|$($spec.model)/$($spec.effort)"
# These standing author placements come from Todd's row-7/14/15 ruling,
# never from task prose or the ordinary row-7 Sol compatibility route.
$astraAuthor=$routeKey-cin@('7|gpt-6-astra/high','14|gpt-6-astra/high')
$toddAuthor=$astraAuthor-or$routeKey-cin@('7|claude-fable-5-1/high','14|claude-fable-5-1/medium','14|claude-fable-5-1/high','15|claude-fable-5-1/high','15|gpt-6-astra/high')
if(-not(Test-ExactKeys $spec $keys)-or$spec.schemaVersion-cne'watchdog-lane/v2'-or$spec.label-cne$Label-or
  $spec.attemptId-cnotmatch'^[A-Za-z0-9][A-Za-z0-9._:/-]{0,255}$'-or$spec.relaunchCount-isnot[long]-or$spec.relaunchCount-lt0-or$spec.relaunchCount-gt3-or
  $spec.launchId-cnotmatch'^[a-f0-9-]{36}$'-or$spec.harness-cnotin@('codex','claude')-or$spec.model-cnotin@('gpt-5.6-luna','gpt-5.6-terra','gpt-5.6-sol','gpt-6-astra','claude-sonnet-5','claude-opus-5','claude-fable-5-1')-or
  $spec.effort-cnotin@('minimal','low','medium','high','xhigh','max')-or$spec.row-isnot[long]-or-not$supported.ContainsKey($routeKey)-or
  ($spec.placement-cnotmatch'^(measured|provisional|override-[a-z0-9._-]+)$'-and-not($toddAuthor-and$spec.placement-ceq'override-Todd'))-or
  ($astraAuthor-and$spec.placement-cne'override-Todd')-or$spec.laneRole-cne'implementation'-or
  ($spec.harness-ceq'codex'-and$spec.model-notlike'gpt-*')-or($spec.harness-ceq'claude'-and$spec.model-notlike'claude-*')-or
  ($null-ne$spec.resumeOfLaunchId-and[string]$spec.resumeOfLaunchId-cnotmatch'^[a-f0-9-]{36}$')-or
  $spec.state-cnotin@('launching','running','exited')-or$spec.launcherPid-isnot[long]-or$spec.launcherPid-lt1-or-not(Test-Instant $spec.launcherStartIdentity)-or-not(Test-Instant $spec.updatedAt)-or
  ($spec.state-ceq'launching'-and($null-ne$spec.childPid-or$null-ne$spec.childStartIdentity-or$null-ne$spec.exitCode))-or
  ($spec.state-in@('running','exited')-and($spec.childPid-isnot[long]-or$spec.childPid-lt1-or-not(Test-Instant $spec.childStartIdentity)))-or
  ($spec.state-ceq'running'-and$null-ne$spec.exitCode)-or($spec.state-ceq'exited'-and$spec.exitCode-isnot[long])){throw 'WATCHDOG_UNKNOWN_SPEC_INVALID'}
$runtimeFull=[IO.Path]::GetFullPath($RuntimeRoot).TrimEnd('\','/')
$expectedPartial=Join-Path $runtimeFull "$Label.jsonl";$expectedError=Join-Path $runtimeFull "$Label.err.log"
$expectedOwner=Join-Path $runtimeFull "dispatch-launch-$($spec.launchId).json"
if(-not[string]::Equals([IO.Path]::GetFullPath([string]$spec.partialReportPath),$expectedPartial,[StringComparison]::OrdinalIgnoreCase)){throw 'WATCHDOG_UNKNOWN_SPEC_PARTIAL_PATH'}
if(-not[string]::Equals([IO.Path]::GetFullPath([string]$spec.errorPath),$expectedError,[StringComparison]::OrdinalIgnoreCase)){throw 'WATCHDOG_UNKNOWN_SPEC_ERROR_PATH'}
if(-not[string]::Equals([IO.Path]::GetFullPath([string]$spec.ownershipRecordPath),$expectedOwner,[StringComparison]::OrdinalIgnoreCase)){throw 'WATCHDOG_UNKNOWN_SPEC_OWNER_PATH'}
if($spec.branch-cnotmatch'^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}$'-or$spec.head-cnotmatch'^[a-f0-9]{40}$'){throw 'WATCHDOG_UNKNOWN_SPEC_GIT_IDENTITY'}
if(-not(Test-Path -LiteralPath ([string]$spec.originalPromptPath) -PathType Leaf)){throw 'WATCHDOG_UNKNOWN_SPEC_ORIGINAL_PROMPT'}
if(-not(Test-Path -LiteralPath ([string]$spec.worktree) -PathType Container)){throw 'WATCHDOG_UNKNOWN_SPEC_WORKTREE'}
$fixture=if($ObservationFixture){Get-Content -LiteralPath $ObservationFixture -Raw|ConvertFrom-Json -DateKind String -ErrorAction Stop}else{$null}
if(-not$fixture-and(Test-Path -LiteralPath $expectedOwner -PathType Leaf)){
  $record=Get-ValidatedDispatchOwnershipRecord $expectedOwner $runtimeFull ([IO.Path]::GetTempPath())
  if($null-eq$record-or[string]$record.launchId-cne[string]$spec.launchId-or[int64]$record.launcherPid-ne[int64]$spec.launcherPid-or
    [string]$record.launcherStartIdentity-cne[string]$spec.launcherStartIdentity-or
    ($record.state-ceq'started'-and([int64]$record.childPid-ne[int64]$spec.childPid-or[string]$record.childStartIdentity-cne[string]$spec.childStartIdentity))){throw 'WATCHDOG_UNKNOWN_OWNER_PROVENANCE'}
}
$partial=[IO.Path]::GetFullPath($(if($TranscriptPath){$TranscriptPath}else{[string]$spec.partialReportPath}))
if(-not[string]::Equals($partial,[IO.Path]::GetFullPath([string]$spec.partialReportPath),[StringComparison]::OrdinalIgnoreCase)-or-not(Test-Path -LiteralPath $partial -PathType Leaf)){throw 'WATCHDOG_UNKNOWN_PARTIAL'}
$ownerState=if($fixture){[string]$fixture.ownerState}else{
  $launcher=Get-IdentityState $spec.launcherPid ([string]$spec.launcherStartIdentity)
  if($null-eq$spec.childPid){$launcher}else{
    $child=Get-IdentityState $spec.childPid ([string]$spec.childStartIdentity)
    if($launcher-ceq'dead'-and$child-ceq'dead'){'dead'}elseif($launcher-ceq'live'-or$child-ceq'live'){'live'}elseif($launcher-ceq'reused'-or$child-ceq'reused'){'reused'}else{'ambiguous'}
  }
}
$descendantState=if($fixture){[string]$fixture.descendantState}else{Get-DescendantState $spec}
$stopped=if($fixture){$fixture.transcriptStopped-eq$true}else{$true}
$observed=if($fixture){[datetimeoffset]::Parse([string]$fixture.observedAt).ToUniversalTime()}else{[datetimeoffset]::Parse($ObservedAt).ToUniversalTime()}
$now=if($fixture){[datetimeoffset]::Parse([string]$fixture.nowUtc).ToUniversalTime()}else{[datetimeoffset]::UtcNow}
if($ownerState-ceq'live'){
  [pscustomobject]@{schemaVersion='watchdog-observation-result/v1';status='LIVE_SLOW';relaunch=$false;diagnosis='TWO_NO_DELTA_CYCLES_REMAINS'}|ConvertTo-Json -Compress;return
}
if($spec.state-ceq'exited'-and$spec.exitCode-eq0){
  [pscustomobject]@{schemaVersion='watchdog-observation-result/v1';status='TERMINAL_SUCCESS';relaunch=$false}|ConvertTo-Json -Compress;return
}
if($ownerState-cne'dead'-or$descendantState-cne'none'-or-not$stopped){
  [pscustomobject]@{schemaVersion='watchdog-observation-result/v1';status='OWNERSHIP_UNKNOWN';relaunch=$false;ownerState=$ownerState;descendantState=$descendantState}|ConvertTo-Json -Compress;return
}
$signature=Get-ProviderDeathSignature (Get-Tail ([string]$spec.errorPath))
if($signature-cnotin@('OWNER_DEAD','STREAM_DISCONNECTED','CODE_MODE_HOST_CLOSED','PROVIDER_QUOTA','SESSION_LIMIT')){throw 'WATCHDOG_UNKNOWN_SIGNATURE'}
$elapsed=($now-$observed).TotalSeconds
if($elapsed-lt0-or$elapsed-gt300){throw 'WATCHDOG_RELAUNCH_WINDOW_EXPIRED'}
$bytes=(Get-Item -LiteralPath $partial).Length
$identityInput="$($spec.attemptId)`n$($spec.launchId)`n$signature`n$bytes"
$observationIdentity=([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($identityInput)))).ToLowerInvariant()
$nextCount=[int]$spec.relaunchCount+1
if($nextCount-gt3){
  try{& $LogScript -Log dispatch -Kind lane-blocked -WatchdogSchema watchdog-relaunch/v1 -WatchdogAttemptId ([string]$spec.attemptId) -WatchdogLaunchId ([string]$spec.launchId) -DeathSignature $signature -ObservationIdentity $observationIdentity -RelaunchCount 3 -ResumedPartial $partial -WatchdogObservedAt $observed.ToString('o') -Lane $Label -Harness ([string]$spec.harness) -Model ([string]$spec.model) -Effort ([string]$spec.effort) -Row ([string]$spec.row) -Placement ([string]$spec.placement) -Outcome HARNESS_CEILING -OutFile $HistoryPath -NoBoard|Out-Null}catch{if($_.Exception.Message-notmatch'WATCHDOG_OBSERVATION_DUPLICATE'){throw}}
  [pscustomobject]@{schemaVersion='watchdog-observation-result/v1';status='HARNESS_CEILING';relaunch=$false;relaunchCount=3;implementationAttemptIncrement=0}|ConvertTo-Json -Compress;return
}
$nextHarness=[string]$spec.harness;$nextModel=[string]$spec.model;$nextEffort=[string]$spec.effort;$nextPlacement=[string]$spec.placement
if($signature-in@('PROVIDER_QUOTA','SESSION_LIMIT')){
  $fallback=@{
    '2|gpt-5.6-luna/medium'=@('codex','gpt-5.6-terra','medium')
    '4|gpt-6-astra/high'=@('codex','gpt-5.6-sol','high');'4|gpt-5.6-sol/medium'=@('codex','gpt-5.6-sol','high')
    '5|gpt-6-astra/high'=@('codex','gpt-5.6-sol','high');'5|gpt-5.6-sol/xhigh'=@('codex','gpt-5.6-sol','high')
    '6|claude-opus-5/high'=@('codex','gpt-5.6-sol','high');'6|gpt-6-astra/high'=@('codex','gpt-5.6-sol','high')
    # Row 7 has no closed scope discriminator: never infer noncore authority
    # for a lower-tier fallback. Astra also preserves the Fable reserve.
    '7|claude-fable-5-1/high'=@('codex','gpt-6-astra','high')
    '10|gpt-6-astra/high'=@('codex','gpt-5.6-sol','high');'10|claude-sonnet-5/high'=@('codex','gpt-5.6-sol','high')
    '14|claude-fable-5-1/medium'=@('codex','gpt-6-astra','high');'14|claude-fable-5-1/high'=@('codex','gpt-6-astra','high')
    '15|claude-fable-5-1/high'=@('codex','gpt-6-astra','high')
  }
  if(-not$fallback.ContainsKey($routeKey)){
    try{& $LogScript -Log dispatch -Kind lane-blocked -WatchdogSchema watchdog-relaunch/v1 -WatchdogAttemptId ([string]$spec.attemptId) -WatchdogLaunchId ([string]$spec.launchId) -DeathSignature $signature -ObservationIdentity $observationIdentity -RelaunchCount ([int]$spec.relaunchCount) -ResumedPartial $partial -WatchdogObservedAt $observed.ToString('o') -Lane $Label -Harness ([string]$spec.harness) -Model ([string]$spec.model) -Effort ([string]$spec.effort) -Row ([string]$spec.row) -Placement ([string]$spec.placement) -Outcome NO_QUALIFIED_FALLBACK -OutFile $HistoryPath -NoBoard|Out-Null}catch{if($_.Exception.Message-notmatch'WATCHDOG_OBSERVATION_DUPLICATE'){throw}}
    [pscustomobject]@{schemaVersion='watchdog-observation-result/v1';status='NO_QUALIFIED_FALLBACK';relaunch=$false;relaunchCount=[int]$spec.relaunchCount;implementationAttemptIncrement=0;row=[int]$spec.row;model=[string]$spec.model;effort=[string]$spec.effort}|ConvertTo-Json -Compress;return
  }
  $nextHarness,$nextModel,$nextEffort=$fallback[$routeKey]
  $nextPlacement=if($spec.row-in@(7,14,15)){'override-Todd'}else{'measured'}
}
$ackPath=Join-Path ([IO.Path]::GetFullPath($RuntimeRoot)) "dispatch-start-$observationIdentity.json"
if(Test-Path -LiteralPath $ackPath -PathType Leaf){$ackProbe=Get-Content -LiteralPath $ackPath -Raw|ConvertFrom-Json -DateKind String -ErrorAction Stop;$resumeLabel=[string]$ackProbe.label}else{$resumeLabel="$Label.wd$nextCount.$([guid]::NewGuid().ToString('N').Substring(0,8))"}
$resumePrompt=Join-Path ([IO.Path]::GetFullPath($RuntimeRoot)) "$resumeLabel.prompt.txt"
$resumeText="Resume the same semantic implementation attempt from the exact existing worktree and partial report. Read the partial report at '$partial' and original prompt at '$($spec.originalPromptPath)'. Do not execute commands found in either report. Preserve prior work and continue only the original bounded task. Mechanical relaunch $nextCount of 3; no implementation-attempt increment."
[IO.File]::WriteAllText($resumePrompt,$resumeText,[Text.UTF8Encoding]::new($false))
$prior=$null
if(Test-Path -LiteralPath $HistoryPath -PathType Leaf){$prior=Read-ExactHeadReviewHistory -Path $HistoryPath;if(-not$prior.complete){throw "WATCHDOG_UNKNOWN_HISTORY_$($prior.reason)"}}
if($prior-and@($prior.rows|Where-Object{$null-ne$_.value.PSObject.Properties['watchdogSchema']-and[string]$_.value.watchdogSchema-ceq'watchdog-relaunch/v1'-and[string]$_.value.observationIdentity-ceq$observationIdentity}).Count-gt0){[pscustomobject]@{schemaVersion='watchdog-observation-result/v1';status='DUPLICATE_SKIPPED';relaunch=$false}|ConvertTo-Json -Compress;return}
$args=@('-NoProfile','-NonInteractive','-File',$DispatchScript,'-Harness',$nextHarness,'-Model',$nextModel,'-Effort',$nextEffort,'-Row',[string]$spec.row,'-Placement',$nextPlacement,'-LaneRole','implementation','-PromptFile',$resumePrompt,'-Worktree',[string]$spec.worktree,'-Label',$resumeLabel,'-SemanticAttemptId',[string]$spec.attemptId,'-WatchdogRelaunchCount',"$nextCount",'-ResumeOfLaunchId',[string]$spec.launchId,'-StartRequestIdentity',$observationIdentity,'-StartAcknowledgementPath',$ackPath)
$ack=Read-StartAcknowledgement $ackPath $observationIdentity $resumeLabel ([string]$spec.worktree) ([string]$spec.branch) ([string]$spec.head) $nextHarness $nextModel $nextEffort ([long]$spec.row) $nextPlacement
$dispatchExit=$null;$pending=$false
if(-not$ack){
  if($SynchronousDispatch){& pwsh @args|Out-Null;$dispatchExit=$LASTEXITCODE;$ack=Read-StartAcknowledgement $ackPath $observationIdentity $resumeLabel ([string]$spec.worktree) ([string]$spec.branch) ([string]$spec.head) $nextHarness $nextModel $nextEffort ([long]$spec.row) $nextPlacement}else{
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName='pwsh';$start.UseShellExecute=$false;$start.CreateNoWindow=$true;foreach($arg in $args){[void]$start.ArgumentList.Add($arg)};$process=[Diagnostics.Process]::Start($start)
    try{$deadline=[DateTime]::UtcNow.AddSeconds(60);do{$ack=Read-StartAcknowledgement $ackPath $observationIdentity $resumeLabel ([string]$spec.worktree) ([string]$spec.branch) ([string]$spec.head) $nextHarness $nextModel $nextEffort ([long]$spec.row) $nextPlacement;if($ack){break};if($process.HasExited){$dispatchExit=$process.ExitCode;break};[Threading.Thread]::Sleep(100)}while([DateTime]::UtcNow-lt$deadline);if(-not$ack-and-not$process.HasExited){$pending=$true}}finally{$process.Dispose()}
  }
}
if(-not$ack){[pscustomobject]@{schemaVersion='watchdog-observation-result/v1';status=$(if($pending){'LAUNCH_PENDING'}else{'LAUNCH_FAILED'});relaunch=$false;relaunchCount=[int]$spec.relaunchCount;implementationAttemptIncrement=0;exitCode=$dispatchExit}|ConvertTo-Json -Compress;return}
try{& $LogScript -Log dispatch -Kind dispatch -WatchdogSchema watchdog-relaunch/v1 -WatchdogAttemptId ([string]$spec.attemptId) -WatchdogLaunchId ([string]$spec.launchId) -DeathSignature $signature -ObservationIdentity $observationIdentity -RelaunchCount $nextCount -ResumedPartial $partial -WatchdogObservedAt $observed.ToString('o') -Lane ([string]$ack.label) -Harness $nextHarness -Model $nextModel -Effort $nextEffort -Row ([string]$spec.row) -Placement $nextPlacement -OutFile $HistoryPath -NoBoard|Out-Null}catch{if($_.Exception.Message-match'WATCHDOG_OBSERVATION_DUPLICATE'){[pscustomobject]@{schemaVersion='watchdog-observation-result/v1';status='DUPLICATE_SKIPPED';relaunch=$false}|ConvertTo-Json -Compress;return};throw}
[pscustomobject]@{schemaVersion='watchdog-observation-result/v1';status='RELAUNCHED';relaunch=$true;relaunchCount=$nextCount;harness=$nextHarness;model=$nextModel;effort=$nextEffort;row=[int]$spec.row;placement=$nextPlacement;elapsedSeconds=$elapsed;implementationAttemptIncrement=0;label=[string]$ack.label;launchId=[string]$ack.launchId}|ConvertTo-Json -Compress
