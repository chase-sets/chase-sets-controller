<#
.SYNOPSIS
Runs one supported repository-wide heavy verification gate under the container
exclusive verifier lock. This is deliberately the only command entrypoint;
callers cannot supply an arbitrary shell string or bypass the gate inventory.
#>
[CmdletBinding(DefaultParameterSetName = "Gate")]
param(
  [Parameter(Mandatory, ParameterSetName = "Gate")][ValidateSet("verify:static", "check:static", "test:scripts", "verify:test", "test", "test:fast", "build", "verify", "verify:build", "verify:test-db")][string]$Gate,
  [Parameter(Mandatory)][string]$Worktree,
  [Parameter(Mandatory)][ValidatePattern("^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$")][string]$Lane,
  [string]$Branch,
  [ValidatePattern("^[a-fA-F0-9]{40}$")][string]$ClaimedHead,
  [ValidatePattern("^[a-fA-F0-9]{40}$")][string]$ImmutableHead,
  # Test seams retain the same process/argument execution path, but production
  # resolution always invokes pnpm with the enumerated gate above.
  [Parameter(ParameterSetName = "Gate", DontShow)]
  [Parameter(ParameterSetName = "ControllerBattery", DontShow)]
  [Parameter(ParameterSetName = "Attach", DontShow)]
  [string]$CommandPath,
  [Parameter(ParameterSetName = "Gate", DontShow)]
  [Parameter(ParameterSetName = "ControllerBattery", DontShow)]
  [Parameter(ParameterSetName = "Attach", DontShow)]
  [string[]]$CommandArgumentList,
  [Parameter(DontShow)][string]$ContainerRoot,
  [Parameter(DontShow)][switch]$TestCancelAfterAcquisition,
  [Parameter(DontShow)][switch]$TestReplaceOwnerBeforeCleanup,
  [Parameter(DontShow)][switch]$TestReplaceOwnerBeforeReclaim,
  [Parameter(DontShow)][ValidateRange(0, 30000)][int]$TestDelayIdentityRevalidationMilliseconds,
  [Parameter(DontShow)][ValidateRange(0, 30000)][int]$TestDelayChildPublicationMilliseconds,
  # The canonical controller release battery uses the same exact-owner lock
  # implementation, but its command and arguments are fixed here rather than
  # exposed as an arbitrary production command surface.
  [Parameter(Mandatory, ParameterSetName = "ControllerBattery", DontShow)][switch]$ControllerBattery,
  [Parameter(ParameterSetName = "ControllerBattery", DontShow)][string]$ControllerBatteryEvidenceReceiptPath = "",
  [Parameter(ParameterSetName = "ControllerBattery", DontShow)][string]$ControllerBatteryResultPath = "",
  # Installed baseline forwarded verbatim to the admitted battery child so the
  # child derives change scope; empty keeps the full battery.
  [Parameter(ParameterSetName = "ControllerBattery", DontShow)][ValidatePattern("^$|^[a-f0-9]{40}$")][string]$ControllerBatteryBaselineHead = "",
  [Parameter(ParameterSetName = "ControllerBattery", DontShow)][ValidateRange(0, [int]::MaxValue)][int]$ControllerBatteryRepairIssue = 0,
  [Parameter(ParameterSetName = "ControllerBattery", DontShow)][string]$ControllerBatteryRepairHistoryPath = "",
  # Guard-evidence precursor producers are a closed production surface. The
  # selected value resolves to one tracked script and one fixed grammar below.
  [Parameter(Mandatory, ParameterSetName = "ControllerPrecursor")]
  [ValidateSet("fail-closed-guard-evidence", "issue-6254-fail-closed-guard-evidence")]
  [string]$ControllerPrecursor,
  [Parameter(Mandatory, ParameterSetName = "ControllerPrecursor")][string]$ControllerPrecursorArtifactPath,
  [Parameter(ParameterSetName = "ControllerPrecursor")]
  [ValidateSet("ReceiptClaims")]
  [string]$ControllerPrecursorScenario,
  # The lane-injected Node preload pauses a classified heavy process before its
  # command body and starts this same lock owner in attached mode.
  [Parameter(Mandatory, ParameterSetName = "Attach", DontShow)]
  [ValidateSet("repository-gate", "playwright", "vitest-full", "script-battery", "build")]
  [string]$AdmissionKind,
  [Parameter(Mandatory, ParameterSetName = "Attach", DontShow)][ValidateRange(1, [int]::MaxValue)][int]$GuardedPid,
  [Parameter(ParameterSetName = "Attach", DontShow)][string]$GuardedProcessStartUtc,
  [Parameter(Mandatory, ParameterSetName = "Attach", DontShow)][ValidatePattern("^[a-f0-9]{32}$")][string]$AdmissionNonce,
  [Parameter(Mandatory, ParameterSetName = "Attach", DontShow)][string]$AdmissionResultPath,
  [Parameter(Mandatory, ParameterSetName = "Attach", DontShow)][string]$AdmissionCommand
)

$ErrorActionPreference = "Stop"
$isAttachedAdmission = $PSCmdlet.ParameterSetName -ceq "Attach"
$isControllerBattery = $PSCmdlet.ParameterSetName -ceq "ControllerBattery"
$isControllerPrecursor = $PSCmdlet.ParameterSetName -ceq "ControllerPrecursor"
$admissionResultFull = $null
$admissionRoot = $null
$attachedDeadTreeProven = $false
$admissionCleanupDiagnostic = 'not-attempted'

function Write-AdmissionResult([bool]$Accepted, [string]$Message, $Record = $null) {
  if (-not $isAttachedAdmission -or -not $admissionResultFull) { return }
  $result = [ordered]@{
    schemaVersion = 1
    nonce = $AdmissionNonce
    accepted = $Accepted
    message = $Message
    owner = if ($Record) {
      [ordered]@{
        lockId = $Record.lockId
        lane = $Record.lane
        branch = $Record.branch
        worktree = $Record.worktree
        head = $Record.head
        identityMode = $Record.identityMode
        pid = $Record.pid
        gate = $Record.gate
      }
    } else {
      $null
    }
  }
  $temporaryPath = "$admissionResultFull.$([guid]::NewGuid().ToString('N')).tmp"
  try {
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($result | ConvertTo-Json -Compress))
    $stream = [IO.File]::Open($temporaryPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
      $stream.Write($bytes, 0, $bytes.Length)
      $stream.Flush($true)
    } finally {
      $stream.Dispose()
    }
    [IO.File]::Move($temporaryPath, $admissionResultFull)
  } finally {
    if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
      Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
  }
}

