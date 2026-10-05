<#
.SYNOPSIS
Report exact-head review authorization coverage for every ready or enqueued PR.
#>
[CmdletBinding()]
param(
  [ValidatePattern("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")]
  [string]$Repository = "chase-sets/chase-sets",
  [string]$HistoryPath = (Join-Path $PSScriptRoot "dispatch-log.jsonl"),
  [ValidateRange(1, 1000000)][int]$MaxHistoryRows = 50000,
  [ValidateRange(1, [long]::MaxValue)][long]$MaxHistoryBytes = 33554432,
  [switch]$SkipRemoteProbes,
  [string]$AuthorityFixture,
  [string]$AuthorityScenario,
  [Parameter(DontShow)][string]$GhCommand = "gh"
)

$ErrorActionPreference = "Stop"
$schema = "exact-head-review-queue-health/v1"
Import-Module (Join-Path $PSScriptRoot "review-head-contract.psm1") -Force -DisableNameChecking

function Invoke-QueueProcess([string]$Command, [string[]]$Arguments) {
  try {
    $resolved = Get-Command $Command -CommandType Application -ErrorAction Stop | Select-Object -First 1
  } catch {
    return [pscustomobject][ordered]@{ exitCode = 127; stdout = "" }
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
    }
  } catch {
    [pscustomobject][ordered]@{ exitCode = 126; stdout = "" }
  } finally {
    $process.Dispose()
  }
}

function Get-QueueFixture {
  if (-not $AuthorityFixture -or -not $AuthorityScenario) {
    throw "review-queue fixture requires -AuthorityFixture and -AuthorityScenario"
  }
  try {
    $fixture = Get-Content -LiteralPath $AuthorityFixture -Raw |
      ConvertFrom-Json -DateKind String -ErrorAction Stop
  } catch {
    throw "review-queue fixture is missing or malformed"
  }
  if ([string]$fixture.schema -cne "review-queue-health-fixture/v1") {
    throw "review-queue fixture schema is unsupported"
  }
  $scenario = $fixture.scenarios.PSObject.Properties[$AuthorityScenario]
  if ($null -eq $scenario) { throw "review-queue fixture scenario '$AuthorityScenario' not found" }
  $scenario.Value
}

function Get-LiveQueue {
  if ($SkipRemoteProbes) {
    return [pscustomobject][ordered]@{ complete = $false; reason = "REMOTE_PROBES_SKIPPED"; prs = @() }
  }
  $owner, $name = $Repository.Split("/")
  $query = @'
query($owner:String!, $name:String!) {
  repository(owner:$owner, name:$name) {
    pullRequests(first:100, states:OPEN, orderBy:{field:UPDATED_AT,direction:DESC}) {
      totalCount
      pageInfo { hasNextPage endCursor }
      nodes {
        number
        isDraft
        headRefOid
        mergeQueueEntry { id }
      }
    }
  }
}
'@
  $queryPath = Join-Path ([IO.Path]::GetTempPath()) ("review-queue-" + [guid]::NewGuid().ToString("N") + ".graphql")
  try {
    [IO.File]::WriteAllText($queryPath, $query, [Text.UTF8Encoding]::new($false))
    $result = Invoke-QueueProcess $GhCommand @(
      "api", "graphql",
      "-F", "query=@$queryPath",
      "-F", "owner=$owner",
      "-F", "name=$name"
    )
    if ($result.exitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.stdout)) {
      return [pscustomobject][ordered]@{ complete = $false; reason = "GITHUB_QUEUE_UNREADABLE"; prs = @() }
    }
    try {
      $payload = $result.stdout | ConvertFrom-Json -DateKind String -ErrorAction Stop
    } catch {
      return [pscustomobject][ordered]@{ complete = $false; reason = "GITHUB_QUEUE_MALFORMED"; prs = @() }
    }
    $hasErrors = $null -ne $payload.PSObject.Properties["errors"] -and
      -not [object]::ReferenceEquals($null, $payload.PSObject.Properties["errors"].Value) -and
      @($payload.PSObject.Properties["errors"].Value).Count -gt 0
    if ($hasErrors -or $null -eq $payload.data.repository.pullRequests) {
      return [pscustomobject][ordered]@{ complete = $false; reason = "GITHUB_QUEUE_ERRORS"; prs = @() }
    }
    $connection = $payload.data.repository.pullRequests
    $nodes = @($connection.nodes)
    if ($connection.pageInfo.hasNextPage -ne $false -or
        -not (Test-WholeNumber $connection.totalCount 0) -or
        $nodes.Count -ne [int64]$connection.totalCount) {
      return [pscustomobject][ordered]@{ complete = $false; reason = "GITHUB_QUEUE_PAGINATION_INCOMPLETE"; prs = @($nodes) }
    }
    [pscustomobject][ordered]@{
      complete = $true
      reason = "GITHUB_QUEUE_COMPLETE"
      prs = @($nodes | ForEach-Object {
          [ordered]@{
            number = $_.number
            isDraft = $_.isDraft
            head = [string]$_.headRefOid
            mergeQueueEntryId = if ($_.mergeQueueEntry) { [string]$_.mergeQueueEntry.id } else { $null }
          }
        })
    }
  } finally {
    if (Test-Path -LiteralPath $queryPath -PathType Leaf) {
      Remove-Item -LiteralPath $queryPath -Force -ErrorAction SilentlyContinue
    }
  }
}

