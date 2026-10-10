[CmdletBinding()]
param(
  [ValidateSet("All", "BatteryArtifact")]
  [string]$Scenario = "All",

  [switch]$RequireArtifactDirectoryInitiallyAbsent,

  [string]$BatteryResultPath = ""
)

$ErrorActionPreference = "Stop"
$controllerRoot = Split-Path -Parent $PSScriptRoot
$aggregator = Join-Path $PSScriptRoot "fail-closed-guard-evidence-aggregate.ps1"
$checker = Join-Path $PSScriptRoot "fail-closed-guard-evidence.ps1"
$artifactRoot = [IO.Path]::GetFullPath((Join-Path $controllerRoot ".orchestrator/artifacts"))
$artifactDirectoryInitiallyAbsent = -not (Test-Path -LiteralPath $artifactRoot)
if ($RequireArtifactDirectoryInitiallyAbsent -and -not $artifactDirectoryInitiallyAbsent) {
  throw "ASSERTION FAILED: clean-worktree control requires an initially absent artifact directory"
}
New-Item -ItemType Directory -Path $artifactRoot -Force | Out-Null
if (-not (Test-Path -LiteralPath $artifactRoot -PathType Container)) {
  throw "ASSERTION FAILED: aggregate test setup did not create the exact artifact directory"
}
if ($artifactDirectoryInitiallyAbsent) {
  Write-Output "CONTROL clean-worktree-no-artifact-directory initial=absent setup-created=true"
} else {
  Write-Output "CONTROL artifact-directory-setup initial=present setup-created=true"
}
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("fail-closed-aggregate-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $testRoot | Out-Null

$checkerRows = @(
  @("C01-RECEIPT-MISSING", "bypass-receipt-missing"),
  @("C02-RECEIPT-UNREADABLE", "bypass-receipt-unreadable"),
  @("C03-RECEIPT-EMPTY", "bypass-receipt-empty"),
  @("C04-UTF8-INVALID", "bypass-utf8-validation"),
  @("C05-JSON-MALFORMED", "bypass-json-parse"),
  @("C06-JSON-DUPLICATE-MEMBER", "bypass-duplicate-member-scan"),
  @("C07-SCHEMA-VERSION", "bypass-schema-version"),
  @("C08-UNKNOWN-ROOT", "bypass-root-closure"),
  @("C09-UNKNOWN-NESTED", "bypass-nested-closure"),
  @("C10-WRONG-TYPE", "bypass-type-check"),
  @("C11-FILE-SIZE-BOUND", "remove-file-size-bound"),
  @("C12-DEPTH-BOUND", "remove-depth-bound"),
  @("C13-CLAIM-COUNT-BOUND", "remove-claim-count-bound"),
  @("C14-OBJECT-MEMBER-BOUND", "remove-object-member-bound"),
  @("C15-SHORT-STRING-BOUND", "remove-short-string-bound"),
  @("C16-OBSERVATION-BOUND", "remove-observation-bound"),
  @("C17-NUMBER-CANONICAL", "bypass-number-token-check"),
  @("C18-CLAIMS-NONEMPTY", "allow-empty-claims"),
  @("C19-GUARD-ID-REQUIRED", "remove-guard-id-required"),
  @("C20-GUARD-ID-UNIQUE", "remove-guard-id-unique"),
  @("C21-MUTANT-ID-REQUIRED", "remove-mutant-id-required"),
  @("C22-MUTANT-ID-UNIQUE", "remove-mutant-id-unique"),
  @("C23-GOVERNING-POINTER", "remove-governing-pointer-check"),
  @("C25-ONE-LEAF-DIFF", "allow-multiple-input-diffs"),
  @("C26-PRESERVED-PROJECTION", "remove-preserved-projection-equality"),
  @("C27-CANDIDATE-EXECUTED", "allow-unexecuted-candidate"),
  @("C28-MUTANT-EXECUTED", "allow-unexecuted-mutant"),
  @("C29-CANDIDATE-EXPECTATION-RESULT", "ignore-candidate-expectation-result-mismatch"),
  @("C30-MUTANT-EXPECTATION-RESULT", "ignore-mutant-expectation-result-mismatch"),
  @("C31-CANDIDATE-GREEN", "allow-candidate-nonpass"),
  @("C32-MUTANT-RED", "allow-mutant-nonfail"),
  @("C34-SIGNATURE-REQUIRED", "remove-failure-signature-required"),
  @("C35-SIGNATURE-MATCH", "ignore-failure-signature-mismatch"),
  @("C36-ENUM-CLOSED", "allow-unknown-enum")
)
$productionRows = @(
  @("LP-B1-B2-EVENT-ORDER", "B1-B2"),
  @("LP-B3-EXACT-HEAD", "B3"),
  @("LP-B3-CLEAR-ANY-OPEN", "B3-clear-any-open"),
  @("LP-D2-RUN-IDENTITY", "D2"),
  @("LP-D3-COMMIT-BOUND", "D3"),
  @("LP-D4-WORKFLOW-IDENTITY", "D4"),
  @("LP-D5-OWNING-JOB", "D5"),
  @("LP-D6-JOB-CONCLUSION", "D6"),
  @("LP-D7-JOB-TAXONOMY", "D7"),
  @("LP-D8-RESOLVER-ONLY", "D8"),
  @("LP-D10-REPORT-ONLY", "D10"),
  @("LP-D15-RUN-LIST-EXIT", "D15"),
  @("LP-F1-EXECUTED-UNRECOGNIZED", "F1-executed-unrecognized"),
  @("LP-ZERO-STEPS", "zero-steps"),
  @("LP-EXECUTED-RED-DEMOTED", "executed-red-demoted"),
  @("LP-BREAKER-REPAIR-FRONTIER-DEFAULT-REFUSE", "breaker-repair-frontier-default-refuse")
)
$batteryRows = @(
  @("BATTERY-CHECKER-REQUIRED", "omit-direct-fail-closed-evidence-validation"),
  @("BATTERY-6254-DISCRIMINATOR-REQUIRED", "omit-issue-6254-discriminator")
)

function Assert-AggregateTest([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Copy-Value($Value) {
  if ($Value -is [Collections.IDictionary]) {
    $copy = [ordered]@{}
    foreach ($key in $Value.Keys) { $copy[$key] = Copy-Value $Value[$key] }
    return $copy
  }
  if ($Value -is [Array]) { return ,@($Value | ForEach-Object { Copy-Value $_ }) }
  return $Value
}

function Insert-Pointer($Preserved, [string]$Pointer, $Value) {
  $copy = Copy-Value $Preserved
  $segments = @($Pointer.Substring(1).Split("/"))
  $cursor = $copy
  for ($index = 0; $index -lt $segments.Count; $index++) {
    if ($index -eq $segments.Count - 1) {
      $cursor[$segments[$index]] = $Value
    } else {
      $cursor[$segments[$index]] = [ordered]@{}
      $cursor = $cursor[$segments[$index]]
    }
  }
  return $copy
}

function Get-TestCanonical($Value){
  if($null-eq$Value){return'n'};if($Value-is[bool]){return $(if($Value){'b:true'}else{'b:false'})};if($Value-is[int]-or$Value-is[long]){return "i:$Value"};if($Value-is[string]){return "s:$([System.Text.Json.JsonSerializer]::Serialize([string]$Value,[System.Text.Json.JsonSerializerOptions]::new()))"}
  if($Value-is[Collections.IDictionary]){$keys=[string[]]@($Value.Keys);[Array]::Sort($keys,[StringComparer]::Ordinal);$parts=foreach($k in $keys){"$([System.Text.Json.JsonSerializer]::Serialize($k,[System.Text.Json.JsonSerializerOptions]::new()))=$(Get-TestCanonical $Value[$k])"};return "o:{$($parts-join';')}"};if($Value-is[Array]){$parts=foreach($v in $Value){Get-TestCanonical $v};return "a:[$($parts-join';')]"};"x:$Value"
}
function Get-TestSha([string]$Text){([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($Text)))).ToLowerInvariant()}

function New-Claim([string]$SuiteId, [string]$GuardId, [string]$MutantId,[string]$Head) {
  $prefix = switch ($SuiteId) {
    "checker" { "checkerGuards" }
    "issue-6254-production" { "productionGuards" }
    "release-battery" { "batteryGuards" }
  }
  $leaf = if ($GuardId -ceq "BATTERY-CHECKER-REQUIRED") { "directInvocationEnabled" } elseif (
    $SuiteId -ceq "issue-6254-production"
  ) { "clauseEnabled" } else { "enabled" }
  $pointer = "/$prefix/$GuardId/$leaf"
  $preserved = [ordered]@{
    controllerRoot = "."
    fixture = "$SuiteId-fixture"
    parallelism = 1
  }
  $signature = switch ($GuardId) {
    "LP-D15-RUN-LIST-EXIT" {
      "ASSERTION FAILED: a nonzero gh run list exit with valid runs JSON is terminal unreadable with no jobs query"
    }
    "BATTERY-CHECKER-REQUIRED" { "BATTERY_DIRECT_CHECKER_VALIDATION_OMITTED" }
    "BATTERY-6254-DISCRIMINATOR-REQUIRED" { "BATTERY_DISCRIMINATOR_OMITTED:issue-6254" }
    default { "MUTANT_KILLED:$MutantId" }
  }
  $claim=[ordered]@{
    guardId = $GuardId
    governingVariable = [ordered]@{ pointer = $pointer; candidateValue = $true; bypassValue = $false }
    preservedVariables = $preserved
    candidate = [ordered]@{
      inputs = Insert-Pointer $preserved $pointer $true
      executed = $true
      expectation = [ordered]@{ testOutcome = "pass"; observation = "PASS"; failureSignature = $null }
      result = [ordered]@{ testOutcome = "pass"; observation = "PASS"; failureSignature = $null }
    }
    bypassMutant = [ordered]@{
      id = $MutantId
      change = "omit $MutantId"
      inputs = Insert-Pointer $preserved $pointer $false
      executed = $true
      expectation = [ordered]@{ testOutcome = "fail"; observation = "FAIL"; failureSignature = $signature }
      result = [ordered]@{ testOutcome = "fail"; observation = "FAIL"; failureSignature = $signature }
    }
    failureSignature = $signature
  }
  return $claim
}

function New-Suite(
  [string]$SuiteId,
  [object[]]$Rows,
  [string]$Head,
  [string]$RunId
) {
  $claims = foreach ($row in $Rows) { New-Claim $SuiteId $row[0] $row[1] $Head }
  return [ordered]@{
    schemaVersion = "fail-closed-guard-suite-result/v1"
    subject = [ordered]@{ controllerHead = $Head }
    suite = [ordered]@{ id = $SuiteId; expectedClaimCount = $Rows.Count }
    execution = [ordered]@{ runId = $RunId; executed = $true; outcome = "pass" }
    claims = @($claims)
  }
}

function Write-Json($Value, [string]$Path) {
  [IO.File]::WriteAllText(
    $Path,
    ($Value | ConvertTo-Json -Depth 100),
    [Text.UTF8Encoding]::new($false)
  )
}

function Add-ScaleEvidence($Suite, [long]$StartingOrdinal) {
  $copy = Copy-Value $Suite
  for ($index = 0; $index -lt @($copy.claims).Count; $index++) {
    $claim = $copy.claims[$index]
    $ordinal = $StartingOrdinal + $index
    $scaleEvidence = [ordered]@{
      claimOrdinal = $ordinal
      active = ($ordinal % 2 -eq 0)
      labels = @("aggregate-scale", [string]$claim.guardId, [string]$claim.bypassMutant.id)
      optional = $null
      payload = "s" * 4000
      secondaryPayload = "t" * 1800
    }
    $claim.preservedVariables["scaleEvidence"] = Copy-Value $scaleEvidence
    $claim.candidate.inputs["scaleEvidence"] = Copy-Value $scaleEvidence
    $claim.bypassMutant.inputs["scaleEvidence"] = Copy-Value $scaleEvidence
  }
  return $copy
}

function Invoke-Aggregator(
  [string]$CheckerPath,
  [string]$ProductionPath,
  [string]$BatteryPath,
  [string]$Head,
  [string]$Out
) {
  $output = & pwsh -NoProfile -NonInteractive -File $aggregator `
    -CheckerResultPath $CheckerPath -ProductionResultPath $ProductionPath `
    -BatteryResultPath $BatteryPath -ExpectedControllerHead $Head -ReceiptOut $Out 2>&1 |
    Out-String
  return [pscustomobject]@{ exitCode = $LASTEXITCODE; output = $output.Trim() }
}

function Assert-Control(
  [string]$Name,
  [scriptblock]$Arrange,
  [string]$ExpectedCode,
  [string]$Head,
  [bool]$PriorReceipt = $true
) {
  $checkerPath = Join-Path $testRoot "$Name-checker.json"
  $productionPath = Join-Path $testRoot "$Name-production.json"
  $batteryPath = Join-Path $testRoot "$Name-battery.json"
  $out = Join-Path $controllerRoot ".orchestrator/artifacts/aggregate-test-$Name.json"
  if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }
  if ($PriorReceipt) {
    [IO.File]::WriteAllText($out, "prior-valid-receipt-sentinel", [Text.UTF8Encoding]::new($false))
  }
  $priorHash = if (Test-Path -LiteralPath $out) { (Get-FileHash -Algorithm SHA256 -LiteralPath $out).Hash } else { $null }
  & $Arrange $checkerPath $productionPath $batteryPath
  $result = Invoke-Aggregator $checkerPath $productionPath $batteryPath $Head $out
  Assert-AggregateTest ($result.exitCode -ne 0) "$Name unexpectedly passed"
  Assert-AggregateTest ($result.output -match [regex]::Escape($ExpectedCode)) `
    "$Name did not report $ExpectedCode (observed=$($result.output))"
  if ($PriorReceipt) {
    Assert-AggregateTest ((Get-FileHash -Algorithm SHA256 -LiteralPath $out).Hash -ceq $priorHash) `
      "$Name changed the prior aggregate receipt"
  } else {
    Assert-AggregateTest (-not (Test-Path -LiteralPath $out)) "$Name wrote a partial receipt"
  }
  if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }
  Write-Output "CONTROL $Name rejected=$ExpectedCode receipt-unchanged=true"
}

