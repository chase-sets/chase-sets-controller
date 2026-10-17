$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lane-selection.ps1")

$script:Passed = 0
$script:Failed = 0

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}

function Assert-Equal([object]$Actual, [object]$Expected, [string]$Message) {
  if ([string]$Actual -cne [string]$Expected) {
    throw "$Message (actual='$Actual', expected='$Expected')"
  }
}

function Assert-Sequence([object[]]$Actual, [object[]]$Expected, [string]$Message) {
  $actualText = (@($Actual) | ForEach-Object { [string]$_ }) -join "|"
  $expectedText = (@($Expected) | ForEach-Object { [string]$_ }) -join "|"
  if ($actualText -cne $expectedText) {
    throw "$Message (actual='$actualText', expected='$expectedText')"
  }
}

function Assert-Rejected([string]$Name, [scriptblock]$Action, [string]$MessagePattern = "") {
  $rejected = $false
  try {
    & $Action
  } catch {
    if ($MessagePattern -and $_.Exception.Message -notmatch $MessagePattern) {
      throw "$Name fired the wrong clause: $($_.Exception.Message)"
    }
    $rejected = $true
  }
  if (-not $rejected) { throw "$Name bypass mutant survived" }
  Write-Host "  mutant-red: $Name"
}

function Invoke-Test([string]$Name, [scriptblock]$Test) {
  try {
    & $Test
    $script:Passed++
    Write-Host "PASS $Name"
  } catch {
    $script:Failed++
    Write-Host "FAIL $Name"
    Write-Host $_
  }
}

function Copy-JsonObject([object]$Object) {
  return ($Object | ConvertTo-Json -Depth 100 -Compress) | ConvertFrom-Json
}

function Read-AdmissionFixture {
  return Get-Content -LiteralPath (Join-Path $PSScriptRoot "fixtures/lane-admission-collected-input.valid.json") -Raw |
    ConvertFrom-Json
}

function Read-SelectionFixture {
  return Get-Content -LiteralPath (Join-Path $PSScriptRoot "fixtures/lane-selection-input.valid.json") -Raw |
    ConvertFrom-Json
}

function New-FixtureReceipt {
  return ConvertTo-LaneAdmission (Read-AdmissionFixture)
}

