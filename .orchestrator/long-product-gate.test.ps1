[CmdletBinding()]
param(
  [ValidateSet('supervisor','mutants')][string]$Part = '',
  [ValidateSet('','direct-host','stale-result','verifier-override')][string]$Mutant = ''
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
  $fakeVerifier = @'
param([string]$Gate,[string]$Worktree,[string]$Lane,[string]$Branch,[string]$ClaimedHead,[string]$ContainerRoot)
$invocation = [ordered]@{ gate=$Gate; worktree=$Worktree; lane=$Lane; branch=$Branch; head=$ClaimedHead; containerRoot=$ContainerRoot }
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'fake-verifier-invocation.json'), ($invocation | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
Write-Output 'SYNTHETIC_VERIFIER_RETURNED'
exit 0
'@
  Write-Text (Join-Path $orchestrator 'invoke-heavy-verifier.ps1') $fakeVerifier
  return $orchestrator
}
function New-LongGateFixture([string]$Root) {
  $runtime = Join-Path $Root 'runtime'; $worktree = Join-Path $Root 'lane-230'
  New-Item -ItemType Directory -Path $runtime, $worktree | Out-Null
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
function Invoke-LongGateProcess($Fixture, [string]$Supervisor, [string]$LaunchId, [string]$ResultPath, [switch]$Preseed) {
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
$childOut=Join-Path $Runtime "child-$LaunchId.out";$childErr=Join-Path $Runtime "child-$LaunchId.err"
$child=Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList @('-NoProfile','-NonInteractive','-File',$Supervisor,'-RuntimeRoot',$Runtime,'-LaunchId',$LaunchId,'-Worktree',$Worktree,'-Lane','lane-230','-Branch',$Branch,'-ClaimedHead',$Head,'-ResultPath',$Result) -RedirectStandardOutput $childOut -RedirectStandardError $childErr -WindowStyle Hidden -PassThru
$ownership=Join-Path $Runtime "dispatch-launch-$LaunchId.json"
$record=[ordered]@{schemaVersion=4;launchId=$LaunchId;laneRole='implementation';promptPath=(Join-Path $Runtime "dispatch-heavy-verifier-$LaunchId.prompt.txt");reviewIsolationRoot=$null;launcherPid=$PID;launcherStartIdentity=(Get-DispatchProcessStartIdentity $PID);recordedAt=[DateTime]::UtcNow.ToString('o');state='started';childPid=$child.Id;childStartIdentity=(Get-DispatchProcessStartIdentity $child.Id);worktree=$Worktree;lane=$Lane;identityMode='branch';branch=$Branch;head=$Head;label='synthetic-long-gate';transcriptPath=(Join-Path $Runtime 'synthetic-long-gate.jsonl')}
if ([string]::IsNullOrWhiteSpace($ownership)) { throw 'synthetic runner ownership path is empty' }
Write-DispatchOwnershipRecord ([string]$ownership) $record -CreateNew
$child.WaitForExit(); if($child.ExitCode -ne 0){Write-Error (Get-Content -Raw $childErr)}; exit $child.ExitCode
'@
  Write-Text $runner $runnerSource
  $arguments = @('-NoProfile','-NonInteractive','-File',$runner,'-Module',$module,'-Supervisor',$Supervisor,'-Runtime',$Fixture.runtime,'-Worktree',$Fixture.worktree,'-Lane','lane-230','-Branch',$Fixture.branch,'-Head',$Fixture.head,'-LaunchId',$LaunchId,'-Result',$ResultPath)
  $out = Join-Path $Fixture.root "runner-$LaunchId.out"; $err = Join-Path $Fixture.root "runner-$LaunchId.err"
  $process = Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList $arguments -RedirectStandardOutput $out -RedirectStandardError $err -WindowStyle Hidden -PassThru
  $process.WaitForExit()
  if ($process.ExitCode -ne 0) { Write-Output "RUNNER_OBSERVED launch=$LaunchId exit=$($process.ExitCode) stderr=$([IO.File]::ReadAllText($err))" }
  return [int]$process.ExitCode
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
    $launcher = $productionDispatch
    $prompt = Join-Path $fixture.runtime 'dispatch-prompt.txt'; Write-Text $prompt 'synthetic dispatch prompt'
    $requestIdentity = 'a' * 64; $ackPath = Join-Path $fixture.runtime "dispatch-start-$requestIdentity.json"
    $label = 'synthetic-long-product-gate'
    & $launcher -Harness codex -Model gpt-6.1-sol -Effort high -LaneRole implementation -Row 4 -Placement provisional `
      -Issue 90230 -PromptFile $prompt -Worktree $fixture.worktree -Label $label -ExecutablePath (Join-Path $PSHOME 'pwsh.exe') `
      -LongProductGate -TestRuntimeRoot $fixture.runtime -TestTempRoot $testRoot `
      -StartRequestIdentity $requestIdentity -StartAcknowledgementPath $ackPath | Out-Null
    Assert-True ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $ackPath)) 'normal dispatch starts the fixed supervisor and publishes its acknowledgement'
    $ack = Get-Content -LiteralPath $ackPath -Raw | ConvertFrom-Json -DateKind String
    Assert-True ($ack.longProductGate.schema -ceq 'long-product-gate/v1' -and $ack.longProductGate.gate -ceq 'test:scripts' -and $ack.longProductGate.hostWatchSeconds -eq 900 -and $ack.longProductGate.resultPath -like '*long-product-gate-*.json') 'acknowledgement binds the fixed gate, 900-second host watch, and exact launch result'
    $routeResult = Get-Content -LiteralPath $ack.longProductGate.resultPath -Raw | ConvertFrom-Json -DateKind String
    Assert-True ($routeResult.schema -ceq 'long-product-gate/v1' -and $routeResult.status -ceq 'passed' -and $routeResult.dispatchReleased -eq $true -and
      $routeResult.launchId -ceq $ack.launchId -and $routeResult.lane -ceq (Split-Path -Leaf $fixture.worktree) -and
      $routeResult.worktree -ceq ([IO.Path]::GetFullPath($fixture.worktree).TrimEnd('\','/')) -and
      $routeResult.branch -ceq $fixture.branch -and $routeResult.head -ceq $fixture.head -and $routeResult.gate -ceq 'test:scripts') 'normal dispatch reaches terminal passed result only after exact release'
    Assert-True (@(Get-ChildItem -LiteralPath $fixture.runtime -Filter 'dispatch-launch-*.json' -File).Count -eq 0) 'normal dispatch leaves no retained owner after result pass'
    Write-Output 'PASS AC1 normal dispatch supervisor ancestry handoff and AC3 atomic passed result'

    $id = [guid]::NewGuid().ToString(); $result = Join-Path $fixture.runtime "long-product-gate-$id.json"
    $directArgs = @('-NoProfile','-NonInteractive','-File',$supervisor,'-RuntimeRoot',$fixture.runtime,'-LaunchId',$id,'-Worktree',$fixture.worktree,'-Lane','lane-230','-Branch',$fixture.branch,'-ClaimedHead',$fixture.head,'-ResultPath',$result)
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
    $mutantNames = if ($Mutant) { @($Mutant) } else { @('direct-host','stale-result') }
    foreach ($mutantName in $mutantNames) {
      $mutantPath = New-Mutant $source $mutantName $fixture
      $id = [guid]::NewGuid().ToString(); $result = Join-Path $fixture.runtime "long-product-gate-$id.json"
      if ($mutantName -ceq 'direct-host') {
        $mutantArgs = @('-NoProfile','-NonInteractive','-File',$mutantPath,'-RuntimeRoot',$fixture.runtime,'-LaunchId',$id,'-Worktree',$fixture.worktree,'-Lane','lane-230','-Branch',$fixture.branch,'-ClaimedHead',$fixture.head,'-ResultPath',$result)
        $mutantOut = Join-Path $fixture.root 'mutant.out'; $mutantErr = Join-Path $fixture.root 'mutant.err'
        $mutantProcess = Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList $mutantArgs -RedirectStandardOutput $mutantOut -RedirectStandardError $mutantErr -WindowStyle Hidden -PassThru
        $mutantProcess.WaitForExit()
        Write-Output "MUTANT_OBSERVED direct-host exit=$($mutantProcess.ExitCode) stderr=$([IO.File]::ReadAllText($mutantErr))"
        $failure = $null
        try { Assert-True ($mutantProcess.ExitCode -ne 0) 'MUTANT direct-host fails at exact-owner assertion' } catch { $failure = $_.Exception.Message }
        Assert-True ($failure -like '*MUTANT direct-host fails at exact-owner assertion*') 'MUTANT direct-host reaches its named assertion'
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
