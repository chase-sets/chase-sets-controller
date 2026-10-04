<#
.SYNOPSIS
The one lane launcher (milestone-orchestrator SKILL.md §5). Every lane,
review, watchdog-target, and decision session launches through this script —
never through a hand-authored one-off run-*.ps1. Hand-rolled launchers
re-earned four known launch failures in one day (2026-07-22: nonexistent pwsh
path, missing --dangerously-skip-permissions on a decision lane, WSL path
blindness, codex shim launch). Each gotcha is encoded here exactly once, with
dispatch-lane.test.ps1 holding a negative control per gotcha. If a needed mode
is missing, extend this script and its test in the same cycle — do not fork a
copy.

Gotchas encoded (references/stall-gotchas.md):
- windows-start-process-codex-shim: only the native codex.exe is ever
  launched, never the codex.ps1/codex.cmd shim that command precedence
  returns first.
- codex-exec-stdin-hang: stdin always redirects from a finite, non-empty
  prompt file (EOF), never an open console handle.
- claude permission gate (stall 2026-07-22 #5899): claude lanes always carry
  --dangerously-skip-permissions; a gated lane wedges on the first gh/MCP call.
- claude-background-task-dies-on-session-exit: Claude lanes receive one
  foreground-only preamble, deny session-scoped orchestration tools, and reject
  nominal success when stream-json shows active or terminated background work.
- wsl-watchdog-windows-path-blindness: the launch banner prints the
  /mnt/<drive>/ translation of the output file for lane-stall-watchdog.sh.
- double-dispatch clobber: refuses to reuse a non-empty output stem without
  -Force, so a live lane's log is never overwritten.
- review-provider-credential-inheritance: review lanes remove known provider
  credential variables, use empty per-launch doctl config roots, and pin
  KUBECONFIG to a nonexistent file before the harness child starts. GitHub
  authentication remains available.
- windows-posix-cli-shim-resolves-real-provider-binary: review isolation does
  not trust POSIX PATH order or shell `which`; an installed Windows doctl.exe
  that wins native resolution still receives no inherited DigitalOcean
  credential or default doctl config.

.EXAMPLE
./dispatch-lane.ps1 -Harness codex -Model gpt-6.1-sol -Effort high `
  -PromptFile .orchestrator/5899-repair.prompt.txt -Worktree lane-05 `
  -Label lane-05-5899-repair -LaneRole implementation -Row 4 -Placement provisional

.EXAMPLE
./dispatch-lane.ps1 -Harness claude -Model claude-sonnet-5-5 -Effort medium `
  -PromptFile .orchestrator/5915-implementation.prompt.txt -Worktree lane-08 `
  -Label lane-08-5915-implementation -LaneRole implementation -Row 3 -Placement override-Todd -DryRun

.EXAMPLE
./dispatch-lane.ps1 -Harness codex -Model gpt-6.1-sol -Effort high `
  -PromptFile .orchestrator/5962-review.prompt.txt -Worktree lane-03 `
  -Label lane-03-5962-review -LaneRole review

Omitting `-LaneRole` defaults to least-authority `review` without prompting.
Provider authority is inherited only when an implementation dispatch
explicitly selects `-LaneRole implementation`.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateSet("codex", "claude")][string]$Harness,
  [string]$Model,
  [string]$Effort,
  # review (default): remove known provider credentials, isolate doctl config,
  # and disable kubectl's default kubeconfig fallback before the harness child
  # starts while retaining GitHub authentication.
  # implementation: explicitly inherit the launcher environment unchanged.
  [ValidateSet("implementation", "review", "planning")][string]$LaneRole = "review",
  [ValidateSet('product','controller')][string]$ReviewTarget = 'product',
  [ValidateRange(1,[int]::MaxValue)][int]$ControllerIssue,
  [ValidatePattern('^[a-f0-9]{40}$')][string]$ControllerHead,
  [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._:/-]{0,255}$')][string]$AuthorAttempt,
  [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._:/-]{0,255}$')][string]$ReviewerAttempt,
  [string]$AuthorModel,
  [ValidateSet('governing','shadow','advisory')][string]$ReviewAuthority,
  [ValidatePattern('^[a-f0-9]{64}$')][string]$SupersedesReceiptRawSha256,
  [string[]]$AddressedFindingIds,
  [Parameter(Mandatory)][string]$PromptFile,
  # Lane worktree: a pool name like "lane-05" (resolved against the container
  # root) or an absolute directory path.
  [Parameter(Mandatory)][string]$Worktree,
  # Output stem: <Label>.jsonl / <Label>.err.log under .orchestrator/.
  [Parameter(Mandatory)][string]$Label,
  # Resolve, validate, and print the launch plan as JSON without launching.
  [switch]$DryRun,
  # Permit reusing an existing non-empty output stem (e.g. an intentional
  # same-label resume after the prior process was confirmed dead).
  [switch]$Force,
  # Testing override for the harness executable; production resolves it.
  [string]$ExecutablePath,
  # Testing override paired with -ExecutablePath; never used by dispatches.
  [Parameter(DontShow)][string[]]$TestArgumentList,
  # Isolated test seams. Production ownership and provider-temp roots are fixed.
  [Parameter(DontShow)][string]$TestRuntimeRoot,
  [Parameter(DontShow)][string]$TestTempRoot,
  [Parameter(DontShow)][string]$ResumeAdmissionObservedPath,
  [Parameter(DontShow)][string]$ResumeAdmissionContinuePath,
  [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._:/-]{0,255}$')][string]$SemanticAttemptId,
  [ValidateRange(0,3)][int]$WatchdogRelaunchCount = 0,
  [ValidatePattern('^$|^[a-f0-9-]{36}$')][string]$ResumeOfLaunchId = '',
  [string]$InterruptedIntegrationResumePath = '',
  [ValidateRange(0,15)][int]$Row = 0,
  [ValidatePattern('^(codex|claude)\.(primary|fallback)$')][string]$Slot,
  [ValidatePattern('^$|^(measured|provisional|reserve|override-[a-z0-9._-]+)$')][string]$Placement = '',
  [Parameter(DontShow)][ValidatePattern('^$|^[a-f0-9]{64}$')][string]$StartRequestIdentity = '',
  [Parameter(DontShow)][string]$StartAcknowledgementPath = '',
  [Parameter(DontShow)][string]$IntegrationTargetPath = '',
  [Parameter(DontShow)][string]$IntegrationAuthorityFixturePath = '',
  [Parameter(DontShow)][string]$IntegrationPreflightObservedPath = '',
  [Parameter(DontShow)][string]$IntegrationPreflightContinuePath = '',
  [Parameter(DontShow)][string]$OwedReleaseScanObservedPath = '',
  [Parameter(DontShow)][string]$OwedReleaseScanContinuePath = '',
  [Parameter(DontShow)][string]$RoutingStateRoot = '',
  [Parameter(DontShow)][string]$RoutingLkgPath = ''
)

$ErrorActionPreference = "Stop"

if ([bool]$StartRequestIdentity -ne [bool]$StartAcknowledgementPath) {
  throw 'dispatch-lane: start acknowledgement path and request identity must be supplied together'
}
if (($ResumeAdmissionObservedPath -or $ResumeAdmissionContinuePath) -and
    (-not $ExecutablePath -or -not $ResumeAdmissionObservedPath -or -not $ResumeAdmissionContinuePath)) { throw 'dispatch-lane: resume admission barrier requires paired isolated test paths and executable override' }

. (Join-Path $PSScriptRoot 'routing-data.ps1') -Library -StateRoot $RoutingStateRoot -LkgPath $RoutingLkgPath

function Resolve-DispatchRouting {
  if ([bool]$Model -ne [bool]$Effort) { throw 'dispatch-lane: explicit -Model and -Effort must be supplied together' }
  if (-not $Model) {
    if ($Row -lt 1) { throw 'dispatch-lane: row-based selection requires -Row 1..15' }
    return Resolve-RoutingSelection -Row $Row -Harness $Harness -Slot $Slot -StateRoot $RoutingStateRoot -LkgPath $RoutingLkgPath
  }
  return Resolve-RoutingSelection -Row $Row -Harness $Harness -Model $Model -Effort $Effort -StateRoot $RoutingStateRoot -LkgPath $RoutingLkgPath
}

$routingExplicit = [bool]$Model

function Throw-DispatchAdmissionIdentityInconsistency {
  throw "dispatch-lane: admission refused because the target HEAD/index/worktree identity is inconsistent (admission-identity-inconsistency)"
}

function Invoke-DispatchAdmissionGit(
  [string]$CanonicalWorktree,
  [string[]]$Arguments,
  [string]$FailureDiagnostic
) {
  $output = @(& git -C $CanonicalWorktree @Arguments 2>$null)
  if ($LASTEXITCODE -ne 0) {
    throw $FailureDiagnostic
  }
  return @($output)
}

