$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'routing-data-test-support.ps1')
$routingTestScope=Enter-RoutingDataTestScope
try {
$root=Join-Path ([IO.Path]::GetTempPath()) ('rebase-integration-test-'+[guid]::NewGuid().ToString('N'))
$repo=Join-Path $root 'unmistakably-synthetic-repo';$history=Join-Path $root 'history.jsonl';$integration=Join-Path $PSScriptRoot 'rebase-integration.ps1';$logEvent=Join-Path $PSScriptRoot 'log-event.ps1'
function Assert-True($Condition,[string]$Message){if(-not$Condition){throw "ASSERTION FAILED: $Message"}}
function Invoke-TestGit([string]$Path,[string[]]$Arguments){$output=@(& git.exe -C $Path @Arguments 2>&1);if($LASTEXITCODE-ne0){throw "git failed: $($Arguments-join' ')`n$($output-join"`n")"};($output-join"`n").Trim()}
function Initialize-Repo([string]$Path){New-Item -ItemType Directory -Path $Path|Out-Null;Invoke-TestGit $Path @('init','--initial-branch=main')|Out-Null;Invoke-TestGit $Path @('config','user.name','Unmistakably Synthetic Rebase Test')|Out-Null;Invoke-TestGit $Path @('config','user.email','synthetic-rebase@example.invalid')|Out-Null;Invoke-TestGit $Path @('config','commit.gpgsign','false')|Out-Null}
function Write-Commit([string]$Path,[string]$File,[string]$Value,[string]$Message){Set-Content -LiteralPath (Join-Path $Path $File) -Value $Value;Invoke-TestGit $Path @('add','--',$File)|Out-Null;Invoke-TestGit $Path @('commit','-m',$Message)|Out-Null;Invoke-TestGit $Path @('rev-parse','HEAD')}
function Write-History([string]$Path,[object[]]$Rows){$text=($Rows|ForEach-Object{$_|ConvertTo-Json -Compress -Depth 10})-join[Environment]::NewLine;[IO.File]::WriteAllText($Path,$text+[Environment]::NewLine,[Text.UTF8Encoding]::new($false))}
try{
  Initialize-Repo $repo;$base=Write-Commit $repo 'base.txt' 'base' 'base';Invoke-TestGit $repo @('checkout','-b','synthetic/feature')|Out-Null;$reviewed=Write-Commit $repo 'feature.txt' 'feature' 'feature patch'
  $branchArgs=@{Pr=900001;ReviewedHead=$reviewed;NewBase=$reviewed;SourcePassReceiptIdentity='ABSENT_REVIEW_REQUIRED';IntegrationLane='synthetic-branch-control';Worktree=$repo;HistoryPath=$history;NoPush=$true}
  $branchCli=@('-Pr','900001','-ReviewedHead',$reviewed,'-NewBase',$reviewed,'-SourcePassReceiptIdentity','ABSENT_REVIEW_REQUIRED','-IntegrationLane','synthetic-branch-control','-Worktree',$repo,'-HistoryPath',$history,'-NoPush')
  $attached=& $integration @branchArgs|ConvertFrom-Json -DateKind String
  Assert-True ($attached.status-ceq'REVIEW_REQUIRED') 'attached branch control did not complete'
  Invoke-TestGit $repo @('checkout','--detach')|Out-Null
  $detachedOutput=& pwsh -NoProfile -NonInteractive -File $integration @branchCli 2>&1;$detachedCode=$LASTEXITCODE
  Assert-True ($detachedCode-ne0-and(($detachedOutput-join"`n")-match 'rebase-integration: an attached own branch is required')) 'detached HEAD did not retain the attached-own-branch refusal'
  Invoke-TestGit $repo @('checkout','synthetic/feature')|Out-Null
  $injected=Join-Path $root 'rebase-integration-injected.ps1';$sourceText=[IO.File]::ReadAllText($integration);$needle='    return $result'+[Environment]::NewLine+'  } finally'
  Assert-True ([regex]::Matches($sourceText,[regex]::Escape($needle)).Count-eq1) 'branch capture injection point changed'
  $injection='    if (($Arguments -contains ''--show-current'' -or $Arguments -contains ''symbolic-ref'') -and -not $script:EmptyBranchInjected) { $script:EmptyBranchInjected=$true; $result.stdout='''' }'
  [IO.File]::WriteAllText($injected,$sourceText.Replace($needle,$injection+[Environment]::NewLine+$needle))
  $recovered=& pwsh -NoProfile -NonInteractive -File $injected @branchCli 2>&1;$recoveredCode=$LASTEXITCODE
  Assert-True ($recoveredCode-eq0-and(($recovered-join"`n")|ConvertFrom-Json -DateKind String).status-ceq'REVIEW_REQUIRED') 'attached zero-exit empty branch read was not recovered by a bounded re-read'
  $alwaysEmpty=Join-Path $root 'rebase-integration-always-empty.ps1'
  [IO.File]::WriteAllText($alwaysEmpty,$sourceText.Replace($needle,'    if ($Arguments -contains ''symbolic-ref'') { $result.stdout='''' }'+[Environment]::NewLine+$needle))
  $emptyOutput=& pwsh -NoProfile -NonInteractive -File $alwaysEmpty @branchCli 2>&1;$emptyCode=$LASTEXITCODE
  Assert-True ($emptyCode-ne0-and(($emptyOutput-join"`n")-match 'attached branch read returned empty at exit zero twice')) 'repeated zero-exit empty branch read was mistaken for detached HEAD'
  $singleLine=Join-Path $root 'rebase-integration-single-line-empty.ps1';$singleNeedle='    if ($RequireOutput -and $process.ExitCode -eq 0'
  Assert-True ([regex]::Matches($sourceText,[regex]::Escape($singleNeedle)).Count-eq1) 'single-line git output guard changed'
  [IO.File]::WriteAllText($singleLine,$sourceText.Replace($singleNeedle,'    if ($Arguments -contains ''--show-toplevel'') { $result.stdout='''' }'+[Environment]::NewLine+$singleNeedle))
  $singleOutput=& pwsh -NoProfile -NonInteractive -File $singleLine @branchCli 2>&1;$singleCode=$LASTEXITCODE
  Assert-True ($singleCode-ne0-and(($singleOutput-join"`n")-match 'git single-line read returned empty at exit zero')) 'zero-exit empty sibling single-line read was accepted'
  Write-Output 'PASS attached, detached, recovered empty, repeated empty, and sibling single-line read controls'

  $tagRepo=Join-Path $root 'unmistakably-synthetic-same-tag';Initialize-Repo $tagRepo
  $tagBase=Write-Commit $tagRepo 'base.txt' 'base' 'synthetic base';Invoke-TestGit $tagRepo @('checkout','-b','synthetic/ambiguous')|Out-Null
  $tagReviewed=Write-Commit $tagRepo 'feature.txt' 'feature' 'synthetic feature';Invoke-TestGit $tagRepo @('checkout','main')|Out-Null
  $tagNewBase=Write-Commit $tagRepo 'main.txt' 'advance' 'synthetic advance';Invoke-TestGit $tagRepo @('checkout','synthetic/ambiguous')|Out-Null
  Invoke-TestGit $tagRepo @('tag','synthetic/ambiguous',$tagReviewed)|Out-Null
  $tagMergeBase=Invoke-TestGit $tagRepo @('merge-base',$tagNewBase,$tagReviewed)
  Assert-True ($tagMergeBase-ceq$tagBase-and$tagNewBase-cne$tagReviewed) 'same-tag control did not require a real rebase'
  $tagOutput=@(& pwsh -NoProfile -NonInteractive -File $integration -Pr 900004 -ReviewedHead $tagReviewed -NewBase $tagNewBase -SourcePassReceiptIdentity ABSENT_REVIEW_REQUIRED -IntegrationLane synthetic-same-tag -Worktree $tagRepo -HistoryPath (Join-Path $root 'same-tag-history.jsonl') -NoPush 2>&1);$tagCode=$LASTEXITCODE
  $tagHead=Invoke-TestGit $tagRepo @('rev-parse','HEAD');$tagBranch=Invoke-TestGit $tagRepo @('branch','--show-current');$tagRef=Invoke-TestGit $tagRepo @('rev-parse','refs/heads/synthetic/ambiguous')
  Write-Output "PROOF same-named-tag exit=$tagCode headMoved=$($tagHead-cne$tagReviewed) branch=$tagBranch signal=$($tagOutput-join' ')"
  Assert-True ($tagCode-eq0-and(($tagOutput-join"`n")|ConvertFrom-Json -DateKind String).status-ceq'REVIEW_REQUIRED'-and$tagBranch-ceq'synthetic/ambiguous'-and$tagRef-ceq$tagHead-and$tagHead-cne$tagReviewed) 'same-named tag changed the branch identity during a real rebase'

  $remoteRepo=Join-Path $root 'unmistakably-synthetic-remote-symref';Initialize-Repo $remoteRepo
  $remoteHead=Write-Commit $remoteRepo 'base.txt' 'base' 'synthetic base';Invoke-TestGit $remoteRepo @('update-ref','refs/remotes/origin/synthetic',$remoteHead)|Out-Null
  Invoke-TestGit $remoteRepo @('symbolic-ref','HEAD','refs/remotes/origin/synthetic')|Out-Null
  $remoteOutput=@(& pwsh -NoProfile -NonInteractive -File $integration -Pr 900005 -ReviewedHead $remoteHead -NewBase $remoteHead -SourcePassReceiptIdentity ABSENT_REVIEW_REQUIRED -IntegrationLane synthetic-remote-symref -Worktree $remoteRepo -HistoryPath (Join-Path $root 'remote-history.jsonl') -NoPush 2>&1);$remoteCode=$LASTEXITCODE
  $remoteAfter=Invoke-TestGit $remoteRepo @('rev-parse','HEAD')
  Assert-True ($remoteCode-ne0-and(($remoteOutput-join"`n")-match 'rebase-integration: an attached own branch is required')-and$remoteAfter-ceq$remoteHead) 'non-branch HEAD symref was not refused before integration'
  Write-Output 'PASS same-named tag real rebase and non-branch HEAD symref refusal controls'
  & $logEvent -Log dispatch -Kind review-complete -Pr 900001 -ReviewedHead $reviewed -ReviewerAttempt synthetic-review -AuthorAttempt synthetic-author -ReviewContract review-contract/v2 -CompleteSweep -Outcome PASS -Model gpt-6.1-sol -AuthorModel gpt-6.1-sol -Blocking 0 -Candidates 0 -NonBlocking 0 -RepairOwner none -OutFile $history -NoBoard
  Import-Module (Join-Path $PSScriptRoot 'review-head-contract.psm1') -Force -DisableNameChecking
  $source=Reduce-ExactHeadReview -Pr 900001 -CurrentHead $reviewed -History (Read-ExactHeadReviewHistory -Path $history);Assert-True ($source.state-ceq'authorized') 'synthetic source PASS is not qualified'
  Invoke-TestGit $repo @('checkout','main')|Out-Null;$newBase=Write-Commit $repo 'main.txt' 'new base' 'advance main';Invoke-TestGit $repo @('checkout','synthetic/feature')|Out-Null
  $result=& $integration -Pr 900001 -ReviewedHead $reviewed -NewBase $newBase -SourcePassReceiptIdentity $source.latest.receiptIdentity -SourcePassReviewedHead $reviewed -IntegrationLane synthetic-integration-one -Worktree $repo -HistoryPath $history -NoPush|ConvertFrom-Json -DateKind String
  $newHead=Invoke-TestGit $repo @('rev-parse','HEAD');$attached=Invoke-TestGit $repo @('branch','--show-current');$localRef=Invoke-TestGit $repo @('rev-parse','refs/heads/synthetic/feature')
  $reduction=Reduce-ExactHeadReview -Pr 900001 -CurrentHead $newHead -History (Read-ExactHeadReviewHistory -Path $history);$row=(Get-Content $history|Select-Object -Last 1|ConvertFrom-Json -DateKind String)
  Assert-True ($result.status-ceq'CONTINUATION_LOGGED'-and$attached-ceq'synthetic/feature'-and$localRef-ceq$newHead) 'successful rebase detached the worktree or left the local branch ref stale'
  Assert-True ($reduction.state-ceq'authorized'-and$reduction.reason-ceq'QUALIFIED_REBASE_ONLY_CONTINUATION'-and$reduction.latest.continuationHops-eq1) 'single-hop continuation did not authorize the new head'
  Assert-True ($row.predecessorHead-ceq$reviewed-and$row.patchPairs.Count-eq1-and$row.patchPairs[0].reviewedPatchId-ceq$row.patchPairs[0].newPatchId-and$row.conflictResolution-eq$false) 'single-hop evidence did not bind predecessor and stable patches'

  Invoke-TestGit $repo @('checkout','main')|Out-Null;$secondBase=Write-Commit $repo 'main-two.txt' 'newer base' 'advance main twice';Invoke-TestGit $repo @('checkout','synthetic/feature')|Out-Null
  $second=& $integration -Pr 900001 -ReviewedHead $newHead -NewBase $secondBase -SourcePassReceiptIdentity $source.latest.receiptIdentity -SourcePassReviewedHead $reviewed -IntegrationLane synthetic-integration-two -Worktree $repo -HistoryPath $history -NoPush|ConvertFrom-Json -DateKind String
  $secondHead=Invoke-TestGit $repo @('rev-parse','HEAD');$secondReduction=Reduce-ExactHeadReview -Pr 900001 -CurrentHead $secondHead -History (Read-ExactHeadReviewHistory -Path $history)
  Assert-True ($second.status-ceq'CONTINUATION_LOGGED'-and$secondReduction.state-ceq'authorized'-and$secondReduction.latest.continuationHops-eq2-and$secondReduction.latest.reviewedHead-ceq$reviewed-and$secondReduction.latest.predecessorHead-ceq$newHead) 'two-hop continuation did not preserve immutable original PASS plus immediate predecessor'
  $rows=@(Get-Content $history|ForEach-Object{$_|ConvertFrom-Json -DateKind String});$continuations=@($rows|Where-Object{$_.continuationSchema-ceq'rebase-only-continuation/v1'})
  $wrongRows=@($rows|ForEach-Object{$_|ConvertTo-Json -Compress -Depth 10|ConvertFrom-Json -DateKind String});$wrongRows[-1].predecessorHead='d'*40;$wrongPath=Join-Path $root 'wrong-predecessor.jsonl';Write-History $wrongPath $wrongRows;$wrong=Reduce-ExactHeadReview -Pr 900001 -CurrentHead $secondHead -History (Read-ExactHeadReviewHistory -Path $wrongPath);Assert-True ($wrong.state-ceq'unknown'-and$wrong.reason-ceq'CONTINUATION_PREDECESSOR_MISSING') 'wrong immediate predecessor was accepted'
  $forkRows=@($rows|ForEach-Object{$_|ConvertTo-Json -Compress -Depth 10|ConvertFrom-Json -DateKind String});$fork=$forkRows[-1]|ConvertTo-Json -Compress -Depth 10|ConvertFrom-Json -DateKind String;$fork.ts=[datetimeoffset]::UtcNow.ToString('o');$fork.predecessorHead=$reviewed;$fork.newHead='e'*40;$fork.integrationLane='synthetic-fork';$forkRows+=@($fork);$forkPath=Join-Path $root 'fork.jsonl';Write-History $forkPath $forkRows;$forked=Reduce-ExactHeadReview -Pr 900001 -CurrentHead $secondHead -History (Read-ExactHeadReviewHistory -Path $forkPath);Assert-True ($forked.state-ceq'unknown'-and$forked.reason-ceq'CONTINUATION_CHAIN_AMBIGUOUS') 'forked continuation chain was accepted'
  $patchRows=@($rows|ForEach-Object{$_|ConvertTo-Json -Compress -Depth 10|ConvertFrom-Json -DateKind String});$patchRows[-1].patchPairs[0].reviewedPatchId='9'*40;$patchRows[-1].patchPairs[0].newPatchId='9'*40;$patchPath=Join-Path $root 'changed-chain-patch.jsonl';Write-History $patchPath $patchRows;$patchChanged=Reduce-ExactHeadReview -Pr 900001 -CurrentHead $secondHead -History (Read-ExactHeadReviewHistory -Path $patchPath);Assert-True ($patchChanged.state-ceq'unknown'-and$patchChanged.reason-ceq'CONTINUATION_CHAIN_PATCH_CHANGED') 'changed patch across linked hops was accepted'

  $noPassRepo=Join-Path $root 'unmistakably-synthetic-no-pass';Initialize-Repo $noPassRepo;$noPassBase=Write-Commit $noPassRepo 'base.txt' 'base' 'base';Invoke-TestGit $noPassRepo @('checkout','-b','synthetic/no-pass')|Out-Null;$noPassHead=Write-Commit $noPassRepo 'feature.txt' 'feature' 'feature';Invoke-TestGit $noPassRepo @('checkout','main')|Out-Null;$noPassNewBase=Write-Commit $noPassRepo 'main.txt' 'advance' 'advance';Invoke-TestGit $noPassRepo @('checkout','synthetic/no-pass')|Out-Null;$noPassHistory=Join-Path $root 'no-pass-history.jsonl'
  $noPass=& $integration -Pr 900002 -ReviewedHead $noPassHead -NewBase $noPassNewBase -SourcePassReceiptIdentity ABSENT_REVIEW_REQUIRED -IntegrationLane synthetic-no-pass-integration -Worktree $noPassRepo -HistoryPath $noPassHistory -NoPush|ConvertFrom-Json -DateKind String;$noPassResultHead=Invoke-TestGit $noPassRepo @('rev-parse','HEAD')
  Assert-True ($noPass.status-ceq'REVIEW_REQUIRED'-and$noPass.continuationAuthority-eq$false-and$noPass.review-ceq'NORMAL_EXACT_NEW_HEAD_REQUIRED'-and$noPassResultHead-cne$noPassHead-and-not(Test-Path $noPassHistory)-and(Invoke-TestGit $noPassRepo @('branch','--show-current'))-ceq'synthetic/no-pass') 'absent PASS did not rebase attached own branch into closed REVIEW_REQUIRED without continuation authority'

  $conflictRepo=Join-Path $root 'unmistakably-synthetic-conflict';Initialize-Repo $conflictRepo;$conflictBase=Write-Commit $conflictRepo 'same.txt' 'base' 'base';Invoke-TestGit $conflictRepo @('checkout','-b','synthetic/conflict')|Out-Null;$conflictHead=Write-Commit $conflictRepo 'same.txt' 'feature' 'feature';Invoke-TestGit $conflictRepo @('checkout','main')|Out-Null;$conflictNewBase=Write-Commit $conflictRepo 'same.txt' 'main' 'main';Invoke-TestGit $conflictRepo @('checkout','synthetic/conflict')|Out-Null
  $conflictOutput=@(& pwsh -NoProfile -NonInteractive -File $integration -Pr 900003 -ReviewedHead $conflictHead -NewBase $conflictNewBase -SourcePassReceiptIdentity ABSENT_REVIEW_REQUIRED -IntegrationLane synthetic-conflict-integration -Worktree $conflictRepo -HistoryPath (Join-Path $root 'conflict-history.jsonl') -NoPush);$conflictCode=$LASTEXITCODE;$conflict=($conflictOutput-join"`n")|ConvertFrom-Json -DateKind String
  Assert-True ($conflictCode-eq2-and$conflict.status-ceq'DELTA_REQUIRED'-and$conflict.reason-ceq'REBASE_CONFLICT'-and-not(Test-Path (Join-Path $root 'conflict-history.jsonl'))) 'conflict fabricated continuation or REVIEW_REQUIRED authority'
  Write-Output 'PASS rebase attached own-branch preservation, absent-PASS REVIEW_REQUIRED, unique acyclic two-hop continuation, immutable source PASS, immediate predecessor, stable patch chain, and wrong/fork/patch/conflict controls'
}finally{
  $resolved=[IO.Path]::GetFullPath($root);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/');if((Split-Path -Parent $resolved).TrimEnd('\','/')-ne$temp-or(Split-Path -Leaf $resolved)-notlike'rebase-integration-test-*'){throw "unsafe test cleanup: $resolved"};Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
}

. (Join-Path $PSScriptRoot 'interrupted-integration-test-support.ps1')
Test-7963ResumeCarrier 'rebase'
} finally {
  Exit-RoutingDataTestScope $routingTestScope
}
