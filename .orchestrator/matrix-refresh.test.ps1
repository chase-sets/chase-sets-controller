param([switch]$CapacityOnly,[switch]$CapacityQuarantineOnly,[string]$RefreshPath,[string]$EvidenceDir)
$ErrorActionPreference = "Stop"

$refresh = Join-Path $PSScriptRoot "matrix-refresh.ps1"
if($RefreshPath){$refresh=$RefreshPath}
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("matrix-refresh-test-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $testRoot | Out-Null
. (Join-Path $PSScriptRoot 'routing-data-test-support.ps1')
$routingTestScope=Enter-RoutingDataTestScope
$oldRoutingRoot=$env:CHASE_SETS_ROUTING_DATA_ROOT
$oldRoutingLkg=$env:CHASE_SETS_ROUTING_LKG_PATH
# The committed matrix is a historical test fixture, not live pool authority.
$snapshot=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'controller-skills/model-routing/capability-matrix.json') | ConvertFrom-Json
$routingFixture=New-RoutingMatrixFixture -Root (Join-Path $testRoot 'routing-state') -Snapshot $snapshot
$env:CHASE_SETS_ROUTING_DATA_ROOT=$routingFixture.stateRoot
$env:CHASE_SETS_ROUTING_LKG_PATH=$routingFixture.lkgPath
try {

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

$matrixPath = Join-Path $testRoot "capability-matrix.json"
$ledgerPath = Join-Path $testRoot "cost-ledger.jsonl"
$dispatchPath = Join-Path $testRoot "dispatch-log.jsonl"

function Reset-Fixtures {
  # AUTHORED content — scores, vetoes, bars. Must survive every refresh.
  $matrix = [ordered]@{
    version = "test"
    configs = @(
      [ordered]@{ id = "gpt-5.6-sol/high"; model = "gpt-5.6-sol"; effort = "high"; harness = "codex"
                  usdPerRun = 999.0; usdN = 1; usdPerArtifact = 42 }   # legacy hand-written
      # Same model, different effort: a different configuration that must
      # never inherit gpt-5.6-sol/high's runs (v4.13). A stale pooled block is planted
      # to prove the refresh removes it rather than leaving it to be read.
      [ordered]@{ id = "gpt-5.6-sol/xhigh"; model = "gpt-5.6-sol"; effort = "xhigh"; harness = "codex"
                  measured = [ordered]@{ usdPerRun = 7.0; n = 2; basis = "stale-pooled" } }
      [ordered]@{ id = "claude-sonnet-5/medium"; model = "claude-sonnet-5"; effort = "medium"; harness = "claude" }
      [ordered]@{ id = "claude-fable-5/high"; model = "claude-fable-5"; effort = "high"; harness = "claude" }
    )
    dimensions = @(
      [ordered]@{ id = "review-recall"; bar = 99; baseline = "gpt-5.6-sol/high"
        cells = [ordered]@{
          "gpt-5.6-sol/high"    = [ordered]@{ score = 0; src = "B" }
          "claude-fable-5/high" = [ordered]@{ veto = $true; reason = "authored veto that must survive" }
        }
      }
    )
  }
  Set-Content -LiteralPath $matrixPath -Encoding utf8 -Value ($matrix | ConvertTo-Json -Depth 20)

  $now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
  # Two exact-version Sol runs normalize to $6 + $8 -> $7/run even though
  # billed-at-the-time USD is $60 + $80. One exact Sonnet run has no normalized
  # field and falls back to its provider-reported USD. Ambiguous aliases are
  # excluded rather than guessed.
  Set-Content -LiteralPath $ledgerPath -Encoding utf8 -Value @(
    (@{ ts=$now; transcript="a.jsonl"; issue=100; model="gpt-5.6-sol"; usd=60.0; usdCurrent=6.0; durationSec=600; costSource="token-derived"; routingCostSource="current-price-token-derived"; durationSrc="file-span-estimate" } | ConvertTo-Json -Compress),
    (@{ ts=$now; transcript="b.jsonl"; issue=101; model="gpt-5.6-sol"; usd=80.0; usdCurrent=8.0; durationSec=1800; costSource="token-derived"; routingCostSource="current-price-token-derived"; durationSrc="file-span-estimate" } | ConvertTo-Json -Compress),
    (@{ ts=$now; transcript="c.jsonl"; issue=102; model="claude-sonnet-5"; usd=4.0; durationSec=300; costSource="stream-json"; durationSrc="stream-json" } | ConvertTo-Json -Compress),
    (@{ ts=$now; transcript="ambiguous-sol.jsonl"; issue=103; model="sol"; usd=100.0; usdCurrent=10.0; durationSec=60; costSource="token-derived"; routingCostSource="current-price-token-derived"; durationSrc="file-span-estimate" } | ConvertTo-Json -Compress),
    (@{ ts=$now; transcript="deprecated-opus.jsonl"; issue=104; model="claude-opus-4-8"; usd=100.0; durationSec=60; costSource="stream-json"; durationSrc="stream-json" } | ConvertTo-Json -Compress)
  )

  # Dispatch rows carry the transcript (the cost join key) and the effort that
  # keys each run to its configuration.
  Set-Content -LiteralPath $dispatchPath -Encoding utf8 -Value @(
    (@{ ts=$now; kind="dispatch"; issue=100; model="gpt-5.6-sol"; effort="high"; transcript="a.jsonl"; row="4" } | ConvertTo-Json -Compress),
    (@{ ts=$now; kind="dispatch"; issue=101; model="gpt-5.6-sol"; effort="high"; transcript="b.jsonl"; routingRow="4" } | ConvertTo-Json -Compress),
    (@{ ts=$now; kind="dispatch"; issue=102; model="claude-sonnet-5"; effort="medium"; transcript="c.jsonl"; row="3" } | ConvertTo-Json -Compress),
    (@{ ts=$now; kind="review-complete"; pr=1; authorModel="sonnet-5";        outcome="BLOCK" } | ConvertTo-Json -Compress),
    (@{ ts=$now; kind="review-complete"; pr=2; authorModel="claude-sonnet-5"; outcome="PASS"  } | ConvertTo-Json -Compress),
    (@{ ts=$now; kind="review-complete"; pr=3; authorModel="Sonnet 5";        outcome="PASS"  } | ConvertTo-Json -Compress),
    (@{ ts=$now; kind="review-complete"; pr=4; authorModel="sonnet";          outcome="PASS"  } | ConvertTo-Json -Compress)
  )
}

function Get-Matrix { Get-Content -LiteralPath $matrixPath -Raw | ConvertFrom-Json }
function Invoke-Refresh { param([switch]$Adjudicate, [switch]$DryRun, [int]$DriftPct = 25)
  & $refresh -Matrix $matrixPath -CostLedger $ledgerPath -DispatchLog $dispatchPath `
    -Adjudicate:$Adjudicate -DryRun:$DryRun -DriftPct $DriftPct -Json | ConvertFrom-Json
}

function New-StrictMatrixPair([string]$Authority,[string]$Outcome,[string]$Label,[int]$Issue) {
  $common=[ordered]@{issue=$Issue;controllerHead=('a'*40);authorAttempt="$Label-author";reviewerAttempt="$Label-reviewer";reviewAuthority=$Authority;lane="$Label-lane";transcript="$Label.jsonl";reviewerModel='gpt-5.6-sol';authorModel='gpt-5.6-sol';effort='high';row='7';placement='measured';harness='codex'}
  $dispatch=[ordered]@{ts='2026-08-01T12:00:00.000Z';kind='dispatch';controllerReviewSchema='controller-review-dispatch/v1'}
  $receipt=[ordered]@{ts='2026-08-01T12:00:00.001Z';kind='review-complete';controllerReviewSchema='controller-review-receipt/v1'}
  foreach($key in $common.Keys){$dispatch[$key]=$common[$key];$receipt[$key]=$common[$key]}
  $blocking=if($Outcome-in@('BLOCK_FIXABLE','BLOCK_REPLAN')){1}else{0}
  $receipt.reviewContract='review-contract/v2';$receipt.completeSweep=$true;$receipt.outcome=$Outcome
  if($blocking){$receipt.findingIds=[object[]]@("MATRIX_$($Label.ToUpperInvariant())")}else{$receipt.findingIds=[object[]]@()}
  $receipt.findings=[ordered]@{blocking=$blocking;candidates=0;nonBlocking=0}
  [pscustomobject]$dispatch;[pscustomobject]$receipt
}

function Test-CapacityClosedEvidence {
  . (Join-Path $PSScriptRoot 'dispatch-ownership.ps1')
  $fields=@('capacityForecastStatus','capacityDecisionDigest','capacityFlip','capacityShadowFlip','capacityFlipSkip',
    'label','policyGeneration','registryAuthorityDigest','family','slot','usedLastKnownGood','model','effort','row','attemptId','branch')
  $cases=@('active-valid','shadow-valid','exact-duplicate','reordered-duplicate','historical-v1','historical-v2','missing-schema') +
    @($fields | ForEach-Object {"missing-$_"}) + @('missing-all-capacity','missing-mixed-status') +
    @('conflicting-active','conflicting-shadow','conflicting-digest','conflicting-skip','conflicting-head',
      'conflicting-registry','conflicting-generation','conflicting-lkg','conflicting-label','conflicting-time','conflicting-mechanical')
  foreach($case in $cases) {
    Reset-Fixtures
    $events=[Collections.Generic.List[object]]::new();$costs=[Collections.Generic.List[object]]::new()
    $now=[DateTimeOffset]::UtcNow.AddMinutes(-2)
    $shadow=$case -in @('shadow-valid','conflicting-shadow')
    foreach($n in 1..3) {
      $attempt="synthetic-$case-$n";$branch="synthetic/$attempt"
      $flip=@{row=4;toward='claude';steps=3;from=@{harness='codex';family='sol';effort='high';slot='codex.primary'}
        to=@{harness='claude';family='opus';effort='medium';slot='claude.primary';placement='override-Todd'}}
      $d=@{ts=$now.ToString('o');kind='dispatch';dispatchRoutingSchema='watchdog-dispatch-routing/v3';attemptId=$attempt;label=$attempt
        lane='synthetic';laneRole='implementation';transcript="$attempt.jsonl";harness='claude';model='claude-opus-5-5';effort='medium';row='4'
        placement='override-Todd';worktree='D:\synthetic-capacity';branch=$branch;head=('a'*40);policyGeneration=1
        registryAuthorityDigest='synthetic';family='opus';slot='claude.primary';usedLastKnownGood=$false
        capacityForecastStatus='in-force';capacityDecisionDigest='0123456789abcdef';capacityFlip=$flip;capacityShadowFlip=$null;capacityFlipSkip=$null}
      if($shadow){
        $d.harness='codex';$d.model='gpt-6.1-sol';$d.effort='high';$d.family='sol';$d.slot='codex.primary';$d.placement='provisional'
        $d.capacityForecastStatus='shadow';$d.capacityFlip=$null;$d.capacityShadowFlip=$flip
      }
      if($case -ceq 'conflicting-skip'){$d.capacityFlip=$null;$d.capacityFlipSkip='SLOT_NOT_ADMITTED'}
      if($case -like 'historical-*'){
        $d.dispatchRoutingSchema="watchdog-dispatch-routing/$($case.Split('-')[-1])"
        foreach($field in @($d.Keys | Where-Object {$_ -like 'capacity*'})){$d.Remove($field)}
        if($case -ceq 'historical-v1'){foreach($field in @('policyGeneration','registryAuthorityDigest','family','slot','usedLastKnownGood')){$d.Remove($field)}}
      }
      $authorModel=$d.model;$authorEffort=$d.effort
      if($case -ceq 'missing-mixed-status'){$events.Add($d.Clone())}
      if($case -ceq 'missing-all-capacity'){
        foreach($field in @($d.Keys|Where-Object{$_ -like 'capacity*'})){$d.Remove($field)}
      } elseif($case -like 'missing-*'){
        $d.Remove($(switch($case){'missing-schema'{'dispatchRoutingSchema'} 'missing-mixed-status'{'capacityForecastStatus'} default{$case.Substring(8)}}))
      }
      $events.Add($d)
      if($case -like '*duplicate' -or $case -like 'conflicting-*'){
        $copy=$d | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable -DateKind String
        switch($case){
          'conflicting-active' {$copy.capacityFlip.steps=4}
          'conflicting-shadow' {$copy.capacityShadowFlip.steps=4}
          'conflicting-digest' {$copy.capacityDecisionDigest='fedcba9876543210'}
          'conflicting-skip' {$copy.capacityFlipSkip='REVIEWER_INDEPENDENCE'}
          'conflicting-head' {$copy.head='b'*40}
          'conflicting-registry' {$copy.registryAuthorityDigest='other-synthetic'}
          'conflicting-generation' {$copy.policyGeneration=2}
          'conflicting-lkg' {$copy.usedLastKnownGood=$true}
          'conflicting-label' {$copy.label='other-synthetic'}
          'conflicting-time' {$copy.ts=$now.AddMilliseconds(1).ToString('o')}
          'conflicting-mechanical' {
            $copy.transcript="$attempt-retry.jsonl";$copy.ts=$now.AddMilliseconds(1).ToString('o')
            $copy.capacityForecastStatus='not-evaluated';$copy.capacityDecisionDigest=$null;$copy.capacityFlip=$null
            $events.Add($copy.Clone());$copy.head='b'*40
          }
          'reordered-duplicate' {
            $copy=[ordered]@{};foreach($field in @($d.Keys|Sort-Object -Descending)){$copy[$field]=$d[$field]}
            $copy.capacityFlip=[ordered]@{to=[ordered]@{placement=$flip.to.placement;slot=$flip.to.slot;effort=$flip.to.effort;family=$flip.to.family;harness=$flip.to.harness}
              from=$flip.from;steps=$flip.steps;toward=$flip.toward;row=$flip.row}
          }
        }
        $events.Add($copy)
      }
      $costs.Add(@{ts=$now.ToString('o');transcript=$d.transcript;model=$authorModel;usdCurrent=10;usd=10;durationSec=60})
      $events.Add(@{ts=$now.AddSeconds(1).ToString('o');kind='review-complete';authorAttempt=$attempt;branch=$branch;authorModel=$authorModel;authorEffort=$authorEffort;outcome='PASS'})
    }
    foreach($reverse in @($false,$true)) {
      $rows=@($events);if($reverse){[array]::Reverse($rows)}
      Set-Content $dispatchPath -Value @($rows|ForEach-Object{$_|ConvertTo-Json -Depth 20 -Compress})
      Set-Content $ledgerPath -Value @($costs|ForEach-Object{$_|ConvertTo-Json -Compress})
      $validators=@(Get-Content $dispatchPath|ConvertFrom-Json -DateKind String|Where-Object kind -EQ 'dispatch'|ForEach-Object{Test-DispatchRoutingLedgerEvidence $_})
      if($case -notlike 'missing-*'){Assert-True ($validators -notcontains $false) "valid closed evidence $case"}
      Invoke-Refresh|Out-Null;$m=Get-Matrix
      $key=if($shadow){"row4`u{001f}gpt-6.1-sol`u{001f}high"}else{"row4`u{001f}claude-opus-5-5`u{001f}medium"}
      $modelKey=if($shadow){"row4`u{001f}gpt-6.1-sol"}else{"row4`u{001f}claude-opus-5-5"}
      if($case -like 'missing-*' -or $case -like 'conflicting-*'){
        foreach($table in @($m.measuredAt,$m.measuredAt.capacityFlipped)){
          Assert-True ($null -eq $table.byRowConfig.$key -and $null -eq $table.blockRateByRow.$modelKey -and
            $null -eq $table.blockRateByRowConfig.$key) "closed evidence excluded $case reverse=$reverse"
        }
        $suffix=if($case -like 'missing-*'){'Unresolved'}else{'Ambiguous'}
        Assert-True ($m.measuredAt.capacityIdentity."costRows$suffix" -eq 3 -and
          $m.measuredAt.capacityIdentity."reviewRows$suffix" -eq 3) "closed evidence diagnostics $case reverse=$reverse"
      } else {
        $ordinary=$shadow -or $case -like 'historical-*'
        $table=if($ordinary){$m.measuredAt}else{$m.measuredAt.capacityFlipped}
        $other=if($ordinary){$m.measuredAt.capacityFlipped}else{$m.measuredAt}
        Assert-True ($table.byRowConfig.$key.runs -eq 3 -and $table.blockRateByRow.$modelKey.reviews -eq 3 -and
          $table.blockRateByRowConfig.$key.reviews -eq 3) "closed evidence control $case reverse=$reverse"
        Assert-True ($null -eq $other.byRowConfig.$key -and $null -eq $other.blockRateByRow.$modelKey -and
          $null -eq $other.blockRateByRowConfig.$key -and
          @($m.measuredAt.capacityIdentity.PSObject.Properties.Value|Where-Object{$_ -ne 0}).Count -eq 0) "closed evidence exclusive cohort $case"
      }
    }
    Write-Output "PASS capacity closed evidence $case both-orders"
  }
}
function Test-CapacityQuarantine {
  . (Join-Path $PSScriptRoot 'dispatch-ownership.ps1')
  foreach($case in @('valid-with-history','missing-kind','extra-author-model','wrong-kind','review-role','planning-role',
      'unknown-role','marker-extra-author','missing-transcript','unmatched-transcript','ambiguous-branch','ambiguous-issue')) {
    Reset-Fixtures
    $events=[Collections.Generic.List[object]]::new();$costs=[Collections.Generic.List[object]]::new()
    $now=[DateTimeOffset]::UtcNow.AddMinutes(-2)
    foreach($n in 1..3){
      $attempt="synthetic-quarantine-$case-$n";$branch="synthetic/$attempt";$issue=908494+$n
      $transcript="synthetic-required-$n--claude-opus-5-5--medium.jsonl"
      $d=@{ts=$now.ToString('o');kind='dispatch';dispatchRoutingSchema='watchdog-dispatch-routing/v3';attemptId=$attempt;label=$attempt
        lane='synthetic';laneRole='implementation';transcript=$transcript;harness='claude';model='claude-opus-5-5';effort='medium';row='4'
        placement='override-Todd';worktree='D:\synthetic-capacity';branch=$branch;head=('a'*40);policyGeneration=1
        registryAuthorityDigest='synthetic';family='opus';slot='claude.primary';usedLastKnownGood=$false
        capacityForecastStatus='in-force';capacityDecisionDigest='0123456789abcdef';capacityShadowFlip=$null;capacityFlipSkip=$null
        capacityFlip=@{row=4;toward='claude';steps=3;from=@{harness='codex';family='sol';effort='high';slot='codex.primary'}
          to=@{harness='claude';family='opus';effort='medium';slot='claude.primary';placement='override-Todd'}}}
      Assert-True (Test-DispatchRoutingLedgerEvidence ($d|ConvertTo-Json -Depth 20|ConvertFrom-Json -DateKind String)) 'quarantine valid synthetic seed'
      # The issue is deliberately absent from v3. Only structured historical
      # branch/issue evidence can prevent the legacy fallback in this fixture.
      $history=@{ts=$now.AddMinutes(-1).ToString('o');kind='dispatch';issue=$issue;branch=$branch
        model=$d.model;effort=$d.effort;row='4';laneRole='implementation';attemptId="synthetic-historical-$n";transcript="synthetic-historical-$n.jsonl"}
      $events.Add($history)
      switch($case){
        'missing-kind' {$d.Remove('kind')}
        'extra-author-model' {$d.authorModel=$d.model}
        'wrong-kind' {$d.kind='verify-complete'}
        'review-role' {$d.laneRole='review'}
        'planning-role' {$d.laneRole='planning'}
        'unknown-role' {$d.laneRole='synthetic-unsupported'}
        'marker-extra-author' {$d.Remove('dispatchRoutingSchema');$d.authorModel=$d.model}
        'missing-transcript' {$d.Remove('transcript')}
        'unmatched-transcript' {$transcript="synthetic-unmatched-$n--claude-opus-5-5--medium.jsonl"}
        'ambiguous-branch' {$d.Remove('transcript');$other=$history.Clone();$other.issue=918494+$n;$events.Add($other)}
        'ambiguous-issue' {$d.Remove('transcript');$other=$history.Clone();$other.branch="synthetic/other-$n";$events.Add($other)}
      }
      $events.Add($d)
      $costs.Add(@{ts=$now.ToString('o');issue=$issue;transcript=$transcript;model='claude-opus-5-5';usdCurrent=10;usd=10;durationSec=60})
      $events.Add(@{ts=$now.AddSeconds(1).ToString('o');kind='review-complete';authorAttempt=$attempt;branch=$branch
        authorModel='claude-opus-5-5';authorEffort='medium';outcome='PASS'})
    }
    foreach($reverse in @($false,$true)){
      $rows=@($events);if($reverse){[array]::Reverse($rows)}
      Set-Content $dispatchPath -Value @($rows|ForEach-Object{$_|ConvertTo-Json -Depth 20 -Compress})
      Set-Content $ledgerPath -Value @($costs|ForEach-Object{$_|ConvertTo-Json -Compress})
      Invoke-Refresh|Out-Null;$m=Get-Matrix
      $key="row4`u{001f}claude-opus-5-5`u{001f}medium";$modelKey="row4`u{001f}claude-opus-5-5"
      Assert-True ($null -eq $m.measuredAt.byRowConfig.$key -and $null -eq $m.measuredAt.blockRateByRowConfig.$key) "quarantine ordinary excluded $case reverse=$reverse"
      if($case -eq 'valid-with-history'){
        Assert-True ($m.measuredAt.capacityFlipped.byRowConfig.$key.runs -eq 3 -and
          @($m.measuredAt.capacityIdentity.PSObject.Properties.Value|Where-Object{$_ -ne 0}).Count -eq 0) 'quarantine valid exact transcript retains flipped costs'
      } else {
        Assert-True ($null -eq $m.measuredAt.capacityFlipped.byRowConfig.$key -and $null -eq $m.measuredAt.byRowModel.$modelKey) "quarantine costs excluded $case reverse=$reverse"
        $suffix=if($case -like 'ambiguous-*'){'Ambiguous'}else{'Unresolved'}
        Assert-True ($m.measuredAt.capacityIdentity."costRows$suffix" -eq 3) "quarantine cost diagnostics $case reverse=$reverse"
      }
      if($case -in @('valid-with-history','unmatched-transcript')){
        Assert-True ($m.measuredAt.capacityFlipped.blockRateByRowConfig.$key.reviews -eq 3) "quarantine valid review join $case"
      } else {
        Assert-True ($null -eq $m.measuredAt.capacityFlipped.blockRateByRowConfig.$key -and
          $m.measuredAt.capacityIdentity.reviewRowsUnresolved -eq 3) "quarantine reviews excluded $case reverse=$reverse"
      }
    }
    Write-Output "PASS capacity quarantine $case both-orders"
  }
}
function Test-CapacityCalibration {
  Reset-Fixtures
  $events=[Collections.Generic.List[object]]::new();$costs=[Collections.Generic.List[object]]::new()
  $now=[DateTimeOffset]::UtcNow.AddMinutes(-5)
  foreach($n in 1..3) {
    foreach($cohort in @('flipped','ordinary','shadow')) {
      $attempt="synthetic-$cohort-$n";$branch="synthetic/$attempt"
      $d=@{ts=$now.ToString('o');kind='dispatch';attemptId=$attempt;branch=$branch;head=('a'*40)
        model='claude-opus-5-5';effort='medium';row='4';transcript="$attempt.jsonl";laneRole='implementation'
        dispatchRoutingSchema='watchdog-dispatch-routing/v3';label=$attempt;lane='synthetic';harness='claude';placement='override-Todd'
        worktree='D:\synthetic-capacity';policyGeneration=1;registryAuthorityDigest='synthetic';family='opus';slot='claude.primary';usedLastKnownGood=$false
        capacityForecastStatus=$(if($cohort -eq 'shadow'){'shadow'}else{'in-force'});capacityFlip=$null
        capacityDecisionDigest='0123456789abcdef';capacityShadowFlip=$null;capacityFlipSkip=$null}
      if($cohort -eq 'flipped'){$d.capacityFlip=@{row=4;toward='claude';steps=3;from=@{harness='codex';family='sol';effort='high';slot='codex.primary'};to=@{harness='claude';family='opus';effort='medium';slot='claude.primary';placement='override-Todd'}}}
      $events.Add($d);$events.Add($d) # exact duplicate evidence never doubles a root
      $costs.Add(@{ts=$now.ToString('o');transcript=$d.transcript;issue=$d.issue;model=$d.model;usdCurrent=10;usd=10;durationSec=60})
      $mechanical=$d.Clone();$mechanical.ts=$now.AddSeconds(1).ToString('o');$mechanical.transcript="$attempt-retry.jsonl"
      $mechanical.capacityForecastStatus='not-evaluated';$mechanical.capacityFlip=$null;$mechanical.capacityDecisionDigest=$null;$events.Add($mechanical)
      $costs.Add(@{ts=$now.ToString('o');transcript=$mechanical.transcript;issue=$d.issue;model=$d.model;usdCurrent=2;usd=2;durationSec=60})
      $quota=$mechanical.Clone();$quota.ts=$now.AddSeconds(2).ToString('o');$quota.model='gpt-6.1-sol';$quota.effort='high';$quota.transcript="$attempt-quota.jsonl"
      $quota.harness='codex';$quota.family='sol';$quota.slot='codex.primary';$events.Add($quota)
      foreach($author in @(@('claude-opus-5-5','medium'),@('gpt-6.1-sol','high'))) {
        $events.Add(@{ts=$now.AddSeconds(3).ToString('o');kind='review-complete';authorAttempt=$attempt;branch=$branch;authorModel=$author[0];authorEffort=$author[1];effort='max';outcome='PASS';issue=$d.issue})
      }
    }
  }
  $events.Add(@{ts=$now.AddSeconds(3).ToString('o');kind='review-complete';authorAttempt='unmatched';branch='synthetic/unmatched';authorModel='claude-opus-5-5';authorEffort='medium';outcome='BLOCK';issue=908495})
  function Save-CapacityFixture($Rows) {
    Set-Content $dispatchPath -Value @($Rows|ForEach-Object{$_|ConvertTo-Json -Depth 20 -Compress})
    Set-Content $ledgerPath -Value @($costs|ForEach-Object{$_|ConvertTo-Json -Compress})
  }
  Save-CapacityFixture $events;Invoke-Refresh|Out-Null;$m=Get-Matrix
  $key="row4`u{001f}claude-opus-5-5`u{001f}medium";$modelKey="row4`u{001f}claude-opus-5-5"
  Assert-True ($m.measuredAt.capacityFlipped.byRowConfig.$key.runs -eq 6 -and $m.measuredAt.capacityFlipped.byRowConfig.$key.usd -eq 36) 'flipped cost cohort joins exact transcript and retains mechanical continuation'
  Assert-True ($m.measuredAt.byRowConfig.$key.runs -eq 12 -and $m.measuredAt.byRowConfig.$key.usd -eq 72) 'ordinary and shadow costs exclude flips'
  Assert-True ($m.measuredAt.capacityFlipped.blockRateByRowConfig.$key.reviews -eq 3 -and
    $m.measuredAt.capacityFlipped.blockRateByRow.$modelKey.reviews -eq 3 -and
    $m.measuredAt.blockRateByRowConfig.$key.reviews -eq 6 -and $m.measuredAt.blockRateByRow.$modelKey.reviews -eq 6) 'multi-valued attempt join uses actual author configuration'
  Assert-True ($m.measuredAt.blockRateByRowConfig."row4`u{001f}gpt-6.1-sol`u{001f}high".reviews -eq 9 -and
    $m.measuredAt.capacityIdentity.reviewRowsUnresolved -eq 1) 'quota configuration remains ordinary; unmatched receipt visibly unresolved'
  $reversed=@($events);[array]::Reverse($reversed);Save-CapacityFixture $reversed;Invoke-Refresh|Out-Null;$other=Get-Matrix
  Assert-True ($other.measuredAt.capacityFlipped.byRowConfig.$key.usd -eq 36 -and $other.measuredAt.capacityFlipped.blockRateByRowConfig.$key.reviews -eq 3 -and $other.measuredAt.blockRateByRowConfig.$key.reviews -eq 6) 'capacity classification independent of log order'
  $conflict=$events[0].Clone();$conflict.transcript='synthetic-conflicting-root.jsonl';$conflict.capacityFlip=$null;$events.Add($conflict)
  $unbound=@{ts=$now.AddSeconds(4).ToString('o');kind='review-complete';branch='synthetic/synthetic-flipped-1';issue=908495;authorModel='claude-opus-5-5';authorEffort='medium';outcome='BLOCK'}
  $events.Add($unbound);Save-CapacityFixture $events;Invoke-Refresh|Out-Null;$ambiguous=Get-Matrix
  Assert-True ($ambiguous.measuredAt.capacityIdentity.reviewRowsAmbiguous -ge 1 -and $ambiguous.measuredAt.capacityIdentity.costRowsAmbiguous -ge 2 -and
    $ambiguous.measuredAt.capacityIdentity.reviewRowsUnresolved -ge 2) 'conflicting roots and unbound receipts visibly excluded'
  Assert-True ($null -eq $ambiguous.measuredAt.capacityFlipped.blockRateByRowConfig.$key) 'capacity cells retain the three-review minimum after ambiguous exclusion'
  $events[0].capacityFlip.to.effort='high';Save-CapacityFixture $events;Invoke-Refresh|Out-Null;$malformed=Get-Matrix
  Assert-True ($malformed.measuredAt.capacityIdentity.costRowsUnresolved -ge 2 -and $malformed.measuredAt.capacityIdentity.reviewRowsUnresolved -ge 3) 'malformed retained v3 cannot supply calibration authority'
  Write-Output 'PASS capacity calibration exact transcript, multi-valued attempts, mechanical/quota continuation, shadow, unmatched and reordered controls'
  Test-CapacityClosedEvidence
  Test-CapacityQuarantine
  if(-not $RefreshPath){
    $mutantRoot=if($EvidenceDir){[IO.Path]::GetFullPath($EvidenceDir)}else{Join-Path $testRoot 'capacity-mutant'}
    [void][IO.Directory]::CreateDirectory($mutantRoot)
    Get-ChildItem -LiteralPath $PSScriptRoot -File|Where-Object Extension -in @('.ps1','.psm1')|Copy-Item -Destination $mutantRoot
    $source=[IO.File]::ReadAllText($refresh)
    foreach($mutation in @(
      @{name='last-dispatch-wins';old='$origin=$roots[0]';new='$origin=@($unique.Values|Sort-Object ts)[-1]';assertion='flipped cost cohort'},
      @{name='missing-status-ordinary';old='modern=(@($rows|Where-Object{Test-CapacityRoutingRecord $_}).Count -gt 0)';new='modern=(@($rows|Where-Object{$_.PSObject.Properties[''capacityForecastStatus'']}).Count -gt 0)';assertion='closed evidence excluded missing-capacityForecastStatus'},
      @{name='partial-evidence-dedup';old='$identity=ConvertTo-CapacityCanonicalValue $e | ConvertTo-Json -Depth 100 -Compress';new='$identity=@($e.ts,$e.transcript,$e.head,$e.capacityForecastStatus,(ConvertTo-CapacityCanonicalValue $e.capacityFlip|ConvertTo-Json -Depth 12 -Compress)) -join "`u{001f}"';assertion='closed evidence excluded conflicting-shadow'},
      @{name='quarantine-after-author-filter';old="if(-not (Test-CapacityRoutingRecord `$e) -and (`$e.kind -cne 'dispatch' -or `$e.laneRole -cin @('review','planning') -or `$e.authorModel)){continue}";new="if(`$e.kind -cne 'dispatch' -or `$e.laneRole -cin @('review','planning') -or `$e.authorModel){continue}";assertion='quarantine ordinary excluded missing-kind';quarantineOnly=$true},
      @{name='legacy-issue-fallback';old='foreach($branch in $capacityModernBranches){';new='foreach($branch in @()){';assertion='quarantine ordinary excluded missing-transcript';quarantineOnly=$true}
    )){
      Assert-True ($source.Contains($mutation.old)) "calibration mutation seam $($mutation.name)"
      $mutant=Join-Path $mutantRoot 'matrix-refresh.ps1'
      [IO.File]::WriteAllText($mutant,$source.Replace($mutation.old,$mutation.new))
      $log=Join-Path $mutantRoot "$($mutation.name).log"
      if($mutation.quarantineOnly){
        & pwsh -NoProfile -NonInteractive -File $PSCommandPath -CapacityQuarantineOnly -RefreshPath $mutant *> $log
      } else {
        & pwsh -NoProfile -NonInteractive -File $PSCommandPath -CapacityOnly -RefreshPath $mutant *> $log
      }
      $code=$LASTEXITCODE
      Copy-Item $mutant (Join-Path $mutantRoot "$($mutation.name).ps1")
      Assert-True ($code -eq 1 -and ([IO.File]::ReadAllText($log)).Contains("ASSERTION FAILED: $($mutation.assertion)")) "$($mutation.name) mutant killed"
      Write-Output "PASS capacity calibration mutant=$($mutation.name) exit=$code"
    }
  }
}
if($CapacityQuarantineOnly){Test-CapacityQuarantine;return}
if($CapacityOnly){Test-CapacityCalibration;return}