function Get-DispatchAdmissionIdentity([string]$CandidateWorktree) {
  $identityDiagnostic = "dispatch-lane: admission refused because the target HEAD/index/worktree identity is inconsistent (admission-identity-inconsistency)"
  $topLevelOutput = Invoke-DispatchAdmissionGit $CandidateWorktree @(
    "rev-parse", "--show-toplevel"
  ) $identityDiagnostic
  $topLevel = ($topLevelOutput -join "`n").Trim()
  $canonicalTopLevel = Get-DispatchCanonicalExistingPath $topLevel
  if ([string]::IsNullOrWhiteSpace($canonicalTopLevel)) {
    Throw-DispatchAdmissionIdentityInconsistency
  }

  $headOutput = Invoke-DispatchAdmissionGit $canonicalTopLevel @(
    "rev-parse", "--verify", "HEAD"
  ) $identityDiagnostic
  $head = ($headOutput -join "`n").Trim().ToLowerInvariant()
  if ($head -cnotmatch "^[a-f0-9]{40}$") {
    Throw-DispatchAdmissionIdentityInconsistency
  }

  $symbolicOutput = @(& git -C $canonicalTopLevel symbolic-ref --quiet HEAD 2>$null)
  $symbolicExit = $LASTEXITCODE
  if ($symbolicExit -eq 0) {
    $symbolicRef = ($symbolicOutput -join "`n").Trim()
    if ($symbolicRef -cnotmatch "^refs/heads/(.+)$") {
      Throw-DispatchAdmissionIdentityInconsistency
    }
    $branch = $Matches[1]
    $identityMode = "branch"
  } elseif ($symbolicExit -eq 1 -and @($symbolicOutput).Count -eq 0) {
    $symbolicRef = $null
    $branch = ""
    $identityMode = "immutable-head"
  } else {
    Throw-DispatchAdmissionIdentityInconsistency
  }

  [pscustomobject]@{
    CanonicalWorktree = $canonicalTopLevel
    Head = $head
    Branch = $branch
    SymbolicRef = $symbolicRef
    IdentityMode = $identityMode
  }
}

function Assert-DispatchAdmissionClean([string]$CanonicalWorktree) {
  $cleanlinessDiagnostic = "dispatch-lane: admission refused because the target worktree is not clean (admission-unclean-worktree); commit and relaunch"
  $statusOutput = @(
    & git --no-optional-locks -C $CanonicalWorktree status --porcelain=v1 --untracked-files=normal 2>$null
  )
  if ($LASTEXITCODE -ne 0 -or @($statusOutput).Count -ne 0) {
    throw $cleanlinessDiagnostic
  }
}

function Get-DispatchAdmissionWorktreeRows(
  [string]$CanonicalWorktree,
  [string]$FailureDiagnostic
) {
  $tableOutput = Invoke-DispatchAdmissionGit $CanonicalWorktree @(
    "worktree", "list", "--porcelain"
  ) $FailureDiagnostic
  $rows = @()
  $row = $null
  foreach ($line in @($tableOutput) + @("")) {
    if ($line -like "worktree *") {
      if ($null -ne $row) { $rows += [pscustomobject]$row }
      $row = [ordered]@{
        Path = $line.Substring("worktree ".Length)
        BranchRef = $null
        Detached = $false
      }
    } elseif ($null -ne $row -and $line -like "branch *") {
      $row.BranchRef = $line.Substring("branch ".Length)
    } elseif ($null -ne $row -and $line -ceq "detached") {
      $row.Detached = $true
    }
  }
  if ($null -ne $row) { $rows += [pscustomobject]$row }
  return @($rows)
}

function Assert-DispatchAdmissionExclusiveBranchAttachment(
  [pscustomobject]$Identity
) {
  $occupancyDiagnostic = "dispatch-lane: admission refused because exclusive branch attachment could not be proven (admission-branch-occupancy)"
  $rows = @(Get-DispatchAdmissionWorktreeRows $Identity.CanonicalWorktree $occupancyDiagnostic)
  $requestedBranch = if ($integrationResume) { $integrationResume.obligation.branch } else { $Identity.Branch }
  foreach ($row in @($rows | Where-Object { $_.Detached })) {
    $nativeBranch = Get-DispatchRebaseBranch $row.Path -RequestedBranch $requestedBranch
    if ($nativeBranch -and $Identity.IdentityMode -ceq 'branch' -and $nativeBranch -ceq $Identity.Branch -and
        -not (Test-DispatchSameCanonicalPath $row.Path $Identity.CanonicalWorktree)) {
      throw 'dispatch-lane: admission-branch-occupancy: original branch is in native rebase in another worktree'
    }
  }
  $targetRows = @()
  foreach ($row in $rows) {
    $rowCanonical = Get-DispatchCanonicalExistingPath $row.Path
    if (-not [string]::IsNullOrWhiteSpace($rowCanonical) -and
        (Test-DispatchSameCanonicalPath $rowCanonical $Identity.CanonicalWorktree)) {
      $targetRows += $row
    }
  }
  if ($targetRows.Count -ne 1) {
    Throw-DispatchAdmissionIdentityInconsistency
  }

  $targetRow = $targetRows[0]
  if ($Identity.IdentityMode -ceq "branch") {
    if ($targetRow.Detached -or $targetRow.BranchRef -cne $Identity.SymbolicRef) {
      Throw-DispatchAdmissionIdentityInconsistency
    }
    foreach ($row in @($rows | Where-Object {
      $_.BranchRef -ceq $Identity.SymbolicRef
    })) {
      $rowCanonical = Get-DispatchCanonicalExistingPath $row.Path
      if ([string]::IsNullOrWhiteSpace($rowCanonical)) {
        throw $occupancyDiagnostic
      }
      if (-not (Test-DispatchSameCanonicalPath $rowCanonical $Identity.CanonicalWorktree)) {
        throw "dispatch-lane: admission refused because branch '$($Identity.Branch)' is attached to another worktree (admission-branch-occupancy): $rowCanonical"
      }
    }
  } elseif (-not $targetRow.Detached -or
      -not [string]::IsNullOrWhiteSpace([string]$targetRow.BranchRef)) {
    Throw-DispatchAdmissionIdentityInconsistency
  }
}

function Assert-DispatchAdmissionIdentityConsistent(
  [pscustomobject]$Before,
  [pscustomobject]$After
) {
  if (-not (Test-DispatchSameCanonicalPath $Before.CanonicalWorktree $After.CanonicalWorktree) -or
      $Before.Head -cne $After.Head -or
      $Before.Branch -cne $After.Branch -or
      $Before.SymbolicRef -cne $After.SymbolicRef -or
      $Before.IdentityMode -cne $After.IdentityMode) {
    Throw-DispatchAdmissionIdentityInconsistency
  }
  if ($After.IdentityMode -ceq "branch") {
    $identityDiagnostic = "dispatch-lane: admission refused because the target HEAD/index/worktree identity is inconsistent (admission-identity-inconsistency)"
    $tipOutput = Invoke-DispatchAdmissionGit $After.CanonicalWorktree @(
      "rev-parse", "--verify", "$($After.SymbolicRef)^{commit}"
    ) $identityDiagnostic
    $tip = ($tipOutput -join "`n").Trim().ToLowerInvariant()
    if ($tip -cne $After.Head) {
      Throw-DispatchAdmissionIdentityInconsistency
    }
  }
}

function Assert-DispatchInterruptedVacancy {
  if (-not (Test-FleetAdmissionRecordExact (Get-ValidatedFleetAdmissionRecord $runtimeRoot) $resumeAdmission.record)) { throw 'INTEGRATION_RESUME_ADMISSION: owner changed' }
  $census = Get-LiveDispatchOwnership -RuntimeRoot $runtimeRoot -TempRoot $tempRoot -ContainerRoot (Split-Path -Parent $worktreeResolved)
  $counts = $census.health.counts
  if ($census.health.status -cne 'ok' -or $counts.candidates -ne $counts.examined -or $counts.truncated -ne 0 -or $counts.rejected -ne 0 -or $counts.probeFailures -ne 0 -or $counts.legacyLiveOwners -ne 0) { throw 'INTEGRATION_RESUME_OWNER: canonical inventory incomplete' }
  foreach ($owner in $census.activeLanes) {
    if ($owner.branch -ceq $integrationResume.obligation.branch -or (Test-DispatchSameCanonicalPath $owner.worktree $worktreeResolved)) { throw 'INTEGRATION_RESUME_OWNER: rival owner' }
  }
  foreach ($file in @(Get-ChildItem -LiteralPath $runtimeRoot -Filter 'dispatch-launch-*.json' -File)) {
    $record = Get-ValidatedDispatchOwnershipRecord $file.FullName $runtimeRoot $tempRoot
    if (-not $record) { throw 'INTEGRATION_RESUME_OWNER: unreadable claimant record' }
    if (@($census.activeLanes | Where-Object { $_.launchId -ceq $record.launchId }).Count -eq 1) { continue }
    if ($record.branch -ceq $integrationResume.obligation.branch -or (Test-DispatchSamePath $record.worktree $worktreeResolved)) {
      # A dead child does not make a surviving wrapper a vacant writer. The
      # general reducer uses child liveness; interrupted admission also checks
      # every matching wrapper and retained possible descendant explicitly.
      if ($record.state -ceq 'launching') { throw 'INTEGRATION_RESUME_OWNER: unpublished or live claimant' }
      Assert-InterruptedIntegrationTreeDead $record
    }
  }
  foreach ($file in @(Get-ChildItem -LiteralPath $runtimeRoot -Filter 'watchdog-lane-*.json' -File)) {
    $prior = Read-RebaseJson $file.FullName
    if ($prior.branch -ceq $integrationResume.obligation.branch -or (Test-DispatchSamePath $prior.worktree $worktreeResolved)) {
      Assert-InterruptedIntegrationTreeDead $prior
    }
  }
  $rows = @(Get-DispatchAdmissionWorktreeRows $worktreeResolved 'INTEGRATION_RESUME_OWNER: worktree inventory unknown')
  $targetCount = 0
  foreach ($row in $rows) {
    $canonical = Get-DispatchCanonicalExistingPath $row.Path
    if (-not $canonical) { throw 'INTEGRATION_RESUME_OWNER: worktree inventory incomplete' }
    if (Test-DispatchSameCanonicalPath $canonical $worktreeResolved) { $targetCount++; continue }
    $branchRef = $row.BranchRef
    if ($row.Detached) { $native = Get-DispatchRebaseBranch $canonical -RequestedBranch $integrationResume.obligation.branch; if ($native) { $branchRef = "refs/heads/$native" } }
    if ($branchRef -ceq "refs/heads/$($integrationResume.obligation.branch)") { throw 'INTEGRATION_RESUME_OWNER: competing logical branch' }
  }
  if ($targetCount -ne 1) { throw 'INTEGRATION_RESUME_OWNER: canonical target missing or duplicated' }
}

