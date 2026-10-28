[CmdletBinding()]
param(
  [ValidateSet('supervisor','mutants')][string]$Part = '',
  [ValidateSet('','direct-host','stale-result','verifier-override','interruption-kills-child','clocks')][string]$Mutant = ''
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
function New-ControllerScriptFixture([string]$Root) {
  $orchestrator = Join-Path $Root '.orchestrator'
  Copy-Item -LiteralPath (Join-Path $controllerRoot '.orchestrator') -Destination $orchestrator -Recurse
  $child = @'
param([string]$ReadyPath,[string]$ReleasePath)
$ready = [ordered]@{ pid = $PID; parentPid = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID").ParentProcessId; startedUtc = [DateTime]::UtcNow.ToString('o') }
[IO.File]::WriteAllText($ReadyPath, ($ready | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
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
  `$arguments = @('-NoProfile','-NonInteractive','-File',(Join-Path `$container '.orchestrator/fixture-heavy-child.ps1'),(Join-Path `$container '.orchestrator/fixture-child-ready.txt'),(Join-Path `$container '.orchestrator/fixture-child-release.txt'))
}
$needle
"@
  $fixtureVerifier = $verifier.Replace($needle, $replacement)
  Assert-True ($fixtureVerifier -cne $verifier -and ([regex]::Matches($fixtureVerifier, [regex]::Escape($replacement))).Count -eq 1) 'fixture verifier uses the exact real gate command-table replacement'
  Write-Text $verifierPath $fixtureVerifier
  return $orchestrator
}
function New-LongGateFixture([string]$Root) {
  $runtime = Join-Path $Root '.orchestrator'; $worktree = Join-Path $Root 'lane-23'
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
function New-InterruptionMutant([string]$Source, $Fixture) {
  $mutantPath = Join-Path $Fixture.orchestrator 'long-product-gate-interruption-kills-child-mutant.ps1'
  $needle = '  $process = [Diagnostics.Process]::Start($start)'
  $replacement = $needle + "`r`n  if (`$process) { `$process.Kill(); [void]`$process.WaitForExit() }"
  $mutant = $Source.Replace($needle, $replacement)
  Assert-True ($mutant -cne $Source -and ([regex]::Matches($mutant, [regex]::Escape($replacement))).Count -eq 1) 'interruption mutant has a load-bearing process-kill seam'
  Write-Text $mutantPath $mutant
  return $mutantPath
}
function Wait-ProcessPath([string]$Path, [Diagnostics.Process]$Process, [string]$Message) {
  Wait-ForPathOrExit $Path $Process $Message
  return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -DateKind String
}
function Stop-ExactStartedProcess([Diagnostics.Process]$Process) {
  if ($Process -and -not $Process.HasExited) { $Process.Kill(); $Process.WaitForExit() }
}
function Invoke-InterruptionCase($Fixture, [string]$Supervisor, [string]$Source, [switch]$Mutant) {
  foreach ($path in @((Join-Path $Fixture.runtime 'fixture-child-ready.txt'),(Join-Path $Fixture.runtime 'fixture-child-release.txt'),(Join-Path $Fixture.runtime 'dispatch-launch-interruption.json'))) {
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
  }
  $id = [guid]::NewGuid().ToString(); $result = Join-Path $Fixture.runtime "long-product-gate-$id.json"
  $runSupervisor = if ($Mutant) { New-InterruptionMutant $Source $Fixture } else { $Supervisor }
  $runner = Invoke-LongGateProcess $Fixture $runSupervisor $id $result -NoWait
  try {
    $recordPath = Join-Path $Fixture.runtime "dispatch-launch-$id.json"
    try { $record = Wait-ProcessPath $recordPath $runner.process 'interruption dispatch owner was not published' } catch {
      if (Test-Path -LiteralPath $runner.error) { Write-Output ("INTERRUPTION_RUNNER_ERR " + (Read-SharedText $runner.error)) }
      throw
    }
    Wait-ProcessPath $result $runner.process 'interruption result was not published' | Out-Null
    $readyFailure = $null
    try { $ready = Wait-ProcessPath (Join-Path $Fixture.runtime 'fixture-child-ready.txt') $runner.process 'real verifier native child was not running before interruption' } catch { $readyFailure = $_ }
    if ($Mutant) {
      Assert-True ($null -ne $readyFailure -or $null -eq $ready) 'MUTANT interruption-kills-child fails at native-child-preserved assertion'
      Write-Output 'PASS MUTANT interruption-kills-child killed at its named preservation assertion'
      return
    }
    $slotOwnerPath = Join-Path $Fixture.runtime 'verify-lock.d/owner.json'
    try { $slotOwner = Wait-ProcessPath $slotOwnerPath $runner.process 'real verifier slot owner was not published before interruption' } catch {
      if (Test-Path -LiteralPath $runner.error) { Write-Output ("INTERRUPTION_RUNNER_ERR " + (Read-SharedText $runner.error)) }
      $childError = Join-Path $Fixture.runtime "child-$id.err"
      if (Test-Path -LiteralPath $childError) { Write-Output ("INTERRUPTION_CHILD_ERR " + (Read-SharedText $childError)) }
      $verifierError = Join-Path $Fixture.runtime "long-product-gate-$id.stderr.log"
      if (Test-Path -LiteralPath $verifierError) { Write-Output ("INTERRUPTION_VERIFIER_ERR " + (Read-SharedText $verifierError)) }
      throw
    }
    $supervisorProcess = Get-Process -Id ([int]$record.childPid) -ErrorAction Stop
    $verifierProcess = Get-Process -Id ([int]$slotOwner.pid) -ErrorAction Stop
    $nativeProcess = Get-Process -Id ([int]$ready.pid) -ErrorAction Stop
    $supervisorProcess.Kill(); $supervisorProcess.WaitForExit()
    Start-Sleep -Milliseconds 250
    $pending = Get-Content -LiteralPath $result -Raw | ConvertFrom-Json -DateKind String
    Assert-True ($pending.status -ceq 'pending' -and $pending.dispatchReleased -eq $false) 'interruption remains incomplete and never publishes PASS'
    Assert-True ((Get-Process -Id ([int]$slotOwner.pid) -ErrorAction SilentlyContinue) -and (Get-Process -Id ([int]$ready.pid) -ErrorAction SilentlyContinue)) 'interruption kills neither verifier nor native child'
    Assert-True ((Test-Path -LiteralPath $recordPath) -and ((Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json).state -ceq 'started')) 'interruption preserves dispatch ownership for recovery'
    Assert-True (@(Get-ChildItem -LiteralPath $Fixture.runtime -Filter 'dispatch-launch-*.json' -File).Count -eq 1 -and -not (Get-ChildItem -LiteralPath $Fixture.runtime -Filter '*relaunch*' -File -ErrorAction SilentlyContinue)) 'interruption neither reclaims nor relaunches and consumes no attempt'
    Write-Output 'PASS AC4 interruption preserves pending result, verifier/native child, ownership and attempt'
  } finally {
    $release = Join-Path $Fixture.runtime 'fixture-child-release.txt'; Write-Text $release 'release'
    if ($runner.process) { $runner.process.WaitForExit(30000) | Out-Null }
    foreach ($processId in @($record.childPid,$slotOwner.pid,$ready.pid)) { if ($processId) { $p=Get-Process -Id ([int]$processId) -ErrorAction SilentlyContinue; if ($p) { try { $p.Kill(); $p.WaitForExit() } catch {} } } }
  }
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
function Assert-SharedCensusClockContract([string]$Path) {
  $tokens = $null; $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
  Assert-True ($errors.Count -eq 0) 'shared census clock source parses without errors'
  $assignments = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true))
  $budget = @($assignments | Where-Object { $_.Left.ToString() -ceq '$script:heavyAdmissionBudget' })[0]
  $evaluation = @($assignments | Where-Object { $_.Left.ToString() -ceq '$evaluation' -and $_.Right.ToString() -like '*deadline=90000*' })[0]
  Assert-True ($budget -and @($budget.Right.Expression.KeyValuePairs | Where-Object { $_ -and $_.Item1 -and $_.Item2 -and $_.Item1.ToString() -ceq 'deadline' -and $_.Item2.ToString() -ceq '210000' }).Count -eq 1) 'shared admission census clock remains 210 seconds'
  Assert-True ($evaluation -and @($evaluation.Right.Expression.KeyValuePairs | Where-Object { $_ -and $_.Item1 -and $_.Item2 -and $_.Item1.ToString() -ceq 'deadline' -and $_.Item2.ToString() -ceq '90000' }).Count -eq 1) 'shared evaluation census clock remains 90 seconds'
  $boundedAttempts = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.ForStatementAst] -and $node.Condition -and $node.Condition.ToString() -like '*$attempt -lt 3*' }, $true))
  Assert-True ($boundedAttempts.Count -eq 1) 'shared census re-observation remains bounded to three attempts'
  $boundedObservations = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.IfStatementAst] -and $node.Clauses.Count -gt 0 -and $node.Clauses[0].Item1 -and $node.Clauses[0].Item1.ToString() -like '*observations -ge 6*' }, $true))
  Assert-True ($boundedObservations.Count -eq 1) 'shared census observation cap remains six with reserved fences'
}
function Test-ClockContractMutant($Fixture) {
  $sourcePath = Join-Path $Fixture.orchestrator 'invoke-heavy-verifier.ps1'
  $source = [IO.File]::ReadAllText($sourcePath)
  $needle = 'deadline=90000'
  Assert-True (([regex]::Matches($source, [regex]::Escape($needle))).Count -eq 1) 'clock mutant has one evaluation deadline seam'
  $mutantPath = Join-Path $Fixture.orchestrator 'invoke-heavy-verifier-clocks-mutant.ps1'
  Write-Text $mutantPath ($source.Replace($needle, 'deadline=90001'))
  $failure = $null
  try { Assert-SharedCensusClockContract $mutantPath } catch { $failure = $_.Exception.Message }
  Assert-True ($failure -like '*shared evaluation census clock remains 90 seconds*') 'MUTANT clocks reaches its named clock assertion'
  Write-Output 'PASS MUTANT clocks killed at its named clock assertion'
}

$controllerRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('long-product-gate-test-' + [guid]::NewGuid().ToString('N'))
$fixtureRoot = Join-Path $controllerRoot ('.long-product-gate-fixture-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot, $fixtureRoot | Out-Null
$fixtureOrchestrator = New-ControllerScriptFixture $fixtureRoot
$productionDispatch = Join-Path $fixtureOrchestrator 'dispatch-lane.ps1'
$productionSupervisor = Join-Path $fixtureOrchestrator 'long-product-gate.ps1'
$sourceSupervisor = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'long-product-gate.ps1'))
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
  $runMutants = -not $Part -or $Part -ceq 'mutants'
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
    $ack = Get-Content -LiteralPath $ackPath -Raw | ConvertFrom-Json -DateKind String
    Assert-True ($ack.longProductGate.schema -ceq 'long-product-gate/v1' -and $ack.longProductGate.gate -ceq 'test:scripts' -and $ack.longProductGate.hostWatchSeconds -eq 900 -and $ack.longProductGate.resultPath -like '*long-product-gate-*.json') 'acknowledgement binds the fixed gate, 900-second host watch, and exact launch result'
    $readyPath = Join-Path $fixture.runtime 'fixture-child-ready.txt'; $releasePath = Join-Path $fixture.runtime 'fixture-child-release.txt'
    try { Wait-ForPathOrExit $readyPath $dispatch 'real verifier native child did not publish its barrier' } catch {
      Write-Output ("DISPATCH_STDERR " + (Read-SharedText $dispatchErr)); Write-Output ("DISPATCH_STDOUT " + (Read-SharedText $dispatchOut))
      foreach ($diagnosticFile in @(Get-ChildItem -LiteralPath $fixture.runtime -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^long-product-gate|^dispatch-launch|^watchdog-lane|eligibility-trace|observation-trace' })) { Write-Output ("REAL_ROUTE_FILE " + $diagnosticFile.Name + "`n" + (Read-SharedText $diagnosticFile.FullName)) }
      throw
    }
    $lockOwnerPath = Join-Path $fixture.runtime 'verify-lock.d/owner.json'
    Wait-ForPathOrExit $lockOwnerPath $dispatch 'real verifier did not publish its product-slot owner'
    $slotOwner = Get-Content -LiteralPath $lockOwnerPath -Raw | ConvertFrom-Json -DateKind String
    $readyRecord = Get-Content -LiteralPath $readyPath -Raw | ConvertFrom-Json -DateKind String
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
    Invoke-InterruptionCase $fixture $supervisor $source

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
    if ($Mutant -ceq 'verifier-override') {
      Test-VerifierOverrideGuardMutant $fixture
      return
    }
    if ($Mutant -ceq 'clocks') {
      Test-ClockContractMutant $fixture
      return
    }
    if ($Mutant -ceq 'interruption-kills-child') {
      Invoke-InterruptionCase $fixture $supervisor $source -Mutant
      return
    }
    $mutantNames = if ($Mutant) { @($Mutant) } else { @('direct-host','stale-result') }
    foreach ($mutantName in $mutantNames) {
      $mutantPath = New-Mutant $source $mutantName $fixture
      $id = [guid]::NewGuid().ToString(); $result = Join-Path $fixture.runtime "long-product-gate-$id.json"
      if ($mutantName -ceq 'direct-host') {
        $mutantArgs = @('-NoProfile','-NonInteractive','-File',$mutantPath,'-RuntimeRoot',$fixture.runtime,'-LaunchId',$id,'-Worktree',$fixture.worktree,'-Lane','lane-23','-Branch',$fixture.branch,'-ClaimedHead',$fixture.head,'-ResultPath',$result)
        $mutantOut = Join-Path $fixture.root 'mutant.out'; $mutantErr = Join-Path $fixture.root 'mutant.err'
        $mutantProcess = Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList $mutantArgs -RedirectStandardOutput $mutantOut -RedirectStandardError $mutantErr -WindowStyle Hidden -PassThru
        $mutantProcess.WaitForExit()
        Write-Output "MUTANT_OBSERVED direct-host exit=$($mutantProcess.ExitCode) stderr=$([IO.File]::ReadAllText($mutantErr))"
        $failure = $null
        $mutantResult = if (Test-Path -LiteralPath $result -PathType Leaf) { Get-Content -LiteralPath $result -Raw | ConvertFrom-Json -DateKind String } else { $null }
        if ($mutantResult) { Write-Output "MUTANT_RESULT direct-host status=$($mutantResult.status) exit=$($mutantResult.exit)" }
        Assert-True ($mutantProcess.ExitCode -ne 0 -and $mutantResult -and $mutantResult.status -ceq 'incomplete' -and $mutantResult.dispatchReleased -eq $false) 'MUTANT direct-host fails at admission after exact-owner bypass'
      } else {
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
  $fixturePath = [IO.Path]::GetFullPath($fixtureRoot)
  $tempPath = [IO.Path]::GetFullPath($testRoot)
  if ($fixturePath.StartsWith(([IO.Path]::GetFullPath($controllerRoot) + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $fixturePath -Recurse -Force -ErrorAction SilentlyContinue }
  if ($tempPath.StartsWith(([IO.Path]::GetFullPath([IO.Path]::GetTempPath()) + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $tempPath -Recurse -Force -ErrorAction SilentlyContinue }
  Exit-RoutingDataTestScope $routingScope
}