# --- 1. measured facts are generated from telemetry ------------------------
Reset-Fixtures
$r = Invoke-Refresh
$m = Get-Matrix
$sol = $m.configs | Where-Object { $_.id -eq "gpt-5.6-sol/high" }
Assert-True ([math]::Abs($sol.measured.usdPerRun - 7.0) -lt 0.01) "usdPerRun generated from ledger (got $($sol.measured.usdPerRun), expected 7.00)"
Assert-True ($sol.measured.n -eq 2) "n counts exact-version runs only (got $($sol.measured.n))"
Assert-True ([math]::Abs($sol.measured.medianMin - 20.0) -lt 0.1) "medianMin from durations (got $($sol.measured.medianMin), expected 20)"
Assert-True ($m.measuredAt.costBasis -eq "current-price-normalized") "matrix records the routing cost basis"
Assert-True ($sol.measured.basis -eq "model+effort") "a measured block names its configuration basis"
# The install merge (controller-install-lock.psm1) transfers generated blocks
# only between matrices stamped with the same schema; the producer of that
# marker is this script, so its emission is pinned here, not by the consumer.
Assert-True ($m.measuredAt.generatedSchema -ceq "measured-by-configuration/v1") "the stamp names the generated schema the install merge gates on (got $($m.measuredAt.generatedSchema))"
Write-Output "PASS matrix-refresh generates measured cost/speed from telemetry"

