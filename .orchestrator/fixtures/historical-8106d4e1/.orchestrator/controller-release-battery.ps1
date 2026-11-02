[CmdletBinding()]
param(
  [string]$ControllerRoot = (Split-Path -Parent $PSScriptRoot),

  [Parameter(Mandatory)]
  [string]$ExpectedControllerHead,

  # Installed baseline commit. When given and the baseline..candidate diff
  # touches only skills, contracts, and test files, the battery runs the prose
  # scope: the tests that read those files plus the guard discriminators. Any
  # runtime script in the diff, or no baseline, selects the full battery.
  [string]$BaselineHead = "",

  # Repair rounds bind their baseline to a governing BLOCK_FIXABLE receipt on
  # that ancestor head. Omit both fields for an initial candidate, whose
  # baseline remains the installed controller head.
  [ValidateRange(0, [int]::MaxValue)][int]$RepairIssue = 0,
  [string]$RepairHistoryPath = "",

  # Optional externally produced guard-evidence record for issue-6254.
  [string]$EvidenceReceiptPath = "",

  # Optional machine-readable battery result output.
  [string]$ResultPath = "",

  [switch]$ValidatePlanOnly,

  # Exact-owner continuation supplied only by invoke-heavy-verifier.ps1 after
  # it has acquired and published the controller-battery owner record.
  [Parameter(DontShow)]
  [switch]$AdmissionOwned
)

$ErrorActionPreference = "Stop"
$controller = [IO.Path]::GetFullPath($ControllerRoot)
$runtime = Join-Path $controller ".orchestrator"

# Source-mutation seams used only in a copied battery by the omission suite.
# Reconciliation below never consults these switches.
$planInclusion = [ordered]@{
  "direct:fail-closed-guard-evidence" = $true
  "discriminator:issue-6254" = $true
}

function Stop-Battery([string]$Code) {
  throw "FAIL controller-release-battery: $Code"
}

