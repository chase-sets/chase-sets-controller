[CmdletBinding()]
param([string]$GuardRevision = '',
  [ValidateSet('', 'omit-truncation', 'restore-scaled-budget')][string]$Mutant = '',
  [switch]$SafetyOnly)
$ErrorActionPreference = 'Stop'
function Assert-True($Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}
function Read-Source([string]$Name) {
  if (-not $GuardRevision) { return [IO.File]::ReadAllText((Join-Path $PSScriptRoot $Name)) }
  $lines = @(& git -C (Split-Path -Parent $PSScriptRoot) show "${GuardRevision}:.orchestrator/$Name")
  if ($LASTEXITCODE -ne 0) { throw "cannot read $Name at $GuardRevision" }
  return $lines -join [Environment]::NewLine
}
$fixture = @{ Now = 0L; Cost = 0; Mode = 'healthy'; Calls = 0; GitCalls = 0; Last = $null
  Pending = [Collections.Generic.List[int]]::new(); Hook = $null; MaxRecords = 64 }
function New-CensusClock {
  $clock = [pscustomobject]@{ Source = $fixture; Origin = $fixture.Now }
  $clock | Add-Member ScriptProperty ElapsedMilliseconds { $this.Source.Now - $this.Origin }
  $clock | Add-Member ScriptMethod Restart { $this.Origin = $this.Source.Now }
  return $clock
}
$ownershipSource = Read-Source 'dispatch-ownership.ps1'
# Before the additive seam commit, meter the existing private construction.
# No authority, timeout, counter or census result is replaced.
if (-not $ownershipSource.Contains('[scriptblock]$ClockResolver')) {
  $ownershipSource = $ownershipSource.Replace('watch=[Diagnostics.Stopwatch]::new();deadline=$DeadlineMs',
    'watch=(New-CensusClock);deadline=$DeadlineMs')
}
. ([scriptblock]::Create($ownershipSource))
$source = Read-Source 'invoke-heavy-verifier.ps1'
if ($Mutant -ceq 'omit-truncation') {
  $needle = '$live.health.counts.truncated -gt 0 -or '
  Assert-True ($source.Contains($needle)) 'omit-truncation target exists'
  $source = $source.Replace($needle, '')
  # Isolate the counter guard: diagnostics cannot mask its omission.
  $source = $source.Replace('(Get-DispatchBlockingDiagnostics $live)', '$false')
}
if ($Mutant -ceq 'restore-scaled-budget') {
  $needle = '$censusDeadlineMs = [int][Math]::Min($RemainingMs, $Evaluation.deadline-$Evaluation.watch.ElapsedMilliseconds)'
  Assert-True ($source.Contains($needle)) 'restore-scaled-budget target exists'
  $source = $source.Replace($needle,
    '$censusDeadlineMs = [int][Math]::Min([Math]::Min(30000, [Math]::Max(5000, 2000 * $beforePaths.Count)), [Math]::Min($RemainingMs, $Evaluation.deadline-$Evaluation.watch.ElapsedMilliseconds))')
}
# Instrument only clock construction in extracted production functions.
$source = $source.Replace('[Diagnostics.Stopwatch]::StartNew()', '(New-CensusClock)')
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
Assert-True ($errors.Count -eq 0) 'guard source parses'
foreach ($definition in $ast.FindAll({ param($n)
    $n -is [Management.Automation.Language.FunctionDefinitionAst]
  }, $false)) {
  . ([scriptblock]::Create($definition.Extent.Text))
}
$census = ${function:Get-LiveDispatchOwnership}
$instant = [datetime]::SpecifyKind([datetime]'2026-01-01', [DateTimeKind]::Utc)
function Get-Process([int]$Id) { [pscustomobject]@{ StartTime = $instant } }
function Get-HeavyCallerAncestry {
  if ($fixture.Mode -ceq 'churn-late' -and $fixture.Calls -eq 1) { & $fixture.Hook }
  if ($fixture.Mode -ceq 'churn-persistent') { & $fixture.Hook }
  if ($fixture.Mode -ceq 'churn-selected') { & $fixture.Hook }
  if ($fixture.Mode -ceq 'native-expired') { $fixture.Now = 90001 }
  return @{ 9011 = $instant.Ticks }
}
function Get-DispatchGitIdentity([string]$Worktree) {
  if ($fixture.Mode -ceq 'git-failed') { return [pscustomobject]@{ status = 'failed' } }
  return [pscustomobject]@{ status = 'ok'; worktree = $Worktree; branch = 'synthetic/census'; head = ('a' * 40) }
}
function Write-AdmissionPending([int]$BudgetMs) { $fixture.Pending.Add($BudgetMs) }
function Get-LiveDispatchOwnership {
  param($RuntimeRoot, $TempRoot, $ContainerRoot, [int]$DeadlineMs, [scriptblock]$GitIdentityResolver)
  $fixture.Calls++
  $callerGitResolver = $GitIdentityResolver
  $parameters = @{
    RuntimeRoot = $RuntimeRoot; TempRoot = $TempRoot; ContainerRoot = $ContainerRoot; DeadlineMs = $DeadlineMs
    MaxRecords = $fixture.MaxRecords
    ProcessStateResolver = { param($ProcessId, $StartIdentity)
      if ($fixture.Mode -ceq 'process-unknown') { return 'failed' }
      return 'live'
    }
    GitIdentityResolver = {
      param($Worktree)
      $fixture.GitCalls++
      $fixture.Now += $fixture.Cost
      & $callerGitResolver $Worktree
    }
  }
  if ($ownershipSource.Contains('[scriptblock]$ClockResolver')) { $parameters.ClockResolver = { New-CensusClock } }
  if ($fixture.Mode -ceq 'deadline-persistent' -or
      ($fixture.Mode -ceq 'deadline-once' -and $fixture.Calls -eq 1)) { $parameters.DeadlineMs = 0 }
  $fixture.Last = & $census @parameters
  if ($fixture.Mode -ceq 'churn-early' -and $fixture.Calls -eq 1) { & $fixture.Hook }
  if ($fixture.Mode -ceq 'equal-count-replace' -and $fixture.Calls -eq 1) { & $fixture.Hook }
  if ($fixture.Mode -ceq 'cap-tail') {
    # Remove only the excluded tail after the real cap refuses. Counts now match
    # the next enumeration, isolating completeness from the count-mismatch guard.
    [IO.File]::Delete($tailPath)
  }
  return $fixture.Last
}
function Reset-Fixture([string]$Mode = 'healthy', [int]$Cost = 0, [long]$AdmissionElapsed = 0) {
  foreach ($entry in $recordBytes.GetEnumerator()) { [IO.File]::WriteAllText($entry.Key, $entry.Value) }
  foreach ($path in @($replacementPath, $tailPath)) {
    if ($path -and [IO.File]::Exists($path)) { [IO.File]::Delete($path) }
  }
  $fixture.Now = 0L; $fixture.Cost = $Cost; $fixture.Mode = $Mode
  $fixture.Calls = 0; $fixture.GitCalls = 0; $fixture.Last = $null; $fixture.MaxRecords = 64
  $fixture.Pending.Clear(); $fixture.Hook = $null
  $script:heavyAdmissionBudget = @{ watch = (New-CensusClock); deadline = 210000; observations = 0; fences = 1 }
  $fixture.Now = $AdmissionElapsed
}
function Assert-Refusal([string]$Reason, [string]$Case) {
  $binding = Get-HeavyCallerBinding
  Assert-True ($binding.Reason -ceq $Reason) "$Case reason=$($binding.Reason) expected=$Reason"
  return $binding
}

$temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
$root = Join-Path $temp ('heavy-census-test-' + [guid]::NewGuid().ToString('N'))
$container = Join-Path $root 'container'
$runtime = Join-Path $container '.orchestrator'
$recordBytes = @{}
$isAttachedAdmission = $true
$GuardedPid = 9011
$GuardedProcessStartUtc = $instant.ToString('o')
try {
  [IO.Directory]::CreateDirectory($runtime) | Out-Null
  foreach ($number in 1..11) {
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


  $foreignPath = @($recordBytes.Keys | Sort-Object)[0]
  $replacementPath = Join-Path $runtime 'dispatch-launch-00000000-0000-0000-0000-000000000099.json'
  $replacement = $recordBytes[$foreignPath] | ConvertFrom-Json -DateKind String
  $replacement.launchId = '00000000-0000-0000-0000-000000000099'
  $replacement.promptPath = Join-Path $runtime "dispatch-heavy-verifier-$($replacement.launchId).prompt.txt"
  $replacementRaw = $replacement | ConvertTo-Json -Compress
  $tailPath = Join-Path $runtime 'dispatch-launch-00000000-0000-0000-0000-000000000100.json'

  foreach ($mode in @('churn-early', 'churn-late', 'equal-count-replace')) {
    Reset-Fixture $mode
    $fixture.Hook = {
      [IO.File]::Delete($foreignPath)
      if ($fixture.Mode -ceq 'equal-count-replace') { [IO.File]::WriteAllText($replacementPath, $replacementRaw) }
    }
    $binding = Get-HeavyCallerBinding
    Assert-True (-not $binding.Reason -and $binding.Path -ceq $callerPath -and $fixture.Calls -eq 2) "$mode fresh complete retry: $($binding.Reason)"
    Write-Output "PASS $mode observations=$($fixture.Calls)"
  }
  Reset-Fixture 'churn-persistent'
  $fixture.Hook = {
    $row = [IO.File]::ReadAllText($foreignPath) | ConvertFrom-Json -DateKind String
    $row.recordedAt = $instant.AddSeconds(-1).AddMilliseconds($fixture.Calls).ToString('o')
    [IO.File]::WriteAllText($foreignPath, ($row | ConvertTo-Json -Compress))
  }
  $null = Assert-Refusal 'dispatch census changed' 'churn-persistent'
  Assert-True ($fixture.Calls -eq 3 -and $script:heavyAdmissionBudget.observations -eq 3) 'bounded three observations, no recursive reset'
  Write-Output 'PASS churn-persistent observations=3'

  Reset-Fixture 'churn-selected'
  $fixture.Hook = {
    $row = [IO.File]::ReadAllText($callerPath) | ConvertFrom-Json -DateKind String
    $row.recordedAt = $instant.AddSeconds(-1).AddMilliseconds($fixture.Calls).ToString('o')
    [IO.File]::WriteAllText($callerPath, ($row | ConvertTo-Json -Compress))
  }
  $null = Assert-Refusal 'selected dispatch bytes changed' 'churn-selected'
  Assert-True ($fixture.Calls -eq 1) 'selected drift is never retried'
  Write-Output 'PASS churn-selected'

  Reset-Fixture 'deadline-once'
  $binding = Get-HeavyCallerBinding
  Assert-True (-not $binding.Reason -and $fixture.Calls -eq 2) "deadline-once fresh complete: $($binding.Reason)"
  Reset-Fixture 'deadline-persistent'
  $null = Assert-Refusal 'dispatch census unknown or incomplete' 'deadline-persistent'
  Assert-True ($fixture.Calls -eq 3) 'persistent deadline has exactly three observations'
  Write-Output 'PASS deadline-once/deadline-persistent'

  Reset-Fixture 'native-expired'
  $null = Assert-Refusal 'dispatch census evaluation exhausted' 'native-read-return-expired'
  Assert-True ($fixture.Calls -eq 1) 'expired returned observation never binds'
  Write-Output 'PASS native-read-return-expired'

  Reset-Fixture
  $script:heavyAdmissionBudget.observations = 3
  $script:heavyAdmissionBudget.fences = 1
  $fixture.Mode = 'deadline-persistent'
  $null = Assert-Refusal 'dispatch census evaluation exhausted' 'budget-composition reserved fences'
  Assert-True ($fixture.Calls -eq 1 -and $script:heavyAdmissionBudget.observations -eq 4) 'reserves one observation per remaining fence'
  $script:heavyAdmissionBudget.fences = 2
  $fixture.Mode = 'healthy'
  $binding = Get-HeavyCallerBinding
  Assert-True (-not $binding.Reason -and $script:heavyAdmissionBudget.observations -eq 5) 'second fence consumes shared counter'
  $script:heavyAdmissionBudget.fences = 3
  $binding = Get-HeavyCallerBinding
  Assert-True (-not $binding.Reason -and $script:heavyAdmissionBudget.observations -eq 6) 'third fence consumes last observation'
  $null = Assert-Refusal 'dispatch census evaluation exhausted' 'budget-composition total cap'
  Assert-True ($fixture.Calls -eq 3) 'no observation after six total'
  Reset-Fixture 'healthy' 0 210000
  $null = Assert-Refusal 'dispatch census evaluation exhausted' 'budget-composition admission expiry'
  Assert-True ($fixture.Calls -eq 0) 'expired admission does not start a census'
  Write-Output 'PASS budget-composition six total / three fences / unchanged shared clocks'

  foreach ($cost in @(0)) {
    foreach ($mode in @('invalid', 'process-unknown', 'git-failed', 'legacy', 'cap-tail')) {
      Reset-Fixture $mode $cost
      if ($mode -ceq 'invalid') { [IO.File]::WriteAllText($foreignPath, '{}') }
      if ($mode -ceq 'legacy') {
        $legacy = $recordBytes[$foreignPath] | ConvertFrom-Json -DateKind String
        $legacy.schemaVersion = 3
        $legacy.PSObject.Properties.Remove('label'); $legacy.PSObject.Properties.Remove('transcriptPath')
        [IO.File]::WriteAllText($foreignPath, ($legacy | ConvertTo-Json -Compress))
      }
      if ($mode -ceq 'cap-tail') {
        [IO.File]::WriteAllText($tailPath, $replacementRaw.Replace($replacement.launchId, '00000000-0000-0000-0000-000000000100'))
        $fixture.MaxRecords = 11
      }
      $null = Assert-Refusal 'dispatch census unknown or incomplete' "slow-probe-adverse-matrix $mode cost=$cost"
      Write-Output "PASS slow-probe-adverse-matrix $mode cost=$cost"
    }
  }
  Reset-Fixture
  $binding = Get-HeavyCallerBinding
  Assert-True (-not $binding.Reason -and $binding.Path -ceq $callerPath -and $fixture.GitCalls -eq 11) 'restored exact caller, complete real census'
  Write-Output 'PASS restored exact caller; no heavy reservation or command body executed'
} finally {
  $resolved = [IO.Path]::GetFullPath($root)
  Assert-True ((Split-Path -Parent $resolved) -ceq $temp -and
    (Split-Path -Leaf $resolved) -like 'heavy-census-test-*') 'cleanup stays in this test-created temp root'
  if ([IO.Directory]::Exists($resolved)) { [IO.Directory]::Delete($resolved, $true) }
}