# --- 1b. measured blocks are per CONFIGURATION, never pooled per model ------
# Before v4.13 gpt-5.6-sol/xhigh reported Sol's whole sample as its own n, so an effort
# cell could never be falsified. Now a config with no effort-resolved run has
# no measured block at all, and the pooled figure is labeled as such elsewhere.
$solXhigh = $m.configs | Where-Object { $_.id -eq "gpt-5.6-sol/xhigh" }
Assert-True ($null -eq $solXhigh.PSObject.Properties["measured"]) "a configuration with no runs at its effort carries no measured block (stale pooled block removed)"
Assert-True (@($m.measuredAt.configsWithoutEffortEvidence) -contains "gpt-5.6-sol/xhigh") "configs without effort-resolved evidence are listed"
Assert-True ($m.measuredAt.byModel."gpt-5.6-sol".n -eq 2) "pooled per-model facts remain readable under byModel"
Assert-True ($m.measuredAt.effortIdentity.byDispatchTranscript -eq 3 -and $m.measuredAt.effortIdentity.ledgerRunsUnresolved -eq 0) "every fixture run resolved its effort through its dispatch row (got $($m.measuredAt.effortIdentity | ConvertTo-Json -Compress))"
Write-Output "PASS matrix-refresh keys measured blocks by configuration"

