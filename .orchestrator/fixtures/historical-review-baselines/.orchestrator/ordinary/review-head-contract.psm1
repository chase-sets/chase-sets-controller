$ErrorActionPreference = "Stop"

$script:ReviewReceiptSchema = "exact-head-review-receipt/v1"
$script:ReviewReducerSchema = "exact-head-review-reducer/v1"
$script:SelectableModels = @(
  "gpt-5.6-luna",
  "gpt-5.6-terra",
  "gpt-5.6-sol",
  "claude-sonnet-5",
  "claude-opus-5",
  "claude-fable-5"
)
$script:TerminalReviewOutcomes = @("PASS", "BLOCK_FIXABLE", "BLOCK_REPLAN", "SKIP")
$script:BlockingReviewOutcomes = @("BLOCK_FIXABLE", "BLOCK_REPLAN")

function Get-ExactHeadReviewContract {
  [pscustomobject][ordered]@{
    receiptSchema = $script:ReviewReceiptSchema
    reducerSchema = $script:ReviewReducerSchema
    maxHistoryBytes = 33554432
    maxHistoryRows = 50000
  }
}

function Test-JsonProperty($Object, [string]$Name) {
  return $null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]
}

function Test-WholeNumber($Value, [int]$Minimum = 0) {
  if ($Value -isnot [byte] -and
      $Value -isnot [int16] -and
      $Value -isnot [int32] -and
      $Value -isnot [int64] -and
      $Value -isnot [uint16] -and
      $Value -isnot [uint32] -and
      $Value -isnot [uint64]) {
    return $false
  }
  try { return [int64]$Value -ge $Minimum } catch { return $false }
}

