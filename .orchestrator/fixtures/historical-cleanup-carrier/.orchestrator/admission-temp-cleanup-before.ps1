$ErrorActionPreference='Stop'
$originalTemp=$env:TEMP;$originalTmp=$env:TMP
$outer=Join-Path ([IO.Path]::GetTempPath()) ('admission-temp-cleanup-test-'+[guid]::NewGuid().ToString('N'))
$privateTemp=Join-Path $outer 'private-temp';$container=Join-Path $outer 'container';$worktree=Join-Path $container 'lane';$runtime=Join-Path $container '.orchestrator'
$guard=Join-Path $PSScriptRoot 'invoke-heavy-verifier.ps1'
function Assert-True($Condition,[string]$Message){if(-not$Condition){throw "ASSERTION FAILED: $Message"}}
function Invoke-TestGit([string[]]$Arguments){$o=@(& git.exe -C $worktree @Arguments 2>&1);if($LASTEXITCODE-ne0){throw "git failed $($o-join"`n")"};return($o-join"`n").Trim()}
function Identity($Process){[pscustomobject]@{pid=$Process.Id;start=$Process.StartTime.ToUniversalTime().ToString('o')}}
function Stop-Exact($Value){$p=Get-Process -Id ([int]$Value.pid) -ErrorAction Stop;Assert-True($p.StartTime.ToUniversalTime().Ticks-eq[datetimeoffset]::Parse([string]$Value.start).ToUniversalTime().Ticks)'fixture kill identity moved';Stop-Process -InputObject $p -Force;$p.WaitForExit()}
function Wait-For([scriptblock]$Condition,[string]$Message){for($i=0;$i-lt400;$i++){if(& $Condition){return};Start-Sleep -Milliseconds 25};throw "timed out: $Message"}
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

  $unrelated=Join-Path $privateTemp 'chase-sets-heavy-admission-unrelated';New-Item -ItemType Directory -Path $unrelated|Out-Null;Set-Content -LiteralPath (Join-Path $unrelated 'keep.txt') -Value keep
  $owned=Join-Path $privateTemp 'chase-sets-heavy-admission-owneddead';$guardedProcess=Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 30') -WindowStyle Hidden -PassThru
  $guarded=Identity $guardedProcess;$attached=Start-AttachedGuard $guarded $owned ('1'*32);Stop-Exact $guarded;$attached.process.WaitForExit()
  $attachedError=$attached.process.StandardError.ReadToEnd();$attachedOutput=$attached.process.StandardOutput.ReadToEnd()
  Assert-True($attached.process.ExitCode-eq0-and-not(Test-Path -LiteralPath $owned)-and(Test-Path -LiteralPath (Join-Path $unrelated 'keep.txt')))"exact hard-killed attempt root was not exclusively cleaned (exit=$($attached.process.ExitCode) owned=$(Test-Path -LiteralPath $owned) unrelated=$(Test-Path -LiteralPath (Join-Path $unrelated 'keep.txt')) stderr=$attachedError stdout=$attachedOutput)"
  $attached.process.Dispose();$guardedProcess.Dispose()

  $liveRoot=Join-Path $privateTemp 'chase-sets-heavy-admission-liveowner';$liveProcess=Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 30') -WindowStyle Hidden -PassThru
  $live=Identity $liveProcess;$liveGuard=Start-AttachedGuard $live $liveRoot ('2'*32);Start-Sleep -Milliseconds 200
  Assert-True((Test-Path -LiteralPath $liveRoot)-and-not$liveGuard.process.HasExited)'live slow owner root was cleaned'
  Stop-Exact $live;$liveGuard.process.WaitForExit();Assert-True(-not(Test-Path -LiteralPath $liveRoot))'live fixture did not clean after exact death';$liveGuard.process.Dispose();$liveProcess.Dispose()

  $relay=Join-Path $outer 'relay.ps1';$childIdentity=Join-Path $outer 'child.json'
  Set-Content -LiteralPath $relay -Value @'
param($IdentityPath)
$child=Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 30') -WindowStyle Hidden -PassThru
[ordered]@{pid=$child.Id;start=$child.StartTime.ToUniversalTime().ToString('o')}|ConvertTo-Json -Compress|Set-Content -LiteralPath $IdentityPath
Start-Sleep -Seconds 30
'@
  $rootProcess=Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList @('-NoProfile','-File',$relay,$childIdentity) -WindowStyle Hidden -PassThru;Wait-For{Test-Path -LiteralPath $childIdentity}'descendant identity'
  $rootIdentity=Identity $rootProcess;$child=Get-Content -LiteralPath $childIdentity -Raw|ConvertFrom-Json -DateKind String;$descRoot=Join-Path $privateTemp 'chase-sets-heavy-admission-descendant';$descGuard=Start-AttachedGuard $rootIdentity $descRoot ('3'*32)
  Stop-Exact $rootIdentity;Start-Sleep -Milliseconds 250;Assert-True((Test-Path -LiteralPath $descRoot)-and-not$descGuard.process.HasExited)'possible surviving descendant was not retained'
  Stop-Exact $child;$descGuard.process.WaitForExit();Assert-True(-not(Test-Path -LiteralPath $descRoot))'descendant-owned root did not clean after the full tree died';$descGuard.process.Dispose();$rootProcess.Dispose()

  $reusedRoot=Join-Path $privateTemp 'chase-sets-heavy-admission-reusedpid';New-Item -ItemType Directory -Path $reusedRoot|Out-Null;Set-Content -LiteralPath (Join-Path $reusedRoot 'result.json') -Value '{}'
  $sleeper=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\ping.exe') -ArgumentList @('-t','127.0.0.1') -WindowStyle Hidden -PassThru;$sleeperIdentity=Identity $sleeper
  $deadWrapperPid=$null;foreach($candidate in 999999..999000){if(@(Get-Process -Id $candidate -ErrorAction SilentlyContinue).Count-eq0-and@(Get-CimInstance Win32_Process -Filter "ParentProcessId = $candidate" -ErrorAction SilentlyContinue).Count-eq0){$deadWrapperPid=$candidate;break}};Assert-True($null-ne$deadWrapperPid)'no dead wrapper fixture identity'
  $lock=Join-Path $runtime 'verify-lock.d';New-Item -ItemType Directory -Path $lock|Out-Null;$owner=[ordered]@{schemaVersion=5;lockId='4'*32;owner='synthetic';lane='lane';branch='synthetic/test';pid=$deadWrapperPid;processStartUtc='2000-01-01T00:00:00.0000000Z';startedUtc=[datetimeoffset]::UtcNow.ToString('o');gate='vitest-full';commandIdentity='a'*64;worktree=$worktree;head=(Invoke-TestGit @('rev-parse','HEAD'));identityMode='branch';state='attached';childPid=$sleeperIdentity.pid;childProcessStartUtc=[datetimeoffset]::Parse($sleeperIdentity.start).AddTicks(-1).ToString('o');admissionRoot=$reusedRoot}
  [IO.File]::WriteAllText((Join-Path $lock 'owner.json'),($owner|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
  $marker=Join-Path $outer 'marker.txt';& $guard -Gate verify:static -Worktree $worktree -Lane lane -Branch synthetic/test -ClaimedHead (Invoke-TestGit @('rev-parse','HEAD')) -ContainerRoot $container -CommandPath (Join-Path $PSHOME 'pwsh.exe') -CommandArgumentList @('-NoProfile','-Command',"Set-Content -LiteralPath '$marker' -Value ran")
  Assert-True((Test-Path -LiteralPath $marker)-and(Test-Path -LiteralPath $reusedRoot))'reused PID became admission-root deletion authority'
  Stop-Exact $sleeperIdentity;$sleeper.Dispose()
  Assert-True(@(Get-ChildItem -LiteralPath $privateTemp -Directory -Filter 'chase-sets-heavy-admission-*').Count-eq2)'unknown/unrelated or reused roots were changed'
  Write-Output 'PASS admission temp cleanup exact hard-kill, live, descendant, reused PID, unrelated/unknown root, and private TEMP controls'
}finally{
  $env:TEMP=$originalTemp;$env:TMP=$originalTmp
  foreach($ownedProcess in @($guardedProcess,$liveProcess,$rootProcess,$sleeper)){
    if ($null -ne $ownedProcess -and $ownedProcess -is [Diagnostics.Process] -and
        $null -ne $ownedProcess.Id -and -not $ownedProcess.HasExited) {
      Stop-Process -Id $ownedProcess.Id -Force -ErrorAction SilentlyContinue
    }
  }
  $resolved=[IO.Path]::GetFullPath($outer);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
  if((Split-Path -Parent $resolved).TrimEnd('\','/')-ne$temp-or(Split-Path -Leaf $resolved)-notlike'admission-temp-cleanup-test-*'){throw "unsafe cleanup $resolved"}
  Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
}
