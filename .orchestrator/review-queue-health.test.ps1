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

function Assert-QueueJsonEqual($Expected,$Actual,[string]$Label){
  $expectedJson=ConvertTo-Json -InputObject $Expected -Compress -Depth 100
  $actualJson=ConvertTo-Json -InputObject $Actual -Compress -Depth 100
  Assert-True ($expectedJson -ceq $actualJson) "$Label whole JSON equality (no removed or normalized leaves): expected=$expectedJson actual=$actualJson"
}

function Get-QueueInputIdentity([string]$Path){
  $file=Get-Item -LiteralPath $Path
  [ordered]@{length=$file.Length;lastWriteUtcTicks=$file.LastWriteTimeUtc.Ticks;sha256=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}
}

function Invoke-PreservedQueue([string]$Path,[string]$Label){
  $before=Get-QueueInputIdentity $Path
  # Exercise the actual CLI's defaults, not an overridden or modelled fold.
  $value=& $queueScript -HistoryPath $Path -AuthorityFixture $fixture -AuthorityScenario 'mixed-ready-and-enqueued' |
    ConvertFrom-Json -Depth 100
  Assert-QueueJsonEqual $before (Get-QueueInputIdentity $Path) "$Label input hash/length/lastwrite preserved"
  Write-Output "QUEUE $Label bytes=$($before.length) sha256=$($before.sha256) result=$($value|ConvertTo-Json -Compress -Depth 100)" | Out-Host
  return $value
}

function Assert-QueueCandidates($Value,[int]$MissingPr=0,[switch]$Blocked){
  $expected=@(
    [ordered]@{pr=6254;head=('a'*40);enqueued=$false;state='authorized';reason='LATEST_EXACT_HEAD_PASS'},
    [ordered]@{pr=6255;head=('b'*40);enqueued=$true;state='authorized';reason='LATEST_EXACT_HEAD_PASS'}
  )
  if($MissingPr){
    $index=if($MissingPr -eq 6254){0}else{1}
    $expected[$index].state='unknown';$expected[$index].reason='NO_REVIEW_HISTORY'
  }
  if($Blocked){$expected[1].state='blocked';$expected[1].reason='LATEST_EXACT_HEAD_BLOCK_FIXABLE'}
  Assert-QueueJsonEqual $expected $Value.candidates 'exact ready/enqueued candidates, excluding draft'
  $expectedDeficits=@($expected|Where-Object {$_.state -cne 'authorized'})
  Assert-QueueJsonEqual $expectedDeficits $Value.deficits 'exact PR deficits'
  $status=if($expectedDeficits.Count){'debt'}else{'healthy'}
  $reason=if($expectedDeficits.Count){'READY_OR_ENQUEUED_PR_LACKS_CURRENT_RECEIPT'}else{'ALL_READY_AND_ENQUEUED_PRS_AUTHORIZED'}
  Assert-True ($Value.status -ceq $status -and $Value.reason -ceq $reason) 'exact queue status and reason'
}

function Assert-QueueCoverage($Value,[int]$Exact,[int]$Controls){
  Assert-QueueJsonEqual ([ordered]@{
    mode='exact-head';exactHeadReceipts=$Exact;planningReceipts=$Controls
    malformedExactHeadReceipts=0;quarantinedNonPrReceipts=(2*$Controls)
    legacyReceipts=0;controllerReceipts=(3*$Controls);retroactiveAuthorization=0
  }) $Value.coverage 'complete receipt coverage map'
  Assert-True ($Value.authority.queueComplete -eq $true -and $Value.authority.historyComplete -eq $true) 'complete fixture and default history authority'
  Assert-True ($Value.authority.controllerReductions.Count -eq $Controls) 'exact controller reduction count'
  if($Controls){
    $controller=$Value.authority.controllerReductions[0]
    Assert-True ($controller.state -ceq 'authorized' -and $controller.reason -ceq 'GOVERNING_PASS' -and
      $controller.selected.candidateRows -eq 6 -and $controller.blockingHeads.Count -eq 0) 'controller authority remains independent of ordinary queue debt'
    Assert-QueueJsonEqual ([ordered]@{
      governing=[ordered]@{pass=1;blockFixable=0;blockReplan=0;inFlight=0}
      shadow=[ordered]@{pass=0;blockFixable=1;blockReplan=0;inFlight=0}
      advisory=[ordered]@{pass=1;blockFixable=0;blockReplan=0;inFlight=0}
      legacy=0;duplicateReplay=0;invalidConflict=0
    }) $controller.census 'complete controller census'
    # Controller rows precede padding in both files, so even physical audit
    # leaves and the derived identity must match, without any projection.
    Assert-QueueJsonEqual @(4,5,6,7,8,9) @($controller.selected.rows.physicalLine|Sort-Object) 'controller physical selected-row positions'
    Assert-QueueJsonEqual @($Exact+9) $controller.audit.rows 'controller physical audit nonblank row census'
  }
}

