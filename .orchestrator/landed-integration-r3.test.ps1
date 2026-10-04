$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'routing-data-test-support.ps1')
$routingTestScope=Enter-RoutingDataTestScope
try {
$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('landed-integration-r3-'+[guid]::NewGuid().ToString('N'))
$producer=Join-Path $PSScriptRoot 'landed-integration-dispatch.ps1'
$consumer=Join-Path $PSScriptRoot 'landed-integration-consume.ps1'
$logger=Join-Path $PSScriptRoot 'log-event.ps1'
$failures=[Collections.Generic.List[string]]::new()
. (Join-Path $PSScriptRoot 'landed-integration-evidence-test-support.ps1')
. (Join-Path $PSScriptRoot 'integration-dispatch-test-support.ps1')

function Assert-True($Condition,[string]$Message){if(-not$Condition){throw "ASSERTION FAILED: $Message"}}
function New-SyntheticRepository([string]$Path,[string]$Branch,[string]$Label){
  New-Item -ItemType Directory -Path $Path|Out-Null
  & git -C $Path init -q --initial-branch=main
  & git -C $Path config user.name "Synthetic $Label"
  & git -C $Path config user.email "synthetic-$($Label.ToLowerInvariant())@example.invalid"
  Set-Content -LiteralPath (Join-Path $Path 'base.txt') -Value 'base'
  & git -C $Path add base.txt
  & git -C $Path commit -q -m base
  & git -C $Path checkout -q -b $Branch
  Set-Content -LiteralPath (Join-Path $Path 'feature.txt') -Value "feature $Label"
  & git -C $Path add feature.txt
  & git -C $Path commit -q -m feature
  $target=(& git -C $Path rev-parse HEAD).Trim()
  & git -C $Path checkout -q main
  Set-Content -LiteralPath (Join-Path $Path 'main.txt') -Value "advance $Label"
  & git -C $Path add main.txt
  & git -C $Path commit -q -m advance
  $base=(& git -C $Path rev-parse HEAD).Trim()
  & git -C $Path checkout -q $Branch
  [pscustomobject]@{path=[IO.Path]::GetFullPath($Path).TrimEnd('\','/');branch=$Branch;target=$target;base=$base}
}
function Write-SyntheticOwner([string]$Runtime,$Repository,[string]$Label){
  $launchId=[guid]::NewGuid().ToString();$recordPath=Join-Path $Runtime "dispatch-launch-$launchId.json"
  $promptPath=Join-Path $Runtime "dispatch-heavy-verifier-$launchId.prompt.txt";$transcriptPath=Join-Path $Runtime "$Label.jsonl"
  [IO.File]::WriteAllText($promptPath,"unmistakably synthetic owner $Label",[Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText($transcriptPath,"{`"type`":`"item.completed`"}`n",[Text.UTF8Encoding]::new($false))
  $record=[ordered]@{schemaVersion=4;launchId=$launchId;laneRole='implementation';promptPath=$promptPath;reviewIsolationRoot=$null;launcherPid=[long]$PID;launcherStartIdentity=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o');recordedAt=[DateTime]::UtcNow.ToString('o');state='launching';childPid=$null;childStartIdentity=$null;worktree=$Repository.path;lane=(Split-Path -Leaf $Repository.path);identityMode='branch';branch=$Repository.branch;head=$Repository.target;label=$Label;transcriptPath=$transcriptPath}
  [IO.File]::WriteAllText($recordPath,($record|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
  [pscustomobject]@{launchId=$launchId;recordPath=$recordPath;promptPath=$promptPath;transcriptPath=$transcriptPath;bytes=[IO.File]::ReadAllBytes($recordPath)}
}
function New-SyntheticObligation($Repository,[long]$LandedPr,[string]$LandedHead,[long]$Pr){
  [ordered]@{schemaVersion='landed-integration-owed/v1';landedPr=$LandedPr;landedHead=$LandedHead;pr=$Pr;targetHead=$Repository.target;newBase=$Repository.base;branch=$Repository.branch;worktree=$Repository.path;integrationLane="integration-$LandedPr-$Pr-$($LandedHead.Substring(0,8))"}
}
function Get-SyntheticIdentity($Value){
  $line=$Value|ConvertTo-Json -Compress
  ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($line)))).ToLowerInvariant()
}
function New-SyntheticAcknowledgement($Obligation,[string]$ResultHead,[string]$Status='REVIEW_REQUIRED'){
  $identity=Get-SyntheticIdentity $Obligation
  [ordered]@{schemaVersion='landed-integration-owed-ack/v2';obligationIdentity=$identity;landedPr=[long]$Obligation.landedPr;landedHead=[string]$Obligation.landedHead;pr=[long]$Obligation.pr;targetHead=[string]$Obligation.targetHead;newBase=[string]$Obligation.newBase;branch=[string]$Obligation.branch;worktree=[string]$Obligation.worktree;integrationLane=[string]$Obligation.integrationLane;predecessorHead=[string]$Obligation.targetHead;resultHead=$ResultHead;resultStatus=$Status;acknowledgedAt=[datetimeoffset]::UtcNow.ToString('o')}
}
function Write-SyntheticAcknowledgement([string]$Runtime,$Acknowledgement){
  $path=Join-Path $Runtime "integration-owed-ack-v2-$($Acknowledgement.landedPr)-$($Acknowledgement.landedHead)-$($Acknowledgement.pr)-$($Acknowledgement.obligationIdentity).json"
  [IO.File]::WriteAllText($path,($Acknowledgement|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
  $path
}
function Write-SyntheticFixture([string]$Path,$Repository,[long]$LandedPr,[string]$LandedHead,[long]$Pr,[string]$HeadOverride,[string]$FilePath='feature.txt',[string]$AuthorityHistory){
  $head=if($HeadOverride){$HeadOverride}else{$Repository.target}
  $fixture=[ordered]@{schemaVersion='landed-integration-census/v1';complete=$true;newBase=$Repository.base;landed=[ordered]@{pr=$LandedPr;head=$LandedHead;files=[ordered]@{complete=$true;totalCount=[long]1;nodes=@([ordered]@{path=$FilePath})}};openPullRequests=[ordered]@{complete=$true;totalCount=[long]1;nodes=@([ordered]@{number=$Pr;headRefOid=$head;headRefName=$Repository.branch;mergeable='MERGEABLE';mergeStateStatus='CLEAN';worktree=$Repository.path;files=[ordered]@{complete=$true;totalCount=[long]1;nodes=@([ordered]@{path=$FilePath})}})}}
  [IO.File]::WriteAllText($Path,($fixture|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
  if(-not$AuthorityHistory){$AuthorityHistory=Join-Path (Split-Path -Parent $Path) 'runtime/history.jsonl'}
  Write-SyntheticIntegrationEligibility $AuthorityHistory $fixture.openPullRequests.nodes
}
function Get-Obligations([string]$Runtime){
  @(Get-ChildItem -LiteralPath $Runtime -Filter 'integration-owed-*.json' -File|Where-Object{$_.Name-notlike'integration-owed-ack-*'-and$_.Name-notlike'integration-owed-accept-*'})
}
function Start-SyntheticPwsh([string[]]$Arguments){
  $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=(Get-Command pwsh -CommandType Application|Select-Object -First 1 -ExpandProperty Source);$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
  foreach($argument in $Arguments){[void]$start.ArgumentList.Add($argument)}
  $process=[Diagnostics.Process]::Start($start)
  [pscustomobject]@{process=$process;stdout=$process.StandardOutput.ReadToEndAsync();stderr=$process.StandardError.ReadToEndAsync()}
}
function Complete-SyntheticPwsh($Handle,[int]$Seconds=45){
  if(-not$Handle.process.WaitForExit($Seconds*1000)){throw "synthetic process did not finish: $($Handle.process.Id)"}
  $stdout=$Handle.stdout.GetAwaiter().GetResult();$stderr=$Handle.stderr.GetAwaiter().GetResult();$code=$Handle.process.ExitCode;$Handle.process.Dispose()
  [pscustomobject]@{exitCode=$code;stdout=$stdout;stderr=$stderr}
}
function Convert-ProducerResult([string]$Output){
  $match=[regex]::Match($Output,'(?s)\{\s*"schemaVersion"\s*:\s*"landed-integration-dispatch-result/v1".*\}\s*$')
  if(-not$match.Success){throw "synthetic producer emitted no result: $Output"}
  $match.Value|ConvertFrom-Json -DateKind String
}
function Write-AssignmentRow([string]$History,$Repository,[long]$LandedPr,[string]$LandedHead,[long]$Pr){
  & $logger -Log dispatch -Kind dispatch -Pr $Pr -IntegrationDispatchSchema landed-integration-dispatch/v1 -LandedPr $LandedPr -LandedHead $LandedHead -TargetHead $Repository.target -TargetBranch $Repository.branch -IntegrationReason INTERSECTING -IntegrationDisposition OWED_ACTIVE_WRITER -TargetIntegrationLane "integration-$LandedPr-$Pr-$($LandedHead.Substring(0,8))" -IntegrationWorktree $Repository.path -Harness codex -Model gpt-6-astra -Effort high -Row 7 -Placement override-Todd -OutFile $History -NoBoard|Out-Null
}

function Test-F13BranchScopedOwners{
  $container=Join-Path $fixtureRoot 'synthetic-f13-container';$runtime=Join-Path $container 'runtime';New-Item -ItemType Directory -Path $runtime|Out-Null
  $target=New-SyntheticRepository (Join-Path $container 'target-lane') 'synthetic/pending-target' 'F13Target'
  $unrelated=New-SyntheticRepository (Join-Path $container 'unrelated-lane') 'synthetic/unrelated-live' 'F13Unrelated'
  $owner=Write-SyntheticOwner $runtime $unrelated 'synthetic-f13-unrelated-owner'
  $landedPr=[long]900300;$landedHead='a'*40;$pr=[long]900301;$obligation=New-SyntheticObligation $target $landedPr $landedHead $pr
  $owedPath=Join-Path $runtime "integration-owed-$pr-$($landedHead.Substring(0,12)).json";[IO.File]::WriteAllText($owedPath,($obligation|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
  $fixturePath=Join-Path $container 'census.json';Write-SyntheticFixture $fixturePath $target $landedPr $landedHead $pr;$history=Join-Path $runtime 'history.jsonl'
  $value=& $producer -LandedPr $landedPr -LandedHead $landedHead -HistoryPath $history -RuntimeRoot $runtime -ContainerRoot $container -Repository $SyntheticIntegrationRepository -FixturePath $fixturePath -NoPushIntegration|ConvertFrom-Json -DateKind String
  $replay=& $producer -LandedPr $landedPr -LandedHead $landedHead -HistoryPath $history -RuntimeRoot $runtime -ContainerRoot $container -Repository $SyntheticIntegrationRepository -FixturePath $fixturePath -NoPushIntegration|ConvertFrom-Json -DateKind String
  $rows=@(Get-Content -LiteralPath $history|ForEach-Object{$_|ConvertFrom-Json -DateKind String}|Where-Object{$_.integrationDispatchSchema-cin@('landed-integration-dispatch/v1','landed-integration-dispatch/v2')})
  Assert-True ($value.targets[0].action-ceq'OWED_ACTIVE_WRITER'-and$value.targets[0].handoff-ceq'NO_OWNER_CLAIM'-and(Get-Obligations $runtime).Count-eq0-and@(Get-ChildItem $runtime -Filter 'integration-owed-ack-*.json').Count-eq0-and$rows.Count-eq1-and$replay.targets[0].action-ceq'DUPLICATE_SKIPPED'-and[Convert]::ToBase64String([IO.File]::ReadAllBytes($owner.recordPath))-ceq[Convert]::ToBase64String($owner.bytes)-and-not(Get-Process -Id $PID -ErrorAction SilentlyContinue).HasExited) 'F13 unrelated live owner stranded the target obligation, changed the unrelated owner, or bypassed post-success duplicate suppression'

  $duplicateContainer=Join-Path $fixtureRoot 'synthetic-f13-duplicate-container';$duplicateRuntime=Join-Path $duplicateContainer 'runtime';New-Item -ItemType Directory -Path $duplicateRuntime|Out-Null
  $duplicateTarget=New-SyntheticRepository (Join-Path $duplicateContainer 'target-a') 'synthetic/duplicate-target' 'F13DuplicateA'
  $duplicateOther=New-SyntheticRepository (Join-Path $duplicateContainer 'target-b') 'synthetic/duplicate-target' 'F13DuplicateB'
  [void](Write-SyntheticOwner $duplicateRuntime $duplicateTarget 'synthetic-f13-duplicate-a');[void](Write-SyntheticOwner $duplicateRuntime $duplicateOther 'synthetic-f13-duplicate-b')
  $duplicateLanded='b'*40;$duplicateObligation=New-SyntheticObligation $duplicateTarget 900310 $duplicateLanded 900311;$duplicateOwed=Join-Path $duplicateRuntime "integration-owed-900311-$($duplicateLanded.Substring(0,12)).json";[IO.File]::WriteAllText($duplicateOwed,($duplicateObligation|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
  $duplicateFixture=Join-Path $duplicateContainer 'census.json';Write-SyntheticFixture $duplicateFixture $duplicateTarget 900310 $duplicateLanded 900311;$duplicateFailure=$null
  $duplicateHistoryBefore=[IO.File]::ReadAllText((Join-Path $duplicateRuntime 'history.jsonl'))
  try{& $producer -LandedPr 900310 -LandedHead $duplicateLanded -HistoryPath (Join-Path $duplicateRuntime 'history.jsonl') -RuntimeRoot $duplicateRuntime -ContainerRoot $duplicateContainer -Repository $SyntheticIntegrationRepository -FixturePath $duplicateFixture -NoPushIntegration|Out-Null}catch{$duplicateFailure=$_.Exception.Message}
  Assert-True ($duplicateFailure-match'CENSUS_UNKNOWN_HANDOFF_OWNER'-and(Get-Obligations $duplicateRuntime).Count-eq1-and[IO.File]::ReadAllText((Join-Path $duplicateRuntime 'history.jsonl'))-ceq$duplicateHistoryBefore-and(& git -C $duplicateTarget.path rev-parse HEAD).Trim()-ceq$duplicateTarget.target) 'F13 duplicate matching owners did not remain unknown with zero integration'
}

function Test-F14AcknowledgedCompletion{
  $container=Join-Path $fixtureRoot 'synthetic-f14-failure-container';$runtime=Join-Path $container 'runtime';New-Item -ItemType Directory -Path $runtime|Out-Null
  $target=New-SyntheticRepository (Join-Path $container 'target-lane') 'synthetic/premature-success' 'F14Failure'
  $owner=Write-SyntheticOwner $runtime $target 'synthetic-f14-exact-owner';$landedPr=[long]900500;$landedHead='c'*40;$pr=[long]900501;$obligation=New-SyntheticObligation $target $landedPr $landedHead $pr
  $owedPath=Join-Path $runtime "integration-owed-$pr-$($landedHead.Substring(0,12)).json";[IO.File]::WriteAllText($owedPath,($obligation|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
  $fixturePath=Join-Path $container 'census.json';Write-SyntheticFixture $fixturePath $target $landedPr $landedHead $pr;$history=Join-Path $runtime 'history.jsonl'
  $producerHandle=Start-SyntheticPwsh @('-NoProfile','-NonInteractive','-File',$producer,'-LandedPr',[string]$landedPr,'-LandedHead',$landedHead,'-HistoryPath',$history,'-RuntimeRoot',$runtime,'-ContainerRoot',$container,'-Repository',$SyntheticIntegrationRepository,'-FixturePath',$fixturePath,'-NoPushIntegration')
  $deadline=[DateTime]::UtcNow.AddSeconds(20);do{if(Test-Path -LiteralPath $owedPath -PathType Leaf){break};if([DateTime]::UtcNow-ge$deadline){throw 'F14 exact obligation was not visible'};[Threading.Thread]::Sleep(25)}while($true)
  $exit19=Join-Path $container 'synthetic-exit-19.ps1';Set-Content -LiteralPath $exit19 -Value 'exit 19';$consumerFailure=$null
  try{& $consumer -Branch $target.branch -Worktree $target.path -RuntimeRoot $runtime -HistoryPath $history -AcceptingOwnerRecordPath $owner.recordPath -AcceptingOwnerLaunchId $owner.launchId -IntegrationScript $exit19 -NoPush|Out-Null}catch{$consumerFailure=$_.Exception.Message}
  $producerResult=Complete-SyntheticPwsh $producerHandle;$producerValue=Convert-ProducerResult $producerResult.stdout
  $failureRows=if(Test-Path $history){@(Get-Content $history|ForEach-Object{$_|ConvertFrom-Json -DateKind String}|Where-Object{$_.integrationDispatchSchema-cin@('landed-integration-dispatch/v1','landed-integration-dispatch/v2')})}else{@()}
  $preRetryNoTerminal=$failureRows.Count-eq0
  if($failureRows.Count-eq0){Write-AssignmentRow $history $target $landedPr $landedHead $pr}
  Remove-Item -LiteralPath $owner.recordPath,$owner.promptPath,$owner.transcriptPath -Force
  $retry=& $producer -LandedPr $landedPr -LandedHead $landedHead -HistoryPath $history -RuntimeRoot $runtime -ContainerRoot $container -Repository $SyntheticIntegrationRepository -FixturePath $fixturePath -NoPushIntegration|ConvertFrom-Json -DateKind String
  $replay=& $producer -LandedPr $landedPr -LandedHead $landedHead -HistoryPath $history -RuntimeRoot $runtime -ContainerRoot $container -Repository $SyntheticIntegrationRepository -FixturePath $fixturePath -NoPushIntegration|ConvertFrom-Json -DateKind String
  $retryHead=(& git -C $target.path rev-parse HEAD).Trim();$retryRows=@(Get-Content $history|ForEach-Object{$_|ConvertFrom-Json -DateKind String}|Where-Object{$_.integrationDispatchSchema-cin@('landed-integration-dispatch/v1','landed-integration-dispatch/v2')})

  $closeContainer=Join-Path $fixtureRoot 'synthetic-f14-ack-close-container';$closeRuntime=Join-Path $closeContainer 'runtime';New-Item -ItemType Directory -Path $closeRuntime|Out-Null
  $closeTarget=New-SyntheticRepository (Join-Path $closeContainer 'target-lane') 'synthetic/ack-closed' 'F14AckClose';$closeLandedPr=[long]900400;$closeLanded='d'*40;$closePr=[long]900401;$closeObligation=New-SyntheticObligation $closeTarget $closeLandedPr $closeLanded $closePr
  $closeOwed=Join-Path $closeRuntime "integration-owed-$closePr-$($closeLanded.Substring(0,12)).json";[IO.File]::WriteAllText($closeOwed,($closeObligation|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false));$closeHistory=Join-Path $closeRuntime 'history.jsonl'
  & $consumer -Branch $closeTarget.branch -Worktree $closeTarget.path -RuntimeRoot $closeRuntime -HistoryPath $closeHistory -NoPush|Out-Null
  $closeReplay=& $consumer -Branch $closeTarget.branch -Worktree $closeTarget.path -RuntimeRoot $closeRuntime -HistoryPath $closeHistory -NoPush|ConvertFrom-Json -DateKind String
  Remove-Item -LiteralPath $closeOwed -Force -ErrorAction SilentlyContinue
  $closedHead=(& git -C $closeTarget.path rev-parse HEAD).Trim();$closeFixture=Join-Path $closeContainer 'census.json';Write-SyntheticFixture $closeFixture $closeTarget $closeLandedPr $closeLanded $closePr $closedHead
  $closeAckPath=@(Get-ChildItem -LiteralPath $closeRuntime -Filter 'integration-owed-ack-*.json' -File)[0].FullName;$closeAckOriginal=[IO.File]::ReadAllText($closeAckPath)
  $unrelatedObligation=New-SyntheticObligation $closeTarget 900410 $closeLanded 900411;$unrelatedAck=New-SyntheticAcknowledgement $unrelatedObligation $closedHead;$unrelatedAckPath=Write-SyntheticAcknowledgement $closeRuntime $unrelatedAck
  & git -C $closeTarget.path reset -q --hard $closeTarget.target
  $resetUnknown=$false;try{& $producer -LandedPr $closeLandedPr -LandedHead $closeLanded -HistoryPath $closeHistory -RuntimeRoot $closeRuntime -ContainerRoot $closeContainer -Repository $SyntheticIntegrationRepository -FixturePath $closeFixture -NoPushIntegration|Out-Null}catch{$resetUnknown=$_.Exception.Message-match'CENSUS_UNKNOWN_HANDOFF_ACKNOWLEDGEMENT'}
  & git -C $closeTarget.path reset -q --hard $closedHead
  $mismatchedAck=$closeAckOriginal|ConvertFrom-Json -DateKind String;$mismatchedAck.landedPr=[long]900499;$mismatchedAck.targetHead='e'*40;[IO.File]::WriteAllText($closeAckPath,($mismatchedAck|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
  $mismatchedUnknown=$false;try{& $producer -LandedPr $closeLandedPr -LandedHead $closeLanded -HistoryPath $closeHistory -RuntimeRoot $closeRuntime -ContainerRoot $closeContainer -Repository $SyntheticIntegrationRepository -FixturePath $closeFixture -NoPushIntegration|Out-Null}catch{$mismatchedUnknown=$_.Exception.Message-match'CENSUS_UNKNOWN_HANDOFF_ACKNOWLEDGEMENT'}
  $missingAck=$closeAckOriginal|ConvertFrom-Json -DateKind String;$missingAck.resultHead='f'*40;[IO.File]::WriteAllText($closeAckPath,($missingAck|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
  $missingUnknown=$false;try{& $producer -LandedPr $closeLandedPr -LandedHead $closeLanded -HistoryPath $closeHistory -RuntimeRoot $closeRuntime -ContainerRoot $closeContainer -Repository $SyntheticIntegrationRepository -FixturePath $closeFixture -NoPushIntegration|Out-Null}catch{$missingUnknown=$_.Exception.Message-match'CENSUS_UNKNOWN_HANDOFF_ACKNOWLEDGEMENT'}
  [IO.File]::WriteAllText($closeAckPath,$closeAckOriginal,[Text.UTF8Encoding]::new($false));Set-Content -LiteralPath (Join-Path $closeTarget.path 'descendant.txt') -Value 'synthetic descendant';& git -C $closeTarget.path add descendant.txt;& git -C $closeTarget.path commit -q -m descendant
  $descendantHead=(& git -C $closeTarget.path rev-parse HEAD).Trim();$ambiguousGit=Join-Path $closeContainer 'ambiguous-git.ps1';Set-Content -LiteralPath $ambiguousGit -Value "if (`$args -contains 'merge-base') { Write-Output ambiguous; exit 2 }`n& git @args`nexit `$LASTEXITCODE"
  $ambiguousUnknown=$false;try{& $producer -LandedPr $closeLandedPr -LandedHead $closeLanded -HistoryPath $closeHistory -RuntimeRoot $closeRuntime -ContainerRoot $closeContainer -Repository $SyntheticIntegrationRepository -FixturePath $closeFixture -HandoffGitExecutable $ambiguousGit -NoPushIntegration|Out-Null}catch{$ambiguousUnknown=$_.Exception.Message-match'CENSUS_UNKNOWN_HANDOFF_ACKNOWLEDGEMENT'}
  $dispatchCalls=Join-Path $closeRuntime 'dispatch-calls.txt';$stub=Join-Path $closeContainer 'dispatch-lane.ps1';$env:SYNTHETIC_R3_DISPATCH_CALLS=$dispatchCalls;$env:SYNTHETIC_R3_EXPECTED_BRANCH=$closeTarget.branch;$env:SYNTHETIC_R3_EXPECTED_HEAD=$closeTarget.target
  Set-Content -LiteralPath $stub -Value @'
param($Harness,$Model,$Effort,$Row,$Placement,$LaneRole,$PromptFile,$Worktree,$Label,$StartRequestIdentity,$StartAcknowledgementPath,$IntegrationTargetPath,$IntegrationAuthorityFixturePath)
Add-Content -LiteralPath $env:SYNTHETIC_R3_DISPATCH_CALLS -Value $Label
$launchId=[guid]::NewGuid().ToString();$owner=Join-Path (Split-Path -Parent $StartAcknowledgementPath) "dispatch-launch-$launchId.json"
$ack=[ordered]@{schemaVersion='dispatch-start-ack/v1';requestIdentity=$StartRequestIdentity;label=$Label;launchId=$launchId;ownershipRecordPath=$owner;worktree=[IO.Path]::GetFullPath($Worktree).TrimEnd('\','/');branch=$env:SYNTHETIC_R3_EXPECTED_BRANCH;head=$env:SYNTHETIC_R3_EXPECTED_HEAD;harness=$Harness;model=$Model;effort=$Effort;row=[long]$Row;placement=$Placement;state='started';childPid=[long]$PID;childStartIdentity=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')}
[IO.File]::WriteAllText($StartAcknowledgementPath,($ack|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
'@
  $closeValue=& $producer -LandedPr $closeLandedPr -LandedHead $closeLanded -HistoryPath $closeHistory -RuntimeRoot $closeRuntime -ContainerRoot $closeContainer -Repository $SyntheticIntegrationRepository -FixturePath $closeFixture -DispatchScript $stub -SynchronousDispatch -NoPushIntegration|ConvertFrom-Json -DateKind String
  $closeRows=@(Get-Content $closeHistory|ForEach-Object{$_|ConvertFrom-Json -DateKind String}|Where-Object{$_.integrationDispatchSchema-cin@('landed-integration-dispatch/v1','landed-integration-dispatch/v2')});$closeHeadAfter=(& git -C $closeTarget.path rev-parse HEAD).Trim()
  Assert-True ($consumerFailure-match'OWED_INTEGRATION_EXECUTION_FAILED_19'-and$producerResult.exitCode-eq0-and$producerValue.targets[0].action-ceq'HANDOFF_RETRYABLE'-and$preRetryNoTerminal-and$retry.targets[0].action-ceq'DUPLICATE_SKIPPED'-and$retryHead-cne$target.target-and(Get-Obligations $runtime).Count-eq0-and@(Get-ChildItem $runtime -Filter 'integration-owed-ack-*.json').Count-eq0-and$retryRows.Count-eq1-and$replay.targets[0].action-ceq'DUPLICATE_SKIPPED'-and$closeReplay.results[0].status-ceq'ACKNOWLEDGED_REPLAY'-and$resetUnknown-and$mismatchedUnknown-and$missingUnknown-and$ambiguousUnknown-and$closeValue.targets[0].action-ceq'OWED_ACTIVE_WRITER'-and$closeValue.targets[0].handoff-ceq'ACKNOWLEDGED_REPLAY'-and$closeRows.Count-eq1-and$closeHeadAfter-ceq$descendantHead-and(Test-Path $unrelatedAckPath)-and-not(Test-Path $closeAckPath)-and-not(Test-Path $dispatchCalls)-and(Get-Obligations $closeRuntime).Count-eq0) 'F14 accepted exit-19 was terminally suppressed, historical assignment blocked retry, acknowledgement-close replay launched a second integration, or reset/missing/ambiguous/mismatched evidence did not remain unknown and retained'
}

function Test-F15AcknowledgementOnlyReconciliation{
  $container=Join-Path $fixtureRoot 'synthetic-f15-container';$runtime=Join-Path $container 'runtime';New-Item -ItemType Directory -Path $runtime|Out-Null
  $target=New-SyntheticRepository (Join-Path $container 'target-lane') 'synthetic/fresh-census-ack' 'F15FreshCensus';$landedPr=[long]900700;$landedHead='7'*40;$pr=[long]900701
  $obligation=New-SyntheticObligation $target $landedPr $landedHead $pr;$obligation.worktree=$obligation.worktree.ToUpperInvariant()
  Assert-True (-not[string]::Equals([string]$obligation.worktree,[string]$target.path,[StringComparison]::Ordinal)-and(Test-ConsumerSamePathForControl ([string]$obligation.worktree) ([string]$target.path))) 'F15 synthetic worktree spelling did not differ only in case'
  $owedPath=Join-Path $runtime "integration-owed-$pr-$($landedHead.Substring(0,12)).json";[IO.File]::WriteAllText($owedPath,($obligation|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false));$history=Join-Path $runtime 'history.jsonl'
  & $consumer -Branch $target.branch -Worktree $target.path -RuntimeRoot $runtime -HistoryPath $history -NoPush|Out-Null
  $ackPath=@(Get-ChildItem -LiteralPath $runtime -Filter "integration-owed-ack-v2-$landedPr-$landedHead-$pr-*.json" -File)[0].FullName;$ack=Get-Content -LiteralPath $ackPath -Raw|ConvertFrom-Json -DateKind String
  Assert-True ($ack.schemaVersion-ceq'landed-integration-owed-ack/v2'-and[string]$ack.newBase-ceq[string]$obligation.newBase-and[string]$ack.worktree-ceq[string]$obligation.worktree-and[string]$ack.obligationIdentity-ceq(Get-SyntheticIdentity $obligation)) 'F15 consumer did not preserve the exact obligation serialization in v2'
  Remove-Item -LiteralPath $owedPath -Force
  $resultHead=[string]$ack.resultHead;$fixturePath=Join-Path $container 'census.json';Write-SyntheticFixture $fixturePath $target $landedPr $landedHead $pr $resultHead
  $foreignPaths=@();foreach($offset in 1..3){$foreignObligation=New-SyntheticObligation $target ([long]($landedPr+$offset)) $landedHead ([long]($pr+$offset));$foreignAck=New-SyntheticAcknowledgement $foreignObligation $resultHead;$foreignPaths+=Write-SyntheticAcknowledgement $runtime $foreignAck}
  $dispatchCalls=Join-Path $runtime 'dispatch-calls.txt';$stub=Join-Path $container 'dispatch-lane.ps1';$env:SYNTHETIC_R3_DISPATCH_CALLS=$dispatchCalls;$env:SYNTHETIC_R3_EXPECTED_BRANCH=$target.branch;$env:SYNTHETIC_R3_EXPECTED_HEAD=$resultHead
  Set-Content -LiteralPath $stub -Value @'
param($Harness,$Model,$Effort,$Row,$Placement,$LaneRole,$PromptFile,$Worktree,$Label,$StartRequestIdentity,$StartAcknowledgementPath,$IntegrationTargetPath,$IntegrationAuthorityFixturePath)
Add-Content -LiteralPath $env:SYNTHETIC_R3_DISPATCH_CALLS -Value $Label
throw 'SYNTHETIC_F15_SECOND_LAUNCH'
'@
  $failedLogger=Join-Path $container 'failed-log.ps1';Set-Content -LiteralPath $failedLogger -Value "throw 'SYNTHETIC_DURABLE_APPEND_FAILURE'"
  $historyBeforeFailure=[IO.File]::ReadAllText($history)
  $appendFailure=$false;try{& $producer -LandedPr $landedPr -LandedHead $landedHead -HistoryPath $history -RuntimeRoot $runtime -ContainerRoot $container -Repository $SyntheticIntegrationRepository -FixturePath $fixturePath -DispatchScript $stub -LogScript $failedLogger -SynchronousDispatch -NoPushIntegration|Out-Null}catch{$appendFailure=$_.Exception.Message-match'SYNTHETIC_DURABLE_APPEND_FAILURE'}
  $stateRetainedAfterFailure=(Test-Path -LiteralPath $ackPath -PathType Leaf)-and[IO.File]::ReadAllText($history)-ceq$historyBeforeFailure-and-not(Test-Path -LiteralPath $dispatchCalls -PathType Leaf)
  $value=& $producer -LandedPr $landedPr -LandedHead $landedHead -HistoryPath $history -RuntimeRoot $runtime -ContainerRoot $container -Repository $SyntheticIntegrationRepository -FixturePath $fixturePath -DispatchScript $stub -SynchronousDispatch -NoPushIntegration|ConvertFrom-Json -DateKind String
  $replay=& $producer -LandedPr $landedPr -LandedHead $landedHead -HistoryPath $history -RuntimeRoot $runtime -ContainerRoot $container -Repository $SyntheticIntegrationRepository -FixturePath $fixturePath -DispatchScript $stub -SynchronousDispatch -NoPushIntegration|ConvertFrom-Json -DateKind String
  $rows=@(Get-Content $history|ForEach-Object{$_|ConvertFrom-Json -DateKind String}|Where-Object{$_.integrationDispatchSchema-cin@('landed-integration-dispatch/v1','landed-integration-dispatch/v2')});$headAfter=(& git -C $target.path rev-parse HEAD).Trim()
  Assert-True ($appendFailure-and$stateRetainedAfterFailure-and$value.targets[0].action-ceq'OWED_ACTIVE_WRITER'-and$value.targets[0].handoff-ceq'ACKNOWLEDGED_REPLAY'-and$replay.targets[0].action-ceq'DUPLICATE_SKIPPED'-and$rows.Count-eq1-and[string]$rows[0].targetHead-ceq$resultHead-and$headAfter-ceq$resultHead-and-not(Test-Path $ackPath)-and-not(Test-Path $dispatchCalls)-and(Get-Obligations $runtime).Count-eq0-and@($foreignPaths|Where-Object{Test-Path -LiteralPath $_ -PathType Leaf}).Count-eq3) 'F15 moved-head acknowledgement-only recovery did not append once, launch zero, retain state through append failure, retire only matching state, or preserve foreign records'

  $negativeContainer=Join-Path $fixtureRoot 'synthetic-f15-negative-container';$negativeRuntime=Join-Path $negativeContainer 'runtime';New-Item -ItemType Directory -Path $negativeRuntime|Out-Null
  $negativeTarget=New-SyntheticRepository (Join-Path $negativeContainer 'target-lane') 'synthetic/f15-negative' 'F15Negative';$negativeLandedPr=[long]900720;$negativeLanded='8'*40;$negativePr=[long]900721
  $negativeFixture=Join-Path $negativeContainer 'census.json';Write-SyntheticFixture $negativeFixture $negativeTarget $negativeLandedPr $negativeLanded $negativePr;$negativeHistory=Join-Path $negativeRuntime 'history.jsonl';$negativeCalls=Join-Path $negativeRuntime 'dispatch-calls.txt'
  $env:SYNTHETIC_R3_DISPATCH_CALLS=$negativeCalls;$env:SYNTHETIC_R3_EXPECTED_BRANCH=$negativeTarget.branch;$env:SYNTHETIC_R3_EXPECTED_HEAD=$negativeTarget.target
  $negativeHistoryBefore=[IO.File]::ReadAllText($negativeHistory)
  $negativeStub=Join-Path $negativeContainer 'dispatch-lane.ps1';Set-Content -LiteralPath $negativeStub -Value @'
param($Harness,$Model,$Effort,$Row,$Placement,$LaneRole,$PromptFile,$Worktree,$Label,$StartRequestIdentity,$StartAcknowledgementPath,$IntegrationTargetPath,$IntegrationAuthorityFixturePath)
Add-Content -LiteralPath $env:SYNTHETIC_R3_DISPATCH_CALLS -Value $Label
throw 'SYNTHETIC_F15_NEGATIVE_LAUNCH'
'@
  $baseObligation=New-SyntheticObligation $negativeTarget $negativeLandedPr $negativeLanded $negativePr;$firstAck=New-SyntheticAcknowledgement $baseObligation $negativeTarget.target;$firstPath=Write-SyntheticAcknowledgement $negativeRuntime $firstAck
  $secondObligation=New-SyntheticObligation $negativeTarget $negativeLandedPr $negativeLanded $negativePr;$secondObligation.newBase=$negativeTarget.target;$secondAck=New-SyntheticAcknowledgement $secondObligation $negativeTarget.target;$secondPath=Write-SyntheticAcknowledgement $negativeRuntime $secondAck
  $twoUnknown=$false;try{& $producer -LandedPr $negativeLandedPr -LandedHead $negativeLanded -HistoryPath $negativeHistory -RuntimeRoot $negativeRuntime -ContainerRoot $negativeContainer -Repository $SyntheticIntegrationRepository -FixturePath $negativeFixture -DispatchScript $negativeStub -SynchronousDispatch -NoPushIntegration|Out-Null}catch{$twoUnknown=$_.Exception.Message-match'CENSUS_UNKNOWN_HANDOFF_ACKNOWLEDGEMENT'}
  Remove-Item -LiteralPath $firstPath,$secondPath -Force
  $mismatchAck=New-SyntheticAcknowledgement $baseObligation $negativeTarget.target;$mismatchPath=Write-SyntheticAcknowledgement $negativeRuntime $mismatchAck;$mismatchAck.branch='synthetic/f15-mismatch';[IO.File]::WriteAllText($mismatchPath,($mismatchAck|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
  $mismatchUnknown=$false;try{& $producer -LandedPr $negativeLandedPr -LandedHead $negativeLanded -HistoryPath $negativeHistory -RuntimeRoot $negativeRuntime -ContainerRoot $negativeContainer -Repository $SyntheticIntegrationRepository -FixturePath $negativeFixture -DispatchScript $negativeStub -SynchronousDispatch -NoPushIntegration|Out-Null}catch{$mismatchUnknown=$_.Exception.Message-match'CENSUS_UNKNOWN_HANDOFF_ACKNOWLEDGEMENT'}
  Remove-Item -LiteralPath $mismatchPath -Force
  $malformedPath=Join-Path $negativeRuntime "integration-owed-ack-v2-$negativeLandedPr-$negativeLanded-$negativePr-$('9'*64).json";[IO.File]::WriteAllText($malformedPath,'{',[Text.UTF8Encoding]::new($false))
  $malformedUnknown=$false;try{& $producer -LandedPr $negativeLandedPr -LandedHead $negativeLanded -HistoryPath $negativeHistory -RuntimeRoot $negativeRuntime -ContainerRoot $negativeContainer -Repository $SyntheticIntegrationRepository -FixturePath $negativeFixture -DispatchScript $negativeStub -SynchronousDispatch -NoPushIntegration|Out-Null}catch{$malformedUnknown=$_.Exception.Message-match'CENSUS_UNKNOWN_HANDOFF_ACKNOWLEDGEMENT'}
  Remove-Item -LiteralPath $malformedPath -Force
  $legacyObligation=New-SyntheticObligation $negativeTarget $negativeLandedPr $negativeLanded $negativePr;$legacyObligation.targetHead=$negativeTarget.base;$legacyIdentity=Get-SyntheticIdentity $legacyObligation;$legacyPath=Join-Path $negativeRuntime "integration-owed-ack-$legacyIdentity.json";$legacy=[ordered]@{schemaVersion='landed-integration-owed-ack/v1';obligationIdentity=$legacyIdentity;landedPr=$negativeLandedPr;landedHead=$negativeLanded;pr=$negativePr;targetHead=$negativeTarget.base;branch=$negativeTarget.branch;worktree=$negativeTarget.path;integrationLane=[string]$legacyObligation.integrationLane;predecessorHead=$negativeTarget.base;resultHead=$negativeTarget.target;resultStatus='REVIEW_REQUIRED';acknowledgedAt=[datetimeoffset]::UtcNow.ToString('o')};[IO.File]::WriteAllText($legacyPath,($legacy|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
  $legacyUnknown=$false;try{& $producer -LandedPr $negativeLandedPr -LandedHead $negativeLanded -HistoryPath $negativeHistory -RuntimeRoot $negativeRuntime -ContainerRoot $negativeContainer -Repository $SyntheticIntegrationRepository -FixturePath $negativeFixture -DispatchScript $negativeStub -SynchronousDispatch -NoPushIntegration|Out-Null}catch{$legacyUnknown=$_.Exception.Message-match'CENSUS_UNKNOWN_HANDOFF_ACKNOWLEDGEMENT'}
  Assert-True ($twoUnknown-and$mismatchUnknown-and$malformedUnknown-and$legacyUnknown-and(Test-Path $legacyPath)-and[IO.File]::ReadAllText($negativeHistory)-ceq$negativeHistoryBefore-and-not(Test-Path $negativeCalls)-and(Get-Obligations $negativeRuntime).Count-eq0) 'F15 two-current, mismatched, malformed, or legacy acknowledgement evidence did not fail closed with zero append and zero launch'

  $f16Container=Join-Path $fixtureRoot 'synthetic-f16-container';$f16Runtime=Join-Path $f16Container 'runtime';New-Item -ItemType Directory -Path $f16Runtime|Out-Null
  $f16Target=New-SyntheticRepository (Join-Path $f16Container 'target-lane') 'synthetic/f16-malformed-v2' 'F16MalformedV2';$f16LandedPr=[long]991000;$f16Landed='6'*40;$f16Pr=[long]991001
  $f16Fixture=Join-Path $f16Container 'census.json';Write-SyntheticFixture $f16Fixture $f16Target $f16LandedPr $f16Landed $f16Pr;$f16History=Join-Path $f16Runtime 'history.jsonl';$f16Calls=Join-Path $f16Runtime 'dispatch-calls.txt'
  $f16MalformedPath=Join-Path $f16Runtime ("integration-owed-ack-v2-$('g'*70).json");[IO.File]::WriteAllText($f16MalformedPath,'{',[Text.UTF8Encoding]::new($false))
  $f16HistoryBefore=[IO.File]::ReadAllText($f16History)
  $env:SYNTHETIC_R3_DISPATCH_CALLS=$f16Calls;$env:SYNTHETIC_R3_EXPECTED_BRANCH=$f16Target.branch;$env:SYNTHETIC_R3_EXPECTED_HEAD=$f16Target.target
  $f16Stub=Join-Path $f16Container 'dispatch-lane.ps1';Set-Content -LiteralPath $f16Stub -Value @'
param($Harness,$Model,$Effort,$Row,$Placement,$LaneRole,$PromptFile,$Worktree,$Label,$StartRequestIdentity,$StartAcknowledgementPath,$IntegrationTargetPath,$IntegrationAuthorityFixturePath)
Add-Content -LiteralPath $env:SYNTHETIC_R3_DISPATCH_CALLS -Value $Label
$launchId=[guid]::NewGuid().ToString();$owner=Join-Path (Split-Path -Parent $StartAcknowledgementPath) "dispatch-launch-$launchId.json"
$ack=[ordered]@{schemaVersion='dispatch-start-ack/v1';requestIdentity=$StartRequestIdentity;label=$Label;launchId=$launchId;ownershipRecordPath=$owner;worktree=[IO.Path]::GetFullPath($Worktree).TrimEnd('\','/');branch=$env:SYNTHETIC_R3_EXPECTED_BRANCH;head=$env:SYNTHETIC_R3_EXPECTED_HEAD;harness=$Harness;model=$Model;effort=$Effort;row=[long]$Row;placement=$Placement;state='started';childPid=[long]$PID;childStartIdentity=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')}
[IO.File]::WriteAllText($StartAcknowledgementPath,($ack|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
'@
  Publish-SyntheticIntegrationRemote $f16Target.path (Join-Path $f16Container 'remote.git')
  $f16Census=Get-Content $f16Fixture -Raw|ConvertFrom-Json -DateKind String
  $f16Authority=Write-SyntheticIntegrationAuthority (Join-Path $f16Container 'authority.json') $f16Census.openPullRequests.nodes $f16Target.base
  $f16Logger=Join-Path $f16Container 'log-event.ps1';Set-Content -LiteralPath $f16Logger -Value @'
param($Log,$Kind,$Pr,$IntegrationDispatchSchema,$LandedPr,$LandedHead,$TargetHead,$TargetBranch,$IntegrationReason,$IntegrationDisposition,$TargetIntegrationLane,$IntegrationWorktree,$Harness,$Model,$Effort,$Row,$Placement,$OutFile,[switch]$NoBoard)
Add-Content -LiteralPath $OutFile -Value ([ordered]@{integrationDispatchSchema=$IntegrationDispatchSchema;landedPr=[long]$LandedPr;landedHead=$LandedHead;pr=[long]$Pr;integrationDisposition=$IntegrationDisposition}|ConvertTo-Json -Compress)
'@
  $candidateUnknown=$false;try{& $producer -LandedPr $f16LandedPr -LandedHead $f16Landed -HistoryPath $f16History -RuntimeRoot $f16Runtime -ContainerRoot $f16Container -Repository $SyntheticIntegrationRepository -FixturePath $f16Fixture -IntegrationAuthorityFixturePath $f16Authority -DispatchScript $f16Stub -LogScript $f16Logger -SynchronousDispatch -NoPushIntegration|Out-Null}catch{$candidateUnknown=$_.Exception.Message-match'CENSUS_UNKNOWN_HANDOFF_ACKNOWLEDGEMENT'}
  $candidateNoMutation=$candidateUnknown-and(Test-Path $f16MalformedPath)-and-not(Test-Path $f16Calls)-and[IO.File]::ReadAllText($f16History)-ceq$f16HistoryBefore
  $subjectRoot=Join-Path $f16Container 'bypass-subject';New-Item -ItemType Directory -Path $subjectRoot|Out-Null
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'dispatch-ownership.ps1'),(Join-Path $PSScriptRoot 'fleet-exclusive-admission.psm1'),(Join-Path $PSScriptRoot 'review-head-contract.psm1'),(Join-Path $PSScriptRoot 'landed-integration-evidence.psm1'),(Join-Path $PSScriptRoot 'integration-dispatch-contract.ps1'),(Join-Path $PSScriptRoot 'routing-data.ps1') -Destination $subjectRoot
  $candidateSource=[IO.File]::ReadAllText($producer);$fenceCall='  Assert-HandoffAcknowledgementNamespace';Assert-True ([regex]::Matches($candidateSource,[regex]::Escape($fenceCall)).Count-eq1) 'F16 bypass mutant did not find exactly one namespace-fence carrier'
  $mutantSource=$candidateSource.Replace($fenceCall,'  $null=$true <# MUTANT_REMOVED_V2_ACKNOWLEDGEMENT_NAMESPACE_FENCE #>');$mutantProducer=Join-Path $subjectRoot 'landed-integration-dispatch.ps1';[IO.File]::WriteAllText($mutantProducer,$mutantSource,[Text.UTF8Encoding]::new($false))
  $mutantValue=& $mutantProducer -LandedPr $f16LandedPr -LandedHead $f16Landed -HistoryPath $f16History -RuntimeRoot $f16Runtime -ContainerRoot $f16Container -Repository $SyntheticIntegrationRepository -FixturePath $f16Fixture -IntegrationAuthorityFixturePath $f16Authority -DispatchScript $f16Stub -LogScript $f16Logger -SynchronousDispatch -NoPushIntegration|ConvertFrom-Json -DateKind String
  $mutantRows=@(Get-Content -LiteralPath $f16History);$mutantCalls=@(Get-Content -LiteralPath $f16Calls)
  Assert-True ($candidateNoMutation-and$mutantValue.targets[0].action-ceq'LAUNCHED'-and$mutantCalls.Count-eq1-and$mutantRows.Count-eq2-and(Test-Path $f16MalformedPath)) 'F16 malformed v2 candidate did not fail closed or the single-clause bypass mutant did not reproduce one launch and one terminal append'
  Write-Output 'EVIDENCE F16 candidate=PASS outcome=CENSUS_UNKNOWN_HANDOFF_ACKNOWLEDGEMENT dispatch=0 terminal=0 retained=true mutant=MUTANT_REMOVED_V2_ACKNOWLEDGEMENT_NAMESPACE_FENCE:FAIL action=LAUNCHED dispatch=1 terminal=1 retained=true synthetic=991000/991001'
}

function Test-ConsumerSamePathForControl([string]$Left,[string]$Right){
  [string]::Equals([IO.Path]::GetFullPath($Left).TrimEnd('\','/'),[IO.Path]::GetFullPath($Right).TrimEnd('\','/'),[StringComparison]::OrdinalIgnoreCase)
}

function Test-7926F1TerminalCleanup {
  # The before arm uses the immutable reviewed producer with the repaired F2
  # dependency, isolating F1 from the protected-ancestor failure.
  $beforeRoot=Join-Path $fixtureRoot 'synthetic-f1-before-producer'
  New-Item -ItemType Directory -Path $beforeRoot|Out-Null
  foreach($name in @('integration-dispatch-contract.ps1','dispatch-ownership.ps1','fleet-exclusive-admission.psm1','review-head-contract.psm1','landed-integration-evidence.psm1','landed-integration-consume.ps1','rebase-integration.ps1','log-event.ps1','orchestration-log-lock.psm1')){
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $beforeRoot
  }
  $beforeRevision='6e9156f8393de4b8f54519ece506d3b488adcd75'
  $beforeSource=@(& git -C (Split-Path -Parent $PSScriptRoot) show "${beforeRevision}:.orchestrator/landed-integration-dispatch.ps1")
  Assert-True ($LASTEXITCODE-eq0) 'F1 immutable reviewed producer available'
  $beforeProducer=Join-Path $beforeRoot 'landed-integration-dispatch.ps1'
  [IO.File]::WriteAllText($beforeProducer,($beforeSource-join"`n"))
  $beforeLogger=@(& git -C (Split-Path -Parent $PSScriptRoot) show "${beforeRevision}:.orchestrator/log-event.ps1")
  Assert-True ($LASTEXITCODE-eq0) 'F1 immutable reviewed logger available'
  [IO.File]::WriteAllText((Join-Path $beforeRoot 'log-event.ps1'),($beforeLogger-join"`n"))
  foreach($arm in @('candidate','before')){
    $container=Join-Path $fixtureRoot "synthetic-f1-$arm";$runtime=Join-Path $container 'runtime'
    New-Item -ItemType Directory -Path $runtime|Out-Null
    $target=New-SyntheticRepository (Join-Path $container 'lane') "synthetic/f1-$arm" "F1$arm"
    $landedPr=[long]992610;$landedHead='a'*40;$pr=[long]992611
    $obligation=New-SyntheticObligation $target $landedPr $landedHead $pr
    $identity=Get-SyntheticIdentity $obligation
    $owedPath=Join-Path $runtime "integration-owed-$pr-$($landedHead.Substring(0,12)).json"
    [IO.File]::WriteAllText($owedPath,($obligation|ConvertTo-Json -Compress))
    $fixture=Join-Path $container 'census.json';Write-SyntheticFixture $fixture $target $landedPr $landedHead $pr
    $history=Join-Path $runtime 'history.jsonl';$subject=if($arm-ceq'before'){$beforeProducer}else{$producer}
    $terminal=Complete-SyntheticPwsh (Start-SyntheticPwsh @('-NoProfile','-NonInteractive','-File',$subject,'-LandedPr',"$landedPr",'-LandedHead',$landedHead,'-HistoryPath',$history,'-RuntimeRoot',$runtime,'-ContainerRoot',$container,'-Repository',$SyntheticIntegrationRepository,'-FixturePath',$fixture,'-NoPushIntegration'))
    [IO.File]::WriteAllText((Join-Path $container 'terminal.stdout'),$terminal.stdout);[IO.File]::WriteAllText((Join-Path $container 'terminal.stderr'),$terminal.stderr)
    Assert-True ($terminal.exitCode-eq0) "F1 $arm actual producer completes: $($terminal.stderr)"
    $rows=@(Get-Content $history|ForEach-Object{$_|ConvertFrom-Json -DateKind String}|Where-Object{$_.integrationDispatchSchema-cin@('landed-integration-dispatch/v1','landed-integration-dispatch/v2')})
    Assert-True ($rows.Count-eq1-and-not(Test-Path $owedPath)) "F1 $arm exactly one terminal before owed deletion"
    $acks=@(Get-ChildItem $runtime -Filter "integration-owed-ack-v*-$identity.json")
    $first=(& git -C $target.path rev-parse HEAD).Trim()
    & git -C $target.path checkout -q main
    Set-Content (Join-Path $target.path 'second-base.txt') 'synthetic next integration'
    & git -C $target.path add second-base.txt
    & git -C $target.path commit -qm 'synthetic second base'
    $secondBase=(& git -C $target.path rev-parse HEAD).Trim()
    & git -C $target.path checkout -q $target.branch
    & git -C $target.path rebase --onto $secondBase $target.base
    Assert-True ($LASTEXITCODE-eq0) 'F1 ordinary second native branch rebase completes'
    & git -C $target.path merge-base --is-ancestor $first HEAD
    Assert-True ($LASTEXITCODE-eq1) 'F1 first result is an existing nonancestor after second rebase'
    $read=Complete-SyntheticPwsh (Start-SyntheticPwsh @('-NoProfile','-NonInteractive','-File',$consumer,'-Branch',$target.branch,'-Worktree',$target.path,'-RuntimeRoot',$runtime,'-HistoryPath',$history))
    [IO.File]::WriteAllText((Join-Path $container 'consumer.stdout'),$read.stdout);[IO.File]::WriteAllText((Join-Path $container 'consumer.stderr'),$read.stderr)
    [IO.File]::WriteAllText((Join-Path $container 'consumer.exit'),[string]$read.exitCode)
    if($arm-ceq'candidate'){
      Assert-True ($acks.Count-eq0-and$read.exitCode-eq0-and($read.stdout|ConvertFrom-Json).consumed-eq0) 'F1 complete terminal leaves no matching ack and ordinary second rewrite consumes zero'
    }else{
      Assert-True ($acks.Count-eq1-and$read.exitCode-ne0-and$read.stderr.Contains('OWED_INTEGRATION_ACK_UNKNOWN')) 'F1 candidate-before fails the same day-after regression'
    }
    Write-Output "EVIDENCE 7926 F1 arm=$arm terminalExit=$($terminal.exitCode) terminalRows=$($rows.Count) matchingAcks=$($acks.Count) consumerExit=$($read.exitCode) synthetic=true"
  }
}

function Test-7926F2ProtectedBoundary {
  $module=Import-Module (Join-Path $PSScriptRoot 'landed-integration-evidence.psm1') -Force -DisableNameChecking -PassThru
  try {
    & $module {
      # Explicit unit simulation, separate from the real protected-ancestor run.
      function script:Get-CimInstance { [pscustomobject]@{ParentProcessId=2147482000} }
      function script:Get-Process { [pscustomobject]@{Id=2147482000} }
      function script:Get-DispatchProcessStartIdentity($ProcessId) { if($ProcessId-eq$PID){'2026-09-12T00:00:00Z'}else{$null} }
      $chain=@(Get-RebaseProcessChain)
      if($chain.Count-ne1-or$chain[0].id-ne$PID){throw 'synthetic F2 did not stop at unreadable ancestor'}
      function script:Get-ChildItem { [pscustomobject]@{FullName='synthetic-observer-record.json'} }
      function script:Get-ValidatedDispatchOwnershipRecord {
        [pscustomobject]@{laneRole='observer';launcherPid=$PID;launcherStartIdentity='2026-09-12T00:00:00Z';childPid=2147481999;childStartIdentity='2026-09-12T00:00:01Z'}
      }
      $denial=$null;try{Assert-RebaseProducerProcess 'synthetic-unit-runtime'}catch{$denial=$_.Exception.Message}
      if($denial-cne'OWED_REBASE_OWNER_UNAUTHORIZED: observer'){throw "synthetic below-boundary observer was not refused: $denial"}
      function script:Get-DispatchProcessStartIdentity { $null }
      $denial=$null;try{Get-RebaseProcessChain}catch{$denial=$_.Exception.Message}
      if($denial-cne'OWED_REBASE_OWNER_UNAUTHORIZED: start unknown'){throw 'synthetic unreadable self was not refused'}
      Write-Output 'EVIDENCE 7926 F2 synthetic=true readableSelf=accepted unreadableAncestor=stopped belowBoundaryObserver=refused unreadableSelf=refused'
    }
  } finally { Remove-Module $module; Import-Module (Join-Path $PSScriptRoot 'landed-integration-evidence.psm1') -Force -DisableNameChecking }
}

# #8103 AC2: a live, readable parent whose start is later than the observer's
# is a reused parent PID; the chain ends at the observer as it does at an exited
# parent, and an unreadable first-link start still refuses start unknown.
function Test-8103ReusedParentEndsChain {
  $module=Import-Module (Join-Path $PSScriptRoot 'landed-integration-evidence.psm1') -Force -DisableNameChecking -PassThru
  try {
    & $module {
      # Explicit unit simulation, as 7926 F2: one parent row, live, born after the observer.
      function script:Get-CimInstance { [pscustomobject]@{ParentProcessId=2147482000} }
      function script:Get-Process { [pscustomobject]@{Id=2147482000} }
      function script:Get-DispatchProcessStartIdentity($ProcessId) { if($ProcessId-eq$PID){'2026-09-12T00:00:00Z'}else{'2026-09-12T00:00:01Z'} }
      $chain=@(Get-RebaseProcessChain)
      if($chain.Count-ne1-or$chain[0].id-ne$PID-or$chain[0].start-cne'2026-09-12T00:00:00Z'){throw "synthetic reused parent did not end the chain at the observer: links=$($chain.Count)"}
      function script:Get-DispatchProcessStartIdentity { $null }
      $denial=$null;try{Get-RebaseProcessChain}catch{$denial=$_.Exception.Message}
      if($denial-cne'OWED_REBASE_OWNER_UNAUTHORIZED: start unknown'){throw "synthetic unreadable self was not refused: $denial"}
      Write-Output 'EVIDENCE 8103 reused-parent-ends-chain synthetic=true reusedParent=chain-ends-at-observer unreadableSelf=refused'
    }
  } finally { Remove-Module $module; Import-Module (Join-Path $PSScriptRoot 'landed-integration-evidence.psm1') -Force -DisableNameChecking }
}

try{
  New-Item -ItemType Directory -Path $fixtureRoot|Out-Null
  Test-8185AuthPartition
  foreach($control in @([pscustomobject]@{name='7962-native';body={Test-7962NativeControls}},[pscustomobject]@{name='7926-F2';body={Test-7926F2ProtectedBoundary}},[pscustomobject]@{name='reused-parent-ends-chain';body={Test-8103ReusedParentEndsChain}},[pscustomobject]@{name='7926-F1';body={Test-7926F1TerminalCleanup}},[pscustomobject]@{name='F13';body={Test-F13BranchScopedOwners}},[pscustomobject]@{name='F14';body={Test-F14AcknowledgedCompletion}},[pscustomobject]@{name='F15';body={Test-F15AcknowledgementOnlyReconciliation}},[pscustomobject]@{name='7926';body={Test-7926CompletedRebase}})){
    try{& $control.body;Write-Output "CONTROL $($control.name) PASS"}catch{$failures.Add("$($control.name): $($_.Exception.Message)");Write-Output "CONTROL $($control.name) FAIL $($_.Exception.Message) $($_.ScriptStackTrace)"}
  }
  Assert-SyntheticIntegrationWitnesses $fixtureRoot
  if($failures.Count-gt0){throw "R3 controls failed: $($failures -join ' | ')"}
  Write-Output 'PASS R3 branch-scoped ownership and acknowledgement-gated terminal integration controls including F15 bounded acknowledgement-only reconciliation'
}finally{
  Remove-Item Env:SYNTHETIC_R3_DISPATCH_CALLS -ErrorAction SilentlyContinue
  Remove-Item Env:SYNTHETIC_R3_EXPECTED_BRANCH -ErrorAction SilentlyContinue
  Remove-Item Env:SYNTHETIC_R3_EXPECTED_HEAD -ErrorAction SilentlyContinue
  $resolved=[IO.Path]::GetFullPath($fixtureRoot);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
  if((Split-Path -Parent $resolved).TrimEnd('\','/')-ne$temp-or(Split-Path -Leaf $resolved)-notlike'landed-integration-r3-*'){throw "unsafe cleanup $resolved"}
  if (Test-Path -LiteralPath (Join-Path $resolved 'synthetic-7926')) {
    Write-Output "ARTIFACT 7926 retained synthetic Git, native reflogs, subprocess logs and exits: $resolved"
  } else { Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue }
}

. (Join-Path $PSScriptRoot 'interrupted-integration-test-support.ps1')

# ---- #8102: fleet load and the retained-retry discriminator ----
# Every leg runs the retained carrier from a committed copy of this checkout's
# tracked .orchestrator inventory inside its own temp container; the synthetic
# verify-lock.d holder (a CPU-heavy child owned and stopped by this test) and
# every source replacement exist only there. The live container's verify-lock.d
# is never read for these legs, never created and never touched.
# The phantom root makes the prior-owner tree guard refuse the retained-retry
# mutant arm, which is what a prior root whose teardown outlasts the arm's
# window does under fleet load; the phantom is set only around that arm.
$phantom8102PsmNeedle='    if (-not $rows.Count) { continue }'
$phantom8102Psm='    if (-not $rows.Count -and -not $env:SYNTHETIC_8102_PHANTOM_ROOT) { continue } # SYNTHETIC_8102_PHANTOM_ROOT: a rowless prior root outlasting the window, decided as an ambiguous root'
$phantom8102SupportNeedle='        Discriminator $f ''retained retry binds its current full index'' ''INTEGRATION_RESUME_STATE'' $retryMutant -LoadBound'
$phantom8102Support='        $env:SYNTHETIC_8102_PHANTOM_ROOT=''1'';try{Discriminator $f ''retained retry binds its current full index'' ''INTEGRATION_RESUME_STATE'' $retryMutant -LoadBound}finally{$env:SYNTHETIC_8102_PHANTOM_ROOT=$null}'
$unconditional8102Needle='if($LoadBound-and$bypass.exit-ne0-and$bypass.stderr.Contains(''INTEGRATION_RESUME_PRIOR_OWNER'')-and$window.held){'
$unconditional8102='if($LoadBound-and$bypass.exit-ne0-and$bypass.stderr.Contains(''INTEGRATION_RESUME_PRIOR_OWNER'')){ # SYNTHETIC_8102_MUTANT: MEASURED_LOAD without a concurrent holder'

function Invoke-8102RetainedLeg([string]$Test,[string]$Label,[hashtable]$Edits,[bool]$WithHolder) {
  $copy=New-8102FixtureCopy $Label $Edits
  $holder=$null;$holderIdentity='none'
  try {
    if($WithHolder){$holder=Start-SyntheticFleetHolder $copy.container;$holderIdentity=$holder.identity}
    $run=Invoke-8102CarrierCopy $copy 'retained'
  } finally { Stop-SyntheticFleetHolder $holder }
  $lines=@($run.stdout -split "\r?\n")
  $measured=@($lines|Where-Object{$_-clike'MEASURED_LOAD *'})
  $finished=[bool]@($lines|Where-Object{$_-clike'RETAINED 7963 retained *finished=True'}).Count
  $text=$run.stdout+"`n"+$run.stderr
  # Write-Host keeps the leg object the function's only pipeline output.
  Write-Host "CONTROL 8102 $Test $Label holder=$holderIdentity exit=$($run.exit) elapsedSeconds=$([int]$run.elapsedSeconds) measuredLines=$($measured.Count) finished=$finished stdout=$($run.stdoutPath) stderr=$($run.stderrPath)"
  return [pscustomobject]@{label=$Label;copy=$copy;run=$run;holder=$holderIdentity;measured=$measured;finished=$finished;exit=$run.exit;text=$text}
}
function Assert-8102([bool]$Condition,[string]$Test,[string]$Name,$Leg) {
  if(-not$Condition){throw "8102 $Test ASSERTION FAILED: $Name; leg=$($Leg.label) exit=$($Leg.exit) stdout=$($Leg.run.stdoutPath) stderr=$($Leg.run.stderrPath)"}
  Write-Output "PROOF 8102 $Test $Name"
}

# AC1 (retained): the retained-retry discriminator's omitted-guard arm refused by
# the prior-owner tree guard is MEASURED_LOAD, with holder identity and elapsed
# time, only while the synthetic holder is live across the arm; the same refusal
# on a vacant fleet stays FAIL; a discriminator that classifies it MEASURED_LOAD
# without a holder fails the vacant control; with no holder and no phantom root
# the unmodified carrier passes.
function Test-TimedFixtureUnderFleetLoadMeasuresLoad {
  $test='timed-fixture-under-fleet-load-measures-load'
  # Classifier legs are proof arms (Test-BatteryProofRelevant); the unmodified
  # retained carrier always runs.
  if(-not(Test-BatteryProofRelevant @('landed-integration-evidence.psm1','landed-integration-r3.test.ps1'))){
    Write-Output "SKIPPED 8102 $test classifier legs: classifier files unchanged in impact battery"
    Invoke-7963ResumeCarriers @('retained')
    return
  }
  $phantomEdits=@{'landed-integration-evidence.psm1'=@(,@($phantom8102PsmNeedle,$phantom8102Psm));'interrupted-integration-test-support.ps1'=@(,@($phantom8102SupportNeedle,$phantom8102Support))}
  $loaded=Invoke-8102RetainedLeg $test 'phantom-root-held' $phantomEdits $true
  Assert-8102 ($loaded.holder-cne'none'-and$loaded.exit-eq75-and$loaded.measured.Count-eq1-and-not$loaded.finished) $test "refused retained-retry arm under a live holder exits 75 with one MEASURED_LOAD line and an unfinished carrier (actual exit=$($loaded.exit) measuredLines=$($loaded.measured.Count))" $loaded
  $measuredLine=[regex]::Match($loaded.measured[0],'^MEASURED_LOAD 7963 retained fleetHolder='+[regex]::Escape($loaded.holder)+' elapsedSeconds=(\d+(\.\d+)?) discriminator=retained retry binds its current full index mutantExit=[1-9]\d* raw=\S+$')
  Assert-8102 $measuredLine.Success $test "MEASURED_LOAD line names the synthetic holder identity and the measured elapsed time: $($loaded.measured[0])" $loaded
  Assert-8102 (-not$loaded.text.Contains('independent omitted guard actual exit=')) $test 'MEASURED_LOAD leg is not the plain discriminator FAIL and never PASS' $loaded
  $vacant=Invoke-8102RetainedLeg $test 'phantom-root-vacant' $phantomEdits $false
  Assert-8102 ($vacant.exit-eq1-and$vacant.measured.Count-eq0-and-not$vacant.finished-and$vacant.text.Contains('7963 retained ASSERTION FAILED: retained retry binds its current full index independent omitted guard actual exit=')) $test "same refusal with no holder stays FAIL exit=1 with no MEASURED_LOAD line (actual exit=$($vacant.exit) measuredLines=$($vacant.measured.Count))" $vacant
  $mutantEdits=@{'landed-integration-evidence.psm1'=@(,@($phantom8102PsmNeedle,$phantom8102Psm));'interrupted-integration-test-support.ps1'=@(@($phantom8102SupportNeedle,$phantom8102Support),@($unconditional8102Needle,$unconditional8102))}
  $mutant=Invoke-8102RetainedLeg $test 'phantom-root-vacant-unconditional-mutant' $mutantEdits $false
  Assert-8102 ($mutant.exit-eq75-and$mutant.measured.Count-eq1-and$mutant.measured[0]-clike'MEASURED_LOAD 7963 retained fleetHolder=none elapsedSeconds=*') $test "discriminator mutant that classifies MEASURED_LOAD without a concurrent holder reports fleetHolder=none on a vacant fleet (actual exit=$($mutant.exit))" $mutant
  Assert-8102 (-not($mutant.exit-eq1-and$mutant.measured.Count-eq0-and$mutant.text.Contains('independent omitted guard actual exit='))) $test 'vacant-fleet FAIL control rejects that mutant' $mutant
  Invoke-7963ResumeCarriers @('retained')
  Write-Output "PASS 8102 $test held-refusal=MEASURED_LOAD vacant-refusal=FAIL vacant-mutant=CAUGHT vacant=PASS"
  foreach($leg in @($loaded,$vacant,$mutant)){Remove-8102FixtureCopy $leg.copy}
}

Test-TimedFixtureUnderFleetLoadMeasuresLoad
} finally { Exit-RoutingDataTestScope $routingTestScope }
