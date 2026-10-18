<#
.SYNOPSIS
Canonical exact-head landing/enqueue preflight.

.DESCRIPTION
Report is the default and never mutates. Apply is the only path containing the
GraphQL enqueuePullRequest mutation. Apply re-reads every authority source and
requires an unchanged exact PR head immediately before that mutation.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$Pr,
  [ValidateSet("Report", "Apply")][string]$Action = "Report",
  [ValidatePattern("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")]
  [string]$Repository = "chase-sets/chase-sets",
  [string]$HistoryPath = (Join-Path $PSScriptRoot "dispatch-log.jsonl"),
  [ValidateRange(1, 1000000)][int]$MaxHistoryRows = 50000,
  [ValidateRange(1, [long]::MaxValue)][long]$MaxHistoryBytes = 33554432,
  # A hard operational fuse. Live dry runs set this even though Report is
  # already non-mutating. Apply with this switch always refuses.
  [switch]$MutationDisabled,
  # Controller releases do not use the product-PR P0 exception. Production
  # product callers omit this; controller-release callers set it explicitly.
  [switch]$ControllerCandidate,
  # Inert fixture seam. A fixture requires a named scenario and never falls
  # through to GitHub. It exercises this production preflight and reducer.
  [string]$AuthorityFixture,
  [string]$AuthorityScenario,
  [Parameter(DontShow)][string]$GhCommand = "gh"
)

$ErrorActionPreference = "Stop"
$preflightSchema = "landing-preflight/v1"
$frontierAuthorityPath = Join-Path $PSScriptRoot "breaker-repair-frontier-authority.json"
$frontierRetryAuthorityPath = Join-Path $PSScriptRoot "breaker-repair-frontier-retry-authority.json"
$frontierAuthorityIssue = 7476
$frontierAuthorityNode = "I_kwDORKgVcc8AAAABOK7jjA"
$frontierAuthorityBodySha256 = "2b81a8235e359fa61c9b58d87c61ce97cb15cf952abca77034afdacaa0b33f21"
$frontierBreakerKey = "7171/7428"
$frontierBreakerOpenTs = "2026-08-24T17:00:56.433Z"
$frontierBreakerLine = 11594
$frontierBreakerRowSha256 = "5d6d5ad8afcdfd3119f7ae19a6f2d601c21bc84e1ef47598ba1811d1a58a9879"
$frontierBreakerRowBytes = 346
$frontierRootIssue = 7468
$frontierRepairIssue = 7470
$frontierRepairBodySha256 = "3be40dd2e99d9142a60989463ed1601577ec9d8e08f44a79c198ed09449ffb89"
$frontierRetryIssue = 7492
$frontierRetryIssueNode = "I_kwDORKgVcc8AAAABOXQ9_A"
$frontierRetryBodySha256 = "8ea03f6a27626411cb4f0f46e6a9accbcdafabf12655dc672b57b4dc864e0317"
$frontierRetryCanonicalBodySha256 = "3bef53a4b384fd50b0231177e6d1943f65ed5c934e2fed15b68c40ccf3490028"
$frontierDecisionIssue = 7493
$frontierDecisionIssueNode = "I_kwDORKgVcc8AAAABOXRc-w"
$frontierDecisionBodySha256 = "cf9066741676d000e08c2613ecc478f7c947de50fc706bd0e66b1e9419324fa5"
$frontierActivationIssue = 7494
$frontierActivationIssueNode = "I_kwDORKgVcc8AAAABOXR9AA"
$frontierActivationBodySha256 = "204bd2189f28b14be0fbeb5f253fc253584ffcfa5a57d14efd9e0ccde7d38e0a"
$frontierConsumedPr = 7487
$frontierConsumedPrNode = "PR_kwDORKgVcc8AAAABBAWvGA"
$frontierConsumedHead = "840a6ec66e70ec429cb674a1197977c9cef655e6"
$frontierConsumedBase = "0fb05e89907f1dc196bbc9a07fa7f852ae81c3fc"
$frontierConsumedControllerHead = "6fbbd0aa39e20b27f6d6d71dff1b8c237e783dc7"
$frontierConsumptionNamespace = "refs/tags/orchestrator-consumption/"
$decision7643Issue = 7643
$decision7643Node = "I_kwDORKgVcc8AAAABPn7EAw"
$decision7643BodySha256 = "0f86990a051007d816b2604a17316793ff3a891281f9126e6e751fc4c56ed966"
$decision7643UpdatedAt = "2026-09-04T13:40:31Z"
$decision7643ClosedAt = "2026-09-04T13:40:31Z"
$decision7643RulingCommentId = 5541242254
$decision7643RulingCommentUrl = "https://github.com/chase-sets/chase-sets/issues/7643#issuecomment-5541242254"
$decision7643RulingCommentBodySha256 = "559aead08264d5795d3909718cdd05abd49572e84fe55590eef31a88a08fdffd"
$decision7643RulingCommentAt = "2026-09-04T13:37:30Z"
$decision7643ToddLogin = "todd-skelton"
$decision7643ToddId = 17231123
$decision7643ToddNode = "MDQ6VXNlcjE3MjMxMTIz"
$decision7643CandidatePr = 7641
$decision7643CandidateHead = "d3175a021e5fd958b60eda1500b5e1d072bbf195"
$decision7643BreakerOpenTs = "2026-09-03T21:47:13.444Z"
$decision7643BreakerLine = 14530
$decision7643BreakerIssue = 7558
$decision7643BreakerPr = 7631
$decision7643BreakerOutcome = "HOSTED_E2E_REQUIRED_FAILURE"
$decision7643BreakerScope = "pipeline"
$decision7643BreakerKey = "$decision7643BreakerIssue/$decision7643BreakerPr"
$decision7643BreakerRowSha256 = "2b35a27c6cdf5cd2d68e54a8f27fd526586a22c5c0eae52bfaa3e373dfbbfb60"
$decision7643BreakerRowBytes = 804
Import-Module (Join-Path $PSScriptRoot "review-head-contract.psm1") -Force -DisableNameChecking

function New-PreflightResult(
  [string]$Status,
  [string]$Reason,
  [int]$MutationCount,
  $InitialObservation,
  $FinalObservation,
  $Review
) {
  $receiptObservation = if ($FinalObservation) { $FinalObservation } else { $InitialObservation }
  $receiptScope = if ($receiptObservation -and $receiptObservation.PSObject.Properties["changeScope"]) {
    ConvertTo-EffectiveChangeScope $receiptObservation.changeScope $(if ($receiptObservation.pr) { [string]$receiptObservation.pr.head } else { "" })
  } else {
    New-FailClosedChangeScopeObservation $(if ($receiptObservation -and $receiptObservation.pr) { [string]$receiptObservation.pr.head } else { "" }) "CHANGE_SCOPE_EVIDENCE_MISSING"
  }
  $receiptBreaker = if ($receiptObservation -and $receiptObservation.breaker -and $receiptObservation.breaker.complete -eq $true -and $receiptObservation.breaker.healthy -eq $false) {
    [ordered]@{
      schemaVersion = "open-pipeline-breaker-identity/v1"
      keys = [string[]]@($receiptObservation.breaker.open)
      rows = [object[]]@($receiptObservation.breaker.openRows)
    }
  } else { $null }
  $result = [pscustomobject][ordered]@{
    schema = $preflightSchema
    action = $Action.ToLowerInvariant()
    status = $Status
    reason = $Reason
    repository = $Repository
    pr = $Pr
    head = if ($FinalObservation) { $FinalObservation.pr.head } elseif ($InitialObservation) { $InitialObservation.pr.head } else { $null }
    mutationCount = $MutationCount
    mutationDisabled = [bool]$MutationDisabled
    review = $Review
    changeScope = $receiptScope
    openBreaker = $receiptBreaker
    observations = [ordered]@{
      initial = $InitialObservation
      final = $FinalObservation
    }
  }
  if ($script:currentAdmission) {
    $result | Add-Member -NotePropertyName admission -NotePropertyValue $script:currentAdmission
    $result | Add-Member -NotePropertyName enqueueAttempts -NotePropertyValue $script:enqueueAttempts
    $result | Add-Member -NotePropertyName dequeueAttempts -NotePropertyValue $script:dequeueAttempts
  }
  return $result
}

function Invoke-ExternalProcess([string]$Command, [string[]]$Arguments) {
  try {
    $resolved = Get-Command $Command -CommandType Application -ErrorAction Stop | Select-Object -First 1
  } catch {
    return [pscustomobject][ordered]@{ exitCode = 127; stdout = ""; stderr = "command unavailable" }
  }
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = $resolved.Source
  $start.UseShellExecute = $false
  $start.CreateNoWindow = $true
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  foreach ($argument in $Arguments) { [void]$start.ArgumentList.Add("$argument") }
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $start
  try {
    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    [pscustomobject][ordered]@{
      exitCode = $process.ExitCode
      stdout = $stdoutTask.GetAwaiter().GetResult()
      stderr = $stderrTask.GetAwaiter().GetResult()
    }
  } catch {
    [pscustomobject][ordered]@{ exitCode = 126; stdout = ""; stderr = "command invocation failed" }
  } finally {
    $process.Dispose()
  }
}

function Invoke-GhGraphQl([string]$Query, [hashtable]$Variables) {
  $queryPath = Join-Path ([IO.Path]::GetTempPath()) ("landing-preflight-" + [guid]::NewGuid().ToString("N") + ".graphql")
  try {
    [IO.File]::WriteAllText($queryPath, $Query, [Text.UTF8Encoding]::new($false))
    $arguments = [Collections.Generic.List[string]]::new()
    foreach ($argument in @("api", "graphql", "-F", "query=@$queryPath")) { $arguments.Add($argument) }
    foreach ($key in @($Variables.Keys | Sort-Object)) {
      $arguments.Add("-F")
      $arguments.Add("$key=$($Variables[$key])")
    }
    $result = Invoke-ExternalProcess $GhCommand @($arguments)
    if ([string]::IsNullOrWhiteSpace($result.stdout)) {
      return [pscustomobject][ordered]@{
        complete = $false
        reason = "GITHUB_GRAPHQL_UNREADABLE"
        payload = $null
        process = [ordered]@{ exitCode = [int]$result.exitCode; stdout = [string]$result.stdout; stderr = [string]$result.stderr }
      }
    }
    try {
      $payload = $result.stdout | ConvertFrom-Json -DateKind String -ErrorAction Stop
    } catch {
      return [pscustomobject][ordered]@{
        complete = $false
        reason = "GITHUB_GRAPHQL_MALFORMED"
        payload = $null
        process = [ordered]@{ exitCode = [int]$result.exitCode; stdout = [string]$result.stdout; stderr = [string]$result.stderr }
      }
    }
    $hasErrors = $null -ne $payload.PSObject.Properties["errors"] -and
      -not [object]::ReferenceEquals($null, $payload.PSObject.Properties["errors"].Value) -and
      @($payload.PSObject.Properties["errors"].Value).Count -gt 0
    $reason = if ($result.exitCode -ne 0) {
      "GITHUB_GRAPHQL_PROCESS_FAILED"
    } elseif ($hasErrors -or $null -eq $payload.data) {
      "GITHUB_GRAPHQL_ERRORS"
    } else {
      "GITHUB_GRAPHQL_COMPLETE"
    }
    [pscustomobject][ordered]@{
      complete = $reason -ceq "GITHUB_GRAPHQL_COMPLETE"
      reason = $reason
      payload = $payload
      process = [ordered]@{ exitCode = [int]$result.exitCode; stdout = [string]$result.stdout; stderr = [string]$result.stderr }
    }
  } finally {
    if (Test-Path -LiteralPath $queryPath -PathType Leaf) {
      Remove-Item -LiteralPath $queryPath -Force -ErrorAction SilentlyContinue
    }
  }
}

function Test-ConnectionComplete($Connection, [int]$ExpectedCollected = -1) {
  if ($null -eq $Connection -or
      $null -eq $Connection.pageInfo -or
      $Connection.pageInfo.hasNextPage -isnot [bool] -or
      $Connection.pageInfo.hasNextPage -eq $true -or
      -not (Test-WholeNumber $Connection.totalCount 0)) {
    return $false
  }
  $nodes = @($Connection.nodes)
  if ($ExpectedCollected -ge 0 -and $nodes.Count -ne $ExpectedCollected) { return $false }
  return $nodes.Count -eq [int64]$Connection.totalCount
}

function Test-ObjectProperty($Object, [string]$Name) {
  if ($null -eq $Object) { return $false }
  if ($Object -is [Collections.IDictionary]) { return $Object.Contains($Name) }
  return $null -ne $Object.PSObject.Properties[$Name]
}

function Test-RequiredCheckInstant($Value) {
  if ($Value -isnot [string] -or
      [string]$Value -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$') {
    return $false
  }
  $parsed = [datetimeoffset]::MinValue
  return [datetimeoffset]::TryParse(
    [string]$Value,
    [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::RoundtripKind,
    [ref]$parsed
  )
}

function Test-RequiredCheckUri($Value) {
  if ($null -eq $Value) { return $true }
  if ($Value -isnot [string]) { return $false }
  $parsed = $null
  return [uri]::TryCreate([string]$Value, [UriKind]::Absolute, [ref]$parsed) -and
    $parsed.Scheme -ceq 'https' -and -not [string]::IsNullOrWhiteSpace($parsed.Host)
}

function ConvertTo-RequiredCheckObservation($Context) {
  $nodeType = if (Test-ObjectProperty $Context '__typename') { [string]$Context.__typename } else { $null }
  if ($nodeType -ceq 'CheckRun') {
    $topKeys = @('__typename', 'name', 'status', 'conclusion', 'databaseId', 'detailsUrl', 'completedAt', 'checkSuite')
    $suite = if (Test-ObjectProperty $Context 'checkSuite') { $Context.checkSuite } else { $null }
    $app = if ($suite -and (Test-ObjectProperty $suite 'app')) { $suite.app } else { $null }
    $workflowRun = if ($suite -and (Test-ObjectProperty $suite 'workflowRun')) { $suite.workflowRun } else { $null }
    $workflow = if ($workflowRun -and (Test-ObjectProperty $workflowRun 'workflow')) { $workflowRun.workflow } else { $null }
    $status = if (Test-ObjectProperty $Context 'status') { [string]$Context.status } else { $null }
    $conclusion = if (Test-ObjectProperty $Context 'conclusion') { $Context.conclusion } else { $null }
    $completedAt = if (Test-ObjectProperty $Context 'completedAt') { $Context.completedAt } else { $null }
    $knownStatuses = @('COMPLETED', 'IN_PROGRESS', 'PENDING', 'QUEUED', 'REQUESTED', 'WAITING')
    $knownConclusions = @('ACTION_REQUIRED', 'CANCELLED', 'FAILURE', 'NEUTRAL', 'SKIPPED', 'STALE', 'STARTUP_FAILURE', 'SUCCESS', 'TIMED_OUT')
    $terminalShape = if ($status -ceq 'COMPLETED') {
      $conclusion -is [string] -and [string]$conclusion -cin $knownConclusions -and (Test-RequiredCheckInstant $completedAt)
    } else {
      $null -eq $conclusion -and $null -eq $completedAt
    }
    $valid = (Test-ExactKeys $Context $topKeys) -and
      $Context.name -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$Context.name) -and
      $status -cin $knownStatuses -and
      (Test-WholeNumber $Context.databaseId 1) -and
      (Test-RequiredCheckUri $Context.detailsUrl) -and
      $terminalShape -and
      (Test-ExactKeys $suite @('app', 'workflowRun')) -and
      (Test-ExactKeys $app @('databaseId')) -and (Test-WholeNumber $app.databaseId 1) -and
      (Test-ExactKeys $workflowRun @('workflow')) -and
      (Test-ExactKeys $workflow @('databaseId')) -and (Test-WholeNumber $workflow.databaseId 1)
    return [pscustomobject][ordered]@{
      schemaVersion = 'required-check-observation/v1'
      valid = $valid
      reason = if ($valid) { 'REQUIRED_CHECK_IDENTITY_VALID' } else { 'REQUIRED_CHECK_IDENTITY_MALFORMED' }
      nodeType = 'CheckRun'
      name = if ($Context.name -is [string]) { [string]$Context.name } else { $null }
      databaseId = if (Test-WholeNumber $Context.databaseId 1) { [long]$Context.databaseId } else { $null }
      status = $status
      conclusion = if ($conclusion -is [string]) { [string]$conclusion } else { $null }
      completedAt = if ($completedAt -is [string]) { [string]$completedAt } else { $null }
      producer = [ordered]@{
        appDatabaseId = if ($app -and (Test-WholeNumber $app.databaseId 1)) { [long]$app.databaseId } else { $null }
        workflowDatabaseId = if ($workflow -and (Test-WholeNumber $workflow.databaseId 1)) { [long]$workflow.databaseId } else { $null }
      }
    }
  }
  if ($nodeType -ceq 'StatusContext') {
    $valid = (Test-ExactKeys $Context @('__typename', 'context', 'state')) -and
      $Context.context -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$Context.context) -and
      $Context.state -is [string] -and [string]$Context.state -cin @('ERROR', 'EXPECTED', 'FAILURE', 'PENDING', 'SUCCESS')
    return [pscustomobject][ordered]@{
      schemaVersion = 'required-check-observation/v1'
      valid = $valid
      reason = if ($valid) { 'REQUIRED_STATUS_CONTEXT_VALID' } else { 'REQUIRED_STATUS_CONTEXT_MALFORMED' }
      nodeType = 'StatusContext'
      name = if ($Context.context -is [string]) { [string]$Context.context } else { $null }
      databaseId = $null
      status = if ($Context.state -is [string]) { [string]$Context.state } else { $null }
      conclusion = $null
      completedAt = $null
      producer = $null
    }
  }
  return [pscustomobject][ordered]@{
    schemaVersion = 'required-check-observation/v1'
    valid = $false
    reason = 'REQUIRED_CHECK_NODE_TYPE_UNSUPPORTED'
    nodeType = $nodeType
    name = $null
    databaseId = $null
    status = $null
    conclusion = $null
    completedAt = $null
    producer = $null
  }
}

function ConvertTo-RequiredCheckProvenance($Observation) {
  [ordered]@{
    nodeType = [string]$Observation.nodeType
    databaseId = $Observation.databaseId
    status = [string]$Observation.status
    conclusion = if ($null -eq $Observation.conclusion) { $null } else { [string]$Observation.conclusion }
    completedAt = if ($null -eq $Observation.completedAt) { $null } else { [string]$Observation.completedAt }
    producer = $Observation.producer
  }
}

function New-RequiredCheckReduction(
  [string]$RequiredName,
  [string]$Status,
  [string]$Reason,
  [int]$MatchCount,
  $Selected = $null,
  [object[]]$Superseded = @()
) {
  [pscustomobject][ordered]@{
    schemaVersion = 'required-check-reducer/v1'
    requiredName = $RequiredName
    status = $Status
    reason = $Reason
    matchCount = $MatchCount
    selected = $Selected
    superseded = [object[]]@($Superseded)
  }
}

function Reduce-RequiredCheckObservations([object[]]$Checks, [string]$RequiredName) {
  $matching = @($Checks | Where-Object { [string]$_.name -ceq $RequiredName })
  if ($matching.Count -eq 0) {
    return New-RequiredCheckReduction $RequiredName 'unknown' 'REQUIRED_CHECK_MISSING' 0
  }

  $versioned = @($matching | Where-Object { [string]$_.schemaVersion -ceq 'required-check-observation/v1' })
  if ($versioned.Count -eq 0) {
    if ($matching.Count -ne 1) {
      return New-RequiredCheckReduction $RequiredName 'unknown' 'REQUIRED_CHECK_MISSING_OR_CONTRADICTORY' $matching.Count
    }
    $legacySelected = [ordered]@{ nodeType = 'LegacyFixture'; outcome = [string]$matching[0].outcome }
    if ([string]$matching[0].outcome -cne 'success') {
      return New-RequiredCheckReduction $RequiredName 'refused' 'REQUIRED_CHECK_NOT_GREEN' 1 $legacySelected
    }
    return New-RequiredCheckReduction $RequiredName 'eligible' 'REQUIRED_CHECK_SELECTED' 1 $legacySelected
  }
  if ($versioned.Count -ne $matching.Count) {
    return New-RequiredCheckReduction $RequiredName 'unknown' 'REQUIRED_CHECK_IDENTITY_MALFORMED' $matching.Count
  }
  $invalid = @($matching | Where-Object { $_.valid -ne $true })
  if ($invalid.Count -gt 0) {
    $reason = @($invalid | ForEach-Object { [string]$_.reason } | Sort-Object -Unique)
    return New-RequiredCheckReduction $RequiredName 'unknown' $(if ($reason.Count -eq 1) { $reason[0] } else { 'REQUIRED_CHECK_IDENTITY_MALFORMED' }) $matching.Count
  }
  $nodeTypes = @($matching | ForEach-Object { [string]$_.nodeType } | Sort-Object -Unique)
  if ($nodeTypes.Count -ne 1) {
    return New-RequiredCheckReduction $RequiredName 'unknown' 'REQUIRED_CHECK_MIXED_NODE_TYPES' $matching.Count
  }
  if ($nodeTypes[0] -ceq 'StatusContext') {
    if ($matching.Count -ne 1) {
      return New-RequiredCheckReduction $RequiredName 'unknown' 'REQUIRED_STATUS_CONTEXT_DUPLICATE' $matching.Count
    }
    $selected = ConvertTo-RequiredCheckProvenance $matching[0]
    if ([string]$matching[0].status -cne 'SUCCESS') {
      return New-RequiredCheckReduction $RequiredName 'refused' 'REQUIRED_CHECK_NOT_GREEN' 1 $selected
    }
    return New-RequiredCheckReduction $RequiredName 'eligible' 'REQUIRED_CHECK_SELECTED' 1 $selected
  }

  # Terminality is an admission predicate, not an ordering value.
  if (@($matching | Where-Object { [string]$_.status -cne 'COMPLETED' }).Count -gt 0) {
    return New-RequiredCheckReduction $RequiredName 'refused' 'REQUIRED_CHECK_NONTERMINAL' $matching.Count
  }
  $producerKeys = @($matching | ForEach-Object {
      "$($_.producer.appDatabaseId)/$($_.producer.workflowDatabaseId)"
    } | Sort-Object -Unique)
  if ($producerKeys.Count -ne 1) {
    return New-RequiredCheckReduction $RequiredName 'unknown' 'REQUIRED_CHECK_PRODUCER_MISMATCH' $matching.Count
  }
  $ids = @($matching | ForEach-Object { [long]$_.databaseId })
  if (@($ids | Sort-Object -Unique).Count -ne $ids.Count) {
    return New-RequiredCheckReduction $RequiredName 'unknown' 'REQUIRED_CHECK_DUPLICATE_ID' $matching.Count
  }

  $allSuccess = @($matching | Where-Object { [string]$_.conclusion -cne 'SUCCESS' }).Count -eq 0
  if (-not $allSuccess) {
    for ($left = 0; $left -lt $matching.Count; $left += 1) {
      for ($right = $left + 1; $right -lt $matching.Count; $right += 1) {
        $leftInstant = [datetimeoffset]::Parse([string]$matching[$left].completedAt, [Globalization.CultureInfo]::InvariantCulture)
        $rightInstant = [datetimeoffset]::Parse([string]$matching[$right].completedAt, [Globalization.CultureInfo]::InvariantCulture)
        $timeOrder = [datetimeoffset]::Compare($leftInstant, $rightInstant)
        if ($timeOrder -eq 0) {
          return New-RequiredCheckReduction $RequiredName 'unknown' 'REQUIRED_CHECK_ORDER_TIE' $matching.Count
        }
        $idOrder = ([long]$matching[$left].databaseId).CompareTo([long]$matching[$right].databaseId)
        if (($timeOrder -gt 0 -and $idOrder -lt 0) -or ($timeOrder -lt 0 -and $idOrder -gt 0)) {
          return New-RequiredCheckReduction $RequiredName 'unknown' 'REQUIRED_CHECK_ORDER_CONTRADICTION' $matching.Count
        }
      }
    }
  }

  $ordering = @(@{ Expression = { [datetimeoffset]::Parse([string]$_.completedAt, [Globalization.CultureInfo]::InvariantCulture) }; Descending = $true })
  if ($allSuccess) {
    $ordering += @{ Expression = { [long]$_.databaseId }; Descending = $true }
  }
  $ordered = @($matching | Sort-Object $ordering)
  $selected = ConvertTo-RequiredCheckProvenance $ordered[0]
  $superseded = @($ordered | Select-Object -Skip 1 | ForEach-Object { ConvertTo-RequiredCheckProvenance $_ })
  if ([string]$ordered[0].conclusion -cnotin @('SUCCESS', 'NEUTRAL', 'SKIPPED')) {
    return New-RequiredCheckReduction $RequiredName 'refused' 'REQUIRED_CHECK_NOT_GREEN' $matching.Count $selected $superseded
  }
  return New-RequiredCheckReduction $RequiredName 'eligible' 'REQUIRED_CHECK_SELECTED' $matching.Count $selected $superseded
}

function Get-ObservedType($Value, [bool]$Present) {
  if (-not $Present) { return "missing" }
  if ($null -eq $Value) { return "null" }
  if ($Value -is [bool]) { return "boolean" }
  if ($Value -is [string]) { return "string" }
  if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int] -or $Value -is [long] -or
      $Value -is [uint16] -or $Value -is [uint32] -or $Value -is [uint64]) { return "integer" }
  if ($Value -is [Collections.IDictionary] -or
      ($Value -is [psobject] -and $Value -isnot [Array] -and $Value -isnot [ValueType])) { return "object" }
  if ($Value -is [Collections.IEnumerable]) { return "array" }
  return "unknown"
}

