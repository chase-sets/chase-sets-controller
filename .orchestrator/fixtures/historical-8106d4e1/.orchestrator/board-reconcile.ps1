<#
.SYNOPSIS
Sweep stale lane-owned board states (milestone-orchestrator SKILL.md §9/§14).
The backstop for `board-set.ps1`, not the mechanism — the mechanism is the
terminal write-back every lane exit owes.

.DESCRIPTION
`scripts/project-status-sync.mjs` never overwrites a lane-owned Status:

    if (item.status && !DERIVED_STATUSES.includes(item.status)) continue;

So the moment the orchestrator writes "In lane", the hourly derived job stops
correcting that item — permanently. A lane that dies, is killed, or is
abandoned without a terminal write leaves its issue pinned to a lane state
forever, and the board is then lying in the one column that was supposed to
make delivery legible.

This script finds those and hands them back to the derived owner. It is
deliberately biased toward doing nothing: three independent liveness signals
must ALL say the issue is dead before it is swept, because a false clear
briefly hides live work while a missed clear is corrected on the next run.

  1. **Lifecycle telemetry.** The latest row for the issue's lane is dispatch.
  2. **Open linked PR.** GitHub reports an open PR that would close the issue.
  3. **Recent telemetry.** Any dispatch-log row for the issue inside
     -MinIdleHours — this covers the window between a dispatch and the first
     terminal lifecycle row.

`Landed` is never swept: it is terminal by construction. A `Landed` item whose
issue is still open is reported instead, because §13 records Closes-automation
closing issues while dropping evidence ACs — the inverse (merged, issue never
closed) is the same machinery failing the other way, and it is worth a look
rather than a silent board edit.

.EXAMPLE
./board-reconcile.ps1

.EXAMPLE
./board-reconcile.ps1 -Apply
#>
[CmdletBinding()]
param(
  # Perform the clears. Report-only by default.
  [switch]$Apply,
  # Telemetry grace window for recent lane activity.
  [double]$MinIdleHours = 2,
  # Blast-radius cap. A sweep that wants to clear more than this in one run is
  # far more likely to be broken than to be right — a stale lifecycle log, a bad
  # config read, or a half-written edit picked up by a live loop all present as
  # "everything is dead". Over the cap it refuses to apply anything and says so.
  [int]$MaxClears = 3,
  [string]$Repo = "chase-sets/chase-sets",
  # Test seams; production reads the canonical logs and the real CLI.
  [string]$DispatchLog,
  [string]$GhCommand = "gh"
)

$ErrorActionPreference = "Stop"

$LaneOwned = @("In lane", "In review", "Landed")
$Sweepable = @("In lane", "In review")

$dispatchPath = if ($DispatchLog) { $DispatchLog } else { Join-Path $PSScriptRoot "dispatch-log.jsonl" }

function Read-JsonLines([string]$Path, [int]$Last) {
  if (-not (Test-Path -LiteralPath $Path)) { return @() }
  $lines = Get-Content -LiteralPath $Path -Tail $Last
  $rows = @()
  foreach ($line in $lines) {
    if (-not "$line".Trim()) { continue }
    try { $rows += ($line | ConvertFrom-Json) } catch { continue }
  }
  return $rows
}

# Branch names carry a number, but NOT always an issue number. `issue-6155-` is
# the owning issue; `review-6134-` and `pr-6157-` are the PR under review, whose
# owning issue is a different number entirely (PR #6134 closes issue #6125) or
# none at all (a chore PR). Both are captured anyway, and the trailing broad
# match widens it further: over-capture keeps a live item OFF the sweep list,
# which is the safe direction to be wrong in.
#
# The PR-shaped numbers are resolved to the issues they close (below), so an
# issue whose only lane is a review or a repair is visible to signal 1 directly.
# Signal 2 remains as the independent check for work with a linked PR and no
# lane at all.
function Get-BranchIssues([string]$Branch) {
  $found = @()
  foreach ($m in [regex]::Matches("$Branch", '(?:issue|review|repair|pr)-(\d{2,6})')) {
    $found += [int]$m.Groups[1].Value
  }
  foreach ($m in [regex]::Matches("$Branch", '(?<![\d.])(\d{4,6})(?![\d.])')) {
    $found += [int]$m.Groups[1].Value
  }
  return $found | Sort-Object -Unique
}

