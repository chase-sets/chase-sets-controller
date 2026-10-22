# Proof-arm relevance (#8207). Inside an impact-scoped controller battery,
# CHASE_SETS_BATTERY_IMPACT_PATHS lists the changed .orchestrator files. A proof
# arm (a guard-omission mutant or a #8102 classifier leg) re-proves that a guard
# or classifier is load-bearing, which only a change to its guarded file or to
# this support file can alter; it skips otherwise. Every candidate arm still
# runs. Outside a battery, and in every full battery, the variable is unset and
# every arm runs.
function Test-BatteryProofRelevant([string[]]$Files) {
  $impact = [string]$env:CHASE_SETS_BATTERY_IMPACT_PATHS
  if ([string]::IsNullOrWhiteSpace($impact)) { return $true }
  $changed = @($impact -split ';' | Where-Object { $_ })
  foreach ($file in @($Files) + @('interrupted-integration-test-support.ps1')) {
    if ($changed -ccontains ".orchestrator/$file") { return $true }
  }
  return $false
}

# The #8076 AC3 control binds the prior-owner guard's live-root refusal and its
# RESUME_GUARD_PRIOR_DEATH call site from the checked module, so module growth
# cannot leave a stale line pin (#9090); a site that is not unique refuses.
function Get-8076GuardSites([string]$Module) {
  $lines=[IO.File]::ReadAllLines($Module)
  $refusal=@(1..$lines.Count|Where-Object{$lines[$_-1].Trim()-ceq"throw 'INTEGRATION_RESUME_PRIOR_OWNER: live root'"})
  $call=@(1..$lines.Count|Where-Object{$lines[$_-1]-ceq'  Assert-InterruptedIntegrationTreeDead $sources.owner # RESUME_GUARD_PRIOR_DEATH'})
  if($refusal.Count-ne1-or$call.Count-ne1){throw "8076 AC3 NOT_CONSTRUCTIBLE: guard sites are not unique refusal=$($refusal.Count) call=$($call.Count)"}
  [pscustomobject]@{refusal=$refusal[0];call=$call[0]}
}

