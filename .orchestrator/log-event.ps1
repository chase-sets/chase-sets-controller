<#
.SYNOPSIS
Append one machine-stamped event row to an orchestrator .jsonl log
(milestone-orchestrator SKILL.md §14). Never hand-write log rows: hand-narrated
timestamps drifted ~21h in live fire (2026-07-16→18) and made cycle time — the
loop's declared optimization target — unmeasurable from its own logs.

.EXAMPLE
./log-event.ps1 -Log dispatch -Kind implementation -Issue 4331 -Lane lane-03 `
  -Harness codex -Model gpt-6.1-sol -Effort high -Row 4 -Placement provisional -Note "signal-reactive engine"

.EXAMPLE
./log-event.ps1 -Log dispatch -Kind review-complete -Pr 5597 -Outcome BLOCK_FIXABLE `
  -Model gpt-6.1-sol -AuthorModel gpt-6-luna `
  -ReviewedHead 0123456789abcdef0123456789abcdef01234567 `
  -ReviewerAttempt review-5597-01 -AuthorAttempt author-5597-03 `
  -ReviewContract review-contract/v2 -CompleteSweep -FindingIds F1,F2 `
  -Blocking 2 -Candidates 2 -NonBlocking 0 -RepairOwner author `
  -Note "all blockers probe-confirmed"
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateSet("dispatch")][string]$Log,
  # Canonical vocabulary (SKILL.md §14). Non-canonical kinds are REJECTED —
  # the first live-fire window grew ~80 distinct kinds against 20 canonical
  # and left deploy-verify turnaround measured on n=2 of 36 landings.
  # Campaign/phase narration goes in -Note on a canonical kind (usually
  # `note`), never a new kind.
  [Parameter(Mandatory)][string]$Kind,
  [object]$Issue,
  # Kept untyped until the ordinary exact-head producer boundary validates the
  # caller's original numeric shape. PowerShell rounds 1.5 when binding it
  # directly to [int], which would otherwise fabricate a different PR identity.
  [object]$Pr,
  [string]$Lane,
  # What the lane was dispatched to do. Recorded for its own sake, and read by
  # the delivery board's lane-owned states (§14): a `review` dispatch puts the
  # issue In review, anything else puts it In lane.
  [ValidateSet("implementation", "review", "planning")][string]$LaneRole,
  [string]$Harness,
  [string]$Model,
  # On review-complete / verify-complete / repair-complete: the model whose
  # output is being judged (the author lane). $Model stays the acting model
  # (the reviewer/repairer). The pair is what makes per-config first-pass
  # quality computable for the tier-3 frontier recompute (SKILL.md §14).
  [string]$AuthorModel,
  [string]$Effort,
  # The effort the run ACTUALLY used, when it differs from the requested
  # $Effort (adaptive dials, harness overrides). matrix-refresh.ps1 reads it
  # over $Effort when it keys a run to its configuration.
  [string]$EffortUsed,
  # On review-complete / verify-complete / repair-complete: the effort the
  # AUTHOR lane ran at. $Effort on those rows is the reviewer's own dial, so
  # without this a receipt scores the author's model but not its configuration
  # (model + effort), which is the routing unit since model-routing v4.13.
  # matrix-refresh.ps1 reads this first and falls back to the author's own
  # dispatch rows only when they agree. Not part of the closed strict
  # controller-review schema.
  [string]$AuthorEffort,
  [string]$Row,
  # How this config was chosen: `measured` (a rubric row backed by local data),
  # `provisional` (benchmark-seeded, under challenge), or `override-<who>`
  # (human routing). The frontier recompute scores these SEPARATELY — an
  # unlabeled override silently credits human judgment to the rubric, which is
  # how the #5863/#5864/#5869 Fable-max reviews were mis-attributed until Todd
  # said so. Provisional rows must never be read as measured results.
  [ValidatePattern('^(measured|provisional|reserve|override-[a-z0-9._-]+)$')]
  [string]$Placement,
  # Lane stream-json transcript filename. This is the JOIN KEY to
  # cost-ledger.jsonl — cost is not knowable at dispatch time, so it is
  # reconciled afterwards by cost-harvest.ps1 and matched on this.
  [string]$Transcript,
  [string]$Outcome,
  [ValidatePattern("^[a-f0-9]{40}$")][string]$LandingHead,
  [ValidatePattern("^[A-Z][A-Z0-9_]{0,127}$")][string]$RefusalReason,
  [ValidatePattern("^[a-f0-9]{64}$")][string]$PassReceiptIdentity,
  [ValidateSet("confirmed", "reconciled", "failed", "unknown")][string]$ActualEnqueueResult,
  [ValidatePattern("^[A-Z][A-Z0-9_]{0,127}$")][string]$ActualEnqueueReason,
  [string]$ActualEnqueueEntryId,
  # Closed rebase-only continuation input. Patch identities are derived from
  # immutable local Git objects; callers never supply patch text or commands.
  [ValidateSet("rebase-only-continuation/v1")][string]$ContinuationSchema,
  [ValidatePattern("^[a-f0-9]{40}$")][string]$ContinuationPredecessorHead,
  [ValidatePattern("^[a-f0-9]{40}$")][string]$ContinuationNewHead,
  [ValidatePattern("^[a-f0-9]{40}$")][string]$ContinuationNewBase,
  [ValidatePattern("^[a-f0-9]{64}$")][string]$SourcePassReceiptIdentity,
  [ValidatePattern("^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$")][string]$IntegrationLane,
  [string]$ContinuationWorktree,
  [ValidateSet("landed-integration-dispatch/v1","landed-integration-dispatch/v2")][string]$IntegrationDispatchSchema,
  [string]$IntegrationExecution,
  [string]$IntegrationAuthoritySchema,
  [string]$LineageRoot,
  [string]$AuthorityState,
  [object]$AuthorityIssue,
  [object]$AuthorityCommentId,
  [string]$Supersedes,
  [ValidateRange(1,[int]::MaxValue)][int]$LandedPr,
  [ValidatePattern("^[a-f0-9]{40}$")][string]$LandedHead,
  [ValidatePattern("^[a-f0-9]{40}$")][string]$TargetHead,
  [ValidatePattern("^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}$")][string]$TargetBranch,
  [ValidateSet("INTERSECTING","DIRTY","CONFLICTING")][string]$IntegrationReason,
  [ValidateSet("LAUNCHED","OWED_ACTIVE_WRITER")][string]$IntegrationDisposition,
  [ValidatePattern("^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$")][string]$TargetIntegrationLane,
  [string]$IntegrationWorktree,
  [ValidateSet('watchdog-relaunch/v1')][string]$WatchdogSchema,
  [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._:/-]{0,255}$')][string]$WatchdogAttemptId,
  [ValidatePattern('^[a-f0-9-]{36}$')][string]$WatchdogLaunchId,
  [ValidateSet('OWNER_DEAD','STREAM_DISCONNECTED','CODE_MODE_HOST_CLOSED','PROVIDER_QUOTA','SESSION_LIMIT')][string]$DeathSignature,
  [ValidatePattern('^[a-f0-9]{64}$')][string]$ObservationIdentity,
  [ValidateRange(0,3)][int]$RelaunchCount,
  [string]$ResumedPartial,
  [string]$WatchdogObservedAt,
  [ValidateSet('watchdog-dispatch-routing/v1','watchdog-dispatch-routing/v2')][string]$DispatchRoutingSchema,
  [object]$PolicyGeneration,
  [string]$RegistryAuthorityDigest,
  [string]$RoutingFamily,
  [string]$RoutingSlot,
  [object]$UsedLastKnownGood,
  [Parameter(DontShow)][string]$RoutingStateRoot,
  [Parameter(DontShow)][string]$RoutingLkgPath,
  [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._:/-]{0,255}$')][string]$DispatchAttemptId,
  [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$')][string]$DispatchLabel,
  [string]$DispatchWorktree,
  [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}$')][string]$DispatchBranch,
  [ValidatePattern('^[a-f0-9]{40}$')][string]$DispatchHead,
  [Parameter(DontShow)][string]$LandedIntegrationFixture,
  [Parameter(DontShow)][string]$LandedIntegrationScript=(Join-Path $PSScriptRoot 'landed-integration-dispatch.ps1'),
  # The replacement issue on a REPLAN_REPLACED row. An unlinked replacement is
  # how #5684 lost its successor: the disposition named #6105/#6106 in prose on
  # a closed PR, and nothing could join the two.
  [int]$Replacement,
  # Required structured receipt for review-complete rows. Plain BLOCK is
  # invalid: classify implementation-shaped findings as BLOCK_FIXABLE and
  # specification/feasibility findings as BLOCK_REPLAN.
  [ValidateSet("review-contract/v2")][string]$ReviewContract,
  # Planning-review receipts are a separate domain. Their reviewedHead is the
  # source artifact being planned from and never claims PR landing authority.
  [ValidateSet("planning-repair/v1")][string]$PlanningContract,
  [switch]$CompleteSweep,
  # Breaker scope (SKILL.md §12). `pipeline` breakers halt enqueue/scale-up
  # loop-wide and their open→clear span IS pipeline downtime. `artifact`
  # breakers (review-churn, two-BLOCK) halt ONE artifact's repair loop while
  # every other lane keeps running, and are discharged by the replan
  # lifecycle's terminal disposition (§7). Unscoped legacy rows are read as
  # pipeline, which is the conservative direction.
  [ValidateSet("artifact", "pipeline")][string]$BreakerScope,
  # Exact controller release identity for controller-skill review receipts.
  [ValidatePattern("^[a-f0-9]{40}$")][string]$ControllerHead,
  # Ordinary PR review receipts are a separate exact-head authorization
  # variant. Attempts are opaque identities supplied by the dispatch/launcher;
  # model families, model names, and reviewer prose are never parsed to infer
  # them. Controller-release receipts stay keyed only by ControllerHead.
  [ValidatePattern("^[a-f0-9]{40}$")][string]$ReviewedHead,
  [ValidatePattern("^[A-Za-z0-9][A-Za-z0-9._:/-]{0,255}$")][string]$ReviewerAttempt,
  [ValidatePattern("^[A-Za-z0-9][A-Za-z0-9._:/-]{0,255}$")][string]$AuthorAttempt,
  [ValidateSet("governing", "shadow", "advisory")][string]$ReviewAuthority,
  # Same-head governing v1 addenda bind these fields on both dispatch and receipt.
  [ValidatePattern('^[a-f0-9]{64}$')][string]$SupersedesReceiptRawSha256,
  [string[]]$AddressedFindingIds,
  [ValidatePattern('^[a-f0-9]{64}$')][string]$OriginalDispatchRawSha256,
  [ValidatePattern('^[a-f0-9]{64}$')][string]$OriginalTerminalRawSha256,
  [ValidatePattern('^Todd:[A-Za-z0-9][A-Za-z0-9._:/#-]{0,255}$')][string]$OperatorAuthority,
  [string[]]$FindingIds,
  [ValidateSet("author", "repair-lane", "planning-repair", "none")][string]$RepairOwner,
  [switch]$ReviewerPatch,
  [int]$Blocking = -1,
  [int]$Candidates = -1,
  [int]$NonBlocking = -1,
  # Defect-class slugs retained on lifecycle evidence for bounded retros and
  # second-bite queries.
  [string[]]$Classes,
  [string]$Note,
  # Skip this row's delivery-board write. Used by board-reconcile.ps1, which
  # already owns the board edit it is reporting, and by anyone replaying
  # history into the log after the fact.
  [switch]$NoBoard,
  # Testing override; production rows always go to the canonical logs.
  [string]$OutFile,
  # Test seam for the board wiring. -OutFile alone means "test row" and
  # suppresses the board write; supplying this re-enables it against a stub, so
  # the positive path is covered without a live board.
  [Parameter(DontShow)][string]$BoardScript
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "orchestration-log-lock.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot "review-head-contract.psm1") -Force -DisableNameChecking
. (Join-Path $PSScriptRoot 'routing-data.ps1') -Library

function Assert-ExactModelVersion([string]$Field, [string]$Value) {
  if (-not $Value) { return }
  if ($DispatchRoutingSchema -ceq 'watchdog-dispatch-routing/v2') {
    # The v2 producer validates registry admission at the closed routing boundary below.
    return
  }
  try {
    $routing = Get-RoutingData -ReadOnly
    $identity = Get-RoutingModelIdentity $routing.registry $Value
    if ($null -eq $identity) { throw "$Field '$Value' is not an exact selectable model version; aliases and family names are forbidden" }
    if (-not $identity.current) {
      $current = [string]$routing.registry.families.PSObject.Properties[$identity.family].Value.current
      throw "$Field '$Value' is retired; use $current for new rows"
    }
  } catch {
    if ($_.Exception.Message -match ' is retired; use | is not an exact selectable model version') { throw }
    throw "$Field '$Value' is not an exact selectable model version; aliases and family names are forbidden"
  }
}

function Test-SupportedPositivePr($Value) {
  if ($Value -is [string]) {
    $parsed = 0
    return [int]::TryParse(
      $Value,
      [Globalization.NumberStyles]::Integer,
      [Globalization.CultureInfo]::InvariantCulture,
      [ref]$parsed
    ) -and $parsed -ge 1
  }
  if ($Value -is [decimal]) {
    return $Value -ge 1 -and $Value -le [int]::MaxValue -and
      [decimal]::Truncate($Value) -eq $Value
  }
  if ($Value -is [double] -or $Value -is [single]) {
    $number = [double]$Value
    return -not [double]::IsNaN($number) -and -not [double]::IsInfinity($number) -and
      $number -ge 1 -and $number -le [int]::MaxValue -and [math]::Truncate($number) -eq $number
  }
  if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or
      $Value -is [int64] -or $Value -is [uint16] -or $Value -is [uint32] -or
      $Value -is [uint64]) {
    try {
      $number = [int64]$Value
      return $number -ge 1 -and $number -le [int]::MaxValue
    } catch {
      return $false
    }
  }
  return $false
}

Assert-ExactModelVersion "model" $Model
Assert-ExactModelVersion "authorModel" $AuthorModel

$hasPr = $PSBoundParameters.ContainsKey("Pr")
$rawPr = $Pr
if ($IntegrationAuthoritySchema) {
  $allowed = @('Log','Kind','IntegrationAuthoritySchema','Pr','Issue','TargetBranch','LineageRoot','TargetHead','AuthorityState','AuthorityIssue','AuthorityCommentId','OperatorAuthority','Supersedes','Note','OutFile','NoBoard','BoardScript')
  if ($Kind -cne 'rule-change' -or $IntegrationAuthoritySchema -cne 'landed-integration-authority/v1' -or
      @($PSBoundParameters.Keys | Where-Object { $_ -cnotin $allowed }).Count -or -not (Test-SupportedPositivePr $rawPr) -or -not (Test-SupportedPositivePr $Issue)) {
    throw 'AUTHORITY_INVALID: closed rule-change authority fields required'
  }
  foreach ($name in @('AuthorityIssue','AuthorityCommentId')) {
    $value=Get-Variable $name -ValueOnly
    if ($value -is [string]) {
      $parsed=0L
      if ($value -cnotmatch '^[1-9][0-9]*$' -or -not [long]::TryParse($value,[ref]$parsed)) { throw 'AUTHORITY_INVALID: positive integer required' }
      Set-Variable $name $parsed
    }
  }
} elseif (@('LineageRoot','AuthorityState','AuthorityIssue','AuthorityCommentId','Supersedes') | Where-Object { $PSBoundParameters.ContainsKey($_) }) {
  throw 'AUTHORITY_INVALID: authority fields require IntegrationAuthoritySchema'
}
if($PSBoundParameters.ContainsKey('Issue')){$Issue=[int]$Issue}
if ($hasPr) {
  # Preserve the historical [int] contract for non-review telemetry. Ordinary
  # exact-head receipts perform the stricter, non-rounding check below first.
  try { $Pr = [int]$rawPr } catch { throw "Pr '$rawPr' is not a supported whole number" }
}

$target = if ($OutFile) { $OutFile } else { Join-Path $PSScriptRoot "$Log-log.jsonl" }

function Invoke-ContinuationGit([string]$Root, [string[]]$Arguments, [string]$Failure) {
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = "git"
  $start.WorkingDirectory = $Root
  $start.UseShellExecute = $false
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  foreach ($argument in $Arguments) { [void]$start.ArgumentList.Add($argument) }
  $process = [Diagnostics.Process]::Start($start)
  try {
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw "$Failure ($($stderr.Trim()))" }
    return $stdout.Trim()
  } finally {
    $process.Dispose()
  }
}

function Get-ContinuationPatchId([string]$Root, [string]$Commit) {
  $show = Invoke-ContinuationGit $Root @(
    "show", "--format=", "--no-ext-diff", "--binary", "--first-parent", $Commit, "--"
  ) "unable to read immutable commit patch"
  if ([string]::IsNullOrWhiteSpace($show)) { throw "rebase-only continuation refuses an empty commit patch" }

  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = "git"
  $start.WorkingDirectory = $Root
  $start.UseShellExecute = $false
  $start.RedirectStandardInput = $true
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  [void]$start.ArgumentList.Add("patch-id")
  [void]$start.ArgumentList.Add("--stable")
  $process = [Diagnostics.Process]::Start($start)
  try {
    $process.StandardInput.Write($show)
    $process.StandardInput.Close()
    $stdout = $process.StandardOutput.ReadToEnd().Trim()
    $stderr = $process.StandardError.ReadToEnd().Trim()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0 -or $stdout -cnotmatch '^([a-f0-9]{40})\s+[a-f0-9]{40}$') {
      throw "rebase-only continuation patch-id probe failed ($stderr)"
    }
    return $Matches[1]
  } finally {
    $process.Dispose()
  }
}

function New-RebaseOnlyContinuationEvidence {
  if ($Kind -cne "repair-complete" -or -not $hasPr -or -not (Test-SupportedPositivePr $rawPr) -or
      -not $ReviewedHead -or -not $ContinuationPredecessorHead -or -not $ContinuationNewHead -or -not $ContinuationNewBase -or
      -not $SourcePassReceiptIdentity -or -not $IntegrationLane -or
      [string]::IsNullOrWhiteSpace($ContinuationWorktree)) {
    throw "rebase-only-continuation/v1 requires repair-complete, positive PR, reviewed/new/base heads, source PASS identity, integration lane, and worktree"
  }
  $root = [IO.Path]::GetFullPath($ContinuationWorktree).TrimEnd('\','/')
  $top = Invoke-ContinuationGit $root @("rev-parse", "--show-toplevel") "continuation worktree is not a Git worktree"
  if (-not [string]::Equals([IO.Path]::GetFullPath($top).TrimEnd('\','/'), $root, [StringComparison]::OrdinalIgnoreCase)) {
    throw "rebase-only continuation requires the canonical Git worktree root"
  }
  $liveHead = (Invoke-ContinuationGit $root @("rev-parse", "HEAD") "unable to read continuation HEAD").ToLowerInvariant()
  if ($liveHead -cne $ContinuationNewHead) { throw "rebase-only continuation new head is not the live worktree HEAD" }
  $status = Invoke-ContinuationGit $root @("status", "--porcelain=v1", "--untracked-files=normal") "unable to verify continuation worktree cleanliness"
  if (-not [string]::IsNullOrWhiteSpace($status)) { throw "rebase-only continuation requires a clean worktree" }
  [void](Invoke-ContinuationGit $root @("merge-base", "--is-ancestor", $ContinuationNewBase, $ContinuationNewHead) "continuation new base is not an ancestor of new head")
  $reviewedBase = Invoke-ContinuationGit $root @("merge-base", $ContinuationPredecessorHead, $ContinuationNewBase) "unable to derive reviewed base"
  if ($reviewedBase -cnotmatch '^[a-f0-9]{40}$') { throw "reviewed base was not an immutable commit" }

  $oldCommits = @((Invoke-ContinuationGit $root @("rev-list", "--reverse", "$reviewedBase..$ContinuationPredecessorHead") "unable to enumerate reviewed range") -split "`r?`n" | Where-Object { $_ })
  $newCommits = @((Invoke-ContinuationGit $root @("rev-list", "--reverse", "$ContinuationNewBase..$ContinuationNewHead") "unable to enumerate rebased range") -split "`r?`n" | Where-Object { $_ })
  if ($oldCommits.Count -lt 1 -or $oldCommits.Count -ne $newCommits.Count) {
    throw "rebase-only continuation commit ranges are empty or have different counts"
  }

  $pairs = [Collections.Generic.List[object]]::new()
  for ($index = 0; $index -lt $oldCommits.Count; $index++) {
    $oldPatch = Get-ContinuationPatchId $root $oldCommits[$index]
    $newPatch = Get-ContinuationPatchId $root $newCommits[$index]
    if ($oldPatch -cne $newPatch) { throw "rebase-only continuation changed patch id at commit index $index" }
    $pairs.Add([ordered]@{
      reviewedCommit = $oldCommits[$index]
      newCommit = $newCommits[$index]
      reviewedPatchId = $oldPatch
      newPatchId = $newPatch
    })
  }

  $history = Read-ExactHeadReviewHistory -Path $target
  $source = Reduce-ExactHeadReview -Pr ([int]$rawPr) -CurrentHead $ReviewedHead -History $history
  if ($source.state -cne "authorized" -or $source.latest.outcome -cne "PASS" -or
      $source.latest.reviewedHead -cne $ReviewedHead -or
      $source.latest.receiptIdentity -cne $SourcePassReceiptIdentity) {
    throw "rebase-only continuation source is not the exact qualified independent PASS"
  }
  $predecessor = Reduce-ExactHeadReview -Pr ([int]$rawPr) -CurrentHead $ContinuationPredecessorHead -History $history
  if ($predecessor.state -cne 'authorized' -or $predecessor.latest.outcome -cne 'PASS' -or
      $predecessor.latest.reviewedHead -cne $ReviewedHead -or
      $predecessor.latest.receiptIdentity -cne $SourcePassReceiptIdentity) {
    throw 'rebase-only continuation predecessor is not uniquely authorized by the immutable source PASS'
  }
  return [ordered]@{
    reviewedBase = $reviewedBase
    patchPairs = @($pairs)
    rangeDiff = "semantic-patch-equivalent"
    conflictResolution = $false
  }
}

$continuationEvidence = if ($ContinuationSchema) { New-RebaseOnlyContinuationEvidence } else { $null }
$continuationFieldsPresent = [bool]$ContinuationPredecessorHead -or [bool]$ContinuationNewHead -or [bool]$ContinuationNewBase -or
  [bool]$SourcePassReceiptIdentity -or [bool]$IntegrationLane -or [bool]$ContinuationWorktree
if (-not $ContinuationSchema -and $continuationFieldsPresent) {
  throw "continuation identity fields require -ContinuationSchema rebase-only-continuation/v1"
}
$integrationDispatchFieldsPresent = $PSBoundParameters.ContainsKey('LandedPr') -or ($Kind -cne 'landed' -and [bool]$LandedHead) -or
  [bool]$TargetHead -or [bool]$TargetBranch -or [bool]$IntegrationReason -or
  [bool]$IntegrationDisposition -or [bool]$TargetIntegrationLane -or [bool]$IntegrationWorktree
if ($IntegrationDispatchSchema) {
  if ($Kind -cne 'dispatch' -or -not $hasPr -or -not (Test-SupportedPositivePr $rawPr) -or
      $LandedPr -lt 1 -or -not $LandedHead -or -not $TargetHead -or -not $TargetBranch -or
      -not $IntegrationReason -or -not $IntegrationDisposition -or -not $TargetIntegrationLane -or
      [string]::IsNullOrWhiteSpace($IntegrationWorktree) -or -not $Harness -or -not $Model -or
      -not $Effort -or -not $Row -or -not $Placement) {
    if ($IntegrationDispatchSchema -cne 'landed-integration-dispatch/v2') { throw 'landed-integration-dispatch/v1 requires closed landed/target/configuration identity' }
  }
  if ($IntegrationDispatchSchema -ceq 'landed-integration-dispatch/v2') {
    if ($Kind -cne 'dispatch' -or -not $hasPr -or -not (Test-SupportedPositivePr $rawPr) -or -not $LandedPr -or -not $LandedHead -or -not $TargetHead -or -not $TargetBranch -or -not $IntegrationReason -or $IntegrationDisposition -cne 'OWED_ACTIVE_WRITER' -or -not $TargetIntegrationLane -or -not $IntegrationWorktree -or -not $IntegrationExecution -or $Harness -or $Model -or $Effort -or $Row -or $Placement) { throw 'integration/v2 requires owed identity and explicit execution attribution' }
    $execution=$IntegrationExecution | ConvertFrom-Json -DateKind String -ErrorAction Stop
    if ($null -ne $execution) {
      $keys=@('launchId','harness','model','effort','row','placement','routeIdentity')
      if (@($execution.PSObject.Properties.Name).Count -ne $keys.Count -or @($keys | Where-Object { $_ -cnotin $execution.PSObject.Properties.Name }).Count -or $execution.launchId -cnotmatch '^[a-f0-9-]{36}$' -or $execution.harness -cnotin @('codex','claude') -or $execution.model -cnotmatch '^(gpt-[a-z0-9.-]+|claude-[a-z0-9.-]+)$' -or $execution.effort -cnotin @('low','medium','high','xhigh','max') -or $execution.row -isnot [long] -or $execution.row -lt 1 -or $execution.row -gt 15 -or $execution.placement -cnotmatch '^(measured|provisional|override-[A-Za-z0-9._-]+)$' -or $execution.routeIdentity -cnotmatch '^[a-f0-9]{64}$') { throw 'integration/v2 invalid execution attribution' }
    }
  }
} elseif ($integrationDispatchFieldsPresent -and -not $IntegrationAuthoritySchema) {
  throw 'integration dispatch identity fields require -IntegrationDispatchSchema landed-integration-dispatch/v1'
}
if ($Kind -ceq 'landed' -and (-not $hasPr -or -not (Test-SupportedPositivePr $rawPr) -or -not $LandedHead)) {
  throw 'landed requires positive -Pr and exact -LandedHead so integration census cannot be skipped'
}
$watchdogFieldsPresent=[bool]$WatchdogAttemptId-or[bool]$WatchdogLaunchId-or[bool]$DeathSignature-or[bool]$ObservationIdentity-or
  $PSBoundParameters.ContainsKey('RelaunchCount')-or[bool]$ResumedPartial-or[bool]$WatchdogObservedAt
$watchdogRoutingFieldsPresent=$PSBoundParameters.ContainsKey('PolicyGeneration')-or[bool]$RegistryAuthorityDigest-or[bool]$RoutingFamily-or[bool]$RoutingSlot-or$PSBoundParameters.ContainsKey('UsedLastKnownGood')
if($WatchdogSchema){
  if($Kind-cnotin@('dispatch','lane-blocked')-or-not$WatchdogAttemptId-or-not$WatchdogLaunchId-or-not$DeathSignature-or-not$ObservationIdentity-or
    -not$PSBoundParameters.ContainsKey('RelaunchCount')-or-not$ResumedPartial-or-not$WatchdogObservedAt-or-not$Lane-or-not$Harness-or-not$Model-or-not$Effort-or-not$Row-or-not$Placement){throw 'watchdog-relaunch/v1 requires closed attempt, death, partial, configuration, routing, and observation identity'}
  $watchInstant=ConvertTo-ReviewInstant $WatchdogObservedAt;if($null-eq$watchInstant){throw 'watchdog observation instant is invalid'}
  if($Kind-ceq'lane-blocked'-and$Outcome-cnotin@('HARNESS_CEILING','NO_QUALIFIED_FALLBACK')){throw 'watchdog lane-blocked requires a closed terminal outcome'}
  if($watchdogRoutingFieldsPresent -and (($PolicyGeneration -isnot [long] -and $PolicyGeneration -isnot [int]) -or $PolicyGeneration -lt 1 -or
      $RegistryAuthorityDigest -cnotmatch '^[a-zA-Z0-9._:-]{1,128}$' -or $RoutingFamily -cnotmatch '^[a-z0-9][a-z0-9._-]{0,63}$' -or
      $RoutingSlot -cnotmatch '^(explicit|(codex|claude)\.(primary|fallback))$' -or $UsedLastKnownGood -isnot [bool])) {
    throw 'ROUTING_EVIDENCE_INVALID: watchdog provenance incomplete'
  }
}elseif($watchdogFieldsPresent){throw 'watchdog fields require -WatchdogSchema watchdog-relaunch/v1'}
$dispatchRoutingFieldsPresent=[bool]$DispatchAttemptId-or[bool]$DispatchLabel-or[bool]$DispatchWorktree-or[bool]$DispatchBranch-or[bool]$DispatchHead
if ($DispatchRoutingSchema -ceq 'watchdog-dispatch-routing/v2') {
  . (Join-Path $PSScriptRoot 'routing-data.ps1') -Library -StateRoot $RoutingStateRoot -LkgPath $RoutingLkgPath
  if ($PolicyGeneration -isnot [long] -and $PolicyGeneration -isnot [int]) { throw 'ROUTING_EVIDENCE_INVALID: policyGeneration' }
  if ($PolicyGeneration -lt 1 -or $RegistryAuthorityDigest -cnotmatch '^[a-zA-Z0-9._:-]{1,128}$' -or
      $RoutingFamily -cnotmatch '^[a-z0-9][a-z0-9._-]{0,63}$' -or
      $RoutingSlot -cnotmatch '^(explicit|(codex|claude)\.(primary|fallback))$' -or $UsedLastKnownGood -isnot [bool]) {
    throw 'ROUTING_EVIDENCE_INVALID: generation, digest, family, slot and LKG flag required'
  }
  $selection = Resolve-RoutingSelection -Row ([int]$Row) -Harness $Harness -Model $Model -Effort $Effort -ReadOnly
  if ($selection.family -cne $RoutingFamily) { throw 'ROUTING_EVIDENCE_INVALID: family identity' }
} elseif (-not $WatchdogSchema -and ($PSBoundParameters.ContainsKey('PolicyGeneration') -or $RegistryAuthorityDigest -or $RoutingFamily -or
          $RoutingSlot -or $PSBoundParameters.ContainsKey('UsedLastKnownGood'))) {
  throw 'ROUTING_EVIDENCE_INVALID: dispatch routing v2 required'
}
if($DispatchRoutingSchema){
  if($Kind-cne'dispatch'-or-not$DispatchAttemptId-or-not$DispatchLabel-or-not$Lane-or$LaneRole-cne'implementation'-or-not$Transcript-or-not$Harness-or-not$Model-or-not$Effort-or-not$Row-or-not$Placement-or
    [string]::IsNullOrWhiteSpace($DispatchWorktree)-or-not$DispatchBranch-or-not$DispatchHead){throw 'watchdog-dispatch-routing/v1 requires closed attempt, lane, transcript, configuration, worktree, branch, and head identity'}
}elseif($dispatchRoutingFieldsPresent){throw 'dispatch routing fields require -DispatchRoutingSchema watchdog-dispatch-routing/v1'}

$strictMarkerPath = Join-Path $PSScriptRoot "controller-review-strict-v1-capability.json"
$controllerCorrection = $Kind -ceq 'controller-review-audit-correction'
if ($controllerCorrection) {
  if (-not $ControllerHead -or -not $OriginalDispatchRawSha256 -or -not $OperatorAuthority) {
    throw 'controller audit correction requires exact head, the original dispatch raw row hash (plus the original terminal raw row hash for a dispatch+terminal pair), and explicit -OperatorAuthority Todd:<reference>'
  }
} elseif ($OriginalDispatchRawSha256 -or $OriginalTerminalRawSha256 -or ($OperatorAuthority -and -not $IntegrationAuthoritySchema)) {
  throw 'audit correction fields require -Kind controller-review-audit-correction'
}
$controllerReviewKind = $Kind -cin @("dispatch", "review-complete", "controller-review-audit-correction")
$strictController = $controllerReviewKind -and [bool]$ControllerHead -and (
  [bool]$ReviewAuthority -or [bool]$ReviewerAttempt -or [bool]$AuthorAttempt -or
  (Test-Path -LiteralPath $strictMarkerPath -PathType Leaf)
)
$strictRoutingPresent = $PSBoundParameters.ContainsKey('PolicyGeneration') -or [bool]$RegistryAuthorityDigest -or
  [bool]$RoutingFamily -or [bool]$RoutingSlot -or $PSBoundParameters.ContainsKey('UsedLastKnownGood')
$controllerAddendum = $PSBoundParameters.ContainsKey('SupersedesReceiptRawSha256') -or $PSBoundParameters.ContainsKey('AddressedFindingIds')
if ($controllerAddendum -and (-not $strictController -or $controllerCorrection -or $strictRoutingPresent -or
    $ReviewAuthority -cne 'governing' -or -not $SupersedesReceiptRawSha256 -or @($AddressedFindingIds).Count -lt 1)) {
  throw 'controller addendum requires governing strict-v1 dispatch/receipt, predecessor receipt hash and addressed finding IDs'
}
if ($strictController -and $strictRoutingPresent) {
  if ($PolicyGeneration -isnot [long] -and $PolicyGeneration -isnot [int]) { throw 'ROUTING_EVIDENCE_INVALID: strict policyGeneration' }
  if ($PolicyGeneration -lt 1 -or $RegistryAuthorityDigest -cnotmatch '^[a-zA-Z0-9._:-]{1,128}$' -or
      $RoutingFamily -cnotmatch '^[a-z0-9][a-z0-9._-]{0,63}$' -or
      $RoutingSlot -cnotmatch '^(explicit|(codex|claude)\.(primary|fallback))$' -or $UsedLastKnownGood -isnot [bool]) {
    throw 'ROUTING_EVIDENCE_INVALID: strict review provenance incomplete'
  }
}
$claimsPlanningReview = $Kind -ceq "review-complete" -and (
  $LaneRole -ceq "planning" -or -not [string]::IsNullOrWhiteSpace($PlanningContract)
)
$planningReview = $claimsPlanningReview -and
  $LaneRole -ceq "planning" -and $PlanningContract -ceq "planning-repair/v1"

if ($PlanningContract -and $Kind -cne "review-complete") {
  throw "-PlanningContract is valid only for review-complete planning receipts"
}

if ($ControllerHead -and ($Kind -eq "dispatch" -or $controllerCorrection) -and $strictController) {
  if (-not $PSBoundParameters.ContainsKey("Issue") -or $Issue -lt 1) { throw "strict controller dispatch requires positive -Issue" }
  if ($LaneRole -ne "review") { throw "strict controller dispatch requires -LaneRole review" }
  foreach ($required in @("Lane","Transcript","Model","AuthorModel","Effort","Row","Placement","Harness","ReviewerAttempt","AuthorAttempt","ReviewAuthority")) {
    if (-not $PSBoundParameters.ContainsKey($required) -or [string]::IsNullOrWhiteSpace([string]$PSBoundParameters[$required])) { throw "strict controller dispatch requires -$required" }
  }
  if ([string]::Equals($ReviewerAttempt, $AuthorAttempt, [StringComparison]::OrdinalIgnoreCase)) { throw "strict controller dispatch requires distinct attempts" }
  if ($Outcome -or $ReviewContract -or $CompleteSweep -or $FindingIds -or $Blocking -ge 0 -or $Candidates -ge 0 -or $NonBlocking -ge 0) {
    throw "strict controller dispatch refuses terminal-only fields"
  }
}

$canonicalKinds = @(
  "dispatch", "lane-complete", "lane-blocked", "review-complete", "controller-review-audit-correction",
  "verify-complete", "repair-complete", "enqueue", "dequeue", "landed",
    "deploy-verified", "stall", "landing-stall", "breaker-open", "breaker-clear",
  "decision-filed", "decision-resolved", "scale", "escaped-defect",
    "rule-change", "gc"
  )
if ($Kind -notin $canonicalKinds) {
  $hint = $canonicalKinds | Where-Object { $k = $_; ($Kind -split "[-_]" | Where-Object { $k -match [regex]::Escape($_) }).Count -gt 0 } | Select-Object -First 3
  $hintText = if ($hint) { " Closest canon: $($hint -join ', ')." } else { "" }
  throw "kind '$Kind' is not canonical (SKILL.md §14) — row refused.$hintText Attach bounded detail with -Note to the owning lifecycle kind. Canon: $($canonicalKinds -join ', ')"
}

$landingStallFieldsPresent = [bool]$LandingHead -or [bool]$RefusalReason -or [bool]$PassReceiptIdentity -or
  [bool]$ActualEnqueueResult -or [bool]$ActualEnqueueReason -or [bool]$ActualEnqueueEntryId
if ($Kind -ceq "landing-stall") {
  if (-not $hasPr -or -not (Test-SupportedPositivePr $rawPr) -or -not $LandingHead -or
      -not $RefusalReason -or -not $PassReceiptIdentity -or -not $ActualEnqueueResult -or
      -not $ActualEnqueueReason) {
    throw "landing-stall requires positive -Pr, exact head and PASS identity, refusal reason, and actual enqueue result"
  }
  if ($ActualEnqueueEntryId -and $ActualEnqueueEntryId -cnotmatch '^[A-Za-z0-9_=-]+$') {
    throw "landing-stall actual enqueue entry id is invalid"
  }
  if ($ActualEnqueueResult -in @("confirmed","reconciled") -and -not $ActualEnqueueEntryId) {
    throw "a confirmed landing-stall enqueue requires its actual queue entry id"
  }
} elseif ($landingStallFieldsPresent) {
  throw "landing-stall identity fields are valid only with -Kind landing-stall"
}

if ($AuthorEffort -and $strictController) {
  throw "-AuthorEffort is not part of the closed strict controller-review schema; a controller release review scores no author configuration"
}
if ($AuthorEffort -and -not $AuthorModel) {
  throw "-AuthorEffort requires -AuthorModel: an effort names a configuration only together with its exact model"
}

if ($Kind -eq "review-complete") {
  $reviewOutcomes = @("PASS", "BLOCK_FIXABLE", "BLOCK_REPLAN", "SKIP")
  if ($Outcome -notin $reviewOutcomes) {
    throw "review-complete outcome '$Outcome' is invalid; use PASS, BLOCK_FIXABLE, BLOCK_REPLAN, or SKIP"
  }
  if ($claimsPlanningReview -and -not $planningReview) {
    throw "planning review-complete requires both -LaneRole planning and -PlanningContract planning-repair/v1"
  }
  if ($planningReview) {
    if ($hasPr -or $ReviewContract -or $ControllerHead -or $ReviewAuthority) {
      throw "planning review-complete refuses PR and PR/controller review authority fields"
    }
    if (-not $PSBoundParameters.ContainsKey("Issue") -or $Issue -lt 1) {
      throw "planning review-complete requires positive -Issue"
    }
  } elseif ($ReviewContract -ne "review-contract/v2") {
    throw "ordinary and controller review-complete require -ReviewContract review-contract/v2"
  }
  if (-not $CompleteSweep) {
    throw "review-complete requires -CompleteSweep; one-finding-per-round reviews are invalid"
  }
  if (-not $Model -or -not $AuthorModel) {
    throw "review-complete requires exact -Model and -AuthorModel versions"
  }
  if ($ControllerHead -and $ReviewedHead) {
    throw "controllerHead and ordinary PR reviewed-head authority are separate receipt variants"
  }
  if ($planningReview) {
    if (-not $ReviewedHead) {
      throw "planning review-complete requires exact lowercase 40-hex source -ReviewedHead"
    }
    if (-not $ReviewerAttempt -or -not $AuthorAttempt) {
      throw "planning review-complete requires explicit -ReviewerAttempt and -AuthorAttempt identities"
    }
    if ([string]::Equals($ReviewerAttempt, $AuthorAttempt, [StringComparison]::OrdinalIgnoreCase)) {
      throw "planning review-complete requires independent attempt identities; reviewer and author attempts are equal"
    }
    foreach ($countParameter in @("Blocking", "Candidates", "NonBlocking")) {
      if (-not $PSBoundParameters.ContainsKey($countParameter) -or
          [int]$PSBoundParameters[$countParameter] -lt 0) {
        throw "planning review-complete requires structured -Blocking, -Candidates, and -NonBlocking counts"
      }
    }
  } elseif ($strictController) {
    if (-not $PSBoundParameters.ContainsKey("Issue") -or $Issue -lt 1) { throw "strict controller review-complete requires positive -Issue" }
    if ($LaneRole -ne "review") { throw "strict controller review-complete requires -LaneRole review" }
    foreach ($required in @("Lane","Transcript","Model","AuthorModel","Effort","Row","Placement","Harness","ReviewerAttempt","AuthorAttempt","ReviewAuthority")) {
      if (-not $PSBoundParameters.ContainsKey($required) -or [string]::IsNullOrWhiteSpace([string]$PSBoundParameters[$required])) { throw "strict controller review-complete requires -$required" }
    }
    if ([string]::Equals($ReviewerAttempt, $AuthorAttempt, [StringComparison]::OrdinalIgnoreCase)) { throw "strict controller review-complete requires distinct attempts" }
    foreach ($countParameter in @("Blocking", "Candidates", "NonBlocking")) {
      if (-not $PSBoundParameters.ContainsKey($countParameter) -or [int]$PSBoundParameters[$countParameter] -lt 0 -or [int]$PSBoundParameters[$countParameter] -gt 10000) {
        throw "strict controller review-complete requires bounded -Blocking, -Candidates, and -NonBlocking counts"
      }
    }
  } elseif (-not $ControllerHead) {
    if (-not $hasPr) {
      throw "ordinary review-complete requires -Pr"
    }
    if (-not (Test-SupportedPositivePr $rawPr)) {
      throw "ordinary review-complete requires -Pr as a positive supported whole number"
    }
    if (-not $ReviewedHead) {
      throw "ordinary review-complete requires exact lowercase 40-hex -ReviewedHead"
    }
    if (-not $ReviewerAttempt -or -not $AuthorAttempt) {
      throw "ordinary review-complete requires explicit -ReviewerAttempt and -AuthorAttempt identities"
    }
    if ([string]::Equals($ReviewerAttempt, $AuthorAttempt, [StringComparison]::OrdinalIgnoreCase)) {
      throw "ordinary review-complete requires independent attempt identities; reviewer and author attempts are equal"
    }
    foreach ($countParameter in @("Blocking", "Candidates", "NonBlocking")) {
      if (-not $PSBoundParameters.ContainsKey($countParameter) -or
          [int]$PSBoundParameters[$countParameter] -lt 0) {
        throw "ordinary review-complete requires structured -Blocking, -Candidates, and -NonBlocking counts"
      }
    }
  }
  $ids = @($FindingIds | Where-Object { $_ })
  if ($ReviewedHead -or $strictController) {
    if (@($ids | Where-Object { [string]$_ -cnotmatch "^[A-Z][A-Z0-9._-]{0,63}$" }).Count -gt 0) {
      throw "ordinary review-complete requires stable uppercase structured -FindingIds values"
    }
    if (@($ids | Sort-Object -Unique).Count -ne $ids.Count) {
      throw "ordinary review-complete refuses duplicate -FindingIds values"
    }
  }
  if ($Outcome -in @("BLOCK_FIXABLE", "BLOCK_REPLAN")) {
    if ($Blocking -lt 1 -or $ids.Count -ne $Blocking) {
      throw "$Outcome requires one stable -FindingIds entry per blocking finding"
    }
    if ($Outcome -eq "BLOCK_FIXABLE" -and $RepairOwner -notin @("author", "repair-lane")) {
      throw "BLOCK_FIXABLE requires -RepairOwner author or repair-lane"
    }
    if ($Outcome -eq "BLOCK_REPLAN" -and $RepairOwner -ne "planning-repair") {
      throw "BLOCK_REPLAN requires -RepairOwner planning-repair"
    }
  } elseif ($Blocking -gt 0 -or $ids.Count -gt 0) {
    throw "$Outcome cannot carry blocking findings"
  }
}

# --- Replan-lifecycle outcome canon (SKILL.md §14) ---------------------------
# `outcome` was free text on every kind except review-complete, and the replan
# state alone accumulated 13 spellings in one live-fire window (REPLAN,
# REPLAN_PARK, PARKED_REPLAN, CLOSED_REPLAN, POST_CAP_REPLAN, ...). That made
# replan debt uncountable, which is how #5616 and #5684 sat with closed PRs and
# no record on the owning issue. Normalize the family here rather than growing
# new event kinds: §14 shrank the kind vocabulary from ~80 to 20 deliberately.
# Only replan-family values are constrained — every unrelated outcome passes
# through untouched, so a running orchestrator can never be broken by this gate.
$replanCanon = @(
  "REPLAN_REQUIRED",  # artifact stopped; the owning issue needs a planning pass
  "REPLAN_STARTED",   # a planning pass is dispatched and active
  "REPLAN_REPLACED",  # replacement filed and linked; original is tracking-only
  "REPLAN_COMPLETE",  # replacement landed and satisfied the original's outcome
  "PARKED_DECISION"   # blocked on a decision issue (NOT the same as replan)
)
$replanAliases = @{
  "REPLAN"                           = "REPLAN_REQUIRED"
  "REPLAN_PARK"                      = "REPLAN_REQUIRED"
  "PARKED_REPLAN"                    = "REPLAN_REQUIRED"
  "CLOSED_REPLAN"                    = "REPLAN_REQUIRED"
  "POST_CAP_REPLAN"                  = "REPLAN_REQUIRED"
  "REPLAN_JUDGMENT"                  = "REPLAN_STARTED"
  "REPLAN_EXECUTION"                 = "REPLAN_STARTED"
  "REPLAN_AUDIT_STARTED"             = "REPLAN_STARTED"
  "APPROVED_REPLAN"                  = "REPLAN_STARTED"
  "BOUNDED_REPLAN_APPROVED"          = "REPLAN_STARTED"
  "BOUNDED_REPLANNING_PREAUTHORIZED" = "REPLAN_STARTED"
}

$outcomeRaw = $Outcome
if ($Outcome -and $Kind -ne "review-complete") {
  $upper = $Outcome.ToUpperInvariant()
  # BLOCK_REPLAN is a review-CONTRACT verdict that happens to contain the word,
  # not a replan-LIFECYCLE state. Without this exemption the gate below threw on
  # every `verify-complete -Outcome BLOCK_REPLAN`, because the value is in
  # neither the canon nor the alias map — a bookkeeping gate refusing a valid
  # contract outcome.
  if (($upper -match "REPLAN" -or $upper -eq "PARKED_DECISION") -and $upper -notlike "BLOCK_*") {
    $normalized =
      if ($replanCanon -contains $upper) { $upper }
      elseif ($replanAliases.ContainsKey($upper)) { $replanAliases[$upper] }
      elseif ($upper -match '^REPLAN_[0-9]+$') { "REPLAN_REPLACED" }
      else { $null }
    if (-not $normalized) {
      throw "outcome '$Outcome' is a replan-family value with no canonical mapping (SKILL.md §14). Use one of: $($replanCanon -join ', '). Narration belongs in -Note."
    }
    $Outcome = $normalized
  }
}

# --- Verify-outcome canon (SKILL.md §14) -------------------------------------
# `review-complete` outcomes have been constrained since the review contract
# landed, but `verify-complete` was left free text and drifted to 27 spellings
# in one window — lowercase `block`/`pass` beside PASS_CI, BLOCKED_MECHANICAL
# and TIMEOUT_ONLY_PENDING_DISCRIMINATOR. This is the same drift that made
# replan debt uncountable, and here it corrupts model routing directly: the
# rubric reads verify outcomes as per-config author block rate.
#
# The distinction that matters is MECHANICAL vs AUTHOR. A harness fault, a
# prompt block, or a failure that reproduces on clean main is not a defect in
# the author's work, but every one of them starts with "BLOCK"/"FAILED" and so
# scored as an author block — biasing every per-config rate UPWARD, against
# whichever config happened to draw the flaky infrastructure.
#
# Normalizes rather than rejects, exactly like the replan canon above: a
# running orchestrator must never be taken down by a bookkeeping gate.
# Deliberately NO alias is guessed for values whose ownership is genuinely
# ambiguous (BLOCKED_ON_PRODUCT_DEFECTS); those pass through and are excluded
# from rates downstream rather than being scored as a win or a loss.
$verifyCanon = @("PASS", "BLOCK", "BLOCK_MECHANICAL", "INDETERMINATE")
$verifyAliases = @{
  # Author-quality passes.
  "PASS_CI" = "PASS"; "PASS_SERIALIZED" = "PASS"; "PASS_EXTERNAL_FLAKE" = "PASS"
  "SHIPPED" = "PASS"; "SHIPPED_LOCAL_META" = "PASS"
  "RECOVERED_CURRENT_RELEASE" = "PASS"
  # Author-quality blocks: the work itself needs repair.
  "READY_FOR_REPAIR" = "BLOCK"; "REJECT" = "BLOCK"; "FAILED" = "BLOCK"
  # Not the author's defect — excluded from author block rate.
  "BLOCKED_MECHANICAL" = "BLOCK_MECHANICAL"
  "MECHANICAL_PROMPT_BLOCK" = "BLOCK_MECHANICAL"
  "FAILED_CLEAN_MAIN" = "BLOCK_MECHANICAL"
  # Load/timeout noise that discriminates nothing about the artifact.
  "LOAD_SENSITIVE" = "INDETERMINATE"; "GREEN_LOAD_DISCRIMINATED" = "INDETERMINATE"
  "HOST_LOAD_NONDISCRIMINATING" = "INDETERMINATE"
  "TIMEOUT_ONLY_PENDING_DISCRIMINATOR" = "INDETERMINATE"
  "RETRY" = "INDETERMINATE"; "SKIP" = "INDETERMINATE"
}
if ($Kind -eq "verify-complete" -and $Outcome -and $Outcome -notin $replanCanon) {
  $vUpper = $Outcome.ToUpperInvariant()
  if ($verifyCanon -contains $vUpper) { $Outcome = $vUpper }
  elseif ($verifyAliases.ContainsKey($vUpper)) { $Outcome = $verifyAliases[$vUpper] }
}

if ($Outcome -in $replanCanon) {
  # The PR is closed evidence; the ISSUE is what recovery tracks. A replan row
  # carrying only `pr` is unrecoverable once the PR drops off the frontier —
  # exactly the #5616 failure.
  if (-not $PSBoundParameters.ContainsKey("Issue")) {
    throw "$Outcome requires -Issue (the OWNING issue, not just the PR): recovery tracks the issue, and a pr-only replan row is how #5616 was lost"
  }
  if ($Outcome -eq "REPLAN_REPLACED" -and -not $PSBoundParameters.ContainsKey("Replacement")) {
    throw "REPLAN_REPLACED requires -Replacement <issue> naming the successor; an unlinked replacement cannot be reconciled"
  }
  if ($Outcome -eq "PARKED_DECISION" -and -not $Note) {
    throw "PARKED_DECISION requires -Note naming the blocking decision issue so decision-resolved can write back (#5748 parked 4 days past its own discharge)"
  }
}

$eventTs = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
if ($IntegrationAuthoritySchema) {
  $entry = [ordered]@{ts=$eventTs;kind='rule-change';integrationAuthoritySchema=$IntegrationAuthoritySchema;pr=[int]$rawPr;issue=$Issue
    targetBranch=$TargetBranch;lineageRoot=$LineageRoot;targetHead=$TargetHead;authorityState=$AuthorityState
    authorityIssue=$AuthorityIssue;authorityCommentId=$AuthorityCommentId;operatorAuthority=$(if($OperatorAuthority){$OperatorAuthority}else{$null})}
  if($PSBoundParameters.ContainsKey('Supersedes')){$entry.supersedes=$Supersedes}
  if($PSBoundParameters.ContainsKey('Note')){$entry.note=$Note}
} elseif ($Kind -ceq "landing-stall") {
  $entry = [ordered]@{
    ts = $eventTs
    kind = "landing-stall"
    landingStallSchema = "landing-stall/v1"
    pr = [int]$rawPr
    head = $LandingHead
    refusalReason = $RefusalReason
    passReceiptIdentity = $PassReceiptIdentity
    enqueue = [ordered]@{
      attempted = $true
      result = $ActualEnqueueResult
      reason = $ActualEnqueueReason
      entryId = if ($ActualEnqueueEntryId) { $ActualEnqueueEntryId } else { $null }
      expectedHeadOid = $LandingHead
      jump = $false
    }
  }
} elseif ($strictController) {
  $schema = if ($controllerCorrection) { "controller-review-audit-correction/v1" } elseif ($strictRoutingPresent) {
    if ($Kind -eq "dispatch") { "controller-review-dispatch/v2" } else { "controller-review-receipt/v2" }
  } elseif ($Kind -eq "dispatch") { "controller-review-dispatch/v1" } else { "controller-review-receipt/v1" }
  $entry = [ordered]@{
    ts = $eventTs
    kind = $Kind
    controllerReviewSchema = $schema
    issue = $Issue
    controllerHead = $ControllerHead
    authorAttempt = $AuthorAttempt
    reviewerAttempt = $ReviewerAttempt
    reviewAuthority = $ReviewAuthority
    lane = $Lane
    transcript = $Transcript
    reviewerModel = $Model
    authorModel = $AuthorModel
    effort = $Effort
    row = $Row
    placement = $Placement
    harness = $Harness
  }
  if ($schema -in @('controller-review-dispatch/v2','controller-review-receipt/v2')) { $entry.stage = 'review' }
  if ($controllerAddendum) {
    $entry.supersedesReceiptRawSha256 = $SupersedesReceiptRawSha256
    $entry.addressedFindingIds = [object[]]@($AddressedFindingIds)
  }
  if ($Kind -eq "review-complete") {
    $entry.reviewContract = $ReviewContract
    $entry.completeSweep = [bool]$CompleteSweep
    $entry.outcome = $Outcome
    $entry.findingIds = [object[]]@($FindingIds | Where-Object { $_ })
    $entry.findings = [ordered]@{ blocking=$Blocking; candidates=$Candidates; nonBlocking=$NonBlocking }
  }
  if ($controllerCorrection) {
    $entry.originalDispatchRawSha256 = $OriginalDispatchRawSha256
    if ($OriginalTerminalRawSha256) { $entry.originalTerminalRawSha256 = $OriginalTerminalRawSha256 }
    $entry.operatorAuthority = $OperatorAuthority
  }
  if ($strictRoutingPresent) {
    if (($PolicyGeneration -isnot [long] -and $PolicyGeneration -isnot [int]) -or $PolicyGeneration -lt 1 -or
        $RegistryAuthorityDigest -cnotmatch '^[a-zA-Z0-9._:-]{1,128}$' -or $RoutingFamily -cnotmatch '^[a-z0-9][a-z0-9._-]{0,63}$' -or
        $RoutingSlot -cnotmatch '^(explicit|(codex|claude)\.(primary|fallback))$' -or $UsedLastKnownGood -isnot [bool]) {
      throw 'ROUTING_EVIDENCE_INVALID: strict review provenance incomplete'
    }
    $entry.policyGeneration=[long]$PolicyGeneration;$entry.registryAuthorityDigest=$RegistryAuthorityDigest
    $entry.family=$RoutingFamily;$entry.slot=$RoutingSlot;$entry.usedLastKnownGood=[bool]$UsedLastKnownGood
  }
} elseif ($ContinuationSchema) {
  $entry = [ordered]@{
    ts = $eventTs
    kind = "repair-complete"
    continuationSchema = "rebase-only-continuation/v1"
    pr = [int]$rawPr
    reviewedHead = $ReviewedHead
    predecessorHead = $ContinuationPredecessorHead
    newHead = $ContinuationNewHead
    newBase = $ContinuationNewBase
    sourcePassReceiptIdentity = $SourcePassReceiptIdentity
    integrationLane = $IntegrationLane
    reviewedBase = $continuationEvidence.reviewedBase
    patchPairs = @($continuationEvidence.patchPairs)
    rangeDiff = $continuationEvidence.rangeDiff
    conflictResolution = $false
  }
} elseif ($DispatchRoutingSchema) {
  $entry=[ordered]@{ts=$eventTs;kind='dispatch';dispatchRoutingSchema=$DispatchRoutingSchema;attemptId=$DispatchAttemptId;label=$DispatchLabel
    lane=$Lane;laneRole='implementation';transcript=$Transcript;harness=$Harness;model=$Model;effort=$Effort;row=$Row;placement=$Placement
    worktree=[IO.Path]::GetFullPath($DispatchWorktree).TrimEnd('\','/');branch=$DispatchBranch;head=$DispatchHead}
  if ($DispatchRoutingSchema -ceq 'watchdog-dispatch-routing/v2') {
    $entry.policyGeneration=[long]$PolicyGeneration;$entry.registryAuthorityDigest=$RegistryAuthorityDigest
    $entry.family=$RoutingFamily;$entry.slot=$RoutingSlot;$entry.usedLastKnownGood=$UsedLastKnownGood
  }
} elseif ($IntegrationDispatchSchema) {
  $entry = [ordered]@{
    ts=$eventTs; kind='dispatch'; integrationDispatchSchema=$IntegrationDispatchSchema
    landedPr=$LandedPr; landedHead=$LandedHead; pr=[int]$rawPr; targetHead=$TargetHead
    targetBranch=$TargetBranch; reason=$IntegrationReason; disposition=$IntegrationDisposition
    integrationLane=$TargetIntegrationLane; worktree=[IO.Path]::GetFullPath($IntegrationWorktree).TrimEnd('\','/')
    laneRole='implementation'; harness=$Harness; model=$Model; effort=$Effort; row=$Row; placement=$Placement
  }
  if ($IntegrationDispatchSchema -ceq 'landed-integration-dispatch/v2') {
    foreach($key in @('harness','model','effort','row','placement')) { $entry.Remove($key) }
    $entry.executionAttribution=$execution
  }
} elseif ($WatchdogSchema) {
  $entry=[ordered]@{ts=$eventTs;kind=$Kind;watchdogSchema='watchdog-relaunch/v1';attemptId=$WatchdogAttemptId
    launchId=$WatchdogLaunchId;observationIdentity=$ObservationIdentity;observedAt=$WatchdogObservedAt
    deathSignature=$DeathSignature;resumedPartial=[IO.Path]::GetFullPath($ResumedPartial);relaunchCount=$RelaunchCount
    lane=$Lane;laneRole='implementation';harness=$Harness;model=$Model;effort=$Effort;row=$Row;placement=$Placement;outcome=$(if($Kind-ceq'lane-blocked'){$Outcome}else{'WATCHDOG_RELAUNCH'})}
  if($watchdogRoutingFieldsPresent){$entry.policyGeneration=[long]$PolicyGeneration;$entry.registryAuthorityDigest=$RegistryAuthorityDigest
    $entry.family=$RoutingFamily;$entry.slot=$RoutingSlot;$entry.usedLastKnownGood=[bool]$UsedLastKnownGood}
} else {
$entry = [ordered]@{ ts = $eventTs; kind = $Kind }
if ($PSBoundParameters.ContainsKey("Issue")) { $entry.issue = $Issue }
if ($PSBoundParameters.ContainsKey("Pr"))    { $entry.pr = $Pr }
if ($Kind -ceq 'landed') { $entry.head = $LandedHead }
if ($Lane)    { $entry.lane = $Lane }
if ($LaneRole) { $entry.laneRole = $LaneRole }
if ($Harness) { $entry.harness = $Harness }
if ($Model)   { $entry.model = $Model }
if ($AuthorModel) { $entry.authorModel = $AuthorModel }
if ($Effort)     { $entry.effort = $Effort }
if ($EffortUsed) { $entry.effortUsed = $EffortUsed }
if ($AuthorEffort) { $entry.authorEffort = $AuthorEffort }
if ($Row)        { $entry.row = $Row }
if ($Placement)  { $entry.placement = $Placement }
if ($Transcript) { $entry.transcript = $Transcript }
if ($Outcome)    { $entry.outcome = $Outcome }
# Preserve the caller's spelling whenever normalization rewrote it, so the
# canon never silently destroys what a lane actually reported.
if ($Outcome -and $outcomeRaw -and $outcomeRaw -cne $Outcome) { $entry.outcomeRaw = $outcomeRaw }
if ($PSBoundParameters.ContainsKey("Replacement")) { $entry.replacement = $Replacement }
if ($ReviewContract) { $entry.reviewContract = $ReviewContract }
if ($PlanningContract) { $entry.planningContract = $PlanningContract }
if ($PSBoundParameters.ContainsKey("CompleteSweep")) { $entry.completeSweep = [bool]$CompleteSweep }
if ($BreakerScope) { $entry.breakerScope = $BreakerScope }
if ($ControllerHead) { $entry.controllerHead = $ControllerHead }
if ($ReviewedHead) {
  if (-not $planningReview) { $entry.receiptSchema = "exact-head-review-receipt/v1" }
  $entry.reviewedHead = $ReviewedHead
  $entry.reviewerAttempt = $ReviewerAttempt
  $entry.authorAttempt = $AuthorAttempt
}
if ($ReviewedHead) {
  # The empty array is meaningful on a PASS/SKIP receipt; omitting it would
  # make the structured finding-count contract unverifiable.
  $entry.findingIds = [object[]]@($FindingIds | Where-Object { $_ })
} elseif ($FindingIds) {
  $entry.findingIds = @($FindingIds)
}
if ($RepairOwner) { $entry.repairOwner = $RepairOwner }
if ($PSBoundParameters.ContainsKey("ReviewerPatch")) { $entry.reviewerPatch = [bool]$ReviewerPatch }

$findings = [ordered]@{}
if ($Blocking -ge 0)    { $findings.blocking = $Blocking }
if ($Candidates -ge 0)  { $findings.candidates = $Candidates }
if ($NonBlocking -ge 0) { $findings.nonBlocking = $NonBlocking }
if ($findings.Count -gt 0) { $entry.findings = $findings }

if ($Classes) { $entry.classes = @($Classes) }
if ($Note) { $entry.note = $Note }
}

$line = $entry | ConvertTo-Json -Compress -Depth 4

if ($strictController -and -not $controllerCorrection) {
  $classification = Get-ControllerReviewRowClassification ($line | ConvertFrom-Json -DateKind String)
  if (-not $classification.valid) {
    throw "strict controller review row refused: $($classification.errors -join ', ')"
  }
}

# Serialize appends across concurrent orchestrator/watchdog processes.
$integrationDuplicate = $false
Invoke-WithOrchestrationLogLock -Body {
  $targetParent = Split-Path -Parent ([IO.Path]::GetFullPath($target))
  if (-not (Test-Path -LiteralPath $targetParent -PathType Container)) {
    throw "log target parent does not exist: $targetParent"
  }
  if ($controllerCorrection) {
    $history = Read-ExactHeadReviewHistory -Path $target
    if (-not $history.complete) { throw "controller audit correction refuses $($history.reason)" }
    $originalBytes = [IO.File]::ReadAllBytes($target)
    if ($originalBytes.Length -eq 0 -or $originalBytes[-1] -ne 10) { throw 'controller audit correction refuses an unterminated original history' }
    $nextLine = 1 + [int](@($history.rows | Sort-Object line -Descending | Select-Object -First 1)[0].line)
    $proposed = [pscustomobject]@{ line=$nextLine; value=($line | ConvertFrom-Json -DateKind String)
      rawSha256=([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($line)))).ToLowerInvariant() }
    $history.rows = @($history.rows) + @($proposed)
    $binding = Get-ControllerAuditCorrectionValidation $proposed $history
    if (-not $binding.valid) { throw "controller audit correction refuses $($binding.reason)" }
    $reduction = Reduce-ControllerReleaseReview -Issue $Issue -ControllerHead $ControllerHead -Mode strict-v1 -History $history
    if ($OriginalTerminalRawSha256) {
      if ($reduction.state -notin @('authorized','blocked')) { throw "controller audit correction refuses $($reduction.reason)" }
    } elseif ($reduction.reason -clike 'AUDIT_*' -or
              @($reduction.audit.danglingCorrections | Where-Object { $_.rawSha256 -ceq $proposed.rawSha256 }).Count -ne 1) {
      throw "controller audit correction refuses $($reduction.reason)"
    }
  }
  if ($IntegrationAuthoritySchema) {
    $history=Read-ExactHeadReviewHistory -Path $target
    if (-not $history.complete -and $history.reason -cne 'HISTORY_MISSING') { throw "AUTHORITY_INVALID: $($history.reason)" }
    if (Test-Path -LiteralPath $target) {
      $original=[IO.File]::ReadAllBytes($target)
      if ($original.Length -and $original[-1] -ne 10) { throw 'AUTHORITY_INVALID: unterminated history' }
    }
    $nextLine=1
    foreach($prior in $history.rows){$nextLine=[math]::Max($nextLine,1+$prior.line)}
    $proposed=[pscustomobject]@{line=$nextLine;value=($line|ConvertFrom-Json -DateKind String);rawSha256=([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($line)))).ToLowerInvariant()}
    $candidate=[pscustomobject]@{complete=$true;rows=@($history.rows)+@($proposed);reason='HISTORY_COMPLETE'}
    $reduced=Reduce-LandedIntegrationAuthority $candidate $Pr $TargetBranch $TargetHead
    if ($reduced.globalUnknown -or $reduced.reason -ceq 'CENSUS_UNKNOWN_AUTHORITY_ROW') {
      throw $(if($AuthorityState -ceq 'RELEASE'){'AUTHORITY_INVALID_RELEASE'}else{'AUTHORITY_INVALID'})
    }
    $sameTarget=@($history.rows|Where-Object{$_.value.integrationAuthoritySchema -ceq 'landed-integration-authority/v1' -and $_.value.pr -eq $Pr -and $_.value.targetBranch -ceq $TargetBranch})
    $lastMatch=0;$lastTransition=0
    foreach($prior in $sameTarget){
      $v=$prior.value
      if($v.authorityState -cin @('STOP','RELEASE')){$lastTransition=[math]::Max($lastTransition,$prior.line)}
      if($v.authorityState -ceq $AuthorityState -and $v.targetHead -ceq $TargetHead -and $v.authorityCommentId -ceq $AuthorityCommentId){$lastMatch=[math]::Max($lastMatch,$prior.line)}
    }
    if($lastMatch -gt 0 -and $lastTransition -le $lastMatch){throw 'AUTHORITY_DUPLICATE'}
  }
  if($ContinuationSchema){
    $finalHistory=Read-ExactHeadReviewHistory -Path $target
    $finalSource=Reduce-ExactHeadReview -Pr ([int]$rawPr) -CurrentHead $ReviewedHead -History $finalHistory
    if($finalSource.state-cne'authorized'-or$finalSource.latest.outcome-cne'PASS'-or$finalSource.latest.receiptIdentity-cne$SourcePassReceiptIdentity){throw 'rebase-only continuation source authority moved before append'}
    $finalPredecessor=Reduce-ExactHeadReview -Pr ([int]$rawPr) -CurrentHead $ContinuationPredecessorHead -History $finalHistory
    if($finalPredecessor.state-cne'authorized'-or$finalPredecessor.latest.reviewedHead-cne$ReviewedHead-or$finalPredecessor.latest.receiptIdentity-cne$SourcePassReceiptIdentity){throw 'rebase-only continuation predecessor authority moved before append'}
    $finalRoot=[IO.Path]::GetFullPath($ContinuationWorktree).TrimEnd('\','/')
    $finalHead=(Invoke-ContinuationGit $finalRoot @('rev-parse','HEAD') 'unable to re-read continuation HEAD').ToLowerInvariant()
    $finalStatus=Invoke-ContinuationGit $finalRoot @('status','--porcelain=v1','--untracked-files=normal') 'unable to re-read continuation worktree'
    if($finalHead-cne$ContinuationNewHead-or-not[string]::IsNullOrWhiteSpace($finalStatus)){throw 'rebase-only continuation worktree moved before append'}
  }
  if (($IntegrationDispatchSchema -or $WatchdogSchema) -and (Test-Path -LiteralPath $target -PathType Leaf)) {
    $history = Read-ExactHeadReviewHistory -Path $target
    if (-not $history.complete) { throw "integration dispatch history is not complete: $($history.reason)" }
    $duplicate = if($IntegrationDispatchSchema){@($history.rows | Where-Object {
      $value=$_.value
      $null -ne $value.PSObject.Properties['integrationDispatchSchema'] -and
      [string]$value.integrationDispatchSchema -cin @('landed-integration-dispatch/v1','landed-integration-dispatch/v2') -and
      [int64]$value.landedPr -eq $LandedPr -and [string]$value.landedHead -ceq $LandedHead -and
      [int64]$value.pr -eq [int]$rawPr
    })}else{@($history.rows|Where-Object{$null-ne$_.value.PSObject.Properties['watchdogSchema']-and[string]$_.value.watchdogSchema-ceq'watchdog-relaunch/v1'-and[string]$_.value.observationIdentity-ceq$ObservationIdentity})}
    if ($duplicate.Count -gt 0) { $script:integrationDuplicate=$true; return }
  }
  $bytes = [Text.UTF8Encoding]::new($false).GetBytes($line + [Environment]::NewLine)
  $stream = [IO.File]::Open(
    [IO.Path]::GetFullPath($target),
    [IO.FileMode]::Append,
    [IO.FileAccess]::Write,
    [IO.FileShare]::Read
  )
  try {
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush($true)
  } finally {
    $stream.Dispose()
  }
}
if ($integrationDuplicate) { throw $(if($WatchdogSchema){'WATCHDOG_OBSERVATION_DUPLICATE'}else{'INTEGRATION_DISPATCH_DUPLICATE'}) }

# --- Delivery board, lane-owned half (SKILL.md §14) --------------------------
# The board derives Backlog/Refined/Blocked hourly (scripts/project-status-sync.mjs)
# and deliberately never overwrites In lane / In review / Landed, because those
# three are the orchestrator's to write. Nothing wrote them for the entire
# program: 605 items on the board and 0 in all three lane-owned columns.
#
# Riding on this call is what makes the fix free. Every dispatch, disposition,
# and landing already logs here, so the board move costs no additional host turn
# and no additional host tokens — and both harnesses inherit it, because both
# shell out to this same script.
#
# board-set.ps1 is fail-open without -Strict, so the try/catch is belt-and-braces
# for a resolution failure before it gets that far. Bookkeeping must never take
# a dispatch down with it.
$boardScript = if ($BoardScript) { $BoardScript } else { Join-Path $PSScriptRoot "board-set.ps1" }
$boardEnabled =
  -not $IntegrationAuthoritySchema -and
  -not $controllerCorrection -and
  $PSBoundParameters.ContainsKey("Issue") -and
  -not $NoBoard -and
  $env:ORCH_BOARD_SYNC -ne "0" -and
  (-not $OutFile -or $PSBoundParameters.ContainsKey("BoardScript"))

if ($boardEnabled) {
  try {
    $boardArguments = @{
      Issue = $Issue
      EventKind = $Kind
      LaneRole = $LaneRole
      Outcome = $Outcome
    }
    if (-not [string]::IsNullOrWhiteSpace($ReviewAuthority)) {
      $boardArguments.ReviewAuthority = $ReviewAuthority
    }
    if ($hasPr -and (Test-SupportedPositivePr $rawPr)) { $boardArguments.Pr = [int]$rawPr }
    [void](& $boardScript @boardArguments)
  }
  catch {
    Write-Warning "board sync skipped for #${Issue}: $($_.Exception.Message)"
  }
}

Write-Output $line
if ($Kind -ceq 'landed') {
  $censusArguments=@{LandedPr=[int]$rawPr;LandedHead=$LandedHead;HistoryPath=$target;RuntimeRoot=(Split-Path -Parent ([IO.Path]::GetFullPath($target)))}
  if ($LandedIntegrationFixture) {$censusArguments.FixturePath=$LandedIntegrationFixture;$censusArguments.SynchronousDispatch=$true}
  & $LandedIntegrationScript @censusArguments | Write-Output
}