function Invoke-QueuePhysicalHistoryQualification {
  $small=Join-Path $testRoot 'synthetic-queue-small.jsonl'
  $large=Join-Path $testRoot 'synthetic-queue-physical.jsonl'
  $late=Join-Path $testRoot 'synthetic-queue-late.jsonl'
  $utf8=[Text.UTF8Encoding]::new($false)
  Add-ExactReceipt $small 6254 ('a'*40) 'synthetic-queue-early-6254'
  Add-ExactReceipt $small 0 ('c'*40) 'synthetic-queue-non-pr-one'
  Add-ExactReceipt $small 0 ('e'*40) 'synthetic-queue-non-pr-two'
  Add-StrictPair $small governing PASS 'synthetic-queue-governing'
  Add-StrictPair $small shadow BLOCK_FIXABLE 'synthetic-queue-shadow'
  Add-StrictPair $small advisory PASS 'synthetic-queue-advisory'
  Add-JsonRow $small (New-SyntheticPlanningReceipt 'queue-physical')
  $earlyBytes=[IO.File]::ReadAllBytes($small)
  $earlyOracle=Invoke-PreservedQueue $small 'small-early-only'
  Assert-QueueCandidates $earlyOracle -MissingPr 6255
  Assert-QueueCoverage $earlyOracle 1 1

  [IO.File]::WriteAllBytes($large,$earlyBytes)
  # Physical LF/byte cliffs only: 50001 whitespace rows, not rich events.
  $paddingRows=50001
  $paddingLine=(' '*671)+"`n"
  $writer=[IO.StreamWriter]::new($large,$true,$utf8)
  try{for($i=0;$i -lt $paddingRows;$i++){$writer.Write($paddingLine)}}finally{$writer.Dispose()}
  Assert-True ((Get-Item -LiteralPath $large).Length -gt 32MB) 'late distinct PR receipt starts after the 32MiB cliff'
  Add-ExactReceipt $late 6255 ('b'*40) 'synthetic-queue-late-6255'
  $lateText=[IO.File]::ReadAllText($late)
  [IO.File]::AppendAllText($small,$lateText,$utf8)
  [IO.File]::AppendAllText($large,$lateText,$utf8)
  $oracle=Invoke-PreservedQueue $small 'small-complete'
  Assert-QueueCandidates $oracle
  Assert-QueueCoverage $oracle 2 1
  $fullIdentity=Get-QueueInputIdentity $large
  $fullBytes=[IO.File]::ReadAllBytes($large)
  $fullLastWrite=[IO.File]::GetLastWriteTimeUtc($large)
  $lines=[IO.File]::ReadAllLines($large)
  Assert-True ($lines.Length -eq 50012 -and $fullIdentity.length -gt 32MB -and
    $fullBytes[$fullBytes.Length-1] -eq 10) 'full fixture exceeds both physical cliffs and ends in LF'
  $actual=Invoke-PreservedQueue $large 'full-complete'
  Assert-QueueJsonEqual $oracle $actual 'small versus full complete report including controller identities'

  try{
    # Materialize the actual last 50000 physical lines in the same input path.
    $suffix=[string]::Join("`n",$lines,$lines.Length-50000,50000)+"`n"
    [IO.File]::WriteAllText($large,$suffix,$utf8)
    Assert-True ([IO.File]::ReadAllLines($large).Length -eq 50000) 'actual physical suffix has exactly 50000 LF rows'
    $suffixOracle=Invoke-PreservedQueue $late 'small-late-only'
    Assert-QueueCandidates $suffixOracle -MissingPr 6254
    Assert-QueueCoverage $suffixOracle 1 0
    $suffixResult=Invoke-PreservedQueue $large 'actual-last-50000'
    Assert-QueueJsonEqual $suffixOracle $suffixResult 'suffix loses exactly the early PR and control inventories'
    Assert-True (($suffixResult|ConvertTo-Json -Compress -Depth 100) -cne ($oracle|ConvertTo-Json -Compress -Depth 100)) 'suffix cannot substitute for complete history'
  }finally{
    [IO.File]::WriteAllBytes($large,$fullBytes)
    [IO.File]::SetLastWriteTimeUtc($large,$fullLastWrite)
  }
  Assert-QueueJsonEqual $fullIdentity (Get-QueueInputIdentity $large) 'suffix restoration exact hash/length/lastwrite'
  Assert-QueueJsonEqual $oracle (Invoke-PreservedQueue $large 'restored-after-suffix') 'suffix restoration whole report'

  try{
    # Maximal LF-complete prefix no larger than 32MiB, not a reader override.
    $prefixLength=1+[Array]::LastIndexOf[byte]($fullBytes,10,([int](32MB)-1),[int](32MB))
    Assert-True ($prefixLength -le 32MB -and $prefixLength -gt $earlyBytes.Length -and
      $prefixLength+672 -gt 32MB -and $fullBytes[$prefixLength-1] -eq 10) 'prefix is maximal line-complete within 32MiB'
    $stream=[IO.File]::Create($large)
    try{$stream.Write($fullBytes,0,$prefixLength)}finally{$stream.Dispose()}
    $prefixResult=Invoke-PreservedQueue $large 'actual-line-complete-32MiB-prefix'
    Assert-QueueCandidates $prefixResult -MissingPr 6255
    Assert-QueueCoverage $prefixResult 1 1
    Assert-QueueJsonEqual $earlyOracle $prefixResult 'prefix loses exactly late distinct PR terminal authority'
  }finally{
    [IO.File]::WriteAllBytes($large,$fullBytes)
    [IO.File]::SetLastWriteTimeUtc($large,$fullLastWrite)
  }
  Assert-QueueJsonEqual $fullIdentity (Get-QueueInputIdentity $large) 'prefix restoration exact hash/length/lastwrite'
  Assert-QueueJsonEqual $oracle (Invoke-PreservedQueue $large 'restored-after-prefix') 'prefix restoration whole report'

  # Build a valid, later ordinary terminal from the existing receipt builder.
  $terminal=$lateText|ConvertFrom-Json -DateKind String
  $terminal.ts='2026-08-02T12:00:00.000Z'
  $terminal.reviewerAttempt='synthetic-queue-appended-reviewer'
  $terminal.authorAttempt='synthetic-queue-appended-author'
  $terminal.outcome='BLOCK_FIXABLE';$terminal.findingIds=[object[]]@('SYNTHETIC_QUEUE_LATE_BLOCK')
  $terminal.findings.blocking=1
  $smallBeforeAppend=Get-QueueInputIdentity $small
  Add-JsonRow $small $terminal
  Add-JsonRow $large $terminal
  $appendedIdentity=Get-QueueInputIdentity $large
  Assert-True ($appendedIdentity.length-$fullIdentity.length -eq
    (Get-Item -LiteralPath $small).Length-$smallBeforeAppend.length) 'small and physical histories append identical terminal bytes'
  $appendedBytes=[IO.File]::ReadAllBytes($large)
  $hasher=[Security.Cryptography.SHA256]::Create()
  try{$prefixHash=[Convert]::ToHexString($hasher.ComputeHash($appendedBytes,0,$fullBytes.Length))}finally{$hasher.Dispose()}
  Assert-True ($prefixHash -ceq $fullIdentity.sha256 -and $appendedIdentity.length -gt $fullIdentity.length) 'append preserves every preexisting byte'
  $appendedOracle=Invoke-PreservedQueue $small 'small-appended-terminal'
  Assert-QueueCandidates $appendedOracle -Blocked
  Assert-QueueCoverage $appendedOracle 3 1
  $appendedActual=Invoke-PreservedQueue $large 'full-appended-terminal'
  Assert-QueueJsonEqual $appendedOracle $appendedActual 'appended whole-result oracle, including exact blocked deficit'
  Assert-True (($appendedActual|ConvertTo-Json -Compress -Depth 100) -cne ($actual|ConvertTo-Json -Compress -Depth 100)) 'late terminal changes actual queue semantics'
  Assert-QueueJsonEqual $appendedOracle (Invoke-PreservedQueue $small 'small-appended-replay') 'small replay whole result'
  Assert-QueueJsonEqual $appendedActual (Invoke-PreservedQueue $large 'full-appended-replay') 'full replay whole result'
  Assert-QueueJsonEqual $appendedIdentity (Get-QueueInputIdentity $large) 'appended source preserved through all reads'
  Write-Output "PASS bounded ordinary queue qualification physicalRows=$($lines.Length) bytes=$($fullIdentity.length) paddingRows=$paddingRows prefixBytes=$prefixLength; whole JSON, suffix/prefix deficits, restoration, append and replay; NOT rich-event or bounded-memory qualification"
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
  Invoke-QueuePhysicalHistoryQualification
  Write-Output 'PASS review-queue-health conserves controller authority without changing ordinary PR health'
}finally{
  $resolved=[IO.Path]::GetFullPath($testRoot)
  if((Split-Path -Parent $resolved).TrimEnd('\','/') -cne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/') -or
      (Split-Path -Leaf $resolved) -notlike 'review-queue-health-test-*'){throw 'unsafe queue health cleanup target'}
  if([IO.Directory]::Exists($resolved)){Remove-Item -LiteralPath $resolved -Recurse -Force}
  Exit-RoutingDataTestScope $routingTestScope
}
