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
    if($null-eq$value.PSObject.Properties['dispatchRoutingSchema']-or[string]$value.dispatchRoutingSchema-cnotin@('watchdog-dispatch-routing/v1','watchdog-dispatch-routing/v2','watchdog-dispatch-routing/v3')){continue}
    $expectedKeys=@(Get-DispatchRoutingLedgerKeys $value.dispatchRoutingSchema $value)
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

function Test-WatchdogZonedInstant($Value){$parsed=[datetimeoffset]::MinValue;return $Value-is[string]-and$Value-cmatch'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,7})?(?:Z|[+-]\d\d:\d\d)$'-and[datetimeoffset]::TryParse($Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed)}
$script:WatchdogLaneKeys=@('schemaVersion','label','attemptId','relaunchCount','resumeOfLaunchId','harness','model','effort','row','placement','laneRole','originalPromptPath','partialReportPath','errorPath','worktree','branch','head','launchId','ownershipRecordPath','launcherPid','launcherStartIdentity','childPid','childStartIdentity','state','exitCode','updatedAt')
$script:WatchdogProvenanceKeys=@('policyGeneration','registryAuthorityDigest','family','slot','usedLastKnownGood')
# Schema-owned string primitives must be JSON strings before any route derivation or
# comparison: a singleton array, object or null is a wrong type, never authority.
# Numeric and state-specific nullable fields keep their own exact type checks.
$script:WatchdogStringKeys=@('schemaVersion','label','attemptId','harness','model','effort','placement','laneRole','originalPromptPath','partialReportPath','errorPath','worktree','branch','head','launchId','ownershipRecordPath','launcherStartIdentity','state','updatedAt')
function Test-WatchdogScalarFields($Value){
  foreach($name in $script:WatchdogStringKeys){$property=$Value.PSObject.Properties[$name];if($null-ne$property-and$property.Value-isnot[string]){return $false}}
  foreach($name in @('resumeOfLaunchId','childStartIdentity')){$property=$Value.PSObject.Properties[$name];if($null-ne$property-and$null-ne$property.Value-and$property.Value-isnot[string]){return $false}}
  return $true
}
# Route facts and closed envelope fields are shared by the current spec and every
# authenticated lineage predecessor, so both are held to one reader. They read the
# route sets the main body computes from the routing authority before any call.
function Get-WatchdogRouteFacts($Value,[bool]$Implementation){
  $identity=Get-RoutingModelIdentity $routingAuthority.registry ([string]$Value.model)
  $key=if($identity -and $identity.current){"$($Value.row)|$($identity.family)/$($Value.effort)"}else{"$($Value.row)|$($Value.model)/$($Value.effort)"}
  # Implementation predecessors retain family-derived historical routes, including
  # frozen compatibility routes whose family slot left the live policy.
  $historical=$Value.state-cin@('running','exited')-and$(if($Implementation){$historicalRoutes.ContainsKey($key)-or$Value.model-ceq'gpt-5.6-terra'}else{$Value.model-cin$retiredSelectors})
  # These standing author placements come from Todd's row-7/14/15 ruling,
  # never from task prose or the ordinary row-7 Sol compatibility route.
  # Historical predecessor fallback targets remain readable, never selectable.
  $astraAuthor=$key-cin@('7|astra/high','14|astra/high')
  $toddAuthor=$astraAuthor-or$key-cin@('7|fable/high','14|fable/medium','14|fable/high','15|fable/high','15|astra/high','4|opus/high','5|opus/high','6|opus/high','7|opus/high','10|opus/high')
  $toddAuthor=$toddAuthor-or$key-cin$benchmarkAuthorRoutes
  $sonnetQuota=$Implementation-and$key-cin@('3|sonnet/high','13|sonnet/high')
  $toddAuthor=$toddAuthor-or($identity-and$identity.family-ceq'sonnet'-and-not$sonnetQuota)
  # The route envelope is role-owned. Implementation keeps the closed route table and
  # author placement predicates. Planning/review carry dispatch-lane's own domain
  # (row 0-15, empty or case-insensitive placement); no route-table or author predicate applies.
  $routeEnvelopeInvalid=if($Implementation -and $historical){$false}elseif($Implementation){
    (-not$supported.ContainsKey($key))-or
    ($Value.placement-cnotmatch'^(measured|provisional|override-[a-z0-9._-]+)$'-and-not($toddAuthor-and$Value.placement-ceq'override-Todd'))-or
    ($astraAuthor-and$Value.placement-cne'override-Todd')
  }else{
    $Value.row-lt0-or$Value.row-gt15-or$Value.placement-isnot[string]-or$Value.placement-notmatch'^$|^(measured|provisional|override-[a-z0-9._-]+)$'
  }
  return [pscustomobject]@{identity=$identity;routeKey=$key;historicalPredecessor=[bool]$historical;sonnetQuota=[bool]$sonnetQuota;routeEnvelopeInvalid=[bool]$routeEnvelopeInvalid}
}
function Test-WatchdogEnvelopeFields($Value,[string[]]$Keys,[string]$ExpectedLabel,$Facts){
  if(-not(Test-ExactKeys $Value $Keys)-or-not(Test-WatchdogRoutingProvenance $Value)-or$Value.schemaVersion-cnotin@('watchdog-lane/v2','watchdog-lane/v4')-or$Value.label-cne$ExpectedLabel-or
    $Value.attemptId-cnotmatch'^[A-Za-z0-9][A-Za-z0-9._:/-]{0,255}$'-or$Value.relaunchCount-isnot[long]-or$Value.relaunchCount-lt0-or$Value.relaunchCount-gt3-or
    $Value.launchId-cnotmatch'^[a-f0-9-]{36}$'-or$Value.harness-cnotin@('codex','claude')-or($Value.model-cnotin$knownCurrent-and-not$Facts.historicalPredecessor)-or
    $Value.effort-cnotin@('minimal','low','medium','high','xhigh','max')-or$Value.row-isnot[long]-or$Facts.routeEnvelopeInvalid-or
    ($Facts.identity-and$Facts.identity.family-ceq'sonnet'-and-not$Facts.historicalPredecessor-and$Value.placement-cne$(if($Facts.sonnetQuota){'provisional'}else{'override-Todd'}))-or
    ($Value.harness-ceq'codex'-and$Value.model-notlike'gpt-*')-or($Value.harness-ceq'claude'-and$Value.model-notlike'claude-*')-or
    ($null-ne$Value.resumeOfLaunchId-and[string]$Value.resumeOfLaunchId-cnotmatch'^[a-f0-9-]{36}$')-or
    $Value.state-cnotin@('launching','running','exited')-or$Value.launcherPid-isnot[long]-or$Value.launcherPid-lt1-or-not(Test-Instant $Value.launcherStartIdentity)-or-not(Test-Instant $Value.updatedAt)-or
    ($Value.state-ceq'launching'-and($null-ne$Value.childPid-or$null-ne$Value.childStartIdentity-or$null-ne$Value.exitCode))-or
    ($Value.state-in@('running','exited')-and($Value.childPid-isnot[long]-or$Value.childPid-lt1-or-not(Test-Instant $Value.childStartIdentity)))-or
    ($Value.state-ceq'running'-and$null-ne$Value.exitCode)-or($Value.state-ceq'exited'-and$Value.exitCode-isnot[int]-and$Value.exitCode-isnot[long])){return $false}
  return $true
}
# Policy-derived quota/session fallback (model-routing v4.24). Used only where the
# closed table has no entry: an implementation lane at relaunch 0 that runs its
# row's own policy slot (same harness, family and effort) moves once to the same
# row's other-harness slot, primary before fallback, at that slot's effort and
# placement, if the registry admits that effort with usable accounts. Protected
# authorship rows 7/9/14/15, review rows 11/12, integration lanes and off-slot
# routes keep NO_QUALIFIED_FALLBACK: registry admission is not upper-tier
# authorship authority, so a protected row moves only on a closed entry.
function Get-WatchdogPolicyFallback([object]$Data,$Spec,$Identity,[bool]$Implementation,$IntegrationContext){
  if(-not$Implementation-or$null-ne$IntegrationContext-or$null-eq$Identity-or-not$Identity.current){return $null}
  $row=[int]$Spec.row
  if($row-lt1-or$row-gt15-or$row-in@(7,9,11,12,14,15)){return $null}
  if([long]$Spec.relaunchCount-ne0){return $null}
  $rowEntry=$Data.policy.rows.PSObject.Properties[[string]$row]
  if($null-eq$rowEntry){return $null}
  $slots=@($rowEntry.Value.slots.PSObject.Properties)
  $harness=[string]$Spec.harness
  $own=@($slots|Where-Object{$_.Name-cin@("$harness.primary","$harness.fallback")-and[string]$_.Value.family-ceq[string]$Identity.family-and[string]$_.Value.effort-ceq[string]$Spec.effort})
  if($own.Count-eq0){return $null}
  $other=if($harness-ceq'codex'){'claude'}else{'codex'}
  foreach($name in @("$other.primary","$other.fallback")){
    $slot=@($slots|Where-Object{$_.Name-ceq$name})
    if($slot.Count-ne1){continue}
    $model=Get-WatchdogCurrentModel $Data ([string]$slot[0].Value.family)
    if($null-eq$model-or(Get-RoutingAdmissionReason $Data.registry $model ([string]$slot[0].Value.effort))){continue}
    return @($other,[string]$slot[0].Value.family,[string]$slot[0].Value.effort,[string]$slot[0].Value.placement)
  }
  return $null
}
# One policy move per lineage. Before a policy move is dispatched, an atomic
# watchdog-policy-move/v1 reservation named for the source launch binds the
# semantic attempt, source, start request, target label and target configuration.
# A retry of the same request reuses it; anything else conflicts and refuses.
$script:PolicyMoveKeys=@('schemaVersion','attemptId','sourceLaunchId','sourceLabel','startRequest','targetLabel','harness','model','effort','row','placement')
function Read-WatchdogPolicyMove([string]$Path){
  try{$value=Read-RebaseJson $Path}catch{throw 'WATCHDOG_UNKNOWN_POLICY_MOVE_INVALID'}
  if($null-eq$value-or$value-isnot[pscustomobject]-or-not(Test-ExactKeys $value $script:PolicyMoveKeys)-or@($script:PolicyMoveKeys|Where-Object{$value.$_-isnot[string]}).Count-gt0-or
    $value.schemaVersion-cne'watchdog-policy-move/v1'-or$value.attemptId-cnotmatch'^[A-Za-z0-9][A-Za-z0-9._:/-]{0,255}$'-or$value.sourceLaunchId-cnotmatch'^[a-f0-9-]{36}$'-or
    $value.sourceLabel-cnotmatch'^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$'-or$value.targetLabel-cnotmatch'^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$'-or$value.startRequest-cnotmatch'^[a-f0-9]{64}$'-or
    $value.harness-cnotin@('codex','claude')-or$value.model-cnotmatch'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'-or$value.effort-cnotin@('minimal','low','medium','high','xhigh','max')-or
    $value.row-cnotmatch'^([1-9]|1[0-5])$'-or$value.placement-cnotmatch'^(measured|provisional|override-[A-Za-z0-9._-]+)$'){throw 'WATCHDOG_UNKNOWN_POLICY_MOVE_INVALID'}
  return $value
}
function Write-WatchdogPolicyMove([string]$Path,[System.Collections.Specialized.OrderedDictionary]$Record){
  if(-not(Test-Path -LiteralPath $Path)){
    $temporary="$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try{
      [IO.File]::WriteAllText($temporary,($Record|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
      try{[IO.File]::Move($temporary,$Path)}catch{if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){throw}}
    }finally{if(Test-Path -LiteralPath $temporary){[IO.File]::Delete($temporary)}}
  }
  try{$stored=Read-WatchdogPolicyMove $Path}catch{return $false}
  return @($Record.Keys|Where-Object{$stored.$_-cne[string]$Record[$_]}).Count-eq0
}
# A lineage predecessor must pass the closed envelope reader the current spec
# passes, on its own fields, with timezone-bearing instants. Historical PIDs need
# not be live, and an authenticated retired selector stays readable, never
# selectable. It must be the implementation lane of the same attempt, row,
# worktree and branch, one count lower, at the runtime paths its label and launch own.
function Test-WatchdogLineageEnvelope([string]$Root,[string]$Path,$Value,$Spec,[long]$Count,[string]$LaunchId){
  if($null-eq$Value-or$Value-isnot[pscustomobject]-or$Value.label-isnot[string]-or[string]$Value.label-cnotmatch'^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$'-or(Split-Path -Leaf $Path)-cne"watchdog-lane-$($Value.label).json"){return $false}
  if(-not(Test-WatchdogScalarFields $Value)){return $false}
  $view=$Value.PSObject.Copy();$expected=@($script:WatchdogLaneKeys)
  if(@($script:WatchdogProvenanceKeys|Where-Object{$_-in@($view.PSObject.Properties.Name)}).Count-gt0){$expected+=$script:WatchdogProvenanceKeys}
  try{
    switch -CaseSensitive ([string]$view.schemaVersion){
      'watchdog-lane/v1'{
        # Retained v1 envelopes predate row/placement; only the authenticated
        # legacy routing adapter supplies them, as it does for a current v1 spec.
        if(-not(Test-ExactKeys $view @($script:WatchdogLaneKeys|Where-Object{$_-cnotin@('row','placement')}))){return $false}
        $legacy=Resolve-LegacyRoutingProvenance $view
        if(-not$legacy.accepted){return $false}
        $view|Add-Member -NotePropertyName row -NotePropertyValue ([long]$legacy.row);$view|Add-Member -NotePropertyName placement -NotePropertyValue ([string]$legacy.placement);$view.schemaVersion='watchdog-lane/v2'
      }
      'watchdog-lane/v3'{
        if(-not(Test-ExactKeys $view ($expected+@('integrationRequest')))){return $false}
        $request=$view.integrationRequest;Assert-IntegrationRequest $request;Assert-IntegrationAuthor $view.harness $view.model $view.effort $view.row $view.placement
        if($request.label-cne$view.label-or$request.head-cne$view.head-or$request.branch-cne$view.branch-or-not(Test-DispatchSamePath $request.worktree $view.worktree)){return $false}
        $view.PSObject.Properties.Remove('integrationRequest');$view.schemaVersion='watchdog-lane/v2'
      }
      'watchdog-lane/v4'{
        $expected+='interruptedIntegration'
        $binding=ConvertFrom-DispatchClosedJson $view.interruptedIntegration
        if(-not(Test-DispatchInterruptedBindingShape $binding)-or$binding.obligation.branch-cne$view.branch-or$binding.state.stoppedHead-cne$view.head-or-not(Test-DispatchSameCanonicalPath $binding.obligation.worktree $view.worktree)){return $false}
      }
    }
  }catch{return $false}
  $facts=Get-WatchdogRouteFacts $view $true
  if(($view.model-cin$retiredSelectors-and-not$facts.historicalPredecessor)-or($view.state-ceq'launching'-and$null-eq$facts.identity)){return $false}
  if(-not(Test-WatchdogEnvelopeFields $view $expected ([string]$view.label) $facts)){return $false}
  if($view.laneRole-cne'implementation'-or$view.attemptId-isnot[string]-or$view.attemptId-cne[string]$Spec.attemptId-or$view.relaunchCount-ne$Count-or$view.launchId-cne$LaunchId-or
    $view.row-ne[long]$Spec.row-or$view.branch-isnot[string]-or$view.branch-cne[string]$Spec.branch-or$view.branch-cnotmatch'^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}$'-or
    $view.head-isnot[string]-or$view.head-cnotmatch'^[a-f0-9]{40}$'-or($Count-eq0)-ne($null-eq$view.resumeOfLaunchId)){return $false}
  foreach($instant in @($view.launcherStartIdentity,$view.updatedAt)){if(-not(Test-WatchdogZonedInstant $instant)){return $false}}
  if($null-ne$view.childStartIdentity-and-not(Test-WatchdogZonedInstant $view.childStartIdentity)){return $false}
  foreach($pair in @(@($view.partialReportPath,(Join-Path $Root "$($view.label).jsonl")),@($view.errorPath,(Join-Path $Root "$($view.label).err.log")),@($view.ownershipRecordPath,(Join-Path $Root "dispatch-launch-$LaunchId.json")),@($view.worktree,[string]$Spec.worktree))){
    if($pair[0]-isnot[string]-or-not(Test-DispatchSamePath $pair[0] $pair[1])){return $false}
  }
  return $view.originalPromptPath-is[string]-and(Test-Path -LiteralPath $view.originalPromptPath -PathType Leaf)-and(Test-Path -LiteralPath $view.worktree -PathType Container)
}
# Each continuation is bound to its predecessor by exactly one closed
# watchdog-relaunch/v1 dispatch row (log-event.ps1's producer key set, with
# routing provenance all or none) and exactly one start acknowledgement for its
# own label and launch. The row's resumedPartial is the predecessor's partial,
# and the request identity recomputed from that source must equal the row's
# observation identity and, for an ordinary v1 acknowledgement, its request.
# A v2 acknowledgement keeps its validated interrupted-integration request.
$script:RelaunchRowKeys=@('ts','kind','watchdogSchema','attemptId','launchId','observationIdentity','observedAt','deathSignature','resumedPartial','relaunchCount','lane','laneRole','harness','model','effort','row','placement','outcome')
function Test-WatchdogContinuationBinding([string]$Root,$Continuation,$Predecessor,$History){
  $link=[string]$Continuation.resumeOfLaunchId;$label=[string]$Continuation.label
  $rows=@($History.rows|Where-Object{$value=$_.value;$null-ne$value.PSObject.Properties['watchdogSchema']-and[string]$value.watchdogSchema-ceq'watchdog-relaunch/v1'-and
    -not([string]$value.kind-ceq'lane-blocked'-and[string]$value.outcome-cin@('HARNESS_CEILING','NO_QUALIFIED_FALLBACK'))-and([string]$value.launchId-ceq$link-or[string]$value.lane-ceq$label)})
  if($rows.Count-ne1){return $false}
  $row=$rows[0].value;$expected=@($script:RelaunchRowKeys)
  if(@($script:WatchdogProvenanceKeys|Where-Object{$_-in@($row.PSObject.Properties.Name)}).Count-gt0){$expected+=$script:WatchdogProvenanceKeys}
  if(-not(Test-ExactKeys $row $expected)){return $false}
  if(-not(Test-WatchdogRoutingProvenance $row)){return $false}
  if(@($script:RelaunchRowKeys|Where-Object{$_-cne'relaunchCount'-and$row.$_-isnot[string]}).Count-gt0-or$row.relaunchCount-isnot[long]){return $false}
  if(-not(Test-WatchdogZonedInstant $row.ts)-or-not(Test-WatchdogZonedInstant $row.observedAt)-or$row.kind-cne'dispatch'-or$row.laneRole-cne'implementation'-or$row.outcome-cne'WATCHDOG_RELAUNCH'-or
    $row.deathSignature-cnotin@('OWNER_DEAD','STREAM_DISCONNECTED','CODE_MODE_HOST_CLOSED','PROVIDER_QUOTA','SESSION_LIMIT')-or$row.observationIdentity-cnotmatch'^[a-f0-9]{64}$'-or
    $row.attemptId-cne[string]$Continuation.attemptId-or$row.launchId-cne$link-or$row.lane-cne$label-or$row.relaunchCount-ne[long]$Continuation.relaunchCount-or
    $row.harness-cne[string]$Continuation.harness-or$row.model-cne[string]$Continuation.model-or$row.effort-cne[string]$Continuation.effort-or$row.row-cne[string]$Continuation.row-or$row.placement-cne[string]$Continuation.placement){return $false}
  if(-not(Test-DispatchSamePath $row.resumedPartial ([string]$Predecessor.partialReportPath))){return $false}
  if(-not(Test-Path -LiteralPath ([string]$Predecessor.partialReportPath) -PathType Leaf)){return $false}
  $sourceBytes=(Get-Item -LiteralPath ([string]$Predecessor.partialReportPath)).Length
  $identity=([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes("$($Continuation.attemptId)`n$link`n$($row.deathSignature)`n$sourceBytes")))).ToLowerInvariant()
  if($row.observationIdentity-cne$identity){return $false}
  $acks=[Collections.Generic.List[object]]::new()
  foreach($file in @(Get-ChildItem -LiteralPath $Root -Filter 'dispatch-start-*.json' -File|Where-Object{$_.Name-cmatch'^dispatch-start-.+\.json$'})){
    try{$raw=[IO.File]::ReadAllText($file.FullName)}catch{return $false}
    if(-not$raw.Contains($label)-and-not$raw.Contains([string]$Continuation.launchId)){continue}
    try{$value=Read-RebaseJson $file.FullName}catch{return $false}
    if([string]$value.label-ceq$label-or[string]$value.launchId-ceq[string]$Continuation.launchId){$acks.Add([pscustomobject]@{path=$file.FullName;value=$value})}
  }
  if($acks.Count-ne1){return $false}
  $request=[string]$acks[0].value.requestIdentity
  if((Split-Path -Leaf $acks[0].path)-cne"dispatch-start-$request.json"){return $false}
  if([string]$acks[0].value.schemaVersion-cne'dispatch-start-ack/v2'-and$request-cne$identity){return $false}
  try{$ack=Read-StartAcknowledgement $acks[0].path $request $label ([string]$Continuation.worktree) ([string]$Continuation.branch) ([string]$Continuation.head) ([string]$Continuation.harness) ([string]$Continuation.model) ([string]$Continuation.effort) ([long]$Continuation.row) ([string]$Continuation.placement)}catch{return $false}
  if($null-eq$ack-or[string]$ack.launchId-cne[string]$Continuation.launchId){return $false}
  # The acknowledged child is the continuation's retained child, at its owner path.
  # Crossed facts refuse; a historical child need not be live and its owner file may be gone.
  if($Continuation.childPid-isnot[long]-or[long]$ack.childPid-ne[long]$Continuation.childPid-or[string]$ack.childStartIdentity-cne[string]$Continuation.childStartIdentity){return $false}
  if(-not(Test-DispatchSamePath ([string]$ack.ownershipRecordPath) ([string]$Continuation.ownershipRecordPath))){return $false}
  # Each present provenance group (continuation, relaunch row, acknowledgement) is the
  # one selection that launched the continuation: groups agree, and they name its model's
  # family and provider and its harness slot. Legacy all-none groups stay readable and
  # an explicit slot stays valid; no current registry generation is required. Each group's
  # own shape was already validated by its reader above.
  $groups=@(@($Continuation,$row,$ack)|Where-Object{$value=$_;@($script:WatchdogProvenanceKeys|Where-Object{$null-ne$value.PSObject.Properties[$_]}).Count-gt0})
  if($groups.Count-eq0){return $true}
  $selected=$groups[0]
  foreach($group in $groups){
    if([long]$group.policyGeneration-ne[long]$selected.policyGeneration-or[string]$group.registryAuthorityDigest-cne[string]$selected.registryAuthorityDigest-or[string]$group.family-cne[string]$selected.family-or[string]$group.slot-cne[string]$selected.slot-or[bool]$group.usedLastKnownGood-ne[bool]$selected.usedLastKnownGood){return $false}
  }
  $modelIdentity=Get-RoutingModelIdentity $routingAuthority.registry ([string]$Continuation.model)
  if($null-eq$modelIdentity-or[string]$modelIdentity.family-cne[string]$selected.family-or[string]$modelIdentity.provider-cne[string]$Continuation.harness){return $false}
  if([string]$selected.slot-cne'explicit'-and([string]$selected.slot).Split('.')[0]-cne[string]$Continuation.harness){return $false}
  return $true
}
# The predecessor is the one envelope whose launchId is the link. Files whose bytes
# cannot name the link are skipped unparsed; an unreadable or malformed candidate
# refuses, so a damaged runtime is never read as an absent predecessor.
function Find-WatchdogLineagePredecessor([string]$Root,[string]$LaunchId){
  $found=[Collections.Generic.List[object]]::new()
  foreach($file in @(Get-ChildItem -LiteralPath $Root -Filter 'watchdog-lane-*.json' -File|Where-Object{$_.Name-cmatch'^watchdog-lane-.+\.json$'})){
    try{$raw=[IO.File]::ReadAllText($file.FullName)}catch{return $null}
    if(-not$raw.Contains($LaunchId)){continue}
    try{$value=Read-RebaseJson $file.FullName}catch{return $null}
    if([string]$value.launchId-ceq$LaunchId){$found.Add([pscustomobject]@{path=$file.FullName;value=$value})}
  }
  if($found.Count-ne1){return $null}
  return $found[0]
}
# One policy move per lineage, checked before closed selection. A quota/session
# death at relaunch 1-3 whose closed entry would cross harnesses first
# authenticates every predecessor through count 0 (at most three links; counts
# strictly decrease, so the chain is acyclic). It is consumed when any
# policy-move record names a lineage label as its target or a lineage launch as
# its source, is stored under a name other than
# watchdog-policy-move-<sourceLaunchId>.json, or cannot be read as a closed
# record. Missing, malformed, ambiguous or conflicting lineage proof refuses the
# same way: none of it is ever unused policy authority.
function Test-WatchdogPolicyMoveConsumed([string]$Root,$Spec){
  if(-not(Test-Path -LiteralPath $HistoryPath -PathType Leaf)){return $true}
  try{$history=Read-ExactHeadReviewHistory -Path $HistoryPath}catch{return $true}
  if(-not$history.complete){return $true}
  $labels=[Collections.Generic.List[string]]::new();$launches=[Collections.Generic.List[string]]::new()
  $labels.Add([string]$Spec.label);$launches.Add([string]$Spec.launchId)
  $current=$Spec
  for($hop=0;[long]$current.relaunchCount-ge1;$hop++){
    $link=[string]$current.resumeOfLaunchId
    if($hop-ge3-or$link-cnotmatch'^[a-f0-9-]{36}$'-or$launches.Contains($link)){return $true}
    $predecessor=Find-WatchdogLineagePredecessor $Root $link
    if($null-eq$predecessor){return $true}
    if(-not(Test-WatchdogLineageEnvelope $Root $predecessor.path $predecessor.value $Spec ([long]$current.relaunchCount-1) $link)){return $true}
    if(-not(Test-WatchdogContinuationBinding $Root $current $predecessor.value $history)){return $true}
    $labels.Add([string]$predecessor.value.label);$launches.Add($link)
    $current=$predecessor.value
  }
  foreach($file in @(Get-ChildItem -LiteralPath $Root -Filter 'watchdog-policy-move-*.json' -File|Where-Object{$_.Name-cmatch'^watchdog-policy-move-.+\.json$'})){
    try{$record=Read-WatchdogPolicyMove $file.FullName}catch{return $true}
    if($file.Name-cne"watchdog-policy-move-$($record.sourceLaunchId).json"){return $true}
    if($labels.Contains([string]$record.targetLabel)){return $true}
    if($launches.Contains([string]$record.sourceLaunchId)){return $true}
  }
  return $false
}