trap {
  if ($isAttachedAdmission) {
    try { Write-AdmissionResult $false $_.Exception.Message } catch {}
    try {
      if (Get-Command Complete-RefusedAttachedAdmission -CommandType Function -ErrorAction SilentlyContinue) {
        Complete-RefusedAttachedAdmission
      }
    } catch {}
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 73
  }
  if ($isControllerPrecursor -and $_.Exception.Message.StartsWith("heavy-verifier: lock unavailable (", [StringComparison]::Ordinal)) {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 73
  }
  throw $_.Exception
}

if ($isAttachedAdmission) {
  $systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
  $admissionResultFull = [IO.Path]::GetFullPath($AdmissionResultPath)
  $admissionResultParent = Split-Path -Parent $admissionResultFull
  if (-not $admissionResultFull.StartsWith($systemTemp + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
      -not (Test-Path -LiteralPath $admissionResultParent -PathType Container) -or
      (Test-Path -LiteralPath $admissionResultFull)) {
    throw "heavy-verifier: admission result must be a new file below the system temp root"
  }
  if ((Split-Path -Leaf $admissionResultParent) -cnotmatch '^chase-sets-heavy-admission-[A-Za-z0-9_-]+$') {
    throw "heavy-verifier: admission result parent is not an exact owned admission root"
  }
  $admissionRoot = $admissionResultParent
  $guarded = Get-Process -Id $GuardedPid -ErrorAction Stop
  if ([string]::IsNullOrWhiteSpace($GuardedProcessStartUtc)) {
    $GuardedProcessStartUtc = $guarded.StartTime.ToUniversalTime().ToString("o")
  } else {
    $guardedExpectedTicks = [DateTimeOffset]::Parse($GuardedProcessStartUtc).ToUniversalTime().Ticks
    if ($guarded.StartTime.ToUniversalTime().Ticks -ne $guardedExpectedTicks) {
      throw "heavy-verifier: guarded process identity is absent or PID-reused"
    }
  }
}

$container = [IO.Path]::GetFullPath($(if ($ContainerRoot) { $ContainerRoot } else { Split-Path -Parent $PSScriptRoot })).TrimEnd('\','/')
$worktreeFull = [IO.Path]::GetFullPath($Worktree).TrimEnd('\','/')
if ($worktreeFull -eq $container -or -not $worktreeFull.StartsWith($container + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $worktreeFull -PathType Container)) {
  throw "heavy-verifier: worktree must be an existing child of the container root"
}

function Invoke-GitIdentityProbe([string[]]$Arguments, [string]$Description) {
  $output = @(& git -C $worktreeFull @Arguments 2>$null)
  if ($LASTEXITCODE -ne 0) {
    throw "heavy-verifier: unable to resolve live Git $Description in the supplied worktree"
  }
  return ($output -join "`n").Trim()
}
function Get-LiveGitIdentity {
  $topLevel = Invoke-GitIdentityProbe @("rev-parse", "--show-toplevel") "worktree"
  $canonical = [IO.Path]::GetFullPath($topLevel).TrimEnd('\','/')
  if (-not [string]::Equals($canonical, $worktreeFull, [StringComparison]::OrdinalIgnoreCase)) {
    throw "heavy-verifier: worktree must name the canonical Git worktree root"
  }
  $head = (Invoke-GitIdentityProbe @("rev-parse", "--verify", "HEAD") "HEAD").ToLowerInvariant()
  if ($head -cnotmatch "^[a-f0-9]{40}$") {
    throw "heavy-verifier: live Git HEAD was not an exact commit SHA"
  }
  $branch = Invoke-GitIdentityProbe @("branch", "--show-current") "branch"
  return [pscustomobject]@{
    Worktree = $canonical
    Branch = $branch
    Head = $head
  }
}

$branchSupplied = $PSBoundParameters.ContainsKey("Branch")
$claimedHeadSupplied = $PSBoundParameters.ContainsKey("ClaimedHead")
$immutableHeadSupplied = $PSBoundParameters.ContainsKey("ImmutableHead")
if (($branchSupplied -ne $claimedHeadSupplied) -or
    ($branchSupplied -eq $immutableHeadSupplied) -or
    ($branchSupplied -and [string]::IsNullOrWhiteSpace($Branch)) -or
    ($claimedHeadSupplied -and [string]::IsNullOrWhiteSpace($ClaimedHead)) -or
    ($immutableHeadSupplied -and [string]::IsNullOrWhiteSpace($ImmutableHead))) {
  throw "heavy-verifier: supply both the claimed branch and its exact launch-time HEAD, or supply one explicit immutable HEAD"
}
$acquiredGitIdentity = Get-LiveGitIdentity
$identityMode = if ($immutableHeadSupplied) { "immutable-head" } else { "branch" }
if ($identityMode -ceq "branch") {
  if ([string]::IsNullOrWhiteSpace($acquiredGitIdentity.Branch) -or $Branch -cne $acquiredGitIdentity.Branch) {
    throw "heavy-verifier: supplied branch identity does not match the live Git branch; command body was not executed"
  }
  $ClaimedHead = $ClaimedHead.ToLowerInvariant()
  if ($ClaimedHead -cne $acquiredGitIdentity.Head) {
    throw "heavy-verifier: supplied exact launch-time HEAD does not match the live Git HEAD; command body was not executed"
  }
} else {
  $ImmutableHead = $ImmutableHead.ToLowerInvariant()
  if (-not [string]::IsNullOrWhiteSpace($acquiredGitIdentity.Branch) -or
      $ImmutableHead -cne $acquiredGitIdentity.Head) {
    throw "heavy-verifier: explicit immutable HEAD requires detached Git state at the exact supplied SHA; command body was not executed"
  }
}

$precursorDefinitions = [ordered]@{
  "fail-closed-guard-evidence" = [ordered]@{
    Script = ".orchestrator/fail-closed-guard-evidence.test.ps1"
    Scenario = "ReceiptClaims"
    ScenarioArgument = "Scenario"
  }
  "issue-6254-fail-closed-guard-evidence" = [ordered]@{
    Script = ".orchestrator/issue-6254-fail-closed-guard-evidence.test.ps1"
    Scenario = $null
    ScenarioArgument = $null
  }
}
if ($isControllerPrecursor) {
  $ControllerPrecursor = @($precursorDefinitions.Keys | Where-Object { $_ -ieq $ControllerPrecursor })[0]
}
$precursorArtifact = $null
$precursorScriptPath = $null

function Test-PrecursorSafeDirectory([string]$Path) {
  try {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    return $item.PSIsContainer -and
      (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne [IO.FileAttributes]::ReparsePoint)
  } catch {
    return $false
  }
}
function Test-PrecursorSafeFile([string]$Path) {
  try {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    return -not $item.PSIsContainer -and
      (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne [IO.FileAttributes]::ReparsePoint)
  } catch {
    return $false
  }
}
function Assert-ControllerPrecursorGitState {
  $status = @(& git -C $worktreeFull status --porcelain=v1 --untracked-files=all --ignore-submodules=none 2>$null)
  if ($LASTEXITCODE -ne 0) {
    throw "heavy-verifier: unable to verify the controller precursor worktree is clean"
  }
  if ($status.Count -ne 0) {
    throw "heavy-verifier: controller precursor requires a clean exact-head worktree; command body was not executed"
  }
  $definition = $precursorDefinitions[$ControllerPrecursor]
  $tracked = Invoke-GitIdentityProbe @("ls-tree", $acquiredGitIdentity.Head, "--", $definition.Script) "precursor producer"
  $expectedTree = "^100(?:644|755) blob [a-f0-9]{40}`t$([regex]::Escape($definition.Script))$"
  if ($tracked -cnotmatch $expectedTree) {
    throw "heavy-verifier: selected controller precursor producer is not one exact tracked regular script"
  }
  $candidatePath = Join-Path $worktreeFull $definition.Script
  if (-not (Test-PrecursorSafeFile $candidatePath)) {
    throw "heavy-verifier: selected controller precursor producer is absent or unsafe"
  }
  $script:precursorScriptPath = $candidatePath
}
function Resolve-ControllerPrecursorArtifact([string]$Value, [string]$Role) {
  if ([string]::IsNullOrWhiteSpace($Value) -or [IO.Path]::IsPathFullyQualified($Value)) {
    throw "heavy-verifier: controller precursor $Role must be a repository-relative JSON file below .orchestrator/artifacts"
  }
  $normalized = $Value.Replace("\", "/")
  $immediate = $normalized -cmatch "^\.orchestrator/artifacts/[A-Za-z0-9][A-Za-z0-9._-]{0,119}\.json$"
  if (-not $immediate) {
    throw "heavy-verifier: controller precursor $Role must be a closed JSON path below .orchestrator/artifacts"
  }
  $full = [IO.Path]::GetFullPath((Join-Path $worktreeFull $normalized))
  $artifactRoot = [IO.Path]::GetFullPath((Join-Path $worktreeFull ".orchestrator/artifacts")).TrimEnd("\", "/")
  if (-not $full.StartsWith($artifactRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
      ($immediate -and -not [string]::Equals((Split-Path -Parent $full).TrimEnd("\", "/"), $artifactRoot, [StringComparison]::OrdinalIgnoreCase))) {
    throw "heavy-verifier: controller precursor $Role escaped .orchestrator/artifacts"
  }
  return [pscustomobject]@{ Relative = $normalized; Full = $full; Root = $artifactRoot }
}
function Assert-ControllerPrecursorArtifactState([switch]$AfterSuccess) {
  $runtimeRoot = Join-Path $worktreeFull ".orchestrator"
  if (-not (Test-PrecursorSafeDirectory $worktreeFull) -or -not (Test-PrecursorSafeDirectory $runtimeRoot)) {
    throw "heavy-verifier: controller precursor worktree or runtime root is unsafe"
  }
  if (-not (Test-Path -LiteralPath $precursorArtifact.Root)) {
    [IO.Directory]::CreateDirectory($precursorArtifact.Root) | Out-Null
  }
  if (-not (Test-PrecursorSafeDirectory $precursorArtifact.Root)) {
    throw "heavy-verifier: controller precursor artifact root is a symlink, reparse point, or unsafe directory"
  }
  if ($AfterSuccess) {
    if (-not (Test-PrecursorSafeFile $precursorArtifact.Full)) {
      throw "heavy-verifier: controller precursor succeeded without its required safe output artifact"
    }
  } elseif (Test-Path -LiteralPath $precursorArtifact.Full) {
    throw "heavy-verifier: controller precursor authoritative output already exists"
  }
}

if ($isControllerPrecursor) {
  Assert-ControllerPrecursorGitState
  $precursorArtifact = Resolve-ControllerPrecursorArtifact $ControllerPrecursorArtifactPath "output"
  $definition = $precursorDefinitions[$ControllerPrecursor]
  if ($definition.Scenario) {
    if (-not $PSBoundParameters.ContainsKey("ControllerPrecursorScenario") -or
        $ControllerPrecursorScenario -cne $definition.Scenario) {
      throw "heavy-verifier: selected controller precursor requires scenario $($definition.Scenario)"
    }
  } elseif ($PSBoundParameters.ContainsKey("ControllerPrecursorScenario")) {
    throw "heavy-verifier: selected controller precursor does not accept a scenario"
  }
  Assert-ControllerPrecursorArtifactState
}

# Controller release batteries and precursors own a separate slot (Todd ruling
# 2026-09-10): they never wait on, and never block, the platform heavy verifier.
$lockDirectoryName = if ($isControllerBattery -or $isControllerPrecursor) { "controller-verify-lock.d" } else { "verify-lock.d" }
$lockPath = Join-Path $container (".orchestrator\" + $lockDirectoryName)
$ownerPath = Join-Path $lockPath "owner.json"
$process = Get-Process -Id $PID -ErrorAction Stop
$started = $process.StartTime.ToUniversalTime().ToString("o")
$command = if ($isAttachedAdmission) {
  $guarded.Path
} elseif ($isControllerBattery -or $isControllerPrecursor) {
  (Get-Process -Id $PID -ErrorAction Stop).Path
} elseif ($CommandPath) {
  [IO.Path]::GetFullPath($CommandPath)
} else {
  $resolved = Get-Command pnpm -CommandType Application -ErrorAction Stop | Select-Object -First 1
  $resolved.Source
}
if (-not (Test-Path -LiteralPath $command -PathType Leaf)) { throw "heavy-verifier: command executable was not found" }
$arguments = if ($isAttachedAdmission) {
  @($AdmissionCommand)
} elseif ($isControllerBattery) {
  $batteryPath = Join-Path $worktreeFull ".orchestrator\controller-release-battery.ps1"
  if (-not (Test-Path -LiteralPath $batteryPath -PathType Leaf) -or
      (Get-Item -LiteralPath $batteryPath -Force).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
    throw "heavy-verifier: canonical controller release battery is absent or unsafe"
  }
  @(
    "-NoProfile", "-NonInteractive", "-File", $batteryPath,
    "-ControllerRoot", $worktreeFull,
    "-ExpectedControllerHead", $acquiredGitIdentity.Head,
    "-EvidenceReceiptPath", $ControllerBatteryEvidenceReceiptPath,
    "-ResultPath", $ControllerBatteryResultPath,
    "-BaselineHead", $ControllerBatteryBaselineHead,
    "-RepairIssue", "$ControllerBatteryRepairIssue",
    "-RepairHistoryPath", $ControllerBatteryRepairHistoryPath,
    "-AdmissionOwned"
  )
} elseif ($isControllerPrecursor) {
  $definition = $precursorDefinitions[$ControllerPrecursor]
  $fixed = @("-NoProfile", "-NonInteractive", "-File", $precursorScriptPath)
  if ($definition.ScenarioArgument) {
    $fixed += @("-$($definition.ScenarioArgument)", $definition.Scenario)
  }
  switch ($ControllerPrecursor) {
    "fail-closed-guard-evidence" {
      $fixed += @("-ExpectedControllerHead", $acquiredGitIdentity.Head, "-SuiteResultOut", $precursorArtifact.Relative)
    }
    "issue-6254-fail-closed-guard-evidence" {
      $fixed += @("-ControllerRoot", $worktreeFull, "-ExpectedControllerHead", $acquiredGitIdentity.Head, "-SuiteResultOut", $precursorArtifact.Relative)
    }
  }
  $fixed
} elseif ($CommandPath) {
  @($CommandArgumentList)
} else {
  @("run", $Gate)
}
$ownerGate = if ($isAttachedAdmission) { $AdmissionKind } elseif ($isControllerBattery -or $isControllerPrecursor) { "script-battery" } else { $Gate }
$identityInput = "$ownerGate`n$command`n$($arguments -join "`n")"
$commandIdentity = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($identityInput))).ToLowerInvariant()
$lockId = [guid]::NewGuid().ToString("N")
$owner = [ordered]@{
  schemaVersion = $(if($isAttachedAdmission){5}else{4}); lockId = $lockId; owner = "$env:USERNAME@$env:COMPUTERNAME"; lane = $Lane
  branch = $(if ($identityMode -ceq "branch") { $acquiredGitIdentity.Branch } else { $null })
  worktree = $acquiredGitIdentity.Worktree; head = $acquiredGitIdentity.Head; identityMode = $identityMode
  pid = $PID; processStartUtc = $started; startedUtc = [DateTime]::UtcNow.ToString("o")
  gate = $ownerGate; commandIdentity = $commandIdentity
  state = $(if ($isAttachedAdmission) { "attached" } else { "launching" })
  childPid = $(if ($isAttachedAdmission) { $GuardedPid } else { $null })
  childProcessStartUtc = $(if ($isAttachedAdmission) { $GuardedProcessStartUtc } else { $null })
}
if($isAttachedAdmission){$owner.admissionRoot=$admissionRoot}
$ownedRaw = $null

function Test-SamePath([string]$Left, [string]$Right) {
  try {
    return [string]::Equals(
      [IO.Path]::GetFullPath($Left).TrimEnd('\','/'),
      [IO.Path]::GetFullPath($Right).TrimEnd('\','/'),
      [StringComparison]::OrdinalIgnoreCase
    )
  } catch {
    return $false
  }
}
function Test-SafeDirectory([string]$Path) {
  try {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    return $item.PSIsContainer -and
      (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne [IO.FileAttributes]::ReparsePoint)
  } catch {
    return $false
  }
}
function Test-SafeFile([string]$Path) {
  try {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    return -not $item.PSIsContainer -and
      (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne [IO.FileAttributes]::ReparsePoint)
  } catch {
    return $false
  }
}
function Get-OwnerSnapshot([string]$RecordPath = $ownerPath) {
  if (-not (Test-SafeDirectory $lockPath) -or -not (Test-SafeFile $RecordPath)) { return $null }
  try {
    $entries = @(Get-ChildItem -LiteralPath $lockPath -Force -ErrorAction Stop)
    if ($entries.Count -ne 1 -or -not (Test-SamePath $entries[0].FullName $RecordPath)) { return $null }
    $raw = [IO.File]::ReadAllText($RecordPath, [Text.Encoding]::UTF8)
    $record = $raw | ConvertFrom-Json -DateKind String -ErrorAction Stop
    return [pscustomobject]@{ Raw = $raw; Record = $record }
  } catch {
    return $null
  }
}
function Test-UtcIdentity([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
  $parsed = [DateTimeOffset]::MinValue
  return [DateTimeOffset]::TryParse($Value, [ref]$parsed)
}
function Test-PositivePid($Value) {
  if ($Value -isnot [int] -and $Value -isnot [long]) { return $false }
  $parsed = 0
  return [int]::TryParse([string]$Value, [ref]$parsed) -and $parsed -gt 0
}
function Test-OwnerShape($Record) {
  if ($null -eq $Record) { return $false }
  if ($Record.schemaVersion -isnot [long]) { return $false }
  $legacyCommon = @("schemaVersion", "lockId", "owner", "lane", "branch", "pid", "processStartUtc", "startedUtc", "gate", "commandIdentity")
  $expected = if ($Record.schemaVersion -eq 1) {
    $legacyCommon
  } elseif ($Record.schemaVersion -in @(2, 3)) {
    @($legacyCommon) + @("state", "childPid", "childProcessStartUtc")
  } elseif ($Record.schemaVersion -eq 4) {
    @($legacyCommon) + @("worktree", "head", "identityMode", "state", "childPid", "childProcessStartUtc")
  } elseif ($Record.schemaVersion -eq 5) {
    @($legacyCommon) + @("worktree", "head", "identityMode", "state", "childPid", "childProcessStartUtc", "admissionRoot")
  } else {
    return $false
  }
  $actual = @($Record.PSObject.Properties.Name)
  if ($actual.Count -ne $expected.Count) { return $false }
  foreach ($name in $expected) {
    if ($actual -cnotcontains $name) { return $false }
  }
  foreach ($name in @("lockId", "owner", "lane", "pid", "processStartUtc", "startedUtc", "gate", "commandIdentity")) {
    if ([string]::IsNullOrWhiteSpace([string]$Record.$name)) { return $false }
  }
  if ($Record.schemaVersion -lt 4 -and [string]::IsNullOrWhiteSpace([string]$Record.branch)) { return $false }
  if ($Record.schemaVersion -in @(4,5)) {
    if ([string]::IsNullOrWhiteSpace([string]$Record.worktree) -or
        "$($Record.head)" -cnotmatch "^[a-f0-9]{40}$" -or
        $Record.identityMode -cnotin @("branch", "immutable-head") -or
        ($Record.identityMode -ceq "branch" -and [string]::IsNullOrWhiteSpace([string]$Record.branch)) -or
        ($Record.identityMode -ceq "immutable-head" -and $null -ne $Record.branch)) {
      return $false
    }
    if($Record.schemaVersion-eq5){
      if($Record.state-cne'attached'-or[string]::IsNullOrWhiteSpace([string]$Record.admissionRoot)){return $false}
      try{
        $candidateRoot=[IO.Path]::GetFullPath([string]$Record.admissionRoot).TrimEnd('\','/')
        $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
        if((Split-Path -Parent $candidateRoot).TrimEnd('\','/')-ne$tempRoot-or(Split-Path -Leaf $candidateRoot)-cnotmatch'^chase-sets-heavy-admission-[A-Za-z0-9_-]+$'){return $false}
      }catch{return $false}
    }
    try {
      if (-not [IO.Path]::IsPathFullyQualified([string]$Record.worktree)) { return $false }
    } catch {
      return $false
    }
  }
  if ("$($Record.lockId)" -cnotmatch "^[a-f0-9]{32}$" -or
      "$($Record.commandIdentity)" -cnotmatch "^[a-f0-9]{64}$" -or
      "$($Record.lane)" -cnotmatch "^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$" -or
      $Record.gate -cnotin @("verify:static", "check:static", "test:scripts", "verify:test", "test", "test:fast", "build", "verify", "verify:build", "verify:test-db", "repository-gate", "playwright", "vitest-full", "script-battery") -or
      -not (Test-PositivePid $Record.pid) -or
      -not (Test-UtcIdentity ([string]$Record.processStartUtc)) -or
      -not (Test-UtcIdentity ([string]$Record.startedUtc))) {
    return $false
  }
  $processStartedAt = [DateTimeOffset]::Parse([string]$Record.processStartUtc).ToUniversalTime()
  $recordedAt = [DateTimeOffset]::Parse([string]$Record.startedUtc).ToUniversalTime()
  if ($processStartedAt.Ticks -gt $recordedAt.Ticks -or
      $recordedAt.Ticks -gt [DateTimeOffset]::UtcNow.AddMinutes(5).Ticks) {
    return $false
  }
  if ($Record.schemaVersion -eq 1) { return $true }
  if ($Record.schemaVersion -eq 3 -or ($Record.schemaVersion -in @(4,5) -and $Record.state -ceq "attached")) {
    if ($Record.state -cne "attached" -or
        -not (Test-PositivePid $Record.childPid) -or
        -not (Test-UtcIdentity ([string]$Record.childProcessStartUtc))) {
      return $false
    }
    $guardedStartedAt = [DateTimeOffset]::Parse([string]$Record.childProcessStartUtc).ToUniversalTime()
    return $guardedStartedAt.Ticks -le $recordedAt.Ticks
  }
  if ($Record.state -ceq "launching") {
    return $null -eq $Record.childPid -and $null -eq $Record.childProcessStartUtc
  }
  if ($Record.state -ceq "started") {
    if (-not (Test-PositivePid $Record.childPid) -or -not (Test-UtcIdentity ([string]$Record.childProcessStartUtc))) {
      return $false
    }
    $childStartedAt = [DateTimeOffset]::Parse([string]$Record.childProcessStartUtc).ToUniversalTime()
    return $childStartedAt.Ticks -ge $recordedAt.Ticks -and
      $childStartedAt.Ticks -le [DateTimeOffset]::UtcNow.AddMinutes(5).Ticks
  }
  return $false
}
function Get-ProcessIdentityState($ProcessId, [string]$StartIdentity) {
  if (-not (Test-PositivePid $ProcessId) -or -not (Test-UtcIdentity $StartIdentity)) { return "ambiguous" }
  try {
    $candidate = @(Get-Process -Id ([int]$ProcessId) -ErrorAction SilentlyContinue)
    if ($candidate.Count -eq 0) { return "dead" }
    if ($candidate.Count -ne 1) { return "ambiguous" }
    $expected = [DateTimeOffset]::Parse($StartIdentity).ToUniversalTime().Ticks
    $actual = $candidate[0].StartTime.ToUniversalTime().Ticks
    return $(if ($actual -eq $expected) { "live" } else { "reused" })
  } catch {
    return "ambiguous"
  }
}
function Test-PossibleOwnedChild($Record, [switch]$GuardedRootOnly) {
  try {
    $recordedAt = [DateTimeOffset]::Parse([string]$Record.startedUtc).ToUniversalTime()
    $pending = [Collections.Generic.Queue[object]]::new()
    $known = @{}
    $roots = @()
    if (-not $GuardedRootOnly) {
      $roots += [pscustomobject]@{
        ProcessId = [int]$Record.pid
        StartIdentity = [string]$Record.processStartUtc
      }
    }
    if ($Record.state -in @("started", "attached")) {
      $roots += [pscustomobject]@{
        ProcessId = [int]$Record.childPid
        StartIdentity = [string]$Record.childProcessStartUtc
      }
    }
    foreach ($root in $roots) {
      if ($known.ContainsKey($root.ProcessId)) { return $null }
      $known[$root.ProcessId] = $null
      $pending.Enqueue([pscustomobject]@{
        ProcessId = $root.ProcessId
        StartIdentity = $root.StartIdentity
        CreationTicks = $null
      })
    }

    # Re-query each discovered identity before trusting it and again after
    # enumerating its children. Any exit/reuse race stays indeterminate.
    $getCreationUtc = {
      param($Candidate)
      if ($Candidate.CreationDate -is [DateTime]) {
        return ([DateTime]$Candidate.CreationDate).ToUniversalTime()
      }
      return [Management.ManagementDateTimeConverter]::ToDateTime(
        [string]$Candidate.CreationDate
      ).ToUniversalTime()
    }
    $testExactCimIdentity = {
      param([int]$ProcessId, [long]$CreationTicks)
      $exact = @(Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction Stop)
      if ($exact.Count -ne 1) { return $false }
      $exactPid = 0
      if (-not [int]::TryParse([string]$exact[0].ProcessId, [ref]$exactPid) -or
          $exactPid -ne $ProcessId) {
        return $false
      }
      $exactCreatedAt = & $getCreationUtc $exact[0]
      return $exactCreatedAt.Ticks -eq $CreationTicks
    }

    while ($pending.Count -gt 0) {
      $parent = $pending.Dequeue()
      $parentId = [int]$parent.ProcessId
      if ($null -eq $parent.CreationTicks) {
        if ((Get-ProcessIdentityState $parentId $parent.StartIdentity) -cnotin @("dead", "reused")) { return $null }
      } elseif (-not (& $testExactCimIdentity $parentId ([long]$parent.CreationTicks))) {
        return $null
      }

      $candidates = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $parentId" -ErrorAction Stop)
      foreach ($candidate in $candidates) {
        $candidatePid = 0
        $reportedParentId = 0
        if (-not [int]::TryParse([string]$candidate.ProcessId, [ref]$candidatePid) -or
            $candidatePid -le 0 -or
            -not [int]::TryParse([string]$candidate.ParentProcessId, [ref]$reportedParentId) -or
            $reportedParentId -ne $parentId) {
          return $null
        }
        $createdAt = & $getCreationUtc $candidate
        if (-not (& $testExactCimIdentity $candidatePid $createdAt.Ticks)) { return $null }
        if ($createdAt.Ticks -ge $recordedAt.Ticks) { return $true }
        # Older processes cannot be owned workers themselves, but their
        # descendants still have to be walked to find later possible workers.
        if ($known.ContainsKey($candidatePid)) {
          if ($null -eq $known[$candidatePid] -or [long]$known[$candidatePid] -ne $createdAt.Ticks) {
            return $null
          }
          continue
        }
        $known[$candidatePid] = $createdAt.Ticks
        $pending.Enqueue([pscustomobject]@{
          ProcessId = $candidatePid
          StartIdentity = $null
          CreationTicks = $createdAt.Ticks
        })
      }

      if ($null -eq $parent.CreationTicks) {
        if ((Get-ProcessIdentityState $parentId $parent.StartIdentity) -cnotin @("dead", "reused")) { return $null }
      } elseif (-not (& $testExactCimIdentity $parentId ([long]$parent.CreationTicks))) {
        return $null
      }
    }
    return $false
  } catch {
    return $null
  }
}
function Test-ReclaimableOwner($Record) {
  if (-not (Test-OwnerShape $Record) -or $Record.schemaVersion -notin @(2, 3, 4, 5)) { return $false }
  if ((Get-ProcessIdentityState $Record.pid ([string]$Record.processStartUtc)) -cne "dead") { return $false }
  if ($Record.state -in @("started", "attached")) {
    $childState = Get-ProcessIdentityState $Record.childPid ([string]$Record.childProcessStartUtc)
    if ($childState -cnotin @("dead", "reused")) { return $false }
  }
  return (Test-PossibleOwnedChild $Record) -eq $false
}
function Remove-ExactOwnedAdmissionRoot($Record,[switch]$GuardedDeathProven){
  if($Record.schemaVersion-ne5){$script:admissionCleanupDiagnostic='not-schema5';return $true}
  $root=[IO.Path]::GetFullPath([string]$Record.admissionRoot).TrimEnd('\','/')
  $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
  if((Split-Path -Parent $root).TrimEnd('\','/')-ne$temp-or(Split-Path -Leaf $root)-cnotmatch'^chase-sets-heavy-admission-[A-Za-z0-9_-]+$'){$script:admissionCleanupDiagnostic='identity-invalid';return $false}
  if(-not(Test-Path -LiteralPath $root)){$script:admissionCleanupDiagnostic='already-absent';return $true}
  if(-not$GuardedDeathProven){
    if((Get-ProcessIdentityState $Record.pid ([string]$Record.processStartUtc))-cne'dead'){$script:admissionCleanupDiagnostic='wrapper-not-dead';return $true}
    # A reused child permits v2.61 lock reclamation but is not positive proof
    # that this attempt owns temp-root deletion.
    if((Get-ProcessIdentityState $Record.childPid ([string]$Record.childProcessStartUtc))-cne'dead'){$script:admissionCleanupDiagnostic='child-not-exact-dead';return $true}
    if((Test-PossibleOwnedChild $Record)-ne$false){$script:admissionCleanupDiagnostic='possible-child';return $true}
  }
  if(-not(Test-SafeDirectory $root)){$script:admissionCleanupDiagnostic='unsafe-root';return $false}
  try{
    foreach($item in @(Get-ChildItem -LiteralPath $root -Force -Recurse -ErrorAction Stop)){
      if($item.PSIsContainer-or(($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-eq[IO.FileAttributes]::ReparsePoint)){$script:admissionCleanupDiagnostic="unsafe-content:$($item.Name):container=$($item.PSIsContainer):attributes=$($item.Attributes)";return $false}
    }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop
    $removed=-not(Test-Path -LiteralPath $root);$script:admissionCleanupDiagnostic=$(if($removed){'removed'}else{'still-present'});return $removed
  }catch{$script:admissionCleanupDiagnostic="remove-failed:$($_.Exception.Message)";return $false}
}
function Complete-RefusedAttachedAdmission {
  if (-not $isAttachedAdmission -or -not $admissionRoot -or $owner.schemaVersion -ne 5) { return }
  while (Test-Path -LiteralPath $admissionRoot -PathType Container) {
    $guardedState = Get-ProcessIdentityState $GuardedPid $GuardedProcessStartUtc
    if ($guardedState -ceq "live") {
      Start-Sleep -Milliseconds 100
      continue
    }
    if ($guardedState -cne "dead") {
      # A reused or unreadable identity is not deletion authority. Retain the
      # exact root for a later proven owner rather than inferring death.
      return
    }
    $possibleDescendant = Test-PossibleOwnedChild $owner -GuardedRootOnly
    if ($possibleDescendant -eq $false) {
      [void](Remove-ExactOwnedAdmissionRoot $owner -GuardedDeathProven)
      return
    }
    Start-Sleep -Milliseconds 100
  }
}
function Write-OwnerRecord($Record, [switch]$CreateNew) {
  $raw = $Record | ConvertTo-Json -Compress
  if ($CreateNew) {
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($raw)
    $stream = [IO.File]::Open($ownerPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
      $stream.Write($bytes, 0, $bytes.Length)
      $stream.Flush($true)
    } finally {
      $stream.Dispose()
    }
    return $raw
  }
  $temporaryPath = Join-Path $lockPath ("owner.transition." + [guid]::NewGuid().ToString("N") + ".tmp")
  try {
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($raw)
    $stream = [IO.File]::Open($temporaryPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
      $stream.Write($bytes, 0, $bytes.Length)
      $stream.Flush($true)
    } finally {
      $stream.Dispose()
    }
    [IO.File]::Move($temporaryPath, $ownerPath, $true)
    return $raw
  } finally {
    if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
      Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
  }
}
function Restore-ClaimedOwner([string]$ClaimPath) {
  try {
    if ((Test-SafeDirectory $lockPath) -and
        (Test-SafeFile $ClaimPath) -and
        -not (Test-Path -LiteralPath $ownerPath)) {
      $entries = @(Get-ChildItem -LiteralPath $lockPath -Force -ErrorAction Stop)
      if ($entries.Count -eq 1 -and (Test-SamePath $entries[0].FullName $ClaimPath)) {
        [IO.File]::Move($ClaimPath, $ownerPath)
      }
    }
  } catch {
    # A failed restoration is deliberately left fail-closed.
  }
}
function Remove-ClaimedOwnerLock([string]$ClaimPath, [string]$ExpectedRaw, [switch]$RequireDead) {
  $removed = $false
  try {
    if (-not (Test-SafeDirectory $lockPath) -or -not (Test-SafeFile $ClaimPath)) { return $false }
    $entries = @(Get-ChildItem -LiteralPath $lockPath -Force -ErrorAction Stop)
    if ($entries.Count -ne 1 -or -not (Test-SamePath $entries[0].FullName $ClaimPath)) { return $false }
    $stream = [IO.File]::Open($ClaimPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Delete)
    try {
      $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true, 1024, $true)
      try { $raw = $reader.ReadToEnd() } finally { $reader.Dispose() }
      if ($raw -cne $ExpectedRaw) { return $false }
      try { $record = $raw | ConvertFrom-Json -DateKind String -ErrorAction Stop } catch { return $false }
      if ($RequireDead -and -not (Test-ReclaimableOwner $record)) { return $false }
      if($RequireDead-and$record.schemaVersion-eq5-and-not(Remove-ExactOwnedAdmissionRoot $record)){return $false}
      [IO.File]::Delete($ClaimPath)
      $removed = $true
    } finally {
      $stream.Dispose()
    }
    if (Test-Path -LiteralPath $ClaimPath) { return $false }
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction Stop
    return -not (Test-Path -LiteralPath $lockPath)
  } finally {
    if (-not $removed) { Restore-ClaimedOwner $ClaimPath }
  }
}
function Invoke-StaleLockReclamation {
  $snapshot = Get-OwnerSnapshot
  if ($null -eq $snapshot -or -not (Test-ReclaimableOwner $snapshot.Record)) { return $false }
  if ($TestReplaceOwnerBeforeReclaim) {
    [IO.File]::WriteAllText($ownerPath, '{"forged":true}', [Text.UTF8Encoding]::new($false))
  }
  $unchanged = Get-OwnerSnapshot
  if ($null -eq $unchanged -or $unchanged.Raw -cne $snapshot.Raw) { return $false }
  $claimPath = Join-Path $lockPath ("owner.reclaim." + $lockId + ".json")
  try {
    [IO.File]::Move($ownerPath, $claimPath)
  } catch {
    return $false
  }
  return Remove-ClaimedOwnerLock $claimPath $snapshot.Raw -RequireDead
}
function Describe-ExistingLock {
  $snapshot = Get-OwnerSnapshot
  $existing = if ($snapshot) { $snapshot.Record } else { $null }
  $shape = Test-OwnerShape $existing
  $wrapperState = if ($shape) { Get-ProcessIdentityState $existing.pid ([string]$existing.processStartUtc) } else { "ambiguous" }
  $childState = if ($shape -and $existing.schemaVersion -in @(2, 3, 4, 5) -and $existing.state -in @("started", "attached")) {
    Get-ProcessIdentityState $existing.childPid ([string]$existing.childProcessStartUtc)
  } else {
    "none"
  }
  $state = if ($wrapperState -ceq "live" -or $childState -ceq "live") {
    "live-owner"
  } elseif ($shape -and $existing.schemaVersion -in @(2, 3, 4, 5) -and (Test-ReclaimableOwner $existing)) {
    "stale-candidate"
  } else {
    "ambiguous-owner"
  }
  $summary = if ($existing) {
    $identitySummary = if ($existing.branch) { "branch=$($existing.branch)" } elseif ($existing.head) { "head=$($existing.head)" } else { "branch=unknown" }
    "lane=$($existing.lane) $identitySummary pid=$($existing.pid) schema=$($existing.schemaVersion) keys=$(@($existing.PSObject.Properties.Name).Count) shape=$shape"
  } else { "owner=unreadable" }
  throw "heavy-verifier: lock unavailable ($state; $summary). It was not modified."
}
function Assert-LiveGitIdentityUnchanged {
  $live = Get-LiveGitIdentity
  if (-not [string]::Equals($live.Worktree, $acquiredGitIdentity.Worktree, [StringComparison]::OrdinalIgnoreCase) -or
      $live.Head -cne $acquiredGitIdentity.Head -or
      $live.Branch -cne $acquiredGitIdentity.Branch) {
    throw "heavy-verifier: live Git branch or HEAD changed after acquisition; command body was not executed"
  }
  if ($isControllerPrecursor) {
    Assert-ControllerPrecursorGitState
    Assert-ControllerPrecursorArtifactState
  }
}
function Test-ThisOwner {
  $snapshot = Get-OwnerSnapshot
  return $null -ne $snapshot -and
    $snapshot.Raw -ceq $ownedRaw -and
    (Test-OwnerShape $snapshot.Record) -and
    (Get-ProcessIdentityState $snapshot.Record.pid ([string]$snapshot.Record.processStartUtc)) -ceq "live"
}
function Release-ThisLock {
  if (-not (Test-ThisOwner)) { return -not (Test-Path -LiteralPath $lockPath) }
  $claimPath = Join-Path $lockPath ("owner.cleanup." + $lockId + ".json")
  try {
    [IO.File]::Move($ownerPath, $claimPath)
  } catch {
    return $false
  }
  return Remove-ClaimedOwnerLock $claimPath $ownedRaw
}

# Platform Gate/Attach keep the container-only coordination key. Controller
# batteries and precursors coordinate on their own key, so a platform
# acquisition or stale-owner reclamation never delays them (Todd ruling
# 2026-09-10, review r3 F3).
$coordinationKey = $container.ToUpperInvariant()
if ($isControllerBattery -or $isControllerPrecursor) { $coordinationKey += "`n" + $lockDirectoryName }
$mutexHash = [Convert]::ToHexString(
  [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($coordinationKey))
).ToLowerInvariant()
$coordinationMutex = [Threading.Mutex]::new($false, "Global\chase-sets-heavy-verifier-$mutexHash")
$mutexHeld = $false
try {
  try {
    $mutexHeld = $coordinationMutex.WaitOne()
  } catch [Threading.AbandonedMutexException] {
    $mutexHeld = $true
  }
  try {
    New-Item -ItemType Directory -Path $lockPath -ErrorAction Stop | Out-Null
  } catch {
    if (-not (Invoke-StaleLockReclamation)) { Describe-ExistingLock }
    try {
      New-Item -ItemType Directory -Path $lockPath -ErrorAction Stop | Out-Null
    } catch {
      Describe-ExistingLock
    }
  }
} finally {
  if ($mutexHeld) { $coordinationMutex.ReleaseMutex() }
  $coordinationMutex.Dispose()
}

$exitCode = 1
$releaseMismatch = $false
try {
  try {
    # CreateNew prevents a forged pre-existing record from being overwritten.
    $ownedRaw = Write-OwnerRecord $owner -CreateNew
  } catch {
    throw "heavy-verifier: unable to write owner record; lock will be released only if still ours"
  }
  if (-not (Test-ThisOwner)) { throw "heavy-verifier: owner validation failed immediately after acquisition" }
  if ($TestDelayIdentityRevalidationMilliseconds -gt 0) {
    Start-Sleep -Milliseconds $TestDelayIdentityRevalidationMilliseconds
  }
  Assert-LiveGitIdentityUnchanged
  if ($isAttachedAdmission) {
    Write-AdmissionResult $true "admitted" $owner
    while ($true) {
      $guardedState = Get-ProcessIdentityState $GuardedPid $GuardedProcessStartUtc
      if ($guardedState -ceq "live") {
        Start-Sleep -Milliseconds 100
        continue
      }
      if ($guardedState -cne "dead") {
        # Ambiguity and PID reuse remain fail-closed. A later exact stale-owner
        # pass must not release while the recorded identity cannot be disproven.
        Start-Sleep -Milliseconds 100
        continue
      }
      $possibleDescendant = Test-PossibleOwnedChild $owner -GuardedRootOnly
      if ($possibleDescendant -eq $false) {$attachedDeadTreeProven=$true;break}
      Start-Sleep -Milliseconds 100
    }
    $exitCode = 0
  } else {
    if ($TestCancelAfterAcquisition) { throw [OperationCanceledException]::new("heavy-verifier test cancellation") }
    # ProcessStartInfo.ArgumentList preserves each argument verbatim; unlike
    # Start-Process -ArgumentList it does not re-join paths containing spaces.
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $command
    $start.WorkingDirectory = $worktreeFull
    $start.UseShellExecute = $false
    # An explicitly wrapped gate already owns the slot. Its child tree must
    # inherit the launcher's original Node options, not recursively invoke the
    # direct-command preload and contend with its own exact owner.
    if ($start.Environment.ContainsKey("CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_NODE_OPTIONS")) {
      $start.Environment["NODE_OPTIONS"] = $start.Environment["CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_NODE_OPTIONS"]
      [void]$start.Environment.Remove("CHASE_SETS_HEAVY_ADMISSION_CONFIG")
      [void]$start.Environment.Remove("CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_NODE_OPTIONS")
    }
    if ($start.Environment.ContainsKey("CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_SCRIPT_SHELL")) {
      $originalScriptShell = $start.Environment["CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_SCRIPT_SHELL"]
      if ([string]::IsNullOrEmpty($originalScriptShell)) {
        [void]$start.Environment.Remove("npm_config_script_shell")
      } else {
        $start.Environment["npm_config_script_shell"] = $originalScriptShell
      }
      foreach ($name in @(
          "CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_SCRIPT_SHELL",
          "CHASE_SETS_HEAVY_ADMISSION_PNPM_SCRIPT_SHELL"
        )) {
        [void]$start.Environment.Remove($name)
      }
    }
    $start.Environment["CHASE_SETS_HEAVY_SLOT_ID"] = $lockId
    foreach ($argument in $arguments) { [void]$start.ArgumentList.Add($argument) }
    $child = [Diagnostics.Process]::Start($start)
    if ($TestDelayChildPublicationMilliseconds -gt 0) {
      Start-Sleep -Milliseconds $TestDelayChildPublicationMilliseconds
    }
    $childStarted = $child.StartTime.ToUniversalTime().ToString("o")
    $startedOwner = [ordered]@{}
    foreach ($entry in $owner.GetEnumerator()) { $startedOwner[$entry.Key] = $entry.Value }
    $startedOwner.state = "started"
    $startedOwner.childPid = $child.Id
    $startedOwner.childProcessStartUtc = $childStarted
    $startedRaw = Write-OwnerRecord $startedOwner
    $owner = $startedOwner
    $ownedRaw = $startedRaw
    if (-not (Test-ThisOwner)) { throw "heavy-verifier: owner validation failed after child publication" }
    $child.WaitForExit()
    if ($isControllerPrecursor) {
      while ((Test-PossibleOwnedChild $owner -GuardedRootOnly) -ne $false) {
        Start-Sleep -Milliseconds 100
      }
    }
    if ($TestReplaceOwnerBeforeCleanup) {
      [IO.File]::WriteAllText($ownerPath, '{"forged":true}', [Text.UTF8Encoding]::new($false))
    }
    $exitCode = $child.ExitCode
    if ($isControllerPrecursor -and $exitCode -eq 0) {
      Assert-ControllerPrecursorArtifactState -AfterSuccess
    }
  }
} finally {
  if($isAttachedAdmission-and$attachedDeadTreeProven-and-not(Remove-ExactOwnedAdmissionRoot $owner -GuardedDeathProven)){
    $releaseMismatch=$true
  }else{
    $releaseMismatch = -not (Release-ThisLock)
  }
}
if ($releaseMismatch) {
  [Console]::Error.WriteLine("heavy-verifier: refusing cleanup because lock ownership no longer matches this caller (admission-root=$admissionCleanupDiagnostic)")
  exit 1
}
exit $exitCode