# The numbers on review/repair/pr branches are PRs. Resolving them to the issues
# they close is what makes signal 1 see an issue whose only lane is a review or
# a repair — without it, protection rests entirely on signal 2's Closes link,
# which is a convention rather than an invariant (draft, chore, and controller
# PRs routinely have none) and on signal 3's 2h grace, which observed reviews
# already exceed (#6157: dispatch 14:59Z, review-complete 18:09Z).
function Get-PrBranchNumbers([string]$Branch) {
  $found = @()
  foreach ($m in [regex]::Matches("$Branch", '(?:review|repair|pr)-(\d{2,6})')) {
    $found += [int]$m.Groups[1].Value
  }
  return $found | Sort-Object -Unique
}

# --- Liveness signal 1: current lifecycle rows -------------------------------
# Lane identity is already canonical telemetry. The latest row for a lane is
# live only when it is a dispatch; terminal lifecycle rows retire it.
$lifecycleRows = @(Read-JsonLines $dispatchPath 400)
$liveFromLanes = [System.Collections.Generic.HashSet[int]]::new()
$prNumbers = [System.Collections.Generic.HashSet[int]]::new()
foreach ($group in @($lifecycleRows | Where-Object { $_.lane -and $_.issue } | Group-Object lane)) {
  $latest = @($group.Group | Sort-Object { [datetimeoffset]::Parse([string]$_.ts) } -Descending | Select-Object -First 1)
  if ($latest.Count -eq 1 -and [string]$latest[0].kind -ceq 'dispatch') {
    [void]$liveFromLanes.Add([int]$latest[0].issue)
  }
}

# One batched query for every PR-shaped branch number.
#
# A degraded resolution is NOT "nothing to add" — it is "we cannot tell which
# issues have live lanes", and every issue whose only lane rides a PR branch is
# then indistinguishable from a dead one. Reporting the degradation and sweeping
# anyway would silently reinstate the exact defect this resolution exists to fix,
# so degradation blocks the sweep the same way missing lifecycle evidence does. The
# standard is already set one screen below by the pre-clear re-check: could not
# confirm death, so refuse rather than assume.
#
# One stray number poisons a whole batch — `gh api graphql` exits non-zero when
# ANY alias errors (a review-/repair-/pr- branch whose number is not a real PR
# does this deterministically), while still printing a body carrying the aliases
# that did resolve. That partial body is harvested rather than discarded, and the
# run reports `partial` so a shrunken signal is never read as a clean one.
$prResolution = "none"
if ($prNumbers.Count -gt 0) {
  $owner, $name = $Repo.Split("/", 2)
  $fields = @()
  $i = 0
  foreach ($pr in $prNumbers) {
    $fields += "p${i}: pullRequest(number: $pr) { closingIssuesReferences(first: 10) { nodes { number } } }"
    $i++
  }
  $prQuery = "query(`$owner:String!,`$name:String!){repository(owner:`$owner,name:`$name){$($fields -join ' ')}}"
  $prRaw = & $GhCommand api graphql -f "query=$prQuery" -F "owner=$owner" -F "name=$name" 2>&1
  $prExit = $LASTEXITCODE

  # `2>&1` merges gh's stderr line ("gh: Could not resolve ...") into the same
  # stream ahead of the JSON body, so concatenating everything and parsing it
  # throws on the leading prose — which silently made the partial harvest below
  # dead code. Keep only the string payload and drop the ErrorRecords the merge
  # introduced, so a real partial response is actually harvested rather than
  # classified as a total failure.
  $prBody = (@($prRaw) | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } |
    ForEach-Object { "$_" } | Where-Object { $_.TrimStart().StartsWith("{") }) -join "`n"
  if (-not $prBody) { $prBody = "$prRaw" }

  $resolvedAliases = 0
  try {
    $repoNode = ($prBody | ConvertFrom-Json).data.repository
    if ($repoNode) {
      foreach ($prop in $repoNode.PSObject.Properties) {
        if (-not $prop.Value) { continue }
        $resolvedAliases++
        foreach ($node in @($prop.Value.closingIssuesReferences.nodes | Where-Object { $_ })) {
          [void]$liveFromLanes.Add([int]$node.number)
        }
      }
    }
    $prResolution =
    if ($prExit -eq 0) { "ok" }
    elseif ($resolvedAliases -gt 0) { "partial" }
    else { "query-failed" }
  }
  catch {
    $prResolution = if ($prExit -eq 0) { "unparseable" } else { "query-failed" }
  }
}

# Degraded resolution means death is unproven for anything the resolution might
# have kept alive. Which issues those are is exactly what could not be computed,
# so no candidate may be swept this run.
$prSignalDegraded = $prResolution -in @("partial", "query-failed", "unparseable")