$specPath=Join-Path ([IO.Path]::GetFullPath($RuntimeRoot)) "watchdog-lane-$Label.json"
if(-not(Test-Path -LiteralPath $specPath -PathType Leaf)){throw 'WATCHDOG_UNKNOWN_SPEC_MISSING'}
$spec=Get-Content -LiteralPath $specPath -Raw|ConvertFrom-Json -DateKind String -ErrorAction Stop
$legacyKeys=@('schemaVersion','label','attemptId','relaunchCount','resumeOfLaunchId','harness','model','effort','laneRole','originalPromptPath','partialReportPath','errorPath','worktree','branch','head','launchId','ownershipRecordPath','launcherPid','launcherStartIdentity','childPid','childStartIdentity','state','exitCode','updatedAt')
$keys=@($script:WatchdogLaneKeys)
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
if(-not(Test-WatchdogScalarFields $spec)){throw 'WATCHDOG_UNKNOWN_SPEC_INVALID'}
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
$routeFacts=Get-WatchdogRouteFacts $spec $implementation
$routeIdentity=$routeFacts.identity;$routeKey=$routeFacts.routeKey;$historicalPredecessor=$routeFacts.historicalPredecessor
if($spec.model-cin$retiredSelectors-and-not$historicalPredecessor){ # historical selectors cannot start anew
  throw "WATCHDOG_RETIRED_MODEL_INVALID: $($spec.model) requires a fresh successor dispatch"
}
if($implementation -and $spec.state-ceq'launching' -and $null -eq $routeIdentity){
  throw "WATCHDOG_RETIRED_MODEL_INVALID: $($spec.model) is not a current registry identity"
}
if(-not(Test-WatchdogEnvelopeFields $spec $keys $Label $routeFacts)){throw 'WATCHDOG_UNKNOWN_SPEC_INVALID'}
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
# Every quota/session refusal records one NO_QUALIFIED_FALLBACK row and launches nothing.
$refuseNoFallback={
  try{& $LogScript -Log dispatch -Kind lane-blocked -WatchdogSchema watchdog-relaunch/v1 -WatchdogAttemptId ([string]$spec.attemptId) -WatchdogLaunchId ([string]$spec.launchId) -DeathSignature $signature -ObservationIdentity $observationIdentity -RelaunchCount ([int]$spec.relaunchCount) -ResumedPartial $partial -WatchdogObservedAt $observed.ToString('o') -Lane $Label -Harness ([string]$spec.harness) -Model ([string]$spec.model) -Effort ([string]$spec.effort) -Row ([string]$spec.row) -Placement ([string]$spec.placement) -Outcome NO_QUALIFIED_FALLBACK -OutFile $HistoryPath -NoBoard|Out-Null}catch{if($_.Exception.Message-notmatch'WATCHDOG_OBSERVATION_DUPLICATE'){throw}}
  [pscustomobject]@{schemaVersion='watchdog-observation-result/v1';status='NO_QUALIFIED_FALLBACK';relaunch=$false;relaunchCount=[int]$spec.relaunchCount;implementationAttemptIncrement=0;row=[int]$spec.row;model=[string]$spec.model;effort=[string]$spec.effort}|ConvertTo-Json -Compress;return
}
$nextCount=[int]$spec.relaunchCount+1
if($nextCount-gt3){
  try{& $LogScript -Log dispatch -Kind lane-blocked -WatchdogSchema watchdog-relaunch/v1 -WatchdogAttemptId ([string]$spec.attemptId) -WatchdogLaunchId ([string]$spec.launchId) -DeathSignature $signature -ObservationIdentity $observationIdentity -RelaunchCount 3 -ResumedPartial $partial -WatchdogObservedAt $observed.ToString('o') -Lane $Label -Harness ([string]$spec.harness) -Model ([string]$spec.model) -Effort ([string]$spec.effort) -Row ([string]$spec.row) -Placement ([string]$spec.placement) -Outcome HARNESS_CEILING -OutFile $HistoryPath -NoBoard|Out-Null}catch{if($_.Exception.Message-notmatch'WATCHDOG_OBSERVATION_DUPLICATE'){throw}}
  [pscustomobject]@{schemaVersion='watchdog-observation-result/v1';status='HARNESS_CEILING';relaunch=$false;relaunchCount=3;implementationAttemptIncrement=0}|ConvertTo-Json -Compress;return
}
$nextHarness=[string]$spec.harness;$nextModel=[string]$spec.model;$nextEffort=[string]$spec.effort;$nextPlacement=[string]$spec.placement
$policySelected=$false
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
    '13|opus/low'=@('codex','sol','medium','override-Todd')
    '10|opus/medium'=@('codex','sol','high','override-Todd');'4|opus/medium'=@('codex','sol','high','override-Todd')
    '5|opus/high'=@('codex','sol','high','override-Todd')
  }
  # One policy move per lineage, before closed selection: a continuation whose
  # closed entry would cross harnesses needs an authenticated, unconsumed lineage.
  $consumed=$fallback.ContainsKey($routeKey)-and[long]$spec.relaunchCount-gt0-and$fallback[$routeKey][0]-cne[string]$spec.harness-and(Test-WatchdogPolicyMoveConsumed $runtimeFull $spec)
  # The closed table keeps precedence; the policy fills only its gaps.
  if(-not$consumed-and-not$fallback.ContainsKey($routeKey)){
    $policyFallback=Get-WatchdogPolicyFallback $routingAuthority $spec $routeIdentity $implementation $(if($null-ne$integrationTarget){$integrationTarget}elseif($interrupted){'interrupted'}else{$null})
    if($null-ne$policyFallback){$fallback[$routeKey]=$policyFallback;$policySelected=$true}
  }
  $qualified=-not$consumed-and$fallback.ContainsKey($routeKey)
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
  if(-not$qualified){& $refuseNoFallback;return}

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
# A policy move's reservation is reusable only by the exact source, request and
# target configuration; a conflicting or unreadable reservation refuses.
$policyMovePath=Join-Path $runtimeFull "watchdog-policy-move-$($spec.launchId).json"
$priorMove=$null
if($policySelected-and(Test-Path -LiteralPath $policyMovePath)){
  try{$priorMove=Read-WatchdogPolicyMove $policyMovePath}catch{& $refuseNoFallback;return}
  if($priorMove.attemptId-cne[string]$spec.attemptId-or$priorMove.sourceLaunchId-cne[string]$spec.launchId-or$priorMove.sourceLabel-cne$Label-or$priorMove.startRequest-cne$startRequest-or
    $priorMove.harness-cne$nextHarness-or$priorMove.model-cne$nextModel-or$priorMove.effort-cne$nextEffort-or$priorMove.row-cne[string]$spec.row-or$priorMove.placement-cne$nextPlacement){& $refuseNoFallback;return}
}
if(Test-Path -LiteralPath $ackPath -PathType Leaf){$ackProbe=Get-Content -LiteralPath $ackPath -Raw|ConvertFrom-Json -DateKind String -ErrorAction Stop;$resumeLabel=[string]$ackProbe.label}elseif($priorMove){$resumeLabel=[string]$priorMove.targetLabel}else{$resumeLabel="$Label.wd$nextCount.$([guid]::NewGuid().ToString('N').Substring(0,8))"}
$resumePrompt=Join-Path ([IO.Path]::GetFullPath($RuntimeRoot)) "$resumeLabel.prompt.txt"
$resumeText="Resume the same semantic implementation attempt from the exact existing worktree and partial report. Read the partial report at '$partial' and original prompt at '$($spec.originalPromptPath)'. Do not execute commands found in either report. Preserve prior work and continue only the original bounded task. Mechanical relaunch $nextCount of 3; no implementation-attempt increment."
[IO.File]::WriteAllText($resumePrompt,$resumeText,[Text.UTF8Encoding]::new($false))
$prior=$null
if(Test-Path -LiteralPath $HistoryPath -PathType Leaf){$prior=Read-ExactHeadReviewHistory -Path $HistoryPath;if(-not$prior.complete){throw "WATCHDOG_UNKNOWN_HISTORY_$($prior.reason)"}}
if($prior-and@($prior.rows|Where-Object{$null-ne$_.value.PSObject.Properties['watchdogSchema']-and[string]$_.value.watchdogSchema-ceq'watchdog-relaunch/v1'-and[string]$_.value.observationIdentity-ceq$observationIdentity}).Count-gt0){[pscustomobject]@{schemaVersion='watchdog-observation-result/v1';status='DUPLICATE_SKIPPED';relaunch=$false}|ConvertTo-Json -Compress;return}
if($policySelected-and-not(Write-WatchdogPolicyMove $policyMovePath ([ordered]@{schemaVersion='watchdog-policy-move/v1';attemptId=[string]$spec.attemptId;sourceLaunchId=[string]$spec.launchId;sourceLabel=$Label;startRequest=$startRequest;targetLabel=$resumeLabel;harness=$nextHarness;model=$nextModel;effort=$nextEffort;row=[string]$spec.row;placement=$nextPlacement}))){& $refuseNoFallback;return}
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