function New-FieldEvidence(
  [bool]$Present,
  $Value,
  [bool]$Predicate,
  [Collections.IDictionary]$Fields = ([ordered]@{}),
  [string[]]$UnexpectedKeys = @()
) {
  $type = Get-ObservedType $Value $Present
  $observedValue = if ($type -in @("object", "array")) {
    try { ConvertTo-CanonicalJson $Value }
    catch {
      try { $Value | ConvertTo-Json -Compress -Depth 64 -ErrorAction Stop }
      catch { "<unserializable>" }
    }
  } else { $Value }
  [ordered]@{
    present = $Present
    explicitNull = $Present -and $null -eq $Value
    type = $type
    value = $observedValue
    predicate = $Predicate
    unexpectedKeys = [string[]]@($UnexpectedKeys | Sort-Object -CaseSensitive)
    fields = $Fields
  }
}

function Get-ScalarFieldEvidence($Object, [string]$Name, [scriptblock]$Predicate) {
  $present = Test-ObjectProperty $Object $Name
  $value = if ($present) { Get-ObjectValue $Object $Name } else { $null }
  New-FieldEvidence $present $value ($present -and (& $Predicate $value))
}

function Get-NestedObjectFieldEvidence(
  $Object,
  [string]$Name,
  [string[]]$ExpectedKeys,
  [Collections.IDictionary]$Fields,
  [bool]$Nullable
) {
  $present = Test-ObjectProperty $Object $Name
  $value = if ($present) { Get-ObjectValue $Object $Name } else { $null }
  $isObject = (Get-ObservedType $value $present) -ceq "object"
  $unexpected = if ($isObject) { @((Get-ObjectKeys $value) | Where-Object { $_ -notin $ExpectedKeys }) } else { @() }
  $closed = $isObject -and (Test-ExactKeys $value $ExpectedKeys)
  $childrenValid = @($Fields.Values | Where-Object { $_.predicate -ne $true }).Count -eq 0
  $predicate = $present -and (($Nullable -and $null -eq $value) -or ($closed -and $childrenValid))
  New-FieldEvidence $present $value $predicate $Fields $unexpected
}

function ConvertTo-QueueEntryObservation($Value) {
  $entryKeys = @("id", "position", "state", "solo", "jump", "baseCommit", "headCommit", "pullRequest")
  $entryIsObject = (Get-ObservedType $Value ($null -ne $Value)) -ceq "object"
  $entryUnexpected = if ($entryIsObject) { @((Get-ObjectKeys $Value) | Where-Object { $_ -notin $entryKeys }) } else { @() }
  $fields = [ordered]@{}
  $fields.id = Get-ScalarFieldEvidence $Value "id" { param($v) $v -is [string] -and $v -cmatch "^[A-Za-z0-9_=-]+$" }
  $fields.position = Get-ScalarFieldEvidence $Value "position" { param($v) Test-WholeNumber $v 0 }
  $fields.state = Get-ScalarFieldEvidence $Value "state" { param($v) $v -is [string] -and $v -cin @("QUEUED", "AWAITING_CHECKS", "MERGEABLE", "UNMERGEABLE", "LOCKED") }
  $fields.solo = Get-ScalarFieldEvidence $Value "solo" { param($v) $v -is [bool] }
  $fields.jump = Get-ScalarFieldEvidence $Value "jump" { param($v) $v -is [bool] }

  foreach ($commitName in @("baseCommit", "headCommit")) {
    $present = Test-ObjectProperty $Value $commitName
    $commit = if ($present) { Get-ObjectValue $Value $commitName } else { $null }
    $commitFields = [ordered]@{
      oid = Get-ScalarFieldEvidence $commit "oid" { param($v) $v -is [string] -and $v -cmatch "^[a-f0-9]{40}$" }
    }
    $fields[$commitName] = Get-NestedObjectFieldEvidence $Value $commitName @("oid") $commitFields $true
  }

  $pullPresent = Test-ObjectProperty $Value "pullRequest"
  $pull = if ($pullPresent) { Get-ObjectValue $Value "pullRequest" } else { $null }
  $pullFields = [ordered]@{
    id = Get-ScalarFieldEvidence $pull "id" { param($v) $v -is [string] -and $v -cmatch "^[A-Za-z0-9_=-]+$" }
    number = Get-ScalarFieldEvidence $pull "number" { param($v) Test-WholeNumber $v 1 }
    headRefOid = Get-ScalarFieldEvidence $pull "headRefOid" { param($v) $v -is [string] -and $v -cmatch "^[a-f0-9]{40}$" }
  }
  $fields.pullRequest = Get-NestedObjectFieldEvidence $Value "pullRequest" @("id", "number", "headRefOid") $pullFields $true

  $valid = $entryIsObject -and (Test-ExactKeys $Value $entryKeys) -and
    @($fields.Values | Where-Object { $_.predicate -ne $true }).Count -eq 0
  [ordered]@{
    schemaVersion = "merge-queue-entry-observation/v1"
    valid = $valid
    unexpectedKeys = [string[]]@($entryUnexpected | Sort-Object -CaseSensitive)
    fields = $fields
    stable = [ordered]@{
      entryId = if ($fields.id.predicate) { [string](Get-ObjectValue $Value "id") } else { $null }
      jump = if ($fields.jump.predicate) { [bool](Get-ObjectValue $Value "jump") } else { $null }
      pullRequest = if ($null -eq $pull) { $null } else { [ordered]@{ id = [string]$pull.id; number = [long]$pull.number; headOid = [string]$pull.headRefOid } }
    }
    transient = [ordered]@{
      position = if ($fields.position.predicate) { [long](Get-ObjectValue $Value "position") } else { $null }
      state = if ($fields.state.predicate) { [string](Get-ObjectValue $Value "state") } else { $null }
      solo = if ($fields.solo.predicate) { [bool](Get-ObjectValue $Value "solo") } else { $null }
      baseOid = if ($null -eq (Get-ObjectValue $Value "baseCommit")) { $null } else { [string](Get-ObjectValue (Get-ObjectValue $Value "baseCommit") "oid") }
      headOid = if ($null -eq (Get-ObjectValue $Value "headCommit")) { $null } else { [string](Get-ObjectValue (Get-ObjectValue $Value "headCommit") "oid") }
    }
  }
}

function Get-Sha256([byte[]]$Bytes) {
  ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes))).ToLowerInvariant()
}

function Get-BodySha256([string]$Body) {
  Get-Sha256 ([Text.UTF8Encoding]::new($false).GetBytes($Body.Replace("`r`n", "`n")))
}

function Get-ObjectKeys($Value) {
  if ($Value -is [Collections.IDictionary]) { return [string[]]@($Value.Keys) }
  if ($null -eq $Value) { return [string[]]@() }
  return [string[]]@($Value.PSObject.Properties.Name)
}

function Get-ObjectValue($Value, [string]$Name) {
  if ($null -eq $Value) { return $null }
  if ($Value -is [Collections.IDictionary]) { return $Value[$Name] }
  $property = $Value.PSObject.Properties[$Name]
  if ($null -eq $property) { return $null }
  return $property.Value
}

function Test-ExactKeys($Value, [string[]]$Expected) {
  if ($null -eq $Value -or ($Value -isnot [Collections.IDictionary] -and $Value -isnot [psobject])) { return $false }
  $actual = [string[]]@(Get-ObjectKeys $Value)
  if ($actual.Count -ne $Expected.Count) { return $false }
  $set = [Collections.Generic.HashSet[string]]::new($Expected, [StringComparer]::Ordinal)
  foreach ($key in $actual) { if (-not $set.Contains($key)) { return $false } }
  return $true
}

function ConvertTo-CanonicalJson($Value) {
  if ($null -eq $Value) { return "null" }
  if ($Value -is [bool]) { return $(if ($Value) { "true" } else { "false" }) }
  if ($Value -is [string]) { return [System.Text.Json.JsonSerializer]::Serialize([string]$Value, [System.Text.Json.JsonSerializerOptions]::new()) }
  if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int] -or $Value -is [long] -or
      $Value -is [uint16] -or $Value -is [uint32] -or $Value -is [uint64]) {
    return [Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture)
  }
  if ($Value -is [Collections.IDictionary] -or
      ($Value -is [psobject] -and $Value -isnot [Array] -and $Value -isnot [ValueType])) {
    $keys = [string[]]@(Get-ObjectKeys $Value)
    [Array]::Sort($keys, [StringComparer]::Ordinal)
    $members = foreach ($key in $keys) {
      ([System.Text.Json.JsonSerializer]::Serialize($key, [System.Text.Json.JsonSerializerOptions]::new())) + ":" + (ConvertTo-CanonicalJson (Get-ObjectValue $Value $key))
    }
    return "{" + ($members -join ",") + "}"
  }
  if ($Value -is [Collections.IEnumerable]) {
    $items = foreach ($item in $Value) { ConvertTo-CanonicalJson $item }
    return "[" + ($items -join ",") + "]"
  }
  throw "unsupported canonical value"
}

function Get-CanonicalSha256($Value) {
  Get-Sha256 ([Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-CanonicalJson $Value)))
}

function Get-ConfigurationSha256($Value) {
  Get-Sha256 ([Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Compress -Depth 100)))
}

function Test-JsonTokenClosure([System.Text.Json.JsonElement]$Element, [int]$Depth = 1) {
  if ($Depth -gt 32) { return $false }
  switch ($Element.ValueKind) {
    ([System.Text.Json.JsonValueKind]::Object) {
      $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
      foreach ($property in $Element.EnumerateObject()) {
        if (-not $names.Add($property.Name) -or -not (Test-JsonTokenClosure $property.Value ($Depth + 1))) { return $false }
      }
    }
    ([System.Text.Json.JsonValueKind]::Array) {
      foreach ($item in $Element.EnumerateArray()) { if (-not (Test-JsonTokenClosure $item ($Depth + 1))) { return $false } }
    }
    ([System.Text.Json.JsonValueKind]::Number) {
      if ($Element.GetRawText() -cnotmatch "^(0|[1-9][0-9]*)$") { return $false }
    }
  }
  return $true
}

function ConvertFrom-ClosedJson([string]$Raw) {
  try {
    if ([string]::IsNullOrWhiteSpace($Raw) -or [Text.UTF8Encoding]::new($false).GetByteCount($Raw) -gt 65536) { return $null }
    $options = [System.Text.Json.JsonDocumentOptions]::new()
    $options.MaxDepth = 32
    $document = [System.Text.Json.JsonDocument]::Parse($Raw, $options)
    try { if (-not (Test-JsonTokenClosure $document.RootElement)) { return $null } } finally { $document.Dispose() }
    return $Raw | ConvertFrom-Json -AsHashtable -Depth 64 -DateKind String -ErrorAction Stop
  } catch { return $null }
}

function New-FailClosedChangeScopeObservation(
  [string]$RequestedHead,
  [string]$Reason,
  $Source = $null
) {
  $candidateCount = 0
  $candidates = [object[]]@()
  if ($Source -and (Test-ObjectProperty $Source "checkCandidateCount") -and
      (Test-WholeNumber (Get-ObjectValue $Source "checkCandidateCount") 0)) {
    $candidateCount = [long](Get-ObjectValue $Source "checkCandidateCount")
  }
  if ($Source -and (Test-ObjectProperty $Source "checkCandidates") -and
      $null -ne (Get-ObjectValue $Source "checkCandidates")) {
    $candidates = [object[]]@((Get-ObjectValue $Source "checkCandidates"))
  }
  [pscustomobject][ordered]@{
    schemaVersion = "pr-change-scope-observation/v1"
    classification = "deployable"
    proven = $false
    reason = $Reason
    requestedHead = $RequestedHead
    evaluatedHead = $null
    checkCandidateCount = $candidateCount
    checkCandidates = $candidates
    evidence = $null
    sourceReason = if ($Source -and (Test-ObjectProperty $Source "reason")) { [string](Get-ObjectValue $Source "reason") } else { $null }
  }
}

function ConvertTo-EffectiveChangeScope($Scope, [string]$ExpectedHead) {
  if ($null -eq $Scope) {
    return New-FailClosedChangeScopeObservation $ExpectedHead "CHANGE_SCOPE_EVIDENCE_MISSING"
  }
  if ([string]$Scope.schemaVersion -cne "pr-change-scope-observation/v1") {
    return New-FailClosedChangeScopeObservation $ExpectedHead "CHANGE_SCOPE_EVIDENCE_MALFORMED" $Scope
  }
  if ([string]$Scope.requestedHead -cne $ExpectedHead) {
    return New-FailClosedChangeScopeObservation $ExpectedHead "CHANGE_SCOPE_HEAD_MISMATCH" $Scope
  }
  if ($Scope.proven -eq $false -and [string]$Scope.classification -ceq "deployable" -and
      $null -eq $Scope.evaluatedHead -and [string]$Scope.reason -cmatch '^CHANGE_SCOPE_[A-Z0-9_]+$') {
    return $Scope
  }
  if ([string]$Scope.evaluatedHead -cne $ExpectedHead) {
    return New-FailClosedChangeScopeObservation $ExpectedHead "CHANGE_SCOPE_HEAD_MISMATCH" $Scope
  }
  if ($Scope.proven -ne $true -or
      [string]$Scope.classification -notin @("deployable", "non-deployable") -or
      -not (Test-WholeNumber $Scope.checkCandidateCount 0) -or
      $Scope.checkCandidates -isnot [Array] -or
      [long]$Scope.checkCandidateCount -ne @($Scope.checkCandidates).Count -or
      [long]$Scope.checkCandidateCount -ne 1 -or
      $null -eq $Scope.evidence) {
    return New-FailClosedChangeScopeObservation $ExpectedHead "CHANGE_SCOPE_EVIDENCE_INCOMPLETE" $Scope
  }
  return $Scope
}

function Get-ChangeScopeOutputMaps([string]$LogText) {
  $documents = [Collections.Generic.List[object]]::new()
  $buffer = [Collections.Generic.List[string]]::new()
  $collecting = $false
  $invalidCandidate = $false
  $legacyKeys = @(
    "changed_files_json", "affected_workspaces", "affected_workspaces_json",
    "directly_affected_workspaces_json", "docs_only", "local_checks", "unit_tests",
    "db_tests", "e2e_tests", "e2e_suites", "e2e_suites_json", "e2e_suite_batches_json",
    "integration_risk_required", "integration_risk_reason", "build", "docker_image",
    "terraform", "workflow_lint", "deploy", "cluster_preview", "compose_smoke",
    "exposure_posture_changed", "exposure_posture_categories",
    "exposure_posture_categories_json"
  )
  $scopeKeys = $legacyKeys + @('scope_json')
  # JSON permits each ASCII key character to be literal or Unicode-escaped,
  # even when a broken value prevents materializing the document's keys.
  $keyPattern = '"(?:' + (@(foreach ($key in $scopeKeys) {
      (@(foreach ($character in $key.ToCharArray()) {
          '(?:' + [regex]::Escape([string]$character) + '|\\u(?i:' + ('{0:x4}' -f [int]$character) + '))'
        }) -join '')
    }) -join '|') + ')"\s*:'
  :scopeCandidate foreach ($rawLine in @($LogText -split "`r?`n")) {
    $line = [regex]::Replace([string]$rawLine, "`e\[[0-9;]*[A-Za-z]", "")
    $line = [regex]::Replace($line, '^\uFEFF?\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z\s+', '')
    $trimmed = $line.Trim()
    if (-not $collecting) {
      if (-not $trimmed.StartsWith('{', [StringComparison]::Ordinal)) { continue }
      $buffer.Clear()
      $collecting = $true
    }
    $buffer.Add($trimmed)
    if ($trimmed -cne "}" -and -not ($buffer.Count -eq 1 -and $trimmed.EndsWith('}', [StringComparison]::Ordinal))) { continue }
    $candidateRaw = @($buffer) -join "`n"
    $collecting = $false
    $expectedKeys = $legacyKeys
    $candidate = ConvertFrom-ClosedJson $candidateRaw
    # Scope-shaped failures poison the observation even beside a valid map.
    $scopeShaped = $candidateRaw -cmatch $keyPattern -or
      @((Get-ObjectKeys $candidate) | Where-Object { $_ -cin $scopeKeys }).Count -gt 0
    if (-not $scopeShaped) { continue }
    $current = Test-ObjectProperty $candidate 'scope_json'
    if ($current) { $expectedKeys += 'scope_json' }
    if (-not (Test-ExactKeys $candidate $expectedKeys)) { $invalidCandidate = $true; continue }
    $allStrings = $true
    foreach ($key in $expectedKeys) {
      if ((Get-ObjectValue $candidate $key) -isnot [string]) { $allStrings = $false; break }
    }
    if (-not $allStrings -or [string](Get-ObjectValue $candidate "deploy") -notin @("true", "false")) { $invalidCandidate = $true; continue }
    if ($current -eq $true) {
      # classifyChanges/toOutputMap/toGithubOutputMap at the same pinned producer.
      # Unmapped arrays are shape-checked, never used to guess classifier policy.
      $arrays = @('changedFiles', 'affectedWorkspaces', 'runtimeAffectedWorkspaces',
        'devDependencyTestAffectedWorkspaces', 'directlyAffectedWorkspaces',
        'directlyRuntimeAffectedWorkspaces', 'directlyTestOnlyAffectedWorkspaces',
        'e2eSuiteIds', 'exposurePostureCategories')
      $booleans = [ordered]@{
        docs_only = 'docsOnly'; local_checks = 'localChecksRequired'; unit_tests = 'unitTestsRequired'
        db_tests = 'dbTestsRequired'; e2e_tests = 'e2eTestsRequired'; integration_risk_required = 'integrationRiskRequired'
        build = 'buildRequired'; docker_image = 'dockerImageRequired'; terraform = 'terraformRequired'
        workflow_lint = 'workflowLintRequired'; deploy = 'deployRequired'; cluster_preview = 'clusterPreviewRequired'
        compose_smoke = 'composeSmokeRequired'; exposure_posture_changed = 'exposurePostureChanged'
      }
      $scope = ConvertFrom-ClosedJson $candidate.scope_json
      if (-not (Test-ExactKeys $scope ($arrays + @($booleans.Values) + @('integrationRiskReason')))) { $invalidCandidate = $true; continue scopeCandidate }
      foreach ($field in $arrays) {
        if ($scope[$field] -isnot [Array]) { $invalidCandidate = $true; continue scopeCandidate }
        foreach ($item in $scope[$field]) { if ($item -isnot [string]) { $invalidCandidate = $true; continue scopeCandidate } }
      }
      foreach ($field in $booleans.Values) { if ($scope[$field] -isnot [bool]) { $invalidCandidate = $true; continue scopeCandidate } }
      if ($scope.integrationRiskReason -isnot [string]) { $invalidCandidate = $true; continue scopeCandidate }
      $expected = [ordered]@{}
      foreach ($key in $booleans.Keys) { $expected[$key] = $scope[$booleans[$key]].ToString().ToLowerInvariant() }
      $expected.integration_risk_reason = $scope.integrationRiskReason
      $expected.affected_workspaces = $scope.affectedWorkspaces -join ','
      $expected.e2e_suites = $scope.e2eSuiteIds -join ','
      $expected.exposure_posture_categories = $scope.exposurePostureCategories -join ','
      foreach ($key in $expected.Keys) { if ($candidate[$key] -cne $expected[$key]) { $invalidCandidate = $true; continue scopeCandidate } }
      # Pinned producer: scripts/e2e-suites.mjs at 2d77c295802c06eb73543a2010babe5d02392fb7.
      # Keep the duration/order partition and greedy size-two batching in parity.
      $durations = [ordered]@{
        marketplace_browse = 420; marketplace_account = 300; marketplace_checkout = 540
        marketplace_seller = 360; catalog_admin_integrations = 720; catalog_admin_modeling = 660
        admin_growth = 360; admin_commerce = 420; admin_support = 240; admin_platform = 240
        admin_auth = 180; admin_access = 300; platform_mcp_sdk = 90
      }
      $order = [Collections.Generic.Dictionary[string,int]]::new([StringComparer]::Ordinal)
      foreach ($id in $durations.Keys) { $order.Add($id, $order.Count) }
      $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
      $suites = @(foreach ($id in $scope.e2eSuiteIds) {
          if ($seen.Add($id)) {
            [pscustomobject]@{ id = $id; order = $(if ($order.ContainsKey($id)) { $order[$id] } else { 999 }); duration = $(if ($order.ContainsKey($id)) { $durations[$id] } else { 300 }) }
          }
        })
      $batches = @(for ($index = 0; $index -lt [Math]::Ceiling($suites.Count / 2.0); $index++) {
          [pscustomobject]@{ index = $index; duration = 0; suites = [Collections.Generic.List[object]]::new() }
        })
      foreach ($suite in @($suites | Sort-Object -Stable @{ Expression = 'duration'; Descending = $true }, order)) {
        $target = @($batches | Where-Object { $_.suites.Count -lt 2 } | Sort-Object duration, @{ Expression = { $_.suites.Count } }, index)[0]
        $target.suites.Add($suite)
        $target.duration += $suite.duration
      }
      $suiteBatches = [string[]]@(foreach ($batch in $batches) { (@($batch.suites | Sort-Object -Stable order | ForEach-Object { $_.id }) -join ',') })
      $encoded = [ordered]@{
        changed_files_json = $scope.changedFiles; affected_workspaces_json = $scope.affectedWorkspaces
        directly_affected_workspaces_json = $scope.directlyAffectedWorkspaces; e2e_suites_json = $scope.e2eSuiteIds
        exposure_posture_categories_json = $scope.exposurePostureCategories
        e2e_suite_batches_json = $suiteBatches
      }
      foreach ($key in $encoded.Keys) {
        # Decode without pipeline enumeration: [] and [one] remain arrays. JSON
        # spelling/escaping is not authority; typed values and order must agree.
        try {
          $document = [System.Text.Json.JsonDocument]::Parse($candidate[$key])
          try {
            if ($document.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Array -or
                -not (Test-JsonTokenClosure $document.RootElement)) { $invalidCandidate = $true; continue scopeCandidate }
          } finally { $document.Dispose() }
          $actual = ConvertFrom-Json -InputObject $candidate[$key] -NoEnumerate -Depth 32 -DateKind String -ErrorAction Stop
          if ((ConvertTo-CanonicalJson $actual) -cne (ConvertTo-CanonicalJson $encoded[$key])) { $invalidCandidate = $true; continue scopeCandidate }
        } catch { $invalidCandidate = $true; continue scopeCandidate }
      }
    }
    $changedFilesRaw = [string](Get-ObjectValue $candidate "changed_files_json")
    try {
      $changedDocument = [System.Text.Json.JsonDocument]::Parse($changedFilesRaw)
      try {
        if ($changedDocument.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Array -or
            -not (Test-JsonTokenClosure $changedDocument.RootElement)) { $invalidCandidate = $true; continue }
      } finally { $changedDocument.Dispose() }
      $changedFiles = [object[]]@($changedFilesRaw | ConvertFrom-Json -Depth 64 -DateKind String -ErrorAction Stop)
    } catch {
      $invalidCandidate = $true
      continue
    }
    if (@($changedFiles | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0) {
      $invalidCandidate = $true
      continue
    }
    $documents.Add([pscustomobject][ordered]@{
        raw = $candidateRaw
        value = $candidate
        changedFiles = [string[]]@($changedFiles)
      })
  }
  if ($collecting -and (@($buffer) -join "`n") -cmatch ($keyPattern + '|"(?:scope_json|[a-z_]+_json|deploy)"\s*:')) { $invalidCandidate = $true }
  if ($invalidCandidate) { return [object[]]@() }
  return [object[]]@($documents)
}

function Get-HostedChangeScopeObservation([string]$PullHead, [object[]]$CheckCandidates) {
  $candidates = [object[]]@($CheckCandidates)
  $fallback = New-FailClosedChangeScopeObservation $PullHead $(if ($candidates.Count -eq 0) { "CHANGE_SCOPE_CHECK_MISSING" } else { "CHANGE_SCOPE_CHECK_AMBIGUOUS" })
  $fallback.checkCandidateCount = $candidates.Count
  $fallback.checkCandidates = $candidates
  if ($candidates.Count -ne 1) { return $fallback }

  $check = $candidates[0]
  if (-not (Test-WholeNumber $check.databaseId 1) -or
      [string]$check.status -cne "COMPLETED" -or [string]$check.conclusion -cne "SUCCESS" -or
      [string]::IsNullOrWhiteSpace([string]$check.detailsUrl)) {
    return New-FailClosedChangeScopeObservation $PullHead "CHANGE_SCOPE_CHECK_INCOMPLETE" ([pscustomobject]@{ checkCandidateCount = 1; checkCandidates = $candidates; reason = "CHANGE_SCOPE_CHECK_INCOMPLETE" })
  }
  $repositoryPattern = [regex]::Escape($Repository)
  $urlMatch = [regex]::Match([string]$check.detailsUrl, "^https://github\.com/$repositoryPattern/actions/runs/(?<run>[0-9]+)/job/(?<job>[0-9]+)(?:\?.*)?$")
  $runId = [long]0
  $jobId = [long]0
  if (-not $urlMatch.Success -or
      -not [long]::TryParse($urlMatch.Groups["run"].Value, [ref]$runId) -or $runId -lt 1 -or
      -not [long]::TryParse($urlMatch.Groups["job"].Value, [ref]$jobId) -or $jobId -lt 1 -or
      [long]$check.databaseId -ne $jobId) {
    return New-FailClosedChangeScopeObservation $PullHead "CHANGE_SCOPE_CHECK_IDENTITY_INVALID" ([pscustomobject]@{ checkCandidateCount = 1; checkCandidates = $candidates; reason = "CHANGE_SCOPE_CHECK_IDENTITY_INVALID" })
  }

  $owner, $name = $Repository.Split("/")
  $jobResult = Invoke-GhRestJson @("repos/$owner/$name/actions/jobs/$jobId")
  $runResult = Invoke-GhRestJson @("repos/$owner/$name/actions/runs/$runId")
  if (-not $jobResult.complete -or -not $runResult.complete) {
    return New-FailClosedChangeScopeObservation $PullHead "CHANGE_SCOPE_PROVIDER_UNREADABLE" ([pscustomobject]@{ checkCandidateCount = 1; checkCandidates = $candidates; reason = "CHANGE_SCOPE_PROVIDER_UNREADABLE" })
  }
  $job = $jobResult.value
  $run = $runResult.value
  $pullRequests = $null
  $pullRequestsProperty = if ($run -is [Collections.IDictionary]) { $null } elseif ($run) { $run.PSObject.Properties["pull_requests"] } else { $null }
  if ($null -ne $pullRequestsProperty -and $pullRequestsProperty.Value -is [Array]) {
    $pullRequests = [object[]]@($pullRequestsProperty.Value)
  }
  $matchingPulls = [object[]]@()
  if ($null -ne $pullRequests) {
    $matchingPulls = [object[]]@($pullRequests | Where-Object {
        (Test-ObjectProperty $_ "number") -and (Test-WholeNumber (Get-ObjectValue $_ "number") 1) -and
        [long](Get-ObjectValue $_ "number") -eq $Pr -and
        (Get-ObjectValue (Get-ObjectValue $_ "head") "sha") -ceq $PullHead
      })
  }
  $jobIdentityComplete =
    (Test-WholeNumber (Get-ObjectValue $job "id") 1) -and [long](Get-ObjectValue $job "id") -eq $jobId -and
    (Test-WholeNumber (Get-ObjectValue $job "run_id") 1) -and [long](Get-ObjectValue $job "run_id") -eq $runId -and
    [string](Get-ObjectValue $job "name") -ceq "Change Scope" -and
    [string](Get-ObjectValue $job "status") -ceq "completed" -and
    [string](Get-ObjectValue $job "conclusion") -ceq "success" -and
    [string](Get-ObjectValue $job "html_url") -ceq [string]$check.detailsUrl
  $runIdentityComplete =
    (Test-WholeNumber (Get-ObjectValue $run "id") 1) -and [long](Get-ObjectValue $run "id") -eq $runId -and
    [string](Get-ObjectValue $run "event") -ceq "pull_request" -and
    [string](Get-ObjectValue $run "status") -ceq "completed" -and
    [string](Get-ObjectValue $run "conclusion") -ceq "success" -and
    [string](Get-ObjectValue $run "path") -ceq ".github/workflows/platform-pr.yml" -and
    (Test-WholeNumber (Get-ObjectValue $run "run_attempt") 1)
  if (-not $jobIdentityComplete) {
    return New-FailClosedChangeScopeObservation $PullHead "CHANGE_SCOPE_JOB_MISMATCH" ([pscustomobject]@{ checkCandidateCount = 1; checkCandidates = $candidates; reason = "CHANGE_SCOPE_JOB_MISMATCH" })
  }
  if (-not $runIdentityComplete) {
    return New-FailClosedChangeScopeObservation $PullHead "CHANGE_SCOPE_RUN_MISMATCH" ([pscustomobject]@{ checkCandidateCount = 1; checkCandidates = $candidates; reason = "CHANGE_SCOPE_RUN_MISMATCH" })
  }
  $jobRunAttempt = Get-ObjectValue $job "run_attempt"
  $workflowRunAttempt = Get-ObjectValue $run "run_attempt"
  if (-not (Test-WholeNumber $jobRunAttempt 1) -or
      [long]$jobRunAttempt -ne [long]$workflowRunAttempt) {
    return New-FailClosedChangeScopeObservation $PullHead "CHANGE_SCOPE_ATTEMPT_MISMATCH" ([pscustomobject]@{ checkCandidateCount = 1; checkCandidates = $candidates; reason = "CHANGE_SCOPE_ATTEMPT_MISMATCH" })
  }
  if ([string](Get-ObjectValue $job "head_sha") -cne $PullHead -or
      [string](Get-ObjectValue $run "head_sha") -cne $PullHead) {
    return New-FailClosedChangeScopeObservation $PullHead "CHANGE_SCOPE_HEAD_MISMATCH" ([pscustomobject]@{ checkCandidateCount = 1; checkCandidates = $candidates; reason = "CHANGE_SCOPE_HEAD_MISMATCH" })
  }
  if ($null -eq $pullRequests) {
    return New-FailClosedChangeScopeObservation $PullHead "CHANGE_SCOPE_PULL_REQUESTS_MALFORMED" ([pscustomobject]@{ checkCandidateCount = 1; checkCandidates = $candidates; reason = "CHANGE_SCOPE_PULL_REQUESTS_MALFORMED" })
  }
  if ($pullRequests.Count -ne 1) {
    return New-FailClosedChangeScopeObservation $PullHead "CHANGE_SCOPE_PULL_REQUEST_COUNT_MISMATCH" ([pscustomobject]@{ checkCandidateCount = 1; checkCandidates = $candidates; reason = "CHANGE_SCOPE_PULL_REQUEST_COUNT_MISMATCH" })
  }
  if ($matchingPulls.Count -ne 1) {
    return New-FailClosedChangeScopeObservation $PullHead "CHANGE_SCOPE_HEAD_MISMATCH" ([pscustomobject]@{ checkCandidateCount = 1; checkCandidates = $candidates; reason = "CHANGE_SCOPE_HEAD_MISMATCH" })
  }

  $owningStepComplete = $false
  :owningStep do {
    # Read the property directly: the generic value helper enumerates arrays.
    $steps = $Job.steps
    if ($steps -isnot [Array]) { break owningStep }
    $owning = @($steps | Where-Object { (Get-ObjectValue $_ 'name') -ceq 'Resolve changed surface' })
    if ($owning.Count -ne 1) { break owningStep }
    $step = $owning[0]
    if ((Get-ObjectValue $step 'status') -cne 'completed' -or
        (Get-ObjectValue $step 'conclusion') -cne 'success' -or
        -not (Test-WholeNumber (Get-ObjectValue $step 'number') 1)) { break owningStep }
    foreach ($timedOwner in @($Job, $step)) {
      if (-not (Test-RequiredCheckInstant (Get-ObjectValue $timedOwner 'started_at')) -or
          -not (Test-RequiredCheckInstant (Get-ObjectValue $timedOwner 'completed_at'))) { break owningStep }
    }
    # GitHub records successful zero-second steps. Ordered inclusive instants,
    # bounded by the owning job, preserve that native second precision.
    $jobStart = [datetimeoffset]::Parse($Job.started_at)
    $jobEnd = [datetimeoffset]::Parse($Job.completed_at)
    $stepStart = [datetimeoffset]::Parse($step.started_at)
    $stepEnd = [datetimeoffset]::Parse($step.completed_at)
    $owningStepComplete = $jobStart -le $stepStart -and $stepStart -le $stepEnd -and $stepEnd -le $jobEnd
  } while ($false)
  if (-not $owningStepComplete) {
    return New-FailClosedChangeScopeObservation $PullHead "CHANGE_SCOPE_STEP_INCOMPLETE" ([pscustomobject]@{ checkCandidateCount = 1; checkCandidates = $candidates; reason = "CHANGE_SCOPE_STEP_INCOMPLETE" })
  }
  $logResult = Invoke-ExternalProcess $GhCommand @("api", "repos/$owner/$name/actions/jobs/$jobId/logs")
  if ($logResult.exitCode -ne 0 -or [string]::IsNullOrWhiteSpace($logResult.stdout) -or
      [Text.UTF8Encoding]::new($false).GetByteCount([string]$logResult.stdout) -gt 2097152) {
    return New-FailClosedChangeScopeObservation $PullHead "CHANGE_SCOPE_LOG_UNREADABLE" ([pscustomobject]@{ checkCandidateCount = 1; checkCandidates = $candidates; reason = "CHANGE_SCOPE_LOG_UNREADABLE" })
  }
  $outputs = [object[]]@(Get-ChangeScopeOutputMaps ([string]$logResult.stdout))
  if ($outputs.Count -ne 1) {
    $outputReason = if ($outputs.Count -eq 0) { "CHANGE_SCOPE_OUTPUT_MISSING" } else { "CHANGE_SCOPE_OUTPUT_AMBIGUOUS" }
    return New-FailClosedChangeScopeObservation $PullHead $outputReason ([pscustomobject]@{ checkCandidateCount = 1; checkCandidates = $candidates; reason = $outputReason })
  }
  $output = $outputs[0]
  $deploy = [string](Get-ObjectValue $output.value "deploy")
  [pscustomobject][ordered]@{
    schemaVersion = "pr-change-scope-observation/v1"
    classification = if ($deploy -ceq "false") { "non-deployable" } else { "deployable" }
    proven = $true
    reason = if ($deploy -ceq "false") { "CHANGE_SCOPE_EXACT_HEAD_NON_DEPLOYABLE" } else { "CHANGE_SCOPE_EXACT_HEAD_DEPLOYABLE" }
    requestedHead = $PullHead
    evaluatedHead = $PullHead
    checkCandidateCount = 1
    checkCandidates = $candidates
    evidence = [ordered]@{
      checkRunId = $jobId
      jobId = $jobId
      workflowRunId = $runId
      jobRunAttempt = [long]$jobRunAttempt
      workflowRunAttempt = [long]$workflowRunAttempt
      workflowPath = [string](Get-ObjectValue $run "path")
      event = [string](Get-ObjectValue $run "event")
      pr = $Pr
      head = $PullHead
      detailsUrl = [string]$check.detailsUrl
      outputSha256 = Get-Sha256 ([Text.UTF8Encoding]::new($false).GetBytes([string]$output.raw))
      deploy = $deploy -ceq "true"
      changedFilesCount = @($output.changedFiles).Count
      changedFiles = [string[]]@($output.changedFiles)
    }
    sourceReason = $null
  }
}

function Get-BreakerRepairAuthorityRecord {
  $legacyPresent = Test-Path -LiteralPath $frontierAuthorityPath -PathType Leaf
  $retryPresent = Test-Path -LiteralPath $frontierRetryAuthorityPath -PathType Leaf
  if ($legacyPresent -and $retryPresent) {
    return [ordered]@{ present = $true; complete = $false; reason = "AUTHORITY_RECORD_AMBIGUOUS"; kind = "ambiguous"; raw = $null }
  }
  if ($legacyPresent) {
    # The #7476 record was consumed and removed. Its fixture contract remains
    # regression evidence, but recreating the production file grants nothing.
    return [ordered]@{ present = $true; complete = $false; reason = "CONSUMED_AUTHORITY_FORBIDDEN"; kind = "consumed"; raw = $null }
  }
  if (-not $retryPresent) {
    return [ordered]@{ present = $false; complete = $true; reason = "AUTHORITY_RECORD_ABSENT"; raw = $null }
  }
  try {
    $bytes = [IO.File]::ReadAllBytes($frontierRetryAuthorityPath)
    $raw = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    [ordered]@{ present = $true; complete = $true; reason = "RETRY_AUTHORITY_RECORD_READ"; kind = "retry"; raw = $raw }
  } catch {
    [ordered]@{ present = $true; complete = $false; reason = "RETRY_AUTHORITY_RECORD_UNREADABLE"; kind = "retry"; raw = $null }
  }
}

function Invoke-GhRestJson([string[]]$Arguments) {
  $result = Invoke-ExternalProcess $GhCommand (@("api") + $Arguments)
  if ($result.exitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.stdout)) {
    return [ordered]@{ complete = $false; value = $null }
  }
  try { [ordered]@{ complete = $true; value = ($result.stdout | ConvertFrom-Json -Depth 100 -DateKind String -NoEnumerate -ErrorAction Stop) } }
  catch { [ordered]@{ complete = $false; value = $null } }
}