# Legacy explicit role/placement contracts remain caller-owned. Automatic
# selection closes the policy route against the watchdog envelope before any
# launch. Todd's protected author routes use the same override as landed
# integration authors; an otherwise-unwatchable policy placement is refused.
if ($routingExplicit) {
if ($Model -cin @('gpt-6.1-sol', 'gpt-6-luna', 'claude-opus-5-5') -and $Placement -ceq 'measured') {
  throw 'dispatch-lane: successor placement is provisional until an independently reviewed routing rebalance'
}
# Integration requests have a stricter closed author contract below, which owns
# their refusal diagnostics; neither integration path admits Sonnet.
if ($Model -ceq 'claude-sonnet-5-5' -and -not $IntegrationTargetPath -and -not $InterruptedIntegrationResumePath) {
  # Row 0 is the review/planning envelope, not an implementation routing row.
  # Review contracts still own authority; this quota never admits a reviewer.
  if ($LaneRole -eq 'review' -and ($Row -in @(11, 12) -or $ReviewTarget -eq 'controller')) {
    throw 'dispatch-lane: Sonnet 5.5 is not an admitted row-11/12 or controller reviewer'
  }
  if ($LaneRole -eq 'implementation' -and $Row -notin @(3, 10, 13)) {
    throw "dispatch-lane: Sonnet 5.5 is admitted only on rows 3, 10 and 13; row $Row is not a Sonnet row"
  }
  $sonnetQuota = $LaneRole -eq 'implementation' -and $Row -in @(3, 13) -and $Effort -ceq 'high'
  $sonnetPlacement = if ($sonnetQuota) { 'provisional' } else { 'override-Todd' }
  if ($Placement -cne $sonnetPlacement) {
    throw "dispatch-lane: Sonnet 5.5 successor placement is $sonnetPlacement for this route until measured"
  }
  if ($LaneRole -eq 'implementation' -and -not ($sonnetQuota -or
      ($Row -in @(3, 13) -and $Effort -ceq 'medium') -or ($Row -eq 10 -and $Effort -ceq 'high'))) {
    throw 'dispatch-lane: Sonnet 5.5 implementation requires rows 3/13 medium conditional or high quota, or row-10 high fallback'
  }
}
}
if ($Label -cnotmatch "^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$") {
  throw "dispatch-lane: label must be a safe 1-200 character output stem"
}

$container = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "dispatch-ownership.ps1")
. (Join-Path $PSScriptRoot 'integration-dispatch-contract.ps1')
Import-Module (Join-Path $PSScriptRoot 'landed-integration-evidence.psm1') -Force -DisableNameChecking
$integrationTarget = $null
if ($IntegrationTargetPath) {
  $integrationTarget = Read-RebaseJson $IntegrationTargetPath
  Assert-IntegrationRequest $integrationTarget
  Assert-IntegrationAuthor $Harness $Model $Effort $Row $Placement # INTEGRATION_GUARD_ROUTE
  if ($LaneRole -cne 'implementation' -or $integrationTarget.label -cne $Label -or
      $integrationTarget.requestIdentity -cne $StartRequestIdentity -or
      -not (Test-DispatchSamePath $integrationTarget.worktree $Worktree)) { throw 'INTEGRATION_REQUEST_MISMATCH' }
}
$dispatchRouting = Resolve-DispatchRouting
$Model = [string]$dispatchRouting.model
$Effort = [string]$dispatchRouting.effort
$Harness = [string]$dispatchRouting.harness
if (-not $routingExplicit) {
  if ($Placement -and $Placement -cne $dispatchRouting.placement) { throw 'ROUTING_PLACEMENT_MISMATCH: automatic selection owns policy placement' }
  $Placement = [string]$dispatchRouting.placement
  $automaticRouteKey = "$($dispatchRouting.row)|$($dispatchRouting.family)/$($dispatchRouting.effort)"
  $protectedAuthorRoutes = @(
    '7|astra/high','7|fable/high',
    '14|fable/medium','14|fable/high','14|astra/high',
    '15|fable/high','15|astra/high'
  )
  if ($LaneRole -eq 'implementation' -and $automaticRouteKey -in $protectedAuthorRoutes) {
    $Placement = 'override-Todd'
  }
  $automaticToddRoutes = $protectedAuthorRoutes + @(
    '4|opus/high','5|opus/high','6|opus/high','7|opus/high','10|opus/high',
    '3|opus/low','3|opus/medium','3|opus/high','3|sol/medium',
    '4|opus/medium','5|opus/medium','10|opus/medium','13|sol/medium',
    '13|opus/low','13|opus/medium','3|sonnet/medium','13|sonnet/medium','10|sonnet/high'
  )
  $automaticPlacementInvalid = if ($LaneRole -eq 'implementation') {
    ($Placement -cnotmatch '^(measured|provisional|override-[a-z0-9._-]+)$' -and
      -not ($Placement -ceq 'override-Todd' -and $automaticRouteKey -cin $automaticToddRoutes)) -or
    ($dispatchRouting.family -ceq 'sonnet' -and $Placement -cne $(if ($automaticRouteKey -cin @('3|sonnet/high','13|sonnet/high')) { 'provisional' } else { 'override-Todd' }))
  } else { $Placement -notmatch '^(measured|provisional|override-[a-z0-9._-]+)$' }
  if ($automaticPlacementInvalid) {
    throw 'ROUTING_PLACEMENT_UNSUPERVISED: automatic policy placement is not admitted by the watchdog'
  }
  $dispatchRouting.placement = $Placement
}
if ([string]::IsNullOrWhiteSpace($Placement) -and $dispatchRouting.placement) { $Placement = [string]$dispatchRouting.placement }
if ($LaneRole -eq 'implementation' -and ($Row -lt 1 -or [string]::IsNullOrWhiteSpace($Placement))) {
  throw 'dispatch-lane: implementation dispatch requires exact -Row and -Placement routing provenance'
}
. (Join-Path $PSScriptRoot "dispatch-claude-stream-audit.ps1"); Import-Module (Join-Path $PSScriptRoot "fleet-exclusive-admission.psm1") -Force -DisableNameChecking
$runtimeRoot = if ($TestRuntimeRoot) { [IO.Path]::GetFullPath($TestRuntimeRoot) } else { [IO.Path]::GetFullPath($PSScriptRoot) }
if ($integrationTarget -and (-not (Test-DispatchSamePath $integrationTarget.runtimeRoot $runtimeRoot) -or
    -not (Test-DispatchSamePath $IntegrationTargetPath (Join-Path $runtimeRoot "integration-request-$Label.json")) -or
    -not (Test-DispatchSamePath $PromptFile (Join-Path $runtimeRoot "$Label.prompt.txt")))) { throw 'INTEGRATION_REQUEST_PATH_MISMATCH' }
