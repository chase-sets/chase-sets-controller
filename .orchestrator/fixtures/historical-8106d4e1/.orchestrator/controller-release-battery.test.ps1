[CmdletBinding()]
param(
  [ValidateSet("All", "Admission", "OmissionMutants", "InheritedAdmissionIsolation")]
  [string]$Scenario = "All",

  [string]$ExpectedControllerHead = "",

  [string]$SuiteResultOut = "",

  [switch]$ValidatePlanOnly
)

$ErrorActionPreference = "Stop"
$controllerRoot = Split-Path -Parent $PSScriptRoot
$battery = Join-Path $PSScriptRoot "controller-release-battery.ps1"
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("controller-release-battery-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $testRoot | Out-Null

$batteryManifest = @(
  [ordered]@{
    guardId = "BATTERY-CHECKER-REQUIRED"
    pointer = "/batteryGuards/BATTERY-CHECKER-REQUIRED/directInvocationEnabled"
    planIdentity = "direct:fail-closed-guard-evidence"
    mutantId = "omit-direct-fail-closed-evidence-validation"
    signature = "BATTERY_DIRECT_CHECKER_VALIDATION_OMITTED"
  },
  [ordered]@{
    guardId = "BATTERY-6254-DISCRIMINATOR-REQUIRED"
    pointer = "/batteryGuards/BATTERY-6254-DISCRIMINATOR-REQUIRED/enabled"
    planIdentity = "discriminator:issue-6254"
    mutantId = "omit-issue-6254-discriminator"
    signature = "BATTERY_DISCRIMINATOR_OMITTED:issue-6254"
  }
)
$omissionRuntimeFiles = @(
  "controller-release-battery.ps1",
  "invoke-heavy-verifier.ps1",
  "fail-closed-guard-evidence.ps1",
  "fail-closed-guard-evidence.schema.json",
  "fail-closed-guard-evidence.test.ps1",
  "issue-6254-discriminator.ps1",
  "lease-contract.psm1",
  "orchestration-log-lock.psm1",
  "dispatch-ownership.ps1",
  "review-head-contract.psm1",
  "review-head-reducer.ps1",
  "landing-preflight.ps1",
  "landing-preflight.fixture.json",
  "review-queue-health.ps1",
  "log-event.ps1"
)

function Assert-BatteryTest([bool]$Condition, [string]$Message) {
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

function New-BatteryClaim($Row) {
  $preserved = [ordered]@{
    checkerValidation = "direct-plus-independent-issue-6254-discriminator"
    controllerRoot = "."
    discovery = "explicit-checker-validation-plus-tracked-tests-and-issue-discriminators"
    parallelism = 1
    testMode = "finite-synthetic-worktree"
  }
  return [ordered]@{
    guardId = $Row.guardId
    governingVariable = [ordered]@{
      pointer = $Row.pointer
      candidateValue = $true
      bypassValue = $false
    }
    preservedVariables = $preserved
    candidate = [ordered]@{
      inputs = Insert-Pointer $preserved $Row.pointer $true
      executed = $true
      expectation = [ordered]@{ testOutcome = "pass"; observation = "PASS"; failureSignature = $null }
      result = [ordered]@{ testOutcome = "pass"; observation = "PASS"; failureSignature = $null }
    }
    bypassMutant = [ordered]@{
      id = $Row.mutantId
      change = "omit only $($Row.planIdentity)"
      inputs = Insert-Pointer $preserved $Row.pointer $false
      executed = $true
      expectation = [ordered]@{ testOutcome = "fail"; observation = "FAIL"; failureSignature = $Row.signature }
      result = [ordered]@{ testOutcome = "fail"; observation = "FAIL"; failureSignature = $Row.signature }
    }
    failureSignature = $Row.signature
  }
}

function Initialize-GitRepository([string]$Root) {
  & git -C $Root init --quiet | Out-Null
  Assert-BatteryTest ($LASTEXITCODE -eq 0) "synthetic git init failed"
  & git -C $Root config user.name "Controller Battery Test"
  & git -C $Root config user.email "controller-battery@example.invalid"
  & git -C $Root add --all
  Assert-BatteryTest ($LASTEXITCODE -eq 0) "synthetic git add failed"
  & git -C $Root commit --quiet -m "finite controller battery fixture"
  Assert-BatteryTest ($LASTEXITCODE -eq 0) "synthetic git commit failed"
  $head = (& git -C $Root rev-parse HEAD 2>&1 | Out-String).Trim()
  Assert-BatteryTest ($LASTEXITCODE -eq 0 -and $head -cmatch "^[a-f0-9]{40}$") "synthetic HEAD unavailable"
  return $head
}

function Copy-RuntimeFile([string]$SyntheticRoot, [string]$Name) {
  $source = Join-Path $PSScriptRoot $Name
  Assert-BatteryTest (Test-Path -LiteralPath $source -PathType Leaf) "runtime fixture missing: $Name"
  [IO.File]::Copy($source, (Join-Path $SyntheticRoot ".orchestrator/$Name"), $true)
}

function Set-NonAdmittedBatteryChildEnvironment([Diagnostics.ProcessStartInfo]$StartInfo) {
  # Restore the environment that existed before the lane admission preload, then
  # remove every admission-only marker. This mutates only the pending child.
  if ($StartInfo.Environment.ContainsKey("CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_NODE_OPTIONS")) {
    $originalNodeOptions = $StartInfo.Environment["CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_NODE_OPTIONS"]
    if ([string]::IsNullOrEmpty($originalNodeOptions)) {
      [void]$StartInfo.Environment.Remove("NODE_OPTIONS")
    } else {
      $StartInfo.Environment["NODE_OPTIONS"] = $originalNodeOptions
    }
  }
  if ($StartInfo.Environment.ContainsKey("CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_SCRIPT_SHELL")) {
    $originalScriptShell = $StartInfo.Environment["CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_SCRIPT_SHELL"]
    if ([string]::IsNullOrEmpty($originalScriptShell)) {
      [void]$StartInfo.Environment.Remove("npm_config_script_shell")
    } else {
      $StartInfo.Environment["npm_config_script_shell"] = $originalScriptShell
    }
  }
  foreach ($name in @(
      "CHASE_SETS_HEAVY_ADMISSION_CONFIG",
      "CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_NODE_OPTIONS",
      "CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_SCRIPT_SHELL",
      "CHASE_SETS_HEAVY_ADMISSION_PNPM_SCRIPT_SHELL"
    )) {
    [void]$StartInfo.Environment.Remove($name)
  }
  [void]$StartInfo.Environment.Remove("CHASE_SETS_HEAVY_SLOT_ID") # BATTERY_NON_ADMITTED_SLOT_SCRUB_SEAM
}

function New-BatteryChildStartInfo([string]$WorkingDirectory) {
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = (Get-Process -Id $PID -ErrorAction Stop).Path
  $start.WorkingDirectory = $WorkingDirectory
  $start.UseShellExecute = $false
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  return $start
}

function Complete-BatteryChildProcess([Diagnostics.Process]$Process) {
  $standardOutput = $Process.StandardOutput.ReadToEndAsync()
  $standardError = $Process.StandardError.ReadToEndAsync()
  $Process.WaitForExit()
  return [pscustomobject]@{
    exitCode = $Process.ExitCode
    output = (($standardOutput.Result + "`n" + $standardError.Result).Trim())
  }
}

# Battery child-launch audit:
# - Invoke-BatteryProcess scrubs before every intentionally non-admitted battery.
# - Start-BatteryFixtureProcess scrubs, then passes a token only when SlotId is
#   explicit; omitted SlotId exercises a fresh acquisition.
# - Invoke-FixtureContender scrubs before its independent wrapper acquisition.
# - Invoke-BlindInheritedAdmissionMutant alone inherits blindly as a required
#   red negative control; it is never used for a candidate launch.
# - Invoke-PlanControl is same-process, finite ValidatePlanOnly execution and
#   never enters the admission path or creates a battery child.

function New-PlanFixture {
  $root = Join-Path $testRoot ("plan-" + [guid]::NewGuid().ToString("N"))
  $runtime = Join-Path $root ".orchestrator"
  New-Item -ItemType Directory -Path $runtime -Force | Out-Null
  Copy-RuntimeFile $root "controller-release-battery.ps1"
  Copy-RuntimeFile $root "fail-closed-guard-evidence.ps1"
  Copy-RuntimeFile $root "fail-closed-guard-evidence.test.ps1"
  Copy-RuntimeFile $root "review-head-contract.psm1"
  foreach ($name in @(
      "controller-release-battery.test.ps1",
      "fail-closed-guard-evidence-aggregate.test.ps1",
      "finite-extra.test.ps1",
      "issue-6254-discriminator.ps1"
    )) {
    if ($name -ceq "finite-extra.test.ps1") {
      [IO.File]::WriteAllText(
        (Join-Path $runtime $name),
        'Write-Output "PASS finite extra test"',
        [Text.UTF8Encoding]::new($false)
      )
    } elseif ($name -ceq "issue-6254-discriminator.ps1") {
      [IO.File]::WriteAllText(
        (Join-Path $runtime $name),
        @'
[CmdletBinding()]
param(
  [string]$ControllerRoot,
  [string]$EvidenceReceiptPath,
  [string]$ExpectedControllerHead
)
Write-Output "PASS finite issue-6254 discriminator"
'@,
        [Text.UTF8Encoding]::new($false)
      )
    } else {
      Copy-RuntimeFile $root $name
    }
  }
  $head = Initialize-GitRepository $root
  return [pscustomobject]@{ root = $root; head = $head }
}

function Invoke-PlanControl {
  $fixture = New-PlanFixture
  $receipt = Join-Path $fixture.root ".orchestrator/unused-plan-only.json"
  $output = & (Join-Path $fixture.root ".orchestrator/controller-release-battery.ps1") `
    -ControllerRoot $fixture.root -ExpectedControllerHead $fixture.head `
    -EvidenceReceiptPath $receipt -ValidatePlanOnly 2>&1 | Out-String
  Assert-BatteryTest ($LASTEXITCODE -eq 0) "finite production plan validation failed: $output"
  foreach ($identity in @(
      "direct:fail-closed-guard-evidence",
      "test:fail-closed-guard-evidence-aggregate.test.ps1",
      "test:controller-release-battery.test.ps1",
      "discriminator:issue-6254"
    )) {
    Assert-BatteryTest ($output -match [regex]::Escape("PLAN identity=$identity")) `
      "finite plan omitted $identity"
  }
  $selfLine = @($output -split "\r?\n" | Where-Object {
      $_ -match "PLAN identity=test:controller-release-battery.test.ps1"
    })
  Assert-BatteryTest ($selfLine.Count -eq 1 -and $selfLine[0] -match [regex]::Escape("-ValidatePlanOnly")) `
    "battery self-test is not finite plan-only"
  Assert-BatteryTest ($output -notmatch [regex]::Escape('controller-runtime-closure-census.ps1')) `
    "governed closure census was incorrectly enrolled as a test or discriminator"
  $consumerInventory=Get-Content -LiteralPath (Join-Path $controllerRoot '.orchestrator/controller-review-consumer-inventory.json') -Raw|ConvertFrom-Json -Depth 20
  Assert-BatteryTest (@($consumerInventory.consumers).Count-eq7-and@($consumerInventory.consumers.path)-cnotcontains'.orchestrator/controller-runtime-closure-census.ps1') `
    "controller review consumer census is not the closed exact seven-row set"
  Write-Output "PASS controller battery plan derives tracked tests/discriminators, includes direct checker, and prevents self-recursion"
}

function Invoke-ScopeControl {
  # Change scope: a baseline..candidate diff confined to skills, contracts, and
  # test files selects the prose scope; a runtime script in the diff keeps the
  # full battery. Both stay finite plan-only.
  $fixture = New-PlanFixture
  $receipt = Join-Path $fixture.root ".orchestrator/unused-plan-only.json"
  $skillDir = Join-Path $fixture.root ".orchestrator/controller-skills/milestone-orchestrator"
  New-Item -ItemType Directory -Path $skillDir -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $skillDir "SKILL.md"), "# Milestone Orchestrator (synthetic)`n", [Text.UTF8Encoding]::new($false))
  & git -C $fixture.root add --all
  & git -C $fixture.root commit --quiet -m "prose change"
  $proseHead = (& git -C $fixture.root rev-parse HEAD 2>&1 | Out-String).Trim()
  $repairHistory = Join-Path $fixture.root ".orchestrator/repair-history.jsonl"
  $tuple = [ordered]@{
    issue = 4388; controllerHead = $fixture.head
    authorAttempt = "synthetic-repair-author"; reviewerAttempt = "synthetic-repair-reviewer"
    reviewAuthority = "governing"; lane = "synthetic-repair-review-lane"
    transcript = "synthetic-repair-review.jsonl"; reviewerModel = "gpt-5.6-sol"
    authorModel = "gpt-5.6-sol"; effort = "high"; row = "11"
    placement = "measured"; harness = "codex"
  }
  $dispatch = [ordered]@{ ts = "2026-09-10T12:00:00.000Z"; kind = "dispatch"; controllerReviewSchema = "controller-review-dispatch/v1" }
  foreach ($key in $tuple.Keys) { $dispatch[$key] = $tuple[$key] }
  $receiptRow = [ordered]@{ ts = "2026-09-10T12:01:00.000Z"; kind = "review-complete"; controllerReviewSchema = "controller-review-receipt/v1" }
  foreach ($key in $tuple.Keys) { $receiptRow[$key] = $tuple[$key] }
  $receiptRow.reviewContract = "review-contract/v2"; $receiptRow.completeSweep = $true
  $receiptRow.outcome = "BLOCK_FIXABLE"; $receiptRow.findingIds = @("F1")
  $receiptRow.findings = [ordered]@{ blocking = 1; candidates = 1; nonBlocking = 0 }
  [IO.File]::WriteAllText($repairHistory, (($dispatch | ConvertTo-Json -Compress -Depth 10) + "`n" + ($receiptRow | ConvertTo-Json -Compress -Depth 10) + "`n"), [Text.UTF8Encoding]::new($false))
  $output = & (Join-Path $fixture.root ".orchestrator/controller-release-battery.ps1") `
    -ControllerRoot $fixture.root -ExpectedControllerHead $proseHead -BaselineHead $fixture.head `
    -RepairIssue 4388 -RepairHistoryPath $repairHistory `
    -EvidenceReceiptPath $receipt -ValidatePlanOnly 2>&1 | Out-String
  Assert-BatteryTest ($LASTEXITCODE -eq 0) "prose-scope plan validation failed: $output"
  Assert-BatteryTest ($output -match [regex]::Escape("BATTERY_SCOPE scope=prose")) "prose diff did not select the prose scope"
  Assert-BatteryTest ($output -notmatch [regex]::Escape("PLAN identity=test:finite-extra.test.ps1")) "prose scope still enrolled an unrelated test"
  foreach ($identity in @("test:controller-release-battery.test.ps1", "discriminator:issue-6254", "direct:fail-closed-guard-evidence")) {
    Assert-BatteryTest ($output -match [regex]::Escape("PLAN identity=$identity")) "prose scope omitted $identity"
  }
  [IO.File]::AppendAllText((Join-Path $fixture.root ".orchestrator/fail-closed-guard-evidence.ps1"), "`n# runtime touch`n", [Text.UTF8Encoding]::new($false))
  & git -C $fixture.root add --all
  & git -C $fixture.root commit --quiet -m "runtime change"
  $runtimeHead = (& git -C $fixture.root rev-parse HEAD 2>&1 | Out-String).Trim()
  $output = & (Join-Path $fixture.root ".orchestrator/controller-release-battery.ps1") `
    -ControllerRoot $fixture.root -ExpectedControllerHead $runtimeHead -BaselineHead $proseHead `
    -EvidenceReceiptPath $receipt -ValidatePlanOnly 2>&1 | Out-String
  Assert-BatteryTest ($LASTEXITCODE -eq 0) "full-scope plan validation failed: $output"
  Assert-BatteryTest ($output -match [regex]::Escape("BATTERY_SCOPE scope=full")) "runtime diff did not select the full battery"
  Assert-BatteryTest ($output -match [regex]::Escape("PLAN identity=test:finite-extra.test.ps1")) "full scope dropped a tracked test"
  $refusal = ""
  try {
    & (Join-Path $fixture.root ".orchestrator/controller-release-battery.ps1") `
      -ControllerRoot $fixture.root -ExpectedControllerHead $runtimeHead -BaselineHead "not-a-sha" `
      -EvidenceReceiptPath $receipt -ValidatePlanOnly 2>&1 | Out-Null
  } catch { $refusal = $_.Exception.Message }
  Assert-BatteryTest ($refusal -match "BATTERY_BASELINE_HEAD_INVALID") "malformed baseline was not refused: $refusal"
  foreach ($control in @(
      [ordered]@{ name="non-ancestor"; baseline=("f" * 40); issue=4388; history=$repairHistory; signature="BATTERY_BASELINE_NOT_ANCESTOR" },
      [ordered]@{ name="missing-history"; baseline=$fixture.head; issue=4388; history=(Join-Path $fixture.root "missing.jsonl"); signature="BATTERY_REPAIR_HISTORY_HISTORY_MISSING" },
      [ordered]@{ name="missing-contract-half"; baseline=$fixture.head; issue=4388; history=""; signature="BATTERY_REPAIR_CONTRACT_INCOMPLETE" }
    )) {
    $observed = ""
    try {
      & (Join-Path $fixture.root ".orchestrator/controller-release-battery.ps1") -ControllerRoot $fixture.root `
        -ExpectedControllerHead $runtimeHead -BaselineHead $control.baseline -RepairIssue $control.issue `
        -RepairHistoryPath $control.history -ValidatePlanOnly 2>&1 | Out-Null
    } catch { $observed = $_.Exception.Message }
    Assert-BatteryTest ($observed -match [regex]::Escape($control.signature)) "$($control.name) repair baseline did not fail closed: $observed"
  }
  $nonBlockHistory = Join-Path $fixture.root ".orchestrator/nonblock-history.jsonl"
  $nonBlockReceipt = $receiptRow | ConvertTo-Json -Depth 10 | ConvertFrom-Json -DateKind String
  $nonBlockReceipt.outcome = "PASS"; $nonBlockReceipt.findingIds = @(); $nonBlockReceipt.findings.blocking = 0; $nonBlockReceipt.findings.candidates = 0
  [IO.File]::WriteAllText($nonBlockHistory, (($dispatch | ConvertTo-Json -Compress -Depth 10) + "`n" + ($nonBlockReceipt | ConvertTo-Json -Compress -Depth 10) + "`n"), [Text.UTF8Encoding]::new($false))
  $nonBlockObserved = ""
  try { & (Join-Path $fixture.root ".orchestrator/controller-release-battery.ps1") -ControllerRoot $fixture.root -ExpectedControllerHead $runtimeHead -BaselineHead $fixture.head -RepairIssue 4388 -RepairHistoryPath $nonBlockHistory -ValidatePlanOnly 2>&1 | Out-Null } catch { $nonBlockObserved = $_.Exception.Message }
  Assert-BatteryTest ($nonBlockObserved -match "BATTERY_REPAIR_PREDECESSOR_NOT_BLOCK_FIXABLE") "non-BLOCK_FIXABLE repair baseline did not fail closed: $nonBlockObserved"
  $missingFindingHistory = Join-Path $fixture.root ".orchestrator/missing-finding-history.jsonl"
  $missingFindingReceipt = $receiptRow | ConvertTo-Json -Depth 10 | ConvertFrom-Json -DateKind String
  $missingFindingReceipt.findingIds = @()
  [IO.File]::WriteAllText($missingFindingHistory, (($dispatch | ConvertTo-Json -Compress -Depth 10) + "`n" + ($missingFindingReceipt | ConvertTo-Json -Compress -Depth 10) + "`n"), [Text.UTF8Encoding]::new($false))
  $missingFindingObserved = ""
  try { & (Join-Path $fixture.root ".orchestrator/controller-release-battery.ps1") -ControllerRoot $fixture.root -ExpectedControllerHead $runtimeHead -BaselineHead $fixture.head -RepairIssue 4388 -RepairHistoryPath $missingFindingHistory -ValidatePlanOnly 2>&1 | Out-Null } catch { $missingFindingObserved = $_.Exception.Message }
  Assert-BatteryTest ($missingFindingObserved -match "BATTERY_REPAIR_RECEIPT_AMBIGUOUS") "finding-less BLOCK_FIXABLE repair baseline did not fail closed: $missingFindingObserved"
  $malformedRepairHistory = Join-Path $fixture.root ".orchestrator/malformed-repair-history.jsonl"
  [IO.File]::WriteAllText($malformedRepairHistory, '{"kind":"review-complete"' + "`n", [Text.UTF8Encoding]::new($false))
  $malformedRepairObserved = ""
  try { & (Join-Path $fixture.root ".orchestrator/controller-release-battery.ps1") -ControllerRoot $fixture.root -ExpectedControllerHead $runtimeHead -BaselineHead $fixture.head -RepairIssue 4388 -RepairHistoryPath $malformedRepairHistory -ValidatePlanOnly 2>&1 | Out-Null } catch { $malformedRepairObserved = $_.Exception.Message }
  Assert-BatteryTest ($malformedRepairObserved -match "BATTERY_REPAIR_HISTORY_HISTORY_MALFORMED") "malformed repair history did not fail closed: $malformedRepairObserved"
  # Production delegation: a non-plan battery hands off to invoke-heavy-verifier,
  # which launches the admitted child. The baseline must survive both hops or
  # every production run silently selects the full battery.
  $batterySource = [IO.File]::ReadAllText((Join-Path $fixture.root ".orchestrator/controller-release-battery.ps1"))
  $verifierSource = [IO.File]::ReadAllText((Join-Path $controllerRoot ".orchestrator/invoke-heavy-verifier.ps1"))
  Assert-BatteryTest ($batterySource -match [regex]::Escape('-ControllerBatteryBaselineHead $BaselineHead')) "battery delegation drops BaselineHead before the heavy verifier"
  Assert-BatteryTest ($verifierSource -match [regex]::Escape('ParameterSetName = "ControllerBattery"') -and $verifierSource -match [regex]::Escape('[string]$ControllerBatteryBaselineHead')) "heavy verifier has no ControllerBattery baseline parameter"
  Assert-BatteryTest ($verifierSource -match [regex]::Escape('"-BaselineHead", $ControllerBatteryBaselineHead')) "heavy verifier omits BaselineHead from the admitted child arguments"
  Assert-BatteryTest ($verifierSource -match [regex]::Escape('"-RepairHistoryPath", $ControllerBatteryRepairHistoryPath')) "heavy verifier omits repair history from the admitted child arguments"
  Write-Output "PASS controller battery initial/repair baselines select prose or full and malformed/nonancestor/nonBF repair authority fails closed"
}

function New-MinimalReceipt([string]$Head, [string]$Path) {
  $preserved = [ordered]@{ controllerRoot = "."; fixture = "battery-minimal"; parallelism = 1 }
  $pointer = "/guards/minimal/enabled"
  $signature = "MUTANT_KILLED:minimal"
  $receipt = [ordered]@{
    schemaVersion = "fail-closed-guard-evidence/v1"
    subject = [ordered]@{ controllerHead = $Head; batteryId = "battery-test-minimal" }
    claims = @(
      [ordered]@{
        guardId = "battery-minimal"
        governingVariable = [ordered]@{ pointer = $pointer; candidateValue = $true; bypassValue = $false }
        preservedVariables = $preserved
        candidate = [ordered]@{
          inputs = Insert-Pointer $preserved $pointer $true
          executed = $true
          expectation = [ordered]@{ testOutcome = "pass"; observation = "PASS"; failureSignature = $null }
          result = [ordered]@{ testOutcome = "pass"; observation = "PASS"; failureSignature = $null }
        }
        bypassMutant = [ordered]@{
          id = "minimal"
          change = "minimal"
          inputs = Insert-Pointer $preserved $pointer $false
          executed = $true
          expectation = [ordered]@{ testOutcome = "fail"; observation = "FAIL"; failureSignature = $signature }
          result = [ordered]@{ testOutcome = "fail"; observation = "FAIL"; failureSignature = $signature }
        }
        failureSignature = $signature
      }
    )
  }
  [IO.File]::WriteAllText($Path, ($receipt | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
}

function New-OmissionFixture {
  $root = Join-Path $testRoot ("omission-" + [guid]::NewGuid().ToString("N"))
  $runtime = Join-Path $root ".orchestrator"
  New-Item -ItemType Directory -Path $runtime -Force | Out-Null
  foreach ($name in $omissionRuntimeFiles) {
    Copy-RuntimeFile $root $name
  }
  [IO.File]::WriteAllText(
    (Join-Path $runtime "finite-process-boundary.test.ps1"),
    'Write-Output "PASS finite process boundary"',
    [Text.UTF8Encoding]::new($false)
  )
  [IO.File]::WriteAllText(
    (Join-Path $runtime "issue-9998-discriminator.ps1"),
    @'
[CmdletBinding()]
param([Parameter(Mandatory)][string]$RepositoryRoot)
if (-not (Test-Path -LiteralPath (Join-Path $RepositoryRoot ".orchestrator"))) {
  throw "repository-root interface was not supplied"
}
Write-Output "PASS finite RepositoryRoot discriminator"
'@,
    [Text.UTF8Encoding]::new($false)
  )
  [IO.File]::WriteAllText(
    (Join-Path $runtime "issue-9999-discriminator.ps1"),
    @'
[CmdletBinding()]
param()
if ($args.Count -ne 0) { throw "parameterless discriminator received extra arguments" }
Write-Output "PASS finite parameterless discriminator"
'@,
    [Text.UTF8Encoding]::new($false)
  )
  $head = Initialize-GitRepository $root
  $receipt = Join-Path $runtime "minimal-receipt.json"
  New-MinimalReceipt $head $receipt
  return [pscustomobject]@{ root = $root; head = $head; receipt = $receipt }
}

function New-AdmissionFixture {
  $root = Join-Path $testRoot ("admission-" + [guid]::NewGuid().ToString("N"))
  $runtime = Join-Path $root ".orchestrator"
  New-Item -ItemType Directory -Path $runtime -Force | Out-Null
  Copy-RuntimeFile $root "controller-release-battery.ps1"
  Copy-RuntimeFile $root "invoke-heavy-verifier.ps1"
  [IO.File]::WriteAllText(
    (Join-Path $runtime "fail-closed-guard-evidence.ps1"),
    @'
[CmdletBinding()]
param([string]$ReceiptPath, [string]$ExpectedControllerHead)
if (-not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) { throw "synthetic receipt missing" }
Write-Output "PASS synthetic direct checker"
'@,
    [Text.UTF8Encoding]::new($false)
  )
  [IO.File]::WriteAllText(
    (Join-Path $runtime "fail-closed-guard-evidence.test.ps1"),
    @'
[CmdletBinding()]
param(
  [ValidateSet("BypassMutants")]
  [string]$Scenario,
  [string]$ExpectedControllerHead
)
Write-Output "PASS synthetic direct checker test"
'@,
    [Text.UTF8Encoding]::new($false)
  )
  [IO.File]::WriteAllText(
    (Join-Path $runtime "issue-6254-discriminator.ps1"),
    @'
[CmdletBinding()]
param([string]$ControllerRoot, [string]$EvidenceReceiptPath, [string]$ExpectedControllerHead)
Write-Output "PASS synthetic issue-6254"
'@,
    [Text.UTF8Encoding]::new($false)
  )
  [IO.File]::WriteAllText(
    (Join-Path $runtime "finite-admission.test.ps1"),
    'Write-Output "PASS synthetic admission child"',
    [Text.UTF8Encoding]::new($false)
  )
  $head = Initialize-GitRepository $root
  $receipt = Join-Path $runtime "minimal-receipt.json"
  New-MinimalReceipt $head $receipt
  return [pscustomobject]@{ root = $root; head = $head; receipt = $receipt }
}

function Invoke-BatteryProcess(
  [string]$BatteryPath,
  $Fixture
) {
  $start = New-BatteryChildStartInfo $Fixture.root
  Set-NonAdmittedBatteryChildEnvironment $start
  foreach ($argument in @(
      "-NoProfile", "-NonInteractive", "-File", $BatteryPath,
      "-ControllerRoot", $Fixture.root,
      "-ExpectedControllerHead", $Fixture.head,
      "-EvidenceReceiptPath", $Fixture.receipt
    )) { [void]$start.ArgumentList.Add($argument) }
  return Complete-BatteryChildProcess ([Diagnostics.Process]::Start($start))
}

# Named negative control: it deliberately restores the pre-v2.38 blind child
# inheritance. It is never a candidate launcher and must fail before admission.
function Invoke-BlindInheritedAdmissionMutant([string]$BatteryPath, $Fixture) {
  $output = & pwsh -NoProfile -NonInteractive -File $BatteryPath `
    -ControllerRoot $Fixture.root -ExpectedControllerHead $Fixture.head `
    -EvidenceReceiptPath $Fixture.receipt 2>&1 | Out-String
  return [pscustomobject]@{ exitCode = $LASTEXITCODE; output = $output.Trim() }
}

function Test-NonAdmittedBatteryChildEnvironmentBoundary([string]$WorkingDirectory, [string]$ParentToken) {
  $probe = New-BatteryChildStartInfo $WorkingDirectory
  $probe.Environment["CHASE_SETS_HEAVY_SLOT_ID"] = $ParentToken
  $probe.Environment["CHASE_SETS_HEAVY_ADMISSION_CONFIG"] = "synthetic-config"
  $probe.Environment["CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_NODE_OPTIONS"] = "--synthetic-original-node"
  $probe.Environment["CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_SCRIPT_SHELL"] = "synthetic-original-shell"
  $probe.Environment["CHASE_SETS_HEAVY_ADMISSION_PNPM_SCRIPT_SHELL"] = "node-check-proxy"
  $probe.Environment["NODE_OPTIONS"] = "--require synthetic-heavy-preload.cjs"
  $probe.Environment["npm_config_script_shell"] = "node-check-proxy"

  Set-NonAdmittedBatteryChildEnvironment $probe
  foreach ($name in @(
      "CHASE_SETS_HEAVY_SLOT_ID",
      "CHASE_SETS_HEAVY_ADMISSION_CONFIG",
      "CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_NODE_OPTIONS",
      "CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_SCRIPT_SHELL",
      "CHASE_SETS_HEAVY_ADMISSION_PNPM_SCRIPT_SHELL"
    )) {
    Assert-BatteryTest (-not $probe.Environment.ContainsKey($name)) `
      "non-admitted child retained $name"
  }
  Assert-BatteryTest ($probe.Environment["NODE_OPTIONS"] -ceq "--synthetic-original-node") `
    "non-admitted child did not restore original Node options"
  Assert-BatteryTest ($probe.Environment["npm_config_script_shell"] -ceq "synthetic-original-shell") `
    "non-admitted child did not restore original script shell"
  Assert-BatteryTest ([string]$env:CHASE_SETS_HEAVY_SLOT_ID -ceq $ParentToken) `
    "child environment boundary mutated the host process token"
  Write-Output "PASS non-admitted battery child environment scrubbed without host mutation"
}

function Test-InheritedAdmissionIsolation {
  $inheritedToken = [string]$env:CHASE_SETS_HEAVY_SLOT_ID
  Assert-BatteryTest ($inheritedToken -cmatch "^[a-f0-9]{32}$") `
    "inherited-admission discriminator requires a syntactically valid parent token"
  $fixture = New-OmissionFixture
  $batteryPath = Join-Path $fixture.root ".orchestrator/controller-release-battery.ps1"
  Test-NonAdmittedBatteryChildEnvironmentBoundary $fixture.root $inheritedToken

  # Candidate and mutant share the exact fixture, battery, head, receipt, token,
  # arguments, and parent process. Only the candidate child environment differs.
  $candidate = Invoke-BatteryProcess $batteryPath $fixture
  Assert-BatteryTest ($candidate.exitCode -eq 0) `
    "scrubbed inherited-admission candidate failed: $($candidate.output)"
  Assert-BatteryTest ($candidate.output -match [regex]::Escape(
      "RESULT identity=direct:fail-closed-guard-evidence exitCode=0 result=PASS"
    )) "scrubbed inherited-admission candidate did not execute green"

  $mutantId = "blind-inherited-heavy-admission"
  $mutant = Invoke-BlindInheritedAdmissionMutant $batteryPath $fixture
  Assert-BatteryTest ($mutant.exitCode -ne 0 -and
    $mutant.output -match [regex]::Escape("BATTERY_INHERITED_ADMISSION_FORBIDDEN")) `
    "$mutantId did not fail with BATTERY_INHERITED_ADMISSION_FORBIDDEN: $($mutant.output)"
  Write-Output "PASS inherited-admission-isolation candidate=PASS mutant=$mutantId`:FAIL signature=BATTERY_INHERITED_ADMISSION_FORBIDDEN"
}

function Invoke-OmissionSuite {
  $fixture = New-OmissionFixture
  $candidate = Invoke-BatteryProcess (Join-Path $fixture.root ".orchestrator/controller-release-battery.ps1") $fixture
  Assert-BatteryTest ($candidate.exitCode -eq 0) "candidate production battery failed: $($candidate.output)"
  foreach ($identity in @(
      "direct:fail-closed-guard-evidence",
      "discriminator:issue-6254",
      "discriminator:issue-9998",
      "discriminator:issue-9999"
    )) {
    Assert-BatteryTest ($candidate.output -match [regex]::Escape("RESULT identity=$identity exitCode=0 result=PASS")) `
      "candidate battery did not execute $identity green"
  }

  $source = Get-Content -LiteralPath (Join-Path $fixture.root ".orchestrator/controller-release-battery.ps1") -Raw
  $applied = 0
  $killed = 0
  foreach ($row in $batteryManifest) {
    $needle = "  `"$($row.planIdentity)`" = `$true"
    Assert-BatteryTest (@([regex]::Matches($source, [regex]::Escape($needle))).Count -eq 1) `
      "$($row.mutantId) did not match exactly one production inclusion seam"
    $mutantSource = $source.Replace($needle, "  `"$($row.planIdentity)`" = `$false")
    $mutantPath = Join-Path $fixture.root ".orchestrator/controller-release-battery.ps1"
    [IO.File]::WriteAllText($mutantPath, $mutantSource, [Text.UTF8Encoding]::new($false))
    & git -C $fixture.root add --all
    Assert-BatteryTest ($LASTEXITCODE -eq 0) "$($row.mutantId) git add failed"
    & git -C $fixture.root commit --quiet -m $row.mutantId
    Assert-BatteryTest ($LASTEXITCODE -eq 0) "$($row.mutantId) git commit failed"
    $fixture.head = (& git -C $fixture.root rev-parse HEAD 2>&1 | Out-String).Trim()
    New-MinimalReceipt $fixture.head $fixture.receipt
    $applied += 1
    $mutant = Invoke-BatteryProcess $mutantPath $fixture
    Assert-BatteryTest ($mutant.exitCode -ne 0 -and
      $mutant.output -match [regex]::Escape($row.signature)) `
      "$($row.mutantId) did not fail with $($row.signature): $($mutant.output)"
    if ($row.guardId -ceq "BATTERY-CHECKER-REQUIRED") {
      Assert-BatteryTest ($mutant.output -match [regex]::Escape(
          "RESULT identity=discriminator:issue-6254 exitCode=0 result=PASS"
        )) "direct-checker omission borrowed or skipped #6254 discriminator coverage"
    }
    $killed += 1
    Write-Host "CLAIM $($row.guardId) candidate=PASS mutant=$($row.mutantId):FAIL signature=$($row.signature)"
  }
  Assert-BatteryTest ($applied -eq 2 -and $killed -eq 2) "battery omission summary is not 2/2"
  return [pscustomobject]@{ applied = $applied; killed = $killed }
}

function Wait-BatteryCondition([scriptblock]$Condition, [int]$Seconds = 15) {
  $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
  do {
    if (& $Condition) { return $true }
    Start-Sleep -Milliseconds 25
  } while ([DateTime]::UtcNow -lt $deadline)
  return $false
}

function Start-BatteryFixtureProcess($Fixture, [switch]$AdmissionOwned, [string]$SlotId = "") {
  $start = New-BatteryChildStartInfo $Fixture.root
  foreach ($argument in @(
      "-NoProfile", "-NonInteractive", "-File",
      (Join-Path $Fixture.root ".orchestrator/controller-release-battery.ps1"),
      "-ControllerRoot", $Fixture.root,
      "-ExpectedControllerHead", $Fixture.head,
      "-EvidenceReceiptPath", $Fixture.receipt
  )) { [void]$start.ArgumentList.Add($argument) }
  if ($AdmissionOwned) { [void]$start.ArgumentList.Add("-AdmissionOwned") }
  Set-NonAdmittedBatteryChildEnvironment $start
  if (-not [string]::IsNullOrWhiteSpace($SlotId)) {
    # The admission negative/continuation surface passes only its explicit test
    # token. Every omitted-token fresh acquisition remains fully scrubbed.
    $start.Environment["CHASE_SETS_HEAVY_SLOT_ID"] = $SlotId
  }
  return [Diagnostics.Process]::Start($start)
}

function Complete-BatteryFixtureProcess([Diagnostics.Process]$Process, [int]$Seconds = 30) {
  if (-not $Process.WaitForExit($Seconds * 1000)) {
    try { $Process.Kill($true) } catch {}
    throw "ASSERTION FAILED: battery fixture process did not exit"
  }
  return [pscustomobject]@{
    exitCode = $Process.ExitCode
    output = (($Process.StandardOutput.ReadToEnd() + "`n" + $Process.StandardError.ReadToEnd()).Trim())
  }
}

function Invoke-FixtureContender($Fixture) {
  $start = New-BatteryChildStartInfo $Fixture.root
  Set-NonAdmittedBatteryChildEnvironment $start
  $branch = (& git -C $Fixture.root branch --show-current 2>&1 | Out-String).Trim()
  $command = (Get-Command whoami.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
  foreach ($argument in @(
      "-NoProfile", "-NonInteractive", "-File",
      (Join-Path $Fixture.root ".orchestrator/invoke-heavy-verifier.ps1"),
      "-Gate", "verify:static",
      "-Worktree", $Fixture.root,
      "-Lane", (Split-Path -Leaf $Fixture.root),
      "-Branch", $branch,
      "-ClaimedHead", $Fixture.head,
      "-ContainerRoot", $testRoot,
      "-CommandPath", $command
    )) { [void]$start.ArgumentList.Add($argument) }
  return Complete-BatteryFixtureProcess ([Diagnostics.Process]::Start($start))
}

function Invoke-AdmissionSuite {
  $fixture = New-AdmissionFixture
  $batteryPath = Join-Path $fixture.root ".orchestrator/controller-release-battery.ps1"
  $readyPath = Join-Path $fixture.root ".orchestrator/admission-ready"
  $releasePath = Join-Path $fixture.root ".orchestrator/admission-release"
  $source = Get-Content -LiteralPath $batteryPath -Raw
  $seam = "  # BATTERY_ADMISSION_TEST_HOLD_SEAM"
  Assert-BatteryTest (@([regex]::Matches($source, [regex]::Escape($seam))).Count -eq 1) `
    "admission hold seam was not exact"
  $hold = @'
  [IO.File]::WriteAllText((Join-Path $controller ".orchestrator/admission-ready"), "ready", [Text.UTF8Encoding]::new($false))
  while (-not (Test-Path -LiteralPath (Join-Path $controller ".orchestrator/admission-release") -PathType Leaf)) {
    Start-Sleep -Milliseconds 25
  }
'@
  [IO.File]::WriteAllText($batteryPath, $source.Replace($seam, $hold.TrimEnd()), [Text.UTF8Encoding]::new($false))
  & git -C $fixture.root add --all
  Assert-BatteryTest ($LASTEXITCODE -eq 0) "admission fixture git add failed"
  & git -C $fixture.root commit --quiet -m "admission hold fixture"
  Assert-BatteryTest ($LASTEXITCODE -eq 0) "admission fixture git commit failed"
  $fixture.head = (& git -C $fixture.root rev-parse HEAD 2>&1 | Out-String).Trim()
  New-MinimalReceipt $fixture.head $fixture.receipt

  $forged = Start-BatteryFixtureProcess $fixture -AdmissionOwned -SlotId ("f" * 32)
  $forgedResult = Complete-BatteryFixtureProcess $forged
  Assert-BatteryTest ($forgedResult.exitCode -ne 0 -and
    $forgedResult.output -match "BATTERY_ADMISSION_OWNER_INVALID") `
    "forged admission continuation was not rejected: $($forgedResult.output)"
  Write-Output "PASS controller battery forged admission continuation refused"

  # r3 F3: a held PLATFORM coordination mutex never delays battery admission.
  # The battery is started while the test holds that mutex and must reach its
  # admitted hold within the ordinary bound; a shared key blocks it instead.
  $coordinationRoot = ([IO.Path]::GetFullPath($testRoot).TrimEnd('\','/')).ToUpperInvariant()
  $platformCoordination = [Threading.Mutex]::new($false, ("Global\chase-sets-heavy-verifier-" + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($coordinationRoot))).ToLowerInvariant()))
  Assert-BatteryTest ($platformCoordination.WaitOne(5000)) "test holds the platform coordination mutex"
  $batteryProcess = Start-BatteryFixtureProcess $fixture
  try {
    Assert-BatteryTest (Wait-BatteryCondition { Test-Path -LiteralPath $readyPath -PathType Leaf }) `
      "battery admission waited on the platform coordination mutex"
    Write-Output "PASS controller battery admitted while the platform coordination mutex is held"
  } finally {
    $platformCoordination.ReleaseMutex()
    $platformCoordination.Dispose()
  }
  $lockPath = Join-Path $testRoot ".orchestrator/controller-verify-lock.d"
  $ownerPath = Join-Path $lockPath "owner.json"
  $platformLockPath = Join-Path $testRoot ".orchestrator/verify-lock.d"
  Assert-BatteryTest (Wait-BatteryCondition {
      (Test-Path -LiteralPath $readyPath -PathType Leaf) -and
      (Test-Path -LiteralPath $ownerPath -PathType Leaf)
    }) "battery did not retain a published owner while live"
  $ownedRaw = [IO.File]::ReadAllText($ownerPath, [Text.Encoding]::UTF8)
  $owner = $ownedRaw | ConvertFrom-Json -DateKind String
  Assert-BatteryTest ($owner.gate -ceq "script-battery" -and $owner.state -ceq "started" -and
    $owner.head -ceq $fixture.head) "live battery owner was not exact"
  Write-Output "PASS controller battery retained exact live owner"

  $nested = Start-BatteryFixtureProcess $fixture
  $nestedResult = Complete-BatteryFixtureProcess $nested
  Assert-BatteryTest ($nestedResult.exitCode -ne 0 -and
    [IO.File]::ReadAllText($ownerPath, [Text.Encoding]::UTF8) -ceq $ownedRaw) `
    "nested battery entered or changed the live owner"
  Write-Output "PASS controller battery nested acquisition refused"

  # Todd ruling 2026-09-10: the platform heavy verifier and the controller
  # battery own separate slots. A platform verifier is admitted beside a live
  # battery, releases its own lock, and never touches the battery's owner.
  $contender = Invoke-FixtureContender $fixture
  Assert-BatteryTest ($contender.exitCode -eq 0 -and
    -not (Test-Path -LiteralPath $platformLockPath) -and
    [IO.File]::ReadAllText($ownerPath, [Text.Encoding]::UTF8) -ceq $ownedRaw) `
    "platform heavy verifier was blocked by, or changed, the live controller owner: $($contender.output)"
  Write-Output "PASS controller battery runs beside the platform verifier on its own slot"

  [IO.File]::WriteAllText($releasePath, "release", [Text.UTF8Encoding]::new($false))
  $success = Complete-BatteryFixtureProcess $batteryProcess
  Assert-BatteryTest ($success.exitCode -eq 0) "admitted battery did not complete green: $($success.output)"
  Assert-BatteryTest (Wait-BatteryCondition { -not (Test-Path -LiteralPath $lockPath) }) `
    "successful battery did not release its exact owner"
  Write-Output "PASS controller battery success released exact owner"

  $admittedContender = Invoke-FixtureContender $fixture
  Assert-BatteryTest ($admittedContender.exitCode -eq 0 -and
    -not (Test-Path -LiteralPath $lockPath)) "contender did not enter after release: $($admittedContender.output)"

  Remove-Item -LiteralPath $readyPath, $releasePath -Force
  $cancelled = Start-BatteryFixtureProcess $fixture
  Assert-BatteryTest (Wait-BatteryCondition { Test-Path -LiteralPath $readyPath -PathType Leaf }) `
    "cancellation battery did not reach admitted hold"
  $cancelOwner = Get-Content -LiteralPath $ownerPath -Raw | ConvertFrom-Json -DateKind String
  Stop-Process -Id ([int]$cancelOwner.childPid) -Force
  $cancelResult = Complete-BatteryFixtureProcess $cancelled
  Assert-BatteryTest ($cancelResult.exitCode -ne 0 -and
    (Wait-BatteryCondition { -not (Test-Path -LiteralPath $lockPath) })) `
    "cancelled battery retained its owner: $($cancelResult.output)"
  Write-Output "PASS controller battery cancellation released exact owner"

  Write-Output "PASS controller battery exact-owner admission blocks competitors and releases on success/cancellation"
}

function Write-BatterySuiteResult([string]$Head, [string]$OutPath) {
  Assert-BatteryTest (-not [string]::IsNullOrWhiteSpace($OutPath)) `
    "OmissionMutants receipt production requires -SuiteResultOut"
  $artifactRoot = [IO.Path]::GetFullPath((Join-Path $controllerRoot ".orchestrator/artifacts"))
  $resolvedOut = [IO.Path]::GetFullPath((Join-Path $controllerRoot $OutPath))
  Assert-BatteryTest ((Split-Path -Parent $resolvedOut).TrimEnd("\", "/") -ceq $artifactRoot.TrimEnd("\", "/")) `
    "suite result must be an immediate child of .orchestrator/artifacts"
  if (Test-Path -LiteralPath $resolvedOut) { Remove-Item -LiteralPath $resolvedOut -Force }

  $summary = Invoke-OmissionSuite
  Assert-BatteryTest ($summary.applied -eq 2 -and $summary.killed -eq 2) "battery suite did not reach 2/2"
  $claims = @($batteryManifest | ForEach-Object { New-BatteryClaim $_ })
  $expectedCount = 2
  $batteryText = Get-Content -LiteralPath $battery -Raw
  foreach($phrase in @('ResultPath','controller-battery-result/v1','rawLog','foreground-file-serial')){
    Assert-BatteryTest ($batteryText.Contains($phrase,[StringComparison]::Ordinal)) "battery result contract omits $phrase"
  }
  $suite = [ordered]@{
    schemaVersion = "fail-closed-guard-suite-result/v1"
    subject = [ordered]@{ controllerHead = $Head }
    suite = [ordered]@{ id = "release-battery"; expectedClaimCount = $expectedCount }
    execution = [ordered]@{
      runId = "release-battery-" + [guid]::NewGuid().ToString("N")
      executed = $true
      outcome = "pass"
    }
    claims = @($claims)
  }
  New-Item -ItemType Directory -Path $artifactRoot -Force | Out-Null
  $temporary = Join-Path $artifactRoot (".release-battery-" + [guid]::NewGuid().ToString("N") + ".tmp")
  try {
    [IO.File]::WriteAllText($temporary, ($suite | ConvertTo-Json -Depth 100), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $resolvedOut
  } finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
  }
  Write-Output "PASS release-battery suite artifact path=$resolvedOut runId=$($suite.execution.runId) head=$Head claims=$expectedCount"
}

try {
  Assert-BatteryTest ($batteryManifest.Count -eq 2) "battery manifest count is not 2"
  if ($ValidatePlanOnly) {
    Invoke-PlanControl
    Invoke-ScopeControl
    Write-Output "PASS controller-release-battery self-test ValidatePlanOnly"
    return
  }

  $liveHead = (& git -C $controllerRoot rev-parse HEAD 2>&1 | Out-String).Trim()
  Assert-BatteryTest ($LASTEXITCODE -eq 0 -and $liveHead -cmatch "^[a-f0-9]{40}$") "cannot resolve controller HEAD"
  if (-not $ExpectedControllerHead) { $ExpectedControllerHead = $liveHead }
  Assert-BatteryTest ($ExpectedControllerHead -ceq $liveHead) `
    "expected head $ExpectedControllerHead does not equal live controller HEAD $liveHead"

  if ($Scenario -ceq "All") {
    Invoke-PlanControl
    Invoke-ScopeControl
    Write-Output "PASS controller release battery tests All"
  } elseif ($Scenario -ceq "Admission") {
    Invoke-AdmissionSuite
  } elseif ($Scenario -ceq "InheritedAdmissionIsolation") {
    Test-InheritedAdmissionIsolation
  } else {
    Write-BatterySuiteResult $ExpectedControllerHead $SuiteResultOut
    Write-Output "PASS battery omission summary applied=2 killed=2 survivors=0 not-applied=0 retained-6254=green"
  }
} finally {
  if (Test-Path -LiteralPath $testRoot) {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd("\", "/")
    if ((Split-Path -Parent $resolved).TrimEnd("\", "/") -ne $temp -or
        (Split-Path -Leaf $resolved) -notlike "controller-release-battery-test-*") {
      throw "refusing unsafe battery-test cleanup target: $resolved"
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
  }
}
