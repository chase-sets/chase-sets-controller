<#
.SYNOPSIS
Runs one supported repository-wide heavy verification gate under the container
exclusive verifier lock. This is deliberately the only command entrypoint;
callers cannot supply an arbitrary shell string or bypass the gate inventory.

.DESCRIPTION
-ControllerFixtureEquivalence (#9627) is the closed controller-slot route for
the existing full #9275 cleanup-scale fixture-equivalence check. It resolves
only the target's tracked .orchestrator/cleanup-scale-fixture-equivalence.check.ps1
and tracked harness at the clean exact HEAD, whose on-disk bytes must equal
their HEAD blobs (exactly or as the uniform CRLF checkout), and runs exactly
  pwsh -NoProfile -NonInteractive -File <check> -Phase fixture -EvidenceDirectory <dir>
<dir> is -ControllerFixtureEvidenceDirectory: one absolute, new [A-Za-z0-9_-]
directory directly below <container-parent>\<container-name>-heavy-evidence.
That root is anchored to the wrapper's existing container context, the same
one that selects its lock slot and ownership census; this route does not
harden that shared seam. The root and every existing ancestor must be plain
directories outside every Git worktree and the runtime root. After exact owner
release the wrapper writes heavy-verifier-receipt.json there. The check's own
verdict belongs to #9275.
#>
[CmdletBinding(DefaultParameterSetName = "Gate")]
param(
  [Parameter(Mandatory, ParameterSetName = "Gate")][ValidateSet("verify:static", "check:static", "test:scripts", "verify:test", "test", "test:fast", "build", "verify", "verify:build", "verify:test-db", "test:e2e:suite")][string]$Gate,
  [Parameter(ParameterSetName = "Gate")][ValidatePattern('^[a-z][a-z0-9_]*$')][string]$E2eSuite,
  [Parameter(Mandatory, ParameterSetName = "WorkspaceTest")][ValidateSet("@chase-sets/ordering")][string]$WorkspaceTest,
  [Parameter(Mandatory, ParameterSetName = "WorkspaceDbTest")][ValidateSet("@chase-sets/payments", IgnoreCase = $false)][string]$WorkspaceDbTest,
  [Parameter(ParameterSetName = "WorkspaceDbTest")][string]$WorkspaceDbTestFile,
  [Parameter(Mandatory, ParameterSetName = "WorkspaceDbTest")][double]$WorkspaceDbBudgetSeconds,
  # Host-declared diagnostics are a closed, case-sensitive name set. A
  # standalone Node entry retains its pinned path and source digest. The
  # Vitest command kind pins its complete argv and binds its tracked test
  # entry to the admitted exact Git head.
  [Parameter(Mandatory, ParameterSetName = "Diagnostic")][string]$Diagnostic,
  [Parameter(ParameterSetName = "Diagnostic")][string]$DiagnosticScriptPath,
  [Parameter(ParameterSetName = "Diagnostic")][ValidatePattern("^[a-fA-F0-9]{64}$")][string]$DiagnosticSha256,
  [Parameter(ParameterSetName = "Diagnostic")][double]$DiagnosticBudgetSeconds,
  [Parameter(Mandatory, ParameterSetName = "NativeDb")][ValidateSet("reconciliation-pg16/v1", IgnoreCase = $false)][string]$NativeDbProfile,
  [Parameter(Mandatory, ParameterSetName = "NativeDb")][string]$NativeRequestPath,
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
  [Parameter(DontShow)][ValidatePattern('^[a-f0-9]{64}$')][string]$QuarantineQueue,
  # Queue-only fault/clock/probe controls, confined to the existing temp fixture
  # surface. They never replace caller eligibility or lock-owner probes.
  [Parameter(DontShow)][string]$TestQueueFixture,
  [Parameter(DontShow)][switch]$TestCancelAfterAcquisition,
  [Parameter(DontShow)][switch]$TestReplaceOwnerBeforeCleanup,
  [Parameter(DontShow)][switch]$TestReplaceOwnerBeforeReclaim,
  [Parameter(DontShow)][ValidateRange(0, 30000)][int]$TestDelayIdentityRevalidationMilliseconds,
  [Parameter(DontShow)][ValidateRange(0, 30000)][int]$TestDelayChildPublicationMilliseconds,
  [Parameter(DontShow)][ValidateRange(0, 30000)][int]$TestDelayDiagnosticLaunchMilliseconds,
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
  # Impact or full scope and an optional prior result for reuse (#8207).
  [Parameter(ParameterSetName = "ControllerBattery", DontShow)][ValidateSet("impact", "full")][string]$ControllerBatteryScope = "impact",
  [Parameter(ParameterSetName = "ControllerBattery", DontShow)][string]$ControllerBatteryPriorResultPath = "",
  # Per-item reuse stop (#9373), forwarded verbatim as one argument.
  [Parameter(ParameterSetName = "ControllerBattery", DontShow)][string]$ControllerBatteryNoReuseIdentity = "",
  # Concurrent battery items (#120), forwarded verbatim as one argument.
  [Parameter(ParameterSetName = "ControllerBattery", DontShow)][string]$ControllerBatteryConcurrentIdentity = "",
  [Parameter(ParameterSetName = "ControllerBattery", DontShow)][ValidateSet("stop", "all")][string]$ControllerBatteryOnFailure = "stop",
  # The canonical battery supplies its own process identity. This avoids a
  # parent-process inference at the controller admission seam.
  [Parameter(ParameterSetName = "ControllerBattery", DontShow)][ValidateRange(0, [int]::MaxValue)][int]$ControllerBatteryClaimantPid = 0,
  [Parameter(ParameterSetName = "ControllerBattery", DontShow)][string]$ControllerBatteryClaimantStartUtc = "",
  # Guard-evidence precursor producers are a closed production surface. The
  # selected value resolves to one tracked script and one fixed grammar below.
  [Parameter(Mandatory, ParameterSetName = "ControllerPrecursor")]
  [ValidateSet("fail-closed-guard-evidence", "issue-6254-fail-closed-guard-evidence")]
  [string]$ControllerPrecursor,
  [Parameter(Mandatory, ParameterSetName = "ControllerPrecursor")][string]$ControllerPrecursorArtifactPath,
  [Parameter(ParameterSetName = "ControllerPrecursor")]
  [ValidateSet("ReceiptClaims")]
  [string]$ControllerPrecursorScenario,
  # The full fixture-equivalence check is one closed route: a tracked script,
  # fixed -Phase fixture and one validated evidence directory (#9627).
  [Parameter(Mandatory, ParameterSetName = "ControllerFixtureEquivalence")][switch]$ControllerFixtureEquivalence,
  [Parameter(Mandatory, ParameterSetName = "ControllerFixtureEquivalence")][string]$ControllerFixtureEvidenceDirectory,
  # The complete default host-heavy-verifier file is a controller-slot member.
  # Its target and grammar are closed below; no command or payload is accepted.
  [Parameter(Mandatory, ParameterSetName = "ControllerHostHeavyVerifier")][switch]$ControllerHostHeavyVerifier,
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
$script:heavyAdmissionBudget = @{ watch=[Diagnostics.Stopwatch]::StartNew(); deadline=210000; observations=0; fences=0 }
$script:heavyAdmissionPriorityRaised = $false
$script:heavyAdmissionPriorityClass = $null
$script:heavyAdmissionPriorityDepth = 0
$script:heavyAdmissionPriorityFailureReported = $false
$script:heavyAdmissionPriorityRestoreFailureReported = $false
$script:heavyAdmissionQuitAfterQuarantine = $false
$isAttachedAdmission = $PSCmdlet.ParameterSetName -ceq "Attach"
$isControllerBattery = $PSCmdlet.ParameterSetName -ceq "ControllerBattery"
$isControllerPrecursor = $PSCmdlet.ParameterSetName -ceq "ControllerPrecursor"
$isControllerFixture = $PSCmdlet.ParameterSetName -ceq "ControllerFixtureEquivalence"
$isControllerHostHeavyVerifier = $PSCmdlet.ParameterSetName -ceq "ControllerHostHeavyVerifier"
$isWorkspaceTest = $PSCmdlet.ParameterSetName -ceq "WorkspaceTest"
$isWorkspaceDbTest = $PSCmdlet.ParameterSetName -ceq "WorkspaceDbTest"
$isNativeDb = $PSCmdlet.ParameterSetName -ceq "NativeDb"
$isDiagnostic = $PSCmdlet.ParameterSetName -ceq "Diagnostic"
$isProductSlot = -not ($isControllerBattery -or $isControllerPrecursor -or $isControllerFixture -or $isControllerHostHeavyVerifier)
$isControllerSlot = $isControllerBattery -or $isControllerPrecursor -or $isControllerFixture -or $isControllerHostHeavyVerifier
$isQueueSlot = $isProductSlot -or $isControllerSlot
$hasControllerBatteryClaimant = $isControllerBattery -and $ControllerBatteryClaimantPid -gt 0
$hostHeavyPayloadKeys = @('QuarantineQueue','TestQueueFixture','TestCancelAfterAcquisition','TestReplaceOwnerBeforeCleanup',
  'TestReplaceOwnerBeforeReclaim','TestDelayIdentityRevalidationMilliseconds','TestDelayChildPublicationMilliseconds',
  'TestDelayDiagnosticLaunchMilliseconds')
if ($isControllerHostHeavyVerifier -and @($hostHeavyPayloadKeys | Where-Object { $PSBoundParameters.ContainsKey($_) }).Count -gt 0) {
  throw 'heavy-verifier: ControllerHostHeavyVerifier accepts no payload or test switches'
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

if ($hasControllerBatteryClaimant -and -not (Test-UtcIdentity $ControllerBatteryClaimantStartUtc)) {
  throw 'heavy-verifier: controller battery claimant identity is unavailable'
}
if ($isControllerBattery -and $ControllerBatteryClaimantPid -eq 0 -and -not [string]::IsNullOrWhiteSpace($ControllerBatteryClaimantStartUtc)) {
  throw 'heavy-verifier: controller battery claimant identity is unavailable'
}
$isBudgetedWorkspaceDb = $isWorkspaceDbTest
$isTimedRoute = $isDiagnostic -or $isBudgetedWorkspaceDb
$diagnosticBudgetSupplied = $PSBoundParameters.ContainsKey('DiagnosticBudgetSeconds')
$nativeRequest = $null
$nativeReplyWritten = $false
$nativeCleanupProof = $null
if ($isWorkspaceTest) { $WorkspaceTest = "@chase-sets/ordering" }
# This closed command shape selects production command resolution. Caller
# authority is determined independently by the native census below.
$isHostVerifier = ($PSCmdlet.ParameterSetName -cin @("Gate", "WorkspaceTest", "WorkspaceDbTest", "Diagnostic")) -and -not $CommandPath
$admissionResultFull = $null
$script:admissionPendingSequence = 0
$admissionRoot = $null
$attachedDeadTreeProven = $false
$admissionCleanupDiagnostic = 'not-attempted'
$script:quarantineCompleted = $false

function Enter-HeavyAdmissionPriority {
  $script:heavyAdmissionPriorityDepth++
  if (-not $IsWindows -or $script:heavyAdmissionPriorityDepth -gt 1) { return }
  $process = $null
  try {
    $process = [Diagnostics.Process]::GetCurrentProcess()
    $script:heavyAdmissionPriorityClass = $process.PriorityClass
    if ($process.PriorityClass -notin @([Diagnostics.ProcessPriorityClass]::BelowNormal, [Diagnostics.ProcessPriorityClass]::Idle)) { return }
    try {
      $process.PriorityClass = [Diagnostics.ProcessPriorityClass]::Normal
      $script:heavyAdmissionPriorityRaised = $true
    } catch {
      if (-not $script:heavyAdmissionPriorityFailureReported) {
        [Console]::Error.WriteLine("heavy-verifier: admission priority raise failed; continuing at inherited class: $($_.Exception.Message)")
        $script:heavyAdmissionPriorityFailureReported = $true
      }
    }
  } catch {
    if (-not $script:heavyAdmissionPriorityFailureReported) {
      [Console]::Error.WriteLine("heavy-verifier: admission priority raise failed; continuing at inherited class: $($_.Exception.Message)")
      $script:heavyAdmissionPriorityFailureReported = $true
    }
  } finally {
    if ($process) { $process.Dispose() }
  }
}

function Exit-HeavyAdmissionPriority {
  if ($script:heavyAdmissionPriorityDepth -gt 0) { $script:heavyAdmissionPriorityDepth-- }
  if ($script:heavyAdmissionPriorityDepth -gt 0 -or -not $script:heavyAdmissionPriorityRaised) { return $true }
  $process = $null
  $restoreError = $null
  $restored = $false
  try {
    $process = [Diagnostics.Process]::GetCurrentProcess()
    try {
      $process.PriorityClass = $script:heavyAdmissionPriorityClass
      $restored = $process.PriorityClass -eq $script:heavyAdmissionPriorityClass
      if (-not $restored) { throw "priority class remained $($process.PriorityClass)" }
    } catch {
      $restoreError = $_
    }
  } catch {
    $restoreError = $_
  } finally {
    if ($process) { $process.Dispose() }
    $script:heavyAdmissionPriorityRaised = $false
  }
  if ($restoreError) {
    if (-not $script:heavyAdmissionPriorityRestoreFailureReported) {
      [Console]::Error.WriteLine("heavy-verifier: admission priority restore failed; child launch is refused: $($restoreError.Exception.Message)")
      $script:heavyAdmissionPriorityRestoreFailureReported = $true
    }
    return $false
  }
  return $restored
}

function Invoke-HeavyAdmissionCensus([scriptblock]$Action) {
  Enter-HeavyAdmissionPriority
  $actionError = $null
  $actionOutput = @()
  $restoreComplete = $false
  try {
    # Dot-source so admission state assigned by the action remains in the
    # verifier's scope while the priority scope covers the whole action.
    $actionOutput = @(. $Action)
  } catch {
    $actionError = $_
  } finally {
    $restoreComplete = Exit-HeavyAdmissionPriority
  }
  if ($actionError) { throw $actionError }
  if (-not $restoreComplete) { throw 'heavy-verifier: admission priority restoration could not be proven' }
  return $actionOutput
}

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
  # The validated attached-result transport field carries the nested-owner
  # descriptor (issue #7941) to the guarded process's descendants. It is
  # transport only; the signed per-call reply remains the authority.
  if ($Accepted -and $script:nestedTransport) { $result.transport = $script:nestedTransport }
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
  if ($isNativeDb) {
    if ($nativeRequest -and -not $nativeReplyWritten) {
      Write-NativeReply $(if ($ownedRaw) { 'unknown' } else { 'refused' }) $_.Exception.Message
    }
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 73
  }
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
  if ($_.Exception.Message.StartsWith('heavy-verifier: caller eligibility:', [StringComparison]::Ordinal) -or
      $_.Exception.Message.StartsWith('heavy-verifier: verify queue', [StringComparison]::Ordinal) -or
      $_.Exception.Message.StartsWith('heavy-verifier: queued;', [StringComparison]::Ordinal) -or
      $_.Exception.Message.StartsWith('heavy-verifier: unable to persist queue', [StringComparison]::Ordinal)) {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 73
  }
  if ($isControllerSlot -and $_.Exception.Message.StartsWith("heavy-verifier: lock unavailable (", [StringComparison]::Ordinal)) {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 73
  }
  if ($isHostVerifier -or $isControllerHostHeavyVerifier) {
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
if ($CommandPath -or $CommandArgumentList -or $TestQueueFixture -or ($isDiagnostic -and $PSBoundParameters.ContainsKey('ContainerRoot'))) {
  $fixtureTemp = if ($IsWindows) {
    [IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Temp')).TrimEnd('\','/')
  } else { [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/') }
  if (-not $container.StartsWith($fixtureTemp + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "heavy-verifier: arbitrary commands are fixture-only; use invoke-heavy-verifier.ps1 -Gate or -WorkspaceTest"
  }
}
$queueFixture = $null
if ($TestQueueFixture) {
  $fixturePath = [IO.Path]::GetFullPath($TestQueueFixture)
  if (-not $fixturePath.StartsWith($container + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'heavy-verifier: verify queue fixture must be inside its temporary container'
  }
  $queueFixture = Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json -DateKind String
}
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

function Test-LaneBranchHistory {
  # Only attached lane admission treats the launch SHA as a branch-history
  # anchor. Host/exact-head gates and detached review keep their exact binding.
  if (-not $isAttachedAdmission) { return $false }
  $entries = @(& git -C $worktreeFull reflog show --format='%H%x09%gs' "refs/heads/$Branch" 2>$null)
  if ($LASTEXITCODE -ne 0 -or $entries.Count -eq 0) { return $false }
  $newer = $null
  $transition = $null
  foreach ($entry in $entries) {
    $fields = $entry -split "`t", 2
    $older = $fields[0]
    if ($older -cnotmatch '^[a-f0-9]{40}$' -or $fields.Count -ne 2) { return $false }
    if ($null -eq $newer) {
      if ($older -cne $acquiredGitIdentity.Head) { return $false }
    } else {
      & git -C $worktreeFull merge-base --is-ancestor $older $newer 2>$null
      if ($LASTEXITCODE -ne 0) {
        # A completed in-branch rebase records its rewritten tip in this
        # branch's own reflog. Require related history, not an arbitrary reset
        # or a SHA that merely exists elsewhere in the repository.
        if (-not $transition.StartsWith('rebase (finish):', [StringComparison]::Ordinal)) { return $false }
        $common = @(& git -C $worktreeFull merge-base $older $newer 2>$null)
        if ($LASTEXITCODE -ne 0 -or $common.Count -ne 1) { return $false }
      }
    }
    if ($older -ceq $ClaimedHead) { return $true }
    $newer = $older
    $transition = $fields[1]
  }
  return $false
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
  if ($ClaimedHead -cne $acquiredGitIdentity.Head -and
      -not (Test-LaneBranchHistory)) {
    throw "heavy-verifier: supplied exact launch-time HEAD does not match the live Git HEAD; command body was not executed"
  }
} else {
  $ImmutableHead = $ImmutableHead.ToLowerInvariant()
  if (-not [string]::IsNullOrWhiteSpace($acquiredGitIdentity.Branch) -or
      $ImmutableHead -cne $acquiredGitIdentity.Head) {
    throw "heavy-verifier: explicit immutable HEAD requires detached Git state at the exact supplied SHA; command body was not executed"
  }
}

function Assert-HostVerifierGitState {
  if (-not $isHostVerifier -and -not $isNativeDb) { return }
  $status = Invoke-GitIdentityProbe @("status", "--porcelain=v1", "--untracked-files=all", "--ignore-submodules=none") "clean state"
  if ($status) {
    $preview = (@($status -split "`r?`n" | Select-Object -First 5) -join "`n")
    throw "heavy-verifier: host verifier requires a clean exact-head worktree`n$preview"
  }
}
# Status trusts the index and stat data, so an assume-unchanged or
# skip-worktree entry (or a restored mtime) can hide edited bytes, and Vite's
# module runner and config bundler read sources with fs, outside the preload's
# module hooks. For vitest-command the verifier therefore opens every regular
# file tracked at the exact HEAD with FileShare.Read, proves the bytes read
# through that handle are the HEAD blob (or its uniform CRLF checkout), and
# holds every handle until the child tree is proven dead. No index flag,
# stat cache or Git filter is consulted, and no tracked file can be rewritten,
# replaced or deleted while the command runs.
$diagnosticExactHeadTree = $null
function Initialize-DiagnosticExactHeadTreeType {
  if ('HeavyExactHeadTree' -as [type]) { return }
  Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Text;
public sealed class HeavyExactHeadTree : IDisposable {
  readonly List<FileStream> streams = new List<FileStream>();
  readonly HashSet<string> tracked = new HashSet<string>(StringComparer.Ordinal);
  public int HeldCount { get { return streams.Count; } }
  public bool IsTracked(string relative) { return tracked.Contains(relative); }
  public static byte[] Git(string root, params string[] arguments) {
    var start = new ProcessStartInfo("git") { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true };
    start.ArgumentList.Add("-C"); start.ArgumentList.Add(root);
    foreach (var argument in arguments) start.ArgumentList.Add(argument);
    using (var process = Process.Start(start)) {
      var error = process.StandardError.ReadToEndAsync();
      using (var output = new MemoryStream()) {
        process.StandardOutput.BaseStream.CopyTo(output);
        process.WaitForExit(); error.Wait();
        if (process.ExitCode != 0) throw new InvalidOperationException("git " + arguments[0] + " was unavailable");
        return output.ToArray();
      }
    }
  }
  static string[] Records(byte[] output) { return new UTF8Encoding(false, true).GetString(output).Split('\0', StringSplitOptions.RemoveEmptyEntries); }
  static string BlobId(byte[] bytes, int length, int oidLength) {
    using (var hash = oidLength == 64 ? IncrementalHash.CreateHash(HashAlgorithmName.SHA256) : IncrementalHash.CreateHash(HashAlgorithmName.SHA1)) {
      hash.AppendData(Encoding.ASCII.GetBytes("blob " + length + "\0"));
      hash.AppendData(bytes, 0, length);
      return Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
    }
  }
  // The HEAD blob itself, or its uniform CRLF checkout (core.autocrlf on a CR-free blob).
  static bool MatchesBlob(byte[] bytes, string oid) {
    if (BlobId(bytes, bytes.Length, oid.Length) == oid) return true;
    var lf = new byte[bytes.Length]; int count = 0; bool sawLf = false;
    for (int index = 0; index < bytes.Length; index++) {
      if (bytes[index] == 13) { if (index + 1 >= bytes.Length || bytes[index + 1] != 10) return false; continue; }
      if (bytes[index] == 10) { if (index == 0 || bytes[index - 1] != 13) return false; sawLf = true; }
      lf[count++] = bytes[index];
    }
    return sawLf && BlobId(lf, count, oid.Length) == oid;
  }
  static bool IsReparse(string path) { return (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0; }
  public static HeavyExactHeadTree Hold(string root, string head) {
    var tree = new HeavyExactHeadTree();
    var safeDirectories = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    var rootFull = Path.GetFullPath(root).TrimEnd('\\', '/');
    try {
      foreach (var record in Records(Git(rootFull, "ls-tree", "-r", "-z", "--full-tree", head))) {
        int tab = record.IndexOf('\t');
        var meta = tab > 0 ? record.Substring(0, tab).Split(' ') : new string[0];
        var relative = tab > 0 ? record.Substring(tab + 1) : record;
        if (meta.Length != 3 || meta[1] != "blob" || (meta[0] != "100644" && meta[0] != "100755") ||
            (meta[2].Length != 40 && meta[2].Length != 64)) {
          throw new InvalidOperationException("exact-head tree entry is not a regular file: " + relative);
        }
        tree.tracked.Add(relative);
        var full = Path.GetFullPath(Path.Combine(rootFull, relative.Replace('/', Path.DirectorySeparatorChar)));
        if (!full.StartsWith(rootFull + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) {
          throw new InvalidOperationException("exact-head tracked file escaped the worktree: " + relative);
        }
        FileStream stream;
        try {
          for (var directory = Path.GetDirectoryName(full); directory.Length > rootFull.Length && !safeDirectories.Contains(directory); directory = Path.GetDirectoryName(directory)) {
            if (IsReparse(directory)) throw new IOException("reparse point");
            safeDirectories.Add(directory);
          }
          if (IsReparse(full)) throw new IOException("reparse point");
          stream = new FileStream(full, FileMode.Open, FileAccess.Read, FileShare.Read, 1, FileOptions.None);
        } catch (Exception) {
          throw new InvalidOperationException("exact-head tracked file is absent, unsafe or unreadable: " + relative);
        }
        tree.streams.Add(stream);
        var bytes = new byte[stream.Length];
        int offset = 0, read;
        while (offset < bytes.Length && (read = stream.Read(bytes, offset, bytes.Length - offset)) > 0) offset += read;
        if (offset != bytes.Length || stream.ReadByte() != -1 || !MatchesBlob(bytes, meta[2])) {
          throw new InvalidOperationException("tracked file bytes do not match the exact HEAD blob: " + relative);
        }
      }
    } catch { tree.Dispose(); throw; }
    return tree;
  }
  // An ignored path is admitted only under node_modules where the preload
  // admits it (the worktree root, or beside a package.json tracked at HEAD), or
  // under an exempt directory. Returns the first other ignored path, or null.
  public string FindUnadmittedIgnoredPath(string root, string[] exemptDirectories) {
    var listing = Records(Git(root, "ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory"));
    foreach (var entry in listing) {
      if (IsAdmittedIgnored(entry, exemptDirectories)) continue;
      bool containsExempt = false;
      foreach (var exempt in exemptDirectories) {
        if (entry.EndsWith("/") && exempt.StartsWith(entry, StringComparison.OrdinalIgnoreCase)) containsExempt = true;
      }
      if (!containsExempt) return entry;
      foreach (var file in Records(Git(root, "ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--", ":(literal)" + entry))) {
        if (!IsAdmittedIgnored(file, exemptDirectories)) return file;
      }
    }
    return null;
  }
  bool IsAdmittedIgnored(string entry, string[] exemptDirectories) {
    foreach (var exempt in exemptDirectories) {
      if (entry.StartsWith(exempt, StringComparison.OrdinalIgnoreCase)) return true;
    }
    var segments = entry.TrimEnd('/').Split('/');
    for (int index = 0; index < segments.Length; index++) {
      if (!string.Equals(segments[index], "node_modules", StringComparison.OrdinalIgnoreCase)) continue;
      if (index == 0) return true;
      if (tracked.Contains(string.Join("/", segments, 0, index) + "/package.json")) return true;
    }
    return false;
  }
  public void Dispose() { foreach (var stream in streams) stream.Dispose(); streams.Clear(); }
}
'@
}
function Get-DiagnosticExactHeadFailure($ErrorRecord) {
  return $ErrorRecord.Exception.GetBaseException().Message
}
function Open-DiagnosticExactHeadTree {
  Initialize-DiagnosticExactHeadTreeType
  try {
    $tree = [HeavyExactHeadTree]::Hold($worktreeFull, $acquiredGitIdentity.Head)
  } catch {
    throw "heavy-verifier: vitest-command $(Get-DiagnosticExactHeadFailure $_)"
  }
  if (-not $tree.IsTracked('vitest.scripts.config.mjs')) {
    $tree.Dispose()
    throw 'heavy-verifier: vitest-command config is not tracked at the admitted exact head'
  }
  return $tree
}
# Vite reads imports, the config and its .env files with fs, so an ignored file
# could be evaluated without a manifest record. Ignored paths are admitted only
# where the preload admits modules: node_modules beside a package.json tracked
# at HEAD (or at the root), the resolved pnpm installation root, and the
# verifier-owned receipt root .orchestrator/artifacts/. Untracked files are
# already refused by the clean-status check.
function Assert-DiagnosticIgnoredPathsAdmitted {
  $exempt = [Collections.Generic.List[string]]::new()
  $exempt.Add('.orchestrator/artifacts/')
  $pnpmRoot = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $pnpmScript) '..')).TrimEnd('\', '/')
  if ($pnpmRoot.StartsWith($worktreeFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    $exempt.Add(([IO.Path]::GetRelativePath($worktreeFull, $pnpmRoot).Replace('\', '/')) + '/')
  }
  try {
    $unadmitted = $diagnosticExactHeadTree.FindUnadmittedIgnoredPath($worktreeFull, $exempt.ToArray())
  } catch {
    throw "heavy-verifier: vitest-command ignored-path inventory was unavailable"
  }
  if ($unadmitted) {
    throw "heavy-verifier: vitest-command worktree has an ignored path outside admitted node_modules: $unadmitted"
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
$diagnosticScriptFull = $null
$diagnosticDefinition = $null
$diagnosticDependencies = @()
$diagnosticVitestCommand = $false
$diagnosticCommandArguments = @()
function Assert-DiagnosticPathNoReparse([string]$Path, [string]$Description) {
  $current = [IO.Path]::GetFullPath($Path)
  while ($current -and (Test-Path -LiteralPath $current)) {
    $item = Get-Item -LiteralPath $current -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne [IO.FileAttributes]::None) {
      throw "heavy-verifier: $Description contains a reparse point"
    }
    $parent = Split-Path -Parent $current
    if ($parent -eq $current) { break }
    $current = $parent
  }
}
function Assert-DiagnosticDeclaration {
  if (-not $isDiagnostic) { return }
  $declarationPath = Join-Path $container '.orchestrator\diagnostic-declarations.json'
  if (-not (Test-Path -LiteralPath $declarationPath -PathType Leaf)) {
    throw "heavy-verifier: diagnostic declaration file is unavailable"
  }
  Assert-DiagnosticPathNoReparse $declarationPath 'diagnostic declaration'
  try {
    $declarations = [IO.File]::ReadAllText($declarationPath) | ConvertFrom-Json -ErrorAction Stop
  } catch {
    throw "heavy-verifier: diagnostic declaration file is unreadable"
  }
  if ($declarations.schema -cne 'host-heavy-diagnostic-declarations/v1' -or $null -eq $declarations.diagnostics) {
    throw "heavy-verifier: diagnostic declaration file has an invalid schema"
  }
  $definition = $declarations.diagnostics.PSObject.Properties | Where-Object Name -ceq $Diagnostic | Select-Object -First 1
  if ($null -eq $definition) {
    throw "heavy-verifier: diagnostic name is not declared"
  }
  $definition = $definition.Value
  if ($definition.enabled -ne $true -or [string]::IsNullOrWhiteSpace([string]$definition.path)) {
    throw "heavy-verifier: diagnostic declaration is not populated"
  }
  $diagnosticKind = [string]$definition.kind
  if ($diagnosticKind -cnotin @('standalone-node', 'vitest-command')) {
    throw "heavy-verifier: diagnostic declaration kind is not supported"
  }
  if (-not $diagnosticBudgetSupplied) {
    throw "heavy-verifier: diagnostic budget is required"
  }
  if ([double]::IsNaN($DiagnosticBudgetSeconds) -or [double]::IsInfinity($DiagnosticBudgetSeconds) -or
      $DiagnosticBudgetSeconds -le 0 -or $DiagnosticBudgetSeconds -gt 86400) {
    throw "heavy-verifier: diagnostic budget must be finite and greater than zero"
  }
  $declaredPath = ([string]$definition.path).Replace('\', '/')
  if ([IO.Path]::IsPathFullyQualified($declaredPath) -or
      $declaredPath -cnotmatch '^[A-Za-z0-9._/-]+\.mjs$' -or
      @($declaredPath.Split('/') | Where-Object { $_ -in @('', '.', '..') }).Count -gt 0) {
    throw "heavy-verifier: diagnostic declaration path must be a normalized repository-relative .mjs path"
  }
  $callerPath = if ($DiagnosticScriptPath) { $DiagnosticScriptPath.Replace('\', '/') } else { $null }
  $declaredHash = $null
  if ($diagnosticKind -ceq 'standalone-node') {
    if ([string]::IsNullOrWhiteSpace($callerPath)) {
      throw "heavy-verifier: standalone-node diagnostics require a script path"
    }
    if ([IO.Path]::IsPathFullyQualified($callerPath) -or
        $callerPath -cnotmatch '^[A-Za-z0-9._/-]+\.mjs$' -or
        @($callerPath.Split('/') | Where-Object { $_ -in @('', '.', '..') }).Count -gt 0) {
      throw "heavy-verifier: diagnostic script must be a repository-relative standalone .mjs path"
    }
    if ($callerPath -cne $declaredPath) {
      throw "heavy-verifier: diagnostic script path does not match host declaration"
    }
    $declaredHash = [string]$definition.sha256
    if ($declaredHash -cnotmatch '^[a-f0-9]{64}$') {
      throw "heavy-verifier: diagnostic declaration has an invalid SHA-256"
    }
    if ($DiagnosticSha256 -cne $declaredHash) {
      throw "heavy-verifier: diagnostic SHA-256 does not match host declaration"
    }
  } else {
    if ($callerPath -or $DiagnosticSha256) {
      throw "heavy-verifier: vitest-command diagnostics do not accept a standalone script hash"
    }
    if ($declaredPath -cne 'scripts/canonical-record.test.mjs') {
      throw 'heavy-verifier: vitest-command entry path is not the canonical-record test'
    }
    $trackedEntry = @(& git -C $worktreeFull ls-tree -r --name-only $acquiredGitIdentity.Head -- $declaredPath 2>$null)
    if ($LASTEXITCODE -ne 0 -or $trackedEntry.Count -ne 1 -or $trackedEntry[0] -cne $declaredPath) {
      throw 'heavy-verifier: vitest-command entry is not tracked at the admitted exact head'
    }
    $expectedArguments = @('exec', 'vitest', 'run', '--config', './vitest.scripts.config.mjs', 'scripts/canonical-record.test.mjs', '--maxWorkers=1', '--fileParallelism=false', '--silent=false')
    if ($definition.PSObject.Properties.Name -notcontains 'command' -or
        $definition.command.executable -cne 'pnpm' -or
        ((@($definition.command.arguments) -join "`n") -cne ($expectedArguments -join "`n"))) {
      throw 'heavy-verifier: vitest-command declaration does not pin the canonical command'
    }
    $script:diagnosticVitestCommand = $true
    $script:diagnosticCommandArguments = $expectedArguments
  }
  $maximumBudget = 0.0
  if (-not [double]::TryParse([string]$definition.maxBudgetSeconds, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$maximumBudget) -or
      [double]::IsNaN($maximumBudget) -or [double]::IsInfinity($maximumBudget) -or $maximumBudget -le 0 -or $maximumBudget -gt 86400) {
    throw "heavy-verifier: diagnostic declaration has an invalid maximum budget"
  }
  if ($DiagnosticBudgetSeconds -gt $maximumBudget) {
    throw "heavy-verifier: diagnostic budget exceeds declared maximum"
  }
  $relative = $declaredPath.Replace('/', '\')
  $candidate = [IO.Path]::GetFullPath((Join-Path $worktreeFull $relative)).TrimEnd('\', '/')
  if (-not $candidate.StartsWith($worktreeFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "heavy-verifier: diagnostic script escaped the supplied worktree"
  }
  Assert-DiagnosticPathNoReparse $candidate 'diagnostic script path'
  if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
    throw "heavy-verifier: declared diagnostic script was not found"
  }
  $actual = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($candidate))).ToLowerInvariant()
  if ($diagnosticKind -ceq 'standalone-node' -and $actual -cne $declaredHash.ToLowerInvariant()) {
    throw "heavy-verifier: declared diagnostic SHA-256 does not match the script"
  }
  $script:diagnosticDefinition = [ordered]@{
    name = $Diagnostic; kind = $diagnosticKind; scriptPath = $declaredPath
    sha256 = if ($declaredHash) { $declaredHash.ToLowerInvariant() } else { $null }
    budgetSeconds = $DiagnosticBudgetSeconds; maxBudgetSeconds = $maximumBudget
  }
  if ($diagnosticVitestCommand) {
    $script:diagnosticDefinition.command = [ordered]@{ executable = 'pnpm'; arguments = @($diagnosticCommandArguments) }
  }
  $script:diagnosticScriptFull = $candidate
  if ($definition.PSObject.Properties.Name -ccontains 'dependencies') {
    if ($definition.dependencies -isnot [array] -or $definition.dependencies.Count -gt 64) {
      throw 'heavy-verifier: diagnostic dependencies must be an array of at most 64 entries'
    }
    $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [void]$paths.Add($candidate)
    $resolved = @()
    $declared = @()
    foreach ($dependency in $definition.dependencies) {
      $dependencyPath = [string]$dependency.path
      $dependencyHash = [string]$dependency.sha256
      $normalized = $dependencyPath.Replace('\', '/')
      if ([string]::IsNullOrWhiteSpace($dependencyPath) -or [IO.Path]::IsPathFullyQualified($dependencyPath) -or
          $normalized -cnotmatch '^[A-Za-z0-9._/-]+\.(mjs|js|json)$' -or
          @($normalized.Split('/') | Where-Object { $_ -in @('', '.', '..') }).Count -gt 0) {
        throw 'heavy-verifier: diagnostic dependency must be a repository-relative .mjs, .js or .json path'
      }
      if ($dependencyHash -cnotmatch '^[a-fA-F0-9]{64}$') {
        throw 'heavy-verifier: diagnostic dependency has an invalid SHA-256'
      }
      $full = [IO.Path]::GetFullPath((Join-Path $worktreeFull $normalized)).TrimEnd('\', '/')
      if (-not $full.StartsWith($worktreeFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'heavy-verifier: diagnostic dependency escaped the supplied worktree'
      }
      if (-not $paths.Add($full)) {
        throw 'heavy-verifier: diagnostic dependency duplicates another dependency or the entry'
      }
      Assert-DiagnosticPathNoReparse $full 'diagnostic dependency path'
      if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw 'heavy-verifier: declared diagnostic dependency was not found'
      }
      $actual = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($full))).ToLowerInvariant()
      if ($actual -cne $dependencyHash.ToLowerInvariant()) {
        throw "heavy-verifier: declared diagnostic dependency SHA-256 does not match: $normalized"
      }
      $resolved += [ordered]@{ path = $full; sha256 = $dependencyHash.ToLowerInvariant() }
      $declared += [ordered]@{ path = $normalized; sha256 = $dependencyHash.ToLowerInvariant() }
    }
    $script:diagnosticDependencies = $resolved
    $script:diagnosticDefinition.dependencies = $declared
  }
}
Assert-DiagnosticDeclaration

$workspaceDbFile = $null
$workspaceDbTestFileSupplied = $PSBoundParameters.ContainsKey('WorkspaceDbTestFile')
$workspaceDbBudgetMaximumSeconds = 900.0
function Assert-WorkspaceDbRoute {
  if (-not $isWorkspaceDbTest) { return }
  if ([double]::IsNaN($WorkspaceDbBudgetSeconds) -or [double]::IsInfinity($WorkspaceDbBudgetSeconds) -or
      $WorkspaceDbBudgetSeconds -le 0 -or $WorkspaceDbBudgetSeconds -gt $workspaceDbBudgetMaximumSeconds) {
    throw "heavy-verifier: workspace DB budget must be finite, greater than zero, and no more than $workspaceDbBudgetMaximumSeconds seconds"
  }
  if ($workspaceDbTestFileSupplied -and [string]::IsNullOrWhiteSpace($WorkspaceDbTestFile)) {
    throw 'heavy-verifier: workspace DB test file must not be empty'
  }
  if ($workspaceDbTestFileSupplied) {
    $normalized = $WorkspaceDbTestFile.Replace('\', '/')
    if ([IO.Path]::IsPathFullyQualified($WorkspaceDbTestFile) -or
        $normalized.StartsWith('/') -or $normalized -cmatch '^[A-Za-z]:/' -or
        $normalized -cnotmatch '^bounded-contexts/payments/.+\.db\.test\.ts$' -or
        @($normalized.Split('/') | Where-Object { $_ -in @('', '.', '..') }).Count -gt 0) {
      throw 'heavy-verifier: workspace DB test file must be a normalized repository-relative payments .db.test.ts path'
    }
    $relative = $normalized.Replace('/', '\')
    $candidate = [IO.Path]::GetFullPath((Join-Path $worktreeFull $relative)).TrimEnd('\', '/')
    if (-not $candidate.StartsWith($worktreeFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
      throw 'heavy-verifier: workspace DB test file escaped the supplied worktree'
    }
    Assert-DiagnosticPathNoReparse $candidate 'workspace DB test file'
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
      throw 'heavy-verifier: workspace DB test file was not found'
    }
    $tracked = @(& git -C $worktreeFull ls-files --error-unmatch -- $normalized 2>$null)
    if ($LASTEXITCODE -ne 0 -or $tracked.Count -ne 1 -or $tracked[0] -cne $normalized) {
      throw 'heavy-verifier: workspace DB test file is not tracked at the supplied worktree HEAD'
    }
    $treeType = ((& git -C $worktreeFull cat-file -t "HEAD:$normalized" 2>$null) -join '').Trim()
    if ($LASTEXITCODE -ne 0 -or $treeType -cne 'blob') {
      throw 'heavy-verifier: workspace DB test file is not a tracked file at the supplied worktree HEAD'
    }
    $workspaceRelativeFilter = $normalized.Substring('bounded-contexts/payments/'.Length)
    $trackedPayments = @(& git -C $worktreeFull ls-files -- 'bounded-contexts/payments/**' 2>$null)
    $matches = @($trackedPayments | Where-Object {
        $_.Substring('bounded-contexts/payments/'.Length).IndexOf($workspaceRelativeFilter, [StringComparison]::OrdinalIgnoreCase) -ge 0
      })
    if ($matches.Count -ne 1) {
      throw 'heavy-verifier: workspace DB test file filter must identify exactly one tracked payments path'
    }
    $script:workspaceDbFile = $normalized
  }
}
Assert-WorkspaceDbRoute
if ($IsWindows -and $isTimedRoute) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class HeavyDiagnosticJob {
  [StructLayout(LayoutKind.Sequential)] struct BasicLimit { public long PerProcessUserTimeLimit, PerJobUserTimeLimit; public uint LimitFlags; public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize; public uint ActiveProcessLimit; public UIntPtr Affinity; public uint PriorityClass, SchedulingClass; }
  [StructLayout(LayoutKind.Sequential)] struct IoCounters { public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount, ReadTransferCount, WriteTransferCount, OtherTransferCount; }
  [StructLayout(LayoutKind.Sequential)] struct ExtendedLimit { public BasicLimit BasicLimitInformation; public IoCounters IoInfo; public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed; }
  [StructLayout(LayoutKind.Sequential)] struct BasicAccounting { public long TotalUserTime, TotalKernelTime, ThisPeriodTotalUserTime, ThisPeriodTotalKernelTime; public uint TotalPageFaultCount, TotalProcesses, ActiveProcesses, TotalTerminatedProcesses; }
  const uint KillOnClose = 0x00002000;
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateJobObjectW(IntPtr attributes, string name);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint length);
  [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateJobObject(IntPtr job, uint code);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr job, int infoClass, IntPtr info, int length, IntPtr returnLength);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr handle);
  public static IntPtr Create() {
    var job = CreateJobObjectW(IntPtr.Zero, null);
    if (job == IntPtr.Zero) throw new InvalidOperationException("CreateJobObject failed: " + Marshal.GetLastWin32Error());
    var info = new ExtendedLimit { BasicLimitInformation = new BasicLimit { LimitFlags = KillOnClose } }; var size = Marshal.SizeOf<ExtendedLimit>(); var memory = Marshal.AllocHGlobal(size);
    try { Marshal.StructureToPtr(info, memory, false); if (!SetInformationJobObject(job, 9, memory, (uint)size)) { CloseHandle(job); throw new InvalidOperationException("SetInformationJobObject failed: " + Marshal.GetLastWin32Error()); } } finally { Marshal.FreeHGlobal(memory); }
    return job;
  }
  public static void Assign(IntPtr job, int pid) {
    var opened = OpenProcess(0x0100u | 0x0001u, false, unchecked((uint)pid));
    if (opened == IntPtr.Zero) throw new InvalidOperationException("OpenProcess failed: " + Marshal.GetLastWin32Error());
    try { if (!AssignProcessToJobObject(job, opened)) throw new InvalidOperationException("AssignProcessToJobObject failed: " + Marshal.GetLastWin32Error()); } finally { CloseHandle(opened); }
  }
  public static void Terminate(IntPtr job, uint code) { if (job != IntPtr.Zero) TerminateJobObject(job, code); }
  public static bool HasActiveProcesses(IntPtr job) { BasicAccounting info = QueryAccounting(job); return info.ActiveProcesses > 0; }
  static BasicAccounting QueryAccounting(IntPtr job) { var size = Marshal.SizeOf<BasicAccounting>(); var memory = Marshal.AllocHGlobal(size); try { if (!QueryInformationJobObject(job, 1, memory, size, IntPtr.Zero)) throw new InvalidOperationException("QueryInformationJobObject(accounting) failed: " + Marshal.GetLastWin32Error()); return Marshal.PtrToStructure<BasicAccounting>(memory); } finally { Marshal.FreeHGlobal(memory); } }
  static ExtendedLimit QueryExtended(IntPtr job) { var size = Marshal.SizeOf<ExtendedLimit>(); var memory = Marshal.AllocHGlobal(size); try { if (!QueryInformationJobObject(job, 9, memory, size, IntPtr.Zero)) throw new InvalidOperationException("QueryInformationJobObject(extended-limit) failed: " + Marshal.GetLastWin32Error()); return Marshal.PtrToStructure<ExtendedLimit>(memory); } finally { Marshal.FreeHGlobal(memory); } }
  public static object QueryResources(IntPtr job) { var accounting = QueryAccounting(job); var extended = QueryExtended(job); return new { peakJobMemoryBytes = extended.PeakJobMemoryUsed.ToUInt64(), totalUserTime100ns = accounting.TotalUserTime, totalKernelTime100ns = accounting.TotalKernelTime, totalProcesses = accounting.TotalProcesses }; }
  public static void Close(IntPtr job) { if (job != IntPtr.Zero) CloseHandle(job); }
}
'@
}
function Write-DiagnosticProcessAmbiguity([int]$ProcessId, [string]$Reason) {
  if ($null -eq $script:diagnosticProcessAmbiguities) { $script:diagnosticProcessAmbiguities = @{} }
  $key = "$ProcessId|$Reason"
  if (-not $script:diagnosticProcessAmbiguities.ContainsKey($key)) {
    $script:diagnosticProcessAmbiguities[$key] = $true
    [Console]::Error.WriteLine("heavy-verifier: diagnostic process observation excluded pid=$ProcessId reason=$Reason")
  }
}
function Test-DiagnosticSnapshotStart([long]$SnapshotTicks, [long]$ExactTicks) {
  # CIM truncates process creation times to whole microseconds.
  return $SnapshotTicks -le $ExactTicks -and $ExactTicks - $SnapshotTicks -le 9
}
function Get-DiagnosticDescendantPids([int]$RootPid, [long]$RootStartTicks = 0) {
  $script:diagnosticSnapshotDescendantStarts = @{}
  if (-not $IsWindows -or $RootPid -le 0 -or $RootStartTicks -le 0) { return @() }
  try {
    $snapshot = @{}; $excluded = @{}; $children = @{}
    foreach ($processInfo in @(Get-CimInstance Win32_Process -ErrorAction Stop)) {
      $processId = 0; $parentId = 0
      if ([int]::TryParse([string]$processInfo.ProcessId, [ref]$processId) -and $processId -gt 0 -and [int]::TryParse([string]$processInfo.ParentProcessId, [ref]$parentId) -and $parentId -gt 0) {
        if ([string]$processInfo.Name -iin @('conhost.exe', 'openconsole.exe')) { continue }
        if ($snapshot.ContainsKey($processId) -or $excluded.ContainsKey($processId)) {
          $snapshot.Remove($processId); $excluded[$processId] = $true
          Write-DiagnosticProcessAmbiguity $processId 'duplicate-process-identity'
          continue
        }
        try {
          if ($processInfo.CreationDate -is [DateTime]) { $createdTicks = $processInfo.CreationDate.ToUniversalTime().Ticks }
          elseif ($processInfo.CreationDate -is [string]) { $createdTicks = [Management.ManagementDateTimeConverter]::ToDateTime($processInfo.CreationDate).ToUniversalTime().Ticks }
          else { throw 'creation time was neither DateTime nor DMTF' }
        } catch { Write-DiagnosticProcessAmbiguity $processId 'creation-time-unparseable'; $excluded[$processId] = $true; continue }
        $snapshot[$processId] = [pscustomobject]@{ Pid=$processId; ParentPid=$parentId; StartTicks=$createdTicks }
      }
    }
    if ($excluded.ContainsKey($RootPid)) { return @() }
    if (-not $snapshot.ContainsKey($RootPid)) {
      Write-DiagnosticProcessAmbiguity $RootPid 'root-snapshot-identity-unavailable'
      return @()
    }
    if (-not (Test-DiagnosticSnapshotStart $snapshot[$RootPid].StartTicks $RootStartTicks)) {
      Write-DiagnosticProcessAmbiguity $RootPid 'root-start-identity-mismatch'
      return @()
    }
    $liveRoot = $null
    try {
      $liveRoot = Get-Process -Id $RootPid -ErrorAction Stop
      [void]$liveRoot.Handle
      if ($liveRoot.StartTime.ToUniversalTime().Ticks -ne $RootStartTicks) {
        Write-DiagnosticProcessAmbiguity $RootPid 'root-start-identity-mismatch'
        return @()
      }
    } catch {
      if ($_.FullyQualifiedErrorId -notlike 'NoProcessFoundForGivenId*') {
        Write-DiagnosticProcessAmbiguity $RootPid 'root-start-identity-unavailable'
        return @()
      }
    } finally { if ($liveRoot -is [IDisposable]) { $liveRoot.Dispose() } }
    foreach ($candidate in $snapshot.Values) {
      if (-not $children.ContainsKey($candidate.ParentPid)) { $children[$candidate.ParentPid] = @() }
      $children[$candidate.ParentPid] += $candidate
    }
    $pending = [Collections.Generic.Queue[object]]::new()
    $pending.Enqueue([pscustomobject]@{ Pid=$RootPid; StartTicks=$RootStartTicks })
    $seen = @{}; $seen[$RootPid] = $true
    $result = @()
    while ($pending.Count -gt 0) {
      $parent = $pending.Dequeue()
      if ($children.ContainsKey($parent.Pid)) { foreach ($candidate in $children[$parent.Pid]) {
        if ($seen.ContainsKey($candidate.Pid)) { continue }
        if ($candidate.StartTicks -lt $parent.StartTicks) {
          Write-DiagnosticProcessAmbiguity $candidate.Pid 'parent-creation-order'
          continue
        }
        $seen[$candidate.Pid] = $true
        $script:diagnosticSnapshotDescendantStarts[$candidate.Pid] = $candidate.StartTicks
        $result += $candidate.Pid
        $pending.Enqueue($candidate)
      } }
    }
    return @($result)
  } catch { Write-DiagnosticProcessAmbiguity $RootPid 'process-snapshot-unavailable'; return @() }
}
function Stop-ExactVerifierProcess([int]$ProcessId, [long]$StartTicks) {
  $candidate = $null
  try {
    $candidate = Get-Process -Id $ProcessId -ErrorAction Stop
    [void]$candidate.Handle
    if ($StartTicks -le 0 -or $candidate.StartTime.ToUniversalTime().Ticks -ne $StartTicks) {
      [Console]::Error.WriteLine("heavy-verifier: diagnostic process kill skipped pid=$ProcessId reason=start-identity-mismatch")
      return
    }
    # The pinned handle binds this non-tree kill; never enumerate a PID-only tree.
    if (-not $candidate.HasExited) { $candidate.Kill() }
  } catch {
    if ($_.FullyQualifiedErrorId -notlike 'NoProcessFoundForGivenId*') {
      [Console]::Error.WriteLine("heavy-verifier: diagnostic process kill skipped pid=$ProcessId reason=identity-or-termination-unavailable")
    }
  } finally { if ($candidate) { $candidate.Dispose() } }
}
function Stop-DiagnosticTree([int]$RootPid, [long]$RootStartTicks = 0, [int[]]$KnownPids = @()) {
  # Kernel job membership is handle-bound, not inferred from reusable PIDs.
  if ($IsWindows -and $diagnosticJobHandle -ne [IntPtr]::Zero) { [HeavyDiagnosticJob]::Terminate($diagnosticJobHandle, 1) }
  Stop-ExactVerifierProcess $RootPid $RootStartTicks
  foreach ($descendantPid in @($KnownPids | Select-Object -Unique)) {
    $expectedStart = if ($script:diagnosticObservedDescendantStarts.ContainsKey($descendantPid)) { $script:diagnosticObservedDescendantStarts[$descendantPid] } else { 0 }
    Stop-ExactVerifierProcess $descendantPid $expectedStart
  }
}
# The diagnostic source handles may be released only once the whole child tree
# is proven dead: the root has exited, the kill-on-close job has no active
# process, and no observed descendant identity is still live.
function Test-DiagnosticTreeExited {
  if ($null -eq $child) { return $true }
  try { if (-not $child.HasExited) { return $false } } catch { return $false }
  if ($IsWindows) {
    if ($diagnosticJobHandle -ne [IntPtr]::Zero) {
      try { if ([HeavyDiagnosticJob]::HasActiveProcesses($diagnosticJobHandle)) { return $false } } catch { return $false }
    }
    return -not (Test-ObservedDiagnosticDescendants @($diagnosticObservedDescendants))
  }
  return (Test-PossibleOwnedChild $owner -GuardedRootOnly) -eq $false
}
function Stop-DiagnosticTreeUntilExited([int]$TimeoutMilliseconds = 10000) {
  $watch = [Diagnostics.Stopwatch]::StartNew()
  while (-not (Test-DiagnosticTreeExited)) {
    if ($watch.ElapsedMilliseconds -ge $TimeoutMilliseconds) { return $false }
    # Re-request identity-checked termination until exit is established.
    try { Stop-DiagnosticTree $child.Id $childStartTicks @($diagnosticObservedDescendants) } catch {}
    try { [void]$child.WaitForExit(250) } catch { Start-Sleep -Milliseconds 250 }
  }
  return $true
}
function Test-ObservedDiagnosticDescendants([int[]]$Pids) {
  foreach ($descendantProcessId in @($Pids | Select-Object -Unique)) {
    if ($descendantProcessId -le 0 -or -not $script:diagnosticObservedDescendantStarts.ContainsKey($descendantProcessId)) { continue }
    $candidate = $null
    try {
      $candidate = Get-Process -Id $descendantProcessId -ErrorAction Stop
      [void]$candidate.Handle
      if ($candidate.StartTime.ToUniversalTime().Ticks -eq $script:diagnosticObservedDescendantStarts[$descendantProcessId]) {
        if (-not $candidate.HasExited) { return $true }
      } else { Write-DiagnosticProcessAmbiguity $descendantProcessId 'observed-start-identity-mismatch' }
    } catch {} finally { if ($candidate) { $candidate.Dispose() } }
  }
  return $false
}
# Read every native launch before interpreting roles or command shape. A failed
# lookup is never evidence that the caller is a standalone host.
function Get-HeavyCallerAncestry([int]$RootPid, [string]$RootStart, [long]$OldestLaunch, [int[]]$CandidatePids, [object[]]$DispatchRecords = @()) {
  $dispatchRootKey = @($DispatchRecords | ForEach-Object {
    "$($_.state)|$($_.launcherPid)|$($_.launcherStartIdentity)|$($_.childPid)|$($_.childStartIdentity)"
  } | Sort-Object) -join ';'
  $key = "$RootPid|$RootStart|$OldestLaunch|$(@($CandidatePids | Sort-Object -Unique) -join ',')|$dispatchRootKey"
  $cached = $script:heavyCallerAncestry
  if ($cached -and $cached.Key -ceq $key) {
    $unchanged = $true
    foreach ($id in $cached.Starts.Keys) {
      try { $ticks = (Get-Process -Id $id -ErrorAction Stop).StartTime.ToUniversalTime().Ticks }
      catch { $unchanged = $false; break }
      Assert-DispatchObservationTime
      if ($ticks -ne $cached.Starts[$id]) { $unchanged = $false; break }
    }
    # Windows parent edges are immutable within exact live process identities.
    # Cache only those edges, never census, ownership, routing or Git authority.
    if ($unchanged) { return $cached.Chain }
  }
  $script:heavyCallerAncestry = $null
  $chain = @{}
  $snapshot = @{}
  $cimBounds = @{}
  if ($Evaluation) {
    $remaining = [Math]::Min($Evaluation.deadline - $Evaluation.watch.ElapsedMilliseconds, $RemainingMs)
    if ($remaining -lt 1000) { throw 'dispatch census evaluation exhausted' }
    $cimBounds.OperationTimeoutSec = [uint32][Math]::Floor($remaining / 1000)
  }
  foreach ($row in @(Get-CimInstance Win32_Process -Property ProcessId,ParentProcessId,CreationDate @cimBounds -ErrorAction Stop)) {
    Assert-DispatchObservationTime
    $id = [int]$row.ProcessId
    if ($snapshot.ContainsKey($id)) { throw 'ambiguous process snapshot' }
    $snapshot[$id] = $row
  }
  foreach ($id in $CandidatePids) {
    if ($snapshot.ContainsKey($id) -and $snapshot[$id].CreationDate) {
      # A reused PID's current start may precede a forged/stale claim. It must
      # not disappear behind a cutoff derived solely from the claimed time.
      $OldestLaunch = [Math]::Min($OldestLaunch, $snapshot[$id].CreationDate.ToUniversalTime().Ticks)
    }
  }
  $expected = [DateTimeOffset]::Parse($RootStart).UtcTicks
  $childTicks = [long]::MaxValue
  while ($RootPid -gt 0) {
    if ($chain.ContainsKey($RootPid) -or $chain.Count -ge 128) { throw 'ambiguous process ancestry' }
    $row = $snapshot[$RootPid]
    if ($null -eq $row -or $null -eq $row.CreationDate) { throw 'process ancestry lookup failed' }
    $snapshotTicks = $row.CreationDate.ToUniversalTime().Ticks
    # WMI truncates to microseconds. An ancestor provably older than every
    # published launch cannot be a containing launch; do not demand access to
    # a privileged service ancestor beyond that evidence boundary.
    if ($chain.Count -gt 0 -and $snapshotTicks + 9 -lt $OldestLaunch) {
      if ($snapshotTicks -gt $childTicks) { throw 'process ancestry PID reused' }
      break
    }
    $process = Get-Process -Id $RootPid -ErrorAction Stop
    $ticks = $process.StartTime.ToUniversalTime().Ticks
    Assert-DispatchObservationTime
    if (($ticks - ($ticks % 10)) -ne $row.CreationDate.ToUniversalTime().Ticks -or $ticks -gt $childTicks -or
        ($chain.Count -eq 0 -and $ticks -ne $expected)) { throw 'process ancestry PID reused' }
    $chain[$RootPid] = $ticks
    $boundDispatchRoot = $false
    foreach ($record in $DispatchRecords) {
      if ($record.state -cne 'started' -or [int]$record.launcherPid -ne $RootPid -or
          -not $chain.ContainsKey([int]$record.childPid)) { continue }
      if ($ticks -ne [DateTimeOffset]::Parse($record.launcherStartIdentity).UtcTicks -or
          $chain[[int]$record.childPid] -ne [DateTimeOffset]::Parse($record.childStartIdentity).UtcTicks) {
        throw 'dispatch root PID reused'
      }
      $boundDispatchRoot = $true
    }
    # A validated published launch binds both the native child in this chain
    # and its dispatch-lane root. The short-lived wrapper above that root is
    # not launch authority; census, Git, routing and byte checks still follow.
    if ($boundDispatchRoot) { break }
    if ($ticks -lt $OldestLaunch) { break }
    $childTicks = $ticks
    $RootPid = [int]$row.ParentProcessId
  }
  $starts = @{}
  foreach ($id in @($CandidatePids) + @($chain.Keys)) {
    if (-not $snapshot.ContainsKey($id) -or -not $snapshot[$id].CreationDate) { $starts = $null; break }
    try { $ticks = (Get-Process -Id $id -ErrorAction Stop).StartTime.ToUniversalTime().Ticks }
    catch { $starts = $null; break }
    Assert-DispatchObservationTime
    if ($ticks - ($ticks % 10) -ne $snapshot[$id].CreationDate.ToUniversalTime().Ticks) { $starts = $null; break }
    $starts[$id] = $ticks
  }
  if ($starts) { $script:heavyCallerAncestry = @{ Key = $key; Starts = $starts; Chain = $chain } }
  return $chain
}
function Get-HeavyRoutingRow($Record, [string]$RuntimeRoot) {
  $path = Join-Path $RuntimeRoot 'dispatch-log.jsonl'
  $file = Get-Item -LiteralPath $path -Force -ErrorAction Stop
  Assert-DispatchObservationTime
  if ($file.PSIsContainer -or $file.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) { throw 'routing history missing or unsafe' }
  if (-not ('ChaseSets.HeavyAdmission.RoutingHistory' -as [type])) {
    # Stream the complete history in managed code, not one PowerShell pipeline
    # per ledger property. Authority still comes from the shared closed validator.
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
namespace ChaseSets.HeavyAdmission {
  public static class RoutingHistory {
    public static IEnumerable<string> RelevantRows(string path, string label, string transcript, Action checkExpiry) {
      using (var reader = new StreamReader(path)) {
      checkExpiry();
      while (true) {
        string line = reader.ReadLine();
        checkExpiry();
        if (line == null) break;
        if (String.IsNullOrWhiteSpace(line)) continue;
        using (JsonDocument document = JsonDocument.Parse(line)) {
          JsonElement schema;
          if (!document.RootElement.TryGetProperty("dispatchRoutingSchema", out schema)) continue;
          bool relevant = false;
          foreach (JsonProperty property in document.RootElement.EnumerateObject()) {
            if ((property.Name == "label" && property.Value.GetString() == label) ||
                (property.Name == "transcript" && property.Value.GetString() == transcript)) relevant = true;
          }
          if (relevant) yield return line;
        }
      }
      }
    }
  }
}
'@
  }
  Assert-DispatchObservationTime
  $candidates = @()
  foreach ($line in [ChaseSets.HeavyAdmission.RoutingHistory]::RelevantRows($path, $Record.label, (Split-Path -Leaf $Record.transcriptPath), [Action]{ Assert-DispatchObservationTime })) {
    $row = ConvertFrom-DispatchClosedJson $line
    if ($null -eq $row) { throw 'routing history malformed' }
    $keys = @(Get-DispatchRoutingLedgerKeys $row.dispatchRoutingSchema $row)
    $actual = @($row.PSObject.Properties.Name)
    if (-not (Test-DispatchRoutingLedgerEvidence $row) -or $keys.Count -ne $actual.Count -or
        @($keys | Where-Object { $_ -cnotin $actual }).Count -gt 0) { throw 'routing row invalid' }
    $instant = [DateTimeOffset]::Parse([string]$row.ts).UtcTicks
    # Historical reuse of a label is not this launch's authority.
    if ($instant -lt [DateTimeOffset]::Parse($Record.launcherStartIdentity).UtcTicks -or
        $instant -gt [DateTimeOffset]::Parse($Record.childStartIdentity).UtcTicks) { continue }
    $number = 0
    if ($row.kind -cne 'dispatch' -or $row.laneRole -cne 'implementation' -or
        $row.label -cne $Record.label -or $row.lane -cne $Record.lane -or
        $row.transcript -cne (Split-Path -Leaf $Record.transcriptPath) -or
        -not (Test-DispatchSamePath $row.worktree $Record.worktree) -or
        [string]$row.branch -cne [string]$Record.branch -or $row.head -cne $Record.head -or
        [string]::IsNullOrWhiteSpace($row.attemptId) -or $row.harness -cnotin @('codex','claude') -or
        [string]::IsNullOrWhiteSpace($row.model) -or [string]::IsNullOrWhiteSpace($row.effort) -or
        $row.placement -cnotmatch '^(measured|provisional|override-[A-Za-z0-9._-]+)$' -or
        -not [int]::TryParse([string]$row.row, [ref]$number) -or $number -lt 1 -or $number -gt 15) {
      throw 'routing row differs from original dispatch identity'
    }
    foreach ($name in @('policyGeneration','registryAuthorityDigest','family','slot','usedLastKnownGood')) {
      if ($Record.PSObject.Properties[$name] -and
          (-not $row.PSObject.Properties[$name] -or $Record.$name -cne $row.$name)) { throw 'routing provenance mismatch' }
    }
    $candidates += [pscustomobject]@{ Row = $number; Raw = $line }
  }
  if ($candidates.Count -ne 1) { throw 'routing row missing or ambiguous for current launch' }
  return $candidates[0]
}
function Write-AdmissionPending([int]$BudgetMs) {
  if (-not $isAttachedAdmission -or -not $admissionResultFull) { return }
  # Progress selects waiting time only. Acceptance still requires the final
  # nonce-bound result after every unchanged eligibility/identity check.
  $script:admissionPendingSequence++
  $pending = [ordered]@{
    schemaVersion = 1
    nonce = $AdmissionNonce
    sequence = $script:admissionPendingSequence
    budgetMs = $BudgetMs
  }
  $temporaryPath = "$admissionResultFull.$([guid]::NewGuid().ToString('N')).tmp"
  try {
    [IO.File]::WriteAllText($temporaryPath, ($pending | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
    for ($attempt = 1; $attempt -le 10; $attempt++) {
      try {
        [IO.File]::Move($temporaryPath, "$admissionResultFull.pending", $true)
        break
      } catch [IO.IOException], [UnauthorizedAccessException] {
        # The waiter can hold the target open during replacement. Progress
        # is time-only: skip an exhausted heartbeat, never refuse eligibility.
        if ($attempt -lt 10) { Start-Sleep -Milliseconds 10 }
      }
    }
  } finally {
    if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
      Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
  }
}
function Assert-DispatchObservationTime {
  $budgets = (Get-Variable dispatchCheckedBudgets -ErrorAction SilentlyContinue).Value
  foreach ($budget in $budgets) {
    if ($budget.watch.ElapsedMilliseconds -ge $budget.deadline) {
      throw 'dispatch census evaluation deadline'
    }
  }
}

function Test-DispatchCensusReobservation($Ownership) {
  $retry = $false
  foreach ($diagnostic in $Ownership.health.diagnostics) {
    if ((Get-LaneDiagnosticSeverity $diagnostic.code) -cne 'blocking') { continue }
    if ($diagnostic.code -cin @('ownership-record-invalid','ownership-deadline-truncated',
        'terminal-transcript-live-process','product-census-git-deadline') -or
        ($diagnostic.code -ceq 'worktree-outside-container' -and $diagnostic.reason -ceq 'git-deadline')) {
      $retry = $true
    } else { return $false }
  }
  return $retry
}

function Get-DispatchBlockingDiagnostics($Ownership) {
  return (@($Ownership.health.diagnostics | Where-Object {
    (Get-LaneDiagnosticSeverity ([string]$_.code)) -ceq 'blocking'
  } | ForEach-Object { "$($_.code):$($_.lane)" }) -join ',')
}

function Get-DispatchCensusPaths([string]$RuntimeRoot, [int]$Limit = [int]::MaxValue) {
  $iterator = [IO.Directory]::EnumerateFiles($RuntimeRoot, 'dispatch-launch-*.json').GetEnumerator()
  try {
    Assert-DispatchObservationTime
    for ($index = 0; $index -lt $Limit; $index++) {
      $more = $iterator.MoveNext()
      Assert-DispatchObservationTime
      if (-not $more) { break }
      $iterator.Current
    }
  } finally { $iterator.Dispose() }
}

function Get-HeavyCallerBinding {
  $evaluation = @{watch=[Diagnostics.Stopwatch]::StartNew();deadline=90000;productPasses=0}
  $admission = $script:heavyAdmissionBudget
  if (-not $admission) { $admission = @{watch=[Diagnostics.Stopwatch]::StartNew();deadline=210000;observations=0;fences=1} }
  $evaluation.deadline = [Math]::Min($evaluation.deadline, $admission.deadline - $admission.watch.ElapsedMilliseconds)
  $dispatchCheckedBudgets = @($evaluation, $admission)
  $anchor = $null
  for ($attempt = 0; $attempt -lt 3; $attempt++) {
    $remaining = [Math]::Min($evaluation.deadline - $evaluation.watch.ElapsedMilliseconds,
      $admission.deadline - $admission.watch.ElapsedMilliseconds)
    $reserved = [Math]::Max(0, 3 - $admission.fences)
    if ($remaining -le 0 -or $admission.observations -ge 6 - $reserved) {
      return [pscustomobject]@{Reason='dispatch census evaluation exhausted'}
    }
    $admission.observations++
    $binding = Get-HeavyCallerObservation $evaluation $remaining
    if ($anchor -and ($binding.Record -or -not $binding.Reason) -and ($anchor.Path -cne $binding.Path -or $anchor.Raw -cne $binding.Raw -or
        $anchor.RoutingRaw -cne $binding.RoutingRaw)) {
      $binding.Reason = 'dispatch census changed authority'; return $binding
    }
    if ($binding.Record) { $anchor = $binding }
    if ($evaluation.watch.ElapsedMilliseconds -ge $evaluation.deadline -or
        $admission.watch.ElapsedMilliseconds -ge $admission.deadline) { $binding.Reason='dispatch census evaluation exhausted' }
    if (-not $binding.Reason -or ($binding.Reason -cne 'dispatch census changed' -and -not $binding.Retryable)) { return $binding }
  }
  return $binding
}


function Get-HeavyCallerObservation($Evaluation, [long]$RemainingMs) {
  $result = [ordered]@{ Record = $null; Raw = $null; Path = $null; Row = $null; RoutingRaw = $null; Reason = $null; Retryable = $false }
  try {
    $runtime = Join-Path $container '.orchestrator'
    $rootPid = if ($isAttachedAdmission) { $GuardedPid } else { $PID }
    $rootStart = if ($isAttachedAdmission) { $GuardedProcessStartUtc } else { (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o') }
    Assert-DispatchObservationTime
    $observedGitIdentities = @{}
    $beforePaths = @(Get-DispatchCensusPaths $runtime | Sort-Object)
    $beforeBytes = @{}
    foreach ($path in $beforePaths) {
      if (-not [IO.File]::Exists($path)) { throw 'dispatch census changed' }
      $beforeBytes[$path] = [IO.File]::ReadAllText($path)
      Assert-DispatchObservationTime
      $candidate = Get-ValidatedDispatchOwnershipRecord $path $runtime ([IO.Path]::GetTempPath())
      Assert-DispatchObservationTime
      if ($candidate -and (Test-DispatchSamePath $candidate.worktree $acquiredGitIdentity.Worktree)) {
        if ($Evaluation.ContainsKey('selectedPath') -and $Evaluation.selectedPath -cne $path -and
            $beforePaths -ccontains $Evaluation.selectedPath) { throw 'dispatch census unknown or incomplete' }
        if ($Evaluation.ContainsKey('selectedPath') -and
            ($Evaluation.selectedPath -cne $path -or $Evaluation.selectedRaw -cne $beforeBytes[$path])) { throw 'selected dispatch bytes changed' }
        $Evaluation.selectedPath = $path; $Evaluation.selectedRaw = $beforeBytes[$path]
      }
    }
    if ($Evaluation.ContainsKey('selectedPath') -and -not $beforeBytes.ContainsKey($Evaluation.selectedPath)) { throw 'selected dispatch bytes changed' }
    Assert-DispatchObservationTime
    # Record count bounds the census. Only the shared checked clocks bound time;
    # a nested per-record estimate must not truncate otherwise-valid authority.
    $censusDeadlineMs = [int][Math]::Min($RemainingMs, $Evaluation.deadline-$Evaluation.watch.ElapsedMilliseconds)
    if ($censusDeadlineMs -le 0) { throw 'dispatch census evaluation exhausted' }
    Write-AdmissionPending $censusDeadlineMs
    $live = Get-LiveDispatchOwnership -RuntimeRoot $runtime -TempRoot ([IO.Path]::GetTempPath()) -ContainerRoot $container -DeadlineMs $censusDeadlineMs -GitIdentityResolver {
      param($Worktree)
      $identity = Get-DispatchGitIdentity $Worktree
      $observedGitIdentities[$Worktree] = $identity
      return $identity
    }
    Assert-DispatchObservationTime
    if ($Evaluation.ContainsKey('selectedPath') -and (-not [IO.File]::Exists($Evaluation.selectedPath) -or
        [IO.File]::ReadAllText($Evaluation.selectedPath) -cne $Evaluation.selectedRaw)) { throw 'selected dispatch bytes changed' }
    Assert-DispatchObservationTime
    if ($live.health.counts.truncated -gt 0 -or $live.health.counts.rejected -gt 0 -or
        $live.health.counts.probeFailures -gt 0 -or $live.health.counts.legacyLiveOwners -gt 0) {
      $result.Retryable = Test-DispatchCensusReobservation $live
      throw 'dispatch census unknown or incomplete'
    }
    $paths = @(Get-DispatchCensusPaths $runtime | Sort-Object)
    if ($paths.Count -ne $live.health.counts.examined) { throw 'dispatch census changed' }
    if (($beforePaths -join "`n") -cne ($paths -join "`n")) { throw 'dispatch census changed' }
    $snapshots = @{}
    $records = @{}
    $oldestLaunch = [long]::MaxValue
    foreach ($path in $paths) {
      $snapshots[$path] = [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes($path))
      Assert-DispatchObservationTime
      $record = Get-ValidatedDispatchOwnershipRecord $path $runtime ([IO.Path]::GetTempPath())
      Assert-DispatchObservationTime
      if ($null -eq $record) { throw 'dispatch record malformed or missing role' }
      if ($beforeBytes[$path] -cne $snapshots[$path]) {
        if (Test-DispatchSamePath $record.worktree $acquiredGitIdentity.Worktree) { throw 'selected dispatch bytes changed' }
        throw 'dispatch census changed'
      }
      $records[$path] = $record
      $startIdentity = if ($record.childPid) { $record.childStartIdentity } else { $record.launcherStartIdentity }
      $oldestLaunch = [Math]::Min($oldestLaunch, [DateTimeOffset]::Parse($startIdentity).UtcTicks)
    }
    $candidatePids = @($records.Values | ForEach-Object { [int]$_.launcherPid; if ($_.childPid) { [int]$_.childPid } })
    $before = Get-HeavyCallerAncestry $rootPid $rootStart $oldestLaunch $candidatePids @($records.Values)
    Assert-DispatchObservationTime
    $matches = @()
    $pendingLaunches = @()
    foreach ($path in $paths) {
      $raw = $snapshots[$path]
      $record = $records[$path]
      $contained = $false
      $pair = if ($record.childPid) { @('childPid','childStartIdentity') } else { @('launcherPid','launcherStartIdentity') }
      $id = [int]$record.($pair[0])
      if ($before.ContainsKey($id)) {
        if ($before[$id] -ne [DateTimeOffset]::Parse($record.($pair[1])).UtcTicks) { throw 'dispatch ancestor PID reused' }
        $contained = $true
      }
      if ($contained) {
        if (-not $record.childPid) { $pendingLaunches += $record; continue }
        $current = @($live.activeLanes | Where-Object launchId -CEQ $record.launchId)
        if ($record.state -cne 'started' -or $current.Count -ne 1 -or
            @($live.health.diagnostics | Where-Object { $_.lane -ceq $record.lane }).Count -gt 0) { throw 'containing dispatch is stale, terminal or unknown' }
        # The census may expose a logical branch during native rebase. Bind the
        # actual Git mode as well, without confusing it with that occupancy key.
        $git = $observedGitIdentities[$current[0].worktree]
        if ($git.status -cne 'ok' -or -not (Test-DispatchSamePath $record.worktree $acquiredGitIdentity.Worktree) -or
            $current[0].head -cne $acquiredGitIdentity.Head -or
            $git.head -cne $acquiredGitIdentity.Head -or
            [string]$git.branch -cne [string]$acquiredGitIdentity.Branch) { throw 'dispatch identity differs from admitted identity' }
        $matches += [pscustomobject]@{ Record = $record; Path = $path; Raw = $raw }
      }
    }
    if ($matches.Count -gt 1) { throw 'ambiguous containing dispatches' }
    # A shared launcher is not a second native child. Only an exact started
    # child can disambiguate a healthy pending launch in another worktree.
    foreach ($pending in $pendingLaunches) {
      if ($matches.Count -ne 1 -or (Test-DispatchSamePath $pending.worktree $matches[0].Record.worktree)) {
        throw 'containing dispatch is launching or ambiguous'
      }
    }
    if ($matches.Count -eq 1) {
      $result.Record = $matches[0].Record; $result.Path = $matches[0].Path; $result.Raw = $matches[0].Raw
      if ($result.Record.laneRole -ceq 'implementation') {
        $routing = Get-HeavyRoutingRow $result.Record $runtime
        Assert-DispatchObservationTime
        $result.Row = $routing.Row; $result.RoutingRaw = $routing.Raw
      }
    }
    # Windows parentage cannot change within one exact process identity. Probe
    # every captured ancestor again without repeating the full CIM enumeration.
    foreach ($id in $before.Keys) {
      $process = Get-Process -Id $id -ErrorAction Stop
      Assert-DispatchObservationTime
      if ($process.StartTime.ToUniversalTime().Ticks -ne $before[$id]) { throw 'ancestry changed' }
    }
    $afterPaths = @(Get-DispatchCensusPaths $runtime | Sort-Object)
    $foreignChanged = ($paths -join "`n") -cne ($afterPaths -join "`n")
    foreach ($path in $paths) {
      if (-not [IO.File]::Exists($path) -or -not [string]::Equals([Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes($path)), $snapshots[$path], [StringComparison]::Ordinal)) {
        if ($path -ceq $result.Path) { throw 'selected dispatch bytes changed' }
        $foreignChanged = $true
      }
      Assert-DispatchObservationTime
    }
    if ($foreignChanged) {
      throw 'dispatch census changed'
    }
    # Preserve the selected-owner refusal above, but never accept a complete
    # census with a blocking diagnostic merely because its counters are zero.
    if ((Get-DispatchBlockingDiagnostics $live)) {
      $result.Retryable = Test-DispatchCensusReobservation $live
      throw 'dispatch census unknown or incomplete'
    }
  } catch { $result.Reason = $_.Exception.Message }
  return [pscustomobject]$result
}
function Assert-HeavyCallerEligibility($Expected = $null) {
  if ($script:heavyAdmissionBudget) { $script:heavyAdmissionBudget.fences++ }
  $binding = Get-HeavyCallerBinding
  if ($binding.Reason) { throw "heavy-verifier: caller eligibility: $($binding.Reason)" }
  $workspaceDbImplementationLane = $isWorkspaceDbTest -and $binding.Record -and
    $binding.Record.laneRole -ceq 'implementation' -and $binding.Row -eq 7
  if ($binding.Record -and -not $workspaceDbImplementationLane -and
      ($binding.Record.laneRole -cne 'implementation' -or $binding.Row -eq 13)) {
    throw "heavy-verifier: caller eligibility: role=$($binding.Record.laneRole) routing-row=$($binding.Row) cannot reserve heavy verification"
  }
  if ($isControllerHostHeavyVerifier -and $binding.Record) {
    try {
      $callerWorktree = [IO.Path]::GetFullPath([string]$binding.Record.worktree).TrimEnd('\','/')
      if (-not [string]::Equals($callerWorktree, $worktreeFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'target worktree does not match caller identity'
      }
    } catch {
      throw "heavy-verifier: caller eligibility: $($_.Exception.Message)"
    }
  }
  if ($Expected -and ($Expected.Path -cne $binding.Path -or -not [string]::Equals($Expected.Raw, $binding.Raw, [StringComparison]::Ordinal) -or
      -not [string]::Equals($Expected.RoutingRaw, $binding.RoutingRaw, [StringComparison]::Ordinal))) { throw 'heavy-verifier: caller eligibility: launch or routing identity changed' }
  Assert-HeavyAdmissionTime
  return $binding
}
function Assert-HeavyAdmissionTime {
  if ($script:heavyAdmissionBudget -and $script:heavyAdmissionBudget.watch.ElapsedMilliseconds -ge $script:heavyAdmissionBudget.deadline) {
    throw 'heavy-verifier: caller eligibility: admission deadline'
  }
}
function Assert-HeavyAdmissionAfterLock([bool]$LockCreated) {
  if (-not $LockCreated) { return }
  try {
    Assert-HeavyAdmissionTime
  } catch {
    # No owner record or queue mutation exists yet. Release only the empty
    # directory this invocation just acquired, then refuse the expired census.
    if ((Test-SafeDirectory $lockPath) -and -not (Test-Path -LiteralPath $ownerPath)) {
      Remove-Item -LiteralPath $lockPath -Force -ErrorAction Stop
    }
    throw 'heavy-verifier: caller eligibility: dispatch census evaluation exhausted'
  }
}
try { . (Join-Path $PSScriptRoot 'dispatch-ownership.ps1') }
catch { throw "heavy-verifier: caller eligibility: ownership reader unavailable: $($_.Exception.Message)" }
$callerBinding = Invoke-HeavyAdmissionCensus { Assert-HeavyCallerEligibility }
Assert-HostVerifierGitState
if (($Gate -ceq 'test:e2e:suite') -ne $PSBoundParameters.ContainsKey('E2eSuite')) {
  throw 'heavy-verifier: test:e2e:suite requires one E2eSuite; other gates do not accept E2eSuite'
}

function Assert-NativeObject($Value, [string[]]$Keys) {
  if ($Value -isnot [pscustomobject]) { throw 'native-db: expected object' }
  $actual = @($Value.PSObject.Properties.Name)
  if ($actual.Count -ne $Keys.Count) { throw 'native-db: missing or unknown key' }
  foreach ($key in $Keys) { if ($actual -cnotcontains $key) { throw "native-db: missing key $key" } }
}
function Assert-NativeText($Value, [int]$Maximum, [string]$Pattern = '') {
  if ($Value -isnot [string] -or $Value.Length -lt 1 -or $Value.Length -gt $Maximum -or
      ($Pattern -and $Value -cnotmatch $Pattern)) { throw 'native-db: invalid string' }
}
function Assert-NativeInteger($Value, [long]$Maximum) {
  if (($Value -isnot [int] -and $Value -isnot [long]) -or $Value -lt 1 -or $Value -gt $Maximum) {
    throw 'native-db: invalid integer'
  }
}
function Assert-NativeRelativePath($Value) {
  Assert-NativeText $Value 1024 '^[A-Za-z0-9._/-]+$'
  if ($Value.StartsWith('/') -or @($Value.Split('/') | Where-Object { $_ -in @('', '.', '..') }).Count) {
    throw 'native-db: relative path escapes'
  }
}
function Assert-NativeCases($Value) {
  if ($Value -isnot [array] -or $Value.Count -lt 1 -or $Value.Count -gt 256) { throw 'native-db: invalid cases' }
  $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($case in $Value) {
    Assert-NativeText $case 512
    if (-not $seen.Add($case)) { throw 'native-db: duplicate case' }
  }
}
function Read-NativeJson([string]$Raw, [int]$Maximum) {
  if ([Text.Encoding]::UTF8.GetByteCount($Raw) -gt $Maximum) { throw 'native-db: message exceeds byte bound' }
  $options = [Text.Json.JsonDocumentOptions]::new(); $options.MaxDepth = 16
  $document = [Text.Json.JsonDocument]::Parse($Raw, $options)
  try {
    $walk = {
      param($Element)
      if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($property in $Element.EnumerateObject()) {
          if (-not $names.Add($property.Name)) { throw 'native-db: duplicate key' }
          & $walk $property.Value
        }
      } elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
        foreach ($item in $Element.EnumerateArray()) { & $walk $item }
      }
    }
    & $walk $document.RootElement
    return ConvertFrom-Json -InputObject $Raw -Depth 16 -DateKind String -NoEnumerate
  } finally { $document.Dispose() }
}
function Assert-NativeRequest($Request) {
  Assert-NativeObject $Request @('schemaVersion','correlation','profile','run','issue','attempt','executorHead','product','declaration','patchDigests','stagedInputDirectory')
  Assert-NativeInteger $Request.schemaVersion 1
  Assert-NativeInteger $Request.correlation 9007199254740991
  Assert-NativeInteger $Request.issue 2147483647
  Assert-NativeInteger $Request.attempt 2147483647
  Assert-NativeText $Request.profile 128
  if ($Request.profile -cne 'reconciliation-pg16/v1') { throw 'native-db: unsupported profile' }
  Assert-NativeText $Request.run 128 '^[A-Za-z0-9._:-]+$'
  Assert-NativeText $Request.executorHead 40 '^[a-f0-9]{40}$'
  Assert-NativeObject $Request.product @('repository','head','tree')
  Assert-NativeText $Request.product.repository 201 '^[A-Za-z0-9._-]{1,100}/[A-Za-z0-9._-]{1,100}$'
  foreach ($key in @('head','tree')) { Assert-NativeText $Request.product.$key 40 '^[a-f0-9]{40}$' }
  Assert-NativeObject $Request.declaration @('version','profile','files','mutants')
  Assert-NativeInteger $Request.declaration.version 1
  Assert-NativeText $Request.declaration.profile 128
  if ($Request.declaration.profile -cne $Request.profile) { throw 'native-db: declaration profile mismatch' }
  $files = $Request.declaration.files
  if ($files -isnot [array] -or $files.Count -ne 3) { throw 'native-db: exactly three profile files required' }
  $expected = @(
    'bounded-contexts/channels/features/reconciliation/tests/channel-drift-classification-table.test.ts',
    'bounded-contexts/channels/features/reconciliation/tests/channel-reconciliation-runtime.db.test.ts',
    'deployables/platform-worker/__tests__/channels-reconciliation-runners.db.test.ts'
  )
  $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($file in $files) {
    Assert-NativeObject $file @('file','cases'); Assert-NativeRelativePath $file.file; Assert-NativeCases $file.cases
    if ($file.file -cnotin $expected -or -not $seen.Add($file.file)) { throw 'native-db: invalid profile file' }
  }
  foreach ($list in @('mutants','patchDigests')) {
    $items = if ($list -ceq 'mutants') { ,$Request.declaration.mutants } else { ,$Request.patchDigests }
    if ($items -isnot [array] -or $items.Count -gt 3) { throw 'native-db: invalid mutant inventory' }
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($item in $items) {
      if ($list -ceq 'mutants') {
        Assert-NativeObject $item @('id','file','cases','assertion')
        Assert-NativeRelativePath $item.file; Assert-NativeCases $item.cases; Assert-NativeText $item.assertion 2048
      } else { Assert-NativeObject $item @('id','digest'); Assert-NativeText $item.digest 64 '^[a-f0-9]{64}$' }
      Assert-NativeText $item.id 128 '^[A-Za-z0-9._:-]+$'
      if (-not $ids.Add($item.id)) { throw 'native-db: duplicate mutant identity' }
    }
  }
  if (@($Request.declaration.mutants).Count -ne @($Request.patchDigests).Count) { throw 'native-db: patch inventory mismatch' }
  foreach ($item in $Request.declaration.mutants) {
    if ($item.id -cnotin @($Request.patchDigests.id)) { throw 'native-db: patch identity mismatch' }
  }
  Assert-NativeText $Request.stagedInputDirectory 1024 '^/srv/chase-sets-native-db-input/[^/\x00-\x1f]+$'
  if (($Request.stagedInputDirectory.Split('/')[-1]) -in @('.', '..')) { throw 'native-db: input path escapes' }
}
function Assert-NativeWindowsPath([string]$Path, [string]$Parent) {
  Assert-NativeText $Path 1024
  $full = [IO.Path]::GetFullPath($Path)
  $base = [IO.Path]::GetFullPath($Parent).TrimEnd('\','/')
  if (-not [IO.Path]::IsPathFullyQualified($Path) -or
      -not $full.StartsWith($base + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'native-db: path outside artifacts'
  }
  $current = $full
  while ($current) {
    if (Test-Path -LiteralPath $current) {
      if ((Get-Item -LiteralPath $current -Force).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
        throw 'native-db: reparse path refused'
      }
    }
    $current = Split-Path -Parent $current
  }
  return $full
}
function Write-NativeReply([string]$Status, [string]$Diagnostic = '') {
  $reply = [ordered]@{
    schemaVersion = 1; correlation = $nativeRequest.correlation; status = $Status
    owner = if ($ownedRaw) { @{ lockId = $lockId; head = $acquiredGitIdentity.Head; lane = $Lane } } else { $null }
    evidencePath = if ($nativeEvidencePath -and (Test-Path -LiteralPath $nativeEvidencePath)) { $nativeEvidencePath } else { $null }
    diagnostic = if ($Diagnostic) { $Diagnostic.Substring(0, [Math]::Min(2048, $Diagnostic.Length)) } else { $null }
  }
  $raw = $reply | ConvertTo-Json -Compress -Depth 8
  if ([Text.Encoding]::UTF8.GetByteCount($raw) -gt 8192) { throw 'native-db: reply exceeds byte bound' }
  [Console]::Out.WriteLine($raw)
  $script:nativeReplyWritten = $true
}
$nativeEvidencePath = $null
if ($isNativeDb) {
  if (-not $IsWindows -or $identityMode -cne 'branch') { throw 'native-db: clean attached Windows anchor required' }
  Assert-NativeText $Branch 128
  Assert-NativeText $worktreeFull 1024
  Assert-NativeText "$env:USERNAME@$env:COMPUTERNAME" 128
  $nativeRequestFull = Assert-NativeWindowsPath $NativeRequestPath (Join-Path $worktreeFull '.orchestrator/artifacts')
  if (-not (Test-Path -LiteralPath $nativeRequestFull -PathType Leaf) -or (Get-Item -LiteralPath $nativeRequestFull).Length -gt 65536) {
    throw 'native-db: request missing or oversized'
  }
  $ignored = @(& git -C $worktreeFull check-ignore -- $nativeRequestFull 2>$null)
  if ($LASTEXITCODE -ne 0 -or $ignored.Count -ne 1) { throw 'native-db: request must be ignored' }
  $nativeRequestBytes = [IO.File]::ReadAllBytes($nativeRequestFull)
  if ($nativeRequestBytes.Length -gt 65536) { throw 'native-db: request oversized' }
  $nativeRequestRaw = [Text.UTF8Encoding]::new($false, $true).GetString($nativeRequestBytes)
  $nativeRequest = Read-NativeJson $nativeRequestRaw 65536
  Assert-NativeRequest $nativeRequest
  $runDigest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($nativeRequest.run))).ToLowerInvariant()
  $nativeEvidencePath = Assert-NativeWindowsPath (Join-Path $worktreeFull ".orchestrator/artifacts/native-db-$runDigest-$($nativeRequest.correlation).json") (Join-Path $worktreeFull '.orchestrator/artifacts')
  if (Test-Path -LiteralPath $nativeEvidencePath) { throw 'native-db: correlation already consumed' }
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

# #9275's full fixture-equivalence check is host heavy verification, never a
# battery item (#9627). Only its tracked script and harness at the clean exact
# HEAD resolve; evidence goes to one fresh directory below a closed root beside
# the existing container context, so outside the runtime root and every
# container worktree.
$fixtureCheckScript = ".orchestrator/cleanup-scale-fixture-equivalence.check.ps1"
$fixtureCheckFiles = @($fixtureCheckScript, ".orchestrator/cleanup-scale-fixture-harness.ps1")
$fixtureCheckPath = $null
$fixtureCheckBlobs = [ordered]@{}
$fixtureEvidenceRoot = $null
$fixtureEvidence = $null
$fixtureWrapperDigest = $null
function Test-PathEntry([string]$Path) {
  # File attributes describe a link itself, so a dangling junction still exists.
  try { [void][IO.File]::GetAttributes($Path); return $true }
  catch [IO.FileNotFoundException], [IO.DirectoryNotFoundException] { return $false }
}
function Get-GitBlobId([byte[]]$Bytes) {
  $hash = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA1)
  try {
    $hash.AppendData([Text.Encoding]::ASCII.GetBytes("blob $($Bytes.Length)`0"))
    $hash.AppendData($Bytes)
    return [Convert]::ToHexString($hash.GetHashAndReset()).ToLowerInvariant()
  } finally { $hash.Dispose() }
}
# Status trusts the index, so an assume-unchanged or skip-worktree entry hides
# edited bytes. The file pwsh will execute must instead be the HEAD blob itself
# or its uniform CRLF checkout (core.autocrlf on a CR-free blob), with no Git
# filter or index flag consulted.
function Test-ControllerFixtureSourceBytes([string]$Path, [string]$Blob) {
  $bytes = [IO.File]::ReadAllBytes($Path)
  if ((Get-GitBlobId $bytes) -ceq $Blob) { return $true }
  # Latin-1 maps each byte to one char, so only line endings are rewritten.
  $text = [Text.Encoding]::Latin1.GetString($bytes)
  $lf = $text.Replace("`r`n", "`n")
  return -not $lf.Contains("`r") -and $lf.Replace("`n", "`r`n") -ceq $text -and
    (Get-GitBlobId ([Text.Encoding]::Latin1.GetBytes($lf))) -ceq $Blob
}
function Assert-ControllerFixtureGitState {
  $status = @(& git -C $worktreeFull status --porcelain=v1 --untracked-files=all --ignore-submodules=none 2>$null)
  if ($LASTEXITCODE -ne 0) {
    throw "heavy-verifier: unable to verify the controller fixture worktree is clean"
  }
  if ($status.Count -ne 0) {
    throw "heavy-verifier: controller fixture equivalence requires a clean exact-head worktree"
  }
  if (-not (Test-PrecursorSafeDirectory $worktreeFull) -or -not (Test-PrecursorSafeDirectory (Join-Path $worktreeFull ".orchestrator"))) {
    throw "heavy-verifier: controller fixture worktree or runtime root is unsafe"
  }
  # The container ignores .orchestrator/*, so a clean status alone cannot rule
  # out an ignored substitute; each file must be tracked at the exact HEAD.
  foreach ($relative in $fixtureCheckFiles) {
    $tracked = Invoke-GitIdentityProbe @("ls-tree", $acquiredGitIdentity.Head, "--", $relative) "fixture check"
    $blob = if ($tracked -cmatch "^100(?:644|755) blob ([a-f0-9]{40})`t$([regex]::Escape($relative))$") { $Matches[1] } else { $null }
    if (-not $blob) {
      throw "heavy-verifier: controller fixture check is not one exact tracked regular script: $relative"
    }
    $sourcePath = Join-Path $worktreeFull $relative
    if (-not (Test-PrecursorSafeFile $sourcePath)) {
      throw "heavy-verifier: controller fixture check is absent or unsafe: $relative"
    }
    if (-not (Test-ControllerFixtureSourceBytes $sourcePath $blob)) {
      throw "heavy-verifier: controller fixture check bytes do not match the exact HEAD blob: $relative"
    }
    $script:fixtureCheckBlobs[$relative] = $blob
  }
  $script:fixtureCheckPath = [IO.Path]::GetFullPath((Join-Path $worktreeFull $fixtureCheckScript))
}

# The complete default host-heavy verifier is a controller-slot route, but its
# authority is the tracked test file and native helper set, not an arbitrary
# command or caller-supplied path.
$hostHeavyVerifierScript = ".orchestrator/host-heavy-verifier.test.ps1"
$hostHeavyVerifierFiles = @(
  $hostHeavyVerifierScript,
  ".orchestrator/invoke-heavy-verifier.ps1",
  ".orchestrator/native-db-admission.py",
  ".orchestrator/heavy-admission-preload.cjs",
  ".orchestrator/heavy-slot.cjs",
  ".orchestrator/heavy-nested-owner.cs",
  ".orchestrator/heavy-nested-client.cjs",
  ".orchestrator/heavy-admission-holder-launcher.cjs",
  ".orchestrator/dispatch-ownership.ps1"
)
$hostHeavyVerifierBlobs = [ordered]@{}
$hostHeavyVerifierPath = $null
$hostHeavyControllerBlobs = [ordered]@{}
$hostHeavyControllerRoot = $null
$hostHeavyControllerHead = $null
function Assert-ControllerHostHeavyControllerState {
  $root = if ($env:CHASE_SETS_CONTROLLER_ROOT) { [IO.Path]::GetFullPath($env:CHASE_SETS_CONTROLLER_ROOT) } else { [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)) }
  $status = @(& git -C $root status --porcelain=v1 --untracked-files=all --ignore-submodules=none 2>$null)
  if ($LASTEXITCODE -ne 0 -or $status.Count -ne 0) { throw 'heavy-verifier: controller source root must be a clean exact-head worktree' }
  $head = (@(& git -C $root rev-parse HEAD 2>$null) -join '').Trim()
  if ($head -notmatch '^[a-f0-9]{40}$') { throw 'heavy-verifier: controller source root head is unavailable' }
  $files = @('.orchestrator/invoke-heavy-verifier.ps1','.orchestrator/dispatch-ownership.ps1')
  $blobs = [ordered]@{}
  foreach ($relative in $files) {
    $tracked = @(& git -C $root ls-tree $head -- $relative 2>$null) -join ''
    if ($tracked -notmatch "^100(?:644|755) blob ([a-f0-9]{40})`t$([regex]::Escape($relative))$") { throw "heavy-verifier: controller source is not one exact tracked regular script: $relative" }
    $path = Join-Path $root $relative
    if (-not (Test-PrecursorSafeFile $path) -or -not (Test-ControllerFixtureSourceBytes $path $Matches[1])) { throw "heavy-verifier: controller source bytes do not match its exact HEAD blob: $relative" }
    $blobs[$relative] = $Matches[1]
  }
  $script:hostHeavyControllerRoot = $root
  $script:hostHeavyControllerHead = $head
  $script:hostHeavyControllerBlobs = $blobs
}
function Assert-ControllerHostHeavyGitState {
  $status = @(& git -C $worktreeFull status --porcelain=v1 --untracked-files=all --ignore-submodules=none 2>$null)
  if ($LASTEXITCODE -ne 0) { throw "heavy-verifier: unable to verify the host-heavy verifier worktree is clean" }
  if ($status.Count -ne 0) { throw "heavy-verifier: host-heavy verifier requires a clean exact-head worktree" }
  if (-not (Test-PrecursorSafeDirectory $worktreeFull) -or
      -not (Test-PrecursorSafeDirectory (Join-Path $worktreeFull ".orchestrator"))) {
    throw "heavy-verifier: host-heavy verifier worktree or runtime root is unsafe"
  }
  foreach ($relative in $hostHeavyVerifierFiles) {
    $tracked = Invoke-GitIdentityProbe @("ls-tree", $acquiredGitIdentity.Head, "--", $relative) "host-heavy verifier source"
    $blob = if ($tracked -cmatch "^100(?:644|755) blob ([a-f0-9]{40})`t$([regex]::Escape($relative))$") { $Matches[1] } else { $null }
    if (-not $blob) { throw "heavy-verifier: host-heavy verifier source is not one exact tracked regular script: $relative" }
    $sourcePath = Join-Path $worktreeFull $relative
    if (-not (Test-PrecursorSafeFile $sourcePath)) { throw "heavy-verifier: host-heavy verifier source is absent or unsafe: $relative" }
    if (-not (Test-ControllerFixtureSourceBytes $sourcePath $blob)) { throw "heavy-verifier: host-heavy verifier source bytes do not match the exact HEAD blob: $relative" }
    $script:hostHeavyVerifierBlobs[$relative] = $blob
  }
  $script:hostHeavyVerifierPath = [IO.Path]::GetFullPath((Join-Path $worktreeFull $hostHeavyVerifierScript))
}
function Resolve-ControllerFixtureEvidence([string]$Value) {
  $parent = Split-Path -Parent $container
  if ([string]::IsNullOrEmpty($parent)) { throw "heavy-verifier: controller fixture evidence root is unavailable" }
  $root = [IO.Path]::GetFullPath((Join-Path $parent ((Split-Path -Leaf $container) + "-heavy-evidence"))).TrimEnd('\','/')
  if ([string]::IsNullOrWhiteSpace($Value) -or -not [IO.Path]::IsPathFullyQualified($Value)) {
    throw "heavy-verifier: controller fixture evidence must be an absolute directory below the closed evidence root $root"
  }
  $full = [IO.Path]::GetFullPath($Value).TrimEnd('\','/')
  # The supplied spelling must already be canonical: no relative segments,
  # alternate roots or names that Windows would silently rewrite.
  $canonical = [string]::Equals($Value.Replace([IO.Path]::AltDirectorySeparatorChar, [IO.Path]::DirectorySeparatorChar).TrimEnd([IO.Path]::DirectorySeparatorChar), $full, [StringComparison]::OrdinalIgnoreCase)
  $insideRoot = [string]::Equals((Split-Path -Parent $full), $root, [StringComparison]::OrdinalIgnoreCase)
  if (-not $canonical -or -not $insideRoot -or (Split-Path -Leaf $full) -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$') {
    throw "heavy-verifier: controller fixture evidence must be one new [A-Za-z0-9_-] directory directly below the closed evidence root $root"
  }
  $script:fixtureEvidenceRoot = $root
  $script:fixtureEvidence = $full
}
function Assert-ControllerFixtureEvidencePath {
  # GetFullPath fixes spelling, not reparse traversal: a junction anywhere above
  # the root could redirect it into a worktree whose .git is outside this
  # lexical ancestry. Every existing ancestor must be a plain directory.
  for ($ancestor = Split-Path -Parent $fixtureEvidenceRoot; $ancestor; $ancestor = Split-Path -Parent $ancestor) {
    if ((Test-PathEntry $ancestor) -and -not (Test-PrecursorSafeDirectory $ancestor)) {
      throw "heavy-verifier: controller fixture evidence ancestor is a symlink, reparse point, or unsafe directory: $ancestor"
    }
  }
  for ($ancestor = $fixtureEvidenceRoot; $ancestor; $ancestor = Split-Path -Parent $ancestor) {
    if (Test-PathEntry (Join-Path $ancestor ".git")) {
      throw "heavy-verifier: controller fixture evidence root is inside a Git worktree"
    }
  }
  if ((Test-PathEntry $fixtureEvidenceRoot) -and -not (Test-PrecursorSafeDirectory $fixtureEvidenceRoot)) {
    throw "heavy-verifier: controller fixture evidence root is a symlink, reparse point, or unsafe directory"
  }
}
function Assert-ControllerFixtureEvidenceFresh {
  Assert-ControllerFixtureEvidencePath
  if (Test-PathEntry $fixtureEvidence) {
    throw "heavy-verifier: controller fixture evidence directory already exists; evidence is never reused"
  }
}
function New-ControllerFixtureEvidence {
  Assert-ControllerFixtureEvidenceFresh
  if (-not (Test-PathEntry $fixtureEvidenceRoot)) { [void][IO.Directory]::CreateDirectory($fixtureEvidenceRoot) }
  if (-not (Test-PrecursorSafeDirectory $fixtureEvidenceRoot)) {
    throw "heavy-verifier: controller fixture evidence root is a symlink, reparse point, or unsafe directory"
  }
  [void][IO.Directory]::CreateDirectory($fixtureEvidence)
  if (-not (Test-PrecursorSafeDirectory $fixtureEvidence) -or @(Get-ChildItem -LiteralPath $fixtureEvidence -Force).Count -ne 0) {
    throw "heavy-verifier: controller fixture evidence directory is unsafe or not fresh"
  }
}

if ($isControllerFixture) {
  Assert-ControllerFixtureGitState
  Resolve-ControllerFixtureEvidence $ControllerFixtureEvidenceDirectory
  Assert-ControllerFixtureEvidenceFresh
  $fixtureWrapperDigest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($PSCommandPath))).ToLowerInvariant()
}
if ($isControllerHostHeavyVerifier) {
  Assert-ControllerHostHeavyControllerState
  Assert-ControllerHostHeavyGitState
}

# Controller release batteries and precursors own a separate slot (Todd ruling
# 2026-09-10): they never wait on, and never block, the platform heavy verifier.
# The fixture-equivalence route shares that controller slot.
$lockDirectoryName = if ($isControllerBattery -or $isControllerPrecursor -or $isControllerFixture -or $isControllerHostHeavyVerifier) { "controller-verify-lock.d" } else { "verify-lock.d" }
$lockPath = Join-Path $container (".orchestrator\" + $lockDirectoryName)
$ownerPath = Join-Path $lockPath "owner.json"
$queueFileStem = if ($isControllerSlot) { 'controller-verify-queue' } else { 'verify-queue' }
$queuePath = Join-Path $container (".orchestrator\$queueFileStem.json")
$queueRecoveryPath = Join-Path $container (".orchestrator\$queueFileStem.recovery")
$queueRecordRoot = Join-Path $container (".orchestrator\$queueFileStem-quarantine")
$queueLabel = if ($isControllerSlot) { 'controller verify queue' } else { 'verify queue' }
$queueRetentionSeconds = 600
$queueMaximumTickets = 128
$queueMaximumBytes = 256 * 1024
$process = Get-Process -Id $PID -ErrorAction Stop
$started = $process.StartTime.ToUniversalTime().ToString("o")
$pnpmScript = $null
$hostNode = $null
if ($isHostVerifier) {
  $hostNode = @(Get-Command node -All -CommandType Application -ErrorAction SilentlyContinue | Where-Object {
    [IO.Path]::GetFileName($_.Source) -imatch '^node(?:\.exe)?$' -and (Test-PrecursorSafeFile $_.Source)
  }) | Select-Object -First 1 -ExpandProperty Source
  # Resolve the standard Node distribution, not a shell shim or embedded Node
  # executable whose process.execPath is pnpm.exe. Never execute shim text.
  foreach ($entry in @(Get-Command pnpm -All -CommandType Application -ErrorAction SilentlyContinue)) {
    $candidate = Join-Path (Split-Path -Parent $entry.Source) "node_modules/pnpm/bin/pnpm.cjs"
    if (Test-PrecursorSafeFile $candidate) { $pnpmScript = [IO.Path]::GetFullPath($candidate); break }
  }
  if (-not $hostNode -or -not $pnpmScript) {
    throw "heavy-verifier: invoke-heavy-verifier.ps1 requires a plain Node executable and Node-hosted pnpm distribution; no unguarded fallback"
  }
}
$command = if ($isAttachedAdmission) {
  $guarded.Path
} elseif ($isNativeDb) {
  'C:\Windows\System32\wsl.exe'
} elseif ($isControllerBattery -or $isControllerPrecursor -or $isControllerFixture -or $isControllerHostHeavyVerifier) {
  (Get-Process -Id $PID -ErrorAction Stop).Path
} elseif ($isDiagnostic) {
  $hostNode
} elseif ($CommandPath) {
  [IO.Path]::GetFullPath($CommandPath)
} else {
  $hostNode
}
if (-not (Test-Path -LiteralPath $command -PathType Leaf)) { throw "heavy-verifier: command executable was not found" }
$arguments = if ($isAttachedAdmission) {
  @($AdmissionCommand)
} elseif ($isNativeDb) {
  @('-d','Ubuntu','--exec','/usr/bin/env','-i','PATH=/usr/bin:/bin','HOME=<R>','LANG=C',
    '/usr/bin/python3','/opt/chase-sets-native-db/admission.py','launch','<R>')
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
    "-Scope", $ControllerBatteryScope,
    "-PriorResultPath", $ControllerBatteryPriorResultPath,
    "-NoReuseIdentity", $ControllerBatteryNoReuseIdentity,
    "-ConcurrentIdentity", $ControllerBatteryConcurrentIdentity,
    "-OnFailure", $ControllerBatteryOnFailure,
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
} elseif ($isControllerHostHeavyVerifier) {
  @("-NoProfile", "-NonInteractive", "-File", $hostHeavyVerifierPath)
} elseif ($isControllerFixture) {
  # Never -BaselineHead or -RunDirectory: the check keeps its immutable oracle
  # and runs every fixture step in one call.
  @("-NoProfile", "-NonInteractive", "-File", $fixtureCheckPath, "-Phase", "fixture", "-EvidenceDirectory", $fixtureEvidence)
} elseif ($CommandPath) {
  @($CommandArgumentList)
} elseif ($isDiagnostic) {
  if ($diagnosticVitestCommand) { @($pnpmScript) + @($diagnosticCommandArguments) }
  else { @($diagnosticScriptFull) }
} elseif ($isWorkspaceDbTest) {
  $workspaceDbRunnerPath = Join-Path $PSScriptRoot 'workspace-db-test.mjs'
  if (-not (Test-SafeFile $workspaceDbRunnerPath)) {
    throw 'heavy-verifier: canonical workspace DB runner is absent or unsafe'
  }
  $workspaceDbArguments = @($workspaceDbRunnerPath, '--pnpm-script', $pnpmScript)
  if ($workspaceDbFile) { $workspaceDbArguments += @('--file', $workspaceDbFile) }
  $workspaceDbArguments
} else {
  if ($isWorkspaceTest) { @($pnpmScript, "--filter", $WorkspaceTest, "run", "test", "--maxWorkers=1", "--no-file-parallelism") }
  elseif ($Gate -ceq 'test:e2e:suite') { @($pnpmScript, 'run', $Gate, '--', $E2eSuite) }
  else { @($pnpmScript, "run", $Gate) }
}
$ownerGate = if ($isNativeDb) { 'verify:test-db' } elseif ($isAttachedAdmission) { $AdmissionKind } elseif ($isControllerBattery -or $isControllerPrecursor -or $isControllerFixture -or $isControllerHostHeavyVerifier) { "script-battery" } elseif ($isWorkspaceDbTest) { 'verify:test-db' } elseif ($isWorkspaceTest) { "test" } elseif ($isDiagnostic) { "diagnostic" } else { $Gate }
$identityInput = "$ownerGate`n$command`n$($arguments -join "`n")"
$commandIdentity = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($identityInput))).ToLowerInvariant()
$lockId = [guid]::NewGuid().ToString("N")
$owner = [ordered]@{
  schemaVersion = $(if($isNativeDb){6}elseif($isAttachedAdmission){5}else{4}); lockId = $lockId; owner = "$env:USERNAME@$env:COMPUTERNAME"; lane = $Lane
  branch = $(if ($identityMode -ceq "branch") { $acquiredGitIdentity.Branch } else { $null })
  worktree = $acquiredGitIdentity.Worktree; head = $acquiredGitIdentity.Head; identityMode = $identityMode
  pid = $PID; processStartUtc = $started; startedUtc = [DateTime]::UtcNow.ToString("o")
  gate = $ownerGate; commandIdentity = $commandIdentity
  state = $(if ($isAttachedAdmission) { "attached" } else { "launching" })
  childPid = $(if ($isAttachedAdmission) { $GuardedPid } else { $null })
  childProcessStartUtc = $(if ($isAttachedAdmission) { $GuardedProcessStartUtc } else { $null })
}
if($isAttachedAdmission){$owner.admissionRoot=$admissionRoot}
if ($isNativeDb) {
  $owner.native = [ordered]@{
    profile = 'reconciliation-pg16/v1'
    request = @{ path = $nativeRequestFull; digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($nativeRequestRaw))).ToLowerInvariant() }
    root = "/srv/chase-sets-pg-probe/native-db-$lockId"; linux = $null
  }
  $arguments = @($arguments | ForEach-Object { $_.Replace('<R>', $owner.native.root) })
  $identityInput = "$ownerGate`n$command`n$($arguments -join "`n")"
  $commandIdentity = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($identityInput))).ToLowerInvariant()
  $owner.commandIdentity = $commandIdentity
}
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
function Get-OwnerSnapshot([string]$RecordPath = $ownerPath) {
  if (-not (Test-SafeDirectory $lockPath) -or -not (Test-SafeFile $RecordPath)) { return $null }
  try {
    $entries = @(Get-ChildItem -LiteralPath $lockPath -Force -ErrorAction Stop)
    if ($entries.Count -ne 1 -or -not (Test-SamePath $entries[0].FullName $RecordPath)) { return $null }
    $openDeadline = [Diagnostics.Stopwatch]::StartNew()
    $stream = $null
    for ($openAttempt = 1; $null -eq $stream; $openAttempt++) {
      try {
        $stream = [IO.File]::Open($RecordPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
      } catch {
        $exception = $_.Exception.GetBaseException()
        $errorCode = [int]$exception.HResult -band 0xffff
        if (-not $IsWindows -or ($exception -isnot [IO.IOException] -and $exception -isnot [UnauthorizedAccessException]) -or
            $errorCode -notin @(5, 32) -or $openAttempt -ge 8 -or $openDeadline.ElapsedMilliseconds -ge 1000) { throw }
        [Threading.Thread]::Sleep([int][Math]::Min(10, [Math]::Max(1, 1000 - $openDeadline.ElapsedMilliseconds)))
        if ($openDeadline.ElapsedMilliseconds -ge 1000) { throw }
      }
    }
    $buffer = [IO.MemoryStream]::new()
    try { $stream.CopyTo($buffer); $bytes = $buffer.ToArray() } finally { $stream.Dispose(); $buffer.Dispose() }
    $buffer = [IO.MemoryStream]::new($bytes, $false)
    $reader = [IO.StreamReader]::new($buffer, [Text.Encoding]::UTF8, $true)
    try { $raw = $reader.ReadToEnd() } finally { $reader.Dispose() }
    $record = $raw | ConvertFrom-Json -DateKind String -ErrorAction Stop
    if ($record.schemaVersion -eq 6) {
      if ($bytes.Length -gt 16384) { return $null }
      $raw = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
      $record = Read-NativeJson $raw 16384
    }
    return [pscustomobject]@{ Raw = $raw; Record = $record }
  } catch {
    return $null
  }
}
function Test-NativeTuple($Tuple) {
  try {
    Assert-NativeObject $Tuple @('bootId','outerPid','startTicks','nspid','inode')
    Assert-NativeText $Tuple.bootId 36 '^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$'
    Assert-NativeInteger $Tuple.outerPid 2147483647
    if ($Tuple.nspid -isnot [array] -or $Tuple.nspid.Count -ne 2) { return $false }
    foreach ($value in $Tuple.nspid) { Assert-NativeInteger $value 2147483647 }
    if ($Tuple.nspid[0] -ne $Tuple.outerPid -or $Tuple.nspid[1] -ne 1) { return $false }
    foreach ($key in @('startTicks','inode')) {
      Assert-NativeText $Tuple.$key 20 '^[0-9]{1,20}$'
      $number = [uint64]0
      if (-not [uint64]::TryParse($Tuple.$key, [ref]$number) -or $number -eq 0) { return $false }
    }
    return $true
  } catch { return $false }
}
function Test-NativeOwnerShape($Record) {
  try {
    if ([Text.Encoding]::UTF8.GetByteCount(($Record | ConvertTo-Json -Depth 16 -Compress)) -gt 16384) { return $false }
    foreach ($key in @('owner','lane','branch','identityMode','gate','state')) { Assert-NativeText $Record.$key 128 }
    foreach ($key in @('processStartUtc','startedUtc','childProcessStartUtc')) {
      if ($null -eq $Record.$key -and $key -ceq 'childProcessStartUtc' -and $Record.state -ceq 'launching') { continue }
      Assert-NativeText $Record.$key 128 '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?Z$'
      if (-not (Test-UtcIdentity $Record.$key)) { return $false }
    }
    foreach ($key in @('lockId','head','commandIdentity')) { if ($Record.$key -isnot [string]) { return $false } }
    if ($Record.identityMode -cne 'branch' -or $Record.gate -cne 'verify:test-db' -or $Record.state -cnotin @('launching','started')) { return $false }
    Assert-NativeText $Record.worktree 1024
    Assert-NativeObject $Record.native @('profile','request','root','linux')
    Assert-NativeText $Record.native.profile 128
    if ($Record.native.profile -cne 'reconciliation-pg16/v1') { return $false }
    Assert-NativeObject $Record.native.request @('path','digest')
    Assert-NativeText $Record.native.request.digest 64 '^[a-f0-9]{64}$'
    Assert-NativeText $Record.native.request.path 1024
    [void](Assert-NativeWindowsPath $Record.native.request.path (Join-Path $Record.worktree '.orchestrator/artifacts'))
    if ($Record.native.root -isnot [string] -or $Record.native.root -cne "/srv/chase-sets-pg-probe/native-db-$($Record.lockId)") { return $false }
    if ($Record.state -ceq 'launching' -and $null -ne $Record.native.linux) { return $false }
    if ($null -ne $Record.native.linux -and -not (Test-NativeTuple $Record.native.linux)) { return $false }
    return $true
  } catch { return $false }
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
  } elseif ($Record.schemaVersion -eq 6) {
    @($legacyCommon) + @('worktree','head','identityMode','state','childPid','childProcessStartUtc','native')
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
  if ($Record.schemaVersion -eq 6 -and -not (Test-NativeOwnerShape $Record)) { return $false }
  if ($Record.schemaVersion -in @(4,5,6)) {
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
      $Record.gate -cnotin @("verify:static", "check:static", "test:scripts", "verify:test", "test", "test:fast", "build", "verify", "verify:build", "verify:test-db", "test:e2e:suite", "repository-gate", "playwright", "vitest-full", "script-battery", "diagnostic") -or
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
        $parentCreationTicks = if ($null -eq $parent.CreationTicks) {
          $rootTicks = [DateTimeOffset]::Parse($parent.StartIdentity).ToUniversalTime().Ticks; $rootTicks - ($rootTicks % 10)
        } else { [long]$parent.CreationTicks }
        # Earlier creation belongs to a previous parent PID incarnation. Roots are
        # cut to CIM's whole microseconds first; equal ticks stay eligible.
        if ($createdAt.Ticks -lt $parentCreationTicks) { continue }
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
function Get-QueueSha256([byte[]]$Bytes) {
  return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}
function Read-QueueContent([string]$Path) {
  $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
  try {
    $size = $stream.Length
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant()
    $bytes = $null
    if ($size -le $queueMaximumBytes) {
      $bytes = [byte[]]::new([int]$size); $stream.Position = 0; $stream.ReadExactly($bytes)
      if ((Get-QueueSha256 $bytes) -cne $hash) { throw 'changed-during-read' }
    }
    if ($stream.Length -ne $size) { throw 'changed-during-read' }
    return [pscustomobject]@{Bytes=$bytes;Size=$size;Hash=$hash}
  } finally { $stream.Dispose() }
}
function Get-QueueFileIdentity([string]$Path) {
  if (-not ('ChaseSets.QueueFiles' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace ChaseSets {
  public static class QueueFiles {
    [StructLayout(LayoutKind.Sequential)] struct Info {
      public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Created, Accessed, Written;
      public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern SafeFileHandle CreateFileW(string p, uint a, uint s, IntPtr security, uint d, uint f, IntPtr t);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool GetFileInformationByHandle(SafeFileHandle h, out Info i);
    public static string Identity(string path) {
      using (var h = CreateFileW(path, 0x80, 7, IntPtr.Zero, 3, 0x00200000, IntPtr.Zero)) {
        Info i;
        if (h.IsInvalid || !GetFileInformationByHandle(h, out i)) throw new Win32Exception(Marshal.GetLastWin32Error());
        if ((i.Attributes & 0x410) != 0 || i.Links != 1) throw new System.IO.IOException("unsafe-file");
        return i.Volume.ToString("x8") + ":" + i.IndexHigh.ToString("x8") + i.IndexLow.ToString("x8");
      }
    }
  }
}
'@
  }
  return [ChaseSets.QueueFiles]::Identity($Path)
}
function Assert-QueuePathSafe([string]$Path) {
  for ($parent = Split-Path -Parent $Path; $parent; $parent = Split-Path -Parent $parent) {
    if (-not (Test-SafeDirectory $parent)) { throw 'unsafe-parent' }
  }
  if (Test-PathEntry $Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
      throw 'unsafe-file'
    }
  }
}
function Get-QueueClaimant {
  if ($callerBinding.Record) {
    $record = $callerBinding.Record
    $claimPid = if ($record.childPid) { [int]$record.childPid } else { [int]$record.launcherPid }
    $start = if ($record.childPid) { [string]$record.childStartIdentity } else { [string]$record.launcherStartIdentity }
    if ([string]::IsNullOrWhiteSpace([string]$record.launchId) -or $claimPid -le 0 -or -not (Test-UtcIdentity $start)) {
      throw 'heavy-verifier: verify queue claimant identity is unavailable'
    }
    $baseKey = "launch:$($record.launchId)"
    return [pscustomobject]@{
      # Controller batteries are retried by a fresh battery process. Keep the
      # containing launch as the lifecycle identity, but bind its ticket to
      # the exact command so an unrelated controller command cannot inherit
      # the position. Product tickets retain #94's launch-only identity.
      Key = $baseKey
      Pid = $claimPid; StartIdentity = $start
      ChildPid = if ($record.childPid) { [int]$record.childPid } else { $null }
      ChildStartIdentity = if ($record.childPid) { [string]$record.childStartIdentity } else { $null }
      CommandIdentity = if ($isControllerSlot) { $commandIdentity } else { $null }
    }
  }
  if ($hasControllerBatteryClaimant) {
    if ((Get-ProcessIdentityState $ControllerBatteryClaimantPid $ControllerBatteryClaimantStartUtc) -cne 'live') {
      throw 'heavy-verifier: verify queue claimant identity is unavailable'
    }
    return [pscustomobject]@{
      Key = "battery:$ControllerBatteryClaimantPid`:$ControllerBatteryClaimantStartUtc"
      Pid = $ControllerBatteryClaimantPid; StartIdentity = $ControllerBatteryClaimantStartUtc
      ChildPid = $null; ChildStartIdentity = $null; CommandIdentity = $commandIdentity
    }
  }
  try {
    $rootPid = if ($isAttachedAdmission) { $GuardedPid } else { $PID }
    $rootStart = if ($isAttachedAdmission) { $GuardedProcessStartUtc } else { (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o') }
    $rootRow = @(Get-CimInstance Win32_Process -Filter "ProcessId = $rootPid" -ErrorAction Stop)
    if ($rootRow.Count -ne 1) { throw 'admitted root parent is ambiguous' }
    $parentId = [int]$rootRow[0].ParentProcessId
    $parent = Get-Process -Id $parentId -ErrorAction Stop
    $start = $parent.StartTime.ToUniversalTime().ToString('o')
    if ((Get-ProcessIdentityState $rootPid $rootStart) -cne 'live' -or
        (Get-ProcessIdentityState $parentId $start) -cne 'live' -or
        $parent.StartTime.ToUniversalTime() -gt [DateTimeOffset]::Parse($rootStart).UtcDateTime) { throw 'parent identity changed' }
    $baseKey = "parent:$parentId`:$start"
    return [pscustomobject]@{
      Key = $baseKey
      Pid = $parentId; StartIdentity = $start; ChildPid = $null; ChildStartIdentity = $null
      CommandIdentity = if ($isControllerSlot) { $commandIdentity } else { $null }
    }
  } catch {
    throw "heavy-verifier: verify queue claimant identity is unavailable: $($_.Exception.Message)"
  }
}
function Test-PossibleQueueDescendant($Ticket) {
  return Test-PossibleOwnedChild ([pscustomobject]@{
    pid = $Ticket.pid; processStartUtc = $Ticket.startIdentity; startedUtc = $Ticket.startIdentity
    state = if ($Ticket.childPid) { 'started' } else { 'launching' }
    childPid = $Ticket.childPid; childProcessStartUtc = $Ticket.childStartIdentity
  })
}
function Get-QueueNow {
  if ($queueFixture.now) { return [DateTimeOffset]::Parse($queueFixture.now) }
  return [DateTimeOffset]::UtcNow
}
function Test-QueueUtc($Value) {
  if ($Value -isnot [string]) { return $false }
  $parsed = [DateTimeOffset]::MinValue
  return [DateTimeOffset]::TryParseExact($Value, 'o', [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed) -and $parsed.Offset -eq [TimeSpan]::Zero
}
function Test-QueueTicketRetained($Ticket, [DateTimeOffset]$Now) {
  $presented = [DateTimeOffset]::Parse([string]$Ticket.presentedUtc).ToUniversalTime()
  if (($Now - $presented).TotalSeconds -gt $queueRetentionSeconds) { return $false }
  $state = Get-ProcessIdentityState $Ticket.pid ([string]$Ticket.startIdentity)
  $probe = @($queueFixture.probes | Where-Object { $_.pid -eq $Ticket.pid -and $_.startIdentity -ceq $Ticket.startIdentity } | Select-Object -First 1)
  if ($probe.Count -eq 1) { $state = $probe[0].state }
  if ($state -in @('live','ambiguous')) { return $true }
  if ($state -in @('dead','reused')) {
    $descendant = Test-PossibleQueueDescendant $Ticket
    if ($probe.Count -eq 1) { $descendant = $probe[0].descendant }
    return $false -ne $descendant
  }
  return $true
}
function Read-VerifyQueue {
  $bytes = $null; $size = 'unknown'; $hash = 'unknown'
  try {
    Assert-QueuePathSafe $queuePath
    if (-not (Test-PathEntry $queuePath)) {
      return [pscustomobject]@{ Exists = $false; Raw = $null; Bytes = [byte[]]@(); Hash = $null; Identity = $null; NextTicket = 1L; Tickets = @() }
    }
    $identity = Get-QueueFileIdentity $queuePath
    $content = Read-QueueContent $queuePath; $bytes = $content.Bytes; $size = $content.Size; $hash = $content.Hash
    if ($size -gt $queueMaximumBytes) { throw 'over-capacity' }
    $raw = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    $doc = Read-NativeJson $raw $queueMaximumBytes
    Assert-NativeObject $doc @('schemaVersion','fileIdentity','nextTicket','tickets')
    if ($doc.fileIdentity -isnot [string] -or $doc.fileIdentity -cne $identity -or (Get-QueueFileIdentity $queuePath) -cne $identity) { throw 'replaced-file' }
    if (($doc.schemaVersion -isnot [int] -and $doc.schemaVersion -isnot [long]) -or $doc.schemaVersion -ne 1 -or ($doc.nextTicket -isnot [int] -and $doc.nextTicket -isnot [long]) -or
        $doc.nextTicket -lt 1 -or $doc.nextTicket -ge [long]::MaxValue -or
        $doc.tickets -isnot [array] -or $doc.tickets.Count -gt $queueMaximumTickets) { throw 'malformed-schema-or-capacity' }
    $numbers = [Collections.Generic.HashSet[long]]::new(); $claimants = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $previous = 0L
    foreach ($ticket in @($doc.tickets)) {
      $keys = (@($ticket.PSObject.Properties.Name) | Sort-Object) -join ','
      $expectedTicketKeys = if ($isControllerSlot) {
        'childPid,childStartIdentity,claimantKey,commandIdentity,number,pid,presentedUtc,startIdentity'
      } else {
        'childPid,childStartIdentity,claimantKey,number,pid,presentedUtc,startIdentity'
      }
      if ($keys -cne $expectedTicketKeys -or
          $ticket.number -isnot [int] -and $ticket.number -isnot [long] -or $ticket.number -lt 1 -or
          $ticket.number -le $previous -or $ticket.number -ge $doc.nextTicket -or
          -not $numbers.Add([long]$ticket.number) -or $ticket.claimantKey -isnot [string] -or $ticket.claimantKey.Length -lt 3 -or $ticket.claimantKey.Length -gt 256 -or
          -not $claimants.Add($(if ($isControllerSlot) { "$($ticket.claimantKey)|$($ticket.commandIdentity)" } else { $ticket.claimantKey })) -or -not (Test-PositivePid $ticket.pid) -or
          -not (Test-QueueUtc $ticket.startIdentity) -or -not (Test-QueueUtc $ticket.presentedUtc)) { throw 'malformed-ticket' }
      if ($isControllerSlot -and ($ticket.commandIdentity -isnot [string] -or $ticket.commandIdentity -cnotmatch '^[a-f0-9]{64}$')) { throw 'malformed-command-identity' }
      if ($null -ne $ticket.childPid -and (-not (Test-PositivePid $ticket.childPid) -or -not (Test-QueueUtc $ticket.childStartIdentity))) { throw 'malformed-child-ticket' }
      if ($null -eq $ticket.childPid -and $null -ne $ticket.childStartIdentity) { throw 'malformed-child-ticket' }
      $previous = [long]$ticket.number
    }
    $ordered = @($doc.tickets | Sort-Object number)
    for ($i = 1; $i -lt $ordered.Count; $i++) { if ($ordered[$i - 1].number -ge $ordered[$i].number) { throw 'ticket-order' } }
    return [pscustomobject]@{ Exists = $true; Raw = $raw; Bytes = $bytes; Hash = $hash; Identity = $identity; NextTicket = [long]$doc.nextTicket; Tickets = $ordered }
  } catch {
    throw "heavy-verifier: verify queue invalid (path=$queuePath size=$size sha256=$hash reason=$($_.Exception.Message))"
  }
}
function Write-VerifyQueue($Queue, [switch]$CreateNew) {
  Assert-QueuePathSafe $queuePath
  $temporary = "$queuePath.$([guid]::NewGuid().ToString('N')).tmp"
  try {
    $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
    $identity = Get-QueueFileIdentity $temporary
    $doc = [ordered]@{ schemaVersion = 1; fileIdentity = $identity; nextTicket = [long]$Queue.NextTicket; tickets = @($Queue.Tickets) }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($doc | ConvertTo-Json -Compress -Depth 10))
    if ($bytes.Length -gt $queueMaximumBytes -or $Queue.Tickets.Count -gt $queueMaximumTickets) { $stream.Dispose(); throw 'heavy-verifier: verify queue over-capacity before publication' }
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    if ($CreateNew -or -not $Queue.Exists) { [IO.File]::Move($temporary, $queuePath) }
    else {
      Assert-VerifyQueueUnchanged $Queue
      Initialize-OwnerRename
      $destination = [ChaseSets.HeavyAdmission.OwnerRename]::OpenDestination($queuePath)
      try {
        Assert-VerifyQueueUnchanged $Queue
        [ChaseSets.HeavyAdmission.OwnerRename]::Publish($temporary, $queuePath, $destination)
      } finally { $destination.Dispose() }
    }
  } finally { if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue } }
}
function Assert-VerifyQueueUnchanged($Queue) {
  $current = Read-VerifyQueue
  if ($Queue.Exists -ne $current.Exists -or $Queue.Hash -cne $current.Hash -or $Queue.Identity -cne $current.Identity) { throw "heavy-verifier: verify queue changed during admission (path=$queuePath size=$($current.Bytes.Length) sha256=$($current.Hash) reason=replaced)" }
}
function Read-VerifyQueueBytes {
  $size = 'unknown'; $hash = 'unknown'
  try {
    Assert-QueuePathSafe $queuePath
    $identity = Get-QueueFileIdentity $queuePath
    $content = Read-QueueContent $queuePath; $bytes = $content.Bytes; $size = $content.Size; $hash = $content.Hash
    if ((Get-QueueFileIdentity $queuePath) -cne $identity) { throw 'replaced-file' }
    return [pscustomobject]@{ Bytes = $bytes; Size = $size; Hash = $hash; Identity = $identity; WrittenUtcTicks = (Get-Item -LiteralPath $queuePath -Force).LastWriteTimeUtc.Ticks }
  } catch { throw "heavy-verifier: verify queue invalid (path=$queuePath size=$size sha256=$hash reason=$($_.Exception.Message))" }
}
function Get-QueueTicketContext {
  if (-not $isQueueSlot) { return $null }
  if (Test-PathEntry $queueRecoveryPath) { throw "heavy-verifier: verify queue recovery marker present ($queueRecoveryPath)" }
  $claimant = Get-QueueClaimant
  $queue = Read-VerifyQueue
  $now = Get-QueueNow
  $retained = @($queue.Tickets | Where-Object { Test-QueueTicketRetained $_ $now })
  $changed = $retained.Count -ne $queue.Tickets.Count
  $queue.Tickets = $retained
  $ticket = $queue.Tickets | Where-Object {
    $_.claimantKey -ceq $claimant.Key -and
    $_.pid -eq $claimant.Pid -and
    $_.startIdentity -ceq $claimant.StartIdentity -and
    (-not $isControllerSlot -or $_.commandIdentity -ceq $claimant.CommandIdentity)
  } | Select-Object -First 1
  if ($ticket) { $ticket.presentedUtc = $now.ToString('o'); $changed = $true }
  else {
    if ($queue.Tickets.Count -ge $queueMaximumTickets) { throw "heavy-verifier: verify queue invalid (path=$queuePath size=$($queue.Bytes.Length) sha256=$($queue.Hash) reason=over-capacity)" }
    $ticketData = [ordered]@{
      number = $queue.NextTicket; claimantKey = $claimant.Key; pid = $claimant.Pid
      startIdentity = $claimant.StartIdentity; childPid = $claimant.ChildPid
      childStartIdentity = $claimant.ChildStartIdentity; presentedUtc = $now.ToString('o')
    }
    if ($isControllerSlot) { $ticketData.commandIdentity = $claimant.CommandIdentity }
    $ticket = [pscustomobject]$ticketData
    $queue.NextTicket++
    $queue.Tickets += $ticket; $changed = $true
  }
  if ($changed) { Assert-VerifyQueueUnchanged $queue; Write-VerifyQueue $queue; $queue = Read-VerifyQueue }
  $position = 1 + @($queue.Tickets | Where-Object number -LT $ticket.number).Count
  return [pscustomobject]@{ Queue = $queue; Ticket = $ticket; Position = $position; IsHead = $position -eq 1; Claimant = $claimant }
}
function Remove-QueueTicket($Context) {
  if ($queueFixture.failRemoval) { throw 'heavy-verifier: verify queue injected admission persistence failure' }
  $queue = Read-VerifyQueue
  $match = @($queue.Tickets | Where-Object number -eq $Context.Ticket.number)
  if ($match.Count -ne 1 -or $match[0].claimantKey -cne $Context.Ticket.claimantKey -or
      ($isControllerSlot -and $match[0].commandIdentity -cne $Context.Ticket.commandIdentity)) {
    throw "heavy-verifier: $queueLabel ticket changed (ticket=$($Context.Ticket.number))"
  }
  $queue.Tickets = @($queue.Tickets | Where-Object number -ne $Context.Ticket.number)
  Assert-VerifyQueueUnchanged $Context.Queue
  Write-VerifyQueue $queue
}
function Invoke-QueueQuarantine {
  if (-not $QuarantineQueue) { return }
  if (-not $isHostVerifier -or $isAttachedAdmission -or $callerBinding.Record -or $env:CHASE_SETS_HEAVY_SLOT_ID -or $env:CHASE_SETS_HEAVY_SLOT_TRANSPORT) { throw 'heavy-verifier: verify queue quarantine is host-only and unbound' }
  try {
    Assert-QueuePathSafe $queueRecoveryPath
    if (-not (Test-PathEntry $queueRecoveryPath)) {
      $queue = Read-VerifyQueueBytes
      if ($queue.Hash -cne $QuarantineQueue) { throw 'requested-hash-mismatch' }
      $invalid = $null
      try { $null = Read-VerifyQueue } catch { $invalid = $_.Exception.Message }
      if (-not $invalid) { throw 'queue-is-valid' }
      $now = Get-QueueNow
      $record = Join-Path $queueRecordRoot "$QuarantineQueue-$($now.UtcDateTime.ToString('yyyyMMddTHHmmssfffffffZ'))"
      $marker = [ordered]@{ schemaVersion = 1; path = $queuePath; identity = $queue.Identity; writtenUtcTicks = $queue.WrittenUtcTicks; size = $queue.Size; sha256 = $queue.Hash; reason = $invalid; wrapperUtc = $now.ToString('o'); record = $record }
      Write-QueueEvidence $queueRecoveryPath ($marker | ConvertTo-Json -Compress)
      throw "pending ($queueRecoveryPath)"
    }
    $marker = Read-NativeJson ([IO.File]::ReadAllText($queueRecoveryPath)) 8192
    Assert-NativeObject $marker @('schemaVersion','path','identity','writtenUtcTicks','size','sha256','reason','wrapperUtc','record')
    if ($marker.schemaVersion -ne 1 -or $marker.sha256 -cne $QuarantineQueue -or $marker.path -cne $queuePath -or
        (Split-Path -Parent $marker.record) -cne $queueRecordRoot -or
        (Split-Path -Leaf $marker.record) -cnotmatch "^$QuarantineQueue-[0-9]{8}T[0-9]{13}Z$" -or
        -not (Test-UtcIdentity $marker.wrapperUtc)) { throw 'marker-authority-mismatch' }
    if (((Get-QueueNow) - [DateTimeOffset]::Parse($marker.wrapperUtc)).TotalSeconds -le $queueRetentionSeconds) { throw 'pending: quiescent-boundary' }
    $record = [string]$marker.record
    if (Test-PathEntry $queueRecordRoot) { if (-not (Test-SafeDirectory $queueRecordRoot)) { throw 'unsafe-record-root' } }
    else { [void][IO.Directory]::CreateDirectory($queueRecordRoot) }
    if (Test-PathEntry $record) { if (-not (Test-SafeDirectory $record)) { throw 'unsafe-record' } }
    else { [void][IO.Directory]::CreateDirectory($record) }
    $recordQueue = Join-Path $record 'verify-queue.json'
    if (-not (Test-PathEntry $recordQueue)) {
      Invoke-QueueFixtureBarrier 'beforeMove'
      $queue = Read-VerifyQueueBytes
      if ($queue.Identity -cne $marker.identity -or $queue.Hash -cne $marker.sha256 -or $queue.Size -ne $marker.size -or $queue.WrittenUtcTicks -ne $marker.writtenUtcTicks) { throw 'source-changed' }
      # The marker forbids presentations for >R. A future-dated presentation
      # cannot be proved stale and therefore cannot be reset.
      try { $untrusted = Read-NativeJson ([Text.Encoding]::UTF8.GetString($queue.Bytes)) $queueMaximumBytes } catch { $untrusted = $null }
      foreach ($ticket in @($untrusted.tickets)) {
        if ($ticket -and (-not (Test-UtcIdentity $ticket.presentedUtc) -or
            ((Get-QueueNow) - [DateTimeOffset]::Parse($ticket.presentedUtc)).TotalSeconds -le $queueRetentionSeconds)) { throw 'possible-live-ticket' }
      }
      [IO.File]::Move($queuePath, $recordQueue)
    }
    Assert-QueuePathSafe $recordQueue
    $moved = Read-QueueContent $recordQueue
    if ((Get-QueueFileIdentity $recordQueue) -cne $marker.identity -or $moved.Size -ne $marker.size -or (Get-Item -LiteralPath $recordQueue -Force).LastWriteTimeUtc.Ticks -ne $marker.writtenUtcTicks -or $moved.Hash -cne $marker.sha256) { throw 'record-readback-mismatch' }
    Stop-QueueRecoveryFixture 'moved'
    $proofPath = Join-Path $record 'empty-proof.json'
    $stage = Join-Path $record 'empty.queue'
    if (-not (Test-PathEntry $proofPath)) {
      if (Test-PathEntry $queuePath) { throw 'unexpected-queue-after-rename' }
      if (-not (Test-PathEntry $stage)) {
        Write-QueueEvidence $stage '{}'
        $empty = @{schemaVersion=1;fileIdentity=(Get-QueueFileIdentity $stage);nextTicket=1;tickets=@()}
        # This stage is private evidence, not the published queue or marker.
        $stream = [IO.File]::Open($stage,[IO.FileMode]::Truncate,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try { $bytes=[Text.Encoding]::UTF8.GetBytes(($empty|ConvertTo-Json -Compress)); $stream.Write($bytes); $stream.Flush($true) } finally { $stream.Dispose() }
      }
      Assert-QueuePathSafe $stage
      $stagedEmpty = Read-NativeJson ([IO.File]::ReadAllText($stage)) 8192
      Assert-NativeObject $stagedEmpty @('schemaVersion','fileIdentity','nextTicket','tickets')
      if ($stagedEmpty.schemaVersion -ne 1 -or $stagedEmpty.nextTicket -ne 1 -or $stagedEmpty.tickets -isnot [array] -or
          $stagedEmpty.tickets.Count -ne 0 -or $stagedEmpty.fileIdentity -cne (Get-QueueFileIdentity $stage)) { throw 'empty-stage-invalid' }
      $raw = [IO.File]::ReadAllText($stage)
      Write-QueueEvidence $proofPath $raw
    }
    Assert-QueuePathSafe $proofPath
    $proof = [IO.File]::ReadAllBytes($proofPath)
    Stop-QueueRecoveryFixture 'prepared'
    if (-not (Test-PathEntry $queuePath)) {
      Assert-QueuePathSafe $stage
      if ((Get-QueueSha256 ([IO.File]::ReadAllBytes($stage))) -cne (Get-QueueSha256 $proof)) { throw 'empty-stage-readback-mismatch' }
      [IO.File]::Move($stage, $queuePath)
    }
    Stop-QueueRecoveryFixture 'published'
    $emptyQueue = Read-VerifyQueue
    if ($emptyQueue.Hash -cne (Get-QueueSha256 $proof) -or $emptyQueue.Tickets.Count -ne 0 -or $emptyQueue.NextTicket -ne 1) { throw 'empty-queue-readback-mismatch' }
    Stop-QueueRecoveryFixture 'readback'
    [IO.File]::Delete($queueRecoveryPath)
    Write-Output "heavy-verifier: verify queue recovery completed (record=$record)"
    $script:quarantineCompleted = $true
  } catch { throw "heavy-verifier: verify queue recovery refused: $($_.Exception.Message)" }
}
function Write-QueueEvidence([string]$Path,[string]$Raw) {
  Assert-QueuePathSafe $Path
  $stream = [IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
  try { $bytes=[Text.Encoding]::UTF8.GetBytes($Raw); $stream.Write($bytes); $stream.Flush($true) } finally { $stream.Dispose() }
}
function Stop-QueueRecoveryFixture([string]$Step) {
  if ($queueFixture.stop -ceq $Step) { throw "fixture-stop:$Step" }
}
function Invoke-QueueFixtureBarrier([string]$Step) {
  if ($queueFixture.barrier -ceq $Step) {
    [IO.File]::WriteAllText(($TestQueueFixture + '.ready'),$Step)
    $deadline=[DateTime]::UtcNow.AddSeconds(30)
    while (-not [IO.File]::Exists($TestQueueFixture + '.continue')) {
      if ([DateTime]::UtcNow -gt $deadline) { throw 'fixture-barrier-timeout' }
      Start-Sleep -Milliseconds 20
    }
  }
}
function Test-ReclaimableOwner($Record) {
  if (-not (Test-OwnerShape $Record) -or $Record.schemaVersion -notin @(2, 3, 4, 5, 6)) { return $false }
  if ((Get-ProcessIdentityState $Record.pid ([string]$Record.processStartUtc)) -cne "dead") { return $false }
  if ($Record.state -in @("started", "attached")) {
    $childState = Get-ProcessIdentityState $Record.childPid ([string]$Record.childProcessStartUtc)
    if ($Record.schemaVersion -eq 6 -and $childState -cne 'dead') { return $false }
    if ($childState -cnotin @("dead", "reused")) { return $false }
  }
  if ((Test-PossibleOwnedChild $Record) -ne $false) { return $false }
  if ($Record.schemaVersion -eq 6) { return $null -ne $Record.native.linux }
  return $true
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
function Initialize-OwnerRename {
  if ('ChaseSets.HeavyAdmission.OwnerRename' -as [type]) { return }
  Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
namespace ChaseSets.HeavyAdmission {
  public static class OwnerRename {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security,
      uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetFileInformationByHandle(SafeFileHandle file, int kind, IntPtr data, uint size);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetFileInformationByHandleEx(SafeFileHandle file, int kind, out StandardInfo info, uint size);
    [StructLayout(LayoutKind.Sequential)]
    struct StandardInfo {
      public long AllocationSize, EndOfFile;
      public uint NumberOfLinks;
      public byte DeletePending, Directory;
    }
    static SafeFileHandle Open(string path, uint access) {
      SafeFileHandle file = CreateFileW(path, access, 7, IntPtr.Zero, 3, 0x00200000, IntPtr.Zero);
      if (file.IsInvalid) { int error = Marshal.GetLastWin32Error(); file.Dispose(); throw new Win32Exception(error); }
      return file;
    }
    public static SafeFileHandle OpenDestination(string path) { return Open(path, 0x80); }
    public static void Publish(string transitionPath, string ownerPath, SafeFileHandle destination) {
      using (SafeFileHandle transition = Open(transitionPath, 0x00010080)) {
        byte[] name = Encoding.Unicode.GetBytes(Path.GetFullPath(ownerPath));
        int rootOffset = IntPtr.Size == 8 ? 8 : 4;
        int lengthOffset = rootOffset + IntPtr.Size;
        int nameOffset = lengthOffset + 4;
        IntPtr buffer = Marshal.AllocHGlobal(nameOffset + name.Length + 2);
        try {
          for (int i = 0; i < nameOffset; i++) Marshal.WriteByte(buffer, i, 0);
          Marshal.WriteInt32(buffer, 0, 3); // REPLACE_IF_EXISTS | POSIX_SEMANTICS
          Marshal.WriteInt32(buffer, lengthOffset, name.Length);
          Marshal.Copy(name, 0, IntPtr.Add(buffer, nameOffset), name.Length);
          Marshal.WriteInt16(buffer, nameOffset + name.Length, 0);
          if (!SetFileInformationByHandle(transition, 22, buffer, (uint)(nameOffset + name.Length + 2)))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        } finally { Marshal.FreeHGlobal(buffer); }
        StandardInfo replaced;
        bool inspected = GetFileInformationByHandleEx(destination, 1, out replaced, (uint)Marshal.SizeOf<StandardInfo>());
        int inspectionError = inspected ? 0 : Marshal.GetLastWin32Error();
        if (!inspected || replaced.NumberOfLinks != 0) {
          // The destination was moved away, not replaced. Undo only our own
          // publication by its still-held handle, never by the owner name.
          IntPtr disposition = Marshal.AllocHGlobal(4);
          try {
            Marshal.WriteInt32(disposition, 3); // DELETE | POSIX_SEMANTICS
            if (!SetFileInformationByHandle(transition, 21, disposition, 4))
              throw new Win32Exception(Marshal.GetLastWin32Error());
          } finally { Marshal.FreeHGlobal(disposition); }
          if (!inspected) throw new Win32Exception(inspectionError);
          throw new IOException("heavy-verifier: owner destination was not replaced");
        }
      }
    }
  }
}
'@ -ErrorAction Stop
}
function Write-OwnerRecord($Record, [switch]$CreateNew) {
  $raw = if ($Record.schemaVersion -eq 6) { $Record | ConvertTo-Json -Compress -Depth 16 } else { $Record | ConvertTo-Json -Compress }
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
    $destination = [ChaseSets.HeavyAdmission.OwnerRename]::OpenDestination($ownerPath)
    try {
      [ChaseSets.HeavyAdmission.OwnerRename]::Publish($temporaryPath, $ownerPath, $destination)
    } finally { $destination.Dispose() }
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
    $share = [IO.FileShare]::Delete
    $nativeOwner = ($ExpectedRaw | ConvertFrom-Json -DateKind String -ErrorAction Stop).schemaVersion -eq 6
    if ($nativeOwner) { $share = $share -bor [IO.FileShare]::Read }
    try {
      $stream = [IO.File]::Open($ClaimPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    } catch [IO.IOException] {
      if (($_.Exception.GetBaseException().HResult -band 0xffff) -eq 32) { return $false }
      throw
    }
    try {
      $encoding = if ($nativeOwner) { [Text.UTF8Encoding]::new($false, $true) } else { [Text.Encoding]::UTF8 }
      $reader = [IO.StreamReader]::new($stream, $encoding, (-not $nativeOwner), 1024, $true)
      try { $raw = $reader.ReadToEnd() } finally { $reader.Dispose() }
      if ($raw -cne $ExpectedRaw) { return $false }
      try { $record = $raw | ConvertFrom-Json -DateKind String -ErrorAction Stop } catch { return $false }
      if ($RequireDead -and -not (Test-ReclaimableOwner $record)) { return $false }
      if($RequireDead-and$record.schemaVersion-eq5-and-not(Remove-ExactOwnedAdmissionRoot $record)){return $false}
      if ($record.schemaVersion -eq 6) {
        if (-not $RequireDead -and -not (Test-NativeNormalRelease $record)) { return $false }
        if (-not (Complete-NativeReconciliation $record)) { return $false }
        if ($RequireDead) {
          if (-not (Test-ReclaimableOwner $record)) { return $false }
        } elseif (-not (Test-NativeNormalRelease $record)) { return $false }
        $afterReconciliation = Get-OwnerSnapshot $ClaimPath
        if ($null -eq $afterReconciliation -or $afterReconciliation.Raw -cne $ExpectedRaw) { return $false }
      }
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
function Assert-LiveGitIdentityUnchanged([switch]$AfterExecution) {
  $live = Get-LiveGitIdentity
  if (-not [string]::Equals($live.Worktree, $acquiredGitIdentity.Worktree, [StringComparison]::OrdinalIgnoreCase) -or
      $live.Head -cne $acquiredGitIdentity.Head -or
      $live.Branch -cne $acquiredGitIdentity.Branch) {
    if ($AfterExecution) { throw "heavy-verifier: receipt refused because live Git branch or HEAD changed during verification" }
    throw "heavy-verifier: live Git branch or HEAD changed after acquisition; command body was not executed"
  }
  if ($isControllerPrecursor) {
    Assert-ControllerPrecursorGitState
    Assert-ControllerPrecursorArtifactState
  }
  if ($isControllerFixture) { Assert-ControllerFixtureGitState }
  if ($isControllerHostHeavyVerifier) { Assert-ControllerHostHeavyGitState }
}
function Test-ThisOwner {
  $snapshot = Get-OwnerSnapshot
  return $null -ne $snapshot -and
    $snapshot.Raw -ceq $ownedRaw -and
    (Test-OwnerShape $snapshot.Record) -and
    (Get-ProcessIdentityState $snapshot.Record.pid ([string]$snapshot.Record.processStartUtc)) -ceq "live"
}
function Release-ThisLock {
  if (-not (Test-ThisOwner)) {
    if ($owner.schemaVersion -eq 6) { return $false }
    return -not (Test-Path -LiteralPath $lockPath)
  }
  $claimPath = Join-Path $lockPath ("owner.cleanup." + $lockId + ".json")
  try {
    [IO.File]::Move($ownerPath, $claimPath)
  } catch {
    return $false
  }
  return Remove-ClaimedOwnerLock $claimPath $ownedRaw
}

function New-NativeStart([string]$Mode, [string]$Root) {
  if ($Mode -cnotin @('launch','reconcile')) { throw 'native-db: unsupported helper action' }
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = 'C:\Windows\System32\wsl.exe'
  $start.UseShellExecute = $false; $start.CreateNoWindow = $true
  $start.RedirectStandardInput = $true; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
  $start.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
  $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false, $true)
  $start.Environment.Clear()
  foreach ($key in @('SystemRoot','WINDIR','SystemDrive')) {
    $value = [Environment]::GetEnvironmentVariable($key)
    if ($value) { $start.Environment[$key] = $value }
  }
  $start.Environment['WSLENV'] = ''
  foreach ($argument in @('-d','Ubuntu','--exec','/usr/bin/env','-i','PATH=/usr/bin:/bin',"HOME=$Root",'LANG=C',
      '/usr/bin/python3','/opt/chase-sets-native-db/admission.py',$Mode,$Root)) { $start.ArgumentList.Add($argument) }
  return $start
}
function Read-NativeLine($Process) {
  $line = $Process.StandardOutput.ReadLineAsync()
  if (-not $line.Wait(30000)) { throw 'native-db: helper control reply expired; retain owner' }
  $raw = $line.GetAwaiter().GetResult()
  if ($null -eq $raw) { throw 'native-db: helper EOF; retain owner' }
  return Read-NativeJson $raw 8192
}
function Test-NativeNormalRelease($Record) {
  return (Test-OwnerShape $Record) -and $Record.state -ceq 'started' -and
    (Get-ProcessIdentityState $Record.pid $Record.processStartUtc) -ceq 'live' -and
    (Get-ProcessIdentityState $Record.childPid $Record.childProcessStartUtc) -ceq 'dead' -and
    (Test-PossibleOwnedChild $Record -GuardedRootOnly) -eq $false -and $null -ne $Record.native.linux
}
function Complete-NativeReconciliation($Record) {
  if (-not (Test-OwnerShape $Record) -or $null -eq $Record.native.linux) { return $false }
  $reconciler = $null
  $reconcilerStartTicks = 0
  try {
    $reconciler = [Diagnostics.Process]::Start((New-NativeStart 'reconcile' $Record.native.root))
    [void]$reconciler.Handle
    $reconcilerStartTicks = $reconciler.StartTime.ToUniversalTime().Ticks
    $errors = $reconciler.StandardError.ReadToEndAsync()
    $reconciler.StandardInput.WriteLine((@{ linux = $Record.native.linux } | ConvertTo-Json -Compress -Depth 8))
    $reconciler.StandardInput.Close()
    $proof = Read-NativeLine $reconciler
    Assert-NativeObject $proof @('linux','root','initAbsent','rootAbsent')
    Assert-NativeText $proof.root 1024
    if (-not (Test-NativeTuple $proof.linux) -or $proof.root -cne $Record.native.root -or
        $proof.initAbsent -isnot [bool] -or -not $proof.initAbsent -or
        $proof.rootAbsent -isnot [bool] -or -not $proof.rootAbsent) { return $false }
    foreach ($key in @('bootId','outerPid','startTicks','inode')) {
      if ($proof.linux.$key -cne $Record.native.linux.$key) { return $false }
    }
    if (-not $reconciler.WaitForExit(30000) -or $reconciler.ExitCode -ne 0) { return $false }
    if ($reconciler.StandardOutput.ReadToEnd()) { return $false }
    if ($isNativeDb -and $Record.lockId -ceq $lockId) { $script:nativeCleanupProof = $proof }
    return $true
  } catch {
    [Console]::Error.WriteLine("native-db: independent cleanup unknown: $($_.Exception.Message)")
    return $false
  } finally {
    if ($reconciler) {
      if (-not $reconciler.HasExited) { Stop-ExactVerifierProcess $reconciler.Id $reconcilerStartTicks; [void]$reconciler.WaitForExit(30000) }
      $reconciler.Dispose()
    }
  }
}
function Invoke-NativeLaunch {
  $callerBinding = Invoke-HeavyAdmissionCensus { Assert-HeavyCallerEligibility $callerBinding }
  if (Test-Path -LiteralPath $nativeEvidencePath) { throw 'native-db: correlation already consumed' }
  $evidenceStream = [IO.File]::Open($nativeEvidencePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
  try {
    $script:child = [Diagnostics.Process]::Start((New-NativeStart 'launch' $owner.native.root))
    try {
      [void]$child.Handle
      $nativeChildStart = $child.StartTime.ToUniversalTime()
      $script:childStartTicks = $nativeChildStart.Ticks
    } catch {
      # Refuse launch on capture failure. Only the pinned launch object can
      # supply a fallback identity, which the stop helper independently checks.
      try { Stop-ExactVerifierProcess $child.Id $child.StartTime.ToUniversalTime().Ticks }
      catch { [Console]::Error.WriteLine("native-db: helper identity unavailable; termination refused pid=$($child.Id)") }
      throw
    }
    $script:nativeErrors = $child.StandardError.ReadToEndAsync()
    $owner.state = 'started'; $owner.childPid = $child.Id
    $owner.childProcessStartUtc = $nativeChildStart.ToString('o')
    if (-not (Test-ThisOwner)) { throw 'native-db: owner changed before Windows child publication' }
    $script:ownedRaw = Write-OwnerRecord $owner
    $envelope = @{ request = $nativeRequestRaw; digest = $owner.native.request.digest } | ConvertTo-Json -Compress -Depth 4
    $child.StandardInput.WriteLine($envelope); $child.StandardInput.Flush()
    $publication = Read-NativeLine $child
    Assert-NativeObject $publication @('linux')
    if (-not (Test-NativeTuple $publication.linux) -or -not (Test-ThisOwner)) { throw 'native-db: tuple or owner publication refused' }
    $owner.native.linux = $publication.linux
    $script:ownedRaw = Write-OwnerRecord $owner
    if (-not (Test-ThisOwner)) { throw 'native-db: published tuple no longer owned' }
    $callerBinding = Invoke-HeavyAdmissionCensus { Assert-HeavyCallerEligibility $callerBinding }
    $child.StandardInput.WriteLine(($publication | ConvertTo-Json -Compress -Depth 8))
    $child.StandardInput.Close()
    # The fixed runner owns its ordinary execution duration. Only control
    # handshakes expire here; no request can widen a product timeout.
    $resultLine = $child.StandardOutput.ReadLineAsync()
    while (-not $resultLine.Wait(1000)) { if (-not (Test-ThisOwner)) { throw 'native-db: owner lost during payload' } }
    $result = Read-NativeJson $resultLine.GetAwaiter().GetResult() 8192
    Assert-NativeObject $result @('status','exit','diagnostic')
    Assert-NativeText $result.status 128
    if ($result.status -cnotin @('completed','refused')) { throw 'native-db: unknown payload lifecycle' }
    if ($result.status -ceq 'completed') {
      if (($result.exit -isnot [int] -and $result.exit -isnot [long]) -or $result.exit -lt -2147483648 -or $result.exit -gt 2147483647 -or $null -ne $result.diagnostic) { throw 'native-db: invalid completion' }
    } else {
      if ($null -ne $result.exit) { throw 'native-db: invalid refusal' }
      Assert-NativeText $result.diagnostic 2048
    }
    if (-not $child.WaitForExit(30000) -or $child.ExitCode -ne 0 -or $child.StandardOutput.ReadToEnd()) { throw 'native-db: helper exit unknown' }
    Assert-LiveGitIdentityUnchanged -AfterExecution
    Assert-HostVerifierGitState
    $evidence = @{ requestDigest = $owner.native.request.digest; owner = $owner; result = $result }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($evidence | ConvertTo-Json -Depth 16))
    $evidenceStream.Write($bytes); $evidenceStream.Flush($true)
    $script:nativeResult = $result
    $script:exitCode = if ($result.status -ceq 'refused') { 73 } elseif ($result.exit -eq 0) { 0 } else { 1 }
  } finally { $evidenceStream.Dispose() }
}

# Nested continuation authority (issue #7941). On Windows, a Gate or Attach
# owner runs one private named-pipe server on a .NET thread inside this exact
# wrapper process (heavy-nested-owner.cs). Descendants of the guarded root
# continue under this admission through a fresh signed exchange instead of a
# per-child PowerShell host probe. Controller batteries and precursors keep
# their own continuation on the controller slot and never publish a product
# descriptor. Non-Windows hosts are unchanged.
$nestedOwnerEligible = $IsWindows -and -not $isControllerBattery -and -not $isControllerPrecursor -and -not $isControllerFixture -and -not $isControllerHostHeavyVerifier -and -not $isNativeDb -and -not $isDiagnostic
$nestedOwner = $null
$nestedBinding = $null
$script:nestedTransport = $null
$nestedInitialization = [ordered]@{ compileMs = $null; reserveMs = $null; bindMs = $null; armMs = $null }
$nestedOwnerSource = Join-Path $PSScriptRoot "heavy-nested-owner.cs"
$nestedClientSource = Join-Path $PSScriptRoot "heavy-nested-client.cjs"
$dispatchOwnershipSource = Join-Path $PSScriptRoot "dispatch-ownership.ps1"
if ($nestedOwnerEligible) {
  foreach ($required in @($nestedOwnerSource, $nestedClientSource, $dispatchOwnershipSource)) {
    if (-not (Test-SafeFile $required)) {
      throw "heavy-verifier: nested continuation runtime is absent or unsafe: $required"
    }
  }
  # The existing dispatch ownership reader is consulted read-only at admission.
  . $dispatchOwnershipSource
}

# Gate/kind map frozen from the installed product manifest and classifier
# closure at product head 574dd01be84bcee5efb11c2f6730d5cbe03d2c8a (derivation
# recorded in the #7941 report). A named gate admits only the transitive
# classified kinds its manifest scripts reach, including its own pnpm root
# claim; an attached root admits its own kind plus the kinds its classified
# shape spawns. Registered E2E roots at product head 2e1328168ad7bd06c0fa96f3769aca37405372dd
# use playwright: run-e2e-suite -> test:chromium -> build + playwright.
# Their existing explicit script-battery caller remains a nested claim only.
# Everything else is a crossed claim and is refused.
$nestedKindClosure = [ordered]@{
  "test:scripts" = @("script-battery", "vitest-full")
  "build" = @("build")
  "verify:build" = @("build")
  "verify:static" = @("repository-gate", "script-battery", "vitest-full")
  "check:static" = @("repository-gate", "script-battery", "vitest-full")
  "verify:test" = @("repository-gate", "script-battery", "vitest-full")
  "test:fast" = @("repository-gate", "script-battery", "vitest-full")
  "test" = @("repository-gate", "script-battery", "vitest-full")
  "verify:test-db" = @("repository-gate", "script-battery", "vitest-full")
  "verify" = @("repository-gate", "script-battery", "vitest-full", "build")
  "repository-gate" = @("repository-gate", "script-battery", "vitest-full", "build")
  "script-battery" = @("script-battery", "vitest-full")
  "vitest-full" = @("vitest-full", "script-battery")
  "playwright" = @("playwright", "script-battery", "build")
  "test:e2e:suite" = @("playwright", "script-battery", "build")
  "diagnostic" = @("diagnostic")
}
function Get-NestedAllowedKinds([string]$RootGate) {
  if (-not $nestedKindClosure.Contains($RootGate)) { throw "heavy-verifier: no frozen nested kind closure for gate $RootGate" }
  return [string[]]@($nestedKindClosure[$RootGate])
}
function Initialize-NestedOwner {
  if (-not $nestedOwnerEligible) { return }
  $watch = [Diagnostics.Stopwatch]::StartNew()
  Add-Type -Path $nestedOwnerSource -ReferencedAssemblies @(
    "System.IO.Pipes", "System.IO.FileSystem", "System.Security.AccessControl",
    "System.Security.Principal.Windows", "System.Security.Claims", "System.Security.Cryptography",
    "System.Text.Json", "System.Text.RegularExpressions", "System.Runtime.InteropServices",
    "System.Threading", "System.Threading.Thread", "System.Collections", "System.Memory",
    "System.Text.Encoding.Extensions", "System.Diagnostics.Process"
  ) -ErrorAction Stop
  $nestedInitialization.compileMs = $watch.ElapsedMilliseconds
  $watch.Restart()
  $script:nestedOwner = [ChaseSets.HeavyAdmission.NestedOwnerServer]::Reserve($lockId)
  $nestedInitialization.reserveMs = $watch.ElapsedMilliseconds
}
function New-NestedTransportDescriptor {
  $descriptor = [ordered]@{ schemaVersion = 1; lockId = $lockId; publicKey = $nestedOwner.PublicKey; launchId = $null; laneRole = $null }
  if ($isHostVerifier -and -not $callerBinding.Record) { $descriptor.schemaVersion = 2; $descriptor.authority = "host-verifier"; $descriptor.commandIdentity = $commandIdentity }
  if ($nestedBinding.Record) {
    $descriptor.launchId = [string]$nestedBinding.Record.launchId
    $descriptor.laneRole = [string]$nestedBinding.Record.laneRole
  }
  return [Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes(($descriptor | ConvertTo-Json -Compress -Depth 4)))
}
function Start-NestedOwner([string]$OwnerRawCurrent, [int]$RootPid, [string]$RootStartUtc, [string]$State, $Binding) {
  $watch = [Diagnostics.Stopwatch]::StartNew()
  $bound = [ChaseSets.HeavyAdmission.NestedOwnerBinding]::new()
  $bound.OwnerRaw = $OwnerRawCurrent
  $bound.LockDirectory = $lockPath
  $bound.LockId = $lockId
  $bound.OwnerIdentity = [string]$owner.owner
  $bound.Gate = $ownerGate
  $bound.State = $State
  $bound.CommandIdentity = $commandIdentity
  $bound.AllowedKinds = Get-NestedAllowedKinds $ownerGate
  $bound.WrapperPid = $PID
  $bound.WrapperStartUtc = $started
  $bound.RootPid = $RootPid
  $bound.RootStartUtc = $RootStartUtc
  $bound.Lane = $Lane
  $bound.Worktree = $acquiredGitIdentity.Worktree
  # PowerShell coerces $null to "" when assigning a C# string field. Keep the
  # new binding's CLR null for detached HEAD; the closed protocol requires null.
  if ($identityMode -ceq "branch") { $bound.Branch = $acquiredGitIdentity.Branch }
  $bound.Head = $acquiredGitIdentity.Head
  $bound.IdentityMode = $identityMode
  $bound.HostVerifier = $isHostVerifier -and -not $callerBinding.Record
  if ($Binding.Record) {
    $bound.DispatchRecordPath = $Binding.Path
    $bound.DispatchRecordRaw = $Binding.Raw
    $bound.LaunchId = [string]$Binding.Record.launchId
    $bound.LaneRole = [string]$Binding.Record.laneRole
    $bound.DispatchLauncherPid = [int]$Binding.Record.launcherPid
    $bound.DispatchLauncherStartUtc = [string]$Binding.Record.launcherStartIdentity
    $bound.DispatchChildPid = [int]$Binding.Record.childPid
    $bound.DispatchChildStartUtc = [string]$Binding.Record.childStartIdentity
  }
  $nestedOwner.Arm($bound)
  $nestedInitialization.armMs = $watch.ElapsedMilliseconds
}
function Format-NestedFailure($Failure, $Connections) {
  if ($null -eq $Failure) { return 'failure=none' }
  # This is a diagnostic boundary, not an exception formatter. Reject unknown
  # shapes rather than interpolating any native/request-derived string.
  try {
    $fields = @('Connection', 'Head', 'ExceptionClass', 'Category', 'Phase',
      'ExchangeCancellationRequested', 'OwnerShutdownRequested')
    $names = @($Failure.PSObject.Properties.Name)
    $valid = $names.Count -eq $fields.Count
    foreach ($name in $names) { if ($name -cnotin $fields) { $valid = $false } }
    foreach ($name in $fields) { if ($name -cnotin $names) { $valid = $false } }
    $valid = $valid -and $Failure.Connection -is [long] -and $Failure.Connection -gt 0 -and $Failure.Connection -le $Connections -and
      $Failure.Head -is [string] -and $Failure.Head.Length -eq 40 -and $Failure.Head -cmatch '^[a-f0-9]{40}$' -and
      $Failure.ExceptionClass -is [string] -and $Failure.ExceptionClass -cin @('none', 'unknown', 'OperationCanceledException',
        'TaskCanceledException', 'IOException', 'ObjectDisposedException', 'UnauthorizedAccessException', 'InvalidOperationException', 'JsonException') -and
      $Failure.Category -is [string] -and $Failure.Category -cin @('unknown', 'cancellation', 'peer-disconnect', 'io', 'disposed',
        'access', 'invalid-operation', 'json', 'protocol-refusal', 'authority-refusal') -and
      $Failure.Phase -is [string] -and $Failure.Phase -cin @('unknown', 'request-read', 'request-parse', 'authority', 'reply-write', 'reply-flush', 'reply-drain') -and
      $Failure.ExchangeCancellationRequested -is [bool] -and $Failure.OwnerShutdownRequested -is [bool]
    if (-not $valid) { return 'failure=unavailable' }
    $safe = [ordered]@{}
    foreach ($name in $fields) { $safe[$name] = $Failure.$name }
    return 'failure=' + ($safe | ConvertTo-Json -Compress)
  } catch { return 'failure=unavailable' }
}
function Stop-NestedOwner {
  if ($null -eq $nestedOwner) { return }
  $statistics = $null
  try { $nestedOwner.Stop() } catch {}
  try { $statistics = $nestedOwner.Statistics() } catch {}
  $bindingSummary = if ($isHostVerifier -and -not $callerBinding.Record) { "host-verifier command=$commandIdentity" } elseif ($nestedBinding -and $nestedBinding.Record) {
    "launch=$($nestedBinding.Record.launchId) role=$($nestedBinding.Record.laneRole)"
  } else {
    "unbound($(if ($nestedBinding) { $nestedBinding.Reason } else { 'not-resolved' }))"
  }
  $served = if ($statistics) { "served=$($statistics.Served) refused=$($statistics.Refused) connections=$($statistics.Connections) lastServiceMs=$([Math]::Round($statistics.LastServiceMs, 1)) totalServiceMs=$([Math]::Round($statistics.TotalServiceMs, 1))" } else { "statistics=unavailable" }
  $failure = if ($statistics) { Format-NestedFailure $statistics.LastFailure $statistics.Connections } else { 'failure=unavailable' }
  [Console]::Error.WriteLine("heavy-verifier: nested-owner pipe=$($nestedOwner.PipeName) compileMs=$($nestedInitialization.compileMs) reserveMs=$($nestedInitialization.reserveMs) bindMs=$($nestedInitialization.bindMs) armMs=$($nestedInitialization.armMs) binding=$bindingSummary $served $failure")
}


# Platform Gate/Attach keep the container-only coordination key. Controller
# batteries and precursors coordinate on their own key, so a platform
# acquisition or stale-owner reclamation never delays them (Todd ruling
# 2026-09-10, review r3 F3).
$coordinationKey = $container.ToUpperInvariant()
if ($isControllerBattery -or $isControllerPrecursor -or $isControllerFixture -or $isControllerHostHeavyVerifier) { $coordinationKey += "`n" + $lockDirectoryName }
$mutexHash = [Convert]::ToHexString(
  [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($coordinationKey))
).ToLowerInvariant()
if (-not $isAttachedAdmission) { Initialize-OwnerRename }
$coordinationMutex = [Threading.Mutex]::new($false, "Global\chase-sets-heavy-verifier-$mutexHash")
$mutexHeld = $false
Invoke-HeavyAdmissionCensus {
  try {
    try {
    $remaining = $script:heavyAdmissionBudget.deadline - $script:heavyAdmissionBudget.watch.ElapsedMilliseconds
    Assert-HeavyAdmissionTime
    $mutexHeld = $coordinationMutex.WaitOne([int][Math]::Max(0, $remaining))
    if (-not $mutexHeld) { throw 'heavy-verifier: caller eligibility: admission deadline' }
    } catch [Threading.AbandonedMutexException] {
      $mutexHeld = $true
    }
    $callerBinding = Invoke-HeavyAdmissionCensus { Assert-HeavyCallerEligibility $callerBinding }
    if ($isProductSlot -and ($env:CHASE_SETS_HEAVY_SLOT_ID -or $env:CHASE_SETS_HEAVY_SLOT_TRANSPORT)) {
      throw 'heavy-verifier: caller eligibility: inherited heavy token must use nested continuation'
    }
    if ($QuarantineQueue) {
      Invoke-QueueQuarantine
    }
    if ($script:quarantineCompleted) { $script:heavyAdmissionQuitAfterQuarantine = $true; return }
    $queueContext = $null
    if ($isQueueSlot) { # admission queue gate
      $queueContext = Get-QueueTicketContext
      if (-not $queueContext.IsHead) {
        $reserved = -not (Test-Path -LiteralPath $lockPath)
        throw "heavy-verifier: queued; ticket=$($queueContext.Ticket.number) position=$($queueContext.Position) reserved=$($reserved); retry within $queueRetentionSeconds seconds"
      }
    }
    $queueLockCreated = $false
    Assert-HeavyAdmissionTime
    try {
      New-Item -ItemType Directory -Path $lockPath -ErrorAction Stop | Out-Null
      $queueLockCreated = $true
    } catch {
      Assert-HeavyAdmissionTime
      if (-not (Invoke-StaleLockReclamation)) { Describe-ExistingLock }
      Assert-HeavyAdmissionTime
      try {
        New-Item -ItemType Directory -Path $lockPath -ErrorAction Stop | Out-Null
        $queueLockCreated = $true
      } catch {
        Describe-ExistingLock
      }
    }
    Assert-HeavyAdmissionAfterLock $queueLockCreated
    if ($queueContext) {
      try { Remove-QueueTicket $queueContext }
      catch {
        if ($queueLockCreated -and (Test-SafeDirectory $lockPath) -and -not (Test-Path -LiteralPath $ownerPath)) {
          Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
        }
        throw "heavy-verifier: unable to persist queue admission; owner was released: $($_.Exception.Message)"
      }
    }
  } finally {
    if ($mutexHeld) { $coordinationMutex.ReleaseMutex() }
    $coordinationMutex.Dispose()
  }
}
if ($script:heavyAdmissionQuitAfterQuarantine) { return }

$exitCode = 1
$releaseMismatch = $false
$child = $null
$childStartTicks = 0
$diagnosticObservedDescendants = @()
$script:diagnosticObservedDescendantStarts = [hashtable]::new()
$childStarted = $null
$childEnded = $null
$childElapsedMs = $null
$childTimedOut = $false
$childResources = $null
$diagnosticJobResources = $null
$diagnosticModuleManifestPath = $null
$diagnosticModules = @()
$diagnosticResultSha256 = $null
$receiptPath = $null
$diagnosticSourceStream = $null
$diagnosticJobHandle = [IntPtr]::Zero
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
  Assert-HostVerifierGitState
  # The reserved nested-owner pipe exists before accepted publication (Attach)
  # and before the guarded launch (Gate). It serves nothing until armed: the
  # dispatch binding resolves right after publication, while the guarded root
  # is still starting, and any earlier descendant connection simply waits.
  Initialize-NestedOwner
  if ($isNativeDb) {
    Invoke-NativeLaunch
  } elseif ($isAttachedAdmission) {
    if ($nestedOwnerEligible) {
      $nestedBinding = Invoke-HeavyAdmissionCensus { Assert-HeavyCallerEligibility $callerBinding }
      Start-NestedOwner $ownedRaw $GuardedPid $GuardedProcessStartUtc "attached" $nestedBinding
      $script:nestedTransport = New-NestedTransportDescriptor
    }
    Assert-HeavyAdmissionTime
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
      if ($possibleDescendant -eq $false) {
        $attachedDeadTreeProven=$true;break
      }
      Start-Sleep -Milliseconds 100
    }
    $exitCode = 0
  } else {
    if ($TestCancelAfterAcquisition) { throw [OperationCanceledException]::new("heavy-verifier test cancellation") }
    if ($isControllerFixture) { New-ControllerFixtureEvidence }
    if ($isDiagnostic -and $TestDelayDiagnosticLaunchMilliseconds -gt 0) {
      Start-Sleep -Milliseconds $TestDelayDiagnosticLaunchMilliseconds
    }
    if ($isDiagnostic) {
      # Census and launch are separated by a final reparse walk and a handle
      # opened with FileShare.Read. The handle remains live until child exit,
      # preventing a hash-to-launch replacement or deletion on Windows.
      Assert-DiagnosticPathNoReparse $diagnosticScriptFull 'diagnostic script path'
      $diagnosticResultPath = Join-Path (Split-Path -Parent $diagnosticScriptFull) ([IO.Path]::GetFileNameWithoutExtension($diagnosticScriptFull) + '.result.json')
      if (Test-Path -LiteralPath $diagnosticResultPath) {
        throw "heavy-verifier: diagnostic result file already exists"
      }
      if ($diagnosticVitestCommand) {
        # Held before the entry launch handle: the entry, the fixed config and
        # every other tracked source are the exact HEAD bytes from here on.
        $diagnosticExactHeadTree = Open-DiagnosticExactHeadTree
        Assert-DiagnosticIgnoredPathsAdmitted
      }
      $diagnosticSourceStream = [IO.File]::Open($diagnosticScriptFull, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
      $launchHashBytes = [Security.Cryptography.SHA256]::HashData($diagnosticSourceStream)
      $launchHash = [Convert]::ToHexString($launchHashBytes).ToLowerInvariant()
      if ($diagnosticVitestCommand) {
        $diagnosticDefinition.sha256 = $launchHash
      } elseif ($launchHash -cne $diagnosticDefinition.sha256) {
        throw "heavy-verifier: declared diagnostic SHA-256 does not match the script"
      }
      $diagnosticSourceStream.Position = 0
      if ($IsWindows) { $diagnosticJobHandle = [HeavyDiagnosticJob]::Create() }
    } elseif ($isWorkspaceDbTest -and $IsWindows) {
      $diagnosticJobHandle = [HeavyDiagnosticJob]::Create()
    }
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
    $workspaceDbStagePath = $null
    if ($isWorkspaceDbTest) {
      $workspaceDbStagePath = Join-Path ([IO.Path]::GetTempPath()) "chase-sets-workspace-db-stage-$lockId.json"
      if (Test-Path -LiteralPath $workspaceDbStagePath) { throw "heavy-verifier: workspace DB stage path already exists" }
      $start.Environment["CHASE_SETS_WORKSPACE_DB_STAGE_PATH"] = $workspaceDbStagePath
    }
    # An inherited descriptor never crosses into a new owner's tree. A Gate
    # owner publishes its own descriptor only in the guarded environment.
    [void]$start.Environment.Remove("CHASE_SETS_HEAVY_SLOT_TRANSPORT")
    if ($nestedOwnerEligible) {
      $nestedBinding = $callerBinding
      $script:nestedTransport = New-NestedTransportDescriptor
      $start.Environment["CHASE_SETS_HEAVY_SLOT_TRANSPORT"] = $script:nestedTransport
    }
    if ($isHostVerifier) {
      $preload = Join-Path $PSScriptRoot "heavy-admission-preload.cjs"
      if (-not (Test-SafeFile $preload)) { throw "heavy-verifier: canonical admission preload unavailable or unsafe" }
      $nodeOptions = "--require=`"$($preload.Replace('\', '/'))`""
      if (-not $isDiagnostic -and -not [string]::IsNullOrWhiteSpace($start.Environment['NODE_OPTIONS'])) {
        $nodeOptions = $start.Environment['NODE_OPTIONS'] + ' ' + $nodeOptions
      }
      if ($isDiagnostic) { $start.Environment['NODE_OPTIONS'] = $nodeOptions }
      $configuration = [ordered]@{
        schemaVersion = 1; guardPath = $PSCommandPath; powershellPath = $process.Path
        containerRoot = $container; worktree = $worktreeFull; lane = $Lane
        retainAdmission = $true
        originalNodeOptionsPresent = $true; originalNodeOptions = $nodeOptions
        originalScriptShellPresent = $start.Environment.ContainsKey('npm_config_script_shell')
        originalScriptShell = $start.Environment['npm_config_script_shell']
      }
      if ($isDiagnostic) {
        $start.Environment["CHASE_SETS_HEAVY_ADMITTED"] = "1"
        # The preload appends its process id so descendants publish independent
        # manifests and cannot truncate the parent's module records.
        $diagnosticModuleManifestPath = Join-Path $container (".orchestrator\diagnostic-modules-$lockId")
        $configuration.diagnostic = [ordered]@{
          kind = $diagnosticDefinition.kind; entry = $diagnosticScriptFull
          entrySha256 = $diagnosticDefinition.sha256; worktree = $worktreeFull
          boundHead = $acquiredGitIdentity.Head; moduleManifestPath = $diagnosticModuleManifestPath
          dependencies = @($diagnosticDependencies)
        }
        if ($diagnosticVitestCommand) {
          # The Node-hosted pnpm entry is outside the product worktree. Its
          # resolved installation root is the only additional module root;
          # Vitest and the test remain governed by the worktree/node_modules
          # and tracked-at-head rules.
          $pnpmModuleRoot = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $pnpmScript) '..')).TrimEnd('\', '/')
          $configuration.diagnostic.allowedRoots = @($pnpmModuleRoot)
        }
      }
      if ($identityMode -ceq "branch") { $configuration.branch = $acquiredGitIdentity.Branch; $configuration.head = $acquiredGitIdentity.Head }
      else { $configuration.immutableHead = $acquiredGitIdentity.Head }
      $start.Environment["NODE_OPTIONS"] = $nodeOptions
      $start.Environment["CHASE_SETS_HEAVY_ADMISSION_CONFIG"] = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($configuration | ConvertTo-Json -Compress -Depth 6)))
      $start.Environment["npm_config_script_shell"] = $hostNode
      $start.Environment["CHASE_SETS_HEAVY_ADMISSION_PNPM_SCRIPT_SHELL"] = "node-check-proxy"
    }
    foreach ($argument in $arguments) { [void]$start.ArgumentList.Add($argument) }
    $callerBinding = Invoke-HeavyAdmissionCensus { Assert-HeavyCallerEligibility $callerBinding }
    if ($isTimedRoute -and $isHostVerifier -and (-not $callerBinding.Record -or $isWorkspaceDbTest)) {
      $receiptRoot = Join-Path $worktreeFull ".orchestrator\artifacts"
      if (-not (Test-SafeDirectory (Split-Path -Parent $receiptRoot))) { throw "heavy-verifier: receipt directory is unsafe" }
      if (-not (Test-Path -LiteralPath $receiptRoot)) { [IO.Directory]::CreateDirectory($receiptRoot) | Out-Null }
      if (-not (Test-SafeDirectory $receiptRoot)) { throw "heavy-verifier: receipt directory is unsafe" }
      $receiptPath = Join-Path $receiptRoot $(if ($isDiagnostic) { "host-heavy-diagnostic-$lockId.json" } else { "host-heavy-verifier-$lockId.json" })
      if (Test-Path -LiteralPath $receiptPath) { throw "heavy-verifier: diagnostic receipt path already exists" }
    }
    # The child is started normally, then assigned immediately. The assignment
    # window is limited to the native Process.Start-to-AssignProcessToJobObject
    # sequence; KillOnClose and descendant cleanup remain fail-closed.
    Assert-HeavyAdmissionTime
    $child = [Diagnostics.Process]::Start($start)
    [void]$child.Handle
    $childStartTicks = $child.StartTime.ToUniversalTime().Ticks
    if ($isTimedRoute -and $IsWindows -and $diagnosticJobHandle -ne [IntPtr]::Zero) { [HeavyDiagnosticJob]::Assign($diagnosticJobHandle, $child.Id) }
    if ($TestDelayChildPublicationMilliseconds -gt 0) {
      Start-Sleep -Milliseconds $TestDelayChildPublicationMilliseconds
    }
    $childStarted = $child.StartTime.ToUniversalTime().ToString("o")
    $childInitialWorkingSet = [long]$child.WorkingSet64
    $peakWorkingSet = $childInitialWorkingSet
    $workingSet = $childInitialWorkingSet
    $childStopwatch = [Diagnostics.Stopwatch]::StartNew()
    $startedOwner = [ordered]@{}
    foreach ($entry in $owner.GetEnumerator()) { $startedOwner[$entry.Key] = $entry.Value }
    $startedOwner.state = "started"
    $startedOwner.childPid = $child.Id
    $startedOwner.childProcessStartUtc = $childStarted
    $startedRaw = Write-OwnerRecord $startedOwner
    $owner = $startedOwner
    $ownedRaw = $startedRaw
    if (-not (Test-ThisOwner)) { throw "heavy-verifier: owner validation failed after child publication" }
    if ($nestedOwnerEligible) {
      Start-NestedOwner $ownedRaw $child.Id $childStarted "started" $nestedBinding
    }
    if ($isTimedRoute) {
      $budgetMilliseconds = [int][Math]::Ceiling($(if ($isDiagnostic) { $DiagnosticBudgetSeconds } else { $WorkspaceDbBudgetSeconds }) * 1000)
      $deadline = [DateTime]::UtcNow.AddMilliseconds($budgetMilliseconds)
      $peakWorkingSet = [long]$child.WorkingSet64
      $workingSet = $peakWorkingSet
      $diagnosticObservedDescendants = @()
      $script:diagnosticObservedDescendantStarts = @{}
      while ($true) {
        try { $child.Refresh(); $workingSet = [long]$child.WorkingSet64; $peakWorkingSet = [long][Math]::Max($peakWorkingSet, $child.PeakWorkingSet64) } catch {}
        if ($IsWindows) {
          foreach ($descendantPid in @(Get-DiagnosticDescendantPids $child.Id $childStartTicks)) {
            $observedProcess = $null
            try {
              $observedProcess = Get-Process -Id $descendantPid -ErrorAction Stop
              [void]$observedProcess.Handle
              $observedStart = $observedProcess.StartTime.ToUniversalTime().Ticks
              if (-not (Test-DiagnosticSnapshotStart $script:diagnosticSnapshotDescendantStarts[$descendantPid] $observedStart)) {
                Write-DiagnosticProcessAmbiguity $descendantPid 'snapshot-start-identity-mismatch'
                continue
              }
              $script:diagnosticObservedDescendantStarts[$descendantPid] = $observedStart
              $diagnosticObservedDescendants += $descendantPid
            } catch {
              Write-DiagnosticProcessAmbiguity $descendantPid 'snapshot-start-identity-unavailable'
            } finally { if ($observedProcess) { $observedProcess.Dispose() } }
          }
          $diagnosticObservedDescendants = @($diagnosticObservedDescendants | Select-Object -Unique)
        }
        if ($child.HasExited) {
          [void]$child.WaitForExit()
          $jobActive = $false
          if ($IsWindows -and $diagnosticJobHandle -ne [IntPtr]::Zero) { $jobActive = [HeavyDiagnosticJob]::HasActiveProcesses($diagnosticJobHandle) }
          $possibleDescendant = if ($IsWindows) { $jobActive -or (Test-ObservedDiagnosticDescendants $diagnosticObservedDescendants) } else { Test-PossibleOwnedChild $owner -GuardedRootOnly }
          if ($possibleDescendant -eq $false) { break }
        }
        $remaining = [int][Math]::Floor(($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        if ($remaining -le 0) {
          $childTimedOut = $true
          Stop-DiagnosticTree $child.Id $childStartTicks @($diagnosticObservedDescendants)
          break
        }
        [void]$child.WaitForExit([Math]::Min(100, $remaining))
      }
      if ($childTimedOut) {
        $cleanupDeadline = [DateTime]::UtcNow.AddSeconds(2)
        while (-not $child.HasExited -and [DateTime]::UtcNow -lt $cleanupDeadline) {
          try { $child.Refresh(); $workingSet = [long]$child.WorkingSet64; $peakWorkingSet = [long][Math]::Max($peakWorkingSet, $child.PeakWorkingSet64) } catch {}
          [void]$child.WaitForExit(50)
        }
      }
    } else {
      $child.WaitForExit()
    }
    $childStopwatch.Stop()
    $childEnded = [DateTime]::UtcNow.ToString("o")
    $childElapsedMs = [long]$childStopwatch.ElapsedMilliseconds
    if ($isTimedRoute -and $IsWindows -and $diagnosticJobHandle -ne [IntPtr]::Zero) {
      $diagnosticJobResources = [HeavyDiagnosticJob]::QueryResources($diagnosticJobHandle)
    }
    if ($isDiagnostic -and $diagnosticModuleManifestPath) {
      $manifestDirectory = Split-Path -Parent $diagnosticModuleManifestPath
      $manifestPrefix = Split-Path -Leaf $diagnosticModuleManifestPath
      $manifestFiles = if (Test-SafeDirectory $manifestDirectory) {
        @(Get-ChildItem -LiteralPath $manifestDirectory -Filter "$manifestPrefix-*.json" -File -Force | Where-Object { Test-SafeFile $_.FullName })
      } else { @() }
      if ($manifestFiles.Count -eq 0) { throw "heavy-verifier: diagnostic module manifest is missing" }
      [hashtable]$moduleByPath = @{}
      try {
        foreach ($manifestFile in $manifestFiles) {
          $manifest = [IO.File]::ReadAllText($manifestFile.FullName) | ConvertFrom-Json -ErrorAction Stop
          foreach ($module in @($manifest.modules)) {
            if ([string]$module.path -and [string]$module.sha256 -cmatch '^[a-f0-9]{64}$') {
              # Processes never overwrite one another: one path, one loaded digest.
              if ($moduleByPath.ContainsKey([string]$module.path) -and $moduleByPath[[string]$module.path].sha256 -cne [string]$module.sha256) {
                throw "heavy-verifier: diagnostic module manifests disagree on a module digest"
              }
              $moduleByPath[[string]$module.path] = [ordered]@{
                module = if ([string]$module.module) { [string]$module.module } else { [string]$module.path }
                path = [string]$module.path
                sha256 = [string]$module.sha256
              }
            }
          }
        }
      } catch { throw "heavy-verifier: diagnostic module manifest is unreadable" }
      $diagnosticModules = @($moduleByPath.Values)
      $entryModule = @($diagnosticModules | Where-Object { Test-SamePath $_.path $diagnosticScriptFull })
      if ($entryModule.Count -eq 0 -and $diagnosticVitestCommand) {
        # Vitest evaluates the test file through Vite's module runner, which reads
        # it with fs rather than Node's module hooks, so no manifest can record it.
        # The exact-head tree hold (every tracked file proven to be its HEAD
        # blob and held with FileShare.Read until the child tree is proven
        # dead) binds it instead: re-hash through the launch handle and record
        # the entry at its launch digest.
        $diagnosticSourceStream.Position = 0
        $exitEntryHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($diagnosticSourceStream)).ToLowerInvariant()
        if ($exitEntryHash -cne $diagnosticDefinition.sha256) {
          throw "heavy-verifier: vitest-command entry changed while its launch handle was held"
        }
        $entryModule = @([ordered]@{ module = $diagnosticScriptFull; path = $diagnosticScriptFull; sha256 = $exitEntryHash })
        $diagnosticModules = @($diagnosticModules) + $entryModule
      }
      if ($entryModule.Count -eq 0) {
        throw "heavy-verifier: diagnostic module manifest did not record the declared entry"
      }
    }
    if ($isDiagnostic) {
      # The declared diagnostic writes <name>.result.json beside its entry script.
      if (Test-SafeFile $diagnosticResultPath) {
        $diagnosticResultSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($diagnosticResultPath))).ToLowerInvariant()
      }
    }
    $childResources = [ordered]@{
      cpuTimeMs = [Math]::Round($child.TotalProcessorTime.TotalMilliseconds, 3)
      peakWorkingSetBytes = [long][Math]::Max($peakWorkingSet, $childInitialWorkingSet)
      workingSetBytes = [long][Math]::Max($workingSet, $childInitialWorkingSet)
    }
    if ($isControllerPrecursor -or $isHostVerifier -or $isControllerFixture) {
      if ($isTimedRoute -and $childTimedOut) {
        Stop-DiagnosticTree $child.Id $childStartTicks @($diagnosticObservedDescendants)
      } else {
        while ((Test-PossibleOwnedChild $owner -GuardedRootOnly) -ne $false) { Start-Sleep -Milliseconds 100 }
      }
    }
    if ($TestReplaceOwnerBeforeCleanup) {
      [IO.File]::WriteAllText($ownerPath, '{"forged":true}', [Text.UTF8Encoding]::new($false))
    }
    $nativeExitCode = $child.ExitCode
    $exitCode = if ($childTimedOut) { 124 } else { $nativeExitCode }
    $workspaceDbOutcome = $null
    $workspaceDbReason = $null
    if ($isWorkspaceDbTest) {
      $workspaceDbStage = $null
      if ($workspaceDbStagePath -and (Test-Path -LiteralPath $workspaceDbStagePath -PathType Leaf)) {
        try { $workspaceDbStage = [IO.File]::ReadAllText($workspaceDbStagePath) | ConvertFrom-Json } catch { $workspaceDbStage = $null }
        Remove-Item -LiteralPath $workspaceDbStagePath -Force -ErrorAction SilentlyContinue
      }
      if ($childTimedOut) {
        $workspaceDbOutcome = 'timed-out'
        $workspaceDbReason = 'workspace DB test exceeded its budget'
      } elseif ($exitCode -eq 73 -and $workspaceDbStage -and [string]$workspaceDbStage.stage -ceq 'preflight') {
        $workspaceDbOutcome = 'preflight-failed'
        $workspaceDbReason = 'DB preflight failed; workspace DB test was not executed'
      } elseif ($exitCode -eq 73) {
        $workspaceDbOutcome = 'not-executed'
        $workspaceDbReason = 'exit 73 without a preflight stage record (for example a heavy-slot refusal); see stderr'
      } elseif ($exitCode -eq 0) {
        $workspaceDbOutcome = 'passed'
      } else {
        $workspaceDbOutcome = 'test-failed'
      }
    }
    if ($isHostVerifier -or $isControllerFixture -or $isControllerHostHeavyVerifier) {
      Assert-LiveGitIdentityUnchanged -AfterExecution
      Assert-HostVerifierGitState
      if ($diagnosticVitestCommand -and $diagnosticExactHeadTree) { Assert-DiagnosticIgnoredPathsAdmitted }
      if ($isControllerHostHeavyVerifier) { Assert-ControllerHostHeavyControllerState; Assert-ControllerHostHeavyGitState }
      if (-not (Test-ThisOwner)) { throw "heavy-verifier: receipt refused because exact owner changed" }
    }
    if ($isHostVerifier -and (-not $callerBinding.Record -or $isWorkspaceDbTest)) {
      $receiptRoot = Join-Path $worktreeFull ".orchestrator/artifacts"
      if (-not (Test-Path -LiteralPath $receiptRoot)) { [IO.Directory]::CreateDirectory($receiptRoot) | Out-Null }
      if (-not (Test-SafeDirectory $receiptRoot) -or -not (Test-SafeDirectory (Split-Path -Parent $receiptRoot))) {
        throw "heavy-verifier: receipt directory is unsafe"
      }
      if (-not $receiptPath) { $receiptPath = Join-Path $receiptRoot "host-heavy-verifier-$lockId.json" }
      if ($isDiagnostic) {
        $receipt = [ordered]@{
          schema = "host-heavy-diagnostic/v1"; authority = "host-verifier"
          diagnostic = $diagnosticDefinition; worktree = $worktreeFull; cwd = $worktreeFull
          head = $acquiredGitIdentity.Head; lane = $Lane; identityMode = $identityMode; branch = $owner.branch
          holder = [ordered]@{ owner = $owner.owner; pid = $owner.pid; processStartUtc = $owner.processStartUtc }
          slot = [ordered]@{ name = $lockDirectoryName; lockId = $lockId }
          command = if ($diagnosticVitestCommand) {
            [ordered]@{ executable = 'pnpm'; arguments = @($diagnosticCommandArguments); text = ('pnpm ' + ($diagnosticCommandArguments -join ' ')); launchExecutable = $command; launchArguments = @($arguments) }
          } else {
            [ordered]@{ executable = $command; arguments = @($arguments) }
          }
          start = $childStarted; end = $childEnded; exit = $exitCode; nativeExit = $nativeExitCode; elapsedMs = $childElapsedMs; timedOut = $childTimedOut
          containerRoot = $container; declarationSha256 = $diagnosticDefinition.sha256; modules = @($diagnosticModules)
          resources = [ordered]@{
            cpuTimeMs = $childResources.cpuTimeMs; peakWorkingSetBytes = $childResources.peakWorkingSetBytes
            workingSetBytes = $childResources.workingSetBytes
            jobPeakMemoryBytes = if ($diagnosticJobResources) { [uint64]$diagnosticJobResources.peakJobMemoryBytes } else { $null }
            jobTotalUserTime100ns = if ($diagnosticJobResources) { [long]$diagnosticJobResources.totalUserTime100ns } else { $null }
            jobTotalKernelTime100ns = if ($diagnosticJobResources) { [long]$diagnosticJobResources.totalKernelTime100ns } else { $null }
            jobTotalProcesses = if ($diagnosticJobResources) { [uint32]$diagnosticJobResources.totalProcesses } else { $null }
          }
        }
        if ($diagnosticResultSha256) { $receipt.Add('resultSha256', $diagnosticResultSha256) }
      } elseif ($isWorkspaceDbTest) {
        $receipt = [ordered]@{
          schema = "host-heavy-verifier/v1"; route = "workspace-db-test"
          authority = $(if ($callerBinding.Record) { "dispatch-lane" } else { "host-verifier" })
          worktree = $worktreeFull; head = $acquiredGitIdentity.Head; lane = $Lane
          identityMode = $identityMode; branch = $owner.branch; gate = $ownerGate
          workspace = $WorkspaceDbTest; file = $workspaceDbFile
          budgetSeconds = $WorkspaceDbBudgetSeconds; elapsedMs = $childElapsedMs; timedOut = $childTimedOut; nativeExit = $nativeExitCode
          commandIdentity = $commandIdentity; executable = $command; arguments = @($arguments)
          lockId = $lockId; wrapper = @{ pid = $PID; processStartUtc = $started }
          root = @{ pid = $child.Id; processStartUtc = $childStarted }; exit = $exitCode
        }
        if ($workspaceDbOutcome) { $receipt.Add('outcome', $workspaceDbOutcome) }
        if ($workspaceDbReason) { $receipt.Add('reason', $workspaceDbReason) }
        if ($callerBinding.Record) {
          $receipt.Add('launchId', [string]$callerBinding.Record.launchId)
          $receipt.Add('laneRole', [string]$callerBinding.Record.laneRole)
          $receipt.Add('routingRow', [int]$callerBinding.Row)
        }
      } else {
        $receipt = [ordered]@{
          schema = "host-heavy-verifier/v1"; authority = "host-verifier"
          worktree = $worktreeFull; head = $acquiredGitIdentity.Head; lane = $Lane
          identityMode = $identityMode; branch = $owner.branch; gate = $ownerGate
          workspace = $(if ($isWorkspaceTest) { $WorkspaceTest } else { $null })
          commandIdentity = $commandIdentity; executable = $command; arguments = @($arguments)
          lockId = $lockId; wrapper = @{ pid = $PID; processStartUtc = $started }
          root = @{ pid = $child.Id; processStartUtc = $childStarted }; exit = $exitCode
        }
      }
      $stream = [IO.File]::Open($receiptPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
      try { $bytes = [Text.Encoding]::UTF8.GetBytes(($receipt | ConvertTo-Json -Depth 5)); $stream.Write($bytes); $stream.Flush($true) }
      finally { $stream.Dispose() }
      [Console]::Error.WriteLine("heavy-verifier: receipt=$receiptPath exit=$exitCode")
    }
    if ($isControllerHostHeavyVerifier) {
      $receiptRoot = Join-Path $worktreeFull ".orchestrator/artifacts"
      if (-not (Test-Path -LiteralPath $receiptRoot)) { [IO.Directory]::CreateDirectory($receiptRoot) }
      if (-not (Test-SafeDirectory $receiptRoot) -or -not (Test-SafeDirectory (Split-Path -Parent $receiptRoot))) {
        throw "heavy-verifier: host-heavy receipt directory is unsafe"
      }
      $receiptPath = Join-Path $receiptRoot "controller-host-heavy-verifier-$lockId.json"
      $receipt = [ordered]@{
        schema = "controller-host-heavy-verifier/v1"; authority = "controller-host-heavy-verifier"
        worktree = $worktreeFull; cwd = $worktreeFull; head = $acquiredGitIdentity.Head
        lane = $Lane; identityMode = $identityMode; branch = $owner.branch; gate = $ownerGate
        slot = [ordered]@{ name = $lockDirectoryName; lockId = $lockId }
        controller = [ordered]@{ worktree = $hostHeavyControllerRoot; head = $hostHeavyControllerHead; sources = $hostHeavyControllerBlobs }
        target = [ordered]@{ worktree = $worktreeFull; head = $acquiredGitIdentity.Head; sources = $hostHeavyVerifierBlobs }
        sources = $hostHeavyVerifierBlobs
        command = [ordered]@{ executable = $command; arguments = @($arguments) }
        wrapper = [ordered]@{ pid = $PID; processStartUtc = $started }
        root = [ordered]@{ pid = $child.Id; processStartUtc = $childStarted }
        exit = $exitCode; nativeExit = $nativeExitCode; released = $false
      }
      $stream = [IO.File]::Open($receiptPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
      try { $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($receipt | ConvertTo-Json -Depth 8)); $stream.Write($bytes); $stream.Flush($true) }
      finally { $stream.Dispose() }
      [Console]::Error.WriteLine("heavy-verifier: host-heavy receipt=$receiptPath exit=$exitCode")
    }
    if ($isControllerPrecursor -and $exitCode -eq 0) {
      Assert-ControllerPrecursorArtifactState -AfterSuccess
    }
  }
} finally {
  # The nested owner stops before release: after this point no descendant can
  # obtain a signed continuation from this wrapper, and the private key dies here.
  Stop-NestedOwner
  $leftoverWorkspaceDbStage = Get-Variable -Name workspaceDbStagePath -ValueOnly -ErrorAction SilentlyContinue
  if ($leftoverWorkspaceDbStage) { Remove-Item -LiteralPath $leftoverWorkspaceDbStage -Force -ErrorAction SilentlyContinue }
  # Terminate the child tree and prove it exited before any source handle is
  # released, on every path (success, timeout and error). If exit cannot be
  # proven the handles stay open until this process exits and the slot is not
  # released as if cleanup had succeeded.
  $diagnosticSourcesRetained = $false
  if ($diagnosticSourceStream -or $diagnosticExactHeadTree) {
    if (Stop-DiagnosticTreeUntilExited) {
      if ($diagnosticSourceStream) { $diagnosticSourceStream.Dispose(); $diagnosticSourceStream = $null }
      if ($diagnosticExactHeadTree) { $diagnosticExactHeadTree.Dispose(); $diagnosticExactHeadTree = $null }
      if ($child) { [Console]::Error.WriteLine("heavy-verifier: diagnostic source handles released after child-tree exit was proven") }
    } else {
      $diagnosticSourcesRetained = $true
      [Console]::Error.WriteLine("heavy-verifier: diagnostic source handles retained because child-tree exit was not proven")
    }
  }
  if ($diagnosticJobHandle -ne [IntPtr]::Zero) {
    [HeavyDiagnosticJob]::Close($diagnosticJobHandle)
    $diagnosticJobHandle = [IntPtr]::Zero
  }
  if ($diagnosticModuleManifestPath) {
    $manifestDirectory = Split-Path -Parent $diagnosticModuleManifestPath
    $manifestPrefix = Split-Path -Leaf $diagnosticModuleManifestPath
    if (Test-SafeDirectory $manifestDirectory) {
      Get-ChildItem -LiteralPath $manifestDirectory -Filter "$manifestPrefix-*.json" -File -Force -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    }
  }
  if ($isTimedRoute -and $child -and -not $child.HasExited) {
    try { Stop-DiagnosticTree $child.Id $childStartTicks @($diagnosticObservedDescendants); [void]$child.WaitForExit(2000) } catch {}
  }
  if ($isNativeDb -and $child -and -not $child.HasExited) {
    try { $child.StandardInput.Close() }
    finally { Stop-ExactVerifierProcess $child.Id $childStartTicks; [void]$child.WaitForExit(30000) }
  }
  if ($diagnosticSourcesRetained) {
    $releaseMismatch = $true
  } elseif (($isHostVerifier -or $isControllerFixture -or $isControllerHostHeavyVerifier) -and $null -ne $child -and
      ($owner.state -cne 'started' -or
       (Get-ProcessIdentityState $owner.childPid $owner.childProcessStartUtc) -cne 'dead' -or
       (Test-PossibleOwnedChild $owner -GuardedRootOnly) -ne $false)) {
    $releaseMismatch = $true
  } elseif($isAttachedAdmission-and$attachedDeadTreeProven-and-not(Remove-ExactOwnedAdmissionRoot $owner -GuardedDeathProven)){
    $releaseMismatch=$true
  }else{
    $releaseMismatch = -not (Release-ThisLock)
  }
}
if ($releaseMismatch) {
  [Console]::Error.WriteLine("heavy-verifier: refusing cleanup because lock ownership no longer matches this caller (admission-root=$admissionCleanupDiagnostic)")
  if ($isNativeDb) { Write-NativeReply 'unknown' 'Exact owner, Windows descendants, Linux init and root absence were not all established; cleanup refused.' }
  exit 1
}
if ($isControllerHostHeavyVerifier -and $receiptPath -and (Test-SafeFile $receiptPath)) {
  $releasedReceipt = [IO.File]::ReadAllText($receiptPath) | ConvertFrom-Json -AsHashtable -DateKind String
  $releasedReceipt['released'] = $true
  $releasedReceipt['releasedUtc'] = [DateTime]::UtcNow.ToString('o')
  [IO.File]::WriteAllText($receiptPath, ($releasedReceipt | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
}
if ($isControllerFixture -and $null -ne $child) {
  # Written only after the exact owner and its whole process tree are released.
  # It records the route and the check's native exit, never the check verdict.
  Assert-ControllerFixtureEvidencePath
  if (-not (Test-PrecursorSafeDirectory $fixtureEvidence)) { throw "heavy-verifier: controller fixture evidence directory became unsafe; receipt refused" }
  $receiptPath = Join-Path $fixtureEvidence "heavy-verifier-receipt.json"
  $receipt = [ordered]@{
    schema = "controller-fixture-equivalence-route/v1"
    wrapper = [ordered]@{ path = $PSCommandPath; sha256 = $fixtureWrapperDigest; pid = $PID; processStartUtc = $started }
    lane = $Lane; worktree = $acquiredGitIdentity.Worktree; identityMode = $identityMode; branch = $owner.branch; head = $acquiredGitIdentity.Head
    sources = $fixtureCheckBlobs; slot = $lockDirectoryName; lockId = $lockId; gate = $ownerGate
    executable = $command; arguments = @($arguments); commandIdentity = $commandIdentity
    child = [ordered]@{ pid = $owner.childPid; processStartUtc = $owner.childProcessStartUtc }
    exit = $exitCode; released = $true; releasedUtc = [DateTime]::UtcNow.ToString("o")
  }
  $stream = [IO.File]::Open($receiptPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
  try { $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($receipt | ConvertTo-Json -Depth 5)); $stream.Write($bytes); $stream.Flush($true) }
  finally { $stream.Dispose() }
  [Console]::Error.WriteLine("heavy-verifier: fixture-equivalence receipt=$receiptPath exit=$exitCode")
}
if ($isNativeDb) {
  if ($null -eq $nativeCleanupProof) { throw 'native-db: cleanup proof unavailable after release' }
  [void](Assert-NativeWindowsPath $nativeEvidencePath (Join-Path $worktreeFull '.orchestrator/artifacts'))
  $evidence = [ordered]@{
    requestDigest = $owner.native.request.digest; owner = $owner; result = $nativeResult
    cleanup = $nativeCleanupProof; releasedUtc = [DateTime]::UtcNow.ToString('o')
  }
  [IO.File]::WriteAllText($nativeEvidencePath, ($evidence | ConvertTo-Json -Depth 16), [Text.UTF8Encoding]::new($false))
  Write-NativeReply $nativeResult.status $nativeResult.diagnostic
}
exit $exitCode
