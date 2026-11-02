[CmdletBinding()]
param(
  [ValidateSet('none','terminal-reasons-dropped','helper-dead-exclusion','scope-first-number','scoped-refusal-dropped','process-cache-reused',
    'reuse-by-inequality','reuse-after-start','mixed-start-source','launcher-bounded-by-updatedAt',
    'ignore-all-contradictions','drop-lane-alias','optional-label-suffix')]
  [string]$Mutant = 'none',
  [string]$ScriptPath = (Join-Path $PSScriptRoot 'board-reconcile.ps1')
)
$ErrorActionPreference = 'Stop'
[Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal'
$candidate = $ScriptPath
. (Join-Path $PSScriptRoot 'board-reconcile.test.ps1') -FunctionsOnly
. $candidate -FunctionsOnly
if ($Mutant -ne 'none') {
  $name = switch ($Mutant) {
    'scoped-refusal-dropped' { 'Get-BoardUnlinkedSpecReasons' }
    'scope-first-number' { 'Get-BoardScopeIssueNumber' }
    'optional-label-suffix' { 'Get-BoardScopeIssueNumber' }
    'mixed-start-source' { 'Get-BoardProcessSnapshot' }
    { $_ -in @('reuse-by-inequality','reuse-after-start','launcher-bounded-by-updatedAt') } { 'Test-BoardUnlinkedDeath' }
    { $_ -in @('ignore-all-contradictions','drop-lane-alias') } { 'Get-BoardUnlinkedLaunchEvidence' }
    default { 'New-BoardUnlinkedSpecScope' }
  }
  $before, $after = switch ($Mutant) {
    'terminal-reasons-dropped' { 'if ($Indexes.linkedLabels.Contains($label)) { continue }'; 'if ($Indexes.linkedLabels.Contains($label) -or $Specs[$label].value.state -ceq ''exited'') { continue }' }
    'helper-dead-exclusion' { '$dead = Test-BoardUnlinkedDeath $spec $processes'; '$dead = (Get-DispatchProcessIdentityState $spec.childPid $spec.childStartIdentity) -ceq ''dead''' }
    'scope-first-number' { '  $patterns = if ($Branch)'; '  if ($Value -match ''[0-9]+'') { return [int]$Matches[0] }; $patterns = if ($Branch)' }
    'scoped-refusal-dropped' { 'foreach ($reason in $Scope.issues[$Number]) { $reason }'; 'foreach ($reason in @()) { $reason }' }
    'process-cache-reused' { '$processes = $null'; 'if (-not $script:cachedScopeProcesses) { $script:cachedScopeProcesses = Get-BoardProcessSnapshot }; $processes = $script:cachedScopeProcesses' }
    'reuse-by-inequality' { '$created -le $updated'; '$created -eq $starts[$root]' }
    'reuse-after-start' { '$created -le $updated'; '$created -le $starts[$root]' }
    'mixed-start-source' { '$creation = $process.CreationDate'; '$creation = $process.CreationDate; if ($null -eq $creation) { $creation = (Get-Process -Id $process.ProcessId).StartTime }' }
    'launcher-bounded-by-updatedAt' { '$end = $null'; '$end = if ($root -ceq ''launcher'') { $updated } else { $null }' }
    'ignore-all-contradictions' { '$consistent = $false'; '$consistent = $true' }
    'drop-lane-alias' { '[void]$laneAliases.Add([string]$row.lane)'; '$null = $row.lane' }
    'optional-label-suffix' { '(?:[a-z]+-)+(?:g|r)[1-9][0-9]*(?:-c[1-9][0-9]*)?\z'; '[a-z]+(?:-[a-z]+)*(?:-(?:g|r)[1-9][0-9]*(?:-c[1-9][0-9]*)?)?\z' }
  }
  $source = (Get-Item "function:$name").ScriptBlock.ToString()
  Assert-Board ($source.Contains($before)) "$Mutant anchor"
  Set-Item "function:$name" ([scriptblock]::Create($source.Replace($before, $after)))
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('board-scope-test-' + [guid]::NewGuid().ToString('N'))
$failures = [Collections.Generic.List[string]]::new()
$script:censusReads = 0
function Get-CimInstance {
  param($ClassName, $Property, $ErrorAction)
  $script:censusReads++
  $script:censusProperties = @($Property)
  if ($script:censusFailure) { throw 'synthetic incomplete census' }
  return $script:processRows
}
# The shared helper deliberately reproduces its reused-PID dead result. The
# applicability reducer must never use this as terminal absence authority.
function Get-DispatchProcessIdentityState { return 'dead' }
function Reset-Census {
  $script:censusFailure = $false
  $script:processRows = @([pscustomobject]@{ ProcessId = 7; ParentProcessId = 0; CreationDate = [datetime]'2025-01-01T00:00:00Z' })
}
function Check([string]$Name, [scriptblock]$Body) {
  try { Reset-Census; & $Body; Write-Output "PASS $Name" }
  catch { $failures.Add("${Name}: $($_.Exception.Message)"); Write-Output "FAIL ${Name}: $($_.Exception.Message)" }
}
function New-ScopeFixture([string]$Name, [bool]$Resolved = $true) {
  $f = New-BoardFixture (Join-Path $root $Name) @()
  $label = if ($Resolved) { '908606-impl-g1' } else { 'synthetic-unresolved' }
  $a = Add-BoardAttempt $f 0 $label 'implementation' 'exited'
  $s = $a.spec
  $s.branch = if ($Resolved) { 'codex/908606-landing-fee-claims-g1' } else { 'codex/synthetic-unresolved' }
  $s.launcherPid = 101; $s.childPid = 102
  $s.launcherStartIdentity = '2026-01-01T00:00:00.0000000Z'
  $s.childStartIdentity = '2026-01-01T00:00:01.0000000Z'
  $s.updatedAt = [datetimeoffset]::UtcNow.ToString('o')
  $s.exitCode = 0
  $s.partialReportPath = Join-Path $f.root 'scope-alias.jsonl'
  $s.transcriptPath = Join-Path $f.root 'scope-transcript.jsonl'
  $rows = [Collections.Generic.List[object]]::new()
  $rows.Add($a.row)
  $rows.Add(@{ kind = 'dispatch'; issue = 908606; lane = 'canonical-issue'; laneRole = 'planning'; ts = '2026-01-01T00:00:00Z'; transcript = 'canonical-issue.jsonl' })
  return @{ fixture = $f; spec = $s; rows = $rows }
}
function Get-ScopeHistory($F, [bool]$Complete = $true) {
  $indexes = New-BoardHistoryIndexes $F.rows $true
  $indexes.scopeComplete = $Complete
  $specs = @{ $F.spec.label = @{ value = $F.spec; error = $null } }
  return @{ rows = @($F.rows); indexes = $indexes; specs = $specs; errors = @();
    unlinkedSpecs = (New-BoardUnlinkedSpecScope $specs $indexes) }
}
function Assert-Projection($History, [int]$Issue, [bool]$Deferred, [string]$Name) {
  $item = New-BoardItem $Issue 'In review' | ConvertTo-Json -Depth 20 | ConvertFrom-Json
  $p = Get-BoardProjection $item $History
  Assert-Board ($p.known -eq (-not $Deferred) -and $p.action -eq $(if ($Deferred) { 'deferred' } else { 'clear' })) "$Name issue=$Issue action=$($p.action) why=$($p.why)"
  if ($Deferred) { Assert-Board ($p.why -like '*unlinked watchdog*') "$Name preserves reason" }
}
function Add-Intersection($F, [string]$Kind) {
  $row = @{ kind = 'dispatch'; issue = 908605; laneRole = 'planning'; ts = '2026-01-01T00:00:00Z';
    lane = 'different-lineage'; transcript = 'different-lineage.jsonl' }
  if ($Kind -eq 'lane') { $row.lane = (Split-Path -Leaf $F.spec.worktree).ToUpperInvariant() }
  if ($Kind -eq 'lane-alias') { $F.rows[0].lane = $F.spec.label; $row.lane = $F.spec.label.ToUpperInvariant(); $row.Remove('transcript') }
  if ($Kind -eq 'partial') { $row.transcript = 'SCOPE-ALIAS.JSONL' }
  if ($Kind -eq 'transcript') { $row.transcript = 'SCOPE-TRANSCRIPT.JSONL' }
  $F.rows.Add($row)
}
try {
  foreach ($alias in @('lane','partial','transcript')) {
    Check "terminal-recent-absent/$alias intersections retained" {
      $f = New-ScopeFixture "terminal-$alias"
      Add-Intersection $f $alias
      $h = Get-ScopeHistory $f
      Assert-Projection $h 908605 $true $alias
      Assert-Projection $h 908606 $false 'death excludes additional candidate applicability'
      Assert-Projection $h 908607 $false 'unrelated qualifies'
      Assert-Board ($h.unlinkedSpecs.all.Count -eq 1 -and $h.unlinkedSpecs.active.Count -eq 0) 'reason retained, not global'
    }
  }
  foreach ($resolved in @($false,$true)) {
    foreach ($case in @('matching-live','in-window-child','in-window-launcher','missing-identity','unreadable-identity','inexact-identity','contradictory-start',
        'same-root','deep-descendant','failed-census','empty-census','duplicate-census','malformed-census','unknown-age')) {
      Check "terminal-death-refusal/$case/resolved=$resolved" {
        $f = New-ScopeFixture "$case-$resolved" $resolved
        Add-Intersection $f 'partial'
        switch ($case) {
          'matching-live' { $script:processRows += [pscustomobject]@{ ProcessId = 102; ParentProcessId = 101; CreationDate = $f.spec.childStartIdentity } }
          'in-window-child' { $script:processRows += [pscustomobject]@{ ProcessId = 102; ParentProcessId = 0; CreationDate = '2026-02-01T00:00:00Z' } }
          'in-window-launcher' { $script:processRows += [pscustomobject]@{ ProcessId = 101; ParentProcessId = 0; CreationDate = '2026-02-01T00:00:00Z' } }
          'missing-identity' { $f.spec.Remove('childStartIdentity') }
          'unreadable-identity' { $f.spec.launcherStartIdentity = 'unreadable' }
          'inexact-identity' { $f.spec.launcherStartIdentity = '2026-01-01' }
          'contradictory-start' { $f.spec.launcherStartIdentity = '2026-01-02T00:00:00Z' }
          'same-root' { $f.spec.launcherPid = 102 }
          'deep-descendant' {
            $script:processRows += @([pscustomobject]@{ ProcessId = 201; ParentProcessId = 102; CreationDate = '2026-02-01T00:00:00Z' },
              [pscustomobject]@{ ProcessId = 202; ParentProcessId = 201; CreationDate = '2026-02-01T00:00:01Z' },
              [pscustomobject]@{ ProcessId = 203; ParentProcessId = 202; CreationDate = '2026-02-01T00:00:02Z' })
          }
          'failed-census' { $script:censusFailure = $true }
          'empty-census' { $script:processRows = @() }
          'duplicate-census' { $script:processRows += $script:processRows[0] }
          'malformed-census' { $script:processRows += [pscustomobject]@{ ProcessId = 201; ParentProcessId = $null } }
          'unknown-age' { $f.spec.updatedAt = 'unknown' }
        }
        $h = Get-ScopeHistory $f
        Assert-Projection $h 908605 $true 'intersection'
        Assert-Projection $h 908606 $true 'candidate refusal'
        Assert-Projection $h 908607 (-not $resolved) 'independent applicability'
      }
    }
  }
  foreach ($case in @('live','unknown-process','unknown-age','launching')) {
    Check "unique-issue/$case remains refusal-only" {
      $f = New-ScopeFixture "unique-$case"
      $f.spec.state = 'running'; Add-Intersection $f 'lane'
      $script:processRows += [pscustomobject]@{ ProcessId = 102; ParentProcessId = 101; CreationDate = $f.spec.childStartIdentity }
      if ($case -eq 'unknown-process') { $script:censusFailure = $true }
      if ($case -eq 'unknown-age') { $f.spec.updatedAt = 'unknown' }
      if ($case -eq 'launching') { $f.spec.state = 'launching'; $f.spec.childPid = 0; $f.spec.childStartIdentity = $null }
      $h = Get-ScopeHistory $f
      Assert-Projection $h 908605 $true 'lane intersection'
      Assert-Projection $h 908606 $true 'owning issue never healthy or retired'
      Assert-Projection $h 908607 $false 'unrelated can qualify'
      Assert-Board ($f.rows[0].issue -eq 0 -and $f.rows[0].kind -eq 'dispatch') 'inference never rewrites issue-less dispatch'
    }
  }
  foreach ($case in @('multi-issue','conflict','numeric-noise','unsupported','absent-issue','reused-seat','launch-mismatch',
      'malformed-worktree','empty-worktree','malformed-alias','malformed-attempt','unsupported-schema','incomplete-scope','missing-launch',
      'running-unresolved','pending-child-unresolved')) {
    Check "unresolved/$case stays GLOBAL" {
      $f = New-ScopeFixture "unresolved-$case"
      $f.spec.state = 'running'
      $script:processRows += [pscustomobject]@{ ProcessId = 102; ParentProcessId = 101; CreationDate = $f.spec.childStartIdentity }
      $complete = $true
      switch ($case) {
        'multi-issue' { $f.spec.label = '908606-908607-impl-g1'; $f.rows[0].transcript = "$($f.spec.label).jsonl" }
        'conflict' { $f.spec.branch = 'codex/908607-landing-fee-claims-g1' }
        'numeric-noise' { $f.spec.label = 'noise908606text'; $f.rows[0].transcript = "$($f.spec.label).jsonl" }
        'unsupported' { $f.spec.label = '908606'; $f.rows[0].transcript = "$($f.spec.label).jsonl" }
        'absent-issue' { $f.rows.RemoveAt(1) }
        'reused-seat' { $row = $f.rows[0].Clone(); $row.issue = 908607; $row.transcript = 'other-launch.jsonl'; $row.branch = 'codex/908607-other-g1'; $f.rows.Add($row) }
        'launch-mismatch' { $f.rows[0].launchId = [guid]::NewGuid().ToString() }
        'malformed-worktree' { $f.spec.worktree = @('not','a','path') }
        'empty-worktree' { $f.spec.worktree = '' }
        'malformed-alias' { $f.spec.transcriptPath = @('not','a','path') }
        'malformed-attempt' { $f.spec.attemptId = @('ambiguous') }
        'unsupported-schema' { $f.spec.schemaVersion = 'watchdog-lane/v99' }
        'incomplete-scope' { $complete = $false }
        'missing-launch' { $f.rows.RemoveAt(0) }
        'running-unresolved' { $f.spec.branch = 'codex/unresolved' }
        'pending-child-unresolved' { $f.spec.state = 'launching'; $f.spec.childPid = 0; $f.spec.branch = 'codex/unresolved' }
      }
      $h = Get-ScopeHistory $f $complete
      Assert-Projection $h 908606 $true 'target'
      Assert-Projection $h 908607 $true 'global uncertainty'
    }
  }
  Check 'closed positional forms and absent canonical issue' {
    Assert-Board ((Get-BoardScopeIssueNumber '8606-impl-g1') -eq 8606) 'ruled real label shape'
    Assert-Board ((Get-BoardScopeIssueNumber 'codex/8606-landing-fee-claims-g1' -Branch) -eq 8606) 'ruled real branch shape'
    Assert-Board ((Get-BoardScopeIssueNumber 'controller-canary-8548-r1') -eq 8548) 'documented controller label position'
    Assert-Board ((Get-BoardScopeIssueNumber 'codex/canary-8548-2f5b902' -Branch) -eq 8548) 'documented controller branch position'
    foreach ($name in @('gpt-6-astra','20261004-8606-impl','8606-8607-impl-g1','controller-8606-8607-g1')) {
      Assert-Board ((Get-BoardScopeIssueNumber $name) -eq 0) "not an issue authority: $name"
    }
  }
  Check 'valid detached terminal envelope excludes only additional applicability' {
    $f = New-ScopeFixture 'detached'
    $f.spec.branch = ''; $f.spec.head = '1111111111111111111111111111111111111111'
    Add-Intersection $f 'transcript'
    $h = Get-ScopeHistory $f
    Assert-Projection $h 908605 $true 'detached intersection'
    Assert-Projection $h 908607 $false 'detached absent roots'
    $f.spec.head = 'not-a-head'
    Assert-Projection (Get-ScopeHistory $f) 908607 $true 'malformed detached identity'
  }
  foreach ($case in @('launch-id','launch-conflict','alias','schema')) {
    Check "terminal-malformed/$case absent roots cannot exclude" {
      $f = New-ScopeFixture "terminal-malformed-$case"
      switch ($case) {
        'launch-id' { $f.spec.launchId = 'not-a-launch' }
        'launch-conflict' { $f.rows[0].launchId = [guid]::NewGuid().ToString() }
        'alias' { $f.spec.partialReportPath = @('ambiguous','alias') }
        'schema' { $f.spec.schemaVersion = 'watchdog-lane/v99' }
      }
      Assert-Projection (Get-ScopeHistory $f) 908607 $true 'malformed envelope remains GLOBAL'
    }
  }
  Check 'snapshot-local process evidence and independent freshness' {
    $f = New-ScopeFixture 'freshness'
    $path = Join-Path $f.fixture.root "watchdog-lane-$($f.spec.label).json"
    [IO.File]::WriteAllText($path, ($f.spec | ConvertTo-Json -Depth 20))
    [IO.File]::WriteAllLines($f.fixture.log, @($f.rows | ForEach-Object { $_ | ConvertTo-Json -Compress }))
    $reads = $script:censusReads
    $before = Get-BoardHistory $f.fixture.log
    Assert-Projection $before 908606 $false 'first absent observation'
    foreach ($number in 908606..908610) { Assert-Projection $before $number $false 'indexed projections reuse snapshot' }
    Assert-Board ($script:censusReads -eq $reads + 1) 'one census, no per-projection probes'
    $script:processRows += [pscustomobject]@{ ProcessId = 102; ParentProcessId = 0; CreationDate = '2026-02-01T00:00:00Z' }
    $after = Get-BoardHistory $f.fixture.log
    Assert-Projection $after 908606 $true 'fresh in-window PID refuses'
    Assert-Board ($script:censusReads -eq $reads + 2) 'no process cache across reads'
    [IO.File]::AppendAllText($f.fixture.log, "{broken`n")
    $broken = Get-BoardHistory $f.fixture.log
    Assert-Board ($broken.errors.Count -eq 1 -and $broken.unlinkedSpecs.active.Count -eq 1) 'incomplete real history cannot narrow scope'
  }
  foreach ($rootName in @('launcher','child')) {
    foreach ($alias in @('lane','partial','transcript','lane-alias')) {
      Check "r2 real-reuse/$rootName/$alias" {
        $f = New-ScopeFixture "reuse-$rootName-$alias" $false
        $f.spec.updatedAt = '2026-03-01T00:00:00.0000000Z'
        $script:processRows += [pscustomobject]@{ ProcessId = $f.spec."${rootName}Pid"; ParentProcessId = 0; CreationDate = '2026-03-04T00:00:00Z' }
        Add-Intersection $f $alias
        $h = Get-ScopeHistory $f
        Assert-Board ($h.unlinkedSpecs.active.Count -eq 0 -and $h.unlinkedSpecs.all.Count -eq 1) 'real reuse leaves GLOBAL, retains reason'
        Assert-Projection $h 908605 $true 'real-reuse intersection'
        Assert-Projection $h 908607 $false 'real-reuse unrelated qualifies'
      }
    }
    foreach ($window in @('precision-trap','before-start','in-window','at-updated')) {
      Check "r2 present-root/$rootName/$window" {
        $f = New-ScopeFixture "window-$rootName-$window" $false
        $f.spec.launcherStartIdentity = '2026-01-01T00:00:00.7961109Z'
        $f.spec.childStartIdentity = '2026-01-01T00:00:01.7961109Z'
        $f.spec.updatedAt = '2026-03-01T00:00:00.0000000Z'
        $created = switch ($window) {
          'precision-trap' { $f.spec."${rootName}StartIdentity" -replace '9Z$', '0Z' }
          'before-start' { '2025-12-31T00:00:00Z' }
          'in-window' { '2026-02-01T00:00:00Z' }
          'at-updated' { $f.spec.updatedAt }
        }
        $script:processRows += [pscustomobject]@{ ProcessId = $f.spec."${rootName}Pid"; ParentProcessId = 0; CreationDate = $created }
        Assert-Projection (Get-ScopeHistory $f) 908607 $true 'possibly original owner refuses'
      }
    }
  }
  foreach ($case in @('missing-start','non-roundtrip-start','non-string-start','non-roundtrip-updated','future-updated','reversed-starts','start-after-updated',
      'missing-creation','unreadable-creation','duplicate','failed','empty','string-pid','negative-pid','overflow-pid',
      'string-ppid','negative-ppid','overflow-ppid')) {
    Check "r2 incomplete-identity/$case" {
      $f = New-ScopeFixture "identity-$case" $false
      switch ($case) {
        'missing-start' { $f.spec.Remove('launcherStartIdentity') }
        'non-roundtrip-start' { $f.spec.childStartIdentity = '2026-01-01' }
        'non-string-start' { $f.spec.childStartIdentity = [datetime]'2026-01-01' }
        'non-roundtrip-updated' { $f.spec.updatedAt = '2026-03-01' }
        'future-updated' { $f.spec.updatedAt = [datetimeoffset]::UtcNow.AddDays(1).ToString('o') }
        'reversed-starts' { $f.spec.launcherStartIdentity = '2026-01-01T00:00:02.0000000Z' }
        'start-after-updated' { $f.spec.childStartIdentity = [datetime]::UtcNow.AddDays(1).ToString('o') }
        'missing-creation' { $script:processRows[0].CreationDate = $null }
        'unreadable-creation' { $script:processRows[0].CreationDate = 'unreadable' }
        'duplicate' { $script:processRows += $script:processRows[0] }
        'failed' { $script:censusFailure = $true }
        'empty' { $script:processRows = @() }
        'string-pid' { $script:processRows[0].ProcessId = '7' }
        'negative-pid' { $script:processRows[0].ProcessId = -1 }
        'overflow-pid' { $script:processRows[0].ProcessId = [long]2147483648 }
        'string-ppid' { $script:processRows[0].ParentProcessId = '0' }
        'negative-ppid' { $script:processRows[0].ParentProcessId = -1 }
        'overflow-ppid' { $script:processRows[0].ParentProcessId = [long]2147483648 }
      }
      $script:fallbackReads = 0
      function Get-Process { $script:fallbackReads++; return @{ StartTime = [datetime]'2025-01-01T00:00:00Z' } }
      Assert-Projection (Get-ScopeHistory $f) 908607 $true 'incomplete identity refuses'
      Assert-Board ($script:fallbackReads -eq 0) 'no mixed Get-Process source'
      if ($case -in @('missing-creation','unreadable-creation','duplicate','failed','empty')) {
        $f.spec.label = '908606-impl-g1'; $f.spec.branch = 'codex/908606-landing-fee-claims-g1'
        $f.rows[0].transcript = "$($f.spec.label).jsonl"
        $h = Get-ScopeHistory $f
        Assert-Projection $h 908606 $true 'unhealthy census retains scoped refusal'
        Assert-Projection $h 908607 $false 'scope remains independently usable'
      }
    }
  }
  Check 'r2 census single native read, creation column and UTC conversion' {
    $script:processRows[0].CreationDate = '2026-01-01T01:00:00+01:00'
    $reads = $script:censusReads
    $snapshot = Get-BoardProcessSnapshot
    Assert-Board ($snapshot.healthy -and $script:censusReads -eq $reads + 1) 'one healthy enumeration'
    Assert-Board ('CreationDate' -in $script:censusProperties) 'native census requests CreationDate'
    Assert-Board ($snapshot.ids[7].Offset -eq [timespan]::Zero -and $snapshot.ids[7] -eq [datetimeoffset]'2026-01-01T00:00:00Z') 'snapshot UTC creation'
  }
  foreach ($case in @('child-inside','child-after','child-v1-after','child-v3-after','child-v4-after','child-null-exit','child-string-exit',
      'child-fraction-exit','child-running-after','launcher-absent-after','launcher-reused-after','launcher-reused-inside',
      'launcher-reused-at-end','child-reused-after','child-reused-between','child-reused-v4-after','child-reused-v4-inside','child-reused-null-inside',
      'before-start-margin','at-start-margin','inside-start-margin','child-at-updated')) {
    Check "r2 descendant/$case" {
      $f = New-ScopeFixture "descendant-$case" $false
      $f.spec.updatedAt = '2026-03-01T00:00:00.0000000Z'
      $parent = if ($case -like 'launcher-*') { 101 } else { 102 }
      $created = '2026-03-02T00:00:00Z'
      switch ($case) {
        'child-inside' { $created = '2026-02-01T00:00:00Z' }
        'child-v1-after' { $f.spec.schemaVersion = 'watchdog-lane/v1' }
        'child-v3-after' { $f.spec.schemaVersion = 'watchdog-lane/v3' }
        'child-v4-after' { $f.spec.schemaVersion = 'watchdog-lane/v4' }
        'child-null-exit' { $f.spec.exitCode = $null }
        'child-string-exit' { $f.spec.exitCode = '0' }
        'child-fraction-exit' { $f.spec.exitCode = 0.5 }
        'child-running-after' { $f.spec.state = 'running' }
        'launcher-reused-after' { $created = '2026-03-05T00:00:00Z' }
        'launcher-reused-at-end' { $created = '2026-03-04T00:00:00Z' }
        'child-reused-after' { $created = '2026-03-05T00:00:00Z' }
        'child-reused-v4-after' { $f.spec.schemaVersion = 'watchdog-lane/v4'; $created = '2026-03-05T00:00:00Z' }
        'child-reused-v4-inside' { $f.spec.schemaVersion = 'watchdog-lane/v4' }
        'child-reused-null-inside' { $f.spec.exitCode = $null }
        'before-start-margin' { $created = '2026-01-01T00:00:00.9989999Z' }
        'at-start-margin' { $created = '2026-01-01T00:00:00.9990000Z' }
        'inside-start-margin' { $created = '2026-01-01T00:00:00.9995000Z' }
        'child-at-updated' { $created = $f.spec.updatedAt }
      }
      if ($case -like '*-reused-*') {
        $script:processRows += [pscustomobject]@{ ProcessId = $parent; ParentProcessId = 0; CreationDate = '2026-03-04T00:00:00Z' }
      }
      $script:processRows += [pscustomobject]@{ ProcessId = 201; ParentProcessId = $parent; CreationDate = $created }
      $ignored = $case -in @('child-after','child-v1-after','child-v3-after','launcher-reused-after',
        'child-reused-after','child-reused-between','child-reused-v4-after','before-start-margin')
      Assert-Projection (Get-ScopeHistory $f) 908607 (-not $ignored) 'lifetime-bound descendant proof'
    }
  }
  Check 'r2 lane-only contradiction keeps every alias but is not scope evidence' {
    $f = New-ScopeFixture 'lane-only'
    $f.rows[0].lane = $f.spec.label
    $f.rows.Add(@{ kind = 'dispatch'; issue = 908605; lane = $f.spec.label.ToUpperInvariant(); laneRole = 'planning'; ts = '2026-01-01T00:00:00Z' })
    Add-Intersection $f 'lane'; Add-Intersection $f 'partial'; Add-Intersection $f 'transcript'
    $h = Get-ScopeHistory $f
    Assert-Board ($h.unlinkedSpecs.active.Count -eq 0) 'lane-only disagreement does not bar death'
    Assert-Projection $h 908605 $true 'all original intersections retained'
    Assert-Projection $h 908607 $false 'lane-only unrelated qualifies'
    # Isolate a projection with only the new alias, no transcript or original lane.
    $f.rows.Add(@{ kind = 'dispatch'; issue = 908608; lane = $f.spec.label.ToUpperInvariant(); laneRole = 'planning'; ts = '2026-01-01T00:00:00Z' })
    Assert-Projection (Get-ScopeHistory $f) 908608 $true 'new lane alias without transcript retains refusal'
    $f.spec.state = 'running'
    Assert-Projection (Get-ScopeHistory $f) 908607 $true 'lane disagreement cannot narrow live scope'
  }
  foreach ($field in @('launchId','attemptId','branch','laneRole')) {
    Check "r2 contradiction/$field" {
      $f = New-ScopeFixture "contradiction-$field" $false
      $other = $f.rows[0].Clone(); $other[$field] = 'synthetic-other-launch'
      $f.rows.Add($other)
      Assert-Projection (Get-ScopeHistory $f) 908607 $true 'conflicting launch refuses death'
    }
  }
  foreach ($case in @('positive','claude','branch-no-suffix','no-issue','version-name','digit-slug','multi-issue','mismatch','absent-issue','suffixless-label')) {
    Check "r2 controller-branch/$case" {
      $f = New-ScopeFixture "controller-$case"
      # Synthetic projection of the exact ruled controller name shapes.
      $f.spec.label = 'controller-8605-board-errors-g1-c2'
      $f.spec.branch = 'codex/controller-8605-board-errors-g1'
      $f.rows[1].issue = 8605
      $f.spec.state = 'running'
      switch ($case) {
        'claude' { $f.spec.branch = 'claude/controller-8605-board-errors-r1-c2' }
        'branch-no-suffix' { $f.spec.branch = 'codex/controller-8605-board-errors' }
        'no-issue' { $f.spec.branch = 'codex/controller-capacity-balance-g1' }
        'version-name' { $f.spec.branch = 'codex/controller-v287-routing-data' }
        'digit-slug' { $f.spec.label = 'controller-7963-recovery-g3'; $f.spec.branch = 'codex/controller-7963-v272-fable-recovery-g3'; $f.rows[1].issue = 7963 }
        'multi-issue' { $f.spec.branch = 'codex/controller-8605-8606-x' }
        'mismatch' { $f.spec.branch = 'codex/controller-8606-board-errors-g1' }
        'absent-issue' { $f.rows.RemoveAt(1) }
        'suffixless-label' { $f.spec.label = 'controller-8605-board-errors' }
      }
      $f.rows[0].transcript = "$($f.spec.label).jsonl"
      $h = Get-ScopeHistory $f
      Assert-Projection $h 908607 ($case -notin @('positive','claude','branch-no-suffix')) 'closed branch grammar'
      Assert-Projection $h 8605 $true 'owning issue stays refused'
    }
  }
  if ($failures.Count) { throw "$($failures.Count) c2/r2 controls failed ($Mutant)" }
  Write-Output "PASS board-unlinked-scope mutant=$Mutant"
} finally {
  $resolvedRoot = [IO.Path]::GetFullPath($root)
  if ((Split-Path -Parent $resolvedRoot) -ne [IO.Path]::GetTempPath().TrimEnd('\','/') -or
      (Split-Path -Leaf $resolvedRoot) -notlike 'board-scope-test-*') { throw 'unsafe scope fixture cleanup' }
  if (Test-Path -LiteralPath $resolvedRoot) { Remove-Item -LiteralPath $resolvedRoot -Recurse -Force }
}