# --- 2. ambiguous aliases and deprecated versions are excluded -------------
Assert-True ($sol.measured.n -eq 2 -and [math]::Abs($sol.measured.usdPerRun - 7.0) -lt 0.01) "ambiguous 'sol' row cannot poison exact gpt-5.6-sol evidence"
$sonnet = $m.configs | Where-Object { $_.id -eq "claude-sonnet-5/medium" }
Assert-True ($sonnet.measured.n -eq 1) "exact claude-sonnet-5 remains measurable (got n=$($sonnet.measured.n))"
Assert-True ($m.measuredAt.modelIdentityRowsExcluded -eq 2) "ambiguous alias and deprecated Opus 4.8 are excluded"
Assert-True ([math]::Abs($m.measuredAt.modelIdentityUsdExcluded - 110.0) -lt 0.01) "excluded normalized cost remains visible without entering selection evidence"
Write-Output "PASS matrix-refresh enforces exact model-version evidence identity"

# --- 3. AUTHORED content is never touched ----------------------------------
Assert-True ($m.dimensions[0].cells."claude-fable-5/high".veto -eq $true) "authored veto survives refresh"
Assert-True ($m.dimensions[0].cells."claude-fable-5/high".reason -eq "authored veto that must survive") "authored veto reason survives"
Assert-True ($m.dimensions[0].cells."gpt-5.6-sol/high".score -eq 0) "authored score survives"
Assert-True ($m.dimensions[0].bar -eq 99) "authored bar survives"
Write-Output "PASS matrix-refresh preserves authored scores, vetoes and bars"

