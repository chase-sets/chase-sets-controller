$ErrorActionPreference = "Stop"

# Every case here runs through -DryRun, so the suite is hermetic: it exercises
# the event -> board state machine without a GitHub round trip. The network
# paths are covered by the fail-open contract (a broken call must warn and
# return ok:false, never throw into a dispatch), asserted at the bottom.

$board = Join-Path $PSScriptRoot "board-set.ps1"

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Assert-Throws([scriptblock]$Action, [string]$Pattern, [string]$Message) {
  try {
    & $Action
    throw "ASSERTION FAILED: $Message (did not throw)"
  }
  catch {
    if ($_.Exception.Message -like "ASSERTION FAILED:*") { throw }
    if ($_.Exception.Message -notmatch $Pattern) {
      throw "ASSERTION FAILED: $Message (unexpected: $($_.Exception.Message))"
    }
  }
}

function Get-Intent {
  param([hashtable]$Splat)
  return (& $board -Issue 4242 -DryRun @Splat | ConvertFrom-Json)
}

function Assert-Intent {
  param([hashtable]$Splat, [string]$Action, [string]$Status, [string]$Message)
  $r = Get-Intent $Splat
  Assert-True ($r.action -eq $Action) "$Message (action: expected $Action, got $($r.action))"
  if ($Action -eq "set") {
    Assert-True ($r.status -eq $Status) "$Message (status: expected '$Status', got '$($r.status)')"
  }
  else {
    Assert-True (-not $r.status) "$Message (a non-set intent must carry no status, got '$($r.status)')"
  }
  Assert-True ($r.ok -eq $true) "$Message (dry runs always succeed)"
}