function Get-RestCollection([string]$Endpoint) {
  $all = [Collections.Generic.List[object]]::new()
  for ($page = 1; $page -le 100; $page++) {
    $joiner = if ($Endpoint.Contains("?")) { "&" } else { "?" }
    $response = Invoke-GhRestJson @("$Endpoint${joiner}per_page=100&page=$page")
    if (-not $response.complete -or $response.value -isnot [Array]) { return [ordered]@{ complete = $false; values = @() } }
    $items = @($response.value)
    foreach ($item in $items) { $all.Add($item) }
    if ($items.Count -lt 100) { return [ordered]@{ complete = $true; values = @($all) } }
  }
  [ordered]@{ complete = $false; values = @() }
}

function Get-PagedGraphConnection([string]$Query, [hashtable]$Variables, [scriptblock]$Selector) {
  $all = [Collections.Generic.List[object]]::new()
  $cursor = $null
  $expectedTotal = $null
  for ($page = 1; $page -le 100; $page++) {
    $vars = @{} + $Variables
    if ($cursor) { $vars.cursor = $cursor }
    $result = Invoke-GhGraphQl $Query $vars
    if (-not $result.complete) { return [ordered]@{ complete = $false; totalCount = 0; nodes = @() } }
    $connection = & $Selector $result.payload
    if (-not (Test-ExactKeys $connection @("totalCount", "pageInfo", "nodes")) -or
        -not (Test-ExactKeys $connection.pageInfo @("hasNextPage", "endCursor")) -or
        -not (Test-WholeNumber $connection.totalCount 0) -or
        $connection.nodes -isnot [Array] -or
        $connection.pageInfo.hasNextPage -isnot [bool]) {
      return [ordered]@{ complete = $false; totalCount = 0; nodes = @() }
    }
    if ($null -eq $expectedTotal) { $expectedTotal = [long]$connection.totalCount }
    elseif ($expectedTotal -ne [long]$connection.totalCount) { return [ordered]@{ complete = $false; totalCount = 0; nodes = @() } }
    foreach ($node in @($connection.nodes)) { $all.Add($node) }
    if ($connection.pageInfo.hasNextPage -eq $false) {
      return [ordered]@{ complete = $all.Count -eq $expectedTotal; totalCount = $expectedTotal; nodes = @($all) }
    }
    $next = [string]$connection.pageInfo.endCursor
    if ([string]::IsNullOrWhiteSpace($next) -or $next -ceq $cursor) { return [ordered]@{ complete = $false; totalCount = 0; nodes = @() } }
    $cursor = $next
  }
  [ordered]@{ complete = $false; totalCount = 0; nodes = @() }
}

function New-IncompleteDeployObservation(
  [object[]]$NonAuthority = @(),
  [Nullable[long]]$UnobservableRunId = $null
) {
  [pscustomobject][ordered]@{
    complete = $false
    reason = "DEPLOY_AUTHORITY_UNREADABLE"
    status = $null
    conclusion = $null
    runId = $null
    jobId = $null
    headSha = $null
    createdAt = $null
    nonAuthority = @($NonAuthority)
    unobservableRunId = $UnobservableRunId
  }
}

function Get-PlatformDeployObservation {
  $owner, $name = $Repository.Split("/")
  $listResult = Invoke-ExternalProcess $GhCommand @(
    "run", "list", "-R", $Repository, "--workflow", "Platform Deploy",
    "--event", "workflow_dispatch", "--limit", "10",
    "--json", "status,conclusion,createdAt,databaseId,headSha"
  )
  if ($listResult.exitCode -ne 0 -or [string]::IsNullOrWhiteSpace($listResult.stdout)) {
    return New-IncompleteDeployObservation
  }
  try {
    $runs = @($listResult.stdout | ConvertFrom-Json -DateKind String -ErrorAction Stop)
  } catch {
    return New-IncompleteDeployObservation
  }
  if ($runs.Count -lt 1 -or $runs.Count -gt 10) {
    return New-IncompleteDeployObservation
  }

  $nonAuthority = [Collections.Generic.List[object]]::new()
  $seenRunIds = @{}
  $previousCreated = $null
  $previousRunId = [long]::MaxValue
  foreach ($run in $runs) {
    if (-not (Test-ObjectProperty $run "databaseId") -or
        -not (Test-WholeNumber $run.databaseId 1) -or
        -not (Test-ObjectProperty $run "createdAt") -or
        -not (Test-ObjectProperty $run "status") -or
        -not (Test-ObjectProperty $run "conclusion") -or
        -not (Test-ObjectProperty $run "headSha")) {
      return New-IncompleteDeployObservation @($nonAuthority)
    }
    $runId = [long]$run.databaseId
    $created = ConvertTo-ReviewInstant ([string]$run.createdAt)
    if ($null -eq $created -or
        [string]::IsNullOrWhiteSpace([string]$run.status) -or
        [string]$run.headSha -cnotmatch "^[a-f0-9]{40}$" -or
        $seenRunIds.ContainsKey($runId) -or
        ($null -ne $previousCreated -and $created -gt $previousCreated) -or
        ($null -ne $previousCreated -and $created -eq $previousCreated -and $runId -ge $previousRunId)) {
      return New-IncompleteDeployObservation @($nonAuthority) $runId
    }
    $seenRunIds[$runId] = $true
    $previousCreated = $created
    $previousRunId = $runId

    $jobsResult = Invoke-ExternalProcess $GhCommand @(
      "api",
      "/repos/$owner/$name/actions/runs/$runId/jobs?filter=latest&per_page=100",
      "-H", "Accept: application/vnd.github+json"
    )
    if ($jobsResult.exitCode -ne 0 -or [string]::IsNullOrWhiteSpace($jobsResult.stdout)) {
      return New-IncompleteDeployObservation @($nonAuthority) $runId
    }
    try {
      $jobsPayload = $jobsResult.stdout | ConvertFrom-Json -DateKind String -ErrorAction Stop
    } catch {
      return New-IncompleteDeployObservation @($nonAuthority) $runId
    }
    if (-not (Test-ObjectProperty $jobsPayload "total_count") -or
        -not (Test-WholeNumber $jobsPayload.total_count 0) -or
        [long]$jobsPayload.total_count -gt 100 -or
        -not (Test-ObjectProperty $jobsPayload "jobs")) {
      return New-IncompleteDeployObservation @($nonAuthority) $runId
    }
    $jobs = @($jobsPayload.jobs)
    if ($jobs.Count -ne [long]$jobsPayload.total_count) {
      return New-IncompleteDeployObservation @($nonAuthority) $runId
    }
    foreach ($job in $jobs) {
      if (-not (Test-ObjectProperty $job "name") -or
          [string]::IsNullOrWhiteSpace([string]$job.name)) {
        return New-IncompleteDeployObservation @($nonAuthority) $runId
      }
    }
    $stagingJobs = @($jobs | Where-Object { [string]$_.name -ceq "Deploy Staging" })
    if ($stagingJobs.Count -gt 1) {
      return New-IncompleteDeployObservation @($nonAuthority) $runId
    }
    if ($stagingJobs.Count -eq 0) {
      if ($jobs.Count -gt 0 -and
          [string]$run.status -ceq "completed" -and
          [string]$run.conclusion -cne "cancelled") {
        return New-IncompleteDeployObservation @($nonAuthority) $runId
      }
      $nonAuthority.Add([pscustomobject][ordered]@{
          runId = $runId
          reason = $(if ($jobs.Count -eq 0) { "RUN_HAS_ZERO_JOBS" } else { "DEPLOY_STAGING_JOB_ABSENT" })
          status = [string]$run.status
          conclusion = [string]$run.conclusion
        })
      continue
    }

    $staging = $stagingJobs[0]
    if (-not (Test-ObjectProperty $staging "id") -or
        -not (Test-WholeNumber $staging.id 1) -or
        -not (Test-ObjectProperty $staging "status") -or
        -not (Test-ObjectProperty $staging "conclusion") -or
        -not (Test-ObjectProperty $staging "steps") -or
        [string]::IsNullOrWhiteSpace([string]$staging.status)) {
      return New-IncompleteDeployObservation @($nonAuthority) $runId
    }
    $jobId = [long]$staging.id
    $steps = @($staging.steps)
    if ($steps.Count -eq 0) {
      $nonAuthority.Add([pscustomobject][ordered]@{
          runId = $runId
          jobId = $jobId
          reason = if ([string]$staging.status -ceq "queued") {
            "DEPLOY_STAGING_QUEUED"
          } elseif ([string]$staging.conclusion -ceq "skipped") {
            "DEPLOY_STAGING_SKIPPED"
          } elseif ([string]$staging.conclusion -ceq "cancelled") {
            "DEPLOY_STAGING_CANCELLED_BEFORE_START"
          } else {
            "DEPLOY_STAGING_NOT_EXECUTED"
          }
          status = [string]$staging.status
          conclusion = [string]$staging.conclusion
        })
      continue
    }

    # An executing deploy has not replaced the latest completed health authority.
    if ([string]$staging.status -ceq "in_progress") {
      $nonAuthority.Add([pscustomobject][ordered]@{
          runId = $runId
          jobId = $jobId
          reason = "DEPLOY_STAGING_IN_PROGRESS"
          status = [string]$staging.status
          conclusion = [string]$staging.conclusion
        })
      continue
    }
    if ([string]$staging.status -cne "completed" -or
        [string]::IsNullOrWhiteSpace([string]$staging.conclusion)) {
      return New-IncompleteDeployObservation @($nonAuthority) $runId
    }

    return [pscustomobject][ordered]@{
      complete = $true
      reason = "DEPLOY_AUTHORITY_OBSERVED"
      status = [string]$staging.status
      conclusion = [string]$staging.conclusion
      runId = $runId
      jobId = $jobId
      headSha = [string]$run.headSha
      createdAt = $created.ToString("o")
      nonAuthority = @($nonAuthority)
      unobservableRunId = $null
    }
  }
  return New-IncompleteDeployObservation @($nonAuthority)
}

function Get-ProductionObservation {
  $owner, $name = $Repository.Split("/")
  $query = @'
query($owner:String!, $name:String!, $pr:Int!, $cursor:String) {
  repository(owner:$owner, name:$name) {
    defaultBranchRef { name target { ... on Commit { oid } } }
    pullRequest(number:$pr) {
      id
      number
      state
      isDraft
      headRefOid
      baseRefName
      mergeQueueEntry { id }
      baseRef {
        name
        branchProtectionRule {
          requiresStatusChecks
          requiredStatusCheckContexts
        }
      }
      commits(last:1) {
        totalCount
        nodes {
          commit {
            oid
            statusCheckRollup {
              state
              contexts(first:100,after:$cursor) {
                totalCount
                pageInfo { hasNextPage endCursor }
                nodes {
                  __typename
                  ... on CheckRun {
                    name
                    status
                    conclusion
                    databaseId
                    detailsUrl
                    completedAt
                    checkSuite {
                      app { databaseId }
                      workflowRun { workflow { databaseId } }
                    }
                  }
                  ... on StatusContext { context state }
                }
              }
            }
          }
        }
      }
      closingIssuesReferences(first:20) {
        totalCount
        pageInfo { hasNextPage endCursor }
        nodes {
          number
          state
          blockedBy(first:50) {
            totalCount
            pageInfo { hasNextPage endCursor }
            nodes { number state }
          }
        }
      }
    }
  }
}
'@
  $graph = Invoke-GhGraphQl $query @{ owner = $owner; name = $name; pr = $Pr }
  if (-not $graph.complete) {
    return [pscustomobject][ordered]@{
      complete = $false
      reason = $graph.reason
      detail = @($graph.payload.errors | ForEach-Object { [string]$_.message }) -join "; "
      pr = $null
      deploy = $null
      breaker = $null
    }
  }
  $repositoryObservation = $graph.payload.data.repository
  $pull = $repositoryObservation.pullRequest
  if ($null -eq $pull) {
    return [pscustomobject][ordered]@{ complete = $false; reason = "PR_NOT_OBSERVABLE"; pr = $null; deploy = $null; breaker = $null }
  }

  $closingComplete = Test-ConnectionComplete $pull.closingIssuesReferences
  $closingIssues = @()
  foreach ($issue in @($pull.closingIssuesReferences.nodes)) {
    $blockersComplete = Test-ConnectionComplete $issue.blockedBy
    $closingComplete = $closingComplete -and $blockersComplete
    $closingIssues += [ordered]@{
      number = $issue.number
      state = [string]$issue.state
      blockersComplete = $blockersComplete
      blockers = @($issue.blockedBy.nodes | ForEach-Object {
          [ordered]@{ number = $_.number; state = [string]$_.state }
        })
    }
  }

  $commitNodes = @($pull.commits.nodes)
  $commit = if ($commitNodes.Count -eq 1) { $commitNodes[0].commit } else { $null }
  $contextsConnection = if ($commit -and $commit.statusCheckRollup) { $commit.statusCheckRollup.contexts } else { $null }
  $contextsPage = $contextsConnection
  $allContexts = [Collections.Generic.List[object]]::new()
  $cursor = $null
  $seenCursors = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  $expectedTotal = $null
  $contextsComplete = $false
  for ($page = 1; $page -le 100; $page++) {
    if (-not (Test-ExactKeys $contextsPage @("totalCount", "pageInfo", "nodes")) -or
        -not (Test-ExactKeys $contextsPage.pageInfo @("hasNextPage", "endCursor")) -or
        -not (Test-WholeNumber $contextsPage.totalCount 0) -or
        $contextsPage.nodes -isnot [Array] -or
        $contextsPage.pageInfo.hasNextPage -isnot [bool]) { break }
    if ($null -eq $expectedTotal) { $expectedTotal = [long]$contextsPage.totalCount }
    elseif ($expectedTotal -ne [long]$contextsPage.totalCount) { break }
    $next = [string]$contextsPage.pageInfo.endCursor
    if (-not [string]::IsNullOrWhiteSpace($next) -and -not $seenCursors.Add($next)) { break }
    foreach ($context in @($contextsPage.nodes)) { $allContexts.Add($context) }
    if (-not $contextsPage.pageInfo.hasNextPage) {
      $contextsComplete = $allContexts.Count -eq $expectedTotal
    }
    if (-not $contextsPage.pageInfo.hasNextPage) { break }
    if ($allContexts.Count -ge $expectedTotal -or [string]::IsNullOrWhiteSpace($next) -or $page -eq 100) { break }
    $cursor = $next
    $nextGraph = Invoke-GhGraphQl $query @{ owner = $owner; name = $name; pr = $Pr; cursor = $cursor }
    if (-not $nextGraph.complete) { break }
    $nextPull = $nextGraph.payload.data.repository.pullRequest
    $nextCommits = @($nextPull.commits.nodes)
    if ([string]$nextPull.headRefOid -cne [string]$pull.headRefOid -or $nextCommits.Count -ne 1 -or
        [string]$nextCommits[0].commit.oid -cne [string]$commit.oid) { break }
    $contextsPage = $nextCommits[0].commit.statusCheckRollup.contexts
  }
  $contextsConnection = [ordered]@{ totalCount = $expectedTotal; nodes = @($allContexts) }
  $checksComplete = $null -ne $commit -and
    [string]$commit.oid -ceq [string]$pull.headRefOid -and
    $contextsComplete
  $checks = @()
  $changeScopeCheckCandidates = [Collections.Generic.List[object]]::new()
  foreach ($context in @($contextsConnection.nodes)) {
    if ([string]$context.__typename -ceq "CheckRun") {
      $checks += ConvertTo-RequiredCheckObservation $context
      if ($context.name -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$context.name)) {
        $checksComplete = $false
      }
      if ([string]$context.name -ceq "Change Scope") {
        $changeScopeCheckCandidates.Add([ordered]@{
            databaseId = if (Test-ObjectProperty $context "databaseId") { $context.databaseId } else { $null }
            detailsUrl = if (Test-ObjectProperty $context "detailsUrl") { [string]$context.detailsUrl } else { $null }
            name = [string]$context.name
            status = [string]$context.status
            conclusion = [string]$context.conclusion
          })
      }
    } elseif ([string]$context.__typename -ceq "StatusContext") {
      $checks += ConvertTo-RequiredCheckObservation $context
      if ($context.context -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$context.context)) {
        $checksComplete = $false
      }
    } else {
      $checksComplete = $false
    }
  }

  $protection = $pull.baseRef.branchProtectionRule
  $requiredContexts = if ($protection) { @($protection.requiredStatusCheckContexts | ForEach-Object { [string]$_ }) } else { @() }
  $branchProtectionObserved = $null -ne $protection -and $protection.requiresStatusChecks -is [bool]

  $deploy = Get-PlatformDeployObservation
  $changeScope = Get-HostedChangeScopeObservation ([string]$pull.headRefOid) ([object[]]@($changeScopeCheckCandidates))

  $history = Read-ExactHeadReviewHistory -Path $HistoryPath -MaxRows $MaxHistoryRows -MaxBytes $MaxHistoryBytes
  $breaker = Get-PipelineBreakerObservation $history
  [pscustomobject][ordered]@{
    complete = $closingComplete -and $checksComplete -and $deploy.complete -and $breaker.complete
    reason = if (-not $closingComplete) {
      "ISSUE_DEPENDENCY_PAGINATION_INCOMPLETE"
    } elseif (-not $checksComplete) {
      "CHECK_PAGINATION_INCOMPLETE"
    } elseif (-not $deploy.complete) {
      "DEPLOY_AUTHORITY_UNREADABLE"
    } elseif (-not $breaker.complete) {
      $breaker.reason
    } else {
      "OBSERVATION_COMPLETE"
    }
    pr = [ordered]@{
      id = [string]$pull.id
      number = $pull.number
      state = [string]$pull.state
      isDraft = $pull.isDraft
      head = [string]$pull.headRefOid
      baseRefName = [string]$pull.baseRefName
      baseHead = [string]$repositoryObservation.defaultBranchRef.target.oid
      mergeQueueEntryId = if ($pull.mergeQueueEntry) { [string]$pull.mergeQueueEntry.id } else { $null }
      branchProtectionObserved = $branchProtectionObserved
      requiresStatusChecks = if ($protection) { $protection.requiresStatusChecks } else { $null }
      requiredContexts = @($requiredContexts)
      statusRollupState = if ($commit.statusCheckRollup) { [string]$commit.statusCheckRollup.state } else { $null }
      checkCollection = [ordered]@{
        exactHead = if ($commit) { [string]$commit.oid } else { $null }
        totalCount = if ($contextsConnection -and (Test-WholeNumber $contextsConnection.totalCount 0)) { [long]$contextsConnection.totalCount } else { $null }
        returnedCount = @($contextsConnection.nodes).Count
        complete = $checksComplete
      }
      checks = @($checks)
      closingIssues = @($closingIssues)
    }
    deploy = $deploy
    breaker = $breaker
    changeScope = $changeScope
  }
}

