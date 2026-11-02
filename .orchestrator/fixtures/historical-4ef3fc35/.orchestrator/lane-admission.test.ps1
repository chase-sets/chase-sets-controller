$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lane-admission.ps1")

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

function Invoke-PublicAdmission([object]$InputObject) {
  $temporary = [IO.Path]::Combine([IO.Path]::GetTempPath(), "lane-admission-$([guid]::NewGuid().ToString('N')).json")
  try {
    [IO.File]::WriteAllText(
      $temporary,
      ($InputObject | ConvertTo-Json -Depth 100),
      [Text.UTF8Encoding]::new($false)
    )
    $jsonLines = @(& (Join-Path $PSScriptRoot "lane-admission.ps1") -InputPath $temporary -Compact)
    return ($jsonLines -join [Environment]::NewLine) | ConvertFrom-Json
  } finally {
    if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
  }
}

function Set-ConflictFixturePaths([object]$Fixture, [string]$Left, [string]$Right) {
  $Fixture.candidates[0].footprint.declared = @($Left)
  $Fixture.candidates[1].footprint.declared = @($Right)
  $Fixture.candidates[2].footprint.declared = @("isolated/c")
  $Fixture.candidates[3].footprint.declared = @("isolated/d")
}

function Test-ReceiptEdge([object]$Receipt, [int]$Left = 101, [int]$Right = 102) {
  return @($Receipt.conflictGraph.candidateEdges | Where-Object {
    ([int]$_.left -eq $Left -and [int]$_.right -eq $Right) -or
    ([int]$_.left -eq $Right -and [int]$_.right -eq $Left)
  }).Count -eq 1
}

function Assert-RecursivelyClosedSchema([object]$Node, [string]$At = '$') {
  if ($null -eq $Node -or $Node -is [string] -or $Node -is [ValueType]) { return }
  $keys = @(Get-LaneObjectKeys $Node)
  if ("type" -cin $keys) {
    $types = @($Node.type)
    if ("object" -cin $types) {
      Assert-True ("additionalProperties" -cin $keys) "$At object lacks additionalProperties"
      Assert-True ($Node.additionalProperties -eq $false) "$At object is not recursively closed"
    }
  }
  if ($Node -is [Collections.IEnumerable] -and $Node -isnot [Collections.IDictionary] -and
      $Node -isnot [pscustomobject]) {
    $index = 0
    foreach ($item in $Node) {
      Assert-RecursivelyClosedSchema $item "$At[$index]"
      $index++
    }
    return
  }
  foreach ($key in $keys) {
    Assert-RecursivelyClosedSchema (Get-LaneProperty $Node $key) "$At.$key"
  }
}

