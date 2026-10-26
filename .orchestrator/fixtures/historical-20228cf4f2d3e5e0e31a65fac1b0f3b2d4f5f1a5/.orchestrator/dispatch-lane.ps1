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
  -Label lane-05-5899-repair -LaneRole implementation

.EXAMPLE
./dispatch-lane.ps1 -Harness claude -Model claude-sonnet-5 -Effort medium `
  -PromptFile .orchestrator/5915-implementation.prompt.txt -Worktree lane-08 `
  -Label lane-08-5915-implementation -LaneRole implementation -DryRun

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
  [Parameter(DontShow)][string]$TestTempRoot
)

$ErrorActionPreference = "Stop"

function Assert-ExactModelVersion([string]$RequestedHarness, [string]$RequestedModel) {
  $allowed = if ($RequestedHarness -eq "claude") {
    @("claude-sonnet-5", "claude-opus-5", "claude-fable-5")
  } else {
    @("gpt-5.6-luna", "gpt-5.6-terra", "gpt-5.6-sol")
  }
  if ($RequestedModel -eq "claude-opus-4-8") {
    throw "dispatch-lane: claude-opus-4-8 is deprecated and off the roster; select an exact current model version"
  }
  if ($RequestedModel -notin $allowed) {
    throw "dispatch-lane: model '$RequestedModel' is not an exact selectable $RequestedHarness version. Aliases and family names are forbidden; allowed: $($allowed -join ', ')"
  }
}

Assert-ExactModelVersion $Harness $Model
if ($Label -cnotmatch "^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$") {
  throw "dispatch-lane: label must be a safe 1-200 character output stem"
}

$container = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "dispatch-ownership.ps1")
. (Join-Path $PSScriptRoot "dispatch-claude-stream-audit.ps1")
$runtimeRoot = if ($TestRuntimeRoot) { [IO.Path]::GetFullPath($TestRuntimeRoot) } else { [IO.Path]::GetFullPath($PSScriptRoot) }
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
# review touches nothing, planning owns GitHub issue recovery.
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
$admissionPreload = Join-Path $PSScriptRoot "heavy-admission-preload.cjs"
$admissionGuard = Join-Path $PSScriptRoot "invoke-heavy-verifier.ps1"
if (-not (Test-Path -LiteralPath $admissionPreload -PathType Leaf) -or
    -not (Test-Path -LiteralPath $admissionGuard -PathType Leaf)) {
  throw "dispatch-lane: heavy admission tooling is incomplete; refusing to launch"
}
$admissionPowerShell = Get-Command pwsh -CommandType Application -ErrorAction Stop |
  Select-Object -First 1 -ExpandProperty Source
$admissionLane = Split-Path -Leaf ([IO.Path]::GetFullPath($worktreeResolved).TrimEnd("\", "/"))
if ($admissionLane -cnotmatch "^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$") {
  throw "dispatch-lane: worktree leaf is not a valid bounded admission lane identity: $admissionLane"
}
$admissionBranchProbe = & git -C $worktreeResolved branch --show-current 2>$null
$admissionBranch = if ($null -eq $admissionBranchProbe) { "" } else { ([string]$admissionBranchProbe).Trim() }
$admissionHeadProbe = & git -C $worktreeResolved rev-parse --verify HEAD 2>$null
$admissionHead = if ($null -eq $admissionHeadProbe) { "" } else { ([string]$admissionHeadProbe).Trim().ToLowerInvariant() }
if ($admissionHead -cnotmatch "^[a-f0-9]{40}$") {
  if ($ExecutablePath -and ($TestRuntimeRoot -or $DryRun)) {
    $admissionBranch = "test/isolated"
    $admissionHead = "0" * 40
  } elseif ($TestArgumentList -and -not $ExecutablePath) {
    # Preserve the existing validation order: the testing-only argument seam
    # must refuse before any production harness or branch is accepted.
    $admissionBranch = "validation/pending"
    $admissionHead = "0" * 40
  } else {
    throw "dispatch-lane: branch and exact HEAD identity are required for heavy-command admission"
  }
}
$admissionIdentityMode = if (-not [string]::IsNullOrWhiteSpace($admissionBranch)) {
  "branch"
} elseif ($LaneRole -eq "review") {
  "immutable-head"
} else {
  throw "dispatch-lane: detached worktrees are admitted only for exact-HEAD review dispatches"
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
try {
  Invoke-DispatchOwnershipScavenge $runtimeRoot $tempRoot | Out-Null
  $launchId = [guid]::NewGuid().ToString()
  $launchPromptFile = Join-Path $runtimeRoot "dispatch-heavy-verifier-$launchId.prompt.txt"
  $ownershipRecordPath = Join-Path $runtimeRoot "dispatch-launch-$launchId.json"
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
  Write-DispatchOwnershipRecord $ownershipRecordPath $ownershipRecord -CreateNew
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
    } else {
      Write-Warning "dispatch-lane: ownership changed before child publication; preserving the record and resources"
    }
  } else {
    Write-Warning "dispatch-lane: child start identity was unavailable; retaining the launching record until the foreground child exits"
  }
  Write-Output "dispatch-lane: pid $($process.Id)"
  $process.WaitForExit()
  $childExitCode = $process.ExitCode
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
  if ($ownershipRecordPath -and $ownershipRecord) {
    if (-not (Remove-DispatchLaunchResources $ownershipRecordPath $ownershipRecord $runtimeRoot $tempRoot)) {
      Write-Warning "dispatch-lane: exact launch cleanup was not proven; the validated ownership record was preserved for a later dispatch"
    }
  }
}

exit $childExitCode
