[CmdletBinding()]
param(
  [ValidateSet('supervisor','queue','transient','mutants')][string]$Part = '',
  [ValidateSet('','direct-host','stale-result','verifier-override','interruption-reclaims-owner','clocks','single-shot','fresh-ticket','no-cap','non-atomic-ready','replacement-line','census-immediate','temp-cleanup')][string]$Mutant = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'suite-parts.ps1')
Assert-SuiteSelection $Part @((Get-LongProductGatePartMap).Keys) $PSBoundParameters @('Mutant')
if ($Mutant -and $Part) { throw 'SUITE_PART: Mutant conflicts with Part' }

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}
function Invoke-CheckedGit([string]$At, [string[]]$Arguments) {
  $output = @(& git -C $At @Arguments 2>&1)
  if ($LASTEXITCODE -ne 0) { throw "fixture git failed: git $($Arguments -join ' ')`n$($output -join "`n")" }
  return ($output -join "`n").Trim()
}
function Write-Text([string]$Path, [string]$Text) {
  [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}
function Read-SharedText([string]$Path) {
  $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
  try { $reader = [IO.StreamReader]::new($stream); try { return $reader.ReadToEnd() } finally { $reader.Dispose() } } finally { $stream.Dispose() }
}
function Wait-ForPathOrExit([string]$Path, [Diagnostics.Process]$Process, [string]$Message) {
  while (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    if ($Process.HasExited) { throw "$Message; process exited $($Process.ExitCode)" }
    Start-Sleep -Milliseconds 25
  }
}
function Assert-NoVerifierOverride([string[]]$Paths) {
  $matches = @($Paths | ForEach-Object {
    if (Test-Path -LiteralPath $_ -PathType Leaf) {
      Select-String -LiteralPath $_ -Pattern 'LongProductGateTestVerifierPath|TestVerifierPath|TestMode' -SimpleMatch:$false
    }
  })
  Assert-True ($matches.Count -eq 0) 'production long-gate scripts expose a verifier override'
}
function Remove-LongGateTempRoot([string]$Path, [switch]$DoubleSeparator) {
  $resolved = [IO.Path]::GetFullPath($Path)
  $tempPrefix = if ($DoubleSeparator) {
    [IO.Path]::GetFullPath([IO.Path]::GetTempPath()) + [IO.Path]::DirectorySeparatorChar
  } else {
    [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
  }
  if ($resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
  }
}
function Assert-LongGateTempCleanup([string]$TempRoot, [string]$ControllerRoot, [switch]$Mutant) {
  $inside = Join-Path $TempRoot ('long-product-gate-cleanup-assertion-' + [guid]::NewGuid().ToString('N'))
  $outside = Join-Path $ControllerRoot ('.long-product-gate-cleanup-outside-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $inside, $outside | Out-Null
  try {
    Remove-LongGateTempRoot $inside -DoubleSeparator:$Mutant
    Assert-True (-not (Test-Path -LiteralPath $inside)) 'long-product-gate temp root is gone after cleanup'
    Remove-LongGateTempRoot $outside
    Assert-True (Test-Path -LiteralPath $outside) 'long-product-gate cleanup refuses path outside TEMP'
  } finally {
    if (Test-Path -LiteralPath $inside) { Remove-Item -LiteralPath $inside -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $outside) { Remove-Item -LiteralPath $outside -Recurse -Force -ErrorAction SilentlyContinue }
  }
  if ($Mutant) { Write-Output 'PASS MUTANT temp-cleanup killed at long-product-gate temp root is gone after cleanup' }
}
function New-ControllerScriptFixture([string]$Root) {
  $orchestrator = Join-Path $Root '.orchestrator'
  Copy-Item -LiteralPath (Join-Path $controllerRoot '.orchestrator') -Destination $orchestrator -Recurse
  $child = @'
param([string]$ReadyPath,[string]$ReleasePath,[string]$PublishBarrier)
$ready = [ordered]@{ pid = $PID; parentPid = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID").ParentProcessId; startedUtc = [DateTime]::UtcNow.ToString('o') }
$readyTemporary = "$ReadyPath.$PID.tmp"
$stream = [IO.File]::Open($readyTemporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try {
  $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($ready | ConvertTo-Json -Compress))
  $stream.Write($bytes); $stream.Flush($true)
  if ($PublishBarrier) {
    [IO.File]::WriteAllText("$PublishBarrier.open", 'writer open')
    while (-not [IO.File]::Exists($PublishBarrier)) { Start-Sleep -Milliseconds 25 }
  }
} finally { $stream.Dispose() }
if ($readyTemporary -cne $ReadyPath) { [IO.File]::Move($readyTemporary, $ReadyPath, $true) }
while (-not [IO.File]::Exists($ReleasePath)) { Start-Sleep -Milliseconds 25 }
exit 0
'@
  Write-Text (Join-Path $orchestrator 'fixture-heavy-child.ps1') $child
  $verifierPath = Join-Path $orchestrator 'invoke-heavy-verifier.ps1'
  $verifier = [IO.File]::ReadAllText($verifierPath)
  $needle = '$ownerGate = if ($isNativeDb) {'
  $needleCount = ([regex]::Matches($verifier, [regex]::Escape($needle))).Count
  Assert-True ($needleCount -eq 1) 'fixture verifier command-table seam occurs exactly once'
  $replacement = @"
if (`$Gate -ceq 'test:scripts') {
  `$command = (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1 -ExpandProperty Source)
  `$arguments = @('-NoProfile','-NonInteractive','-File',(Join-Path `$container '.orchestrator/fixture-heavy-child.ps1'),(Join-Path `$container ".orchestrator/fixture-child-ready-`$Lane.txt"),(Join-Path `$container ".orchestrator/fixture-child-release-`$Lane.txt"))
}
$needle
"@
  $fixtureVerifier = $verifier.Replace($needle, $replacement)
  Assert-True ($fixtureVerifier -cne $verifier -and ([regex]::Matches($fixtureVerifier, [regex]::Escape($replacement))).Count -eq 1) 'fixture verifier uses the exact real gate command-table replacement'
  Write-Text $verifierPath $fixtureVerifier
  return $orchestrator
}
function New-LongGateFixture([string]$Root, [string]$Lane = 'lane-23') {
  $runtime = Join-Path $Root '.orchestrator'; $worktree = Join-Path $Root $Lane
  New-Item -ItemType Directory -Path $worktree -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $worktree '.orchestrator/artifacts') -Force | Out-Null
  Invoke-CheckedGit $worktree @('init','--initial-branch=synthetic/long-gate') | Out-Null
  Invoke-CheckedGit $worktree @('config','user.name','Long Product Gate Test') | Out-Null
  Invoke-CheckedGit $worktree @('config','user.email','long-product-gate@example.invalid') | Out-Null
  Write-Text (Join-Path $worktree 'seed.txt') 'seed'
  Invoke-CheckedGit $worktree @('add','--','seed.txt') | Out-Null
  Invoke-CheckedGit $worktree @('commit','-m','seed') | Out-Null
  [pscustomobject]@{
    root = $Root; runtime = $runtime; worktree = $worktree; branch = (Invoke-CheckedGit $worktree @('branch','--show-current'))
    head = (Invoke-CheckedGit $worktree @('rev-parse','HEAD')); orchestrator = (Join-Path $Root '.orchestrator')
    ready = (Join-Path $runtime "fixture-child-ready-$Lane.txt"); release = (Join-Path $runtime "fixture-child-release-$Lane.txt")
  }
}
function Invoke-LongGateProcess($Fixture, [string]$Supervisor, [string]$LaunchId, [string]$ResultPath, [switch]$Preseed, [switch]$NoWait) {
  $prompt = Join-Path $Fixture.runtime "dispatch-heavy-verifier-$LaunchId.prompt.txt"
  $transcript = Join-Path $Fixture.runtime "synthetic-long-gate.jsonl"
  Write-Text $prompt 'synthetic prompt'; Write-Text $transcript ''
  if ($Preseed) { Write-Text $ResultPath '{"schema":"foreign-result/v1","status":"passed"}' }
  $runner = Join-Path $Fixture.root "runner-$LaunchId.ps1"
  $ownership = Join-Path $Fixture.runtime "dispatch-launch-$LaunchId.json"
  $module = Join-Path $Fixture.orchestrator 'dispatch-ownership.ps1'
  $runnerSource = @'
param($Module,$Supervisor,$Runtime,$Worktree,$Lane,$Branch,$Head,$LaunchId,$Result)
$ErrorActionPreference='Stop'; . $Module
$logger=Join-Path (Split-Path -Parent $Supervisor) 'log-event.ps1'
& $logger -Log dispatch -Kind dispatch -Issue 90230 -DispatchRoutingSchema watchdog-dispatch-routing/v2 -DispatchAttemptId $LaunchId -DispatchLabel synthetic-long-gate -Lane $Lane -LaneRole implementation -Transcript 'synthetic-long-gate.jsonl' -Harness codex -Model gpt-6.1-sol -Effort high -Row 4 -Placement provisional -DispatchWorktree $Worktree -DispatchBranch $Branch -DispatchHead $Head -PolicyGeneration 1 -RegistryAuthorityDigest synthetic-consumer-authority -RoutingFamily sol -RoutingSlot codex.primary -UsedLastKnownGood $false -RoutingStateRoot $env:CHASE_SETS_ROUTING_DATA_ROOT -RoutingLkgPath $env:CHASE_SETS_ROUTING_LKG_PATH -OutFile (Join-Path $Runtime 'dispatch-log.jsonl') -NoBoard | Out-Null
$childOut=Join-Path $Runtime "child-$LaunchId.out";$childErr=Join-Path $Runtime "child-$LaunchId.err"
$child=Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList @('-NoProfile','-NonInteractive','-File',$Supervisor,'-RuntimeRoot',$Runtime,'-LaunchId',$LaunchId,'-Worktree',$Worktree,'-Lane','lane-23','-Branch',$Branch,'-ClaimedHead',$Head,'-ResultPath',$Result) -RedirectStandardOutput $childOut -RedirectStandardError $childErr -WindowStyle Hidden -PassThru
$ownership=Join-Path $Runtime "dispatch-launch-$LaunchId.json"
$record=[ordered]@{schemaVersion=4;launchId=$LaunchId;laneRole='implementation';promptPath=(Join-Path $Runtime "dispatch-heavy-verifier-$LaunchId.prompt.txt");reviewIsolationRoot=$null;launcherPid=$PID;launcherStartIdentity=(Get-DispatchProcessStartIdentity $PID);recordedAt=[DateTime]::UtcNow.ToString('o');state='started';childPid=$child.Id;childStartIdentity=(Get-DispatchProcessStartIdentity $child.Id);worktree=$Worktree;lane=$Lane;identityMode='branch';branch=$Branch;head=$Head;label='synthetic-long-gate';transcriptPath=(Join-Path $Runtime 'synthetic-long-gate.jsonl')}
if ([string]::IsNullOrWhiteSpace($ownership)) { throw 'synthetic runner ownership path is empty' }
Write-DispatchOwnershipRecord ([string]$ownership) $record -CreateNew
$child.WaitForExit(); if($child.ExitCode -ne 0){Write-Error (Get-Content -Raw $childErr)}; exit $child.ExitCode
'@
  Write-Text $runner $runnerSource
  $arguments = @('-NoProfile','-NonInteractive','-File',$runner,'-Module',$module,'-Supervisor',$Supervisor,'-Runtime',$Fixture.runtime,'-Worktree',$Fixture.worktree,'-Lane','lane-23','-Branch',$Fixture.branch,'-Head',$Fixture.head,'-LaunchId',$LaunchId,'-Result',$ResultPath)
  $out = Join-Path $Fixture.root "runner-$LaunchId.out"; $err = Join-Path $Fixture.root "runner-$LaunchId.err"
  $process = Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList $arguments -RedirectStandardOutput $out -RedirectStandardError $err -WindowStyle Hidden -PassThru
  if ($NoWait) { return [pscustomobject]@{ process=$process; result=$ResultPath; ownership=$ownership; output=$out; error=$err } }
  $process.WaitForExit()
  if ($process.ExitCode -ne 0) { Write-Output "RUNNER_OBSERVED launch=$LaunchId exit=$($process.ExitCode) stderr=$([IO.File]::ReadAllText($err))" }
  return [int]$process.ExitCode
}
function Wait-ProcessPath([string]$Path, [Diagnostics.Process]$Process, [string]$Message) {
  while ($true) {
    Wait-ForPathOrExit $Path $Process $Message
    $value = $null
    try { $value = Read-SharedText $Path | ConvertFrom-Json -DateKind String } catch {}
    if ($null -ne $value) { return $value }
    if ($Process.HasExited) { throw "$Message; process exited before a complete JSON publication" }
    Start-Sleep -Milliseconds 25
  }
}
function Stop-ExactStartedProcess([Diagnostics.Process]$Process) {
  if ($Process -and -not $Process.HasExited) { $Process.Kill(); $Process.WaitForExit() }
}
function Invoke-InterruptionCase($Fixture, [switch]$Mutant) {
  foreach ($path in @($Fixture.ready,$Fixture.release)) {
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
  }
  $label = 'interruption-' + [guid]::NewGuid().ToString('N')
  $request = [guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')
  $ackPath = Join-Path $Fixture.runtime "dispatch-start-$request.json"
  $prompt = Join-Path $Fixture.runtime "$label.prompt.txt"; Write-Text $prompt 'synthetic interruption prompt'
  $arguments = @('-NoProfile','-NonInteractive','-File',(Join-Path $Fixture.orchestrator 'dispatch-lane.ps1'),'-Harness','codex','-Model','gpt-6.1-sol','-Effort','high','-LaneRole','implementation','-Row','4','-Placement','provisional',
    '-Issue','90230','-PromptFile',$prompt,'-Worktree',$Fixture.worktree,'-Label',$label,'-ExecutablePath',(Join-Path $PSHOME 'pwsh.exe'),
    '-LongProductGate','-TestRuntimeRoot',$Fixture.runtime,'-TestTempRoot',$testRoot,'-StartRequestIdentity',$request,'-StartAcknowledgementPath',$ackPath)
  $hostProcess = Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList $arguments -RedirectStandardOutput (Join-Path $Fixture.root "$label.out") -RedirectStandardError (Join-Path $Fixture.root "$label.err") -WindowStyle Hidden -PassThru
  $supervisorProcess = $null; $verifierProcess = $null; $nativeProcess = $null
  try {
    $ack = Wait-ProcessPath $ackPath $hostProcess 'interruption dispatch acknowledgement was not published'
    $recordPath = $ack.ownershipRecordPath; $result = $ack.longProductGate.resultPath
    $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json -DateKind String
    $ready = Wait-ProcessPath $Fixture.ready $hostProcess 'real verifier native child was not running before interruption'
    $slotOwnerPath = Join-Path $Fixture.runtime 'verify-lock.d/owner.json'
    $slotOwner = Wait-ProcessPath $slotOwnerPath $hostProcess 'real verifier slot owner was not published before interruption'
    $supervisorProcess = Get-Process -Id ([int]$record.childPid) -ErrorAction Stop
    $verifierProcess = Get-Process -Id ([int]$slotOwner.pid) -ErrorAction Stop
    $nativeProcess = Get-Process -Id ([int]$ready.pid) -ErrorAction Stop
    $ownerBefore = [IO.File]::ReadAllText($recordPath)
    $historyPath = Join-Path $Fixture.runtime 'dispatch-log.jsonl'; $historyBefore = [IO.File]::ReadAllText($historyPath)
    $hostProcess.Kill(); $hostProcess.WaitForExit()
    $hostProcess.Dispose(); $hostProcess = $null
    . (Join-Path $Fixture.orchestrator 'dispatch-ownership.ps1')
    while ((Get-DispatchProcessIdentityState $record.launcherPid $record.launcherStartIdentity) -cne 'dead') { Start-Sleep -Milliseconds 25 }
    if ($Mutant) {
      $definition = Get-TestDefinition (Join-Path $Fixture.orchestrator 'dispatch-ownership.ps1') 'Invoke-DispatchOwnershipScavenge'
      $needle = 'if ($childState -notin @("live", "dead", "ambiguous") -or $childState -ne "dead") {'
      Assert-True (($definition.Split(@($needle),[StringSplitOptions]::None)).Count -eq 2) 'interruption reclaim mutant changes exactly one live-child guard'
      $replacement = $needle + "`r`n" + '        Remove-Item -LiteralPath $candidate.FullName -Force'
      . ([scriptblock]::Create($definition.Replace($needle, $replacement)))
    }
    $scavenge = Invoke-DispatchOwnershipScavenge $Fixture.runtime $testRoot
    Write-Output "INTERRUPTION_SCAVENGE mutant=$Mutant removed=$($scavenge.removed) preserved=$($scavenge.preserved) rejected=$($scavenge.rejected)"
    $failure = $null
    try { Assert-True ($scavenge.removed -eq 0 -and $scavenge.preserved -eq 1 -and (Test-Path -LiteralPath $recordPath) -and [IO.File]::ReadAllText($recordPath) -ceq $ownerBefore) 'interruption preserves exact dispatch ownership for recovery' } catch { $failure = $_.Exception.Message }
    if ($Mutant) {
      Assert-True ($failure -like '*ASSERTION FAILED: interruption preserves exact dispatch ownership for recovery*') 'MUTANT interruption-reclaims-owner reaches its named preservation assertion'
      Write-Output 'PASS MUTANT interruption-reclaims-owner killed at interruption preserves exact dispatch ownership for recovery'
      return
    }
    if ($failure) { throw $failure }
    $observation = & (Join-Path $Fixture.orchestrator 'lane-stall-watchdog.ps1') -Label $label -RuntimeRoot $Fixture.runtime -HistoryPath $historyPath | ConvertFrom-Json -DateKind String
    Assert-True ($observation.status -ceq 'LIVE_SLOW' -and $observation.relaunch -eq $false) 'interruption watchdog neither kills nor relaunches a live supervised gate'
    $pending = Get-Content -LiteralPath $result -Raw | ConvertFrom-Json -DateKind String
    Assert-True ($pending.status -ceq 'pending' -and $pending.dispatchReleased -eq $false) 'interruption remains incomplete and never publishes PASS'
    Assert-True ((Get-Process -Id ([int]$slotOwner.pid) -ErrorAction SilentlyContinue) -and (Get-Process -Id ([int]$ready.pid) -ErrorAction SilentlyContinue)) 'interruption kills neither verifier nor native child'
    Assert-True ([IO.File]::ReadAllText($historyPath) -ceq $historyBefore) 'interruption consumes no attempt and appends no relaunch row'
    Write-Text $Fixture.release 'release'
    $supervisorProcess.WaitForExit(); $supervisorProcess.Dispose(); $supervisorProcess = $null
    $verifierProcess.WaitForExit(); $nativeProcess.WaitForExit()
    $completed = Get-Content -LiteralPath $result -Raw | ConvertFrom-Json -DateKind String
    Assert-True ($completed.status -ceq 'verifier-passed' -and $completed.dispatchReleased -eq $false) 'interrupted host never promotes a late verifier return to PASS'
    $recovery = Invoke-DispatchOwnershipScavenge $Fixture.runtime $testRoot
    Assert-True ($recovery.removed -eq 1 -and -not (Test-Path -LiteralPath $recordPath) -and -not (Test-Path -LiteralPath (Join-Path $Fixture.runtime 'verify-lock.d'))) 'proven-dead recovery releases exact ownership and slot without PASS'
    Assert-True ([IO.File]::ReadAllText($historyPath) -ceq $historyBefore) 'proven-dead recovery consumes no attempt'
    Write-Output 'PASS AC4 interruption preserves pending result, verifier/native child, ownership and attempt'
  } finally {
    Write-Text $Fixture.release 'release'
    if ($supervisorProcess) { $supervisorProcess.WaitForExit() }
    foreach ($process in @($hostProcess,$supervisorProcess,$verifierProcess,$nativeProcess)) { Stop-ExactStartedProcess $process }
    if ($recordPath -and (Test-Path -LiteralPath $recordPath)) { Remove-Item -LiteralPath $recordPath -Force }
  }
}
function Replace-FixtureOnce([string]$Source, [string]$Needle, [string]$Replacement) {
  Assert-True (([regex]::Matches($Source, [regex]::Escape($Needle))).Count -eq 1) "fixture substitution occurs exactly once: $Needle"
  return $Source.Replace($Needle, $Replacement)
}
function Test-ReadyHandoff($Fixture, [switch]$NonAtomic) {
  $source = [IO.File]::ReadAllText((Join-Path $Fixture.orchestrator 'fixture-heavy-child.ps1'))
  if ($NonAtomic) { $source = Replace-FixtureOnce $source '$readyTemporary = "$ReadyPath.$PID.tmp"' '$readyTemporary = $ReadyPath' }
  $path = Join-Path $Fixture.root ('ready-child-' + [guid]::NewGuid().ToString('N') + '.ps1')
  Write-Text $path $source
  $ready = "$path.ready"; $release = "$path.release"; $publish = "$path.publish"
  $process = Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList @('-NoProfile','-NonInteractive','-File',$path,$ready,$release,$publish) -WindowStyle Hidden -PassThru
  $failure = $null
  try {
    Wait-ForPathOrExit "$publish.open" $process 'ready writer did not reach its publication barrier'
    Assert-True (-not (Test-Path -LiteralPath $ready)) 'ready handoff hides the final path while its exclusive writer is open'
    Write-Text $publish 'publish'
    $value = Wait-ProcessPath $ready $process 'atomic ready publication was not readable'
    Assert-True ($value.pid -eq $process.Id) 'ready handoff publishes complete native-child identity'
  } catch { $failure = $_.Exception.Message } finally {
    Write-Text $publish 'publish'; Write-Text $release 'release'; $process.WaitForExit(); $process.Dispose()
  }
  if ($NonAtomic) {
    Assert-True ($failure -ceq 'ASSERTION FAILED: ready handoff hides the final path while its exclusive writer is open') 'MUTANT non-atomic-ready reaches the named handoff assertion'
    Write-Output 'PASS MUTANT non-atomic-ready killed at ready handoff hides the final path while its exclusive writer is open'
  } else {
    if ($failure) { throw $failure }
    Write-Output 'PASS atomic ready handoff with an exclusive writer held behind a barrier'
  }
}
function Start-FixtureDispatch($Fixture) {
  $request = [guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')
  $label = 'queue-' + [guid]::NewGuid().ToString('N')
  $prompt = Join-Path $Fixture.runtime "$label.prompt.txt"; Write-Text $prompt 'fixture queue dispatch'
  $ackPath = Join-Path $Fixture.runtime "dispatch-start-$request.json"
  $arguments = @('-NoProfile','-NonInteractive','-File',(Join-Path $Fixture.orchestrator 'dispatch-lane.ps1'),'-Harness','codex','-Model','gpt-6.1-sol','-Effort','high','-LaneRole','implementation','-Row','4','-Placement','provisional',
    '-Issue','90230','-PromptFile',$prompt,'-Worktree',$Fixture.worktree,'-Label',$label,'-ExecutablePath',(Join-Path $PSHOME 'pwsh.exe'),
    '-LongProductGate','-TestRuntimeRoot',$Fixture.runtime,'-TestTempRoot',$testRoot,'-StartRequestIdentity',$request,'-StartAcknowledgementPath',$ackPath)
  $process = Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList $arguments -RedirectStandardOutput (Join-Path $Fixture.root "$label.out") -RedirectStandardError (Join-Path $Fixture.root "$label.err") -WindowStyle Hidden -PassThru
  return [pscustomobject]@{process=$process;ackPath=$ackPath;label=$label;ack=$null;supervisor=$null}
}
function Read-FixtureAck($Dispatch) {
  $Dispatch.ack = Wait-ProcessPath $Dispatch.ackPath $Dispatch.process 'queue dispatch acknowledgement was not published'
  $Dispatch.supervisor = Get-Process -Id ([int]$Dispatch.ack.childPid) -ErrorAction SilentlyContinue
}
function Wait-QueuePoll($Fixture, $Dispatch, [int]$Number) {
  $path = Join-Path $Fixture.runtime "fixture-queue-poll-$Number.json"
  while (-not (Test-Path -LiteralPath $path)) {
    if ($Dispatch.process.HasExited) { return $null }
    Start-Sleep -Milliseconds 25
  }
  return Wait-ProcessPath $path $Dispatch.process 'queue poll publication was not complete'
}
function Invoke-QueueCase([string]$Mode, [string]$Mutation = '') {
  $root = Join-Path $fixtureRoot ('queue-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $root | Out-Null
  New-ControllerScriptFixture $root | Out-Null
  $holder = New-LongGateFixture $root 'lane-24'
  $leader = New-LongGateFixture $root 'lane-25'
  $client = New-LongGateFixture $root 'lane-26'
  $supervisorPath = Join-Path $client.orchestrator 'long-product-gate.ps1'
  $original = [IO.File]::ReadAllText($supervisorPath)
  $leaderRelease = Join-Path $client.runtime 'fixture-leader-release.txt'
  $leaderHeld = Join-Path $client.runtime 'fixture-leader-held.txt'
  $holderDispatch = $null; $leaderDispatch = $null; $clientDispatch = $null
  $failure = $null
  try {
    $holderDispatch = Start-FixtureDispatch $holder; Read-FixtureAck $holderDispatch
    Wait-ProcessPath $holder.ready $holderDispatch.process 'real slot holder did not start its native child' | Out-Null
    # An admitted holder has removed its own queue ticket. Keep the first
    # real refused claimant alive, so the client queues behind its reservation.
    $holdLeader = @'
[IO.File]::WriteAllText((Join-Path $runtimeFull 'fixture-leader-held.txt'), 'held')
while (-not [IO.File]::Exists((Join-Path $runtimeFull 'fixture-leader-release.txt'))) { Start-Sleep -Milliseconds 25 }
$retryProcess = [Diagnostics.Process]::Start($start)
$retryOut = $retryProcess.StandardOutput.ReadToEndAsync(); $retryErr = $retryProcess.StandardError.ReadToEndAsync()
$retryProcess.WaitForExit()
[IO.File]::AppendAllText($stdoutPath, $retryOut.GetAwaiter().GetResult())
[IO.File]::AppendAllText($stderrPath, $retryErr.GetAwaiter().GetResult())
$exitCode = $retryProcess.ExitCode; $retryProcess.Dispose()
exit $exitCode
'@
    Write-Text $supervisorPath (Replace-FixtureOnce $original 'exit $exitCode' $holdLeader)
    $leaderDispatch = Start-FixtureDispatch $leader; Read-FixtureAck $leaderDispatch
    Wait-ForPathOrExit $leaderHeld $leaderDispatch.process 'first real refused claimant did not retain its reservation'
    $leaderResult = Wait-ProcessPath $leaderDispatch.ack.longProductGate.resultPath $leaderDispatch.process 'leader refusal was not recorded'
    Assert-True ($leaderResult.status -ceq 'incomplete' -and $leaderResult.exit -eq 73) 'real occupied slot refuses the first live claimant'

    $clockPath = Join-Path $client.runtime 'fixture-queue-clock.txt'; Write-Text $clockPath '0'
    $clock = @'
$queueWatch = [pscustomobject]@{}
$queueWatch | Add-Member -NotePropertyName StartedAt -NotePropertyValue ([double][IO.File]::ReadAllText((Join-Path $runtimeFull 'fixture-queue-clock.txt')))
$queueWatch | Add-Member -MemberType ScriptProperty -Name Elapsed -Value { [TimeSpan]::FromSeconds([double][IO.File]::ReadAllText((Join-Path $runtimeFull 'fixture-queue-clock.txt')) - $this.StartedAt) }
'@
    $poll = @'
$fixturePoll = 1 + $fixturePoll
$pollPath = Join-Path $runtimeFull "fixture-queue-poll-$fixturePoll.json"
$pollValue = @{ticket=$presentedTicket;pid=$PID;arguments=@($start.ArgumentList)} | ConvertTo-Json -Compress
[IO.File]::WriteAllText("$pollPath.tmp", $pollValue)
[IO.File]::Move("$pollPath.tmp", $pollPath)
while (-not [IO.File]::Exists("$pollPath.continue")) { Start-Sleep -Milliseconds 25 }
'@
    $queueWatchBlock = "    if (-not `$queueWatch) {`r`n      `$queueWatch = [Diagnostics.Stopwatch]::StartNew()`r`n    }`r`n    if (`$null -eq `$queueTicket) {`r`n      `$queueTicket = `$presentedTicket`r`n    }"
    $clockBody = $clock.Trim("`r", "`n")
    $clockBlock = "    if (-not `$queueWatch) {`r`n" + $clockBody + "`r`n    }`r`n    if (`$null -eq `$queueTicket) {`r`n      `$queueTicket = `$presentedTicket`r`n    }"
    $copy = Replace-FixtureOnce $original $queueWatchBlock $clockBlock
    $copy = Replace-FixtureOnce $copy '$presentationWatch = [Diagnostics.Stopwatch]::StartNew()' ($clock.Replace('$queueWatch', '$presentationWatch'))
    $copy = Replace-FixtureOnce $copy "      [Threading.Thread]::Sleep(`$queueSleepMilliseconds)`r`n      continue" ('      $null = $queueSleepMilliseconds' + "`r`n      continue")
    $copy = Replace-FixtureOnce $copy "    [Threading.Thread]::Sleep(`$queueSleepMilliseconds)" ($poll.TrimEnd("`r", "`n"))
    if ($Mode -ceq 'expire-admit') {
      $firstRefusal = @'
$process.WaitForExit()
if (-not $queueTicket) {
  [IO.File]::WriteAllText((Join-Path $runtimeFull 'fixture-first-refusal.txt'), 'refused')
  while (-not [IO.File]::Exists((Join-Path $runtimeFull 'fixture-first-refusal.continue'))) { Start-Sleep -Milliseconds 25 }
}
'@
      $copy = Replace-FixtureOnce $copy '$process.WaitForExit()' $firstRefusal
    }
    if ($Mutation -ceq 'single-shot') {
      $copy = Replace-FixtureOnce $copy 'if ($exitCode -ne 73 -or -not $presentationError.StartsWith' 'if ($true -or $exitCode -ne 73 -or -not $presentationError.StartsWith'
    }
    if ($Mutation -ceq 'no-cap') {
      $copy = Replace-FixtureOnce $copy 'if ($queueWatch -and $queueWatch.Elapsed.TotalSeconds -ge $queueWaitCapSeconds)' 'if ($false)'
    }
    if ($Mutation -ceq 'replacement-line') {
      $copy = Replace-FixtureOnce $copy 'if ($replacementPossible)' 'if ($false)'
    }
    if ($Mutation -ceq 'fresh-ticket') {
      $discardReservation = @'
while (-not [IO.File]::Exists("$pollPath.continue")) { Start-Sleep -Milliseconds 25 }
if ($fixturePoll -eq 1) {
  $queueFile = Join-Path $runtimeFull 'verify-queue.json'
  $queue = [IO.File]::ReadAllText($queueFile) | ConvertFrom-Json -DateKind String
  $queue.tickets = @($queue.tickets | Where-Object number -NE ([long]$presentedTicket))
  [IO.File]::WriteAllText($queueFile, ($queue | ConvertTo-Json -Depth 10 -Compress))
}
'@
      $copy = Replace-FixtureOnce $copy 'while (-not [IO.File]::Exists("$pollPath.continue")) { Start-Sleep -Milliseconds 25 }' $discardReservation
    }
    Write-Text $supervisorPath $copy
    $clientDispatch = Start-FixtureDispatch $client; Read-FixtureAck $clientDispatch
    if ($Mode -ceq 'expire-admit') {
      Wait-ForPathOrExit (Join-Path $client.runtime 'fixture-first-refusal.txt') $clientDispatch.process 'real verifier did not reach the first queued refusal barrier'
      Write-Text $clockPath '601'
      Write-Text (Join-Path $client.runtime 'fixture-first-refusal.continue') 'continue'
    }
    $first = Wait-QueuePoll $client $clientDispatch 1
    Assert-True ($null -ne $first) 'queued gate re-presents instead of finalizing its first queued refusal'
    $pendingPath = $clientDispatch.ack.longProductGate.resultPath
    $pendingBytes = Read-SharedText $pendingPath
    $pending = $pendingBytes | ConvertFrom-Json -DateKind String
    Assert-True ($pending.status -ceq 'pending' -and $null -eq $pending.exit) 'queued refusal leaves the result pending'
    $stderrPath = Join-Path $client.runtime "long-product-gate-$($clientDispatch.ack.launchId).stderr.log"
    $queuePath = Join-Path $client.runtime 'verify-queue.json'
    $queueBefore = Read-SharedText $queuePath
    $queue = $queueBefore | ConvertFrom-Json -DateKind String
    $ticketBefore = @($queue.tickets | Where-Object number -EQ ([long]$first.ticket))[0]
    Assert-True ($ticketBefore.pid -eq $clientDispatch.supervisor.Id -and $ticketBefore.claimantKey -like "launch:$($clientDispatch.ack.launchId)*") 'real queue ticket belongs to the recorded supervisor claimant'
    if ($Mode -ceq 'expire-admit') {
      $ticketBefore.presentedUtc = [DateTime]::UtcNow.AddSeconds(-601).ToString('o')
      Write-Text $queuePath ($queue | ConvertTo-Json -Depth 10 -Compress)
      Write-Text $clockPath '601'
      Write-Text $holder.release 'release'; $holderDispatch.process.WaitForExit()
      Write-Text $leader.release 'release'; Write-Text $leaderRelease 'release'; $leaderDispatch.process.WaitForExit()
      Assert-True ($holderDispatch.process.ExitCode -eq 0 -and $leaderDispatch.process.ExitCode -eq 0) 'expiry predecessors release through real admission'
      $afterPrune = Read-SharedText $queuePath | ConvertFrom-Json -DateKind String
      Assert-True (@($afterPrune.tickets | Where-Object number -EQ ([long]$first.ticket)).Count -eq 0) 'real verifier prunes the expired client reservation'
      Write-Text (Join-Path $client.runtime 'fixture-queue-poll-1.json.continue') 'continue'
      Wait-ProcessPath $client.ready $clientDispatch.process 'expired client replacement did not execute through real admission' | Out-Null
      Write-Text $client.release 'release'; $clientDispatch.process.WaitForExit()
      $result = Read-SharedText $pendingPath | ConvertFrom-Json -DateKind String
      $afterAdmission = Read-SharedText $queuePath | ConvertFrom-Json -DateKind String
      Assert-True ($afterAdmission.nextTicket -eq $afterPrune.nextTicket + 1 -and $clientDispatch.process.ExitCode -eq 0 -and $result.status -ceq 'passed' -and $result.nativeExit -eq 0 -and $result.dispatchReleased -eq $true -and -not (Test-Path -LiteralPath (Join-Path $client.runtime 'verify-lock.d'))) 'expired ticket replacement is a valid admitted run and releases slot and dispatch'
      $history = Read-SharedText $stderrPath
      Assert-True ($history.Contains("long-product-gate: queue ticket replaced before admission (previous=$($first.ticket))")) 'expired admission records the queue ticket replacement warning'
      Assert-True ($history.Contains("long-product-gate: admission ticket comparison unavailable (previous=$($first.ticket))") -and [regex]::Matches($history, '(?m)^heavy-verifier: queued;').Count -eq 1 -and $history -like '*heavy-verifier: nested-owner pipe=*') 'expired admission records unavailable comparison and preserves queue and admission history'
      Write-Output "PASS expired queued ticket=$($first.ticket) pruned, replacement admitted and released; named replacement warning recorded"
    } elseif ($Mode -ceq 'interrupt') {
      $ownerPath = Join-Path $client.runtime 'verify-lock.d/owner.json'; $ownerBytes = Read-SharedText $ownerPath
      $ledgerPath = Join-Path $client.runtime 'dispatch-log.jsonl'; $ledgerBytes = Read-SharedText $ledgerPath
      $clientDispatch.supervisor.Kill(); $clientDispatch.supervisor.WaitForExit(); $clientDispatch.process.WaitForExit()
      . (Join-Path $client.orchestrator 'dispatch-ownership.ps1')
      $scavenge = Invoke-DispatchOwnershipScavenge $client.runtime $testRoot
      $watchdog = & (Join-Path $client.orchestrator 'lane-stall-watchdog.ps1') -Label $holderDispatch.label -RuntimeRoot $client.runtime -HistoryPath $ledgerPath | ConvertFrom-Json -DateKind String
      Assert-True ((Read-SharedText $pendingPath) -ceq $pendingBytes -and (Read-SharedText $queuePath) -ceq $queueBefore) 'queued supervisor interruption preserves pending result and reserved queue bytes'
      Assert-True ($scavenge.removed -eq 0 -and (Read-SharedText $ownerPath) -ceq $ownerBytes -and -not $holderDispatch.process.HasExited -and -not $leaderDispatch.process.HasExited) 'queued interruption never reclaims or kills another claimant'
      Assert-True ($watchdog.relaunch -eq $false -and (Read-SharedText $ledgerPath) -ceq $ledgerBytes -and -not (Test-Path -LiteralPath $client.ready)) 'queued interruption neither relaunches nor consumes an attempt or executes the gate'
      Write-Output 'PASS queued supervisor interruption preserves pending result, reservation and live holder; no reclaim/relaunch/attempt'
      return
    } else {
      if ($Mode -ceq 'cap') { Write-Text $clockPath '3601' }
      Write-Text (Join-Path $client.runtime 'fixture-queue-poll-1.json.continue') 'continue'
      $second = Wait-QueuePoll $client $clientDispatch 2
      if ($Mode -ceq 'cap') {
        Assert-True ($null -eq $second) 'queue wait cap finalizes without a second verifier presentation'
        $clientDispatch.process.WaitForExit()
        $result = Read-SharedText $pendingPath | ConvertFrom-Json -DateKind String
        Assert-True ($result.status -ceq 'incomplete' -and $result.exit -eq 73 -and (Read-SharedText $stderrPath) -like '*long-product-gate: queued wait cap 3600 seconds reached*' -and -not (Test-Path -LiteralPath $client.ready)) 'queue wait cap names 3600 seconds and refuses without execution'
        Write-Output 'PASS queued wait cap 3600 seconds: fake clock, incomplete exit 73, no execution'
        return
      }
      $history = Read-SharedText $stderrPath
      $tickets = @([regex]::Matches($history, '(?m)^heavy-verifier: queued; ticket=([0-9]+) ') | ForEach-Object { $_.Groups[1].Value })
      Assert-True ($null -ne $second -and $tickets.Count -eq 2 -and @($tickets | Select-Object -Unique).Count -eq 1) 'queued presentations preserve the same reserved ticket number'
      Assert-True (($first.arguments -join "`n") -ceq ($second.arguments -join "`n") -and $first.pid -eq $second.pid) 'queued presentations keep identical verifier arguments and supervisor identity'
      $ticketAfter = @((Read-SharedText $queuePath | ConvertFrom-Json -DateKind String).tickets | Where-Object number -EQ ([long]$first.ticket))[0]
      Assert-True ($ticketAfter.presentedUtc -cne $ticketBefore.presentedUtc -and (Read-SharedText $pendingPath) -ceq $pendingBytes) 'queued presentation refreshes presentedUtc without changing pending result bytes'
      Write-Text $holder.release 'release'; $holderDispatch.process.WaitForExit()
      $holderDispatch.supervisor.Dispose(); $holderDispatch.supervisor = $null; $holderDispatch.process.Dispose(); $holderDispatch.process = $null
      Write-Text $leader.release 'release'; Write-Text $leaderRelease 'release'; $leaderDispatch.process.WaitForExit()
      Assert-True ($leaderDispatch.process.ExitCode -eq 0) 'reserved leader consumes its ticket through real admission before the client'
      $leaderDispatch.supervisor.Dispose(); $leaderDispatch.supervisor = $null; $leaderDispatch.process.Dispose(); $leaderDispatch.process = $null
      Write-Text (Join-Path $client.runtime 'fixture-queue-poll-2.json.continue') 'continue'
      Wait-ProcessPath $client.ready $clientDispatch.process 'queued real gate did not execute after slot release' | Out-Null
      Write-Text $client.release 'release'; $clientDispatch.process.WaitForExit()
      $result = Read-SharedText $pendingPath | ConvertFrom-Json -DateKind String
      Assert-True ($clientDispatch.process.ExitCode -eq 0 -and $result.status -ceq 'passed' -and $result.nativeExit -eq 0 -and $result.dispatchReleased -eq $true -and -not (Test-Path -LiteralPath (Join-Path $client.runtime 'verify-lock.d'))) 're-presented queued gate succeeds and releases its real slot and dispatch'
      $finalHistory = Read-SharedText $stderrPath
      Assert-True ([regex]::Matches($finalHistory, '(?m)^heavy-verifier: queued;').Count -eq 2 -and $finalHistory -like '*heavy-verifier: nested-owner pipe=*') 'terminal stderr retains every queued presentation and admitted execution'
      Assert-True ($finalHistory.Contains("long-product-gate: admission ticket comparison unavailable (previous=$($first.ticket))") -and -not $finalHistory.Contains('long-product-gate: queue ticket replaced before admission')) 'unexpired admission records unavailable comparison without a replacement warning'
      Write-Output "PASS real queued gate reused ticket=$($first.ticket) twice, refreshed presentation, executed and released"
    }
  } catch { $failure = $_.Exception.Message } finally {
    if ($clientDispatch -and $clientDispatch.supervisor) { Stop-ExactStartedProcess $clientDispatch.supervisor }
    Write-Text $leaderRelease 'release'
    foreach ($fixture in @($holder,$leader,$client)) { Write-Text $fixture.release 'release' }
    foreach ($dispatch in @($clientDispatch,$leaderDispatch,$holderDispatch)) {
      if ($dispatch) { if ($dispatch.process) { $dispatch.process.WaitForExit(); $dispatch.process.Dispose() }; if ($dispatch.supervisor) { $dispatch.supervisor.Dispose() } }
    }
  }
  if ($Mutation) {
    $expected = switch ($Mutation) {
      'single-shot' { 'queued gate re-presents instead of finalizing its first queued refusal' }
      'fresh-ticket' { 'queued presentations preserve the same reserved ticket number' }
      'no-cap' { 'queue wait cap finalizes without a second verifier presentation' }
      'replacement-line' { 'expired admission records the queue ticket replacement warning' }
    }
    Assert-True ($failure -ceq "ASSERTION FAILED: $expected") "MUTANT $Mutation reaches its named queue assertion (actual=$failure)"
    if ($Mutation -ceq 'fresh-ticket') { Assert-True ((Read-SharedText $stderrPath) -like '*long-product-gate: queue ticket changed*') 'changed ticket diagnostic explains the lost reservation' }
    Write-Output "PASS MUTANT $Mutation killed at $expected"
  } elseif ($failure) { throw $failure }
}
function New-TransientVerifier($Fixture, $Responses) {
  $responsePath = Join-Path $Fixture.runtime 'fixture-transient-responses.json'
  $statePath = Join-Path $Fixture.runtime 'fixture-transient-call.txt'
  Write-Text $responsePath (@($Responses) | ConvertTo-Json -Depth 5)
  $source = @'
param([string]$Gate,[string]$Worktree,[string]$Lane,[string]$Branch,[string]$ClaimedHead,[string]$ContainerRoot)
$responsePath = '__RESPONSE_PATH__'
$statePath = '__STATE_PATH__'
$call = if (Test-Path -LiteralPath $statePath) { [int](Get-Content -LiteralPath $statePath -Raw) } else { 0 }
$call++
[IO.File]::WriteAllText($statePath, [string]$call)
$responses = @(Get-Content -LiteralPath $responsePath -Raw | ConvertFrom-Json -DateKind String)
$response = $responses[$call - 1]
if ($null -eq $response) { throw "fixture transient verifier response exhausted at call=$call" }
if ($response.text) { [Console]::Error.WriteLine([string]$response.text) }
exit [int]$response.exit
'@
  $source = $source.Replace('__RESPONSE_PATH__', $responsePath.Replace("'", "''")).Replace('__STATE_PATH__', $statePath.Replace("'", "''"))
  $path = Join-Path $Fixture.orchestrator 'fixture-transient-verifier.ps1'
  Write-Text $path $source
  return [pscustomobject]@{ path = $path; state = $statePath }
}
function Invoke-TransientCensusCase([string]$Mode, [string]$Mutation = '') {
  $root = Join-Path $fixtureRoot ('transient-' + $Mode + '-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $root | Out-Null
  New-ControllerScriptFixture $root | Out-Null
  $fixture = New-LongGateFixture $root 'lane-23'
  $supervisorPath = Join-Path $fixture.orchestrator 'long-product-gate.ps1'
  $source = [IO.File]::ReadAllText($supervisorPath)
  $queued = @{type='queued';text='heavy-verifier: queued; ticket=171 position=4 reserved=True; retry within 600 seconds';exit=73}
  $changedQueued = @{type='queued';text='heavy-verifier: queued; ticket=172 position=4 reserved=True; retry within 600 seconds';exit=73}
  $transient = @{type='transient';text='heavy-verifier: caller eligibility: dispatch census evaluation exhausted';exit=73}
  $admitted = @{type='admitted';text='heavy-verifier: admitted; ticket=171';exit=0}
  $replacementAdmitted = @{type='admitted';text='heavy-verifier: admitted; ticket=172; native=fixture';exit=0}
  $responses = switch ($Mode) {
    'held' { @($queued,$queued,$transient,$queued,$admitted) }
    'before' { @($transient,$queued,$admitted) }
    'cap' { @($transient,$transient,$transient) }
    'wait-cap' { @($transient,$transient) }
    'changed' { @($queued,$transient,$changedQueued) }
    'replacement' { @($queued,$transient,$replacementAdmitted) }
    'other' { @(@{type='other';text='heavy-verifier: caller eligibility: dispatch census changed authority';exit=73}) }
    default { throw "unknown transient census case $Mode" }
  }
  $verifier = New-TransientVerifier $fixture $responses
  $verifierNeedle = '$verifier = Join-Path $PSScriptRoot ''invoke-heavy-verifier.ps1'''
  $verifierReplacement = '$verifier = ''' + $verifier.path.Replace("'", "''") + ''''
  $source = Replace-FixtureOnce $source $verifierNeedle $verifierReplacement
  $poll = @'
$fixturePoll = 1 + $fixturePoll
$pollPath = Join-Path $runtimeFull "fixture-transient-poll-$fixturePoll.json"
[IO.File]::WriteAllText($pollPath, [string]$fixturePoll)
while (-not [IO.File]::Exists("$pollPath.continue")) { Start-Sleep -Milliseconds 10 }
'@
  $source = Replace-FixtureOnce $source "      [Threading.Thread]::Sleep(`$queueSleepMilliseconds)`r`n      continue" (($poll.TrimEnd("`r", "`n")) + "`r`n      continue")
  $source = Replace-FixtureOnce $source "    [Threading.Thread]::Sleep(`$queueSleepMilliseconds)" ($poll.TrimEnd("`r", "`n"))
  if ($Mode -ceq 'wait-cap') {
    $clockPath = Join-Path $fixture.runtime 'fixture-transient-clock.txt'
    Write-Text $clockPath '0'
    $clock = @'
$queueWatch = [pscustomobject]@{}
$queueWatch | Add-Member -NotePropertyName StartedAt -NotePropertyValue ([double][IO.File]::ReadAllText((Join-Path $runtimeFull 'fixture-transient-clock.txt')))
$queueWatch | Add-Member -MemberType ScriptProperty -Name Elapsed -Value { [TimeSpan]::FromSeconds([double][IO.File]::ReadAllText((Join-Path $runtimeFull 'fixture-transient-clock.txt')) - $this.StartedAt) }
'@
    $source = Replace-FixtureOnce $source 'if (-not $queueWatch) { $queueWatch = [Diagnostics.Stopwatch]::StartNew() }' $clock
  }
  if ($Mutation -ceq 'census-immediate') { $source = Replace-FixtureOnce $source 'if ($isTransientCallerEligibilityRefusal)' 'if ($false)' }
  Write-Text $supervisorPath $source
  $launchId = [guid]::NewGuid().ToString()
  $resultPath = Join-Path $fixture.runtime "long-product-gate-$launchId.json"
  $runner = Invoke-LongGateProcess $fixture $supervisorPath $launchId $resultPath -NoWait
  $failure = $null; $result = $null
  try {
    $pollCount = switch ($Mode) { 'held' { 4 }; 'before' { 2 }; 'cap' { 2 }; 'wait-cap' { 1 }; 'changed' { 2 }; 'replacement' { 2 }; 'other' { 0 } }
    if ($Mutation -ceq 'census-immediate') {
      $firstPoll = Join-Path $fixture.runtime 'fixture-transient-poll-1.json'
      $deadline = [DateTime]::UtcNow.AddSeconds(10)
      while (-not (Test-Path -LiteralPath $firstPoll) -and -not $runner.process.HasExited -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 25 }
      Assert-True ((Test-Path -LiteralPath $firstPoll) -and -not $runner.process.HasExited) 'census refusal is transient and re-presented before a queued ticket'
    }
    for ($pollNumber = 1; $pollNumber -le $pollCount; $pollNumber++) {
      $pollPath = Join-Path $fixture.runtime "fixture-transient-poll-$pollNumber.json"
      Wait-ForPathOrExit $pollPath $runner.process "transient census poll $pollNumber was not reached"
      Write-Output "TRANSIENT_POLL mode=$Mode number=$pollNumber"
      if ($Mode -ceq 'wait-cap' -and $pollNumber -eq 1) { Write-Text (Join-Path $fixture.runtime 'fixture-transient-clock.txt') '3601' }
      Write-Text "$pollPath.continue" 'continue'
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while ([DateTime]::UtcNow -lt $deadline) {
      if (Test-Path -LiteralPath $resultPath) {
        try { $result = Read-SharedText $resultPath | ConvertFrom-Json -DateKind String } catch {}
        if ($result -and $result.status -cne 'pending') { break }
      }
      if ($runner.process.HasExited) { break }
      Start-Sleep -Milliseconds 25
    }
    if ($result -and -not $runner.process.HasExited) {
      $runnerDeadline = [DateTime]::UtcNow.AddSeconds(15)
      while (-not $runner.process.HasExited -and [DateTime]::UtcNow -lt $runnerDeadline) { Start-Sleep -Milliseconds 25 }
    }
    $historyPath = Join-Path $fixture.runtime "long-product-gate-$launchId.stderr.log"
    $history = if (Test-Path -LiteralPath $historyPath) { Read-SharedText $historyPath } else { '' }
    Assert-True ($result -and $runner.process.HasExited) "transient census case $Mode reached a terminal result (runnerExit=$($runner.process.ExitCode) result=$result history=$history)"
    switch ($Mode) {
      'held' {
        $tickets = @([regex]::Matches($history, '(?m)^heavy-verifier: queued; ticket=([0-9]+) ') | ForEach-Object { $_.Groups[1].Value })
        Assert-True ($result.status -ceq 'verifier-passed' -and $result.exit -eq 0 -and $tickets.Count -eq 3 -and @($tickets | Select-Object -Unique).Count -eq 1 -and $tickets[0] -eq '171' -and $history.Contains('heavy-verifier: admitted; ticket=171') -and $history.Contains('long-product-gate: transient caller-eligibility refusal; re-presenting (ticket=171 count=1)')) 'transient census refusal re-presents a held ticket and admits with the same ticket'
        Write-Output 'PASS transient census refusal while queued re-presents ticket=171 and admits with the same ticket'
      }
      'before' {
        Assert-True ($result.status -ceq 'verifier-passed' -and $result.exit -eq 0 -and $history.Contains('long-product-gate: transient caller-eligibility refusal; re-presenting (ticket=<none> count=1)') -and $history.Contains('heavy-verifier: queued; ticket=171') -and $history.Contains('heavy-verifier: admitted; ticket=171')) 'transient census refusal before a ticket starts the queue watch and re-presents before admission'
        Write-Output 'PASS transient census refusal before a ticket starts the queue watch and admits'
      }
      'cap' {
        Assert-True ($result.status -ceq 'incomplete' -and $result.exit -eq 73 -and ([regex]::Matches($history, '(?m)^long-product-gate: transient caller-eligibility refusal;').Count -eq 3) -and $history.Contains('long-product-gate: transient caller-eligibility refusal cap 3 reached') -and -not $history.Contains('heavy-verifier: admitted;')) 'consecutive transient census refusal cap finalizes incomplete before admission'
        Write-Output 'PASS consecutive transient census refusal cap=3 finalizes incomplete'
      }
      'wait-cap' {
        Assert-True ($result.status -ceq 'incomplete' -and $result.exit -eq 73 -and $history.Contains('long-product-gate: queued wait cap 3600 seconds reached') -and $history.Contains('heavy-verifier: caller eligibility: dispatch census evaluation exhausted')) 'transient wait counts toward the 3600-second queued cap'
        Write-Output 'PASS transient wait counts toward queued wait cap 3600 seconds'
      }
      'changed' {
        Assert-True ($result.status -ceq 'incomplete' -and $result.exit -eq 73 -and $history.Contains('long-product-gate: queue ticket changed') -and -not $history.Contains('heavy-verifier: admitted;')) 'ticket change after a transient refusal finalizes immediately'
        Write-Output 'PASS ticket change after transient refusal finalizes immediately'
      }
      'replacement' {
        Assert-True ($result.status -ceq 'verifier-passed' -and $result.exit -eq 0 -and $history.Contains('long-product-gate: admission ticket comparison (previous=171 current=172)') -and $history.Contains('long-product-gate: queue ticket replaced before admission (previous=171)')) 'admitted replacement ticket after a transient refusal retains v2.165 diagnostics'
        Write-Output 'PASS admitted replacement ticket after transient refusal retains v2.165 diagnostics'
      }
      'other' {
        Assert-True ($result.status -ceq 'incomplete' -and $result.exit -eq 73 -and $history.Contains('heavy-verifier: caller eligibility: dispatch census changed authority') -and -not $history.Contains('transient caller-eligibility refusal;')) 'different caller-eligibility refusal finalizes immediately'
        Write-Output 'PASS different caller-eligibility refusal finalizes immediately'
      }
    }
  } catch { $failure = $_.Exception.Message } finally {
    if ($runner.process -and -not $runner.process.HasExited) { Stop-ExactStartedProcess $runner.process }
    if ($runner.process) { $runner.process.Dispose() }
  }
  if ($Mutation) {
    Assert-True ($failure -ceq 'ASSERTION FAILED: census refusal is transient and re-presented before a queued ticket') "MUTANT $Mutation reaches its named transient assertion (actual=$failure)"
    Write-Output 'PASS MUTANT census-immediate killed at census refusal is transient and re-presented before a queued ticket'
  } elseif ($failure) { throw $failure }
}
function New-Mutant([string]$Source, [string]$Name, $Fixture) {
  $mutantPath = Join-Path $Fixture.orchestrator "long-product-gate-$Name-mutant.ps1"
  $mutant = $Source
  switch ($Name) {
    'direct-host' {
      $old = "if (`$null -eq `$record) { throw 'long-product-gate: exact dispatch owner was not published for this supervisor' }"
      $new = "if (`$null -eq `$record) { `$record = [pscustomobject]@{ laneRole='implementation'; launchId=`$LaunchId; lane=`$Lane; worktree=`$worktreeFull; branch=`$Branch; head=`$ClaimedHead } }"
      $mutant = $mutant.Replace($old, $new)
    }
    'stale-result' {
      $old = "if (Test-Path -LiteralPath `$ResultPath -PathType Leaf) { throw 'long-product-gate: result path is already occupied' }"
      $mutant = $mutant.Replace($old, "if (`$false) { throw 'long-product-gate: result path is already occupied' }")
    }
  }
  Assert-True ($mutant -cne $Source) "mutant $Name has a load-bearing source seam"
  Write-Text $mutantPath $mutant
  return $mutantPath
}
function Test-VerifierOverrideGuardMutant($Fixture) {
  $mutantPath = Join-Path $Fixture.root 'dispatch-lane-verifier-override-mutant.ps1'
  $source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'dispatch-lane.ps1'))
  $needle = '  [Parameter(DontShow)][switch]$LongProductGate,'
  $replacement = $needle + "`r`n  [Parameter(DontShow)][string]`$LongProductGateTestVerifierPath,"
  $mutant = $source.Replace($needle, $replacement)
  Assert-True ($mutant -cne $source) 'verifier-override mutant has a load-bearing source seam'
  Write-Text $mutantPath $mutant
  $failure = $null
  try { Assert-NoVerifierOverride @($mutantPath, (Join-Path $PSScriptRoot 'long-product-gate.ps1')) } catch { $failure = $_.Exception.Message }
  Assert-True ($failure -like '*production long-gate scripts expose a verifier override*') 'MUTANT verifier-override reaches named guard assertion'
  Write-Output 'PASS MUTANT verifier-override killed at its named guard assertion'
}
function Get-TestDefinition([string]$Path, [string]$Name) {
  $tokens = $null; $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
  Assert-True ($errors.Count -eq 0) 'shared census clock source parses without errors'
  $definitions = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $Name }, $true))
  Assert-True ($definitions.Count -eq 1) "test extraction finds exactly one $Name"
  return $definitions[0].Extent.Text
}
function Assert-AdmissionTicketDiagnostics([string]$Source, [string]$LogPath) {
  $tokens = $null; $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseInput($Source, [ref]$tokens, [ref]$errors)
  $samples = @($ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$presentationSeconds'
  }, $true))
  Assert-True ($errors.Count -eq 0 -and $samples.Count -eq 1) 'presentation clock sample extracts exactly once'
  $presentationWatch = [pscustomobject]@{Elapsed=[TimeSpan]::FromSeconds(601)}
  $queueWatch = [pscustomobject]@{Elapsed=[TimeSpan]::Zero}
  . ([scriptblock]::Create($samples[0].Extent.Text))
  Assert-True ($presentationSeconds -eq 601) 'presentation clock includes time before the first queued refusal is observed'
  $blocks = @($ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -ceq '$queueTicket'
  }, $true))
  Assert-True ($errors.Count -eq 0 -and $blocks.Count -eq 1) 'admission ticket diagnostic block extracts exactly once'
  $diagnostics = [scriptblock]::Create($blocks[0].Extent.Text)
  foreach ($case in @(
    @{output='heavy-verifier: admitted; ticket=3'; previous=1000; now=1601; comparison='comparison (previous=3 current=3)'; warning=$false; name='exposed unchanged ticket is comparable even after retention'},
    @{output='heavy-verifier: admitted; ticket=4'; previous=1000; now=1001; comparison='comparison (previous=3 current=4)'; warning=$true; name='exposed replacement warns without an expiry gap'},
    @{output='heavy-verifier: nested-owner pipe=fixture'; previous=1000; now=1600; comparison='comparison unavailable (previous=3)'; warning=$false; name='unavailable ticket at exactly 600 seconds has no replacement warning'},
    @{output='heavy-verifier: nested-owner pipe=fixture'; previous=1000; now=1601; comparison='comparison unavailable (previous=3)'; warning=$true; name='unavailable ticket after 600 seconds warns using the previous presentation'}
  )) {
    $queueTicket = '3'; $queueRetentionSeconds = 600
    $presentationSeconds = $case.now; $previousPresentationSeconds = $case.previous
    $presentationOutput = $case.output; $presentationError = ''; $stderrPath = $LogPath
    Write-Text $stderrPath ''
    . $diagnostics
    $history = Read-SharedText $stderrPath
    Assert-True ($history.Contains("long-product-gate: admission ticket $($case.comparison)") -and $history.Contains('long-product-gate: queue ticket replaced before admission (previous=3)') -eq $case.warning) $case.name
  }
}
function Test-AdmissionTicketDiagnostics($Fixture, [string]$Source) {
  $log = Join-Path $Fixture.runtime 'fixture-admission-diagnostics.log'
  Assert-AdmissionTicketDiagnostics $Source $log
  Write-Output 'PASS admission ticket diagnostics compare exposed tickets and the strict 600-second previous-presentation boundary'
  foreach ($mutation in @(
    @('$presentationSeconds = $presentationWatch.Elapsed.TotalSeconds', '$presentationSeconds = $queueWatch.Elapsed.TotalSeconds', 'presentation clock includes time before the first queued refusal is observed'),
    @('if ($admissionTicketMatch.Success)', 'if ($false)', 'exposed unchanged ticket is comparable even after retention'),
    @('$admissionTicket -cne $queueTicket', '$admissionTicket -ceq $queueTicket', 'exposed unchanged ticket is comparable even after retention'),
    @('-gt $queueRetentionSeconds', '-ge $queueRetentionSeconds', 'unavailable ticket at exactly 600 seconds has no replacement warning'),
    @('$presentationSeconds - $previousPresentationSeconds', '$presentationSeconds', 'unavailable ticket at exactly 600 seconds has no replacement warning')
  )) {
    $mutated = Replace-FixtureOnce $Source $mutation[0] $mutation[1]
    $failure = $null
    try { Assert-AdmissionTicketDiagnostics $mutated $log } catch { $failure = $_.Exception.Message }
    Assert-True ($failure -ceq "ASSERTION FAILED: $($mutation[2])") "MUTANT admission diagnostics reaches $($mutation[2])"
    Write-Output "PASS MUTANT admission diagnostics killed at $($mutation[2])"
  }
}
function Assert-SharedCensusClockContract([string]$Path) {
  $tokens = $null; $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
  $budget = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.ToString() -ceq '$script:heavyAdmissionBudget' }, $true))
  Assert-True ($errors.Count -eq 0 -and $budget.Count -eq 1) 'shared admission budget initializer extracts exactly once'
  function New-FrozenCensusClock { return [pscustomobject]@{ ElapsedMilliseconds = 0 } }
  $clockCall = '[Diagnostics.Stopwatch]::StartNew()'
  . ([scriptblock]::Create($budget[0].Extent.Text.Replace($clockCall, '(New-FrozenCensusClock)')))
  Assert-True ($script:heavyAdmissionBudget.deadline -eq 210000) 'shared admission census clock remains 210 seconds'
  $definition = Get-TestDefinition $Path 'Get-HeavyCallerBinding'
  . ([scriptblock]::Create($definition.Replace($clockCall, '(New-FrozenCensusClock)')))
  $observed = [Collections.Generic.List[object]]::new()
  function Get-HeavyCallerObservation($Evaluation, $Remaining) {
    $observed.Add([pscustomobject]@{deadline=$Evaluation.deadline;remaining=$Remaining})
    return [pscustomobject]@{Reason='dispatch census changed';Retryable=$true;Record=$null}
  }
  $script:heavyAdmissionBudget.fences = 3
  $binding = Get-HeavyCallerBinding
  Assert-True ($observed.Count -gt 0 -and $observed[0].deadline -eq 90000 -and $observed[0].remaining -eq 90000) 'shared evaluation census clock remains 90 seconds'
  Assert-True ($observed.Count -eq 3 -and $binding.Reason -ceq 'dispatch census changed') 'shared census re-observation remains bounded to three attempts'
  $script:heavyAdmissionBudget.observations = 5; $observed.Clear()
  $binding = Get-HeavyCallerBinding
  Assert-True ($observed.Count -eq 1 -and $script:heavyAdmissionBudget.observations -eq 6 -and $binding.Reason -ceq 'dispatch census evaluation exhausted') 'shared census observation cap remains six'
  $script:heavyAdmissionBudget.observations = 4; $script:heavyAdmissionBudget.fences = 1; $observed.Clear()
  $binding = Get-HeavyCallerBinding
  Assert-True ($observed.Count -eq 0 -and $binding.Reason -ceq 'dispatch census evaluation exhausted') 'shared census preserves remaining admission fences'
}
function Test-ClockContractMutant($Fixture) {
  $sourcePath = Join-Path $Fixture.orchestrator 'invoke-heavy-verifier.ps1'
  $source = [IO.File]::ReadAllText($sourcePath)
  $mutantPath = Join-Path $Fixture.orchestrator 'invoke-heavy-verifier-clocks-mutant.ps1'
  foreach ($mutation in @(
    @('deadline=210000; observations=0', 'deadline=210001; observations=0', 'shared admission census clock remains 210 seconds'),
    @('deadline=90000', 'deadline=90001', 'shared evaluation census clock remains 90 seconds'),
    @('$attempt -lt 3', '$attempt -lt 4', 'shared census re-observation remains bounded to three attempts'),
    @('$admission.observations -ge 6', '$admission.observations -ge 7', 'shared census observation cap remains six'),
    @('3 - $admission.fences', '2 - $admission.fences', 'shared census preserves remaining admission fences')
  )) {
    Assert-True (([regex]::Matches($source, [regex]::Escape($mutation[0]))).Count -eq 1) 'clock mutant has exactly one load-bearing seam'
    Write-Text $mutantPath ($source.Replace($mutation[0], $mutation[1]))
    $failure = $null
    try { Assert-SharedCensusClockContract $mutantPath } catch { $failure = $_.Exception.Message }
    Assert-True ($failure -ceq "ASSERTION FAILED: $($mutation[2])") "MUTANT clocks reaches $($mutation[2])"
    Write-Output "PASS MUTANT clocks killed at $($mutation[2])"
  }
}

$controllerRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('long-product-gate-test-' + [guid]::NewGuid().ToString('N'))
$fixtureRoot = Join-Path $controllerRoot ('.long-product-gate-fixture-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot, $fixtureRoot | Out-Null
$cleanupMutant = $Mutant -ceq 'temp-cleanup'
if (-not $Mutant -or $cleanupMutant) {
  if ($cleanupMutant) {
    $failure = $null
    try { Assert-LongGateTempCleanup $testRoot $controllerRoot -Mutant } catch { $failure = $_.Exception.Message }
    Assert-True ($failure -ceq 'ASSERTION FAILED: long-product-gate temp root is gone after cleanup') 'MUTANT temp-cleanup reaches its named cleanup assertion'
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    Write-Output 'PASS MUTANT temp-cleanup reaches its named cleanup assertion'
    return
  }
  Assert-LongGateTempCleanup $testRoot $controllerRoot
}
$fixtureOrchestrator = New-ControllerScriptFixture $fixtureRoot
$productionDispatch = Join-Path $fixtureOrchestrator 'dispatch-lane.ps1'
$productionSupervisor = Join-Path $fixtureOrchestrator 'long-product-gate.ps1'
Assert-NoVerifierOverride @((Join-Path $PSScriptRoot 'dispatch-lane.ps1'), (Join-Path $PSScriptRoot 'long-product-gate.ps1'))
$guardOutput = & git -C $controllerRoot grep -n -E 'LongProductGateTestVerifierPath|TestVerifierPath|TestMode' -- .orchestrator/dispatch-lane.ps1 .orchestrator/long-product-gate.ps1 2>&1
Assert-True ($LASTEXITCODE -eq 1 -and -not $guardOutput) 'git grep found a production verifier override'
Write-Output 'PASS guard production scripts have no verifier-path override'
$routingSupport = Join-Path $PSScriptRoot 'routing-data-test-support.ps1'
. $routingSupport
$routingScope = Enter-RoutingDataTestScope
try {
  $fixture = New-LongGateFixture $fixtureRoot
  $supervisor = $productionSupervisor
  $source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'long-product-gate.ps1'))
  $runSupervisor = -not $Part -or $Part -ceq 'supervisor'
  $runQueue = -not $Part -or $Part -ceq 'queue'
  $runTransient = -not $Part -or $Part -ceq 'transient'
  $runMutants = -not $Part -or $Part -ceq 'mutants'
  if ($Mutant -cin @('single-shot','fresh-ticket','no-cap','non-atomic-ready','replacement-line','census-immediate')) {
    if ($Mutant -ceq 'non-atomic-ready') { Test-ReadyHandoff $fixture -NonAtomic }
    elseif ($Mutant -ceq 'census-immediate') { Invoke-TransientCensusCase 'before' $Mutant }
    else { Invoke-QueueCase $(if ($Mutant -ceq 'no-cap') { 'cap' } elseif ($Mutant -ceq 'replacement-line') { 'expire-admit' } else { 'admit' }) $Mutant }
    return
  }
  if ($runQueue) {
    Test-AdmissionTicketDiagnostics $fixture $source
    Test-ReadyHandoff $fixture
    Invoke-QueueCase 'admit'
    Invoke-QueueCase 'expire-admit'
    Invoke-QueueCase 'cap'
    Invoke-QueueCase 'interrupt'
  }
  if ($runTransient) {
    Invoke-TransientCensusCase 'held'
    Invoke-TransientCensusCase 'before'
    Invoke-TransientCensusCase 'cap'
    Invoke-TransientCensusCase 'wait-cap'
    Invoke-TransientCensusCase 'changed'
    Invoke-TransientCensusCase 'replacement'
    Invoke-TransientCensusCase 'other'
    if ($Part -ceq 'transient') { return }
  }
  if ($runSupervisor) {
    Assert-SharedCensusClockContract (Join-Path $fixture.orchestrator 'invoke-heavy-verifier.ps1')
    Write-Output 'PASS AC5 shared v2.161 census clocks 90/210 seconds, cap six, re-observation bounded'
    $launcher = $productionDispatch
    $prompt = Join-Path $fixture.runtime 'dispatch-prompt.txt'; Write-Text $prompt 'synthetic dispatch prompt'
    $requestIdentity = 'a' * 64; $ackPath = Join-Path $fixture.runtime "dispatch-start-$requestIdentity.json"
    $label = 'synthetic-long-product-gate'
    $dispatchOut = Join-Path $fixture.root 'dispatch.out'; $dispatchErr = Join-Path $fixture.root 'dispatch.err'
    $dispatchArguments = @('-NoProfile','-NonInteractive','-File',$launcher,'-Harness','codex','-Model','gpt-6.1-sol','-Effort','high','-LaneRole','implementation','-Row','4','-Placement','provisional',
      '-Issue','90230','-PromptFile',$prompt,'-Worktree',$fixture.worktree,'-Label',$label,'-ExecutablePath',(Join-Path $PSHOME 'pwsh.exe'),
      '-LongProductGate','-TestRuntimeRoot',$fixture.runtime,'-TestTempRoot',$testRoot,'-StartRequestIdentity',$requestIdentity,'-StartAcknowledgementPath',$ackPath)
    $dispatch = Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList $dispatchArguments -RedirectStandardOutput $dispatchOut -RedirectStandardError $dispatchErr -WindowStyle Hidden -PassThru
    try { Wait-ForPathOrExit $ackPath $dispatch 'normal dispatch acknowledgement was not published' } catch { Write-Output ("DISPATCH_STDERR " + (Read-SharedText $dispatchErr)); Write-Output ("DISPATCH_STDOUT " + (Read-SharedText $dispatchOut)); throw }
    Assert-True (-not $dispatch.HasExited) 'normal dispatch remained alive for the supervisor handoff'
    $ack = Wait-ProcessPath $ackPath $dispatch 'normal dispatch acknowledgement was not complete'
    Assert-True ($ack.longProductGate.schema -ceq 'long-product-gate/v1' -and $ack.longProductGate.gate -ceq 'test:scripts' -and $ack.longProductGate.hostWatchSeconds -eq 900 -and $ack.longProductGate.resultPath -like '*long-product-gate-*.json') 'acknowledgement binds the fixed gate, 900-second host watch, and exact launch result'
    $readyPath = $fixture.ready; $releasePath = $fixture.release
    try { Wait-ForPathOrExit $readyPath $dispatch 'real verifier native child did not publish its barrier' } catch {
      Write-Output ("DISPATCH_STDERR " + (Read-SharedText $dispatchErr)); Write-Output ("DISPATCH_STDOUT " + (Read-SharedText $dispatchOut))
      foreach ($diagnosticFile in @(Get-ChildItem -LiteralPath $fixture.runtime -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^long-product-gate|^dispatch-launch|^watchdog-lane|eligibility-trace|observation-trace' })) { Write-Output ("REAL_ROUTE_FILE " + $diagnosticFile.Name + "`n" + (Read-SharedText $diagnosticFile.FullName)) }
      throw
    }
    $lockOwnerPath = Join-Path $fixture.runtime 'verify-lock.d/owner.json'
    Wait-ForPathOrExit $lockOwnerPath $dispatch 'real verifier did not publish its product-slot owner'
    do {
      $slotOwner = Get-Content -LiteralPath $lockOwnerPath -Raw | ConvertFrom-Json -DateKind String
      if ($slotOwner.state -ceq 'started') { break }
      if ($dispatch.HasExited) { throw 'real verifier did not publish its started product-slot owner' }
      Start-Sleep -Milliseconds 25
    } while ($true)
    $readyRecord = Wait-ProcessPath $readyPath $dispatch 'real native ready publication was not complete'
    Write-Output "REAL_SLOT gate=$($slotOwner.gate) pid=$($slotOwner.pid) childPid=$($slotOwner.childPid) nativePid=$($readyRecord.pid)"
    Assert-True ($slotOwner.gate -ceq 'test:scripts' -and $slotOwner.childPid -eq $readyRecord.pid) 'real verifier owns the fixture product slot and native child'
    Write-Text $releasePath 'release'
    $dispatch.WaitForExit()
    Assert-True ($dispatch.ExitCode -eq 0) "normal dispatch failed: $([IO.File]::ReadAllText($dispatchErr))"
    $verifierLogPath = Join-Path $fixture.runtime "long-product-gate-$($ack.launchId).stderr.log"
    Assert-True (Test-Path -LiteralPath $verifierLogPath -PathType Leaf) 'real verifier publishes its stderr receipt'
    $verifierLog = Read-SharedText $verifierLogPath
    Assert-True ($verifierLog -like '*heavy-verifier: nested-owner pipe=*' -and $verifierLog -like '*binding=launch=*role=implementation*') 'real verifier publishes the admitted nested-owner binding'
    $routeResult = Get-Content -LiteralPath $ack.longProductGate.resultPath -Raw | ConvertFrom-Json -DateKind String
    Assert-True ($routeResult.schema -ceq 'long-product-gate/v1' -and $routeResult.status -ceq 'passed' -and $routeResult.dispatchReleased -eq $true -and
      $routeResult.launchId -ceq $ack.launchId -and $routeResult.lane -ceq (Split-Path -Leaf $fixture.worktree) -and
      $routeResult.worktree -ceq ([IO.Path]::GetFullPath($fixture.worktree).TrimEnd('\','/')) -and
      $routeResult.branch -ceq $fixture.branch -and $routeResult.head -ceq $fixture.head -and $routeResult.gate -ceq 'test:scripts') 'normal dispatch reaches terminal passed result only after exact release'
    Assert-True ($routeResult.schema -ceq 'long-product-gate/v1' -and $routeResult.gate -ceq 'test:scripts' -and $routeResult.exit -eq 0 -and $routeResult.nativeExit -eq 0) 'real verifier terminal receipt binds test:scripts and native success'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.runtime 'verify-lock.d'))) 'real verifier releases the fixture product slot'
    Assert-True (@(Get-ChildItem -LiteralPath $fixture.runtime -Filter 'dispatch-launch-*.json' -File).Count -eq 0) 'normal dispatch leaves no retained owner after result pass'
    Write-Output 'PASS AC1 normal dispatch supervisor ancestry handoff and AC3 atomic passed result'
    Invoke-InterruptionCase $fixture

    $id = [guid]::NewGuid().ToString(); $result = Join-Path $fixture.runtime "long-product-gate-$id.json"
    $directArgs = @('-NoProfile','-NonInteractive','-File',$supervisor,'-RuntimeRoot',$fixture.runtime,'-LaunchId',$id,'-Worktree',$fixture.worktree,'-Lane','lane-23','-Branch',$fixture.branch,'-ClaimedHead',$fixture.head,'-ResultPath',$result)
    $direct = Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList $directArgs -WindowStyle Hidden -PassThru
    $direct.WaitForExit()
    Assert-True ($direct.ExitCode -ne 0 -and -not (Test-Path -LiteralPath $result)) 'direct host supervisor refuses without the exact dispatch owner'
    Write-Output 'PASS AC1 direct supervisor host refusal before result publication'
    $id = [guid]::NewGuid().ToString(); $result = Join-Path $fixture.runtime "long-product-gate-$id.json"
    $before = '{"schema":"foreign-result/v1","status":"passed"}'
    Write-Text $result $before
    $exit = Invoke-LongGateProcess $fixture $supervisor $id $result -Preseed
    Assert-True ($exit -ne 0 -and [IO.File]::ReadAllText($result) -ceq $before) 'stale result is rejected without overwrite'
    Write-Output 'PASS AC3 stale result rejected and foreign bytes preserved'
  }
  if ($runMutants) {
    if (-not $Mutant) {
      Test-ReadyHandoff $fixture -NonAtomic
      Invoke-QueueCase 'admit' 'single-shot'
      Invoke-QueueCase 'admit' 'fresh-ticket'
      Invoke-QueueCase 'cap' 'no-cap'
      Invoke-QueueCase 'expire-admit' 'replacement-line'
      Invoke-TransientCensusCase 'before' 'census-immediate'
      Test-VerifierOverrideGuardMutant $fixture
      Test-ClockContractMutant $fixture
      Invoke-InterruptionCase $fixture -Mutant
    }
    if ($Mutant -ceq 'verifier-override') {
      Test-VerifierOverrideGuardMutant $fixture
      return
    }
    if ($Mutant -ceq 'clocks') {
      Test-ClockContractMutant $fixture
      return
    }
    if ($Mutant -ceq 'interruption-reclaims-owner') {
      Invoke-InterruptionCase $fixture -Mutant
      return
    }
    $mutantNames = if ($Mutant) { @($Mutant) } else { @('direct-host','stale-result') }
    foreach ($mutantName in $mutantNames) {
      $mutantPath = New-Mutant $source $mutantName $fixture
      $id = [guid]::NewGuid().ToString(); $result = Join-Path $fixture.runtime "long-product-gate-$id.json"
      if ($mutantName -ceq 'direct-host') {
        Write-Text $fixture.release 'release'
        $mutantArgs = @('-NoProfile','-NonInteractive','-File',$mutantPath,'-RuntimeRoot',$fixture.runtime,'-LaunchId',$id,'-Worktree',$fixture.worktree,'-Lane','lane-23','-Branch',$fixture.branch,'-ClaimedHead',$fixture.head,'-ResultPath',$result)
        $mutantOut = Join-Path $fixture.root 'mutant.out'; $mutantErr = Join-Path $fixture.root 'mutant.err'
        $mutantProcess = Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList $mutantArgs -RedirectStandardOutput $mutantOut -RedirectStandardError $mutantErr -WindowStyle Hidden -PassThru
        $mutantProcess.WaitForExit()
        Write-Output "MUTANT_OBSERVED direct-host exit=$($mutantProcess.ExitCode) stderr=$([IO.File]::ReadAllText($mutantErr))"
        $failure = $null
        try { Assert-True ($mutantProcess.ExitCode -ne 0 -and -not (Test-Path -LiteralPath $result)) 'direct host supervisor refuses without the exact dispatch owner' } catch { $failure = $_.Exception.Message }
        Assert-True ($failure -ceq 'ASSERTION FAILED: direct host supervisor refuses without the exact dispatch owner') 'MUTANT direct-host reaches its named assertion'
      } else {
        Write-Text $fixture.release 'release'
        $before = '{"schema":"foreign-result/v1","status":"passed"}'
        $exit = Invoke-LongGateProcess $fixture $mutantPath $id $result -Preseed
        Write-Output "MUTANT_OBSERVED stale-result exit=$exit bytes=$([IO.File]::ReadAllText($result))"
        $failure = $null
        try { Assert-True ($exit -ne 0 -and [IO.File]::ReadAllText($result) -ceq $before) 'MUTANT stale-result fails at occupied-result assertion' } catch { $failure = $_.Exception.Message }
        Assert-True ($failure -like '*MUTANT stale-result fails at occupied-result assertion*') 'MUTANT stale-result reaches its named assertion'
      }
      Write-Output "PASS MUTANT $mutantName killed at its named guard assertion"
    }
  }
} finally {
  if ($dispatch -and -not $dispatch.HasExited) {
    Write-Text $fixture.release 'release'
    $dispatch.WaitForExit()
  }
  $fixturePath = [IO.Path]::GetFullPath($fixtureRoot)
  $tempPath = [IO.Path]::GetFullPath($testRoot)
  $controllerPrefix = [IO.Path]::GetFullPath($controllerRoot).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
  if ($fixturePath.StartsWith($controllerPrefix, [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $fixturePath -Recurse -Force -ErrorAction SilentlyContinue }
  Remove-LongGateTempRoot $tempPath
  Assert-True (-not (Test-Path -LiteralPath $tempPath)) 'long-product-gate temp root is gone after cleanup'
  Exit-RoutingDataTestScope $routingScope
}
