<#
.SYNOPSIS
Project live implementation/review attempts onto open executable board issues.
Terminal events use the same observation functions; this hourly backstop repairs
missed events. Clearing hands status derivation back to project-status-sync.
#>
[CmdletBinding()]
param(
  [switch]$Apply,
  # Retained caller compatibility; spec-less dispatch death has a fixed 6h bound.
  [double]$MinIdleHours = 2,
  [ValidateRange(1, 2147483647)][int]$MaxClears = 10,
  [string]$Repo = 'chase-sets/chase-sets',
  [string]$DispatchLog,
  [string]$GhCommand = 'gh',
  [switch]$FunctionsOnly
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'dispatch-ownership.ps1')

function Invoke-BoardQuery([string]$Cli, [string[]]$Arguments) {
  $raw = & $Cli @Arguments 2>&1
  if ($LASTEXITCODE -ne 0) { throw "board read failed (gh exit $LASTEXITCODE)" }
  $value = "$raw" | ConvertFrom-Json -DateKind String
  if ($value.errors -or -not $value.data) { throw 'board read returned incomplete data' }
  return $value.data
}

function Get-BoardIssueFields {
  return 'id number state issueType{name} labels(first:100){nodes{name} pageInfo{hasNextPage}} closedByPullRequestsReferences(first:100,includeClosedPrs:false){nodes{number state isDraft} pageInfo{hasNextPage}}'
}