try {
  # --- dispatch: the lane role decides which lane-owned column it lands in ---
  Assert-Intent @{ EventKind = "dispatch" } "set" "In lane" "a bare dispatch is In lane"
  Assert-Intent @{ EventKind = "dispatch"; LaneRole = "implementation" } "set" "In lane" "implementation dispatch is In lane"
  Assert-Intent @{ EventKind = "dispatch"; LaneRole = "planning" } "set" "In lane" "a planning lane is still a lane"
  Assert-Intent @{ EventKind = "dispatch"; LaneRole = "review" } "set" "In review" "review dispatch is In review"
  Assert-Intent @{ EventKind = "dispatch"; LaneRole = "REVIEW" } "set" "In review" "lane role is case-insensitive"

  # --- the §7 gate owns work between lane completion and landing ---
  Assert-Intent @{ EventKind = "lane-complete" } "set" "In review" "a complete lane hands off to the gate"
  Assert-Intent @{ EventKind = "repair-complete" } "set" "In review" "a repair returns to the gate"

  # --- review dispositions ---
  Assert-Intent @{ EventKind = "review-complete"; Outcome = "PASS" } "set" "In review" "PASS still awaits enqueue"
  Assert-Intent @{ EventKind = "review-complete"; Outcome = "SKIP" } "set" "In review" "a skipped gate still awaits enqueue"
  Assert-Intent @{ EventKind = "review-complete"; Outcome = "BLOCK_FIXABLE" } "set" "In lane" "fixable blocks route back to a lane"
  Assert-Intent @{ EventKind = "review-complete"; Outcome = "BLOCK_REPLAN" } "clear" $null "a specification defect leaves lane ownership"
  Assert-Intent @{ EventKind = "review-complete"; Outcome = "BLOCK_FIXABLE"; ReviewAuthority = "shadow" } "none" $null "a shadow finding never moves the governing board state"
  Assert-Intent @{ EventKind = "review-complete"; Outcome = "BLOCK_REPLAN"; ReviewAuthority = "advisory" } "none" $null "an advisory finding never clears the governing board state"

  # --- landing ---
  Assert-Intent @{ EventKind = "landed" } "set" "Landed" "a merge is Landed"

  # --- replan-family outcomes, which ride on several kinds ---
  Assert-Intent @{ EventKind = "lane-blocked"; Outcome = "PARKED_DECISION" } "clear" $null "a decision park hands back to the derived owner"
  Assert-Intent @{ EventKind = "note"; Outcome = "REPLAN_REQUIRED" } "clear" $null "replan-required leaves no lane owner"
  Assert-Intent @{ EventKind = "dispatch"; Outcome = "REPLAN_STARTED" } "set" "In lane" "an active planning pass is In lane"
  Assert-Intent @{ EventKind = "repair-complete"; Outcome = "REPLAN_REPLACED" } "clear" $null "the replaced original stops carrying lane state"
  Assert-Intent @{ EventKind = "repair-complete"; Outcome = "REPLAN_COMPLETE" } "set" "Landed" "a satisfied replan is Landed"

  # A replan-family outcome must win over the kind it rides on, or a
  # `dispatch` row carrying REPLAN_REPLACED would re-open lane ownership on an
  # issue whose successor already owns it.
  Assert-Intent @{ EventKind = "dispatch"; LaneRole = "review"; Outcome = "REPLAN_REPLACED" } "clear" $null "replan outcomes outrank the event kind"

  # --- kinds that say nothing about ownership must not move the board ---
  foreach ($quiet in @("enqueue", "dequeue", "stall", "deploy-verified", "breaker-open",
      "breaker-clear", "decision-filed", "decision-resolved", "scale",
      "escaped-defect", "rule-change", "gc", "landing-stall",
      "verify-complete")) {
    Assert-Intent @{ EventKind = $quiet } "none" $null "'$quiet' does not change lane ownership"
  }

  # --- explicit modes ---
  Assert-Intent @{ Status = "In review" } "set" "In review" "an explicit status is honored"
  Assert-Intent @{ Clear = $true } "clear" $null "an explicit clear is honored"

  # --- the derived three are not ours to write ---
  # project-status-sync.mjs derives Backlog/Refined/Blocked hourly; a write from
  # here would race that job and silently win, reintroducing exactly the drift
  # the generated board was built to end.
  foreach ($derived in @("Backlog", "Refined", "Blocked")) {
    Assert-Throws { & $board -Issue 4242 -Status $derived -DryRun } "ValidateSet|not belong|argument" `
      "'$derived' is refused: it belongs to project-status-sync.mjs"
  }

  # No event kind may ever resolve to a derived status, whatever the outcome.
  foreach ($kind in @("dispatch", "lane-complete", "lane-blocked", "review-complete",
      "repair-complete", "landed", "note")) {
    foreach ($outcome in @("", "PASS", "BLOCK_FIXABLE", "BLOCK_REPLAN", "PARKED_DECISION",
        "REPLAN_REQUIRED", "REPLAN_STARTED", "REPLAN_REPLACED", "REPLAN_COMPLETE")) {
      $r = Get-Intent @{ EventKind = $kind; Outcome = $outcome }
      Assert-True ($r.status -in @($null, "", "In lane", "In review", "Landed")) `
        "'$kind'/'$outcome' resolved to '$($r.status)', which is not lane-owned"
    }
  }

  # --- fail-open: bookkeeping never takes a dispatch down with it -------------
  # A dispatch that dies because the board was unreachable would be strictly
  # worse than an unrecorded board move, so the default path swallows and warns.
  $broken = & $board -Issue 4242 -EventKind dispatch -GhCommand "definitely-not-a-real-gh-binary" `
    -WarningAction SilentlyContinue 2>$null | ConvertFrom-Json
  Assert-True ($broken.ok -eq $false) "an unreachable board returns ok:false"
  Assert-True ([bool]$broken.error) "a failed write reports why"

  Assert-Throws { & $board -Issue 4242 -EventKind dispatch -GhCommand "definitely-not-a-real-gh-binary" -Strict } `
    "." "-Strict turns fail-open into fail-loud"

  Write-Output "board-set.test.ps1: PASS"
}
catch {
  Write-Error $_
  exit 1
}
