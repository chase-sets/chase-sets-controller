[CmdletBinding()]
param(
  [string]$Revision = '',
  [ValidateSet('', 'no-retry', 'reader-share')][string]$Mutant = '',
  [ValidateSet('all', 'transient', 'exhausted', 'non-sharing', 'reader-prefix', 'reader-contention')][string]$Scenario = 'all',
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
  if ($Mutant -eq 'no-retry') {
    $needle = 'if (-not $sharingViolation) { throw }'
    Assert-Retry ($source.Contains($needle)) 'no-retry mutant seam absent'
    $source = $source.Replace($needle, 'throw # MUTANT no-retry')
  }
  Write-TestFile $module $source
  $readerModule=Join-Path $scripts 'dispatch-ledger-reader.psm1'
  if ($Mutant -eq 'reader-share') {
    $readerSource=[IO.File]::ReadAllText($readerModule)
    $needle='[IO.FileShare]::ReadWrite'
    Assert-Retry ($readerSource.Contains($needle)) 'old direct-open/share mutant seam missing'
    Write-TestFile $readerModule ($readerSource.Replace($needle,'[IO.FileShare]::Read'))
  }
  $logger = Join-Path $scripts 'log-event.ps1'
  $source = [IO.File]::ReadAllText($logger)
  $needle = '$bytes = [Text.UTF8Encoding]::new($false).GetBytes($line + [Environment]::NewLine)'
  Assert-Retry ($source.Contains($needle)) 'logger observation seam absent'
  $source = $source.Replace($needle, "$needle`n  if (`$env:SYNTHETIC_8604_ATTEMPT) { [IO.File]::WriteAllText(`$env:SYNTHETIC_8604_ATTEMPT, 'append-attempt') }")
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
  if ($Scenario -in @('all','reader-prefix')) {
    Import-Module $readerModule -Force -DisableNameChecking
    $ledger=Join-Path $root 'utf8-dispatch-log.jsonl'
    $encoding=[Text.UTF8Encoding]::new($false,$true)
    # U+00E9 / U+20AC / U+1F600 exercise 2/3/4-byte boundaries without
    # depending on the source file's encoding. Include CRLF and a blank line.
    $unicode=[string][char]0xe9+[char]0x20ac+[char]::ConvertFromUtf32(0x1f600)
    $text="{`"kind`":`"dispatch`",`"issue`":1}`r`n`n{`"kind`":`"dispatch`",`"issue`":2,`"note`":`"$unicode`"}`n"
    $all=$encoding.GetBytes($text)
    $tested=0
    for ($offset=0;$offset -le $all.Length;$offset++) {
      $cut=[byte[]]::new($offset);[Array]::Copy($all,$cut,$offset);[IO.File]::WriteAllBytes($ledger,$cut)
      $expected=0
      for ($i=0;$i -lt $offset;$i++) { if ($cut[$i] -eq 10) { $expected=$i+1 } }
      $history=Read-DispatchCountHistory -Path $ledger
      Assert-Retry $history.complete "every-byte prefix unreadable offset=$offset"
      Assert-Retry ($history.cursor -eq $expected -and $history.snapshotLength -eq $expected -and $history.audit.bytes -eq $offset) "cursor/snapshot byte boundary offset=$offset"
      Assert-Retry ($history.partialTrailingRow -eq ($expected -ne $offset)) "partial-tail flag offset=$offset"
      $prefix=[byte[]]::new($expected);[Array]::Copy($all,$prefix,$expected)
      $digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($prefix)).ToLowerInvariant()
      Assert-Retry ($history.snapshotHash -ceq $digest) "snapshot digest offset=$offset"
      $lines=0;foreach ($b in $prefix) { if ($b -eq 10) { $lines++ } }
      Assert-Retry ($history.snapshotLines -eq $lines) "physical lines offset=$offset"
      foreach ($row in $history.rows) {
        Assert-Retry ($row.rawSha256 -ceq [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($encoding.GetBytes($row.raw))).ToLowerInvariant()) "raw hash offset=$offset"
      }
      $strict=Read-DispatchCountHistory -Path $ledger -RequireTerminated
      Assert-Retry ($strict.complete -eq ($expected -eq $offset)) "under-lock tail refusal offset=$offset"
      if ($expected -ne $offset) { Assert-Retry ($strict.reason -ceq 'HISTORY_UNTERMINATED_OR_MOVED') 'tail refusal reason changed' }
      # Finish this same interrupted append: the cached LF prefix must extend
      # identically without reparsing or renumbering its immutable rows.
      [IO.File]::WriteAllBytes($ledger,$all)
      $extended=Read-DispatchCountHistory -Path $ledger -PrefixHistory $history -RequireTerminated
      $whole=Read-DispatchCountHistory -Path $ledger -RequireTerminated
      Assert-Retry ($extended.complete -and ($extended.rows | ConvertTo-Json -Depth 30 -Compress) -ceq ($whole.rows | ConvertTo-Json -Depth 30 -Compress)) "prefix extension differs offset=$offset"
      Assert-Retry ($whole.rows.Count -eq 2 -and $whole.rows[1].line -eq 3 -and $whole.cursor -eq $all.Length) 'global blank-line identity/cursor lost'
      $tested++
    }
    foreach ($bad in @('{"a":1,"\u0061":2}', '{"nested":[{"x":1,"x":2}]}','{malformed')) {
      Write-TestFile $ledger ($bad+"`n")
      $history=Read-DispatchCountHistory -Path $ledger
      Assert-Retry (-not $history.complete -and $history.reason -ceq 'HISTORY_MALFORMED' -and $history.audit.malformedLineNumbers[0] -eq 1) 'malformed/decoded duplicate row became authority'
    }
    [IO.File]::WriteAllBytes($ledger,[byte[]]@(123,34,120,34,58,34,255,34,125,10))
    Assert-Retry (-not (Read-DispatchCountHistory -Path $ledger).complete) 'invalid UTF8 became authority'
    Write-TestFile $ledger "{}`n{}`n"
    Assert-Retry ((Read-DispatchCountHistory -Path $ledger -MaxRows 1).reason -ceq 'HISTORY_TRUNCATED') 'existing row cap changed'
    Assert-Retry ((Read-DispatchCountHistory -Path $ledger -MaxBytes 1).reason -ceq 'HISTORY_TRUNCATED') 'existing byte cap changed'
    $prefix=Read-DispatchCountHistory -Path $ledger
    Write-TestFile $ledger "[]`n[]`n"
    Assert-Retry (-not (Read-DispatchCountHistory -Path $ledger -PrefixHistory $prefix).complete) 'rewritten prefix was trusted'
    Write-TestFile $ledger ''
    Assert-Retry (-not (Read-DispatchCountHistory -Path $ledger -PrefixHistory $prefix).complete) 'rewound prefix was trusted'
    $threw=$false
    try { Read-DispatchLedgerLines -Path (Join-Path $root 'missing.jsonl') | Out-Null } catch { $threw=$true }
    Assert-Retry $threw 'throwing line adapter swallowed refusal'
    Write-TestFile $ledger "{}`r`r`n"
    $cr=Read-DispatchCountHistory -Path $ledger
    Assert-Retry ($cr.complete -and $cr.rows[0].raw -ceq '{}' -and $cr.rows[0].byteLength -eq 2 -and $cr.snapshotLines -eq 2) 'StreamReader raw/global-line compatibility changed for CR/CRLF'
    Assert-Retry (-not (Read-DispatchCountHistory -Path (Join-Path $root 'missing.jsonl')).complete) 'missing history invented empty authority'
    Write-Output "PASS reader-prefix UTF8-every-byte offsets=$tested globalLine=3 rawSha256=preserved"
  }
  if ($Scenario -in @('all','reader-contention')) {
    # Instrument copies of the full owner at the open-handle seam, not a
    # substitute stream-only reader. Both readers stay open across BOTH writes.
    $ledger=Join-Path $root 'held-dispatch-log.jsonl';$release=Join-Path $root 'reader-release'
    Write-TestFile $ledger "{`"kind`":`"dispatch`",`"issue`":1}`n"
    $initialLength=(Get-Item -LiteralPath $ledger).Length
    $readers=[Collections.Generic.List[object]]::new()
    $writer=$null;$writerPending=$null
    try {
      foreach ($index in 1..2) {
        $directory=Join-Path $root "reader-$index";[void][IO.Directory]::CreateDirectory($directory)
        $marker=Join-Path $directory 'opened';$copy=Join-Path $directory 'dispatch-ledger-reader.psm1'
        $source=[IO.File]::ReadAllText($readerModule)
        $needle='$length=$stream.Length'
        Assert-Retry ($source.Contains($needle)) 'held-open full reader seam absent'
        $pause=@'
[IO.File]::WriteAllText('__MARKER__','open')
$deadline=[datetime]::UtcNow.AddSeconds(60)
while (-not [IO.File]::Exists('__RELEASE__')) {
  if ([datetime]::UtcNow -ge $deadline) { throw 'reader barrier expired' }
  [Threading.Thread]::Sleep(10)
}
'@
        $pause=$pause.Replace('__MARKER__',$marker.Replace("'","''")).Replace('__RELEASE__',$release.Replace("'","''"))
        Write-TestFile $copy ($source.Replace($needle,$needle+"`n"+$pause))
        $shell=[powershell]::Create()
        [void]$shell.AddScript({param($module,$path) Import-Module $module -Force; Read-DispatchCountHistory -Path $path}).AddArgument($copy).AddArgument($ledger)
        $pending=$shell.BeginInvoke();$readers.Add(@{shell=$shell;pending=$pending;marker=$marker;module=$copy})
      }
      $deadline=[datetime]::UtcNow.AddSeconds(30)
      while (@($readers | Where-Object { -not [IO.File]::Exists($_.marker) }).Count -and [datetime]::UtcNow -lt $deadline) { [Threading.Thread]::Sleep(10) }
      Assert-Retry (@($readers | Where-Object { [IO.File]::Exists($_.marker) -and -not $_.pending.IsCompleted }).Count -eq 2) 'N=2 full readers not genuinely held open'
      $writer=[powershell]::Create()
      [void]$writer.AddScript({param($logger,$ledger)
        $ErrorActionPreference='Stop'
        foreach ($issue in 2..3) { & $logger -Log dispatch -Kind cycle -Issue $issue -OutFile $ledger -NoBoard }
      }).AddArgument($logger).AddArgument($ledger)
      $writerPending=$writer.BeginInvoke()
      Assert-Retry ($writerPending.AsyncWaitHandle.WaitOne(45000)) 'append worker did not finish while readers held open'
      $writerOutput=$writer.EndInvoke($writerPending)
      Assert-Retry (-not $writer.HadErrors -and ($writer.Streams.Error | Out-String) -notmatch 'ORCHESTRATION_LOG_SHARING_RETRY_EXHAUSTED') "held-reader append refused or exhausted sharing retries (old direct-open/share RED control): $($writer.Streams.Error | Out-String)"
      Assert-Retry (@($readers | Where-Object { -not $_.pending.IsCompleted }).Count -eq 2) 'readers released before append completion'
      Write-TestFile $release 'release after both persisted appends'
      foreach ($reader in $readers) {
        Assert-Retry ($reader.pending.AsyncWaitHandle.WaitOne(10000)) 'full reader failed to complete'
        $history=@($reader.shell.EndInvoke($reader.pending))[-1]
        Assert-Retry (-not $reader.shell.HadErrors -and $history.complete -and $history.cursor -eq $initialLength -and $history.rows.Count -eq 1) 'held reader returned torn/incomplete captured prefix'
        $reader.shell.Commands.Clear()
        [void]$reader.shell.AddScript({param($path) Read-DispatchCountHistory -Path $path}).AddArgument($ledger)
        $final=@($reader.shell.Invoke())[-1]
        Assert-Retry ($final.complete -and $final.rows.Count -eq 3 -and $final.cursor -eq (Get-Item -LiteralPath $ledger).Length -and -not $final.partialTrailingRow) 'reader final cursor omitted persisted append'
        Assert-Retry ((@($final.rows | ForEach-Object { $_.value.issue }) -join ',') -ceq '1,2,3') 'append lost or duplicated'
      }
      Write-Output 'PASS reader-contention heldFullReaders=2 appends=2 persisted=2 completeCursors=2 retryExhaustion=0 timingGate=none'
    } finally {
      Write-TestFile $release 'release on failure'
      if ($writer) {
        if ($writerPending -and -not $writerPending.IsCompleted) { [void]$writerPending.AsyncWaitHandle.WaitOne(45000) }
        $writer.Dispose()
      }
      foreach ($reader in $readers) { if (-not $reader.pending.IsCompleted) { [void]$reader.pending.AsyncWaitHandle.WaitOne(10000) };$reader.shell.Dispose() }
    }
  }
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
        Assert-Retry ($rows.Count -eq 1 -and $rows[0].dispatchRoutingSchema -ceq 'watchdog-dispatch-routing/v3') 'routing append duplicated or changed schema'
        . (Join-Path $scripts 'dispatch-ownership.ps1')
        Assert-Retry (Test-DispatchRoutingLedgerEvidence $rows[0]) 'capacity routing evidence lost at ledger admission'
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
  if (-not $Mutant -and -not $Revision -and $Scenario -in @('all','reader-contention')) {
    $redOutput=Join-Path $EvidenceRoot 'old-reader-share.red.log'
    & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -NonInteractive -File $PSCommandPath -Scenario reader-contention -Mutant reader-share *> $redOutput
    $redExit=$LASTEXITCODE
    Assert-Retry ($redExit -ne 0 -and [IO.File]::ReadAllText($redOutput).Contains('ORCHESTRATION_LOG_SHARING_RETRY_EXHAUSTED')) 'old direct-open/share RED control did not discriminate'
    Write-Output "KILLED old-direct-open/share fullReaders=2 exit=$redExit log=$redOutput"
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
