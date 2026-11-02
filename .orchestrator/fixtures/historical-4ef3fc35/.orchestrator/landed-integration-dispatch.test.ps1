param([switch]$AuthorityOnly,[string]$ControllerRoot=(Split-Path -Parent $PSScriptRoot),[switch]$OwnershipOnly,[string]$OwnershipControl='*',[switch]$SkipOwnershipMutants,[string]$DispatcherPath,[switch]$ProductCensusOnly,[switch]$RetainedCensusOnly,[switch]$OtherBranch,[string]$CensusMutant='')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'routing-data-test-support.ps1')
$routingTestScope=Enter-RoutingDataTestScope
try {
. (Join-Path $PSScriptRoot 'dispatch-ownership.ps1')
. (Join-Path $PSScriptRoot 'product-census-integration-test-support.ps1')
if ($RetainedCensusOnly) { Test-PlatformSeatRetainedIntegration -OtherBranch:$OtherBranch -Mutant $CensusMutant; return }
if ($ProductCensusOnly -or (-not $AuthorityOnly -and -not $OwnershipOnly)) {
  Test-PlatformSeatProductIntegration
  Test-PlatformSeatLiveProductOwner
  Test-PlatformSeatRetainedIntegration
  Test-PlatformSeatRetainedIntegration -OtherBranch
  foreach ($mutant in @('auth-branch-only','auth-child','handoff-before','handoff-after')) {
    Test-PlatformSeatRetainedIntegration -Mutant $mutant
  }
}
if ($ProductCensusOnly) { return }
$root=Join-Path ([IO.Path]::GetTempPath()) ('landed-integration-test-'+[guid]::NewGuid().ToString('N'))
$previousPoolUrl=$env:CODEX_POOL_STATUS_URL
$runtime=Join-Path $root 'runtime';$history=Join-Path $runtime 'history.jsonl';$calls=Join-Path $runtime 'calls.txt'
$script=Join-Path $ControllerRoot '.orchestrator/landed-integration-dispatch.ps1'
if($DispatcherPath){$script=$DispatcherPath}
. (Join-Path $PSScriptRoot 'dispatch-ownership.ps1')
. (Join-Path $PSScriptRoot 'integration-dispatch-test-support.ps1')
function Assert-True($Condition,[string]$Message){if(-not$Condition){throw "ASSERTION FAILED: $Message"}}
try{
  New-Item -ItemType Directory -Path $runtime | Out-Null
  $seed=Join-Path $root 'main';New-Item -ItemType Directory $seed|Out-Null
  & git -C $seed init -q --initial-branch=main
  & git -C $seed config user.name 'Synthetic Integration'
  & git -C $seed config user.email 'synthetic-integration@example.invalid'
  Set-Content (Join-Path $seed 'base.txt') base
  & git -C $seed add base.txt
  & git -C $seed commit -q -m base
  $base=(& git -C $seed rev-parse HEAD).Trim()
  $branches=@{2='synthetic/intersect';3='synthetic/conflict';4='synthetic/dirty-active';5='synthetic/clean'}
  $worktrees=@{};$nativeHeads=@{}
  foreach($n in 2..5){
    $path=Join-Path $root "target-$n";$worktrees[$n]=$path
    & git -C $seed worktree add -q -b $branches[$n] $path main
    Set-Content (Join-Path $path "feature-$n.txt") "feature-$n"
    & git -C $path add .
    & git -C $path commit -q -m "feature-$n"
    $nativeHeads[$n]=(& git -C $path rev-parse HEAD).Trim()
  }
  Publish-SyntheticIntegrationRemote $seed (Join-Path $root 'remote.git')
  $stub=Join-Path $root 'dispatch-lane.ps1'
  Set-Content -LiteralPath $stub -Value @'
param($Harness,$Model,$Effort,$Row,$Placement,$LaneRole,$PromptFile,$Worktree,$Label,$StartRequestIdentity,$StartAcknowledgementPath,$IntegrationTargetPath,$IntegrationAuthorityFixturePath)
Add-Content -LiteralPath $env:SYNTHETIC_DISPATCH_CALLS -Value "$Label|$Worktree|$Model|$Effort"
$leaf=Split-Path -Leaf $Worktree
if($env:SYNTHETIC_INTEGRATION_FAIL-and$Label-like"$($env:SYNTHETIC_INTEGRATION_FAIL)*"){exit 19}
$branch=(& git -C $Worktree branch --show-current).Trim()
$head=(& git -C $Worktree rev-parse HEAD).Trim()
$launchId=[guid]::NewGuid().ToString();$owner=Join-Path (Split-Path -Parent $StartAcknowledgementPath) "dispatch-launch-$launchId.json"
$ack=[ordered]@{schemaVersion='dispatch-start-ack/v1';requestIdentity=$StartRequestIdentity;label=$Label;launchId=$launchId;ownershipRecordPath=$owner;worktree=[IO.Path]::GetFullPath($Worktree).TrimEnd('\','/');branch=$branch;head=$head;harness=$Harness;model=$Model;effort=$Effort;row=[long]$Row;placement=$Placement;state='started';childPid=[long]$PID;childStartIdentity=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')}
[IO.File]::WriteAllText($StartAcknowledgementPath,($ack|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
exit 0
'@
  $landedHead='a'*40
  $nodes=@(
    [ordered]@{number=[long]2;headRefOid=$nativeHeads[2];headRefName='synthetic/intersect';mergeable='MERGEABLE';mergeStateStatus='CLEAN';worktree=$worktrees[2];files=[ordered]@{complete=$true;totalCount=[long]1;nodes=@([ordered]@{path='shared.txt'})}},
    [ordered]@{number=[long]3;headRefOid=$nativeHeads[3];headRefName='synthetic/conflict';mergeable='CONFLICTING';mergeStateStatus='BLOCKED';worktree=$worktrees[3];files=[ordered]@{complete=$true;totalCount=[long]1;nodes=@([ordered]@{path='other.txt'})}},
    [ordered]@{number=[long]4;headRefOid=$nativeHeads[4];headRefName='synthetic/dirty-active';mergeable='MERGEABLE';mergeStateStatus='DIRTY';worktree=$worktrees[4];files=[ordered]@{complete=$true;totalCount=[long]1;nodes=@([ordered]@{path='active.txt'})}},
    [ordered]@{number=[long]5;headRefOid=$nativeHeads[5];headRefName='synthetic/clean';mergeable='MERGEABLE';mergeStateStatus='CLEAN';worktree=$worktrees[5];files=[ordered]@{complete=$true;totalCount=[long]1;nodes=@([ordered]@{path='none.txt'})}}
  )
  $fixture=[ordered]@{schemaVersion='landed-integration-census/v1';complete=$true;newBase=$base;activeBranches=@();landed=[ordered]@{pr=[long]1;head=$landedHead;files=[ordered]@{complete=$true;totalCount=[long]1;nodes=@([ordered]@{path='shared.txt'})}};openPullRequests=[ordered]@{complete=$true;totalCount=[long]4;nodes=$nodes}}
  $fixturePath=Join-Path $root 'census.json';[IO.File]::WriteAllText($fixturePath,($fixture|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
  $authority=Write-SyntheticIntegrationAuthority (Join-Path $root 'authority.json') $nodes $base
  $env:SYNTHETIC_DISPATCH_CALLS=$calls
  $env:CODEX_POOL_STATUS_URL='http://127.0.0.1:1/status' # isolated tests never read the live pool
  function Test-AuthorityCensus([string]$Name,[string]$Mode,[string]$Subject=$script){
    $r=Join-Path $root "authority-$Name";New-Item -ItemType Directory $r|Out-Null
    $h=Join-Path $r 'history.jsonl';$call=Join-Path $r 'calls.txt';$env:SYNTHETIC_DISPATCH_CALLS=$call
    $c=$fixture|ConvertTo-Json -Depth 12|ConvertFrom-Json -DateKind String
    $c.openPullRequests.nodes=@($c.openPullRequests.nodes|Select-Object -First 3);$c.openPullRequests.totalCount=3L
    $binding=@{Log='dispatch';Kind='rule-change';IntegrationAuthoritySchema='landed-integration-authority/v1';Pr=2;Issue=908132;TargetBranch=$branches[2];LineageRoot='synthetic/8132';TargetHead=$nativeHeads[2];OutFile=$h;NoBoard=$true}
    $logger=Join-Path $PSScriptRoot 'log-event.ps1'
    $stopArgs=@{AuthorityState='STOP';AuthorityIssue=908132;AuthorityCommentId=9000000001;OperatorAuthority='Todd:908132#9000000001';Note='Synthetic STOP ruling observed 2026-09-23T00:00:00Z'}
    $beforeApply=$null
    if($Mode-in@('mixed','invalid')){
      Write-SyntheticIntegrationEligibility $h @($nodes[1])
      & $logger @binding @stopArgs|Out-Null
      $stop=(Read-ExactHeadReviewHistory $h).rows[-1].rawSha256
      if($Mode-ceq'invalid'){
        $bad=(Read-ExactHeadReviewHistory $h).rows[-1].value
        $bad.authorityState='RELEASE';$bad|Add-Member supersedes ('f'*64)
        $bad|ConvertTo-Json -Compress|Add-Content $h
      }
      # If Gate A is bypassed these deliberately invalid retained pointers are read.
      $pointer=Join-Path $r "integration-owed-2-$($landedHead.Substring(0,12)).json"
      Set-Content $pointer 'synthetic retained pointer, must not be consumed'
      $c.activeBranches=@($branches[2]);$c.openPullRequests.nodes[0].worktree=Join-Path $r 'missing-stopped-worktree'
    }elseif($Mode-ceq'transition'){
      $c.openPullRequests.nodes=@($c.openPullRequests.nodes[0]);$c.openPullRequests.totalCount=1L
      Write-SyntheticIntegrationEligibility $h @($nodes[0])
      & $logger @binding @stopArgs|Out-Null
      $stop=(Read-ExactHeadReviewHistory $h).rows[-1].rawSha256
      $releaseArgs=$stopArgs.Clone();$releaseArgs.AuthorityState='RELEASE';$releaseArgs.AuthorityCommentId=9000000002;$releaseArgs.OperatorAuthority='Todd:908132#9000000002';$releaseArgs.Supersedes=$stop
      & $logger @binding @releaseArgs|Out-Null
      $releasedPath=Join-Path $r 'released-census.json';$c|ConvertTo-Json -Depth 12|Set-Content $releasedPath
      $released=& $Subject -LandedPr 1 -LandedHead $landedHead -HistoryPath $h -RuntimeRoot $r -ContainerRoot $root -Repository $SyntheticIntegrationRepository -FixturePath $releasedPath -IntegrationAuthorityFixturePath $authority -DispatchScript $stub -SynchronousDispatch|ConvertFrom-Json -DateKind String
      Assert-True ($released.targets[0].action-ceq'AUTHORITY_UNKNOWN'-and-not(Test-Path $call)) 'RELEASE-only census admitted'
      Write-SyntheticIntegrationEligibility $h @($nodes[0])
    }elseif($Mode-in@('drift-stop','drift-head','drift-global')){
      $c.openPullRequests.nodes=@($c.openPullRequests.nodes[0]);$c.openPullRequests.totalCount=1L
      Write-SyntheticIntegrationEligibility $h @($nodes[0])
      $beforeApply={
        if($Mode-ceq'drift-stop'){& $logger @binding @stopArgs|Out-Null}
        elseif($Mode-ceq'drift-global'){Add-Content $h '{synthetic malformed'}
        else {& git -C $worktrees[2] symbolic-ref HEAD refs/heads/synthetic/clean}
      }
    }else{[IO.File]::WriteAllText($h,'')}
    $p=Join-Path $r 'census.json';$c|ConvertTo-Json -Depth 12|Set-Content $p
    $historyBefore=[IO.File]::ReadAllText($h);$failure=$null;$result=$null
    try{$result=& $Subject -LandedPr 1 -LandedHead $landedHead -HistoryPath $h -RuntimeRoot $r -ContainerRoot $root -Repository $SyntheticIntegrationRepository -FixturePath $p -IntegrationAuthorityFixturePath $authority -DispatchScript $stub -SynchronousDispatch -BeforeApply $beforeApply |ConvertFrom-Json -DateKind String}catch{$failure=$_.Exception.Message}finally{
      if($Mode-ceq'drift-head'){& git -C $worktrees[2] symbolic-ref HEAD refs/heads/synthetic/intersect}
    }
    $count=if(Test-Path $call){@(Get-Content $call).Count}else{0}
    if($Mode-in@('mixed','invalid')){
      $action=if($Mode-ceq'mixed'){'TERMINAL_AUTHORITY_STOP'}else{'AUTHORITY_UNKNOWN'}
      Assert-True ($null-eq$failure-and$count-eq1-and$result.targets[0].action-ceq$action-and$result.targets[0].authorityRows -contains $stop-and$result.targets[1].action-ceq'AUTHORITY_UNKNOWN'-and$result.targets[2].action-ceq'LAUNCHED') "$Name partition/effects failure: $failure"
      Assert-True ((Get-Content $pointer)-ceq'synthetic retained pointer, must not be consumed') "$Name consumed pointer"
      $after=[IO.File]::ReadAllText($h)
      $repeat=& $Subject -LandedPr 1 -LandedHead $landedHead -HistoryPath $h -RuntimeRoot $r -ContainerRoot $root -Repository $SyntheticIntegrationRepository -FixturePath $p -IntegrationAuthorityFixturePath $authority -DispatchScript $stub -SynchronousDispatch |ConvertFrom-Json -DateKind String
      Assert-True ([IO.File]::ReadAllText($h)-ceq$after-and@(Get-Content $call).Count-eq1-and$repeat.targets[1].action-ceq$action) "$Name day-after replay consumed authority or relaunched sibling"
      $plan=Get-Content (Get-ChildItem $r -Filter 'integration-plan-*.json')[0].FullName -Raw|ConvertFrom-Json
      Assert-True (@($plan.targets[0].PSObject.Properties).Count-eq6) 'plan schema grew authority replay fields'
    }elseif($Mode-ceq'transition'){
      Assert-True ($null-eq$failure-and$count-eq1-and$result.targets[0].action-ceq'LAUNCHED') "$Name fresh same-head admission failed: $failure"
    }elseif($Mode-ceq'drift-global'){Assert-True ($failure-ceq'CENSUS_UNKNOWN_AUTHORITY_ROW'-and$count-eq0) "$Name global refusal missing"}
    else{
      $action=if($Mode-like'drift-*'){'AUTHORITY_CHANGED'}else{'AUTHORITY_UNKNOWN'}
      Assert-True ($null-eq$failure-and$count-eq0-and@($result.targets|Where-Object action -cne $action).Count-eq0) "$Name admitted or wrong result: $failure"
      Assert-True (@(Get-ChildItem $r -File|Where-Object{$_.Name-like'*.prompt.txt'-or$_.Name-like'integration-request-*'-or$_.Name-like'dispatch-start-*'}).Count-eq0) "$Name pre-effect gate too late"
    }
    if($Mode-ceq'unbound'){Assert-True ([IO.File]::ReadAllText($h)-ceq$historyBefore) 'unbound wrote history'}
    Write-Output "CONTROL $Name PASS"
  }
  Import-Module (Join-Path $PSScriptRoot 'review-head-contract.psm1') -Force -DisableNameChecking
  if(-not$OwnershipOnly){
  Test-AuthorityCensus 'stopped-and-eligible-mixed-census' mixed
  Test-AuthorityCensus 'scoped-invalid-release-eligible-sibling' invalid
  Test-AuthorityCensus 'terminal-authority-unbound' unbound
  Test-AuthorityCensus 'terminal-authority-pre-apply-stop' drift-stop
  Test-AuthorityCensus 'terminal-authority-pre-apply-head' drift-head
  Test-AuthorityCensus 'terminal-authority-pre-apply-global' drift-global
  Test-AuthorityCensus 'terminal-stop-day-after-and-authorized-transition' transition
  foreach($guard in @('PLAN','APPLY')){
    $mutantRoot=Join-Path $root "mutant-$guard";New-Item -ItemType Directory $mutantRoot|Out-Null
    Get-ChildItem $PSScriptRoot -File|Where-Object Extension -in @('.ps1','.psm1')|Copy-Item -Destination $mutantRoot
    $mutant=Join-Path $mutantRoot 'landed-integration-dispatch.ps1'
    $source=[IO.File]::ReadAllText($script)
    $old=if($guard-ceq'PLAN'){"if(`$authority.state-cne'ELIGIBLE'){ # AUTHORITY_GUARD_PLAN"}else{"if(`$identityReason-or`$authority.state-cne'ELIGIBLE'){ # AUTHORITY_GUARD_APPLY"}
    Assert-True ($source.Contains($old)) "$guard mutation anchor missing"
    [IO.File]::WriteAllText($mutant,$source.Replace($old,"if(`$false){ # MUTATED_$guard"))
    $caught=$false
    try{Test-AuthorityCensus "mutant-$guard" $(if($guard-ceq'PLAN'){'mixed'}else{'drift-stop'}) $mutant}catch{$caught=$_.Exception.Message-like'ASSERTION FAILED:*'}
    Assert-True $caught "$guard bypass survived its paired control"
    Write-Output "CONTROL AUTHORITY_GUARD_$guard bypass REJECTED"
  }
  if($AuthorityOnly){return}
  $env:SYNTHETIC_DISPATCH_CALLS=$calls
  Write-SyntheticIntegrationEligibility $history $nodes
  $first=& $script -LandedPr 1 -LandedHead $landedHead -HistoryPath $history -RuntimeRoot $runtime -ContainerRoot $root -Repository $SyntheticIntegrationRepository -FixturePath $fixturePath -IntegrationAuthorityFixturePath $authority -DispatchScript $stub -SynchronousDispatch|ConvertFrom-Json -DateKind String
  $rows=@(Get-Content -LiteralPath $history|ForEach-Object{$_|ConvertFrom-Json -DateKind String})
  $dispatches=@($rows|Where-Object{$_.integrationDispatchSchema-cin@('landed-integration-dispatch/v1','landed-integration-dispatch/v2')})
  $launched=@(Get-Content -LiteralPath $calls)
  Assert-True ($first.targetCount-eq3-and$dispatches.Count-eq3-and$launched.Count-eq3) 'census did not dispatch exactly intersecting/conflicting/DIRTY targets'
  Assert-True (@($dispatches|Where-Object{$_.pr-eq5}).Count-eq0) 'nonintersecting clean PR was admitted'
  $second=& $script -LandedPr 1 -LandedHead $landedHead -HistoryPath $history -RuntimeRoot $runtime -ContainerRoot $root -Repository $SyntheticIntegrationRepository -FixturePath $fixturePath -IntegrationAuthorityFixturePath $authority -DispatchScript $stub -SynchronousDispatch|ConvertFrom-Json -DateKind String
  Assert-True (@(Get-Content -LiteralPath $calls).Count-eq3-and@($second.targets|Where-Object{$_.action-ceq'DUPLICATE_SKIPPED'}).Count-eq3) 'repeated landed observation duplicated integration dispatch'
  function Test-AuthorDispatch([string]$Name,[string]$Status,[string]$ExpectedModel,[string]$ForeignAck='',[string]$DispatchStub=$stub,[switch]$DefaultPoolStatus,[switch]$RoutingAck){
    $r=Join-Path $root "author-$Name";New-Item -ItemType Directory $r|Out-Null
    $h=Join-Path $r 'history.jsonl';$call=Join-Path $r 'calls.txt';$env:SYNTHETIC_DISPATCH_CALLS=$call
    $c=$fixture|ConvertTo-Json -Depth 12|ConvertFrom-Json -DateKind String
    $c.openPullRequests.nodes=@($c.openPullRequests.nodes[0]);$c.openPullRequests.totalCount=[long]1
    $p=Join-Path $r 'census.json';$c|ConvertTo-Json -Depth 12|Set-Content $p
    Write-SyntheticIntegrationEligibility $h @($nodes[0])
    $pool=Join-Path $r 'pool.json';[IO.File]::WriteAllText($pool,$Status,[Text.UTF8Encoding]::new($false))
    $wt=[IO.Path]::GetFullPath($worktrees[2]);$lane="integration-1-2-$($landedHead.Substring(0,8))"
    $legacy="landed-integration-start/v1`n1`n$landedHead`n2`n$($nativeHeads[2])`n$($branches[2])`n$wt`n$lane"
    $legacyId=([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($legacy)))).ToLowerInvariant()
    $harness=if($ExpectedModel-ceq'gpt-6-astra'){'codex'}else{'claude'}
    $request="landed-integration-start/v2`n$legacyId`n$base`n$harness/$ExpectedModel/high/7/override-Todd"
    $identity=([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($request)))).ToLowerInvariant()
    $ack=Join-Path $r "dispatch-start-$identity.json"
    if($ForeignAck){Copy-Item -LiteralPath $ForeignAck -Destination (Join-Path $r (Split-Path -Leaf $ForeignAck))}
    $failure=$null;$result=$null
    $poolArgs=if($DefaultPoolStatus){@{}}else{@{PoolStatusFixturePath=$pool}}
    try{$result=& $script -LandedPr 1 -LandedHead $landedHead -HistoryPath $h -RuntimeRoot $r -ContainerRoot $root -Repository $SyntheticIntegrationRepository -FixturePath $p -IntegrationAuthorityFixturePath $authority @poolArgs -DispatchScript $DispatchStub -SynchronousDispatch|ConvertFrom-Json -DateKind String}catch{$failure=$_.Exception.Message}
    if($DispatchStub-ceq$stub -or $RoutingAck){
      Assert-True ($null-eq$failure-and$result.targets[0].action-ceq'LAUNCHED'-and(Test-Path $ack)-and@(Get-Content $call).Count-eq1) "$Name identity/launch: $failure"
      $record=Get-Content $ack -Raw|ConvertFrom-Json -DateKind String
      Assert-True ($record.requestIdentity-ceq$identity-and$record.harness-ceq$harness-and$record.model-ceq$ExpectedModel) "$Name wrong acknowledgement tuple"
      $row=@(Get-Content $h|ForEach-Object{$_|ConvertFrom-Json -DateKind String}|Where-Object integrationDispatchSchema -eq 'landed-integration-dispatch/v1')
      Assert-True ($row.Count-eq1-and$row[0].harness-ceq$harness-and$row[0].model-ceq$ExpectedModel) "$Name wrong terminal tuple"
    }else{Assert-True ($failure-like'*INTEGRATION_DISPATCH_START_ACK_UNKNOWN*'-and@(Get-Content $h|Where-Object{$_ -like '*landed-integration-dispatch/v1*'}).Count-eq0) "$Name alien acknowledgement admitted: $failure"}
    return [pscustomobject]@{ack=$ack;identity=$identity;result=$result;runtime=$r}
  }
  $future=[datetimeoffset]::UtcNow.AddDays(1).ToString('o')
  $blockedPool=@{error=$null;accounts=@(@{provider='codex';disabled=$false;routingModels=@{'gpt-6-astra'=@{status='blocked';next_retry_after=$future}}},@{provider='codex';disabled=$false;routingModels=@{'gpt-6-astra'=@{status='blocked';next_retry_after=$future}}})}|ConvertTo-Json -Depth 8
  $readyPool=@{error=$null;accounts=@(@{provider='codex';disabled=$false;routingModels=@{'gpt-6-astra'=@{status='ready';next_retry_after='0001-01-01T00:00:00Z'}}},@{provider='codex';disabled=$false;routingModels=@{'gpt-6-astra'=@{status='blocked';next_retry_after=$future}}})}|ConvertTo-Json -Depth 8
  $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$listener.Start()
  try{
    $env:CODEX_POOL_STATUS_URL="http://127.0.0.1:$(($listener.LocalEndpoint).Port)/api/status"
    [void](Test-AuthorDispatch 'fixture-default-no-http' $blockedPool 'gpt-6-astra' -DefaultPoolStatus)
    Assert-True (-not$listener.Pending()) 'fixture-mode producer contacted pool without an explicit status fixture'
  }finally{$listener.Stop();$env:CODEX_POOL_STATUS_URL='http://127.0.0.1:1/status'}
  $astraControl=Test-AuthorDispatch 'ready' $readyPool 'gpt-6-astra'
  $fableControl=Test-AuthorDispatch 'blocked-with-astra-ack' $blockedPool 'claude-fable-5-1' $astraControl.ack
  Assert-True ($astraControl.identity-cne$fableControl.identity-and-not(Test-Path (Join-Path $astraControl.runtime (Split-Path -Leaf $fableControl.ack)))) 'Astra and Fable identities collided'
  [void](Test-AuthorDispatch 'ready-with-fable-ack' $readyPool 'gpt-6-astra' $fableControl.ack)
  foreach($case in @(@('malformed','{invalid'),@('unparsable','{"accounts":"blocked"}'),@('no-reset',(@{accounts=@(@{provider='codex';disabled=$false;routingModels=@{'gpt-6-astra'=@{status='blocked';next_retry_after='unknown'}}})}|ConvertTo-Json -Depth 6)))){
    [void](Test-AuthorDispatch $case[0] $case[1] 'gpt-6-astra')
  }
  $alienStub=Join-Path $root 'alien-dispatch-lane.ps1'
  $stubText=[IO.File]::ReadAllText($stub).Replace('[IO.File]::WriteAllText($StartAcknowledgementPath',"`$ack.model='claude-opus-5-5'`n[IO.File]::WriteAllText(`$StartAcknowledgementPath")
  [IO.File]::WriteAllText($alienStub,$stubText,[Text.UTF8Encoding]::new($false))
  [void](Test-AuthorDispatch 'alien-fable-ack' $blockedPool 'claude-fable-5-1' '' $alienStub)
  $routingStub=Join-Path $root 'routing-ack-dispatch.ps1'
  $routingAssignment="`$ack.policyGeneration=[long]1;`$ack.registryAuthorityDigest='synthetic-consumer-authority';`$ack.family='astra';`$ack.slot='explicit';`$ack.usedLastKnownGood=`$false`n"
  $routingStubText=[IO.File]::ReadAllText($stub).Replace('[IO.File]::WriteAllText($StartAcknowledgementPath',$routingAssignment+'[IO.File]::WriteAllText($StartAcknowledgementPath')
  [IO.File]::WriteAllText($routingStub,$routingStubText,[Text.UTF8Encoding]::new($false))
  [void](Test-AuthorDispatch 'routing-ack-complete' $readyPool 'gpt-6-astra' -DispatchStub $routingStub -RoutingAck)
  foreach($field in @('policyGeneration','registryAuthorityDigest','family','slot','usedLastKnownGood')){
    $partialStub=Join-Path $root "routing-ack-missing-$field.ps1"
    $partialText=$routingStubText.Replace('[IO.File]::WriteAllText($StartAcknowledgementPath',"`$ack.Remove('$field')`n[IO.File]::WriteAllText(`$StartAcknowledgementPath")
    [IO.File]::WriteAllText($partialStub,$partialText,[Text.UTF8Encoding]::new($false))
    [void](Test-AuthorDispatch "routing-ack-missing-$field" $readyPool 'gpt-6-astra' -DispatchStub $partialStub)
  }
  $crossedSlotStub=Join-Path $root 'routing-ack-crossed-slot.ps1'
  [IO.File]::WriteAllText($crossedSlotStub,$routingStubText.Replace("`$ack.slot='explicit'","`$ack.slot='codex.primary'"),[Text.UTF8Encoding]::new($false))
  [void](Test-AuthorDispatch 'routing-ack-crossed-slot' $readyPool 'gpt-6-astra' -DispatchStub $crossedSlotStub)
  Write-Output 'PASS F1 integration launch routing acknowledgement complete; five partial fields and crossed slot refused'
  Write-Output 'CONTROL 8119 Astra filename, Fable isolation, crossed retained acknowledgements, status fail-closed, and alien acknowledgement rejection PASS'
  $env:SYNTHETIC_DISPATCH_CALLS=$calls
  $bad=$fixture.PSObject.Copy();$bad.openPullRequests=[ordered]@{complete=$true;totalCount=[long]5;nodes=$nodes}
  $badPath=Join-Path $root 'incomplete.json';[IO.File]::WriteAllText($badPath,($bad|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
  $unknownFailed=$false;try{& $script -LandedPr 1 -LandedHead $landedHead -HistoryPath $history -RuntimeRoot $runtime -ContainerRoot $root -Repository $SyntheticIntegrationRepository -FixturePath $badPath -IntegrationAuthorityFixturePath $authority -DispatchScript $stub -SynchronousDispatch|Out-Null}catch{$unknownFailed=$true}
  Assert-True ($unknownFailed-and@(Get-Content -LiteralPath $calls).Count-eq3) 'incomplete independent count became empty/success or dispatched'

  $nativeRuntime=Join-Path $root 'native-unknown-runtime';New-Item -ItemType Directory $nativeRuntime|Out-Null;$nativeCalls=Join-Path $nativeRuntime 'calls.txt';$env:SYNTHETIC_DISPATCH_CALLS=$nativeCalls
  $nativeNode=[ordered]@{number=[long]6;headRefOid=('6'*40);headRefName='synthetic/native-unknown';mergeable='UNKNOWN';mergeStateStatus='UNKNOWN';worktree=$worktrees[5];files=[ordered]@{complete=$true;totalCount=[long]1;nodes=@([ordered]@{path='other.txt'})}}
  $nativeFixture=[ordered]@{schemaVersion='landed-integration-census/v1';complete=$true;newBase=$base;activeBranches=@();landed=$fixture.landed;openPullRequests=[ordered]@{complete=$true;totalCount=[long]1;nodes=@($nativeNode)}}
  $nativePath=Join-Path $nativeRuntime 'census.json';[IO.File]::WriteAllText($nativePath,($nativeFixture|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false));$nativeFailed=$false
  try{& $script -LandedPr 1 -LandedHead $landedHead -HistoryPath (Join-Path $nativeRuntime 'history.jsonl') -RuntimeRoot $nativeRuntime -ContainerRoot $root -Repository $SyntheticIntegrationRepository -FixturePath $nativePath -IntegrationAuthorityFixturePath $authority -DispatchScript $stub -SynchronousDispatch|Out-Null}catch{$nativeFailed=$_.Exception.Message-match'CENSUS_UNKNOWN_NATIVE_MERGEABILITY'}
  Assert-True ($nativeFailed-and-not(Test-Path $nativeCalls)-and-not(Test-Path (Join-Path $nativeRuntime 'history.jsonl'))) 'unresolved native mergeability became clean non-intersection or emitted lifecycle rows'

  # Synthetic incident shape only: these PRs, heads, owners and files are not host facts.
  function Invoke-PreflightControl([string]$Name,[scriptblock]$Change,[string]$ExpectedFailure){
    $controlRuntime=Join-Path $root "preflight-$Name";New-Item -ItemType Directory $controlRuntime|Out-Null
    $controlHistory=Join-Path $controlRuntime 'history.jsonl';$controlCalls=Join-Path $controlRuntime 'calls.txt'
    $control=$fixture|ConvertTo-Json -Depth 12|ConvertFrom-Json -DateKind String
    $control.openPullRequests.totalCount=[long]$control.openPullRequests.nodes.Count
    & $Change $control $controlRuntime
    Write-SyntheticIntegrationEligibility $controlHistory $nodes
    $controlPath=Join-Path $controlRuntime 'census.json';$control|ConvertTo-Json -Depth 12|Set-Content $controlPath
    $before=@{};foreach($file in @(Get-ChildItem $controlRuntime -File)){$before[$file.Name]=(Get-FileHash $file.FullName -Algorithm SHA256).Hash}
    $env:SYNTHETIC_DISPATCH_CALLS=$controlCalls;$failure=$null
    try{& $script -LandedPr 1 -LandedHead $landedHead -HistoryPath $controlHistory -RuntimeRoot $controlRuntime -ContainerRoot $root -Repository $SyntheticIntegrationRepository -IntegrationAuthorityFixturePath $authority -FixturePath $controlPath -DispatchScript $stub -SynchronousDispatch|Out-Null}catch{$failure=$_.Exception.Message}
    $mutations=@(Get-ChildItem $controlRuntime -File|Where-Object{$_.Name-notlike'integration-plan-*.json'-and(-not$before.ContainsKey($_.Name)-or$before[$_.Name]-cne(Get-FileHash $_.FullName -Algorithm SHA256).Hash)})
    Assert-True ($failure-like"*$ExpectedFailure*"-and-not(Test-Path $controlCalls)-and$mutations.Count-eq0) "$Name crossed mutation boundary: failure=$failure mutations=$($mutations.Name -join ',')"
    return $controlRuntime
  }
  $missingControl=Invoke-PreflightControl 'early-product-later-missing-controller' {
    param($c,$r)
    $c.openPullRequests.nodes[3].mergeStateStatus='DIRTY'
    $c.openPullRequests.nodes[3].files.nodes[0].path='.orchestrator/synthetic-controller.ps1'
    $c.openPullRequests.nodes[3].worktree=Join-Path $r 'synthetic-missing-controller'
  } 'CENSUS_UNKNOWN_WORKTREE_5'
  $refusedPlans=@(Get-ChildItem $missingControl -Filter 'integration-plan-*.json')
  $refusedPlan=Get-Content $refusedPlans[0].FullName -Raw|ConvertFrom-Json -DateKind String
  Assert-True ($refusedPlans.Count-eq1-and$refusedPlan.targets.Count-eq4-and$refusedPlan.targets[0].action-ceq'LAUNCH'-and$refusedPlan.targets[3].action-ceq'MISSING_WORKTREE') 'missing-worktree refusal lost the complete durable partition'
  foreach($case in @('unknown-root','unknown-file','overflow-pr','fractional-count','duplicate-pr')){
    [void](Invoke-PreflightControl $case {
      param($c,$r)
      switch($case){
        'unknown-root' {$c|Add-Member unexpected $true}
        'unknown-file' {$c.openPullRequests.nodes[3].files.nodes[0]|Add-Member unexpected $true}
        'overflow-pr' {$c.openPullRequests.nodes[3].number=[long]2147483648}
        'fractional-count' {$c.openPullRequests.nodes[3].files.totalCount=1.5}
        'duplicate-pr' {$c.openPullRequests.nodes[3].number=[long]2}
      }
    } 'CENSUS_UNKNOWN')
  }
  [void](Invoke-PreflightControl 'later-malformed-owed' {
    param($c,$r)
    Set-Content (Join-Path $r "integration-owed-4-$($landedHead.Substring(0,12)).json") '{"schemaVersion":"synthetic-invalid-owed"}'
  } 'CENSUS_UNKNOWN_OWED_IDENTITY')
  foreach($case in @('invalid-terminal-time','overflow-terminal-pr','unknown-terminal-field')){
    [void](Invoke-PreflightControl $case {
      param($c,$r)
      $terminal=$dispatches[0]|ConvertTo-Json -Compress|ConvertFrom-Json -DateKind String
      switch($case){
        'invalid-terminal-time' {$terminal.ts='2026-02-30T20:00:00Z'}
        'overflow-terminal-pr' {$terminal.pr=[long]2147483648}
        'unknown-terminal-field' {$terminal|Add-Member unexpected ([pscustomobject]@{synthetic=$true})}
      }
      $terminal|ConvertTo-Json -Compress|Set-Content (Join-Path $r 'history.jsonl')
    } 'CENSUS_UNKNOWN')
  }
  $terminalVariants=@{}
  foreach($version in @('legacy','astra','fable','owed-null','owed-executor')){
    $terminal=$dispatches[0]|ConvertTo-Json -Compress|ConvertFrom-Json -DateKind String
    if($version-ceq'legacy'){$terminal.model='gpt-5.6-terra';$terminal.effort='medium';$terminal.row='2';$terminal.placement='measured'}
    if($version-ceq'fable'){$terminal.harness='claude';$terminal.model='claude-fable-5-1'}
    if($version-like'owed-*'){
      $terminal.integrationDispatchSchema='landed-integration-dispatch/v2';$terminal.disposition='OWED_ACTIVE_WRITER'
      foreach($key in @('harness','model','effort','row','placement')){$terminal.PSObject.Properties.Remove($key)}
      $terminal|Add-Member executionAttribution $null
      if($version-ceq'owed-executor'){$terminal.executionAttribution=[pscustomobject]@{launchId=[guid]::NewGuid().ToString();harness='codex';model='gpt-5.6-terra';effort='medium';row=[long]2;placement='measured';routeIdentity=('a'*64)}}
    }
    $terminalVariants[$version]=$terminal
    $terminalRuntime=Join-Path $root "terminal-$version";New-Item -ItemType Directory $terminalRuntime|Out-Null
    $terminalHistory=Join-Path $terminalRuntime 'history.jsonl';$terminal|ConvertTo-Json -Depth 5 -Compress|Set-Content $terminalHistory
    Write-SyntheticIntegrationEligibility $terminalHistory @($nodes[0])
    $terminalBefore=[IO.File]::ReadAllBytes($terminalHistory)
    $terminalFixture=$fixture|ConvertTo-Json -Depth 12|ConvertFrom-Json -DateKind String
    $terminalFixture.openPullRequests.nodes=@($terminalFixture.openPullRequests.nodes[0]);$terminalFixture.openPullRequests.totalCount=[long]1
    $terminalPath=Join-Path $terminalRuntime 'census.json';$terminalFixture|ConvertTo-Json -Depth 12|Set-Content $terminalPath
    $env:SYNTHETIC_DISPATCH_CALLS=Join-Path $terminalRuntime 'calls.txt'
    $terminalReplay=& $script -LandedPr 1 -LandedHead $landedHead -HistoryPath $terminalHistory -RuntimeRoot $terminalRuntime -ContainerRoot $root -Repository $SyntheticIntegrationRepository -FixturePath $terminalPath -IntegrationAuthorityFixturePath $authority -DispatchScript $stub -SynchronousDispatch|ConvertFrom-Json -DateKind String
    Assert-True ($terminalReplay.targets[0].action-ceq'DUPLICATE_SKIPPED'-and-not(Test-Path $env:SYNTHETIC_DISPATCH_CALLS)-and[Convert]::ToBase64String($terminalBefore)-ceq[Convert]::ToBase64String([IO.File]::ReadAllBytes($terminalHistory))) "terminal $version compatibility or byte preservation"
  }
  foreach($case in @('crossed-tuple','fable-crossed-harness','fable-crossed-model','numeric-v1-row','v2-launch','v2-extra','v2-missing','v2-row','duplicate-terminal','crossed-terminal')){
    [void](Invoke-PreflightControl $case {
      param($c,$r)
      $variant=if($case-like'v2-*'){'owed-executor'}elseif($case-like'fable-*'){'fable'}else{'astra'}
      $terminal=$terminalVariants[$variant]|ConvertTo-Json -Depth 5|ConvertFrom-Json -DateKind String
      switch($case){
        'crossed-tuple' {$terminal.effort='medium'}
        'fable-crossed-harness' {$terminal.harness='codex'}
        'fable-crossed-model' {$terminal.model='claude-opus-5-5'}
        'numeric-v1-row' {$terminal.row=[long]7}
        'v2-launch' {$terminal.disposition='LAUNCHED'}
        'v2-extra' {$terminal.executionAttribution|Add-Member unexpected $true}
        'v2-missing' {$terminal.PSObject.Properties.Remove('executionAttribution')}
        'v2-row' {$terminal.executionAttribution.row=1.5}
        'crossed-terminal' {$terminal.targetBranch='synthetic/crossed'}
      }
      $line=$terminal|ConvertTo-Json -Depth 5 -Compress
      if($case-ceq'duplicate-terminal'){$line+="`n$line"}
      Set-Content (Join-Path $r 'history.jsonl') $line
    } 'CENSUS_UNKNOWN')
  }
  Write-Output 'CONTROL 7962/8018/8119 terminal corpus legacy/Astra/Fable/v2-null/v2-executor=byte-stable replay; crossed/duplicate/malformed=zero-effects refusal'
  $replayRuntime=Join-Path $root 'synthetic-partial-replay';New-Item -ItemType Directory $replayRuntime|Out-Null
  $replayHistory=Join-Path $replayRuntime 'history.jsonl';$replayCalls=Join-Path $replayRuntime 'calls.txt';$env:SYNTHETIC_DISPATCH_CALLS=$replayCalls
  $dispatches[0]|ConvertTo-Json -Compress|Set-Content $replayHistory
  Write-SyntheticIntegrationEligibility $replayHistory $nodes
  $replayFixture=$fixture|ConvertTo-Json -Depth 12|ConvertFrom-Json -DateKind String
  $replayFixture.openPullRequests.totalCount=[long]$replayFixture.openPullRequests.nodes.Count
  $replayFixture.activeBranches=@('synthetic/intersect')
  $replayFixture.openPullRequests.nodes[3].mergeStateStatus='DIRTY'
  $replayFixture.openPullRequests.nodes[3].files.nodes[0].path='.orchestrator/synthetic-controller.ps1'
  $replayPath=Join-Path $replayRuntime 'census.json';$replayFixture|ConvertTo-Json -Depth 12|Set-Content $replayPath
  $replay=& $script -LandedPr 1 -LandedHead $landedHead -HistoryPath $replayHistory -RuntimeRoot $replayRuntime -ContainerRoot $root -Repository $SyntheticIntegrationRepository -IntegrationAuthorityFixturePath $authority -FixturePath $replayPath -DispatchScript $stub -SynchronousDispatch|ConvertFrom-Json -DateKind String
  $replayAgain=& $script -LandedPr 1 -LandedHead $landedHead -HistoryPath $replayHistory -RuntimeRoot $replayRuntime -ContainerRoot $root -Repository $SyntheticIntegrationRepository -IntegrationAuthorityFixturePath $authority -FixturePath $replayPath -DispatchScript $stub -SynchronousDispatch|ConvertFrom-Json -DateKind String
  Assert-True (@(Get-Content $replayCalls).Count-eq2-and@(Get-Content $replayHistory).Count-eq7-and@($replay.targets|Where-Object{$_.pr-eq2-and$_.action-ceq'DUPLICATE_SKIPPED'}).Count-eq1-and@($replayAgain.targets|Where-Object{$_.action-ceq'DUPLICATE_SKIPPED'}).Count-eq3-and@($replay.targets|Where-Object{$_.pr-eq5-and$_.action-ceq'CONTROLLER_ADMISSION_REQUIRED'}).Count-eq1) 'partial replay duplicated an already terminal active target, stranded a validated target, or launched a controller author'
  Assert-True (@(Get-ChildItem $replayRuntime -Filter 'integration-owed-*.json').Count-eq0) 'terminal active owner acquired a duplicate owed integration'
  Write-Output 'CONTROL 8018 early-product/later-missing-controller launches=0 mutationRows=0 durableTargets=4; partial-replay existingTerminalActiveOwner=skipped stillOwedLaunches=2 repeatLaunches=0 controller=admission-required'

  $worktreeContainer=Join-Path $root 'synthetic-f17-container';$productRepository=Join-Path $worktreeContainer 'main';New-Item -ItemType Directory -Path $worktreeContainer,$productRepository|Out-Null
  & git -C $worktreeContainer init -q --initial-branch=main;& git -C $worktreeContainer config user.name 'Synthetic F17 Meta Repository';& git -C $worktreeContainer config user.email 'synthetic-f17-meta@example.invalid';Set-Content (Join-Path $worktreeContainer 'meta-seed.txt') 'unmistakably synthetic meta repository';& git -C $worktreeContainer add meta-seed.txt;& git -C $worktreeContainer commit -q -m 'synthetic meta seed'
  & git -C $productRepository init -q --initial-branch=main;& git -C $productRepository config user.name 'Synthetic F17 Product Repository';& git -C $productRepository config user.email 'synthetic-f17-product@example.invalid';Set-Content (Join-Path $productRepository 'product-seed.txt') 'unmistakably synthetic product repository';& git -C $productRepository add product-seed.txt;& git -C $productRepository commit -q -m 'synthetic product seed'
  $productOnlyWorktree=Join-Path $worktreeContainer 'synthetic-f17-product-only-lane';$productShadowedWorktree=Join-Path $worktreeContainer 'synthetic-f17-canonical-shadowed-lane';$metaOnlyWorktree=Join-Path $worktreeContainer 'synthetic-f17-wrong-meta-only-lane';$metaShadowWorktree=Join-Path $worktreeContainer 'synthetic-f17-same-name-shadow-lane'
  & git -C $productRepository worktree add -q -b synthetic/f17-product-only $productOnlyWorktree HEAD;& git -C $productRepository worktree add -q -b synthetic/f17-shadowed $productShadowedWorktree HEAD
  & git -C $worktreeContainer worktree add -q -b synthetic/f17-meta-only $metaOnlyWorktree HEAD;& git -C $worktreeContainer worktree add -q -b synthetic/f17-shadowed $metaShadowWorktree HEAD
  Publish-SyntheticIntegrationRemote $productRepository (Join-Path $worktreeContainer 'product-remote.git')
  function Invoke-F17WorktreeControl([string]$Name,[long]$Pr,[string]$Branch,[string]$Head,[string]$ExpectedWorktree,[string]$ExpectedFailure){
    $controlRuntime=Join-Path $worktreeContainer "runtime-$Name";New-Item -ItemType Directory -Path $controlRuntime|Out-Null;$controlHistory=Join-Path $controlRuntime 'history.jsonl';$controlCalls=Join-Path $controlRuntime 'calls.txt';$env:SYNTHETIC_DISPATCH_CALLS=$controlCalls
    $controlFixture=[ordered]@{schemaVersion='landed-integration-census/v1';complete=$true;newBase=(& git -C $productRepository rev-parse refs/remotes/origin/main).Trim();activeBranches=@();landed=[ordered]@{pr=[long]9907856;head=$landedHead;files=[ordered]@{complete=$true;totalCount=[long]1;nodes=@([ordered]@{path='synthetic-f17-shared.txt'})}};openPullRequests=[ordered]@{complete=$true;totalCount=[long]1;nodes=@([ordered]@{number=$Pr;headRefOid=$Head;headRefName=$Branch;mergeable='MERGEABLE';mergeStateStatus='CLEAN';files=[ordered]@{complete=$true;totalCount=[long]1;nodes=@([ordered]@{path='synthetic-f17-shared.txt'})}})}}
    $controlFixturePath=Join-Path $controlRuntime 'census.json';[IO.File]::WriteAllText($controlFixturePath,($controlFixture|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false));$failure=$null;$value=$null
    $controlAuthority=Write-SyntheticIntegrationAuthority (Join-Path $worktreeContainer "authority-$Name.json") $controlFixture.openPullRequests.nodes $controlFixture.newBase
    Write-SyntheticIntegrationEligibility $controlHistory $controlFixture.openPullRequests.nodes
    try{$value=& $script -LandedPr 9907856 -LandedHead $landedHead -HistoryPath $controlHistory -RuntimeRoot $controlRuntime -ContainerRoot $worktreeContainer -Repository $SyntheticIntegrationRepository -FixturePath $controlFixturePath -IntegrationAuthorityFixturePath $controlAuthority -DispatchScript $stub -SynchronousDispatch|ConvertFrom-Json -DateKind String}catch{$failure=$_.Exception.Message}
    [string[]]$callLines=if(Test-Path -LiteralPath $controlCalls){@(Get-Content -LiteralPath $controlCalls)}else{@()};[string[]]$historyLines=if(Test-Path -LiteralPath $controlHistory){@(Get-Content -LiteralPath $controlHistory)}else{@()}
    if($ExpectedFailure){
      $launchArtifacts=@(Get-ChildItem -LiteralPath $controlRuntime -File|Where-Object{$_.Name-notin@('census.json','history.jsonl')-and$_.Name-notlike'integration-plan-*.json'})
      Assert-True ($failure-ceq$ExpectedFailure-and$callLines.Count-eq0-and$historyLines.Count-eq1-and$launchArtifacts.Count-eq0) "$Name did not fail closed before append/launch (failure=$failure calls=$($callLines.Count) history=$($historyLines.Count) artifacts=$($launchArtifacts.Count))"
    }else{
      $calledWorktree=if($callLines.Count-eq1){([string]$callLines[0]).Split('|')[1]}else{''};$actual=if($calledWorktree){[IO.Path]::GetFullPath($calledWorktree).TrimEnd('\','/')}else{''};$expected=[IO.Path]::GetFullPath($ExpectedWorktree).TrimEnd('\','/')
      Assert-True ($null-eq$failure-and$value.targetCount-eq1-and$value.targets[0].action-ceq'LAUNCHED'-and$callLines.Count-eq1-and$historyLines.Count-eq2-and[string]::Equals($actual,$expected,[StringComparison]::OrdinalIgnoreCase)) "$Name did not dispatch the exact registered product sibling (failure=$failure targetCount=$($value.targetCount) calls=$($callLines.Count) history=$($historyLines.Count) actual=$actual expected=$expected)"
    }
  }
  $productOnlyHead=(& git -C $productOnlyWorktree rev-parse HEAD).Trim();$productShadowedHead=(& git -C $productShadowedWorktree rev-parse HEAD).Trim();$metaOnlyHead=(& git -C $metaOnlyWorktree rev-parse HEAD).Trim()
  Invoke-F17WorktreeControl 'product-only' 9907652 'synthetic/f17-product-only' $productOnlyHead $productOnlyWorktree $null
  Invoke-F17WorktreeControl 'absent' 9907653 'synthetic/f17-absent' ('d'*40) $null 'CENSUS_UNKNOWN_WORKTREE_9907653'
  Invoke-F17WorktreeControl 'wrong-meta-only' 9907654 'synthetic/f17-meta-only' $metaOnlyHead $null 'CENSUS_UNKNOWN_WORKTREE_9907654'
  Invoke-F17WorktreeControl 'same-name-shadow' 9907655 'synthetic/f17-shadowed' $productShadowedHead $productShadowedWorktree $null
  Write-Output 'CONTROL F17 nestedRepositories productOnly=product-sibling absent=unknown wrongMetaOnly=unknown sameNameShadow=product-sibling zeroUnresolvedAppendLaunch=true'

  $failedRuntime=Join-Path $root 'launch-failure-runtime';New-Item -ItemType Directory $failedRuntime|Out-Null;$failedCalls=Join-Path $failedRuntime 'calls.txt';$env:SYNTHETIC_DISPATCH_CALLS=$failedCalls;$env:SYNTHETIC_INTEGRATION_FAIL='integration-1-2-'
  $failedFixture=[ordered]@{schemaVersion='landed-integration-census/v1';complete=$true;newBase=$base;activeBranches=@();landed=$fixture.landed;openPullRequests=[ordered]@{complete=$true;totalCount=[long]1;nodes=@($nodes[0])}}
  $failedPath=Join-Path $failedRuntime 'census.json';[IO.File]::WriteAllText($failedPath,($failedFixture|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false));$failedHistory=Join-Path $failedRuntime 'history.jsonl'
  Write-SyntheticIntegrationEligibility $failedHistory @($nodes[0])
  $failedHistoryBefore=[IO.File]::ReadAllText($failedHistory)
  $failedOne=& $script -LandedPr 1 -LandedHead $landedHead -HistoryPath $failedHistory -RuntimeRoot $failedRuntime -ContainerRoot $root -Repository $SyntheticIntegrationRepository -FixturePath $failedPath -IntegrationAuthorityFixturePath $authority -DispatchScript $stub -SynchronousDispatch|ConvertFrom-Json -DateKind String
  $failedTwo=& $script -LandedPr 1 -LandedHead $landedHead -HistoryPath $failedHistory -RuntimeRoot $failedRuntime -ContainerRoot $root -Repository $SyntheticIntegrationRepository -FixturePath $failedPath -IntegrationAuthorityFixturePath $authority -DispatchScript $stub -SynchronousDispatch|ConvertFrom-Json -DateKind String
  Assert-True ($failedOne.targets[0].action-ceq'LAUNCH_FAILED'-and$failedTwo.targets[0].action-ceq'LAUNCH_FAILED'-and@(Get-Content $failedCalls).Count-eq2-and[IO.File]::ReadAllText($failedHistory)-ceq$failedHistoryBefore) 'failed integration launcher was logged as success or made retry unrecoverable'
  Remove-Item Env:SYNTHETIC_INTEGRATION_FAIL

  $consumerRepo=Join-Path $root 'synthetic-owed-repo';New-Item -ItemType Directory $consumerRepo|Out-Null;& git -C $consumerRepo init -q --initial-branch=main;& git -C $consumerRepo config user.name 'Synthetic Owed Test';& git -C $consumerRepo config user.email 'synthetic-owed@example.invalid'
  Set-Content (Join-Path $consumerRepo 'base.txt') 'base';& git -C $consumerRepo add base.txt;& git -C $consumerRepo commit -q -m base;& git -C $consumerRepo checkout -q -b synthetic/owed
  Set-Content (Join-Path $consumerRepo 'feature.txt') 'feature';& git -C $consumerRepo add feature.txt;& git -C $consumerRepo commit -q -m feature;$owedTarget=(& git -C $consumerRepo rev-parse HEAD).Trim()
  & git -C $consumerRepo checkout -q main;Set-Content (Join-Path $consumerRepo 'main.txt') 'new base';& git -C $consumerRepo add main.txt;& git -C $consumerRepo commit -q -m advance;$owedBase=(& git -C $consumerRepo rev-parse HEAD).Trim();& git -C $consumerRepo checkout -q synthetic/owed
  $consumerRuntime=Join-Path $root 'consumer-runtime';New-Item -ItemType Directory $consumerRuntime|Out-Null;$owed=[ordered]@{schemaVersion='landed-integration-owed/v1';landedPr=[long]1;landedHead=$landedHead;pr=[long]7;targetHead=$owedTarget;newBase=$owedBase;branch='synthetic/owed';worktree=[IO.Path]::GetFullPath($consumerRepo).TrimEnd('\','/');integrationLane='synthetic-owed-integration'}
  [IO.File]::WriteAllText((Join-Path $consumerRuntime 'integration-owed-7-synthetic.json'),($owed|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false));$consumer=Join-Path $PSScriptRoot 'landed-integration-consume.ps1'
  $integrationCalls=Join-Path $consumerRuntime 'integration-calls.txt';$integrationWrapper=Join-Path $consumerRuntime 'integration-wrapper.ps1'
  Set-Content -LiteralPath $integrationWrapper -Value "Add-Content -LiteralPath '$($integrationCalls.Replace("'","''"))' -Value integration`n& '$((Join-Path $PSScriptRoot 'rebase-integration.ps1').Replace("'","''"))' @args`nexit `$LASTEXITCODE"
  $otherOwed=[ordered]@{schemaVersion='landed-integration-owed/v1';landedPr=[long]1;landedHead=$landedHead;pr=[long]8;targetHead=('8'*40);newBase=$owedBase;branch='synthetic/other';worktree=[IO.Path]::GetFullPath($worktrees[5]).TrimEnd('\','/');integrationLane='synthetic-other-integration'};$otherOwedPath=Join-Path $consumerRuntime 'integration-owed-8-synthetic.json';[IO.File]::WriteAllText($otherOwedPath,($otherOwed|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
  $consumeOne=& $consumer -Branch 'synthetic/owed' -Worktree $consumerRepo -RuntimeRoot $consumerRuntime -HistoryPath (Join-Path $consumerRuntime 'history.jsonl') -IntegrationScript $integrationWrapper -NoPush|ConvertFrom-Json -DateKind String;$consumedHead=(& git -C $consumerRepo rev-parse HEAD).Trim();$consumedBranch=(& git -C $consumerRepo branch --show-current).Trim()
  Set-Content (Join-Path $consumerRepo 'descendant.txt') 'later descendant';& git -C $consumerRepo add descendant.txt;& git -C $consumerRepo commit -q -m descendant;$descendantHead=(& git -C $consumerRepo rev-parse HEAD).Trim()
  [IO.File]::WriteAllText((Join-Path $consumerRuntime 'integration-owed-7-synthetic.json'),($owed|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
  $consumeTwo=& $consumer -Branch 'synthetic/owed' -Worktree $consumerRepo -RuntimeRoot $consumerRuntime -HistoryPath (Join-Path $consumerRuntime 'history.jsonl') -IntegrationScript $integrationWrapper -NoPush|ConvertFrom-Json -DateKind String;$replayHead=(& git -C $consumerRepo rev-parse HEAD).Trim()
  $exactOwedPath=Join-Path $consumerRuntime 'integration-owed-7-synthetic.json';[IO.File]::WriteAllText($exactOwedPath,($owed|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
  & git -C $consumerRepo reset -q --hard $owedTarget
  $resetFailed=$false;try{& $consumer -Branch 'synthetic/owed' -Worktree $consumerRepo -RuntimeRoot $consumerRuntime -HistoryPath (Join-Path $consumerRuntime 'history.jsonl') -IntegrationScript $integrationWrapper -NoPush|Out-Null}catch{$resetFailed=$_.Exception.Message-match'OWED_INTEGRATION_ACK_UNKNOWN'}
  $ackPath=@(Get-ChildItem $consumerRuntime -Filter 'integration-owed-ack-*.json')[0].FullName;$ackOriginal=[IO.File]::ReadAllText($ackPath);$ackMissing=$ackOriginal|ConvertFrom-Json -DateKind String;$ackMissing.resultHead='f'*40;[IO.File]::WriteAllText($ackPath,($ackMissing|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
  $missingFailed=$false;try{& $consumer -Branch 'synthetic/owed' -Worktree $consumerRepo -RuntimeRoot $consumerRuntime -HistoryPath (Join-Path $consumerRuntime 'history.jsonl') -IntegrationScript $integrationWrapper -NoPush|Out-Null}catch{$missingFailed=$_.Exception.Message-match'OWED_INTEGRATION_ACK_UNKNOWN'};[IO.File]::WriteAllText($ackPath,$ackOriginal,[Text.UTF8Encoding]::new($false))
  $ambiguousGit=Join-Path $consumerRuntime 'ambiguous-git.ps1';Set-Content -LiteralPath $ambiguousGit -Value "if (`$args -contains 'merge-base') { Write-Output ambiguous; exit 2 }`n& git @args`nexit `$LASTEXITCODE"
  $ambiguousFailed=$false;try{& $consumer -Branch 'synthetic/owed' -Worktree $consumerRepo -RuntimeRoot $consumerRuntime -HistoryPath (Join-Path $consumerRuntime 'history.jsonl') -IntegrationScript $integrationWrapper -GitExecutable $ambiguousGit -NoPush|Out-Null}catch{$ambiguousFailed=$_.Exception.Message-match'OWED_INTEGRATION_ACK_UNKNOWN'}
  Assert-True ($consumeOne.consumed-eq1-and$consumeOne.results[0].status-ceq'REVIEW_REQUIRED'-and$consumeTwo.consumed-eq1-and$consumeTwo.results[0].status-ceq'ACKNOWLEDGED_REPLAY'-and$descendantHead-cne$consumedHead-and$replayHead-ceq$descendantHead-and$consumedBranch-ceq'synthetic/owed'-and@(Get-Content $integrationCalls).Count-eq1-and@(Get-ChildItem $consumerRuntime -Filter 'integration-owed-ack-*.json').Count-eq1-and$resetFailed-and$missingFailed-and$ambiguousFailed-and(Test-Path $exactOwedPath)-and(Test-Path $otherOwedPath)) 'descendant acknowledgement replay changed HEAD/rebased twice, or reset/missing/ambiguous Git did not remain unknown with only the matching obligation retained'

  function Wait-SyntheticFile([string]$Path,[int]$Seconds=20){$deadline=[DateTime]::UtcNow.AddSeconds($Seconds);while(-not(Test-Path -LiteralPath $Path -PathType Leaf)){if([DateTime]::UtcNow-ge$deadline){throw "synthetic barrier expired: $Path"};[Threading.Thread]::Sleep(25)}}
  function Start-SyntheticPwsh([string[]]$Arguments,[string]$Stdout,[string]$Stderr,[switch]$HandoffCoordinator){
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=(Get-Command pwsh -CommandType Application|Select-Object -First 1 -ExpandProperty Source);$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $start.RedirectStandardInput=[bool]$HandoffCoordinator
    foreach($argument in $Arguments){[void]$start.ArgumentList.Add($argument)}
    $process=[Diagnostics.Process]::Start($start);$outTask=$process.StandardOutput.ReadToEndAsync();$errTask=$process.StandardError.ReadToEndAsync();[pscustomobject]@{process=$process;stdoutTask=$outTask;stderrTask=$errTask;stdout=$Stdout;stderr=$Stderr}
  }
  function Complete-SyntheticPwsh($Handle,[int]$Seconds=45){if(-not$Handle.process.WaitForExit($Seconds*1000)){throw "synthetic process did not finish: $($Handle.process.Id)"};$out=$Handle.stdoutTask.GetAwaiter().GetResult();$err=$Handle.stderrTask.GetAwaiter().GetResult();[IO.File]::WriteAllText($Handle.stdout,$out,[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($Handle.stderr,$err,[Text.UTF8Encoding]::new($false));$code=$Handle.process.ExitCode;$Handle.process.Dispose();[pscustomobject]@{exitCode=$code;stdout=$out;stderr=$err}}
  $raceContainer=Join-Path $root 'synthetic-release-race-container';$raceRepo=Join-Path $raceContainer 'race-lane';$raceRuntime=Join-Path $raceContainer 'runtime';$raceTemp=Join-Path $raceContainer 'private-temp';New-Item -ItemType Directory -Path $raceRepo,$raceRuntime,$raceTemp|Out-Null
  & git -C $raceRepo init -q --initial-branch=main;& git -C $raceRepo config user.name 'Synthetic Release Race';& git -C $raceRepo config user.email 'synthetic-release-race@example.invalid';Set-Content (Join-Path $raceRepo 'base.txt') 'base';& git -C $raceRepo add base.txt;& git -C $raceRepo commit -q -m base;& git -C $raceRepo checkout -q -b synthetic/release-race;Set-Content (Join-Path $raceRepo 'feature.txt') 'feature';& git -C $raceRepo add feature.txt;& git -C $raceRepo commit -q -m feature;$raceTarget=(& git -C $raceRepo rev-parse HEAD).Trim();& git -C $raceRepo checkout -q main;Set-Content (Join-Path $raceRepo 'main.txt') 'new base';& git -C $raceRepo add main.txt;& git -C $raceRepo commit -q -m advance;$raceBase=(& git -C $raceRepo rev-parse HEAD).Trim();& git -C $raceRepo checkout -q synthetic/release-race
  $racePrompt=Join-Path $raceContainer 'owner.prompt.txt';Set-Content $racePrompt 'unmistakably synthetic owner';$childRelease=Join-Path $raceContainer 'release-child';$childScript=Join-Path $raceContainer 'owner-child.ps1';Set-Content $childScript 'param($Release);Write-Output ''{"type":"item.completed"}'';while(-not(Test-Path -LiteralPath $Release)){[Threading.Thread]::Sleep(25)}'
  $ownerScanned=Join-Path $raceContainer 'owner-scanned';$ownerContinue=Join-Path $raceContainer 'owner-continue';$producerSnapshotted=Join-Path $raceContainer 'producer-snapshotted';$publicationContinue=Join-Path $raceContainer 'publication-continue';$raceHistory=Join-Path $raceRuntime 'dispatch-log.jsonl';$raceCalls=Join-Path $raceRuntime 'second-writer-calls.txt';$env:SYNTHETIC_DISPATCH_CALLS=$raceCalls
  $ownerWrapper=Join-Path $raceContainer 'owner-launcher.ps1';$ownerValues=@{dispatch=(Join-Path $PSScriptRoot 'dispatch-lane.ps1');prompt=$racePrompt;repo=$raceRepo;runtime=$raceRuntime;temp=$raceTemp;observed=$ownerScanned;continue=$ownerContinue;exe=(Get-Command pwsh -CommandType Application|Select-Object -First 1 -ExpandProperty Source);child=$childScript;release=$childRelease};$ownerWrapperText=@'
& '{0}' -Harness codex -Model gpt-6.1-sol -Effort medium -LaneRole implementation -PromptFile '{1}' -Worktree '{2}' -Label synthetic-release-owner -Row 2 -Placement provisional -ExecutablePath '{3}' -TestRuntimeRoot '{4}' -TestTempRoot '{5}' -OwedReleaseScanObservedPath '{6}' -OwedReleaseScanContinuePath '{7}' -TestArgumentList @('-NoProfile','-NonInteractive','-File','{8}','{9}')
exit $LASTEXITCODE
'@ -f @($ownerValues.dispatch,$ownerValues.prompt,$ownerValues.repo,$ownerValues.exe,$ownerValues.runtime,$ownerValues.temp,$ownerValues.observed,$ownerValues.continue,$ownerValues.child,$ownerValues.release|ForEach-Object{$_.Replace("'","''")});[IO.File]::WriteAllText($ownerWrapper,$ownerWrapperText,[Text.UTF8Encoding]::new($false))
  $ownerArgs=@('-NoProfile','-NonInteractive','-File',$ownerWrapper)
  $ownerHandle=Start-SyntheticPwsh $ownerArgs (Join-Path $raceContainer 'owner.stdout.log') (Join-Path $raceContainer 'owner.stderr.log')
  $ownerRecordDeadline=[DateTime]::UtcNow.AddSeconds(20);do{$ownerRecords=@(Get-ChildItem -LiteralPath $raceRuntime -Filter 'dispatch-launch-*.json' -File -ErrorAction SilentlyContinue);if($ownerRecords.Count-eq1){break};if([DateTime]::UtcNow-ge$ownerRecordDeadline){throw 'synthetic exact owner was not published'};[Threading.Thread]::Sleep(25)}while($true)
  $raceFixture=[ordered]@{schemaVersion='landed-integration-census/v1';complete=$true;newBase=$raceBase;landed=[ordered]@{pr=[long]900100;head=('1'*40);files=[ordered]@{complete=$true;totalCount=[long]1;nodes=@([ordered]@{path='feature.txt'})}};openPullRequests=[ordered]@{complete=$true;totalCount=[long]1;nodes=@([ordered]@{number=[long]900101;headRefOid=$raceTarget;headRefName='synthetic/release-race';mergeable='MERGEABLE';mergeStateStatus='CLEAN';worktree=$raceRepo;files=[ordered]@{complete=$true;totalCount=[long]1;nodes=@([ordered]@{path='feature.txt'})}})}}
  $raceFixturePath=Join-Path $raceContainer 'census.json';[IO.File]::WriteAllText($raceFixturePath,($raceFixture|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
  Write-SyntheticIntegrationEligibility $raceHistory $raceFixture.openPullRequests.nodes
  $producerArgs=@('-NoProfile','-NonInteractive','-File',$script,'-LandedPr','900100','-LandedHead',('1'*40),'-HistoryPath',$raceHistory,'-RuntimeRoot',$raceRuntime,'-ContainerRoot',$raceContainer,'-Repository',$SyntheticIntegrationRepository,'-FixturePath',$raceFixturePath,'-DispatchScript',$stub,'-ActiveSnapshotObservedPath',$producerSnapshotted,'-PublicationContinuePath',$publicationContinue,'-NoPushIntegration')
  $producerHandle=Start-SyntheticPwsh $producerArgs (Join-Path $raceContainer 'producer.stdout.log') (Join-Path $raceContainer 'producer.stderr.log')
  Wait-SyntheticFile $producerSnapshotted;[IO.File]::WriteAllText($childRelease,'release',[Text.UTF8Encoding]::new($false));Wait-SyntheticFile $ownerScanned;[IO.File]::WriteAllText($ownerContinue,'continue',[Text.UTF8Encoding]::new($false));$ownerResult=Complete-SyntheticPwsh $ownerHandle
  Assert-True ($ownerResult.exitCode-eq0-and@(Get-ChildItem -LiteralPath $raceRuntime -Filter 'dispatch-launch-*.json' -File).Count-eq0) "synthetic exact owner did not release before publication: $($ownerResult.stderr)"
  [IO.File]::WriteAllText($publicationContinue,'publish',[Text.UTF8Encoding]::new($false));$producerResult=Complete-SyntheticPwsh $producerHandle;$producerMatch=[regex]::Match($producerResult.stdout,'(?s)\{\s*"schemaVersion"\s*:\s*"landed-integration-dispatch-result/v1".*\}\s*$');if(-not$producerMatch.Success){throw "synthetic producer emitted no result (exit=$($producerResult.exitCode) stdout=$($producerResult.stdout) stderr=$($producerResult.stderr))"};$producerJson=$producerMatch.Value|ConvertFrom-Json -DateKind String;$raceHead=(& git -C $raceRepo rev-parse HEAD).Trim()
  $raceReplay=& $script -LandedPr 900100 -LandedHead ('1'*40) -HistoryPath $raceHistory -RuntimeRoot $raceRuntime -ContainerRoot $raceContainer -Repository $SyntheticIntegrationRepository -FixturePath $raceFixturePath -DispatchScript $stub -NoPushIntegration|ConvertFrom-Json -DateKind String
  $raceObligations=@(Get-ChildItem -LiteralPath $raceRuntime -Filter 'integration-owed-*.json' -File|Where-Object{$_.Name-notlike'integration-owed-ack-*'-and$_.Name-notlike'integration-owed-accept-*'});$raceAcks=@(Get-ChildItem -LiteralPath $raceRuntime -Filter 'integration-owed-ack-*.json' -File);$raceRows=@(Get-Content $raceHistory|ForEach-Object{$_|ConvertFrom-Json -DateKind String}|Where-Object{$_.integrationDispatchSchema-cin@('landed-integration-dispatch/v1','landed-integration-dispatch/v2')})
  Assert-True ($producerResult.exitCode-eq0-and$producerJson.targets[0].action-ceq'OWED_ACTIVE_WRITER'-and$producerJson.targets[0].handoff-ceq'NO_OWNER_CLAIM'-and$raceHead-cne$raceTarget-and$raceObligations.Count-eq0-and$raceAcks.Count-eq0-and$raceRows.Count-eq1-and$raceReplay.targets[0].action-ceq'DUPLICATE_SKIPPED'-and-not(Test-Path $raceCalls)-and@(Get-ChildItem -LiteralPath $raceRuntime -Filter 'dispatch-launch-*.json' -File).Count-eq0) "release-before-publication barrier did not yield one integration/terminal, zero retained acknowledgements/stranded obligations/second writers, and acknowledged-only duplicate suppression: $($producerResult.stderr)"

  foreach($handoffArm in @('durable-owner','withheld-ack')){
  $ownerContainer=Join-Path $root ('synthetic-exact-owner-container-'+$handoffArm);$ownerRepo=Join-Path $ownerContainer 'owner-lane';$ownerRuntime=Join-Path $ownerContainer 'runtime';New-Item -ItemType Directory -Path $ownerRepo,$ownerRuntime|Out-Null;& git -C $ownerRepo init -q --initial-branch=main;& git -C $ownerRepo config user.name 'Synthetic Exact Owner';& git -C $ownerRepo config user.email 'synthetic-exact-owner@example.invalid';Set-Content (Join-Path $ownerRepo 'base.txt') base;& git -C $ownerRepo add base.txt;& git -C $ownerRepo commit -q -m base;& git -C $ownerRepo checkout -q -b synthetic/exact-owner;Set-Content (Join-Path $ownerRepo 'feature.txt') feature;& git -C $ownerRepo add feature.txt;& git -C $ownerRepo commit -q -m feature;$ownerTarget=(& git -C $ownerRepo rev-parse HEAD).Trim();& git -C $ownerRepo checkout -q main;Set-Content (Join-Path $ownerRepo 'main.txt') advance;& git -C $ownerRepo add main.txt;& git -C $ownerRepo commit -q -m advance;$ownerBase=(& git -C $ownerRepo rev-parse HEAD).Trim();& git -C $ownerRepo checkout -q synthetic/exact-owner
  $exactLaunch=[guid]::NewGuid().ToString();$exactOwnerPath=Join-Path $ownerRuntime "dispatch-launch-$exactLaunch.json";$exactPrompt=Join-Path $ownerRuntime "dispatch-heavy-verifier-$exactLaunch.prompt.txt";$exactTranscript=Join-Path $ownerRuntime 'synthetic-exact-owner.jsonl';[IO.File]::WriteAllText($exactPrompt,'exact owner',[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($exactTranscript,"{`"type`":`"item.completed`"}`n",[Text.UTF8Encoding]::new($false));$testStart=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
  $exactOwner=[ordered]@{schemaVersion=4;launchId=$exactLaunch;laneRole='implementation';promptPath=$exactPrompt;reviewIsolationRoot=$null;launcherPid=[long]$PID;launcherStartIdentity=$testStart;recordedAt=[DateTime]::UtcNow.ToString('o');state='launching';childPid=$null;childStartIdentity=$null;worktree=[IO.Path]::GetFullPath($ownerRepo).TrimEnd('\','/');lane='owner-lane';identityMode='branch';branch='synthetic/exact-owner';head=$ownerTarget;label='synthetic-exact-owner';transcriptPath=$exactTranscript};[IO.File]::WriteAllText($exactOwnerPath,($exactOwner|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
  $ownerFixture=[ordered]@{schemaVersion='landed-integration-census/v1';complete=$true;newBase=$ownerBase;landed=[ordered]@{pr=[long]900200;head=('2'*40);files=[ordered]@{complete=$true;totalCount=[long]1;nodes=@([ordered]@{path='feature.txt'})}};openPullRequests=[ordered]@{complete=$true;totalCount=[long]1;nodes=@([ordered]@{number=[long]900201;headRefOid=$ownerTarget;headRefName='synthetic/exact-owner';mergeable='MERGEABLE';mergeStateStatus='CLEAN';worktree=$ownerRepo;files=[ordered]@{complete=$true;totalCount=[long]1;nodes=@([ordered]@{path='feature.txt'})}})}};$ownerFixturePath=Join-Path $ownerContainer 'census.json';[IO.File]::WriteAllText($ownerFixturePath,($ownerFixture|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false));$ownerHistory=Join-Path $ownerRuntime 'history.jsonl';$ownerCalls=Join-Path $ownerRuntime 'second-writer-calls.txt';$env:SYNTHETIC_DISPATCH_CALLS=$ownerCalls
  $handoffEntered=Join-Path $ownerContainer 'handoff-entered';$handoffContinue=Join-Path $ownerContainer 'handoff-continue'
  Write-SyntheticIntegrationEligibility $ownerHistory $ownerFixture.openPullRequests.nodes
  $nativeTrace=Join-Path $ownerContainer 'native-git-trace.jsonl';$previousTrace=$env:GIT_TRACE2_EVENT;$env:GIT_TRACE2_EVENT=$nativeTrace
  $exactProducer=$null;$exactProducerResult=$null
  try{
    $exactProducerArgs=@('-NoProfile','-NonInteractive','-File',$script,'-LandedPr','900200','-LandedHead',('2'*40),'-HistoryPath',$ownerHistory,'-RuntimeRoot',$ownerRuntime,'-ContainerRoot',$ownerContainer,'-Repository',$SyntheticIntegrationRepository,'-FixturePath',$ownerFixturePath,'-DispatchScript',$stub,'-HandoffEnteredPath',$handoffEntered,'-HandoffContinuePath',$handoffContinue,'-NoPushIntegration')
    $exactProducer=Start-SyntheticPwsh $exactProducerArgs (Join-Path $ownerContainer 'producer.stdout.log') (Join-Path $ownerContainer 'producer.stderr.log') -HandoffCoordinator
    Wait-SyntheticFile $handoffEntered
    $observedDeadline=[datetime]::Parse([IO.File]::ReadAllText($handoffEntered)).ToUniversalTime()
    $exactConsume=$null
    if($handoffArm-ceq'durable-owner'){
      # Cross both the production deadline and the former 15-second fixture
      # window before starting real work. Completion, not elapsed time, resumes it.
      while([DateTime]::UtcNow-le$observedDeadline.AddSeconds(11)){[Threading.Thread]::Sleep(25)}
      $exactConsume=& $consumer -Branch 'synthetic/exact-owner' -Worktree $ownerRepo -RuntimeRoot $ownerRuntime -HistoryPath $ownerHistory -AcceptingOwnerRecordPath $exactOwnerPath -AcceptingOwnerLaunchId $exactLaunch -NoPush|ConvertFrom-Json -DateKind String
      $durableAcks=@(Get-ChildItem -LiteralPath $ownerRuntime -Filter 'integration-owed-ack-*.json' -File)
      Assert-True ($durableAcks.Count-eq1) "F3 durable owner acknowledgement count actual=$($durableAcks.Count) expected=1"
      Assert-True ([DateTime]::UtcNow-gt$observedDeadline-and-not$exactProducer.process.HasExited) 'F3 producer did not remain coordinated after the production deadline'
    }else{
      # Withhold the real consumer until the producer's actual deadline has passed.
      while([DateTime]::UtcNow-le$observedDeadline){[Threading.Thread]::Sleep(25)}
      $withheldAcks=@(Get-ChildItem -LiteralPath $ownerRuntime -Filter 'integration-owed-ack-*.json' -File)
      Assert-True ($withheldAcks.Count-eq0) "F3 withheld acknowledgement count actual=$($withheldAcks.Count) expected=0"
      Assert-True (Remove-DispatchLaunchResources $exactOwnerPath $exactOwner $ownerRuntime ([IO.Path]::GetTempPath())) 'F3 exact synthetic owner release refused'
      Remove-Item -LiteralPath $exactTranscript -Force
    }
    $resumedAt=[DateTime]::UtcNow
    [IO.File]::WriteAllText($handoffContinue,'continue',[Text.UTF8Encoding]::new($false))
    $exactProducer.process.StandardInput.WriteLine('continue')
    $exactProducer.process.StandardInput.Close()
    $exactProducerResult=Complete-SyntheticPwsh $exactProducer
    $exactMatch=[regex]::Match($exactProducerResult.stdout,'(?s)\{\s*"schemaVersion"\s*:\s*"landed-integration-dispatch-result/v1".*\}\s*$')
    if(-not$exactMatch.Success){throw "exact-owner producer emitted no result: $($exactProducerResult.stderr)"}
    $exactProducerJson=$exactMatch.Value|ConvertFrom-Json -DateKind String
    $exactTerminal=$exactProducerJson
    $exactHead=(& git -C $ownerRepo rev-parse HEAD).Trim()
    $exactReplay=& $script -LandedPr 900200 -LandedHead ('2'*40) -HistoryPath $ownerHistory -RuntimeRoot $ownerRuntime -ContainerRoot $ownerContainer -Repository $SyntheticIntegrationRepository -FixturePath $ownerFixturePath -DispatchScript $stub -NoPushIntegration|ConvertFrom-Json -DateKind String
    Assert-True ($exactReplay.targets[0].action-ceq'DUPLICATE_SKIPPED') "F3 replay action actual=$($exactReplay.targets[0].action) expected=DUPLICATE_SKIPPED"
  }finally{
    $env:GIT_TRACE2_EVENT=$previousTrace
    if($exactProducer-and-not$exactProducerResult){
      $exactProducer.process.StandardInput.Close()
      $exactProducerResult=Complete-SyntheticPwsh $exactProducer
    }
  }
  if(Test-Path -LiteralPath $exactOwnerPath){
    $currentExactOwner=Get-Content -LiteralPath $exactOwnerPath -Raw|ConvertFrom-Json -DateKind String
    Assert-True (Remove-DispatchLaunchResources $exactOwnerPath $currentExactOwner $ownerRuntime ([IO.Path]::GetTempPath())) 'F3 durable synthetic owner cleanup refused'
    Remove-Item -LiteralPath $exactTranscript -Force
  }
  $exactObligations=@(Get-ChildItem -LiteralPath $ownerRuntime -Filter 'integration-owed-*.json' -File|Where-Object{$_.Name-notlike'integration-owed-ack-*'-and$_.Name-notlike'integration-owed-accept-*'});$exactAcks=@(Get-ChildItem -LiteralPath $ownerRuntime -Filter 'integration-owed-ack-*.json' -File);$exactRows=@(Get-Content $ownerHistory|ForEach-Object{$_|ConvertFrom-Json -DateKind String}|Where-Object{$_.integrationDispatchSchema-cin@('landed-integration-dispatch/v1','landed-integration-dispatch/v2')})
  Assert-True ($exactRows[0].integrationDispatchSchema -ceq 'landed-integration-dispatch/v2' -and $null -eq $exactRows[0].executionAttribution) 'legacy owner without a native routing/spec join must have explicit unknown attribution'
  $operands=[ordered]@{
    producerExit=[ordered]@{actual=$exactProducerResult.exitCode;expected=0;pass=($exactProducerResult.exitCode-eq0)}
    producerAction=[ordered]@{actual=$exactProducerJson.targets[0].action;expected=@('HANDOFF_RETRYABLE','OWED_ACTIVE_WRITER');pass=($exactProducerJson.targets[0].action-cin@('HANDOFF_RETRYABLE','OWED_ACTIVE_WRITER'))}
    terminalAction=[ordered]@{actual=$exactTerminal.targets[0].action;expected='OWED_ACTIVE_WRITER';pass=($exactTerminal.targets[0].action-ceq'OWED_ACTIVE_WRITER')}
    terminalHandoff=[ordered]@{actual=$exactTerminal.targets[0].handoff;expected=@('EXACT_OWNER','ACKNOWLEDGED_REPLAY');pass=($exactTerminal.targets[0].handoff-cin@('EXACT_OWNER','ACKNOWLEDGED_REPLAY'))}
    consumerStatus=[ordered]@{actual=$(if($exactConsume){$exactConsume.results[0].status}else{$null});expected='REVIEW_REQUIRED';pass=($null-ne$exactConsume-and$exactConsume.results[0].status-ceq'REVIEW_REQUIRED')}
    movedHead=[ordered]@{actual=$exactHead;original=$ownerTarget;expected='different from original';pass=($exactHead-cne$ownerTarget)}
    owedCount=[ordered]@{actual=$exactObligations.Count;expected=0;pass=($exactObligations.Count-eq0)}
    matchingAckCount=[ordered]@{actual=$exactAcks.Count;expected=0;pass=($exactAcks.Count-eq0)}
    terminalCount=[ordered]@{actual=$exactRows.Count;expected=1;pass=($exactRows.Count-eq1)}
    secondWriterCalls=[ordered]@{actual=(Test-Path $ownerCalls);expected=$false;pass=(-not(Test-Path $ownerCalls))}
  }
  function Assert-ExactOwnerOperands($ActualOperands){
    $failures=@(foreach($operand in $ActualOperands.GetEnumerator()){
      Write-Host "EVIDENCE F3 arm=$handoffArm operand=$($operand.Key) $($operand.Value|ConvertTo-Json -Compress -Depth 4)"
      if(-not$operand.Value.pass){"$($operand.Key) actual=$($operand.Value.actual) expected=$($operand.Value.expected -join ',')"}
    })
    Assert-True ($failures.Count-eq0) ("F3 exact-owner conjunct refusal: "+($failures -join '; '))
  }
  $nativeStarts=@(Get-Content -LiteralPath $nativeTrace|ForEach-Object{$_|ConvertFrom-Json -DateKind String}|Where-Object{$_.event-ceq'start'})
  $nativeRebases=@($nativeStarts|Where-Object{$_.argv-contains'rebase'}).Count;$nativePushes=@($nativeStarts|Where-Object{$_.argv-contains'push'}).Count
  $remainingOwners=@(Get-ChildItem -LiteralPath $ownerRuntime -Filter 'dispatch-launch-*.json' -File).Count
  Assert-True ($nativeRebases-eq1-and$nativePushes-eq0-and$remainingOwners-eq0) "F3 native calls/cleanup rebase=$nativeRebases expected=1 push=$nativePushes expected=0 remainingOwners=$remainingOwners expected=0"
  if($handoffArm-ceq'durable-owner'){
    Assert-ExactOwnerOperands $operands
    Assert-True ($exactTerminal.targets[0].handoff-ceq'EXACT_OWNER') "F3 genuine owner was confused with acknowledgement replay: actual=$($exactTerminal.targets[0].handoff)"
    $positiveTerminalCount=$exactRows.Count;$positiveAckCount=$exactAcks.Count;$positiveOwedCount=$exactObligations.Count
    Write-Output "EVIDENCE F3 durable-owner handoff=$($exactTerminal.targets[0].handoff) durableBeforeResume=$($durableAcks.Count) rebase=$nativeRebases push=$nativePushes replay=$($exactReplay.targets[0].action)"
  }else{
    $namedRefusal=$null;try{Assert-ExactOwnerOperands $operands}catch{$namedRefusal=$_.Exception.Message}
    Assert-True ($exactTerminal.targets[0].handoff-ceq'NO_OWNER_CLAIM'-and$resumedAt-gt$observedDeadline-and$namedRefusal-like'*terminalHandoff actual=NO_OWNER_CLAIM*') "F3 withheld acknowledgement did not discriminate terminalHandoff: actual=$($exactTerminal.targets[0].handoff) refusal=$namedRefusal"
    foreach($name in @('producerExit','producerAction','terminalAction','movedHead','owedCount','matchingAckCount','terminalCount','secondWriterCalls')){Assert-True $operands[$name].pass "F3 withheld acknowledgement unrelated conjunct $name failed"}
    Write-Output "CONTROL F3 withheld-ack handoff=$($exactTerminal.targets[0].handoff) deadline=$($observedDeadline.ToString('o')) resumed=$($resumedAt.ToString('o')) withheldAcks=$($withheldAcks.Count) rebase=$nativeRebases push=$nativePushes refusal=$namedRefusal"
  }
  }
  Write-Output "CONTROL F10 handoff exactOwner=1 noOwnerClaim=1 integrations=2 acknowledgedTerminals=$($raceRows.Count+$positiveTerminalCount) retainedAcknowledgements=$($raceAcks.Count+$positiveAckCount) stranded=$($raceObligations.Count+$positiveOwedCount) secondWriters=0 replay=duplicate-suppressed"
  Write-Output 'CONTROL F12 descendantReplay=acknowledged headPreserved=true repeatIntegrations=0 reset=unknown missingObject=unknown ambiguousGit=unknown'

  $producer=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'log-event.ps1') -Raw
  Assert-True ($producer.Contains("if (`$Kind -ceq 'landed')",[StringComparison]::Ordinal)-and$producer.Contains("& `$LandedIntegrationScript @censusArguments",[StringComparison]::Ordinal)) 'landed lifecycle producer is not wired to the census entrypoint'
  $launcherSource=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'dispatch-lane.ps1') -Raw
  Assert-True ($launcherSource.Contains("landed-integration-consume.ps1",[StringComparison]::Ordinal)-and$launcherSource.Contains("AcceptingOwnerRecordPath = `$ownershipRecordPath",[StringComparison]::Ordinal)-and$launcherSource.Contains("AcceptingOwnerLaunchId = `$launchId",[StringComparison]::Ordinal)) 'canonical active-lane release boundary does not accept and consume owed integrations under the exact owner'
  $triggerCalls=Join-Path $runtime 'trigger.txt';$triggerStub=Join-Path $root 'landed-trigger.ps1'
  Set-Content -LiteralPath $triggerStub -Value @'
param($LandedPr,$LandedHead,$HistoryPath,$RuntimeRoot,$FixturePath,[switch]$SynchronousDispatch)
[ordered]@{pr=$LandedPr;head=$LandedHead;history=$HistoryPath;runtime=$RuntimeRoot;fixture=$FixturePath;synchronous=[bool]$SynchronousDispatch}|ConvertTo-Json -Compress|Set-Content -LiteralPath $env:SYNTHETIC_LANDED_TRIGGER
'@
  $env:SYNTHETIC_LANDED_TRIGGER=$triggerCalls;$triggerHistory=Join-Path $runtime 'trigger-history.jsonl'
  & (Join-Path $PSScriptRoot 'log-event.ps1') -Log dispatch -Kind landed -Pr 1 -LandedHead $landedHead -OutFile $triggerHistory -NoBoard -LandedIntegrationFixture $fixturePath -LandedIntegrationScript $triggerStub|Out-Null
  $trigger=Get-Content -LiteralPath $triggerCalls -Raw|ConvertFrom-Json -DateKind String;$landedRow=Get-Content -LiteralPath $triggerHistory -Raw|ConvertFrom-Json -DateKind String
  Assert-True ($trigger.pr-eq1-and$trigger.head-ceq$landedHead-and$trigger.synchronous-eq$true-and$landedRow.kind-ceq'landed'-and$landedRow.head-ceq$landedHead) 'actual landed lifecycle row did not invoke the census with exact identity'

  }
  function New-Connection([object[]]$Nodes,[long]$Total,[bool]$HasNext,[string]$Cursor){
    [ordered]@{totalCount=$Total;pageInfo=[ordered]@{hasNextPage=$HasNext;endCursor=$Cursor};nodes=@($Nodes)}
  }
  function Add-GraphStep($Queue,[string]$Name,[string]$QueryContains,$Variables,$Payload,[string]$Error=$null){
    $Queue.Add([ordered]@{name=$Name;queryContains=$QueryContains;variables=$Variables;payload=$Payload;error=$Error})
  }
  function New-CorePayload($Pr,[string]$State,[string]$Head,[string]$Branch,[string]$Mergeable,[string]$MergeState,[long]$ChangedFiles){
    [ordered]@{data=[ordered]@{repository=[ordered]@{pullRequest=[ordered]@{number=[long]$Pr;state=$State;headRefOid=$Head;headRefName=$Branch;mergeable=$Mergeable;mergeStateStatus=$MergeState;changedFiles=$ChangedFiles;milestone=$null}}}}
  }
  function New-FilePayload($Pr,[string]$Head,[long]$ChangedFiles,$Connection){
    [ordered]@{data=[ordered]@{repository=[ordered]@{pullRequest=[ordered]@{number=[long]$Pr;headRefOid=$Head;changedFiles=$ChangedFiles;files=$Connection}}}}
  }
  function New-GraphQueue([int]$OuterCount=1,[int]$TargetPosition=1,[int]$TargetFileCount=101){
    $queue=[Collections.Generic.List[object]]::new();$owner,$name=$SyntheticIntegrationRepository.Split('/');$landedPr=900001;$targetPr=910000+$TargetPosition
    $landedCore=[ordered]@{data=[ordered]@{repository=[ordered]@{pullRequest=[ordered]@{number=[long]$landedPr;state='MERGED';headRefOid=$landedHead;changedFiles=[long]1}}}}
    Add-GraphStep $queue 'landed-before' 'changedFiles' ([ordered]@{owner=$owner;name=$name;pr=$landedPr}) $landedCore
    $landedConnection=New-Connection @([ordered]@{path='catalog/pin.json'}) 1 $false $null
    Add-GraphStep $queue 'landed-files' 'files(first:100' ([ordered]@{owner=$owner;name=$name;pr=$landedPr;cursor=$null}) (New-FilePayload $landedPr $landedHead 1 $landedConnection)
    Add-GraphStep $queue 'landed-after' 'changedFiles' ([ordered]@{owner=$owner;name=$name;pr=$landedPr}) $landedCore
    $openNodes=[Collections.Generic.List[object]]::new()
    foreach($position in 1..$OuterCount){
      $pr=910000+$position;$isTarget=$position-eq$TargetPosition;$head=if($isTarget){$productionHead}else{('{0:x40}' -f $position)}
      $openNodes.Add([ordered]@{number=[long]$pr;headRefOid=$head;headRefName=$(if($isTarget){'synthetic/cap-boundary'}else{"synthetic/outer-$position"});mergeable='MERGEABLE';mergeStateStatus='CLEAN';changedFiles=[long]$(if($isTarget){$TargetFileCount}else{1});milestone=$null})
    }
    $firstOpen=@($openNodes|Select-Object -First 100);$hasOuterNext=$OuterCount-gt100
    $openPayload=[ordered]@{data=[ordered]@{repository=[ordered]@{pullRequests=(New-Connection $firstOpen $OuterCount $hasOuterNext $(if($hasOuterNext){'synthetic-open-100'}else{$null}))}}}
    Add-GraphStep $queue 'open-page-1' 'pullRequests(first:100' ([ordered]@{owner=$owner;name=$name;cursor=$null}) $openPayload
    if($hasOuterNext){
      $remaining=@($openNodes|Select-Object -Skip 100)
      $openPayload2=[ordered]@{data=[ordered]@{repository=[ordered]@{pullRequests=(New-Connection $remaining $OuterCount $false $null)}}}
      Add-GraphStep $queue 'open-page-2' 'pullRequests(first:100' ([ordered]@{owner=$owner;name=$name;cursor='synthetic-open-100'}) $openPayload2
    }
    $basePayload=[ordered]@{data=[ordered]@{repository=[ordered]@{defaultBranchRef=[ordered]@{target=[ordered]@{oid=$base}}}}}
    Add-GraphStep $queue 'base' 'defaultBranchRef' ([ordered]@{owner=$owner;name=$name}) $basePayload
    foreach($node in $openNodes){
      $core=New-CorePayload $node.number 'OPEN' $node.headRefOid $node.headRefName $node.mergeable $node.mergeStateStatus $node.changedFiles
      Add-GraphStep $queue "target-$($node.number)-before" 'mergeStateStatus changedFiles' ([ordered]@{owner=$owner;name=$name;pr=$node.number}) $core
      if($node.number-eq$targetPr-and$TargetFileCount-eq101){
        $firstFiles=@(1..100|ForEach-Object{[ordered]@{path=('synthetic/nondecisive-{0:d3}.txt' -f $_)}})
        Add-GraphStep $queue 'target-files-page-1' 'files(first:100' ([ordered]@{owner=$owner;name=$name;pr=$node.number;cursor=$null}) (New-FilePayload $node.number $node.headRefOid 101 (New-Connection $firstFiles 101 $true 'synthetic-files-100'))
        Add-GraphStep $queue 'target-files-page-2' 'files(first:100' ([ordered]@{owner=$owner;name=$name;pr=$node.number;cursor='synthetic-files-100'}) (New-FilePayload $node.number $node.headRefOid 101 (New-Connection @([ordered]@{path='catalog/pin.json'}) 101 $false $null))
      }else{
        $path=if($node.number-eq$targetPr){'catalog/pin.json'}else{"synthetic/pr-$($node.number).txt"}
        Add-GraphStep $queue "target-$($node.number)-files" 'files(first:100' ([ordered]@{owner=$owner;name=$name;pr=$node.number;cursor=$null}) (New-FilePayload $node.number $node.headRefOid $node.changedFiles (New-Connection @([ordered]@{path=$path}) $node.changedFiles $false $null))
      }
      Add-GraphStep $queue "target-$($node.number)-after" 'mergeStateStatus changedFiles' ([ordered]@{owner=$owner;name=$name;pr=$node.number}) $core
    }
    return @($queue)
  }
  function Add-OwnershipReads($Queue,$Nodes,$Owners,[string]$Phase){
    $owner,$name=$SyntheticIntegrationRepository.Split('/')
    foreach($node in @($Nodes|Sort-Object number)){
      $links=@(if($Owners.ContainsKey([int]$node.number)){$Owners[[int]$node.number]})
      $pages=[Math]::Max(1,[Math]::Ceiling($links.Count/100))
      for($page=0;$page-lt$pages;$page++){
        $cursor=if($page){"synthetic-owners-$($page*100)"}else{$null}
        $next=if($page-lt$pages-1){"synthetic-owners-$(($page+1)*100)"}else{$null}
        $pull=[ordered]@{number=$node.number;state='OPEN';headRefOid=$node.headRefOid;headRefName=$node.headRefName;milestone=$node.milestone;
          closingIssuesReferences=((New-Connection @($links|Select-Object -Skip ($page*100) -First 100) $links.Count ($null-ne$next) $next)|ConvertTo-Json -Depth 8|ConvertFrom-Json -AsHashtable)}
        Add-GraphStep $Queue "ownership-$($node.number)-$Phase-$page" 'closingIssuesReferences(first:100' @{owner=$owner;name=$name;pr=$node.number;cursor=$cursor} @{data=@{repository=@{pullRequest=$pull}}}
      }
    }
  }
  function Invoke-GraphControl([string]$Name,$Queue,[bool]$ExpectPass,[string]$ExpectedAction='LAUNCHED',[string]$ExpectedFailure='',[int]$ExpectedTargets=1,[switch]$TerminalStop,
      [hashtable]$Owners=@{},[hashtable]$ExpectedActions=@{},[scriptblock]$MutateOwnership,[scriptblock]$BeforeApply,[string]$Subject=$script,[switch]$Repeat,[switch]$RequirePlan){
    $controlRuntime=Join-Path $productionRoot "runtime-$Name";New-Item -ItemType Directory -Path $controlRuntime|Out-Null
    $graphPath=Join-Path $controlRuntime 'graph.json'
    $controlCalls=Join-Path $controlRuntime 'calls.txt';$env:SYNTHETIC_DISPATCH_CALLS=$controlCalls;$failure=$null;$value=$null
    $apiNodes=@($Queue|Where-Object{$_.name-like'target-*-before'}|ForEach-Object{$_.payload.data.repository.pullRequest})
    $reasonNodes=@($apiNodes|Where-Object{
      $n=$_.number
      $_.mergeable-ceq'CONFLICTING'-or$_.mergeStateStatus-ceq'DIRTY'-or@($Queue|Where-Object{$_.payload.data.repository.pullRequest.number-eq$n-and@($_.payload.data.repository.pullRequest.files.nodes|Where-Object path -CEQ 'catalog/pin.json').Count}).Count
    })
    $expanded=[Collections.Generic.List[object]]::new();foreach($step in $Queue){$expanded.Add($step)}
    foreach($node in @($reasonNodes|Sort-Object number)){
      Add-OwnershipReads $expanded @($node) $Owners 'before'
      Add-OwnershipReads $expanded @($node) $Owners 'after'
    }
    $applyNodes=@($reasonNodes|Where-Object{
      $n=$_.number
      $controller=@($Queue|Where-Object{$_.payload.data.repository.pullRequest.number-eq$n-and@($_.payload.data.repository.pullRequest.files.nodes|Where-Object path -Like '.orchestrator/*').Count}).Count-gt0
      -not$controller-and$(if($ExpectedActions.Count){$ExpectedActions[[int]$n]-ceq'LAUNCHED'}else{$ExpectedAction-ceq'LAUNCHED'})
    })
    Add-OwnershipReads $expanded $applyNodes $Owners 'apply'
    if($MutateOwnership){& $MutateOwnership $expanded}
    [IO.File]::WriteAllText($graphPath,(ConvertTo-Json -InputObject @($expanded) -Depth 20),[Text.UTF8Encoding]::new($false))
    $controlHistory=Join-Path $controlRuntime 'history.jsonl'
    # Seed explicit synthetic bindings before the collector, including negative
    # pagination controls. Count subsequent effects separately from these inputs.
    Write-SyntheticIntegrationEligibility $controlHistory $apiNodes
    if($TerminalStop){
      $node=$apiNodes[0]
      & (Join-Path $PSScriptRoot 'log-event.ps1') -Log dispatch -Kind rule-change -IntegrationAuthoritySchema landed-integration-authority/v1 -Pr $node.number -Issue 908132 -TargetBranch $node.headRefName -LineageRoot synthetic/8132 -TargetHead ('f'*40) -AuthorityState STOP -AuthorityIssue 908132 -AuthorityCommentId 9000000001 -OperatorAuthority 'Todd:908132#9000000001' -Note 'Synthetic stop read 2026-09-23T00:00:00Z' -OutFile $controlHistory -NoBoard | Out-Null
      $stopHash=(Read-ExactHeadReviewHistory $controlHistory).rows[-1].rawSha256
      $pointer=Join-Path $controlRuntime "integration-owed-$($node.number)-$($landedHead.Substring(0,12)).json"
      Set-Content $pointer 'synthetic retained pointer'
    }
    $authorityInputCount=@(Get-Content $controlHistory).Count
    $graphAuthority=Write-SyntheticIntegrationAuthority (Join-Path $controlRuntime 'authority.json') $apiNodes $base $SyntheticIntegrationRepository
    $historyBefore=[IO.File]::ReadAllText($controlHistory)
    try{$value=& $Subject -LandedPr 900001 -LandedHead $landedHead -Repository $SyntheticIntegrationRepository -HistoryPath (Join-Path $controlRuntime 'history.jsonl') -RuntimeRoot $controlRuntime -ContainerRoot $productionRoot -GraphFixturePath $graphPath -IntegrationAuthorityFixturePath $graphAuthority -DispatchScript $stub -SynchronousDispatch -BeforeApply $BeforeApply|ConvertFrom-Json -DateKind String}catch{$failure=$_.Exception.Message}
    $callCount=if(Test-Path -LiteralPath $controlCalls){@(Get-Content -LiteralPath $controlCalls).Count}else{0}
    $historyCount=if(Test-Path $controlHistory){@(Get-Content $controlHistory).Count-$authorityInputCount}else{0}
    $expectedCalls=if($ExpectedActions.Count){@($ExpectedActions.Values|Where-Object{$_-ceq'LAUNCHED'}).Count}elseif($ExpectedAction-ceq'LAUNCHED'){1}else{0}
    if($ExpectPass){Assert-True ($null-eq$failure-and$value.targetCount-eq$ExpectedTargets-and@($value.targets|Where-Object{$_.action-ceq$ExpectedAction}).Count-eq1-and$callCount-eq$expectedCalls-and$historyCount-eq$expectedCalls) "$Name did not traverse the wired paginated collector with the exact disposition (failure=$failure targetCount=$($value.targetCount) calls=$callCount history=$historyCount)"}
    else{Assert-True ($null-ne$failure-and$failure-match'CENSUS_UNKNOWN|^INTEGRATION_TARGET_RECONCILIATION_REQUIRED:'-and$callCount-eq0-and$historyCount-eq0) "$Name did not fail UNKNOWN before dispatch (failure=$failure calls=$callCount history=$historyCount)"}
    if($ExpectedFailure){
      $matchesFailure=if($ExpectedFailure-ceq'INTEGRATION_TARGET_RECONCILIATION_REQUIRED:'){$failure.StartsWith($ExpectedFailure,[StringComparison]::Ordinal)}else{$failure-ceq$ExpectedFailure}
      Assert-True $matchesFailure "$Name returned the wrong refusal: $failure"
    }
    foreach($pr in $ExpectedActions.Keys){Assert-True (@($value.targets|Where-Object{$_.pr-eq$pr-and$_.action-ceq$ExpectedActions[$pr]}).Count-eq1) "$Name wrong result for $pr"}
    $plans=@(Get-ChildItem $controlRuntime -Filter 'integration-plan-*.json')
    if($ExpectedFailure-ceq'CENSUS_UNKNOWN_OWNERSHIP_REGISTER'){Assert-True ($plans.Count-eq0) "$Name global unreadability claimed a plan"}
    if($ExpectPass-or$RequirePlan){
      Assert-True ($plans.Count-eq1) "$Name complete plan missing"
      $planned=Get-Content $plans[0].FullName -Raw|ConvertFrom-Json
      Assert-True ($planned.targets.Count-eq$apiNodes.Count) "$Name partial plan"
      foreach($target in $planned.targets){Assert-True (($target.PSObject.Properties.Name|Sort-Object)-join',' -ceq 'action,branch,head,pr,reason,worktree') "$Name plan shape changed"}
      if($ExpectedFailure-like'CENSUS_UNKNOWN_OWNERSHIP_*'-and$RequirePlan){
        Assert-True (@($planned.targets|Where-Object action -CEQ 'OWNERSHIP_UNKNOWN').Count-eq1) "$Name missing scoped unknown"
        if($apiNodes.Count-gt1){Assert-True (@($planned.targets|Where-Object action -CEQ 'LAUNCH').Count-eq1) "$Name eligible sibling was not fully planned"}
      }
    }
    foreach($target in @($value.targets|Where-Object action -CEQ 'PLATFORM_HANDOFF_REQUIRED')){
      Assert-True (($target.PSObject.Properties.Name|Sort-Object)-join',' -ceq 'action,pr') "$Name platform result grew"
      Assert-True (@(Get-ChildItem $controlRuntime -File|Where-Object{$_.Name-like"integration-owed-$($target.pr)-*"-or$_.Name-like"integration-$($value.landedPr)-$($target.pr)-*"}).Count-eq0) "$Name platform effects"
    }
    if($expectedCalls-eq0-or-not$ExpectPass){
      Assert-True ([IO.File]::ReadAllText($controlHistory)-ceq$historyBefore) "$Name changed history bytes"
      if(-not$TerminalStop){Assert-True (@(Get-ChildItem $controlRuntime -File|Where-Object{$_.Name-like'integration-owed-*'-or$_.Name-like'dispatch-start-*'-or$_.Name-like'dispatch-launch-*'-or$_.Name-like'integration-request-*'-or$_.Name-like'*.prompt.txt'}).Count-eq0) "$Name published before boundary"}
    }
    if($Repeat){
      $repeatHistory=[IO.File]::ReadAllText($controlHistory)
      $again=& $Subject -LandedPr 900001 -LandedHead $landedHead -Repository $SyntheticIntegrationRepository -HistoryPath $controlHistory -RuntimeRoot $controlRuntime -ContainerRoot $productionRoot -GraphFixturePath $graphPath -IntegrationAuthorityFixturePath $graphAuthority -DispatchScript $stub -SynchronousDispatch|ConvertFrom-Json
      Assert-True ($again.targets[0].action-ceq'PLATFORM_HANDOFF_REQUIRED'-and[IO.File]::ReadAllText($controlHistory)-ceq$repeatHistory-and-not(Test-Path $controlCalls)) "$Name day-after consumed deferral"
    }
    if($TerminalStop){
      Assert-True ($value.targets[0].authorityRows.Count-eq1-and$value.targets[0].authorityRows[0]-ceq$stopHash-and(Get-Content $pointer)-ceq'synthetic retained pointer') 'production STOP lost exact hash or consumed pointer'
      Write-Output "CONTROL $Name PASS production collector, zero launch/history effects"
    }
    Write-Output "CONTROL $Name PASS calls=$callCount historyEffects=$historyCount refusal=$failure"
  }

  $productionRoot=Join-Path $root 'synthetic-production-container';$productionRepository=Join-Path $productionRoot 'main';$productionWorktree=Join-Path $productionRoot 'synthetic-production-repo';New-Item -ItemType Directory -Path $productionRepository|Out-Null
  New-Item -ItemType Directory (Join-Path $productionRoot '.orchestrator')|Out-Null
  $syntheticRegister=Join-Path $productionRoot '.orchestrator/platform-handoff.md'
  Set-Content $syntheticRegister @'
# Unmistakably synthetic ownership register
## 1. Ownership register
| Scope | Owner | Notes |
| --- | --- | --- |
| chase-sets milestone 9908018 (Synthetic Platform) | platform | synthetic |
| every other chase-sets milestone, issue, PR, worktree, and the merge queue | incumbent | synthetic |
| `synthetic-8133/platform` (all issues) | platform self loop (`m1`) | synthetic repository scope |
| WSL executor `/root/orchestration-m1/repo` | platform | not a repository scope |
## 2. Partition rule
'@
  & git -C $productionRepository init -q --initial-branch=main
  Set-Content -LiteralPath (Join-Path $productionRepository 'seed.txt') -Value 'unmistakably synthetic census fixture'
  & git -C $productionRepository add seed.txt;& git -C $productionRepository -c user.name='Synthetic Test' -c user.email='synthetic@example.invalid' commit -q -m 'synthetic fixture';& git -C $productionRepository worktree add -q -b synthetic/cap-boundary $productionWorktree HEAD
  Publish-SyntheticIntegrationRemote $productionRepository (Join-Path $productionRoot 'remote.git')
  $productionHead=(& git -C $productionWorktree rev-parse HEAD).Trim();$base=(& git -C $productionWorktree rev-parse refs/remotes/origin/main).Trim()
  if(-not$OwnershipOnly){
  Invoke-GraphControl 'outer-and-file-page-101' (New-GraphQueue -OuterCount 101 -TargetPosition 101 -TargetFileCount 101) $true
  Invoke-GraphControl 'terminal-authority-stops-before-effects' (New-GraphQueue -TargetFileCount 1) $true 'TERMINAL_AUTHORITY_STOP' -TerminalStop

  $missingQueue=New-GraphQueue -OuterCount 2 -TargetPosition 1 -TargetFileCount 1
  foreach($step in $missingQueue){
    if($step.name-ceq'open-page-1'){$step.payload.data.repository.pullRequests.nodes[1].mergeStateStatus='DIRTY'}
    if($step.name-like'target-910002-before'-or$step.name-like'target-910002-after'){$step.payload.data.repository.pullRequest.mergeStateStatus='DIRTY'}
    if($step.name-ceq'target-910002-files'){$step.payload.data.repository.pullRequest.files.nodes[0].path='.orchestrator/synthetic-controller.ps1'}
  }
  Invoke-GraphControl 'production-early-product-later-missing-controller' $missingQueue $false -ExpectedFailure 'CENSUS_UNKNOWN_WORKTREE_910002'
  $productionRefusal=Get-ChildItem (Join-Path $productionRoot 'runtime-production-early-product-later-missing-controller') -Filter 'integration-plan-*.json'
  $productionPlan=Get-Content $productionRefusal.FullName -Raw|ConvertFrom-Json -DateKind String
  Assert-True ($productionPlan.targets.Count-eq2-and$productionPlan.targets[0].action-ceq'LAUNCH'-and$productionPlan.targets[1].action-ceq'MISSING_WORKTREE') 'production negative did not retain the complete disposition plan'
  Write-Output 'CONTROL 8018 production collector earlyProduct=910001 laterMissingController=910002 launches=0 mutationRows=0 durableTargets=2'

  $laterWorktree=Join-Path $productionRoot 'synthetic-later-worktree'
  & git -C $productionRepository worktree add -q -b synthetic/outer-2 $laterWorktree HEAD
  & git -C $productionRepository push -q origin synthetic/outer-2
  Assert-True ($LASTEXITCODE-eq0) 'later synthetic branch publication'
  Invoke-GraphControl 'production-repaired-missing-controller' $missingQueue $true -ExpectedTargets 2
  $dirtyQueue=New-GraphQueue -OuterCount 2 -TargetPosition 1 -TargetFileCount 1
  foreach($step in $dirtyQueue){
    if($step.name-ceq'open-page-1'){$step.payload.data.repository.pullRequests.nodes[1].mergeStateStatus='DIRTY';$step.payload.data.repository.pullRequests.nodes[1].headRefOid=$productionHead}
    if($step.name-like'target-910002-*'){$step.payload.data.repository.pullRequest.headRefOid=$productionHead}
    if($step.name-like'target-910002-before'-or$step.name-like'target-910002-after'){$step.payload.data.repository.pullRequest.mergeStateStatus='DIRTY'}
  }
  Set-Content (Join-Path $laterWorktree 'synthetic-untracked.txt') 'unmistakably synthetic dirty launch target'
  Invoke-GraphControl 'production-later-dirty-launch-worktree' $dirtyQueue $false -ExpectedFailure 'INTEGRATION_TARGET_RECONCILIATION_REQUIRED:'

  $extraCore=New-GraphQueue -TargetFileCount 1
  @($extraCore|Where-Object{$_.name-like'target-*-after'})[0].payload.data.repository.pullRequest.unexpected=$true
  Invoke-GraphControl 'target-reobservation-unknown-field' $extraCore $false

  $platformQueue=New-GraphQueue -TargetFileCount 1
  foreach($step in $platformQueue){
    if($step.name-ceq'open-page-1'){$step.payload.data.repository.pullRequests.nodes[0].milestone=[ordered]@{number=[long]9908018}}
    if($step.name-like'target-*-before'-or$step.name-like'target-*-after'){$step.payload.data.repository.pullRequest.milestone=[ordered]@{number=[long]9908018}}
  }
  Invoke-GraphControl 'registered-platform-target' $platformQueue $true 'PLATFORM_HANDOFF_REQUIRED'
  $platformMoved=New-GraphQueue -TargetFileCount 1
  @($platformMoved|Where-Object{$_.name-like'target-*-after'})[0].payload.data.repository.pullRequest.milestone=[ordered]@{number=[long]9908018}
  Invoke-GraphControl 'platform-ownership-moved' $platformMoved $false
  $extraMilestone=New-GraphQueue -TargetFileCount 1
  foreach($step in $extraMilestone){
    if($step.name-ceq'open-page-1'){$step.payload.data.repository.pullRequests.nodes[0].milestone=[ordered]@{number=[long]9908018;unexpected=$true}}
    if($step.name-like'target-*-before'-or$step.name-like'target-*-after'){$step.payload.data.repository.pullRequest.milestone=[ordered]@{number=[long]9908018;unexpected=$true}}
  }
  Invoke-GraphControl 'platform-unknown-field' $extraMilestone $false

  $capQueue=New-GraphQueue -TargetFileCount 101;$capPage=@($capQueue|Where-Object{$_.name-ceq'target-files-page-1'})[0]
  $capPage.payload.data.repository.pullRequest.files.pageInfo.hasNextPage=$false;$capPage.payload.data.repository.pullRequest.files.pageInfo.endCursor=$null
  Invoke-GraphControl 'cap-truncation' $capQueue $false
  $countQueue=New-GraphQueue -TargetFileCount 101;$countPage=@($countQueue|Where-Object{$_.name-ceq'target-files-page-1'})[0]
  $countPage.payload.data.repository.pullRequest.changedFiles=[long]100
  Invoke-GraphControl 'changed-files-mismatch' $countQueue $false
  $cursorQueue=New-GraphQueue -TargetFileCount 101;$cursorPage=@($cursorQueue|Where-Object{$_.name-ceq'target-files-page-1'})[0]
  $cursorPage.payload.data.repository.pullRequest.files.pageInfo.endCursor=$null
  Invoke-GraphControl 'unsafe-cursor' $cursorQueue $false
  $movedQueue=New-GraphQueue -TargetFileCount 101;$moved=@($movedQueue|Where-Object{$_.name-like'target-*-after'})[0]
  $moved.payload.data.repository.pullRequest.headRefOid='d'*40
  Invoke-GraphControl 'head-moved' $movedQueue $false
  $errorQueue=New-GraphQueue -TargetFileCount 101;$errorPage=@($errorQueue|Where-Object{$_.name-ceq'target-files-page-2'})[0]
  $errorPage.error='synthetic transport failure';$errorPage.payload=$null
  Invoke-GraphControl 'transport-error' $errorQueue $false
  $partialQueue=New-GraphQueue -OuterCount 2 -TargetPosition 1 -TargetFileCount 1;$partialOpen=@($partialQueue|Where-Object{$_.name-ceq'open-page-1'})[0]
  $partialOpen.payload.data.repository.pullRequests.nodes=@($partialOpen.payload.data.repository.pullRequests.nodes|Select-Object -First 1)
  Invoke-GraphControl 'outer-partial' $partialQueue $false
  }
  function New-Owner([long]$Number=9900001,[string]$Repository=$SyntheticIntegrationRepository,$Milestone=9908018,[string]$State='CLOSED'){
    [ordered]@{number=$Number;state=$State;repository=[ordered]@{nameWithOwner=$Repository};milestone=$(if($null-ne$Milestone){[ordered]@{number=$Milestone}}else{$null})}
  }
  function Test-OwnershipControl([string]$Name,[string]$Mode,[string]$Subject=$script){
    $q=New-GraphQueue -TargetFileCount 1;$owners=@{};$actions=@{};$mutate=$null;$beforeApply=$null;$failure='';$pass=$true;$expected='PLATFORM_HANDOFF_REQUIRED';$targets=1;$repeat=$false;$requirePlan=$false
    $registerBefore=[IO.File]::ReadAllText($syntheticRegister)
    $owners[910001]=@((New-Owner))
    if($Mode-in@('closed','mixed-first','mixed-last')){
      if($Mode-like'mixed-*'){
        $position=if($Mode-ceq'mixed-first'){2}else{1};$q=New-GraphQueue -OuterCount 2 -TargetPosition $position -TargetFileCount 1
        $platformPr=if($position-eq2){910001}else{910002};$incumbentPr=910000+$position
        $owners=@{};$owners[$platformPr]=@((New-Owner));$actions=@{};$actions[$platformPr]='PLATFORM_HANDOFF_REQUIRED';$actions[$incumbentPr]='LAUNCHED';$targets=2
      }else{$platformPr=910001}
      foreach($step in $q){
        foreach($node in @($step.payload.data.repository.pullRequests.nodes)+@($step.payload.data.repository.pullRequest)){
          if($null-ne$node-and$node.number-eq$platformPr-and$node.Contains('headRefName')){$node.headRefName='synthetic/8133-no-holder';if($node.Contains('mergeable')){$node.mergeable='CONFLICTING';$node.mergeStateStatus='DRAFT'}}
        }
      }
    }elseif($Mode-in@('negative','null-owner','nonplatform','unrelated','incumbent-pr','incumbent-owner')){
      $expected='LAUNCHED';$owners[910001]=switch($Mode){
        'negative' {@()};'null-owner' {@((New-Owner -Milestone $null))};'nonplatform' {@((New-Owner -Milestone 9908000),(New-Owner -Number 9900002 -Milestone 9908001))}
        'unrelated' {@((New-Owner -Repository 'synthetic-8133/unrelated'))};'incumbent-pr' {@()};'incumbent-owner' {@((New-Owner -Milestone 9908000))}
      }
    }elseif($Mode-ceq'pr-positive'){$owners[910001]=@((New-Owner -Milestone 9908000))
    }elseif($Mode-ceq'repo-positive'){$owners[910001]=@((New-Owner -Repository 'synthetic-8133/platform' -Milestone $null))
    }elseif($Mode-in@('two-positive','many-positive','many-negative','page-two','page-two-negative','total-moves','cap','cursor','truncated','duplicate')){
      $count=if($Mode-ceq'two-positive'){2}else{101}
      $links=@(1..$count|ForEach-Object{New-Owner -Number (9900000+$_) -Repository $(if($Mode-in@('two-positive','many-positive','many-negative')){$SyntheticIntegrationRepository}else{'synthetic-8133/unrelated'}) -Milestone 9908000})
      if($Mode-in@('two-positive','many-positive','page-two')){$links[-1]=New-Owner -Number 9999999}
      $owners[910001]=$links
      if($Mode-in@('page-two-negative','many-negative')){$expected='LAUNCHED'}
      if($Mode-in@('total-moves','cap','cursor','truncated','duplicate')){
        $pass=$false;$failure='CENSUS_UNKNOWN_OWNERSHIP_910001';$requirePlan=$true
        $mutate={param($steps)
          $pages=@($steps|Where-Object name -Like 'ownership-910001-after-*');$c=$pages[0].payload.data.repository.pullRequest.closingIssuesReferences
          switch($Mode){
            'total-moves' {$pages[1].payload.data.repository.pullRequest.closingIssuesReferences.totalCount=102L}
            'cap' {$c.nodes+=@((New-Owner -Number 9999998));$steps.Remove($pages[1])|Out-Null}
            'cursor' {$c.pageInfo.endCursor=$null;$steps.Remove($pages[1])|Out-Null}
            'truncated' {$c.pageInfo.hasNextPage=$false;$steps.Remove($pages[1])|Out-Null}
            'duplicate' {$pages[1].payload.data.repository.pullRequest.closingIssuesReferences.nodes=@($c.nodes[0])}
          }
        }
      }
    }elseif($Mode-ceq'day-after'){$repeat=$true
    }elseif($Mode-ceq'bad-register'){
      [IO.File]::WriteAllText($syntheticRegister,$registerBefore.Replace('platform self loop (`m1`)','incumbent'));$pass=$false;$failure='CENSUS_UNKNOWN_OWNERSHIP_REGISTER'
    }elseif($Mode-like'drift-*'){
      $owners[910001]=@();$expected='LAUNCHED';$pass=$false;$failure='CENSUS_UNKNOWN_OWNERSHIP_910001';$requirePlan=$false
      if($Mode-ceq'drift-register'){$beforeApply={[IO.File]::AppendAllText($syntheticRegister,"`nsynthetic changed register bytes`n")}}
      else{$mutate={param($steps)
        $p=@($steps|Where-Object name -EQ 'ownership-910001-apply-0')[0].payload.data.repository.pullRequest
        switch($Mode){'drift-head' {$p.headRefOid='e'*40};'drift-branch' {$p.headRefName='synthetic/drift'};'drift-milestone' {$p.milestone=@{number=9908018L}};'drift-link' {$p.closingIssuesReferences=New-Connection @((New-Owner)) 1 $false $null}}
      }}
    }elseif($Mode-like'invalid-*'){
      $q=New-GraphQueue -OuterCount 2 -TargetPosition 2 -TargetFileCount 1
      foreach($step in $q){foreach($node in @($step.payload.data.repository.pullRequests.nodes)+@($step.payload.data.repository.pullRequest)){if($null-ne$node-and$node.number-eq910001-and$node.Contains('mergeable')){$node.mergeStateStatus='DIRTY'}}}
      $pass=$false;$failure='CENSUS_UNKNOWN_OWNERSHIP_910001';$requirePlan=$true
      $mutate={param($steps)
        $entry=@($steps|Where-Object name -EQ 'ownership-910001-after-0')[0];$p=$entry.payload.data.repository.pullRequest;$o=$p.closingIssuesReferences.nodes[0]
        switch($Mode){
          'invalid-state' {$o.state='UNKNOWN'};'invalid-positive-pr' {$o.state='UNKNOWN'};'invalid-repository' {$o.repository.nameWithOwner='not-a-repository'};'invalid-number' {$o.number=1.5}
          'invalid-milestone' {$o.milestone.number='9908018'};'invalid-nested-field' {$o.repository.extra=$true};'invalid-missing' {$p.Remove('closingIssuesReferences')}
          'invalid-transport' {$entry.error='synthetic unavailable';$entry.payload=$null};'invalid-link-moves' {$o.state='OPEN'}
        }
      }
    }
    if($Mode-in@('pr-positive','incumbent-pr','owner-positive','invalid-positive-pr')){
      foreach($step in $q){foreach($node in @($step.payload.data.repository.pullRequests.nodes)+@($step.payload.data.repository.pullRequest)){if($null-ne$node-and$node.number-eq910001-and$node.Contains('milestone')){$node.milestone=@{number=$(if($Mode-in@('pr-positive','invalid-positive-pr')){9908018L}else{9908000L})}}}}
    }
    try{Invoke-GraphControl $Name $q $pass $expected -ExpectedFailure $failure -ExpectedTargets $targets -Owners $owners -ExpectedActions $actions -MutateOwnership $mutate -BeforeApply $beforeApply -Subject $Subject -Repeat:$repeat -RequirePlan:$requirePlan}
    finally{[IO.File]::WriteAllText($syntheticRegister,$registerBefore)}
  }
  $ownershipCases=[ordered]@{
    'null-pr-milestone-closed-platform-owner'='closed';'platform-and-incumbent-mixed-census-platform-first'='mixed-first';'platform-and-incumbent-mixed-census-platform-last'='mixed-last'
    'ownership-complete-negative-retains-incumbent'='negative';'ownership-null-owner-milestone'='null-owner';'ownership-multiple-nonplatform-owners'='nonplatform';'ownership-unrelated-cross-repo-milestone'='unrelated'
    'platform-pr-milestone-disagreeing-owner-defers'='pr-positive';'platform-owner-disagreeing-pr-defers'='owner-positive';'ownership-decisive-owner-beyond-100'='page-two';'ownership-page-two-negative-twin'='page-two-negative'
    'ownership-cross-repo-platform-repository-defers'='repo-positive';'ownership-invalid-repository-owner-cell'='bad-register';'ownership-multiple-owner-platform-defers'='two-positive';'ownership-101-same-repo-platform-defers'='many-positive'
    'ownership-101-same-repo-negative-twin'='many-negative'
    'ownership-total-moves-between-pages'='total-moves';'ownership-cap'='cap';'ownership-cursor'='cursor';'ownership-truncated'='truncated';'ownership-duplicate'='duplicate'
    'ownership-fallback-and-day-after'='day-after';'ownership-incumbent-pr-empty-links'='incumbent-pr';'ownership-incumbent-owner'='incumbent-owner'
  }
  foreach($mode in @('invalid-state','invalid-positive-pr','invalid-repository','invalid-number','invalid-milestone','invalid-nested-field','invalid-missing','invalid-transport','invalid-link-moves','drift-head','drift-branch','drift-milestone','drift-link','drift-register')){$ownershipCases["ownership-unknown-refuses-before-apply-$mode"]=$mode}
  $ownershipFailures=[Collections.Generic.List[string]]::new()
  foreach($case in $ownershipCases.GetEnumerator()){
    if($case.Key-notlike$OwnershipControl){continue}
    try{Test-OwnershipControl $case.Key $case.Value}catch{$ownershipFailures.Add("$($case.Key): $($_.Exception.Message)");Write-Output "CONTROL $($case.Key) FAIL $($_.Exception.Message)"}
  }
  if($ownershipFailures.Count){throw ($ownershipFailures -join "`n")}
  if(-not$SkipOwnershipMutants-and$OwnershipControl-ceq'*'){
    $source=[IO.File]::ReadAllText($script)
    $mutations=@(
      @{name='owner-read-bypass';mode='closed';old='$snapshot=Get-PrOwnership $pr';new='$snapshot=[pscustomobject]@{milestone=$pr.milestone;owners=@()}'},
      @{name='closed-owner-filter';mode='closed';old='foreach($link in $Snapshot.owners){';new="foreach(`$link in @(`$Snapshot.owners|Where-Object state -CEQ 'OPEN')){"},
      @{name='exactly-one-owner';mode='many-positive';old='foreach($link in $Snapshot.owners){';new='foreach($link in @($Snapshot.owners|Select-Object -First 1)){'},
      @{name='first-page-only';mode='page-two';old='foreach($link in $Snapshot.owners){';new='foreach($link in @($Snapshot.owners|Select-Object -First 100)){'},
      @{name='repository-scope-discard';mode='repo-positive';old='if($link.repository.nameWithOwner-in$Register.repositories)';new='if($false)'},
      @{name='cross-repo-milestone-match';mode='unrelated';old='$link.repository.nameWithOwner-ieq$Repository-and';new=''},
      @{name='complete-negative-unknown';mode='negative';old='return $false';new="throw 'complete negative refused'"},
      @{name='total-stability-bypass';mode='total-moves';old="elseif(`$expected-ne[int64]`$connection.totalCount){throw 'CENSUS_UNKNOWN_TOTAL_MOVED'}";new=''},
      @{name='owner-stability-bypass';mode='invalid-link-moves';old='if((Get-RebaseRecordIdentity $snapshot)-cne(Get-RebaseRecordIdentity $reobserved))';new='if($false)'},
      @{name='apply-ownership-bypass';mode='drift-link';old='if(-not$FixturePath){Assert-CurrentOwnership $pr}';new=''},
      @{name='apply-register-bypass';mode='drift-register';old='.identity-cne$platformRegister.identity';new='.identity-cne$currentRegister.identity'}
    )
    foreach($mutation in $mutations){
      $mutantRoot=Join-Path $root "ownership-mutant-$($mutation.name)";New-Item -ItemType Directory $mutantRoot|Out-Null
      Get-ChildItem $PSScriptRoot -File|Where-Object Extension -in @('.ps1','.psm1')|Copy-Item -Destination $mutantRoot
      $mutant=Join-Path $mutantRoot 'landed-integration-dispatch.ps1'
      Assert-True ($source.Contains($mutation.old)) "$($mutation.name) mutation anchor missing"
      $mutated=$source.Replace($mutation.old,$mutation.new)
      if($mutation.name-ceq'owner-read-bypass'){$mutated=$mutated.Replace('$reobserved=Get-PrOwnership $pr','$reobserved=$snapshot')}
      if($mutation.name-ceq'first-page-only'){
        # Preserve native order in this mutant so the decisive page-2 owner is
        # precisely what the broken prefix classifier drops, not a sorted prefix.
        $mutated=$mutated.Replace('@($links.nodes|Sort-Object {$_.repository.nameWithOwner},number)','@($links.nodes)')
      }
      [IO.File]::WriteAllText($mutant,$mutated)
      $caught=$false
      try{Test-OwnershipControl "mutant-$($mutation.name)" $mutation.mode $mutant}catch{
        $caught=$_.Exception.Message-like'ASSERTION FAILED:*'
        Write-Output "MUTANT $($mutation.name) observed: $($_.Exception.Message)"
      }
      Assert-True $caught "$($mutation.name) bypass survived its discriminating control"
      Write-Output "MUTANT $($mutation.name) REJECTED"
    }
  }
  Assert-SyntheticIntegrationWitnesses $root
  Write-Output 'PASS landed exact-once census plus wired outer/file pagination, page-101 decisive intersection, changedFiles/totalCount identity, exact-head re-observation, and partial/error/unsafe/cap UNKNOWN controls'
}finally{
  Remove-Item Env:SYNTHETIC_DISPATCH_CALLS -ErrorAction SilentlyContinue
  if($null-eq$previousPoolUrl){Remove-Item Env:CODEX_POOL_STATUS_URL -ErrorAction SilentlyContinue}else{$env:CODEX_POOL_STATUS_URL=$previousPoolUrl}
  Remove-Item Env:SYNTHETIC_INTEGRATION_FAIL -ErrorAction SilentlyContinue
  Remove-Item Env:SYNTHETIC_LANDED_TRIGGER -ErrorAction SilentlyContinue
  $resolved=[IO.Path]::GetFullPath($root);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
  if((Split-Path -Parent $resolved).TrimEnd('\','/')-ne$temp-or(Split-Path -Leaf $resolved)-notlike'landed-integration-test-*'){throw "unsafe cleanup $resolved"}
  Write-Output "Retained integration fixtures: $resolved"
}
} finally { Exit-RoutingDataTestScope $routingTestScope }