function Get-PipelineBreakerObservation($History) {
  if (-not $History.complete) {
    return [pscustomobject][ordered]@{ complete = $false; healthy = $null; reason = $History.reason; open = @() }
  }
  $events = [Collections.Generic.List[object]]::new()
  foreach ($entry in @($History.rows)) {
    $row = $entry.value
    if ([string]$row.kind -notin @("breaker-open", "breaker-clear")) { continue }
    $instant = ConvertTo-ReviewInstant ([string]$row.ts)
    if ($null -eq $instant) {
      return [pscustomobject][ordered]@{ complete = $false; healthy = $null; reason = "BREAKER_HISTORY_MALFORMED"; open = @() }
    }
    $scope = if ($row.PSObject.Properties["breakerScope"]) { [string]$row.breakerScope } else { "pipeline" }
    if ($scope -notin @("pipeline", "artifact")) {
      return [pscustomobject][ordered]@{ complete = $false; healthy = $null; reason = "BREAKER_SCOPE_INVALID"; open = @() }
    }
    if ($scope -eq "artifact") { continue }
    $issueKey = if ($row.PSObject.Properties["issue"]) { [string]$row.issue } else { "-" }
    $prKey = if ($row.PSObject.Properties["pr"]) { [string]$row.pr } else { "-" }
    $events.Add([pscustomobject][ordered]@{
        instant = $instant
        openTs = [string]$row.ts
        line = [int]$entry.line
        kind = [string]$row.kind
        key = "$issueKey/$prKey"
        rowSha256 = [string]$entry.rawSha256
        byteLength = [int]$entry.byteLength
      })
  }
  $open = @{}
  $unpairedClears = 0
  foreach ($event in @($events | Sort-Object instant, line)) {
    if ($event.kind -eq "breaker-open") {
      $open[$event.key] = $event
    } elseif ($open.ContainsKey($event.key)) {
      $open.Remove($event.key)
    } else {
      $unpairedClears += 1
    }
  }
  [pscustomobject][ordered]@{
    complete = $true
    healthy = $open.Count -eq 0
    reason = if ($open.Count -eq 0) { "BREAKER_HEALTHY" } else { "PIPELINE_BREAKER_OPEN" }
    open = @($open.Keys | Sort-Object)
    openRows = @($open.Values | Sort-Object key | ForEach-Object {
        [ordered]@{
          key = $_.key
          openTs = $_.openTs
          line = $_.line
          rowSha256 = $_.rowSha256
          byteLength = $_.byteLength
        }
      })
    unpairedClears = $unpairedClears
  }
}

function Get-FrontierIssueCore([int]$Issue) {
  $query = @'
query($owner:String!,$name:String!,$issue:Int!){
  repository(owner:$owner,name:$name){
    issue(number:$issue){id number state body updatedAt issueType{name} milestone{number state}}
  }
}
'@
  $owner, $name = $Repository.Split("/")
  $result = Invoke-GhGraphQl $query @{ owner = $owner; name = $name; issue = $Issue }
  if (-not $result.complete -or $null -eq $result.payload.data.repository.issue) { return $null }
  $value = $result.payload.data.repository.issue
  [ordered]@{
    id = [string]$value.id
    number = [int]$value.number
    state = [string]$value.state
    bodySha256 = Get-BodySha256 ([string]$value.body)
    updatedAt = [string]$value.updatedAt
    type = if ($value.issueType) { [string]$value.issueType.name } else { $null }
    milestone = if ($value.milestone) { [ordered]@{ number = [int]$value.milestone.number; state = [string]$value.milestone.state } } else { $null }
  }
}

function Get-FrontierIssueLabels([int]$Issue) {
  $query = @'
query($owner:String!,$name:String!,$issue:Int!,$cursor:String){
  repository(owner:$owner,name:$name){issue(number:$issue){labels(first:100,after:$cursor){totalCount pageInfo{hasNextPage endCursor} nodes{name}}}}
}
'@
  $owner, $name = $Repository.Split("/")
  $connection = Get-PagedGraphConnection $query @{ owner = $owner; name = $name; issue = $Issue } { param($p) $p.data.repository.issue.labels }
  if (-not $connection.complete) { return $null }
  $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($node in @($connection.nodes)) {
    if (-not (Test-ExactKeys $node @("name")) -or $node.name -isnot [string] -or
        [string]::IsNullOrWhiteSpace([string]$node.name) -or -not $names.Add([string]$node.name)) { return $null }
  }
  $result = [string[]]@($names | Sort-Object -CaseSensitive)
  Write-Output -NoEnumerate $result
}

function Get-FrontierIssueBlockers([int]$Issue) {
  $query = @'
query($owner:String!,$name:String!,$issue:Int!,$cursor:String){
  repository(owner:$owner,name:$name){issue(number:$issue){blockedBy(first:100,after:$cursor){totalCount pageInfo{hasNextPage endCursor} nodes{id number state}}}}
}
'@
  $owner, $name = $Repository.Split("/")
  $connection = Get-PagedGraphConnection $query @{ owner = $owner; name = $name; issue = $Issue } { param($p) $p.data.repository.issue.blockedBy }
  if (-not $connection.complete) { return $null }
  $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  $numbers = [Collections.Generic.HashSet[int]]::new()
  $rows = [Collections.Generic.List[object]]::new()
  foreach ($node in @($connection.nodes)) {
    if (-not (Test-ExactKeys $node @("id", "number", "state")) -or
        $node.id -isnot [string] -or [string]$node.id -cnotmatch "^[A-Za-z0-9_=-]+$" -or
        -not (Test-WholeNumber $node.number 1) -or [long]$node.number -gt [int]::MaxValue -or
        $node.state -isnot [string] -or [string]$node.state -notin @("OPEN", "CLOSED") -or
        -not $ids.Add([string]$node.id) -or -not $numbers.Add([int]$node.number)) { return $null }
    $rows.Add([ordered]@{ id = [string]$node.id; number = [int]$node.number; state = [string]$node.state })
  }
  $result = [object[]]@($rows | Sort-Object number)
  Write-Output -NoEnumerate $result
}

function Get-FrontierClosure([int]$Root) {
  $pending = [Collections.Generic.Queue[int]]::new()
  $pending.Enqueue($Root)
  $visited = [Collections.Generic.HashSet[int]]::new()
  $rows = [Collections.Generic.List[object]]::new()
  while ($pending.Count -gt 0 -and $visited.Count -lt 1000) {
    $number = $pending.Dequeue()
    if (-not $visited.Add($number)) { continue }
    $blockers = Get-FrontierIssueBlockers $number
    if ($null -eq $blockers) { return [ordered]@{ complete = $false; rows = @() } }
    foreach ($blocker in @($blockers)) {
      $rows.Add([ordered]@{ parent = $number; id = $blocker.id; number = $blocker.number; state = $blocker.state })
      if (-not $visited.Contains([int]$blocker.number)) { $pending.Enqueue([int]$blocker.number) }
    }
  }
  if ($pending.Count -gt 0) { return [ordered]@{ complete = $false; rows = @() } }
  [ordered]@{ complete = $true; rows = @($rows | Sort-Object parent, number) }
}

function Get-FrontierPullRequestFiles([int]$Number) {
  $query = @'
query($owner:String!,$name:String!,$pr:Int!,$cursor:String){
  repository(owner:$owner,name:$name){pullRequest(number:$pr){files(first:100,after:$cursor){totalCount pageInfo{hasNextPage endCursor} nodes{path}}}}
}
'@
  $owner, $name = $Repository.Split("/")
  $connection = Get-PagedGraphConnection $query @{ owner = $owner; name = $name; pr = $Number } { param($p) $p.data.repository.pullRequest.files }
  if (-not $connection.complete) { return $null }
  $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($node in @($connection.nodes)) {
    if (-not (Test-ExactKeys $node @("path")) -or $node.path -isnot [string]) { return $null }
    $rawPath = [string]$node.path
    $path = $rawPath.ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($rawPath) -or $rawPath.Contains("\", [StringComparison]::Ordinal) -or
        $rawPath.StartsWith("/", [StringComparison]::Ordinal) -or $rawPath.StartsWith("./", [StringComparison]::Ordinal) -or
        @($rawPath.Split("/") | Where-Object { $_ -in @("", ".", "..") }).Count -gt 0 -or
        -not $paths.Add($path)) { return $null }
  }
  $result = [string[]]@($paths | Sort-Object -CaseSensitive)
  Write-Output -NoEnumerate $result
}

function Get-FrontierOpenPullRequests {
  $query = @'
query($owner:String!,$name:String!,$cursor:String){
  repository(owner:$owner,name:$name){pullRequests(first:100,after:$cursor,states:OPEN,orderBy:{field:CREATED_AT,direction:ASC}){
    totalCount pageInfo{hasNextPage endCursor} nodes{id number state isDraft headRefOid autoMergeRequest{enabledAt}}
  }}
}
'@
  $owner, $name = $Repository.Split("/")
  $connection = Get-PagedGraphConnection $query @{ owner = $owner; name = $name } { param($p) $p.data.repository.pullRequests }
  if (-not $connection.complete) { return [ordered]@{ complete = $false; pullRequests = @() } }
  $rows = [Collections.Generic.List[object]]::new()
  foreach ($pull in @($connection.nodes)) {
    $files = Get-FrontierPullRequestFiles ([int]$pull.number)
    if ($null -eq $files -or [string]$pull.headRefOid -cnotmatch "^[a-f0-9]{40}$" -or [string]$pull.state -cne "OPEN") {
      return [ordered]@{ complete = $false; pullRequests = @() }
    }
    $rows.Add([ordered]@{
        id = [string]$pull.id
        number = [int]$pull.number
        isDraft = [bool]$pull.isDraft
        headOid = [string]$pull.headRefOid
        autoMerge = $null -ne $pull.autoMergeRequest
        files = $files
      })
  }
  [ordered]@{ complete = $true; pullRequests = @($rows | Sort-Object number) }
}

function Get-FrontierQueue {
  $query = @'
query($owner:String!,$name:String!,$cursor:String){
  repository(owner:$owner,name:$name){mergeQueue(branch:"main"){
    entries(first:100,after:$cursor){totalCount pageInfo{hasNextPage endCursor} nodes{
      id position state solo jump baseCommit{oid} headCommit{oid} pullRequest{id number headRefOid}
    }}
  }}
}
'@
  $owner, $name = $Repository.Split("/")
  $connection = Get-PagedGraphConnection $query @{ owner = $owner; name = $name } { param($p) $p.data.repository.mergeQueue.entries }
  if (-not $connection.complete) { return [ordered]@{ complete = $false; totalCount = $null; entries = @() } }
  $entries = foreach ($entry in @($connection.nodes)) {
    ConvertTo-QueueEntryObservation $entry
  }
  [ordered]@{ complete = $true; totalCount = [long]$connection.totalCount; entries = @($entries) }
}

function Get-FrontierIssueComments([int]$Issue) {
  $owner, $name = $Repository.Split("/")
  $comments = Get-RestCollection "repos/$owner/$name/issues/$Issue/comments"
  if (-not $comments.complete) { return [ordered]@{ complete = $false; comments = @() } }
  $rows = [Collections.Generic.List[object]]::new()
  foreach ($comment in @($comments.values)) {
    if (-not (Test-WholeNumber $comment.id 1) -or $comment.body -isnot [string] -or
        [string]$comment.html_url -cnotmatch '^https://github\.com/chase-sets/chase-sets/issues/[1-9][0-9]*#issuecomment-[1-9][0-9]*$' -or
        [string]$comment.user.login -cnotmatch '^[A-Za-z0-9-]+$') {
      return [ordered]@{ complete = $false; comments = @() }
    }
    $rows.Add([ordered]@{
        id = [long]$comment.id
        url = [string]$comment.html_url
        author = [string]$comment.user.login
        bodySha256 = Get-BodySha256 ([string]$comment.body)
      })
  }
  [ordered]@{ complete = $true; comments = @($rows | Sort-Object id) }
}

function Get-RetryProviderAuthority {
  $replacement = Get-FrontierIssueCore $frontierRetryIssue
  $decision = Get-FrontierIssueCore $frontierDecisionIssue
  $activation = Get-FrontierIssueCore $frontierActivationIssue
  $activationBlockers = Get-FrontierIssueBlockers $frontierActivationIssue
  $decisionComments = Get-FrontierIssueComments $frontierDecisionIssue
  $complete = $null -ne $replacement -and $null -ne $decision -and $null -ne $activation -and
    $null -ne $activationBlockers -and $decisionComments.complete -eq $true
  [ordered]@{
    complete = $complete
    replacement = $replacement
    decision = $decision
    activation = $activation
    activationBlockersComplete = $null -ne $activationBlockers
    activationBlockers = if ($null -ne $activationBlockers) { @($activationBlockers) } else { @() }
    decisionCommentsComplete = $decisionComments.complete -eq $true
    decisionComments = @($decisionComments.comments)
  }
}

function Get-FrontierConfiguration($RepositoryCore, $OpenPullRequests) {
  $owner, $name = $Repository.Split("/")
  $rulesetList = Get-RestCollection "repos/$owner/$name/rulesets"
  $collaboratorList = Get-RestCollection "repos/$owner/$name/collaborators?affiliation=all"
  $protectionResult = Invoke-GhRestJson @("repos/$owner/$name/branches/main/protection")
  if (-not $rulesetList.complete -or -not $collaboratorList.complete -or -not $protectionResult.complete) {
    return [ordered]@{ complete = $false; value = $null; sha256 = $null }
  }
  $rulesets = [Collections.Generic.List[object]]::new()
  foreach ($summary in @($rulesetList.values | Sort-Object id)) {
    $detailResult = Invoke-GhRestJson @("repos/$owner/$name/rulesets/$([long]$summary.id)")
    if (-not $detailResult.complete) { return [ordered]@{ complete = $false; value = $null; sha256 = $null } }
    $detail = $detailResult.value
    if ([string]$detail.target -cne "branch" -or $null -eq $detail.conditions -or $null -eq $detail.conditions.ref_name) { continue }
    $include = [string[]]@($detail.conditions.ref_name.include | ForEach-Object { [string]$_ })
    $exclude = [string[]]@($detail.conditions.ref_name.exclude | ForEach-Object { [string]$_ })
    $unknownPatterns = @(($include + $exclude) | Where-Object { $_ -notmatch '^refs/heads/[A-Za-z0-9._/-]+$' -and $_ -cne "~DEFAULT_BRANCH" })
    if ($unknownPatterns.Count -gt 0) { return [ordered]@{ complete = $false; value = $null; sha256 = $null } }
    $applies = @($include | Where-Object { $_ -in @("refs/heads/main", "~DEFAULT_BRANCH") }).Count -gt 0 -and
      @($exclude | Where-Object { $_ -in @("refs/heads/main", "~DEFAULT_BRANCH") }).Count -eq 0
    if (-not $applies) { continue }
    if ([string]$detail.enforcement -cne "active" -or @($detail.bypass_actors).Count -ne 0) {
      return [ordered]@{ complete = $false; value = $null; sha256 = $null }
    }
    $rules = [Collections.Generic.List[object]]::new()
    foreach ($rule in @($detail.rules | Sort-Object type)) {
      switch ([string]$rule.type) {
        "required_linear_history" {
          if (-not (Test-ExactKeys $rule @("type"))) { return [ordered]@{ complete = $false; value = $null; sha256 = $null } }
          $rules.Add([ordered]@{ type = "required_linear_history" })
        }
        "non_fast_forward" {
          if (-not (Test-ExactKeys $rule @("type"))) { return [ordered]@{ complete = $false; value = $null; sha256 = $null } }
          $rules.Add([ordered]@{ type = "non_fast_forward" })
        }
        "required_status_checks" {
          $p = $rule.parameters
          if (-not (Test-ExactKeys $rule @("type", "parameters")) -or
              -not (Test-ExactKeys $p @("strict_required_status_checks_policy", "do_not_enforce_on_create", "required_status_checks")) -or
              $p.strict_required_status_checks_policy -ne $true -or $p.do_not_enforce_on_create -ne $false) {
            return [ordered]@{ complete = $false; value = $null; sha256 = $null }
          }
          $checks = @($p.required_status_checks | ForEach-Object {
              if (-not (Test-ExactKeys $_ @("context", "integration_id"))) { throw "configuration rule is not closed" }
              [ordered]@{ context = [string]$_.context; integrationId = [long]$_.integration_id }
            } | Sort-Object context, integrationId)
          if ($checks.Count -ne 1 -or $checks[0].context -cne "PR Required" -or $checks[0].integrationId -ne 15368) {
            return [ordered]@{ complete = $false; value = $null; sha256 = $null }
          }
          $rules.Add([ordered]@{ type = "required_status_checks"; strict = $true; doNotEnforceOnCreate = $false; checks = $checks })
        }
        "merge_queue" {
          $p = $rule.parameters
          if (-not (Test-ExactKeys $rule @("type", "parameters")) -or
              -not (Test-ExactKeys $p @("merge_method", "max_entries_to_build", "min_entries_to_merge", "max_entries_to_merge", "min_entries_to_merge_wait_minutes", "grouping_strategy", "check_response_timeout_minutes"))) {
            return [ordered]@{ complete = $false; value = $null; sha256 = $null }
          }
          $rules.Add([ordered]@{ type = "merge_queue"; mergeMethod = [string]$p.merge_method; maximumEntriesToBuild = [int]$p.max_entries_to_build; maximumEntriesToMerge = [int]$p.max_entries_to_merge; minimumEntriesToMerge = [int]$p.min_entries_to_merge; minimumEntriesToMergeWaitMinutes = [int]$p.min_entries_to_merge_wait_minutes; groupingStrategy = [string]$p.grouping_strategy; checkResponseTimeoutMinutes = [int]$p.check_response_timeout_minutes })
        }
        default { return [ordered]@{ complete = $false; value = $null; sha256 = $null } }
      }
    }
    $rulesets.Add([ordered]@{
        id = [long]$detail.id
        name = [string]$detail.name
        target = [string]$detail.target
        enforcement = [string]$detail.enforcement
        include = [string[]]@($include | Sort-Object -CaseSensitive)
        exclude = [string[]]@($exclude | Sort-Object -CaseSensitive)
        bypassActors = @()
        rules = @($rules)
      })
  }
  $p = $protectionResult.value
  $protection = [ordered]@{
    enforceAdmins = [bool]$p.enforce_admins.enabled
    requiredStatusChecks = [ordered]@{
      strict = [bool]$p.required_status_checks.strict
      contexts = [string[]]@($p.required_status_checks.contexts | ForEach-Object { [string]$_ } | Sort-Object -CaseSensitive)
      checks = @($p.required_status_checks.checks | ForEach-Object { [ordered]@{ context = [string]$_.context; appId = [long]$_.app_id } } | Sort-Object context, appId)
    }
    requiredSignatures = [bool]$p.required_signatures.enabled
    requiredLinearHistory = [bool]$p.required_linear_history.enabled
    requiredConversationResolution = [bool]$p.required_conversation_resolution.enabled
    allowForcePushes = [bool]$p.allow_force_pushes.enabled
    allowDeletions = [bool]$p.allow_deletions.enabled
    blockCreations = [bool]$p.block_creations.enabled
    lockBranch = [bool]$p.lock_branch.enabled
    allowForkSyncing = [bool]$p.allow_fork_syncing.enabled
  }
  $collaborators = @($collaboratorList.values | ForEach-Object {
      [ordered]@{
        login = [string]$_.login
        id = [long]$_.id
        nodeId = [string]$_.node_id
        role = [string]$_.role_name
        permissions = [ordered]@{ admin = [bool]$_.permissions.admin; maintain = [bool]$_.permissions.maintain; push = [bool]$_.permissions.push; triage = [bool]$_.permissions.triage; pull = [bool]$_.permissions.pull }
      }
    } | Sort-Object login)
  $value = [ordered]@{
    schemaVersion = "admission-configuration/v1"
    repository = [ordered]@{ autoMergeAllowed = [bool]$RepositoryCore.autoMergeAllowed; mergeCommitAllowed = [bool]$RepositoryCore.mergeCommitAllowed; rebaseMergeAllowed = [bool]$RepositoryCore.rebaseMergeAllowed; squashMergeAllowed = [bool]$RepositoryCore.squashMergeAllowed; viewerPermission = [string]$RepositoryCore.viewerPermission }
    mergeQueue = $RepositoryCore.mergeQueue
    applicableRulesetCount = $rulesets.Count
    applicableRulesets = @($rulesets)
    classicProtection = $protection
    writers = [ordered]@{
      automatedEnqueueWriters = @(".orchestrator/landing-preflight.ps1")
      openAutoMergeRequestCount = @($OpenPullRequests.pullRequests | Where-Object { $_.autoMerge }).Count
      collaboratorCount = $collaborators.Count
      collaborators = $collaborators
      authorityBoundary = "manual administrator enqueue is detected, never prevented"
    }
  }
  [ordered]@{ complete = $true; value = $value; sha256 = Get-ConfigurationSha256 $value }
}

