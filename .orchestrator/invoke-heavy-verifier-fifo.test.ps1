[CmdletBinding()]
param(
  [ValidateSet('', 'bypass-fifo', 'skip-absent-head', 'renumber-on-retry', 'prune-live', 'never-expire', 'reset-without-authority', 'quarantine-early', 'ignore-marker', 'rename-completes', 'controller-bypass-fifo', 'controller-command-link')][string]$Mutant = '',
  [string]$GuardRevision = '',
  [ValidateSet('all','order','lifecycle','authority','recovery','isolation','controller')][string]$Part = 'all',
  # Bound for each fixture step (driver start, one guarded attempt). A loaded
  # host can spend most of a minute inside one cold guard process.
  [ValidateRange(10,1800)][int]$FixtureTimeoutSeconds = 300,
  # Runs each named mutant as a child suite. A mutant counts as killed only
  # when the child's first assertion failure is that mutant's own assertion.
  [switch]$MutantMatrix,
  [string[]]$MatrixMutants = @(),
  [ValidateRange(1,11)][int]$MatrixThrottle = 1
)
$ErrorActionPreference = 'Stop'
$suiteClock = [Diagnostics.Stopwatch]::StartNew()
$repo = Split-Path -Parent $PSScriptRoot
$expectedKills = [ordered]@{
  'bypass-fifo' = 'MUTANT bypass-fifo AC1 Gate B first refusal'
  'skip-absent-head' = 'MUTANT skip-absent-head AC1 Gate absent-head refusal position=2'
  'renumber-on-retry' = 'MUTANT renumber-on-retry AC1 retry keeps number and order'
  'prune-live' = 'MUTANT prune-live AC3 lifecycle live descendant=false age=599'
  'never-expire' = 'MUTANT never-expire AC3 lifecycle dead descendant=unknown age=601'
  'reset-without-authority' = 'MUTANT reset-without-authority AC4 authority guard leaves queue and quarantine unchanged'
  'quarantine-early' = 'AC4 quarantine cannot complete early'
  'ignore-marker' = 'AC4 changed-hash marker still blocks admission'
  'rename-completes' = 'AC4 recovery stop moved is not completion'
  'controller-bypass-fifo' = 'CONTROLLER AC1 B queues'
  'controller-command-link' = 'CONTROLLER AC2 changed command gets tail ticket'
}
function Get-FirstAssertion([string]$Text) {
  # Assertions write one raw "ASSERTION FAILED:" line to stderr before throwing;
  # the console error view (source echo, wrapping) is never parsed.
  foreach ($line in ($Text -split "\r?\n")) { if ($line -cmatch '^ASSERTION FAILED: (.*)$') { return $Matches[1].TrimEnd() } }
  return $null
}
if ($MutantMatrix) {
  $names = if ($MatrixMutants.Count) { @($MatrixMutants | ForEach-Object { $_ -split ',' } | Where-Object { $_ }) } else { @($expectedKills.Keys | ForEach-Object { [string]$_ }) }
  foreach ($name in $names) { if (-not $expectedKills.Contains($name)) { throw "SETUP: unknown matrix mutant $name" } }
  $self = $PSCommandPath; $timeout = $FixtureTimeoutSeconds; $revision = $GuardRevision
  $results = $names | ForEach-Object -ThrottleLimit $MatrixThrottle -Parallel {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $childArgs = @('-NoProfile','-NonInteractive','-File',$using:self,'-Mutant',$_,'-FixtureTimeoutSeconds',$using:timeout)
    if ($using:revision) { $childArgs += @('-GuardRevision',$using:revision) }
    # Raw stdout/stderr files: the PowerShell error stream would reformat the
    # child's one-line assertion record.
    $log = Join-Path ([IO.Path]::GetTempPath()) ('heavy-fifo-matrix-' + [guid]::NewGuid().ToString('N'))
    $child = Start-Process -FilePath (Get-Command pwsh).Source -ArgumentList $childArgs -RedirectStandardOutput "$log.out" -RedirectStandardError "$log.err" -NoNewWindow -PassThru
    $child.WaitForExit()
    # A grandchild can still hold the inherited redirect handle; read shared.
    $out = (@("$log.out", "$log.err") | ForEach-Object {
      $stream = [IO.File]::Open($_, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
      try { [IO.StreamReader]::new($stream).ReadToEnd() } finally { $stream.Dispose() }
    }) -join "`n"
    foreach ($file in @("$log.out", "$log.err")) {
      if ((Split-Path -Parent $file).TrimEnd('\','/') -ieq ([IO.Path]::GetTempPath()).TrimEnd('\','/') -and (Split-Path -Leaf $file) -cmatch '^heavy-fifo-matrix-[0-9a-f]{32}\.(out|err)$') {
        foreach ($try in 1..60) { try { Remove-Item -LiteralPath $file -ErrorAction Stop; break } catch { Start-Sleep -Milliseconds 500 } }
      }
    }
    [pscustomobject]@{ Name = $_; Exit = $child.ExitCode; Output = $out; Seconds = [int]$clock.Elapsed.TotalSeconds }
  }
  $survivors = 0
  foreach ($name in $names) {
    $r = @($results | Where-Object Name -ceq $name)[0]
    $first = Get-FirstAssertion $r.Output
    $want = $expectedKills[$name]
    # Setup failures, another case's assertion, or a passing child are survivors.
    $killed = $r.Exit -ne 0 -and $first -and ($first -ceq $want -or $first.StartsWith("$want ", [StringComparison]::Ordinal)) -and $r.Output -notmatch 'SETUP' -and $r.Output -notmatch '(?m)^PASS FIFO (mutant|authority guard) case'
    $died = if ($first) { $first.Substring(0, [Math]::Min(120, $first.Length)) } elseif ($r.Output -match '(SETUP[^\r\n]*)') { $Matches[1] } else { '<no assertion>' }
    Write-Output ("MUTANT {0} {1} exit={2} wall={3}s expected='{4}' died='{5}'" -f $name, $(if ($killed) { 'KILLED' } else { 'NOT-KILLED' }), $r.Exit, $r.Seconds, $want, $died)
    if (-not $killed) { $survivors++ }
  }
  if ($survivors) { Write-Output "FAIL FIFO mutant matrix survivors=$survivors wall=$([int]$suiteClock.Elapsed.TotalSeconds)s"; exit 1 }
  Write-Output "PASS FIFO mutant matrix mutants=$($names.Count) survivors=0 wall=$([int]$suiteClock.Elapsed.TotalSeconds)s"; exit 0
}
$source = if ($GuardRevision) {
  $text = @(& git -C $repo show "${GuardRevision}:.orchestrator/invoke-heavy-verifier.ps1")
  if ($LASTEXITCODE -ne 0) { throw "SETUP: cannot read guard revision $GuardRevision" }; $text -join "`n"
} else { [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'invoke-heavy-verifier.ps1')) }
# Only the executed guard copy changes. Expectations/cases are identical.
$mutations = @{
  'bypass-fifo' = @('if (-not $queueContext.IsHead) {', 'if ($false) {')
  'skip-absent-head' = @('IsHead = $position -eq 1;', 'IsHead = ($position -eq 1 -or -not (Test-Path -LiteralPath $lockPath));')
  'renumber-on-retry' = @('$ticket.presentedUtc = $now.ToString(''o''); $changed = $true', '$ticket.number = $queue.NextTicket; $queue.NextTicket++; $ticket.presentedUtc = $now.ToString(''o''); $changed = $true')
  'prune-live' = @("if (`$state -in @('live','ambiguous')) { return `$true }", "if (`$state -eq 'live') { return `$false }; if (`$state -eq 'ambiguous') { return `$true }")
  'never-expire' = @('if (($Now - $presented).TotalSeconds -gt $queueRetentionSeconds)', 'if ($false)')
  'reset-without-authority' = @('if (-not $isHostVerifier -or $isAttachedAdmission -or $callerBinding.Record -or $env:CHASE_SETS_HEAVY_SLOT_ID -or $env:CHASE_SETS_HEAVY_SLOT_TRANSPORT)', 'if ($false)')
  'quarantine-early' = @('if (((Get-QueueNow) - [DateTimeOffset]::Parse($marker.wrapperUtc)).TotalSeconds -le $queueRetentionSeconds)', 'if ($false)')
  'ignore-marker' = @('if (Test-PathEntry $queueRecoveryPath) { throw "heavy-verifier: verify queue recovery marker present ($queueRecoveryPath)" }', 'if ($false) { throw "heavy-verifier: verify queue recovery marker present ($queueRecoveryPath)" }')
  'rename-completes' = @("Stop-QueueRecoveryFixture 'moved'", '[IO.File]::Delete($queueRecoveryPath); $script:quarantineCompleted = $true; return')
  'controller-bypass-fifo' = @('if ($isQueueSlot) { # admission queue gate', 'if ($isProductSlot) { # admission queue gate')
  'controller-command-link' = @('(-not $isControllerSlot -or $_.commandIdentity -ceq $claimant.CommandIdentity)', '$true')
}
if ($Mutant) {
  $edit = $mutations[$Mutant]
  if ($source.Split([string[]]@($edit[0]), [StringSplitOptions]::None).Count -ne 2) { throw "SETUP: mutant anchor not unique: $Mutant" }
  $source = $source.Replace($edit[0], $edit[1])
}
function Assert-Fifo($Condition,[string]$Name,[string]$Detail='') { if (-not $Condition) { [Console]::Error.WriteLine(("ASSERTION FAILED: $Name $Detail" -split "\r?\n")[0]); throw "ASSERTION FAILED: $Name $Detail" } }
function Write-Json($Path,$Value) { [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 16 -Compress)) }
function Read-Json($Path) { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 16 -DateKind String }
function Hash-File($Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Wait-For([scriptblock]$Predicate,[string]$Name) {
  $deadline=[DateTime]::UtcNow.AddSeconds($FixtureTimeoutSeconds)
  while (-not (& $Predicate)) { if ([DateTime]::UtcNow -gt $deadline) { throw "SETUP/fixture timeout: $Name after $FixtureTimeoutSeconds s" }; Start-Sleep -Milliseconds 30 }
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('heavy-fifo-'+[guid]::NewGuid().ToString('N'))
$container=Join-Path $root 'container'; $runtime=Join-Path $container '.orchestrator'; $tree=Join-Path $container 'tree'
$drivers=[Collections.Generic.List[object]]::new(); $attempts=[Collections.Generic.List[object]]::new()
$pwsh=(Get-Command pwsh).Source; $node=(Get-Command node).Source
[void][IO.Directory]::CreateDirectory($runtime); [void][IO.Directory]::CreateDirectory($tree)
$guard=Join-Path $runtime 'invoke-heavy-verifier.ps1';[IO.File]::WriteAllText($guard,$source)
foreach($name in @('dispatch-ownership.ps1','heavy-nested-owner.cs','heavy-nested-client.cjs','heavy-admission-preload.cjs','heavy-slot.cjs','heavy-admission-holder-launcher.cjs')) { Copy-Item (Join-Path $PSScriptRoot $name) $runtime }
$runner=Join-Path $root 'runner.ps1'
[IO.File]::WriteAllText($runner, 'param($Guard,$InputPath); $p=Get-Content -LiteralPath $InputPath -Raw|ConvertFrom-Json -AsHashtable -DateKind String; & $Guard @p; exit $LASTEXITCODE')
$body=Join-Path $root 'body.cjs'
[IO.File]::WriteAllText($body,@'
const fs=require('fs'); const [marker,release,result]=process.argv.slice(2);
const timer=setInterval(()=>{
  if(result){if(!fs.existsSync(result))return;let r;try{r=JSON.parse(fs.readFileSync(result));}catch{return;}
    if(!r.accepted){process.exit(0);} }
  clearInterval(timer);fs.appendFileSync(marker,'body\n');
  if(!release)process.exit(0);
  const hold=setInterval(()=>{if(fs.existsSync(release)){clearInterval(hold);process.exit(0);}},20);
},20);
'@)
$driverFile=Join-Path $root 'driver.cjs'
[IO.File]::WriteAllText($driverFile,@'
const fs=require('fs'),cp=require('child_process'),path=require('path'),os=require('os'),crypto=require('crypto');
const [dir,pwsh,runner,guard,body]=process.argv.slice(2);let busy=false;
function publish(file,value){fs.writeFileSync(file+'.tmp',JSON.stringify(value));fs.renameSync(file+'.tmp',file);}
fs.writeFileSync(path.join(dir,'ready'),String(process.pid));
setInterval(()=>{if(busy)return;if(fs.existsSync(path.join(dir,'stop')))process.exit(0);
const req=path.join(dir,'request.json');if(!fs.existsSync(req))return;busy=true;
const spec=JSON.parse(fs.readFileSync(req));fs.unlinkSync(req);
try{const p=spec.parameters;
const env={...process.env};
for(const key of Object.keys(env))if(key==='NODE_OPTIONS'||key.startsWith('CHASE_SETS_HEAVY_ADMISSION_')||key==='CHASE_SETS_HEAVY_SLOT_ID'||key==='CHASE_SETS_HEAVY_SLOT_TRANSPORT'||key.toLowerCase()==='npm_config_script_shell')delete env[key];
Object.assign(env,spec.env||{});env.FIFO_BODY=spec.marker;env.FIFO_RELEASE=spec.release||'';
if(spec.shape==='Attach'){
 const ar=fs.mkdtempSync(path.join(os.tmpdir(),'chase-sets-heavy-admission-fifo-')),result=path.join(ar,'result.json');
 const child=cp.spawn(process.execPath,[body,spec.marker,spec.release||'',result],{windowsHide:true,stdio:'ignore',env});
 p.AdmissionKind='repository-gate';p.GuardedPid=child.pid;p.AdmissionNonce=crypto.randomBytes(16).toString('hex');p.AdmissionResultPath=result;p.AdmissionCommand=p.AdmissionCommand||'verify:static';
}else if(spec.shape==='ControllerBattery'){p.ControllerBattery=true;}
else if(!spec.production){p.Gate=p.Gate||'verify:static';p.CommandPath=process.execPath;p.CommandArgumentList=[body,spec.marker,spec.release||''];}
const input=spec.output+'.input';fs.writeFileSync(input,JSON.stringify(p));
const proc=cp.spawn(pwsh,['-NoProfile','-NonInteractive','-File',runner,guard,input],{windowsHide:true,env});
let output='';proc.stdout.on('data',b=>output+=b);proc.stderr.on('data',b=>output+=b);
proc.on('close',code=>{publish(spec.output,{code,output});busy=false;});
fs.writeFileSync(spec.output+'.started',String(proc.pid));
}catch(e){publish(spec.output,{code:-999,output:String(e)});busy=false;}
},20);
'@)
function New-Driver([string]$Name) {
  $dir=Join-Path $root ($Name+'-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($dir)
  $start=[Diagnostics.ProcessStartInfo]::new($node);$start.UseShellExecute=$false;$start.CreateNoWindow=$true
  foreach($arg in @($driverFile,$dir,$pwsh,$runner,$guard,$body)){[void]$start.ArgumentList.Add($arg)}
  $process=[Diagnostics.Process]::Start($start)
  $driver=[pscustomobject]@{Dir=$dir;Process=$process;Pid=$process.Id;Start=$process.StartTime.ToUniversalTime().ToString('o')}
  $drivers.Add($driver);Wait-For {Test-Path (Join-Path $dir 'ready')} 'driver startup';return $driver
}
function Start-Attempt($Driver,[string]$Shape='Gate',[hashtable]$Extra=@{},[switch]$Hold,[switch]$Production,[hashtable]$Environment=@{}) {
  $id=[guid]::NewGuid().ToString('N');$output=Join-Path $Driver.Dir "$id.result";$marker=Join-Path $root "$id.body";$release=if($Hold){Join-Path $root "$id.release"}else{''}
  $p=@{Worktree=$tree;Lane='fifo';Branch=$script:branch;ClaimedHead=$script:head;ContainerRoot=$container}
  if($Shape-ceq'ControllerBattery'){$p.ControllerBatteryClaimantPid=$Driver.Pid;$p.ControllerBatteryClaimantStartUtc=$Driver.Start}
  if($Production-and$Shape-eq'Gate'){$p.Gate='verify:static'};foreach($key in $Extra.Keys){$p[$key]=$Extra[$key]}
  $attempt=[pscustomobject]@{Output=$output;Marker=$marker;Release=$release;Driver=$Driver};$attempts.Add($attempt)
  Write-Json (Join-Path $Driver.Dir 'next.json') @{parameters=$p;shape=$Shape;marker=$marker;release=$release;output=$output;production=[bool]$Production;env=$Environment}
  [IO.File]::Move((Join-Path $Driver.Dir 'next.json'),(Join-Path $Driver.Dir 'request.json'))
  Wait-For {Test-Path ($output+'.started')} 'attempt started';return $attempt
}
function Complete-Attempt($Attempt) {
  Wait-For {Test-Path $Attempt.Output} 'attempt completion';$r=Read-Json $Attempt.Output
  return [pscustomobject]@{Code=$r.code;Output=$r.output;Body=(Test-Path $Attempt.Marker);Attempt=$Attempt}
}
function Invoke-Attempt($Driver,[string]$Shape='Gate',[hashtable]$Extra=@{},[switch]$Production,[hashtable]$Environment=@{}) { Complete-Attempt (Start-Attempt $Driver $Shape $Extra -Production:$Production -Environment $Environment) }
function Release-Attempt($Attempt) { [IO.File]::WriteAllText($Attempt.Release,'release');Complete-Attempt $Attempt }
$queue=Join-Path $runtime 'verify-queue.json';$recovery=Join-Path $runtime 'verify-queue.recovery';$lock=Join-Path $runtime 'verify-lock.d';$owner=Join-Path $lock 'owner.json';$fixture=Join-Path $container 'fixture.json'
$controllerQueue=Join-Path $runtime 'controller-verify-queue.json';$controllerLock=Join-Path $runtime 'controller-verify-lock.d';$controllerOwner=Join-Path $controllerLock 'owner.json'
function Set-Fixture($Value) { Write-Json $fixture $Value;return @{TestQueueFixture=$fixture} }
function Clear-Queue { foreach($p in @($queue,$recovery)){if(Test-Path -LiteralPath $p){Remove-Item -LiteralPath $p -Force}} }
function Clear-ControllerQueue { foreach($p in @($controllerQueue)){if(Test-Path -LiteralPath $p){Remove-Item -LiteralPath $p -Force}} }
function Assert-Refused($Result,[string]$Name,[string]$Pattern='') {
  Assert-Fifo ($Result.Code -eq 73 -and -not $Result.Body -and (-not $Pattern -or $Result.Output -match $Pattern)) $Name "exit=$($Result.Code) body=$($Result.Body) output=$($Result.Output)"
  Assert-RecoveryOwners
}
function Assert-RecoveryOwners {
  if($script:recoveryOwnerHash){Assert-Fifo ((Hash-File $owner)-ceq$script:recoveryOwnerHash-and(Hash-File $script:controllerOwner)-ceq$script:controllerOwnerHash) 'AC4 recovery leaves both owners byte-identical'}
}
function Assert-LockBlocked($Result,[string]$Name) {
  Assert-Fifo ($Result.Code -ne 0 -and -not $Result.Body -and $Result.Output -match 'lock unavailable \(') $Name "exit=$($Result.Code) $($Result.Output)"
}
if($Mutant){
  $Part = switch($Mutant){
    {$_ -in @('bypass-fifo','skip-absent-head','renumber-on-retry','controller-bypass-fifo','controller-command-link')} {'order';break}
    {$_ -in @('prune-live','never-expire')} {'lifecycle';break}
    'reset-without-authority' {'authority';break}
    default {'recovery';break}
  }
}
  function Test-ControllerOrder {
    Clear-ControllerQueue
    $control=Invoke-Attempt $a ControllerBattery
    Assert-Fifo ($control.Code -eq 0 -and $control.Body) 'CONTROLLER AC1 no-waiter control' $control.Output
    $barrier=Start-Attempt $o ControllerBattery -Hold;Wait-For {Test-Path $barrier.Marker} 'controller barrier owner'
    Assert-ControllerBlocked (Invoke-Attempt $a ControllerBattery) 'CONTROLLER AC1 A waits for owner'
    Assert-ControllerRefused (Invoke-Attempt $b ControllerBattery) 'CONTROLLER AC1 B queues' 'queued;.*position=2'
    Assert-ControllerRefused (Invoke-Attempt $c ControllerBattery) 'CONTROLLER AC1 C queues' 'queued;.*position=3'
    $before=Read-Json $controllerQueue;$retry=Invoke-Attempt $a ControllerBattery;$after=Read-Json $controllerQueue
    Assert-Fifo (($before.tickets.number -join ',') -ceq ($after.tickets.number -join ',') -and ($before.tickets.claimantKey -join ',') -ceq ($after.tickets.claimantKey -join ',')) 'CONTROLLER AC1 retry keeps number and order' $retry.Output
    $null=Release-Attempt $barrier
    Assert-ControllerRefused (Invoke-Attempt $b ControllerBattery) 'CONTROLLER AC1 B remains behind A' 'queued;.*position=2.*reserved=True'
    Assert-ControllerRefused (Invoke-Attempt $c ControllerBattery) 'CONTROLLER AC1 C remains behind A' 'queued;.*position=3.*reserved=True'
    Assert-ControllerRefused (Invoke-Attempt $o ControllerBattery) 'CONTROLLER AC2 releasing owner reclaims behind existing waiters' 'queued;.*position=4.*reserved=True'
    $admitted=Invoke-Attempt $a ControllerBattery
    Assert-Fifo ($admitted.Code -eq 0 -and $admitted.Body) 'CONTROLLER AC1 earliest admits' $admitted.Output
    Assert-Fifo (@((Read-Json $controllerQueue).tickets|Where-Object claimantKey -like "*parent:$($a.Pid)*").Count -eq 0) 'CONTROLLER AC1 admitted ticket removed' $admitted.Output
    Write-Output "PASS CONTROLLER AC1 FIFO battery claimant and separate queue state mutant=$Mutant"

    Clear-ControllerQueue;$barrier=Start-Attempt $o ControllerBattery -Hold;Wait-For {Test-Path $barrier.Marker} 'controller command-link barrier'
    Assert-ControllerBlocked (Invoke-Attempt $a ControllerBattery) 'CONTROLLER AC2 first claimant holds the head'
    Assert-ControllerRefused (Invoke-Attempt $b ControllerBattery) 'CONTROLLER AC2 first command ticket' 'position=2'
    Assert-ControllerRefused (Invoke-Attempt $b ControllerBattery @{ControllerBatteryOnFailure='all'}) 'CONTROLLER AC2 changed command gets tail ticket' 'position=3'
    $tickets=@((Read-Json $controllerQueue).tickets)
    Assert-Fifo ($tickets.Count -eq 3 -and $tickets[1].commandIdentity -cne $tickets[2].commandIdentity) 'CONTROLLER AC2 command linkage is not priority inheritance'
    $null=Release-Attempt $barrier
    Assert-Fifo ((Invoke-Attempt $a ControllerBattery).Code -eq 0) 'CONTROLLER AC2 earliest claimant admits before linked command'
    Assert-Fifo ((Invoke-Attempt $b ControllerBattery).Code -eq 0) 'CONTROLLER AC2 first command admits before linked command'
    Assert-Fifo ((Invoke-Attempt $b ControllerBattery @{ControllerBatteryOnFailure='all'}).Code -eq 0) 'CONTROLLER AC2 linked command admits at its own turn'
    $prior=Join-Path $root 'prior-result.json';$foreign=Join-Path $root 'foreign-result.json';[IO.File]::WriteAllText($prior,'prior');[IO.File]::WriteAllText($foreign,'foreign')
    Clear-ControllerQueue;$barrier=Start-Attempt $o ControllerBattery -Hold;Wait-For {Test-Path $barrier.Marker} 'controller prior-result barrier'
    $sameA=Invoke-Attempt $b ControllerBattery @{ControllerBatteryPriorResultPath=$prior};$foreignB=Invoke-Attempt $b ControllerBattery @{ControllerBatteryPriorResultPath=$foreign}
    $tickets=@((Read-Json $controllerQueue).tickets)
    Assert-Fifo ($tickets.Count-eq2-and$tickets[0].claimantKey-ceq$tickets[1].claimantKey-and$tickets[0].commandIdentity-cne$tickets[1].commandIdentity) 'CONTROLLER AC2 prior evidence links same lane while foreign result gets distinct command' ($tickets|ConvertTo-Json -Compress)
    $null=Release-Attempt $barrier;$priorAdmitted=Invoke-Attempt $b ControllerBattery @{ControllerBatteryPriorResultPath=$prior}
    Assert-Fifo ($priorAdmitted.Code-eq0-and$priorAdmitted.Body) 'CONTROLLER AC2 same-lane prior result retry admits with body' $priorAdmitted.Output
    $rejected=Invoke-Attempt $b ControllerBattery @{ControllerBatteryPriorResultPath=$foreign}
    Assert-Fifo ($rejected.Code-eq91-and-not$rejected.Body-and$rejected.Output-match'foreign prior result') 'CONTROLLER AC2 foreign prior result is rejected without body' $rejected.Output
    Write-Output 'PASS CONTROLLER AC2 per-command linkage and separate controller queue'
  }
  function Assert-ControllerRefused($Result,[string]$Name,[string]$Pattern='') {
    Assert-Fifo ($Result.Code -eq 73 -and -not $Result.Body -and (-not $Pattern -or $Result.Output -match $Pattern)) $Name "exit=$($Result.Code) body=$($Result.Body) output=$($Result.Output)"
  }
  function Assert-ControllerBlocked($Result,[string]$Name) {
    Assert-Fifo ($Result.Code -eq 73 -and -not $Result.Body -and $Result.Output -match 'lock unavailable \(') $Name "exit=$($Result.Code) output=$($Result.Output)"
  }
function Write-Seed($Tickets,[long]$Next=1000) {
  $doc=if(Test-Path $queue){Read-Json $queue}else{[pscustomobject]@{schemaVersion=1;fileIdentity='fixture-not-initialized';nextTicket=1;tickets=@()}}
  $doc.tickets=@($Tickets);$doc.nextTicket=$Next;Write-Json $queue $doc
}
function New-Ticket([long]$Number,[int]$Id,[string]$Start,[string]$Presented,[string]$Key="fixture:$Id") { [pscustomobject]@{number=$Number;claimantKey=$Key;pid=$Id;startIdentity=$Start;childPid=$null;childStartIdentity=$null;presentedUtc=$Presented} }
function New-DispatchFixture($Driver,[string]$Label) {
  $launch=[guid]::NewGuid().ToString();$path=Join-Path $runtime "dispatch-launch-$launch.json"
  $record=@{
    schemaVersion=4;launchId=$launch;laneRole='implementation'
    promptPath=(Join-Path $runtime "dispatch-heavy-verifier-$launch.prompt.txt");reviewIsolationRoot=$null
    launcherPid=$PID;launcherStartIdentity=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
    recordedAt=([DateTimeOffset]::Parse($Driver.Start).AddMilliseconds(-1).UtcDateTime.ToString('o'))
    state='started';childPid=$Driver.Pid;childStartIdentity=$Driver.Start
    worktree=$tree;lane='tree';identityMode='branch';branch=$branch;head=$head
    label=$Label;transcriptPath=(Join-Path $runtime "$Label.jsonl")
  }
  Write-Json $path $record;[IO.File]::WriteAllText($record.promptPath,'inert');[IO.File]::WriteAllText($record.transcriptPath,"{`"type`":`"item.completed`"}`n")
  Write-Json (Join-Path $runtime 'dispatch-log.jsonl') @{ts=$record.recordedAt;kind='dispatch';dispatchRoutingSchema='watchdog-dispatch-routing/v1';attemptId=$Label;label=$Label;lane='tree';laneRole='implementation';transcript="$Label.jsonl";harness='codex';model='gpt-6-astra';effort='high';row='7';placement='override-Todd';worktree=$tree;branch=$branch;head=$head}
  return [pscustomobject]@{Path=$path;Record=$record}
}
try {
  & git -C $tree init --quiet
  [IO.File]::WriteAllText((Join-Path $tree '.gitignore'),".orchestrator/artifacts/`nnode_modules/`n")
  [IO.File]::WriteAllText((Join-Path $tree 'package.json'),'{"name":"inert-heavy-fifo","private":true,"scripts":{"verify:static":"node gate.cjs"}}')
  [void][IO.Directory]::CreateDirectory((Join-Path $tree 'scripts'))
  [IO.File]::WriteAllText((Join-Path $tree 'scripts/vitest.mjs'), 'import fs from "node:fs"; fs.appendFileSync(process.env.FIFO_CHILD,"nested\n");')
  [IO.File]::WriteAllText((Join-Path $tree 'gate.cjs'), @'
const fs=require('fs'),path=require('path'),cp=require('child_process');
if(process.env.FIFO_NESTED==='1'){
  const queue=process.env.FIFO_QUEUE,owner=path.join(path.dirname(queue),'verify-lock.d/owner.json');
  const original=fs.readFileSync(queue),before=fs.readFileSync(owner);fs.writeFileSync(queue,'{invalid nested fixture');
  const run=(name,env)=>cp.spawnSync(process.execPath,['scripts/vitest.mjs','run'],{env:{...process.env,FIFO_CHILD:process.env.FIFO_BODY+'.'+name,...env},encoding:'utf8',windowsHide:true});
  const good=run('nested',{}),copied=run('copied',{CHASE_SETS_HEAVY_SLOT_ID:'a'.repeat(32),CHASE_SETS_HEAVY_SLOT_TRANSPORT:''});
  if(good.status!==0||copied.status!==73||!fs.existsSync(process.env.FIFO_BODY+'.nested')||fs.existsSync(process.env.FIFO_BODY+'.copied')||
    !fs.readFileSync(owner).equals(before)||fs.readFileSync(queue,'utf8')!=='{invalid nested fixture')throw Error('nested isolation: '+good.status+' '+good.stderr+' copied='+copied.status+' '+copied.stderr);
  fs.writeFileSync(queue,original);
}
fs.appendFileSync(process.env.FIFO_BODY,'body\n');
'@)
  & pnpm.cmd --dir $tree install --lockfile-only --ignore-scripts --offline *> (Join-Path $root 'pnpm-setup.log')
  if($LASTEXITCODE -ne 0){throw 'SETUP: fixture pnpm lock generation'}
  [void][IO.Directory]::CreateDirectory((Join-Path $tree '.orchestrator'))
  [IO.File]::WriteAllText((Join-Path $tree '.orchestrator/controller-release-battery.ps1'),'param([string]$PriorResultPath); if($PriorResultPath -and [IO.Path]::GetFileName($PriorResultPath)-ceq''foreign-result.json''){Write-Error ''foreign prior result'';exit 91}; [IO.File]::AppendAllText($env:FIFO_BODY,"body`n"); while($env:FIFO_RELEASE -and -not (Test-Path -LiteralPath $env:FIFO_RELEASE)){ Start-Sleep -Milliseconds 20 }')
  [IO.File]::WriteAllText((Join-Path $tree '.orchestrator/fail-closed-guard-evidence.test.ps1'),'param($Scenario,$ExpectedControllerHead,$SuiteResultOut); [IO.File]::WriteAllText((Join-Path (Get-Location) $SuiteResultOut),''{}''); [IO.File]::AppendAllText($env:FIFO_BODY,"body`n")')
  & git -C $tree add .gitignore package.json pnpm-lock.yaml gate.cjs scripts .orchestrator
  & git -C $tree -c user.name=Fixture -c user.email=fixture@example.invalid commit --quiet -m 'inert FIFO fixture'
  if($LASTEXITCODE -ne 0){throw 'SETUP: fixture commit'}
  $script:head=(& git -C $tree rev-parse HEAD).Trim();$script:branch=(& git -C $tree branch --show-current).Trim()
  $a=New-Driver A;$b=New-Driver B;$c=New-Driver C;$o=New-Driver owner
  $now=[DateTimeOffset]::UtcNow;$start=$now.AddHours(-1).ToString('o')
  function Test-MutantOrder {
    foreach($shape in @('Gate','Attach')) {
      Clear-Queue;$control=Invoke-Attempt $a $shape
      Assert-Fifo ($control.Code -eq 0 -and $control.Body) "MUTANT $Mutant AC1 $shape control" $control.Output
      $barrier=Start-Attempt $o $shape -Hold;Wait-For {Test-Path $barrier.Marker} "MUTANT $Mutant $shape barrier"
      Assert-LockBlocked (Invoke-Attempt $a $shape) "MUTANT $Mutant AC1 $shape A waits for owner"
      Assert-Refused (Invoke-Attempt $b $shape) "MUTANT $Mutant AC1 $shape B first refusal" 'queued;.*ticket=\d+.*position=2'
      Assert-Refused (Invoke-Attempt $c $shape) "MUTANT $Mutant AC1 $shape C first refusal" 'queued;.*position=3'
      $before=Read-Json $queue;$retry=Invoke-Attempt $a $shape;$after=Read-Json $queue
      Assert-Fifo (($before.tickets.number -join ',') -ceq ($after.tickets.number -join ',') -and ($before.tickets.claimantKey -join ',') -ceq ($after.tickets.claimantKey -join ',')) "MUTANT $Mutant AC1 retry keeps number and order" $retry.Output
      $null=Release-Attempt $barrier
      foreach($pair in @(@($b,2),@($c,3))) {
        Assert-Refused (Invoke-Attempt $pair[0] $shape) "MUTANT $Mutant AC1 $shape absent-head refusal position=$($pair[1])" "queued;.*ticket=\d+.*position=$($pair[1]).*reserved=True"
      }
      $admitted=Invoke-Attempt $a $shape
      Assert-Fifo ($admitted.Code -eq 0 -and $admitted.Body) "MUTANT $Mutant AC1 $shape A admits after release" $admitted.Output
      Write-Output "PASS MUTANT $Mutant AC1 $shape named guard case"
    }
  }
  function Test-MutantLifecycle {
    $rows=@();$tickets=@();$probes=@();$number=0
    foreach($state in @('dead','reused','live','ambiguous')){foreach($desc in @($false,$null)){foreach($age in @(599,601)){
      $number++;$probeId=2100000000+$number
      $tickets+=New-Ticket $number $probeId $start ($now.AddSeconds(-$age).ToString('o'))
      $probes+=@{pid=$probeId;startIdentity=$start;state=$state;descendant=$desc}
      $rows+=@{number=$number;state=$state;desc=$desc;age=$age;keep=($age -le 600 -and ($state -in @('live','ambiguous') -or $null -eq $desc))}
    }}}
    Clear-Queue;$control=Invoke-Attempt $a Gate
    Assert-Fifo ($control.Code -eq 0 -and $control.Body) "MUTANT $Mutant AC3 lifecycle control" $control.Output
    Write-Seed $tickets
    $r=Invoke-Attempt $b Gate (Set-Fixture @{now=$now.ToString('o');probes=$probes})
    $retained=@((Read-Json $queue).tickets.number)
    foreach($row in $rows){
      $observed=$retained -contains $row.number
      $name="MUTANT $Mutant AC3 lifecycle $($row.state) descendant=$(if($null -eq $row.desc){'unknown'}else{'false'}) age=$($row.age)"
      Assert-Fifo ($observed -eq $row.keep) $name "retained=$observed expected=$($row.keep) exit=$($r.Code) $($r.Output)"
    }
    Write-Output "PASS MUTANT $Mutant AC3 lifecycle named guard case"
  }
  if($Part -eq 'controller'){Test-ControllerOrder;Write-Output "PASS FIFO controller case=$Mutant wall=$([int]$suiteClock.Elapsed.TotalSeconds)s";return}
  if($Part -eq 'order'){
    if($Mutant -in @('controller-bypass-fifo','controller-command-link')) { Test-ControllerOrder }
    else { Test-MutantOrder }
    Write-Output "PASS FIFO mutant case=$Mutant";return
  }
  if($Part -eq 'lifecycle'){Test-MutantLifecycle;Write-Output "PASS FIFO mutant case=$Mutant";return}
  if($Part-eq'all') {
  Test-ControllerOrder
  $control=Invoke-Attempt $a Gate
  Assert-Fifo ($control.Code-eq0-and$control.Body) 'AC2 initial no-waiter control' $control.Output
  Write-Output 'PASS AC2 initial no-waiter control'
  $now=[DateTimeOffset]::UtcNow;$start=$now.AddHours(-1).ToString('o')
  function Test-LifecycleMatrix {
  $rows=@();$tickets=@();$probes=@();$number=0
  foreach($state in @('dead','reused','live','ambiguous')){foreach($desc in @($false,$null)){foreach($age in @(599,601)){
    $number++;$probeId=2000000000+$number
    $tickets+=New-Ticket $number $probeId $start ($now.AddSeconds(-$age).ToString('o'))
    $probes+=@{pid=$probeId;startIdentity=$start;state=$state;descendant=$desc}
    $rows+=@{number=$number;state=$state;desc=$desc;age=$age;keep=($age-le600-and($state-in@('live','ambiguous')-or$null-eq$desc))}
  }}}
  Write-Seed $tickets
  $r=Invoke-Attempt $b Gate (Set-Fixture @{now=$now.ToString('o');probes=$probes})
  $retained=@((Read-Json $queue).tickets.number)
  foreach($row in $rows){
    $observed=$retained-contains$row.number
    $name="AC3 lifecycle $($row.state) descendant=$(if($null-eq$row.desc){'unknown'}else{'false'}) age=$($row.age)"
    Assert-Fifo ($observed-eq$row.keep) $name "retained=$observed expected=$($row.keep) exit=$($r.Code) $($r.Output)"
    Write-Output "PASS $name retained=$observed"
  }
  Assert-Refused $r 'AC3 retained matrix heads reserve free slot' 'reserved=True'
  }
  # Historical guards lack the queue-only probe seam. Prove their FIFO failure
  # with unmodified Gate/Attach inputs before attempting the lifecycle matrix.
  if(-not$GuardRevision){Test-LifecycleMatrix}
  foreach($shape in @('Gate','Attach')) {
    Clear-Queue;$control=Invoke-Attempt $a $shape
    Assert-Fifo ($control.Code -eq 0 -and $control.Body) "AC2 $shape no-waiter control" $control.Output
    Write-Output "PASS AC2 $shape no-waiter control"
    $barrier=Start-Attempt $o $shape -Hold;Wait-For {Test-Path $barrier.Marker} "$shape barrier owner"
    $ownerHash=Hash-File $owner;$ownerEntries=(@(Get-ChildItem $lock -Force|ForEach-Object Name)-join ',')
    Assert-LockBlocked (Invoke-Attempt $a $shape) "AC1 $shape A waits for owner"
    Assert-Refused (Invoke-Attempt $b $shape) "AC1 $shape B FIFO refusal" 'queued;.*ticket=\d+.*position=2'
    Assert-Refused (Invoke-Attempt $c $shape) "AC1 $shape C FIFO refusal" 'queued;.*position=3'
    Assert-Fifo ((Hash-File $owner)-ceq$ownerHash -and (@(Get-ChildItem $lock -Force|ForEach-Object Name)-join ',')-ceq$ownerEntries) "AC1 $shape byte-exact owner and lock"
    $before=Read-Json $queue;$retry=Invoke-Attempt $a $shape;$after=Read-Json $queue
    Assert-Fifo (($before.tickets.number -join ',')-ceq($after.tickets.number -join ',') -and ($before.tickets.claimantKey -join ',')-ceq($after.tickets.claimantKey -join ',')) 'AC1 retry keeps number and order' $retry.Output
    $before.tickets[0].presentedUtc=$after.tickets[0].presentedUtc
    Assert-Fifo ($before.nextTicket-eq$after.nextTicket-and($before.tickets|ConvertTo-Json -Compress -Depth 8)-ceq($after.tickets|ConvertTo-Json -Compress -Depth 8)) "AC1 $shape retry changes only own presentation"
    Assert-LockBlocked $retry "AC1 $shape retry retained"
    $released=Release-Attempt $barrier;Assert-Fifo ($released.Code-eq0) "AC1 $shape barrier releases" $released.Output
    [IO.File]::WriteAllText((Join-Path $tree "$shape-reclaimer-head.txt"),'inert reclaimer head change')
    & git -C $tree add "$shape-reclaimer-head.txt"
    & git -C $tree -c user.name=Fixture -c user.email=fixture@example.invalid commit --quiet -m 'inert reclaimer head change'
    $script:head=(& git -C $tree rev-parse HEAD).Trim()
    foreach($pair in @(@($b,2),@($c,3))) {
      Assert-Refused (Invoke-Attempt $pair[0] $shape) "AC1 reserved absent head $shape position=$($pair[1])" "queued;.*ticket=\d+.*position=$($pair[1]).*reserved=True"
      Assert-Fifo (-not(Test-Path $lock)) "AC1 $shape reservation leaves lock absent"
    }
    $extra=if($shape-eq'Gate'){@{Gate='build'}}else{@{AdmissionCommand='build'}}
    Assert-Refused (Invoke-Attempt $o $shape $extra) "AC2 $shape immediate reclaimer queues behind waiters" 'queued;.*position=4.*reserved=True'
    $admitted=Invoke-Attempt $a $shape
    Assert-Fifo ($admitted.Code-eq0 -and $admitted.Body -and @(Get-Content $admitted.Attempt.Marker).Count-eq1) "AC1 $shape earliest admits exactly one inert marker" $admitted.Output
    Assert-Fifo (-not(Test-Path $lock) -and @((Read-Json $queue).tickets|Where-Object pid -eq $a.Pid).Count-eq0) "AC1 $shape admitted ticket removed before release"
    Write-Output "PASS AC1/AC2 $shape ordered A/B/C, retry, absent-head reservation, byte-exact owner, immediate reclaimer, one body"
  }
  if($GuardRevision){Test-LifecycleMatrix}
  Clear-Queue;$barrier=Start-Attempt $o Attach -Hold;Wait-For {Test-Path $barrier.Marker} 'r17 barrier'
  $r17=New-DispatchFixture $a 'fifo-r17'
  Assert-LockBlocked (Invoke-Attempt $a Attach) 'AC1 r17 containing verifier waits'
  $ticket=(Read-Json $queue).tickets[0]
  Assert-Fifo ($ticket.claimantKey-ceq"launch:$($r17.Record.launchId)") 'AC1 r17 ticket belongs to containing launch, not guarded root'
  Assert-LockBlocked (Invoke-Attempt $a Attach) 'AC1 r17 new guarded root retains launch ticket'
  Assert-Fifo ((Read-Json $queue).tickets[0].number-eq$ticket.number) 'AC1 r17 guarded root exit does not drop or renumber launch ticket'
  $null=Invoke-Attempt $b Gate;$null=Release-Attempt $barrier
  1..3|ForEach-Object {Assert-Refused (Invoke-Attempt $b Attach) 'AC1 r17 repeated Attach reservation' 'reserved=True'}
  $r=Invoke-Attempt $a Attach;Assert-Fifo ($r.Code-eq0-and$r.Body) 'AC1 r17 waiting verifier admits' $r.Output
  Remove-Item -LiteralPath $r17.Path
  Write-Output 'PASS AC1 r17 containing-launch Attach retries retain ticket across guarded-root exits and cannot be overtaken'
  # Queue-only probes never replace real caller/owner eligibility probes.
  $now=[DateTimeOffset]::UtcNow
  Write-Seed @((New-Ticket 1 2000000001 $start $now.ToString('o')),(New-Ticket 2 $a.Pid $a.Start $now.ToString('o') "parent:$($a.Pid):$($a.Start)"))
  $settings=Set-Fixture @{now=$now.ToString('o');probes=@(@{pid=2000000001;startIdentity=$start;state='dead';descendant=$false})}
  Assert-Refused (Invoke-Attempt $b Gate $settings) 'AC1 refuse after prune' 'position=2.*reserved=True'
  Assert-Fifo (@((Read-Json $queue).tickets|Where-Object number -eq 1).Count-eq0) 'AC1 prune persisted while refusing'
  Write-Output 'PASS AC1 refuse-after-prune keeps retained absent head'
  # Head changes do not change claimant identity; eligibility still rechecks Git.
  $barrier=$null;Clear-Queue;$barrier=Start-Attempt $o Gate -Hold;Wait-For {Test-Path $barrier.Marker} 'head-change barrier'
  $null=Invoke-Attempt $a Gate;$ticket=(Read-Json $queue).tickets[0]
  [IO.File]::WriteAllText((Join-Path $tree 'new-head.txt'),'inert head change')
  & git -C $tree add new-head.txt
  & git -C $tree -c user.name=Fixture -c user.email=fixture@example.invalid commit --quiet -m 'inert head change'
  $oldHead=$head;$script:head=(& git -C $tree rev-parse HEAD).Trim()
  $r=Invoke-Attempt $a Gate @{Gate='build'};Assert-LockBlocked $r 'AC3 same parent changed command/head still waits'
  $next=(Read-Json $queue).tickets[0]
  Assert-Fifo ($next.number-eq$ticket.number-and$next.claimantKey-ceq$ticket.claimantKey) 'AC3 head-change retention'
  $null=Release-Attempt $barrier
  $new=New-Driver newParent
  Assert-Refused (Invoke-Attempt $new Gate) 'AC3 new standalone parent queues at tail' 'position=2'
  $r=Invoke-Attempt $a Gate;Assert-Fifo ($r.Code-eq0-and$r.Body) 'AC3 same parent retains head after attempts exit' $r.Output
  Write-Output 'PASS AC3 command/head change, attempt exit, same/new standalone parent'
  $oldStart=[DateTimeOffset]::Parse($b.Start).AddSeconds(-1).ToString('o')
  Write-Seed @((New-Ticket 1 $b.Pid $oldStart $now.ToString('o') "parent:$($b.Pid):$oldStart"))
  $r=Invoke-Attempt $b Gate (Set-Fixture @{now=$now.ToString('o');probes=@(@{pid=$b.Pid;startIdentity=$oldStart;state='reused';descendant=$null})})
  Assert-Refused $r 'AC3 reused PID never inherits retained ticket' 'position=2'
  Assert-Fifo (@((Read-Json $queue).tickets).Count-eq2) 'AC3 reused identity and new claimant remain distinct'
  Write-Output 'PASS AC3 reused PID does not inherit a ticket with unknown descendants'
  Write-Seed @((New-Ticket 1 $b.Pid $b.Start $now.AddSeconds(-601).ToString('o') "parent:$($b.Pid):$($b.Start)"),(New-Ticket 2 $a.Pid $a.Start $now.ToString('o') "parent:$($a.Pid):$($a.Start)"))
  Assert-Refused (Invoke-Attempt $b Gate (Set-Fixture @{now=$now.ToString('o')})) 'AC3 expired claimant re-enqueues behind retained waiter' 'position=2.*reserved=True'
  $tickets=@((Read-Json $queue).tickets)
  Assert-Fifo (@($tickets|Where-Object number -eq 1).Count-eq0-and@($tickets|Where-Object {$_.pid-eq$b.Pid-and$_.number-eq1000}).Count-eq1) 'AC3 expired retry receives a fresh tail number'
  Write-Output 'PASS AC3 expired claimant retry re-enqueues at tail without inheriting old number'
  foreach($kind in @('corrupt','duplicate','duplicate-ticket','replaced','over-bytes','over-tickets','unsafe')) {
    Clear-Queue;$null=Invoke-Attempt $a Gate
    switch($kind){
      corrupt {[IO.File]::WriteAllText($queue,'{broken')}
      duplicate {$raw=[IO.File]::ReadAllText($queue);[IO.File]::WriteAllText($queue,$raw.Replace('"schemaVersion":1','"schemaVersion":1,"schemaVersion":1'))}
      duplicate-ticket {$t=New-Ticket 1 $a.Pid $a.Start $now.ToString('o');Write-Seed @($t,$t)}
      replaced {$copy="$queue.copy";[IO.File]::Copy($queue,$copy);[IO.File]::Move($copy,$queue,$true)}
      over-bytes {[IO.File]::WriteAllText($queue,('x'*(256*1024+1)))}
      over-tickets {Write-Seed @(1..129|ForEach-Object {New-Ticket $_ (100000+$_) $start $now.ToString('o')})}
      unsafe {$target="$queue.target";[IO.File]::Move($queue,$target);New-Item -ItemType SymbolicLink -Path $queue -Target $target|Out-Null}
    }
    $hash=Hash-File $queue
    1..2|ForEach-Object {
      $r=Invoke-Attempt $b Gate
      Assert-Refused $r "AC4 $kind repeated invalid queue" 'path=.*size=.*sha256=.*reason='
      Assert-Fifo ($r.Output.Contains("path=$queue")) "AC4 $kind diagnostic names exact path"
      if($kind-ne'unsafe'){Assert-Fifo ($r.Output.Contains("size=$((Get-Item $queue).Length)")-and$r.Output.Contains("sha256=$hash")) "AC4 $kind diagnostic names measured size/hash"}
      Assert-Fifo ((Hash-File $queue)-ceq$hash) "AC4 $kind byte-exact refusal"
      Assert-Fifo (-not(Test-Path $lock)) "AC4 $kind leaves absent owner/lock unchanged"
    }
    Write-Output "PASS AC4 $kind repeated refusal preserves bytes, no ticket/body"
  }
  Clear-Queue;$r=Invoke-Attempt $a Gate (Set-Fixture @{failRemoval=$true})
  Assert-Refused $r 'AC4 admission persistence failure releases owner' 'unable to persist queue admission'
  Assert-Fifo (-not(Test-Path $lock)) 'AC4 failed removal releases owner without body'
  Write-Output 'PASS AC4 failed admission persistence releases owner without body'
  Write-Seed @(1..128|ForEach-Object {New-Ticket $_ $a.Pid $a.Start ([DateTimeOffset]::UtcNow.ToString('o')) "capacity:$_"})
  $hash=Hash-File $queue
  Assert-Refused (Invoke-Attempt $b Gate) 'AC3/AC4 128 retained ticket cap grants no ticket' 'path=.*size=.*sha256=.*reason=over-capacity'
  Assert-Fifo ((Hash-File $queue)-ceq$hash) 'AC3/AC4 full queue is unchanged'
  Write-Output 'PASS AC3/AC4 exactly 128 retained tickets refuses a 129th without mutation'
  }
  if($Part-in@('all','isolation')) {
  Clear-Queue;$r=Invoke-Attempt $a Gate @{} -Production -Environment @{FIFO_NESTED='1';FIFO_QUEUE=$queue}
  Assert-Fifo ($r.Code-eq0-and$r.Body-and(Test-Path ($r.Attempt.Marker+'.nested'))-and-not(Test-Path ($r.Attempt.Marker+'.copied'))) 'AC4 nested owner and inherited token never touch queue' $r.Output
  Write-Output 'PASS AC4 real nested continuation admits under owner; copied token refuses; invalid queue and owner byte-exact'
  Clear-Queue;[IO.File]::WriteAllText($queue,'{invalid isolation fixture');$hash=Hash-File $queue
  $r=Invoke-Attempt $b ControllerBattery
  Assert-Fifo ($r.Code-eq0-and$r.Body-and(Hash-File $queue)-ceq$hash) 'AC4 ControllerBattery never reads/writes product queue' $r.Output
  $r=Invoke-Attempt $b ControllerPrecursor @{ControllerPrecursor='fail-closed-guard-evidence';ControllerPrecursorScenario='ReceiptClaims';ControllerPrecursorArtifactPath='.orchestrator/artifacts/fifo.json'} -Production
  Assert-Fifo ($r.Code-eq0-and$r.Body-and(Hash-File $queue)-ceq$hash) 'AC4 ControllerPrecursor never reads/writes product queue' $r.Output
  Remove-Item -LiteralPath (Join-Path $tree '.orchestrator/artifacts/fifo.json')
  Write-Output 'PASS AC4 controller battery/precursor ignore invalid product queue'
  }
  if($Part-eq'isolation'){Write-Output 'PASS FIFO isolation behavioral cases';return}
  # Recovery calls resolve the production Gate, with no arbitrary command.
  Clear-Queue;$recoveryBarrier=Start-Attempt $o Gate -Hold;Wait-For {Test-Path $recoveryBarrier.Marker} 'recovery owner barrier'
  $script:recoveryOwnerHash=Hash-File $owner
  $script:controllerOwner=Join-Path $runtime 'controller-verify-lock.d/owner.json'
  [void][IO.Directory]::CreateDirectory((Split-Path -Parent $script:controllerOwner));[IO.File]::WriteAllText($script:controllerOwner,'controller owner sentinel')
  $script:controllerOwnerHash=Hash-File $script:controllerOwner
  $recoveryDriver=New-Driver recoveryHost
  if($Part -eq 'authority'){
    Clear-Queue;[IO.File]::WriteAllText($queue,'{invalid authority fixture');$hash=Hash-File $queue
    $dispatch=New-DispatchFixture $recoveryDriver 'fifo-authority'
    $routing=Read-Json (Join-Path $runtime 'dispatch-log.jsonl');$routing.row='7';Write-Json (Join-Path $runtime 'dispatch-log.jsonl') $routing
    $r=Invoke-Attempt $recoveryDriver Gate @{QuarantineQueue=$hash} -Production
    Assert-Fifo ($r.Code -eq 73 -and -not $r.Body) "MUTANT $Mutant AC4 authority guard refuses unbound reset" $r.Output
    Assert-Fifo (-not(Test-Path $recovery) -and (Hash-File $queue) -ceq $hash) "MUTANT $Mutant AC4 authority guard leaves queue and quarantine unchanged" "output=$($r.Output)"
    Assert-Fifo ($r.Output -match 'eligibility|host-only') "MUTANT $Mutant AC4 authority guard names refusal reason" $r.Output
    Remove-Item -LiteralPath $dispatch.Path
    Write-Output "PASS FIFO authority guard case=$Mutant"
    return
  }
  foreach($fault in @('changed-hash','replaced','reparse','pre-move-replacement')) {
    Clear-Queue;[IO.File]::WriteAllText($queue,"{invalid $fault");$hash=Hash-File $queue;$recover=@{QuarantineQueue=$hash}
    $r=Invoke-Attempt $recoveryDriver Gate ($recover+(Set-Fixture @{now=$now.ToString('o')})) -Production
    Assert-Refused $r "AC4 $fault recovery marker starts pending" 'pending'
    $markerHash=Hash-File $recovery;$marker=Read-Json $recovery
    $replacement="$queue.replacement";$saved="$queue.$fault.original"
    if($fault-eq'pre-move-replacement'){
      $settings=Set-Fixture @{now=$now.AddSeconds(601).ToString('o');barrier='beforeMove'}
      $attempt=Start-Attempt $recoveryDriver Gate ($recover+$settings) -Production
      Wait-For {Test-Path ($fixture+'.ready')} 'pre-move barrier'
    }
    if($fault-eq'changed-hash'){[IO.File]::AppendAllText($queue,'changed')}
    else {
      [IO.File]::Move($queue,$saved)
      if($fault-eq'reparse'){New-Item -ItemType SymbolicLink -Path $queue -Target $saved|Out-Null}
      else {[IO.File]::Copy($saved,$queue)}
    }
    $faultHash=Hash-File $queue
    if($fault-eq'pre-move-replacement'){
      [IO.File]::WriteAllText(($fixture+'.continue'),'continue');$r=Complete-Attempt $attempt
      Remove-Item -LiteralPath ($fixture+'.ready'),($fixture+'.continue')
    } else { $r=Invoke-Attempt $recoveryDriver Gate ($recover+(Set-Fixture @{now=$now.AddSeconds(601).ToString('o')})) -Production }
    Assert-Refused $r "AC4 recovery $fault refuses without moving evidence" 'source-changed|unsafe-file'
    Assert-Fifo ((Hash-File $queue)-ceq$faultHash-and(Hash-File $recovery)-ceq$markerHash-and-not(Test-Path (Join-Path $marker.record 'verify-queue.json'))) "AC4 $fault preserves marker and queue"
    Assert-Refused (Invoke-Attempt $b Gate) "AC4 $fault marker still blocks admission" 'recovery marker'
    Write-Output "PASS AC4 recovery $fault retains queue/marker evidence and blocks admission"
  }
  Clear-Queue;[IO.File]::WriteAllText($queue,'{invalid recovery fixture');$hash=Hash-File $queue
  $recover=@{QuarantineQueue=$hash}
  foreach($token in @('CHASE_SETS_HEAVY_SLOT_ID','CHASE_SETS_HEAVY_SLOT_TRANSPORT')){
    Assert-Refused (Invoke-Attempt $recoveryDriver Gate $recover -Production -Environment @{$token='copied'}) 'AC4 token caller cannot reset' 'eligibility|host-only'
    Assert-Fifo (-not(Test-Path $recovery)-and(Hash-File $queue)-ceq$hash) 'AC4 token refusal preserves evidence'
  }
  $dispatch=New-DispatchFixture $recoveryDriver 'fifo-recovery'
  $routing=Read-Json (Join-Path $runtime 'dispatch-log.jsonl');$routing.row='13';Write-Json (Join-Path $runtime 'dispatch-log.jsonl') $routing
  Assert-Refused (Invoke-Attempt $recoveryDriver Gate) 'AC4 ineligible caller never touches queue' 'caller eligibility:.*routing-row=13'
  Assert-Fifo ((Hash-File $queue)-ceq$hash-and-not(Test-Path $recovery)) 'AC4 ineligible refusal preserves queue'
  $routing.row='7';Write-Json (Join-Path $runtime 'dispatch-log.jsonl') $routing
  $r=Invoke-Attempt $recoveryDriver Gate $recover -Production
  Assert-Refused $r 'AC4 reset requires unbound host authority' 'host-only'
  Assert-Fifo (-not(Test-Path $recovery)-and(Hash-File $queue)-ceq$hash) 'AC4 lane cannot create recovery marker'
  Remove-Item -LiteralPath $dispatch.Path
  $r=Invoke-Attempt $recoveryDriver Gate ($recover+(Set-Fixture @{now=$now.ToString('o')})) -Production
  Assert-Refused $r 'AC4 recovery first call pending' 'pending'
  $markerHash=Hash-File $recovery;$marker=Read-Json $recovery
  $r=Invoke-Attempt $recoveryDriver Gate ($recover+(Set-Fixture @{now=$now.AddSeconds(599).ToString('o')})) -Production
  Assert-Refused $r 'AC4 quarantine cannot complete early' 'pending'
  Assert-Fifo ((Hash-File $queue)-ceq$hash-and(Hash-File $recovery)-ceq$markerHash) 'AC4 early quarantine keeps evidence'
  Assert-Refused (Invoke-Attempt $b Gate) 'AC4 marker blocks ordinary admission' 'recovery marker'
  $saved="$queue.saved";[IO.File]::Move($queue,$saved)
  Assert-Refused (Invoke-Attempt $b Gate) 'AC4 marker blocks absent queue initialization' 'recovery marker'
  Assert-Fifo (-not(Test-Path $queue)) 'AC4 marker forbids queue init';[IO.File]::Move($saved,$queue)
  foreach($stop in @('moved','prepared','published','readback')){
    $r=Invoke-Attempt $recoveryDriver Gate ($recover+(Set-Fixture @{now=$now.AddSeconds(601).ToString('o');stop=$stop})) -Production
    Assert-Refused $r "AC4 recovery stop $stop is not completion" "fixture-stop:$stop"
    Assert-Fifo ((Hash-File $recovery)-ceq$markerHash-and(Hash-File (Join-Path $marker.record 'verify-queue.json'))-ceq$hash) "AC4 recovery stop $stop preserves evidence"
    Assert-Refused (Invoke-Attempt $b Gate) "AC4 recovery stop $stop blocks ordinary admission" 'recovery marker'
    Write-Output "PASS AC4 recovery stop $stop blocks admission, byte-exact evidence; rerun resumes"
  }
  $r=Invoke-Attempt $recoveryDriver Gate ($recover+(Set-Fixture @{now=$now.AddSeconds(601).ToString('o')})) -Production
  Assert-Fifo ($r.Code-eq0-and-not$r.Body-and$r.Output-match'record='-and-not(Test-Path $recovery)-and@((Read-Json $queue).tickets).Count-eq0) 'AC4 only complete recovery enables admission' $r.Output
  Assert-RecoveryOwners;$script:recoveryOwnerHash=$null
  $released=Release-Attempt $recoveryBarrier;Assert-Fifo ($released.Code-eq0) 'AC4 recovery owner releases normally' $released.Output
  Remove-Item -LiteralPath $script:controllerOwner;Remove-Item -LiteralPath (Split-Path -Parent $script:controllerOwner)
  $r=Invoke-Attempt $a Gate;Assert-Fifo ($r.Code-eq0-and$r.Body) 'AC4 admission after completed recovery' $r.Output
  Write-Output 'PASS AC4 host-only, token/lane fences, early boundary, absent queue, resumable recovery and completion'
  Write-Output "PASS FIFO behavioral baseline (revision=$(if($GuardRevision){$GuardRevision}else{'working tree'}) mutant=$Mutant part=$Part) wall=$([int]$suiteClock.Elapsed.TotalSeconds)s"
} finally {
  foreach($attempt in $attempts){if($attempt.Release){[IO.File]::WriteAllText($attempt.Release,'cleanup')}}
  foreach($driver in $drivers){[IO.File]::WriteAllText((Join-Path $driver.Dir 'stop'),'stop')}
  foreach($driver in $drivers){if(-not$driver.Process.WaitForExit(10000)){$driver.Process.Kill($true);$driver.Process.WaitForExit()}}
  $rootFull=[IO.Path]::GetFullPath($root)
  $tempFull=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
  $rootParent=[IO.Path]::GetDirectoryName($rootFull)
  $rootLeaf=[IO.Path]::GetFileName($rootFull)
  if($rootParent -ieq $tempFull -and $rootLeaf -cmatch '^heavy-fifo-[0-9a-f]{32}$' -and (Test-Path -LiteralPath $rootFull)){
    Remove-Item -LiteralPath $rootFull -Recurse -Force
    Write-Output "FIFO fixture cleanup: removed $rootFull"
  }
}
