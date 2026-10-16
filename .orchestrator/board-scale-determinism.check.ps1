[CmdletBinding()]
param()
# Requires local B commit/blob objects; this direct reviewer check is not a battery item.
$ErrorActionPreference = 'Stop'
[Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal'
. (Join-Path $PSScriptRoot 'board-scale-test-support.ps1')
Assert-Board ([bool](Get-Command Get-BoardScaleDecision -ErrorAction SilentlyContinue)) 'count decision replaces installed wall decision'
$root = Join-Path ([IO.Path]::GetTempPath()) ('board-scale-determinism-' + [guid]::NewGuid().ToString('N'))
$evidence = if ($env:BOARD_SCALE_EVIDENCE_ROOT) { $env:BOARD_SCALE_EVIDENCE_ROOT } else { Join-Path $PSScriptRoot 'logs/board-scale' }
[void][IO.Directory]::CreateDirectory($root)
[void][IO.Directory]::CreateDirectory($evidence)
$reportPath = Join-Path $evidence ("determinism-$([guid]::NewGuid().ToString('N')).json")
$report = [ordered]@{ schema = 'board-scale-determinism/v1'; sourceHead = (& git -C $PSScriptRoot rev-parse HEAD)
  supportBlob = (& git -C $PSScriptRoot hash-object (Join-Path $PSScriptRoot 'board-scale-test-support.ps1'))
  priority = [string][Diagnostics.Process]::GetCurrentProcess().PriorityClass
  controls = @(); boundaryTraces = @(); actualVectors = @(); replayMatrix = @(); verdict = 'FAIL' }
$oldCounts = $env:BOARD_SCALE_COUNTS; $oldDelay = $env:BOARD_SCALE_CENSUS_DELAY; $oldSchedule = $env:BOARD_SCALE_SCHEDULE
function Copy-CheckValue($Value) { return $Value | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable }
function Assert-Refuses([string]$Name, [scriptblock]$Action, [scriptblock]$Bypass) {
  $reason = $null
  try { & $Action | Out-Null } catch { $reason = $_.Exception.Message }
  Assert-Board ([bool]$reason) "$Name refuses"
  & $Bypass | Out-Null
  $report.controls += @{ name = $Name; rejected = $true; reason = $reason; oneVariableBypass = 'PASS' }
}
function Assert-Killed([string]$Name, [string]$Source, [scriptblock]$Check) {
  $null = Read-CheckAst $Source
  $reason = $null
  try { & { param($s,$c) . ([scriptblock]::Create($s)); & $c } $Source $Check } catch { $reason = $_.Exception.Message }
  Assert-Board ([bool]$reason) "$Name mutant killed"
  & $Check
  $report.controls += @{ name = $Name; killed = $true; reason = $reason; unchangedCheck = 'PASS' }
}
function Read-CheckAst([string]$Source) {
  $tokens = $null; $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseInput($Source, [ref]$tokens, [ref]$errors)
  Assert-Board ($errors.Count -eq 0) 'check source parses'
  return $ast
}
function Get-CheckFunction([string]$Source, [string]$Name) {
  return (Read-CheckAst $Source).Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $Name }, $true).Extent.Text
}
function Get-CheckAssertions([string]$Source) {
  return @((Read-CheckAst $Source).FindAll({
    param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Assert-Board'
  }, $true) | ForEach-Object { @{ message = $_.CommandElements[-1].Extent.Text; source = $_.Extent.Text } })
}
function Assert-FunctionalInventory([string]$Source) {
  $current = @(Get-CheckAssertions $Source)
  foreach ($entry in $script:baselineAssertions) {
    if ($entry.message -in $script:replacedMessages) { continue }
    $matches = @($current | Where-Object message -CEQ $entry.message)
    Assert-Board ($matches.Count -eq 1) "B assertion retained: $($entry.message)"
    if ($entry.message -cne "'real writer fixture-ledger forwarding'") {
      Assert-Board ($matches[0].source -ceq $entry.source) "B assertion unchanged: $($entry.message)"
    }
  }
}
function New-CheckObservation($Expected, [string]$Counter = '') {
  $passes = @()
  for ($i = 1; $i -le $Expected.passes; $i++) {
    $passes += @{ ordinal = $i; path = 'synthetic/dispatch.jsonl'; parse = [long]$Expected.parse; linkage = [long]$Expected.linkage; complete = $true }
  }
  $o = @{ schema = 'board-scale-work/v1'; limits = $Expected; passes = $passes; selection = [long]$Expected.selected
    first = $null; status = 'PASS'; boardComplete = $true
    waits = @(@{ ordinal = 1; phase = 'board'; requested = 0; executed = 0; afterBoard = $false }) }
  if ($Counter) {
    $o.passes = @($passes[0]); $o.status = 'EXCEEDED'; $o.boardComplete = $false
    if ($Counter -eq 'selection') { $o.selection = [long]$Expected.selection + 1 }
    else {
      $o.passes[0].complete = $false; $o.passes[0][$Counter] = [long]$Expected[$Counter] + 1
      if ($Counter -eq 'parse') { $o.passes[0].linkage = 0 }
    }
    $o.first = @{ counter = $Counter; attempted = [long]$Expected[$Counter] + 1; limit = $Expected[$Counter]; pass = 1 }
  }
  return $o
}
function New-CheckFixture([string]$Name) {
  $path = Join-Path $root $Name
  [void][IO.Directory]::CreateDirectory($path)
  $f = @{ root = $path; log = (Join-Path $path 'dispatch.jsonl'); gh = (Join-Path $path 'gh.ps1') }
  $lines = @()
  foreach ($owner in @(1,2)) {
    $label = "synthetic-scale-$owner"
    $row = @{ ts = '2026-01-01T00:00:00Z'; kind = 'dispatch'; issue = $(if ($owner -eq 1) { 8548 } else { 100002 })
      lane = $label; laneRole = 'implementation'; transcript = "$label.jsonl"; attemptId = $label }
    $lines += $row | ConvertTo-Json -Compress
    Write-ScaleJson (Join-Path $path "watchdog-lane-$label.json") @{
      schemaVersion = 'watchdog-lane/v2'; label = $label; attemptId = $label; laneRole = 'implementation'
      worktree = (Join-Path $path $label); state = 'exited'; launchId = '11111111-1111-1111-1111-111111111111'
      childPid = 12345; childStartIdentity = 'synthetic-live'
    }
  }
  $row.issue = 8548; $row.lane = 'synthetic-scale-1'; $row.transcript = 'synthetic-scale-1.jsonl'
  $row.attemptId = 'synthetic-scale-1'; $row.kind = 'landed'
  $lines += $row | ConvertTo-Json -Compress
  [IO.File]::WriteAllLines($f.log, $lines)
  $item = New-BoardItem 8548 'In lane'
  Write-ScaleJson (Join-Path $path 'item-8548.json') $item
  Write-ScaleJson (Join-Path $path 'page-0.json') @{ data = @{ node = @{ items = @{ nodes = @($item); pageInfo = @{ hasNextPage = $false } } } } }
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures/board-scale-gh.ps1') -Destination $f.gh
  [IO.File]::WriteAllText((Join-Path $path 'stub-trace'), '')
  return $f
}
function Invoke-CheckWork($Fixture, [string]$Arm, $Expected) {
  $runtime = New-BoardScaleRuntime $Fixture $Arm
  . (Join-Path $runtime 'count-probes.ps1')
  New-ScaleObservation $Expected
  $env:BOARD_SCALE_COUNTS = Join-Path $Fixture.root 'work-counts.json'
  try {
    Invoke-ScaleWait board 0
    . (Join-Path $runtime 'board-reconcile.ps1') -FunctionsOnly
    $history = Get-BoardHistory $Fixture.log
    for ($i = 0; $i -lt 2; $i++) { $null = Get-BoardProjection ([pscustomobject](New-BoardItem 8548)) $history }
    Complete-ScaleBoard
    $global:BoardScale.status = 'PASS'
  } catch {
    if ($_.Exception.Message -like '*SYNTHETIC_SCALE_EXCEEDED*' -and $global:BoardScale.first) { $global:BoardScale.status = 'EXCEEDED' } else { throw }
  } finally { Write-ScaleObservation }
  return Copy-CheckValue $global:BoardScale
}
function Invoke-CheckEvent([string]$Name, [int]$Delay, [int]$BoardWait = 0) {
  $f = New-CheckFixture $Name
  $runtime = New-BoardScaleRuntime $f
  if ($BoardWait) {
    $wrapper = Join-Path $runtime 'board-wrapper.ps1'
    $text = [IO.File]::ReadAllText($wrapper)
    [IO.File]::WriteAllText($wrapper, (Replace-ScaleAnchor $text 'Invoke-ScaleWait board 0' "Invoke-ScaleWait board $BoardWait"))
  }
  . (Join-Path $runtime 'count-probes.ps1')
  New-ScaleObservation $script:eventExpected
  $env:BOARD_SCALE_COUNTS = Join-Path $f.root 'work-counts.json'
  $env:BOARD_SCALE_CENSUS_DELAY = [string]$Delay
  $prefix = [IO.File]::ReadAllBytes($f.log)
  & (Join-Path $runtime 'board-wrapper.ps1') -Issue 8548 -EventKind landed -LaneRole implementation -Pr 908548
  & (Join-Path $runtime 'census.ps1') -RuntimeRoot $f.root
  $global:BoardScale.status = 'PASS'
  Write-ScaleObservation
  $after = [IO.File]::ReadAllBytes($f.log)
  Assert-Board ([Linq.Enumerable]::SequenceEqual($prefix, $after)) 'tiny wrapper durable unchanged ledger'
  Assert-Board ((Get-Content (Join-Path $f.root 'append-trace')).Count -eq 1) 'tiny wrapper append-before-board observed'
  $result = Get-Content (Join-Path $f.root 'board-result.json') -Raw | ConvertFrom-Json -AsHashtable
  Assert-Board ($result.ok -and $result.action -ceq 'clear') 'tiny wrapper actual event write'
  return @{ counts = (Copy-CheckValue $global:BoardScale); result = $result }
}
function Invoke-CheckDriverControls {
  . (Join-Path $PSScriptRoot 'routing-data-test-support.ps1')
  $scope = Enter-RoutingDataTestScope
  $oldSync = $env:ORCH_BOARD_SYNC
  $oldSchedule = $env:BOARD_SCALE_SCHEDULE
  try {
    $env:ORCH_BOARD_SYNC = '1'
    $env:BOARD_SCALE_SCHEDULE = 'quiet'
    # Independent tiny N=2/R=2/S=2 arithmetic, with the delivered inert growth allowance.
    $inertGrowth = (Get-BoardScaleExpected 2400 'inert').parse - 24500
    function Get-BoardScaleExpected([int]$Items, [string]$Arm, [string]$Event = '') {
      # Event adds a third related row; each of its two selections visits all three.
      if ($Event) { return @{ parse = 4; linkage = 6; selection = 8; passes = 2; selected = 6 } }
      $writes = if ($Arm -eq 'inert') { 0 } else { 1 }
      return @{ parse = 2 + $(if ($Arm -eq 'inert') { $inertGrowth } else { 0 })
        linkage = 4; selection = 2 * (1 + 2 * $writes); passes = 1 + 2 * $writes; selected = 1 + 2 * $writes }
    }
    $f = New-CheckFixture 'driver-hourly'
    $lines = [IO.File]::ReadAllLines($f.log)[0..1]
    [IO.File]::WriteAllLines($f.log, $lines)
    $f.identity = @{ synthetic = $true; items = 1; openExecutable = 1 }
    $reason = $null
    try { Invoke-BoardScaleArm $f 'candidate' | Out-Null } catch { $reason = $_.Exception.Message }
    # One tiny write has three passes, not the untouched suite's twenty-one-pass floor.
    Assert-Board ($reason -like '*ASSERTION FAILED: all complete freshness passes*') 'tiny candidate reaches full-scale-only functional floor'
    $candidate = Get-Content -LiteralPath $env:BOARD_SCALE_COUNTS -Raw | ConvertFrom-Json -AsHashtable
    Assert-Board ($candidate.status -ceq 'PASS' -and $candidate.passes.Count -eq 3 -and -not $candidate.first) 'tiny driver candidate complete counts'
    $after = [IO.File]::ReadAllLines($f.log)
    Assert-Board ($after.Count -eq 3 -and ($after[-1] | ConvertFrom-Json).kind -ceq 'gc') 'tiny candidate appends one gc telemetry row'
    $report.driverVectors = @{ candidate = $candidate; candidateFunctionalFloor = $reason }
    Invoke-BoardScaleArm $f 'inert' | Out-Null
    $inert = Get-Content -LiteralPath $env:BOARD_SCALE_COUNTS -Raw | ConvertFrom-Json -AsHashtable
    Assert-Board ($inert.status -ceq 'PASS' -and $inert.passes.Count -eq 1 -and $inert.passes[0].parse -eq 3 -and -not $inert.first) 'tiny candidate then inert parses N plus one'
    $report.driverVectors.inert = $inert

    # Reproduce the original fixed-N defect with only the new pre-launch guard bypassed.
    $invokeSource = Get-CheckFunction $support 'Invoke-BoardScaleArm'
    $fixedNSource = Replace-ScaleAnchor $invokeSource 'if ($referenceRows -ne $referenceExpected)' 'if ($false)'
    # Pin the extracted function's source root, not the escaped child-driver variable.
    $fixedNSource = [regex]::Replace($fixedNSource, '(?<!`)\$PSScriptRoot', [Text.RegularExpressions.MatchEvaluator]{
      param($match) "'$($PSScriptRoot.Replace("'", "''"))'"
    })
    $fixedN = & {
      . ([scriptblock]::Create($fixedNSource))
      $inertGrowth = 0
      $reason = $null
      try { Invoke-BoardScaleArm $f 'inert' | Out-Null } catch { $reason = $_.Exception.Message }
      $report.driverVectors.fixedNReason = $reason
      Assert-Board ($reason -like '*ASSERTION FAILED: algorithmic control discrimination*') 'fixed N driver discrimination is red'
      Get-Content -LiteralPath $env:BOARD_SCALE_COUNTS -Raw | ConvertFrom-Json -AsHashtable
    }
    Assert-Board ($fixedN.status -ceq 'EXCEEDED' -and $fixedN.first.counter -ceq 'parse' -and $fixedN.first.attempted -eq 3 -and $fixedN.first.limit -eq 2) 'fixed N driver exceeds at N plus one'
    $report.driverVectors.fixedN = $fixedN
    $report.controls += @{ name = 'fixed-N-after-candidate'; rejected = $true; reason = $fixedN.first; oneVariableBypass = 'PASS: inert parse allowance N+1' }
    foreach ($delta in @(-1,1)) {
      $drift = New-CheckFixture "driver-drift-$delta"
      $drift.identity = @{ synthetic = $true; items = 1; openExecutable = 1 }
      $base = [IO.File]::ReadAllLines($drift.log)
      $drifted = if ($delta -eq -1) { @($base[0]) } else { @($base[0],$base[1],$base[0]) }
      [IO.File]::WriteAllLines($drift.log, $drifted)
      $reason = $null
      try { Invoke-BoardScaleArm $drift 'candidate' | Out-Null } catch { $reason = $_.Exception.Message }
      Assert-Board ($reason -like 'scale reference row anchor refused:*') 'ledger drift is a pre-launch refusal'
      Assert-Board (-not (Test-Path (Join-Path $drift.root 'runtime/invoke.ps1')) -and -not (Test-Path (Join-Path $drift.root 'work-counts.json'))) 'ledger drift never launches driver or classifies work'
      $report.controls += @{ name = "reference-row-drift-$delta"; rejected = $true; reason = $reason; oneVariableBypass = 'PENDING' }
      # Restore only the row count, retaining the same fixture, source and expectations.
      [IO.File]::WriteAllLines($drift.log, $base[0..1])
      $reason = $null
      try { Invoke-BoardScaleArm $drift 'candidate' | Out-Null } catch { $reason = $_.Exception.Message }
      Assert-Board ($reason -like '*ASSERTION FAILED: all complete freshness passes*') 'restored ledger reaches tiny functional floor'
      $restored = Get-Content -LiteralPath $env:BOARD_SCALE_COUNTS -Raw | ConvertFrom-Json -AsHashtable
      Assert-Board ($restored.status -ceq 'PASS' -and $restored.passes.Count -eq 3) 'restored row anchor executes complete counts'
      $report.controls[-1].oneVariableBypass = 'PASS'
    }
    $eventFixture = New-CheckFixture 'driver-event'
    $eventFixture.identity = @{ synthetic = $true; items = 1; openExecutable = 1 }
    Invoke-BoardScaleArm $eventFixture 'candidate' 'landed' 2000 | Out-Null
    $eventCounts = Get-Content -LiteralPath $env:BOARD_SCALE_COUNTS -Raw | ConvertFrom-Json -AsHashtable
    Assert-Board ($eventCounts.status -ceq 'PASS' -and $eventCounts.passes.Count -eq 2 -and $eventCounts.passes[0].parse -eq 4) 'tiny event executes generated driver and logger'
    $report.driverVectors.event = $eventCounts
  } finally {
    $env:ORCH_BOARD_SYNC = $oldSync
    $env:BOARD_SCALE_SCHEDULE = $oldSchedule
    Exit-RoutingDataTestScope $scope
  }
}
try {
  $support = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'board-scale-test-support.ps1')).Replace("`r`n", "`n")
  Invoke-CheckDriverControls
  $B = '24a00072a5d10b93c290d805d900920e3a2aa84a'
  $baseline = (& git -C $PSScriptRoot cat-file blob cf9bb1ec621c6ebae1497a13b0e30b71f1408c8c) -join "`n"
  Assert-Board ($LASTEXITCODE -eq 0) 'immutable B support available'
  $baselineHourly = (& git -C $PSScriptRoot cat-file blob 4eedaa85619279fa8b30595045acf95a6137e802) -join "`n"
  Assert-Board ($LASTEXITCODE -eq 0) 'immutable B hourly available'
  foreach ($binding in @(@('board-scale-test-support.ps1','cf9bb1ec621c6ebae1497a13b0e30b71f1408c8c'), @('board-hourly-scale.test.ps1','4eedaa85619279fa8b30595045acf95a6137e802'))) {
    Assert-Board ((& git -C $PSScriptRoot rev-parse "$($B):.orchestrator/$($binding[0])") -ceq $binding[1]) 'B blob provenance'
  }
  $oracle = 'fixtures/board-history-v289.ps1'
  Assert-Board ((& git -C $PSScriptRoot hash-object (Join-Path $PSScriptRoot $oracle)) -ceq (& git -C $PSScriptRoot rev-parse "$($B):.orchestrator/$oracle")) 'independent immutable algorithm oracle'
  $script:baselineAssertions = @(Get-CheckAssertions $baseline)
  $script:replacedMessages = @(
    "'linkage mutant anchor'", "'reference complete parse/inventory'",
    '"$Arm/$Event full-path evidence failed: $evidence/$name.json"',
    "'census is outside board clock'", "'census-only slowdown actually executed'"
  )
  Assert-FunctionalInventory $support
  $report.assertionMap = @($baselineAssertions | ForEach-Object {
    $entry = $_
    @{ message = $entry.message; baseline = $entry.source
      candidate = @((Get-CheckAssertions $support) | Where-Object message -CEQ $entry.message | ForEach-Object source)
      disposition = $(if ($entry.message -in $replacedMessages) { 'replaced by anchor/count/wait proof' } else { 'retained, JSON path trace adapted' }) }
  })
  foreach ($name in @('board-hourly-scale.test.ps1','board-history-scale.test.ps1')) {
    $current = [IO.File]::ReadAllText((Join-Path $PSScriptRoot $name)).Replace("`r`n", "`n").TrimEnd()
    $bSource = ((& git -C $PSScriptRoot show "$($B):.orchestrator/$name") -join "`n").TrimEnd()
    Assert-Board ($current -ceq $bSource) 'B complete caller inventory unchanged'
  }
  $report.callerInventory = @{ hourly = @('candidate/2400','inert/2400','baseline/2400','issue-scan/2400','no-linkage/2400','candidate/10','ten-item-scan/10')
    events = @('dispatch','lane-complete','review-complete','landed','landed-slow'); armSelectors = 5; eventSelectors = 5; unchangedFromB = $true }
  Assert-Board ($baselineHourly.Contains("'ten-item-scan'")) 'B tiny scan positive retained'
  Assert-Board ($support -notmatch 'BOARD_SCALE_DEADLINE|Test-ScaleBudget|budgetSeconds|timingVerdict|censusSeconds|cooperativeDeadline|headroomReference|Measure-BoardReference') 'superseded clock and dormant CPU path removed'
  $report.functions = @((Read-CheckAst $support).FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false) | ForEach-Object { @{ name = $_.Name; line = $_.Extent.StartLineNumber } })

  $expected = Get-BoardScaleExpected 2400 'candidate'
  Assert-Board ($expected.parse -eq 24500 -and $expected.linkage -eq 23415 -and $expected.selection -eq 600000 -and $expected.passes -eq 21) 'independent hourly constants'
  $inertExpected = Get-BoardScaleExpected 2400 'inert'
  Assert-Board ($inertExpected.parse -eq 24501 -and $inertExpected.linkage -eq 23415 -and $inertExpected.selection -eq 200000 -and $inertExpected.passes -eq 1 -and $inertExpected.selected -eq 10) 'inert gc growth and zero-write bound'
  $e = Get-BoardScaleExpected 2400 'candidate' 'landed'
  Assert-Board ($e.parse -eq 24501 -and $e.linkage -eq 23416 -and $e.selection -eq 40002 -and $e.passes -eq 2) 'independent event constants'
  $pass = New-CheckObservation $expected
  Assert-Board ((Get-BoardScaleDecision $pass $expected) -ceq 'PASS') 'complete replay'
  foreach ($counter in @('parse','linkage','selection')) {
    $exceeded = New-CheckObservation $expected $counter
    Assert-Board ((Get-BoardScaleDecision $exceeded $expected) -ceq 'EXCEEDED') 'pure count excess accepted with partial trace'
    $invalid = Copy-CheckValue $exceeded; $invalid.first.attempted = 'invalid'
    Assert-Refuses "invalid first $counter" { Get-BoardScaleDecision $invalid $expected } { Get-BoardScaleDecision $exceeded $expected }
  }
  foreach ($counter in @('parse','linkage','selection')) {
    . ([scriptblock]::Create((Get-BoardScaleProbeSource)))
    $limits = @{ parse = 2; linkage = 2; selection = 2; passes = 1; selected = 2 }
    New-ScaleObservation $limits
    $env:BOARD_SCALE_COUNTS = Join-Path $root "boundary-$counter.json"
    Start-ScaleHistory 'boundary'
    Add-ScaleWork $counter
    Assert-Board (-not $global:BoardScale.first) "$counter limit minus one"
    Add-ScaleWork $counter
    Assert-Board (-not $global:BoardScale.first) "$counter exact limit"
    $beforeThird = Copy-CheckValue $global:BoardScale
    Assert-Refuses "$counter limit plus one" { Add-ScaleWork $counter } {
      $global:BoardScale = Copy-CheckValue $beforeThird
      $global:BoardScale.limits[$counter] = 3
      Add-ScaleWork $counter
      Assert-Board (-not $global:BoardScale.first) 'only the count allowance changed'
    }
    $persisted = Get-Content $env:BOARD_SCALE_COUNTS -Raw | ConvertFrom-Json -AsHashtable
    Assert-Board ($persisted.first.attempted -eq 3 -and -not $persisted.passes[0].complete) 'partial trace durable before throw'
    $report.boundaryTraces += $persisted
  }
  foreach ($counter in @('parse','linkage')) {
    $bad = Copy-CheckValue $pass; $bad.passes[0][$counter]--
    Assert-Refuses "dropped $counter" { Get-BoardScaleDecision $bad $expected } { Get-BoardScaleDecision $pass $expected }
    $bad = Copy-CheckValue $pass; $bad.passes[0].Remove($counter)
    Assert-Refuses "missing $counter" { Get-BoardScaleDecision $bad $expected } { Get-BoardScaleDecision $pass $expected }
  }
  foreach ($value in @(-1,1.5,'30',$null,$true)) {
    $bad = Copy-CheckValue $pass; $bad.selection = $value
    Assert-Refuses "invalid count [$value]" { Get-BoardScaleDecision $bad $expected } { Get-BoardScaleDecision $pass $expected }
  }
  $bad = Copy-CheckValue $pass; $bad.passes += $bad.passes[-1]
  Assert-Refuses 'duplicate pass' { Get-BoardScaleDecision $bad $expected } { Get-BoardScaleDecision $pass $expected }
  $bad = Copy-CheckValue $pass; $bad.passes = @($bad.passes[0])
  Assert-Refuses 'truncated passes' { Get-BoardScaleDecision $bad $expected } { Get-BoardScaleDecision $pass $expected }
  Assert-Refuses 'child error is not censor' { Get-BoardScaleDecision $pass $expected 1 } { Get-BoardScaleDecision $pass $expected 0 }
  Assert-Refuses 'missing observation' { Get-BoardScaleDecision $null $expected } { Get-BoardScaleDecision $pass $expected }
  Assert-Refuses 'failed instrumentation anchor' { Replace-ScaleAnchor 'different' 'required' 'replacement' } { Replace-ScaleAnchor 'required' 'required' 'replacement' }

  $probe = Get-BoardScaleProbeSource
  $probeCheck = {
    . ([scriptblock]::Create((Get-BoardScaleProbeSource)))
    New-ScaleObservation @{ parse = 1; linkage = 1; selection = 1 }
    Start-ScaleHistory 'mutation'
    Add-ScaleWork parse
    $caught = $false
    try { Add-ScaleWork parse } catch { $caught = $_.Exception.Message -like '*SYNTHETIC_SCALE_EXCEEDED*' }
    Assert-Board ($caught -and $global:BoardScale.passes[0].parse -eq 2) 'increment/check before work'
  }
  foreach ($mutation in @(
    @('drop-increment','$target[$Counter]++',''),
    @('ignore-limit','if ($target[$Counter] -gt $global:BoardScale.limits[$Counter])','if ($false)'),
    @('bad-count','$target[$Counter]++','$target[$Counter] = -1')
  )) {
    $mutant = Replace-ScaleAnchor $probe $mutation[1] $mutation[2]
    $definition = "function Get-BoardScaleProbeSource { return @'`n$mutant`n'@`n}"
    Assert-Killed $mutation[0] $definition $probeCheck
  }
  . ([scriptblock]::Create((Get-BoardScaleProbeSource)))
  New-ScaleObservation @{ parse = 1; linkage = 1; selection = 1 }
  Start-Sleep 1
  Start-Sleep -Milliseconds 1
  Start-Sleep -Seconds 0.002
  Assert-Board (($global:BoardScale.waits.requested -join ',') -ceq '1000,1,2') 'virtual sleep positional seconds and named units'
  $report.virtualSleepBinding = Copy-CheckValue $global:BoardScale.waits
  $script:smallExpected = @{ parse = 3; linkage = 5; selection = 5; passes = 1; selected = 4 }
  foreach ($schedule in @('quiet','yield')) {
    $env:BOARD_SCALE_SCHEDULE = $schedule
    foreach ($arm in @('candidate','baseline','no-linkage','issue-scan','ten-item-scan')) {
      $f = New-CheckFixture "work-$schedule-$arm"
      $x = Copy-CheckValue $smallExpected
      if ($arm -eq 'ten-item-scan') { $x.selection = 6; $x.selected = 6 }
      $o = Invoke-CheckWork $f $arm $x
      $report.actualVectors += @{ schedule = $schedule; arm = $arm; decision = 'PENDING'; counts = $o }
      $decision = Get-BoardScaleDecision $o $x
      Assert-BoardScaleArmDecision $arm $decision $o
      $report.actualVectors[-1].decision = $decision
      Assert-Board (($schedule -ceq 'quiet' -and $o.yieldRequests -eq 0) -or ($schedule -ceq 'yield' -and $o.yieldRequests -gt 0)) 'fixed scheduling perturbation exercised'
    }
  }
  for ($i = 0; $i -lt 5; $i++) {
    $quiet = $report.actualVectors[$i]; $yielded = $report.actualVectors[$i + 5]
    Assert-Board ($quiet.arm -ceq $yielded.arm -and $quiet.decision -ceq $yielded.decision) 'actual scheduled classification equality'
    Assert-Board ($quiet.counts.selection -eq $yielded.counts.selection) 'actual scheduled selection equality'
    for ($j = 0; $j -lt $quiet.counts.passes.Count; $j++) {
      foreach ($key in @('parse','linkage','complete')) { Assert-Board ($quiet.counts.passes[$j][$key] -eq $yielded.counts.passes[$j][$key]) 'actual scheduled pass equality' }
    }
  }
  $f = New-CheckFixture 'swallow'
  $runtime = New-BoardScaleRuntime $f
  $source = [IO.File]::ReadAllText((Join-Path $runtime 'board-reconcile.ps1'))
  $history = Get-CheckFunction $source 'Get-BoardHistory'
  . ([scriptblock]::Create($history))
  $censorCheck = {
    . ([scriptblock]::Create((Get-BoardScaleProbeSource)))
    New-ScaleObservation @{ parse = 1; linkage = 5; selection = 5 }
    Invoke-ScaleWait board 0
    $caught = $false
    try { $null = Get-BoardHistory $f.log } catch { $caught = $_.Exception.Message -like '*SYNTHETIC_SCALE_EXCEEDED*' }
    Assert-Board $caught 'parser/projection catch propagates censor'
  }
  Assert-Killed 'swallow-censor' ($history.Replace("if (`$_.Exception.Message -like '*SYNTHETIC_SCALE_EXCEEDED*') { throw };", '')) $censorCheck

  # Force a selection censor specifically inside hourly's pre-write catch.
  . (Join-Path $runtime 'count-probes.ps1')
  $lateLimits = @{ parse = 3; linkage = 5; selection = 2 }
  New-ScaleObservation $lateLimits
  $env:BOARD_SCALE_COUNTS = Join-Path $f.root 'late-censor.json'
  Assert-Refuses 'hourly projection catch censor' {
    & (Join-Path $runtime 'board-reconcile.ps1') -Apply -DispatchLog $f.log -GhCommand $f.gh
  } {
    New-ScaleObservation $lateLimits
    & (Join-Path $runtime 'board-reconcile.ps1') -Apply:$false -DispatchLog $f.log -GhCommand $f.gh
  }

  $script:eventExpected = @{ parse = 3; linkage = 5; selection = 6; passes = 2; selected = 4 }
  $ordinary = Invoke-CheckEvent 'ordinary' 0
  $slow = Invoke-CheckEvent 'slow' 2000
  Assert-Board ((Get-BoardScaleDecision $ordinary.counts $eventExpected 0 0) -ceq 'PASS') 'ordinary virtual event'
  Assert-Board ((Get-BoardScaleDecision $slow.counts $eventExpected 0 2000) -ceq 'PASS') 'slow census excluded from board verdict'
  foreach ($key in @('selection','status','boardComplete')) { Assert-Board ($ordinary.counts[$key] -ceq $slow.counts[$key]) 'ordinary/slow board vectors equal' }
  for ($i = 0; $i -lt 2; $i++) {
    foreach ($key in @('parse','linkage','complete')) { Assert-Board ($ordinary.counts.passes[$i][$key] -eq $slow.counts.passes[$i][$key]) 'ordinary/slow pass vectors equal' }
  }
  Assert-Board (($ordinary.result | ConvertTo-Json -Compress) -ceq ($slow.result | ConvertTo-Json -Compress)) 'ordinary/slow output equal'
  $boardWait = Invoke-CheckEvent 'board-wait' 0 1
  Assert-Board (($ordinary.result | ConvertTo-Json -Compress) -ceq ($boardWait.result | ConvertTo-Json -Compress)) '+1 board wait identical output'
  Assert-Refuses '+1 board-wait' { Get-BoardScaleDecision $boardWait.counts $eventExpected 0 0 } {
    $bypass = Copy-CheckValue $boardWait.counts; $bypass.waits[0].requested = 0; $bypass.waits[0].executed = 0
    Get-BoardScaleDecision $bypass $eventExpected 0 0
  }
  $report.waitVectors = @{ ordinary = $ordinary; slow = $slow; boardWait = $boardWait }
  $decisionSource = Get-CheckFunction $support 'Get-BoardScaleDecision'
  Assert-Killed 'ignore-board-wait' (Replace-ScaleAnchor $decisionSource 'if ($wait.executed -ne 0)' 'if ($false)') {
    $caught = $false
    try { Get-BoardScaleDecision $boardWait.counts $eventExpected 0 0 | Out-Null } catch { $caught = $true }
    Assert-Board $caught 'board wait must reject'
  }
  Assert-Killed 'include-census' (Replace-ScaleAnchor $decisionSource '$census += $wait.executed' '$census += $wait.executed; if ($wait.executed -gt 0) { throw ''census charged to board'' }') {
    Assert-Board ((Get-BoardScaleDecision $slow.counts $eventExpected 0 2000) -ceq 'PASS') 'census must remain outside board'
  }
  $missingWait = Copy-CheckValue $pass; $missingWait.waits = @()
  Assert-Refuses 'missing-wait' { Get-BoardScaleDecision $missingWait $expected } { Get-BoardScaleDecision $pass $expected }
  Assert-Killed 'ignore-missing-wait' (Replace-ScaleAnchor $decisionSource 'if ($board -eq 0)' 'if ($false)') {
    $caught = $false
    try { Get-BoardScaleDecision $missingWait $expected | Out-Null } catch { $caught = $true }
    Assert-Board $caught 'missing waits must reject'
  }
  $wrongOrder = Copy-CheckValue $slow.counts; $wrongOrder.waits[-1].afterBoard = $false
  Assert-Refuses 'census-before-board' { Get-BoardScaleDecision $wrongOrder $eventExpected 0 2000 } { Get-BoardScaleDecision $slow.counts $eventExpected 0 2000 }

  $assertion = @($baselineAssertions | Where-Object message -CEQ "'cap writes/inert convergence'")[0].source
  $dropped = Replace-ScaleAnchor $support $assertion ''
  Assert-Refuses 'drop-assertion' { Assert-FunctionalInventory $dropped } { Assert-FunctionalInventory $support }
  $missingCounter = Copy-CheckValue $pass; $missingCounter.Remove('selection')
  Assert-Refuses 'missing-counter' { Get-BoardScaleDecision $missingCounter $expected } { Get-BoardScaleDecision $pass $expected }
  $armDecision = Get-CheckFunction $support 'Assert-BoardScaleArmDecision'
  Assert-Killed 'swapped-tiny-discriminator' (Replace-ScaleAnchor $armDecision "@('baseline','issue-scan','no-linkage')" "@('baseline','issue-scan','no-linkage','ten-item-scan')") {
    Assert-BoardScaleArmDecision 'ten-item-scan' 'PASS' $pass
  }

  $replayCheck = {
    # S1 clocks and a 100-wall/40-CPU trace have identical work but opposite
    # old wall verdicts. They are replays, not new hosted measurements.
    $left = New-CheckObservation $expected; $right = Copy-CheckValue $left
    $left.elapsedSeconds = 191.2307462; $left.cpuSeconds = 6.71875
    $right.elapsedSeconds = 100; $right.cpuSeconds = 40
    Assert-Board ((Get-BoardScaleDecision $left $expected) -ceq (Get-BoardScaleDecision $right $expected)) 'opposite-clock replay count equality'
  }
  & $replayCheck
  Assert-Killed 'clock-leak' (Replace-ScaleAnchor $decisionSource "  return 'PASS'" "  if (`$Observation.elapsedSeconds -gt 166.08014616) { throw 'clock leak' }; return 'PASS'") $replayCheck
  for ($rep = 1; $rep -le 3; $rep++) {
    $oldBudget = 1.4 * 21 * [Math]::Max(4.6285764,3.0873425) + 30
    Assert-Board (191.2307462 -gt $oldBudget -and 100 -lt $oldBudget) 'old wall equality control red'
    foreach ($revision in @('B','candidate')) {
      foreach ($shape in @('aggregate','standalone')) {
        foreach ($perturbation in @('quiet','yield')) {
          $cases = @()
          foreach ($case in @('candidate','inert','baseline','issue-scan','no-linkage','tiny','tiny-scan','dispatch','lane-complete','review-complete','landed','landed-slow')) {
            $arm = switch ($case) { 'tiny' { 'candidate' }; 'tiny-scan' { 'ten-item-scan' }; default { $case } }
            $event = if ($case -in @('dispatch','lane-complete','review-complete','landed','landed-slow')) { 'landed' } else { '' }
            $items = if ($case -like 'tiny*') { 10 } else { 2400 }
            $x = Get-BoardScaleExpected $items $arm $event
            $counter = if ($arm -in @('baseline','no-linkage')) { 'linkage' } elseif ($arm -eq 'issue-scan') { 'selection' } else { '' }
            $o = New-CheckObservation $x $counter
            $delay = -1
            if ($case -in @('landed','landed-slow')) {
              $delay = if ($case -eq 'landed-slow') { 2000 } else { 0 }
              $o.waits += @{ ordinal = 2; phase = 'census'; requested = $delay; executed = $delay; afterBoard = $true }
            }
            $o.elapsedSeconds = if ($perturbation -eq 'yield') { 191.2307462 } else { 100 }
            $o.cpuSeconds = if ($perturbation -eq 'yield') { 6.71875 } else { 40 }
            $decision = Get-BoardScaleDecision $o $x 0 $delay
            Assert-Board ($decision -ceq $(if ($counter) { 'EXCEEDED' } else { 'PASS' })) 'replay case classification'
            $cases += @{ case = $case; expected = $x; decision = $decision; counts = $o }
          }
          $report.replayMatrix += @{ repetition = $rep; revision = $revision; shape = $shape; perturbation = $perturbation
            kind = 'synthetic replay, not host sample'; cases = $cases; oldWallEquality = 'FAIL (expected)' }
        }
      }
    }
  }
  Assert-Board ($report.replayMatrix.Count -eq 24) '24 replay cells retained'
  $report.hostProof = 'NOT_EXECUTED: host owns exact-head full-path 24-sample matrix and baseline-aware governing battery'
  $report.verdict = 'PASS'
} catch {
  $report.error = $_.Exception.Message
  throw
} finally {
  $env:BOARD_SCALE_COUNTS = $oldCounts; $env:BOARD_SCALE_CENSUS_DELAY = $oldDelay; $env:BOARD_SCALE_SCHEDULE = $oldSchedule
  [IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 40))
  Remove-BoardScaleFixture $root
}
Write-Output "PASS board-scale-determinism evidence=$reportPath"