Invoke-Test "ac01-closed-three-schema-contract" {
  $schemaNames = @(
    "lane-admission-collected-input-v1.schema.json",
    "lane-admission-v1.schema.json",
    "lane-selection-input-v1.schema.json",
    "lane-selection-v1.schema.json"
  )
  Assert-Equal $schemaNames.Count 4 "N3 requires four formalized contracts"
  foreach ($schemaName in $schemaNames) {
    $schema = Get-Content -LiteralPath (Join-Path $PSScriptRoot $schemaName) -Raw | ConvertFrom-Json
    Assert-RecursivelyClosedSchema $schema $schemaName
  }

  $fixture = Read-AdmissionFixture
  $receipt = Invoke-PublicAdmission $fixture
  Assert-Equal $receipt.schemaVersion "lane-admission/v1" "public receipt schema"
  Assert-Equal $receipt.status "complete" "candidate green receipt"
  if (Get-Command Test-Json -ErrorAction SilentlyContinue) {
    $snapshotJson = $fixture | ConvertTo-Json -Depth 100
    $receiptJson = $receipt | ConvertTo-Json -Depth 100
    Assert-True ($snapshotJson | Test-Json -SchemaFile (Join-Path $PSScriptRoot "lane-admission-collected-input-v1.schema.json")) "collected input JSON schema"
    Assert-True ($receiptJson | Test-Json -SchemaFile (Join-Path $PSScriptRoot "lane-admission-v1.schema.json")) "receipt JSON schema"
  }

  $nestedMutant = Copy-JsonObject $fixture
  $nestedMutant.candidates[0].milestone | Add-Member -NotePropertyName title -NotePropertyValue "Wave prose"
  Assert-Rejected "mutant-lax-nested-schema" {
    [void](ConvertTo-LaneAdmission $nestedMutant)
  } "unknown property"

  $batchMutant = Copy-JsonObject $receipt
  $batchMutant | Add-Member -NotePropertyName selectedBatch -NotePropertyValue @(101)
  Assert-Rejected "mutant-machine-receipt-selects-batch" {
    [void](Assert-LaneAdmissionContract $batchMutant)
  } "unknown property"

  $hostClaimMutant = Copy-JsonObject $receipt
  $hostClaimMutant.structurallyEligibleCandidates[0] |
    Add-Member -NotePropertyName explicitPriority -NotePropertyValue $true
  Assert-Rejected "mutant-receipt-claims-host-totality" {
    [void](Assert-LaneAdmissionContract $hostClaimMutant)
  } "unknown property"

  $dateOnly = Copy-JsonObject $fixture
  $dateOnly.cycle.collectedAt = "2026-07-31"
  Assert-Rejected "mutant-date-only-instant" {
    [void](ConvertTo-LaneAdmission $dateOnly)
  } "timezone-bearing"

  $outOfRange = Copy-JsonObject $fixture
  $outOfRange.authorityRows[0].coverage.total = 1000001
  Assert-Rejected "mutant-out-of-range-count" {
    [void](ConvertTo-LaneAdmission $outOfRange)
  } "0 through 1000000"
}

Invoke-Test "ac01-receipt-never-selects" {
  $receipt = Invoke-PublicAdmission (Read-AdmissionFixture)
  $keys = @(Get-LaneObjectKeys $receipt)
  foreach ($forbidden in @(
    "selected","selectedBatch","admitted","admittedBatch","machineAdmissibleBatch",
    "runnableFrontier","finalChoice"
  )) {
    Assert-True ($forbidden -cnotin $keys) "receipt exposed forbidden final field $forbidden"
  }
  Write-Host "  mutant-red: mutant-machine-receipt-selects-batch"
}

Invoke-Test "ac02-complete-candidate-and-conflict-receipt" {
  $receipt = Invoke-PublicAdmission (Read-AdmissionFixture)
  Assert-Equal @($receipt.structurallyEligibleCandidates).Count 4 "all P0-P3 candidates preserved"
  Assert-Sequence @($receipt.structurallyEligibleCandidates.priority | Sort-Object) @("p0","p1","p2","p3") "priority is not membership cutoff"
  Assert-True (Test-ReceiptEdge $receipt) "overlapping candidates must remain with a complete edge"
  Assert-True (@($receipt.structurallyEligibleCandidates.number) -contains 101) "left candidate preserved"
  Assert-True (@($receipt.structurallyEligibleCandidates.number) -contains 102) "right candidate preserved"

  $mutantGreedyCount = @($receipt.structurallyEligibleCandidates).Count - 1
  Assert-True ($mutantGreedyCount -ne @($receipt.structurallyEligibleCandidates).Count) "mutant must be discriminated"
  Write-Host "  mutant-red: mutant-greedy-machine-batch"

  $missingEdge = Copy-JsonObject $receipt
  $missingEdge.conflictGraph.candidateEdges = @($missingEdge.conflictGraph.candidateEdges |
    Where-Object { -not ($_.left -eq 101 -and $_.right -eq 102) })
  Assert-Rejected "mutant-omits-candidate-conflict-edge" {
    [void](Assert-LaneAdmissionContract $missingEdge)
  } "conflict graph is incomplete"
}

