$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'routing-data-test-support.ps1')
$routingTestScope=Enter-RoutingDataTestScope
$queueScript = Join-Path $PSScriptRoot 'review-queue-health.ps1'
$fixture = Join-Path $PSScriptRoot 'review-queue-health.fixture.json'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('review-queue-health-test-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null

function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "ASSERTION FAILED: $Message"}}
function Add-JsonRow([string]$Path,$Row){[IO.File]::AppendAllText($Path,($Row|ConvertTo-Json -Compress -Depth 10)+"`n",[Text.UTF8Encoding]::new($false))}

function Add-ExactReceipt([string]$Path,[int]$Pr,[string]$Head,[string]$Label){
  Add-JsonRow $Path ([ordered]@{ts='2026-08-01T12:00:00.000Z';kind='review-complete';pr=$Pr;receiptSchema='exact-head-review-receipt/v1';reviewedHead=$Head;reviewerAttempt="$Label-reviewer";authorAttempt="$Label-author";reviewContract='review-contract/v2';completeSweep=$true;outcome='PASS';model='gpt-5.6-sol';authorModel='gpt-5.6-sol';findingIds=[object[]]@();findings=[ordered]@{blocking=0;candidates=0;nonBlocking=0}})
}

function Add-StrictPair([string]$Path,[string]$Authority,[string]$Outcome,[string]$Label){
  $common=[ordered]@{issue=6400;controllerHead=('d'*40);authorAttempt="$Label-author";reviewerAttempt="$Label-reviewer";reviewAuthority=$Authority;lane="$Label-lane";transcript="$Label.jsonl";reviewerModel='gpt-5.6-sol';authorModel='gpt-5.6-sol';effort='high';row='7';placement='measured';harness='codex'}
  $dispatch=[ordered]@{ts='2026-08-01T12:00:00.000Z';kind='dispatch';controllerReviewSchema='controller-review-dispatch/v1'}
  $receipt=[ordered]@{ts='2026-08-01T12:00:00.001Z';kind='review-complete';controllerReviewSchema='controller-review-receipt/v1'}
  foreach($key in $common.Keys){$dispatch[$key]=$common[$key];$receipt[$key]=$common[$key]}
  $blocking=if($Outcome-in@('BLOCK_FIXABLE','BLOCK_REPLAN')){1}else{0}
  $receipt.reviewContract='review-contract/v2';$receipt.completeSweep=$true;$receipt.outcome=$Outcome
  if($blocking){$receipt.findingIds=[object[]]@("QUEUE_$($Label.ToUpperInvariant())")}else{$receipt.findingIds=[object[]]@()}
  $receipt.findings=[ordered]@{blocking=$blocking;candidates=0;nonBlocking=0}
  Add-JsonRow $Path $dispatch;Add-JsonRow $Path $receipt
}

function New-SyntheticPlanningReceipt([string]$Label){
  [ordered]@{
    ts='2026-09-09T12:00:00.000Z';kind='review-complete';issue=999001
    lane="synthetic-$Label-lane";laneRole='planning';harness='codex'
    model='gpt-5.6-sol';authorModel='gpt-5.6-sol';effort='high';authorEffort='high'
    row='4';placement='measured';transcript="synthetic-$Label.jsonl";outcome='BLOCK_REPLAN'
    planningContract='planning-repair/v1';planningRound=1;completeSweep=$true;reviewedHead=('f'*40)
    reviewerAttempt="synthetic-$Label-reviewer";authorAttempt="synthetic-$Label-author"
    findingIds=[object[]]@('SYNTHETIC_F1');nonBlockingIds=[object[]]@();repairOwner='author'
    disposition='REPLACED';note='Synthetic planning receipt control.'
  }
}

function Invoke-SyntheticPlanningControl($PlanningRow,[string]$Label){
  $path=Join-Path $testRoot "$Label.jsonl"
  Add-ExactReceipt $path 6254 ('a'*40) "synthetic-$Label-pr-6254"
  Add-ExactReceipt $path 6255 ('b'*40) "synthetic-$Label-pr-6255"
  Add-JsonRow $path $PlanningRow
  & $queueScript -HistoryPath $path -AuthorityFixture $fixture -AuthorityScenario 'mixed-ready-and-enqueued' |
    ConvertFrom-Json -Depth 30
}

