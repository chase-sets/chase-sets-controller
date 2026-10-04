[CmdletBinding()]
param(
  [string]$Revision = '',
  [ValidateSet('', 'no-retry')][string]$Mutant = '',
  [ValidateSet('all', 'transient', 'exhausted', 'non-sharing')][string]$Scenario = 'all',
  [string]$EvidenceRoot = ''
)

$ErrorActionPreference = 'Stop'
[Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal'
$root = Join-Path ([IO.Path]::GetTempPath()) ('synthetic-8604-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
if (-not $EvidenceRoot) { $EvidenceRoot = Join-Path $root 'evidence' }
[void][IO.Directory]::CreateDirectory($EvidenceRoot)
function Assert-Retry([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}
function Write-TestFile([string]$Path, [string]$Text) {
  [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

$routingScope = $null
try {
  $subject = Join-Path $root 'subject'
  [void][IO.Directory]::CreateDirectory($subject)
  $controller = Split-Path -Parent $PSScriptRoot
  if ($Revision) {
    $archive = Join-Path $root 'subject.zip'
    & git -C $controller archive --format=zip "--output=$archive" $Revision -- .orchestrator
    Assert-Retry ($LASTEXITCODE -eq 0) 'baseline archive failed'
    Expand-Archive -LiteralPath $archive -DestinationPath $subject
  } else {
    $paths = @(& git -C $controller ls-files -- .orchestrator)
    Assert-Retry ($LASTEXITCODE -eq 0) 'candidate source inventory failed'
    foreach ($path in $paths) {
      $destination = Join-Path $subject $path
      [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
      [IO.File]::Copy((Join-Path $controller $path), $destination)
    }
  }
  $scripts = Join-Path $subject '.orchestrator'
  $module = Join-Path $scripts 'orchestration-log-lock.psm1'
  $source = [IO.File]::ReadAllText($module)
  # The real lock algorithm runs against a private mutex, never the host ledger.
  $source = $source.Replace('Global\ChaseSetsOrchLog', ('Local\Synthetic8604-' + [guid]::NewGuid().ToString('N')))
  if ($Mutant) {
    $needle = 'if (-not $sharingViolation) { throw }'
    Assert-Retry ($source.Contains($needle)) 'no-retry mutant seam absent'
    $source = $source.Replace($needle, 'throw # MUTANT no-retry')
  }
  Write-TestFile $module $source
  $logger = Join-Path $scripts 'log-event.ps1'
  $source = [IO.File]::ReadAllText($logger)
  $needle = '$bytes = [Text.UTF8Encoding]::new($false).GetBytes($line + [Environment]::NewLine)'
  Assert-Retry ($source.Contains($needle)) 'logger observation seam absent'
  $source = $source.Replace($needle, "$needle`n  [IO.File]::WriteAllText(`$env:SYNTHETIC_8604_ATTEMPT, 'append-attempt')")
  Write-TestFile $logger $source
  . (Join-Path $scripts 'routing-data-test-support.ps1')
  $routingScope = Enter-RoutingDataTestScope

  $worktree = Join-Path $root 'synthetic-seat'
  [void][IO.Directory]::CreateDirectory($worktree)
  & git -C $worktree init -q
  Assert-Retry ($LASTEXITCODE -eq 0) 'fixture init failed'
  Write-TestFile (Join-Path $worktree 'fixture.txt') 'synthetic fixture'
  & git -C $worktree add fixture.txt
  & git -C $worktree -c user.name=Synthetic -c user.email=synthetic@example.invalid commit -qm fixture
  Assert-Retry ($LASTEXITCODE -eq 0) 'fixture commit failed'
  $prompt = Join-Path $root 'prompt.txt'
  Write-TestFile $prompt 'Synthetic inert harness. No provider or model invocation.'
  $child = Join-Path $root 'child.ps1'
  Write-TestFile $child @'
[Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal'
[IO.File]::WriteAllText($env:SYNTHETIC_8604_CHILD, 'started')
Start-Sleep -Milliseconds 500
Write-Output 'synthetic child completed'
exit 0
'@
  $runner = Join-Path $root 'runner.ps1'
  Write-TestFile $runner @'
param($Launcher, $Worktree, $Prompt, $Child, $Runtime, $Temp, $Label)
$ErrorActionPreference = 'Stop'
[Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal'
& $Launcher -Harness codex -Model gpt-6.1-sol -Effort high -LaneRole implementation -Row 4 -Placement provisional -Issue 908604 `
  -Worktree $Worktree -PromptFile $Prompt -Label $Label -ExecutablePath (Join-Path $PSHOME 'pwsh.exe') `
  -TestArgumentList @('-NoProfile', '-NonInteractive', '-File', $Child) -TestRuntimeRoot $Runtime -TestTempRoot $Temp
exit $LASTEXITCODE
'@

  $failures = [Collections.Generic.List[string]]::new()
  foreach ($case in @('transient', 'exhausted', 'non-sharing')) {
    if ($Scenario -ne 'all' -and $Scenario -ne $case) { continue }
    $runtime = Join-Path $root "runtime-$case"
    $temp = Join-Path $root "temp-$case"
    [void][IO.Directory]::CreateDirectory($runtime)
    [void][IO.Directory]::CreateDirectory($temp)
    $ledger = Join-Path $runtime 'dispatch-log.jsonl'
    $marker = Join-Path $root "attempt-$case.txt"
    $childMarker = Join-Path $root "child-$case.txt"
    $stdout = Join-Path $EvidenceRoot "$case.out.log"
    $stderr = Join-Path $EvidenceRoot "$case.err.log"
    $label = "synthetic-8604-$case"
    $handle = $null
    $process = $null
    try {
      if ($case -eq 'non-sharing') {
        [void][IO.Directory]::CreateDirectory($ledger)
      } else {
        Write-TestFile $ledger ''
        $handle = [IO.File]::Open($ledger, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
      }
      $arguments = @('-NoProfile', '-NonInteractive', '-File', $runner,
        (Join-Path $scripts 'dispatch-lane.ps1'), $worktree, $prompt, $child, $runtime, $temp, $label)
      $process = Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList $arguments -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr `
        -Environment @{SYNTHETIC_8604_ATTEMPT=$marker; SYNTHETIC_8604_CHILD=$childMarker}
      $deadline = [datetime]::UtcNow.AddSeconds(15)
      while (-not (Test-Path -LiteralPath $marker) -and -not $process.HasExited -and [datetime]::UtcNow -lt $deadline) {
        [Threading.Thread]::Sleep(25)
      }
      Assert-Retry (Test-Path -LiteralPath $marker) "$case never reached append; see $stderr"
      $timer = [Diagnostics.Stopwatch]::StartNew()
      if ($case -eq 'transient') {
        [Threading.Thread]::Sleep(1200)
        Assert-Retry (@(Get-ChildItem -LiteralPath $runtime -Filter 'dispatch-launch-*.json').Count -eq 0) 'ownership published while ledger is locked'
        Assert-Retry (-not (Test-Path -LiteralPath (Join-Path $runtime "$label.jsonl"))) 'transcript created while ledger is locked'
        Assert-Retry (-not (Test-Path -LiteralPath $childMarker)) 'child started while ledger is locked'
        $handle.Dispose(); $handle = $null
      }
      $waitSeconds = if ($case -eq 'exhausted') { 38 } else { 10 }
      Assert-Retry ($process.WaitForExit($waitSeconds * 1000)) "$case exceeded focused test bound"
      $timer.Stop()
      $code = $process.ExitCode
      if ($handle) { $handle.Dispose(); $handle = $null }
      $output = [IO.File]::ReadAllText($stdout)
      $errorText = [IO.File]::ReadAllText($stderr)
      $owners = @(Get-ChildItem -LiteralPath $runtime -Filter 'dispatch-launch-*.json').Count
      $prompts = @(Get-ChildItem -LiteralPath $runtime -Filter 'dispatch-heavy-verifier-*.prompt.txt').Count
      if ($case -eq 'transient') {
        Assert-Retry ($code -eq 0) "transient lock did not launch: exit=$code; see $stderr"
        Assert-Retry (Test-Path -LiteralPath $childMarker) 'synthetic child did not run'
        Assert-Retry ($output -match 'dispatch-lane: pid \d+') 'success missing pid output'
        $rows = @(Get-Content -LiteralPath $ledger | ConvertFrom-Json -DateKind String)
        Assert-Retry ($rows.Count -eq 1 -and $rows[0].dispatchRoutingSchema -ceq 'watchdog-dispatch-routing/v2') 'routing append duplicated or changed schema'
        Assert-Retry ($rows[0].issue -eq 908604 -and $rows[0].label -ceq $label) 'routing identity changed'
      } else {
        Assert-Retry ($code -ne 0) "$case unexpectedly succeeded"
        Assert-Retry ($owners -eq 0 -and $prompts -eq 0) "$case left ownership or prompt residue"
        Assert-Retry (@(Get-ChildItem -LiteralPath $temp).Count -eq 0) "$case created provider isolation"
        Assert-Retry (-not (Test-Path -LiteralPath (Join-Path $runtime "$label.jsonl"))) "$case created transcript"
        Assert-Retry (-not (Test-Path -LiteralPath $childMarker)) "$case launched child"
        Assert-Retry ($output -notmatch 'dispatch-lane: pid') "$case printed pid"
        Assert-Retry (@(Get-ChildItem -LiteralPath $runtime -Filter 'watchdog-lane-*.json').Count -eq 0) "$case published watchdog ownership"
        if ($case -eq 'exhausted') {
          Assert-Retry ($code -eq 74 -and $errorText.Contains('ORCHESTRATION_LOG_SHARING_RETRY_EXHAUSTED')) 'exhaustion missing distinct exit 74/code'
          Assert-Retry ($timer.Elapsed.TotalSeconds -ge 29 -and $timer.Elapsed.TotalSeconds -lt 35) 'retry budget not bounded to 30 seconds'
          Assert-Retry ((Get-Item -LiteralPath $ledger).Length -eq 0) 'exhaustion changed ledger bytes'
        } else {
          Assert-Retry ($code -ne 74 -and $timer.Elapsed.TotalSeconds -lt 5) 'non-sharing I/O error was retried or misclassified'
          Assert-Retry ($errorText -match 'denied|UnauthorizedAccess') 'non-sharing control missed real access-denied error'
        }
      }
      Assert-Retry ($owners -eq 0 -and $prompts -eq 0) 'completion left launch resources'
      Write-Output "PASS $case exit=$code appendElapsedMs=$($timer.ElapsedMilliseconds) owners=$owners prompts=$prompts logs=$stdout,$stderr"
    } catch {
      $failures.Add("${case}: $($_.Exception.Message)")
      Write-Output "FAIL ${case}: $($_.Exception.Message)"
    } finally {
      if ($handle) { $handle.Dispose() }
      if ($process) {
        # Never detach the fixture, even if an assertion fails before its wait.
        $process.WaitForExit()
        $state = [ordered]@{
          scenario=$case; exitCode=$process.ExitCode
          owners=@(Get-ChildItem -LiteralPath $runtime -Filter 'dispatch-launch-*.json').Count
          watchdogs=@(Get-ChildItem -LiteralPath $runtime -Filter 'watchdog-lane-*.json').Count
          prompts=@(Get-ChildItem -LiteralPath $runtime -Filter 'dispatch-heavy-verifier-*.prompt.txt').Count
          transcriptExists=(Test-Path -LiteralPath (Join-Path $runtime "$label.jsonl"))
          childStarted=(Test-Path -LiteralPath $childMarker)
          pidOutput=([IO.File]::ReadAllText($stdout) -match 'dispatch-lane: pid')
        }
        Write-TestFile (Join-Path $EvidenceRoot "$case.state.json") ($state | ConvertTo-Json)
        if (Test-Path -LiteralPath $ledger -PathType Leaf) {
          [IO.File]::Copy($ledger, (Join-Path $EvidenceRoot "$case.ledger.jsonl"), $true)
        }
        $process.Dispose()
      }
    }
  }
  if ($failures.Count) { throw ($failures -join "`n") }
  Write-Output "PASS dispatch ledger sharing retry revision=$Revision mutant=$Mutant"
} finally {
  if ($routingScope) { Exit-RoutingDataTestScope $routingScope }
  $resolved = [IO.Path]::GetFullPath($root)
  if ((Split-Path -Parent $resolved).TrimEnd('\','/') -cne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/') -or
      (Split-Path -Leaf $resolved) -cnotlike 'synthetic-8604-*') { throw 'unsafe synthetic fixture cleanup' }
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
