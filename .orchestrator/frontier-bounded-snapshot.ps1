<#
.SYNOPSIS
Bounded frontier snapshot, rebuilt from LIVE sources every run
(milestone-orchestrator SKILL.md section 4).

.DESCRIPTION
This script used to carry a hand-maintained `$issueNumbers` array. That array
was the de-facto replan queue, and it silently decided what recovery work
existed: #5684, #5616, and #5748 all had PRs closed unmerged and were absent
from the array, so nothing looked at them again. Section 4 already forbids
exactly this ("never trust program instances written into this file - they go
stale"); the array was the file disobeying its own skill.

The frontier is now derived from label and state queries. Adding an issue to
the frontier means labeling it, not editing this file.

.EXAMPLE
./frontier-bounded-snapshot.ps1

.EXAMPLE
./frontier-bounded-snapshot.ps1 -Issue 4129,5496 -MaxIssues 80
#>
[CmdletBinding()]
param(
  # Ad-hoc additions on top of the derived frontier (program tracking issues,
  # a milestone spine head). These are additive and never replace the queries.
  [int[]]$Issue = @(),
  [int[]]$Pr = @(),
  # Hard bound so a mislabeled corpus can never produce an unbounded snapshot.
  [int]$MaxIssues = 60,
  [int]$MaxPrs = 25,
  [string]$Repo = "chase-sets/chase-sets",
  # Test seam; production uses the real CLI.
  [string]$GhCommand = "gh"
)

$ErrorActionPreference = "Stop"

function Clip-Text([object]$Value, [int]$Limit) {
  $text = if ($null -eq $Value) { "" } else { [string]$Value }
  if ($text.Length -le $Limit) { return $text }
  $head = [math]::Floor($Limit * 0.6)
  $tail = $Limit - $head
  return $text.Substring(0, $head) + "`n...[machine-truncated]...`n" + $text.Substring($text.Length - $tail)
}

function Invoke-Gh([string[]]$GhArguments, [string]$What) {
  $raw = & $GhCommand @GhArguments
  if ($LASTEXITCODE -ne 0) { throw "$What failed (gh exit $LASTEXITCODE)" }
  return $raw
}

# An empty result is the HEALTHY state for every one of these queries (no
# replan debt, no open decisions), so empty output must parse to an empty set
# rather than throwing. A frontier probe that crashes precisely when there is
# nothing wrong is worse than no probe.
function ConvertFrom-GhJson([object]$Raw) {
  $text = (@($Raw) -join "`n").Trim()
  if (-not $text) { return @() }
  return @($text | ConvertFrom-Json)
}

function Get-IssueNumbersByLabel([string]$Label) {
  $raw = Invoke-Gh @(
    "issue", "list", "--repo", $Repo, "--state", "open",
    "--label", $Label, "--limit", "100", "--json", "number"
  ) "open '$Label' query"
  return @(ConvertFrom-GhJson $raw | ForEach-Object { [int]$_.number })
}

# --- derive the frontier from live state ------------------------------------
# Ordered by recovery priority: replan debt first, because it is the class that
# disappears when nobody looks at it.
$frontierSources = [ordered]@{
  "status:needs-replan"  = @(Get-IssueNumbersByLabel "status:needs-replan")
  "status:tracking-only" = @(Get-IssueNumbersByLabel "status:tracking-only")
  "decision"             = @(Get-IssueNumbersByLabel "decision")
  "priority:p0"          = @(Get-IssueNumbersByLabel "priority:p0")
}

$issueNumbers = [System.Collections.Generic.List[int]]::new()
$seenIssues = [System.Collections.Generic.HashSet[int]]::new()
foreach ($source in $frontierSources.GetEnumerator()) {
  foreach ($number in $source.Value) {
    if ($seenIssues.Add($number)) { [void]$issueNumbers.Add($number) }
  }
}
foreach ($number in @($Issue)) {
  if ($seenIssues.Add($number)) { [void]$issueNumbers.Add($number) }
}

$issuesTruncated = $false
if ($issueNumbers.Count -gt $MaxIssues) {
  # Never truncate silently: a bounded snapshot that hides what it dropped
  # reads as "the frontier is small" when the frontier is actually overflowing.
  $issuesTruncated = $true
  $droppedIssues = @($issueNumbers | Select-Object -Skip $MaxIssues)
  $issueNumbers = [System.Collections.Generic.List[int]](@($issueNumbers | Select-Object -First $MaxIssues))
} else {
  $droppedIssues = @()
}

$issues = foreach ($number in $issueNumbers) {
  $raw = Invoke-Gh @(
    "issue", "view", "$number", "--repo", $Repo, "--json",
    "number,title,state,body,labels,milestone,comments,closedAt,updatedAt,url"
  ) "gh issue view #$number"
  # NOT $issue: that name collides case-insensitively with the [int[]]$Issue
  # parameter and PowerShell would try to coerce the object into an int array.
  $issueDetail = $raw | ConvertFrom-Json
  $latestComment = @($issueDetail.comments | Sort-Object createdAt | Select-Object -Last 1)
  $labels = @($issueDetail.labels | ForEach-Object { $_.name })
  [ordered]@{
    number = $issueDetail.number
    title = $issueDetail.title
    state = $issueDetail.state
    closedAt = $issueDetail.closedAt
    updatedAt = $issueDetail.updatedAt
    milestone = if ($issueDetail.milestone) { $issueDetail.milestone.title } else { $null }
    labels = $labels
    # Explicit lifecycle read so a consumer never has to infer recovery state
    # from prose. "parked" is deliberately not a value here: an issue awaiting
    # planning is active recovery work.
    lifecycle =
      if ($labels -contains "status:needs-replan") { "needs-replan" }
      elseif ($labels -contains "status:tracking-only") { "tracking-only" }
      elseif ($labels -contains "decision") { "decision" }
      else { "runnable" }
    body = Clip-Text $issueDetail.body 2500
    latestComment = if ($latestComment.Count -gt 0) {
      [ordered]@{
        author = $latestComment[0].author.login
        createdAt = $latestComment[0].createdAt
        url = $latestComment[0].url
        body = Clip-Text $latestComment[0].body 1200
      }
    } else {
      $null
    }
    url = $issueDetail.url
  }
}

# --- PRs: open set, live, plus explicit additions ----------------------------
$openPrRaw = Invoke-Gh @(
  "pr", "list", "--repo", $Repo, "--state", "open", "--limit", "100", "--json", "number"
) "open PR query"
$prNumbers = [System.Collections.Generic.List[int]]::new()
$seenPrs = [System.Collections.Generic.HashSet[int]]::new()
foreach ($number in @(ConvertFrom-GhJson $openPrRaw | ForEach-Object { [int]$_.number })) {
  if ($seenPrs.Add($number)) { [void]$prNumbers.Add($number) }
}
foreach ($number in @($Pr)) {
  if ($seenPrs.Add($number)) { [void]$prNumbers.Add($number) }
}

$prsTruncated = $false
if ($prNumbers.Count -gt $MaxPrs) {
  $prsTruncated = $true
  $droppedPrs = @($prNumbers | Select-Object -Skip $MaxPrs)
  $prNumbers = [System.Collections.Generic.List[int]](@($prNumbers | Select-Object -First $MaxPrs))
} else {
  $droppedPrs = @()
}

$prs = foreach ($number in $prNumbers) {
  # Splat through a variable: `& $cmd @( ... )` passes ONE array argument
  # instead of splatting. This call deliberately bypasses Invoke-Gh because a
  # single unreadable PR must skip, not abort the whole snapshot.
  $prViewArguments = @(
    "pr", "view", "$number", "--repo", $Repo, "--json",
    "number,title,state,isDraft,headRefOid,baseRefOid,mergeStateStatus,body,comments,updatedAt,url"
  )
  $raw = & $GhCommand @prViewArguments
  if ($LASTEXITCODE -ne 0) { continue }
  # NOT $pr: same case-insensitive collision with the [int[]]$Pr parameter.
  $prDetail = $raw | ConvertFrom-Json
  $latestComment = @($prDetail.comments | Sort-Object createdAt | Select-Object -Last 1)
  [ordered]@{
    number = $prDetail.number
    title = $prDetail.title
    state = $prDetail.state
    isDraft = $prDetail.isDraft
    head = $prDetail.headRefOid
    base = $prDetail.baseRefOid
    mergeState = $prDetail.mergeStateStatus
    updatedAt = $prDetail.updatedAt
    body = Clip-Text $prDetail.body 1800
    latestComment = if ($latestComment.Count -gt 0) {
      [ordered]@{
        author = $latestComment[0].author.login
        createdAt = $latestComment[0].createdAt
        url = $latestComment[0].url
        body = Clip-Text $latestComment[0].body 1000
      }
    } else {
      $null
    }
    url = $prDetail.url
  }
}

$decisionRaw = Invoke-Gh @(
  "issue", "list", "--repo", $Repo, "--state", "open", "--label", "decision",
  "--limit", "100", "--json", "number,title,updatedAt,url"
) "open decision query"
$opsRaw = Invoke-Gh @(
  "issue", "list", "--repo", $Repo, "--state", "open", "--search", '"[ops-alert]" in:title',
  "--limit", "100", "--json", "number,title,updatedAt,url"
) "open ops-alert query"

[ordered]@{
  generatedAt = (Get-Date).ToUniversalTime().ToString("o")
  scope = "Live label-derived frontier: replan debt, tracking-only originals, open decisions, P0s, plus explicit additions"
  frontierSources = [ordered]@{
    counts = [ordered]@{
      needsReplan = @($frontierSources["status:needs-replan"]).Count
      trackingOnly = @($frontierSources["status:tracking-only"]).Count
      decision = @($frontierSources["decision"]).Count
      priorityP0 = @($frontierSources["priority:p0"]).Count
      explicit = @($Issue).Count
    }
    issuesTruncated = $issuesTruncated
    droppedIssues = @($droppedIssues)
    prsTruncated = $prsTruncated
    droppedPrs = @($droppedPrs)
  }
  issues = @($issues)
  prs = @($prs)
  openDecisions = @(ConvertFrom-GhJson $decisionRaw)
  openOpsAlerts = @(ConvertFrom-GhJson $opsRaw)
} | ConvertTo-Json -Compress -Depth 8
