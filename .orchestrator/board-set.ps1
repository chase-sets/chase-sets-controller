<#
.SYNOPSIS
Write a LANE-OWNED Status onto the delivery board (milestone-orchestrator
SKILL.md §14). This is the orchestrator's half of the seam that
`scripts/project-status-sync.mjs` (chase-sets PR #6161) deliberately left open.

.DESCRIPTION
The board's Status field has six options and two owners:

  Backlog / Refined / Blocked   derived hourly by scripts/project-status-sync.mjs
                                from dependencies + milestone + labels.
  In lane / In review / Landed  owned HERE. Nothing else writes them, which is
                                why the board read 0/0/0 on those three for the
                                whole program while 605 items sat on it.

The sync job never clobbers a lane-owned state:

    if (item.status && !DERIVED_STATUSES.includes(item.status)) continue;

That non-clobber rule is correct, and it is also a trap: once this script writes
"In lane", the hourly job will never correct that item again. A lane that dies
without a terminal write leaves its issue pinned to "In lane" forever — the same
rot the sync script's own header complains about, one column over. So writing a
lane state incurs an obligation to end it, and `board-reconcile.ps1` is the
backstop that catches the ones nobody ended.

**Clearing is the handoff.** `-Clear` removes the Status value entirely rather
than guessing a derived one; the next sync run recomputes Backlog/Refined/Blocked
from the facts. Deriving it here would fork the derivation.

**Fail-open.** A board write is bookkeeping, never a gate. Every failure warns
and returns `{"ok":false}` with exit 0 so a dispatch is never lost to a GitHub
blip. Pass -Strict to make failures throw (used by the tests and by anyone
debugging the wiring).

.EXAMPLE
./board-set.ps1 -Issue 6155 -Status 'In lane'

.EXAMPLE
./board-set.ps1 -Issue 6155 -EventKind review-complete -Outcome BLOCK_FIXABLE

.EXAMPLE
./board-set.ps1 -Issue 6155 -Clear
#>
[CmdletBinding(DefaultParameterSetName = "Event")]
param(
  [Parameter(Mandatory)][int]$Issue,

  # Lane-owned states only. The derived three belong to project-status-sync.mjs
  # and are never written from here — writing one would race the hourly job and
  # silently win, which is exactly the drift this board was rebuilt to end.
  [Parameter(Mandatory, ParameterSetName = "Set")]
  [ValidateSet("In lane", "In review", "Landed")][string]$Status,

  # Hand the item back to the derived owner (removes the Status value).
  [Parameter(Mandatory, ParameterSetName = "Clear")][switch]$Clear,

  # Derive the intent from a §14 telemetry event instead of naming a state.
  # This is how log-event.ps1 calls it, so the event -> board state machine
  # lives in exactly one place.
  [Parameter(Mandatory, ParameterSetName = "Event")][string]$EventKind,
  [Parameter(ParameterSetName = "Event")][string]$LaneRole,
  [Parameter(ParameterSetName = "Event")][string]$Outcome,
  [Parameter(ParameterSetName = "Event")][ValidateSet("governing", "shadow", "advisory")][string]$ReviewAuthority,

  [string]$Repo = "chase-sets/chase-sets",
  # Resolve the intent and print the plan without touching the network.
  [switch]$DryRun,
  # Turn fail-open into fail-loud. Tests and manual debugging only.
  [switch]$Strict,
  # Test seam; production uses the real CLI.
  [string]$GhCommand = "gh"
)

$ErrorActionPreference = "Stop"

$LaneOwnedStatuses = @("In lane", "In review", "Landed")
$DerivedStatuses = @("Backlog", "Refined", "Blocked")

# --- Event -> board intent ---------------------------------------------------
# The state machine. Pure, so board-set.test.ps1 can hold every arm of it
# without a network. `none` is a first-class answer: most canonical kinds
# (enqueue, stall, deploy-verified, breaker-*, gc, note) say nothing about who
# owns the issue, and a bookkeeping event that quietly moved the board would be
# worse than one that did nothing.
function Resolve-BoardIntent {
  param([string]$EventKind, [string]$LaneRole, [string]$Outcome, [string]$ReviewAuthority)

  $kind = ("$EventKind").Trim().ToLowerInvariant()
  $role = ("$LaneRole").Trim().ToLowerInvariant()
  $out = ("$Outcome").Trim().ToUpperInvariant()
  $authority = ("$ReviewAuthority").Trim().ToLowerInvariant()

  # Replan-family outcomes ride on several kinds, so they are read first.
  # These mirror the §14 canon in log-event.ps1 exactly.
  switch ($out) {
    # A decision park and a bare replan requirement both hand the issue back to
    # the derived owner: it will land on Blocked (the decision is a dependency)
    # or Backlog, and which one is the sync job's call, not ours.
    "PARKED_DECISION" { return @{ action = "clear"; status = $null; why = "parked on a decision; derived owner recomputes" } }
    "REPLAN_REQUIRED" { return @{ action = "clear"; status = $null; why = "replan required; no lane owns it" } }
    # A planning lane IS a lane.
    "REPLAN_STARTED" { return @{ action = "set"; status = "In lane"; why = "planning lane active" } }
    # The original becomes tracking-only and the replacement carries its own
    # row; leaving the original "In lane" is how #5684 stayed invisible.
    "REPLAN_REPLACED" { return @{ action = "clear"; status = $null; why = "replaced; successor carries the lane state" } }
    "REPLAN_COMPLETE" { return @{ action = "set"; status = "Landed"; why = "replacement landed and satisfied the original" } }
  }

  switch ($kind) {
    "dispatch" {
      if ($role -eq "review") { return @{ action = "set"; status = "In review"; why = "review lane dispatched" } }
      return @{ action = "set"; status = "In lane"; why = "lane dispatched" }
    }
    # Work is done; the §7 gate now owns it.
    "lane-complete" { return @{ action = "set"; status = "In review"; why = "lane complete, awaiting the review gate" } }
    "repair-complete" { return @{ action = "set"; status = "In review"; why = "repair complete, back to the gate" } }
    "lane-blocked" { return @{ action = "clear"; status = $null; why = "lane stopped without a successor" } }
    "review-complete" {
      if ($authority -in @("shadow", "advisory")) {
        return @{ action = "none"; status = $null; why = "non-governing controller review outcome" }
      }
      switch ($out) {
        "PASS" { return @{ action = "set"; status = "In review"; why = "passed the gate, awaiting enqueue" } }
        "SKIP" { return @{ action = "set"; status = "In review"; why = "gate skipped, awaiting enqueue" } }
        "BLOCK_FIXABLE" { return @{ action = "set"; status = "In lane"; why = "blocking findings routed to repair" } }
        "BLOCK_REPLAN" { return @{ action = "clear"; status = $null; why = "specification defect; planning owns it" } }
      }
      return @{ action = "none"; status = $null; why = "review-complete with no recognized outcome" }
    }
    "landed" { return @{ action = "set"; status = "Landed"; why = "merged" } }
  }

  return @{ action = "none"; status = $null; why = "kind '$kind' does not change lane ownership" }
}

function Write-Result([hashtable]$Result) {
  Write-Output (([ordered]@{
        ok     = $Result.ok
        issue  = $Result.issue
        action = $Result.action
        status = $Result.status
        why    = $Result.why
        error  = $Result.error
      }) | ConvertTo-Json -Compress -Depth 3)
}

function Invoke-GhJson([string[]]$GhArguments, [string]$What) {
  $raw = & $GhCommand @GhArguments 2>&1
  if ($LASTEXITCODE -ne 0) { throw "$What failed (gh exit ${LASTEXITCODE}): $raw" }
  if (-not "$raw".Trim()) { throw "$What returned nothing" }
  return "$raw" | ConvertFrom-Json
}

# --- Resolve the intent ------------------------------------------------------
$intent =
if ($PSCmdlet.ParameterSetName -eq "Set") { @{ action = "set"; status = $Status; why = "explicit" } }
elseif ($PSCmdlet.ParameterSetName -eq "Clear") { @{ action = "clear"; status = $null; why = "explicit" } }
else { Resolve-BoardIntent -EventKind $EventKind -LaneRole $LaneRole -Outcome $Outcome -ReviewAuthority $ReviewAuthority }

if ($intent.action -eq "set" -and $intent.status -notin $LaneOwnedStatuses) {
  $message = "refusing to write '$($intent.status)': only $($LaneOwnedStatuses -join ', ') are lane-owned; $($DerivedStatuses -join '/') belong to project-status-sync.mjs"
  if ($Strict) { throw $message }
  Write-Warning $message
  Write-Result @{ ok = $false; issue = $Issue; action = "none"; status = $null; why = $intent.why; error = $message }
  return
}

if ($intent.action -eq "none" -or $DryRun) {
  Write-Result @{ ok = $true; issue = $Issue; action = $intent.action; status = $intent.status; why = $intent.why; error = $null }
  return
}

# --- Apply -------------------------------------------------------------------
try {
  # Config comes from the SAME repo variables CI reads, so the board can never
  # be driven by two disagreeing copies of the field ids.
  $projectId = (& $GhCommand variable get DELIVERY_PROJECT_ID --repo $Repo 2>&1 | Out-String).Trim()
  if ($LASTEXITCODE -ne 0 -or -not $projectId) { throw "DELIVERY_PROJECT_ID is unreadable" }
  $fieldId = (& $GhCommand variable get DELIVERY_STATUS_FIELD_ID --repo $Repo 2>&1 | Out-String).Trim()
  if ($LASTEXITCODE -ne 0 -or -not $fieldId) { throw "DELIVERY_STATUS_FIELD_ID is unreadable" }

  $optionId = $null
  if ($intent.action -eq "set") {
    $optionsRaw = (& $GhCommand variable get DELIVERY_STATUS_OPTION_IDS --repo $Repo 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $optionsRaw) { throw "DELIVERY_STATUS_OPTION_IDS is unreadable" }
    $options = $optionsRaw | ConvertFrom-Json
    $optionId = $options.$($intent.status)
    if (-not $optionId) {
      throw "DELIVERY_STATUS_OPTION_IDS has no id for '$($intent.status)' — add the lane-owned option ids to that repo variable"
    }
  }

  $owner, $name = $Repo.Split("/", 2)
  $lookup = Invoke-GhJson @(
    "api", "graphql",
    "-f", "query=query(`$owner:String!,`$name:String!,`$number:Int!){repository(owner:`$owner,name:`$name){issue(number:`$number){id number projectItems(first:20){nodes{id project{id}}}}}}",
    "-F", "owner=$owner", "-F", "name=$name", "-F", "number=$Issue"
  ) "issue lookup"

  $issueNode = $lookup.data.repository.issue
  if (-not $issueNode) { throw "issue #$Issue not found in $Repo" }

  $itemId = ($issueNode.projectItems.nodes | Where-Object { $_.project.id -eq $projectId } | Select-Object -First 1).id

  if (-not $itemId) {
    # An issue in a lane that is not on the board is exactly the invisibility
    # this work exists to end, so add it rather than skipping it.
    $added = Invoke-GhJson @(
      "api", "graphql",
      "-f", "query=mutation(`$p:ID!,`$c:ID!){addProjectV2ItemById(input:{projectId:`$p,contentId:`$c}){item{id}}}",
      "-F", "p=$projectId", "-F", "c=$($issueNode.id)"
    ) "board item add"
    $itemId = $added.data.addProjectV2ItemById.item.id
    if (-not $itemId) { throw "could not add issue #$Issue to the board" }
  }

  if ($intent.action -eq "set") {
    [void](Invoke-GhJson @(
        "api", "graphql",
        "-f", "query=mutation(`$p:ID!,`$i:ID!,`$f:ID!,`$o:String!){updateProjectV2ItemFieldValue(input:{projectId:`$p,itemId:`$i,fieldId:`$f,value:{singleSelectOptionId:`$o}}){projectV2Item{id}}}",
        "-F", "p=$projectId", "-F", "i=$itemId", "-F", "f=$fieldId", "-F", "o=$optionId"
      ) "status write")
  }
  else {
    [void](Invoke-GhJson @(
        "api", "graphql",
        "-f", "query=mutation(`$p:ID!,`$i:ID!,`$f:ID!){clearProjectV2ItemFieldValue(input:{projectId:`$p,itemId:`$i,fieldId:`$f}){projectV2Item{id}}}",
        "-F", "p=$projectId", "-F", "i=$itemId", "-F", "f=$fieldId"
      ) "status clear")
  }

  Write-Result @{ ok = $true; issue = $Issue; action = $intent.action; status = $intent.status; why = $intent.why; error = $null }
}
catch {
  $message = $_.Exception.Message
  if ($Strict) { throw }
  # Fail-open: bookkeeping must never take a dispatch down with it.
  Write-Warning "board-set: #$Issue -> $($intent.action) $($intent.status) failed: $message"
  Write-Result @{ ok = $false; issue = $Issue; action = $intent.action; status = $intent.status; why = $intent.why; error = $message }
}
