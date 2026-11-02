[CmdletBinding()]
param(
  [ValidateSet('none','global-error-reintroduced','kind-less-row-errors','parse-failure-swallowed','intersection-ignored','live-ignored','recent-ignored')][string]$Mutant = 'none',
  [string]$ScriptPath = (Join-Path $PSScriptRoot 'board-reconcile.ps1')
)
$ErrorActionPreference = 'Stop'
[Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal'
$historyScriptPath = $ScriptPath
. (Join-Path $PSScriptRoot 'board-reconcile.test.ps1') -FunctionsOnly
. $historyScriptPath -FunctionsOnly
if ($Mutant -ne 'none') {
  $name = if ($Mutant -in @('kind-less-row-errors','parse-failure-swallowed')) { 'Get-BoardHistory' }
    elseif ($Mutant -in @('live-ignored','recent-ignored')) { 'New-BoardUnlinkedSpecScope' } else { 'Get-BoardUnlinkedSpecReasons' }
  $source = (Get-Item "function:$name").ScriptBlock.ToString()
  $before, $after = switch ($Mutant) {
    'kind-less-row-errors' { "if (-not `$row.kind) { continue }"; "if (-not `$row.kind) { throw 'missing kind' }" }
    'parse-failure-swallowed' { '$errors.Add("malformed lifecycle row $count")'; '$null = $count' }
    'global-error-reintroduced' { 'foreach ($reason in $Scope.active)'; 'foreach ($reason in $Scope.all)' }
    'intersection-ignored' { 'foreach ($lane in $Lanes)'; 'foreach ($lane in @())' }
    'live-ignored' { '$dead -and ($spec.state -ceq ''exited'' -or -not $recent)'; '($dead -or -not $recent) -and ($spec.state -ceq ''exited'' -or -not $recent)' }
    'recent-ignored' { '$dead -and ($spec.state -ceq ''exited'' -or -not $recent)'; '$dead' }
  }
  Assert-Board ($source.Contains($before)) "$Mutant anchor"
  Set-Item "function:$name" ([scriptblock]::Create($source.Replace($before, $after)))
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('board-errors-test-' + [guid]::NewGuid().ToString('N'))
$failures = [Collections.Generic.List[string]]::new()
function Write-Json($Path, $Value) { [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 20 -Compress)) }
function Get-CimInstance {
  [pscustomobject]@{ ProcessId = $PID; ParentProcessId = 0; CreationDate = [datetime]'2025-01-01T00:00:00Z' }
}
function Set-UnlinkedFixtureIdentity($Spec) {
  $Spec.branch = 'codex/synthetic-unrelated'
  $Spec.launcherPid = 2147483646; $Spec.launcherStartIdentity = '2000-01-01T00:00:00.0000000Z'
  $Spec.childPid = 2147483647; $Spec.childStartIdentity = '2000-01-01T00:00:01.0000000Z'
}
function Check([string]$Name, [scriptblock]$Body) {
  try { & $Body; Write-Output "PASS $Name" }
  catch { $failures.Add("${Name}: $($_.Exception.Message)"); Write-Output "FAIL ${Name}: $($_.Exception.Message)" }
}
try {
  Check 'AC1/AC4 six exact July telemetry rows' {
    $f = New-BoardFixture (Join-Path $root 'july') @()
    Copy-Item (Join-Path $PSScriptRoot 'fixtures/board-july-telemetry.jsonl') $f.log
    $h = Get-BoardHistory $f.log
    Assert-Board ($h.count -eq 6 -and $h.rows.Count -eq 0 -and $h.errors.Count -eq 0) 'parseable kind-less rows are non-lifecycle telemetry'
    foreach ($status in @('In review','Landed')) {
      $item = New-BoardItem 908605 $status | ConvertTo-Json -Depth 20 | ConvertFrom-Json
      $p = Get-BoardProjection $item $h
      Assert-Board ($p.known -and $p.action -eq 'clear') "$status drift can clear"
    }
  }
  Check 'AC1/AC3 real JSON parse failure' {
    $f = New-BoardFixture (Join-Path $root 'parse') @()
    [IO.File]::WriteAllText($f.log, "{broken`n")
    $h = Get-BoardHistory $f.log
    Assert-Board ($h.errors.Count -eq 1 -and $h.errors[0] -eq 'malformed lifecycle row 1') 'real parse failure retained'
    $item = New-BoardItem 908605 | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    Assert-Board ((Get-BoardProjection $item $h).action -eq 'deferred') 'unknown JSON scope remains fail-closed'
  }
  foreach ($case in @('unrelated','lane-intersection','transcript-intersection','live','recent','stale-dead','ambiguous','malformed','exited-recent','unknown-age')) {
    Check "AC2/AC3/AC4 issue-less spec $case" {
      $f = New-BoardFixture (Join-Path $root $case) @()
      $a = Add-BoardAttempt $f 0 'synthetic-orphan' 'implementation' 'exited'
      Set-UnlinkedFixtureIdentity $a.spec
      $a.spec.updatedAt = '2026-01-01T00:00:00.0000000Z'
      $a.spec.partialReportPath = Join-Path $f.root 'synthetic-alias.jsonl'
      # No issue field at all, as in the live watchdog envelopes.
      Assert-Board (-not $a.spec.ContainsKey('issue')) 'issue-less live envelope shape'
      if ($case -in @('live','recent','stale-dead','ambiguous')) { $a.spec.state = 'running' }
      if ($case -eq 'live') { $a.spec.childPid = $PID }
      if ($case -in @('recent','exited-recent')) { $a.spec.updatedAt = [datetimeoffset]::UtcNow.ToString('o') }
      if ($case -eq 'unknown-age') { $a.spec.updatedAt = 'not-an-instant' }
      if ($case -eq 'ambiguous') { $a.spec.childStartIdentity = 'not-an-instant' }
      $specPath = Join-Path $f.root 'watchdog-lane-synthetic-orphan.json'
      Write-Json $specPath $a.spec
      if ($case -eq 'malformed') { [IO.File]::WriteAllText($specPath, '{broken') }
      if ($case -in @('lane-intersection','transcript-intersection')) {
        $row = @{ kind = 'dispatch'; ts = '2026-01-01T00:00:00Z'; issue = 908605; laneRole = 'planning'
          lane = $(if ($case -eq 'lane-intersection') { $a.row.lane.ToUpperInvariant() } else { 'synthetic-different-lane' })
          transcript = $(if ($case -eq 'transcript-intersection') { 'synthetic-alias.jsonl' } else { 'synthetic-lineage.jsonl' }) }
        [IO.File]::AppendAllText($f.log, ($row | ConvertTo-Json -Compress) + "`n")
      }
      $h = Get-BoardHistory $f.log
      foreach ($number in @(908605,908606)) {
        $item = New-BoardItem $number | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $p = Get-BoardProjection $item $h
        $defer = $case -in @('live','recent','ambiguous','malformed','unknown-age') -or ($number -eq 908605 -and $case -like '*intersection')
        Assert-Board ($p.known -eq (-not $defer)) "$case issue $number known=$(-not $defer); actual=$($p.why)"
        Assert-Board ($p.action -eq $(if ($defer) { 'deferred' } else { 'clear' })) "$case projection action"
        if ($defer) { Assert-Board ($p.why -like '*unlinked watchdog*') 'in-scope ambiguity explained' }
      }
    }
  }
  Check 'AC4 synthetic full dry run repairs review and open-Landed class drift' {
    $f = New-BoardFixture (Join-Path $root 'dry-run') @((New-BoardItem 908605 'In review'), (New-BoardItem 908606 'Landed'))
    $a = Add-BoardAttempt $f 0 'synthetic-unrelated' 'implementation' 'exited'
    Set-UnlinkedFixtureIdentity $a.spec
    $a.spec.updatedAt = '2026-01-01T00:00:00.0000000Z'
    Write-Json (Join-Path $f.root 'watchdog-lane-synthetic-unrelated.json') $a.spec
    Copy-Item (Join-Path $PSScriptRoot 'fixtures/board-july-telemetry.jsonl') $f.log -Force
    $r = & $historyScriptPath -DispatchLog $f.log -GhCommand $f.gh | ConvertFrom-Json
    Assert-Board (-not $r.applied -and $r.qualifying -eq 2 -and $r.mutations -eq 0 -and $r.deferred -eq 0) 'two drift corrections planned, no writes or deferrals'
    Assert-Board ((Get-BoardCalls $f 'mutation|workflow').Count -eq 0) 'dry run never mutates'
  }
  if ($failures.Count) { throw "$($failures.Count) focused cases failed ($Mutant)" }
  Write-Output "PASS board-history-errors mutant=$Mutant"
} finally {
  $resolved = [IO.Path]::GetFullPath($root)
  if ((Split-Path -Parent $resolved) -ne [IO.Path]::GetTempPath().TrimEnd('\','/') -or (Split-Path -Leaf $resolved) -notlike 'board-errors-test-*') { throw 'unsafe errors fixture cleanup' }
  if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
