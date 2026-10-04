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

# Historical launchers come from tracked fixtures (#8580), never from private
# container history, so every carrier runs on a public fixture-only checkout.
. (Join-Path $PSScriptRoot 'history-fixture.ps1')

# #8580: the fleet observed around timed fixture windows. By default it is the
# container holding this checkout (the real host fleet; proven by the
# host-smoke-fleet-source test). CHASE_SETS_TEST_FLEET_CONTAINER names a
# test-owned container instead, so CI or a copy may observe a synthetic fleet.
# Held/vacant classification is unchanged either way.
function Resolve-7963FleetContainer {
  $override = [string]$env:CHASE_SETS_TEST_FLEET_CONTAINER
  if ([string]::IsNullOrWhiteSpace($override)) { return (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) }
  $resolved = [IO.Path]::GetFullPath($override).TrimEnd('\','/')
  if (-not (Test-Path -LiteralPath $resolved -PathType Container)) { throw "7963 fleet container override is not a directory: $override" }
  return $resolved
}

# Native controls run from their existing registered carriers, both focused
# and in the controller battery. Incident paths/stage shapes are read-only provenance;
# all Git repositories, commits, contents and process trees below are synthetic.
function Test-7963ResumeCarrier([ValidateSet('dispatch','ownership','rebase','watchdog','retained','native-branch')][string]$Carrier) {
  Import-Module (Join-Path $PSScriptRoot 'landed-integration-evidence.psm1') -Force -DisableNameChecking
  . (Join-Path $PSScriptRoot 'dispatch-ownership.ps1')
  $root = Join-Path ([IO.Path]::GetTempPath()) ('integration-7963-'+$Carrier+'-'+[guid]::NewGuid().ToString('N'))
  [IO.Directory]::CreateDirectory($root) | Out-Null
  # Reproduce the actual retired Terra launch with the pre-migration launcher.
  # Candidate admission must reject that selector; never relax production
  # validation just to construct a historical stopped-attempt fixture.
  $historicalRoot = Join-Path $root 'pre-migration'
  try { $historicalManifest = Expand-HistoryFixture 'b3b4ac2d0d6e3d1aa6666e5b6179178ebcfaa780' $historicalRoot }
  catch { throw "7963 historical launcher fixture failed: $($_.Exception.Message)" }
  Write-Output "FIXTURE 7963 $Carrier historical launcher b3b4ac2d read=$(@($historicalManifest.files|Where-Object mode -ceq 'read').Count) existence-only=$(@($historicalManifest.files|Where-Object mode -ceq 'existence-only').Count) root=$historicalRoot"
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
  $fleetContainer=Resolve-7963FleetContainer
  $holder=Join-Path $root 'native-holder.ps1'
  [IO.File]::WriteAllText($holder,@'
param([string]$Release,[string]$Ready,[string]$Arm,[string]$ArmedReceipt,[int]$DeadlineSeconds=30,[int]$OwnerPid,[string]$OwnerStartIdentity)
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
  while(-not(Test-Path -LiteralPath $Release)){
    try{$owner=Get-Process -Id $OwnerPid -ErrorAction Stop;$live=$owner.StartTime.ToUniversalTime().ToString('o')-ceq$OwnerStartIdentity}catch{$live=$false}
    if(-not$live){exit 0}
    [Threading.Thread]::Sleep(100)
  }
  exit 0
}
$deadline=[datetimeoffset]::UtcNow.AddSeconds($DeadlineSeconds)
if($Arm){
  $receipt=[ordered]@{pid=$PID;startIdentity=$p.StartTime.ToUniversalTime().ToString('o');armedAt=$deadline.AddSeconds(-30).ToString('o');deadline=$deadline.ToString('o')}
  [IO.File]::WriteAllText("$ArmedReceipt.pending",($receipt|ConvertTo-Json -Compress))
  [IO.File]::Move("$ArmedReceipt.pending",$ArmedReceipt)
}
while(-not(Test-Path -LiteralPath $Release)-and[datetimeoffset]::UtcNow-lt$deadline){[Threading.Thread]::Sleep(20)}
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
  function Native([string]$Script,[string[]]$Arguments) {
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
      Save "$stem.input.json" ([ordered]@{config=$invocationConfig;resumeInputBytesPath=$resumeBytesPath;resumeInputSha256=$resumeBytesHash;dispatchSha256=(Get-RebaseHash ([IO.File]::ReadAllBytes($invocationConfig.dispatch)))})
    }
    $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=(Join-Path $PSHOME 'pwsh.exe');$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    foreach($argument in @('-NoProfile','-NonInteractive','-File',$Script)+$Arguments){[void]$psi.ArgumentList.Add($argument)}
    $p=[Diagnostics.Process]::Start($psi)
    try {
      $start=$p.StartTime.ToUniversalTime().ToString('o');$out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync();$p.WaitForExit()
      $stdout=$out.GetAwaiter().GetResult();$stderr=$err.GetAwaiter().GetResult()
      [IO.File]::WriteAllText("$stem.stdout.txt",$stdout);[IO.File]::WriteAllText("$stem.stderr.txt",$stderr)
      $result=[ordered]@{pid=$p.Id;startIdentity=$start;exitCode=$p.ExitCode;hasExited=$p.HasExited;script=$Script;arguments=$Arguments;stdoutPath="$stem.stdout.txt";stderrPath="$stem.stderr.txt"}
      Save "$stem.result.json" $result
      return [pscustomobject]@{exit=$p.ExitCode;stdout=$stdout;stderr=$stderr;resultPath="$stem.result.json"}
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
    $initial=$Record.observations[0]
    if(@($initial.roots|Where-Object{$_.state-ceq'reuse-or-ambiguous'}).Count){$Record.classification='MEASURED_REUSE';return}
    $pending=@($initial.roots|Where-Object{$_.state-ceq'exact'})
    if(-not$pending.Count){$Record.classification='NO_REPRODUCTION';return}
    $deadline=[datetimeoffset]::UtcNow.AddSeconds(10)
    $Record.settleDeadline=$deadline.ToString('o')
    if($Record.hold){
      $held=@($pending|Where-Object{$_.role-ceq'launcher'-and$_.ProcessId-eq$Record.hold.pid-and(Identity8076 $_.rows[0] $Record.hold.startIdentity)})
      if($held.Count-ne1){throw '8076 AC3 NOT_CONSTRUCTIBLE: release lacks the projected holder identity'}
      $Record.hold.preReleaseObservation=Observe8076 (Rows8076 @(Get-CimInstance Win32_Process -Filter "ProcessId = $($Record.hold.pid)" -ErrorAction Stop)) $Owner
      $live=@($Record.hold.preReleaseObservation.roots|Where-Object{$_.role-ceq'launcher'-and$_.state-ceq'exact'-and$_.rows[0].ThreadCount-gt0})
      $Record.hold.releaseAbsent= -not(Test-Path -LiteralPath $Record.hold.releasePath)
      $Record.hold.releaseStartedAt=[datetimeoffset]::UtcNow.ToString('o')
      $Record.hold.fleetLoadAtRelease=Get-FleetLoadObservation $fleetContainer
      if($live.Count-ne1-or-not$Record.hold.releaseAbsent-or-not$Record.hold.armedReceipt-or
        [datetimeoffset]$Record.hold.releaseStartedAt-ge[datetimeoffset]$Record.hold.armedReceipt.deadline){
        # #8102: a miss of the 30 s armed bound is MEASURED_LOAD only when the
        # platform slot was held by one live owner from arm to release; any other
        # miss, and every miss on a vacant fleet, stays the NOT_CONSTRUCTIBLE fail.
        $window=Get-FleetLoadWindow $Record.hold.fleetLoadAtArm $Record.hold.fleetLoadAtRelease
        $boundMissed=[bool]$Record.hold.armedReceipt-and[datetimeoffset]$Record.hold.releaseStartedAt-ge[datetimeoffset]$Record.hold.armedReceipt.deadline
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
    } while([datetimeoffset]::UtcNow-lt$deadline)
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
    $record=[ordered]@{schemaVersion='interrupted-integration-measurement/v1';candidateHead=$candidateHead;seedResultPath=$Seed.resultPath;seedResult=(Read-RebaseJson $Seed.resultPath);watchdogPath=$watchdogPath;watchdogSha256=(Get-RebaseHash ([IO.File]::ReadAllBytes($watchdogPath)));watchdog=$Owner;guardCallSite='landed-integration-evidence.psm1:884';guardRefusalSite='landed-integration-evidence.psm1:615';observations=@((Observe8076 $all $Owner));classification=$null;boundExpired=$false;hold=$null}
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
        $record.hold.armStartedAt=[datetimeoffset]::UtcNow.ToString('o')
        $record.hold.fleetLoadAtArm=Get-FleetLoadObservation $fleetContainer
        [IO.File]::WriteAllText($record.hold.armPath,'arm captured 8076 holder')
        $record.hold.armWrittenAt=[datetimeoffset]::UtcNow.ToString('o')
        $readyBy=[datetimeoffset]::UtcNow.AddSeconds(10)
        while(-not(Test-Path -LiteralPath $record.hold.armedReceiptPath)-and[datetimeoffset]::UtcNow-lt$readyBy){
          if($Seed.holder8076.HasExited-or$Seed.holder8076.StartTime.ToUniversalTime().ToString('o')-cne$record.hold.startIdentity){throw '8076 AC3 NOT_CONSTRUCTIBLE: armed holder identity unavailable'}
          [Threading.Thread]::Sleep(20)
        }
        if(-not(Test-Path -LiteralPath $record.hold.armedReceiptPath)){throw '8076 AC3 NOT_CONSTRUCTIBLE: holder armed receipt missing'}
        $record.hold.armedReceipt=Read-RebaseJson $record.hold.armedReceiptPath
        $armed=$record.hold.armedReceipt
        if($armed.pid-ne$record.hold.pid-or$armed.startIdentity-cne$record.hold.startIdentity-or
          [datetimeoffset]$record.hold.armStartedAt-le[datetimeoffset]$record.observations[0].observedAt-or
          [datetimeoffset]$armed.armedAt-lt[datetimeoffset]$record.hold.armStartedAt-or
          ([datetimeoffset]$armed.deadline-[datetimeoffset]$armed.armedAt).TotalSeconds-ne30){throw '8076 AC3 NOT_CONSTRUCTIBLE: holder arm identity, ordering or bound differs'}
        Save $path $record
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
        } catch {$pair.mutantError=$_.Exception.Message;$pair.mutantStack=$_.ScriptStackTrace}
        $pair.refusalObservation=Observe8076 (Rows8076 @(Get-CimInstance Win32_Process -Filter "ProcessId = $($record.hold.pid)" -ErrorAction Stop)) $Owner
        $live=@($pair.refusalObservation.roots|Where-Object{$_.role-ceq'launcher'-and$_.state-ceq'exact'-and$_.rows[0].ThreadCount-gt0})
        $pair.rootLiveAtRefusal=($live.Count-eq1-and-not(Test-Path -LiteralPath $record.hold.releasePath))
        if($pair.mutantError-cne'INTEGRATION_RESUME_PRIOR_OWNER: live root'-or$pair.mutantStack-notmatch'landed-integration-evidence\.psm1: line 615'){
          throw '8076 AC3 NOT_CONSTRUCTIBLE: held wait-omitted mutant did not refuse at psm1:615'
        }
        if(-not$pair.rootLiveAtRefusal){throw '8076 AC3 NOT_CONSTRUCTIBLE: holder was not live and unreleased at the refusal'}
        if((Get-RebaseRecordIdentity (Get-InterruptedIntegrationState $Obligation.worktree))-cne$before){throw '8076 omission changed frozen native inputs'}
        if((Get-RebaseHash ([IO.File]::ReadAllBytes($watchdogPath)))-cne$pair.watchdogSha256){throw '8076 omission changed frozen watchdog inputs'}
      }
      $binding=Resume8076 $record $path $Owner $Seed $Obligation $Runtime $Label
      if($Control){
        if($record.classification-cne'MEASURED_STALE'-or-not$record.hold.releasedAt){throw '8076 candidate did not settle measured held identity'}
        if(-not$Seed.holder8076.HasExited){throw '8076 AC3 NOT_CONSTRUCTIBLE: released holder has not exited'}
        $record.hold.exitedAt=$Seed.holder8076.ExitTime.ToUniversalTime().ToString('o')
        if(-not$record.hold.armedReceipt-or-not$record.hold.preReleaseObservation-or-not$record.hold.releaseAbsent-or
          $record.hold.releaseMarginSeconds-le0-or$record.hold.Contains('cleanupReleasedAt')-or
          [datetimeoffset]$record.hold.exitedAt-le[datetimeoffset]$record.hold.releasedAt-or
          [datetimeoffset]$record.settleCompletedAt-gt[datetimeoffset]$record.settleDeadline){throw '8076 AC3 NOT_CONSTRUCTIBLE: candidate release causality or settle bound unproven'}
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
$deadline=[datetimeoffset]::UtcNow.AddSeconds(10)
do {
  $owners=@(Get-ChildItem -LiteralPath $cfg.runtime -Filter 'dispatch-launch-*.json' -File|ForEach-Object{Get-Content -Raw $_.FullName|ConvertFrom-Json -DateKind String}|Where-Object{$_.childPid-eq$PID-and$_.state-ceq'started'})
  if($owners.Count-eq1){break}
  [Threading.Thread]::Sleep(20)
} while([datetimeoffset]::UtcNow-lt$deadline)
if($owners.Count-ne1){throw 'synthetic actual child ownership not published'}
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
  try{$readyBy=[datetimeoffset]::UtcNow.AddSeconds(10);while(-not(Test-Path -LiteralPath $cfg.descendantReady)-and[datetimeoffset]::UtcNow-lt$readyBy){[Threading.Thread]::Sleep(20)};if(-not(Test-Path -LiteralPath $cfg.descendantReady)){throw 'native descendant failed to start'}}finally{$descendant.Dispose()}
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
      $request=Get-RebaseHash ([Text.Encoding]::UTF8.GetBytes("landed-integration-start/v2`n$request`n$onto`ncodex/gpt-6-astra/high/7/override-Todd"))
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
      foreach($arg in @('-NoProfile','-NonInteractive','-File',$holder,'-Release',$release8076,'-Ready',$ready8076,'-Arm',$arm8076,'-ArmedReceipt',$armed8076)){[void]$psi.ArgumentList.Add($arg)}
      $holder8076=[Diagnostics.Process]::Start($psi)
      $readyBy=[datetimeoffset]::UtcNow.AddSeconds(10)
      while(-not(Test-Path -LiteralPath $ready8076)-and[datetimeoffset]::UtcNow-lt$readyBy){[Threading.Thread]::Sleep(20)}
      if(-not(Test-Path -LiteralPath $ready8076)){throw '8076 AC3 NOT_CONSTRUCTIBLE: native holder failed to start'}
      $born8076=Read-RebaseJson $ready8076
      if($born8076.pid-ne$holder8076.Id-or$born8076.startIdentity-cne$holder8076.StartTime.ToUniversalTime().ToString('o')){throw '8076 AC3 NOT_CONSTRUCTIBLE: native holder publication differs'}
      $hold8076=[ordered]@{pid=$born8076.pid;startIdentity=$born8076.startIdentity;readyPath=$ready8076;releasePath=$release8076;armPath=$arm8076;armedReceiptPath=$armed8076;armStartedAt=$null;armWrittenAt=$null;armedReceipt=$null;preReleaseObservation=$null;releaseAbsent=$false;releaseStartedAt=$null;releasedAt=$null;releaseMarginSeconds=$null;exitedAt=$null}
    }
    $candidateDispatcher=$cfg.dispatch
    if(-not$CurrentRequest){$cfg.dispatch=$historicalDispatcher;Save $config $cfg}
    try {
      $seed=if($CurrentRequest){Native $runner @('-Config',$config)}else{Native $runner @('-Config',$config,'-Model','gpt-5.6-terra','-Route','2','-Placement','measured')} # historical dispatcher fixture only
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
      $routes=@(Get-Content (Join-Path $runtime 'dispatch-log.jsonl')|ForEach-Object{$_|ConvertFrom-Json -DateKind String}|Where-Object{$_.dispatchRoutingSchema-cin@('watchdog-dispatch-routing/v1','watchdog-dispatch-routing/v2')-and$_.label-ceq$label})
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
          $exited8076=$holder8076.WaitForExit(10000)
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
  function Launch($f,[string[]]$Extra=@()) { Save $f.config $f.cfg; Native $runner (@('-Config',$f.config)+$Extra) }
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
  function Race($f,[string]$Dispatch,[bool]$ExpectPlan) {
    $path=(@($f.shape.changes|Where-Object{$_-like"M`t*"})[0] -split "`t",2)[1];$full=Join-Path $f.repo $path;$bytes=[IO.File]::ReadAllBytes($full)
    $f.cfg.barrierObserved=Join-Path $f.case "race-$ExpectPlan.observed";$f.cfg.barrierContinue=Join-Path $f.case "race-$ExpectPlan.continue"
    $originalDispatch=$f.cfg.dispatch;$f.cfg.dispatch=$Dispatch;Save $f.config $f.cfg
    $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=(Join-Path $PSHOME 'pwsh.exe');$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    foreach($arg in @('-NoProfile','-NonInteractive','-File',$runner,'-Config',$f.config,'-Dry')){[void]$psi.ArgumentList.Add($arg)}
    $p=[Diagnostics.Process]::Start($psi);$out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync();$start=$p.StartTime.ToUniversalTime().ToString('o')
    try{
      $deadline=[datetimeoffset]::UtcNow.AddSeconds(30)
      while(-not(Test-Path -LiteralPath $f.cfg.barrierObserved)-and-not$p.HasExited-and[datetimeoffset]::UtcNow-lt$deadline){[Threading.Thread]::Sleep(20)}
      if(-not(Test-Path -LiteralPath $f.cfg.barrierObserved)){
        # Diagnostic only: name why the child never reached the barrier.
        $barrierDiagnostic=if($p.HasExited){$errText=$err.GetAwaiter().GetResult();"child exit=$($p.ExitCode) stderr=$(($errText -split "\r?\n" | Where-Object { $_ } | Select-Object -Last 3) -join ' | ')"}else{"child still running after 30 s"}
        throw "7963 actual admission barrier did not enter ($barrierDiagnostic)"
      }
      [IO.File]::AppendAllText($full,"changed after exclusive admission`n");$changed=RawState $f
      [IO.File]::WriteAllText($f.cfg.barrierContinue,'continue owned fixture')
      $p.WaitForExit();$stdout=$out.GetAwaiter().GetResult();$stderr=$err.GetAwaiter().GetResult();$stem=Join-Path $artifacts "7963-$candidateTag-ownership-race-$ExpectPlan"
      [IO.File]::WriteAllText("$stem.stdout.txt",$stdout);[IO.File]::WriteAllText("$stem.stderr.txt",$stderr);Save "$stem.result.json" ([ordered]@{pid=$p.Id;startIdentity=$start;exitCode=$p.ExitCode;hasExited=$p.HasExited;expectedPlan=$ExpectPlan;fixture=$f.case;source=$Dispatch})
      Proof (($ExpectPlan-and$p.ExitCode-eq0-and$stdout.Contains('"heavyAdmission"'))-or(-not$ExpectPlan-and$p.ExitCode-ne0-and$stderr.Contains('INTEGRATION_RESUME_STATE')-and-not$stdout.Contains('"heavyAdmission"'))) "actual admission race expectedPlan=$ExpectPlan exit=$($p.ExitCode) raw=$stem.result.json"
      Proof ((RawState $f)-ceq$changed-and-not(Test-Path -LiteralPath $f.cfg.entry)) 'race preserves the changed index/working/metadata bytes and starts no harness'
    }finally{
      if(-not$p.HasExited){[IO.File]::WriteAllText($f.cfg.barrierContinue,'release owned failed control');if(-not$p.WaitForExit(10000)){$p.Kill();$p.WaitForExit()}}
      $p.Dispose();$f.cfg.dispatch=$originalDispatch;$f.cfg.barrierObserved='';$f.cfg.barrierContinue='';Save $f.config $f.cfg
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
      $old = Join-Path $f.case 'old8023'
      [void](Expand-HistoryFixture 'f67fc96aa2b12050408b97dbe023fe6de586ca74' $old)
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
        [void](Expand-HistoryFixture '0b6e67e87d82d340c496f05a54bff149bda39d4d' $baseline)
        if(-not(Test-Path -LiteralPath (Join-Path $baseline '.orchestrator/dispatch-lane.ps1') -PathType Leaf)){throw '7963 immutable baseline extraction failed'}
        $candidate=$f.cfg.dispatch;$input=$f.cfg.resumePath;$f.cfg.dispatch=Join-Path $baseline '.orchestrator/dispatch-lane.ps1';$f.cfg.resumePath=''
        Refusal $f "$incident immutable baseline refuses" 'detached worktrees'
        $f.cfg.dispatch=$candidate;$f.cfg.resumePath=$input
        foreach($role in @('review','planning')){Refusal $f "$incident wrong role $role" 'INTEGRATION_RESUME_ROUTE' @('-Dry','-Role',$role)}
        Refusal $f "$incident wrong route" 'INTEGRATION_RESUME_ROUTE' @('-Dry','-Model','gpt-6.1-sol')
        # 8063: the Todd-ruled Fable 5.1 vendor fallback (4388/5743533387) is the only
        # second admitted resume route; every other harness/model/effort/row/role/placement refuses.
        $fable=@('-Dry','-Harness','claude','-Model','claude-fable-5-1')
        ValidPlan $f "$incident 8063 claude/claude-fable-5-1/high/7/override-Todd fallback route admitted" $fable
        foreach($sibling in @('claude-sonnet-5-5','claude-opus-5-5')){Refusal $f "$incident 8063 claude sibling $sibling refused" 'INTEGRATION_RESUME_ROUTE' @('-Dry','-Harness','claude','-Model',$sibling)}
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
        Discriminator $f "$incident upper-tier route" 'INTEGRATION_RESUME_ROUTE' $routeMutant @('-Dry','-Model','gpt-6.1-sol')
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
        Race $raceCandidate $f.cfg.dispatch $false
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
        # between the candidate and mutant. The separate holder's 30s deadline,
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
          $orphan=Get-Process -Id $born.pid -ErrorAction Stop
        try {
          Proof ($orphan.StartTime.ToUniversalTime().ToString('o')-ceq$born.startIdentity) 'possible descendant uses actual OS creation identity'
          $nativeChild=@(Get-CimInstance Win32_Process -Filter "ProcessId = $($born.pid)" -ErrorAction Stop)
          Proof ($nativeChild.Count-eq1-and$nativeChild[0].ParentProcessId-eq$orphanFixture.prior.childPid) 'surviving descendant has the actual prior child as its native parent'
          Discriminator $orphanFixture 'actual surviving descendant denies prior-tree death' 'INTEGRATION_RESUME_PRIOR_OWNER' $deathMutant
          Proof (-not$orphan.HasExited) 'possible-child discriminator executed while the child survived'
        } finally {
          [IO.File]::WriteAllText($orphanFixture.cfg.descendantRelease,'release owned descendant')
          if(-not$orphan.WaitForExit(10000)){$orphan.Kill();$orphan.WaitForExit();throw '7963 owned descendant did not finish'}
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
  try{
    if(-not$Holder.child.WaitForExit(5000)){$Holder.child.Kill($true);[void]$Holder.child.WaitForExit(5000)}
  }finally{$Holder.child.Dispose()}
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
  # Copied-runtime tests have synthetic Git history and no historical commits:
  # the pre-migration launcher comes from the copied fixtures/history data, so
  # every copy leg is also a public fixture-only run of its carrier (#8580).
  return [pscustomobject]@{label=$Label;container=$container;root=$copy;runtime=(Join-Path $copy '.orchestrator');applied=$applied}
}
# Runs one carrier from a copy in its own pwsh process, bounded, and returns the
# raw exit and captured streams. The copy's support script is dot-sourced from
# the copy so every fixture probe observes the copy's container.
function Invoke-8102CarrierCopy($Copy,[string]$Carrier,[int]$TimeoutSeconds=1500) {
  $runner=Join-Path $Copy.container "run-$Carrier.ps1"
  [IO.File]::WriteAllText($runner,"`$ErrorActionPreference='Stop'`n. '$($Copy.runtime)\interrupted-integration-test-support.ps1'`nInvoke-7963ResumeCarriers @('$Carrier')`n",[Text.UTF8Encoding]::new($false))
  $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=(Join-Path $PSHOME 'pwsh.exe');$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.WorkingDirectory=$Copy.root
  foreach($argument in @('-NoProfile','-NonInteractive','-File',$runner)){[void]$psi.ArgumentList.Add($argument)}
  # A classifier leg proves its whole carrier; proof-arm relevance never applies inside it.
  [void]$psi.Environment.Remove('CHASE_SETS_BATTERY_IMPACT_PATHS')
  # The copy observes its own container's fleet, never an inherited override.
  [void]$psi.Environment.Remove('CHASE_SETS_TEST_FLEET_CONTAINER')
  $startedAt=[datetimeoffset]::UtcNow
  $p=[Diagnostics.Process]::Start($psi)
  try{
    $out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync()
    if(-not$p.WaitForExit($TimeoutSeconds*1000)){$p.Kill($true);[void]$p.WaitForExit(10000);throw "8102 carrier copy $($Copy.label)/$Carrier exceeded $TimeoutSeconds s"}
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
