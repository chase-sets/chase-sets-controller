[CmdletBinding()]
param([switch]$FunctionsOnly, [string]$ScriptPath = (Join-Path $PSScriptRoot 'board-reconcile.ps1'))
$ErrorActionPreference = 'Stop'
function Assert-Board([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}
function New-BoardItem([int]$Number, [string]$Status = 'In lane') {
  return [ordered]@{
    id = "PVTI_SYNTHETIC_$Number"; status = @{ name = $Status; updatedAt = '2026-01-01T00:00:00Z' }
    content = @{ __typename = 'Issue'; id = "I_SYNTHETIC_$Number"; number = $Number; state = 'OPEN'
      issueType = @{ name = 'Task' }; labels = @{ nodes = @(); pageInfo = @{ hasNextPage = $false } }
      closedByPullRequestsReferences = @{ nodes = @(); pageInfo = @{ hasNextPage = $false } } }
  }
}
function New-BoardFixture([string]$Root, [object[]]$Items) {
  [void](New-Item -ItemType Directory -Path $Root -Force)
  $fixture = @{ root = $Root; log = (Join-Path $Root 'dispatch.jsonl'); gh = (Join-Path $Root 'gh.ps1')
    data = (Join-Path $Root 'items.json'); calls = (Join-Path $Root 'calls.jsonl'); race = (Join-Path $Root 'race.json') }
  [IO.File]::WriteAllText($fixture.log, '')
  [IO.File]::WriteAllText($fixture.data, (ConvertTo-Json -InputObject @($Items) -Depth 20))
  [IO.File]::WriteAllText($fixture.gh, @'
$ErrorActionPreference = 'Stop'
$data = Join-Path $PSScriptRoot 'items.json'
[IO.File]::AppendAllText((Join-Path $PSScriptRoot 'calls.jsonl'), (ConvertTo-Json -InputObject @($args) -Compress) + "`n")
$argsList = @($args)
function Arg([string]$Name) {
  foreach ($a in $argsList) { if ($a.StartsWith($Name + '=')) { return $a.Substring($Name.Length + 1) } }
}
if ($args[0] -eq 'variable') {
  if ($args[2] -eq 'DELIVERY_STATUS_OPTION_IDS') { '{"In lane":"lane","In review":"review","Landed":"landed"}' }
  else { 'PVT_SYNTHETIC' }
  exit 0
}
if ($args[0] -eq 'workflow') { '{"ok":true}'; exit 0 }
$query = Arg 'query'
$items = @(Get-Content $data -Raw | ConvertFrom-Json -AsHashtable)
if ($query -match 'mutation') {
  $item = @($items | Where-Object id -eq (Arg 'i'))[0]
  if ($query -match 'clearProject') { $item.status.name = '' }
  elseif ($query -match 'updateProject') { $item.status.name = switch (Arg 'o') { 'lane' { 'In lane' }; 'review' { 'In review' }; 'landed' { 'Landed' } } }
  else { throw 'unexpected synthetic mutation' }
  [IO.File]::WriteAllText($data, (ConvertTo-Json -InputObject $items -Depth 20))
  '{"data":{"updateProjectV2ItemFieldValue":{"projectV2Item":{"id":"synthetic"}},"clearProjectV2ItemFieldValue":{"projectV2Item":{"id":"synthetic"}}}}'
  exit 0
}
if ($query -match 'issue\(number:') {
  $readPath = Join-Path $PSScriptRoot 'issue-read-count'
  $readCount = if (Test-Path $readPath) { 1 + [int](Get-Content $readPath) } else { 1 }
  [IO.File]::WriteAllText($readPath, [string]$readCount)
  $racePath = Join-Path $PSScriptRoot 'race.json'
  if (Test-Path $racePath) {
    $race = Get-Content $racePath -Raw | ConvertFrom-Json -AsHashtable
    if (-not $race.atRead -or $readCount -eq $race.atRead) {
    if ($race.row) { [IO.File]::AppendAllText((Join-Path $PSScriptRoot 'dispatch.jsonl'), ($race.row | ConvertTo-Json -Compress) + "`n") }
    if ($race.ContainsKey('replaceLog')) { [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'dispatch.jsonl'), [string]$race.replaceLog) }
    if ($race.spec) { [IO.File]::WriteAllText((Join-Path $PSScriptRoot "watchdog-lane-$($race.spec.label).json"), ($race.spec | ConvertTo-Json -Depth 10)) }
    if ($race.status) { $items[0].status.name = $race.status }
    if ($race.state) { $items[0].content.state = $race.state }
    if ($race.pr) { $items[0].content.closedByPullRequestsReferences.nodes = @($race.pr) }
    [IO.File]::WriteAllText($data, (ConvertTo-Json -InputObject $items -Depth 20))
    Remove-Item -LiteralPath $racePath
    }
  }
  if (Test-Path (Join-Path $PSScriptRoot 'fail-fresh')) { exit 1 }
  $item = @($items | Where-Object { $_.content.number -eq [int](Arg 'number') })[0]
  $issue = $item.content.Clone()
  $issue.projectItems = @{ nodes = @(@{ id = $item.id; project = @{ id = 'PVT_SYNTHETIC' }; status = $item.status }); pageInfo = @{ hasNextPage = $false } }
  [IO.File]::AppendAllText((Join-Path $PSScriptRoot 'observations.jsonl'), (@{ phase = 'issue'; read = $readCount; item = $item } | ConvertTo-Json -Depth 20 -Compress) + "`n")
  @{ data = @{ repository = @{ issue = $issue } } } | ConvertTo-Json -Depth 20 -Compress
  exit 0
}
[IO.File]::AppendAllText((Join-Path $PSScriptRoot 'observations.jsonl'), (@{ phase = 'initial-page'; items = $items } | ConvertTo-Json -Depth 20 -Compress) + "`n")
@{ data = @{ node = @{ items = @{ nodes = $items; pageInfo = @{ hasNextPage = $false; endCursor = $null } } } } } | ConvertTo-Json -Depth 20 -Compress
exit 0
'@)
  return $fixture
}
function Add-BoardAttempt($Fixture, [int]$Issue, [string]$Label, [string]$Role = 'implementation', [string]$State = 'running') {
  $row = @{ ts = [datetimeoffset]::UtcNow.AddHours(-7).ToString('o'); kind = 'dispatch'; issue = $Issue
    lane = "synthetic-$Label"; laneRole = $Role; transcript = "$Label.jsonl"; attemptId = $Label }
  $spec = @{ schemaVersion = 'watchdog-lane/v2'; label = $Label; attemptId = $Label; laneRole = $Role
    worktree = (Join-Path $Fixture.root "synthetic-$Label"); state = $State; launchId = [guid]::NewGuid().ToString()
    childPid = $PID; childStartIdentity = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o') }
  [IO.File]::AppendAllText($Fixture.log, ($row | ConvertTo-Json -Compress) + "`n")
  [IO.File]::WriteAllText((Join-Path $Fixture.root "watchdog-lane-$Label.json"), ($spec | ConvertTo-Json))
  return @{ row = $row; spec = $spec }
}
function Get-BoardCalls($Fixture, [string]$Pattern) {
  return @(Get-Content $Fixture.calls | Where-Object { $_ -match $Pattern })
}
if ($FunctionsOnly) { return }
$root = Join-Path ([IO.Path]::GetTempPath()) ('board-reconcile-test-' + [guid]::NewGuid().ToString('N'))
function Run-Board($Fixture, [switch]$Apply) {
  & $ScriptPath -DispatchLog $Fixture.log -GhCommand $Fixture.gh -Apply:$Apply | ConvertFrom-Json -DateKind String
}
try {
  $f = New-BoardFixture (Join-Path $root 'implementation-planning') @((New-BoardItem 908449))
  $null = Add-BoardAttempt $f 908449 'implementation'
  $p = Add-BoardAttempt $f 908449 'planning' 'planning' 'exited'; $p.row.kind = 'lane-complete'
  [IO.File]::AppendAllText($f.log, ($p.row | ConvertTo-Json -Compress) + "`n")
  $r = Run-Board $f -Apply
  Assert-Board ($r.qualifying -eq 0 -and $r.projections[0].desired -eq 'In lane') 'live implementation beside completed planning keeps In lane'
  Write-Output 'PASS implementation-planning'

  $item = New-BoardItem 908450 'In review'
  $item.content.closedByPullRequestsReferences.nodes = @(@{ number = 909001; state = 'OPEN'; isDraft = $false })
  $f = New-BoardFixture (Join-Path $root 'implementation-precedence') @($item)
  $null = Add-BoardAttempt $f 908450 'impl'; $null = Add-BoardAttempt $f 908450 'review' 'review'
  $r = Run-Board $f -Apply
  Assert-Board ($r.qualifying -eq 1 -and $r.mutations -eq 1 -and $r.findings[0].desired -eq 'In lane') 'one issue with implementation+review+PR projects once as In lane'
  Assert-Board ((Get-BoardCalls $f 'updateProjectV2ItemFieldValue').Count -eq 1) 'one mutation per issue'
  Write-Output 'PASS implementation-precedence'

  foreach ($case in @('exited', 'dead', 'expired-specless', 'young-specless', 'ambiguous', 'malformed-pid', 'malformed-spec', 'mismatched', 'unlinked-watchdog', 'orphan-spec', 'tail-401', 'live-review')) {
    $status = if ($case -eq 'live-review') { 'In review' } else { 'In lane' }
    $f = New-BoardFixture (Join-Path $root $case) @((New-BoardItem 908451 $status))
    $a = Add-BoardAttempt $f 908451 'attempt' $(if ($case -eq 'live-review') { 'review' } else { 'implementation' })
    $specPath = Join-Path $f.root 'watchdog-lane-attempt.json'
    switch ($case) {
      'exited' { $a.spec.state = 'exited' }
      'dead' { $a.spec.childStartIdentity = '2000-01-01T00:00:00Z' }
      'ambiguous' { $a.spec.childStartIdentity = 'not-an-instant' }
      'malformed-pid' { $a.spec.childPid = 'not-a-pid' }
      'mismatched' { $a.spec.attemptId = 'different-attempt' }
      'unlinked-watchdog' { [IO.File]::AppendAllText($f.log, (@{ kind = 'lane-blocked'; watchdogSchema = 'watchdog-relaunch/v1'; attemptId = 'attempt'; lane = 'synthetic-attempt'; ts = [datetimeoffset]::UtcNow.ToString('o') } | ConvertTo-Json -Compress) + "`n") }
      'tail-401' { 1..400 | ForEach-Object { [IO.File]::AppendAllText($f.log, (@{ kind = 'gc'; ts = [datetimeoffset]::UtcNow.ToString('o') } | ConvertTo-Json -Compress) + "`n") } }
      'young-specless' { $a.row.ts = [datetimeoffset]::UtcNow.ToString('o'); [IO.File]::WriteAllText($f.log, ($a.row | ConvertTo-Json -Compress) + "`n") }
    }
    [IO.File]::WriteAllText($specPath, ($a.spec | ConvertTo-Json))
    if ($case -eq 'malformed-spec') { [IO.File]::WriteAllText($specPath, '{broken') }
    if ($case -eq 'orphan-spec') { [IO.File]::WriteAllText($f.log, '') }
    if ($case -like '*specless') { Remove-Item -LiteralPath $specPath }
    $r = Run-Board $f -Apply
    if ($case -in @('exited', 'dead', 'expired-specless')) { Assert-Board ($r.mutations -eq 1 -and $r.findings[0].action -eq 'cleared') "$case is dead" }
    elseif ($case -in @('tail-401', 'live-review')) {
      Assert-Board ($r.qualifying -eq 0 -and $r.deferred -eq 0 -and $r.projections[0].desired -eq $status) "$case remains live"
      if ($case -eq 'tail-401') { Assert-Board ($r.lifecycleRows -eq 401) 'canonical history includes tail miss' }
    } else { Assert-Board ($r.mutations -eq 0 -and $r.deferred -eq 1 -and $r.findings[0].why) "$case defers visibly" }
    Write-Output "PASS $case"
  }
  foreach ($state in @('live', 'dead')) {
    $case = "malformed-launch-$state"
    $f = New-BoardFixture (Join-Path $root $case) @((New-BoardItem 908451 'In review'))
    $a = Add-BoardAttempt $f 908451 'malformed-launch'
    $a.spec.launchId = 'SYNTHETIC-NOT-A-LAUNCH-IDENTITY'
    if ($state -eq 'dead') { $a.spec.childStartIdentity = '2000-01-01T00:00:00Z' }
    [IO.File]::WriteAllText((Join-Path $f.root 'watchdog-lane-malformed-launch.json'), ($a.spec | ConvertTo-Json))
    $r = Run-Board $f -Apply
    Assert-Board ($r.projections[0].known -eq $false -and $r.findings[0].action -eq 'deferred') "$case is unknown/deferred"
    Assert-Board ($r.mutations -eq 0 -and $r.deferred -eq 1 -and $r.findings[0].why -match 'malformed watchdog') "$case defers with a visible malformed-watchdog reason"
    Assert-Board ((Get-BoardCalls $f 'mutation').Count -eq 0) "$case makes no board write"
    $after = @(Get-Content $f.data -Raw | ConvertFrom-Json)
    Assert-Board ($after[0].status.name -eq 'In review') "$case leaves status unchanged"
    Write-Output "PASS $case"
  }
  $f = New-BoardFixture (Join-Path $root 'terminal-control') @((New-BoardItem 908451))
  $a = Add-BoardAttempt $f 908451 'terminal'; $a.row.kind = 'lane-complete'
  [IO.File]::AppendAllText($f.log, ($a.row | ConvertTo-Json -Compress) + "`n")
  $r = Run-Board $f -Apply
  Assert-Board ($r.mutations -eq 1 -and $r.findings[0].action -eq 'cleared') 'terminal row retires its still-live process only'
  Write-Output 'PASS terminal-control'
  $f = New-BoardFixture (Join-Path $root 'sibling-issues') @((New-BoardItem 908451), (New-BoardItem 908452 'Refined'))
  $null = Add-BoardAttempt $f 908452 'other-review' 'review'
  $null = Add-BoardAttempt $f 908451 'own-planning' 'planning'
  $r = Run-Board $f -Apply
  Assert-Board ($r.mutations -eq 2 -and $r.projections[0].desired -eq $null -and $r.projections[1].desired -eq 'In review') 'sibling planning/review never own another issue'
  Write-Output 'PASS sibling-issues'
  foreach ($case in @('draft', 'non-draft', 'degraded', 'missing-log', 'malformed-log')) {
    $item = New-BoardItem 908452 'In review'
    if ($case -in @('draft', 'non-draft')) { $item.content.closedByPullRequestsReferences.nodes = @(@{ number = 909002; state = 'OPEN'; isDraft = ($case -eq 'draft') }) }
    if ($case -eq 'degraded') { $item.content.closedByPullRequestsReferences.pageInfo.hasNextPage = $true }
    $f = New-BoardFixture (Join-Path $root $case) @($item)
    if ($case -eq 'missing-log') { Remove-Item -LiteralPath $f.log }
    if ($case -eq 'malformed-log') { [IO.File]::WriteAllText($f.log, '{broken') }
    $r = Run-Board $f -Apply
    if ($case -eq 'draft') { Assert-Board ($r.mutations -eq 1) 'draft does not protect status' }
    elseif ($case -eq 'non-draft') { Assert-Board ($r.qualifying -eq 0 -and $r.projections[0].desired -eq 'In review') 'non-draft closing PR protects status' }
    else { Assert-Board ($r.mutations -eq 0 -and $r.deferred -eq 1) "$case applies nothing" }
    Write-Output "PASS $case"
  }
  $items = @((New-BoardItem 908453 'Landed'), (New-BoardItem 908454 'Canceled'), (New-BoardItem 908455 'Epic'), (New-BoardItem 908456 'Tracking'), (New-BoardItem 908457 'Landed'), (New-BoardItem 908458 'Landed'))
  $items[0].content.state = 'CLOSED'; $items[0].content.stateReason = 'COMPLETED'
  $items[1].content.state = 'CLOSED'; $items[1].content.stateReason = 'NOT_PLANNED'
  $items[2].content.issueType.name = 'Epic'; $items[3].content.labels.nodes = @(@{ name = 'status:tracking-only' })
  $f = New-BoardFixture (Join-Path $root 'eligibility') $items; $null = Add-BoardAttempt $f 908458 'eligible-impl'
  $r = Run-Board $f -Apply
  Assert-Board ($r.qualifying -eq 2 -and $r.mutations -eq 2 -and $r.syncDispatched) 'legacy open Landed clears or becomes In lane'
  $after = @(Get-Content $f.data -Raw | ConvertFrom-Json)
  foreach ($i in 0..3) { Assert-Board ($after[$i].status.name -eq $items[$i].status.name) 'closed/Epic/Tracking untouched' }
  Assert-Board ($after[4].status.name -eq '' -and $after[5].status.name -eq 'In lane') 'eligible legacy Landed projections'
  Write-Output 'PASS closed-completed/closed-not-planned/Epic/Tracking/legacy-Landed'

  $items = @(1..12 | ForEach-Object { $item = New-BoardItem (908500 + $_); $item.status.updatedAt = [datetimeoffset]::UtcNow.AddDays(-$_).ToString('o'); $item })
  $f = New-BoardFixture (Join-Path $root 'cap') $items; $r = Run-Board $f -Apply
  Assert-Board ($r.qualifying -eq 12 -and $r.mutations -eq 10 -and $r.deferred -eq 2) '12 -> 10 applied / 2 deferred default cap'
  $cleared = @($r.findings | Where-Object action -eq 'cleared')
  Assert-Board (($cleared.issue -join ',') -eq ((908512..908503) -join ',')) 'oldest status first'
  Assert-Board ((Get-BoardCalls $f 'project-status-sync.yml').Count -eq 1) 'one sync dispatch for ten clears'
  Assert-Board (-not $r.telemetryError -and @((Get-Content $f.log | ConvertFrom-Json) | Where-Object kind -eq 'gc').Count -eq 1) 'clear telemetry remains in the fixture log'
  $r = Run-Board $f -Apply
  Assert-Board ($r.qualifying -eq 2 -and $r.mutations -eq 2 -and $r.deferred -eq 0) 'successive run drains remainder'
  $r = Run-Board $f -Apply; Assert-Board ($r.qualifying -eq 0 -and $r.mutations -eq 0) 'converged no actionable drift'
  Write-Output 'PASS cap-12-10-2/oldest-first/convergence'
  foreach ($case in @('blank', 'noop', 'report-only')) {
    $f = New-BoardFixture (Join-Path $root $case) @((New-BoardItem 908460 $(if ($case -eq 'noop') { 'Refined' } else { '' })))
    $r = Run-Board $f -Apply:($case -ne 'report-only')
    Assert-Board ((Get-BoardCalls $f 'project-status-sync.yml').Count -eq $(if ($case -eq 'blank') { 1 } else { 0 })) "$case sync count"
    Write-Output "PASS $case"
  }
  foreach ($case in @('implementation-race', 'late-implementation-race', 'review-race', 'unknown-race', 'pr-race', 'draft-race', 'board-race', 'closed-race', 'fresh-failure')) {
    $f = New-BoardFixture (Join-Path $root $case) @((New-BoardItem 908461)); $race = @{}
    if ($case -in @('implementation-race', 'late-implementation-race', 'review-race', 'unknown-race')) {
      $race = Add-BoardAttempt $f 908461 'arrival' $(if ($case -eq 'review-race') { 'review' } else { 'implementation' })
      [IO.File]::WriteAllText($f.log, ''); Remove-Item -LiteralPath (Join-Path $f.root 'watchdog-lane-arrival.json')
      if ($case -eq 'unknown-race') { $race.spec.childStartIdentity = 'ambiguous' }
      if ($case -eq 'late-implementation-race') { $race.atRead = 2 }
    }
    if ($case -eq 'pr-race') { $race.pr = @{ number = 909003; state = 'OPEN'; isDraft = $false } }
    if ($case -eq 'draft-race') { $race.pr = @{ number = 909003; state = 'OPEN'; isDraft = $true } }
    if ($case -eq 'board-race') { $race.status = 'In review' }
    if ($case -eq 'closed-race') { $race.state = 'CLOSED' }
    if ($case -eq 'fresh-failure') { [IO.File]::WriteAllText((Join-Path $f.root 'fail-fresh'), '') }
    else { [IO.File]::WriteAllText($f.race, ($race | ConvertTo-Json -Depth 20)) }
    $r = Run-Board $f -Apply
    Assert-Board ($r.mutations -eq 0 -and $r.deferred -eq 1) "$case vetoes mutation"
    Assert-Board ((Get-BoardCalls $f 'mutation').Count -eq 0) "$case makes no board write"
    Write-Output "PASS $case"
  }
  Write-Output 'PASS board-reconcile projection regression suite'
} finally {
  $resolved = [IO.Path]::GetFullPath($root); $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
  if ((Split-Path -Parent $resolved).TrimEnd('\', '/') -ne $temp -or (Split-Path -Leaf $resolved) -notlike 'board-reconcile-test-*') { throw 'unsafe board test cleanup' }
  if (Test-Path $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
