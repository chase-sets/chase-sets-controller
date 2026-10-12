[CmdletBinding()]
param([string]$HistorySnapshot, [string]$BaselineModule, [string]$EvidenceRoot)
$ErrorActionPreference = 'Stop'
$candidate=Import-Module (Join-Path $PSScriptRoot 'review-head-contract.psm1') -Force -PassThru -DisableNameChecking
$history = [pscustomobject]@{ complete=$true; rows=@(
  [pscustomobject]@{value=[pscustomobject]@{kind='note';issue=8468}},
  [pscustomobject]@{value=[pscustomobject]@{controllerReviewSchema='unsupported';issue=8468;controllerHead=('a'*40)}}
); audit=@{rows=2;malformedRows=0}; reason='HISTORY_COMPLETE' }
$rows = @(Get-ControllerReviewClassifiedHistory -History $history)
if ($rows.Count -ne 1 -or $rows[0].classification.valid -or -not $rows[0].classification.strict) {
  throw 'ASSERTION FAILED: selective classification must preserve malformed strict rows'
}
Write-Output 'PASS selective controller classification retains malformed claims'

$head='a'*40
$tuple=[ordered]@{issue=8468;controllerHead=$head;authorAttempt='synthetic-author';reviewerAttempt='synthetic-reviewer';reviewAuthority='governing';lane='synthetic-lane';transcript='synthetic.jsonl';reviewerModel='gpt-6.1-sol';authorModel='gpt-6-astra';effort='high';row='11';placement='provisional';harness='codex'}
$dispatch=[ordered]@{ts='2026-10-01T00:00:00.000Z';kind='dispatch';controllerReviewSchema='controller-review-dispatch/v1'}
$receipt=[ordered]@{ts='2026-10-01T00:00:01.000Z';kind='review-complete';controllerReviewSchema='controller-review-receipt/v1'}
foreach($key in $tuple.Keys){$dispatch[$key]=$tuple[$key];$receipt[$key]=$tuple[$key]}
$receipt.reviewContract='review-contract/v2';$receipt.completeSweep=$true;$receipt.outcome='PASS';$receipt.findingIds=@();$receipt.findings=@{blocking=0;candidates=0;nonBlocking=0}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('controller-scaling-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
  $path=Join-Path $temp 'history.jsonl'
  $rawDispatch=($dispatch|ConvertTo-Json -Compress).Replace('controllerReviewSchema','controller\u0052eviewSchema')
  $rawReceipt=$receipt|ConvertTo-Json -Compress -Depth 20
  [IO.File]::WriteAllLines($path,@($rawDispatch,$rawReceipt),[Text.UTF8Encoding]::new($false))
  $complete=Read-ExactHeadReviewHistory $path
  $positive=Reduce-ControllerReleaseReview -Issue 8468 -ControllerHead $head -Mode strict-v1 -History $complete
  if($positive.state-cne'authorized'){throw "ASSERTION FAILED: exact host-dispatched eligible review not accepted: $($positive.reason)"}
  $mutant=$complete.PSObject.Copy();$mutant.rows=@($complete.rows[0])
  $dropped=Reduce-ControllerReleaseReview -Issue 8468 -ControllerHead $head -Mode strict-v1 -History $mutant
  if(($positive|ConvertTo-Json -Compress -Depth 100)-ceq($dropped|ConvertTo-Json -Compress -Depth 100)-or$dropped.state-cne'in-flight'){
    throw 'MUTANT SURVIVED: dropped relevant terminal'
  }
  # Adapter failure and an unlaunched native fallback are evidence only, not a
  # causal independent review. No model executable is run by this fixture.
  [IO.File]::WriteAllLines($path,@('{"kind":"lane-blocked","note":"unsupported_encrypted_delegation; attempted native-CLI fallback; PENDING_HOST_REVIEW"}',$rawReceipt),[Text.UTF8Encoding]::new($false))
  $bypass=Reduce-ControllerReleaseReview -Issue 8468 -ControllerHead $head -Mode strict-v1 -History (Read-ExactHeadReviewHistory $path)
  if($bypass.state-ceq'authorized'-or$bypass.reason-cne'STRICT_PAIR_CONFLICT'){throw 'ASSERTION FAILED: bypass supplied a semantic verdict'}
  Write-Output 'PASS escaped schema claim, host-positive/bypass-negative and dropped-relevant-row mutant'
} finally {
  if(-not[IO.Path]::GetFullPath($temp).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)){throw 'unsafe cleanup target'}
  Remove-Item -LiteralPath $temp -Recurse -Force
}