function ConvertTo-ReviewInstant([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
  $parsed = [datetimeoffset]::MinValue
  if (-not [datetimeoffset]::TryParse(
      $Value,
      [Globalization.CultureInfo]::InvariantCulture,
      [Globalization.DateTimeStyles]::RoundtripKind,
      [ref]$parsed
    )) {
    return $null
  }
  return $parsed.ToUniversalTime()
}

function Test-AttemptIdentity([string]$Value) {
  return -not [string]::IsNullOrWhiteSpace($Value) -and
    $Value -cmatch "^[A-Za-z0-9][A-Za-z0-9._:/-]{0,255}$"
}

function Get-ReviewReceiptValidation($Row) {
  $errors = [Collections.Generic.List[string]]::new()
  $required = @(
    "ts", "kind", "pr", "receiptSchema", "reviewedHead",
    "reviewerAttempt", "authorAttempt", "reviewContract", "completeSweep",
    "outcome", "model", "authorModel", "findingIds", "findings"
  )
  foreach ($field in $required) {
    if (-not (Test-JsonProperty $Row $field)) { $errors.Add("MISSING_$($field.ToUpperInvariant())") }
  }

  $instant = if (Test-JsonProperty $Row "ts") { ConvertTo-ReviewInstant ([string]$Row.ts) } else { $null }
  if ($null -eq $instant) { $errors.Add("INVALID_TS") }
  if ((Test-JsonProperty $Row "kind") -and [string]$Row.kind -cne "review-complete") {
    $errors.Add("INVALID_KIND")
  }
  if ((Test-JsonProperty $Row "receiptSchema") -and
      [string]$Row.receiptSchema -cne $script:ReviewReceiptSchema) {
    $errors.Add("UNSUPPORTED_RECEIPT_SCHEMA")
  }
  if ((Test-JsonProperty $Row "pr") -and
      (-not (Test-WholeNumber $Row.pr 1) -or [int64]$Row.pr -gt [int]::MaxValue)) {
    $errors.Add("INVALID_PR")
  }
  if ((Test-JsonProperty $Row "reviewedHead") -and
      [string]$Row.reviewedHead -cnotmatch "^[a-f0-9]{40}$") {
    $errors.Add("INVALID_REVIEWED_HEAD")
  }

  $reviewerAttempt = if (Test-JsonProperty $Row "reviewerAttempt") { [string]$Row.reviewerAttempt } else { "" }
  $authorAttempt = if (Test-JsonProperty $Row "authorAttempt") { [string]$Row.authorAttempt } else { "" }
  if (-not (Test-AttemptIdentity $reviewerAttempt)) { $errors.Add("INVALID_REVIEWER_ATTEMPT") }
  if (-not (Test-AttemptIdentity $authorAttempt)) { $errors.Add("INVALID_AUTHOR_ATTEMPT") }
  if ((Test-AttemptIdentity $reviewerAttempt) -and
      (Test-AttemptIdentity $authorAttempt) -and
      [string]::Equals($reviewerAttempt, $authorAttempt, [StringComparison]::OrdinalIgnoreCase)) {
    $errors.Add("ATTEMPT_IDENTITIES_NOT_INDEPENDENT")
  }

  if ((Test-JsonProperty $Row "reviewContract") -and
      [string]$Row.reviewContract -cne "review-contract/v2") {
    $errors.Add("INVALID_REVIEW_CONTRACT")
  }
  if ((Test-JsonProperty $Row "completeSweep") -and
      ($Row.completeSweep -isnot [bool] -or $Row.completeSweep -ne $true)) {
    $errors.Add("INCOMPLETE_SWEEP")
  }
  if ((Test-JsonProperty $Row "outcome") -and
      [string]$Row.outcome -cnotin $script:TerminalReviewOutcomes) {
    $errors.Add("INVALID_TERMINAL_DISPOSITION")
  }
  foreach ($modelField in @("model", "authorModel")) {
    if ((Test-JsonProperty $Row $modelField) -and
        [string]$Row.$modelField -cnotin $script:SelectableModels) {
      $errors.Add("INVALID_$($modelField.ToUpperInvariant())")
    }
  }

  $ids = @()
  if (Test-JsonProperty $Row "findingIds") {
    $findingIdsProperty = $Row.PSObject.Properties["findingIds"]
    if ([object]::ReferenceEquals($null, $findingIdsProperty.Value) -or
        $findingIdsProperty.Value -isnot [array]) {
      $errors.Add("INVALID_FINDING_IDS")
    } else {
      $ids = @($findingIdsProperty.Value)
      if (@($ids | Where-Object { [string]$_ -cnotmatch "^[A-Z][A-Z0-9._-]{0,63}$" }).Count -gt 0) {
        $errors.Add("INVALID_FINDING_ID")
      }
      if (@($ids | Sort-Object -Unique).Count -ne $ids.Count) {
        $errors.Add("DUPLICATE_FINDING_ID")
      }
    }
  }

  $blocking = $null
  if (Test-JsonProperty $Row "findings") {
    foreach ($countField in @("blocking", "candidates", "nonBlocking")) {
      if (-not (Test-JsonProperty $Row.findings $countField)) {
        $errors.Add("MISSING_FINDINGS_$($countField.ToUpperInvariant())")
      } elseif (-not (Test-WholeNumber $Row.findings.$countField 0)) {
        $errors.Add("INVALID_FINDINGS_$($countField.ToUpperInvariant())")
      }
    }
    if (Test-JsonProperty $Row.findings "blocking") { $blocking = [int64]$Row.findings.blocking }
  }
  if ($null -ne $blocking -and $ids.Count -ne $blocking) {
    $errors.Add("FINDING_COUNT_MISMATCH")
  }
  if ((Test-JsonProperty $Row "outcome") -and $null -ne $blocking) {
    if ([string]$Row.outcome -in $script:BlockingReviewOutcomes -and $blocking -lt 1) {
      $errors.Add("BLOCK_WITHOUT_FINDING")
    }
    if ([string]$Row.outcome -notin $script:BlockingReviewOutcomes -and $blocking -ne 0) {
      $errors.Add("NONBLOCK_WITH_BLOCKING_FINDING")
    }
  }

  [pscustomobject][ordered]@{
    valid = $errors.Count -eq 0
    errors = @($errors)
    instant = $instant
  }
}

function Read-ExactHeadReviewHistory(
  [string]$Path,
  [int]$MaxRows = 50000,
  [long]$MaxBytes = 33554432
) {
  $audit = [ordered]@{
    pathStatus = "unknown"
    bytes = 0
    rows = 0
    parsedRows = 0
    malformedRows = 0
    truncated = $false
    malformedLineNumbers = @()
  }
  $rows = [Collections.Generic.List[object]]::new()
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    $audit.pathStatus = "missing"
    return [pscustomobject][ordered]@{ complete = $false; rows = @(); audit = $audit; reason = "HISTORY_MISSING" }
  }
  try {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $audit.bytes = [int64]$item.Length
    if ($item.Length -gt $MaxBytes) {
      $audit.pathStatus = "oversize"
      $audit.truncated = $true
      return [pscustomobject][ordered]@{ complete = $false; rows = @(); audit = $audit; reason = "HISTORY_TRUNCATED" }
    }
    $lineNumber = 0
    foreach ($line in [IO.File]::ReadLines($item.FullName)) {
      $lineNumber += 1
      if ($lineNumber -gt $MaxRows) {
        $audit.truncated = $true
        break
      }
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      $audit.rows += 1
      try {
        $row = $line | ConvertFrom-Json -DateKind String -ErrorAction Stop
        $rows.Add([pscustomobject][ordered]@{ line = $lineNumber; value = $row })
        $audit.parsedRows += 1
      } catch {
        $audit.malformedRows += 1
        $audit.malformedLineNumbers += $lineNumber
      }
    }
    $audit.pathStatus = if ($audit.truncated) { "truncated" } elseif ($audit.malformedRows) { "malformed" } else { "ok" }
  } catch {
    $audit.pathStatus = "unreadable"
    return [pscustomobject][ordered]@{ complete = $false; rows = @(); audit = $audit; reason = "HISTORY_UNREADABLE" }
  }
  if ($audit.truncated) {
    return [pscustomobject][ordered]@{ complete = $false; rows = @($rows); audit = $audit; reason = "HISTORY_TRUNCATED" }
  }
  if ($audit.malformedRows -gt 0) {
    return [pscustomobject][ordered]@{ complete = $false; rows = @($rows); audit = $audit; reason = "HISTORY_MALFORMED" }
  }
  [pscustomobject][ordered]@{ complete = $true; rows = @($rows); audit = $audit; reason = "HISTORY_COMPLETE" }
}