Invoke-Test "ac07-global-vs-candidate-unknown" {
  $green = Read-AdmissionFixture
  Assert-Equal (Invoke-PublicAdmission $green).status "complete" "candidate green"

  $missing = Copy-JsonObject $green
  $missing.authorityRows = @($missing.authorityRows | Where-Object { $_.set -cne "labels" })
  $missingReceipt = ConvertTo-LaneAdmission $missing
  Assert-Equal $missingReceipt.status "closed" "M1 missing global row closes receipt"
  Assert-True (@($missingReceipt.reasonCodes) -contains "GLOBAL_AUTHORITY_MISSING") "M1 clause"
  Write-Host "  mutant-red: mutant-missing-row-is-complete"

  $duplicate = Copy-JsonObject $green
  $duplicate.authorityRows = @($duplicate.authorityRows) + @((Copy-JsonObject $duplicate.authorityRows[1]))
  $duplicateReceipt = ConvertTo-LaneAdmission $duplicate
  Assert-Equal $duplicateReceipt.status "closed" "M2 duplicate global row closes receipt"
  Assert-True (@($duplicateReceipt.reasonCodes) -contains "GLOBAL_AUTHORITY_DUPLICATE") "M2 clause"
  Write-Host "  mutant-red: mutant-first-global-row-wins"

  $moved = Copy-JsonObject $green
  $moved.authorityRows[0].coverage.finalRevision = "authority-candidates-r2"
  $movedReceipt = ConvertTo-LaneAdmission $moved
  Assert-Equal $movedReceipt.status "closed" "M4 moving global authority closes receipt"
  Assert-True (@($movedReceipt.reasonCodes) -contains "GLOBAL_AUTHORITY_MOVED") "M4 clause"
  Write-Host "  mutant-red: mutant-ignore-final-rebind"

  $cap = Copy-JsonObject $green
  $cap.authorityRows[0].coverage.providerCap = 3
  $cap.authorityRows[0].coverage.hasNextPage = $true
  $capReceipt = ConvertTo-LaneAdmission $cap
  Assert-Equal $capReceipt.status "closed" "unsafe continuation is bounded unknown"
  Assert-True (@($capReceipt.reasonCodes) -contains "GLOBAL_AUTHORITY_CAP_MISMATCH") "cap mismatch clause"
  Write-Host "  mutant-red: mutant-cap-container-means-complete"

  $presentUnknown = Copy-JsonObject $green
  $presentUnknown.authorityRows[1].coverage.status = "unknown"
  $presentUnknown.authorityRows[1].coverage.collected = 0
  $presentUnknown.authorityRows[1].coverage.unexamined = 12
  $unknownReceipt = ConvertTo-LaneAdmission $presentUnknown
  Assert-Equal $unknownReceipt.status "closed" "M8 aggregate state is not container presence"
  Assert-True (@($unknownReceipt.reasonCodes) -contains "GLOBAL_AUTHORITY_INCOMPLETE") "M8 clause"
  Write-Host "  mutant-red: mutant-present-container-is-complete"

  $countMismatch = Copy-JsonObject $green
  $countMismatch.authorityRows[0].coverage.collected = 3
  $countMismatch.authorityRows[0].coverage.total = 3
  $countMismatchReceipt = ConvertTo-LaneAdmission $countMismatch
  Assert-Equal $countMismatchReceipt.status "closed" "aggregate count must reconcile to candidate rows"
  Assert-True (@($countMismatchReceipt.reasonCodes) -contains "GLOBAL_AUTHORITY_INCOMPLETE") "aggregate count reconciliation clause"

  $candidateUnknown = Copy-JsonObject $green
  $candidateUnknown.candidates[2].authority.coverage.status = "unknown"
  $candidateUnknown.candidates[2].authority.coverage.collected = 0
  $candidateUnknown.candidates[2].authority.coverage.unexamined = 1
  $candidateReceipt = ConvertTo-LaneAdmission $candidateUnknown
  Assert-Equal $candidateReceipt.status "complete" "isolatable candidate defect keeps global receipt open"
  Assert-Equal @($candidateReceipt.structurallyEligibleCandidates).Count 3 "only defective candidate excluded"
  Assert-True (@($candidateReceipt.exclusions | Where-Object { $_.candidate -eq 103 }).reasonCodes -contains "CANDIDATE_AUTHORITY_UNKNOWN") "candidate blast radius clause"

  $nonIsolated = Copy-JsonObject $candidateUnknown
  $nonIsolated.candidates[2].authority.isolated = $false
  $nonIsolatedReceipt = ConvertTo-LaneAdmission $nonIsolated
  Assert-Equal $nonIsolatedReceipt.status "closed" "unisolated candidate uncertainty is global"
  Assert-True (@($nonIsolatedReceipt.reasonCodes) -contains "GLOBAL_AUTHORITY_INCOMPLETE") "global blast radius clause"

  $malformed = Copy-JsonObject $green
  $malformed.authorityRows[0].coverage.total = "four"
  Assert-Rejected "M3-mutant-malformed-count-coerces" {
    [void](ConvertTo-LaneAdmission $malformed)
  } "integer"
}

