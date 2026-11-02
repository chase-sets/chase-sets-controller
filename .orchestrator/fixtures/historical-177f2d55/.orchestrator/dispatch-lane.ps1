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
./dispatch-lane.ps1 -Harness codex -Model gpt-5.6-sol -Effort high `
  -PromptFile .orchestrator/5899-repair.prompt.txt -Worktree lane-05 `
  -Label lane-05-5899-repair -LaneRole implementation -Row 4 -Placement measured

.EXAMPLE
./dispatch-lane.ps1 -Harness claude -Model claude-sonnet-5 -Effort medium `
  -PromptFile .orchestrator/5915-implementation.prompt.txt -Worktree lane-08 `
  -Label lane-08-5915-implementation -LaneRole implementation -Row 3 -Placement measured -DryRun

.EXAMPLE
./dispatch-lane.ps1 -Harness codex -Model gpt-5.6-sol -Effort high `
  -PromptFile .orchestrator/5962-review.prompt.txt -Worktree lane-03 `
  -Label lane-03-5962-review -LaneRole review

Omitting `-LaneRole` defaults to least-authority `review` without prompting.
Provider authority is inherited only when an implementation dispatch
explicitly selects `-LaneRole implementation`.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateSet("codex", "claude")][string]$Harness,
  [Parameter(Mandatory)][string]$Model,
  [Parameter(Mandatory)][ValidateSet("minimal", "low", "medium", "high", "xhigh", "max")][string]$Effort,
  # review (default): remove known provider credentials, isolate doctl config,
  # and disable kubectl's default kubeconfig fallback before the harness child
  # starts while retaining GitHub authentication.
  # implementation: explicitly inherit the launcher environment unchanged.
  [ValidateSet("implementation", "review", "planning")][string]$LaneRole = "review",
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
  [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._:/-]{0,255}$')][string]$SemanticAttemptId,
  [ValidateRange(0,3)][int]$WatchdogRelaunchCount = 0,
  [ValidatePattern('^$|^[a-f0-9-]{36}$')][string]$ResumeOfLaunchId = '',
  [ValidateRange(0,15)][int]$Row = 0,
  [ValidatePattern('^$|^(measured|provisional|override-[a-z0-9._-]+)$')][string]$Placement = '',
  [Parameter(DontShow)][ValidatePattern('^$|^[a-f0-9]{64}$')][string]$StartRequestIdentity = '',
  [Parameter(DontShow)][string]$StartAcknowledgementPath = '',
  [Parameter(DontShow)][string]$OwedReleaseScanObservedPath = '',
  [Parameter(DontShow)][string]$OwedReleaseScanContinuePath = ''
)

$ErrorActionPreference = "Stop"

if ($LaneRole -eq 'implementation' -and ($Row -lt 1 -or [string]::IsNullOrWhiteSpace($Placement))) {
  throw 'dispatch-lane: implementation dispatch requires exact -Row and -Placement routing provenance'
}
if ([bool]$StartRequestIdentity -ne [bool]$StartAcknowledgementPath) {
  throw 'dispatch-lane: start acknowledgement path and request identity must be supplied together'
}

function Assert-ExactModelVersion([string]$RequestedHarness, [string]$RequestedModel) {
  $allowed = if ($RequestedHarness -eq "claude") {
    @("claude-sonnet-5", "claude-opus-5", "claude-fable-5-1")
  } else {
    @("gpt-5.6-luna", "gpt-5.6-terra", "gpt-5.6-sol", "gpt-6-astra")
  }
  if ($RequestedModel -eq "claude-opus-4-8") {
    throw "dispatch-lane: claude-opus-4-8 is deprecated and off the roster; select an exact current model version"
  }
  if ($RequestedModel -cnotin $allowed) {
    throw "dispatch-lane: model '$RequestedModel' is not an exact selectable $RequestedHarness version. Aliases and family names are forbidden; allowed: $($allowed -join ', ')"
  }
}

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

Assert-ExactModelVersion $Harness $Model
if ($Model -ceq "gpt-6-astra" -and $Effort -eq "minimal") { throw "dispatch-lane: gpt-6-astra supports low, medium, high, xhigh, or max effort" }
if ($Label -cnotmatch "^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$") {
  throw "dispatch-lane: label must be a safe 1-200 character output stem"
}

$container = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "dispatch-ownership.ps1")
. (Join-Path $PSScriptRoot "dispatch-claude-stream-audit.ps1"); Import-Module (Join-Path $PSScriptRoot "fleet-exclusive-admission.psm1") -Force -DisableNameChecking
$runtimeRoot = if ($TestRuntimeRoot) { [IO.Path]::GetFullPath($TestRuntimeRoot) } else { [IO.Path]::GetFullPath($PSScriptRoot) }
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
if ($admissionIdentityBefore.IdentityMode -ceq "immutable-head" -and $LaneRole -ne "review") {
  throw "dispatch-lane: detached worktrees are admitted only for exact-HEAD review dispatches"
}

