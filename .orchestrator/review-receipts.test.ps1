$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'routing-data-test-support.ps1')
$scope = Enter-RoutingDataTestScope
$root = Join-Path ([IO.Path]::GetTempPath()) ('review-receipts-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
try {
  Import-Module (Join-Path $PSScriptRoot 'review-head-contract.psm1') -Force -DisableNameChecking
  $logger = Join-Path $PSScriptRoot 'log-event.ps1'
  $log = Join-Path $root 'reviews.jsonl'
  $headA = 'a' * 40
  $headB = 'b' * 40
  function Assert-Receipt($Condition, $Message) { if (-not $Condition) { throw $Message } }
  function Write-Receipt($Head, $Outcome, $Blocking) {
    & $logger -Log dispatch -Kind review-complete -Pr 263 -ReviewedHead $Head -Model gpt-6.1-sol -Outcome $Outcome -Blocking $Blocking -OutFile $log -NoBoard | Out-Null
  }
  Write-Receipt $headA BLOCK_FIXABLE 1
  $row = Get-Content $log -Tail 1 | ConvertFrom-Json -DateKind String
  Assert-Receipt ((Get-ReviewReceiptValidation $row).valid) 'minimal blocking receipt is unreadable'
  Assert-Receipt ($row.findings.nonBlocking -eq 0 -and $row.findings.candidates -eq 0) 'optional counts must default to zero'
  Assert-Receipt (-not $row.PSObject.Properties['reviewerAttempt'] -and -not $row.PSObject.Properties['completeSweep']) 'legacy bookkeeping leaked into minimal receipt'
  foreach($count in @('Candidates','NonBlocking')) {
    $optional=@{}; $optional[$count]=-1; $refused=$false
    try { & $logger -Log dispatch -Kind review-complete -Pr 263 -ReviewedHead $headA -Model gpt-6.1-sol -Outcome PASS -Blocking 0 @optional -OutFile $log -NoBoard | Out-Null }
    catch { $refused=$_.Exception.Message -like '*requires nonnegative*' }
    Assert-Receipt $refused "explicit negative $count was accepted"
  }
  Assert-Receipt ((Reduce-ExactHeadReview -Pr 263 -CurrentHead $headA -History (Read-ExactHeadReviewHistory $log)).state -eq 'blocked') 'block did not apply'
  Start-Sleep -Milliseconds 5
  Write-Receipt $headB PASS 0
  $history = Read-ExactHeadReviewHistory $log
  Assert-Receipt ((Reduce-ExactHeadReview -Pr 263 -CurrentHead $headB -History $history).state -eq 'authorized') 'later-head PASS did not clear earlier-head block'
  Assert-Receipt ((Reduce-ExactHeadReview -Pr 263 -CurrentHead ('c' * 40) -History $history).state -eq 'stale') 'unreviewed live head was authorized'
  Start-Sleep -Milliseconds 5
  Write-Receipt $headA PASS 0
  Assert-Receipt ((Reduce-ExactHeadReview -Pr 263 -CurrentHead $headA -History (Read-ExactHeadReviewHistory $log)).state -eq 'authorized') 'same-head later PASS remains sticky'
  # The production enqueue consumer sees the minimal receipt, not a parallel
  # test-only authorization. AuthorityFixture keeps every mutation synthetic.
  $enqueueLog=Join-Path $root 'enqueue.jsonl'
  & $logger -Log dispatch -Kind review-complete -Pr 6254 -ReviewedHead $headA -Model gpt-6.1-sol -Outcome PASS -Blocking 0 -OutFile $enqueueLog -NoBoard | Out-Null
  $preflight=Join-Path $PSScriptRoot 'landing-preflight.ps1'
  $fixture=Join-Path $PSScriptRoot 'landing-preflight.fixture.json'
  $eligible=& $preflight -Pr 6254 -Action Apply -HistoryPath $enqueueLog -AuthorityFixture $fixture -AuthorityScenario eligible | ConvertFrom-Json
  Assert-Receipt ($eligible.status -eq 'enqueued' -and $eligible.mutationCount -eq 1) 'minimal receipt did not authorize synthetic exact-head enqueue'
  $moved=& $preflight -Pr 6254 -Action Apply -HistoryPath $enqueueLog -AuthorityFixture $fixture -AuthorityScenario head-movement | ConvertFrom-Json
  Assert-Receipt ($moved.status -eq 'unknown' -and $moved.reason -eq 'HEAD_MOVED_BETWEEN_READS' -and $moved.mutationCount -eq 0) 'head movement did not fail closed before enqueue'
  $bad = $row.PSObject.Copy(); $bad.outcome = 'PASS'
  Assert-Receipt (-not (Get-ReviewReceiptValidation $bad).valid) 'PASS accepted blocking findings'
  foreach ($field in @('pr','reviewedHead','model','outcome','findings')) {
    $bad = $row.PSObject.Copy(); $bad.PSObject.Properties.Remove($field)
    Assert-Receipt (-not (Get-ReviewReceiptValidation $bad).valid) "missing concept accepted: $field"
  }
  # Execute the actual controller-target guard without a harness or process.
  $tokens=$null; $parseErrors=$null
  $source=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'dispatch-lane.ps1'))
  $ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$parseErrors)
  Assert-Receipt ($parseErrors.Count -eq 0) 'dispatcher does not parse'
  $guards=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.StartsWith("if (`$ReviewTarget -ceq 'controller') {")},$false))
  Assert-Receipt ($guards.Count -eq 1) 'controller target guard missing or duplicated'
  $ReviewTarget='controller'; $LaneRole='review'; $ControllerHead=$null; $admissionHead=$headA
  & ([scriptblock]::Create($guards[0].Extent.Text))
  $ControllerHead=$headB; $refused=$false
  try { & ([scriptblock]::Create($guards[0].Extent.Text)) } catch { $refused=$_.Exception.Message -like '*must target the worktree HEAD*' }
  Assert-Receipt $refused 'controller explicit mismatched head accepted'
  Assert-Receipt (-not $source.Contains('Reduce-ControllerReleaseReview')) 'controller launch restored receipt prelogging'
  # Legacy strict pairs remain readable, but a later valid review wins.
  $legacyLog=Join-Path $root 'legacy.jsonl'
  $rows=[Collections.Generic.List[object]]::new()
  function Add-LegacyPair($Head, $Verdict, $Round) {
    foreach ($kind in @('dispatch','review-complete')) {
      $r=[ordered]@{ts=[datetimeoffset]::UtcNow.AddHours(-1).AddMinutes($Round).AddSeconds($(if($kind -eq 'dispatch'){0}else{1})).ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
        kind=$kind;controllerReviewSchema=$(if($kind -eq 'dispatch'){'controller-review-dispatch/v1'}else{'controller-review-receipt/v1'})
        issue=263;controllerHead=$Head;authorAttempt="author-$Round";reviewerAttempt="reviewer-$Round";reviewAuthority='governing'
        lane="review-$Round";transcript="review-$Round.jsonl";reviewerModel='gpt-6.1-sol';authorModel='gpt-6.1-sol';effort='high';row='11';placement='provisional';harness='codex'}
      if($kind -eq 'review-complete') {
        $blocking=if($Verdict -eq 'PASS'){0}else{1}
        $r.reviewContract='review-contract/v2';$r.completeSweep=$true;$r.outcome=$Verdict
        $r.findingIds=[object[]]@($(if($blocking){'F1'}));$r.findings=@{blocking=$blocking;candidates=$blocking;nonBlocking=0}
      }
      $rows.Add([pscustomobject]$r)
    }
  }
  Add-LegacyPair $headA BLOCK_FIXABLE 1
  Add-LegacyPair $headB PASS 2
  Add-LegacyPair $headA PASS 3
  [IO.File]::WriteAllLines($legacyLog,@($rows | ForEach-Object {$_ | ConvertTo-Json -Compress -Depth 8}))
  $history=Read-ExactHeadReviewHistory $legacyLog
  foreach($head in @($headA,$headB)) {
    $legacy=Reduce-ControllerReleaseReview -Issue 263 -ControllerHead $head -Mode strict-v1 -History $history
    Assert-Receipt ($legacy.state -eq 'authorized' -and $legacy.blockingHeads.Count -eq 0) "legacy block stayed sticky at $head ($($legacy.reason))"
  }
  Write-Output 'PASS minimal five-concept receipts; exact-head authority; latest verdict replaces prior blocks'
} finally {
  Remove-Item -LiteralPath $root -Recurse -Force
  Exit-RoutingDataTestScope $scope
}
