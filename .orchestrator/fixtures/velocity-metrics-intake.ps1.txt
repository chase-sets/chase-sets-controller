[CmdletBinding()]
param(
  [string]$ContainerRoot = (Split-Path -Parent $PSScriptRoot),
  [string]$FactsPath = "",
  [string]$FactsOut = "",
  [string]$ObservationLog = "",
  [string]$NowUtc = "",
  [switch]$NoRecord,
  [switch]$Summary
)

# velocity-report/v1 (#8207). Read-only reducer over GitHub and dispatch-log
# facts. It raises exactly two alarms, FLOOR and DROUGHT; everything else is
# diagnostic context. Incomplete facts yield UNKNOWN, never OK.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 3.0

$script:VelocityRepo = "chase-sets/chase-sets"
$script:FloorLanes = 2
$script:FloorRunMinutes = 60
$script:FloorGraceHours = 2
$script:FloorRearmHours = 4
$script:DroughtHours = 48
$script:DroughtGraceHours = 4
$script:StaleAttemptHours = 8
$script:DecisionHeavyCount = 3
$script:LateRelabelHours = 48
$script:TerminalKinds = @("lane-complete", "lane-blocked", "review-complete", "repair-complete", "verify-complete", "decision-resolved")

function ConvertTo-VelocityUtc([object]$Value) {
  if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
  if ($Value -is [datetime]) { return ([datetime]$Value).ToUniversalTime() }
  return [datetime]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)
}

function Format-VelocityUtc([datetime]$Value) {
  return $Value.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ", [Globalization.CultureInfo]::InvariantCulture)
}

function Test-VelocityProductKind([object]$Labels) {
  return @($Labels | Where-Object { [string]$_ -ceq "kind:product" }).Count -gt 0
}

function Test-VelocityReadyIssue($Issue, [int[]]$PlatformMilestones) {
  $labels = @($Issue.labels | ForEach-Object { [string]$_ })
  if (-not (Test-VelocityProductKind $labels)) { return $false }
  if (@($labels | Where-Object { $_.StartsWith("status:", [StringComparison]::Ordinal) -or $_ -ceq "decision" }).Count -gt 0) { return $false }
  if ($null -eq $Issue.milestone -or -not [bool]$Issue.milestone.committed) { return $false }
  if ($PlatformMilestones -contains [int]$Issue.milestone.number) { return $false }
  return ([int]$Issue.openBlockers -eq 0)
}

function Get-VelocityLaneIssueMap([object[]]$Rows) {
  # Issue-bearing dispatch rows key on the launch label; watchdog routing rows
  # alias the ownership record's worktree name to that label.
  $map = @{}
  $alias = @{}
  foreach ($row in @($Rows | Sort-Object { ConvertTo-VelocityUtc $_.ts })) {
    if ([string]$row.kind -cne "dispatch") { continue }
    $lane = if ($null -ne $row.PSObject.Properties["lane"]) { [string]$row.lane } else { "" }
    $label = if ($null -ne $row.PSObject.Properties["label"]) { [string]$row.label } else { "" }
    if (-not [string]::IsNullOrWhiteSpace($label) -and -not [string]::IsNullOrWhiteSpace($lane) -and $label -cne $lane) {
      $alias[$lane] = $label
      if ($null -ne $row.PSObject.Properties["worktree"] -and -not [string]::IsNullOrWhiteSpace([string]$row.worktree)) {
        $alias[(Split-Path -Leaf ([string]$row.worktree))] = $label
      }
    }
    if ($null -eq $row.PSObject.Properties["issue"] -or $null -eq $row.issue -or [string]::IsNullOrWhiteSpace($lane)) { continue }
    $map[$lane] = [pscustomobject]@{ issue = [int]$row.issue; startedAt = (ConvertTo-VelocityUtc $row.ts) }
  }
  $resolved = @{}
  foreach ($key in $map.Keys) { $resolved[$key] = $map[$key] }
  foreach ($key in $alias.Keys) {
    if (-not $resolved.ContainsKey($key) -and $map.ContainsKey($alias[$key])) { $resolved[$key] = $map[$alias[$key]] }
  }
  return $resolved
}

