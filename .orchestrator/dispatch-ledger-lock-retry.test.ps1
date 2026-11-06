[CmdletBinding()]
param(
  [string]$Revision = '',
  [ValidateSet('', 'no-retry', 'reader-share')][string]$Mutant = '',
  [ValidateSet('all', 'transient', 'exhausted', 'non-sharing', 'reader-prefix', 'reader-contention', 'forced-sharing')][string]$Scenario = 'all',
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
function Get-TestRetryPath([string]$Ledger) {
  $key=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($Ledger))))
  return Join-Path $retryDirectory ($key+'.txt')
}
function Get-TestRetryCount([string]$Ledger) {
  $path=Get-TestRetryPath $Ledger
  if (-not [IO.File]::Exists($path)) { return 0 }
  # Observation must not deny write sharing to the counter's append handle.
  $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
  $reader=[IO.StreamReader]::new($stream)
  try {
    $count=0
    while ($null -ne $reader.ReadLine()) { $count++ }
    return $count
  } finally { $reader.Dispose() }
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
  $hashes=[ordered]@{}
  $hashes['dispatch-ledger-lock-retry.test.ps1']=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
  foreach ($name in @('dispatch-ledger-reader.psm1','dispatch-history-checkpoint.psm1','orchestration-log-lock.psm1','log-event.ps1')) {
    $path=Join-Path $scripts $name
    # Older -Revision fixtures may predate the reader/checkpoint modules.
    $hashes[$name]=if ([IO.File]::Exists($path)) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }
  }
  Write-TestFile (Join-Path $EvidenceRoot 'source-hashes.json') ($hashes | ConvertTo-Json)
  $retryDirectory=Join-Path $root 'sharing-retries'
  [void][IO.Directory]::CreateDirectory($retryDirectory)
  $module = Join-Path $scripts 'orchestration-log-lock.psm1'
  $source = [IO.File]::ReadAllText($module)
  # The real lock algorithm runs against a private mutex, never the host ledger.
  $source = $source.Replace('Global\ChaseSetsOrchLog', ('Local\Synthetic8604-' + [guid]::NewGuid().ToString('N')))
  # Observe only the real append-open sharing catch in the synthetic copy.
  # No retry budget, delay, acquisition or producer code is changed.
  $needle='if (-not $sharingViolation) { throw }'
  Assert-Retry (($source.Split([string[]]@($needle),[StringSplitOptions]::None).Count-1) -eq 1) 'sharing retry counter seam is not unique'
  $counter=@'
$retryKey=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($Path))))
[IO.File]::AppendAllText((Join-Path '__RETRY_DIRECTORY__' ($retryKey+'.txt')), "retry`n")
'@
  $counter=$counter.Replace('__RETRY_DIRECTORY__',$retryDirectory.Replace("'","''"))
  $source=$source.Replace($needle,$needle+"`n"+$counter)
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

  $appendRunner=Join-Path $root 'append-runner.ps1'
  Write-TestFile $appendRunner @'