function Invoke-PublicSelection([object]$Receipt, [object]$InputObject) {
  $receiptPath = [IO.Path]::Combine([IO.Path]::GetTempPath(), "lane-receipt-$([guid]::NewGuid().ToString('N')).json")
  $inputPath = [IO.Path]::Combine([IO.Path]::GetTempPath(), "lane-selection-$([guid]::NewGuid().ToString('N')).json")
  try {
    $encoding = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText($receiptPath, ($Receipt | ConvertTo-Json -Depth 100), $encoding)
    [IO.File]::WriteAllText($inputPath, ($InputObject | ConvertTo-Json -Depth 100), $encoding)
    $jsonLines = @(& (Join-Path $PSScriptRoot "lane-selection.ps1") `
      -ReceiptPath $receiptPath -InputPath $inputPath -Compact)
    return ($jsonLines -join [Environment]::NewLine) | ConvertFrom-Json
  } finally {
    if ([IO.File]::Exists($receiptPath)) { [IO.File]::Delete($receiptPath) }
    if ([IO.File]::Exists($inputPath)) { [IO.File]::Delete($inputPath) }
  }
}

function Assert-NoSelectionReason([object]$Result, [string]$Reason, [string]$Message) {
  Assert-Equal $Result.status "no-selection" $Message
  Assert-Equal @($Result.selectedBatch).Count 0 "$Message selected no candidate"
  Assert-True (@($Result.reasonCodes) -contains $Reason) "$Message reason '$Reason'"
}

Invoke-Test "ac03-host-input-completeness-matrix" {
  $receipt = New-FixtureReceipt
  $greenInput = Read-SelectionFixture
  $green = Invoke-PublicSelection $receipt $greenInput
  Assert-Equal $green.status "selected" "candidate green"
  Assert-True (@($green.selectedBatch) -contains 101) "candidate green selected explicit priority"
  if (Get-Command Test-Json -ErrorAction SilentlyContinue) {
    Assert-True (($greenInput | ConvertTo-Json -Depth 100) |
      Test-Json -SchemaFile (Join-Path $PSScriptRoot "lane-selection-input-v1.schema.json")) "host input JSON schema"
    Assert-True (($green | ConvertTo-Json -Depth 100) |
      Test-Json -SchemaFile (Join-Path $PSScriptRoot "lane-selection-v1.schema.json")) "selection JSON schema"
  }

  $missing = Copy-JsonObject $greenInput
  $missing.judgments = @($missing.judgments | Where-Object { $_.candidate -ne 104 })
  $missingResult = ConvertTo-LaneSelection $receipt $missing
  Assert-NoSelectionReason $missingResult "HOST_INPUT_INCOMPLETE" "M5 missing row"
  Write-Host "  mutant-red: mutant-host-absence-means-eligible"

  $duplicate = Copy-JsonObject $greenInput
  $duplicate.judgments = @($duplicate.judgments) + @((Copy-JsonObject $duplicate.judgments[0]))
  $duplicateResult = ConvertTo-LaneSelection $receipt $duplicate
  Assert-NoSelectionReason $duplicateResult "HOST_INPUT_DUPLICATE" "M5 duplicate row"
  Write-Host "  mutant-red: mutant-first-host-row-wins"

  $ambiguous = Copy-JsonObject $greenInput
  $ambiguous.judgments[3].ambiguous = $true
  Assert-NoSelectionReason (ConvertTo-LaneSelection $receipt $ambiguous) "HOST_INPUT_AMBIGUOUS" "M5 ambiguous row"

  $incomplete = Copy-JsonObject $greenInput
  $incomplete.complete = $false
  Assert-NoSelectionReason (ConvertTo-LaneSelection $receipt $incomplete) "HOST_INPUT_INCOMPLETE" "M8 present input incomplete"
  Write-Host "  mutant-red: mutant-present-host-container-is-complete"

  $stale = Copy-JsonObject $greenInput
  $stale.validUntil = "2026-07-31T05:02:59Z"
  Assert-NoSelectionReason (ConvertTo-LaneSelection $receipt $stale) "HOST_INPUT_STALE" "expired host input"

  $preReceipt = Copy-JsonObject $greenInput
  $preReceipt.capturedAt = "2026-07-31T05:00:59Z"
  Assert-NoSelectionReason (ConvertTo-LaneSelection $receipt $preReceipt) "HOST_INPUT_STALE" "host input captured before receipt"

  $moving = Copy-JsonObject $greenInput
  $moving.finalAuthorityRevision = "host-judgments-r2"
  Assert-NoSelectionReason (ConvertTo-LaneSelection $receipt $moving) "HOST_INPUT_MOVED" "moving host input"

  $malformed = Copy-JsonObject $greenInput
  $malformed.judgments[0].gatedTrack | Add-Member -NotePropertyName inferredFromLabel -NotePropertyValue $true
  Assert-Rejected "mutant-lax-host-nested-schema" {
    [void](ConvertTo-LaneSelection $receipt $malformed)
  } "unknown property"
}

Invoke-Test "ac04-overlapping-priority-and-fallback" {
  $receipt = New-FixtureReceipt
  Assert-True (@($receipt.conflictGraph.candidateEdges | Where-Object {
    ($_.left -eq 101 -and $_.right -eq 102) -or ($_.left -eq 102 -and $_.right -eq 101)
  }).Count -eq 1) "A/B overlap fixture missing"
  Assert-True (@($receipt.conflictGraph.candidateEdges | Where-Object {
    ($_.left -eq 103 -and $_.right -eq 104) -or ($_.left -eq 104 -and $_.right -eq 103)
  }).Count -eq 1) "C/D overlap fixture missing"

  $inputObject = Read-SelectionFixture
  $result = Invoke-PublicSelection $receipt $inputObject
  Assert-Sequence @($result.selectedBatch) @(101,104) "explicit A wins B and closed-window C cannot suppress D"
  Assert-True (@($result.serialized | Where-Object { $_.candidate -eq 102 -and $_.yieldsTo -eq "101" }).Count -eq 1) "B serialized to A"
  Assert-True (@($result.eligibleCandidates) -notcontains 103) "closed-window C filtered before batching"
  Assert-True (@($result.selectedBatch) -contains 104) "fallback D selected despite conflict with filtered C"
  Write-Host "  mutant-red: mutant-conflict-before-host-filter"

  $allIneligible = Copy-JsonObject $inputObject
  foreach ($judgment in $allIneligible.judgments) {
    $judgment.explicitPriority = $false
    $judgment.launchSpine = $false
    $judgment.gatedTrack.member = $false
    $judgment.gatedTrack.open = $null
    $judgment.hardeningCloseout = $false
    $judgment.milestoneExitGateSatisfied = $false
  }
  $empty = ConvertTo-LaneSelection $receipt $allIneligible
  Assert-Equal $empty.status "selected" "complete all-ineligible host judgment is valid"
  Assert-Equal @($empty.selectedBatch).Count 0 "no eligible judgment selects nothing"
  Assert-True (@($empty.reasonCodes) -contains "NO_ELIGIBLE_CANDIDATES") "empty selection reason"
  Write-Host "  mutant-red: mutant-no-eligible-means-first"

  $emptySnapshot = Read-AdmissionFixture
  $emptySnapshot.candidates = @()
  $candidateCoverage = @($emptySnapshot.authorityRows | Where-Object { $_.set -ceq "candidate-issues" })[0].coverage
  $candidateCoverage.collected = 0
  $candidateCoverage.total = 0
  $emptyReceipt = ConvertTo-LaneAdmission $emptySnapshot
  $emptyInput = Read-SelectionFixture
  $emptyInput.judgments = @()
  $emptyInput.waveOrder = @()
  $emptyInput.executableWaveMilestoneId = $null
  $emptyResult = ConvertTo-LaneSelection $emptyReceipt $emptyInput
  Assert-Equal $emptyResult.status "selected" "zero-candidate host input is explicitly complete"
  Assert-Equal @($emptyResult.selectedBatch).Count 0 "zero-candidate cycle selects nothing"
}

Invoke-Test "ac05-host-wave-order" {
  $receipt = New-FixtureReceipt
  $inputObject = Read-SelectionFixture
  $inputObject.judgments[0].explicitPriority = $false
  $result = ConvertTo-LaneSelection $receipt $inputObject
  Assert-True (@($result.eligibleCandidates) -notcontains 101) "native lower milestone number may not become wave order"
  Assert-True (@($result.selectedBatch) -contains 104) "host first/executable wave selected"
  Assert-Equal $receipt.structurallyEligibleCandidates[0].milestone.number 100 "fixture native order"
  Assert-Equal $inputObject.waveOrder[0] "milestone-wave-1" "fixture host order reverses native number"
  Write-Host "  mutant-red: mutant-milestone-number-is-wave-order"

  $duplicate = Copy-JsonObject $inputObject
  $duplicate.waveOrder = @("milestone-wave-1","milestone-wave-1")
  Assert-NoSelectionReason (ConvertTo-LaneSelection $receipt $duplicate) "WAVE_ORDER_DUPLICATE" "duplicate wave order"

  $incomplete = Copy-JsonObject $inputObject
  $incomplete.waveOrder = @("milestone-wave-1")
  Assert-NoSelectionReason (ConvertTo-LaneSelection $receipt $incomplete) "WAVE_ORDER_INCOMPLETE" "incomplete wave permutation"

  $unknownChoice = Copy-JsonObject $inputObject
  $unknownChoice.executableWaveMilestoneId = "milestone-wave-3"
  Assert-NoSelectionReason (ConvertTo-LaneSelection $receipt $unknownChoice) "EXECUTABLE_WAVE_UNKNOWN" "choice outside permutation"

  $proseMutant = Copy-JsonObject $inputObject
  $proseMutant | Add-Member -NotePropertyName milestoneTitle -NotePropertyValue "Wave 1"
  Assert-Rejected "mutant-title-or-due-date-orders-wave" {
    [void](ConvertTo-LaneSelection $receipt $proseMutant)
  } "unknown property"
}

Invoke-Test "ac06-operator-existence-window-matrix" {
  $receipt = New-FixtureReceipt
  $green = Read-SelectionFixture
  $greenResult = ConvertTo-LaneSelection $receipt $green
  Assert-True (@($greenResult.eligibleCandidates) -notcontains 103) "current false window excludes only C"
  Assert-True (@($greenResult.selectedBatch) -contains 104) "closed-window C leaves D selectable"
  Write-Host "  mutant-red: mutant-closed-window-closes-cycle"

  $missingRecord = Copy-JsonObject $green
  $missingRecord.judgments[2].operator.complete = $false
  Assert-NoSelectionReason (ConvertTo-LaneSelection $receipt $missingRecord) "OPERATOR_RECORD_MISSING" "missing window record"

  $missingWindow = Copy-JsonObject $green
  $missingWindow.judgments[2].operator.windowOpen = $null
  Assert-NoSelectionReason (ConvertTo-LaneSelection $receipt $missingWindow) "OPERATOR_RECORD_MISSING" "dependency without window truth"

  $missingLabel = Copy-JsonObject $green
  $receiptMissingLabel = Copy-JsonObject $receipt
  @($receiptMissingLabel.structurallyEligibleCandidates | Where-Object { $_.number -eq 103 })[0].operatorLabel = $false
  Assert-NoSelectionReason (ConvertTo-LaneSelection $receiptMissingLabel $missingLabel) "OPERATOR_LABEL_INCONSISTENT" "declared dependency with missing label"
  Write-Host "  mutant-red: mutant-missing-label-means-no-dependency"

  $nonePlusLabel = Copy-JsonObject $green
  $nonePlusLabel.judgments[2].operator.dependencyExists = $false
  $nonePlusLabel.judgments[2].operator.windowOpen = $null
  Assert-NoSelectionReason (ConvertTo-LaneSelection $receipt $nonePlusLabel) "OPERATOR_LABEL_INCONSISTENT" "none plus label inconsistency"
  Write-Host "  mutant-red: mutant-label-alone-is-authority"

  $expired = Copy-JsonObject $green
  $expired.judgments[2].operator.validUntil = "2026-07-31T05:02:59Z"
  Assert-NoSelectionReason (ConvertTo-LaneSelection $receipt $expired) "OPERATOR_RECORD_EXPIRED" "expired operator window"

  $moving = Copy-JsonObject $green
  $moving.judgments[2].operator.finalRevision = "operator-103-r2"
  Assert-NoSelectionReason (ConvertTo-LaneSelection $receipt $moving) "OPERATOR_RECORD_MOVED" "moving operator record"
}

Invoke-Test "ac10-selected-batch-scale-gate" {
  $receipt = New-FixtureReceipt
  $inputObject = Read-SelectionFixture
  $backfill = Invoke-PublicSelection $receipt $inputObject
  Assert-Equal $backfill.scale.action "backfill" "backfill precedes add"
  Assert-True ($backfill.scale.gates.runnableReadyDisjointWork) "selected batch derives runnable gate"
  Assert-True ($backfill.scale.gates.queueAndDeployHealthy) "queue/deploy exact gate"
  Assert-True ($backfill.scale.gates.hostCapacitySafe) "option-1 host capacity exact gate"
  Assert-True ($backfill.scale.gates.ownershipSafe) "ownership exact gate"

  $addReceipt = Copy-JsonObject $receipt
  $addReceipt.capacityFacts.ownership.active = 4
  $add = ConvertTo-LaneSelection $addReceipt $inputObject
  Assert-Equal $add.scale.action "add" "add only when no idle lane and authorization remains"
  Assert-Equal $add.scale.recommendedLaneCount 5 "add recommends one bounded lane"

  $unknownMemory = Copy-JsonObject $receipt
  $unknownMemory.capacityFacts.hostCapacity.memorySafe = $null
  $holdMemory = ConvertTo-LaneSelection $unknownMemory $inputObject
  Assert-Equal $holdMemory.scale.action "hold" "unknown host memory holds"
  Assert-True (@($holdMemory.scale.reasonCodes) -contains "HOST_CAPACITY_UNKNOWN") "host capacity reason"

  $unknownDecision = Copy-JsonObject $receipt
  $unknownDecision.capacityFacts.decision = "unknown"
  Assert-Equal (ConvertTo-LaneSelection $unknownDecision $inputObject).scale.action "hold" "unresolved option-1 fact holds"

  $staleCapacity = Copy-JsonObject $receipt
  $staleCapacity.capacityFacts.hostCapacity.validUntil = "2026-07-31T05:02:59Z"
  Assert-Equal (ConvertTo-LaneSelection $staleCapacity $inputObject).scale.action "hold" "stale host capacity holds"

  $partialOwnership = Copy-JsonObject $receipt
  $partialOwnership.capacityFacts.ownership.complete = $false
  $holdOwnership = ConvertTo-LaneSelection $partialOwnership $inputObject
  Assert-Equal $holdOwnership.scale.action "hold" "partial ownership holds"
  Assert-True (@($holdOwnership.scale.reasonCodes) -contains "OWNERSHIP_UNKNOWN") "ownership reason"

  $missingHost = Copy-JsonObject $inputObject
  $missingHost.judgments = @($missingHost.judgments | Where-Object { $_.candidate -ne 104 })
  $noSelection = ConvertTo-LaneSelection $receipt $missingHost
  Assert-Equal $noSelection.status "no-selection" "host completeness blocks selection"
  Assert-Equal $noSelection.scale.action "hold" "scale requires lane-selection decision"
  Assert-True (@($noSelection.scale.reasonCodes) -contains "SCALE_REQUIRES_SELECTION") "post-selection scale clause"
  Write-Host "  mutant-red: mutant-scale-from-machine-candidate-count"
}

Invoke-Test "M5-host-input-complete-before-batch" {
  $receipt = New-FixtureReceipt
  $inputObject = Read-SelectionFixture
  $inputObject.judgments = @($inputObject.judgments | Where-Object { $_.candidate -ne 102 })
  $result = ConvertTo-LaneSelection $receipt $inputObject
  Assert-NoSelectionReason $result "HOST_INPUT_INCOMPLETE" "one omitted losing conflict row still closes whole cycle"
  Assert-Equal @($result.serialized).Count 0 "no conflict winner examined on incomplete host input"
  Write-Host "  mutant-red: mutant-conflict-winner-before-completeness"
}

Invoke-Test "M6-no-prose-or-native-wave-inference" {
  $receipt = New-FixtureReceipt
  $inputObject = Read-SelectionFixture
  $inputObject.judgments[0] | Add-Member -NotePropertyName issueProse -NotePropertyValue "explicit lane"
  Assert-Rejected "mutant-host-prose-inference" {
    [void](ConvertTo-LaneSelection $receipt $inputObject)
  } "unknown property"
}

Invoke-Test "M7-operator-two-fact-authority" {
  $receipt = New-FixtureReceipt
  $closed = Read-SelectionFixture
  $closedResult = ConvertTo-LaneSelection $receipt $closed
  Assert-Equal $closedResult.status "selected" "complete false window is candidate-scoped ineligibility"
  Assert-True (@($closedResult.selectedBatch) -contains 104) "fallback remains work-conserving"

  $missing = Copy-JsonObject $closed
  $missing.judgments[2].operator.windowOpen = $null
  Assert-NoSelectionReason (ConvertTo-LaneSelection $receipt $missing) "OPERATOR_RECORD_MISSING" "missing truth is cycle-global unknown"
}

Invoke-Test "M10-work-conserving-selection" {
  $result = Invoke-PublicSelection (New-FixtureReceipt) (Read-SelectionFixture)
  Assert-Sequence @($result.selectedBatch) @(101,104) "A wins B; filtered C cannot suppress D"
}

Invoke-Test "ac11-discrimination-matrix" {
  $schema = Get-Content -LiteralPath (Join-Path $PSScriptRoot "lane-selection-v1.schema.json") -Raw |
    ConvertFrom-Json
  Assert-Sequence @($schema.'$defs'.selectionReasons.items.enum | Sort-Object) @($script:LaneSelectionReasonCodes | Sort-Object) "selection reason producer/consumer parity"
  Assert-Sequence @($schema.'$defs'.scaleReasons.items.enum | Sort-Object) @($script:LaneScaleReasonCodes | Sort-Object) "scale reason producer/consumer parity"
  $source = Get-Content -LiteralPath (Join-Path $PSScriptRoot "lane-selection.ps1") -Raw
  foreach ($reason in @($script:LaneSelectionReasonCodes) + @($script:LaneScaleReasonCodes)) {
    $occurrences = ([regex]::Matches($source, [regex]::Escape($reason))).Count
    Assert-True ($occurrences -ge 2) "reason '$reason' lacks declaration plus producer"
  }
  Assert-True ($source.IndexOf("No conflict winner is examined", [StringComparison]::Ordinal) -ge 0) "code-shape completeness guard absent"
  Write-Host "  candidate-green: complete immutable receipt-bound host input"
  Write-Host "  mutant-red: named controls ac03-ac10/M5-M10 all rejected"
}

if ($script:Failed -gt 0) {
  throw "lane-selection tests failed: $($script:Failed) failed, $($script:Passed) passed"
}
Write-Host "lane-selection tests passed: $($script:Passed)"
