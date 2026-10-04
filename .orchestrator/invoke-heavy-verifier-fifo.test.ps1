[CmdletBinding()]
param([string]$GuardPath=(Join-Path $PSScriptRoot 'invoke-heavy-verifier.ps1'),[ValidateSet('fifo','unfair-reclaim','prune-live')][string]$Mutant,[ValidateSet('Both','Identical','Continuation')][string]$Shape='Both')
$ErrorActionPreference='Stop'
if(-not$GuardPath){$GuardPath=Join-Path $PSScriptRoot 'invoke-heavy-verifier.ps1'}
$root=Join-Path ([IO.Path]::GetTempPath()) ('synthetic-fifo-8490-'+[guid]::NewGuid().ToString('N'))
$runtime=Join-Path $root '.orchestrator';$worktree=Join-Path $root 'candidate'
$resultRoot=Join-Path $worktree '.orchestrator/artifacts'
$lock=Join-Path $runtime 'controller-verify-lock.d';$ownerPath=Join-Path $lock 'owner.json'
$queuePath=Join-Path $runtime 'controller-verify-queue.json'
function Assert-Fifo($Value,[string]$Name){if(-not$Value){throw "ASSERTION FAILED: $Name"};Write-Output "PASS $Name"}
function Invoke-Fifo([string]$Lane,[switch]$Continue,[switch]$Cancel){
  $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
  $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
  $arguments=@('-NoProfile','-NonInteractive','-File',$GuardPath,'-ControllerBattery','-ContainerRoot',$root,'-Worktree',$worktree,'-Lane',$Lane,'-Branch','synthetic/fifo','-ClaimedHead',$head,'-ControllerBatteryResultPath',(Join-Path $resultRoot "$Lane.result.json"))
  if($Continue){$arguments+=@('-ControllerBatteryPriorResultPath',(Join-Path $resultRoot "$Lane.prior.json"),'-ControllerBatteryOnFailure','all')}
  if($Cancel){$arguments+='-CancelControllerClaim'}
  foreach($arg in $arguments){$start.ArgumentList.Add($arg)}
  $p=[Diagnostics.Process]::Start($start)
  try{$out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync();$p.WaitForExit();return [pscustomobject]@{code=$p.ExitCode;text=$out.Result+$err.Result}}finally{$p.Dispose()}
}
function Set-Barrier {
  [void][IO.Directory]::CreateDirectory($lock)
  $self=Get-Process -Id $PID
  $value=[ordered]@{schemaVersion=4;lockId=('1'*32);owner='synthetic';lane='A';branch='synthetic/fifo';worktree=$worktree;head=$head;identityMode='branch';pid=$PID;processStartUtc=$self.StartTime.ToUniversalTime().ToString('o');startedUtc=[DateTime]::UtcNow.ToString('o');gate='script-battery';commandIdentity=('b'*64);state='launching';childPid=$null;childProcessStartUtc=$null}
  [IO.File]::WriteAllText($ownerPath,($value|ConvertTo-Json -Compress))
}
function Release-Barrier {
  # Only this fixture's owner is removed at the explicit release barrier.
  $value=Get-Content $ownerPath -Raw|ConvertFrom-Json
  if($value.lockId-cne('1'*32)-or$value.pid-ne$PID){throw 'foreign fixture owner'}
  [IO.File]::Delete($ownerPath);[IO.Directory]::Delete($lock)
}
try {
  [void][IO.Directory]::CreateDirectory($runtime);[void][IO.Directory]::CreateDirectory((Join-Path $worktree '.orchestrator'))
  if($Mutant){
    $source=[IO.File]::ReadAllText($GuardPath)
    $anchor='if($position-ne1){throw "heavy-verifier: queued;$script:controllerQueueDiagnostic"}'
    if(-not$source.Contains($anchor)){throw 'FIFO mutant anchor absent'}
    $replacement=if($Mutant-ceq'fifo'){'if($false){throw "heavy-verifier: queued;$script:controllerQueueDiagnostic"}'}else{'if($position-ne1-and$Lane-cne''A''){throw "heavy-verifier: queued;$script:controllerQueueDiagnostic"}'}
    if($Mutant-ceq'prune-live'){
      $anchor="if(`$state-cin@('dead','reused'))"
      if(-not$source.Contains($anchor)){throw 'claimant mutant anchor absent'}
      $replacement='if($true)'
    }
    $GuardPath=Join-Path $root 'mutant.ps1';[IO.File]::WriteAllText($GuardPath,$source.Replace($anchor,$replacement))
  }
  $stub=Join-Path $worktree '.orchestrator/controller-release-battery.ps1'
  [IO.File]::WriteAllText($stub,@'
param($ControllerRoot,$ExpectedControllerHead,$EvidenceReceiptPath,$ResultPath,$BaselineHead,$RepairIssue,$RepairHistoryPath,$Scope,$PriorResultPath,$OnFailure,[switch]$AdmissionOwned)
$owner=Get-Content (Join-Path (Split-Path -Parent $ControllerRoot) '.orchestrator/controller-verify-lock.d/owner.json') -Raw|ConvertFrom-Json
if($owner.lockId-cne$env:CHASE_SETS_HEAVY_SLOT_ID){throw 'bad synthetic admission token'}
[IO.File]::WriteAllText($ResultPath,(@{head=$ExpectedControllerHead;lane=$owner.lane;commandIdentity=$owner.commandIdentity;prior=$PriorResultPath;onFailure=$OnFailure}|ConvertTo-Json -Compress))
'@)
  & git -C $worktree init -q -b synthetic/fifo
  [IO.File]::WriteAllText((Join-Path $worktree '.gitignore'),'.orchestrator/artifacts/')
  & git -C $worktree -c user.name=Synthetic -c user.email=synthetic@example.invalid add .
  & git -C $worktree -c user.name=Synthetic -c user.email=synthetic@example.invalid commit -qm fixture
  $head=(& git -C $worktree rev-parse HEAD).Trim()
  [void][IO.Directory]::CreateDirectory($resultRoot)
  $shapes=if($Shape-ceq'Identical'){@($false)}elseif($Shape-ceq'Continuation'){@($true)}else{@($false,$true)}
  foreach($continuation in $shapes){
    $initial=Invoke-Fifo A
    Assert-Fifo ($initial.code-eq0) "AC2 no-waiter admission (observed=$($initial.text))"
    $original=Get-Content (Join-Path $resultRoot 'A.result.json') -Raw|ConvertFrom-Json
    [IO.File]::Move((Join-Path $resultRoot 'A.result.json'),(Join-Path $resultRoot 'A.prior.json'),$true)
    $link=Join-Path $resultRoot 'A.result.json.admission.json'
    if(Test-Path $link){[IO.File]::Move($link,(Join-Path $resultRoot 'A.prior.json.admission.json'),$true)}
    Set-Barrier
    $raw=[IO.File]::ReadAllText($ownerPath)
    $b=Invoke-Fifo B
    Assert-Fifo ($b.code-ne0-and-not(Test-Path (Join-Path $resultRoot 'B.result.json'))-and[IO.File]::ReadAllText($ownerPath)-ceq$raw) 'AC4 queued no-body preserves live owner bytes'
    Release-Barrier
    $a=Invoke-Fifo A -Continue:$continuation
    Assert-Fifo ($a.code-eq73-and-not(Test-Path (Join-Path $resultRoot 'A.result.json'))) "AC2 releasing lane cannot reclaim ahead of waiter continuation=$continuation (exit=$($a.code))"
    if($continuation){Assert-Fifo ($a.text-match"priorEvidence=$($original.commandIdentity)") 'AC2 own same-head evidence links while continuation remains queued'}
    $before=[IO.File]::ReadAllText($queuePath)
    $retry=Invoke-Fifo A -Continue:$continuation
    Assert-Fifo ($retry.code-eq73-and$retry.text-match'position=2'-and[IO.File]::ReadAllText($queuePath)-ceq$before) 'AC1 reversed retry neither duplicates nor refreshes ticket'
    $b=Invoke-Fifo B
    Assert-Fifo ($b.code-eq0-and(Test-Path (Join-Path $resultRoot 'B.result.json'))) 'AC1 earliest claimant executes after explicit release barrier'
    $a=Invoke-Fifo A -Continue:$continuation
    Assert-Fifo ($a.code-eq0) 'AC3 refused wrapper exits, live claimant retries and admits'
    $result=Get-Content (Join-Path $resultRoot 'A.result.json') -Raw|ConvertFrom-Json
    Assert-Fifo (($result.commandIdentity-cne$original.commandIdentity)-eq$continuation) 'AC2 distinct continuation command hash, no priority normalization'
    Assert-Fifo (($result.prior-ne'')-eq$continuation) 'AC2 prior evidence forwarded separately from queue priority'
    foreach($file in @('B.result.json','A.result.json','B.result.json.admission.json','A.result.json.admission.json')){[IO.File]::Delete((Join-Path $resultRoot $file))}
  }
  Set-Barrier
  $a=Invoke-Fifo abandoned
  $b=Invoke-Fifo survivor
  $cancel=Invoke-Fifo abandoned -Cancel
  Assert-Fifo ($cancel.code-eq0-and(Test-Path $ownerPath)) 'AC3 non-retrying claimant explicitly withdraws without preempting owner'
  Release-Barrier
  Assert-Fifo ((Invoke-Fifo survivor).code-eq0) 'AC3 cancelled claimant no longer blocks eligible waiter'
  # The production reducer with exact controlled process observations. A dead
  # invocation is irrelevant; these records belong to stable claimant sessions.
  $ast=[Management.Automation.Language.Parser]::ParseFile($GuardPath,[ref]$null,[ref]$null)
  foreach($function in $ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]},$false)){
    . ([scriptblock]::Create($function.Extent.Text))
  }
  $controllerQueuePath=$queuePath;$Lane='matrix-new';$worktreeFull=$worktree
  $acquiredGitIdentity=@{Head=$head};$commandIdentity='c'*64
  $controllerClaimant=@{pid=$PID;start=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')}
  $CancelControllerClaim=$false
  $isControllerBattery=$true;$ControllerBatteryOnFailure='all';$ControllerBatteryPriorResultPath=Join-Path $resultRoot 'A.prior.json'
  $Lane='A'
  Assert-Fifo ($null-ne(Get-ControllerPriorLink)) 'AC2 exact lane/head prior link positive control'
  $Lane='foreign';Assert-Fifo ($null-eq(Get-ControllerPriorLink)) 'AC2 foreign lane inherits no linkage'
  $Lane='A';$linkPath="$ControllerBatteryPriorResultPath.admission.json";$linkRaw=[IO.File]::ReadAllText($linkPath)
  $foreign=$linkRaw|ConvertFrom-Json;$foreign.worktree=$root
  [IO.File]::WriteAllText($linkPath,($foreign|ConvertTo-Json -Compress))
  Assert-Fifo ($null-eq(Get-ControllerPriorLink)) 'AC2 foreign-worktree result inherits no linkage'
  [IO.File]::WriteAllText($linkPath,$linkRaw)
  $Lane='A';$acquiredGitIdentity.Head='e'*40;Assert-Fifo ($null-eq(Get-ControllerPriorLink)) 'AC2 changed head inherits no linkage'
  $acquiredGitIdentity.Head=$head;$isControllerBattery=$false;Assert-Fifo ($null-eq(Get-ControllerPriorLink)) 'AC2 unrelated command inherits no linkage'
  $isControllerBattery=$true;$Lane='matrix-new'
  function Get-ProcessIdentityState($ProcessId,[string]$StartIdentity){if($ProcessId-eq$PID-and$StartIdentity-ceq$controllerClaimant.start){return 'live'};return $script:claimantState}
  function Test-PossibleOwnedChild($Record){return $script:possibleChild}
  foreach($state in @('dead','reused','live','ambiguous')){
    foreach($possible in @($false,$null)){
      $script:claimantState=$state;$script:possibleChild=$possible
      $claim=@{ticket=[long]1;lane='matrix-old';worktree=$worktree;head=$head;commandIdentity=('d'*64);pid=999991;processStartUtc='2000-01-01T00:00:00.0000000Z'}
      [IO.File]::WriteAllText($queuePath,(@{schemaVersion=1;nextTicket=[long]2;claims=@($claim)}|ConvertTo-Json -Depth 5 -Compress))
      $accepted=$false;try{$admission=Enter-ControllerQueue;$accepted=$null-ne$admission}catch{if($_.Exception.Message-notlike'heavy-verifier: queued;*'){throw}}
      $expected=$state-in@('dead','reused')-and$possible-eq$false
      Assert-Fifo ($accepted-eq$expected) "AC3 claimant=$state descendant=$possible prunes only proven obsolete identity"
      $q=Get-Content $queuePath -Raw|ConvertFrom-Json
      Assert-Fifo (($q.claims.Count-eq1)-eq$expected) 'AC3 exact prior ticket retained on live/unknown identity'
    }
  }
  $queueRaw=[IO.File]::ReadAllText($queuePath)
  [IO.File]::WriteAllText($queuePath,'{"schemaVersion":1,"nextTicket":2,"claims":[],"claims":[]}')
  $invalid=[IO.File]::ReadAllText($queuePath);$refused=$false
  try{Enter-ControllerQueue|Out-Null}catch{$refused=$true}
  Assert-Fifo ($refused-and[IO.File]::ReadAllText($queuePath)-ceq$invalid) 'AC3 malformed/duplicate queue is byte-exact fail closed'
  [IO.File]::WriteAllText($queuePath,$queueRaw)
  $script:claimantState='reused';$script:possibleChild=$false
  $claim.pid=$PID;$claim.lane=$Lane;$claim.commandIdentity=$commandIdentity
  [IO.File]::WriteAllText($queuePath,(@{schemaVersion=1;nextTicket=[long]2;claims=@($claim)}|ConvertTo-Json -Depth 5 -Compress))
  $admission=Enter-ControllerQueue
  Assert-Fifo ($admission.ticket-eq2-and$admission.snapshot.record.claims[0].processStartUtc-ceq$controllerClaimant.start) 'AC3 reused PID cannot inherit the old exact ticket'
  $snapshot=Read-ControllerQueue
  $replacement=$snapshot.raw.Replace('"nextTicket":3','"nextTicket":4')
  [IO.File]::WriteAllText($queuePath,$replacement)
  $refused=$false;try{Write-ControllerQueue $snapshot}catch{$refused=$_.Exception.Message-like'*queue replaced*'}
  Assert-Fifo ($refused-and[IO.File]::ReadAllText($queuePath)-ceq$replacement) 'AC3 replaced queue snapshot is never overwritten'
  Write-Output 'PASS FIFO runtime barrier suite'
} finally {
  $resolved=[IO.Path]::GetFullPath($root)
  if(-not$resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)-or(Split-Path -Leaf $resolved)-notlike'synthetic-fifo-8490-*'){throw 'unsafe fixture cleanup'}
  if(Test-Path $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