function Get-RepairFrontierProductionObservation($Observation, $ImmediateQueue = $null) {
  $owner, $name = $Repository.Split("/")
  $query = @'
query($owner:String!,$name:String!){repository(owner:$owner,name:$name){
  autoMergeAllowed mergeCommitAllowed rebaseMergeAllowed squashMergeAllowed viewerPermission
  defaultBranchRef{name target{... on Commit{oid}}}
  mergeQueue(branch:"main"){configuration{mergeMethod maximumEntriesToBuild maximumEntriesToMerge minimumEntriesToMerge minimumEntriesToMergeWaitTime checkResponseTimeout mergingStrategy}}
}}
'@
  $coreResult = Invoke-GhGraphQl $query @{ owner = $owner; name = $name }
  if (-not $coreResult.complete) { return [ordered]@{ complete = $false; reason = "FRONTIER_PROVIDER_UNREADABLE" } }
  $repo = $coreResult.payload.data.repository
  $queueConfiguration = $repo.mergeQueue.configuration
  $repositoryCore = [ordered]@{
    autoMergeAllowed = $repo.autoMergeAllowed
    mergeCommitAllowed = $repo.mergeCommitAllowed
    rebaseMergeAllowed = $repo.rebaseMergeAllowed
    squashMergeAllowed = $repo.squashMergeAllowed
    viewerPermission = [string]$repo.viewerPermission
    mergeQueue = [ordered]@{ mergeMethod = [string]$queueConfiguration.mergeMethod; maximumEntriesToBuild = [int]$queueConfiguration.maximumEntriesToBuild; maximumEntriesToMerge = [int]$queueConfiguration.maximumEntriesToMerge; minimumEntriesToMerge = [int]$queueConfiguration.minimumEntriesToMerge; minimumEntriesToMergeWaitTime = [int]$queueConfiguration.minimumEntriesToMergeWaitTime; checkResponseTimeout = [int]$queueConfiguration.checkResponseTimeout; mergingStrategy = [string]$queueConfiguration.mergingStrategy }
  }
  $defaultOid = [string]$repo.defaultBranchRef.target.oid
  $authorityRecord = Get-BreakerRepairAuthorityRecord
  $authorityRecordValue = if ($authorityRecord.present -eq $true -and $authorityRecord.complete -eq $true) {
    ConvertFrom-ClosedJson ([string]$authorityRecord.raw)
  } else { $null }
  $retryProvider = if ($authorityRecordValue -and [string]$authorityRecordValue.schemaVersion -ceq "breaker-repair-frontier-retry-authority/v1") {
    Get-RetryProviderAuthority
  } else { $null }
  $authority = Get-FrontierIssueCore $frontierAuthorityIssue
  $authorityLabels = Get-FrontierIssueLabels $frontierAuthorityIssue
  $root = Get-FrontierIssueCore $frontierRootIssue
  $repair = Get-FrontierIssueCore $frontierRepairIssue
  $repairLabels = Get-FrontierIssueLabels $frontierRepairIssue
  $repairBlockers = Get-FrontierIssueBlockers $frontierRepairIssue
  $closure = Get-FrontierClosure $frontierRootIssue
  $openPulls = Get-FrontierOpenPullRequests
  $queue = if ($null -ne $ImmediateQueue) { $ImmediateQueue } else { Get-FrontierQueue }
  $candidateFiles = Get-FrontierPullRequestFiles $Pr
  $comparisonResult = Invoke-GhRestJson @("repos/$owner/$name/compare/$defaultOid...$([string]$Observation.pr.head)")
  if ($null -eq $authority -or $null -eq $authorityLabels -or $null -eq $root -or $null -eq $repair -or $null -eq $repairLabels -or
      $null -eq $repairBlockers -or -not $closure.complete -or -not $openPulls.complete -or -not $queue.complete -or
      ($null -ne $retryProvider -and $retryProvider.complete -ne $true) -or
      $null -eq $candidateFiles -or -not $comparisonResult.complete) {
    return [ordered]@{ complete = $false; reason = "FRONTIER_PROVIDER_UNREADABLE" }
  }
  $configuration = Get-FrontierConfiguration $repositoryCore $openPulls
  if (-not $configuration.complete) { return [ordered]@{ complete = $false; reason = "FRONTIER_CONFIGURATION_UNREADABLE" } }
  $collisions = [Collections.Generic.List[object]]::new()
  $candidateSet = [Collections.Generic.HashSet[string]]::new(
    [Collections.Generic.IEnumerable[string]]$candidateFiles,
    [StringComparer]::Ordinal
  )
  foreach ($other in @($openPulls.pullRequests | Where-Object { $_.number -ne $Pr })) {
    foreach ($path in @($other.files)) { if ($candidateSet.Contains([string]$path)) { $collisions.Add([ordered]@{ pr = [int]$other.number; path = [string]$path }) } }
  }
  $comparison = $comparisonResult.value
  [ordered]@{
    complete = $true
    reason = "FRONTIER_OBSERVATION_COMPLETE"
    observedAt = [datetimeoffset]::UtcNow.ToString("o")
    authorityRecord = $authorityRecord
    retryProvider = $retryProvider
    authorityIssue = [ordered]@{ id = $authority.id; number = $authority.number; state = $authority.state; bodySha256 = $authority.bodySha256; type = $authority.type; milestone = $authority.milestone; labels = $authorityLabels }
    root = [ordered]@{ issue = $root; closureComplete = $true; closure = @($closure.rows) }
    repair = [ordered]@{ issue = $repair; labels = $repairLabels; blockersComplete = $true; blockers = @($repairBlockers) }
    candidate = [ordered]@{
      id = [string]$Observation.pr.id; number = [int]$Observation.pr.number; headOid = [string]$Observation.pr.head
      baseOid = $defaultOid; mergeBaseOid = [string]$comparison.merge_base_commit.sha
      comparisonStatus = [string]$comparison.status; filesComplete = $true; files = $candidateFiles
      closingIssuesComplete = $true; closingIssues = @($Observation.pr.closingIssues | ForEach-Object { [int]$_.number })
    }
    defaultOid = $defaultOid
    openPullRequests = $openPulls
    collisions = @($collisions | Sort-Object pr, path)
    queue = $queue
    configuration = $configuration
    breaker = $Observation.breaker
  }
}

function Get-Decision7643ProviderAuthority {
  $owner, $name = $Repository.Split("/")
  $issueResult = Invoke-GhRestJson @("repos/$owner/$name/issues/$decision7643Issue")
  if (-not $issueResult.complete -or $null -eq $issueResult.value) {
    return [ordered]@{ complete = $false; reason = "DECISION_7643_UNREADABLE"; decision = $null; commentsComplete = $false; comments = @() }
  }
  $issue = $issueResult.value
  if (-not (Test-ObjectProperty $issue "node_id") -or $issue.node_id -isnot [string] -or
      -not (Test-ObjectProperty $issue "number") -or -not (Test-WholeNumber $issue.number 1) -or
      -not (Test-ObjectProperty $issue "state") -or $issue.state -isnot [string] -or
      -not (Test-ObjectProperty $issue "state_reason") -or $issue.state_reason -isnot [string] -or
      -not (Test-ObjectProperty $issue "body") -or $issue.body -isnot [string] -or
      -not (Test-ObjectProperty $issue "updated_at") -or $issue.updated_at -isnot [string] -or
      -not (Test-ObjectProperty $issue "closed_at") -or $issue.closed_at -isnot [string] -or
      -not (Test-ObjectProperty $issue "type") -or $null -eq $issue.type -or
      -not (Test-ObjectProperty $issue.type "name") -or $issue.type.name -isnot [string] -or
      -not (Test-ObjectProperty $issue "closed_by") -or $null -eq $issue.closed_by -or
      -not (Test-ObjectProperty $issue.closed_by "login") -or $issue.closed_by.login -isnot [string]) {
    return [ordered]@{ complete = $false; reason = "DECISION_7643_MALFORMED"; decision = $null; commentsComplete = $false; comments = @() }
  }
  $commentsResult = Get-RestCollection "repos/$owner/$name/issues/$decision7643Issue/comments"
  if (-not $commentsResult.complete) {
    return [ordered]@{ complete = $false; reason = "DECISION_7643_COMMENTS_UNREADABLE"; decision = $null; commentsComplete = $false; comments = @() }
  }
  $comments = [Collections.Generic.List[object]]::new()
  foreach ($comment in @($commentsResult.values)) {
    if (-not (Test-ObjectProperty $comment "id") -or -not (Test-WholeNumber $comment.id 1) -or
        -not (Test-ObjectProperty $comment "html_url") -or $comment.html_url -isnot [string] -or
        -not (Test-ObjectProperty $comment "body") -or $comment.body -isnot [string] -or
        -not (Test-ObjectProperty $comment "created_at") -or $comment.created_at -isnot [string] -or
        -not (Test-ObjectProperty $comment "updated_at") -or $comment.updated_at -isnot [string] -or
        -not (Test-ObjectProperty $comment "author_association") -or $comment.author_association -isnot [string] -or
        -not (Test-ObjectProperty $comment "user") -or $null -eq $comment.user -or
        -not (Test-ObjectProperty $comment.user "login") -or $comment.user.login -isnot [string] -or
        -not (Test-ObjectProperty $comment.user "id") -or -not (Test-WholeNumber $comment.user.id 1) -or
        -not (Test-ObjectProperty $comment.user "node_id") -or $comment.user.node_id -isnot [string]) {
      return [ordered]@{ complete = $false; reason = "DECISION_7643_COMMENT_MALFORMED"; decision = $null; commentsComplete = $false; comments = @() }
    }
    $comments.Add([ordered]@{
        id = [long]$comment.id
        url = [string]$comment.html_url
        author = [ordered]@{ login = [string]$comment.user.login; id = [long]$comment.user.id; nodeId = [string]$comment.user.node_id }
        authorAssociation = [string]$comment.author_association
        bodySha256 = Get-BodySha256 ([string]$comment.body)
        createdAt = [string]$comment.created_at
        updatedAt = [string]$comment.updated_at
      })
  }
  [ordered]@{
    complete = $true
    reason = "DECISION_7643_AUTHORITY_COMPLETE"
    decision = [ordered]@{
      id = [string]$issue.node_id
      number = [long]$issue.number
      state = ([string]$issue.state).ToUpperInvariant()
      stateReason = ([string]$issue.state_reason).ToUpperInvariant()
      type = [string]$issue.type.name
      bodySha256 = Get-BodySha256 ([string]$issue.body)
      updatedAt = [string]$issue.updated_at
      closedAt = [string]$issue.closed_at
      closedBy = [string]$issue.closed_by.login
    }
    commentsComplete = $true
    comments = @($comments | Sort-Object id)
  }
}

function Get-Decision7643BreakerAuthority($ObservedBreaker) {
  $history = Read-ExactHeadReviewHistory -Path $HistoryPath -MaxRows $MaxHistoryRows -MaxBytes $MaxHistoryBytes
  if (-not $history.complete) {
    return [ordered]@{ complete = $false; reason = $history.reason; current = $null; row = $null }
  }
  $current = Get-PipelineBreakerObservation $history
  $rows = @($history.rows | Where-Object { [long]$_.line -eq $decision7643BreakerLine })
  $row = if ($rows.Count -eq 1) { $rows[0] } else { $null }
  [ordered]@{
    complete = $current.complete -eq $true -and $rows.Count -eq 1 -and
      (Get-CanonicalSha256 $current) -ceq (Get-CanonicalSha256 $ObservedBreaker)
    reason = if ($rows.Count -eq 1) { "DECISION_7643_BREAKER_OBSERVED" } else { "DECISION_7643_BREAKER_ROW_UNAVAILABLE" }
    current = $current
    row = if ($null -ne $row) {
      [ordered]@{
        line = [long]$row.line
        rowSha256 = [string]$row.rawSha256
        byteLength = [long]$row.byteLength
        kind = [string]$row.value.kind
        ts = [string]$row.value.ts
        issue = $row.value.issue
        pr = $row.value.pr
        outcome = [string]$row.value.outcome
        breakerScope = [string]$row.value.breakerScope
      }
    } else { $null }
  }
}

function Get-Decision7643ProductionObservation($Observation, $ImmediateQueue = $null) {
  $owner, $name = $Repository.Split("/")
  $query = @'
query($owner:String!,$name:String!){repository(owner:$owner,name:$name){
  autoMergeAllowed mergeCommitAllowed rebaseMergeAllowed squashMergeAllowed viewerPermission
  mergeQueue(branch:"main"){configuration{mergeMethod maximumEntriesToBuild maximumEntriesToMerge minimumEntriesToMerge minimumEntriesToMergeWaitTime checkResponseTimeout mergingStrategy}}
}}
'@
  $coreResult = Invoke-GhGraphQl $query @{ owner = $owner; name = $name }
  if (-not $coreResult.complete -or $null -eq $coreResult.payload.data.repository) {
    return [ordered]@{ complete = $false; reason = "DECISION_7643_PROVIDER_UNREADABLE" }
  }
  $repo = $coreResult.payload.data.repository
  $queueConfiguration = $repo.mergeQueue.configuration
  $repositoryCore = [ordered]@{
    autoMergeAllowed = $repo.autoMergeAllowed
    mergeCommitAllowed = $repo.mergeCommitAllowed
    rebaseMergeAllowed = $repo.rebaseMergeAllowed
    squashMergeAllowed = $repo.squashMergeAllowed
    viewerPermission = [string]$repo.viewerPermission
    mergeQueue = [ordered]@{ mergeMethod = [string]$queueConfiguration.mergeMethod; maximumEntriesToBuild = [int]$queueConfiguration.maximumEntriesToBuild; maximumEntriesToMerge = [int]$queueConfiguration.maximumEntriesToMerge; minimumEntriesToMerge = [int]$queueConfiguration.minimumEntriesToMerge; minimumEntriesToMergeWaitTime = [int]$queueConfiguration.minimumEntriesToMergeWaitTime; checkResponseTimeout = [int]$queueConfiguration.checkResponseTimeout; mergingStrategy = [string]$queueConfiguration.mergingStrategy }
  }
  $decision = Get-Decision7643ProviderAuthority
  $breakerAuthority = Get-Decision7643BreakerAuthority $Observation.breaker
  $openPulls = Get-FrontierOpenPullRequests
  $queue = if ($null -ne $ImmediateQueue) { $ImmediateQueue } else { Get-FrontierQueue }
  $candidateFiles = Get-FrontierPullRequestFiles $Pr
  if ($decision.complete -ne $true -or $breakerAuthority.complete -ne $true -or
      -not $openPulls.complete -or -not $queue.complete -or $null -eq $candidateFiles) {
    return [ordered]@{ complete = $false; reason = "DECISION_7643_PROVIDER_UNREADABLE"; decision = $decision; breakerAuthority = $breakerAuthority }
  }
  $configuration = Get-FrontierConfiguration $repositoryCore $openPulls
  if (-not $configuration.complete) {
    return [ordered]@{ complete = $false; reason = "DECISION_7643_CONFIGURATION_UNREADABLE"; decision = $decision; breakerAuthority = $breakerAuthority }
  }
  $collisions = [Collections.Generic.List[object]]::new()
  $candidateSet = [Collections.Generic.HashSet[string]]::new(
    [Collections.Generic.IEnumerable[string]]$candidateFiles,
    [StringComparer]::Ordinal
  )
  foreach ($other in @($openPulls.pullRequests | Where-Object { $_.number -ne $Pr })) {
    foreach ($path in @($other.files)) {
      if ($candidateSet.Contains([string]$path)) { $collisions.Add([ordered]@{ pr = [int]$other.number; path = [string]$path }) }
    }
  }
  [ordered]@{
    complete = $true
    reason = "DECISION_7643_OBSERVATION_COMPLETE"
    observedAt = [datetimeoffset]::UtcNow.ToString("o")
    decision = $decision
    breakerAuthority = $breakerAuthority
    candidate = [ordered]@{
      id = [string]$Observation.pr.id
      number = [int]$Observation.pr.number
      headOid = [string]$Observation.pr.head
      filesComplete = $true
      files = $candidateFiles
    }
    openPullRequests = $openPulls
    collisions = @($collisions | Sort-Object pr, path)
    queue = $queue
    configuration = $configuration
    breaker = $Observation.breaker
  }
}

function Test-AuthorityRecordShape($Record, [datetimeoffset]$ObservedAt) {
  if (-not (Test-ExactKeys $Record @("schemaVersion", "createdAt", "expiresAt", "authority", "breaker", "repair", "candidate", "configurationSha256")) -or
      [string]$Record.schemaVersion -cne "breaker-repair-frontier-authority/v1" -or
      -not (Test-ExactKeys $Record.authority @("issue", "bodySha256")) -or
      -not (Test-ExactKeys $Record.breaker @("key", "openTs", "line", "rowSha256")) -or
      -not (Test-ExactKeys $Record.repair @("rootIssue", "issue", "bodySha256")) -or
      -not (Test-ExactKeys $Record.candidate @("pr", "headOid", "baseOid"))) { return $false }
  if (-not (Test-WholeNumber $Record.authority.issue 1) -or [long]$Record.authority.issue -ne $frontierAuthorityIssue -or
      [string]$Record.authority.bodySha256 -cne $frontierAuthorityBodySha256 -or
      [string]$Record.breaker.key -cne $frontierBreakerKey -or
      [string]$Record.breaker.openTs -cne $frontierBreakerOpenTs -or
      -not (Test-WholeNumber $Record.breaker.line 1) -or [long]$Record.breaker.line -ne $frontierBreakerLine -or
      [string]$Record.breaker.rowSha256 -cne $frontierBreakerRowSha256 -or
      -not (Test-WholeNumber $Record.repair.rootIssue 1) -or [long]$Record.repair.rootIssue -ne $frontierRootIssue -or
      -not (Test-WholeNumber $Record.repair.issue 1) -or [long]$Record.repair.issue -ne $frontierRepairIssue -or
      [string]$Record.repair.bodySha256 -cne $frontierRepairBodySha256 -or
      -not (Test-WholeNumber $Record.candidate.pr 1) -or
      [string]$Record.candidate.headOid -cnotmatch "^[a-f0-9]{40}$" -or
      [string]$Record.candidate.baseOid -cnotmatch "^[a-f0-9]{40}$" -or
      [string]$Record.configurationSha256 -cnotmatch "^[a-f0-9]{64}$") { return $false }
  if ([string]$Record.createdAt -cnotmatch "^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?Z$" -or
      [string]$Record.expiresAt -cnotmatch "^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?Z$") { return $false }
  $created = ConvertTo-ReviewInstant ([string]$Record.createdAt)
  $expires = ConvertTo-ReviewInstant ([string]$Record.expiresAt)
  return $null -ne $created -and $null -ne $expires -and $expires -gt $created -and
    ($expires - $created).TotalSeconds -le 7200 -and $ObservedAt -ge $created -and $ObservedAt -lt $expires
}

function Get-RetryAuthorityIdentity($Record) {
  Get-CanonicalSha256 ([ordered]@{
      schemaVersion = $Record.schemaVersion
      lineage = $Record.lineage
      consumedAttempt = $Record.consumedAttempt
      replacement = $Record.replacement
      decision = $Record.decision
      activation = $Record.activation
      controller = $Record.controller
      breaker = $Record.breaker
      repair = $Record.repair
      candidate = $Record.candidate
      configurationSha256 = $Record.configurationSha256
      attempt = $Record.attempt
      activationCensus = $Record.activationCensus
    })
}

function Get-RetryConsumptionRefName([string]$CandidateHead, [string]$AuthorityIdentity) {
  "$frontierConsumptionNamespace" +
    "lineage-$frontierAuthorityIssue/head-$CandidateHead/attempt-2/authority-$AuthorityIdentity"
}

function Test-RetryAttemptPolicy($Attempt, $SpendTelemetry) {
  if (-not (Test-ExactKeys $Attempt @("ordinal", "consumed", "absoluteCeiling", "nonPass")) -or
      -not (Test-ExactKeys $SpendTelemetry @("status", "billedUsd")) -or
      [long]$Attempt.ordinal -ne 2 -or [long]$Attempt.consumed -ne 1 -or
      [long]$Attempt.absoluteCeiling -ne 2 -or [string]$Attempt.nonPass -cne "PARK" -or
      [string]$SpendTelemetry.status -cnotin @("recorded", "unavailable")) { return $false }
  if ([string]$SpendTelemetry.status -ceq "unavailable") { return $null -eq $SpendTelemetry.billedUsd }
  return [string]$SpendTelemetry.billedUsd -cmatch '^(0|[1-9][0-9]*)(\.[0-9]{1,2})?$'
}

function Test-RetryAuthorityRecordShape($Record, [datetimeoffset]$ObservedAt) {
  if (-not (Test-ExactKeys $Record @(
        "schemaVersion", "createdAt", "expiresAt", "lineage", "consumedAttempt",
        "replacement", "decision", "activation", "breaker", "repair",
        "candidate", "configurationSha256", "attempt", "spendTelemetry",
        "activationCensus", "remoteConsumption"
      )) -or [string]$Record.schemaVersion -cne "breaker-repair-frontier-retry-authority/v1" -or
      -not (Test-ExactKeys $Record.lineage @("rootIssue")) -or
      -not (Test-ExactKeys $Record.consumedAttempt @(
          "pr", "prNodeId", "headOid", "baseOid", "queueEntryId", "enqueuedAt",
          "dequeuedAt", "terminalDecision", "enqueueAttempts", "dequeueAttempts",
          "mutationCount", "controllerHead", "terminalReceiptSha256"
        )) -or
      -not (Test-ExactKeys $Record.replacement @("issue", "nodeId", "bodySha256", "canonicalBodySha256", "updatedAt")) -or
      -not (Test-ExactKeys $Record.decision @(
          "issue", "nodeId", "bodySha256", "updatedAt", "rulingCommentId",
          "rulingCommentUrl", "rulingAuthor", "rulingBodySha256"
        )) -or
      -not (Test-ExactKeys $Record.activation @("issue", "nodeId", "bodySha256", "updatedAt")) -or
      -not (Test-ExactKeys $Record.breaker @("key", "openTs", "line", "rowSha256")) -or
      -not (Test-ExactKeys $Record.repair @("rootIssue", "issue", "bodySha256")) -or
      -not (Test-ExactKeys $Record.candidate @("pr", "prNodeId", "headOid", "baseOid")) -or
      -not (Test-ExactKeys $Record.attempt @("ordinal", "consumed", "absoluteCeiling", "nonPass")) -or
      -not (Test-ExactKeys $Record.spendTelemetry @("status", "billedUsd")) -or
      -not (Test-ExactKeys $Record.activationCensus @(
          "schemaVersion", "complete", "observedAt", "productHead", "workflowCount",
          "workflowPathsSha256", "tagTriggerCount", "tagRulesComplete", "tagRulesetCount"
        )) -or
      -not (Test-ExactKeys $Record.remoteConsumption @(
          "namespace", "lineageRoot", "candidateHead", "attemptOrdinal",
          "authorityIdentity", "expectedRef", "targetOid"
        ))) { return $false }

  $created = ConvertTo-ReviewInstant ([string]$Record.createdAt)
  $expires = ConvertTo-ReviewInstant ([string]$Record.expiresAt)
  $censusAt = ConvertTo-ReviewInstant ([string]$Record.activationCensus.observedAt)
  if ($null -eq $created -or $null -eq $expires -or $null -eq $censusAt -or
      $expires -le $created -or ($expires - $created).TotalSeconds -gt 7200 -or
      $ObservedAt -lt $created -or $ObservedAt -ge $expires -or
      $censusAt -gt $ObservedAt -or ($ObservedAt - $censusAt).TotalMinutes -gt 30) { return $false }

  if ([long]$Record.lineage.rootIssue -ne $frontierAuthorityIssue -or
      [long]$Record.consumedAttempt.pr -ne $frontierConsumedPr -or
      [string]$Record.consumedAttempt.prNodeId -cne $frontierConsumedPrNode -or
      [string]$Record.consumedAttempt.headOid -cne $frontierConsumedHead -or
      [string]$Record.consumedAttempt.baseOid -cne $frontierConsumedBase -or
      [string]$Record.consumedAttempt.queueEntryId -cnotmatch "^[A-Za-z0-9_=-]+$" -or
      [string]$Record.consumedAttempt.enqueuedAt -cne "2026-08-26T15:11:10Z" -or
      [string]$Record.consumedAttempt.dequeuedAt -cne "2026-08-26T15:11:17Z" -or
      [string]$Record.consumedAttempt.terminalDecision -cne "ADMISSION_COMPROMISE_RECOVERED" -or
      [long]$Record.consumedAttempt.enqueueAttempts -ne 1 -or
      [long]$Record.consumedAttempt.dequeueAttempts -ne 1 -or
      [long]$Record.consumedAttempt.mutationCount -ne 2 -or
      [string]$Record.consumedAttempt.controllerHead -cne $frontierConsumedControllerHead -or
      [string]$Record.consumedAttempt.terminalReceiptSha256 -cnotmatch "^[a-f0-9]{64}$") { return $false }

  if ([long]$Record.replacement.issue -ne $frontierRetryIssue -or
      [string]$Record.replacement.nodeId -cne $frontierRetryIssueNode -or
      [string]$Record.replacement.bodySha256 -cne $frontierRetryBodySha256 -or
      [string]$Record.replacement.canonicalBodySha256 -cne $frontierRetryCanonicalBodySha256 -or
      $null -eq (ConvertTo-ReviewInstant ([string]$Record.replacement.updatedAt)) -or
      [long]$Record.decision.issue -ne $frontierDecisionIssue -or
      [string]$Record.decision.nodeId -cne $frontierDecisionIssueNode -or
      [string]$Record.decision.bodySha256 -cne $frontierDecisionBodySha256 -or
      $null -eq (ConvertTo-ReviewInstant ([string]$Record.decision.updatedAt)) -or
      -not (Test-WholeNumber $Record.decision.rulingCommentId 1) -or
      [string]$Record.decision.rulingCommentUrl -cnotmatch '^https://github\.com/chase-sets/chase-sets/issues/7493#issuecomment-[1-9][0-9]*$' -or
      [string]$Record.decision.rulingAuthor -cne "todd-skelton" -or
      [string]$Record.decision.rulingBodySha256 -cnotmatch "^[a-f0-9]{64}$" -or
      [long]$Record.activation.issue -ne $frontierActivationIssue -or
      [string]$Record.activation.nodeId -cne $frontierActivationIssueNode -or
      [string]$Record.activation.bodySha256 -cne $frontierActivationBodySha256 -or
      $null -eq (ConvertTo-ReviewInstant ([string]$Record.activation.updatedAt))) { return $false }

  if ([string]$Record.breaker.key -cne $frontierBreakerKey -or
      [string]$Record.breaker.openTs -cne $frontierBreakerOpenTs -or
      [long]$Record.breaker.line -ne $frontierBreakerLine -or
      [string]$Record.breaker.rowSha256 -cne $frontierBreakerRowSha256 -or
      [long]$Record.repair.rootIssue -ne $frontierRootIssue -or
      [long]$Record.repair.issue -ne $frontierRepairIssue -or
      [string]$Record.repair.bodySha256 -cne $frontierRepairBodySha256 -or
      [long]$Record.candidate.pr -ne $frontierConsumedPr -or
      [string]$Record.candidate.prNodeId -cne $frontierConsumedPrNode -or
      [string]$Record.candidate.headOid -cne $frontierConsumedHead -or
      [string]$Record.candidate.baseOid -cne $frontierConsumedBase -or
      [string]$Record.configurationSha256 -cnotmatch "^[a-f0-9]{64}$") { return $false }

  if (-not (Test-RetryAttemptPolicy $Record.attempt $Record.spendTelemetry)) { return $false }

  if ([string]$Record.activationCensus.schemaVersion -cne "workflow-tag-activation-census/v1" -or
      $Record.activationCensus.complete -ne $true -or
      [string]$Record.activationCensus.productHead -cne $frontierConsumedBase -or
      -not (Test-WholeNumber $Record.activationCensus.workflowCount 1) -or
      [string]$Record.activationCensus.workflowPathsSha256 -cnotmatch "^[a-f0-9]{64}$" -or
      [long]$Record.activationCensus.tagTriggerCount -ne 0 -or
      $Record.activationCensus.tagRulesComplete -ne $true -or
      [long]$Record.activationCensus.tagRulesetCount -ne 0) { return $false }

  $identity = Get-RetryAuthorityIdentity $Record
  $expectedRef = Get-RetryConsumptionRefName $frontierConsumedHead $identity
  return [string]$Record.remoteConsumption.namespace -ceq $frontierConsumptionNamespace -and
    [long]$Record.remoteConsumption.lineageRoot -eq $frontierAuthorityIssue -and
    [string]$Record.remoteConsumption.candidateHead -ceq $frontierConsumedHead -and
    [long]$Record.remoteConsumption.attemptOrdinal -eq 2 -and
    [string]$Record.remoteConsumption.authorityIdentity -ceq $identity -and
    [string]$Record.remoteConsumption.expectedRef -ceq $expectedRef -and
    [string]$Record.remoteConsumption.targetOid -ceq $frontierConsumedHead
}

