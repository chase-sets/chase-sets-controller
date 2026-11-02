[CmdletBinding()]
param(
  [string]$ReceiptPath,
  [string]$ReceiptJson,
  [string]$InputPath,
  [string]$InputJson,
  [switch]$Compact
)

$ErrorActionPreference = "Stop"
$laneSelectionSavedReceiptPath = $ReceiptPath
$laneSelectionSavedReceiptJson = $ReceiptJson
$laneSelectionSavedInputPath = $InputPath
$laneSelectionSavedInputJson = $InputJson
$laneSelectionSavedCompact = $Compact
. (Join-Path $PSScriptRoot "lane-admission.ps1") -Library
$ReceiptPath = $laneSelectionSavedReceiptPath
$ReceiptJson = $laneSelectionSavedReceiptJson
$InputPath = $laneSelectionSavedInputPath
$InputJson = $laneSelectionSavedInputJson
$Compact = $laneSelectionSavedCompact

$script:LaneSelectionReasonCodes = @(
  "RECEIPT_NOT_COMPLETE",
  "HOST_INPUT_RECEIPT_MISMATCH",
  "HOST_INPUT_CYCLE_MISMATCH",
  "HOST_INPUT_INCOMPLETE",
  "HOST_INPUT_DUPLICATE",
  "HOST_INPUT_AMBIGUOUS",
  "HOST_INPUT_STALE",
  "HOST_INPUT_MOVED",
  "WAVE_ORDER_INCOMPLETE",
  "WAVE_ORDER_DUPLICATE",
  "EXECUTABLE_WAVE_UNKNOWN",
  "CANDIDATE_REVISION_MOVED",
  "MILESTONE_MOVED",
  "OPERATOR_LABEL_INCONSISTENT",
  "OPERATOR_RECORD_MISSING",
  "OPERATOR_RECORD_EXPIRED",
  "OPERATOR_RECORD_MOVED",
  "NO_ELIGIBLE_CANDIDATES",
  "CONFLICT_SERIALIZED"
)
$script:LaneScaleReasonCodes = @(
  "SCALE_REQUIRES_SELECTION",
  "RUNNABLE_WORK_UNKNOWN",
  "QUEUE_DEPLOY_UNHEALTHY",
  "HOST_CAPACITY_UNKNOWN",
  "OWNERSHIP_UNKNOWN",
  "NO_SCALE_CAPACITY"
)

function Add-LaneSelectionReason([Collections.Generic.HashSet[string]]$Set, [string]$Reason) {
  if ($Reason -cnotin $script:LaneSelectionReasonCodes) { throw "unknown selection reason '$Reason'" }
  [void]$Set.Add($Reason)
}

