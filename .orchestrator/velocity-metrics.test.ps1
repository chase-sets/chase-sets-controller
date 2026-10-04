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
  }
  foreach ($key in $Override.Keys) { $base[$key] = $Override[$key] }
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
Assert-Velocity ((@($r.metrics.flowingProductIssues) -join ",") -ceq "101,102") "running CI and merge queue flow; red CI with no owner does not"
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

Write-Output "PASS velocity-metrics assertions=$script:assertions"