function ConvertTo-RemoteRefObservation($Value) {
  $valid = $null -ne $Value -and (Test-ExactKeys $Value @("ref", "node_id", "url", "object")) -and
    (Test-ExactKeys $Value.object @("sha", "type", "url")) -and
    [string]$Value.ref -cmatch '^refs/tags/orchestrator-consumption/[A-Za-z0-9._/-]+$' -and
    [string]$Value.object.sha -cmatch '^[a-f0-9]{40}$' -and [string]$Value.object.type -ceq "commit"
  [ordered]@{
    valid = $valid
    ref = if ($null -ne $Value) { [string]$Value.ref } else { $null }
    targetOid = if ($null -ne $Value -and $null -ne $Value.object) { [string]$Value.object.sha } else { $null }
    objectType = if ($null -ne $Value -and $null -ne $Value.object) { [string]$Value.object.type } else { $null }
  }
}

function Get-RemoteConsumptionNamespace {
  $owner, $name = $Repository.Split("/")
  $result = Get-RestCollection "repos/$owner/$name/git/matching-refs/tags/orchestrator-consumption"
  if (-not $result.complete) { return [ordered]@{ complete = $false; refs = @() } }
  [ordered]@{ complete = $true; refs = @($result.values | ForEach-Object { ConvertTo-RemoteRefObservation $_ }) }
}

function Get-RemoteConsumptionRef([string]$ExpectedRef) {
  $owner, $name = $Repository.Split("/")
  $suffix = $ExpectedRef.Substring("refs/".Length)
  $result = Invoke-GhRestJson @("repos/$owner/$name/git/ref/$suffix")
  if (-not $result.complete) { return [ordered]@{ complete = $false; ref = $null } }
  [ordered]@{ complete = $true; ref = ConvertTo-RemoteRefObservation $result.value }
}

function Invoke-RemoteConsumptionRefCreate([string]$ExpectedRef, [string]$TargetOid) {
  $owner, $name = $Repository.Split("/")
  $result = Invoke-ExternalProcess $GhCommand @(
    "api", "--method", "POST", "repos/$owner/$name/git/refs",
    "-f", "ref=$ExpectedRef", "-f", "sha=$TargetOid"
  )
  $value = $null
  if (-not [string]::IsNullOrWhiteSpace([string]$result.stdout)) {
    try { $value = $result.stdout | ConvertFrom-Json -Depth 32 -DateKind String -ErrorAction Stop } catch { $value = $null }
  }
  [ordered]@{
    attempted = $true
    exitCode = [int]$result.exitCode
    stdout = [string]$result.stdout
    stderr = [string]$result.stderr
    ref = if ($null -ne $value) { ConvertTo-RemoteRefObservation $value } else { $null }
  }
}

function Invoke-RetryConsumptionProtocol($Record) {
  $expectedRef = [string]$Record.remoteConsumption.expectedRef
  $targetOid = [string]$Record.remoteConsumption.targetOid
  $pre = if ($fixtureScenario -and $fixtureScenario.remoteConsumption) {
    $fixtureScenario.remoteConsumption.preCensus
  } else {
    Get-RemoteConsumptionNamespace
  }
  $receipt = [ordered]@{
    schemaVersion = "breaker-repair-frontier-remote-consumption/v1"
    complete = $false
    reason = "REMOTE_NAMESPACE_UNREADABLE"
    expectedRef = $expectedRef
    targetOid = $targetOid
    preCensus = $pre
    create = [ordered]@{ attempted = $false; exitCode = $null; stdout = ""; stderr = ""; ref = $null }
    postCensus = $null
    reread = $null
  }
  if ($pre.complete -ne $true -or @($pre.refs | Where-Object { $_.valid -ne $true }).Count -gt 0) { return $receipt }
  if (@($pre.refs).Count -ne 0) { $receipt.reason = "REMOTE_NAMESPACE_NOT_EMPTY"; return $receipt }

  $create = if ($fixtureScenario -and $fixtureScenario.remoteConsumption) {
    $fixtureScenario.remoteConsumption.create
  } else {
    Invoke-RemoteConsumptionRefCreate $expectedRef $targetOid
  }
  $receipt.create = $create
  if ($create.attempted -ne $true -or [int]$create.exitCode -ne 0 -or $null -eq $create.ref -or
      $create.ref.valid -ne $true -or [string]$create.ref.ref -cne $expectedRef -or
      [string]$create.ref.targetOid -cne $targetOid) {
    $receipt.reason = "REMOTE_ATOMIC_CREATE_UNCONFIRMED"
    return $receipt
  }

  $post = if ($fixtureScenario -and $fixtureScenario.remoteConsumption) {
    $fixtureScenario.remoteConsumption.postCensus
  } else {
    Get-RemoteConsumptionNamespace
  }
  $receipt.postCensus = $post
  if ($post.complete -ne $true -or @($post.refs).Count -ne 1 -or $post.refs[0].valid -ne $true -or
      [string]$post.refs[0].ref -cne $expectedRef -or [string]$post.refs[0].targetOid -cne $targetOid) {
    $receipt.reason = "REMOTE_POST_CREATE_CENSUS_MISMATCH"
    return $receipt
  }

  $reread = if ($fixtureScenario -and $fixtureScenario.remoteConsumption) {
    $fixtureScenario.remoteConsumption.reread
  } else {
    Get-RemoteConsumptionRef $expectedRef
  }
  $receipt.reread = $reread
  if ($reread.complete -ne $true -or $null -eq $reread.ref -or $reread.ref.valid -ne $true -or
      [string]$reread.ref.ref -cne $expectedRef -or [string]$reread.ref.targetOid -cne $targetOid) {
    $receipt.reason = "REMOTE_EXACT_REF_REREAD_MISMATCH"
    return $receipt
  }
  $receipt.complete = $true
  $receipt.reason = "REMOTE_CONSUMPTION_CONFIRMED"
  return $receipt
}

function Test-FrontierConfiguration($Configuration) {
  if ($null -eq $Configuration -or $Configuration.complete -ne $true -or
      [string]$Configuration.sha256 -cnotmatch "^[a-f0-9]{64}$" -or
      (Get-ConfigurationSha256 $Configuration.value) -cne [string]$Configuration.sha256) { return $false }
  $value = $Configuration.value
  if (-not (Test-ExactKeys $value @("schemaVersion", "repository", "mergeQueue", "applicableRulesetCount", "applicableRulesets", "classicProtection", "writers")) -or
      [string]$value.schemaVersion -cne "admission-configuration/v1" -or
      -not (Test-ExactKeys $value.repository @("autoMergeAllowed", "mergeCommitAllowed", "rebaseMergeAllowed", "squashMergeAllowed", "viewerPermission")) -or
      $value.repository.autoMergeAllowed -ne $false -or $value.repository.squashMergeAllowed -ne $true -or
      -not (Test-ExactKeys $value.mergeQueue @("mergeMethod", "maximumEntriesToBuild", "maximumEntriesToMerge", "minimumEntriesToMerge", "minimumEntriesToMergeWaitTime", "checkResponseTimeout", "mergingStrategy")) -or
      [string]$value.mergeQueue.mergeMethod -cne "SQUASH" -or [int]$value.mergeQueue.maximumEntriesToBuild -ne 2 -or
      [int]$value.mergeQueue.maximumEntriesToMerge -ne 2 -or [int]$value.mergeQueue.minimumEntriesToMerge -ne 1 -or
      [int]$value.mergeQueue.minimumEntriesToMergeWaitTime -ne 0 -or [int]$value.mergeQueue.checkResponseTimeout -ne 3600 -or
      [string]$value.mergeQueue.mergingStrategy -cne "ALLGREEN" -or
      -not (Test-WholeNumber $value.applicableRulesetCount 1) -or @($value.applicableRulesets).Count -ne [int]$value.applicableRulesetCount) { return $false }
  $types = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($ruleset in @($value.applicableRulesets)) {
    if (-not (Test-ExactKeys $ruleset @("id", "name", "target", "enforcement", "include", "exclude", "bypassActors", "rules")) -or
        -not (Test-WholeNumber $ruleset.id 1) -or [string]$ruleset.target -cne "branch" -or
        [string]$ruleset.enforcement -cne "active" -or @($ruleset.bypassActors).Count -ne 0 -or
        @($ruleset.include | Where-Object { $_ -in @("refs/heads/main", "~DEFAULT_BRANCH") }).Count -eq 0 -or
        @($ruleset.exclude | Where-Object { $_ -in @("refs/heads/main", "~DEFAULT_BRANCH") }).Count -gt 0) { return $false }
    foreach ($rule in @($ruleset.rules)) {
      $type = [string]$rule.type
      if ($type -notin @("required_linear_history", "non_fast_forward", "required_status_checks", "merge_queue")) { return $false }
      [void]$types.Add($type)
      switch ($type) {
        "required_linear_history" { if (-not (Test-ExactKeys $rule @("type"))) { return $false } }
        "non_fast_forward" { if (-not (Test-ExactKeys $rule @("type"))) { return $false } }
        "required_status_checks" {
          $requiredCheck = @($rule.checks)[0]
          if (-not (Test-ExactKeys $rule @("type", "strict", "doNotEnforceOnCreate", "checks")) -or
              $rule.strict -ne $true -or $rule.doNotEnforceOnCreate -ne $false -or @($rule.checks).Count -ne 1 -or
              -not (Test-ExactKeys $requiredCheck @("context", "integrationId")) -or
              [string]$requiredCheck.context -cne "PR Required" -or [long]$requiredCheck.integrationId -ne 15368) { return $false }
        }
        "merge_queue" {
          if (-not (Test-ExactKeys $rule @("type", "mergeMethod", "maximumEntriesToBuild", "maximumEntriesToMerge", "minimumEntriesToMerge", "minimumEntriesToMergeWaitMinutes", "groupingStrategy", "checkResponseTimeoutMinutes")) -or
              [string]$rule.mergeMethod -cne "SQUASH" -or [int]$rule.maximumEntriesToBuild -ne 2 -or [int]$rule.maximumEntriesToMerge -ne 2 -or
              [int]$rule.minimumEntriesToMerge -ne 1 -or [int]$rule.minimumEntriesToMergeWaitMinutes -ne 0 -or
              [string]$rule.groupingStrategy -cne "ALLGREEN" -or [int]$rule.checkResponseTimeoutMinutes -ne 60) { return $false }
        }
      }
    }
  }
  if (@("required_linear_history", "non_fast_forward", "required_status_checks", "merge_queue" | Where-Object { -not $types.Contains($_) }).Count -gt 0) { return $false }
  $protection = $value.classicProtection
  $protectionCheck = @($protection.requiredStatusChecks.checks)[0]
  if (-not (Test-ExactKeys $protection @("enforceAdmins", "requiredStatusChecks", "requiredSignatures", "requiredLinearHistory", "requiredConversationResolution", "allowForcePushes", "allowDeletions", "blockCreations", "lockBranch", "allowForkSyncing")) -or
      $protection.enforceAdmins -ne $true -or $protection.requiredLinearHistory -ne $true -or
      $protection.requiredConversationResolution -ne $true -or $protection.allowForcePushes -ne $false -or $protection.allowDeletions -ne $false -or
      $protection.requiredSignatures -ne $false -or $protection.blockCreations -ne $false -or
      $protection.lockBranch -ne $false -or $protection.allowForkSyncing -ne $false -or
      -not (Test-ExactKeys $protection.requiredStatusChecks @("strict", "contexts", "checks")) -or
      $protection.requiredStatusChecks.strict -ne $true -or (@($protection.requiredStatusChecks.contexts) -join ",") -cne "PR Required" -or
      @($protection.requiredStatusChecks.checks).Count -ne 1 -or [string]$protectionCheck.context -cne "PR Required" -or
      [long]$protectionCheck.appId -ne 15368) { return $false }
  $writers = $value.writers
  if (-not (Test-ExactKeys $writers @("automatedEnqueueWriters", "openAutoMergeRequestCount", "collaboratorCount", "collaborators", "authorityBoundary")) -or
      (@($writers.automatedEnqueueWriters) -join ",") -cne ".orchestrator/landing-preflight.ps1" -or
      [int]$writers.openAutoMergeRequestCount -ne 0 -or @($writers.collaborators).Count -ne [int]$writers.collaboratorCount -or
      [string]$writers.authorityBoundary -cne "manual administrator enqueue is detected, never prevented") { return $false }
  foreach ($collaborator in @($writers.collaborators)) {
    if (-not (Test-ExactKeys $collaborator @("login", "id", "nodeId", "role", "permissions")) -or
        [string]::IsNullOrWhiteSpace([string]$collaborator.login) -or -not (Test-WholeNumber $collaborator.id 1) -or
        -not (Test-ExactKeys $collaborator.permissions @("admin", "maintain", "push", "triage", "pull"))) { return $false }
  }
  return $true
}

function Get-FrontierStableProjection($Snapshot) {
  [ordered]@{
    authorityRecord = $Snapshot.authorityRecord.raw
    retryProvider = $Snapshot.retryProvider
    authorityIssue = $Snapshot.authorityIssue
    root = $Snapshot.root
    repair = $Snapshot.repair
    candidate = $Snapshot.candidate
    defaultOid = $Snapshot.defaultOid
    openPullRequests = $Snapshot.openPullRequests
    collisions = $Snapshot.collisions
    configuration = $Snapshot.configuration
    breaker = $Snapshot.breaker
  }
}

function Get-StableEntryConjuncts($MutationResult, $QueueEntry, $Candidate) {
  $mutationEntry = $MutationResult.entry
  $mutationPull = if ($null -ne $mutationEntry) { $mutationEntry.stable.pullRequest } else { $null }
  $queuePull = if ($null -ne $QueueEntry) { $QueueEntry.stable.pullRequest } else { $null }
  [ordered]@{
    mutationExitZero = $MutationResult.graphql.process.exitCode -eq 0
    mutationDataPresent = $MutationResult.graphql.data.present -eq $true -and $MutationResult.graphql.data.explicitNull -eq $false
    mutationErrorsAbsent = $MutationResult.graphql.errors.present -eq $false -or $MutationResult.graphql.errors.explicitNull -eq $true -or $MutationResult.graphql.errors.value -ceq "[]"
    clientMutationId = $MutationResult.clientMutationId.predicate -eq $true
    mutationEntryShape = $null -ne $mutationEntry -and $mutationEntry.valid -eq $true
    mutationEntryId = $null -ne $mutationEntry -and [string]$mutationEntry.stable.entryId -ceq [string]$MutationResult.entryId
    mutationJumpFalse = $null -ne $mutationEntry -and $mutationEntry.stable.jump -eq $false
    mutationPullRequestCompatible = $null -eq $mutationPull -or
      ([string]$mutationPull.id -ceq [string]$Candidate.id -and [long]$mutationPull.number -eq [long]$Candidate.number -and
       [string]$mutationPull.headOid -ceq [string]$Candidate.headOid)
    queueEntryShape = $null -ne $QueueEntry -and $QueueEntry.valid -eq $true
    exactEntryId = $null -ne $QueueEntry -and [string]$QueueEntry.stable.entryId -ceq [string]$MutationResult.entryId
    queueJumpFalse = $null -ne $QueueEntry -and $QueueEntry.stable.jump -eq $false
    exactPrNodeId = $null -ne $queuePull -and [string]$queuePull.id -ceq [string]$Candidate.id
    exactPrNumber = $null -ne $queuePull -and [long]$queuePull.number -eq [long]$Candidate.number
    exactPrHead = $null -ne $queuePull -and [string]$queuePull.headOid -ceq [string]$Candidate.headOid
    mutationQueueStableMatch = $null -ne $QueueEntry -and $null -ne $mutationEntry -and
      [string]$mutationEntry.stable.entryId -ceq [string]$QueueEntry.stable.entryId -and
      $mutationEntry.stable.jump -eq $QueueEntry.stable.jump -and
      ($null -eq $mutationPull -or
        ([string]$mutationPull.id -ceq [string]$queuePull.id -and [long]$mutationPull.number -eq [long]$queuePull.number -and
         [string]$mutationPull.headOid -ceq [string]$queuePull.headOid))
  }
}

function Get-Decision7643StableProjection($Snapshot) {
  [ordered]@{
    decision = $Snapshot.decision
    breakerAuthority = $Snapshot.breakerAuthority
    candidate = $Snapshot.candidate
    openPullRequests = $Snapshot.openPullRequests
    collisions = $Snapshot.collisions
    configuration = $Snapshot.configuration
    breaker = $Snapshot.breaker
  }
}

function Test-Decision7643LandingAdapter($Observation, $ExpectedMutation = $null, $ImmediateQueue = $null) {
  $snapshot = if ($Observation.decision7643Adapter) {
    $Observation.decision7643Adapter
  } elseif ($fixtureScenario) {
    $null
  } else {
    Get-Decision7643ProductionObservation $Observation $ImmediateQueue
  }
  if ($null -eq $snapshot) { $snapshot = [ordered]@{ complete = $false; reason = "DECISION_7643_OBSERVATION_ABSENT" } }
  if ($null -ne $ImmediateQueue -and $null -ne $snapshot.queue) { $snapshot.queue = $ImmediateQueue }
  $conjuncts = [ordered]@{
    observationComplete = $snapshot.complete -eq $true
    exactDecision = $false
    exactRuling = $false
    exactRetainedBreaker = $false
    exactCandidate = $false
    collisionFree = $false
    queue = $false
    configuration = $false
  }

  $provider = $snapshot.decision
  $decision = if ($null -ne $provider) { $provider.decision } else { $null }
  $conjuncts.exactDecision = $null -ne $provider -and $provider.complete -eq $true -and
    (Test-ExactKeys $provider @("complete", "reason", "decision", "commentsComplete", "comments")) -and
    $provider.commentsComplete -eq $true -and
    (Test-ExactKeys $decision @("id", "number", "state", "stateReason", "type", "bodySha256", "updatedAt", "closedAt", "closedBy")) -and
    [string]$decision.id -ceq $decision7643Node -and [long]$decision.number -eq $decision7643Issue -and
    [string]$decision.state -ceq "CLOSED" -and [string]$decision.stateReason -ceq "COMPLETED" -and
    [string]$decision.type -ceq "Decision" -and [string]$decision.bodySha256 -ceq $decision7643BodySha256 -and
    [string]$decision.updatedAt -ceq $decision7643UpdatedAt -and [string]$decision.closedAt -ceq $decision7643ClosedAt -and
    [string]$decision.closedBy -ceq $decision7643ToddLogin

  [object[]]$comments = @(
    if ($null -ne $provider) { @($provider.comments) } else { @() }
  )
  $ruling = if ($comments.Count -eq 1) { $comments[0] } else { $null }
  $rulingAuthor = if ($null -ne $ruling) { $ruling.author } else { $null }
  $conjuncts.exactRuling = $comments.Count -eq 1 -and
    (Test-ExactKeys $ruling @("id", "url", "author", "authorAssociation", "bodySha256", "createdAt", "updatedAt")) -and
    (Test-ExactKeys $rulingAuthor @("login", "id", "nodeId")) -and
    [long]$ruling.id -eq $decision7643RulingCommentId -and [string]$ruling.url -ceq $decision7643RulingCommentUrl -and
    [string]$rulingAuthor.login -ceq $decision7643ToddLogin -and [long]$rulingAuthor.id -eq $decision7643ToddId -and
    [string]$rulingAuthor.nodeId -ceq $decision7643ToddNode -and [string]$ruling.authorAssociation -ceq "MEMBER" -and
    [string]$ruling.bodySha256 -ceq $decision7643RulingCommentBodySha256 -and
    [string]$ruling.createdAt -ceq $decision7643RulingCommentAt -and [string]$ruling.updatedAt -ceq $decision7643RulingCommentAt

  $breakerAuthority = $snapshot.breakerAuthority
  $currentBreaker = if ($null -ne $breakerAuthority) { $breakerAuthority.current } else { $null }
  $rawRow = if ($null -ne $breakerAuthority) { $breakerAuthority.row } else { $null }
  [object[]]$openRows = @(
    if ($null -ne $currentBreaker) { @($currentBreaker.openRows) } else { @() }
  )
  $openRow = if ($openRows.Count -eq 1) { $openRows[0] } else { $null }
  $conjuncts.exactRetainedBreaker = $null -ne $breakerAuthority -and $breakerAuthority.complete -eq $true -and
    (Test-ExactKeys $breakerAuthority @("complete", "reason", "current", "row")) -and
    $currentBreaker.complete -eq $true -and $currentBreaker.healthy -eq $false -and
    @($currentBreaker.open).Count -eq 1 -and [string]@($currentBreaker.open)[0] -ceq $decision7643BreakerKey -and
    $openRows.Count -eq 1 -and
    (Test-ExactKeys $openRow @("key", "openTs", "line", "rowSha256", "byteLength")) -and
    [string]$openRow.key -ceq $decision7643BreakerKey -and [string]$openRow.openTs -ceq $decision7643BreakerOpenTs -and
    [long]$openRow.line -eq $decision7643BreakerLine -and [string]$openRow.rowSha256 -ceq $decision7643BreakerRowSha256 -and
    [long]$openRow.byteLength -eq $decision7643BreakerRowBytes -and
    (Test-ExactKeys $rawRow @("line", "rowSha256", "byteLength", "kind", "ts", "issue", "pr", "outcome", "breakerScope")) -and
    [long]$rawRow.line -eq $decision7643BreakerLine -and [string]$rawRow.rowSha256 -ceq $decision7643BreakerRowSha256 -and
    [long]$rawRow.byteLength -eq $decision7643BreakerRowBytes -and [string]$rawRow.kind -ceq "breaker-open" -and
    [string]$rawRow.ts -ceq $decision7643BreakerOpenTs -and
    (Test-WholeNumber $rawRow.issue 1) -and [long]$rawRow.issue -eq $decision7643BreakerIssue -and
    (Test-WholeNumber $rawRow.pr 1) -and [long]$rawRow.pr -eq $decision7643BreakerPr -and
    [string]$rawRow.outcome -ceq $decision7643BreakerOutcome -and [string]$rawRow.breakerScope -ceq $decision7643BreakerScope -and
    (Get-CanonicalSha256 $currentBreaker) -ceq (Get-CanonicalSha256 $snapshot.breaker)

  $candidate = $snapshot.candidate
  $conjuncts.exactCandidate = (Test-ExactKeys $candidate @("id", "number", "headOid", "filesComplete", "files")) -and
    [int]$candidate.number -eq $Pr -and $Pr -eq $decision7643CandidatePr -and
    [string]$candidate.id -cmatch "^[A-Za-z0-9_=-]+$" -and [string]$candidate.headOid -ceq $decision7643CandidateHead -and
    $candidate.filesComplete -eq $true
  [object[]]$candidatePulls = @(
    if ($null -ne $snapshot.openPullRequests) {
      @($snapshot.openPullRequests.pullRequests | Where-Object { [int]$_.number -eq $Pr })
    } else { @() }
  )
  $conjuncts.collisionFree = $snapshot.openPullRequests.complete -eq $true -and $candidatePulls.Count -eq 1 -and
    [string]$candidatePulls[0].headOid -ceq $decision7643CandidateHead -and
    (Get-CanonicalSha256 @($candidatePulls[0].files)) -ceq (Get-CanonicalSha256 @($candidate.files)) -and
    @($snapshot.collisions).Count -eq 0
  $queuePredicates = $null
  if ($null -eq $ExpectedMutation) {
    $conjuncts.queue = $snapshot.queue.complete -eq $true -and @($snapshot.queue.entries).Count -eq 0
  } else {
    $entries = @($snapshot.queue.entries)
    $queuePredicates = Get-StableEntryConjuncts $ExpectedMutation $(if ($entries.Count -eq 1) { $entries[0] } else { $null }) $candidate
    $conjuncts.queue = $snapshot.queue.complete -eq $true -and $entries.Count -eq 1 -and
      @($queuePredicates.Values | Where-Object { $_ -ne $true }).Count -eq 0
  }
  $conjuncts.configuration = Test-FrontierConfiguration $snapshot.configuration
  $admitted = @($conjuncts.Values | Where-Object { $_ -ne $true }).Count -eq 0
  [ordered]@{
    admitted = $admitted
    snapshot = $snapshot
    admission = [ordered]@{
      schemaVersion = "decision-7643-pr-7641-landing-adapter-admission/v1"
      decision = if ($admitted) { "DECISION_7643_PR_7641_ADAPTER_ADMITTED" } else { "DECISION_7643_PR_7641_ADAPTER_REFUSED" }
      conjuncts = $conjuncts
      queuePredicates = $queuePredicates
      configurationSha256 = if ($snapshot.configuration) { $snapshot.configuration.sha256 } else { $null }
      configurationComputedSha256 = if ($snapshot.configuration.value) { Get-ConfigurationSha256 $snapshot.configuration.value } else { $null }
      collisions = @($snapshot.collisions)
      authorityBoundary = [ordered]@{ atomic = "PR #7641 exact head through expectedHeadOid"; governedNotAtomic = "Decision #7643, exact breaker row, queue, collision, checks, deploy, and configuration through repeated reads and enforcing audit"; detectedNotPrevented = "manual administrator enqueue" }
      seed = [ordered]@{
        decision = [ordered]@{ issue = $decision7643Issue; nodeId = $decision7643Node; rulingCommentId = $decision7643RulingCommentId; rulingBodySha256 = $decision7643RulingCommentBodySha256 }
        breaker = [ordered]@{ openTs = $decision7643BreakerOpenTs; line = $decision7643BreakerLine; issue = $decision7643BreakerIssue; pr = $decision7643BreakerPr; outcome = $decision7643BreakerOutcome; scope = $decision7643BreakerScope; rowSha256 = $decision7643BreakerRowSha256 }
        candidate = [ordered]@{ pr = $decision7643CandidatePr; headOid = $decision7643CandidateHead }
      }
    }
  }
}

