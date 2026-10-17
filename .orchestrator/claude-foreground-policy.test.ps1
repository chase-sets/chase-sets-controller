<#
.SYNOPSIS
Focused #9712 regression (claude-foreground-gate-exceeds-tool-limit). Every
Claude child, whatever its role or model alias, receives a one-hour foreground
Bash/PowerShell envelope, background tasks disabled and no auto-background
threshold; a conflicting Claude settings env block refuses the launch and its
preparation or dry run; Codex launches are unchanged; the #6005 completion
audit still rejects background
work. Inert fixtures only: the harness child is pwsh, never a model CLI, and
nothing here runs the 610 s smoke or reserves a heavy slot.

.PARAMETER IncidentTranscript
Optional retained #9585 transcript (9585-impl-g1.jsonl). When supplied, its
exact bytes are replayed through the unchanged audit; when omitted the replay
reports NOT_EXECUTED and the synthetic controls still run.
#>
param([string]$IncidentTranscript = '')

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'routing-data-test-support.ps1')
. (Join-Path $PSScriptRoot 'dispatch-claude-stream-audit.ps1')
$routingTestScope = Enter-RoutingDataTestScope
$launcher = Join-Path $PSScriptRoot 'dispatch-lane.ps1'
$auditHelper = Join-Path $PSScriptRoot 'dispatch-claude-stream-audit.ps1'
$failures = [Collections.Generic.List[string]]::new()
$policyNames = @('BASH_DEFAULT_TIMEOUT_MS', 'BASH_MAX_TIMEOUT_MS', 'CLAUDE_CODE_DISABLE_BACKGROUND_TASKS', 'CLAUDE_CODE_AUTO_BACKGROUND_TIMEOUT_MS')
$requiredPolicy = [ordered]@{
  BASH_DEFAULT_TIMEOUT_MS = '3600000'
  BASH_MAX_TIMEOUT_MS = '3600000'
  CLAUDE_CODE_DISABLE_BACKGROUND_TASKS = '1'
  CLAUDE_CODE_AUTO_BACKGROUND_TIMEOUT_MS = $null
}
# The incident-shaped parent: Claude's own defaults plus an inherited
# auto-background threshold. Children must not see any of these values.
$conflictingParent = [ordered]@{
  BASH_DEFAULT_TIMEOUT_MS = '120000'
  BASH_MAX_TIMEOUT_MS = '600000'
  CLAUDE_CODE_DISABLE_BACKGROUND_TASKS = '0'
  CLAUDE_CODE_AUTO_BACKGROUND_TIMEOUT_MS = '590000'
}
$incidentSha256 = 'ac1a0af04d14adb95f24a1fa7c30d01ba1b9aa399f8a36eeb882960887671660'

function Assert-Policy([bool]$Condition, [string]$Message) {
  if ($Condition) { Write-Output "PASS $Message" } else { $script:failures.Add($Message); Write-Output "FAIL $Message" }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("claude-foreground-policy-test-" + [guid]::NewGuid())
$testRootResolved = [IO.Path]::GetFullPath($testRoot)
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
  $prompt = Join-Path $testRoot 'prompt.txt'
  Set-Content -LiteralPath $prompt -Value 'do the work'
  $worktree = Join-Path $testRoot 'lane-97'
  New-Item -ItemType Directory -Path $worktree | Out-Null
  foreach ($arguments in @(
      @('init', '--initial-branch=codex/claude-foreground-policy-test'),
      @('config', 'user.name', 'Claude Foreground Policy Test'),
      @('config', 'user.email', 'claude-foreground-policy-test@example.invalid'))) {
    & git -C $worktree @arguments 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "fixture git failed: $($arguments -join ' ')" }
  }
  # Planted project/local settings stay git-ignored so the clean-worktree
  # admission refusal cannot stand in for the policy refusal under test.
  Add-Content -LiteralPath (Join-Path $worktree '.git/info/exclude') -Value '/.claude/'
  Set-Content -LiteralPath (Join-Path $worktree 'seed.txt') -Value 'policy seed'
  & git -C $worktree add -- seed.txt 2>&1 | Out-Null
  & git -C $worktree commit -m 'policy seed' 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'fixture git commit failed' }
  $runtimeRoot = Join-Path $testRoot 'dispatch-runtime'
  $providerTempRoot = Join-Path $testRoot 'provider-temp'
  $claudeConfigDir = Join-Path $testRoot 'claude-config'
  $managedRoot = Join-Path $testRoot 'claude-managed'
  $projectSettingsDir = Join-Path $worktree '.claude'
  New-Item -ItemType Directory -Path $runtimeRoot, $providerTempRoot, $claudeConfigDir, $managedRoot | Out-Null
  $preload = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'heavy-admission-preload.cjs'))

  # Inert harness child: records its prompt and effective environment, then
  # emits one successful stream-json result.
  $child = Join-Path $testRoot 'policy-child.ps1'
  @'