function Get-VelocityIssueKinds($Facts, [int]$Issue) {
  $key = [string]$Issue
  if ($null -ne $Facts.issueKinds -and $null -ne $Facts.issueKinds.PSObject.Properties[$key]) { return @($Facts.issueKinds.$key) }
  $open = @($Facts.productIssues | Where-Object { [int]$_.number -eq $Issue })
  if ($open.Count -gt 0) { return @("kind:product") }
  return @()
}

function Get-VelocityLaneHours($Facts, [datetime]$Now, [hashtable]$LaneMap, [string[]]$ActiveLanes) {
  $windowStart = $Now.AddHours(-48)
  $rows = @($Facts.dispatchRows | Sort-Object { ConvertTo-VelocityUtc $_.ts })
  $totals = [ordered]@{ product = 0.0; other = 0.0; unattributedOpenLanes = 0 }
  for ($i = 0; $i -lt $rows.Count; $i++) {
    $row = $rows[$i]
    if ([string]$row.kind -cne "dispatch" -or $null -eq $row.PSObject.Properties["issue"] -or $null -eq $row.issue) { continue }
    if ($null -eq $row.PSObject.Properties["lane"] -or [string]::IsNullOrWhiteSpace([string]$row.lane)) { continue }
    $lane = [string]$row.lane
    $start = ConvertTo-VelocityUtc $row.ts
    $end = $null
    for ($j = $i + 1; $j -lt $rows.Count; $j++) {
      $next = $rows[$j]
      if ($null -eq $next.PSObject.Properties["lane"] -or [string]$next.lane -cne $lane) { continue }
      if ([string]$next.kind -ceq "dispatch") { $end = ConvertTo-VelocityUtc $next.ts; break }
      if ($script:TerminalKinds -contains [string]$next.kind) { $end = ConvertTo-VelocityUtc $next.ts; break }
    }
    if ($null -eq $end) {
      if ($ActiveLanes -contains $lane) { $end = $Now } else { $totals.unattributedOpenLanes += 1; continue }
    }
    $clipStart = if ($start -lt $windowStart) { $windowStart } else { $start }
    if ($end -le $clipStart) { continue }
    $hours = ($end - $clipStart).TotalHours
    if (Test-VelocityProductKind (Get-VelocityIssueKinds $Facts ([int]$row.issue))) { $totals.product += $hours } else { $totals.other += $hours }
  }
  $sum = $totals.product + $totals.other
  return [pscustomobject][ordered]@{
    productHours = [math]::Round($totals.product, 2)
    otherHours = [math]::Round($totals.other, 2)
    productShare = $(if ($sum -gt 0) { [math]::Round($totals.product / $sum, 3) } else { $null })
    unattributedOpenLanes = $totals.unattributedOpenLanes
  }
}

function Get-VelocityActionTime($Facts, [string]$AlarmId, [datetime]$Since) {
  $token = "velocity:$AlarmId"
  $hits = @($Facts.dispatchRows | Where-Object {
      $ts = ConvertTo-VelocityUtc $_.ts
      $note = if ($null -ne $_.PSObject.Properties["note"]) { [string]$_.note } else { "" }
      $ts -ge $Since -and $note.Contains($token, [StringComparison]::Ordinal)
    } | Sort-Object { ConvertTo-VelocityUtc $_.ts })
  if ($hits.Count -eq 0) { return $null }
  return ConvertTo-VelocityUtc $hits[-1].ts
}