$queue = if ($AuthorityFixture -or $AuthorityScenario) { Get-QueueFixture } else { Get-LiveQueue }
$history = Read-ExactHeadReviewHistory -Path $HistoryPath -MaxRows $MaxHistoryRows -MaxBytes $MaxHistoryBytes

$legacy = 0
$exact = 0
$malformedExact = 0
$quarantinedNonPr = 0
$planning = 0
$controller = 0
$controllerClassifications = @()
if ($history.complete) {
  $recordVocabulary = Get-ReviewRecordVocabulary
  foreach ($entry in @($history.rows)) {
    $row = $entry.value
    $controllerClassification = Get-ControllerReviewRowClassification $entry $recordVocabulary
    if ($controllerClassification.strict -or $controllerClassification.legacy) {
      $controllerClassifications += $controllerClassification
      if ($controllerClassification.rowKind -in @("receipt","legacy") -and [string]$row.kind -ceq "review-complete") { $controller += 1 }
      continue
    }
    if ([string]$row.kind -cne "review-complete") { continue }
    $prDomain = Get-OrdinaryReviewPrDomain $row
    if ($prDomain.state -ceq "explicit-non-pr") {
      $quarantinedNonPr += 1
      continue
    }
    if (Test-PlanningReviewReceiptIdentity $row) {
      $planning += 1
      continue
    }
    if ($row.PSObject.Properties["receiptSchema"] -or
        $row.PSObject.Properties["reviewedHead"] -or
        $row.PSObject.Properties["reviewerAttempt"] -or
        $row.PSObject.Properties["authorAttempt"]) {
      $validation = Get-ReviewReceiptValidation $row $recordVocabulary
      if ($validation.valid) { $exact += 1 } else { $malformedExact += 1 }
    } else {
      $legacy += 1
    }
  }
}
$controllerReductions = @()
if($history.complete){
  $strictIdentities=@($controllerClassifications|Where-Object{$_.strict-and$_.valid}|ForEach-Object{"$($_.issue)|$($_.controllerHead)|$($_.version)"}|Sort-Object -Unique)
  foreach($identity in $strictIdentities){
    $parts=$identity-split'\|',3
    $mode=if($parts[2]-ceq'v2'){'strict-v2'}else{'strict-v1'}
    $controllerReductions += Reduce-ControllerReleaseReview -Issue ([int]$parts[0]) -ControllerHead $parts[1] -Mode $mode -History $history
  }
}
$coverageMode = if ($exact -gt 0 -and $legacy -gt 0) {
  "mixed"
} elseif ($exact -gt 0) {
  "exact-head"
} elseif ($legacy -gt 0) {
  "legacy-only"
} else {
  "none"
}

$candidates = @()
foreach ($pull in @($queue.prs)) {
  if ($pull.isDraft -eq $true -and [string]::IsNullOrWhiteSpace([string]$pull.mergeQueueEntryId)) { continue }
  if (-not (Test-WholeNumber $pull.number 1) -or
      [string]$pull.head -cnotmatch "^[a-f0-9]{40}$" -or
      $pull.isDraft -isnot [bool]) {
    $candidates += [ordered]@{
      pr = if (Test-WholeNumber $pull.number 1) { $pull.number } else { $null }
      head = [string]$pull.head
      enqueued = -not [string]::IsNullOrWhiteSpace([string]$pull.mergeQueueEntryId)
      state = "unknown"
      reason = "PR_AUTHORITY_MALFORMED"
    }
    continue
  }
  $reduction = Reduce-ExactHeadReview -Pr ([int]$pull.number) -CurrentHead ([string]$pull.head) -History $history
  $candidates += [ordered]@{
    pr = [int]$pull.number
    head = [string]$pull.head
    enqueued = -not [string]::IsNullOrWhiteSpace([string]$pull.mergeQueueEntryId)
    state = [string]$reduction.state
    reason = [string]$reduction.reason
  }
}
$deficits = @($candidates | Where-Object { $_.state -ne "authorized" })
$status = if (-not $queue.complete) { "unknown" } elseif (-not $history.complete) { "unknown" } elseif ($deficits.Count -gt 0) { "debt" } else { "healthy" }
$reason = if (-not $queue.complete) {
  [string]$queue.reason
} elseif (-not $history.complete) {
  [string]$history.reason
} elseif ($deficits.Count -gt 0) {
  "READY_OR_ENQUEUED_PR_LACKS_CURRENT_RECEIPT"
} elseif ($candidates.Count -eq 0) {
  "NO_READY_OR_ENQUEUED_PRS"
} else {
  "ALL_READY_AND_ENQUEUED_PRS_AUTHORIZED"
}

[pscustomobject][ordered]@{
  schema = $schema
  status = $status
  reason = $reason
  repository = $Repository
  candidates = @($candidates)
  deficits = @($deficits)
  coverage = [ordered]@{
    mode = $coverageMode
    exactHeadReceipts = $exact
    planningReceipts = $planning
    malformedExactHeadReceipts = $malformedExact
    quarantinedNonPrReceipts = $quarantinedNonPr
    legacyReceipts = $legacy
    controllerReceipts = $controller
    retroactiveAuthorization = 0
  }
  authority = [ordered]@{
    queueComplete = [bool]$queue.complete
    historyComplete = [bool]$history.complete
    controllerReductions = @($controllerReductions)
  }
} | ConvertTo-Json -Depth 8