# --- 4. legacy hand-written cost fields are removed ------------------------
# Two sources for one number is a staleness trap; the generated block wins.
Assert-True ($null -eq $sol.PSObject.Properties["usdPerRun"]) "legacy usdPerRun stripped"
Assert-True ($null -eq $sol.PSObject.Properties["usdN"]) "legacy usdN stripped"
Assert-True ($null -eq $sol.PSObject.Properties["usdPerArtifact"]) "legacy usdPerArtifact stripped"
Write-Output "PASS matrix-refresh strips hand-written fields it supersedes"

# --- 5. row costs join through both row and routingRow spellings -----------
Assert-True ($null -ne $m.measuredAt.byRow."4") "row 4 costed"
Assert-True ($m.measuredAt.byRow."4".runs -eq 2) "legacy routingRow spelling still joins (got $($m.measuredAt.byRow.'4'.runs))"
Assert-True ([math]::Abs($m.measuredAt.byRow."4".usd - 14.0) -lt 0.01) "row 4 total is both runs (got $($m.measuredAt.byRow.'4'.usd))"
Write-Output "PASS matrix-refresh joins cost to rows across row/routingRow spellings"

# --- 5b. cost splits by row AND model --------------------------------------
# byRow pools every model on the row, so it cannot answer what a single config
# costs on the row it is being judged on — which is how P1 ("<=50% USD/artifact"
# on row 8) and P2 ("<=60%" on row 7) are both written. Without this cell every
# adjudication has to recompute the split by hand from the raw ledger.
function Get-RowModelCell([object]$Matrix, [string]$Row, [string]$Model) {
  foreach ($p in $Matrix.measuredAt.byRowModel.PSObject.Properties) {
    if ($p.Value.row -eq $Row -and $p.Value.model -eq $Model) { return $p.Value }
  }
  return $null
}
$solRow4 = Get-RowModelCell $m "4" "gpt-5.6-sol"
Assert-True ($null -ne $solRow4) "row 4 x gpt-5.6-sol cell exists"
Assert-True ($solRow4.runs -eq 2) "row x model cell counts only that model's runs (got $($solRow4.runs))"
Assert-True ([math]::Abs($solRow4.usdPerRun - 7.0) -lt 0.01) "row x model usdPerRun is that model's own (got $($solRow4.usdPerRun))"
$sonnetRow3 = Get-RowModelCell $m "3" "claude-sonnet-5"
Assert-True ($sonnetRow3.runs -eq 1 -and [math]::Abs($sonnetRow3.usdPerRun - 4.0) -lt 0.01) "a second config on a different row keeps its own cell"
Assert-True ($null -eq (Get-RowModelCell $m "4" "claude-sonnet-5")) "no cell is invented for a config that never ran the row"
Write-Output "PASS matrix-refresh splits cost by row and model, not just by row"

# --- 5c. cost splits by row AND configuration ------------------------------
# byRowModel still pools every effort of a model, so it cannot compare the
# challenger `gpt-5.6-sol/medium` with the incumbent `gpt-5.6-sol/high` on row 4 — which is how
# every quota threshold is written. byRowConfig is that comparison.
function Get-RowConfigCell([object]$Matrix, [string]$Row, [string]$Model, [string]$Effort) {
  foreach ($p in $Matrix.measuredAt.byRowConfig.PSObject.Properties) {
    if ($p.Value.row -eq $Row -and $p.Value.model -eq $Model -and $p.Value.effort -eq $Effort) { return $p.Value }
  }
  return $null
}
$solHighRow4 = Get-RowConfigCell $m "4" "gpt-5.6-sol" "high"
Assert-True ($null -ne $solHighRow4 -and $solHighRow4.runs -eq 2 -and [math]::Abs($solHighRow4.usdPerRun - 7.0) -lt 0.01) "row x configuration cell carries that configuration's own runs"
Assert-True ($null -eq (Get-RowConfigCell $m "4" "gpt-5.6-sol" "xhigh")) "no row x configuration cell is invented for an effort that never ran"
Write-Output "PASS matrix-refresh splits cost by row and configuration"

# --- 6. version-EXPLICIT spellings are recovered, bare families are not -----
# The fixture carries four author spellings: sonnet-5 (BLOCK), claude-sonnet-5
# (PASS), "Sonnet 5" (PASS) and bare sonnet (PASS).
#
# The first three name the same version and differ only in punctuation, so they
# are one config's evidence; excluding them cost ~42% of Sonnet's real review
# sample, and because only Claude configs were ever mis-spelled, the loss landed
# entirely on one side of the comparisons the experiments turn on.
#
# Bare `sonnet` names no version and stays out: resolving it would be a guess,
# and a guess is how evidence silently transfers to a successor model.
$br = $m.measuredAt.blockRateByAuthor."claude-sonnet-5"
Assert-True ($br.reviews -eq 3) "version-explicit spellings join one config's evidence (got $($br.reviews))"
Assert-True ([math]::Abs($br.blockRate - 0.33) -lt 0.01) "recovered rows carry their own outcomes (got $($br.blockRate))"

$audit = $m.measuredAt.modelIdentityAudit
Assert-True ($null -ne $audit."sonnet" -and $null -eq $audit."sonnet".canonical) "bare family alias stays unresolved"
Assert-True ($audit."sonnet-5".canonical -eq "claude-sonnet-5") "version-explicit spelling is audited as repaired"
Assert-True ($audit."sonnet-5".repaired -eq $true) "repair is reported, not silent"
Write-Output "PASS matrix-refresh recovers version-explicit spellings and still excludes bare aliases"

# --- 6b. mechanical failures are not author-quality blocks -----------------
# A harness fault, a prompt block, or a failure reproducing on clean main all
# begin with BLOCK/FAILED and were swallowed by a generic ^BLOCK match, charging
# whichever config drew the flaky infrastructure with a quality defect.
Reset-Fixtures
$ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
Set-Content -LiteralPath $dispatchPath -Value @(
  (@{ ts=$ts; kind="verify-complete"; pr=20; authorModel="claude-opus-5"; outcome="PASS" } | ConvertTo-Json -Compress),
  (@{ ts=$ts; kind="verify-complete"; pr=21; authorModel="claude-opus-5"; outcome="BLOCK" } | ConvertTo-Json -Compress),
  (@{ ts=$ts; kind="verify-complete"; pr=22; authorModel="claude-opus-5"; outcome="BLOCKED_MECHANICAL" } | ConvertTo-Json -Compress),
  (@{ ts=$ts; kind="verify-complete"; pr=23; authorModel="claude-opus-5"; outcome="MECHANICAL_PROMPT_BLOCK" } | ConvertTo-Json -Compress),
  (@{ ts=$ts; kind="verify-complete"; pr=24; authorModel="claude-opus-5"; outcome="FAILED_CLEAN_MAIN" } | ConvertTo-Json -Compress),
  (@{ ts=$ts; kind="verify-complete"; pr=25; authorModel="claude-opus-5"; outcome="REJECT" } | ConvertTo-Json -Compress)
)
Invoke-Refresh | Out-Null
$mech = (Get-Matrix)
$obr = $mech.measuredAt.blockRateByAuthor."claude-opus-5"
Assert-True ($obr.reviews -eq 3) "three mechanical rows leave the denominator (got $($obr.reviews))"
Assert-True ($obr.blocks -eq 2) "BLOCK and REJECT are author blocks (got $($obr.blocks))"
Assert-True ($mech.measuredAt.mechanicalExcluded -eq 3) "mechanical exclusions are counted, not hidden (got $($mech.measuredAt.mechanicalExcluded))"
Write-Output "PASS matrix-refresh scores mechanical failures against the harness, not the author"