# These two independently load-bearing guards are intentionally adjacent and
# precede plan construction and every dispatch side effect. The mutant controls
# in dispatch-lane.test.ps1 delete one call at a time.
Assert-DispatchAdmissionClean $worktreeResolved # ADMISSION_GUARD_CLEANLINESS
Assert-DispatchAdmissionExclusiveBranchAttachment $admissionIdentityBefore # ADMISSION_GUARD_EXCLUSIVE_BRANCH
$admissionIdentityAfter = Get-DispatchAdmissionIdentity $worktreeResolved
Assert-DispatchAdmissionIdentityConsistent $admissionIdentityBefore $admissionIdentityAfter
$admissionBranch = $admissionIdentityAfter.Branch
$admissionHead = $admissionIdentityAfter.Head
$admissionIdentityMode = $admissionIdentityAfter.IdentityMode

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
if ($exe -notlike "*.exe") {
  throw "dispatch-lane: resolved executable is not a native .exe: $exe (stall-gotcha windows-start-process-codex-shim)"
}
if ($TestArgumentList -and -not $ExecutablePath) {
  throw "dispatch-lane: -TestArgumentList requires the testing-only -ExecutablePath override"
}

# --- build the argument list -------------------------------------------------
$launchArguments = switch ($Harness) {
  "codex" {
    @("exec", "-m", $Model, "-c", "model_reasoning_effort=$Effort", "--json",
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
  }
  $temporary="$watchdogSpecPath.$([guid]::NewGuid().ToString('N')).tmp"
  try{[IO.File]::WriteAllText($temporary,($spec|ConvertTo-Json -Compress -Depth 4),[Text.UTF8Encoding]::new($false));[IO.File]::Move($temporary,$watchdogSpecPath,$true)}finally{Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue}
}
try {
  Invoke-DispatchOwnershipScavenge $runtimeRoot $tempRoot | Out-Null
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
  }
  Write-DispatchOwnershipRecord $ownershipRecordPath $ownershipRecord -CreateNew <# FLEET_ADMISSION_GUARD_LANE_OWNER_PUBLISHED_BEFORE_LEASE #>; Assert-FleetExclusiveLeaseVacantForDispatch -RuntimeRoot $runtimeRoot <# FLEET_ADMISSION_GUARD_FLEET_LEASE_INSPECTION #>; Assert-FleetExclusiveLeaseVacantForDispatch -RuntimeRoot $runtimeRoot <# FLEET_ADMISSION_GUARD_FLEET_LEASE_REREAD #>
  Write-WatchdogSpec 'launching'
  if ($LaneRole -eq 'implementation') {
    & (Join-Path $PSScriptRoot 'log-event.ps1') -Log dispatch -Kind dispatch -DispatchRoutingSchema watchdog-dispatch-routing/v1 `
      -DispatchAttemptId $(if($SemanticAttemptId){$SemanticAttemptId}else{$Label}) -DispatchLabel $Label -Lane $admissionLane -LaneRole implementation `
      -Transcript (Split-Path -Leaf $stdoutPath) -Harness $Harness -Model $Model -Effort $Effort -Row ([string]$Row) -Placement $Placement `
      -DispatchWorktree $worktreeResolved -DispatchBranch $admissionBranch -DispatchHead $admissionHead -OutFile (Join-Path $runtimeRoot 'dispatch-log.jsonl') -NoBoard | Out-Null
  }
  $gatePreamble = "Heavy verification contract: use '$($plan.heavyVerifier.entrypoint)' for every full gate. Supported gates: $($plan.heavyVerifier.supportedGates -join ', '). It acquires and validates the exclusive lock, runs foreground, and only releases its own owner record. Direct memory-heavy Node, Playwright, Vitest, script-battery, and build commands are machine-admitted through the same lock before their command body. A timeout is load-sensitive only after an unchanged isolated timing collapse and a complete one-worker/file-serial gate; never raise timeouts, edit product files, or skip tests.`r`n`r`n"
  $harnessPreamble = if ($Harness -eq "claude") { $claudeForegroundPreamble } else { "" }
  $reviewPreamble = if ($LaneRole -eq "review") { $reviewContractText.TrimEnd() + "`r`n`r`n" } else { "" }
  $planningPreamble = if ($LaneRole -eq "planning") { $planningContractText.TrimEnd() + "`r`n`r`n" } else { "" }
  [IO.File]::WriteAllText($launchPromptFile, $gatePreamble + $harnessPreamble + $reviewPreamble + $planningPreamble + [IO.File]::ReadAllText($promptResolved), [Text.UTF8Encoding]::new($false))
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
    NODE_OPTIONS = $(if ([string]::IsNullOrWhiteSpace($originalNodeOptions)) { $preloadOption } else { "$originalNodeOptions $preloadOption" })
    npm_config_script_shell = [IO.Path]::GetFullPath((Get-Command node -CommandType Application -ErrorAction Stop | Select-Object -First 1 -ExpandProperty Source))
    CHASE_SETS_HEAVY_ADMISSION_CONFIG = $admissionEncoded
    CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_NODE_OPTIONS = $originalNodeOptions
    CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_SCRIPT_SHELL = $admissionConfiguration.originalScriptShell
    CHASE_SETS_HEAVY_ADMISSION_PNPM_SCRIPT_SHELL = "node-check-proxy"
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
  if ($LaneRole -eq 'implementation' -and $admissionIdentityMode -eq 'branch' -and $ownershipRecordPath -and $ownershipRecord) {
    $consumer = Join-Path $PSScriptRoot 'landed-integration-consume.ps1'
    if (Test-Path -LiteralPath $consumer -PathType Leaf) {
      try {
        $consumerArguments = @{
          Branch = $admissionBranch; Worktree = $worktreeResolved; RuntimeRoot = $runtimeRoot
          HistoryPath = (Join-Path $runtimeRoot 'dispatch-log.jsonl')
          AcceptingOwnerRecordPath = $ownershipRecordPath; AcceptingOwnerLaunchId = $launchId
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
}

exit $childExitCode
