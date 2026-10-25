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
# Plan-mode bound ([#123 Run dispatch-lane.test.ps1 on hosted CI in parts within
# the shard bound](https://github.com/chase-sets/chase-sets-controller/issues/123)):
# a candidate plan refuses a largest shard estimate over 300 s and any
# fallback, equal-split or whole-item stale estimate; a split part's own stale
# record stays accepted.
$boundTasks=@(@{identity='test:a';timingSource='recorded'},@{identity='test:b#x';timingSource='recorded-part'},@{identity='test:c#y';timingSource='stale-recorded-part'},@{identity='test:e';timingSource='local-only'})
$boundShards=@(@{shard=0;estimatedMs=300000},@{shard=1;estimatedMs=120000})
Assert-Ci ((Assert-CiPlanBound $boundShards $boundTasks 300000)-eq300000) 'plan bound refused an observed plan at the bound'
Refuses-Sharding {Assert-CiPlanBound @(@{shard=0;estimatedMs=300001}) $boundTasks 300000}
Refuses-Sharding {Assert-CiPlanBound $boundShards (@($boundTasks)+@(@{identity='test:d';timingSource='stale-recorded'})) 300000}
foreach($source in @('fallback','recorded-split-estimate','stale-recorded-split-estimate','fallback-split-estimate')){
  Refuses-Sharding {Assert-CiPlanBound $boundShards (@($boundTasks)+@(@{identity="test:$source";timingSource=$source})) 300000}
}
$boundDefinition=(Get-Command Assert-CiPlanBound).Definition
# Each mutant removes one check; the plan only that check refuses is then
# accepted, so every refusal control above turns red against its mutant.
foreach($boundMutant in @(
  @{edit=@('-le $BoundMs','-le [long]::MaxValue');shards=@(@{shard=0;estimatedMs=300001});tasks=$boundTasks},
  @{edit=@("-ceq 'fallback'","-ceq 'never'");shards=$boundShards;tasks=(@($boundTasks)+@(@{identity='test:f';timingSource='fallback'}))},
  @{edit=@("-ceq 'stale-recorded'","-ceq 'never-stale'");shards=$boundShards;tasks=(@($boundTasks)+@(@{identity='test:d';timingSource='stale-recorded'}))},
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
# Role, not commit identity, decides enforcement. A candidate on a foreign
# checkout (runner head differs from the checkout, as with --ref main
# -f controller_head=<candidate>) is still bounded; only role=baseline is not.
$foreignCheckout='a'*40;$foreignRunner='b'*40
$overBound=@(@{shard=0;estimatedMs=300001})
$candidateBound=Get-CiPlanBound 'candidate' $boundShards $boundTasks $foreignCheckout $foreignRunner 300000
Assert-Ci ($candidateBound.role-ceq'candidate'-and$candidateBound.enforced-eq$true-and$candidateBound.maxEstimatedMs-eq300000-and$candidateBound.checkoutHead-ceq$foreignCheckout-and$candidateBound.runnerHead-ceq$foreignRunner) 'candidate plan bound not recorded as enforced'
Refuses-Sharding {Get-CiPlanBound 'candidate' $overBound $boundTasks $foreignCheckout $foreignRunner 300000}
Refuses-Sharding {Get-CiPlanBound 'candidate' $boundShards (@($boundTasks)+@(@{identity='test:d';timingSource='stale-recorded'})) $foreignCheckout $foreignRunner 300000}
$baselineBound=Get-CiPlanBound 'baseline' $overBound (@($boundTasks)+@(@{identity='test:f';timingSource='fallback'})) $foreignCheckout $foreignRunner 300000
Assert-Ci ($baselineBound.role-ceq'baseline'-and$baselineBound.enforced-eq$false-and$baselineBound.maxEstimatedMs-eq300001) 'baseline plan bound not recorded as unenforced'
foreach($badRole in @('','self','Candidate','BASELINE')){Refuses-Sharding {Get-CiPlanBound $badRole $boundShards $boundTasks $foreignCheckout $foreignRunner 300000}}
$roleDefinition=(Get-Command Get-CiPlanBound).Definition
foreach($roleMutant in @(
  @('$enforced = $Role -cne ''baseline''','$enforced = $Role -cne ''baseline'' -and $RunnerHead -ceq $CheckoutHead'),
  @('$enforced = $Role -cne ''baseline''','$enforced = $false')
)){
  Assert-Ci ($roleDefinition.Contains($roleMutant[0],[StringComparison]::Ordinal)) 'plan role mutant anchor missing'
  & {
    . ([scriptblock]::Create("function Get-CiPlanBound {`n$($roleDefinition.Replace($roleMutant[0],$roleMutant[1]))`n}"))
    $accepted=$true;try{[void](Get-CiPlanBound 'candidate' $overBound $boundTasks $foreignCheckout $foreignRunner 300000)}catch{$accepted=$false}
    Assert-Ci $accepted "plan role mutant survived: $($roleMutant[1])"
  }
}
$ciTokens=$null;$ciErrors=$null
$ciAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'controller-ci.ps1'),[ref]$ciTokens,[ref]$ciErrors)
Assert-Ci ($ciErrors.Count-eq0) 'controller-ci parse failed'
$workflowText=[IO.File]::ReadAllText((Join-Path (Split-Path -Parent $PSScriptRoot) '.github/workflows/controller-battery.yml')).Replace("`r`n","`n")
function Assert-PlanBoundWired($Ast,[string]$Workflow){
  $roleParameter=@($Ast.ParamBlock.Parameters|Where-Object{$_.Name.VariablePath.UserPath-ceq'Role'})
  Assert-Ci ($roleParameter.Count-eq1-and$roleParameter[0].Extent.Text-ceq"[ValidateSet('candidate','baseline')][string]`$Role = 'candidate'") 'Plan role parameter/default changed'
  $planBlock=@($Ast.EndBlock.Statements|Where-Object{$_ -is [Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -ceq "`$Mode -ceq 'Plan'"})
  Assert-Ci ($planBlock.Count-eq1) 'Plan mode block missing'
  $calls=@($planBlock[0].FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -cin @('Get-CiPlanBound','Assert-CiPlanBound')},$true))
  Assert-Ci ($calls.Count-eq1-and$calls[0].Extent.Text-ceq'Get-CiPlanBound $Role $planShards $executionItems $checkoutHead ([string]$env:GITHUB_SHA) 300000') 'Plan mode does not bound the plan by its role'
  $guard=$calls[0].Parent;while($guard-and$guard-isnot[Management.Automation.Language.IfStatementAst]-and$guard-ne$planBlock[0]){$guard=$guard.Parent}
  Assert-Ci ($guard-eq$planBlock[0]) 'Plan bound is conditional inside Plan mode'
  Assert-Ci ($planBlock[0].Extent.Text.Contains('planning=@{algorithm=''LPT'';fallbackMs=30000;maxAgeDays=30;shards=$planShards;bound=$bound}')) 'Plan does not record its role/bound'
  Assert-Ci (-not [regex]::IsMatch($planBlock[0].Extent.Text,'GITHUB_SHA\s*-c?(in|eq)|selfPlan')) 'Plan bound keyed to commit identity'
  Assert-Ci ($Workflow.Contains("      role:`n        description: ") -and $Workflow.Contains("        type: choice`n        options: [candidate, baseline]`n        default: candidate`n")) 'workflow role input missing'
  Assert-Ci ($Workflow.Contains('          CI_ROLE: ${{ inputs.role || (github.event_name == ''push'' && ''baseline'') || ''candidate'' }}'+"`n") -and $Workflow.Contains('-Mode Plan ') -and $Workflow.Contains(' -Role $env:CI_ROLE ')) 'workflow does not pass role to Plan mode'
}
Assert-PlanBoundWired $ciAst $workflowText
$ciText=$ciAst.Extent.Text
foreach($wiringMutant in @(
  @('ci','$bound = Get-CiPlanBound $Role $planShards $executionItems $checkoutHead ([string]$env:GITHUB_SHA) 300000','$bound = if ([string]$env:GITHUB_SHA -cin @($checkoutHead,$sourceHead)) { Get-CiPlanBound $Role $planShards $executionItems $checkoutHead ([string]$env:GITHUB_SHA) 300000 } else { @{enforced=$false} }'),
  @('ci','Get-CiPlanBound $Role $planShards','Get-CiPlanBound ''baseline'' $planShards'),
  @('ci',"[string]`$Role = 'candidate'","[string]`$Role = 'baseline'"),
  @('ci',';bound=$bound}','}'),
  @('workflow',' -Role $env:CI_ROLE ',' '),
  @('workflow',"        default: candidate`n","        default: baseline`n"),
  # #225: a push run has no inputs; it must plan as an unenforced baseline.
  @('workflow'," || (github.event_name == 'push' && 'baseline') || 'candidate' }}"," || 'candidate' }}"),
  @('workflow',"(github.event_name == 'push' && 'baseline')","(github.event_name == 'push' && 'candidate')"),
  @('workflow',"(github.event_name == 'push' && 'baseline')","(github.event_name == 'workflow_dispatch' && 'baseline')")
)){
  if($wiringMutant[0]-ceq'ci'){
    Assert-Ci ($ciText.Contains($wiringMutant[1])) "plan wiring mutant anchor missing: $($wiringMutant[1])"
    Refuses-Sharding {Assert-PlanBoundWired ([Management.Automation.Language.Parser]::ParseInput($ciText.Replace($wiringMutant[1],$wiringMutant[2]),[ref]$ciTokens,[ref]$ciErrors)) $workflowText}
  } else {
    Assert-Ci ($workflowText.Contains($wiringMutant[1])) "workflow wiring mutant anchor missing: $($wiringMutant[1])"
    Refuses-Sharding {Assert-PlanBoundWired $ciAst $workflowText.Replace($wiringMutant[1],$wiringMutant[2])}
  }
}
Write-Output 'PASS plan bound: over-300 s, fallback, split-estimate and whole-item stale plans refused (stale part accepted); candidate on a foreign checkout enforced, baseline recorded unenforced; push runs plan as baseline; check/role/wiring mutants red'
. (Join-Path $PSScriptRoot 'suite-parts.ps1')
Refuses-Sharding {Assert-SuiteSelection 'unknown' @('left','right') @{Part='unknown'} @('Case')}
Refuses-Sharding {Assert-SuiteSelection 'left' @('left','right') @{Part='left';Case='all'} @('Case')}
Assert-Ci (@(Get-HeavySuitePartSelector '' @{}).Count-eq0) 'default heavy selection changed'
foreach($entry in (Get-HeavySuitePartMap).GetEnumerator()){
  Assert-Ci ((Get-HeavySuitePartSelector $entry.Key @{Part=$entry.Key})-ceq$entry.Value) 'heavy selector mapping changed'
}
Refuses-Sharding {Get-HeavySuitePartSelector 'legacy' @{Part='legacy';PrecursorOnly=$true}}
if($EvidenceDirectory){Write-CiJson $receipts (Join-Path $EvidenceDirectory 'sharding-controls.json')}
Write-Output 'PASS plan-bound 16..32, role-keyed plan-mode 300 s bound, legacy-ten, stale part observations over equal-weight split (mutant red), exact/empty receipt replay, deterministic ties/fallback and count/mapping/selector/exclusion bypass controls'