# --- 6c. controller review authority is conserved without poisoning routing --
Reset-Fixtures
$governingRows=@(New-StrictMatrixPair governing PASS 'matrix-governing' 210)
Import-Module (Join-Path $PSScriptRoot 'review-head-contract.psm1') -Force -DisableNameChecking
$governingClasses=@($governingRows|ForEach-Object{Get-ControllerReviewRowClassification (($_|ConvertTo-Json -Compress -Depth 10)|ConvertFrom-Json -Depth 10 -DateKind String)})
Assert-True (@($governingClasses|Where-Object{-not$_.strict-or-not$_.valid}).Count-eq0) "governing matrix fixture must be closed strict rows: $($governingClasses|ConvertTo-Json -Compress -Depth 10)"
$governingRows|ForEach-Object{$_|ConvertTo-Json -Compress -Depth 10}|Set-Content -LiteralPath $dispatchPath
Invoke-Refresh|Out-Null
$governingProjection=((Get-Matrix).measuredAt.blockRateByAuthor|ConvertTo-Json -Compress -Depth 10)
$authorityRows=@($governingRows)+@(New-StrictMatrixPair shadow BLOCK_FIXABLE 'matrix-shadow' 211)+@(New-StrictMatrixPair advisory BLOCK_REPLAN 'matrix-advisory' 212)
$authorityRows|ForEach-Object{$_|ConvertTo-Json -Compress -Depth 10}|Set-Content -LiteralPath $dispatchPath
Invoke-Refresh|Out-Null
$authorityMatrix=Get-Matrix
$authorityProjection=$authorityMatrix.measuredAt.blockRateByAuthor|ConvertTo-Json -Compress -Depth 10
Assert-True ($authorityProjection-ceq$governingProjection) "shadow/advisory controller outcomes must not change authored block-rate evidence"
$authoritySol=$authorityMatrix.measuredAt.blockRateByAuthor.'gpt-5.6-sol'
Assert-True ($authoritySol.reviews-eq1-and$authoritySol.blocks-eq0) "only the governing strict PASS enters routing evidence: $($authorityMatrix.measuredAt.blockRateByAuthor|ConvertTo-Json -Compress -Depth 10)"
Write-Output "PASS matrix-refresh conserves governing evidence while excluding shadow/advisory outcomes"

# --- 7. -DryRun writes nothing ---------------------------------------------
Reset-Fixtures
$before = Get-Content -LiteralPath $matrixPath -Raw
$r = Invoke-Refresh -DryRun
Assert-True ($r.dryRun -eq $true) "dryRun reported"
Assert-True ((Get-Content -LiteralPath $matrixPath -Raw) -eq $before) "-DryRun leaves the matrix byte-identical"
Write-Output "PASS matrix-refresh -DryRun writes nothing"

# --- 8. idempotent: refreshing twice yields the same measured values -------
Reset-Fixtures
Invoke-Refresh | Out-Null
$first = (Get-Matrix).configs | Where-Object { $_.id -eq "gpt-5.6-sol/high" }
Invoke-Refresh | Out-Null
$second = (Get-Matrix).configs | Where-Object { $_.id -eq "gpt-5.6-sol/high" }
Assert-True ($first.measured.usdPerRun -eq $second.measured.usdPerRun) "repeat refresh is stable"
Assert-True ($first.measured.n -eq $second.measured.n) "repeat refresh does not double-count"
Write-Output "PASS matrix-refresh is idempotent"

# --- 9. drift alarm fires when a measured value moves materially ----------
Reset-Fixtures
Invoke-Refresh -Adjudicate | Out-Null   # freeze $7.00/run as baseline
$now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
Add-Content -LiteralPath $ledgerPath -Encoding utf8 `
  -Value (@{ ts=$now; transcript="d.jsonl"; issue=103; model="gpt-5.6-sol"; usd=40.0; durationSec=600; costSource="token-derived" } | ConvertTo-Json -Compress)
Add-Content -LiteralPath $dispatchPath -Encoding utf8 `
  -Value (@{ ts=$now; kind="dispatch"; issue=103; model="gpt-5.6-sol"; effort="high"; transcript="d.jsonl"; row="4" } | ConvertTo-Json -Compress)
$r = Invoke-Refresh
Assert-True ($r.driftAlerts.Count -ge 1) "drift alarm fires on a material move"
$alert = $r.driftAlerts | Where-Object { $_.config -eq "gpt-5.6-sol/high" }
Assert-True ($null -ne $alert) "drift alert names the config"
Assert-True ($alert.was -lt $alert.now) "drift alert carries before and after"
Write-Output "PASS matrix-refresh drift alarm fires on material change"

# --- 10. no alarm when the move is within tolerance ------------------------
Reset-Fixtures
Invoke-Refresh -Adjudicate | Out-Null
$r = Invoke-Refresh -DriftPct 25
Assert-True ($r.driftAlerts.Count -eq 0) "no drift alarm when nothing moved"
Write-Output "PASS matrix-refresh stays quiet when values are stable"

# --- 11. indeterminate outcomes are excluded, not counted as passes --------
# "anything not BLOCK*" silently scored RETRY/skip/LOAD_SENSITIVE as wins and
# biased every block rate downward.
Reset-Fixtures
$now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
Add-Content -LiteralPath $dispatchPath -Encoding utf8 -Value @(
  (@{ ts=$now; kind="review-complete"; pr=10; authorModel="claude-fable-5"; outcome="BLOCK" } | ConvertTo-Json -Compress),
  (@{ ts=$now; kind="review-complete"; pr=11; authorModel="claude-fable-5"; outcome="block" } | ConvertTo-Json -Compress),
  (@{ ts=$now; kind="review-complete"; pr=12; authorModel="claude-fable-5"; outcome="RETRY" } | ConvertTo-Json -Compress),
  (@{ ts=$now; kind="review-complete"; pr=13; authorModel="claude-fable-5"; outcome="LOAD_SENSITIVE" } | ConvertTo-Json -Compress),
  (@{ ts=$now; kind="review-complete"; pr=14; authorModel="claude-fable-5"; outcome="PASS_CI" } | ConvertTo-Json -Compress)
)
Invoke-Refresh | Out-Null
$fb = (Get-Matrix).measuredAt.blockRateByAuthor."claude-fable-5"
Assert-True ($fb.reviews -eq 3) "RETRY and LOAD_SENSITIVE excluded from the denominator (got n=$($fb.reviews), expected 3)"
Assert-True ($fb.blocks -eq 2) "lowercase 'block' counted as a block (got $($fb.blocks))"
Assert-True ([math]::Abs($fb.blockRate - 0.67) -lt 0.01) "block rate over determinate outcomes only (got $($fb.blockRate))"
Assert-True ((Get-Matrix).measuredAt.outcomesExcluded -ge 2) "excluded count reported"
Write-Output "PASS matrix-refresh excludes indeterminate outcomes and is case-insensitive"

# --- 12. block rate is stratified by row -----------------------------------
Reset-Fixtures
$now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
Add-Content -LiteralPath $dispatchPath -Encoding utf8 -Value @(
  (@{ ts=$now; kind="review-complete"; issue=100; authorModel="gpt-5.6-sol"; outcome="BLOCK" } | ConvertTo-Json -Compress),
  (@{ ts=$now; kind="review-complete"; issue=100; authorModel="gpt-5.6-sol"; outcome="PASS"  } | ConvertTo-Json -Compress),
  (@{ ts=$now; kind="review-complete"; issue=100; authorModel="gpt-5.6-sol"; outcome="PASS"  } | ConvertTo-Json -Compress),
  (@{ ts=$now; kind="review-complete"; issue=100; authorModel="sol";         outcome="PASS"  } | ConvertTo-Json -Compress)
)
Invoke-Refresh | Out-Null
$rows = (Get-Matrix).measuredAt.blockRateByRow
$cellName = ($rows.PSObject.Properties | Where-Object { $_.Value.row -eq "4" -and $_.Value.model -eq "gpt-5.6-sol" } | Select-Object -First 1)
Assert-True ($null -ne $cellName) "per-row block-rate cell emitted for row 4 / sol"
Assert-True ($cellName.Value.reviews -eq 3) "row cell excludes the ambiguous alias review (got $($cellName.Value.reviews))"
Assert-True ([math]::Abs($cellName.Value.blockRate - 0.33) -lt 0.01) "row-stratified block rate uses exact-version evidence only (got $($cellName.Value.blockRate))"
# The receipts name no authorEffort; issue 100's only author dispatch ran Sol
# at high, so the author configuration resolves without a guess.
$cfgCell = ((Get-Matrix).measuredAt.blockRateByRowConfig.PSObject.Properties | Where-Object { $_.Value.row -eq "4" -and $_.Value.model -eq "gpt-5.6-sol" -and $_.Value.effort -eq "high" } | Select-Object -First 1)
Assert-True ($null -ne $cfgCell -and $cfgCell.Value.reviews -eq 3 -and [math]::Abs($cfgCell.Value.blockRate - 0.33) -lt 0.01) "row x author-configuration block rate resolves the author's effort from its unique dispatch"
Write-Output "PASS matrix-refresh stratifies block rate by routing row and configuration"