function Assert-LaneSelectionInputContract([object]$InputObject) {
  Assert-LaneExactKeys $InputObject @(
    "schemaVersion","receiptId","cycleId","selectionAt","capturedAt","validUntil",
    "authorityRevision","finalAuthorityRevision","complete","ambiguous","waveOrder",
    "executableWaveMilestoneId","judgments"
  ) @() "selectionInput"
  if ([string]$InputObject.schemaVersion -cne "lane-selection-input/v1") {
    throw "selectionInput.schemaVersion invalid"
  }
  Assert-LaneIdentifier $InputObject.receiptId "selectionInput.receiptId"
  Assert-LaneIdentifier $InputObject.cycleId "selectionInput.cycleId"
  foreach ($field in @("selectionAt","capturedAt","validUntil")) {
    [void](ConvertTo-LaneInstant (Get-LaneProperty $InputObject $field) "selectionInput.$field")
  }
  Assert-LaneIdentifier $InputObject.authorityRevision "selectionInput.authorityRevision"
  Assert-LaneIdentifier $InputObject.finalAuthorityRevision "selectionInput.finalAuthorityRevision"
  if ($InputObject.complete -isnot [bool] -or $InputObject.ambiguous -isnot [bool]) {
    throw "selectionInput completeness fields must be boolean"
  }
  foreach ($milestone in @($InputObject.waveOrder)) {
    Assert-LaneIdentifier $milestone "selectionInput.waveOrder[]"
  }
  if ($null -ne $InputObject.executableWaveMilestoneId) {
    Assert-LaneIdentifier $InputObject.executableWaveMilestoneId "selectionInput.executableWaveMilestoneId"
  }
  foreach ($judgment in @($InputObject.judgments)) {
    Assert-LaneExactKeys $judgment @(
      "candidate","candidateRevision","milestoneNodeId","milestoneRevision","explicitPriority",
      "launchSpine","gatedTrack","hardeningCloseout","milestoneExitGateSatisfied",
      "complete","ambiguous","operator"
    ) @() "selectionInput.judgments[]"
    Assert-LaneCount $judgment.candidate "judgment.candidate"
    if ([int]$judgment.candidate -lt 1) { throw "judgment.candidate invalid" }
    Assert-LaneIdentifier $judgment.candidateRevision "judgment.candidateRevision"
    Assert-LaneIdentifier $judgment.milestoneNodeId "judgment.milestoneNodeId"
    Assert-LaneIdentifier $judgment.milestoneRevision "judgment.milestoneRevision"
    foreach ($field in @(
      "explicitPriority","launchSpine","hardeningCloseout","milestoneExitGateSatisfied",
      "complete","ambiguous"
    )) {
      if ((Get-LaneProperty $judgment $field) -isnot [bool]) {
        throw "judgment.$field must be boolean"
      }
    }
    Assert-LaneExactKeys $judgment.gatedTrack @("member","open") @() "judgment.gatedTrack"
    if ($judgment.gatedTrack.member -isnot [bool] -or
        ($null -ne $judgment.gatedTrack.open -and $judgment.gatedTrack.open -isnot [bool])) {
      throw "judgment.gatedTrack fields invalid"
    }
    Assert-LaneExactKeys $judgment.operator @(
      "dependencyExists","windowOpen","complete","ambiguous","capturedAt","validUntil",
      "revision","finalRevision"
    ) @() "judgment.operator"
    if ($judgment.operator.dependencyExists -isnot [bool] -or
        ($null -ne $judgment.operator.windowOpen -and $judgment.operator.windowOpen -isnot [bool]) -or
        $judgment.operator.complete -isnot [bool] -or $judgment.operator.ambiguous -isnot [bool]) {
      throw "judgment.operator fields invalid"
    }
    [void](ConvertTo-LaneInstant $judgment.operator.capturedAt "judgment.operator.capturedAt")
    [void](ConvertTo-LaneInstant $judgment.operator.validUntil "judgment.operator.validUntil")
    Assert-LaneIdentifier $judgment.operator.revision "judgment.operator.revision"
    Assert-LaneIdentifier $judgment.operator.finalRevision "judgment.operator.finalRevision"
  }
  return $true
}

function New-LaneScaleDecision([object]$Receipt, [object]$Selection) {
  $reasons = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  $facts = $Receipt.capacityFacts
  $hostFacts = $facts.hostCapacity
  $ownership = $facts.ownership
  $scaleAt = ConvertTo-LaneInstant $Selection.generatedAt "selection.generatedAt"
  $hostCapturedAt = ConvertTo-LaneInstant $hostFacts.capturedAt "receipt.capacityFacts.hostCapacity.capturedAt"
  $hostValidUntil = ConvertTo-LaneInstant $hostFacts.validUntil "receipt.capacityFacts.hostCapacity.validUntil"
  $runnable = [string]$Selection.status -ceq "selected" -and @($Selection.selectedBatch).Count -gt 0
  $queueHealthy = $facts.queueAndDeployHealthy -is [bool] -and [bool]$facts.queueAndDeployHealthy
  $hostSafe = [string]$facts.decision -ceq "option-1" -and [bool]$hostFacts.complete -and
    $hostFacts.memorySafe -is [bool] -and [bool]$hostFacts.memorySafe -and
    $hostFacts.heavyVerifierSafe -is [bool] -and [bool]$hostFacts.heavyVerifierSafe -and
    [string]$hostFacts.revision -ceq [string]$hostFacts.finalRevision -and
    $hostCapturedAt -le $scaleAt -and $hostValidUntil -ge $scaleAt
  $ownershipSafe = [bool]$ownership.complete -and $ownership.safe -is [bool] -and
    [bool]$ownership.safe -and [string]$ownership.revision -ceq [string]$ownership.finalRevision -and
    [int]$ownership.active -le [int]$ownership.currentPool -and
    [int]$ownership.currentPool -le [int]$ownership.authorizedMax
  if ([string]$Selection.status -cne "selected") { [void]$reasons.Add("SCALE_REQUIRES_SELECTION") }
  if (-not $runnable) { [void]$reasons.Add("RUNNABLE_WORK_UNKNOWN") }
  if (-not $queueHealthy) { [void]$reasons.Add("QUEUE_DEPLOY_UNHEALTHY") }
  if (-not $hostSafe) { [void]$reasons.Add("HOST_CAPACITY_UNKNOWN") }
  if (-not $ownershipSafe) { [void]$reasons.Add("OWNERSHIP_UNKNOWN") }

  $currentPool = [int]$ownership.currentPool
  $active = [int]$ownership.active
  $authorizedMax = [int]$ownership.authorizedMax
  $idle = [Math]::Max(0, $currentPool - $active)
  $action = "hold"
  $recommended = $currentPool
  if ($runnable -and $queueHealthy -and $hostSafe -and $ownershipSafe) {
    if ($idle -gt 0) {
      $action = "backfill"
    } elseif ($currentPool -lt $authorizedMax) {
      $action = "add"
      $recommended = $currentPool + 1
    } else {
      [void]$reasons.Add("NO_SCALE_CAPACITY")
    }
  }
  return [ordered]@{
    action = $action
    reasonCodes = @($reasons | Sort-Object)
    gates = [ordered]@{
      runnableReadyDisjointWork = $runnable
      queueAndDeployHealthy = $queueHealthy
      hostCapacitySafe = $hostSafe
      ownershipSafe = $ownershipSafe
    }
    hostCapacityInputs = [ordered]@{
      memorySafe = $hostFacts.memorySafe
      heavyVerifierSafe = $hostFacts.heavyVerifierSafe
    }
    currentPool = $currentPool
    active = $active
    idle = $idle
    authorizedMax = $authorizedMax
    recommendedLaneCount = $recommended
  }
}

