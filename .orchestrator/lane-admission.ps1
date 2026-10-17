[CmdletBinding()]
param(
  [string]$InputPath,
  [string]$InputJson,
  [switch]$Library,
  [switch]$Compact
)

$ErrorActionPreference = "Stop"

$script:LaneAdmissionAuthoritySets = @(
  "candidate-issues",
  "labels",
  "milestones",
  "open-prs",
  "active-lanes"
)
$script:LaneAdmissionReasonCodes = @(
  "GLOBAL_AUTHORITY_MISSING",
  "GLOBAL_AUTHORITY_DUPLICATE",
  "GLOBAL_AUTHORITY_INCOMPLETE",
  "GLOBAL_AUTHORITY_MOVED",
  "GLOBAL_AUTHORITY_CAP_MISMATCH",
  "CANDIDATE_AUTHORITY_UNKNOWN",
  "CANDIDATE_AUTHORITY_MOVED",
  "CANDIDATE_PATH_UNKNOWN",
  "ACTIVE_LANE_AUTHORITY_UNKNOWN",
  "ORDERING_UNKNOWN",
  "DEPENDENCY_BLOCKED",
  "DEPENDENCY_CYCLE",
  "READINESS_UNKNOWN",
  "LIFECYCLE_INELIGIBLE",
  "MILESTONE_UNKNOWN",
  "OVERRIDE_CANNOT_SATISFY_UNKNOWN"
)

function Get-LaneObjectKeys([object]$Object) {
  if ($null -eq $Object) { return @() }
  if ($Object -is [Collections.IDictionary]) { return @($Object.Keys | ForEach-Object { [string]$_ }) }
  return @($Object.PSObject.Properties.Name)
}

function Get-LaneProperty([object]$Object, [string]$Name, [object]$Default = $null) {
  if ($null -eq $Object) { return $Default }
  if ($Object -is [Collections.IDictionary]) {
    if ($Object.Contains($Name)) { return $Object[$Name] }
    return $Default
  }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) { return $Default }
  return $property.Value
}

function Assert-LaneExactKeys(
  [object]$Object,
  [string[]]$Required,
  [string[]]$Optional = @(),
  [string]$At = "object"
) {
  if ($null -eq $Object -or $Object -is [string] -or $Object -is [ValueType]) {
    throw "$At must be an object"
  }
  $actual = @(Get-LaneObjectKeys $Object)
  $allowed = @($Required) + @($Optional)
  foreach ($key in $actual) {
    if ($key -cnotin $allowed) { throw "$At contains unknown property '$key'" }
  }
  foreach ($key in $Required) {
    if ($key -cnotin $actual) { throw "$At is missing property '$key'" }
  }
}

function Test-LaneInstant([object]$Value) {
  if ($Value -is [datetimeoffset]) { return $true }
  if ($Value -is [datetime]) { return $Value.Kind -ne [DateTimeKind]::Unspecified }
  if ($Value -isnot [string] -or
      $Value -cnotmatch '^\d{4}-\d{2}-\d{2}T.+(?:Z|[+-]\d{2}:\d{2})$') {
    return $false
  }
  $parsed = [datetimeoffset]::MinValue
  return [datetimeoffset]::TryParse(
    $Value,
    [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::RoundtripKind,
    [ref]$parsed
  )
}

function ConvertTo-LaneInstant([object]$Value, [string]$At) {
  if (-not (Test-LaneInstant $Value)) { throw "$At must be a timezone-bearing instant" }
  if ($Value -is [datetimeoffset]) { return $Value }
  if ($Value -is [datetime]) { return [datetimeoffset]$Value }
  return [datetimeoffset]::Parse(
    [string]$Value,
    [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::RoundtripKind
  )
}

function Format-LaneInstant([object]$Value, [string]$At) {
  $instant = ConvertTo-LaneInstant $Value $At
  return $instant.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture)
}

function Assert-LaneCount([object]$Value, [string]$At) {
  if ($Value -isnot [ValueType]) { throw "$At must be an integer" }
  $parsed = 0L
  if (-not [int64]::TryParse([string]$Value, [ref]$parsed) -or $parsed -lt 0 -or $parsed -gt 1000000) {
    throw "$At must be an integer from 0 through 1000000"
  }
}

function Assert-LaneIdentifier([object]$Value, [string]$At, [int]$Maximum = 128) {
  if ($Value -isnot [string] -or $Value.Length -lt 1 -or $Value.Length -gt $Maximum -or
      $Value -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._:/@+-]*$') {
    throw "$At is invalid"
  }
}

function Assert-LaneUnique([object[]]$Values, [string]$At) {
  $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($value in @($Values)) {
    if (-not $seen.Add([string]$value)) { throw "$At contains a duplicate value" }
  }
}

