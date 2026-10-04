[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$')][string]$Label,
  [string]$RuntimeRoot=$PSScriptRoot,
  [string]$HistoryPath=(Join-Path $PSScriptRoot 'dispatch-log.jsonl'),
  [string]$TranscriptPath,
  [string]$ObservedAt=([DateTime]::UtcNow.ToString('o')),
  [Parameter(DontShow)][string]$ObservationFixture,
  [Parameter(DontShow)][string]$IntegrationAuthorityFixturePath,
  [Parameter(DontShow)][string]$DispatchScript=(Join-Path $PSScriptRoot 'dispatch-lane.ps1'),
  [Parameter(DontShow)][string]$LogScript=(Join-Path $PSScriptRoot 'log-event.ps1'),
  [Parameter(DontShow)][switch]$SynchronousDispatch
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'routing-data.ps1') -Library
. (Join-Path $PSScriptRoot 'dispatch-ownership.ps1')
. (Join-Path $PSScriptRoot 'watchdog-host-hold.ps1') -Library
. (Join-Path $PSScriptRoot 'integration-dispatch-contract.ps1')
Import-Module (Join-Path $PSScriptRoot 'landed-integration-evidence.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'review-head-contract.psm1') -Force -DisableNameChecking
function Test-ExactKeys($Value,[string[]]$Expected){$actual=@($Value.PSObject.Properties.Name);return $actual.Count-eq$Expected.Count-and@($Expected|Where-Object{$_-cnotin$actual}).Count-eq0}
function Test-WatchdogRoutingProvenance($Value){
  $names=@('policyGeneration','registryAuthorityDigest','family','slot','usedLastKnownGood')
  $actual=@($Value.PSObject.Properties.Name);$present=@($names|Where-Object{$_-in$actual})
  if($present.Count-eq0){return $true};if($present.Count-ne$names.Count){return $false}
  return ($Value.policyGeneration-is[int] -or $Value.policyGeneration-is[long]) -and [long]$Value.policyGeneration -ge 1 -and
    $Value.registryAuthorityDigest-is[string] -and $Value.registryAuthorityDigest-cmatch'^[a-zA-Z0-9._:-]{1,128}$' -and
    $Value.family-is[string] -and $Value.family-cmatch'^[a-z0-9][a-z0-9._-]{0,63}$' -and
    $Value.slot-is[string] -and $Value.slot-cmatch'^(explicit|(codex|claude)\.(primary|fallback))$' -and
    $Value.usedLastKnownGood-is[bool]
}
function Get-WatchdogRoutingAuthority {
  try { return Get-RoutingData -ReadOnly } catch { throw "WATCHDOG_ROUTING_DATA_REFUSED: $($_.Exception.Message)" }
}
function Get-WatchdogCurrentModel([object]$Data,[string]$Family){
  $entry=$Data.registry.families.PSObject.Properties[$Family]
  if($null -eq $entry -or $entry.Value.current -isnot [string]){return $null}
  return [string]$entry.Value.current
}
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
# 8098: the account pool fails a turn with HTTP 503 `upstream rate limited,
# retry later: All credentials for model <x> are cooling down (last error: credential_quota)` (or the
# analogous 429 `model_cooldown` wording). The Codex harness writes it as `stream disconnected -
# retrying sampling request` WARN lines in <label>.err.log and as the final native turn.failed
# record in <label>.jsonl. Either tail carrying that envelope is PROVIDER_QUOTA.
function Test-PoolQuotaEnvelope([string]$Text){
  if([string]::IsNullOrEmpty($Text)){return $false}
  return $Text.Contains('credential_quota')-or$Text.Contains('model_cooldown')-or$Text-cmatch'All credentials for model .+ are cooling down'
}
# Only the transcript's final native record is judged: a turn.failed (or error) record contributes
# its message; any other final record (a recovered turn) or non-JSON final line contributes nothing.
function Get-TranscriptTerminalMessage([string]$TranscriptTail){
  $lines=@($TranscriptTail -split "`r?`n"|ForEach-Object{$_.Trim()}|Where-Object{$_})
  if($lines.Count-eq0){return ''}
  $record=$null;try{$record=$lines[-1]|ConvertFrom-Json -DateKind String -ErrorAction Stop}catch{return ''}
  if($null-eq$record-or$null-eq$record.PSObject.Properties['type']){return ''}
  if([string]$record.type-ceq'turn.failed'){return [string]$record.error.message}
  if([string]$record.type-ceq'error'){return [string]$record.message}
  return ''
}
function Get-ProviderDeathSignature([string]$ErrorTail,[string]$TranscriptTail=''){
  $lines=@($ErrorTail -split "`r?`n"|ForEach-Object{$_.Trim()}|Where-Object{$_})
  if(@($lines|Where-Object{$_-cin@('provider quota exceeded','provider quota exhausted')}).Count-gt0){return 'PROVIDER_QUOTA'}
  if(@($lines|Where-Object{$_-cin@('session limit reached','session limit exceeded')}).Count-gt0){return 'SESSION_LIMIT'}
  if(@($lines|Where-Object{$_-ceq'stream disconnected'}).Count-gt0){return 'STREAM_DISCONNECTED'}
  if(@($lines|Where-Object{$_-ceq'code-mode host closed'}).Count-gt0){return 'CODE_MODE_HOST_CLOSED'}
  if((Test-PoolQuotaEnvelope $ErrorTail)-or(Test-PoolQuotaEnvelope (Get-TranscriptTerminalMessage $TranscriptTail))){return 'PROVIDER_QUOTA'}
  return 'OWNER_DEAD'
}
function Test-AckInstant($Value){$parsed=[datetimeoffset]::MinValue;return $Value-is[string]-and[datetimeoffset]::TryParse([string]$Value,[ref]$parsed)}
function Read-StartAcknowledgement([string]$Path,[string]$RequestIdentity,[string]$ExpectedLabel,[string]$ExpectedWorktree,[string]$ExpectedBranch,[string]$ExpectedHead,[string]$Harness,[string]$Model,[string]$Effort,[long]$Row,[string]$Placement,[object]$ExpectedPolicyGeneration=$null,[string]$ExpectedRegistryAuthorityDigest=$null,[string]$ExpectedFamily=$null,[string]$ExpectedSlot=$null,[Nullable[bool]]$ExpectedUsedLastKnownGood=$null){
  if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
  $ack=Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json -DateKind String -ErrorAction Stop
  $keys=@('schemaVersion','requestIdentity','label','launchId','ownershipRecordPath','worktree','branch','head','harness','model','effort','row','placement','state','childPid','childStartIdentity')
  $provenance=@('policyGeneration','registryAuthorityDigest','family','slot','usedLastKnownGood')
  if(@($provenance|Where-Object{$_ -in @($ack.PSObject.Properties.Name)}).Count -gt 0){$keys += $provenance}
  if($ack.schemaVersion-ceq'dispatch-start-ack/v2'){
    $ack=Read-RebaseJson $Path
    $keys+='interruptedIntegration'
    $bound=ConvertFrom-DispatchClosedJson $ack.interruptedIntegration
    if(-not(Test-DispatchInterruptedBindingShape $bound)-or(Get-RebaseRecordIdentity $bound)-cne$RequestIdentity-or$bound.state.stoppedHead-cne$ExpectedHead-or$bound.obligation.branch-cne$ExpectedBranch){throw 'WATCHDOG_START_ACK_UNKNOWN'}
  }
  if(-not(Test-ExactKeys $ack $keys)-or-not(Test-WatchdogRoutingProvenance $ack)-or$ack.schemaVersion-cnotin@('dispatch-start-ack/v1','dispatch-start-ack/v2')-or$ack.requestIdentity-cne$RequestIdentity-or$ack.label-cne$ExpectedLabel-or
    -not[string]::Equals([IO.Path]::GetFullPath([string]$ack.worktree).TrimEnd('\','/'),[IO.Path]::GetFullPath($ExpectedWorktree).TrimEnd('\','/'),[StringComparison]::OrdinalIgnoreCase)-or
    [string]$ack.branch-cne$ExpectedBranch-or[string]$ack.head-cne$ExpectedHead-or$ack.harness-cne$Harness-or$ack.model-cne$Model-or$ack.effort-cne$Effort-or
    $ack.row-isnot[long]-or$ack.row-ne$Row-or$ack.placement-cne$Placement-or$ack.state-cne'started'-or$ack.launchId-cnotmatch'^[a-f0-9-]{36}$'-or
    $ack.childPid-isnot[long]-or$ack.childPid-lt1-or-not(Test-AckInstant $ack.childStartIdentity)){throw 'WATCHDOG_START_ACK_UNKNOWN'}
  if($null -ne $ExpectedPolicyGeneration){
    $ackHasRouting=@('policyGeneration','registryAuthorityDigest','family','slot','usedLastKnownGood'|Where-Object{$_ -in @($ack.PSObject.Properties.Name)}).Count -gt 0
    if($ackHasRouting -and (-not(Test-WatchdogRoutingProvenance $ack)-or[long]$ack.policyGeneration -ne [long]$ExpectedPolicyGeneration-or[string]$ack.registryAuthorityDigest-cne$ExpectedRegistryAuthorityDigest-or
      [string]$ack.family-cne$ExpectedFamily-or[string]$ack.slot-cne$ExpectedSlot-or[bool]$ack.usedLastKnownGood -ne [bool]$ExpectedUsedLastKnownGood)){throw 'WATCHDOG_START_ACK_UNKNOWN'}
  }
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
  $candidates=[Collections.Generic.List[object]]::new()
  foreach($row in @($history.rows)){
    $value=$row.value
    if($null-eq$value.PSObject.Properties['dispatchRoutingSchema']-or[string]$value.dispatchRoutingSchema-cnotin@('watchdog-dispatch-routing/v1','watchdog-dispatch-routing/v2')){continue}
    $expectedKeys=@(Get-DispatchRoutingLedgerKeys $value.dispatchRoutingSchema)
    $actual=@($value.PSObject.Properties.Name);$route=0
    if(-not(Test-DispatchRoutingLedgerEvidence $value)-or$actual.Count-ne$expectedKeys.Count-or@($expectedKeys|Where-Object{$_-cnotin$actual}).Count-ne0-or-not(Test-Instant $value.ts)-or
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
$provenance=@('policyGeneration','registryAuthorityDigest','family','slot','usedLastKnownGood')
$specProvenancePresent=@($provenance|Where-Object{$_ -in @($spec.PSObject.Properties.Name)}).Count -gt 0
if($specProvenancePresent){$keys += $provenance}
$legacy=Test-ExactKeys $spec $legacyKeys
# 8186: the lane role is closed to dispatch-lane's three roles and read before any
# other admission. Only implementation lanes reach routing provenance, recovery
# age, history, fallback, prompt or dispatch below; planning and review are
# observed on dispatch-lane's own envelope and never relaunched or killed here.
$laneRole=if($null-ne$spec.PSObject.Properties['laneRole']-and$spec.laneRole-is[string]){[string]$spec.laneRole}else{''}
if($laneRole-cnotin@('implementation','planning','review')){throw 'WATCHDOG_UNKNOWN_SPEC_INVALID'}
$implementation=$laneRole-ceq'implementation'
$integrationTarget=$null
if($spec.schemaVersion-ceq'watchdog-lane/v3'){
  if(-not$implementation-or-not(Test-ExactKeys $spec ($keys+@('integrationRequest')))){throw 'WATCHDOG_UNKNOWN_INTEGRATION_SPEC'}
  $integrationTarget=$spec.integrationRequest
  Assert-IntegrationRequest $integrationTarget
  Assert-IntegrationAuthor $spec.harness $spec.model $spec.effort $spec.row $spec.placement
  if($integrationTarget.label-cne$Label-or$integrationTarget.head-cne$spec.head-or$integrationTarget.branch-cne$spec.branch-or-not(Test-DispatchSamePath $integrationTarget.worktree $spec.worktree)){throw 'WATCHDOG_UNKNOWN_INTEGRATION_REQUEST'}
  # Normalize only this in-memory reader view. Retained native bytes stay v3.
  $spec.PSObject.Properties.Remove('integrationRequest');$spec.schemaVersion='watchdog-lane/v2'
}
$interrupted = $spec.schemaVersion -ceq 'watchdog-lane/v4'
if ($interrupted) {
  if(-not$implementation){throw 'WATCHDOG_UNKNOWN_RESUME_BINDING'} # v4 interrupted integration is implementation-only
  $spec=Read-RebaseJson $specPath
  $keys += 'interruptedIntegration'
  $retainedBinding = ConvertFrom-DispatchClosedJson $spec.interruptedIntegration
  if ($ObservationFixture -or -not (Test-DispatchInterruptedBindingShape $retainedBinding) -or $retainedBinding.obligation.branch -cne $spec.branch -or
      $retainedBinding.state.stoppedHead -cne $spec.head -or -not (Test-DispatchSameCanonicalPath $retainedBinding.obligation.worktree $spec.worktree)) { throw 'WATCHDOG_UNKNOWN_RESUME_BINDING' }
}
if($legacy-and$spec.schemaVersion-ceq'watchdog-lane/v1'){
  if($implementation){
    $routing=Resolve-LegacyRoutingProvenance $spec
    if(-not$routing.accepted){[pscustomobject]@{schemaVersion='watchdog-observation-result/v1';status='ROUTING_PROVENANCE_REFUSED';relaunch=$false;reason=[string]$routing.reason;candidateCount=$(if($null-ne$routing.PSObject.Properties['candidateCount']){[int]$routing.candidateCount}else{0})}|ConvertTo-Json -Compress;return}
    $spec|Add-Member -NotePropertyName row -NotePropertyValue ([long]$routing.row)
    $spec|Add-Member -NotePropertyName placement -NotePropertyValue ([string]$routing.placement)
  }else{
    # A retained v1 planning/review lane never had a routing row: it carries
    # dispatch-lane's least-authority envelope (row 0, empty placement) in memory only.
    $spec|Add-Member -NotePropertyName row -NotePropertyValue ([long]0)
    $spec|Add-Member -NotePropertyName placement -NotePropertyValue ''
  }
  $spec.schemaVersion='watchdog-lane/v2'
}
$routingAuthority=Get-WatchdogRoutingAuthority
$watchdogCompatibilityRoutes=@(
  '2|sol/medium','2|luna/medium',
  '4|sol/high','4|sol/medium','4|opus/high',
  '5|sol/high','5|sol/xhigh','5|opus/high',
  '6|sol/high','6|opus/high',
  '7|sol/high','7|opus/high',
  '10|sol/high','10|opus/high',
  '3|sonnet/medium','3|sonnet/high','13|sonnet/high',
  '4|astra/high','5|astra/high','6|astra/high',
  '7|fable/high','7|astra/high',
  '10|astra/high','10|sonnet/high','13|sonnet/medium',
  '14|fable/medium','14|fable/high','14|astra/high',
  '15|fable/high','15|astra/high'
)
$benchmarkAuthorRoutes=@('3|opus/low','3|opus/medium','3|opus/high','3|sol/medium','4|opus/medium','5|opus/medium','10|opus/medium','13|sol/medium','13|opus/low','13|opus/medium','3|sonnet/medium','13|sonnet/medium')
$supported=@{}
foreach($rowProperty in $routingAuthority.policy.rows.PSObject.Properties){foreach($slotProperty in $rowProperty.Value.slots.PSObject.Properties){$config=$slotProperty.Value;$supported["$($rowProperty.Name)|$($config.family)/$($config.effort)"]=$true}}
foreach($benchmarkRoute in $benchmarkAuthorRoutes){$supported[$benchmarkRoute]=$true}
foreach($compatibilityRoute in $watchdogCompatibilityRoutes){$supported[$compatibilityRoute]=$true}
$routeIdentity=Get-RoutingModelIdentity $routingAuthority.registry ([string]$spec.model)
$routeKey=if($routeIdentity -and $routeIdentity.current){"$($spec.row)|$($routeIdentity.family)/$($spec.effort)"}else{"$($spec.row)|$($spec.model)/$($spec.effort)"}
$historicalRoutes=@{}
foreach($supportedRoute in $supported.Keys){
  $routeParts=$supportedRoute.Split([char[]]'|/')
  $family=$routingAuthority.registry.families.PSObject.Properties[$routeParts[1]]
  if($null -eq $family){continue}
  foreach($historical in @($family.Value.historical)){
    foreach($historicalEffort in @('low','medium','high','xhigh','max')){
      $historicalRoutes["$($routeParts[0])|$historical/$historicalEffort"]=$true
    }
  }
}
$retiredSelectors=@(Get-RoutingModelSet -Registry $routingAuthority.registry -Scope historical)
# Reader-only predecessor retained by v2.86 evidence; it is not a selectable
# route and does not participate in the frozen current compatibility surface.
$retiredSelectors += 'gpt-5.6-terra'
$knownCurrent=@(Get-RoutingModelSet -Registry $routingAuthority.registry -Scope current)
# Implementation predecessors retain family-derived historical routes, including
# frozen compatibility routes whose family slot left the live policy.
$historicalPredecessor=$spec.state-cin@('running','exited')-and$(if($implementation){$historicalRoutes.ContainsKey($routeKey)-or$spec.model-ceq'gpt-5.6-terra'}else{$spec.model-cin$retiredSelectors})
if($spec.model-cin$retiredSelectors-and-not$historicalPredecessor){ # historical selectors cannot start anew
  throw "WATCHDOG_RETIRED_MODEL_INVALID: $($spec.model) requires a fresh successor dispatch"
}
if($implementation -and $spec.state-ceq'launching' -and $null -eq $routeIdentity){
  throw "WATCHDOG_RETIRED_MODEL_INVALID: $($spec.model) is not a current registry identity"
}
# These standing author placements come from Todd's row-7/14/15 ruling,
# never from task prose or the ordinary row-7 Sol compatibility route.
# Historical predecessor fallback targets remain readable, never selectable.
$astraAuthor=$routeKey-cin@('7|astra/high','14|astra/high')
$toddAuthor=$astraAuthor-or$routeKey-cin@('7|fable/high','14|fable/medium','14|fable/high','15|fable/high','15|astra/high','4|opus/high','5|opus/high','6|opus/high','7|opus/high','10|opus/high')
$toddAuthor=$toddAuthor-or$routeKey-cin$benchmarkAuthorRoutes
$sonnetQuota=$implementation-and$routeKey-cin@('3|sonnet/high','13|sonnet/high')
$toddAuthor=$toddAuthor-or($routeIdentity-and$routeIdentity.family-ceq'sonnet'-and-not$sonnetQuota)
# The route envelope is role-owned. Implementation keeps the closed route table and
# author placement predicates. Planning/review carry dispatch-lane's own domain
# (row 0-15, empty or case-insensitive placement); no route-table or author predicate applies.
$routeEnvelopeInvalid=if($implementation -and $historicalPredecessor){$false}elseif($implementation){
  (-not$supported.ContainsKey($routeKey))-or
  ($spec.placement-cnotmatch'^(measured|provisional|override-[a-z0-9._-]+)$'-and-not($toddAuthor-and$spec.placement-ceq'override-Todd'))-or
  ($astraAuthor-and$spec.placement-cne'override-Todd')
}else{
  $spec.row-lt0-or$spec.row-gt15-or$spec.placement-isnot[string]-or$spec.placement-notmatch'^$|^(measured|provisional|override-[a-z0-9._-]+)$'
}
if(-not(Test-ExactKeys $spec $keys)-or-not(Test-WatchdogRoutingProvenance $spec)-or$spec.schemaVersion-cnotin@('watchdog-lane/v2','watchdog-lane/v4')-or$spec.label-cne$Label-or
  $spec.attemptId-cnotmatch'^[A-Za-z0-9][A-Za-z0-9._:/-]{0,255}$'-or$spec.relaunchCount-isnot[long]-or$spec.relaunchCount-lt0-or$spec.relaunchCount-gt3-or
  $spec.launchId-cnotmatch'^[a-f0-9-]{36}$'-or$spec.harness-cnotin@('codex','claude')-or($spec.model-cnotin$knownCurrent-and-not$historicalPredecessor)-or
  $spec.effort-cnotin@('minimal','low','medium','high','xhigh','max')-or$spec.row-isnot[long]-or$routeEnvelopeInvalid-or
  ($routeIdentity-and$routeIdentity.family-ceq'sonnet'-and-not$historicalPredecessor-and$spec.placement-cne$(if($sonnetQuota){'provisional'}else{'override-Todd'}))-or
  ($spec.harness-ceq'codex'-and$spec.model-notlike'gpt-*')-or($spec.harness-ceq'claude'-and$spec.model-notlike'claude-*')-or
  ($null-ne$spec.resumeOfLaunchId-and[string]$spec.resumeOfLaunchId-cnotmatch'^[a-f0-9-]{36}$')-or
  $spec.state-cnotin@('launching','running','exited')-or$spec.launcherPid-isnot[long]-or$spec.launcherPid-lt1-or-not(Test-Instant $spec.launcherStartIdentity)-or-not(Test-Instant $spec.updatedAt)-or
  ($spec.state-ceq'launching'-and($null-ne$spec.childPid-or$null-ne$spec.childStartIdentity-or$null-ne$spec.exitCode))-or
  ($spec.state-in@('running','exited')-and($spec.childPid-isnot[long]-or$spec.childPid-lt1-or-not(Test-Instant $spec.childStartIdentity)))-or
  ($spec.state-ceq'running'-and$null-ne$spec.exitCode)-or($spec.state-ceq'exited'-and$spec.exitCode-isnot[int]-and$spec.exitCode-isnot[long])){throw 'WATCHDOG_UNKNOWN_SPEC_INVALID'}
$runtimeFull=[IO.Path]::GetFullPath($RuntimeRoot).TrimEnd('\','/')
$expectedPartial=Join-Path $runtimeFull "$Label.jsonl";$expectedError=Join-Path $runtimeFull "$Label.err.log"
$expectedOwner=Join-Path $runtimeFull "dispatch-launch-$($spec.launchId).json"
if(-not[string]::Equals([IO.Path]::GetFullPath([string]$spec.partialReportPath),$expectedPartial,[StringComparison]::OrdinalIgnoreCase)){throw 'WATCHDOG_UNKNOWN_SPEC_PARTIAL_PATH'}
if(-not[string]::Equals([IO.Path]::GetFullPath([string]$spec.errorPath),$expectedError,[StringComparison]::OrdinalIgnoreCase)){throw 'WATCHDOG_UNKNOWN_SPEC_ERROR_PATH'}
if(-not[string]::Equals([IO.Path]::GetFullPath([string]$spec.ownershipRecordPath),$expectedOwner,[StringComparison]::OrdinalIgnoreCase)){throw 'WATCHDOG_UNKNOWN_SPEC_OWNER_PATH'}
# dispatch-lane admits a detached (immutable-head) worktree only for review, which records an empty branch.
$detachedReview=$laneRole-ceq'review'-and$spec.branch-is[string]-and$spec.branch-ceq''
if((-not$detachedReview-and$spec.branch-cnotmatch'^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}$')-or$spec.head-cnotmatch'^[a-f0-9]{40}$'){throw 'WATCHDOG_UNKNOWN_SPEC_GIT_IDENTITY'}
if(-not(Test-Path -LiteralPath ([string]$spec.originalPromptPath) -PathType Leaf)){throw 'WATCHDOG_UNKNOWN_SPEC_ORIGINAL_PROMPT'}
if(-not(Test-Path -LiteralPath ([string]$spec.worktree) -PathType Container)){throw 'WATCHDOG_UNKNOWN_SPEC_WORKTREE'}
# Serialize the host's persisted-before-stop hold with the complete recovery
# mutation path. A held or unreadable launch has no prompt/ack/ledger effects.
$holdMutex=Enter-WatchdogHoldLock $runtimeFull ([string]$spec.launchId)
try {
$hold=Read-WatchdogHold $runtimeFull $spec
if($hold.state-cnotin@('absent','released')){ # HOST_HOLD_GUARD
  [pscustomobject]@{schemaVersion='watchdog-observation-result/v1';status='OBSERVATION_ONLY';relaunch=$false;laneRole=$laneRole;diagnosis='HOST_HOLD';holdState=$hold.state}|ConvertTo-Json -Compress;return
}
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
if(-not$interrupted-and$spec.state-ceq'exited'-and$spec.exitCode-eq0){
  [pscustomobject]@{schemaVersion='watchdog-observation-result/v1';status='TERMINAL_SUCCESS';relaunch=$false}|ConvertTo-Json -Compress;return
}
if($ownerState-cne'dead'-or$descendantState-cne'none'-or-not$stopped){
  [pscustomobject]@{schemaVersion='watchdog-observation-result/v1';status='OWNERSHIP_UNKNOWN';relaunch=$false;ownerState=$ownerState;descendantState=$descendantState}|ConvertTo-Json -Compress;return
}
if(-not$implementation){ # OBSERVATION_GUARD_ROLE
  # A valid, stopped, proven-dead, non-successful planning/review lane is host
  # diagnosis: not healthy, terminal or vacancy authority, and never a relaunch.
  # It returns before any recovery age, history, fallback, count, prompt,
  # dispatch or ledger effect, so repeated observations change no bytes.
  [pscustomobject]@{schemaVersion='watchdog-observation-result/v1';status='OBSERVATION_ONLY';relaunch=$false;laneRole=$laneRole;diagnosis='HOST_DIAGNOSIS_REQUIRED';ownerState=$ownerState;state=[string]$spec.state;exitCode=$spec.exitCode}|ConvertTo-Json -Compress;return
}
if($integrationTarget -or $interrupted){
  $authorityPr=if($interrupted){$retainedBinding.obligation.pr}else{$integrationTarget.pr}
  $authorityBranch=if($interrupted){$retainedBinding.obligation.branch}else{$integrationTarget.branch}
  $authorityHistory=Read-ExactHeadReviewHistory -Path $HistoryPath
  if(-not$authorityHistory.complete){throw "WATCHDOG_UNKNOWN_HISTORY_$($authorityHistory.reason)"}
  $authority=Reduce-LandedIntegrationAuthority $authorityHistory $authorityPr $authorityBranch $spec.head
  if($authority.globalUnknown-or$authority.reason-ceq'CENSUS_UNKNOWN_AUTHORITY_ROW'){throw 'WATCHDOG_UNKNOWN_AUTHORITY_ROW'}
  if($authority.state-ceq'STOP'){ # AUTHORITY_GUARD_WATCHDOG
    [pscustomobject]@{schemaVersion='watchdog-observation-result/v1';status='TERMINAL_AUTHORITY_STOP';relaunch=$false;pr=$authorityPr;branch=$authorityBranch;stopRows=@($authority.authorityRows)}|ConvertTo-Json -Compress;return
  }
}
if($historicalPredecessor){ # historical models never relaunch
  # Never relabel a pinned predecessor's continuation as successor evidence.
  # The host must arrange a fresh, attributed successor dispatch after vacancy.
  [pscustomobject]@{schemaVersion='watchdog-observation-result/v1';status='RETIRED_MODEL_REQUIRES_REDISPATCH';relaunch=$false;model=[string]$spec.model;implementationAttemptIncrement=0}|ConvertTo-Json -Compress;return
}
$freshResume = $null
if ($interrupted) {
  try {
    $completion = Read-RebaseCompletion $retainedBinding.obligation $RuntimeRoot -Replay
    if ($completion) { [pscustomobject]@{schemaVersion='watchdog-observation-result/v1';status='TERMINAL_SUCCESS';relaunch=$false}|ConvertTo-Json -Compress;return }
    $freshResume = New-InterruptedIntegrationResume $retainedBinding.obligation $RuntimeRoot $Label $spec.launchId
  } catch { [pscustomobject]@{schemaVersion='watchdog-observation-result/v1';status='RESUME_REFUSED';relaunch=$false;reason=$_.Exception.Message}|ConvertTo-Json -Compress;return }
}
$signature=Get-ProviderDeathSignature (Get-Tail ([string]$spec.errorPath)) (Get-Tail $partial)
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
    '2|luna/medium'=@('codex','sol','medium')
    '4|astra/high'=@('codex','sol','high');'4|sol/medium'=@('codex','sol','high')
    '5|astra/high'=@('codex','sol','high');'5|sol/xhigh'=@('codex','sol','high')
    '6|opus/high'=@('codex','sol','high');'6|astra/high'=@('codex','sol','high')
    # Row 7 has no closed scope discriminator: never infer noncore authority
    # for a lower-tier fallback. Astra also preserves the Fable reserve.
    '7|fable/high'=@('codex','astra','high')
    '10|astra/high'=@('codex','sol','high');'10|sonnet/high'=@('codex','sol','high')
    '14|fable/medium'=@('codex','astra','high');'14|fable/high'=@('codex','astra','high')
    '15|fable/high'=@('codex','astra','high')
    # Todd-ruled vendor fallbacks (4388/5743533387, #8063): a quota-blocked or
    # refused Astra author falls to the Fable family and a Sol author falls to
    # the Opus family at the same effort. The fourth element is
    # the ruled placement: every entry below relaunches as override-Todd on
    # any row because Todd placed the fallback author, not the routing row.
    '7|astra/high'=@('claude','fable','high','override-Todd');'14|astra/high'=@('claude','fable','high','override-Todd');'15|astra/high'=@('claude','fable','high','override-Todd')
    '4|sol/high'=@('claude','opus','high','override-Todd');'5|sol/high'=@('claude','opus','high','override-Todd');'6|sol/high'=@('claude','opus','high','override-Todd')
    '7|sol/high'=@('claude','opus','high','override-Todd');'10|sol/high'=@('claude','opus','high','override-Todd')
    '3|sol/medium'=@('claude','opus','medium','override-Todd');'13|sol/medium'=@('claude','opus','medium','override-Todd')
    '3|opus/medium'=@('codex','sol','medium','override-Todd');'13|opus/medium'=@('codex','sol','medium','override-Todd')
  }
  $qualified=$fallback.ContainsKey($routeKey)
  if($qualified){
    $nextHarness,$nextFamily,$nextEffort,$ruledPlacement=$fallback[$routeKey]
    $nextModel=Get-WatchdogCurrentModel $routingAuthority $nextFamily
    if($null -eq $nextModel){$qualified=$false}
    # Successor targets have no inherited measured placement. A Todd-ruled
    # four-element entry retains its policy placement, not capability evidence.
    $nextPlacement=if($null-ne$ruledPlacement){[string]$ruledPlacement}elseif($spec.row-in@(7,14,15)){'override-Todd'}elseif($nextFamily-in@('sol','luna','opus')){'provisional'}else{'measured'}
    # Integration watchdog retries retain their selected author. Cross-vendor
    # fallback is admitted only by the pool-gated landed producer, not here.
    if($integrationTarget){
      if($nextHarness-cne$spec.harness-or$nextModel-cne$spec.model){$qualified=$false}
      else{try{Assert-IntegrationAuthor $nextHarness $nextModel $nextEffort $spec.row $nextPlacement}catch{if($_.Exception.Message-cnotmatch'^INTEGRATION_AUTHOR_UNAVAILABLE'){throw};$qualified=$false}}
    }
  }
  if(-not$qualified){
    try{& $LogScript -Log dispatch -Kind lane-blocked -WatchdogSchema watchdog-relaunch/v1 -WatchdogAttemptId ([string]$spec.attemptId) -WatchdogLaunchId ([string]$spec.launchId) -DeathSignature $signature -ObservationIdentity $observationIdentity -RelaunchCount ([int]$spec.relaunchCount) -ResumedPartial $partial -WatchdogObservedAt $observed.ToString('o') -Lane $Label -Harness ([string]$spec.harness) -Model ([string]$spec.model) -Effort ([string]$spec.effort) -Row ([string]$spec.row) -Placement ([string]$spec.placement) -Outcome NO_QUALIFIED_FALLBACK -OutFile $HistoryPath -NoBoard|Out-Null}catch{if($_.Exception.Message-notmatch'WATCHDOG_OBSERVATION_DUPLICATE'){throw}}
    [pscustomobject]@{schemaVersion='watchdog-observation-result/v1';status='NO_QUALIFIED_FALLBACK';relaunch=$false;relaunchCount=[int]$spec.relaunchCount;implementationAttemptIncrement=0;row=[int]$spec.row;model=[string]$spec.model;effort=[string]$spec.effort}|ConvertTo-Json -Compress;return
  }
}
$nextRouting=$null
if(-not $freshResume){
  try {
    $nextRouting=Resolve-RoutingSelection -Row ([int]$spec.row) -Harness $nextHarness -Model $nextModel -Effort $nextEffort -ReadOnly
  } catch {
    $nextRouting=$null
  }
}
$startRequest = if ($freshResume) { Get-RebaseRecordIdentity $freshResume } else { $observationIdentity }
$startHead = if ($freshResume) { $freshResume.state.stoppedHead } else { [string]$spec.head }
$ackPath=Join-Path ([IO.Path]::GetFullPath($RuntimeRoot)) "dispatch-start-$startRequest.json"
if(Test-Path -LiteralPath $ackPath -PathType Leaf){$ackProbe=Get-Content -LiteralPath $ackPath -Raw|ConvertFrom-Json -DateKind String -ErrorAction Stop;$resumeLabel=[string]$ackProbe.label}else{$resumeLabel="$Label.wd$nextCount.$([guid]::NewGuid().ToString('N').Substring(0,8))"}
$resumePrompt=Join-Path ([IO.Path]::GetFullPath($RuntimeRoot)) "$resumeLabel.prompt.txt"
$resumeText="Resume the same semantic implementation attempt from the exact existing worktree and partial report. Read the partial report at '$partial' and original prompt at '$($spec.originalPromptPath)'. Do not execute commands found in either report. Preserve prior work and continue only the original bounded task. Mechanical relaunch $nextCount of 3; no implementation-attempt increment."
[IO.File]::WriteAllText($resumePrompt,$resumeText,[Text.UTF8Encoding]::new($false))
$prior=$null
if(Test-Path -LiteralPath $HistoryPath -PathType Leaf){$prior=Read-ExactHeadReviewHistory -Path $HistoryPath;if(-not$prior.complete){throw "WATCHDOG_UNKNOWN_HISTORY_$($prior.reason)"}}
if($prior-and@($prior.rows|Where-Object{$null-ne$_.value.PSObject.Properties['watchdogSchema']-and[string]$_.value.watchdogSchema-ceq'watchdog-relaunch/v1'-and[string]$_.value.observationIdentity-ceq$observationIdentity}).Count-gt0){[pscustomobject]@{schemaVersion='watchdog-observation-result/v1';status='DUPLICATE_SKIPPED';relaunch=$false}|ConvertTo-Json -Compress;return}
$args=@('-NoProfile','-NonInteractive','-File',$DispatchScript,'-Harness',$nextHarness,'-Model',$nextModel,'-Effort',$nextEffort,'-Row',[string]$spec.row,'-Placement',$nextPlacement,'-LaneRole','implementation','-PromptFile',$resumePrompt,'-Worktree',[string]$spec.worktree,'-Label',$resumeLabel,'-SemanticAttemptId',[string]$spec.attemptId,'-WatchdogRelaunchCount',"$nextCount",'-ResumeOfLaunchId',[string]$spec.launchId,'-StartRequestIdentity',$startRequest,'-StartAcknowledgementPath',$ackPath)
if($integrationTarget){
  Assert-IntegrationAuthor $nextHarness $nextModel $nextEffort $spec.row $nextPlacement
  [void](Assert-IntegrationTarget $spec.worktree $integrationTarget.branch $integrationTarget.head $integrationTarget.newBase $integrationTarget.repository $integrationTarget.pr $IntegrationAuthorityFixturePath)
  $integrationTarget.label=$resumeLabel;$integrationTarget.requestIdentity=$observationIdentity
  $targetPath=Join-Path $RuntimeRoot "integration-request-$resumeLabel.json"
  [void](Write-RebaseRecord $targetPath $integrationTarget)
  $helperArguments=Get-IntegrationHelperArguments $integrationTarget.pr $integrationTarget.head $integrationTarget.newBase $integrationTarget.sourceIdentity $integrationTarget.sourceHead $resumeLabel $spec.worktree $RuntimeRoot $HistoryPath
  $helperCommand='pwsh '+(@($helperArguments|ForEach-Object{"'"+$_.Replace("'","''")+"'"})-join' ')
  [IO.File]::WriteAllText($resumePrompt,"$resumeText`nAuthor: $nextHarness/$nextModel/$nextEffort/row$($spec.row)/$nextPlacement. Complete noninteractive helper invocation for this dispatch label:`n$helperCommand",[Text.UTF8Encoding]::new($false))
  $args+=@('-IntegrationTargetPath',$targetPath)
  if($IntegrationAuthorityFixturePath){$args+=@('-IntegrationAuthorityFixturePath',$IntegrationAuthorityFixturePath)}
}
if ($freshResume) {
  $resumePath = Join-Path $runtimeFull "dispatch-resume-$startRequest.json"
  if (-not (Test-Path -LiteralPath $resumePath)) { Write-RebaseRecord $resumePath $freshResume }
  elseif ((Get-RebaseRecordIdentity (Read-RebaseJson $resumePath)) -cne $startRequest) { throw 'WATCHDOG_UNKNOWN_RESUME_BINDING' }
  $args += @('-InterruptedIntegrationResumePath',$resumePath)
}
# An interrupted resume is a continuation of the exact prior dispatch. Its
# dispatch-lane caller may have used the explicit Model/Effort form, whose
# provenance slot is intentionally `explicit`; do not replace that authority
# with a fresh policy-slot guess while validating the start acknowledgement.
$expectedRouting=if($freshResume -and (Test-WatchdogRoutingProvenance $spec)){$spec}elseif(-not $freshResume){$nextRouting}else{$null}
$ack=Read-StartAcknowledgement $ackPath $startRequest $resumeLabel ([string]$spec.worktree) ([string]$spec.branch) $startHead $nextHarness $nextModel $nextEffort ([long]$spec.row) $nextPlacement $(if($expectedRouting){$expectedRouting.policyGeneration}else{$null}) $(if($expectedRouting){$expectedRouting.registryAuthorityDigest}else{$null}) $(if($expectedRouting){$expectedRouting.family}else{$null}) $(if($expectedRouting){$expectedRouting.slot}else{$null}) $(if($expectedRouting){[bool]$expectedRouting.usedLastKnownGood}else{$null})
$dispatchExit=$null;$pending=$false
$hold=Read-WatchdogHold $runtimeFull $spec
if($hold.state-cnotin@('absent','released')){ # HOST_HOLD_PREDISPATCH_GUARD
  [pscustomobject]@{schemaVersion='watchdog-observation-result/v1';status='OBSERVATION_ONLY';relaunch=$false;laneRole=$laneRole;diagnosis='HOST_HOLD';holdState=$hold.state}|ConvertTo-Json -Compress;return
}
if(-not$ack){
  if($SynchronousDispatch){& pwsh @args|Out-Null;$dispatchExit=$LASTEXITCODE;$ack=Read-StartAcknowledgement $ackPath $startRequest $resumeLabel ([string]$spec.worktree) ([string]$spec.branch) $startHead $nextHarness $nextModel $nextEffort ([long]$spec.row) $nextPlacement $(if($expectedRouting){$expectedRouting.policyGeneration}else{$null}) $(if($expectedRouting){$expectedRouting.registryAuthorityDigest}else{$null}) $(if($expectedRouting){$expectedRouting.family}else{$null}) $(if($expectedRouting){$expectedRouting.slot}else{$null}) $(if($expectedRouting){[bool]$expectedRouting.usedLastKnownGood}else{$null})}else{
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName='pwsh';$start.UseShellExecute=$false;$start.CreateNoWindow=$true;foreach($arg in $args){[void]$start.ArgumentList.Add($arg)};$process=[Diagnostics.Process]::Start($start)
    try{$deadline=[DateTime]::UtcNow.AddSeconds(60);do{$ack=Read-StartAcknowledgement $ackPath $startRequest $resumeLabel ([string]$spec.worktree) ([string]$spec.branch) $startHead $nextHarness $nextModel $nextEffort ([long]$spec.row) $nextPlacement $(if($expectedRouting){$expectedRouting.policyGeneration}else{$null}) $(if($expectedRouting){$expectedRouting.registryAuthorityDigest}else{$null}) $(if($expectedRouting){$expectedRouting.family}else{$null}) $(if($expectedRouting){$expectedRouting.slot}else{$null}) $(if($expectedRouting){[bool]$expectedRouting.usedLastKnownGood}else{$null});if($ack){break};if($process.HasExited){$dispatchExit=$process.ExitCode;break};[Threading.Thread]::Sleep(100)}while([DateTime]::UtcNow-lt$deadline);if(-not$ack-and-not$process.HasExited){$pending=$true}}finally{$process.Dispose()}
  }
}
if(-not$ack){[pscustomobject]@{schemaVersion='watchdog-observation-result/v1';status=$(if($pending){'LAUNCH_PENDING'}else{'LAUNCH_FAILED'});relaunch=$false;relaunchCount=[int]$spec.relaunchCount;implementationAttemptIncrement=0;exitCode=$dispatchExit}|ConvertTo-Json -Compress;return}
$logParams=@{Log='dispatch';Kind='dispatch';WatchdogSchema='watchdog-relaunch/v1';WatchdogAttemptId=[string]$spec.attemptId;WatchdogLaunchId=[string]$spec.launchId;DeathSignature=$signature;ObservationIdentity=$observationIdentity;RelaunchCount=$nextCount;ResumedPartial=$partial;WatchdogObservedAt=$observed.ToString('o');Lane=[string]$ack.label;Harness=$nextHarness;Model=$nextModel;Effort=$nextEffort;Row=[string]$spec.row;Placement=$nextPlacement;OutFile=$HistoryPath;NoBoard=$true}
if($nextRouting){$logParams.PolicyGeneration=[long]$nextRouting.policyGeneration;$logParams.RegistryAuthorityDigest=[string]$nextRouting.registryAuthorityDigest;$logParams.RoutingFamily=[string]$nextRouting.family;$logParams.RoutingSlot=[string]$nextRouting.slot;$logParams.UsedLastKnownGood=[bool]$nextRouting.usedLastKnownGood}
try{& $LogScript @logParams|Out-Null}catch{if($_.Exception.Message-match'WATCHDOG_OBSERVATION_DUPLICATE'){[pscustomobject]@{schemaVersion='watchdog-observation-result/v1';status='DUPLICATE_SKIPPED';relaunch=$false}|ConvertTo-Json -Compress;return};throw}
$result=[ordered]@{schemaVersion='watchdog-observation-result/v1';status='RELAUNCHED';relaunch=$true;relaunchCount=$nextCount;harness=$nextHarness;model=$nextModel;effort=$nextEffort;row=[int]$spec.row;placement=$nextPlacement;elapsedSeconds=$elapsed;implementationAttemptIncrement=0;label=[string]$ack.label;launchId=[string]$ack.launchId}
if($nextRouting){$result.policyGeneration=[long]$nextRouting.policyGeneration;$result.registryAuthorityDigest=[string]$nextRouting.registryAuthorityDigest;$result.family=[string]$nextRouting.family;$result.slot=[string]$nextRouting.slot;$result.usedLastKnownGood=[bool]$nextRouting.usedLastKnownGood}
$result|ConvertTo-Json -Compress
}finally{$holdMutex.ReleaseMutex();$holdMutex.Dispose()}
