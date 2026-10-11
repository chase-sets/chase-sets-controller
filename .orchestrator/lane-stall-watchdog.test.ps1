param([switch]$BeforeFixControl,[ValidateSet('v2','v1')][string]$Row15MeasuredControl,[switch]$AuthorityOnly,[switch]$RetiredOnly,[switch]$SonnetOnly,[switch]$ExplicitRoutingOnly,[switch]$CapacityOnly,[switch]$PolicyFallbackOnly,[switch]$PolicyFallbackMutantsOnly,[string]$PolicyFallbackCase,[string]$WatchdogScript,[ValidateSet('pool-quota-envelope-classifies-provider-quota','sol-quota-relaunches-ruled-opus-fallback','non-quota-503-stays-owner-dead')][string]$Named8098Control,[ValidateSet('role-envelope','observation-without-relaunch')][string]$Named8186Control)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'routing-data-test-support.ps1')
$routingTestScope=Enter-RoutingDataTestScope
try {
$root=Join-Path ([IO.Path]::GetTempPath()) ('lane-watchdog-test-'+[guid]::NewGuid().ToString('N'))
$runtime=Join-Path $root 'runtime';$worktree=Join-Path $root 'worktree';$history=Join-Path $runtime 'history.jsonl';$calls=Join-Path $runtime 'calls.txt'
$watchdog=if($WatchdogScript){$WatchdogScript}else{Join-Path $PSScriptRoot 'lane-stall-watchdog.ps1'}
function Assert-True($Condition,[string]$Message){if(-not$Condition){throw "ASSERTION FAILED: $Message"}}
function Get-Harness([string]$Model){if($Model-like'claude-*'){'claude'}else{'codex'}}
function New-Spec([string]$Label,[string]$Model='gpt-6.1-sol',[string]$Effort='high',[int]$Count=0,[int]$Row=4,[string]$Placement='provisional'){
  $partial=Join-Path $runtime "$Label.jsonl";$error=Join-Path $runtime "$Label.err.log";Set-Content -LiteralPath $partial -Value 'unmistakably synthetic partial report';Set-Content -LiteralPath $error -Value 'native owner ended'
  $launchId=[guid]::NewGuid().ToString()
  $spec=[ordered]@{schemaVersion='watchdog-lane/v2';label=$Label;attemptId='synthetic-semantic-attempt';relaunchCount=[long]$Count;resumeOfLaunchId=$null;harness=(Get-Harness $Model);model=$Model;effort=$Effort;row=[long]$Row;placement=$Placement;laneRole='implementation';originalPromptPath=(Join-Path $runtime 'original.prompt.txt');partialReportPath=$partial;errorPath=$error;worktree=$worktree;branch='synthetic/branch';head=('a'*40);launchId=$launchId;ownershipRecordPath=(Join-Path $runtime "dispatch-launch-$launchId.json");launcherPid=[long]999991;launcherStartIdentity='2000-01-01T00:00:00.0000000Z';childPid=[long]999992;childStartIdentity='2000-01-01T00:00:01.0000000Z';state='exited';exitCode=[long]1;updatedAt=[datetimeoffset]::UtcNow.AddMinutes(-1).ToString('o')}
  $path=Join-Path $runtime "watchdog-lane-$Label.json";[IO.File]::WriteAllText($path,($spec|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false));[pscustomobject]@{spec=$spec;partial=$partial;error=$error}
}
function New-LegacySpec([string]$Label,[string]$Model='gpt-6.1-sol',[string]$Effort='high'){
  $item=New-Spec $Label $Model $Effort;$item.spec.schemaVersion='watchdog-lane/v1';$item.spec.Remove('row');$item.spec.Remove('placement')
  [IO.File]::WriteAllText((Join-Path $runtime "watchdog-lane-$Label.json"),($item.spec|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false));$item
}
function Add-LegacyRoutingRow($Item,[int]$Row=4,[string]$Placement='provisional',[hashtable]$Changes=@{}){
  $value=[ordered]@{attemptId=[string]$Item.spec.attemptId;label=[string]$Item.spec.label;lane=(Split-Path -Leaf $Item.spec.worktree);transcript=(Split-Path -Leaf $Item.spec.partialReportPath);harness=[string]$Item.spec.harness;model=[string]$Item.spec.model;effort=[string]$Item.spec.effort;row=[long]$Row;placement=$Placement;worktree=[IO.Path]::GetFullPath([string]$Item.spec.worktree).TrimEnd('\','/');branch=[string]$Item.spec.branch;head=[string]$Item.spec.head}
  foreach($key in $Changes.Keys){$value[$key]=$Changes[$key]}
  & (Join-Path $PSScriptRoot 'log-event.ps1') -Log dispatch -Kind dispatch -DispatchRoutingSchema watchdog-dispatch-routing/v1 -DispatchAttemptId $value.attemptId -DispatchLabel $value.label -Lane $value.lane -LaneRole implementation -Transcript $value.transcript -Harness $value.harness -Model $value.model -Effort $value.effort -Row ([string]$value.row) -Placement $value.placement -DispatchWorktree $value.worktree -DispatchBranch $value.branch -DispatchHead $value.head -OutFile $history -NoBoard|Out-Null
}
function New-Observation([string]$Name,[string]$Owner='dead',[string]$Descendant='none',[int]$AgeSeconds=299){
  $now=[datetimeoffset]::UtcNow;$value=[ordered]@{ownerState=$Owner;descendantState=$Descendant;transcriptStopped=$true;observedAt=$now.AddSeconds(-$AgeSeconds).ToString('o');nowUtc=$now.ToString('o')}
  $path=Join-Path $runtime "$Name.observation.json";[IO.File]::WriteAllText($path,($value|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false));$path
}
function Invoke-Watchdog($Item,[string]$Name){& $watchdog -Label $Item.spec.label -RuntimeRoot $runtime -HistoryPath $history -TranscriptPath $Item.partial -ObservationFixture (New-Observation $Name) -DispatchScript $stub -SynchronousDispatch|ConvertFrom-Json -DateKind String}
function Save-Spec($Item){[IO.File]::WriteAllText((Join-Path $runtime "watchdog-lane-$($Item.spec.label).json"),($Item.spec|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))}
function Get-CallCount {if(Test-Path $calls){@(Get-Content $calls).Count}else{0}}
function Assert-Recovery($Item,$Result,[string]$Model,[string]$Effort,[string]$Placement,[int]$Before){
  Assert-True ($Result.status-ceq'RELAUNCHED'-and$Result.row-eq$Item.spec.row-and$Result.model-ceq$Model-and$Result.effort-ceq$Effort-and$Result.placement-ceq$Placement-and$Result.relaunchCount-eq($Item.spec.relaunchCount+1)-and$Result.implementationAttemptIncrement-eq0) 'recovery result changed exact route or semantic count'
  $expected="$($Result.label)|$(Get-Harness $Model)|$Model|$Effort|$($Item.spec.row)|$Placement|$($Item.spec.attemptId)|$($Item.spec.relaunchCount+1)|$($Item.spec.launchId)"
  Assert-True ((Get-CallCount)-eq($Before+1)-and(Get-Content $calls -Tail 1)-ceq$expected) 'actual dispatch did not receive the exact authorized configuration/placement/attempt'
  $row=Get-Content $history -Tail 1|ConvertFrom-Json -DateKind String
  Assert-True ($row.model-ceq$Model-and$row.effort-ceq$Effort-and$row.row-eq$Item.spec.row-and$row.placement-ceq$Placement-and$row.relaunchCount-eq$Result.relaunchCount) 'canonical relaunch row lost selected configuration/placement/count'
}
function Test-SonnetCutover {
  foreach($route in @(@(3,'medium'),@(13,'medium'),@(10,'high'))){
    $old=New-Spec "sonnet-old-$($route[0])" 'claude-sonnet-5' $route[1] 0 $route[0] override-Todd
    $before=Get-CallCount;$hash=(Get-FileHash $old.partial).Hash
    $live=& $watchdog -Label $old.spec.label -RuntimeRoot $runtime -HistoryPath $history -TranscriptPath $old.partial -ObservationFixture (New-Observation $old.spec.label 'live' 'none') -DispatchScript $stub -SynchronousDispatch|ConvertFrom-Json
    Assert-True ($live.status-ceq'LIVE_SLOW'-and(Get-CallCount)-eq$before) 'live Sonnet 5 worker disturbed'
    $dead=Invoke-Watchdog $old "$($old.spec.label)-dead"
    Assert-True ($dead.status-ceq'RETIRED_MODEL_REQUIRES_REDISPATCH'-and-not$dead.relaunch-and(Get-CallCount)-eq$before-and(Get-FileHash $old.partial).Hash-ceq$hash) 'historical Sonnet worker relaunched or relabeled'
    $old.spec.state='launching';$old.spec.childPid=$null;$old.spec.childStartIdentity=$null;$old.spec.exitCode=$null;Save-Spec $old
    $refused=$false;try{Invoke-Watchdog $old $old.spec.label|Out-Null}catch{$refused=$_.Exception.Message-match'WATCHDOG_RETIRED_MODEL_INVALID'}
    Assert-True ($refused-and(Get-CallCount)-eq$before) 'new Sonnet 5 worker admitted'
    $sonnet=New-Spec "sonnet55-row$($route[0])" 'claude-sonnet-5-5' $route[1] 0 $route[0] override-Todd
    $before=Get-CallCount;$result=Invoke-Watchdog $sonnet $sonnet.spec.label
    Assert-Recovery $sonnet $result 'claude-sonnet-5-5' $route[1] override-Todd $before
  }
  $sonnetQuota=New-Spec 'sonnet55-row10-quota' 'claude-sonnet-5-5' high 0 10 override-Todd
  Set-Content $sonnetQuota.error 'provider quota exceeded'
  $before=Get-CallCount;$result=Invoke-Watchdog $sonnetQuota $sonnetQuota.spec.label
  Assert-Recovery $sonnetQuota $result 'gpt-6.1-sol' high provisional $before
  $sonnetMeasured=New-Spec 'sonnet55-not-measured' 'claude-sonnet-5-5' medium 0 3 measured
  $before=Get-CallCount;$refused=$false
  try{Invoke-Watchdog $sonnetMeasured $sonnetMeasured.spec.label|Out-Null}catch{$refused=$_.Exception.Message-match'WATCHDOG_UNKNOWN_SPEC_INVALID'}
  Assert-True ($refused-and(Get-CallCount)-eq$before) 'Sonnet 5.5 inherited measured placement'
  foreach($route in @(3,13)){
    $challenger=New-Spec "sonnet55-challenger-$route" 'claude-sonnet-5-5' high 0 $route provisional
    $before=Get-CallCount;$result=Invoke-Watchdog $challenger $challenger.spec.label
    Assert-Recovery $challenger $result 'claude-sonnet-5-5' high provisional $before
    foreach($signature in @('provider quota exceeded','session limit reached')){
      $blocked=New-Spec "sonnet55-quota-$route-$($signature.Split(' ')[0])" 'claude-sonnet-5-5' high 0 $route provisional
      Set-Content $blocked.error $signature
      $before=Get-CallCount;$result=Invoke-Watchdog $blocked $blocked.spec.label
      Assert-True ($result.status-ceq'NO_QUALIFIED_FALLBACK'-and-not$result.relaunch-and(Get-CallCount)-eq$before) 'Sonnet challenger invented cross-model quota/session fallback'
    }
    foreach($placement in @('Provisional','override-Todd','override-todd','measured')){
      $invalid=New-Spec "sonnet55-bad-high-$route-$placement" 'claude-sonnet-5-5' high 0 $route $placement
      $before=Get-CallCount;$refused=$false
      try{Invoke-Watchdog $invalid $invalid.spec.label|Out-Null}catch{$refused=$_.Exception.Message-match'WATCHDOG_UNKNOWN_SPEC_INVALID'}
      Assert-True ($refused-and(Get-CallCount)-eq$before) 'Sonnet high quota placement lost exact-case provisional gate'
    }
    foreach($placement in @('provisional','override-todd','Override-Todd')){
      $invalid=New-Spec "sonnet55-bad-medium-$route-$placement" 'claude-sonnet-5-5' medium 0 $route $placement
      $before=Get-CallCount;$refused=$false
      try{Invoke-Watchdog $invalid $invalid.spec.label|Out-Null}catch{$refused=$_.Exception.Message-match'WATCHDOG_UNKNOWN_SPEC_INVALID'}
      Assert-True ($refused-and(Get-CallCount)-eq$before) 'Sonnet conditional medium lost exact-case override-Todd gate'
    }
  }
  Write-Output 'PASS Sonnet cutover/rebalance: historical workers preserved, rows 3/13 medium and high quota recover exactly, row-10 fallback retained, quota/session exhaustion closed, placement case enforced'
}
# #9092: a cross-harness move at relaunch 1-3 needs an authenticated lineage, so a
# continuation is built from a real watchdog relaunch (canonical relaunch row and start
# acknowledgement) of its predecessor, never as a bare count>0 spec.
function New-Continuation($Prior,$Result,[string]$Model,[string]$Effort,[string]$Placement){
  $item=New-Spec ([string]$Result.label) $Model $Effort ([int]$Prior.spec.relaunchCount+1) ([int]$Prior.spec.row) $Placement
  $item.spec.attemptId=$Prior.spec.attemptId;$item.spec.launchId=[string]$Result.launchId;$item.spec.resumeOfLaunchId=$Prior.spec.launchId
  $item.spec.ownershipRecordPath=Join-Path $runtime "dispatch-launch-$($Result.launchId).json"
  # g2-r1:F2: a continuation retains the child its start acknowledgement names, and the
  # acknowledgement's routing provenance when it carries one, as dispatch-lane writes them.
  $found=@(Get-ChildItem -LiteralPath $runtime -Filter 'dispatch-start-*.json' -File|Where-Object{$value=Get-Content -LiteralPath $_.FullName -Raw|ConvertFrom-Json -DateKind String;$value.label-ceq$item.spec.label-and$value.launchId-ceq$item.spec.launchId})
  if($found.Count-ne1){throw "fixture start acknowledgement missing for $($item.spec.label)"}
  $ack=Get-Content -LiteralPath $found[0].FullName -Raw|ConvertFrom-Json -DateKind String
  $item.spec.childPid=[long]$ack.childPid;$item.spec.childStartIdentity=[string]$ack.childStartIdentity
  foreach($key in @('policyGeneration','registryAuthorityDigest','family','slot','usedLastKnownGood')){if($null-ne$ack.PSObject.Properties[$key]){$item.spec[$key]=$ack.$key}}
  Save-Spec $item;$item
}
function New-RelaunchedContinuation([string]$Label,[string]$Model,[string]$Effort,[int]$Row,[string]$Placement){
  $origin=New-Spec "$Label-origin" $Model $Effort 0 $Row $Placement
  $before=Get-CallCount;$result=Invoke-Watchdog $origin "$Label-origin"
  Assert-Recovery $origin $result $Model $Effort $Placement $before
  New-Continuation $origin $result $Model $Effort $Placement
}
# model-routing v4.24 / #9092. Every case enters through the public watchdog with the
# synthetic dispatch stub, in both quota and session envelopes, and prints CASE PASS or
# CASE FAIL, so each guard mutant is judged at its named case. -PolicyFallbackCase runs
# one case family (the id before '/'). Policy slots are set per case and restored.
function Test-PolicyFallback {
  $policyPath=Join-Path $env:CHASE_SETS_ROUTING_DATA_ROOT 'routing-policy.json'
  $policyBytes=[IO.File]::ReadAllBytes($policyPath)
  $failures=[Collections.Generic.List[string]]::new();$passes=[Collections.Generic.List[string]]::new()
  # Production generation-2 rows 1 and 2 (Opus stands in for the Haiku family the fixture lacks).
  $gen2=@{'1|claude.fallback'=[ordered]@{family='opus';effort='low';placement='provisional'};'1|codex.fallback'=[ordered]@{family='luna';effort='medium';placement='provisional'};'2|claude.fallback'=[ordered]@{family='opus';effort='medium';placement='override-Todd'}}
  # Row 3 Opus/high becomes a policy slot whose other-harness slot (Sol/medium) has a closed entry back to Opus.
  $chain=@{'3|claude.fallback'=[ordered]@{family='opus';effort='high';placement='override-Todd'}}
  # Protected rows given lower-tier policy slots that have no closed entry.
  $protected=@{}
  foreach($row in @(7,14,15)){$protected["$row|claude.primary"]=[ordered]@{family='opus';effort='medium';placement='provisional'};$protected["$row|codex.fallback"]=[ordered]@{family='sol';effort='medium';placement='provisional'}}
  function Set-PolicySlots([hashtable]$Slots){
    [IO.File]::WriteAllBytes($policyPath,$policyBytes)
    if($Slots.Count-eq0){return}
    $policy=[Text.Encoding]::UTF8.GetString($policyBytes)|ConvertFrom-Json -AsHashtable
    foreach($key in $Slots.Keys){$row,$slot=$key.Split('|');$policy.rows[$row].slots[$slot]=$Slots[$key]}
    [IO.File]::WriteAllText($policyPath,($policy|ConvertTo-Json -Depth 50),[Text.UTF8Encoding]::new($false))
  }
  function Invoke-PolicyCase([string]$CaseId,[hashtable]$CaseSlots,[scriptblock]$CaseBody){
    if($PolicyFallbackCase-and$CaseId.Split('/')[0]-cne$PolicyFallbackCase){return}
    try{Set-PolicySlots $CaseSlots;& $CaseBody|Out-Null;$passes.Add($CaseId);Write-Output "CASE PASS $CaseId"}
    catch{$failures.Add($CaseId);Write-Output "CASE FAIL $CaseId :: $($_.Exception.Message)"}
    finally{[IO.File]::WriteAllBytes($policyPath,$policyBytes)}
  }
  # A spec the watchdog already refuses (an implementation lane on review row 12) is also no move.
  function Assert-Blocked($Item,[string]$Why,[switch]$AllowSpecRefusal){
    $before=Get-CallCount;$result=$null;$refusal=''
    try{$result=Invoke-Watchdog $Item $Item.spec.label}catch{$refusal=$_.Exception.Message;if(-not$AllowSpecRefusal-or$refusal-cne'WATCHDOG_UNKNOWN_SPEC_INVALID'){throw}}
    Assert-True (($result.status-ceq'NO_QUALIFIED_FALLBACK'-and-not$result.relaunch-or$refusal-ceq'WATCHDOG_UNKNOWN_SPEC_INVALID')-and(Get-CallCount)-eq$before) "policy fallback must not move: $Why (status=$($result.status) refusal=$refusal)"
  }
  # An authentic closed-only lineage: a row-3 Sol/medium origin and its real same-config
  # relaunch. Unchanged, the continuation's quota/session death takes the closed Opus move.
  function New-ClosedLineage([string]$Name){
    $origin=New-Spec "$Name-origin" 'gpt-6.1-sol' medium 0 3 provisional
    $before=Get-CallCount;$first=Invoke-Watchdog $origin "$Name-origin"
    Assert-Recovery $origin $first 'gpt-6.1-sol' medium provisional $before
    $hop=New-Continuation $origin $first 'gpt-6.1-sol' medium provisional;Set-Content $hop.error $envelope
    [pscustomobject]@{origin=$origin;hop=$hop;originPath=(Join-Path $runtime "watchdog-lane-$($origin.spec.label).json")}
  }
  function Assert-ClosedMove($Item,[string]$Model='claude-opus-5-5',[string]$Placement='override-Todd'){
    $before=Get-CallCount;$result=Invoke-Watchdog $Item $Item.spec.label
    Assert-Recovery $Item $result $Model medium $Placement $before;$result
  }
  # Rewrites the origin envelope in place (its file name stays the original label's).
  function Edit-Origin($Lineage,[scriptblock]$Change){
    & $Change $Lineage.origin.spec
    [IO.File]::WriteAllText($Lineage.originPath,($Lineage.origin.spec|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
  }
  function Edit-RelaunchRow([string]$Lane,[scriptblock]$Change,[switch]$Duplicate){
    $lines=[Collections.Generic.List[string]]::new([string[]][IO.File]::ReadAllLines($history));$index=-1
    for($i=0;$i-lt$lines.Count;$i++){if($lines[$i].Contains("`"lane`":`"$Lane`"")-and$lines[$i].Contains('"watchdogSchema"')-and$lines[$i].Contains('"kind":"dispatch"')){$index=$i}}
    Assert-True ($index-ge0) "fixture relaunch row missing for $Lane"
    if($Duplicate){$lines.Insert($index+1,$lines[$index])}else{$row=$lines[$index]|ConvertFrom-Json -AsHashtable -DateKind String;& $Change $row;$lines[$index]=$row|ConvertTo-Json -Compress}
    [IO.File]::WriteAllText($history,($lines-join"`n")+"`n",[Text.UTF8Encoding]::new($false))
  }
  function Get-AckFile($Item){
    $found=@(Get-ChildItem -LiteralPath $runtime -Filter 'dispatch-start-*.json'|Where-Object{[IO.File]::ReadAllText($_.FullName).Contains($Item.spec.launchId)-and(Get-Content -LiteralPath $_.FullName -Raw|ConvertFrom-Json -DateKind String).label-ceq$Item.spec.label})
    Assert-True ($found.Count-eq1) "fixture start acknowledgement missing for $($Item.spec.label)";$found[0]
  }
  function Edit-Ack($Item,[scriptblock]$Change){
    $file=Get-AckFile $Item;$ack=Get-Content -LiteralPath $file.FullName -Raw|ConvertFrom-Json -AsHashtable -DateKind String
    & $Change $ack;[IO.File]::WriteAllText($file.FullName,($ack|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
  }
  # A closed lineage whose acknowledgements carry dispatch-lane's routing provenance.
  function New-ProvenanceLineage([string]$Name){
    $env:SYNTHETIC_WATCHDOG_EXPLICIT_ACK='1'
    try{New-ClosedLineage $Name}finally{Remove-Item Env:SYNTHETIC_WATCHDOG_EXPLICIT_ACK -ErrorAction SilentlyContinue}
  }
  # Sets the same provenance facts on the relaunch row, acknowledgement and continuation.
  function Set-LineageProvenance($Lineage,[hashtable]$Values){
    Edit-RelaunchRow $Lineage.hop.spec.label {param($r)foreach($k in $Values.Keys){$r[$k]=$Values[$k]}}
    Edit-Ack $Lineage.hop {param($a)foreach($k in $Values.Keys){$a[$k]=$Values[$k]}}
    foreach($k in $Values.Keys){$Lineage.hop.spec[$k]=$Values[$k]};Save-Spec $Lineage.hop
  }
  function New-Hex([string]$Prefix=''){$Prefix+(([guid]::NewGuid().ToString('N')+[guid]::NewGuid().ToString('N')).Substring(0,64-$Prefix.Length))}
  function Write-PolicyRecord([string]$FileId,[string]$Source,[string]$Target){
    $path=Join-Path $runtime "watchdog-policy-move-$FileId.json"
    $record=[ordered]@{schemaVersion='watchdog-policy-move/v1';attemptId='synthetic-semantic-attempt';sourceLaunchId=$Source;sourceLabel='synthetic-record-source';startRequest=(New-Hex);targetLabel=$Target;harness='codex';model='gpt-6.1-sol';effort='medium';row='3';placement='provisional'}
    [IO.File]::WriteAllText($path,($record|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false));$path
  }
  # A real first policy move: row-3 Opus/high moves to the codex.fallback Sol/medium slot.
  function New-PolicyMove([string]$Name){
    $origin=New-Spec $Name 'claude-opus-5-5' high 0 3 'override-Todd';Set-Content $origin.error $envelope
    $before=Get-CallCount;$moved=Invoke-Watchdog $origin $origin.spec.label
    Assert-Recovery $origin $moved 'gpt-6.1-sol' medium provisional $before
    $hop=New-Continuation $origin $moved 'gpt-6.1-sol' medium provisional;Set-Content $hop.error $envelope
    [pscustomobject]@{origin=$origin;moved=$moved;hop=$hop;record=(Join-Path $runtime "watchdog-policy-move-$($origin.spec.launchId).json")}
  }
  foreach($envelope in @('provider quota exceeded','session limit reached')){
    $tag=$envelope.Split(' ')[0]
    # AC1-AC3: the first policy move, both directions, with its bound reservation.
    foreach($case in @(
      @('ac1-row2',2,'gpt-6.1-sol','medium','provisional','claude-opus-5-5','medium','override-Todd'),
      @('ac2-row1-codex',1,'gpt-6-luna','low','provisional','claude-opus-5-5','low','provisional'),
      @('ac2-row1-claude',1,'claude-opus-5-5','low','provisional','gpt-6-luna','low','provisional'),
      @('ac3-row8',8,'claude-opus-5-5','high','provisional','gpt-6.1-sol','high','provisional'))){
      Invoke-PolicyCase "$($case[0])/$tag" $gen2 {
        $item=New-Spec "pf-$($case[0])-$tag" $case[2] $case[3] 0 $case[1] $case[4];Set-Content $item.error $envelope
        $before=Get-CallCount;$result=Invoke-Watchdog $item $item.spec.label
        Assert-Recovery $item $result $case[5] $case[6] $case[7] $before
        $row=Get-Content $history -Tail 1|ConvertFrom-Json -DateKind String
        $record=Get-Content (Join-Path $runtime "watchdog-policy-move-$($item.spec.launchId).json") -Raw|ConvertFrom-Json -DateKind String
        Assert-True ($record.schemaVersion-ceq'watchdog-policy-move/v1'-and$record.attemptId-ceq$item.spec.attemptId-and$record.sourceLaunchId-ceq$item.spec.launchId-and$record.sourceLabel-ceq$item.spec.label-and$record.startRequest-ceq$row.observationIdentity-and$record.targetLabel-ceq$result.label-and$record.harness-ceq(Get-Harness $case[5])-and$record.model-ceq$case[5]-and$record.effort-ceq$case[6]-and$record.row-ceq[string]$case[1]-and$record.placement-ceq$case[7]) 'policy move reservation is not bound to the attempt, source, request, target and configuration'
      }
    }
    Invoke-PolicyCase "ac4-precedence/$tag" $gen2 {
      $ruled=New-Spec "pf-ac4-$tag" 'gpt-6.1-sol' high 0 4 provisional;Set-Content $ruled.error $envelope
      $before=Get-CallCount;$result=Invoke-Watchdog $ruled $ruled.spec.label
      Assert-Recovery $ruled $result 'claude-opus-5-5' high 'override-Todd' $before
      Assert-True (-not(Test-Path (Join-Path $runtime "watchdog-policy-move-$($ruled.spec.launchId).json"))) 'a closed-table move wrote a policy reservation'
    }
    Invoke-PolicyCase "ac5-count1/$tag" $gen2 {
      $again=New-RelaunchedContinuation "pf-ac5-$tag" 'gpt-6.1-sol' medium 2 provisional;Set-Content $again.error $envelope
      Assert-Blocked $again 'relaunch 1 takes no policy move'
    }
    foreach($case in @(@('ac6-row9',9,'gpt-6.1-sol','high','provisional'),@('ac6-row11',11,'gpt-6.1-sol','high','provisional'),@('ac6-row12',12,'claude-opus-5-5','medium','override-Todd'))){
      Invoke-PolicyCase "$($case[0])/$tag" $gen2 {
        $excluded=New-Spec "pf-$($case[0])-$tag" $case[2] $case[3] 0 $case[1] $case[4];Set-Content $excluded.error $envelope
        Assert-Blocked $excluded "row $($case[1]) is excluded" -AllowSpecRefusal:($case[1]-eq12)
      }
    }
    Invoke-PolicyCase "ac7-off-slot/$tag" @{} {
      $offSlot=New-Spec "pf-ac7-$tag" 'claude-opus-5-5' high 0 3 'override-Todd';Set-Content $offSlot.error $envelope
      Assert-Blocked $offSlot 'route is not its row''s policy slot'
    }
    Invoke-PolicyCase "ac8-unadmitted/$tag" @{'2|claude.fallback'=[ordered]@{family='opus';effort='max';placement='override-Todd'}} {
      $registry=Set-ProductionShapedRoutingRegistry -Path (Join-Path $env:CHASE_SETS_ROUTING_DATA_ROOT 'model-registry.json')
      try{
        $unadmitted=New-Spec "pf-ac8-$tag" 'gpt-6.1-sol' medium 0 2 provisional;Set-Content $unadmitted.error $envelope
        Assert-Blocked $unadmitted 'target effort is not admitted'
      }finally{Restore-RoutingRegistryBytes $registry}
    }
    Invoke-PolicyCase "ac9-absent-slot/$tag" @{} {
      $absent=New-Spec "pf-ac9-$tag" 'gpt-6.1-sol' medium 0 2 provisional;Set-Content $absent.error $envelope
      Assert-Blocked $absent 'row has no other-harness slot'
    }
    # r1:F1: protected rows 7/14/15 move only on a closed entry.
    foreach($row in @(7,14,15)){
      Invoke-PolicyCase "f1-protected-$row/$tag" $protected {
        $item=New-Spec "pf-f1-$row-$tag" 'gpt-6.1-sol' medium 0 $row provisional;Set-Content $item.error $envelope
        Assert-Blocked $item "protected row $row has no closed entry"
      }
    }
    # r1:F2: one policy move per lineage. The policy target's closed entry would cross back.
    Invoke-PolicyCase "r1f2-policy-to-closed/$tag" $chain {
      $move=New-PolicyMove "pf-r1f2-$tag"
      Assert-Blocked $move.hop 'an authenticated continuation of a consumed policy move takes a closed cross-harness move'
    }
    Invoke-PolicyCase "r1f2-two-hop/$tag" $chain {
      $move=New-PolicyMove "pf-r1f2-hop-$tag";Set-Content $move.hop.error 'native owner ended'
      $before=Get-CallCount;$same=Invoke-Watchdog $move.hop "$($move.hop.spec.label)-owner"
      Assert-Recovery $move.hop $same 'gpt-6.1-sol' medium provisional $before
      $third=New-Continuation $move.hop $same 'gpt-6.1-sol' medium provisional;Set-Content $third.error $envelope
      Assert-Blocked $third 'a consumed policy move two authenticated links back'
    }
    # r2:F2: missing, unlinked, forged, deleted and incomplete lineage evidence.
    Invoke-PolicyCase "r2f2-unlinked-1/$tag" @{} {
      $item=New-Spec "pf-r2-unlinked1-$tag" 'gpt-6.1-sol' medium 1 3 provisional;Set-Content $item.error $envelope
      Assert-Blocked $item 'a count-1 continuation with no link'
    }
    Invoke-PolicyCase "r2f2-unlinked-2/$tag" @{} {
      $item=New-Spec "pf-r2-unlinked2-$tag" 'claude-opus-5-5' medium 2 3 'override-Todd';Set-Content $item.error $envelope
      Assert-Blocked $item 'a count-2 continuation with no link'
    }
    Invoke-PolicyCase "r2f2-missing-origin/$tag" @{} {
      $item=New-Spec "pf-r2-missing-$tag" 'gpt-6.1-sol' medium 1 3 provisional;$item.spec.resumeOfLaunchId=[guid]::NewGuid().ToString();Save-Spec $item;Set-Content $item.error $envelope
      Assert-Blocked $item 'a count-1 continuation whose origin is missing'
    }
    Invoke-PolicyCase "r2f2-forged/$tag" @{} {
      $plain=New-Spec "pf-r2-plain-$tag" 'gpt-6.1-sol' medium 0 3 provisional
      $forged=New-Spec "pf-r2-forged-$tag" 'claude-opus-5-5' medium 1 3 'override-Todd';$forged.spec.resumeOfLaunchId=$plain.spec.launchId;Save-Spec $forged;Set-Content $forged.error $envelope
      Assert-Blocked $forged 'a continuation naming a valid origin without its relaunch row and start acknowledgement'
    }
    Invoke-PolicyCase "r2f2-deleted-origin/$tag" @{} {
      $lineage=New-ClosedLineage "pf-r2-deleted-$tag";Remove-Item -LiteralPath $lineage.originPath
      Assert-Blocked $lineage.hop 'a continuation whose origin envelope is deleted'
    }
    Invoke-PolicyCase "r2f2-four-field/$tag" @{} {
      $lineage=New-ClosedLineage "pf-r2-fourfield-$tag";Set-Content $lineage.hop.error 'native owner ended'
      $before=Get-CallCount;$same=Invoke-Watchdog $lineage.hop "$($lineage.hop.spec.label)-owner"
      Assert-Recovery $lineage.hop $same 'gpt-6.1-sol' medium provisional $before
      $last=New-Continuation $lineage.hop $same 'gpt-6.1-sol' medium provisional;Set-Content $last.error $envelope
      [IO.File]::WriteAllText((Join-Path $runtime "watchdog-lane-$($lineage.hop.spec.label).json"),([ordered]@{launchId=$lineage.hop.spec.launchId;attemptId=$lineage.hop.spec.attemptId;relaunchCount=1;label=$lineage.hop.spec.label}|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
      Assert-Blocked $last 'a count-2 continuation whose count-1 predecessor is a four-field record'
    }
    # r3:F2 envelope: each predecessor invariant refuses on its own.
    foreach($case in @(
      @('r3-envelope-state',{param($s)$s.state='SYNTHETIC_INVALID_STATE'}),
      @('r3-envelope-pid',{param($s)$s.launcherPid=[long]-1}),
      @('r3-envelope-instant',{param($s)$s.launcherStartIdentity='2000-01-01'}),
      @('r3-envelope-extra-key',{param($s)$s['synthetic']='unexpected'}),
      @('r3-envelope-exit-type',{param($s)$s.exitCode='1'}),
      @('r3-envelope-child-null',{param($s)$s.childPid=$null}),
      @('r3-envelope-head',{param($s)$s.head='SYNTHETIC-NOT-A-SHA'}),
      @('r3-envelope-placement',{param($s)$s.placement='synthetic-placement'}),
      @('r3-envelope-provenance',{param($s)$s['family']='sol'}),
      @('r3-envelope-attempt',{param($s)$s.attemptId='synthetic-other-attempt'}),
      @('r3-envelope-count',{param($s)$s.relaunchCount=[long]1;$s.resumeOfLaunchId=[guid]::NewGuid().ToString()}),
      @('r3-envelope-label',{param($s)$s.label='synthetic-renamed-origin'}))){
      Invoke-PolicyCase "$($case[0])/$tag" @{} {
        $lineage=New-ClosedLineage "pf-$($case[0])-$tag";Edit-Origin $lineage $case[1]
        Assert-Blocked $lineage.hop "$($case[0]) predecessor"
      }
    }
    # r3:F2 history: the continuation's relaunch row is closed and unique.
    foreach($case in @(
      @('r3-history-death',{param($r)$r.Remove('deathSignature')}),
      @('r3-history-extra',{param($r)$r['synthetic']='unexpected'}),
      @('r3-history-type',{param($r)$r['relaunchCount']='1'}),
      @('r3-history-provenance-partial',{param($r)foreach($k in @('policyGeneration','registryAuthorityDigest','slot','usedLastKnownGood')){$r.Remove($k)};$r['family']='sol'}),
      @('r3-history-provenance-invalid',{param($r)$r['policyGeneration']=[long]1;$r['registryAuthorityDigest']='synthetic';$r['family']='sol';$r['slot']='synthetic-invalid-slot';$r['usedLastKnownGood']=$false}),
      # Only the row's own provenance shape check rejects this group: its slot and family agree with the continuation.
      @('r3-history-provenance-shape',{param($r)$r['policyGeneration']=[long]1;$r['registryAuthorityDigest']='synthetic digest with spaces';$r['family']='sol';$r['slot']='explicit';$r['usedLastKnownGood']=$false}),
      @('r3-history-outcome',{param($r)$r['outcome']='SYNTHETIC_OUTCOME'}),
      @('r3-history-observed-at',{param($r)$r['observedAt']='2000-01-01'}))){
      Invoke-PolicyCase "$($case[0])/$tag" @{} {
        $lineage=New-ClosedLineage "pf-$($case[0])-$tag";Edit-RelaunchRow $lineage.hop.spec.label $case[1]
        Assert-Blocked $lineage.hop "$($case[0]) relaunch row"
      }
    }
    Invoke-PolicyCase "r3-history-replayed/$tag" @{} {
      $lineage=New-ClosedLineage "pf-r3-replayed-$tag";Edit-RelaunchRow $lineage.hop.spec.label {} -Duplicate
      Assert-Blocked $lineage.hop 'a replayed relaunch row'
    }
    # r3:F2 source and request: the row and acknowledgement bind the predecessor's partial and request.
    Invoke-PolicyCase "r3-source-resumed-partial/$tag" @{} {
      $lineage=New-ClosedLineage "pf-r3-resumed-$tag";Edit-RelaunchRow $lineage.hop.spec.label {param($r)$r['resumedPartial']=Join-Path $runtime 'SYNTHETIC_UNRELATED_PARTIAL.jsonl'}
      Assert-Blocked $lineage.hop 'a relaunch row naming an unrelated partial'
    }
    Invoke-PolicyCase "r3-source-missing/$tag" @{} {
      $lineage=New-ClosedLineage "pf-r3-source-$tag";Remove-Item -LiteralPath $lineage.origin.partial
      Assert-Blocked $lineage.hop 'a predecessor whose source partial is missing'
    }
    Invoke-PolicyCase "r3-request-row/$tag" @{} {
      $lineage=New-ClosedLineage "pf-r3-reqrow-$tag";Edit-RelaunchRow $lineage.hop.spec.label {param($r)$r['observationIdentity']=(New-Hex)}
      Assert-Blocked $lineage.hop 'a relaunch row whose observation identity is not the recomputed request'
    }
    Invoke-PolicyCase "r3-request-ack/$tag" @{} {
      $lineage=New-ClosedLineage "pf-r3-reqack-$tag";$file=Get-AckFile $lineage.hop
      $ack=Get-Content -LiteralPath $file.FullName -Raw|ConvertFrom-Json -DateKind String;$ack.requestIdentity=(New-Hex)
      [IO.File]::WriteAllText((Join-Path $runtime "dispatch-start-$($ack.requestIdentity).json"),($ack|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false));Remove-Item -LiteralPath $file.FullName
      Assert-Blocked $lineage.hop 'a start acknowledgement for a different request'
    }
    Invoke-PolicyCase "r3-ack-duplicate/$tag" @{} {
      $lineage=New-ClosedLineage "pf-r3-ackdup-$tag";$file=Get-AckFile $lineage.hop
      $ack=Get-Content -LiteralPath $file.FullName -Raw|ConvertFrom-Json -DateKind String;$ack.requestIdentity=(New-Hex 'ffff')
      [IO.File]::WriteAllText((Join-Path $runtime "dispatch-start-$($ack.requestIdentity).json"),($ack|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
      Assert-Blocked $lineage.hop 'a second start acknowledgement for the same continuation'
    }
    Invoke-PolicyCase "r3-ack-missing/$tag" @{} {
      $lineage=New-ClosedLineage "pf-r3-ackmissing-$tag";Remove-Item -LiteralPath (Get-AckFile $lineage.hop).FullName
      Assert-Blocked $lineage.hop 'a continuation without its start acknowledgement'
    }
    # r3:F2 record scan: each check refuses on its own, independent of the file name.
    Invoke-PolicyCase "r3-scan-renamed/$tag" $chain {
      $move=New-PolicyMove "pf-r3-renamed-$tag";$renamed=Join-Path $runtime "watchdog-policy-move-$([guid]::NewGuid()).json";[IO.File]::Move($move.record,$renamed)
      try{Assert-Blocked $move.hop 'a renamed valid policy record'}finally{Remove-Item -LiteralPath $renamed}
    }
    Invoke-PolicyCase "r3-scan-target/$tag" @{} {
      $lineage=New-ClosedLineage "pf-r3-target-$tag";$source=[guid]::NewGuid().ToString();$record=Write-PolicyRecord $source $source $lineage.hop.spec.label
      try{Assert-Blocked $lineage.hop 'a record naming the continuation as target with a conflicting source'}finally{Remove-Item -LiteralPath $record}
    }
    Invoke-PolicyCase "r3-scan-source/$tag" @{} {
      $lineage=New-ClosedLineage "pf-r3-source-record-$tag";$record=Write-PolicyRecord $lineage.origin.spec.launchId $lineage.origin.spec.launchId "synthetic-unrelated-target-$tag"
      try{Assert-Blocked $lineage.hop 'a record whose source is a predecessor launch'}finally{Remove-Item -LiteralPath $record}
    }
    Invoke-PolicyCase "r3-scan-filename/$tag" @{} {
      $lineage=New-ClosedLineage "pf-r3-filename-$tag";$record=Write-PolicyRecord ([guid]::NewGuid().ToString()) ([guid]::NewGuid().ToString()) "synthetic-unrelated-target-$tag"
      try{Assert-Blocked $lineage.hop 'a record stored under another launch''s name'}finally{Remove-Item -LiteralPath $record}
    }
    Invoke-PolicyCase "r3-scan-malformed/$tag" @{} {
      $lineage=New-ClosedLineage "pf-r3-malformed-$tag";$record=Join-Path $runtime "watchdog-policy-move-$([guid]::NewGuid()).json";Set-Content -LiteralPath $record -Value 'synthetic malformed record'
      try{Assert-Blocked $lineage.hop 'an unreadable policy record'}finally{Remove-Item -LiteralPath $record}
    }
    # g2-r1:F1: schema-owned strings are scalar strings; a singleton array, null or object
    # never stands in for one, on a predecessor or on the current spec.
    foreach($case in @(
      @('g2f1-origin-model-array',{param($s)$s.model=@('gpt-6.1-sol')}),
      @('g2f1-origin-schema-array',{param($s)$s.schemaVersion=@('watchdog-lane/v2')}),
      @('g2f1-origin-harness-array',{param($s)$s.harness=@('codex')}),
      @('g2f1-origin-effort-array',{param($s)$s.effort=@('medium')}),
      @('g2f1-origin-state-array',{param($s)$s.state=@('exited')}),
      @('g2f1-origin-role-array',{param($s)$s.laneRole=@('implementation')}),
      @('g2f1-origin-placement-array',{param($s)$s.placement=@('provisional')}),
      @('g2f1-origin-branch-array',{param($s)$s.branch=@('synthetic/branch')}),
      @('g2f1-origin-model-null',{param($s)$s.model=$null}),
      @('g2f1-origin-effort-object',{param($s)$s.effort=[ordered]@{value='medium'}}))){
      Invoke-PolicyCase "$($case[0])/$tag" @{} {
        $lineage=New-ClosedLineage "pf-$($case[0])-$tag";Edit-Origin $lineage $case[1]
        Assert-Blocked $lineage.hop "$($case[0]) predecessor"
      }
    }
    foreach($case in @(
      @('g2f1-current-model-array',{param($s)$s.model=@('gpt-6.1-sol')}),
      @('g2f1-current-effort-array',{param($s)$s.effort=@('medium')}),
      @('g2f1-current-placement-object',{param($s)$s.placement=[ordered]@{value='provisional'}}))){
      Invoke-PolicyCase "$($case[0])/$tag" $gen2 {
        $item=New-Spec "pf-$($case[0])-$tag" 'gpt-6.1-sol' medium 0 2 provisional;& $case[1] $item.spec;Save-Spec $item;Set-Content $item.error $envelope
        Assert-Blocked $item "$($case[0]) current spec" -AllowSpecRefusal
      }
    }
    # g2-r1:F2: the acknowledged child is the continuation's retained child.
    foreach($case in @(
      @('g2f2-ack-child-pid',{param($a)$a.childPid=[long]123456789}),
      @('g2f2-ack-child-start',{param($a)$a.childStartIdentity='2001-01-01T00:00:00.0000000Z'}))){
      Invoke-PolicyCase "$($case[0])/$tag" @{} {
        $lineage=New-ClosedLineage "pf-$($case[0])-$tag";Edit-Ack $lineage.hop $case[1]
        Assert-Blocked $lineage.hop "$($case[0]) acknowledgement"
      }
    }
    Invoke-PolicyCase "g2f2-spec-child/$tag" @{} {
      $lineage=New-ClosedLineage "pf-g2f2-spec-child-$tag";$lineage.hop.spec.childStartIdentity='2001-01-01T00:00:00.0000000Z';Save-Spec $lineage.hop
      Assert-Blocked $lineage.hop 'a continuation whose retained child is not its acknowledged child'
    }
    # g2-r1:F2: present provenance groups are one selection naming the continuation's
    # model family, provider and harness slot.
    Invoke-PolicyCase "g2f2-row-provenance/$tag" @{} {
      $lineage=New-ProvenanceLineage "pf-g2f2-row-prov-$tag";Edit-RelaunchRow $lineage.hop.spec.label {param($r)$r['registryAuthorityDigest']='synthetic-conflicting-digest'}
      Assert-Blocked $lineage.hop 'a relaunch row whose provenance conflicts with its acknowledgement and continuation'
    }
    Invoke-PolicyCase "g2f2-ack-provenance/$tag" @{} {
      $lineage=New-ProvenanceLineage "pf-g2f2-ack-prov-$tag";Edit-Ack $lineage.hop {param($a)$a.policyGeneration=[long]999}
      Assert-Blocked $lineage.hop 'an acknowledgement whose provenance conflicts with its row and continuation'
    }
    Invoke-PolicyCase "g2f2-family-unbound/$tag" @{} {
      $lineage=New-ProvenanceLineage "pf-g2f2-family-$tag";Set-LineageProvenance $lineage @{family='opus'}
      Assert-Blocked $lineage.hop 'consistent provenance naming another family than the continuation model'
    }
    Invoke-PolicyCase "g2f2-slot-harness/$tag" @{} {
      $lineage=New-ProvenanceLineage "pf-g2f2-slot-$tag";Set-LineageProvenance $lineage @{slot='claude.primary'}
      Assert-Blocked $lineage.hop 'consistent provenance naming another harness slot than the continuation'
    }
    Invoke-PolicyCase "pos-coherent-provenance/$tag" @{} {
      $lineage=New-ProvenanceLineage "pf-pos-coherent-$tag"
      Assert-True ($null-ne$lineage.hop.spec['family']-and[string]$lineage.hop.spec['slot']-ceq'explicit') 'coherent fixture lost its acknowledged provenance'
      Assert-ClosedMove $lineage.hop
    }
    # Positive controls: authentic closed-only, Fable, retained and legacy lineages keep their moves.
    Invoke-PolicyCase "pos-closed-chain/$tag" @{} {
      $origin=New-Spec "pf-pos-chain-$tag" 'gpt-6.1-sol' medium 0 3 provisional;Set-Content $origin.error $envelope
      $first=Assert-ClosedMove $origin
      $hop1=New-Continuation $origin $first 'claude-opus-5-5' medium 'override-Todd';Set-Content $hop1.error $envelope
      $second=Assert-ClosedMove $hop1 'gpt-6.1-sol'
      $hop2=New-Continuation $hop1 $second 'gpt-6.1-sol' medium 'override-Todd';Set-Content $hop2.error $envelope
      $third=Assert-ClosedMove $hop2
      $hop3=New-Continuation $hop2 $third 'claude-opus-5-5' medium 'override-Todd';Set-Content $hop3.error $envelope
      $before=Get-CallCount;$ceiling=Invoke-Watchdog $hop3 $hop3.spec.label
      Assert-True ($ceiling.status-ceq'HARNESS_CEILING'-and-not$ceiling.relaunch-and(Get-CallCount)-eq$before) 'an authentic count-3 continuation did not stop at the harness ceiling'
    }
    Invoke-PolicyCase "pos-closed-count1/$tag" @{} {
      $lineage=New-ClosedLineage "pf-pos-count1-$tag";Assert-ClosedMove $lineage.hop
    }
    Invoke-PolicyCase "pos-fable/$tag" @{} {
      $fable=New-RelaunchedContinuation "pf-pos-fable-$tag" 'claude-fable-5-1' high 7 'override-Todd';Set-Content $fable.error $envelope
      $before=Get-CallCount;$result=Invoke-Watchdog $fable $fable.spec.label
      Assert-Recovery $fable $result 'gpt-6-astra' high 'override-Todd' $before
    }
    Invoke-PolicyCase "pos-provenance/$tag" @{} {
      . (Join-Path $PSScriptRoot 'routing-data.ps1') -Library
      $selection=Resolve-RoutingSelection -Row 3 -Harness codex -Model gpt-6.1-sol -Effort medium -ReadOnly
      $origin=New-Spec "pf-pos-provenance-$tag-origin" 'gpt-6.1-sol' medium 0 3 provisional
      $origin.spec.policyGeneration=[long]$selection.policyGeneration;$origin.spec.registryAuthorityDigest=[string]$selection.registryAuthorityDigest;$origin.spec.family=[string]$selection.family;$origin.spec.slot=[string]$selection.slot;$origin.spec.usedLastKnownGood=[bool]$selection.usedLastKnownGood;Save-Spec $origin
      $before=Get-CallCount;$first=Invoke-Watchdog $origin $origin.spec.label
      Assert-Recovery $origin $first 'gpt-6.1-sol' medium provisional $before
      $hop=New-Continuation $origin $first 'gpt-6.1-sol' medium provisional;Set-Content $hop.error $envelope
      Assert-ClosedMove $hop
    }
    Invoke-PolicyCase "pos-legacy-origin/$tag" @{} {
      $legacy=New-LegacySpec "pf-pos-legacy-$tag";Add-LegacyRoutingRow $legacy 4 provisional
      $before=Get-CallCount;$first=Invoke-Watchdog $legacy $legacy.spec.label
      Assert-True ($first.status-ceq'RELAUNCHED'-and$first.model-ceq'gpt-6.1-sol'-and(Get-CallCount)-eq$before+1) 'legacy v1 origin did not relaunch same-config'
      # The v1 origin's row and placement come only from its authenticated legacy routing row.
      $legacyView=[pscustomobject]@{spec=[ordered]@{relaunchCount=[long]0;row=[long]4;attemptId=$legacy.spec.attemptId;launchId=$legacy.spec.launchId}}
      $hop=New-Continuation $legacyView $first 'gpt-6.1-sol' high provisional;Set-Content $hop.error $envelope
      $before=Get-CallCount;$result=Invoke-Watchdog $hop $hop.spec.label
      Assert-Recovery $hop $result 'claude-opus-5-5' high 'override-Todd' $before
    }
    Invoke-PolicyCase "pos-unrelated-record/$tag" @{} {
      $lineage=New-ClosedLineage "pf-pos-unrelated-$tag";$source=[guid]::NewGuid().ToString();$record=Write-PolicyRecord $source $source "synthetic-unrelated-target-$tag"
      try{Assert-ClosedMove $lineage.hop}finally{Remove-Item -LiteralPath $record}
    }
    # Reservation lifecycle: a launch failure before receipt retries the exact request and
    # target; a replay is a duplicate; a conflicting reservation refuses.
    Invoke-PolicyCase "pos-retry/$tag" $gen2 {
      $item=New-Spec "pf-pos-retry-$tag" 'gpt-6.1-sol' medium 0 2 provisional;Set-Content $item.error $envelope
      $recordPath=Join-Path $runtime "watchdog-policy-move-$($item.spec.launchId).json"
      $env:SYNTHETIC_WATCHDOG_FAIL_LABEL=$item.spec.label
      try{$before=Get-CallCount;$failed=Invoke-Watchdog $item $item.spec.label}finally{Remove-Item Env:SYNTHETIC_WATCHDOG_FAIL_LABEL}
      Assert-True ($failed.status-ceq'LAUNCH_FAILED'-and-not$failed.relaunch-and(Get-CallCount)-eq$before+1-and(Test-Path $recordPath)) 'a failed policy launch did not keep its reservation'
      $reserved=[IO.File]::ReadAllBytes($recordPath);$target=(Get-Content $recordPath -Raw|ConvertFrom-Json -DateKind String).targetLabel
      $before=Get-CallCount;$result=Invoke-Watchdog $item $item.spec.label
      Assert-Recovery $item $result 'claude-opus-5-5' medium 'override-Todd' $before
      Assert-True ($result.label-ceq$target-and[Convert]::ToBase64String([IO.File]::ReadAllBytes($recordPath))-ceq[Convert]::ToBase64String($reserved)) 'the retry did not reuse the exact reserved target'
    }
    Invoke-PolicyCase "pos-replay/$tag" $gen2 {
      $item=New-Spec "pf-pos-replay-$tag" 'gpt-6.1-sol' medium 0 2 provisional;Set-Content $item.error $envelope
      $before=Get-CallCount;$result=Invoke-Watchdog $item $item.spec.label
      Assert-Recovery $item $result 'claude-opus-5-5' medium 'override-Todd' $before
      $before=Get-CallCount;$replay=Invoke-Watchdog $item $item.spec.label
      Assert-True ($replay.status-ceq'DUPLICATE_SKIPPED'-and(Get-CallCount)-eq$before) 'a replayed policy move launched again'
    }
    Invoke-PolicyCase "pos-reserve-conflict/$tag" $gen2 {
      $item=New-Spec "pf-pos-conflict-$tag" 'gpt-6.1-sol' medium 0 2 provisional;Set-Content $item.error $envelope
      $record=Write-PolicyRecord $item.spec.launchId $item.spec.launchId "synthetic-conflict-target-$tag";$bytes=[IO.File]::ReadAllBytes($record)
      Assert-Blocked $item 'a reservation for another request'
      Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($record))-ceq[Convert]::ToBase64String($bytes)) 'a conflicting reservation was overwritten'
    }
  }
  if($failures.Count-gt0){throw "ASSERTION FAILED: 9092 policy fallback cases failed: $($failures-join', ')"}
  if($PolicyFallbackCase){Write-Output "PASS 9092 policy fallback case family $PolicyFallbackCase cases=$($passes.Count)";return}
  Write-Output 'PASS policy fallback v4.24: rows 1/2/8 move once to the other-harness slot in both directions and envelopes with a bound reservation; closed table precedence; relaunch 1, rows 9/11/12, off-slot route, unadmitted target and absent slot stay blocked'
  Write-Output 'PASS 9092 protected rows 7/14/15 and one policy move per lineage: protected policy-only gaps, one- and two-link consumed chains, unlinked, missing, forged, deleted and four-field lineage evidence stay blocked'
  Write-Output "PASS 9092 lineage authentication: predecessor envelope with scalar types, closed relaunch row, source/request binding, unique acknowledgement joined to the retained child and provenance, and record-scan refusals; closed-only count 1/2/3, Fable, retained-provenance and legacy lineages, retry, replay and conflict controls cases=$($passes.Count)"
}
# #9092 guard discriminators: each mutant removes one guard, and its named
# -PolicyFallbackOnly case family must turn red at that case (CASE FAIL <case>/...)
# in a fresh child run.
function Test-PolicyFallbackMutants {
  $source=[IO.File]::ReadAllText($watchdog)
  $mutantRoot=Join-Path $root 'mutants-9092';New-Item -ItemType Directory -Force -Path $mutantRoot|Out-Null
  Get-ChildItem $PSScriptRoot -File|Where-Object Extension -in @('.ps1','.psm1')|Copy-Item -Destination $mutantRoot
  New-Item -ItemType Directory -Force -Path (Join-Path $mutantRoot 'controller-skills/model-routing')|Out-Null
  Copy-Item (Join-Path $PSScriptRoot 'controller-skills/model-routing/capability-matrix.json') (Join-Path $mutantRoot 'controller-skills/model-routing/capability-matrix.json')
  $mutants=@(
    # AC11's six guards.
    @{name='no-policy-fallback';case='ac1-row2';old='    if($null-ne$policyFallback){';new='    if($false){'},
    @{name='second-move-allowed';case='ac5-count1';old='  if([long]$Spec.relaunchCount-ne0){return $null}';new=''},
    @{name='excluded-rows-allowed';case='ac6-row9';old='-or$row-in@(7,9,11,12,14,15)';new=''},
    @{name='policy-overrides-closed-table';case='ac4-precedence';old='  if(-not$consumed-and-not$fallback.ContainsKey($routeKey)){';new='  if(-not$consumed){'},
    @{name='admission-ignored';case='ac8-unadmitted';old='    if($null-eq$model-or(Get-RoutingAdmissionReason $Data.registry $model ([string]$slot[0].Value.effort))){continue}';new='    if($null-eq$model){continue}'},
    @{name='own-slot-ignored';case='ac7-off-slot';old='  if($own.Count-eq0){return $null}';new=''},
    # r1/r2 lineage guards.
    @{name='protected-rows-14-15-allowed';case='f1-protected-14';old='@(7,9,11,12,14,15)';new='@(7,9,11,12)'},
    @{name='consumed-policy-move-ignored';case='r1f2-policy-to-closed';old='-and(Test-WatchdogPolicyMoveConsumed $runtimeFull $spec)';new='-and$false'},
    @{name='missing-lineage-allowed';case='r2f2-unlinked-1';old='    if($hop-ge3-or$link-cnotmatch''^[a-f0-9-]{36}$''-or$launches.Contains($link)){return $true}';new='    if($link-cnotmatch''^[a-f0-9-]{36}$''){break};if($hop-ge3-or$launches.Contains($link)){return $true}'},
    @{name='missing-predecessor-allowed';case='r2f2-missing-origin';old='    if($null-eq$predecessor){return $true}';new='    if($null-eq$predecessor){break}'},
    @{name='unbound-continuation-allowed';case='r2f2-forged';old='if(-not(Test-WatchdogContinuationBinding $Root $current';new='if($false-and(Test-WatchdogContinuationBinding $Root $current'},
    @{name='incomplete-predecessor-allowed';case='r3-envelope-state';old='if(-not(Test-WatchdogLineageEnvelope $Root';new='if($false-and(Test-WatchdogLineageEnvelope $Root'},
    @{name='predecessor-record-ignored';case='r3-scan-source';old='    if($launches.Contains([string]$record.sourceLaunchId)){return $true}';new=''},
    # r3:F2 predecessor envelope facts.
    @{name='envelope-state-unchecked';case='r3-envelope-state';old='$Value.state-cnotin@(''launching'',''running'',''exited'')-or';new=''},
    @{name='envelope-pid-unchecked';case='r3-envelope-pid';old='-or$Value.launcherPid-lt1';new=''},
    @{name='envelope-instant-unchecked';case='r3-envelope-instant';old='  foreach($instant in @($view.launcherStartIdentity,$view.updatedAt)){if(-not(Test-WatchdogZonedInstant $instant)){return $false}}';new=''},
    # r3:F2 closed relaunch row.
    @{name='history-keys-unchecked';case='r3-history-extra';old='  if(-not(Test-ExactKeys $row $expected)){return $false}';new=''},
    @{name='history-types-unchecked';case='r3-history-type';old='  if(@($script:RelaunchRowKeys|Where-Object{$_-cne''relaunchCount''-and$row.$_-isnot[string]}).Count-gt0-or$row.relaunchCount-isnot[long]){return $false}';new=''},
    @{name='history-provenance-unchecked';case='r3-history-provenance-shape';old='  if(-not(Test-WatchdogRoutingProvenance $row)){return $false}';new=''},
    @{name='history-uniqueness-unchecked';case='r3-history-replayed';old='  if($rows.Count-ne1){return $false}';new='  if($rows.Count-lt1){return $false}'},
    # r3:F2 source and request bindings.
    @{name='resumed-partial-unbound';case='r3-source-resumed-partial';old='  if(-not(Test-DispatchSamePath $row.resumedPartial ([string]$Predecessor.partialReportPath))){return $false}';new=''},
    @{name='source-partial-unchecked';case='r3-source-missing';old='  if(-not(Test-Path -LiteralPath ([string]$Predecessor.partialReportPath) -PathType Leaf)){return $false}';new=''},
    @{name='row-identity-unbound';case='r3-request-row';old='  if($row.observationIdentity-cne$identity){return $false}';new=''},
    @{name='ack-request-unbound';case='r3-request-ack';old='-and$request-cne$identity){return $false}';new='-and$false){return $false}'},
    @{name='ack-uniqueness-unchecked';case='r3-ack-duplicate';old='  if($acks.Count-ne1){return $false}';new='  if($acks.Count-lt1){return $false}'},
    # r3:F2 record scan; each check is independent of the file-name lookup.
    @{name='record-filename-unchecked';case='r3-scan-filename';old='    if($file.Name-cne"watchdog-policy-move-$($record.sourceLaunchId).json"){return $true}';new=''},
    @{name='record-target-unchecked';case='r3-scan-target';old='    if($labels.Contains([string]$record.targetLabel)){return $true}';new=''},
    @{name='record-malformed-ignored';case='r3-scan-malformed';old='    try{$record=Read-WatchdogPolicyMove $file.FullName}catch{return $true}';new='    try{$record=Read-WatchdogPolicyMove $file.FullName}catch{continue}'},
    # g2-r1:F1 scalar types and F2 continuation joins; each guard alone.
    @{name='predecessor-scalar-unchecked';case='g2f1-origin-model-array';old='  if(-not(Test-WatchdogScalarFields $Value)){return $false}';new=''},
    @{name='current-scalar-unchecked';case='g2f1-current-model-array';old='if(-not(Test-WatchdogScalarFields $spec)){throw ''WATCHDOG_UNKNOWN_SPEC_INVALID''}';new=''},
    @{name='ack-child-unbound';case='g2f2-ack-child-pid';old='  if($Continuation.childPid-isnot[long]-or[long]$ack.childPid-ne[long]$Continuation.childPid-or[string]$ack.childStartIdentity-cne[string]$Continuation.childStartIdentity){return $false}';new=''},
    @{name='provenance-join-unchecked';case='g2f2-row-provenance';old='-or[bool]$group.usedLastKnownGood-ne[bool]$selected.usedLastKnownGood){return $false}';new='-and$false){return $false}'},
    @{name='provenance-family-unbound';case='g2f2-family-unbound';old='-or[string]$modelIdentity.family-cne[string]$selected.family';new=''},
    @{name='provenance-slot-unbound';case='g2f2-slot-harness';old='  if([string]$selected.slot-cne''explicit''-and([string]$selected.slot).Split(''.'')[0]-cne[string]$Continuation.harness){return $false}';new=''}
  )
  foreach($m in $mutants){
    Assert-True (([regex]::Matches($source,[regex]::Escape($m.old))).Count-eq1) "9092 mutation anchor not unique: $($m.name)"
    $mutantPath=Join-Path $mutantRoot "9092-$($m.name).ps1";[IO.File]::WriteAllText($mutantPath,$source.Replace($m.old,$m.new),[Text.UTF8Encoding]::new($false))
    $parseErrors=$null;[void][Management.Automation.Language.Parser]::ParseFile($mutantPath,[ref]$null,[ref]$parseErrors);Assert-True ($parseErrors.Count-eq0) "9092 mutant does not parse: $($m.name)"
    $mutantOut=& (Get-Command pwsh).Source -NoProfile -NonInteractive -File (Join-Path $mutantRoot 'lane-stall-watchdog.test.ps1') -PolicyFallbackOnly -PolicyFallbackCase $m.case -WatchdogScript $mutantPath 2>&1|Out-String;$mutantExit=$LASTEXITCODE
    [IO.File]::WriteAllText((Join-Path $mutantRoot "9092-$($m.name).log"),"exit=$mutantExit`n$mutantOut")
    $named=$mutantOut-cmatch('(?m)^CASE FAIL '+[regex]::Escape($m.case)+'/')
    Assert-True (($mutantExit-ne0)-and$named) "9092 mutant survived: $($m.name) case=$($m.case) (exit=$mutantExit)"
    Write-Output "MUTANT 9092 $($m.name) RED at $($m.case) (exit=$mutantExit)"
  }
  Write-Output "PASS 9092 policy fallback guard discriminators mutants=$($mutants.Count) survivors=0"
}
try{
  New-Item -ItemType Directory -Path $runtime,$worktree|Out-Null;Set-Content -LiteralPath (Join-Path $runtime 'original.prompt.txt') -Value 'unmistakably synthetic original'
  $stub=Join-Path $root 'dispatch-lane.ps1';Set-Content -LiteralPath $stub -Value @'
param($Harness,$Model,$Effort,$Row,$Placement,$LaneRole,$PromptFile,$Worktree,$Label,$SemanticAttemptId,$WatchdogRelaunchCount,$ResumeOfLaunchId,$StartRequestIdentity,$StartAcknowledgementPath,$IntegrationTargetPath,$IntegrationAuthorityFixturePath)
Add-Content -LiteralPath $env:SYNTHETIC_WATCHDOG_CALLS -Value "$Label|$Harness|$Model|$Effort|$Row|$Placement|$SemanticAttemptId|$WatchdogRelaunchCount|$ResumeOfLaunchId"
if($env:SYNTHETIC_WATCHDOG_FAIL_LABEL-and$Label-like"$($env:SYNTHETIC_WATCHDOG_FAIL_LABEL)*"){exit 19}
$launchId=[guid]::NewGuid().ToString();$owner=Join-Path (Split-Path -Parent $StartAcknowledgementPath) "dispatch-launch-$launchId.json"
$ack=[ordered]@{schemaVersion='dispatch-start-ack/v1';requestIdentity=$StartRequestIdentity;label=$Label;launchId=$launchId;ownershipRecordPath=$owner;worktree=[IO.Path]::GetFullPath($Worktree).TrimEnd('\','/');branch='synthetic/branch';head=('a'*40);harness=$Harness;model=$Model;effort=$Effort;row=[long]$Row;placement=$Placement;state='started';childPid=[long]$PID;childStartIdentity=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')}
if($env:SYNTHETIC_WATCHDOG_ACK_FIELD){$ack[$env:SYNTHETIC_WATCHDOG_ACK_FIELD]=$env:SYNTHETIC_WATCHDOG_ACK_VALUE}
if($env:SYNTHETIC_WATCHDOG_EXPLICIT_ACK -eq '1'){
  . (Join-Path $env:SYNTHETIC_WATCHDOG_ORCH 'routing-data.ps1') -Library
  $routing=Resolve-RoutingSelection -Row ([int]$Row) -Harness $Harness -Model $Model -Effort $Effort -ReadOnly
  $ack.policyGeneration=[long]$routing.policyGeneration
  $ack.registryAuthorityDigest=[string]$routing.registryAuthorityDigest
  $ack.family=[string]$routing.family
  $ack.slot=[string]$routing.slot
  $ack.usedLastKnownGood=[bool]$routing.usedLastKnownGood
}
if($IntegrationTargetPath){$target=Get-Content $IntegrationTargetPath -Raw|ConvertFrom-Json;$ack.head=$target.head;$ack.branch=$target.branch}
[IO.File]::WriteAllText($StartAcknowledgementPath,($ack|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false));exit 0
'@
  $env:SYNTHETIC_WATCHDOG_CALLS=$calls
  $env:SYNTHETIC_WATCHDOG_ORCH=$PSScriptRoot
  function Test-ExplicitRoutingRelaunch {
    $env:SYNTHETIC_WATCHDOG_EXPLICIT_ACK='1'
    try {
      $cases=@(
        @{name='same-config-row4-sol';model='gpt-6.1-sol';effort='high';row=4;placement='provisional';error=$null;target='gpt-6.1-sol'},
        @{name='row7-astra-to-fable';model='gpt-6-astra';effort='high';row=7;placement='override-Todd';error='provider quota exceeded';target='claude-fable-5-1'},
        @{name='row4-sol-to-opus-quota';model='gpt-6.1-sol';effort='high';row=4;placement='provisional';error='provider quota exceeded';target='claude-opus-5-5'},
        @{name='row4-sol-to-opus-session';model='gpt-6.1-sol';effort='high';row=4;placement='provisional';error='session limit reached';target='claude-opus-5-5'}
      )
      foreach($case in $cases){
        $item=New-Spec "explicit-routing-$($case.name)" $case.model $case.effort 0 $case.row $case.placement
        if($case.error){Set-Content -LiteralPath $item.error -Value $case.error}
        $before=Get-CallCount;$result=Invoke-Watchdog $item $item.spec.label
        Assert-True ($result.status-ceq'RELAUNCHED'-and$result.model-ceq$case.target-and$result.slot-ceq'explicit') "explicit routing $($case.name) did not relaunch with slot=explicit"
        Assert-True ((Get-CallCount)-eq($before+1)) "explicit routing $($case.name) dispatched more or fewer than once"
        $row=Get-Content -LiteralPath $history -Tail 1|ConvertFrom-Json -DateKind String
        Assert-True ($row.kind-ceq'dispatch'-and$row.model-ceq$case.target-and$row.slot-ceq'explicit') "explicit routing $($case.name) ledger lost slot=explicit"
        Write-Output "PASS F1 explicit relaunch $($case.name) target=$($result.model)/$($result.effort) ledgerSlot=$($row.slot) resultSlot=$($result.slot)"
      }
    } finally { Remove-Item Env:SYNTHETIC_WATCHDOG_EXPLICIT_ACK -ErrorAction SilentlyContinue }
  }
  if(-not $CapacityOnly -and -not $BeforeFixControl -and -not $Row15MeasuredControl -and -not $Named8098Control -and -not $Named8186Control -and -not $PolicyFallbackOnly -and -not $PolicyFallbackMutantsOnly) {
    $beforeCapacity=Get-CallCount
    & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File $PSCommandPath -CapacityOnly -WatchdogScript $watchdog
    Assert-True ($LASTEXITCODE -eq 0) 'isolated capacity watchdog cases failed'
    Assert-True ((Get-CallCount) -eq $beforeCapacity) 'capacity child changed parent dispatch fixture'
  }
  if($CapacityOnly) {
    foreach($entry in @(@(13,'low','medium'),@(10,'medium','high'),@(4,'medium','high'),@(5,'high','high'))) {
      foreach($envelope in @('provider quota exceeded','session limit reached')) {
        $item=New-Spec "capacity-$($entry[0])-$($envelope.Split(' ')[0])" 'claude-opus-5-5' $entry[1] 0 $entry[0] 'override-Todd'
        Set-Content $item.error $envelope;$before=Get-CallCount;$result=Invoke-Watchdog $item $item.spec.label
        Assert-Recovery $item $result 'gpt-6.1-sol' $entry[2] 'override-Todd' $before
      }
    }
    foreach($row in @(8,11,12)) {
      $item=New-Spec "capacity-no-fable-$row" 'gpt-6-astra' high 0 $row 'override-Todd';Set-Content $item.error 'provider quota exceeded'
      $before=Get-CallCount;$result=$null;$refusal=''
      try{$result=Invoke-Watchdog $item $item.spec.label}catch{$refusal=$_.Exception.Message}
      Assert-True (($result.status -ceq 'NO_QUALIFIED_FALLBACK' -or $refusal -ceq 'WATCHDOG_UNKNOWN_SPEC_INVALID') -and (Get-CallCount) -eq $before) 'Fable never rows 8/11/12'
    }
    . (Join-Path $PSScriptRoot 'routing-data.ps1') -Library
    $selection=Resolve-RoutingSelection -Row 4 -Harness codex -Model gpt-6.1-sol -Effort high -ReadOnly
    foreach($version in @('v1','v2','v3')) {
      foreach($issue in @(0,908526)) {
        $item=New-LegacySpec "capacity-retained-$version-$issue"
        $args=@{Log='dispatch';Kind='dispatch';DispatchRoutingSchema="watchdog-dispatch-routing/$version";DispatchAttemptId=$item.spec.attemptId
          DispatchLabel=$item.spec.label;Lane=(Split-Path -Leaf $worktree);LaneRole='implementation';Transcript=(Split-Path -Leaf $item.partial)
          Harness='codex';Model='gpt-6.1-sol';Effort='high';Row='4';Placement='provisional';DispatchWorktree=$worktree
          DispatchBranch=$item.spec.branch;DispatchHead=$item.spec.head;OutFile=$history;NoBoard=$true}
        if($version -cne 'v1'){
          $args.PolicyGeneration=$selection.policyGeneration;$args.RegistryAuthorityDigest=$selection.registryAuthorityDigest
          $args.RoutingFamily=$selection.family;$args.RoutingSlot=$selection.slot;$args.UsedLastKnownGood=$selection.usedLastKnownGood
        }
        if($version -ceq 'v3'){
          $args.CapacityForecastStatus='not-evaluated';$args.CapacityDecisionDigest=$null;$args.CapacityFlip=$null;$args.CapacityShadowFlip=$null;$args.CapacityFlipSkip=$null
        }
        if($issue){$args.Issue=$issue}
        & (Join-Path $PSScriptRoot 'log-event.ps1') @args|Out-Null
        $before=Get-CallCount;$result=Invoke-Watchdog $item $item.spec.label
        Assert-True ($result.status -ceq 'RELAUNCHED' -and $result.row -eq 4 -and (Get-CallCount) -eq $before+1) "retained $version reader issue=$issue"
      }
    }
    Write-Output 'PASS capacity watchdog four own-slot quota routes, both envelopes, Fable exclusions'
    if($CapacityOnly){return}
  }
  if($ExplicitRoutingOnly){Test-ExplicitRoutingRelaunch;return}
  if($SonnetOnly){Test-SonnetCutover;return}
  if($PolicyFallbackOnly){Test-PolicyFallback;return}
  if($PolicyFallbackMutantsOnly){Test-PolicyFallbackMutants;return}
  # 8186: planning/review lanes are observed on dispatch-lane's own envelope and never recovered here.
  function New-RoleSpec([string]$Label,[string]$Role,[int]$Row=0,[string]$Placement='',[string]$Model='claude-opus-5-5',[string]$Effort='medium',[string]$State='exited',$ExitCode=1,[string]$Branch='synthetic/branch'){
    $item=New-Spec $Label $Model $Effort 0 $Row $Placement
    $item.spec.laneRole=$Role;$item.spec.branch=$Branch;$item.spec.state=$State
    if($State-ceq'launching'){$item.spec.childPid=$null;$item.spec.childStartIdentity=$null;$item.spec.exitCode=$null}
    elseif($State-ceq'running'){$item.spec.exitCode=$null}else{$item.spec.exitCode=$(if($null-eq$ExitCode){$null}else{[long]$ExitCode})}
    Save-Spec $item;$item
  }
  function Invoke-RoleWatchdog($Item,[string]$Name,[string]$Owner='dead',[string]$Descendant='none',[int]$AgeSeconds=299){
    & $watchdog -Label $Item.spec.label -RuntimeRoot $runtime -HistoryPath $history -TranscriptPath $Item.partial -ObservationFixture (New-Observation $Name $Owner $Descendant $AgeSeconds) -DispatchScript $stub -SynchronousDispatch|ConvertFrom-Json -DateKind String
  }
  function Assert-Throws($Item,[string]$Name,[string]$Pattern,[string]$Message){
    $before=Get-CallCount;$failure=$null
    try{Invoke-RoleWatchdog $Item $Name|Out-Null}catch{$failure=$_.Exception.Message}
    Assert-True ($failure-cmatch$Pattern-and(Get-CallCount)-eq$before) "$Message (got: $failure)"
  }
  function Assert-ObservationOnly($Result,[string]$Role,[string]$Message){
    Assert-True ($null-ne$Result-and$Result.schemaVersion-ceq'watchdog-observation-result/v1'-and$Result.status-ceq'OBSERVATION_ONLY'-and$Result.relaunch-eq$false-and$Result.laneRole-ceq$Role-and$Result.diagnosis-ceq'HOST_DIAGNOSIS_REQUIRED') "$Message (got: $($Result|ConvertTo-Json -Compress))"
  }
  $named8186=@('role-envelope','observation-without-relaunch')
  if($Named8186Control){$named8186=@($Named8186Control)}
  foreach($name8186 in $named8186){
    if($name8186-ceq'role-envelope'){
      # Actual dispatch-lane role envelopes: row 8 override-Todd planning, row 11 detached review, row 0 empty-placement review.
      $planning=New-RoleSpec 'r8186-planning-row8' planning 8 'override-Todd'
      Assert-ObservationOnly (Invoke-RoleWatchdog $planning 'r8186-planning-row8') planning 'planning row 8 override-Todd (no implementation route) was not observed on its own envelope'
      $crossed=New-RoleSpec 'r8186-implementation-row8' implementation 8 'override-Todd'
      Assert-Throws $crossed 'r8186-implementation-row8' '^WATCHDOG_UNKNOWN_SPEC_INVALID' 'the same row 8 envelope stayed admissible for implementation'
      $review=New-RoleSpec 'r8186-review-row11-detached' review 11 'override-Todd' -Branch ''
      Assert-ObservationOnly (Invoke-RoleWatchdog $review 'r8186-review-row11-detached') review 'detached review (empty branch) was refused'
      $review0=New-RoleSpec 'r8186-review-row0' review 0 ''
      Assert-ObservationOnly (Invoke-RoleWatchdog $review0 'r8186-review-row0') review 'row 0 empty-placement review was refused'
      $planningCase=New-RoleSpec 'r8186-planning-case' planning 3 'Override-Todd'
      Assert-ObservationOnly (Invoke-RoleWatchdog $planningCase 'r8186-planning-case') planning 'dispatch-lane case-insensitive placement was refused for planning'
      $planningCodex=New-RoleSpec 'r8186-planning-codex' planning 15 'measured' 'gpt-6-astra' 'xhigh'
      Assert-ObservationOnly (Invoke-RoleWatchdog $planningCodex 'r8186-planning-codex') planning 'planning row 15 codex envelope was refused'
      # Domain closure comes from dispatch-lane, not the implementation route table.
      foreach($case in @(
        @('row16',{param($i)$i.spec.row=[long]16},'^WATCHDOG_UNKNOWN_SPEC_INVALID'),
        @('rowneg',{param($i)$i.spec.row=[long](-1)},'^WATCHDOG_UNKNOWN_SPEC_INVALID'),
        @('rowstring',{param($i)$i.spec.row='8'},'^WATCHDOG_UNKNOWN_SPEC_INVALID'),
        @('placement',{param($i)$i.spec.placement='bogus'},'^WATCHDOG_UNKNOWN_SPEC_INVALID'),
        @('placementnull',{param($i)$i.spec.placement=$null},'^WATCHDOG_UNKNOWN_SPEC_INVALID'),
        @('model',{param($i)$i.spec.model='gpt-6-nova'},'^WATCHDOG_UNKNOWN_SPEC_INVALID'),
        @('effort',{param($i)$i.spec.effort='ultra'},'^WATCHDOG_UNKNOWN_SPEC_INVALID'),
        @('harness',{param($i)$i.spec.harness='codex'},'^WATCHDOG_UNKNOWN_SPEC_INVALID'),
        @('extrakey',{param($i)$i.spec['routeTable']='none'},'^WATCHDOG_UNKNOWN_SPEC_INVALID'),
        @('state',{param($i)$i.spec.state='stopped'},'^WATCHDOG_UNKNOWN_SPEC_INVALID'),
        @('rolebogus',{param($i)$i.spec.laneRole='bogus'},'^WATCHDOG_UNKNOWN_SPEC_INVALID'),
        @('rolecase',{param($i)$i.spec.laneRole='Planning'},'^WATCHDOG_UNKNOWN_SPEC_INVALID'),
        @('rolenull',{param($i)$i.spec.laneRole=$null},'^WATCHDOG_UNKNOWN_SPEC_INVALID'),
        @('rolemissing',{param($i)$i.spec.Remove('laneRole')},'^WATCHDOG_UNKNOWN_SPEC_INVALID'),
        @('branchplanning',{param($i)$i.spec.branch=''},'^WATCHDOG_UNKNOWN_SPEC_GIT_IDENTITY'),
        @('head',{param($i)$i.spec.head='not-a-sha'},'^WATCHDOG_UNKNOWN_SPEC_GIT_IDENTITY'),
        @('partialpath',{param($i)$i.spec.partialReportPath=(Join-Path $runtime 'r8186-planning-row8.jsonl')},'^WATCHDOG_UNKNOWN_SPEC_PARTIAL_PATH'),
        @('errorpath',{param($i)$i.spec.errorPath=(Join-Path $runtime 'r8186-planning-row8.err.log')},'^WATCHDOG_UNKNOWN_SPEC_ERROR_PATH'),
        @('ownerpath',{param($i)$i.spec.ownershipRecordPath=(Join-Path $runtime 'dispatch-launch-other.json')},'^WATCHDOG_UNKNOWN_SPEC_OWNER_PATH'),
        @('prompt',{param($i)$i.spec.originalPromptPath=(Join-Path $runtime 'missing.prompt.txt')},'^WATCHDOG_UNKNOWN_SPEC_ORIGINAL_PROMPT'),
        @('worktree',{param($i)$i.spec.worktree=(Join-Path $root 'missing-worktree')},'^WATCHDOG_UNKNOWN_SPEC_WORKTREE'))){
        $label="r8186-envelope-$($case[0])";$item=New-RoleSpec $label planning 8 'override-Todd'
        & $case[1] $item;Save-Spec $item
        Assert-Throws $item $label $case[2] "planning envelope defect '$($case[0])' was not refused closed"
      }
      $mismatch=New-RoleSpec 'r8186-envelope-label' planning 8 'override-Todd';$mismatch.spec.label='r8186-other'
      [IO.File]::WriteAllText((Join-Path $runtime 'watchdog-lane-r8186-envelope-label.json'),($mismatch.spec|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
      $before=Get-CallCount;$failure=$null
      try{& $watchdog -Label 'r8186-envelope-label' -RuntimeRoot $runtime -HistoryPath $history -TranscriptPath $mismatch.partial -ObservationFixture (New-Observation 'r8186-envelope-label') -DispatchScript $stub -SynchronousDispatch|Out-Null}catch{$failure=$_.Exception.Message}
      Assert-True ($failure-cmatch'^WATCHDOG_UNKNOWN_SPEC_INVALID'-and(Get-CallCount)-eq$before) "planning label mismatch was admitted (got: $failure)"
      $detachedImplementation=New-RoleSpec 'r8186-implementation-detached' implementation 7 'override-Todd' 'claude-fable-5-1' 'high' -Branch ''
      Assert-Throws $detachedImplementation 'r8186-implementation-detached' '^WATCHDOG_UNKNOWN_SPEC_GIT_IDENTITY' 'empty branch was admitted for implementation'
      $reviewRow16=New-RoleSpec 'r8186-review-row16' review 16 ''
      Assert-Throws $reviewRow16 'r8186-review-row16' '^WATCHDOG_UNKNOWN_SPEC_INVALID' 'review row 16 was admitted'
      # v3/v4 remain implementation-only; role is read before any integration/resume binding.
      $v3=New-RoleSpec 'r8186-planning-v3' planning 8 'override-Todd';$v3.spec.schemaVersion='watchdog-lane/v3';$v3.spec['integrationRequest']=[ordered]@{schemaVersion='integration-dispatch-request/v1'};Save-Spec $v3
      Assert-Throws $v3 'r8186-planning-v3' '^WATCHDOG_UNKNOWN_INTEGRATION_SPEC' 'v3 planning spec was not refused'
      $v4=New-RoleSpec 'r8186-review-v4' review 11 'override-Todd';$v4.spec.schemaVersion='watchdog-lane/v4';$v4.spec['interruptedIntegration']='{}';Save-Spec $v4
      Assert-Throws $v4 'r8186-review-v4' '^WATCHDOG_UNKNOWN_RESUME_BINDING' 'v4 review spec was not refused'
      # Retained v1 planning/review need no routing row; v1 implementation without a row is still refused.
      foreach($role in @('planning','review')){
        $legacyRole=New-LegacySpec "r8186-legacy-$role" 'claude-opus-5-5' 'medium';$legacyRole.spec.laneRole=$role;Save-Spec $legacyRole
        Assert-ObservationOnly (Invoke-RoleWatchdog $legacyRole "r8186-legacy-$role") $role "retained v1 $role lane required a routing row"
      }
      $legacyImplementation=New-LegacySpec 'r8186-legacy-implementation' 'gpt-6.1-sol' 'high'
      $legacyResult=Invoke-RoleWatchdog $legacyImplementation 'r8186-legacy-implementation'
      Assert-True ($legacyResult.status-ceq'ROUTING_PROVENANCE_REFUSED'-and-not$legacyResult.relaunch) 'v1 implementation without a routing row lost its refusal'
      $legacyBogus=New-LegacySpec 'r8186-legacy-bogus' 'claude-opus-5-5' 'medium';$legacyBogus.spec.laneRole='bogus';Save-Spec $legacyBogus
      Assert-Throws $legacyBogus 'r8186-legacy-bogus' '^WATCHDOG_UNKNOWN_SPEC_INVALID' 'v1 unknown role was admitted'
      # Retired selectors cannot start anew for any role.
      $retiredPlanning=New-RoleSpec 'r8186-planning-retired-launching' planning 8 'override-Todd' 'claude-opus-5' 'high' 'launching'
      Assert-Throws $retiredPlanning 'r8186-planning-retired-launching' '^WATCHDOG_RETIRED_MODEL_INVALID' 'retired planning selector was admitted anew'
      Write-Output 'PASS 8186 role-envelope'
    }
    if($name8186-ceq'observation-without-relaunch'){
      $promptsBefore=@(Get-ChildItem -LiteralPath $runtime -Filter '*.prompt.txt').Count
      $historyBefore=if(Test-Path $history){(Get-FileHash $history).Hash}else{'absent'}
      $callsBefore=Get-CallCount
      $ownerTail=@{dead='dead';live='live';ambiguous='ambiguous';reused='reused'}
      $count=0
      foreach($role in @('planning','review')){
        foreach($state in @('launching','running','exited')){
          foreach($owner in @('dead','live','ambiguous','reused')){
            foreach($descendant in @('none','possible','ambiguous')){
              foreach($exit in @(0,7)){
                if($state-cne'exited'-and$exit-ne0){continue}
                $count++;$label="r8186-obs-$role-$state-$owner-$descendant-$exit"
                $item=New-RoleSpec $label $role 8 'override-Todd' 'claude-opus-5-5' 'medium' $state $exit
                $before=Get-CallCount;$specBefore=(Get-FileHash (Join-Path $runtime "watchdog-lane-$label.json")).Hash;$partialBefore=(Get-FileHash $item.partial).Hash
                $result=Invoke-RoleWatchdog $item $label $owner $descendant
                if($owner-ceq'live'){Assert-True ($result.status-ceq'LIVE_SLOW'-and-not$result.relaunch) "$label live owner was not LIVE_SLOW"}
                elseif($state-ceq'exited'-and$exit-eq0){Assert-True ($result.status-ceq'TERMINAL_SUCCESS'-and-not$result.relaunch) "$label exit 0 was not TERMINAL_SUCCESS"}
                elseif($owner-cne'dead'-or$descendant-cne'none'){Assert-True ($result.status-ceq'OWNERSHIP_UNKNOWN'-and-not$result.relaunch) "$label ambiguous ownership was not OWNERSHIP_UNKNOWN (got $($result.status))"}
                else{Assert-ObservationOnly $result $role "$label proven-dead non-successful lane was not OBSERVATION_ONLY";Assert-True ($result.state-ceq$state-and$result.ownerState-ceq'dead') "$label observation lost state/owner"}
                $again=Invoke-RoleWatchdog $item "$label-again" $owner $descendant
                Assert-True ($again.status-ceq$result.status) "$label repeated observation changed status"
                Assert-True ((Get-CallCount)-eq$before-and(Get-FileHash (Join-Path $runtime "watchdog-lane-$label.json")).Hash-ceq$specBefore-and(Get-FileHash $item.partial).Hash-ceq$partialBefore) "$label observation had dispatch or byte effects"
              }
            }
          }
        }
      }
      Assert-True ($count-eq 2*4*3*(1+1+2)) "observation matrix incomplete ($count)"
      # Stale detection, quota tails, arbitrary tails and historical routes never reach recovery for planning/review.
      $stale=New-RoleSpec 'r8186-obs-stale' planning 8 'override-Todd'
      Assert-ObservationOnly (Invoke-RoleWatchdog $stale 'r8186-obs-stale' dead none 301) planning 'stale (301 s) planning observation reached recovery age'
      $future=New-RoleSpec 'r8186-obs-future' review 11 'override-Todd' -Branch ''
      Assert-ObservationOnly (Invoke-RoleWatchdog $future 'r8186-obs-future' dead none -5) review 'negative-age review observation reached recovery age'
      $quota=New-RoleSpec 'r8186-obs-quota' planning 8 'override-Todd';Set-Content -LiteralPath $quota.error -Value 'provider quota exceeded'
      Assert-ObservationOnly (Invoke-RoleWatchdog $quota 'r8186-obs-quota') planning 'quota-signature planning lane reached fallback'
      $sessionLimit=New-RoleSpec 'r8186-obs-session' review 0 '';Set-Content -LiteralPath $sessionLimit.error -Value 'session limit reached'
      Assert-ObservationOnly (Invoke-RoleWatchdog $sessionLimit 'r8186-obs-session') review 'session-limit review lane reached fallback'
      $arbitrary=New-RoleSpec 'r8186-obs-arbitrary' planning 8 'override-Todd';Set-Content -LiteralPath $arbitrary.error -Value 'unclassified synthetic tail 8186'
      Assert-ObservationOnly (Invoke-RoleWatchdog $arbitrary 'r8186-obs-arbitrary') planning 'arbitrary-tail planning lane reached signature classification'
      $historical=New-RoleSpec 'r8186-obs-historical' planning 7 'override-Todd' 'claude-opus-5' 'high'
      Assert-ObservationOnly (Invoke-RoleWatchdog $historical 'r8186-obs-historical') planning 'historical-model planning predecessor was routed to redispatch'
      $historicalReview=New-RoleSpec 'r8186-obs-historical-review' review 0 '' 'gpt-5.6-sol' 'high' 'running'
      Assert-ObservationOnly (Invoke-RoleWatchdog $historicalReview 'r8186-obs-historical-review') review 'historical-model running review predecessor was routed to redispatch'
      $ceiling=New-RoleSpec 'r8186-obs-ceiling' planning 8 'override-Todd';$ceiling.spec.relaunchCount=[long]3;Save-Spec $ceiling
      Assert-ObservationOnly (Invoke-RoleWatchdog $ceiling 'r8186-obs-ceiling') planning 'planning lane at count 3 reached the harness ceiling'
      $historyAfter=if(Test-Path $history){(Get-FileHash $history).Hash}else{'absent'}
      Assert-True ((Get-CallCount)-eq$callsBefore-and@(Get-ChildItem -LiteralPath $runtime -Filter '*.prompt.txt').Count-eq$promptsBefore-and$historyAfter-ceq$historyBefore) 'observation-only lanes produced dispatch, prompt or history effects'
      Write-Output 'PASS 8186 observation-without-relaunch'
    }
  }
  if($Named8186Control){return}
  # 8186 mutants: each named control is re-run as a child suite against a mutated
  # reducer copy and must fail with an assertion or a closed WATCHDOG_ throw.
  $mutantRoot8186=Join-Path $root 'mutants-8186';New-Item -ItemType Directory $mutantRoot8186|Out-Null
  $source8186=[IO.File]::ReadAllText($watchdog)
  $guardAnchor='if(-not$implementation){ # OBSERVATION_GUARD_ROLE'
  $guardEnd='|ConvertTo-Json -Compress;return'+"`r`n"+'}'+"`r`n"
  $guardStart=$source8186.IndexOf($guardAnchor);Assert-True ($guardStart-ge0) '8186 guard anchor missing'
  $guardStop=$source8186.IndexOf($guardEnd,$guardStart)+$guardEnd.Length
  $guardBlock=$source8186.Substring($guardStart,$guardStop-$guardStart)
  $roleAnchor="if(`$laneRole-cnotin@('implementation','planning','review')){throw 'WATCHDOG_UNKNOWN_SPEC_INVALID'}"
  $ageAnchor="if(`$elapsed-lt0-or`$elapsed-gt300){throw 'WATCHDOG_RELAUNCH_WINDOW_EXPIRED'}"+"`r`n"
  foreach($anchor in @($guardAnchor,$roleAnchor,$ageAnchor)){Assert-True (([regex]::Matches($source8186,[regex]::Escape($anchor))).Count-eq1) "8186 mutation anchor not unique: $anchor"}
  $mutants8186=@(
    # Classify by role before the closed envelope/path/identity validation.
    @{name='role-shortcut-before-validation';control='role-envelope';text=$source8186.Replace($roleAnchor,"if(`$laneRole-cne'implementation'){[pscustomobject]@{schemaVersion='watchdog-observation-result/v1';status='OBSERVATION_ONLY';relaunch=`$false;laneRole=`$laneRole;diagnosis='HOST_DIAGNOSIS_REQUIRED'}|ConvertTo-Json -Compress;return}")},
    # Let planning/review fall through to implementation recovery.
    @{name='remove-nonimplementation-recovery-stop';control='observation-without-relaunch';text=$source8186.Replace($guardAnchor,'if($false){ # MUTATED_OBSERVATION_GUARD')},
    # Observe only after the signature/age checks already refused a stale lane.
    @{name='observation-after-signature';control='observation-without-relaunch';text=$source8186.Replace($guardBlock,'').Replace($ageAnchor,$ageAnchor+$guardBlock)}
  )
  Get-ChildItem $PSScriptRoot -File|Where-Object Extension -in @('.ps1','.psm1')|Copy-Item -Destination $mutantRoot8186
  New-Item -ItemType Directory -Force -Path (Join-Path $mutantRoot8186 'controller-skills/model-routing')|Out-Null
  Copy-Item (Join-Path $PSScriptRoot 'controller-skills/model-routing/capability-matrix.json') (Join-Path $mutantRoot8186 'controller-skills/model-routing/capability-matrix.json')
  foreach($m in $mutants8186){
    Assert-True ($m.text-cne$source8186) "8186 mutant unchanged: $($m.name)"
    $mutantPath=Join-Path $mutantRoot8186 "$($m.name).ps1";[IO.File]::WriteAllText($mutantPath,$m.text,[Text.UTF8Encoding]::new($false))
    $parseErrors=$null;[void][Management.Automation.Language.Parser]::ParseFile($mutantPath,[ref]$null,[ref]$parseErrors);Assert-True ($parseErrors.Count-eq0) "8186 mutant does not parse: $($m.name)"
    $mutantTest=Join-Path (Split-Path -Parent $mutantPath) 'lane-stall-watchdog.test.ps1'
    $mutantOut=& (Get-Command pwsh).Source -NoProfile -NonInteractive -File $mutantTest -Named8186Control $m.control -WatchdogScript $mutantPath 2>&1|Out-String;$mutantExit=$LASTEXITCODE
    [IO.File]::WriteAllText((Join-Path $mutantRoot8186 "$($m.name).log"),"exit=$mutantExit`n$mutantOut")
    $mutantHasFailure = $mutantOut -match 'ASSERTION FAILED|WATCHDOG_[A-Z_]+'
    $mutantHasPass = $mutantOut -match "(?m)^PASS 8186 $([regex]::Escape([string]$m.control))\s*$"
    Assert-True (($mutantExit -ne 0) -and $mutantHasFailure -and (-not $mutantHasPass)) "8186 mutant survived: $($m.name) (exit=$mutantExit)"
    Write-Output "MUTANT 8186 $($m.name) RED ($($m.control) control rejected, exit=$mutantExit)"
  }
  foreach($old in @(@('gpt-5.6-sol','high',4),@('gpt-5.6-terra','medium',2),@('gpt-5.6-luna','medium',2),@('claude-opus-5','high',6),@('claude-sonnet-5','medium',3),@('claude-sonnet-5','medium',13),@('claude-sonnet-5','high',10),@('gpt-6-sol','high',4),@('gpt-6-sol','xhigh',5),@('gpt-6-sol','medium',13),@('gpt-6-sol','medium',2))){
    $item=New-Spec "new-retired-$($old[0])" $old[0] $old[1] 0 $old[2] measured
    $item.spec.state='launching';$item.spec.childPid=$null;$item.spec.childStartIdentity=$null;$item.spec.exitCode=$null;Save-Spec $item
    $before=Get-CallCount;$failure=$null
    try{Invoke-Watchdog $item $item.spec.label|Out-Null}catch{$failure=$_.Exception.Message}
    Assert-True ($failure-match"WATCHDOG_RETIRED_MODEL_INVALID.*$($old[0])"-and(Get-CallCount)-eq$before) "new retired spec was admitted: $failure"
  }
  $oldTodd=New-Spec 'historical-opus-todd-early' 'claude-opus-5' high 0 4 override-Todd
  $oldResult=Invoke-Watchdog $oldTodd $oldTodd.spec.label
  Assert-True ($oldResult.status-ceq'RETIRED_MODEL_REQUIRES_REDISPATCH'-and-not$oldResult.relaunch) 'historical Todd predecessor was not read-only'
  if($RetiredOnly){Write-Output 'PASS new retired watchdog specs refused';return}
  if(-not$BeforeFixControl-and-not$Row15MeasuredControl){
  . (Join-Path $PSScriptRoot 'integration-dispatch-test-support.ps1')
  & git -C $worktree init -q --initial-branch=main
  & git -C $worktree config user.name 'Synthetic Authority'
  & git -C $worktree config user.email 'synthetic-authority@example.invalid'
  Set-Content (Join-Path $worktree 'seed.txt') synthetic
  & git -C $worktree add .
  & git -C $worktree commit -qm synthetic
  & git -C $worktree checkout -qb synthetic/branch
  Publish-SyntheticIntegrationRemote $worktree (Join-Path $root 'remote.git')
  $nativeHead=(& git -C $worktree rev-parse HEAD).Trim()
  $item=New-Spec 'synthetic-8132-stop' 'gpt-6-astra' high 0 7 override-Todd
  $item.spec.head=$nativeHead;$item.spec.schemaVersion='watchdog-lane/v3'
  $item.spec['integrationRequest']=[ordered]@{schemaVersion='integration-dispatch-request/v1';requestIdentity=('c'*64);repository=$SyntheticIntegrationRepository;pr=908132L;landedPr=908131L;landedHead=('a'*40);head=$nativeHead;newBase=$nativeHead;branch='synthetic/branch';worktree=$worktree;label=$item.spec.label;sourceIdentity='ABSENT_REVIEW_REQUIRED';sourceHead='';runtimeRoot=$runtime;historyPath=$history}
  Save-Spec $item
  $logger=Join-Path $PSScriptRoot 'log-event.ps1'
  $binding=@{Log='dispatch';Kind='rule-change';IntegrationAuthoritySchema='landed-integration-authority/v1';Pr=908132;Issue=908132;TargetBranch='synthetic/branch';LineageRoot='synthetic/8132';TargetHead=('f'*40);OutFile=$history;NoBoard=$true;AuthorityIssue=908132;AuthorityCommentId=9000000001;OperatorAuthority='Todd:908132#9000000001';Note='Synthetic ruling read 2026-09-23T00:00:00Z'}
  & $logger @binding -AuthorityState STOP|Out-Null
  $stop=(Read-ExactHeadReviewHistory $history).rows[-1].rawSha256
  $observation=New-Observation 'synthetic-authority'
  $before=@{};foreach($f in Get-ChildItem $runtime -File){$before[$f.Name]=(Get-FileHash $f.FullName).Hash}
  foreach($day in 1..2){
    $result=& $watchdog -Label $item.spec.label -RuntimeRoot $runtime -HistoryPath $history -ObservationFixture $observation -DispatchScript $stub -SynchronousDispatch|ConvertFrom-Json
    Assert-True ($result.status-ceq'TERMINAL_AUTHORITY_STOP'-and-not$result.relaunch-and$result.stopRows.Count-eq1-and$result.stopRows[0]-ceq$stop) 'watchdog STOP gate did not bind exact active hash'
  }
  $changed=@(Get-ChildItem $runtime -File|Where-Object{-not$before.ContainsKey($_.Name)-or$before[$_.Name]-cne(Get-FileHash $_.FullName).Hash})
  Assert-True ($changed.Count-eq0-and(Get-CallCount)-eq0) 'watchdog stop wrote prompt/request/resume/ack/history or dispatched'
  Write-Output 'CONTROL watchdog-relaunch-refused-by-terminal-stop PASS'
  $mutantRoot=Join-Path $root 'mutant-stop-gate';New-Item -ItemType Directory $mutantRoot|Out-Null
  Get-ChildItem $PSScriptRoot -File|Where-Object Extension -in @('.ps1','.psm1')|Copy-Item -Destination $mutantRoot
  $source=[IO.File]::ReadAllText($watchdog);$anchor="if(`$authority.state-ceq'STOP'){ # AUTHORITY_GUARD_WATCHDOG"
  Assert-True ($source.Contains($anchor)) 'watchdog mutation anchor missing'
  $mutant=Join-Path $mutantRoot 'lane-stall-watchdog.ps1';[IO.File]::WriteAllText($mutant,$source.Replace($anchor,'if($false){ # MUTATED_STOP_GATE'))
  $emptyApi=Join-Path $root 'synthetic-empty-api.json';Set-Content $emptyApi '[]'
  $mutantFailure=$null
  try{& $mutant -Label $item.spec.label -RuntimeRoot $runtime -HistoryPath $history -ObservationFixture $observation -IntegrationAuthorityFixturePath $emptyApi -DispatchScript $stub -SynchronousDispatch|Out-Null}catch{$mutantFailure=$_.Exception.Message}
  $mutantEffects=@(Get-ChildItem $runtime -Filter '*.prompt.txt'|Where-Object{-not$before.ContainsKey($_.Name)})
  Assert-True ($mutantFailure-like'INTEGRATION_TARGET_RECONCILIATION_REQUIRED:*'-and$mutantEffects.Count-eq1) 'watchdog STOP bypass did not fail the no-prompt-effect control'
  Write-Output 'CONTROL AUTHORITY_GUARD_WATCHDOG bypass REJECTED (one forbidden prompt effect)'
  $ordinary=New-Spec 'synthetic-8132-ordinary';$ordinaryResult=Invoke-Watchdog $ordinary 'ordinary-authority'
  Assert-True ($ordinaryResult.status-ceq'RELAUNCHED') 'ordinary lane was authority-gated'
  Write-Output 'CONTROL watchdog-ordinary-lane-unaffected PASS'
  $live=& $watchdog -Label $item.spec.label -RuntimeRoot $runtime -HistoryPath $history -ObservationFixture (New-Observation 'authority-live' live) -DispatchScript $stub|ConvertFrom-Json
  Assert-True ($live.status-ceq'LIVE_SLOW') 'STOP became a live-lane kill or gate'
  $valid=[IO.File]::ReadAllText($history)
  foreach($case in @('malformed','scoped-invalid','unscoped','missing')){
    [IO.File]::WriteAllText($history,$valid)
    switch($case){
      malformed {Add-Content $history '{synthetic malformed'}
      scoped-invalid {$row=(Read-ExactHeadReviewHistory $history).rows[0].value;$row|Add-Member unexpected $true;$row|ConvertTo-Json -Compress|Add-Content $history}
      unscoped {Add-Content $history '{"integrationAuthoritySchema":"landed-integration-authority/v1","pr":null}'}
      missing {Remove-Item -LiteralPath $history}
    }
    $failure=$null;$beforeCalls=Get-CallCount
    $beforeInvalid=@{};foreach($f in Get-ChildItem $runtime -File|Where-Object Name -notlike '*.observation.json'){$beforeInvalid[$f.Name]=(Get-FileHash $f.FullName).Hash}
    try{Invoke-Watchdog $item "bad-authority-$case"|Out-Null}catch{$failure=$_.Exception.Message}
    $invalidEffects=@(Get-ChildItem $runtime -File|Where-Object{$_.Name-notlike'*.observation.json'-and(-not$beforeInvalid.ContainsKey($_.Name)-or$beforeInvalid[$_.Name]-cne(Get-FileHash $_.FullName).Hash)})
    Assert-True ($failure-like'WATCHDOG_UNKNOWN_*'-and(Get-CallCount)-eq$beforeCalls-and$invalidEffects.Count-eq0) "$case watchdog did not refuse before effects"
  }
  [IO.File]::WriteAllText($history,$valid)
  $binding.AuthorityCommentId=9000000002;$binding.OperatorAuthority='Todd:908132#9000000002'
  & $logger @binding -AuthorityState RELEASE -Supersedes $stop|Out-Null
  $api=Write-SyntheticIntegrationAuthority (Join-Path $root 'authority.json') @([pscustomobject]@{number=908132;headRefName='synthetic/branch';headRefOid=$nativeHead}) $nativeHead
  $beforeCalls=Get-CallCount
  $result=& $watchdog -Label $item.spec.label -RuntimeRoot $runtime -HistoryPath $history -ObservationFixture (New-Observation 'released') -IntegrationAuthorityFixturePath $api -DispatchScript $stub -SynchronousDispatch|ConvertFrom-Json
  Assert-True ($result.status-ceq'RELAUNCHED'-and(Get-CallCount)-eq($beforeCalls+1)) 'released watchdog required ELIGIBLE or failed its existing admitted resume'
  Write-Output 'CONTROL watchdog-malformed-authority-row-refuses PASS; watchdog-relaunch-after-release-proceeds PASS'
  if($AuthorityOnly){return}
  }
  # September 23 policy placements retain identity through a mechanical retry.
  $benchmarkRoutes=@(
    @(3,'claude-opus-5-5','low'),@(3,'claude-opus-5-5','medium'),@(3,'claude-opus-5-5','high'),@(3,'gpt-6.1-sol','medium'),
    @(4,'claude-opus-5-5','medium'),@(5,'claude-opus-5-5','medium'),@(10,'claude-opus-5-5','medium'),
    @(13,'gpt-6.1-sol','medium'),@(13,'claude-opus-5-5','low'),@(13,'claude-opus-5-5','medium'),
    @(3,'claude-sonnet-5-5','medium'),@(13,'claude-sonnet-5-5','medium')
  )
  foreach($entry in $benchmarkRoutes){
    $label="benchmark-$($entry-join'-')";$item=New-Spec $label $entry[1] $entry[2] 0 $entry[0] 'override-Todd'
    $before=Get-CallCount;$result=Invoke-Watchdog $item $label
    Assert-Recovery $item $result $entry[1] $entry[2] 'override-Todd' $before
    if($entry[0]-in@(3,13)-and$entry[2]-ceq'medium'-and$entry[1]-cin@('gpt-6.1-sol','claude-opus-5-5')){continue}
    if($entry[1] -ceq 'claude-opus-5-5' -and (($entry[0] -in @(4,10) -and $entry[2] -ceq 'medium') -or ($entry[0] -eq 13 -and $entry[2] -ceq 'low'))){continue} # covered by capacity quota controls above
    $quota=New-Spec "$label-quota" $entry[1] $entry[2] 0 $entry[0] 'override-Todd';Set-Content $quota.error 'provider quota exhausted'
    $before=Get-CallCount;$blocked=Invoke-Watchdog $quota "$label-quota"
    Assert-True ($blocked.status-ceq'NO_QUALIFIED_FALLBACK'-and$blocked.relaunch-eq$false-and(Get-CallCount)-eq$before) 'benchmark placement invented an unruled automatic quota fallback'
  }
  Write-Output 'PASS benchmark routing: 12 exact policy recoveries; remaining unruled routes block; capacity quota routes separately covered'
  foreach($entry in @(@(3,'gpt-6.1-sol','claude-opus-5-5'),@(13,'gpt-6.1-sol','claude-opus-5-5'),@(3,'claude-opus-5-5','gpt-6.1-sol'),@(13,'claude-opus-5-5','gpt-6.1-sol'))){
    foreach($envelope in @('provider quota exceeded','session limit reached')){
      $row=$entry[0];$primary=$entry[1];$target=$entry[2];$tag="$row-$primary-$($envelope.Replace(' ','-'))"
      $item=New-Spec "synthetic-8146-$tag" $primary 'medium' 0 $row 'override-Todd';Set-Content $item.error $envelope
      $before=Get-CallCount;$result=Invoke-Watchdog $item $item.spec.label
      Assert-Recovery $item $result $target 'medium' 'override-Todd' $before
      Assert-True ($result.harness-ceq(Get-Harness $target)) "8146 fallback $tag changed harness"
      $again=New-Spec "synthetic-8146-roundtrip-$tag" $target 'medium' 1 $row 'override-Todd';$before=Get-CallCount;$roundTrip=Invoke-Watchdog $again $again.spec.label
      Assert-Recovery $again $roundTrip $target 'medium' 'override-Todd' $before
      Write-Output "CONTROL 8146 FALLBACK row=$row from=$primary/medium envelope=$envelope selected=$($result.harness)/$($result.model)/$($result.effort) placement=$($result.placement) roundTrip=$($roundTrip.status)"
    }
  }
  # 8098: the account pool's quota envelope. The fixtures replay the captured bytes from
  # .orchestrator/8090-publication-freshness-g4.err.log (lines 32-37: the six credential_quota
  # retry lines) and 8090-publication-freshness-g4.jsonl (the final two native records); the
  # SHA256 guards below pin those slices. No captured 429 envelope exists, so the model_cooldown
  # line is synthetic in the same retry-line shape.
  if(-not$BeforeFixControl-and-not$Row15MeasuredControl){
    function Get-TextSha256([string]$Text){([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text)))).ToLowerInvariant()}
    function Write-LfLines([string]$Path,[string[]]$Lines){[IO.File]::WriteAllText($Path,(($Lines-join"`n")+"`n"),[Text.UTF8Encoding]::new($false))}
    function Get-LastHistoryRow {Get-Content $history -Tail 1|ConvertFrom-Json -DateKind String}
    $poolQuotaRetryLines=@(
      '2026-09-21T04:14:32.994240Z  WARN codex_core::responses_retry: stream disconnected - retrying sampling request (1/6 in 199ms)... turn_id=01a0c22a-3dd2-70c3-bab6-21c17d745535 retries=1 max_retries=6 sampling_error=unexpected status 503 Service Unavailable: upstream rate limited, retry later: All credentials for model gpt-5.6-sol are cooling down (last error: credential_quota), url: http://127.0.0.1:8317/v1/responses',
      '2026-09-21T04:14:39.387073Z  WARN codex_core::responses_retry: stream disconnected - retrying sampling request (2/6 in 421ms)... turn_id=01a0c22a-3dd2-70c3-bab6-21c17d745535 retries=2 max_retries=6 sampling_error=unexpected status 503 Service Unavailable: upstream rate limited, retry later: All credentials for model gpt-5.6-sol are cooling down (last error: credential_quota), url: http://127.0.0.1:8317/v1/responses',
      '2026-09-21T04:14:45.852407Z  WARN codex_core::responses_retry: stream disconnected - retrying sampling request (3/6 in 765ms)... turn_id=01a0c22a-3dd2-70c3-bab6-21c17d745535 retries=3 max_retries=6 sampling_error=unexpected status 503 Service Unavailable: upstream rate limited, retry later: All credentials for model gpt-5.6-sol are cooling down (last error: credential_quota), url: http://127.0.0.1:8317/v1/responses',
      '2026-09-21T04:14:52.937395Z  WARN codex_core::responses_retry: stream disconnected - retrying sampling request (4/6 in 1.592s)... turn_id=01a0c22a-3dd2-70c3-bab6-21c17d745535 retries=4 max_retries=6 sampling_error=unexpected status 503 Service Unavailable: upstream rate limited, retry later: All credentials for model gpt-5.6-sol are cooling down (last error: credential_quota), url: http://127.0.0.1:8317/v1/responses',
      '2026-09-21T04:15:00.759777Z  WARN codex_core::responses_retry: stream disconnected - retrying sampling request (5/6 in 3.095s)... turn_id=01a0c22a-3dd2-70c3-bab6-21c17d745535 retries=5 max_retries=6 sampling_error=unexpected status 503 Service Unavailable: upstream rate limited, retry later: All credentials for model gpt-5.6-sol are cooling down (last error: credential_quota), url: http://127.0.0.1:8317/v1/responses',
      '2026-09-21T04:15:10.449640Z  WARN codex_core::responses_retry: stream disconnected - retrying sampling request (6/6 in 6.16s)... turn_id=01a0c22a-3dd2-70c3-bab6-21c17d745535 retries=6 max_retries=6 sampling_error=unexpected status 503 Service Unavailable: upstream rate limited, retry later: All credentials for model gpt-5.6-sol are cooling down (last error: credential_quota), url: http://127.0.0.1:8317/v1/responses'
    )
    $poolQuotaTranscriptRecords=@(
      '{"type":"error","message":"unexpected status 503 Service Unavailable: upstream rate limited, retry later: All credentials for model gpt-5.6-sol are cooling down (last error: credential_quota), url: http://127.0.0.1:8317/v1/responses"}',
      '{"type":"turn.failed","error":{"message":"unexpected status 503 Service Unavailable: upstream rate limited, retry later: All credentials for model gpt-5.6-sol are cooling down (last error: credential_quota), url: http://127.0.0.1:8317/v1/responses"}}'
    )
    Assert-True ((Get-TextSha256 (($poolQuotaRetryLines-join"`n")+"`n"))-ceq'd1b1f5cb178a623901fff8b0747828bda8831513cae0ff67fc536806321acf21') 'captured credential_quota retry lines drifted from 8090-publication-freshness-g4.err.log lines 32-37'
    Assert-True ((Get-TextSha256 (($poolQuotaTranscriptRecords-join"`n")+"`n"))-ceq'6cf7967daa4f5bf3509d5ea48606481a574f99ae0d26cab103ea94bc322d5a0a') 'captured native records drifted from the final two records of 8090-publication-freshness-g4.jsonl'
    $modelCooldownRetryLine='2026-09-21T04:14:32.994240Z  WARN codex_core::responses_retry: stream disconnected - retrying sampling request (1/6 in 199ms)... turn_id=01a0c22a-3dd2-70c3-bab6-21c17d745535 retries=1 max_retries=6 sampling_error=unexpected status 429 Too Many Requests: upstream rate limited, retry later: model_cooldown for model gpt-5.6-sol, url: http://127.0.0.1:8317/v1/responses'
    $plain503RetryLine='2026-09-21T04:14:32.994240Z  WARN codex_core::responses_retry: stream disconnected - retrying sampling request (1/6 in 199ms)... turn_id=01a0c22a-3dd2-70c3-bab6-21c17d745535 retries=1 max_retries=6 sampling_error=unexpected status 503 Service Unavailable: upstream temporarily unavailable, url: http://127.0.0.1:8317/v1/responses'
    $plain503TranscriptRecords=@('{"type":"error","message":"unexpected status 503 Service Unavailable: upstream temporarily unavailable, url: http://127.0.0.1:8317/v1/responses"}','{"type":"turn.failed","error":{"message":"unexpected status 503 Service Unavailable: upstream temporarily unavailable, url: http://127.0.0.1:8317/v1/responses"}}')
    $recoveredTranscriptRecords=@('{"type":"error","message":"Reconnecting... 1/6 (unexpected status 503 Service Unavailable: upstream temporarily unavailable, url: http://127.0.0.1:8317/v1/responses)"}','{"type":"item.completed","item":{"type":"agent_message","text":"synthetic recovered turn"}}')
    $named8098=@('pool-quota-envelope-classifies-provider-quota','sol-quota-relaunches-ruled-opus-fallback','non-quota-503-stays-owner-dead')
    if($Named8098Control){$named8098=@($Named8098Control)}
    foreach($name in $named8098){
      if($name-ceq'pool-quota-envelope-classifies-provider-quota'){
        # (a) err.log carries the six captured retry lines; (b) err.log is truly empty and only the
        # captured turn.failed transcript carries the envelope; (c) a 429 model_cooldown retry line.
        $cases=@(
          @('errlog-retry-lines',$poolQuotaRetryLines,$null),
          @('empty-errlog-turn-failed-transcript',@(),$poolQuotaTranscriptRecords),
          @('429-model-cooldown',@($modelCooldownRetryLine),$null)
        )
        $failures=@()
        foreach($case in $cases){
          $item=New-Spec "$name-$($case[0])" 'gpt-6.1-sol' 'high' 0 4 'measured'
          if($case[1].Count-gt0){Write-LfLines $item.error $case[1]}else{[IO.File]::WriteAllText($item.error,'')}
          if($null-ne$case[2]){Write-LfLines $item.partial $case[2]}
          $before=Get-CallCount;$result=Invoke-Watchdog $item $item.spec.label;$row=Get-LastHistoryRow
          Write-Output "CONTROL 8098 AC1 case=$($case[0]) errBytes=$((Get-Item -LiteralPath $item.error).Length) partialBytes=$((Get-Item -LiteralPath $item.partial).Length) status=$($result.status) deathSignature=$($row.deathSignature) selected=$($result.harness)/$($result.model)/$($result.effort) placement=$($result.placement) launches=$((Get-CallCount)-$before)"
          if($result.status-cne'RELAUNCHED'-or$row.deathSignature-cne'PROVIDER_QUOTA'){$failures+=($case[0]+': '+$row.deathSignature)}
        }
        Assert-True ($failures.Count-eq0) "pool quota envelope cases did not classify as PROVIDER_QUOTA: $($failures-join', ')"
      }elseif($name-ceq'sol-quota-relaunches-ruled-opus-fallback'){
        $item=New-Spec $name 'gpt-6.1-sol' 'high' 0 4 'measured';Write-LfLines $item.error $poolQuotaRetryLines;Write-LfLines $item.partial $poolQuotaTranscriptRecords
        $before=Get-CallCount;$result=Invoke-Watchdog $item $name
        Assert-Recovery $item $result 'claude-opus-5-5' 'high' 'override-Todd' $before
        $row=Get-LastHistoryRow
        Assert-True ($result.harness-ceq'claude'-and$result.relaunchCount-eq1-and$row.kind-ceq'dispatch'-and$row.harness-ceq'claude'-and$row.deathSignature-ceq'PROVIDER_QUOTA'-and$row.relaunchCount-eq1) "captured sol quota death did not relaunch the ruled Opus fallback as PROVIDER_QUOTA relaunch 1: $($row.deathSignature)"
        Write-Output "CONTROL 8098 AC2 row=4 from=gpt-6.1-sol/high/measured deathSignature=$($row.deathSignature) selected=$($result.harness)/$($result.model)/$($result.effort) placement=$($result.placement) relaunchCount=$($result.relaunchCount) semanticIncrement=$($result.implementationAttemptIncrement) launches=$((Get-CallCount)-$before)"
      }elseif($name-ceq'non-quota-503-stays-owner-dead'){
        # Negative controls: identical classification at df2c60b8 and after.
        $quotedEnvelope='synthetic quoted text: credential_quota; All credentials for model synthetic-model are cooling down'
        $quotedMessage='{"type":"item.completed","item":{"type":"agent_message","text":"'+$quotedEnvelope+'"}}'
        $controls=@(
          @('plain-503',@($plain503RetryLine),$plain503TranscriptRecords,'OWNER_DEAD'),
          @('recovered-retry-beside-exact-line',@('stream disconnected',$plain503RetryLine),$recoveredTranscriptRecords,'STREAM_DISCONNECTED'),
          @('recovered-retry-only',@($plain503RetryLine),$recoveredTranscriptRecords,'OWNER_DEAD'),
          @('no-envelope',@(),$null,'OWNER_DEAD'),
          @('earlier-quota-record-then-completed',@(),@($poolQuotaTranscriptRecords[0],$recoveredTranscriptRecords[1]),'OWNER_DEAD'),
          @('quoted-envelope-then-truncated-final-line',@(),@($quotedMessage,'{"type":"item.completed","item":{"type":"agent_message","text":"synthetic half-writ'),'OWNER_DEAD'),
          @('quoted-envelope-as-final-message',@(),@($quotedMessage),'OWNER_DEAD'),
          @('quoted-envelope-over-16k-tail',@(),@('{"type":"item.completed","item":{"type":"agent_message","text":"'+('synthetic padding '*1100)+$quotedEnvelope+'"}}'),'OWNER_DEAD')
        )
        $failures=@()
        foreach($control in $controls){
          $item=New-Spec "$name-$($control[0])" 'gpt-6.1-sol' 'high' 0 4 'measured'
          if($control[1].Count-gt0){Write-LfLines $item.error $control[1]}
          if($null-ne$control[2]){Write-LfLines $item.partial $control[2]}
          $before=Get-CallCount;$result=Invoke-Watchdog $item $item.spec.label
          $row=Get-LastHistoryRow
          Write-Output "CONTROL 8098 AC3 case=$($control[0]) expected=$($control[3]) status=$($result.status) deathSignature=$($row.deathSignature) selected=$($result.harness)/$($result.model)/$($result.effort) placement=$($result.placement) launches=$((Get-CallCount)-$before)"
          if($row.deathSignature-cne$control[3]){$failures+=($control[0]+': '+$row.deathSignature)}
          if($result.status-ceq'RELAUNCHED'-and$result.model-ceq'gpt-6.1-sol'){Assert-Recovery $item $result 'gpt-6.1-sol' 'high' 'measured' $before}
          else{$failures+=($control[0]+': unexpected recovery route')}
        }
        Assert-True ($failures.Count-eq0) "negative controls changed classification or route: $($failures-join', ')"
      }
    }
    if($Named8098Control){return}
  }
  # Literal compatibility expectations are independent of production routing.
  # The retained v1 grammar still refuses Todd's exact case (review note N1).
  if(-not$BeforeFixControl){
    $placements=@(
      @('v2',15,'measured','LIVE_SLOW'),@('v1',15,'measured','LIVE_SLOW'),
      @('v2',15,'override-Todd','LIVE_SLOW'),@('v1',15,'override-Todd','ROUTING_PROVENANCE_REFUSED'),
      @('v2',7,'override-Todd','LIVE_SLOW'),@('v2',14,'override-Todd','LIVE_SLOW'),
      @('v1',7,'override-Todd','ROUTING_PROVENANCE_REFUSED'),@('v1',14,'override-Todd','ROUTING_PROVENANCE_REFUSED'),
      @('v2',7,'measured','WATCHDOG_UNKNOWN_SPEC_INVALID'),@('v2',14,'measured','WATCHDOG_UNKNOWN_SPEC_INVALID'),
      @('v1',7,'measured','WATCHDOG_UNKNOWN_SPEC_INVALID'),@('v1',14,'measured','WATCHDOG_UNKNOWN_SPEC_INVALID')
    )
    if($Row15MeasuredControl){$placements=@($placements|Where-Object{$_[0]-ceq$Row15MeasuredControl-and$_[1]-eq15-and$_[2]-ceq'measured'})}
    foreach($entry in $placements){
      $label="synthetic-placement-$($entry-join'-')"
      $item=if($entry[0]-ceq'v1'){New-LegacySpec $label 'gpt-6-astra' 'high'}else{New-Spec $label 'gpt-6-astra' 'high' 0 $entry[1] $entry[2]}
      $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName='pwsh';$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardInput=$true
      foreach($arg in @('-NoProfile','-NonInteractive','-Command','[Console]::ReadLine() | Out-Null')){[void]$start.ArgumentList.Add($arg)}
      $owner=[Diagnostics.Process]::Start($start)
      try{
        $item.spec.launcherPid=[long]$owner.Id;$item.spec.childPid=[long]$owner.Id;$item.spec.launcherStartIdentity=$owner.StartTime.ToUniversalTime().ToString('o');$item.spec.childStartIdentity=$item.spec.launcherStartIdentity;Save-Spec $item
        if($entry[0]-ceq'v1'){Add-LegacyRoutingRow $item $entry[1] $entry[2]}
        $before=Get-CallCount;$status='';$value=$null
        try{$value=& $watchdog -Label $label -RuntimeRoot $runtime -HistoryPath $history -DispatchScript $stub -SynchronousDispatch|ConvertFrom-Json -DateKind String;$status=$value.status}
        catch{if($_.Exception.Message-cne'WATCHDOG_UNKNOWN_SPEC_INVALID'){throw};$status=$_.Exception.Message}
        Write-Output "CONTROL 7955 COMPAT schema=$($entry[0]) row=$($entry[1]) model=gpt-6-astra effort=high placement=$($entry[2]) expected=$($entry[3]) actual=$status launches=$((Get-CallCount)-$before) ownerPid=$($owner.Id) ownerStart=$($item.spec.launcherStartIdentity)"
        Assert-True ($status-ceq$entry[3]-and(Get-CallCount)-eq$before) "literal placement compatibility failed: $($entry-join'/') actual=$status"
        if($status-ceq'ROUTING_PROVENANCE_REFUSED'){Assert-True ($value.reason-ceq'MISSING_OR_MISMATCHED'-and$value.candidateCount-eq0-and$value.relaunch-eq$false) 'legacy Todd case guessed provenance'}
      }finally{
        $owner.StandardInput.Close();$owner.WaitForExit();Assert-True ($owner.ExitCode-eq0) 'synthetic placement owner failed normal exit'
        Write-Output "CONTROL 7955 COMPAT_CLEANUP ownerPid=$($owner.Id) exit=$($owner.ExitCode)";$owner.Dispose()
      }
    }
    if($Row15MeasuredControl){return}
  }
  # Real disposable native identities: stdin holds the owner alive, then EOF
  # ends it normally. No observation seam or historical live-lane identity.
  foreach($route in @(7,14,15)){
    $item=New-Spec "synthetic-native-astra-$route" 'gpt-6-astra' 'high' 1 $route 'override-Todd'
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName='pwsh';$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardInput=$true
    foreach($arg in @('-NoProfile','-NonInteractive','-Command','[Console]::ReadLine() | Out-Null')){[void]$start.ArgumentList.Add($arg)}
    $owner=[Diagnostics.Process]::Start($start)
    try{
      $item.spec.launcherPid=[long]$owner.Id;$item.spec.childPid=[long]$owner.Id;$item.spec.launcherStartIdentity=$owner.StartTime.ToUniversalTime().ToString('o');$item.spec.childStartIdentity=$item.spec.launcherStartIdentity;Save-Spec $item
      $before=Get-CallCount
      if($BeforeFixControl){
        $refused=$false;try{& $watchdog -Label $item.spec.label -RuntimeRoot $runtime -HistoryPath $history -DispatchScript $stub -SynchronousDispatch|Out-Null}catch{$refused=$_.Exception.Message-match'WATCHDOG_UNKNOWN_SPEC_INVALID'}
        Assert-True ($refused-and(Get-CallCount)-eq$before) "before-fix row $route did not reproduce schema refusal"
        Write-Output "CONTROL 7955 BEFORE row=$route model=gpt-6-astra effort=high placement=override-Todd status=WATCHDOG_UNKNOWN_SPEC_INVALID launches=0"
      }else{
        $live=& $watchdog -Label $item.spec.label -RuntimeRoot $runtime -HistoryPath $history -DispatchScript $stub -SynchronousDispatch|ConvertFrom-Json -DateKind String
        Assert-True ($live.status-ceq'LIVE_SLOW'-and(Get-CallCount)-eq$before) "native upper-tier row $route did not classify the real live owner"
      }
      $owner.StandardInput.Close();$owner.WaitForExit();Assert-True ($owner.ExitCode-eq0) 'synthetic native owner failed normal exit'
      if(-not$BeforeFixControl){
        Set-Content $item.partial '{"type":"turn.failed","error":{"message":"synthetic model_not_found: unknown provider for model gpt-6-astra"}}'
        $dead=& $watchdog -Label $item.spec.label -RuntimeRoot $runtime -HistoryPath $history -DispatchScript $stub -SynchronousDispatch|ConvertFrom-Json -DateKind String
        Assert-Recovery $item $dead 'gpt-6-astra' 'high' 'override-Todd' $before
        $deathRow=Get-Content $history -Tail 1|ConvertFrom-Json -DateKind String
        Assert-True ($deathRow.deathSignature-ceq'OWNER_DEAD') 'model-not-found transcript changed native envelope classification'
        Write-Output "CONTROL 7955 AFTER row=$route nativeLive=$($live.status) nativeDead=$($dead.status) model=$($dead.model) effort=$($dead.effort) placement=$($dead.placement) relaunchCount=$($dead.relaunchCount) semanticIncrement=$($dead.implementationAttemptIncrement)"
      }
    }finally{if(-not$owner.HasExited){$owner.StandardInput.Close();$owner.WaitForExit()};$owner.Dispose()}
  }
  if($BeforeFixControl){return}
  $childIdentity=Join-Path $runtime 'synthetic-descendant.pid';$childRelease=Join-Path $runtime 'synthetic-descendant.release'
  $childScript=Join-Path $runtime 'synthetic-descendant.ps1';$parentScript=Join-Path $runtime 'synthetic-parent.ps1'
  Set-Content $childScript 'param($Identity,$Release); Set-Content $Identity $PID; while(-not(Test-Path -LiteralPath $Release)){Start-Sleep -Milliseconds 50}'
  Set-Content $parentScript @'
param($ChildScript,$Identity,$Release)
$start=[Diagnostics.ProcessStartInfo]::new();$start.FileName='pwsh';$start.UseShellExecute=$false;$start.CreateNoWindow=$true
foreach($arg in @('-NoProfile','-File',$ChildScript,$Identity,$Release)){[void]$start.ArgumentList.Add($arg)}
$child=[Diagnostics.Process]::Start($start);$child.Dispose()
while(-not(Test-Path -LiteralPath $Identity)){Start-Sleep -Milliseconds 50}
[Console]::ReadLine() | Out-Null
'@
  $parentStart=[Diagnostics.ProcessStartInfo]::new();$parentStart.FileName='pwsh';$parentStart.UseShellExecute=$false;$parentStart.CreateNoWindow=$true;$parentStart.RedirectStandardInput=$true
  foreach($arg in @('-NoProfile','-File',$parentScript,$childScript,$childIdentity,$childRelease)){[void]$parentStart.ArgumentList.Add($arg)}
  $parent=[Diagnostics.Process]::Start($parentStart);$possibleChild=$null
  try{
    $item=New-Spec 'synthetic-native-possible-child' 'gpt-6-astra' 'high' 0 7 'override-Todd'
    $item.spec.launcherPid=[long]$parent.Id;$item.spec.childPid=[long]$parent.Id;$item.spec.launcherStartIdentity=$parent.StartTime.ToUniversalTime().ToString('o');$item.spec.childStartIdentity=$item.spec.launcherStartIdentity;Save-Spec $item
    while(-not(Test-Path $childIdentity)){Assert-True (-not$parent.HasExited) 'synthetic parent exited before child publication';Start-Sleep -Milliseconds 50}
    $possibleChild=Get-Process -Id ([int](Get-Content $childIdentity));$parent.StandardInput.Close();$parent.WaitForExit()
    $before=Get-CallCount;$result=& $watchdog -Label $item.spec.label -RuntimeRoot $runtime -HistoryPath $history -DispatchScript $stub -SynchronousDispatch|ConvertFrom-Json -DateKind String
    Assert-True ($result.status-ceq'OWNERSHIP_UNKNOWN'-and$result.ownerState-ceq'dead'-and$result.descendantState-ceq'possible'-and(Get-CallCount)-eq$before) 'actual dead parent with surviving possible child launched'
    Write-Output 'CONTROL 7955 NATIVE_DESCENDANT owner=dead descendant=possible status=OWNERSHIP_UNKNOWN launches=0'
  }finally{
    Set-Content $childRelease 'synthetic normal exit';if(-not$parent.HasExited){$parent.StandardInput.Close();$parent.WaitForExit()};$parent.Dispose()
    if($possibleChild){$possibleChild.WaitForExit();$possibleChild.Dispose()}
  }
  foreach($route in @(7,14,15)){
    foreach($control in @(@('live','none','LIVE_SLOW'),@('dead','possible','OWNERSHIP_UNKNOWN'),@('ambiguous','none','OWNERSHIP_UNKNOWN'),@('reused','none','OWNERSHIP_UNKNOWN'),@('dead','ambiguous','OWNERSHIP_UNKNOWN'))){
      $item=New-Spec "synthetic-owner-$route-$($control[0])-$($control[1])" 'gpt-6-astra' 'high' 0 $route 'override-Todd';$before=Get-CallCount
      $result=& $watchdog -Label $item.spec.label -RuntimeRoot $runtime -HistoryPath $history -ObservationFixture (New-Observation $item.spec.label $control[0] $control[1]) -DispatchScript $stub -SynchronousDispatch|ConvertFrom-Json -DateKind String
      Assert-True ($result.status-ceq$control[2]-and(Get-CallCount)-eq$before) 'upper-tier route bypassed ownership guard'
    }
    $item=New-Spec "synthetic-ceiling-$route" 'gpt-6-astra' 'high' 3 $route 'override-Todd';$before=Get-CallCount;$result=Invoke-Watchdog $item $item.spec.label
    Assert-True ($result.status-ceq'HARNESS_CEILING'-and$result.implementationAttemptIncrement-eq0-and$result.relaunchCount-eq3-and(Get-CallCount)-eq$before) 'upper-tier route bypassed three-relaunch ceiling'
  }
  foreach($mutation in @(
    @{name='wrong-row';changes=@{row=[long]8}},@{name='wrong-effort';changes=@{effort='medium'}},
    @{name='measured';changes=@{placement='measured'}},@{name='provisional';changes=@{placement='provisional'}},
    @{name='wrong-override';changes=@{placement='override-other'}},@{name='case-override';changes=@{placement='override-todd'}},
    @{name='invalid-grammar';changes=@{placement='override-TODD'}},
    @{name='wrong-harness';changes=@{harness='claude'}},@{name='family-alias';changes=@{model='astra'}},
    @{name='malformed-extra';changes=@{core=$true}},@{name='cross-label';changes=@{label='synthetic-other-label'}},
    @{name='cross-launch';changes=@{launchId=[guid]::NewGuid().ToString()}}
  )){
    foreach($route in @(7,14,15)){
      $item=New-Spec "synthetic-invalid-$route-$($mutation.name)" 'gpt-6-astra' 'high' 0 $route 'override-Todd';$label=$item.spec.label
      foreach($key in $mutation.changes.Keys){$item.spec[$key]=$mutation.changes[$key]}
      [IO.File]::WriteAllText((Join-Path $runtime "watchdog-lane-$label.json"),($item.spec|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
      # These four row-15 spellings were valid before #7955 (F1/F2).
      if($route-eq15-and$mutation.name-in@('measured','provisional','wrong-override','case-override')){
        $before=Get-CallCount;$value=Invoke-Watchdog $item $label
        Assert-Recovery $item $value 'gpt-6-astra' 'high' $item.spec.placement $before
        continue
      }
      $before=Get-CallCount;$refused=$false
      try{& $watchdog -Label $label -RuntimeRoot $runtime -HistoryPath $history -ObservationFixture (New-Observation $label) -DispatchScript $stub -SynchronousDispatch|Out-Null}catch{$refused=$_.Exception.Message-match'WATCHDOG_UNKNOWN_SPEC_(INVALID|OWNER_PATH)'}
      Assert-True ($refused-and(Get-CallCount)-eq$before) "route mutation $route/$($mutation.name) launched"
    }
  }
  foreach($model in @('gpt-6.1-sol','gpt-6.1-sol','gpt-6-luna','claude-sonnet-5-5','claude-opus-5-5')){
    foreach($route in @(7,14,15)){
      # 8063: 7|claude-opus-5-5/high is now the Todd-ruled Sol fallback author (4388/5743533387);
      # this control stays pointed at the unruled 7|claude-opus-5-5/medium spelling instead.
      $effort=if($model-ceq'claude-opus-5-5'-and$route-eq7){'medium'}else{'high'}
      $item=New-Spec "synthetic-lower-tier-$route-$model" $model $effort 0 $route 'override-Todd';$before=Get-CallCount;$refused=$false
      try{Invoke-Watchdog $item $item.spec.label|Out-Null}catch{$refused=$_.Exception.Message-match'WATCHDOG_UNKNOWN_SPEC_INVALID'}
      Assert-True ($refused-and(Get-CallCount)-eq$before) "lower-tier author $route/$model inherited Todd authority"
    }
  }
  foreach($field in @('requestIdentity','head','model','effort','placement','ownershipRecordPath')){
    $item=New-Spec "synthetic-ack-mismatch-$field" 'gpt-6-astra' 'high' 1 7 'override-Todd';$before=Get-CallCount;$beforeRows=@(Get-Content $history).Count
    $env:SYNTHETIC_WATCHDOG_ACK_FIELD=$field;$env:SYNTHETIC_WATCHDOG_ACK_VALUE='synthetic-wrong-identity';$refused=$false
    try{Invoke-Watchdog $item $item.spec.label|Out-Null}catch{$refused=$_.Exception.Message-match'WATCHDOG_START_ACK_(UNKNOWN|OWNER_UNKNOWN)'}
    finally{Remove-Item Env:SYNTHETIC_WATCHDOG_ACK_FIELD;Remove-Item Env:SYNTHETIC_WATCHDOG_ACK_VALUE}
    Assert-True ($refused-and(Get-CallCount)-eq($before+1)-and@(Get-Content $history).Count-eq$beforeRows) "mismatched ack $field recorded recovery"
  }
  Write-Output 'CONTROL 7955 GUARDS routeMutations=36 routeRefusals=32 restoredRow15Acceptances=4 lowerTierMutations=15 acknowledgementMutations=6 unauthorizedLaunches=0 acknowledgementSuccessRows=0'
  foreach($entry in @(@(7,'high'),@(14,'medium'),@(14,'high'),@(15,'high'))){
    foreach($envelope in @('provider quota exceeded','session limit reached')){
      $item=New-RelaunchedContinuation "synthetic-fable-$($entry[0])-$($entry[1])-$($envelope.Replace(' ','-'))" 'claude-fable-5-1' $entry[1] $entry[0] 'override-Todd'
      Set-Content $item.error $envelope;$before=Get-CallCount;$result=Invoke-Watchdog $item $item.spec.label
      Assert-Recovery $item $result 'gpt-6-astra' 'high' 'override-Todd' $before
      Write-Output "CONTROL 7955 FALLBACK row=$($entry[0]) from=claude-fable-5-1/$($entry[1]) envelope=$envelope selected=$($result.model)/$($result.effort) placement=$($result.placement) launches=1"
    }
  }
  # 8063 re-points the former Astra rows-7/14/15 closed-block control: Astra now falls to Fable 5.1
  # under 4388/5743533387, so the unruled primaries are the ruled claude-opus-5-5/high targets at
  # rows 4/7/10. Row 5 now has the independently tested capacity quota move.
  foreach($route in @(4,7,10)){
    foreach($envelope in @('provider quota exceeded','session limit reached')){
      $item=New-Spec "synthetic-opus-blocked-$route-$($envelope.Replace(' ','-'))" 'claude-opus-5-5' 'high' 2 $route 'override-Todd';Set-Content $item.error $envelope
      $before=Get-CallCount;$result=Invoke-Watchdog $item $item.spec.label;$row=Get-Content $history -Tail 1|ConvertFrom-Json -DateKind String
      Assert-True ($result.status-ceq'NO_QUALIFIED_FALLBACK'-and$result.relaunch-eq$false-and$result.relaunchCount-eq2-and$result.implementationAttemptIncrement-eq0-and(Get-CallCount)-eq$before-and$row.kind-ceq'lane-blocked'-and$row.model-ceq'claude-opus-5-5'-and$row.effort-ceq'high'-and$row.row-eq$route-and$row.placement-ceq'override-Todd') 'ruled Opus fallback target invented a further quota move or a lower-tier author'
      Write-Output "CONTROL 8063 NO_FALLBACK row=$route envelope=$envelope status=$($result.status) config=$($row.model)/$($row.effort) placement=$($row.placement) launches=0 semanticIncrement=0"
    }
  }
  # 8063: Todd-ruled vendor fallbacks (4388/5743533387). Each of the eight entries relaunches the
  # exact ruled tuple as override-Todd on any row, and the relaunched tuple round-trips as a
  # supported Todd-authored configuration on its next mechanical death.
  $ruled=@(
    @(7,'gpt-6-astra','claude-fable-5-1'),@(14,'gpt-6-astra','claude-fable-5-1'),@(15,'gpt-6-astra','claude-fable-5-1'),
    @(4,'gpt-6.1-sol','claude-opus-5-5'),@(5,'gpt-6.1-sol','claude-opus-5-5'),@(6,'gpt-6.1-sol','claude-opus-5-5'),@(7,'gpt-6.1-sol','claude-opus-5-5'),@(10,'gpt-6.1-sol','claude-opus-5-5')
  )
  foreach($entry in $ruled){
    $route=$entry[0];$primary=$entry[1];$target=$entry[2];$primaryPlacement=if($primary-ceq'gpt-6-astra'){'override-Todd'}else{'measured'}
    foreach($envelope in @('provider quota exceeded','session limit reached')){
      $tag="$route-$primary-$($envelope.Replace(' ','-'))"
      $item=New-Spec "synthetic-ruled-$tag" $primary 'high' 0 $route $primaryPlacement;Set-Content $item.error $envelope
      $before=Get-CallCount;$result=Invoke-Watchdog $item $item.spec.label
      Assert-Recovery $item $result $target 'high' 'override-Todd' $before
      Assert-True ($result.harness-ceq'claude') "ruled fallback $tag did not select the claude harness"
      $again=New-Spec "synthetic-ruled-roundtrip-$tag" $target 'high' 1 $route 'override-Todd';$before=Get-CallCount;$roundTrip=Invoke-Watchdog $again $again.spec.label
      Assert-Recovery $again $roundTrip $target 'high' 'override-Todd' $before
      Write-Output "CONTROL 8063 FALLBACK row=$route from=$primary/high/$primaryPlacement envelope=$envelope selected=$($result.harness)/$($result.model)/$($result.effort) placement=$($result.placement) roundTrip=$($roundTrip.status) launches=2"
    }
  }
  # 8063: the pre-existing entries keep their Codex fallback and row-derived placement.
  foreach($entry in @(@(4,'gpt-6.1-sol','medium'),@(5,'gpt-6.1-sol','xhigh'),@(6,'claude-opus-5-5','high'),@(10,'gpt-6-astra','high'))){
    $item=New-Spec "synthetic-retained-$($entry[0])-$($entry[1])-$($entry[2])" $entry[1] $entry[2] 0 $entry[0] 'measured';Set-Content $item.error 'provider quota exceeded'
    $before=Get-CallCount;$result=Invoke-Watchdog $item $item.spec.label;Assert-Recovery $item $result 'gpt-6.1-sol' 'high' 'provisional' $before
    Write-Output "CONTROL 8063 RETAINED row=$($entry[0]) from=$($entry[1])/$($entry[2]) selected=$($result.harness)/$($result.model)/$($result.effort) placement=$($result.placement)"
  }
  # 8063: the relaunched claude-opus-5-5/high targets are supported at rows 4/5/7/10 as measured and
  # as override-Todd (row 6 measured is in the existing accepted table); nothing else widened.
  foreach($entry in @(@(4,'measured'),@(4,'override-Todd'),@(5,'measured'),@(5,'override-Todd'),@(6,'override-Todd'),@(7,'measured'),@(7,'override-Todd'),@(10,'measured'),@(10,'override-Todd'))){
    $name="accepted-8063-$($entry[0])-claude-opus-5-5-high-$($entry[1])";$item=New-Spec $name 'claude-opus-5-5' 'high' 0 $entry[0] $entry[1]
    $value=& $watchdog -Label $name -RuntimeRoot $runtime -HistoryPath $history -TranscriptPath $item.partial -ObservationFixture (New-Observation $name 'live' 'none') -DispatchScript $stub -SynchronousDispatch|ConvertFrom-Json -DateKind String
    Assert-True ($value.status-ceq'LIVE_SLOW') "8063 supported Opus route rejected: $($entry-join'/')"
  }
  foreach($entry in @(
    @(4,'gpt-6.1-sol','high'),@(5,'gpt-6.1-sol','high'),@(6,'gpt-6.1-sol','high'),@(7,'gpt-6.1-sol','high'),@(10,'gpt-6.1-sol','high'),
    @(4,'gpt-6-astra','high'),@(5,'gpt-6-astra','high'),@(6,'gpt-6-astra','high'),@(10,'gpt-6-astra','high'),
    @(3,'claude-sonnet-5-5','high'),@(13,'claude-sonnet-5-5','high'),
    @(2,'claude-opus-5-5','high'),@(3,'claude-opus-5-5','max'),@(13,'claude-opus-5-5','high'),@(4,'claude-opus-5-5','low'),@(10,'claude-opus-5-5','xhigh'),
    @(4,'claude-fable-5-1','high'),@(10,'claude-fable-5-1','high')
  )){
    $item=New-Spec "synthetic-8063-unauthored-$($entry[0])-$($entry[1])-$($entry[2])" $entry[1] $entry[2] 0 $entry[0] 'override-Todd';$before=Get-CallCount;$refused=$false
    try{Invoke-Watchdog $item $item.spec.label|Out-Null}catch{$refused=$_.Exception.Message-match'WATCHDOG_UNKNOWN_SPEC_INVALID'}
    Assert-True ($refused-and(Get-CallCount)-eq$before) "override-Todd admitted outside the extended Todd-authored table: $($entry-join'/')"
  }
  Write-Output 'CONTROL 8063 GUARDS ruledEntries=8 ruledRelaunches=16 roundTrips=16 retainedCodexFallbacks=4 opusClosedBlocks=8 opusAcceptances=9 unauthoredRefusals=19 unauthorizedLaunches=0'
  # An integration watchdog retry retains its selected author, so a v3 integration lane at
  # 7|gpt-6-astra/high dying on PROVIDER_QUOTA closes NO_QUALIFIED_FALLBACK (exit 0, one retained spec,
  # no launch) exactly as a missing entry does, while the same spec without an integration target
  # takes the ruled claude/claude-fable-5-1/high/override-Todd relaunch.
  $integrationLabel='synthetic-8063-integration-astra-quota';$integrationItem=New-Spec $integrationLabel 'gpt-6-astra' 'high' 0 7 'override-Todd';Set-Content $integrationItem.error 'provider quota exhausted'
  $integrationItem.spec.schemaVersion='watchdog-lane/v3'
  $integrationItem.spec['integrationRequest']=[ordered]@{schemaVersion='integration-dispatch-request/v1';requestIdentity=('c'*64);repository='synthetic/8063';pr=[long]908063;landedPr=[long]908062;landedHead=('a'*40);head=[string]$integrationItem.spec.head;newBase=('b'*40);branch=[string]$integrationItem.spec.branch;worktree=$worktree;label=$integrationLabel;sourceIdentity='ABSENT_REVIEW_REQUIRED';sourceHead='';runtimeRoot=$runtime;historyPath=$history}
  Save-Spec $integrationItem
  $before=Get-CallCount;$beforeSpecs=@(Get-ChildItem $runtime -Filter 'watchdog-lane-*.json').Count;$beforeRows=@(Get-Content $history).Count
  $integrationOutput=@(& pwsh -NoProfile -NonInteractive -File $watchdog -Label $integrationLabel -RuntimeRoot $runtime -HistoryPath $history -TranscriptPath $integrationItem.partial -ObservationFixture (New-Observation $integrationLabel) -DispatchScript $stub -SynchronousDispatch)-join"`n";$integrationExit=$LASTEXITCODE
  Assert-True ($integrationExit-eq0-and$integrationOutput.Contains('NO_QUALIFIED_FALLBACK')) "v3 integration Astra quota death did not close NO_QUALIFIED_FALLBACK with exit 0: exit=$integrationExit output=$integrationOutput"
  $integrationResult=$integrationOutput|ConvertFrom-Json -DateKind String;$integrationRow=Get-Content $history -Tail 1|ConvertFrom-Json -DateKind String
  Assert-True ($integrationResult.schemaVersion-ceq'watchdog-observation-result/v1'-and$integrationResult.status-ceq'NO_QUALIFIED_FALLBACK'-and$integrationResult.relaunch-eq$false-and$integrationResult.relaunchCount-eq0-and$integrationResult.implementationAttemptIncrement-eq0-and$integrationResult.row-eq7-and$integrationResult.model-ceq'gpt-6-astra'-and$integrationResult.effort-ceq'high') 'v3 integration closed block changed the NO_QUALIFIED_FALLBACK payload'
  Assert-True ((Get-CallCount)-eq$before-and@(Get-Content $history).Count-eq($beforeRows+1)-and$integrationRow.kind-ceq'lane-blocked'-and$integrationRow.outcome-ceq'NO_QUALIFIED_FALLBACK'-and$integrationRow.deathSignature-ceq'PROVIDER_QUOTA'-and$integrationRow.harness-ceq'codex'-and$integrationRow.model-ceq'gpt-6-astra'-and$integrationRow.effort-ceq'high'-and$integrationRow.row-eq7-and$integrationRow.placement-ceq'override-Todd'-and$integrationRow.relaunchCount-eq0) 'v3 integration closed block launched or lost the lane-blocked row shape'
  $retainedSpec=Get-Content -LiteralPath (Join-Path $runtime "watchdog-lane-$integrationLabel.json") -Raw|ConvertFrom-Json -DateKind String
  Assert-True (@(Get-ChildItem $runtime -Filter 'watchdog-lane-*.json').Count-eq$beforeSpecs-and@(Get-ChildItem $runtime -Filter "watchdog-lane-$integrationLabel*.json").Count-eq1-and$retainedSpec.schemaVersion-ceq'watchdog-lane/v3'-and$retainedSpec.integrationRequest.label-ceq$integrationLabel) 'v3 integration closed block wrote a second watchdog-lane spec or rewrote the retained native spec'
  $mirrorItem=New-Spec 'synthetic-8063-ordinary-astra-quota' 'gpt-6-astra' 'high' 0 7 'override-Todd';Set-Content $mirrorItem.error 'provider quota exhausted'
  $before=Get-CallCount;$mirrorResult=Invoke-Watchdog $mirrorItem $mirrorItem.spec.label
  Assert-Recovery $mirrorItem $mirrorResult 'claude-fable-5-1' 'high' 'override-Todd' $before
  Assert-True ($mirrorResult.harness-ceq'claude') 'ordinary Astra quota death did not select the claude harness'
  Write-Output "CONTROL 8063 INTEGRATION_AUTHOR v3Integration=$($integrationResult.status) exit=$integrationExit specs=1 launches=0 ordinary=$($mirrorResult.status) selected=$($mirrorResult.harness)/$($mirrorResult.model)/$($mirrorResult.effort) placement=$($mirrorResult.placement) launches=1"
  $fableLabel='synthetic-8119-integration-fable-retry';$fableItem=New-Spec $fableLabel 'claude-fable-5-1' 'high' 0 7 'override-Todd'
  $fableItem.spec.head=$nativeHead;$fableItem.spec.schemaVersion='watchdog-lane/v3'
  $fableItem.spec['integrationRequest']=[ordered]@{schemaVersion='integration-dispatch-request/v1';requestIdentity=('d'*64);repository=$SyntheticIntegrationRepository;pr=[long]908132;landedPr=[long]908131;landedHead=('a'*40);head=$nativeHead;newBase=$nativeHead;branch='synthetic/branch';worktree=$worktree;label=$fableLabel;sourceIdentity='ABSENT_REVIEW_REQUIRED';sourceHead='';runtimeRoot=$runtime;historyPath=$history}
  Save-Spec $fableItem
  $before=Get-CallCount
  $fableRetry=& $watchdog -Label $fableLabel -RuntimeRoot $runtime -HistoryPath $history -TranscriptPath $fableItem.partial -ObservationFixture (New-Observation $fableLabel) -IntegrationAuthorityFixturePath $api -DispatchScript $stub -SynchronousDispatch|ConvertFrom-Json -DateKind String
  Assert-True ($fableRetry.status-ceq'RELAUNCHED'-and$fableRetry.harness-ceq'claude'-and$fableRetry.model-ceq'claude-fable-5-1'-and(Get-CallCount)-eq($before+1)) 'Fable integration same-author retry failed'
  $fablePrompt=Get-Content -LiteralPath (Join-Path $runtime "$($fableRetry.label).prompt.txt") -Raw
  Assert-True ($fablePrompt.Contains('Author: claude/claude-fable-5-1/high/row7/override-Todd.')) 'Fable integration retry prompt named a different author'
  Write-Output 'CONTROL 8119 watchdog Fable same-author prompt PASS'
  $early=New-Spec 'early-confirmed';$earlyResult=& $watchdog -Label early-confirmed -RuntimeRoot $runtime -HistoryPath $history -TranscriptPath $early.partial -ObservationFixture (New-Observation 'early-confirmed' 'dead' 'none' 1) -DispatchScript $stub -SynchronousDispatch|ConvertFrom-Json -DateKind String
  Assert-True ($earlyResult.status-ceq'RELAUNCHED'-and$earlyResult.elapsedSeconds-lt5) 'early confirmed mechanical death waited for a minimum delay'
  foreach($old in @(@('gpt-5.6-sol','high',4),@('gpt-5.6-terra','medium',2),@('gpt-5.6-luna','medium',2),@('claude-opus-5','high',6),@('claude-sonnet-5','medium',3),@('claude-sonnet-5','medium',13),@('claude-sonnet-5','high',10),@('gpt-6-sol','high',4),@('gpt-6-sol','xhigh',5),@('gpt-6-sol','medium',13),@('gpt-6-sol','medium',2))){
    $name="retired-$($old[0])-$($old[2])";$item=New-Spec $name $old[0] $old[1] 0 $old[2] 'measured';$before=Get-CallCount
    $hash=(Get-FileHash $item.partial).Hash
    $live=& $watchdog -Label $name -RuntimeRoot $runtime -HistoryPath $history -TranscriptPath $item.partial -ObservationFixture (New-Observation $name 'live' 'none') -DispatchScript $stub -SynchronousDispatch|ConvertFrom-Json
    Assert-True ($live.status-ceq'LIVE_SLOW'-and(Get-CallCount)-eq$before) 'migration interfered with a live predecessor'
    $dead=Invoke-Watchdog $item "$name-dead"
    Assert-True ($dead.status-ceq'RETIRED_MODEL_REQUIRES_REDISPATCH'-and$dead.model-ceq$old[0]-and-not$dead.relaunch-and(Get-CallCount)-eq$before-and(Get-FileHash $item.partial).Hash-ceq$hash) 'retired worker was relaunched, relabeled, or changed'
  }
  $ruledOld=New-Spec 'historical-opus-todd-placement' 'claude-opus-5' high 0 4 override-Todd
  $result=Invoke-Watchdog $ruledOld $ruledOld.spec.label
  Assert-True ($result.status-ceq'RETIRED_MODEL_REQUIRES_REDISPATCH'-and-not$result.relaunch) 'historical Todd placement lost predecessor refusal'
  Test-SonnetCutover
  Test-ExplicitRoutingRelaunch
  Test-PolicyFallback
  Test-PolicyFallbackMutants
  $same=New-Spec 'same-config';$sameResult=Invoke-Watchdog $same 'same';Assert-True ($sameResult.status-ceq'RELAUNCHED'-and$sameResult.model-ceq'gpt-6.1-sol'-and$sameResult.effort-ceq'high') 'dead owner was not relaunched same-config'
  $beforeDuplicate=@(Get-Content -LiteralPath $calls).Count;$duplicate=Invoke-Watchdog $same 'same-duplicate';Assert-True ($duplicate.status-ceq'DUPLICATE_SKIPPED'-and@(Get-Content -LiteralPath $calls).Count-eq$beforeDuplicate) 'confirmed relaunch was not duplicate-suppressed'
  $prose=New-Spec 'prose-quota' 'gpt-6-astra' 'high';Set-Content -LiteralPath $prose.partial -Value 'unmistakably synthetic task prose discusses quota policy';$proseResult=Invoke-Watchdog $prose 'prose-quota';Assert-True ($proseResult.status-ceq'RELAUNCHED'-and$proseResult.model-ceq'gpt-6-astra') 'ordinary report prose authorized provider fallback'
  $quota=New-Spec 'quota-fallback' 'gpt-6-astra' 'high';Set-Content -LiteralPath $quota.error -Value 'provider quota exceeded';$quotaResult=Invoke-Watchdog $quota 'quota';Assert-True ($quotaResult.status-ceq'RELAUNCHED'-and$quotaResult.model-ceq'gpt-6.1-sol') 'exact provider envelope did not use the row-qualified fallback'
  $legacySame=New-LegacySpec 'legacy-v261-same';Add-LegacyRoutingRow $legacySame 4;$legacySameResult=Invoke-Watchdog $legacySame 'legacy-v261-same';Assert-True ($legacySameResult.status-ceq'RELAUNCHED'-and$legacySameResult.row-eq4-and$legacySameResult.model-ceq'gpt-6.1-sol') 'exact predecessor v1 spec did not recover a unique same-config canonical route'
  $legacyQuota=New-LegacySpec 'legacy-v261-quota' 'gpt-6-astra' 'high';Set-Content -LiteralPath $legacyQuota.error -Value 'provider quota exceeded';Add-LegacyRoutingRow $legacyQuota 4;$legacyQuotaResult=Invoke-Watchdog $legacyQuota 'legacy-v261-quota';Assert-True ($legacyQuotaResult.status-ceq'RELAUNCHED'-and$legacyQuotaResult.row-eq4-and$legacyQuotaResult.model-ceq'gpt-6.1-sol') 'exact predecessor v1 spec did not preserve row-qualified quota routing'
  foreach($legacyControl in @(
    [ordered]@{name='zero';rows=@()},
    [ordered]@{name='multiple';rows=@(@{},@{})},
    [ordered]@{name='wrong-head';rows=@(@{head=('b'*40)})},
    [ordered]@{name='wrong-attempt';rows=@(@{attemptId='synthetic-other-attempt'})},
    [ordered]@{name='wrong-config';rows=@(@{model='gpt-6-astra'})}
  )){
    $legacyItem=New-LegacySpec "legacy-v261-$($legacyControl.name)";$beforeLegacyCalls=@(Get-Content -LiteralPath $calls).Count
    foreach($changes in $legacyControl.rows){Add-LegacyRoutingRow $legacyItem 4 'measured' $changes}
    $legacyResult=Invoke-Watchdog $legacyItem "legacy-v261-$($legacyControl.name)"
    Assert-True ($legacyResult.status-ceq'ROUTING_PROVENANCE_REFUSED'-and$legacyResult.relaunch-eq$false-and@(Get-Content -LiteralPath $calls).Count-eq$beforeLegacyCalls) "legacy $($legacyControl.name) routing evidence guessed a route or relaunched"
  }
  Write-Output 'CONTROL F11 legacyV1 sameConfig=RELAUNCHED quota=row4-qualified refusals=zero,multiple,wrong-head,wrong-attempt,wrong-config refusal=ROUTING_PROVENANCE_REFUSED relaunches=0'
  # 8063 re-points the former sol-quota-blocked control: 4|gpt-6.1-sol/high now falls to claude-opus-5-5/high
  # under 4388/5743533387, so the unruled primary is 2|gpt-6.1-sol/medium.
  $noFallback=New-Spec 'terra-quota-blocked' 'gpt-6.1-sol' 'medium' 0 2;Set-Content -LiteralPath $noFallback.error -Value 'provider quota exceeded';$blocked=Invoke-Watchdog $noFallback 'terra-quota-blocked';Assert-True ($blocked.status-ceq'NO_QUALIFIED_FALLBACK'-and$blocked.relaunch-eq$false-and$blocked.relaunchCount-eq0-and$blocked.row-eq2-and$blocked.model-ceq'gpt-6.1-sol'-and$blocked.effort-ceq'medium') 'Terra/medium row-2 quota death did not close blocked'
  $failure=New-Spec 'launch-failure';$env:SYNTHETIC_WATCHDOG_FAIL_LABEL='launch-failure.wd1.';$beforeRows=if(Test-Path $history){@(Get-Content $history).Count}else{0};$failedOne=Invoke-Watchdog $failure 'launch-failure-one';$failedTwo=Invoke-Watchdog $failure 'launch-failure-two';$afterRows=if(Test-Path $history){@(Get-Content $history).Count}else{0};Assert-True ($failedOne.status-ceq'LAUNCH_FAILED'-and$failedTwo.status-ceq'LAUNCH_FAILED'-and$beforeRows-eq$afterRows-and$failedOne.relaunchCount-eq0-and$failedTwo.relaunchCount-eq0) 'failed launcher consumed identity/count';Remove-Item Env:SYNTHETIC_WATCHDOG_FAIL_LABEL
  $ceiling=New-Spec 'ceiling' 'gpt-6.1-sol' 'high' 3;$ceilingResult=Invoke-Watchdog $ceiling 'ceiling';Assert-True ($ceilingResult.status-ceq'HARNESS_CEILING'-and$ceilingResult.implementationAttemptIncrement-eq0) 'fourth death did not block at ceiling'
  foreach($control in @([ordered]@{name='live-slow';owner='live';desc='none';status='LIVE_SLOW'},[ordered]@{name='possible-child';owner='dead';desc='possible';status='OWNERSHIP_UNKNOWN'},[ordered]@{name='reused-pid';owner='reused';desc='none';status='OWNERSHIP_UNKNOWN'},[ordered]@{name='ambiguous-child';owner='dead';desc='ambiguous';status='OWNERSHIP_UNKNOWN'})){$item=New-Spec $control.name;$count=@(Get-Content $calls).Count;$result=& $watchdog -Label $control.name -RuntimeRoot $runtime -HistoryPath $history -TranscriptPath $item.partial -ObservationFixture (New-Observation $control.name $control.owner $control.desc) -DispatchScript $stub -SynchronousDispatch|ConvertFrom-Json -DateKind String;Assert-True ($result.status-ceq$control.status-and@(Get-Content $calls).Count-eq$count) "$($control.name) was relaunched"}
  $success=New-Spec 'terminal-success';$success.spec.exitCode=[long]0;[IO.File]::WriteAllText((Join-Path $runtime 'watchdog-lane-terminal-success.json'),($success.spec|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false));$successCount=@(Get-Content $calls).Count;$successResult=& $watchdog -Label terminal-success -RuntimeRoot $runtime -HistoryPath $history -TranscriptPath $success.partial -ObservationFixture (New-Observation 'terminal-success') -DispatchScript $stub -SynchronousDispatch|ConvertFrom-Json -DateKind String;Assert-True ($successResult.status-ceq'TERMINAL_SUCCESS'-and@(Get-Content $calls).Count-eq$successCount) 'terminal success relaunched'
  $deadline=New-Spec 'deadline';$deadlineResult=& $watchdog -Label deadline -RuntimeRoot $runtime -HistoryPath $history -TranscriptPath $deadline.partial -ObservationFixture (New-Observation 'deadline' 'dead' 'none' 300) -DispatchScript $stub -SynchronousDispatch|ConvertFrom-Json -DateKind String;Assert-True ($deadlineResult.status-ceq'RELAUNCHED'-and$deadlineResult.elapsedSeconds-eq300) 'exact deadline refused'
  $stale=New-Spec 'stale-window';$staleFailed=$false;try{& $watchdog -Label stale-window -RuntimeRoot $runtime -HistoryPath $history -TranscriptPath $stale.partial -ObservationFixture (New-Observation 'stale-window' 'dead' 'none' 301) -DispatchScript $stub -SynchronousDispatch|Out-Null}catch{$staleFailed=$_.Exception.Message-match'WINDOW_EXPIRED'};Assert-True $staleFailed 'stale observation admitted'
  $wrong=New-Spec 'partial-identity';$other=Join-Path $runtime 'other.jsonl';Set-Content $other 'unrelated';$partialFailed=$false;try{& $watchdog -Label partial-identity -RuntimeRoot $runtime -HistoryPath $history -TranscriptPath $other -ObservationFixture (New-Observation 'partial') -DispatchScript $stub -SynchronousDispatch|Out-Null}catch{$partialFailed=$_.Exception.Message-match'UNKNOWN_PARTIAL'};Assert-True $partialFailed 'wrong partial admitted'
  $accepted=@(
    @(2,'gpt-6.1-sol','medium','measured'),@(2,'gpt-6-luna','medium','measured'),@(3,'claude-sonnet-5-5','medium','override-Todd'),
    @(4,'gpt-6.1-sol','high','measured'),@(4,'gpt-6-astra','high','measured'),@(4,'gpt-6.1-sol','medium','measured'),
    @(5,'gpt-6.1-sol','high','measured'),@(5,'gpt-6-astra','high','measured'),@(5,'gpt-6.1-sol','xhigh','measured'),
    @(6,'claude-opus-5-5','high','measured'),@(6,'gpt-6-astra','high','measured'),@(6,'gpt-6.1-sol','high','measured'),
    @(7,'gpt-6.1-sol','high','measured'),@(7,'claude-fable-5-1','high','measured'),
    @(10,'gpt-6.1-sol','high','measured'),@(10,'gpt-6-astra','high','measured'),@(10,'claude-sonnet-5-5','high','override-Todd'),
    @(13,'claude-sonnet-5-5','medium','override-Todd'),@(14,'claude-fable-5-1','medium','measured'),@(14,'claude-fable-5-1','high','measured'),
    @(15,'claude-fable-5-1','high','measured'),@(15,'gpt-6-astra','high','measured'),@(15,'gpt-6-astra','high','override-Todd'),
    @(7,'gpt-6-astra','high','override-Todd'),@(14,'gpt-6-astra','high','override-Todd')
  )
  foreach($entry in $accepted){$name="accepted-$($entry-join'-')";$item=New-Spec $name $entry[1] $entry[2] 0 $entry[0] $entry[3];$value=& $watchdog -Label $name -RuntimeRoot $runtime -HistoryPath $history -TranscriptPath $item.partial -ObservationFixture (New-Observation $name 'live' 'none') -DispatchScript $stub -SynchronousDispatch|ConvertFrom-Json -DateKind String;Assert-True ($value.status-ceq'LIVE_SLOW') "accepted route rejected: $($entry-join'/')"}
  $constantSource=Get-Content -LiteralPath $watchdog -Raw
  $constantNeedle="'7|sol/high',"
  Assert-True (([regex]::Matches($constantSource,[regex]::Escape($constantNeedle))).Count-eq1) 'watchdog compatibility constant route anchor is not unique'
  $constantMutantRoot=Join-Path $root 'mutant-watchdog-constant';New-Item -ItemType Directory -Path $constantMutantRoot|Out-Null
  Get-ChildItem $PSScriptRoot -File|Where-Object Extension -in @('.ps1','.psm1')|Copy-Item -Destination $constantMutantRoot
  New-Item -ItemType Directory -Force -Path (Join-Path $constantMutantRoot 'controller-skills/model-routing')|Out-Null
  Copy-Item (Join-Path $PSScriptRoot 'controller-skills/model-routing/capability-matrix.json') (Join-Path $constantMutantRoot 'controller-skills/model-routing/capability-matrix.json')
  $constantMutant=Join-Path $constantMutantRoot 'lane-stall-watchdog.ps1'
  [IO.File]::WriteAllText($constantMutant,$constantSource.Replace($constantNeedle,''),[Text.UTF8Encoding]::new($false))
  $constantCase=New-Spec 'constant-route-deletion' 'gpt-6.1-sol' 'high' 0 7 'provisional'
  $constantFailed=$false
  try { & $constantMutant -Label $constantCase.spec.label -RuntimeRoot $runtime -HistoryPath $history -TranscriptPath $constantCase.partial -ObservationFixture (New-Observation 'constant-route-deletion' 'live' 'none') -DispatchScript $stub -SynchronousDispatch|Out-Null } catch { $constantFailed=$_.Exception.Message-match'WATCHDOG_UNKNOWN_SPEC_INVALID' }
  Assert-True $constantFailed 'deleting a frozen watchdog compatibility route survived'
  Write-Output 'MUTANT watchdog-constant-route RED (7|sol/high deletion rejected)'
  $ordinary=New-Spec 'synthetic-row7-ordinary' 'gpt-6.1-sol' 'high' 0 7 'provisional';$before=Get-CallCount;$ordinaryResult=Invoke-Watchdog $ordinary 'ordinary';Assert-Recovery $ordinary $ordinaryResult 'gpt-6.1-sol' 'high' 'provisional' $before
  $invalid=New-Spec 'unqualified-cross-row' 'gpt-6.1-sol' 'medium' 0 7;$invalidFailed=$false;try{& $watchdog -Label unqualified-cross-row -RuntimeRoot $runtime -HistoryPath $history -TranscriptPath $invalid.partial -ObservationFixture (New-Observation 'unqualified' 'live' 'none') -DispatchScript $stub -SynchronousDispatch|Out-Null}catch{$invalidFailed=$_.Exception.Message-match'UNKNOWN_SPEC_INVALID'};Assert-True $invalidFailed 'unqualified cross-row config accepted'
  Write-Output 'PASS watchdog v2 closure, uniquely bound v2.61 routing adapter, provider-envelope-only classification, exhaustive row/config admission, qualified fallback or closed block, acknowledged exact-once relaunch, retryable launch failure, ceiling, live-slow, reused-PID, descendant, partial, and deadline controls'
}finally{
  Remove-Item Env:SYNTHETIC_WATCHDOG_CALLS -ErrorAction SilentlyContinue;Remove-Item Env:SYNTHETIC_WATCHDOG_FAIL_LABEL -ErrorAction SilentlyContinue
  Remove-Item Env:SYNTHETIC_WATCHDOG_ACK_FIELD -ErrorAction SilentlyContinue;Remove-Item Env:SYNTHETIC_WATCHDOG_ACK_VALUE -ErrorAction SilentlyContinue
  $resolved=[IO.Path]::GetFullPath($root);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/');if((Split-Path -Parent $resolved).TrimEnd('\','/')-ne$temp-or(Split-Path -Leaf $resolved)-notlike'lane-watchdog-test-*'){throw "unsafe cleanup $resolved"};Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
}

. (Join-Path $PSScriptRoot 'interrupted-integration-test-support.ps1')
Test-7963ResumeCarrier 'watchdog'
} finally {
  Exit-RoutingDataTestScope $routingTestScope
}