function Test-BreakerRepairFrontier($Observation, $ExpectedMutation = $null, $ImmediateQueue = $null) {
  $snapshot = if ($Observation.admission) { $Observation.admission } elseif ($fixtureScenario) { $null } else { Get-RepairFrontierProductionObservation $Observation $ImmediateQueue }
  if ($null -eq $snapshot) { $snapshot = [ordered]@{ complete = $false; reason = "FRONTIER_OBSERVATION_ABSENT" } }
  if ($null -ne $ImmediateQueue -and $null -ne $snapshot.queue) { $snapshot.queue = $ImmediateQueue }
  $conjuncts = [ordered]@{
    observationComplete = $snapshot.complete -eq $true
    authorityRecordClosed = $false
    retryAuthority = $true
    exactAuthorityIssue = $false
    exactRetainedBreaker = $false
    repairGraph = $false
    exactCandidate = $false
    currentBase = $false
    collisionFree = $false
    queue = $false
    configuration = $false
  }
  $record = if ($snapshot.authorityRecord.present -eq $true -and $snapshot.authorityRecord.complete -eq $true) { ConvertFrom-ClosedJson ([string]$snapshot.authorityRecord.raw) } else { $null }
  $instant = ConvertTo-ReviewInstant ([string]$snapshot.observedAt)
  $isRetry = $record -and [string]$record.schemaVersion -ceq "breaker-repair-frontier-retry-authority/v1"
  if ($record -and $instant) {
    if ($isRetry) {
      $conjuncts.authorityRecordClosed = Test-RetryAuthorityRecordShape $record $instant
      $conjuncts.retryAuthority = $conjuncts.authorityRecordClosed
    } else {
      $conjuncts.authorityRecordClosed = Test-AuthorityRecordShape $record $instant
    }
  }
  $conjuncts.exactAuthorityIssue = $snapshot.authorityIssue.id -ceq $frontierAuthorityNode -and
    [int]$snapshot.authorityIssue.number -eq $frontierAuthorityIssue -and [string]$snapshot.authorityIssue.state -ceq "OPEN" -and
    [string]$snapshot.authorityIssue.bodySha256 -ceq $frontierAuthorityBodySha256 -and
    [string]$snapshot.authorityIssue.type -ceq "Bug" -and [int]$snapshot.authorityIssue.milestone.number -eq 136 -and
    [string]$snapshot.authorityIssue.milestone.state -ceq "OPEN" -and
    (@($snapshot.authorityIssue.labels | Sort-Object -CaseSensitive) -join ",") -ceq "area:ops,kind:ops,priority:p0,risk:semantic-authority"
  $openRows = @($snapshot.breaker.openRows)
  $conjuncts.exactRetainedBreaker = $snapshot.breaker.complete -eq $true -and $snapshot.breaker.healthy -eq $false -and
    @($snapshot.breaker.open).Count -eq 1 -and [string]@($snapshot.breaker.open)[0] -ceq $frontierBreakerKey -and $openRows.Count -eq 1 -and
    [string]$openRows[0].key -ceq $frontierBreakerKey -and [string]$openRows[0].openTs -ceq $frontierBreakerOpenTs -and
    [int]$openRows[0].line -eq $frontierBreakerLine -and [string]$openRows[0].rowSha256 -ceq $frontierBreakerRowSha256 -and
    [int]$openRows[0].byteLength -eq $frontierBreakerRowBytes
  $labels = [string[]]@($snapshot.repair.labels)
  $closureMembers = @($snapshot.root.closure | Where-Object { [int]$_.number -eq $frontierRepairIssue })
  $conjuncts.repairGraph = $snapshot.root.closureComplete -eq $true -and [int]$snapshot.root.issue.number -eq $frontierRootIssue -and
    [string]$snapshot.root.issue.state -ceq "OPEN" -and $closureMembers.Count -ge 1 -and
    [int]$snapshot.repair.issue.number -eq $frontierRepairIssue -and [string]$snapshot.repair.issue.state -ceq "OPEN" -and
    [string]$snapshot.repair.issue.type -ceq "Bug" -and [int]$snapshot.repair.issue.milestone.number -eq 136 -and
    [string]$snapshot.repair.issue.milestone.state -ceq "OPEN" -and [string]$snapshot.repair.issue.bodySha256 -ceq $frontierRepairBodySha256 -and
    @($labels | Where-Object { $_ -in @("status:tracking-only", "status:needs-replan") }).Count -eq 0 -and
    @("priority:p0", "area:infrastructure", "kind:ops" | Where-Object { $_ -notin $labels }).Count -eq 0 -and
    $snapshot.repair.blockersComplete -eq $true -and @($snapshot.repair.blockers | Where-Object { [string]$_.state -ceq "OPEN" }).Count -eq 0
  $conjuncts.exactCandidate = [int]$snapshot.candidate.number -eq $Pr -and [int]$record.candidate.pr -eq $Pr -and
    [string]$snapshot.candidate.id -cmatch "^[A-Za-z0-9_=-]+$" -and [string]$snapshot.candidate.headOid -ceq [string]$record.candidate.headOid -and
    $snapshot.candidate.filesComplete -eq $true -and $snapshot.candidate.closingIssuesComplete -eq $true -and
    @($snapshot.candidate.closingIssues).Count -eq 1 -and [int]@($snapshot.candidate.closingIssues)[0] -eq $frontierRepairIssue
  $conjuncts.currentBase = [string]$snapshot.defaultOid -ceq [string]$record.candidate.baseOid -and
    [string]$snapshot.candidate.baseOid -ceq [string]$record.candidate.baseOid -and
    [string]$snapshot.candidate.mergeBaseOid -ceq [string]$record.candidate.baseOid -and
    [string]$snapshot.candidate.comparisonStatus -in @("ahead", "identical")
  $candidatePulls = @($snapshot.openPullRequests.pullRequests | Where-Object { [int]$_.number -eq $Pr })
  $conjuncts.collisionFree = $snapshot.openPullRequests.complete -eq $true -and $candidatePulls.Count -eq 1 -and
    [string]$candidatePulls[0].headOid -ceq [string]$record.candidate.headOid -and
    (Get-CanonicalSha256 @($candidatePulls[0].files)) -ceq (Get-CanonicalSha256 @($snapshot.candidate.files)) -and
    @($snapshot.collisions).Count -eq 0
  $queuePredicates = $null
  if ($null -eq $ExpectedMutation) {
    $conjuncts.queue = $snapshot.queue.complete -eq $true -and @($snapshot.queue.entries).Count -eq 0
  } else {
    $entries = @($snapshot.queue.entries)
    $queuePredicates = Get-StableEntryConjuncts $ExpectedMutation $(if ($entries.Count -eq 1) { $entries[0] } else { $null }) $snapshot.candidate
    $conjuncts.queue = $snapshot.queue.complete -eq $true -and $entries.Count -eq 1 -and
      @($queuePredicates.Values | Where-Object { $_ -ne $true }).Count -eq 0
  }
  $conjuncts.configuration = Test-FrontierConfiguration $snapshot.configuration
  if ($record) { $conjuncts.configuration = $conjuncts.configuration -and [string]$record.configurationSha256 -ceq [string]$snapshot.configuration.sha256 }
  if ($record -and -not $isRetry) {
    $conjuncts.exactAuthorityIssue = $conjuncts.exactAuthorityIssue -and [string]$record.authority.bodySha256 -ceq [string]$snapshot.authorityIssue.bodySha256
    $conjuncts.exactRetainedBreaker = $conjuncts.exactRetainedBreaker -and [string]$record.breaker.rowSha256 -ceq [string]$openRows[0].rowSha256
    $conjuncts.repairGraph = $conjuncts.repairGraph -and [string]$record.repair.bodySha256 -ceq [string]$snapshot.repair.issue.bodySha256
  }
  if ($record -and $isRetry) {
    $provider = $snapshot.retryProvider
    $rulingComments = if ($null -ne $provider) { @($provider.decisionComments | Where-Object {
          [long]$_.id -eq [long]$record.decision.rulingCommentId -and
          [string]$_.url -ceq [string]$record.decision.rulingCommentUrl -and
          [string]$_.author -ceq [string]$record.decision.rulingAuthor -and
          [string]$_.bodySha256 -ceq [string]$record.decision.rulingBodySha256
        }) } else { @() }
    $activationBlockers = if ($null -ne $provider) { @($provider.activationBlockers | Sort-Object number) } else { @() }
    $conjuncts.retryAuthority = $conjuncts.retryAuthority -and
      $null -ne $provider -and $provider.complete -eq $true -and
      [string]$provider.replacement.id -ceq $frontierRetryIssueNode -and [long]$provider.replacement.number -eq $frontierRetryIssue -and
      [string]$provider.replacement.state -ceq "CLOSED" -and [string]$provider.replacement.bodySha256 -ceq $frontierRetryBodySha256 -and
      [string]$provider.replacement.updatedAt -ceq [string]$record.replacement.updatedAt -and
      [string]$provider.decision.id -ceq $frontierDecisionIssueNode -and [long]$provider.decision.number -eq $frontierDecisionIssue -and
      [string]$provider.decision.state -ceq "CLOSED" -and [string]$provider.decision.bodySha256 -ceq $frontierDecisionBodySha256 -and
      [string]$provider.decision.updatedAt -ceq [string]$record.decision.updatedAt -and
      $provider.decisionCommentsComplete -eq $true -and $rulingComments.Count -eq 1 -and
      [string]$provider.activation.id -ceq $frontierActivationIssueNode -and [long]$provider.activation.number -eq $frontierActivationIssue -and
      [string]$provider.activation.state -ceq "OPEN" -and [string]$provider.activation.bodySha256 -ceq $frontierActivationBodySha256 -and
      [string]$provider.activation.updatedAt -ceq [string]$record.activation.updatedAt -and
      $provider.activationBlockersComplete -eq $true -and $activationBlockers.Count -eq 2 -and
      [long]$activationBlockers[0].number -eq $frontierRetryIssue -and [string]$activationBlockers[0].state -ceq "CLOSED" -and
      [long]$activationBlockers[1].number -eq $frontierDecisionIssue -and [string]$activationBlockers[1].state -ceq "CLOSED" -and
      [string]$record.breaker.rowSha256 -ceq [string]$openRows[0].rowSha256 -and
      [string]$record.repair.bodySha256 -ceq [string]$snapshot.repair.issue.bodySha256 -and
      [long]$record.candidate.pr -eq [long]$snapshot.candidate.number -and
      [string]$record.candidate.headOid -ceq [string]$snapshot.candidate.headOid -and
      [string]$record.candidate.baseOid -ceq [string]$snapshot.candidate.baseOid -and
      [string]$record.configurationSha256 -ceq [string]$snapshot.configuration.sha256
  }
  $admitted = @($conjuncts.Values | Where-Object { $_ -ne $true }).Count -eq 0
  [ordered]@{
    admitted = $admitted
    snapshot = $snapshot
    record = $record
    admission = [ordered]@{
      schemaVersion = "breaker-repair-frontier-admission/v2"
      decision = if ($admitted) { "BREAKER_REPAIR_FRONTIER_ADMITTED" } else { "BREAKER_REPAIR_FRONTIER_REFUSED" }
      conjuncts = $conjuncts
      queuePredicates = $queuePredicates
      configurationSha256 = if ($snapshot.configuration) { $snapshot.configuration.sha256 } else { $null }
      configurationComputedSha256 = if ($snapshot.configuration.value) { Get-ConfigurationSha256 $snapshot.configuration.value } else { $null }
      collisions = @($snapshot.collisions)
      authorityBoundary = [ordered]@{ atomic = "candidate head through expectedHeadOid"; governedNotAtomic = "queue/default/configuration/repair authority through repeated reads and enforcing audit"; detectedNotPrevented = "manual administrator enqueue" }
      seed = [ordered]@{ authorityIssue = $frontierAuthorityIssue; authorityBodySha256 = $frontierAuthorityBodySha256; breaker = [ordered]@{ key = $frontierBreakerKey; openTs = $frontierBreakerOpenTs; line = $frontierBreakerLine; rowSha256 = $frontierBreakerRowSha256 }; repair = [ordered]@{ rootIssue = $frontierRootIssue; issue = $frontierRepairIssue; bodySha256 = $frontierRepairBodySha256 }; candidate = if ($snapshot.candidate) { [ordered]@{ pr = $snapshot.candidate.number; headOid = $snapshot.candidate.headOid; baseOid = $snapshot.candidate.baseOid } } else { $null } }
    }
  }
}

function Get-FixtureScenario {
  if (-not $AuthorityFixture -or -not $AuthorityScenario) {
    throw "landing-preflight fixture requires -AuthorityFixture and -AuthorityScenario"
  }
  if (-not (Test-Path -LiteralPath $AuthorityFixture -PathType Leaf)) {
    throw "landing-preflight fixture not found: $AuthorityFixture"
  }
  try {
    $fixture = Get-Content -LiteralPath $AuthorityFixture -Raw |
      ConvertFrom-Json -DateKind String -ErrorAction Stop
  } catch {
    throw "landing-preflight fixture is malformed"
  }
  if ([string]$fixture.schema -cne "landing-preflight-fixture/v1") {
    throw "landing-preflight fixture schema is unsupported"
  }
  $scenario = $fixture.scenarios.PSObject.Properties[$AuthorityScenario]
  if ($null -eq $scenario) { throw "landing-preflight fixture scenario '$AuthorityScenario' not found" }
  return $scenario.Value
}

$fixtureScenario = if ($AuthorityFixture -or $AuthorityScenario) { Get-FixtureScenario } else { $null }
$observationIndex = 0
function Get-AuthorityObservation {
  if ($fixtureScenario) {
    $observations = @($fixtureScenario.observations)
    if ($observationIndex -ge $observations.Count) {
      return [pscustomobject][ordered]@{ complete = $false; reason = "FIXTURE_OBSERVATION_MISSING"; pr = $null; deploy = $null; breaker = $null }
    }
    $observation = $observations[$observationIndex]
    $script:observationIndex += 1
    $expectedHead = if ($observation.pr) { [string]$observation.pr.head } else { "" }
    $sourceScope = if ($observation.PSObject.Properties["changeScope"]) { $observation.changeScope } else { $null }
    $observation | Add-Member -NotePropertyName changeScope -NotePropertyValue (ConvertTo-EffectiveChangeScope $sourceScope $expectedHead) -Force
    return $observation
  }
  return Get-ProductionObservation
}

function Get-ImmediateQueueObservation {
  if ($fixtureScenario) {
    $observations = @($fixtureScenario.observations)
    if ($observationIndex -ge $observations.Count) {
      return [ordered]@{ complete = $false; totalCount = $null; entries = @() }
    }
    $next = $observations[$observationIndex]
    if ($null -ne $next.decision7643Adapter) { return $next.decision7643Adapter.queue }
    if ($null -ne $next.admission) { return $next.admission.queue }
    return [ordered]@{ complete = $false; totalCount = $null; entries = @() }
  }
  Get-FrontierQueue
}

function Test-PreflightPullObservation($Observation) {
  if ($null -eq $Observation -or $Observation.complete -ne $true) {
    return [pscustomobject][ordered]@{ status = "unknown"; reason = if ($Observation.reason) { [string]$Observation.reason } else { "AUTHORITY_INCOMPLETE" } }
  }
  $pull = $Observation.pr
  if ($null -eq $pull -or
      -not (Test-WholeNumber $pull.number 1) -or [int]$pull.number -ne $Pr -or
      [string]$pull.id -notmatch "^[A-Za-z0-9_=-]+$" -or
      [string]$pull.head -cnotmatch "^[a-f0-9]{40}$" -or
      $pull.isDraft -isnot [bool]) {
    return [pscustomobject][ordered]@{ status = "unknown"; reason = "PR_AUTHORITY_MALFORMED" }
  }
  if ([string]$pull.state -cne "OPEN") {
    return [pscustomobject][ordered]@{ status = "refused"; reason = "PR_NOT_OPEN" }
  }
  if ($pull.isDraft) {
    return [pscustomobject][ordered]@{ status = "refused"; reason = "PR_DRAFT" }
  }
  return $null
}

function Test-PreflightObservation($Observation, $Review) {
  $invalid = Test-PreflightPullObservation $Observation
  if ($null -ne $invalid) { return $invalid }
  $pull = $Observation.pr
  if (-not [string]::IsNullOrWhiteSpace([string]$pull.mergeQueueEntryId)) {
    return [pscustomobject][ordered]@{ status = "refused"; reason = "PR_ALREADY_ENQUEUED" }
  }
  Test-NonHoldPreflightObservation $Observation $Review
}

function Test-NonHoldPreflightObservation($Observation, $Review) {
  $invalid = Test-PreflightPullObservation $Observation
  if ($null -ne $invalid) { return $invalid }
  $pull = $Observation.pr
  if ($null -eq $Review -or [string]$Review.currentHead -cne [string]$pull.head) {
    return [pscustomobject][ordered]@{ status = "unknown"; reason = "REVIEW_REDUCTION_HEAD_MISMATCH" }
  }
  switch ([string]$Review.state) {
    "authorized" {}
    "blocked" { return [pscustomobject][ordered]@{ status = "refused"; reason = "REVIEW_BLOCKED_$($Review.reason)" } }
    "stale" { return [pscustomobject][ordered]@{ status = "refused"; reason = "REVIEW_STALE_$($Review.reason)" } }
    default { return [pscustomobject][ordered]@{ status = "unknown"; reason = "REVIEW_AUTHORITY_$($Review.reason)" } }
  }
  if ([string]$Review.latest.authorityKind -ceq "rebase-only-continuation" -and
      ([string]$pull.baseRefName -cne "main" -or
       [string]$pull.baseHead -cnotmatch "^[a-f0-9]{40}$" -or
       [string]$Review.latest.newBase -cne [string]$pull.baseHead)) {
    return [pscustomobject][ordered]@{ status = "unknown"; reason = "CONTINUATION_BASE_HEAD_MISMATCH" }
  }
  if ($pull.branchProtectionObserved -ne $true -or $pull.requiresStatusChecks -ne $true) {
    return [pscustomobject][ordered]@{ status = "unknown"; reason = "REQUIRED_CHECK_AUTHORITY_UNOBSERVABLE" }
  }
  $required = @($pull.requiredContexts | ForEach-Object { [string]$_ })
  if ($required.Count -eq 0 -or @($required | Sort-Object -Unique).Count -ne $required.Count) {
    return [pscustomobject][ordered]@{ status = "unknown"; reason = "REQUIRED_CHECK_AUTHORITY_MALFORMED" }
  }
  $checks = @($pull.checks)
  $reductions = [Collections.Generic.List[object]]::new()
  foreach ($requiredName in $required) {
    $reduction = Reduce-RequiredCheckObservations ([object[]]$checks) $requiredName
    $reductions.Add($reduction)
    if ($pull -is [Collections.IDictionary]) {
      $pull['requiredCheckReductions'] = [object[]]@($reductions)
    } else {
      $pull | Add-Member -NotePropertyName requiredCheckReductions -NotePropertyValue ([object[]]@($reductions)) -Force
    }
    if ([string]$reduction.status -cne 'eligible') {
      return [pscustomobject][ordered]@{ status = [string]$reduction.status; reason = [string]$reduction.reason }
    }
  }
  if ([string]$pull.statusRollupState -cne "SUCCESS") {
    return [pscustomobject][ordered]@{ status = "refused"; reason = "CHECK_ROLLUP_NOT_GREEN" }
  }
  foreach ($issue in @($pull.closingIssues)) {
    if ($issue.blockersComplete -ne $true) {
      return [pscustomobject][ordered]@{ status = "unknown"; reason = "ISSUE_BLOCKER_AUTHORITY_INCOMPLETE" }
    }
    if (@($issue.blockers | Where-Object { [string]$_.state -ceq "OPEN" }).Count -gt 0) {
      return [pscustomobject][ordered]@{ status = "refused"; reason = "OPEN_NATIVE_ISSUE_BLOCKER" }
    }
  }
  if ($Observation.deploy.complete -ne $true) {
    return [pscustomobject][ordered]@{ status = "unknown"; reason = "DEPLOY_AUTHORITY_UNREADABLE" }
  }
  if ([string]$Observation.deploy.status -cne "completed" -or
      [string]$Observation.deploy.conclusion -cne "success") {
    return [pscustomobject][ordered]@{ status = "refused"; reason = "DEPLOY_UNHEALTHY" }
  }
  if ($Observation.breaker.complete -ne $true) {
    return [pscustomobject][ordered]@{ status = "unknown"; reason = if ($Observation.breaker.reason) { [string]$Observation.breaker.reason } else { "BREAKER_AUTHORITY_UNREADABLE" } }
  }
  if ($Observation.breaker.healthy -ne $true) {
    if ($Pr -eq $decision7643CandidatePr) {
      $adapter = Test-Decision7643LandingAdapter $Observation
      $script:currentAdmission = $adapter.admission
      $script:decision7643Evaluation = $adapter
      if (-not $adapter.admitted) {
        return [pscustomobject][ordered]@{ status = "refused"; reason = "PIPELINE_BREAKER_OPEN"; repair = $false; decision7643Adapter = $true }
      }
      return [pscustomobject][ordered]@{ status = "eligible"; reason = "DECISION_7643_PR_7641_ADAPTER_ADMITTED"; repair = $true; decision7643Adapter = $true }
    }
    $frontier = Test-BreakerRepairFrontier $Observation
    $script:currentAdmission = $frontier.admission
    $script:frontierEvaluation = $frontier
    # The global breaker stop remains the default arm. Only the complete exact
    # instance above can replace it; every unhandled or inexact state lands here.
    if (-not $frontier.admitted) {
      $changeScope = ConvertTo-EffectiveChangeScope $Observation.changeScope ([string]$pull.head)
      $Observation | Add-Member -NotePropertyName changeScope -NotePropertyValue $changeScope -Force
      if ($changeScope.proven -eq $true -and ([string]($changeScope.classification) -ceq "non-deployable")) {
        Set-Variable -Scope Script -Name currentAdmission -Value $null
        $script:frontierEvaluation = $null
        return [pscustomobject][ordered]@{
          status = "eligible"
          reason = "SCOPE_AWARE_BREAKER_ADMITTED"
          repair = $false
          scopeAwareBreaker = $true
        }
      }
      return [pscustomobject][ordered]@{ status = "refused"; reason = "PIPELINE_BREAKER_OPEN"; repair = $false; scopeAwareBreaker = $false }
    }
    return [pscustomobject][ordered]@{ status = "eligible"; reason = "BREAKER_REPAIR_FRONTIER_ADMITTED"; repair = $true }
  }
  [pscustomobject][ordered]@{ status = "eligible"; reason = "ALL_AUTHORITY_CURRENT"; repair = $false }
}

function Get-ReviewReduction([string]$Head) {
  $history = Read-ExactHeadReviewHistory -Path $HistoryPath -MaxRows $MaxHistoryRows -MaxBytes $MaxHistoryBytes
  Reduce-ExactHeadReview -Pr $Pr -CurrentHead $Head -History $history
}