function New-LaneNoSelection(
  [object]$Receipt,
  [object]$InputObject,
  [Collections.Generic.HashSet[string]]$Reasons
) {
  $result = [ordered]@{
    schemaVersion = "lane-selection/v1"
    selectionId = "selection-$([string]$InputObject.receiptId)"
    receiptId = [string]$InputObject.receiptId
    cycleId = [string]$InputObject.cycleId
    generatedAt = Format-LaneInstant $InputObject.selectionAt "selectionInput.selectionAt"
    status = "no-selection"
    reasonCodes = @($Reasons | Sort-Object)
    eligibleCandidates = @()
    selectedBatch = @()
    serialized = @()
    scale = $null
    provenance = [ordered]@{
      receiptSchema = "lane-admission/v1"
      hostInputSchema = "lane-selection-input/v1"
      receiptGeneratedAt = Format-LaneInstant $Receipt.generatedAt "receipt.generatedAt"
      hostCapturedAt = Format-LaneInstant $InputObject.capturedAt "selectionInput.capturedAt"
    }
  }
  $result.scale = New-LaneScaleDecision $Receipt $result
  [void](Assert-LaneSelectionContract $result)
  return $result
}

function ConvertTo-LaneSelection([object]$Receipt, [object]$InputObject) {
  [void](Assert-LaneAdmissionContract $Receipt)
  [void](Assert-LaneSelectionInputContract $InputObject)
  $reasons = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  if ([string]$Receipt.status -cne "complete") { Add-LaneSelectionReason $reasons "RECEIPT_NOT_COMPLETE" }
  if ([string]$InputObject.receiptId -cne [string]$Receipt.receiptId) {
    Add-LaneSelectionReason $reasons "HOST_INPUT_RECEIPT_MISMATCH"
  }
  if ([string]$InputObject.cycleId -cne [string]$Receipt.cycleId) {
    Add-LaneSelectionReason $reasons "HOST_INPUT_CYCLE_MISMATCH"
  }
  if (-not [bool]$InputObject.complete) { Add-LaneSelectionReason $reasons "HOST_INPUT_INCOMPLETE" }
  if ([bool]$InputObject.ambiguous) { Add-LaneSelectionReason $reasons "HOST_INPUT_AMBIGUOUS" }
  if ([string]$InputObject.authorityRevision -cne [string]$InputObject.finalAuthorityRevision) {
    Add-LaneSelectionReason $reasons "HOST_INPUT_MOVED"
  }
  $selectionAt = ConvertTo-LaneInstant $InputObject.selectionAt "selectionInput.selectionAt"
  $capturedAt = ConvertTo-LaneInstant $InputObject.capturedAt "selectionInput.capturedAt"
  $validUntil = ConvertTo-LaneInstant $InputObject.validUntil "selectionInput.validUntil"
  $receiptGeneratedAt = ConvertTo-LaneInstant $Receipt.generatedAt "receipt.generatedAt"
  if ($capturedAt -gt $selectionAt -or $validUntil -lt $selectionAt -or
      $receiptGeneratedAt -gt $capturedAt) {
    Add-LaneSelectionReason $reasons "HOST_INPUT_STALE"
  }

  $candidateMap = @{}
  foreach ($candidate in @($Receipt.structurallyEligibleCandidates)) {
    $candidateMap[[string][int]$candidate.number] = $candidate
  }
  $judgmentGroups = @{}
  foreach ($judgment in @($InputObject.judgments)) {
    $key = [string][int]$judgment.candidate
    if (-not $judgmentGroups.ContainsKey($key)) { $judgmentGroups[$key] = @() }
    $judgmentGroups[$key] = @($judgmentGroups[$key]) + @($judgment)
  }
  foreach ($candidateKey in @($candidateMap.Keys)) {
    $rows = @($judgmentGroups[$candidateKey] | Where-Object { $null -ne $_ })
    if ($rows.Count -eq 0) { Add-LaneSelectionReason $reasons "HOST_INPUT_INCOMPLETE" }
    if ($rows.Count -gt 1) { Add-LaneSelectionReason $reasons "HOST_INPUT_DUPLICATE" }
  }
  foreach ($judgmentKey in @($judgmentGroups.Keys)) {
    if (-not $candidateMap.ContainsKey($judgmentKey)) {
      Add-LaneSelectionReason $reasons "HOST_INPUT_INCOMPLETE"
    }
  }

  $expectedMilestones = @($Receipt.structurallyEligibleCandidates |
    ForEach-Object { [string]$_.milestone.nodeId } | Sort-Object -Unique)
  $waveOrder = @($InputObject.waveOrder | ForEach-Object { [string]$_ })
  if (@($waveOrder | Sort-Object -Unique).Count -ne $waveOrder.Count) {
    Add-LaneSelectionReason $reasons "WAVE_ORDER_DUPLICATE"
  }
  $expectedWaveKey = (@($expectedMilestones | Sort-Object) -join "|")
  $actualWaveKey = (@($waveOrder | Sort-Object) -join "|")
  if ($expectedWaveKey -cne $actualWaveKey) {
    Add-LaneSelectionReason $reasons "WAVE_ORDER_INCOMPLETE"
  }
  if ($expectedMilestones.Count -eq 0) {
    if ($null -ne $InputObject.executableWaveMilestoneId) {
      Add-LaneSelectionReason $reasons "EXECUTABLE_WAVE_UNKNOWN"
    }
  } elseif ($null -eq $InputObject.executableWaveMilestoneId -or
            [string]$InputObject.executableWaveMilestoneId -cnotin $waveOrder) {
      Add-LaneSelectionReason $reasons "EXECUTABLE_WAVE_UNKNOWN"
  }

  $evaluated = @()
  if ($reasons.Count -eq 0) {
    foreach ($candidate in @($Receipt.structurallyEligibleCandidates)) {
      $judgment = @($judgmentGroups[[string][int]$candidate.number])[0]
      if (-not [bool]$judgment.complete) { Add-LaneSelectionReason $reasons "HOST_INPUT_INCOMPLETE" }
      if ([bool]$judgment.ambiguous) { Add-LaneSelectionReason $reasons "HOST_INPUT_AMBIGUOUS" }
      if ([string]$judgment.candidateRevision -cne [string]$candidate.revision) {
        Add-LaneSelectionReason $reasons "CANDIDATE_REVISION_MOVED"
      }
      if ([string]$judgment.milestoneNodeId -cne [string]$candidate.milestone.nodeId -or
          [string]$judgment.milestoneRevision -cne [string]$candidate.milestone.revision) {
        Add-LaneSelectionReason $reasons "MILESTONE_MOVED"
      }
      if ([bool]$judgment.gatedTrack.member -and $null -eq $judgment.gatedTrack.open) {
        Add-LaneSelectionReason $reasons "HOST_INPUT_INCOMPLETE"
      }
      if (-not [bool]$judgment.gatedTrack.member -and $null -ne $judgment.gatedTrack.open) {
        Add-LaneSelectionReason $reasons "HOST_INPUT_AMBIGUOUS"
      }

      $operator = $judgment.operator
      if (-not [bool]$operator.complete) { Add-LaneSelectionReason $reasons "OPERATOR_RECORD_MISSING" }
      if ([bool]$operator.ambiguous) { Add-LaneSelectionReason $reasons "HOST_INPUT_AMBIGUOUS" }
      $operatorCaptured = ConvertTo-LaneInstant $operator.capturedAt "judgment.operator.capturedAt"
      $operatorValidUntil = ConvertTo-LaneInstant $operator.validUntil "judgment.operator.validUntil"
      if ($operatorCaptured -gt $selectionAt -or $operatorValidUntil -lt $selectionAt) {
        Add-LaneSelectionReason $reasons "OPERATOR_RECORD_EXPIRED"
      }
      if ([string]$operator.revision -cne [string]$operator.finalRevision) {
        Add-LaneSelectionReason $reasons "OPERATOR_RECORD_MOVED"
      }
      if ([bool]$operator.dependencyExists -ne [bool]$candidate.operatorLabel) {
        Add-LaneSelectionReason $reasons "OPERATOR_LABEL_INCONSISTENT"
      }
      if ([bool]$operator.dependencyExists -and $null -eq $operator.windowOpen) {
        Add-LaneSelectionReason $reasons "OPERATOR_RECORD_MISSING"
      }
      if (-not [bool]$operator.dependencyExists -and $null -ne $operator.windowOpen) {
        Add-LaneSelectionReason $reasons "OPERATOR_LABEL_INCONSISTENT"
      }

      $waveIndex = [array]::IndexOf($waveOrder, [string]$candidate.milestone.nodeId)
      $routeTier = 99
      if ([bool]$judgment.explicitPriority) { $routeTier = 1 }
      elseif ([bool]$judgment.launchSpine) { $routeTier = 2 }
      elseif ([string]$candidate.milestone.nodeId -ceq [string]$InputObject.executableWaveMilestoneId -and
              [bool]$judgment.milestoneExitGateSatisfied) { $routeTier = 3 }
      elseif ([bool]$judgment.gatedTrack.member -and [bool]$judgment.gatedTrack.open) { $routeTier = 4 }
      elseif ([bool]$judgment.hardeningCloseout) { $routeTier = 5 }
      $operatorEligible = -not [bool]$operator.dependencyExists -or [bool]$operator.windowOpen
      $evaluated += [ordered]@{
        candidate = [int]$candidate.number
        routeTier = $routeTier
        waveIndex = $waveIndex
        operatorEligible = $operatorEligible
        eligible = $routeTier -lt 99 -and $operatorEligible
      }
    }
  }

  # No conflict winner is examined until the complete host pass above succeeds.
  if ($reasons.Count -gt 0) {
    return New-LaneNoSelection $Receipt $InputObject $reasons
  }

  $orderingMap = @{}
  foreach ($fact in @($Receipt.orderingFacts)) { $orderingMap[[string][int]$fact.candidate] = $fact }
  $priorityMap = @{ p0 = 0; p1 = 1; p2 = 2; p3 = 3 }
  $ranked = @($evaluated | Where-Object { $_.eligible } | Sort-Object `
    @{ Expression = { [int]$_.routeTier } }, `
    @{ Expression = { [int]$_.waveIndex } }, `
    @{ Expression = {
      $fact = $orderingMap[[string][int]$_.candidate]
      if ([string]$fact.dispatchTier -ceq "ranked") { 0 } else { 1 }
    } }, `
    @{ Expression = {
      $fact = $orderingMap[[string][int]$_.candidate]
      if ($null -eq $fact.dispatchRank) { [int]::MaxValue } else { [int]$fact.dispatchRank }
    } }, `
    @{ Expression = {
      $fact = $orderingMap[[string][int]$_.candidate]
      [int]$priorityMap[[string]$fact.priority]
    } }, `
    @{ Expression = { [int]$orderingMap[[string][int]$_.candidate].topologyOrder } }, `
    @{ Expression = { [int]$_.candidate } })

  $activeConflicts = [Collections.Generic.HashSet[int]]::new()
  foreach ($edge in @($Receipt.conflictGraph.activeLaneEdges)) { [void]$activeConflicts.Add([int]$edge.candidate) }
  $pairConflicts = @{}
  foreach ($edge in @($Receipt.conflictGraph.candidateEdges)) {
    $pairConflicts["$([int]$edge.left)|$([int]$edge.right)"] = $true
    $pairConflicts["$([int]$edge.right)|$([int]$edge.left)"] = $true
  }
  $selected = [Collections.Generic.List[int]]::new()
  $serialized = @()
  foreach ($row in @($ranked)) {
    $candidateNumber = [int]$row.candidate
    if ($activeConflicts.Contains($candidateNumber)) {
      $serialized += [ordered]@{
        candidate = $candidateNumber
        yieldsTo = "active-lane"
        reasonCode = "CONFLICT_SERIALIZED"
      }
      continue
    }
    $winner = $null
    foreach ($selectedNumber in @($selected)) {
      if ($pairConflicts.ContainsKey("$candidateNumber|$selectedNumber")) {
        $winner = $selectedNumber
        break
      }
    }
    if ($null -ne $winner) {
      $serialized += [ordered]@{
        candidate = $candidateNumber
        yieldsTo = [string]$winner
        reasonCode = "CONFLICT_SERIALIZED"
      }
    } else {
      $selected.Add($candidateNumber)
    }
  }
  if ($ranked.Count -eq 0) { Add-LaneSelectionReason $reasons "NO_ELIGIBLE_CANDIDATES" }
  if ($serialized.Count -gt 0) { Add-LaneSelectionReason $reasons "CONFLICT_SERIALIZED" }

  $result = [ordered]@{
    schemaVersion = "lane-selection/v1"
    selectionId = "selection-$([string]$InputObject.receiptId)"
    receiptId = [string]$InputObject.receiptId
    cycleId = [string]$InputObject.cycleId
    generatedAt = Format-LaneInstant $InputObject.selectionAt "selectionInput.selectionAt"
    status = "selected"
    reasonCodes = @($reasons | Sort-Object)
    eligibleCandidates = @($ranked.candidate | ForEach-Object { [int]$_ })
    selectedBatch = @($selected)
    serialized = @($serialized | Sort-Object { [int]$_.candidate })
    scale = $null
    provenance = [ordered]@{
      receiptSchema = "lane-admission/v1"
      hostInputSchema = "lane-selection-input/v1"
      receiptGeneratedAt = Format-LaneInstant $Receipt.generatedAt "receipt.generatedAt"
      hostCapturedAt = Format-LaneInstant $InputObject.capturedAt "selectionInput.capturedAt"
    }
  }
  $result.scale = New-LaneScaleDecision $Receipt $result
  [void](Assert-LaneSelectionContract $result)
  return $result
}

function Assert-LaneSelectionContract([object]$Result) {
  Assert-LaneExactKeys $Result @(
    "schemaVersion","selectionId","receiptId","cycleId","generatedAt","status",
    "reasonCodes","eligibleCandidates","selectedBatch","serialized","scale","provenance"
  ) @() "selection"
  if ([string]$Result.schemaVersion -cne "lane-selection/v1") { throw "selection schema invalid" }
  Assert-LaneIdentifier $Result.selectionId "selection.selectionId"
  Assert-LaneIdentifier $Result.receiptId "selection.receiptId"
  Assert-LaneIdentifier $Result.cycleId "selection.cycleId"
  [void](ConvertTo-LaneInstant $Result.generatedAt "selection.generatedAt")
  if ([string]$Result.status -cnotin @("selected","no-selection")) { throw "selection.status invalid" }
  foreach ($reason in @($Result.reasonCodes)) {
    if ([string]$reason -cnotin $script:LaneSelectionReasonCodes) { throw "selection reason invalid" }
  }
  Assert-LaneUnique @($Result.reasonCodes) "selection.reasonCodes"
  foreach ($number in @($Result.eligibleCandidates) + @($Result.selectedBatch)) {
    Assert-LaneCount $number "selection candidate number"
  }
  Assert-LaneUnique @($Result.eligibleCandidates) "selection.eligibleCandidates"
  Assert-LaneUnique @($Result.selectedBatch) "selection.selectedBatch"
  foreach ($number in @($Result.selectedBatch)) {
    if ([string][int]$number -cnotin @($Result.eligibleCandidates | ForEach-Object { [string][int]$_ })) {
      throw "selected batch contains an ineligible candidate"
    }
  }
  if ([string]$Result.status -ceq "no-selection" -and
      (@($Result.eligibleCandidates).Count -gt 0 -or @($Result.selectedBatch).Count -gt 0 -or
       @($Result.serialized).Count -gt 0)) {
    throw "no-selection output contains a conflict decision"
  }
  foreach ($row in @($Result.serialized)) {
    Assert-LaneExactKeys $row @("candidate","yieldsTo","reasonCode") @() "selection.serialized[]"
    Assert-LaneCount $row.candidate "selection.serialized[].candidate"
    Assert-LaneIdentifier ([string]$row.yieldsTo) "selection.serialized[].yieldsTo"
    if ([string]$row.reasonCode -cne "CONFLICT_SERIALIZED") { throw "serialized reason invalid" }
  }
  Assert-LaneUnique @($Result.serialized.candidate) "selection.serialized candidate identities"
  Assert-LaneExactKeys $Result.scale @(
    "action","reasonCodes","gates","hostCapacityInputs","currentPool","active","idle",
    "authorizedMax","recommendedLaneCount"
  ) @() "selection.scale"
  if ([string]$Result.scale.action -cnotin @("hold","backfill","add")) { throw "scale action invalid" }
  foreach ($reason in @($Result.scale.reasonCodes)) {
    if ([string]$reason -cnotin $script:LaneScaleReasonCodes) { throw "scale reason invalid" }
  }
  Assert-LaneUnique @($Result.scale.reasonCodes) "selection.scale.reasonCodes"
  Assert-LaneExactKeys $Result.scale.gates @(
    "runnableReadyDisjointWork","queueAndDeployHealthy","hostCapacitySafe","ownershipSafe"
  ) @() "selection.scale.gates"
  Assert-LaneExactKeys $Result.scale.hostCapacityInputs @(
    "memorySafe","heavyVerifierSafe"
  ) @() "selection.scale.hostCapacityInputs"
  foreach ($field in @(
    "runnableReadyDisjointWork","queueAndDeployHealthy","hostCapacitySafe","ownershipSafe"
  )) {
    if ((Get-LaneProperty $Result.scale.gates $field) -isnot [bool]) {
      throw "selection.scale.gates.$field must be boolean"
    }
  }
  foreach ($field in @("memorySafe","heavyVerifierSafe")) {
    $value = Get-LaneProperty $Result.scale.hostCapacityInputs $field
    if ($null -ne $value -and $value -isnot [bool]) { throw "selection scale host input invalid" }
  }
  foreach ($field in @("currentPool","active","idle","authorizedMax","recommendedLaneCount")) {
    Assert-LaneCount (Get-LaneProperty $Result.scale $field) "selection.scale.$field"
  }
  Assert-LaneExactKeys $Result.provenance @(
    "receiptSchema","hostInputSchema","receiptGeneratedAt","hostCapturedAt"
  ) @() "selection.provenance"
  if ([string]$Result.provenance.receiptSchema -cne "lane-admission/v1" -or
      [string]$Result.provenance.hostInputSchema -cne "lane-selection-input/v1") {
    throw "selection provenance schema invalid"
  }
  [void](ConvertTo-LaneInstant $Result.provenance.receiptGeneratedAt "selection.provenance.receiptGeneratedAt")
  [void](ConvertTo-LaneInstant $Result.provenance.hostCapturedAt "selection.provenance.hostCapturedAt")
  return $true
}

if ($MyInvocation.InvocationName -ne ".") {
  if (($ReceiptPath -and $ReceiptJson) -or (-not $ReceiptPath -and -not $ReceiptJson)) {
    throw "supply exactly one of -ReceiptPath or -ReceiptJson"
  }
  if (($InputPath -and $InputJson) -or (-not $InputPath -and -not $InputJson)) {
    throw "supply exactly one of -InputPath or -InputJson"
  }
  $receiptText = if ($ReceiptPath) { Get-Content -LiteralPath $ReceiptPath -Raw } else { $ReceiptJson }
  $inputText = if ($InputPath) { Get-Content -LiteralPath $InputPath -Raw } else { $InputJson }
  $receipt = $receiptText | ConvertFrom-Json
  $inputObject = $inputText | ConvertFrom-Json
  $result = ConvertTo-LaneSelection $receipt $inputObject
  if ($Compact) { $result | ConvertTo-Json -Depth 100 -Compress }
  else { $result | ConvertTo-Json -Depth 100 }
}