try {
  $head = (& git -C $controllerRoot rev-parse HEAD 2>&1 | Out-String).Trim()
  Assert-AggregateTest ($LASTEXITCODE -eq 0 -and $head -cmatch "^[a-f0-9]{40}$") "cannot resolve live HEAD"
  $otherHead = if ($head[0] -ceq "b") { "c" * 40 } else { "b" * 40 }
  $checkerSuite = New-Suite "checker" $checkerRows $head "run-checker"
  $productionSuite = New-Suite "issue-6254-production" $productionRows $head "run-production"
  $batterySuite = New-Suite "release-battery" $batteryRows $head "run-battery"
  $suiteResultSchema = Get-Content -LiteralPath (Join-Path $PSScriptRoot "fail-closed-guard-suite-result.schema.json") -Raw |
    ConvertFrom-Json -DateKind String
  $schemaIds = [string[]]@($suiteResultSchema.properties.suite.properties.id.enum)
  $schemaCounts = [long[]]@($suiteResultSchema.properties.suite.properties.expectedClaimCount.enum)
  $partitionIds = [string[]]@($checkerSuite.suite.id, $productionSuite.suite.id, $batterySuite.suite.id)
  $partitionCounts = [long[]]@(
    $checkerSuite.suite.expectedClaimCount,
    $productionSuite.suite.expectedClaimCount,
    $batterySuite.suite.expectedClaimCount
  )
  Assert-AggregateTest (
    [string]::Join("`n", $schemaIds) -ceq [string]::Join("`n", $partitionIds) -and
    [string]::Join("`n", $schemaCounts) -ceq [string]::Join("`n", $partitionCounts)
  ) "suite-result schema IDs/counts do not equal aggregate producer partitions"
  Write-Output "PASS suite-result schema/producer parity ids=$($partitionIds -join ',') counts=$($partitionCounts -join '/')"

  if ($Scenario -ceq "BatteryArtifact") {
    Assert-AggregateTest (-not [string]::IsNullOrWhiteSpace($BatteryResultPath)) "BatteryArtifact requires -BatteryResultPath"
    $resolvedBattery = [IO.Path]::GetFullPath($(if([IO.Path]::IsPathRooted($BatteryResultPath)){$BatteryResultPath}else{Join-Path $controllerRoot $BatteryResultPath}))
    Assert-AggregateTest (Test-Path -LiteralPath $resolvedBattery -PathType Leaf) "BatteryArtifact input is missing"
    $checkerPath = Join-Path $testRoot "synthetic-checker.json"
    $productionPath = Join-Path $testRoot "synthetic-production.json"
    $out = Join-Path $controllerRoot ".orchestrator/artifacts/aggregate-test-battery-artifact.json"
    if(Test-Path -LiteralPath $out){Remove-Item -LiteralPath $out -Force}
    Write-Json $checkerSuite $checkerPath
    Write-Json $productionSuite $productionPath
    $actual = Get-Content -LiteralPath $resolvedBattery -Raw | ConvertFrom-Json -DateKind String
    Assert-AggregateTest ([int]$actual.suite.expectedClaimCount-eq$batteryRows.Count-and@($actual.claims).Count-eq$batteryRows.Count) "actual release-battery artifact count does not match its manifest"
    $accepted = Invoke-Aggregator $checkerPath $productionPath $resolvedBattery $head $out
    Assert-AggregateTest ($accepted.exitCode-eq0-and(Test-Path -LiteralPath $out -PathType Leaf)) "canonical aggregate rejected the actual release-battery artifact: $($accepted.output)"
    Remove-Item -LiteralPath $out -Force
    Write-Output "PASS actual release-battery artifact accepted by canonical schema/aggregate claims=$($batteryRows.Count)"
    return
  }

  Assert-Control "pre-suite" {
    param($c, $p, $b)
  } "AGGREGATE_SUITES_NOT_EXECUTED" $head $false

  Assert-Control "missing-suite" {
    param($c, $p, $b)
    Write-Json $checkerSuite $c
    Write-Json $productionSuite $p
  } "AGGREGATE_SUITE_MISSING:release-battery" $head

  Assert-Control "duplicate-claim" {
    param($c, $p, $b)
    $duplicate = Copy-Value $productionSuite
    $duplicate.claims[0].guardId = $checkerSuite.claims[0].guardId
    Write-Json $checkerSuite $c
    Write-Json $duplicate $p
    Write-Json $batterySuite $b
  } "AGGREGATE_CLAIM_DUPLICATE:C01-RECEIPT-MISSING" $head

  Assert-Control "wrong-head" {
    param($c, $p, $b)
    $wrong = Copy-Value $productionSuite
    $wrong.subject.controllerHead = $otherHead
    Write-Json $checkerSuite $c
    Write-Json $wrong $p
    Write-Json $batterySuite $b
  } "AGGREGATE_HEAD_MISMATCH:issue-6254-production" $head

  Assert-Control "issue-6254-production-partial-update" {
    param($c, $p, $b)
    $partial = Copy-Value $productionSuite
    $partial.suite.expectedClaimCount = 15
    Write-Json $checkerSuite $c
    Write-Json $partial $p
    Write-Json $batterySuite $b
  } "AGGREGATE_SUITE_INCONSISTENT:issue-6254-production" $head

  Assert-Control "moved-live-head" {
    param($c, $p, $b)
    $cSuite = Copy-Value $checkerSuite
    $pSuite = Copy-Value $productionSuite
    $bSuite = Copy-Value $batterySuite
    $cSuite.subject.controllerHead = $otherHead
    $pSuite.subject.controllerHead = $otherHead
    $bSuite.subject.controllerHead = $otherHead
    Write-Json $cSuite $c
    Write-Json $pSuite $p
    Write-Json $bSuite $b
  } "AGGREGATE_LIVE_HEAD_MOVED" $otherHead

  foreach ($case in @(
      [ordered]@{ name = "wrong-identity"; mutate = { param($s) $s.suite.id = "checker" } },
      [ordered]@{ name = "wrong-count"; mutate = { param($s) $s.suite.expectedClaimCount = 4 } },
      [ordered]@{ name = "not-executed"; mutate = { param($s) $s.execution.executed = $false } },
      [ordered]@{ name = "executed-string"; mutate = { param($s) $s.execution.executed = "True" } },
      [ordered]@{ name = "wrong-outcome"; mutate = { param($s) $s.execution.outcome = "fail" } },
      [ordered]@{ name = "duplicate-run"; mutate = { param($s) $s.execution.runId = "run-checker" } },
      [ordered]@{ name = "wrong-partition"; mutate = { param($s) $s.claims[0].guardId = "NOT-IN-PARTITION" } },
      [ordered]@{ name = "unknown-property"; mutate = { param($s) $s.execution.extra = $true } }
    )) {
    $mutate = $case.mutate
    Assert-Control ("inconsistent-" + $case.name) {
      param($c, $p, $b)
      $changed = Copy-Value $batterySuite
      & $mutate $changed
      Write-Json $checkerSuite $c
      Write-Json $productionSuite $p
      Write-Json $changed $b
    } "AGGREGATE_SUITE_INCONSISTENT:release-battery" $head
  }

  $checkerPath = Join-Path $testRoot "success-checker.json"
  $productionPath = Join-Path $testRoot "success-production.json"
  $batteryPath = Join-Path $testRoot "success-battery.json"
  Write-Json $checkerSuite $checkerPath
  Write-Json $productionSuite $productionPath
  Write-Json $batterySuite $batteryPath
  $out = Join-Path $controllerRoot ".orchestrator/artifacts/aggregate-test-success.json"
  if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }
  $success = Invoke-Aggregator $checkerPath $productionPath $batteryPath $head $out
  $aggregateCount=$checkerRows.Count+$productionRows.Count+$batteryRows.Count
  Assert-AggregateTest ($success.exitCode -eq 0 -and $success.output -match "claims=$aggregateCount") `
    "valid three-suite aggregate failed: $($success.output)"
  $receipt = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json -DateKind String
  Assert-AggregateTest (@($receipt.claims).Count -eq $aggregateCount) "aggregate row count is not code-derived"
  $checked = & $checker -ReceiptPath $out -ExpectedControllerHead $head 2>&1 | Out-String
  Assert-AggregateTest ($LASTEXITCODE -eq 0 -and $checked -match "claims=$aggregateCount") "published aggregate does not validate"
  Remove-Item -LiteralPath $out -Force

  $scaleChecker = Add-ScaleEvidence $checkerSuite 0
  $scaleProduction = Add-ScaleEvidence $productionSuite $checkerRows.Count
  $scaleBattery = Add-ScaleEvidence $batterySuite ($checkerRows.Count + $productionRows.Count)
  $scaleReceipt = [ordered]@{
    schemaVersion = "fail-closed-guard-evidence/v1"
    subject = [ordered]@{
      controllerHead = $head
      batteryId = "issue-6254-fail-closed-guard-evidence/$aggregateCount"
    }
    claims = @($scaleChecker.claims; $scaleProduction.claims; $scaleBattery.claims)
  }
  $scalePrettyJson = $scaleReceipt | ConvertTo-Json -Depth 100
  $scaleCompactJson = $scaleReceipt | ConvertTo-Json -Compress -Depth 100
  $scalePrettyBytes = [Text.UTF8Encoding]::new($false).GetByteCount($scalePrettyJson)
  $scaleCompactBytes = [Text.UTF8Encoding]::new($false).GetByteCount($scaleCompactJson)
  Assert-AggregateTest ($scalePrettyBytes -gt 1MB) "scale fixture pretty representation did not exceed 1 MiB"
  Assert-AggregateTest ($scaleCompactBytes -lt 1MB) "scale fixture compact representation did not remain below 1 MiB"

  $scaleCheckerPath = Join-Path $testRoot "scale-checker.json"
  $scaleProductionPath = Join-Path $testRoot "scale-production.json"
  $scaleBatteryPath = Join-Path $testRoot "scale-battery.json"
  Write-Json $scaleChecker $scaleCheckerPath
  Write-Json $scaleProduction $scaleProductionPath
  Write-Json $scaleBattery $scaleBatteryPath
  $scaleOut = Join-Path $controllerRoot ".orchestrator/artifacts/aggregate-test-scale.json"
  if (Test-Path -LiteralPath $scaleOut) { Remove-Item -LiteralPath $scaleOut -Force }
  try {
    $scaleSuccess = Invoke-Aggregator $scaleCheckerPath $scaleProductionPath $scaleBatteryPath $head $scaleOut
    Assert-AggregateTest ($scaleSuccess.exitCode -eq 0 -and $scaleSuccess.output -match "claims=$aggregateCount") `
      "compact scale aggregate failed: $($scaleSuccess.output)"
    $publishedJson = [IO.File]::ReadAllText($scaleOut, [Text.UTF8Encoding]::new($false, $true))
    Assert-AggregateTest ($publishedJson -ceq $scaleCompactJson) `
      "compact aggregate did not preserve exact nested values, types, or property/claim order"
    $published = $publishedJson | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
    Assert-AggregateTest (
      @($published.Keys).Count -eq 3 -and
      @($published.Keys)[0] -ceq "schemaVersion" -and
      @($published.Keys)[1] -ceq "subject" -and
      @($published.Keys)[2] -ceq "claims" -and
      [string]$published.schemaVersion -ceq "fail-closed-guard-evidence/v1"
    ) "compact aggregate root schema/order changed"
    Assert-AggregateTest (
      @($published.subject.Keys).Count -eq 2 -and
      @($published.subject.Keys)[0] -ceq "controllerHead" -and
      @($published.subject.Keys)[1] -ceq "batteryId" -and
      [string]$published.subject.controllerHead -ceq $head -and
      [string]$published.subject.batteryId -ceq "issue-6254-fail-closed-guard-evidence/$aggregateCount"
    ) "compact aggregate subject changed"
    Assert-AggregateTest (@($published.claims).Count -eq $aggregateCount) `
      "compact aggregate claim count changed"
    $expectedGuardIds = [string[]]@($scaleReceipt.claims | ForEach-Object { [string]$_.guardId })
    $actualGuardIds = [string[]]@($published.claims | ForEach-Object { [string]$_.guardId })
    $expectedMutantIds = [string[]]@($scaleReceipt.claims | ForEach-Object { [string]$_.bypassMutant.id })
    $actualMutantIds = [string[]]@($published.claims | ForEach-Object { [string]$_.bypassMutant.id })
    Assert-AggregateTest ([string]::Join("`n", $actualGuardIds) -ceq [string]::Join("`n", $expectedGuardIds)) `
      "compact aggregate guard IDs/order changed"
    Assert-AggregateTest ([string]::Join("`n", $actualMutantIds) -ceq [string]::Join("`n", $expectedMutantIds)) `
      "compact aggregate mutant IDs/order changed"
    $scaleProbe = $published.claims[0].preservedVariables.scaleEvidence
    Assert-AggregateTest (
      $scaleProbe.claimOrdinal -is [long] -and
      $scaleProbe.active -is [bool] -and
      $scaleProbe.labels -is [Array] -and
      $scaleProbe.optional -eq $null -and
      $scaleProbe.payload -is [string] -and
      $scaleProbe.payload.Length -eq 4000 -and
      $scaleProbe.secondaryPayload -is [string] -and
      $scaleProbe.secondaryPayload.Length -eq 1800
    ) "compact aggregate nested value types changed"
    $scaleChecked = & $checker -ReceiptPath $scaleOut -ExpectedControllerHead $head 2>&1 | Out-String
    Assert-AggregateTest ($LASTEXITCODE -eq 0 -and $scaleChecked -match "claims=$aggregateCount") `
      "unchanged checker rejected compact scale aggregate"

    $overBoundReceipt = Copy-Value $scaleReceipt
    foreach ($claim in @($overBoundReceipt.claims)) {
      $claim.preservedVariables["overBoundPayload"] = "z" * 2048
      $claim.candidate.inputs["overBoundPayload"] = "z" * 2048
      $claim.bypassMutant.inputs["overBoundPayload"] = "z" * 2048
    }
    $overBoundJson = $overBoundReceipt | ConvertTo-Json -Compress -Depth 100
    $overBoundBytes = [Text.UTF8Encoding]::new($false).GetByteCount($overBoundJson)
    Assert-AggregateTest ($overBoundBytes -gt 1MB) "over-bound compact control did not exceed 1 MiB"
    $overBoundPath = Join-Path $testRoot "over-bound-compact.json"
    [IO.File]::WriteAllText($overBoundPath, $overBoundJson, [Text.UTF8Encoding]::new($false))
    $overBoundChecked = & pwsh -NoProfile -NonInteractive -File $checker `
      -ReceiptPath $overBoundPath -ExpectedControllerHead $head 2>&1 | Out-String
    Assert-AggregateTest ($LASTEXITCODE -ne 0 -and $overBoundChecked -match "RECEIPT_TOO_LARGE") `
      "unchanged checker did not reject a genuinely over-bound compact receipt"
    Write-Output "CONTROL aggregate-scale prettyBytes=$scalePrettyBytes compactBytes=$scaleCompactBytes claims=$aggregateCount checker=PASS"
    Write-Output "CONTROL aggregate-over-bound compactBytes=$overBoundBytes rejected=RECEIPT_TOO_LARGE"
  } finally {
    if (Test-Path -LiteralPath $scaleOut) { Remove-Item -LiteralPath $scaleOut -Force }
  }

  Write-Output "PASS aggregate controls pre-suite/missing/duplicate/wrong-head/moved-head/inconsistent/no-write"
  Write-Output "PASS aggregate success head=$head rows=$aggregateCount partitions=$($checkerRows.Count)/$($productionRows.Count)/$($batteryRows.Count)"
} finally {
  if (Test-Path -LiteralPath $testRoot) {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd("\", "/")
    if ((Split-Path -Parent $resolved).TrimEnd("\", "/") -ne $temp -or
        (Split-Path -Leaf $resolved) -notlike "fail-closed-aggregate-test-*") {
      throw "refusing unsafe aggregate-test cleanup target: $resolved"
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
  }
  if ($artifactDirectoryInitiallyAbsent -and (Test-Path -LiteralPath $artifactRoot)) {
    $residue = @(Get-ChildItem -LiteralPath $artifactRoot -Force)
    if ($residue.Count -ne 0) {
      throw "aggregate test left residue in its initially absent artifact directory"
    }
    [IO.Directory]::Delete($artifactRoot, $false)
  }
}
