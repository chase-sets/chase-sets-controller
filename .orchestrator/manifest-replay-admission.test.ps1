[CmdletBinding()]
param([ValidateSet('All','Pair','Admission','Results','Lifecycle','Containment')][string]$Scenario='All',
  [ValidateSet('','wrong-stage','text-only','missing','malformed','overflow')][string]$ResultCase='')
$ErrorActionPreference='Stop'
function Assert-Replay($Value,[string]$Message) { if (-not $Value) { throw "ASSERTION FAILED: $Message" } }
$script:activeCalls=[Collections.Generic.List[object]]::new()
if ($Scenario -ceq 'All') {
  $children=@(); $watch=[Diagnostics.Stopwatch]::StartNew()
  try {
    foreach ($part in @('Pair','Admission','Results','Lifecycle','Containment')) {
      $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe')); $start.UseShellExecute=$false; $start.CreateNoWindow=$true
      $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
      foreach ($arg in @('-NoProfile','-File',$PSCommandPath,'-Scenario',$part)) { $start.ArgumentList.Add($arg) }
      $child=[Diagnostics.Process]::Start($start)
      $children+=@{process=$child;part=$part;stdout=$child.StandardOutput.ReadToEndAsync();stderr=$child.StandardError.ReadToEndAsync()}
    }
    foreach ($child in $children) {
      Assert-Replay ($child.process.WaitForExit([int][Math]::Max(0,550000-$watch.ElapsedMilliseconds))) "focused fixture part $($child.part) bounded below 600s"
      Write-Output $child.stdout.GetAwaiter().GetResult()
      $errors=$child.stderr.GetAwaiter().GetResult()
      Assert-Replay ($child.process.ExitCode -eq 0) "focused fixture part $($child.part) exit=$($child.process.ExitCode) $errors"
    }
  } finally {
    foreach ($child in $children) { if (-not $child.process.HasExited) { $child.process.Kill($true); [void]$child.process.WaitForExit(3000) }; $child.process.Dispose() }
  }
  Write-Output 'PASS manifest replay admission: five isolated inert fixture parts'
  exit 0
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('manifest-replay-'+[guid]::NewGuid().ToString('N'))
$container=Join-Path $root 'container'; $runtime=Join-Path $container '.orchestrator'; $seat=Join-Path $container 'seat with spaces'
$logs=Join-Path $seat '.orchestrator/logs'; $lock=Join-Path $runtime 'verify-lock.d'
[IO.Directory]::CreateDirectory($runtime) | Out-Null; [IO.Directory]::CreateDirectory($logs) | Out-Null
foreach ($name in @('invoke-heavy-verifier.ps1','diagnostic-declarations.json','manifest-replay-bindings.schema.json','manifest-replay-receipt.schema.json','dispatch-ownership.ps1','dispatch-ledger-reader.psm1','heavy-admission-preload.cjs','heavy-slot.cjs','heavy-nested-client.cjs','heavy-admission-holder-launcher.cjs')) {
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $runtime
}
$guard=Join-Path $runtime 'invoke-heavy-verifier.ps1'
$source=[IO.File]::ReadAllText($guard)
function Invoke-FixtureGit([string[]]$Arguments) { $value=@(& git -C $seat @Arguments 2>&1); Assert-Replay ($LASTEXITCODE -eq 0) "fixture Git $Arguments $value"; return ($value -join "`n").Trim() }
function Json([string]$Path,$Value) { [IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 24),[Text.UTF8Encoding]::new($false)) }
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Pin([string]$Name) { @{path=".orchestrator/logs/$Name";sha256=(Hash (Join-Path $logs $Name))} }
function Start-Call([hashtable]$Overrides=@{},[string]$Phase='base') {
  $parameters=[ordered]@{ManifestReplay='10808-ac3-replay';ReplayPhase=$Phase;ReplayRunId=$script:run;ReplayManifestPath=$script:bindingsPath;ReplayManifestSha256=(Hash $script:bindingsPath);ReplayBudgetSeconds='540';Worktree=$seat;Lane='replay-test';Branch='codex/fixture';ClaimedHead=$head}
  if ($Phase -ceq 'repaired') { $parameters.ReplayBaseReceiptSha256=$script:baseSha }
  foreach ($entry in $Overrides.GetEnumerator()) { if ($null -eq $entry.Value) { $parameters.Remove($entry.Key) } else { $parameters[$entry.Key]=$entry.Value } }
  $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe')); $start.UseShellExecute=$false; $start.CreateNoWindow=$true
  $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
  foreach ($arg in @('-NoProfile','-File',$guard)) { $start.ArgumentList.Add($arg) }
  foreach ($entry in $parameters.GetEnumerator()) { $start.ArgumentList.Add('-'+$entry.Key); if ($entry.Value -isnot [bool]) { $start.ArgumentList.Add([string]$entry.Value) } }
  foreach ($key in @('CHASE_SETS_HEAVY_SLOT_ID','CHASE_SETS_HEAVY_SLOT_TRANSPORT','CHASE_SETS_HEAVY_ADMISSION_CONFIG','NODE_OPTIONS')) { [void]$start.Environment.Remove($key) }
  $process=[Diagnostics.Process]::Start($start); [void]$process.Handle
  $call=@{process=$process;output=$process.StandardOutput.ReadToEndAsync();errors=$process.StandardError.ReadToEndAsync()}
  $script:activeCalls.Add($call)
  return $call
}
function Complete-Call($Call) {
  try {
    if (-not $Call.process.WaitForExit(90000)) { $Call.process.Kill($true); [void]$Call.process.WaitForExit(2000); throw 'fixture foreground call exceeded 90s' }
    return @{code=$Call.process.ExitCode;stdout=$Call.output.GetAwaiter().GetResult();stderr=$Call.errors.GetAwaiter().GetResult()}
  } finally {
    $Call.process.Dispose(); [void]$script:activeCalls.Remove($Call)
  }
}
function Call([hashtable]$Overrides=@{},[string]$Phase='base') { Complete-Call (Start-Call $Overrides $Phase) }
function Refuses($Result,[string]$Name) {
  Assert-Replay ($Result.code -eq 73) "$Name exit73 actual=$($Result.code) $($Result.stderr) $($Result.stdout)"
  Assert-Replay (-not (Test-Path -LiteralPath (Join-Path $script:evidence 'base.result.json'))) "$Name no payload"
  Assert-Replay (-not (Test-Path -LiteralPath $lock)) "$Name no holder"
  Write-Output "PASS refuse $Name exit=73 payload=0 holder=0"
}
function Set-Package([string]$Behavior='normal') {
  [IO.File]::WriteAllText($guard,$source)
  $script:run=[guid]::NewGuid().ToString('N'); $script:evidence=Join-Path $seat ".orchestrator/artifacts/manifest-replay-$script:run"
  $script:bindingsPath=Join-Path $logs 'bindings.json'
  $script:bindings=[ordered]@{schema='host-heavy-manifest-replay-bindings/v1';runId=$script:run;head=$head;worktree=$seat;budgetSeconds=540;provenance=@{manifest=(Pin 'original.json');artifacts=@(1..4 | ForEach-Object {Pin "original-$_.txt"})};phases=[ordered]@{}}
  foreach ($phase in @('base','repaired')) {
    $wrapper=Join-Path $logs "$phase.wrapper.ps1"; $specPath=Join-Path $logs "$phase.spec.json"; $capture=Join-Path $logs "$phase.capture.mjs"
    [IO.File]::WriteAllText($wrapper,@'
param([string]$Spec)
$ErrorActionPreference='Stop'
$specification=Get-Content -LiteralPath $Spec -Raw | ConvertFrom-Json
& node @($specification.invocation.arguments)
exit $LASTEXITCODE
'@)
    $captureText=@'
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawn,spawnSync} from 'node:child_process';
const spec=JSON.parse(fs.readFileSync(fileURLToPath(import.meta.url).replace('.capture.mjs','.spec.json'),'utf8'));
const behavior='BEHAVIOR';
if(process.argv.slice(2).join('|')!=='step3') throw Error('bad argv');
const git=spawnSync('git',['-C',spec.worktree,'rev-parse','HEAD'],{encoding:'utf8'});
if(git.status!==0 || git.stdout.trim()!==spec.head) throw Error('Git unavailable');
const env=process.env;
if(!env.NODE_OPTIONS.includes('heavy-admission-preload.cjs') || !env.CHASE_SETS_HEAVY_SLOT_ID || env.CHASE_SETS_HEAVY_SLOT_TRANSPORT || env.CHASE_SETS_HEAVY_ADMITTED || JSON.parse(Buffer.from(env.CHASE_SETS_HEAVY_ADMISSION_CONFIG,'base64')).diagnostic) throw Error('bad containment admission environment');
console.log('ordinary Git/capture allowed; token/preload/config present; descriptor/Diagnostic absent');
if(behavior==='heavy-child') {
  const child=spawnSync(process.execPath,[path.join(spec.worktree,'scripts','run-workspaces.mjs'),'test'],{encoding:'utf8'});
  if(child.status!==73 || fs.existsSync(path.join(spec.worktree,'forbidden-marker'))) throw Error('heavy child admitted: '+child.status+' '+child.stderr);
  console.log('classified child73 no descriptor: '+child.stderr);
}
if(behavior==='overflow') { process.stdout.write('x'.repeat(9*1024*1024)); setInterval(()=>{},100); }
if(behavior==='hang' || behavior==='spawn-exit') {
  const child=spawn(process.env.ComSpec,['/c','ping','127.0.0.1','-n','100'],{stdio:'ignore'});
  fs.writeFileSync(path.join(path.dirname(spec.resultPath),'survivor.pid'),String(child.pid));
  fs.writeFileSync(path.join(path.dirname(spec.resultPath),'barrier'),String(process.pid));
  if(behavior==='spawn-exit') child.once('spawn',()=>setTimeout(()=>process.exit(0),1000));
  setInterval(()=>{},100);
} else if(behavior==='child73') { process.exit(73); }
else if(behavior==='missing') { console.log('PASS_PRECOMMIT_ONLY'); process.exit(0); }
else if(behavior==='malformed') { fs.writeFileSync(spec.resultPath,'{"truncated":'); process.exit(1); }
else if(behavior!=='overflow') {
  let red=spec.phase==='base';
  let checks=red?[{stage:behavior==='wrong-stage'?'wrong':'deadline',status:'failed',code:'INERT_RED',message:'inert deadline specimen'}]:[{stage:'identity',status:'passed',code:'OK',message:''},{stage:'content',status:'passed',code:'OK',message:''}];
  if(behavior==='text-only') checks=[{stage:'deadline',status:'passed',code:'INERT_RED',message:'inert deadline specimen'}];
  if(behavior==='missing-identity' && !red) checks=checks.filter(x=>x.stage!=='identity');
  const result={schema:'host-heavy-replay-phase-result/v1',runId:spec.runId,phase:spec.phase,head:spec.head,nativeExit:red?1:0,status:red?'failed':'passed',checks};
  fs.writeFileSync(spec.resultPath,JSON.stringify(result),{flag:'wx'});
  process.exit(red?1:0);
}
'@
    [IO.File]::WriteAllText($capture,$captureText.Replace('BEHAVIOR',$Behavior))
    $invocation=@{executable='node';arguments=@($capture,'step3')}
    Json $specPath ([ordered]@{schema='host-heavy-replay-spec/v1';runId=$script:run;phase=$phase;head=$head;worktree=$seat;budgetSeconds=540;laneMode=$false;invocation=$invocation;resultPath=(Join-Path $script:evidence "$phase.result.json");stdoutPath=(Join-Path $script:evidence "$phase.stdout.log");stderrPath=(Join-Path $script:evidence "$phase.stderr.log")})
    $script:bindings.phases[$phase]=[ordered]@{wrapper=(Pin "$phase.wrapper.ps1");spec=(Pin "$phase.spec.json");capture=(Pin "$phase.capture.mjs");preflight=(Pin 'preflight.mjs');dependencies=@((Pin 'sibling.mjs'));command=@{executable='pwsh';arguments=@('-NoProfile','-File',$wrapper,'-Spec',$specPath)};invocation=$invocation;resultPath=(Join-Path $script:evidence "$phase.result.json");expected=@{nativeExit=$(if($phase -ceq 'base'){1}else{0});firstFailure=$(if($phase -ceq 'base'){[ordered]@{stage='deadline';code='INERT_RED';message='inert deadline specimen'}}else{$null})}}
  }
  Save-Package
}
function Save-Package {
  Json $script:bindingsPath $script:bindings
  Json (Join-Path $runtime 'diagnostic-declarations.json') ([ordered]@{schema='host-heavy-diagnostic-declarations/v1';diagnostics=@{};manifestReplays=@{'10808-ac3-replay'=@{enabled=$true;kind='manifest-replay';path='.orchestrator/logs/bindings.json';sha256=(Hash $script:bindingsPath);maxBudgetSeconds=540}}})
}
function Receipt([string]$Phase='base') {
  $path=Join-Path $script:evidence "$Phase.receipt.json"
  Assert-Replay (Test-Path -LiteralPath $path) "receipt exists $Phase"
  $raw=[IO.File]::ReadAllText($path)
  Assert-Replay (Test-Json -Json $raw -SchemaFile (Join-Path $PSScriptRoot 'manifest-replay-receipt.schema.json')) 'published receipt validates'
  return $raw|ConvertFrom-Json -AsHashtable -DateKind String
}
function Substitute([string]$Old,[string]$New) {
  $text=[IO.File]::ReadAllText($guard)
  Assert-Replay (([regex]::Matches($text,[regex]::Escape($Old))).Count -eq 1) "fixture substitution unique $Old"
  [IO.File]::WriteAllText($guard,$text.Replace($Old,$New))
}
function Wait-File([string]$Path,$Call) {
  $watch=[Diagnostics.Stopwatch]::StartNew()
  while (-not (Test-Path -LiteralPath $Path) -and -not $Call.process.HasExited -and $watch.ElapsedMilliseconds -lt 80000) { Start-Sleep -Milliseconds 20 }
  if (-not (Test-Path -LiteralPath $Path)) {
    if (-not $Call.process.HasExited) { $Call.process.Kill($true); [void]$Call.process.WaitForExit(3000) }
    $stdout=$Call.output.GetAwaiter().GetResult(); $stderr=$Call.errors.GetAwaiter().GetResult()
    throw "ASSERTION FAILED: barrier exists $Path stdout=$stdout stderr=$stderr"
  }
}
try {
  [IO.File]::WriteAllText((Join-Path $seat '.gitignore'),".orchestrator/logs/`n.orchestrator/artifacts/`n")
  [void](Invoke-FixtureGit @('init','-q','-b','codex/fixture')); [void](Invoke-FixtureGit @('config','user.email','replay@example.invalid')); [void](Invoke-FixtureGit @('config','user.name','Inert replay fixture'))
  [IO.Directory]::CreateDirectory((Join-Path $seat 'scripts')) | Out-Null
  [IO.File]::WriteAllText((Join-Path $seat 'scripts/run-workspaces.mjs'),"import fs from 'node:fs';fs.writeFileSync('forbidden-marker','forbidden');")
  [void](Invoke-FixtureGit @('add','.')); [void](Invoke-FixtureGit @('commit','-qm','inert fixture')); $head=Invoke-FixtureGit @('rev-parse','HEAD')
  Json (Join-Path $logs 'original.json') @{provenance='inert original only'}
  foreach ($n in 1..4) { [IO.File]::WriteAllText((Join-Path $logs "original-$n.txt"),"inert provenance $n") }
  [IO.File]::WriteAllText((Join-Path $logs 'preflight.mjs'),'// inert preflight')
  [IO.File]::WriteAllText((Join-Path $logs 'sibling.mjs'),'// inert pinned sibling')
  if ($Scenario -ceq 'Pair') {
  Set-Package
  $base=Call
  Assert-Replay ($base.code -eq 0) "expected red executes $($base.stderr) $($base.stdout) child-stderr=$(if(Test-Path (Join-Path $script:evidence 'base.stderr.log')){Get-Content (Join-Path $script:evidence 'base.stderr.log') -Raw})"
  $baseReceipt=Receipt; Assert-Replay ($baseReceipt.outcome -ceq 'expected-failure' -and $baseReceipt.nativeExit -eq 1 -and $baseReceipt.attemptConsumed) 'expected red observed, not fabricated'
  $script:baseSha=Hash (Join-Path $script:evidence 'base.receipt.json')
  Assert-Replay ($base.stdout.Contains($script:baseSha)) 'base digest published after commit'
  $pair=Call @{} 'repaired'; Assert-Replay ($pair.code -eq 0) "pair executes $($pair.stderr)"
  $receipt=Receipt 'repaired'; Assert-Replay ($receipt.pairComplete -and $receipt.nativeExit -eq 0 -and $receipt.results.base.nativeExit -eq 1 -and $receipt.results.repaired.nativeExit -eq 0) 'same-head observed pair'
  $duplicate=Call @{} 'repaired'; Assert-Replay ($duplicate.code -eq 73) 'no phase twice'
  $schema=Get-Content (Join-Path $PSScriptRoot 'manifest-replay-receipt.schema.json') -Raw
  $bindingsSchema=Get-Content (Join-Path $PSScriptRoot 'manifest-replay-bindings.schema.json') -Raw
  Assert-Replay (Test-Json -Json (Get-Content $script:bindingsPath -Raw) -Schema $bindingsSchema) 'published bindings schema accepts valid inert package'
  $badBindings=$script:bindings|ConvertTo-Json -Depth 24|ConvertFrom-Json -AsHashtable; $badBindings.budgetSeconds=539
  Assert-Replay (-not (Test-Json -Json ($badBindings|ConvertTo-Json -Depth 24) -Schema $bindingsSchema -ErrorAction SilentlyContinue)) 'published bindings schema rejects contradictory budget'
  $definitions=($bindingsSchema|ConvertFrom-Json -AsHashtable).definitions
  $phaseSchema=@{'$ref'='#/definitions/phaseResult';definitions=$definitions}|ConvertTo-Json -Depth 24
  Assert-Replay (Test-Json -Json ($receipt.result|ConvertTo-Json -Depth 16) -Schema $phaseSchema) 'phase result validates against published definition'
  $badResult=$receipt.result|ConvertTo-Json -Depth 16|ConvertFrom-Json -AsHashtable; $badResult.nativeExit=1
  Assert-Replay (-not (Test-Json -Json ($badResult|ConvertTo-Json -Depth 16) -Schema $phaseSchema -ErrorAction SilentlyContinue)) 'published result schema rejects passed/nonzero contradiction'
  foreach ($mutation in @(@{exit=73},@{recorderComplete=$false},@{attemptConsumed=$false},@{released=$false},@{nativeExit=73},@{pairComplete=$false})) {
    $invalid=$receipt.Clone(); foreach($entry in $mutation.GetEnumerator()){$invalid[$entry.Key]=$entry.Value}
    Assert-Replay (-not (Test-Json -Json ($invalid|ConvertTo-Json -Depth 24) -Schema $schema -ErrorAction SilentlyContinue)) 'contradictory receipt rejected by published schema'
  }
  Write-Output 'PASS exact-head pair: base red/repaired identity+content, digest commit, duplicate refusal, conditional receipt schema'
  }
  if ($Scenario -ceq 'Admission') {
  foreach ($case in @(@{ReplayRunId='bad'},@{ReplayPhase='other'},@{ReplayManifestSha256='bad'},@{ReplayBudgetSeconds='NaN'},@{Lane='bad lane'},@{ClaimedHead='bad'},@{ReplayBaseReceiptSha256=('a'*64)},@{Gate='verify:static'},@{TestCancelAfterAcquisition=$true})) {
    Set-Package; Refuses (Call $case) ('CLI '+($case.Keys -join ','))
  }
  foreach ($role in @('wrapper','spec','capture','preflight')) {
    Set-Package; $script:bindings.phases.repaired[$role].sha256='a'*64; Save-Package; Refuses (Call) "both phases pinned $role"
  }
  Set-Package; $script:bindings.phases.repaired.dependencies[0].sha256='a'*64; Save-Package; Refuses (Call) 'dependency pin'
  Set-Package; $script:bindings.provenance.artifacts[2].sha256='a'*64; Save-Package; Refuses (Call) 'provenance pin'
  Set-Package; $script:bindings.phases.base.command.arguments[0]='-Command'; Save-Package; Refuses (Call) 'shell grammar'
  Set-Package; $script:bindings.phases.base.wrapper.path='.orchestrator/logs/../escape.ps1'; Save-Package; Refuses (Call) 'traversal'
  Set-Package; $script:bindings.extra=$true; Save-Package; Refuses (Call) 'unknown JSON key'
  Set-Package; $raw=[IO.File]::ReadAllText($script:bindingsPath); [IO.File]::WriteAllText($script:bindingsPath,$raw.Replace('"budgetSeconds": 540','"budgetSeconds": 540, "budgetSeconds": 540'))
  $declaration=Get-Content (Join-Path $runtime 'diagnostic-declarations.json') -Raw|ConvertFrom-Json -AsHashtable; $declaration.manifestReplays.'10808-ac3-replay'.sha256=Hash $script:bindingsPath; Json (Join-Path $runtime 'diagnostic-declarations.json') $declaration
  Refuses (Call) 'duplicate JSON key'
  Set-Package; $declaration=Get-Content (Join-Path $runtime 'diagnostic-declarations.json') -Raw|ConvertFrom-Json -AsHashtable; $declaration.manifestReplays.'10808-ac3-replay'.kind='standalone-node'; Json (Join-Path $runtime 'diagnostic-declarations.json') $declaration; Refuses (Call) 'kind confusion'
  Set-Package; [IO.File]::WriteAllText((Join-Path $seat 'dirty'),'dirty'); Refuses (Call) 'untracked Git'; [IO.File]::Delete((Join-Path $seat 'dirty'))
  }
  if ($Scenario -ceq 'Results') {
  foreach ($behavior in @('wrong-stage','text-only','missing','malformed','overflow') | Where-Object { -not $ResultCase -or $_ -ceq $ResultCase }) {
    Set-Package $behavior; $result=Call
    Assert-Replay ($result.code -eq 1) "$behavior incomplete exit1 actual=$($result.code) $($result.stderr)"
    $receipt=Receipt; Assert-Replay ($receipt.outcome -ceq 'incomplete' -and -not $receipt.pairComplete -and $receipt.cleanupComplete -and $receipt.released) "$behavior never qualifies: $($receipt|ConvertTo-Json -Depth 5 -Compress)"
    Assert-Replay (-not (Test-Path -LiteralPath $lock)) "$behavior no holder"
    Write-Output "PASS result $behavior incomplete and cleanup proven"
  }
  if (-not $ResultCase) {
  Set-Package 'missing-identity'; $result=Call; Assert-Replay ($result.code -eq 0) 'missing identity repaired test has valid base red'
  $script:baseSha=Hash (Join-Path $script:evidence 'base.receipt.json'); $result=Call @{} 'repaired'
  Assert-Replay ($result.code -eq 1 -and -not (Receipt 'repaired').pairComplete) 'zero alone without identity/content does not qualify'
  Set-Package 'child73'; $result=Call; Assert-Replay ($result.code -eq 73) "child73 NOT_EXECUTED $($result.stderr)"
  $receipt=Receipt; Assert-Replay ($receipt.nativeExit -eq 73 -and -not $receipt.attemptConsumed -and $receipt.executionStarted -and -not $receipt.pairComplete) 'child73 unconsumed but physically started'
  Assert-Replay ((Call).code -eq 73) 'started child73 cannot relaunch'
  Set-Package 'heavy-child'; $result=Call; Assert-Replay ($result.code -eq 0) "unclassified capture and denied classified child $($result.stderr)"
  Assert-Replay ((Get-Content (Join-Path $script:evidence 'base.stdout.log') -Raw).Contains('classified child73')) 'classified no-descriptor refusal actually observed'
  }
  }
  if ($Scenario -ceq 'Lifecycle') {
  Set-Package; $one=Start-Call; $two=Start-Call
  $first=Complete-Call $one; $second=Complete-Call $two
  Assert-Replay ((@($first.code,$second.code)|Sort-Object) -join ',' -ceq '0,73') 'racing calls execute once and refuse one'
  Assert-Replay ((Receipt).outcome -ceq 'expected-failure') 'racing call cannot overwrite committed result'
  Set-Package; [IO.Directory]::CreateDirectory($script:evidence)|Out-Null; Json (Join-Path $script:evidence 'base.claim.json') @{foreign=$true}; Refuses (Call) 'interrupted claim no steal'
  Set-Package; $base=Call; Assert-Replay ($base.code -eq 0) "base tamper setup $($base.stderr)"; $script:baseSha=Hash (Join-Path $script:evidence 'base.receipt.json')
  $path=Join-Path $script:evidence 'base.receipt.json'; $tamper=Get-Content $path -Raw|ConvertFrom-Json -AsHashtable; $tamper.reason='non-identity tamper'; Json $path $tamper
  Assert-Replay ((Call @{} 'repaired').code -eq 73) 'base non-identity digest tamper refuses'
  foreach ($gap in @('release','receipt','commit')) {
    Set-Package
    $anchor=switch($gap){release{'    [void](Get-ReplayRemaining)'}receipt{'    [IO.File]::Move($pending,$receiptPath)'}commit{'      [Console]::Out.WriteLine("manifest-replay receipt=$receiptPath sha256=$receiptHash outcome=$outcome exit=$exit")'}}
    if($gap -ceq 'release') { $anchor='    $pending=Join-Path $script:replayEvidence "$ReplayPhase.receipt.pending.json"' }
    Substitute $anchor ('    throw "inert interrupted '+$gap+'"' + "`n" + $anchor)
    $result=Call; Assert-Replay ($result.code -eq 1) "$gap interruption incomplete"
    Assert-Replay ((Call).code -eq 73) "$gap interruption never relaunches"
  }
  }
  if ($Scenario -ceq 'Containment') {
  Set-Package; Substitute '(IntPtr)0x2000D' '(IntPtr)0x7ffffffe'
  Refuses (Call) 'atomic Job assignment unsupported'
  Assert-Replay (-not (Test-Path -LiteralPath (Join-Path $script:evidence 'base.claim.json'))) 'proven no-payload refusal rolls back only owned claim'
  Set-Package
  Substitute '    $job.Resume()' ('    [IO.File]::WriteAllText((Join-Path $script:replayEvidence "pre-resume.barrier"),"suspended")' + "`n" + '    Start-Sleep -Seconds 15' + "`n" + '    $job.Resume()')
  $suspended=Start-Call; Wait-File (Join-Path $script:evidence 'pre-resume.barrier') $suspended
  $published=Get-Content (Join-Path $script:evidence 'base.start.json') -Raw | ConvertFrom-Json -DateKind String
  $exact=Get-Process -Id $published.childPid; [void]$exact.Handle
  Assert-Replay ($exact.StartTime.ToUniversalTime().Ticks -eq [DateTimeOffset]::Parse($published.childProcessStartUtc).UtcTicks) "pre-resume exact published identity actual=$($exact.StartTime.ToUniversalTime().ToString('o')) published=$($published.childProcessStartUtc)"
  $suspended.process.Kill(); [void]$suspended.process.WaitForExit(3000)
  Assert-Replay ($exact.WaitForExit(3000) -and -not (Test-Path -LiteralPath (Join-Path $script:evidence 'base.result.json'))) 'host loss before resume kills suspended payload without marker'
  $exact.Dispose(); $suspended.process.Dispose()
  # The dead owner is reclaimed by the real admission path of the next fixture.
  foreach ($behavior in @('hang','spawn-exit')) {
    Set-Package $behavior; Substitute '$resumeMs+540000' '$resumeMs+5000'
    $result=Call; Assert-Replay ($result.code -eq 124) "$behavior short deadline exits124 $($result.stderr)"
    $receipt=Receipt; Assert-Replay ($receipt.cleanupComplete -and $receipt.survivorsAfterCleanup -eq 0 -and $receipt.outcome -ceq 'timed-out') "$behavior exact Job cleanup"
    $survivorPath=Join-Path $script:evidence 'survivor.pid'; Assert-Replay (Test-Path -LiteralPath $survivorPath) "$behavior survivor pid published stdout=$($result.stdout) stderr=$($result.stderr)"; $survivor=[int](Get-Content $survivorPath); Assert-Replay (-not (Get-Process -Id $survivor -ErrorAction SilentlyContinue)) "$behavior no surviving descendant"
    Write-Output "PASS atomic Job $behavior timeout124 descendants=0"
  }
  Set-Package 'hang'; $runCall=Start-Call; Wait-File (Join-Path $script:evidence 'barrier') $runCall
  $survivor=[int](Get-Content (Join-Path $script:evidence 'survivor.pid')); $survivorProcess=Get-Process -Id $survivor; [void]$survivorProcess.Handle
  $runCall.process.Kill(); [void]$runCall.process.WaitForExit(3000)
  Assert-Replay ($survivorProcess.WaitForExit(3000)) 'host loss kills exact Job descendants'
  Assert-Replay (Test-Path -LiteralPath $lock) 'host loss retains owner for exact reclamation'
  $survivorProcess.Dispose(); $runCall.process.Dispose()
  Write-Output 'PASS host loss kills Job and retains incomplete claim/owner'
  }
  Write-Output 'PASS manifest replay admission: inert CLI/package/result/pair/claim/Job controls'
} finally {
  $absolute=[IO.Path]::GetFullPath($root); $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
  if (-not $absolute.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)) { throw 'fixture cleanup escaped temp' }
  foreach ($call in @($script:activeCalls)) {
    try { if (-not $call.process.HasExited) { $call.process.Kill($true); [void]$call.process.WaitForExit(3000) } } catch {}
    try { $call.process.Dispose() } catch {}
  }
  $script:activeCalls.Clear(); [GC]::Collect(); [GC]::WaitForPendingFinalizers()
  if (Test-Path -LiteralPath $root) {
    $removed=$false
    for ($attempt=0; $attempt -lt 50 -and -not $removed; $attempt++) {
      try { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop; $removed=$true } catch { Start-Sleep -Milliseconds 100 }
    }
    if (-not $removed -and (Test-Path -LiteralPath $root)) { throw 'fixture cleanup could not remove owned root after closing active calls' }
  }
}
