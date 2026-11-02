$ErrorActionPreference = "Stop"

$reducer = Join-Path $PSScriptRoot "review-head-reducer.ps1"
$legacyFixture = Join-Path $PSScriptRoot "fixtures/legacy-non-pr-review-history.jsonl"
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("review-head-reducer-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$headA = "a" * 40
$headB = "b" * 40
$baseInstant = [datetimeoffset]::UtcNow.AddHours(-2)

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function New-Receipt(
  [int]$Pr,
  [string]$Head,
  [string]$Outcome,
  [int]$Minute,
  [string]$ReviewerAttempt = "",
  [string]$AuthorAttempt = ""
) {
  if (-not $ReviewerAttempt) { $ReviewerAttempt = "review-$Pr-$Minute" }
  if (-not $AuthorAttempt) { $AuthorAttempt = "author-$Pr-1" }
  $ids = if ($Outcome -in @("BLOCK_FIXABLE", "BLOCK_REPLAN")) { @("F$Minute") } else { @() }
  [pscustomobject][ordered]@{
    ts = $baseInstant.AddMinutes($Minute).ToString("o")
    kind = "review-complete"
    pr = $Pr
    receiptSchema = "exact-head-review-receipt/v1"
    reviewedHead = $Head
    reviewerAttempt = $ReviewerAttempt
    authorAttempt = $AuthorAttempt
    reviewContract = "review-contract/v2"
    completeSweep = $true
    outcome = $Outcome
    model = "gpt-5.6-sol"
    authorModel = "gpt-5.6-sol"
    findingIds = [object[]]@($ids)
    findings = [ordered]@{
      blocking = $ids.Count
      candidates = $ids.Count
      nonBlocking = 0
    }
  }
}

function Invoke-Reduction(
  [object[]]$Rows,
  [int]$Pr = 6254,
  [string]$Head = $headA,
  [int]$MaxRows = 50000
) {
  $path = Join-Path $testRoot ("history-" + [guid]::NewGuid().ToString("N") + ".jsonl")
  $lines = @($Rows | ForEach-Object {
      if ($_ -is [string]) { $_ } else { $_ | ConvertTo-Json -Compress -Depth 6 }
    })
  [IO.File]::WriteAllLines($path, $lines, [Text.UTF8Encoding]::new($false))
  & $reducer -Pr $Pr -CurrentHead $Head -HistoryPath $path -MaxHistoryRows $MaxRows |
    ConvertFrom-Json -DateKind String
}

try {
  $headAPass = New-Receipt 6254 $headA PASS 1
  $legacyLines = [object[]]@(Get-Content -LiteralPath $legacyFixture)
  $expectedLegacyLineHashes = [string[]]@(
    "557af53b0575ff0a0a60e60ee81b5b3be12509d63fbddf41413634b1cea7106f",
    "e98408a0ff23ae04454515ba6e260738b06b0b781d928fdd1ce129c61d455515",
    "1e619675cc0a5fdb0a930d40ca7e8986d4e591fa538eb5620878ec1329bc6bcc",
    "bbb565ca78897e1994848ed21ab012b92822281ed290b166f98e4fd021669633",
    "7e8f41193236da97da6752bbc22dddb5d934cee5649e2edc41950b186064a1c8",
    "ae01a707640ea0da2fad9e8a7d9e8e5a814699e196a0b4095dbfc7f1ac7445b8",
    "92c43d966ba3edc3f85540b4df5442bf11206971293693910b42ed38a42f8805",
    "e9e435882173148eafd5c58aff4c4899dc76e604836638e3c5b4d9c34cdbce5f",
    "4ef9cc99f9debcfe317830d1d4e1a780cdb4884f02c4bc654f133366fa9f5095",
    "6ddbb16abaa5d1a285c80f619233b8359f672d99263f93a749203707d3834d13",
    "b7dbc52f0f81e788cbac22d2454180a50a19715bde89394fac3367d2b8cea71d",
    "2dca7f151b498517b42af5b3dfe1662accca6c33b076481b4747722fbc622fc8",
    "c9b7a33c2b460fb6ff4e63479f9b62c68968935ad9d9b9081e26f84050a19d1c",
    "378492b5427be836bf6c5cd87f2b2e83e48d1ea0d5c7477cd82f8d78333b8502",
    "61aa6b712df49ad743c995d2480200badd4b4ef79e128d64c499dac02c8877da",
    "908f62550ac338e5115022d625ff55dd475f9110e3fbc789102089c564ad4c20",
    "52adfdacfd11d62a809e50b49b6c9b38b4869a07a1d712b5f202b780b531c912",
    "a3b75dbd393dd9b67613462fbed938d70cb5e842123065ca36de6b33e993279d",
    "3cdad63c993f64538bbad557dfb03a97b0f81f19f6e55d414fa5ae7da2843774",
    "9855686187dc5c809793e375cc653bfa76effb955fabb3da7b68ae95e21e2b4f",
    "734307a7fe5feefd2c2da22ffe1c0e9b82f609bdb5c5ffd807886c214dcec5de",
    "c502e5e38d42a1e7198f1576e57174e146cabe813e8eb114fc3e298dbc1ef1fe",
    "edcbf6f5743cce47f46fe3fe643d85b15d9c6fb0dbeb35d65b82eb5bc646c0dd",
    "f58804221c764f30c4197a6e050f6143f93def8537a5b90f2a6514a50e3188fe",
    "b32153e1d101e4a648c4c1bde4578440bbd380086fd42a043a85b0f2f27af49d"
  )
  $actualLegacyLineHashes = [string[]]@($legacyLines | ForEach-Object {
      ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
          [Text.UTF8Encoding]::new($false).GetBytes([string]$_)
        ))).ToLowerInvariant()
    })
  Assert-True ($legacyLines.Count -eq 25 -and
    [Linq.Enumerable]::SequenceEqual([string[]]$expectedLegacyLineHashes, [string[]]$actualLegacyLineHashes)) `
    "the genuine legacy review fixture must preserve all 25 canonical rows byte-for-byte"
  $legacyValues = [object[]]@($legacyLines | ForEach-Object { $_ | ConvertFrom-Json -DateKind String })
  foreach ($legacyValue in $legacyValues) {
    Assert-True ($legacyValue.kind -ceq "review-complete" -and
      -not $legacyValue.PSObject.Properties["pr"] -and
      -not $legacyValue.PSObject.Properties["receiptSchema"] -and
      -not $legacyValue.PSObject.Properties["reviewedHead"] -and
      -not $legacyValue.PSObject.Properties["reviewerAttempt"] -and
      -not $legacyValue.PSObject.Properties["authorAttempt"]) `
      "the genuine fixture contains a row outside the legacy non-PR/non-exact-head domain"
  }
  $legacyClass = Invoke-Reduction ([object[]](@($legacyLines) + @($headAPass)))
  Assert-True ($legacyClass.state -ceq "authorized" -and
    $legacyClass.reason -ceq "LATEST_EXACT_HEAD_PASS" -and
    $legacyClass.audit.validRelevantReceipts -eq 1 -and
    $legacyClass.audit.quarantinedNonPrReceipts -eq 25 -and
    @($legacyClass.audit.quarantinedNonPrReceiptDetails).Count -eq 25 -and
    @($legacyClass.audit.quarantinedNonPrReceiptDetails | Where-Object {
        $_.reason -cne "LEGACY_NON_PR_NON_EXACT_HEAD_REVIEW" -or $null -ne $_.pr
      }).Count -eq 0) `
    "all 25 genuine legacy records must be honestly quarantined while the modern target PASS authorizes"
  $legacyOnly = Invoke-Reduction $legacyLines
  Assert-True ($legacyOnly.state -ceq "unknown" -and
    $legacyOnly.reason -ceq "NO_REVIEW_HISTORY" -and
    $legacyOnly.audit.quarantinedNonPrReceipts -eq 25) `
    "legacy non-PR records alone must never become PR authority"

  $syntheticLegacyBoundary = [pscustomobject][ordered]@{
    ts = "2026-01-01T00:00:00Z"; kind = "review-complete"; issue = 900000001
    lane = "synthetic-legacy-boundary"; outcome = "PASS"
    note = "SYNTHETIC legacy-domain boundary control"
    findings = [ordered]@{ blocking = 0; candidates = 0; nonBlocking = 0 }
  }
  $claimedExactFields = [ordered]@{
    receiptSchema = "exact-head-review-receipt/v1"
    reviewedHead = $headA
    reviewerAttempt = "synthetic-legacy-boundary-reviewer"
    authorAttempt = "synthetic-legacy-boundary-author"
    reviewAuthority = "governing"
  }
  foreach ($claim in $claimedExactFields.GetEnumerator()) {
    $claimed = $syntheticLegacyBoundary.PSObject.Copy()
    $claimed | Add-Member -NotePropertyName $claim.Key -NotePropertyValue $claim.Value
    $claimedResult = Invoke-Reduction @($claimed, $headAPass)
    Assert-True ($claimedResult.state -ceq "unknown" -and
      $claimedResult.reason -ceq "RELEVANT_RECEIPT_UNVERIFIABLE") `
      "a missing-PR row claiming $($claim.Key) escaped modern fail-closed uncertainty"
  }
  foreach ($invalidIssue in @($null, "synthetic-issue")) {
    $unprovenLegacy = $syntheticLegacyBoundary.PSObject.Copy()
    if ($null -eq $invalidIssue) {
      $unprovenLegacy.PSObject.Properties.Remove("issue")
    } else {
      $unprovenLegacy.issue = $invalidIssue
    }
    $unprovenLegacyResult = Invoke-Reduction @($unprovenLegacy, $headAPass)
    Assert-True ($unprovenLegacyResult.state -ceq "unknown" -and
      $unprovenLegacyResult.reason -ceq "RELEVANT_RECEIPT_UNVERIFIABLE") `
      "a missing-PR row without a positive supported issue identity was misclassified as legacy non-PR"
  }
  $ordinaryBaseline = "8d1affe3d308443155eb3d81eaa619c345e1124e"
  $baselineRuntime = Join-Path $testRoot "ordinary-baseline"
  [IO.Directory]::CreateDirectory($baselineRuntime) | Out-Null
  $controllerRoot = Split-Path -Parent $PSScriptRoot
  foreach($relative in @(".orchestrator/review-head-contract.psm1",".orchestrator/review-head-reducer.ps1")){
    $sourceLines=@(& git -C $controllerRoot show "${ordinaryBaseline}:$relative")
    Assert-True ($LASTEXITCODE-eq0-and$sourceLines.Count-gt0) "ordinary reducer baseline source must be readable at $ordinaryBaseline"
    [IO.File]::WriteAllText((Join-Path $baselineRuntime (Split-Path -Leaf $relative)),($sourceLines-join"`n")+"`n",[Text.UTF8Encoding]::new($false))
  }
  $ordinaryHistory=Join-Path $testRoot "ordinary-byte-stable.jsonl"
  [IO.File]::WriteAllText($ordinaryHistory,($headAPass|ConvertTo-Json -Compress -Depth 6)+"`n",[Text.UTF8Encoding]::new($false))
  $ordinaryArgs=@('-NoProfile','-NonInteractive','-File',$reducer,'-Pr','6254','-CurrentHead',$headA,'-HistoryPath',$ordinaryHistory)
  $currentOrdinary=(& pwsh @ordinaryArgs 2>&1|Out-String);Assert-True ($LASTEXITCODE-eq0) "candidate ordinary reducer must execute"
  $ordinaryArgs[3]=Join-Path $baselineRuntime 'review-head-reducer.ps1'
  $baselineOrdinary=(& pwsh @ordinaryArgs 2>&1|Out-String);Assert-True ($LASTEXITCODE-eq0) "baseline ordinary reducer must execute"
  $currentOrdinaryValue=$currentOrdinary|ConvertFrom-Json -DateKind String
  $baselineOrdinaryValue=$baselineOrdinary|ConvertFrom-Json -DateKind String
  Assert-True ($currentOrdinaryValue.state-ceq$baselineOrdinaryValue.state-and
    $currentOrdinaryValue.reason-ceq$baselineOrdinaryValue.reason-and
    $currentOrdinaryValue.latest.reviewedHead-ceq$baselineOrdinaryValue.latest.reviewedHead) `
    "requested PR exact-head authority changed while adding quarantine audit fields"

  $authorized = Invoke-Reduction @($headAPass)
  Assert-True ($authorized.state -eq "authorized" -and
    $authorized.reason -eq "LATEST_EXACT_HEAD_PASS") "an exact-head PASS authorizes (observed=$($authorized | ConvertTo-Json -Compress -Depth 8))"

  # Canonical dispatch-log line 16343: planning reviewedHead is source
  # provenance, not ordinary PR exact-head authority.
  $livePlanningLine16343 = '{"ts":"2026-09-09T10:49:03.2980812+00:00","kind":"review-complete","issue":7735,"lane":"20260909-7735-glossary-conformance-review-r1","laneRole":"planning","harness":"codex","model":"gpt-5.6-sol","authorModel":"claude-opus-5","effort":"high","authorEffort":"high","row":"8","placement":"measured","transcript":"7735-sol-high-glossary-conformance-planning-review-r1.jsonl","outcome":"BLOCK_REPLAN","planningContract":"planning-repair/v1","planningRound":1,"completeSweep":true,"reviewedHead":"6feb1454cecb4a73a90845103a9a0de2a336eaad","reviewerAttempt":"7735-sol-high-glossary-conformance-planning-review-r1","authorAttempt":"7735-opus5-high-glossary-conformance-plan-r1","findingIds":["F1","F2","F3","F4","F5"],"nonBlockingIds":["N1"],"repairOwner":"author","disposition":"REPLACED","note":"Qualified terminal planning review receipt."}'
  $planningExcluded = Invoke-Reduction @($livePlanningLine16343, $headAPass)
  Assert-True ($planningExcluded.state -eq "authorized" -and
    $planningExcluded.reason -eq "LATEST_EXACT_HEAD_PASS" -and
    $planningExcluded.audit.planningReceiptsIgnored -eq 1 -and
    $planningExcluded.audit.planningReceiptDetails[0].line -eq 1 -and
    $planningExcluded.audit.planningReceiptDetails[0].issue -eq 7735 -and
    $planningExcluded.audit.planningReceiptDetails[0].reviewedHead -ceq "6feb1454cecb4a73a90845103a9a0de2a336eaad" -and
    $planningExcluded.audit.malformedExactHeadReceipts -eq 0) `
    "the exact live line-16343 planning shape is audited outside PR authority while the target PASS reduces normally"

  $planningClaimsPr = $livePlanningLine16343 | ConvertFrom-Json -DateKind String
  $planningClaimsPr | Add-Member -NotePropertyName pr -NotePropertyValue 6254
  $planningPrPoison = Invoke-Reduction @($planningClaimsPr, $headAPass)
  Assert-True ($planningPrPoison.state -eq "unknown" -and
    $planningPrPoison.reason -eq "MALFORMED_EXACT_HEAD_RECEIPT") `
    "a planning-labeled row that claims the requested PR remains an ordinary malformed-receipt poison"

  $planningClaimsReviewContract = $livePlanningLine16343 | ConvertFrom-Json -DateKind String
  $planningClaimsReviewContract | Add-Member -NotePropertyName reviewContract -NotePropertyValue "review-contract/v2"
  $planningReviewContractPoison = Invoke-Reduction @($planningClaimsReviewContract, $headAPass)
  Assert-True ($planningReviewContractPoison.state -eq "unknown" -and
    $planningReviewContractPoison.reason -eq "MALFORMED_EXACT_HEAD_RECEIPT") `
    "a planning-labeled row that claims the PR review contract cannot escape ordinary fail-closed validation"

  $incompletePlanningIdentity = $livePlanningLine16343 | ConvertFrom-Json -DateKind String
  $incompletePlanningIdentity.PSObject.Properties.Remove("planningContract")
  $incompletePlanningPoison = Invoke-Reduction @($incompletePlanningIdentity, $headAPass)
  Assert-True ($incompletePlanningPoison.state -eq "unknown" -and
    $incompletePlanningPoison.reason -eq "MALFORMED_EXACT_HEAD_RECEIPT") `
    "laneRole planning alone is not enough to bypass ordinary fail-closed validation"

  $precursorZeroOne = New-Receipt 0 $headB PASS -2 "precursor-review-zero-one" "precursor-author-zero-one"
  $precursorZeroTwo = New-Receipt 0 $headA PASS -1 "precursor-review-zero-two" "precursor-author-zero-two"
  $livePoisonShape = Invoke-Reduction @($precursorZeroOne, $precursorZeroTwo, $headAPass)
  Assert-True ($livePoisonShape.state -eq "authorized" -and
    $livePoisonShape.reason -eq "LATEST_EXACT_HEAD_PASS" -and
    $livePoisonShape.audit.validRelevantReceipts -eq 1 -and
    $livePoisonShape.audit.quarantinedNonPrReceipts -eq 2 -and
    @($livePoisonShape.audit.quarantinedNonPrReceiptDetails).Count -eq 2 -and
    $livePoisonShape.audit.quarantinedNonPrReceiptDetailsTruncated -eq $false) `
    "two explicit pr:0 precursor rows are quarantined while only the target's valid PASS authorizes"

  $poisonWithoutPass = Invoke-Reduction @($precursorZeroOne, $precursorZeroTwo)
  Assert-True ($poisonWithoutPass.state -eq "unknown" -and
    $poisonWithoutPass.reason -eq "NO_REVIEW_HISTORY" -and
    $null -eq $poisonWithoutPass.latest -and
    $poisonWithoutPass.audit.quarantinedNonPrReceipts -eq 2) `
    "quarantined pr:0 rows never become authorization when the target PASS is absent"

  $poisonWithStalePass = Invoke-Reduction @(
    $precursorZeroOne,
    $precursorZeroTwo,
    (New-Receipt 6254 $headB PASS 1)
  )
  Assert-True ($poisonWithStalePass.state -eq "stale" -and
    $poisonWithStalePass.reason -eq "CURRENT_HEAD_HAS_NO_TERMINAL_REVIEW") `
    "quarantined pr:0 rows cannot promote a stale target PASS"

  $ambiguousPrReceipt = New-Receipt 6254 $headA PASS 0 "ambiguous-pr-review" "ambiguous-pr-author"
  $ambiguousPrReceipt.PSObject.Properties.Remove("pr")
  $ambiguousPr = Invoke-Reduction @($ambiguousPrReceipt, $headAPass)
  Assert-True ($ambiguousPr.state -eq "unknown" -and
    $ambiguousPr.reason -eq "RELEVANT_RECEIPT_UNVERIFIABLE" -and
    $ambiguousPr.audit.uncertainReceipts[0].errors -contains "AMBIGUOUS_PR_IDENTITY") `
    "an absent PR identity fails closed because it may belong to the requested PR"

  $nonnumericPrReceipt = New-Receipt 6254 $headA PASS 0 "nonnumeric-pr-review" "nonnumeric-pr-author"
  $nonnumericPrReceipt.pr = "zero"
  $nonnumericPr = Invoke-Reduction @($nonnumericPrReceipt, $headAPass)
  Assert-True ($nonnumericPr.state -eq "unknown" -and $nonnumericPr.reason -eq "RELEVANT_RECEIPT_UNVERIFIABLE") `
    "a nonnumeric PR identity fails closed because it may belong to the requested PR"

  $fractionalPrReceipt = New-Receipt 6254 $headA PASS 0 "fractional-pr-review" "fractional-pr-author"
  $fractionalPrReceipt.pr = [decimal]0.5
  $fractionalPr = Invoke-Reduction @($fractionalPrReceipt, $headAPass)
  Assert-True ($fractionalPr.state -eq "unknown" -and $fractionalPr.reason -eq "RELEVANT_RECEIPT_UNVERIFIABLE") `
    "a fractional PR identity fails closed because it may belong to the requested PR"

  $overflowPrReceipt = New-Receipt 6254 $headA PASS 0 "overflow-pr-review" "overflow-pr-author"
  $overflowPrReceipt.pr = [int64][int]::MaxValue + 1
  $overflowPr = Invoke-Reduction @($overflowPrReceipt, $headAPass)
  Assert-True ($overflowPr.state -eq "unknown" -and $overflowPr.reason -eq "RELEVANT_RECEIPT_UNVERIFIABLE") `
    "an overflowed PR identity fails closed because it may belong to the requested PR"

  $otherPrMalformed = New-Receipt 9002 $headA PASS 0 "other-review" "other-author"
  $otherPrMalformed.reviewerAttempt = $otherPrMalformed.authorAttempt
  $otherPrIsolation = Invoke-Reduction @($otherPrMalformed, $headAPass)
  Assert-True ($otherPrIsolation.state -ceq "authorized" -and
    $otherPrIsolation.audit.quarantinedOtherPrReceipts -eq 1 -and
    $otherPrIsolation.audit.validRelevantReceipts -eq 1) `
    "a malformed other-PR receipt is quarantined and cannot poison the requested PR"

  $rawMalformedIsolation = Invoke-Reduction @('{"kind":"review-complete"', $headAPass)
  Assert-True ($rawMalformedIsolation.state -ceq "unknown" -and
    $rawMalformedIsolation.reason -ceq "HISTORY_MALFORMED" -and
    $rawMalformedIsolation.audit.malformedRows -eq 1) `
    "an unattributed malformed row fails closed because its PR domain is unknowable"

  $unknownOnly = Invoke-Reduction @($ambiguousPrReceipt)
  Assert-True ($unknownOnly.state -ceq "unknown" -and $unknownOnly.reason -ceq "RELEVANT_RECEIPT_UNVERIFIABLE") `
    "unknown receipt identity alone never becomes requested-PR PASS authority"

  $boundedQuarantineRows = [Collections.Generic.List[object]]::new()
  foreach ($index in 1..65) {
    $boundedQuarantineRows.Add((New-Receipt 0 $headA PASS (-100 - $index) "quarantine-review-$index" "quarantine-author-$index"))
  }
  $boundedQuarantine = Invoke-Reduction @($boundedQuarantineRows)
  Assert-True ($boundedQuarantine.audit.quarantinedNonPrReceipts -eq 65 -and
    @($boundedQuarantine.audit.quarantinedNonPrReceiptDetails).Count -eq 64 -and
    $boundedQuarantine.audit.quarantinedNonPrReceiptDetailsTruncated -eq $true) `
    "non-PR quarantine telemetry preserves its total while bounding row details"

  $synchronized = Invoke-Reduction @($headAPass) -Head $headB
  Assert-True ($synchronized.state -eq "stale" -and
    $synchronized.reason -eq "CURRENT_HEAD_HAS_NO_TERMINAL_REVIEW") "head A never authorizes synchronized head B"
  $freshB = Invoke-Reduction @($headAPass, (New-Receipt 6254 $headB PASS 2)) -Head $headB
  Assert-True ($freshB.state -eq "authorized") "a fresh exact-head PASS authorizes head B"

  $passBlock = Invoke-Reduction @(
    (New-Receipt 6254 $headA PASS 1),
    (New-Receipt 6254 $headA BLOCK_FIXABLE 2)
  )
  Assert-True ($passBlock.state -eq "blocked" -and
    $passBlock.reason -eq "LATEST_EXACT_HEAD_BLOCK_FIXABLE") "PASS then BLOCK is blocked"

  $repairPass = Invoke-Reduction @(
    (New-Receipt 6254 $headA BLOCK_FIXABLE 1),
    (New-Receipt 6254 $headA PASS 3)
  )
  Assert-True ($repairPass.state -eq "authorized") "BLOCK then repair then fresh PASS authorizes"

  $duplicate = New-Receipt 6254 $headA PASS 4
  $reordered = Invoke-Reduction @(
    $duplicate,
    (New-Receipt 6254 $headA BLOCK_FIXABLE 2),
    $duplicate,
    (New-Receipt 6254 $headB PASS 3)
  )
  Assert-True ($reordered.state -eq "authorized" -and
    $reordered.audit.duplicateReceipts -eq 1) "duplicate and reordered rows reduce deterministically"

  $contradictoryAttempt = Invoke-Reduction @(
    (New-Receipt 6254 $headA PASS 1 "review-attempt-one" "author-one"),
    (New-Receipt 6254 $headA BLOCK_FIXABLE 2 "review-attempt-one" "author-one")
  )
  Assert-True ($contradictoryAttempt.state -eq "unknown" -and
    $contradictoryAttempt.reason -eq "CONTRADICTORY_ATTEMPT_RECEIPTS") "one attempt cannot emit contradictory terminal receipts"

  $sameInstantPass = New-Receipt 6254 $headA PASS 5 "review-same-time-a" "author-a"
  $sameInstantBlock = New-Receipt 6254 $headA BLOCK_FIXABLE 5 "review-same-time-b" "author-a"
  $ambiguous = Invoke-Reduction @($sameInstantBlock, $sameInstantPass)
  Assert-True ($ambiguous.state -eq "unknown" -and
    $ambiguous.reason -eq "TERMINAL_ORDER_AMBIGUOUS") "same-time contradictory terminals fail closed"

  $malformed = Invoke-Reduction @(
    (New-Receipt 6254 $headA PASS 1),
    '{"kind":"review-complete"'
  )
  Assert-True ($malformed.state -eq "unknown" -and
    $malformed.reason -eq "HISTORY_MALFORMED") "unattributed malformed history fails closed"

  $malformedExactReceipt = New-Receipt 6254 $headA PASS 0
  $malformedExactReceipt.reviewerAttempt = $malformedExactReceipt.authorAttempt
  $malformedExactBeforeFresh = Invoke-Reduction @(
    $malformedExactReceipt,
    (New-Receipt 6254 $headA PASS 2)
  )
  Assert-True ($malformedExactBeforeFresh.state -eq "unknown" -and
    $malformedExactBeforeFresh.reason -eq "MALFORMED_EXACT_HEAD_RECEIPT") `
    "a malformed versioned receipt fails closed even when it predates a valid PASS"

  $otherPrMalformed = New-Receipt 6255 $headA PASS 0 "other-pr-review" "other-pr-author"
  $otherPrMalformed.reviewerAttempt = $otherPrMalformed.authorAttempt
  $otherPositiveIrrelevant = Invoke-Reduction @($otherPrMalformed, $headAPass)
  Assert-True ($otherPositiveIrrelevant.state -eq "authorized") `
    "an explicitly different positive PR remains irrelevant even when its own row is malformed"

  $truncated = Invoke-Reduction @(
    (New-Receipt 6254 $headA PASS 1),
    (New-Receipt 6254 $headA PASS 2)
  ) -MaxRows 1
  Assert-True ($truncated.state -eq "unknown" -and
    $truncated.reason -eq "HISTORY_TRUNCATED") "bounded scan truncation fails closed"

  $parentOnly = Invoke-Reduction @((New-Receipt 6254 $headA PASS 1)) -Head $headB
  Assert-True ($parentOnly.state -eq "stale") "a parent-only PASS is stale for the child head"

  $controllerReceipt = [pscustomobject][ordered]@{
    ts = $baseInstant.AddMinutes(10).ToString("o")
    kind = "review-complete"
    pr = 6254
    outcome = "PASS"
    reviewContract = "review-contract/v2"
    completeSweep = $true
    controllerHead = $headA
  }
  $controllerOnly = Invoke-Reduction @($controllerReceipt)
  Assert-True ($controllerOnly.state -eq "unknown" -and
    $controllerOnly.reason -eq "NO_REVIEW_HISTORY" -and
    $controllerOnly.audit.controllerReceiptsIgnored -eq 1) "controllerHead receipt remains compatible but cannot authorize an ordinary PR"

  $legacyBeforeFresh = [pscustomobject][ordered]@{
    ts = $baseInstant.ToString("o")
    kind = "review-complete"
    pr = 6254
    outcome = "PASS"
    reviewContract = "review-contract/v2"
    completeSweep = $true
  }
  $mixedCoverage = Invoke-Reduction @($legacyBeforeFresh, (New-Receipt 6254 $headA PASS 2))
  Assert-True ($mixedCoverage.state -eq "authorized" -and
    $mixedCoverage.audit.legacyOrInvalidRelevantReceipts -eq 1) "older legacy history stays visible without retroactively becoming authority"

  $legacyAfterFresh = $legacyBeforeFresh.PSObject.Copy()
  $legacyAfterFresh.ts = $baseInstant.AddMinutes(3).ToString("o")
  $mixedUncertain = Invoke-Reduction @((New-Receipt 6254 $headA PASS 2), $legacyAfterFresh)
  Assert-True ($mixedUncertain.state -eq "unknown" -and
    $mixedUncertain.reason -eq "RELEVANT_RECEIPT_UNVERIFIABLE") "later legacy terminal evidence fails closed"

  Import-Module (Join-Path $PSScriptRoot "review-head-contract.psm1") -Force -DisableNameChecking
  function New-StrictControllerRow([string]$Kind,[string]$Authority,[string]$Outcome="",[string]$Head=$headA,[int]$Issue=6335,[string]$Author="controller-author",[string]$Reviewer="controller-reviewer",[string]$Version="v1") {
    $row=[ordered]@{
      ts=$baseInstant.AddMinutes($(if($Kind-eq"dispatch"){10}else{11})).ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
      kind=$Kind
      controllerReviewSchema=$(if($Version-eq"v2"){if($Kind-eq"dispatch"){"controller-review-dispatch/v2"}else{"controller-review-receipt/v2"}}else{if($Kind-eq"dispatch"){"controller-review-dispatch/v1"}else{"controller-review-receipt/v1"}})
      issue=$Issue;controllerHead=$Head;authorAttempt=$Author;reviewerAttempt=$Reviewer;reviewAuthority=$Authority
      lane="controller-review-lane";transcript="controller-review.jsonl";reviewerModel="gpt-5.6-sol";authorModel="gpt-5.6-sol";effort="high";row="7";placement="measured";harness="codex"
    }
    if($Version-eq"v2"){$row.stage="review"}
    if($Kind-eq"review-complete"){
      $ids=if($Outcome-in@("BLOCK_FIXABLE","BLOCK_REPLAN")){@("F1")}else{@()}
      $row.reviewContract="review-contract/v2";$row.completeSweep=$true;$row.outcome=$Outcome;$row.findingIds=[object[]]@($ids);$row.findings=[ordered]@{blocking=@($ids).Count;candidates=@($ids).Count;nonBlocking=0}
    }
    [pscustomobject]$row
  }
  function Invoke-ControllerReduction([object[]]$Rows,[string]$Mode="strict-v1",[int]$Issue=6335,[string]$Head=$headA){
    $path=Join-Path $testRoot ("controller-"+[guid]::NewGuid().ToString("N")+".jsonl")
    [IO.File]::WriteAllLines($path,@($Rows|ForEach-Object{if($_-is[string]){$_}else{$_|ConvertTo-Json -Compress -Depth 10}}),[Text.UTF8Encoding]::new($false))
    $history=Read-ExactHeadReviewHistory -Path $path
    Reduce-ControllerReleaseReview -Issue $Issue -ControllerHead $Head -Mode $Mode -History $history
  }

  $governingPass=New-StrictControllerRow dispatch governing
  $governingReceipt=New-StrictControllerRow review-complete governing PASS
  $shadowDispatch=New-StrictControllerRow dispatch shadow "" $headA 6335 shadow-author shadow-reviewer
  $shadowBlock=New-StrictControllerRow review-complete shadow BLOCK_REPLAN $headA 6335 shadow-author shadow-reviewer
  $strictAuthorized=Invoke-ControllerReduction @($governingPass,$shadowDispatch,$shadowBlock,$governingReceipt)
  Assert-True ($strictAuthorized.state-eq"authorized"-and$strictAuthorized.census.governing.pass-eq1-and$strictAuthorized.census.shadow.blockReplan-eq1) `
    "governing PASS authorizes while shadow BLOCK remains separately conserved (observed=$($strictAuthorized|ConvertTo-Json -Compress -Depth 20))"

  $ordinaryRepair=[pscustomobject][ordered]@{ts=$baseInstant.AddMinutes(10).AddSeconds(10).ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'");kind="repair-complete";issue=6335;controllerHead=$headA}
  $ordinaryVerify=[pscustomobject][ordered]@{ts=$baseInstant.AddMinutes(12).ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'");kind="verify-complete";issue=6335;controllerHead=$headA}
  $strictWithOrdinaryLifecycle=Invoke-ControllerReduction @($governingPass,$ordinaryRepair,$governingReceipt,$ordinaryVerify)
  Assert-True ($strictWithOrdinaryLifecycle.state-eq"authorized"-and$strictWithOrdinaryLifecycle.reason-eq"GOVERNING_PASS") `
    "ordinary non-review ControllerHead rows do not pollute a valid strict pair"

  function New-HistoricalLifecyclePollution([string]$Kind,[datetimeoffset]$Ts) {
    [pscustomobject][ordered]@{
      ts=$Ts.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'");kind=$Kind;controllerReviewSchema="controller-review-receipt/v1"
      issue=6335;controllerHead=$headA;authorAttempt=$null;reviewerAttempt=$null;reviewAuthority=$null
      lane=$null;transcript=$null;reviewerModel=$null;authorModel=$null;effort=$null;row=$null;placement=$null;harness=$null
    }
  }
  $historicalRepair=New-HistoricalLifecyclePollution "repair-complete" $baseInstant.AddMinutes(10).AddSeconds(10)
  $historicalVerify=New-HistoricalLifecyclePollution "verify-complete" $baseInstant.AddMinutes(12)
  $historicalPollution=Invoke-ControllerReduction @($governingPass,$historicalRepair,$governingReceipt,$historicalVerify)
  Assert-True ($historicalPollution.state-eq"indeterminate"-and
    $historicalPollution.reason-eq"MALFORMED_RELEVANT_STRICT_ROW"-and
    $historicalPollution.census.invalidConflict-eq2) `
    "the planted predecessor emitter shape fails closed for both lifecycle kinds"

  $strictInflight=Invoke-ControllerReduction @($governingPass)
  Assert-True ($strictInflight.state-eq"in-flight"-and$strictInflight.census.governing.inFlight-eq1) "every candidate dispatch must become terminal"

  $strictDuplicate=Invoke-ControllerReduction @($governingPass,$governingPass,$governingReceipt,$governingReceipt)
  Assert-True ($strictDuplicate.state-eq"authorized"-and$strictDuplicate.census.duplicateReplay-eq2) "exact byte duplicate replay collapses"

  $conflictingReceipt=New-StrictControllerRow review-complete governing BLOCK_FIXABLE
  $strictConflict=Invoke-ControllerReduction @($governingPass,$governingReceipt,$conflictingReceipt)
  Assert-True ($strictConflict.state-eq"indeterminate"-and$strictConflict.reason-eq"STRICT_PAIR_CONFLICT") "changed terminal under reused attempts conflicts"

  $strictCausality=Invoke-ControllerReduction @($governingReceipt,$governingPass)
  Assert-True ($strictCausality.state-eq"indeterminate"-and$strictCausality.reason-eq"STRICT_TERMINAL_NOT_CAUSAL") "terminal-before-dispatch refuses"

  $foreignAuthorReuse=New-StrictControllerRow dispatch advisory "" $headB 6400 controller-author foreign-reviewer
  $strictAuthorReuse=Invoke-ControllerReduction @($foreignAuthorReuse,$governingPass,$governingReceipt)
  Assert-True ($strictAuthorReuse.state-eq"authorized"-and$strictAuthorReuse.reason-eq"GOVERNING_PASS") "historical author attempt reuse on another issue cannot poison lane-bound candidate authority"

  $foreignReviewerReuse=New-StrictControllerRow dispatch advisory "" $headB 6400 foreign-author controller-reviewer
  $strictReviewerReuse=Invoke-ControllerReduction @($foreignReviewerReuse,$governingPass,$governingReceipt)
  Assert-True ($strictReviewerReuse.state-eq"authorized"-and$strictReviewerReuse.reason-eq"GOVERNING_PASS") "historical reviewer attempt reuse on another issue cannot poison lane-bound candidate authority"

  $historicalHead="fb089bfa633647cad9f12ff121dd0c73b2f53e5a"
  $liveHead="40721b674cae01cf0cc2536bc7016b4d52b4c1d8"
  $historicalDispatch=New-StrictControllerRow dispatch governing "" $historicalHead 6251 author-6251-fb089bf-sol-r1 review-6251-fb089bf-opus5-r1
  $historicalDispatch.ts="2026-08-02T05:02:04.378Z"
  $historicalDispatch.lane="chase-sets-controller-6251-packet-repair-r1"
  $historicalDispatch.transcript="6251-opus5-high-controller-review-r2.jsonl"
  $historicalDispatch.reviewerModel="claude-opus-5"
  $historicalDispatch.row="11"
  $historicalDispatch.placement="provisional"
  $historicalDispatch.harness="claude"
  $historicalReceipt=New-StrictControllerRow review-complete governing PASS $historicalHead 6251 author-6251-fb089bf-sol-r1 review-6251-fb089bf-opus5-r1
  $historicalReceipt.ts="2026-08-02T05:31:41.135Z"
  $historicalReceipt.lane="lane-external"
  $historicalReceipt.transcript="6251-opus5-high-controller-review-r2.jsonl"
  $historicalReceipt.reviewerModel="claude-opus-5"
  $historicalReceipt.row="11"
  $historicalReceipt.placement="provisional"
  $historicalReceipt.harness="claude"
  $historicalReceipt.findings.candidates=3
  $historicalReceipt.findings.nonBlocking=5
  $liveDispatch=New-StrictControllerRow dispatch governing "" $liveHead 6251 6251-sol-high-packet-a-40721-fresh-r1 a098c3b6-0800-4f0d-9ec3-01d46689faa0
  $liveDispatch.ts="2026-08-02T18:29:44.374Z"
  $liveDispatch.lane="controller-6251-packet-a-r3"
  $liveDispatch.transcript="6251-opus5-high-packet-b-40721-governing-review-r1.jsonl"
  $liveDispatch.reviewerModel="claude-opus-5"
  $liveDispatch.row="11"
  $liveDispatch.placement="provisional"
  $liveDispatch.harness="claude"
  $liveReceipt=New-StrictControllerRow review-complete governing PASS $liveHead 6251 6251-sol-high-packet-a-40721-fresh-r1 a098c3b6-0800-4f0d-9ec3-01d46689faa0
  $liveReceipt.ts="2026-08-02T18:51:58.783Z"
  $liveReceipt.lane="controller-6251-packet-a-r3"
  $liveReceipt.transcript="6251-opus5-high-packet-b-40721-governing-review-r1.jsonl"
  $liveReceipt.reviewerModel="claude-opus-5"
  $liveReceipt.row="11"
  $liveReceipt.placement="provisional"
  $liveReceipt.harness="claude"
  $liveReceipt.findings.candidates=4
  $liveReceipt.findings.nonBlocking=7
  $liveHistoryReduction=Invoke-ControllerReduction @($historicalDispatch,$historicalReceipt,$liveDispatch,$liveReceipt) strict-v1 6251 $liveHead
  Assert-True ($liveHistoryReduction.state-eq"authorized"-and$liveHistoryReduction.reason-eq"GOVERNING_PASS"-and
    $liveHistoryReduction.selected.governingPair.lane-ceq"controller-6251-packet-a-r3"-and
    $liveHistoryReduction.selected.governingPair.transcript-ceq"6251-opus5-high-packet-b-40721-governing-review-r1.jsonl") `
    "an unrelated historical tuple mismatch does not block the exact live distinct-attempt candidate (observed=$($liveHistoryReduction|ConvertTo-Json -Compress -Depth 20))"

  $nestedUnknown=New-StrictControllerRow review-complete governing PASS
  $nestedUnknown.findings["surprise"]=1
  $strictClosed=Invoke-ControllerReduction @($governingPass,$nestedUnknown)
  Assert-True ($strictClosed.state-eq"indeterminate"-and$strictClosed.reason-eq"MALFORMED_RELEVANT_STRICT_ROW") "nested unknown fields fail closed (observed=$($strictClosed|ConvertTo-Json -Compress -Depth 20))"

  $unsupportedSchema=New-StrictControllerRow review-complete governing PASS
  $unsupportedSchema.controllerReviewSchema="controller-review-receipt/v99"
  $strictUnsupported=Invoke-ControllerReduction @($governingPass,$unsupportedSchema)
  Assert-True ($strictUnsupported.state-eq"indeterminate"-and$strictUnsupported.reason-eq"MALFORMED_RELEVANT_STRICT_ROW") "an unknown strict schema cannot downgrade into legacy authority"

  $v2Dispatch=New-StrictControllerRow dispatch governing "" $headA 6335 v2-author v2-reviewer v2
  $v2Receipt=New-StrictControllerRow review-complete governing PASS $headA 6335 v2-author v2-reviewer v2
  $strictV2=Invoke-ControllerReduction @($v2Dispatch,$v2Receipt) strict-v2
  Assert-True ($strictV2.state-eq"authorized"-and$strictV2.mode-eq"strict-v2") "v2 reader requires exact stage review"

  Write-Output "PASS review-head reducer ordinary byte-stable lifecycle and strict controller authority coverage"
} finally {
  $resolved = [IO.Path]::GetFullPath($testRoot)
  $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd("\", "/")
  if ((Split-Path -Parent $resolved).TrimEnd("\", "/") -ne $temp -or
      (Split-Path -Leaf $resolved) -notlike "review-head-reducer-test-*") {
    throw "refusing unsafe test cleanup target: $resolved"
  }
  Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
}
