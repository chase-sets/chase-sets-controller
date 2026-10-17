[CmdletBinding()]
param(
  [ValidateSet('none','terminal-reasons-dropped','helper-dead-exclusion','scope-first-number','scoped-refusal-dropped','process-cache-reused',
    'reuse-by-inequality','reuse-after-start','mixed-start-source','launcher-bounded-by-updatedAt',
    'ignore-all-contradictions','drop-lane-alias','optional-label-suffix',
    'attribution-skips-decision-kinds','attribution-admits-kindless','attribution-drops-malformed-issue',
    'attribution-marks-dead','attribution-links-label','attribution-ignores-conflict','attribution-hides-prelaunch-conflict',
    'attribution-wildcards-missing-lane','attribution-ignores-branch-mismatch','attribution-bypasses-launch-evidence',
    'attribution-row-width-cap','attribution-row-overflow-throws')]
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
    { $_ -in @('attribution-skips-decision-kinds','attribution-admits-kindless','attribution-drops-malformed-issue') } { 'Get-BoardHistory' }
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
    'attribution-skips-decision-kinds' { '$row.kind -is [string] -and $null -ne $row.issue'; '$row.kind -in @(''dispatch'',''lane-complete'',''repair-complete'',''review-complete'',''lane-blocked'',''landed'') -and $null -ne $row.issue' }
    'attribution-admits-kindless' { '$row.kind -is [string] -and $null -ne $row.issue'; '$null -ne $row.issue' }
    'attribution-drops-malformed-issue' { '$null -ne $row.issue -and $row.transcript'; '($row.issue -is [int] -or $row.issue -is [long]) -and $row.issue -gt 0 -and $row.transcript' }
    'attribution-marks-dead' { '$scope.issues[$attributed].Add($reason)'; 'continue' }
    'attribution-links-label' { '$scope.issues[$attributed].Add($reason)'; '$scope.issues[$attributed].Add($reason); [void]$Indexes.linkedLabels.Add($label)' }
    'attribution-ignores-conflict' { 'if ($null -ne $record.$field -and'; 'if ($false -and' }
    'attribution-hides-prelaunch-conflict' { 'foreach ($record in $records) {'; 'foreach ($record in $records) { $skip = [datetimeoffset]::MinValue; if ([datetimeoffset]::TryParse([string]$record.ts, [ref]$skip) -and $skip -lt $start.AddMilliseconds(-1)) { continue }' }
    'attribution-wildcards-missing-lane' { 'if ($record.lane -isnot [string] -or $record.lane -cnotin'; 'if ($null -ne $record.lane -and $record.lane -cnotin' }
    'attribution-ignores-branch-mismatch' { 'if ($null -ne $record.branch -and'; 'if ($false -and' }
    'attribution-bypasses-launch-evidence' { '$launch.scopeConsistent -and @($launch.issues | Where-Object { $_ -ne $candidate }).Count -eq 0'; '$true' }
    'attribution-row-width-cap' { '''\A[0-9]+\z'''; '''\A[0-9]{1,9}\z''' }
    'attribution-row-overflow-throws' { '[long]::TryParse($Value, [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) { $parsed }'; '$true) { [long]$Value }' }
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
# r4 record attribution (#9632): the exact-byte #8349 decision-lane rows
# 22605/22608 and its spec, replayed through the real history pass.
$script:r4Lines = @(Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/board-8349-decision-lane.jsonl'))
$script:r4Hashes = @('a9c58415d1b66a84bc41d4a186954805a3a48ca83e6001d85726f04748e14dbf',
  '29858cb60db0ec785a5a9d6ec0a0e3489d9934cbc3b7816bc072f4554cee7a01', '2e98515ab68d8856ef649264ed75123c6290e1b9f4af65e37551cabbae193fa8')
function Add-R4Canonical($F, [int]$Issue) {
  $F.ledger.Add(@{ ts = '2026-09-28T00:00:00Z'; kind = 'dispatch'; issue = $Issue; lane = "canonical-$Issue"; laneRole = 'planning'; transcript = "canonical-$Issue.jsonl" })
}
function New-R4Fixture([string]$Name) {
  $f = @{ fixture = (New-BoardFixture (Join-Path $root "r4-$Name") @()); ledger = [Collections.Generic.List[object]]::new()
    spec = $script:r4Lines[2]; label = 'opus-8349-enrollment-pin-decision-r1' }
  Add-R4Canonical $f 8349
  $f.ledger.Add($script:r4Lines[0]); $f.ledger.Add($script:r4Lines[1])
  # The absent launcher's two 2026-10-08 possible descendants refuse death proof.
  $script:processRows += @([pscustomobject]@{ ProcessId = 78608; ParentProcessId = 65676; CreationDate = '2026-10-08T16:20:00Z' },
    [pscustomobject]@{ ProcessId = 73704; ParentProcessId = 65676; CreationDate = '2026-10-08T16:20:01Z' })
  return $f
}
function Get-R4Entry($F, [int]$Index) {
  # Exact-byte lines stay raw until a case edits them.
  if ($F.ledger[$Index] -is [string]) { $F.ledger[$Index] = $F.ledger[$Index] | ConvertFrom-Json -AsHashtable -DateKind String }
  return $F.ledger[$Index]
}
function Get-R4Spec($F) {
  if ($F.spec -is [string]) { $F.spec = $F.spec | ConvertFrom-Json -AsHashtable -DateKind String }
  return $F.spec
}
function Set-R4Label($F, [string]$Label) {
  $F.label = $Label; (Get-R4Spec $F).label = $Label
  foreach ($index in 1, 2) { (Get-R4Entry $F $index).transcript = "$Label.jsonl" }
}
function Get-R4History($F) {
  $lines = foreach ($entry in $F.ledger) { if ($entry -is [string]) { $entry } else { $entry | ConvertTo-Json -Compress -Depth 10 } }
  [IO.File]::WriteAllText($F.fixture.log, (@($lines) -join "`n") + "`n")
  $spec = if ($F.spec -is [string]) { $F.spec } else { $F.spec | ConvertTo-Json -Compress -Depth 10 }
  [IO.File]::WriteAllText((Join-Path $F.fixture.root "watchdog-lane-$($F.label).json"), $spec)
  return Get-BoardHistory $F.fixture.log
}
function Assert-R4($F, $History, [int]$Issue, [string]$Name) {
  # $Issue names the attributed owner; 0 means the reason must stay GLOBAL.
  $reason = "unlinked watchdog $($F.label): owning issue unknown"
  $scope = $History.unlinkedSpecs
  Assert-Board ($scope.all -contains $reason) "$Name reason retained"
  $scoped = @($scope.issues.Keys | Where-Object { $scope.issues[$_] -contains $reason })
  if ($Issue) {
    Assert-Board ($scope.active -notcontains $reason -and "$scoped" -eq "$Issue") "$Name attributed issue-local only: scoped=$scoped active=$($scope.active -join '|')"
    Assert-Projection $History 908607 $false "$Name unrelated projection"
    Assert-Projection $History $Issue $true "$Name owning issue"
  } else {
    Assert-Board ($scope.active -contains $reason -and $scoped.Count -eq 0) "$Name stays GLOBAL: scoped=$scoped"
    Assert-Projection $History 908607 $true "$Name unrelated projection"
  }
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
  Check 'r4 attribution/exact-byte fixture' {
    $sha = [Security.Cryptography.SHA256]::Create()
    Assert-Board ($script:r4Lines.Count -eq 3) 'rows 22605/22608 plus the spec'
    foreach ($index in 0..2) {
      $hash = ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($script:r4Lines[$index])) | ForEach-Object { $_.ToString('x2') }) -join ''
      Assert-Board ($hash -ceq $script:r4Hashes[$index]) "fixture line $($index + 1) exact bytes"
    }
  }
  Check 'r4 attribution/index any string kind once per fresh history' {
    $f = New-R4Fixture 'index'
    $label = $f.label
    $f.ledger.Add(@{ ts = '2026-09-29T06:30:00Z'; issue = 9349; lane = $label; laneRole = 'review'; row = 8; transcript = "$label.jsonl" })
    $f.ledger.Add(@{ ts = '2026-09-29T06:30:00Z'; kind = 'note'; issue = $null; transcript = "$label.jsonl" })
    $f.ledger.Add(@{ ts = '2026-09-29T06:30:00Z'; kind = 'note'; issue = 9349; transcript = @("$label.jsonl") })
    $f.ledger.Add(@{ ts = '2026-09-29T06:30:00Z'; kind = 'decision-filed'; issue = '9999991'; transcript = 'synthetic-malformed.jsonl' })
    $h = Get-R4History $f
    $index = $h.indexes.attribution
    Assert-Board ($null -ne $index -and $h.errors.Count -eq 0) 'attribution index built in the history pass'
    $kinds = @($index[$label] | ForEach-Object { $_.kind }) -join ','
    Assert-Board ($kinds -ceq 'decision-filed,decision-resolved') "decision kinds indexed, kind-less skipped: $kinds"
    Assert-Board ($index.ContainsKey('synthetic-malformed') -and $index['synthetic-malformed'].Count -eq 1 -and
      $index['synthetic-malformed'][0].issue -ceq '9999991') 'malformed issue claim indexed for typing'
    Assert-Board ($index.ContainsKey('canonical-8349') -and $index['canonical-8349'].Count -eq 1) 'lifecycle rows attribute too'
    Assert-Board ($index.Count -eq 3 -and -not $index.ContainsKey($label.ToUpperInvariant())) 'exact stems; null issue and non-string transcript skipped'
    Assert-Board ($h.rows.Count -eq 1 -and $h.count -eq 7) 'lifecycle row set unchanged'
    Assert-Board ((@($h.indexes.canonicalIssues) -join ',') -eq '8349' -and (@($h.indexes.linkedLabels) -join ',') -ceq 'canonical-8349') 'canonical issues and linkage unchanged'
    $fresh = Get-R4History $f
    Assert-Board (-not [object]::ReferenceEquals($fresh.indexes.attribution, $index) -and @($fresh.indexes.attribution[$label]).Count -eq 2) 'fresh index, each row once'
  }
  foreach ($census in @('edges','unhealthy')) {
    Check "r4 positive/exact-8349/census=$census" {
      $f = New-R4Fixture "exact-$census"
      $reason = "unlinked watchdog $($f.label): owning issue unknown"
      $f.ledger.Add(@{ ts = '2026-10-01T00:00:00Z'; kind = 'dispatch'; issue = 908605; lane = '20260926-DECISION-SEAT-A'; laneRole = 'planning'; transcript = 'different-lineage.jsonl' })
      $f.ledger.Add(@{ ts = '2026-10-01T00:00:00Z'; kind = 'dispatch'; issue = 908604; lane = 'different-lineage'; laneRole = 'planning'; transcript = 'OPUS-8349-ENROLLMENT-PIN-DECISION-R1.jsonl' })
      if ($census -eq 'unhealthy') { $script:censusFailure = $true }
      $h = Get-R4History $f
      Assert-Board ($f.ledger[1] -is [string] -and $f.ledger[2] -is [string] -and $f.spec -is [string] -and $h.errors.Count -eq 0) 'exact bytes replayed'
      Assert-R4 $f $h 8349 'exact #8349'
      Assert-Board ($h.unlinkedSpecs.lanes['20260926-decision-seat-a'] -contains $reason -and $h.unlinkedSpecs.transcripts[$f.label] -contains $reason) 'lane and transcript intersections stay'
      Assert-Projection $h 908605 $true 'lane intersection'
      Assert-Projection $h 908604 $true 'transcript intersection'
      $owner = Get-BoardProjection (New-BoardItem 8349 'In review' | ConvertTo-Json -Depth 20 | ConvertFrom-Json) $h
      Assert-Board ($owner.why -like "*$reason*") "#8349 retains the reason: $($owner.why)"
      Assert-Board (-not $h.indexes.linkedLabels.Contains($f.label) -and $h.indexes.linkedLabels.Count -eq 3) 'linkedLabels unchanged'
      Assert-Board (-not (Test-BoardUnlinkedDeath $h.specs[$f.label].value (Get-BoardProcessSnapshot))) 'still not proven dead'
    }
  }
  foreach ($case in @('causal-margin','row-native-integer','lane-worktree-leaf','lane-attempt-id','supplied-identity-agrees','branch-agrees','grammar-label-agrees')) {
    Check "r4 positive/$case" {
      $f = New-R4Fixture "positive-$case"
      $spec = Get-R4Spec $f; $first = Get-R4Entry $f 1; $last = Get-R4Entry $f 2
      switch ($case) {
        'causal-margin' { $first.ts = '2026-09-29T06:10:00.000Z'; $last.ts = '2026-09-29T06:17:28.8358214Z' }
        'row-native-integer' { $first.row = 8; $last.row = 8 }
        'lane-worktree-leaf' { $first.lane = $last.lane = '20260926-decision-seat-a' }
        'lane-attempt-id' { $spec.attemptId = 'opus-8349-attempt-a'; foreach ($r in $first, $last) { $r.lane = $r.attemptId = $spec.attemptId } }
        'supplied-identity-agrees' { foreach ($r in $first, $last) { $r.attemptId = $spec.attemptId; $r.launchId = $spec.launchId; $r.branch = '' } }
        'branch-agrees' { $spec.branch = 'codex/8349-enrollment-pin-g1'; foreach ($r in $first, $last) { $r.branch = $spec.branch } }
        'grammar-label-agrees' { Set-R4Label $f '8349-synth-decision-r1' }
      }
      Assert-R4 $f (Get-R4History $f) 8349 $case
    }
  }
  # A row claim agrees by its Int64 value; digit-spelling width never decides (gov-r1 F1).
  $widths = [ordered]@{ 'integer' = '8'; 'digits-9' = '"000000008"'; 'digits-10' = '"0000000008"'; 'digits-28' = '"0000000000000000000000000008"' }
  foreach ($case in $widths.Keys) {
    Check "r4 positive/row-width/$case" {
      $f = New-R4Fixture "width-$case"
      foreach ($index in 1, 2) { $f.ledger[$index] = $script:r4Lines[$index - 1].Replace('"row":"8"', "`"row`":$($widths[$case])") }
      Assert-Board ($f.ledger[2] -cne $script:r4Lines[1]) 'row spelling applied'
      Assert-R4 $f (Get-R4History $f) 8349 "row width $case"
    }
  }
  foreach ($case in @('spec-digits-10','overflow-everywhere')) {
    Check "r4 $(if ($case -eq 'spec-digits-10') { 'positive' } else { 'negative' })/row-width/$case" {
      $f = New-R4Fixture "width-$case"
      $row = if ($case -eq 'spec-digits-10') { '"0000000008"' } else { '"9223372036854775808"' }
      $f.spec = $script:r4Lines[2].Replace('"row":8,', "`"row`":$row,")
      if ($case -eq 'overflow-everywhere') {
        # Identical overflowing spellings still never agree: no value, no claim.
        foreach ($index in 1, 2) { $f.ledger[$index] = $script:r4Lines[$index - 1].Replace('"row":"8"', "`"row`":$row") }
      }
      Assert-Board ($f.spec -cne $script:r4Lines[2]) 'spec row spelling applied'
      Assert-R4 $f (Get-R4History $f) $(if ($case -eq 'spec-digits-10') { 8349 } else { 0 }) "row width $case"
    }
  }
  # The same boundary on in-memory records, including native Int32 and BigInteger values.
  $memory = @(@('int32', [int]8, 8349), @('int64', [long]8, 8349), @('digits-9', '000000008', 8349), @('digits-10', '0000000008', 8349),
    @('digits-28', '0000000000000000000000000008', 8349), @('int64-max', '9223372036854775807', 0), @('overflow', '9223372036854775808', 0),
    @('overflow-padded', '0000000009223372036854775808', 0), @('overflow-native', [bigint]::Parse('9223372036854775808'), 0),
    @('leading-space', ' 8', 0), @('negative', '-8', 0), @('double', [double]8, 0), @('decimal', [decimal]8, 0), @('bool', $true, 0), @('array', @(8), 0))
  foreach ($rowCase in $memory) {
    $rowName, $rowValue, $rowOwner = $rowCase
    Check "r4 $(if ($rowOwner) { 'positive' } else { 'negative' })/row-width/in-memory/$rowName" {
      $f = New-R4Fixture "width-memory-$rowName"
      $h = Get-R4History $f
      $records = @($h.indexes.attribution[$f.label])
      Assert-Board ($records.Count -eq 2) "two same-label records: $($records.Count)"
      foreach ($record in $records) { $record.row = $rowValue }
      $h.unlinkedSpecs = New-BoardUnlinkedSpecScope $h.specs $h.indexes
      Assert-R4 $f $h $rowOwner "in-memory row $rowName"
    }
  }
  foreach ($case in @('two-issues','prelaunch-only','prelaunch-role-conflict','prelaunch-issue-conflict','missing-lane','missing-laneRole',
      'missing-row','missing-ts','branch-vs-empty','branch-mismatch','grammar-branch','grammar-label','non-canonical','non-roundtrip-start',
      'invalid-envelope','kindless','launch-lane-alias')) {
    Check "r4 negative/$case" {
      $f = New-R4Fixture "negative-$case"
      $spec = Get-R4Spec $f; $first = Get-R4Entry $f 1; $last = Get-R4Entry $f 2
      switch ($case) {
        'two-issues' { $other = $last.Clone(); $other.issue = 9349; $f.ledger.Add($other); Add-R4Canonical $f 9349 }
        'prelaunch-only' { $first.ts = $last.ts = '2026-09-29T06:17:28.8358213Z' }
        'prelaunch-role-conflict' { $first.ts = '2026-09-29T06:10:00.000Z'; $first.laneRole = 'implementation' }
        'prelaunch-issue-conflict' { $first.ts = '2026-09-29T06:10:00.000Z'; $first.issue = 9349; Add-R4Canonical $f 9349 }
        { $_ -like 'missing-*' } { $last.Remove($case.Substring('missing-'.Length)) }
        'branch-vs-empty' { $last.branch = 'codex/8349-enrollment-pin-g1' }
        'branch-mismatch' { $spec.branch = 'codex/8349-enrollment-pin-g1'; $last.branch = 'codex/8349-other-pin-g1' }
        'grammar-branch' { $spec.branch = 'codex/9999993-synth-grammar' }
        'grammar-label' { Set-R4Label $f '9999994-synth-decision-r1' }
        'non-canonical' { $f.ledger.RemoveAt(0) }
        'non-roundtrip-start' { $spec.launcherStartIdentity = '2026-09-29T06:17:28.836Z' }
        'invalid-envelope' { $spec.launchId = 'not-a-launch' }
        'kindless' { $first.Remove('kind'); $last.Remove('kind') }
        'launch-lane-alias' {
          $f.ledger.Add(@{ ts = '2026-09-29T06:18:00.000Z'; kind = 'dispatch'; lane = $f.label; laneRole = 'review'; attemptId = $f.label; transcript = "$($f.label).jsonl" })
        }
      }
      $h = Get-R4History $f
      Assert-R4 $f $h 0 $case
      if ($case -eq 'launch-lane-alias') {
        Assert-Board ($h.unlinkedSpecs.lanes[$f.label] -contains "unlinked watchdog $($f.label): owning issue unknown") 'alias kept as intersection only'
      }
    }
  }
  foreach ($field in @('harness','model','effort','placement','attemptId','launchId','laneRole','row','lane')) {
    Check "r4 negative/conflict/$field" {
      $f = New-R4Fixture "conflict-$field"
      $last = Get-R4Entry $f 2
      $last[$field] = switch ($field) {
        'harness' { 'codex' } 'model' { 'gpt-6-astra' } 'effort' { 'medium' } 'placement' { 'override-Todd' } 'attemptId' { 'other-attempt' }
        'launchId' { [guid]::NewGuid().ToString() } 'laneRole' { 'implementation' } 'row' { '9' } 'lane' { 'arbitrary-alias' }
      }
      Assert-R4 $f (Get-R4History $f) 0 "$field conflict"
    }
  }
  # Typed claims edit the exact JSON text; malformed issues join the real rows, never replace them.
  $typed = [ordered]@{
    'issue-string-other' = @('"issue":8349', '"issue":"9999991"'); 'issue-string-same' = @('"issue":8349', '"issue":"8349"')
    'issue-zero' = @('"issue":8349', '"issue":0'); 'issue-array' = @('"issue":8349', '"issue":[8349]')
    'issue-fraction' = @('"issue":8349', '"issue":8349.5'); 'issue-integral-float' = @('"issue":8349', '"issue":8349.0')
    'issue-bool' = @('"issue":8349', '"issue":true')
    'row-padded' = @('"row":"8"', '"row":"8 "'); 'row-signed' = @('"row":"8"', '"row":"+8"'); 'row-decimal-string' = @('"row":"8"', '"row":"8.0"')
    'row-float' = @('"row":"8"', '"row":8.0'); 'row-bool' = @('"row":"8"', '"row":true'); 'row-empty' = @('"row":"8"', '"row":""')
    'row-array' = @('"row":"8"', '"row":[8]'); 'row-leading-space' = @('"row":"8"', '"row":" 8"')
    'row-overflow' = @('"row":"8"', '"row":"9223372036854775808"'); 'row-overflow-native' = @('"row":"8"', '"row":9223372036854775808')
    'row-non-ascii-digit' = @('"row":"8"', '"row":"\u0668"')
    'laneRole-array' = @('"laneRole":"review"', '"laneRole":["review"]'); 'laneRole-number' = @('"laneRole":"review"', '"laneRole":1')
    'laneRole-case' = @('"laneRole":"review"', '"laneRole":"Review"')
    'ts-text' = @('"ts":"2026-09-29T06:29:48.879Z"', '"ts":"not-a-time"'); 'ts-number' = @('"ts":"2026-09-29T06:29:48.879Z"', '"ts":12345')
    'ts-date-only' = @('"ts":"2026-09-29T06:29:48.879Z"', '"ts":"2026-09-29"'); 'ts-no-offset' = @('"ts":"2026-09-29T06:29:48.879Z"', '"ts":"2026-09-29T06:29:48.879"')
  }
  foreach ($case in $typed.Keys) {
    Check "r4 negative/typed/$case" {
      $f = New-R4Fixture "typed-$case"
      $line = $script:r4Lines[1].Replace($typed[$case][0], $typed[$case][1])
      Assert-Board ($line -cne $script:r4Lines[1]) 'typed claim applied'
      if ($case -like 'issue-*') { $f.ledger.Add($line) } else { $f.ledger[2] = $line }
      Assert-R4 $f (Get-R4History $f) 0 "typed $case"
    }
  }
  foreach ($split in @('issue','branch')) {
    Check "r4 negative/reused-seat-$split/record" {
      $f = New-R4Fixture "seat-record-$split"
      $row = @{ ts = '2026-10-01T00:00:00Z'; kind = 'dispatch'; issue = 9999991; lane = '20260926-decision-seat-a'; laneRole = 'review'; transcript = 'other-launch.jsonl'; attemptId = 'other-launch' }
      if ($split -eq 'branch') { $row.issue = 8349; $row.branch = 'codex/9999991-other-g1' }
      $f.ledger.Add($row)
      Assert-R4 $f (Get-R4History $f) 0 "reused seat $split"
    }
    Check "r4 negative/reused-seat-$split/grammar" {
      $f = New-ScopeFixture "r4-seat-grammar-$split"
      $f.spec.state = 'running'
      $script:processRows += [pscustomobject]@{ ProcessId = 102; ParentProcessId = 101; CreationDate = $f.spec.childStartIdentity }
      Assert-Projection (Get-ScopeHistory $f) 908607 $false 'grammar route resolves before the reused seat'
      $row = $f.rows[0].Clone(); $row.transcript = 'other-launch.jsonl'
      if ($split -eq 'issue') { $row.issue = 908607 } else { $row.issue = 908606; $row.branch = 'codex/908607-other-g1' }
      $f.rows.Add($row)
      Assert-Projection (Get-ScopeHistory $f) 908607 $true "reused seat $split"
    }
  }
  foreach ($seat in @($false,$true)) {
    Check "r4 $(if ($seat) { 'negative' } else { 'positive' })/live-shape-fable-7031/same-seat=$seat" {
      # Synthetic projection of the live shape: planning lane on the shared main seat.
      $f = New-R4Fixture "fable-7031-$seat"
      Set-R4Label $f 'fable-7031-canary-sequencing-r1'
      $spec = Get-R4Spec $f
      $spec.attemptId = $f.label; $spec.laneRole = 'planning'; $spec.branch = 'main'; $spec.model = 'claude-fable-5-1'; $spec.placement = 'override-Todd'
      $spec.worktree = 'D:\Users\ToddS\Source\Repos\chase-sets\main'
      foreach ($index in 1, 2) {
        $r = Get-R4Entry $f $index
        $r.issue = 7031; $r.lane = $f.label; $r.laneRole = 'planning'; $r.model = 'claude-fable-5-1'; $r.placement = 'override-Todd'
      }
      Add-R4Canonical $f 7031
      if ($seat) { $f.ledger.Add(@{ ts = '2026-10-01T00:00:00Z'; kind = 'dispatch'; issue = 5981; lane = 'main'; laneRole = 'implementation'; transcript = 'lane-5981-impl.jsonl' }) }
      Assert-R4 $f (Get-R4History $f) $(if ($seat) { 0 } else { 7031 }) 'fable-7031 shape'
    }
  }
  Check 'r4 negative/incomplete-history' {
    $f = New-R4Fixture 'incomplete'
    $h = Get-R4History $f
    Assert-R4 $f $h 8349 'complete-history control'
    $h.indexes.scopeComplete = $false
    $h.unlinkedSpecs = New-BoardUnlinkedSpecScope $h.specs $h.indexes
    Assert-R4 $f $h 0 'incomplete history'
  }
  Check 'r4 negative/malformed-json-row' {
    $f = New-R4Fixture 'malformed-json'
    $f.ledger.Add('{broken')
    $h = Get-R4History $f
    Assert-Board ($h.errors.Count -eq 1 -and $h.errors[0] -ceq 'malformed lifecycle row 4') "parse failure stays an error: $($h.errors -join '|')"
    Assert-R4 $f $h 0 'malformed JSON row'
  }
  if ($failures.Count) { throw "$($failures.Count) c2/r2 controls failed ($Mutant)" }
  Write-Output "PASS board-unlinked-scope mutant=$Mutant"
} finally {
  $resolvedRoot = [IO.Path]::GetFullPath($root)
  if ((Split-Path -Parent $resolvedRoot) -ne [IO.Path]::GetTempPath().TrimEnd('\','/') -or
      (Split-Path -Leaf $resolvedRoot) -notlike 'board-scope-test-*') { throw 'unsafe scope fixture cleanup' }
  if (Test-Path -LiteralPath $resolvedRoot) { Remove-Item -LiteralPath $resolvedRoot -Recurse -Force }
}