function ConvertTo-LaneAdmissionPath([object]$Value) {
  if ($Value -isnot [string] -or $Value.Length -lt 1 -or $Value.Length -gt 512) {
    throw "path must be a non-empty bounded string"
  }
  if ($Value -cne $Value.Trim()) { throw "path may not contain outer whitespace" }
  $path = $Value.Replace("\", "/")
  if ($path.StartsWith("/") -or $path -cmatch '^[A-Za-z]:' -or $path.Contains("//") -or
      $path.EndsWith("/")) {
    throw "path must be repo-relative and normalized"
  }
  while ($path.StartsWith("./", [StringComparison]::Ordinal)) {
    $path = $path.Substring(2)
  }
  if (-not $path) { throw "path may not resolve to empty" }
  $segments = @($path.Split("/"))
  for ($index = 0; $index -lt $segments.Count; $index++) {
    $segment = $segments[$index]
    if (-not $segment -or $segment -ceq "." -or $segment -ceq ".." -or
        $segment -cnotmatch '^[A-Za-z0-9._@+,\-*?]+$') {
      throw "path contains an invalid segment"
    }
    if ($segment.Contains("**") -and
        -not ($segment -ceq "**" -and $index -eq ($segments.Count - 1))) {
      throw "recursive wildcard is only valid as the final complete segment"
    }
  }
  return [ordered]@{
    value = ($segments -join "/").ToLowerInvariant()
    segments = @($segments | ForEach-Object { $_.ToLowerInvariant() })
    recursive = $segments[-1] -ceq "**"
  }
}

function Test-LaneAdmissionSegmentCompatibility([string]$Left, [string]$Right) {
  $leftWild = $Left.Contains("*") -or $Left.Contains("?")
  $rightWild = $Right.Contains("*") -or $Right.Contains("?")
  if (-not $leftWild -and -not $rightWild) {
    return [string]::Equals($Left, $Right, [StringComparison]::OrdinalIgnoreCase)
  }
  if ($leftWild -and $rightWild) {
    # The bounded grammar has no negation. Ambiguous wildcard intersections
    # serialize conservatively; they never establish disjointness.
    return $true
  }
  $pattern = if ($leftWild) { $Left } else { $Right }
  $literal = if ($leftWild) { $Right } else { $Left }
  $regex = "^" + [regex]::Escape($pattern).Replace("\*", "[^/]*").Replace("\?", "[^/]") + "$"
  return [regex]::IsMatch($literal, $regex, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

function Test-LaneAdmissionPathOverlap([string]$Left, [string]$Right) {
  $leftPath = ConvertTo-LaneAdmissionPath $Left
  $rightPath = ConvertTo-LaneAdmissionPath $Right
  $leftSegments = @($leftPath.segments)
  $rightSegments = @($rightPath.segments)
  $leftLength = if ($leftPath.recursive) { $leftSegments.Count - 1 } else { $leftSegments.Count }
  $rightLength = if ($rightPath.recursive) { $rightSegments.Count - 1 } else { $rightSegments.Count }
  if ($leftLength -eq 0 -or $rightLength -eq 0) { return $true }
  $prefixLength = [Math]::Min($leftLength, $rightLength)
  for ($index = 0; $index -lt $prefixLength; $index++) {
    if (-not (Test-LaneAdmissionSegmentCompatibility $leftSegments[$index] $rightSegments[$index])) {
      return $false
    }
  }
  # Footprints conflict on equality and ancestor/descendant containment. This
  # also makes base/** overlap base, descendants, and every strict ancestor,
  # symmetrically, without relying on operand order.
  return $true
}

function Get-LaneAdmissionOverlaps([object[]]$Left, [object[]]$Right) {
  $matches = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($leftPath in @($Left)) {
    foreach ($rightPath in @($Right)) {
      if (Test-LaneAdmissionPathOverlap ([string]$leftPath) ([string]$rightPath)) {
        $leftNormalized = (ConvertTo-LaneAdmissionPath $leftPath).value
        $rightNormalized = (ConvertTo-LaneAdmissionPath $rightPath).value
        [void]$matches.Add("$leftNormalized|$rightNormalized")
      }
    }
  }
  return @($matches | Sort-Object)
}

function Assert-LaneCoverageShape([object]$Coverage, [string]$At) {
  Assert-LaneExactKeys $Coverage @(
    "status","pages","collected","total","providerCap","hasNextPage","unexamined",
    "revision","finalRevision","revisionStable"
  ) @() $At
  if ([string](Get-LaneProperty $Coverage "status") -cnotin @("complete","unknown")) {
    throw "$At.status is invalid"
  }
  foreach ($field in @("pages","collected","total","providerCap","unexamined")) {
    Assert-LaneCount (Get-LaneProperty $Coverage $field) "$At.$field"
  }
  foreach ($field in @("hasNextPage","revisionStable")) {
    if ((Get-LaneProperty $Coverage $field) -isnot [bool]) { throw "$At.$field must be boolean" }
  }
  Assert-LaneIdentifier (Get-LaneProperty $Coverage "revision") "$At.revision"
  Assert-LaneIdentifier (Get-LaneProperty $Coverage "finalRevision") "$At.finalRevision"
}

function Test-LaneCoverageComplete([object]$Coverage) {
  $status = [string](Get-LaneProperty $Coverage "status")
  $pages = [int](Get-LaneProperty $Coverage "pages")
  $collected = [int](Get-LaneProperty $Coverage "collected")
  $total = [int](Get-LaneProperty $Coverage "total")
  $cap = [int](Get-LaneProperty $Coverage "providerCap")
  $unexamined = [int](Get-LaneProperty $Coverage "unexamined")
  $revision = [string](Get-LaneProperty $Coverage "revision")
  $finalRevision = [string](Get-LaneProperty $Coverage "finalRevision")
  return $status -ceq "complete" -and
    (($total -eq 0 -and $pages -ge 0) -or ($total -gt 0 -and $pages -gt 0)) -and
    $collected -eq $total -and $total -le $cap -and $unexamined -eq 0 -and
    -not [bool](Get-LaneProperty $Coverage "hasNextPage") -and
    [bool](Get-LaneProperty $Coverage "revisionStable") -and
    $revision -ceq $finalRevision
}

function Assert-LaneAdmissionCollectedInputContract([object]$InputObject) {
  Assert-LaneExactKeys $InputObject @(
    "schemaVersion","snapshotId","cycle","authorityRows","candidates","activeLanes",
    "capacity","overrides","provenance"
  ) @() "collectedInput"
  if ([string]$InputObject.schemaVersion -cne "lane-admission-collected-input/v1") {
    throw "collectedInput.schemaVersion invalid"
  }
  Assert-LaneIdentifier $InputObject.snapshotId "collectedInput.snapshotId"

  Assert-LaneExactKeys $InputObject.cycle @("cycleId","collectedAt","finalRebindAt") @() "cycle"
  Assert-LaneIdentifier $InputObject.cycle.cycleId "cycle.cycleId"
  $collectedAt = ConvertTo-LaneInstant $InputObject.cycle.collectedAt "cycle.collectedAt"
  $finalRebindAt = ConvertTo-LaneInstant $InputObject.cycle.finalRebindAt "cycle.finalRebindAt"
  if ($finalRebindAt -lt $collectedAt) { throw "cycle final rebind precedes collection" }

  foreach ($row in @($InputObject.authorityRows)) {
    Assert-LaneExactKeys $row @("set","coverage") @() "authorityRows[]"
    if ([string]$row.set -cnotin $script:LaneAdmissionAuthoritySets) {
      throw "authorityRows[].set invalid"
    }
    Assert-LaneCoverageShape $row.coverage "authorityRows[$($row.set)].coverage"
  }

  $candidateNumbers = [Collections.Generic.HashSet[int]]::new()
  foreach ($candidate in @($InputObject.candidates)) {
    Assert-LaneExactKeys $candidate @(
      "number","nodeId","revision","finalRevision","state","issueType","milestone",
      "readiness","priority","dispatchRank","projectItemCount","dependencies",
      "footprint","operatorLabel","lifecycle","authority"
    ) @() "candidates[]"
    Assert-LaneCount $candidate.number "candidates[].number"
    if ([int]$candidate.number -lt 1) { throw "candidate number invalid" }
    Assert-LaneIdentifier $candidate.nodeId "candidates[].nodeId"
    Assert-LaneIdentifier $candidate.revision "candidates[].revision"
    Assert-LaneIdentifier $candidate.finalRevision "candidates[].finalRevision"
    if ([string]$candidate.state -cnotin @("open","closed")) { throw "candidate state invalid" }
    if ([string]$candidate.issueType -cnotin @("Slice","Epic","Tracking","Decision","Incident")) {
      throw "candidate issueType invalid"
    }
    if (-not $candidateNumbers.Add([int]$candidate.number)) {
      # Duplicate identity is a semantic global defect, but each row must still
      # be recursively well-formed.
    }

    Assert-LaneExactKeys $candidate.milestone @(
      "nodeId","number","state","revision","finalRevision"
    ) @() "candidates[].milestone"
    Assert-LaneIdentifier $candidate.milestone.nodeId "candidate.milestone.nodeId"
    Assert-LaneCount $candidate.milestone.number "candidate.milestone.number"
    if ([int]$candidate.milestone.number -lt 1) { throw "candidate.milestone.number invalid" }
    if ([string]$candidate.milestone.state -cnotin @("open","closed")) {
      throw "candidate.milestone.state invalid"
    }
    Assert-LaneIdentifier $candidate.milestone.revision "candidate.milestone.revision"
    Assert-LaneIdentifier $candidate.milestone.finalRevision "candidate.milestone.finalRevision"

    Assert-LaneExactKeys $candidate.readiness @(
      "status","subjectRevision","authorityComplete","revisionStable","checkerSha"
    ) @() "candidates[].readiness"
    if ([string]$candidate.readiness.status -cnotin @("ready","not-ready","unknown")) {
      throw "candidate.readiness.status invalid"
    }
    Assert-LaneIdentifier $candidate.readiness.subjectRevision "candidate.readiness.subjectRevision"
    foreach ($field in @("authorityComplete","revisionStable")) {
      if ((Get-LaneProperty $candidate.readiness $field) -isnot [bool]) {
        throw "candidate.readiness.$field must be boolean"
      }
    }
    if ([string]$candidate.readiness.checkerSha -cnotmatch '^[0-9a-f]{40}$') {
      throw "candidate.readiness.checkerSha invalid"
    }

    if ([string]$candidate.priority -cnotin @("p0","p1","p2","p3")) {
      throw "candidate.priority invalid"
    }
    if ($null -ne $candidate.dispatchRank) {
      Assert-LaneCount $candidate.dispatchRank "candidate.dispatchRank"
    }
    Assert-LaneCount $candidate.projectItemCount "candidate.projectItemCount"

    foreach ($dependency in @($candidate.dependencies)) {
      Assert-LaneExactKeys $dependency @(
        "number","state","revision","finalRevision"
      ) @() "candidates[].dependencies[]"
      Assert-LaneCount $dependency.number "dependency.number"
      if ([int]$dependency.number -lt 1) { throw "dependency.number invalid" }
      if ([string]$dependency.state -cnotin @("open","closed")) { throw "dependency.state invalid" }
      Assert-LaneIdentifier $dependency.revision "dependency.revision"
      Assert-LaneIdentifier $dependency.finalRevision "dependency.finalRevision"
    }

    Assert-LaneExactKeys $candidate.footprint @(
      "declared","observed","complete","grammarStatus"
    ) @() "candidates[].footprint"
    if ($candidate.footprint.complete -isnot [bool]) { throw "candidate.footprint.complete must be boolean" }
    if ([string]$candidate.footprint.grammarStatus -cnotin @("handled","indeterminate")) {
      throw "candidate.footprint.grammarStatus invalid"
    }
    foreach ($token in @($candidate.footprint.declared) + @($candidate.footprint.observed)) {
      if ($token -isnot [string]) { throw "candidate footprint token must be string" }
    }
    if ($candidate.operatorLabel -isnot [bool]) { throw "candidate.operatorLabel must be boolean" }
    Assert-LaneExactKeys $candidate.lifecycle @("refined","executable") @() "candidate.lifecycle"
    if ($candidate.lifecycle.refined -isnot [bool] -or $candidate.lifecycle.executable -isnot [bool]) {
      throw "candidate lifecycle fields must be boolean"
    }
    Assert-LaneExactKeys $candidate.authority @("isolated","coverage") @() "candidate.authority"
    if ($candidate.authority.isolated -isnot [bool]) { throw "candidate.authority.isolated must be boolean" }
    Assert-LaneCoverageShape $candidate.authority.coverage "candidate.authority.coverage"
  }

  foreach ($lane in @($InputObject.activeLanes)) {
    Assert-LaneExactKeys $lane @(
      "owner","revision","finalRevision","declaredFootprint","observedFootprint","complete"
    ) @() "activeLanes[]"
    Assert-LaneIdentifier $lane.owner "activeLanes[].owner"
    Assert-LaneIdentifier $lane.revision "activeLanes[].revision"
    Assert-LaneIdentifier $lane.finalRevision "activeLanes[].finalRevision"
    if ($lane.complete -isnot [bool]) { throw "activeLanes[].complete must be boolean" }
    foreach ($token in @($lane.declaredFootprint) + @($lane.observedFootprint)) {
      if ($token -isnot [string]) { throw "active lane footprint token must be string" }
    }
  }

  Assert-LaneExactKeys $InputObject.capacity @(
    "decision","queueAndDeployHealthy","hostCapacity","ownership"
  ) @() "capacity"
  if ([string]$InputObject.capacity.decision -cnotin @("option-1","unknown")) {
    throw "capacity.decision invalid"
  }
  if ($null -ne $InputObject.capacity.queueAndDeployHealthy -and
      $InputObject.capacity.queueAndDeployHealthy -isnot [bool]) {
    throw "capacity.queueAndDeployHealthy must be boolean or null"
  }
  Assert-LaneExactKeys $InputObject.capacity.hostCapacity @(
    "memorySafe","heavyVerifierSafe","complete","authorityId","capturedAt","validUntil",
    "revision","finalRevision"
  ) @() "capacity.hostCapacity"
  foreach ($field in @("memorySafe","heavyVerifierSafe")) {
    $value = Get-LaneProperty $InputObject.capacity.hostCapacity $field
    if ($null -ne $value -and $value -isnot [bool]) {
      throw "capacity.hostCapacity.$field must be boolean or null"
    }
  }
  if ($InputObject.capacity.hostCapacity.complete -isnot [bool]) {
    throw "capacity.hostCapacity.complete must be boolean"
  }
  Assert-LaneIdentifier $InputObject.capacity.hostCapacity.authorityId "capacity.hostCapacity.authorityId"
  [void](ConvertTo-LaneInstant $InputObject.capacity.hostCapacity.capturedAt "capacity.hostCapacity.capturedAt")
  [void](ConvertTo-LaneInstant $InputObject.capacity.hostCapacity.validUntil "capacity.hostCapacity.validUntil")
  Assert-LaneIdentifier $InputObject.capacity.hostCapacity.revision "capacity.hostCapacity.revision"
  Assert-LaneIdentifier $InputObject.capacity.hostCapacity.finalRevision "capacity.hostCapacity.finalRevision"

  Assert-LaneExactKeys $InputObject.capacity.ownership @(
    "safe","complete","currentPool","active","authorizedMax","revision","finalRevision"
  ) @() "capacity.ownership"
  if ($null -ne $InputObject.capacity.ownership.safe -and
      $InputObject.capacity.ownership.safe -isnot [bool]) {
    throw "capacity.ownership.safe must be boolean or null"
  }
  if ($InputObject.capacity.ownership.complete -isnot [bool]) {
    throw "capacity.ownership.complete must be boolean"
  }
  foreach ($field in @("currentPool","active","authorizedMax")) {
    Assert-LaneCount (Get-LaneProperty $InputObject.capacity.ownership $field) "capacity.ownership.$field"
  }
  Assert-LaneIdentifier $InputObject.capacity.ownership.revision "capacity.ownership.revision"
  Assert-LaneIdentifier $InputObject.capacity.ownership.finalRevision "capacity.ownership.finalRevision"

  foreach ($override in @($InputObject.overrides)) {
    Assert-LaneExactKeys $override @(
      "who","fact","reason","expiresAt","receiptId"
    ) @() "overrides[]"
    Assert-LaneIdentifier $override.who "override.who"
    Assert-LaneIdentifier $override.fact "override.fact"
    if ($override.reason -isnot [string] -or $override.reason.Length -lt 1 -or $override.reason.Length -gt 512) {
      throw "override.reason invalid"
    }
    [void](ConvertTo-LaneInstant $override.expiresAt "override.expiresAt")
    Assert-LaneIdentifier $override.receiptId "override.receiptId"
  }

  Assert-LaneExactKeys $InputObject.provenance @(
    "collector","collectorVersion","repository","subjectHead"
  ) @() "provenance"
  foreach ($field in @("collector","collectorVersion","repository","subjectHead")) {
    Assert-LaneIdentifier (Get-LaneProperty $InputObject.provenance $field) "provenance.$field"
  }
  return $true
}

function Add-LaneReason([Collections.Generic.HashSet[string]]$Set, [string]$Reason) {
  if ($Reason -cnotin $script:LaneAdmissionReasonCodes) { throw "unknown admission reason '$Reason'" }
  [void]$Set.Add($Reason)
}

function ConvertTo-LaneAdmission([object]$InputObject) {
  [void](Assert-LaneAdmissionCollectedInputContract $InputObject)
  $rootReasons = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  $globalClosed = $false
  $coverageOutput = @()
  foreach ($setName in $script:LaneAdmissionAuthoritySets) {
    $matches = @($InputObject.authorityRows | Where-Object { [string]$_.set -ceq $setName })
    if ($matches.Count -eq 0) {
      Add-LaneReason $rootReasons "GLOBAL_AUTHORITY_MISSING"
      $globalClosed = $true
      continue
    }
    if ($matches.Count -ne 1) {
      Add-LaneReason $rootReasons "GLOBAL_AUTHORITY_DUPLICATE"
      $globalClosed = $true
      continue
    }
    $coverage = $matches[0].coverage
    $coverageOutput += [ordered]@{
      set = $setName
      status = [string]$coverage.status
      pages = [int]$coverage.pages
      collected = [int]$coverage.collected
      total = [int]$coverage.total
      providerCap = [int]$coverage.providerCap
      hasNextPage = [bool]$coverage.hasNextPage
      unexamined = [int]$coverage.unexamined
      revision = [string]$coverage.revision
      finalRevision = [string]$coverage.finalRevision
      revisionStable = [bool]$coverage.revisionStable
    }
    if ([int]$coverage.total -gt [int]$coverage.providerCap -or [bool]$coverage.hasNextPage) {
      Add-LaneReason $rootReasons "GLOBAL_AUTHORITY_CAP_MISMATCH"
      $globalClosed = $true
    }
    if ([string]$coverage.revision -cne [string]$coverage.finalRevision -or
        -not [bool]$coverage.revisionStable) {
      Add-LaneReason $rootReasons "GLOBAL_AUTHORITY_MOVED"
      $globalClosed = $true
    }
    if (-not (Test-LaneCoverageComplete $coverage)) {
      Add-LaneReason $rootReasons "GLOBAL_AUTHORITY_INCOMPLETE"
      $globalClosed = $true
    }
  }
  $candidateAuthority = @($InputObject.authorityRows | Where-Object {
    [string]$_.set -ceq "candidate-issues"
  })
  if ($candidateAuthority.Count -eq 1 -and
      [int]$candidateAuthority[0].coverage.collected -ne @($InputObject.candidates).Count) {
    Add-LaneReason $rootReasons "GLOBAL_AUTHORITY_INCOMPLETE"
    $globalClosed = $true
  }
  $activeLaneAuthority = @($InputObject.authorityRows | Where-Object {
    [string]$_.set -ceq "active-lanes"
  })
  if ($activeLaneAuthority.Count -eq 1 -and
      [int]$activeLaneAuthority[0].coverage.collected -ne @($InputObject.activeLanes).Count) {
    Add-LaneReason $rootReasons "GLOBAL_AUTHORITY_INCOMPLETE"
    $globalClosed = $true
  }

  $numberCounts = @{}
  $rankCounts = @{}
  foreach ($candidate in @($InputObject.candidates)) {
    $numberKey = [string][int]$candidate.number
    $numberCounts[$numberKey] = 1 + [int]($numberCounts[$numberKey])
    if ($null -ne $candidate.dispatchRank) {
      $rankKey = [string][int]$candidate.dispatchRank
      $rankCounts[$rankKey] = 1 + [int]($rankCounts[$rankKey])
    }
  }
  if (@($numberCounts.Values | Where-Object { $_ -gt 1 }).Count -gt 0 -or
      @($rankCounts.Values | Where-Object { $_ -gt 1 }).Count -gt 0) {
    Add-LaneReason $rootReasons "ORDERING_UNKNOWN"
    $globalClosed = $true
  }

  $normalizedActive = @()
  foreach ($lane in @($InputObject.activeLanes)) {
    try {
      if (-not [bool]$lane.complete -or [string]$lane.revision -cne [string]$lane.finalRevision) {
        throw "active lane authority incomplete"
      }
      $declaredPaths = @()
      $observedPaths = @()
      foreach ($token in @($lane.declaredFootprint)) {
        $declaredPaths += (ConvertTo-LaneAdmissionPath $token).value
      }
      foreach ($token in @($lane.observedFootprint)) {
        $observedPaths += (ConvertTo-LaneAdmissionPath $token).value
      }
      $normalizedActive += [ordered]@{
        owner = [string]$lane.owner
        revision = [string]$lane.finalRevision
        footprint = [ordered]@{
          declared = @($declaredPaths | Sort-Object -Unique)
          observed = @($observedPaths | Sort-Object -Unique)
          combined = @(@($declaredPaths) + @($observedPaths) | Sort-Object -Unique)
        }
      }
    } catch {
      Add-LaneReason $rootReasons "ACTIVE_LANE_AUTHORITY_UNKNOWN"
      $globalClosed = $true
    }
  }

  $eligible = @()
  $exclusions = @()
  $candidateByNumber = @{}
  foreach ($candidate in @($InputObject.candidates)) {
    $candidateByNumber[[string][int]$candidate.number] = $candidate
  }
  $cycleCandidates = [Collections.Generic.HashSet[int]]::new()
  foreach ($candidate in @($InputObject.candidates)) {
    $origin = [int]$candidate.number
    $pending = [Collections.Generic.Stack[int]]::new()
    $visited = [Collections.Generic.HashSet[int]]::new()
    foreach ($dependency in @($candidate.dependencies)) {
      if ($candidateByNumber.ContainsKey([string][int]$dependency.number)) {
        $pending.Push([int]$dependency.number)
      }
    }
    while ($pending.Count -gt 0) {
      $current = $pending.Pop()
      if ($current -eq $origin) {
        [void]$cycleCandidates.Add($origin)
        break
      }
      if (-not $visited.Add($current)) { continue }
      foreach ($dependency in @($candidateByNumber[[string]$current].dependencies)) {
        if ($candidateByNumber.ContainsKey([string][int]$dependency.number)) {
          $pending.Push([int]$dependency.number)
        }
      }
    }
  }
  if (-not $globalClosed) {
    foreach ($candidate in @($InputObject.candidates | Sort-Object { [int]$_.number })) {
      $candidateReasons = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
      $coverage = $candidate.authority.coverage
      if (-not (Test-LaneCoverageComplete $coverage)) {
        if (-not [bool]$candidate.authority.isolated) {
          Add-LaneReason $rootReasons "GLOBAL_AUTHORITY_INCOMPLETE"
          $globalClosed = $true
          break
        }
        Add-LaneReason $candidateReasons "CANDIDATE_AUTHORITY_UNKNOWN"
      }
      if ([string]$candidate.revision -cne [string]$candidate.finalRevision -or
          [string]$coverage.revision -cne [string]$coverage.finalRevision) {
        Add-LaneReason $candidateReasons "CANDIDATE_AUTHORITY_MOVED"
      }
      if ([string]$candidate.readiness.status -cne "ready" -or
          -not [bool]$candidate.readiness.authorityComplete -or
          -not [bool]$candidate.readiness.revisionStable -or
          [string]$candidate.readiness.subjectRevision -cne [string]$candidate.finalRevision) {
        Add-LaneReason $candidateReasons "READINESS_UNKNOWN"
      }
      if ([string]$candidate.state -cne "open" -or [string]$candidate.issueType -cne "Slice" -or
          -not [bool]$candidate.lifecycle.refined -or -not [bool]$candidate.lifecycle.executable) {
        Add-LaneReason $candidateReasons "LIFECYCLE_INELIGIBLE"
      }
      if ([string]$candidate.milestone.state -cne "open" -or
          [string]$candidate.milestone.revision -cne [string]$candidate.milestone.finalRevision) {
        Add-LaneReason $candidateReasons "MILESTONE_UNKNOWN"
      }
      if ([int]$candidate.projectItemCount -ne 1) {
        Add-LaneReason $rootReasons "ORDERING_UNKNOWN"
        $globalClosed = $true
        break
      }
      foreach ($dependency in @($candidate.dependencies)) {
        if ([string]$dependency.revision -cne [string]$dependency.finalRevision) {
          Add-LaneReason $candidateReasons "CANDIDATE_AUTHORITY_MOVED"
        }
        if ([string]$dependency.state -ceq "open") {
          Add-LaneReason $candidateReasons "DEPENDENCY_BLOCKED"
        }
        if ([int]$dependency.number -eq [int]$candidate.number) {
          Add-LaneReason $candidateReasons "DEPENDENCY_CYCLE"
        }
        $dependencyCandidate = $candidateByNumber[[string][int]$dependency.number]
        if ($null -ne $dependencyCandidate -and
            ([string]$dependency.state -cne [string]$dependencyCandidate.state -or
             [string]$dependency.finalRevision -cne [string]$dependencyCandidate.finalRevision)) {
          Add-LaneReason $candidateReasons "CANDIDATE_AUTHORITY_MOVED"
        }
      }
      if ($cycleCandidates.Contains([int]$candidate.number)) {
        Add-LaneReason $candidateReasons "DEPENDENCY_CYCLE"
      }
      $declaredPaths = @()
      $observedPaths = @()
      try {
        if (-not [bool]$candidate.footprint.complete -or
            [string]$candidate.footprint.grammarStatus -cne "handled") {
          throw "candidate footprint incomplete"
        }
        foreach ($token in @($candidate.footprint.declared)) {
          $declaredPaths += (ConvertTo-LaneAdmissionPath $token).value
        }
        foreach ($token in @($candidate.footprint.observed)) {
          $observedPaths += (ConvertTo-LaneAdmissionPath $token).value
        }
      } catch {
        Add-LaneReason $candidateReasons "CANDIDATE_PATH_UNKNOWN"
      }

      if ($candidateReasons.Count -gt 0) {
        $exclusions += [ordered]@{
          candidate = [int]$candidate.number
          reasonCodes = @($candidateReasons | Sort-Object)
        }
        continue
      }
      $eligible += [ordered]@{
        number = [int]$candidate.number
        nodeId = [string]$candidate.nodeId
        revision = [string]$candidate.finalRevision
        state = [string]$candidate.state
        issueType = [string]$candidate.issueType
        milestone = [ordered]@{
          nodeId = [string]$candidate.milestone.nodeId
          number = [int]$candidate.milestone.number
          state = [string]$candidate.milestone.state
          revision = [string]$candidate.milestone.finalRevision
        }
        readiness = [ordered]@{
          status = [string]$candidate.readiness.status
          subjectRevision = [string]$candidate.readiness.subjectRevision
          authorityComplete = [bool]$candidate.readiness.authorityComplete
          revisionStable = [bool]$candidate.readiness.revisionStable
          checkerSha = [string]$candidate.readiness.checkerSha
        }
        priority = [string]$candidate.priority
        dispatchRank = if ($null -eq $candidate.dispatchRank) { $null } else { [int]$candidate.dispatchRank }
        dependencies = @($candidate.dependencies | ForEach-Object {
          [ordered]@{ number = [int]$_.number; state = [string]$_.state; revision = [string]$_.finalRevision }
        })
        topologyOrder = 0
        operatorLabel = [bool]$candidate.operatorLabel
        footprint = [ordered]@{
          declared = @($declaredPaths | Sort-Object -Unique)
          observed = @($observedPaths | Sort-Object -Unique)
          combined = @(@($declaredPaths) + @($observedPaths) | Sort-Object -Unique)
        }
        lifecycle = [ordered]@{ refined = $true; executable = $true }
      }
    }
  }

  if ($globalClosed) {
    $eligible = @()
    $exclusions = @()
  }

  $priorityMap = @{ p0 = 0; p1 = 1; p2 = 2; p3 = 3 }
  $topology = @($eligible | Sort-Object { [int]$_.number })
  for ($index = 0; $index -lt $topology.Count; $index++) {
    $topology[$index].topologyOrder = $index
  }
  $ordered = @($eligible | Sort-Object `
    @{ Expression = { if ($null -eq $_.dispatchRank) { 1 } else { 0 } } }, `
    @{ Expression = { if ($null -eq $_.dispatchRank) { [int]::MaxValue } else { [int]$_.dispatchRank } } }, `
    @{ Expression = { [int]$priorityMap[[string]$_.priority] } }, `
    @{ Expression = { [int]$_.number } })
  $orderingFacts = @($ordered | ForEach-Object {
    [ordered]@{
      candidate = [int]$_.number
      dispatchTier = if ($null -eq $_.dispatchRank) { "unranked" } else { "ranked" }
      dispatchRank = $_.dispatchRank
      priority = [string]$_.priority
      topologyOrder = [int]$_.topologyOrder
      issueNumber = [int]$_.number
    }
  })

  $candidateEdges = @()
  for ($leftIndex = 0; $leftIndex -lt $eligible.Count; $leftIndex++) {
    for ($rightIndex = $leftIndex + 1; $rightIndex -lt $eligible.Count; $rightIndex++) {
      $overlaps = @(Get-LaneAdmissionOverlaps $eligible[$leftIndex].footprint.combined $eligible[$rightIndex].footprint.combined)
      if ($overlaps.Count -gt 0) {
        $candidateEdges += [ordered]@{
          left = [int]$eligible[$leftIndex].number
          right = [int]$eligible[$rightIndex].number
          paths = @($overlaps)
        }
      }
    }
  }
  $activeLaneEdges = @()
  foreach ($candidate in @($eligible)) {
    foreach ($lane in @($normalizedActive)) {
      $overlaps = @(Get-LaneAdmissionOverlaps $candidate.footprint.combined $lane.footprint.combined)
      if ($overlaps.Count -gt 0) {
        $activeLaneEdges += [ordered]@{
          candidate = [int]$candidate.number
          owner = [string]$lane.owner
          paths = @($overlaps)
        }
      }
    }
  }

  $overrideRows = @($InputObject.overrides | ForEach-Object {
    [ordered]@{
      who = [string]$_.who
      fact = [string]$_.fact
      reason = [string]$_.reason
      expiresAt = Format-LaneInstant $_.expiresAt "override.expiresAt"
      receiptId = [string]$_.receiptId
      accepted = $false
      reasonCode = "OVERRIDE_CANNOT_SATISFY_UNKNOWN"
    }
  })
  if ($overrideRows.Count -gt 0) { Add-LaneReason $rootReasons "OVERRIDE_CANNOT_SATISFY_UNKNOWN" }

  $hostCapacity = $InputObject.capacity.hostCapacity
  $ownership = $InputObject.capacity.ownership
  $result = [ordered]@{
    schemaVersion = "lane-admission/v1"
    receiptId = [string]$InputObject.snapshotId
    cycleId = [string]$InputObject.cycle.cycleId
    generatedAt = Format-LaneInstant $InputObject.cycle.finalRebindAt "cycle.finalRebindAt"
    status = if ($globalClosed) { "closed" } else { "complete" }
    reasonCodes = @($rootReasons | Sort-Object)
    coverage = @($coverageOutput | Sort-Object { [string]$_.set })
    structurallyEligibleCandidates = @($eligible | Sort-Object { [int]$_.number })
    activeLaneFacts = @($normalizedActive | Sort-Object { [string]$_.owner })
    exclusions = @($exclusions | Sort-Object { [int]$_.candidate })
    orderingFacts = @($orderingFacts)
    conflictGraph = [ordered]@{
      candidateEdges = @($candidateEdges | Sort-Object `
        @{ Expression = { [int]$_.left } }, @{ Expression = { [int]$_.right } })
      activeLaneEdges = @($activeLaneEdges | Sort-Object `
        @{ Expression = { [int]$_.candidate } }, @{ Expression = { [string]$_.owner } })
    }
    capacityFacts = [ordered]@{
      decision = [string]$InputObject.capacity.decision
      queueAndDeployHealthy = $InputObject.capacity.queueAndDeployHealthy
      hostCapacity = [ordered]@{
        memorySafe = $hostCapacity.memorySafe
        heavyVerifierSafe = $hostCapacity.heavyVerifierSafe
        complete = [bool]$hostCapacity.complete
        authorityId = [string]$hostCapacity.authorityId
        capturedAt = Format-LaneInstant $hostCapacity.capturedAt "capacity.hostCapacity.capturedAt"
        validUntil = Format-LaneInstant $hostCapacity.validUntil "capacity.hostCapacity.validUntil"
        revision = [string]$hostCapacity.revision
        finalRevision = [string]$hostCapacity.finalRevision
      }
      ownership = [ordered]@{
        safe = $ownership.safe
        complete = [bool]$ownership.complete
        currentPool = [int]$ownership.currentPool
        active = [int]$ownership.active
        authorizedMax = [int]$ownership.authorizedMax
        revision = [string]$ownership.revision
        finalRevision = [string]$ownership.finalRevision
      }
    }
    overrides = @($overrideRows)
    provenance = [ordered]@{
      inputSchema = "lane-admission-collected-input/v1"
      collector = [string]$InputObject.provenance.collector
      collectorVersion = [string]$InputObject.provenance.collectorVersion
      repository = [string]$InputObject.provenance.repository
      subjectHead = [string]$InputObject.provenance.subjectHead
      collectedAt = Format-LaneInstant $InputObject.cycle.collectedAt "cycle.collectedAt"
      finalRebindAt = Format-LaneInstant $InputObject.cycle.finalRebindAt "cycle.finalRebindAt"
    }
  }
  [void](Assert-LaneAdmissionContract $result)
  return $result
}

function Assert-LaneAdmissionContract([object]$Result) {
  Assert-LaneExactKeys $Result @(
    "schemaVersion","receiptId","cycleId","generatedAt","status","reasonCodes",
    "coverage","structurallyEligibleCandidates","activeLaneFacts","exclusions","orderingFacts",
    "conflictGraph","capacityFacts","overrides","provenance"
  ) @() "receipt"
  if ([string]$Result.schemaVersion -cne "lane-admission/v1") { throw "receipt schemaVersion invalid" }
  Assert-LaneIdentifier $Result.receiptId "receipt.receiptId"
  Assert-LaneIdentifier $Result.cycleId "receipt.cycleId"
  [void](ConvertTo-LaneInstant $Result.generatedAt "receipt.generatedAt")
  if ([string]$Result.status -cnotin @("complete","closed")) { throw "receipt.status invalid" }
  foreach ($reason in @($Result.reasonCodes)) {
    if ([string]$reason -cnotin $script:LaneAdmissionReasonCodes) { throw "receipt reason invalid" }
  }
  Assert-LaneUnique @($Result.reasonCodes) "receipt.reasonCodes"
  foreach ($coverage in @($Result.coverage)) {
    Assert-LaneExactKeys $coverage @(
      "set","status","pages","collected","total","providerCap","hasNextPage",
      "unexamined","revision","finalRevision","revisionStable"
    ) @() "receipt.coverage[]"
    if ([string]$coverage.set -cnotin $script:LaneAdmissionAuthoritySets) { throw "receipt coverage set invalid" }
    $coverageShape = [ordered]@{
      status = $coverage.status
      pages = $coverage.pages
      collected = $coverage.collected
      total = $coverage.total
      providerCap = $coverage.providerCap
      hasNextPage = $coverage.hasNextPage
      unexamined = $coverage.unexamined
      revision = $coverage.revision
      finalRevision = $coverage.finalRevision
      revisionStable = $coverage.revisionStable
    }
    Assert-LaneCoverageShape $coverageShape "receipt.coverage[$($coverage.set)]"
  }
  Assert-LaneUnique @($Result.coverage.set) "receipt.coverage sets"
  $candidateIdentities = @()
  foreach ($candidate in @($Result.structurallyEligibleCandidates)) {
    Assert-LaneExactKeys $candidate @(
      "number","nodeId","revision","state","issueType","milestone","readiness","priority",
      "dispatchRank","dependencies","topologyOrder","operatorLabel","footprint","lifecycle"
    ) @() "receipt.structurallyEligibleCandidates[]"
    Assert-LaneExactKeys $candidate.milestone @("nodeId","number","state","revision") @() "receipt.candidate.milestone"
    Assert-LaneExactKeys $candidate.readiness @(
      "status","subjectRevision","authorityComplete","revisionStable","checkerSha"
    ) @() "receipt.candidate.readiness"
    Assert-LaneExactKeys $candidate.footprint @("declared","observed","combined") @() "receipt.candidate.footprint"
    Assert-LaneExactKeys $candidate.lifecycle @("refined","executable") @() "receipt.candidate.lifecycle"
    Assert-LaneCount $candidate.number "receipt.candidate.number"
    if ([int]$candidate.number -lt 1) { throw "receipt candidate number invalid" }
    Assert-LaneIdentifier $candidate.nodeId "receipt.candidate.nodeId"
    Assert-LaneIdentifier $candidate.revision "receipt.candidate.revision"
    if ([string]$candidate.state -cne "open" -or [string]$candidate.issueType -cne "Slice") {
      throw "receipt candidate lifecycle identity invalid"
    }
    Assert-LaneIdentifier $candidate.milestone.nodeId "receipt.candidate.milestone.nodeId"
    Assert-LaneCount $candidate.milestone.number "receipt.candidate.milestone.number"
    if ([int]$candidate.milestone.number -lt 1) { throw "receipt candidate milestone number invalid" }
    Assert-LaneIdentifier $candidate.milestone.revision "receipt.candidate.milestone.revision"
    if ([string]$candidate.milestone.state -cne "open") { throw "receipt candidate milestone state invalid" }
    if ([string]$candidate.readiness.status -cne "ready" -or
        -not [bool]$candidate.readiness.authorityComplete -or
        -not [bool]$candidate.readiness.revisionStable -or
        [string]$candidate.readiness.subjectRevision -cne [string]$candidate.revision -or
        [string]$candidate.readiness.checkerSha -cnotmatch '^[0-9a-f]{40}$') {
      throw "receipt candidate readiness invalid"
    }
    if ([string]$candidate.priority -cnotin @("p0","p1","p2","p3")) { throw "receipt candidate priority invalid" }
    if ($null -ne $candidate.dispatchRank) {
      Assert-LaneCount $candidate.dispatchRank "receipt.candidate.dispatchRank"
    }
    Assert-LaneCount $candidate.topologyOrder "receipt.candidate.topologyOrder"
    if ($candidate.operatorLabel -isnot [bool]) { throw "receipt candidate operatorLabel invalid" }
    if (-not [bool]$candidate.lifecycle.refined -or -not [bool]$candidate.lifecycle.executable) {
      throw "receipt candidate lifecycle invalid"
    }
    foreach ($field in @("declared","observed","combined")) {
      foreach ($token in @((Get-LaneProperty $candidate.footprint $field))) {
        $normalized = ConvertTo-LaneAdmissionPath $token
        if ([string]$normalized.value -cne [string]$token) {
          throw "receipt candidate footprint is not canonical"
        }
      }
      Assert-LaneUnique @((Get-LaneProperty $candidate.footprint $field)) "receipt.candidate.footprint.$field"
    }
    $expectedCombined = @(@($candidate.footprint.declared) + @($candidate.footprint.observed) | Sort-Object -Unique)
    if ((@($expectedCombined) -join "|") -cne (@($candidate.footprint.combined) -join "|")) {
      throw "receipt candidate combined footprint is incomplete"
    }
    $candidateIdentities += [string][int]$candidate.number
    foreach ($dependency in @($candidate.dependencies)) {
      Assert-LaneExactKeys $dependency @("number","state","revision") @() "receipt.candidate.dependencies[]"
      Assert-LaneCount $dependency.number "receipt.candidate.dependency.number"
      if ([int]$dependency.number -lt 1) { throw "receipt dependency number invalid" }
      if ([string]$dependency.state -cnotin @("open","closed")) { throw "receipt dependency state invalid" }
      Assert-LaneIdentifier $dependency.revision "receipt.candidate.dependency.revision"
    }
  }
  Assert-LaneUnique $candidateIdentities "receipt candidate identities"
  $activeOwners = @()
  foreach ($lane in @($Result.activeLaneFacts)) {
    Assert-LaneExactKeys $lane @("owner","revision","footprint") @() "receipt.activeLaneFacts[]"
    Assert-LaneIdentifier $lane.owner "receipt.activeLaneFacts[].owner"
    Assert-LaneIdentifier $lane.revision "receipt.activeLaneFacts[].revision"
    Assert-LaneExactKeys $lane.footprint @("declared","observed","combined") @() "receipt.activeLaneFacts[].footprint"
    foreach ($field in @("declared","observed","combined")) {
      foreach ($token in @((Get-LaneProperty $lane.footprint $field))) {
        $normalized = ConvertTo-LaneAdmissionPath $token
        if ([string]$normalized.value -cne [string]$token) {
          throw "receipt active lane footprint is not canonical"
        }
      }
      Assert-LaneUnique @((Get-LaneProperty $lane.footprint $field)) "receipt.activeLaneFacts[].footprint.$field"
    }
    $expectedCombined = @(@($lane.footprint.declared) + @($lane.footprint.observed) | Sort-Object -Unique)
    if ((@($expectedCombined) -join "|") -cne (@($lane.footprint.combined) -join "|")) {
      throw "receipt active lane combined footprint is incomplete"
    }
    $activeOwners += [string]$lane.owner
  }
  Assert-LaneUnique $activeOwners "receipt active lane owners"
  foreach ($row in @($Result.exclusions)) {
    Assert-LaneExactKeys $row @("candidate","reasonCodes") @() "receipt.exclusions[]"
    foreach ($reason in @($row.reasonCodes)) {
      if ([string]$reason -cnotin $script:LaneAdmissionReasonCodes) { throw "exclusion reason invalid" }
    }
    Assert-LaneCount $row.candidate "receipt.exclusions[].candidate"
    Assert-LaneUnique @($row.reasonCodes) "receipt.exclusions[].reasonCodes"
  }
  Assert-LaneUnique @($Result.exclusions.candidate) "receipt exclusion identities"
  foreach ($row in @($Result.orderingFacts)) {
    Assert-LaneExactKeys $row @(
      "candidate","dispatchTier","dispatchRank","priority","topologyOrder","issueNumber"
    ) @() "receipt.orderingFacts[]"
    Assert-LaneCount $row.candidate "receipt.orderingFacts[].candidate"
    if ([string]$row.dispatchTier -cnotin @("ranked","unranked")) { throw "ordering dispatch tier invalid" }
    if ($null -ne $row.dispatchRank) { Assert-LaneCount $row.dispatchRank "ordering dispatchRank" }
    if ([string]$row.priority -cnotin @("p0","p1","p2","p3")) { throw "ordering priority invalid" }
    Assert-LaneCount $row.topologyOrder "ordering topologyOrder"
    Assert-LaneCount $row.issueNumber "ordering issueNumber"
    if ([int]$row.candidate -ne [int]$row.issueNumber) { throw "ordering issue identity mismatch" }
  }
  Assert-LaneUnique @($Result.orderingFacts.candidate) "receipt ordering identities"
  if ((@($Result.orderingFacts.candidate | Sort-Object) -join "|") -cne
      (@($Result.structurallyEligibleCandidates.number | Sort-Object) -join "|")) {
    throw "ordering facts are not complete over receipt candidates"
  }
  Assert-LaneExactKeys $Result.conflictGraph @("candidateEdges","activeLaneEdges") @() "receipt.conflictGraph"
  foreach ($edge in @($Result.conflictGraph.candidateEdges)) {
    Assert-LaneExactKeys $edge @("left","right","paths") @() "receipt.conflictGraph.candidateEdges[]"
    Assert-LaneCount $edge.left "candidate edge left"
    Assert-LaneCount $edge.right "candidate edge right"
    if ([int]$edge.left -eq [int]$edge.right -or
        [string][int]$edge.left -cnotin $candidateIdentities -or
        [string][int]$edge.right -cnotin $candidateIdentities) {
      throw "candidate edge identity invalid"
    }
    foreach ($pathPair in @($edge.paths)) {
      if ($pathPair -isnot [string] -or -not $pathPair.Contains("|")) { throw "candidate edge path pair invalid" }
    }
  }
  foreach ($edge in @($Result.conflictGraph.activeLaneEdges)) {
    Assert-LaneExactKeys $edge @("candidate","owner","paths") @() "receipt.conflictGraph.activeLaneEdges[]"
    Assert-LaneCount $edge.candidate "active edge candidate"
    Assert-LaneIdentifier $edge.owner "active edge owner"
    if ([string][int]$edge.candidate -cnotin $candidateIdentities -or [string]$edge.owner -cnotin $activeOwners) {
      throw "active edge identity unknown"
    }
    foreach ($pathPair in @($edge.paths)) {
      if ($pathPair -isnot [string] -or -not $pathPair.Contains("|")) { throw "active edge path pair invalid" }
    }
  }
  $expectedCandidateEdges = @()
  for ($leftIndex = 0; $leftIndex -lt @($Result.structurallyEligibleCandidates).Count; $leftIndex++) {
    for ($rightIndex = $leftIndex + 1; $rightIndex -lt @($Result.structurallyEligibleCandidates).Count; $rightIndex++) {
      $leftCandidate = @($Result.structurallyEligibleCandidates)[$leftIndex]
      $rightCandidate = @($Result.structurallyEligibleCandidates)[$rightIndex]
      $overlaps = @(Get-LaneAdmissionOverlaps $leftCandidate.footprint.combined $rightCandidate.footprint.combined)
      if ($overlaps.Count -gt 0) {
        $expectedCandidateEdges += "$([int]$leftCandidate.number)|$([int]$rightCandidate.number)|$($overlaps -join ',')"
      }
    }
  }
  $actualCandidateEdges = @($Result.conflictGraph.candidateEdges | ForEach-Object {
    "$([int]$_.left)|$([int]$_.right)|$(@($_.paths) -join ',')"
  })
  if ((@($expectedCandidateEdges | Sort-Object) -join ";") -cne
      (@($actualCandidateEdges | Sort-Object) -join ";")) {
    throw "receipt candidate conflict graph is incomplete"
  }
  $expectedActiveEdges = @()
  foreach ($candidate in @($Result.structurallyEligibleCandidates)) {
    foreach ($lane in @($Result.activeLaneFacts)) {
      $overlaps = @(Get-LaneAdmissionOverlaps $candidate.footprint.combined $lane.footprint.combined)
      if ($overlaps.Count -gt 0) {
        $expectedActiveEdges += "$([int]$candidate.number)|$([string]$lane.owner)|$($overlaps -join ',')"
      }
    }
  }
  $actualActiveEdges = @($Result.conflictGraph.activeLaneEdges | ForEach-Object {
    "$([int]$_.candidate)|$([string]$_.owner)|$(@($_.paths) -join ',')"
  })
  if ((@($expectedActiveEdges | Sort-Object) -join ";") -cne
      (@($actualActiveEdges | Sort-Object) -join ";")) {
    throw "receipt active-lane conflict graph is incomplete"
  }
  Assert-LaneExactKeys $Result.capacityFacts @(
    "decision","queueAndDeployHealthy","hostCapacity","ownership"
  ) @() "receipt.capacityFacts"
  Assert-LaneExactKeys $Result.capacityFacts.hostCapacity @(
    "memorySafe","heavyVerifierSafe","complete","authorityId","capturedAt","validUntil",
    "revision","finalRevision"
  ) @() "receipt.capacityFacts.hostCapacity"
  Assert-LaneExactKeys $Result.capacityFacts.ownership @(
    "safe","complete","currentPool","active","authorizedMax","revision","finalRevision"
  ) @() "receipt.capacityFacts.ownership"
  if ([string]$Result.capacityFacts.decision -cnotin @("option-1","unknown")) { throw "capacity decision invalid" }
  if ($null -ne $Result.capacityFacts.queueAndDeployHealthy -and
      $Result.capacityFacts.queueAndDeployHealthy -isnot [bool]) { throw "queue/deploy fact invalid" }
  foreach ($field in @("memorySafe","heavyVerifierSafe")) {
    $value = Get-LaneProperty $Result.capacityFacts.hostCapacity $field
    if ($null -ne $value -and $value -isnot [bool]) { throw "host capacity fact invalid" }
  }
  if ($Result.capacityFacts.hostCapacity.complete -isnot [bool]) { throw "host capacity completeness invalid" }
  Assert-LaneIdentifier $Result.capacityFacts.hostCapacity.authorityId "capacity authorityId"
  [void](ConvertTo-LaneInstant $Result.capacityFacts.hostCapacity.capturedAt "capacity capturedAt")
  [void](ConvertTo-LaneInstant $Result.capacityFacts.hostCapacity.validUntil "capacity validUntil")
  Assert-LaneIdentifier $Result.capacityFacts.hostCapacity.revision "capacity revision"
  Assert-LaneIdentifier $Result.capacityFacts.hostCapacity.finalRevision "capacity finalRevision"
  if ($null -ne $Result.capacityFacts.ownership.safe -and
      $Result.capacityFacts.ownership.safe -isnot [bool]) { throw "ownership safety invalid" }
  if ($Result.capacityFacts.ownership.complete -isnot [bool]) { throw "ownership completeness invalid" }
  foreach ($field in @("currentPool","active","authorizedMax")) {
    Assert-LaneCount (Get-LaneProperty $Result.capacityFacts.ownership $field) "ownership.$field"
  }
  Assert-LaneIdentifier $Result.capacityFacts.ownership.revision "ownership revision"
  Assert-LaneIdentifier $Result.capacityFacts.ownership.finalRevision "ownership finalRevision"
  foreach ($override in @($Result.overrides)) {
    Assert-LaneExactKeys $override @(
      "who","fact","reason","expiresAt","receiptId","accepted","reasonCode"
    ) @() "receipt.overrides[]"
  }
  Assert-LaneExactKeys $Result.provenance @(
    "inputSchema","collector","collectorVersion","repository","subjectHead",
    "collectedAt","finalRebindAt"
  ) @() "receipt.provenance"
  if ([string]$Result.provenance.inputSchema -cne "lane-admission-collected-input/v1") {
    throw "receipt provenance input schema invalid"
  }
  foreach ($field in @("collector","collectorVersion","repository","subjectHead")) {
    Assert-LaneIdentifier (Get-LaneProperty $Result.provenance $field) "receipt.provenance.$field"
  }
  [void](ConvertTo-LaneInstant $Result.provenance.collectedAt "receipt.provenance.collectedAt")
  [void](ConvertTo-LaneInstant $Result.provenance.finalRebindAt "receipt.provenance.finalRebindAt")
  return $true
}

if (-not $Library -and $MyInvocation.InvocationName -ne ".") {
  if (($InputPath -and $InputJson) -or (-not $InputPath -and -not $InputJson)) {
    throw "supply exactly one of -InputPath or -InputJson"
  }
  $json = if ($InputPath) { Get-Content -LiteralPath $InputPath -Raw } else { $InputJson }
  $inputObject = $json | ConvertFrom-Json
  $result = ConvertTo-LaneAdmission $inputObject
  $depth = 100
  if ($Compact) { $result | ConvertTo-Json -Depth $depth -Compress }
  else { $result | ConvertTo-Json -Depth $depth }
}
