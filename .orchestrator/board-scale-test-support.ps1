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
function New-BoardScaleRuntime($Fixture, [string]$Arm = 'candidate') {
  $runtime = Join-Path $Fixture.root 'runtime'
  [void][IO.Directory]::CreateDirectory($runtime)
  $source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'board-reconcile.ps1'))
  $oracle = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fixtures/board-history-v289.ps1'))
  $tokens = $null; $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseInput($oracle, [ref]$tokens, [ref]$errors)
  $oldHistory = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-BoardHistory' }, $false).Extent.Text
  $oldProjection = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-BoardProjection' }, $false).Extent.Text
  if ($Arm -eq 'baseline') {
    $candidateAst = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
    foreach ($name in @('Get-BoardHistory','Get-BoardProjection')) {
      $function = $candidateAst.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $false)
      $replacement = if ($name -eq 'Get-BoardHistory') { $oldHistory } else { $oldProjection }
      $source = $source.Replace($function.Extent.Text, $replacement)
    }
  }
  if ($Arm -in @('issue-scan','ten-item-scan')) {
    $source = $source.Replace('$related = @(Get-BoardIssueRows $History.indexes $native.number)',
      '$related = @($History.rows | Where-Object { $_.issue -eq $native.number })')
  }
  if ($Arm -eq 'no-linkage') {
    $start = $oldHistory.IndexOf('  foreach ($label in $specs.Keys)')
    $end = $oldHistory.IndexOf('  return @{ rows')
    $loop = $oldHistory.Substring($start, $end - $start)
    $old = '  foreach ($label in $specs.Keys) {' + "`n" +
      '    if (-not $indexes.linkedLabels.Contains($label)) { $errors.Add("unlinked watchdog ${label}: owning issue unknown") }' + "`n" + '  }'
    $source = $source.Replace("`r`n", "`n")
    Assert-Board ($source.Contains($old)) 'linkage mutant anchor'
    $source = $source.Replace($old, $loop)
  }
  # These probes exist only in the disposable runtime, never production guards.
  $source = $source.Replace('function Get-BoardHistory([string]$Path) {', @'
function Get-BoardHistory([string]$Path) {
  Test-ScaleBudget
  [IO.File]::AppendAllText($env:BOARD_SCALE_TRACE, "start|$Path`n")
'@)
  $source = $source.Replace('  return @{ rows =', '  [IO.File]::AppendAllText($env:BOARD_SCALE_TRACE, "complete|$count|$($specs.Count)`n")' + "`n" + '  return @{ rows =')
  if ($Arm -in @('baseline','no-linkage')) {
    $source = $source.Replace('foreach ($label in $specs.Keys) {', 'foreach ($label in $specs.Keys) { Test-ScaleBudget;')
  }
  $source = $source.Replace('function Get-BoardProjection($Item, $History) {', 'function Get-BoardProjection($Item, $History) { Test-ScaleBudget;')
  [IO.File]::WriteAllText((Join-Path $runtime 'board-reconcile.ps1'), $source)
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'board-set.ps1') -Destination $runtime
  [IO.File]::WriteAllText((Join-Path $runtime 'dispatch-ownership.ps1'), @'
function Get-DispatchProcessIdentityState([int]$ProcessId, [string]$StartIdentity) {
  if ($ProcessId -ne 12345) { throw 'unexpected synthetic process' }
  if ($StartIdentity -eq 'synthetic-live') { 'live' } else { 'dead' }
}
function Test-ScaleBudget {
  if ($env:BOARD_SCALE_DEADLINE -and [datetimeoffset]::UtcNow.Ticks -gt [long]$env:BOARD_SCALE_DEADLINE) { throw 'SYNTHETIC_SCALE_CENSORED' }
}
'@)
  $logger = (Join-Path $PSScriptRoot 'log-event.ps1').Replace("'", "''")
  [IO.File]::WriteAllText((Join-Path $runtime 'log-event.ps1'), "& '$logger' @args")
  [IO.File]::WriteAllText((Join-Path $runtime 'board-wrapper.ps1'), @'
param($Issue,$EventKind,$LaneRole,$Outcome,$ReviewAuthority,$Pr)
$root = Split-Path -Parent $PSScriptRoot
$last = Get-Content (Join-Path $root 'dispatch.jsonl') -Tail 1 | ConvertFrom-Json
if ($last.kind -ne $EventKind -or $last.issue -ne $Issue) { throw 'append-before-board missing' }
[IO.File]::AppendAllText((Join-Path $root 'append-trace'), "$EventKind|$Issue`n")
$r = & (Join-Path $PSScriptRoot 'board-set.ps1') @PSBoundParameters -DispatchLog (Join-Path $root 'dispatch.jsonl') -GhCommand (Join-Path $root 'gh.ps1') -Strict
[IO.File]::WriteAllText((Join-Path $root 'board-result.json'), "$r")
[IO.File]::WriteAllText((Join-Path $root 'board-complete'), [string][datetimeoffset]::UtcNow.Ticks)
'@)
  [IO.File]::WriteAllText((Join-Path $runtime 'census.ps1'), @'
param($LandedPr,$LandedHead,$HistoryPath,$RuntimeRoot)
$start = [Diagnostics.Stopwatch]::StartNew()
if ($env:BOARD_SCALE_CENSUS_DELAY) { Start-Sleep -Milliseconds ([int]$env:BOARD_SCALE_CENSUS_DELAY) }
[IO.File]::WriteAllText((Join-Path $RuntimeRoot 'census-seconds'), [string]$start.Elapsed.TotalSeconds)
'@)
  return $runtime
}
function Measure-BoardReference([string]$Path) {
  # AST extraction is from the committed immutable oracle, not candidate or
  # mutant. These are precisely installed lines 47-79, through inventory catch.
  $oracle = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fixtures/board-history-v289.ps1'))
  $start = $oracle.IndexOf('  $rows =')
  $end = $oracle.IndexOf('  foreach ($label in $specs.Keys)')
  $body = 'param([string]$Path)' + "`n" + $oracle.Substring($start, $end - $start) +
    "`n" + 'return @{ rows=$rows.Count; count=$count; specs=$specs.Count; errors=@($errors) }'
  $referenceBody = [scriptblock]::Create($body)
  $clock = [Diagnostics.Stopwatch]::StartNew()
  $result = & $referenceBody $Path
  $seconds = $clock.Elapsed.TotalSeconds
  Assert-Board ($result.count -ge 24500 -and $result.rows -ge 20000 -and $result.specs -eq 3415 -and $result.errors.Count -eq 0) 'reference complete parse/inventory'
  $script:BoardReferenceCounts = $result
  return $seconds
}
function Get-ScaleLoad {
  if ($IsWindows) {
    try { return @{ percent = (Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average; source = 'Win32_Processor.LoadPercentage' } } catch {}
  }
  return @{ percent = $null; source = 'unavailable'; processCpuSeconds = [Diagnostics.Process]::GetCurrentProcess().TotalProcessorTime.TotalSeconds }
}
function Invoke-BoardScaleArm($Fixture, [string]$Arm, [string]$Event = '', [int]$CensusDelay = 0) {
  Write-Output "START synthetic board scale $Arm/$Event fixture=$($Fixture.root)"
  $runtime = New-BoardScaleRuntime $Fixture $Arm
  $referencePath = Join-Path $Fixture.root 'reference.jsonl'
  Copy-Item -LiteralPath $Fixture.log -Destination $referencePath -Force
  $Fixture.identity.ledgerBytes = (Get-Item $Fixture.log).Length
  $Fixture.identity.ledgerSha256 = (Get-FileHash -LiteralPath $Fixture.log -Algorithm SHA256).Hash.ToLowerInvariant()
  $Fixture.identity.specBytes = (Get-ChildItem -LiteralPath $Fixture.root -Filter 'watchdog-lane-*.json' -File | Measure-Object Length -Sum).Sum
  $env:BOARD_SCALE_TRACE = Join-Path $Fixture.root 'history-trace'
  [IO.File]::WriteAllText($env:BOARD_SCALE_TRACE, '')
  [IO.File]::WriteAllText((Join-Path $Fixture.root 'stub-trace'), '')
  $env:BOARD_SCALE_CENSUS_DELAY = [string]$CensusDelay
  $env:BOARD_SCALE_DEADLINE = ''
  $before = Measure-BoardReference $referencePath
  $Fixture.identity.rows = $script:BoardReferenceCounts.count
  $Fixture.identity.retained = $script:BoardReferenceCounts.rows
  $loadBefore = Get-ScaleLoad
  $start = [datetimeoffset]::UtcNow
  $budgetBefore = if ($Event) { 3 * $before + 10 } elseif ($Arm -eq 'inert') { 2 * $before + 10 } else { 1.4 * 21 * $before + 30 }
  if ($Arm -in @('baseline','issue-scan','no-linkage')) {
    # Stop at the provisional budget, then validate against the final bracket.
    # A larger after-reference makes this invalid evidence, never a red PASS.
    $env:BOARD_SCALE_DEADLINE = [string]$start.AddSeconds($budgetBefore).Ticks
  }
  $driver = Join-Path $runtime 'invoke.ps1'
  $entry = if ($Event) {
    $role = if ($Event -eq 'review-complete') { 'review' } else { 'implementation' }
    $args = @{ Log = 'dispatch'; Kind = $Event; Issue = 8548; Lane = 'synthetic-scale-1'; LaneRole = $role
      Transcript = 'synthetic-scale-1.jsonl'; OutFile = $Fixture.log; BoardScript = (Join-Path $runtime 'board-wrapper.ps1') }
    if ($Event -eq 'review-complete') {
      $args.Outcome = 'PASS'; $args.Pr = 908548; $args.ReviewedHead = ('a' * 40)
      $args.Model = 'gpt-6.1-sol'; $args.AuthorModel = 'gpt-6-astra'; $args.Effort = 'high'
      $args.ReviewerAttempt = 'synthetic-scale-reviewer'; $args.AuthorAttempt = 'synthetic-scale-author'
      $args.ReviewContract = 'review-contract/v2'; $args.CompleteSweep = $true
      $args.Blocking = 0; $args.Candidates = 0; $args.NonBlocking = 0
    }
    if ($Event -eq 'landed') { $args.Pr = 908548; $args.LandedHead = ('a' * 40); $args.LandedIntegrationScript = Join-Path $runtime 'census.ps1' }
    Write-ScaleJson (Join-Path $runtime 'arguments.json') $args
    (Join-Path $PSScriptRoot 'log-event.ps1')
  } else {
    Write-ScaleJson (Join-Path $runtime 'arguments.json') @{ Apply = $true; DispatchLog = $Fixture.log; GhCommand = $Fixture.gh }
    Join-Path $runtime 'board-reconcile.ps1'
  }
  [IO.File]::WriteAllText($driver, @"
`$ErrorActionPreference = 'Stop'
[Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal'
try {
  `$arguments = Get-Content (Join-Path `$PSScriptRoot 'arguments.json') -Raw | ConvertFrom-Json -AsHashtable
  & '$($entry.Replace("'","''"))' @arguments
} catch { if (`$_.Exception.Message -match 'SYNTHETIC_SCALE_CENSORED') { 'SYNTHETIC_SCALE_CENSORED' } else { throw } }
"@)
  # Foreground child includes the actual entrypoint startup and all stub I/O.
  $output = & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File $driver 2>&1
  $exitCode = $LASTEXITCODE
  $finish = [datetimeoffset]::UtcNow
  $elapsed = ($finish - $start).TotalSeconds
  if ($Event -eq 'landed' -and (Test-Path (Join-Path $Fixture.root 'board-complete'))) {
    $elapsed = ([datetimeoffset]::new([long][IO.File]::ReadAllText((Join-Path $Fixture.root 'board-complete')), [timespan]::Zero) - $start).TotalSeconds
  }
  $env:BOARD_SCALE_DEADLINE = ''
  $loadAfter = Get-ScaleLoad
  $after = Measure-BoardReference $referencePath
  $reference = [Math]::Max($before, $after)
  $budget = if ($Event) { 3 * $reference + 10 } elseif ($Arm -eq 'inert') { 2 * $reference + 10 } else { 1.4 * 21 * $reference + 30 }
  $trace = @(Get-Content $env:BOARD_SCALE_TRACE)
  $stub = @(Get-Content (Join-Path $Fixture.root 'stub-trace') | ConvertFrom-Json)
  $censored = "$output" -match 'SYNTHETIC_SCALE_CENSORED'
  $record = [ordered]@{ synthetic = $true; arm = $Arm; event = $Event; sourceHead = (& git -C $PSScriptRoot rev-parse HEAD)
    command = "pwsh -NoProfile -File $driver"; priority = 'BelowNormal'
    runtimeSourceSha256 = (Get-FileHash -LiteralPath (Join-Path $runtime 'board-reconcile.ps1') -Algorithm SHA256).Hash.ToLowerInvariant()
    candidateSourceSha256 = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'board-reconcile.ps1') -Algorithm SHA256).Hash.ToLowerInvariant()
    referenceHead = $script:BoardReferenceHead; fixture = $Fixture.identity; beforeSeconds = $before; afterSeconds = $after
    elapsedSeconds = $elapsed; fullInvocationSeconds = ($finish - $start).TotalSeconds; budgetSeconds = $budget
    loadBefore = $loadBefore; loadAfter = $loadAfter; starts = @($trace | Where-Object { $_ -like 'start|*' }).Count
    passes = @($trace | Where-Object { $_ -like 'complete|*' }).Count; trace = $trace
    stubSeconds = ($stub | Measure-Object seconds -Sum).Sum; pageCalls = @($stub | Where-Object kind -eq 'page').Count
    mutations = @($stub | Where-Object kind -eq 'mutation').Count; censusDelayMs = $CensusDelay; censusSeconds = 0
    exitCode = $exitCode; censored = $censored; verdict = 'INCONCLUSIVE'; timingVerdict = 'FAIL'; output = @($output | ForEach-Object { "$_" }) }
  if (Test-Path (Join-Path $Fixture.root 'census-seconds')) { $record.censusSeconds = [double][IO.File]::ReadAllText((Join-Path $Fixture.root 'census-seconds')) }
  if ($Arm -in @('baseline','issue-scan','no-linkage')) {
    if ($exitCode -eq 0 -and $censored -and $elapsed -gt $budget) { $record.verdict = 'EXCEEDED (censored)' }
  } elseif ($exitCode -eq 0 -and -not $censored -and $elapsed -le $budget) { $record.timingVerdict = 'PASS' }
  $evidence = if ($env:BOARD_SCALE_EVIDENCE_ROOT) { $env:BOARD_SCALE_EVIDENCE_ROOT } else { Join-Path $PSScriptRoot 'logs/board-scale' }
  [void][IO.Directory]::CreateDirectory($evidence)
  $name = "$Arm-$Event-$([guid]::NewGuid().ToString('N'))"
  [IO.File]::WriteAllText((Join-Path $evidence "$name.json"), ($record | ConvertTo-Json -Depth 30))
  Assert-Board ($record.verdict -ne 'INCONCLUSIVE' -or $record.timingVerdict -eq 'PASS') "$Arm/$Event full-path evidence failed: $evidence/$name.json"
  if ($record.timingVerdict -eq 'PASS') {
    $expectedPasses = if ($Event) { 2 } elseif ($Arm -eq 'inert') { 1 } else { 21 }
    Assert-Board ($record.passes -eq $expectedPasses -and $record.starts -eq $expectedPasses) 'all complete freshness passes'
    Assert-Board (@($trace | Where-Object { $_ -like 'start|*' -and $_ -cne "start|$($Fixture.log)" }).Count -eq 0) 'real writer fixture-ledger forwarding'
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
      if ($Event -eq 'landed') {
        Assert-Board ($record.fullInvocationSeconds - $record.elapsedSeconds -ge $record.censusSeconds) 'census is outside board clock'
        Assert-Board ($record.censusSeconds -ge $CensusDelay / 1000) 'census-only slowdown actually executed'
      }
    }
    $prefix = [IO.File]::ReadAllBytes($referencePath)
    $afterBytes = [IO.File]::ReadAllBytes($Fixture.log)
    Assert-Board ($afterBytes.Length -ge $prefix.Length) 'append did not truncate history'
    $prefixStream = [IO.MemoryStream]::new($afterBytes, 0, $prefix.Length, $false)
    try {
      Assert-Board ([Linq.Enumerable]::SequenceEqual([Security.Cryptography.SHA256]::HashData($prefix), [Security.Cryptography.SHA256]::HashData($prefixStream))) 'append durability/no row loss'
    } finally { $prefixStream.Dispose() }
    $record.verdict = 'PASS'
  }
  [IO.File]::WriteAllText((Join-Path $evidence "$name.json"), ($record | ConvertTo-Json -Depth 30))
  Write-Output ([pscustomobject]$record | Select-Object arm,event,beforeSeconds,afterSeconds,elapsedSeconds,budgetSeconds,passes,mutations,pageCalls,stubSeconds,verdict | ConvertTo-Json -Compress)
}
function Remove-BoardScaleFixture([string]$Root) {
  $resolved = [IO.Path]::GetFullPath($Root)
  if ((Split-Path -Parent $resolved) -ne [IO.Path]::GetTempPath().TrimEnd('\','/') -or (Split-Path -Leaf $resolved) -notlike 'board-scale-*') { throw 'unsafe scale cleanup' }
  if (Test-Path $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