$startAcknowledgementFull = $null
if ($StartAcknowledgementPath) {
  $startAcknowledgementFull = [IO.Path]::GetFullPath($StartAcknowledgementPath)
  if (-not [string]::Equals((Split-Path -Parent $startAcknowledgementFull).TrimEnd('\','/'), $runtimeRoot.TrimEnd('\','/'), [StringComparison]::OrdinalIgnoreCase) -or
      (Split-Path -Leaf $startAcknowledgementFull) -cne "dispatch-start-$StartRequestIdentity.json") {
    throw 'dispatch-lane: start acknowledgement must be an exact runtime-root dispatch-start identity path'
  }
}
$tempRoot = if ($TestTempRoot) { [IO.Path]::GetFullPath($TestTempRoot) } else { [IO.Path]::GetFullPath([IO.Path]::GetTempPath()) }
if (($TestRuntimeRoot -or $TestTempRoot) -and -not $ExecutablePath) {
  throw "dispatch-lane: isolated runtime roots require the testing-only -ExecutablePath override"
}
foreach ($testRoot in @($runtimeRoot, $tempRoot)) {
  if (-not (Test-Path -LiteralPath $testRoot -PathType Container)) {
    throw "dispatch-lane: runtime root does not exist: $testRoot"
  }
}
$providerCredentialNames = @(
  "DIGITALOCEAN_ACCESS_TOKEN",
  "DIGITALOCEAN_TOKEN",
  "DIGITALOCEAN_CONTEXT",
  "TF_VAR_digitalocean_token",
  "DIGITALOCEAN_SPACES_ACCESS_KEY",
  "DIGITALOCEAN_SPACES_SECRET",
  "SPACES_ACCESS_ID",
  "SPACES_SECRET_KEY",
  "SPACES_ACCESS_KEY_ID",
  "SPACES_SECRET_ACCESS_KEY",
  "AWS_ACCESS_KEY_ID",
  "AWS_SECRET_ACCESS_KEY",
  "AWS_SESSION_TOKEN",
  "AWS_PROFILE",
  "AWS_SHARED_CREDENTIALS_FILE",
  "RELEASE_EVIDENCE_SPACES_ACCESS_ID",
  "RELEASE_EVIDENCE_SPACES_SECRET_KEY"
)
# Lane transcripts show the bulk of context spent on unbounded reads: whole
# runtime transcripts and ledgers, directory inventories of the runtime root,
# complete hosted CI logs and repeated tail/status polls. Each such output is
# re-read on every later model request of the lane. The contract bounds
# retrieval without changing what evidence exists or what a role may mutate.
$boundedRetrievalPreamble = "Bounded retrieval contract: prefer exact named paths and bounded line ranges. Scope searches and inventories to the needed paths and patterns, and bound displayed output with -First/-Tail, line-width limits or selected fields. This bounds output, not necessary caller discovery, exact ownership/history checks or complete evidence inspection; inspect all required evidence in bounded slices. Fetch hosted CI logs to a file, then search that file. Keep polls short, bounded and in the foreground; when waiting is necessary, repeat short bounded foreground calls and let each return. Complete evidence stays on disk; cite paths and exact lines rather than dumping raw output. Heavy-verifier, harness, role and review contracts remain authoritative.`r`n`r`n"
$claudeDisallowedTools = @("Monitor", "ScheduleWakeup", "CronCreate", "CronDelete", "CronList")
$claudeForegroundPreamble = "Claude foreground-only execution contract: keep every terminal gate and poll in this turn's foreground and bounded. Do not use Monitor, ScheduleWakeup, any Cron tool (CronCreate, CronDelete, or CronList), long --watch commands, or long sleep/poll loops. When waiting is necessary, use repeated short bounded foreground calls, let each call return, and do not report delivery complete until all terminal work is finished.`r`n`r`n"
# Review and planning lanes are both read-only against provider state, so they
# share the credential-isolation policy. They differ in what they may mutate:
# review receives no provider credentials; its bounded mechanical remedies are
# governed by contracts/review-v2.md. Planning owns GitHub issue recovery.
$credentialIsolatedRoles = @("review", "planning")
$isCredentialIsolated = $LaneRole -in $credentialIsolatedRoles

$reviewContractPath = Join-Path $PSScriptRoot "contracts/review-v2.md"
if ($LaneRole -eq "review") {
  if (-not (Test-Path -LiteralPath $reviewContractPath -PathType Leaf)) {
    throw "dispatch-lane: review contract is missing: $reviewContractPath"
  }
  $reviewContractText = [IO.File]::ReadAllText($reviewContractPath)
  if ($reviewContractText -notmatch "REVIEW_CONTRACT_VERSION: review-contract/v2") {
    throw "dispatch-lane: review contract version marker is missing or unsupported"
  }
}

$planningContractPath = Join-Path $PSScriptRoot "contracts/planning-repair-v1.md"
if ($LaneRole -eq "planning") {
  if (-not (Test-Path -LiteralPath $planningContractPath -PathType Leaf)) {
    throw "dispatch-lane: planning contract is missing: $planningContractPath"
  }
  $planningContractText = [IO.File]::ReadAllText($planningContractPath)
  if ($planningContractText -notmatch "PLANNING_CONTRACT_VERSION: planning-repair/v1") {
    throw "dispatch-lane: planning contract version marker is missing or unsupported"
  }
}

# --- validate prompt: finite, existing, non-empty (stdin EOF gotcha) ---------
$promptResolved = if ([System.IO.Path]::IsPathRooted($PromptFile)) { $PromptFile } else { Join-Path (Get-Location) $PromptFile }
if (-not (Test-Path -LiteralPath $promptResolved -PathType Leaf)) {
  throw "dispatch-lane: prompt file not found: $promptResolved"
}
if ((Get-Item -LiteralPath $promptResolved).Length -eq 0) {
  throw "dispatch-lane: prompt file is empty (a lane launched on an empty prompt hangs or no-ops): $promptResolved"
}

# --- validate worktree -------------------------------------------------------
$worktreeResolved = if ([System.IO.Path]::IsPathRooted($Worktree)) { $Worktree } else { Join-Path $container $Worktree }
if (-not (Test-Path -LiteralPath $worktreeResolved -PathType Container)) {
  throw "dispatch-lane: worktree directory not found: $worktreeResolved"
}
$requestedCanonicalWorktree = Get-DispatchCanonicalExistingPath $worktreeResolved
if ([string]::IsNullOrWhiteSpace($requestedCanonicalWorktree)) {
  Throw-DispatchAdmissionIdentityInconsistency
}
$admissionPreload = Join-Path $PSScriptRoot "heavy-admission-preload.cjs"
$admissionGuard = Join-Path $PSScriptRoot "invoke-heavy-verifier.ps1"
if (-not (Test-Path -LiteralPath $admissionPreload -PathType Leaf) -or
    -not (Test-Path -LiteralPath $admissionGuard -PathType Leaf)) {
  throw "dispatch-lane: heavy admission tooling is incomplete; refusing to launch"
}
$admissionPowerShell = Get-Command pwsh -CommandType Application -ErrorAction Stop |
  Select-Object -First 1 -ExpandProperty Source
$admissionIdentityBefore = Get-DispatchAdmissionIdentity $requestedCanonicalWorktree
if (-not (Test-DispatchSameCanonicalPath $requestedCanonicalWorktree $admissionIdentityBefore.CanonicalWorktree)) {
  Throw-DispatchAdmissionIdentityInconsistency
}
$worktreeResolved = $admissionIdentityBefore.CanonicalWorktree
$admissionLane = Split-Path -Leaf $worktreeResolved
if ($admissionLane -cnotmatch "^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$") {
  throw "dispatch-lane: worktree leaf is not a valid bounded admission lane identity: $admissionLane"
}
$integrationResume = $null
$resumeAdmission = $null
try {
if ($InterruptedIntegrationResumePath) {
  if ($integrationTarget) { throw 'INTEGRATION_RESUME_BINDING: fresh and interrupted requests are mutually exclusive' }
  foreach ($name in @('GIT_DIR','GIT_WORK_TREE','GIT_INDEX_FILE','GIT_OBJECT_DIRECTORY','GIT_ALTERNATE_OBJECT_DIRECTORIES')) {
    if ([Environment]::GetEnvironmentVariable($name)) { throw "INTEGRATION_RESUME_GIT_UNKNOWN: redirected $name" }
  }
  # Exactly two closed resume routes share one identical downstream binding:
  # the standing codex/gpt-6-astra/high/7/override-Todd author, and the
  # Todd-ruled vendor fallback claude/claude-fable-5-1/high/7/override-Todd
  # that replaces a quota-blocked or refused Astra author (4388/5743533387,
  # #8063). Any other harness, model, effort, row, role, or placement refuses.
  $astraResumeRoute = $Harness -ceq 'codex' -and $dispatchRouting.family -ceq 'astra'
  $fableResumeRoute = $Harness -ceq 'claude' -and $dispatchRouting.family -ceq 'fable'
  if ($LaneRole -cne 'implementation' -or -not ($astraResumeRoute -or $fableResumeRoute) -or $Effort -cne 'high' -or $Row -ne 7 -or $Placement -cne 'override-Todd') {
    throw 'INTEGRATION_RESUME_ROUTE: exact eligible implementation route required'
  }
  Import-Module (Join-Path $PSScriptRoot 'landed-integration-evidence.psm1') -Force -DisableNameChecking
  $integrationResume = Read-RebaseJson $InterruptedIntegrationResumePath
  foreach ($name in @("$Label.jsonl","$Label.err.log","watchdog-lane-$Label.json")) {
    if (Test-Path -LiteralPath (Join-Path $runtimeRoot $name)) { throw 'INTEGRATION_RESUME_BINDING: output identity already used' }
  }
  if (-not (Test-DispatchInterruptedBindingShape $integrationResume) -or
      -not (Test-DispatchSameCanonicalPath $integrationResume.obligation.worktree $worktreeResolved)) { throw 'INTEGRATION_RESUME_BINDING: target mismatch' }
  [void](Assert-InterruptedIntegrationResume $integrationResume $runtimeRoot)
  $resumeRequest = Get-RebaseRecordIdentity $integrationResume
  if ($StartRequestIdentity -and $StartRequestIdentity -cne $resumeRequest) { throw 'INTEGRATION_RESUME_BINDING: start request mismatch' }
  $StartRequestIdentity = $resumeRequest
  $startAcknowledgementFull = Join-Path $runtimeRoot "dispatch-start-$resumeRequest.json"
  $StartAcknowledgementPath = $startAcknowledgementFull
  if ($ResumeOfLaunchId -and $ResumeOfLaunchId -cne $integrationResume.sources.priorLaunchId) { throw 'INTEGRATION_RESUME_BINDING: prior launch mismatch' }
  $ResumeOfLaunchId = $integrationResume.sources.priorLaunchId
  if (Test-Path -LiteralPath $startAcknowledgementFull) { throw 'INTEGRATION_RESUME_BINDING: retained start request already used' }
  Assert-FleetExclusiveLeaseVacantForDispatch -RuntimeRoot $runtimeRoot
  $resumeControllerHead = (@(& git -C $container rev-parse HEAD 2>$null) -join '').Trim()
  if ($LASTEXITCODE -ne 0) { throw 'INTEGRATION_RESUME_BINDING: controller identity unknown' }
  $resumeAdmission = Enter-FleetExclusiveAdmission -RuntimeRoot $runtimeRoot -LeaseHolder "resume-$([guid]::NewGuid().ToString('N'))" -Issue 7963 -Attempt "7963-$([guid]::NewGuid().ToString('N'))" `
    -ControllerRoot (Split-Path -Parent $runtimeRoot) -ControllerHead $resumeControllerHead -Worktree $worktreeResolved -Branch $integrationResume.obligation.branch `
    -ClaimedHead $integrationResume.state.stoppedHead -Gate interrupted-canonical-integration
  if ($ResumeAdmissionObservedPath) {
    [IO.File]::WriteAllText($ResumeAdmissionObservedPath,$resumeRequest,[Text.UTF8Encoding]::new($false))
    $barrierDeadline = [datetimeoffset]::UtcNow.AddSeconds(10)
    while (-not (Test-Path -LiteralPath $ResumeAdmissionContinuePath) -and [datetimeoffset]::UtcNow -lt $barrierDeadline) { [Threading.Thread]::Sleep(20) }
    if (-not (Test-Path -LiteralPath $ResumeAdmissionContinuePath)) { throw 'INTEGRATION_RESUME_ADMISSION: native test barrier expired' }
  }
  Assert-DispatchInterruptedVacancy
  [void](Assert-InterruptedIntegrationResume $integrationResume $runtimeRoot) # RESUME_GUARD_UNDER_ADMISSION
}
if (-not $integrationResume -and $admissionIdentityBefore.IdentityMode -ceq "immutable-head" -and $LaneRole -ne "review") {
  throw "dispatch-lane: detached worktrees are admitted only for exact-HEAD review dispatches"
}

# These two independently load-bearing guards are intentionally adjacent and
# precede plan construction and every dispatch side effect. The mutant controls
# in dispatch-lane.test.ps1 delete one call at a time.
if (-not $integrationResume) {
Assert-DispatchAdmissionClean $worktreeResolved # ADMISSION_GUARD_CLEANLINESS
}
Assert-DispatchAdmissionExclusiveBranchAttachment $admissionIdentityBefore # ADMISSION_GUARD_EXCLUSIVE_BRANCH
$admissionIdentityAfter = Get-DispatchAdmissionIdentity $worktreeResolved
Assert-DispatchAdmissionIdentityConsistent $admissionIdentityBefore $admissionIdentityAfter
$admissionBranch = $admissionIdentityAfter.Branch
$admissionHead = $admissionIdentityAfter.Head
$admissionIdentityMode = $admissionIdentityAfter.IdentityMode
if ($integrationResume) {
  $admissionBranch = $integrationResume.obligation.branch
  $admissionIdentityMode = 'branch'
}
if ($integrationTarget) {
  [void](Assert-IntegrationTarget $worktreeResolved $integrationTarget.branch $integrationTarget.head $integrationTarget.newBase $integrationTarget.repository $integrationTarget.pr $IntegrationAuthorityFixturePath) # INTEGRATION_GUARD_ADMISSION
}

if ($LaneRole -eq 'review') {
  $controllerTree = @(& git -C $worktreeResolved ls-tree --name-only $admissionHead -- '.orchestrator/controller-release-battery.ps1')
  if ($LASTEXITCODE -ne 0) { throw 'dispatch-lane: controller review target identity unreadable' }
  if ($controllerTree.Count -gt 0 -and $ReviewTarget -cne 'controller') {
    throw 'dispatch-lane: controller source review requires -ReviewTarget controller and a strict prelogged tuple'
  }
}
if ($ReviewTarget -ceq 'controller') {
  if ($LaneRole -cne 'review' -or $ControllerHead -cne $admissionHead -or $ControllerIssue -lt 1 -or
      -not $AuthorAttempt -or -not $ReviewerAttempt -or -not $AuthorModel -or -not $ReviewAuthority) {
    throw 'dispatch-lane: strict controller prelaunch tuple is incomplete or does not match the target HEAD'
  }
  Import-Module (Join-Path $PSScriptRoot 'review-head-contract.psm1') -Force -DisableNameChecking
  $dispatchTuple = [pscustomobject][ordered]@{
    ts=[datetimeoffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'"); kind='dispatch'; controllerReviewSchema='controller-review-dispatch/v2'; stage='review'
    issue=$ControllerIssue; controllerHead=$ControllerHead; authorAttempt=$AuthorAttempt; reviewerAttempt=$ReviewerAttempt
    reviewAuthority=$ReviewAuthority; lane=$admissionLane; transcript="$Label.jsonl"; reviewerModel=$Model; authorModel=$AuthorModel
    effort=$Effort; row=[string]$Row; placement=$Placement; harness=$Harness
    policyGeneration=[long]$dispatchRouting.policyGeneration
    registryAuthorityDigest=[string]$dispatchRouting.registryAuthorityDigest
    family=[string]$dispatchRouting.family; slot=[string]$dispatchRouting.slot
    usedLastKnownGood=[bool]$dispatchRouting.usedLastKnownGood
  }
  if ($PSBoundParameters.ContainsKey('SupersedesReceiptRawSha256') -or $PSBoundParameters.ContainsKey('AddressedFindingIds')) {
    $dispatchTuple | Add-Member supersedesReceiptRawSha256 $SupersedesReceiptRawSha256
    $dispatchTuple | Add-Member addressedFindingIds ([object[]]@($AddressedFindingIds))
  }
  # TestRuntimeRoot isolates output only; dispatch authority belongs to this controller.
  $reviewHistory = Read-ExactHeadReviewHistory -Path (Join-Path $PSScriptRoot 'dispatch-log.jsonl')
  $prelaunchReview = Reduce-ControllerReleaseReview -Issue $ControllerIssue -ControllerHead $ControllerHead -Mode strict-v1 -History $reviewHistory -DispatchTuple $dispatchTuple
  # v1 controller-review history remains readable during the provenance
  # migration.  Retry only the exact legacy tuple when the v2-bound attempt
  # cannot join; a v2 row with partial or mismatched routing evidence still
  # fails closed because its v2 tuple is never projected into this fallback.
  if ($prelaunchReview.reason -ceq 'STRICT_PRELAUNCH_TUPLE_REQUIRED') {
    $legacyDispatchTuple = [pscustomobject][ordered]@{}
    foreach ($property in $dispatchTuple.PSObject.Properties) {
      if ($property.Name -notin @('policyGeneration','registryAuthorityDigest','family','slot','usedLastKnownGood','stage')) {
        $legacyDispatchTuple | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value
      }
    }
    $legacyDispatchTuple.controllerReviewSchema = 'controller-review-dispatch/v1'
    $legacyReview = Reduce-ControllerReleaseReview -Issue $ControllerIssue -ControllerHead $ControllerHead -Mode strict-v1 -History $reviewHistory -DispatchTuple $legacyDispatchTuple
    if ($legacyReview.state -ceq 'in-flight' -and $legacyReview.reason -ceq 'STRICT_ATTEMPT_IN_FLIGHT') { $prelaunchReview = $legacyReview }
  }
  if ($prelaunchReview.state -cne 'in-flight' -or $prelaunchReview.reason -cne 'STRICT_ATTEMPT_IN_FLIGHT') {
    throw "dispatch-lane: strict controller prelaunch tuple refused: $($prelaunchReview.reason)"
  }
} elseif ($ControllerIssue -or $ControllerHead -or $AuthorAttempt -or $ReviewerAttempt -or $AuthorModel -or $ReviewAuthority -or
    $PSBoundParameters.ContainsKey('SupersedesReceiptRawSha256') -or $PSBoundParameters.ContainsKey('AddressedFindingIds')) {
  throw 'dispatch-lane: controller tuple inputs require -ReviewTarget controller'
}

# --- output stem, clobber guard ----------------------------------------------
$stdoutPath = Join-Path $runtimeRoot "$Label.jsonl"
$stderrPath = Join-Path $runtimeRoot "$Label.err.log"
if (-not $Force) {
  foreach ($p in @($stdoutPath, $stderrPath)) {
    if ((Test-Path -LiteralPath $p) -and (Get-Item -LiteralPath $p).Length -gt 0) {
      throw "dispatch-lane: output already exists and is non-empty ($p) — a live lane may own this label; pick a new -Label or pass -Force after confirming the prior process is dead"
    }
  }
}

# --- resolve the native executable (shim gotcha) -----------------------------
function Resolve-HarnessExecutable([string]$Name) {
  $candidates = @(Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue |
      Where-Object { $_.Source -like "*.exe" })
  if ($candidates.Count -gt 0) { return $candidates[0].Source }
  throw "dispatch-lane: no native $Name.exe on PATH — the .ps1/.cmd shim must never be launched (stall-gotcha windows-start-process-codex-shim); install or add the native executable to PATH"
}
$exe = if ($ExecutablePath) { $ExecutablePath } else { Resolve-HarnessExecutable $Harness }
if ($integrationTarget -and -not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'INTEGRATION_AUTHOR_UNAVAILABLE: eligible native executable is missing' }
if ($exe -notlike "*.exe") {
  throw "dispatch-lane: resolved executable is not a native .exe: $exe (stall-gotcha windows-start-process-codex-shim)"
}
if ($TestArgumentList -and -not $ExecutablePath) {
  throw "dispatch-lane: -TestArgumentList requires the testing-only -ExecutablePath override"
}

# --- build the argument list -------------------------------------------------
$launchArguments = switch ($Harness) {
  "codex" {
    # Unattended lanes use shell/git, not ChatGPT connectors. Disable only the
    # built-in Apps MCP client; retain other MCP servers and desktop settings.
    # Pin the account pool provider: since 2026-09-23 the desktop default is
    # openai, which reaches the pool only through the desktop-login relay.
    @("exec", "-m", $Model, "-c", "model_provider=account_pool", "-c", "model_reasoning_effort=$Effort", "-c", "features.apps=false", "--json",
      "--dangerously-bypass-approvals-and-sandbox", "-C", $worktreeResolved, "-")
  }
  "claude" {
    # --print reads the prompt from redirected stdin; passing it as an argument
    # re-earns quoting bugs on multiline prompts. --dangerously-skip-permissions
    # is unconditional: a gated lane wedges on its first gh/MCP call
    # (stall 2026-07-22 #5899 decision lane).
    @("--model", $Model, "--effort", $Effort, "--print",
      "--output-format", "stream-json", "--verbose", "--dangerously-skip-permissions",
      "--disallowedTools") + $claudeDisallowedTools
  }
}
if ($TestArgumentList) {
  $launchArguments = @($TestArgumentList)
}

# --- lane role / provider isolation contract ---------------------------------
# Review is a child-only environment policy. Start-Process -Environment removes
# credential variables with $null while leaving unrelated variables inherited.
# Redirecting both config roots covers native Windows doctl (%APPDATA%) and
# POSIX doctl ($XDG_CONFIG_HOME). KUBECONFIG must name a nonexistent file
# inside the same unique root; removing it would re-enable kubectl's default
# kubeconfig fallback. PATH is deliberately not treated as a security boundary:
# Windows-native executable resolution may skip a Git Bash /tmp doctl.cmd shim
# and find doctl.exe later on PATH.
$environmentPolicy = if ($LaneRole -eq "review") {
  [ordered]@{
    mode = "digitalocean-review-isolation"
    removedVariables = @($providerCredentialNames)
    isolatedConfigRoots = @("APPDATA", "XDG_CONFIG_HOME")
    kubeconfigPolicy = "nonexistent-path-inside-isolated-temp-root"
    preservesNonProviderEnvironment = $true
    preservesGitHubAuthentication = $true
  }
} elseif ($LaneRole -eq "planning") {
  # Same provider-credential removal as review. GitHub auth is deliberately
  # preserved: issue recovery IS this lane's deliverable, and a planning lane
  # that cannot file the replacement just re-creates the gap it was sent to close.
  [ordered]@{
    mode = "planning-repair-isolation"
    removedVariables = @($providerCredentialNames)
    isolatedConfigRoots = @("APPDATA", "XDG_CONFIG_HOME")
    kubeconfigPolicy = "nonexistent-path-inside-isolated-temp-root"
    preservesNonProviderEnvironment = $true
    preservesGitHubAuthentication = $true
  }
} else {
  [ordered]@{
    mode = "inherit"
    removedVariables = @()
    isolatedConfigRoots = @()
    kubeconfigPolicy = "inherit"
    preservesNonProviderEnvironment = $true
    preservesGitHubAuthentication = $true
  }
}

# --- WSL watch-path hint (watchdog path-blindness gotcha) --------------------
$watchHint = $null
if ($stdoutPath -match "^(?<drive>[A-Za-z]):[\\/](?<rest>.*)$") {
  $watchHint = "/mnt/$($Matches.drive.ToLower())/" + ($Matches.rest -replace "\\", "/")
}

$heavyAdmissionPlan = [ordered]@{
  mode = "node-preload-and-pnpm-script-shell-existing-lock"
  preload = $admissionPreload
  lane = $admissionLane
  identityMode = $admissionIdentityMode
  guardedShapes = @(
    "repository-wide pnpm gates and aliases",
    "Playwright test entrypoints",
    "full Vitest runs without explicit test files",
    "browser/e2e and workspace script batteries",
    "workspace and application builds",
    "pnpm/npx shims, direct Node CLI files, and nested pnpm children"
  )
  unguardedShapes = @("focused Vitest files", "typecheck", "format", "focused unit commands")
  refusalExitCode = 73
}
if ($admissionIdentityMode -eq "branch") {
  $heavyAdmissionPlan.branch = $admissionBranch
  $heavyAdmissionPlan.head = $admissionHead
} else {
  $heavyAdmissionPlan.immutableHead = $admissionHead
}

$plan = [ordered]@{
  harness = $Harness
  routing = $dispatchRouting
  laneRole = $LaneRole
  executable = $exe
  arguments = @($launchArguments)
  workingDirectory = $worktreeResolved
  stdin = $promptResolved
  stdout = $stdoutPath
  stderr = $stderrPath
  watchdogWatchPath = $watchHint
  environmentPolicy = $environmentPolicy
  reviewContract = if ($LaneRole -eq "review") {
    [ordered]@{
      version = "review-contract/v2"
      path = [IO.Path]::GetFullPath($reviewContractPath)
      injected = $true
    }
  } else {
    $null
  }
  planningContract = if ($LaneRole -eq "planning") {
    [ordered]@{
      version = "planning-repair/v1"
      path = [IO.Path]::GetFullPath($planningContractPath)
      injected = $true
    }
  } else {
    $null
  }
  heavyVerifier = [ordered]@{
    entrypoint = (Join-Path $PSScriptRoot "invoke-heavy-verifier.ps1")
    supportedGates = @("verify:static", "check:static", "test:scripts", "verify:test", "test", "test:fast", "build", "verify", "verify:build", "verify:test-db")
    loadSensitiveProof = "unchanged isolated pass with material timing collapse, then one-worker/file-serial complete gate; never raise timeouts, edit product files, or skip tests"
  }
  heavyAdmission = $heavyAdmissionPlan
}

if ($DryRun) {
  $plan | ConvertTo-Json -Depth 4
  $global:LASTEXITCODE = 0
  return
}

Write-Output "dispatch-lane: launching $Harness ($Model/$Effort) in $worktreeResolved"
Write-Output "dispatch-lane: routing generation=$($dispatchRouting.policyGeneration) digest=$($dispatchRouting.registryAuthorityDigest) family=$($dispatchRouting.family) slot=$($dispatchRouting.slot) usedLastKnownGood=$($dispatchRouting.usedLastKnownGood) sourceReason=$($dispatchRouting.sourceReason)"
Write-Output "dispatch-lane: lane role $LaneRole; environment policy $($environmentPolicy.mode)"
Write-Output "dispatch-lane: output $stdoutPath"
Write-Output "dispatch-lane: watchdog watch path $watchHint"

$reviewIsolationRoot = $null
$launchPromptFile = $null
$childExitCode = $null
$launchId = $null
$ownershipRecordPath = $null
$ownershipRecord = $null
$process = $null
$watchdogSpecPath = $null
function Write-WatchdogSpec([string]$State, $ChildPid = $null, $ChildStart = $null, $ExitCode = $null) {
  if (-not $watchdogSpecPath -or -not $launchId) { return }
  $spec = [ordered]@{
    schemaVersion='watchdog-lane/v2';label=$Label
    attemptId=$(if($SemanticAttemptId){$SemanticAttemptId}else{$Label})
    relaunchCount=$WatchdogRelaunchCount;resumeOfLaunchId=$(if($ResumeOfLaunchId){$ResumeOfLaunchId}else{$null})
    harness=$Harness;model=$Model;effort=$Effort;row=[long]$Row;placement=$Placement;laneRole=$LaneRole
    originalPromptPath=[IO.Path]::GetFullPath($promptResolved);partialReportPath=[IO.Path]::GetFullPath($stdoutPath)
    errorPath=[IO.Path]::GetFullPath($stderrPath);worktree=[IO.Path]::GetFullPath($worktreeResolved).TrimEnd('\','/')
    branch=$admissionBranch;head=$admissionHead;launchId=$launchId;ownershipRecordPath=[IO.Path]::GetFullPath($ownershipRecordPath)
    launcherPid=$PID;launcherStartIdentity=Get-DispatchProcessStartIdentity $PID
    childPid=$ChildPid;childStartIdentity=$ChildStart;state=$State;exitCode=$ExitCode
    updatedAt=[DateTime]::UtcNow.ToString('o')
    policyGeneration=[long]$dispatchRouting.policyGeneration
    registryAuthorityDigest=[string]$dispatchRouting.registryAuthorityDigest
    family=[string]$dispatchRouting.family
    slot=[string]$dispatchRouting.slot
    usedLastKnownGood=[bool]$dispatchRouting.usedLastKnownGood
  }
  if ($integrationTarget) {
    $spec.schemaVersion = 'watchdog-lane/v3'
    $spec.integrationRequest = $integrationTarget
  }
  if ($integrationResume) {
    $spec.schemaVersion = 'watchdog-lane/v4'
    $spec.interruptedIntegration = $integrationResume | ConvertTo-Json -Depth 12 -Compress
  }
  $temporary="$watchdogSpecPath.$([guid]::NewGuid().ToString('N')).tmp"
  try{[IO.File]::WriteAllText($temporary,($spec|ConvertTo-Json -Compress -Depth 4),[Text.UTF8Encoding]::new($false));[IO.File]::Move($temporary,$watchdogSpecPath,$true)}finally{Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue}
}
try {
  if ($integrationTarget) {
    if ($IntegrationPreflightObservedPath -or $IntegrationPreflightContinuePath) {
      if (-not $IntegrationPreflightObservedPath -or -not $IntegrationPreflightContinuePath) { throw 'INTEGRATION_BARRIER_INVALID' }
      [IO.File]::WriteAllText($IntegrationPreflightObservedPath,'preflight-complete',[Text.UTF8Encoding]::new($false))
      $deadline=[DateTime]::UtcNow.AddSeconds(15)
      while (-not (Test-Path -LiteralPath $IntegrationPreflightContinuePath)) {
        if ([DateTime]::UtcNow -ge $deadline) { throw 'INTEGRATION_BARRIER_EXPIRED' }
        [Threading.Thread]::Sleep(25)
      }
    }
    if ((Get-RebaseRecordIdentity (Read-RebaseJson $IntegrationTargetPath)) -cne (Get-RebaseRecordIdentity $integrationTarget)) { throw 'INTEGRATION_REQUEST_MOVED' }
    [void](Assert-IntegrationTarget $worktreeResolved $integrationTarget.branch $integrationTarget.head $integrationTarget.newBase $integrationTarget.repository $integrationTarget.pr $IntegrationAuthorityFixturePath) # INTEGRATION_GUARD_PUBLICATION
    $integrationOwners = Get-LiveDispatchOwnership -RuntimeRoot $runtimeRoot -TempRoot $tempRoot -ContainerRoot $container -ProductCensus:($integrationTarget.repository -ceq 'chase-sets/chase-sets')
    if ($integrationOwners.health.status -cne 'ok' -or @($integrationOwners.activeLanes | Where-Object { $_.branch -ceq $integrationTarget.branch }).Count) { throw "INTEGRATION_OWNER_PENDING diagnostics=$(Get-DispatchBlockingDiagnostics $integrationOwners)" }
  }
  if (-not $integrationResume) { Invoke-DispatchOwnershipScavenge $runtimeRoot $tempRoot | Out-Null }
  $launchId = [guid]::NewGuid().ToString()
  $launchPromptFile = Join-Path $runtimeRoot "dispatch-heavy-verifier-$launchId.prompt.txt"
  $ownershipRecordPath = Join-Path $runtimeRoot "dispatch-launch-$launchId.json"
  $watchdogSpecPath = Join-Path $runtimeRoot "watchdog-lane-$Label.json"
  $ownershipRecord = [ordered]@{
    schemaVersion = 4
    launchId = $launchId
    laneRole = $LaneRole
    promptPath = [IO.Path]::GetFullPath($launchPromptFile)
    reviewIsolationRoot = if ($isCredentialIsolated) { [IO.Path]::GetFullPath((Join-Path $tempRoot "chase-sets-$LaneRole-$launchId")) } else { $null }
    launcherPid = $PID
    launcherStartIdentity = Get-DispatchProcessStartIdentity $PID
    recordedAt = [DateTime]::UtcNow.ToString("o")
    state = "launching"
    childPid = $null
    childStartIdentity = $null
    worktree = [IO.Path]::GetFullPath($worktreeResolved).TrimEnd("\", "/")
    lane = $admissionLane
    identityMode = $admissionIdentityMode
    branch = $(if ($admissionIdentityMode -eq "branch") { $admissionBranch } else { $null })
    head = $admissionHead
    label = $Label
    transcriptPath = [IO.Path]::GetFullPath($stdoutPath)
    policyGeneration = [long]$dispatchRouting.policyGeneration
    registryAuthorityDigest = [string]$dispatchRouting.registryAuthorityDigest
    family = [string]$dispatchRouting.family
    slot = [string]$dispatchRouting.slot
    usedLastKnownGood = [bool]$dispatchRouting.usedLastKnownGood
  }
  if ($integrationResume) {
    Assert-DispatchInterruptedVacancy
    [void](Assert-InterruptedIntegrationResume $integrationResume $runtimeRoot) # RESUME_GUARD_BEFORE_PUBLICATION
    $ownershipRecord.schemaVersion = 5
    $ownershipRecord.interruptedIntegration = $integrationResume | ConvertTo-Json -Depth 12 -Compress
  }
  Write-DispatchOwnershipRecord $ownershipRecordPath $ownershipRecord -CreateNew <# FLEET_ADMISSION_GUARD_LANE_OWNER_PUBLISHED_BEFORE_LEASE #>
  if (-not $integrationResume) {
    Assert-FleetExclusiveLeaseVacantForDispatch -RuntimeRoot $runtimeRoot <# FLEET_ADMISSION_GUARD_FLEET_LEASE_INSPECTION #>; Assert-FleetExclusiveLeaseVacantForDispatch -RuntimeRoot $runtimeRoot <# FLEET_ADMISSION_GUARD_FLEET_LEASE_REREAD #>
  } elseif (-not (Test-FleetAdmissionRecordExact (Get-ValidatedFleetAdmissionRecord $runtimeRoot) $resumeAdmission.record)) {
    throw 'INTEGRATION_RESUME_ADMISSION: changed before launch'
  }
  Write-WatchdogSpec 'launching'
  if (-not $integrationResume -and $LaneRole -eq 'implementation' -and $admissionIdentityMode -eq 'branch') {
    Import-Module (Join-Path $PSScriptRoot 'landed-integration-evidence.psm1') -Force -DisableNameChecking
    foreach ($owed in @(Get-RebaseOwed $runtimeRoot $admissionBranch $worktreeResolved)) {
      # A recovery dispatch already at R must not manufacture a start at R.
      $ancestor = @(& git -C $worktreeResolved merge-base --is-ancestor $owed.targetHead $admissionHead 2>&1)
      if ($LASTEXITCODE -eq 0 -and $ancestor.Count -eq 0) { [void](New-RebaseStart $owed $runtimeRoot $ownershipRecordPath -Prelaunch) }
    }
  }
  if ($LaneRole -eq 'implementation') {
    & (Join-Path $PSScriptRoot 'log-event.ps1') -Log dispatch -Kind dispatch -DispatchRoutingSchema watchdog-dispatch-routing/v2 `
      -DispatchAttemptId $(if($SemanticAttemptId){$SemanticAttemptId}else{$Label}) -DispatchLabel $Label -Lane $admissionLane -LaneRole implementation `
      -Transcript (Split-Path -Leaf $stdoutPath) -Harness $Harness -Model $Model -Effort $Effort -Row ([string]$Row) -Placement $Placement `
      -DispatchWorktree $worktreeResolved -DispatchBranch $admissionBranch -DispatchHead $admissionHead `
      -PolicyGeneration $dispatchRouting.policyGeneration -RegistryAuthorityDigest $dispatchRouting.registryAuthorityDigest `
      -RoutingFamily $dispatchRouting.family -RoutingSlot $dispatchRouting.slot -UsedLastKnownGood $dispatchRouting.usedLastKnownGood `
      -RoutingStateRoot $RoutingStateRoot -RoutingLkgPath $RoutingLkgPath -OutFile (Join-Path $runtimeRoot 'dispatch-log.jsonl') -NoBoard | Out-Null
  }
  $gatePreamble = "Heavy verification contract: use '$($plan.heavyVerifier.entrypoint)' for every full gate. Supported gates: $($plan.heavyVerifier.supportedGates -join ', '). It acquires and validates the exclusive lock, runs foreground, and only releases its own owner record. Direct memory-heavy Node, Playwright, Vitest, script-battery, and build commands are machine-admitted through the same lock before their command body. A timeout is load-sensitive only after an unchanged isolated timing collapse and a complete one-worker/file-serial gate; never raise timeouts, edit product files, or skip tests.`r`n`r`n"
  if ($integrationResume) {
    $gatePreamble += "Interrupted canonical integration: original logical branch '$admissionBranch', detached HEAD '$admissionHead'. Entry bytes are preserved. Only this implementation child may resolve these existing conflicts. Continue through rebase-integration.ps1 -ContinueInterruptedIntegration with the bound original Pr/ReviewedHead/NewBase/Worktree. GIT_EDITOR is noninteractive. Never start a new rebase, abort, reset, stash, skip, or normalize the worktree. A later native stop remains pending; completion requires clean attachment, original-head lease publication, and the existing native completion validator. Resume gives no PASS or continuation authority.`r`n`r`n"
  }
  $harnessPreamble = if ($Harness -eq "claude") { $claudeForegroundPreamble } else { "" }
  $reviewPreamble = if ($LaneRole -eq "review") { $reviewContractText.TrimEnd() + "`r`n`r`n" } else { "" }
  $planningPreamble = if ($LaneRole -eq "planning") { $planningContractText.TrimEnd() + "`r`n`r`n" } else { "" }
  [IO.File]::WriteAllText($launchPromptFile, $gatePreamble + $boundedRetrievalPreamble + $harnessPreamble + $reviewPreamble + $planningPreamble + [IO.File]::ReadAllText($promptResolved), [Text.UTF8Encoding]::new($false))
  $startParameters = @{
    FilePath = $exe
    ArgumentList = @($launchArguments)
    WorkingDirectory = $worktreeResolved
    RedirectStandardInput = $launchPromptFile
    RedirectStandardOutput = $stdoutPath
    RedirectStandardError = $stderrPath
    WindowStyle = "Hidden"
    PassThru = $true
  }
  if (-not (Get-Command Start-Process).Parameters.ContainsKey("Environment")) {
    throw "dispatch-lane: heavy admission requires PowerShell 7.4+ Start-Process -Environment; refusing to launch"
  }
  $originalNodeOptionsPresent = Test-Path "Env:NODE_OPTIONS"
  $originalNodeOptions = if ($originalNodeOptionsPresent) { [string]$env:NODE_OPTIONS } else { "" }
  $admissionConfiguration = [ordered]@{
    schemaVersion = 1
    guardPath = [IO.Path]::GetFullPath($admissionGuard)
    powershellPath = [IO.Path]::GetFullPath($admissionPowerShell)
    containerRoot = [IO.Path]::GetFullPath($(if ($TestRuntimeRoot) { Split-Path -Parent $worktreeResolved } else { $container }))
    worktree = [IO.Path]::GetFullPath($worktreeResolved)
    lane = $admissionLane
    originalNodeOptionsPresent = $originalNodeOptionsPresent
    originalNodeOptions = $originalNodeOptions
    originalScriptShellPresent = Test-Path "Env:npm_config_script_shell"
    originalScriptShell = if (Test-Path "Env:npm_config_script_shell") { [string]$env:npm_config_script_shell } else { "" }
  }
  if ($admissionIdentityMode -eq "branch") {
    $admissionConfiguration.branch = $admissionBranch
    $admissionConfiguration.head = $admissionHead
  } else {
    $admissionConfiguration.immutableHead = $admissionHead
  }
  $admissionEncoded = [Convert]::ToBase64String(
    [Text.Encoding]::UTF8.GetBytes(($admissionConfiguration | ConvertTo-Json -Compress))
  )
  $preloadOption = "--require=$([IO.Path]::GetFullPath($admissionPreload))"
  $childEnvironment = @{
    CHASE_SETS_INTEGRATION_RUNTIME = $runtimeRoot
    NODE_OPTIONS = $(if ([string]::IsNullOrWhiteSpace($originalNodeOptions)) { $preloadOption } else { "$originalNodeOptions $preloadOption" })
    npm_config_script_shell = [IO.Path]::GetFullPath((Get-Command node -CommandType Application -ErrorAction Stop | Select-Object -First 1 -ExpandProperty Source))
    CHASE_SETS_HEAVY_ADMISSION_CONFIG = $admissionEncoded
    CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_NODE_OPTIONS = $originalNodeOptions
    CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_SCRIPT_SHELL = $admissionConfiguration.originalScriptShell
    CHASE_SETS_HEAVY_ADMISSION_PNPM_SCRIPT_SHELL = "node-check-proxy"
  }
  if ($integrationResume) {
    $childEnvironment['CHASE_SETS_INTERRUPTED_INTEGRATION_OWNER'] = $ownershipRecordPath
    $childEnvironment['GIT_EDITOR'] = 'true'
  }
  $startParameters["Environment"] = $childEnvironment

  if ($isCredentialIsolated) {
    $reviewIsolationRoot = Join-Path $tempRoot "chase-sets-$LaneRole-$launchId"
    New-Item -ItemType Directory -Path $reviewIsolationRoot | Out-Null

    foreach ($name in $providerCredentialNames) {
      $childEnvironment[$name] = $null
    }
    $childEnvironment["APPDATA"] = $reviewIsolationRoot
    $childEnvironment["XDG_CONFIG_HOME"] = $reviewIsolationRoot
    $childEnvironment["KUBECONFIG"] = Join-Path $reviewIsolationRoot "nonexistent-kubeconfig"

    # gh defaults to %APPDATA%\GitHub CLI on Windows. Pin its original config
    # before APPDATA is isolated so stored GitHub auth and GH_*/GITHUB_* token
    # variables remain available to read-only review work.
    if ($env:GH_CONFIG_DIR) {
      $childEnvironment["GH_CONFIG_DIR"] = $env:GH_CONFIG_DIR
    } elseif ($env:APPDATA) {
      $childEnvironment["GH_CONFIG_DIR"] = Join-Path $env:APPDATA "GitHub CLI"
    }
  }

  $process = Start-Process @startParameters
  $startedRecord = [ordered]@{}
  foreach ($property in $ownershipRecord.GetEnumerator()) {
    $startedRecord[$property.Key] = $property.Value
  }
  $startedRecord.state = "started"
  $startedRecord.childPid = $process.Id
  $startedRecord.childStartIdentity = Get-DispatchProcessStartIdentity $process.Id
  if ($startedRecord.childStartIdentity) {
    $publishedRecord = Get-ValidatedDispatchOwnershipRecord $ownershipRecordPath $runtimeRoot $tempRoot
    if (Test-DispatchOwnershipRecordExact $publishedRecord $ownershipRecord) {
      Write-DispatchOwnershipRecord $ownershipRecordPath $startedRecord
      $ownershipRecord = $startedRecord
      Write-WatchdogSpec 'running' $process.Id $startedRecord.childStartIdentity
      if ($StartAcknowledgementPath) {
        $acknowledgement = [ordered]@{
          schemaVersion='dispatch-start-ack/v1';requestIdentity=$StartRequestIdentity;label=$Label
          launchId=$launchId;ownershipRecordPath=[IO.Path]::GetFullPath($ownershipRecordPath)
          worktree=[IO.Path]::GetFullPath($worktreeResolved).TrimEnd('\','/');branch=$admissionBranch;head=$admissionHead
          harness=$Harness;model=$Model;effort=$Effort;row=[long]$Row;placement=$Placement
          state='started';childPid=[long]$process.Id;childStartIdentity=$startedRecord.childStartIdentity
          policyGeneration=[long]$dispatchRouting.policyGeneration;registryAuthorityDigest=[string]$dispatchRouting.registryAuthorityDigest
          family=[string]$dispatchRouting.family;slot=[string]$dispatchRouting.slot;usedLastKnownGood=[bool]$dispatchRouting.usedLastKnownGood
        }
        if ($integrationResume) {
          $acknowledgement.schemaVersion = 'dispatch-start-ack/v2'
          $acknowledgement.interruptedIntegration = $ownershipRecord.interruptedIntegration
        }
        $acknowledgementBytes = [Text.UTF8Encoding]::new($false).GetBytes(($acknowledgement | ConvertTo-Json -Compress))
        $acknowledgementStream = [IO.File]::Open($startAcknowledgementFull,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
        try { $acknowledgementStream.Write($acknowledgementBytes,0,$acknowledgementBytes.Length);$acknowledgementStream.Flush($true) } finally { $acknowledgementStream.Dispose() }
      }
    } else {
      Write-Warning "dispatch-lane: ownership changed before child publication; preserving the record and resources"
    }
  } else {
    Write-Warning "dispatch-lane: child start identity was unavailable; retaining the launching record until the foreground child exits"
  }
  if ($resumeAdmission -and $startedRecord.childStartIdentity) {
    if (-not (Exit-FleetExclusiveAdmission $resumeAdmission)) { throw 'INTEGRATION_RESUME_ADMISSION: exact release failed' }
    $resumeAdmission = $null
  }
  Write-Output "dispatch-lane: pid $($process.Id)"
  $process.WaitForExit()
  $childExitCode = $process.ExitCode
  Write-WatchdogSpec 'exited' $process.Id $startedRecord.childStartIdentity $childExitCode
  if ($Harness -eq "claude" -and $childExitCode -eq 0) {
    $audit = Test-ClaudeStreamJsonCompletion $stdoutPath
    if (-not $audit.accepted) {
      [Console]::Error.WriteLine("dispatch-lane: Claude success rejected for label '$Label' in '$worktreeResolved'; lane ownership remains incomplete and the transcript is preserved at '$stdoutPath'.")
      foreach ($diagnostic in $audit.diagnostics) {
        [Console]::Error.WriteLine("dispatch-lane: $diagnostic")
      }
      $childExitCode = 1
    }
  }
} finally {
  if ($process) {
    $process.Dispose()
  }
  $resumeStillStopped = $false
  if ($integrationResume -and $ownershipRecordPath -and $ownershipRecord) {
    $resumeIdentity = Get-DispatchGitIdentity $worktreeResolved
    $resumeStillStopped = $resumeIdentity.status -cne 'ok' -or [string]::IsNullOrWhiteSpace($resumeIdentity.branch)
    if (-not $resumeStillStopped) {
      try {
        [void](Complete-InterruptedIntegration $integrationResume.obligation $runtimeRoot $ownershipRecordPath)
        [void](Read-RebaseCompletion $integrationResume.obligation $runtimeRoot)
      } catch {
        [Console]::Error.WriteLine("INTEGRATION_RESUME_COMPLETION: $($_.Exception.Message)")
        $childExitCode = 1
      }
    }
  }
  if (-not $resumeStillStopped -and $LaneRole -eq 'implementation' -and $admissionIdentityMode -eq 'branch' -and $ownershipRecordPath -and $ownershipRecord) {
    $consumer = Join-Path $PSScriptRoot 'landed-integration-consume.ps1'
    if (Test-Path -LiteralPath $consumer -PathType Leaf) {
      try {
        $consumerArguments = @{
          Branch = $admissionBranch; Worktree = $worktreeResolved; RuntimeRoot = $runtimeRoot
          HistoryPath = (Join-Path $runtimeRoot 'dispatch-log.jsonl')
          AcceptingOwnerRecordPath = $ownershipRecordPath; AcceptingOwnerLaunchId = $launchId
          AcceptingOwnerRecord = [ref]$ownershipRecord
        }
        if ($OwedReleaseScanObservedPath) { $consumerArguments.ReleaseScanObservedPath = $OwedReleaseScanObservedPath }
        if ($OwedReleaseScanContinuePath) { $consumerArguments.ReleaseScanContinuePath = $OwedReleaseScanContinuePath }
        & $consumer @consumerArguments | Out-Null
        if ($LASTEXITCODE -ne 0 -and ($null -eq $childExitCode -or $childExitCode -eq 0)) { $childExitCode = 1 }
      } catch {
        [Console]::Error.WriteLine("dispatch-lane: owed integration consumer failed: $($_.Exception.Message)")
        if ($null -eq $childExitCode -or $childExitCode -eq 0) { $childExitCode = 1 }
      }
    }
  }
  if ($ownershipRecordPath -and $ownershipRecord) {
    if (-not (Remove-DispatchLaunchResources $ownershipRecordPath $ownershipRecord $runtimeRoot $tempRoot)) {
      Write-Warning "dispatch-lane: exact launch cleanup was not proven; the validated ownership record was preserved for a later dispatch"
    }
  }
  if ($integrationResume -and $process -and $startedRecord.childStartIdentity) { Write-WatchdogSpec 'exited' $startedRecord.childPid $startedRecord.childStartIdentity $childExitCode }
}

exit $childExitCode
} finally {
  if ($resumeAdmission) {
    if (-not (Exit-FleetExclusiveAdmission $resumeAdmission)) { Write-Warning 'INTEGRATION_RESUME_ADMISSION: exact admission cleanup refused' }
  }
}