if($HistorySnapshot){
  if(-not$BaselineModule-or-not$EvidenceRoot){throw 'snapshot equivalence requires baseline module and evidence root'}
  $snapshotHash=(Get-FileHash $HistorySnapshot).Hash
  $baseline=Import-Module $BaselineModule -Force -PassThru -DisableNameChecking
  $timer=[Diagnostics.Stopwatch]::StartNew()
  $live=& $candidate {param($p) Read-ExactHeadReviewHistory $p} $HistorySnapshot
  if(-not$live.complete){throw "snapshot incomplete: $($live.reason)"}
  $newClasses=@(& $candidate {param($h) Get-ControllerReviewClassifiedHistory -History $h} $live)
  $liveHead='16c53af23eb0656e7d2b233164fee99d8be55527'
  $repair=@($newClasses|Where-Object{$_.classification.strict-and$_.classification.valid-and$_.classification.issue-eq8425-and$_.classification.controllerHead-ceq$liveHead-and$_.classification.rowKind-ceq'receipt'-and$_.classification.reviewAuthority-ceq'governing'})
  $repairJson=$repair|ConvertTo-Json -Compress -Depth 100
  [IO.File]::WriteAllText((Join-Path $EvidenceRoot 'after-battery-receipts.json'),$repairJson)
  "AFTER battery-repair seconds=$($timer.Elapsed.TotalSeconds) rows=$($live.audit.rows) receipts=$($repair.Count)"
  $timer.Restart()
  $installHistory=& $candidate {param($p) Read-ExactHeadReviewHistory $p} $HistorySnapshot
  $issues=@(& $candidate {param($h,$head) Get-ControllerReviewClassifiedHistory -History $h | ForEach-Object{$_.classification}|Where-Object{$_.strict-and$_.valid-and$_.controllerHead-ceq$head}|ForEach-Object{[int]$_.issue}|Sort-Object -Unique} $installHistory $liveHead)
  if($issues.Count-ne1){throw 'installer issue ambiguity'}
  $install=& $candidate {param($h,$issue,$head) Reduce-ControllerReleaseReview -Issue $issue -ControllerHead $head -Mode strict-v1 -History $h} $installHistory $issues[0] $liveHead
  $installJson=$install|ConvertTo-Json -Compress -Depth 100
  [IO.File]::WriteAllText((Join-Path $EvidenceRoot 'after-install-reduction.json'),$installJson)
  "AFTER installer-reduction seconds=$($timer.Elapsed.TotalSeconds) issues=$($issues -join ',') state=$($install.state) reason=$($install.reason)"
  if($repairJson-cne[IO.File]::ReadAllText((Join-Path $EvidenceRoot 'before-battery-receipts.json'))-or$installJson-cne[IO.File]::ReadAllText((Join-Path $EvidenceRoot 'before-install-reduction.json'))){throw 'live battery/installer byte equivalence failed'}
  # Cache H0's already measured pure classification, never its reductions or
  # filtered history. Correction joins still receive every original row.
  $before=@(Get-Content -Raw (Join-Path $EvidenceRoot 'before-classifications.json')|ConvertFrom-Json -DateKind String)
  & $baseline {
    param($classes)
    $script:equivalenceCache=@{}
    foreach($item in $classes){$script:equivalenceCache["$($item.entry.rawSha256)|$($item.entry.line)"]=$item.classification}
    $script:originalClassifier=${function:Get-ControllerReviewRowClassification}
    function script:Get-ControllerReviewRowClassification($Entry,$Vocabulary){
      $key="$($Entry.rawSha256)|$($Entry.line)"
      if($Entry.PSObject.Properties['rawSha256']-and$script:equivalenceCache.ContainsKey($key)){return $script:equivalenceCache[$key]}
      & $script:originalClassifier $Entry $Vocabulary
    }
  } $before
  $cachedReference=& $baseline {param($h,$head) Reduce-ControllerReleaseReview -Issue 8425 -ControllerHead $head -Mode strict-v1 -History $h} $live $liveHead
  if(($cachedReference|ConvertTo-Json -Compress -Depth 100)-cne[IO.File]::ReadAllText((Join-Path $EvidenceRoot 'before-install-reduction.json'))){throw 'cached H0 classification replay differs from measured uncached reduction'}
  $pairs=@($before|Where-Object{$_.classification.controllerHead-cmatch'^[a-f0-9]{40}$'-and$_.classification.issue-ge1-and$_.classification.issue-le[int]::MaxValue}|ForEach-Object{"$($_.classification.issue)|$($_.classification.controllerHead)"}|Sort-Object -Unique)
  $count=0
  $writer=[IO.StreamWriter]::new((Join-Path $EvidenceRoot 'live-equivalence.jsonl'),$false,[Text.UTF8Encoding]::new($false))
  try{foreach($pair in $pairs){
    $issue,$head=$pair.Split('|')
    foreach($selector in @(
      { $_.classification.strict -and $_.classification.valid -and $_.classification.controllerHead -ceq $head },
      { $_.classification.strict -and $_.classification.valid -and $_.classification.issue -eq [int]$issue -and $_.classification.controllerHead -ceq $head -and $_.classification.rowKind -ceq 'receipt' -and $_.classification.reviewAuthority -ceq 'governing' }
    )){
      $oldSelection=@($before|Where-Object $selector)|ConvertTo-Json -Compress -Depth 100
      $newSelection=@($newClasses|Where-Object $selector)|ConvertTo-Json -Compress -Depth 100
      if($oldSelection-cne$newSelection){throw "live installer/battery selection mismatch: $pair"}
    }
    foreach($mode in @('strict-v1','strict-v2')){
      $p=@{Issue=[int]$issue;ControllerHead=$head;Mode=$mode;History=$live}
      $old=& $baseline {param($p) Reduce-ControllerReleaseReview @p} $p
      $new=& $candidate {param($p) Reduce-ControllerReleaseReview @p} $p
      $oldJson=$old|ConvertTo-Json -Compress -Depth 100;$newJson=$new|ConvertTo-Json -Compress -Depth 100
      if($oldJson-cne$newJson){throw "live reduction mismatch: $pair/$mode"}
      $writer.WriteLine($newJson);$count+=1
    }
  }}finally{$writer.Dispose()}
  if((Get-FileHash $HistorySnapshot).Hash-cne$snapshotHash){throw 'snapshot bytes changed'}
  "PASS live snapshot byte-equivalent reductions=$count pairs=$($pairs.Count) sha256=$snapshotHash"
}
