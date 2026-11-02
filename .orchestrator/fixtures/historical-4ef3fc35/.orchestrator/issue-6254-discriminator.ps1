[CmdletBinding()]
param(
  # Container-meta worktree whose production controller surface is under test.
  [string]$ControllerRoot = (Split-Path -Parent $PSScriptRoot),

  [string]$EvidenceReceiptPath,

  [string]$ExpectedControllerHead,

  # Focused implementation-lane seam for the receipt-poison controls.
  [switch]$ReceiptPoisonOnly
)

$ErrorActionPreference = "Stop"
$controller = [IO.Path]::GetFullPath($ControllerRoot)
$runtime = Join-Path $controller ".orchestrator"
$required = @(
  "fail-closed-guard-evidence.ps1",
  "review-head-contract.psm1",
  "review-head-reducer.ps1",
  "landing-preflight.ps1",
  "review-queue-health.ps1",
  "log-event.ps1",
  "fixtures/legacy-non-pr-review-history.jsonl"
)
foreach ($name in $required) {
  $path = Join-Path $runtime $name
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "ISSUE-6254 NEGATIVE: production exact-head control missing at $path"
  }
}

function Assert-6254([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ISSUE-6254 NEGATIVE: $Message" }
}

function Invoke-ReceiptPoisonDiscriminator {
  $testRoot = Join-Path ([IO.Path]::GetTempPath()) ("issue-6254-receipt-poison-" + [guid]::NewGuid().ToString("N"))
  [IO.Directory]::CreateDirectory($testRoot) | Out-Null
  $headA = "a" * 40
  $headB = "b" * 40
  $targetPr = 6473

  function New-ReceiptRow([object]$Pr,[string]$Head,[string]$Label,[string]$Outcome="PASS") {
    $ids = if ($Outcome -in @("BLOCK_FIXABLE","BLOCK_REPLAN")) { [object[]]@("F_$($Label.ToUpperInvariant())") } else { [object[]]@() }
    [pscustomobject][ordered]@{
      ts = "2026-08-02T12:00:00.000Z"
      kind = "review-complete"
      pr = $Pr
      receiptSchema = "exact-head-review-receipt/v1"
      reviewedHead = $Head
      reviewerAttempt = "$Label-reviewer"
      authorAttempt = "$Label-author"
      reviewContract = "review-contract/v2"
      completeSweep = $true
      outcome = $Outcome
      model = "gpt-5.6-sol" # historical replay only
      authorModel = "gpt-5.6-sol" # historical replay only
      findingIds = [object[]]@($ids)
      findings = [ordered]@{ blocking = @($ids).Count; candidates = @($ids).Count; nonBlocking = 0 }
    }
  }

  function Write-ReceiptHistory([object[]]$Rows,[string]$Name) {
    $path = Join-Path $testRoot $Name
    [IO.File]::WriteAllLines(
      $path,
      @($Rows | ForEach-Object {
          if ($_ -is [string]) { $_ } else { $_ | ConvertTo-Json -Compress -Depth 8 }
        }),
      [Text.UTF8Encoding]::new($false)
    )
    $path
  }

  function Invoke-ReceiptReducer([string]$ReducerPath,[string]$History,[string]$Head=$headA) {
    & $ReducerPath -Pr $targetPr -CurrentHead $Head -HistoryPath $History |
      ConvertFrom-Json -DateKind String
  }

  try {
    $zeroOne = New-ReceiptRow 0 $headB "precursor-zero-one"
    $zeroTwo = New-ReceiptRow 0 $headA "precursor-zero-two"
    $targetPass = New-ReceiptRow $targetPr $headA "target-pass"
    $frozenHistory = Write-ReceiptHistory @($zeroOne,$zeroTwo,$targetPass) "frozen-live-shape.jsonl"
    $candidateReducer = Join-Path $runtime "review-head-reducer.ps1"
    $candidate = Invoke-ReceiptReducer $candidateReducer $frozenHistory
    Assert-6254 ($candidate.state -ceq "authorized" -and
      $candidate.reason -ceq "LATEST_EXACT_HEAD_PASS" -and
      $candidate.audit.validRelevantReceipts -eq 1 -and
      $candidate.audit.quarantinedNonPrReceipts -eq 2) `
      "candidate did not authorize solely from the valid target PASS over the exact two-pr:0 live shape (observed=$($candidate | ConvertTo-Json -Compress -Depth 10))"

    $legacyRows = [object[]]@(Get-Content -LiteralPath (Join-Path $runtime "fixtures/legacy-non-pr-review-history.jsonl"))
    Assert-6254 ($legacyRows.Count -eq 25) "genuine legacy non-PR fixture cardinality moved"
    $legacyHistory = Write-ReceiptHistory ([object[]](@($legacyRows) + @($targetPass))) "legacy-non-pr-history.jsonl"
    $legacyCandidate = Invoke-ReceiptReducer $candidateReducer $legacyHistory
    Assert-6254 ($legacyCandidate.state -ceq "authorized" -and
      $legacyCandidate.reason -ceq "LATEST_EXACT_HEAD_PASS" -and
      $legacyCandidate.audit.validRelevantReceipts -eq 1 -and
      $legacyCandidate.audit.quarantinedNonPrReceipts -eq 25) `
      "candidate did not isolate the complete genuine legacy non-PR/non-exact-head class"

    $legacyMutantRoot = Join-Path $testRoot "legacy-non-pr-global-poison"
    [IO.Directory]::CreateDirectory($legacyMutantRoot) | Out-Null
    Copy-Item -LiteralPath (Join-Path $runtime "review-head-reducer.ps1") -Destination $legacyMutantRoot
    $legacyContractSource = Get-Content -LiteralPath (Join-Path $runtime "review-head-contract.psm1") -Raw
    $legacyNeedle = 'if (Test-LegacyNonPrReviewIdentity $row) {'
    Assert-6254 (@([regex]::Matches($legacyContractSource,[regex]::Escape($legacyNeedle))).Count -eq 1) `
      "named legacy-domain bypass mutant did not match exactly one governing clause"
    $legacyMutantSource = $legacyContractSource.Replace($legacyNeedle,'if ($false -and (Test-LegacyNonPrReviewIdentity $row)) {')
    [IO.File]::WriteAllText(
      (Join-Path $legacyMutantRoot "review-head-contract.psm1"),
      $legacyMutantSource,
      [Text.UTF8Encoding]::new($false)
    )
    $legacyMutant = Invoke-ReceiptReducer (Join-Path $legacyMutantRoot "review-head-reducer.ps1") $legacyHistory
    Assert-6254 ($legacyMutant.state -ceq "unknown" -and
      $legacyMutant.reason -ceq "RELEVANT_RECEIPT_UNVERIFIABLE") `
      "named legacy-non-pr-global-poison bypass mutant survived the complete-class control"

    $otherMalformed = New-ReceiptRow 9002 $headA "other-pr-malformed"
    $otherMalformed.reviewerAttempt = $otherMalformed.authorAttempt
    $isolatedHistory = Write-ReceiptHistory @($otherMalformed,$targetPass) "other-pr-isolation.jsonl"
    $isolated = Invoke-ReceiptReducer $candidateReducer $isolatedHistory
    Assert-6254 ($isolated.state -ceq "authorized" -and $isolated.audit.quarantinedOtherPrReceipts -eq 1) `
      "candidate did not isolate malformed other-PR authority"

    $mutantRoot = Join-Path $testRoot "other-pr-global-poison"
    [IO.Directory]::CreateDirectory($mutantRoot) | Out-Null
    Copy-Item -LiteralPath (Join-Path $runtime "review-head-reducer.ps1") -Destination $mutantRoot
    $contractSource = Get-Content -LiteralPath (Join-Path $runtime "review-head-contract.psm1") -Raw
    $needle = 'if ($rowPr -ne $Pr) {'
    Assert-6254 (@([regex]::Matches($contractSource,[regex]::Escape($needle))).Count -eq 1) `
      "named bypass mutant did not match exactly one governing clause"
    $mutantSource = $contractSource.Replace($needle,'if ($false -and $rowPr -ne $Pr) {')
    [IO.File]::WriteAllText(
      (Join-Path $mutantRoot "review-head-contract.psm1"),
      $mutantSource,
      [Text.UTF8Encoding]::new($false)
    )
    $mutant = Invoke-ReceiptReducer (Join-Path $mutantRoot "review-head-reducer.ps1") $isolatedHistory
    Assert-6254 ($mutant.state -ceq "unknown" -and
      $mutant.reason -ceq "MALFORMED_EXACT_HEAD_RECEIPT") `
      "named other-pr-global-poison bypass mutant survived the isolation control"

    $absent = Invoke-ReceiptReducer $candidateReducer (Write-ReceiptHistory @($zeroOne,$zeroTwo) "absent-pass.jsonl")
    Assert-6254 ($absent.state -ceq "unknown" -and $absent.reason -ceq "NO_REVIEW_HISTORY") `
      "two quarantined pr:0 rows authorized without a positive target PASS"

    $stale = Invoke-ReceiptReducer $candidateReducer (Write-ReceiptHistory @(
        $zeroOne,$zeroTwo,(New-ReceiptRow $targetPr $headB "target-stale")
      ) "stale-pass.jsonl")
    Assert-6254 ($stale.state -ceq "stale" -and $stale.reason -ceq "CURRENT_HEAD_HAS_NO_TERMINAL_REVIEW") `
      "two quarantined pr:0 rows promoted stale target evidence"

    $ambiguous = New-ReceiptRow $targetPr $headA "ambiguous-missing-pr"
    $ambiguous.PSObject.Properties.Remove("pr")
    $ambiguousResult = Invoke-ReceiptReducer $candidateReducer (Write-ReceiptHistory @(
        $zeroOne,$zeroTwo,$targetPass,$ambiguous
      ) "ambiguous-pr.jsonl")
    Assert-6254 ($ambiguousResult.state -ceq "unknown" -and
      $ambiguousResult.reason -ceq "RELEVANT_RECEIPT_UNVERIFIABLE" -and
      $ambiguousResult.audit.quarantinedNonPrReceipts -eq 2) `
      "ambiguous missing PR identity did not fail closed while explicit pr:0 rows stayed quarantined"

    $rawMalformedPath = Join-Path $testRoot "raw-malformed.jsonl"
    [IO.File]::WriteAllLines(
      $rawMalformedPath,
      @('{"kind":"review-complete"', ($targetPass | ConvertTo-Json -Compress -Depth 8)),
      [Text.UTF8Encoding]::new($false)
    )
    $rawMalformedResult = Invoke-ReceiptReducer $candidateReducer $rawMalformedPath
    Assert-6254 ($rawMalformedResult.state -ceq "unknown" -and
      $rawMalformedResult.reason -ceq "HISTORY_MALFORMED") `
      "unparseable review history did not fail closed before target authorization"

    $matchingMalformed = New-ReceiptRow $targetPr $headA "matching-malformed"
    $matchingMalformed.reviewerAttempt = $matchingMalformed.authorAttempt
    $matchingMalformedResult = Invoke-ReceiptReducer $candidateReducer (Write-ReceiptHistory @(
        $zeroOne,$zeroTwo,$targetPass,$matchingMalformed
      ) "matching-malformed.jsonl")
    Assert-6254 ($matchingMalformedResult.state -ceq "unknown" -and
      $matchingMalformedResult.reason -ceq "MALFORMED_EXACT_HEAD_RECEIPT") `
      "malformed receipt for the requested positive PR did not remain blocking"

    Write-Output "PASS issue-6254 requested-PR receipt isolation: candidate=authorized named-mutants=legacy-non-pr-global-poison:red,other-pr-global-poison:red negatives=absent,stale,ambiguous,raw-malformed,matching-malformed"
  } finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd("\", "/")
    if ((Split-Path -Parent $resolved).TrimEnd("\", "/") -ne $temp -or
        (Split-Path -Leaf $resolved) -notlike "issue-6254-receipt-poison-*") {
      throw "refusing unsafe receipt-poison cleanup target: $resolved"
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Invoke-ReceiptPoisonDiscriminator
if ($ReceiptPoisonOnly) { return }

if ($ExpectedControllerHead -cnotmatch "^[a-f0-9]{40}$") {
  throw "ISSUE-6254 NEGATIVE: expected controller head is not lowercase 40-hex"
}
$liveHead = (& git -C $controller rev-parse HEAD 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $liveHead -cne $ExpectedControllerHead) {
  throw "ISSUE-6254 NEGATIVE: expected controller head $ExpectedControllerHead does not equal live head $liveHead"
}
$root = Join-Path ([IO.Path]::GetTempPath()) ("issue-6254-discriminator-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $root | Out-Null
$headA = "a" * 40
$headB = "b" * 40

try {
  $history = Join-Path $root "history.jsonl"
  $receipt = [ordered]@{
    ts = [datetimeoffset]::UtcNow.AddMinutes(-2).ToString("o")
    kind = "review-complete"
    pr = 6254
    receiptSchema = "exact-head-review-receipt/v1"
    reviewedHead = $headA
    reviewerAttempt = "review-6254-discriminator"
    authorAttempt = "author-6254-discriminator"
    reviewContract = "review-contract/v2"
    completeSweep = $true
    outcome = "PASS"
    model = "gpt-5.6-sol" # historical replay only
    authorModel = "gpt-5.6-sol" # historical replay only
    findingIds = [object[]]@()
    findings = [ordered]@{ blocking = 0; candidates = 0; nonBlocking = 0 }
  }
  [IO.File]::WriteAllText(
    $history,
    ($receipt | ConvertTo-Json -Compress -Depth 6) + [Environment]::NewLine,
    [Text.UTF8Encoding]::new($false)
  )

  $reducer = Join-Path $runtime "review-head-reducer.ps1"
  $current = & $reducer -Pr 6254 -CurrentHead $headA -HistoryPath $history |
    ConvertFrom-Json -DateKind String
  $moved = & $reducer -Pr 6254 -CurrentHead $headB -HistoryPath $history |
    ConvertFrom-Json -DateKind String
  Assert-6254 ($current.state -eq "authorized") "exact reviewed head was not authorized"
  Assert-6254 ($moved.state -eq "stale") "synchronized head inherited its parent's PASS"

  $logger = Join-Path $runtime "log-event.ps1"
  $loggerOutput = Join-Path $root "logger.jsonl"
  $sameAttemptRejected = $false
  try {
    & $logger -Log dispatch -Kind review-complete -Pr 6254 `
      -Model claude-opus-5-5 -AuthorModel gpt-6.1-sol -Outcome PASS `
      -ReviewContract review-contract/v2 -CompleteSweep -ReviewedHead $headA `
      -ReviewerAttempt same-attempt -AuthorAttempt same-attempt `
      -Blocking 0 -Candidates 0 -NonBlocking 0 -OutFile $loggerOutput | Out-Null
  } catch {
    $sameAttemptRejected = $_.Exception.Message -match "independent attempt identities"
  }
  Assert-6254 $sameAttemptRejected "different model names disguised one attempt identity"

  $preflight = Join-Path $runtime "landing-preflight.ps1"
  $fixture = Join-Path $runtime "landing-preflight.fixture.json"
  if (-not (Test-Path -LiteralPath $fixture -PathType Leaf)) {
    throw "ISSUE-6254 NEGATIVE: production preflight fixture missing"
  }
  $report = & $preflight -Pr 6254 -Action Report -HistoryPath $history `
    -AuthorityFixture $fixture -AuthorityScenario eligible -MutationDisabled |
    ConvertFrom-Json -DateKind String
  Assert-6254 ($report.status -eq "eligible" -and $report.mutationCount -eq 0) "report-only preflight was not non-mutating and eligible"

  $apply = & $preflight -Pr 6254 -Action Apply -HistoryPath $history `
    -AuthorityFixture $fixture -AuthorityScenario eligible |
    ConvertFrom-Json -DateKind String
  Assert-6254 ($apply.status -eq "enqueued" -and $apply.mutationCount -eq 1) "green apply fixture did not reach exactly one canonical mutation"

  Write-Output "PASS issue-6254 discriminator: fail-closed evidence validated, explicit independent attempts, exact-head authorization, synchronize invalidation, report-only zero mutation, and one guarded apply mutation"
} finally {
  $resolved = [IO.Path]::GetFullPath($root)
  $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd("\", "/")
  if ((Split-Path -Parent $resolved).TrimEnd("\", "/") -ne $temp -or
      (Split-Path -Leaf $resolved) -notlike "issue-6254-discriminator-*") {
    throw "refusing unsafe discriminator cleanup target: $resolved"
  }
  Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
}