function Get-VelocityReport($Facts, [datetime]$Now, [object[]]$Observations) {
  $now = $Now.ToUniversalTime()
  $complete = [bool]$Facts.complete
  $platform = @($Facts.platformMilestones | ForEach-Object { [int]$_ })

  $lastMerge = ConvertTo-VelocityUtc $Facts.lastProductMergeAt
  $hoursSince = if ($null -ne $lastMerge) { [math]::Round(($now - $lastMerge).TotalHours, 1) } else { $null }

  $weekStart = $now.AddDays(-7)
  $recent = @($Facts.merges | Where-Object { (ConvertTo-VelocityUtc $_.mergedAt) -ge $weekStart })
  $unlinked = @($recent | Where-Object { @($_.issues | Where-Object { @($_.kinds).Count -gt 0 }).Count -eq 0 })
  $productRecent = @($recent | Where-Object { @($_.issues | Where-Object { Test-VelocityProductKind $_.kinds }).Count -gt 0 })
  $lateRelabels = @()
  foreach ($merge in $productRecent) {
    $mergedAt = ConvertTo-VelocityUtc $merge.mergedAt
    foreach ($issue in @($merge.issues)) {
      $labeledAt = ConvertTo-VelocityUtc $issue.productLabeledAt
      if ($null -ne $labeledAt -and $labeledAt -le $mergedAt -and ($mergedAt - $labeledAt).TotalHours -lt $script:LateRelabelHours) {
        $lateRelabels += [pscustomobject][ordered]@{ pr = [int]$merge.pr; issue = [int]$issue.number; hoursBeforeMerge = [math]::Round(($mergedAt - $labeledAt).TotalHours, 1) }
      }
    }
  }

  $activeLanes = @($Facts.activeLanes | ForEach-Object { [string]$_.lane })
  $laneMap = Get-VelocityLaneIssueMap @($Facts.dispatchRows)
  $flowing = [Collections.Generic.SortedSet[int]]::new()
  $staleAttempts = @()
  foreach ($active in @($Facts.activeLanes)) {
    $entry = $laneMap[[string]$active.lane]
    if ($null -eq $entry) { continue }
    if (-not (Test-VelocityProductKind (Get-VelocityIssueKinds $Facts $entry.issue))) { continue }
    [void]$flowing.Add($entry.issue)
    if ([string]$active.laneRole -ceq "implementation") {
      $lastProgress = $entry.startedAt
      foreach ($pr in @($Facts.productPrs | Where-Object { @($_.issues) -contains $entry.issue })) {
        $pushed = ConvertTo-VelocityUtc $pr.headCommittedAt
        if ($null -ne $pushed -and $pushed -gt $lastProgress) { $lastProgress = $pushed }
      }
      $idle = ($now - $lastProgress).TotalHours
      if ($idle -ge $script:StaleAttemptHours) {
        $staleAttempts += [pscustomobject][ordered]@{ issue = $entry.issue; lane = [string]$active.lane; hoursWithoutPush = [math]::Round($idle, 1) }
      }
    }
  }
  foreach ($pr in @($Facts.productPrs)) {
    if ([bool]$pr.inMergeQueue -or @("PENDING", "EXPECTED") -contains [string]$pr.ciState) {
      foreach ($issue in @($pr.issues)) { [void]$flowing.Add([int]$issue) }
    }
  }
  $ready = @($Facts.productIssues | Where-Object { Test-VelocityReadyIssue $_ $platform } | ForEach-Object { [int]$_.number } | Sort-Object)
  $readyIdle = @($ready | Where-Object { -not $flowing.Contains($_) })

  $floorState = if (-not $complete) { "UNKNOWN" }
    elseif ($flowing.Count -ge $script:FloorLanes) { "MET" }
    elseif ($readyIdle.Count -ge 1) { "UNMET" }
    else { "MET" }

  $dayStart = $now.AddHours(-24)
  $decisionHeavy = @($Facts.dispatchRows | Where-Object {
      [string]$_.kind -ceq "decision-filed" -and $null -ne $_.PSObject.Properties["issue"] -and $null -ne $_.issue -and (ConvertTo-VelocityUtc $_.ts) -ge $dayStart
    } | Group-Object { [int]$_.issue } | Where-Object { $_.Count -ge $script:DecisionHeavyCount } |
    ForEach-Object { [pscustomobject][ordered]@{ issue = [int]$_.Name; decisionLanes24h = $_.Count } })

  $alarms = @()
  if ($complete) {
    $series = @(@($Observations) + @([pscustomobject]@{ ts = (Format-VelocityUtc $now); floorState = $floorState }) |
      Where-Object { $null -ne $_ } | Sort-Object { ConvertTo-VelocityUtc $_.ts })
    $run = @()
    for ($k = $series.Count - 1; $k -ge 0; $k--) {
      if ([string]$series[$k].floorState -cne "UNMET") { break }
      $run += $series[$k]
    }
    if ($run.Count -ge 2) {
      $onset = ConvertTo-VelocityUtc $run[-1].ts
      if (($now - $onset).TotalMinutes -ge $script:FloorRunMinutes) {
        $raisedAt = $onset.AddMinutes($script:FloorRunMinutes)
        $since = if ($now.AddHours(-$script:FloorRearmHours) -gt $onset) { $now.AddHours(-$script:FloorRearmHours) } else { $onset }
        $acted = Get-VelocityActionTime $Facts "FLOOR" $since
        $alarms += [pscustomobject][ordered]@{
          id = "FLOOR"; onset = (Format-VelocityUtc $onset); raisedAt = (Format-VelocityUtc $raisedAt)
          actedAt = $(if ($null -ne $acted) { Format-VelocityUtc $acted } else { $null })
          unacted = ($null -eq $acted -and ($now - $raisedAt).TotalHours -ge $script:FloorGraceHours)
          detail = "flowing product issues $($flowing.Count) < $($script:FloorLanes) with ready idle: $($readyIdle -join ',')"
        }
      }
    }
    $droughtHours = if ($null -ne $hoursSince) { $hoursSince } else { [double]::PositiveInfinity }
    if ($droughtHours -ge $script:DroughtHours) {
      $periodStart = if ($null -ne $lastMerge) {
        $periods = [math]::Floor(($droughtHours - $script:DroughtHours) / $script:DroughtHours)
        $lastMerge.AddHours($script:DroughtHours * (1 + $periods))
      } else { $now.AddHours(-$script:DroughtHours) }
      $acted = Get-VelocityActionTime $Facts "DROUGHT" $periodStart
      $alarms += [pscustomobject][ordered]@{
        id = "DROUGHT"; onset = $(if ($null -ne $lastMerge) { Format-VelocityUtc ($lastMerge.AddHours($script:DroughtHours)) } else { $null })
        raisedAt = (Format-VelocityUtc $periodStart)
        actedAt = $(if ($null -ne $acted) { Format-VelocityUtc $acted } else { $null })
        unacted = ($null -eq $acted -and ($now - $periodStart).TotalHours -ge $script:DroughtGraceHours)
        detail = "no kind:product merge for $(if ($null -ne $hoursSince) { "$hoursSince h (last $(Format-VelocityUtc $lastMerge))" } else { 'the whole lookback' })"
      }
    }
  }

  $status = if (-not $complete) { "UNKNOWN" } elseif ($alarms.Count -gt 0) { "ALARM" } else { "OK" }
  return [pscustomobject][ordered]@{
    schema = "velocity-report/v1"
    now = (Format-VelocityUtc $now)
    status = $status
    factsComplete = $complete
    gaps = @($Facts.gaps)
    metrics = [pscustomobject][ordered]@{
      lastProductMergeAt = $(if ($null -ne $lastMerge) { Format-VelocityUtc $lastMerge } else { $null })
      hoursSinceProductMerge = $hoursSince
      merges7d = $recent.Count
      productMerges7d = $productRecent.Count
      unlinkedMerges7d = $unlinked.Count
      unlinkedRatio7d = $(if ($recent.Count -gt 0) { [math]::Round($unlinked.Count / $recent.Count, 3) } else { $null })
      flowingProductIssues = @($flowing)
      readyProductIssues = $ready
      readyNotInFlight = $readyIdle
      floorState = $floorState
      ownershipStatus = [string]$Facts.ownershipStatus
    }
    alarms = $alarms
    diagnostics = [pscustomobject][ordered]@{
      staleAttempts = $staleAttempts
      decisionHeavyIssues = $decisionHeavy
      laneHours48h = (Get-VelocityLaneHours $Facts $now $laneMap $activeLanes)
      lateProductRelabels = $lateRelabels
    }
  }
}

