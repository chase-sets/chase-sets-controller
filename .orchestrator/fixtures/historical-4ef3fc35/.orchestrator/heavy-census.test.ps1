[CmdletBinding()]
param(
  [string]$GuardRevision = '',
  [ValidateSet('', 'omit-truncation', 'fixed-deadline', 'unbounded-deadline')]
  [string]$Mutant = '',
  [switch]$SafetyOnly
)

$ErrorActionPreference = 'Stop'
(Get-Process -Id $PID).PriorityClass = 'BelowNormal'
function Assert-True($Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}
function Read-Source([string]$Name) {
  if (-not $GuardRevision) { return [IO.File]::ReadAllText((Join-Path $PSScriptRoot $Name)) }
  $lines = @(& git -C (Split-Path -Parent $PSScriptRoot) show "${GuardRevision}:.orchestrator/$Name")
  if ($LASTEXITCODE -ne 0) { throw "cannot read $Name at $GuardRevision" }
  return $lines -join "`n"
}
. ([scriptblock]::Create((Read-Source 'dispatch-ownership.ps1')))
$source = Read-Source 'invoke-heavy-verifier.ps1'
$needle = switch ($Mutant) {
  'omit-truncation' { '$live.health.counts.truncated -gt 0 -or ' }
  'fixed-deadline' { 'Get-HeavyOwnershipCensusDeadlineMs $candidateCount' }
  'unbounded-deadline' { '[Math]::Min([long]30000, [Math]::Max([long]5000, 2000 * [long]$CandidateCount))' }
}
if ($Mutant) {
  Assert-True ($source.Contains($needle)) "mutant target exists: $Mutant"
  $replacement = switch ($Mutant) {
    'omit-truncation' { '' }
    'fixed-deadline' { '5000' }
    'unbounded-deadline' { '[Math]::Max([long]5000, 2000 * [long]$CandidateCount)' }
  }
  $source = $source.Replace($needle, $replacement)
}
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
Assert-True ($errors.Count -eq 0) 'guard source parses'
foreach ($definition in $ast.FindAll({ param($n)
    $n -is [Management.Automation.Language.FunctionDefinitionAst]
  }, $false)) {
  . ([scriptblock]::Create($definition.Extent.Text))
}

# Exercise the production eligibility/binding functions and the real census,
# record parser, routing reader and filesystem. Only OS/Git observations are
# synthetic; this focused test never reserves either heavy slot or runs a body.
$census = ${function:Get-LiveDispatchOwnership}
$fixture = @{ DelayMs = 700; Mode = 'healthy'; GitCalls = 0; Last = $null; Deadline = 0; Calls = 0 }
$instant = [datetime]::SpecifyKind([datetime]'2026-01-01', [DateTimeKind]::Utc)
function Get-Process([int]$Id) { [pscustomobject]@{ StartTime = $instant } }
function Get-HeavyCallerAncestry { return @{ 9012 = $instant.Ticks } }
function Get-DispatchGitIdentity([string]$Worktree) {
  if ($fixture.Mode -ceq 'git-failed') { return [pscustomobject]@{ status = 'failed' } }
  return [pscustomobject]@{ status = 'ok'; worktree = $Worktree; branch = 'synthetic/census'; head = ('a' * 40) }
}
function Get-LiveDispatchOwnership {
  param($RuntimeRoot, $TempRoot, $ContainerRoot, [int]$DeadlineMs = 5000, [scriptblock]$GitIdentityResolver)
  $fixture.Deadline = $DeadlineMs
  $fixture.Calls++
  $callerGitResolver = $GitIdentityResolver
  $parameters = @{
    RuntimeRoot = $RuntimeRoot; TempRoot = $TempRoot; ContainerRoot = $ContainerRoot; DeadlineMs = $DeadlineMs
    ProcessStateResolver = { param($ProcessId, $StartIdentity)
      if ($fixture.Mode -ceq 'process-unknown') { return 'failed' }
      return 'live'
    }
    GitIdentityResolver = {
      param($Worktree)
      $fixture.GitCalls++
      if ($fixture.DelayMs) { Start-Sleep -Milliseconds $fixture.DelayMs }
      & $callerGitResolver $Worktree
    }
  }
  if ($fixture.Mode -ceq 'deadline') { $parameters.DeadlineMs = 1 }
  if ($fixture.Mode -ceq 'record-cap') { $parameters.MaxRecords = 0 }
  $fixture.Last = & $census @parameters
  if ($fixture.Mode -ceq 'deadline') {
    # An unexamined containing launch can disappear before the binding's next
    # enumeration. Removing only that evidence must not turn its child into a
    # standalone host. This isolates the truncation guard from count mismatch.
    $examined = @($fixture.Last.activeLanes.ownershipRecordPath)
    foreach ($path in $recordBytes.Keys) {
      if ($path -notin $examined) { [IO.File]::Delete($path) }
    }
  }
  return $fixture.Last
}

$temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
$root = Join-Path $temp ('heavy-census-test-' + [guid]::NewGuid().ToString('N'))
$container = Join-Path $root 'container'
$runtime = Join-Path $container '.orchestrator'
$recordBytes = @{}
$isAttachedAdmission = $true
$GuardedPid = 9012
$GuardedProcessStartUtc = $instant.ToString('o')
try {
  [IO.Directory]::CreateDirectory($runtime) | Out-Null
  foreach ($number in 1..12) {
    $launch = '00000000-0000-0000-0000-{0:d12}' -f $number
    $lane = 'synthetic-{0:d2}' -f $number
    $worktree = Join-Path $container $lane
    [IO.Directory]::CreateDirectory($worktree) | Out-Null
    $record = [pscustomobject][ordered]@{
      schemaVersion = 4; launchId = $launch; laneRole = 'implementation'
      promptPath = (Join-Path $runtime "dispatch-heavy-verifier-$launch.prompt.txt"); reviewIsolationRoot = $null
      launcherPid = 8000; launcherStartIdentity = $instant.AddSeconds(-2).ToString('o')
      recordedAt = $instant.AddSeconds(-1).ToString('o'); state = 'started'
      childPid = 9000 + $number; childStartIdentity = $instant.ToString('o')
      worktree = $worktree; lane = $lane; identityMode = 'branch'; branch = 'synthetic/census'; head = ('a' * 40)
      label = $lane; transcriptPath = (Join-Path $runtime "$lane.jsonl")
    }
    $path = Join-Path $runtime "dispatch-launch-$launch.json"
    Write-DispatchOwnershipRecord $path $record -CreateNew
    $recordBytes[$path] = [IO.File]::ReadAllText($path)
    [IO.File]::WriteAllText($record.transcriptPath, "{`"type`":`"item.completed`"}`n")
  }
  $caller = $record
  $callerPath = $path
  $acquiredGitIdentity = [pscustomobject]@{ Worktree = $caller.worktree; Branch = $caller.branch; Head = $caller.head }
  $routing = [ordered]@{
    ts = $instant.AddMilliseconds(-1).ToString('o'); kind = 'dispatch'; dispatchRoutingSchema = 'watchdog-dispatch-routing/v1'
    attemptId = 'synthetic-census'; label = $caller.label; lane = $caller.lane; laneRole = 'implementation'
    transcript = "$($caller.label).jsonl"; harness = 'codex'; model = 'gpt-6-astra'; effort = 'high'; row = '7'; placement = 'override-Todd'
    worktree = $caller.worktree; branch = $caller.branch; head = $caller.head
  }
  [IO.File]::WriteAllText((Join-Path $runtime 'dispatch-log.jsonl'), ($routing | ConvertTo-Json -Compress) + "`n")

  if (-not $SafetyOnly) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $binding = Get-HeavyCallerBinding
    $watch.Stop()
    $counts = $fixture.Last.health.counts
    Write-Output "SLOW_CENSUS revision=$GuardRevision mutant=$Mutant elapsedMs=$($watch.ElapsedMilliseconds) deadlineMs=$($fixture.Deadline) candidates=$($counts.candidates) examined=$($counts.examined) active=$($counts.active) truncated=$($counts.truncated) gitCalls=$($fixture.GitCalls) reason=$($binding.Reason)"
    Assert-True (-not $binding.Reason -and $binding.Record.launchId -ceq $caller.launchId -and $binding.Row -eq 7) '12 slow live records admit the exact dispatched caller'
    Assert-True ($counts.examined -eq 12 -and $counts.truncated -eq 0 -and $fixture.GitCalls -eq 12 -and $fixture.Calls -eq 1) 'complete fresh census, no cached identity or retry'
    Assert-True ($fixture.Deadline -eq 24000) '12 candidates select the bounded 24000ms heavy-only allowance'
    # The admission-time recheck must perform fresh Git observations too.
    $fixture.DelayMs = 0
    $again = Assert-HeavyCallerEligibility $binding
    Assert-True ($again.Record.launchId -ceq $caller.launchId -and $fixture.GitCalls -eq 24) 'canonical eligibility recheck reads fresh ownership and Git'
    Write-Output 'PASS slow census and canonical exact-binding eligibility recheck'
  }

  foreach ($case in @(@(0,5000), @(1,5000), @(2,5000), @(3,6000), @(11,22000), @(12,24000), @(15,30000), @(64,30000), @([int]::MaxValue,30000))) {
    Assert-True ((Get-HeavyOwnershipCensusDeadlineMs $case[0]) -eq $case[1]) "candidate deadline count=$($case[0]) expected=$($case[1])"
  }
  Write-Output 'PASS deadline floor, candidate scaling, hard ceiling and overflow boundary'

  $fixture.DelayMs = 0
  foreach ($mode in @('process-unknown', 'git-failed', 'invalid', 'legacy', 'transcript-unknown', 'duplicate', 'deadline', 'record-cap')) {
    $fixture.Mode = $mode
    $fixture.DelayMs = if ($mode -ceq 'deadline') { 5 } else { 0 }
    if ($mode -ceq 'invalid') { [IO.File]::WriteAllText($callerPath, '{}') }
    if ($mode -ceq 'legacy') {
      $legacy = $recordBytes[$callerPath] | ConvertFrom-Json -DateKind String
      $legacy.schemaVersion = 3
      $legacy.PSObject.Properties.Remove('label'); $legacy.PSObject.Properties.Remove('transcriptPath')
      [IO.File]::WriteAllText($callerPath, ($legacy | ConvertTo-Json -Compress))
    }
    if ($mode -ceq 'transcript-unknown') { [IO.File]::WriteAllText($caller.transcriptPath, "not-json`n") }
    if ($mode -ceq 'duplicate') {
      $otherPath = @($recordBytes.Keys | Sort-Object)[0]
      $duplicate = $recordBytes[$otherPath] | ConvertFrom-Json -DateKind String
      $duplicate.worktree = $caller.worktree; $duplicate.lane = $caller.lane
      [IO.File]::WriteAllText($otherPath, ($duplicate | ConvertTo-Json -Compress))
    }
    $reason = ''
    try { Assert-HeavyCallerEligibility | Out-Null } catch { $reason = $_.Exception.Message }
    if ($mode -ceq 'deadline') {
      Assert-True ($fixture.Last.health.counts.truncated -gt 0 -and
        @($fixture.Last.activeLanes | Where-Object launchId -CEQ $caller.launchId).Count -eq 0 -and
        -not [IO.File]::Exists($callerPath)) 'deadline leaves the containing record unexamined, then absent'
    }
    Assert-True ($reason -ceq 'heavy-verifier: caller eligibility: dispatch census unknown or incomplete') "fail closed for $mode (observed=$reason)"
    Write-Output "PASS fail-closed $mode"
    foreach ($entry in $recordBytes.GetEnumerator()) { [IO.File]::WriteAllText($entry.Key, $entry.Value) }
    [IO.File]::WriteAllText($caller.transcriptPath, "{`"type`":`"item.completed`"}`n")
  }
  $fixture.Mode = 'healthy'; $fixture.DelayMs = 0
  $restored = Assert-HeavyCallerEligibility
  Assert-True ($restored.Record.launchId -ceq $caller.launchId) 'same inputs admit once the governing defects are removed'
  Write-Output 'PASS restored exact caller; no heavy reservation or command body executed'
} finally {
  $resolved = [IO.Path]::GetFullPath($root)
  Assert-True ((Split-Path -Parent $resolved) -ceq $temp -and
    (Split-Path -Leaf $resolved) -like 'heavy-census-test-*') 'cleanup stays in this test-created temp root'
  if ([IO.Directory]::Exists($resolved)) { [IO.Directory]::Delete($resolved, $true) }
}