try{
  $history=Join-Path $testRoot 'dispatch.jsonl'
  Add-ExactReceipt $history 6254 ('a'*40) 'pr-6254'
  Add-ExactReceipt $history 6255 ('b'*40) 'pr-6255'
  Add-ExactReceipt $history 0 ('c'*40) 'precursor-zero-one'
  Add-ExactReceipt $history 0 ('e'*40) 'precursor-zero-two'
  Add-StrictPair $history governing PASS 'queue-governing'
  Add-StrictPair $history shadow BLOCK_FIXABLE 'queue-shadow'
  Add-StrictPair $history advisory PASS 'queue-advisory'
  # Verbatim canonical dispatch-log line 16343. Its reviewedHead is planning
  # source provenance and does not claim ordinary PR exact-head authority.
  $livePlanningLine16343='{"ts":"2026-09-09T10:49:03.2980812+00:00","kind":"review-complete","issue":7735,"lane":"20260909-7735-glossary-conformance-review-r1","laneRole":"planning","harness":"codex","model":"gpt-5.6-sol","authorModel":"claude-opus-5","effort":"high","authorEffort":"high","row":"8","placement":"measured","transcript":"7735-sol-high-glossary-conformance-planning-review-r1.jsonl","outcome":"BLOCK_REPLAN","planningContract":"planning-repair/v1","planningRound":1,"completeSweep":true,"reviewedHead":"6feb1454cecb4a73a90845103a9a0de2a336eaad","reviewerAttempt":"7735-sol-high-glossary-conformance-planning-review-r1","authorAttempt":"7735-opus5-high-glossary-conformance-plan-r1","findingIds":["F1","F2","F3","F4","F5"],"nonBlockingIds":["N1"],"repairOwner":"author","disposition":"REPLACED","note":"Qualified terminal planning review receipt."}'
  [IO.File]::AppendAllText($history,$livePlanningLine16343+"`n",[Text.UTF8Encoding]::new($false))
  $result=& $queueScript -HistoryPath $history -AuthorityFixture $fixture -AuthorityScenario 'mixed-ready-and-enqueued'|ConvertFrom-Json -Depth 30
  Assert-True ($result.status-ceq'healthy'-and$result.deficits.Count-eq0) 'controller rows must not change ordinary exact-head queue authorization'
  Assert-True ($result.coverage.exactHeadReceipts-eq2-and$result.coverage.planningReceipts-eq1-and
    $result.coverage.controllerReceipts-eq3-and$result.coverage.quarantinedNonPrReceipts-eq2-and
    $result.coverage.malformedExactHeadReceipts-eq0-and$result.coverage.legacyReceipts-eq0) `
    'ordinary, planning, quarantined non-PR, malformed, legacy, and controller receipt inventories remain separately conserved'
  Assert-True ($result.authority.controllerReductions.Count-eq1) 'one controller candidate identity must produce one shared reduction'
  $reduction=$result.authority.controllerReductions[0]
  Assert-True ($reduction.state-ceq'authorized'-and$reduction.reason-ceq'GOVERNING_PASS') 'shadow block cannot override the governing PASS'
  Assert-True ($reduction.census.governing.pass-eq1-and$reduction.census.shadow.blockFixable-eq1-and$reduction.census.advisory.pass-eq1) 'queue health preserves all three authority outcomes'
  Assert-True ($reduction.blockingHeads.Count-eq0) 'a non-governing block cannot enter the governing blocking-head set'

  $mixedPr=New-SyntheticPlanningReceipt 'mixed-pr'
  $mixedPr.pr=6254
  $mixedPrResult=Invoke-SyntheticPlanningControl $mixedPr 'mixed-pr'
  Assert-True ($mixedPrResult.coverage.exactHeadReceipts-eq2-and
    $mixedPrResult.coverage.planningReceipts-eq0-and
    $mixedPrResult.coverage.malformedExactHeadReceipts-eq1) `
    'synthetic planning plus PR authority remains malformed ordinary authority'

  $mixedOrdinaryContract=New-SyntheticPlanningReceipt 'mixed-ordinary-contract'
  $mixedOrdinaryContract.reviewContract='review-contract/v2'
  $mixedOrdinaryContractResult=Invoke-SyntheticPlanningControl $mixedOrdinaryContract 'mixed-ordinary-contract'
  Assert-True ($mixedOrdinaryContractResult.coverage.exactHeadReceipts-eq2-and
    $mixedOrdinaryContractResult.coverage.planningReceipts-eq0-and
    $mixedOrdinaryContractResult.coverage.malformedExactHeadReceipts-eq1) `
    'synthetic planning plus ordinary review contract remains malformed ordinary authority'

  $missingPlanningContract=New-SyntheticPlanningReceipt 'missing-planning-contract'
  $missingPlanningContract.Remove('planningContract')
  $missingPlanningContractResult=Invoke-SyntheticPlanningControl $missingPlanningContract 'missing-planning-contract'
  Assert-True ($missingPlanningContractResult.coverage.exactHeadReceipts-eq2-and
    $missingPlanningContractResult.coverage.planningReceipts-eq0-and
    $missingPlanningContractResult.coverage.malformedExactHeadReceipts-eq1) `
    'synthetic laneRole planning without planningContract remains malformed ordinary authority'

  $missingLaneRole=New-SyntheticPlanningReceipt 'missing-lane-role'
  $missingLaneRole.Remove('laneRole')
  $missingLaneRoleResult=Invoke-SyntheticPlanningControl $missingLaneRole 'missing-lane-role'
  Assert-True ($missingLaneRoleResult.coverage.exactHeadReceipts-eq2-and
    $missingLaneRoleResult.coverage.planningReceipts-eq0-and
    $missingLaneRoleResult.coverage.malformedExactHeadReceipts-eq1) `
    'synthetic planningContract without laneRole planning remains malformed ordinary authority'
  Write-Output 'PASS review-queue-health conserves controller authority without changing ordinary PR health'
}finally{
  $resolved=[IO.Path]::GetFullPath($testRoot)
  if((Split-Path -Parent $resolved).TrimEnd('\','/') -cne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/') -or
      (Split-Path -Leaf $resolved) -notlike 'review-queue-health-test-*'){throw 'unsafe queue health cleanup target'}
  if([IO.Directory]::Exists($resolved)){Remove-Item -LiteralPath $resolved -Recurse -Force}
  Exit-RoutingDataTestScope $routingTestScope
}
