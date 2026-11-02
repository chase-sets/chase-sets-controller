# #9123 composed collector -> FactsOut -> FactsPath -> report coverage.
# Loaded within velocity-metrics.test.ps1's synthetic external-input scope.
function Replay-9123([string]$Source,[switch]$MoveHead) {
  $errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($Source,[ref]$null,[ref]$errors)
  Assert-Velocity ($errors.Count -eq 0) '9123 replay source parses'
  foreach($name in @('Get-VelocityFacts','Get-VelocityReport')){
    $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true)
    . ([scriptblock]::Create($node.Extent.Text.Replace('$PSScriptRoot', "'$($PSScriptRoot.Replace("'", "''"))'")))
  }
  $cli=@($ast.EndBlock.Statements|Where-Object{$_ -is [Management.Automation.Language.IfStatementAst]})[-1].Clauses[0].Item2
  $body=[scriptblock]::Create($cli.Extent.Text.Substring(1,$cli.Extent.Text.Length-2))
  $ContainerRoot=$root;$NowUtc=$clock.ToString('o');$ObservationLog=Join-Path $runtime '9123-observations.jsonl'
  $FactsOut=Join-Path $runtime '9123-facts.json';$FactsPath='';$NoRecord=$false;$Summary=$false
  if(Test-Path -LiteralPath $ObservationLog){Remove-Item -LiteralPath $ObservationLog}
  $collected=(& $body)|ConvertFrom-Json -DateKind String
  $savedFacts=Get-Content -LiteralPath $FactsOut -Raw|ConvertFrom-Json -DateKind String
  if($MoveHead){$savedFacts.productPrs[0].headOid='d'*40;Save-Json $FactsOut $savedFacts}
  # Replay cannot reread review history: remove it until reporting finishes.
  $ledger=[IO.File]::ReadAllText($dispatchPath)
  try {
    [IO.File]::WriteAllText($dispatchPath,'')
    $FactsPath=$FactsOut;$FactsOut='';$NoRecord=$true
    $replayed=(& $body)|ConvertFrom-Json -DateKind String
  } finally {[IO.File]::WriteAllText($dispatchPath,$ledger)}
  $row=if(Test-Path -LiteralPath $ObservationLog){Get-Content -LiteralPath $ObservationLog -Last 1|ConvertFrom-Json -DateKind String}else{$null}
  [pscustomobject]@{facts=$savedFacts;report=$replayed;collected=$collected;observation=$row}
}
function Set-ReviewRows([string]$Mode) {
  $receipt=([pscustomobject]$pass)|ConvertTo-Json -Depth 10|ConvertFrom-Json -DateKind String
  $receipt.ts=$clock.AddDays(-30).ToString('o')
  $rows=@($receipt)
  switch($Mode){
    SKIP {$receipt.outcome='SKIP'}
    stale {$receipt.reviewedHead='b'*40}
    'no-history' {$rows=@()}
    malformed {$receipt.completeSweep='invalid'}
    contradictory {$other=$receipt.PSObject.Copy();$other.outcome='SKIP';$rows+=@($other)}
    'unknown-outcome' {$receipt.outcome='SYNTHETIC_UNKNOWN'}
    'filtered-malformed' {$other=$receipt.PSObject.Copy();$other.ts='invalid';$rows+=@($other)}
    continuation {
      $receipt.reviewedHead='b'*40
      [IO.File]::WriteAllText($dispatchPath,($receipt|ConvertTo-Json -Compress -Depth 10))
      $original=Reduce-ExactHeadReview -Pr $prNumber -CurrentHead ('b'*40) -History (Read-ExactHeadReviewHistory -Path $dispatchPath)
      $rows+=@([pscustomobject]@{ts=$clock.AddMinutes(-1).ToString('o');kind='repair-complete';continuationSchema='rebase-only-continuation/v1';pr=$prNumber
        reviewedHead=('b'*40);predecessorHead=('b'*40);newHead=$head;newBase=('c'*40);reviewedBase=('e'*40)
        sourcePassReceiptIdentity=$original.latest.receiptIdentity;integrationLane='synthetic-9123-integration'
        patchPairs=@([pscustomobject]@{reviewedCommit=('b'*40);newCommit=$head;reviewedPatchId=('1'*40);newPatchId=('1'*40)})
        rangeDiff='semantic-patch-equivalent';conflictResolution=$false})
    }
  }
  [IO.File]::WriteAllLines($dispatchPath,@($rows|ForEach-Object{$_|ConvertTo-Json -Depth 10 -Compress}),[Text.UTF8Encoding]::new($false))
}
$source=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'velocity-metrics.ps1'))
$activeHold=(Read-MergeHoldState $holdPath $clock).state
foreach($queue in @($false,$true)){
  foreach($hold in @($false,$true)){
    $holdState=$activeHold.PSObject.Copy();if(-not $hold){$holdState.records=@()};Save-Json $holdPath $holdState
    $script:syntheticPr.mergeQueueEntry=if($queue){[pscustomobject]@{id='MQE_SYNTHETIC_8526';state='QUEUED'}}else{$null}
    foreach($mode in @('PASS','SKIP','stale','continuation','no-history','malformed','contradictory','unknown-outcome')){
      Set-ReviewRows $mode
      $arm=Replay-9123 $source;$r=$arm.report
      $valid=$mode -cin @('PASS','SKIP','stale','continuation','no-history')
      $expectedHeld=$hold -and $mode -cin @('PASS','continuation')
      $expectedFlow=$queue -and $valid -and -not $expectedHeld
      Assert-Velocity ($r.factsComplete -eq $valid -and $r.metrics.heldCount -eq [int]$expectedHeld -and ($r.metrics.flowingProductIssues -contains $issueNumber) -eq $expectedFlow) "9123 queue=$queue hold=$hold mode=$mode classification: $($r.gaps -join ',')"
      Assert-Velocity (($r.gaps -ccontains "review-reduction-unknown:$prNumber") -eq (-not $valid)) '9123 gap iff invalid reduction'
      Assert-Velocity (($arm.facts.productPrs[0].reviewReduction.PSObject.Properties.Name -join ',') -ceq 'state,reason,currentHead') '9123 persists only reducer top-level projection'
      if(-not $valid){
        Assert-Velocity ($r.status -ceq 'UNKNOWN' -and $r.metrics.floorState -ceq 'UNKNOWN' -and $null -eq $arm.observation) '9123 malformed authority has no observation or invented queue flow'
        $f=$arm.facts;$f.productPrs[0].inMergeQueue=$false
        $f.dispatchRows=@([pscustomobject]@{ts=$clock.ToString('o');kind='enqueue';pr=$prNumber;head=$head})
        Assert-Velocity ((Get-VelocityReport $f $clock @()).metrics.flowingProductIssues.Count -eq 0) '9123 invalid projection cannot add green-wait flow'
      } else {
        Assert-Velocity (($arm.observation.readyIdleIssues -join ',') -ceq ($r.metrics.readyNotInFlight -join ',') -and
          ($arm.observation.heldPrs -join ',') -ceq (@($r.metrics.heldProductPrs|ForEach-Object pr) -join ',') -and $arm.observation.ts -ceq $r.now) '9123 additive observation identity arrays bind exact cycle ts'
        if($mode -ceq 'no-history' -and -not $queue){
          Assert-Velocity ($r.metrics.readyNotInFlight -contains $issueNumber -and $r.metrics.floorState -ceq 'UNMET') '9123 no review history is ready idle for first review'
        }
      }
      Write-Output "PASS 9123 replay queue=$queue hold=$hold mode=$mode"
    }
  }
}
Save-Json $holdPath $activeHold;$script:syntheticPr.mergeQueueEntry=[pscustomobject]@{id='MQE_SYNTHETIC_8526';state='QUEUED'}
foreach($mode in @('PASS','malformed')){
  Set-ReviewRows $mode;$arm=Replay-9123 $source;$f=$arm.facts
  $f.activeLanes=@([pscustomobject]@{lane='synthetic-live';laneRole='implementation'})
  $f.dispatchRows=@([pscustomobject]@{ts=$clock.ToString('o');kind='dispatch';issue=$issueNumber;lane='synthetic-live'})
  $r=Get-VelocityReport $f $clock @()
  Assert-Velocity ($r.metrics.flowingProductIssues -contains $issueNumber -and $r.metrics.heldCount -eq $(if($mode -ceq 'PASS'){1}else{0})) '9123 live flow is independent of held and invalid projection'
  Assert-Velocity (($r.gaps -ccontains "review-reduction-unknown:$prNumber") -eq ($mode -ceq 'malformed')) '9123 invalid projection/live flow retains gap'
  if($mode -ceq 'malformed'){
    $f.productIssues+=@(Issue 908530)
    $f.activeLanes+=@([pscustomobject]@{lane='synthetic-other-live';laneRole='implementation'})
    $f.dispatchRows+=@([pscustomobject]@{ts=$clock.ToString('o');kind='dispatch';issue=908530;lane='synthetic-other-live'})
    $r=Get-VelocityReport $f $clock @()
    Assert-Velocity ($r.status -ceq 'UNKNOWN' -and $r.metrics.floorState -ceq 'MET' -and $r.metrics.floorProofIssues.Count -eq 2) '9123 reduction gap is additive-only even with applicable hold; independent two-lane proof remains MET'
  }
}
$mutants=@(
  @{name='rollup-only-held';mode='SKIP';move=$false;guard='$reduction.state -ceq ''authorized''';replacement='$pr.ciState -ceq ''SUCCESS'''},
  @{name='dispatchRows-input';mode='filtered-malformed';move=$false;guard='-History $authorityHistory';replacement='-History ([pscustomobject]@{complete=$true;reason="";audit=$authorityHistory.audit;rows=@($authorityHistory.rows|Where-Object{$facts.dispatchRows.line -contains $_.line})})'},
  @{name='reviewedHead-binding';mode='continuation';move=$false;guard='currentHead=$reduction.currentHead';replacement="currentHead=(Get-VelocityValue (Get-VelocityValue `$reduction 'latest') 'reviewedHead')"},
  @{name='dropped-head-equality';mode='PASS';move=$true;guard='$reduction.currentHead -ceq $pr.headOid';replacement='$true'}
)
foreach($m in $mutants){
  Set-ReviewRows $m.mode
  Assert-Velocity ($source.Contains($m.guard)) "9123 $($m.name) isolated anchor"
  $candidate=Replay-9123 $source -MoveHead:$m.move
  $mutated=Replay-9123 ($source.Replace($m.guard,$m.replacement)) -MoveHead:$m.move
  $expected=if($m.mode -ceq 'continuation'){1}else{0}
  Assert-Velocity ($candidate.report.metrics.heldCount -eq $expected) "9123 $($m.name) candidate PASS"
  Assert-Velocity ($mutated.report.metrics.heldCount -ne $expected) "9123 $($m.name) mutant FAIL on same frozen inputs"
  Write-Output "KILLED 9123 $($m.name) candidate=PASS mutant=FAIL"
}
Set-ReviewRows PASS
$validFacts=(Replay-9123 $source).facts
foreach($defect in @('absent','null','array-head','array-state','extra-field','legacy-unknown')){
  $f=$validFacts|ConvertTo-Json -Depth 32|ConvertFrom-Json -DateKind String
  switch($defect){
    absent {$f.productPrs[0].PSObject.Properties.Remove('reviewReduction')}
    null {$f.productPrs[0].reviewReduction=$null}
    'array-head' {$f.productPrs[0].reviewReduction.currentHead=@($head)}
    'array-state' {$f.productPrs[0].reviewReduction.state=@('authorized')}
    'extra-field' {$f.productPrs[0].reviewReduction|Add-Member latest $null}
    'legacy-unknown' {$f.productPrs[0].reviewReduction.state='unknown';$f.productPrs[0].reviewReduction.reason='LEGACY_RECEIPTS_ONLY'}
  }
  $r=Get-VelocityReport $f $clock @()
  Assert-Velocity ($r.status -ceq 'UNKNOWN' -and $r.metrics.heldCount -eq 0 -and $r.metrics.flowingProductIssues.Count -eq 0 -and $r.gaps -ccontains "review-reduction-unknown:$prNumber") "9123 $defect projection is invalid without throwing"
}
