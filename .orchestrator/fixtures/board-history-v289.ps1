# Immutable synthetic-test oracle: installed f292db3c0c89aba867b7ae10da6fffd0fc2970ee.
# Original board-reconcile.ps1 lines 46-212, unchanged function bodies.
function Get-BoardHistory([string]$Path) {
  $rows = [Collections.Generic.List[object]]::new()
  $errors = [Collections.Generic.List[string]]::new()
  $count = 0
  try {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'canonical lifecycle log unavailable' }
    # A 400-row tail cannot establish absence. Scan canonical history in bounded
    # pages and keep lifecycle rows, not unrelated telemetry payloads.
    Get-Content -LiteralPath $Path -ReadCount 400 -ErrorAction Stop | ForEach-Object {
      foreach ($line in $_) {
        if (-not "$line".Trim()) { continue }
        $count++
        try {
          $row = $line | ConvertFrom-Json -DateKind String -ErrorAction Stop
          if (-not $row.kind) { throw 'missing kind' }
          if ($row.kind -in @('dispatch','lane-complete','repair-complete','review-complete','lane-blocked','landed') -or
              $row.outcome -in @('PARKED_DECISION','REPLAN_REQUIRED','REPLAN_REPLACED','REPLAN_COMPLETE')) {
            $rows.Add($row)
          }
        } catch { $errors.Add("malformed lifecycle row $count") }
      }
    }
  } catch { $errors.Add($_.Exception.Message) }
  $specs = @{}
  try {
    foreach ($file in @(Get-ChildItem -LiteralPath (Split-Path -Parent $Path) -Filter 'watchdog-lane-*.json' -File -ErrorAction Stop)) {
      $label = $file.BaseName.Substring('watchdog-lane-'.Length)
      try {
        $spec = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -DateKind String
        if ($spec.label -cne $label) { throw 'watchdog filename/label mismatch' }
        $specs[$label] = @{ value = $spec; error = $null }
      } catch { $specs[$label] = @{ value = $null; error = "unreadable/malformed watchdog $label" } }
    }
  } catch { $errors.Add('watchdog inventory unreadable') }
  foreach ($label in $specs.Keys) {
    $links = @($rows | Where-Object {
      $_.issue -gt 0 -and $_.transcript -and [IO.Path]::GetFileNameWithoutExtension([string]$_.transcript) -ceq $label
    })
    if (-not $links.Count) { $errors.Add("unlinked watchdog ${label}: owning issue unknown") }
  }
  return @{ rows = @($rows); specs = $specs; errors = @($errors); count = $count }
}