# --- 13. effort identity: resolve, never guess ------------------------------
Reset-Fixtures
$m = Get-Matrix
$m.configs += [pscustomobject]@{ id="gpt-5.6-sol/medium"; model="gpt-5.6-sol"; effort="medium"; harness="codex" }
Set-Content -LiteralPath $matrixPath -Encoding utf8 -Value ($m | ConvertTo-Json -Depth 20)
$t0 = [datetime]::UtcNow
$ts = { param([int]$Minutes) $t0.AddMinutes($Minutes).ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'") }
Add-Content -LiteralPath $ledgerPath -Encoding utf8 -Value @(
  # No dispatch row: the transcript name's <issue>-<model>-<effort>- token resolves it.
  (@{ ts=(& $ts 0); transcript="7001-sol-medium-scoped-fix-r1.jsonl"; issue=7001; model="gpt-5.6-sol"; usd=2.0; usdCurrent=2.0; durationSec=120; costSource="token-derived" } | ConvertTo-Json -Compress),
  # Astra's double-hyphen delimiter is the only accepted Astra spelling.
  (@{ ts=(& $ts 0); transcript="7002-gpt-6-astra--high-cutover-r1.jsonl"; issue=7002; model="gpt-6-astra"; usd=9.0; usdCurrent=9.0; durationSec=120; costSource="token-derived" } | ConvertTo-Json -Compress),
  # Neither a dispatch row nor a parseable name: counts for the model, for no configuration.
  (@{ ts=(& $ts 0); transcript="mystery.jsonl"; issue=7003; model="gpt-5.6-sol"; usd=50.0; usdCurrent=50.0; durationSec=120; costSource="token-derived" } | ConvertTo-Json -Compress),
  # effortUsed wins over the requested effort.
  (@{ ts=(& $ts 0); transcript="e.jsonl"; issue=7004; model="gpt-5.6-sol"; usd=3.0; usdCurrent=3.0; durationSec=120; costSource="token-derived" } | ConvertTo-Json -Compress)
)
Add-Content -LiteralPath $dispatchPath -Encoding utf8 -Value @(
  (@{ ts=(& $ts 0); kind="dispatch"; issue=7004; model="gpt-5.6-sol"; effort="high"; effortUsed="medium"; transcript="e.jsonl"; row="4" } | ConvertTo-Json -Compress),
  # Issue 7010: author ran Sol medium, then Sol high, both BEFORE the receipt -> ambiguous.
  (@{ ts=(& $ts 1); kind="dispatch"; issue=7010; model="gpt-5.6-sol"; effort="medium"; transcript="7010-a.jsonl"; row="4"; laneRole="implementation" } | ConvertTo-Json -Compress),
  (@{ ts=(& $ts 2); kind="dispatch"; issue=7010; model="gpt-5.6-sol"; effort="high"; transcript="7010-b.jsonl"; row="4"; laneRole="implementation" } | ConvertTo-Json -Compress),
  (@{ ts=(& $ts 3); kind="review-complete"; issue=7010; authorModel="gpt-5.6-sol"; model="claude-opus-5"; effort="high"; outcome="PASS" } | ConvertTo-Json -Compress),
  # Issue 7011: one author dispatch before the receipt, a different effort AFTER it -> still unique.
  (@{ ts=(& $ts 1); kind="dispatch"; issue=7011; model="gpt-5.6-sol"; effort="medium"; transcript="7011-a.jsonl"; row="4"; laneRole="implementation" } | ConvertTo-Json -Compress),
  (@{ ts=(& $ts 2); kind="review-complete"; issue=7011; authorModel="gpt-5.6-sol"; model="claude-opus-5"; effort="high"; outcome="BLOCK" } | ConvertTo-Json -Compress),
  (@{ ts=(& $ts 3); kind="dispatch"; issue=7011; model="gpt-5.6-sol"; effort="high"; transcript="7011-b.jsonl"; row="4"; laneRole="implementation" } | ConvertTo-Json -Compress),
  # A review dispatch for the same issue names the reviewer's model, not the author's: ignored for author effort.
  (@{ ts=(& $ts 1); kind="dispatch"; issue=7011; model="gpt-5.6-sol"; authorModel="gpt-5.6-sol"; effort="xhigh"; transcript="7011-review.jsonl"; row="11"; laneRole="review" } | ConvertTo-Json -Compress),
  # Issue 7012: the receipt's own authorEffort field wins outright, even against dispatch history.
  (@{ ts=(& $ts 1); kind="dispatch"; issue=7012; model="gpt-5.6-sol"; effort="high"; transcript="7012-a.jsonl"; row="4"; laneRole="implementation" } | ConvertTo-Json -Compress),
  (@{ ts=(& $ts 2); kind="review-complete"; issue=7012; authorModel="gpt-5.6-sol"; authorEffort="medium"; model="claude-opus-5"; effort="high"; outcome="PASS" } | ConvertTo-Json -Compress),
  (@{ ts=(& $ts 2); kind="review-complete"; issue=7012; authorModel="gpt-5.6-sol"; authorEffort="medium"; model="claude-opus-5"; effort="high"; outcome="PASS" } | ConvertTo-Json -Compress),
  # Issue 7013 on row 5: only two determinate receipts, so both the row cell and the row x configuration cell stay below the n>=3 floor and are suppressed.
  (@{ ts=(& $ts 1); kind="dispatch"; issue=7013; model="gpt-5.6-sol"; effort="xhigh"; transcript="7013-a.jsonl"; row="5"; laneRole="implementation" } | ConvertTo-Json -Compress),
  (@{ ts=(& $ts 2); kind="review-complete"; issue=7013; authorModel="gpt-5.6-sol"; model="claude-opus-5"; effort="high"; outcome="PASS" } | ConvertTo-Json -Compress),
  (@{ ts=(& $ts 2); kind="review-complete"; issue=7013; authorModel="gpt-5.6-sol"; model="claude-opus-5"; effort="high"; outcome="BLOCK" } | ConvertTo-Json -Compress)
)
Invoke-Refresh | Out-Null
$m = Get-Matrix
$solMedium = $m.configs | Where-Object { $_.id -eq "gpt-5.6-sol/medium" }
$solHigh = $m.configs | Where-Object { $_.id -eq "gpt-5.6-sol/high" }
Assert-True ($solMedium.measured.n -eq 2 -and [math]::Abs($solMedium.measured.usdPerRun - 2.5) -lt 0.01) "name-parsed effort and effortUsed both key runs to gpt-5.6-sol/medium (got n=$($solMedium.measured.n), usd=$($solMedium.measured.usdPerRun))"
Assert-True ($solHigh.measured.n -eq 2) "the unresolved run and the effortUsed=medium run never reach gpt-5.6-sol/high (got n=$($solHigh.measured.n))"
Assert-True ($m.measuredAt.byModel."gpt-5.6-sol".n -eq 5) "the unresolved run still counts for its model (got $($m.measuredAt.byModel.'gpt-5.6-sol'.n))"
$ei = $m.measuredAt.effortIdentity
Assert-True ($ei.byTranscriptName -eq 2 -and $ei.ledgerRunsUnresolved -eq 1 -and [math]::Abs($ei.ledgerUsdUnresolved - 50.0) -lt 0.01) "effort identity audit counts name-resolved and unresolved runs with their USD (got $($ei | ConvertTo-Json -Compress))"
Assert-True ($ei.reviewRowsAmbiguous -eq 1 -and $ei.byUniqueAuthorDispatch -eq 3 -and $ei.byAuthorEffortField -eq 2) "receipt author effort: one ambiguous, three unique by dispatch, two by field (got $($ei | ConvertTo-Json -Compress))"
$cfgCells = @($m.measuredAt.blockRateByRowConfig.PSObject.Properties | Where-Object { $_.Value.row -eq "4" -and $_.Value.model -eq "gpt-5.6-sol" })
Assert-True (@($cfgCells | Where-Object { $_.Value.effort -eq "medium" }).Count -eq 1 -and @($cfgCells | Where-Object { $_.Value.effort -eq "medium" })[0].Value.reviews -eq 3) "row 4 x gpt-5.6-sol/medium collects the unique-dispatch receipt and both authorEffort receipts, never the ambiguous one (got $($cfgCells | ForEach-Object { $_.Value } | ConvertTo-Json -Compress))"
Assert-True (@($cfgCells | Where-Object { $_.Value.effort -eq "high" }).Count -eq 0) "the ambiguous receipt is not guessed onto gpt-5.6-sol/high"
$rowSol = ($m.measuredAt.blockRateByRow.PSObject.Properties | Where-Object { $_.Value.row -eq "4" -and $_.Value.model -eq "gpt-5.6-sol" } | Select-Object -First 1).Value
Assert-True ($null -ne $rowSol -and $rowSol.reviews -eq 4 -and $m.measuredAt.blockRateByAuthor."gpt-5.6-sol".reviews -eq 6) "an ambiguous or unresolved author effort still counts the receipt for the model and the row (got row=$($rowSol | ConvertTo-Json -Compress))"
# Below three determinate receipts a cell is noise and is suppressed, in both tables.
Assert-True ($null -eq ($m.measuredAt.blockRateByRow.PSObject.Properties | Where-Object { $_.Value.row -eq "5" -and $_.Value.model -eq "gpt-5.6-sol" })) "a two-review row cell is suppressed"
Assert-True ($null -eq ($m.measuredAt.blockRateByRowConfig.PSObject.Properties | Where-Object { $_.Value.row -eq "5" -and $_.Value.effort -eq "xhigh" })) "a two-review row x configuration cell is suppressed"
Write-Output "PASS matrix-refresh resolves effort identity from dispatch, name, or field and never guesses"

# Integer-major GPT identities must not disappear or inherit Sol's measurements.
Reset-Fixtures
$m = Get-Matrix
$m.configs += [pscustomobject]@{ id='gpt-6-astra/high';model='gpt-6-astra';effort='high';harness='codex' }
$m | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $matrixPath -Encoding utf8
$now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
@{ ts=$now;transcript='astra.jsonl';issue=200;model='gpt-6-astra';usd=12.0;usdCurrent=12.0;durationSec=120;costSource='token-derived' } | ConvertTo-Json -Compress | Add-Content -LiteralPath $ledgerPath
@{ ts=$now;kind='dispatch';issue=200;model='gpt-6-astra';effort='high';transcript='astra.jsonl';row='4' } | ConvertTo-Json -Compress | Add-Content -LiteralPath $dispatchPath
Invoke-Refresh | Out-Null
$m = Get-Matrix
$astra = $m.configs | Where-Object id -eq 'gpt-6-astra/high'
$sol = $m.configs | Where-Object id -eq 'gpt-5.6-sol/high'
Assert-True ($astra.measured.n -eq 1 -and $astra.measured.usdPerRun -eq 12) 'Astra integer-major identity retains its own cost cell'
Assert-True ($sol.measured.n -eq 2 -and $sol.measured.usdPerRun -eq 7) 'Astra does not contaminate Sol measurements'
Write-Output 'PASS matrix-refresh preserves independent Astra identity'

# A successor starts empty, then accumulates only its own exact-version facts.
Reset-Fixtures
$m = Get-Matrix
$m.configs += [pscustomobject]@{ id="claude-fable-5-1/high"; model="claude-fable-5-1"; effort="high"; harness="claude" }
Set-Content -LiteralPath $matrixPath -Encoding utf8 -Value ($m | ConvertTo-Json -Depth 20)
$now = [datetime]::UtcNow.ToString("o")
Add-Content -LiteralPath $ledgerPath -Encoding utf8 -Value (
  @{ ts=$now; transcript="old-fable.jsonl"; model="claude-fable-5"; usd=30.0; durationSec=600; costSource="stream-json" } | ConvertTo-Json -Compress)
Add-Content -LiteralPath $dispatchPath -Encoding utf8 -Value (
  @{ ts=$now; kind="dispatch"; model="claude-fable-5"; effort="high"; transcript="old-fable.jsonl" } | ConvertTo-Json -Compress)
Invoke-Refresh | Out-Null
$fresh = (Get-Matrix).configs | Where-Object id -eq "claude-fable-5-1/high"
Assert-True ($null -eq $fresh.measured) "Fable 5.1 inherits no Fable 5 measurements"
foreach ($spelling in @("claude-fable-5-1", "Fable 5.1", "fable-5-1")) {
  Add-Content -LiteralPath $ledgerPath -Encoding utf8 -Value (
    @{ ts=$now; transcript="$spelling.jsonl"; model=$spelling; usd=3.0; durationSec=60; costSource="stream-json" } | ConvertTo-Json -Compress)
  Add-Content -LiteralPath $dispatchPath -Encoding utf8 -Value (
    @{ ts=$now; kind="dispatch"; model=$spelling; effort="high"; transcript="$spelling.jsonl" } | ConvertTo-Json -Compress)
}
Add-Content -LiteralPath $dispatchPath -Encoding utf8 -Value @(
  (@{ ts=$now; kind="review-complete"; authorModel="claude-fable-5"; outcome="BLOCK" } | ConvertTo-Json -Compress),
  (@{ ts=$now; kind="review-complete"; authorModel="Fable 5.1"; outcome="PASS" } | ConvertTo-Json -Compress)
)
Invoke-Refresh | Out-Null
$m = Get-Matrix
$old = $m.configs | Where-Object id -eq "claude-fable-5/high"
$fresh = $m.configs | Where-Object id -eq "claude-fable-5-1/high"
Assert-True ($old.measured.n -eq 1 -and $old.measured.usdPerRun -eq 30) "Fable 5 historical cost remains separate"
Assert-True ($fresh.measured.n -eq 3 -and $fresh.measured.usdPerRun -eq 3) "version-explicit 5.1 spellings share only successor evidence"
Assert-True ($m.measuredAt.blockRateByAuthor.'claude-fable-5'.blockRate -eq 1) "predecessor review result remains historical"
Assert-True ($m.measuredAt.blockRateByAuthor.'claude-fable-5-1'.blockRate -eq 0) "successor review result does not inherit predecessor blocks"
Write-Output "PASS Fable 5.1 evidence is isolated from Fable 5"

# --- 14. a configuration id is derived, never named ------------------------
# `astra-high` shipped without a version because its id was a nickname. The
# refresh now refuses a config whose id is not exactly `<exact selector>/<effort>`
# instead of guessing which of the two the author meant.
Reset-Fixtures
$m = Get-Matrix
$m.configs += [pscustomobject]@{ id="sol-high"; model="gpt-5.6-sol"; effort="high"; harness="codex" }
Set-Content -LiteralPath $matrixPath -Encoding utf8 -Value ($m | ConvertTo-Json -Depth 20)
$beforeHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $matrixPath).Hash
$refused = $null
try { Invoke-Refresh | Out-Null } catch { $refused = "$($_.Exception.Message)" }
Assert-True ($null -ne $refused -and $refused -match "must be exactly '<exact model selector>/<effort>'" -and $refused -match "gpt-5.6-sol/high") "a nicknamed config id is refused with the derived id named (got: $refused)"
Assert-True ((Get-FileHash -Algorithm SHA256 -LiteralPath $matrixPath).Hash -ceq $beforeHash) "the refusal leaves the matrix byte-identical (fail closed)"
Write-Output "PASS matrix-refresh refuses a configuration id that is not derived from its model and effort"