Invoke-Test "ac08-bidirectional-recursive-entrypoint" {
  $rows = @(
    @("a/b/**", "a/b"),
    @("a/b", "a/b/**"),
    @("a/b/**", "a/b/c"),
    @("a/b/c", "a/b/**"),
    @("a/b/**", "a"),
    @("a", "a/b/**"),
    @(".orchestrator/controller-skills/**", ".orchestrator"),
    @(".orchestrator", ".orchestrator/controller-skills/**"),
    @("packages/ui/src/**", "packages"),
    @("packages", "packages/ui/src/**")
  )
  foreach ($row in $rows) {
    $fixture = Read-AdmissionFixture
    Set-ConflictFixturePaths $fixture $row[0] $row[1]
    $receipt = Invoke-PublicAdmission $fixture
    Assert-True (Test-ReceiptEdge $receipt) "public entrypoint missed '$($row[0])' vs '$($row[1])'"
  }

  function Test-MutantOneDirectional([string]$Left, [string]$Right) {
    $normalizedLeft = (ConvertTo-LaneAdmissionPath $Left)
    $normalizedRight = (ConvertTo-LaneAdmissionPath $Right)
    if (-not $normalizedLeft.recursive) { return $false }
    $base = @($normalizedLeft.segments)[0..($normalizedLeft.segments.Count - 2)] -join "/"
    return $normalizedRight.value -ceq $base -or $normalizedRight.value.StartsWith("$base/")
  }
  Assert-True (-not (Test-MutantOneDirectional "packages" "packages/ui/src/**")) "mutant setup invalid"
  Write-Host "  mutant-red: mutant-one-directional-recursive-overlap"

  $activeFixture = Read-AdmissionFixture
  $activeFixture.activeLanes = @([pscustomobject]@{
    owner = "lane-active"
    revision = "lane-active-r1"
    finalRevision = "lane-active-r1"
    declaredFootprint = @("packages")
    observedFootprint = @()
    complete = $true
  })
  $activeCoverage = @($activeFixture.authorityRows | Where-Object { $_.set -ceq "active-lanes" })[0].coverage
  $activeCoverage.collected = 1
  $activeCoverage.total = 1
  $activeReceipt = Invoke-PublicAdmission $activeFixture
  Assert-True (@($activeReceipt.conflictGraph.activeLaneEdges | Where-Object { $_.candidate -eq 101 }).Count -eq 1) "candidate/active recursive ancestor conflict missing"
  $missingActiveEdge = Copy-JsonObject $activeReceipt
  $missingActiveEdge.conflictGraph.activeLaneEdges = @($missingActiveEdge.conflictGraph.activeLaneEdges |
    Where-Object { $_.candidate -ne 101 })
  Assert-Rejected "mutant-omits-active-lane-conflict-edge" {
    [void](Assert-LaneAdmissionContract $missingActiveEdge)
  } "active-lane conflict graph is incomplete"
}