function Test-SameBatteryPath([string]$Left, [string]$Right) {
  try {
    return [string]::Equals(
      [IO.Path]::GetFullPath($Left).TrimEnd("\", "/"),
      [IO.Path]::GetFullPath($Right).TrimEnd("\", "/"),
      [StringComparison]::OrdinalIgnoreCase
    )
  } catch {
    return $false
  }
}

function Assert-BatteryAdmission {
  $token = [string]$env:CHASE_SETS_HEAVY_SLOT_ID
  if ($token -cnotmatch "^[a-f0-9]{32}$") { Stop-Battery "BATTERY_ADMISSION_TOKEN_INVALID" }
  $container = Split-Path -Parent $controller
  # The controller slot, never the platform verifier's (Todd ruling 2026-09-10).
  $lockPath = Join-Path $container ".orchestrator\controller-verify-lock.d"
  $ownerPath = Join-Path $lockPath "owner.json"
  if (-not (Test-Path -LiteralPath $lockPath -PathType Container) -or
      -not (Test-Path -LiteralPath $ownerPath -PathType Leaf)) {
    Stop-Battery "BATTERY_ADMISSION_OWNER_INVALID"
  }
  $deadline = [DateTime]::UtcNow.AddSeconds(10)
  do {
    try {
      $entries = @(Get-ChildItem -LiteralPath $lockPath -Force -ErrorAction Stop)
      if ($entries.Count -eq 1 -and
          (Test-SameBatteryPath $entries[0].FullName $ownerPath) -and
          -not $entries[0].PSIsContainer -and
          (($entries[0].Attributes -band [IO.FileAttributes]::ReparsePoint) -ne [IO.FileAttributes]::ReparsePoint)) {
        $owner = [IO.File]::ReadAllText($ownerPath, [Text.Encoding]::UTF8) |
          ConvertFrom-Json -DateKind String -ErrorAction Stop
        if ($owner.schemaVersion -eq 4 -and
            $owner.lockId -ceq $token -and
            $owner.gate -ceq "script-battery" -and
            $owner.state -ceq "started" -and
            $owner.identityMode -ceq "branch" -and
            (Test-SameBatteryPath ([string]$owner.worktree) $controller) -and
            $owner.head -ceq $ExpectedControllerHead -and
            $owner.branch -ceq (& git -C $controller branch --show-current 2>$null | Out-String).Trim() -and
            [int]$owner.childPid -eq $PID) {
          $self = Get-Process -Id $PID -ErrorAction Stop
          $wrapper = Get-Process -Id ([int]$owner.pid) -ErrorAction Stop
          $expectedSelf = [DateTimeOffset]::Parse([string]$owner.childProcessStartUtc).ToUniversalTime().Ticks
          $expectedWrapper = [DateTimeOffset]::Parse([string]$owner.processStartUtc).ToUniversalTime().Ticks
          if ($self.StartTime.ToUniversalTime().Ticks -eq $expectedSelf -and
              $wrapper.StartTime.ToUniversalTime().Ticks -eq $expectedWrapper) {
            return
          }
        }
      }
    } catch {}
    Start-Sleep -Milliseconds 25
  } while ([DateTime]::UtcNow -lt $deadline)
  Stop-Battery "BATTERY_ADMISSION_OWNER_INVALID"
}

function Quote-Command([string[]]$Arguments) {
  return @($Arguments | ForEach-Object {
      if ($_ -match '[\s"]') { '"' + $_.Replace('"', '\"') + '"' } else { $_ }
    }) -join " "
}

function New-PlanItem(
  [string]$Identity,
  [string]$Path,
  [string[]]$Arguments
) {
  return [pscustomobject][ordered]@{
    identity = $Identity
    path = $Path
    executable = (Get-Process -Id $PID -ErrorAction Stop).Path
    arguments = $Arguments
    command = ((Get-Process -Id $PID -ErrorAction Stop).Path) + " " + (Quote-Command $Arguments)
  }
}

if ($ExpectedControllerHead -cnotmatch "^[a-f0-9]{40}$") {
  Stop-Battery "BATTERY_EXPECTED_HEAD_INVALID"
}
$liveHead = (& git -C $controller rev-parse HEAD 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $liveHead -cne $ExpectedControllerHead) {
  Stop-Battery "BATTERY_LIVE_HEAD_MOVED"
}

if (-not $ValidatePlanOnly) {
  if (-not $AdmissionOwned) {
    if (-not [string]::IsNullOrWhiteSpace([string]$env:CHASE_SETS_HEAVY_SLOT_ID)) {
      Stop-Battery "BATTERY_INHERITED_ADMISSION_FORBIDDEN"
    }
    $verifier = Join-Path $runtime "invoke-heavy-verifier.ps1"
    if (-not (Test-Path -LiteralPath $verifier -PathType Leaf) -or
        (Get-Item -LiteralPath $verifier -Force).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
      Stop-Battery "BATTERY_ADMISSION_WRAPPER_UNAVAILABLE"
    }
    $branch = (& git -C $controller branch --show-current 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($branch)) {
      Stop-Battery "BATTERY_BRANCH_IDENTITY_INVALID"
    }
    $lane = Split-Path -Leaf $controller
    & $verifier -ControllerBattery -Worktree $controller -Lane $lane -Branch $branch `
      -ClaimedHead $ExpectedControllerHead -ContainerRoot (Split-Path -Parent $controller) `
      -ControllerBatteryEvidenceReceiptPath $EvidenceReceiptPath `
      -ControllerBatteryResultPath $ResultPath `
      -ControllerBatteryBaselineHead $BaselineHead `
      -ControllerBatteryRepairIssue $RepairIssue `
      -ControllerBatteryRepairHistoryPath $RepairHistoryPath
    exit $LASTEXITCODE
  }
  Assert-BatteryAdmission
  # BATTERY_ADMISSION_TEST_HOLD_SEAM
} elseif ($AdmissionOwned) {
  Stop-Battery "BATTERY_PLAN_ONLY_ADMISSION_FORBIDDEN"
}

$treeOutput = & git -C $controller ls-tree -r --name-only $ExpectedControllerHead 2>&1
if ($LASTEXITCODE -ne 0) { Stop-Battery "BATTERY_PLAN_UNREADABLE" }
$tracked = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($path in @($treeOutput)) {
  $normalized = ([string]$path).Replace("\", "/")
  if ($normalized -cmatch "^\.orchestrator/.+\.test\.ps1$" -or
      $normalized -cmatch "^\.orchestrator/issue-[^/]+-discriminator\.ps1$") {
    [void]$tracked.Add($normalized)
  }
}
$trackedPaths = [string[]]@($tracked)
[Array]::Sort($trackedPaths, [StringComparer]::Ordinal)

$batteryScope = "full"
$changedPaths = @()
if (-not [string]::IsNullOrWhiteSpace($BaselineHead)) {
  if ($BaselineHead -cnotmatch "^[a-f0-9]{40}$") { Stop-Battery "BATTERY_BASELINE_HEAD_INVALID" }
  & git -C $controller merge-base --is-ancestor $BaselineHead $ExpectedControllerHead 2>$null
  if ($LASTEXITCODE -ne 0) { Stop-Battery "BATTERY_BASELINE_NOT_ANCESTOR" }
  $repairContractRequested = $RepairIssue -gt 0 -or -not [string]::IsNullOrWhiteSpace($RepairHistoryPath)
  if ($repairContractRequested) {
    if ($RepairIssue -lt 1 -or [string]::IsNullOrWhiteSpace($RepairHistoryPath)) {
      Stop-Battery "BATTERY_REPAIR_CONTRACT_INCOMPLETE"
    }
    $resolvedRepairHistory = if ([IO.Path]::IsPathRooted($RepairHistoryPath)) {
      [IO.Path]::GetFullPath($RepairHistoryPath)
    } else { [IO.Path]::GetFullPath((Join-Path $controller $RepairHistoryPath)) }
    Import-Module (Join-Path $runtime "review-head-contract.psm1") -Force -DisableNameChecking
    $repairHistory = Read-ExactHeadReviewHistory -Path $resolvedRepairHistory
    if (-not $repairHistory.complete) { Stop-Battery "BATTERY_REPAIR_HISTORY_$($repairHistory.reason)" }
    $repairReceipts = @($repairHistory.rows | ForEach-Object {
        [pscustomobject]@{ entry = $_; classification = Get-ControllerReviewRowClassification $_ }
      } | Where-Object {
        $_.classification.strict -and $_.classification.valid -and
        [int64]$_.classification.issue -eq $RepairIssue -and
        [string]$_.classification.controllerHead -ceq $BaselineHead -and
        $_.classification.rowKind -ceq "receipt" -and
        [string]$_.classification.reviewAuthority -ceq "governing"
      })
    if ($repairReceipts.Count -ne 1) { Stop-Battery "BATTERY_REPAIR_RECEIPT_AMBIGUOUS" }
    $repairReceipt = $repairReceipts[0].entry.value
    if ([string]$repairReceipt.outcome -cne "BLOCK_FIXABLE") { Stop-Battery "BATTERY_REPAIR_PREDECESSOR_NOT_BLOCK_FIXABLE" }
    if (@($repairReceipt.findingIds).Count -lt 1 -or
        @($repairReceipt.findingIds).Count -ne [int64]$repairReceipt.findings.blocking) {
      Stop-Battery "BATTERY_REPAIR_FINDINGS_MISSING"
    }
  }
  $diffOutput = & git -C $controller diff --name-only "$BaselineHead..$ExpectedControllerHead" 2>&1
  if ($LASTEXITCODE -ne 0) { Stop-Battery "BATTERY_BASELINE_UNREADABLE" }
  $changedPaths = @($diffOutput | ForEach-Object { ([string]$_).Replace("\", "/").Trim() } | Where-Object { $_ })
  $runtimeChanges = @($changedPaths | Where-Object {
      $_ -cnotmatch "^\.orchestrator/(controller-skills/|contracts/|[^/]+\.test\.ps1$)"
    })
  if ($changedPaths.Count -gt 0 -and $runtimeChanges.Count -eq 0) { $batteryScope = "prose" }
}
if ($batteryScope -ceq "prose") {
  $proseTests = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($proseTest in @(
      ".orchestrator/issue-6997-autonomy-policy.test.ps1",
      ".orchestrator/contract-enforcement.test.ps1",
      ".orchestrator/install-controller-skills.test.ps1",
      ".orchestrator/controller-release-battery.test.ps1"
    )) { [void]$proseTests.Add($proseTest) }
  foreach ($changed in $changedPaths) {
    if ($changed -cmatch "^\.orchestrator/[^/]+\.test\.ps1$") { [void]$proseTests.Add($changed) }
  }
  $trackedPaths = [string[]]@($trackedPaths | Where-Object {
      $_ -cmatch "^\.orchestrator/issue-[^/]+-discriminator\.ps1$" -or $proseTests.Contains($_)
    })
}

$requiredItems = [Collections.Generic.List[object]]::new()
$checkerPath = Join-Path $runtime "fail-closed-guard-evidence.test.ps1"
$resolvedReceipt = if ([string]::IsNullOrWhiteSpace($EvidenceReceiptPath)) {
  ""
} elseif ([IO.Path]::IsPathRooted($EvidenceReceiptPath)) {
  [IO.Path]::GetFullPath($EvidenceReceiptPath)
} else {
  [IO.Path]::GetFullPath((Join-Path $controller $EvidenceReceiptPath))
}
$directArgs = @(
  "-NoProfile", "-NonInteractive", "-File", $checkerPath,
  "-Scenario", "BypassMutants",
  "-ExpectedControllerHead", $ExpectedControllerHead
)
$requiredItems.Add((New-PlanItem "direct:fail-closed-guard-evidence" ".orchestrator/fail-closed-guard-evidence.ps1" $directArgs))

foreach ($path in $trackedPaths) {
  $absolute = Join-Path $controller $path
  if ($path -cmatch "^\.orchestrator/(issue-[^/]+)-discriminator\.ps1$") {
    $slug = $Matches[1]
    $identity = "discriminator:$slug"
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
      $absolute,
      [ref]$tokens,
      [ref]$parseErrors
    )
    if (@($parseErrors).Count -ne 0) {
      Stop-Battery "BATTERY_DISCRIMINATOR_INTERFACE_UNREADABLE:$slug"
    }
    $parameterNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($parameter in @($ast.ParamBlock.Parameters)) {
      [void]$parameterNames.Add($parameter.Name.VariablePath.UserPath)
    }
    if ($slug -ceq "issue-6254") {
      if (-not $parameterNames.Contains("ControllerRoot") -or
          -not $parameterNames.Contains("EvidenceReceiptPath") -or
          -not $parameterNames.Contains("ExpectedControllerHead")) {
        Stop-Battery "BATTERY_DISCRIMINATOR_INTERFACE_UNREADABLE:$slug"
      }
      $arguments = @(
        "-NoProfile", "-NonInteractive", "-File", $absolute,
        "-ControllerRoot", $controller,
        "-EvidenceReceiptPath", $resolvedReceipt,
        "-ExpectedControllerHead", $ExpectedControllerHead
      )
    } else {
      $arguments = @("-NoProfile", "-NonInteractive", "-File", $absolute)
      if ($parameterNames.Contains("ControllerRoot")) {
        $arguments += @("-ControllerRoot", $controller)
      } elseif ($parameterNames.Contains("RepositoryRoot")) {
        $arguments += @("-RepositoryRoot", $controller)
      }
    }
    $requiredItems.Add((New-PlanItem $identity $path $arguments))
    continue
  }

  $identity = "test:" + $path.Substring(".orchestrator/".Length)
  $arguments = @("-NoProfile", "-NonInteractive", "-File", $absolute)
  if ($path -ceq ".orchestrator/controller-release-battery.test.ps1") {
    $arguments += @("-ValidatePlanOnly")
  }
  $requiredItems.Add((New-PlanItem $identity $path $arguments))
}

$identitySet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($item in $requiredItems) {
  if (-not $identitySet.Add($item.identity)) { Stop-Battery "BATTERY_PLAN_DUPLICATE:$($item.identity)" }
}
foreach ($requiredDiscriminator in @("discriminator:issue-6254")) {
  if (-not $identitySet.Contains($requiredDiscriminator)) {
    Stop-Battery "BATTERY_DISCRIMINATOR_OMITTED:$($requiredDiscriminator.Substring('discriminator:'.Length))"
  }
}

$selectedItems = [Collections.Generic.List[object]]::new()
foreach ($item in $requiredItems) {
  if ($item.identity -ceq "direct:fail-closed-guard-evidence" -and
      -not $planInclusion["direct:fail-closed-guard-evidence"]) {
    continue
  }
  if ($item.identity -ceq "discriminator:issue-6254" -and
      -not $planInclusion["discriminator:issue-6254"]) {
    continue
  }
  $selectedItems.Add($item)
}

Write-Output "BATTERY_SCOPE scope=$batteryScope baseline=$(if ($BaselineHead) { $BaselineHead } else { 'none' }) changed=$($changedPaths.Count)"
Write-Output "BATTERY_PLAN_BEGIN head=$ExpectedControllerHead required=$($requiredItems.Count) selected=$($selectedItems.Count)"
foreach ($item in $requiredItems) {
  Write-Output "REQUIRED identity=$($item.identity) path=$($item.path)"
}
foreach ($item in $selectedItems) {
  Write-Output "PLAN identity=$($item.identity) command=$($item.command)"
}
Write-Output "BATTERY_PLAN_END"

if ($ValidatePlanOnly) {
  Write-Output "PASS controller release battery plan-only head=$ExpectedControllerHead required=$($requiredItems.Count)"
  return
}
$results = [Collections.Generic.List[object]]::new()
foreach ($item in $selectedItems) {
  $childOutput = & $item.executable @($item.arguments) 2>&1 | Out-String
  $exitCode = $LASTEXITCODE
  $provenance = [ordered]@{kind='execution';command=$item.command;attempt='local-battery'}
  $result = [pscustomobject][ordered]@{
    identity = $item.identity
    command = $item.command
    exitCode = $exitCode
    result = if ($exitCode -eq 0) { "PASS" } else { "FAIL" }
    output = $childOutput.Trim()
    provenance = $provenance
  }
  $results.Add($result)
  Write-Output "RESULT identity=$($result.identity) exitCode=$exitCode result=$($result.result)"
  if ($result.output) {
    foreach ($line in @($result.output -split "\r?\n")) {
      Write-Output "CHILD identity=$($result.identity) $line"
    }
  }
}

$executed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($result in $results) {
  if (-not $executed.Add($result.identity)) {
    Stop-Battery "BATTERY_RESULT_DUPLICATE:$($result.identity)"
  }
}
foreach ($item in $requiredItems) {
  if (-not $executed.Contains($item.identity)) {
    switch ($item.identity) {
      "direct:fail-closed-guard-evidence" {
        Stop-Battery "BATTERY_DIRECT_CHECKER_VALIDATION_OMITTED"
      }
      "discriminator:issue-6254" {
        Stop-Battery "BATTERY_DISCRIMINATOR_OMITTED:issue-6254"
      }
      default { Stop-Battery "BATTERY_RESULT_MISSING:$($item.identity)" }
    }
  }
}
foreach ($result in $results) {
  if (-not $identitySet.Contains($result.identity)) {
    Stop-Battery "BATTERY_RESULT_EXTRA:$($result.identity)"
  }
  if ($result.exitCode -ne 0) {
    Stop-Battery "BATTERY_CHILD_FAILED:$($result.identity)"
  }
}
if ($results.Count -ne $requiredItems.Count) {
  Stop-Battery "BATTERY_RESULT_COUNT_MISMATCH"
}

if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
  $resolvedResult = if ([IO.Path]::IsPathRooted($ResultPath)) {
    [IO.Path]::GetFullPath($ResultPath)
  } else {
    [IO.Path]::GetFullPath((Join-Path $controller $ResultPath))
  }
  $artifactRoot = [IO.Path]::GetFullPath((Join-Path $runtime "artifacts")).TrimEnd("\", "/")
  if ((Split-Path -Parent $resolvedResult).TrimEnd("\", "/") -cne $artifactRoot) {
    Stop-Battery "BATTERY_RESULT_PATH_INVALID"
  }
  New-Item -ItemType Directory -Path $artifactRoot -Force | Out-Null
  $rawPath = [IO.Path]::ChangeExtension($resolvedResult, ".log")
  $rawText = @($results | ForEach-Object {
    "RESULT identity=$($_.identity) exitCode=$($_.exitCode) result=$($_.result)`n$($_.output)"
  }) -join "`n"
  $rawBytes = [Text.UTF8Encoding]::new($false).GetBytes($rawText + "`n")
  [IO.File]::WriteAllBytes($rawPath, $rawBytes)
  $rawHash = ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($rawBytes))).ToLowerInvariant()
  $resultRecord = [ordered]@{
    schemaVersion = "controller-battery-result/v1"
    controllerHead = $ExpectedControllerHead
    execution = [ordered]@{
      mode = "foreground-file-serial"
      outcome = "PASS"
      requiredCount = $requiredItems.Count
      executedCount = @($results | Where-Object {$_.provenance.kind -ceq 'execution'}).Count
      reusedCount = @($results | Where-Object {$_.provenance.kind -ceq 'receipt-reuse'}).Count
      satisfiedCount = $results.Count
    }
    inventory = @($requiredItems | ForEach-Object {
      [ordered]@{ identity = $_.identity; path = $_.path; command = $_.command }
    })
    results = @($results | ForEach-Object {
      [ordered]@{ identity = $_.identity; exitCode = $_.exitCode; result = $_.result; provenance = $_.provenance }
    })
    rawLog = [ordered]@{
      kind = "raw-log"
      relativePath = ".orchestrator/artifacts/" + [IO.Path]::GetFileName($rawPath)
      byteLength = $rawBytes.Length
      sha256 = $rawHash
    }
  }
  $resultBytes = [Text.UTF8Encoding]::new($false).GetBytes(($resultRecord | ConvertTo-Json -Compress -Depth 20) + "`n")
  [IO.File]::WriteAllBytes($resolvedResult, $resultBytes)
  Write-Output "BATTERY_RESULT path=$resolvedResult raw=$rawPath"
}

$executedCount=@($results|Where-Object{$_.provenance.kind-ceq'execution'}).Count;$reusedCount=@($results|Where-Object{$_.provenance.kind-ceq'receipt-reuse'}).Count
Write-Output "PASS controller release battery head=$ExpectedControllerHead required=$($requiredItems.Count) executed=$executedCount reused=$reusedCount satisfied=$($results.Count) direct=1 tests=$(@($requiredItems | Where-Object identity -like 'test:*').Count) discriminators=$(@($requiredItems | Where-Object identity -like 'discriminator:*').Count)"