function Get-BoardIssue([int]$Number, [string]$Repository, [string]$Project, [string]$Cli) {
  $owner, $name = $Repository.Split('/', 2)
  $fields = Get-BoardIssueFields
  $query = "query(`$owner:String!,`$name:String!,`$number:Int!){repository(owner:`$owner,name:`$name){issue(number:`$number){$fields projectItems(first:100){nodes{id project{id} status:fieldValueByName(name:`"Status`"){... on ProjectV2ItemFieldSingleSelectValue{name updatedAt}}} pageInfo{hasNextPage}}}}}"
  $data = Invoke-BoardQuery $Cli @('api','graphql','-f',"query=$query",'-F',"owner=$owner",'-F',"name=$name",'-F',"number=$Number")
  $native = $data.repository.issue
  if (-not $native -or $native.projectItems.pageInfo.hasNextPage -ne $false) { throw 'issue/project linkage unreadable or truncated' }
  $matches = @($native.projectItems.nodes | Where-Object { $_.project.id -ceq $Project })
  if ($matches.Count -gt 1) { throw 'ambiguous board item' }
  return [pscustomobject]@{ id = $(if ($matches.Count) { $matches[0].id } else { $null })
    status = $(if ($matches.Count) { $matches[0].status } else { $null }); content = $native }
}

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
          if (-not $row.kind) { continue }
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
  $indexes = New-BoardHistoryIndexes $rows ($specs.Count -gt 0)
  $indexes.scopeComplete = $errors.Count -eq 0
  $unlinkedSpecs = New-BoardUnlinkedSpecScope $specs $indexes
  return @{ rows = @($rows); specs = $specs; errors = @($errors); count = $count; indexes = $indexes; unlinkedSpecs = $unlinkedSpecs }
}

function Get-BoardProcessSnapshot {
  $snapshot = @{ healthy = $false; ids = @{}; parents = @{} }
  try {
    $processes = @(Get-CimInstance Win32_Process -Property ProcessId,ParentProcessId,CreationDate -ErrorAction Stop)
    if (-not $processes.Count) { return $snapshot }
    foreach ($process in $processes) {
      foreach ($value in @($process.ProcessId, $process.ParentProcessId)) {
        if ($value -isnot [uint32] -and $value -isnot [int] -and $value -isnot [long]) { return $snapshot }
        if ($value -lt 0 -or $value -gt [int]::MaxValue) { return $snapshot }
      }
      $id = [int]$process.ProcessId; $parent = [int]$process.ParentProcessId
      if ($snapshot.ids.ContainsKey($id)) { return $snapshot }
      $creation = $process.CreationDate
      $created = [datetimeoffset]::MinValue
      if ($creation -is [datetime]) { $created = [datetimeoffset]$creation.ToUniversalTime() }
      elseif ($creation -is [datetimeoffset]) { $created = $creation.ToUniversalTime() }
      elseif ($creation -isnot [string] -or -not [datetimeoffset]::TryParse($creation,
          [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$created)) { return $snapshot }
      $created = $created.ToUniversalTime()
      $snapshot.ids[$id] = $created
      if (-not $snapshot.parents.ContainsKey($parent)) { $snapshot.parents[$parent] = [Collections.Generic.List[object]]::new() }
      $snapshot.parents[$parent].Add(@{ id = $id; created = $created })
    }
    $snapshot.healthy = $true
  } catch { $snapshot.healthy = $false }
  return $snapshot
}

function Test-BoardUnlinkedEnvelope($Spec, [string]$Label) {
  return $Spec.schemaVersion -cin @('watchdog-lane/v1','watchdog-lane/v2','watchdog-lane/v3','watchdog-lane/v4') -and
    $Spec.label -is [string] -and $Spec.label -ceq $Label -and
    $Spec.attemptId -is [string] -and -not [string]::IsNullOrWhiteSpace($Spec.attemptId) -and
    $Spec.launchId -is [string] -and $Spec.launchId -cmatch '^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$' -and
    $Spec.worktree -is [string] -and [IO.Path]::IsPathFullyQualified($Spec.worktree) -and
    $Spec.branch -is [string] -and ($Spec.branch.Length -gt 0 -or ($Spec.head -is [string] -and $Spec.head -cmatch '^[a-f0-9]{40}$')) -and
    $Spec.laneRole -cin @('implementation','review','planning','decision','capture') -and
    $Spec.state -cin @('running','launching','exited') -and
    ($null -eq $Spec.partialReportPath -or $Spec.partialReportPath -is [string]) -and
    ($null -eq $Spec.transcriptPath -or $Spec.transcriptPath -is [string])
}

function Test-BoardUnlinkedDeath($Spec, $Processes) {
  if (-not $Processes.healthy) { return $false }
  $updated = [datetimeoffset]::MinValue
  if ($Spec.updatedAt -isnot [string] -or -not [datetimeoffset]::TryParseExact($Spec.updatedAt, 'o',
      [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$updated) -or
      $updated -gt [datetimeoffset]::UtcNow) { return $false }
  $starts = @{}
  foreach ($root in @('launcher','child')) {
    $id = $Spec."${root}Pid"; $identity = $Spec."${root}StartIdentity"
    $start = [datetimeoffset]::MinValue
    if (($id -isnot [int] -and $id -isnot [long]) -or $id -le 0 -or $id -gt [int]::MaxValue -or
        -not (Test-DispatchUtcRoundTripIdentity $identity) -or -not [datetimeoffset]::TryParse($identity, [ref]$start) -or
        $start -gt $updated) { return $false }
    $starts[$root] = $start
  }
  if ($Spec.launcherPid -eq $Spec.childPid -or $starts.launcher -gt $starts.child) { return $false }
  foreach ($root in @('launcher','child')) {
    $id = [int]$Spec."${root}Pid"
    $end = $null
    if ($Processes.ids.ContainsKey($id)) {
      $created = $Processes.ids[$id]
      # CIM truncates to microseconds. Inequality with a recorded 100 ns start
      # is not reuse proof; only creation strictly after updatedAt proves it.
      if ($created -le $updated) { return $false }
      $end = $created
    }
    # The launcher can spawn work after writing exited. Only a non-resume
    # child's completed wait supplies an updatedAt lifetime upper bound.
    if ($root -ceq 'child' -and $Spec.state -ceq 'exited' -and
        $Spec.schemaVersion -cin @('watchdog-lane/v1','watchdog-lane/v2','watchdog-lane/v3') -and
        ($Spec.exitCode -is [int] -or $Spec.exitCode -is [long])) {
      if ($null -eq $end -or $updated -lt $end) { $end = $updated }
    }
    foreach ($edge in $Processes.parents[$id]) {
      if ($edge.id -eq $id -or $edge.created -lt $starts[$root].AddMilliseconds(-1) -or
          ($null -ne $end -and $edge.created -gt $end)) { continue }
      return $false
    }
  }
  return $true
}

function Get-BoardScopeIssueNumber([string]$Value, [switch]$Branch) {
  # Closed positional forms, not digit-substring extraction. Labels:
  # [controller-]<issue>-<words>-gN/rN[-cN], controller-<words>-<issue>-gN/rN[-cN].
  # Branches: codex|claude/[controller-]<issue>-<words>[-gN/rN[-cN]], or <words>-<issue>-gN|hex-head.
  $patterns = if ($Branch) { @(
    '\A(?:codex|claude)/(?<issue>[1-9][0-9]*)-[a-z]+(?:-[a-z]+)*(?:-(?:g|r)[1-9][0-9]*(?:-c[1-9][0-9]*)?)?\z',
    '\A(?:codex|claude)/controller-(?<issue>[1-9][0-9]*)-[a-z]+(?:-[a-z]+)*(?:-(?:g|r)[1-9][0-9]*(?:-c[1-9][0-9]*)?)?\z',
    '\A(?:codex|claude)/(?:[a-z]+-)+(?<issue>[1-9][0-9]*)-(?:g[1-9][0-9]*|[a-f0-9]{7,40})\z'
  ) } else { @(
    '\A(?:controller-)?(?<issue>[1-9][0-9]*)-(?:[a-z]+-)+(?:g|r)[1-9][0-9]*(?:-c[1-9][0-9]*)?\z',
    '\Acontroller-(?:[a-z]+-)+(?<issue>[1-9][0-9]*)-(?:g|r)[1-9][0-9]*(?:-c[1-9][0-9]*)?\z'
  ) }
  foreach ($pattern in $patterns) {
    $number = 0
    if ($Value -cmatch $pattern -and [int]::TryParse($Matches.issue, [ref]$number)) { return $number }
  }
  return 0
}

function Get-BoardUnlinkedLaunchEvidence($Spec, $Keys, $Indexes) {
  $rows = [Collections.Generic.HashSet[object]]::new()
  foreach ($kind in @('lanes','transcripts')) {
    foreach ($key in $Keys[$kind]) {
      if ($key) { foreach ($row in $Indexes.scopeRows[$kind][$key]) { [void]$rows.Add($row) } }
    }
  }
  $consistent = $true; $scopeConsistent = $true; $corroborated = $false
  $laneAliases = [Collections.Generic.HashSet[string]]::new([StringComparer]::InvariantCultureIgnoreCase)
  $issues = [Collections.Generic.HashSet[int]]::new()
  foreach ($row in $rows) {
    $sameTranscript = $row.transcript -is [string] -and
      [IO.Path]::GetFileNameWithoutExtension($row.transcript) -ceq $Spec.label
    $sameSeatDispatch = $row.kind -ceq 'dispatch' -and $row.lane -eq (Split-Path -Leaf $Spec.worktree.TrimEnd('\','/')) -and
      $row.laneRole -notin @('planning','decision','capture')
    if (($sameTranscript -or $sameSeatDispatch) -and $row.issue) {
      if (($row.issue -isnot [int] -and $row.issue -isnot [long]) -or $row.issue -le 0 -or $row.issue -gt [int]::MaxValue) {
        $scopeConsistent = $false
      } else { [void]$issues.Add([int]$row.issue) }
    }
    if ($sameSeatDispatch -and $row.branch -and $row.branch -cne $Spec.branch) { $scopeConsistent = $false }
    if (-not $sameTranscript) { continue }
    foreach ($field in @('attemptId','launchId','branch','laneRole')) {
      if ($row.$field -and $row.$field -cne $Spec.$field) { $consistent = $false }
    }
    if ($row.lane -and $row.lane -cne (Split-Path -Leaf $Spec.worktree.TrimEnd('\','/'))) {
      $scopeConsistent = $false
      [void]$laneAliases.Add([string]$row.lane)
    }
    $instant = [datetimeoffset]::MinValue
    if ($row.kind -ceq 'dispatch' -and $row.attemptId -ceq $Spec.attemptId -and
        [datetimeoffset]::TryParse([string]$row.ts, [ref]$instant)) { $corroborated = $true }
  }
  return @{ consistent = $consistent; scopeConsistent = $scopeConsistent; corroborated = $corroborated; issues = $issues; laneAliases = $laneAliases }
}

function New-BoardUnlinkedSpecScope($Specs, $Indexes) {
  $scope = @{ all = [Collections.Generic.List[string]]::new(); active = [Collections.Generic.List[string]]::new()
    lanes = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::InvariantCultureIgnoreCase)
    transcripts = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::InvariantCultureIgnoreCase)
    issues = @{} }
  $now = [datetimeoffset]::UtcNow
  $processes = $null
  foreach ($label in $Specs.Keys) {
    if ($Indexes.linkedLabels.Contains($label)) { continue }
    $reason = "unlinked watchdog ${label}: owning issue unknown"
    $scope.all.Add($reason)
    $entry = $Specs[$label]; $spec = $entry.value
    $lane = if ($spec.worktree -is [string] -and -not [string]::IsNullOrWhiteSpace($spec.worktree.TrimEnd('\','/'))) {
      Split-Path -Leaf $spec.worktree.TrimEnd('\','/')
    }
    $keys = @{ lanes = @($lane); transcripts = @($label) }
    foreach ($path in @($spec.partialReportPath, $spec.transcriptPath)) {
      if ($path -is [string] -and $path) { $keys.transcripts += [IO.Path]::GetFileNameWithoutExtension($path) }
    }
    $valid = -not $entry.error -and $lane -and (Test-BoardUnlinkedEnvelope $spec $label)
    if ($valid) {
      $launch = Get-BoardUnlinkedLaunchEvidence $spec $keys $Indexes
      $keys.lanes += @($launch.laneAliases)
    }
    foreach ($kind in @('lanes','transcripts')) {
      foreach ($key in $keys[$kind]) {
        if (-not $key) { continue }
        if (-not $scope[$kind].ContainsKey($key)) { $scope[$kind][$key] = [Collections.Generic.List[string]]::new() }
        $scope[$kind][$key].Add($reason)
      }
    }
    if (-not $valid) {
      $scope.active.Add($reason); continue
    }
    if (-not $launch.consistent) { $scope.active.Add($reason); continue }
    if ($null -eq $processes) { $processes = Get-BoardProcessSnapshot }
    $instant = [datetimeoffset]::MinValue
    $recent = -not [datetimeoffset]::TryParse([string]$spec.updatedAt, [ref]$instant) -or $now - $instant -le [timespan]::FromHours(6)
    $dead = Test-BoardUnlinkedDeath $spec $processes
    if ($dead -and ($spec.state -ceq 'exited' -or -not $recent)) { continue }
    # Derivation only bounds this refusal. It never changes rows, attempts,
    # ownership, or terminal authority; every intersection above is retained.
    $number = Get-BoardScopeIssueNumber $label
    $branchNumber = Get-BoardScopeIssueNumber $spec.branch -Branch
    if ($Indexes.scopeComplete -and $launch.scopeConsistent -and $launch.corroborated -and $number -gt 0 -and $number -eq $branchNumber -and
        $Indexes.canonicalIssues.Contains($number) -and @($launch.issues | Where-Object { $_ -ne $number }).Count -eq 0) {
      if (-not $scope.issues.ContainsKey($number)) { $scope.issues[$number] = [Collections.Generic.List[string]]::new() }
      $scope.issues[$number].Add($reason)
    } else {
      $scope.active.Add($reason)
    }
  }
  return $scope
}

function Get-BoardUnlinkedSpecReasons($Scope, $Lanes, $Rows, [int]$Number) {
  if (-not $Scope) { return }
  foreach ($reason in $Scope.active) { $reason }
  foreach ($reason in $Scope.issues[$Number]) { $reason }
  foreach ($lane in $Lanes) {
    if ($lane -is [string]) {
      foreach ($reason in $Scope.lanes[$lane]) { $reason }
    } else {
      # Preserve the same typed lane membership semantics as issue-less rows.
      foreach ($key in $Scope.lanes.Keys) {
        if ($key -in @($lane)) { foreach ($reason in $Scope.lanes[$key]) { $reason } }
      }
    }
  }
  foreach ($row in $Rows) {
    if ($row.transcript) {
      $label = [IO.Path]::GetFileNameWithoutExtension([string]$row.transcript)
      foreach ($reason in $Scope.transcripts[$label]) { $reason }
    }
  }
}

function New-BoardHistoryIndexes($Rows, [bool]$LinkLabels) {
  # PowerShell string equality uses invariant-culture comparison, not ordinal
  # comparison. Linkage is case-sensitive; lane membership is not.
  $linkedLabels = [Collections.Generic.HashSet[string]]::new([StringComparer]::InvariantCulture)
  $issues = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::InvariantCultureIgnoreCase)
  $lanes = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::InvariantCultureIgnoreCase)
  $nonzeroIssues = [Collections.Generic.List[object]]::new()
  $otherLanes = [Collections.Generic.List[object]]::new()
  $ordinal = 0
  $canonicalIssues = [Collections.Generic.HashSet[int]]::new()
  $scopeRows = @{}
  foreach ($kind in @('lanes','transcripts')) {
    $scopeRows[$kind] = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::InvariantCultureIgnoreCase)
  }
  foreach ($row in $Rows) {
    if ($LinkLabels) {
      $scopeInstant = [datetimeoffset]::MinValue
      if (($row.issue -is [int] -or $row.issue -is [long]) -and $row.issue -gt 0 -and $row.issue -le [int]::MaxValue -and
          [datetimeoffset]::TryParse([string]$row.ts, [ref]$scopeInstant)) {
        [void]$canonicalIssues.Add([int]$row.issue)
      }
      $scopeKeys = @{ lanes = $row.lane; transcripts = $(if ($row.transcript -is [string]) { [IO.Path]::GetFileNameWithoutExtension($row.transcript) }) }
      foreach ($kind in @('lanes','transcripts')) {
        $scopeKey = $scopeKeys[$kind]
        if ($scopeKey -isnot [string] -or -not $scopeKey) { continue }
        if (-not $scopeRows[$kind].ContainsKey($scopeKey)) { $scopeRows[$kind][$scopeKey] = [Collections.Generic.List[object]]::new() }
        $scopeRows[$kind][$scopeKey].Add($row)
      }
    }
    if ($LinkLabels -and $row.issue -gt 0 -and $row.transcript) {
      [void]$linkedLabels.Add([IO.Path]::GetFileNameWithoutExtension([string]$row.transcript))
    }
    $entry = @{ row = $row; ordinal = $ordinal++ }
    # JSON issue values are not schema-restricted. Arrays use PowerShell's
    # filtered-result truthiness; true matches every nonzero native Int32.
    $nonzero = $false
    if ($row.issue -is [long] -or $row.issue -is [int] -or $row.issue -is [string]) {
      $key = [string]$row.issue
      if (-not $issues.ContainsKey($key)) { $issues[$key] = [Collections.Generic.List[object]]::new() }
      $issues[$key].Add($entry)
    } else {
      $keys = [Collections.Generic.HashSet[string]]::new([StringComparer]::InvariantCultureIgnoreCase)
      foreach ($value in @($row.issue)) {
        if ($value -is [string]) { [void]$keys.Add($value) }
        elseif ($value -is [bool]) {
          if ($value) { $nonzero = $true } else { [void]$keys.Add('0') }
        }
        elseif ($null -ne $value -and $value -is [ValueType]) {
          $number = 0
          if ([int]::TryParse([string]$value, [ref]$number) -and $value -eq $number) {
            [void]$keys.Add([string]$number)
          }
        }
      }
      foreach ($key in $keys) {
        if (-not $issues.ContainsKey($key)) { $issues[$key] = [Collections.Generic.List[object]]::new() }
        $issues[$key].Add($entry)
      }
    }
    if ($nonzero) { $nonzeroIssues.Add($entry) }
    if (-not $row.issue -and ($row.watchdogSchema -or $row.dispatchRoutingSchema)) {
      if ($row.lane -is [string]) {
        if (-not $lanes.ContainsKey($row.lane)) { $lanes[$row.lane] = [Collections.Generic.List[object]]::new() }
        $lanes[$row.lane].Add($entry)
      } else { $otherLanes.Add($entry) }
    }
  }
  return @{ linkedLabels = $linkedLabels; issues = $issues; nonzeroIssues = $nonzeroIssues
    lanes = $lanes; otherLanes = $otherLanes; scopeRows = $scopeRows; canonicalIssues = $canonicalIssues; scopeComplete = $true }
}

function Get-BoardIssueRows($Indexes, [int]$Number) {
  if (-not $Indexes) { return }
  $entries = $Indexes.issues[[string]$Number]
  if ($Number -ne 0 -and $Indexes.nonzeroIssues.Count) {
    $entries = @(@($entries) + @($Indexes.nonzeroIssues) | Sort-Object ordinal -Unique)
  }
  foreach ($entry in $entries) {
    if ($entry.row.issue -eq $Number) { $entry.row }
  }
}

function Get-BoardUnlinkedLaneRows($Indexes, $Lanes) {
  if (-not $Indexes -or -not $Lanes.Count) { return }
  $selected = [Collections.Generic.HashSet[object]]::new()
  $entries = [Collections.Generic.List[object]]::new()
  $typed = $false
  foreach ($lane in $Lanes) {
    if ($lane -is [string]) {
      foreach ($entry in $Indexes.lanes[$lane]) { if ($selected.Add($entry)) { $entries.Add($entry) } }
    } else { $typed = $true }
  }
  if ($typed) {
    # A typed -in member is the left operand and may convert comparer-equal
    # bucket strings differently; apply the original test per indexed row.
    foreach ($key in $Indexes.lanes.Keys) {
      foreach ($entry in $Indexes.lanes[$key]) {
        if (-not $selected.Contains($entry) -and $entry.row.lane -in $Lanes) { [void]$selected.Add($entry); $entries.Add($entry) }
      }
    }
  }
  foreach ($entry in $Indexes.otherLanes) {
    if ($entry.row.lane -in $Lanes -and $selected.Add($entry)) { $entries.Add($entry) }
  }
  # Sort-Object -Unique later retains the first casing of equal reasons.
  foreach ($entry in ($entries | Sort-Object ordinal)) { $entry.row }
}

function Get-BoardProjection($Item, $History) {
  if (-not $History.indexes -and $History.rows.Count -gt 0) { throw 'non-empty board history requires indexes' }
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
  $related = @(Get-BoardIssueRows $History.indexes $native.number)
  $lanes = @($related | Where-Object lane | ForEach-Object { $_.lane } | Sort-Object -Unique)
  foreach ($reason in (Get-BoardUnlinkedSpecReasons $History.unlinkedSpecs $lanes $related $native.number)) { $reasons.Add($reason) }
  # Issue-less watchdog rows can never retire an owner by a number guessed from
  # its branch. Retain them as unknown for the issue linked by canonical history.
  foreach ($row in (Get-BoardUnlinkedLaneRows $History.indexes $lanes)) {
    $reasons.Add("unlinked watchdog row for lane $($row.lane): missing owning issue")
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

if ($FunctionsOnly) { return }
$dispatchPath = if ($DispatchLog) { [IO.Path]::GetFullPath($DispatchLog) } else { Join-Path $PSScriptRoot 'dispatch-log.jsonl' }
$projectId = (& $GhCommand variable get DELIVERY_PROJECT_ID --repo $Repo 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or -not $projectId) { throw 'DELIVERY_PROJECT_ID is unreadable' }
$fields = Get-BoardIssueFields
$query = "query(`$project:ID!,`$after:String){node(id:`$project){... on ProjectV2{items(first:100,after:`$after){pageInfo{hasNextPage endCursor} nodes{id status:fieldValueByName(name:`"Status`"){... on ProjectV2ItemFieldSingleSelectValue{name updatedAt}} content{__typename ... on Issue{$fields}}}}}}}"
$items = [Collections.Generic.List[object]]::new(); $after = $null
$cursors = [Collections.Generic.HashSet[string]]::new(); $numbers = [Collections.Generic.HashSet[int]]::new()
do {
  $arguments = @('api','graphql','-f',"query=$query",'-F',"project=$projectId")
  if ($after) { $arguments += @('-F',"after=$after") }
  $page = (Invoke-BoardQuery $GhCommand $arguments).node.items
  if (-not $page -or $page.pageInfo.hasNextPage -isnot [bool]) { throw 'board pagination unreadable' }
  foreach ($item in @($page.nodes)) {
    if ($item.content.__typename -cne 'Issue') { continue }
    if (-not $numbers.Add([int]$item.content.number)) { throw 'duplicate board issue' }
    $items.Add($item)
  }
  $after = if ($page.pageInfo.hasNextPage) { $page.pageInfo.endCursor } else { $null }
  if ($page.pageInfo.hasNextPage -and (-not $after -or -not $cursors.Add($after))) { throw 'board pagination incomplete' }
} while ($after)
$history = Get-BoardHistory $dispatchPath
$projections = @($items | ForEach-Object { Get-BoardProjection $_ $history })
$prDegraded = @($projections | Where-Object { $_.why -like '*PR resolution degraded*' }).Count -gt 0
if ($prDegraded) {
  foreach ($projection in $projections | Where-Object eligible) {
    $projection.known = $false; $projection.action = 'deferred'; $projection.why = 'PR resolution degraded; no mutations this run'
  }
}
$findings = @($projections | Where-Object { $_.action -ne 'none' } | Sort-Object statusSince, issue | ForEach-Object {
  [pscustomobject]@{ finding = $(if ($_.known) { 'lane-status-drift' } else { 'insufficient-evidence' }); issue = $_.issue
    status = $_.status; desired = $_.desired; action = $(if ($_.known) { "would-$($_.action)" } else { 'deferred' }); why = $_.why }
})
$qualifying = @($projections | Where-Object { $_.action -in @('clear','set') }).Count
$mutations = 0; $attempted = 0
if ($Apply) {
  foreach ($finding in $findings | Where-Object { $_.action -like 'would-*' }) {
    if ($attempted -ge $MaxClears) { $finding.action = 'deferred'; $finding.why = "mutation cap $MaxClears; retained for next hourly run"; continue }
    try {
      $before = @($projections | Where-Object issue -eq $finding.issue)[0]
      $freshItem = Get-BoardIssue $finding.issue $Repo $projectId $GhCommand
      $fresh = Get-BoardProjection $freshItem (Get-BoardHistory $dispatchPath)
      if (-not (Test-BoardObservationUnchanged $before $fresh)) { # BOARD_PRE_MUTATION_GUARD
        $finding.action = 'deferred'; $finding.why = "pre-mutation observation changed or unknown: $($fresh.why)"; continue
      }
      $arguments = @{ Issue = $finding.issue; Repo = $Repo; GhCommand = $GhCommand; DispatchLog = $dispatchPath; ExpectedObservation = $fresh }
      if ($fresh.desired) { $arguments.Status = $fresh.desired } else { $arguments.Clear = $true }
      $attempted++
      $written = & (Join-Path $PSScriptRoot 'board-set.ps1') @arguments | ConvertFrom-Json
      if (-not $written.ok -or $written.action -notin @('clear','set')) { throw 'board write failed or deferred' }
      $mutations++; $finding.action = if ($fresh.desired) { 'set' } else { 'cleared' }
    } catch { $finding.action = 'deferred'; $finding.why = "pre-mutation read/write failed: $($_.Exception.Message)" }
  }
}
$syncDispatched = $false; $syncError = $null
if ($Apply -and (@($findings | Where-Object action -eq 'cleared').Count -or @($items | Where-Object { -not $_.status.name }).Count)) {
  $syncOutput = & $GhCommand workflow run project-status-sync.yml --repo $Repo 2>&1
  $syncDispatched = $LASTEXITCODE -eq 0
  if (-not $syncDispatched) { $syncError = "project-status-sync dispatch failed (gh exit $LASTEXITCODE)" }
}
$telemetryError = $null
$cleared = @($findings | Where-Object action -eq 'cleared')
if ($cleared.Count) {
  try {
    $gcLog = if ($DispatchLog) { @{ OutFile = $dispatchPath } } else { @{} }
    & (Join-Path $PSScriptRoot 'log-event.ps1') -Log dispatch -Kind gc -NoBoard @gcLog `
      -Note "board-reconcile cleared $($cleared.Count) stale lane-owned statuses: $($cleared.issue -join ',')" | Out-Null
  } catch { $telemetryError = $_.Exception.Message }
}
[ordered]@{
  ts = [datetimeoffset]::UtcNow.ToString('o'); kind = 'board-reconcile'; applied = [bool]$Apply
  scanned = $items.Count; laneOwned = @($items | Where-Object { $_.status.name -in @('In lane','In review','Landed') }).Count
  lifecycleRows = $history.count; prResolution = $(if ($prDegraded) { 'degraded' } else { 'ok' }); refused = $null
  qualifying = $qualifying; mutations = $mutations; deferred = @($findings | Where-Object action -eq 'deferred').Count
  syncDispatched = $syncDispatched; syncError = $syncError; telemetryError = $telemetryError; findings = @($findings)
  projections = @($projections | Select-Object issue, status, eligible, known, desired, why)
} | ConvertTo-Json -Compress -Depth 8
