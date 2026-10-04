[CmdletBinding()]
param()

# #8207 velocity-report/v1 boundaries on synthetic facts. No network, no
# ownership probe, no dispatch-log read.

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "velocity-metrics.ps1")
$script:assertions = 0
function Assert-Velocity([bool]$Condition, [string]$Message) {
  $script:assertions += 1
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

$now = ConvertTo-VelocityUtc "2026-09-26T12:00:00Z"
function T([double]$HoursAgo) { return (Format-VelocityUtc $now.AddHours(-$HoursAgo)) }
function Issue([int]$Number, [string[]]$Labels = @("kind:product", "priority:p1"), [int]$Milestone = 148, [bool]$Committed = $true, [int]$Blockers = 0) {
  return [pscustomobject]@{ number = $Number; labels = $Labels; milestone = [pscustomobject]@{ number = $Milestone; committed = $Committed }; openBlockers = $Blockers }
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
      [pscustomobject]@{ pr = 1; mergedAt = (T 10); issues = @([pscustomobject]@{ number = 11; kinds = @("kind:product"); productLabeledAt = (T 200) }) },
      [pscustomobject]@{ pr = 2; mergedAt = (T 20); issues = @([pscustomobject]@{ number = 12; kinds = @("kind:ops"); productLabeledAt = $null }) },
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
$late = @([pscustomobject]@{ pr = 4; mergedAt = (T 5); issues = @([pscustomobject]@{ number = 44; kinds = @("kind:product"); productLabeledAt = (T 6) }) })
$r = Get-VelocityReport (Facts @{ dispatchRows = @($stale + $decisions); merges = $late; lastProductMergeAt = (T 5) }) $now @()
Assert-Velocity ((@($r.diagnostics.staleAttempts | ForEach-Object issue) -join ",") -ceq "100") "an implementation lane 9 h without a push is stale; 3 h is not"
$pushed = @([pscustomobject]@{ pr = 9; issues = @(100); isDraft = $true; inMergeQueue = $false; ciState = "FAILURE"; headCommittedAt = (T 1) })
$r2 = Get-VelocityReport (Facts @{ dispatchRows = $stale; productPrs = $pushed }) $now @()
Assert-Velocity (@($r2.diagnostics.staleAttempts).Count -eq 0) "a recent push clears the stale-attempt flag"
Assert-Velocity ((@($r.diagnostics.decisionHeavyIssues | ForEach-Object issue) -join ",") -ceq "101") "three decision lanes in 24 h flag the issue"
Assert-Velocity (@($r.diagnostics.lateProductRelabels).Count -eq 1 -and $r.diagnostics.lateProductRelabels[0].pr -eq 4) "kind:product applied within 48 h of merge is flagged"
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
Case 'launch-issue-no-host-row' {
  $rows=@([pscustomobject]@{ts=(T 2);kind='dispatch';dispatchRoutingSchema='watchdog-dispatch-routing/v2';issue=100;attemptId='100-g2';label='100-g2';lane='seat';worktree='D:\synthetic\seat'})
  $map=Get-VelocityLaneIssueMap $rows
  Assert-Velocity ($map['100-g2'].issue -eq 100) 'launcher label maps without a HOST row'
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
  $source=(& git -C (Split-Path -Parent $PSScriptRoot) show f292db3c0c89aba867b7ae10da6fffd0fc2970ee:.orchestrator/velocity-metrics.ps1) -join "`n"
  $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
  $old=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Get-VelocityReport'},$true)
  . ([scriptblock]::Create($old.Extent.Text))
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
    $script:syntheticIssue=[pscustomobject]@{number=$issueNumber;body='synthetic product';labels=[pscustomobject]@{totalCount=1;nodes=@([pscustomobject]@{name='kind:product'})};milestone=[pscustomobject]@{number=148;state='OPEN';description='<!-- outcome: {"status":"committed"} -->'};blockedBy=[pscustomobject]@{totalCount=0;nodes=@()}}
    $script:syntheticPr=[pscustomobject]@{number=$prNumber;body='';repository=[pscustomobject]@{nameWithOwner='synthetic/velocity'};headRefOid=$head;isDraft=$false;mergeQueueEntry=[pscustomobject]@{id='MQE_SYNTHETIC_8526';state='QUEUED'};commits=[pscustomobject]@{nodes=@([pscustomobject]@{commit=[pscustomobject]@{oid=$head;committedDate=$clock.ToString('o');statusCheckRollup=[pscustomobject]@{state='SUCCESS'}}})};closingIssuesReferences=[pscustomobject]@{totalCount=1;nodes=@([pscustomobject]@{number=$issueNumber;labels=$script:syntheticIssue.labels})}}
    $script:syntheticMerges=@();$script:syntheticOpenPrs=$true
    $script:syntheticMergeIssue=[pscustomobject]@{number=$issueNumber;labels=$script:syntheticIssue.labels;timelineItems=[pscustomobject]@{nodes=@()}}
    function Invoke-VelocityGraphQL([string]$Query,[hashtable]$Variables){
      if($Query -match 'issueOrPullRequest\(number:(?:0|-)'){throw 'synthetic GraphQL refuses non-positive issue number'}
      if($Query.Contains('issue(number:')){
        Assert-Velocity ($Query.Contains('labels(first:30){totalCount') -and $Query.Contains('timelineItems')) 'merged body lookup requests complete labels and relabel diagnostics'
        return [pscustomobject]@{repository=[pscustomobject]@{"i$issueNumber"=$script:syntheticMergeIssue}}
      }
      if($Variables.q -like '*is:merged*'){
        foreach($field in @('number body repository','mergedAt','closingIssuesReferences(first:5){totalCount','labels(first:30){totalCount')){Assert-Velocity ($Query.Contains($field)) "merged collector requests $field"}
        $nodes=@($script:syntheticMerges)
      }
      elseif($Variables.q -like '*is:issue*'){$nodes=@(if($null -ne $script:syntheticIssue){$script:syntheticIssue})}
      elseif($Variables.q -like '*is:pr is:open*'){
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
    Assert-Velocity ($facts.complete -and $null -eq $facts.lastProductMergeAt) 'merged Refs issue must be product-qualified'
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
