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
  # Host-declared standalone Node diagnostics are a closed name set. The host
  # supplies the declaration's repository-relative script, source digest and
  # finite wall-clock budget; all three are checked before slot acquisition.
  [Parameter(Mandatory, ParameterSetName = "Diagnostic")][ValidateSet("worst13-no-fit")][string]$Diagnostic,
  [Parameter(Mandatory, ParameterSetName = "Diagnostic")][string]$DiagnosticScriptPath,
  [Parameter(Mandatory, ParameterSetName = "Diagnostic")][ValidatePattern("^[a-fA-F0-9]{64}$")][string]$DiagnosticSha256,
  [Parameter(Mandatory, ParameterSetName = "Diagnostic")][double]$DiagnosticBudgetSeconds,
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
  # Impact or full scope and an optional prior result for reuse (#8207).
  [Parameter(ParameterSetName = "ControllerBattery", DontShow)][ValidateSet("impact", "full")][string]$ControllerBatteryScope = "impact",
  [Parameter(ParameterSetName = "ControllerBattery", DontShow)][string]$ControllerBatteryPriorResultPath = "",
  # Per-item reuse stop (#9373), forwarded verbatim as one argument.
  [Parameter(ParameterSetName = "ControllerBattery", DontShow)][string]$ControllerBatteryNoReuseIdentity = "",
  [Parameter(ParameterSetName = "ControllerBattery", DontShow)][ValidateSet("stop", "all")][string]$ControllerBatteryOnFailure = "stop",
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
$isControllerFixture = $PSCmdlet.ParameterSetName -ceq "ControllerFixtureEquivalence"
$isWorkspaceTest = $PSCmdlet.ParameterSetName -ceq "WorkspaceTest"
$isNativeDb = $PSCmdlet.ParameterSetName -ceq "NativeDb"
$isDiagnostic = $PSCmdlet.ParameterSetName -ceq "Diagnostic"
$nativeRequest = $null
$nativeReplyWritten = $false
$nativeCleanupProof = $null
if ($isWorkspaceTest) { $WorkspaceTest = "@chase-sets/ordering" }
# This closed command shape selects production command resolution. Caller
# authority is determined independently by the native census below.
$isHostVerifier = ($PSCmdlet.ParameterSetName -cin @("Gate", "WorkspaceTest", "Diagnostic")) -and -not $CommandPath
$admissionResultFull = $null
$script:admissionPendingSequence = 0
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
  if ($_.Exception.Message.StartsWith('heavy-verifier: caller eligibility:', [StringComparison]::Ordinal)) {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 73
  }
  if (($isControllerPrecursor -or $isControllerFixture) -and $_.Exception.Message.StartsWith("heavy-verifier: lock unavailable (", [StringComparison]::Ordinal)) {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 73
  }
  if ($isHostVerifier) {
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
if ($CommandPath -or $CommandArgumentList) {
  $fixtureTemp = if ($IsWindows) {
    [IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Temp')).TrimEnd('\','/')
  } else { [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/') }
  if (-not $container.StartsWith($fixtureTemp + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "heavy-verifier: arbitrary commands are fixture-only; use invoke-heavy-verifier.ps1 -Gate or -WorkspaceTest"
  }
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
  if ($status) { throw "heavy-verifier: host verifier requires a clean exact-head worktree" }
}
$diagnosticScriptFull = $null
$diagnosticDefinition = $null
function Assert-DiagnosticDeclaration {
  if (-not $isDiagnostic) { return }
  $definitions = [ordered]@{
    'worst13-no-fit' = [ordered]@{ kind = 'standalone-node'; extension = '.mjs' }
  }
  if (-not $definitions.Contains($Diagnostic)) {
    throw "heavy-verifier: diagnostic name is not declared"
  }
  if ([double]::IsNaN($DiagnosticBudgetSeconds) -or [double]::IsInfinity($DiagnosticBudgetSeconds) -or
      $DiagnosticBudgetSeconds -le 0 -or $DiagnosticBudgetSeconds -gt 86400) {
    throw "heavy-verifier: diagnostic budget must be finite and greater than zero"
  }
  if ([string]::IsNullOrWhiteSpace($DiagnosticScriptPath) -or
      [IO.Path]::IsPathFullyQualified($DiagnosticScriptPath) -or
      $DiagnosticScriptPath.Replace('\', '/') -cnotmatch '^[A-Za-z0-9._/-]+\.mjs$' -or
      @($DiagnosticScriptPath.Replace('\', '/').Split('/') | Where-Object { $_ -in @('', '.', '..') }).Count -gt 0) {
    throw "heavy-verifier: diagnostic script must be a repository-relative standalone .mjs path"
  }
  $relative = $DiagnosticScriptPath.Replace('/', '\')
  $candidate = [IO.Path]::GetFullPath((Join-Path $worktreeFull $relative)).TrimEnd('\', '/')
  if (-not $candidate.StartsWith($worktreeFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "heavy-verifier: diagnostic script escaped the supplied worktree"
  }
  $current = $candidate
  while ($current -and (Test-Path -LiteralPath $current)) {
    $item = Get-Item -LiteralPath $current -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne [IO.FileAttributes]::None) {
      throw "heavy-verifier: diagnostic script path contains a reparse point"
    }
    $parent = Split-Path -Parent $current
    if ($parent -eq $current) { break }
    $current = $parent
  }
  if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
    throw "heavy-verifier: declared diagnostic script was not found"
  }
  $actual = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($candidate))).ToLowerInvariant()
  if ($actual -cne $DiagnosticSha256.ToLowerInvariant()) {
    throw "heavy-verifier: declared diagnostic SHA-256 does not match the script"
  }
  $script:diagnosticDefinition = [ordered]@{
    name = $Diagnostic; kind = $definitions[$Diagnostic].kind; scriptPath = $DiagnosticScriptPath.Replace('\', '/')
    sha256 = $actual; budgetSeconds = $DiagnosticBudgetSeconds
  }
  $script:diagnosticScriptFull = $candidate
}
Assert-DiagnosticDeclaration
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
      if ($ticks -ne $cached.Starts[$id]) { $unchanged = $false; break }
    }
    # Windows parent edges are immutable within exact live process identities.
    # Cache only those edges, never census, ownership, routing or Git authority.
    if ($unchanged) { return $cached.Chain }
  }
  $script:heavyCallerAncestry = $null
  $chain = @{}
  $snapshot = @{}
  foreach ($row in @(Get-CimInstance Win32_Process -Property ProcessId,ParentProcessId,CreationDate -ErrorAction Stop)) {
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
    if ($ticks - ($ticks % 10) -ne $snapshot[$id].CreationDate.ToUniversalTime().Ticks) { $starts = $null; break }
    $starts[$id] = $ticks
  }
  if ($starts) { $script:heavyCallerAncestry = @{ Key = $key; Starts = $starts; Chain = $chain } }
  return $chain
}
function Get-HeavyRoutingRow($Record, [string]$RuntimeRoot) {
  $path = Join-Path $RuntimeRoot 'dispatch-log.jsonl'
  $file = Get-Item -LiteralPath $path -Force -ErrorAction Stop
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
    public static IEnumerable<string> RelevantRows(string path, string label, string transcript) {
      foreach (string line in File.ReadLines(path)) {
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
'@
  }
  $candidates = @()
  foreach ($line in [ChaseSets.HeavyAdmission.RoutingHistory]::RelevantRows($path, $Record.label, (Split-Path -Leaf $Record.transcriptPath))) {
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
function Get-HeavyOwnershipCensusDeadlineMs([int]$CandidateCount) {
  # Serial Git identity probes need fleet-sized time, not fleet-sized authority.
  # Allow 2s per candidate (reported throughput: 3-8 records/5s), retaining the
  # 5s floor and a 30s census budget ceiling. No retry or cached identity proof.
  return [int][Math]::Min([long]30000, [Math]::Max([long]5000, 2000 * [long]$CandidateCount))
}
function Get-HeavyCallerBinding([switch]$Recheck) {
  $result = [ordered]@{ Record = $null; Raw = $null; Path = $null; Row = $null; RoutingRaw = $null; Reason = $null }
  try {
    $runtime = Join-Path $container '.orchestrator'
    $rootPid = if ($isAttachedAdmission) { $GuardedPid } else { $PID }
    $rootStart = if ($isAttachedAdmission) { $GuardedProcessStartUtc } else { (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o') }
    $observedGitIdentities = @{}
    # This bounded sample selects time only; the census and subsequent exact
    # record enumeration still prove completeness. Other census callers retain
    # their own budgets, including the separate product-census proof allowance.
    $candidateCount = @([IO.Directory]::EnumerateFiles($runtime, 'dispatch-launch-*.json') | Select-Object -First 15).Count
    $censusDeadlineMs = Get-HeavyOwnershipCensusDeadlineMs $candidateCount
    Write-AdmissionPending $censusDeadlineMs
    $live = Get-LiveDispatchOwnership -RuntimeRoot $runtime -TempRoot ([IO.Path]::GetTempPath()) -ContainerRoot $container -DeadlineMs $censusDeadlineMs -GitIdentityResolver {
      param($Worktree)
      $identity = Get-DispatchGitIdentity $Worktree
      $observedGitIdentities[$Worktree] = $identity
      return $identity
    }
    if ($live.health.counts.truncated -gt 0 -or $live.health.counts.rejected -gt 0 -or
        $live.health.counts.probeFailures -gt 0 -or $live.health.counts.legacyLiveOwners -gt 0) { throw 'dispatch census unknown or incomplete' }
    $paths = @([IO.Directory]::EnumerateFiles($runtime, 'dispatch-launch-*.json') | Sort-Object)
    if ($paths.Count -ne $live.health.counts.examined) { throw 'dispatch census changed' }
    $snapshots = @{}
    $records = @{}
    $oldestLaunch = [long]::MaxValue
    foreach ($path in $paths) {
      $snapshots[$path] = [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes($path))
      $record = Get-ValidatedDispatchOwnershipRecord $path $runtime ([IO.Path]::GetTempPath())
      if ($null -eq $record) { throw 'dispatch record malformed or missing role' }
      $records[$path] = $record
      $startIdentity = if ($record.childPid) { $record.childStartIdentity } else { $record.launcherStartIdentity }
      $oldestLaunch = [Math]::Min($oldestLaunch, [DateTimeOffset]::Parse($startIdentity).UtcTicks)
    }
    $candidatePids = @($records.Values | ForEach-Object { [int]$_.launcherPid; if ($_.childPid) { [int]$_.childPid } })
    $before = Get-HeavyCallerAncestry $rootPid $rootStart $oldestLaunch $candidatePids @($records.Values)
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
        $result.Row = $routing.Row; $result.RoutingRaw = $routing.Raw
      }
    }
    # Windows parentage cannot change within one exact process identity. Probe
    # every captured ancestor again without repeating the full CIM enumeration.
    foreach ($id in $before.Keys) {
      $process = Get-Process -Id $id -ErrorAction Stop
      if ($process.StartTime.ToUniversalTime().Ticks -ne $before[$id]) { throw 'ancestry changed' }
    }
    $afterPaths = @([IO.Directory]::EnumerateFiles($runtime, 'dispatch-launch-*.json') | Sort-Object)
    $foreignChanged = ($paths -join "`n") -cne ($afterPaths -join "`n")
    foreach ($path in $paths) {
      if (-not [IO.File]::Exists($path) -or -not [string]::Equals([Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes($path)), $snapshots[$path], [StringComparison]::Ordinal)) {
        if ($path -ceq $result.Path) { throw 'selected dispatch bytes changed' }
        $foreignChanged = $true
      }
    }
    if ($foreignChanged) {
      if ($Recheck) { throw 'dispatch census kept changing' }
      # Foreign lifecycle bytes are not selected authority. Re-census their
      # semantics once instead of denying an unrelated healthy transition.
      $fresh = Get-HeavyCallerBinding -Recheck
      if ($fresh.Reason -or $fresh.Path -cne $result.Path -or -not [string]::Equals($fresh.Raw, $result.Raw, [StringComparison]::Ordinal) -or
          -not [string]::Equals($fresh.RoutingRaw, $result.RoutingRaw, [StringComparison]::Ordinal)) { throw "dispatch census changed authority: $($fresh.Reason)" }
      return $fresh
    }
  } catch { $result.Reason = $_.Exception.Message }
  return [pscustomobject]$result
}
function Assert-HeavyCallerEligibility($Expected = $null) {
  $binding = Get-HeavyCallerBinding
  if ($binding.Reason) { throw "heavy-verifier: caller eligibility: $($binding.Reason)" }
  if ($binding.Record -and ($binding.Record.laneRole -cne 'implementation' -or $binding.Row -eq 13)) {
    throw "heavy-verifier: caller eligibility: role=$($binding.Record.laneRole) routing-row=$($binding.Row) cannot reserve heavy verification"
  }
  if ($Expected -and ($Expected.Path -cne $binding.Path -or -not [string]::Equals($Expected.Raw, $binding.Raw, [StringComparison]::Ordinal) -or
      -not [string]::Equals($Expected.RoutingRaw, $binding.RoutingRaw, [StringComparison]::Ordinal))) { throw 'heavy-verifier: caller eligibility: launch or routing identity changed' }
  return $binding
}
try { . (Join-Path $PSScriptRoot 'dispatch-ownership.ps1') }
catch { throw "heavy-verifier: caller eligibility: ownership reader unavailable: $($_.Exception.Message)" }
$callerBinding = Assert-HeavyCallerEligibility
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

# Controller release batteries and precursors own a separate slot (Todd ruling
# 2026-09-10): they never wait on, and never block, the platform heavy verifier.
# The fixture-equivalence route shares that controller slot.
$lockDirectoryName = if ($isControllerBattery -or $isControllerPrecursor -or $isControllerFixture) { "controller-verify-lock.d" } else { "verify-lock.d" }
$lockPath = Join-Path $container (".orchestrator\" + $lockDirectoryName)
$ownerPath = Join-Path $lockPath "owner.json"
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
} elseif ($isControllerBattery -or $isControllerPrecursor -or $isControllerFixture) {
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
} elseif ($isControllerFixture) {
  # Never -BaselineHead or -RunDirectory: the check keeps its immutable oracle
  # and runs every fixture step in one call.
  @("-NoProfile", "-NonInteractive", "-File", $fixtureCheckPath, "-Phase", "fixture", "-EvidenceDirectory", $fixtureEvidence)
} elseif ($CommandPath) {
  @($CommandArgumentList)
} elseif ($isDiagnostic) {
  @($diagnosticScriptFull)
} else {
  if ($isWorkspaceTest) { @($pnpmScript, "--filter", $WorkspaceTest, "run", "test", "--maxWorkers=1", "--no-file-parallelism") }
  elseif ($Gate -ceq 'test:e2e:suite') { @($pnpmScript, 'run', $Gate, '--', $E2eSuite) }
  else { @($pnpmScript, "run", $Gate) }
}
$ownerGate = if ($isNativeDb) { 'verify:test-db' } elseif ($isAttachedAdmission) { $AdmissionKind } elseif ($isControllerBattery -or $isControllerPrecursor -or $isControllerFixture) { "script-battery" } elseif ($isWorkspaceTest) { "test" } elseif ($isDiagnostic) { "diagnostic" } else { $Gate }
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
    $stream = [IO.File]::Open($RecordPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
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
function Assert-LaneAdmissionReceipt {
  if ($env:CHASE_SETS_LANE_MODE -ne '1' -or [string]::IsNullOrWhiteSpace($env:CHASE_SETS_HEAVY_ADMISSION_WORKSPACE_TEST)) { return }
  $receiptPath = Join-Path $worktreeFull ".orchestrator/artifacts/lane-heavy-admission-$($owner.lockId)-$($owner.childPid).json"
  if (-not (Test-SafeFile $receiptPath)) {
    throw "heavy-verifier: lane-mode admission receipt is missing; host binding refused"
  }
  try { $receipt = [IO.File]::ReadAllText($receiptPath) | ConvertFrom-Json -DateKind String -ErrorAction Stop } catch {
    throw "heavy-verifier: lane-mode admission receipt is unreadable; host binding refused"
  }
  $allowedKinds = @('script-battery', 'vitest-full')
  $observedArguments = @($receipt.observedCommand.arguments)
  if ($receipt.schema -cne 'lane-heavy-admission/v1' -or
      $receipt.kind -cnotin $allowedKinds -or
      $receipt.holder.owner -cne $owner.owner -or [int]$receipt.holder.pid -ne [int]$owner.pid -or
      [int]$receipt.writer.pid -ne [int]$owner.childPid -or
      $receipt.slot.lockId -cne $owner.lockId -or $receipt.slot.name -cne $lockDirectoryName -or
      [IO.Path]::GetFullPath([string]$receipt.cwd) -cne $worktreeFull -or
      [string]$receipt.head -cne [string]$acquiredGitIdentity.Head -or
      $receipt.admittedCommand.executable -cne $command -or
      (@($receipt.admittedCommand.arguments) -join "`n") -cne (@($arguments) -join "`n") -or
      [string]::IsNullOrWhiteSpace([string]$receipt.observedCommand.executable) -or
      $observedArguments.Count -eq 0 -or
      ($observedArguments | Where-Object { [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0 -or
      -not (Test-UtcIdentity ([string]$receipt.start)) -or -not (Test-UtcIdentity ([string]$receipt.end)) -or
      [DateTimeOffset]::Parse([string]$receipt.end).Ticks -lt [DateTimeOffset]::Parse([string]$receipt.start).Ticks -or
      ($receipt.exit -isnot [int] -and $receipt.exit -isnot [long])) {
    throw "heavy-verifier: lane-mode admission receipt did not bind the admitted command; host binding refused"
  }
  return $receipt
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
    [IO.File]::Replace($temporaryPath, $ownerPath, [NullString]::Value)
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
  try {
    $reconciler = [Diagnostics.Process]::Start((New-NativeStart 'reconcile' $Record.native.root))
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
      if (-not $reconciler.HasExited) { $reconciler.Kill(); [void]$reconciler.WaitForExit(30000) }
      $reconciler.Dispose()
    }
  }
}
function Invoke-NativeLaunch {
  $callerBinding = Assert-HeavyCallerEligibility $callerBinding
  if (Test-Path -LiteralPath $nativeEvidencePath) { throw 'native-db: correlation already consumed' }
  $evidenceStream = [IO.File]::Open($nativeEvidencePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
  try {
    $script:child = [Diagnostics.Process]::Start((New-NativeStart 'launch' $owner.native.root))
    $script:nativeErrors = $child.StandardError.ReadToEndAsync()
    $owner.state = 'started'; $owner.childPid = $child.Id
    $owner.childProcessStartUtc = $child.StartTime.ToUniversalTime().ToString('o')
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
    $callerBinding = Assert-HeavyCallerEligibility $callerBinding
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
$nestedOwnerEligible = $IsWindows -and -not $isControllerBattery -and -not $isControllerPrecursor -and -not $isControllerFixture -and -not $isNativeDb -and -not $isDiagnostic
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
if ($isControllerBattery -or $isControllerPrecursor -or $isControllerFixture) { $coordinationKey += "`n" + $lockDirectoryName }
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
  $callerBinding = Assert-HeavyCallerEligibility $callerBinding
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
$child = $null
$childStarted = $null
$childEnded = $null
$childElapsedMs = $null
$childTimedOut = $false
$childResources = $null
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
      $nestedBinding = Assert-HeavyCallerEligibility $callerBinding
      Start-NestedOwner $ownedRaw $GuardedPid $GuardedProcessStartUtc "attached" $nestedBinding
      $script:nestedTransport = New-NestedTransportDescriptor
    }
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
        Assert-LaneAdmissionReceipt
        $attachedDeadTreeProven=$true;break
      }
      Start-Sleep -Milliseconds 100
    }
    $exitCode = 0
  } else {
    if ($TestCancelAfterAcquisition) { throw [OperationCanceledException]::new("heavy-verifier test cancellation") }
    if ($isControllerFixture) { New-ControllerFixtureEvidence }
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
      if (-not [string]::IsNullOrWhiteSpace($start.Environment['NODE_OPTIONS'])) {
        $nodeOptions = $start.Environment['NODE_OPTIONS'] + ' ' + $nodeOptions
      }
      $configuration = [ordered]@{
        schemaVersion = 1; guardPath = $PSCommandPath; powershellPath = $process.Path
        containerRoot = $container; worktree = $worktreeFull; lane = $Lane
        retainAdmission = $true
        laneMode = ($env:CHASE_SETS_LANE_MODE -eq '1')
        workspaceTest = $(if ($isWorkspaceTest) { $WorkspaceTest } else { $null })
        expectedCommand = [ordered]@{ executable = $command; arguments = @($arguments) }
        originalNodeOptionsPresent = $true; originalNodeOptions = $nodeOptions
        originalScriptShellPresent = $start.Environment.ContainsKey('npm_config_script_shell')
        originalScriptShell = $start.Environment['npm_config_script_shell']
      }
      if ($identityMode -ceq "branch") { $configuration.branch = $acquiredGitIdentity.Branch; $configuration.head = $acquiredGitIdentity.Head }
      else { $configuration.immutableHead = $acquiredGitIdentity.Head }
      $start.Environment["NODE_OPTIONS"] = $nodeOptions
      $start.Environment["CHASE_SETS_HEAVY_ADMISSION_CONFIG"] = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($configuration | ConvertTo-Json -Compress)))
      $start.Environment["npm_config_script_shell"] = $hostNode
      $start.Environment["CHASE_SETS_HEAVY_ADMISSION_PNPM_SCRIPT_SHELL"] = "node-check-proxy"
      if ($isWorkspaceTest) { $start.Environment["CHASE_SETS_HEAVY_ADMISSION_WORKSPACE_TEST"] = $WorkspaceTest }
      else { [void]$start.Environment.Remove("CHASE_SETS_HEAVY_ADMISSION_WORKSPACE_TEST") }
    }
    foreach ($argument in $arguments) { [void]$start.ArgumentList.Add($argument) }
    $callerBinding = Assert-HeavyCallerEligibility $callerBinding
    $child = [Diagnostics.Process]::Start($start)
    if ($TestDelayChildPublicationMilliseconds -gt 0) {
      Start-Sleep -Milliseconds $TestDelayChildPublicationMilliseconds
    }
    $childStarted = $child.StartTime.ToUniversalTime().ToString("o")
    $childInitialWorkingSet = [long]$child.WorkingSet64
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
    if ($isDiagnostic) {
      $budgetMilliseconds = [int][Math]::Ceiling($DiagnosticBudgetSeconds * 1000)
      if (-not $child.WaitForExit($budgetMilliseconds)) {
        $childTimedOut = $true
        try { $child.Kill($true) } catch { try { $child.Kill() } catch {} }
        [void]$child.WaitForExit(30000)
      }
    } else {
      $child.WaitForExit()
    }
    $childStopwatch.Stop()
    $childEnded = [DateTime]::UtcNow.ToString("o")
    $childElapsedMs = [long]$childStopwatch.ElapsedMilliseconds
    $childResources = [ordered]@{
      cpuTimeMs = [Math]::Round($child.TotalProcessorTime.TotalMilliseconds, 3)
      peakWorkingSetBytes = [long][Math]::Max($child.PeakWorkingSet64, $childInitialWorkingSet)
      workingSetBytes = [long][Math]::Max($child.WorkingSet64, $childInitialWorkingSet)
    }
    if ($isControllerPrecursor -or $isHostVerifier -or $isControllerFixture) {
      while ((Test-PossibleOwnedChild $owner -GuardedRootOnly) -ne $false) {
        Start-Sleep -Milliseconds 100
      }
    }
    if ($TestReplaceOwnerBeforeCleanup) {
      [IO.File]::WriteAllText($ownerPath, '{"forged":true}', [Text.UTF8Encoding]::new($false))
    }
    $exitCode = $child.ExitCode
    if ($isHostVerifier -or $isControllerFixture) {
      Assert-LiveGitIdentityUnchanged -AfterExecution
      Assert-HostVerifierGitState
      if (-not (Test-ThisOwner)) { throw "heavy-verifier: receipt refused because exact owner changed" }
    }
    if ($isHostVerifier -and -not $callerBinding.Record) {
      $receiptRoot = Join-Path $worktreeFull ".orchestrator/artifacts"
      if (-not (Test-Path -LiteralPath $receiptRoot)) { [IO.Directory]::CreateDirectory($receiptRoot) | Out-Null }
      if (-not (Test-SafeDirectory $receiptRoot) -or -not (Test-SafeDirectory (Split-Path -Parent $receiptRoot))) {
        throw "heavy-verifier: receipt directory is unsafe"
      }
      $receiptPath = if ($isDiagnostic) { Join-Path $receiptRoot "host-heavy-diagnostic-$lockId.json" } else { Join-Path $receiptRoot "host-heavy-verifier-$lockId.json" }
      $receipt = if ($isDiagnostic) {
        [ordered]@{
          schema = "host-heavy-diagnostic/v1"; authority = "host-verifier"
          diagnostic = $diagnosticDefinition; worktree = $worktreeFull; cwd = $worktreeFull
          head = $acquiredGitIdentity.Head; lane = $Lane; identityMode = $identityMode; branch = $owner.branch
          holder = [ordered]@{ owner = $owner.owner; pid = $owner.pid; processStartUtc = $owner.processStartUtc }
          slot = [ordered]@{ name = $lockDirectoryName; lockId = $lockId }
          command = [ordered]@{ executable = $command; arguments = @($arguments) }
          start = $childStarted; end = $childEnded; exit = $exitCode; elapsedMs = $childElapsedMs; timedOut = $childTimedOut
          resources = $childResources
        }
      } else {
        [ordered]@{
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
    if ($isControllerPrecursor -and $exitCode -eq 0) {
      Assert-ControllerPrecursorArtifactState -AfterSuccess
    }
  }
} finally {
  # The nested owner stops before release: after this point no descendant can
  # obtain a signed continuation from this wrapper, and the private key dies here.
  Stop-NestedOwner
  if ($isNativeDb -and $child -and -not $child.HasExited) {
    $child.StandardInput.Close()
    $child.Kill(); [void]$child.WaitForExit(30000)
  }
  if (($isHostVerifier -or $isControllerFixture) -and $null -ne $child -and
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