function Read-VelocityObservations([string]$Path, [datetime]$Now) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
  $cutoff = $Now.AddHours(-48)
  return @(Get-Content -LiteralPath $Path -ErrorAction Stop | ForEach-Object {
      try { $_ | ConvertFrom-Json } catch { $null }
    } | Where-Object { $null -ne $_ -and $null -ne $_.PSObject.Properties["ts"] -and (ConvertTo-VelocityUtc $_.ts) -ge $cutoff })
}

function Invoke-VelocityGraphQL([string]$Query, [hashtable]$Variables) {
  $arguments = @("api", "graphql", "-f", "query=$Query")
  foreach ($key in $Variables.Keys) {
    if ($null -ne $Variables[$key]) { $arguments += @("-f", "$key=$($Variables[$key])") }
  }
  $raw = & gh @arguments 2>&1
  if ($LASTEXITCODE -ne 0) { throw "gh graphql failed: $(($raw | Out-String).Trim())" }
  $parsed = ($raw | Out-String) | ConvertFrom-Json
  if ($null -ne $parsed.PSObject.Properties["errors"] -and $null -ne $parsed.errors) { throw "gh graphql returned errors" }
  return $parsed.data
}

function Invoke-VelocitySearch([string]$SearchQuery, [string]$Fields) {
  $query = 'query($q:String!,$c:String){search(query:$q,type:ISSUE,first:100,after:$c){issueCount pageInfo{hasNextPage endCursor} nodes{' + $Fields + '}}}'
  $nodes = @()
  $cursor = $null
  do {
    $data = Invoke-VelocityGraphQL $query @{ q = $SearchQuery; c = $cursor }
    $nodes += @($data.search.nodes)
    $cursor = $data.search.pageInfo.endCursor
  } while ([bool]$data.search.pageInfo.hasNextPage)
  if ($nodes.Count -ne [int]$data.search.issueCount -and [int]$data.search.issueCount -le 1000) {
    throw "search '$SearchQuery' returned $($nodes.Count) of $($data.search.issueCount)"
  }
  return $nodes
}

