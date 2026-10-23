[CmdletBinding()]
param([string]$EvidenceDirectory)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'controller-ci.ps1') -Mode Library
function Refuses-Sharding([scriptblock]$Body){$refused=$false;try{&$Body|Out-Null}catch{$refused=$true};Assert-Ci $refused 'sharding bypass survived'}
function Copy-Sharding($Value){return ($Value|ConvertTo-Json -Depth 50|ConvertFrom-Json -Depth 50 -DateKind String)}
$inventory=@(0..3|ForEach-Object{[pscustomobject]@{identity="test:synthetic-$_";path='synthetic.ps1';command='synthetic';arguments=@();restriction=$null}})
$manifest=@{schemaVersion='controller-ci-parts/v1';items=@(@{identity=$inventory[0].identity;selector='-Part';parts=@(@{name='left';weight=1},@{name='right';weight=1});ownership=@{parts=@('left','right')}})}
$receipts=[Collections.Generic.List[object]]::new()
foreach($count in @(10,16,17,18)){
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
foreach($badCount in @(0,10,15,19,16.5,'16',$true)){Refuses-Sharding {Get-CiShardCount @{shardCount=$badCount}}}
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
. (Join-Path $PSScriptRoot 'suite-parts.ps1')
Refuses-Sharding {Assert-SuiteSelection 'unknown' @('left','right') @{Part='unknown'} @('Case')}
Refuses-Sharding {Assert-SuiteSelection 'left' @('left','right') @{Part='left';Case='all'} @('Case')}
Assert-Ci (@(Get-HeavySuitePartSelector '' @{}).Count-eq0) 'default heavy selection changed'
foreach($entry in (Get-HeavySuitePartMap).GetEnumerator()){
  Assert-Ci ((Get-HeavySuitePartSelector $entry.Key @{Part=$entry.Key})-ceq$entry.Value) 'heavy selector mapping changed'
}
Refuses-Sharding {Get-HeavySuitePartSelector 'legacy' @{Part='legacy';PrecursorOnly=$true}}
if($EvidenceDirectory){Write-CiJson $receipts (Join-Path $EvidenceDirectory 'sharding-controls.json')}
Write-Output 'PASS plan-bound 16/17/18, legacy-ten, exact/empty receipt replay, deterministic ties/fallback and count/mapping/selector/exclusion bypass controls'