function Get-ReceiptFingerprint($Row) {
  $canonical = [ordered]@{
    ts = [string]$Row.ts
    pr = [int64]$Row.pr
    receiptSchema = [string]$Row.receiptSchema
    reviewedHead = [string]$Row.reviewedHead
    reviewerAttempt = [string]$Row.reviewerAttempt
    authorAttempt = [string]$Row.authorAttempt
    reviewContract = [string]$Row.reviewContract
    completeSweep = [bool]$Row.completeSweep
    outcome = [string]$Row.outcome
    model = [string]$Row.model
    authorModel = [string]$Row.authorModel
    findingIds = @($Row.findingIds | ForEach-Object { [string]$_ })
    findings = [ordered]@{
      blocking = [int64]$Row.findings.blocking
      candidates = [int64]$Row.findings.candidates
      nonBlocking = [int64]$Row.findings.nonBlocking
    }
  }
  $bytes = [Text.Encoding]::UTF8.GetBytes(($canonical | ConvertTo-Json -Compress -Depth 5))
  [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function New-ReviewReduction(
  [string]$State,
  [string]$Reason,
  [int]$Pr,
  [string]$CurrentHead,
  $Latest,
  $Audit
) {
  [pscustomobject][ordered]@{
    schema = $script:ReviewReducerSchema
    state = $State
    reason = $Reason
    pr = $Pr
    currentHead = $CurrentHead
    latest = $Latest
    audit = $Audit
  }
}

function Reduce-ExactHeadReview(
  [int]$Pr,
  [string]$CurrentHead,
  $History
) {
  if ($Pr -lt 1) {
    return New-ReviewReduction "unknown" "INVALID_REQUEST_PR" $Pr $CurrentHead $null $History.audit
  }
  if ($CurrentHead -cnotmatch "^[a-f0-9]{40}$") {
    return New-ReviewReduction "unknown" "INVALID_CURRENT_HEAD" $Pr $CurrentHead $null $History.audit
  }
  if (-not $History.complete) {
    return New-ReviewReduction "unknown" $History.reason $Pr $CurrentHead $null $History.audit
  }

  $valid = [Collections.Generic.List[object]]::new()
  $uncertain = [Collections.Generic.List[object]]::new()
  $malformedExact = [Collections.Generic.List[object]]::new()
  $controllerReceipts = 0
  $legacyReceipts = 0
  foreach ($entry in @($History.rows)) {
    $row = $entry.value
    if (-not (Test-JsonProperty $row "kind") -or [string]$row.kind -cne "review-complete") { continue }
    if (Test-JsonProperty $row "controllerHead") {
      $controllerReceipts += 1
      continue
    }
    $rowPr = if ((Test-JsonProperty $row "pr") -and (Test-WholeNumber $row.pr 1)) { [int64]$row.pr } else { $null }
    $couldApply = $null -eq $rowPr -or $rowPr -eq $Pr
    if (-not $couldApply) { continue }

    $validation = Get-ReviewReceiptValidation $row
    if (-not $validation.valid) {
      $invalidEntry = [pscustomobject][ordered]@{
        line = $entry.line
        instant = $validation.instant
        errors = @($validation.errors)
      }
      $claimsExactHeadSchema =
        (Test-JsonProperty $row "receiptSchema") -or
        (Test-JsonProperty $row "reviewedHead") -or
        (Test-JsonProperty $row "reviewerAttempt") -or
        (Test-JsonProperty $row "authorAttempt")
      if ($claimsExactHeadSchema) {
        $malformedExact.Add($invalidEntry)
      } else {
        $legacyReceipts += 1
        $uncertain.Add($invalidEntry)
      }
      continue
    }
    $valid.Add([pscustomobject][ordered]@{
      line = $entry.line
      instant = $validation.instant
      row = $row
      fingerprint = Get-ReceiptFingerprint $row
    })
  }

  $audit = [ordered]@{}
  foreach ($property in $History.audit.GetEnumerator()) { $audit[$property.Key] = $property.Value }
  $audit.controllerReceiptsIgnored = $controllerReceipts
  $audit.legacyOrInvalidRelevantReceipts = $legacyReceipts
  $audit.malformedExactHeadReceipts = $malformedExact.Count
  $audit.validRelevantReceipts = $valid.Count
  $audit.duplicateReceipts = 0
  $audit.uncertainReceipts = @($uncertain | ForEach-Object {
      [ordered]@{ line = $_.line; errors = @($_.errors) }
    })
  $audit.malformedExactHeadReceiptDetails = @($malformedExact | ForEach-Object {
      [ordered]@{ line = $_.line; errors = @($_.errors) }
    })

  if ($malformedExact.Count -gt 0) {
    return New-ReviewReduction "unknown" "MALFORMED_EXACT_HEAD_RECEIPT" $Pr $CurrentHead $null $audit
  }

  $deduplicated = [Collections.Generic.List[object]]::new()
  foreach ($group in @($valid | Group-Object fingerprint)) {
    $deduplicated.Add($group.Group[0])
    $audit.duplicateReceipts += $group.Count - 1
  }

  foreach ($attemptGroup in @($deduplicated | Group-Object { $_.row.reviewerAttempt })) {
    if ($attemptGroup.Count -gt 1) {
      return New-ReviewReduction "unknown" "CONTRADICTORY_ATTEMPT_RECEIPTS" $Pr $CurrentHead $null $audit
    }
  }

  $latestValidInstant = @($deduplicated | Sort-Object instant -Descending | Select-Object -First 1).instant
  $unboundedUncertainty = @($uncertain | Where-Object {
      $null -eq $_.instant -or $null -eq $latestValidInstant -or $_.instant -ge $latestValidInstant
    })
  if ($unboundedUncertainty.Count -gt 0) {
    $audit.uncertainLines = @($unboundedUncertainty | ForEach-Object { $_.line })
    return New-ReviewReduction "unknown" "RELEVANT_RECEIPT_UNVERIFIABLE" $Pr $CurrentHead $null $audit
  }

  if ($deduplicated.Count -eq 0) {
    $reason = if ($legacyReceipts -gt 0) { "LEGACY_RECEIPTS_ONLY" } else { "NO_REVIEW_HISTORY" }
    return New-ReviewReduction "unknown" $reason $Pr $CurrentHead $null $audit
  }

  $exact = @($deduplicated | Where-Object { [string]$_.row.reviewedHead -ceq $CurrentHead })
  if ($exact.Count -eq 0) {
    return New-ReviewReduction "stale" "CURRENT_HEAD_HAS_NO_TERMINAL_REVIEW" $Pr $CurrentHead $null $audit
  }

  $latestInstant = ($exact | Sort-Object instant -Descending | Select-Object -First 1).instant
  $atLatestInstant = @($exact | Where-Object { $_.instant.Ticks -eq $latestInstant.Ticks })
  $latestOutcomes = @($atLatestInstant | ForEach-Object { [string]$_.row.outcome } | Sort-Object -Unique)
  if ($latestOutcomes.Count -gt 1) {
    return New-ReviewReduction "unknown" "TERMINAL_ORDER_AMBIGUOUS" $Pr $CurrentHead $null $audit
  }
  $latest = $atLatestInstant | Sort-Object fingerprint | Select-Object -First 1
  $latestSummary = [ordered]@{
    ts = [string]$latest.row.ts
    reviewedHead = [string]$latest.row.reviewedHead
    outcome = [string]$latest.row.outcome
    reviewerAttempt = [string]$latest.row.reviewerAttempt
    authorAttempt = [string]$latest.row.authorAttempt
    model = [string]$latest.row.model
    authorModel = [string]$latest.row.authorModel
  }
  switch ([string]$latest.row.outcome) {
    "PASS" { return New-ReviewReduction "authorized" "LATEST_EXACT_HEAD_PASS" $Pr $CurrentHead $latestSummary $audit }
    "BLOCK_FIXABLE" { return New-ReviewReduction "blocked" "LATEST_EXACT_HEAD_BLOCK_FIXABLE" $Pr $CurrentHead $latestSummary $audit }
    "BLOCK_REPLAN" { return New-ReviewReduction "blocked" "LATEST_EXACT_HEAD_BLOCK_REPLAN" $Pr $CurrentHead $latestSummary $audit }
    "SKIP" { return New-ReviewReduction "blocked" "LATEST_EXACT_HEAD_SKIP" $Pr $CurrentHead $latestSummary $audit }
    default { return New-ReviewReduction "unknown" "LATEST_TERMINAL_UNRECOGNIZED" $Pr $CurrentHead $latestSummary $audit }
  }
}

Export-ModuleMember -Function @(
  "Get-ExactHeadReviewContract",
  "Get-ReviewReceiptValidation",
  "Read-ExactHeadReviewHistory",
  "Reduce-ExactHeadReview",
  "Test-WholeNumber",
  "ConvertTo-ReviewInstant"
)