function Get-VelocityOutcomeCommitted([string]$Description) {
  if ([string]::IsNullOrEmpty($Description)) { return $false }
  $match = [regex]::Match($Description, '<!--\s*outcome:\s*(\{[^}]*\})\s*-->')
  if (-not $match.Success) { return $false }
  try { return ([string]($match.Groups[1].Value | ConvertFrom-Json).status -ceq "committed") } catch { return $false }
}

function Get-VelocityFacts([string]$Container, [datetime]$Now) {
  $gaps = @()
  $facts = [ordered]@{
    schema = "velocity-facts/v1"; collectedAt = (Format-VelocityUtc $Now); complete = $false; gaps = @()
    platformMilestones = @(); merges = @(); lastProductMergeAt = $null; productIssues = @(); productPrs = @()
    activeLanes = @(); ownershipStatus = "unknown"; dispatchRows = @(); issueKinds = [ordered]@{}
  }

  $handoff = Join-Path $Container ".orchestrator/platform-handoff.md"
  try {
    $facts.platformMilestones = @(Get-Content -LiteralPath $handoff -ErrorAction Stop | ForEach-Object {
        $m = [regex]::Match($_, '^\|\s*chase-sets milestone (\d+)[^|]*\|\s*platform\s*\|')
        if ($m.Success) { [int]$m.Groups[1].Value }
      })
  } catch { $gaps += "platform-register-unreadable" }

  $issueFields = 'number labels(first:30){nodes{name}} timelineItems(itemTypes:[LABELED_EVENT],last:20){nodes{... on LabeledEvent{createdAt label{name}}}}'
  try {
    $since = $Now.AddDays(-30).ToString("yyyy-MM-dd", [Globalization.CultureInfo]::InvariantCulture)
    $prs = Invoke-VelocitySearch "repo:$script:VelocityRepo is:pr is:merged merged:>=$since" ("... on PullRequest{number mergedAt closingIssuesReferences(first:5){nodes{" + $issueFields + "}}}")
    $facts.merges = @($prs | ForEach-Object {
        [pscustomobject][ordered]@{
          pr = [int]$_.number; mergedAt = [string]$_.mergedAt
          issues = @($_.closingIssuesReferences.nodes | ForEach-Object {
              $labels = @($_.labels.nodes | ForEach-Object { [string]$_.name })
              $labeled = @($_.timelineItems.nodes | Where-Object { $null -ne $_.PSObject.Properties["label"] -and [string]$_.label.name -ceq "kind:product" } | Sort-Object createdAt)
              [pscustomobject][ordered]@{
                number = [int]$_.number
                kinds = @($labels | Where-Object { $_.StartsWith("kind:", [StringComparison]::Ordinal) })
                productLabeledAt = $(if ($labeled.Count -gt 0) { [string]$labeled[-1].createdAt } else { $null })
              }
            })
        }
      })
    $productMerges = @($facts.merges | Where-Object { @($_.issues | Where-Object { Test-VelocityProductKind $_.kinds }).Count -gt 0 } | Sort-Object { ConvertTo-VelocityUtc $_.mergedAt })
    if ($productMerges.Count -gt 0) { $facts.lastProductMergeAt = [string]$productMerges[-1].mergedAt }
  } catch { $gaps += "merged-prs: $($_.Exception.Message)" }

  try {
    $issues = Invoke-VelocitySearch "repo:$script:VelocityRepo is:issue is:open label:kind:product" '... on Issue{number labels(first:30){nodes{name}} milestone{number state description} blockedBy(first:30){nodes{state}}}'
    $facts.productIssues = @($issues | ForEach-Object {
        [pscustomobject][ordered]@{
          number = [int]$_.number
          labels = @($_.labels.nodes | ForEach-Object { [string]$_.name })
          milestone = $(if ($null -ne $_.milestone) {
              [pscustomobject][ordered]@{ number = [int]$_.milestone.number; committed = ([string]$_.milestone.state -ceq "OPEN" -and (Get-VelocityOutcomeCommitted ([string]$_.milestone.description))) }
            } else { $null })
          openBlockers = @($_.blockedBy.nodes | Where-Object { [string]$_.state -ceq "OPEN" }).Count
        }
      })
  } catch { $gaps += "product-issues: $($_.Exception.Message)" }

  try {
    $open = Invoke-VelocitySearch "repo:$script:VelocityRepo is:pr is:open" '... on PullRequest{number isDraft mergeQueueEntry{state} commits(last:1){nodes{commit{committedDate statusCheckRollup{state}}}} closingIssuesReferences(first:5){nodes{number labels(first:30){nodes{name}}}}}'
    $facts.productPrs = @($open | ForEach-Object {
        $productIssues = @($_.closingIssuesReferences.nodes | Where-Object { Test-VelocityProductKind @($_.labels.nodes | ForEach-Object { [string]$_.name }) } | ForEach-Object { [int]$_.number })
        if ($productIssues.Count -gt 0) {
          $commit = @($_.commits.nodes)[0].commit
          [pscustomobject][ordered]@{
            pr = [int]$_.number; issues = $productIssues; isDraft = [bool]$_.isDraft
            inMergeQueue = ($null -ne $_.mergeQueueEntry)
            ciState = $(if ($null -ne $commit.statusCheckRollup) { [string]$commit.statusCheckRollup.state } else { "NONE" })
            headCommittedAt = [string]$commit.committedDate
          }
        }
      })
  } catch { $gaps += "open-prs: $($_.Exception.Message)" }

  try {
    . (Join-Path $Container ".orchestrator/dispatch-ownership.ps1")
    $ownership = Get-LiveDispatchOwnership (Join-Path $Container ".orchestrator") ([IO.Path]::GetTempPath()) $Container
    $facts.ownershipStatus = [string]$ownership.health.status
    $facts.activeLanes = @($ownership.activeLanes | ForEach-Object { [pscustomobject][ordered]@{ lane = [string]$_.lane; laneRole = [string]$_.laneRole } })
  } catch { $gaps += "ownership: $($_.Exception.Message)" }

  $logPath = Join-Path $Container ".orchestrator/dispatch-log.jsonl"
  try {
    $cutoff = $Now.AddDays(-7)
    $facts.dispatchRows = @(Get-Content -LiteralPath $logPath -ErrorAction Stop | ForEach-Object {
        try { $_ | ConvertFrom-Json } catch { $null }
      } | Where-Object { $null -ne $_ -and $null -ne $_.PSObject.Properties["ts"] -and (ConvertTo-VelocityUtc $_.ts) -ge $cutoff })
  } catch { $gaps += "dispatch-log: $($_.Exception.Message)" }

  try {
    # Detached launches record "pid N" in the dispatch note without an
    # ownership record. Count one live only while no terminal row follows it and
    # the process started within its launch window (PID-reuse guard).
    $known = @{}
    foreach ($lane in @($facts.activeLanes)) { $known[[string]$lane.lane] = $true }
    $rows = @($facts.dispatchRows | Sort-Object { ConvertTo-VelocityUtc $_.ts })
    for ($i = 0; $i -lt $rows.Count; $i++) {
      $row = $rows[$i]
      if ([string]$row.kind -cne "dispatch" -or $null -eq $row.PSObject.Properties["note"] -or $null -eq $row.PSObject.Properties["lane"]) { continue }
      $pidMatch = [regex]::Match([string]$row.note, '\bpid (\d+)\b')
      if (-not $pidMatch.Success -or $known.ContainsKey([string]$row.lane)) { continue }
      $closed = $false
      for ($j = $i + 1; $j -lt $rows.Count; $j++) {
        if ($null -ne $rows[$j].PSObject.Properties["lane"] -and [string]$rows[$j].lane -ceq [string]$row.lane -and
            ($script:TerminalKinds -contains [string]$rows[$j].kind -or [string]$rows[$j].kind -ceq "dispatch")) { $closed = $true; break }
      }
      if ($closed) { continue }
      $process = Get-Process -Id ([int]$pidMatch.Groups[1].Value) -ErrorAction SilentlyContinue
      if ($null -eq $process) { continue }
      $started = $process.StartTime.ToUniversalTime()
      $ts = ConvertTo-VelocityUtc $row.ts
      if ($started -lt $ts.AddMinutes(-15) -or $started -gt $ts.AddMinutes(2)) { continue }
      $role = if ($null -ne $row.PSObject.Properties["laneRole"]) { [string]$row.laneRole } else { "" }
      $facts.activeLanes += [pscustomobject][ordered]@{ lane = [string]$row.lane; laneRole = $role; source = "dispatch-pid" }
      $known[[string]$row.lane] = $true
    }
  } catch { $gaps += "dispatch-pid-lanes: $($_.Exception.Message)" }

  try {
    $known = @{}
    foreach ($issue in @($facts.productIssues)) { $known[[int]$issue.number] = $true }
    $needed = @($facts.dispatchRows | Where-Object { $null -ne $_.PSObject.Properties["issue"] -and $null -ne $_.issue } |
      ForEach-Object { [int]$_.issue } | Sort-Object -Unique | Where-Object { -not $known.ContainsKey($_) })
    for ($offset = 0; $offset -lt $needed.Count; $offset += 50) {
      $chunk = @($needed[$offset..([math]::Min($offset + 49, $needed.Count - 1))])
      $selections = ($chunk | ForEach-Object { "i$($_): issueOrPullRequest(number:$($_)){... on Issue{labels(first:30){nodes{name}}} ... on PullRequest{labels(first:30){nodes{name}}}}" }) -join " "
      $data = Invoke-VelocityGraphQL ('query{repository(owner:"chase-sets",name:"chase-sets"){' + $selections + '}}') @{}
      foreach ($n in $chunk) {
        $node = $data.repository."i$n"
        $facts.issueKinds["$n"] = @(if ($null -ne $node) { $node.labels.nodes | ForEach-Object { [string]$_.name } | Where-Object { $_.StartsWith("kind:", [StringComparison]::Ordinal) } })
      }
    }
  } catch { $gaps += "issue-kinds: $($_.Exception.Message)" }

  $facts.issueKinds = [pscustomobject]$facts.issueKinds
  $facts.gaps = @($gaps)
  $facts.complete = ($gaps.Count -eq 0)
  return [pscustomobject]$facts
}