# Without lifecycle history there is no evidence of death, only absence of
# evidence — refuse to sweep rather than guess.
$haveSnapshotEvidence = Test-Path -LiteralPath $dispatchPath -PathType Leaf

# --- Liveness signal 3: recent telemetry ------------------------------------
$cutoff = (Get-Date).ToUniversalTime().AddHours(-$MinIdleHours)
$liveFromTelemetry = [System.Collections.Generic.HashSet[int]]::new()
foreach ($row in Read-JsonLines $dispatchPath 400) {
  if (-not $row.issue) { continue }
  [datetime]$ts = [datetime]::MinValue
  if (-not [datetime]::TryParse("$($row.ts)", [ref]$ts)) { continue }
  if ($ts.ToUniversalTime() -ge $cutoff) { [void]$liveFromTelemetry.Add([int]$row.issue) }
}

# --- Board items in lane-owned states ---------------------------------------
$projectId = (& $GhCommand variable get DELIVERY_PROJECT_ID --repo $Repo 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or -not $projectId) { throw "DELIVERY_PROJECT_ID is unreadable" }

$query = @'
query($project:ID!,$after:String){
  node(id:$project){
    ... on ProjectV2 {
      items(first:100, after:$after){
        pageInfo{ hasNextPage endCursor }
        nodes{
          id
          status: fieldValueByName(name:"Status"){ ... on ProjectV2ItemFieldSingleSelectValue { name } }
          content{
            ... on Issue {
              number
              state
              closedByPullRequestsReferences(first:5, includeClosedPrs:false){ nodes{ number state } }
            }
          }
        }
      }
    }
  }
}
'@

$items = @()
$after = $null
do {
  $ghArgs = @("api", "graphql", "-f", "query=$query", "-F", "project=$projectId")
  if ($after) { $ghArgs += @("-F", "after=$after") }
  $raw = & $GhCommand @ghArgs 2>&1
  if ($LASTEXITCODE -ne 0) { throw "board item query failed (gh exit ${LASTEXITCODE}): $raw" }
  $page = ("$raw" | ConvertFrom-Json).data.node.items
  foreach ($node in @($page.nodes)) {
    if (-not $node.content.number) { continue }
    $items += [pscustomobject]@{
      ItemId  = $node.id
      Number  = [int]$node.content.number
      State   = "$($node.content.state)"
      Status  = "$($node.status.name)"
      OpenPrs = @($node.content.closedByPullRequestsReferences.nodes | ForEach-Object { $_.number })
    }
  }
  $after = if ($page.pageInfo.hasNextPage) { $page.pageInfo.endCursor } else { $null }
} while ($after)

$laneItems = @($items | Where-Object { $_.Status -in $LaneOwned })

$findings = @()
foreach ($item in $laneItems) {
  if ($item.Status -eq "Landed") {
    if ($item.State -eq "OPEN") {
      $findings += [pscustomobject]@{
        finding = "landed-but-open"; issue = $item.Number; status = $item.Status
        action  = "report"; why = "board says Landed but the issue is still open — check Closes-automation and the evidence ACs (SKILL.md §13)"
      }
    }
    continue
  }

  # Every signal is recorded whether it fired or not. A sweep that clears a live
  # item must be diagnosable from its own output — reconstructing one after the
  # fact from a `gc` row is guesswork, and guesswork is how a
  # false clear survives to happen again.
  $signals = [ordered]@{
    activeLane = $liveFromLanes.Contains($item.Number)
    openPr     = $item.OpenPrs.Count -gt 0
    telemetry  = $liveFromTelemetry.Contains($item.Number)
  }
  if ($signals.activeLane -or $signals.openPr -or $signals.telemetry) { continue }

  if (-not $haveSnapshotEvidence) {
    $findings += [pscustomobject]@{
      finding = "insufficient-evidence"; issue = $item.Number; status = $item.Status
      action  = "skip"; signals = $signals
      why     = "canonical lifecycle log is unavailable; death is unproven"
    }
    continue
  }

  if ($prSignalDegraded) {
    $findings += [pscustomobject]@{
      finding = "insufficient-evidence"; issue = $item.Number; status = $item.Status
      action  = "skip"; signals = $signals
      why     = "PR resolution degraded ($prResolution); an issue whose only lane rides a PR-named branch cannot be distinguished from a dead one, so death is unproven"
    }
    continue
  }

  $findings += [pscustomobject]@{
    finding = "stale-lane-state"; issue = $item.Number; status = $item.Status
    action  = "would-clear"; signals = $signals
    why     = "no active lifecycle lane, no open PR, no telemetry within ${MinIdleHours}h"
  }
}

