[CmdletBinding()]
param(
  [string]$GuardRevision = '',
  [ValidateSet('', 'unbound-root', 'launcher-start', 'child-start', 'forged-child', 'cache-record')]
  [string]$Mutant = ''
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
$mutations = @{
  'unbound-root' = @(@{ Find = '$boundDispatchRoot = $false'; Replace = '$boundDispatchRoot = $true' })
  'launcher-start' = @(@{ Find = '$ticks -ne [DateTimeOffset]::Parse($record.launcherStartIdentity).UtcTicks'; Replace = '$false' })
  'child-start' = @(@{ Find = '$chain[[int]$record.childPid] -ne [DateTimeOffset]::Parse($record.childStartIdentity).UtcTicks'; Replace = '$false' })
  'forged-child' = @(
    @{ Find = '-not $chain.ContainsKey([int]$record.childPid)'; Replace = '$false' },
    @{ Find = '$chain[[int]$record.childPid] -ne [DateTimeOffset]::Parse($record.childStartIdentity).UtcTicks'; Replace = '$false' }
  )
  'cache-record' = @(@{ Find = '$key = "$RootPid|$RootStart|$OldestLaunch|$(@($CandidatePids | Sort-Object -Unique) -join '','')|$dispatchRootKey"'; Replace = '$key = "$RootPid|$RootStart|$OldestLaunch|$(@($CandidatePids | Sort-Object -Unique) -join '','')"' })
}
if ($Mutant) {
  foreach ($mutation in $mutations[$Mutant]) {
    Assert-True ($source.Contains($mutation.Find)) "mutant target exists: $Mutant"
    $source = $source.Replace($mutation.Find, $mutation.Replace)
  }
}
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
Assert-True ($errors.Count -eq 0) 'guard source parses'
foreach ($definition in $ast.FindAll({ param($n)
    $n -is [Management.Automation.Language.FunctionDefinitionAst]
  }, $false)) {
  . ([scriptblock]::Create($definition.Extent.Text))
}

# Real binding, census, closed record validator, routing reader and filesystem;
# synthetic OS/Git observations only. No slot, dispatch or command body runs.
$census = ${function:Get-LiveDispatchOwnership}
$instant = [datetime]::SpecifyKind([datetime]'2026-01-01', [DateTimeKind]::Utc)
$processes = @{}
function Get-Process([int]$Id) {
  if (-not $processes.ContainsKey($Id)) { throw 'fixture process exited' }
  return [pscustomobject]@{ StartTime = $processes[$Id].Start }
}
function Get-CimInstance {
  foreach ($id in $processes.Keys) {
    $start = $processes[$id].Start
    [pscustomobject]@{ ProcessId = $id; ParentProcessId = $processes[$id].Parent
      CreationDate = [datetime]::new($start.Ticks - ($start.Ticks % 10), [DateTimeKind]::Utc) }
  }
}
function Get-DispatchGitIdentity([string]$Worktree) {
  [pscustomobject]@{ status = 'ok'; worktree = $Worktree; branch = 'synthetic/ancestry'; head = ('a' * 40) }
}
function Get-LiveDispatchOwnership {
  param($RuntimeRoot, $TempRoot, $ContainerRoot, [int]$DeadlineMs, [scriptblock]$GitIdentityResolver)
  & $census -RuntimeRoot $RuntimeRoot -TempRoot $TempRoot -ContainerRoot $ContainerRoot -DeadlineMs $DeadlineMs `
    -GitIdentityResolver $GitIdentityResolver -ProcessStateResolver {
      param($ProcessId, $StartIdentity)
      if (-not $processes.ContainsKey([int]$ProcessId)) { return 'dead' }
      if ($processes[[int]$ProcessId].Start.Ticks -ne [DateTimeOffset]::Parse($StartIdentity).UtcTicks) { return 'dead' }
      return 'live'
    }
}
$temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
$root = Join-Path $temp ('heavy-ancestry-test-' + [guid]::NewGuid().ToString('N'))
$container = Join-Path $root 'container'
$runtime = Join-Path $container '.orchestrator'
$isAttachedAdmission = $true
$failures = [Collections.Generic.List[string]]::new()
function Check-Binding([string]$Name, [string]$Expected, [switch]$KeepCache) {
  if (-not $KeepCache) { $script:heavyCallerAncestry = $null }
  $binding = Get-HeavyCallerBinding
  $observed = if ($binding.Reason) { $binding.Reason } elseif ($binding.Record) { 'BOUND' } else { 'UNBOUND' }
  $passed = if ($Expected -ceq 'BOUND') {
    $observed -ceq 'BOUND' -and $binding.Record.launchId -ceq $caller.launchId -and $binding.Row -eq 4
  } else { $binding.Reason -and $binding.Reason -match $Expected }
  if (-not $passed) { $failures.Add($Name) }
  Write-Host "$(if ($passed) { 'PASS' } else { 'FAIL' }) $Name expected=$Expected observed=$observed"
  return $binding
}
try {
  [IO.Directory]::CreateDirectory($runtime) | Out-Null
  foreach ($chain in @(
      @{ Name = '8521 seller r1'; Pids = @(39248, 90396, 77320, 68796, 77232, 31988); Child = 77320; Launcher = 68796 },
      @{ Name = '8616 Windows qualification'; Pids = @(50236, 44600, 97804, 102008); Child = 50236; Launcher = 44600 }
    )) {
    $processes.Clear()
    for ($index = 0; $index -lt $chain.Pids.Count - 1; $index++) {
      $processes[$chain.Pids[$index]] = @{ Start = $instant.AddSeconds(30 - $index); Parent = $chain.Pids[$index + 1] }
    }
    # An older unrelated live lane keeps the pre-fix cutoff below the exited
    # wrapper, matching the concurrent-host defect rather than masking it.
    $processes[8000] = @{ Start = $instant; Parent = 0 }
    $processes[9000] = @{ Start = $instant.AddSeconds(1); Parent = 8000 }
    $processes[9999] = @{ Start = $instant.AddSeconds(29); Parent = 0 }
    $paths = @()
    foreach ($number in 1..2) {
      $launch = '00000000-0000-0000-0000-{0:d12}' -f $number
      $lane = "synthetic-$number"
      $worktree = Join-Path $container $lane
      [IO.Directory]::CreateDirectory($worktree) | Out-Null
      $launcher = if ($number -eq 1) { 8000 } else { $chain.Launcher }
      $child = if ($number -eq 1) { 9000 } else { $chain.Child }
      $record = [pscustomobject][ordered]@{
        schemaVersion = 4; launchId = $launch; laneRole = 'implementation'
        promptPath = (Join-Path $runtime "dispatch-heavy-verifier-$launch.prompt.txt"); reviewIsolationRoot = $null
        launcherPid = $launcher; launcherStartIdentity = $processes[$launcher].Start.ToString('o')
        recordedAt = $processes[$launcher].Start.AddTicks(1).ToString('o'); state = 'started'
        childPid = $child; childStartIdentity = $processes[$child].Start.ToString('o')
        worktree = $worktree; lane = $lane; identityMode = 'branch'; branch = 'synthetic/ancestry'; head = ('a' * 40)
        label = $lane; transcriptPath = (Join-Path $runtime "$lane.jsonl")
      }
      $path = Join-Path $runtime "dispatch-launch-$launch.json"
      Write-DispatchOwnershipRecord $path $record
      $paths += $path
      [IO.File]::WriteAllText($record.transcriptPath, "{`"type`":`"item.completed`"}`n")
    }
    $caller = $record; $callerPath = $path
    $original = [IO.File]::ReadAllText($callerPath)
    $acquiredGitIdentity = [pscustomobject]@{ Worktree = $caller.worktree; Branch = $caller.branch; Head = $caller.head }
    $GuardedPid = $chain.Pids[0]; $GuardedProcessStartUtc = $processes[$GuardedPid].Start.ToString('o')
    $routing = [ordered]@{
      ts = $processes[$chain.Child].Start.ToString('o'); kind = 'dispatch'; dispatchRoutingSchema = 'watchdog-dispatch-routing/v1'
      attemptId = 'synthetic-ancestry'; label = $caller.label; lane = $caller.lane; laneRole = 'implementation'
      transcript = "$($caller.label).jsonl"; harness = 'codex'; model = 'gpt-6.1-sol'; effort = 'high'; row = '4'; placement = 'provisional'
      worktree = $caller.worktree; branch = $caller.branch; head = $caller.head
    }
    [IO.File]::WriteAllText((Join-Path $runtime 'dispatch-log.jsonl'), ($routing | ConvertTo-Json -Compress) + "`n")
    $binding = Check-Binding "$($chain.Name): dead wrapper" 'BOUND'
    if ($binding.Record) {
      $rechecked = Assert-HeavyCallerEligibility $binding
      Assert-True ($rechecked.Record.launchId -ceq $caller.launchId) 'exact eligibility recheck retains published authority'
    }
    $deadPid = $chain.Pids[-1]
    $processes[$deadPid] = @{ Start = $instant.AddSeconds(20); Parent = 0 }
    Check-Binding "$($chain.Name): waiting scheduler wrapper" 'BOUND' | Out-Null
    $processes.Remove($deadPid)
    # Isolate the new child-start boundary check from the downstream census
    # and ancestor check, which independently refuse the same stale identity.
    $changed = $original | ConvertFrom-Json -DateKind String
    $changed.childStartIdentity = $processes[$chain.Child].Start.AddTicks(1).ToString('o')
    $script:heavyCallerAncestry = $null
    $reason = ''
    try {
      Get-HeavyCallerAncestry $GuardedPid $GuardedProcessStartUtc $instant.Ticks @(8000, 9000, $chain.Launcher, $chain.Child) @($changed) | Out-Null
    } catch { $reason = $_.Exception.Message }
    if ($reason -cne 'dispatch root PID reused') { $failures.Add("$($chain.Name): direct child-start boundary") }
    Write-Host "$(if ($reason -ceq 'dispatch root PID reused') { 'PASS' } else { 'FAIL' }) $($chain.Name): direct child-start boundary observed=$reason"
    foreach ($control in @('unbound caller', 'launcher PID reuse', 'child PID reuse', 'forged child', 'stale record', 'inactive worktree', 'malformed record')) {
      $changed = $original | ConvertFrom-Json -DateKind String
      $expected = 'lookup failed'
      switch ($control) {
        'unbound caller' { [IO.File]::Delete($callerPath) }
        'launcher PID reuse' { $changed.launcherStartIdentity = $instant.AddSeconds(2).ToString('o'); $expected = 'dispatch root PID reused' }
        'child PID reuse' { $changed.childStartIdentity = $processes[$chain.Child].Start.AddTicks(1).ToString('o'); $expected = 'PID reused|stale, terminal or unknown' }
        'forged child' { $changed.childPid = 9999; $changed.childStartIdentity = $processes[9999].Start.ToString('o') }
        'stale record' { $changed.launcherStartIdentity = $instant.ToString('o'); $expected = 'dispatch root PID reused' }
        'inactive worktree' { $changed.worktree = Join-Path $container 'absent'; $changed.lane = 'absent'; $expected = 'stale, terminal or unknown' }
        'malformed record' { $changed | Add-Member unexpected 'forged'; $expected = 'census unknown or incomplete' }
      }
      if ($control -cne 'unbound caller') { [IO.File]::WriteAllText($callerPath, ($changed | ConvertTo-Json -Compress)) }
      Check-Binding "$($chain.Name): $control" $expected | Out-Null
      [IO.File]::WriteAllText($callerPath, $original)
    }
    # Same candidate PIDs and cutoff, different launch identity: cached parent
    # edges must not retain a boundary authorized by superseded record bytes.
    Check-Binding "$($chain.Name): cache seed" 'BOUND' | Out-Null
    $changed = $original | ConvertFrom-Json -DateKind String
    $changed.launcherStartIdentity = $instant.AddSeconds(2).ToString('o')
    [IO.File]::WriteAllText($callerPath, ($changed | ConvertTo-Json -Compress))
    Check-Binding "$($chain.Name): cache record replacement" 'dispatch root PID reused' -KeepCache | Out-Null
    [IO.File]::WriteAllText($callerPath, $original)
  }
  Assert-True ($failures.Count -eq 0) "ancestry fixtures failed: $($failures -join '; ')"
  Write-Output "PASS heavy ancestry revision=$GuardRevision mutant=$Mutant; no heavy slot or command body executed"
} finally {
  $resolved = [IO.Path]::GetFullPath($root)
  Assert-True ((Split-Path -Parent $resolved) -ceq $temp -and (Split-Path -Leaf $resolved) -like 'heavy-ancestry-test-*') 'cleanup stays in this test-created temp root'
  if ([IO.Directory]::Exists($resolved)) { [IO.Directory]::Delete($resolved, $true) }
}