Invoke-Test "ac09-overlap-negative-and-normalization-matrix" {
  $matrix = @(
    @("a/b", "a/c", $false),
    @("packages/ui", "packages/uikit", $false),
    @("src/*.ts", "src/a.ts", $true),
    @("src/*.ts", "src/a/b.ts", $false),
    @(".orchestrator/**", "orchestrator", $false),
    @("./.orchestrator/**", ".orchestrator", $true),
    @("Dotted.Root/file", "dotted.root", $true)
  )
  foreach ($row in $matrix) {
    $fixture = Read-AdmissionFixture
    Set-ConflictFixturePaths $fixture $row[0] $row[1]
    $receipt = Invoke-PublicAdmission $fixture
    Assert-Equal (Test-ReceiptEdge $receipt) ([bool]$row[2]) "public overlap '$($row[0])' vs '$($row[1])'"
  }

  foreach ($badPath in @("", "/absolute", "C:\drive", "a/../b", "a/./b", "a//b", "a/[x]")) {
    $fixture = Read-AdmissionFixture
    $fixture.candidates[0].footprint.declared = @($badPath)
    $receipt = Invoke-PublicAdmission $fixture
    Assert-Equal $receipt.status "complete" "malformed candidate path must be isolatable"
    Assert-True (@($receipt.exclusions | Where-Object { $_.candidate -eq 101 }).reasonCodes -contains "CANDIDATE_PATH_UNKNOWN") "malformed path reason"
  }

  $official = (ConvertTo-LaneAdmissionPath ".orchestrator").value
  $trimStartMutant = ".orchestrator".TrimStart("./")
  Assert-Equal $official ".orchestrator" "leading dotted root preserved"
  Assert-Equal $trimStartMutant "orchestrator" "TrimStart mutant must reproduce defect"
  Write-Host "  mutant-red: mutant-salvage-trimstart"
}

Invoke-Test "M6-no-prose-or-native-wave-inference" {
  $fixture = Read-AdmissionFixture
  $fixture.candidates[0].milestone |
    Add-Member -NotePropertyName dueDate -NotePropertyValue "2026-08-01T00:00:00Z"
  Assert-Rejected "mutant-title-or-due-date-enters-machine-authority" {
    [void](ConvertTo-LaneAdmission $fixture)
  } "unknown property"
}

Invoke-Test "M8-state-not-container-completeness" {
  $fixture = Read-AdmissionFixture
  $fixture.authorityRows[4].coverage.status = "unknown"
  $fixture.authorityRows[4].coverage.revisionStable = $false
  $receipt = ConvertTo-LaneAdmission $fixture
  Assert-Equal $receipt.status "closed" "present draft authority cannot be positive"
  Assert-True (@($receipt.reasonCodes) -contains "GLOBAL_AUTHORITY_INCOMPLETE") "aggregate completeness clause"
  Write-Host "  mutant-red: mutant-presence-alone-complete"
}

Invoke-Test "M9-receipt-not-final" {
  $receipt = Invoke-PublicAdmission (Read-AdmissionFixture)
  Assert-Equal $receipt.status "complete" "positive machine receipt"
  Assert-True ("selectedBatch" -cnotin @(Get-LaneObjectKeys $receipt)) "receipt cannot select"
  $mutant = Copy-JsonObject $receipt
  $mutant | Add-Member -NotePropertyName machineAdmissibleBatch -NotePropertyValue @(101)
  Assert-Rejected "mutant-machine-receipt-selects-batch" {
    [void](Assert-LaneAdmissionContract $mutant)
  } "unknown property"
}

Invoke-Test "ac11-discrimination-matrix" {
  $schema = Get-Content -LiteralPath (Join-Path $PSScriptRoot "lane-admission-v1.schema.json") -Raw |
    ConvertFrom-Json
  $schemaReasons = @($schema.'$defs'.admissionReasons.items.enum)
  Assert-Sequence @($schemaReasons | Sort-Object) @($script:LaneAdmissionReasonCodes | Sort-Object) "admission reason producer/consumer enum parity"
  $source = Get-Content -LiteralPath (Join-Path $PSScriptRoot "lane-admission.ps1") -Raw
  foreach ($reason in $script:LaneAdmissionReasonCodes) {
    $occurrences = ([regex]::Matches($source, [regex]::Escape($reason))).Count
    Assert-True ($occurrences -ge 2) "reason '$reason' lacks declaration plus producer"
  }
  Assert-True ($source -match 'Test-LaneAdmissionPathOverlap') "public conflict producer missing"
  Assert-True ($source -match 'conflictGraph') "public conflict consumer missing"
  Write-Host "  candidate-green: all non-governing fixture inputs frozen"
  Write-Host "  mutant-red: named controls ac01-ac09/M1-M9 all rejected"
}

if ($script:Failed -gt 0) {
  throw "lane-admission tests failed: $($script:Failed) failed, $($script:Passed) passed"
}
Write-Host "lane-admission tests passed: $($script:Passed)"
