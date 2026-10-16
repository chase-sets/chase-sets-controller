# Synthetic full-path fixtures. No live board, history, ownership, or registry.
$script:BoardReferenceHead = 'f292db3c0c89aba867b7ae10da6fffd0fc2970ee'
. (Join-Path $PSScriptRoot 'board-reconcile.test.ps1') -FunctionsOnly
function Write-ScaleJson([string]$Path, $Value) {
  [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Value -Compress -Depth 30))
}
function New-BoardScaleFixture([string]$Root, [int]$ItemCount = 2400) {
  [void][IO.Directory]::CreateDirectory($Root)
  $f = @{ root = $Root; log = (Join-Path $Root 'dispatch.jsonl'); gh = (Join-Path $Root 'gh.ps1') }
  $stream = [IO.StreamWriter]::new($f.log, $false, [Text.UTF8Encoding]::new($false))
  try {
    for ($i = 1; $i -le 24500; $i++) {
      $owner = if ($i -le 3415) { $i } else { 11 + (($i - 3416) % 3405) }
      $label = "synthetic-scale-$owner"
      $issue = if ($owner -le 10) { 8547 + $owner } else { 100000 + $owner }
      if ($owner -eq 5 -and $ItemCount -ge 1310) { $issue = 8547 + 1310 }
      $kind = if ($i -le 3415) { 'dispatch' } elseif ($i -le 20000) { 'lane-complete' } else { 'verify-complete' }
      $role = if ($owner % 2) { 'implementation' } else { 'review' }
      $row = [ordered]@{ ts = '2026-01-01T00:00:00Z'; kind = $kind; issue = $issue; lane = $label
        laneRole = $role; transcript = "$label.jsonl"; attemptId = $label; harness = 'codex'
        model = 'gpt-6-astra'; effort = 'high'; row = 7; placement = 'override-Todd'
        authorModel = 'gpt-6-astra'; authorEffort = 'high'; outcome = 'SYNTHETIC_OBSERVATION'
        controllerHead = $script:BoardReferenceHead; pr = 900000 + $owner
        note = "Synthetic lifecycle observation $i for retained execution $label; no external issue or provider assertion."
        classes = @('synthetic-full-history','synthetic-attribution','synthetic-order-preservation')
        provenance = @{ source = 'board-scale-test-support'; synthetic = $true; sequence = $i
          worktree = "synthetic/worktrees/$label"; branch = "synthetic/board-scale/$owner"
          observation = "synthetic-observation-$i"; fixture = 'board-history-scale/v1' } }
      $stream.WriteLine(($row | ConvertTo-Json -Compress -Depth 10))
      if ($i -le 3415) {
        $spec = @{ schemaVersion = 'watchdog-lane/v2'; label = $label; attemptId = $label; laneRole = $role
          worktree = (Join-Path $Root $label); state = $(if ($owner -le 5) { 'running' } else { 'exited' })
          launchId = '11111111-1111-1111-1111-111111111111'; childPid = 12345; childStartIdentity = 'synthetic-live'
          harness = 'codex'; model = 'gpt-6-astra'; effort = 'high'; row = 7; placement = 'override-Todd'
          head = $script:BoardReferenceHead; branch = "synthetic/board-scale/$owner"
          transcriptPath = (Join-Path $Root "$label.jsonl"); synthetic = $true }
        Write-ScaleJson (Join-Path $Root "watchdog-lane-$label.json") $spec
      }
    }
  } finally { $stream.Dispose() }
  $items = [Collections.Generic.List[object]]::new()
  for ($i = 1; $i -le $ItemCount; $i++) {
    $item = New-BoardItem (8547 + $i) 'Refined'
    if ($i -ge 6 -and $i -le 10) { $item.status.name = 'In lane' }
    if ($i -gt 1310) { $item.content.state = 'CLOSED' }
    $items.Add($item)
    Write-ScaleJson (Join-Path $Root "item-$($item.content.number).json") $item
  }
  for ($offset = 0; $offset -lt $ItemCount; $offset += 100) {
    $end = [Math]::Min($offset + 99, $ItemCount - 1)
    Write-ScaleJson (Join-Path $Root "page-$offset.json") @{ data = @{ node = @{ items = @{
      nodes = @($items[$offset..$end]); pageInfo = @{ hasNextPage = ($end + 1 -lt $ItemCount); endCursor = [string]($end + 1) }
    } } } }
  }
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures/board-scale-gh.ps1') -Destination $f.gh
  $specFiles = @(Get-ChildItem -LiteralPath $Root -Filter 'watchdog-lane-*.json' -File)
  $f.identity = @{ synthetic = $true; rows = 24500; retained = 20000; ledgerBytes = (Get-Item $f.log).Length
    specs = $specFiles.Count; specBytes = ($specFiles | Measure-Object Length -Sum).Sum
    items = $ItemCount; openExecutable = [Math]::Min(1310, $ItemCount); pageSize = 100
    ledgerSha256 = (Get-FileHash -LiteralPath $f.log -Algorithm SHA256).Hash.ToLowerInvariant() }
  Assert-Board ($f.identity.ledgerBytes -ge 15000000 -and $specFiles.Count -ge 3415) 'synthetic ledger/spec floors'
  return $f
}
function Get-BoardScaleExpected([int]$Items, [string]$Arm, [string]$Event = '') {
  $eventPath = -not [string]::IsNullOrEmpty($Event)
  # Hourly inert reads 24500 fixture rows plus the preceding candidate apply's one non-retained gc telemetry row.
  $rows = if ($eventPath -or $Arm -eq 'inert') { 24501 } else { 24500 }
  $retained = if ($eventPath) { 20001 } else { 20000 }
  $writes = if ($Arm -eq 'inert') { 0 } else { 10 }
  return @{
    parse = $rows; linkage = $retained + 3415
    selection = $(if ($eventPath) { 2 * $retained } else { $retained * ([Math]::Min($Items, 10) + 2 * $writes) })
    passes = $(if ($eventPath) { 2 } elseif ($Arm -eq 'inert') { 1 } else { 21 })
    # Independent fixture arithmetic: ten linked open owners, plus two fresh
    # reads per write. The tiny scan visits R for all thirty selections.
    selected = $(if ($eventPath) { 4 } elseif ($Arm -eq 'inert') { 10 } elseif ($Arm -eq 'ten-item-scan') { 600000 } else { 30 })
  }
}
function Get-BoardScaleProbeSource {
  return @'
function New-ScaleObservation($Limits) {
  $global:BoardScale = @{
    schema = 'board-scale-work/v1'; limits = $Limits; passes = @(); selection = 0L
    first = $null; status = 'RUNNING'; waits = @(); boardComplete = $false; yieldRequests = 0
  }
}
function Write-ScaleObservation {
  if ($env:BOARD_SCALE_COUNTS) {
    [IO.File]::WriteAllText($env:BOARD_SCALE_COUNTS, ($global:BoardScale | ConvertTo-Json -Depth 20))
  }
}
function Start-ScaleHistory([string]$Path) {
  if ($global:BoardScale.first) { throw 'SYNTHETIC_SCALE_EXCEEDED' }
  $global:BoardScale.passes += @{ ordinal = $global:BoardScale.passes.Count + 1; path = $Path; parse = 0L; linkage = 0L; complete = $false }
}
function Add-ScaleWork([ValidateSet('parse','linkage','selection')][string]$Counter) {
  if ($global:BoardScale.first) { throw 'SYNTHETIC_SCALE_EXCEEDED' }
  $pass = $global:BoardScale.passes[-1]
  $target = if ($Counter -eq 'selection') { $global:BoardScale } else { $pass }
  $target[$Counter]++
  # Fixed placement 1,98,195,...; scheduling telemetry never enters the verdict.
  if ($env:BOARD_SCALE_SCHEDULE -eq 'yield' -and ($target[$Counter] - 1) % 97 -eq 0) {
    $global:BoardScale.yieldRequests++
    [void][Threading.Thread]::Yield()
  }
  if ($target[$Counter] -gt $global:BoardScale.limits[$Counter]) {
    $global:BoardScale.first = @{ counter = $Counter; attempted = $target[$Counter]
      limit = $global:BoardScale.limits[$Counter]; pass = $pass.ordinal }
    Write-ScaleObservation
    throw 'SYNTHETIC_SCALE_EXCEEDED'
  }
}
function Complete-ScaleHistory {
  $global:BoardScale.passes[-1].complete = $true
}
function Invoke-ScaleWait([ValidateSet('board','census')][string]$Phase, [int]$Milliseconds) {
  # Virtual-only waits: executed records the modeled request, not an observed OS sleep.
  if ($Milliseconds -lt 0) { throw 'negative synthetic wait' }
  $global:BoardScale.waits += @{ ordinal = $global:BoardScale.waits.Count + 1
    phase = $Phase; requested = $Milliseconds; executed = $Milliseconds; afterBoard = $global:BoardScale.boardComplete }
}
function Complete-ScaleBoard {
  if ($global:BoardScale.boardComplete) { throw 'duplicate board completion' }
  $global:BoardScale.boardComplete = $true
}
function Start-Sleep {
  [CmdletBinding(PositionalBinding = $false)]
  param([int]$Milliseconds, [Parameter(Position = 0)][double]$Seconds)
  if ($PSBoundParameters.ContainsKey('Seconds')) {
    if ($Seconds * 1000 -ne [Math]::Truncate($Seconds * 1000)) { throw 'noninteger virtual milliseconds' }
    $Milliseconds = [int]($Seconds * 1000)
  }
  Invoke-ScaleWait $(if ($global:BoardScale.boardComplete) { 'census' } else { 'board' }) $Milliseconds
}
'@
}
function Test-ScaleInteger($Value) {
  return ($Value -is [int] -or $Value -is [long]) -and $Value -ge 0
}
function Get-BoardScaleDecision($Observation, $Expected, [int]$ExitCode = 0, [int]$CensusDelay = -1) {
  # Only work, requested/executed waits and execution completeness own a verdict.
  # Clock/CPU/load fields, even if supplied by a replay, are deliberately unread.
  if ($ExitCode -ne 0 -or -not $Observation -or $Observation.schema -cne 'board-scale-work/v1') { throw 'invalid scale observation/child exit' }
  foreach ($key in @('limits','passes','selection','first','status','waits','boardComplete')) {
    if (-not $Observation.Contains($key)) { throw "missing scale field $key" }
  }
  foreach ($key in @('parse','linkage','selection')) {
    if (-not (Test-ScaleInteger $Observation.limits[$key]) -or $Observation.limits[$key] -ne $Expected[$key]) { throw "invalid scale limit $key" }
  }
  if (-not (Test-ScaleInteger $Observation.selection) -or $Observation.status -notin @('PASS','EXCEEDED')) { throw 'invalid scale count/status' }
  if ($Observation.passes.Count -lt 1 -or $Observation.passes.Count -gt $Expected.passes) { throw 'missing/duplicate scale pass' }
  $ordinal = 0
  foreach ($pass in $Observation.passes) {
    $ordinal++
    if (-not (Test-ScaleInteger $pass.ordinal) -or $pass.ordinal -ne $ordinal -or -not $pass.path -or $pass.complete -isnot [bool]) { throw 'invalid scale pass trace' }
    foreach ($key in @('parse','linkage')) {
      if (-not (Test-ScaleInteger $pass[$key])) { throw "missing/invalid scale counter $key" }
      if ($pass.complete -and $pass[$key] -ne $Expected[$key]) { throw "incomplete scale counter $key" }
    }
    if (-not $pass.complete -and ($ordinal -ne $Observation.passes.Count -or -not $Observation.first)) { throw 'truncated scale pass' }
  }
  $ordinal = 0; $board = 0; $census = 0L; $censusCalls = 0
  foreach ($wait in $Observation.waits) {
    $ordinal++
    if (-not (Test-ScaleInteger $wait.ordinal) -or $wait.ordinal -ne $ordinal -or -not (Test-ScaleInteger $wait.requested) -or -not (Test-ScaleInteger $wait.executed) -or
        $wait.requested -ne $wait.executed -or $wait.afterBoard -isnot [bool]) { throw 'invalid wait observation' }
    if ($wait.phase -ceq 'board' -and -not $wait.afterBoard -and $censusCalls -eq 0) { $board++; if ($wait.executed -ne 0) { throw 'board wait allowance exceeded' } }
    elseif ($wait.phase -ceq 'census' -and $wait.afterBoard) { $censusCalls++; $census += $wait.executed }
    else { throw 'wait order invalid' }
  }
  if ($board -eq 0) { throw 'missing board wait observation' }
  if (-not $Observation.first -and (($CensusDelay -ge 0 -and ($censusCalls -ne 1 -or $census -ne $CensusDelay)) -or
      ($CensusDelay -lt 0 -and $censusCalls -ne 0))) { throw 'missing/invalid census wait observation' }
  if ($Observation.first) {
    $first = $Observation.first
    if ($first.counter -notin @('parse','linkage','selection') -or $Observation.status -cne 'EXCEEDED' -or
        -not (Test-ScaleInteger $first.pass) -or $first.pass -ne $Observation.passes.Count -or
        -not (Test-ScaleInteger $first.limit) -or -not (Test-ScaleInteger $first.attempted) -or
        $first.limit -ne $Expected[$first.counter] -or $first.attempted -ne $first.limit + 1) { throw 'invalid first over-limit attempt' }
    $actual = if ($first.counter -eq 'selection') { $Observation.selection } else { $Observation.passes[-1][$first.counter] }
    if ($actual -ne $first.attempted) { throw 'lost first over-limit counter' }
    if (($first.counter -eq 'linkage' -and $Observation.passes[-1].parse -ne $Expected.parse) -or
        ($first.counter -eq 'parse' -and $Observation.passes[-1].linkage -ne 0) -or
        ($first.counter -ne 'selection' -and $Observation.passes[-1].complete) -or
        ($first.counter -eq 'selection' -and -not $Observation.passes[-1].complete)) { throw 'invalid censor phase' }
    foreach ($pass in $Observation.passes) {
      foreach ($key in @('parse','linkage')) {
        if ($pass[$key] -gt $Expected[$key] -and -not ($pass.ordinal -eq $first.pass -and $key -ceq $first.counter)) { throw 'unexplained excess counter' }
      }
    }
    if ($Observation.selection -gt $Expected.selection -and $first.counter -cne 'selection') { throw 'unexplained selection excess' }
    return 'EXCEEDED'
  }
  if ($Observation.status -cne 'PASS' -or $Observation.passes.Count -ne $Expected.passes -or
      $Observation.selection -gt $Expected.selection -or $Observation.selection -ne $Expected.selected -or
      $Observation.boardComplete -isnot [bool] -or -not $Observation.boardComplete) { throw 'incomplete scale execution' }
  foreach ($pass in $Observation.passes) { if (-not $pass.complete) { throw 'incomplete scale pass' } }
  return 'PASS'
}
function Replace-ScaleAnchor([string]$Source, [string]$Anchor, [string]$Replacement, [int]$Count = 1) {
  $found = [regex]::Matches($Source, [regex]::Escape($Anchor)).Count
  Assert-Board ($found -eq $Count) "scale anchor expected $Count, found $($found): $Anchor"
  return $Source.Replace($Anchor, $Replacement)
}
function Update-ScaleFunction([string]$Source, [string]$Name, [scriptblock]$Transform) {
  $tokens = $null; $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseInput($Source, [ref]$tokens, [ref]$errors)
  Assert-Board ($errors.Count -eq 0) "parse disposable source $Name"
  $functions = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $Name }, $true))
  Assert-Board ($functions.Count -eq 1) "unique disposable function $Name"
  $old = $functions[0].Extent.Text
  return Replace-ScaleAnchor $Source $old (& $Transform $old)
}
function Protect-ScaleCatches([string]$Source) {
  # Fail-open production paths must not swallow our disposable count censor.
  return [regex]::Replace($Source, 'catch\s*\{', [Text.RegularExpressions.MatchEvaluator]{
    param($match)
    'catch { if ($_.Exception.Message -like ''*SYNTHETIC_SCALE_EXCEEDED*'') { throw };'
  })
}
function New-BoardScaleRuntime($Fixture, [string]$Arm = 'candidate') {
  $runtime = Join-Path $Fixture.root 'runtime'
  [void][IO.Directory]::CreateDirectory($runtime)
  $source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'board-reconcile.ps1')).Replace("`r`n", "`n")
  $oracle = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fixtures/board-history-v289.ps1')).Replace("`r`n", "`n")
  $tokens = $null; $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseInput($oracle, [ref]$tokens, [ref]$errors)
  Assert-Board ($errors.Count -eq 0) 'immutable history oracle parses'
  $oldHistory = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-BoardHistory' }, $false).Extent.Text
  $oldProjection = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-BoardProjection' }, $false).Extent.Text
  if ($Arm -eq 'baseline') {
    $source = Update-ScaleFunction $source 'Get-BoardHistory' { param($s) $oldHistory }
    $source = Update-ScaleFunction $source 'Get-BoardProjection' { param($s) $oldProjection }
  }
  if ($Arm -in @('issue-scan','ten-item-scan')) {
    $source = Replace-ScaleAnchor $source '$related = @(Get-BoardIssueRows $History.indexes $native.number)' '$related = @($History.rows | Where-Object { $_.issue -eq $native.number })'
  }
  if ($Arm -eq 'no-linkage') {
    $start = $oldHistory.IndexOf('  foreach ($label in $specs.Keys)')
    $end = $oldHistory.IndexOf('  return @{ rows')
    Assert-Board ($start -ge 0 -and $end -gt $start) 'legacy linkage loop anchors'
    $loop = $oldHistory.Substring($start, $end - $start)
    $old = '  $unlinkedSpecs = New-BoardUnlinkedSpecScope $specs $indexes'
    $source = Replace-ScaleAnchor $source $old ($loop + $old)
  }
  $source = Update-ScaleFunction $source 'Get-BoardHistory' {
    param($s)
    $s = Replace-ScaleAnchor $s 'function Get-BoardHistory([string]$Path) {' "function Get-BoardHistory([string]`$Path) {`n  Start-ScaleHistory `$Path"
    $s = Replace-ScaleAnchor $s '$row = $line | ConvertFrom-Json' 'Add-ScaleWork parse; $row = $line | ConvertFrom-Json'
    $s = Replace-ScaleAnchor $s '  return @{ rows =' "  Complete-ScaleHistory`n  return @{ rows ="
    if ($Arm -in @('baseline','no-linkage')) {
      $s = Replace-ScaleAnchor $s 'foreach ($label in $specs.Keys) {' 'foreach ($label in $specs.Keys) { Add-ScaleWork linkage;'
      $s = Replace-ScaleAnchor $s '$links = @($rows | Where-Object {' '$links = @($rows | Where-Object { Add-ScaleWork linkage;'
    }
    $s
  }
  if ($Arm -ne 'baseline') {
    $source = Update-ScaleFunction $source 'New-BoardHistoryIndexes' {
      param($s) Replace-ScaleAnchor $s 'foreach ($row in $Rows) {' 'foreach ($row in $Rows) { Add-ScaleWork linkage;'
    }
    $source = Update-ScaleFunction $source 'New-BoardUnlinkedSpecScope' {
      param($s) Replace-ScaleAnchor $s 'foreach ($label in $Specs.Keys) {' 'foreach ($label in $Specs.Keys) { Add-ScaleWork linkage;'
    }
  }
  if ($Arm -in @('baseline','issue-scan','ten-item-scan')) {
    $source = Update-ScaleFunction $source 'Get-BoardProjection' {
      param($s) Replace-ScaleAnchor $s '$related = @($History.rows | Where-Object { $_.issue -eq $native.number })' '$related = @($History.rows | Where-Object { Add-ScaleWork selection; $_.issue -eq $native.number })'
    }
  } else {
    $source = Update-ScaleFunction $source 'Get-BoardIssueRows' {
      param($s) Replace-ScaleAnchor $s 'foreach ($entry in $entries) {' 'foreach ($entry in $entries) { Add-ScaleWork selection;'
    }
  }
  [IO.File]::WriteAllText((Join-Path $runtime 'board-reconcile.ps1'), (Protect-ScaleCatches $source))
  $writer = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'board-set.ps1'))
  [IO.File]::WriteAllText((Join-Path $runtime 'board-set.ps1'), (Protect-ScaleCatches $writer))
  [IO.File]::WriteAllText((Join-Path $runtime 'count-probes.ps1'), (Get-BoardScaleProbeSource))
  [IO.File]::WriteAllText((Join-Path $runtime 'dispatch-ownership.ps1'), @'
function Get-DispatchProcessIdentityState([int]$ProcessId, [string]$StartIdentity) {
  if ($ProcessId -ne 12345) { throw 'unexpected synthetic process' }
  if ($StartIdentity -eq 'synthetic-live') { 'live' } else { 'dead' }
}
'@)
  # Logger dependencies retain their real read-only paths; only its disposable
  # catches change, including the event board-sync catch.
  $logger = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'log-event.ps1'))
  $logger = $logger.Replace('$PSScriptRoot', "'$($PSScriptRoot.Replace("'", "''"))'")
  [IO.File]::WriteAllText((Join-Path $runtime 'log-event.ps1'), (Protect-ScaleCatches $logger))
  [IO.File]::WriteAllText((Join-Path $runtime 'board-wrapper.ps1'), @'
param($Issue,$EventKind,$LaneRole,$Outcome,$ReviewAuthority,$Pr)
$root = Split-Path -Parent $PSScriptRoot
$last = Get-Content (Join-Path $root 'dispatch.jsonl') -Tail 1 | ConvertFrom-Json
if ($last.kind -ne $EventKind -or $last.issue -ne $Issue) { throw 'append-before-board missing' }
[IO.File]::AppendAllText((Join-Path $root 'append-trace'), "$EventKind|$Issue`n")
Invoke-ScaleWait board 0
$r = & (Join-Path $PSScriptRoot 'board-set.ps1') @PSBoundParameters -DispatchLog (Join-Path $root 'dispatch.jsonl') -GhCommand (Join-Path $root 'gh.ps1') -Strict
[IO.File]::WriteAllText((Join-Path $root 'board-result.json'), "$r")
Complete-ScaleBoard
[IO.File]::WriteAllText((Join-Path $root 'board-complete'), 'complete')
'@)
  [IO.File]::WriteAllText((Join-Path $runtime 'census.ps1'), @'
param($LandedPr,$LandedHead,$HistoryPath,$RuntimeRoot)
if (-not (Test-Path (Join-Path $RuntimeRoot 'board-complete')) -or -not $global:BoardScale.boardComplete) { throw 'census before board completion' }
Start-Sleep -Milliseconds ([int]$env:BOARD_SCALE_CENSUS_DELAY)
'@)
  foreach ($name in @('board-reconcile.ps1','board-set.ps1','log-event.ps1','count-probes.ps1','board-wrapper.ps1','census.ps1')) {
    $tokens = $null; $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $runtime $name), [ref]$tokens, [ref]$errors)
    Assert-Board ($errors.Count -eq 0) "instrumented runtime parses: $name"
  }
  return $runtime
}
function Assert-BoardScaleArmDecision([string]$Arm, [string]$Decision, $Counts) {
  $negative = $Arm -in @('baseline','issue-scan','no-linkage')
  Assert-Board ($Decision -ceq $(if ($negative) { 'EXCEEDED' } else { 'PASS' })) 'algorithmic control discrimination'
  if ($negative) {
    Assert-Board ($Counts.first.counter -ceq $(if ($Arm -eq 'issue-scan') { 'selection' } else { 'linkage' })) 'algorithmic control counter/reason'
  }
}
function Invoke-BoardScaleArm($Fixture, [string]$Arm, [string]$Event = '', [int]$CensusDelay = 0) {
  Write-Output "START synthetic board scale $Arm/$Event fixture=$($Fixture.root)"
  $runtime = New-BoardScaleRuntime $Fixture $Arm
  $referencePath = Join-Path $Fixture.root 'reference.jsonl'
  Copy-Item -LiteralPath $Fixture.log -Destination $referencePath -Force
  $Fixture.identity.ledgerBytes = (Get-Item $Fixture.log).Length
  $Fixture.identity.ledgerSha256 = (Get-FileHash -LiteralPath $Fixture.log -Algorithm SHA256).Hash.ToLowerInvariant()
  $Fixture.identity.specBytes = (Get-ChildItem -LiteralPath $Fixture.root -Filter 'watchdog-lane-*.json' -File | Measure-Object Length -Sum).Sum
  $expected = Get-BoardScaleExpected $Fixture.identity.items $Arm $Event
  $referenceRows = 0L
  foreach ($line in [IO.File]::ReadLines($referencePath)) {
    if (-not [string]::IsNullOrWhiteSpace($line)) { $referenceRows++ }
  }
  $referenceExpected = $expected.parse - $(if ($Event) { 1 } else { 0 })
  if ($referenceRows -ne $referenceExpected) { throw "scale reference row anchor refused: expected $referenceExpected nonblank rows, found $referenceRows ($referencePath)" }
  $Fixture.identity.rows = $referenceRows
  Write-ScaleJson (Join-Path $runtime 'limits.json') $expected
  $env:BOARD_SCALE_COUNTS = Join-Path $Fixture.root 'work-counts.json'
  [IO.File]::WriteAllText((Join-Path $Fixture.root 'stub-trace'), '')
  $env:BOARD_SCALE_CENSUS_DELAY = [string]$CensusDelay
  $start = [datetimeoffset]::UtcNow
  $driver = Join-Path $runtime 'invoke.ps1'
  $entry = if ($Event) {
    $role = if ($Event -eq 'review-complete') { 'review' } else { 'implementation' }
    $arguments = @{ Log = 'dispatch'; Kind = $Event; Issue = 8548; Lane = 'synthetic-scale-1'; LaneRole = $role
      Transcript = 'synthetic-scale-1.jsonl'; OutFile = $Fixture.log; BoardScript = (Join-Path $runtime 'board-wrapper.ps1') }
    if ($Event -eq 'review-complete') {
      $arguments.Outcome = 'PASS'; $arguments.Pr = 908548; $arguments.ReviewedHead = ('a' * 40)
      $arguments.Model = 'gpt-6.1-sol'; $arguments.AuthorModel = 'gpt-6-astra'; $arguments.Effort = 'high'
      $arguments.ReviewerAttempt = 'synthetic-scale-reviewer'; $arguments.AuthorAttempt = 'synthetic-scale-author'
      $arguments.ReviewContract = 'review-contract/v2'; $arguments.CompleteSweep = $true
      $arguments.Blocking = 0; $arguments.Candidates = 0; $arguments.NonBlocking = 0
    }
    if ($Event -eq 'landed') { $arguments.Pr = 908548; $arguments.LandedHead = ('a' * 40); $arguments.LandedIntegrationScript = Join-Path $runtime 'census.ps1' }
    Write-ScaleJson (Join-Path $runtime 'arguments.json') $arguments
    Join-Path $runtime 'log-event.ps1'
  } else {
    Write-ScaleJson (Join-Path $runtime 'arguments.json') @{ Apply = $true; DispatchLog = $Fixture.log; GhCommand = $Fixture.gh }
    Join-Path $runtime 'board-reconcile.ps1'
  }
  [IO.File]::WriteAllText($driver, @"
`$ErrorActionPreference = 'Stop'
[Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal'
. (Join-Path `$PSScriptRoot 'count-probes.ps1')
New-ScaleObservation (Get-Content (Join-Path `$PSScriptRoot 'limits.json') -Raw | ConvertFrom-Json -AsHashtable)
try {
  Invoke-ScaleWait board 0
  `$arguments = Get-Content (Join-Path `$PSScriptRoot 'arguments.json') -Raw | ConvertFrom-Json -AsHashtable
  & '$($entry.Replace("'","''"))' @arguments
  if (`$global:BoardScale.first) { throw 'swallowed scale censor' }
  if (-not `$global:BoardScale.boardComplete) { Complete-ScaleBoard }
  `$global:BoardScale.status = 'PASS'
} catch {
  if (`$_.Exception.Message -like '*SYNTHETIC_SCALE_EXCEEDED*' -and `$global:BoardScale.first) {
    `$global:BoardScale.status = 'EXCEEDED'
  } else { `$global:BoardScale.status = 'ERROR'; throw }
} finally { Write-ScaleObservation }
"@)
  # The entire real entrypoint and its stub I/O execute in this foreground child.
  $output = & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -NonInteractive -File $driver 2>&1
  $exitCode = $LASTEXITCODE
  $finish = [datetimeoffset]::UtcNow
  $evidence = if ($env:BOARD_SCALE_EVIDENCE_ROOT) { $env:BOARD_SCALE_EVIDENCE_ROOT } else { Join-Path $PSScriptRoot 'logs/board-scale' }
  [void][IO.Directory]::CreateDirectory($evidence)
  $name = "$Arm-$Event-$([guid]::NewGuid().ToString('N'))"
  $record = [ordered]@{ synthetic = $true; arm = $Arm; event = $Event; sourceHead = (& git -C $PSScriptRoot rev-parse HEAD)
    command = "pwsh -NoProfile -NonInteractive -File $driver"; priority = 'BelowNormal'
    runtimeSourceSha256 = (Get-FileHash -LiteralPath (Join-Path $runtime 'board-reconcile.ps1') -Algorithm SHA256).Hash.ToLowerInvariant()
    candidateSourceSha256 = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'board-reconcile.ps1') -Algorithm SHA256).Hash.ToLowerInvariant()
    supportBlob = (& git -C $PSScriptRoot hash-object (Join-Path $PSScriptRoot 'board-scale-test-support.ps1'))
    referenceHead = $script:BoardReferenceHead; fixture = $Fixture.identity; expected = $expected
    elapsedSeconds = ($finish - $start).TotalSeconds; exitCode = $exitCode
    censusDelayMs = $CensusDelay; verdict = 'FAIL'; output = @($output | ForEach-Object { "$_" }) }
  try {
    # Missing, malformed or truncated evidence is an error, never a censor.
    $counts = Get-Content -LiteralPath $env:BOARD_SCALE_COUNTS -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable
    $trace = @($counts.passes)
    $stub = @(Get-Content (Join-Path $Fixture.root 'stub-trace') -ErrorAction Stop | ConvertFrom-Json)
    $record.counts = $counts; $record.trace = $trace
    $record.starts = $trace.Count; $record.passes = @($trace | Where-Object complete).Count
    $record.pageCalls = @($stub | Where-Object kind -eq 'page').Count
    $record.mutations = @($stub | Where-Object kind -eq 'mutation').Count
    $record.stubSeconds = ($stub | Measure-Object seconds -Sum).Sum
    $decision = Get-BoardScaleDecision $counts $expected $exitCode $(if ($Event -eq 'landed') { $CensusDelay } else { -1 })
    Assert-BoardScaleArmDecision $Arm $decision $counts
    if ($decision -ceq 'PASS') {
      $expectedPasses = if ($Event) { 2 } elseif ($Arm -eq 'inert') { 1 } else { 21 }
      Assert-Board ($record.passes -eq $expectedPasses -and $record.starts -eq $expectedPasses) 'all complete freshness passes'
      Assert-Board (@($trace | Where-Object { $_.path -cne $Fixture.log }).Count -eq 0) 'real writer fixture-ledger forwarding'
      if (-not $Event) {
        $result = "$output" | ConvertFrom-Json
        Assert-Board ($result.scanned -eq $Fixture.identity.items -and $record.pageCalls -eq [Math]::Ceiling($Fixture.identity.items / 100)) 'complete 100-item pagination'
        Assert-Board (@($result.projections | Where-Object eligible).Count -eq $Fixture.identity.openExecutable) 'open executable board scale'
        Assert-Board ($result.mutations -eq $(if ($Arm -eq 'inert') { 0 } else { 10 }) -and $result.deferred -eq 0) 'cap writes/inert convergence'
        if ($Arm -ne 'inert') {
          Assert-Board (@($result.findings | Where-Object action -eq 'cleared').Count -eq 5 -and @($result.findings | Where-Object action -eq 'set').Count -eq 5 -and $result.syncDispatched) 'clear/set and derived-sync handoff'
          if ($Fixture.identity.items -ge 1310) {
            Assert-Board (@($result.findings | Where-Object { $_.issue -eq 9857 -and $_.action -eq 'set' }).Count -eq 1) 'decisive live owner on final executable page'
          }
        }
      } else {
        $result = Get-Content (Join-Path $Fixture.root 'board-result.json') -Raw | ConvertFrom-Json
        Assert-Board ($result.ok -and $result.action -in @('set','clear')) 'event real writer projection'
        Assert-Board ($result.action -eq $(if ($Event -eq 'dispatch') { 'set' } else { 'clear' })) 'event expected projection'
        Assert-Board ((Get-Content (Join-Path $Fixture.root 'append-trace')).Count -eq 1) 'one append before board'
      }
      $prefix = [IO.File]::ReadAllBytes($referencePath)
      $afterBytes = [IO.File]::ReadAllBytes($Fixture.log)
      Assert-Board ($afterBytes.Length -ge $prefix.Length) 'append did not truncate history'
      $prefixStream = [IO.MemoryStream]::new($afterBytes, 0, $prefix.Length, $false)
      try {
        Assert-Board ([Linq.Enumerable]::SequenceEqual([Security.Cryptography.SHA256]::HashData($prefix), [Security.Cryptography.SHA256]::HashData($prefixStream))) 'append durability/no row loss'
      } finally { $prefixStream.Dispose() }
    }
    $record.verdict = $decision
  } catch {
    $record.error = $_.Exception.Message
    throw "$($_.Exception.Message) (evidence: $(Join-Path $evidence "$name.json"))"
  } finally {
    [IO.File]::WriteAllText((Join-Path $evidence "$name.json"), ($record | ConvertTo-Json -Depth 30))
  }
  Write-Output ([pscustomobject]$record | Select-Object arm,event,elapsedSeconds,passes,mutations,pageCalls,verdict | ConvertTo-Json -Compress)
}
function Remove-BoardScaleFixture([string]$Root) {
  $resolved = [IO.Path]::GetFullPath($Root)
  if ((Split-Path -Parent $resolved) -ne [IO.Path]::GetTempPath().TrimEnd('\','/') -or (Split-Path -Leaf $resolved) -notlike 'board-scale-*') { throw 'unsafe scale cleanup' }
  if (Test-Path $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
