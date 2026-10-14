param([ValidateSet('All','AC1','AC2','AC3','AC4','AC8186','mixed-role-isolation','reducer-failure-isolation','day-after-error-and-observation','launch-status-observed','transport-vs-reducer-failure','relaunch-follow-stays-fatal')][string]$Only='All', [switch]$BeforeFix)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'routing-data-test-support.ps1')
$routingTestScope=Enter-RoutingDataTestScope
try {
$entry=Join-Path $PSScriptRoot 'lane-stall-watchdog-batch.ps1'
$shell=Join-Path $PSScriptRoot 'lane-stall-watchdog.sh'
function Check($Condition,[string]$Message){if(-not $Condition){throw "ASSERTION FAILED: $Message"}}
if($BeforeFix){
  if($Only-eq'AC2'){
    # The historical shell unconditionally reports a stall and exits zero even
    # when pwsh.exe returns Exec format error. Exercise it, not a text oracle.
    $root=Join-Path $PSScriptRoot ('artifacts/batch-red-'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($root)
    $bash='C:/Program Files/Git/bin/bash.exe'
    $harness=Join-Path $root 'shell-control.sh'
    $body=@'
pwsh.exe() { echo 'Exec format error SYNTHETIC_SECRET_8136' >&2; return 126; }
wslpath() { printf '%s\n' "$2"; }
export -f pwsh.exe wslpath
export POLL_S=0 STALL_POLLS=1 MAX_S=10
source "$1" "synthetic:$2"
'@
    [IO.File]::WriteAllText($harness,$body.Replace("`r`n","`n"))
    $inputPath=Join-Path $root 'transcript.txt';[IO.File]::WriteAllText($inputPath,'synthetic')
    $output=& $bash $harness $shell $inputPath 2>&1|Out-String;$code=$LASTEXITCODE
    [IO.File]::WriteAllText((Join-Path $root 'result.txt'),"exit=$code`n$output")
    Check ($code-ne0-and$output.Contains('TRANSPORT_FAILURE')-and-not$output.Contains('SYNTHETIC_SECRET_8136')-and-not$output.Contains('STALL-DETECTED')) 'AC2 shell captured transport failure must be nonzero, classified, and secret-free'
  }else{
    Check (Test-Path -LiteralPath $entry) "$Only actual native batch entry is absent on installed baseline"
  }
  return
}
Check (Test-Path -LiteralPath $entry) 'native batch entry exists'
$root=Join-Path $PSScriptRoot ('artifacts/batch-native-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$pwsh=(Get-Command pwsh).Source
$active=[Collections.Generic.List[object]]::new()
$workers=[Collections.Generic.List[object]]::new()
$sequence=0
function Json([string]$Path,$Value){[IO.File]::WriteAllText($Path,(ConvertTo-Json -InputObject $Value -Depth 12),[Text.UTF8Encoding]::new($false))}
function Begin-Native([string]$Script,[string[]]$Arguments,[string]$Name){
  $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$pwsh;$start.UseShellExecute=$false;$start.CreateNoWindow=$true
  $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
  foreach($a in @('-NoProfile','-NonInteractive','-File',$Script)+$Arguments){[void]$start.ArgumentList.Add($a)}
  $process=[Diagnostics.Process]::Start($start)
  $handle=[pscustomobject]@{process=$process;stdout=$process.StandardOutput.ReadToEndAsync();stderr=$process.StandardError.ReadToEndAsync();name=$Name;ended=$false}
  $active.Add($handle);return $handle
}
function End-Native($Handle){
  Check ($Handle.process.WaitForExit(60000)) "native command did not end: $($Handle.name)"
  $result=[pscustomobject]@{exit=$Handle.process.ExitCode;stdout=$Handle.stdout.GetAwaiter().GetResult();stderr=$Handle.stderr.GetAwaiter().GetResult();pid=$Handle.process.Id}
  [IO.File]::WriteAllText((Join-Path $root "$($Handle.name).stdout.log"),$result.stdout)
  [IO.File]::WriteAllText((Join-Path $root "$($Handle.name).stderr.log"),$result.stderr)
  Json (Join-Path $root "$($Handle.name).exit.json") @{exit=$result.exit;pid=$result.pid}
  $Handle.ended=$true;$Handle.process.Dispose();return $result
}
function Run-Native([string]$Script,[string[]]$Arguments,[string]$Name){End-Native (Begin-Native $Script $Arguments $Name)}
function Git([string]$Repo,[string[]]$Arguments){$output=& git.exe -C $Repo @Arguments 2>&1;Check ($LASTEXITCODE-eq0) 'synthetic Git setup';return ($output-join"`n")}
function New-Producer([string]$Label,[ValidateSet('dead','terminal','live')][string]$Mode,[string]$SharedRuntime,[ValidateSet('implementation','planning','review')][string]$Role='implementation',[int]$Row=7,[string]$Placement='override-Todd',[switch]$Detached){
  $case=Join-Path $root "$Label space";$repo=Join-Path $case 'worktree';$runtime=Join-Path $case 'runtime space';$temp=Join-Path $case 'temp'
  if($SharedRuntime){$runtime=$SharedRuntime}
  foreach($p in @($repo,$runtime,$temp)){[void][IO.Directory]::CreateDirectory($p)}
  [void](Git $repo @('init','-q','--initial-branch=synthetic/8136'))
  [void](Git $repo @('config','user.name','Synthetic 8136'));[void](Git $repo @('config','user.email','synthetic8136@example.invalid'))
  [IO.File]::WriteAllText((Join-Path $repo 'seed.txt'),'synthetic only');[void](Git $repo @('add','.'));[void](Git $repo @('commit','-qm','synthetic seed'))
  if($Detached){[void](Git $repo @('checkout','-q','--detach'))} # dispatch-lane admits an immutable-head worktree only for review
  $prompt=Join-Path $case 'prompt.txt';[IO.File]::WriteAllText($prompt,'Synthetic transport test. No provider or product action.')
  $body=Join-Path $case 'worker.ps1';$release=Join-Path $case 'release';$progress=Join-Path $case 'session output.jsonl';$grow=Join-Path $case 'grow'
  [IO.File]::WriteAllText($progress,'synthetic session start')
  [IO.File]::WriteAllText((Join-Path $case 'descendant.ps1'),@'
param($Release,$Progress,$Grow)
$until=[datetime]::UtcNow.AddSeconds(90)
while(-not(Test-Path -LiteralPath $Release)-and[datetime]::UtcNow-lt$until){
  if(Test-Path -LiteralPath $Grow){[IO.File]::AppendAllText($Progress,"synthetic descendant progress`n")}
  Start-Sleep -Milliseconds 20
}
'@)
  [IO.File]::WriteAllText($body,@'
param($Mode,$Release,$Progress,$Grow)
$null=[Console]::In.ReadToEnd()
Write-Output '{"type":"synthetic.worker.started"}'
if($Mode-eq'dead'){[Console]::Error.WriteLine('stream disconnected');exit 17}
if($Mode-eq'live'){
  $arguments=@('-NoProfile','-NonInteractive','-File',(Join-Path $PSScriptRoot 'descendant.ps1'),$Release,$Progress,$Grow)|ForEach-Object{'"'+$_+'"'}
  $child=Start-Process -FilePath (Get-Command pwsh).Source -ArgumentList $arguments -WindowStyle Hidden -PassThru
  @{pid=$child.Id;startIdentity=$child.StartTime.ToUniversalTime().ToString('o')}|ConvertTo-Json|Set-Content -LiteralPath ($Progress+'.child.json')
  $until=[datetime]::UtcNow.AddSeconds(90)
  while(-not(Test-Path -LiteralPath $Release)-and[datetime]::UtcNow-lt$until){
    Start-Sleep -Milliseconds 20
  }
  [IO.File]::WriteAllText($Release,'cooperative descendant exit');$child.WaitForExit();$child.Dispose()
}
Write-Output '{"type":"turn.completed"}'
exit 0
'@)
  $config=Join-Path $case 'dispatch.json';$runner=Join-Path $case 'produce.ps1'
  $workerArguments=@('-NoProfile','-NonInteractive','-File',$body,$Mode,$release,$progress,$grow)|ForEach-Object{'"'+$_+'"'}
  Json $config @{script=(Join-Path $PSScriptRoot 'dispatch-lane.ps1');parameters=@{Harness='codex';Model='gpt-6-astra';Effort='high';Row=$Row;Placement=$Placement;LaneRole=$Role;PromptFile=$prompt;Worktree=$repo;Label=$Label;ExecutablePath=$pwsh;TestRuntimeRoot=$runtime;TestTempRoot=$temp;TestArgumentList=@($workerArguments)}}
  [IO.File]::WriteAllText($runner,'$c=Get-Content -LiteralPath '''+$config.Replace("'","''")+''' -Raw|ConvertFrom-Json -AsHashtable;$p=$c.parameters;& $c.script @p;exit $LASTEXITCODE')
  $handle=Begin-Native $runner @() "$Label-producer"
  $caseObject=[pscustomobject]@{label=$Label;runtime=$runtime;transcript=(Join-Path $runtime "$Label.jsonl");spec=(Join-Path $runtime "watchdog-lane-$Label.json");release=$release;progress=$progress;grow=$grow;handle=$handle}
  $workers.Add($caseObject)
  if($Mode-ne'live'){$r=End-Native $handle;Check ($r.exit-eq$(if($Mode-eq'dead'){17}else{0})) "real producer $Mode exit"}
  else{
    $deadline=[datetime]::UtcNow.AddSeconds(30);$ready=$false
    while([datetime]::UtcNow-lt$deadline-and-not$handle.process.HasExited){
      if(Test-Path -LiteralPath $caseObject.spec){$spec=Get-Content -LiteralPath $caseObject.spec -Raw|ConvertFrom-Json;if($spec.state-eq'running'-and(Test-Path ($progress+'.child.json'))){$ready=$true;break}}
      Start-Sleep -Milliseconds 50
    }
    Check $ready 'real producer published live spec'
  }
  return $caseObject
}
function Lane($Case,[switch]$Progress){
  $lane=@{label=$Case.label;runtimeRoot=$Case.runtime;transcriptPath=$Case.transcript}
  if($Progress){$lane.progressPath=$Case.progress};return $lane
}
function Batch($Lanes,[string]$Name,[string[]]$Extra=@(),[string]$Subject=$entry,[double]$Window=3,[int]$Unchanged=1){
  $manifest=Join-Path $root "$Name.lanes.json";Json $manifest @($Lanes)
  $r=Run-Native $Subject (@('-LanesPath',$manifest,'-PollSeconds','0.05','-UnchangedPolls',[string]$Unchanged,'-WindowSeconds',[string]$Window)+$Extra) $Name
  $events=@($r.stdout-split"`r?`n"|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json -DateKind String})
  $r|Add-Member events $events
  Check (@(Get-Process -Id $r.pid -ErrorAction SilentlyContinue).Count-eq0) 'batch process survived return'
  foreach($event in @($events|Where-Object{$_.event-in@('OBSERVATION','REDUCER_FAILURE')-and$_.transportPid})){
    Check (@(Get-Process -Id $event.transportPid -ErrorAction SilentlyContinue).Count-eq0) 'watcher helper survived observation'
  }
  return $r
}
function Failure($Result,[string]$Message){
  # Shared input/setup/transport-start failure: fatal, batch-wide, never a lane diagnosis.
  Check ($Result.exit-ne0-and@($Result.events|Where-Object event -eq TRANSPORT_FAILURE).Count-eq1-and
    @($Result.events|Where-Object event -eq OBSERVATION).Count-eq0-and@($Result.events|Where-Object event -eq REDUCER_FAILURE).Count-eq0-and
    $Result.events[-1].reason-ceq'TRANSPORT_FAILURE'-and$Result.events[-1].exitCode-eq1-and
    -not($Result.stdout+$Result.stderr).Contains('SYNTHETIC_SECRET_8136')) $Message
}
function Reducer-Failure($Result,[string]$Code,[string]$Message,[string]$Reason='WINDOW_EXPIRED',[string]$Label=''){
  # Contained lane error: labeled, closed-coded, secret-free; siblings continue; exit is nonzero while unresolved.
  $failures=@($Result.events|Where-Object event -eq REDUCER_FAILURE)
  Check ($Result.exit-ne0-and$failures.Count-ge1-and@($failures|Where-Object{$_.code-cne$Code}).Count-eq0-and
    @($failures|Where-Object{$_.label-isnot[string]-or-not$_.label-or($Label-and$_.label-cne$Label)}).Count-eq0-and
    @($failures|Where-Object{$_.PSObject.Properties.Name-contains'message'-or$_.PSObject.Properties.Name-contains'output'-or$_.PSObject.Properties.Name-contains'stderr'}).Count-eq0-and
    @($Result.events|Where-Object event -eq TRANSPORT_FAILURE).Count-eq0-and$Result.events[-1].event-ceq'EXIT'-and$Result.events[-1].reason-ceq$Reason-and
    $Result.events[-1].exitCode-eq1-and$Result.events[-1].unresolvedReducerFailures-eq1-and
    -not($Result.stdout+$Result.stderr).Contains('SYNTHETIC_SECRET_8136')) $Message
}
function Mutate([string]$Name,[string]$Old,[string]$New){
  $text=[IO.File]::ReadAllText($entry);Check (([regex]::Matches($text,[regex]::Escape($Old))).Count-eq1) "mutation anchor $Name"
  $path=Join-Path $root "$Name.ps1";[IO.File]::WriteAllText($path,$text.Replace($Old,$New));return $path
}
function Reject-Mutant([string]$Name,[scriptblock]$Probe){
  $failure=$null;try{& $Probe}catch{$failure=$_.Exception.Message}
  Check ($failure-like'ASSERTION FAILED:*') "mutant survived or probe broke: $Name"
  Json (Join-Path $root "$Name.oracle.json") @{accepted=$false;failure=$failure}
  Write-Output "MUTANT $Name RED (assertion rejected)"
}
function Stub([string]$Name,[string]$Body){
  $path=Join-Path $root "$Name.ps1"
  [IO.File]::WriteAllText($path,'param($Label,$RuntimeRoot,$HistoryPath,$TranscriptPath,$ObservedAt)'+"`n"+$Body);return $path
}
function Same-Worker($Spec){
  foreach($pair in @(@($Spec.launcherPid,$Spec.launcherStartIdentity),@($Spec.childPid,$Spec.childStartIdentity))){
    $process=Get-Process -Id $pair[0] -ErrorAction Stop
    Check ($process.StartTime.ToUniversalTime().Ticks-eq[datetimeoffset]::Parse($pair[1]).UtcTicks) 'live worker identity changed or was terminated'
  }
  if($script:descendant){
    $process=Get-Process -Id $script:descendant.pid -ErrorAction Stop
    Check ($process.StartTime.ToUniversalTime().Ticks-eq[datetimeoffset]::Parse($script:descendant.startIdentity).UtcTicks) 'descendant identity changed or was terminated'
  }
}
function Growth-Oracle($Result,$Case){
  Check ($Result.exit-eq0-and@($Result.events|Where-Object event -eq PROGRESS).Count-ge2-and
    @($Result.events|Where-Object relaunch -eq $true).Count-eq0-and$Result.events[0].lanes[0].transcriptPath-ceq$Case.transcript) 'AC4 descendant progress must be observed without replacing transcript or relaunching'
  $unchanged=0
  foreach($event in $Result.events){
    switch($event.event){
      PROGRESS {$unchanged=0}
      UNCHANGED {$unchanged++;Check ($event.unchangedPolls-eq$unchanged) 'AC4 growth did not reset exact poll count'}
      DETECTED {Check ($unchanged-eq3) 'AC4 detection before three consecutive unchanged polls'}
      OBSERVATION {$unchanged=0;Check ($event.status-ceq'LIVE_SLOW') 'AC4 live descendant observation'}
    }
  }
}
try{
  $terminal=New-Producer 'synthetic-terminal' terminal
  $reducer=Join-Path $PSScriptRoot 'lane-stall-watchdog.ps1'
  $reducerHash=(Get-FileHash $reducer).Hash
  if($Only-in@('All','AC1')){
    $r=Batch @((Lane $terminal)) 'AC1-real-producer-spaces'
    Check ($r.exit-eq0-and$r.events[-1].reason-ceq'ALL_TERMINAL'-and@($r.events|Where-Object status -eq TERMINAL_SUCCESS).Count-eq1) 'AC1 actual entry and real spec with native space/drive-colon paths'
    $started=$r.events[0];Check ($started.lanes[0].label-ceq$terminal.label-and$started.lanes[0].runtimeRoot-ceq$terminal.runtime-and$started.lanes[0].transcriptPath-ceq$terminal.transcript) 'AC1 exact inputs'
    $capture=Join-Path $root 'forwarded.json'
    $spy=Stub 'forwarding-spy' ('@{label=$Label;runtimeRoot=$RuntimeRoot;transcriptPath=$TranscriptPath;observedAt=$ObservedAt}|ConvertTo-Json|Set-Content -LiteralPath '''+$capture.Replace("'","''")+''';& '''+$reducer.Replace("'","''")+''' @PSBoundParameters;exit $LASTEXITCODE')
    $r=Batch @((Lane $terminal)) 'AC1-forwarded-detection' @('-ReducerScript',$spy)
    $forwarded=Get-Content $capture -Raw|ConvertFrom-Json -DateKind String
    $detection=@($r.events|Where-Object event -eq DETECTED)[0]
    Check ($forwarded.label-ceq$terminal.label-and$forwarded.runtimeRoot-ceq$terminal.runtime-and$forwarded.transcriptPath-ceq$terminal.transcript-and$forwarded.observedAt-ceq$detection.observedAt) 'AC1 exact detection time forwarded unchanged'
    $wsl=Lane $terminal;foreach($key in @('runtimeRoot','transcriptPath')){$p=$wsl[$key];$wsl[$key]='/mnt/'+$p.Substring(0,1).ToLowerInvariant()+'/'+$p.Substring(3).Replace('\','/')}
    $r=Batch @($wsl) 'AC1-retained-wsl-path';Check ($r.exit-eq0-and$r.events[-1].reason-eq'ALL_TERMINAL') 'AC1 retained drive mount translated without WSL'
    $dead=New-Producer 'synthetic-dead' dead
    $calls=Join-Path $root 'stub-dispatches.txt';$dispatch=Join-Path $root 'safe-dispatch.ps1'
    [IO.File]::WriteAllText($dispatch,'[IO.File]::AppendAllText('''+$calls.Replace("'","''")+''',"stub dispatch`n");exit 19')
    $stale=[datetimeoffset]::UtcNow.AddSeconds(-600).ToString('o')
    $args=@('-TestObservedAt',$stale,'-DispatchScript',$dispatch,'-SynchronousDispatch')
    # 8186: expiry is a contained, lane-labeled reducer failure (nonzero exit, no dispatch), not a batch abort.
    $oracle={param($r) Reducer-Failure $r 'WATCHDOG_RELAUNCH_WINDOW_EXPIRED' 'AC1 stale detection reaches expiry with zero dispatches' 'WINDOW_EXPIRED' $dead.label;Check (-not(Test-Path $calls)) 'AC1 stale detection dispatched'}
    $r=Batch @((Lane $dead)) 'AC1-stale-detection' $args;& $oracle $r
    $mutant=Mutate 'omit-observed-at' ",'-ObservedAt',`$DetectedAt" ''
    $r=Batch @((Lane $dead)) 'AC1-omission-mutant' ($args+@('-ReducerScript',$reducer)) $mutant
    Check (Test-Path $calls) 'AC1 omission must reach stub dispatch, not an earlier refusal'
    Reject-Mutant 'omit-ObservedAt' {& $oracle $r}
    Write-Output 'PASS AC1 actual-entry-real-producer-spaces-drive-colon / detection-forwarding / stale-window'
  }
  if($Only-in@('All','AC2')){
    & $PSCommandPath -Only AC2 -BeforeFix
    Write-Output 'PASS AC2 legacy-shell-explicit-native-required-nonzero-secret-free'
    $good='''{"schemaVersion":"watchdog-observation-result/v1","status":"TERMINAL_SUCCESS","relaunch":false}'''
    foreach($mode in @('missing-executable','non-executable','exec-format','valid-nonzero','missing-result','malformed-result','wrong-schema','unknown-state','wrong-relaunch','missing-relaunch-label')){
      $extra=@()
      switch($mode){
        missing-executable {$extra=@('-TransportPath',(Join-Path $root 'absent.exe'))}
        non-executable {$bad=Join-Path $root 'not executable.exe';[IO.File]::WriteAllText($bad,'SYNTHETIC_SECRET_8136');$extra=@('-TransportPath',$bad)}
        exec-format {$script=Stub $mode "[Console]::Error.WriteLine('Exec format error SYNTHETIC_SECRET_8136');exit 126";$extra=@('-ReducerScript',$script)}
        valid-nonzero {$script=Stub $mode ($good+"`n[Console]::Error.WriteLine('SYNTHETIC_SECRET_8136');exit 19");$extra=@('-ReducerScript',$script)}
        missing-result {$extra=@('-ReducerScript',(Stub $mode 'exit 0'))}
        malformed-result {$extra=@('-ReducerScript',(Stub $mode "'SYNTHETIC_SECRET_8136 invalid JSON'"))}
        wrong-schema {$extra=@('-ReducerScript',(Stub $mode ($good.Replace('watchdog-observation-result/v1','bogus'))))}
        unknown-state {$extra=@('-ReducerScript',(Stub $mode ($good.Replace('TERMINAL_SUCCESS','SYNTHETIC_SECRET_8136'))))}
        wrong-relaunch {$extra=@('-ReducerScript',(Stub $mode ($good.Replace('false','true'))))}
        missing-relaunch-label {$extra=@('-ReducerScript',(Stub $mode ($good.Replace('TERMINAL_SUCCESS','RELAUNCHED').Replace('false','true'))))}
      }
      # 8186 split: a started reducer's exit/result defect is a contained lane REDUCER_FAILURE;
      # transport absence and unfollowable relaunch claims stay fatal TRANSPORT_FAILURE.
      $reducerCode=switch($mode){{$_-in@('exec-format','valid-nonzero')}{'REDUCER_EXIT'}{$_-in@('missing-result','malformed-result','wrong-schema','unknown-state')}{'RESULT_INVALID'}default{''}}
      $r=Batch @((Lane $terminal)) "AC2-$mode" $extra
      if($reducerCode){Reducer-Failure $r $reducerCode "AC2 $mode is a contained lane reducer failure" 'WINDOW_EXPIRED' $terminal.label;Check (@($r.events|Where-Object event -eq OBSERVATION).Count-eq0) "AC2 $mode became lane health"}
      else{Failure $r "AC2 $mode fails closed"}
      if($mode-eq'valid-nonzero'){
        $mutant=Mutate 'ignore-exit' 'if($process.ExitCode-ne0){' 'if($false){'
        $m=Batch @((Lane $terminal)) 'AC2-nonzero-mutant' $extra $mutant
        Check ($m.exit-eq0-and@($m.events|Where-Object status -eq TERMINAL_SUCCESS).Count-eq1) 'AC2 exit mutant must launder the nonzero command into health'
        Reject-Mutant 'ignore-native-exit' {Reducer-Failure $m 'REDUCER_EXIT' 'nonzero cannot be lane health'}
      }
      if($mode-eq'wrong-schema'){
        $mutant=Mutate 'ignore-result-schema' '$result.schemaVersion-cne''watchdog-observation-result/v1''' '$false'
        $m=Batch @((Lane $terminal)) 'AC2-schema-mutant' $extra $mutant
        Check ($m.exit-eq0-and@($m.events|Where-Object status -eq TERMINAL_SUCCESS).Count-eq1) 'AC2 schema mutant must launder the invalid result into health'
        Reject-Mutant 'ignore-result-schema' {Reducer-Failure $m 'RESULT_INVALID' 'invalid result schema cannot be lane health'}
      }
      Write-Output "PASS AC2 $mode"
    }
    foreach($mode in @('missing-transcript','missing-spec','malformed-spec','duplicate-lane','empty-input','wrong-transcript')){
      $lane=Lane $terminal;$lanes=@($lane);$backup=$null
      switch($mode){
        missing-transcript {$backup=[IO.File]::ReadAllBytes($terminal.transcript);[IO.File]::Delete($terminal.transcript)}
        missing-spec {$backup=[IO.File]::ReadAllBytes($terminal.spec);[IO.File]::Delete($terminal.spec)}
        malformed-spec {$backup=[IO.File]::ReadAllBytes($terminal.spec);[IO.File]::WriteAllText($terminal.spec,'SYNTHETIC_SECRET_8136 malformed')}
        duplicate-lane {$lanes=@($lane,$lane)}
        empty-input {$lanes=@()}
        wrong-transcript {$lane.transcriptPath=$terminal.progress}
      }
      try{$r=Batch $lanes "AC2-$mode"
        # A present-but-unreadable spec is the reducer's refusal (lane-labeled REDUCER_EXIT);
        # every other mode is shared input loss and stays a fatal transport failure.
        if($mode-eq'malformed-spec'){Reducer-Failure $r 'REDUCER_EXIT' "AC2 $mode is a contained lane reducer failure" 'WINDOW_EXPIRED' $terminal.label;Check (@($r.events|Where-Object event -eq OBSERVATION).Count-eq0) "AC2 $mode became lane health"}
        else{Failure $r "AC2 $mode unknown"}}finally{
        if($mode-eq'missing-transcript'){[IO.File]::WriteAllBytes($terminal.transcript,$backup)}
        if($mode-in@('missing-spec','malformed-spec')){[IO.File]::WriteAllBytes($terminal.spec,$backup)}
      }
      Write-Output "PASS AC2 $mode"
    }
  }
  if($Only-in@('All','AC3','AC4')){
    $live=New-Producer 'synthetic-live' live;$spec=Get-Content $live.spec -Raw|ConvertFrom-Json -DateKind String
    $script:descendant=Get-Content ($live.progress+'.child.json') -Raw|ConvertFrom-Json -DateKind String
    if($Only-in@('All','AC3')){
      $before=[IO.File]::ReadAllText($live.spec)
      $r=Batch @((Lane $live)) 'AC3-live-stale-text' @() $entry 4
      Check ($r.exit-eq0-and@($r.events|Where-Object status -eq LIVE_SLOW).Count-ge1-and@($r.events|Where-Object relaunch -eq $true).Count-eq0) 'AC3 stale text must delegate to LIVE_SLOW, never launch/kill'
      Same-Worker $spec;Check ([IO.File]::ReadAllText($live.spec)-ceq$before) 'AC3 live spec changed'
      Check (@(Get-ChildItem -LiteralPath $live.runtime -Filter 'watchdog-lane-*.json').Count-eq1) 'AC3 unexpected launch'
      $mutant=Mutate 'omit-live-observation' '$result=Observe $lane $detectedAt' '$result=[pscustomobject]@{status="TERMINAL_SUCCESS";relaunch=$false;pid=$PID}'
      $m=Batch @((Lane $live)) 'AC3-live-omission-mutant' @('-ReducerScript',$reducer) $mutant
      Check ($m.exit-eq0-and@($m.events|Where-Object status -eq TERMINAL_SUCCESS).Count-eq1) 'AC3 mutant must reach the substituted result, not fail transport setup'
      Reject-Mutant 'omit-live-reducer-call' {Check (@($m.events|Where-Object status -eq LIVE_SLOW).Count-ge1) 'AC3 live oracle'}
      Same-Worker $spec
      Write-Output 'PASS AC3 real-live-worker-stale-text-LIVE_SLOW-zero-launch-zero-kill-same-identity'
    }
    if($Only-in@('All','AC4')){
      $skillPath=Join-Path $PSScriptRoot 'controller-skills/milestone-orchestrator/SKILL.md'
      $skillBytes=[IO.File]::ReadAllBytes($skillPath);$skill=[Text.UTF8Encoding]::new($false,$true).GetString($skillBytes)
      Check (-not($skillBytes[0]-eq0xef-and$skillBytes[1]-eq0xbb-and$skillBytes[2]-eq0xbf)-and$skill-notmatch'(?<!\r)\n|\r(?!\n)'-and$skill.Contains('Arm native PowerShell 7 `lane-stall-watchdog-batch.ps1 -LanesPath')) 'AC4 native caller and strict UTF-8/CRLF skill'
      $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($entry,[ref]$tokens,[ref]$errors)
      Check ($errors.Count-eq0) 'batch parses'
      foreach($pair in @(@('PollSeconds','120'),@('UnchangedPolls','3'),@('WindowSeconds','7200'))){
        $p=@($ast.ParamBlock.Parameters|Where-Object {$_.Name.VariablePath.UserPath-eq$pair[0]})[0];Check ($p.DefaultValue.Extent.Text-ceq$pair[1]) "AC4 default $($pair[0])"
      }
      $r=Batch @((Lane $terminal),(Lane $live)) 'AC4-multiple-steady-expiry' @() $entry 5
      Check ($r.exit-eq0-and$r.events[-1].reason-ceq'WINDOW_EXPIRED'-and@($r.events|Where-Object status -eq TERMINAL_SUCCESS).Count-eq1-and@($r.events|Where-Object status -eq LIVE_SLOW).Count-ge1) 'AC4 multi-lane expiry-only exit'
      Check (-not($r.stdout+$r.stderr).Contains('no stalls')) 'AC4 expiry made health claim'
      Check ($r.events[0].watcher.pid-eq$r.pid-and$r.events[-1].watcher.startIdentity-ceq$r.events[0].watcher.startIdentity-and$r.events[0].source.entrySha256-ceq(Get-FileHash $entry).Hash.ToLowerInvariant()) 'AC4 startup/exit source and process identity'
      Same-Worker $spec
      # Steady monitoring ends on the second actual live observation, not an
      # assumed number of CIM/import invocations inside a short wall-clock window.
      # End-Native's existing 60-second command deadline is unchanged.
      $steadyManifest=Join-Path $root 'AC4-steady-rearm.lanes.json';$counter=Join-Path $root 'steady-count.txt'
      $steadyBody='$out=& '''+$reducer.Replace("'","''")+''' @PSBoundParameters;$out;if(($out|ConvertFrom-Json).status-eq''LIVE_SLOW''){[IO.File]::AppendAllText('''+$counter.Replace("'","''")+''',"1`n");if(@(Get-Content -LiteralPath '''+$counter.Replace("'","''")+''').Count-eq2){[IO.File]::AppendAllText('''+$steadyManifest.Replace("'","''")+'''," ")}}'
      $steady=Stub 'steady-real-reducer' $steadyBody
      $r=Batch @((Lane $terminal),(Lane $live)) 'AC4-steady-rearm' @('-ReducerScript',$steady) $entry 7200
      Check ($r.exit-eq0-and$r.events[-1].reason-ceq'MEMBERSHIP_CHANGED'-and@($r.events|Where-Object status -eq LIVE_SLOW).Count-eq2) 'AC4 steady second actual live observation before re-arm'
      $mutant=Mutate 'exit-first-observation' 'if(@($lanes|Where-Object{-not$_.terminal}).Count-eq0)' 'if($true)'
      [IO.File]::Delete($counter)
      $steadyMutant=Stub 'steady-real-reducer-mutant-input' ($steadyBody.Replace($steadyManifest,(Join-Path $root 'AC4-first-observation-mutant.lanes.json')))
      $m=Batch @((Lane $terminal),(Lane $live)) 'AC4-first-observation-mutant' @('-ReducerScript',$steadyMutant) $mutant 7200
      Check ($m.exit-eq0-and$m.events[-1].reason-ceq'ALL_TERMINAL') 'AC4 first-observation mutant must reach the premature terminal exit'
      Reject-Mutant 'exit-on-first-observation' {Check ($m.events[-1].reason-ceq'MEMBERSHIP_CHANGED'-and@($m.events|Where-Object status -eq LIVE_SLOW).Count-eq2) 'AC4 steady multi-lane oracle'}
      $membershipManifest=Join-Path $root 'AC4-membership-exit.lanes.json'
      $membershipStub=Stub 'change-membership' ('[IO.File]::AppendAllText('''+$membershipManifest.Replace("'","''")+'''," ");''{"schemaVersion":"watchdog-observation-result/v1","status":"LIVE_SLOW","relaunch":false}''')
      $r=Batch @((Lane $live)) 'AC4-membership-exit' @('-ReducerScript',$membershipStub) $entry 3
      Check ($r.exit-eq0-and$r.events[-1].reason-ceq'MEMBERSHIP_CHANGED') 'AC4 changed snapshot must release watcher for re-arm'
      $mutant=Mutate 'ignore-membership-change' '$exitReason=''MEMBERSHIP_CHANGED'';break' '$null=$null'
      $mutantManifest=Join-Path $root 'AC4-membership-mutant.lanes.json'
      $mutantStub=Stub 'change-membership-mutant-input' ([IO.File]::ReadAllText($membershipStub).Split("`n",2)[1].Replace($membershipManifest,$mutantManifest))
      $m=Batch @((Lane $live)) 'AC4-membership-mutant' @('-ReducerScript',$mutantStub) $mutant 2
      Check ($m.exit-eq0-and$m.events[-1].reason-ceq'WINDOW_EXPIRED') 'AC4 membership mutant must reach expiry, not an unrelated failure'
      Check ([IO.File]::ReadAllText($mutantManifest).EndsWith(' ')) 'membership mutant did not receive the changed input'
      Reject-Mutant 'ignore-membership-change' {Check ($m.events[-1].reason-ceq'MEMBERSHIP_CHANGED') 'AC4 membership oracle'}
      $r=Batch @((Lane $live)) 'AC4-failure-keeps-worker' @('-ReducerScript',(Stub 'AC4-failure' "throw 'SYNTHETIC_SECRET_8136'"))
      # 8186: the throwing reducer is a contained, secret-free lane failure; the watcher still exits nonzero and never touches the worker.
      Reducer-Failure $r 'REDUCER_EXIT' 'AC4 failure is contained, nonzero, and secret-free' 'WINDOW_EXPIRED' $live.label
      Same-Worker $spec
      [IO.File]::WriteAllText($live.grow,'grow')
      $r=Batch @((Lane $live -Progress)) 'AC4-session-growth' @() $entry 1 3
      Growth-Oracle $r $live
      $mutant=Mutate 'ignore-session-growth' '$size-ne$lane.size-or$progressSize-ne$lane.progressSize' '$size-ne$lane.size'
      $m=Batch @((Lane $live -Progress)) 'AC4-growth-mutant' @('-ReducerScript',$reducer) $mutant 1 3
      Check ($m.exit-eq0-and@($m.events|Where-Object status -eq LIVE_SLOW).Count-ge1) 'AC4 growth mutant must reach the real reducer'
      Reject-Mutant 'ignore-session-growth' {Growth-Oracle $m $live}
      [IO.File]::Delete($live.grow);Same-Worker $spec
      [IO.File]::WriteAllText($live.release,'release');$done=End-Native $live.handle;Check ($done.exit-eq0) 'cooperative worker completion'
      Check (@(Get-Process -Id $script:descendant.pid -ErrorAction SilentlyContinue).Count-eq0) 'cooperative descendant survived completion'
      $r=Batch @((Lane $terminal),(Lane $live)) 'AC4-rearm-all-terminal' @() $entry 8
      Check ($r.exit-eq0-and$r.events[-1].reason-ceq'ALL_TERMINAL'-and@($r.events|Where-Object status -eq TERMINAL_SUCCESS).Count-eq2) 'AC4 membership re-arm all-terminal exit'
      $replacement=New-Producer 'synthetic-replacement' terminal $terminal.runtime
      $follow=Stub 'synthetic-relaunch-result' ('if($Label-ceq''synthetic-terminal''){''{"schemaVersion":"watchdog-observation-result/v1","status":"RELAUNCHED","relaunch":true,"label":"synthetic-replacement"}''}else{& '''+$reducer.Replace("'","''")+''' @PSBoundParameters}')
      $r=Batch @((Lane $terminal)) 'AC4-follow-replacement' @('-ReducerScript',$follow) $entry 8
      Check ($r.exit-eq0-and$r.events[-1].reason-ceq'ALL_TERMINAL'-and@($r.events|Where-Object event -eq MEMBERSHIP_CHANGED).Count-eq1-and@($r.events|Where-Object {$_.event-eq'OBSERVATION'-and$_.label-ceq$replacement.label-and$_.status-ceq'TERMINAL_SUCCESS'}).Count-eq1) 'AC4 synthetic relaunch result follows real replacement spec'
      Write-Output 'PASS AC4 defaults / multiple-lanes / steady-monitoring / session-growth / expiry-only / membership-rearm / all-terminal / no-surviving-helpers'
    }
  }
  $named8186=@('mixed-role-isolation','reducer-failure-isolation','day-after-error-and-observation','launch-status-observed','transport-vs-reducer-failure','relaunch-follow-stays-fatal')
  if($Only-in(@('All','AC8186')+$named8186)){
    $run8186=if($Only-in@('All','AC8186')){$named8186}else{@($Only)}
    # 8186: actual dispatch-lane producers for every watched role. Planning/review lanes
    # live in dispatch-lane's own envelope (row 0-15, empty or placed; detached only for review).
    $implDead=New-Producer 'synthetic-impl-dead' dead
    $planningDead=New-Producer 'synthetic-planning-dead' dead -Role planning -Row 8 -Placement 'override-Todd'
    $reviewDetached=New-Producer 'synthetic-review-detached' dead -Role review -Row 11 -Placement 'override-Todd' -Detached
    $reviewRow0=New-Producer 'synthetic-review-row0' dead -Role review -Row 0 -Placement ''
    foreach($pair in @(@($planningDead,'planning',8,'override-Todd','synthetic/8136'),@($reviewDetached,'review',11,'override-Todd',''),@($reviewRow0,'review',0,'',"synthetic/8136"))){
      $s=Get-Content $pair[0].spec -Raw|ConvertFrom-Json -DateKind String
      Check ($s.laneRole-ceq$pair[1]-and$s.row-eq$pair[2]-and$s.placement-ceq$pair[3]-and$s.branch-ceq$pair[4]-and$s.state-ceq'exited'-and$s.exitCode-eq17) "8186 real $($pair[1]) producer envelope: $($pair[0].label)"
    }
    $roleCases=@($planningDead,$reviewDetached,$reviewRow0);$A=$implDead;$B=$terminal
    function Events($Result,[string]$Event,[string]$Label=''){return @($Result.events|Where-Object{$_.event-ceq$Event-and(-not$Label-or$_.label-ceq$Label)})}
    function Snapshot([string]$Dir){$m=@{};foreach($f in Get-ChildItem -LiteralPath $Dir -File -Recurse){$m[$f.FullName]=(Get-FileHash -LiteralPath $f.FullName).Hash};return $m}
    function Same-Snapshot([hashtable]$Before,[string]$Dir,[string]$Message){
      $after=Snapshot $Dir;Check ($after.Count-eq$Before.Count-and@($Before.Keys|Where-Object{-not$after.ContainsKey($_)-or$after[$_]-cne$Before[$_]}).Count-eq0) $Message
    }
    function Cadence($Result,[int]$Unchanged){
      # After a reduction or a contained lane error the per-lane unchanged count restarts at 1.
      $counts=@{}
      foreach($e in $Result.events){
        if(-not$e.label){continue}
        switch($e.event){
          PROGRESS {$counts[$e.label]=0}
          UNCHANGED {$counts[$e.label]=1+[int]$counts[$e.label];Check ($e.unchangedPolls-eq$counts[$e.label]) "8186 cadence drift for $($e.label)"}
          DETECTED {Check ($counts[$e.label]-eq$Unchanged) "8186 detection before $Unchanged unchanged polls for $($e.label)"}
          OBSERVATION {$counts[$e.label]=0}
          REDUCER_FAILURE {$counts[$e.label]=0}
        }
      }
    }
    function Obs([string]$Status){return "'"+'{"schemaVersion":"watchdog-observation-result/v1","status":"'+$Status+'","relaunch":false}'+"'"}
    function Touch([string]$Name){return '[IO.File]::AppendAllText('''+(Join-Path $root "$Name.lanes.json").Replace("'","''")+'''," ");'}
    $fail19="[Console]::Error.WriteLine('SYNTHETIC_SECRET_8136');exit 19"
    function Seq-Stub([string]$Name,[string]$L1,[string[]]$S1,[string]$L2='',[string[]]$S2=@()){
      # Per-label call sequence: call k runs the k-th body (the last body repeats); other labels reach the real reducer.
      $counter=Join-Path $root "$Name.calls"
      $body='$counter='''+$counter.Replace("'","''")+''';$n=1;if(Test-Path -LiteralPath $counter){$n=@(Get-Content -LiteralPath $counter|Where-Object{$_-ceq$Label}).Count+1};[IO.File]::AppendAllText($counter,$Label+"`n")'+"`n"+'switch($Label){'+"`n"
      foreach($pair in @(@($L1,$S1),@($L2,$S2))){
        if(-not$pair[0]){continue}
        $steps=@($pair[1]);$body+="'$($pair[0])'{`$i=[Math]::Min(`$n,$($steps.Count));switch(`$i){"
        for($k=0;$k-lt$steps.Count;$k++){$body+="$($k+1){$($steps[$k])}"}
        $body+="}}`n"
      }
      $body+='default{& '''+$reducer.Replace("'","''")+''' @PSBoundParameters;exit $LASTEXITCODE}'+"`n}"
      return Stub $Name $body
    }
    if('mixed-role-isolation'-in$run8186){
      $calls8186=Join-Path $root 'stub-dispatches-8186.txt';$dispatch8186=Join-Path $root 'safe-dispatch-8186.ps1'
      [IO.File]::WriteAllText($dispatch8186,'[IO.File]::AppendAllText('''+$calls8186.Replace("'","''")+''',"stub dispatch`n");exit 19')
      $stale8186=[datetimeoffset]::UtcNow.AddSeconds(-600).ToString('o')
      $snapshots=@{};foreach($c in $roleCases+@($A)){$snapshots[$c.label]=Snapshot $c.runtime}
      # The stale implementation lane sits between the role lanes so its failure must not stop them.
      $r=Batch @((Lane $planningDead),(Lane $reviewDetached),(Lane $A),(Lane $reviewRow0),(Lane $B)) 'AC8186-mixed-role-isolation' @('-TestObservedAt',$stale8186,'-DispatchScript',$dispatch8186,'-SynchronousDispatch') $entry 8
      Reducer-Failure $r 'WATCHDOG_RELAUNCH_WINDOW_EXPIRED' '8186 mixed roles: only the stale implementation lane is a contained expiry' 'WINDOW_EXPIRED' $A.label
      foreach($c in $roleCases){
        Check (@(Events $r OBSERVATION $c.label|Where-Object{$_.status-ceq'OBSERVATION_ONLY'-and$_.relaunch-eq$false}).Count-ge1-and@(Events $r OBSERVATION $c.label|Where-Object status -cne OBSERVATION_ONLY).Count-eq0-and@(Events $r REDUCER_FAILURE $c.label).Count-eq0) "8186 $($c.label) must be observation-only, never health, terminal or error"
      }
      Check (@(Events $r OBSERVATION $B.label|Where-Object status -ceq TERMINAL_SUCCESS).Count-eq1-and@(Events $r OBSERVATION $A.label).Count-eq0-and@($r.events|Where-Object relaunch -eq $true).Count-eq0-and-not(Test-Path $calls8186)) '8186 mixed roles: terminal sibling observed once; implementation lane never observed or dispatched'
      $firstFailure=[array]::IndexOf($r.events,(Events $r REDUCER_FAILURE)[0])
      Check (@($r.events|Select-Object -Skip ($firstFailure+1)|Where-Object{$_.event-ceq'OBSERVATION'-and$_.status-ceq'OBSERVATION_ONLY'}).Count-ge1) '8186 role siblings did not continue after the implementation failure'
      foreach($c in $roleCases+@($A)){Same-Snapshot $snapshots[$c.label] $c.runtime "8186 observation-only/expiry changed runtime bytes for $($c.label)"}
      Cadence $r 1
      Write-Output 'PASS 8186 mixed-role-isolation planning-row8/review-row11-detached/review-row0-empty observation-only around a contained implementation expiry'
    }
    if('reducer-failure-isolation'-in$run8186){
      $live8186=New-Producer 'synthetic-live-8186' live;$liveSpec8186=Get-Content $live8186.spec -Raw|ConvertFrom-Json -DateKind String
      $script:descendant=Get-Content ($live8186.progress+'.child.json') -Raw|ConvertFrom-Json -DateKind String
      $badStub=Stub 'bad-lane-only' ('if($Label-ceq'''+$A.label+'''){'+$fail19+'}'+"`n"+'& '''+$reducer.Replace("'","''")+''' @PSBoundParameters;exit $LASTEXITCODE')
      $orders=@{first=@((Lane $A),(Lane $live8186),(Lane $B));middle=@((Lane $live8186),(Lane $A),(Lane $B));last=@((Lane $live8186),(Lane $B),(Lane $A))}
      $isolation={param($r,[string]$name)
        Reducer-Failure $r 'REDUCER_EXIT' "8186 $name`: bad lane is a contained REDUCER_EXIT" 'WINDOW_EXPIRED' $A.label
        $failures=Events $r REDUCER_FAILURE;$first=[array]::IndexOf($r.events,$failures[0])
        Check ($failures.Count-ge2-and@($r.events|Select-Object -Skip ($first+1)|Where-Object{$_.event-ceq'OBSERVATION'-and$_.status-ceq'LIVE_SLOW'-and$_.label-ceq$live8186.label}).Count-ge1) "8186 $name`: live sibling not observed after the first failure, or no later sweep"
        Check (@(Events $r OBSERVATION $B.label|Where-Object status -ceq TERMINAL_SUCCESS).Count-eq1-and@(Events $r OBSERVATION $A.label).Count-eq0-and@($r.events|Where-Object relaunch -eq $true).Count-eq0) "8186 $name`: terminal sibling observed once; bad lane never became health"
      }
      foreach($name in @('first','middle','last')){
        $r=Batch $orders[$name] "AC8186-isolation-$name" @('-ReducerScript',$badStub) $entry 10
        & $isolation $r $name;Cadence $r 1;Same-Worker $liveSpec8186
      }
      $mutant=Mutate 'batch-abort-on-reducer-error' "`$reducerFailureCodes=@('REDUCER_EXIT','RESULT_INVALID','WATCHDOG_RELAUNCH_WINDOW_EXPIRED')" '$reducerFailureCodes=@()'
      $m=Batch $orders['first'] 'AC8186-isolation-mutant' @('-ReducerScript',$badStub) $mutant 10
      Check ($m.exit-ne0-and@(Events $m TRANSPORT_FAILURE).Count-eq1-and@(Events $m OBSERVATION).Count-eq0) '8186 abort mutant must reach the batch-wide abort, not an unrelated failure'
      Reject-Mutant 'batch-abort-on-reducer-error' {& $isolation $m 'mutant'}
      Same-Worker $liveSpec8186
      [IO.File]::WriteAllText($live8186.release,'release');$done=End-Native $live8186.handle;Check ($done.exit-eq0) '8186 cooperative live worker completion'
      Write-Output 'PASS 8186 reducer-failure-isolation bad lane first/middle/last with live+terminal siblings'
    }
    if('day-after-error-and-observation'-in$run8186){
      $P=$planningDead
      $dayStub=Stub 'day-error-lane' ('if($Label-ceq'''+$A.label+'''){'+$fail19+'}'+"`n"+'& '''+$reducer.Replace("'","''")+''' @PSBoundParameters;exit $LASTEXITCODE')
      $r=Batch @((Lane $A),(Lane $P)) 'AC8186-two-cycles' @('-ReducerScript',$dayStub) $entry 8 2
      Reducer-Failure $r 'REDUCER_EXIT' '8186 two cycles: error lane stays a contained, unresolved REDUCER_EXIT' 'WINDOW_EXPIRED' $A.label
      Check (@(Events $r REDUCER_FAILURE $A.label).Count-ge2-and@(Events $r OBSERVATION $P.label|Where-Object status -ceq OBSERVATION_ONLY).Count-ge2-and@(Events $r OBSERVATION $P.label|Where-Object status -cne OBSERVATION_ONLY).Count-eq0-and@(Events $r OBSERVATION $A.label).Count-eq0) '8186 two cycles: error and observation-only lanes both stayed watched into a second cycle'
      Cadence $r 2
      $mutant=Mutate 'mark-observation-terminal' "`$lane.terminal=`$result.status-cin@('TERMINAL_SUCCESS','TERMINAL_AUTHORITY_STOP')" "`$lane.terminal=`$result.status-cin@('TERMINAL_SUCCESS','TERMINAL_AUTHORITY_STOP','OBSERVATION_ONLY')"
      $m=Batch @((Lane $A),(Lane $P)) 'AC8186-terminal-mutant' @('-ReducerScript',$dayStub) $mutant 8 2
      Check (@(Events $m OBSERVATION $P.label).Count-eq1-and@(Events $m REDUCER_FAILURE $A.label).Count-ge2) '8186 terminal mutant must stop watching the planning lane after one observation'
      Reject-Mutant 'mark-observation-terminal' {Check (@(Events $m OBSERVATION $P.label|Where-Object status -ceq OBSERVATION_ONLY).Count-ge2) '8186 observation-only lane must stay watched'}
      # Error, valid reduction, error again: the last error is unresolved at a membership exit.
      $n='AC8186-error-valid-error';$s=Seq-Stub $n $A.label @($fail19,(Obs LIVE_SLOW),$fail19) $B.label @((Obs LIVE_SLOW),(Obs LIVE_SLOW),((Touch $n)+(Obs LIVE_SLOW)))
      $r=Batch @((Lane $A),(Lane $B)) $n @('-ReducerScript',$s) $entry 30
      Reducer-Failure $r 'REDUCER_EXIT' '8186 error-valid-error: a later error is unresolved at membership exit' 'MEMBERSHIP_CHANGED' $A.label
      Check (@(Events $r REDUCER_FAILURE $A.label).Count-eq2-and@(Events $r OBSERVATION $A.label|Where-Object status -ceq LIVE_SLOW).Count-eq1) '8186 error-valid-error sequence'
      Cadence $r 1
      # Error then valid reduction: recovered errors permit a normal zero exit.
      $n='AC8186-recovered';$s=Seq-Stub $n $A.label @($fail19,(Obs LIVE_SLOW)) $B.label @((Obs LIVE_SLOW),((Touch $n)+(Obs LIVE_SLOW)))
      $r=Batch @((Lane $A),(Lane $B)) $n @('-ReducerScript',$s) $entry 30
      Check ($r.exit-eq0-and$r.events[-1].reason-ceq'MEMBERSHIP_CHANGED'-and$r.events[-1].unresolvedReducerFailures-eq0-and@(Events $r REDUCER_FAILURE $A.label).Count-eq1-and@(Events $r OBSERVATION $A.label|Where-Object status -ceq LIVE_SLOW).Count-eq1-and@(Events $r TRANSPORT_FAILURE).Count-eq0) '8186 recovered error permits normal exit'
      # Error then DUPLICATE_SKIPPED: a duplicate never resolves the error.
      $n='AC8186-error-then-duplicate';$s=Seq-Stub $n $A.label @($fail19,(Obs DUPLICATE_SKIPPED)) $B.label @((Obs LIVE_SLOW),((Touch $n)+(Obs LIVE_SLOW)))
      $r=Batch @((Lane $A),(Lane $B)) $n @('-ReducerScript',$s) $entry 30
      Reducer-Failure $r 'REDUCER_EXIT' '8186 error-then-duplicate stays unresolved' 'MEMBERSHIP_CHANGED' $A.label
      Check (@(Events $r OBSERVATION $A.label|Where-Object status -ceq DUPLICATE_SKIPPED).Count-eq1) '8186 duplicate observation recorded'
      $mutant=Mutate 'clear-error-on-duplicate' "if(`$result.status-cne'DUPLICATE_SKIPPED'){`$lane.unresolved=`$false}" '$lane.unresolved=$false'
      $n='AC8186-duplicate-mutant';$s=Seq-Stub $n $A.label @($fail19,(Obs DUPLICATE_SKIPPED)) $B.label @((Obs LIVE_SLOW),((Touch $n)+(Obs LIVE_SLOW)))
      $m=Batch @((Lane $A),(Lane $B)) $n @('-ReducerScript',$s) $mutant 30
      Check ($m.exit-eq0-and$m.events[-1].unresolvedReducerFailures-eq0-and@(Events $m OBSERVATION $A.label|Where-Object status -ceq DUPLICATE_SKIPPED).Count-eq1) '8186 duplicate mutant must launder the error through the duplicate'
      Reject-Mutant 'clear-error-on-duplicate' {Reducer-Failure $m 'REDUCER_EXIT' '8186 duplicate oracle' 'MEMBERSHIP_CHANGED' $A.label}
      # Error then transcript growth without any later reduction: growth is cadence, not recovery.
      $growthStep='[IO.File]::AppendAllText($TranscriptPath,"synthetic growth`n");'+$fail19
      $growthOracle={param($r,[string]$msg)
        Reducer-Failure $r 'REDUCER_EXIT' $msg 'MEMBERSHIP_CHANGED' $A.label
        $first=[array]::IndexOf($r.events,(Events $r REDUCER_FAILURE $A.label)[0])
        Check (@(Events $r REDUCER_FAILURE $A.label).Count-eq1-and@($r.events|Select-Object -Skip ($first+1)|Where-Object{$_.event-ceq'PROGRESS'-and$_.label-ceq$A.label}).Count-ge1-and@(Events $r OBSERVATION $A.label).Count-eq0) "$msg (growth after the error, no later reduction)"
      }
      $transcriptBackup=[IO.File]::ReadAllBytes($A.transcript)
      try{
        $n='AC8186-growth-without-recovery';$s=Seq-Stub $n $A.label @($growthStep) $B.label @((Obs LIVE_SLOW),((Touch $n)+(Obs LIVE_SLOW)))
        $r=Batch @((Lane $A),(Lane $B)) $n @('-ReducerScript',$s) $entry 30
        & $growthOracle $r '8186 growth without recovery stays unresolved'
        [IO.File]::WriteAllBytes($A.transcript,$transcriptBackup)
        $mutant=Mutate 'clear-error-on-growth' '$lane.size=$size;$lane.progressSize=$progressSize;$lane.unchanged=0' '$lane.size=$size;$lane.progressSize=$progressSize;$lane.unchanged=0;$lane.unresolved=$false'
        $n='AC8186-growth-mutant';$s=Seq-Stub $n $A.label @($growthStep) $B.label @((Obs LIVE_SLOW),((Touch $n)+(Obs LIVE_SLOW)))
        $m=Batch @((Lane $A),(Lane $B)) $n @('-ReducerScript',$s) $mutant 30
        Check ($m.exit-eq0-and$m.events[-1].unresolvedReducerFailures-eq0-and@(Events $m PROGRESS $A.label).Count-ge1) '8186 growth mutant must launder the error through growth'
        Reject-Mutant 'clear-error-on-growth' {& $growthOracle $m '8186 growth oracle'}
      }finally{[IO.File]::WriteAllBytes($A.transcript,$transcriptBackup)}
      # A terminal sibling never masks an unresolved error; a recovered lane can still reach ALL_TERMINAL.
      $n='AC8186-terminal-sibling';$s=Seq-Stub $n $A.label @($fail19)
      $r=Batch @((Lane $A),(Lane $B)) $n @('-ReducerScript',$s) $entry 4
      Reducer-Failure $r 'REDUCER_EXIT' '8186 terminal sibling: unresolved error still exits nonzero at expiry' 'WINDOW_EXPIRED' $A.label
      Check (@(Events $r OBSERVATION $B.label|Where-Object status -ceq TERMINAL_SUCCESS).Count-eq1-and@(Events $r REDUCER_FAILURE $A.label).Count-ge2) '8186 terminal sibling observed once while the error lane kept failing'
      $n='AC8186-all-terminal-after-recovery';$s=Seq-Stub $n $A.label @($fail19,(Obs TERMINAL_SUCCESS))
      $r=Batch @((Lane $A),(Lane $B)) $n @('-ReducerScript',$s) $entry 30
      Check ($r.exit-eq0-and$r.events[-1].reason-ceq'ALL_TERMINAL'-and$r.events[-1].unresolvedReducerFailures-eq0-and@(Events $r REDUCER_FAILURE $A.label).Count-eq1-and@(Events $r OBSERVATION|Where-Object status -ceq TERMINAL_SUCCESS).Count-eq2) '8186 recovered error lane reaches ALL_TERMINAL with zero exit'
      Write-Output 'PASS 8186 day-after-error-and-observation two-cycles / error-valid-error / recovered / error-then-duplicate / growth-without-recovery / terminal-sibling / all-terminal'
    }
    if('launch-status-observed'-in$run8186){
      $n='AC8186-launch-status';$s=Seq-Stub $n $A.label @((Obs LAUNCH_PENDING),((Touch $n)+(Obs LAUNCH_FAILED)))
      $r=Batch @((Lane $A)) $n @('-ReducerScript',$s) $entry 30
      $statuses=@(Events $r OBSERVATION $A.label|ForEach-Object status)
      Check ($r.exit-eq0-and$r.events[-1].reason-ceq'MEMBERSHIP_CHANGED'-and$r.events[-1].unresolvedReducerFailures-eq0-and($statuses-join',')-ceq'LAUNCH_PENDING,LAUNCH_FAILED'-and@(Events $r REDUCER_FAILURE).Count-eq0-and@(Events $r TRANSPORT_FAILURE).Count-eq0-and@($r.events|Where-Object relaunch -eq $true).Count-eq0) '8186 LAUNCH_PENDING/LAUNCH_FAILED are valid observations that keep the lane watched'
      Cadence $r 1
      Write-Output 'PASS 8186 launch-status-observed'
    }
    if('transport-vs-reducer-failure'-in$run8186){
      $transportOracle={param($r,[string]$msg)
        Check ($r.exit-ne0-and@(Events $r TRANSPORT_FAILURE).Count-eq1-and(Events $r TRANSPORT_FAILURE)[0].code-ceq'TRANSPORT_UNKNOWN'-and@(Events $r REDUCER_FAILURE).Count-eq0-and@(Events $r OBSERVATION).Count-eq1-and$r.events[-1].reason-ceq'TRANSPORT_FAILURE'-and$r.events[-1].unresolvedReducerFailures-eq0) $msg
      }
      # The first reduction removes the reducer script; the sibling's reduction must find transport absent and abort.
      $vanish=Stub 'vanishing-reducer' ('Remove-Item -LiteralPath $PSCommandPath -Force'+"`n"+(Obs LIVE_SLOW))
      $r=Batch @((Lane $A),(Lane $B)) 'AC8186-transport-vs-reducer' @('-ReducerScript',$vanish) $entry 4
      Check (-not(Test-Path -LiteralPath $vanish)) '8186 vanishing reducer did not remove itself'
      & $transportOracle $r '8186 reducer removed mid-run is a fatal transport failure, not a lane error'
      $mutant=Mutate 'skip-per-reduction-transport-check' 'Assert-Transport # TRANSPORT_GUARD_PER_REDUCTION' '$null=$null # MUTATED_TRANSPORT_GUARD'
      $vanishMutant=Stub 'vanishing-reducer-mutant' ('Remove-Item -LiteralPath $PSCommandPath -Force'+"`n"+(Obs LIVE_SLOW))
      $m=Batch @((Lane $A),(Lane $B)) 'AC8186-transport-mutant' @('-ReducerScript',$vanishMutant) $mutant 4
      Check (@(Events $m REDUCER_FAILURE).Count-ge1) '8186 transport mutant must misclassify the missing reducer as a lane error'
      Reject-Mutant 'skip-per-reduction-transport-check' {& $transportOracle $m '8186 transport oracle'}
      # Poll-time lane input loss after a valid observation stays fatal at the next poll.
      $transcriptBackup=[IO.File]::ReadAllBytes($A.transcript)
      try{
        $loss=Stub 'input-loss' ('[IO.File]::Delete($TranscriptPath)'+"`n"+(Obs LIVE_SLOW))
        $r=Batch @((Lane $A)) 'AC8186-input-loss' @('-ReducerScript',$loss) $entry 4
        Check ($r.exit-ne0-and@(Events $r TRANSPORT_FAILURE).Count-eq1-and(Events $r TRANSPORT_FAILURE)[0].code-ceq'INPUT_UNKNOWN'-and@(Events $r REDUCER_FAILURE).Count-eq0-and@(Events $r OBSERVATION).Count-eq1-and$r.events[-1].unresolvedReducerFailures-eq0) '8186 poll-time input loss stays fatal'
      }finally{[IO.File]::WriteAllBytes($A.transcript,$transcriptBackup)}
      Write-Output 'PASS 8186 transport-vs-reducer-failure reducer-removed-mid-run / poll-time-input-loss'
    }
    if('relaunch-follow-stays-fatal'-in$run8186){
      $followOracle={param($r,[string]$msg)
        Check ($r.exit-ne0-and@(Events $r TRANSPORT_FAILURE).Count-eq1-and@(Events $r REDUCER_FAILURE).Count-eq0-and@(Events $r MEMBERSHIP_CHANGED).Count-eq0-and$r.events[-1].reason-ceq'TRANSPORT_FAILURE'-and$r.events[-1].unresolvedReducerFailures-eq0) $msg
      }
      $ghost=Stub 'relaunch-ghost' '''{"schemaVersion":"watchdog-observation-result/v1","status":"RELAUNCHED","relaunch":true,"label":"synthetic-nonexistent"}'''
      $r=Batch @((Lane $A)) 'AC8186-relaunch-ghost' @('-ReducerScript',$ghost) $entry 4
      & $followOracle $r '8186 a relaunch whose replacement cannot be read is fatal'
      Check (@(Events $r OBSERVATION $A.label|Where-Object status -ceq RELAUNCHED).Count-eq1) '8186 relaunch observation recorded before the fatal follow'
      $badLabel=Stub 'relaunch-bad-label' '''{"schemaVersion":"watchdog-observation-result/v1","status":"RELAUNCHED","relaunch":true,"label":"bad label!"}'''
      $r=Batch @((Lane $A)) 'AC8186-relaunch-bad-label' @('-ReducerScript',$badLabel) $entry 4
      Failure $r '8186 an unfollowable relaunch label is fatal, never a lane error'
      $mutant=Mutate 'contain-relaunch-follow-failure' 'if($result.relaunch){Follow-Relaunch $lane $result}' 'if($result.relaunch){try{Follow-Relaunch $lane $result}catch{Note-ReducerFailure $lane $detectedAt ''RESULT_INVALID''}}'
      $m=Batch @((Lane $A)) 'AC8186-relaunch-mutant' @('-ReducerScript',$ghost) $mutant 4
      Check (@(Events $m REDUCER_FAILURE).Count-ge1-and@(Events $m TRANSPORT_FAILURE).Count-eq0) '8186 follow mutant must contain the unreadable replacement'
      Reject-Mutant 'contain-relaunch-follow-failure' {& $followOracle $m '8186 follow oracle'}
      Write-Output 'PASS 8186 relaunch-follow-stays-fatal'
    }
  }
  Check ((Get-FileHash $reducer).Hash-ceq$reducerHash) 'canonical reducer bytes changed'
  Write-Output "PASS batch tests $Only; evidence=$root"
}finally{
  foreach($worker in $workers){[IO.File]::WriteAllText($worker.release,'cooperative cleanup')}
  foreach($handle in $active){if(-not$handle.ended){$null=End-Native $handle}}
  $survivors=@(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'"|Where-Object{$_.CommandLine-and$_.CommandLine.Contains($root)})
  Check ($survivors.Count-eq0) 'owned watcher/helper/worker process survived focused test cleanup'
  Write-Output 'PASS owned-process cleanup (zero surviving helpers/workers; cooperative release only)'
}
} finally { Exit-RoutingDataTestScope $routingTestScope }
