[CmdletBinding()]
param([string]$EvidenceDirectory)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'controller-ci.ps1') -Mode Library
function Refuses-Sharding([scriptblock]$Body){$refused=$false;try{&$Body|Out-Null}catch{$refused=$true};Assert-Ci $refused 'sharding bypass survived'}
function Copy-Sharding($Value){return ($Value|ConvertTo-Json -Depth 50|ConvertFrom-Json -Depth 50 -DateKind String)}
$inventory=@(0..3|ForEach-Object{[pscustomobject]@{identity="test:synthetic-$_";path='synthetic.ps1';command='synthetic';arguments=@();restriction=$null}})
$manifest=@{schemaVersion='controller-ci-parts/v1';items=@(@{identity=$inventory[0].identity;selector='-Part';parts=@(@{name='left';weight=1},@{name='right';weight=1});ownership=@{parts=@('left','right')}})}
$receipts=[Collections.Generic.List[object]]::new()
foreach($count in @(@(10)+@(16..32))){
  $tasks=New-CiAssignments $inventory '' $manifest -ShardCount $count
  $plan=@{controllerHead=('a'*40);checkoutHead=('b'*40);productSha=('c'*40);planSha256=('d'*64);selected=$inventory;executionItems=$tasks}
  if($count-ne10){$plan.shardCount=$count}
  $parts=@(0..($count-1)|ForEach-Object{$n=$_;@{schemaVersion='controller-ci-shard/v1';shard=$n;controllerHead=$plan.controllerHead;checkoutHead=$plan.checkoutHead
    productSha=$plan.productSha;planSha256=$plan.planSha256;results=@($tasks|Where-Object shard -EQ $n|ForEach-Object{@{identity=$_.identity;result='PASS';exitCode=0;elapsedMs=1}})}})
  Assert-Ci ((Merge-CiResults $plan $parts).Count-eq4) 'bounded/legacy/empty shard replay failed'
  Refuses-Sharding {Merge-CiResults $plan $parts[0..($count-2)]}
  $bad=Copy-Sharding $parts;$bad[-1].shard=0;Refuses-Sharding {Merge-CiResults $plan $bad}
  $bad=Copy-Sharding $parts;$bad[-1].shard=$count;Refuses-Sharding {Merge-CiResults $plan $bad}
  foreach($key in @('planSha256','controllerHead','checkoutHead','productSha')){
    $bad=Copy-Sharding $parts;$bad[0].$key='wrong';Refuses-Sharding {Merge-CiResults $plan $bad}
  }
  $split=$tasks|Where-Object requiredIdentity -CEQ $inventory[0].identity|Select-Object -First 1
  $parts[$split.shard].results[0].result='FAIL';$parts[$split.shard].results[0].exitCode=7
  $result=Merge-CiResults $plan $parts
  Assert-Ci (@($result|Where-Object identity -CEQ $inventory[0].identity)[0].result-ceq'FAIL') 'failed part did not fail required identity'
  $parts[$split.shard].results[0].result='LOCAL_ONLY';$parts[$split.shard].results[0].exitCode=125
  Refuses-Sharding {Merge-CiResults $plan $parts}
  $receipts.Add(@{count=$count;tasks=$tasks.Count;emptyShards=$count-$tasks.Count;outcome='PASS'})
}
foreach($badCount in @(0,10,15,33,16.5,'16',$true)){Refuses-Sharding {Get-CiShardCount @{shardCount=$badCount}}}
foreach($kind in @('unknown','duplicate','missing','extra','duplicate-part','selector','owned-duplicate')){
  $bad=Copy-Sharding $manifest
  switch($kind){
    'unknown' {$bad.items[0].identity='test:unknown'}
    'duplicate' {$bad.items+=@($bad.items[0])}
    'missing' {$bad.items[0].parts=@($bad.items[0].parts[0])}
    'extra' {$bad.items[0].parts+=@(@{name='extra';weight=1})}
    'duplicate-part' {$bad.items[0].parts[1].name='left'}
    'selector' {$bad.items[0].selector='-Case'}
    'owned-duplicate' {$bad.items[0].ownership.parts=@('left','left')}
  }
  Refuses-Sharding {New-CiAssignments $inventory '' $bad -ShardCount 16}
}
$inventory[0].restriction=@{classification='LOCAL_ONLY';reason='synthetic'}
Refuses-Sharding {New-CiAssignments $inventory '' $manifest -ShardCount 16}
$inventory[0].restriction=$null
$one=New-CiAssignments $inventory '' -ShardCount 16
$two=New-CiAssignments @($inventory[3..0]) '' -ShardCount 16
Assert-Ci (($one|ConvertTo-Json -Depth 10 -Compress)-ceq($two|ConvertTo-Json -Depth 10 -Compress)) 'LPT tie assignment is not deterministic'
Assert-Ci (@($one|Where-Object timingSource -CNE fallback).Count-eq0-and$one[0].shard-eq0) 'fallback/tie behavior changed'
# A stale hosted part observation keeps its own shape; the equal-weight share
# of the whole suite is used only for a part with no observation at all.
$stalePartRoot=Join-Path ([IO.Path]::GetTempPath()) ('ci-stale-part-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($stalePartRoot)
try{
  & git -C $stalePartRoot init -q; & git -C $stalePartRoot config user.name Synthetic; & git -C $stalePartRoot config user.email synthetic@example.invalid
  [IO.File]::WriteAllText((Join-Path $stalePartRoot 'synthetic.test.ps1'),'# synthetic',[Text.UTF8Encoding]::new($false))
  & git -C $stalePartRoot add .; & git -C $stalePartRoot commit -qm synthetic
  Assert-Ci ($LASTEXITCODE-eq0) 'stale-part fixture commit failed'
  $partItem=@([pscustomobject]@{identity='test:synthetic.test.ps1';path='synthetic.test.ps1';command='synthetic';arguments=@();restriction=$null})
  $partManifest=@{schemaVersion='controller-ci-parts/v1';items=@(@{identity='test:synthetic.test.ps1';selector='-Part';parts=@(@{name='left';weight=1},@{name='right';weight=1},@{name='unseen';weight=1})})}
  $digest=Get-CiSourceDigest (Join-Path $stalePartRoot 'synthetic.test.ps1')
  $at='2026-10-24T00:00:00Z';$stamp=[datetimeoffset]'2026-10-25T00:00:00Z'
  $staleRecords=@(@{identity='test:synthetic.test.ps1';elapsedMs=30000},@{identity='test:synthetic.test.ps1#left';elapsedMs=27000},@{identity='test:synthetic.test.ps1#right';elapsedMs=2000}|ForEach-Object{
    [pscustomobject]@{identity=$_.identity;elapsedMs=[long]$_.elapsedMs;recordedAtUtc=$at;sourceSha256=$digest;sourceSetSha256=('e'*64)}})
  $staleTasks=Set-CiBalancedShards (New-CiExecutionItems $partItem $partManifest @{records=$staleRecords} $stalePartRoot $stamp) 16
  $byName=@{};foreach($task in $staleTasks){$byName[$task.identity]=$task}
  Assert-Ci ($byName['test:synthetic.test.ps1#left'].estimatedMs-eq27000-and$byName['test:synthetic.test.ps1#left'].timingSource-ceq'stale-recorded-part'-and
    $byName['test:synthetic.test.ps1#right'].estimatedMs-eq2000-and$byName['test:synthetic.test.ps1#right'].timingSource-ceq'stale-recorded-part'-and
    $byName['test:synthetic.test.ps1#unseen'].estimatedMs-eq10000-and$byName['test:synthetic.test.ps1#unseen'].timingSource-ceq'stale-recorded-split-estimate') 'stale part observation was replaced by an equal-weight split'
  $definition=(Get-Command New-CiExecutionItems).Definition
  $needle="elseif (`$partTiming.source -ceq 'stale-recorded')"
  Assert-Ci ($definition.Contains($needle,[StringComparison]::Ordinal)) 'stale-part mutation target missing'
  & {
    . ([scriptblock]::Create("function New-CiExecutionItems {`n$($definition.Replace($needle,'elseif ($false)').Replace('$PSScriptRoot',"'$PSScriptRoot'"))`n}"))
    $mutantTasks=New-CiExecutionItems $partItem $partManifest @{records=$staleRecords} $stalePartRoot $stamp
    Refuses-Sharding {Assert-Ci (@($mutantTasks|Where-Object identity -CEQ 'test:synthetic.test.ps1#left')[0].estimatedMs-eq27000) 'equal-split mutant accepted'}
  }
}finally{
  $resolved=[IO.Path]::GetFullPath($stalePartRoot)
  Assert-Ci ((Split-Path -Parent $resolved)-ceq[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')) 'unsafe stale-part fixture cleanup'
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
# Plan-mode bound (#123): a self-planned head refuses a plan whose largest shard
# estimate exceeds 300 s or that rests on fallback/equal-split estimates.
$boundTasks=@(@{identity='test:a';timingSource='recorded'},@{identity='test:b#x';timingSource='recorded-part'},@{identity='test:c#y';timingSource='stale-recorded-part'},@{identity='test:d';timingSource='stale-recorded'},@{identity='test:e';timingSource='local-only'})
$boundShards=@(@{shard=0;estimatedMs=300000},@{shard=1;estimatedMs=120000})
Assert-Ci ((Assert-CiPlanBound $boundShards $boundTasks 300000)-eq300000) 'plan bound refused an observed plan at the bound'
Refuses-Sharding {Assert-CiPlanBound @(@{shard=0;estimatedMs=300001}) $boundTasks 300000}
foreach($source in @('fallback','recorded-split-estimate','stale-recorded-split-estimate','fallback-split-estimate')){
  Refuses-Sharding {Assert-CiPlanBound $boundShards (@($boundTasks)+@(@{identity="test:$source";timingSource=$source})) 300000}
}
$boundDefinition=(Get-Command Assert-CiPlanBound).Definition
# Each mutant removes one check; the plan only that check refuses is then
# accepted, so every refusal control above turns red against its mutant.
foreach($boundMutant in @(
  @{edit=@('-le $BoundMs','-le [long]::MaxValue');shards=@(@{shard=0;estimatedMs=300001});tasks=$boundTasks},
  @{edit=@("-ceq 'fallback'","-ceq 'never'");shards=$boundShards;tasks=(@($boundTasks)+@(@{identity='test:f';timingSource='fallback'}))},
  @{edit=@("EndsWith('-split-estimate'","EndsWith('-never'");shards=$boundShards;tasks=(@($boundTasks)+@(@{identity='test:g#z';timingSource='recorded-split-estimate'}))}
)){
  Assert-Ci ($boundDefinition.Contains($boundMutant.edit[0],[StringComparison]::Ordinal)) "plan bound mutant anchor missing: $($boundMutant.edit[0])"
  Refuses-Sharding {Assert-CiPlanBound $boundMutant.shards $boundMutant.tasks 300000}
  & {
    . ([scriptblock]::Create("function Assert-CiPlanBound {`n$($boundDefinition.Replace($boundMutant.edit[0],$boundMutant.edit[1]))`n}"))
    $accepted=$true;try{[void](Assert-CiPlanBound $boundMutant.shards $boundMutant.tasks 300000)}catch{$accepted=$false}
    Assert-Ci $accepted "plan bound mutant survived: $($boundMutant.edit[0]) is not load-bearing"
  }
}
$ciTokens=$null;$ciErrors=$null
$ciAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'controller-ci.ps1'),[ref]$ciTokens,[ref]$ciErrors)
Assert-Ci ($ciErrors.Count-eq0) 'controller-ci parse failed'
function Assert-PlanBoundWired($Ast){
  $planBlock=@($Ast.EndBlock.Statements|Where-Object{$_ -is [Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -ceq "`$Mode -ceq 'Plan'"})
  Assert-Ci ($planBlock.Count-eq1) 'Plan mode block missing'
  $calls=@($planBlock[0].FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Assert-CiPlanBound'},$true))
  Assert-Ci ($calls.Count-eq1-and$calls[0].Extent.Text-ceq'Assert-CiPlanBound $planShards $executionItems 300000') 'Plan mode does not enforce the shard bound'
  $guard=$calls[0].Parent;while($guard-and$guard-isnot[Management.Automation.Language.IfStatementAst]){$guard=$guard.Parent}
  Assert-Ci ($null-ne$guard-and$guard.Clauses[0].Item1.Extent.Text-ceq'$selfPlan') 'Plan bound is not keyed to the self-planned head'
  Assert-Ci ($planBlock[0].Extent.Text.Contains('$selfPlan = [string]$env:GITHUB_SHA -cin @($checkoutHead,$sourceHead)')) 'self-plan selector changed'
}
Assert-PlanBoundWired $ciAst
$ciText=$ciAst.Extent.Text
Refuses-Sharding {Assert-PlanBoundWired ([Management.Automation.Language.Parser]::ParseInput($ciText.Replace('maxEstimatedMs=(Assert-CiPlanBound $planShards $executionItems 300000)','maxEstimatedMs=0'),[ref]$ciTokens,[ref]$ciErrors))}
Refuses-Sharding {Assert-PlanBoundWired ([Management.Automation.Language.Parser]::ParseInput($ciText.Replace('$selfPlan = [string]$env:GITHUB_SHA -cin @($checkoutHead,$sourceHead)','$selfPlan = $false'),[ref]$ciTokens,[ref]$ciErrors))}
Write-Output 'PASS plan bound: over-300 s, fallback and split-estimate plans refused; bound check mutants red; Plan mode wired for the self-planned head'
. (Join-Path $PSScriptRoot 'suite-parts.ps1')
Refuses-Sharding {Assert-SuiteSelection 'unknown' @('left','right') @{Part='unknown'} @('Case')}
Refuses-Sharding {Assert-SuiteSelection 'left' @('left','right') @{Part='left';Case='all'} @('Case')}
Assert-Ci (@(Get-HeavySuitePartSelector '' @{}).Count-eq0) 'default heavy selection changed'
foreach($entry in (Get-HeavySuitePartMap).GetEnumerator()){
  Assert-Ci ((Get-HeavySuitePartSelector $entry.Key @{Part=$entry.Key})-ceq$entry.Value) 'heavy selector mapping changed'
}
Refuses-Sharding {Get-HeavySuitePartSelector 'legacy' @{Part='legacy';PrecursorOnly=$true}}
if($EvidenceDirectory){Write-CiJson $receipts (Join-Path $EvidenceDirectory 'sharding-controls.json')}
Write-Output 'PASS plan-bound 16..32, plan-mode 300 s bound, legacy-ten, stale part observations over equal-weight split (mutant red), exact/empty receipt replay, deterministic ties/fallback and count/mapping/selector/exclusion bypass controls'