$wouldClear = @($findings | Where-Object { $_.finding -eq "stale-lane-state" })

# Blast-radius check runs BEFORE any mutation, so a broken sweep clears nothing
# rather than clearing three things and then noticing.
$refused = $null
if ($Apply -and $wouldClear.Count -gt $MaxClears) {
  $refused = "sweep refused: $($wouldClear.Count) items would clear, cap is $MaxClears. Check lifecycle freshness and script integrity before raising -MaxClears."
  foreach ($f in $wouldClear) { $f.action = "refused" }
}

if ($Apply -and -not $refused) {
  foreach ($f in $wouldClear) {
    # Re-verify liveness against GitHub immediately before mutating. The board
    # read that produced this finding may be seconds stale, and ProjectV2 reads
    # are eventually consistent; a PR opened in that window must veto the clear.
    $fresh = & $GhCommand api graphql `
      -f "query=query(`$owner:String!,`$name:String!,`$number:Int!){repository(owner:`$owner,name:`$name){issue(number:`$number){closedByPullRequestsReferences(first:5,includeClosedPrs:false){nodes{number}}}}}" `
      -F "owner=$($Repo.Split('/')[0])" -F "name=$($Repo.Split('/')[1])" -F "number=$($f.issue)" 2>&1
    if ($LASTEXITCODE -eq 0) {
      # `@($emptyArray.number)` yields a single $null in PowerShell, not an
      # empty array, so filter before counting — otherwise the veto fires on
      # every issue and the backstop silently never clears anything.
      $prs = @(("$fresh" | ConvertFrom-Json).data.repository.issue.closedByPullRequestsReferences.nodes |
        Where-Object { $_ } | ForEach-Object { $_.number })
      if ($prs.Count -gt 0) {
        $f.action = "vetoed"
        $f.why = "re-check found open PR #$($prs -join ',#'); the board read was stale"
        continue
      }
    }
    else {
      # Could not confirm death. Refuse rather than assume.
      $f.action = "unverified"
      $f.why = "liveness re-check failed; refusing to clear on an unconfirmed read"
      continue
    }

    $result = & (Join-Path $PSScriptRoot "board-set.ps1") -Issue $f.issue -Clear -Repo $Repo -GhCommand $GhCommand
    $parsed = try { "$result" | ConvertFrom-Json } catch { $null }
    $f.action = if ($parsed -and $parsed.ok) { "cleared" } else { "clear-failed" }
  }

  $cleared = @($findings | Where-Object { $_.action -eq "cleared" })
  if ($cleared.Count -gt 0) {
    # Every other side effect here is seamed for tests except this one, and an
    # unseamed telemetry write is worse than an unseamed anything else: the
    # suite's -Apply cases run against fixture issues, so each run appended
    # production-shaped `gc` rows to the CANONICAL dispatch log, byte-identical
    # to real sweeps. Those fabricated rows are exactly the "#6155 production
    # misfire" this release escalated and could not reproduce — there was no
    # misfire, only the test suite writing into live telemetry. A -DispatchLog
    # override means this is a test run; its rows belong in that same file.
    $gcLog = if ($DispatchLog) { @{ OutFile = $dispatchPath } } else { @{} }
    [void](& (Join-Path $PSScriptRoot "log-event.ps1") -Log dispatch -Kind gc -NoBoard @gcLog `
        -Note "board-reconcile cleared $($cleared.Count) stale lane-owned status(es): $(($cleared | ForEach-Object { "#$($_.issue)" }) -join ' ') (signals: no active lifecycle lane, no open PR, no telemetry within ${MinIdleHours}h)")
  }
}

Write-Output ([ordered]@{
    ts        = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
    kind      = "board-reconcile"
    applied   = [bool]$Apply
    scanned   = $items.Count
    laneOwned = $laneItems.Count
    lifecycleRows = $lifecycleRows.Count
    # ok / none / partial / query-failed / unparseable. Anything but ok or none
    # weakens signal 1 for review and repair lanes and blocks the sweep for that
    # run, so it must be visible rather than read as "no lane is working a PR".
    prResolution = $prResolution
    refused   = $refused
    findings  = @($findings)
  } | ConvertTo-Json -Compress -Depth 6)
