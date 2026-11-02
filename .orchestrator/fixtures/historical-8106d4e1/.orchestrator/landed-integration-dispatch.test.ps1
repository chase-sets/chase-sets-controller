$ErrorActionPreference='Stop'
$root=Join-Path ([IO.Path]::GetTempPath()) ('landed-integration-test-'+[guid]::NewGuid().ToString('N'))
$runtime=Join-Path $root 'runtime';$history=Join-Path $runtime 'history.jsonl';$calls=Join-Path $runtime 'calls.txt'
$script=Join-Path $PSScriptRoot 'landed-integration-dispatch.ps1'
. (Join-Path $PSScriptRoot 'dispatch-ownership.ps1')
function Assert-True($Condition,[string]$Message){if(-not$Condition){throw "ASSERTION FAILED: $Message"}}
try{
  New-Item -ItemType Directory -Path $runtime | Out-Null
  $worktrees=@{};foreach($n in 2..5){$path=Join-Path $root "target-$n";New-Item -ItemType Directory -Path $path|Out-Null;$worktrees[$n]=$path}
  $stub=Join-Path $root 'dispatch-lane.ps1'
  Set-Content -LiteralPath $stub -Value @'
param($Harness,$Model,$Effort,$Row,$Placement,$LaneRole,$PromptFile,$Worktree,$Label,$StartRequestIdentity,$StartAcknowledgementPath)
Add-Content -LiteralPath $env:SYNTHETIC_DISPATCH_CALLS -Value "$Label|$Worktree|$Model|$Effort"
$leaf=Split-Path -Leaf $Worktree
if($env:SYNTHETIC_INTEGRATION_FAIL-and$Label-like"$($env:SYNTHETIC_INTEGRATION_FAIL)*"){exit 19}
$branch=switch($leaf){'target-2'{'synthetic/intersect'}'target-3'{'synthetic/conflict'}'target-4'{'synthetic/dirty-active'}'synthetic-production-repo'{'synthetic/cap-boundary'}default{(& git -C $Worktree branch --show-current).Trim()}}
$head=switch($leaf){'target-2'{'2'*40}'target-3'{'3'*40}'target-4'{'4'*40}'synthetic-production-repo'{'c'*40}default{(& git -C $Worktree rev-parse HEAD).Trim()}}
$launchId=[guid]::NewGuid().ToString();$owner=Join-Path (Split-Path -Parent $StartAcknowledgementPath) "dispatch-launch-$launchId.json"
$ack=[ordered]@{schemaVersion='dispatch-start-ack/v1';requestIdentity=$StartRequestIdentity;label=$Label;launchId=$launchId;ownershipRecordPath=$owner;worktree=[IO.Path]::GetFullPath($Worktree).TrimEnd('\','/');branch=$branch;head=$head;harness=$Harness;model=$Model;effort=$Effort;row=[long]$Row;placement=$Placement;state='started';childPid=[long]$PID;childStartIdentity=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')}
[IO.File]::WriteAllText($StartAcknowledgementPath,($ack|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
exit 0
'@
  $landedHead='a'*40;$base='b'*40
  $nodes=@(
    [ordered]@{number=[long]2;headRefOid=('2'*40);headRefName='synthetic/intersect';mergeable='MERGEABLE';mergeStateStatus='CLEAN';worktree=$worktrees[2];files=[ordered]@{complete=$true;totalCount=[long]1;nodes=@([ordered]@{path='shared.txt'})}},
    [ordered]@{number=[long]3;headRefOid=('3'*40);headRefName='synthetic/conflict';mergeable='CONFLICTING';mergeStateStatus='BLOCKED';worktree=$worktrees[3];files=[ordered]@{complete=$true;totalCount=[long]1;nodes=@([ordered]@{path='other.txt'})}},
    [ordered]@{number=[long]4;headRefOid=('4'*40);headRefName='synthetic/dirty-active';mergeable='MERGEABLE';mergeStateStatus='DIRTY';worktree=$worktrees[4];files=[ordered]@{complete=$true;totalCount=[long]1;nodes=@([ordered]@{path='active.txt'})}},
    [ordered]@{number=[long]5;headRefOid=('5'*40);headRefName='synthetic/clean';mergeable='MERGEABLE';mergeStateStatus='CLEAN';worktree=$worktrees[5];files=[ordered]@{complete=$true;totalCount=[long]1;nodes=@([ordered]@{path='none.txt'})}}
  )
  $fixture=[ordered]@{schemaVersion='landed-integration-census/v1';complete=$true;newBase=$base;activeBranches=@();landed=[ordered]@{pr=[long]1;head=$landedHead;files=[ordered]@{complete=$true;totalCount=[long]1;nodes=@([ordered]@{path='shared.txt'})}};openPullRequests=[ordered]@{complete=$true;totalCount=[long]4;nodes=$nodes}}
  $fixturePath=Join-Path $root 'census.json';[IO.File]::WriteAllText($fixturePath,($fixture|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
  $env:SYNTHETIC_DISPATCH_CALLS=$calls
  $first=& $script -LandedPr 1 -LandedHead $landedHead -HistoryPath $history -RuntimeRoot $runtime -ContainerRoot $root -FixturePath $fixturePath -DispatchScript $stub -SynchronousDispatch|ConvertFrom-Json -DateKind String
  $rows=@(Get-Content -LiteralPath $history|ForEach-Object{$_|ConvertFrom-Json -DateKind String})
  $dispatches=@($rows|Where-Object{$_.integrationDispatchSchema-ceq'landed-integration-dispatch/v1'})
  $launched=@(Get-Content -LiteralPath $calls)
  Assert-True ($first.targetCount-eq3-and$dispatches.Count-eq3-and$launched.Count-eq3) 'census did not dispatch exactly intersecting/conflicting/DIRTY targets'
  Assert-True (@($dispatches|Where-Object{$_.pr-eq5}).Count-eq0) 'nonintersecting clean PR was admitted'
  $second=& $script -LandedPr 1 -LandedHead $landedHead -HistoryPath $history -RuntimeRoot $runtime -ContainerRoot $root -FixturePath $fixturePath -DispatchScript $stub -SynchronousDispatch|ConvertFrom-Json -DateKind String
  Assert-True (@(Get-Content -LiteralPath $calls).Count-eq3-and@($second.targets|Where-Object{$_.action-ceq'DUPLICATE_SKIPPED'}).Count-eq3) 'repeated landed observation duplicated integration dispatch'
  $bad=$fixture.PSObject.Copy();$bad.openPullRequests=[ordered]@{complete=$true;totalCount=[long]5;nodes=$nodes}
  $badPath=Join-Path $root 'incomplete.json';[IO.File]::WriteAllText($badPath,($bad|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
  $unknownFailed=$false;try{& $script -LandedPr 1 -LandedHead $landedHead -HistoryPath $history -RuntimeRoot $runtime -ContainerRoot $root -FixturePath $badPath -DispatchScript $stub -SynchronousDispatch|Out-Null}catch{$unknownFailed=$true}
  Assert-True ($unknownFailed-and@(Get-Content -LiteralPath $calls).Count-eq3) 'incomplete independent count became empty/success or dispatched'

  $nativeRuntime=Join-Path $root 'native-unknown-runtime';New-Item -ItemType Directory $nativeRuntime|Out-Null;$nativeCalls=Join-Path $nativeRuntime 'calls.txt';$env:SYNTHETIC_DISPATCH_CALLS=$nativeCalls
  $nativeNode=[ordered]@{number=[long]6;headRefOid=('6'*40);headRefName='synthetic/native-unknown';mergeable='UNKNOWN';mergeStateStatus='UNKNOWN';worktree=$worktrees[5];files=[ordered]@{complete=$true;totalCount=[long]1;nodes=@([ordered]@{path='other.txt'})}}
  $nativeFixture=[ordered]@{schemaVersion='landed-integration-census/v1';complete=$true;newBase=$base;activeBranches=@();landed=$fixture.landed;openPullRequests=[ordered]@{complete=$true;totalCount=[long]1;nodes=@($nativeNode)}}
  $nativePath=Join-Path $nativeRuntime 'census.json';[IO.File]::WriteAllText($nativePath,($nativeFixture|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false));$nativeFailed=$false
  try{& $script -LandedPr 1 -LandedHead $landedHead -HistoryPath (Join-Path $nativeRuntime 'history.jsonl') -RuntimeRoot $nativeRuntime -ContainerRoot $root -FixturePath $nativePath -DispatchScript $stub -SynchronousDispatch|Out-Null}catch{$nativeFailed=$_.Exception.Message-match'CENSUS_UNKNOWN_NATIVE_MERGEABILITY'}
  Assert-True ($nativeFailed-and-not(Test-Path $nativeCalls)-and-not(Test-Path (Join-Path $nativeRuntime 'history.jsonl'))) 'unresolved native mergeability became clean non-intersection or emitted lifecycle rows'

  $worktreeContainer=Join-Path $root 'synthetic-f17-container';$productRepository=Join-Path $worktreeContainer 'main';New-Item -ItemType Directory -Path $worktreeContainer,$productRepository|Out-Null
  & git -C $worktreeContainer init -q --initial-branch=main;& git -C $worktreeContainer config user.name 'Synthetic F17 Meta Repository';& git -C $worktreeContainer config user.email 'synthetic-f17-meta@example.invalid';Set-Content (Join-Path $worktreeContainer 'meta-seed.txt') 'unmistakably synthetic meta repository';& git -C $worktreeContainer add meta-seed.txt;& git -C $worktreeContainer commit -q -m 'synthetic meta seed'
  & git -C $productRepository init -q --initial-branch=main;& git -C $productRepository config user.name 'Synthetic F17 Product Repository';& git -C $productRepository config user.email 'synthetic-f17-product@example.invalid';Set-Content (Join-Path $productRepository 'product-seed.txt') 'unmistakably synthetic product repository';& git -C $productRepository add product-seed.txt;& git -C $productRepository commit -q -m 'synthetic product seed'
  $productOnlyWorktree=Join-Path $worktreeContainer 'synthetic-f17-product-only-lane';$productShadowedWorktree=Join-Path $worktreeContainer 'synthetic-f17-canonical-shadowed-lane';$metaOnlyWorktree=Join-Path $worktreeContainer 'synthetic-f17-wrong-meta-only-lane';$metaShadowWorktree=Join-Path $worktreeContainer 'synthetic-f17-same-name-shadow-lane'
  & git -C $productRepository worktree add -q -b synthetic/f17-product-only $productOnlyWorktree HEAD;& git -C $productRepository worktree add -q -b synthetic/f17-shadowed $productShadowedWorktree HEAD
  & git -C $worktreeContainer worktree add -q -b synthetic/f17-meta-only $metaOnlyWorktree HEAD;& git -C $worktreeContainer worktree add -q -b synthetic/f17-shadowed $metaShadowWorktree HEAD
  function Invoke-F17WorktreeControl([string]$Name,[long]$Pr,[string]$Branch,[string]$Head,[string]$ExpectedWorktree,[string]$ExpectedFailure){
    $controlRuntime=Join-Path $worktreeContainer "runtime-$Name";New-Item -ItemType Directory -Path $controlRuntime|Out-Null;$controlHistory=Join-Path $controlRuntime 'history.jsonl';$controlCalls=Join-Path $controlRuntime 'calls.txt';$env:SYNTHETIC_DISPATCH_CALLS=$controlCalls
    $controlFixture=[ordered]@{schemaVersion='landed-integration-census/v1';complete=$true;newBase=$base;activeBranches=@();landed=[ordered]@{pr=[long]9907856;head=$landedHead;files=[ordered]@{complete=$true;totalCount=[long]1;nodes=@([ordered]@{path='synthetic-f17-shared.txt'})}};openPullRequests=[ordered]@{complete=$true;totalCount=[long]1;nodes=@([ordered]@{number=$Pr;headRefOid=$Head;headRefName=$Branch;mergeable='MERGEABLE';mergeStateStatus='CLEAN';files=[ordered]@{complete=$true;totalCount=[long]1;nodes=@([ordered]@{path='synthetic-f17-shared.txt'})}})}}
    $controlFixturePath=Join-Path $controlRuntime 'census.json';[IO.File]::WriteAllText($controlFixturePath,($controlFixture|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false));$failure=$null;$value=$null
    try{$value=& $script -LandedPr 9907856 -LandedHead $landedHead -HistoryPath $controlHistory -RuntimeRoot $controlRuntime -ContainerRoot $worktreeContainer -FixturePath $controlFixturePath -DispatchScript $stub -SynchronousDispatch|ConvertFrom-Json -DateKind String}catch{$failure=$_.Exception.Message}
    [string[]]$callLines=if(Test-Path -LiteralPath $controlCalls){@(Get-Content -LiteralPath $controlCalls)}else{@()};[string[]]$historyLines=if(Test-Path -LiteralPath $controlHistory){@(Get-Content -LiteralPath $controlHistory)}else{@()}
    if($ExpectedFailure){
      $launchArtifacts=@(Get-ChildItem -LiteralPath $controlRuntime -File|Where-Object{$_.Name-ne'census.json'})
      Assert-True ($failure-ceq$ExpectedFailure-and$callLines.Count-eq0-and$historyLines.Count-eq0-and$launchArtifacts.Count-eq0) "$Name did not fail closed before append/launch (failure=$failure calls=$($callLines.Count) history=$($historyLines.Count) artifacts=$($launchArtifacts.Count))"
    }else{
      $calledWorktree=if($callLines.Count-eq1){([string]$callLines[0]).Split('|')[1]}else{''};$actual=if($calledWorktree){[IO.Path]::GetFullPath($calledWorktree).TrimEnd('\','/')}else{''};$expected=[IO.Path]::GetFullPath($ExpectedWorktree).TrimEnd('\','/')
      Assert-True ($null-eq$failure-and$value.targetCount-eq1-and$value.targets[0].action-ceq'LAUNCHED'-and$callLines.Count-eq1-and$historyLines.Count-eq1-and[string]::Equals($actual,$expected,[StringComparison]::OrdinalIgnoreCase)) "$Name did not dispatch the exact registered product sibling (failure=$failure targetCount=$($value.targetCount) calls=$($callLines.Count) history=$($historyLines.Count) actual=$actual expected=$expected)"
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
  $failedOne=& $script -LandedPr 1 -LandedHead $landedHead -HistoryPath $failedHistory -RuntimeRoot $failedRuntime -ContainerRoot $root -FixturePath $failedPath -DispatchScript $stub -SynchronousDispatch|ConvertFrom-Json -DateKind String
  $failedTwo=& $script -LandedPr 1 -LandedHead $landedHead -HistoryPath $failedHistory -RuntimeRoot $failedRuntime -ContainerRoot $root -FixturePath $failedPath -DispatchScript $stub -SynchronousDispatch|ConvertFrom-Json -DateKind String
  Assert-True ($failedOne.targets[0].action-ceq'LAUNCH_FAILED'-and$failedTwo.targets[0].action-ceq'LAUNCH_FAILED'-and@(Get-Content $failedCalls).Count-eq2-and-not(Test-Path $failedHistory)) 'failed integration launcher was logged as success or made retry unrecoverable'
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
  function Start-SyntheticPwsh([string[]]$Arguments,[string]$Stdout,[string]$Stderr){
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=(Get-Command pwsh -CommandType Application|Select-Object -First 1 -ExpandProperty Source);$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    foreach($argument in $Arguments){[void]$start.ArgumentList.Add($argument)}
    $process=[Diagnostics.Process]::Start($start);$outTask=$process.StandardOutput.ReadToEndAsync();$errTask=$process.StandardError.ReadToEndAsync();[pscustomobject]@{process=$process;stdoutTask=$outTask;stderrTask=$errTask;stdout=$Stdout;stderr=$Stderr}
  }
  function Complete-SyntheticPwsh($Handle,[int]$Seconds=45){if(-not$Handle.process.WaitForExit($Seconds*1000)){throw "synthetic process did not finish: $($Handle.process.Id)"};$out=$Handle.stdoutTask.GetAwaiter().GetResult();$err=$Handle.stderrTask.GetAwaiter().GetResult();[IO.File]::WriteAllText($Handle.stdout,$out,[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($Handle.stderr,$err,[Text.UTF8Encoding]::new($false));$code=$Handle.process.ExitCode;$Handle.process.Dispose();[pscustomobject]@{exitCode=$code;stdout=$out;stderr=$err}}
  $raceContainer=Join-Path $root 'synthetic-release-race-container';$raceRepo=Join-Path $raceContainer 'race-lane';$raceRuntime=Join-Path $raceContainer 'runtime';$raceTemp=Join-Path $raceContainer 'private-temp';New-Item -ItemType Directory -Path $raceRepo,$raceRuntime,$raceTemp|Out-Null
  & git -C $raceRepo init -q --initial-branch=main;& git -C $raceRepo config user.name 'Synthetic Release Race';& git -C $raceRepo config user.email 'synthetic-release-race@example.invalid';Set-Content (Join-Path $raceRepo 'base.txt') 'base';& git -C $raceRepo add base.txt;& git -C $raceRepo commit -q -m base;& git -C $raceRepo checkout -q -b synthetic/release-race;Set-Content (Join-Path $raceRepo 'feature.txt') 'feature';& git -C $raceRepo add feature.txt;& git -C $raceRepo commit -q -m feature;$raceTarget=(& git -C $raceRepo rev-parse HEAD).Trim();& git -C $raceRepo checkout -q main;Set-Content (Join-Path $raceRepo 'main.txt') 'new base';& git -C $raceRepo add main.txt;& git -C $raceRepo commit -q -m advance;$raceBase=(& git -C $raceRepo rev-parse HEAD).Trim();& git -C $raceRepo checkout -q synthetic/release-race
  $racePrompt=Join-Path $raceContainer 'owner.prompt.txt';Set-Content $racePrompt 'unmistakably synthetic owner';$childRelease=Join-Path $raceContainer 'release-child';$childScript=Join-Path $raceContainer 'owner-child.ps1';Set-Content $childScript 'param($Release);Write-Output ''{"type":"item.completed"}'';while(-not(Test-Path -LiteralPath $Release)){[Threading.Thread]::Sleep(25)}'
  $ownerScanned=Join-Path $raceContainer 'owner-scanned';$ownerContinue=Join-Path $raceContainer 'owner-continue';$producerSnapshotted=Join-Path $raceContainer 'producer-snapshotted';$publicationContinue=Join-Path $raceContainer 'publication-continue';$raceHistory=Join-Path $raceRuntime 'dispatch-log.jsonl';$raceCalls=Join-Path $raceRuntime 'second-writer-calls.txt';$env:SYNTHETIC_DISPATCH_CALLS=$raceCalls
  $ownerWrapper=Join-Path $raceContainer 'owner-launcher.ps1';$ownerValues=@{dispatch=(Join-Path $PSScriptRoot 'dispatch-lane.ps1');prompt=$racePrompt;repo=$raceRepo;runtime=$raceRuntime;temp=$raceTemp;observed=$ownerScanned;continue=$ownerContinue;exe=(Get-Command pwsh -CommandType Application|Select-Object -First 1 -ExpandProperty Source);child=$childScript;release=$childRelease};$ownerWrapperText=@'
& '{0}' -Harness codex -Model gpt-5.6-terra -Effort medium -LaneRole implementation -PromptFile '{1}' -Worktree '{2}' -Label synthetic-release-owner -Row 2 -Placement measured -ExecutablePath '{3}' -TestRuntimeRoot '{4}' -TestTempRoot '{5}' -OwedReleaseScanObservedPath '{6}' -OwedReleaseScanContinuePath '{7}' -TestArgumentList @('-NoProfile','-NonInteractive','-File','{8}','{9}')
exit $LASTEXITCODE
'@ -f @($ownerValues.dispatch,$ownerValues.prompt,$ownerValues.repo,$ownerValues.exe,$ownerValues.runtime,$ownerValues.temp,$ownerValues.observed,$ownerValues.continue,$ownerValues.child,$ownerValues.release|ForEach-Object{$_.Replace("'","''")});[IO.File]::WriteAllText($ownerWrapper,$ownerWrapperText,[Text.UTF8Encoding]::new($false))
  $ownerArgs=@('-NoProfile','-NonInteractive','-File',$ownerWrapper)
  $ownerHandle=Start-SyntheticPwsh $ownerArgs (Join-Path $raceContainer 'owner.stdout.log') (Join-Path $raceContainer 'owner.stderr.log')
  $ownerRecordDeadline=[DateTime]::UtcNow.AddSeconds(20);do{$ownerRecords=@(Get-ChildItem -LiteralPath $raceRuntime -Filter 'dispatch-launch-*.json' -File -ErrorAction SilentlyContinue);if($ownerRecords.Count-eq1){break};if([DateTime]::UtcNow-ge$ownerRecordDeadline){throw 'synthetic exact owner was not published'};[Threading.Thread]::Sleep(25)}while($true)
  $raceFixture=[ordered]@{schemaVersion='landed-integration-census/v1';complete=$true;newBase=$raceBase;landed=[ordered]@{pr=[long]900100;head=('1'*40);files=[ordered]@{complete=$true;totalCount=[long]1;nodes=@([ordered]@{path='feature.txt'})}};openPullRequests=[ordered]@{complete=$true;totalCount=[long]1;nodes=@([ordered]@{number=[long]900101;headRefOid=$raceTarget;headRefName='synthetic/release-race';mergeable='MERGEABLE';mergeStateStatus='CLEAN';worktree=$raceRepo;files=[ordered]@{complete=$true;totalCount=[long]1;nodes=@([ordered]@{path='feature.txt'})}})}}
  $raceFixturePath=Join-Path $raceContainer 'census.json';[IO.File]::WriteAllText($raceFixturePath,($raceFixture|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
  $producerArgs=@('-NoProfile','-NonInteractive','-File',$script,'-LandedPr','900100','-LandedHead',('1'*40),'-HistoryPath',$raceHistory,'-RuntimeRoot',$raceRuntime,'-ContainerRoot',$raceContainer,'-FixturePath',$raceFixturePath,'-DispatchScript',$stub,'-ActiveSnapshotObservedPath',$producerSnapshotted,'-PublicationContinuePath',$publicationContinue,'-NoPushIntegration')
  $producerHandle=Start-SyntheticPwsh $producerArgs (Join-Path $raceContainer 'producer.stdout.log') (Join-Path $raceContainer 'producer.stderr.log')
  Wait-SyntheticFile $producerSnapshotted;[IO.File]::WriteAllText($childRelease,'release',[Text.UTF8Encoding]::new($false));Wait-SyntheticFile $ownerScanned;[IO.File]::WriteAllText($ownerContinue,'continue',[Text.UTF8Encoding]::new($false));$ownerResult=Complete-SyntheticPwsh $ownerHandle
  Assert-True ($ownerResult.exitCode-eq0-and@(Get-ChildItem -LiteralPath $raceRuntime -Filter 'dispatch-launch-*.json' -File).Count-eq0) "synthetic exact owner did not release before publication: $($ownerResult.stderr)"
  [IO.File]::WriteAllText($publicationContinue,'publish',[Text.UTF8Encoding]::new($false));$producerResult=Complete-SyntheticPwsh $producerHandle;$producerMatch=[regex]::Match($producerResult.stdout,'(?s)\{\s*"schemaVersion"\s*:\s*"landed-integration-dispatch-result/v1".*\}\s*$');if(-not$producerMatch.Success){throw "synthetic producer emitted no result (exit=$($producerResult.exitCode) stdout=$($producerResult.stdout) stderr=$($producerResult.stderr))"};$producerJson=$producerMatch.Value|ConvertFrom-Json -DateKind String;$raceHead=(& git -C $raceRepo rev-parse HEAD).Trim()
  $raceReplay=& $script -LandedPr 900100 -LandedHead ('1'*40) -HistoryPath $raceHistory -RuntimeRoot $raceRuntime -ContainerRoot $raceContainer -FixturePath $raceFixturePath -DispatchScript $stub -NoPushIntegration|ConvertFrom-Json -DateKind String
  $raceObligations=@(Get-ChildItem -LiteralPath $raceRuntime -Filter 'integration-owed-*.json' -File|Where-Object{$_.Name-notlike'integration-owed-ack-*'-and$_.Name-notlike'integration-owed-accept-*'});$raceAcks=@(Get-ChildItem -LiteralPath $raceRuntime -Filter 'integration-owed-ack-*.json' -File);$raceRows=@(Get-Content $raceHistory|ForEach-Object{$_|ConvertFrom-Json -DateKind String}|Where-Object{$_.integrationDispatchSchema-ceq'landed-integration-dispatch/v1'})
  Assert-True ($producerResult.exitCode-eq0-and$producerJson.targets[0].action-ceq'OWED_ACTIVE_WRITER'-and$producerJson.targets[0].handoff-ceq'NO_OWNER_CLAIM'-and$raceHead-cne$raceTarget-and$raceObligations.Count-eq0-and$raceAcks.Count-eq0-and$raceRows.Count-eq1-and$raceReplay.targets[0].action-ceq'DUPLICATE_SKIPPED'-and-not(Test-Path $raceCalls)-and@(Get-ChildItem -LiteralPath $raceRuntime -Filter 'dispatch-launch-*.json' -File).Count-eq0) "release-before-publication barrier did not yield one integration/terminal, zero retained acknowledgements/stranded obligations/second writers, and acknowledged-only duplicate suppression: $($producerResult.stderr)"

  foreach($handoffArm in @('durable-owner','withheld-ack')){
  $ownerContainer=Join-Path $root ('synthetic-exact-owner-container-'+$handoffArm);$ownerRepo=Join-Path $ownerContainer 'owner-lane';$ownerRuntime=Join-Path $ownerContainer 'runtime';New-Item -ItemType Directory -Path $ownerRepo,$ownerRuntime|Out-Null;& git -C $ownerRepo init -q --initial-branch=main;& git -C $ownerRepo config user.name 'Synthetic Exact Owner';& git -C $ownerRepo config user.email 'synthetic-exact-owner@example.invalid';Set-Content (Join-Path $ownerRepo 'base.txt') base;& git -C $ownerRepo add base.txt;& git -C $ownerRepo commit -q -m base;& git -C $ownerRepo checkout -q -b synthetic/exact-owner;Set-Content (Join-Path $ownerRepo 'feature.txt') feature;& git -C $ownerRepo add feature.txt;& git -C $ownerRepo commit -q -m feature;$ownerTarget=(& git -C $ownerRepo rev-parse HEAD).Trim();& git -C $ownerRepo checkout -q main;Set-Content (Join-Path $ownerRepo 'main.txt') advance;& git -C $ownerRepo add main.txt;& git -C $ownerRepo commit -q -m advance;$ownerBase=(& git -C $ownerRepo rev-parse HEAD).Trim();& git -C $ownerRepo checkout -q synthetic/exact-owner
  $exactLaunch=[guid]::NewGuid().ToString();$exactOwnerPath=Join-Path $ownerRuntime "dispatch-launch-$exactLaunch.json";$exactPrompt=Join-Path $ownerRuntime "dispatch-heavy-verifier-$exactLaunch.prompt.txt";$exactTranscript=Join-Path $ownerRuntime 'synthetic-exact-owner.jsonl';[IO.File]::WriteAllText($exactPrompt,'exact owner',[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($exactTranscript,"{`"type`":`"item.completed`"}`n",[Text.UTF8Encoding]::new($false));$testStart=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
  $exactOwner=[ordered]@{schemaVersion=4;launchId=$exactLaunch;laneRole='implementation';promptPath=$exactPrompt;reviewIsolationRoot=$null;launcherPid=[long]$PID;launcherStartIdentity=$testStart;recordedAt=[DateTime]::UtcNow.ToString('o');state='launching';childPid=$null;childStartIdentity=$null;worktree=[IO.Path]::GetFullPath($ownerRepo).TrimEnd('\','/');lane='owner-lane';identityMode='branch';branch='synthetic/exact-owner';head=$ownerTarget;label='synthetic-exact-owner';transcriptPath=$exactTranscript};[IO.File]::WriteAllText($exactOwnerPath,($exactOwner|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
  $ownerFixture=[ordered]@{schemaVersion='landed-integration-census/v1';complete=$true;newBase=$ownerBase;landed=[ordered]@{pr=[long]900200;head=('2'*40);files=[ordered]@{complete=$true;totalCount=[long]1;nodes=@([ordered]@{path='feature.txt'})}};openPullRequests=[ordered]@{complete=$true;totalCount=[long]1;nodes=@([ordered]@{number=[long]900201;headRefOid=$ownerTarget;headRefName='synthetic/exact-owner';mergeable='MERGEABLE';mergeStateStatus='CLEAN';worktree=$ownerRepo;files=[ordered]@{complete=$true;totalCount=[long]1;nodes=@([ordered]@{path='feature.txt'})}})}};$ownerFixturePath=Join-Path $ownerContainer 'census.json';[IO.File]::WriteAllText($ownerFixturePath,($ownerFixture|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false));$ownerHistory=Join-Path $ownerRuntime 'history.jsonl';$ownerCalls=Join-Path $ownerRuntime 'second-writer-calls.txt';$env:SYNTHETIC_DISPATCH_CALLS=$ownerCalls
  $handoffEntered=Join-Path $ownerContainer 'handoff-entered';$handoffContinue=Join-Path $ownerContainer 'handoff-continue'
  $nativeTrace=Join-Path $ownerContainer 'native-git-trace.jsonl';$previousTrace=$env:GIT_TRACE2_EVENT;$env:GIT_TRACE2_EVENT=$nativeTrace
  try{
    $exactProducerArgs=@('-NoProfile','-NonInteractive','-File',$script,'-LandedPr','900200','-LandedHead',('2'*40),'-HistoryPath',$ownerHistory,'-RuntimeRoot',$ownerRuntime,'-ContainerRoot',$ownerContainer,'-FixturePath',$ownerFixturePath,'-DispatchScript',$stub,'-HandoffEnteredPath',$handoffEntered,'-HandoffContinuePath',$handoffContinue,'-NoPushIntegration')
    $exactProducer=Start-SyntheticPwsh $exactProducerArgs (Join-Path $ownerContainer 'producer.stdout.log') (Join-Path $ownerContainer 'producer.stderr.log')
    Wait-SyntheticFile $handoffEntered
    $observedDeadline=[datetime]::Parse([IO.File]::ReadAllText($handoffEntered)).ToUniversalTime()
    $exactConsume=$null
    if($handoffArm-ceq'durable-owner'){
      $exactConsume=& $consumer -Branch 'synthetic/exact-owner' -Worktree $ownerRepo -RuntimeRoot $ownerRuntime -HistoryPath $ownerHistory -AcceptingOwnerRecordPath $exactOwnerPath -AcceptingOwnerLaunchId $exactLaunch -NoPush|ConvertFrom-Json -DateKind String
      $durableAcks=@(Get-ChildItem -LiteralPath $ownerRuntime -Filter 'integration-owed-ack-*.json' -File)
      Assert-True ($durableAcks.Count-eq1) "F3 durable owner acknowledgement count actual=$($durableAcks.Count) expected=1"
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
    $exactProducerResult=Complete-SyntheticPwsh $exactProducer
    $exactMatch=[regex]::Match($exactProducerResult.stdout,'(?s)\{\s*"schemaVersion"\s*:\s*"landed-integration-dispatch-result/v1".*\}\s*$')
    if(-not$exactMatch.Success){throw "exact-owner producer emitted no result: $($exactProducerResult.stderr)"}
    $exactProducerJson=$exactMatch.Value|ConvertFrom-Json -DateKind String
    $exactTerminal=$exactProducerJson
    $exactHead=(& git -C $ownerRepo rev-parse HEAD).Trim()
    $exactReplay=& $script -LandedPr 900200 -LandedHead ('2'*40) -HistoryPath $ownerHistory -RuntimeRoot $ownerRuntime -ContainerRoot $ownerContainer -FixturePath $ownerFixturePath -DispatchScript $stub -NoPushIntegration|ConvertFrom-Json -DateKind String
    Assert-True ($exactReplay.targets[0].action-ceq'DUPLICATE_SKIPPED') "F3 replay action actual=$($exactReplay.targets[0].action) expected=DUPLICATE_SKIPPED"
  }finally{$env:GIT_TRACE2_EVENT=$previousTrace}
  if(Test-Path -LiteralPath $exactOwnerPath){
    $currentExactOwner=Get-Content -LiteralPath $exactOwnerPath -Raw|ConvertFrom-Json -DateKind String
    Assert-True (Remove-DispatchLaunchResources $exactOwnerPath $currentExactOwner $ownerRuntime ([IO.Path]::GetTempPath())) 'F3 durable synthetic owner cleanup refused'
    Remove-Item -LiteralPath $exactTranscript -Force
  }
  $exactObligations=@(Get-ChildItem -LiteralPath $ownerRuntime -Filter 'integration-owed-*.json' -File|Where-Object{$_.Name-notlike'integration-owed-ack-*'-and$_.Name-notlike'integration-owed-accept-*'});$exactAcks=@(Get-ChildItem -LiteralPath $ownerRuntime -Filter 'integration-owed-ack-*.json' -File);$exactRows=@(Get-Content $ownerHistory|ForEach-Object{$_|ConvertFrom-Json -DateKind String}|Where-Object{$_.integrationDispatchSchema-ceq'landed-integration-dispatch/v1'})
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

  function New-Connection([object[]]$Nodes,[long]$Total,[bool]$HasNext,[string]$Cursor){
    [ordered]@{totalCount=$Total;pageInfo=[ordered]@{hasNextPage=$HasNext;endCursor=$Cursor};nodes=@($Nodes)}
  }
  function Add-GraphStep($Queue,[string]$Name,[string]$QueryContains,$Variables,$Payload,[string]$Error=$null){
    $Queue.Add([ordered]@{name=$Name;queryContains=$QueryContains;variables=$Variables;payload=$Payload;error=$Error})
  }
  function New-CorePayload($Pr,[string]$State,[string]$Head,[string]$Branch,[string]$Mergeable,[string]$MergeState,[long]$ChangedFiles){
    [ordered]@{data=[ordered]@{repository=[ordered]@{pullRequest=[ordered]@{number=[long]$Pr;state=$State;headRefOid=$Head;headRefName=$Branch;mergeable=$Mergeable;mergeStateStatus=$MergeState;changedFiles=$ChangedFiles}}}}
  }
  function New-FilePayload($Pr,[string]$Head,[long]$ChangedFiles,$Connection){
    [ordered]@{data=[ordered]@{repository=[ordered]@{pullRequest=[ordered]@{number=[long]$Pr;headRefOid=$Head;changedFiles=$ChangedFiles;files=$Connection}}}}
  }
  function New-GraphQueue([int]$OuterCount=1,[int]$TargetPosition=1,[int]$TargetFileCount=101){
    $queue=[Collections.Generic.List[object]]::new();$owner='synthetic-owner';$name='synthetic-repo';$landedPr=900001;$targetPr=910000+$TargetPosition
    $landedCore=New-CorePayload $landedPr 'MERGED' $landedHead 'synthetic/landed' 'MERGEABLE' 'CLEAN' 1
    Add-GraphStep $queue 'landed-before' 'changedFiles' ([ordered]@{owner=$owner;name=$name;pr=$landedPr}) $landedCore
    $landedConnection=New-Connection @([ordered]@{path='catalog/pin.json'}) 1 $false $null
    Add-GraphStep $queue 'landed-files' 'files(first:100' ([ordered]@{owner=$owner;name=$name;pr=$landedPr;cursor=$null}) (New-FilePayload $landedPr $landedHead 1 $landedConnection)
    Add-GraphStep $queue 'landed-after' 'changedFiles' ([ordered]@{owner=$owner;name=$name;pr=$landedPr}) $landedCore
    $openNodes=[Collections.Generic.List[object]]::new()
    foreach($position in 1..$OuterCount){
      $pr=910000+$position;$isTarget=$position-eq$TargetPosition;$head=if($isTarget){'c'*40}else{('{0:x40}' -f $position)}
      $openNodes.Add([ordered]@{number=[long]$pr;headRefOid=$head;headRefName=$(if($isTarget){'synthetic/cap-boundary'}else{"synthetic/outer-$position"});mergeable='MERGEABLE';mergeStateStatus='CLEAN';changedFiles=[long]$(if($isTarget){$TargetFileCount}else{1})})
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
  function Invoke-GraphControl([string]$Name,$Queue,[bool]$ExpectPass){
    $controlRuntime=Join-Path $productionRoot "runtime-$Name";New-Item -ItemType Directory -Path $controlRuntime|Out-Null
    $graphPath=Join-Path $controlRuntime 'graph.json';[IO.File]::WriteAllText($graphPath,($Queue|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
    $controlCalls=Join-Path $controlRuntime 'calls.txt';$env:SYNTHETIC_DISPATCH_CALLS=$controlCalls;$failure=$null;$value=$null
    try{$value=& $script -LandedPr 900001 -LandedHead $landedHead -Repository 'synthetic-owner/synthetic-repo' -HistoryPath (Join-Path $controlRuntime 'history.jsonl') -RuntimeRoot $controlRuntime -ContainerRoot $productionRoot -GraphFixturePath $graphPath -DispatchScript $stub -SynchronousDispatch|ConvertFrom-Json -DateKind String}catch{$failure=$_.Exception.Message}
    $callCount=if(Test-Path -LiteralPath $controlCalls){@(Get-Content -LiteralPath $controlCalls).Count}else{0}
    if($ExpectPass){Assert-True ($null-eq$failure-and$value.targetCount-eq1-and$callCount-eq1) "$Name did not traverse the wired paginated collector and dispatch the sole decisive target (failure=$failure targetCount=$($value.targetCount) calls=$callCount)"}
    else{Assert-True ($null-ne$failure-and$failure-match'CENSUS_UNKNOWN'-and$callCount-eq0) "$Name did not fail UNKNOWN before dispatch (failure=$failure calls=$callCount)"}
  }

  $productionRoot=Join-Path $root 'synthetic-production-container';$productionRepository=Join-Path $productionRoot 'main';$productionWorktree=Join-Path $productionRoot 'synthetic-production-repo';New-Item -ItemType Directory -Path $productionRepository|Out-Null
  & git -C $productionRepository init -q --initial-branch=main
  Set-Content -LiteralPath (Join-Path $productionRepository 'seed.txt') -Value 'unmistakably synthetic census fixture'
  & git -C $productionRepository add seed.txt;& git -C $productionRepository -c user.name='Synthetic Test' -c user.email='synthetic@example.invalid' commit -q -m 'synthetic fixture';& git -C $productionRepository worktree add -q -b synthetic/cap-boundary $productionWorktree HEAD
  Invoke-GraphControl 'outer-and-file-page-101' (New-GraphQueue -OuterCount 101 -TargetPosition 101 -TargetFileCount 101) $true

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
  Write-Output 'PASS landed exact-once census plus wired outer/file pagination, page-101 decisive intersection, changedFiles/totalCount identity, exact-head re-observation, and partial/error/unsafe/cap UNKNOWN controls'
}finally{
  Remove-Item Env:SYNTHETIC_DISPATCH_CALLS -ErrorAction SilentlyContinue
  Remove-Item Env:SYNTHETIC_INTEGRATION_FAIL -ErrorAction SilentlyContinue
  Remove-Item Env:SYNTHETIC_LANDED_TRIGGER -ErrorAction SilentlyContinue
  $resolved=[IO.Path]::GetFullPath($root);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
  if((Split-Path -Parent $resolved).TrimEnd('\','/')-ne$temp-or(Split-Path -Leaf $resolved)-notlike'landed-integration-test-*'){throw "unsafe cleanup $resolved"}
  Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
}