# Native controls run from their existing registered carriers, both focused
# and in the controller battery. Incident paths/stage shapes are read-only provenance;
# all Git repositories, commits, contents and process trees below are synthetic.
function Test-7963ResumeCarrier([ValidateSet('dispatch','ownership','rebase','watchdog','retained','native-branch')][string]$Carrier) {
  Import-Module (Join-Path $PSScriptRoot 'landed-integration-evidence.psm1') -Force -DisableNameChecking
  . (Join-Path $PSScriptRoot 'dispatch-ownership.ps1'); . (Join-Path $PSScriptRoot 'integration-dispatch-test-support.ps1')
  $root = Join-Path ([IO.Path]::GetTempPath()) ('integration-7963-'+$Carrier+'-'+[guid]::NewGuid().ToString('N'))
  [IO.Directory]::CreateDirectory($root) | Out-Null
  # Reproduce the actual retired Terra launch with the pre-migration launcher.
  # Candidate admission must reject that selector; never relax production
  # validation just to construct a historical stopped-attempt fixture.
  $historicalRoot = Join-Path $root 'pre-migration'
  $historicalZip = Join-Path $root 'pre-migration.zip'
  & git -C (Split-Path -Parent $PSScriptRoot) archive --format=zip "--output=$historicalZip" b3b4ac2d0d6e3d1aa6666e5b6179178ebcfaa780 .orchestrator
  if ($LASTEXITCODE -ne 0) { throw '7963 historical launcher archive failed' }
  Expand-Archive -LiteralPath $historicalZip -DestinationPath $historicalRoot; [void](Set-ArchivedOrchestrationLogMutexName (Join-Path $historicalRoot '.orchestrator'))
  $historicalDispatcher = Join-Path $historicalRoot '.orchestrator/dispatch-lane.ps1'
  $artifacts = Join-Path $PSScriptRoot 'artifacts'
  [IO.Directory]::CreateDirectory($artifacts) | Out-Null
  $script:resume7963Counter = 0
  $candidateHead = (@(& git.exe -C (Split-Path -Parent $PSScriptRoot) rev-parse HEAD) -join '').Trim()
  if ($LASTEXITCODE -ne 0 -or $candidateHead -cnotmatch '^[a-f0-9]{40}$') { throw '7963 exact test candidate unavailable' }
  $finished = $false
  $control8076 = @{pending=($Carrier-ceq'dispatch')}
  $candidateTag = $candidateHead.Substring(0,8)+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
  # #8102: the platform slot of the container holding this checkout is observed
  # (never taken) around each timed fixture window.
  $fleetContainer=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
  $holder=Join-Path $root 'native-holder.ps1'
  [IO.File]::WriteAllText($holder,@'
param([string]$Release,[string]$Ready,[string]$Arm,[string]$ArmedReceipt,[string]$Expire,[int]$OwnerPid,[string]$OwnerStartIdentity)
$p=Get-Process -Id $PID
[IO.File]::WriteAllText($Ready,([ordered]@{pid=$PID;startIdentity=$p.StartTime.ToUniversalTime().ToString('o')}|ConvertTo-Json -Compress))
if($Arm){
  while(-not(Test-Path -LiteralPath $Arm)){
    if(Test-Path -LiteralPath $Release){exit 0}
    [Threading.Thread]::Sleep(20)
  }
  if(Test-Path -LiteralPath $Release){exit 0}
}
if($OwnerPid -and $OwnerStartIdentity){
  while(-not(Test-Path -LiteralPath $Release)-and-not(Test-Path -LiteralPath $Expire)){
    try{$owner=Get-Process -Id $OwnerPid -ErrorAction Stop;$live=$owner.StartTime.ToUniversalTime().ToString('o')-ceq$OwnerStartIdentity}catch{$live=$false}
    if(-not$live){exit 0}
    [Threading.Thread]::Sleep(100)
  }
  exit 0
}
if($Arm){
  $armedAt=[datetimeoffset]::UtcNow
  $receipt=[ordered]@{pid=$PID;startIdentity=$p.StartTime.ToUniversalTime().ToString('o');armedAt=$armedAt.ToString('o');deadline=$armedAt.AddSeconds(30).ToString('o')}
  [IO.File]::WriteAllText("$ArmedReceipt.pending",($receipt|ConvertTo-Json -Compress))
  [IO.File]::Move("$ArmedReceipt.pending",$ArmedReceipt)
}
while(-not(Test-Path -LiteralPath $Release)-and-not(Test-Path -LiteralPath $Expire)){[Threading.Thread]::Sleep(20)}
'@,[Text.UTF8Encoding]::new($false))
  function Proof([bool]$Condition,[string]$Name) {
    if (-not $Condition) { throw "7963 $Carrier ASSERTION FAILED: $Name; retained=$root" }
    Write-Output "PROOF 7963 $Carrier $Name"
  }
  function FixtureGit([string]$Repo,[string[]]$Arguments) {
    $output = @(& git.exe --no-optional-locks -C $Repo @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "7963 native Git failed: $($Arguments -join ' ') $($output -join "`n")" }
    return ($output -join "`n").Trim()
  }
  function Save([string]$Path,$Value) { [IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 20 -Compress),[Text.UTF8Encoding]::new($false)) }
  function Native([string]$Script,[string[]]$Arguments,[switch]$KeepGitEnvironment) {
    $script:resume7963Counter++
    $stem=Join-Path $artifacts ("7963-$candidateTag-$Carrier-{0:d3}" -f $script:resume7963Counter)
    $configIndex=[Array]::IndexOf($Arguments,'-Config')
    if($configIndex-ge0){
      $invocationConfig=Read-RebaseJson $Arguments[$configIndex+1]
      $resumeBytesPath=$null;$resumeBytesHash=$null
      if($invocationConfig.resumePath){
        $resumeBytes=[IO.File]::ReadAllBytes($invocationConfig.resumePath)
        $resumeBytesPath="$stem.resume-input.bin";$resumeBytesHash=Get-RebaseHash $resumeBytes
        [IO.File]::WriteAllBytes($resumeBytesPath,$resumeBytes)
      }
      # The child inherits routing state, so routing names the state it reads (#9619).
      Save "$stem.input.json" ([ordered]@{config=$invocationConfig;resumeInputBytesPath=$resumeBytesPath;resumeInputSha256=$resumeBytesHash;dispatchSha256=(Get-RebaseHash ([IO.File]::ReadAllBytes($invocationConfig.dispatch)));routing=[ordered]@{root=$env:CHASE_SETS_ROUTING_DATA_ROOT;lkg=$env:CHASE_SETS_ROUTING_LKG_PATH}})
    }
    $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=(Join-Path $PSHOME 'pwsh.exe');$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    $resumeInvocation=$false
    if($configIndex-ge0-and$configIndex+1-lt$Arguments.Count){$resumeInvocation=[bool](Read-RebaseJson $Arguments[$configIndex+1]).resume}
    # The retained watchdog relaunches the interrupted resume itself, so its child
    # environment is the resume environment (#204).
    if([IO.Path]::GetFileName($Script)-ceq'lane-stall-watchdog.ps1'){$resumeInvocation=$true}
    $gitEnvironmentNames=@('GIT_DIR','GIT_WORK_TREE','GIT_INDEX_FILE','GIT_OBJECT_DIRECTORY','GIT_ALTERNATE_OBJECT_DIRECTORIES')
    if($resumeInvocation-and-not$KeepGitEnvironment){foreach($name in $gitEnvironmentNames){[void]$psi.Environment.Remove($name)}}
    if($resumeInvocation-and$KeepGitEnvironment){$psi.Environment['GIT_ALTERNATE_OBJECT_DIRECTORIES']=Join-Path $root 'synthetic-alternate-objects'}
    foreach($argument in @('-NoProfile','-NonInteractive','-File',$Script)+$Arguments){[void]$psi.ArgumentList.Add($argument)}
    $gitEnvironment=[ordered]@{};foreach($name in $gitEnvironmentNames){$gitEnvironment[$name]=$psi.Environment[$name]}
    $p=[Diagnostics.Process]::Start($psi)
    try {
      $start=$p.StartTime.ToUniversalTime().ToString('o');$out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync();$p.WaitForExit()
      $stdout=$out.GetAwaiter().GetResult();$stderr=$err.GetAwaiter().GetResult()
      [IO.File]::WriteAllText("$stem.stdout.txt",$stdout);[IO.File]::WriteAllText("$stem.stderr.txt",$stderr)
      $result=[ordered]@{pid=$p.Id;startIdentity=$start;exitCode=$p.ExitCode;hasExited=$p.HasExited;script=$Script;arguments=$Arguments;stdoutPath="$stem.stdout.txt";stderrPath="$stem.stderr.txt";gitEnvironment=$gitEnvironment}
      Save "$stem.result.json" $result
      return [pscustomobject]@{exit=$p.ExitCode;stdout=$stdout;stderr=$stderr;resultPath="$stem.result.json";gitEnvironment=$gitEnvironment}
    } finally { $p.Dispose() }
  }
  function Identity8076($Process,$Expected) {
    $null-ne$Process.CreationDate-and
      [Math]::Abs(([datetimeoffset]$Process.CreationDate).ToUniversalTime().Ticks-([datetimeoffset]$Expected).ToUniversalTime().Ticks)-lt10
  }
  function Observe8076($All,$Owner) {
    $seen=[Collections.Generic.HashSet[int]]::new();$queue=[Collections.Generic.Queue[int]]::new()
    $roots=@(foreach($role in @('launcher','child')){
      $id=[int]$Owner."${role}Pid";$expected=$Owner."${role}StartIdentity"
      [void]$seen.Add($id);$queue.Enqueue($id)
      $rows=@($All|Where-Object{$_.ProcessId-eq$id})
      [ordered]@{role=$role;ProcessId=$id;recordedStartIdentity=$expected;state=$(if(-not$rows.Count){'absent'}elseif($rows.Count-eq1-and(Identity8076 $rows[0] $expected)){'exact'}else{'reuse-or-ambiguous'});rows=$rows}
    })
    $descendants=@(while($queue.Count){
      $parent=$queue.Dequeue()
      foreach($row in @($All|Where-Object{$_.ParentProcessId-eq$parent})){
        if($seen.Add([int]$row.ProcessId)){$queue.Enqueue([int]$row.ProcessId);$row}
      }
    })
    [ordered]@{observedAt=[datetimeoffset]::UtcNow.ToString('o');roots=$roots;descendants=$descendants}
  }
  function Rows8076($Rows) {
    @($Rows|ForEach-Object{
      [ordered]@{ProcessId=$_.ProcessId;ParentProcessId=$_.ParentProcessId;CreationDate=$(if($null-ne$_.CreationDate){([datetimeoffset]$_.CreationDate).ToUniversalTime().ToString('o')}else{$null});ThreadCount=$_.ThreadCount;ExecutionState=$_.ExecutionState;threadState=$(if($null-eq$_.ThreadCount){'unknown'}elseif($_.ThreadCount-eq0){'terminated-but-referenced'}else{'running'})}
    })
  }
  function Settle8076($Record,[string]$Path,$Owner,$Seed) {
    $initial=if($Record.hold){$Record.hold.preArmObservation}else{$Record.observations[0]}
    if(@($initial.roots|Where-Object{$_.state-ceq'reuse-or-ambiguous'}).Count){$Record.classification='MEASURED_REUSE';return}
    $pending=@($initial.roots|Where-Object{$_.state-ceq'exact'})
    if(-not$pending.Count){$Record.classification='NO_REPRODUCTION';return}
    if($Record.hold){
      $held=@($pending|Where-Object{$_.role-ceq'launcher'-and$_.ProcessId-eq$Record.hold.pid-and(Identity8076 $_.rows[0] $Record.hold.startIdentity)})
      if($held.Count-ne1){throw '8076 AC3 NOT_CONSTRUCTIBLE: release lacks the projected holder identity'}
      $Record.hold.preReleaseObservation=Observe8076 (Rows8076 @(Get-CimInstance Win32_Process -Property ProcessId,ParentProcessId,CreationDate,ThreadCount,ExecutionState -ErrorAction Stop)) $Owner
      $live=@($Record.hold.preReleaseObservation.roots|Where-Object{$_.role-ceq'launcher'-and$_.state-ceq'exact'-and$_.rows[0].ThreadCount-gt0})
      if(Test-Path -LiteralPath $Record.hold.expireRequestPath){
        $expiredAt=([datetimeoffset]$Record.hold.armedReceipt.armedAt).AddSeconds(30).ToString('o')
        [IO.File]::WriteAllText($Record.hold.expirePath,(@{pid=$Record.hold.pid;startIdentity=$Record.hold.startIdentity;expiredAt=$expiredAt}|ConvertTo-Json -Compress))
      }
      if(Test-Path -LiteralPath $Record.hold.expirePath){
        $expiry=Read-RebaseJson $Record.hold.expirePath
        if($expiry.pid-ne$Record.hold.pid-or$expiry.startIdentity-cne$Record.hold.startIdentity){throw '8076 AC3 NOT_CONSTRUCTIBLE: expiry signal identity differs'}
        $Record.hold.expiryObserved=$true
      }
      $Record.hold.releaseAbsent= -not(Test-Path -LiteralPath $Record.hold.releasePath)
      $Record.hold.releaseStartedAt=$(if($Record.hold.expiryObserved){$expiry.expiredAt}else{[datetimeoffset]::UtcNow.ToString('o')})
      $Record.hold.fleetLoadAtRelease=Get-FleetLoadObservation $fleetContainer
      $Record.hold.expiryObserved=Test-Path -LiteralPath $Record.hold.expirePath
      if($Record.hold.expiryObserved-or$live.Count-ne1-or-not$Record.hold.releaseAbsent-or-not$Record.hold.armedReceipt){
        # #8102: a miss is MEASURED_LOAD only when the test-owned expiry signal
        # was observed and the platform slot was held by one live owner from arm;
        # no wall-clock deadline decides the unmodified carrier.
        $window=Get-FleetLoadWindow $Record.hold.fleetLoadAtArm $Record.hold.fleetLoadAtRelease
        $boundMissed=[bool]$Record.hold.expiryObserved
        if($boundMissed-and$Record.hold.releaseAbsent-and$window.held){
          $elapsed=([datetimeoffset]$Record.hold.releaseStartedAt-[datetimeoffset]$Record.hold.armedReceipt.armedAt).TotalSeconds
          $Record.classification='MEASURED_LOAD'
          $Record.hold.fleetLoad=[ordered]@{window=$window;elapsedSeconds=$elapsed;boundSeconds=30}
          throw "MEASURED_LOAD 8076 $Carrier fleetHolder=$($window.holder) elapsedSeconds=$elapsed boundSeconds=30 armedAt=$($Record.hold.armedReceipt.armedAt) deadline=$($Record.hold.armedReceipt.deadline) releaseStartedAt=$($Record.hold.releaseStartedAt) projection=$Path"
        }
        throw '8076 AC3 NOT_CONSTRUCTIBLE: holder not live and unreleased before armed deadline at release'
      }
      [IO.File]::WriteAllText($Record.hold.releasePath,'release projected 8076 holder')
      $Record.hold.releasedAt=[datetimeoffset]::UtcNow.ToString('o')
      $Record.hold.releaseMarginSeconds=([datetimeoffset]$Record.hold.armedReceipt.deadline-[datetimeoffset]$Record.hold.releasedAt).TotalSeconds
      if($Record.hold.releaseMarginSeconds-le0){throw '8076 AC3 NOT_CONSTRUCTIBLE: release did not precede armed deadline'}
    }
    do {
      $filter=(@($pending|ForEach-Object{"ProcessId = $($_.ProcessId)"})-join' OR ')
      $rows=Rows8076 @(Get-CimInstance Win32_Process -Filter $filter -ErrorAction Stop)
      $observation=Observe8076 $rows $Owner
      $Record.observations+=,$observation
      if(@($observation.roots|Where-Object{$_.state-ceq'reuse-or-ambiguous'}).Count){$Record.classification='MEASURED_REUSE';break}
      $pending=@($observation.roots|Where-Object{$_.state-ceq'exact'})
      if(-not$pending.Count){$Record.classification='MEASURED_STALE';break}
    } while($true)
    $Record.boundExpired=($pending.Count-gt0-and$null-eq$Record.classification)
    $Record.settleCompletedAt=[datetimeoffset]::UtcNow.ToString('o')
  }
  function Resume8076($Record,[string]$Path,$Owner,$Seed,$Obligation,[string]$Runtime,[string]$Label) {
    try {
      Settle8076 $Record $Path $Owner $Seed # 8076_IDENTITY_BOUND_WAIT
    } finally { Save $Path $Record }
    New-InterruptedIntegrationResume $Obligation $Runtime $Label $Owner.launchId
  }
  function MeasuredResume8076($Owner,$Seed,$Obligation,[string]$Runtime,[string]$Label,[bool]$Control) {
    $path=$Seed.resultPath.Replace('.result.json','.prior-owner.json')
    $watchdogPath=Join-Path $Runtime "watchdog-lane-$Label.json"
    $all=Rows8076 @(Get-CimInstance Win32_Process -Property ProcessId,ParentProcessId,CreationDate,ThreadCount,ExecutionState -ErrorAction Stop)
    $sites8076=Get-8076GuardSites (Join-Path $PSScriptRoot 'landed-integration-evidence.psm1')
    $record=[ordered]@{schemaVersion='interrupted-integration-measurement/v1';candidateHead=$candidateHead;seedResultPath=$Seed.resultPath;seedResult=(Read-RebaseJson $Seed.resultPath);watchdogPath=$watchdogPath;watchdogSha256=(Get-RebaseHash ([IO.File]::ReadAllBytes($watchdogPath)));watchdog=$Owner;guardCallSite="landed-integration-evidence.psm1:$($sites8076.call)";guardRefusalSite="landed-integration-evidence.psm1:$($sites8076.refusal)";observations=@((Observe8076 $all $Owner));classification=$null;boundExpired=$false;hold=$null}
    $record.guardModuleSha256=Get-RebaseHash ([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'landed-integration-evidence.psm1')))
    $pair=$null
    try {
      if($Control){
        $record.hold=$Seed.hold8076
      }
      Save $path $record
      if($Control){
        $held=@($record.observations[0].roots|Where-Object{$_.role-ceq'launcher'-and$_.state-ceq'exact'-and$_.ProcessId-eq$record.hold.pid})
        if($held.Count-ne1-or$held[0].rows[0].ThreadCount-le0-or(Test-Path -LiteralPath $record.hold.releasePath)){
          $record.classification=if(@($record.observations[0].roots|Where-Object{$_.state-ceq'reuse-or-ambiguous'}).Count){'MEASURED_REUSE'}elseif(-not@($record.observations[0].roots|Where-Object{$_.state-ceq'exact'}).Count){'NO_REPRODUCTION'}else{$null}
          throw '8076 AC3 NOT_CONSTRUCTIBLE: unreleased holder is not a live exact recorded root'
        }
        # Mutate this in-process resume, not the dispatch script run by Native.
        # Both legs use this one stopped repository and the same retained owner.
        $source=[IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'interrupted-integration-test-support.ps1'))
        $text=[Text.Encoding]::UTF8.GetString($source)
        $needle='      Settle8076 $Record $Path $Owner $Seed # '+'8076_IDENTITY_BOUND_WAIT'
        if([regex]::Matches($text,[regex]::Escape($needle)).Count-ne1){throw '8076 unique omission site unavailable'}
        $mutant=$text.Replace($needle,'      # Synthetic omission: 8076 identity-bound wait only.')
        $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($mutant,[ref]$tokens,[ref]$errors)
        if($errors.Count){throw '8076 omission source failed parsing'}
        $definition=$ast.Find({param($node) $node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-ceq'Resume8076'},$true)
        $block=[scriptblock]::Create($definition.Extent.Text)
        $pair=[ordered]@{schemaVersion='8076-wait-omitted-pair/v2';name='8076-wait-omitted';candidateSourceSha256=(Get-RebaseHash $source);mutantSourceSha256=(Get-RebaseHash ([Text.Encoding]::UTF8.GetBytes($mutant)));projectionPath=$path;heldIdentity=$record.hold;mutantError=$null;mutantStack=$null;refusalObservation=$null;rootLiveAtRefusal=$false;releaseCausalityProven=$false;candidatePassed=$false}
        $before=Get-RebaseRecordIdentity (Get-InterruptedIntegrationState $Obligation.worktree)
        $pair.frozenStateIdentity=$before;$pair.watchdogSha256=$record.watchdogSha256
        try {
          & { . $block; Resume8076 $record $path $Owner $Seed $Obligation $Runtime $Label } | Out-Null
        } catch {$pair.mutantError=$_.Exception.Message;$pair.mutantStack=$_.ScriptStackTrace;$pair.mutantRefusedAt=[datetimeoffset]::UtcNow.ToString('o')}
        $pair.refusalObservation=Observe8076 (Rows8076 @(Get-CimInstance Win32_Process -Property ProcessId,ParentProcessId,CreationDate,ThreadCount,ExecutionState -ErrorAction Stop)) $Owner
        $live=@($pair.refusalObservation.roots|Where-Object{$_.role-ceq'launcher'-and$_.state-ceq'exact'-and$_.rows[0].ThreadCount-gt0})
        $pair.rootLiveAtRefusal=($live.Count-eq1-and-not(Test-Path -LiteralPath $record.hold.releasePath))
        if($pair.mutantError-cne'INTEGRATION_RESUME_PRIOR_OWNER: live root'-or$pair.mutantStack-notmatch"landed-integration-evidence\.psm1: line $($sites8076.refusal)(?!\d)"){
          throw "8076 AC3 NOT_CONSTRUCTIBLE: held wait-omitted mutant did not refuse at psm1:$($sites8076.refusal)"
        }
        if(-not$pair.rootLiveAtRefusal){throw '8076 AC3 NOT_CONSTRUCTIBLE: holder was not live and unreleased at the refusal'}
        if((Get-RebaseRecordIdentity (Get-InterruptedIntegrationState $Obligation.worktree))-cne$before){throw '8076 omission changed frozen native inputs'}
        if((Get-RebaseHash ([IO.File]::ReadAllBytes($watchdogPath)))-cne$pair.watchdogSha256){throw '8076 omission changed frozen watchdog inputs'}
        $pair.omissionValidatedAt=[datetimeoffset]::UtcNow.ToString('o')
        $record.hold.preArmObservation=Observe8076 (Rows8076 @(Get-CimInstance Win32_Process -Property ProcessId,ParentProcessId,CreationDate,ThreadCount,ExecutionState -ErrorAction Stop)) $Owner
        $fresh=@($record.hold.preArmObservation.roots|Where-Object{$_.role-ceq'launcher'-and$_.state-ceq'exact'-and$_.ProcessId-eq$record.hold.pid-and$_.rows[0].ThreadCount-gt0})
        if($fresh.Count-ne1-or@($record.hold.preArmObservation.roots|Where-Object{$_.state-ceq'reuse-or-ambiguous'}).Count-or
          $Seed.holder8076.HasExited-or$Seed.holder8076.StartTime.ToUniversalTime().ToString('o')-cne$record.hold.startIdentity-or
          (Test-Path -LiteralPath $record.hold.releasePath)-or(Test-Path -LiteralPath $record.hold.armPath)-or(Test-Path -LiteralPath $record.hold.armedReceiptPath)){
          throw '8076 AC3 NOT_CONSTRUCTIBLE: same unarmed unreleased holder identity unavailable before arm'
        }
        # Proof -> frozen equality -> fresh same identity -> one arm -> release.
        $record.hold.armStartedAt=[datetimeoffset]::UtcNow.ToString('o')
        $record.hold.fleetLoadAtArm=Get-FleetLoadObservation $fleetContainer
        [IO.File]::WriteAllText($record.hold.armPath,'arm captured 8076 holder')
        $record.hold.armWrittenAt=[datetimeoffset]::UtcNow.ToString('o')
        while(-not(Test-Path -LiteralPath $record.hold.armedReceiptPath)-and-not$Seed.holder8076.HasExited){
          if($Seed.holder8076.HasExited-or$Seed.holder8076.StartTime.ToUniversalTime().ToString('o')-cne$record.hold.startIdentity){throw '8076 AC3 NOT_CONSTRUCTIBLE: armed holder identity unavailable'}
          [Threading.Thread]::Sleep(20)
        }
        if(-not(Test-Path -LiteralPath $record.hold.armedReceiptPath)){throw '8076 AC3 NOT_CONSTRUCTIBLE: holder armed receipt missing'}
        $record.hold.armedReceipt=Read-RebaseJson $record.hold.armedReceiptPath
        $armed=$record.hold.armedReceipt
        if($armed.pid-ne$record.hold.pid-or$armed.startIdentity-cne$record.hold.startIdentity-or
          [datetimeoffset]$record.hold.armStartedAt-le[datetimeoffset]$record.hold.preArmObservation.observedAt-or
          [datetimeoffset]$record.hold.preArmObservation.observedAt-le[datetimeoffset]$pair.omissionValidatedAt-or
          [datetimeoffset]$armed.armedAt-lt[datetimeoffset]$record.hold.armStartedAt-or
          ([datetimeoffset]$armed.deadline-[datetimeoffset]$armed.armedAt).TotalSeconds-ne30){throw '8076 AC3 NOT_CONSTRUCTIBLE: holder arm identity, ordering or bound differs'}
        Save $path $record
      }
      $binding=Resume8076 $record $path $Owner $Seed $Obligation $Runtime $Label
      if($Control){
        if($record.classification-cne'MEASURED_STALE'-or-not$record.hold.releasedAt){throw '8076 candidate did not settle measured held identity'}
        if(-not$Seed.holder8076.HasExited){throw '8076 AC3 NOT_CONSTRUCTIBLE: released holder has not exited'}
        $record.hold.exitedAt=$Seed.holder8076.ExitTime.ToUniversalTime().ToString('o')
        if(-not$record.hold.armedReceipt-or-not$record.hold.preReleaseObservation-or-not$record.hold.releaseAbsent-or
          $record.hold.releaseMarginSeconds-le0-or$record.hold.Contains('cleanupReleasedAt')-or
          [datetimeoffset]$record.hold.exitedAt-le[datetimeoffset]$record.hold.releasedAt-or
          [datetimeoffset]$record.settleCompletedAt-lt[datetimeoffset]$record.hold.releasedAt){throw '8076 AC3 NOT_CONSTRUCTIBLE: candidate release causality or terminal settlement unproven'}
        if((Get-RebaseRecordIdentity (Get-InterruptedIntegrationState $Obligation.worktree))-cne$before){throw '8076 candidate changed frozen native inputs'}
        if($binding.sources.watchdogSha256-cne$pair.watchdogSha256){throw '8076 candidate did not bind the rewritten watchdog bytes'}
        $pair.releaseCausalityProven=$true
        $pair.candidatePassed=$true
      }
      return $binding
    } finally {
      Save $path $record
      if($pair){Save ($Seed.resultPath.Replace('.result.json','.wait-omitted-pair.json')) $pair}
      [Console]::WriteLine("MEASUREMENT 8076 $Carrier classification=$($record.classification) boundExpired=$($record.boundExpired) projection=$path")
    }
  }
  $harness=Join-Path $root 'synthetic-harness.ps1'
  [IO.File]::WriteAllText($harness,@'
param([string]$Config)
$ErrorActionPreference='Stop'
$cfg=Get-Content -Raw $Config|ConvertFrom-Json -DateKind String
[void][Console]::In.ReadToEnd()
Import-Module $cfg.module -Force -DisableNameChecking
# The launcher publishes this child's started record before it waits on the
# child: wait on that record or on the launcher's exit, never on elapsed time.
# The pinned handle keeps a reused launcher PID from standing in for it.
$self=Get-Process -Id $PID;$launcher=$self.Parent
if($null-ne$launcher){[void]$launcher.Handle;if($launcher.StartTime-gt$self.StartTime){$launcher=$null}}
do {
  $launcherExited=$null-eq$launcher-or$launcher.HasExited
  $owners=@(Get-ChildItem -LiteralPath $cfg.runtime -Filter 'dispatch-launch-*.json' -File|ForEach-Object{Get-Content -Raw $_.FullName|ConvertFrom-Json -DateKind String}|Where-Object{$_.childPid-eq$PID-and$_.state-ceq'started'})
  if($owners.Count-ge1-or$launcherExited){break}
  [Threading.Thread]::Sleep(20)
} while($true)
if($owners.Count-ne1){throw "synthetic actual child ownership not published: owners=$($owners.Count) launcherExited=$launcherExited"}
if($cfg.resume){
  $entry=Get-InterruptedIntegrationState $cfg.repo
  [IO.File]::WriteAllText($cfg.entry,($entry|ConvertTo-Json -Compress))
  if($cfg.entryOnly){exit 0}
  $paths=@(& git --no-optional-locks -C $cfg.repo diff --name-only --diff-filter=U)
  if($LASTEXITCODE-ne0){throw 'synthetic unmerged inventory failed'}
  foreach($path in $paths){[IO.File]::WriteAllText((Join-Path $cfg.repo $path),"synthetic resolved $path`n");& git -C $cfg.repo add -- $path;if($LASTEXITCODE-ne0){throw 'synthetic stage failed'}}
}
$args=@('-NoProfile','-NonInteractive','-File',$cfg.helper,'-Pr',[string]$cfg.obligation.pr,'-ReviewedHead',$cfg.obligation.targetHead,'-NewBase',$cfg.obligation.newBase,'-SourcePassReceiptIdentity','ABSENT_REVIEW_REQUIRED','-IntegrationLane',$cfg.obligation.integrationLane,'-Worktree',$cfg.repo,'-RuntimeRoot',$cfg.runtime)
if($cfg.resume){$args+='-ContinueInterruptedIntegration'}
$command='pwsh '+($args -join ' ')
if(-not$cfg.resume-and$cfg.outerCommand){
  $body="& '"+$cfg.helper.Replace("'","''")+"' "+(@($args[4..($args.Count-1)]|ForEach-Object{if($_.StartsWith('-')){$_}else{"'"+$_.Replace("'","''")+"'"}})-join' ')
  $exe=Join-Path $PSHOME 'pwsh.exe';$output=@(& $exe -NoProfile -NonInteractive -Command $body 2>&1);$code=$LASTEXITCODE
  $command='"'+$exe+'" -NoProfile -NonInteractive -Command "'+$body+'"'
}else{$output=@(& pwsh @args 2>&1);$code=$LASTEXITCODE}
[ordered]@{type='item.completed';item=[ordered]@{id='native-helper';type='command_execution';command=$command;aggregated_output=($output -join "`n");exit_code=[long]$code;status=$(if($code-eq0){'completed'}else{'failed'})}}|ConvertTo-Json -Depth 8 -Compress
if(-not$cfg.resume-and$code-ne$(if($cfg.outerCommand){1}else{2})){throw "synthetic initial conflict exit=$code $output"}
if($cfg.resume-and$code-notin@(0,2)){throw "synthetic continuation exit=$code $output"}
if(-not$cfg.resume-and$cfg.holdDescendant){
  # Do not inherit the seed's redirected capture pipes: their EOF would wait
  # for this intentionally surviving child before the caller could probe it.
  $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=(Join-Path $PSHOME 'pwsh.exe');$psi.UseShellExecute=$true;$psi.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
  foreach($arg in @('-NoProfile','-NonInteractive','-File',$cfg.holder,'-Release',$cfg.descendantRelease,'-Ready',$cfg.descendantReady,'-OwnerPid',[string]$cfg.ownerPid,'-OwnerStartIdentity',$cfg.ownerStartIdentity)){[void]$psi.ArgumentList.Add($arg)}
  $descendant=[Diagnostics.Process]::Start($psi)
  # Ready is the holder's first act; wait on it or on the holder's exit.
  try{while(-not(Test-Path -LiteralPath $cfg.descendantReady)-and-not$descendant.HasExited){[Threading.Thread]::Sleep(20)};if(-not(Test-Path -LiteralPath $cfg.descendantReady)){throw "native descendant failed to start: exited $($descendant.ExitCode)"}}finally{$descendant.Dispose()}
}
if(-not$cfg.resume){exit 0} # Faithful nominal child success is not rebase completion.
exit $code
'@,[Text.UTF8Encoding]::new($false))
  $runner=Join-Path $root 'synthetic-launch.ps1'
  [IO.File]::WriteAllText($runner,@'
param([string]$Config,[switch]$Dry,[switch]$NoCim,[string]$Role='implementation',[string]$Harness='codex',[string]$Model='gpt-6-astra',[string]$Effort='',[string]$Route='7',[string]$Placement='override-Todd')
$ErrorActionPreference='Stop'
if($NoCim){Import-Module Microsoft.PowerShell.Management;Import-Module Microsoft.PowerShell.Utility;Remove-Module CimCmdlets -Force -ErrorAction SilentlyContinue;$PSModuleAutoLoadingPreference='None'}
$cfg=Get-Content -Raw $Config|ConvertFrom-Json -DateKind String
if($cfg.latencyMs){[Threading.Thread]::Sleep([int]$cfg.latencyMs)} # carrier-latency-injection (#9619): delay before dispatch
$params=@{Harness=$Harness;Model=$Model;Effort=$(if($Effort){$Effort}elseif($Route-eq'2'){'medium'}else{'high'});Row=[int]$Route;Placement=$Placement;LaneRole=$Role;PromptFile=$cfg.prompt;Worktree=$cfg.repo;Label=$cfg.label;ExecutablePath=(Join-Path $PSHOME 'pwsh.exe');TestArgumentList=@('-NoProfile','-NonInteractive','-File',$cfg.harness,'-Config',$Config);TestRuntimeRoot=$cfg.runtime;DryRun=$Dry}
if($cfg.resumePath){$params.InterruptedIntegrationResumePath=$cfg.resumePath}
if($cfg.barrierObserved){$params.ResumeAdmissionObservedPath=$cfg.barrierObserved;$params.ResumeAdmissionContinuePath=$cfg.barrierContinue}
if(-not$cfg.resume-and$cfg.request){$params.StartRequestIdentity=$cfg.request;$params.StartAcknowledgementPath=Join-Path $cfg.runtime "dispatch-start-$($cfg.request).json"}
if(-not$cfg.resume-and$cfg.targetPath){$params.IntegrationTargetPath=$cfg.targetPath;$params.IntegrationAuthorityFixturePath=$cfg.authorityPath}
& $cfg.dispatch @params
exit $LASTEXITCODE
'@,[Text.UTF8Encoding]::new($false))
  $watchdogBridge=Join-Path $root 'synthetic-watchdog-dispatch.ps1'
  [IO.File]::WriteAllText($watchdogBridge,@'
param($Harness,$Model,$Effort,$Row,$Placement,$LaneRole,$PromptFile,$Worktree,$Label,$SemanticAttemptId,$WatchdogRelaunchCount,$ResumeOfLaunchId,$StartRequestIdentity,$StartAcknowledgementPath,$InterruptedIntegrationResumePath)
$ErrorActionPreference='Stop'
$path=$env:SYNTHETIC_7963_WATCHDOG_CONFIG
$cfg=Get-Content -Raw $path|ConvertFrom-Json -DateKind String
$cfg.entryOnly=$false;$cfg.label=$Label;$cfg.prompt=$PromptFile;$cfg.resumePath=$InterruptedIntegrationResumePath
[IO.File]::WriteAllText($path,($cfg|ConvertTo-Json -Depth 12 -Compress))
& $cfg.dispatch -Harness $Harness -Model $Model -Effort $Effort -Row ([int]$Row) -Placement $Placement -LaneRole $LaneRole -PromptFile $PromptFile -Worktree $Worktree -Label $Label -SemanticAttemptId $SemanticAttemptId -WatchdogRelaunchCount ([int]$WatchdogRelaunchCount) -ResumeOfLaunchId $ResumeOfLaunchId -StartRequestIdentity $StartRequestIdentity -StartAcknowledgementPath $StartAcknowledgementPath -InterruptedIntegrationResumePath $InterruptedIntegrationResumePath -ExecutablePath (Join-Path $PSHOME 'pwsh.exe') -TestArgumentList @('-NoProfile','-NonInteractive','-File',$cfg.harness,'-Config',$path) -TestRuntimeRoot $cfg.runtime
exit $LASTEXITCODE
'@,[Text.UTF8Encoding]::new($false))
  function Fixture([string]$Incident,[switch]$SecondStop,[switch]$HoldDescendant,[switch]$CopiedHelper,[switch]$CurrentRequest) {
    $case=Join-Path $root ($Incident+'-'+[guid]::NewGuid().ToString('N'));$repo=Join-Path $case 'lane';$runtime=Join-Path $case 'runtime';$remote=Join-Path $case 'remote.git'
    [IO.Directory]::CreateDirectory($repo)|Out-Null;[IO.Directory]::CreateDirectory($runtime)|Out-Null
    foreach($name in @('rebase-integration.ps1','landed-integration-evidence.psm1','dispatch-ownership.ps1')){
      Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $runtime $name)
      if((Get-FileHash -LiteralPath (Join-Path $runtime $name)).Hash-cne(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $name)).Hash){throw '7963 canonical fixture helper source differs'}
    }
    $shape=@(Get-Content -Raw (Join-Path $PSScriptRoot 'fixtures/interrupted-integration-shapes.json')|ConvertFrom-Json|Where-Object{$_.incident-ceq$Incident})[0]
    [void](FixtureGit $repo @('init','-q','--initial-branch=main'));[void](FixtureGit $repo @('config','user.name','Unmistakably Synthetic 7963'));[void](FixtureGit $repo @('config','user.email','synthetic-7963@example.invalid'));[void](FixtureGit $repo @('config','commit.gpgsign','false'))
    foreach($change in $shape.changes){$kind,$path=$change.Split("`t",2);[IO.Directory]::CreateDirectory((Split-Path -Parent (Join-Path $repo $path)))|Out-Null;if($kind-cne'A'){[IO.File]::WriteAllText((Join-Path $repo $path),"synthetic ancestor $path`nunchanged middle`nbase tail`n")}}
    if($SecondStop){[IO.File]::WriteAllText((Join-Path $repo 'later.txt'),"later ancestor`n")}
    [void](FixtureGit $repo @('add','.'));[void](FixtureGit $repo @('commit','-qm','synthetic ancestor'));$ancestor=FixtureGit $repo @('rev-parse','HEAD')
    $branch="synthetic/$Carrier-$Incident";[void](FixtureGit $repo @('checkout','-qb',$branch))
    foreach($change in $shape.changes){$kind,$path=$change.Split("`t",2);[IO.Directory]::CreateDirectory((Split-Path -Parent (Join-Path $repo $path)))|Out-Null;[IO.File]::WriteAllText((Join-Path $repo $path),"synthetic feature $path`nunchanged middle`nfeature tail`n")}
    [void](FixtureGit $repo @('add','.'));[void](FixtureGit $repo @('commit','-qm','synthetic feature'))
    if($SecondStop){[IO.File]::WriteAllText((Join-Path $repo 'later.txt'),"later feature`n");[void](FixtureGit $repo @('commit','-qam','synthetic later feature'))}
    $commitCount=if($Incident-ceq'7906'){10}else{2}
    $already=if($SecondStop){2}else{1}
    for($commit=$already+1;$commit-le$commitCount;$commit++){
      [IO.File]::WriteAllText((Join-Path $repo "synthetic-pending-$commit.txt"),"Unmistakably synthetic pending native commit $commit of $commitCount`n")
      [void](FixtureGit $repo @('add','.'));[void](FixtureGit $repo @('commit','-qm',"synthetic pending $commit"))
    }
    $original=FixtureGit $repo @('rev-parse','HEAD');[void](FixtureGit $repo @('checkout','-q','main'))
    foreach($change in $shape.changes){$kind,$path=$change.Split("`t",2);if($kind-ceq'U'){[IO.File]::WriteAllText((Join-Path $repo $path),"synthetic landed $path`nunchanged middle`nlanded tail`n")}}
    if($SecondStop){[IO.File]::WriteAllText((Join-Path $repo 'later.txt'),"later landed`n")}
    [void](FixtureGit $repo @('commit','-qam','synthetic landed'));$onto=FixtureGit $repo @('rev-parse','HEAD');[void](FixtureGit $repo @('checkout','-q',$branch))
    [void](FixtureGit $repo @('init','--bare',$remote));[void](FixtureGit $repo @('remote','add','origin',$remote));$pr=[long](996300+[int]$Incident)
    [void](FixtureGit $repo @('push','origin',"HEAD:refs/heads/$branch","HEAD:refs/pull/$pr/head"))
    $o=[ordered]@{schemaVersion='landed-integration-owed/v1';landedPr=[long]996300;landedHead=$onto;pr=$pr;targetHead=$original;newBase=$onto;branch=$branch;worktree=$repo;integrationLane="integration-996300-$pr-$($onto.Substring(0,8))"}
    $request=Get-RebaseHash ([Text.Encoding]::UTF8.GetBytes("landed-integration-start/v1`n$($o.landedPr)`n$($o.landedHead)`n$pr`n$original`n$branch`n$repo`n$($o.integrationLane)"))
    $label="$($o.integrationLane)-seed";$prompt=Join-Path $runtime "$label.prompt.txt";[IO.File]::WriteAllText($prompt,"Integrate PR #$pr after landed PR #$($o.landedPr). Use only '$(Join-Path $runtime 'rebase-integration.ps1')' ReviewedHead $original NewBase $onto.")
    $cfg=[ordered]@{repo=$repo;runtime=$runtime;obligation=$o;module=(Join-Path $PSScriptRoot 'landed-integration-evidence.psm1');helper=(Join-Path $PSScriptRoot 'rebase-integration.ps1');harness=$harness;dispatch=(Join-Path $PSScriptRoot 'dispatch-lane.ps1');prompt=$prompt;label=$label;request=$request;resume=$false;resumePath='';entry=(Join-Path $case 'entry.json');entryOnly=$false;holdDescendant=[bool]$HoldDescendant;holder=$holder;descendantRelease=(Join-Path $case 'descendant.release');descendantReady=(Join-Path $case 'descendant.ready');ownerPid=$PID;ownerStartIdentity=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o');outerCommand=($Incident-ceq'7927')}
    $cfg.helper=Join-Path $runtime 'rebase-integration.ps1'
    if($CurrentRequest){
      [void](FixtureGit $repo @('push','origin','main:refs/heads/main'))
      $request=Get-RebaseHash ([Text.Encoding]::UTF8.GetBytes("landed-integration-start/v2`n$request`n$onto`ncodex/gpt-6.1-sol/high/7/provisional"))
      $cfg.request=$request;$cfg.targetPath=Join-Path $runtime "integration-request-$label.json";$cfg.authorityPath=Join-Path $case 'synthetic-authority.json'
      $repository='synthetic-7963/native-integration'
      Save $cfg.targetPath ([ordered]@{schemaVersion='integration-dispatch-request/v1';requestIdentity=$request;repository=$repository;pr=$pr;landedPr=$o.landedPr;landedHead=$onto;head=$original;newBase=$onto;branch=$branch;worktree=$repo;label=$label;sourceIdentity='ABSENT_REVIEW_REQUIRED';sourceHead='';runtimeRoot=$runtime;historyPath=(Join-Path $runtime 'dispatch-log.jsonl')})
      Save $cfg.authorityPath ([ordered]@{data=@{repository=@{nameWithOwner=$repository;ref=@{name='main';target=@{oid=$onto}};pullRequest=@{number=$pr;state='OPEN';headRefName=$branch;headRefOid=$original;headRepository=@{nameWithOwner=$repository}}}}})
    }
    if($CopiedHelper){
      $copyRoot=Join-Path $case 'synthetic-copied-helper';[IO.Directory]::CreateDirectory($copyRoot)|Out-Null
      foreach($name in @('rebase-integration.ps1','landed-integration-evidence.psm1','dispatch-ownership.ps1')){
        Copy-Item -LiteralPath (Join-Path $runtime $name) -Destination (Join-Path $copyRoot $name)
        if((Get-FileHash (Join-Path $copyRoot $name)).Hash-cne(Get-FileHash (Join-Path $runtime $name)).Hash){throw '7963 copied helper bytes differ'}
      }
      $cfg.helper=Join-Path $copyRoot 'rebase-integration.ps1'
    }
    $config=Join-Path $case 'config.json';Save $config $cfg
    $runControl8076=$control8076.pending-and-not$CopiedHelper-and-not$HoldDescendant
    $control8076.pending=$false
    $holder8076=$null;$hold8076=$null;$seed=$null
    try {
    if($runControl8076){
      # Start before the seed publishes route.ts and childStartIdentity.
      $release8076=Join-Path $case '8076-holder.release';$ready8076=Join-Path $case '8076-holder.ready'
      $arm8076=Join-Path $case '8076-holder.arm';$armed8076=Join-Path $case '8076-holder.armed.json'
      $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=(Join-Path $PSHOME 'pwsh.exe');$psi.UseShellExecute=$true;$psi.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
      $expire8076=Join-Path $case '8076-holder.expire'
      $expireRequest8076=Join-Path $case '8076-holder.expire-request'
      foreach($arg in @('-NoProfile','-NonInteractive','-File',$holder,'-Release',$release8076,'-Ready',$ready8076,'-Arm',$arm8076,'-ArmedReceipt',$armed8076,'-Expire',$expire8076)){[void]$psi.ArgumentList.Add($arg)}
      $holder8076=[Diagnostics.Process]::Start($psi)
      while(-not(Test-Path -LiteralPath $ready8076)-and-not$holder8076.HasExited){[Threading.Thread]::Sleep(20)}
      if(-not(Test-Path -LiteralPath $ready8076)){throw '8076 AC3 NOT_CONSTRUCTIBLE: native holder failed to start'}
      $born8076=Read-RebaseJson $ready8076
      if($born8076.pid-ne$holder8076.Id-or$born8076.startIdentity-cne$holder8076.StartTime.ToUniversalTime().ToString('o')){throw '8076 AC3 NOT_CONSTRUCTIBLE: native holder publication differs'}
      $hold8076=[ordered]@{pid=$born8076.pid;startIdentity=$born8076.startIdentity;readyPath=$ready8076;releasePath=$release8076;expirePath=$expire8076;expireRequestPath=$expireRequest8076;armPath=$arm8076;armedReceiptPath=$armed8076;armStartedAt=$null;armWrittenAt=$null;armedReceipt=$null;preReleaseObservation=$null;releaseAbsent=$false;expiryObserved=$false;releaseStartedAt=$null;releasedAt=$null;releaseMarginSeconds=$null;exitedAt=$null}
    }
    $candidateDispatcher=$cfg.dispatch
    if(-not$CurrentRequest){$cfg.dispatch=$historicalDispatcher;Save $config $cfg}
    try {
      $seed=if($CurrentRequest){Native $runner @('-Config',$config,'-Model','gpt-6.1-sol','-Effort','high','-Placement','provisional')}else{Native $runner @('-Config',$config,'-Model','gpt-5.6-terra','-Route','2','-Placement','measured')} # historical dispatcher fixture only
    } finally {
      $cfg.dispatch=$candidateDispatcher;Save $config $cfg
    }
    $seed|Add-Member -NotePropertyName hold8076 -NotePropertyValue $hold8076
    $seed|Add-Member -NotePropertyName holder8076 -NotePropertyValue $holder8076
    if($seed.exit-ne1){throw "7963 native stopped fixture failed $($seed.resultPath)"}
    $w=Read-RebaseJson (Join-Path $runtime "watchdog-lane-$label.json")
    if($w.exitCode-ne0){throw '7963 stopped fixture did not reproduce nominal child success'}
    if($CurrentRequest-and($w.schemaVersion-cne'watchdog-lane/v3'-or$w.integrationRequest.requestIdentity-cne$request)){throw '7963 current canonical request was not retained'}
    $nativeDir=Join-Path $repo '.git/rebase-merge'
    if([IO.File]::ReadAllText((Join-Path $nativeDir 'msgnum')).Trim()-cne'1'-or[IO.File]::ReadAllText((Join-Path $nativeDir 'end')).Trim()-cne[string]$commitCount){throw '7963 native first-stop remaining history shape mismatch'}
    $stages=(FixtureGit $repo @('ls-files','--unmerged')) -split "`n"
    $expected=@($shape.unmerged|ForEach-Object { ($_ -split ' ',3)[2] })
    if((@($stages|ForEach-Object{($_-split' ',3)[2]})-join"`n")-cne($expected-join"`n")){throw '7963 original native stage-shape mismatch'}
    foreach($stage in $stages){$mode,$oid,$tail=$stage -split ' ',3;$number,$path=$tail.Split("`t",2);$blob=FixtureGit $repo @('cat-file','blob',$oid);$prefix=switch($number){'1'{'synthetic ancestor'};'2'{'synthetic landed'};'3'{'synthetic feature'}};if(-not$blob.StartsWith("$prefix $path")){throw '7963 native stage contents mismatch'}}
    foreach($change in $shape.changes){$kind,$path=$change.Split("`t",2);if($kind-cne'U'){if(-not(FixtureGit $repo @('show',":$path")).StartsWith("synthetic feature $path")){throw '7963 staged nonconflict body mismatch'}}}
    if($CopiedHelper){
      # Deliberately untrusted input, hashed from the actual copied-helper run.
      # No transcript command or native result is rewritten to claim execution.
      $routes=@(Get-Content (Join-Path $runtime 'dispatch-log.jsonl')|ForEach-Object{$_|ConvertFrom-Json -DateKind String}|Where-Object{$_.dispatchRoutingSchema-cin@('watchdog-dispatch-routing/v1','watchdog-dispatch-routing/v2','watchdog-dispatch-routing/v3')-and$_.label-ceq$label})
      if($routes.Count-ne1){throw '7963 copied fixture routing ambiguous'}
      $sourceInput=[ordered]@{requestIdentity=$request;priorLabel=$label;priorLaunchId=$w.launchId;ackSha256=(Get-RebaseHash ([IO.File]::ReadAllBytes((Join-Path $runtime "dispatch-start-$request.json"))));watchdogSha256=(Get-RebaseHash ([IO.File]::ReadAllBytes((Join-Path $runtime "watchdog-lane-$label.json"))));promptSha256=(Get-RebaseHash ([IO.File]::ReadAllBytes($prompt)));transcriptSha256=(Get-RebaseHash ([IO.File]::ReadAllBytes($w.partialReportPath)));routingIdentity=(Get-RebaseRecordIdentity $routes[0]);checkpointSha256=$null}
      $binding=[ordered]@{schemaVersion='interrupted-canonical-integration/v1';obligation=$o;sources=$sourceInput;state=(Get-InterruptedIntegrationState $repo)}
    }elseif($HoldDescendant){
      $module=Get-Module|Where-Object{$_.Path-eq$cfg.module}|Select-Object -First 1
      $sources=& $module {param($o,$r,$l,$id) Get-InterruptedIntegrationSources $o $r $l $id} $o $runtime $label $w.launchId
      $binding=[ordered]@{schemaVersion='interrupted-canonical-integration/v1';obligation=$o;sources=$sources.binding;state=(Get-InterruptedIntegrationState $repo)}
    }else{
      if($runControl8076){
        # Synthetic retained-record rewrite, never a claim about the seed's real PID.
        $w.launcherPid=[long]$hold8076.pid;$w.launcherStartIdentity=$hold8076.startIdentity
        Save (Join-Path $runtime "watchdog-lane-$label.json") $w
      }
      $binding=MeasuredResume8076 $w $seed $o $runtime $label $runControl8076
    }
    } catch {
      if($HoldDescendant){[IO.File]::WriteAllText($cfg.descendantRelease,'release owned descendant on fixture failure')}
      throw
    } finally {
      if($holder8076){
        try {
          if(-not(Test-Path -LiteralPath $release8076)){
            [IO.File]::WriteAllText($release8076,'release owned 8076 holder on fixture exit')
            if($hold8076){$hold8076.cleanupReleasedAt=[datetimeoffset]::UtcNow.ToString('o')}
          }
          $holder8076.WaitForExit()
          $exited8076=$holder8076.HasExited
          $exit8076=if($exited8076){$holder8076.ExitTime.ToUniversalTime().ToString('o')}else{$null}
          if($hold8076){$hold8076.exitedAt=$exit8076}
          if($seed){Save ($seed.resultPath.Replace('.result.json','.holder-exit.json')) ([ordered]@{hold=$hold8076;observedAt=[datetimeoffset]::UtcNow.ToString('o');hasExited=$exited8076;exitedAt=$exit8076})}
          if(-not$exited8076){throw "8076 owned holder still live pid=$($holder8076.Id); release=$release8076"}
        } finally { $holder8076.Dispose() }
      }
    }
    try {
      $resumePath=Join-Path $runtime 'resume-input.json';Save $resumePath $binding
      $cfg.resume=$true;$cfg.resumePath=$resumePath;$cfg.label="$label-resume";$cfg.prompt=Join-Path $runtime "$($cfg.label).prompt.txt";[IO.File]::WriteAllText($cfg.prompt,[IO.File]::ReadAllText($prompt));Save $config $cfg
      [pscustomobject]@{repo=$repo;runtime=$runtime;case=$case;cfg=$cfg;config=$config;binding=$binding;shape=$shape;prior=$w;seed=$seed;original=$original;onto=$onto;branch=$branch;pr=$pr}
    } catch {
      if($HoldDescendant){[IO.File]::WriteAllText($cfg.descendantRelease,'release owned descendant on fixture failure')}
      throw
    }
  }
  function Launch($f,[string[]]$Extra=@(),[switch]$KeepGitEnvironment) { Save $f.config $f.cfg; Native $runner (@('-Config',$f.config)+$Extra) -KeepGitEnvironment:$KeepGitEnvironment }
  function RawState($f) {
    $files=[ordered]@{};$gitDir=Join-Path $f.repo '.git'
    foreach($file in @(Get-ChildItem -LiteralPath $f.repo -Recurse -File -Force|Sort-Object FullName)){
      if($file.FullName.StartsWith($gitDir+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){continue}
      $files[[IO.Path]::GetRelativePath($f.repo,$file.FullName)]=Get-RebaseHash ([IO.File]::ReadAllBytes($file.FullName))
    }
    $metadata=[ordered]@{}
    foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $gitDir 'rebase-merge') -Recurse -File -Force|Sort-Object FullName)){$metadata[$file.Name]=Get-RebaseHash ([IO.File]::ReadAllBytes($file.FullName))}
    Get-RebaseRecordIdentity ([ordered]@{head=(FixtureGit $f.repo @('rev-parse','HEAD'));index=(Get-RebaseHash ([IO.File]::ReadAllBytes((Join-Path $gitDir 'index'))));files=$files;metadata=$metadata})
  }
  $mutants=@{}
  function Mutant([string]$Name,[string]$File,[string]$Needle,[string]$Replacement) {
    if($mutants.ContainsKey($Name)){return $mutants[$Name]}
    if(-not(Test-BatteryProofRelevant @($File))){
      [Console]::Out.WriteLine("SKIPPED 7963 $Carrier mutant=$Name guarded=$File unchanged in impact battery")
      $mutants[$Name]=$null
      return $null
    }
    $dir=Join-Path $root "mutant-$Name";[IO.Directory]::CreateDirectory($dir)|Out-Null
    $sourceRoot=Split-Path -Parent $PSScriptRoot
    $sourcePaths=@(& git.exe -C $sourceRoot ls-files --cached --others --exclude-standard -- .orchestrator)
    if($LASTEXITCODE-ne0){throw '7963 current source inventory failed'}
    foreach($relative in $sourcePaths){
      $destination=Join-Path $dir $relative
      [IO.Directory]::CreateDirectory((Split-Path -Parent $destination))|Out-Null
      Copy-Item -LiteralPath (Join-Path $sourceRoot $relative) -Destination $destination
      if((Get-FileHash $destination).Hash-cne(Get-FileHash (Join-Path $sourceRoot $relative)).Hash){throw '7963 mutant source capture differs'}
    }
    $path=Join-Path $dir ".orchestrator/$File";$text=[IO.File]::ReadAllText($path)
    if([regex]::Matches($text,[regex]::Escape($Needle)).Count-ne1){throw "7963 mutant $Name exact guard count differs"}
    [IO.File]::WriteAllText($path,$text.Replace($Needle,$Replacement),[Text.UTF8Encoding]::new($false))
    [void](FixtureGit $dir @('init','-q','--initial-branch=synthetic/controller'));[void](FixtureGit $dir @('config','user.name','Synthetic guard omission'));[void](FixtureGit $dir @('config','user.email','synthetic-omission@example.invalid'));[void](FixtureGit $dir @('config','commit.gpgsign','false'));[void](FixtureGit $dir @('add','.orchestrator'));[void](FixtureGit $dir @('commit','-qm',"synthetic omitted $Name guard"))
    Save (Join-Path $artifacts "7963-$candidateTag-$Carrier-mutant-$Name.json") ([ordered]@{candidateHead=$candidateHead;name=$Name;file=$File;omitted=$Needle;replacement=$Replacement;mutantHead=(FixtureGit $dir @('rev-parse','HEAD'));mutantPath=$path;candidateSha256=(Get-RebaseHash ([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot $File))));mutantSha256=(Get-RebaseHash ([IO.File]::ReadAllBytes($path)))})
    $mutants[$Name]=Join-Path $dir '.orchestrator/dispatch-lane.ps1'
    return $mutants[$Name]
  }
  function GuardLine([string]$File,[string]$Diagnostic) {
    $lines=@([IO.File]::ReadAllLines((Join-Path $PSScriptRoot $File))|Where-Object{$_.Contains($Diagnostic)})
    if($lines.Count-ne1){throw "7963 unique guard line missing: $Diagnostic"};return $lines[0]
  }
  function RuntimeState($f) {
    Get-RebaseRecordIdentity @(@(Get-ChildItem -LiteralPath $f.runtime -Recurse -File -Force|Sort-Object FullName)|ForEach-Object{[ordered]@{path=[IO.Path]::GetRelativePath($f.runtime,$_.FullName);sha256=(Get-RebaseHash ([IO.File]::ReadAllBytes($_.FullName)))}})
  }
  function ValidPlan($f,[string]$Name,[string[]]$Extra=@('-Dry')) {
    $before=RawState $f;$runtimeBefore=RuntimeState $f
    $result=Launch $f $Extra
    Proof ($result.exit-eq0-and$result.stdout.Contains('"heavyAdmission"')-and-not(Test-Path $f.cfg.entry)-and(RawState $f)-ceq$before-and(RuntimeState $f)-ceq$runtimeBefore) "$Name valid native resume plan=RAN harness=NOTRUN target/runtime=UNCHANGED raw=$($result.resultPath)"
  }
  function Discriminator($f,[string]$Name,[string]$Reason,[string]$MutantPath,[string[]]$Extra=@('-Dry'),[scriptblock]$Observe,[switch]$LoadBound) {
    $before=RawState $f;$runtimeBefore=RuntimeState $f;$candidatePath=$f.cfg.dispatch
    $observations=@()
    if($Observe){$observations+=& $Observe}
    $candidate=Launch $f $Extra
    if($Observe){$observations+=& $Observe}
    Proof ($candidate.exit-ne0-and$candidate.stderr.Contains($Reason)-and-not$candidate.stdout.Contains('"heavyAdmission"')-and-not(Test-Path $f.cfg.entry)-and(RawState $f)-ceq$before-and(RuntimeState $f)-ceq$runtimeBefore) "$Name candidate exit=$($candidate.exit) plan/body=NOTRUN all target/runtime bytes=UNCHANGED raw=$($candidate.resultPath)"
    if([string]::IsNullOrEmpty($MutantPath)){[Console]::Out.WriteLine("SKIPPED 7963 $Carrier $Name omitted-guard arm");return}
    try{
      $f.cfg.dispatch=$MutantPath
      if($Observe){$observations+=& $Observe}
      $loadBefore=if($LoadBound){Get-FleetLoadObservation $fleetContainer}else{$null}
      $bypass=Launch $f $Extra
      $loadAfter=if($LoadBound){Get-FleetLoadObservation $fleetContainer}else{$null}
      if($Observe){$observations+=& $Observe}
    }finally{$f.cfg.dispatch=$candidatePath}
    if($Observe){Save ($bypass.resultPath.Replace('.result.json','.liveness.json')) $observations}
    $pair=[ordered]@{name=$Name;reason=$Reason;candidate=$candidate.resultPath;candidateExit=$candidate.exit;mutant=$bypass.resultPath;mutantExit=$bypass.exit;mutantSource=$MutantPath;targetBefore=$before;targetAfter=(RawState $f);runtimeBefore=$runtimeBefore;runtimeAfter=(RuntimeState $f)}
    $window=$null
    if($LoadBound){$window=Get-FleetLoadWindow $loadBefore $loadAfter;$pair.fleetLoad=$window}
    Save ($bypass.resultPath.Replace('.result.json','.pair.json')) $pair
    if($LoadBound-and$bypass.exit-ne0-and$bypass.stderr.Contains('INTEGRATION_RESUME_PRIOR_OWNER')-and$window.held){
      # #8102: the omitted-guard arm is refused by the prior-owner tree guard when
      # the prior root's teardown outlasts the arm's window. That is MEASURED_LOAD
      # only if the platform slot was held by one live owner across the arm; the
      # same refusal on a vacant fleet remains the discriminator failure below.
      $elapsed=([datetimeoffset]$loadAfter.observedAt-[datetimeoffset]$loadBefore.observedAt).TotalSeconds
      throw "MEASURED_LOAD 7963 $Carrier fleetHolder=$($window.holder) elapsedSeconds=$elapsed discriminator=$Name mutantExit=$($bypass.exit) raw=$($bypass.resultPath)"
    }
    Proof ($bypass.exit-eq0-and$bypass.stdout.Contains('"heavyAdmission"')-and(RawState $f)-ceq$before-and(RuntimeState $f)-ceq$runtimeBefore-and-not(Test-Path -LiteralPath $f.cfg.entry)) "$Name independent omitted guard actual exit=$($bypass.exit) expected=0 plan=RAN harness=NOTRUN all target/runtime bytes=UNCHANGED raw=$($bypass.resultPath)"
  }
  function Race($f,[string]$Dispatch,[bool]$ExpectPlan,[int]$LatencySeconds=0) {
    $path=(@($f.shape.changes|Where-Object{$_-like"M`t*"})[0] -split "`t",2)[1];$full=Join-Path $f.repo $path;$bytes=[IO.File]::ReadAllBytes($full)
    $f.cfg.barrierObserved=Join-Path $f.case "race-$ExpectPlan.observed";$f.cfg.barrierContinue=Join-Path $f.case "race-$ExpectPlan.continue";$f.cfg.latencyMs=$LatencySeconds*1000
    $originalDispatch=$f.cfg.dispatch;$f.cfg.dispatch=$Dispatch;Save $f.config $f.cfg
    $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=(Join-Path $PSHOME 'pwsh.exe');$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    foreach($arg in @('-NoProfile','-NonInteractive','-File',$runner,'-Config',$f.config,'-Dry')){[void]$psi.ArgumentList.Add($arg)}
    $p=[Diagnostics.Process]::Start($psi);$out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync();$start=$p.StartTime.ToUniversalTime().ToString('o');$entry=[Diagnostics.Stopwatch]::StartNew()
    try{
      # The barrier signal or the dispatch child's exit ends this wait, never elapsed time.
      while(-not(Test-Path -LiteralPath $f.cfg.barrierObserved)-and-not$p.HasExited){[Threading.Thread]::Sleep(20)}
      if(-not(Test-Path -LiteralPath $f.cfg.barrierObserved)){$p.WaitForExit();$childError=$err.GetAwaiter().GetResult();throw "7963 actual admission barrier did not enter: dispatch child exited $($p.ExitCode) $($childError.Substring([Math]::Max(0,$childError.Length-600)))"}
      if($LatencySeconds){Proof ($entry.Elapsed.TotalSeconds-gt30) "carrier-latency-injection child delayed ${LatencySeconds}s entered the admission barrier after $([Math]::Round($entry.Elapsed.TotalSeconds,1))s, past the former 30s bound"}
      [IO.File]::AppendAllText($full,"changed after exclusive admission`n");$changed=RawState $f
      [IO.File]::WriteAllText($f.cfg.barrierContinue,'continue owned fixture')
      $p.WaitForExit();$stdout=$out.GetAwaiter().GetResult();$stderr=$err.GetAwaiter().GetResult();$stem=Join-Path $artifacts "7963-$candidateTag-ownership-race-$ExpectPlan"
      [IO.File]::WriteAllText("$stem.stdout.txt",$stdout);[IO.File]::WriteAllText("$stem.stderr.txt",$stderr);Save "$stem.result.json" ([ordered]@{pid=$p.Id;startIdentity=$start;exitCode=$p.ExitCode;hasExited=$p.HasExited;expectedPlan=$ExpectPlan;fixture=$f.case;source=$Dispatch})
      Proof (($ExpectPlan-and$p.ExitCode-eq0-and$stdout.Contains('"heavyAdmission"'))-or(-not$ExpectPlan-and$p.ExitCode-ne0-and$stderr.Contains('INTEGRATION_RESUME_STATE')-and-not$stdout.Contains('"heavyAdmission"'))) "actual admission race expectedPlan=$ExpectPlan exit=$($p.ExitCode) raw=$stem.result.json"
      Proof ((RawState $f)-ceq$changed-and-not(Test-Path -LiteralPath $f.cfg.entry)) 'race preserves the changed index/working/metadata bytes and starts no harness'
    }finally{
      # Released at its barrier, the dry child finishes its plan or refusal and exits.
      if(-not$p.HasExited){[IO.File]::WriteAllText($f.cfg.barrierContinue,'release owned failed control');$p.WaitForExit()}
      $p.Dispose();$f.cfg.dispatch=$originalDispatch;$f.cfg.barrierObserved='';$f.cfg.barrierContinue='';$f.cfg.latencyMs=0;Save $f.config $f.cfg
      # This fixture remains at the raced bytes. No later case borrows its input.
    }
  }
  function Refusal($f,[string]$Name,[string]$Reason,[string[]]$Extra=@('-Dry')) {
    $before=Get-InterruptedIntegrationState $f.repo
    $files=@(Get-ChildItem -LiteralPath $f.runtime -File|Sort-Object Name|ForEach-Object{[ordered]@{name=$_.Name;sha=(Get-RebaseHash ([IO.File]::ReadAllBytes($_.FullName)))}})
    $result=Launch $f $Extra
    $after=Get-InterruptedIntegrationState $f.repo
    $filesAfter=@(Get-ChildItem -LiteralPath $f.runtime -File|Sort-Object Name|ForEach-Object{[ordered]@{name=$_.Name;sha=(Get-RebaseHash ([IO.File]::ReadAllBytes($_.FullName)))}})
    Proof ($result.exit-ne0-and$result.stderr.Contains($Reason)-and-not(Test-Path -LiteralPath $f.cfg.entry)-and(Get-RebaseRecordIdentity $before)-ceq(Get-RebaseRecordIdentity $after)-and(Get-RebaseRecordIdentity $files)-ceq(Get-RebaseRecordIdentity $filesAfter)-and-not$result.stdout.Contains('"heavyAdmission"')) "$Name exit=$($result.exit) body=NOTRUN index/bytes/metadata/runtime=UNCHANGED raw=$($result.resultPath)"
  }
  try {
    if ($Carrier -ceq 'native-branch') {
      $f = Fixture '7927'
      $target = Join-Path $f.case 'ordinary-target'
      [void](FixtureGit $f.repo @('worktree','add','-b','synthetic/unrelated-target',$target,$f.onto))
      [void](FixtureGit $f.repo @('update-ref',"refs/heads/$($f.branch)",$f.onto,$f.original))
      $before = RawState $f
      function ScopeState([string]$Repo) {
        $files=[ordered]@{}
        foreach($relative in @((FixtureGit $Repo @('ls-files','--cached','--others','--exclude-standard')) -split "`n" | Sort-Object -Unique)) {
          $path=Join-Path $Repo $relative
          $files[$relative]=if(Test-Path -LiteralPath $path -PathType Leaf){Get-RebaseHash ([IO.File]::ReadAllBytes($path))}else{'absent'}
        }
        $native=FixtureGit $Repo @('rev-parse','--git-path','rebase-merge')
        if(-not[IO.Path]::IsPathFullyQualified($native)){$native=Join-Path $Repo $native}
        $metadata=[ordered]@{}
        if(Test-Path -LiteralPath $native){foreach($file in @(Get-ChildItem -LiteralPath $native -File -Recurse | Sort-Object FullName)){$metadata[$file.Name]=Get-RebaseHash ([IO.File]::ReadAllBytes($file.FullName))}}
        $index=FixtureGit $Repo @('rev-parse','--git-path','index')
        if(-not[IO.Path]::IsPathFullyQualified($index)){$index=Join-Path $Repo $index}
        Get-RebaseRecordIdentity ([ordered]@{head=(FixtureGit $Repo @('rev-parse','HEAD'));refs=(FixtureGit $Repo @('show-ref'));table=(FixtureGit $Repo @('worktree','list','--porcelain'));index=(Get-RebaseHash ([IO.File]::ReadAllBytes($index)));files=$files;metadata=$(if($metadata.Count){$metadata}else{$null})})
      }
      $targetState=ScopeState $target; $siblingState=ScopeState $f.repo
      $targetBefore = FixtureGit $target @('status','--porcelain=v1','--untracked-files=normal')
      Proof ($targetBefore -ceq '' -and (Get-Content (Join-Path $f.repo '.git/rebase-merge/head-name')) -ceq "refs/heads/$($f.branch)" -and (FixtureGit $f.repo @('rev-parse',"refs/heads/$($f.branch)")) -cne $f.original) '8023 real native different head-name with moved original ref and clean ordinary target'
      $archive = Join-Path $f.case 'old8023.zip'; $old = Join-Path $f.case 'old8023'
      [void](FixtureGit (Split-Path -Parent $PSScriptRoot) @('archive','--format=zip','-o',$archive,'f67fc96aa2b12050408b97dbe023fe6de586ca74','.orchestrator'))
      [IO.Compression.ZipFile]::ExtractToDirectory($archive,$old)
      $body = Join-Path $f.case 'ordinary-body.ps1'
      [IO.File]::WriteAllText($body,@'
param([string]$Config)
$cfg=Get-Content -Raw $Config|ConvertFrom-Json
[void][Console]::In.ReadToEnd()
[IO.File]::AppendAllText($cfg.entry,"body`n")
exit 0
'@)
      $ordinary = $f.cfg | ConvertTo-Json -Depth 15 | ConvertFrom-Json
      $ordinary.repo=$target; $ordinary.resume=$false; $ordinary.resumePath=''; $ordinary.request=''; $ordinary.harness=$body
      $ordinary.entry=Join-Path $f.case 'ordinary-body.txt'
      $ordinaryConfig=Join-Path $f.case 'ordinary-config.json'
      function Ordinary([string]$Dispatch,[string]$Role,[string]$Name) {
        $ordinary.dispatch=$Dispatch; $ordinary.label="synthetic-8023-$Name-$Role"
        $ordinary.runtime=Join-Path $f.case $ordinary.label
        [IO.Directory]::CreateDirectory($ordinary.runtime)|Out-Null
        Save $ordinaryConfig $ordinary
        Native $runner @('-Config',$ordinaryConfig,'-Role',$Role)
      }
      foreach ($role in @('implementation','planning','review')) {
        $oldResult=Ordinary (Join-Path $old '.orchestrator/dispatch-lane.ps1') $role 'old'
        Proof ($oldResult.exit -ne 0 -and $oldResult.stderr.Contains('native original branch moved') -and -not(Test-Path $ordinary.entry) -and @(Get-ChildItem $ordinary.runtime -File).Count -eq 0) "8023 old ordinary $role refuses before body/owner raw=$($oldResult.resultPath)"
      }
      foreach ($role in @('implementation','planning','review')) {
        $result=Ordinary $f.cfg.dispatch $role 'candidate'
        $count=if(Test-Path $ordinary.entry){@(Get-Content $ordinary.entry).Count}else{0}
        $expected=@('implementation','planning','review').IndexOf($role)+1
        Proof ($result.exit -eq 0 -and $count -eq $expected -and (RawState $f) -ceq $before -and (ScopeState $target) -ceq $targetState -and (ScopeState $f.repo) -ceq $siblingState) "8023 candidate ordinary $role launches exactly once body=$count target/sibling refs/index/files/metadata unchanged raw=$($result.resultPath)"
      }
      $omission=Mutant '8023-ordinary-scope' 'dispatch-lane.ps1' 'Get-DispatchRebaseBranch $row.Path -RequestedBranch $requestedBranch' 'Get-DispatchRebaseBranch $row.Path'
      if($omission){
      $result=Ordinary $omission 'planning' 'omitted-scope'
      Proof ($result.exit -ne 0 -and $result.stderr.Contains('native original branch moved') -and @(Get-Content $ordinary.entry).Count -eq 3) "8023 scope omission kills ordinary positive raw=$($result.resultPath)"
      }
      $skip=Mutant '8023-skip-native' 'dispatch-lane.ps1' '$nativeBranch = Get-DispatchRebaseBranch $row.Path -RequestedBranch $requestedBranch' '$nativeBranch = $null # Synthetic unsafe detached bypass'
      $headName=Join-Path $f.repo '.git/rebase-merge/head-name'; $originalName=[IO.File]::ReadAllBytes($headName)
      foreach ($state in @('matching','matching-moved','missing','malformed','unreadable')) {
        $held=$null
        try {
          switch ($state) {
            'matching' { [IO.File]::WriteAllText($headName,"refs/heads/synthetic/unrelated-target`n"); [void](FixtureGit $f.repo @('update-ref','refs/heads/synthetic/unrelated-target',$f.original,$f.onto)); [void](FixtureGit $target @('read-tree','--reset','-u',$f.original)) }
            'matching-moved' { [IO.File]::WriteAllText($headName,"refs/heads/synthetic/unrelated-target`n") }
            'missing' { [IO.File]::Move($headName,"$headName.saved") }
            'malformed' { [IO.File]::WriteAllText($headName,"refs/heads/invalid..branch`n") }
            'unreadable' { $held=[IO.File]::Open($headName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None) }
          }
          $result=Ordinary $f.cfg.dispatch 'planning' $state
          $reason= switch($state){'matching'{'original branch is in native rebase'} 'matching-moved'{'native original branch moved'} 'missing'{'native operation incomplete'} 'malformed'{'native operation malformed'} 'unreadable'{'head-name'}}
          Proof ($result.exit -ne 0 -and $result.stderr.Contains($reason) -and @(Get-Content $ordinary.entry).Count -eq 3 -and @(Get-ChildItem $ordinary.runtime -File).Count -eq 0) "8023 $state candidate refuses body/owner=0 raw=$($result.resultPath)"
          if($skip){
          $bypass=Ordinary $skip 'planning' "bypass-$state"
          Proof ($bypass.exit -eq 0 -and @(Get-Content $ordinary.entry).Count -eq 4) "8023 $state detached-bypass mutant violates refusal raw=$($bypass.resultPath)"
          [IO.File]::WriteAllText($ordinary.entry,"body`nbody`nbody`n")
          }
        } finally {
          if($held){$held.Dispose()}
          if(Test-Path "$headName.saved"){[IO.File]::Move("$headName.saved",$headName)}
          [IO.File]::WriteAllBytes($headName,$originalName)
          if($state -ceq 'matching'){[void](FixtureGit $f.repo @('update-ref','refs/heads/synthetic/unrelated-target',$f.onto,$f.original));[void](FixtureGit $target @('read-tree','--reset','-u',$f.onto))}
        }
      }
      $r=Fixture '7927'
      $sibling=Join-Path $r.case 'stale-sibling'
      [void](FixtureGit $r.repo @('worktree','add','-b','synthetic/stale-sibling',$sibling,$r.original))
      $conflict=@(& git.exe --no-optional-locks -C $sibling rebase main 2>&1)
      Proof ($LASTEXITCODE -eq 1) '8023 interrupted sibling is an actual native conflict'
      [void](FixtureGit $sibling @('update-ref','refs/heads/synthetic/stale-sibling',$r.onto,$r.original))
      $resumeSiblingState=ScopeState $sibling
      ValidPlan $r '8023 unrelated moved native sibling does not poison interrupted vacancy'
      $resumeOmission=Mutant '8023-resume-scope' 'dispatch-lane.ps1' 'Get-DispatchRebaseBranch $canonical -RequestedBranch $integrationResume.obligation.branch' 'Get-DispatchRebaseBranch $canonical'
      if($resumeOmission){
      $candidate=$r.cfg.dispatch; $r.cfg.dispatch=$resumeOmission
      Refusal $r '8023 vacancy scope omission kills interrupted positive' 'native original branch moved'
      $r.cfg.dispatch=$candidate
      }
      $native=FixtureGit $sibling @('rev-parse','--git-path','rebase-merge')
      $siblingName=Join-Path $native 'head-name'; $savedName=[IO.File]::ReadAllBytes($siblingName)
      [IO.File]::WriteAllText($siblingName,"refs/heads/$($r.branch)`n")
      $rivalOmission=Mutant '8023-resume-rival' 'dispatch-lane.ps1' (GuardLine 'dispatch-lane.ps1' 'INTEGRATION_RESUME_OWNER: competing logical branch') '    # Synthetic omission: matching native sibling exclusion.'
      Discriminator $r '8023 matching native sibling is not vacancy' 'INTEGRATION_RESUME_OWNER: competing logical branch' $rivalOmission
      [IO.File]::WriteAllBytes($siblingName,$savedName)
      $unknownOmission=Mutant '8023-resume-unknown' 'dispatch-ownership.ps1' "  if (`$LASTEXITCODE -ne 0) { throw 'dispatch-ownership: native operation malformed' }" '  if ($LASTEXITCODE -ne 0) { return $null } # Synthetic unsafe unknown-as-vacant projection.'
      try {
        [IO.File]::WriteAllText($siblingName,'refs/heads/invalid..branch')
        Discriminator $r '8023 unknown native sibling is not vacancy' 'native operation malformed' $unknownOmission
      } finally { [IO.File]::WriteAllBytes($siblingName,$savedName) }
      $r.cfg.entryOnly=$true
      $resume=Launch $r
      Proof ($resume.exit -eq 0 -and (Test-Path $r.cfg.entry) -and (ScopeState $sibling) -ceq $resumeSiblingState) "8023 real interrupted child admitted with unrelated stale native sibling unchanged raw=$($resume.resultPath)"
      $finished=$true
      return
    }
    $incidents = if($Carrier-ceq'dispatch'){@('7906','7927')}else{@('7927')}
    foreach($incident in $incidents){
      $f=Fixture $incident -SecondStop:($Carrier-ceq'retained') -CurrentRequest:($Carrier-ceq'rebase')
      if($Carrier-ceq'rebase'){
        Write-RebaseRecord (Join-Path $f.runtime "integration-owed-$($f.pr)-$($f.onto.Substring(0,12)).json") $f.binding.obligation
      }
      Write-Output "PROOF 7963 $Carrier shape=$incident actual native stage bodies and every staged nonconflict body verified root=$($f.case)"
      if($Carrier-ceq'dispatch'){
        $baseline=Join-Path $f.case 'baseline';[IO.Directory]::CreateDirectory($baseline)|Out-Null
        # Extract with .NET rather than whichever tar is first on PATH: GNU tar reads a Windows drive prefix as a remote host.
        $archive=Join-Path $f.case 'baseline.zip';[void](FixtureGit (Split-Path -Parent $PSScriptRoot) @('archive','--format=zip','-o',$archive,'0b6e67e87d82d340c496f05a54bff149bda39d4d','.orchestrator'))
        [IO.Compression.ZipFile]::ExtractToDirectory($archive,$baseline)
        if(-not(Test-Path -LiteralPath (Join-Path $baseline '.orchestrator/dispatch-lane.ps1') -PathType Leaf)){throw '7963 immutable baseline extraction failed'}
        $candidate=$f.cfg.dispatch;$input=$f.cfg.resumePath;$f.cfg.dispatch=Join-Path $baseline '.orchestrator/dispatch-lane.ps1';$f.cfg.resumePath=''
        Refusal $f "$incident immutable baseline refuses" 'detached worktrees'
        $f.cfg.dispatch=$candidate;$f.cfg.resumePath=$input
        foreach($role in @('review','planning')){Refusal $f "$incident wrong role $role" 'INTEGRATION_RESUME_ROUTE' @('-Dry','-Role',$role)}
        Refusal $f "$incident Sol off its row-7 slot placement" 'INTEGRATION_RESUME_ROUTE' @('-Dry','-Model','gpt-6.1-sol');ValidPlan $f "$incident current row-7 codex slot codex/gpt-6.1-sol/high/7/provisional admitted" @('-Dry','-Model','gpt-6.1-sol','-Placement','provisional');ValidPlan $f "$incident current row-7 claude slot claude/claude-opus-5-5/xhigh/7/provisional admitted" @('-Dry','-Harness','claude','-Model','claude-opus-5-5','-Effort','xhigh','-Placement','provisional')
        # 8063: beside today's row-7 slots, only the retained Astra tuple and the Todd-ruled Fable 5.1
        # fallback tuple (4388/5743533387) are admitted; every other harness/model/effort/row/role/placement refuses.
        $fable=@('-Dry','-Harness','claude','-Model','claude-fable-5-1')
        ValidPlan $f "$incident 8063 claude/claude-fable-5-1/high/7/override-Todd fallback route admitted" $fable
        foreach($sibling in @('claude-sonnet-5-5','claude-opus-5-5')){Refusal $f "$incident 8063 claude sibling $sibling at the Fable high/override-Todd tuple refused" 'INTEGRATION_RESUME_ROUTE' @('-Dry','-Harness','claude','-Model',$sibling)}
        Refusal $f "$incident 8063 Fable wrong effort" 'INTEGRATION_RESUME_ROUTE' ($fable+@('-Effort','medium'))
        Refusal $f "$incident 8063 Fable wrong row" 'INTEGRATION_RESUME_ROUTE' ($fable+@('-Route','14'))
        foreach($role in @('review','planning')){Refusal $f "$incident 8063 Fable wrong role $role" 'INTEGRATION_RESUME_ROUTE' ($fable+@('-Role',$role))}
        foreach($placement in @('measured','provisional','override-todd')){Refusal $f "$incident 8063 Fable wrong placement $placement" 'INTEGRATION_RESUME_ROUTE' ($fable+@('-Placement',$placement))}
        Refusal $f "$incident 8063 Fable on codex harness" 'MODEL_HARNESS_MISMATCH' @('-Dry','-Harness','codex','-Model','claude-fable-5-1')
        Refusal $f "$incident 8063 Astra on claude harness" 'MODEL_HARNESS_MISMATCH' @('-Dry','-Harness','claude','-Model','gpt-6-astra')
        foreach($section in @('obligation','sources','state')){
          $bad=$f.binding|ConvertTo-Json -Depth 15|ConvertFrom-Json -DateKind String;$bad.$section|Add-Member -NotePropertyName unknownAuthority -NotePropertyValue $true;Save $f.cfg.resumePath $bad
          Refusal $f "$incident closed nested $section" 'INTEGRATION_RESUME_BINDING'
        }
        $duplicate=($f.binding|ConvertTo-Json -Depth 15 -Compress).Replace('"dirtySha256":','"dirtySha256":"'+('a'*64)+'","dirtySha256":')
        [IO.File]::WriteAllText($f.cfg.resumePath,$duplicate)
        Refusal $f "$incident duplicate nested member" 'duplicate key'
        Save $f.cfg.resumePath $f.binding
        foreach($field in @('metadataSha256','indexSha256','stagesSha256','dirtySha256','stagedSha256','unstagedSha256','stoppedHead','onto')){
          $bad=$f.binding|ConvertTo-Json -Depth 15|ConvertFrom-Json -DateKind String;$bad.state.$field=$(if($field.EndsWith('Sha256')){'a'*64}else{'a'*40});Save $f.cfg.resumePath $bad
          Refusal $f "$incident independent $field" 'INTEGRATION_RESUME_'
        }
        Save $f.cfg.resumePath $f.binding
        $stateMutant=Mutant 'fingerprint' 'landed-integration-evidence.psm1' (GuardLine 'landed-integration-evidence.psm1' 'INTEGRATION_RESUME_STATE: stale or unrelated bytes') '  # Synthetic omission: exact current input fingerprint comparison.'
        foreach($field in @('indexSha256','dirtySha256','metadataSha256','stagesSha256','stagedSha256','unstagedSha256','stoppedCommit','stoppedHead','oldBase')){
          $bad=$f.binding|ConvertTo-Json -Depth 15|ConvertFrom-Json -DateKind String;$bad.state.$field=$(if($field-in@('stoppedCommit','stoppedHead','oldBase')){'b'*40}else{'b'*64});Save $f.cfg.resumePath $bad
          Discriminator $f "$incident $field binding" 'INTEGRATION_RESUME_STATE' $stateMutant
        }
        Save $f.cfg.resumePath $f.binding
        $routeMutant=Mutant 'route' 'dispatch-lane.ps1' "    throw 'INTEGRATION_RESUME_ROUTE: exact eligible implementation route required'" '    # Synthetic omission: exact role/route guard.'
        Discriminator $f "$incident implementation role" 'INTEGRATION_RESUME_ROUTE' $routeMutant @('-Dry','-Role','planning')
        Discriminator $f "$incident Sol off its row-7 slot placement" 'INTEGRATION_RESUME_ROUTE' $routeMutant @('-Dry','-Model','gpt-6.1-sol')
        Discriminator $f "$incident 8063 claude sibling model on the fallback route" 'INTEGRATION_RESUME_ROUTE' $routeMutant @('-Dry','-Harness','claude','-Model','claude-sonnet-5-5')
        Discriminator $f "$incident 8063 Fable fallback route effort" 'INTEGRATION_RESUME_ROUTE' $routeMutant ($fable+@('-Effort','medium'))
        $sourceMutant=Mutant 'source-binding' 'landed-integration-evidence.psm1' (GuardLine 'landed-integration-evidence.psm1' 'INTEGRATION_RESUME_SOURCE: changed binding') '  # Synthetic omission: source bytes comparison.'
        $bad=$f.binding|ConvertTo-Json -Depth 15|ConvertFrom-Json -DateKind String;$bad.sources.ackSha256='b'*64;Save $f.cfg.resumePath $bad
        Discriminator $f "$incident exact source bytes" 'INTEGRATION_RESUME_SOURCE' $sourceMutant
        Save $f.cfg.resumePath $f.binding
        $remoteMutant=Mutant 'remote' 'landed-integration-evidence.psm1' (GuardLine 'landed-integration-evidence.psm1' 'INTEGRATION_RESUME_REMOTE: original branch/PR changed') '    # Synthetic omission: original remote equality.'
        $older=FixtureGit $f.repo @('rev-parse',"$($f.original)^")
        [void](FixtureGit (Join-Path $f.case 'remote.git') @('update-ref',"refs/pull/$($f.pr)/head",$older))
        try{Discriminator $f "$incident exact PR head" 'INTEGRATION_RESUME_REMOTE' $remoteMutant}finally{[void](FixtureGit (Join-Path $f.case 'remote.git') @('update-ref',"refs/pull/$($f.pr)/head",$f.original))}
        [void](FixtureGit (Join-Path $f.case 'remote.git') @('update-ref',"refs/heads/$($f.branch)",$older))
        try{Discriminator $f "$incident exact remote branch" 'INTEGRATION_RESUME_REMOTE' $remoteMutant}finally{[void](FixtureGit (Join-Path $f.case 'remote.git') @('update-ref',"refs/heads/$($f.branch)",$f.original))}
        $localMutant=Mutant 'local-original' 'dispatch-ownership.ps1' "    throw 'dispatch-ownership: native original branch moved'" '    # Synthetic omission: native original ref equality.'
        # Ref movement leaves native reflog evidence. Keep it out of the later
        # completion fixture rather than repairing or weakening that evidence.
        $localMoved=Fixture $incident
        $localOlder=FixtureGit $localMoved.repo @('rev-parse',"$($localMoved.original)^")
        [void](FixtureGit $localMoved.repo @('update-ref',"refs/heads/$($localMoved.branch)",$localOlder))
        Discriminator $localMoved "$incident exact local original" 'native original branch moved' $localMutant
        $replayMutant=Mutant 'native-proof' 'landed-integration-evidence.psm1' '    Assert-InterruptedIntegrationReplay $o $state # RESUME_GUARD_NATIVE_REPLAY' '    # Synthetic omission: independent native replay.'
        # Mutating an index or a working file changes native stat state too.
        # Give destructive controls their own stopped repo; never repair one
        # fixture by restoring an index and then borrow its old authority.
        $staged=Fixture $incident
        $path=(@($staged.shape.changes|Where-Object{$_-like"M`t*"})[0] -split "`t",2)[1];$full=Join-Path $staged.repo $path
        [IO.File]::AppendAllText($full,"unrelated staged mutation`n");[void](FixtureGit $staged.repo @('add','--',$path))
        $bad=$staged.binding|ConvertTo-Json -Depth 15|ConvertFrom-Json -DateKind String;$bad.state=Get-InterruptedIntegrationState $staged.repo;Save $staged.cfg.resumePath $bad
        Discriminator $staged "$incident staged nonconflict bytes cannot become capture authority" 'INTEGRATION_RESUME_NATIVE_PROOF' $replayMutant
        $commandMutant=Mutant 'canonical-command' 'landed-integration-evidence.psm1' (GuardLine 'landed-integration-evidence.psm1' '$elements[$fileIndex] -isnot') '  if ($elements[$fileIndex] -isnot [Management.Automation.Language.StringConstantExpressionAst]) { return $null } # Synthetic omission: canonical helper path equality only.'
        $copied=Fixture $incident -CopiedHelper
        Discriminator $copied "$incident copied command proof cannot claim the canonical helper" 'INTEGRATION_RESUME_SOURCE: canonical helper conflict absent or ambiguous' $commandMutant
        ValidPlan $f "$incident original fixture after independent destructive controls"
        foreach($nativePart in @('message','git-rebase-todo.backup')){
          $nativePath=Join-Path $f.repo ".git/rebase-merge/$nativePart";$originalNative=[IO.File]::ReadAllBytes($nativePath)
          try{
            [IO.File]::AppendAllText($nativePath,"`n# unrelated native metadata mutation`n")
            $bad=$f.binding|ConvertTo-Json -Depth 15|ConvertFrom-Json -DateKind String;$bad.state=Get-InterruptedIntegrationState $f.repo;Save $f.cfg.resumePath $bad
            Discriminator $f "$incident native $nativePart is authenticated independently of capture" 'INTEGRATION_RESUME_NATIVE_PROOF' $replayMutant
          }finally{[IO.File]::WriteAllBytes($nativePath,$originalNative);Save $f.cfg.resumePath $f.binding}
        }
        $donePath=Join-Path $f.repo '.git/rebase-merge/done';$doneBytes=[IO.File]::ReadAllBytes($donePath);$before=RawState $f
        try{
          [IO.File]::AppendAllText($donePath,[Text.Encoding]::UTF8.GetString($doneBytes));$altered=RawState $f
          $wrongDone=Launch $f @('-Dry')
          Proof ($wrongDone.exit-ne0-and$wrongDone.stderr.Contains('INTEGRATION_RESUME_OPERATION')-and-not$wrongDone.stdout.Contains('"heavyAdmission"')-and(RawState $f)-ceq$altered) "$incident actual native done history mutation refuses before plan and preserves mutated bytes raw=$($wrongDone.resultPath)"
        }finally{[IO.File]::WriteAllBytes($donePath,$doneBytes)}
        Proof ((RawState $f)-ceq$before) "$incident owned native done control restored exactly"
      }
      if($Carrier-ceq'ownership'){
        $raceCandidate=Fixture $incident
        # carrier-latency-injection (#9619 AC4): the candidate child starts 31 s late.
        Race $raceCandidate $f.cfg.dispatch $false 31
        $raceMutant=Mutant 'admission-reread' 'dispatch-lane.ps1' '  [void](Assert-InterruptedIntegrationResume $integrationResume $runtimeRoot) # RESUME_GUARD_UNDER_ADMISSION' '  # Synthetic omission: revalidation under exclusive admission.'
        if($raceMutant){
        $raceBypass=Fixture $incident
        Race $raceBypass $raceMutant $true
        }
        ValidPlan $f 'unavailable OS inventory positive prerequisite'
        $deathMutant=Mutant 'prior-tree-death' 'landed-integration-evidence.psm1' 'function Assert-InterruptedIntegrationTreeDead($Owner) {' "function Assert-InterruptedIntegrationTreeDead(`$Owner) {`n  return # Synthetic omission: actual prior tree death."
        Discriminator $f 'actual unavailable OS inventory is not proof of death' 'Get-CimInstance' $deathMutant @('-Dry','-NoCim')
        $wpath=Join-Path $f.runtime "watchdog-lane-$($f.prior.label).json";$originalBytes=[IO.File]::ReadAllBytes($wpath)
        $bad=Read-RebaseJson $wpath;$bad.launcherPid=[long]$PID;$bad.launcherStartIdentity=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o');Save $wpath $bad
        Refusal $f 'altered prior OS identity source' 'INTEGRATION_RESUME_SOURCE'
        [IO.File]::WriteAllBytes($wpath,$originalBytes)
        $misbound=Read-RebaseJson $wpath;$misbound.launcherPid=[long]$PID;Save $wpath $misbound
        $misboundInput=$f.binding|ConvertTo-Json -Depth 15|ConvertFrom-Json -DateKind String;$misboundInput.sources.watchdogSha256=Get-RebaseHash ([IO.File]::ReadAllBytes($wpath));Save $f.cfg.resumePath $misboundInput
        try{
          $actualStart=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
          Proof ($actualStart-cne$misbound.launcherStartIdentity) 'tampered retained PID names a real differently-born process; no kernel PID-recycling fact is claimed'
          # #8103: a retained PID held by a differently-born process is a reused PID and is dead; only the exact recorded identity is a live root.
          ValidPlan $f 'reused retained PID is dead by identity'
          $live=Read-RebaseJson $wpath;$live.launcherStartIdentity=$actualStart;Save $wpath $live
          $liveInput=$f.binding|ConvertTo-Json -Depth 15|ConvertFrom-Json -DateKind String;$liveInput.sources.watchdogSha256=Get-RebaseHash ([IO.File]::ReadAllBytes($wpath));Save $f.cfg.resumePath $liveInput
          Discriminator $f 'exact-identity live retained root is not death' 'INTEGRATION_RESUME_PRIOR_OWNER: live root' $deathMutant
        }finally{[IO.File]::WriteAllBytes($wpath,$originalBytes);Save $f.cfg.resumePath $f.binding}
        $logical=Get-DispatchRebaseBranch $f.repo
        Proof ($logical-ceq$f.branch-and(FixtureGit $f.repo @('branch','--show-current'))-ceq'') 'native logical branch remains truthful while detached'
        $projection=Fixture $incident
        [void](FixtureGit $projection.repo @('update-ref',"refs/heads/$($projection.branch)",$projection.onto,$projection.original))
        $failure=$null
        try { Get-DispatchRebaseBranch $projection.repo | Out-Null } catch { $failure=$_.Exception.Message }
        Proof ($failure -ceq 'dispatch-ownership: native original branch moved') '8023 unscoped ownership projection still refuses moved original tip'
        Proof ((Get-DispatchRebaseBranch $projection.repo -RequestedBranch 'synthetic/known-other') -ceq $projection.branch) '8023 scoped projection identifies only the unrelated logical branch, not vacancy'
        $failure=$null
        try { Get-DispatchRebaseBranch $projection.repo -RequestedBranch $projection.branch | Out-Null } catch { $failure=$_.Exception.Message }
        Proof ($failure -ceq 'dispatch-ownership: native original branch moved') '8023 matching branch retains original tip guard'
        $rivalMutant=Mutant 'live-rival' 'dispatch-lane.ps1' (GuardLine 'dispatch-lane.ps1' 'INTEGRATION_RESUME_OWNER: rival owner') '    # Synthetic omission: live rival exclusion.'
        # The actual foreground carrier is the synthetic rival. It cannot expire
        # between the candidate and mutant. The separate holder's expiry signal,
        # all production guards and every invocation bound remain unchanged.
        $rival=Get-Process -Id $PID
        $id=[guid]::NewGuid().ToString();$recordPath=Join-Path $f.runtime "dispatch-launch-$id.json";$label="synthetic-rival-$id"
        $record=[ordered]@{schemaVersion=4;launchId=$id;laneRole='implementation';promptPath=(Join-Path $f.runtime "dispatch-heavy-verifier-$id.prompt.txt");reviewIsolationRoot=$null;launcherPid=$PID;launcherStartIdentity=$rival.StartTime.ToUniversalTime().ToString('o');recordedAt=[datetime]::UtcNow.ToString('o');state='launching';childPid=$null;childStartIdentity=$null;worktree=$f.repo;lane='lane';identityMode='branch';branch=$f.branch;head=$f.binding.state.stoppedHead;label=$label;transcriptPath=(Join-Path $f.runtime "$label.jsonl")}
        try {
          [IO.File]::WriteAllText($record.promptPath,'Unmistakably synthetic live claimant');[IO.File]::WriteAllText($record.transcriptPath,"{`"type`":`"item.completed`"}`n");Write-DispatchOwnershipRecord $recordPath $record -CreateNew
          $observeRival={
            $current=Get-ValidatedDispatchOwnershipRecord $recordPath $f.runtime ([IO.Path]::GetTempPath())
            $state=Get-DispatchProcessIdentityState $record.launcherPid $record.launcherStartIdentity
            $census=Get-LiveDispatchOwnership -RuntimeRoot $f.runtime -TempRoot ([IO.Path]::GetTempPath()) -ContainerRoot $f.case
            if($state-cne'live'-or-not(Test-DispatchOwnershipRecordExact $current $record)-or$census.health.status-cne'ok'-or
              $census.health.counts.candidates-ne$census.health.counts.examined-or$census.health.counts.truncated-ne0-or
              @($census.activeLanes|Where-Object{$_.launchId-ceq$id-and$_.branch-ceq$f.branch}).Count-ne1){throw '7963 native rival lost exact live publication'}
            [ordered]@{observedAt=[datetimeoffset]::UtcNow.ToString('o');pid=$record.launcherPid;startIdentity=$record.launcherStartIdentity;state=$state;recordSha256=(Get-RebaseHash ([IO.File]::ReadAllBytes($recordPath)));census=$census}
          }
          Discriminator $f 'actual live rival denies admission' 'INTEGRATION_RESUME_OWNER: rival owner' $rivalMutant -Observe $observeRival
        } finally {
          if(-not(Remove-DispatchLaunchResources $recordPath $record $f.runtime ([IO.Path]::GetTempPath()))){throw '7963 exact owned rival cleanup refused'}
          Remove-Item -LiteralPath $record.transcriptPath -Force
          $rival.Dispose()
        }
        $orphanFixture=Fixture '7927' -HoldDescendant
        try {
          $born=Read-RebaseJson $orphanFixture.cfg.descendantReady
          $orphan=Get-Process -Id $born.pid -ErrorAction Stop;[void]$orphan.Handle # pin this holder; its PID cannot be reused under the wait
        try {
          Proof ($orphan.StartTime.ToUniversalTime().ToString('o')-ceq$born.startIdentity) 'possible descendant uses actual OS creation identity'
          $nativeChild=@(Get-CimInstance Win32_Process -Filter "ProcessId = $($born.pid)" -ErrorAction Stop)
          Proof ($nativeChild.Count-eq1-and$nativeChild[0].ParentProcessId-eq$orphanFixture.prior.childPid) 'surviving descendant has the actual prior child as its native parent'
          Discriminator $orphanFixture 'actual surviving descendant denies prior-tree death' 'INTEGRATION_RESUME_PRIOR_OWNER' $deathMutant
          Proof (-not$orphan.HasExited) 'possible-child discriminator executed while the child survived'
        } finally {
          [IO.File]::WriteAllText($orphanFixture.cfg.descendantRelease,'release owned descendant')
          # The holder polls its release every 100 ms and exits 0; wait on that exit.
          $orphan.WaitForExit()
          if($orphan.ExitCode-ne0){throw "7963 owned descendant did not finish its release: exited $($orphan.ExitCode)"}
          Save (Join-Path $artifacts "7963-$candidateTag-ownership-descendant-process.json") ([ordered]@{pid=$born.pid;startIdentity=$born.startIdentity;exitCode=$orphan.ExitCode;hasExited=$orphan.HasExited;priorChildPid=$orphanFixture.prior.childPid;fixture=$orphanFixture.case})
          $orphan.Dispose()
        }
        } finally {
          [IO.File]::WriteAllText($orphanFixture.cfg.descendantRelease,'release owned descendant')
        }
      }
      $entryState=Get-InterruptedIntegrationState $f.repo
      if($Carrier-ceq'watchdog'){$f.cfg.entryOnly=$true}
      $run=Launch $f
      Proof ($run.exit-in@(0,2)-and(Test-Path -LiteralPath $f.cfg.entry)) "$incident candidate actual child entry exit=$($run.exit) raw=$($run.resultPath)"
      $gitEnvironmentNames=@('GIT_DIR','GIT_WORK_TREE','GIT_INDEX_FILE','GIT_OBJECT_DIRECTORY','GIT_ALTERNATE_OBJECT_DIRECTORIES')
      Proof (@($gitEnvironmentNames|Where-Object{-not[string]::IsNullOrEmpty([string]$run.gitEnvironment[$_])}).Count-eq0) "$incident resume child launch strips redirected Git environment"
      $entryBefore=if(Test-Path -LiteralPath $f.cfg.entry){Get-RebaseHash ([IO.File]::ReadAllBytes($f.cfg.entry))}else{$null}
      $guardControl=Launch $f @('-Dry') -KeepGitEnvironment
      $entryAfter=if(Test-Path -LiteralPath $f.cfg.entry){Get-RebaseHash ([IO.File]::ReadAllBytes($f.cfg.entry))}else{$null}
      Proof ($guardControl.exit-ne0-and$guardControl.stderr.Contains('INTEGRATION_RESUME_GIT_UNKNOWN: redirected GIT_ALTERNATE_OBJECT_DIRECTORIES')-and-not$guardControl.stdout.Contains('"heavyAdmission"')-and$entryAfter-ceq$entryBefore) "$incident redirected alternate object directory remains refused raw=$($guardControl.resultPath)"
      $entry=Read-RebaseJson $f.cfg.entry
      Proof ((Get-RebaseRecordIdentity $entry)-ceq(Get-RebaseRecordIdentity $entryState)) "$incident complete raw index/stages/staged/unstaged/metadata entry equality"
      $watchdog=Read-RebaseJson (Join-Path $f.runtime "watchdog-lane-$($f.cfg.label).json")
      Proof ($watchdog.schemaVersion-ceq'watchdog-lane/v4'-and$watchdog.interruptedIntegration-ceq($f.binding|ConvertTo-Json -Depth 12 -Compress)) 'closed binding retained through watchdog exit'
      if($Carrier-ceq'watchdog'){
        Proof ($run.exit-eq0-and$watchdog.exitCode-eq0-and-not(FixtureGit $f.repo @('branch','--show-current'))) 'actual nominal-zero resumed child leaves native conflict, not completion'
        $oldEnvironment=$env:SYNTHETIC_7963_WATCHDOG_CONFIG
        try{
          $env:SYNTHETIC_7963_WATCHDOG_CONFIG=$f.config
          $retry=Native (Join-Path $PSScriptRoot 'lane-stall-watchdog.ps1') @('-Label',$f.cfg.label,'-RuntimeRoot',$f.runtime,'-HistoryPath',(Join-Path $f.runtime 'dispatch-log.jsonl'),'-DispatchScript',$watchdogBridge,'-SynchronousDispatch')
          Proof ($retry.exit-eq0-and$retry.stdout.Contains('"status":"RELAUNCHED"')-and$retry.stdout.Contains('"implementationAttemptIncrement":0')) "actual native watchdog relaunches only through bound canonical dispatcher raw=$($retry.resultPath)"
          $f.cfg=Read-RebaseJson $f.config;$f.binding=Read-RebaseJson $f.cfg.resumePath
          $nextWatch=Read-RebaseJson (Join-Path $f.runtime "watchdog-lane-$($f.cfg.label).json")
          Proof ($nextWatch.relaunchCount-eq1-and$nextWatch.resumeOfLaunchId-ceq$watchdog.launchId-and$nextWatch.interruptedIntegration-ceq($f.binding|ConvertTo-Json -Depth 12 -Compress)) 'actual replacement start/watchdog retains exact original logical branch and fresh binding'
        }finally{$env:SYNTHETIC_7963_WATCHDOG_CONFIG=$oldEnvironment}
      }
      if($Carrier-ceq'retained'){
        Proof ($run.exit-eq2-and-not(FixtureGit $f.repo @('branch','--show-current'))) 'next genuine native conflict remains detached'
        Remove-Item -LiteralPath $f.cfg.entry -Force
        $f.cfg.label+='-stale';$oldPrompt=$f.cfg.prompt;$f.cfg.prompt=Join-Path $f.runtime "$($f.cfg.label).prompt.txt";[IO.File]::WriteAllText($f.cfg.prompt,[IO.File]::ReadAllText($oldPrompt))
        Refusal $f 'stale original snapshot after next conflict' 'INTEGRATION_RESUME_STATE'
        $next=New-InterruptedIntegrationResume $f.binding.obligation $f.runtime $watchdog.label $watchdog.launchId
        $f.cfg.label+='-fresh';$oldPrompt=$f.cfg.prompt;$f.cfg.prompt=Join-Path $f.runtime "$($f.cfg.label).prompt.txt";[IO.File]::WriteAllText($f.cfg.prompt,[IO.File]::ReadAllText($oldPrompt))
        Save $f.cfg.resumePath $next
        $checkpointPath=Join-Path $f.runtime "integration-resume-stop-$($watchdog.launchId).json"
        $checkpointBytes=[IO.File]::ReadAllBytes($checkpointPath);$checkpoint=Read-RebaseJson $checkpointPath
        Proof ([IO.File]::ReadAllText((Join-Path $f.repo '.git/rebase-merge/msgnum')).Trim()-ceq'2'-and[IO.File]::ReadAllText((Join-Path $f.repo '.git/rebase-merge/end')).Trim()-ceq'2'-and$next.sources.checkpointSha256-ceq(Get-RebaseHash $checkpointBytes)-and(Get-RebaseRecordIdentity $next.state)-ceq(Get-RebaseRecordIdentity $checkpoint.state)) 'actual 2/2 native stop and complete checkpoint identity bind fresh retry'
        ValidPlan $f 'fresh native checkpoint with ordered obligation'
        foreach($mutation in @('missing-state-member','extra-state-member','wrong-binding','wrong-launch','before-child')){
          $badCheckpoint=Read-RebaseJson $checkpointPath
          switch($mutation){
            'missing-state-member'{$badCheckpoint.state.PSObject.Properties.Remove('indexSha256');$reason='INTEGRATION_RESUME_SOURCE: closed checkpoint state'}
            'extra-state-member'{$badCheckpoint.state|Add-Member -NotePropertyName syntheticExtra -NotePropertyValue $true;$reason='INTEGRATION_RESUME_SOURCE: closed checkpoint state'}
            'wrong-binding'{$badCheckpoint.bindingIdentity='a'*64;$reason='INTEGRATION_RESUME_SOURCE: retained stop causality'}
            'wrong-launch'{$badCheckpoint.launchId=[guid]::NewGuid().ToString();$reason='INTEGRATION_RESUME_SOURCE: retained stop causality'}
            'before-child'{$badCheckpoint.capturedAt=([datetimeoffset]$watchdog.childStartIdentity).AddSeconds(-1).ToString('o');$reason='INTEGRATION_RESUME_SOURCE: retained stop causality'}
          }
          try{Save $checkpointPath $badCheckpoint;Refusal $f "retained checkpoint $mutation" $reason}finally{[IO.File]::WriteAllBytes($checkpointPath,$checkpointBytes)}
        }
        try{
          $duplicateCheckpoint=[Text.Encoding]::UTF8.GetString($checkpointBytes).Replace('"indexSha256":','"indexSha256":"'+('a'*64)+'","indexSha256":')
          [IO.File]::WriteAllText($checkpointPath,$duplicateCheckpoint)
          Refusal $f 'retained checkpoint duplicate nested key' 'duplicate key'
        }finally{[IO.File]::WriteAllBytes($checkpointPath,$checkpointBytes)}
        $badNext=$next|ConvertTo-Json -Depth 15|ConvertFrom-Json -DateKind String;$badNext.state.indexSha256='b'*64;Save $f.cfg.resumePath $badNext
        $retryMutant=Mutant 'retained-fingerprint' 'landed-integration-evidence.psm1' (GuardLine 'landed-integration-evidence.psm1' 'INTEGRATION_RESUME_STATE: stale or unrelated bytes') '  # Synthetic omission: retained current state fingerprint.'
        Discriminator $f 'retained retry binds its current full index' 'INTEGRATION_RESUME_STATE' $retryMutant -LoadBound
        $f.binding=$next;Save $f.cfg.resumePath $next;$f.cfg.label+='-next';$f.cfg.prompt=Join-Path $f.runtime "$($f.cfg.label).prompt.txt";[IO.File]::WriteAllText($f.cfg.prompt,"Integrate PR #$($f.pr) after PR #996300. rebase-integration.ps1 $($f.original) $($f.onto)")
        $nextRun=Launch $f
        Proof ($nextRun.exit-eq0) "fresh native next-stop admission completes raw=$($nextRun.resultPath)"
        $nextEntry=Read-RebaseJson $f.cfg.entry
        $nextWatchdog=Read-RebaseJson (Join-Path $f.runtime "watchdog-lane-$($f.cfg.label).json")
        # The dispatcher names its acknowledgement from the identity of the parsed resume bytes. Hash the saved bytes the same way:
        # the in-memory fixture obligation carries cmdlet-wrapped path strings that ConvertTo-RebaseCanonical does not treat as strings.
        $nextRequest=Get-RebaseRecordIdentity (Read-RebaseJson $f.cfg.resumePath)
        $nextAck=Read-RebaseJson (Join-Path $f.runtime "dispatch-start-$nextRequest.json")
        Proof ((Get-RebaseRecordIdentity $nextEntry)-ceq(Get-RebaseRecordIdentity $next.state)-and$nextAck.requestIdentity-ceq$nextRequest-and$nextAck.launchId-ceq$nextWatchdog.launchId-and$nextAck.childPid-eq$nextWatchdog.childPid-and$nextAck.childStartIdentity-ceq$nextWatchdog.childStartIdentity-and$nextAck.interruptedIntegration-ceq($next|ConvertTo-Json -Depth 12 -Compress)-and$nextWatchdog.resumeOfLaunchId-ceq$watchdog.launchId) 'fresh 2/2 retry entry bytes and one acknowledged actual owner are exact'
      }
      $completion=Read-RebaseCompletion $f.binding.obligation $f.runtime
      Proof ($null-ne$completion-and$completion.schemaVersion-ceq'landed-integration-rebase-complete/v2'-and$completion.predecessorHead-ceq$f.original-and(FixtureGit $f.repo @('status','--porcelain=v1','--untracked-files=normal'))-ceq''-and(FixtureGit $f.repo @('branch','--show-current'))-ceq$f.branch) 'clean attached original-lease publication passes existing native completion checks'
      $dayAfter=Read-RebaseCompletion $f.binding.obligation $f.runtime -Replay
      Proof ($dayAfter.resultHead-ceq$completion.resultHead-and-not([IO.File]::ReadAllText((Join-Path $f.runtime 'dispatch-log.jsonl')).Contains('rebase-only-continuation/v1'))) 'day-after replay emits no PASS or continuation'
      if($Carrier-ceq'rebase'){
        $o=$f.binding.obligation
        $ack=Read-RebaseJson (Join-Path $f.runtime "integration-owed-ack-v3-$($o.landedPr)-$($o.landedHead)-$($o.pr)-$(Get-RebaseObligationIdentity $o).json")
        Proof ($ack.schemaVersion-ceq'landed-integration-owed-ack/v3'-and$ack.resultHead-ceq$completion.resultHead-and$ack.completionIdentity-ceq(Get-RebaseRecordIdentity $completion)) 'current automatic request completes owed integration with exact ack/v3 identity'
      }
      if($Carrier-ceq'watchdog'){
        $watch=Native (Join-Path $PSScriptRoot 'lane-stall-watchdog.ps1') @('-Label',$f.cfg.label,'-RuntimeRoot',$f.runtime,'-HistoryPath',(Join-Path $f.runtime 'dispatch-log.jsonl'))
        Proof ($watch.exit-eq0-and$watch.stdout.Contains('TERMINAL_SUCCESS')-and$watch.stdout.Contains('"relaunch":false')) "actual retained watchdog validates native completion without launch raw=$($watch.resultPath)"
      }
    }
    $finished=$true
  } catch {
    # Fixture diagnostics only: name the failing statement before the retained-root notice.
    Write-Output "EXCEPTION 7963 $Carrier $($_.Exception.Message) STACK $($_.ScriptStackTrace -replace "`r?`n",' | ')"
    throw
  } finally {
    Write-Output "RETAINED 7963 $Carrier native objects, stage bodies, entry snapshots and source evidence: $root; finished=$finished"
  }
}

# #8102: carriers run in order; a fixture that classified a missed bound as
# MEASURED_LOAD ends the test process with exit 75 and one standalone
# MEASURED_LOAD line (holder identity and elapsed time), never PASS or FAIL.
# Every other failure propagates unchanged (exit 1).
function Invoke-7963ResumeCarriers([string[]]$Carriers) {
  foreach ($carrier in $Carriers) {
    try { Test-7963ResumeCarrier $carrier }
    catch {
      if ($_.Exception.Message -clike 'MEASURED_LOAD *') { Write-Output $_.Exception.Message; exit 75 }
      throw
    }
  }
}

# ---- #9334: ordinary-author interrupted canonical integration carriers ----
# Native controls for the closed `interrupted-canonical-integration/v2` variant.
# Every repository, commit, process tree and transcript below is synthetic; the
# only real inputs are the candidate sources and the immutable baseline archive.
# The merge graph reproduces the 9285 first-stop shape: a first-parent chain and
# an older side history joined by a merge, so the raw reverse list (six commits
# including the merge) differs from the sequencer's five-pick plan.
function Test-9334OrdinaryCarrier([ValidateSet('ordinary-dispatch','ordinary-rebase','ordinary-watchdog','successor-rebase','successor-publication','successor-amend','successor-dispatch','successor-completion','successor-depth','successor-watchdog')][string]$Carrier) {
  Import-Module (Join-Path $PSScriptRoot 'landed-integration-evidence.psm1') -Force -DisableNameChecking
  . (Join-Path $PSScriptRoot 'dispatch-ownership.ps1')
  $root = Join-Path ([IO.Path]::GetTempPath()) ('integration-9334-'+$Carrier+'-'+[guid]::NewGuid().ToString('N'))
  [IO.Directory]::CreateDirectory($root) | Out-Null
  $artifacts = Join-Path $PSScriptRoot 'artifacts'
  [IO.Directory]::CreateDirectory($artifacts) | Out-Null
  $script:ordinary9334Counter = 0
  $candidateHead = (@(& git.exe -C (Split-Path -Parent $PSScriptRoot) rev-parse HEAD) -join '').Trim()
  if ($LASTEXITCODE -ne 0 -or $candidateHead -cnotmatch '^[a-f0-9]{40}$') { throw '9334 exact test candidate unavailable' }
  $baselineHead = '4ef3fc35d82153f7751cf28a9a740d365f972688'
  $candidateTag = $candidateHead.Substring(0,8)+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
  $finished = $false
  function Proof9334([bool]$Condition,[string]$Name) {
    $issueTag = if ($Carrier -like 'successor-*') { '9411' } else { '9334' }
    if (-not $Condition) { throw "$issueTag $Carrier ASSERTION FAILED: $Name; retained=$root" }
    [Console]::Out.WriteLine("PROOF $issueTag $Carrier $Name") # console, not pipeline: callers may discard function output
  }
  function Git9334([string]$Repo,[string[]]$Arguments) {
    $output = @(& git.exe --no-optional-locks -C $Repo @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "9334 native Git failed: $($Arguments -join ' ') $($output -join "`n")" }
    return ($output -join "`n").Trim()
  }
  function Save9334([string]$Path,$Value) { [IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 20 -Compress),[Text.UTF8Encoding]::new($false)) }
  function Native9334([string]$Script,[string[]]$Arguments) {
    $script:ordinary9334Counter++
    $stem=Join-Path $artifacts ("9334-$candidateTag-$Carrier-{0:d3}" -f $script:ordinary9334Counter)
    $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=(Join-Path $PSHOME 'pwsh.exe');$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    $configIndex=[Array]::IndexOf($Arguments,'-Config')
    if($configIndex-ge0-and$configIndex+1-lt$Arguments.Count-and$(foreach($c in @(Read-RebaseJson $Arguments[$configIndex+1])){[bool]$c.resume-or-not[string]::IsNullOrEmpty([string]$c.resumePath)})){
      foreach($name in @('GIT_DIR','GIT_WORK_TREE','GIT_INDEX_FILE','GIT_OBJECT_DIRECTORY','GIT_ALTERNATE_OBJECT_DIRECTORIES')){[void]$psi.Environment.Remove($name)}
    }
    foreach($argument in @('-NoProfile','-NonInteractive','-File',$Script)+$Arguments){[void]$psi.ArgumentList.Add($argument)}
    $p=[Diagnostics.Process]::Start($psi)
    try {
      $start=$p.StartTime.ToUniversalTime().ToString('o');$out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync();$p.WaitForExit()
      $stdout=$out.GetAwaiter().GetResult();$stderr=$err.GetAwaiter().GetResult()
      [IO.File]::WriteAllText("$stem.stdout.txt",$stdout);[IO.File]::WriteAllText("$stem.stderr.txt",$stderr)
      Save9334 "$stem.result.json" ([ordered]@{pid=$p.Id;startIdentity=$start;exitCode=$p.ExitCode;script=$Script;arguments=$Arguments;stdoutPath="$stem.stdout.txt";stderrPath="$stem.stderr.txt"})
      return [pscustomobject]@{exit=$p.ExitCode;stdout=$stdout;stderr=$stderr;resultPath="$stem.result.json"}
    } finally { $p.Dispose() }
  }
  $harness=Join-Path $root 'synthetic-ordinary-harness.ps1'
  [IO.File]::WriteAllText($harness,@'
param([string]$Config)
$ErrorActionPreference='Stop'
$cfg=Get-Content -Raw $Config|ConvertFrom-Json -DateKind String
$stdin=[Console]::In.ReadToEnd()
if($cfg.promptCapture){[IO.File]::WriteAllText($cfg.promptCapture,$stdin)}
Import-Module $cfg.module -Force -DisableNameChecking
$deadline=[datetimeoffset]::UtcNow.AddSeconds(10)
do {
  $owners=@(Get-ChildItem -LiteralPath $cfg.runtime -Filter 'dispatch-launch-*.json' -File|ForEach-Object{Get-Content -Raw $_.FullName|ConvertFrom-Json -DateKind String}|Where-Object{$_.childPid-eq$PID-and$_.state-ceq'started'})
  if($owners.Count-eq1){break}
  [Threading.Thread]::Sleep(20)
} while([datetimeoffset]::UtcNow-lt$deadline)
if($owners.Count-ne1){throw 'synthetic ordinary child ownership not published'}
$o=$cfg.obligation
$exe=Join-Path $PSHOME 'pwsh.exe'
function Emit([string]$Command,[string[]]$Output,[int]$Code){ [Console]::Out.WriteLine(([ordered]@{type='item.completed';item=[ordered]@{id=[guid]::NewGuid().ToString('N');type='command_execution';command=$Command;aggregated_output=($Output -join "`n");exit_code=[long]$Code;status=$(if($Code-eq0){'completed'}else{'failed'})}}|ConvertTo-Json -Depth 8 -Compress)) }
function Helper([string[]]$Extra){
  $arguments=@('-NoProfile','-NonInteractive','-File',$cfg.helper,'-Pr',[string]$o.pr,'-ReviewedHead',$o.targetHead,'-NewBase',$o.newBase,'-SourcePassReceiptIdentity','ABSENT_REVIEW_REQUIRED','-IntegrationLane',$o.integrationLane,'-Worktree',$cfg.repo,'-RuntimeRoot',$cfg.runtime)+$Extra
  $out=@(& $exe @arguments 2>&1);$code=$LASTEXITCODE
  Emit ('pwsh '+($arguments -join ' ')) $out $code
  [pscustomobject]@{code=$code;text=($out -join "`n")}
}
function Expect($r,[int]$Code,[string]$Reason,[string]$Name){ if($r.code-ne$Code-or($Reason-and-not$r.text.Contains($Reason))){throw "synthetic $Name expected exit=$Code reason='$Reason' got exit=$($r.code) $($r.text)"} }
if($cfg.phase-cin@('seed','live')){
  [IO.Directory]::CreateDirectory((Join-Path $cfg.repo '.codex'))|Out-Null
  $inner="pwsh -NoProfile -File ../runtime/rebase-integration.ps1 -Pr $($o.pr) -ReviewedHead $($o.targetHead) -NewBase $($o.newBase) -SourcePassReceiptIdentity ABSENT_REVIEW_REQUIRED -IntegrationLane $($o.integrationLane) -Worktree $($cfg.repo) -NoPush *> .codex/integration.log; `$code=`$LASTEXITCODE; Get-Content .codex/integration.log -Tail 30; exit `$code"
  $out=@(& $exe -Command $inner 2>&1);$code=$LASTEXITCODE
  Emit ('"'+$exe+'" -Command '''+$inner+'''') $out $code
  if($code-ne2){throw "synthetic ordinary first stop exit=$code $($out -join "`n")"}
  if($cfg.phase-ceq'seed'){exit 0} # Faithful nominal child success is not completion.
}
if($cfg.phase-ceq'successor'){
  # 9411 successor: attached at R or granted P; nothing native remains to continue.
  [IO.File]::WriteAllText($cfg.entry,(@{head=(@(& git -C $cfg.repo rev-parse HEAD) -join '').Trim()}|ConvertTo-Json -Compress))
  if($cfg.successorContinue){ Expect (Helper @('-ContinueInterruptedIntegration','-NoPush')) 1 'successor publishes only' 'successor continuation' }
} else {
$entry=Get-InterruptedIntegrationState $cfg.repo
[IO.File]::WriteAllText($cfg.entry,($entry|ConvertTo-Json -Compress))
if($cfg.entryOnly){exit 0}
if($cfg.earlyPublish){ Expect (Helper @('-PublishInterruptedIntegration')) 1 'finish proof required' 'early publication' }
$beforeNoPush=Get-RebaseRecordIdentity (Get-InterruptedIntegrationState $cfg.repo)
Expect (Helper @('-ContinueInterruptedIntegration')) 1 'ordinary continuation requires NoPush' 'missing NoPush'
if((Get-RebaseRecordIdentity (Get-InterruptedIntegrationState $cfg.repo))-cne$beforeNoPush){throw 'missing NoPush mutated native checkpoint'}
$paths=@(& git --no-optional-locks -C $cfg.repo diff --name-only --diff-filter=U)
if($LASTEXITCODE-ne0){throw 'synthetic unmerged inventory failed'}
foreach($path in $paths){[IO.File]::WriteAllText((Join-Path $cfg.repo $path),"synthetic resolved $path`n");& git -C $cfg.repo add -- $path;if($LASTEXITCODE-ne0){throw 'synthetic stage failed'}}
$continue=Helper @('-ContinueInterruptedIntegration','-NoPush')
if($continue.code-eq2){exit 2}
if($continue.code-ne0){throw "synthetic continuation exit=$($continue.code) $($continue.text)"}
if($cfg.barePublish){ Expect (Helper @('-PublishInterruptedIntegration')) 1 'bare finish result' 'bare publication' }
if($cfg.finishOnly){exit 0}
}
switch([string]$cfg.movement){
  'commit'{
    [IO.File]::WriteAllText((Join-Path $cfg.repo 'synthetic-repair.txt'),"synthetic repair`n");[IO.File]::WriteAllText((Join-Path $cfg.repo 'synthetic-repair.test.txt'),"synthetic repair test`n")
    & git -C $cfg.repo add -- synthetic-repair.txt synthetic-repair.test.txt;if($LASTEXITCODE-ne0){throw 'synthetic add failed'}
    & git -C $cfg.repo commit -qm 'synthetic repair and test';if($LASTEXITCODE-ne0){throw 'synthetic commit failed'}
  }
  'commit-again'{
    [IO.File]::AppendAllText((Join-Path $cfg.repo 'synthetic-repair.txt'),"synthetic successor repair`n")
    & git -C $cfg.repo commit -qam 'synthetic successor repair';if($LASTEXITCODE-ne0){throw 'synthetic successor commit failed'}
  }
  'commit-amend'{
    # 9411: a valid granted commit after R, then amended by the successor itself.
    [IO.File]::WriteAllText((Join-Path $cfg.repo 'synthetic-repair.txt'),"synthetic repair`n");[IO.File]::WriteAllText((Join-Path $cfg.repo 'synthetic-repair.test.txt'),"synthetic repair test`n")
    & git -C $cfg.repo add -- synthetic-repair.txt synthetic-repair.test.txt;if($LASTEXITCODE-ne0){throw 'synthetic add failed'}
    & git -C $cfg.repo commit -qm 'synthetic granted repair';if($LASTEXITCODE-ne0){throw 'synthetic commit failed'}
    [IO.File]::AppendAllText((Join-Path $cfg.repo 'synthetic-repair.txt'),"synthetic amended repair`n")
    & git -C $cfg.repo commit -q --amend -am 'synthetic amended granted repair';if($LASTEXITCODE-ne0){throw 'synthetic amend failed'}
  }
  'amend-finish'{ & git -C $cfg.repo commit -q --amend -m 'synthetic amended finish';if($LASTEXITCODE-ne0){throw 'synthetic amend failed'} }
  'reset'{ & git -C $cfg.repo reset -q --soft HEAD~1;if($LASTEXITCODE-ne0){throw 'synthetic reset failed'};& git -C $cfg.repo commit -qm 'synthetic rewritten finish';if($LASTEXITCODE-ne0){throw 'synthetic commit failed'} }
  default{}
}
if($cfg.scopeViolation){
  $outsidePath=if($cfg.scopeViolation-ceq'unicode-alias'){'synthetic'+[char]0x00ad+'-repair.txt'}else{'synthetic-outside-grant.txt'}
  [IO.File]::WriteAllText((Join-Path $cfg.repo $outsidePath),"synthetic unauthorized edit`n")
  & git -C $cfg.repo add -- $outsidePath; & git -C $cfg.repo commit -qm 'synthetic outside FINAL grant'
  if($LASTEXITCODE-ne0){throw 'synthetic outside commit failed'}
  if($cfg.scopeViolation-ceq'edit-then-revert'){
    Remove-Item -LiteralPath (Join-Path $cfg.repo 'synthetic-outside-grant.txt')
    & git -C $cfg.repo add -u; & git -C $cfg.repo commit -qm 'synthetic revert hides unauthorized net diff'
    if($LASTEXITCODE-ne0){throw 'synthetic reverting commit failed'}
  }
}
if($cfg.leaseMismatch){ $older=(& git -C $cfg.repo rev-parse "$($o.targetHead)^").Trim(); & git -C $cfg.remote update-ref "refs/heads/$($o.branch)" $older; if($LASTEXITCODE-ne0){throw 'synthetic remote move failed'} }
if($cfg.exitBeforePublish){exit 0} # declared controlled exit at the finish boundary: finished-unpublished
if($cfg.injectPublication){[IO.File]::WriteAllText($cfg.injectPublication,'{}')} # synthetic record appearing after admission
if($cfg.prePublish){ # 9411: local head, reflogs and status a refused publication must keep
  $gitDir=Join-Path $cfg.repo '.git'
  [IO.File]::WriteAllText($cfg.prePublish,([ordered]@{head=(@(& git -C $cfg.repo rev-parse HEAD) -join '').Trim();branchLog=(Get-RebaseHash ([IO.File]::ReadAllBytes((Join-Path $gitDir "logs/refs/heads/$($o.branch)"))));headLog=(Get-RebaseHash ([IO.File]::ReadAllBytes((Join-Path $gitDir 'logs/HEAD'))));status=(@(& git --no-optional-locks -C $cfg.repo status --porcelain=v1 --untracked-files=normal) -join "`n")}|ConvertTo-Json -Compress))
}
$publish=Helper @('-PublishInterruptedIntegration')
if($cfg.expectRefusal){ Expect $publish 1 $cfg.expectRefusal 'publication refusal'; exit 0 }
Expect $publish 0 '"pushed":true' 'publication'
if($cfg.duplicatePublish){ Expect (Helper @('-PublishInterruptedIntegration')) 1 'already published' 'duplicate publication' }
if($cfg.moveAfterPublish){ [IO.File]::AppendAllText((Join-Path $cfg.repo 'synthetic-repair.test.txt'),"synthetic after publication`n"); & git -C $cfg.repo commit -qam 'synthetic movement after publication'; if($LASTEXITCODE-ne0){throw 'synthetic post-publication commit failed'} }
exit 0
'@,[Text.UTF8Encoding]::new($false))
  $runner=Join-Path $root 'synthetic-ordinary-launch.ps1'
  [IO.File]::WriteAllText($runner,@'
param([string]$Config,[switch]$Dry,[string]$Role='implementation',[string]$Harness='codex',[string]$Model='gpt-6-astra',[string]$Effort='high',[string]$Route='7',[string]$Placement='override-Todd',[int]$Relaunch=0)
$ErrorActionPreference='Stop'
$cfg=Get-Content -Raw $Config|ConvertFrom-Json -DateKind String
$params=@{Harness=$Harness;Model=$Model;Effort=$Effort;Row=[int]$Route;Placement=$Placement;LaneRole=$Role;PromptFile=$cfg.prompt;Worktree=$cfg.repo;Label=$cfg.label;ExecutablePath=(Join-Path $PSHOME 'pwsh.exe');TestArgumentList=@('-NoProfile','-NonInteractive','-File',$cfg.harness,'-Config',$Config);TestRuntimeRoot=$cfg.runtime;DryRun=$Dry}
if($cfg.resumePath){$params.InterruptedIntegrationResumePath=$cfg.resumePath}
if($cfg.semanticAttemptId){$params.SemanticAttemptId=$cfg.semanticAttemptId}
if($Relaunch){$params.WatchdogRelaunchCount=$Relaunch}
& $cfg.dispatch @params
exit $LASTEXITCODE
'@,[Text.UTF8Encoding]::new($false))
  function Fixture9334([string]$Name,[switch]$SecondStop,[switch]$Live) {
    $case=Join-Path $root ($Name+'-'+[guid]::NewGuid().ToString('N'));$repo=Join-Path $case 'lane';$runtime=Join-Path $case 'runtime';$remote=Join-Path $case 'remote.git'
    [IO.Directory]::CreateDirectory($repo)|Out-Null;[IO.Directory]::CreateDirectory($runtime)|Out-Null
    foreach($file in @('rebase-integration.ps1','landed-integration-evidence.psm1','dispatch-ownership.ps1','integration-dispatch-contract.ps1','routing-data.ps1')){
      Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $runtime $file)
      if((Get-FileHash -LiteralPath (Join-Path $runtime $file)).Hash-cne(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $file)).Hash){throw '9334 canonical fixture helper source differs'}
    }
    [void](Git9334 $repo @('init','-q','--initial-branch=main'));[void](Git9334 $repo @('config','user.name','Unmistakably Synthetic 9334'));[void](Git9334 $repo @('config','user.email','synthetic-9334@example.invalid'));[void](Git9334 $repo @('config','commit.gpgsign','false'))
    [IO.File]::WriteAllText((Join-Path $repo '.gitignore'),".codex/`n")
    [IO.File]::WriteAllText((Join-Path $repo 'README.md'),"synthetic ancestor README`nunchanged middle`nbase tail`n")
    [IO.File]::WriteAllText((Join-Path $repo 'package.json'),"{`n  `"name`": `"synthetic-ancestor`",`n  `"version`": `"0.0.1`"`n}`n")
    [void](Git9334 $repo @('add','.'));[void](Git9334 $repo @('commit','-qm','synthetic ancestor'));$ancestor=Git9334 $repo @('rev-parse','HEAD')
    $branch="synthetic/9334-$Name";[void](Git9334 $repo @('checkout','-qb',$branch))
    $side="synthetic/9334-side-$Name";[void](Git9334 $repo @('checkout','-qb',$side))
    $previousAuthorDate=$env:GIT_AUTHOR_DATE;$previousCommitterDate=$env:GIT_COMMITTER_DATE
    try {
      $env:GIT_AUTHOR_DATE='2026-10-01T00:00:00Z';$env:GIT_COMMITTER_DATE='2026-10-01T00:00:00Z'
      [IO.File]::WriteAllText((Join-Path $repo 'side.txt'),"synthetic side one`n");[void](Git9334 $repo @('add','.'));[void](Git9334 $repo @('commit','-qm','synthetic side 1'))
      $env:GIT_AUTHOR_DATE='2026-10-01T00:00:01Z';$env:GIT_COMMITTER_DATE='2026-10-01T00:00:01Z'
      [IO.File]::AppendAllText((Join-Path $repo 'side.txt'),"synthetic side two`n");[void](Git9334 $repo @('commit','-qam','synthetic side 2'))
      [void](Git9334 $repo @('checkout','-q',$branch))
      $env:GIT_AUTHOR_DATE='2026-10-02T00:00:00Z';$env:GIT_COMMITTER_DATE='2026-10-02T00:00:00Z'
      [IO.File]::WriteAllText((Join-Path $repo 'package.json'),"{`n  `"name`": `"synthetic-feature`",`n  `"version`": `"0.0.1`"`n}`n");[void](Git9334 $repo @('commit','-qam','synthetic chain 1 package'))
      $env:GIT_AUTHOR_DATE='2026-10-02T00:00:01Z';$env:GIT_COMMITTER_DATE='2026-10-02T00:00:01Z'
      [IO.File]::WriteAllText((Join-Path $repo 'README.md'),"synthetic feature README`nunchanged middle`nbase tail`n");[void](Git9334 $repo @('commit','-qam','synthetic chain 2 readme'))
      $env:GIT_AUTHOR_DATE='2026-10-02T00:00:02Z';$env:GIT_COMMITTER_DATE='2026-10-02T00:00:02Z'
      [IO.File]::WriteAllText((Join-Path $repo 'feature.txt'),"synthetic feature file`n")
      if($SecondStop){[IO.File]::WriteAllText((Join-Path $repo 'README.md'),"synthetic feature README`nunchanged middle`nfeature tail`n")}
      [void](Git9334 $repo @('add','.'));[void](Git9334 $repo @('commit','-qm','synthetic chain 3 feature'))
      $env:GIT_AUTHOR_DATE='2026-10-03T00:00:00Z';$env:GIT_COMMITTER_DATE='2026-10-03T00:00:00Z'
      [void](Git9334 $repo @('merge','--no-ff','-q','-m','synthetic merge side',$side))
    } finally {
      if($null-eq$previousAuthorDate){Remove-Item Env:GIT_AUTHOR_DATE -ErrorAction SilentlyContinue}else{$env:GIT_AUTHOR_DATE=$previousAuthorDate}
      if($null-eq$previousCommitterDate){Remove-Item Env:GIT_COMMITTER_DATE -ErrorAction SilentlyContinue}else{$env:GIT_COMMITTER_DATE=$previousCommitterDate}
    }
    $original=Git9334 $repo @('rev-parse','HEAD');[void](Git9334 $repo @('branch','-qD',$side))
    [void](Git9334 $repo @('checkout','-q','main'))
    [IO.File]::WriteAllText((Join-Path $repo 'package.json'),"{`n  `"name`": `"synthetic-landed`",`n  `"version`": `"0.0.2`"`n}`n")
    if($SecondStop){[IO.File]::WriteAllText((Join-Path $repo 'README.md'),"synthetic ancestor README`nunchanged middle`nlanded tail`n")}
    [void](Git9334 $repo @('commit','-qam','synthetic landed'));$onto=Git9334 $repo @('rev-parse','HEAD');[void](Git9334 $repo @('checkout','-q',$branch))
    $oldBase=Git9334 $repo @('merge-base',$original,$onto)
    $raw=@((Git9334 $repo @('rev-list','--reverse',"$oldBase..$original")) -split "`n");$plan=@((Git9334 $repo @('rev-list','--reverse','--topo-order','--no-merges',"$oldBase..$original")) -split "`n")
    if($oldBase-cne$ancestor-or$raw.Count-ne6-or$plan.Count-ne5-or($raw[0..4] -join ',')-ceq($plan -join ',')){throw "9334 NOT_CONSTRUCTIBLE: synthetic merge graph raw=$($raw.Count) plan=$($plan.Count)"}
    [void](Git9334 $repo @('init','--bare',$remote));[void](Git9334 $repo @('remote','add','origin',$remote));$pr=[long]996334
    [void](Git9334 $repo @('push','-q','origin',"HEAD:refs/heads/$branch","HEAD:refs/pull/$pr/head",'main:refs/heads/main'))
    $o=[ordered]@{schemaVersion='ordinary-integration/v1';pr=$pr;targetHead=$original;newBase=$onto;branch=$branch;worktree=$repo;integrationLane="9334-$Name"}
    $label="ordinary-9334-$Name-seed";$prompt=Join-Path $runtime "$label.prompt.txt"
    $decisionDirectory=Join-Path $runtime 'logs';[void][IO.Directory]::CreateDirectory($decisionDirectory)
    $decisionPath=Join-Path $decisionDirectory 'synthetic-final.report.md'
    [IO.File]::WriteAllText($decisionPath,"SYNTHETIC FINAL ONLY: permit synthetic-repair.txt and corresponding synthetic-repair.test.txt. Not an actual product test-path grant.`n")
    $grant=[ordered]@{schemaVersion='ordinary-integration-repair-authority/v1';obligationIdentity=(Get-RebaseObligationIdentity $o);decisionPath=$decisionPath;decisionSha256=(Get-RebaseHash ([IO.File]::ReadAllBytes($decisionPath)));firstLine=1;lastLine=1;repairPaths=@('synthetic-repair.txt');focusedTests=@([ordered]@{path='synthetic-repair.test.txt';repairPath='synthetic-repair.txt'})}
    $scopeBlock='```ordinary-integration-repair-authority/v1'+"`n"+($grant|ConvertTo-Json -Depth 10 -Compress)+"`n"+'```'
    [IO.File]::WriteAllText($prompt,"Synthetic ordinary author: integrate PR #$pr onto $onto through rebase-integration.ps1 with -NoPush. After a conflict stop, never continue, abort, reset or push.`n$scopeBlock`n")
    $cfg=[ordered]@{repo=$repo;runtime=$runtime;remote=$remote;obligation=$o;module=(Join-Path $PSScriptRoot 'landed-integration-evidence.psm1');helper=(Join-Path $runtime 'rebase-integration.ps1');harness=$harness;dispatch=(Join-Path $PSScriptRoot 'dispatch-lane.ps1');prompt=$prompt;label=$label;phase=$(if($Live){'live'}else{'seed'});resumePath='';semanticAttemptId='';entry=(Join-Path $case 'entry.json');entryOnly=$false;earlyPublish=$false;barePublish=$false;finishOnly=$false;movement='commit';leaseMismatch=$false;expectRefusal='';duplicatePublish=$false}
    $config=Join-Path $case 'config.json';Save9334 $config $cfg
    $seed=Native9334 $runner @('-Config',$config)
    $w=Read-RebaseJson (Join-Path $runtime "watchdog-lane-$label.json")
    if($w.schemaVersion-cne'watchdog-lane/v2'-or$w.state-cne'exited'-or$w.exitCode-ne0){throw "9334 ordinary seed did not reproduce nominal child success $($seed.resultPath)"}
    $nativeDir=Join-Path $repo '.git/rebase-merge'
    if(-not$Live){
      if([IO.File]::ReadAllText((Join-Path $nativeDir 'msgnum')).Trim()-cne'1'-or[IO.File]::ReadAllText((Join-Path $nativeDir 'end')).Trim()-cne'5'){throw '9334 native first-stop remaining history shape mismatch'}
      if((Git9334 $repo @('diff','--name-only','--diff-filter=U'))-cne'package.json'){throw '9334 native first-stop conflict path mismatch'}
    }
    $capturePath=Join-Path $runtime "integration-ordinary-conflict-$($w.launchId).json"
    $cfg.phase='resume';$cfg.label="ordinary-9334-$Name-resume";$cfg.prompt=Join-Path $runtime "$($cfg.label).prompt.txt";[IO.File]::WriteAllText($cfg.prompt,[IO.File]::ReadAllText($prompt));Save9334 $config $cfg
    [pscustomobject]@{repo=$repo;runtime=$runtime;remote=$remote;case=$case;cfg=$cfg;config=$config;obligation=$o;seed=$seed;prior=$w;seedLabel=$label;capturePath=$capturePath;original=$original;onto=$onto;oldBase=$oldBase;branch=$branch;pr=$pr;raw=$raw;plan=$plan;binding=$null}
  }
  function Bind9334($f) {
    $binding=New-InterruptedIntegrationResume $f.obligation $f.runtime $f.seedLabel $f.prior.launchId
    $f.binding=$binding;$f.cfg.resumePath=Join-Path $f.runtime 'resume-input.json';Save9334 $f.cfg.resumePath $binding;Save9334 $f.config $f.cfg
    return $binding
  }
  function Launch9334($f,[string[]]$Extra=@()) { Save9334 $f.config $f.cfg; Native9334 $runner (@('-Config',$f.config)+$Extra) }
  function RawState9334($f) {
    $files=[ordered]@{};$gitDir=Join-Path $f.repo '.git'
    foreach($file in @(Get-ChildItem -LiteralPath $f.repo -Recurse -File -Force|Sort-Object FullName)){
      if($file.FullName.StartsWith($gitDir+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){continue}
      $files[[IO.Path]::GetRelativePath($f.repo,$file.FullName)]=Get-RebaseHash ([IO.File]::ReadAllBytes($file.FullName))
    }
    $metadata=[ordered]@{};$native=Join-Path $gitDir 'rebase-merge'
    if(Test-Path -LiteralPath $native){foreach($file in @(Get-ChildItem -LiteralPath $native -Recurse -File -Force|Sort-Object FullName)){$metadata[$file.Name]=Get-RebaseHash ([IO.File]::ReadAllBytes($file.FullName))}}
    # An attached (finished) worktree has no native metadata; name that explicitly.
    Get-RebaseRecordIdentity ([ordered]@{head=(Git9334 $f.repo @('rev-parse','HEAD'));index=(Get-RebaseHash ([IO.File]::ReadAllBytes((Join-Path $gitDir 'index'))));files=$files;metadata=$(if($metadata.Count){$metadata}else{'no native operation'})})
  }
  function RuntimeState9334($f) {
    Get-RebaseRecordIdentity @(@(Get-ChildItem -LiteralPath $f.runtime -Recurse -File -Force|Sort-Object FullName)|ForEach-Object{[ordered]@{path=[IO.Path]::GetRelativePath($f.runtime,$_.FullName);sha256=(Get-RebaseHash ([IO.File]::ReadAllBytes($_.FullName)))}})
  }
  $mutants9334=@{}
  function Mutant9334([string]$Name,[string]$File,[string]$Needle,[string]$Replacement) {
    if($mutants9334.ContainsKey($Name)){return $mutants9334[$Name]}
    if(-not(Test-BatteryProofRelevant @($File))){
      [Console]::Out.WriteLine("SKIPPED 9334 $Carrier mutant=$Name guarded=$File unchanged in impact battery")
      $mutants9334[$Name]=$null
      return $null
    }
    $dir=Join-Path $root "mutant-$Name";[IO.Directory]::CreateDirectory($dir)|Out-Null
    $sourceRoot=Split-Path -Parent $PSScriptRoot
    $sourcePaths=@(& git.exe -C $sourceRoot ls-files --cached --others --exclude-standard -- .orchestrator)
    if($LASTEXITCODE-ne0){throw '9334 current source inventory failed'}
    foreach($relative in $sourcePaths){
      $destination=Join-Path $dir $relative
      [IO.Directory]::CreateDirectory((Split-Path -Parent $destination))|Out-Null
      Copy-Item -LiteralPath (Join-Path $sourceRoot $relative) -Destination $destination
    }
    $path=Join-Path $dir ".orchestrator/$File";$text=[IO.File]::ReadAllText($path)
    if([regex]::Matches($text,[regex]::Escape($Needle)).Count-ne1){throw "9334 mutant $Name exact guard count differs"}
    [IO.File]::WriteAllText($path,$text.Replace($Needle,$Replacement),[Text.UTF8Encoding]::new($false))
    [void](Git9334 $dir @('init','-q','--initial-branch=synthetic/controller'));[void](Git9334 $dir @('config','user.name','Synthetic guard omission'));[void](Git9334 $dir @('config','user.email','synthetic-omission@example.invalid'));[void](Git9334 $dir @('config','commit.gpgsign','false'));[void](Git9334 $dir @('add','.orchestrator'));[void](Git9334 $dir @('commit','-qm',"synthetic omitted $Name guard"))
    Save9334 (Join-Path $artifacts "9334-$candidateTag-$Carrier-mutant-$Name.json") ([ordered]@{candidateHead=$candidateHead;name=$Name;file=$File;omitted=$Needle;replacement=$Replacement;mutantPath=$path;candidateSha256=(Get-RebaseHash ([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot $File))));mutantSha256=(Get-RebaseHash ([IO.File]::ReadAllBytes($path)))})
    $mutants9334[$Name]=Join-Path $dir '.orchestrator/dispatch-lane.ps1'
    return $mutants9334[$Name]
  }
  function GuardLine9334([string]$File,[string]$Diagnostic) {
    $lines=@([IO.File]::ReadAllLines((Join-Path $PSScriptRoot $File))|Where-Object{$_.Contains($Diagnostic)})
    if($lines.Count-ne1){throw "9334 unique guard line missing: $Diagnostic"};return $lines[0]
  }
  function ValidPlan9334($f,[string]$Name,[string[]]$Extra=@('-Dry')) {
    $before=RawState9334 $f;$runtimeBefore=RuntimeState9334 $f
    $result=Launch9334 $f $Extra
    Proof9334 ($result.exit-eq0-and$result.stdout.Contains('"heavyAdmission"')-and-not(Test-Path $f.cfg.entry)-and(RawState9334 $f)-ceq$before-and(RuntimeState9334 $f)-ceq$runtimeBefore) "$Name valid ordinary resume plan=RAN harness=NOTRUN target/runtime=UNCHANGED raw=$($result.resultPath)"
  }
  function Refusal9334($f,[string]$Name,[string]$Reason,[string[]]$Extra=@('-Dry')) {
    $before=RawState9334 $f;$runtimeBefore=RuntimeState9334 $f
    $result=Launch9334 $f $Extra
    Proof9334 ($result.exit-ne0-and$result.stderr.Contains($Reason)-and-not(Test-Path -LiteralPath $f.cfg.entry)-and(RawState9334 $f)-ceq$before-and(RuntimeState9334 $f)-ceq$runtimeBefore-and-not$result.stdout.Contains('"heavyAdmission"')) "$Name exit=$($result.exit) body=NOTRUN index/bytes/metadata/runtime=UNCHANGED raw=$($result.resultPath)"
  }
  function Discriminator9334($f,[string]$Name,[string]$Reason,[string]$MutantPath,[string[]]$Extra=@('-Dry')) {
    Refusal9334 $f "$Name candidate" $Reason $Extra
    if([string]::IsNullOrEmpty($MutantPath)){[Console]::Out.WriteLine("SKIPPED 9334 $Carrier $Name omitted-guard arm");return}
    $before=RawState9334 $f;$runtimeBefore=RuntimeState9334 $f;$candidatePath=$f.cfg.dispatch
    try{$f.cfg.dispatch=$MutantPath;$bypass=Launch9334 $f $Extra}finally{$f.cfg.dispatch=$candidatePath;Save9334 $f.config $f.cfg}
    Proof9334 ($bypass.exit-eq0-and$bypass.stdout.Contains('"heavyAdmission"')-and(RawState9334 $f)-ceq$before-and(RuntimeState9334 $f)-ceq$runtimeBefore-and-not(Test-Path -LiteralPath $f.cfg.entry)) "$Name independent omitted guard actual exit=$($bypass.exit) expected=0 plan=RAN harness=NOTRUN bytes=UNCHANGED raw=$($bypass.resultPath)"
  }
  function Events9334($f,[string]$Label) { @([IO.File]::ReadAllLines((Join-Path $f.runtime "$Label.jsonl")) | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json -DateKind String } | Where-Object { $_.type -ceq 'item.completed' -and $_.item.type -ceq 'command_execution' }) }
  function Completion9334($f,[string]$Origin,[string]$Name) {
    $completion=Read-RebaseCompletion $f.obligation $f.runtime
    $remoteHead=(Git9334 $f.repo @('ls-remote','--heads','origin',"refs/heads/$($f.branch)")).Split("`t")[0]
    Proof9334 ($null-ne$completion-and$completion.schemaVersion-ceq'landed-integration-rebase-complete/v3'-and$completion.mode-ceq'ORDINARY_OWNER_RELEASE'-and$completion.origin-ceq$Origin-and$completion.predecessorHead-ceq$f.original-and$completion.finishHead-cne$completion.resultHead-and$completion.movementProof.commitCount-eq1-and@($completion.movementProof.changedPaths).Count-eq2-and$completion.resultHead-ceq$remoteHead-and(Git9334 $f.repo @('rev-parse','HEAD'))-ceq$completion.resultHead-and(Git9334 $f.repo @('branch','--show-current'))-ceq$f.branch-and(Git9334 $f.repo @('status','--porcelain=v1','--untracked-files=normal'))-ceq'') "$Name completion/v3 origin=$Origin binds finish R, one plain repair commit (two files) R->P, remote==P, clean attached result"
    [void](Git9334 $f.repo @('merge-base','--is-ancestor',$f.onto,$completion.resultHead));[void](Git9334 $f.repo @('merge-base','--is-ancestor',$completion.finishHead,$completion.resultHead))
    $mutations=[ordered]@{
      'boolean finish identity'={param($c) $c.movementProof.finishIdentity=$true}
      'bare R completion'={param($c) $c.resultHead=$c.finishHead;$c.movementProof.rows=@();$c.movementProof.commitCount=0;$c.movementProof.publicationIdentity=$null}
      'boolean movement row'={param($c) $c.movementProof.rows[0].new=$true}
      'movement row extra'={param($c) $c.movementProof.rows[0]|Add-Member unknownAuthority $true}
      'nonstring changed path'={param($c) $c.movementProof.changedPaths=@($true)}
      'wildcard changed path'={param($c) $c.movementProof.changedPaths=@('*')}
      'boolean repository'={param($c) $c.publication.repository=$true}
      'date-only native time'={param($c) $c.rebaseProof.startedAt='2026-10-01'}
      'wrong finish identity'={param($c) $c.movementProof.finishIdentity='f'*64}
      'scope widened at completion'={param($c) $c.repairAuthority.grant.repairPaths+= 'synthetic-outside-grant.txt'}
    }
    if($Origin-ceq'live'){
      $mutations['nested capture owner extra']={param($c) $v=$c.interruptedIntegration|ConvertFrom-Json -DateKind String;$v.owner|Add-Member unknownAuthority $true;$c.interruptedIntegration=$v|ConvertTo-Json -Depth 20 -Compress}
      foreach($key in @('launcherPid','childPid','launcherStartIdentity','childStartIdentity')){
        $mutations["capture owner $key wrong type"]=[scriptblock]::Create("param(`$c) `$v=`$c.interruptedIntegration|ConvertFrom-Json -DateKind String;`$v.owner.$key=`$true;`$c.interruptedIntegration=`$v|ConvertTo-Json -Depth 20 -Compress")
      }
      $mutations['capture source PASS boolean']={param($c) $v=$c.interruptedIntegration|ConvertFrom-Json -DateKind String;$v.sourcePassReceiptIdentity=$true;$c.interruptedIntegration=$v|ConvertTo-Json -Depth 20 -Compress}
      $mutations['capture wrong state join']={param($c) $v=$c.interruptedIntegration|ConvertFrom-Json -DateKind String;$v.state.onto='f'*40;$c.interruptedIntegration=$v|ConvertTo-Json -Depth 20 -Compress}
      $mutations['capture invalid path']={param($c) $v=$c.interruptedIntegration|ConvertFrom-Json -DateKind String;$v.conflictPaths=@('../outside');$c.interruptedIntegration=$v|ConvertTo-Json -Depth 20 -Compress}
    }
    foreach($case in $mutations.GetEnumerator()){
      $bad=$completion|ConvertTo-Json -Depth 30|ConvertFrom-Json -DateKind String
      & $case.Value $bad
      $refused=$false
      try { & (Get-Module landed-integration-evidence) {param($c,$o,$r) Read-OrdinaryIntegrationCompletion $c $o $r 'git' -Replay} $bad $f.obligation $f.runtime | Out-Null } catch { $refused=$true }
      Proof9334 $refused "$Name valid-P single-variable refusal: $($case.Key)"
    }
    $dayAfter=Read-RebaseCompletion $f.obligation $f.runtime -Replay
    [IO.File]::WriteAllText((Join-Path $f.repo 'later-ordinary.txt'),"later ordinary product movement`n");[void](Git9334 $f.repo @('add','later-ordinary.txt'));[void](Git9334 $f.repo @('commit','-qm','synthetic later ordinary movement'))
    $afterMovement=Read-RebaseCompletion $f.obligation $f.runtime -Replay
    Proof9334 ($dayAfter.resultHead-ceq$completion.resultHead-and$afterMovement.resultHead-ceq$completion.resultHead-and(Get-RebaseRecordIdentity $afterMovement)-ceq(Get-RebaseRecordIdentity $completion)-and-not([IO.File]::ReadAllText((Join-Path $f.runtime 'dispatch-log.jsonl')).Contains('rebase-only-continuation/v1'))) "$Name day-after replay and later ordinary movement do not reopen or change completion; no PASS or continuation row"
    return $completion
  }
  # ---- #9411 finished-unpublished successor carriers (synthetic native fixtures) ----
  $successorBaselineHead = 'aa62899ecb923aa87a25ea8a312f7dffc6ed41e0' # installed controller at #9411 dispatch
  function Finish9411($f,[switch]$Commit) {
    # Prior launch F: the resumed ordinary owner finishes R under NoPush,
    # optionally makes one granted plain commit, and exits unpublished.
    [void](Bind9334 $f); $f.cfg.finishOnly=(-not $Commit); $f.cfg.exitBeforePublish=[bool]$Commit; $f.cfg.movement=$(if($Commit){'commit'}else{''})
    $run=Launch9334 $f
    $f.cfg.finishOnly=$false;$f.cfg.exitBeforePublish=$false;$f.cfg.movement='commit';Save9334 $f.config $f.cfg
    $w=Read-RebaseJson (Join-Path $f.runtime "watchdog-lane-$($f.cfg.label).json")
    $finish=Read-RebaseJson (Join-Path $f.runtime "integration-resume-finish-$($w.launchId).json")
    Proof9334 ($run.exit-ne0-and$run.stderr.Contains('INTEGRATION_RESUME_COMPLETION: finished unpublished')-and$w.schemaVersion-ceq'watchdog-lane/v4'-and$w.state-ceq'exited'-and$finish.pushed-eq$false-and(Git9334 $f.repo @('branch','--show-current'))-ceq$f.branch-and(Git9334 $f.remote @('rev-parse',"refs/heads/$($f.branch)"))-ceq$f.original-and$null-eq(Read-RebaseCompletion $f.obligation $f.runtime)-and-not(Test-Path -LiteralPath (Join-Path $f.runtime "integration-resume-publication-$($w.launchId).json"))) "prior launch finished R under NoPush$(if($Commit){' plus one granted plain commit'}), exited unpublished; launcher refused completion; remote at original head raw=$($run.resultPath)"
    if(Test-Path -LiteralPath $f.cfg.entry){Remove-Item -LiteralPath $f.cfg.entry -Force}
    return [pscustomobject]@{watchdog=$w;finish=$finish;finishPath=(Join-Path $f.runtime "integration-resume-finish-$($w.launchId).json")}
  }
  function Successor9411($f,$Prior,[string]$Suffix,$Binding=$null) {
    if($null-eq$Binding){$Binding=New-InterruptedIntegrationResume $f.obligation $f.runtime $Prior.label $Prior.launchId -Successor}
    $f.cfg.phase='successor';$f.cfg.label="ordinary-9411-$Suffix";$f.cfg.prompt=Join-Path $f.runtime "$($f.cfg.label).prompt.txt"
    [IO.File]::WriteAllText($f.cfg.prompt,[IO.File]::ReadAllText((Join-Path $f.runtime "$($f.seedLabel).prompt.txt")))
    $f.cfg.resumePath=Join-Path $f.runtime "successor-$Suffix.json";Save9334 $f.cfg.resumePath $Binding;Save9334 $f.config $f.cfg
    if(Test-Path -LiteralPath $f.cfg.entry){Remove-Item -LiteralPath $f.cfg.entry -Force}
    $f.binding=$Binding
    return $Binding
  }
  # Serialized identity: the controller always hashes the retained JSON form.
  function Identity9411($Value) { Get-RebaseRecordIdentity ($Value|ConvertTo-Json -Depth 20 -Compress|ConvertFrom-Json -DateKind String) }
  function Produce9411($f,$Prior) { New-InterruptedIntegrationResume $f.obligation $f.runtime $Prior.label $Prior.launchId -Successor }
  function Refused9411([scriptblock]$Action) { try { & $Action | Out-Null; return 'UNEXPECTED SUCCESS' } catch { return $_.Exception.Message } }
  function Snapshot9411($f) {
    $gitDir=Join-Path $f.repo '.git'
    [pscustomobject]@{head=(Git9334 $f.repo @('rev-parse','HEAD'));branchLog=[IO.File]::ReadAllBytes((Join-Path $gitDir "logs/refs/heads/$($f.branch)"));headLog=[IO.File]::ReadAllBytes((Join-Path $gitDir 'logs/HEAD'))}
  }
  function Restore9411($f,$Snapshot) {
    $gitDir=Join-Path $f.repo '.git'
    if((Git9334 $f.repo @('branch','--show-current'))-cne$f.branch){[void](Git9334 $f.repo @('checkout','-q',$f.branch))}
    [void](Git9334 $f.repo @('reset','-q','--hard',$Snapshot.head));[void](Git9334 $f.repo @('clean','-qfd'))
    [IO.File]::WriteAllBytes((Join-Path $gitDir "logs/refs/heads/$($f.branch)"),$Snapshot.branchLog);[IO.File]::WriteAllBytes((Join-Path $gitDir 'logs/HEAD'),$Snapshot.headLog)
  }
  function BaselineModule9411($f) {
    $baseline=Join-Path $f.case 'baseline-9411'
    if(-not(Test-Path -LiteralPath $baseline)){
      [IO.Directory]::CreateDirectory($baseline)|Out-Null
      $archive=Join-Path $f.case 'baseline-9411.zip';[void](Git9334 (Split-Path -Parent $PSScriptRoot) @('archive','--format=zip','-o',$archive,$successorBaselineHead,'.orchestrator'))
      [IO.Compression.ZipFile]::ExtractToDirectory($archive,$baseline)
    }
    return $baseline
  }
  function Completion9411($f,$S,$FW,[int]$Commits,[string]$Name) {
    $completion=Read-RebaseCompletion $f.obligation $f.runtime
    $remoteHead=(Git9334 $f.repo @('ls-remote','--heads','origin',"refs/heads/$($f.branch)")).Split("`t")[0]
    Proof9334 ($null-ne$completion-and$completion.schemaVersion-ceq'landed-integration-rebase-complete/v4'-and$completion.mode-ceq'ORDINARY_OWNER_RELEASE'-and$completion.origin-ceq'successor'-and$completion.executionOwner.launchId-ceq$S.launchId-and$completion.executionLabel-ceq$S.label-and$completion.finishOwner.launchId-ceq$FW.launchId-and$completion.finishLabel-ceq$FW.label-and$completion.predecessorHead-ceq$f.original-and$completion.finishHead-cne$completion.resultHead-and$completion.movementProof.commitCount-eq$Commits-and$completion.resultHead-ceq$remoteHead-and(Git9334 $f.repo @('rev-parse','HEAD'))-ceq$completion.resultHead-and(Git9334 $f.repo @('branch','--show-current'))-ceq$f.branch-and(Git9334 $f.repo @('status','--porcelain=v1','--untracked-files=normal'))-ceq'') "$Name completion/v4 origin=successor binds the prior finish owner, the successor owner, R, P ($Commits granted commits), the original-head lease and remote==P"
    [void](Git9334 $f.repo @('merge-base','--is-ancestor',$completion.finishHead,$completion.resultHead));[void](Git9334 $f.repo @('merge-base','--is-ancestor',$f.onto,$completion.resultHead))
    $baselineModule=Import-Module (Join-Path (BaselineModule9411 $f) '.orchestrator/landed-integration-evidence.psm1') -Force -DisableNameChecking -PassThru
    try { $baselineRead=Refused9411 { & $baselineModule {param($o,$r) Read-RebaseCompletion $o $r -Replay} $f.obligation $f.runtime } }
    finally { Remove-Module $baselineModule -Force; Import-Module (Join-Path $PSScriptRoot 'landed-integration-evidence.psm1') -Force -DisableNameChecking }
    Proof9334 ($baselineRead-cne'UNEXPECTED SUCCESS') "$Name baseline $($successorBaselineHead.Substring(0,8)) reader cannot validate the two-owner completion/v4: '$baselineRead'"
    $mutations=[ordered]@{
      'finish owner extra key'={param($c) $c.finishOwner|Add-Member unknownAuthority $true}
      'finish owner is the successor'={param($c) $c.finishOwner=$c.executionOwner}
      'finish owner launch boolean'={param($c) $c.finishOwner.launchId=$true}
      'finish owner start date-only'={param($c) $c.finishOwner.childStartIdentity='2026-10-01'}
      'finish label boolean'={param($c) $c.finishLabel=$true}
      'missing finish owner'={param($c) $c.PSObject.Properties.Remove('finishOwner')}
      'origin resume on v4'={param($c) $c.origin='resume'}
      'v3 version with successor origin'={param($c) $c.schemaVersion='landed-integration-rebase-complete/v3'}
      'retained successor head moved'={param($c) $v=$c.interruptedIntegration|ConvertFrom-Json -DateKind String;$v.state.attachedHead='f'*40;$c.interruptedIntegration=$v|ConvertTo-Json -Depth 20 -Compress}
      'retained successor nested extra'={param($c) $v=$c.interruptedIntegration|ConvertFrom-Json -DateKind String;$v.sources|Add-Member unknownAuthority $true;$c.interruptedIntegration=$v|ConvertTo-Json -Depth 20 -Compress}
      'retained successor stoppedHead'={param($c) $v=$c.interruptedIntegration|ConvertFrom-Json -DateKind String;$v.state|Add-Member stoppedHead $v.state.attachedHead;$c.interruptedIntegration=$v|ConvertTo-Json -Depth 20 -Compress}
      'retained successor grant identity'={param($c) $v=$c.interruptedIntegration|ConvertFrom-Json -DateKind String;$v.sources.grantIdentity='f'*64;$c.interruptedIntegration=$v|ConvertTo-Json -Depth 20 -Compress}
      'wrong finish identity'={param($c) $c.movementProof.finishIdentity='f'*64}
      'bare R completion'={param($c) $c.resultHead=$c.finishHead;$c.movementProof.rows=@();$c.movementProof.commitCount=0;$c.movementProof.publicationIdentity=$null}
      'date-only native time'={param($c) $c.rebaseProof.startedAt='2026-10-01'}
      'scope widened at completion'={param($c) $c.repairAuthority.grant.repairPaths+= 'synthetic-outside-grant.txt'}
    }
    foreach($case in $mutations.GetEnumerator()){
      $bad=$completion|ConvertTo-Json -Depth 30|ConvertFrom-Json -DateKind String
      & $case.Value $bad
      $refused=$false
      try { & (Get-Module landed-integration-evidence) {param($c,$o,$r) Read-OrdinaryIntegrationCompletion $c $o $r 'git' -Replay} $bad $f.obligation $f.runtime | Out-Null } catch { $refused=$true }
      Proof9334 $refused "$Name valid-P single-variable refusal: $($case.Key)"
    }
    $dayAfter=Read-RebaseCompletion $f.obligation $f.runtime -Replay
    [IO.File]::WriteAllText((Join-Path $f.repo 'later-ordinary.txt'),"later ordinary product movement`n");[void](Git9334 $f.repo @('add','later-ordinary.txt'));[void](Git9334 $f.repo @('commit','-qm','synthetic later ordinary movement'))
    $afterMovement=Read-RebaseCompletion $f.obligation $f.runtime -Replay
    Proof9334 ($dayAfter.resultHead-ceq$completion.resultHead-and(Get-RebaseRecordIdentity $afterMovement)-ceq(Get-RebaseRecordIdentity $completion)-and-not([IO.File]::ReadAllText((Join-Path $f.runtime 'dispatch-log.jsonl')).Contains('rebase-only-continuation/v1'))) "$Name day-after replay and later ordinary movement do not reopen or change the two-owner completion; no PASS or continuation row"
    return $completion
  }
  function PushCount9411($f) {
    $log=Join-Path $f.remote "logs/refs/heads/$($f.branch)"
    if(-not(Test-Path -LiteralPath $log -PathType Leaf)){return @()}
    return @([IO.File]::ReadAllLines($log)|Where-Object{$_.Contains("`tpush")})
  }
  try {
    if ($Carrier -ceq 'ordinary-dispatch') {
      $f=Fixture9334 'dispatch'
      Proof9334 ($f.raw.Count-eq6-and$f.plan.Count-eq5-and$f.raw[5]-ceq$f.original-and($f.plan -join ',')-cne(($f.raw[0..4]) -join ',')) 'F2 graph: raw reverse history is six commits including the merge; the sequencer plan is five picks in a different order'
      $done=@([IO.File]::ReadAllText((Join-Path $f.repo '.git/rebase-merge/done')) -split "`r?`n"|Where-Object{$_-and-not$_.StartsWith('#')});$todo=@([IO.File]::ReadAllText((Join-Path $f.repo '.git/rebase-merge/git-rebase-todo')) -split "`r?`n"|Where-Object{$_-and-not$_.StartsWith('#')})
      $nativePlan=@(@($done)+@($todo)|ForEach-Object{Git9334 $f.repo @('rev-parse',"$(($_ -split ' ')[1])^{commit}")})
      Proof9334 (($nativePlan -join ',')-ceq($f.plan -join ',')) 'native done+todo equals the topo-order no-merges plan, not the raw reverse list'
      $capture=Read-RebaseJson $f.capturePath
      Proof9334 ($capture.schemaVersion-ceq'ordinary-integration-conflict/v1'-and$capture.launchId-ceq$f.prior.launchId-and$capture.owner.childPid-eq$f.prior.childPid-and$capture.owner.childStartIdentity-ceq$f.prior.childStartIdentity-and(@($capture.conflictPaths) -join ',')-ceq'package.json'-and$capture.state.originalHead-ceq$f.original-and$capture.state.onto-ceq$f.onto) 'LIVE first conflict: the helper captured its own ordinary stop under the actual schema-4 owner'
      $events=Events9334 $f $f.seedLabel
      Proof9334 ($events.Count-eq1-and$events[0].item.exit_code-eq2-and$events[0].item.command.Contains('-NoPush *> .codex/integration.log; $code=$LASTEXITCODE; Get-Content .codex/integration.log -Tail 30; exit $code')-and$events[0].item.command.Contains('../runtime/rebase-integration.ps1')) 'actual wrapper/relative-helper/logging/NoPush ordinary first-stop transcript'
      # Baseline arm: the installed controller refuses the actual ordinary stop (F2) and knows no ordinary grammar or obligation (F1).
      $baseline=Join-Path $f.case 'baseline';[IO.Directory]::CreateDirectory($baseline)|Out-Null
      $archive=Join-Path $f.case 'baseline.zip';[void](Git9334 (Split-Path -Parent $PSScriptRoot) @('archive','--format=zip','-o',$archive,$baselineHead,'.orchestrator'))
      [IO.Compression.ZipFile]::ExtractToDirectory($archive,$baseline)
      $baselineModule=Import-Module (Join-Path $baseline '.orchestrator/landed-integration-evidence.psm1') -Force -DisableNameChecking -PassThru
      try {
        $baselineState=$null;try{Get-InterruptedIntegrationState $f.repo|Out-Null;$baselineState='UNEXPECTED SUCCESS'}catch{$baselineState=$_.Exception.Message}
        $baselineCommand=& $baselineModule {param($c,$o,$r) Test-InterruptedIntegrationCommand $c '' $o $r (Join-Path $r 'rebase-integration.ps1')} ([string]$events[0].item.command) $f.obligation $f.runtime
        $baselineSources=$null;try{& $baselineModule {param($o,$r,$l,$id) Get-InterruptedIntegrationSources $o $r $l $id} $f.obligation $f.runtime $f.seedLabel $f.prior.launchId|Out-Null;$baselineSources='UNEXPECTED SUCCESS'}catch{$baselineSources=$_.Exception.Message}
      } finally { Remove-Module $baselineModule -Force; Import-Module (Join-Path $PSScriptRoot 'landed-integration-evidence.psm1') -Force -DisableNameChecking }
      Proof9334 ($baselineState-ceq'INTEGRATION_RESUME_OPERATION: todo/done history mismatch'-and$null-eq$baselineCommand-and$baselineSources.Contains('OWED_REBASE_PROOF_INVALID')) "baseline $($baselineHead.Substring(0,8)) reproduces F2 (todo/done mismatch on the merge graph) and F1 (no ordinary grammar/obligation): state='$baselineState' command=null sources='$baselineSources'"
      $binding=Bind9334 $f
      Proof9334 ($binding.schemaVersion-ceq'interrupted-canonical-integration/v2'-and$binding.sources.conflictSha256-ceq(Get-RebaseHash ([IO.File]::ReadAllBytes($f.capturePath)))-and$null-eq$binding.sources.checkpointSha256-and$binding.sources.attemptId-ceq$f.prior.attemptId-and$binding.state.stoppedCommit-ceq$f.plan[0]-and$binding.state.oldBase-ceq$f.oldBase-and(Test-DispatchInterruptedBindingShape (Read-RebaseJson $f.cfg.resumePath))) 'ordinary v2 binding: capture hash, semantic attempt, first pick stopped, closed shape accepted by ownership'
      $f.cfg.dispatch=Join-Path $baseline '.orchestrator/dispatch-lane.ps1'
      Refusal9334 $f 'immutable baseline launcher refuses the ordinary v2 binding' 'INTEGRATION_RESUME_BINDING'
      $f.cfg.dispatch=Join-Path $PSScriptRoot 'dispatch-lane.ps1'
      ValidPlan9334 $f 'ordinary dead first stop admitted'
      foreach($role in @('review','planning')){Refusal9334 $f "wrong role $role" 'INTEGRATION_RESUME_ROUTE' @('-Dry','-Role',$role)}
      Refusal9334 $f 'Sol off its row-7 slot placement' 'INTEGRATION_RESUME_ROUTE' @('-Dry','-Model','gpt-6.1-sol')
      ValidPlan9334 $f 'current row-7 codex slot codex/gpt-6.1-sol/high/7/provisional admitted for the ordinary variant' @('-Dry','-Model','gpt-6.1-sol','-Placement','provisional')
      ValidPlan9334 $f 'current row-7 claude slot claude/claude-opus-5-5/xhigh/7/provisional admitted for the ordinary variant' @('-Dry','-Harness','claude','-Model','claude-opus-5-5','-Effort','xhigh','-Placement','provisional')
      ValidPlan9334 $f '8063 claude/claude-fable-5-1/high/7/override-Todd fallback route admitted for the ordinary variant' @('-Dry','-Harness','claude','-Model','claude-fable-5-1')
      $f.cfg.semanticAttemptId='synthetic-other-attempt'
      Refusal9334 $f 'foreign semantic attempt' 'INTEGRATION_RESUME_BINDING: semantic attempt mismatch'
      $f.cfg.semanticAttemptId=$f.prior.attemptId
      ValidPlan9334 $f 'same semantic attempt admitted'
      $f.cfg.semanticAttemptId=''
      foreach($section in @('obligation','sources','state')){
        $bad=$binding|ConvertTo-Json -Depth 15|ConvertFrom-Json -DateKind String;$bad.$section|Add-Member -NotePropertyName unknownAuthority -NotePropertyValue $true;Save9334 $f.cfg.resumePath $bad
        Refusal9334 $f "closed nested $section" 'INTEGRATION_RESUME_BINDING'
      }
      Save9334 $f.cfg.resumePath $binding
      $stateMutant=Mutant9334 'ordinary-fingerprint' 'landed-integration-evidence.psm1' (GuardLine9334 'landed-integration-evidence.psm1' 'INTEGRATION_RESUME_STATE: ordinary input bytes stale or unrelated') '  # Synthetic omission: exact ordinary input fingerprint comparison.'
      foreach($field in @('metadataSha256','indexSha256','stagesSha256','dirtySha256','stagedSha256','unstagedSha256','stoppedCommit')){
        $bad=$binding|ConvertTo-Json -Depth 15|ConvertFrom-Json -DateKind String;$bad.state.$field=$(if($field-ceq'stoppedCommit'){'b'*40}else{'b'*64});Save9334 $f.cfg.resumePath $bad
        Discriminator9334 $f "ordinary $field binding" 'INTEGRATION_RESUME_STATE' $stateMutant
      }
      Save9334 $f.cfg.resumePath $binding
      $sourceMutant=Mutant9334 'ordinary-source-binding' 'landed-integration-evidence.psm1' (GuardLine9334 'landed-integration-evidence.psm1' 'INTEGRATION_RESUME_SOURCE: ordinary binding changed') '  # Synthetic omission: ordinary source bytes comparison.'
      foreach($field in @('watchdogSha256','promptSha256','transcriptSha256','routingIdentity','conflictSha256')){
        $bad=$binding|ConvertTo-Json -Depth 15|ConvertFrom-Json -DateKind String;$bad.sources.$field='b'*64;Save9334 $f.cfg.resumePath $bad
        Discriminator9334 $f "ordinary exact source $field" 'INTEGRATION_RESUME_SOURCE' $sourceMutant
      }
      Save9334 $f.cfg.resumePath $binding
      $remoteMutant=Mutant9334 'ordinary-remote' 'landed-integration-evidence.psm1' (GuardLine9334 'landed-integration-evidence.psm1' 'INTEGRATION_RESUME_REMOTE: ordinary original branch/PR moved') '    # Synthetic omission: ordinary original remote equality.'
      $older=Git9334 $f.repo @('rev-parse',"$($f.original)^")
      [void](Git9334 $f.remote @('update-ref',"refs/heads/$($f.branch)",$older))
      try{Discriminator9334 $f 'ordinary exact remote branch' 'INTEGRATION_RESUME_REMOTE' $remoteMutant}finally{[void](Git9334 $f.remote @('update-ref',"refs/heads/$($f.branch)",$f.original))}
      $planMutant=Mutant9334 'ordinary-native-plan' 'landed-integration-evidence.psm1' "@('rev-list','--reverse','--topo-order','--no-merges'," "@('rev-list','--reverse',"
      if($planMutant){
        $candidatePath=$f.cfg.dispatch
        try{$f.cfg.dispatch=$planMutant;Refusal9334 $f 'raw reverse-history plan (F2 omission) kills the actual merge-graph positive' 'INTEGRATION_RESUME_OPERATION: todo/done history mismatch'}finally{$f.cfg.dispatch=$candidatePath;Save9334 $f.config $f.cfg}
      }
      $deathMutant=Mutant9334 'ordinary-prior-tree-death' 'landed-integration-evidence.psm1' 'function Assert-InterruptedIntegrationTreeDead($Owner) {' "function Assert-InterruptedIntegrationTreeDead(`$Owner) {`n  return # Synthetic omission: actual prior tree death."
      $wpath=Join-Path $f.runtime "watchdog-lane-$($f.seedLabel).json";$originalWatchdog=[IO.File]::ReadAllBytes($wpath);$originalCapture=[IO.File]::ReadAllBytes($f.capturePath)
      try{
        $actualStart=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
        $live=Read-RebaseJson $wpath;$live.launcherPid=[long]$PID;$live.launcherStartIdentity=$actualStart;Save9334 $wpath $live
        Refusal9334 $f 'altered prior OS identity source' 'INTEGRATION_RESUME_SOURCE'
        # The helper capture joins the same owner identities; tamper it consistently so only the death guard discriminates.
        $liveCapture=Read-RebaseJson $f.capturePath;$liveCapture.owner.launcherPid=[long]$PID;$liveCapture.owner.launcherStartIdentity=$actualStart;Save9334 $f.capturePath $liveCapture
        $liveInput=$binding|ConvertTo-Json -Depth 15|ConvertFrom-Json -DateKind String;$liveInput.sources.watchdogSha256=Get-RebaseHash ([IO.File]::ReadAllBytes($wpath));$liveInput.sources.conflictSha256=Get-RebaseHash ([IO.File]::ReadAllBytes($f.capturePath));Save9334 $f.cfg.resumePath $liveInput
        Discriminator9334 $f 'exact-identity live ordinary root is not death' 'INTEGRATION_RESUME_PRIOR_OWNER: live root' $deathMutant
      }finally{[IO.File]::WriteAllBytes($wpath,$originalWatchdog);[IO.File]::WriteAllBytes($f.capturePath,$originalCapture);Save9334 $f.cfg.resumePath $binding}
      $replayMutant=Mutant9334 'ordinary-native-proof' 'landed-integration-evidence.psm1' '    Assert-InterruptedIntegrationReplay $o $firstStop # ORDINARY_RESUME_GUARD_NATIVE_REPLAY' '    # Synthetic omission: independent ordinary native replay.'
      $staged=Fixture9334 'staged'
      Remove-Item -LiteralPath $staged.capturePath -Force # historical variant: no helper capture, transcript proves the first stop
      [IO.File]::AppendAllText((Join-Path $staged.repo 'README.md'),"unrelated staged mutation`n");[void](Git9334 $staged.repo @('add','--','README.md'))
      $stagedBinding=[ordered]@{schemaVersion='interrupted-canonical-integration/v2';obligation=$staged.obligation;sources=$null;state=(Get-InterruptedIntegrationState $staged.repo)}
      $module=Get-Module|Where-Object{$_.Path-eq(Join-Path $PSScriptRoot 'landed-integration-evidence.psm1')}|Select-Object -First 1
      $stagedSources=& $module {param($o,$r,$l,$id) Get-OrdinaryIntegrationSources $o $r $l $id} $staged.obligation $staged.runtime $staged.seedLabel $staged.prior.launchId
      $stagedBinding.sources=$stagedSources.binding
      $staged.cfg.resumePath=Join-Path $staged.runtime 'resume-input.json';Save9334 $staged.cfg.resumePath $stagedBinding;Save9334 $staged.config $staged.cfg
      Proof9334 ($null-eq$stagedBinding.sources.conflictSha256-and(@($stagedSources.conflict.conflictPaths) -join ',')-ceq'package.json') 'historical ordinary route binds the transcript conflict when no helper capture exists'
      Discriminator9334 $staged 'staged nonconflict bytes cannot become ordinary capture authority' 'INTEGRATION_RESUME_NATIVE_PROOF' $replayMutant
      $historical=Fixture9334 'historical'
      Remove-Item -LiteralPath $historical.capturePath -Force
      $historicalBinding=Bind9334 $historical
      Proof9334 ($null-eq$historicalBinding.sources.conflictSha256) 'historical ordinary stop (no capture, like 9285) binds through transcript grammar plus native replay'
      ValidPlan9334 $historical 'historical ordinary first stop admitted'
      $transcriptPath=Join-Path $historical.runtime "$($historical.seedLabel).jsonl";$transcriptBytes=[IO.File]::ReadAllBytes($transcriptPath)
      $grammarMutant=Mutant9334 'ordinary-helper-identity' 'landed-integration-evidence.psm1' (GuardLine9334 'landed-integration-evidence.psm1' 'ORDINARY_HELPER_RELATIVE_TO_BOUND_WORKTREE') "    `$helperPath = Join-Path `$Runtime 'rebase-integration.ps1' # Synthetic omission: any relative helper counts as canonical."
      try{
        $copied=[Text.Encoding]::UTF8.GetString($transcriptBytes).Replace('../runtime/rebase-integration.ps1','../copied/rebase-integration.ps1')
        [IO.File]::WriteAllText($transcriptPath,$copied,[Text.UTF8Encoding]::new($false))
        $copiedInput=$historicalBinding|ConvertTo-Json -Depth 15|ConvertFrom-Json -DateKind String;$copiedInput.sources.transcriptSha256=Get-RebaseHash ([IO.File]::ReadAllBytes($transcriptPath));Save9334 $historical.cfg.resumePath $copiedInput
        Discriminator9334 $historical 'copied relative helper cannot claim the canonical ordinary helper' 'INTEGRATION_RESUME_SOURCE: ordinary helper conflict absent or ambiguous' $grammarMutant
        $contradiction=[Text.Encoding]::UTF8.GetString($transcriptBytes)+([ordered]@{type='item.completed';item=[ordered]@{id='synthetic-later';type='command_execution';command='git rebase --continue';aggregated_output='Successfully rebased';exit_code=[long]0;status='completed'}}|ConvertTo-Json -Depth 8 -Compress)+"`n"
        [IO.File]::WriteAllText($transcriptPath,$contradiction,[Text.UTF8Encoding]::new($false))
        $contradictionInput=$historicalBinding|ConvertTo-Json -Depth 15|ConvertFrom-Json -DateKind String;$contradictionInput.sources.transcriptSha256=Get-RebaseHash ([IO.File]::ReadAllBytes($transcriptPath));Save9334 $historical.cfg.resumePath $contradictionInput
        Refusal9334 $historical 'later native movement in the transcript contradicts a preserved first stop' 'INTEGRATION_RESUME_SOURCE: contradictory later movement'
      }finally{[IO.File]::WriteAllBytes($transcriptPath,$transcriptBytes);Save9334 $historical.cfg.resumePath $historicalBinding}
      ValidPlan9334 $f 'original ordinary fixture after independent destructive controls'
      # Actual resumed owner: early publication refused, finish R under -NoPush, bare R refused, one repair/test commit, leased publication P, duplicate refused.
      $entryState=Get-InterruptedIntegrationState $f.repo
      $f.cfg.earlyPublish=$true;$f.cfg.barePublish=$true;$f.cfg.duplicatePublish=$true
      $run=Launch9334 $f
      Proof9334 ($run.exit-eq0-and(Test-Path -LiteralPath $f.cfg.entry)) "resumed ordinary child finished and published exit=$($run.exit) raw=$($run.resultPath)"
      $entry=Read-RebaseJson $f.cfg.entry
      Proof9334 ((Get-RebaseRecordIdentity $entry)-ceq(Get-RebaseRecordIdentity $entryState)) 'complete raw index/stages/staged/unstaged/metadata entry equality for the ordinary resume'
      $resumeWatchdog=Read-RebaseJson (Join-Path $f.runtime "watchdog-lane-$($f.cfg.label).json")
      Proof9334 ($resumeWatchdog.schemaVersion-ceq'watchdog-lane/v4'-and$resumeWatchdog.interruptedIntegration-ceq($binding|ConvertTo-Json -Depth 12 -Compress)-and$resumeWatchdog.attemptId-ceq$f.prior.attemptId-and$resumeWatchdog.resumeOfLaunchId-ceq$f.prior.launchId) 'closed ordinary binding and semantic attempt retained through watchdog exit'
      $resumeEvents=Events9334 $f $f.cfg.label
      $publishEvents=@($resumeEvents|Where-Object{$_.item.command.Contains('-PublishInterruptedIntegration')})
      $continueEvents=@($resumeEvents|Where-Object{$_.item.command.Contains('-ContinueInterruptedIntegration')})
      Proof9334 ($publishEvents.Count-eq4-and$publishEvents[0].item.exit_code-eq1-and$publishEvents[0].item.aggregated_output.Contains('finish proof required')-and$publishEvents[1].item.exit_code-eq1-and$publishEvents[1].item.aggregated_output.Contains('bare finish result')-and$publishEvents[2].item.exit_code-eq0-and$publishEvents[2].item.aggregated_output.Contains('"pushed":true')-and$publishEvents[3].item.exit_code-eq1-and$publishEvents[3].item.aggregated_output.Contains('already published')-and$continueEvents.Count-eq2-and$continueEvents[0].item.exit_code-eq1-and$continueEvents[0].item.aggregated_output.Contains('ordinary continuation requires NoPush')-and$continueEvents[1].item.exit_code-eq0-and$continueEvents[1].item.aggregated_output.Contains('"pushed":false')) 'early publication, bare R publication, missing NoPush and duplicate publication refuse; NoPush finish then one leased publication succeed'
      $finish=Read-RebaseJson (Join-Path $f.runtime "integration-resume-finish-$($resumeWatchdog.launchId).json")
      $publication=Read-RebaseJson (Join-Path $f.runtime "integration-resume-publication-$($resumeWatchdog.launchId).json")
      Proof9334 ($finish.pushed-eq$false-and$finish.bindingIdentity-ceq(Get-RebaseRecordIdentity (Read-RebaseJson $f.cfg.resumePath))-and$publication.finishHead-ceq$finish.resultHead-and$publication.leaseExpectedHead-ceq$f.original-and$publication.commitCount-eq1-and(@($publication.changedPaths) -join ',')-ceq'synthetic-repair.test.txt,synthetic-repair.txt') 'finish R and publication P records bind the exact binding, lease and plain-commit movement'
      $completion=Completion9334 $f 'resume' 'ordinary resumed'
      Proof9334 ($completion.movementProof.publicationIdentity-ceq(Get-RebaseRecordIdentity $publication)-and$completion.movementProof.finishIdentity-ceq(Get-RebaseRecordIdentity $finish)) 'completion binds the finish and publication identities'
      # Single-variable negatives, each on its own stopped repository.
      foreach($violation in @('outside','edit-then-revert','unicode-alias')){
        $scoped=Fixture9334 $violation;[void](Bind9334 $scoped);$scoped.cfg.scopeViolation=$violation;$scoped.cfg.expectRefusal='INTEGRATION_RESUME_SCOPE: commit outside FINAL grant'
        $run=Launch9334 $scoped
        Proof9334 ($run.exit-ne0-and$run.stderr.Contains('finished unpublished')-and(Git9334 $scoped.remote @('rev-parse',"refs/heads/$($scoped.branch)"))-ceq$scoped.original-and$null-eq(Read-RebaseCompletion $scoped.obligation $scoped.runtime)) "FINAL scope ${violation}: publication refused before push; remote unchanged; no completion raw=$($run.resultPath)"
      }
      $unpublished=Fixture9334 'unpublished';[void](Bind9334 $unpublished);$unpublished.cfg.finishOnly=$true
      $run=Launch9334 $unpublished
      $unpublishedWatchdog=Read-RebaseJson (Join-Path $unpublished.runtime "watchdog-lane-$($unpublished.cfg.label).json")
      $unpublishedFinish=Read-RebaseJson (Join-Path $unpublished.runtime "integration-resume-finish-$($unpublishedWatchdog.launchId).json")
      Proof9334 ($run.exit-ne0-and$run.stderr.Contains('INTEGRATION_RESUME_COMPLETION: finished unpublished')-and$unpublishedWatchdog.exitCode-eq1-and$unpublishedWatchdog.state-ceq'exited'-and$unpublishedFinish.pushed-eq$false-and$null-eq(Read-RebaseCompletion $unpublished.obligation $unpublished.runtime)-and(Git9334 $unpublished.repo @('rev-parse','HEAD'))-ceq$unpublishedFinish.resultHead-and(Git9334 $unpublished.repo @('branch','--show-current'))-ceq$unpublished.branch-and(Git9334 $unpublished.remote @('rev-parse',"refs/heads/$($unpublished.branch)"))-ceq$unpublished.original-and-not(Test-Path (Join-Path $unpublished.runtime "integration-rebase-complete-$(Get-RebaseObligationIdentity $unpublished.obligation).json"))) "finished-unpublished: finish R recorded, launcher refuses completion (recorded exit 1 as for landed resumes), no completion/ack, remote still at original head raw=$($run.resultPath)"
      $lease=Fixture9334 'lease';[void](Bind9334 $lease);$lease.cfg.leaseMismatch=$true;$lease.cfg.expectRefusal='INTEGRATION_RESUME_PUBLICATION: lease/remote mismatch'
      $run=Launch9334 $lease
      $leaseOlder=Git9334 $lease.repo @('rev-parse',"$($lease.original)^")
      Proof9334 ($run.exit-ne0-and$run.stderr.Contains('finished unpublished')-and(Git9334 $lease.remote @('rev-parse',"refs/heads/$($lease.branch)"))-ceq$leaseOlder-and$null-eq(Read-RebaseCompletion $lease.obligation $lease.runtime)-and-not(Test-Path (Join-Path $lease.runtime "integration-resume-publication-$((Read-RebaseJson (Join-Path $lease.runtime "watchdog-lane-$($lease.cfg.label).json")).launchId).json"))) "lease mismatch: publication refused, moved remote untouched, local P preserved, no completion raw=$($run.resultPath)"
      $amend=Fixture9334 'amend';[void](Bind9334 $amend);$amend.cfg.movement='amend-finish';$amend.cfg.expectRefusal='INTEGRATION_RESUME_PUBLICATION: result is not a descendant of the finish'
      $run=Launch9334 $amend
      Proof9334 ($run.exit-ne0-and$run.stderr.Contains('finished unpublished')-and(Git9334 $amend.remote @('rev-parse',"refs/heads/$($amend.branch)"))-ceq$amend.original-and$null-eq(Read-RebaseCompletion $amend.obligation $amend.runtime)) "non-descendant (amended finish): publication refused, remote at original head, no completion raw=$($run.resultPath)"
      $foreign=Fixture9334 'foreign';[void](Bind9334 $foreign);$foreign.cfg.movement='reset';$foreign.cfg.expectRefusal='INTEGRATION_RESUME_PUBLICATION: unrelated movement after finish'
      $run=Launch9334 $foreign
      Proof9334 ($run.exit-ne0-and$run.stderr.Contains('finished unpublished')-and(Git9334 $foreign.remote @('rev-parse',"refs/heads/$($foreign.branch)"))-ceq$foreign.original-and$null-eq(Read-RebaseCompletion $foreign.obligation $foreign.runtime)) "foreign movement (reset/rewrite): publication refused, remote at original head, no completion raw=$($run.resultPath)"
      $finished=$true
      return
    }
    if ($Carrier -ceq 'ordinary-rebase') {
      # LIVE lane: the same ordinary child captures, continues under -NoPush, commits and publishes; the launcher completes origin=live.
      $live=Fixture9334 'live' -Live
      Proof9334 ($live.seed.exit-eq0-and(Test-Path -LiteralPath $live.capturePath)) "live ordinary lane exit=$($live.seed.exit) with helper capture raw=$($live.seed.resultPath)"
      $liveEvents=Events9334 $live $live.seedLabel
      Proof9334 ($liveEvents.Count-eq4-and$liveEvents[0].item.exit_code-eq2-and$liveEvents[1].item.command.Contains('-ContinueInterruptedIntegration')-and$liveEvents[1].item.exit_code-eq1-and$liveEvents[1].item.aggregated_output.Contains('ordinary continuation requires NoPush')-and$liveEvents[2].item.exit_code-eq0-and$liveEvents[3].item.command.Contains('-PublishInterruptedIntegration')-and$liveEvents[3].item.exit_code-eq0) 'live ordinary child: wrapper first stop, missing NoPush refusal, NoPush continuation, leased publication'
      [void](Completion9334 $live 'live' 'ordinary live')
      # Second real conflict after readmission: checkpoint, stale refusal, fresh v4 chain, readmission, publication.
      $r=Fixture9334 'retained' -SecondStop
      $first=Bind9334 $r
      $run=Launch9334 $r
      $watchdog=Read-RebaseJson (Join-Path $r.runtime "watchdog-lane-$($r.cfg.label).json")
      $checkpointPath=Join-Path $r.runtime "integration-resume-stop-$($watchdog.launchId).json"
      Proof9334 ($run.exit-eq2-and-not(Git9334 $r.repo @('branch','--show-current'))-and(Test-Path -LiteralPath $checkpointPath)-and[IO.File]::ReadAllText((Join-Path $r.repo '.git/rebase-merge/msgnum')).Trim()-ceq'3') "second real conflict stays detached at pick 3 with a checkpoint under the resumed owner raw=$($run.resultPath)"
      Remove-Item -LiteralPath $r.cfg.entry -Force
      $r.cfg.label+='-stale';$oldPrompt=$r.cfg.prompt;$r.cfg.prompt=Join-Path $r.runtime "$($r.cfg.label).prompt.txt";[IO.File]::WriteAllText($r.cfg.prompt,[IO.File]::ReadAllText($oldPrompt))
      Refusal9334 $r 'stale ordinary snapshot after next conflict' 'INTEGRATION_RESUME_STATE'
      $next=New-InterruptedIntegrationResume $r.obligation $r.runtime $watchdog.label $watchdog.launchId
      $checkpoint=Read-RebaseJson $checkpointPath
      Proof9334 ($next.schemaVersion-ceq'interrupted-canonical-integration/v2'-and$next.sources.priorLaunchId-ceq$watchdog.launchId-and$next.sources.checkpointSha256-ceq(Get-RebaseHash ([IO.File]::ReadAllBytes($checkpointPath)))-and$next.sources.attemptId-ceq$first.sources.attemptId-and$checkpoint.bindingIdentity-ceq(Get-RebaseRecordIdentity (Read-RebaseJson $r.cfg.resumePath))-and(Get-RebaseRecordIdentity $next.state)-ceq(Get-RebaseRecordIdentity $checkpoint.state)) 'fresh ordinary retry binds the v4 chain, exact checkpoint and the same semantic attempt'
      $r.binding=$next;Save9334 $r.cfg.resumePath $next;$r.cfg.label+='-next';$r.cfg.prompt=Join-Path $r.runtime "$($r.cfg.label).prompt.txt";[IO.File]::WriteAllText($r.cfg.prompt,[IO.File]::ReadAllText($oldPrompt))
      ValidPlan9334 $r 'fresh ordinary checkpoint admitted'
      $nextRun=Launch9334 $r
      Proof9334 ($nextRun.exit-eq0) "ordinary readmission finishes and publishes raw=$($nextRun.resultPath)"
      $nextWatchdog=Read-RebaseJson (Join-Path $r.runtime "watchdog-lane-$($r.cfg.label).json")
      Proof9334 ($nextWatchdog.resumeOfLaunchId-ceq$watchdog.launchId-and$nextWatchdog.attemptId-ceq$first.sources.attemptId-and$nextWatchdog.interruptedIntegration-ceq($next|ConvertTo-Json -Depth 12 -Compress)) 'retry watchdog retains the fresh binding, lineage and semantic attempt'
      [void](Completion9334 $r 'resume' 'ordinary retained retry')
      $finished=$true
      return
    }
    if ($Carrier -ceq 'ordinary-watchdog') {
      $f=Fixture9334 'watchdog'
      [void](Bind9334 $f)
      $run=Launch9334 $f
      Proof9334 ($run.exit-eq0) "ordinary resume for watchdog observation completes raw=$($run.resultPath)"
      [void](Completion9334 $f 'resume' 'ordinary watchdog-observed')
      $watch=Native9334 (Join-Path $PSScriptRoot 'lane-stall-watchdog.ps1') @('-Label',$f.cfg.label,'-RuntimeRoot',$f.runtime,'-HistoryPath',(Join-Path $f.runtime 'dispatch-log.jsonl'))
      Proof9334 ($watch.exit-eq0-and$watch.stdout.Contains('TERMINAL_SUCCESS')-and$watch.stdout.Contains('"relaunch":false')) "actual retained watchdog validates the ordinary v3 completion without launch raw=$($watch.resultPath)"
      $finished=$true
      return
    }
    if ($Carrier -ceq 'successor-rebase') {
      # AC1 producer, AC5 producer negatives and AC3 two-launch publication.
      $f=Fixture9334 'successor'
      $prior=Finish9411 $f -Commit
      $FW=$prior.watchdog;$R=$prior.finish.resultHead;$P1=Git9334 $f.repo @('rev-parse','HEAD')
      Proof9334 ($P1-cne$R-and(Git9334 $f.repo @('rev-parse',"$P1^"))-ceq$R) 'prior made exactly one granted plain commit R->P1 before its declared exit'
      # Failing-first: the installed baseline has no successor producer.
      $baseline=BaselineModule9411 $f
      $baselineModule=Import-Module (Join-Path $baseline '.orchestrator/landed-integration-evidence.psm1') -Force -DisableNameChecking -PassThru
      try { $baselineResult=Refused9411 { & $baselineModule {param($o,$r,$l,$id) New-InterruptedIntegrationResume $o $r $l $id} $f.obligation $f.runtime $FW.label $FW.launchId } }
      finally { Remove-Module $baselineModule -Force; Import-Module (Join-Path $PSScriptRoot 'landed-integration-evidence.psm1') -Force -DisableNameChecking }
      Proof9334 ($baselineResult-ceq'INTEGRATION_RESUME_OPERATION: detached canonical root required') "baseline $($successorBaselineHead.Substring(0,8)) strands the finished-unpublished state: '$baselineResult'"
      $automatic=Refused9411 { New-InterruptedIntegrationResume $f.obligation $f.runtime $FW.label $FW.launchId }
      Proof9334 ($automatic-ceq'INTEGRATION_RESUME_SUCCESSOR: finished-unpublished successor is host-dispatched only') 'automatic (watchdog) producer refuses the attached finished-unpublished state'
      $rawBefore=RawState9334 $f;$runtimeBefore=RuntimeState9334 $f
      $binding=Produce9411 $f $FW
      Proof9334 ($binding.schemaVersion-ceq'interrupted-canonical-integration/v3'-and$binding.sources.priorLaunchId-ceq$FW.launchId-and$binding.sources.finishLaunchId-ceq$FW.launchId-and$binding.sources.finishLabel-ceq$FW.label-and
        $binding.sources.finishSha256-ceq(Get-RebaseHash ([IO.File]::ReadAllBytes($prior.finishPath)))-and$binding.sources.attemptId-ceq$f.prior.attemptId-and
        $binding.sources.ackSha256-ceq(Get-RebaseHash ([IO.File]::ReadAllBytes((Join-Path $f.runtime "dispatch-start-$(Get-RebaseRecordIdentity (Read-RebaseJson $f.cfg.resumePath)).json"))))-and
        $binding.state.finishHead-ceq$R-and$binding.state.attachedHead-ceq$P1-and-not$binding.state.Contains('stoppedHead')-and
        (Test-DispatchInterruptedBindingShape ($binding|ConvertTo-Json -Depth 15|ConvertFrom-Json -DateKind String))-and(RawState9334 $f)-ceq$rawBefore-and(RuntimeState9334 $f)-ceq$runtimeBefore) 'AC1 closed v3 binding: retained finish/start-ack/watchdog/prompt/grant, attached P1 after one granted commit, no stoppedHead; no target byte or retained record rewritten'
      $identity=Identity9411 $binding
      # AC5 producer negatives: each single variable, restored, refused before any push.
      $remoteBefore=Git9334 $f.remote @('rev-parse',"refs/heads/$($f.branch)")
      $finishBytes=[IO.File]::ReadAllBytes($prior.finishPath);$watchdogPath=Join-Path $f.runtime "watchdog-lane-$($FW.label).json";$watchdogBytes=[IO.File]::ReadAllBytes($watchdogPath)
      $promptPath=$FW.originalPromptPath;$promptBytes=[IO.File]::ReadAllBytes($promptPath)
      $publicationPath=Join-Path $f.runtime "integration-resume-publication-$($FW.launchId).json";$completionPath=Join-Path $f.runtime "integration-rebase-complete-$(Get-RebaseObligationIdentity $f.obligation).json"
      $snapshot=Snapshot9411 $f
      $cases=@(
        @{name='pushed:true finish';reason='INTEGRATION_RESUME_SUCCESSOR: pushed finish forbidden';mutate={$v=Read-RebaseJson $prior.finishPath;$v.pushed=$true;Save9334 $prior.finishPath $v};restore={[IO.File]::WriteAllBytes($prior.finishPath,$finishBytes)}}
        @{name='altered finish binding';reason='INTEGRATION_RESUME_PUBLICATION: finish proof binding';mutate={$v=Read-RebaseJson $prior.finishPath;$v.bindingIdentity='f'*64;Save9334 $prior.finishPath $v};restore={[IO.File]::WriteAllBytes($prior.finishPath,$finishBytes)}}
        @{name='missing finish';reason='INTEGRATION_RESUME_SUCCESSOR: retained finish required';mutate={Remove-Item -LiteralPath $prior.finishPath -Force};restore={[IO.File]::WriteAllBytes($prior.finishPath,$finishBytes)}}
        @{name='contradictory causality: finish after the prior exit';reason='INTEGRATION_RESUME_SUCCESSOR: finish after prior exit';mutate={$v=Read-RebaseJson $prior.finishPath;$v.finishedAt=([datetimeoffset]$FW.updatedAt).AddSeconds(1).ToString('o');Save9334 $prior.finishPath $v};restore={[IO.File]::WriteAllBytes($prior.finishPath,$finishBytes)}}
        @{name='live or premature prior (watchdog still running)';reason='INTEGRATION_RESUME_SUCCESSOR: exited retained resume launch required';mutate={$v=Read-RebaseJson $watchdogPath;$v.state='running';$v.exitCode=$null;Save9334 $watchdogPath $v};restore={[IO.File]::WriteAllBytes($watchdogPath,$watchdogBytes)}}
        @{name='prior prompt without the host FINAL grant';reason='INTEGRATION_RESUME_SCOPE: exact host FINAL grant required';mutate={[IO.File]::WriteAllText($promptPath,'Synthetic prompt without a grant.')};restore={[IO.File]::WriteAllBytes($promptPath,$promptBytes)}}
        @{name='existing prior publication record (synthetic control)';reason='INTEGRATION_RESUME_SUCCESSOR: publication exists';mutate={[IO.File]::WriteAllText($publicationPath,'{}')};restore={Remove-Item -LiteralPath $publicationPath -Force}}
        @{name='existing completion (synthetic control)';reason='INTEGRATION_RESUME_SUCCESSOR: completion exists';mutate={[IO.File]::WriteAllText($completionPath,'{}')};restore={Remove-Item -LiteralPath $completionPath -Force}}
        @{name='dirty worktree';reason='INTEGRATION_RESUME_SUCCESSOR: clean attached obligation branch required';mutate={[IO.File]::WriteAllText((Join-Path $f.repo 'synthetic-dirty.txt'),"dirty`n")};restore={Restore9411 $f $snapshot}}
        @{name='detached worktree';reason='INTEGRATION_RESUME_SUCCESSOR: attached finished-unpublished state required';mutate={[void](Git9334 $f.repo @('checkout','-q','--detach'))};restore={Restore9411 $f $snapshot}}
        @{name='moved remote branch';reason='INTEGRATION_RESUME_REMOTE: ordinary successor branch/PR moved';mutate={[void](Git9334 $f.remote @('update-ref',"refs/heads/$($f.branch)",(Git9334 $f.repo @('rev-parse',"$($f.original)^"))))};restore={[void](Git9334 $f.remote @('update-ref',"refs/heads/$($f.branch)",$f.original))}}
        @{name='moved PR head';reason='INTEGRATION_RESUME_REMOTE: ordinary successor branch/PR moved';mutate={[void](Git9334 $f.remote @('update-ref',"refs/pull/$($f.pr)/head",(Git9334 $f.repo @('rev-parse',"$($f.original)^"))))};restore={[void](Git9334 $f.remote @('update-ref',"refs/pull/$($f.pr)/head",$f.original))}}
        @{name='pushed-unrecorded remote==HEAD with no record';reason='INTEGRATION_RESUME_SUCCESSOR: pushed unrecorded; no second push';mutate={[void](Git9334 $f.remote @('fetch','-q',$f.repo,"refs/heads/$($f.branch):refs/synthetic/9411-p1"));[void](Git9334 $f.remote @('update-ref',"refs/heads/$($f.branch)",$P1))};restore={[void](Git9334 $f.remote @('update-ref',"refs/heads/$($f.branch)",$f.original));[void](Git9334 $f.remote @('update-ref','-d','refs/synthetic/9411-p1'))}}
        @{name='reset after the finish';reason='INTEGRATION_RESUME_PUBLICATION: unrelated movement after finish';mutate={[void](Git9334 $f.repo @('reset','-q','--soft','HEAD~1'));[void](Git9334 $f.repo @('commit','-qm','synthetic rewritten repair'))};restore={Restore9411 $f $snapshot}}
        @{name='rebase after the finish';reason='INTEGRATION_RESUME_PUBLICATION: unrelated movement after finish';mutate={[IO.File]::AppendAllText((Join-Path $f.repo 'synthetic-repair.txt'),"granted`n");[void](Git9334 $f.repo @('commit','-qam','synthetic granted'));$env:GIT_COMMITTER_DATE='2026-10-05T00:00:00Z';try{[void](Git9334 $f.repo @('-c','core.editor=true','rebase','-q','--force-rebase','HEAD~1'))}finally{Remove-Item Env:GIT_COMMITTER_DATE};if((Git9334 $f.repo @('reflog','-1','--format=%gs',"refs/heads/$($f.branch)")) -cnotmatch '^rebase'){throw '9411 rebase control did not rewrite the branch'}};restore={Restore9411 $f $snapshot}}
        @{name='out-of-grant commit after the finish';reason='INTEGRATION_RESUME_SCOPE: commit outside FINAL grant';mutate={[IO.File]::WriteAllText((Join-Path $f.repo 'synthetic-outside-grant.txt'),"outside`n");[void](Git9334 $f.repo @('add','synthetic-outside-grant.txt'));[void](Git9334 $f.repo @('commit','-qm','synthetic outside grant'))};restore={Restore9411 $f $snapshot}}
      )
      foreach($case in $cases){
        $refusal=$null
        try { & $case.mutate; $refusal=Refused9411 { Produce9411 $f $FW } } finally { & $case.restore }
        Proof9334 ($refusal.Contains($case.reason)-and(Git9334 $f.remote @('rev-parse',"refs/heads/$($f.branch)"))-ceq$remoteBefore) "AC5 producer refusal before any push: $($case.name) ('$refusal')"
      }
      Proof9334 ((Identity9411 (Produce9411 $f $FW))-ceq$identity-and(Git9334 $f.repo @('rev-parse','HEAD'))-ceq$P1-and(Git9334 $f.repo @('status','--porcelain=v1','--untracked-files=normal'))-ceq'') 'restored inputs reproduce the identical binding (finish, ack, watchdog, grant, branch reflog, tree): history kept'
      # Independent guard omissions (in-process producer from a mutated controller copy).
      foreach($guard in @(
        @{name='successor-all-owners-dead';marker='SUCCESSOR_GUARD_ALL_OWNERS_DEAD';replacement='  # Synthetic omission: every chain owner tree-dead.';reason='INTEGRATION_RESUME_PRIOR_OWNER: live root';mutate={$v=Read-RebaseJson $watchdogPath;$v.launcherPid=[long]$PID;$v.launcherStartIdentity=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o');Save9334 $watchdogPath $v};restore={[IO.File]::WriteAllBytes($watchdogPath,$watchdogBytes)}}
        @{name='successor-single-publication';marker='function Assert-OrdinarySuccessorVacancy';replacement="function Assert-OrdinarySuccessorVacancy(`$Obligation,[string]`$Runtime,`$Evidence) {`n  return # Synthetic omission: publication/completion/latest census.";reason='INTEGRATION_RESUME_SUCCESSOR: publication exists';mutate={[IO.File]::WriteAllText($publicationPath,'{}')};restore={Remove-Item -LiteralPath $publicationPath -Force}}
        @{name='successor-remote-lease';marker='SUCCESSOR_GUARD_REMOTE_LEASE';replacement='    # Synthetic omission: original-head remote/PR lease.';reason='INTEGRATION_RESUME_SUCCESSOR: pushed unrecorded; no second push';mutate={[void](Git9334 $f.remote @('fetch','-q',$f.repo,"refs/heads/$($f.branch):refs/synthetic/9411-p1"));[void](Git9334 $f.remote @('update-ref',"refs/heads/$($f.branch)",$P1))};restore={[void](Git9334 $f.remote @('update-ref',"refs/heads/$($f.branch)",$f.original));[void](Git9334 $f.remote @('update-ref','-d','refs/synthetic/9411-p1'))}}
      )){
        $line=GuardLine9334 'landed-integration-evidence.psm1' $guard.marker
        $mutantDispatch=Mutant9334 $guard.name 'landed-integration-evidence.psm1' $line $guard.replacement
        if(-not$mutantDispatch){continue}
        $candidateRefusal=$null;$mutantResult=$null
        try {
          & $guard.mutate
          $candidateRefusal=Refused9411 { Produce9411 $f $FW }
          $mutantModule=Import-Module (Join-Path (Split-Path -Parent $mutantDispatch) 'landed-integration-evidence.psm1') -Force -DisableNameChecking -PassThru
          try { $mutantResult=Refused9411 { & $mutantModule {param($o,$r,$l,$id) New-InterruptedIntegrationResume $o $r $l $id -Successor} $f.obligation $f.runtime $FW.label $FW.launchId } }
          finally { Remove-Module $mutantModule -Force; Import-Module (Join-Path $PSScriptRoot 'landed-integration-evidence.psm1') -Force -DisableNameChecking }
        } finally { & $guard.restore }
        Proof9334 ($candidateRefusal.Contains($guard.reason)-and$mutantResult-ceq'UNEXPECTED SUCCESS') "guard $($guard.marker): candidate refuses ('$candidateRefusal'); omitted guard produces a binding (bypass red)"
      }
      # AC3: the host-dispatched successor publishes once across both launches.
      [void](Successor9411 $f $FW 'publish' $binding)
      [void](Git9334 $f.remote @('config','core.logAllRefUpdates','always'))
      $f.cfg.successorContinue=$true;$f.cfg.movement='commit-again';$f.cfg.duplicatePublish=$true;$f.cfg.promptCapture=Join-Path $f.case 'successor-prompt.txt'
      $run=Launch9334 $f
      $S=Read-RebaseJson (Join-Path $f.runtime "watchdog-lane-$($f.cfg.label).json")
      Proof9334 ($run.exit-eq0-and$S.schemaVersion-ceq'watchdog-lane/v4'-and$S.state-ceq'exited'-and$S.head-ceq$P1-and$S.resumeOfLaunchId-ceq$FW.launchId-and$S.attemptId-ceq$FW.attemptId-and$S.harness-ceq$FW.harness-and$S.model-ceq$FW.model-and$S.interruptedIntegration-ceq($binding|ConvertTo-Json -Depth 12 -Compress)) "successor launch at live HEAD P1 keeps the exact prior tuple and semantic attempt, publishes, and its launcher completes raw=$($run.resultPath)"
      $ack=Read-RebaseJson (Join-Path $f.runtime "dispatch-start-$identity.json")
      Proof9334 ($ack.schemaVersion-ceq'dispatch-start-ack/v2'-and$ack.head-ceq$P1-and$ack.launchId-ceq$S.launchId-and$ack.interruptedIntegration-ceq$S.interruptedIntegration) 'single-use start-ack/v2 binds the successor binding at the live HEAD'
      $events=Events9334 $f $f.cfg.label
      $continueEvents=@($events|Where-Object{$_.item.command.Contains('-ContinueInterruptedIntegration')});$publishEvents=@($events|Where-Object{$_.item.command.Contains('-PublishInterruptedIntegration')})
      Proof9334 ($continueEvents.Count-eq1-and$continueEvents[0].item.exit_code-eq1-and$continueEvents[0].item.aggregated_output.Contains('successor publishes only')-and$publishEvents.Count-eq2-and$publishEvents[0].item.exit_code-eq0-and$publishEvents[0].item.aggregated_output.Contains('"pushed":true')-and$publishEvents[1].item.exit_code-eq1-and$publishEvents[1].item.aggregated_output.Contains('already published')) 'successor continuation refuses; one publication succeeds; duplicate publication refuses'
      $P2=Git9334 $f.repo @('rev-parse','HEAD');$pushes=@(PushCount9411 $f)
      Proof9334 ($pushes.Count-eq1-and$pushes[0].StartsWith("$($f.original) $P2 ")-and(Git9334 $f.remote @('rev-parse',"refs/heads/$($f.branch)"))-ceq$P2) "push counter: exactly one leased push original->P2 across both launches (prior pushed nothing)"
      $publication=Read-RebaseJson (Join-Path $f.runtime "integration-resume-publication-$($S.launchId).json")
      Proof9334 ($publication.finishIdentity-ceq$binding.sources.finishIdentity-and$publication.finishHead-ceq$R-and$publication.publishedHead-ceq$P2-and$publication.leaseExpectedHead-ceq$f.original-and$publication.commitCount-eq2-and@($publication.movement).Count-eq2-and$publication.movement[0].new-ceq$P1-and-not(Test-Path -LiteralPath $publicationPath)) 'successor publication binds the prior finish identity, R->P1->P2 granted movement and the original-head lease; no record under the prior launch'
      $promptText=[IO.File]::ReadAllText($f.cfg.promptCapture)
      Proof9334 ($promptText.Contains('Finished-unpublished ordinary successor')-and$promptText.Contains('-PublishInterruptedIntegration')-and$promptText.Contains('exit 73 is disclosed non-execution')-and-not$promptText.Contains('Continue through rebase-integration.ps1 -ContinueInterruptedIntegration')) 'publication-only successor preamble, never the continuation preamble'
      [void](Completion9411 $f $S $FW 2 'successor')
      $again=Refused9411 { Produce9411 $f $S };$fromPrior=Refused9411 { Produce9411 $f $FW }
      Proof9334 ($again.Contains('INTEGRATION_RESUME_SUCCESSOR: completion exists')-and$fromPrior.Contains('INTEGRATION_RESUME_SUCCESSOR: completion exists')-and@(PushCount9411 $f).Count-eq1) "terminal: no second successor from either launch ('$again'); push counter stays 1"
      $finished=$true
      return
    }
    if ($Carrier -ceq 'successor-publication') {
      # AC3 single publication across launches, independent of the admission census:
      # a prior-launch publication appearing after admission refuses before any push.
      # Two successors per fixture stay inside the retained depth bound.
      $once=Fixture9334 'successor-once'
      $oncePrior=Finish9411 $once
      $OF=$oncePrior.watchdog
      [void](Git9334 $once.remote @('config','core.logAllRefUpdates','always'))
      $injected=Join-Path $once.runtime "integration-resume-publication-$($OF.launchId).json"
      [void](Successor9411 $once $OF 'once-1');$once.cfg.movement='commit';$once.cfg.injectPublication=$injected;$once.cfg.expectRefusal='INTEGRATION_RESUME_PUBLICATION: already published';Save9334 $once.config $once.cfg
      $runOnce=Launch9334 $once
      $OS1=Read-RebaseJson (Join-Path $once.runtime "watchdog-lane-$($once.cfg.label).json")
      Proof9334 ($runOnce.exit-ne0-and$runOnce.stderr.Contains('finished unpublished')-and@(PushCount9411 $once).Count-eq0-and(Git9334 $once.remote @('rev-parse',"refs/heads/$($once.branch)"))-ceq$once.original-and-not(Test-Path -LiteralPath (Join-Path $once.runtime "integration-resume-publication-$($OS1.launchId).json"))) "a prior-launch publication record appearing after admission refuses the successor publication before any push (push counter 0) raw=$($runOnce.resultPath)"
      Remove-Item -LiteralPath $injected -Force;$once.cfg.injectPublication='';$once.cfg.expectRefusal=''
      $publicationLine=GuardLine9334 'landed-integration-evidence.psm1' 'SUCCESSOR_GUARD_ONE_PUBLICATION'
      $onceMutant=Mutant9334 'successor-one-publication' 'landed-integration-evidence.psm1' $publicationLine $publicationLine.Replace('if (Test-Path','if ($launch -ceq $Child.record.launchId -and (Test-Path').Replace('-PathType Leaf) {','-PathType Leaf)) {')
      if($onceMutant){
        $runtimeModule=Join-Path $once.runtime 'landed-integration-evidence.psm1';$candidateModule=[IO.File]::ReadAllBytes($runtimeModule)
        try {
          [IO.File]::WriteAllBytes($runtimeModule,[IO.File]::ReadAllBytes((Join-Path (Split-Path -Parent $onceMutant) 'landed-integration-evidence.psm1')))
          [void](Successor9411 $once $OS1 'once-2');$once.cfg.movement='commit-again';$once.cfg.injectPublication=$injected;Save9334 $once.config $once.cfg
          $runBypass=Launch9334 $once
          $OS2=Read-RebaseJson (Join-Path $once.runtime "watchdog-lane-$($once.cfg.label).json")
          Proof9334 (@(PushCount9411 $once).Count-eq1-and(Test-Path -LiteralPath $injected)-and(Test-Path -LiteralPath (Join-Path $once.runtime "integration-resume-publication-$($OS2.launchId).json"))) "guard SUCCESSOR_GUARD_ONE_PUBLICATION omitted (own-launch-only check) on the same input: the helper pushes a second publication across launches (bypass red, push counter 1) raw=$($runBypass.resultPath)"
        } finally { [IO.File]::WriteAllBytes($runtimeModule,$candidateModule) }
      } else { [Console]::Out.WriteLine("SKIPPED 9411 $Carrier SUCCESSOR_GUARD_ONE_PUBLICATION omitted-guard arm") }
      # Admission-to-publication drift: the remote moves during the successor run.
      $drift=Fixture9334 'successor-drift'
      $driftPrior=Finish9411 $drift
      [void](Git9334 $drift.remote @('config','core.logAllRefUpdates','always'))
      [void](Successor9411 $drift $driftPrior.watchdog 'drift-1');$drift.cfg.movement='commit';$drift.cfg.leaseMismatch=$true;$drift.cfg.expectRefusal='INTEGRATION_RESUME_PUBLICATION: lease/remote mismatch';Save9334 $drift.config $drift.cfg
      $runDrift=Launch9334 $drift
      $DS=Read-RebaseJson (Join-Path $drift.runtime "watchdog-lane-$($drift.cfg.label).json");$moved=Git9334 $drift.repo @('rev-parse',"$($drift.original)^")
      Proof9334 ($runDrift.exit-ne0-and@(PushCount9411 $drift).Count-eq0-and(Git9334 $drift.remote @('rev-parse',"refs/heads/$($drift.branch)"))-ceq$moved-and-not(Test-Path -LiteralPath (Join-Path $drift.runtime "integration-resume-publication-$($DS.launchId).json"))-and$null-eq(Read-RebaseCompletion $drift.obligation $drift.runtime)) "admission-to-publication remote drift refuses under the original-head lease; moved remote untouched; no push, record or completion raw=$($runDrift.resultPath)"
      $finished=$true
      return
    }
    if ($Carrier -ceq 'successor-amend') {
      # F1: successor movement after R is plain commits only. A granted commit amended
      # after admission refuses before any push and again at the next admission; a granted
      # commit after R then amended refuses at admission. Bare R and a plain granted commit
      # stay admitted, and amending R itself keeps its descendant refusal.
      $f=Fixture9334 'successor-amend'
      $prior=Finish9411 $f
      $FW=$prior.watchdog;$R=$prior.finish.resultHead;$amendReason='INTEGRATION_RESUME_SUCCESSOR: amended commit after finish forbidden'
      [void](Git9334 $f.remote @('config','core.logAllRefUpdates','always'))
      $atR=Snapshot9411 $f
      function Local9411 { [ordered]@{raw=(RawState9334 $f);runtime=(RuntimeState9334 $f);branchLog=(Get-RebaseHash ([IO.File]::ReadAllBytes((Join-Path $f.repo ".git/logs/refs/heads/$($f.branch)"))));headLog=(Get-RebaseHash ([IO.File]::ReadAllBytes((Join-Path $f.repo '.git/logs/HEAD'))));remote=(Git9334 $f.remote @('rev-parse',"refs/heads/$($f.branch)","refs/pull/$($f.pr)/head"))}|ConvertTo-Json -Compress }
      function Unpublished9411 { @(Get-ChildItem -LiteralPath $f.runtime -File|Where-Object{$_.Name -like 'integration-resume-publication-*' -or $_.Name -like 'integration-rebase-complete-*'}).Count-eq0-and(Git9334 $f.remote @('rev-parse',"refs/heads/$($f.branch)","refs/pull/$($f.pr)/head"))-ceq"$($f.original)`n$($f.original)" }
      $bare=Successor9411 $f $FW 'amend-s1'
      Proof9334 ($bare.state.attachedHead-ceq$R-and$bare.state.finishHead-ceq$R) 'bare finish R is admitted'
      # Amendment after admission: the successor makes a valid granted commit, amends it, publishes.
      $f.cfg.movement='commit-amend';$f.cfg.prePublish=Join-Path $f.case 'pre-publication.json';$f.cfg.expectRefusal=$amendReason
      $run=Launch9334 $f
      $S1=Read-RebaseJson (Join-Path $f.runtime "watchdog-lane-$($f.cfg.label).json");$pre=Read-RebaseJson $f.cfg.prePublish
      $f.cfg.movement='commit';$f.cfg.prePublish='';$f.cfg.expectRefusal='';Save9334 $f.config $f.cfg
      $amended=Git9334 $f.repo @('rev-parse','HEAD');$publishEvents=@(Events9334 $f $S1.label|Where-Object{$_.item.command.Contains('-PublishInterruptedIntegration')})
      $branchRows=@((Git9334 $f.repo @('reflog','--format=%gs',"refs/heads/$($f.branch)")) -split "`n")
      Proof9334 ($run.exit-ne0-and$run.stderr.Contains('INTEGRATION_RESUME_COMPLETION: finished unpublished')-and$S1.state-ceq'exited'-and$S1.head-ceq$R-and$publishEvents.Count-eq1-and$publishEvents[0].item.exit_code-eq1-and$publishEvents[0].item.aggregated_output.Contains($amendReason)-and
        $branchRows[0]-cmatch'^commit \(amend\): '-and$branchRows[1]-cmatch'^commit: '-and(Git9334 $f.repo @('rev-parse',"$amended^"))-ceq$R-and$pre.head-ceq$amended-and$pre.status-ceq''-and(Git9334 $f.repo @('status','--porcelain=v1','--untracked-files=normal'))-ceq''-and
        $pre.branchLog-ceq(Get-RebaseHash ([IO.File]::ReadAllBytes((Join-Path $f.repo ".git/logs/refs/heads/$($f.branch)"))))-and$pre.headLog-ceq(Get-RebaseHash ([IO.File]::ReadAllBytes((Join-Path $f.repo '.git/logs/HEAD'))))-and@(PushCount9411 $f).Count-eq0-and(Unpublished9411)) "amendment after admission: the successor's granted commit R->P1, amended to P1', refuses publication before any push (push counter 0); head, reflogs and status unchanged by the refusal; remote branch and PR at the original head; no publication or completion raw=$($run.resultPath)"
      $before=Local9411;$next=Refused9411 { Produce9411 $f $S1 }
      Proof9334 ($next.Contains($amendReason)-and(Local9411)-ceq$before-and(Unpublished9411)) "the amendment left by the dead successor refuses the next admission ('$next'); bytes, history, records and remote unchanged"
      # A valid granted commit after R is admitted; the same commit amended refuses at admission.
      Restore9411 $f $atR
      [IO.File]::WriteAllText((Join-Path $f.repo 'synthetic-repair.txt'),"synthetic repair`n");[IO.File]::WriteAllText((Join-Path $f.repo 'synthetic-repair.test.txt'),"synthetic repair test`n")
      [void](Git9334 $f.repo @('add','--','synthetic-repair.txt','synthetic-repair.test.txt'));[void](Git9334 $f.repo @('commit','-qm','synthetic granted repair'));$P1=Git9334 $f.repo @('rev-parse','HEAD')
      $plain=Produce9411 $f $S1
      Proof9334 ($plain.state.attachedHead-ceq$P1-and$plain.state.finishHead-ceq$R-and$plain.sources.priorLaunchId-ceq$S1.launchId-and$plain.sources.finishLaunchId-ceq$FW.launchId) 'a plain granted commit R->P1 is admitted (successor of the dead successor, same finish)'
      [IO.File]::AppendAllText((Join-Path $f.repo 'synthetic-repair.txt'),"synthetic amended repair`n");[void](Git9334 $f.repo @('commit','-q','--amend','-am','synthetic amended granted repair'))
      $before=Local9411;$admission=Refused9411 { Produce9411 $f $S1 }
      Proof9334 ($admission.Contains($amendReason)-and(Git9334 $f.repo @('reflog','-1','--format=%gs',"refs/heads/$($f.branch)"))-cmatch'^commit \(amend\): '-and(Local9411)-ceq$before-and(Unpublished9411)) "admission: the granted commit after R, then amended, refuses ('$admission'); bytes, history, records and remote unchanged"
      [void](Successor9411 $f $S1 'amend-s2' $plain)
      Refusal9334 $f 'host dispatch of the plain-commit binding after its commit was amended' $amendReason
      $plainMutant=Mutant9334 'successor-plain-commit' 'landed-integration-evidence.psm1' (GuardLine9334 'landed-integration-evidence.psm1' 'SUCCESSOR_GUARD_PLAIN_COMMIT') '    # Synthetic omission: successor plain-commit movement.'
      if($plainMutant){
        $mutantModule=Import-Module (Join-Path (Split-Path -Parent $plainMutant) 'landed-integration-evidence.psm1') -Force -DisableNameChecking -PassThru
        try { $mutantResult=Refused9411 { & $mutantModule {param($o,$r,$l,$id) New-InterruptedIntegrationResume $o $r $l $id -Successor} $f.obligation $f.runtime $S1.label $S1.launchId } }
        finally { Remove-Module $mutantModule -Force; Import-Module (Join-Path $PSScriptRoot 'landed-integration-evidence.psm1') -Force -DisableNameChecking }
        Proof9334 ($mutantResult-ceq'UNEXPECTED SUCCESS') 'guard SUCCESSOR_GUARD_PLAIN_COMMIT omitted: the same amended input produces a successor binding (bypass red)'
      } else { [Console]::Out.WriteLine("SKIPPED 9411 $Carrier SUCCESSOR_GUARD_PLAIN_COMMIT omitted-guard arm") }
      Restore9411 $f $atR
      [void](Git9334 $f.repo @('commit','-q','--amend','-m','synthetic amended finish'));$amendR=Refused9411 { Produce9411 $f $S1 }
      Restore9411 $f $atR
      $again=Produce9411 $f $S1
      Proof9334 ($amendR.Contains('INTEGRATION_RESUME_PUBLICATION: result is not a descendant of the finish')-and$again.state.attachedHead-ceq$R-and(Unpublished9411)) "amending R itself keeps its descendant refusal ('$amendR'); restored history admits bare R again"
      $finished=$true
      return
    }
    if ($Carrier -ceq 'successor-dispatch') {
      # AC2 dispatch admission and AC5 admission refusals; dry plans run no child.
      $f=Fixture9334 'successor-dispatch'
      $prior=Finish9411 $f
      $FW=$prior.watchdog;$R=$prior.finish.resultHead
      $binding=Successor9411 $f $FW 'dispatch'
      Proof9334 ($binding.state.attachedHead-ceq$R-and$binding.state.finishHead-ceq$R) 'host producer binds the bare finish R at the live attached HEAD'
      $baseline=BaselineModule9411 $f
      $candidatePath=$f.cfg.dispatch
      try { $f.cfg.dispatch=Join-Path $baseline '.orchestrator/dispatch-lane.ps1'; Refusal9334 $f "immutable baseline $($successorBaselineHead.Substring(0,8)) launcher refuses the attached successor binding" 'INTEGRATION_RESUME_BINDING' } finally { $f.cfg.dispatch=$candidatePath;Save9334 $f.config $f.cfg }
      $before=RawState9334 $f;$runtimeBefore=RuntimeState9334 $f
      $plan=Launch9334 $f @('-Dry')
      Proof9334 ($plan.exit-eq0-and$plan.stdout.Contains('"heavyAdmission"')-and$plan.stdout.Contains($R)-and-not(Test-Path -LiteralPath $f.cfg.entry)-and(RawState9334 $f)-ceq$before-and(RuntimeState9334 $f)-ceq$runtimeBefore) "host successor dispatch admitted: live-HEAD claim R, exact prior tuple, harness NOTRUN, bytes UNCHANGED raw=$($plan.resultPath)"
      $hostMutant=Mutant9334 'successor-host-only' 'dispatch-lane.ps1' (GuardLine9334 'dispatch-lane.ps1' 'SUCCESSOR_GUARD_HOST_ONLY') '  # Synthetic omission: host-only successor dispatch.'
      Discriminator9334 $f 'watchdog relaunch cannot carry a successor binding' 'INTEGRATION_RESUME_SUCCESSOR: host-only successor dispatch' $hostMutant @('-Dry','-Relaunch','1')
      $tupleMutant=Mutant9334 'successor-exact-tuple' 'dispatch-lane.ps1' (GuardLine9334 'dispatch-lane.ps1' 'SUCCESSOR_GUARD_EXACT_TUPLE') '      # Synthetic omission: exact prior tuple.'
      Discriminator9334 $f 'crossed tuple: eligible fable route against the astra prior' 'INTEGRATION_RESUME_SUCCESSOR: crossed tuple or attempt' $tupleMutant @('-Dry','-Harness','claude','-Model','claude-fable-5-1')
      # Today's row-7 slot passes the route gate but still crosses the retained Astra prior tuple.
      Refusal9334 $f 'crossed tuple: current sol slot against the astra prior' 'INTEGRATION_RESUME_SUCCESSOR: crossed tuple or attempt' @('-Dry','-Model','gpt-6.1-sol','-Placement','provisional')
      Refusal9334 $f 'ineligible route: Sol off its row-7 slot placement' 'INTEGRATION_RESUME_ROUTE' @('-Dry','-Model','gpt-6.1-sol')
      $f.cfg.semanticAttemptId='synthetic-other-attempt';Save9334 $f.config $f.cfg
      Refusal9334 $f 'crossed semantic attempt' 'INTEGRATION_RESUME_BINDING: semantic attempt mismatch'
      $f.cfg.semanticAttemptId='';Save9334 $f.config $f.cfg
      $promptBytes=[IO.File]::ReadAllBytes($f.cfg.prompt)
      $grantMutant=Mutant9334 'successor-equal-grant' 'dispatch-lane.ps1' (GuardLine9334 'dispatch-lane.ps1' 'SUCCESSOR_GUARD_EQUAL_GRANT') '    # Synthetic omission: equal prior FINAL grant.'
      try {
        $text=[Text.Encoding]::UTF8.GetString($promptBytes)
        $widened=$text.Replace('"repairPaths":["synthetic-repair.txt"]','"repairPaths":["synthetic-repair.txt","synthetic-widened.txt"]')
        if($widened-ceq$text){throw '9411 widened grant fixture did not change the prompt'}
        [IO.File]::WriteAllText($f.cfg.prompt,$widened,[Text.UTF8Encoding]::new($false))
        Discriminator9334 $f 'crossed grant: widened successor prompt grant' 'INTEGRATION_RESUME_SCOPE: successor grant differs from the prior FINAL grant' $grantMutant
        [IO.File]::WriteAllText($f.cfg.prompt,'Synthetic successor prompt without a grant.',[Text.UTF8Encoding]::new($false))
        Refusal9334 $f 'successor prompt without the FINAL grant' 'INTEGRATION_RESUME_SCOPE: exact host FINAL grant required'
      } finally { [IO.File]::WriteAllBytes($f.cfg.prompt,$promptBytes) }
      foreach($section in @('obligation','sources','state')){
        $bad=$binding|ConvertTo-Json -Depth 15|ConvertFrom-Json -DateKind String;$bad.$section|Add-Member -NotePropertyName unknownAuthority -NotePropertyValue $true;Save9334 $f.cfg.resumePath $bad
        Refusal9334 $f "closed nested successor $section" 'INTEGRATION_RESUME_BINDING'
      }
      foreach($case in @('attachedHead-boolean','finishLaunchId-number','stoppedHead-added','grantIdentity-null')){
        $bad=$binding|ConvertTo-Json -Depth 15|ConvertFrom-Json -DateKind String
        switch($case){ 'attachedHead-boolean'{$bad.state.attachedHead=$true} 'finishLaunchId-number'{$bad.sources.finishLaunchId=7} 'stoppedHead-added'{$bad.state|Add-Member stoppedHead $R} 'grantIdentity-null'{$bad.sources.grantIdentity=$null} }
        Save9334 $f.cfg.resumePath $bad
        Refusal9334 $f "successor shape $case" 'INTEGRATION_RESUME_BINDING'
      }
      Save9334 $f.cfg.resumePath $binding
      $stateMutant=Mutant9334 'successor-state' 'landed-integration-evidence.psm1' (GuardLine9334 'landed-integration-evidence.psm1' 'INTEGRATION_RESUME_STATE: ordinary successor input stale or unrelated') '  # Synthetic omission: exact successor state.'
      foreach($field in @('attachedTree','branchReflogSha256')){
        $bad=$binding|ConvertTo-Json -Depth 15|ConvertFrom-Json -DateKind String;$bad.state.$field=$(if($field-ceq'attachedTree'){'b'*40}else{'b'*64});Save9334 $f.cfg.resumePath $bad
        Discriminator9334 $f "successor state $field binding" 'INTEGRATION_RESUME_STATE: ordinary successor input stale or unrelated' $stateMutant
      }
      Save9334 $f.cfg.resumePath $binding
      $sourceMutant=Mutant9334 'successor-source' 'landed-integration-evidence.psm1' (GuardLine9334 'landed-integration-evidence.psm1' 'INTEGRATION_RESUME_SOURCE: ordinary successor binding changed') '  # Synthetic omission: exact successor sources.'
      foreach($field in @('ackSha256','finishSha256','finishIdentity','watchdogSha256')){
        $bad=$binding|ConvertTo-Json -Depth 15|ConvertFrom-Json -DateKind String;$bad.sources.$field='b'*64;Save9334 $f.cfg.resumePath $bad
        Discriminator9334 $f "successor exact source $field" 'INTEGRATION_RESUME_SOURCE: ordinary successor binding changed' $sourceMutant
      }
      # The grant identity is guarded twice: omitting the source comparison still meets the equal-grant guard.
      $bad=$binding|ConvertTo-Json -Depth 15|ConvertFrom-Json -DateKind String;$bad.sources.grantIdentity='b'*64;Save9334 $f.cfg.resumePath $bad
      Refusal9334 $f 'successor exact source grantIdentity' 'INTEGRATION_RESUME_SOURCE: ordinary successor binding changed'
      if($sourceMutant){ try { $f.cfg.dispatch=$sourceMutant; Refusal9334 $f 'tampered grant identity with the source guard omitted still refuses at the independent equal-grant guard' 'INTEGRATION_RESUME_SCOPE: successor grant differs from the prior FINAL grant' } finally { $f.cfg.dispatch=$candidatePath;Save9334 $f.config $f.cfg } }
      Save9334 $f.cfg.resumePath $binding
      $watchdogPath=Join-Path $f.runtime "watchdog-lane-$($FW.label).json";$watchdogBytes=[IO.File]::ReadAllBytes($watchdogPath)
      try {
        $v=Read-RebaseJson $watchdogPath;$v.state='running';$v.exitCode=$null;Save9334 $watchdogPath $v
        Refusal9334 $f 'premature start: the prior launch has not exited' 'INTEGRATION_RESUME_SUCCESSOR: exited retained resume launch required'
      } finally { [IO.File]::WriteAllBytes($watchdogPath,$watchdogBytes) }
      $ackPath=Join-Path $f.runtime "dispatch-start-$(Identity9411 $binding).json"
      try { [IO.File]::WriteAllText($ackPath,'{}'); Refusal9334 $f 'duplicate start: the single-use start request is already used' 'INTEGRATION_RESUME_BINDING: retained start request already used' } finally { Remove-Item -LiteralPath $ackPath -Force }
      [IO.File]::WriteAllText((Join-Path $f.repo 'synthetic-dirty.txt'),"dirty`n")
      try { Refusal9334 $f 'dirty attached successor worktree' 'INTEGRATION_RESUME_SUCCESSOR: clean attached obligation branch required' } finally { Remove-Item -LiteralPath (Join-Path $f.repo 'synthetic-dirty.txt') -Force }
      $older=Git9334 $f.repo @('rev-parse',"$($f.original)^")
      [void](Git9334 $f.remote @('update-ref',"refs/pull/$($f.pr)/head",$older))
      try { Refusal9334 $f 'moved PR head' 'INTEGRATION_RESUME_REMOTE: ordinary successor branch/PR moved' } finally { [void](Git9334 $f.remote @('update-ref',"refs/pull/$($f.pr)/head",$f.original)) }
      ValidPlan9334 $f 'original successor fixture after independent destructive controls'
      $finished=$true
      return
    }
    if ($Carrier -ceq 'successor-completion') {
      # AC4: unpublished successor retry from the latest dead successor, two-owner completion, replay, depth.
      $f=Fixture9334 'successor-retry'
      $prior=Finish9411 $f
      $FW=$prior.watchdog;$R=$prior.finish.resultHead
      $snapshot=Snapshot9411 $f
      try { [void](Git9334 $f.repo @('commit','-q','--amend','-m','synthetic amended finish')); $amend=Refused9411 { Produce9411 $f $FW } } finally { Restore9411 $f $snapshot }
      Proof9334 ($amend.Contains('INTEGRATION_RESUME_PUBLICATION: result is not a descendant of the finish')-and(Git9334 $f.repo @('rev-parse','HEAD'))-ceq$R) "AC5 amend of the finish commit R refuses before any push ('$amend'); history restored"
      [void](Successor9411 $f $FW 's1');$f.cfg.movement='commit';$f.cfg.exitBeforePublish=$true;Save9334 $f.config $f.cfg
      $run1=Launch9334 $f
      $S1=Read-RebaseJson (Join-Path $f.runtime "watchdog-lane-$($f.cfg.label).json");$P1=Git9334 $f.repo @('rev-parse','HEAD')
      Proof9334 ($run1.exit-ne0-and$run1.stderr.Contains('INTEGRATION_RESUME_COMPLETION: finished unpublished')-and$S1.schemaVersion-ceq'watchdog-lane/v4'-and$S1.state-ceq'exited'-and$S1.head-ceq$R-and$null-eq(Read-RebaseCompletion $f.obligation $f.runtime)-and
        -not(Test-Path -LiteralPath (Join-Path $f.runtime "integration-resume-publication-$($S1.launchId).json"))-and(Git9334 $f.remote @('rev-parse',"refs/heads/$($f.branch)"))-ceq$f.original-and(Git9334 $f.repo @('rev-parse',"$P1^"))-ceq$R) "repeated unpublished: successor S1 made a granted commit and exited unpublished by declared exit; no completion, no publication, remote at original raw=$($run1.resultPath)"
      $f.cfg.exitBeforePublish=$false;if(Test-Path -LiteralPath $f.cfg.entry){Remove-Item -LiteralPath $f.cfg.entry -Force}
      $superseded=Refused9411 { Produce9411 $f $FW }
      Proof9334 ($superseded.Contains('INTEGRATION_RESUME_SUCCESSOR: prior already has a successor; bind the latest dead successor')) "the superseded prior cannot be bound again ('$superseded')"
      $s1Binding=Read-RebaseJson $f.cfg.resumePath
      $f.cfg.label='ordinary-9411-s1-again';$f.cfg.prompt=Join-Path $f.runtime "$($f.cfg.label).prompt.txt";[IO.File]::WriteAllText($f.cfg.prompt,[IO.File]::ReadAllText((Join-Path $f.runtime "$($f.seedLabel).prompt.txt")));Save9334 $f.config $f.cfg
      Refusal9334 $f 'duplicate start of the consumed S1 binding under a fresh label' 'INTEGRATION_RESUME_SUCCESSOR: prior already has a successor'
      $b2=Successor9411 $f $S1 's2'
      Proof9334 ($b2.sources.priorLaunchId-ceq$S1.launchId-and$b2.sources.finishLaunchId-ceq$FW.launchId-and$b2.sources.finishIdentity-ceq$s1Binding.sources.finishIdentity-and$b2.sources.grantIdentity-ceq$s1Binding.sources.grantIdentity-and$b2.sources.attemptId-ceq$FW.attemptId-and$b2.state.attachedHead-ceq$P1-and$b2.state.finishHead-ceq$R) 'retry binds the latest dead successor S1 and recurses through it to the original finish and grant'
      $f.cfg.movement='commit-again';Save9334 $f.config $f.cfg
      $run2=Launch9334 $f
      $S2=Read-RebaseJson (Join-Path $f.runtime "watchdog-lane-$($f.cfg.label).json")
      Proof9334 ($run2.exit-eq0-and$S2.resumeOfLaunchId-ceq$S1.launchId-and$S2.attemptId-ceq$FW.attemptId) "retry successor S2 at the depth bound (S1, F, seed) publishes once and completes raw=$($run2.resultPath)"
      $completion=Completion9411 $f $S2 $FW 2 'retry successor'
      Proof9334 (-not(Test-Path -LiteralPath (Join-Path $f.runtime "integration-resume-publication-$($S1.launchId).json"))-and(Test-Path -LiteralPath (Join-Path $f.runtime "integration-resume-publication-$($S2.launchId).json"))) 'exactly one publication record across F, S1 and S2'
      # S2 sits at the depth bound: a successor of S2 refuses on depth first; within the
      # bound (from S1) the census refuses on the retained completion.
      $terminal=Refused9411 { Produce9411 $f $S1 };$beyond=Refused9411 { Produce9411 $f $S2 }
      Proof9334 ($terminal.Contains('INTEGRATION_RESUME_SUCCESSOR: completion exists')-and$beyond.Contains('INTEGRATION_RESUME_SOURCE: bounded retained chain exhausted')) "terminal replay is inert: no successor after completion ('$terminal'; beyond the bound '$beyond')"
      $finished=$true
      return
    }
    if ($Carrier -ceq 'successor-depth') {
      # Depth: the retained chain allows at most three predecessors.
      $d=Fixture9334 'successor-depth' -SecondStop
      [void](Bind9334 $d)
      $stopRun=Launch9334 $d
      $stop=Read-RebaseJson (Join-Path $d.runtime "watchdog-lane-$($d.cfg.label).json")
      Proof9334 ($stopRun.exit-eq2) "depth fixture: the first resume stops again raw=$($stopRun.resultPath)"
      Remove-Item -LiteralPath $d.cfg.entry -Force
      $next=New-InterruptedIntegrationResume $d.obligation $d.runtime $stop.label $stop.launchId
      $d.cfg.resumePath=Join-Path $d.runtime 'resume-next.json';Save9334 $d.cfg.resumePath $next;$d.cfg.label+='-next';$d.cfg.prompt=Join-Path $d.runtime "$($d.cfg.label).prompt.txt";[IO.File]::WriteAllText($d.cfg.prompt,[IO.File]::ReadAllText((Join-Path $d.runtime "$($d.seedLabel).prompt.txt")));$d.cfg.finishOnly=$true;Save9334 $d.config $d.cfg
      $finishRun=Launch9334 $d
      $DF=Read-RebaseJson (Join-Path $d.runtime "watchdog-lane-$($d.cfg.label).json")
      Proof9334 ($finishRun.exit-ne0-and$finishRun.stderr.Contains('finished unpublished')) "depth fixture: the retained retry finishes unpublished raw=$($finishRun.resultPath)"
      $d.cfg.finishOnly=$false;Remove-Item -LiteralPath $d.cfg.entry -Force
      [void](Successor9411 $d $DF 'depth-s1');$d.cfg.exitBeforePublish=$true;$d.cfg.movement='';Save9334 $d.config $d.cfg
      [void](Launch9334 $d);$DS1=Read-RebaseJson (Join-Path $d.runtime "watchdog-lane-$($d.cfg.label).json")
      # DS1 is the deepest admissible successor (prior, stop and seed fill the bound); a
      # successor of DS1 refuses at production, never launched only to be unable to publish.
      $exhausted=Refused9411 { Produce9411 $d $DS1 }
      Proof9334 ($DS1.state-ceq'exited'-and$exhausted.Contains('INTEGRATION_RESUME_SOURCE: bounded retained chain exhausted')-and@(Get-ChildItem -LiteralPath $d.runtime -Filter 'watchdog-lane-ordinary-9411-*.json' -File).Count-eq1-and(Git9334 $d.remote @('rev-parse',"refs/heads/$($d.branch)"))-ceq$d.original) "depth exhaustion refuses at production for the successor beyond the bound ('$exhausted'); no further successor launched; obligation stays finished-unpublished for an independent decision"
      $finished=$true
      return
    }
    if ($Carrier -ceq 'successor-watchdog') {
      # AC2 watchdog: finished-unpublished is RESUME_REFUSED with no relaunch; the host successor completes.
      $f=Fixture9334 'successor-watchdog'
      $prior=Finish9411 $f
      $FW=$prior.watchdog
      function Watch9411($Label) { Native9334 (Join-Path $PSScriptRoot 'lane-stall-watchdog.ps1') @('-Label',$Label,'-RuntimeRoot',$f.runtime,'-HistoryPath',(Join-Path $f.runtime 'dispatch-log.jsonl')) }
      $launchesBefore=@(Get-ChildItem -LiteralPath $f.runtime -Filter 'watchdog-lane-*.json' -File).Count
      $watch=Watch9411 $FW.label
      Proof9334 ($watch.stdout.Contains('RESUME_REFUSED')-and$watch.stdout.Contains('"relaunch":false')-and$watch.stdout.Contains('host-dispatched only')-and@(Get-ChildItem -LiteralPath $f.runtime -Filter 'dispatch-resume-*.json' -File).Count-eq0-and@(Get-ChildItem -LiteralPath $f.runtime -Filter 'watchdog-lane-*.json' -File).Count-eq$launchesBefore) "watchdog observes the exited finished-unpublished launch: RESUME_REFUSED, no relaunch, no resume input raw=$($watch.resultPath)"
      [void](Successor9411 $f $FW 'watch-s1');$f.cfg.exitBeforePublish=$true;Save9334 $f.config $f.cfg
      [void](Launch9334 $f);$S1=Read-RebaseJson (Join-Path $f.runtime "watchdog-lane-$($f.cfg.label).json")
      $watchS1=Watch9411 $S1.label
      Proof9334 ($watchS1.stdout.Contains('RESUME_REFUSED')-and$watchS1.stdout.Contains('"relaunch":false')-and@(Get-ChildItem -LiteralPath $f.runtime -Filter 'dispatch-resume-*.json' -File).Count-eq0) "watchdog reads the retained v4/v3 successor and refuses its automatic relaunch raw=$($watchS1.resultPath)"
      $f.cfg.exitBeforePublish=$false
      [void](Successor9411 $f $S1 'watch-s2');$f.cfg.movement='commit-again';Save9334 $f.config $f.cfg
      $run=Launch9334 $f;$S2=Read-RebaseJson (Join-Path $f.runtime "watchdog-lane-$($f.cfg.label).json")
      Proof9334 ($run.exit-eq0) "host successor publishes and completes raw=$($run.resultPath)"
      $watchS2=Watch9411 $S2.label
      $baselineWatch=Native9334 (Join-Path (BaselineModule9411 $f) '.orchestrator/lane-stall-watchdog.ps1') @('-Label',$S2.label,'-RuntimeRoot',$f.runtime,'-HistoryPath',(Join-Path $f.runtime 'dispatch-log.jsonl'))
      Proof9334 (-not$baselineWatch.stdout.Contains('TERMINAL_SUCCESS')) "baseline $($successorBaselineHead.Substring(0,8)) watchdog cannot read the retained successor launch as terminal: exit=$($baselineWatch.exit) raw=$($baselineWatch.resultPath)"
      Proof9334 ($watchS2.exit-eq0-and$watchS2.stdout.Contains('TERMINAL_SUCCESS')-and$watchS2.stdout.Contains('"relaunch":false')) "watchdog validates the two-owner completion/v4 as terminal without launch raw=$($watchS2.resultPath)"
      $finished=$true
      return
    }
  } catch {
    Write-Output "EXCEPTION $(if($Carrier -like 'successor-*'){'9411'}else{'9334'}) $Carrier $($_.Exception.Message) STACK $($_.ScriptStackTrace -replace "`r?`n",' | ')"
    throw
  } finally {
    Write-Output "RETAINED $(if($Carrier -like 'successor-*'){'9411'}else{'9334'}) $Carrier native objects, records, entry snapshots and source evidence: $root; finished=$finished"
  }
}
function Invoke-9334OrdinaryCarriers([string[]]$Carriers) {
  foreach ($carrier in $Carriers) { Test-9334OrdinaryCarrier $carrier }
}

# Inert decision/shape controls. Native process, source authentication and Git
# authority are deliberately seams here, never claims about the protected lane.
function Test-9334OrdinaryProof {
  $module=Import-Module (Join-Path $PSScriptRoot 'landed-integration-evidence.psm1') -Force -DisableNameChecking -PassThru
  try { & $module {
    $script:checks=0
    function Check([string]$Name,[scriptblock]$Action,[bool]$Refuses=$false,[string]$Reason='') {
      $errorText=$null
      try { & $Action | Out-Null } catch { $errorText=$_.Exception.Message }
      if ($Refuses -ne ($null-ne$errorText)) { throw "synthetic ordinary proof $Name expectedRefusal=$Refuses error=$errorText" }
      if($Reason-and$errorText-cne$Reason){throw "synthetic ordinary proof $Name wrong refusal: $errorText"}
      $script:checks++; Write-Output "PASS synthetic ordinary proof: $Name$(if($Refuses){' REFUSED '+$errorText})"
    }
    function Clone($v) { $v|ConvertTo-Json -Depth 30|ConvertFrom-Json -DateKind String }
    function StringLeaves($v,[object[]]$Parts=@()) {
      if ($v -is [string]) { return [pscustomobject]@{parts=$Parts} }
      if ($v -is [array]) {
        for ($i=0;$i-lt$v.Count;$i++) { StringLeaves $v[$i] ($Parts+@($i)) }
      } elseif ($v -is [pscustomobject]) {
        foreach ($property in $v.PSObject.Properties) { StringLeaves $property.Value ($Parts+@($property.Name)) }
      }
    }
    function WrongStringTypes([string]$Boundary,$Valid,[scriptblock]$Validate) {
      foreach ($leaf in @(StringLeaves (Clone $Valid))) {
        foreach ($kind in @('singleton-array','object','null')) {
          $mutated=Clone $Valid; $parent=$mutated
          for ($i=0;$i-lt($leaf.parts.Count-1);$i++) {
            $part=$leaf.parts[$i]
            if($part-is[int]){$parent=$parent[$part]}else{$parent=$parent.$part}
          }
          $last=$leaf.parts[-1]
          $original=if($last-is[int]){$parent[$last]}else{$parent.$last}
          $wrong=switch($kind){ 'singleton-array' { ,@($original) }; 'object' { [pscustomobject]@{value=$original} }; 'null' { $null } }
          if($last-is[int]){$parent[$last]=$wrong}else{$parent.$last=$wrong}
          Check "$Boundary $($leaf.parts-join'.') $kind" { & $Validate $mutated } $true
        }
      }
      Check "$Boundary scalar control after wrong types" { & $Validate (Clone $Valid) }
    }
    $runtime=Join-Path ([IO.Path]::GetTempPath()) ('synthetic-9334-proof-'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory((Join-Path $runtime 'logs'))
    $o=New-OrdinaryIntegrationObligation 996334 ('1'*40) ('2'*40) 'synthetic/proof' (Join-Path $runtime 'repo') 'synthetic-proof'
    $owner=[pscustomobject]@{label='synthetic-proof';launchId='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';recordPath=(Join-Path $runtime 'dispatch-launch-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.json');launcherPid=900001;launcherStartIdentity='2026-10-01T00:00:00Z';childPid=900002;childStartIdentity='2026-10-01T00:00:01Z';laneRole='implementation';identityMode='branch';branch=$o.branch;worktree=$o.worktree;head=$o.targetHead}
    $decision=Join-Path $runtime 'logs/synthetic-final.report.md'
    [IO.File]::WriteAllText($decision,"SYNTHETIC FINAL: synthetic repair and test only. No actual test-path grant.`n")
    $grant=[ordered]@{schemaVersion='ordinary-integration-repair-authority/v1';obligationIdentity=(Get-RebaseObligationIdentity $o);decisionPath=$decision;decisionSha256=(Get-RebaseHash ([IO.File]::ReadAllBytes($decision)));firstLine=1;lastLine=1;repairPaths=@('synthetic-repair.txt');focusedTests=@([ordered]@{path='synthetic-repair.test.txt';repairPath='synthetic-repair.txt'})}
    $prompt=Join-Path $runtime 'synthetic.prompt.txt'
    function Prompt($g) { [IO.File]::WriteAllText($prompt,('```ordinary-integration-repair-authority/v1'+"`n"+($g|ConvertTo-Json -Depth 10 -Compress)+"`n"+'```')) }
    $script:syntheticSources=[pscustomobject]@{owner=(Clone $owner);binding=[pscustomobject]@{promptSha256=('a'*64);routingIdentity=('b'*64)}}
    $script:syntheticSources.owner|Add-Member originalPromptPath $prompt
    function script:Get-OrdinaryIntegrationSources { $script:syntheticSources }
    Prompt $grant
    $authority=Get-OrdinaryRepairAuthority $o $runtime $owner
    Check 'exact synthetic host grant' { Get-OrdinaryRepairAuthority $o $runtime $owner }
    WrongStringTypes 'grant' $grant { param($v) Prompt $v; Get-OrdinaryRepairAuthority $o $runtime $owner }
    Prompt $grant
    foreach($case in @('wildcard','traversal','wrong-obligation','wrong-decision-hash','wrong-test-parent','unicode-test-parent','unknown-key','boolean-line','duplicate-path')) {
      $g=Clone $grant
      switch($case) {
        wildcard {$g.repairPaths=@('*')}
        traversal {$g.focusedTests[0].path='../outside'}
        'wrong-obligation' {$g.obligationIdentity='f'*64}
        'wrong-decision-hash' {$g.decisionSha256='f'*64}
        'wrong-test-parent' {$g.focusedTests[0].repairPath='synthetic-other.txt'}
        'unicode-test-parent' {$g.focusedTests[0].repairPath='synthetic'+[char]0x00ad+'-repair.txt'}
        'unknown-key' {$g.focusedTests[0]|Add-Member extra $true}
        'boolean-line' {$g.firstLine=$true}
        'duplicate-path' {$g.repairPaths+= 'synthetic-repair.txt'}
      }
      Prompt $g; Check "grant $case" { Get-OrdinaryRepairAuthority $o $runtime $owner } $true
    }
    [IO.File]::WriteAllText($prompt,'no grant')
    Check 'missing host grant' { Get-OrdinaryRepairAuthority $o $runtime $owner } $true
    Prompt $grant
    $R='3'*40;$P='4'*40;$T='5'*40
    $script:syntheticPaths=@('synthetic-repair.txt','synthetic-repair.test.txt')
    $script:syntheticCommitPaths=@($script:syntheticPaths)
    function script:Get-InterruptedIntegrationGitBytes { ,[Text.Encoding]::UTF8.GetBytes(($script:syntheticCommitPaths -join "`0")+"`0") }
    function script:Invoke-RebaseEvidenceGit($Worktree,$Arguments) {
      switch($Arguments[0]) {
        'merge-base' { '' }
        'rev-list' { if($Arguments -contains '--parents'){ "$('4'*40) $('3'*40)" } elseif($Arguments -contains '--count'){'1'}else{'4'*40} }
        'diff' { if($Arguments[-2]-ceq('3'*40)-and$Arguments[-1]-ceq('4'*40)){($script:syntheticCommitPaths -join "`0")+"`0"}else{throw 'unexpected synthetic diff'} }
        'rev-parse' { if($Arguments[1]-ceq'HEAD'){'4'*40}else{'5'*40} }
        'ls-remote' { "$('1'*40)`trefs/heads/synthetic/proof" }
        'push' { $script:syntheticPushed=$true;'' }
        default { throw "unexpected synthetic Git $($Arguments[0])" }
      }
    }
    $movement=@([ordered]@{old=$R;new=$P;message='commit: synthetic repair'})
    Check 'authorized every-commit movement' { Assert-OrdinaryRepairMovement $o $authority $R $P $movement $script:syntheticPaths }
    $script:syntheticCommitPaths=@('synthetic-outside-grant.txt')
    Check 'out-of-set commit' { Assert-OrdinaryRepairMovement $o $authority $R $P $movement $script:syntheticPaths } $true
    Check 'edit then revert cannot use net allowed paths' { Assert-OrdinaryRepairMovement $o $authority $R $P $movement @('synthetic-repair.txt') } $true
    $script:syntheticCommitPaths=@(' synthetic-repair.txt')
    Check 'leading-space filename stays outside exact grant' { Assert-OrdinaryRepairMovement $o $authority $R $P $movement $script:syntheticPaths } $true 'INTEGRATION_RESUME_SCOPE: commit outside FINAL grant'
    $script:syntheticCommitPaths=@('synthetic-repair.txt','Synthetic-repair.txt')
    Check 'case-distinct Git paths remain distinct' { if (@(Get-OrdinaryChangedPaths $o.worktree $R $P).Count -ne 2) { throw 'case-distinct Git path lost' } }
    Check 'case-colliding unauthorized path cannot disappear' { Assert-OrdinaryRepairMovement $o $authority $R $P $movement $script:syntheticPaths } $true 'INTEGRATION_RESUME_PROOF: exact repository path required'
    $unicodePath='synthetic'+[char]0x00ad+'-repair.txt'
    $script:syntheticCommitPaths=@($unicodePath)
    Check 'linguistically equal path is outside exact grant' { Assert-OrdinaryRepairMovement $o $authority $R $P $movement @($unicodePath) } $true 'INTEGRATION_RESUME_SCOPE: commit outside FINAL grant'
    $unicodeAuthority=Clone $authority;$unicodeAuthority.grant.repairPaths=@($unicodePath);$unicodeAuthority.grant.focusedTests=@()
    Check 'explicit synthetic Unicode grant remains usable' { Assert-OrdinaryRepairMovement $o $unicodeAuthority $R $P $movement @($unicodePath) }
    $script:syntheticCommitPaths=@($script:syntheticPaths)
    Check 'claimed changed paths require ordinal identity' { Assert-OrdinaryRepairMovement $o $authority $R $P $movement @($unicodePath,'synthetic-repair.test.txt') } $true 'INTEGRATION_RESUME_SCOPE: changed paths differ from authorized commits'
    $state=[ordered]@{branch=$o.branch;originalHead=$o.targetHead;onto=$o.newBase;stoppedHead=$o.newBase;stoppedCommit=('6'*40);oldBase=('7'*40);metadataSha256=('a'*64);indexSha256=('b'*64);stagesSha256=('c'*64);dirtySha256=('d'*64);stagedSha256=('e'*64);unstagedSha256=('f'*64)}
    $capture=[ordered]@{schemaVersion='ordinary-integration-conflict/v1';launchId=$owner.launchId;label=$owner.label;obligation=$o;sourcePassReceiptIdentity='ABSENT_REVIEW_REQUIRED';conflictPaths=@('synthetic-conflict.txt');owner=[ordered]@{launcherPid=$owner.launcherPid;launcherStartIdentity=$owner.launcherStartIdentity;childPid=$owner.childPid;childStartIdentity=$owner.childStartIdentity};state=$state;capturedAt='2026-10-01T00:00:02Z';noPush=$true}
    Check 'complete capture control' { Assert-OrdinaryConflictCapture (Clone $capture) $owner.launchId $owner.label $o $owner }
    WrongStringTypes 'capture' $capture { param($v) Assert-OrdinaryConflictCapture $v $owner.launchId $owner.label $o $owner }
    foreach($case in @('owner-extra','owner-pid-boolean','owner-start-date','wrong-launcher','state-join','source-pass-boolean','path-boolean','path-traversal','label-boolean','before-child','missing-NoPush')) {
      $bad=Clone $capture
      switch($case) {
        'owner-extra' {$bad.owner|Add-Member unknownAuthority $true}
        'owner-pid-boolean' {$bad.owner.childPid=$true}
        'owner-start-date' {$bad.owner.childStartIdentity='2026-10-01'}
        'wrong-launcher' {$bad.owner.launcherPid=900003}
        'state-join' {$bad.state.originalHead='f'*40}
        'source-pass-boolean' {$bad.sourcePassReceiptIdentity=$true}
        'path-boolean' {$bad.conflictPaths=@($true)}
        'path-traversal' {$bad.conflictPaths=@('../outside')}
        'label-boolean' {$bad.label=$true}
        'before-child' {$bad.capturedAt='2026-10-01T00:00:00Z'}
        'missing-NoPush' {$bad.noPush=$false}
      }
      Check "capture $case" { Assert-OrdinaryConflictCapture $bad $owner.launchId $owner.label $o $owner } $true
    }
    $script:unitFinishBytes=[Text.Encoding]::UTF8.GetBytes("$($o.targetHead) $R Synthetic <synthetic@example.invalid> 1790812802 +0000`trebase (finish): synthetic`n")
    $script:unitPublishedBytes=[Text.Encoding]::UTF8.GetBytes([Text.Encoding]::UTF8.GetString($script:unitFinishBytes)+"$R $P Synthetic <synthetic@example.invalid> 1790812804 +0000`tcommit: synthetic repair`n")
    $finishHash=Get-RebaseHash $script:unitFinishBytes;$publishedHash=Get-RebaseHash $script:unitPublishedBytes
    $proof=[ordered]@{oldBase=$state.oldBase;branchOldHead=$o.targetHead;branchNewHead=$R;onto=$o.newBase;branchReflogHash=$finishHash;headReflogHash=('d'*64);startedAt='2026-10-01T00:00:02Z';finishedAt='2026-10-01T00:00:03Z'}
    $script:unitProof=$proof
    $script:unitFinish=[pscustomobject]@{identity=('e'*64);finish=[pscustomobject]@{resultHead=$R;pushed=$false;branchReflogHash=$finishHash;headReflogHash=('d'*64);finishedAt='2026-10-01T00:00:03Z'}}
    $script:unitPublished=[pscustomobject]@{identity=('f'*64);publication=[pscustomobject]@{publishedHead=$P;publishedTree=$T;branchReflogHash=$publishedHash;changedPaths=@($script:syntheticPaths);repairAuthority=$authority;publishedAt='2026-10-01T00:00:05Z'}}
    function script:Read-RebaseBytes($Runtime,$Hash) { if($Hash-ceq(Get-RebaseHash $script:unitPublishedBytes)){,$script:unitPublishedBytes}else{,$script:unitFinishBytes} }
    function script:Get-RebaseNativeProof { $script:unitProof }
    $readFinish=${function:Read-OrdinaryFinish}
    $readPublication=${function:Read-OrdinaryPublicationRecord}
    $proofChild=[pscustomobject]@{record=$owner;obligation=$o;ordinary=$true;bindingIdentity=('a'*64)}
    $finishRecord=[ordered]@{schemaVersion='integration-resume-finish/v1';launchId=$owner.launchId;bindingIdentity=$proofChild.bindingIdentity;obligationIdentity=(Get-RebaseObligationIdentity $o);predecessorHead=$o.targetHead;resultHead=$R;resultTree=$T;branchReflogHash=$finishHash;headReflogHash=('d'*64);pushed=$false;finishedAt='2026-10-01T00:00:03Z'}
    $finishPath=Join-Path $runtime "integration-resume-finish-$($owner.launchId).json"
    function RetainFinish($v) { [IO.File]::WriteAllText($finishPath,($v|ConvertTo-Json -Depth 30 -Compress)) }
    RetainFinish $finishRecord
    Check 'retained finish scalar control (inert byte seam)' { & $readFinish $runtime $proofChild }
    WrongStringTypes 'finish' $finishRecord { param($v) RetainFinish $v; & $readFinish $runtime $proofChild }
    RetainFinish $finishRecord
    $readFinishControl=& $readFinish $runtime $proofChild
    $publicationRecord=[ordered]@{schemaVersion='integration-resume-publication/v1';launchId=$owner.launchId;bindingIdentity=$proofChild.bindingIdentity;finishIdentity=$readFinishControl.identity;finishHead=$R;publishedHead=$P;publishedTree=$T;leaseBranch=$o.branch;leaseExpectedHead=$o.targetHead;movement=$movement;commitCount=1;changedPaths=@($script:syntheticPaths);branchReflogHash=$publishedHash;publication=[ordered]@{repository='synthetic://local';branch=$o.branch;observedHead=$P;observedAt='2026-10-01T00:00:05Z'};publishedAt='2026-10-01T00:00:05Z';repairAuthority=$authority}
    $publicationPath=Join-Path $runtime "integration-resume-publication-$($owner.launchId).json"
    function RetainPublication($v) { [IO.File]::WriteAllText($publicationPath,($v|ConvertTo-Json -Depth 30 -Compress)) }
    RetainPublication $publicationRecord
    Check 'retained publication scalar control (inert authority seams)' { & $readPublication $runtime $proofChild $readFinishControl }
    WrongStringTypes 'publication' $publicationRecord { param($v) RetainPublication $v; & $readPublication $runtime $proofChild $readFinishControl }
    Remove-Item -LiteralPath $publicationPath
    function script:Read-OrdinaryFinish { $script:unitFinish }
    function script:Read-OrdinaryPublicationRecord { $script:unitPublished }
    function script:Assert-RebaseResult {}
    function script:Get-RebaseLogBytes { ,$script:unitPublishedBytes }
    function script:Get-RebasePublication { [ordered]@{repository='synthetic://local';branch='synthetic/proof';observedHead=('4'*40);observedAt='2026-10-01T00:00:05Z'} }
    function script:Save-RebaseBytes($Runtime,$Bytes) { Get-RebaseHash $Bytes }
    function script:Write-RebaseRecord($Path,$Value) { $script:syntheticWritten=$Value }
    function script:git { $global:LASTEXITCODE=0 }
    $child=[pscustomobject]@{record=$owner;obligation=$o;ordinary=$true;bindingIdentity=('a'*64)}
    $tokens=$null;$errors=$null
    $helperAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'rebase-integration.ps1'),[ref]$tokens,[ref]$errors)
    $continuation=@($helperAst.EndBlock.Statements|Where-Object{$_ -is [Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -ceq '$ContinueInterruptedIntegration'})
    if($errors.Count-or$continuation.Count-ne1){throw 'synthetic helper continuation extraction failed'}
    $body=[scriptblock]::Create("`$PSScriptRoot='"+(Split-Path -Parent $helperAst.Extent.File).Replace("'","''")+"'`n"+$continuation[0].Clauses[0].Item2.Extent.Text.Trim().Substring(1).TrimEnd().TrimEnd('}'))
    $script:unitChild=$child;$script:continuationMutation=$false
    function script:Get-OrdinaryLiveRequest { $script:unitChild.obligation }
    function script:Get-InterruptedIntegrationChild { $script:unitChild }
    function script:Invoke-IntegrationGit { $script:continuationMutation=$true;throw 'synthetic native mutation reached' }
    Check 'exact helper missing NoPush before continuation/push' {
      function Import-Module {}
      $NoPush=$false;$RuntimeRoot=$runtime;$root=$o.worktree
      try { & $body } catch { if($_.Exception.Message-cne'INTEGRATION_RESUME_CHILD: ordinary continuation requires NoPush'){throw "wrong refusal: $($_.Exception.Message)"};throw }
    } $true 'INTEGRATION_RESUME_CHILD: ordinary continuation requires NoPush'
    if($script:continuationMutation){throw 'missing NoPush reached synthetic native seam'}
    $script:syntheticPushed=$false;$script:syntheticWritten=$null
    Check 'production publication authorized P (inert Git/owner seams)' { Publish-OrdinaryIntegration $runtime $child $o.worktree }
    if(-not$script:syntheticPushed-or$null-eq$script:syntheticWritten){throw 'synthetic authorized publication did not reach push/record seams'}
    $script:syntheticCommitPaths=@('synthetic-outside-authorized-repair.txt');$script:syntheticPushed=$false;$script:syntheticWritten=$null
    Check 'production publication unauthorized path before push' { Publish-OrdinaryIntegration $runtime $child $o.worktree } $true
    if($script:syntheticPushed-or$null-ne$script:syntheticWritten){throw 'synthetic out-of-set publication reached a mutation seam'}
    $script:syntheticCommitPaths=@($script:syntheticPaths)
    $execution=Clone $owner;$execution.PSObject.Properties.Remove('label')
    $completion=[ordered]@{schemaVersion='landed-integration-rebase-complete/v3';obligation=$o;obligationIdentity=(Get-RebaseObligationIdentity $o);mode='ORDINARY_OWNER_RELEASE';origin='live';interruptedIntegration=($capture|ConvertTo-Json -Depth 20 -Compress);executionOwner=$execution;executionLabel=$owner.label;repairAuthority=$authority;predecessorHead=$o.targetHead;finishHead=$R;resultHead=$P;resultTree=$T;completedAt='2026-10-01T00:00:06Z';rebaseProof=$proof;movementProof=[ordered]@{commitCount=1;changedPaths=@($script:syntheticPaths);rows=$movement;finishReflogHash=$finishHash;publishedReflogHash=$publishedHash;finishIdentity=('e'*64);publicationIdentity=('f'*64)};publication=[ordered]@{repository='synthetic://local';branch=$o.branch;observedHead=$P;observedAt='2026-10-01T00:00:05Z'}}
    Check 'valid nonempty P completion control (inert authority seams)' { Read-OrdinaryIntegrationCompletion (Clone $completion) $o $runtime 'synthetic-no-binary' }
    WrongStringTypes 'completion' $completion { param($v) Read-OrdinaryIntegrationCompletion $v $o $runtime 'synthetic-no-binary' }
    foreach($case in @('nested-owner-extra','boolean-finish-identity','bare-R','wrong-finish-identity','boolean-row','extra-row','boolean-publication','scope-widening')) {
      $c=Clone $completion
      switch($case) {
        'nested-owner-extra' {$v=$c.interruptedIntegration|ConvertFrom-Json -DateKind String;$v.owner|Add-Member unknownAuthority $true;$c.interruptedIntegration=$v|ConvertTo-Json -Depth 20 -Compress}
        'boolean-finish-identity' {$c.movementProof.finishIdentity=$true}
        'bare-R' {$c.resultHead=$R;$c.movementProof.commitCount=0;$c.movementProof.rows=@();$c.movementProof.changedPaths=@();$c.movementProof.publicationIdentity=$null}
        'wrong-finish-identity' {$c.movementProof.finishIdentity='a'*64}
        'boolean-row' {$c.movementProof.rows[0].new=$true}
        'extra-row' {$c.movementProof.rows[0]|Add-Member extra $true}
        'boolean-publication' {$c.publication.repository=$true}
        'scope-widening' {$c.repairAuthority.grant.repairPaths+= 'synthetic-outside.txt'}
      }
      Check "P completion $case" { Read-OrdinaryIntegrationCompletion $c $o $runtime 'synthetic-no-binary' } $true
    }
    Check 'pushed finish producer' { Save-OrdinaryIntegrationFinish $runtime ([pscustomobject]@{obligation=$o}) $o.worktree $true } $true
    # #9411 closed attached successor shape: recursive closure, bounded types,
    # nullable stop hashes only, never stoppedHead; the binding head is attachedHead.
    $successorShape=[ordered]@{schemaVersion='interrupted-canonical-integration/v3';obligation=$o
      sources=[ordered]@{priorLabel='synthetic-proof';priorLaunchId=$owner.launchId;attemptId='synthetic-attempt';watchdogSha256=('a'*64);promptSha256=('b'*64);transcriptSha256=('c'*64);routingIdentity=('d'*64);conflictSha256=$null;checkpointSha256=$null;ackSha256=('e'*64);finishLabel='synthetic-proof';finishLaunchId=$owner.launchId;finishSha256=('f'*64);finishIdentity=('1'*64);grantIdentity=('2'*64)}
      state=[ordered]@{branch=$o.branch;originalHead=$o.targetHead;onto=$o.newBase;finishHead=$R;attachedHead=$P;attachedTree=$T;branchReflogSha256=('3'*64)}}
    function SuccessorShape($v) { if (-not (Test-DispatchInterruptedBindingShape (Clone $v))) { throw 'INTEGRATION_RESUME_BINDING: successor shape refused' } }
    Check 'closed successor shape control' { SuccessorShape $successorShape }
    WrongStringTypes 'successor shape' $successorShape { param($v) SuccessorShape $v }
    foreach($case in @('sources-extra','state-extra','obligation-extra','stoppedHead-added','branch-join','original-join','finish-launch-pattern','finish-label-pattern','reflog-hash-short','tree-uppercase','v2-tag-on-attached-shape')) {
      $bad=Clone $successorShape
      switch($case) {
        'sources-extra' {$bad.sources|Add-Member unknownAuthority $true}
        'state-extra' {$bad.state|Add-Member unknownAuthority $true}
        'obligation-extra' {$bad.obligation|Add-Member unknownAuthority $true}
        'stoppedHead-added' {$bad.state|Add-Member stoppedHead $P}
        'branch-join' {$bad.state.branch='synthetic/other'}
        'original-join' {$bad.state.originalHead='9'*40}
        'finish-launch-pattern' {$bad.sources.finishLaunchId='not-a-launch'}
        'finish-label-pattern' {$bad.sources.finishLabel='../outside'}
        'reflog-hash-short' {$bad.state.branchReflogSha256='3'*40}
        'tree-uppercase' {$bad.state.attachedTree='A'*40}
        'v2-tag-on-attached-shape' {$bad.schemaVersion='interrupted-canonical-integration/v2'}
      }
      Check "successor shape $case" { SuccessorShape $bad } $true
    }
    Check 'successor binding head is the attached head; v2 keeps stoppedHead' { if ((Get-DispatchInterruptedBindingHead (Clone $successorShape)) -cne $P -or (Get-DispatchInterruptedBindingHead ([pscustomobject]@{schemaVersion='interrupted-canonical-integration/v2';state=[pscustomobject]@{stoppedHead=$R}})) -cne $R) { throw 'binding head' } }
    Write-Output "PASS synthetic ordinary proof assertions=$script:checks retained=$runtime; no native authority claimed"
  } } finally { Remove-Module $module -Force; Import-Module (Join-Path $PSScriptRoot 'landed-integration-evidence.psm1') -Force -DisableNameChecking }
}

# ---- #8102 test-owned fleet-load fixtures (used by the named tests only) ----
function Assert-8102TempContainer([string]$Container) {
  $resolved=[IO.Path]::GetFullPath($Container).TrimEnd('\','/')
  $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
  if((Split-Path -Parent $resolved).TrimEnd('\','/')-ne$temp-or(Split-Path -Leaf $resolved)-notlike'8102-*'-and(Split-Path -Leaf $resolved)-notlike'controller-release-battery-test-*'){throw "8102 refusing a container outside the test temp root: $Container"}
  return $resolved
}
# A synthetic platform-slot holder: an owner.json in the TEST container's
# .orchestrator/verify-lock.d (never a live container) whose child is a
# CPU-heavy pwsh loop owned and stopped by the test. Wrapper identity is the
# test process itself; child identity is the busy loop.
function Start-SyntheticFleetHolder([string]$Container,[string]$Lane='synthetic-8102-holder',[string]$Gate='vitest-full') {
  $resolved=Assert-8102TempContainer $Container
  $lockDir=Join-Path $resolved '.orchestrator/verify-lock.d'
  if(Test-Path -LiteralPath $lockDir){throw "8102 synthetic holder refuses an existing lock directory: $lockDir"}
  $stopPath=Join-Path $resolved 'synthetic-holder.stop'
  $busyScript=Join-Path $resolved 'synthetic-holder-busy.ps1'
  [IO.File]::WriteAllText($busyScript,'param([string]$Stop)'+"`n"+'while(-not(Test-Path -LiteralPath $Stop)){$x=0;for($i=0;$i-lt200000;$i++){$x+=[Math]::Sqrt($i)}}'+"`n",[Text.UTF8Encoding]::new($false))
  $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=(Join-Path $PSHOME 'pwsh.exe');$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
  foreach($argument in @('-NoProfile','-NonInteractive','-File',$busyScript,'-Stop',$stopPath)){[void]$psi.ArgumentList.Add($argument)}
  $child=[Diagnostics.Process]::Start($psi)
  $self=Get-Process -Id $PID -ErrorAction Stop
  $lockId=[guid]::NewGuid().ToString('N')
  $owner=[ordered]@{schemaVersion=4;lockId=$lockId;owner="$env:USERNAME@$env:COMPUTERNAME";lane=$Lane;branch='synthetic/8102';worktree=$resolved;head=('0'*40);identityMode='branch';pid=$PID;processStartUtc=$self.StartTime.ToUniversalTime().ToString('o');startedUtc=[datetime]::UtcNow.ToString('o');gate=$Gate;commandIdentity='synthetic 8102 fleet holder';state='started';childPid=$child.Id;childProcessStartUtc=$child.StartTime.ToUniversalTime().ToString('o')}
  [IO.Directory]::CreateDirectory($lockDir)|Out-Null
  $ownerPath=Join-Path $lockDir 'owner.json'
  [IO.File]::WriteAllText($ownerPath,($owner|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
  $identity=("lane=$Lane;gate=$Gate;lockId=$lockId;pid=$PID;started=$($owner.processStartUtc)" -replace '\s','_')
  return [pscustomobject]@{lockDir=$lockDir;ownerPath=$ownerPath;stopPath=$stopPath;child=$child;owner=$owner;identity=$identity}
}
function Stop-SyntheticFleetHolder($Holder) {
  if($null-eq$Holder){return}
  try{[IO.File]::WriteAllText($Holder.stopPath,'stop')}catch{}
  try{$Holder.child.WaitForExit()}finally{$Holder.child.Dispose()}
  if(Test-Path -LiteralPath $Holder.lockDir){Remove-Item -LiteralPath $Holder.lockDir -Recurse -Force}
}
# A stale owner.json: well-formed, but its wrapper and child identities name
# processes that already exited. The probes must report it as not held.
function Write-StaleFleetOwner([string]$Container) {
  $resolved=Assert-8102TempContainer $Container
  $lockDir=Join-Path $resolved '.orchestrator/verify-lock.d'
  if(Test-Path -LiteralPath $lockDir){throw "8102 stale owner refuses an existing lock directory: $lockDir"}
  $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=(Join-Path $PSHOME 'pwsh.exe');$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
  foreach($argument in @('-NoProfile','-NonInteractive','-Command','exit 0')){[void]$psi.ArgumentList.Add($argument)}
  $dead=[Diagnostics.Process]::Start($psi);$deadStart=$dead.StartTime.ToUniversalTime().ToString('o');$dead.WaitForExit();$deadPid=$dead.Id;$dead.Dispose()
  $owner=[ordered]@{schemaVersion=4;lockId=[guid]::NewGuid().ToString('N');owner="$env:USERNAME@$env:COMPUTERNAME";lane='synthetic-8102-stale';branch='synthetic/8102';worktree=$resolved;head=('0'*40);identityMode='branch';pid=$deadPid;processStartUtc=$deadStart;startedUtc=[datetime]::UtcNow.ToString('o');gate='vitest-full';commandIdentity='synthetic 8102 stale owner';state='started';childPid=$deadPid;childProcessStartUtc=$deadStart}
  [IO.Directory]::CreateDirectory($lockDir)|Out-Null
  [IO.File]::WriteAllText((Join-Path $lockDir 'owner.json'),($owner|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
  return $lockDir
}
# A committed copy of this checkout's tracked .orchestrator inventory inside a
# fresh test container (<temp>/8102-<label>-<id>/copy), with exact single-site
# source replacements applied before the commit. The copy's own container is
# where its fixtures observe fleet load.
function New-8102FixtureCopy([string]$Label,[hashtable]$Replacements=@{}) {
  $container=Join-Path ([IO.Path]::GetTempPath()) ('8102-'+$Label+'-'+[guid]::NewGuid().ToString('N').Substring(0,12))
  $copy=Join-Path $container 'copy'
  [IO.Directory]::CreateDirectory($copy)|Out-Null
  $sourceRoot=Split-Path -Parent $PSScriptRoot
  $sourcePaths=@(& git.exe -C $sourceRoot ls-files --cached --others --exclude-standard -- .orchestrator)
  if($LASTEXITCODE-ne0-or-not$sourcePaths.Count){throw '8102 current source inventory failed'}
  foreach($relative in $sourcePaths){
    $destination=Join-Path $copy $relative
    [IO.Directory]::CreateDirectory((Split-Path -Parent $destination))|Out-Null
    Copy-Item -LiteralPath (Join-Path $sourceRoot $relative) -Destination $destination
  }
  $applied=[ordered]@{}
  foreach($file in @($Replacements.Keys)){
    $path=Join-Path $copy ".orchestrator/$file";$text=[IO.File]::ReadAllText($path)
    foreach($edit in @($Replacements[$file])){
      $needle=[string]$edit[0];$replacement=[string]$edit[1]
      if([regex]::Matches($text,[regex]::Escape($needle)).Count-ne1){throw "8102 copy $Label needle count differs in $file`: $needle"}
      $text=$text.Replace($needle,$replacement)
    }
    [IO.File]::WriteAllText($path,$text,[Text.UTF8Encoding]::new($false))
    $applied[$file]=@($Replacements[$file]|ForEach-Object{[string]$_[0]})
  }
  foreach($arguments in @(@('init','-q','--initial-branch=synthetic/controller'),@('config','user.name','Synthetic 8102 copy'),@('config','user.email','synthetic-8102@example.invalid'),@('config','commit.gpgsign','false'),@('add','.orchestrator'),@('commit','-qm',"synthetic 8102 copy $Label"))){
    $output=@(& git.exe --no-optional-locks -C $copy @arguments 2>&1)
    if($LASTEXITCODE-ne0){throw "8102 copy Git failed: $($arguments -join ' ') $($output -join "`n")"}
  }
  # Copied-runtime tests have synthetic Git history. Resolve the immutable
  # pre-migration fixture through the caller's read-only alternates instead of
  # asking the dev clone's upload side to advertise a private object.
  $privateObjectDirectories=@()
  if(-not [string]::IsNullOrWhiteSpace($env:GIT_ALTERNATE_OBJECT_DIRECTORIES)){
    $privateObjectDirectories=@($env:GIT_ALTERNATE_OBJECT_DIRECTORIES -split [regex]::Escape([IO.Path]::PathSeparator) | ForEach-Object {$_.Trim().Trim('"')} | Where-Object {-not [string]::IsNullOrWhiteSpace($_)})
    if($privateObjectDirectories.Count){
      $alternates=Join-Path $copy '.git/objects/info/alternates'
      [IO.Directory]::CreateDirectory((Split-Path -Parent $alternates))|Out-Null
      [IO.File]::WriteAllText($alternates,(($privateObjectDirectories -join "`n")+"`n"),[Text.UTF8Encoding]::new($false))
    }
  }
  $historical='b3b4ac2d0d6e3d1aa6666e5b6179178ebcfaa780'
  $historicalType=@(& git.exe -C $copy cat-file -t "${historical}^{commit}" 2>&1)
  if($LASTEXITCODE-ne0-or(($historicalType-join '').Trim()-cne'commit')){throw "8102 historical fixture unavailable through GIT_ALTERNATE_OBJECT_DIRECTORIES"}
  $output=@(& git.exe -C $copy update-ref refs/heads/synthetic/8102-historical $historical 2>&1)
  if($LASTEXITCODE-ne0){throw "8102 historical fixture ref update failed: $($output -join ' ')"}
  return [pscustomobject]@{label=$Label;container=$container;root=$copy;runtime=(Join-Path $copy '.orchestrator');applied=$applied}
}
# Runs one carrier from a copy in its own pwsh process, bounded, and returns the
# raw exit and captured streams. The copy's support script is dot-sourced from
# the copy so every fixture probe observes the copy's container.
function Invoke-8102CarrierCopy($Copy,[string]$Carrier) {
  $runner=Join-Path $Copy.container "run-$Carrier.ps1"
  [IO.File]::WriteAllText($runner,"`$ErrorActionPreference='Stop'`n. '$($Copy.runtime)\interrupted-integration-test-support.ps1'`nInvoke-7963ResumeCarriers @('$Carrier')`n",[Text.UTF8Encoding]::new($false))
  $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=(Join-Path $PSHOME 'pwsh.exe');$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.WorkingDirectory=$Copy.root
  foreach($argument in @('-NoProfile','-NonInteractive','-File',$runner)){[void]$psi.ArgumentList.Add($argument)}
  # A classifier leg proves its whole carrier; proof-arm relevance never applies inside it.
  [void]$psi.Environment.Remove('CHASE_SETS_BATTERY_IMPACT_PATHS')
  $startedAt=[datetimeoffset]::UtcNow
  $p=[Diagnostics.Process]::Start($psi)
  try{
    $out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync()
    $p.WaitForExit()
    $stdout=$out.GetAwaiter().GetResult();$stderr=$err.GetAwaiter().GetResult()
    $stdoutPath=Join-Path $Copy.container "run-$Carrier.stdout.txt";$stderrPath=Join-Path $Copy.container "run-$Carrier.stderr.txt"
    [IO.File]::WriteAllText($stdoutPath,$stdout);[IO.File]::WriteAllText($stderrPath,$stderr)
    return [pscustomobject]@{exit=$p.ExitCode;stdout=$stdout;stderr=$stderr;stdoutPath=$stdoutPath;stderrPath=$stderrPath;elapsedSeconds=([datetimeoffset]::UtcNow-$startedAt).TotalSeconds}
  }finally{$p.Dispose()}
}
function Remove-8102FixtureCopy($Copy) {
  if($null-eq$Copy){return}
  $resolved=Assert-8102TempContainer $Copy.container
  Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
}
