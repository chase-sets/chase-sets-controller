param([switch]$BeforeFixControl,[ValidateSet('v2','v1')][string]$Row15MeasuredControl)
$ErrorActionPreference='Stop'
$root=Join-Path ([IO.Path]::GetTempPath()) ('lane-watchdog-test-'+[guid]::NewGuid().ToString('N'))
$runtime=Join-Path $root 'runtime';$worktree=Join-Path $root 'worktree';$history=Join-Path $runtime 'history.jsonl';$calls=Join-Path $runtime 'calls.txt'
$watchdog=Join-Path $PSScriptRoot 'lane-stall-watchdog.ps1'
function Assert-True($Condition,[string]$Message){if(-not$Condition){throw "ASSERTION FAILED: $Message"}}
function Get-Harness([string]$Model){if($Model-like'claude-*'){'claude'}else{'codex'}}
function New-Spec([string]$Label,[string]$Model='gpt-5.6-sol',[string]$Effort='high',[int]$Count=0,[int]$Row=4,[string]$Placement='measured'){
  $partial=Join-Path $runtime "$Label.jsonl";$error=Join-Path $runtime "$Label.err.log";Set-Content -LiteralPath $partial -Value 'unmistakably synthetic partial report';Set-Content -LiteralPath $error -Value 'native owner ended'
  $launchId=[guid]::NewGuid().ToString()
  $spec=[ordered]@{schemaVersion='watchdog-lane/v2';label=$Label;attemptId='synthetic-semantic-attempt';relaunchCount=[long]$Count;resumeOfLaunchId=$null;harness=(Get-Harness $Model);model=$Model;effort=$Effort;row=[long]$Row;placement=$Placement;laneRole='implementation';originalPromptPath=(Join-Path $runtime 'original.prompt.txt');partialReportPath=$partial;errorPath=$error;worktree=$worktree;branch='synthetic/branch';head=('a'*40);launchId=$launchId;ownershipRecordPath=(Join-Path $runtime "dispatch-launch-$launchId.json");launcherPid=[long]999991;launcherStartIdentity='2000-01-01T00:00:00.0000000Z';childPid=[long]999992;childStartIdentity='2000-01-01T00:00:01.0000000Z';state='exited';exitCode=[long]1;updatedAt=[datetimeoffset]::UtcNow.AddMinutes(-1).ToString('o')}
  $path=Join-Path $runtime "watchdog-lane-$Label.json";[IO.File]::WriteAllText($path,($spec|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false));[pscustomobject]@{spec=$spec;partial=$partial;error=$error}
}
function New-LegacySpec([string]$Label,[string]$Model='gpt-5.6-sol',[string]$Effort='high'){
  $item=New-Spec $Label $Model $Effort;$item.spec.schemaVersion='watchdog-lane/v1';$item.spec.Remove('row');$item.spec.Remove('placement')
  [IO.File]::WriteAllText((Join-Path $runtime "watchdog-lane-$Label.json"),($item.spec|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false));$item
}
function Add-LegacyRoutingRow($Item,[int]$Row=4,[string]$Placement='measured',[hashtable]$Changes=@{}){
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
try{
  New-Item -ItemType Directory -Path $runtime,$worktree|Out-Null;Set-Content -LiteralPath (Join-Path $runtime 'original.prompt.txt') -Value 'unmistakably synthetic original'
  $stub=Join-Path $root 'dispatch-lane.ps1';Set-Content -LiteralPath $stub -Value @'
param($Harness,$Model,$Effort,$Row,$Placement,$LaneRole,$PromptFile,$Worktree,$Label,$SemanticAttemptId,$WatchdogRelaunchCount,$ResumeOfLaunchId,$StartRequestIdentity,$StartAcknowledgementPath)
Add-Content -LiteralPath $env:SYNTHETIC_WATCHDOG_CALLS -Value "$Label|$Harness|$Model|$Effort|$Row|$Placement|$SemanticAttemptId|$WatchdogRelaunchCount|$ResumeOfLaunchId"
if($env:SYNTHETIC_WATCHDOG_FAIL_LABEL-and$Label-like"$($env:SYNTHETIC_WATCHDOG_FAIL_LABEL)*"){exit 19}
$launchId=[guid]::NewGuid().ToString();$owner=Join-Path (Split-Path -Parent $StartAcknowledgementPath) "dispatch-launch-$launchId.json"
$ack=[ordered]@{schemaVersion='dispatch-start-ack/v1';requestIdentity=$StartRequestIdentity;label=$Label;launchId=$launchId;ownershipRecordPath=$owner;worktree=[IO.Path]::GetFullPath($Worktree).TrimEnd('\','/');branch='synthetic/branch';head=('a'*40);harness=$Harness;model=$Model;effort=$Effort;row=[long]$Row;placement=$Placement;state='started';childPid=[long]$PID;childStartIdentity=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')}
if($env:SYNTHETIC_WATCHDOG_ACK_FIELD){$ack[$env:SYNTHETIC_WATCHDOG_ACK_FIELD]=$env:SYNTHETIC_WATCHDOG_ACK_VALUE}
[IO.File]::WriteAllText($StartAcknowledgementPath,($ack|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false));exit 0
'@
  $env:SYNTHETIC_WATCHDOG_CALLS=$calls
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
  foreach($model in @('gpt-5.6-sol','gpt-5.6-terra','gpt-5.6-luna','claude-sonnet-5','claude-opus-5')){
    foreach($route in @(7,14,15)){
      $item=New-Spec "synthetic-lower-tier-$route-$model" $model 'high' 0 $route 'override-Todd';$before=Get-CallCount;$refused=$false
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
      $item=New-Spec "synthetic-fable-$($entry[0])-$($entry[1])-$($envelope.Replace(' ','-'))" 'claude-fable-5-1' $entry[1] 1 $entry[0] 'override-Todd'
      Set-Content $item.error $envelope;$before=Get-CallCount;$result=Invoke-Watchdog $item $item.spec.label
      Assert-Recovery $item $result 'gpt-6-astra' 'high' 'override-Todd' $before
      Write-Output "CONTROL 7955 FALLBACK row=$($entry[0]) from=claude-fable-5-1/$($entry[1]) envelope=$envelope selected=$($result.model)/$($result.effort) placement=$($result.placement) launches=1"
    }
  }
  foreach($route in @(7,14,15)){
    foreach($envelope in @('provider quota exceeded','session limit reached')){
      $item=New-Spec "synthetic-astra-blocked-$route-$($envelope.Replace(' ','-'))" 'gpt-6-astra' 'high' 2 $route 'override-Todd';Set-Content $item.error $envelope
      $before=Get-CallCount;$result=Invoke-Watchdog $item $item.spec.label;$row=Get-Content $history -Tail 1|ConvertFrom-Json -DateKind String
      Assert-True ($result.status-ceq'NO_QUALIFIED_FALLBACK'-and$result.relaunch-eq$false-and$result.relaunchCount-eq2-and$result.implementationAttemptIncrement-eq0-and(Get-CallCount)-eq$before-and$row.kind-ceq'lane-blocked'-and$row.model-ceq'gpt-6-astra'-and$row.effort-ceq'high'-and$row.row-eq$route-and$row.placement-ceq'override-Todd') 'upper-tier exhaustion invented quota, Fable reserve authority, or a lower-tier author'
      Write-Output "CONTROL 7955 NO_FALLBACK row=$route envelope=$envelope status=$($result.status) config=$($row.model)/$($row.effort) placement=$($row.placement) launches=0 semanticIncrement=0"
    }
  }
  $early=New-Spec 'early-confirmed';$earlyResult=& $watchdog -Label early-confirmed -RuntimeRoot $runtime -HistoryPath $history -TranscriptPath $early.partial -ObservationFixture (New-Observation 'early-confirmed' 'dead' 'none' 1) -DispatchScript $stub -SynchronousDispatch|ConvertFrom-Json -DateKind String
  Assert-True ($earlyResult.status-ceq'RELAUNCHED'-and$earlyResult.elapsedSeconds-lt5) 'early confirmed mechanical death waited for a minimum delay'
  $same=New-Spec 'same-config';$sameResult=Invoke-Watchdog $same 'same';Assert-True ($sameResult.status-ceq'RELAUNCHED'-and$sameResult.model-ceq'gpt-5.6-sol'-and$sameResult.effort-ceq'high') 'dead owner was not relaunched same-config'
  $beforeDuplicate=@(Get-Content -LiteralPath $calls).Count;$duplicate=Invoke-Watchdog $same 'same-duplicate';Assert-True ($duplicate.status-ceq'DUPLICATE_SKIPPED'-and@(Get-Content -LiteralPath $calls).Count-eq$beforeDuplicate) 'confirmed relaunch was not duplicate-suppressed'
  $prose=New-Spec 'prose-quota' 'gpt-6-astra' 'high';Set-Content -LiteralPath $prose.partial -Value 'unmistakably synthetic task prose discusses quota policy';$proseResult=Invoke-Watchdog $prose 'prose-quota';Assert-True ($proseResult.status-ceq'RELAUNCHED'-and$proseResult.model-ceq'gpt-6-astra') 'ordinary report prose authorized provider fallback'
  $quota=New-Spec 'quota-fallback' 'gpt-6-astra' 'high';Set-Content -LiteralPath $quota.error -Value 'provider quota exceeded';$quotaResult=Invoke-Watchdog $quota 'quota';Assert-True ($quotaResult.status-ceq'RELAUNCHED'-and$quotaResult.model-ceq'gpt-5.6-sol') 'exact provider envelope did not use the row-qualified fallback'
  $legacySame=New-LegacySpec 'legacy-v261-same';Add-LegacyRoutingRow $legacySame 4;$legacySameResult=Invoke-Watchdog $legacySame 'legacy-v261-same';Assert-True ($legacySameResult.status-ceq'RELAUNCHED'-and$legacySameResult.row-eq4-and$legacySameResult.model-ceq'gpt-5.6-sol') 'exact predecessor v1 spec did not recover a unique same-config canonical route'
  $legacyQuota=New-LegacySpec 'legacy-v261-quota' 'gpt-6-astra' 'high';Set-Content -LiteralPath $legacyQuota.error -Value 'provider quota exceeded';Add-LegacyRoutingRow $legacyQuota 4;$legacyQuotaResult=Invoke-Watchdog $legacyQuota 'legacy-v261-quota';Assert-True ($legacyQuotaResult.status-ceq'RELAUNCHED'-and$legacyQuotaResult.row-eq4-and$legacyQuotaResult.model-ceq'gpt-5.6-sol') 'exact predecessor v1 spec did not preserve row-qualified quota routing'
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
  $noFallback=New-Spec 'sol-quota-blocked';Set-Content -LiteralPath $noFallback.error -Value 'provider quota exceeded';$blocked=Invoke-Watchdog $noFallback 'sol-quota-blocked';Assert-True ($blocked.status-ceq'NO_QUALIFIED_FALLBACK'-and$blocked.relaunch-eq$false-and$blocked.relaunchCount-eq0) 'Sol/high quota death did not close blocked'
  $failure=New-Spec 'launch-failure';$env:SYNTHETIC_WATCHDOG_FAIL_LABEL='launch-failure.wd1.';$beforeRows=if(Test-Path $history){@(Get-Content $history).Count}else{0};$failedOne=Invoke-Watchdog $failure 'launch-failure-one';$failedTwo=Invoke-Watchdog $failure 'launch-failure-two';$afterRows=if(Test-Path $history){@(Get-Content $history).Count}else{0};Assert-True ($failedOne.status-ceq'LAUNCH_FAILED'-and$failedTwo.status-ceq'LAUNCH_FAILED'-and$beforeRows-eq$afterRows-and$failedOne.relaunchCount-eq0-and$failedTwo.relaunchCount-eq0) 'failed launcher consumed identity/count';Remove-Item Env:SYNTHETIC_WATCHDOG_FAIL_LABEL
  $ceiling=New-Spec 'ceiling' 'gpt-5.6-sol' 'high' 3;$ceilingResult=Invoke-Watchdog $ceiling 'ceiling';Assert-True ($ceilingResult.status-ceq'HARNESS_CEILING'-and$ceilingResult.implementationAttemptIncrement-eq0) 'fourth death did not block at ceiling'
  foreach($control in @([ordered]@{name='live-slow';owner='live';desc='none';status='LIVE_SLOW'},[ordered]@{name='possible-child';owner='dead';desc='possible';status='OWNERSHIP_UNKNOWN'},[ordered]@{name='reused-pid';owner='reused';desc='none';status='OWNERSHIP_UNKNOWN'},[ordered]@{name='ambiguous-child';owner='dead';desc='ambiguous';status='OWNERSHIP_UNKNOWN'})){$item=New-Spec $control.name;$count=@(Get-Content $calls).Count;$result=& $watchdog -Label $control.name -RuntimeRoot $runtime -HistoryPath $history -TranscriptPath $item.partial -ObservationFixture (New-Observation $control.name $control.owner $control.desc) -DispatchScript $stub -SynchronousDispatch|ConvertFrom-Json -DateKind String;Assert-True ($result.status-ceq$control.status-and@(Get-Content $calls).Count-eq$count) "$($control.name) was relaunched"}
  $success=New-Spec 'terminal-success';$success.spec.exitCode=[long]0;[IO.File]::WriteAllText((Join-Path $runtime 'watchdog-lane-terminal-success.json'),($success.spec|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false));$successCount=@(Get-Content $calls).Count;$successResult=& $watchdog -Label terminal-success -RuntimeRoot $runtime -HistoryPath $history -TranscriptPath $success.partial -ObservationFixture (New-Observation 'terminal-success') -DispatchScript $stub -SynchronousDispatch|ConvertFrom-Json -DateKind String;Assert-True ($successResult.status-ceq'TERMINAL_SUCCESS'-and@(Get-Content $calls).Count-eq$successCount) 'terminal success relaunched'
  $deadline=New-Spec 'deadline';$deadlineResult=& $watchdog -Label deadline -RuntimeRoot $runtime -HistoryPath $history -TranscriptPath $deadline.partial -ObservationFixture (New-Observation 'deadline' 'dead' 'none' 300) -DispatchScript $stub -SynchronousDispatch|ConvertFrom-Json -DateKind String;Assert-True ($deadlineResult.status-ceq'RELAUNCHED'-and$deadlineResult.elapsedSeconds-eq300) 'exact deadline refused'
  $stale=New-Spec 'stale-window';$staleFailed=$false;try{& $watchdog -Label stale-window -RuntimeRoot $runtime -HistoryPath $history -TranscriptPath $stale.partial -ObservationFixture (New-Observation 'stale-window' 'dead' 'none' 301) -DispatchScript $stub -SynchronousDispatch|Out-Null}catch{$staleFailed=$_.Exception.Message-match'WINDOW_EXPIRED'};Assert-True $staleFailed 'stale observation admitted'
  $wrong=New-Spec 'partial-identity';$other=Join-Path $runtime 'other.jsonl';Set-Content $other 'unrelated';$partialFailed=$false;try{& $watchdog -Label partial-identity -RuntimeRoot $runtime -HistoryPath $history -TranscriptPath $other -ObservationFixture (New-Observation 'partial') -DispatchScript $stub -SynchronousDispatch|Out-Null}catch{$partialFailed=$_.Exception.Message-match'UNKNOWN_PARTIAL'};Assert-True $partialFailed 'wrong partial admitted'
  $accepted=@(
    @(2,'gpt-5.6-terra','medium','measured'),@(2,'gpt-5.6-luna','medium','measured'),@(3,'claude-sonnet-5','medium','measured'),
    @(4,'gpt-5.6-sol','high','measured'),@(4,'gpt-6-astra','high','measured'),@(4,'gpt-5.6-sol','medium','measured'),
    @(5,'gpt-5.6-sol','high','measured'),@(5,'gpt-6-astra','high','measured'),@(5,'gpt-5.6-sol','xhigh','measured'),
    @(6,'claude-opus-5','high','measured'),@(6,'gpt-6-astra','high','measured'),@(6,'gpt-5.6-sol','high','measured'),
    @(7,'gpt-5.6-sol','high','measured'),@(7,'claude-fable-5-1','high','measured'),
    @(10,'gpt-5.6-sol','high','measured'),@(10,'gpt-6-astra','high','measured'),@(10,'claude-sonnet-5','high','measured'),
    @(13,'claude-sonnet-5','medium','measured'),@(14,'claude-fable-5-1','medium','measured'),@(14,'claude-fable-5-1','high','measured'),
    @(15,'claude-fable-5-1','high','measured'),@(15,'gpt-6-astra','high','measured'),@(15,'gpt-6-astra','high','override-Todd'),
    @(7,'gpt-6-astra','high','override-Todd'),@(14,'gpt-6-astra','high','override-Todd')
  )
  foreach($entry in $accepted){$name="accepted-$($entry-join'-')";$item=New-Spec $name $entry[1] $entry[2] 0 $entry[0] $entry[3];$value=& $watchdog -Label $name -RuntimeRoot $runtime -HistoryPath $history -TranscriptPath $item.partial -ObservationFixture (New-Observation $name 'live' 'none') -DispatchScript $stub -SynchronousDispatch|ConvertFrom-Json -DateKind String;Assert-True ($value.status-ceq'LIVE_SLOW') "accepted route rejected: $($entry-join'/')"}
  $ordinary=New-Spec 'synthetic-row7-ordinary' 'gpt-5.6-sol' 'high' 0 7 'measured';$before=Get-CallCount;$ordinaryResult=Invoke-Watchdog $ordinary 'ordinary';Assert-Recovery $ordinary $ordinaryResult 'gpt-5.6-sol' 'high' 'measured' $before
  $invalid=New-Spec 'unqualified-cross-row' 'gpt-5.6-terra' 'medium' 0 7;$invalidFailed=$false;try{& $watchdog -Label unqualified-cross-row -RuntimeRoot $runtime -HistoryPath $history -TranscriptPath $invalid.partial -ObservationFixture (New-Observation 'unqualified' 'live' 'none') -DispatchScript $stub -SynchronousDispatch|Out-Null}catch{$invalidFailed=$_.Exception.Message-match'UNKNOWN_SPEC_INVALID'};Assert-True $invalidFailed 'unqualified cross-row config accepted'
  Write-Output 'PASS watchdog v2 closure, uniquely bound v2.61 routing adapter, provider-envelope-only classification, exhaustive row/config admission, qualified fallback or closed block, acknowledged exact-once relaunch, retryable launch failure, ceiling, live-slow, reused-PID, descendant, partial, and deadline controls'
}finally{
  Remove-Item Env:SYNTHETIC_WATCHDOG_CALLS -ErrorAction SilentlyContinue;Remove-Item Env:SYNTHETIC_WATCHDOG_FAIL_LABEL -ErrorAction SilentlyContinue
  Remove-Item Env:SYNTHETIC_WATCHDOG_ACK_FIELD -ErrorAction SilentlyContinue;Remove-Item Env:SYNTHETIC_WATCHDOG_ACK_VALUE -ErrorAction SilentlyContinue
  $resolved=[IO.Path]::GetFullPath($root);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/');if((Split-Path -Parent $resolved).TrimEnd('\','/')-ne$temp-or(Split-Path -Leaf $resolved)-notlike'lane-watchdog-test-*'){throw "unsafe cleanup $resolved"};Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
}
