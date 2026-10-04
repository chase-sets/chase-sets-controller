[CmdletBinding()]
param(
  [ValidateSet("All", "Admission", "OmissionMutants", "InheritedAdmissionIsolation", "HostLifecycle", "HostEntry", "ExactChildHost", "RenameReuse", "ReuseBaseline")]
  [string]$Scenario = "All",

  [string]$ExpectedControllerHead = "",

  [string]$SuiteResultOut = "",

  [string]$HostEvidencePrefix = "",

  [switch]$ValidatePlanOnly
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot 'routing-data-test-support.ps1')
$routingTestScope=Enter-RoutingDataTestScope
$controllerRoot = Split-Path -Parent $PSScriptRoot
$battery = Join-Path $PSScriptRoot "controller-release-battery.ps1"
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("controller-release-battery-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $testRoot | Out-Null
# #8102: synthetic fleet-holder helpers. Their lock directory lives under this
# test's temp root only; the live container's verify-lock.d is never touched.
. (Join-Path $PSScriptRoot "interrupted-integration-test-support.ps1")

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
  "routing-data.ps1",
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

function Set-InstalledBatteryHead([string]$SkillsRoot, [string]$Head) {
  $identityPath = Join-Path $SkillsRoot 'native-db/identity.json'
  [IO.Directory]::CreateDirectory((Split-Path -Parent $identityPath)) | Out-Null
  [IO.File]::WriteAllText($identityPath, (@{ head = $Head; digest = ('0' * 64) } | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
}

function Set-SyntheticBatterySkillsRoot($Fixture, [string]$SkillsRoot) {
  $batteryPath = Join-Path $Fixture.root '.orchestrator/controller-release-battery.ps1'
  $source = [IO.File]::ReadAllText($batteryPath).Replace("(Join-Path `$HOME '.claude/skills')", "'$($SkillsRoot.Replace("'", "''"))'")
  Assert-BatteryTest ($source -cne [IO.File]::ReadAllText($batteryPath)) 'synthetic skills-root default was not replaced'
  [IO.File]::WriteAllText($batteryPath, $source, [Text.UTF8Encoding]::new($false))
  & git -C $Fixture.root add -- .orchestrator/controller-release-battery.ps1
  & git -C $Fixture.root commit --quiet -m 'synthetic installed skills root'
  $Fixture.head = (& git -C $Fixture.root rev-parse HEAD | Out-String).Trim()
  New-MinimalReceipt $Fixture.head $Fixture.receipt
  Set-InstalledBatteryHead $SkillsRoot $Fixture.head
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
# - Invoke-8102BatteryLeg (named test battery-incomplete-under-measured-load)
#   launches only through Invoke-BatteryProcess, so it is scrubbed as well.

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
  Assert-BatteryTest (@($consumerInventory.consumers).Count-eq8-and@($consumerInventory.consumers.path)-cnotcontains'.orchestrator/controller-runtime-closure-census.ps1') `
    "controller review consumer census is not the closed exact eight-row set"
  $launcherConsumer=@($consumerInventory.consumers|Where-Object{$_.path-ceq'.orchestrator/dispatch-lane.ps1'})
  Assert-BatteryTest ($launcherConsumer.Count-eq1-and$launcherConsumer[0].symbol-ceq'Reduce-ControllerReleaseReview'-and
    $launcherConsumer[0].purpose-ceq'strict-controller-review-prelaunch'-and$launcherConsumer[0].ordinaryPrExemption-eq$true) `
    "controller review launcher consumer must bind the strict reducer and preserve ordinary PR exemption"
  Write-Output "PASS controller battery plan derives tracked tests/discriminators, includes direct checker, and prevents self-recursion"
}

function Invoke-ScopeControl {
  # Change scope: a baseline..candidate diff selects the impact scope; a
  # runtime file no test reaches, a battery change, or -Scope full selects the
  # full battery. All stay finite plan-only.
  $fixture = New-PlanFixture
  $receipt = Join-Path $fixture.root ".orchestrator/unused-plan-only.json"
  $skillsRoot = Join-Path $testRoot ('skills-' + [guid]::NewGuid().ToString('N'))
  Set-InstalledBatteryHead $skillsRoot $fixture.head
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
    -RepairIssue 4388 -RepairHistoryPath $repairHistory -SkillsRoot $skillsRoot `
    -EvidenceReceiptPath $receipt -ValidatePlanOnly 2>&1 | Out-String
  Assert-BatteryTest ($LASTEXITCODE -eq 0) "prose-scope plan validation failed: $output"
  Assert-BatteryTest ($output -match [regex]::Escape("BATTERY_SCOPE scope=impact")) "skill diff did not select the impact scope"
  Assert-BatteryTest ($output -notmatch [regex]::Escape("PLAN identity=test:finite-extra.test.ps1")) "impact scope still enrolled an unrelated test"
  foreach ($identity in @("test:controller-release-battery.test.ps1", "discriminator:issue-6254", "direct:fail-closed-guard-evidence")) {
    Assert-BatteryTest ($output -match [regex]::Escape("PLAN identity=$identity")) "impact scope omitted $identity"
  }
  [IO.File]::AppendAllText((Join-Path $fixture.root ".orchestrator/fail-closed-guard-evidence.ps1"), "`n# runtime touch`n", [Text.UTF8Encoding]::new($false))
  & git -C $fixture.root add --all
  & git -C $fixture.root commit --quiet -m "runtime change"
  $runtimeHead = (& git -C $fixture.root rev-parse HEAD 2>&1 | Out-String).Trim()
  # A non-installed ancestor without repair authority must not narrow this plan.
  $refusal = ''
  try {
    & (Join-Path $fixture.root '.orchestrator/controller-release-battery.ps1') `
      -ControllerRoot $fixture.root -ExpectedControllerHead $runtimeHead -BaselineHead $proseHead `
      -SkillsRoot $skillsRoot -ValidatePlanOnly 2>&1 | Out-Null
  } catch { $refusal = $_.Exception.Message }
  Assert-BatteryTest ($refusal -match 'BATTERY_BASELINE_NOT_INSTALLED') "non-installed ancestor accepted: $refusal"
  $installedPlan = & (Join-Path $fixture.root '.orchestrator/controller-release-battery.ps1') `
    -ControllerRoot $fixture.root -ExpectedControllerHead $runtimeHead -BaselineHead $fixture.head `
    -SkillsRoot $skillsRoot -ValidatePlanOnly 2>&1 | Out-String
  Assert-BatteryTest ($LASTEXITCODE -eq 0 -and $installedPlan -match 'BATTERY_PLAN_BEGIN') "installed baseline refused: $installedPlan"
  Remove-Item -LiteralPath (Join-Path $skillsRoot 'native-db/identity.json')
  $refusal = ''
  try {
    & (Join-Path $fixture.root '.orchestrator/controller-release-battery.ps1') `
      -ControllerRoot $fixture.root -ExpectedControllerHead $runtimeHead -BaselineHead $fixture.head `
      -SkillsRoot $skillsRoot -ValidatePlanOnly 2>&1 | Out-Null
  } catch { $refusal = $_.Exception.Message }
  Assert-BatteryTest ($refusal -match 'BATTERY_BASELINE_NOT_INSTALLED') "missing install record accepted: $refusal"
  [IO.File]::WriteAllText((Join-Path $skillsRoot 'native-db/identity.json'), (@{ head = $fixture.head } | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
  $refusal = ''
  try {
    & (Join-Path $fixture.root '.orchestrator/controller-release-battery.ps1') `
      -ControllerRoot $fixture.root -ExpectedControllerHead $runtimeHead -BaselineHead $fixture.head `
      -SkillsRoot $skillsRoot -ValidatePlanOnly 2>&1 | Out-Null
  } catch { $refusal = $_.Exception.Message }
  Assert-BatteryTest ($refusal -match 'BATTERY_BASELINE_NOT_INSTALLED') "malformed install record accepted: $refusal"
  Set-InstalledBatteryHead $skillsRoot $proseHead
  $repairPlan = & (Join-Path $fixture.root '.orchestrator/controller-release-battery.ps1') `
    -ControllerRoot $fixture.root -ExpectedControllerHead $runtimeHead -BaselineHead $fixture.head `
    -RepairIssue 4388 -RepairHistoryPath $repairHistory -SkillsRoot $skillsRoot -ValidatePlanOnly 2>&1 | Out-String
  Assert-BatteryTest ($LASTEXITCODE -eq 0 -and $repairPlan -match 'BATTERY_PLAN_BEGIN') "governing repair baseline refused: $repairPlan"
  Assert-BatteryTest ($repairPlan.Contains("REPAIR_RECEIPT issue=4388 head=$($fixture.head) reviewerAttempt=synthetic-repair-reviewer findingIds=F1") -and
    $repairPlan.Contains("REPAIR_INPUTS -RepairIssue=4388 -RepairHistoryPath=$repairHistory")) 'repair log must bind its receipt and original inputs without a result file'
  Set-InstalledBatteryHead $skillsRoot $proseHead
  $output = & (Join-Path $fixture.root ".orchestrator/controller-release-battery.ps1") `
    -ControllerRoot $fixture.root -ExpectedControllerHead $runtimeHead -BaselineHead $proseHead `
    -SkillsRoot $skillsRoot -EvidenceReceiptPath $receipt -ValidatePlanOnly 2>&1 | Out-String
  Assert-BatteryTest ($LASTEXITCODE -eq 0) "runtime impact plan validation failed: $output"
  Assert-BatteryTest ($output -match [regex]::Escape("BATTERY_SCOPE scope=impact") -and $output -match [regex]::Escape("reason=reached")) "tested runtime diff did not select the impact scope: $output"
  Assert-BatteryTest ($output -match [regex]::Escape("PLAN identity=test:fail-closed-guard-evidence.test.ps1")) "impact scope omitted the test that reads the changed runtime file"
  Assert-BatteryTest (@($output -split "\r?\n" | Where-Object { $_ -clike "PLAN identity=test:controller-release-battery.test.ps1 *-ValidatePlanOnly*" }).Count -eq 1) "a non-battery impact plan ran the full battery self-test"
  Assert-BatteryTest ($output -notmatch [regex]::Escape("PLAN identity=test:finite-extra.test.ps1")) "impact scope enrolled a test that reads nothing changed"
  $output = & (Join-Path $fixture.root ".orchestrator/controller-release-battery.ps1") `
    -ControllerRoot $fixture.root -ExpectedControllerHead $runtimeHead -BaselineHead $proseHead -Scope full `
    -SkillsRoot $skillsRoot -EvidenceReceiptPath $receipt -ValidatePlanOnly 2>&1 | Out-String
  Assert-BatteryTest ($LASTEXITCODE -eq 0 -and $output -match [regex]::Escape("BATTERY_SCOPE scope=full") -and $output -match [regex]::Escape("reason=requested")) "-Scope full did not select the full battery: $output"
  Assert-BatteryTest ($output -match [regex]::Escape("PLAN identity=test:finite-extra.test.ps1")) "full scope dropped a tracked test"
  # A generated name: this self-test's own source must not mention the orphan.
  $orphanName = "orphan" + [guid]::NewGuid().ToString("N") + ".ps1"
  [IO.File]::WriteAllText((Join-Path $fixture.root ".orchestrator/$orphanName"), 'Write-Output "no test reads this"', [Text.UTF8Encoding]::new($false))
  & git -C $fixture.root add --all
  & git -C $fixture.root commit --quiet -m "unreached runtime change"
  $orphanHead = (& git -C $fixture.root rev-parse HEAD 2>&1 | Out-String).Trim()
  Set-InstalledBatteryHead $skillsRoot $runtimeHead
  $output = & (Join-Path $fixture.root ".orchestrator/controller-release-battery.ps1") `
    -ControllerRoot $fixture.root -ExpectedControllerHead $orphanHead -BaselineHead $runtimeHead `
    -SkillsRoot $skillsRoot -EvidenceReceiptPath $receipt -ValidatePlanOnly 2>&1 | Out-String
  Assert-BatteryTest ($LASTEXITCODE -eq 0 -and $output -match [regex]::Escape("BATTERY_SCOPE scope=full") -and $output -match [regex]::Escape("reason=unreached:.orchestrator/$orphanName")) "a runtime file no test reaches did not force the full battery: $output"
  [IO.File]::AppendAllText((Join-Path $fixture.root ".orchestrator/controller-release-battery.ps1"), "`n# battery touch`n", [Text.UTF8Encoding]::new($false))
  & git -C $fixture.root add --all
  & git -C $fixture.root commit --quiet -m "battery change"
  $batteryHead = (& git -C $fixture.root rev-parse HEAD 2>&1 | Out-String).Trim()
  Set-InstalledBatteryHead $skillsRoot $orphanHead
  $output = & (Join-Path $fixture.root ".orchestrator/controller-release-battery.ps1") `
    -ControllerRoot $fixture.root -ExpectedControllerHead $batteryHead -BaselineHead $orphanHead `
    -SkillsRoot $skillsRoot -EvidenceReceiptPath $receipt -ValidatePlanOnly 2>&1 | Out-String
  # A battery change runs the impact scope with the battery's full self-test
  # (no -ValidatePlanOnly); every other impact plan keeps it plan-only.
  $selfTestPlan = @($output -split "\r?\n" | Where-Object { $_ -clike "PLAN identity=test:controller-release-battery.test.ps1 *" })
  Assert-BatteryTest ($LASTEXITCODE -eq 0 -and $output -match [regex]::Escape("BATTERY_SCOPE scope=impact") -and $output -match [regex]::Escape("reason=battery-changed") -and
    $selfTestPlan.Count -eq 1 -and -not $selfTestPlan[0].Contains("-ValidatePlanOnly")) "a battery change did not select impact with the full battery self-test: $output"
  Assert-BatteryTest ($output -notmatch [regex]::Escape("PLAN identity=test:finite-extra.test.ps1")) "a battery change enrolled a test that reads nothing changed"
  & git -C $fixture.root checkout --quiet --detach $runtimeHead
  Assert-BatteryTest ($LASTEXITCODE -eq 0) "could not return the scope fixture to the runtime head"
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
  foreach ($pair in @(
      @('-ControllerBatteryScope $Scope', '"-Scope", $ControllerBatteryScope'),
      @('-ControllerBatteryPriorResultPath $PriorResultPath', '"-PriorResultPath", $ControllerBatteryPriorResultPath'),
      @('-ControllerBatteryOnFailure $OnFailure', '"-OnFailure", $ControllerBatteryOnFailure')
    )) {
    Assert-BatteryTest ($batterySource -match [regex]::Escape($pair[0]) -and $verifierSource -match [regex]::Escape($pair[1])) "scope or prior result is dropped before the admitted child: $($pair[1])"
  }
  Write-Output "PASS controller battery initial/repair baselines select impact or full and malformed/nonancestor/nonBF repair authority fails closed"
}

function Invoke-ImpactControl {
  # Transitive readers select their tests, comment-only mentions do not, and a
  # contract reaches the tests of the code that reads it.
  $fixture = New-PlanFixture
  $receipt = Join-Path $fixture.root ".orchestrator/unused-plan-only.json"
  $skillsRoot = Join-Path $testRoot ('skills-' + [guid]::NewGuid().ToString('N'))
  $files = [ordered]@{
    "widget.ps1" = 'Write-Output "widget"'
    "widget-consumer.ps1" = '. (Join-Path $PSScriptRoot "widget.ps1"); Get-Content (Join-Path $PSScriptRoot "contracts/widget-v1.md")'
    "widget-consumer.test.ps1" = '& (Join-Path $PSScriptRoot "widget-consumer.ps1") | Out-Null; Write-Output "PASS widget consumer"'
    "comment-only.test.ps1" = "# widget-consumer and widget are named only in this comment`nWrite-Output `"PASS comment only`""
  }
  foreach ($name in $files.Keys) { [IO.File]::WriteAllText((Join-Path $fixture.root ".orchestrator/$name"), $files[$name], [Text.UTF8Encoding]::new($false)) }
  New-Item -ItemType Directory -Path (Join-Path $fixture.root ".orchestrator/contracts") -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $fixture.root ".orchestrator/contracts/widget-v1.md"), "widget contract`n", [Text.UTF8Encoding]::new($false))
  & git -C $fixture.root add --all
  & git -C $fixture.root commit --quiet -m "widget fixture"
  $baseHead = (& git -C $fixture.root rev-parse HEAD 2>&1 | Out-String).Trim()
  Set-InstalledBatteryHead $skillsRoot $baseHead
  foreach ($case in @(
      [ordered]@{ name = "transitive-code"; path = ".orchestrator/widget.ps1"; text = 'Write-Output "widget v2"' },
      [ordered]@{ name = "contract-reader"; path = ".orchestrator/contracts/widget-v1.md"; text = "widget contract v2`n" }
    )) {
    & git -C $fixture.root checkout --quiet --detach $baseHead
    [IO.File]::WriteAllText((Join-Path $fixture.root $case.path), $case.text, [Text.UTF8Encoding]::new($false))
    & git -C $fixture.root commit --quiet -am $case.name
    $caseHead = (& git -C $fixture.root rev-parse HEAD 2>&1 | Out-String).Trim()
    $output = & (Join-Path $fixture.root ".orchestrator/controller-release-battery.ps1") `
      -ControllerRoot $fixture.root -ExpectedControllerHead $caseHead -BaselineHead $baseHead `
      -SkillsRoot $skillsRoot -EvidenceReceiptPath $receipt -ValidatePlanOnly 2>&1 | Out-String
    Assert-BatteryTest ($LASTEXITCODE -eq 0 -and $output -match [regex]::Escape("BATTERY_SCOPE scope=impact")) "$($case.name): impact plan failed: $output"
    Assert-BatteryTest ($output -match [regex]::Escape("PLAN identity=test:widget-consumer.test.ps1")) "$($case.name): the reader's test was not selected"
    Assert-BatteryTest ($output -notmatch [regex]::Escape("PLAN identity=test:comment-only.test.ps1")) "$($case.name): a comment-only mention selected a test"
    Assert-BatteryTest ($output -notmatch [regex]::Escape("PLAN identity=test:finite-extra.test.ps1")) "$($case.name): an unrelated test was selected"
  }
  & git -C $fixture.root checkout --quiet --detach $baseHead
  & git -C $fixture.root mv .orchestrator/widget.ps1 .orchestrator/gadget.ps1
  [IO.File]::WriteAllText((Join-Path $fixture.root '.orchestrator/gadget.test.ps1'), 'Get-Content (Join-Path $PSScriptRoot "gadget.ps1") | Out-Null', [Text.UTF8Encoding]::new($false))
  & git -C $fixture.root add --all
  & git -C $fixture.root commit --quiet -m 'rename widget with stale caller'
  $renameHead = (& git -C $fixture.root rev-parse HEAD 2>&1 | Out-String).Trim()
  $output = & (Join-Path $fixture.root '.orchestrator/controller-release-battery.ps1') `
    -ControllerRoot $fixture.root -ExpectedControllerHead $renameHead -BaselineHead $baseHead `
    -SkillsRoot $skillsRoot -ValidatePlanOnly 2>&1 | Out-String
  Assert-BatteryTest ($LASTEXITCODE -eq 0 -and $output -match 'BATTERY_SCOPE scope=impact') "rename impact plan failed: $output"
  Assert-BatteryTest (($output -replace '\s+', ' ') -match 'IMPACT path=\.orchestrator/widget\.ps1 tests=[^ ]*widget-consumer\.test\.ps1' -and
    $output -match 'PLAN identity=test:widget-consumer\.test\.ps1') "renamed-away runtime path did not reach the stale caller: $output"
  Assert-BatteryTest ($output -match 'BATTERY_SCOPE scope=impact .* changed=3 ') "rename old/new paths not counted: $output"
  $batteryPath = Join-Path $fixture.root '.orchestrator/controller-release-battery.ps1'
  $source = [IO.File]::ReadAllText($batteryPath)
  Assert-BatteryTest (@([regex]::Matches($source, 'diff --no-renames --name-only')).Count -eq 2) 'rename diff mutant needs both calls'
  try {
    [IO.File]::WriteAllText($batteryPath, $source.Replace('diff --no-renames --name-only', 'diff --name-only'), [Text.UTF8Encoding]::new($false))
    $mutant = & $batteryPath -ControllerRoot $fixture.root -ExpectedControllerHead $renameHead `
      -BaselineHead $baseHead -SkillsRoot $skillsRoot -ValidatePlanOnly 2>&1 | Out-String
    Assert-BatteryTest ($mutant -notmatch 'PLAN identity=test:widget-consumer\.test.ps1' -and
      $mutant -notmatch 'IMPACT path=\.orchestrator/widget\.ps1') "old rename diff calls unexpectedly reached stale caller: $mutant"
  } finally {
    [IO.File]::WriteAllText($batteryPath, $source, [Text.UTF8Encoding]::new($false))
  }
  Write-Output 'PASS controller battery synthetic rename impact selects stale caller and old path'
  Write-Output "PASS controller battery impact scope follows code readers transitively, contract readers directly, and ignores comments"
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

function New-OmissionFixture([hashtable]$ExtraRuntimeFiles = @{}) {
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
  foreach ($name in @($ExtraRuntimeFiles.Keys)) {
    $extraPath = Join-Path $runtime $name
    [IO.Directory]::CreateDirectory((Split-Path -Parent $extraPath)) | Out-Null
    [IO.File]::WriteAllText($extraPath, $ExtraRuntimeFiles[$name], [Text.UTF8Encoding]::new($false))
  }
  $head = Initialize-GitRepository $root
  $receipt = Join-Path $runtime "minimal-receipt.json"
  New-MinimalReceipt $head $receipt
  return [pscustomobject]@{ root = $root; head = $head; receipt = $receipt }
}

function New-AdmissionFixture([hashtable]$ExtraRuntimeFiles = @{}, [string]$Prefix = "admission-") {
  $root = Join-Path $testRoot ($Prefix + [guid]::NewGuid().ToString("N"))
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
  foreach ($name in $ExtraRuntimeFiles.Keys) {
    [IO.File]::WriteAllText((Join-Path $runtime $name), $ExtraRuntimeFiles[$name], [Text.UTF8Encoding]::new($false))
  }
  $head = Initialize-GitRepository $root
  $receipt = Join-Path $runtime "minimal-receipt.json"
  New-MinimalReceipt $head $receipt
  return [pscustomobject]@{ root = $root; head = $head; receipt = $receipt }
}

function Invoke-BatteryProcess(
  [string]$BatteryPath,
  $Fixture,
  [string[]]$ExtraArguments = @()
) {
  $start = New-BatteryChildStartInfo $Fixture.root
  Set-NonAdmittedBatteryChildEnvironment $start
  foreach ($argument in @(
      "-NoProfile", "-NonInteractive", "-File", $BatteryPath,
      "-ControllerRoot", $Fixture.root,
      "-ExpectedControllerHead", $Fixture.head,
      "-EvidenceReceiptPath", $Fixture.receipt
    ) + $ExtraArguments) { [void]$start.ArgumentList.Add($argument) }
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
  Test-BatteryTimingAndTerminalResults
  Test-FailingBatteryResultWriteOmission
  Test-BatteryIncompleteUnderMeasuredLoad | ForEach-Object { Write-Host $_ }
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

function Assert-BatteryTiming($Value, [string]$Label) {
  foreach ($name in @('startedUtc', 'finishedUtc')) {
    $instant = $Value.$name
    $parsed = [DateTimeOffset]::MinValue
    Assert-BatteryTest ($instant -is [string] -and
      $instant -cmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$' -and
      [DateTimeOffset]::TryParse($instant, [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::None, [ref]$parsed)) "${Label}: invalid $name"
  }
  Assert-BatteryTest (($Value.elapsedMs -is [int] -or $Value.elapsedMs -is [long]) -and
    $Value.elapsedMs -ge 0) "${Label}: invalid elapsedMs"
}

function Assert-BatteryResultTiming($Leg) {
  $record = $Leg.record
  Assert-BatteryTest ($null -ne $record -and $record.schemaVersion -ceq 'controller-battery-result/v1' -and
    $record.controllerHead -ceq $Leg.fixture.head -and
    $record.execution.mode -ceq 'foreground-file-serial') 'battery timing record lost identity or serial mode'
  Assert-BatteryTiming $record.execution 'battery total'
  Assert-BatteryTest ($record.execution.requiredCount -eq $record.inventory.Count -and
    $record.execution.executedCount -eq $record.results.Count -and $record.execution.reusedCount -eq 0 -and
    $record.execution.satisfiedCount -eq $record.results.Count) 'battery result counts changed'
  $rawPath = Join-Path $Leg.fixture.root $record.rawLog.relativePath
  $rawBytes = [IO.File]::ReadAllBytes($rawPath)
  Assert-BatteryTest ($record.rawLog.kind -ceq 'raw-log' -and $record.rawLog.byteLength -eq $rawBytes.Length -and
    $record.rawLog.sha256 -ceq ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($rawBytes))).ToLowerInvariant()) `
    'battery raw log bytes/hash do not bind the written file'
  $rawLines = @([Text.Encoding]::UTF8.GetString($rawBytes) -split '\r?\n' | Where-Object { $_ -clike 'RESULT identity=*' })
  $resultLines = @($Leg.run.output -split '\r?\n' | Where-Object { $_ -clike 'RESULT identity=*' })
  Assert-BatteryTest ($resultLines.Count -eq $record.results.Count -and $rawLines.Count -eq $record.results.Count) `
    'timing must cover every executed item in stdout, raw log and JSON'
  for ($index = 0; $index -lt $record.results.Count; $index++) {
    $row = $record.results[$index]
    Assert-BatteryTiming $row $row.identity
    $expected = "RESULT identity=$($row.identity) exitCode=$($row.exitCode) result=$($row.result) fleetLoad=$($row.fleetLoad) startedUtc=$($row.startedUtc) finishedUtc=$($row.finishedUtc) elapsedMs=$($row.elapsedMs)"
    Assert-BatteryTest ($resultLines[$index] -ceq $expected -and $rawLines[$index] -ceq $expected -and
      $row.provenance.kind -ceq 'execution' -and $row.provenance.attempt -ceq 'local-battery') `
      "RESULT prefix, order, timing or provenance changed: $($row.identity)"
  }
  $recap = @($Leg.run.output -split '\r?\n' | Where-Object { $_ -clike 'TIMING identity=*' })
  $slowestFirst = @($record.results | Sort-Object -Property elapsedMs -Descending -Stable)
  Assert-BatteryTest ($recap.Count -eq $slowestFirst.Count) 'recap does not cover all executed items exactly once'
  for ($index = 0; $index -lt $slowestFirst.Count; $index++) {
    $row = $slowestFirst[$index]
    Assert-BatteryTest ($recap[$index] -ceq "TIMING identity=$($row.identity) startedUtc=$($row.startedUtc) finishedUtc=$($row.finishedUtc) elapsedMs=$($row.elapsedMs)") `
      'recap is not slowest-first or changed item timing'
  }
  $summaries = @($Leg.run.output -split '\r?\n' | Where-Object { $_ -clike 'PASS controller release battery head=*' })
  if ($record.execution.outcome -ceq 'PASS') {
    $execution = $record.execution
    $expected = "PASS controller release battery head=$($record.controllerHead) required=$($execution.requiredCount) executed=$($execution.executedCount) reused=$($execution.reusedCount) satisfied=$($execution.satisfiedCount) direct=1 tests=$(@($record.inventory | Where-Object identity -like 'test:*').Count) discriminators=$(@($record.inventory | Where-Object identity -like 'discriminator:*').Count) startedUtc=$($execution.startedUtc) finishedUtc=$($execution.finishedUtc) elapsedMs=$($execution.elapsedMs)"
    Assert-BatteryTest ($summaries.Count -eq 1 -and $summaries[0] -ceq $expected -and
      $Leg.run.output.IndexOf($recap[0], [StringComparison]::Ordinal) -gt
      $Leg.run.output.IndexOf($expected, [StringComparison]::Ordinal)) 'PASS summary totals or recap position changed'
  } else {
    Assert-BatteryTest ($summaries.Count -eq 0) 'non-PASS battery printed an installable PASS summary'
  }
  Assert-BatteryTest (@($Leg.run.output -split '\r?\n' | Where-Object { $_ -clike 'BATTERY_RESULT path=*' }).Count -eq 1) `
    'executed battery must publish exactly one result'
}

function Invoke-TimingBatteryLeg($Fixture, [string]$ResultPath = '') {
  if (-not $ResultPath) { $ResultPath = Join-Path $Fixture.root '.orchestrator/artifacts/8067-result.json' }
  $run = Invoke-BatteryProcess (Join-Path $Fixture.root '.orchestrator/controller-release-battery.ps1') $Fixture @('-ResultPath', $ResultPath)
  $record = if (Test-Path -LiteralPath $ResultPath -PathType Leaf) {
    Get-Content -LiteralPath $ResultPath -Raw | ConvertFrom-Json -DateKind String
  } else { $null }
  return [pscustomobject]@{ fixture = $Fixture; run = $run; resultPath = $ResultPath; record = $record }
}

function Assert-FailingBatteryResult($Leg, [string]$Signature) {
  Assert-BatteryTest (Test-Path -LiteralPath $Leg.resultPath -PathType Leaf) 'BATTERY_FAIL_RESULT_MISSING'
  Assert-BatteryTest ($Leg.run.exitCode -eq 1 -and $Leg.run.output.Contains('FAIL controller-release-battery:') -and
    $Leg.run.output.Contains($Signature) -and
    $Leg.record.execution.outcome -ceq 'FAIL' -and $Leg.record.failureCode -ceq $Signature) `
    "FAIL record, exit or terminal signature changed: $Signature"
}

function Replace-BatteryFixtureSource([string]$Source, [string]$Needle, [string]$Replacement) {
  Assert-BatteryTest ([regex]::Matches($Source, [regex]::Escape($Needle)).Count -eq 1) `
    "battery fixture mutation must match exactly once: $Needle"
  return $Source.Replace($Needle, $Replacement)
}

function Test-BatteryTimingAndTerminalResults {
  $source = [IO.File]::ReadAllText($battery).Replace("`r`n", "`n")
  $pass = Invoke-TimingBatteryLeg (New-AdmissionFixture)
  Assert-BatteryTest ($pass.run.exitCode -eq 0 -and $pass.record.execution.outcome -ceq 'PASS' -and
    $null -eq $pass.record.failureCode) 'battery-timing-pass fixture failed'
  Assert-BatteryResultTiming $pass
  Assert-BatteryTest ((@($pass.record.inventory.identity) -join '|') -ceq (@($pass.record.results.identity) -join '|')) `
    'timing changed selected execution order'

  $failureFiles = @{ 'finite-admission.test.ps1' = 'Write-Output "synthetic deliberate child failure"; exit 23' }
  $failed = Invoke-TimingBatteryLeg (New-AdmissionFixture $failureFiles)
  Assert-FailingBatteryResult $failed 'BATTERY_CHILD_FAILED:test:finite-admission.test.ps1'
  Assert-BatteryResultTiming $failed
  # Fail-fast (default): the first failure ends execution; the rest are named
  # as not run, and executed + not run covers the whole inventory.
  $afterFailure = @($failed.record.inventory.identity | Select-Object -Skip (1 + [Array]::IndexOf(@($failed.record.inventory.identity), 'test:finite-admission.test.ps1')))
  Assert-BatteryTest (@($failed.record.results | Where-Object { $_.identity -ceq 'test:finite-admission.test.ps1' -and $_.exitCode -eq 23 }).Count -eq 1 -and
    $afterFailure.Count -ge 1 -and (@($failed.record.execution.notRun) -join '|') -ceq ($afterFailure -join '|') -and
    $failed.record.results.Count + @($failed.record.execution.notRun).Count -eq $failed.record.inventory.Count -and
    $failed.run.output.Contains("NOT_RUN count=$($afterFailure.Count) after=test:finite-admission.test.ps1")) 'child FAIL did not stop at the failure and name the not-run remainder'
  $runAllFixture = New-AdmissionFixture $failureFiles
  $runAllPath = Join-Path $runAllFixture.root '.orchestrator/artifacts/run-all.json'
  $runAllRun = Invoke-BatteryProcess (Join-Path $runAllFixture.root '.orchestrator/controller-release-battery.ps1') $runAllFixture @('-ResultPath', $runAllPath, '-OnFailure', 'all')
  $runAll = [pscustomobject]@{ run = $runAllRun; record = (Get-Content -LiteralPath $runAllPath -Raw | ConvertFrom-Json -DateKind String) }
  Assert-BatteryTest ($runAll.run.exitCode -eq 1 -and $runAll.record.results.Count -eq $runAll.record.inventory.Count -and
    @($runAll.record.execution.notRun).Count -eq 0 -and $runAll.record.failureCode -ceq 'BATTERY_CHILD_FAILED:test:finite-admission.test.ps1') '-OnFailure all truncated the execution loop'

  $partialSource = Replace-BatteryFixtureSource $source '    $itemFleetLoad = Get-BatteryFleetLoad' `
    ('    if ($results.Count -eq 1) { Stop-Battery "SYNTHETIC_POST_START_FAILURE" }' + "`n" + '    $itemFleetLoad = Get-BatteryFleetLoad')
  $partial = Invoke-TimingBatteryLeg (New-AdmissionFixture @{ 'controller-release-battery.ps1' = $partialSource })
  Assert-FailingBatteryResult $partial 'SYNTHETIC_POST_START_FAILURE'
  Assert-BatteryResultTiming $partial
  Assert-BatteryTest ($partial.record.results.Count -eq 1 -and $partial.record.execution.requiredCount -eq 4) `
    'post-start exception did not preserve only the executed prefix'

  # Clock rollback changes wall instants only. The stopwatch remains authoritative.
  $clockSource = Replace-BatteryFixtureSource $source '$finishedUtc = [DateTime]::UtcNow.ToString("o")' '$finishedUtc = "2000-01-01T00:00:00.0000000Z"'
  $clock = Invoke-TimingBatteryLeg (New-AdmissionFixture @{ 'controller-release-battery.ps1' = $clockSource })
  Assert-BatteryTest ($clock.run.exitCode -eq 0 -and
    @($clock.record.results | Where-Object { $_.finishedUtc -cge $_.startedUtc }).Count -eq 0) 'clock-adjustment control did not reverse item wall instants'
  Assert-BatteryResultTiming $clock
  Assert-BatteryTest ($source.Contains('$itemClock = [Diagnostics.Stopwatch]::StartNew()') -and
    $source.Contains('elapsedMs = $itemClock.ElapsedMilliseconds') -and
    $source.Contains('$batteryClock = [Diagnostics.Stopwatch]::StartNew()') -and
    $source.Contains('elapsedMs = $batteryClock.ElapsedMilliseconds')) 'elapsed timing lost its monotonic source'
  foreach ($bad in @(
      @{ name = 'date-only'; field = 'startedUtc'; value = '2026-09-22' },
      @{ name = 'no-zone'; field = 'finishedUtc'; value = '2026-09-22T12:00:00.0000000' },
      @{ name = 'invalid-date'; field = 'finishedUtc'; value = '2026-99-22T12:00:00.0000000Z' },
      @{ name = 'negative-duration'; field = 'elapsedMs'; value = -1 },
      @{ name = 'fractional-duration'; field = 'elapsedMs'; value = 0.5 },
      @{ name = 'overflow-duration'; field = 'elapsedMs'; value = [decimal]::MaxValue }
    )) {
    $invalid = $pass.record.results[0] | ConvertTo-Json -Depth 10 | ConvertFrom-Json -DateKind String
    $invalid.($bad.field) = $bad.value
    $refusal = ''
    try { Assert-BatteryTiming $invalid $bad.name } catch { $refusal = $_.Exception.Message }
    Assert-BatteryTest ($refusal -ceq "ASSERTION FAILED: $($bad.name): invalid $($bad.field)") "timing assertion accepted $($bad.name)"
  }

  # Each mutation changes the named reconciliation input, not the refusing guard.
  $reconcile = '  $executed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)'
  foreach ($control in @(
      @{ name = 'duplicate'; needle = $reconcile; replacement = "  `$results.Add(`$results[0])`n$reconcile"; signature = 'BATTERY_RESULT_DUPLICATE:direct:fail-closed-guard-evidence' },
      @{ name = 'direct-omitted'; needle = '  "direct:fail-closed-guard-evidence" = $true'; replacement = '  "direct:fail-closed-guard-evidence" = $false'; signature = 'BATTERY_DIRECT_CHECKER_VALIDATION_OMITTED' },
      @{ name = 'discriminator-omitted'; needle = '  "discriminator:issue-6254" = $true'; replacement = '  "discriminator:issue-6254" = $false'; signature = 'BATTERY_DISCRIMINATOR_OMITTED:issue-6254' },
      @{ name = 'missing'; needle = $reconcile; replacement = "  `$results.RemoveAt(2)`n$reconcile"; signature = 'BATTERY_RESULT_MISSING:test:finite-admission.test.ps1' },
      @{ name = 'extra'; needle = $reconcile; replacement = "  [void]`$identitySet.Remove(`$results[0].identity)`n$reconcile"; signature = 'BATTERY_RESULT_EXTRA:direct:fail-closed-guard-evidence' },
      @{ name = 'count'; needle = '  if ($results.Count -ne $requiredItems.Count) {'; replacement = "  `$requiredItems.Add(`$requiredItems[0])`n  if (`$results.Count -ne `$requiredItems.Count) {"; signature = 'BATTERY_RESULT_COUNT_MISMATCH' }
    )) {
    $changed = Replace-BatteryFixtureSource $source $control.needle $control.replacement
    $leg = Invoke-TimingBatteryLeg (New-AdmissionFixture @{ 'controller-release-battery.ps1' = $changed })
    Assert-FailingBatteryResult $leg $control.signature
    Assert-BatteryTiming $leg.record.execution $control.name
    foreach ($row in $leg.record.results) { Assert-BatteryTiming $row $row.identity }
    Assert-BatteryTest ($leg.record.execution.measuredLoadCount -eq 0 -and
      $leg.run.output -cnotmatch '(?m)^PASS controller release battery head=') "reconciliation $($control.name) changed terminal precedence"
    Write-Host "PASS battery-failure-result-$($control.name) signature=$($control.signature)"
  }

  $markerSource = 'param([string]$Scenario, [string]$ExpectedControllerHead)' + "`n" +
    '[IO.File]::WriteAllText((Join-Path $PSScriptRoot "child-started"), "started")'
  $invalidFixture = New-AdmissionFixture @{ 'fail-closed-guard-evidence.test.ps1' = $markerSource }
  $invalidBattery = Join-Path $invalidFixture.root '.orchestrator/controller-release-battery.ps1'
  foreach ($path in @(
      (Join-Path $invalidFixture.root 'outside.json'),
      (Join-Path $invalidFixture.root '.orchestrator/artifacts/nested/result.json'),
      (Join-Path $invalidFixture.root '.orchestrator/artifacts/result.log')
    )) {
    $run = Invoke-BatteryProcess $invalidBattery $invalidFixture @('-ResultPath', $path)
    Assert-BatteryTest ($run.exitCode -eq 1 -and $run.output.Contains('BATTERY_RESULT_PATH_INVALID') -and
      $run.output -cnotmatch '(?m)^RESULT ' -and -not (Test-Path -LiteralPath $path) -and
      -not (Test-Path -LiteralPath (Join-Path $invalidFixture.root '.orchestrator/child-started'))) `
      'invalid ResultPath must refuse before any item starts or result is written'
  }
  $preExecutionPath = Join-Path $invalidFixture.root '.orchestrator/artifacts/pre-execution.json'
  $wrongHead = [pscustomobject]@{ root = $invalidFixture.root; receipt = $invalidFixture.receipt; head = ('f' * 40) }
  $refused = Invoke-BatteryProcess $invalidBattery $wrongHead @('-ResultPath', $preExecutionPath)
  Assert-BatteryTest ($refused.exitCode -eq 1 -and $refused.output.Contains('BATTERY_LIVE_HEAD_MOVED') -and
    -not (Test-Path -LiteralPath $preExecutionPath)) 'pre-execution refusal wrote a result'
  $plan = Invoke-BatteryProcess $invalidBattery $invalidFixture @('-ValidatePlanOnly', '-ResultPath', $preExecutionPath)
  Assert-BatteryTest ($plan.exitCode -eq 0 -and -not (Test-Path -LiteralPath $preExecutionPath) -and
    -not (Test-Path -LiteralPath (Join-Path $invalidFixture.root '.orchestrator/child-started'))) 'plan-only unexpectedly executed or wrote a result'
  $optionalFixture = New-AdmissionFixture
  $optional = Invoke-BatteryProcess (Join-Path $optionalFixture.root '.orchestrator/controller-release-battery.ps1') $optionalFixture
  Assert-BatteryTest ($optional.exitCode -eq 0 -and $optional.output -cnotmatch '(?m)^BATTERY_RESULT path=' -and
    -not (Test-Path -LiteralPath (Join-Path $optionalFixture.root '.orchestrator/artifacts')) ) 'optional no-ResultPath invocation changed'
  Write-Host 'PASS battery-timing-pass child-fail post-start-failure clock-adjustment timing-negatives reconciliation-refusals pre-execution no-result-path'
}

function Save-BatteryFixtureCommit($Fixture, [hashtable]$Files, [string]$Message) {
  foreach ($name in $Files.Keys) {
    [IO.File]::WriteAllText((Join-Path $Fixture.root ".orchestrator/$name"), $Files[$name], [Text.UTF8Encoding]::new($false))
    & git -C $Fixture.root add -- ".orchestrator/$name"
  }
  & git -C $Fixture.root commit --quiet -m $Message
  Assert-BatteryTest ($LASTEXITCODE -eq 0) "fixture commit failed: $Message"
  $head = (& git -C $Fixture.root rev-parse HEAD 2>&1 | Out-String).Trim()
  return [pscustomobject]@{ root = $Fixture.root; head = $head; receipt = $Fixture.receipt }
}

function Test-BatteryReuseAndBaseline {
  # Reuse: an unchanged passing test is lent from the prior result; the changed
  # test and guard items execute; a tampered raw log refuses reuse.
  $fixture = New-AdmissionFixture @{ "steady.test.ps1" = 'Write-Output "PASS steady"'; "changing.test.ps1" = 'Write-Output "PASS changing v1"' } "reuse-"
  $first = Invoke-TimingBatteryLeg $fixture (Join-Path $fixture.root ".orchestrator/artifacts/reuse-1.json")
  Assert-BatteryTest ($first.run.exitCode -eq 0 -and $first.record.execution.outcome -ceq "PASS") "reuse seed run failed: $($first.run.output)"
  $next = Save-BatteryFixtureCommit $fixture @{ "changing.test.ps1" = 'Write-Output "PASS changing v2"' } "change one test"
  $secondPath = Join-Path $fixture.root ".orchestrator/artifacts/reuse-2.json"
  $run = Invoke-BatteryProcess (Join-Path $fixture.root ".orchestrator/controller-release-battery.ps1") $next @("-ResultPath", $secondPath, "-PriorResultPath", $first.resultPath)
  $record = Get-Content -LiteralPath $secondPath -Raw | ConvertFrom-Json -DateKind String
  $byIdentity = @{}
  foreach ($row in @($record.results)) { $byIdentity[$row.identity] = $row }
  Assert-BatteryTest ($run.exitCode -eq 0 -and $record.execution.outcome -ceq "PASS") "reuse run failed: $($run.output)"
  Assert-BatteryTest ($byIdentity["test:steady.test.ps1"].provenance.kind -ceq "receipt-reuse" -and
    $byIdentity["test:steady.test.ps1"].provenance.priorHead -ceq $fixture.head) "unchanged passing test was not reused"
  foreach ($identity in @("test:changing.test.ps1", "direct:fail-closed-guard-evidence", "discriminator:issue-6254")) {
    Assert-BatteryTest ($byIdentity[$identity].provenance.kind -ceq "execution") "$identity was reused but must execute"
  }
  Assert-BatteryTest ($record.execution.reusedCount -ge 1 -and
    $record.execution.executedCount + $record.execution.reusedCount -eq $record.execution.satisfiedCount -and
    $record.execution.satisfiedCount -eq $record.execution.requiredCount) "reuse broke executed + reused = satisfied = required"
  Assert-BatteryTest ($run.output -match "PASS controller release battery head=$($next.head) required=\d+ executed=\d+ reused=$($record.execution.reusedCount) ") "PASS summary does not report reuse"
  $rawPath = Join-Path $fixture.root $first.record.rawLog.relativePath
  [IO.File]::AppendAllText($rawPath, "tampered`n")
  $tamperedPath = Join-Path $fixture.root ".orchestrator/artifacts/reuse-3.json"
  $tampered = Invoke-BatteryProcess (Join-Path $fixture.root ".orchestrator/controller-release-battery.ps1") $next @("-ResultPath", $tamperedPath, "-PriorResultPath", $first.resultPath)
  Assert-BatteryTest ($tampered.exitCode -ne 0 -and $tampered.output.Contains("BATTERY_PRIOR_RESULT_INVALID:RAW_LOG_MISMATCH")) "tampered prior raw log was accepted: $($tampered.output)"

  # Baseline: a failure that reproduces identically on the baseline is
  # PREEXISTING (still exit 1, never PASS); a failure new to the candidate is a
  # REGRESSION and keeps the ordinary child-failure signature.
  $known = 'throw "ASSERTION FAILED: known defect 4711 at $PSScriptRoot"'
  $fixture = New-AdmissionFixture @{ "known-bad.test.ps1" = $known } "baseline-"
  $skillsRoot = Join-Path $testRoot ('skills-' + [guid]::NewGuid().ToString('N'))
  Set-SyntheticBatterySkillsRoot $fixture $skillsRoot
  $candidate = Save-BatteryFixtureCommit $fixture @{ "steady.test.ps1" = 'Write-Output "PASS steady"' } "unrelated change"
  $preexistingPath = Join-Path $fixture.root ".orchestrator/artifacts/baseline-1.json"
  $run = Invoke-BatteryProcess (Join-Path $fixture.root ".orchestrator/controller-release-battery.ps1") $candidate @("-ResultPath", $preexistingPath, "-BaselineHead", $fixture.head, "-Scope", "full")
  $record = Get-Content -LiteralPath $preexistingPath -Raw | ConvertFrom-Json -DateKind String
  $knownRow = @($record.results | Where-Object identity -ceq "test:known-bad.test.ps1")
  Assert-BatteryTest ($run.exitCode -eq 1 -and $record.execution.outcome -ceq "FAIL_PREEXISTING_ONLY" -and
    $record.failureCode -ceq "BATTERY_PREEXISTING_ONLY:test:known-bad.test.ps1" -and
    $knownRow.Count -eq 1 -and $knownRow[0].baseline.classification -ceq "PREEXISTING" -and
    $run.output.Contains("FAIL_PREEXISTING_ONLY controller release battery head=$($candidate.head)") -and
    -not $run.output.Contains("PASS controller release battery")) "identical baseline failure was not PREEXISTING-only: $($run.output)"
  $regression = Save-BatteryFixtureCommit $fixture @{ "finite-admission.test.ps1" = 'throw "ASSERTION FAILED: new defect"' } "regress"
  $regressionPath = Join-Path $fixture.root ".orchestrator/artifacts/baseline-2.json"
  $run = Invoke-BatteryProcess (Join-Path $fixture.root ".orchestrator/controller-release-battery.ps1") $regression @("-ResultPath", $regressionPath, "-BaselineHead", $fixture.head, "-Scope", "full")
  $record = Get-Content -LiteralPath $regressionPath -Raw | ConvertFrom-Json -DateKind String
  $newRow = @($record.results | Where-Object identity -ceq "test:finite-admission.test.ps1")
  Assert-BatteryTest ($run.exitCode -eq 1 -and $record.execution.outcome -ceq "FAIL" -and
    $record.failureCode -ceq "BATTERY_CHILD_FAILED:test:finite-admission.test.ps1" -and
    $newRow[0].baseline.classification -ceq "REGRESSION") "a candidate-only failure was not a REGRESSION: $($run.output)"
  Assert-BatteryTest (@(Get-ChildItem -LiteralPath $testRoot -Directory -Filter "*-battery-baseline-*").Count -eq 0) "baseline worktree was not removed"

  # Proof-arm relevance: only an impact run exports the changed orchestrator
  # paths to its children; a full run clears them so every arm executes.
  $probe = 'Write-Output "IMPACT_ENV=[$env:CHASE_SETS_BATTERY_IMPACT_PATHS]"'
  $fixture = New-AdmissionFixture @{ "env-probe.test.ps1" = $probe } "impact-env-"
  $skillsRoot = Join-Path $testRoot ('skills-' + [guid]::NewGuid().ToString('N'))
  Set-SyntheticBatterySkillsRoot $fixture $skillsRoot
  $changed = Save-BatteryFixtureCommit $fixture @{ "env-probe.test.ps1" = ($probe + "`n# v2") } "probe change"
  foreach ($case in @(@{ scope = "impact"; expected = "IMPACT_ENV=[.orchestrator/env-probe.test.ps1]" }, @{ scope = "full"; expected = "IMPACT_ENV=[]" })) {
    $run = Invoke-BatteryProcess (Join-Path $fixture.root ".orchestrator/controller-release-battery.ps1") $changed @("-BaselineHead", $fixture.head, "-Scope", $case.scope)
    Assert-BatteryTest ($run.exitCode -eq 0 -and $run.output.Contains("CHILD identity=test:env-probe.test.ps1 $($case.expected)")) "$($case.scope) run exported the wrong impact list: $($run.output)"
  }
  Write-Output "PASS controller battery reuses unchanged passing tests, refuses tampered priors, and classifies PREEXISTING vs REGRESSION on the baseline"
}

function Test-RenameImpactAndReuse {
  $directTest = ('Write-Output "stable direct test fixture"' + "`n") * 8 +
    'Get-Content (Join-Path $PSScriptRoot "__PATH__") | Out-Null'
  $fixture = New-AdmissionFixture @{
    'foo.ps1' = 'Write-Output "foo"'
    'foo.test.ps1' = $directTest.Replace('__PATH__', 'foo.ps1')
    'caller.ps1' = 'Get-Content (Join-Path $PSScriptRoot "foo.ps1") | Out-Null'
    'caller.test.ps1' = 'Get-Content (Join-Path $PSScriptRoot "caller.ps1") | Out-Null; Write-Output "IMPACT_ENV=[$env:CHASE_SETS_BATTERY_IMPACT_PATHS]"'
  } 'rename-reuse-'
  $skillsRoot = Join-Path $testRoot ('skills-' + [guid]::NewGuid().ToString('N'))
  Set-SyntheticBatterySkillsRoot $fixture $skillsRoot
  $batteryPath = Join-Path $fixture.root '.orchestrator/controller-release-battery.ps1'
  $first = Invoke-TimingBatteryLeg $fixture (Join-Path $fixture.root '.orchestrator/artifacts/rename-prior.json')
  Assert-BatteryTest ($first.run.exitCode -eq 0) "rename reuse seed failed: $($first.run.output)"
  & git -C $fixture.root mv .orchestrator/foo.ps1 .orchestrator/bar.ps1
  & git -C $fixture.root mv .orchestrator/foo.test.ps1 .orchestrator/bar.test.ps1
  [IO.File]::WriteAllText((Join-Path $fixture.root '.orchestrator/bar.test.ps1'), $directTest.Replace('__PATH__', 'bar.ps1'), [Text.UTF8Encoding]::new($false))
  & git -C $fixture.root add -- .orchestrator/bar.test.ps1
  & git -C $fixture.root commit --quiet -m 'rename runtime and direct test, retain caller'
  $candidate = [pscustomobject]@{ root = $fixture.root; head = (& git -C $fixture.root rev-parse HEAD | Out-String).Trim(); receipt = $fixture.receipt }
  $impact = Invoke-BatteryProcess $batteryPath $candidate @('-BaselineHead', $fixture.head)
  Assert-BatteryTest ($impact.exitCode -eq 0 -and $impact.output -match 'BATTERY_SCOPE scope=impact .* changed=4 ') "rename impact omitted old/new paths: $($impact.output)"
  Assert-BatteryTest ($impact.output.Contains('CHILD identity=test:caller.test.ps1 IMPACT_ENV=[') -and
    $impact.output.Contains('.orchestrator/foo.ps1') -and $impact.output.Contains('.orchestrator/foo.test.ps1')) "rename impact omitted caller or old paths from child environment: $($impact.output)"
  $resultPath = Join-Path $fixture.root '.orchestrator/artifacts/rename-current.json'
  $reused = Invoke-BatteryProcess $batteryPath $candidate @('-Scope', 'full', '-PriorResultPath', $first.resultPath, '-ResultPath', $resultPath)
  $record = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -DateKind String
  $caller = @($record.results | Where-Object identity -ceq 'test:caller.test.ps1')
  Assert-BatteryTest ($reused.exitCode -eq 0 -and $caller.Count -eq 1 -and $caller[0].provenance.kind -ceq 'execution') "renamed-away file allowed stale caller test reuse: $($reused.output)"
  $source = [IO.File]::ReadAllText($batteryPath)
  Assert-BatteryTest (@([regex]::Matches($source, 'diff --no-renames --name-only')).Count -eq 2) 'reuse diff mutant needs both calls'
  try {
    [IO.File]::WriteAllText($batteryPath, $source.Replace('diff --no-renames --name-only', 'diff --name-only'), [Text.UTF8Encoding]::new($false))
    $mutantPath = Join-Path $fixture.root '.orchestrator/artifacts/rename-mutant.json'
    $mutant = Invoke-BatteryProcess $batteryPath $candidate @('-Scope', 'full', '-PriorResultPath', $first.resultPath, '-ResultPath', $mutantPath)
    $mutantRecord = Get-Content -LiteralPath $mutantPath -Raw | ConvertFrom-Json -DateKind String
    $mutantCaller = @($mutantRecord.results | Where-Object identity -ceq 'test:caller.test.ps1')
    Assert-BatteryTest ($mutant.exitCode -eq 0 -and $mutantCaller.Count -eq 1 -and
      $mutantCaller[0].provenance.kind -ceq 'receipt-reuse') "old rename diff calls did not reproduce stale caller reuse: $($mutant.output)"
  } finally {
    [IO.File]::WriteAllText($batteryPath, $source, [Text.UTF8Encoding]::new($false))
  }
  Write-Output 'PASS controller battery synthetic rename preserves old paths in impact environment and prevents stale caller reuse'
}

function Test-FailingBatteryResultWriteOmission {
  $mutantId = 'omit-failing-battery-result-write'
  $source = [IO.File]::ReadAllText($battery).Replace("`r`n", "`n")
  $writeBoundary = "try {`n  if (`$executionStarted -and `$resolvedResult) {"
  # The same committed fixture contains both orderings. Only this ignored
  # control file changes; source/head/receipt/arguments/result path stay fixed.
  $throwBeforeWrite = @'
if ($null -ne $batteryFailure -and (Test-Path -LiteralPath (Join-Path $controller '.git/omit-failing-battery-result-write'))) {
  throw $batteryFailure
}
'@
  $fixtureSource = Replace-BatteryFixtureSource $source $writeBoundary ($throwBeforeWrite + "`n" + $writeBoundary)
  $fixture = New-AdmissionFixture @{
    'controller-release-battery.ps1' = $fixtureSource
    'finite-admission.test.ps1' = 'Write-Output "synthetic deliberate child failure"; exit 23'
  }
  $batteryPath = Join-Path $fixture.root '.orchestrator/controller-release-battery.ps1'
  $sourceHash = (Get-FileHash -LiteralPath $batteryPath -Algorithm SHA256).Hash
  $receiptHash = (Get-FileHash -LiteralPath $fixture.receipt -Algorithm SHA256).Hash
  $signature = 'BATTERY_CHILD_FAILED:test:finite-admission.test.ps1'
  $artifactDirectory = Join-Path $fixture.root '.orchestrator/artifacts'
  [IO.Directory]::CreateDirectory($artifactDirectory) | Out-Null
  $unrelatedPayload = Join-Path $artifactDirectory 'unrelated.txt'
  [IO.File]::WriteAllText($unrelatedPayload, 'not a battery result')
  $candidate = Invoke-TimingBatteryLeg $fixture
  Assert-FailingBatteryResult $candidate $signature
  Assert-BatteryResultTiming $candidate
  Remove-Item -LiteralPath $candidate.resultPath, ([IO.Path]::ChangeExtension($candidate.resultPath, '.log')) -Force
  [IO.File]::WriteAllText((Join-Path $fixture.root '.git/omit-failing-battery-result-write'), 'omit')
  $mutant = Invoke-TimingBatteryLeg $fixture $candidate.resultPath
  Assert-BatteryTest ($mutant.run.exitCode -eq $candidate.run.exitCode -and
    $mutant.run.output.Contains($signature) -and
    -not (Test-Path -LiteralPath $mutant.resultPath) -and
    @($mutant.run.output -split '\r?\n' | Where-Object { $_ -clike 'RESULT identity=*' }).Count -eq $candidate.record.results.Count) `
    "$mutantId did not reach the identical executed child failure without a result"
  $candidateResults = @($candidate.run.output -split '\r?\n' | Where-Object { $_ -clike 'RESULT identity=*' } | ForEach-Object { $_ -creplace ' startedUtc=.*$', '' })
  $mutantResults = @($mutant.run.output -split '\r?\n' | Where-Object { $_ -clike 'RESULT identity=*' } | ForEach-Object { $_ -creplace ' startedUtc=.*$', '' })
  Assert-BatteryTest (($candidateResults -join "`n") -ceq ($mutantResults -join "`n")) 'write omission changed executed identities, order, exits, results or fleet load'
  $assertionFailure = ''
  try { Assert-FailingBatteryResult $mutant $signature } catch { $assertionFailure = $_.Exception.Message }
  Assert-BatteryTest ($assertionFailure -ceq 'ASSERTION FAILED: BATTERY_FAIL_RESULT_MISSING') `
    "$mutantId did not fail the candidate's same result-presence assertion"
  Assert-BatteryTest (Test-Path -LiteralPath $unrelatedPayload -PathType Leaf) `
    'omission control must retain a nonempty artifact directory without the canonical result'
  Assert-BatteryTest ((Get-FileHash -LiteralPath $batteryPath -Algorithm SHA256).Hash -ceq $sourceHash -and
    (Get-FileHash -LiteralPath $fixture.receipt -Algorithm SHA256).Hash -ceq $receiptHash -and
    (& git -C $fixture.root rev-parse HEAD | Out-String).Trim() -ceq $fixture.head) 'omission control changed frozen source, head or receipt'
  Write-Host "CLAIM BATTERY-FAIL-RESULT-WRITTEN candidate=PASS mutant=${mutantId}:FAIL signature=BATTERY_FAIL_RESULT_MISSING"
}

# ---- #8102 AC2 named test: battery-incomplete-under-measured-load ----
# The synthetic omission fixture gets one extra timed-fixture stand-in that
# exits 75 with a MEASURED_LOAD line, run as a scrubbed, non-admitted battery
# child while a synthetic verify-lock.d holder under $testRoot is live.
function Invoke-8102BatteryLeg([string]$Label, [hashtable]$ExtraRuntimeFiles, [string[]]$ExtraArguments = @()) {
  # The #6254 discriminator has required the legacy non-PR review fixture since
  # 43308dc; the shared omission inventory above does not carry it, so these
  # legs supply it themselves and leave the other scenarios' fixture unchanged.
  $legFiles = @{ "fixtures/legacy-non-pr-review-history.jsonl" = [IO.File]::ReadAllText((Join-Path $PSScriptRoot "fixtures/legacy-non-pr-review-history.jsonl")) }
  foreach ($name in @($ExtraRuntimeFiles.Keys)) { $legFiles[$name] = $ExtraRuntimeFiles[$name] }
  $fixture = New-OmissionFixture $legFiles
  $resultPath = Join-Path $fixture.root ".orchestrator/artifacts/8102-$Label.json"
  $run = Invoke-BatteryProcess (Join-Path $fixture.root ".orchestrator/controller-release-battery.ps1") $fixture (@("-ResultPath", $resultPath) + $ExtraArguments)
  $lines = @($run.output -split "\r?\n")
  $record = if (Test-Path -LiteralPath $resultPath) { Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -DateKind String } else { $null }
  $outcome = if ($record) { $record.execution.outcome } else { "NO_RECORD" }
  # Write-Host keeps the leg object the function's only pipeline output.
  Write-Host "CONTROL 8102 battery-incomplete-under-measured-load $Label exit=$($run.exitCode) outcome=$outcome fleetLoad=$(if ($record) { $record.fleetLoad } else { '' }) result=$resultPath"
  return [pscustomobject]@{
    label = $Label; fixture = $fixture; run = $run; lines = $lines; record = $record; resultPath = $resultPath
    resultLines = @($lines | Where-Object { $_ -clike "RESULT identity=*" })
  }
}
function Test-BatteryIncompleteUnderMeasuredLoad {
  $test = "battery-incomplete-under-measured-load"
  $probeName = "measured-load-probe.test.ps1"
  $probe = @{ $probeName = 'Write-Output "MEASURED_LOAD synthetic-probe fleetHolder=synthetic elapsedSeconds=31 boundSeconds=30"' + "`nexit 75`n" }
  # Leg A: one MEASURED_LOAD item while a live synthetic holder holds the slot.
  $holder = $null
  try {
    $holder = Start-SyntheticFleetHolder $testRoot
    $identity = $holder.identity
    $loaded = Invoke-8102BatteryLeg "measured-held" $probe
  } finally { Stop-SyntheticFleetHolder $holder }
  Assert-BatteryTest ($loaded.run.exitCode -eq 75) "${test}: battery with one MEASURED_LOAD item did not exit 75: exit=$($loaded.run.exitCode) $($loaded.run.output)"
  Assert-BatteryTest (@($loaded.lines | Where-Object { $_ -ceq "INCOMPLETE_MEASURED_LOAD controller release battery head=$($loaded.fixture.head) measured=test:$probeName fleetLoad=$identity" }).Count -eq 1) "${test}: INCOMPLETE_MEASURED_LOAD line missing or wrong: $($loaded.run.output)"
  Assert-BatteryTest (@($loaded.lines | Where-Object { $_ -clike "PASS controller release battery*" }).Count -eq 0) "${test}: MEASURED_LOAD run printed the installable PASS line"
  Assert-BatteryTest (@($loaded.lines | Where-Object { $_ -clike "BATTERY_PLAN_BEGIN head=$($loaded.fixture.head) * fleetLoad=$identity" }).Count -eq 1) "${test}: plan line did not record the admission fleet load: $($loaded.run.output)"
  Assert-BatteryTest ($loaded.resultLines.Count -ge 6 -and @($loaded.resultLines | Where-Object { $_ -cnotlike "* fleetLoad=$identity startedUtc=*" }).Count -eq 0) "${test}: not every RESULT line records fleetLoad=${identity}: $($loaded.resultLines -join "`n")"
  Assert-BatteryTest (@($loaded.resultLines | Where-Object { $_ -clike "RESULT identity=test:$probeName exitCode=75 result=MEASURED_LOAD fleetLoad=$identity startedUtc=*" }).Count -eq 1) "${test}: probe item was not classified MEASURED_LOAD: $($loaded.resultLines -join "`n")"
  Assert-BatteryTest (@($loaded.resultLines | Where-Object { $_ -clike "* result=FAIL *" }).Count -eq 0 -and -not $loaded.run.output.Contains("BATTERY_CHILD_FAILED")) "${test}: MEASURED_LOAD was reported as FAIL"
  Assert-BatteryTest ($null -ne $loaded.record -and $loaded.record.execution.outcome -ceq "INCOMPLETE_MEASURED_LOAD" -and $loaded.record.execution.measuredLoadCount -eq 1 -and $loaded.record.fleetLoad -ceq $identity -and $loaded.record.execution.requiredCount -eq $loaded.resultLines.Count) "${test}: result record does not carry the INCOMPLETE_MEASURED_LOAD outcome and admission fleet load: $($loaded.resultPath)"
  $probeResult = @($loaded.record.results | Where-Object { $_.identity -ceq "test:$probeName" })
  Assert-BatteryTest ($probeResult.Count -eq 1 -and $probeResult[0].result -ceq "MEASURED_LOAD" -and $probeResult[0].exitCode -eq 75 -and
    @($loaded.record.results | Where-Object { $_.fleetLoad -cne $identity }).Count -eq 0 -and
    @($loaded.record.results | Where-Object { $_.result -ceq "PASS" }).Count -eq ($loaded.record.results.Count - 1)) "${test}: result record items do not carry per-item fleetLoad and exactly one MEASURED_LOAD item: $($loaded.resultPath)"
  # Leg B: the same battery with no MEASURED_LOAD item on a vacant fleet is unchanged.
  $vacant = Invoke-8102BatteryLeg "vacant" @{}
  Assert-BatteryTest ($vacant.run.exitCode -eq 0 -and @($vacant.lines | Where-Object { $_ -clike "PASS controller release battery head=$($vacant.fixture.head) *" }).Count -eq 1 -and @($vacant.lines | Where-Object { $_ -clike "*MEASURED_LOAD*" }).Count -eq 0) "${test}: vacant-fleet battery without a MEASURED_LOAD item is not the unchanged PASS: exit=$($vacant.run.exitCode) $($vacant.run.output)"
  Assert-BatteryTest (@($vacant.lines | Where-Object { $_ -clike "BATTERY_PLAN_BEGIN * fleetLoad=none" }).Count -eq 1 -and $vacant.resultLines.Count -ge 5 -and @($vacant.resultLines | Where-Object { $_ -cnotlike "* result=PASS fleetLoad=none startedUtc=*" }).Count -eq 0) "${test}: vacant-fleet battery did not record fleetLoad=none on the plan and every RESULT line: $($vacant.run.output)"
  Assert-BatteryTest ($null -ne $vacant.record -and $vacant.record.execution.outcome -ceq "PASS" -and $vacant.record.execution.measuredLoadCount -eq 0 -and $vacant.record.fleetLoad -ceq "none" -and @($vacant.record.results | Where-Object { $_.fleetLoad -cne "none" }).Count -eq 0) "${test}: vacant-fleet result record is not the unchanged PASS outcome: $($vacant.resultPath)"
  # Leg C: a stale owner.json (well-formed, but every identity already exited) is not load.
  $staleLock = $null
  try {
    $staleLock = Write-StaleFleetOwner $testRoot
    $stale = Invoke-8102BatteryLeg "stale-owner" @{}
  } finally { if ($staleLock -and (Test-Path -LiteralPath $staleLock)) { Remove-Item -LiteralPath $staleLock -Recurse -Force } }
  Assert-BatteryTest ($stale.run.exitCode -eq 0 -and $null -ne $stale.record -and $stale.record.execution.outcome -ceq "PASS" -and $stale.record.fleetLoad -ceq "none" -and @($stale.lines | Where-Object { $_ -clike "BATTERY_PLAN_BEGIN * fleetLoad=none" }).Count -eq 1 -and @($stale.resultLines | Where-Object { $_ -cnotlike "* fleetLoad=none startedUtc=*" }).Count -eq 0) "${test}: a stale owner.json was reported as fleet load: $($stale.run.output)"
  # Leg D: exit 75 without a MEASURED_LOAD line is FAIL (distinct code, battery exit 1), never INCOMPLETE_MEASURED_LOAD.
  $bare = Invoke-8102BatteryLeg "bare-75" @{ "bare-exit-75.test.ps1" = 'Write-Output "synthetic bare exit 75"' + "`nexit 75`n" }
  Assert-BatteryTest ($bare.run.exitCode -eq 1 -and @($bare.lines | Where-Object { $_ -clike "RESULT identity=test:bare-exit-75.test.ps1 exitCode=75 result=FAIL fleetLoad=none startedUtc=*" }).Count -eq 1 -and $bare.run.output.Contains("BATTERY_CHILD_FAILED:test:bare-exit-75.test.ps1") -and @($bare.lines | Where-Object { $_ -clike "INCOMPLETE_MEASURED_LOAD*" }).Count -eq 0) "${test}: exit 75 without a MEASURED_LOAD line was not FAIL exit=1: exit=$($bare.run.exitCode) $($bare.run.output)"
  Assert-FailingBatteryResult $bare 'BATTERY_CHILD_FAILED:test:bare-exit-75.test.ps1'
  # Leg E: a genuine FAIL still wins when a measured-load item also ran.
  $holder = $null
  try {
    $holder = Start-SyntheticFleetHolder $testRoot
    $mixedIdentity = $holder.identity
    # FAIL precedence over MEASURED_LOAD needs both items executed: run all.
    $mixed = Invoke-8102BatteryLeg 'mixed-fail-measured' @{
      $probeName = $probe[$probeName]
      'bare-exit-75.test.ps1' = 'Write-Output "synthetic bare exit 75"' + "`nexit 75`n"
    } @('-OnFailure', 'all')
  } finally { Stop-SyntheticFleetHolder $holder }
  Assert-FailingBatteryResult $mixed 'BATTERY_CHILD_FAILED:test:bare-exit-75.test.ps1'
  Assert-BatteryTest ($mixed.record.execution.measuredLoadCount -eq 1 -and $mixed.record.fleetLoad -ceq $mixedIdentity -and
    @($mixed.record.results | Where-Object { $_.fleetLoad -cne $mixedIdentity }).Count -eq 0 -and
    @($mixed.record.results | Where-Object { $_.result -ceq 'MEASURED_LOAD' -and $_.exitCode -eq 75 }).Count -eq 1 -and
    @($mixed.lines | Where-Object { $_ -clike 'INCOMPLETE_MEASURED_LOAD*' }).Count -eq 0) 'mixed FAIL/MEASURED_LOAD lost load evidence or FAIL precedence'
  foreach ($leg in @($loaded, $vacant, $stale, $bare, $mixed)) { Assert-BatteryResultTiming $leg }
  Write-Output "PASS 8102 $test held-measured=INCOMPLETE_MEASURED_LOAD(75) vacant=PASS(0) stale-owner=none bare-75=FAIL(1) mixed=FAIL(1) timing=retained"
}

# #8184 fixtures keep host declarations in Git, not a production override.
function Set-HostDeclaration([string]$Source, [string]$Declaration) {
  $pattern = '(?m)^\$batteryHostPath = [^\r\n]*'
  if ([regex]::IsMatch($Source, $pattern)) {
    return [regex]::Replace($Source, $pattern, [Text.RegularExpressions.MatchEvaluator]{ param($m) $Declaration })
  }
  return $Source.Replace('$ErrorActionPreference = "Stop"', ('$ErrorActionPreference = "Stop"' + "`r`n" + $Declaration))
}

function New-HostDeclaration([string]$Path) {
  return "`$batteryHostPath = '$($Path.Replace("'", "''"))'"
}

function Save-HostCandidate($Fixture, [string]$Source, [switch]$Dirty) {
  [IO.File]::WriteAllText((Join-Path $Fixture.root '.orchestrator/controller-release-battery.ps1'), $Source, [Text.UTF8Encoding]::new($false))
  if (-not $Dirty) {
    & git -C $Fixture.root add .orchestrator/controller-release-battery.ps1
    & git -C $Fixture.root commit --quiet --allow-empty -m 'synthetic host control'
    Assert-BatteryTest ($LASTEXITCODE -eq 0) 'host fixture commit failed'
    $Fixture.head = (& git -C $Fixture.root rev-parse HEAD | Out-String).Trim()
    New-MinimalReceipt $Fixture.head $Fixture.receipt
  }
}

function New-HostFixture {
  $fixture = New-AdmissionFixture -Prefix 'host fixture ' -ExtraRuntimeFiles @{
    'finite-admission.test.ps1' = @'
[IO.File]::AppendAllText((Join-Path $PSScriptRoot 'host-marker'), "marker\n")
Write-Output 'HOST_CHEAP_MARKER'
'@
  }
  $source = [IO.File]::ReadAllText((Join-Path $fixture.root '.orchestrator/controller-release-battery.ps1'))
  $source = Set-HostDeclaration $source (New-HostDeclaration (Get-Process -Id $PID).Path)
  Save-HostCandidate $fixture $source
  return $fixture
}

function Invoke-HostCase([string]$CaseName, [scriptblock]$Body) {
  try { & $Body; Write-Host "PASS $CaseName" } catch {
    $script:hostFailures.Add("${CaseName}: $($_.Exception.Message)")
    Write-Host "FAIL ${CaseName}: $($_.Exception.Message)"
  }
}

function Invoke-HostRun($Fixture, [string]$Label, [string]$Entry = 'Wrapper', [string]$Executable = '',
    [string]$LaunchPath = '', [string]$ParentPath = '', [string]$Token = '', [switch]$ReplaceOwner) {
  $resultPath = Join-Path $Fixture.root '.orchestrator/artifacts/host-result.json'
  $markerPath = Join-Path $Fixture.root '.orchestrator/host-marker'
  foreach ($path in @($resultPath, [IO.Path]::ChangeExtension($resultPath, '.log'), [IO.Path]::ChangeExtension($resultPath, '.timing.txt'), $markerPath)) {
    if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
  }
  $artifactDirectory = Split-Path -Parent $resultPath
  if (Test-Path -LiteralPath $artifactDirectory) { [IO.Directory]::Delete($artifactDirectory) }
  $start = New-BatteryChildStartInfo $Fixture.root
  Set-NonAdmittedBatteryChildEnvironment $start
  if ($Executable) { $start.FileName = $Executable }
  if ($LaunchPath) { $start.Environment['PATH'] = $LaunchPath }
  if ($Token) { $start.Environment['CHASE_SETS_HEAVY_SLOT_ID'] = $Token }
  [void]$start.Environment.Remove('BATTERY_HOST_LAUNCHED_PATH')
  $start.Environment['BATTERY_HOST_UNRELATED'] = 'preserved value with spaces'
  $batteryPath = Join-Path $Fixture.root '.orchestrator/controller-release-battery.ps1'
  $arguments = @('-ControllerRoot', $Fixture.root, '-ExpectedControllerHead', $Fixture.head,
    '-EvidenceReceiptPath', $Fixture.receipt, '-ResultPath', $resultPath)
  if ($Entry -eq 'Wrapper') {
    $scriptPath = Join-Path $testRoot 'installed/.orchestrator/invoke-heavy-verifier.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath)) {
      [IO.Directory]::CreateDirectory((Split-Path -Parent $scriptPath)) | Out-Null
      [IO.File]::Copy((Join-Path $PSScriptRoot 'invoke-heavy-verifier.ps1'), $scriptPath)
    }
    $branch = (& git -C $Fixture.root branch --show-current | Out-String).Trim()
    $arguments = @('-ControllerBattery', '-Worktree', $Fixture.root, '-Lane', 'host-fixture',
      '-Branch', $branch, '-ClaimedHead', $Fixture.head, '-ContainerRoot', $testRoot,
      '-ControllerBatteryEvidenceReceiptPath', $Fixture.receipt, '-ControllerBatteryResultPath', $resultPath)
    if ($ReplaceOwner) { $arguments += '-TestReplaceOwnerBeforeCleanup' }
  } else {
    $scriptPath = $batteryPath
    if ($Entry -eq 'Plan') {
      $arguments += '-ValidatePlanOnly'
      if ($Token) { $arguments += '-AdmissionOwned' }
    }
  }
  if ($Entry -eq 'AdmissionOwned' -or $ParentPath) {
    $launcher = Join-Path $Fixture.root '.orchestrator/host-launch.ps1'
    $preamble = if ($ParentPath) { "`$env:PATH = '$($ParentPath.Replace("'", "''"))'`r`n" } else { '' }
    if ($Entry -eq 'AdmissionOwned') {
      $preamble += @'
$lock = Join-Path (Split-Path -Parent $PSScriptRoot) '../.orchestrator/controller-verify-lock.d'
[IO.Directory]::CreateDirectory($lock) | Out-Null
$ownerPath = Join-Path $lock 'owner.json'
$env:CHASE_SETS_HEAVY_SLOT_ID = [guid]::NewGuid().ToString('N')
$self = Get-Process -Id $PID
$owner = [ordered]@{
  schemaVersion=4; lockId=$env:CHASE_SETS_HEAVY_SLOT_ID; gate='script-battery'; state='started'; identityMode='branch'
  worktree=(Split-Path -Parent $PSScriptRoot); head=$args[3]
  branch=(& git -C (Split-Path -Parent $PSScriptRoot) branch --show-current | Out-String).Trim()
  childPid=$PID; pid=$PID; processStartUtc=$self.StartTime.ToUniversalTime().ToString('o')
  childProcessStartUtc=$self.StartTime.ToUniversalTime().ToString('o')
}
$raw = $owner | ConvertTo-Json -Compress
[IO.File]::WriteAllText($ownerPath, $raw)
try {
  & (Join-Path $PSScriptRoot 'controller-release-battery.ps1') @args -AdmissionOwned
} finally {
  if ([IO.File]::ReadAllText($ownerPath) -ceq $raw) {
    Remove-Item -LiteralPath $ownerPath -Force
    [IO.Directory]::Delete([IO.Path]::GetFullPath($lock))
  }
}
'@
    } else {
      $preamble += "& '$($scriptPath.Replace("'", "''"))' @args`r`nexit `$LASTEXITCODE`r`n"
    }
    [IO.File]::WriteAllText($launcher, $preamble, [Text.UTF8Encoding]::new($false))
    $scriptPath = $launcher
  }
  foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $scriptPath) + $arguments) {
    [void]$start.ArgumentList.Add($argument)
  }
  $run = Complete-BatteryChildProcess ([Diagnostics.Process]::Start($start))
  $record = if (Test-Path -LiteralPath $resultPath) { [IO.File]::ReadAllText($resultPath) | ConvertFrom-Json } else { $null }
  $raw = if (Test-Path -LiteralPath ([IO.Path]::ChangeExtension($resultPath, '.log'))) {
    [IO.File]::ReadAllText([IO.Path]::ChangeExtension($resultPath, '.log'))
  } else { '' }
  if ($HostEvidencePrefix) {
    [IO.File]::WriteAllText("$HostEvidencePrefix-$Label.log", "exitCode=$($run.exitCode)`r`n$($run.output)")
    if ($record) {
      [IO.File]::Copy($resultPath, "$HostEvidencePrefix-$Label.json", $true)
      [IO.File]::WriteAllText("$HostEvidencePrefix-$Label-raw.log", $raw)
    }
  }
  Write-Host "CONTROL $Label entry=$Entry exit=$($run.exitCode) marker=$([int](Test-Path -LiteralPath $markerPath))"
  return [pscustomobject]@{ run=$run; record=$record; raw=$raw; resultPath=$resultPath; markerPath=$markerPath }
}

function Assert-HostGreen($Run, [string]$ExpectedPath) {
  Assert-BatteryTest ($Run.run.exitCode -eq 0) "host green failed: $($Run.run.output)"
  Assert-BatteryTest (@([regex]::Matches($Run.run.output, 'CHILD identity=test:finite-admission.test.ps1 HOST_CHEAP_MARKER')).Count -eq 1) 'cheap marker must run exactly once'
  Assert-BatteryTest ($null -ne $Run.record.hostIdentity) 'admitted result lacks hostIdentity'
  $identity = $Run.record.hostIdentity
  Assert-BatteryTest ([string]::Equals([IO.Path]::GetFullPath($ExpectedPath), $identity.expectedPath, [StringComparison]::OrdinalIgnoreCase)) 'expected path not bound to result'
  Assert-BatteryTest ([string]::Equals((Get-Process -Id $PID).Path, $identity.actualPath, [StringComparison]::OrdinalIgnoreCase)) 'actual path not bound to result'
  Assert-BatteryTest ($identity.sha256 -ceq (Get-FileHash -LiteralPath (Get-Process -Id $PID).Path -Algorithm SHA256).Hash.ToLowerInvariant()) 'host hash is not observed bytes'
  Assert-BatteryTest ($identity.byteLength -eq (Get-Item -LiteralPath (Get-Process -Id $PID).Path).Length) 'host length is not observed bytes'
  foreach ($key in @('expectedPath','actualPath','sha256','byteLength','ProductVersion','PSVersion','PSHOME','bundleVersion')) {
    Assert-BatteryTest (-not [string]::IsNullOrWhiteSpace([string]$identity.$key)) "host observation $key absent"
    Assert-BatteryTest ($Run.run.output.Contains("$key=$($identity.$key)") -and $Run.raw.Contains("$key=$($identity.$key)")) "host observation $key not bound to stdout/raw log"
  }
}

function Assert-HostRefused($Run, [string]$Code) {
  Assert-BatteryTest ($Run.run.exitCode -ne 0 -and $Run.run.output.Contains($Code)) "expected $Code, got exit=$($Run.run.exitCode): $($Run.run.output)"
  Assert-BatteryTest ($Run.run.output -notmatch 'BATTERY_PLAN_BEGIN|HOST_CHEAP_MARKER|HOST_DIRECT_DELEGATION') 'host refusal crossed a cheap boundary'
  Assert-BatteryTest (-not (Test-Path -LiteralPath $Run.resultPath) -and -not (Test-Path -LiteralPath $Run.markerPath)) 'refusal wrote child/result'
  Assert-BatteryTest (-not (Test-Path -LiteralPath ([IO.Path]::ChangeExtension($Run.resultPath, '.log')))) 'refusal wrote raw result'
  Assert-BatteryTest (-not (Test-Path -LiteralPath (Split-Path -Parent $Run.resultPath))) 'refusal created result directory'
}

function Test-BatteryHostLifecycle {
  $script:hostFailures = [Collections.Generic.List[string]]::new()
  $fixture = New-HostFixture
  $path = (Get-Process -Id $PID).Path
  $matching = [IO.File]::ReadAllText((Join-Path $fixture.root '.orchestrator/controller-release-battery.ps1'))
  $stalePath = Join-Path $testRoot 'stale pwsh.exe'
  [IO.File]::WriteAllText($stalePath, 'synthetic existing host, never executed')
  $stale = Set-HostDeclaration $matching (New-HostDeclaration $stalePath)
  $installedDir = Join-Path $testRoot 'installed/.orchestrator'
  [IO.Directory]::CreateDirectory($installedDir) | Out-Null
  [IO.File]::WriteAllText((Join-Path $installedDir 'controller-release-battery.ps1'), $stale)
  Invoke-HostCase 'battery-host-pin-lifecycle installed-stale/H-stale' {
    Save-HostCandidate $fixture $stale
    Assert-HostRefused (Invoke-HostRun $fixture 'lifecycle-stale') 'BATTERY_HOST_PATH_MISMATCH'
  }
  Invoke-HostCase 'battery-host-pin-lifecycle installed-stale/H-matching' {
    Save-HostCandidate $fixture $matching
    Assert-HostGreen (Invoke-HostRun $fixture 'lifecycle-match') $path
  }
  Invoke-HostCase 'battery-host-pin-lifecycle dirty-only matching' {
    Save-HostCandidate $fixture $stale
    Save-HostCandidate $fixture $matching -Dirty
    Assert-HostRefused (Invoke-HostRun $fixture 'lifecycle-dirty') 'BATTERY_HOST_PATH_MISMATCH'
  }
  Invoke-HostCase 'battery-host-pin-lifecycle pin-from-installed-copy mutant' {
    $needle = '& git -C $controller show "${ExpectedControllerHead}:.orchestrator/controller-release-battery.ps1"'
    Assert-BatteryTest ($matching.Contains($needle)) 'pin-from-installed-copy mutation not applied'
    $replacement = "Get-Content -LiteralPath '$((Join-Path $installedDir 'controller-release-battery.ps1').Replace("'", "''"))'"
    Save-HostCandidate $fixture ($matching.Replace($needle, $replacement))
    Assert-HostRefused (Invoke-HostRun $fixture 'mutant-installed') 'BATTERY_HOST_PATH_MISMATCH'
  }
  $diagnostic = $matching.Replace((New-HostDeclaration $path), ((New-HostDeclaration $path) + "`r`n`$batteryHostSha256 = '$('0' * 64)'"))
  Invoke-HostCase 'battery-host-pin-lifecycle digest-change green' {
    Save-HostCandidate $fixture $diagnostic
    $run = Invoke-HostRun $fixture 'digest-change'
    Assert-HostGreen $run $path
    Assert-BatteryTest ($run.record.hostIdentity.sha256 -cne ('0' * 64)) 'diagnostic literal became observed hash'
  }
  Invoke-HostCase 'battery-host-pin-lifecycle enforce-committed-digest mutant' {
    $needle = '$hostIdentity = Get-BatteryHostIdentity'
    Assert-BatteryTest ($diagnostic.Contains($needle)) 'enforce-committed-digest mutation not applied'
    $mutant = $diagnostic.Replace($needle, ($needle + "`r`nif (`$hostIdentity.sha256 -cne `$batteryHostSha256) { Stop-Battery 'BATTERY_HOST_DIGEST_MISMATCH' }"))
    Save-HostCandidate $fixture $mutant
    Assert-HostRefused (Invoke-HostRun $fixture 'mutant-digest') 'BATTERY_HOST_DIGEST_MISMATCH'
  }
  $declarations = [ordered]@{
    missing = '# no canonical path declaration'
    duplicate = (New-HostDeclaration $path) + "`r`n" + (New-HostDeclaration $path)
    scopedDuplicate = (New-HostDeclaration $path) + "`r`n" + (New-HostDeclaration $path).Replace('$batteryHostPath', '$script:batteryHostPath')
    typedDuplicate = (New-HostDeclaration $path) + "`r`n[string]" + (New-HostDeclaration $path)
    nonString = '`$batteryHostPath = 42'.TrimStart('`')
    relative = "`$batteryHostPath = 'pwsh.exe'"
    expression = "`$batteryHostPath = (Join-Path 'C:/test' 'pwsh.exe')"
    interpolated = '`$batteryHostPath = "$PSHOME/pwsh.exe"'.TrimStart('`')
    empty = "`$batteryHostPath = ''"
    nested = "if (`$true) { $(New-HostDeclaration $path) }"
  }
  foreach ($name in $declarations.Keys) {
    Invoke-HostCase "battery-host-pin-lifecycle invalid-$name" {
      Save-HostCandidate $fixture (Set-HostDeclaration $matching $declarations[$name])
      Assert-HostRefused (Invoke-HostRun $fixture "invalid-$name" 'Plan') 'BATTERY_HOST_PIN_INVALID'
    }
  }
  Invoke-HostCase 'battery-host-pin-lifecycle committed expression never evaluated' {
    $evaluationMarker = Join-Path $testRoot 'must-not-evaluate'
    $expression = "`$batteryHostPath = [IO.File]::WriteAllText('$($evaluationMarker.Replace("'", "''"))', 'evaluated')"
    Save-HostCandidate $fixture (Set-HostDeclaration $matching $expression)
    Save-HostCandidate $fixture $matching -Dirty
    Assert-HostRefused (Invoke-HostRun $fixture 'invalid-unevaluated' 'Plan') 'BATTERY_HOST_PIN_INVALID'
    Assert-BatteryTest (-not (Test-Path -LiteralPath $evaluationMarker)) 'committed expression was evaluated'
  }
  Invoke-HostCase 'battery-host-pin-lifecycle unreadable committed blob' {
    Save-HostCandidate $fixture $matching
    & git -C $fixture.root rm --cached .orchestrator/controller-release-battery.ps1 | Out-Null
    & git -C $fixture.root commit --quiet -m 'synthetic missing blob'
    $fixture.head = (& git -C $fixture.root rev-parse HEAD | Out-String).Trim()
    Assert-HostRefused (Invoke-HostRun $fixture 'invalid-unreadable' 'Plan') 'BATTERY_HOST_PIN_INVALID'
  }
  Assert-BatteryTest ($script:hostFailures.Count -eq 0) ($script:hostFailures -join "`n")
}

function Test-BatteryExactChildHost {
  $fixture = New-HostFixture
  $path = (Get-Process -Id $PID).Path
  $windowsApps = Join-Path $env:LOCALAPPDATA 'Microsoft/WindowsApps/pwsh.exe'
  # A tiny framework forwarding executable makes the same-basename control
  # deterministic without requiring a second PowerShell installation. Its
  # launched path travels to the observer so forwarding cannot hide the mutant.
  $shimDirectory = Join-Path $testRoot 'noncanonical host with spaces'
  [IO.Directory]::CreateDirectory($shimDirectory) | Out-Null
  $shimPath = Join-Path $shimDirectory 'pwsh.exe'
  $shimSourcePath = Join-Path $shimDirectory 'host.cs'
  $shimSource = @'
using System;
using System.Diagnostics;
using System.Linq;
class HostForwarder {
  static int Main(string[] args) {
    string launched = Process.GetCurrentProcess().MainModule.FileName;
    Console.WriteLine("HOST_FORWARDER launchedPath=" + launched);
    var start = new ProcessStartInfo(@"__HOST__");
    // Fixture arguments contain spaced paths, but no embedded quotes.
    start.Arguments = String.Join(" ", args.Select(arg => "\"" + arg + "\""));
    start.UseShellExecute = false;
    start.EnvironmentVariables["BATTERY_HOST_LAUNCHED_PATH"] = launched;
    using (var child = Process.Start(start)) { child.WaitForExit(); return child.ExitCode; }
  }
}
'@
  [IO.File]::WriteAllText($shimSourcePath, $shimSource.Replace('__HOST__', $path.Replace('"', '""')))
  $compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
  & $compiler /nologo /target:exe "/out:$shimPath" $shimSourcePath | Out-Host
  Assert-BatteryTest ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $shimPath)) 'synthetic forwarding host compilation failed'
  $nodeCommand = (Get-Command node.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
  $nodePath = (& $nodeCommand -p 'process.execPath' | Out-String).Trim()
  Assert-BatteryTest ($LASTEXITCODE -eq 0 -and [IO.Path]::IsPathFullyQualified($nodePath)) 'exact process.execPath unavailable'
  $runtime = Join-Path $fixture.root '.orchestrator'
  $grandchild = @'
[ordered]@{ actualPath=(Get-Process -Id $PID).Path; launchedPath=$env:BATTERY_HOST_LAUNCHED_PATH; PSHOME=$PSHOME; PSVersion=$PSVersionTable.PSVersion.ToString(); unrelated=$env:BATTERY_HOST_UNRELATED; slot=$env:CHASE_SETS_HEAVY_SLOT_ID } | ConvertTo-Json -Compress
'@
  [IO.File]::WriteAllText((Join-Path $runtime 'host-grandchild.ps1'), $grandchild)
  $node = @'
const {spawnSync} = require('node:child_process');
const child = spawnSync('pwsh.exe', ['-NoProfile', '-NonInteractive', '-File', process.argv[2]], {encoding:'utf8'});
console.log(JSON.stringify({nodePath:process.execPath, grandchild:child.status === 0 ? JSON.parse(child.stdout) : null, status:child.status, error:child.stderr}));
process.exit(child.status ?? 1);
'@
  [IO.File]::WriteAllText((Join-Path $runtime 'host-node.cjs'), $node)
  $observer = @'
$expected = '__EXPECTED__'
$expectedHome = '__HOME__'
$expectedVersion = '__VERSION__'
$observed = [ordered]@{ actualPath=(Get-Process -Id $PID).Path; launchedPath=$env:BATTERY_HOST_LAUNCHED_PATH; PSHOME=$PSHOME; PSVersion=$PSVersionTable.PSVersion.ToString(); unrelated=$env:BATTERY_HOST_UNRELATED; slot=$env:CHASE_SETS_HEAVY_SLOT_ID }
Write-Output ('HOST_CHILD ' + ($observed | ConvertTo-Json -Compress))
$node = & '__NODE__' (Join-Path $PSScriptRoot 'host-node.cjs') (Join-Path $PSScriptRoot 'host-grandchild.ps1') | Out-String
$nodeExit = $LASTEXITCODE
Write-Output ('HOST_NODE ' + $node.Trim())
$record = $node | ConvertFrom-Json
foreach ($identity in @($observed, $record.grandchild)) {
  if ($nodeExit -ne 0 -or $null -eq $identity -or ($identity.launchedPath -and $identity.launchedPath -ine $expected) -or
      $identity.actualPath -ine $expected -or $identity.PSHOME -ine $expectedHome -or
      $identity.PSVersion -cne $expectedVersion -or $identity.unrelated -cne 'preserved value with spaces' -or $identity.slot -cnotmatch '^[a-f0-9]{32}$') {
    Write-Output 'BATTERY_CHILD_HOST_IDENTITY_MISMATCH'
    exit 37
  }
}
[IO.File]::AppendAllText((Join-Path $PSScriptRoot 'host-marker'), "marker\n")
Write-Output 'HOST_CHEAP_MARKER'
'@
  $observer = $observer.Replace('__EXPECTED__', $path.Replace("'", "''")).Replace('__HOME__', $PSHOME.Replace("'", "''")).Replace('__VERSION__', $PSVersionTable.PSVersion.ToString()).Replace('__NODE__', $nodePath.Replace("'", "''"))
  [IO.File]::WriteAllText((Join-Path $runtime 'finite-admission.test.ps1'), $observer)
  & git -C $fixture.root add .orchestrator/finite-admission.test.ps1 .orchestrator/host-grandchild.ps1 .orchestrator/host-node.cjs
  $source = [IO.File]::ReadAllText((Join-Path $runtime 'controller-release-battery.ps1'))
  Save-HostCandidate $fixture $source
  $launchDirectories = [ordered]@{ synthetic=$shimDirectory }
  if (Test-Path -LiteralPath $windowsApps -PathType Leaf) {
    $launchDirectories.windowsapps = Split-Path -Parent $windowsApps
  } else { Write-Host 'SKIP battery-exact-child-host WindowsApps absent; synthetic forwarding host supplies both PATH greens' }
  foreach ($hostName in $launchDirectories.Keys) {
    $launchPath = $launchDirectories[$hostName] + ';' + $env:PATH
    $run = Invoke-HostRun $fixture "child-launch-$hostName-green" -LaunchPath $launchPath
    Assert-HostGreen $run $path
    Write-Host "PASS battery-exact-child-host $hostName-first launch PATH child/Node-grandchild canonical"
    $run = Invoke-HostRun $fixture "child-parent-$hostName-green" -ParentPath $launchPath
    Assert-HostGreen $run $path
    Write-Host "PASS battery-exact-child-host $hostName in-process parent PATH exact launch child/Node-grandchild canonical"
  }

  # Mutate the already-started battery's PATH, after the host has prepended its
  # PSHOME. Keep this injection identical for own-executable and PATH launches.
  $needle = '      $childOutput = & $item.executable @($item.arguments) 2>&1 | ForEach-Object {'
  Assert-BatteryTest ($source.Contains($needle)) 'child-host-from-path launch seam missing'
  $injectedPath = $shimDirectory + ';' + $env:PATH
  $injection = "      `$env:PATH = '$($injectedPath.Replace("'", "''"))'`r`n"
  $injected = $source.Replace($needle, ($injection + $needle))
  Save-HostCandidate $fixture $injected
  Assert-HostGreen (Invoke-HostRun $fixture 'child-own-exe-green') $path
  Write-Host 'PASS battery-exact-child-host same-basename in-process injection own-exe green'
  $mutant = $injected.Replace('$childOutput = & $item.executable', '$childOutput = & pwsh.exe')
  Save-HostCandidate $fixture $mutant
  $run = Invoke-HostRun $fixture 'mutant-child-host-from-path'
  Assert-BatteryTest ($run.run.exitCode -eq 1 -and $run.run.output.Contains('BATTERY_CHILD_HOST_IDENTITY_MISMATCH') -and
    $run.run.output.Contains('BATTERY_CHILD_FAILED:test:finite-admission.test.ps1') -and
    $run.run.output.Contains('RESULT identity=test:finite-admission.test.ps1 exitCode=37 result=FAIL')) 'child-host-from-path did not fail on the observer identity with exit propagation'
  Assert-BatteryTest ($run.record.execution.outcome -ceq 'FAIL') 'identity mutant lost normal failure result'
  Assert-BatteryTest ($run.run.output.Contains("HOST_FORWARDER launchedPath=$shimPath") -and
    $run.run.output.Contains('"launchedPath":')) 'forwarder launched path was not retained by the identity observer'
  Write-Host 'PASS battery-exact-child-host mutant=child-host-from-path:FAIL observer=BATTERY_CHILD_HOST_IDENTITY_MISMATCH childExit=37 batteryExit=1'
  Assert-BatteryTest (-not (Test-Path (Join-Path $testRoot '.orchestrator/controller-verify-lock.d'))) 'child mutant retained admission owner'
}

function Test-BatteryHostEntry {
  $script:hostFailures = [Collections.Generic.List[string]]::new()
  $fixture = New-HostFixture
  $path = (Get-Process -Id $PID).Path
  $matching = [IO.File]::ReadAllText((Join-Path $fixture.root '.orchestrator/controller-release-battery.ps1'))
  $different = Join-Path $testRoot 'different pwsh.exe'
  [IO.File]::WriteAllText($different, 'synthetic existing host, never executed')
  $directory = Join-Path $testRoot 'directory/pwsh.exe'
  [IO.Directory]::CreateDirectory($directory) | Out-Null
  $link = Join-Path $testRoot 'linked pwsh.exe'
  New-Item -ItemType SymbolicLink -Path $link -Target $path | Out-Null
  $cases = @(
    @{name='different';path=$different;code='BATTERY_HOST_PATH_MISMATCH'},
    @{name='missing';path=(Join-Path $testRoot 'missing pwsh.exe');code='BATTERY_HOST_CANONICAL_MISSING'},
    @{name='directory';path=$directory;code='BATTERY_HOST_CANONICAL_INVALID'},
    @{name='reparse';path=$link;code='BATTERY_HOST_CANONICAL_INVALID'}
  )
  foreach ($entry in @('Wrapper','Direct','AdmissionOwned','Plan')) {
    # Intercept only direct delegation: otherwise its second battery check masks
    # the bypass mutant at the first entry. Other entries use real admission.
    $wrapper = Join-Path $fixture.root '.orchestrator/invoke-heavy-verifier.ps1'
    [IO.File]::WriteAllText($wrapper, "Write-Output 'HOST_DIRECT_DELEGATION'`r`nexit 0")
    Invoke-HostCase "battery-host-entry $entry matching" {
      Save-HostCandidate $fixture $matching
      $run = Invoke-HostRun $fixture "entry-$entry-green" $entry
      Assert-BatteryTest ($run.run.exitCode -eq 0) "matching $entry failed: $($run.run.output)"
      if ($entry -eq 'Direct') { Assert-BatteryTest ($run.run.output.Contains('HOST_DIRECT_DELEGATION')) 'direct did not delegate' }
      elseif ($entry -eq 'Plan') {
        Assert-BatteryTest ($run.run.output.Contains('BATTERY_PLAN_BEGIN') -and -not (Test-Path $run.resultPath) -and -not (Test-Path $run.markerPath)) 'plan-only side effects or no plan'
      } else { Assert-HostGreen $run $path }
    }
    foreach ($case in $cases) {
      Invoke-HostCase "battery-host-entry $entry $($case.name)" {
        Save-HostCandidate $fixture (Set-HostDeclaration $matching (New-HostDeclaration $case.path))
        $run = Invoke-HostRun $fixture "entry-$entry-$($case.name)" $entry
        Assert-HostRefused $run $case.code
        foreach ($field in @('expectedPath=','actualPath=','sha256=','byteLength=','ProductVersion=','PSVersion=','PSHOME=','bundleVersion=','canonicalCommand=')) {
          Assert-BatteryTest ($run.run.output.Contains($field)) "refusal lacks $field"
        }
        if ($case.name -eq 'missing') {
          Assert-BatteryTest ($run.run.output.IndexOf('BATTERY_HOST_CANONICAL_MISSING') -lt $run.run.output.IndexOf('BATTERY_HOST_PATH_MISMATCH')) 'missing is not primary before path mismatch'
        }
        Assert-BatteryTest (-not (Test-Path (Join-Path $testRoot '.orchestrator/controller-verify-lock.d'))) 'refusal retained own fixture owner'
      }
    }
    Invoke-HostCase "battery-host-entry $entry bypass-battery-host-check mutant" {
      $needle = '$hostIdentity = Get-BatteryHostIdentity'
      Assert-BatteryTest ($matching.Contains($needle)) 'bypass-battery-host-check mutation not applied'
      $source = Set-HostDeclaration $matching (New-HostDeclaration $different)
      Save-HostCandidate $fixture ($source.Replace($needle, '$hostIdentity = $null'))
      $run = Invoke-HostRun $fixture "mutant-bypass-$entry" $entry
      Assert-BatteryTest ($run.run.exitCode -eq 0) "bypass masked at ${entry}: $($run.run.output)"
      $boundary = if ($entry -eq 'Direct') { 'HOST_DIRECT_DELEGATION' } elseif ($entry -eq 'Plan') { 'BATTERY_PLAN_BEGIN' } else { 'HOST_CHEAP_MARKER' }
      Assert-BatteryTest ($run.run.output.Contains($boundary)) "bypass did not reach $boundary"
      $caught = $false
      try { Assert-HostRefused $run 'BATTERY_HOST_PATH_MISMATCH' } catch { $caught = $_.Exception.Message.StartsWith('ASSERTION FAILED:') }
      Assert-BatteryTest $caught 'bypass mutant survived the paired refusal assertion'
    }
  }
  Invoke-HostCase 'battery-host-entry normalized absolute case/slash green' {
    Save-HostCandidate $fixture (Set-HostDeclaration $matching (New-HostDeclaration ($path.ToUpperInvariant().Replace('\','/'))))
    Assert-HostGreen (Invoke-HostRun $fixture 'normalized-green') $path
  }
  Invoke-HostCase 'battery-host-entry unavailable observations still admit' {
    $source = $matching.Replace('try { $identity.sha256 =', "try { throw 'synthetic unreadable observation'; `$identity.sha256 =")
    $source = $source.Replace('try { $identity.byteLength =', "try { throw 'synthetic unreadable observation'; `$identity.byteLength =")
    $source = $source.Replace('$version = [Diagnostics.FileVersionInfo]', "throw 'synthetic unreadable observation'; `$version = [Diagnostics.FileVersionInfo]")
    $source = $source.Replace('C:/Users/ToddS/.cache/codex-runtimes/codex-primary-runtime/runtime.json', (Join-Path $testRoot 'absent-runtime.json'))
    Assert-BatteryTest ($source -cne $matching) 'observation fault injection not applied'
    Save-HostCandidate $fixture $source
    $run = Invoke-HostRun $fixture 'observations-unavailable'
    Assert-BatteryTest ($run.run.exitCode -eq 0 -and (Test-Path $run.markerPath)) 'unreadable observations became admission predicates'
    foreach ($key in @('sha256','byteLength','ProductVersion','bundleVersion')) {
      Assert-BatteryTest ($run.record.hostIdentity.$key -ceq 'unavailable' -and $run.run.output.Contains("$key=unavailable") -and $run.raw.Contains("$key=unavailable")) "unreadable $key was not explicit in result/stdout/raw"
    }
  }
  foreach ($entry in @('Direct','Plan')) {
    Invoke-HostCase "battery-host-entry $entry inherited admission forbidden" {
      Save-HostCandidate $fixture $matching
      $run = Invoke-HostRun $fixture "forbidden-$entry" $entry -Token ('f' * 32)
      $code = if ($entry -eq 'Plan') { 'BATTERY_PLAN_ONLY_ADMISSION_FORBIDDEN' } else { 'BATTERY_INHERITED_ADMISSION_FORBIDDEN' }
      Assert-HostRefused $run $code
    }
  }
  Invoke-HostCase 'battery-host-entry foreign owner untouched' {
    Save-HostCandidate $fixture (Set-HostDeclaration $matching (New-HostDeclaration $different))
    $run = Invoke-HostRun $fixture 'foreign-owner' -ReplaceOwner
    $lock = Join-Path $testRoot '.orchestrator/controller-verify-lock.d'
    try {
      Assert-HostRefused $run 'BATTERY_HOST_PATH_MISMATCH'
      Assert-BatteryTest ([IO.File]::ReadAllText((Join-Path $lock 'owner.json')) -ceq '{"forged":true}') 'foreign fixture owner was not retained byte-for-byte'
    } finally {
      Remove-Item -LiteralPath (Join-Path $lock 'owner.json') -Force
      [IO.Directory]::Delete($lock)
    }
  }
  $windowsApps = Join-Path $env:LOCALAPPDATA 'Microsoft/WindowsApps/pwsh.exe'
  if (Test-Path -LiteralPath $windowsApps -PathType Leaf) {
    Invoke-HostCase 'battery-host-entry WindowsApps red' {
      Save-HostCandidate $fixture $matching
      Assert-HostRefused (Invoke-HostRun $fixture 'windowsapps-red' -Executable $windowsApps) 'BATTERY_HOST_PATH_MISMATCH'
    }
  } else { Write-Host 'SKIP battery-host-entry WindowsApps absent; synthetic different-path red remains mandatory' }
  Assert-BatteryTest ($script:hostFailures.Count -eq 0) ($script:hostFailures -join "`n")
}

try {
  Assert-BatteryTest ($batteryManifest.Count -eq 2) "battery manifest count is not 2"
  if ($ValidatePlanOnly) {
    Invoke-PlanControl
    Invoke-ScopeControl
    Invoke-ImpactControl
    # Reuse needs admitted synthetic children and runs under -Scenario RenameReuse.
    Write-Output "PASS controller-release-battery self-test ValidatePlanOnly"
    return
  }

  $liveHead = (& git -C $controllerRoot rev-parse HEAD 2>&1 | Out-String).Trim()
  Assert-BatteryTest ($LASTEXITCODE -eq 0 -and $liveHead -cmatch "^[a-f0-9]{40}$") "cannot resolve controller HEAD"
  if (-not $ExpectedControllerHead) { $ExpectedControllerHead = $liveHead }
  Assert-BatteryTest ($ExpectedControllerHead -ceq $liveHead) `
    "expected head $ExpectedControllerHead does not equal live controller HEAD $liveHead"

  if ($Scenario -ceq "All") {
    Test-BatteryHostLifecycle
    Test-BatteryHostEntry
    Test-BatteryExactChildHost
    Invoke-PlanControl
    Invoke-ScopeControl
    Invoke-ImpactControl
    Test-BatteryTimingAndTerminalResults
    Test-BatteryReuseAndBaseline
    Test-RenameImpactAndReuse
    Test-FailingBatteryResultWriteOmission
    Test-BatteryIncompleteUnderMeasuredLoad
    Write-Output "PASS controller release battery tests All"
  } elseif ($Scenario -ceq "Admission") {
    Invoke-AdmissionSuite
  } elseif ($Scenario -ceq "InheritedAdmissionIsolation") {
    Test-InheritedAdmissionIsolation
  } elseif ($Scenario -ceq "HostLifecycle") {
    Test-BatteryHostLifecycle
  } elseif ($Scenario -ceq "HostEntry") {
    Test-BatteryHostEntry
  } elseif ($Scenario -ceq "ExactChildHost") {
    Test-BatteryExactChildHost
  } elseif ($Scenario -ceq 'RenameReuse') {
    Test-RenameImpactAndReuse
  } elseif ($Scenario -ceq 'ReuseBaseline') {
    Test-BatteryReuseAndBaseline
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
  Exit-RoutingDataTestScope $routingTestScope
}
