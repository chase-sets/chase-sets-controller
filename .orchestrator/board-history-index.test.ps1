[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
[Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal'
. (Join-Path $PSScriptRoot 'board-reconcile.test.ps1') -FunctionsOnly
. (Join-Path $PSScriptRoot 'board-reconcile.ps1') -FunctionsOnly
$candidateHistory = ${function:Get-BoardHistory}
$candidateProjection = ${function:Get-BoardProjection}
. (Join-Path $PSScriptRoot 'fixtures/board-history-v289.ps1')
$referenceHistory = ${function:Get-BoardHistory}
$referenceProjection = ${function:Get-BoardProjection}
$root = Join-Path ([IO.Path]::GetTempPath()) ('board-index-test-' + [guid]::NewGuid().ToString('N'))
Add-Type -TypeDefinition @'
using System;
using System.Collections;
public sealed class BoardFullHistoryTrap : IEnumerable {
    public IEnumerator GetEnumerator() { throw new InvalidOperationException("FULL_HISTORY_ACCESS"); }
    public int Count { get { throw new InvalidOperationException("FULL_HISTORY_ACCESS"); } }
    public object this[int i] { get { throw new InvalidOperationException("FULL_HISTORY_ACCESS"); } }
}
'@
function Json($Value) { ConvertTo-Json -InputObject $Value -Depth 30 -Compress }
function Assert-SameProjection($Item, $Actual, $Expected, [string]$Name) {
  $want = & $referenceProjection $Item $Expected
  $got = & $candidateProjection $Item $Actual
  Assert-Board ((Json $got) -ceq (Json $want)) "$Name exact projection/evidence"
}
function Protect-FullHistory($History) {
  # Replace every escaped complete collection, including copied aliases, not
  # just the public rows property. Indexed subsets retain their row objects.
  $full = @($History.rows)
  $signature = Json @($full | ForEach-Object { Json $_ } | Sort-Object)
  function Protect-Dictionary($Dictionary) {
    foreach ($key in @($Dictionary.Keys)) {
      $value = $Dictionary[$key]
      if ($value -is [Collections.IDictionary]) { Protect-Dictionary $value; continue }
      if ($value -is [string] -or $value -isnot [Collections.IEnumerable] -or $value -is [BoardFullHistoryTrap]) { continue }
      $members = @($value)
      if ($full.Count -gt 0 -and $members.Count -eq $full.Count -and
          (Json @($members | ForEach-Object { Json $_ } | Sort-Object)) -ceq $signature) {
        $Dictionary[$key] = [BoardFullHistoryTrap]::new()
      } else {
        foreach ($member in $members) {
          if ($member -is [Collections.IDictionary]) { Protect-Dictionary $member }
        }
      }
    }
  }
  Protect-Dictionary $History
}
try {
  foreach ($case in @('typed-issues','case-lanes','typed-lane-order','case-labels','invalid-history','invalid-spec','unreadable','inventory-unreadable','specless-359','specless-361')) {
    $f = New-BoardFixture (Join-Path $root $case) @((New-BoardItem 8548))
    $a = Add-BoardAttempt $f 8548 'CaseLabel'
    if ($case -eq 'typed-issues') {
      Remove-Item -LiteralPath (Join-Path $f.root 'watchdog-lane-CaseLabel.json')
      $values = @(8548, '8548', '08548', 8548.5, 0, '', $null, '0', $true, $false,
        @(8548, 2), @(0, 0), @(@(8548), 2), [pscustomobject]@{ n = 8548 }, -1, 2147483647,
        8548.0, "85$([char]0x00ad)48")
      foreach ($value in $values) {
        $row = $a.row.Clone(); $row.issue = $value; $row.kind = 'lane-complete'
        [IO.File]::AppendAllText($f.log, (Json $row) + "`n")
      }
    }
    if ($case -eq 'case-lanes') {
      foreach ($field in @('watchdogSchema','dispatchRoutingSchema')) {
        $row = @{ kind = 'lane-blocked'; lane = 'SYNTHETIC-caselabel'; issue = $null }
        $row[$field] = 'synthetic/v1'
        [IO.File]::AppendAllText($f.log, (Json $row) + "`n")
      }
    }
    if ($case -eq 'case-labels') {
      $a.row.transcript = 'caselabel.jsonl'
      [IO.File]::WriteAllText($f.log, (Json $a.row) + "`n")
    }
    if ($case -eq 'typed-lane-order') {
      $a.row.lane = 'True'
      [IO.File]::WriteAllText($f.log, (Json $a.row) + "`n")
      foreach ($lane in @($true, 'TRUE')) {
        $row = @{ kind = 'lane-blocked'; lane = $lane; issue = $null; watchdogSchema = 'synthetic/v1' }
        [IO.File]::AppendAllText($f.log, (Json $row) + "`n")
      }
    }
    if ($case -eq 'invalid-history') {
      [IO.File]::AppendAllText($f.log, "`n{broken`n{} `n" + (Json @{ kind = 'unrelated'; outcome = 'REPLAN_COMPLETE'; issue = 8548 }) + "`n")
    }
    if ($case -eq 'invalid-spec') { [IO.File]::WriteAllText((Join-Path $f.root 'watchdog-lane-orphan.json'), '{broken') }
    if ($case -eq 'unreadable') { Remove-Item -LiteralPath $f.log }
    if ($case -eq 'inventory-unreadable') { $f.log = Join-Path $f.root 'missing-directory/dispatch.jsonl' }
    if ($case -like 'specless-*') {
      Remove-Item -LiteralPath (Join-Path $f.root 'watchdog-lane-CaseLabel.json')
      $a.row.ts = [datetimeoffset]::UtcNow.AddMinutes(-[int]$case.Split('-')[1]).ToString('o')
      [IO.File]::WriteAllText($f.log, (Json $a.row) + "`n")
    }
    $expected = & $referenceHistory $f.log
    $actual = & $candidateHistory $f.log
    Assert-Board ($actual.count -eq $expected.count) "$case nonblank count"
    Assert-Board ((Json $actual.rows) -ceq (Json $expected.rows)) "$case retained bytes/order/fields"
    Assert-Board ((Json @($actual.errors | Sort-Object)) -ceq (Json @($expected.errors | Sort-Object))) "$case error multiset"
    if ($case -eq 'invalid-history') {
      Assert-Board ($actual.errors -contains 'malformed lifecycle row 2' -and $actual.errors -contains 'malformed lifecycle row 3') 'nonblank error row numbers'
    }
    $actual.copiedAlias = @($actual.rows | ForEach-Object { $_ })
    Protect-FullHistory $actual
    foreach ($number in @(8548, 2, 0, -1, 2147483647)) {
      $item = New-BoardItem $number | ConvertTo-Json -Depth 20 | ConvertFrom-Json
      Assert-SameProjection $item $actual $expected "$case/$number"
      if ($number -eq 8548 -and $case -like 'specless-*') {
        Assert-Board ((& $candidateProjection $item $actual).known -eq ($case -eq 'specless-361')) 'six-hour spec-less boundary'
      }
    }
    if ($case -eq 'case-lanes') {
      $item = New-BoardItem 8548 | ConvertTo-Json -Depth 20 | ConvertFrom-Json
      Assert-Board (-not (& $candidateProjection $item $actual).known) 'case-variant issue-less evidence refuses'
      $ordinal = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
      foreach ($key in $actual.indexes.lanes.Keys) { $ordinal[$key] = $actual.indexes.lanes[$key] }
      $actual.indexes.lanes = $ordinal
      Assert-Board ((Json (& $candidateProjection $item $actual)) -cne (Json (& $referenceProjection $item $expected))) 'ordinal lane mutant differs'
      Write-Output 'CONTROL ordinal-lane-key: rejected'
    }
    Write-Output "PASS board-history-index-equivalence $case"
  }
  $f = New-BoardFixture (Join-Path $root 'int-mutant') @((New-BoardItem 8548))
  $a = Add-BoardAttempt $f 8548 'typed'
  $a.row.issue = '08548'; [IO.File]::WriteAllText($f.log, (Json $a.row) + "`n")
  $expected = & $referenceHistory $f.log; $actual = & $candidateHistory $f.log
  $item = New-BoardItem 8548 | ConvertTo-Json -Depth 20 | ConvertFrom-Json
  $intIndex = [Collections.Generic.Dictionary[string,object]]::new()
  foreach ($row in $actual.rows) {
    $key = [string][int]$row.issue
    if (-not $intIndex.ContainsKey($key)) { $intIndex[$key] = [Collections.Generic.List[object]]::new() }
    $intIndex[$key].Add(@{ row = $row })
  }
  $mutantHistory = $actual.Clone(); $mutantHistory.indexes = $actual.indexes.Clone(); $mutantHistory.indexes.issues = $intIndex
  $intResult = & {
    function Get-BoardIssueRows($Indexes, [int]$Number) { foreach ($entry in $Indexes.issues[[string]$Number]) { $entry.row } }
    & $candidateProjection $item $mutantHistory
  }
  Assert-Board ((Json $intResult) -cne (Json (& $referenceProjection $item $expected))) 'int-coerced issue mutant differs'
  Write-Output 'CONTROL int-coerced-issue-key: rejected'
  $actual.copiedAlias = @($actual.rows | ForEach-Object { $_ })
  $actual.deepAlias = @(Json $actual.rows | ConvertFrom-Json -DateKind String)
  $actual.nested = @{ copy = @($actual.rows | ForEach-Object { $_ }) }
  Protect-FullHistory $actual
  foreach ($arm in @('issue','lane','copied-alias','deep-copied-alias','nested-copied-alias')) {
    $text = $candidateProjection.ToString()
    if ($arm -eq 'issue') {
      $text = $text.Replace('$related = @(Get-BoardIssueRows $History.indexes $native.number)', '$related = @($History.rows | Where-Object { $_.issue -eq $native.number })')
    } else {
      $target = switch ($arm) {
        'lane' { '$History.rows' }; 'copied-alias' { '$History.copiedAlias' }
        'deep-copied-alias' { '$History.deepAlias' }; 'nested-copied-alias' { '$History.nested.copy' }
      }
      $text = $text.Replace('(Get-BoardUnlinkedLaneRows $History.indexes $lanes)', $target)
    }
    $caught = $false
    try { $null = & ([scriptblock]::Create($text)) $item $actual } catch { $caught = $_.Exception.Message -match 'FULL_HISTORY_ACCESS' }
    Assert-Board $caught "$arm scan mutant trips execution trap"
    Write-Output "CONTROL full-history-${arm}: rejected"
  }
  Write-Output 'PASS board-history-index-equivalence / zero full-history enumeration'
} finally {
  $resolved = [IO.Path]::GetFullPath($root)
  if ((Split-Path -Parent $resolved) -ne [IO.Path]::GetTempPath().TrimEnd('\','/') -or (Split-Path -Leaf $resolved) -notlike 'board-index-test-*') { throw 'unsafe index cleanup' }
  if (Test-Path $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