function Test-DirectLandingAuthorityComplete($Observation, $Review) {
  if ($ControllerCandidate -or $null -eq $Observation -or $Observation.complete -ne $true -or
      $null -eq $Observation.pr) { return $false }
  $pull = $Observation.pr
  if (-not (Test-WholeNumber $pull.number 1) -or [int]$pull.number -ne $Pr -or
      [string]$pull.id -cnotmatch '^[A-Za-z0-9_=-]+$' -or
      [string]$pull.head -cnotmatch '^[a-f0-9]{40}$' -or
      [string]$pull.state -cne 'OPEN' -or $pull.isDraft -ne $false -or
      -not [string]::IsNullOrWhiteSpace([string]$pull.mergeQueueEntryId)) { return $false }
  if ($null -eq $Review -or [string]$Review.state -cne 'authorized' -or
      [string]$Review.currentHead -cne [string]$pull.head -or
      ([string]$Review.latest.reviewedHead -cne [string]$pull.head -and
        [string]$Review.latest.authorizedHead -cne [string]$pull.head) -or
       [string]$Review.latest.outcome -cne 'PASS' -or
       [string]$Review.latest.receiptIdentity -cnotmatch '^[a-f0-9]{64}$') { return $false }
  if ([string]$Review.latest.authorityKind -ceq 'rebase-only-continuation' -and
      ([string]$pull.baseRefName -cne 'main' -or
       [string]$pull.baseHead -cnotmatch '^[a-f0-9]{40}$' -or
       [string]$Review.latest.newBase -cne [string]$pull.baseHead)) { return $false }
  if ($pull.branchProtectionObserved -ne $true -or $pull.requiresStatusChecks -ne $true -or
      [string]$pull.statusRollupState -cne 'SUCCESS') { return $false }
  $required = @($pull.requiredContexts | ForEach-Object { [string]$_ })
  if ($required.Count -eq 0 -or @($required | Sort-Object -Unique).Count -ne $required.Count) { return $false }
  foreach ($requiredName in $required) {
    if ([string](Reduce-RequiredCheckObservations @($pull.checks) $requiredName).status -cne 'eligible') { return $false }
  }
  foreach ($issue in @($pull.closingIssues)) {
    if ($issue.blockersComplete -ne $true -or
        @($issue.blockers | Where-Object { [string]$_.state -ceq 'OPEN' }).Count -gt 0) { return $false }
  }
  # A product PR is direct-enqueue qualified only when no pipeline breaker can
  # hold its deployable. Scope-aware and incident-repair exceptions continue
  # through normal Apply, where their stronger admission audits remain intact.
  return $Observation.breaker.complete -eq $true -and $Observation.breaker.healthy -eq $true
}

function Get-ScopeAwareBreakerProjection($Observation) {
  [ordered]@{
    head = [string]$Observation.pr.head
    changeScope = ConvertTo-EffectiveChangeScope $Observation.changeScope ([string]$Observation.pr.head)
    breaker = [ordered]@{
      complete = $Observation.breaker.complete
      healthy = $Observation.breaker.healthy
      open = [string[]]@($Observation.breaker.open)
      openRows = [object[]]@($Observation.breaker.openRows)
    }
  }
}

function New-EnqueueMutationResult($GraphResult, [string]$RequestedClientMutationId, [bool]$RequireClosedEntry) {
  $payload = $GraphResult.payload
  $dataPresent = Test-ObjectProperty $payload "data"
  $dataValue = if ($dataPresent) { Get-ObjectValue $payload "data" } else { $null }
  $errorsPresent = Test-ObjectProperty $payload "errors"
  $errorsValue = if ($errorsPresent) { Get-ObjectValue $payload "errors" } else { $null }
  $dataEvidence = New-FieldEvidence $dataPresent $dataValue ($dataPresent -and $null -ne $dataValue -and (Get-ObservedType $dataValue $true) -ceq "object")
  $errorsType = Get-ObservedType $errorsValue $errorsPresent
  $errorsEvidence = New-FieldEvidence $errorsPresent $errorsValue ((-not $errorsPresent) -or $null -eq $errorsValue -or $errorsType -ceq "array")

  $enqueue = if ($null -ne $dataValue -and (Test-ObjectProperty $dataValue "enqueuePullRequest")) {
    Get-ObjectValue $dataValue "enqueuePullRequest"
  } else { $null }
  $returnedClientMutationId = if ($null -ne $enqueue -and (Test-ObjectProperty $enqueue "clientMutationId")) {
    Get-ObjectValue $enqueue "clientMutationId"
  } else { $null }
  $clientPresent = $null -ne $enqueue -and (Test-ObjectProperty $enqueue "clientMutationId")
  $clientEvidence = New-FieldEvidence $clientPresent $returnedClientMutationId (
    $clientPresent -and $returnedClientMutationId -is [string] -and
    [string]$returnedClientMutationId -ceq $RequestedClientMutationId
  )
  $entryValue = if ($null -ne $enqueue -and (Test-ObjectProperty $enqueue "mergeQueueEntry")) {
    Get-ObjectValue $enqueue "mergeQueueEntry"
  } else { $null }
  $entry = if ($null -ne $entryValue) { ConvertTo-QueueEntryObservation $entryValue } else { $null }
  $entryId = if ($null -ne $entryValue -and (Test-ObjectProperty $entryValue "id") -and
      (Get-ObjectValue $entryValue "id") -is [string] -and
      [string](Get-ObjectValue $entryValue "id") -cmatch "^[A-Za-z0-9_=-]+$") {
    [string](Get-ObjectValue $entryValue "id")
  } else { $null }
  $confirmed = $GraphResult.complete -eq $true -and $clientEvidence.predicate -eq $true -and $null -ne $entryId -and
    (-not $RequireClosedEntry -or ($null -ne $entry -and $entry.valid -eq $true -and
      [string]$entry.stable.entryId -ceq [string]$entryId))
  [pscustomobject][ordered]@{
    complete = $confirmed
    reason = if ($confirmed) { "ENQUEUED" } elseif ($null -eq $entryId) { "ENQUEUE_ENTRY_ID_UNCONFIRMED" } else { "ENQUEUE_MUTATION_UNCONFIRMED" }
    entryId = $entryId
    entry = $entry
    clientMutationId = $clientEvidence
    graphql = [ordered]@{
      schemaVersion = "graphql-mutation-envelope/v1"
      process = [ordered]@{
        exitCode = if ($null -ne $GraphResult.process) { [int]$GraphResult.process.exitCode } else { 126 }
        stdout = if ($null -ne $GraphResult.process) { [string]$GraphResult.process.stdout } else { "" }
        stderr = if ($null -ne $GraphResult.process) { [string]$GraphResult.process.stderr } else { "missing process result" }
      }
      data = $dataEvidence
      errors = $errorsEvidence
    }
  }
}

function Get-FixtureEnqueueGraphResult($FixtureMutation, [string]$RequestedClientMutationId) {
  if ($FixtureMutation.graphql) {
    $payload = $FixtureMutation.graphql.payload
    $exitCode = [int]$FixtureMutation.graphql.exitCode
    $stdout = if (Test-ObjectProperty $FixtureMutation.graphql "stdout") { [string]$FixtureMutation.graphql.stdout } else { $payload | ConvertTo-Json -Compress -Depth 100 }
    $stderr = if (Test-ObjectProperty $FixtureMutation.graphql "stderr") { [string]$FixtureMutation.graphql.stderr } else { "" }
    $hasErrors = (Test-ObjectProperty $payload "errors") -and $null -ne $payload.errors -and @($payload.errors).Count -gt 0
    return [pscustomobject][ordered]@{
      complete = $exitCode -eq 0 -and -not $hasErrors -and $null -ne $payload.data
      reason = "FIXTURE_GRAPHQL"
      payload = $payload
      process = [ordered]@{ exitCode = $exitCode; stdout = $stdout; stderr = $stderr }
    }
  }
  $entryValue = if ($FixtureMutation.complete -eq $true -and $FixtureMutation.entry) {
    $FixtureMutation.entry
  } elseif ($FixtureMutation.complete -eq $true -and -not [string]::IsNullOrWhiteSpace([string]$FixtureMutation.entryId)) {
    [ordered]@{ id = [string]$FixtureMutation.entryId }
  } else { $null }
  $payload = [ordered]@{
    data = [ordered]@{
      enqueuePullRequest = [ordered]@{
        clientMutationId = $RequestedClientMutationId
        mergeQueueEntry = $entryValue
      }
    }
  }
  $stdout = $payload | ConvertTo-Json -Compress -Depth 100
  [pscustomobject][ordered]@{
    complete = $FixtureMutation.complete -eq $true
    reason = "FIXTURE_GRAPHQL"
    payload = $payload
    process = [ordered]@{ exitCode = $(if ($FixtureMutation.complete -eq $true) { 0 } else { 1 }); stdout = $stdout; stderr = $(if ($FixtureMutation.complete -eq $true) { "" } else { "synthetic enqueue failure" }) }
  }
}

function Invoke-EnqueueMutation([string]$PullRequestId, [string]$ExpectedHeadOid = "", [bool]$RepairAdmission = $false) {
  if ($MutationDisabled) {
    return [pscustomobject][ordered]@{ complete = $false; reason = "MUTATION_HARD_DISABLED"; entryId = $null; entry = $null; clientMutationId = $null; graphql = $null }
  }
  $mutation = @'
mutation($pullRequestId:ID!, $clientMutationId:String!, $expectedHeadOid:GitObjectID!, $jump:Boolean!) {
  enqueuePullRequest(input:{pullRequestId:$pullRequestId, clientMutationId:$clientMutationId, expectedHeadOid:$expectedHeadOid, jump:$jump}) {
    clientMutationId
    mergeQueueEntry { id position state solo jump baseCommit{oid} headCommit{oid} pullRequest{id number headRefOid} }
  }
}
'@
  $variables = @{
    pullRequestId = $PullRequestId
    clientMutationId = "landing-preflight-$([guid]::NewGuid().ToString("N"))"
  }
  $variables.expectedHeadOid = $ExpectedHeadOid
  $variables.jump = "false"
  $result = if ($fixtureScenario) {
    $fixtureMutation = if ($fixtureScenario.mutation.enqueue) { $fixtureScenario.mutation.enqueue } else { $fixtureScenario.mutation }
    Get-FixtureEnqueueGraphResult $fixtureMutation ([string]$variables.clientMutationId)
  } else {
    Invoke-GhGraphQl $mutation $variables
  }
  New-EnqueueMutationResult $result ([string]$variables.clientMutationId) $RepairAdmission
}

function Invoke-DequeueMutation([string]$PullRequestId, [string]$ExpectedEntryId) {
  if ($fixtureScenario) {
    $fixtureMutation = $fixtureScenario.mutation.dequeue
    $fixtureEntryId = if ($fixtureMutation.complete -eq $true) { [string]$fixtureMutation.entryId } else { $null }
    return [pscustomobject][ordered]@{ complete = $fixtureMutation.complete -eq $true -and $fixtureEntryId -ceq $ExpectedEntryId; entryId = $fixtureEntryId }
  }
  $mutation = @'
mutation($id:ID!,$clientMutationId:String!){
  dequeuePullRequest(input:{id:$id,clientMutationId:$clientMutationId}){clientMutationId mergeQueueEntry{id}}
}
'@
  $result = Invoke-GhGraphQl $mutation @{ id = $PullRequestId; clientMutationId = "landing-preflight-dequeue-$([guid]::NewGuid().ToString("N"))" }
  $entryId = if ($result.complete) { [string]$result.payload.data.dequeuePullRequest.mergeQueueEntry.id } else { "" }
  [pscustomobject][ordered]@{ complete = $result.complete -and $entryId -ceq $ExpectedEntryId; entryId = if ($result.complete) { $entryId } else { $null } }
}

$script:currentAdmission = $null
$script:frontierEvaluation = $null
$script:decision7643Evaluation = $null
$script:enqueueAttempts = 0
$script:dequeueAttempts = 0
$initial = Get-AuthorityObservation
$initialReview = if ($initial.pr -and [string]$initial.pr.head -cmatch "^[a-f0-9]{40}$") {
  Get-ReviewReduction ([string]$initial.pr.head)
} else {
  $null
}
$initialDecision = Test-PreflightObservation $initial $initialReview
$initialFrontier = $script:frontierEvaluation
$initialDecision7643 = $script:decision7643Evaluation
$initialDirectAuthority = Test-DirectLandingAuthorityComplete $initial $initialReview
if ($initialDecision.status -ne "eligible") {
  if ($Action -ne 'Apply' -or -not $initialDirectAuthority -or $MutationDisabled) {
    New-PreflightResult $initialDecision.status $initialDecision.reason 0 $initial $null $initialReview |
      ConvertTo-Json -Depth 100
    return
  }
}

function Invoke-ControllerP0DirectEnqueue($InitialObservation, $FinalObservation, $Review, [string]$RefusalReason) {
  $script:enqueueAttempts = 1
  $mutation = Invoke-EnqueueMutation ([string]$FinalObservation.pr.id) ([string]$FinalObservation.pr.head) $false
  $actualResult = if ($mutation.complete) { 'confirmed' } else { 'unknown' }
  $actualReason = if ($mutation.complete) { 'DIRECT_ENQUEUE_CONFIRMED' } else { 'DIRECT_ENQUEUE_RESPONSE_UNKNOWN' }
  $entryId = [string]$mutation.entryId
  $reconciliation = $null
  if (-not $mutation.complete) {
    $queue = Get-ImmediateQueueObservation
    $matches = @($queue.entries | Where-Object {
        $_.valid -eq $true -and [int]$_.stable.pullRequest.number -eq $Pr -and
        [string]$_.stable.pullRequest.id -ceq [string]$FinalObservation.pr.id -and
        [string]$_.stable.pullRequest.headOid -ceq [string]$FinalObservation.pr.head
      })
    $reconciliation = [ordered]@{ complete=$queue.complete -eq $true; matches=$matches.Count }
    if ($queue.complete -eq $true -and $matches.Count -eq 1) {
      $actualResult = 'reconciled'; $actualReason = 'DIRECT_ENQUEUE_RECONCILED'
      $entryId = [string]$matches[0].stable.entryId
    }
  }
  $logArguments = @{Log='dispatch';Kind='landing-stall';Pr=$Pr;LandingHead=[string]$FinalObservation.pr.head;RefusalReason=$RefusalReason;PassReceiptIdentity=[string]$Review.latest.receiptIdentity;ActualEnqueueResult=$actualResult;ActualEnqueueReason=$actualReason;OutFile=$HistoryPath;NoBoard=$true}
  if ($entryId) { $logArguments.ActualEnqueueEntryId = $entryId }
  $logged=$true;$logFailure=$null
  try {[void](& (Join-Path $PSScriptRoot 'log-event.ps1') @logArguments)} catch {$logged=$false;$logFailure=$_.Exception.Message}
  $stall=[ordered]@{schemaVersion='landing-stall/v1';logged=$logged;refusalReason=$RefusalReason;enqueue=[ordered]@{attempted=$true;result=$actualResult;reason=$actualReason;entryId=$(if($entryId){$entryId}else{$null});expectedHeadOid=[string]$FinalObservation.pr.head;jump=$false};reconciliation=$reconciliation;logFailure=$logFailure}
  $status=if(-not$logged){'unknown'}elseif($actualResult-in@('confirmed','reconciled')){'enqueued'}else{'unknown'}
  $reason=if(-not$logged){'LANDING_STALL_RECORD_FAILED'}elseif($status-ceq'enqueued'){'CONTROLLER_P0_DIRECT_ENQUEUE_CONFIRMED'}else{'CONTROLLER_P0_DIRECT_ENQUEUE_FAILED'}
  $result=New-PreflightResult $status $reason 1 $InitialObservation $FinalObservation $Review
  $result|Add-Member -NotePropertyName landingStall -NotePropertyValue $stall
  $result|Add-Member -NotePropertyName enqueueAttempts -NotePropertyValue 1 -Force
  if($entryId){$result|Add-Member -NotePropertyName mergeQueueEntryId -NotePropertyValue $entryId}
  $result
}
if ($Action -eq "Report") {
  New-PreflightResult "eligible" "REPORT_ONLY_ELIGIBLE" 0 $initial $null $initialReview |
    ConvertTo-Json -Depth 100
  return
}
if ($MutationDisabled) {
  New-PreflightResult "refused" "MUTATION_HARD_DISABLED" 0 $initial $null $initialReview |
    ConvertTo-Json -Depth 100
  return
}

$final = Get-AuthorityObservation
if ($null -eq $final.pr -or [string]$final.pr.head -cne [string]$initial.pr.head) {
  New-PreflightResult "unknown" "HEAD_MOVED_BETWEEN_READS" 0 $initial $final $initialReview |
    ConvertTo-Json -Depth 100
  return
}
$finalReview = Get-ReviewReduction ([string]$final.pr.head)
$script:frontierEvaluation = $null
$script:decision7643Evaluation = $null
$finalDecision = Test-PreflightObservation $final $finalReview
$finalFrontier = $script:frontierEvaluation
$finalDecision7643 = $script:decision7643Evaluation
if ($finalDecision.status -ne "eligible") {
  $finalDirectAuthority = Test-DirectLandingAuthorityComplete $final $finalReview
  if ($initialDirectAuthority -and $finalDirectAuthority) {
    Invoke-ControllerP0DirectEnqueue $initial $final $finalReview ([string]$finalDecision.reason) |
      ConvertTo-Json -Depth 100
  } else {
    New-PreflightResult $finalDecision.status $finalDecision.reason 0 $initial $final $finalReview |
      ConvertTo-Json -Depth 100
  }
  return
}

$scopeAwareBreakerAdmission = $initialDecision.scopeAwareBreaker -eq $true -or $finalDecision.scopeAwareBreaker -eq $true
if ($scopeAwareBreakerAdmission) {
  $scopeStable = $initialDecision.scopeAwareBreaker -eq $true -and
    $finalDecision.scopeAwareBreaker -eq $true -and
    (Get-CanonicalSha256 (Get-ScopeAwareBreakerProjection $initial)) -ceq
      (Get-CanonicalSha256 (Get-ScopeAwareBreakerProjection $final))
  if (-not $scopeStable) {
    $final.changeScope = New-FailClosedChangeScopeObservation ([string]$final.pr.head) "CHANGE_SCOPE_MOVED_BETWEEN_READS" $final.changeScope
    New-PreflightResult "refused" "PIPELINE_BREAKER_OPEN" 0 $initial $final $finalReview |
      ConvertTo-Json -Depth 100
    return
  }
}

$repairAdmission = $initialDecision.repair -eq $true -or $finalDecision.repair -eq $true
$decision7643Admission = $initialDecision.decision7643Adapter -eq $true -or $finalDecision.decision7643Adapter -eq $true
if ($repairAdmission) {
  if ($decision7643Admission) {
    if ($initialDecision.repair -ne $true -or $finalDecision.repair -ne $true -or
        $initialDecision.decision7643Adapter -ne $true -or $finalDecision.decision7643Adapter -ne $true -or
        (Get-CanonicalSha256 (Get-Decision7643StableProjection $initialDecision7643.snapshot)) -cne
          (Get-CanonicalSha256 (Get-Decision7643StableProjection $finalDecision7643.snapshot))) {
      $script:currentAdmission.decision = "DECISION_7643_PR_7641_ADAPTER_REFUSED"
      New-PreflightResult "refused" "PIPELINE_BREAKER_OPEN" 0 $initial $final $finalReview |
        ConvertTo-Json -Depth 100
      return
    }
    $script:currentAdmission.preMutation = [ordered]@{ status = "eligible"; reason = "DECISION_7643_PR_7641_ADAPTER_ADMITTED" }
  } else {
    if ($initialDecision.repair -ne $true -or $finalDecision.repair -ne $true -or
        (Get-CanonicalSha256 (Get-FrontierStableProjection $initialFrontier.snapshot)) -cne
          (Get-CanonicalSha256 (Get-FrontierStableProjection $finalFrontier.snapshot))) {
      $script:currentAdmission.decision = "BREAKER_REPAIR_FRONTIER_REFUSED"
      New-PreflightResult "refused" "PIPELINE_BREAKER_OPEN" 0 $initial $final $finalReview |
        ConvertTo-Json -Depth 100
      return
    }
    $script:currentAdmission.preMutation = [ordered]@{ status = "eligible"; reason = "BREAKER_REPAIR_FRONTIER_ADMITTED" }
    if ([string]$finalFrontier.record.schemaVersion -ceq "breaker-repair-frontier-retry-authority/v1") {
      $remoteConsumption = Invoke-RetryConsumptionProtocol $finalFrontier.record
      $script:currentAdmission.remoteConsumption = $remoteConsumption
      if ($remoteConsumption.complete -ne $true) {
        $script:currentAdmission.decision = "RETRY_CONSUMPTION_PARK"
        $script:currentAdmission.nonPass = "PARK"
        New-PreflightResult "refused" $remoteConsumption.reason 0 $initial $final $finalReview |
          ConvertTo-Json -Depth 100
        return
      }
    }
  }
}

$script:enqueueAttempts = 1
$mutationCount = 1
$mutationResult = Invoke-EnqueueMutation ([string]$final.pr.id) ([string]$final.pr.head) $repairAdmission
if ($repairAdmission) {
  $script:currentAdmission.mutation = [ordered]@{
    schemaVersion = if ($decision7643Admission) { "decision-7643-pr-7641-landing-adapter-mutation/v1" } else { "breaker-repair-frontier-mutation/v1" }
    reason = $mutationResult.reason
    entryId = $mutationResult.entryId
    clientMutationId = $mutationResult.clientMutationId
    entry = $mutationResult.entry
    graphql = $mutationResult.graphql
  }
}
if (-not $repairAdmission -and -not $mutationResult.complete) {
  New-PreflightResult "unknown" $mutationResult.reason $mutationCount $initial $final $finalReview |
    ConvertTo-Json -Depth 100
  return
}
$audit = $null
if ($repairAdmission) {
  # The complete paginated queue is deliberately the first provider
  # observation after the enqueue response. No admission branch precedes it.
  $immediateQueue = Get-ImmediateQueueObservation
  if ([string]::IsNullOrWhiteSpace([string]$mutationResult.entryId)) {
    $queueEntries = @($immediateQueue.entries)
    $auditCandidate = if ($decision7643Admission) { $finalDecision7643.snapshot.candidate } else { $finalFrontier.snapshot.candidate }
    $queuePredicates = Get-StableEntryConjuncts $mutationResult $(if ($queueEntries.Count -eq 1) { $queueEntries[0] } else { $null }) $auditCandidate
    $audit = [ordered]@{
      schemaVersion = if ($decision7643Admission) { "decision-7643-pr-7641-landing-adapter-audit/v1" } else { "breaker-repair-frontier-audit/v1" }
      decision = "unknown"
      entryShape = $null -ne $mutationResult.entry -and $mutationResult.entry.valid -eq $true
      stableAuthority = $false
      immediateQueue = $immediateQueue
      observation = $null
      conjuncts = [ordered]@{ entryIdConfirmed = $false; completeAuthorityAudit = $false }
      queuePredicates = $queuePredicates
      failedPredicates = [string[]]@($queuePredicates.Keys | Where-Object { $queuePredicates[$_] -ne $true })
    }
    $script:currentAdmission.audit = $audit
    $script:currentAdmission.decision = "ENQUEUE_UNKNOWN_PARK"
    $script:currentAdmission.nonPass = "PARK"
    New-PreflightResult "unknown" "ENQUEUE_ENTRY_ID_UNCONFIRMED" $mutationCount $initial $final $finalReview |
      ConvertTo-Json -Depth 100
    return
  }
  $auditObservation = Get-AuthorityObservation
  $auditEvaluation = if ($decision7643Admission) {
    Test-Decision7643LandingAdapter $auditObservation $mutationResult $immediateQueue
  } else {
    Test-BreakerRepairFrontier $auditObservation $mutationResult $immediateQueue
  }
  $stable = if ($decision7643Admission) {
    $auditEvaluation.admitted -and
      (Get-CanonicalSha256 (Get-Decision7643StableProjection $auditEvaluation.snapshot)) -ceq
        (Get-CanonicalSha256 (Get-Decision7643StableProjection $finalDecision7643.snapshot))
  } else {
    $auditEvaluation.admitted -and
      (Get-CanonicalSha256 (Get-FrontierStableProjection $auditEvaluation.snapshot)) -ceq
        (Get-CanonicalSha256 (Get-FrontierStableProjection $finalFrontier.snapshot))
  }
  $failedPredicates = [Collections.Generic.List[string]]::new()
  foreach ($entry in $auditEvaluation.admission.conjuncts.GetEnumerator()) { if ($entry.Value -ne $true) { $failedPredicates.Add("authority.$($entry.Key)") } }
  foreach ($entry in $auditEvaluation.admission.queuePredicates.GetEnumerator()) { if ($entry.Value -ne $true) { $failedPredicates.Add("entry.$($entry.Key)") } }
  $audit = [ordered]@{
    schemaVersion = if ($decision7643Admission) { "decision-7643-pr-7641-landing-adapter-audit/v1" } else { "breaker-repair-frontier-audit/v1" }
    decision = if ($stable) { "confirmed" } else { "compromised" }
    entryShape = $null -ne $mutationResult.entry -and $mutationResult.entry.valid -eq $true
    stableAuthority = $stable
    immediateQueue = $immediateQueue
    observation = $auditObservation
    conjuncts = $auditEvaluation.admission.conjuncts
    queuePredicates = $auditEvaluation.admission.queuePredicates
    failedPredicates = [string[]]@($failedPredicates)
  }
  $script:currentAdmission.audit = $audit
  if (-not $stable) {
    $script:dequeueAttempts = 1
    $mutationCount = 2
    $dequeue = Invoke-DequeueMutation ([string]$final.pr.id) ([string]$mutationResult.entryId)
    $script:currentAdmission.decision = if ($dequeue.complete) { "ADMISSION_COMPROMISE_RECOVERED" } else { "ADMISSION_COMPROMISE_UNRECOVERED" }
    $script:currentAdmission.nonPass = "PARK"
    $status = if ($dequeue.complete) { "refused" } else { "unknown" }
    $reason = if ($dequeue.complete) { "ADMISSION_COMPROMISE_RECOVERED" } else { "ADMISSION_COMPROMISE_UNRECOVERED" }
    New-PreflightResult $status $reason $mutationCount $initial $final $finalReview |
      ConvertTo-Json -Depth 100
    return
  }
}
$result = New-PreflightResult "enqueued" "ENQUEUE_CONFIRMED" $mutationCount $initial $final $finalReview
$result | Add-Member -NotePropertyName mergeQueueEntryId -NotePropertyValue $mutationResult.entryId
$result | ConvertTo-Json -Depth 100
