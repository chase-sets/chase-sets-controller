[CmdletBinding()]
param([string]$HistorySnapshot,[string]$HistoryModule,[string]$HistoryOutput)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot 'routing-data-test-support.ps1')
$routingTestScope=Enter-RoutingDataTestScope
try {

# Optional read-only AC3 replay. Both processes receive the same captured file;
# the baseline module is extracted from Git, never copied from the candidate.
if ($HistorySnapshot) {
  if (-not $HistoryModule -or -not $HistoryOutput) { throw 'history replay requires module and output paths' }
  $timer=[Diagnostics.Stopwatch]::StartNew()
  $module=Import-Module $HistoryModule -Force -PassThru -DisableNameChecking
  & $module {
    param($snapshot,$output)
    $bytes=[IO.File]::ReadAllBytes($snapshot)
    if(-not $bytes.Length -or $bytes[-1]-ne10){throw 'snapshot must contain complete newline-terminated history'}
    $lines=[IO.File]::ReadAllLines($snapshot)
    $history=Read-ExactHeadReviewHistory -Path $snapshot -MaxRows $lines.Count -MaxBytes $bytes.Length
    if($history.audit.truncated -or $history.audit.rows-ne@($lines|Where-Object{-not[string]::IsNullOrWhiteSpace($_)}).Count){throw 'incomplete history census'}
    if($history.reason-cnotin@('HISTORY_COMPLETE','HISTORY_MALFORMED')){throw "history unreadable: $($history.reason)"}
    $writer=[IO.StreamWriter]::new($output,$false,[Text.UTF8Encoding]::new($false))
    $writer.NewLine="`n"
    try {
      $writer.WriteLine(($history|Select-Object complete,reason,audit|ConvertTo-Json -Compress -Depth 30))
      $pairs=[Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
      $script:replayCache=[Collections.Generic.Dictionary[object,object]]::new([Collections.Generic.ReferenceEqualityComparer]::Instance)
      foreach($entry in $history.rows){
        $classification=Get-ControllerReviewRowClassification $entry
        $script:replayCache.Add($entry,$classification)
        $writer.WriteLine(([ordered]@{entry=$entry;classification=$classification}|ConvertTo-Json -Compress -Depth 100))
        if($null-ne$classification.controllerHead){
          $pair=[ordered]@{issue=$classification.issue;controllerHead=$classification.controllerHead}
          $key=$pair|ConvertTo-Json -Compress
          if(-not$pairs.Contains($key)){$pairs[$key]=$pair}
        }
      }
      # Preserve raw identities even for JSON-malformed rows the reader audits
      # rather than classifies. Nothing is filtered from the reducer's history.
      foreach($lineNumber in $history.audit.malformedLineNumbers){
        $writer.WriteLine(([ordered]@{malformedLine=$lineNumber;raw=$lines[$lineNumber-1]}|ConvertTo-Json -Compress))
      }
      # Only pure classifications of the exact immutable entry objects are
      # memoized. Every reduction still sees the complete unmodified history;
      # correction projections use the original classifier. Check equivalence
      # against an uncached reduction before replaying all historical pairs.
      $first=@($pairs.Values|Where-Object{(Test-WholeNumber $_.issue 1)-and$_.issue-le[int]::MaxValue-and$_.controllerHead-cmatch'^[a-f0-9]{40}$'})[0]
      $uncached=Reduce-ControllerReleaseReview -Issue $first.issue -ControllerHead $first.controllerHead -Mode strict-v1 -History $history|ConvertTo-Json -Compress -Depth 100
      $script:replayClassifier=${function:Get-ControllerReviewRowClassification}
      function script:Get-ControllerReviewRowClassification($Entry){
        if($script:replayCache.ContainsKey($Entry)){return $script:replayCache[$Entry]}
        & $script:replayClassifier $Entry
      }
      $cached=Reduce-ControllerReleaseReview -Issue $first.issue -ControllerHead $first.controllerHead -Mode strict-v1 -History $history|ConvertTo-Json -Compress -Depth 100
      if($uncached-cne$cached){throw 'memoized replay differs from uncached reduction'}
      foreach($pair in $pairs.Values){
        try{$result=Reduce-ControllerReleaseReview -Issue $pair.issue -ControllerHead $pair.controllerHead -Mode strict-v1 -History $history}
        catch{$result=[ordered]@{refused=$_.Exception.Message;errorId=$_.FullyQualifiedErrorId}}
        $writer.WriteLine(([ordered]@{pair=$pair;reduction=$result}|ConvertTo-Json -Compress -Depth 100))
      }
      Write-Output "same-snapshot-history-parity rows=$($history.audit.rows) parsed=$($history.rows.Count) malformed=$($history.audit.malformedRows) pairs=$($pairs.Count) memoization-control=byte-identical"
    } finally {$writer.Dispose()}
  } ([IO.Path]::GetFullPath($HistorySnapshot)) ([IO.Path]::GetFullPath($HistoryOutput))
  Write-Output "elapsedSeconds=$($timer.Elapsed.TotalSeconds) outputSha256=$((Get-FileHash $HistoryOutput -Algorithm SHA256).Hash)"
  return
}

$reducer = Join-Path $PSScriptRoot "review-head-reducer.ps1"
$legacyFixture = Join-Path $PSScriptRoot "fixtures/legacy-non-pr-review-history.jsonl"
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("review-head-reducer-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$baselinePath=Join-Path $testRoot 'controller-review-baseline.psm1'
$baselineSource=& git -C (Split-Path -Parent $PSScriptRoot) show '16c53af23eb0656e7d2b233164fee99d8be55527:.orchestrator/review-head-contract.psm1'
if($LASTEXITCODE-ne0){throw 'cannot extract reducer equivalence baseline'}
[IO.File]::WriteAllLines($baselinePath,$baselineSource,[Text.UTF8Encoding]::new($false))
$script:equivalenceBaseline=Import-Module $baselinePath -Force -PassThru -DisableNameChecking
$script:ordinaryEquivalenceCount=0
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
  $actual=& $reducer -Pr $Pr -CurrentHead $Head -HistoryPath $path -MaxHistoryRows $MaxRows |
    ConvertFrom-Json -DateKind String
  $old=& $script:equivalenceBaseline {
    param($path,$max,$pr,$head)
    Reduce-ExactHeadReview -Pr $pr -CurrentHead $head -History (Read-ExactHeadReviewHistory -Path $path -MaxRows $max) | ConvertTo-Json -Depth 8
  } $path $MaxRows $Pr $Head | ConvertFrom-Json -DateKind String
  Assert-True (($actual|ConvertTo-Json -Compress -Depth 100)-ceq($old|ConvertTo-Json -Compress -Depth 100)) "H0 ordinary reducer equivalence $Pr/$Head"
  $script:ordinaryEquivalenceCount+=1
  $actual
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
    if($Version-eq"v2"){$row.policyGeneration=1;$row.registryAuthorityDigest='synthetic-authority';$row.family='sol';$row.slot='codex.primary';$row.usedLastKnownGood=$false;$row.stage='review'}
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
    Invoke-EquivalentControllerReduction -Issue $Issue -ControllerHead $Head -Mode $Mode -History $history
  }

  # Every existing controller fixture, including direct reduction calls below,
  # is checked against H0, not a duplicate of the optimized implementation.
  $script:equivalenceCandidate=Get-Module review-head-contract
  $script:equivalenceCount=0
  function Invoke-EquivalentControllerReduction {
    param($Issue,$ControllerHead,$Mode,$History,$DispatchTuple)
    $args=@{Issue=$Issue;ControllerHead=$ControllerHead;Mode=$Mode;History=$History}
    if($null-ne$DispatchTuple){$args.DispatchTuple=$DispatchTuple}
    $actual=& $script:equivalenceCandidate {param($p) Reduce-ControllerReleaseReview @p} $args
    $expected=& $script:equivalenceBaseline {param($p) Reduce-ControllerReleaseReview @p} $args
    Assert-True (($actual|ConvertTo-Json -Compress -Depth 100)-ceq($expected|ConvertTo-Json -Compress -Depth 100)) "H0 equivalence $Mode/$Issue/$ControllerHead"
    $oldClasses=@(& $script:equivalenceBaseline {
      param($h)
      $v=Get-ReviewRecordVocabulary
      foreach($entry in $h.rows){[pscustomobject]@{entry=$entry;classification=(Get-ControllerReviewRowClassification $entry $v)}}
    } $History)
    $newClasses=@(& $script:equivalenceCandidate {param($h) Get-ControllerReviewClassifiedHistory -History $h} $History)
    foreach($classes in @(@{name='installer';predicate={ $_.classification.strict -and $_.classification.valid -and $_.classification.controllerHead -ceq $ControllerHead }},
      @{name='battery';predicate={ $_.classification.strict -and $_.classification.valid -and $_.classification.issue -eq $Issue -and $_.classification.controllerHead -ceq $ControllerHead -and $_.classification.rowKind -ceq 'receipt' -and $_.classification.reviewAuthority -ceq 'governing' }})){
      $before=@($oldClasses|Where-Object $classes.predicate)|ConvertTo-Json -Compress -Depth 100
      $after=@($newClasses|Where-Object $classes.predicate)|ConvertTo-Json -Compress -Depth 100
      Assert-True ($before-ceq$after) "H0 $($classes.name) selector equivalence $Mode/$Issue"
    }
    $script:equivalenceCount+=1
    $actual
  }

  $f2RegistrySnapshot=Set-ProductionShapedRoutingRegistry (Join-Path $routingTestScope.root 'model-registry.json')
  try {
    $terraReceipt=New-Receipt 6335 $headA PASS 30
    $terraReceipt.model='gpt-5.6-terra';$terraReceipt.authorModel='gpt-5.6-terra'
    $terraReceipt | Add-Member -NotePropertyName effort -NotePropertyValue max
    $terraReceipt | Add-Member -NotePropertyName authorEffort -NotePropertyValue high
    $terraReduction=Invoke-Reduction @($terraReceipt) -Pr 6335 -Head $headA
    Assert-True ($terraReduction.state-eq'authorized'-and$terraReduction.reason-eq'LATEST_EXACT_HEAD_PASS') 'reader-only Terra receipt was rejected'
    $terraReceipt.effort='ultra'
    Assert-True (-not (Get-ReviewReceiptValidation $terraReceipt).valid) 'history reader admitted an effort outside the closed vocabulary'
    $terraReceipt.effort='max'
    $pr8083Receipt=New-Receipt 8083 $headA PASS 31
    $pr8083Receipt.model='gpt-5.6-terra';$pr8083Receipt.authorModel='gpt-5.6-terra'
    $pr8083Reduction=Invoke-Reduction @($pr8083Receipt) -Pr 8083 -Head $headA
    Assert-True ($pr8083Reduction.state-eq'authorized'-and$pr8083Reduction.reason-eq'LATEST_EXACT_HEAD_PASS') 'PR 8083-shaped historical receipt did not reduce authorized'
    $maxDispatch=New-StrictControllerRow dispatch governing; $maxReceipt=New-StrictControllerRow review-complete governing PASS
    $maxDispatch.effort='max';$maxReceipt.effort='max'
    $maxReduction=Invoke-ControllerReduction @($maxDispatch,$maxReceipt)
    Assert-True ($maxReduction.state-eq'authorized'-and$maxReduction.reason-eq'GOVERNING_PASS') 'max-effort controller row was rejected'
    Write-Output 'PASS F2 historical reader vocabulary Terra receipt and max-effort controller row'
  } finally { Restore-RoutingRegistryBytes $f2RegistrySnapshot }

  $governingPass=New-StrictControllerRow dispatch governing
  $governingReceipt=New-StrictControllerRow review-complete governing PASS
  # #8064: construction-only fields retain closed shape, UTC and numeric bounds.
  # No test-only timestamp, JSON or numeric coercion seam is added to the writer.
  $constructedCases=@(
    @{Name='unknown-key';Code='ROW_SHAPE_NOT_CLOSED';Change={param($r) $r|Add-Member surprise 1}},
    @{Name='date-only';Code='INVALID_TS';Change={param($r) $r.ts='2026-09-24'}},
    @{Name='invalid-utc';Code='INVALID_TS';Change={param($r) $r.ts='2026-02-30T00:00:00.000Z'}},
    @{Name='fractional-issue';Code='INVALID_ISSUE';Change={param($r) $r.issue=1.5}},
    @{Name='overflow-issue';Code='INVALID_ISSUE';Change={param($r) $r.issue=2147483648L}},
    @{Name='nested-key';Code='FINDINGS_SHAPE_NOT_CLOSED';Change={param($r) $r.findings|Add-Member surprise 1}},
    @{Name='fractional-count';Code='INVALID_CANDIDATES';Change={param($r) $r.findings.candidates=0.5}},
    @{Name='overflow-count';Code='INVALID_NONBLOCKING';Change={param($r) $r.findings.nonBlocking=10001}},
    @{Name='negative-count';Code='INVALID_BLOCKING';Change={param($r) $r.findings.blocking=-1}}
  )
  foreach($case in $constructedCases){
    $row=$governingReceipt|ConvertTo-Json -Depth 20|ConvertFrom-Json -DateKind String
    $row.reviewerModel='gpt-6.1-sol';$row.authorModel='gpt-6-astra';$row.row='11'
    Assert-True ((Get-ControllerReviewRowClassification $row).valid) 'current-model constructed-field baseline must classify valid'
    & $case.Change $row
    $classification=Get-ControllerReviewRowClassification $row
    Assert-True (-not$classification.valid-and$case.Code-cin$classification.errors) "strict-constructed-fields/$($case.Name) expected $($case.Code)"
    Write-Output "PASS strict-constructed-fields/$($case.Name) $($case.Code)"
  }
  $rawDispatch=$governingPass|ConvertTo-Json -Compress
  $rawReceipt=$governingReceipt|ConvertTo-Json -Compress -Depth 10
  $duplicateProperties=[ordered]@{
    'literal-tuple'=$rawDispatch.Replace('"authorAttempt":"controller-author"','"authorAttempt":"synthetic-ambiguous-first","authorAttempt":"controller-author"')
    'escaped-equivalent-tuple'=$rawDispatch.Replace('"authorAttempt":"controller-author"','"author\u0041ttempt":"synthetic-ambiguous-first","authorAttempt":"controller-author"')
    'nested-findings'=$rawReceipt.Replace('"blocking":0','"blocking":1,"blocking":0')
    'nested-escaped-findings'=$rawReceipt.Replace('"blocking":0','"block\u0069ng":1,"blocking":0')
    'object-inside-array'='{"kind":"synthetic-data","values":[{"nested":{"name":1,"name":2}}]}'
  }
  foreach($case in $duplicateProperties.Keys){
    $raw=$duplicateProperties[$case]
    $path=Join-Path $testRoot "duplicate-property-$case.jsonl"
    [IO.File]::WriteAllLines($path,@($rawDispatch,$raw),[Text.UTF8Encoding]::new($false))
    $beforeHash=(Get-FileHash $path).Hash
    $history=Read-ExactHeadReviewHistory -Path $path
    $reduced=Invoke-EquivalentControllerReduction -Issue 6335 -ControllerHead $headA -Mode strict-v1 -History $history
    Assert-True (-not$history.complete-and$history.reason-eq'HISTORY_MALFORMED'-and$history.audit.malformedRows-eq1-and$history.audit.parsedRows-eq1-and$history.audit.malformedLineNumbers[0]-eq2) "$case duplicate must be a malformed physical row before classification"
    Assert-True ($reduced.state-eq'indeterminate'-and$reduced.reason-eq'HISTORY_MALFORMED'-and$beforeHash-ceq(Get-FileHash $path).Hash) "$case must refuse strict reduction without changing raw history"
    Write-Output "PASS F1 raw duplicate property: $case (HISTORY_MALFORMED; bytes unchanged)"
  }
  $uniqueNested='{"kind":"synthetic-data","values":[{"name":1},{"name":2}],"text":"\"name\":1,\"name\":2"}'
  $uniqueReduction=Invoke-ControllerReduction @($governingPass,$uniqueNested,$governingReceipt)
  Assert-True ($uniqueReduction.state-eq'authorized') 'unique names in separate nested objects and duplicate-looking string contents remain valid'
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

  # #8110 AC4: the case-sensitive placement control is not loosened. `override-Todd`
  # is invalid with exactly one error; the lowercase precedent shape stays valid.
  $overrideToddRow=New-StrictControllerRow dispatch governing "" $headA 8103 "goal-8110-author" "goal-8110-reviewer-r1"
  $overrideToddRow.lane="controller-8110-review-r1";$overrideToddRow.transcript="controller-8110-review-r1.jsonl";$overrideToddRow.placement="override-Todd"
  $overrideToddClass=Get-ControllerReviewRowClassification $overrideToddRow
  Assert-True ($overrideToddClass.strict-and-not$overrideToddClass.valid-and$overrideToddClass.rowKind-ceq"dispatch"-and
    @($overrideToddClass.errors).Count-eq1-and$overrideToddClass.errors[0]-ceq"INVALID_PLACEMENT") `
    "AC4: override-Todd must classify invalid with the single error INVALID_PLACEMENT (observed=$($overrideToddClass|ConvertTo-Json -Compress -Depth 20))"
  $overrideToddLower=$overrideToddRow.PSObject.Copy();$overrideToddLower.placement="override-todd"
  Assert-True ((Get-ControllerReviewRowClassification $overrideToddLower).valid) "AC4: the lowercase override placement precedent stays valid"

  # #8110 AC1: a dangling malformed strict dispatch row (no terminal row, no
  # successor valid dispatch on its issue/head) fails closed AND is classified
  # dangling; a dispatch-only audit correction under Todd authority clears it
  # without any terminal hash, and the head becomes reachable again.
  function New-DanglingDispatchCorrection($Target,[string]$Authority="Todd:synthetic-8110-test-ruling",[string]$Placement="override-todd",[bool]$WithAuthority=$true) {
    $raw=$Target|ConvertTo-Json -Compress -Depth 10
    $hash=([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($raw)))).ToLowerInvariant()
    $row=[ordered]@{
      ts=[datetimeoffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'");kind="controller-review-audit-correction";controllerReviewSchema="controller-review-audit-correction/v1"
      issue=$Target.issue;controllerHead=$Target.controllerHead;authorAttempt=$Target.authorAttempt;reviewerAttempt=$Target.reviewerAttempt;reviewAuthority=$Target.reviewAuthority
      lane=$Target.lane;transcript=$Target.transcript;reviewerModel=$Target.reviewerModel;authorModel=$Target.authorModel;effort=$Target.effort;row=$Target.row;placement=$Placement;harness=$Target.harness
      originalDispatchRawSha256=$hash
    }
    if($WithAuthority){$row.operatorAuthority=$Authority}
    [pscustomobject]$row
  }
  $danglingRow=$overrideToddRow
  $danglingOnly=Invoke-ControllerReduction @($danglingRow) strict-v1 8103
  Assert-True ($danglingOnly.state-eq"indeterminate"-and$danglingOnly.reason-eq"MALFORMED_RELEVANT_STRICT_ROW"-and
    $danglingOnly.census.invalidConflict-eq1-and@($danglingOnly.audit.invalidRows).Count-eq1-and
    $danglingOnly.audit.invalidRows[0].line-eq1-and$danglingOnly.audit.invalidRows[0].errors[0]-ceq"INVALID_PLACEMENT"-and
    $danglingOnly.audit.invalidRows[0].dangling-eq$true) `
    "AC1: a dangling malformed dispatch row fails closed and is classified dangling (observed=$($danglingOnly|ConvertTo-Json -Compress -Depth 20))"
  $danglingCorrection=New-DanglingDispatchCorrection $danglingRow
  $danglingCleared=Invoke-ControllerReduction @($danglingRow,$danglingCorrection) strict-v1 8103
  Assert-True ($danglingCleared.state-eq"indeterminate"-and$danglingCleared.reason-eq"NO_STRICT_REVIEW_HISTORY"-and
    $danglingCleared.census.invalidConflict-eq0-and$null-eq$danglingCleared.selected-and
    @($danglingCleared.audit.danglingCorrections).Count-eq1-and$danglingCleared.audit.danglingCorrections[0].physicalLine-eq2-and
    $danglingCleared.audit.danglingCorrections[0].originalPhysicalLine-eq1-and
    $danglingCleared.audit.danglingCorrections[0].originalDispatchRawSha256-ceq$danglingCorrection.originalDispatchRawSha256-and
    $danglingCleared.audit.danglingCorrections[0].operatorAuthority-ceq"Todd:synthetic-8110-test-ruling") `
    "AC1: a dispatch-only correction clears the dangling row without a terminal and grants nothing (observed=$($danglingCleared|ConvertTo-Json -Compress -Depth 20))"
  # The same clearance through the producer: log-event.ps1 appends the correction
  # row (no originalTerminalRawSha256 key) after the immutable original bytes.
  $danglingPath=Join-Path $testRoot "dangling-8110.jsonl"
  [IO.File]::WriteAllLines($danglingPath,@(($danglingRow|ConvertTo-Json -Compress -Depth 10)),[Text.UTF8Encoding]::new($false))
  $danglingHistory=Read-ExactHeadReviewHistory -Path $danglingPath
  $danglingPrefix=[IO.File]::ReadAllBytes($danglingPath)
  $producerCorrection=@{Log='dispatch';Kind='controller-review-audit-correction';Issue=8103;ControllerHead=$headA;Lane=$danglingRow.lane;LaneRole='review';Transcript=$danglingRow.transcript;Harness=$danglingRow.harness;Model='gpt-6.1-sol';AuthorModel='gpt-6.1-sol';Effort=$danglingRow.effort;Row=$danglingRow.row;Placement='override-todd';AuthorAttempt=$danglingRow.authorAttempt;ReviewerAttempt=$danglingRow.reviewerAttempt;ReviewAuthority=$danglingRow.reviewAuthority;OriginalDispatchRawSha256=$danglingHistory.rows[0].rawSha256;OperatorAuthority='Todd:synthetic-8110-test-ruling';OutFile=$danglingPath;NoBoard=$true}
  & (Join-Path $PSScriptRoot "log-event.ps1") @producerCorrection | Out-Null
  $producedHistory=Read-ExactHeadReviewHistory -Path $danglingPath
  $producedBytes=[IO.File]::ReadAllBytes($danglingPath)
  Assert-True ([Convert]::ToBase64String($danglingPrefix)-ceq[Convert]::ToBase64String($producedBytes[0..($danglingPrefix.Length-1)])-and
    $producedHistory.rows.Count-eq2-and$producedHistory.rows[1].value.controllerReviewSchema-ceq"controller-review-audit-correction/v1"-and
    $null-eq$producedHistory.rows[1].value.PSObject.Properties["originalTerminalRawSha256"]-and
    $producedHistory.rows[1].value.originalDispatchRawSha256-ceq$danglingHistory.rows[0].rawSha256) `
    "AC1: the producer appended a dispatch-only correction after the immutable original without a terminal hash"
  $producedReduction=Invoke-EquivalentControllerReduction -Issue 8103 -ControllerHead $headA -Mode strict-v1 -History $producedHistory
  Assert-True ($producedReduction.reason-eq"NO_STRICT_REVIEW_HISTORY"-and@($producedReduction.audit.danglingCorrections).Count-eq1) "AC1: the produced correction clears the dangling row"
  # Reachable again: a relaunched review on a fresh lane is admitted at prelaunch
  # and its governing PASS authorizes on the original rows, never the cleared one.
  $relaunchDispatch=New-StrictControllerRow dispatch governing "" $headA 8103 "goal-8110-author" "goal-8110-reviewer-r2"
  $relaunchDispatch.lane="controller-8110-review-r2";$relaunchDispatch.transcript="controller-8110-review-r2.jsonl";$relaunchDispatch.ts=[datetimeoffset]::UtcNow.AddSeconds(-2).ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
  $relaunchReceipt=New-StrictControllerRow review-complete governing PASS $headA 8103 "goal-8110-author" "goal-8110-reviewer-r2"
  $relaunchReceipt.lane="controller-8110-review-r2";$relaunchReceipt.transcript="controller-8110-review-r2.jsonl";$relaunchReceipt.ts=[datetimeoffset]::UtcNow.AddSeconds(-1).ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
  $relaunchPath=Join-Path $testRoot "dangling-8110-relaunch.jsonl"
  [IO.File]::WriteAllLines($relaunchPath,@(($danglingRow|ConvertTo-Json -Compress -Depth 10),($danglingCorrection|ConvertTo-Json -Compress -Depth 10),($relaunchDispatch|ConvertTo-Json -Compress -Depth 10)),[Text.UTF8Encoding]::new($false))
  $relaunchPrelaunch=Invoke-EquivalentControllerReduction -Issue 8103 -ControllerHead $headA -Mode strict-v1 -History (Read-ExactHeadReviewHistory -Path $relaunchPath) -DispatchTuple $relaunchDispatch
  Assert-True ($relaunchPrelaunch.state-eq"in-flight"-and$relaunchPrelaunch.reason-eq"STRICT_ATTEMPT_IN_FLIGHT") `
    "AC1: after clearance the relaunched prelaunch tuple is in flight (observed=$($relaunchPrelaunch|ConvertTo-Json -Compress -Depth 20))"
  $relaunchDone=Invoke-ControllerReduction @($danglingRow,$danglingCorrection,$relaunchDispatch,$relaunchReceipt) strict-v1 8103
  Assert-True ($relaunchDone.state-eq"authorized"-and$relaunchDone.reason-eq"GOVERNING_PASS"-and
    $relaunchDone.selected.governingPair.lane-ceq"controller-8110-review-r2"-and
    $relaunchDone.selected.governingPair.dispatchRawSha256-cne$danglingCorrection.originalDispatchRawSha256-and
    @($relaunchDone.selected.rows|Where-Object{$_.kind-ceq"audit-corrected-dispatch"}).Count-eq0-and
    @($relaunchDone.audit.danglingCorrections).Count-eq1) `
    "AC1: the relaunched governing PASS authorizes on its own rows, never the cleared one (observed=$($relaunchDone|ConvertTo-Json -Compress -Depth 20))"

  # #8110 AC2/AC3 in the reducer: what a dispatch-only correction can never clear.
  $terminalBackedReceipt=New-StrictControllerRow review-complete governing PASS $headA 8103 "goal-8110-author" "goal-8110-reviewer-r1"
  $terminalBackedReceipt.lane=$danglingRow.lane;$terminalBackedReceipt.transcript=$danglingRow.transcript
  $terminalBacked=Invoke-ControllerReduction @($danglingRow,$terminalBackedReceipt) strict-v1 8103
  Assert-True ($terminalBacked.state-eq"indeterminate"-and$terminalBacked.reason-eq"MALFORMED_RELEVANT_STRICT_ROW"-and
    $terminalBacked.census.invalidConflict-eq1-and$terminalBacked.audit.invalidRows[0].dangling-eq$false) `
    "AC2: a malformed row with a matching review-complete is not dangling and still fails closed (observed=$($terminalBacked|ConvertTo-Json -Compress -Depth 20))"
  $terminalBackedCorrected=Invoke-ControllerReduction @($danglingRow,$terminalBackedReceipt,$danglingCorrection) strict-v1 8103
  Assert-True ($terminalBackedCorrected.state-eq"indeterminate"-and$terminalBackedCorrected.reason-eq"AUDIT_ORIGINAL_NOT_DANGLING") `
    "AC2: a dispatch-only correction cannot clear a terminal-backed malformed row (observed=$($terminalBackedCorrected|ConvertTo-Json -Compress -Depth 20))"
  $lateTerminal=Invoke-ControllerReduction @($danglingRow,$danglingCorrection,$terminalBackedReceipt) strict-v1 8103
  Assert-True ($lateTerminal.state-eq"indeterminate"-and$lateTerminal.reason-eq"AUDIT_ORIGINAL_NOT_DANGLING") `
    "AC2: a matching terminal that lands after the correction unbinds it (observed=$($lateTerminal|ConvertTo-Json -Compress -Depth 20))"
  $malformedTerminal=$terminalBackedReceipt.PSObject.Copy();$malformedTerminal.placement="override-Todd"
  $bothMalformed=Invoke-ControllerReduction @($danglingRow,$malformedTerminal,$danglingCorrection) strict-v1 8103
  Assert-True ($bothMalformed.state-eq"indeterminate"-and$bothMalformed.reason-eq"AUDIT_ORIGINAL_NOT_DANGLING") `
    "AC2: a malformed pair is pollution, not a dangling row (observed=$($bothMalformed|ConvertTo-Json -Compress -Depth 20))"
  $successorBefore=Invoke-ControllerReduction @($danglingRow,$relaunchDispatch,$danglingCorrection) strict-v1 8103
  Assert-True ($successorBefore.state-eq"indeterminate"-and$successorBefore.reason-eq"AUDIT_ORIGINAL_NOT_DANGLING") `
    "AC2: a valid successor dispatch before the correction means the row was not dangling (observed=$($successorBefore|ConvertTo-Json -Compress -Depth 20))"
  $successorUncorrected=Invoke-ControllerReduction @($danglingRow,$relaunchDispatch) strict-v1 8103
  Assert-True ($successorUncorrected.reason-eq"MALFORMED_RELEVANT_STRICT_ROW"-and$successorUncorrected.audit.invalidRows[0].dangling-eq$false) "AC2: a superseded malformed row is not classified dangling"
  $validTarget=Invoke-ControllerReduction @($relaunchDispatch,(New-DanglingDispatchCorrection $relaunchDispatch "Todd:synthetic-8110-test-ruling" "measured")) strict-v1 8103
  Assert-True ($validTarget.state-eq"indeterminate"-and$validTarget.reason-eq"AUDIT_DISPATCH_MISMATCH") `
    "AC2: a dispatch-only correction cannot clear a valid dispatch row (observed=$($validTarget|ConvertTo-Json -Compress -Depth 20))"
  $foreignHeadCorrection=New-DanglingDispatchCorrection $danglingRow;$foreignHeadCorrection.controllerHead="b"*40
  $foreignHead=Invoke-ControllerReduction @($danglingRow,$foreignHeadCorrection) strict-v1 8103
  Assert-True ($foreignHead.reason-eq"MALFORMED_RELEVANT_STRICT_ROW"-and$foreignHead.census.invalidConflict-eq1) "AC2: a correction on another head clears nothing here"
  $sentinelPair=New-DanglingDispatchCorrection $danglingRow
  $sentinelPair|Add-Member -NotePropertyName originalTerminalRawSha256 -NotePropertyValue ("0"*64)
  $sentinelCleared=Invoke-ControllerReduction @($danglingRow,$sentinelPair) strict-v1 8103
  Assert-True ($sentinelCleared.state-eq"indeterminate"-and$sentinelCleared.reason-eq"MALFORMED_RELEVANT_STRICT_ROW"-and$sentinelCleared.census.invalidConflict-eq1) `
    "AC2: a fabricated terminal hash is a pair correction that binds nothing and clears nothing (observed=$($sentinelCleared|ConvertTo-Json -Compress -Depth 20))"
  $noAuthority=Invoke-ControllerReduction @($danglingRow,(New-DanglingDispatchCorrection $danglingRow "" "override-todd" $false)) strict-v1 8103
  Assert-True ($noAuthority.reason-eq"MALFORMED_RELEVANT_STRICT_ROW"-and$noAuthority.census.invalidConflict-eq2-and
    @($noAuthority.audit.invalidRows|Where-Object{$_.line-eq2-and"ROW_SHAPE_NOT_CLOSED"-cin$_.errors}).Count-eq1) `
    "AC3: a correction without operatorAuthority is itself malformed and clears nothing (observed=$($noAuthority|ConvertTo-Json -Compress -Depth 20))"
  $wrongAuthority=Invoke-ControllerReduction @($danglingRow,(New-DanglingDispatchCorrection $danglingRow "synthetic:not-todd")) strict-v1 8103
  Assert-True ($wrongAuthority.reason-eq"MALFORMED_RELEVANT_STRICT_ROW"-and$wrongAuthority.census.invalidConflict-eq2-and
    @($wrongAuthority.audit.invalidRows|Where-Object{$_.line-eq2-and"INVALID_OPERATOR_AUTHORITY"-cin$_.errors}).Count-eq1) `
    "AC3: a correction whose authority is not Todd's is itself malformed and clears nothing (observed=$($wrongAuthority|ConvertTo-Json -Compress -Depth 20))"
  $duplicateCorrection=Invoke-ControllerReduction @($danglingRow,$danglingCorrection,$danglingCorrection) strict-v1 8103
  Assert-True ($duplicateCorrection.state-eq"indeterminate"-and$duplicateCorrection.reason-eq"AUDIT_CORRECTION_DUPLICATE") "AC2: a replayed dispatch-only correction fails closed"
  $absentTarget=New-DanglingDispatchCorrection $governingPass "Todd:synthetic-8110-test-ruling" "measured";$absentTarget.originalDispatchRawSha256="c"*64
  $historicalPollutionStill=Invoke-ControllerReduction @($governingPass,$historicalRepair,$governingReceipt,$historicalVerify,$absentTarget)
  Assert-True ($historicalPollutionStill.state-eq"indeterminate"-and$historicalPollutionStill.reason-eq"AUDIT_ORIGINAL_COUNT") "AC2: a correction naming no physical row binds nothing and clears nothing (observed=$($historicalPollutionStill|ConvertTo-Json -Compress -Depth 20))"
  $historicalCorrectionOnPollution=New-DanglingDispatchCorrection $governingPass "Todd:synthetic-8110-test-ruling" "measured"
  $historicalCorrectionOnPollution.originalDispatchRawSha256=(New-DanglingDispatchCorrection $historicalRepair).originalDispatchRawSha256
  $historicalPollutionNamed=Invoke-ControllerReduction @($governingPass,$historicalRepair,$governingReceipt,$historicalVerify,$historicalCorrectionOnPollution)
  Assert-True ($historicalPollutionNamed.state-eq"indeterminate"-and$historicalPollutionNamed.reason-eq"AUDIT_DISPATCH_MISMATCH") "AC2: historical lifecycle pollution is not a dispatch row and cannot be cleared (observed=$($historicalPollutionNamed|ConvertTo-Json -Compress -Depth 20))"
  Write-Output "PASS #8110 dangling malformed dispatch row: dangling classification, dispatch-only correction under Todd authority, terminal-backed pollution still closed"

  Assert-True ($script:equivalenceCount -eq 39) "equivalence must exercise all 39 controller fixture invocations; observed=$script:equivalenceCount"

  # New v1 addendum fixtures deliberately differ from H0. The 39 historical
  # equivalence controls above still compare the complete reduction bytewise.
  function New-ControllerAddendumFixture {
    $rows=@(
      (New-StrictControllerRow dispatch governing),
      (New-StrictControllerRow review-complete governing BLOCK_FIXABLE),
      (New-StrictControllerRow dispatch governing '' $headA 6335 controller-author addendum-reviewer),
      (New-StrictControllerRow review-complete governing PASS $headA 6335 controller-author addendum-reviewer)
    )
    $hash=(Get-ControllerReviewRowClassification $rows[1]).rawSha256
    foreach($index in 2..3){
      $rows[$index].ts=$baseInstant.AddMinutes(10+$index).ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
      $rows[$index].lane='addendum-lane';$rows[$index].transcript='addendum.jsonl'
      $rows[$index]|Add-Member supersedesReceiptRawSha256 $hash
      $rows[$index]|Add-Member addressedFindingIds ([object[]]@('F1'))
    }
    $rows
  }
  function Invoke-AddendumReduction([object[]]$Rows,[string]$Mode='strict-v1') {
    $path=Join-Path $testRoot ('addendum-'+[guid]::NewGuid().ToString('N')+'.jsonl')
    [IO.File]::WriteAllLines($path,@($Rows|ForEach-Object{
      if($_-is[string]){$_}else{$_|ConvertTo-Json -Compress -Depth 10}
    }),[Text.UTF8Encoding]::new($false))
    & $script:equivalenceCandidate {
      param($p,$mode,$head)
      Reduce-ControllerReleaseReview -Issue 6335 -ControllerHead $head -Mode $mode -History (Read-ExactHeadReviewHistory -Path $p)
    } $path $Mode $headA
  }
  $addendumRows=New-ControllerAddendumFixture
  $addendum=Invoke-AddendumReduction $addendumRows
  Assert-True ($addendum.state-ceq'authorized'-and$addendum.reason-ceq'GOVERNING_PASS') '#8547 bound same-head PASS must supersede the named BLOCK'
  Assert-True ($addendum.selected.governingBlock-eq0-and$addendum.census.governing.blockFixable-eq1-and
    $addendum.selected.rows.Count-eq4-and$addendum.audit.supersessions.Count-eq1-and
    $addendum.audit.supersessions[0].predecessorRawSha256-ceq$addendumRows[2].supersedesReceiptRawSha256-and
    $addendum.audit.supersessions[0].addendumRawSha256-ceq(Get-ControllerReviewRowClassification $addendumRows[3]).rawSha256-and
    $addendum.selected.governingPair.terminalRawSha256-ceq(Get-ControllerReviewRowClassification $addendumRows[3]).rawSha256) '#8547 keep the BLOCK in census/audit and select the bound PASS'
  $replayed=Invoke-AddendumReduction @($addendumRows+$addendumRows)
  Assert-True ($replayed.state-ceq'authorized'-and$replayed.census.duplicateReplay-eq4-and$replayed.audit.supersessions.Count-eq1) '#8547 byte-identical replay does not create a second supersession'
  foreach($blockOutcome in @('BLOCK_FIXABLE','BLOCK_REPLAN')){
    $rows=New-ControllerAddendumFixture
    $rows[1].outcome=$blockOutcome
    $rows[1].findingIds=[object[]]@('F1','F2');$rows[1].findings.blocking=2;$rows[1].findings.candidates=2
    foreach($index in 2..3){
      $rows[$index].supersedesReceiptRawSha256=(Get-ControllerReviewRowClassification $rows[1]).rawSha256
      $rows[$index].addressedFindingIds=[object[]]@('F2','F1')
    }
    Assert-True ((Invoke-AddendumReduction $rows).state-ceq'authorized') "#8547 $blockOutcome accepts all named findings in either order"
  }
  $negativeControls=[ordered]@{
    'unbound PASS'={param($r) foreach($i in 2..3){$r[$i].PSObject.Properties.Remove('supersedesReceiptRawSha256');$r[$i].PSObject.Properties.Remove('addressedFindingIds')}}
    'receipt-only binding'={param($r) $r[2].PSObject.Properties.Remove('supersedesReceiptRawSha256');$r[2].PSObject.Properties.Remove('addressedFindingIds')}
    'dispatch-only binding'={param($r) $r[3].PSObject.Properties.Remove('supersedesReceiptRawSha256');$r[3].PSObject.Properties.Remove('addressedFindingIds')}
    'missing predecessor'={param($r) foreach($i in 2..3){$r[$i].supersedesReceiptRawSha256='c'*64}}
    'malformed predecessor'={param($r) foreach($i in 2..3){$r[$i].supersedesReceiptRawSha256='not-a-hash'}}
    'missing findings'={param($r) $r[3].PSObject.Properties.Remove('addressedFindingIds')}
    'empty findings'={param($r) foreach($i in 2..3){$r[$i].addressedFindingIds=[object[]]@()}}
    'wrong finding'={param($r) foreach($i in 2..3){$r[$i].addressedFindingIds=[object[]]@('F2')}}
    'duplicate finding'={param($r) foreach($i in 2..3){$r[$i].addressedFindingIds=[object[]]@('F1','F1')}}
    'scalar findings'={param($r) foreach($i in 2..3){$r[$i].addressedFindingIds='F1'}}
    'extra finding'={param($r) foreach($i in 2..3){$r[$i].addressedFindingIds=[object[]]@('F1','F2')}}
    'wrong-case finding'={param($r) foreach($i in 2..3){$r[$i].addressedFindingIds=[object[]]@('f1')}}
    'partial findings'={param($r) $r[1].findingIds=[object[]]@('F1','F2');$r[1].findings.blocking=2;$r[1].findings.candidates=2;foreach($i in 2..3){$r[$i].supersedesReceiptRawSha256=(Get-ControllerReviewRowClassification $r[1]).rawSha256}}
    'wrong head'={param($r) foreach($i in 2..3){$r[$i].controllerHead=$headB}}
    'wrong issue'={param($r) foreach($i in 2..3){$r[$i].issue=6400}}
    'wrong author attempt'={param($r) foreach($i in 2..3){$r[$i].authorAttempt='other-author'}}
    'wrong reviewer attempt'={param($r) $r[3].reviewerAttempt='other-reviewer'}
    'reused predecessor attempt'={param($r) foreach($i in 2..3){$r[$i].reviewerAttempt=$r[1].reviewerAttempt}}
    'shadow addendum'={param($r) foreach($i in 2..3){$r[$i].reviewAuthority='shadow'}}
    'advisory addendum'={param($r) foreach($i in 2..3){$r[$i].reviewAuthority='advisory'}}
    'PASS with blockers'={param($r) $r[3].findingIds=[object[]]@('F3');$r[3].findings.blocking=1}
    'PASS with unresolved candidates'={param($r) $r[3].findings.candidates=1}
    'incomplete sweep'={param($r) $r[3].completeSweep=$false}
    'malformed timestamp'={param($r) $r[3].ts='yesterday'}
    'equal predecessor timestamp'={param($r) $r[2].ts=$r[1].ts}
    'reversed predecessor timestamp'={param($r) $r[2].ts=$r[0].ts}
    'equal terminal timestamp'={param($r) $r[3].ts=$r[2].ts}
    'reversed terminal timestamp'={param($r) $r[3].ts=$r[1].ts}
    'contradictory binding'={param($r) $r[3].supersedesReceiptRawSha256='d'*64}
    'malformed predecessor receipt'={param($r) $r[1].completeSweep=$false;foreach($i in 2..3){$r[$i].supersedesReceiptRawSha256=(Get-ControllerReviewRowClassification $r[1]).rawSha256}}
    'non-BLOCK predecessor'={param($r) foreach($i in 2..3){$r[$i].supersedesReceiptRawSha256=(Get-ControllerReviewRowClassification $r[0]).rawSha256}}
  }
  foreach($control in $negativeControls.GetEnumerator()){
    $rows=New-ControllerAddendumFixture
    & $control.Value $rows
    $result=Invoke-AddendumReduction $rows
    Assert-True ($result.state-cne'authorized') "#8547 fail closed: $($control.Key)"
  }
  $rows=New-ControllerAddendumFixture
  foreach($sequence in @(@($rows[0],$rows[2],$rows[1],$rows[3]),@($rows[0],$rows[1],$rows[3],$rows[2]),@($rows[0],$rows[2],$rows[3]),@($rows[0],$rows[1],$rows[2]),@($rows[1],$rows[2],$rows[3]),@($rows[0],$rows[1],$rows[3]))){
    Assert-True ((Invoke-AddendumReduction $sequence).state-cne'authorized') '#8547 missing or noncausal physical receipt/dispatch fails closed'
  }
  $laterDispatch=New-StrictControllerRow dispatch governing '' $headA 6335 controller-author later-reviewer
  $laterBlock=New-StrictControllerRow review-complete governing BLOCK_REPLAN $headA 6335 controller-author later-reviewer
  $laterDispatch.ts=$baseInstant.AddMinutes(14).ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
  $laterBlock.ts=$baseInstant.AddMinutes(15).ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
  $later=Invoke-AddendumReduction @($rows+@($laterDispatch,$laterBlock))
  Assert-True ($later.state-ceq'blocked'-and$later.reason-ceq'GOVERNING_BLOCK'-and$later.selected.governingBlock-eq1) '#8547 BLOCK PASS BLOCK remains blocked'
  $contradiction=$rows[3].PSObject.Copy();$contradiction.outcome='BLOCK_FIXABLE';$contradiction.findingIds=[object[]]@('F3');$contradiction.findings=[ordered]@{blocking=1;candidates=1;nonBlocking=0}
  Assert-True ((Invoke-AddendumReduction @($rows+@($contradiction))).state-cne'authorized') '#8547 contradictory terminal cannot supersede'
  Assert-True ((Invoke-AddendumReduction @($rows+@('{"kind":'))).state-cne'authorized') '#8547 malformed history cannot supersede'
  $second=New-ControllerAddendumFixture
  foreach($i in 2..3){$second[$i].reviewerAttempt='second-addendum';$second[$i].lane='second-lane';$second[$i].transcript='second.jsonl'}
  Assert-True ((Invoke-AddendumReduction @($rows+@($second[2],$second[3]))).state-cne'authorized') '#8547 competing supersessions fail closed'
  foreach($mode in @('legacy-h1','legacy-h2','strict-v2')){
    $result=Invoke-AddendumReduction $rows $mode
    Assert-True ($result.state-cne'authorized') "#8547 v1 addendum cannot open $mode"
  }
  $v2Rows=New-ControllerAddendumFixture
  foreach($row in $v2Rows){
    $row.controllerReviewSchema=$row.controllerReviewSchema.Replace('/v1','/v2')
    $row|Add-Member stage review
    $row|Add-Member policyGeneration 1
    $row|Add-Member registryAuthorityDigest synthetic-authority
    $row|Add-Member family sol
    $row|Add-Member slot codex.primary
    $row|Add-Member usedLastKnownGood $false
  }
  foreach($i in 2..3){$v2Rows[$i].supersedesReceiptRawSha256=(Get-ControllerReviewRowClassification $v2Rows[1]).rawSha256}
  Assert-True ((Invoke-AddendumReduction $v2Rows strict-v2).reason-ceq'MALFORMED_RELEVANT_STRICT_ROW') '#8547 strict-v2 still rejects addendum fields'
  foreach($i in 2..3){$v2Rows[$i].PSObject.Properties.Remove('supersedesReceiptRawSha256');$v2Rows[$i].PSObject.Properties.Remove('addressedFindingIds')}
  Assert-True ((Invoke-AddendumReduction $v2Rows strict-v2).reason-ceq'GOVERNING_BLOCK') '#8547 strict-v2 BLOCK followed by unbound PASS remains blocked'
  foreach($legacyMode in @('legacy-h1','legacy-h2')){
    $legacyIssue=if($legacyMode-ceq'legacy-h1'){6348}else{6335}
    $legacyPair=@((New-StrictControllerRow dispatch governing),(New-StrictControllerRow review-complete governing PASS))
    foreach($row in $legacyPair){
      $row.PSObject.Properties.Remove('controllerReviewSchema');$row.issue=$legacyIssue
      $row|Add-Member laneRole review;$row|Add-Member model $row.reviewerModel
    }
    $path=Join-Path $testRoot "$legacyMode-unchanged.jsonl"
    [IO.File]::WriteAllLines($path,@($legacyPair|ForEach-Object{$_|ConvertTo-Json -Compress -Depth 10}),[Text.UTF8Encoding]::new($false))
    $history=Read-ExactHeadReviewHistory -Path $path
    $parameters=@{Issue=$legacyIssue;ControllerHead=$headA;Mode=$legacyMode;History=$history}
    $current=& $script:equivalenceCandidate {param($p) Reduce-ControllerReleaseReview @p} $parameters
    $baseline=& $script:equivalenceBaseline {param($p) Reduce-ControllerReleaseReview @p} $parameters
    Assert-True ($current.state-ceq'authorized'-and($current|ConvertTo-Json -Compress -Depth 100)-ceq($baseline|ConvertTo-Json -Compress -Depth 100)) "#8547 $legacyMode remains byte-equivalent and authorizes its genuine shape"
  }
  Write-Output "PASS #8547 same-head bound addendum; audit/replay; both BLOCK outcomes; $($negativeControls.Count) field controls; causal/missing/contradiction/later-BLOCK controls; legacy/v2 closed"
  Write-Output "PASS review-head reducer ordinary byte-stable lifecycle and strict controller authority coverage; H0 equivalent controller fixtures=$script:equivalenceCount ordinary fixtures=$script:ordinaryEquivalenceCount"
} finally {
  $resolved = [IO.Path]::GetFullPath($testRoot)
  $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd("\", "/")
  if ((Split-Path -Parent $resolved).TrimEnd("\", "/") -ne $temp -or
      (Split-Path -Leaf $resolved) -notlike "review-head-reducer-test-*") {
    throw "refusing unsafe test cleanup target: $resolved"
  }
  Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
}
} finally {
  Exit-RoutingDataTestScope $routingTestScope
}
