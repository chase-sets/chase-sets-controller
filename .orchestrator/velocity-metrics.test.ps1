[CmdletBinding()]
param()

# #8207 velocity-report/v1 boundaries on synthetic facts. No network, no
# ownership probe, no dispatch-log read.

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot 'routing-data-test-support.ps1')
$routingTestScope=Enter-RoutingDataTestScope
try {
. (Join-Path $PSScriptRoot "velocity-metrics.ps1")
$script:assertions = 0
function Assert-Velocity([bool]$Condition, [string]$Message) {
  $script:assertions += 1
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

$now = ConvertTo-VelocityUtc "2026-09-26T12:00:00Z"
function T([double]$HoursAgo) { return (Format-VelocityUtc $now.AddHours(-$HoursAgo)) }
function Issue([int]$Number, [string[]]$Labels = @("kind:product", "priority:p1"), [int]$Milestone = 148, [bool]$Committed = $true, [int]$Blockers = 0, [string]$Track = 'commerce', [string]$Title = 'Synthetic product issue') {
  return [pscustomobject]@{ number = $Number; title = $Title; labels = $Labels; milestone = [pscustomobject]@{ number = $Milestone; committed = $Committed; track = $Track; state = 'OPEN' }; openBlockers = $Blockers }
}
function MergeIssue([int]$Number, [string[]]$Kinds = @('kind:product'), [string]$Track = 'commerce', $LabeledAt = $null) {
  $issue = Issue $Number $Kinds -Track $Track
  $issue | Add-Member kinds $Kinds
  $issue | Add-Member productLabeledAt $LabeledAt
  return $issue
}
function Landing($Pr) {
  $head='a'*40
  return [pscustomobject]@{
    repository='chase-sets/chase-sets';pr=[int]$Pr.pr;headOid=$head;observedAt=(T 0);queueEntryId=$(if($Pr.inMergeQueue){"MQE_SYNTHETIC_$($Pr.pr)"}else{$null})
    reviewReduction=[pscustomobject]@{schema='velocity-review-reduction/v1';currentHead=$head;state='authorized';reason='LATEST_EXACT_HEAD_PASS';latest=[pscustomobject]@{receiptIdentity=('b'*64);outcome='PASS';authorizedHead=$head}}
    requiredCheckAuthority=[pscustomobject]@{schema='velocity-required-check-authority/v1';protectionObserved=$true;requiresStatusChecks=$true;requiredNames=@('synthetic-required');exactHead=$head;totalCount=1;returnedCount=1;complete=$true;reductions=@([pscustomobject]@{schemaVersion='required-check-reducer/v1';requiredName='synthetic-required';status='eligible';reason='REQUIRED_CHECK_SELECTED';matchCount=1;selected=[pscustomobject]@{nodeType='StatusContext';databaseId=$null;status='SUCCESS';conclusion=$null;completedAt=$null;producer=$null};superseded=@()})}
    nonHoldPrerequisites=[pscustomobject]@{schema='velocity-non-hold-prerequisites/v1';complete=$true;status='eligible';reason='ALL_AUTHORITY_CURRENT';blocker=[pscustomobject]@{complete=$true;openCount=0};deploy=[pscustomobject]@{complete=$true;status='completed';conclusion='success'};breaker=[pscustomobject]@{complete=$true;healthy=$true};base=[pscustomobject]@{name='main';headOid=('c'*40)};changeScope=[pscustomobject]@{proven=$false;classification='deployable';head=$head}}
  }
}
function Facts([hashtable]$Override = @{}) {
  $base = [ordered]@{
    schema = "velocity-facts/v1"; complete = $true; gaps = @(); platformMilestones = @(155)
    merges = @(
      [pscustomobject]@{ pr = 1; mergedAt = (T 10); issues = @((MergeIssue 11 -LabeledAt (T 200))) },
      [pscustomobject]@{ pr = 2; mergedAt = (T 20); issues = @((MergeIssue 12 @('kind:ops') 'incumbent-ops')) },
      [pscustomobject]@{ pr = 3; mergedAt = (T 30); issues = @() }
    )
    lastProductMergeAt = (T 10)
    productIssues = @((Issue 100), (Issue 101), (Issue 102))
    productPrs = @()
    activeLanes = @([pscustomobject]@{ lane = "100-g1"; laneRole = "implementation" }, [pscustomobject]@{ lane = "101-g1"; laneRole = "implementation" })
    ownershipStatus = "ok"
    dispatchRows = @(
      [pscustomobject]@{ ts = (T 2); kind = "dispatch"; issue = 100; lane = "100-g1"; laneRole = "implementation" },
      [pscustomobject]@{ ts = (T 3); kind = "dispatch"; issue = 101; lane = "101-g1"; laneRole = "implementation" }
    )
    issueKinds = [pscustomobject]@{}
    holdState=[pscustomobject]@{schema='merge-hold-state/v1';revision=1;initializedAt=(T 240);records=@()}
  }
  foreach ($key in $Override.Keys) { $base[$key] = $Override[$key] }
  if ($Override.ContainsKey('lastProductMergeAt') -and -not $Override.ContainsKey('merges')) {
    if ($null -eq $Override.lastProductMergeAt) { $base.merges = @($base.merges | Where-Object pr -NE 1) }
    else { $base.merges[0].mergedAt = $Override.lastProductMergeAt }
  }
  foreach($pr in $base.productPrs){
    if($null -eq $pr.PSObject.Properties['headOid']){
      $pr|Add-Member headOid ('a'*40);$pr|Add-Member repository 'chase-sets/chase-sets'
      $pr|Add-Member queueEntryId $(if($pr.inMergeQueue){"MQE_SYNTHETIC_$($pr.pr)"}else{$null})
      $pr|Add-Member velocityLanding (Landing $pr)
      $validLanding=Test-VelocityLandingRecord $pr.velocityLanding
      Assert-Velocity $validLanding 'synthetic landing fixture is recursively valid'
    }
  }
  $base.cycleId='synthetic-cycle'
  $base.landingCapture=[pscustomobject]@{schema='velocity-landing-capture/v1';cycleId='synthetic-cycle';startedAt=(T 0.01);completedAt=(T 0);complete=$true;records=@($base.productPrs|ForEach-Object velocityLanding)}
  return [pscustomobject]$base
}
function Obs([double]$HoursAgo, [string]$State) { return [pscustomobject]@{ ts = (T $HoursAgo); floorState = $State } }

# Healthy baseline.
$r = Get-VelocityReport (Facts) $now @()
Assert-Velocity ($r.status -ceq "OK") "baseline is OK"
Assert-Velocity ($r.metrics.floorState -ceq "MET") "two product lanes meet the floor"
Assert-Velocity ((@($r.metrics.flowingProductIssues) -join ",") -ceq "100,101") "active product lanes are flowing"
Assert-Velocity ((@($r.metrics.readyNotInFlight) -join ",") -ceq "102") "ready idle excludes flowing issues"
Assert-Velocity ($r.metrics.merges7d -eq 3 -and $r.metrics.productMerges7d -eq 1 -and $r.metrics.unlinkedMerges7d -eq 1) "merge counts classify product, other and unlinked"
Assert-Velocity ($r.metrics.hoursSinceProductMerge -eq 10) "hours since product merge"

# DROUGHT: 48 h boundary, grace, acted and re-arm per period.
$r = Get-VelocityReport (Facts @{ lastProductMergeAt = (T 47.9) }) $now @()
Assert-Velocity (@($r.alarms | Where-Object id -eq "DROUGHT").Count -eq 0) "no drought before 48 h"
$r = Get-VelocityReport (Facts @{ lastProductMergeAt = (T 50) }) $now @()
$d = @($r.alarms | Where-Object id -eq "DROUGHT")[0]
Assert-Velocity ($r.status -ceq "ALARM" -and $null -ne $d -and -not $d.unacted) "drought raised at 48 h and inside its 4 h grace"
$r = Get-VelocityReport (Facts @{ lastProductMergeAt = (T 53) }) $now @()
Assert-Velocity (@($r.alarms | Where-Object id -eq "DROUGHT")[0].unacted) "drought unacted after grace"
$acted = @((Facts).dispatchRows) + @([pscustomobject]@{ ts = (T 1); kind = "decision-resolved"; lane = "velocity-drought"; note = "velocity:DROUGHT diagnosis dispatched" })
$r = Get-VelocityReport (Facts @{ lastProductMergeAt = (T 53); dispatchRows = $acted }) $now @()
$d = @($r.alarms | Where-Object id -eq "DROUGHT")[0]
Assert-Velocity (-not $d.unacted -and $null -ne $d.actedAt) "a velocity:DROUGHT row after onset acts on the alarm"
$staleAct = @((Facts).dispatchRows) + @([pscustomobject]@{ ts = (T 10); kind = "decision-resolved"; note = "velocity:DROUGHT first period" })
$r = Get-VelocityReport (Facts @{ lastProductMergeAt = (T 101); dispatchRows = $staleAct }) $now @()
Assert-Velocity (@($r.alarms | Where-Object id -eq "DROUGHT")[0].unacted) "an action from an earlier 48 h period does not cover the next period"
$wrongAct = @((Facts).dispatchRows) + @([pscustomobject]@{ ts = (T 1); kind = "decision-resolved"; note = "velocity:FLOOR only" })
$r = Get-VelocityReport (Facts @{ lastProductMergeAt = (T 53); dispatchRows = $wrongAct }) $now @()
Assert-Velocity (@($r.alarms | Where-Object id -eq "DROUGHT")[0].unacted) "a FLOOR action does not act on DROUGHT"
$r = Get-VelocityReport (Facts @{ lastProductMergeAt = $null }) $now @()
Assert-Velocity (@($r.alarms | Where-Object id -eq "DROUGHT").Count -eq 1) "no product merge in the lookback is a drought"

# FLOOR: unmet only with ready idle work, and only after a continuous 60 min run.
$oneLane = @([pscustomobject]@{ lane = "100-g1"; laneRole = "implementation" })
$r = Get-VelocityReport (Facts @{ activeLanes = $oneLane }) $now @()
Assert-Velocity ($r.metrics.floorState -ceq "UNMET" -and @($r.alarms | Where-Object id -eq "FLOOR").Count -eq 0) "a single unmet observation raises no alarm"
$r = Get-VelocityReport (Facts @{ activeLanes = $oneLane }) $now @((Obs 0.5 "UNMET"))
Assert-Velocity (@($r.alarms | Where-Object id -eq "FLOOR").Count -eq 0) "unmet for 30 min raises no alarm"
$r = Get-VelocityReport (Facts @{ activeLanes = $oneLane }) $now @((Obs 1.5 "UNMET"), (Obs 0.5 "UNMET"))
$f = @($r.alarms | Where-Object id -eq "FLOOR")[0]
Assert-Velocity ($null -ne $f -and -not $f.unacted) "unmet for 90 min raises FLOOR inside grace"
$r = Get-VelocityReport (Facts @{ activeLanes = $oneLane }) $now @((Obs 1.5 "UNMET"), (Obs 1.0 "MET"), (Obs 0.5 "UNMET"))
Assert-Velocity (@($r.alarms | Where-Object id -eq "FLOOR").Count -eq 0) "a MET observation resets the run"
$r = Get-VelocityReport (Facts @{ activeLanes = $oneLane }) $now @((Obs 4 "UNMET"), (Obs 2 "UNMET"))
Assert-Velocity (@($r.alarms | Where-Object id -eq "FLOOR")[0].unacted) "FLOOR unacted after 2 h grace"
$noReady = @((Issue 100), (Issue 101 @("kind:product", "status:needs-replan")), (Issue 102 @("kind:product") 155), (Issue 103 @("kind:product") 148 $false), (Issue 104 @("kind:product") 148 $true 1), (Issue 105 @("kind:product", "decision")))
$r = Get-VelocityReport (Facts @{ activeLanes = $oneLane; productIssues = $noReady }) $now @((Obs 3 "UNMET"))
Assert-Velocity ($r.metrics.floorState -ceq "MET" -and @($r.metrics.readyNotInFlight).Count -eq 0) "status labels, platform milestone, candidate outcome, open blocker and decision issues are not ready"

# Flowing: merge queue and running hosted CI count; finished CI without a lane does not.
$prs = @(
  [pscustomobject]@{ pr = 9; issues = @(101); isDraft = $true; inMergeQueue = $false; ciState = "PENDING"; headCommittedAt = (T 1) },
  [pscustomobject]@{ pr = 8; issues = @(102); isDraft = $false; inMergeQueue = $true; ciState = "SUCCESS"; headCommittedAt = (T 5) },
  [pscustomobject]@{ pr = 7; issues = @(103); isDraft = $true; inMergeQueue = $false; ciState = "FAILURE"; headCommittedAt = (T 5) }
)
$r = Get-VelocityReport (Facts @{ activeLanes = @(); productPrs = $prs; productIssues = @((Issue 101), (Issue 102), (Issue 103)) }) $now @()
Assert-Velocity ((@($r.metrics.flowingProductIssues) -join ",") -ceq "101,102") "running CI and merge queue flow; red CI with no owner does not: flow=$($r.metrics.flowingProductIssues -join ',') gaps=$($r.gaps -join ',')"
Assert-Velocity ($r.metrics.floorState -ceq "UNMET" -eq $false) "two flowing issues meet the floor"
$r = Get-VelocityReport (Facts @{ activeLanes = @([pscustomobject]@{ lane = "ops-g1"; laneRole = "implementation" }); dispatchRows = @([pscustomobject]@{ ts = (T 1); kind = "dispatch"; issue = 500; lane = "ops-g1" }); issueKinds = [pscustomobject]@{ "500" = @("kind:ops") } }) $now @()
Assert-Velocity (@($r.metrics.flowingProductIssues).Count -eq 0) "a non-product lane never counts toward the floor"
$aliasRows = @(
  [pscustomobject]@{ ts = (T 2); kind = "dispatch"; dispatchRoutingSchema = "watchdog-dispatch-routing/v1"; label = "100-g2"; lane = "20260926-100-seat"; worktree = "D:\x\20260926-100-seat" },
  [pscustomobject]@{ ts = (T 2); kind = "dispatch"; issue = 100; lane = "100-g2" }
)
$r = Get-VelocityReport (Facts @{ activeLanes = @([pscustomobject]@{ lane = "20260926-100-seat"; laneRole = "implementation" }); dispatchRows = $aliasRows }) $now @()
Assert-Velocity ((@($r.metrics.flowingProductIssues) -join ",") -ceq "100") "an ownership seat name resolves through its watchdog routing alias"

# UNKNOWN fails closed and raises no alarm.
$r = Get-VelocityReport (Facts @{ complete = $false; gaps = @("open-prs: timeout"); lastProductMergeAt = (T 90) }) $now @((Obs 3 "UNMET"))
Assert-Velocity ($r.status -ceq "UNKNOWN" -and $r.metrics.floorState -ceq "UNKNOWN" -and @($r.alarms).Count -eq 0) "incomplete facts are UNKNOWN, never OK or ALARM"

# Diagnostics are reported, never alarms.
$stale = @([pscustomobject]@{ ts = (T 9); kind = "dispatch"; issue = 100; lane = "100-g1" }, [pscustomobject]@{ ts = (T 3); kind = "dispatch"; issue = 101; lane = "101-g1" })
$decisions = @(1..3 | ForEach-Object { [pscustomobject]@{ ts = (T $_); kind = "decision-filed"; issue = 101; lane = "d$_" } })
$late = @([pscustomobject]@{ pr = 4; mergedAt = (T 5); issues = @((MergeIssue 44 -LabeledAt (T 6))) })
$r = Get-VelocityReport (Facts @{ dispatchRows = @($stale + $decisions); merges = $late; lastProductMergeAt = (T 5) }) $now @()
Assert-Velocity ((@($r.diagnostics.staleAttempts | ForEach-Object issue) -join ",") -ceq "100") "an implementation lane 9 h without a push is stale; 3 h is not"
$pushed = @([pscustomobject]@{ pr = 9; issues = @(100); isDraft = $true; inMergeQueue = $false; ciState = "FAILURE"; headCommittedAt = (T 1) })
$r2 = Get-VelocityReport (Facts @{ dispatchRows = $stale; productPrs = $pushed }) $now @()
Assert-Velocity (@($r2.diagnostics.staleAttempts).Count -eq 0) "a recent push clears the stale-attempt flag"
Assert-Velocity ((@($r.diagnostics.decisionHeavyIssues | ForEach-Object issue) -join ",") -ceq "101") "three decision lanes in 24 h flag the issue"
Assert-Velocity (@($r.diagnostics.lateProductRelabels).Count -eq 0) "kind changes inside a product milestone never flag late relabels"
Assert-Velocity ($r.status -ceq "OK") "diagnostics alone never raise an alarm"
$hours = Get-VelocityReport (Facts @{ dispatchRows = @(
      [pscustomobject]@{ ts = (T 4); kind = "dispatch"; issue = 100; lane = "p" }, [pscustomobject]@{ ts = (T 2); kind = "lane-complete"; issue = 100; lane = "p" },
      [pscustomobject]@{ ts = (T 4); kind = "dispatch"; issue = 500; lane = "o" }, [pscustomobject]@{ ts = (T 3); kind = "lane-complete"; issue = 500; lane = "o" }
    ); activeLanes = @(); issueKinds = [pscustomobject]@{ "500" = @("kind:ops") } }) $now @()
Assert-Velocity ($hours.diagnostics.laneHours48h.productHours -eq 2 -and $hours.diagnostics.laneHours48h.otherHours -eq 1 -and $hours.diagnostics.laneHours48h.productShare -eq 0.667) "lane-hours split product and other work"

# Outcome marker parsing.
Assert-Velocity (Get-VelocityOutcomeCommitted '<!-- outcome: {"version":1,"track":"commerce","order":100,"status":"committed"} -->') "committed marker"
Assert-Velocity (-not (Get-VelocityOutcomeCommitted '<!-- outcome: {"version":1,"status":"candidate"} -->')) "candidate marker is not committed"
Assert-Velocity (-not (Get-VelocityOutcomeCommitted 'no marker')) "missing marker is not committed"

$syntheticFailures=[Collections.Generic.List[string]]::new()
function Case([string]$Name,[scriptblock]$Body) {try{&$Body;Write-Output "PASS $Name (synthetic)"}catch{$syntheticFailures.Add("${Name}: $($_.Exception.Message)");Write-Output "FAIL ${Name}: $($_.Exception.Message)";Write-Output $_.ScriptStackTrace}}
Case 'FLOOR-F1-malformed-dequeue-and-controller-ownership' {
  foreach($kind in @('dequeue','controller')){
    foreach($malformed in @($false,$true)){
      $ts=if($malformed){'synthetic-invalid-timestamp'}else{T 0.25}
      if($kind -ceq 'dequeue'){
        $p=[pscustomobject]@{pr=990077;issues=@(101);isDraft=$false;inMergeQueue=$false;ciState='SUCCESS';headCommittedAt=(T 1)}
        $f=Facts @{productPrs=@($p);activeLanes=$oneLane}
        $f.dispatchRows=@($f.dispatchRows[0],
          [pscustomobject]@{ts=(T 0.5);kind='enqueue';pr=990077},
          [pscustomobject]@{ts=$ts;kind='dequeue';pr=990077;issue=101})
      }else{
        $f=Facts
        $f.dispatchRows+=@([pscustomobject]@{ts=$ts;kind='dispatch';issue=101;lane='controller-101-synthetic';reviewTarget='controller'})
      }
      $r=Get-VelocityReport $f $now @()
      $expected=if($malformed){'UNKNOWN'}else{'UNMET'}
      Assert-Velocity ($r.metrics.floorState -ceq $expected) "F1 $kind malformed=$malformed floor=$expected"
      Assert-Velocity ((@($r.metrics.flowingProductIssues) -join ',') -ceq $(if($malformed){'100,101'}else{'100'})) 'F1 control exposes hidden exclusion'
      Assert-Velocity ($r.factsComplete -eq (-not $malformed)) 'F1 completeness unchanged'
      if($malformed){Assert-Velocity ($r.gaps -ccontains 'dispatch-row-invalid:3:timestamp') 'F1 malformed row remains disclosed'}
    }
  }
}
Case 'FLOOR-F2-whole-log-and-open-PR-census' {
  foreach($readable in @($true,$false)){
    $prs=@([pscustomobject]@{pr=990101;issues=@(101);isDraft=$true;inMergeQueue=$false;ciState='PENDING';headCommittedAt=(T 1)},
      [pscustomobject]@{pr=990102;issues=@(102);isDraft=$true;inMergeQueue=$false;ciState='PENDING';headCommittedAt=(T 1)})
    $f=Facts @{productPrs=$prs;activeLanes=@();dispatchRows=@()}
    if($readable){$f.dispatchRows=@([pscustomobject]@{ts=(T 4);kind='dispatch';issue=101;lane='controller-101-synthetic';reviewTarget='controller'})}
    else{$f.complete=$false;$f.gaps=@('dispatch-log: synthetic unreadable')}
    $r=Get-VelocityReport $f $now @()
    Assert-Velocity ($r.metrics.floorState -ceq $(if($readable){'UNMET'}else{'UNKNOWN'})) "F2 dispatch-log readable=$readable"
    Assert-Velocity ((@($r.metrics.flowingProductIssues) -join ',') -ceq $(if($readable){'102'}else{'101,102'})) 'F2 hidden controller ownership changes flow'

    $p=[pscustomobject]@{pr=990077;issues=@(101);isDraft=$false;inMergeQueue=$false;ciState='SUCCESS';headCommittedAt=(T 1)}
    $f=Facts @{productPrs=@($p)}
    $f.productPrs[0].headOid='d'*40
    $f.dispatchRows=@($f.dispatchRows[0],
      [pscustomobject]@{ts=(T 1);kind='dispatch';dispatchRoutingSchema='watchdog-dispatch-routing/v2';issue=101;label='101-review';lane='seat';worktree='D:\synthetic\seat';head=('c'*40)})
    $f.activeLanes=@($oneLane[0],
      [pscustomobject]@{lane='seat';label='101-review';laneRole='review';worktree='D:\synthetic\seat';launchHead=('c'*40);startedAt=(T 1)})
    if(-not $readable){$f.productPrs=@();$f.landingCapture.records=@();$f.complete=$false;$f.gaps=@('open-prs: synthetic timeout')}
    $r=Get-VelocityReport $f $now @()
    Assert-Velocity ($r.metrics.floorState -ceq 'UNKNOWN' -and $r.status -ceq 'UNKNOWN') "F2 open-prs readable=$readable cannot prove floor"
    Assert-Velocity ((@($r.metrics.flowingProductIssues) -join ',') -ceq $(if($readable){'100'}else{'100,101'})) 'F2 hidden stale review head changes flow'
  }
}
Case 'FLOOR-additive-only-gaps' {
  $additive=@('landing-capture-unknown:990102','landing-capture-unverified','launch-issue-unresolved:synthetic-lane',
    'launch-issue-resolution-pending:synthetic-lane','merge-hold-state-unverified')
  foreach($gap in $additive){
    $r=Get-VelocityReport (Facts @{complete=$false;gaps=@($gap)}) $now @((Obs 3 'UNMET'))
    Assert-Velocity ($r.metrics.floorState -ceq 'MET') "$gap permits two independently flowing issues"
    Assert-Velocity ($r.status -ceq 'UNKNOWN' -and -not $r.factsComplete -and @($r.alarms).Count -eq 0) 'FLOOR proof does not certify facts or raise alarms'
    Assert-Velocity (($r.gaps -join ',') -ceq $gap) 'gap preserved exactly'
  }
  $r=Get-VelocityReport (Facts @{complete=$false;gaps=$additive}) $now @()
  Assert-Velocity ($r.metrics.floorState -ceq 'MET' -and ($r.gaps -join ',') -ceq (($additive|Sort-Object -Unique) -join ',')) 'all five additive kinds together permit MET without losing gaps'
  Assert-Velocity (($r.metrics.floorProofIssues -join ',') -ceq '100,101') 'proof set exposes the two witnesses'
  $r=Get-VelocityReport (Facts @{complete=$false;gaps=$additive;activeLanes=$oneLane}) $now @()
  Assert-Velocity ($r.metrics.floorState -ceq 'UNKNOWN') 'below floor with incomplete facts remains UNKNOWN'
}
Case 'FLOOR-per-issue-label-gaps' {
  foreach($kind in @('merged-issue-labels-incomplete','issue-details-labels-incomplete')){
    $gaps=@("${kind}:101","${kind}:101",'landing-capture-unverified')
    $f=Facts @{complete=$false;gaps=$gaps}
    $r=Get-VelocityReport $f $now @()
    Assert-Velocity ($r.metrics.floorState -ceq 'UNKNOWN') "$kind removes one of two witnesses"
    Assert-Velocity (($r.metrics.floorProofIssues -join ',') -ceq '100' -and ($r.metrics.flowingProductIssues -join ',') -ceq '100,101') 'deduplicated issue drop leaves diagnostic flow intact'
    Assert-Velocity ($r.status -ceq 'UNKNOWN' -and -not $r.factsComplete -and ($r.gaps -join ',') -ceq (($gaps|Sort-Object -Unique) -join ',')) 'per-issue proof changes no completeness evidence'
    $f.activeLanes+=@([pscustomobject]@{lane='102-g1';laneRole='implementation'})
    $f.dispatchRows+=@([pscustomobject]@{ts=(T 1);kind='dispatch';issue=102;lane='102-g1'})
    $r=Get-VelocityReport $f $now @()
    Assert-Velocity ($r.metrics.floorState -ceq 'MET' -and ($r.metrics.floorProofIssues -join ',') -ceq '100,102') "$kind leaves two unaffected witnesses"
    $f.gaps=@("${kind}:900199")
    $r=Get-VelocityReport $f $now @()
    Assert-Velocity ($r.metrics.floorState -ceq 'MET' -and @($r.metrics.floorProofIssues).Count -eq 3) 'unrelated issue does not subtract an arbitrary witness'
  }
}
Case 'FLOOR-closed-gap-classification-and-complete-compatibility' {
  $closed=@('dispatch-log: synthetic','open-prs: synthetic','product-issues: synthetic','merged-prs: synthetic',
    'ownership: synthetic','ownership-not-complete','platform-register-unreadable','dispatch-pid-lanes: synthetic','issue-kinds: synthetic',
    'pr-connections-incomplete:990102','merged-pr-connections-incomplete:990102','pr-body-incomplete:990102','merged-pr-body-incomplete:990102',
    'issue-connections-incomplete:101','synthetic-unclassified:101','LANDING-CAPTURE-UNKNOWN:990102',
    'landing-capture-unknown','landing-capture-unverified:extra','launch-issue-unresolved:',
    'merged-issue-labels-incomplete:0','merged-issue-labels-incomplete:2147483648','issue-details-labels-incomplete:101:extra')
  foreach($gap in $closed){
    $r=Get-VelocityReport (Facts @{complete=$false;gaps=@($gap,'landing-capture-unverified')}) $now @()
    Assert-Velocity ($r.metrics.floorState -ceq 'UNKNOWN' -and $r.status -ceq 'UNKNOWN') "$gap cannot prove FLOOR"
    Assert-Velocity (@($r.metrics.floorProofIssues).Count -eq 0) 'unbounded gaps expose no proof set'
  }
  foreach($field in @('kind','issue','pr','outcome','integrationAuthoritySchema','authorityState')){
    $row=[ordered]@{ts='synthetic-invalid-timestamp'};$row[$field]=if($field -cin @('issue','pr')){101}else{'synthetic'}
    $f=Facts;$f.dispatchRows+=@([pscustomobject]$row)
    $r=Get-VelocityReport $f $now @()
    Assert-Velocity ($r.metrics.floorState -ceq 'UNKNOWN' -and $r.gaps -ccontains 'dispatch-row-invalid:3:timestamp') "malformed $field consumer row fails closed"
  }
  # FactsPath may supply contradictory complete=true/gaps. Preserve the old complete-facts decision tree.
  foreach($lanes in @(@((Facts).activeLanes),$oneLane)){
    $f=Facts @{gaps=@('dispatch-log: synthetic','merged-issue-labels-incomplete:100');activeLanes=$lanes}
    $r=Get-VelocityReport $f $now @()
    Assert-Velocity ($r.factsComplete -and $r.metrics.floorState -ceq $(if($lanes.Count -ge 2){'MET'}else{'UNMET'})) 'complete-facts behavior unchanged even with supplied gaps'
  }
}
Case 'FLOOR-issue-connections-not-issue-local' {
  $p=[pscustomobject]@{pr=990103;issues=@(101,102);isDraft=$false;inMergeQueue=$true;ciState='SUCCESS';headCommittedAt=(T 1)}
  $f=Facts @{activeLanes=$oneLane;productPrs=@($p);productIssues=@((Issue 100),(Issue 101 -Blockers 1),(Issue 102 -Blockers 1))}
  $f.holdState.records=@([pscustomobject]@{holdId='synthetic-hold';scope='queue';issue=908624;armedWindowId='synthetic-window';takenAt=(T 0.5);expiresAt=(T -1);releasedAt=$null})
  $r=Get-VelocityReport $f $now @()
  Assert-Velocity (@($r.metrics.flowingProductIssues) -contains 102) 'no ready linked issue means PR is not held'
  $f.productIssues[1].openBlockers=0;$f.complete=$false;$f.gaps=@('issue-connections-incomplete:101')
  $r=Get-VelocityReport $f $now @()
  Assert-Velocity (@($r.metrics.flowingProductIssues) -notcontains 102 -and $r.metrics.heldCount -eq 1) 'missing blocker on 101 changes flow for 102 through PR-level held state'
  Assert-Velocity ($r.metrics.floorState -ceq 'UNKNOWN') 'non-local connection gap is category c'
}
function FloorCaptureFacts([string]$Mode,[bool]$InQueue,[bool]$WithHold=$true) {
  $p=[pscustomobject]@{pr=990105;issues=@(101);isDraft=$false;inMergeQueue=$InQueue;ciState='SUCCESS';headCommittedAt=(T 1)}
  $f=Facts @{activeLanes=$oneLane;productPrs=@($p)}
  if($WithHold){$f.holdState.records=@([pscustomobject]@{holdId='synthetic-hold';scope='queue';issue=908624;armedWindowId='synthetic-window';takenAt=(T 0.5);expiresAt=(T -1);releasedAt=$null})}
  if(-not $InQueue){$f.dispatchRows=@($f.dispatchRows[0],[pscustomobject]@{ts=(T 0.5);kind='enqueue';pr=990105})}
  $record=$f.landingCapture.records[0]
  switch($Mode){
    'nonhold-incomplete' {$record.nonHoldPrerequisites.complete=$false;$record.nonHoldPrerequisites.status='unknown';$record.nonHoldPrerequisites.reason='SYNTHETIC_DEPLOY_UNREADABLE'}
    'checks-incomplete' {$record.requiredCheckAuthority.complete=$false;$record.nonHoldPrerequisites.status='unknown';$record.nonHoldPrerequisites.reason='SYNTHETIC_CHECKS_TRUNCATED'}
    'capture-stale' {$record.observedAt=(T 1)}
  }
  Assert-Velocity (Test-VelocityLandingRecord $record) "PE $Mode record remains schema-valid"
  return $f
}
foreach($inQueue in @($true,$false)){
  $where=if($inQueue){'queue'}else{'greenwait'}
  foreach($mode in @('complete','nonhold-incomplete','checks-incomplete','capture-stale')){
    Case "PE-$where-$mode" {
      $r=Get-VelocityReport (FloorCaptureFacts $mode $inQueue) $now @()
      $complete=$mode -ceq 'complete'
      $flow=if($complete -or $mode -ceq 'capture-stale'){'100'}else{'100,101'}
      Assert-Velocity (($r.metrics.flowingProductIssues -join ',') -ceq $flow) 'PE diagnostic flow unchanged'
      Assert-Velocity ($r.metrics.heldCount -eq $(if($complete){1}else{0})) 'PE held count unchanged'
      Assert-Velocity ($r.factsComplete -eq $complete -and $r.status -ceq $(if($complete){'OK'}else{'UNKNOWN'})) 'PE status and completeness unchanged'
      $expectedGaps=if($complete){''}elseif($mode -ceq 'capture-stale'){'landing-capture-unknown:990105,landing-capture-unverified'}else{'landing-capture-unknown:990105'}
      Assert-Velocity (($r.gaps -join ',') -ceq $expectedGaps) 'PE existing gaps unchanged; no new gap kind'
      Assert-Velocity ($r.metrics.floorState -ceq $(if($complete){'UNMET'}else{'UNKNOWN'})) "PE-$where-$mode floor rejects hidden hold"
      Assert-Velocity (($r.metrics.floorProofIssues -join ',') -ceq $(if($complete -or $mode -ceq 'capture-stale'){'100'}else{''})) 'PE proof set fails closed only for valid capture with applicable hold'
    }
  }
  foreach($mode in @('nonhold-incomplete','checks-incomplete')){
    Case "PE-$where-$mode-no-hold" {
      $r=Get-VelocityReport (FloorCaptureFacts $mode $inQueue $false) $now @()
      Assert-Velocity ($r.metrics.floorState -ceq 'MET' -and ($r.metrics.floorProofIssues -join ',') -ceq '100,101') 'PE no applicable hold preserves additive proof'
      Assert-Velocity (($r.metrics.flowingProductIssues -join ',') -ceq '100,101' -and $r.metrics.heldCount -eq 0) 'PE no-hold flow unchanged'
      Assert-Velocity ($r.status -ceq 'UNKNOWN' -and -not $r.factsComplete -and ($r.gaps -join ',') -ceq 'landing-capture-unknown:990105') 'PE no-hold facts remain incomplete'
    }
  }
}
Case 'FLOOR-capture-hold-condition-mutant' {
  $candidate=(Get-Item Function:Get-VelocityReport).ScriptBlock.ToString()
  $guard=' -and -not $holdAmbiguousPrs.Contains($Matches[1])'
  Assert-Velocity ($candidate.Contains($guard)) 'capture-hold mutant locates condition'
  $mutant=[scriptblock]::Create($candidate.Replace($guard,''))
  foreach($inQueue in @($true,$false)){
    foreach($mode in @('nonhold-incomplete','checks-incomplete')){
      $f=FloorCaptureFacts $mode $inQueue
      $r=Get-VelocityReport $f $now @()
      Assert-Velocity ($r.metrics.floorState -ceq 'UNKNOWN') 'capture-hold candidate discriminator'
      $r=& $mutant $f $now @()
      Assert-Velocity ($r.metrics.floorState -ceq 'MET') 'dropping capture-hold condition exposes false MET'
      Write-Output "KILLED capture-hold-condition inQueue=$inQueue mode=$mode candidate=UNKNOWN mutant=MET"
    }
  }
}
Case 'FLOOR-gap-classification-mutants' {
  $candidate=(Get-Item Function:Get-VelocityReport).ScriptBlock.ToString()
  $variants=@(
    @{name='allowlist-widened';guard="'landing-capture-unverified','merge-hold-state-unverified'";replacement="'landing-capture-unverified','merge-hold-state-unverified','ownership-not-complete'";gap='ownership-not-complete'},
    @{name='per-issue-not-subtracted';guard='[void]$floorProofIssues.Remove($issueNumber)';replacement='';gap='merged-issue-labels-incomplete:101'},
    @{name='case-insensitive-allowlist';guard='$gap -cmatch';replacement='$gap -match';gap='LANDING-CAPTURE-UNKNOWN:990102'}
  )
  foreach($variant in $variants){
    $f=Facts @{complete=$false;gaps=@($variant.gap)}
    $r=Get-VelocityReport $f $now @()
    Assert-Velocity ($r.metrics.floorState -ceq 'UNKNOWN') "$($variant.name) candidate discriminator"
    Assert-Velocity ($candidate.Contains($variant.guard)) "$($variant.name) mutant locates guard"
    $mutant=[scriptblock]::Create($candidate.Replace($variant.guard,$variant.replacement))
    $r=& $mutant $f $now @()
    Assert-Velocity ($r.metrics.floorState -ceq 'MET') "$($variant.name) exposes false MET"
    Write-Output "KILLED $($variant.name) candidate=UNKNOWN mutant=MET"
  }
}
Case 'product-definition-todd-20261004-examples' {
  # These are synthetic controls with Todd's example numbers, not altered live evidence.
  $examples = @(
    @{number=8263;kind='test';product=$true}, @{number=8264;kind='test';product=$true},
    @{number=7857;kind='security';product=$true}, @{number=8456;kind='ops';product=$true},
    @{number=7951;kind='tech-debt';product=$true}, @{number=7198;kind='product';product=$true},
    @{number=7963;kind='product';product=$false;controller='reviewTarget'},
    @{number=8047;kind='ops';product=$false;controller='controllerIssue'},
    @{number=8125;kind='test';product=$false;controller='lane'},
    @{number=8129;kind='product';product=$false;controller='title'},
    @{number=8478;kind='product';product=$false;controller='label'}
  )
  foreach ($example in $examples) {
    $n=$example.number;$issue=MergeIssue $n @("kind:$($example.kind)")
    $row=[pscustomobject]@{ts=(T 2);kind='dispatch';issue=$n;lane="synthetic-$n"}
    switch ($example['controller']) {
      reviewTarget {$row|Add-Member reviewTarget controller}
      controllerIssue {$row|Add-Member controllerIssue $n}
      lane {$row.lane="controller-synthetic-$n"}
      title {$issue.title='[controller] Synthetic controller issue'}
      label {$row|Add-Member label "controller-synthetic-$n"}
    }
    $merge=[pscustomobject]@{pr=900001;mergedAt=(T 1);issues=@($issue)}
    $facts=Facts @{productIssues=@($issue);merges=@($merge);dispatchRows=@($row);activeLanes=@([pscustomobject]@{lane=$row.lane;laneRole='implementation'})}
    $r=Get-VelocityReport $facts $now @()
    Assert-Velocity ((@($r.metrics.flowingProductIssues) -contains $n) -eq $example.product) "synthetic #$n flow follows milestone/ownership"
    Assert-Velocity (($r.metrics.productMerges7d -eq 1) -eq $example.product) "synthetic #$n merge count follows milestone/ownership"
    Assert-Velocity (($null -ne $r.metrics.lastProductMergeAt) -eq $example.product) "synthetic #$n last merge follows milestone/ownership, not legacy fact pin"
    $facts.activeLanes=@()
    $facts.dispatchRows+=@([pscustomobject]@{ts=(T 1);kind='lane-complete';lane=$row.lane})
    $r=Get-VelocityReport $facts $now @()
    Assert-Velocity ((@($r.metrics.readyNotInFlight) -contains $n) -eq $example.product) "synthetic #$n ready idle follows milestone/ownership"
    Assert-Velocity ($r.diagnostics.laneHours48h.productShare -eq [int]$example.product) "synthetic #$n share follows milestone/ownership"
    Assert-Velocity ($r.productDefinitionVersion -ceq 'committed-product-milestone/v1' -and $r.schema -ceq 'velocity-report/v1') 'versioned definition preserves report schema'
    # Hosted CI also uses this definition rather than trusting productPrs membership.
    $facts.productPrs=(Facts @{productPrs=@([pscustomobject]@{pr=900002;issues=@($n);isDraft=$true;inMergeQueue=$false;ciState='PENDING';headCommittedAt=(T 1)})}).productPrs
    $r=Get-VelocityReport $facts $now @()
    Assert-Velocity ((@($r.metrics.flowingProductIssues) -contains $n) -eq $example.product) "synthetic #$n CI flow follows milestone/ownership"
  }
}
Case 'F10-controller-seat-reuse-is-not-product-ownership' {
  $shapes = @(
    @{name='ordinary-seat-30d';rows=@([pscustomobject]@{ts=(T 720);kind='dispatch';issue=900121;lane='lane-01'});issues=@(900120,900121);ready='900120,900121'},
    @{name='reused-seat-30d';rows=@([pscustomobject]@{ts=(T 720);kind='dispatch';issue=900121;lane='controller-900120-seat-g1'});issues=@(900120,900121);ready='900121'},
    @{name='reused-seat-2h';rows=@([pscustomobject]@{ts=(T 2);kind='dispatch';issue=900121;lane='controller-900120-seat-g1'});issues=@(900120,900121);ready='900121'},
    @{name='reused-seat-routing';rows=@(
      [pscustomobject]@{ts=(T 3);kind='dispatch';issue=900121;lane='900121-impl-g1';laneRole='implementation'},
      [pscustomobject]@{ts=(T 2);kind='dispatch';dispatchRoutingSchema='watchdog-dispatch-routing/v1';label='900121-impl-g1';lane='controller-900120-seat-g1';laneRole='implementation'}
    );issues=@(900120,900121);ready='900121'},
    @{name='reused-seat-no-suffix';rows=@([pscustomobject]@{ts=(T 720);kind='dispatch';issue=900121;lane='controller-900119'});issues=@(900120,900121);ready='900120,900121'},
    # Canonical dispatch-log.jsonl shapes at :19454 and :6965, with fixed synthetic time and issue facts.
    @{name='canonical-8075-in-8125';rows=@([pscustomobject]@{ts=(T 720);kind='dispatch';issue=8075;lane='controller-8125-census-blast-radius-g1';laneRole='planning';transcript='fable-8075-fixture-recovery-r4.jsonl'});issues=@(8075,8125);ready='8075'},
    @{name='canonical-6730-in-6720';rows=@([pscustomobject]@{ts=(T 720);kind='dispatch';issue=6730;lane='controller-6720'});issues=@(6720,6730);ready='6730'}
  )
  $failures = @()
  foreach ($shape in $shapes) {
    $facts=Facts @{productIssues=@($shape.issues|ForEach-Object{Issue $_});activeLanes=@();dispatchRows=$shape.rows;merges=@();lastProductMergeAt=$null}
    $r=Get-VelocityReport $facts $now @()
    $actual=$r.metrics.readyNotInFlight -join ','
    $passed=$actual -ceq $shape.ready
    Write-Output "F10 $($shape.name) ready=[$actual] expected=[$($shape.ready)] $(if($passed){'PASS'}else{'FAIL'})"
    if(-not $passed){$failures+=@($shape.name)}
  }
  Assert-Velocity ($failures.Count -eq 0) "F10 seat-reuse shapes: $($failures -join ',')"
  foreach ($marker in @('reviewTarget','controllerIssue-number','controllerIssue-true')) {
    $row=[pscustomobject]@{ts=(T 720);kind='dispatch';issue=900121;lane='controller-900120-seat-g1'}
    switch ($marker) {
      reviewTarget {$row|Add-Member reviewTarget controller}
      controllerIssue-number {$row|Add-Member controllerIssue 900122}
      controllerIssue-true {$row|Add-Member controllerIssue $true}
    }
    $owned=@(Get-VelocityControllerIssues @($row) $now)
    Assert-Velocity ($owned -contains 900121 -and $owned -notcontains 900120) "$marker independently owns the explicit issue, not the reused seat"
    if($marker -ceq 'controllerIssue-number'){Assert-Velocity ($owned -contains 900122) 'integer controllerIssue retains its explicit ownership'}
  }
  $independent=[pscustomobject]@{ts=(T 721);kind='review-complete';issue=900121;reviewTarget='controller'}
  $facts=Facts @{productIssues=@((Issue 900120),(Issue 900121));activeLanes=@();dispatchRows=@($shapes[1].rows)+@($independent)}
  $r=Get-VelocityReport $facts $now @()
  Assert-Velocity (@($r.metrics.readyNotInFlight).Count -eq 0) 'reused-seat product issue stays excluded when independently controller-owned'

  $candidate=(Get-Item Function:Get-VelocityControllerIssues).ScriptBlock.ToString()
  $guard='$explicitMarker -or $prefixes.Count -eq 0 -or $prefixes -contains $resolved'
  Assert-Velocity ($candidate.Contains($guard)) 'F10 mutant locates numbered-prefix ownership guard'
  $mutant=[scriptblock]::Create($candidate.Replace($guard,'$true'))
  $owned=@(& $mutant $shapes[1].rows $now)
  Assert-Velocity ($owned -contains 900121 -and $owned -notcontains 900120) 'F10 foreign-issue-emission mutant reproduces product exclusion and idle controller issue'
  Write-Output 'KILLED F10 foreign-issue-emission mutant'
}
Case 'product-definition-milestone-park-and-window-boundaries' {
  foreach ($control in @('parked','body-parked','candidate','incumbent-ops','delivery','platform-pilot','platform-owned','advisory','closed-milestone','no-milestone','missing-track')) {
    $issue=MergeIssue 900101
    switch ($control) {
      parked {$issue.labels+=@('status:parked')}
      'body-parked' {$issue|Add-Member terminalState unknown}
      candidate {$issue.milestone.committed=$false}
      'incumbent-ops' {$issue.milestone.track='incumbent-ops'}
      delivery {$issue.milestone.track='delivery'}
      'platform-pilot' {$issue.milestone.track='platform-pilot'}
      'platform-owned' {$issue.milestone.number=155}
      advisory {$issue.milestone.number=150}
      'closed-milestone' {$issue.milestone.state='CLOSED'}
      'no-milestone' {$issue.milestone=$null}
      'missing-track' {$issue.milestone.PSObject.Properties.Remove('track')}
    }
    $r=Get-VelocityReport (Facts @{productIssues=@($issue);merges=@([pscustomobject]@{pr=900102;mergedAt=(T 1);issues=@($issue)});dispatchRows=@();activeLanes=@()}) $now @()
    Assert-Velocity (@($r.metrics.readyNotInFlight).Count -eq 0 -and $r.metrics.productMerges7d -eq 0) "$control is not product work"
  }
  foreach ($age in @(168,168.01,720,-1)) {
    $issue=Issue 900103 @('kind:test') -Track mobile
    $row=[pscustomobject]@{ts=(T $age);kind='review-complete';issue=900103;reviewTarget='controller'}
    $r=Get-VelocityReport (Facts @{productIssues=@($issue);activeLanes=@();dispatchRows=@($row)}) $now @()
    Assert-Velocity ((@($r.metrics.readyNotInFlight) -contains 900103) -eq ($age -lt 0)) 'controller ownership never expires, but future evidence is not observed'
  }
  foreach ($marker in @('reviewTarget','controllerIssue','lane','label')) {
    $controller=Issue 900110 @('kind:test')
    $product=Issue 900111 @('kind:ops')
    $oldController=[pscustomobject]@{ts=(T 720);kind='dispatch';issue=900110;lane='synthetic-controller-origin'}
    switch ($marker) {
      reviewTarget {$oldController|Add-Member reviewTarget controller}
      controllerIssue {$oldController|Add-Member controllerIssue 900110}
      lane {$oldController.lane='controller-synthetic-origin'}
      label {$oldController|Add-Member label 'controller-synthetic-origin'}
    }
    $oldProduct=[pscustomobject]@{ts=(T 720);kind='dispatch';issue=900111;lane='synthetic-product-origin'}
    $facts=Facts @{productIssues=@($controller,$product);activeLanes=@();dispatchRows=@($oldController,$oldProduct)}
    $r=Get-VelocityReport $facts $now @()
    Assert-Velocity (($r.metrics.readyNotInFlight -join ',') -ceq '900111') "old $marker controller evidence excludes only controller ownership, not old ordinary product work"
  }
  $prefix=[pscustomobject]@{ts=(T 1);kind='dispatch';lane='controller-8129-synthetic-g1';label='controller-8129-synthetic-g1-c3'}
  $r=Get-VelocityReport (Facts @{productIssues=@((Issue 8129));activeLanes=@();dispatchRows=@($prefix)}) $now @()
  Assert-Velocity (@($r.metrics.readyNotInFlight).Count -eq 0) 'controller continuation prefix binds ownership even without an Issue annotation'
  $prefix|Add-Member issue 900106
  $r=Get-VelocityReport (Facts @{productIssues=@((Issue 8129),(Issue 900106));activeLanes=@();dispatchRows=@($prefix)}) $now @()
  Assert-Velocity (($r.metrics.readyNotInFlight -join ',') -ceq '900106') 'foreign explicit Issue stays product while the numbered controller seat owns only its issue'
  $issue=MergeIssue 900104 @('kind:test')
  $facts=Facts @{productIssues=@($issue);activeLanes=@();dispatchRows=@();merges=@([pscustomobject]@{pr=900105;mergedAt=(T 1);issues=@($issue)})}
  $before=Get-VelocityReport $facts $now @()
  $issue.labels=@('kind:product');$issue.kinds=@('kind:product');$issue.productLabeledAt=T 1.1
  $after=Get-VelocityReport $facts $now @()
  Assert-Velocity (@($after.diagnostics.lateProductRelabels).Count -eq 0 -and $after.metrics.productMerges7d -eq $before.metrics.productMerges7d -and ($after.metrics.readyNotInFlight -join ',') -ceq ($before.metrics.readyNotInFlight -join ',')) 'kind:test -> kind:product within a product milestone never alarms or changes accounting'
}
Case 'open-issue-census-beyond-search-cap' {
  $savedGraph=(Get-Item Function:Invoke-VelocityGraphQL).ScriptBlock
  try {
    $script:syntheticCensusControl='complete'
    function Invoke-VelocityGraphQL([string]$Query,[hashtable]$Variables) {
      Assert-Velocity ($Query.Contains('issues(states:OPEN,first:100,after:$c)') -and -not $Query.Contains('search(')) 'native open issue connection avoids the search ceiling'
      $offset=if($Variables.c){[int]$Variables.c}else{0}
      $end=[math]::Min($offset+100,1304)
      $nodes=@(($offset+1)..$end | ForEach-Object {[pscustomobject]@{number=$_}})
      $total=1304
      if($script:syntheticCensusControl -ceq 'moving' -and $offset){$total++}
      if($script:syntheticCensusControl -ceq 'duplicate' -and $offset){$nodes[0].number=1}
      if($script:syntheticCensusControl -ceq 'truncated' -and $end -eq 1304){$nodes=@($nodes | Select-Object -Skip 1)}
      $cursor=if($script:syntheticCensusControl -ceq 'stuck'){$Variables.c}else{[string]$end}
      return [pscustomobject]@{repository=[pscustomobject]@{issues=[pscustomobject]@{totalCount=$total;nodes=$nodes;pageInfo=[pscustomobject]@{hasNextPage=($end -lt 1304);endCursor=$cursor}}}}
    }
    Assert-Velocity (@(Invoke-VelocityOpenIssues).Count -eq 1304) 'all 1,304 synthetic issues are returned, not a partial 1,000'
    foreach($control in @('moving','duplicate','truncated','stuck')) {
      $script:syntheticCensusControl=$control;$failure=$null
      try { $null=Invoke-VelocityOpenIssues } catch { $failure=$_.Exception.Message }
      Assert-Velocity ($null -ne $failure -and $failure -like 'open issue*') "$control census fails closed"
    }
  } finally {Set-Item Function:Invoke-VelocityGraphQL $savedGraph}
}
Case 'launch-issue-no-host-row' {
  $rows=@([pscustomobject]@{ts=(T 2);kind='dispatch';dispatchRoutingSchema='watchdog-dispatch-routing/v2';issue=100;attemptId='100-g2';label='100-g2';lane='seat';worktree='D:\synthetic\seat'})
  $map=Get-VelocityLaneIssueMap $rows
  Assert-Velocity ($map['100-g2'].issue -eq 100) 'launcher label maps without a HOST row'
}
# Verbatim dispatch-log rows captured for #8674, in source-line order:
# 28411, 28422, 28445, 28463, 28466, 28469, 28472, 28476, 28477, 28478.
# Paths/heads are inert evidence, never opened or used for live ownership.
$launchRoutes8674=@(Get-Content (Join-Path $PSScriptRoot 'fixtures/velocity-launch-routes-8674.jsonl') | ConvertFrom-Json -DateKind String)
function LaunchFacts8674($Route,[string]$LauncherStartedAt,[string]$RecordedAt) {
  Facts @{productIssues=@((Issue $Route.issue));dispatchRows=@($Route);activeLanes=@(
    [pscustomobject]@{lane=$Route.lane;laneRole=$Route.laneRole;label=$Route.label;worktree=$Route.worktree;launchHead=$Route.head;startedAt=$RecordedAt;launcherStartedAt=$LauncherStartedAt})}
}
Case 'launch-route-before-ownership-record' {
  $pairs=@(
    @('8952-impl-g1-cont2','12:41:27.961','12:40:48.3674298','12:41:28.2694043'),
    @('9003-occurrence-map-r1','14:54:24.400','14:54:00.5242130','14:54:24.6432788'),
    @('153-eta-r1','14:58:23.172','14:57:44.8759097','14:58:23.4524866'),
    @('velocity-brief-delta-r2','15:01:30.332','15:01:03.4142778','15:01:30.6259227'),
    @('8674-plan-r1','15:04:06.476','15:03:28.4078713','15:04:06.6846343'))
  foreach($pair in $pairs){
    Case "launch-route-before-ownership-record/$($pair[0])" {
      $route=@($launchRoutes8674|Where-Object label -CEQ $pair[0])[0]
      $routeTime=ConvertTo-VelocityUtc $route.ts
      Assert-Velocity ($routeTime -eq (ConvertTo-VelocityUtc "2026-10-07T$($pair[1])Z")) 'captured route instant matches brief'
      $now=$routeTime.AddMinutes(60)
      $facts=LaunchFacts8674 $route "2026-10-07T$($pair[2])Z" "2026-10-07T$($pair[3])Z"
      $r=Get-VelocityReport $facts $now @()
      Assert-Velocity ($r.factsComplete -and (@($r.metrics.flowingProductIssues) -join ',') -ceq [string]$route.issue -and @($r.gaps|Where-Object{$_ -like 'launch-issue-*'}).Count -eq 0) "captured $($route.label) resolves $($route.issue) with complete facts"
    }
  }
}
Case 'velocity-cycle-20261007T1438-lanes' {
  $cycle=@{'7994-transport-g2'=7994;'8952-impl-g1-cont2'=8952;'9022-impl-g1'=9022;'9011-exact-head-review-r1'=7918;'operator-7426-final-review-r1-20261007'=7426;'operator-8838-native-verifier-20261007'=8838}
  foreach($label in $cycle.Keys){
    Case "velocity-cycle-20261007T1438-lanes/$label" {
      $route=@($launchRoutes8674|Where-Object label -CEQ $label)[0]
      $routeTime=ConvertTo-VelocityUtc $route.ts;$now=$routeTime.AddMinutes(60)
      # Modeled ownership: launcher -30s, recordedAt +0.3s (measured ranges).
      $facts=LaunchFacts8674 $route $routeTime.AddSeconds(-30).ToString('o') $routeTime.AddMilliseconds(300).ToString('o')
      $r=Get-VelocityReport $facts $now @()
      Assert-Velocity ($r.factsComplete -and (@($r.metrics.flowingProductIssues) -join ',') -ceq [string]$cycle[$label] -and @($r.gaps|Where-Object{$_ -like 'launch-issue-*'}).Count -eq 0) "cycle $label resolves explicit issue $($cycle[$label])"
    }
  }
}
foreach($control in @('stale-route-before-launcher','launch-head-mismatch','launch-worktree-mismatch','missing-launcher-start','review-stale-head','repair-stale-head','invalid-start','same-ms-valid-route','previous-ms-stale-route','observed-start-before-launcher')){
  Case $control {
    $route=$launchRoutes8674[0].PSObject.Copy();$routeTime=ConvertTo-VelocityUtc $route.ts;$now=$routeTime.AddMinutes(60)
    $facts=LaunchFacts8674 $route '2026-10-07T12:40:48.3674298Z' '2026-10-07T12:41:28.2694043Z'
    $active=$facts.activeLanes[0]
    switch($control){
      'stale-route-before-launcher' {$active.launcherStartedAt=$routeTime.AddSeconds(1).ToString('o')}
      'launch-head-mismatch' {$active.launchHead='f'*40}
      'launch-worktree-mismatch' {$active.worktree='D:\synthetic\other-launch'}
      'missing-launcher-start' {$active.PSObject.Properties.Remove('launcherStartedAt')}
      'invalid-start' {$active.launcherStartedAt='not-a-timestamp'}
      'same-ms-valid-route' {$active.launcherStartedAt=$routeTime.AddTicks(9999).ToString('o')}
      'previous-ms-stale-route' {$active.launcherStartedAt=$routeTime.AddMilliseconds(1).ToString('o')}
      'observed-start-before-launcher' {$route|Add-Member observedStartAt '2026-10-07T12:40:48.366Z';$route|Add-Member observedEvidence 'transcript-ctime:synthetic-8674'}
      {$_ -in @('review-stale-head','repair-stale-head')} {
        $active.laneRole=if($control -ceq 'review-stale-head'){'review'}else{'repair'}
        $pr=[pscustomobject]@{pr=908674;issues=@($route.issue);isDraft=$false;inMergeQueue=$false;ciState='SUCCESS';headCommittedAt=$route.ts}
        $facts=Facts @{productIssues=$facts.productIssues;dispatchRows=@($route);activeLanes=@($active);productPrs=@($pr)}
        Assert-Velocity ($facts.productPrs[0].headOid -cne $active.launchHead) 'linked PR carries a different head'
      }
    }
    $r=Get-VelocityReport $facts $now @()
    if($control -ceq 'same-ms-valid-route'){
      Assert-Velocity ($r.factsComplete -and @($r.metrics.flowingProductIssues) -contains $route.issue) 'millisecond-truncated route at launcher bound resolves'
    }else{
      Assert-Velocity (@($r.gaps) -contains "launch-issue-unresolved:$($route.label)" -and -not $r.factsComplete -and @($r.metrics.flowingProductIssues) -notcontains $route.issue) "$control stays launch-issue-unresolved past ten minutes"
    }
  }
}
Case 'issue-7198-dispatch-label-binds-ownership-seat' {
  $label='7198-impl-g2-c2';$seat='20261004-7198-impl';$head='a'*40
  $worktree="D:\synthetic\$seat"
  $annotation=[pscustomobject]@{ts=(T 1);kind='dispatch';issue=7198;lane=$label}
  $route=[pscustomobject]@{ts=(T 1);kind='dispatch';dispatchRoutingSchema='watchdog-dispatch-routing/v2';lane=$seat;label=$label;worktree=$worktree;head=$head}
  foreach($routeFirst in @($true,$false)) {
    $rows=if($routeFirst){@($route,$annotation)}else{@($annotation,$route)}
    $map=Get-VelocityLaneIssueMap $rows @(7198)
    foreach($key in @($label,$seat,$worktree)) {
      Assert-Velocity ($map[$key].issue -eq 7198 -and $map[$key].route -eq $route) "#7198 label/seat/worktree share explicit issue and canonical routing (routeFirst=$routeFirst)"
    }
    foreach($withLabel in @($true,$false)) {
      $owner=[pscustomobject]@{lane=$seat;laneRole='implementation';worktree=$worktree;launchHead=$head;startedAt=(T 1)}
      if($withLabel){$owner|Add-Member label $label}
      $facts=Facts @{productIssues=@((Issue 7198));dispatchRows=$rows;activeLanes=@($owner)}
      $r=Get-VelocityReport $facts $now @()
      Assert-Velocity ($r.factsComplete -and (@($r.metrics.flowingProductIssues) -join ',') -ceq '7198' -and @($r.metrics.readyNotInFlight).Count -eq 0) "#7198 live ownership is flowing, not ready idle (routeFirst=$routeFirst, withLabel=$withLabel)"
      $facts.activeLanes=@()
      $stopped=Get-VelocityReport $facts $now @()
      Assert-Velocity (@($stopped.metrics.flowingProductIssues).Count -eq 0 -and @($stopped.metrics.readyNotInFlight) -contains 7198) '#7198 historical routing without live ownership does not flow'
    }
  }
  $unbound=Get-VelocityLaneIssueMap @($route) @(7198)
  Assert-Velocity (-not $unbound.ContainsKey($seat)) '#7198 continuation prefix alone cannot invent the missing issue annotation'
}
Case 'running-lane-alias-attribution' {
  $rows=@([pscustomobject]@{ts=(T 200);kind='dispatch';issue=100;lane='100-g1'},[pscustomobject]@{ts=(T 199);kind='dispatch';label='100-g1';lane='seat';worktree='D:\synthetic\seat'},[pscustomobject]@{ts=(T 9);kind='dispatch';label='100-g1.wd1.synthetic';attemptId='100-g1';lane='seat';worktree='D:\synthetic\seat'})
  $r=Get-VelocityReport (Facts @{dispatchRows=$rows;activeLanes=@([pscustomobject]@{lane='seat';laneRole='implementation'})}) $now @()
  Assert-Velocity (@($r.metrics.flowingProductIssues) -contains 100) 'multi-hop relaunch retains >7d issue origin'
}
Case 'launch-label-issue-resolution' {
  $r=Get-VelocityReport (Facts @{dispatchRows=@();activeLanes=@([pscustomobject]@{lane='unresolved';laneRole='planning';startedAt=(T 1)})}) $now @((Obs 3 'UNMET'))
  Assert-Velocity (-not $r.factsComplete -and $r.metrics.floorState -ceq 'UNKNOWN' -and @($r.metrics.readyNotInFlight).Count -eq 0) 'unresolved owned lane older than ten minutes is a gap, not idle FLOOR'
  $r=Get-VelocityReport (Facts @{dispatchRows=@();activeLanes=@([pscustomobject]@{lane='unresolved';laneRole='planning';startedAt=(T 0.1)})}) $now @((Obs 3 'UNMET'))
  Assert-Velocity (-not $r.factsComplete -and $r.metrics.floorState -ceq 'UNKNOWN' -and @($r.gaps) -contains 'launch-issue-resolution-pending:unresolved') 'N2 unresolved lane inside grace cannot record MET and reset FLOOR'
}
Case 'terminal-parked-not-ready-idle' {
  $i=Issue 100;$i|Add-Member terminalState 'parked'
  $r=Get-VelocityReport (Facts @{productIssues=@($i);activeLanes=@();dispatchRows=@()}) $now @((Obs 3 'UNMET'))
  Assert-Velocity (@($r.metrics.readyNotInFlight).Count -eq 0 -and @($r.diagnostics.terminalParkedIssues).Count -eq 1) 'terminal issue is diagnostic, not ready idle'
}
Case 'merged-pending-completion' {
  $merge=[pscustomobject]@{pr=908527;mergedAt=(T 0.5);issues=@([pscustomobject]@{number=100;kinds=@('kind:product');productLabeledAt=$null})}
  $landed=[pscustomobject]@{ts=(T 0.5);kind='landed';pr=908527}
  $f=Facts @{productIssues=@((Issue 100));activeLanes=@();dispatchRows=@($landed);merges=@($merge)}
  $r=Get-VelocityReport $f $now @()
  Assert-Velocity (@($r.metrics.flowingProductIssues) -contains 100 -and @($r.metrics.readyNotInFlight).Count -eq 0) 'open issue after merge awaits completion, not ready idle'
  $f.productIssues[0]|Add-Member terminalState parked
  $r=Get-VelocityReport $f $now @()
  Assert-Velocity (@($r.metrics.flowingProductIssues).Count -eq 0 -and @($r.diagnostics.terminalParkedIssues).Count -eq 1) 'terminal park still takes precedence after merge'
}
Case 'F1-bounded-pending-landing' {
  $merge=[pscustomobject]@{pr=908527;mergedAt=(T 0.5);issues=@([pscustomobject]@{number=100;kinds=@('kind:product');productLabeledAt=$null})}
  $landed=[pscustomobject]@{ts=(T 0.5);kind='landed';pr=908527}
  $verified=[pscustomobject]@{ts=(T 0.25);kind='deploy-verified';pr=908527}
  foreach($control in @('verified','24h','480h','no-landed','future-landed')){
    $merge.mergedAt=T 0.5;$landed.ts=T 0.5
    $rows=@($landed)
    switch($control){verified{$rows+=@($verified)};'24h'{$merge.mergedAt=T 24;$landed.ts=T 24};'480h'{$merge.mergedAt=T 480;$landed.ts=T 480};'no-landed'{$rows=@()};'future-landed'{$landed.ts=T -1}}
    $f=Facts @{productIssues=@((Issue 100));activeLanes=@();dispatchRows=$rows;merges=@($merge)}
    $r=Get-VelocityReport $f $now @((Obs 2 'UNMET'))
    Assert-Velocity (@($r.metrics.flowingProductIssues).Count -eq 0 -and @($r.metrics.readyNotInFlight) -contains 100 -and $r.metrics.floorState -ceq 'UNMET' -and @($r.alarms|Where-Object id -EQ FLOOR).Count -eq 1) "F1 $control stops landing flow and restores FLOOR"
    $guard=switch($control){verified{'if($verified.Count -gt 0){continue}'};'24h'{' -or ($now-$mergedAt).TotalHours -ge 24'}}
    if($guard){
      $candidate=(Get-Item Function:Get-VelocityReport).ScriptBlock.ToString()
      Assert-Velocity ($candidate.Contains($guard)) "F1 $control mutant locates guard"
      $mutant=[scriptblock]::Create($candidate.Replace($guard,''))
      $mutated=& $mutant $f $now @((Obs 2 'UNMET'))
      Assert-Velocity (@($mutated.metrics.flowingProductIssues) -contains 100 -and @($mutated.metrics.readyNotInFlight).Count -eq 0) "F1 $control mutant reproduces forbidden landing flow"
      Write-Output "KILLED F1 landing-$control mutant (unbounded/verified guard)"
    }
  }
}
Case 'F3-routing-rows-never-create-hours' {
  $rows=@([pscustomobject]@{ts=(T 40);kind='dispatch';issue=100;lane='product'},[pscustomobject]@{ts=(T 39);kind='lane-complete';lane='product'},[pscustomobject]@{ts=(T 2);kind='dispatch';issue=500;lane='ops'},[pscustomobject]@{ts=(T 1);kind='lane-complete';lane='ops'})
  $f=Facts @{dispatchRows=$rows;activeLanes=@();issueKinds=[pscustomobject]@{'500'=@('kind:ops')}}
  $before=(Get-VelocityReport $f $now @()).diagnostics.laneHours48h
  $f.dispatchRows+=@([pscustomobject]@{ts=(T 40);kind='dispatch';issue=100;lane='lane-91';label='product';dispatchRoutingSchema='watchdog-dispatch-routing/v2'},[pscustomobject]@{ts=(T 2);kind='dispatch';issue=500;lane='lane-91';label='ops';dispatchRoutingSchema='watchdog-dispatch-routing/v2'})
  $after=(Get-VelocityReport $f $now @()).diagnostics.laneHours48h
  Assert-Velocity ($before.productHours -eq 1 -and $after.productHours -eq 1 -and $after.otherHours -eq 1 -and $after.productShare -eq $before.productShare -and $after.unattributedOpenLanes -eq 0) 'F3 routing rows preserve productShare=0.5 and paired hours'
  $f.dispatchRows=@($f.dispatchRows|Where-Object{Get-VelocityValue $_ 'dispatchRoutingSchema'})
  $r=Get-VelocityReport $f $now @()
  Assert-Velocity ($r.diagnostics.laneHours48h.productHours -eq 0 -and $r.diagnostics.laneHours48h.otherHours -eq 0) 'routing-only launches never create hours'
  foreach($terminal in @('lane-blocked','review-complete','repair-complete','verify-complete','dispatch')){
    $f.dispatchRows=@([pscustomobject]@{ts=(T 2);kind='dispatch';issue=100;lane='product'},[pscustomobject]@{ts=(T 1);kind=$terminal;lane='product'})
    $f.activeLanes=@([pscustomobject]@{lane='product';laneRole='implementation'})
    $r=Get-VelocityReport $f $now @()
    Assert-Velocity ($r.diagnostics.laneHours48h.productHours -eq 0) "only lane-complete closes counted hours, not $terminal or live ownership"
  }
}
Case 'F5-legacy-malformed-dispatch-rows' {
  foreach($rows in @(@([pscustomobject]@{ts='bad';kind='dispatch'}),@([pscustomobject]@{ts=(T 1)}))){
    $r=Get-VelocityReport (Facts @{dispatchRows=$rows}) $now @()
    Assert-Velocity ($r.status -ceq 'UNKNOWN' -and $r.metrics.floorState -ceq 'UNKNOWN' -and @($r.gaps|Where-Object{$_ -like 'dispatch-row-invalid:*'}).Count -gt 0) 'F5 legacy/malformed history is named UNKNOWN, never crash or OK'
  }
  $rows=@([pscustomobject]@{ts='2026-09-26T10:00:00.0000000+00:00';kind='dispatch';issue=100;lane='100-g1'})
  $r=Get-VelocityReport (Facts @{dispatchRows=$rows;activeLanes=@([pscustomobject]@{lane='100-g1';laneRole='implementation'})}) $now @()
  Assert-Velocity ($r.factsComplete -and @($r.metrics.flowingProductIssues) -contains 100) 'valid explicit-offset dispatch timestamps remain supported'
}
Case 'F6-adjacent-dispatch-lane-complete' {
  foreach($closer in @('decision-resolved','review-complete','repair-complete','lane-blocked','verify-complete','dispatch')){
    $rows=@([pscustomobject]@{ts=(T 40);kind='dispatch';issue=100;lane='product'},[pscustomobject]@{ts=(T 39.9);kind=$closer;lane='product'},[pscustomobject]@{ts=(T 2);kind='lane-complete';lane='product'},[pscustomobject]@{ts=(T 2);kind='dispatch';issue=500;lane='ops'},[pscustomobject]@{ts=(T 1);kind='lane-complete';lane='ops'})
    $f=Facts @{dispatchRows=$rows;activeLanes=@();issueKinds=[pscustomobject]@{'500'=@('kind:ops')}}
    $h=(Get-VelocityReport $f $now @()).diagnostics.laneHours48h
    Assert-Velocity ($h.productHours -eq 0 -and $h.otherHours -eq 1 -and $h.productShare -eq 0 -and $h.unattributedOpenLanes -eq 0) "F6 first closer $closer prevents non-adjacent pair"
    if($closer -ceq 'decision-resolved'){
      $candidate=(Get-Item Function:Get-VelocityLaneHours).ScriptBlock.ToString()
      $guard='$script:TerminalKinds -ccontains [string]$row.kind'
      Assert-Velocity ($candidate.Contains($guard)) 'F6 mutant locates adjacent terminal boundary'
      $mutant=[scriptblock]::Create($candidate.Replace($guard,"'lane-complete' -ceq [string]`$row.kind"))
      $h=& $mutant $f $now @{} @()
      Assert-Velocity ($h.productHours -eq 38 -and $h.productShare -eq 0.974) 'F6 skip-until-lane-complete mutant reproduces inflated share'
      Write-Output 'KILLED F6 skip-until-lane-complete mutant'
    }
  }
}
Case 'F6-unattributed-window-and-active-lanes' {
  $rows=@(1..3|ForEach-Object{[pscustomobject]@{ts=(T 720);kind='dispatch';issue=100;lane="review-$_"};[pscustomobject]@{ts=(T 719);kind='review-complete';lane="review-$_"}})
  $f=Facts @{dispatchRows=$rows;activeLanes=@()}
  Assert-Velocity ((Get-VelocityReport $f $now @()).diagnostics.laneHours48h.unattributedOpenLanes -eq 0) 'F6b closed old reviews are not open'
  $f.dispatchRows+=@([pscustomobject]@{ts=(T 169);kind='dispatch';issue=100;lane='old-open'},[pscustomobject]@{ts=(T 168);kind='dispatch';issue=100;lane='edge-open'},[pscustomobject]@{ts=(T 1);kind='dispatch';issue=100;lane='live'},[pscustomobject]@{ts=(T 1);kind='dispatch';issue=100;lane='recent-open'})
  $f.activeLanes=@([pscustomobject]@{lane='live';laneRole='implementation'})
  $h=(Get-VelocityReport $f $now @()).diagnostics.laneHours48h
  Assert-Velocity ($h.productHours -eq 0 -and $h.unattributedOpenLanes -eq 2) 'F6/N20 only nonlive unclosed seven-day origins are unattributed'
}
Case 'F7-inert-legacy-diagnostics-preserve-alarms' {
  $legacy=@(1..6|ForEach-Object{[pscustomobject]@{line=($_*2);at='2026-07-16T18:15:30.1349648Z';task="synthetic legacy $_";lane="lane-$_"}})
  $f=Facts @{dispatchRows=@((Facts).dispatchRows)+$legacy;lastProductMergeAt=(T 53);activeLanes=$oneLane}
  $r=Get-VelocityReport $f $now @((Obs 2 'UNMET'))
  Assert-Velocity ($r.factsComplete -and $r.status -ceq 'ALARM' -and (@($r.alarms.id)-join ',') -ceq 'FLOOR,DROUGHT') 'F7 inert legacy rows do not suppress FLOOR or DROUGHT'
  Assert-Velocity ((@($r.diagnostics.legacyDispatchRows)-join ',') -ceq '2,4,6,8,10,12') 'F7/N14 inert diagnostics name canonical lines'
  $candidate=(Get-Item Function:Get-VelocityDispatchRows).ScriptBlock.ToString()
  $guard='$legacy.Add($line)'
  Assert-Velocity ($candidate.Contains($guard)) 'F7 mutant locates inert diagnostic branch'
  try {
    Set-Item Function:Get-VelocityDispatchRows ([scriptblock]::Create($candidate.Replace($guard,'$gaps.Add("dispatch-row-invalid:${line}:timestamp")')))
    $mutated=Get-VelocityReport $f $now @((Obs 2 'UNMET'))
    Assert-Velocity (-not $mutated.factsComplete -and $mutated.status -ceq 'UNKNOWN' -and @($mutated.alarms).Count -eq 0) 'F7 legacy-as-gap mutant suppresses DROUGHT and FLOOR'
    Write-Output 'KILLED F7 legacy-as-completeness-gap mutant'
  } finally {Set-Item Function:Get-VelocityDispatchRows ([scriptblock]::Create($candidate))}
}
Case 'F7-consumer-fields-stay-unknown' {
  foreach($field in @('kind','issue','pr','outcome','integrationAuthoritySchema','authorityState')){
    $bad=[pscustomobject]@{line=42;ts='bad'};$bad|Add-Member $field $null
    $r=Get-VelocityReport (Facts @{dispatchRows=@($bad);activeLanes=@()}) $now @()
    Assert-Velocity ($r.status -ceq 'UNKNOWN' -and @($r.gaps) -contains 'dispatch-row-invalid:42:timestamp') "F7/N14 even null $field is consumer-relevant malformed history"
  }
}
Case 'F8-verified-before-landed' {
  $merge=[pscustomobject]@{pr=908527;mergedAt=(T 1);issues=@([pscustomobject]@{number=100;kinds=@('kind:product');productLabeledAt=$null})}
  $landed=[pscustomobject]@{ts=(Format-VelocityUtc $now.AddMinutes(-30).AddSeconds(35));kind='landed';pr=908527}
  $verified=[pscustomobject]@{ts=(T 0.5);kind='deploy-verified';pr=908527}
  $f=Facts @{productIssues=@((Issue 100));activeLanes=@();dispatchRows=@($verified,$landed);merges=@($merge)}
  $r=Get-VelocityReport $f $now @((Obs 2 'UNMET'))
  Assert-Velocity (@($r.metrics.flowingProductIssues).Count -eq 0 -and @($r.metrics.readyNotInFlight) -contains 100 -and $r.metrics.floorState -ceq 'UNMET' -and @($r.alarms.id) -contains 'FLOOR') 'F8 verified 35 seconds before landed restores idle and FLOOR'
  $candidate=(Get-Item Function:Get-VelocityReport).ScriptBlock.ToString();$guard='(ConvertTo-VelocityUtc $_.ts) -ge $mergedAt'
  Assert-Velocity ($candidate.Contains($guard)) 'F8 mutant locates merge-time verification anchor'
  $mutant=[scriptblock]::Create($candidate.Replace($guard,'(ConvertTo-VelocityUtc $_.ts) -ge (ConvertTo-VelocityUtc $landed[0].ts)'))
  $r=& $mutant $f $now @((Obs 2 'UNMET'))
  Assert-Velocity (@($r.metrics.flowingProductIssues) -contains 100 -and $r.metrics.floorState -ceq 'MET') 'F8 landed-ts-anchor mutant reproduces forbidden flow'
  Write-Output 'KILLED F8 landed-ts-anchor mutant'
  foreach($at in @((T 2),(T -1))){
    $verified.ts=$at;$r=Get-VelocityReport $f $now @()
    Assert-Velocity (@($r.metrics.landingProductIssues) -contains 100) 'F8 pre-merge and future verification do not close pending landing'
  }
}
Case 'F9-dequeue-unbinds-enqueue' {
  $p=[pscustomobject]@{pr=77;issues=@(101);isDraft=$false;inMergeQueue=$false;ciState='SUCCESS';headCommittedAt=(T 1)}
  $f=Facts @{activeLanes=@();productPrs=@($p);productIssues=@((Issue 101))}
  foreach($kind in @('enqueue','landed')){
    $binding=[pscustomobject]@{ts=(T 0.5);kind=$kind;pr=77}
    $dequeue=[pscustomobject]@{ts=(T 0.25);kind='dequeue';pr=77;issue=101}
    $reenqueue=[pscustomobject]@{ts=(T 0.1);kind='enqueue';pr=77}
    foreach($control in @('enqueue-only','enqueue-then-dequeue','enqueue-dequeue-reenqueue','foreign-repository','other-pr','future','prior','same-time')){
      $dequeue.ts=T 0.25;$dequeue.pr=77;$dequeue.PSObject.Properties.Remove('repository')
      $f.dispatchRows=@($binding,$dequeue)
      switch($control){'enqueue-only'{$f.dispatchRows=@($binding)};'enqueue-dequeue-reenqueue'{$f.dispatchRows+=@($reenqueue)};'foreign-repository'{$dequeue|Add-Member repository 'foreign/repo'};'other-pr'{$dequeue.pr=78};future{$dequeue.ts=T -1};prior{$dequeue.ts=T 0.75};'same-time'{$dequeue.ts=$binding.ts}}
      $r=Get-VelocityReport $f $now @((Obs 2 'UNMET'))
      if($control -cin @('enqueue-then-dequeue','same-time')){
        Assert-Velocity (@($r.metrics.readyNotInFlight) -contains 101 -and @($r.metrics.flowingProductIssues).Count -eq 0 -and $r.metrics.floorState -ceq 'UNMET' -and @($r.alarms.id) -contains 'FLOOR') "F9 $kind/$control unbinds and restores FLOOR"
        if($control -ceq 'enqueue-then-dequeue'){
          $candidate=(Get-Item Function:Get-VelocityReport).ScriptBlock.ToString();$guard="`$_.kind -ceq 'dequeue'"
          Assert-Velocity ($candidate.Contains($guard)) 'F9 mutant locates dequeue guard'
          $mutant=[scriptblock]::Create($candidate.Replace($guard,'$false'))
          $r=& $mutant $f $now @((Obs 2 'UNMET'))
          Assert-Velocity (@($r.metrics.flowingProductIssues) -contains 101) 'F9 ignore-dequeue mutant reproduces stale binding'
          Write-Output "KILLED F9 ignore-dequeue mutant ($kind)"
        }
      } else {Assert-Velocity (@($r.metrics.flowingProductIssues) -contains 101 -and @($r.metrics.readyNotInFlight).Count -eq 0) "F9 $kind/$control preserves flow"}
      if($control -ceq 'enqueue-only'){
        $candidate=(Get-Item Function:Get-VelocityReport).ScriptBlock.ToString();$guard=' -or $greenWait'
        Assert-Velocity ($candidate.Contains($guard)) 'N17 mutant locates row-only greenWait flow'
        $r=& ([scriptblock]::Create($candidate.Replace($guard,''))) $f $now @()
        Assert-Velocity (@($r.metrics.readyNotInFlight) -contains 101) 'N17 greenWait-as-idle mutant kills only row binding'
        Write-Output "KILLED N17 greenWait-as-idle mutant ($kind)"
      }
    }
  }
}
Case 'held-pass-only/held-queued-pass/held-only-floor' {
  $f=Facts @{activeLanes=@();productIssues=@((Issue 101),(Issue 102));productPrs=@($prs[0],$prs[1])}
  $f.productPrs[0].inMergeQueue=$true;$f.productPrs[0].isDraft=$false;$f.productPrs[0].ciState='SUCCESS';$f.productPrs[0].queueEntryId='MQE_SYNTHETIC_9';$f.productPrs[0].velocityLanding=Landing $f.productPrs[0]
  $f.landingCapture.records=@($f.productPrs|ForEach-Object velocityLanding)
  $f.holdState.records=@([pscustomobject]@{holdId='synthetic-hold';scope='queue';issue=908526;armedWindowId='synthetic-window';takenAt=(T 0.5);expiresAt=(T -1);releasedAt=$null})
  $r=Get-VelocityReport $f $now @((Obs 1 'UNMET'))
  Assert-Velocity ($r.metrics.heldCount -eq 2 -and @($r.metrics.flowingProductIssues).Count -eq 0 -and @($r.metrics.readyNotInFlight).Count -eq 0 -and $r.metrics.floorState -ceq 'UNMET') 'two held queues do not count as flow or idle'
  Assert-Velocity ($r.alarms[0].id -ceq 'FLOOR' -and $r.alarms[0].detail.Contains('synthetic-hold') -and $r.alarms[0].detail.Contains('host action')) 'sixty-minute held-only FLOOR names hold and action'
  $f.holdState.records=@();$r=Get-VelocityReport $f $now @()
  Assert-Velocity (@($r.metrics.flowingProductIssues).Count -eq 2 -and $r.metrics.heldCount -eq 0) 'verified no-hold restores queue flow'
}
Case 'held-dedup-flow-precedence/mixed-floor-causes/held-authority-boundaries' {
  $p=[pscustomobject]@{pr=88;issues=@(100);isDraft=$false;inMergeQueue=$true;ciState='SUCCESS';headCommittedAt=(T 1)}
  $f=Facts @{activeLanes=@();productIssues=@((Issue 100),(Issue 101));productPrs=@($p)}
  $h=[pscustomobject]@{holdId='synthetic-held';scope='prs';prs=@(88);issue=908526;armedWindowId='synthetic-window';takenAt=(T 0.5);expiresAt=(T -1);releasedAt=$null}
  $f.holdState.records=@($h)
  $r=Get-VelocityReport $f $now @((Obs 1 'UNMET'))
  Assert-Velocity ($r.metrics.heldCount -eq 1 -and @($r.metrics.readyNotInFlight) -contains 101 -and $r.alarms[0].detail.Contains('88') -and $r.alarms[0].detail.Contains('101')) 'mixed FLOOR names idle and held causes'
  $f.productPrs+=@($p);$r=Get-VelocityReport $f $now @()
  Assert-Velocity ($r.metrics.heldCount -eq 1) 'PR deduplicated with hold identities'
  $f.activeLanes=@([pscustomobject]@{lane='100-g1';laneRole='implementation'})
  $r=Get-VelocityReport $f $now @()
  Assert-Velocity (@($r.metrics.flowingProductIssues) -contains 100 -and $r.metrics.heldCount -eq 1) 'independent live lane still flows'
  $f.activeLanes=@();$p.ciState='PENDING';$r=Get-VelocityReport $f $now @()
  Assert-Velocity (@($r.metrics.flowingProductIssues) -contains 100) 'independent running CI flows'
  $p.ciState='SUCCESS';$f.productPrs=@($p)
  $original=$f|ConvertTo-Json -Depth 64
  foreach($case in @('draft','unready','other-blocker','not-pass','unrelated-pr','released','expired','missing-state','prose','future-take','extra-key','wrong-head')){
    $f=$original|ConvertFrom-Json -DateKind String
    switch($case){
      draft {$f.productPrs[0].isDraft=$true}
      unready {$f.productIssues[0].labels+=@('status:needs-replan')}
      'other-blocker' {$f.landingCapture.records[0].nonHoldPrerequisites.status='refused';$f.landingCapture.records[0].nonHoldPrerequisites.reason='OPEN_NATIVE_ISSUE_BLOCKER';$f.landingCapture.records[0].nonHoldPrerequisites.blocker.openCount=1}
      'not-pass' {$f.landingCapture.records[0].reviewReduction.state='blocked';$f.landingCapture.records[0].reviewReduction.latest.outcome='BLOCK_FIXABLE';$f.landingCapture.records[0].nonHoldPrerequisites.status='refused';$f.landingCapture.records[0].nonHoldPrerequisites.reason='REVIEW_BLOCKED'}
      'unrelated-pr' {$f.holdState.records[0].prs=@(999)}
      released {$f.holdState.records[0].releasedAt=(T 0.1)}
      expired {$f.holdState.records[0].takenAt=(T 1.5);$f.holdState.records[0].expiresAt=(T 0.1)}
      'missing-state' {$f.holdState=$null}
      prose {$f.holdState=[pscustomobject]@{note='Todd hold until tomorrow'}}
      'future-take' {$f.holdState.records[0].takenAt=(T -0.1)}
      'extra-key' {$f.holdState.records[0]|Add-Member active $true}
      'wrong-head' {$f.productPrs[0].headOid='d'*40}
    }
    $r=Get-VelocityReport $f $now @()
    Assert-Velocity ($r.metrics.heldCount -eq 0) "$case never counts held-only"
    if($case -cin @('missing-state','prose','future-take','extra-key','wrong-head')){Assert-Velocity (-not $r.factsComplete -and $r.metrics.floorState -ceq 'UNKNOWN') "$case stays UNKNOWN"}
  }
  $f=$original|ConvertFrom-Json -DateKind String
  $candidate=(Get-Item Function:Get-VelocityReport).ScriptBlock.ToString()
  Assert-Velocity ($candidate.Contains('-and -not $isHeld')) 'held-vs-flowing mutant finds its guard'
  $mutant=[scriptblock]::Create($candidate.Replace('-and -not $isHeld',''))
  $r=& $mutant $f $now @()
  Assert-Velocity (@($r.metrics.flowingProductIssues) -contains 100) 'held-vs-flowing mutant reproduces forbidden queue flow'
  Write-Output 'KILLED held-vs-flowing mutant: candidate excludes held queue, omitted guard flows'
  # Executed immutable-intake reproduction, not a claim of captured live queue facts.
  # Exact source blob cf1ec3bd53cbc58b3f5b256dcfe44e976d0bbb09 at intake
  # f292db3c0c89aba867b7ae10da6fffd0fc2970ee. CI snapshots have no source history.
  $source=([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fixtures/velocity-metrics-intake.ps1.txt')) -replace "`r`n","`n")
  $sourceHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($source))).ToLowerInvariant()
  Assert-Velocity ($sourceHash -ceq '2c12f8c571caaa11f53859b682b3a351de1f31629cf98ab3f883b72ef568898f') 'immutable intake source matches the archived original'
  $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
  Assert-Velocity ($errors.Count -eq 0) 'immutable intake source parses'
  $oldConstant=$ast.Find({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$script:LateRelabelHours'},$true)
  Assert-Velocity ($null -ne $oldConstant) 'immutable intake relabel constant exists'
  . ([scriptblock]::Create($oldConstant.Extent.Text))
  foreach ($name in @('Test-VelocityProductKind','Get-VelocityIssueKinds','Test-VelocityReadyIssue','Get-VelocityReport')) {
    $old=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true)
    Assert-Velocity ($null -ne $old) "immutable intake helper exists: $name"
    . ([scriptblock]::Create($old.Extent.Text))
  }
  $red=Get-VelocityReport $f $now @()
  Assert-Velocity (@($red.metrics.flowingProductIssues) -contains 100 -and $null -eq $red.metrics.PSObject.Properties['heldCount']) 'intake baseline counts held queue as flowing'
  Write-Output 'RED immutable intake held queue: flowing=100, held metric absent (synthetic replay)'
}
Case 'launch-label-issue-resolution-controls' {
  $origin=[pscustomobject]@{ts=(T 200);kind='dispatch';issue=100;lane='100-impl-g1';label='100-impl-g1';worktree='D:\synthetic\seat'}
  $continued=[pscustomobject]@{ts=(T 1);kind='dispatch';lane='100-impl-g1';label='100-impl-g1-c2';worktree='D:\synthetic\seat'}
  $m=Get-VelocityLaneIssueMap @($origin,$continued) @(100,101)
  Assert-Velocity ($m['100-impl-g1-c2'].issue -eq 100) '-cN inherits unique prior seat issue'
  $continued|Add-Member issue 101;$m=Get-VelocityLaneIssueMap @($origin,$continued) @(100,101)
  Assert-Velocity ($m['100-impl-g1-c2'].issue -eq 101) 'explicit Issue wins over prefix and prior issue'
  $continued.PSObject.Properties.Remove('issue');$m=Get-VelocityLaneIssueMap @($continued) @(100)
  Assert-Velocity (-not $m.ContainsKey('100-impl-g1-c2')) '-cN without prior seat cannot guess prefix'
  $m=Get-VelocityLaneIssueMap @([pscustomobject]@{ts=(T 1);kind='dispatch';lane='seat';label='100-review-g1'}) @(100)
  Assert-Velocity ($m['100-review-g1'].issue -eq 100) 'absent Issue validates leading canonical prefix'
  $m=Get-VelocityLaneIssueMap @([pscustomobject]@{ts=(T 1);kind='dispatch';lane='seat';label='999-review-100'}) @(100)
  Assert-Velocity ($m.Count -eq 0) 'nonmatching prefix and embedded digits are not guessed'
  $cycle=@([pscustomobject]@{ts=(T 2);kind='dispatch';lane='a';label='a';attemptId='b'},[pscustomobject]@{ts=(T 1);kind='dispatch';lane='b';label='b';attemptId='a'})
  Assert-Velocity ((Get-VelocityLaneIssueMap $cycle).Count -eq 0) 'cyclic aliases stay unresolved'
  $conflict=$origin.PSObject.Copy();$conflict.issue=101
  Assert-Velocity (-not (Get-VelocityLaneIssueMap @($origin,$conflict,$continued) @(100,101)).ContainsKey('100-impl-g1-c2')) 'conflicting prior identity stays unresolved'
}
Case 'green-waiting-review' {
  $p=[pscustomobject]@{pr=77;issues=@(101);isDraft=$false;inMergeQueue=$false;ciState='SUCCESS';headCommittedAt=(T 1)}
  $f=Facts @{activeLanes=@();productPrs=@($p);productIssues=@((Issue 101))}
  $r=Get-VelocityReport $f $now @()
  Assert-Velocity (@($r.metrics.readyNotInFlight) -contains 101) 'green with no bound lane or row remains idle'
  foreach($role in @('review','repair')){
    $f.dispatchRows=@([pscustomobject]@{ts=(T 1);kind='dispatch';dispatchRoutingSchema='watchdog-dispatch-routing/v2';issue=101;label='101-review';lane='seat';worktree='D:\synthetic\seat';head=$p.headOid})
    $f.activeLanes=@([pscustomobject]@{lane='seat';label='101-review';laneRole=$role;worktree='D:\synthetic\seat';launchHead=$p.headOid;startedAt=(T 1)})
    foreach($draft in @($false,$true)){
      $p.isDraft=$draft;$r=Get-VelocityReport $f $now @()
      Assert-Velocity (@($r.metrics.flowingProductIssues).Count -eq 1 -and @($r.metrics.readyNotInFlight).Count -eq 0) "green/draft=$draft bound $role lane flows once"
      if($role -ceq 'review' -and -not $draft){
        $candidate=(Get-Item Function:Get-VelocityReport).ScriptBlock.ToString()
        $guard='[void]$flowing.Add($entry.issue)'
        Assert-Velocity ($candidate.Contains($guard)) 'green-wait-as-idle mutant locates lane flow'
        $mutant=[scriptblock]::Create($candidate.Replace($guard,''))
        $mutated=& $mutant $f $now @()
        Assert-Velocity (@($mutated.metrics.readyNotInFlight) -contains 101) 'green-wait-as-idle mutant misclassifies bound review lane as idle'
        Write-Output 'KILLED green-wait-as-idle mutant: same green bound lane is idle only under mutant'
      }
    }
    $p.headOid='d'*40;$r=Get-VelocityReport $f $now @()
    Assert-Velocity (-not $r.factsComplete -and @($r.metrics.flowingProductIssues).Count -eq 0) "wrong-head $role lane fails closed"
    $p.headOid='a'*40
  }
  $p.isDraft=$false;$f.activeLanes=@()
  foreach($kind in @('enqueue','landed')){
    $f.dispatchRows=@([pscustomobject]@{ts=(T 0.5);kind=$kind;pr=77;head=$p.headOid})
    $r=Get-VelocityReport $f $now @()
    Assert-Velocity (@($r.metrics.flowingProductIssues) -contains 101) "green PR bound $kind row flows"
    $f.dispatchRows[0].head='d'*40;$r=Get-VelocityReport $f $now @()
    Assert-Velocity (@($r.metrics.readyNotInFlight) -contains 101) "wrong-head $kind cannot flow"
    $f.dispatchRows[0].PSObject.Properties.Remove('head');$r=Get-VelocityReport $f $now @()
    Assert-Velocity (@($r.metrics.flowingProductIssues) -contains 101) "canonical headless $kind binds PR after current commit"
    $f.dispatchRows[0].ts=T 2;$r=Get-VelocityReport $f $now @()
    Assert-Velocity (@($r.metrics.readyNotInFlight) -contains 101) "stale headless $kind predating current commit cannot flow"
    $f.dispatchRows[0].ts=T -1;$r=Get-VelocityReport $f $now @()
    Assert-Velocity (@($r.metrics.readyNotInFlight) -contains 101) "future $kind cannot flow"
  }
}
Case 'F2-unknown-outcome-per-pr' {
  $p=[pscustomobject]@{pr=77;issues=@(100);isDraft=$false;inMergeQueue=$true;ciState='SUCCESS';headCommittedAt=(T 1)}
  $q=[pscustomobject]@{pr=78;issues=@(101);isDraft=$false;inMergeQueue=$true;ciState='SUCCESS';headCommittedAt=(T 1)}
  $f=Facts @{activeLanes=@();productPrs=@($p,$q)}
  $p.velocityLanding.reviewReduction.latest.outcome='FUTURE_UNKNOWN'
  Assert-Velocity (Test-VelocityLandingCapture $f.landingCapture $f.cycleId $now) 'F2 unknown outcome does not void valid sibling capture'
  $r=Get-VelocityReport $f $now @()
  Assert-Velocity ($r.status -ceq 'UNKNOWN' -and @($r.gaps) -contains 'landing-capture-unknown:77' -and @($r.gaps) -notcontains 'landing-capture-unknown:78' -and @($r.metrics.flowingProductIssues) -contains 101 -and @($r.metrics.flowingProductIssues) -notcontains 100) 'F2 unknown outcome fails closed only for its PR'
  $root=Join-Path ([IO.Path]::GetTempPath()) ('synthetic-8526-unknown-outcome-'+[guid]::NewGuid().ToString('N'))
  [IO.Directory]::CreateDirectory($root)|Out-Null
  try{
    $path=Join-Path $root 'capture.json'
    $written=Write-VelocityLandingCapture $path $f.cycleId $now.AddMinutes(-1) @($p,$q) $now
    $f.landingCapture=Read-VelocityLandingCapture $path $f.cycleId $now
    $r=Get-VelocityReport $f $now @()
    Assert-Velocity ($written.records.Count -eq 2 -and $written.records[0].reviewReduction.reason -ceq 'REVIEW_OUTCOME_UNKNOWN' -and @($r.metrics.flowingProductIssues) -contains 101 -and @($r.metrics.flowingProductIssues) -notcontains 100) 'F2 unknown outcome atomic write/read preserves valid sibling and fails closed per PR'
  }finally{
    if([IO.Path]::GetFullPath($root).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $root -Recurse -Force}
  }
  $f.landingCapture.records=@($p.velocityLanding,$q.velocityLanding)
  $p.velocityLanding.reviewReduction.latest|Add-Member extra $true
  Assert-Velocity (-not (Test-VelocityLandingCapture $f.landingCapture $f.cycleId $now)) 'unknown outcome does not bypass closed nested validation'
  $p.velocityLanding.reviewReduction.latest.PSObject.Properties.Remove('extra')
  $p.velocityLanding.reviewReduction.latest.outcome='SKIP'
  Assert-Velocity (-not (Test-VelocityLandingRecord $p.velocityLanding)) 'SKIP cannot claim authorized PASS'
}
Case 'held-capture-production-chain/held-collector-wiring' {
  $root=Join-Path ([IO.Path]::GetTempPath()) ('synthetic-8526-collector-'+[guid]::NewGuid().ToString('N'))
  $runtime=Join-Path $root '.orchestrator'
  [IO.Directory]::CreateDirectory($runtime)|Out-Null
  $savedGraph=(Get-Item Function:Invoke-VelocityGraphQL).ScriptBlock
  $clock=[datetime]::UtcNow
  try {
    [IO.File]::WriteAllText((Join-Path $runtime 'platform-handoff.md'),'| chase-sets milestone 155 | platform |')
    [IO.File]::WriteAllText((Join-Path $runtime 'dispatch-log.jsonl'),'')
    [IO.File]::WriteAllText((Join-Path $runtime 'dispatch-ownership.ps1'),@'
function Get-LiveDispatchOwnership($Runtime,$Temp,$Container) {
  Get-Content -LiteralPath (Join-Path $Runtime 'synthetic-ownership.json') -Raw|ConvertFrom-Json -DateKind String
}
'@)
    function Save-Json([string]$Path,$Value){[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 64),[Text.UTF8Encoding]::new($false))}
    $ownershipPath=Join-Path $runtime 'synthetic-ownership.json'
    Save-Json $ownershipPath @{health=@{status='ok'};activeLanes=@()}
    $holdPath=Join-Path $runtime 'merge-hold-state.json'
    $null=Update-MergeHoldState -Path $holdPath -Action Initialize -ExpectedRevision 0 -Reconciled -Now $clock.AddMinutes(-10)
    $null=Update-MergeHoldState -Path $holdPath -Action Take -ExpectedRevision 1 -Armed -ArmedWindowId synthetic-armed -HoldId synthetic-hold -Issue 908526 -Now $clock.AddMinutes(-1) -ExpiresAt $clock.AddHours(1)
    $head='a'*40;$prNumber=908527;$issueNumber=908528
    $pass=[ordered]@{ts=$clock.AddMinutes(-5).ToString('o');kind='review-complete';pr=$prNumber;receiptSchema='exact-head-review-receipt/v1';reviewedHead=$head;reviewerAttempt='synthetic-review';authorAttempt='synthetic-author';reviewContract='review-contract/v2';completeSweep=$true;outcome='PASS';model='gpt-6.1-sol';authorModel='gpt-6-astra';findingIds=@();findings=@{blocking=0;candidates=0;nonBlocking=0}}
    $history=Join-Path $runtime 'review.jsonl';[IO.File]::WriteAllText($history,($pass|ConvertTo-Json -Compress -Depth 10)+[Environment]::NewLine)
    $observation=(Get-Content (Join-Path $PSScriptRoot 'landing-preflight.fixture.json') -Raw|ConvertFrom-Json -DateKind String).scenarios.eligible.observations[0]
    $observation.pr.number=$prNumber;$observation.pr.id='PR_SYNTHETIC_8526';$observation.pr.mergeQueueEntryId='MQE_SYNTHETIC_8526'
    $observation.pr.closingIssues[0].number=$issueNumber
    $observation.pr|Add-Member baseHead ('c'*40)
    $observation.pr|Add-Member checkCollection ([pscustomobject]@{exactHead=$head;totalCount=1;returnedCount=1;complete=$true})
    $observation.pr.checks=@([pscustomobject]@{schemaVersion='required-check-observation/v1';valid=$true;reason='REQUIRED_STATUS_CONTEXT_VALID';nodeType='StatusContext';name='PR Required';databaseId=$null;status='SUCCESS';conclusion=$null;completedAt=$null;producer=$null})
    $fixture=Join-Path $runtime 'preflight.json'
    function Capture-Report {
      Save-Json $fixture @{schema='landing-preflight-fixture/v1';scenarios=@{synthetic=@{observations=@($observation)}}}
      $raw=& (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File (Join-Path $PSScriptRoot 'landing-preflight.ps1') -Pr $prNumber -Repository synthetic/velocity -Action Report -MutationDisabled -HistoryPath $history -AuthorityFixture $fixture -AuthorityScenario synthetic
      if($LASTEXITCODE -ne 0){throw 'synthetic preflight process failed'}
      $raw|ConvertFrom-Json -DateKind String
    }
    $cycle='synthetic-8526-cycle';$started=[datetime]::UtcNow
    $preflight=Capture-Report
    Assert-Velocity ($preflight.reason -ceq 'PR_ALREADY_ENQUEUED' -and $preflight.mutationCount -eq 0 -and $preflight.velocityLanding.nonHoldPrerequisites.status -ceq 'eligible') "Report preserves queued refusal and exposes non-hold qualification: $($preflight.reason)/$($preflight.velocityLanding.nonHoldPrerequisites.reason)"
    $capturePath=Join-Path $runtime 'logs/velocity-landing-capture.json'
    $capture=Write-VelocityLandingCapture $capturePath $cycle $started @($preflight)
    $script:syntheticIssue=[pscustomobject]@{number=$issueNumber;title='Synthetic product';body='synthetic product';labels=[pscustomobject]@{totalCount=1;nodes=@([pscustomobject]@{name='kind:product'})};milestone=[pscustomobject]@{number=148;state='OPEN';description='<!-- outcome: {"version":1,"track":"commerce","status":"committed"} -->'};blockedBy=[pscustomobject]@{totalCount=0;nodes=@()}}
    $script:syntheticPr=[pscustomobject]@{number=$prNumber;body='';repository=[pscustomobject]@{nameWithOwner='synthetic/velocity'};headRefOid=$head;isDraft=$false;mergeQueueEntry=[pscustomobject]@{id='MQE_SYNTHETIC_8526';state='QUEUED'};commits=[pscustomobject]@{nodes=@([pscustomobject]@{commit=[pscustomobject]@{oid=$head;committedDate=$clock.ToString('o');statusCheckRollup=[pscustomobject]@{state='SUCCESS'}}})};closingIssuesReferences=[pscustomobject]@{totalCount=1;nodes=@([pscustomobject]@{number=$issueNumber;labels=$script:syntheticIssue.labels})}}
    $script:syntheticMerges=@();$script:syntheticOpenPrs=$true
    $script:syntheticMergeIssue=[pscustomobject]@{number=$issueNumber;title='Synthetic merged product';body='synthetic closed issue';labels=$script:syntheticIssue.labels;milestone=$script:syntheticIssue.milestone}
    function Invoke-VelocityGraphQL([string]$Query,[hashtable]$Variables){
      if($Query -match 'issueOrPullRequest\(number:(?:0|-)'){throw 'synthetic GraphQL refuses non-positive issue number'}
      if($Query.Contains('issue(number:')){
        Assert-Velocity ($Query.Contains('labels(first:30){totalCount') -and $Query.Contains('milestone{number state description}') -and $Query.Contains('number title body')) 'merged body lookup requests complete product-definition inputs'
        return [pscustomobject]@{repository=[pscustomobject]@{"i$issueNumber"=$script:syntheticMergeIssue}}
      }
      if($Variables['q'] -like '*is:merged*'){
        foreach($field in @('number body repository','mergedAt','closingIssuesReferences(first:5){totalCount','labels(first:30){totalCount')){Assert-Velocity ($Query.Contains($field)) "merged collector requests $field"}
        $nodes=@($script:syntheticMerges)
      }
      elseif($Query.Contains('issues(states:OPEN,first:100,after:$c)')){
        Assert-Velocity (-not $Query.Contains('kind:product')) 'open issue census is independent of kind labels'
        $nodes=@(if($null -ne $script:syntheticIssue){$script:syntheticIssue})
        return [pscustomobject]@{repository=[pscustomobject]@{issues=[pscustomobject]@{totalCount=$nodes.Count;pageInfo=[pscustomobject]@{hasNextPage=$false;endCursor=$null};nodes=$nodes}}}
      }
      elseif($Variables['q'] -like '*is:pr is:open*'){
        foreach($field in @('number body repository','headRefOid','nameWithOwner','mergeQueueEntry{id','totalCount')){Assert-Velocity ($Query.Contains($field)) "collector requests $field"}
        $nodes=@(if($script:syntheticOpenPrs){$script:syntheticPr})
      }else{throw 'unexpected synthetic external request'}
      return [pscustomobject]@{search=[pscustomobject]@{issueCount=$nodes.Count;pageInfo=[pscustomobject]@{hasNextPage=$false;endCursor=$null};nodes=$nodes}}
    }
    function Collect {Get-VelocityFacts $root ([datetime]::UtcNow) $cycle $capturePath}
    $facts=Collect;$r=Get-VelocityReport $facts ([datetime]::UtcNow) @()
    Assert-Velocity ($facts.complete -and $r.metrics.heldCount -eq 1 -and @($r.metrics.flowingProductIssues).Count -eq 0 -and @($r.metrics.readyNotInFlight).Count -eq 0) "producer -> Report -> atomic capture -> collector -> held (gaps=$($r.gaps -join ','))"
    $factsPath=Join-Path $runtime 'facts.json';Save-Json $factsPath $facts
    $summary=& (Join-Path $PSScriptRoot 'velocity-metrics.ps1') -ContainerRoot $root -FactsPath $factsPath -CycleId $cycle -NoRecord -Summary
    Assert-Velocity (($summary -join "`n").Contains('held=1') -and ($summary -join "`n").Contains('holds=synthetic-hold')) 'production Summary names hold identity'
    # AC11: delivery uses Refs, not closing references. All queue facts here are synthetic.
    $closing=$script:syntheticPr.closingIssuesReferences
    $script:syntheticPr.closingIssuesReferences=[pscustomobject]@{totalCount=0;nodes=@()}
    $script:syntheticPr.body="Refs #$issueNumber"
    foreach($keyword in @('Refs','Close','Closes','Closed','Fix','Fixes','Fixed','Resolve','Resolves','Resolved')){
      $script:syntheticPr.body="$keyword #$issueNumber"
      $facts=Collect;$r=Get-VelocityReport $facts ([datetime]::UtcNow) @()
      Assert-Velocity ($facts.complete -and @($facts.productPrs).Count -eq 1 -and $r.metrics.heldCount -eq 1 -and @($r.metrics.readyNotInFlight).Count -eq 0) "refs-only-queued-product/$keyword collector -> held"
    }
    $script:syntheticPr.body="Refs #$issueNumber; closes #$issueNumber"
    $facts=Collect
    Assert-Velocity (@($facts.productPrs[0].issues).Count -eq 1) 'body issue identities deduplicated'
    $facts.holdState.records=@();$r=Get-VelocityReport $facts ([datetime]::UtcNow) @()
    Assert-Velocity (@($r.metrics.flowingProductIssues).Count -eq 1 -and $r.metrics.flowingProductIssues[0] -eq $issueNumber -and $r.metrics.heldCount -eq 0) 'refs-only queued product without hold flows once'
    $script:syntheticPr.body='synthetic delivery without an issue reference'
    $enqueue=@{ts=$clock.ToString('o');kind='enqueue';issue=$issueNumber;pr=$prNumber}
    $dispatchPath=Join-Path $runtime 'dispatch-log.jsonl'
    [IO.File]::WriteAllText($dispatchPath,($enqueue|ConvertTo-Json -Compress)+[Environment]::NewLine)
    $facts=Collect;$r=Get-VelocityReport $facts ([datetime]::UtcNow) @()
    Assert-Velocity ($facts.complete -and $r.metrics.heldCount -eq 1) 'enqueue Issue+Pr fallback collector -> held'
    foreach($control in @('wrong-pr','boolean-pr','not-enqueue','future','foreign-repository','explicit-nonproduct')){
      $row=$enqueue.Clone()
      switch($control){
        'wrong-pr' {$row.pr=$prNumber+1}
        'boolean-pr' {$row.pr=$true}
        'not-enqueue' {$row.kind='dispatch'}
        'future' {$row.ts=$clock.AddDays(1).ToString('o')}
        'foreign-repository' {$row.repository='synthetic/other'}
        'explicit-nonproduct' {$script:syntheticPr.body='Refs #999999'}
      }
      [IO.File]::WriteAllText($dispatchPath,($row|ConvertTo-Json -Compress)+[Environment]::NewLine)
      $facts=Collect
      Assert-Velocity ($facts.complete -and @($facts.productPrs).Count -eq 0) "enqueue fallback refuses $control"
    }
    [IO.File]::WriteAllText($dispatchPath,'')
    foreach($body in @('Refs #0','Refs #999999999999999999999','Refs #908528x','preferences #908528','Refs other/repo#908528')){
      $script:syntheticPr.body=$body;$facts=Collect
      Assert-Velocity ($facts.complete -and @($facts.productPrs).Count -eq 0) "body reference refuses $body"
    }
    $script:syntheticPr.body="Refs #$issueNumber";$script:syntheticPr.closingIssuesReferences=$closing
    $facts=Collect
    Assert-Velocity (@($facts.productPrs[0].issues).Count -eq 1) 'closing reference plus Refs is one issue'
    $script:syntheticPr.PSObject.Properties.Remove('body');$facts=Collect;$r=Get-VelocityReport $facts ([datetime]::UtcNow) @()
    Assert-Velocity (-not $facts.complete -and $r.metrics.floorState -ceq 'UNKNOWN' -and @($facts.gaps) -contains "pr-body-incomplete:$prNumber") 'omitted body source is UNKNOWN, not a healthy floor'
    $script:syntheticPr|Add-Member body "Refs #$issueNumber"
    Write-Output 'PASS refs-only-queued-product: collector/body/closing/enqueue fallback -> held and no-hold flowing (synthetic)'
    # AC11 extension: a merged Refs-only PR is product throughput, including
    # closed referenced issues. A still-open linked issue is awaiting landing
    # completion, not newly idle work. No deploy success is fabricated.
    $mergedAt=$clock.AddMinutes(-20).ToString('o')
    $script:syntheticMerges=@([pscustomobject]@{number=$prNumber;body="Refs #$issueNumber";repository=$script:syntheticPr.repository;mergedAt=$mergedAt;closingIssuesReferences=[pscustomobject]@{totalCount=0;nodes=@()}})
    $script:syntheticOpenPrs=$false
    [IO.File]::WriteAllText($dispatchPath,(@{ts=$mergedAt;kind='landed';pr=$prNumber}|ConvertTo-Json -Compress)+[Environment]::NewLine)
    $facts=Collect;$r=Get-VelocityReport $facts ([datetime]::UtcNow) @()
    Assert-Velocity ($facts.complete -and $facts.lastProductMergeAt -ceq $mergedAt -and $r.metrics.productMerges7d -eq 1 -and $r.metrics.hoursSinceProductMerge -lt 1) 'refs-only-merged-product moves lastProductMergeAt, seven-day count and DROUGHT clock'
    Assert-Velocity (@($r.metrics.flowingProductIssues) -contains $issueNumber -and @($r.metrics.readyNotInFlight).Count -eq 0) 'merged product with pending deploy/verify is flowing, never ready idle'
    Save-Json $factsPath $facts
    $summary=& (Join-Path $PSScriptRoot 'velocity-metrics.ps1') -ContainerRoot $root -FactsPath $factsPath -NoRecord -Summary
    Assert-Velocity (($summary -join "`n").Contains("flowing=$issueNumber readyIdle= ")) 'merged pending completion collector -> report -> Summary'
    foreach($keyword in @('Refs','Closes','Fixes','Resolved')){
      $script:syntheticMerges[0].body="$keyword #$issueNumber; Refs #$issueNumber"
      $facts=Collect
      Assert-Velocity ($facts.lastProductMergeAt -ceq $mergedAt -and @($facts.merges[0].issues).Count -eq 1) "merged body $keyword is deduplicated"
    }
    $savedIssue=$script:syntheticIssue;$script:syntheticIssue=$null
    $facts=Collect;$r=Get-VelocityReport $facts ([datetime]::UtcNow) @()
    Assert-Velocity ($facts.complete -and $facts.lastProductMergeAt -ceq $mergedAt -and $r.metrics.productMerges7d -eq 1 -and @($r.metrics.flowingProductIssues).Count -eq 0) 'closed Refs-only product issue counts as throughput but not in-flight work'
    $script:syntheticIssue=$savedIssue
    $script:syntheticMerges[0].body='synthetic landing without body links'
    foreach($kind in @('enqueue','landed')){
      $row=@{ts=$clock.AddMinutes(-21).ToString('o');kind=$kind;issue=$issueNumber;pr=$prNumber}
      [IO.File]::WriteAllText($dispatchPath,($row|ConvertTo-Json -Compress)+[Environment]::NewLine)
      $facts=Collect
      Assert-Velocity ($facts.complete -and $facts.lastProductMergeAt -ceq $mergedAt) "merged $kind Issue+Pr fallback moves last merge"
      foreach($bad in @('wrong-pr','future','foreign','boolean-issue','not-landing')){
        $badRow=$row.Clone()
        switch($bad){'wrong-pr'{$badRow.pr=$prNumber+1};future{$badRow.ts=$clock.AddDays(1).ToString('o')};foreign{$badRow.repository='synthetic/other'};'boolean-issue'{$badRow.issue=$true};'not-landing'{$badRow.kind='dispatch'}}
        [IO.File]::WriteAllText($dispatchPath,($badRow|ConvertTo-Json -Compress)+[Environment]::NewLine)
        $facts=Collect
        Assert-Velocity ($null -eq $facts.lastProductMergeAt) "merged fallback refuses $kind/$bad"
      }
    }
    [IO.File]::WriteAllText($dispatchPath,'')
    $script:syntheticMerges[0].body="Refs #$issueNumber"
    $script:syntheticMergeIssue.labels=[pscustomobject]@{totalCount=1;nodes=@([pscustomobject]@{name='kind:ops'})}
    $facts=Collect
    Assert-Velocity ($facts.complete -and $facts.lastProductMergeAt -ceq $mergedAt) 'kind:ops in a product milestone remains product throughput'
    $script:syntheticMergeIssue.labels=$script:syntheticIssue.labels
    $savedMergeIssue=$script:syntheticMergeIssue;$script:syntheticMergeIssue=$null
    $facts=Collect
    Assert-Velocity (-not $facts.complete -and @($facts.gaps | Where-Object { $_ -like 'merged-prs:*unresolved*' }).Count -eq 1) 'unresolved merged body issue is UNKNOWN, not a known drought'
    $script:syntheticMergeIssue=$savedMergeIssue
    $script:syntheticMergeIssue.labels=[pscustomobject]@{totalCount=2;nodes=@([pscustomobject]@{name='kind:product'})}
    $facts=Collect
    Assert-Velocity (-not $facts.complete -and @($facts.gaps) -contains "merged-issue-labels-incomplete:$issueNumber") 'truncated merged issue labels are UNKNOWN'
    $script:syntheticMergeIssue.labels=$script:syntheticIssue.labels
    $script:syntheticMerges[0].closingIssuesReferences.totalCount=1
    $facts=Collect
    Assert-Velocity (-not $facts.complete -and @($facts.gaps) -contains "merged-pr-connections-incomplete:$prNumber") 'truncated merged closing references are UNKNOWN'
    $script:syntheticMerges[0].closingIssuesReferences.totalCount=0
    $script:syntheticMerges[0].PSObject.Properties.Remove('body')
    $facts=Collect
    Assert-Velocity (-not $facts.complete -and @($facts.gaps) -contains "merged-pr-body-incomplete:$prNumber") 'merged omitted body fails closed'
    $script:syntheticMerges=@();$script:syntheticOpenPrs=$true
    Write-Output 'PASS refs-only-merged-product and merged-pending-completion: synthetic collector -> report -> Summary'
    foreach($cause in @('red-check','native-blocker','stale-pass','skip')){
      switch($cause){
        'red-check' {$observation.pr.checks[0].status='FAILURE';$observation.pr.statusRollupState='FAILURE'}
        'native-blocker' {$observation.pr.closingIssues[0].blockers=@([pscustomobject]@{number=908529;state='OPEN'})}
        'stale-pass' {$pass.reviewedHead='d'*40;[IO.File]::WriteAllText($history,($pass|ConvertTo-Json -Compress -Depth 10)+[Environment]::NewLine)}
        'skip' {$pass.outcome='SKIP';[IO.File]::WriteAllText($history,($pass|ConvertTo-Json -Compress -Depth 10)+[Environment]::NewLine)}
      }
      $negativeStart=[datetime]::UtcNow;$negative=Capture-Report
      $null=Write-VelocityLandingCapture $capturePath $cycle $negativeStart @($negative)
      $r=Get-VelocityReport (Collect) ([datetime]::UtcNow) @()
      Assert-Velocity ($negative.reason -ceq 'PR_ALREADY_ENQUEUED' -and $negative.mutationCount -eq 0 -and $negative.velocityLanding.nonHoldPrerequisites.status -cne 'eligible' -and $r.metrics.heldCount -eq 0) "queued $cause is not held-only and never mutates"
      if($cause -ceq 'skip'){Assert-Velocity ($negative.velocityLanding.reviewReduction.latest.outcome -ceq 'SKIP') 'F2 real Report SKIP writes capture and never grants review flow';Write-Output 'PASS F2 SKIP Report -> capture -> collector'}
      $observation.pr.checks[0].status='SUCCESS';$observation.pr.statusRollupState='SUCCESS';$observation.pr.closingIssues[0].blockers=@();$pass.reviewedHead=$head
      $pass.outcome='PASS';[IO.File]::WriteAllText($history,($pass|ConvertTo-Json -Compress -Depth 10)+[Environment]::NewLine)
    }
    Save-Json $capturePath $capture
    foreach($case in @('stale','future','head','duplicate','cycle','partial','extra','missing-record','deleted')){
      $bad=$capture|ConvertTo-Json -Depth 64|ConvertFrom-Json -DateKind String
      switch($case){
        stale {$bad.startedAt=$clock.AddMinutes(-6).ToString('o')}
        future {$bad.completedAt=$clock.AddHours(1).ToString('o')}
        head {$bad.records[0].headOid='d'*40}
        duplicate {$bad.records+=@($bad.records[0])}
        cycle {$bad.cycleId='wrong-cycle'}
        partial {$bad.complete=$false}
        extra {$bad.records[0].requiredCheckAuthority.reductions[0].selected|Add-Member extra $true}
        'missing-record' {$bad.records=@()}
        deleted {}
      }
      Save-Json $capturePath $bad
      if($case -ceq 'deleted'){[IO.File]::Delete($capturePath)}
      $r=Get-VelocityReport (Collect) ([datetime]::UtcNow) @()
      Assert-Velocity (-not $r.factsComplete -and $r.metrics.floorState -ceq 'UNKNOWN' -and $r.metrics.heldCount -eq 0) "capture $case cannot confer held or healthy FLOOR"
    }
    Save-Json $capturePath $capture
    $null=Update-MergeHoldState -Path $holdPath -Action Lift -ExpectedRevision 2 -HoldId synthetic-hold -Now ([datetime]::UtcNow)
    $r=Get-VelocityReport (Collect) ([datetime]::UtcNow) @()
    Assert-Velocity ($r.metrics.heldCount -eq 0 -and @($r.metrics.flowingProductIssues) -contains $issueNumber) 'real producer lift restores queue flow'
    [IO.File]::Delete($holdPath)
    $r=Get-VelocityReport (Collect) ([datetime]::UtcNow) @()
    Assert-Velocity (-not $r.factsComplete -and $r.metrics.heldCount -eq 0) 'omitted hold source never becomes no-hold'
    $null=Update-MergeHoldState -Path $holdPath -Action Initialize -ExpectedRevision 0 -Reconciled -Now ([datetime]::UtcNow)
    # Verified ownership projection retains the exact current label and old origin.
    $label='908528-impl-g1.wd1.synthetic';$recordPath=Join-Path $runtime 'synthetic-owner.json'
    Save-Json $recordPath @{launchId='synthetic-launch';label=$label;head=$head;recordedAt=$clock.AddHours(-9).ToString('o')}
    Save-Json $ownershipPath @{health=@{status='ok'};activeLanes=@(@{lane='synthetic-seat';laneRole='implementation';launchId='synthetic-launch';ownershipRecordPath=$recordPath;worktree=$root;head=$head})}
    $rows=@(@{ts=$clock.AddDays(-8).ToString('o');kind='dispatch';issue=$issueNumber;lane='908528-impl-g1'},@{ts=$clock.AddHours(-9).ToString('o');kind='dispatch';dispatchRoutingSchema='watchdog-dispatch-routing/v2';label=$label;lane='synthetic-seat';attemptId='908528-impl-g1';worktree=$root;head=$head})
    [IO.File]::WriteAllLines((Join-Path $runtime 'dispatch-log.jsonl'),@($rows|ForEach-Object{$_|ConvertTo-Json -Compress}))
    $script:syntheticPr.mergeQueueEntry=$null;$script:syntheticPr.commits.nodes[0].commit.statusCheckRollup.state='FAILURE'
    $observation.pr.mergeQueueEntryId=$null;$started=[datetime]::UtcNow;$preflight=Capture-Report
    $capture=Write-VelocityLandingCapture $capturePath $cycle $started @($preflight)
    $facts=Collect;$r=Get-VelocityReport $facts ([datetime]::UtcNow) @()
    Assert-Velocity (@($r.metrics.flowingProductIssues) -contains $issueNumber -and @($r.metrics.readyNotInFlight).Count -eq 0) 'collector retains >7d origin and .wd alias with no queue or CI flow'
    Case 'ownership-projection-launcher-start' {
      # Captured b54c6450 record's projection fields; no live record access.
      $record=[pscustomobject]@{launchId='b54c6450-d77d-46fc-8994-7d74680aeac0';label='8952-impl-g1-cont2';head='c86379e85c4d411243a5099104e53de9af876504';recordedAt='2026-10-07T12:41:28.2694043Z';launcherStartIdentity='2026-10-07T12:40:48.3674298Z'}
      Save-Json $recordPath $record
      $owner=[pscustomobject]@{lane='20261006-8952-impl-g1';laneRole='implementation';launchId=$record.launchId;ownershipRecordPath=$recordPath;worktree='D:\Users\ToddS\Source\Repos\chase-sets\20261006-8952-impl-g1';head=$record.head}
      Save-Json $ownershipPath @{health=@{status='ok'};activeLanes=@($owner)}
      $collected=Collect
      $lane=$collected.activeLanes[0]
      Assert-Velocity ((Get-VelocityValue $lane 'launcherStartedAt') -ceq $record.launcherStartIdentity) 'actual Get-VelocityFacts copies launcherStartIdentity exactly'
      $projected=ConvertTo-VelocityActiveLane $owner $record
      foreach($lane in @($projected,$collected.activeLanes[0])){
        Assert-Velocity ((Get-VelocityValue $lane 'launcherStartedAt') -ceq $record.launcherStartIdentity -and $lane.startedAt -ceq $record.recordedAt -and $lane.launchHead -ceq $record.head -and $lane.label -ceq $record.label -and $lane.worktree -ceq $owner.worktree) 'helper and actual collector copy exact ownership identities and launcher start'
      }
    }
    Save-Json $ownershipPath @{health=@{status='ok'};activeLanes=@()}
    $r=Get-VelocityReport (Collect) ([datetime]::UtcNow) @()
    Assert-Velocity (@($r.metrics.flowingProductIssues).Count -eq 0) 'stopped ownership does not inherit old alias flow'
    $script:syntheticPr.commits.nodes[0].commit.statusCheckRollup.state='SUCCESS'
    $waiting=Collect;$r=Get-VelocityReport $waiting ([datetime]::UtcNow) @()
    Assert-Velocity (@($r.metrics.flowingProductIssues).Count -eq 0 -and @($r.metrics.readyNotInFlight) -contains $issueNumber) 'green PR without bound lane is ready idle in collector'
    Save-Json $factsPath $waiting
    $summary=& (Join-Path $PSScriptRoot 'velocity-metrics.ps1') -ContainerRoot $root -FactsPath $factsPath -NoRecord -Summary
    Assert-Velocity (($summary -join "`n").Contains("flowing= readyIdle=$issueNumber ")) 'green idle reaches Summary'
    $script:syntheticIssue.labels.nodes+=@([pscustomobject]@{name='status:needs-replan'});$script:syntheticIssue.labels.totalCount=2
    $r=Get-VelocityReport (Collect) ([datetime]::UtcNow) @()
    Assert-Velocity (@($r.diagnostics.terminalParkedIssues).Count -eq 1 -and @($r.metrics.readyNotInFlight).Count -eq 0) 'collector terminal park is distinct from ready idle'
    $script:syntheticIssue.labels.nodes=@([pscustomobject]@{name='kind:product'});$script:syntheticIssue.labels.totalCount=1
    $r=Get-VelocityReport (Collect) ([datetime]::UtcNow) @()
    Assert-Velocity (@($r.metrics.readyNotInFlight) -contains $issueNumber) 'synthetic unpark restores ordinary classification'
    $stop=@{ts=$clock.AddMinutes(-3).ToString('o');kind='rule-change';integrationAuthoritySchema='landed-integration-authority/v1';pr=$prNumber;issue=$issueNumber;targetBranch='synthetic/terminal';lineageRoot='synthetic/lineage';targetHead=$head;authorityState='STOP';authorityIssue=908530;authorityCommentId=900000001;operatorAuthority='Todd:908530#900000001'}
    $dispatchPath=Join-Path $runtime 'dispatch-log.jsonl'
    [IO.File]::AppendAllText($dispatchPath,($stop|ConvertTo-Json -Compress)+[Environment]::NewLine)
    $parked=Collect;$r=Get-VelocityReport $parked ([datetime]::UtcNow) @()
    Assert-Velocity ($r.diagnostics.terminalParkedIssues[0].state -ceq 'parked' -and @($r.metrics.readyNotInFlight).Count -eq 0) 'canonical terminal STOP receipt excludes ready idle without labels'
    Save-Json $factsPath $parked
    $summary=& (Join-Path $PSScriptRoot 'velocity-metrics.ps1') -ContainerRoot $root -FactsPath $factsPath -NoRecord -Summary
    Assert-Velocity (($summary -join "`n").Contains("terminalParked=$issueNumber")) 'terminal collector -> report -> Summary'
    $stopHash=(Read-ExactHeadReviewHistory $dispatchPath).rows[-1].rawSha256
    $release=$stop.Clone();$release.ts=$clock.AddMinutes(-2).ToString('o');$release.authorityState='RELEASE';$release.supersedes=$stopHash
    $eligible=$stop.Clone();$eligible.ts=$clock.AddMinutes(-1).ToString('o');$eligible.authorityState='ELIGIBLE';$eligible.authorityIssue=$null;$eligible.authorityCommentId=$null;$eligible.operatorAuthority=$null
    [IO.File]::AppendAllText($dispatchPath,(($release,$eligible|ForEach-Object{$_|ConvertTo-Json -Compress}) -join [Environment]::NewLine)+[Environment]::NewLine)
    $r=Get-VelocityReport (Collect) ([datetime]::UtcNow) @()
    Assert-Velocity (@($r.metrics.readyNotInFlight) -contains $issueNumber -and @($r.diagnostics.terminalParkedIssues).Count -eq 0) 'canonical release plus exact-head eligibility restores ordinary classification'
    $bad=$stop.Clone();$bad.authorityCommentId='malformed';$bad.ts=[datetime]::UtcNow.ToString('o')
    [IO.File]::AppendAllText($dispatchPath,($bad|ConvertTo-Json -Compress)+[Environment]::NewLine)
    $r=Get-VelocityReport (Collect) ([datetime]::UtcNow) @()
    Assert-Velocity (@($r.metrics.readyNotInFlight).Count -eq 0 -and $r.diagnostics.terminalParkedIssues[0].state -ceq 'unknown') 'malformed terminal authority is named unknown, never idle'
    Case 'F7-legacy-collector-summary-canonical-lines' {
      $legacy=@(1..6|ForEach-Object{@{at='2026-07-16T18:15:30.1349648Z';task="synthetic legacy $_";lane="lane-$_"}})
      [IO.File]::WriteAllLines($dispatchPath,@($legacy|ForEach-Object{'';$_|ConvertTo-Json -Compress}))
      $facts=Collect;$r=Get-VelocityReport $facts ([datetime]::UtcNow) @()
      Assert-Velocity ($facts.complete -and $r.factsComplete -and (@($r.diagnostics.legacyDispatchRows)-join ',') -ceq '2,4,6,8,10,12') 'F7 six inert rows survive collector as canonical-line diagnostics, not gaps'
      Save-Json $factsPath $facts
      $summary=& (Join-Path $PSScriptRoot 'velocity-metrics.ps1') -ContainerRoot $root -FactsPath $factsPath -NoRecord -Summary
      Assert-Velocity (($summary -join "`n").Contains('legacyDispatchRows=6')) 'F7 legacy diagnostic count reaches Summary'
      [IO.File]::AppendAllText($dispatchPath,"`n"+(@{ts='bad';kind='dispatch'}|ConvertTo-Json -Compress)+[Environment]::NewLine)
      $facts=Collect
      Assert-Velocity (-not $facts.complete -and @($facts.gaps) -contains 'dispatch-row-invalid:14:timestamp') 'N14 consumer gap uses canonical line after blanks'
    }
    Case 'F7-nonpositive-issue-collector' {
      $rows=@(@{ts=$clock.ToString('o');kind='dispatch';issue=0;lane='zero'},@{ts=$clock.ToString('o');kind='dispatch';issue=-1;lane='negative'})
      [IO.File]::WriteAllLines($dispatchPath,@($rows|ForEach-Object{'';$_|ConvertTo-Json -Compress}))
      $facts=Collect;$r=Get-VelocityReport $facts ([datetime]::UtcNow) @()
      Assert-Velocity ($facts.complete -and $r.factsComplete -and @($facts.gaps|Where-Object{$_ -like 'issue-kinds:*'}).Count -eq 0) 'F7 issue 0 and negative never poison GraphQL kind batch'
      Assert-Velocity ((@($r.diagnostics.nonPositiveIssueDispatchRows)-join ',') -ceq '2,4') 'F7 excluded issue-kind lookup rows retain canonical line diagnostics'
    }
    Case 'N15-unreadable-process-start-time' {
      [IO.File]::WriteAllText($dispatchPath,(@{ts=$clock.ToString('o');kind='dispatch';issue=$issueNumber;lane='protected-pid';note='pid 4'}|ConvertTo-Json -Compress)+[Environment]::NewLine)
      function Get-Process {param($Id,$ErrorAction) [pscustomobject]@{StartTime=$null}}
      $facts=Collect
      Assert-Velocity ($facts.complete -and @($facts.activeLanes).Count -eq 0 -and @($facts.gaps|Where-Object{$_ -like 'dispatch-pid-lanes:*'}).Count -eq 0) 'N15 unverifiable protected process is not live and does not void projection'
    }
  } finally {
    Set-Item Function:Invoke-VelocityGraphQL $savedGraph
    if([IO.Path]::GetFullPath($root).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $root -Recurse -Force}
  }
}
if($syntheticFailures.Count){throw ($syntheticFailures -join "`n")}
Write-Output "PASS velocity-metrics assertions=$script:assertions"
} finally {
  Exit-RoutingDataTestScope $routingTestScope
}