$capturedPrompt = [Console]::In.ReadToEnd()
$values = [ordered]@{}
foreach ($name in $env:POLICY_CAPTURE_NAMES.Split(',')) { $values[$name] = [Environment]::GetEnvironmentVariable($name) }
$capture = [ordered]@{ prompt = $capturedPrompt; environment = $values; psEdition = [string]$PSVersionTable.PSEdition }
[IO.File]::WriteAllText($env:POLICY_CHILD_CAPTURE, ($capture | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
'{"type":"result","subtype":"success","is_error":false,"result":"done"}'
exit 0
'@ | Set-Content -LiteralPath $child
  # Runner: invokes the real launcher in-process, then records its own
  # environment so a launcher-side parent mutation is visible.
  $runner = Join-Path $testRoot 'policy-runner.ps1'
  @'
$parameters = @{
  Harness = $env:POLICY_HARNESS; Model = $env:POLICY_MODEL; Effort = $env:POLICY_EFFORT; LaneRole = $env:POLICY_ROLE
  Row = [int]$env:POLICY_ROW; Placement = $env:POLICY_PLACEMENT; PromptFile = $env:POLICY_PROMPT
  Worktree = $env:POLICY_WORKTREE; Label = $env:POLICY_LABEL; ExecutablePath = (Join-Path $PSHOME 'pwsh.exe')
  TestArgumentList = @('-NoProfile', '-NonInteractive', '-File', $env:POLICY_CHILD)
  TestRuntimeRoot = $env:POLICY_RUNTIME_ROOT; TestTempRoot = $env:POLICY_TEMP_ROOT
}
if ((Get-Command $env:POLICY_LAUNCHER).Parameters.ContainsKey('TestClaudeManagedPolicyRoot')) {
  $parameters.TestClaudeManagedPolicyRoot = $env:POLICY_MANAGED_ROOT
}
if ($env:POLICY_EXTRA) {
  foreach ($entry in ($env:POLICY_EXTRA | ConvertFrom-Json -AsHashtable).GetEnumerator()) { $parameters[$entry.Key] = $entry.Value }
}
$code = 1
$output = @()
try {
  $output = @(& $env:POLICY_LAUNCHER @parameters)
  $code = $LASTEXITCODE
} catch {
  [Console]::Error.WriteLine($_.Exception.Message)
  $code = 1
} finally {
  [IO.File]::WriteAllText($env:POLICY_STDOUT_CAPTURE, ($output -join "`n"), [Text.UTF8Encoding]::new($false))
  $after = [ordered]@{ psEdition = [string]$PSVersionTable.PSEdition }
  foreach ($name in $env:POLICY_PARENT_NAMES.Split(',')) { $after[$name] = [Environment]::GetEnvironmentVariable($name) }
  [IO.File]::WriteAllText($env:POLICY_PARENT_CAPTURE, ($after | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
}
exit $code
'@ | Set-Content -LiteralPath $runner

  $captureNames = @($policyNames) + @('DIGITALOCEAN_ACCESS_TOKEN', 'APPDATA', 'XDG_CONFIG_HOME', 'KUBECONFIG', 'GH_CONFIG_DIR',
    'NODE_OPTIONS', 'CHASE_SETS_HEAVY_ADMISSION_CONFIG', 'npm_config_script_shell', 'CLAUDE_CONFIG_DIR')

  function Invoke-PolicyScenario(
    [string]$Name,
    [string]$Harness = 'claude',
    [string]$LaneRole = 'implementation',
    [string]$Model = 'claude-opus-5-5',
    [string]$Effort = 'high',
    [int]$Row = 10,
    [string]$Placement = 'override-Todd',
    [hashtable]$Extra = @{}
  ) {
    $label = "test-$Name-$([guid]::NewGuid().ToString('N').Substring(0, 12))"
    $childCapture = Join-Path $testRoot "$label-child.json"
    $parentCapture = Join-Path $testRoot "$label-parent.json"
    $stdoutCapture = Join-Path $testRoot "$label-stdout.txt"
    $runnerOutput = Join-Path $testRoot "$label-runner.out"
    $runnerError = Join-Path $testRoot "$label-runner.err"
    $scenarioEnvironment = @{
      POLICY_LAUNCHER = $launcher; POLICY_HARNESS = $Harness; POLICY_MODEL = $Model; POLICY_EFFORT = $Effort
      POLICY_ROLE = $LaneRole; POLICY_ROW = [string]$Row; POLICY_PLACEMENT = $Placement; POLICY_PROMPT = $prompt
      POLICY_WORKTREE = $worktree; POLICY_LABEL = $label; POLICY_CHILD = $child; POLICY_CHILD_CAPTURE = $childCapture
      POLICY_PARENT_CAPTURE = $parentCapture; POLICY_CAPTURE_NAMES = ($captureNames -join ',')
      POLICY_PARENT_NAMES = ($policyNames -join ','); POLICY_RUNTIME_ROOT = $runtimeRoot; POLICY_TEMP_ROOT = $providerTempRoot
      POLICY_MANAGED_ROOT = $managedRoot; CLAUDE_CONFIG_DIR = $claudeConfigDir
      POLICY_STDOUT_CAPTURE = $stdoutCapture; POLICY_EXTRA = $(if ($Extra.Count) { $Extra | ConvertTo-Json -Compress } else { $null })
      DIGITALOCEAN_ACCESS_TOKEN = 'synthetic-provider-token-not-a-secret'
    }
    foreach ($entry in $conflictingParent.GetEnumerator()) { $scenarioEnvironment[$entry.Key] = $entry.Value }
    $process = Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') `
      -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $runner) `
      -Environment $scenarioEnvironment -WindowStyle Hidden -PassThru `
      -RedirectStandardOutput $runnerOutput -RedirectStandardError $runnerError
    try {
      if (-not $process.WaitForExit(180000)) {
        $process.Kill($true)
        [void]$process.WaitForExit(10000)
        throw "policy scenario '$Name' did not finish within 180 s"
      }
      $exitCode = $process.ExitCode
    } finally { $process.Dispose() }
    [pscustomobject]@{
      name = $Name
      label = $label
      exitCode = $exitCode
      diagnostics = if (Test-Path -LiteralPath $runnerError) { [IO.File]::ReadAllText($runnerError) } else { '' }
      output = if (Test-Path -LiteralPath $stdoutCapture) { [IO.File]::ReadAllText($stdoutCapture) } else { '' }
      child = if (Test-Path -LiteralPath $childCapture) { [IO.File]::ReadAllText($childCapture) | ConvertFrom-Json } else { $null }
      parent = if (Test-Path -LiteralPath $parentCapture) { [IO.File]::ReadAllText($parentCapture) | ConvertFrom-Json } else { $null }
      transcriptPresent = Test-Path -LiteralPath (Join-Path $runtimeRoot "$label.jsonl")
    }
  }

  function Get-ClaudePreambleSegment([string]$Prompt) {
    $start = $Prompt.IndexOf('Claude foreground-only execution contract:', [StringComparison]::Ordinal)
    if ($start -lt 0) { return '' }
    $end = $Prompt.IndexOf("`r`n`r`n", $start, [StringComparison]::Ordinal)
    if ($end -lt 0) { return $Prompt.Substring($start) }
    return $Prompt.Substring($start, $end - $start)
  }

  function Assert-ParentUnchanged($Scenario, [string]$Context) {
    $unchanged = $null -ne $Scenario.parent
    foreach ($entry in $conflictingParent.GetEnumerator()) {
      if (-not $unchanged -or [string]$Scenario.parent.($entry.Key) -cne $entry.Value) { $unchanged = $false }
    }
    Assert-Policy $unchanged "AC1 $Context leaves the launcher's own environment unchanged"
  }

  function Get-SettingsSnapshot {
    @(Get-ChildItem -LiteralPath @($claudeConfigDir, $managedRoot) -Recurse -Force -File -ErrorAction SilentlyContinue) +
      @(Get-ChildItem -LiteralPath $projectSettingsDir -Recurse -Force -File -ErrorAction SilentlyContinue) |
      Sort-Object FullName | ForEach-Object { "$($_.FullName)|$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)" }
  }

  # --- AC1: effective policy for every Claude role, by harness ---------------
  $unrelatedUserSettings = '{"env":{"API_TIMEOUT_MS":"300000","BASH_MAX_TIMEOUT_MS":"3600000"},"theme":"dark"}'
  [IO.File]::WriteAllText((Join-Path $claudeConfigDir 'settings.json'), $unrelatedUserSettings, [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText((Join-Path $claudeConfigDir '.claude.json'), '{"numStartups":1}', [Text.UTF8Encoding]::new($false))
  Assert-Policy ((Get-Command $launcher).Parameters.ContainsKey('TestClaudeManagedPolicyRoot')) `
    'AC1 launcher exposes the testing-only managed-policy root, so fixtures never read machine policy'
  $claudeRoles = @(
    @{ Name = 'claude-implementation'; LaneRole = 'implementation'; Model = 'claude-opus-5-5'; Effort = 'high'; Row = 10 },
    @{ Name = 'claude-review'; LaneRole = 'review'; Model = 'claude-sonnet-5-5'; Effort = 'medium'; Row = 0 },
    @{ Name = 'claude-planning'; LaneRole = 'planning'; Model = 'claude-sonnet-5-5'; Effort = 'medium'; Row = 0 }
  )
  $settingsBefore = (Get-SettingsSnapshot) -join "`n"
  foreach ($role in $claudeRoles) {
    $scenario = Invoke-PolicyScenario @role
    $context = "Claude $($role.LaneRole) ($($role.Model))"
    Assert-Policy ($scenario.exitCode -eq 0 -and $null -ne $scenario.child) "AC1 $context launches its inert child successfully"
    $environment = if ($scenario.child) { $scenario.child.environment } else { $null }
    foreach ($entry in $requiredPolicy.GetEnumerator()) {
      $observed = if ($environment) { $environment.($entry.Key) } else { 'not-captured' }
      if ($null -eq $entry.Value) {
        Assert-Policy ($null -ne $environment -and $null -eq $observed) "AC1 $context child has no inherited $($entry.Key)"
      } else {
        Assert-Policy ([string]$observed -ceq $entry.Value) "AC1 $context child $($entry.Key) is $($entry.Value) despite inherited $($conflictingParent[$entry.Key])"
      }
    }
    Assert-ParentUnchanged $scenario "$context success"
    $nodeOptions = if ($environment) { [string]$environment.NODE_OPTIONS } else { '' }
    Assert-Policy ($nodeOptions.Contains("--require=$preload") -and -not [string]::IsNullOrEmpty($environment.CHASE_SETS_HEAVY_ADMISSION_CONFIG)) `
      "AC1/AC4 $context keeps heavy admission preload and configuration"
    if ($role.LaneRole -eq 'implementation') {
      Assert-Policy ($environment -and $environment.DIGITALOCEAN_ACCESS_TOKEN -ceq 'synthetic-provider-token-not-a-secret') `
        "AC1/AC4 $context keeps implementation provider inheritance"
    } else {
      $isolation = if ($environment) { [string]$environment.APPDATA } else { '' }
      Assert-Policy ($environment -and $null -eq $environment.DIGITALOCEAN_ACCESS_TOKEN -and
        $isolation.StartsWith((Join-Path ([IO.Path]::GetFullPath($providerTempRoot)) "chase-sets-$($role.LaneRole)-"), [StringComparison]::OrdinalIgnoreCase) -and
        $environment.XDG_CONFIG_HOME -ceq $isolation -and [string]$environment.KUBECONFIG -ceq (Join-Path $isolation 'nonexistent-kubeconfig') -and
        -not [string]::IsNullOrEmpty($environment.GH_CONFIG_DIR)) "AC1/AC4 $context keeps provider credential isolation"
    }
    $preamble = if ($scenario.child) { Get-ClaudePreambleSegment ([string]$scenario.child.prompt) } else { '' }
    Assert-Policy ($preamble.Contains('Do not use Monitor, ScheduleWakeup, any Cron tool (CronCreate, CronDelete, or CronList)')) "AC1 $context preamble keeps the session-scoped tool bans"
    Assert-Policy ($preamble.Contains('one-hour') -and $preamble.Contains('harness bound, not a gate budget')) "AC1 $context preamble names the one-hour harness bound, not a gate budget"
    Assert-Policy ($preamble.Contains('Run each finite gate in the foreground without an explicit timeout')) "AC1 $context preamble tells gates to omit explicit timeouts"
    Assert-Policy ($preamble.Contains('Narrow reads and polls before calling them') -and $preamble.Contains('room to complete') -and
      $preamble.Contains('never rely on the hour for them')) "AC1 $context preamble narrows reads/polls before short calls whose deadline allows completion"
    Assert-Policy ($preamble -notmatch '\b(590|600)\s*(-?\s*s\b|-?\s*seconds?\b)|\b(590000|600000)\b') "AC1 $context preamble carries no 590/600 s timeout guidance"
    Assert-Policy ($preamble.Contains("forfeits this session's acceptance") -and $preamble.Contains('report it incomplete to the host') -and
      $preamble.Contains('do not recover and finish it') -and $preamble.Contains('retry it automatically, or report PASS')) `
      "AC4 $context preamble pins expiry as forfeited acceptance reported incomplete, never recovered, retried or PASS"
  }
  Assert-Policy (((Get-SettingsSnapshot) -join "`n") -ceq $settingsBefore) 'AC1 successful Claude launches never write user, project or managed settings'

  # --- AC1: conflicting settings env refuses the Claude launch ----------------
  $conflictCases = @(
    @{ Name = 'user'; Path = (Join-Path $claudeConfigDir 'settings.json'); Text = '{"env":{"BASH_MAX_TIMEOUT_MS":"600000"}}'; Key = 'BASH_MAX_TIMEOUT_MS' },
    @{ Name = 'global-config'; Path = (Join-Path $claudeConfigDir '.claude.json'); Text = '{"numStartups":1,"env":{"bash_default_timeout_ms":120000}}'; Key = 'bash_default_timeout_ms' },
    @{ Name = 'project'; Path = (Join-Path $projectSettingsDir 'settings.json'); Text = '{"env":{"CLAUDE_CODE_AUTO_BACKGROUND_TIMEOUT_MS":"590000"}}'; Key = 'CLAUDE_CODE_AUTO_BACKGROUND_TIMEOUT_MS' },
    @{ Name = 'local'; Path = (Join-Path $projectSettingsDir 'settings.local.json'); Text = '{"env":{"CLAUDE_CODE_DISABLE_BACKGROUND_TASKS":"0"}}'; Key = 'CLAUDE_CODE_DISABLE_BACKGROUND_TASKS' },
    @{ Name = 'managed-policy'; Path = (Join-Path $managedRoot 'managed-settings.json'); Text = '{"env":{"BASH_DEFAULT_TIMEOUT_MS":"600000"}}'; Key = 'BASH_DEFAULT_TIMEOUT_MS' },
    @{ Name = 'managed-policy'; Path = (Join-Path $managedRoot 'managed-settings.d/50-timeouts.json'); Text = '{"env":{"BASH_MAX_TIMEOUT_MS":"590000"}}'; Key = 'BASH_MAX_TIMEOUT_MS' },
    @{ Name = 'managed-policy'; Path = (Join-Path $managedRoot 'managed-settings.d/60-hidden.json'); Text = '{"env":{"CLAUDE_CODE_DISABLE_BACKGROUND_TASKS":"0"}}'; Key = 'CLAUDE_CODE_DISABLE_BACKGROUND_TASKS'; Hidden = $true },
    @{ Name = 'managed-policy'; Path = (Join-Path $managedRoot 'HKLM.Settings.json'); Text = '{"env":{"CLAUDE_CODE_AUTO_BACKGROUND_TIMEOUT_MS":""}}'; Key = 'CLAUDE_CODE_AUTO_BACKGROUND_TIMEOUT_MS' },
    @{ Name = 'user'; Path = (Join-Path $claudeConfigDir 'settings.json'); Text = '{"env":{"BASH_MAX_TIMEOUT_MS":'; Key = 'not valid JSON' }
  )
  foreach ($case in $conflictCases) {
    $original = if (Test-Path -LiteralPath $case.Path) { [IO.File]::ReadAllBytes($case.Path) } else { $null }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $case.Path) | Out-Null
    [IO.File]::WriteAllText($case.Path, $case.Text, [Text.UTF8Encoding]::new($false))
    if ($case.Hidden) { [IO.File]::SetAttributes($case.Path, [IO.File]::GetAttributes($case.Path) -bor [IO.FileAttributes]::Hidden) }
    $plantedHash = (Get-FileHash -LiteralPath $case.Path -Algorithm SHA256).Hash
    try {
      $relative = [IO.Path]::GetRelativePath($testRoot, $case.Path)
      $scenario = Invoke-PolicyScenario -Name "conflict-$($case.Name)"
      $ledger = Join-Path $runtimeRoot 'dispatch-log.jsonl'
      $ledgerRow = (Test-Path -LiteralPath $ledger) -and ([IO.File]::ReadAllText($ledger)).Contains($scenario.label)
      Assert-Policy ($scenario.exitCode -ne 0 -and $null -eq $scenario.child -and -not $scenario.transcriptPresent -and -not $ledgerRow) `
        "AC1 $($case.Name) settings conflict in $relative refuses before any ledger row or Claude child"
      Assert-Policy ($scenario.diagnostics.Contains('CLAUDE_FOREGROUND_POLICY_CONFLICT') -and $scenario.diagnostics.Contains($case.Name) -and
        $scenario.diagnostics.Contains([IO.Path]::GetFullPath($case.Path)) -and $scenario.diagnostics.Contains($case.Key)) `
        "AC1 $($case.Name) refusal names its source, file and $($case.Key)"
      if ($case.Text.Contains('590000')) {
        Assert-Policy (-not $scenario.diagnostics.Contains('590000')) "AC1 $($case.Name) refusal does not echo the conflicting settings value"
      }
      Assert-ParentUnchanged $scenario "$($case.Name) refusal"
      Assert-Policy ((Get-FileHash -LiteralPath $case.Path -Algorithm SHA256).Hash -ceq $plantedHash) "AC1 $($case.Name) refusal never edits the conflicting settings file"
    } finally {
      if ($null -eq $original) { Remove-Item -LiteralPath $case.Path -Force } else { [IO.File]::WriteAllBytes($case.Path, $original) }
    }
  }

  # --- AC1: managed drop-ins Claude never loads cannot conflict ---------------
  # Claude 2.1.299 loads a managed-settings.d entry only when its name ends in
  # an ordinal ".json" and does not start with "."; file attributes do not matter.
  foreach ($ignored in @('.inactive.json', '50-timeouts.JSON')) {
    $ignoredPath = Join-Path $managedRoot "managed-settings.d/$ignored"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ignoredPath) | Out-Null
    [IO.File]::WriteAllText($ignoredPath, '{"env":{"BASH_MAX_TIMEOUT_MS":"590000"}}', [Text.UTF8Encoding]::new($false))
    try {
      $scenario = Invoke-PolicyScenario -Name 'ignored-drop-in'
      $observed = if ($scenario.child) { [string]$scenario.child.environment.BASH_MAX_TIMEOUT_MS } else { 'not-captured' }
      Assert-Policy ($scenario.exitCode -eq 0 -and $observed -ceq '3600000' -and -not $scenario.diagnostics.Contains('CLAUDE_FOREGROUND_POLICY_CONFLICT')) `
        "AC1 managed drop-in '$ignored', which Claude never loads, neither conflicts nor refuses the launch"
    } finally { Remove-Item -LiteralPath $ignoredPath -Force }
  }

  # --- AC1: a stable conflict refuses preparation and dry runs too ------------
  # The host prelogs a prepared strict tuple and then launches, so a conflict
  # already present must refuse while preparing: no prepared route or plan, no
  # ledger row, no child. A strict review reaches Claude through a capacity
  # flip, so the check follows the flip. Same-value settings and Codex routes
  # still prepare.
  $userSettingsPath = Join-Path $claudeConfigDir 'settings.json'
  $conflictingUserSettings = '{"env":{"BASH_MAX_TIMEOUT_MS":"600000"}}'
  $forecastPath = Join-Path $env:CHASE_SETS_ROUTING_DATA_ROOT 'capacity-forecast.json'
  $seedHead = (@(& git -C $worktree rev-parse HEAD) -join '').Trim()
  $strictReview = @{ PrepareRoute = $true; ReviewTarget = 'controller'; ControllerIssue = 997120; ControllerHead = $seedHead
    AuthorAttempt = 'synthetic-policy-author'; ReviewerAttempt = 'synthetic-policy-reviewer'; AuthorModel = 'gpt-6-astra'; ReviewAuthority = 'governing' }
  $strictRoute = @{ Harness = 'codex'; LaneRole = 'review'; Model = 'gpt-6.1-sol'; Effort = 'high'; Row = 11; Placement = 'provisional'; Extra = $strictReview }
  $codexRoute = @{ Harness = 'codex'; Model = 'gpt-6.1-sol'; Effort = 'high'; Row = 4; Placement = 'provisional' }
  function ConvertFrom-PolicyOutput([string]$Text) { try { $Text | ConvertFrom-Json -DateKind String } catch { $null } }
  function Set-PolicyForecast([string]$Toward) {
    $now = [DateTimeOffset]::UtcNow
    $forecast = [ordered]@{ format = 'capacity-forecast/v1'; mode = 'active'; generatedAt = $now.AddMinutes(-1).ToString('o'); staleAfter = $now.AddMinutes(14).ToString('o')
      decisionDigest = 'fedcba9876543210'; providers = @{ codex = @{ state = 'conserve' }; claude = @{ state = 'spend' } }; balance = @{ toward = $Toward; steps = 1 } }
    [IO.File]::WriteAllText($forecastPath, ($forecast | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
  }
  function Test-PreparationRefused($Scenario) {
    $ledger = Join-Path $runtimeRoot 'dispatch-log.jsonl'
    $ledgerRow = (Test-Path -LiteralPath $ledger) -and ([IO.File]::ReadAllText($ledger)).Contains($Scenario.label)
    $Scenario.exitCode -ne 0 -and $Scenario.diagnostics.Contains('CLAUDE_FOREGROUND_POLICY_CONFLICT') -and
      $Scenario.diagnostics.Contains([IO.Path]::GetFullPath($userSettingsPath)) -and -not $Scenario.output.Contains('"prepared"') -and
      -not $Scenario.output.Contains('"heavyAdmission"') -and $null -eq $Scenario.child -and -not $Scenario.transcriptPresent -and -not $ledgerRow
  }
  $preparationCases = @(
    @{ Name = 'prepare-ordinary'; Context = 'ordinary Claude PrepareRoute'; Route = @{ Extra = @{ PrepareRoute = $true } }; Toward = ''
      Accepts = { param($p) $p.prepared -eq $true -and $p.harness -ceq 'claude' -and $null -eq $p.strictTuple } },
    @{ Name = 'dry-run'; Context = 'Claude DryRun'; Route = @{ Extra = @{ DryRun = $true } }; Toward = ''
      Accepts = { param($p) $p.harness -ceq 'claude' -and $null -ne $p.heavyAdmission } },
    @{ Name = 'prepare-strict'; Context = 'strict controller PrepareRoute flipped to Claude'; Route = $strictRoute; Toward = 'claude'
      Accepts = { param($p) $p.prepared -eq $true -and $p.strictTuple.harness -ceq 'claude' -and $p.strictTuple.reviewerModel -ceq 'claude-opus-5-5' } }
  )
  $codexCases = @(
    @{ Name = 'codex-prepare'; Context = 'Codex PrepareRoute'; Route = $codexRoute + @{ Extra = @{ PrepareRoute = $true } }
      Accepts = { param($p) $p.prepared -eq $true -and $p.harness -ceq 'codex' } },
    @{ Name = 'codex-dry-run'; Context = 'Codex DryRun'; Route = $codexRoute + @{ Extra = @{ DryRun = $true } }
      Accepts = { param($p) $p.harness -ceq 'codex' -and $null -ne $p.heavyAdmission } },
    @{ Name = 'codex-prepare-strict'; Context = 'unflipped strict controller Codex PrepareRoute'; Route = $strictRoute
      Accepts = { param($p) $p.prepared -eq $true -and $p.strictTuple.harness -ceq 'codex' -and $p.strictTuple.reviewerModel -ceq 'gpt-6.1-sol' } }
  )
  try {
    foreach ($case in $preparationCases) {
      $route = $case.Route
      if ($case.Toward) { Set-PolicyForecast $case.Toward }
      try {
        [IO.File]::WriteAllText($userSettingsPath, $conflictingUserSettings, [Text.UTF8Encoding]::new($false))
        $refused = Invoke-PolicyScenario -Name "conflict-$($case.Name)" @route
        Assert-Policy (Test-PreparationRefused $refused) "AC1 $($case.Context) refuses a stable settings conflict with no prepared route, plan, ledger row or child"
        [IO.File]::WriteAllText($userSettingsPath, $unrelatedUserSettings, [Text.UTF8Encoding]::new($false))
        $accepted = Invoke-PolicyScenario -Name "same-value-$($case.Name)" @route
        Assert-Policy ($accepted.exitCode -eq 0 -and (& $case.Accepts (ConvertFrom-PolicyOutput $accepted.output))) "AC1 $($case.Context) still prepares under same-value settings"
      } finally {
        if (Test-Path -LiteralPath $forecastPath) { Remove-Item -LiteralPath $forecastPath -Force }
      }
    }
    [IO.File]::WriteAllText($userSettingsPath, $conflictingUserSettings, [Text.UTF8Encoding]::new($false))
    foreach ($case in $codexCases) {
      $route = $case.Route
      $codexScenario = Invoke-PolicyScenario -Name $case.Name @route
      Assert-Policy ($codexScenario.exitCode -eq 0 -and (& $case.Accepts (ConvertFrom-PolicyOutput $codexScenario.output))) "AC4 $($case.Context) ignores a conflicting Claude setting"
    }
    # Resumed integration is capacity-exempt, so its harness is final before
    # admission. A shape-invalid binding keeps every run short of the fleet
    # admission (the heavy slot): a conflict must refuse before the binding is
    # read, and the same-value control must reach the binding refusal instead.
    $resumeBinding = Join-Path $testRoot 'resume-binding-shape-invalid.json'
    [IO.File]::WriteAllText($resumeBinding, '{}', [Text.UTF8Encoding]::new($false))
    $resumeObserved = Join-Path $testRoot 'resume-admission.observed'
    $fableResume = @{ Model = 'claude-fable-5-1'; Effort = 'high'; Row = 7; Placement = 'override-Todd'
      Extra = @{ InterruptedIntegrationResumePath = $resumeBinding; ResumeAdmissionObservedPath = $resumeObserved; ResumeAdmissionContinuePath = (Join-Path $testRoot 'resume-admission.continue') } }
    $resumeRefused = Invoke-PolicyScenario -Name 'conflict-fable-resume' @fableResume
    Assert-Policy ((Test-PreparationRefused $resumeRefused) -and -not $resumeRefused.diagnostics.Contains('INTEGRATION_RESUME') -and -not (Test-Path -LiteralPath $resumeObserved)) `
      'AC1 eligible Fable resume refuses a settings conflict before reading its binding or entering fleet admission'
    [IO.File]::WriteAllText($userSettingsPath, $unrelatedUserSettings, [Text.UTF8Encoding]::new($false))
    $resumeControl = Invoke-PolicyScenario -Name 'same-value-fable-resume' @fableResume
    Assert-Policy ($resumeControl.exitCode -ne 0 -and $resumeControl.diagnostics.Contains('INTEGRATION_RESUME_BINDING: target mismatch') -and
      -not $resumeControl.diagnostics.Contains('CLAUDE_FOREGROUND_POLICY_CONFLICT') -and -not (Test-Path -LiteralPath $resumeObserved)) `
      'AC1 same-value Fable resume passes the settings check and stops at its binding, still short of fleet admission'
  } finally {
    [IO.File]::WriteAllText($userSettingsPath, $unrelatedUserSettings, [Text.UTF8Encoding]::new($false))
  }

  # --- AC4: Codex launch, environment, prompt and inheritance are unchanged ---
  [IO.File]::WriteAllText((Join-Path $claudeConfigDir 'settings.json'), '{"env":{"BASH_MAX_TIMEOUT_MS":"600000"}}', [Text.UTF8Encoding]::new($false))
  $codex = Invoke-PolicyScenario -Name 'codex-implementation' -Harness codex -Model 'gpt-6.1-sol' -Effort high -Row 4 -Placement provisional
  [IO.File]::WriteAllText((Join-Path $claudeConfigDir 'settings.json'), $unrelatedUserSettings, [Text.UTF8Encoding]::new($false))
  Assert-Policy ($codex.exitCode -eq 0 -and $null -ne $codex.child) 'AC4 Codex launch ignores Claude settings and launches its inert child'
  $codexInherits = $null -ne $codex.child
  foreach ($entry in $conflictingParent.GetEnumerator()) {
    if (-not $codexInherits -or [string]$codex.child.environment.($entry.Key) -cne $entry.Value) { $codexInherits = $false }
  }
  Assert-Policy $codexInherits 'AC4 Codex child inherits all four parent values unchanged'
  Assert-Policy ($codex.child -and -not ([string]$codex.child.prompt).Contains('Claude foreground-only execution contract')) 'AC4 Codex prompt carries no Claude preamble'
  Assert-ParentUnchanged $codex 'Codex launch'
  $fakeCodex = Join-Path $testRoot 'fake-codex.exe'
  Set-Content -LiteralPath $fakeCodex -Value ''
  $codexPlan = & $launcher -Harness codex -Model gpt-6.1-sol -Effort high -Row 4 -Placement provisional -LaneRole implementation `
    -PromptFile $prompt -Worktree $worktree -Label "test-codex-plan-$([guid]::NewGuid().ToString('N').Substring(0, 12))" -DryRun `
    -ExecutablePath $fakeCodex | ConvertFrom-Json
  $expectedCodexArguments = @('exec', '-m', 'gpt-6.1-sol', '-c', 'model_provider=account_pool', '-c', 'model_reasoning_effort=high', '-c', 'features.apps=false', '--json',
    '--dangerously-bypass-approvals-and-sandbox', '-C', $codexPlan.workingDirectory, '-')
  Assert-Policy ((@($codexPlan.arguments) | ConvertTo-Json -Compress) -ceq ($expectedCodexArguments | ConvertTo-Json -Compress)) 'AC4 Codex arguments are unchanged'

  # --- AC4: launcher pins hidden windows, native PS7 and child-only policy ----
  $launcherSource = [IO.File]::ReadAllText($launcher)
  $tokens = $null; $parseErrors = $null
  $launcherAst = [Management.Automation.Language.Parser]::ParseInput($launcherSource, [ref]$tokens, [ref]$parseErrors)
  $startParameterHashes = @($launcherAst.FindAll({ param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$startParameters' }, $true))
  $hidden = $startParameterHashes.Count -eq 1 -and $startParameterHashes[0].Right.Extent.Text -match 'WindowStyle\s*=\s*"Hidden"'
  Assert-Policy ($parseErrors.Count -eq 0 -and $hidden) 'AC4 the one Claude/Codex child Start-Process stays WindowStyle Hidden'
  Assert-Policy ($launcherSource.Contains('requires PowerShell 7.4+ Start-Process -Environment') -and $codex.parent -and $codex.parent.psEdition -ceq 'Core') `
    'AC4 the launcher still requires native PowerShell 7 Start-Process -Environment'
  Assert-Policy ($launcherSource -notmatch '\$env:(BASH_|CLAUDE_CODE_)\w*\s*=' -and $launcherSource -notmatch 'SetEnvironmentVariable') `
    'AC1 the policy is applied only to the child environment, never to the launcher process'

  # --- AC3: the #6005 completion audit is unchanged and still bites ----------
  $successResult = [ordered]@{ type = 'result'; subtype = 'success'; is_error = $false; result = 'done' }
  $controls = @(
    @{ Name = 'active-at-success'; Accept = $false; Match = 'active at delivery success'; Events = @(
        [ordered]@{ type = 'system'; subtype = 'background_tasks_changed'; tasks = @([ordered]@{ task_id = 'bg-active'; task_type = 'local_bash'; description = 'Run terminal verification' }) },
        $successResult) },
    @{ Name = 'backgrounded-then-stopped'; Accept = $false; Match = 'bg-timeout state killed/stopped'; Events = @(
        [ordered]@{ type = 'system'; subtype = 'task_started'; task_id = 'bg-timeout'; description = 'Retry scoped static gate'; is_backgrounded = $false; task_type = 'local_bash' },
        [ordered]@{ type = 'system'; subtype = 'background_tasks_changed'; tasks = @([ordered]@{ task_id = 'bg-timeout'; task_type = 'local_bash'; description = 'Retry scoped static gate' }) },
        [ordered]@{ type = 'system'; subtype = 'task_updated'; task_id = 'bg-timeout'; patch = [ordered]@{ is_backgrounded = $true } },
        [ordered]@{ type = 'system'; subtype = 'task_updated'; task_id = 'bg-timeout'; patch = [ordered]@{ status = 'killed' } },
        [ordered]@{ type = 'system'; subtype = 'task_notification'; task_id = 'bg-timeout'; status = 'stopped'; summary = 'Retry scoped static gate' },
        [ordered]@{ type = 'system'; subtype = 'background_tasks_changed'; tasks = @() },
        $successResult) },
    @{ Name = 'stopped-without-snapshot'; Accept = $false; Match = 'bg-snapshot-missed state stopped'; Events = @(
        [ordered]@{ type = 'system'; subtype = 'task_notification'; task_id = 'bg-snapshot-missed'; status = 'stopped'; summary = 'Terminal task with a missing active snapshot' },
        $successResult) },
    @{ Name = 'malformed-json'; Accept = $false; Match = 'malformed stream-json'; Partial = '{"type":"system","subtype":"background_tasks_changed","tasks":['; Events = @($successResult) },
    @{ Name = 'foreground-completion'; Accept = $true; Events = @(
        [ordered]@{ type = 'system'; subtype = 'task_started'; task_id = 'fg-gate'; description = 'Run focused gate'; is_backgrounded = $false; task_type = 'local_bash' },
        [ordered]@{ type = 'system'; subtype = 'task_notification'; task_id = 'fg-gate'; status = 'completed'; summary = 'Run focused gate' },
        $successResult) },
    @{ Name = 'failed-without-killed-or-stopped'; Accept = $true; Events = @(
        [ordered]@{ type = 'system'; subtype = 'task_started'; task_id = 'fg-failed'; description = 'Short-deadline command'; is_backgrounded = $false; task_type = 'local_powershell' },
        [ordered]@{ type = 'system'; subtype = 'task_notification'; task_id = 'fg-failed'; status = 'failed'; summary = 'Short-deadline command' },
        $successResult) },
    @{ Name = 'cleared-completed-history'; Accept = $true; Events = @(
        [ordered]@{ type = 'system'; subtype = 'background_tasks_changed'; tasks = @([ordered]@{ taskId = 'bg-cleared'; taskType = 'local_powershell'; summary = 'Bounded task' }) },
        [ordered]@{ type = 'system'; subtype = 'task_notification'; taskId = 'bg-cleared'; state = 'completed' },
        [ordered]@{ type = 'system'; subtype = 'background_tasks_changed'; tasks = @() },
        $successResult) }
  )
  foreach ($control in $controls) {
    $control.Path = Join-Path $testRoot "audit-$($control.Name).jsonl"
    [IO.File]::WriteAllLines($control.Path, [string[]]@($control.Events | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 20 }), [Text.UTF8Encoding]::new($false))
    if ($control.Partial) { [IO.File]::AppendAllText($control.Path, $control.Partial, [Text.UTF8Encoding]::new($false)) }
  }
  $incidentControl = $null
  if ($IncidentTranscript) {
    $incidentPath = [IO.Path]::GetFullPath($IncidentTranscript)
    $incidentHash = (Get-FileHash -LiteralPath $incidentPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-Policy ($incidentHash -ceq $incidentSha256) "AC3 replay input is the complete retained #9585 transcript (SHA256 $incidentSha256)"
    $incidentControl = @{ Name = 'retained-9585-transcript'; Accept = $false; Match = 'b7g04cpkn state killed/stopped'; Path = $incidentPath }
    $controls += $incidentControl
  } else {
    Write-Output 'NOT_EXECUTED AC3 retained #9585 transcript replay (pass -IncidentTranscript <9585-impl-g1.jsonl>)'
  }
  function Test-AuditControl($Control, $Audit) {
    if ($Control.Accept) { return [bool]$Audit.accepted }
    return (-not $Audit.accepted) -and ((@($Audit.diagnostics) -join "`n").Contains($Control.Match))
  }
  foreach ($control in $controls) {
    $audit = Test-ClaudeStreamJsonCompletion $control.Path
    $verdict = if ($control.Accept) { 'accepts' } else { "rejects ($($control.Match))" }
    Assert-Policy (Test-AuditControl $control $audit) "AC3 unchanged audit $verdict $($control.Name)"
  }
  # Disposable rejection-disabled mutant: every rejection control must catch it.
  $auditSource = [IO.File]::ReadAllText($auditHelper)
  $mutantSource = $auditSource.Replace('accepted = $auditErrors.Count -eq 0', 'accepted = $true')
  Assert-Policy ($mutantSource -cne $auditSource) 'AC3 rejection-disabled mutant differs from the audit in exactly its acceptance verdict'
  $caught = @(& {
      . ([scriptblock]::Create($mutantSource))
      foreach ($control in $controls | Where-Object { -not $_.Accept }) {
        if (-not (Test-AuditControl $control (Test-ClaudeStreamJsonCompletion $control.Path))) { $control.Name }
      }
    })
  $rejectionControls = @($controls | Where-Object { -not $_.Accept } | ForEach-Object { $_.Name })
  Assert-Policy (($caught -join ',') -ceq ($rejectionControls -join ',')) "AC3 every rejection control fails against the rejection-disabled mutant ($($rejectionControls -join ', '))"
} finally {
  Exit-RoutingDataTestScope $routingTestScope
  if (((Split-Path -Parent $testRootResolved).TrimEnd('\', '/')) -ne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')) -or
      (Split-Path -Leaf $testRootResolved) -notlike 'claude-foreground-policy-test-*') {
    throw "refusing unsafe test cleanup target: $testRootResolved"
  }
  Remove-Item -LiteralPath $testRootResolved -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
  throw "ASSERTION FAILED: $($failures.Count) claude foreground policy assertion(s): $($failures -join ' | ')"
}
Write-Output 'PASS claude foreground policy'