if ($MyInvocation.InvocationName -ne ".") {
  $container = [IO.Path]::GetFullPath($ContainerRoot)
  $now = if ([string]::IsNullOrWhiteSpace($NowUtc)) { [datetime]::UtcNow } else { ConvertTo-VelocityUtc $NowUtc }
  $observationPath = if ([string]::IsNullOrWhiteSpace($ObservationLog)) { Join-Path $container ".orchestrator/logs/velocity-observations.jsonl" } else { $ObservationLog }
  $facts = if ([string]::IsNullOrWhiteSpace($FactsPath)) { Get-VelocityFacts $container $now } else { Get-Content -LiteralPath $FactsPath -Raw | ConvertFrom-Json }
  if (-not [string]::IsNullOrWhiteSpace($FactsOut)) {
    [IO.File]::WriteAllText($FactsOut, ($facts | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
  }
  $report = Get-VelocityReport $facts $now (Read-VelocityObservations $observationPath $now)
  if (-not $NoRecord -and $report.factsComplete) {
    $observation = [ordered]@{
      ts = $report.now; floorState = $report.metrics.floorState
      flowing = @($report.metrics.flowingProductIssues).Count; readyNotInFlight = @($report.metrics.readyNotInFlight).Count
      hoursSinceProductMerge = $report.metrics.hoursSinceProductMerge; status = $report.status
    }
    [IO.Directory]::CreateDirectory((Split-Path -Parent $observationPath)) | Out-Null
    [IO.File]::AppendAllText($observationPath, ($observation | ConvertTo-Json -Compress) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
  }
  if ($Summary) {
    $alarmText = (@($report.alarms | ForEach-Object { "$($_.id)$(if ($_.unacted) { '(UNACTED)' } elseif ($_.actedAt) { '(acted)' } else { '(open)' })" }) -join ",")
    Write-Output ("VELOCITY {0} floor={1} flowing={2} readyIdle={3} hoursSinceProductMerge={4} alarms=[{5}]" -f $report.status, $report.metrics.floorState,
      (@($report.metrics.flowingProductIssues) -join ","), (@($report.metrics.readyNotInFlight) -join ","), $report.metrics.hoursSinceProductMerge, $alarmText)
  } else {
    Write-Output ($report | ConvertTo-Json -Depth 8)
  }
}
