$ErrorActionPreference='Stop'
$originalTemp=$env:TEMP;$originalTmp=$env:TMP
$outer=Join-Path ([IO.Path]::GetTempPath()) ('admission-temp-cleanup-test-'+[guid]::NewGuid().ToString('N'))
$privateTemp=Join-Path $outer 'private-temp';$container=Join-Path $outer 'container';$worktree=Join-Path $container 'lane';$runtime=Join-Path $container '.orchestrator'
$guard=Join-Path $PSScriptRoot 'invoke-heavy-verifier.ps1'
function Assert-True($Condition,[string]$Message){if(-not$Condition){throw "ASSERTION FAILED: $Message"}}
function Invoke-TestGit([string[]]$Arguments){$o=@(& git.exe -C $worktree @Arguments 2>&1);if($LASTEXITCODE-ne0){throw "git failed $($o-join"`n")"};return($o-join"`n").Trim()}
$ownedIdentities=[Collections.Generic.List[object]]::new()
$fixtures=[Collections.Generic.List[object]]::new()
$completed=$false
function Identity($Process){
  $value=[pscustomobject]@{pid=$Process.Id;start=$Process.StartTime.ToUniversalTime().ToString('o')}
  [void]$Process.SafeHandle # Pin the OS process, not just its reusable PID.
  $ownedIdentities.Add([pscustomobject]@{pid=$value.pid;start=$value.start;process=$Process})
  return $value
}
function Stop-Exact($Value,[string]$Phase,[scriptblock]$ReadStart={param($Process) $Process.StartTime},[scriptblock]$BetweenObservations={}){
  Write-Host "EVIDENCE cleanup requested phase=$Phase pid=$($Value.pid) start=$($Value.start)"
  $matches=@($ownedIdentities|Where-Object{ $_.pid-eq$Value.pid-and$_.start-ceq$Value.start })
  Assert-True($matches.Count-eq1)"fixture ownership refused phase=$Phase pid=$($Value.pid) requestedStart=$($Value.start) matches=$($matches.Count)"
  $p=Get-Process -Id ([int]$Value.pid) -ErrorAction Stop
  try{
    [void]$p.SafeHandle
    & $BetweenObservations
    $actualStart=& $ReadStart $p
    Write-Host ('EVIDENCE cleanup identity '+([ordered]@{phase=$Phase;pid=$Value.pid;requestedStart=$Value.start;actualStart=$actualStart;hasExited=$p.HasExited;name=$p.ProcessName;syntheticStartProbe=($ReadStart.ToString()-cne'param($Process) $Process.StartTime')}|ConvertTo-Json -Compress))
    Assert-True($null-ne$actualStart)"fixture start unreadable; protected phase=$Phase pid=$($Value.pid) requestedStart=$($Value.start)"
    Assert-True($actualStart.ToUniversalTime().Ticks-eq[datetimeoffset]::Parse([string]$Value.start).ToUniversalTime().Ticks)"fixture kill identity moved phase=$Phase pid=$($Value.pid)"
    Assert-True(-not$p.HasExited)"fixture exited before deliberate kill phase=$Phase pid=$($Value.pid)"
    $p.Kill();$p.WaitForExit()
    Write-Host "EVIDENCE cleanup deliberate-kill phase=$Phase pid=$($Value.pid) exit=$($p.ExitCode)"
  }finally{$p.Dispose()}
}
function Wait-For([scriptblock]$Condition,[string]$Message){for($i=0;$i-lt400;$i++){if(& $Condition){return};Start-Sleep -Milliseconds 25};throw "timed out: $Message"}
function Start-Fixture([string]$Phase){
  $release=Join-Path $outer "$Phase.release";$ready=Join-Path $outer "$Phase.ready"
  $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=(Join-Path $PSHOME 'pwsh.exe');$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
  foreach($arg in @('-NoProfile','-NonInteractive','-File',$fixtureScript,$release,$ready)){[void]$start.ArgumentList.Add($arg)}
  $process=[Diagnostics.Process]::Start($start);$identity=Identity $process
  $fixture=[pscustomobject]@{phase=$Phase;process=$process;identity=$identity;release=$release;ready=$ready};$fixtures.Add($fixture)
  Wait-For {Test-Path -LiteralPath $ready} "$Phase ready"
  return $fixture
}
function Assert-Refusal([scriptblock]$Action,[string]$Expected){
  $failure=$null;try{& $Action}catch{$failure=$_.Exception.Message}
  Assert-True($failure-and$failure.Contains($Expected))"expected refusal $Expected; actual=$failure"
  Write-Host "CONTROL cleanup refusal $failure"
}
function Start-AttachedGuard($Guarded,[string]$Root,[string]$Nonce){
  New-Item -ItemType Directory -Path $Root|Out-Null;$result=Join-Path $Root 'result.json'
  $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=(Join-Path $PSHOME 'pwsh.exe');$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
  foreach($arg in @('-NoProfile','-NonInteractive','-File',$guard,'-AdmissionKind','vitest-full','-GuardedPid',"$($Guarded.pid)",'-GuardedProcessStartUtc',[string]$Guarded.start,'-AdmissionNonce',$Nonce,'-AdmissionResultPath',$result,'-AdmissionCommand','synthetic-private-fixture','-Worktree',$worktree,'-Lane','lane','-Branch','synthetic/test','-ClaimedHead',(Invoke-TestGit @('rev-parse','HEAD')),'-ContainerRoot',$container)){[void]$start.ArgumentList.Add($arg)}
  $process=[Diagnostics.Process]::Start($start);Wait-For {Test-Path -LiteralPath $result -PathType Leaf} 'attached admission result';$receipt=Get-Content -LiteralPath $result -Raw|ConvertFrom-Json -DateKind String;Assert-True($receipt.accepted-eq$true)'attached admission was not accepted';return [pscustomobject]@{process=$process;result=$result;root=$Root}
}
try{
  New-Item -ItemType Directory -Path $privateTemp,$worktree,$runtime|Out-Null;$env:TEMP=$privateTemp;$env:TMP=$privateTemp
  Invoke-TestGit @('init','--initial-branch=synthetic/test')|Out-Null;Invoke-TestGit @('config','user.name','Synthetic Temp Test')|Out-Null;Invoke-TestGit @('config','user.email','temp-test@example.invalid')|Out-Null;Invoke-TestGit @('config','commit.gpgsign','false')|Out-Null
  Set-Content -LiteralPath (Join-Path $worktree 'seed.txt') -Value seed;Invoke-TestGit @('add','--','seed.txt')|Out-Null;Invoke-TestGit @('commit','-m','seed')|Out-Null

  $fixtureScript=Join-Path $outer 'fixture.ps1'
  Set-Content -LiteralPath $fixtureScript -Value @'
param($ReleasePath,$ReadyPath)
$ErrorActionPreference='Stop'
$self=Get-Process -Id $PID
Write-Output "ready pid=$PID start=$($self.StartTime.ToUniversalTime().ToString('o'))"
[IO.File]::WriteAllText($ReadyPath,'ready')
while(-not[IO.File]::Exists($ReleasePath)){Start-Sleep -Milliseconds 25}
Write-Output "released pid=$PID exit=0"
exit 0
'@

  # Immutable before helper, with only a barrier inserted between enumeration
  # and StartTime. With the launch handle retained, the old helper silently
  # accepts normal exit as a hard kill. The candidate must refuse that lifecycle.
  $beforeSource=(& git -C $PSScriptRoot show 'f85f146380fb82dcee44accba762032f51987bf4:.orchestrator/admission-temp-cleanup.test.ps1')-join"`n"
  Assert-True($LASTEXITCODE-eq0)'immutable cleanup carrier unavailable'
  $beforeLine=($beforeSource-split"`n"|Where-Object{$_-like'function Stop-Exact*'})
  Assert-True(@($beforeLine).Count-eq1)'immutable Stop-Exact ambiguous'
  $beforeLine=$beforeLine.Replace('Stop-Exact($Value)','Stop-Before($Value,[scriptblock]$BetweenObservations)').Replace(';Assert-True',';& $BetweenObservations;Assert-True')
  . ([scriptblock]::Create($beforeLine))
  foreach($arm in @('before','candidate')){
    $exitFixture=Start-Fixture "exit-between-$arm"
    $releaseExit={
      Write-Host ('EVIDENCE cleanup exit-before '+([ordered]@{phase=$exitFixture.phase;requested=$exitFixture.identity;hasExited=$exitFixture.process.HasExited;cim=@(Get-CimInstance Win32_Process -Filter "ProcessId = $($exitFixture.identity.pid)"|Select-Object ProcessId,ParentProcessId,CreationDate,Name,CommandLine)}|ConvertTo-Json -Depth 5 -Compress))
      Set-Content -LiteralPath $exitFixture.release -Value release
      $exitFixture.process.WaitForExit()
      Assert-True($exitFixture.process.ExitCode-eq0)'barrier child did not exit normally'
      Write-Host "EVIDENCE cleanup exit-after phase=$($exitFixture.phase) pid=$($exitFixture.identity.pid) exit=$($exitFixture.process.ExitCode) stdout=$($exitFixture.process.StandardOutput.ReadToEnd()) stderr=$($exitFixture.process.StandardError.ReadToEnd())"
    }
    if($arm-eq'before'){
      Stop-Before $exitFixture.identity $releaseExit
      Assert-True($exitFixture.process.ExitCode-eq0)'before arm did not retain the normal exit'
      Write-Host 'CONTROL cleanup before falsely accepted normal exit as deliberate kill'
    }
    else{Assert-Refusal {Stop-Exact $exitFixture.identity $exitFixture.phase -BetweenObservations $releaseExit} 'exited before deliberate kill'}
  }

  $safeFixture=Start-Fixture 'unsafe-identity';$safe=$safeFixture.identity
  Assert-Refusal {Stop-Exact $safe 'unreadable-live' -ReadStart {param($Process) $null}} 'start unreadable; protected'
  Assert-True(-not$safeFixture.process.HasExited)'unreadable live process was killed'
  $wrongStart=[pscustomobject]@{pid=$safe.pid;start=[datetimeoffset]::Parse($safe.start).AddTicks(-1).ToString('o')}
  Assert-Refusal {Stop-Exact $wrongStart 'reused-or-wrong-start'} 'ownership refused'
  $ownedIdentities.Add($ownedIdentities[$ownedIdentities.Count-1])
  Assert-Refusal {Stop-Exact $safe 'ambiguous'} 'ownership refused'
  $ownedIdentities.RemoveAt($ownedIdentities.Count-1)
  $foreign=[pscustomobject]@{pid=$PID;start=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')}
  Assert-Refusal {Stop-Exact $foreign 'foreign'} 'ownership refused'
  Assert-True(-not$safeFixture.process.HasExited)'unsafe identity control killed the real fixture'
  Stop-Exact $safe 'unsafe-controls-complete'

  $unrelated=Join-Path $privateTemp 'chase-sets-heavy-admission-unrelated';New-Item -ItemType Directory -Path $unrelated|Out-Null;Set-Content -LiteralPath (Join-Path $unrelated 'keep.txt') -Value keep
  $owned=Join-Path $privateTemp 'chase-sets-heavy-admission-owneddead';$guardedFixture=Start-Fixture 'hard-kill';$guardedProcess=$guardedFixture.process
  $guarded=$guardedFixture.identity;$attached=Start-AttachedGuard $guarded $owned ('1'*32);Stop-Exact $guarded 'hard-kill';$attached.process.WaitForExit()
  $attachedError=$attached.process.StandardError.ReadToEnd();$attachedOutput=$attached.process.StandardOutput.ReadToEnd()
  Assert-True($attached.process.ExitCode-eq0-and-not(Test-Path -LiteralPath $owned)-and(Test-Path -LiteralPath (Join-Path $unrelated 'keep.txt')))"exact hard-killed attempt root was not exclusively cleaned (exit=$($attached.process.ExitCode) owned=$(Test-Path -LiteralPath $owned) unrelated=$(Test-Path -LiteralPath (Join-Path $unrelated 'keep.txt')) stderr=$attachedError stdout=$attachedOutput)"
  $attached.process.Dispose()

  $liveRoot=Join-Path $privateTemp 'chase-sets-heavy-admission-liveowner';$liveFixture=Start-Fixture 'live-owner';$liveProcess=$liveFixture.process
  $live=$liveFixture.identity;$liveGuard=Start-AttachedGuard $live $liveRoot ('2'*32);Start-Sleep -Milliseconds 200
  Assert-True((Test-Path -LiteralPath $liveRoot)-and-not$liveGuard.process.HasExited)'live slow owner root was cleaned'
  Stop-Exact $live 'live-owner';$liveGuard.process.WaitForExit();Assert-True(-not(Test-Path -LiteralPath $liveRoot))'live fixture did not clean after exact death';$liveGuard.process.Dispose()

  $relay=Join-Path $outer 'relay.ps1';$childIdentity=Join-Path $outer 'child.json'
  Set-Content -LiteralPath $relay -Value @'
param($IdentityPath,$FixtureScript,$ReleasePath,$ReadyPath)
$child=Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList @('-NoProfile','-File',$FixtureScript,$ReleasePath,$ReadyPath) -RedirectStandardOutput "$IdentityPath.stdout.log" -RedirectStandardError "$IdentityPath.stderr.log" -WindowStyle Hidden -PassThru
[ordered]@{pid=$child.Id;start=$child.StartTime.ToUniversalTime().ToString('o')}|ConvertTo-Json -Compress|Set-Content -LiteralPath $IdentityPath
while(-not[IO.File]::Exists($ReleasePath)){Start-Sleep -Milliseconds 25}
$child.WaitForExit()
'@
  $descendantRelease=Join-Path $outer 'descendant.release';$descendantReady=Join-Path $outer 'descendant.ready'
  $rootProcess=Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList @('-NoProfile','-File',$relay,$childIdentity,$fixtureScript,$descendantRelease,$descendantReady) -WindowStyle Hidden -PassThru;Wait-For{Test-Path -LiteralPath $childIdentity}'descendant identity'
  $rootIdentity=Identity $rootProcess;$child=Get-Content -LiteralPath $childIdentity -Raw|ConvertFrom-Json -DateKind String;$descRoot=Join-Path $privateTemp 'chase-sets-heavy-admission-descendant';$descGuard=Start-AttachedGuard $rootIdentity $descRoot ('3'*32)
  Wait-For {Test-Path -LiteralPath $descendantReady} 'descendant ready'
  $childProcess=Get-Process -Id $child.pid -ErrorAction Stop;$observedChild=Identity $childProcess
  Assert-True($observedChild.start-ceq$child.start)'descendant identity moved before registration'
  Stop-Exact $rootIdentity 'descendant-parent';Start-Sleep -Milliseconds 250;Assert-True((Test-Path -LiteralPath $descRoot)-and-not$descGuard.process.HasExited)'possible surviving descendant was not retained'
  Assert-True(-not$childProcess.HasExited)'descendant did not survive parent death'
  Stop-Exact $child 'descendant-child';$descGuard.process.WaitForExit();Assert-True(-not(Test-Path -LiteralPath $descRoot))'descendant-owned root did not clean after the full tree died';$descGuard.process.Dispose()

  $reusedRoot=Join-Path $privateTemp 'chase-sets-heavy-admission-reusedpid';New-Item -ItemType Directory -Path $reusedRoot|Out-Null;Set-Content -LiteralPath (Join-Path $reusedRoot 'result.json') -Value '{}'
  $sleeper=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\ping.exe') -ArgumentList @('-t','127.0.0.1') -WindowStyle Hidden -PassThru;$sleeperIdentity=Identity $sleeper
  $deadWrapperPid=$null;foreach($candidate in 999999..999000){if(@(Get-Process -Id $candidate -ErrorAction SilentlyContinue).Count-eq0-and@(Get-CimInstance Win32_Process -Filter "ParentProcessId = $candidate" -ErrorAction SilentlyContinue).Count-eq0){$deadWrapperPid=$candidate;break}};Assert-True($null-ne$deadWrapperPid)'no dead wrapper fixture identity'
  $lock=Join-Path $runtime 'verify-lock.d';New-Item -ItemType Directory -Path $lock|Out-Null;$owner=[ordered]@{schemaVersion=5;lockId='4'*32;owner='synthetic';lane='lane';branch='synthetic/test';pid=$deadWrapperPid;processStartUtc='2000-01-01T00:00:00.0000000Z';startedUtc=[datetimeoffset]::UtcNow.ToString('o');gate='vitest-full';commandIdentity='a'*64;worktree=$worktree;head=(Invoke-TestGit @('rev-parse','HEAD'));identityMode='branch';state='attached';childPid=$sleeperIdentity.pid;childProcessStartUtc=[datetimeoffset]::Parse($sleeperIdentity.start).AddTicks(-1).ToString('o');admissionRoot=$reusedRoot}
  [IO.File]::WriteAllText((Join-Path $lock 'owner.json'),($owner|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
  $marker=Join-Path $outer 'marker.txt';& $guard -Gate verify:static -Worktree $worktree -Lane lane -Branch synthetic/test -ClaimedHead (Invoke-TestGit @('rev-parse','HEAD')) -ContainerRoot $container -CommandPath (Join-Path $PSHOME 'pwsh.exe') -CommandArgumentList @('-NoProfile','-Command',"Set-Content -LiteralPath '$marker' -Value ran")
  Assert-True((Test-Path -LiteralPath $marker)-and(Test-Path -LiteralPath $reusedRoot))'reused PID became admission-root deletion authority'
  Stop-Exact $sleeperIdentity 'reused-pid'
  Assert-True(@(Get-ChildItem -LiteralPath $privateTemp -Directory -Filter 'chase-sets-heavy-admission-*').Count-eq2)'unknown/unrelated or reused roots were changed'
  Write-Output 'PASS admission temp cleanup exact hard-kill, live, descendant, reused PID, unrelated/unknown root, and private TEMP controls'
  $completed=$true
}finally{
  $env:TEMP=$originalTemp;$env:TMP=$originalTmp
  foreach($fixture in $fixtures){Set-Content -LiteralPath $fixture.release -Value release}
  if($descendantRelease){Set-Content -LiteralPath $descendantRelease -Value release}
  foreach($ownedIdentity in $ownedIdentities){
    $ownedProcess=$ownedIdentity.process
    if($null-ne$ownedProcess.Id){
      if(-not$ownedProcess.HasExited-and$ownedProcess-eq$sleeper){Stop-Exact $ownedIdentity 'finally-ping'}
      $ownedProcess.WaitForExit();$ownedProcess.Dispose()
    }
  }
  $resolved=[IO.Path]::GetFullPath($outer);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
  if((Split-Path -Parent $resolved).TrimEnd('\','/')-ne$temp-or(Split-Path -Leaf $resolved)-notlike'admission-temp-cleanup-test-*'){throw "unsafe cleanup $resolved"}
  if($completed){Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue}
  else{Write-Host "RETAINED failed cleanup fixture $resolved"}
}