# F2: a historical max effort remains evidence for its explicit configuration
# even when the production-shaped registry no longer admits max for new work.
$f2MatrixRegistrySnapshot=Set-ProductionShapedRoutingRegistry (Join-Path $routingFixture.stateRoot 'model-registry.json')
try {
  Reset-Fixtures
  $m=Get-Matrix
  $m.configs += [pscustomobject]@{id='gpt-6.1-sol/max';model='gpt-6.1-sol';effort='max';harness='codex'}
  Set-Content -LiteralPath $matrixPath -Encoding utf8 -Value ($m|ConvertTo-Json -Depth 20)
  $nowF2=(Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
  Add-Content -LiteralPath $ledgerPath -Value (@{ts=$nowF2;transcript='f2-max.jsonl';issue=9042;model='gpt-6.1-sol';usd=9.0;usdCurrent=9.0;durationSec=60;costSource='token-derived';routingCostSource='current-price-token-derived';durationSrc='file-span-estimate'}|ConvertTo-Json -Compress)
  Add-Content -LiteralPath $dispatchPath -Value (@{ts=$nowF2;kind='dispatch';issue=9042;model='gpt-6.1-sol';effort='max';transcript='f2-max.jsonl';row='4'}|ConvertTo-Json -Compress)
  Invoke-Refresh|Out-Null
  $f2MaxConfig=(Get-Matrix).configs|Where-Object{$_.id-ceq'gpt-6.1-sol/max'}
  Assert-True ($null-ne$f2MaxConfig-and$f2MaxConfig.measured.n-eq1) "matrix-refresh dropped a max run for a model that lacks max admission (got $($f2MaxConfig|ConvertTo-Json -Compress))"
  Write-Output 'PASS F2 matrix-refresh counts explicit max configuration without live max admission'
} finally { Restore-RoutingRegistryBytes $f2MatrixRegistrySnapshot }

Test-CapacityCalibration
Write-Output "ALL matrix-refresh tests passed"
} finally {
  $env:CHASE_SETS_ROUTING_DATA_ROOT=$oldRoutingRoot
  $env:CHASE_SETS_ROUTING_LKG_PATH=$oldRoutingLkg
  $resolvedRoot=[IO.Path]::GetFullPath($testRoot)
  $tempPrefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
  if (-not $resolvedRoot.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'unsafe matrix fixture cleanup root' }
  Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
  Exit-RoutingDataTestScope $routingTestScope
}
