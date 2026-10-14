<#
.SYNOPSIS
Write a LANE-OWNED Status onto the delivery board (milestone-orchestrator
SKILL.md §14). This is the orchestrator's half of the seam that
`scripts/project-status-sync.mjs` (chase-sets PR #6161) deliberately left open.

.DESCRIPTION
In lane means a live implementation; otherwise In review means a live review
or an open non-draft closing PR. Only open executable issues are projected.
Derived, closed, Epic and Tracking states belong to project-status-sync.
Explicit manual -Status Landed remains supported; events never write Landed.
The shared observation in board-reconcile.ps1 protects other live attempts
before an event writes. Its hourly sweep repairs missed terminal events.

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
  [Parameter(ParameterSetName = "Event")][int]$Pr,
  [Parameter(ParameterSetName = "Event")][ValidateSet("governing", "shadow", "advisory")][string]$ReviewAuthority,

  [string]$Repo = "chase-sets/chase-sets",
  # Resolve the intent and print the plan without touching the network.
  [switch]$DryRun,
  # Turn fail-open into fail-loud. Tests and manual debugging only.
  [switch]$Strict,
  # Test seam; production uses the real CLI.
  [string]$GhCommand = "gh",
  [string]$DispatchLog,
  # Reconciliation binds its final read to the writer's own last observation.
  [Parameter(DontShow)][psobject]$ExpectedObservation
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
  param([string]$EventKind, [string]$LaneRole, [string]$Outcome, [string]$ReviewAuthority, [int]$Pr)

  $kind = ("$EventKind").Trim().ToLowerInvariant()
  $role = ("$LaneRole").Trim().ToLowerInvariant()
  $out = ("$Outcome").Trim().ToUpperInvariant()
  $authority = ("$ReviewAuthority").Trim().ToLowerInvariant()
  if ($role -in @('planning', 'decision', 'capture')) {
    return @{ action = 'none'; status = $null; why = 'non-execution lane never owns board status' }
  }

  # Replan-family outcomes ride on several kinds, so they are read first.
  # These mirror the §14 canon in log-event.ps1 exactly.
  switch ($out) {
    # A decision park and a bare replan requirement both hand the issue back to
    # the derived owner: it will land on Blocked (the decision is a dependency)
    # or Backlog, and which one is the sync job's call, not ours.
    "PARKED_DECISION" { return @{ action = "clear"; status = $null; why = "parked on a decision; derived owner recomputes" } }
    "REPLAN_REQUIRED" { return @{ action = "clear"; status = $null; why = "replan required; no lane owns it" } }
    "REPLAN_STARTED" { return @{ action = "none"; status = $null; why = "planning does not own board status" } }
    # The original becomes tracking-only and the replacement carries its own
    # row; leaving the original "In lane" is how #5684 stayed invisible.
    "REPLAN_REPLACED" { return @{ action = "clear"; status = $null; why = "replaced; successor carries the lane state" } }
    "REPLAN_COMPLETE" { return @{ action = "clear"; status = $null; why = "replacement satisfied original; sync owns terminal state" } }
  }

  switch ($kind) {
    "dispatch" {
      if ($role -eq "implementation") { return @{ action = "set"; status = "In lane"; why = "implementation dispatched" } }
      if ($role -eq "review" -or $authority -eq 'governing') { return @{ action = "set"; status = "In review"; why = "review lane dispatched" } }
      return @{ action = 'none'; status = $null; why = 'dispatch has no execution role' }
    }
    # Work is done; the §7 gate now owns it.
    { $_ -in @('lane-complete', 'repair-complete') } {
      if ($role -ne 'implementation') { return @{ action = 'none'; status = $null; why = 'completion has no implementation authority' } }
      if ($Pr -gt 0) { return @{ action = 'set'; status = 'In review'; why = 'implementation complete with PR' } }
      return @{ action = 'clear'; status = $null; why = 'implementation complete without PR' }
    }
    "lane-blocked" { return @{ action = "clear"; status = $null; why = "lane stopped without a successor" } }
    "review-complete" {
      if ($authority -in @("shadow", "advisory")) {
        return @{ action = "none"; status = $null; why = "non-governing controller review outcome" }
      }
      if ($role -ne 'review' -and $authority -ne 'governing') { return @{ action = 'none'; status = $null; why = 'completion has no review authority' } }
      if ($out -ne 'BLOCK_REPLAN' -and $Pr -gt 0) { return @{ action = 'set'; status = 'In review'; why = 'review complete with PR' } }
      return @{ action = 'clear'; status = $null; why = 'review released lane ownership' }
    }
    "landed" { return @{ action = "clear"; status = $null; why = "merged; sync owns terminal state" } }
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
else { Resolve-BoardIntent -EventKind $EventKind -LaneRole $LaneRole -Outcome $Outcome -ReviewAuthority $ReviewAuthority -Pr $Pr }

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

  # Event intents are candidates, not authority over another attempt. Reuse the
  # backstop's observation, without running its sweep or dispatching a workflow.
  $eventMode = $PSCmdlet.ParameterSetName -eq 'Event'
  . (Join-Path $PSScriptRoot 'board-reconcile.ps1') -FunctionsOnly -Repo $Repo -DispatchLog $DispatchLog -GhCommand $GhCommand
  $item = Get-BoardIssue $Issue $Repo $projectId $GhCommand
  $path = if ($DispatchLog) { [IO.Path]::GetFullPath($DispatchLog) } else { Join-Path $PSScriptRoot 'dispatch-log.jsonl' }
  $observation = Get-BoardProjection $item $(if ($eventMode -or $ExpectedObservation) { Get-BoardHistory $path } else { @{ rows = @(); specs = @{}; errors = @(); count = 0 } })
  if (-not $observation.eligible -or -not $observation.known) {
    Write-Result @{ ok = $true; issue = $Issue; action = 'none'; status = $null; why = $observation.why; error = $null }
    return
  }
  if ($ExpectedObservation -and -not (Test-BoardObservationUnchanged $ExpectedObservation $observation)) {
    Write-Result @{ ok = $true; issue = $Issue; action = 'none'; status = $null; why = 'deferred: writer observation changed'; error = $null }
    return
  }
  if ($eventMode) {
    $fresh = Get-BoardProjection (Get-BoardIssue $Issue $Repo $projectId $GhCommand) (Get-BoardHistory $path)
    if (-not (Test-BoardObservationUnchanged $observation $fresh)) {
      Write-Result @{ ok = $true; issue = $Issue; action = 'none'; status = $null; why = "deferred: changed or unknown observation; $($fresh.why)"; error = $null }
      return
    }
    $intent = @{ action = $fresh.action; status = $fresh.desired; why = $fresh.why }
    if ($intent.action -eq 'none') {
      Write-Result @{ ok = $true; issue = $Issue; action = 'none'; status = $null; why = $intent.why; error = $null }
      return
    }
  }

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

  $issueNode = $item.content
  if (-not $issueNode) { throw "issue #$Issue not found in $Repo" }

  $itemId = $item.id

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