param($Logger,$Ledger,[int]$Appends,$Receipts)
$ErrorActionPreference='Stop'
[Diagnostics.Process]::GetCurrentProcess().PriorityClass='BelowNormal'
try {
  foreach ($index in 1..$Appends) {
    & $Logger -Log dispatch -Kind scale -Issue ($index+1) -Note 'synthetic held-reader append' -OutFile $Ledger -NoBoard
    [IO.File]::AppendAllText($Receipts,"$index`n")
  }
} catch {
  [Console]::Error.WriteLine(($_ | Out-String))
  if (($_ | Out-String).Contains('ORCHESTRATION_LOG_SHARING_RETRY_EXHAUSTED')) { exit 74 }
  exit 1
}
exit 0
'@

  if ($Scenario -in @('all','reader-contention','forced-sharing')) {
    $controlLedger=Join-Path $root 'forced-sharing-dispatch-log.jsonl'
    Write-TestFile $controlLedger ''
    $control=$null;$blocker=$null
    $controlOut=Join-Path $EvidenceRoot 'forced-sharing.out.log'
    $controlErr=Join-Path $EvidenceRoot 'forced-sharing.err.log'
    $controlReceipts=Join-Path $EvidenceRoot 'forced-sharing.receipts.txt'
    $controlAttempt=Join-Path $root 'forced-sharing-attempt.txt'
    Write-TestFile $controlReceipts ''
    try {
      $blocker=[IO.File]::Open($controlLedger,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
      $control=Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -WindowStyle Hidden -PassThru `
        -ArgumentList @('-NoProfile','-NonInteractive','-File',$appendRunner,$logger,$controlLedger,1,$controlReceipts) `
        -RedirectStandardOutput $controlOut -RedirectStandardError $controlErr -Environment @{SYNTHETIC_8604_ATTEMPT=$controlAttempt}
      # Startup/import latency is not a speed gate. Keep the blocker until an
      # observed catch, with only a bounded hang timeout for this private child.
      $deadline=[datetime]::UtcNow.AddSeconds(60)
      while ((Get-TestRetryCount $controlLedger) -eq 0 -and -not $control.HasExited -and [datetime]::UtcNow -lt $deadline) { [Threading.Thread]::Sleep(10) }
      Assert-Retry ((Get-TestRetryCount $controlLedger) -gt 0) "forced-sharing control never executed the real sharing catch; appendAttempt=$([IO.File]::Exists($controlAttempt)) exit=$($control.ExitCode)"
      Assert-Retry ((Get-Item -LiteralPath $controlLedger).Length -eq 0 -and [IO.File]::ReadAllLines($controlReceipts).Count -eq 0) 'forced-sharing control appended while blocked'
      $blocker.Dispose();$blocker=$null
      Assert-Retry ($control.WaitForExit(45000)) 'forced-sharing append exceeded bounded worker wait'
      $controlRows=@(Get-Content -LiteralPath $controlLedger | ConvertFrom-Json -DateKind String)
      Assert-Retry ($control.ExitCode -eq 0 -and $controlRows.Count -eq 1 -and $controlRows[0].issue -eq 2 -and [IO.File]::ReadAllLines($controlReceipts).Count -eq 1) 'forced-sharing append did not recover exactly once'
      Write-Output "PASS forced-sharing exit=$($control.ExitCode) persisted=1 appendSharingRetries=$(Get-TestRetryCount $controlLedger) counterSeam=real-sharing-catch timingGate=none"
    } finally {
      if ($blocker) { $blocker.Dispose() }
      if ($control) {
        if (-not $control.HasExited -and -not $control.WaitForExit(45000)) { $control.Kill($true);$control.WaitForExit() }
        Write-TestFile (Join-Path $EvidenceRoot 'forced-sharing.state.json') (@{exitCode=$control.ExitCode;appendAttempt=[IO.File]::Exists($controlAttempt);appendSharingRetries=(Get-TestRetryCount $controlLedger);receipts=[IO.File]::ReadAllLines($controlReceipts).Count} | ConvertTo-Json)
        if ([IO.File]::Exists((Get-TestRetryPath $controlLedger))) { [IO.File]::Copy((Get-TestRetryPath $controlLedger),(Join-Path $EvidenceRoot 'forced-sharing.retry-events.txt'),$true) }
        $control.Dispose()
      }
    }
  }

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
    # Exercise the available store, not a second implementation of cache state.
    # One held owner resumes the stored prefix; the other is a cold owner.
    $checkpointModule=Join-Path $scripts 'dispatch-history-checkpoint.psm1'
    Import-Module $checkpointModule -Force -DisableNameChecking
    $seedHistory=Read-DispatchCountHistory -Path $ledger
    $publication=Publish-DispatchHistoryCheckpoint -Path $ledger -History $seedHistory
    Assert-Retry $publication.published 'contention fixture checkpoint seed was not published'
    $readers=[Collections.Generic.List[object]]::new()
    $writer=$null
    $captures=@();$heldAtStart=0;$heldAtPersistence=0;$completeCursors=0
    $writerOut=Join-Path $EvidenceRoot 'reader-contention.out.log'
    $writerErr=Join-Path $EvidenceRoot 'reader-contention.err.log'
    $receipts=Join-Path $EvidenceRoot 'reader-contention.receipts.txt'
    $writerAttempt=Join-Path $root 'reader-contention-attempt.txt'
    Write-TestFile $receipts ''
    try {
      foreach ($index in 1..2) {
        $directory=Join-Path $root "reader-$index";[void][IO.Directory]::CreateDirectory($directory)
        $marker=Join-Path $directory 'opened';$copy=Join-Path $directory 'dispatch-ledger-reader.psm1'
        $source=[IO.File]::ReadAllText($readerModule)
        $needle='$reader=[DispatchHistoryStreaming.ReaderV1]::new($stream,$length,$prefixLength)'
        Assert-Retry (($source.Split([string[]]@($needle),[StringSplitOptions]::None).Count-1) -eq 1) 'held-open captured streaming owner seam is not unique'
        $pause=@'
[IO.File]::WriteAllText('__MARKER__', (@{length=$length;readerType=$reader.GetType().FullName;handleOpen=(-not $stream.SafeFileHandle.IsClosed)} | ConvertTo-Json))
$deadline=[datetime]::UtcNow.AddSeconds(180)
while (-not [IO.File]::Exists('__RELEASE__')) {
  if ([datetime]::UtcNow -ge $deadline) { throw 'reader barrier expired' }
  [Threading.Thread]::Sleep(10)
}
'@
        $pause=$pause.Replace('__MARKER__',$marker.Replace("'","''")).Replace('__RELEASE__',$release.Replace("'","''"))
        Write-TestFile $copy ($source.Replace($needle,$needle+"`n"+$pause))
        $checkpointCopy=Join-Path $directory 'dispatch-history-checkpoint.psm1'
        [IO.File]::Copy($checkpointModule,$checkpointCopy)
        $shell=[powershell]::Create()
        [void]$shell.AddScript({param($module,$path,$checkpointModule,$useCheckpoint)
          $ErrorActionPreference='Stop'
          if ($useCheckpoint) {
            Import-Module $checkpointModule -Force -DisableNameChecking
            $stored=Read-DispatchHistoryCheckpoint -Path $path
            if ($stored.state -cne 'valid') { throw 'contention checkpoint prefix unavailable' }
            Read-DispatchCountHistory -Path $path -PrefixHistory $stored.checkpoint
          } else { Import-Module $module -Force; Read-DispatchCountHistory -Path $path }
        }).AddArgument($copy).AddArgument($ledger).AddArgument($checkpointCopy).AddArgument(($index -eq 2))
        $pending=$shell.BeginInvoke();$readers.Add(@{shell=$shell;pending=$pending;marker=$marker;module=$copy})
      }
      $deadline=[datetime]::UtcNow.AddSeconds(30)
      while (@($readers | Where-Object { -not [IO.File]::Exists($_.marker) }).Count -and [datetime]::UtcNow -lt $deadline) { [Threading.Thread]::Sleep(10) }
      $heldAtStart=@($readers | Where-Object { [IO.File]::Exists($_.marker) -and -not $_.pending.IsCompleted }).Count
      Assert-Retry ($heldAtStart -eq 2) 'N=2 full readers not genuinely held open'
      foreach ($reader in $readers) {
        $capture=[IO.File]::ReadAllText($reader.marker) | ConvertFrom-Json
        $captures+=$capture
        Assert-Retry ($capture.length -eq $initialLength -and $capture.handleOpen -and $capture.readerType -ceq 'DispatchHistoryStreaming.ReaderV1') 'reader barrier did not capture the actual open streaming owner'
      }
      Assert-Retry ((Get-TestRetryCount $ledger) -eq 0) 'contention counter not initially zero'
      $writer=Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -WindowStyle Hidden -PassThru `
        -ArgumentList @('-NoProfile','-NonInteractive','-File',$appendRunner,$logger,$ledger,2,$receipts) `
        -RedirectStandardOutput $writerOut -RedirectStandardError $writerErr -Environment @{SYNTHETIC_8604_ATTEMPT=$writerAttempt}
      # Bound bootstrap separately from the unchanged 30-second producer retry
      # budget. Otherwise a slow native import can make the RED control recover
      # during cleanup before it ever exercises exhaustion.
      $deadline=[datetime]::UtcNow.AddSeconds(60)
      while (-not [IO.File]::Exists($writerAttempt) -and -not $writer.HasExited -and [datetime]::UtcNow -lt $deadline) { [Threading.Thread]::Sleep(10) }
      Assert-Retry ([IO.File]::Exists($writerAttempt)) 'native append worker never reached append after bounded bootstrap'
      Assert-Retry ($writer.WaitForExit(45000)) 'append worker did not finish while readers held open'
      $writerError=[IO.File]::ReadAllText($writerErr)
      Assert-Retry ($writer.ExitCode -eq 0 -and $writerError -notmatch 'ORCHESTRATION_LOG_SHARING_RETRY_EXHAUSTED') "held-reader append refused or exhausted sharing retries (old direct-open/share RED control): exit=$($writer.ExitCode) appendSharingRetries=$(Get-TestRetryCount $ledger) $writerError"
      $heldAtPersistence=@($readers | Where-Object { -not $_.pending.IsCompleted }).Count
      Assert-Retry ($heldAtPersistence -eq 2) 'readers released before append completion'
      Assert-Retry (-not [IO.File]::Exists($release)) 'reader barrier released before persistence'
      Assert-Retry ([IO.File]::ReadAllLines($receipts).Count -eq 2) 'actual log-event append calls did not both return'
      $persisted=@(Get-Content -LiteralPath $ledger | ConvertFrom-Json -DateKind String)
      Assert-Retry (($persisted.issue -join ',') -ceq '1,2,3') 'both actual appends were not persisted while readers held open'
      Assert-Retry ((Get-TestRetryCount $ledger) -eq 0) 'shared streaming readers caused actual append sharing retries'
      Write-TestFile $release 'release after both persisted appends'
      foreach ($reader in $readers) {
        Assert-Retry ($reader.pending.AsyncWaitHandle.WaitOne(10000)) 'full reader failed to complete'
        $history=@($reader.shell.EndInvoke($reader.pending))[-1]
        Assert-Retry (-not $reader.shell.HadErrors -and $history.complete -and $history.cursor -eq $initialLength -and $history.rows.Count -eq 1) 'held reader returned torn/incomplete captured prefix'
        $reader.shell.Commands.Clear()
        [void]$reader.shell.AddScript({param($path) Read-DispatchCountHistory -Path $path}).AddArgument($ledger)
        $reader.pending=$reader.shell.BeginInvoke()
        Assert-Retry ($reader.pending.AsyncWaitHandle.WaitOne(10000)) 'final reader exceeded bounded worker wait'
        $final=@($reader.shell.EndInvoke($reader.pending))[-1]
        Assert-Retry ($final.complete -and $final.rows.Count -eq 3 -and $final.cursor -eq (Get-Item -LiteralPath $ledger).Length -and -not $final.partialTrailingRow) 'reader final cursor omitted persisted append'
        Assert-Retry ((@($final.rows | ForEach-Object { $_.value.issue }) -join ',') -ceq '1,2,3') 'append lost or duplicated'
        $completeCursors++
      }
      Write-Output "PASS reader-contention heldFullReaders=$heldAtPersistence streamingOwner=ReaderV1 checkpointReaders=1 appends=2 persisted=2 completeCursors=$completeCursors exit=$($writer.ExitCode) appendSharingRetries=$(Get-TestRetryCount $ledger) timingGate=none"
    } finally {
      Write-TestFile $release 'release on failure'
      if ($writer) {
        if (-not $writer.HasExited -and -not $writer.WaitForExit(45000)) { $writer.Kill($true);$writer.WaitForExit() }
        Write-TestFile (Join-Path $EvidenceRoot 'reader-contention.state.json') (@{exitCode=$writer.ExitCode;appendAttempt=[IO.File]::Exists($writerAttempt);appendSharingRetries=(Get-TestRetryCount $ledger);receipts=[IO.File]::ReadAllLines($receipts).Count;heldReadersAtStart=$heldAtStart;heldReadersAtPersistence=$heldAtPersistence;completeCursors=$completeCursors;streamingCaptures=$captures;checkpointReaders=1;initialLength=$initialLength} | ConvertTo-Json -Depth 5)
        if ([IO.File]::Exists((Get-TestRetryPath $ledger))) { [IO.File]::Copy((Get-TestRetryPath $ledger),(Join-Path $EvidenceRoot 'reader-contention.retry-events.txt'),$true) }
        [IO.File]::Copy($ledger,(Join-Path $EvidenceRoot 'reader-contention.ledger.jsonl'),$true)
        $writer.Dispose()
      }
      foreach ($reader in $readers) { if (-not $reader.pending.IsCompleted -and -not $reader.pending.AsyncWaitHandle.WaitOne(10000)) { $reader.shell.Stop() };$reader.shell.Dispose() }
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
      # Native initialization is not the append-retry budget measured below.
      # Use the same bounded bootstrap guard as the other native workers.
      $deadline = [datetime]::UtcNow.AddSeconds(60)
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
        if (-not $process.HasExited -and -not $process.WaitForExit(45000)) { $process.Kill($true);$process.WaitForExit() }
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
    $redEvidence=Join-Path $EvidenceRoot 'old-reader-share'
    & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -NonInteractive -File $PSCommandPath -Scenario reader-contention -Mutant reader-share -EvidenceRoot $redEvidence *> $redOutput
    $redExit=$LASTEXITCODE
    Assert-Retry ($redExit -ne 0 -and [IO.File]::ReadAllText($redOutput).Contains('ORCHESTRATION_LOG_SHARING_RETRY_EXHAUSTED')) 'old direct-open/share RED control did not discriminate'
    $redState=Get-Content -LiteralPath (Join-Path $redEvidence 'reader-contention.state.json') -Raw | ConvertFrom-Json
    Assert-Retry ($redState.exitCode -eq 74 -and $redState.appendSharingRetries -gt 0 -and $redState.receipts -eq 0) 'reader-share RED control did not exercise counted native append exhaustion'
    Write-Output "KILLED old-direct-open/share fullReaders=2 exit=$redExit writerExit=$($redState.exitCode) appendSharingRetries=$($redState.appendSharingRetries) log=$redOutput"
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