function Get-BoardProjection($Item, $History) {
  $native = $Item.content
  $result = [ordered]@{ issue = [int]$native.number; itemId = $Item.id; status = [string]$Item.status.name
    statusSince = [string]$Item.status.updatedAt; eligible = $false; known = $true; desired = $null
    action = 'none'; why = ''; evidence = '' }
  if ($native.state -ceq 'CLOSED' -or $native.issueType.name -ceq 'Epic' -or
      @($native.labels.nodes | Where-Object name -eq 'status:tracking-only').Count) {
    $result.why = 'closed, Epic or Tracking belongs to project-status-sync'
    return [pscustomobject]$result
  }
  $reasons = [Collections.Generic.List[string]]::new()
  $statusInstant = [datetimeoffset]::MinValue
  if ($result.status -and -not [datetimeoffset]::TryParse($result.statusSince, [ref]$statusInstant)) {
    $reasons.Add('status age unreadable')
  }
  if ($native.state -cne 'OPEN' -or -not $native.PSObject.Properties['issueType'] -or
      $native.labels.pageInfo.hasNextPage -ne $false) { $reasons.Add('native eligibility unreadable or truncated') }
  $result.eligible = $true
  foreach ($errorText in $History.errors) { $reasons.Add($errorText) }
  $prs = $native.closedByPullRequestsReferences
  if (-not $prs -or $prs.pageInfo.hasNextPage -ne $false) { $reasons.Add('PR resolution degraded: incomplete closing PR connection') }
  $openPrs = [Collections.Generic.List[int]]::new()
  foreach ($pr in @($prs.nodes)) {
    if (-not $pr -or $pr.state -notin @('OPEN','CLOSED','MERGED') -or $pr.isDraft -isnot [bool] -or $pr.number -le 0) {
      $reasons.Add('PR resolution degraded: malformed closing PR'); continue
    }
    if ($pr.state -ceq 'OPEN' -and -not $pr.isDraft) { $openPrs.Add([int]$pr.number) }
  }
  $liveImplementation = $false; $liveReview = $false
  $evidence = [Collections.Generic.List[string]]::new()
  $related = @($History.rows | Where-Object { $_.issue -eq $native.number })
  $lanes = @($related | Where-Object lane | ForEach-Object { $_.lane } | Sort-Object -Unique)
  # Issue-less watchdog rows can never retire an owner by a number guessed from
  # its branch. Retain them as unknown for the issue linked by canonical history.
  foreach ($row in $History.rows) {
    if (-not $row.issue -and ($row.watchdogSchema -or $row.dispatchRoutingSchema)) {
      if ($row.lane -in $lanes) { $reasons.Add("unlinked watchdog row for lane $($row.lane): missing owning issue") }
    }
  }
  $attempts = @{}
  foreach ($row in $related) {
    if ($row.laneRole -in @('planning','decision','capture')) { continue }
    $rowInstant = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse([string]$row.ts, [ref]$rowInstant)) {
      $reasons.Add('malformed lifecycle timestamp'); continue
    }
    if (-not $row.lane) { $reasons.Add('unlinked lifecycle row: missing lane'); continue }
    # A transcript labels an execution; the semantic attempt can span relaunches.
    $key = "$($row.lane)|$($row.transcript)"
    if (-not $row.transcript) {
      $reasons.Add("unlinked lifecycle attempt in lane $($row.lane)"); continue
    }
    if ($row.kind -ceq 'dispatch') {
      if ($attempts.ContainsKey($key) -and $attempts[$key].dispatch.attemptId -and $row.attemptId -and
          $attempts[$key].dispatch.attemptId -cne $row.attemptId) { $reasons.Add("ambiguous dispatch attempt in $key") }
      $attempts[$key] = @{ dispatch = $row; latest = $row }
    }
    elseif ($attempts.ContainsKey($key)) {
      $dispatch = $attempts[$key].dispatch
      if (($row.attemptId -and $dispatch.attemptId -and $row.attemptId -cne $dispatch.attemptId) -or
          ($row.laneRole -and $row.laneRole -cne $dispatch.laneRole)) {
        $reasons.Add("mismatched terminal attempt in lane $($row.lane)")
      } else { $attempts[$key].latest = $row }
    } else { $reasons.Add("terminal without linked dispatch in lane $($row.lane)") }
  }
  foreach ($key in @($attempts.Keys | Sort-Object)) {
    $attempt = $attempts[$key]; $dispatch = $attempt.dispatch; $latest = $attempt.latest
    $role = [string]$dispatch.laneRole
    if ($role -in @('planning','decision','capture')) { continue }
    if ($role -ne 'implementation' -and $role -ne 'review' -and $dispatch.reviewAuthority -ne 'governing') {
      $reasons.Add("unknown lane role in $key"); continue
    }
    $evidence.Add(($latest | ConvertTo-Json -Compress -Depth 10))
    if ($latest.kind -cne 'dispatch') { continue }
    $label = [IO.Path]::GetFileNameWithoutExtension([string]$dispatch.transcript)
    if (-not $History.specs.ContainsKey($label)) {
      $instant = [datetimeoffset]::MinValue
      if (-not [datetimeoffset]::TryParse([string]$dispatch.ts, [ref]$instant)) { $reasons.Add("malformed dispatch timestamp in $key") }
      elseif ([datetimeoffset]::UtcNow - $instant -le [timespan]::FromHours(6)) { $reasons.Add("spec-less dispatch under six hours in $key") }
      else { $evidence.Add('expired-spec-less') }
      continue
    }
    $entry = $History.specs[$label]; $spec = $entry.value
    if ($entry.error) { $reasons.Add($entry.error); continue }
    $evidence.Add(($spec | ConvertTo-Json -Compress -Depth 10))
    if ($spec.schemaVersion -notin @('watchdog-lane/v1','watchdog-lane/v2','watchdog-lane/v3','watchdog-lane/v4') -or
        [string]::IsNullOrWhiteSpace([string]$spec.worktree) -or $spec.launchId -isnot [string] -or $spec.launchId -cnotmatch '^[a-f0-9-]{36}$' -or
        -not $spec.attemptId -or $spec.attemptId -cne $(if ($dispatch.attemptId) { $dispatch.attemptId } else { $label }) -or
        (Split-Path -Leaf ([string]$spec.worktree).TrimEnd('\','/')) -cne $dispatch.lane -or
        $spec.laneRole -cne $role -or ($dispatch.launchId -and $dispatch.launchId -cne $spec.launchId) -or
        $spec.state -notin @('running','launching','exited')) {
      $reasons.Add("malformed watchdog envelope or mismatched attempt $label"); continue
    }
    if (($spec.childPid -isnot [int] -and $spec.childPid -isnot [long]) -or $spec.childPid -le 0 -or
        $spec.childPid -gt [int]::MaxValue -or $spec.childStartIdentity -isnot [string]) {
      $reasons.Add("malformed process identity for $label"); continue
    }
    $identity = Get-DispatchProcessIdentityState -ProcessId $spec.childPid -StartIdentity $spec.childStartIdentity
    $evidence.Add($identity)
    if ($identity -ceq 'ambiguous') { $reasons.Add("ambiguous process identity for $label"); continue }
    if ($spec.state -ceq 'exited') { continue }
    if ($identity -ceq 'dead') { continue }
    if ($role -ceq 'implementation') { $liveImplementation = $true } else { $liveReview = $true }
  }
  $nativeEvidence = [ordered]@{ state = $native.state; issueType = $native.issueType.name
    labels = @($native.labels.nodes.name | Sort-Object)
    prs = @($prs.nodes | Sort-Object number | Select-Object number, state, isDraft) }
  $result.evidence = (@($evidence) -join "`n") + "`nNative:" + ($nativeEvidence | ConvertTo-Json -Compress -Depth 5)
  if ($reasons.Count) {
    $result.known = $false; $result.action = 'deferred'; $result.why = (@($reasons | Sort-Object -Unique) -join '; ')
    return [pscustomobject]$result
  }
  $result.desired = if ($liveImplementation) { 'In lane' } elseif ($liveReview -or $openPrs.Count) { 'In review' } else { $null }
  $result.why = if ($liveImplementation) { 'live implementation' } elseif ($liveReview) { 'live review' } elseif ($openPrs.Count) { 'open non-draft closing PR' } else { 'no live implementation/review or non-draft closing PR' }
  if ($result.desired -and $result.desired -cne $result.status) { $result.action = 'set' }
  elseif (-not $result.desired -and $result.status -in @('In lane','In review','Landed')) { $result.action = 'clear' }
  return [pscustomobject]$result
}

function Test-BoardObservationUnchanged($Before, $After) {
  return $After.known -and $After.eligible -and $Before.itemId -ceq $After.itemId -and
    $Before.status -ceq $After.status -and $Before.statusSince -ceq $After.statusSince -and
    $Before.desired -ceq $After.desired -and $Before.evidence -ceq $After.evidence
}
