param([switch]$Baseline, [switch]$NativeDbOnly)
$ErrorActionPreference = 'Stop'
if ($NativeDbOnly) {
  $helper = (Join-Path $PSScriptRoot 'native-db-admission.py').Replace('\','/')
  if ($helper -notmatch '^([A-Za-z]):/(.*)$') { throw 'native fixture requires an absolute drive path' }
  $linuxHelper = '/mnt/' + $Matches[1].ToLowerInvariant() + '/' + $Matches[2]
  $fixture = @'
import hashlib, importlib.util, json, os, pathlib, select, shutil, subprocess, sys, time, uuid
source = pathlib.Path(sys.argv[1])
parent = pathlib.Path('/srv/chase-sets-pg-probe')
fixture = parent / ('native-db-component-' + uuid.uuid4().hex)
fixture.mkdir(mode=0o755)
helper = fixture / 'admission.py'
runner = fixture / 'inert.py'
inputs = fixture / 'inputs'
inputs.mkdir(mode=0o755)
staged = inputs / 'synthetic'
(staged / 'tools').mkdir(parents=True, mode=0o755)
shutil.copy2(pathlib.Path(sys.executable).resolve(), staged / 'tools/node')
text = source.read_text().replace("Path('/opt/chase-sets-native-db/admission.py')", repr(helper).replace('PosixPath', 'Path')).replace("Path('/opt/chase-sets-native-db/reconciliation-pg16.mjs')", repr(runner).replace('PosixPath', 'Path')).replace("Path('/srv/chase-sets-native-db-input')", repr(inputs).replace('PosixPath', 'Path'))
helper.write_text(text)
spec = importlib.util.spec_from_file_location('synthetic_admission', helper)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
processes = []
roots = []
tuples = {}
def command(mode, root):
    return ['/usr/bin/env','-i','PATH=/usr/bin:/bin',f'HOME={root}','LANG=C','/usr/bin/python3',str(helper),mode,str(root)]
def line(process):
    assert select.select([process.stdout], [], [], 30)[0], 'fixture reply deadline'
    raw = process.stdout.readline()
    assert raw, process.stderr.read().decode()
    return json.loads(raw)
def start():
    root = parent / ('native-db-' + uuid.uuid4().hex)
    roots.append(root)
    process = subprocess.Popen(command('launch', root), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    processes.append(process)
    raw = json.dumps({'profile':'reconciliation-pg16/v1','stagedInputDirectory':str(staged)}, separators=(',',':'))
    envelope = {'request':raw,'digest':hashlib.sha256(raw.encode()).hexdigest()}
    process.stdin.write((json.dumps(envelope)+'\n').encode()); process.stdin.flush()
    publication = line(process)
    module.validate_tuple(publication['linux'])
    tuples[root] = publication['linux']
    return root, process, publication
def ack(process, publication):
    process.stdin.write((json.dumps(publication)+'\n').encode()); process.stdin.flush()
    process.stdin.close()
def reconcile(root, expected, success=True):
    result = subprocess.run(command('reconcile', root), input=(json.dumps({'linux':expected})+'\n').encode(), capture_output=True, timeout=40)
    if success:
        assert result.returncode == 0, result.stderr.decode()
        proof = json.loads(result.stdout)
        assert proof == {'linux':expected,'root':str(root),'initAbsent':True,'rootAbsent':True}, proof
    else:
        assert result.returncode != 0, 'wrong tuple must refuse'
    return result
try:
    root, process, publication = start()
    assert not (root / 'result.json').exists(), 'no payload before tuple acknowledgement'
    ack(process, publication)
    result = line(process)
    assert result['status'] == 'refused' and result['exit'] is None, result
    assert process.wait(timeout=30) == 0
    reconcile(root, publication['linux'])
    print('PASS copied native missing-runner refusal and exact cleanup', flush=True)
    root, process, publication = start()
    race_source = '''import importlib.util,os,pathlib,signal,sys,time
spec=importlib.util.spec_from_file_location('race_admission',sys.argv[1])
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
original=os.pidfd_open
def raced_open(pid):
    if sys.argv[3]=='absent':
        descriptor=original(pid)
        signal.pidfd_send_signal(descriptor,signal.SIGKILL);os.close(descriptor)
        deadline=time.monotonic()+30
        while pathlib.Path('/proc',str(pid)).exists() and time.monotonic()<deadline: time.sleep(.01)
        assert not pathlib.Path('/proc',str(pid)).exists()
    raise ProcessLookupError('synthetic pidfd exit race')
m.os.pidfd_open=raced_open
m.reconcile(m.execution_root(sys.argv[2]))
'''
    for state in ('present','absent'):
        raced = subprocess.run(['/usr/bin/python3','-c',race_source,str(helper),str(root),state], input=(json.dumps(publication)+'\n').encode(), capture_output=True, timeout=40)
        assert (raced.returncode == 0) == (state == 'absent'), raced.stderr.decode()
        if state == 'present': assert module.identity(publication['linux']['outerPid']) == publication['linux'] and root.exists()
        else: assert not root.exists() and json.loads(raced.stdout)['initAbsent']
    process.stdin.close(); process.wait(timeout=30)
    print('PASS pidfd disappearance race: present identity retains owner, actual absence permits exact cleanup', flush=True)
    runner.write_text('import time\ntime.sleep(300)\n')
    pathlib.Path(str(runner)+'.sha256').write_text(hashlib.sha256(runner.read_bytes()).hexdigest())
    esrch_source = '''import importlib.util,os,pathlib,signal,sys,time
spec=importlib.util.spec_from_file_location('esrch_admission',sys.argv[1])
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
arm=sys.argv[3];pid=int(sys.argv[4]);reaper=int(sys.argv[5]);proc=pathlib.Path('/proc',str(pid))
original_send=signal.pidfd_send_signal
original_identity=m.identity
calls=[]
def bound_send(descriptor,signum,*rest):
    assert proc.exists(),'bound injection requires a present init'
    if arm=='bound-kill': original_send(descriptor,signum,*rest)
    raise ProcessLookupError('synthetic ESRCH after pidfd binding')
def counted_identity(target):
    calls.append(target)
    if len(calls)==1: return original_identity(target)
    assert target==pid
    if arm=='wait-absent':
        assert proc.exists(),'held reaper must leave the bound init visible until the injected re-read'
        os.kill(reaper,signal.SIGCONT)
        deadline=time.monotonic()+30
        while proc.exists() and time.monotonic()<deadline: time.sleep(.01)
        assert not proc.exists(),'bound init death must complete before the injected re-read'
    else:
        assert proc.exists(),'retained init must still resolve at the injected re-read'
    print('INJECTED bounded-wait re-read',file=sys.stderr,flush=True)
    raise ProcessLookupError('synthetic ESRCH inside bounded wait')
if arm in ('bound-kill','bound-nokill','wait-present'): m.signal.pidfd_send_signal=bound_send
if arm in ('wait-absent','wait-present'): m.identity=counted_identity
m.reconcile(m.execution_root(sys.argv[2]))
'''
    def reaper_of(expected):
        outer = pathlib.Path('/proc', str(expected['outerPid']))
        ppid = int(next(x for x in (outer/'status').read_text().splitlines() if x.startswith('PPid:')).split()[1])
        assert pathlib.Path('/proc', str(ppid), 'comm').read_text().strip() == 'unshare', 'init parent must be the fixed unshare'
        return ppid
    def esrch(arm, root, expected, timeout=40):
        return subprocess.run(['/usr/bin/python3','-c',esrch_source,str(helper),str(root),arm,str(expected['outerPid']),str(reaper_of(expected))], input=(json.dumps({'linux':expected})+'\n').encode(), capture_output=True, timeout=timeout)
    def retained(run, root, expected, diagnostic):
        assert run.returncode != 0 and diagnostic in run.stderr, run.stderr.decode()
        assert module.identity(expected['outerPid']) == expected and root.exists(), 'retained owner requires the live matching init and its exact root'
    def released(run, root, expected):
        assert run.returncode == 0, run.stderr.decode()
        assert json.loads(run.stdout) == {'linux':expected,'root':str(root),'initAbsent':True,'rootAbsent':True}, run.stdout
        assert not root.exists() and not pathlib.Path('/proc',str(expected['outerPid'])).exists()
    root, process, publication = start()
    expected = publication['linux']
    ack(process, publication)
    retained(esrch('bound-nokill', root, expected, 60), root, expected, b'exact init absence unknown')
    retained(esrch('wait-present', root, expected), root, expected, b'synthetic ESRCH inside bounded wait')
    released(esrch('bound-kill', root, expected), root, expected)
    process.wait(timeout=30)
    print('PASS bound ESRCH at pidfd_send_signal: undelivered kill expires into a retained owner, injected bounded-wait re-read with the init present retains, delivered kill releases exactly that root', flush=True)
    root, process, publication = start()
    expected = publication['linux']
    ack(process, publication)
    reaper = reaper_of(expected)
    # Hold the reaper so the bound init's death is still visible at the wait
    # entry; the intercepted re-read resumes it before polling to absence.
    os.kill(reaper, module.signal.SIGSTOP)
    try:
        raced = esrch('wait-absent', root, expected)
    finally:
        if pathlib.Path('/proc', str(reaper), 'comm').exists() and pathlib.Path('/proc', str(reaper), 'comm').read_text().strip() == 'unshare':
            os.kill(reaper, module.signal.SIGCONT)
    assert b'INJECTED bounded-wait re-read' in raced.stderr, raced.stderr.decode()
    released(raced, root, expected)
    process.wait(timeout=30)
    print('PASS bound ESRCH at the bounded-wait identity re-read after complete /proc absence releases exactly that root', flush=True)
    runner.write_text('''import json, os, pathlib, time
root = pathlib.Path(os.environ['HOME'])
status = pathlib.Path('/proc/self/status').read_text()
proof = {'uid':os.getuid(),'gid':os.getgid(),'groups':os.getgroups(),'status':status,'env':dict(os.environ),'proc':os.readlink('/proc/self/ns/pid'),'mount':os.readlink('/proc/self/ns/mnt')}
(root/'proof.json').write_text(json.dumps(proof))
if os.fork() == 0:
    os.setsid()
    if os.fork() == 0:
        (root/'grandchild').write_text(str(os.getpid()))
        time.sleep(20)
        (root/'escaped').write_text('BAD')
    os._exit(0)
time.sleep(10)
''')
    pathlib.Path(str(runner)+'.sha256').write_text(hashlib.sha256(runner.read_bytes()).hexdigest())
    root, process, publication = start()
    process.stdin.close()
    assert process.wait(timeout=30) != 0, 'midlaunch parent EOF must refuse'
    assert not (root/'scratch').exists(), 'midlaunch parent loss must not start payload'
    reconcile(root, publication['linux'])
    print('PASS midlaunch parent-channel loss: tuple acknowledgement absent, no payload, independent exact cleanup', flush=True)
    root, process, publication = start()
    expected = publication['linux']
    assert not (root / 'scratch').exists(), 'tuple before unprivileged payload'
    wrong_start = dict(expected, startTicks=str(int(expected['startTicks'])+1))
    reconcile(root, wrong_start, False)
    assert module.identity(expected['outerPid']) == expected
    wrong_boot = dict(expected, bootId='00000000-0000-0000-0000-000000000000')
    reconcile(root, wrong_boot, False)
    assert module.identity(expected['outerPid']) == expected
    ack(process, publication)
    deadline = time.monotonic()+30
    while not (root/'scratch/proof.json').exists() and time.monotonic()<deadline:
        time.sleep(.05)
    assert (root/'scratch/proof.json').exists(), (root/'result.json').read_text() if (root/'result.json').exists() else 'payload missing'
    proof = json.loads((root/'scratch/proof.json').read_text())
    assert proof['uid'] == proof['gid'] == 65534 and proof['groups'] == [], proof
    assert 'NoNewPrivs:\t1' in proof['status']
    assert set(proof['env']) <= {'PATH','HOME','LANG','TMPDIR','LC_CTYPE'}, proof['env']
    assert proof['mount'] != os.readlink('/proc/self/ns/mnt')
    assert proof['proc'] != os.readlink('/proc/self/ns/pid')
    deadline = time.monotonic()+30
    while not (root/'scratch/grandchild').exists() and time.monotonic()<deadline:
        time.sleep(.025)
    assert (root/'scratch/grandchild').exists(), 'real double-fork/setsid grandchild missing'
    inner = int((root/'scratch/grandchild').read_text())
    members = []
    deadline = time.monotonic()+30
    while not members and time.monotonic()<deadline:
        for outer in pathlib.Path(f"/proc/{expected['outerPid']}/task/{expected['outerPid']}/children").read_text().split():
            observed = module.identity(int(outer))
            if observed['nspid'] == [int(outer), inner]: members.append(observed)
        if not members: time.sleep(.025)
    assert len(members)==1, 'exact reparented deepest grandchild identity'
    process.kill(); process.wait(timeout=30)
    assert module.identity(expected['outerPid']) == expected, 'helper death must not imply Linux init death'
    reconcile(root, expected)
    process.wait(timeout=30)
    assert not pathlib.Path('/proc',str(expected['outerPid'])).exists()
    assert not root.exists()
    assert all(not pathlib.Path('/proc', str(member['outerPid'])).exists() for member in members), 'deepest namespace descendants must die'
    print('PASS copied native tuple-before-payload, uid/gid/groups/NoNewPrivs/private namespaces, wrong-start/wrong-boot, helper-loss survivors, exact pidfd reconciliation and double-fork/setsid death', flush=True)
    gate = """    wait_input(sys.stdin.buffer)
    acknowledgement = read_message(sys.stdin.buffer, 8192)
    closed(acknowledgement, ('published',))
    if acknowledgement['published'] is not True:
        raise ValueError('tuple not published')
"""
    assert text.count(gate)==1, 'tuple-gate mutation must have one exact site'
    helper.write_text(text.replace(gate, '    # Synthetic tuple-publication bypass.\n'))
    root, process, publication = start()
    deadline=time.monotonic()+30
    while not (root/'scratch/proof.json').exists() and time.monotonic()<deadline:
        time.sleep(.025)
    assert (root/'scratch/proof.json').exists(), 'tuple bypass must violate the pre-ack no-payload assertion'
    process.kill(); process.wait(timeout=30)
    reconcile(root, publication['linux'])
    helper.write_text(text)
    print('PASS tuple-gate bypass discrimination: same request, runner, tools and environment; only init acknowledgement gate removed; inert payload entered before acknowledgement', flush=True)
finally:
    for root, expected in tuples.items():
        if root.exists() or pathlib.Path('/proc',str(expected['outerPid'])).exists():
            reconcile(root, expected)
    for process in processes:
        if process.poll() is None:
            process.wait(timeout=30)
    assert all(not root.exists() for root in roots), 'owned execution roots remain'
    assert fixture.resolve().parent == parent and fixture.name.startswith('native-db-component-')
    shutil.rmtree(fixture)
    print('PASS copied native fixture cleanup: all owned processes exited; exact fixture root absent', flush=True)
'@
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = 'C:\Windows\System32\wsl.exe'; $start.UseShellExecute = $false; $start.CreateNoWindow = $true
  $start.RedirectStandardInput = $true; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
  $start.Environment['WSLENV'] = ''
  foreach ($argument in @('-d','Ubuntu','--exec','/usr/bin/env','-i','PATH=/usr/bin:/bin','LANG=C','/usr/bin/python3','-',$linuxHelper)) { $start.ArgumentList.Add($argument) }
  $process = [Diagnostics.Process]::Start($start)
  $output = $process.StandardOutput.ReadToEndAsync(); $errors = $process.StandardError.ReadToEndAsync()
  $process.StandardInput.WriteLine($fixture); $process.StandardInput.Close()
  while (-not $process.WaitForExit(1000)) {}
  Write-Output $output.GetAwaiter().GetResult()
  Write-Output $errors.GetAwaiter().GetResult()
  if ($process.ExitCode -ne 0) { throw "native copied-runtime qualification failed: $($process.ExitCode)" }
  $fixtureId = [guid]::NewGuid().ToString('N')
  $windowsRoot = Join-Path ([IO.Path]::GetTempPath()) "native-wrapper-$fixtureId"
  $linuxRoot = "/srv/chase-sets-pg-probe/native-db-component-$fixtureId"
  $anchor = Join-Path $windowsRoot 'anchor'
  $runtime = Join-Path $windowsRoot '.orchestrator'
  $artifacts = Join-Path $anchor '.orchestrator/artifacts'
  $nativeChildren = [Collections.Generic.List[object]]::new()
  function Start-NativeFixture([string[]]$Mode, [switch]$OmitBranch) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName=(Get-Process -Id $PID).Path; $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    foreach ($key in @($start.Environment.Keys)) {
      if ($key -like 'CHASE_SETS_HEAVY_*' -or $key -in @('NODE_OPTIONS','npm_config_script_shell')) { [void]$start.Environment.Remove($key) }
    }
    $binding=@('-ClaimedHead',$head)
    if (-not $OmitBranch) { $binding=@('-Branch','codex/synthetic')+$binding }
    foreach ($argument in @('-NoProfile','-NonInteractive','-File',(Join-Path $runtime 'invoke-heavy-verifier.ps1'),'-ContainerRoot',$windowsRoot,'-Worktree',$anchor,'-Lane','synthetic-native-component')+$binding+$Mode) { $start.ArgumentList.Add($argument) }
    $child=[Diagnostics.Process]::Start($start)
    $entry=@{process=$child;start=$child.StartTime.ToUniversalTime().Ticks;out=$child.StandardOutput.ReadToEndAsync();err=$child.StandardError.ReadToEndAsync()}
    $nativeChildren.Add($entry)
    return $entry
  }
  function Complete-NativeFixture($Entry, [int]$Exit) {
    if (-not $Entry.process.WaitForExit(30000)) { throw 'native fixture did not finish' }
    $text=$Entry.out.GetAwaiter().GetResult()+$Entry.err.GetAwaiter().GetResult()
    if ($Entry.process.ExitCode -ne $Exit) { throw "native fixture expected $Exit got $($Entry.process.ExitCode): $text" }
    return $text
  }
  function Wait-NativeOwner([int]$Schema, [string]$LockName = 'verify-lock.d') {
    $path=Join-Path $runtime "$LockName/owner.json"
    $deadline=[DateTime]::UtcNow.AddSeconds(30)
    while ([DateTime]::UtcNow -lt $deadline) {
      if (Test-Path $path) {
        try {
          $record=Get-Content $path -Raw | ConvertFrom-Json -DateKind String
          if ($record.schemaVersion -eq $Schema -and $record.state -ceq 'started' -and ($Schema -ne 6 -or $record.native.linux)) { return $record }
        } catch {}
      }
      Start-Sleep -Milliseconds 50
    }
    throw 'native fixture owner publication expired'
  }
  $linuxSetup = @'
import pathlib, sys
source, root = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
assert root.parent == pathlib.Path('/srv/chase-sets-pg-probe') and root.name.startswith('native-db-component-')
root.mkdir(mode=0o755)
text = source.read_text().replace("Path('/opt/chase-sets-native-db/admission.py')", "Path("+repr(str(root/'admission.py'))+")").replace("Path('/opt/chase-sets-native-db/reconciliation-pg16.mjs')", "Path("+repr(str(root/'absent-runner.mjs'))+")")
(root/'admission.py').write_text(text)
'@
  try {
    New-Item -ItemType Directory $runtime,$artifacts -Force | Out-Null
    $copy = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'invoke-heavy-verifier.ps1')).Replace('/opt/chase-sets-native-db/admission.py', "$linuxRoot/admission.py")
    [IO.File]::WriteAllText((Join-Path $runtime 'invoke-heavy-verifier.ps1'), $copy)
    & C:\Windows\System32\wsl.exe -d Ubuntu --exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=C /usr/bin/python3 -c $linuxSetup $linuxHelper $linuxRoot
    if ($LASTEXITCODE -ne 0) { throw 'native wrapper fixture setup failed' }
    Set-Content (Join-Path $anchor '.gitignore') ".orchestrator/artifacts/`nnode_modules/"
    & git -C $anchor init -b codex/synthetic --quiet
    & git -C $anchor -c user.name=Synthetic -c user.email=synthetic@example.invalid add .
    & git -C $anchor -c user.name=Synthetic -c user.email=synthetic@example.invalid commit -m synthetic --quiet
    $head = (& git -C $anchor rev-parse HEAD).Trim()
    $request = @{
      schemaVersion=1; correlation=1; profile='reconciliation-pg16/v1'; run='synthetic-native-component'; issue=2147483647; attempt=1; executorHead=('a'*40)
      product=@{repository='synthetic/native-fixture';head=('b'*40);tree=('c'*40)}
      declaration=@{version=1;profile='reconciliation-pg16/v1';mutants=@();files=@(
        @{file='bounded-contexts/channels/features/reconciliation/tests/channel-drift-classification-table.test.ts';cases=@('synthetic')},
        @{file='bounded-contexts/channels/features/reconciliation/tests/channel-reconciliation-runtime.db.test.ts';cases=@('synthetic')},
        @{file='deployables/platform-worker/__tests__/channels-reconciliation-runners.db.test.ts';cases=@('synthetic')}
      )};patchDigests=@();stagedInputDirectory='/srv/chase-sets-native-db-input/synthetic'
    }
    $requestPath = Join-Path $artifacts 'request.json'
    [IO.File]::WriteAllText($requestPath, ($request | ConvertTo-Json -Depth 12 -Compress))
    $nativeMode=@('-NativeDbProfile','reconciliation-pg16/v1','-NativeRequestPath',$requestPath)
    $missing=Start-NativeFixture $nativeMode -OmitBranch
    if ((Complete-NativeFixture $missing 73) -notmatch 'supply both') { throw 'native missing-branch refusal lost its boundary' }
    $exactHead=$head; $head='0'*40
    $wrong=Start-NativeFixture $nativeMode
    $head=$exactHead
    if ((Complete-NativeFixture $wrong 73) -notmatch 'does not match the live Git HEAD') { throw 'native wrong-head refusal lost its boundary' }
    $mixed=Start-NativeFixture ($nativeMode+@('-ImmutableHead',$head))
    if ((Complete-NativeFixture $mixed 73) -notmatch 'supply both') { throw 'native mixed identity was not refused' }
    $dirtyPath=Join-Path $anchor 'synthetic-dirty.fixture'
    [IO.File]::WriteAllText($dirtyPath,'synthetic')
    try {
      $dirty=Start-NativeFixture $nativeMode
      if ((Complete-NativeFixture $dirty 73) -notmatch 'clean exact-head') { throw 'native dirty anchor was not refused' }
    } finally { Remove-Item -LiteralPath $dirtyPath }
    foreach ($extra in @(@('-CommandPath',(Get-Process -Id $PID).Path),@('-NativeEnvironment','PGHOSTADDR=synthetic'))) {
      [void](Complete-NativeFixture (Start-NativeFixture ($nativeMode+$extra)) 1)
    }
    [void](Complete-NativeFixture (Start-NativeFixture @('-NativeDbProfile','Reconciliation-pg16/v1','-NativeRequestPath',$requestPath)) 1)
    $requestRaw = [IO.File]::ReadAllText($requestPath)
    foreach ($encoding in @([Text.UTF8Encoding]::new($true), [Text.UnicodeEncoding]::new($false, $true))) {
      [byte[]]$encoded = $encoding.GetPreamble() + $encoding.GetBytes($requestRaw)
      [IO.File]::WriteAllBytes($requestPath, $encoded)
      [void](Complete-NativeFixture (Start-NativeFixture $nativeMode) 73)
    }
    [IO.File]::WriteAllText($requestPath, $requestRaw, [Text.UTF8Encoding]::new($false))
    if ((Test-Path (Join-Path $runtime 'verify-lock.d')) -or @(Get-ChildItem $artifacts -Filter 'native-db-*.json').Count) { throw 'native prelaunch refusals must leave no owner or execution evidence' }
    Write-Output 'PASS native invocation forms: missing branch, wrong head, dirty anchor, mixed identity, command/env surface, profile case and changed encoding refuse before body'
    $reply = @(& pwsh -NoProfile -File (Join-Path $runtime 'invoke-heavy-verifier.ps1') -NativeDbProfile reconciliation-pg16/v1 -NativeRequestPath $requestPath -ContainerRoot $windowsRoot -Worktree $anchor -Lane synthetic-native-component -Branch codex/synthetic -ClaimedHead $head 2>&1)
    $exit = $LASTEXITCODE
    Write-Output ($reply -join "`n")
    if ($exit -ne 73) { throw "native missing runner expected 73, got $exit" }
    $record = ($reply | Where-Object { "$_".StartsWith('{') } | Select-Object -Last 1) | ConvertFrom-Json -DateKind String
    if ($record.status -cne 'refused' -or -not $record.owner -or -not $record.evidencePath) { throw 'native missing runner lacks typed refusal/evidence' }
    $evidence=Get-Content -LiteralPath $record.evidencePath -Raw | ConvertFrom-Json -DateKind String
    if (-not $evidence.cleanup.initAbsent -or -not $evidence.cleanup.rootAbsent -or $evidence.releasedUtc -notmatch 'T.*Z$') { throw 'native evidence lacks actual release and independent cleanup proof' }
    if (Test-Path (Join-Path $runtime 'verify-lock.d')) { throw 'native missing runner retained owner despite exact cleanup' }
    Write-Output 'PASS copied wrapper: real Windows schema6 publication, real Linux missing-runner refusal, guarded-root release, unchanged product slot'
    $replay=Start-NativeFixture @('-NativeDbProfile','reconciliation-pg16/v1','-NativeRequestPath',$requestPath)
    $replayText=Complete-NativeFixture $replay 73
    if ($replayText -notmatch 'correlation already consumed' -or (Test-Path (Join-Path $runtime 'verify-lock.d'))) { throw 'duplicate correlation must refuse before acquisition' }
    foreach ($name in @('heavy-admission-preload.cjs','heavy-slot.cjs','heavy-nested-owner.cs','heavy-nested-client.cjs','heavy-admission-holder-launcher.cjs','dispatch-ownership.ps1')) {
      Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $runtime
    }
    [IO.File]::WriteAllText((Join-Path $anchor 'package.json'), '{"name":"synthetic-native-exclusion","private":true,"scripts":{"verify:static":"node static-fixture.cjs"}}')
    [IO.File]::WriteAllText((Join-Path $anchor 'pnpm-lock.yaml'), "lockfileVersion: '9.0'`n`nsettings:`n  autoInstallPeers: true`n  excludeLinksFromLockfile: false`n`nimporters:`n`n  .: {}`n")
    [IO.File]::WriteAllText((Join-Path $anchor 'static-fixture.cjs'), "const fs=require('node:fs');fs.writeFileSync('.orchestrator/artifacts/static-body','entered');const timer=setInterval(()=>{if(fs.existsSync('.orchestrator/artifacts/static-release'))clearInterval(timer)},25);")
    & git -C $anchor add package.json static-fixture.cjs pnpm-lock.yaml
    & git -C $anchor -c user.name=Synthetic -c user.email=synthetic@example.invalid commit -m synthetic-exclusion --quiet
    $head=(& git -C $anchor rev-parse HEAD).Trim()
    $inertSetup=@'
import hashlib,pathlib,shutil,sys
root=pathlib.Path(sys.argv[1]); assert root.resolve()==root and root.parent==pathlib.Path('/srv/chase-sets-pg-probe')
inputs=root/'inputs'; (inputs/'synthetic/tools').mkdir(parents=True)
shutil.copy2(pathlib.Path(sys.executable).resolve(),inputs/'synthetic/tools/node')
helper=root/'admission.py'; text=helper.read_text().replace("Path('/srv/chase-sets-native-db-input')","Path("+repr(str(inputs))+")"); helper.write_text(text)
runner=root/'absent-runner.mjs'
runner.write_text("import pathlib,os,time\nr=pathlib.Path(os.environ['HOME'])\n(r/'ready').write_text('inert')\nwhile not (r/'release').exists(): time.sleep(.025)\n")
pathlib.Path(str(runner)+'.sha256').write_text(hashlib.sha256(runner.read_bytes()).hexdigest())
'@
    & C:\Windows\System32\wsl.exe -d Ubuntu --exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=C /usr/bin/python3 -c $inertSetup $linuxRoot
    if ($LASTEXITCODE -ne 0) { throw 'inert copied runner setup failed' }
    $copy=$copy.Replace('/srv/chase-sets-native-db-input/', "$linuxRoot/inputs/")
    [IO.File]::WriteAllText((Join-Path $runtime 'invoke-heavy-verifier.ps1'),$copy)
    $request.stagedInputDirectory="$linuxRoot/inputs/synthetic"; $request.correlation=2
    [IO.File]::WriteAllText($requestPath,($request | ConvertTo-Json -Depth 12 -Compress))
    $native=Start-NativeFixture @('-NativeDbProfile','reconciliation-pg16/v1','-NativeRequestPath',$requestPath)
    $nativeOwner=Wait-NativeOwner 6
    $readyPython=@'
import pathlib,sys,time
root=pathlib.Path(sys.argv[1]); assert root.parent==pathlib.Path('/srv/chase-sets-pg-probe') and root.name.startswith('native-db-') and root.resolve()==root
deadline=time.monotonic()+30
while not (root/'scratch/ready').exists() and time.monotonic()<deadline: time.sleep(.025)
assert (root/'scratch/ready').exists(), 'inert payload did not enter'
'@
    & C:\Windows\System32\wsl.exe -d Ubuntu --exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=C /usr/bin/python3 -c $readyPython $nativeOwner.native.root
    if ($LASTEXITCODE -ne 0) { throw 'native winning body absent' }
    $loser=Start-NativeFixture @('-Gate','verify:static')
    $loserText=Complete-NativeFixture $loser 73
    if ($loserText -notmatch 'lock unavailable' -or (Test-Path (Join-Path $artifacts 'static-body'))) { throw 'native-owned slot failed to exclude real Windows Gate body' }
    $releasePython="import pathlib,sys; r=pathlib.Path(sys.argv[1]); assert r.parent==pathlib.Path('/srv/chase-sets-pg-probe') and r.name.startswith('native-db-') and r.resolve()==r; (r/'scratch/release').write_text('release')"
    & C:\Windows\System32\wsl.exe -d Ubuntu --exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=C /usr/bin/python3 -c $releasePython $nativeOwner.native.root
    if ($LASTEXITCODE -ne 0) { throw 'exact inert native release failed' }
    [void](Complete-NativeFixture $native 0)
    if (Test-Path (Join-Path $runtime 'verify-lock.d')) { throw 'native owner did not release after exact cleanup' }
    $windows=Start-NativeFixture @('-Gate','verify:static')
    [void](Wait-NativeOwner 4)
    $deadline=[DateTime]::UtcNow.AddSeconds(30)
    while (-not (Test-Path (Join-Path $artifacts 'static-body')) -and -not $windows.process.HasExited -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 25 }
    if (-not (Test-Path (Join-Path $artifacts 'static-body'))) { [void](Complete-NativeFixture $windows 0); throw 'Windows Gate fixture body absent' }
    $request.correlation=3
    [IO.File]::WriteAllText($requestPath,($request | ConvertTo-Json -Depth 12 -Compress))
    $loser=Start-NativeFixture @('-NativeDbProfile','reconciliation-pg16/v1','-NativeRequestPath',$requestPath)
    $loserText=Complete-NativeFixture $loser 73
    if ($loserText -notmatch 'lock unavailable') { throw "Windows-owned slot failed to exclude native launch: $loserText" }
    # Same request bytes, anchor, environment and live Windows owner. Only the
    # copied native slot mapping changes; an isolated second slot must make the
    # intended no-body assertion red. No production second slot is introduced.
    $slotMutant=$copy.Replace('else { "verify-lock.d" }', 'elseif ($isNativeDb) { "native-bypass-lock.d" } else { "verify-lock.d" }')
    if ($slotMutant -ceq $copy) { throw 'slot bypass mutation did not apply' }
    [IO.File]::WriteAllText((Join-Path $runtime 'invoke-heavy-verifier.ps1'),$slotMutant)
    try {
      $bypass=Start-NativeFixture @('-NativeDbProfile','reconciliation-pg16/v1','-NativeRequestPath',$requestPath)
      $bypassOwner=Wait-NativeOwner 6 'native-bypass-lock.d'
      & C:\Windows\System32\wsl.exe -d Ubuntu --exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=C /usr/bin/python3 -c $readyPython $bypassOwner.native.root
      if ($LASTEXITCODE -ne 0) { throw 'slot bypass did not violate the native no-body assertion' }
      & C:\Windows\System32\wsl.exe -d Ubuntu --exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=C /usr/bin/python3 -c $releasePython $bypassOwner.native.root
      if ($LASTEXITCODE -ne 0) { throw 'slot mutant exact release failed' }
      [void](Complete-NativeFixture $bypass 0)
      Write-Output 'PASS slot-bypass discrimination: candidate refused; one mutated slot mapping entered inert body with all other invocation inputs frozen'
    } finally { [IO.File]::WriteAllText((Join-Path $runtime 'invoke-heavy-verifier.ps1'),$copy) }
    [IO.File]::WriteAllText((Join-Path $artifacts 'static-release'),'release')
    [void](Complete-NativeFixture $windows 0)
    if (-not (Test-Path (Join-Path $artifacts 'static-body')) -or (Test-Path (Join-Path $runtime 'verify-lock.d'))) { throw 'Windows fixture body/release missing' }
    Write-Output 'PASS copied native and real Windows Gate verify:static reciprocal exclusion; loser bodies absent; no installed exclusion or product test claim'
    $request.correlation=4
    [IO.File]::WriteAllText($requestPath,($request | ConvertTo-Json -Depth 12 -Compress))
    $interrupted=Start-NativeFixture @('-NativeDbProfile','reconciliation-pg16/v1','-NativeRequestPath',$requestPath)
    $interruptedOwner=Wait-NativeOwner 6
    & C:\Windows\System32\wsl.exe -d Ubuntu --exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=C /usr/bin/python3 -c $readyPython $interruptedOwner.native.root
    if ($LASTEXITCODE -ne 0) { throw 'midpayload fixture did not enter payload' }
    $retainedRaw=[IO.File]::ReadAllText((Join-Path $runtime 'verify-lock.d/owner.json'))
    $interrupted.process.Kill(); [void]$interrupted.process.WaitForExit(30000)
    $oldChild=Get-Process -Id $interruptedOwner.childPid -ErrorAction SilentlyContinue
    if ($oldChild) {
      if ($oldChild.StartTime.ToUniversalTime().Ticks -ne [DateTimeOffset]::Parse($interruptedOwner.childProcessStartUtc).Ticks) { throw 'interrupted child identity changed' }
      $oldChild.Kill(); [void]$oldChild.WaitForExit(30000)
    }
    if ([IO.File]::ReadAllText((Join-Path $runtime 'verify-lock.d/owner.json')) -cne $retainedRaw) { throw 'Windows death changed owner bytes' }
    $observePython=@'
import json,pathlib,runpy,sys
module=runpy.run_path(sys.argv[1]); expected=json.loads(sys.argv[2])
assert module['boot_id']()==expected['bootId']
if pathlib.Path('/proc',str(expected['outerPid'])).exists():
    assert module['identity'](expected['outerPid'])==expected, 'reused or ambiguous Linux identity'
    print('OBSERVED exact Linux survivor after Windows wrapper and child loss')
else:
    print('OBSERVED Linux init already absent after Windows loss; this is not root cleanup')
assert pathlib.Path(sys.argv[3]).is_dir(), 'exact R still requires independent cleanup'
'@
    & C:\Windows\System32\wsl.exe -d Ubuntu --exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=C /usr/bin/python3 -c $observePython "$linuxRoot/admission.py" ($interruptedOwner.native.linux | ConvertTo-Json -Compress -Depth 8) $interruptedOwner.native.root
    if ($LASTEXITCODE -ne 0) { throw 'Windows-loss lifecycle observation failed' }
    $request.correlation=5
    [IO.File]::WriteAllText($requestPath,($request | ConvertTo-Json -Depth 12 -Compress))
    $resumed=Start-NativeFixture @('-NativeDbProfile','reconciliation-pg16/v1','-NativeRequestPath',$requestPath)
    $resumedOwner=Wait-NativeOwner 6
    $deadline=[DateTime]::UtcNow.AddSeconds(30)
    while ($resumedOwner.lockId -ceq $interruptedOwner.lockId -and [DateTime]::UtcNow -lt $deadline) {
      Start-Sleep -Milliseconds 100; $resumedOwner=Wait-NativeOwner 6
    }
    if ($resumedOwner.lockId -ceq $interruptedOwner.lockId) { throw 'later claimant did not reconcile prior owner' }
    & C:\Windows\System32\wsl.exe -d Ubuntu --exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=C /usr/bin/python3 -c $readyPython $resumedOwner.native.root
    if ($LASTEXITCODE -ne 0) { throw 'later claimant payload did not enter' }
    $absencePython="import pathlib,sys; assert not pathlib.Path('/proc',sys.argv[1]).exists(); assert not pathlib.Path(sys.argv[2]).exists()"
    & C:\Windows\System32\wsl.exe -d Ubuntu --exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=C /usr/bin/python3 -c $absencePython "$($interruptedOwner.native.linux.outerPid)" $interruptedOwner.native.root
    if ($LASTEXITCODE -ne 0) { throw 'later claimant released without Linux tuple and exact-root absence' }
    & C:\Windows\System32\wsl.exe -d Ubuntu --exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=C /usr/bin/python3 -c $releasePython $resumedOwner.native.root
    if ($LASTEXITCODE -ne 0) { throw 'resumed inert native release failed' }
    [void](Complete-NativeFixture $resumed 0)
    Write-Output 'PASS copied wrapper loss: unchanged owner and R retained, independent Linux state observed, later all-root claimant reconciles exact tuple and R before next invocation'
    $failureSetup=@'
import hashlib,pathlib,sys
root=pathlib.Path(sys.argv[1]); assert root.resolve()==root and root.parent==pathlib.Path('/srv/chase-sets-pg-probe')
runner=root/'absent-runner.mjs'; runner.write_text(runner.read_text()+"\nimport sys\nsys.exit(7)\n")
pathlib.Path(str(runner)+'.sha256').write_text(hashlib.sha256(runner.read_bytes()).hexdigest())
'@
    & C:\Windows\System32\wsl.exe -d Ubuntu --exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=C /usr/bin/python3 -c $failureSetup $linuxRoot
    if ($LASTEXITCODE -ne 0) { throw 'inert failure fixture setup failed' }
    $request.correlation=6
    [IO.File]::WriteAllText($requestPath,($request | ConvertTo-Json -Depth 12 -Compress))
    $failed=Start-NativeFixture @('-NativeDbProfile','reconciliation-pg16/v1','-NativeRequestPath',$requestPath)
    $failedOwner=Wait-NativeOwner 6
    & C:\Windows\System32\wsl.exe -d Ubuntu --exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=C /usr/bin/python3 -c $readyPython $failedOwner.native.root
    if ($LASTEXITCODE -ne 0) { throw 'failure fixture body absent' }
    & C:\Windows\System32\wsl.exe -d Ubuntu --exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=C /usr/bin/python3 -c $releasePython $failedOwner.native.root
    $failedReply=(Complete-NativeFixture $failed 1).Trim() | ConvertFrom-Json -DateKind String
    $failedEvidence=Get-Content $failedReply.evidencePath -Raw | ConvertFrom-Json -DateKind String
    if ($failedReply.status -cne 'completed' -or $failedEvidence.result.exit -ne 7 -or -not $failedEvidence.cleanup.rootAbsent) { throw 'payload failure must preserve exit, not import PASS, and still clean exactly' }
    Write-Output 'PASS inert payload failure: actual exit 7 retained, lifecycle completed is not PASS, wrapper exit 1 and exact cleanup'
    $request.correlation=7
    [IO.File]::WriteAllText($requestPath,($request | ConvertTo-Json -Depth 12 -Compress))
    $helperLost=Start-NativeFixture @('-NativeDbProfile','reconciliation-pg16/v1','-NativeRequestPath',$requestPath)
    $helperLostOwner=Wait-NativeOwner 6
    & C:\Windows\System32\wsl.exe -d Ubuntu --exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=C /usr/bin/python3 -c $readyPython $helperLostOwner.native.root
    if ($LASTEXITCODE -ne 0) { throw 'helper-loss body absent' }
    $killHelper=@'
import json,os,pathlib,runpy,signal,sys
module=runpy.run_path(sys.argv[1]); expected=json.loads(sys.argv[2]); root=sys.argv[3]
assert module['identity'](expected['outerPid'])==expected
def parent(pid):
    data=pathlib.Path('/proc',str(pid),'stat').read_text(); return int(data[data.rindex(')')+2:].split()[1])
helper=parent(parent(expected['outerPid']))
arguments=pathlib.Path('/proc',str(helper),'cmdline').read_bytes().split(b'\0')
assert arguments[1:4]==[sys.argv[1].encode(),b'launch',root.encode()]
before=module['identity'](helper); descriptor=os.pidfd_open(helper)
try:
    assert module['identity'](helper)==before
    signal.pidfd_send_signal(descriptor,signal.SIGKILL)
finally: os.close(descriptor)
'@
    & C:\Windows\System32\wsl.exe -d Ubuntu --exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=C /usr/bin/python3 -c $killHelper "$linuxRoot/admission.py" ($helperLostOwner.native.linux | ConvertTo-Json -Compress -Depth 8) $helperLostOwner.native.root
    if ($LASTEXITCODE -ne 0) { throw 'exact helper-loss probe failed' }
    $helperReplyText=Complete-NativeFixture $helperLost 73
    if ($helperReplyText -notmatch '"status":"unknown"' -or (Test-Path (Join-Path $runtime 'verify-lock.d'))) { throw 'lost helper must report unknown and independently finish exact cleanup' }
    Write-Output 'PASS midpayload helper death: exact pidfd target, typed unknown, independent cleanup and no successful result import'
    $precleanupMarker=Join-Path $artifacts 'precleanup'
    $pause="[IO.File]::WriteAllText('$precleanupMarker','paused'); while (`$true) { Start-Sleep -Milliseconds 25 }"
    $pausedCopy=$copy.Replace('$script:nativeResult = $result', $pause+'; $script:nativeResult = $result')
    if ($pausedCopy -ceq $copy) { throw 'precleanup fixture pause did not apply' }
    [IO.File]::WriteAllText((Join-Path $runtime 'invoke-heavy-verifier.ps1'),$pausedCopy)
    $request.correlation=8
    [IO.File]::WriteAllText($requestPath,($request | ConvertTo-Json -Depth 12 -Compress))
    $precleanup=Start-NativeFixture @('-NativeDbProfile','reconciliation-pg16/v1','-NativeRequestPath',$requestPath)
    $precleanupOwner=Wait-NativeOwner 6
    & C:\Windows\System32\wsl.exe -d Ubuntu --exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=C /usr/bin/python3 -c $readyPython $precleanupOwner.native.root
    & C:\Windows\System32\wsl.exe -d Ubuntu --exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=C /usr/bin/python3 -c $releasePython $precleanupOwner.native.root
    $deadline=[DateTime]::UtcNow.AddSeconds(30)
    while (-not (Test-Path $precleanupMarker) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 25 }
    if (-not (Test-Path $precleanupMarker)) { throw 'precleanup boundary was not reached' }
    $precleanupRaw=[IO.File]::ReadAllText((Join-Path $runtime 'verify-lock.d/owner.json'))
    $precleanup.process.Kill(); [void]$precleanup.process.WaitForExit(30000)
    if ([IO.File]::ReadAllText((Join-Path $runtime 'verify-lock.d/owner.json')) -cne $precleanupRaw) { throw 'precleanup wrapper death changed owner bytes' }
    [IO.File]::WriteAllText((Join-Path $runtime 'invoke-heavy-verifier.ps1'),$copy)
    $request.correlation=9
    [IO.File]::WriteAllText($requestPath,($request | ConvertTo-Json -Depth 12 -Compress))
    $next=Start-NativeFixture @('-NativeDbProfile','reconciliation-pg16/v1','-NativeRequestPath',$requestPath)
    $nextOwner=Wait-NativeOwner 6
    $deadline=[DateTime]::UtcNow.AddSeconds(30)
    while ($nextOwner.lockId -ceq $precleanupOwner.lockId -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100; $nextOwner=Wait-NativeOwner 6 }
    if ($nextOwner.lockId -ceq $precleanupOwner.lockId) { throw 'precleanup owner was not independently reconciled' }
    & C:\Windows\System32\wsl.exe -d Ubuntu --exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=C /usr/bin/python3 -c $absencePython "$($precleanupOwner.native.linux.outerPid)" $precleanupOwner.native.root
    if ($LASTEXITCODE -ne 0) { throw 'precleanup release omitted Linux/root absence' }
    & C:\Windows\System32\wsl.exe -d Ubuntu --exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=C /usr/bin/python3 -c $readyPython $nextOwner.native.root
    & C:\Windows\System32\wsl.exe -d Ubuntu --exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=C /usr/bin/python3 -c $releasePython $nextOwner.native.root
    [void](Complete-NativeFixture $next 1)
    Write-Output 'PASS precleanup wrapper loss: unchanged owner retained after payload exit; next invocation independently reconciles before acquiring'
  } finally {
    $identities=@($nativeOwner,$bypassOwner,$interruptedOwner,$resumedOwner,$failedOwner,$helperLostOwner,$precleanupOwner,$nextOwner) | Where-Object { $null -ne $_ }
    if (Test-Path $artifacts) { [IO.File]::WriteAllText((Join-Path $artifacts 'native-case-identities.json'),(@($identities) | ConvertTo-Json -Depth 16)) }
    if (Test-Path $artifacts) { [IO.File]::WriteAllText((Join-Path $artifacts 'static-release'),'release') }
    foreach ($entry in $nativeChildren) {
      if (-not $entry.process.HasExited) { [void]$entry.process.WaitForExit(1000) }
      if (-not $entry.process.HasExited -and $entry.process.StartTime.ToUniversalTime().Ticks -eq $entry.start) {
        $entry.process.Kill(); [void]$entry.process.WaitForExit(30000)
      }
      if ($entry.process.HasExited) {
        [IO.File]::WriteAllText((Join-Path $artifacts "process-$($entry.process.Id).log"), $entry.out.GetAwaiter().GetResult()+$entry.err.GetAwaiter().GetResult())
      }
    }
    foreach ($fixtureLock in @('verify-lock.d','native-bypass-lock.d')) {
    $retainedPath=Join-Path $runtime "$fixtureLock/owner.json"
    if (Test-Path $retainedPath) {
      $retained=Get-Content $retainedPath -Raw | ConvertFrom-Json -DateKind String
      if ($retained.schemaVersion -eq 6 -and $retained.native.linux) {
        $live=Get-Process -Id $retained.childPid -ErrorAction SilentlyContinue
        if ($live -and $live.StartTime.ToUniversalTime().Ticks -eq [DateTimeOffset]::Parse($retained.childProcessStartUtc).Ticks) { $live.Kill(); [void]$live.WaitForExit(30000) }
        $cleanup=@{linux=$retained.native.linux} | ConvertTo-Json -Compress -Depth 8
        $cleanup | & C:\Windows\System32\wsl.exe -d Ubuntu --exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=C /usr/bin/python3 "$linuxRoot/admission.py" reconcile $retained.native.root
        if ($LASTEXITCODE -ne 0) { throw 'owned synthetic Linux processes could not be reconciled' }
      }
    }
    }
    $linuxCleanup = @'
import pathlib, shutil, sys
root = pathlib.Path(sys.argv[1])
assert root.parent == pathlib.Path('/srv/chase-sets-pg-probe') and root.name.startswith('native-db-component-') and root.resolve() == root
shutil.rmtree(root)
'@
    & C:\Windows\System32\wsl.exe -d Ubuntu --exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=C /usr/bin/python3 -c $linuxCleanup $linuxRoot
    if ($LASTEXITCODE -ne 0) { throw "native wrapper fixture cleanup failed: $linuxRoot" }
    Write-Output "NATIVE FIXTURE $windowsRoot"
  }
  return
}
if (-not $Baseline) { & $PSCommandPath -NativeDbOnly }
$source = $PSScriptRoot
$root = Join-Path ([IO.Path]::GetTempPath()) ('host-heavy-test-' + [guid]::NewGuid().ToString('N'))
$runtime = Join-Path $root '.orchestrator'
$worktree = Join-Path $root 'host-fixture'
$artifacts = Join-Path $worktree '.orchestrator/artifacts'
$node = (Get-Command node -CommandType Application | Select-Object -First 1).Source
$pwsh = (Get-Process -Id $PID).Path
$children = [Collections.Generic.List[object]]::new()
function Assert($Condition, $Message) { if (-not $Condition) { throw "ASSERTION FAILED: $Message" } }
function Git([string[]]$Arguments) {
  $output = @(& git.exe -C $worktree @Arguments 2>&1)
  Assert ($LASTEXITCODE -eq 0) ($output -join "`n")
  return ($output -join "`n").Trim()
}
function Start-Child([string]$Executable, [string[]]$Arguments, [hashtable]$Environment = @{}) {
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = $Executable; $start.WorkingDirectory = $worktree
  $start.UseShellExecute = $false; $start.CreateNoWindow = $true
  $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
  foreach ($key in @($start.Environment.Keys)) {
    if ($key -like 'CHASE_SETS_HEAVY_*' -or $key -in @('NODE_OPTIONS', 'npm_config_script_shell')) { [void]$start.Environment.Remove($key) }
  }
  $start.Environment['NODE_OPTIONS'] = "--require=`"$((Join-Path $runtime 'heavy-admission-preload.cjs').Replace('\', '/'))`""
  $start.Environment['HOST_NODE'] = $node
  $start.Environment['HOST_RUNTIME'] = $runtime
  $start.Environment['HOST_ARTIFACTS'] = $artifacts
  foreach ($item in $Environment.GetEnumerator()) { $start.Environment[$item.Key] = $item.Value }
  foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
  $process = [Diagnostics.Process]::Start($start)
  $entry = @{ Process = $process; Start = $process.StartTime.ToUniversalTime().Ticks
    Out = $process.StandardOutput.ReadToEndAsync(); Err = $process.StandardError.ReadToEndAsync() }
  $children.Add($entry)
  return $entry
}
function Complete($Entry, [int]$Exit) {
  Assert ($Entry.Process.WaitForExit(30000)) 'fixture exits within existing 30 second bound'
  $text = $Entry.Out.GetAwaiter().GetResult() + $Entry.Err.GetAwaiter().GetResult()
  Write-Output $text
  Assert ($Entry.Process.ExitCode -eq $Exit) "expected exit $Exit; actual $($Entry.Process.ExitCode)"
}
try {
  New-Item -ItemType Directory $runtime, $artifacts, (Join-Path $worktree 'scripts'), (Join-Path $worktree 'ordering') -Force | Out-Null
  foreach ($file in @('invoke-heavy-verifier.ps1', 'heavy-admission-preload.cjs', 'heavy-slot.cjs', 'heavy-nested-owner.cs', 'heavy-nested-client.cjs', 'heavy-admission-holder-launcher.cjs', 'dispatch-ownership.ps1')) {
    if ($Baseline) {
      $text = @(& git.exe -C (Split-Path -Parent $source) show "0e4eb7955bc102216b34d427ecc43933d2e0ff23`:.orchestrator/$file") -join "`n"
      Assert ($LASTEXITCODE -eq 0) "read baseline $file"
      [IO.File]::WriteAllText((Join-Path $runtime $file), $text)
    } else { Copy-Item -LiteralPath (Join-Path $source $file) -Destination $runtime }
  }
  Set-Content (Join-Path $worktree '.gitignore') ".orchestrator/artifacts/`nnode_modules/"
  Set-Content (Join-Path $worktree 'pnpm-workspace.yaml') "packages:`n  - ordering"
  Set-Content (Join-Path $worktree 'pnpm-lock.yaml') "lockfileVersion: '9.0'`n`nsettings:`n  autoInstallPeers: true`n  excludeLinksFromLockfile: false`n`nimporters:`n`n  .: {}`n`n  ordering: {}"
  Set-Content (Join-Path $worktree 'package.json') '{"name":"synthetic-host-fixture","private":true,"scripts":{"verify:test-db":"node scripts/run-workspaces.mjs test:db"}}'
  Set-Content (Join-Path $worktree 'ordering/package.json') '{"name":"@chase-sets/ordering","private":true,"scripts":{"test":"node ../scripts/run-workspaces.mjs test"}}'
  Set-Content (Join-Path $worktree 'scripts/vitest.mjs') @'
import fs from 'node:fs';
import path from 'node:path';
import cp from 'node:child_process';
import {fileURLToPath} from 'node:url';
fs.appendFileSync(path.join(process.env.HOST_ARTIFACTS, process.env.HOST_MARKER || 'nested.jsonl'), JSON.stringify({pid:process.pid, token:process.env.CHASE_SETS_HEAVY_SLOT_ID})+'\n');
if (process.env.HOST_DEEP === '1') {
  const result = cp.spawnSync(process.execPath, [fileURLToPath(import.meta.url), 'run'], {env:{...process.env,HOST_DEEP:'0',HOST_MARKER:'deep.jsonl'},stdio:'inherit',windowsHide:true});
  if (result.status !== 0) process.exit(result.status ?? 74);
}
process.exit(Number(process.env.HOST_EXIT || 0));
'@
  Set-Content (Join-Path $worktree 'scripts/run-workspaces.mjs') @'
import fs from 'node:fs';
import path from 'node:path';
import cp from 'node:child_process';
import crypto from 'node:crypto';
import {fileURLToPath} from 'node:url';
const out = process.env.HOST_ARTIFACTS;
const script = fileURLToPath(new URL('./vitest.mjs', import.meta.url));
const lock = path.join(process.env.HOST_RUNTIME, 'verify-lock.d/owner.json');
const raw = fs.readFileSync(lock, 'utf8');
const owner = JSON.parse(raw);
fs.appendFileSync(path.join(out, 'body.jsonl'), JSON.stringify({pid:process.pid, token:process.env.CHASE_SETS_HEAVY_SLOT_ID, args:process.argv.slice(2)})+'\n');
function child(name, env = {}, expected = 73) {
  const marker = name + '.jsonl';
  const result = cp.spawnSync(process.execPath, [script, 'run'], {env:{...process.env, HOST_MARKER:marker, ...env}, encoding:'utf8', windowsHide:true});
  if (result.status !== expected || (expected === 73 && fs.existsSync(path.join(out, marker)))) throw Error(name + ': ' + result.status + ' ' + result.stderr);
  console.log('CONTROL '+name+' exit='+result.status+' zeroEffects='+(expected===73));
}
child('nested', {HOST_DEEP:'1',HOST_EXIT:'0'}, 0);
for (const [field, value] of Object.entries({pid:1, processStartUtc:'2000-01-01T00:00:00.0000000Z', childPid:1, childProcessStartUtc:'2000-01-01T00:00:00.0000000Z', head:'a'.repeat(40), worktree:path.dirname(owner.worktree), lane:'wrong-lane', commandIdentity:'b'.repeat(64)})) {
  try { fs.writeFileSync(lock, JSON.stringify({...owner,[field]:value})); child('wrong-'+field); }
  finally { fs.writeFileSync(lock, raw); }
}
child('missing-transport', {CHASE_SETS_HEAVY_SLOT_TRANSPORT:''});
child('forged-transport', {CHASE_SETS_HEAVY_SLOT_TRANSPORT:Buffer.from('{}').toString('base64')});
const descriptor = JSON.parse(Buffer.from(process.env.CHASE_SETS_HEAVY_SLOT_TRANSPORT,'base64').toString());
const forged = {...descriptor, publicKey:crypto.generateKeyPairSync('ec',{namedCurve:'prime256v1'}).publicKey.export({format:'der',type:'spki'}).toString('base64')};
child('forged-key', {CHASE_SETS_HEAVY_SLOT_TRANSPORT:Buffer.from(JSON.stringify(forged)).toString('base64')});
child('forged-command', {CHASE_SETS_HEAVY_SLOT_TRANSPORT:Buffer.from(JSON.stringify({...descriptor,commandIdentity:'c'.repeat(64)})).toString('base64')});
child('copied-token', {CHASE_SETS_HEAVY_SLOT_ID:'a'.repeat(32)});
fs.writeFileSync(path.join(out,'ready.json'), JSON.stringify({token:process.env.CHASE_SETS_HEAVY_SLOT_ID, transport:process.env.CHASE_SETS_HEAVY_SLOT_TRANSPORT, owner}));
if (process.env.HOST_WAIT === '1') {
  while (!fs.existsSync(path.join(out,'release'))) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,25);
}
process.exit(Number(process.env.HOST_EXIT || 0));
'@
  Git @('init', '-b', 'synthetic-host') | Out-Null
  Git @('-c', 'user.name=Synthetic Fixture', '-c', 'user.email=fixture@example.invalid', 'add', '.') | Out-Null
  Git @('-c', 'user.name=Synthetic Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'synthetic fixture') | Out-Null
  $head = Git @('rev-parse', 'HEAD')
  Git @('checkout', '--detach', $head) | Out-Null
  Assert (-not (Git @('status', '--porcelain'))) 'synthetic immutable worktree clean'
  Assert (@(Get-ChildItem $runtime -Filter 'dispatch-launch-*.json').Count -eq 0) 'no dispatch records'
  $guard = Join-Path $runtime 'invoke-heavy-verifier.ps1'
  if ($Baseline) {
    # Installed Gate has no safe Node-pnpm resolver. Use its pre-existing test
    # seam only to reproduce the downstream dispatch refusal without product DB.
    $pnpm = Join-Path $env:APPDATA 'npm/node_modules/pnpm/bin/pnpm.cjs'
    $entry = Join-Path $runtime 'baseline.ps1'
    Set-Content $entry "& '$guard' -Gate verify:test-db -Worktree '$worktree' -Lane host-fixture -ImmutableHead '$head' -ContainerRoot '$root' -CommandPath '$node' -CommandArgumentList @('$pnpm', 'run', 'verify:test-db'); exit `$LASTEXITCODE"
    $run = Start-Child $pwsh @('-NoProfile', '-File', $entry)
    Complete $run 73
    Assert (-not (Test-Path (Join-Path $artifacts 'body.jsonl'))) 'baseline zero body effects'
    Write-Output 'PASS installed-baseline reproduction: no provable dispatch binding; exit 73; zero body effects'
    return
  }
  Assert (-not (Get-Command $guard).Parameters['CommandPath'].ParameterSets.ContainsKey('WorkspaceTest')) 'closed workspace entrypoint has no arbitrary command seam'
  $classification = "const c=require(process.env.HOST_RUNTIME+'/heavy-admission-preload.cjs'); if(c.classifyCommand([process.execPath,'pnpm.mjs','run','test'])!=='repository-gate'||c.classifyCommand([process.execPath,'data.cjs','pnpm.mjs','run','test'])!==null)process.exit(1);"
  Complete (Start-Child $node @('-e', $classification)) 0
  $common = @('-NoProfile', '-File', $guard, '-Worktree', $worktree, '-Lane', 'host-fixture', '-ImmutableHead', $head, '-ContainerRoot', $root)
  $run = Start-Child $pwsh ($common + @('-Gate', 'verify:test-db')) @{HOST_WAIT='1'}
  $ready = Join-Path $artifacts 'ready.json'
  $deadline = [DateTime]::UtcNow.AddSeconds(30)
  while (-not (Test-Path $ready) -and -not $run.Process.HasExited -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 25 }
  if (-not (Test-Path $ready)) { Complete $run 0; throw 'host body never became ready' }
  $state = Get-Content $ready -Raw | ConvertFrom-Json
  # This process is a sibling of the guarded root, with the exact copied token
  # and descriptor. The kernel pipe client/ancestry check must still refuse it.
  $sibling = Start-Child $node @((Join-Path $worktree 'scripts/vitest.mjs'), 'run') @{
    CHASE_SETS_HEAVY_SLOT_ID=$state.token; CHASE_SETS_HEAVY_SLOT_TRANSPORT=$state.transport; HOST_MARKER='sibling.jsonl'
  }
  Complete $sibling 73
  Assert (-not (Test-Path (Join-Path $artifacts 'sibling.jsonl'))) 'sibling zero effects'
  Set-Content (Join-Path $artifacts 'release') 'release'
  Complete $run 0
  Assert (-not (Test-Path (Join-Path $runtime 'verify-lock.d'))) 'same machine slot released'
  Assert (@(Get-Content (Join-Path $artifacts 'body.jsonl')).Count -eq 1) 'declared body exactly once'
  Assert (@(Get-Content (Join-Path $artifacts 'nested.jsonl')).Count -eq 1) 'nested heavy body exactly once'
  Assert (@(Get-Content (Join-Path $artifacts 'deep.jsonl')).Count -eq 1) 'deeper heavy descendant exactly once'
  foreach ($marker in @('body.jsonl', 'nested.jsonl', 'deep.jsonl')) {
    $body = Get-Content (Join-Path $artifacts $marker) -Raw | ConvertFrom-Json
    Assert ($body.token -ceq $state.token) "$marker uses the same sole slot"
  }
  $run = Start-Child $pwsh ($common + @('-WorkspaceTest', '@chase-sets/ordering')) @{HOST_EXIT='9'}
  Complete $run 9
  $receipts = @(Get-ChildItem $artifacts -Filter 'host-heavy-verifier-*.json' | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json })
  Assert ($receipts.Count -eq 2) 'two create-once receipts'
  $receipt = $receipts | Where-Object workspace -eq '@chase-sets/ordering'
  Assert ($receipt.exit -eq 9 -and $receipt.head -ceq $head -and $receipt.lane -ceq 'host-fixture' -and $receipt.worktree -ieq $worktree) 'receipt exit and immutable identity'
  Assert (($receipt.arguments | Select-Object -Skip 1) -join ' ' -ceq '--filter @chase-sets/ordering run test --maxWorkers=1 --no-file-parallelism') 'exact closed package command'
  $identity = "$($receipt.gate)`n$($receipt.executable)`n$($receipt.arguments -join "`n")"
  $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($identity))).ToLowerInvariant()
  Assert ($receipt.commandIdentity -ceq $hash -and $receipt.wrapper.pid -gt 0 -and $receipt.root.pid -gt 0 -and $receipt.wrapper.processStartUtc -and $receipt.root.processStartUtc) 'content-bound command and native wrapper/root identities'
  $gateReceipt = $receipts | Where-Object gate -eq 'verify:test-db'
  Assert ($gateReceipt.wrapper.pid -eq $state.owner.pid -and $gateReceipt.wrapper.processStartUtc -ceq $state.owner.processStartUtc -and
    $gateReceipt.root.pid -eq $state.owner.childPid -and $gateReceipt.root.processStartUtc -ceq $state.owner.childProcessStartUtc) 'receipt matches observed native owner/root'
  $body = @(Get-Content (Join-Path $artifacts 'body.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
  Assert ($body.Count -eq 2 -and ($body[1].args -join ' ') -ceq 'test --maxWorkers=1 --no-file-parallelism') 'workspace body receives exact serial flags once'
  $wrongHead = @($common)
  $wrongHead[[Array]::IndexOf($wrongHead, '-ImmutableHead') + 1] = 'a' * 40
  Complete (Start-Child $pwsh ($wrongHead + @('-Gate', 'verify:test-db'))) 73
  $wrongWorktree = @($common)
  $wrongWorktree[[Array]::IndexOf($wrongWorktree, '-Worktree') + 1] = Join-Path $worktree 'scripts'
  Complete (Start-Child $pwsh ($wrongWorktree + @('-Gate', 'verify:test-db'))) 73
  $manifestPath = Join-Path $worktree 'package.json'
  $manifestBytes = [IO.File]::ReadAllBytes($manifestPath)
  try {
    Add-Content $manifestPath ' '
    Complete (Start-Child $pwsh ($common + @('-Gate', 'verify:test-db'))) 73
  } finally { [IO.File]::WriteAllBytes($manifestPath, $manifestBytes) }
  $pnpmShim = Get-Command pnpm -All -CommandType Application | Where-Object Source -like '*\pnpm.CMD' | Select-Object -First 1
  $shim = Get-Content $pnpmShim.Source -Raw
  Assert ($shim -match '"%~dp0\\(?<relative>[^"]*\\pnpm\.exe)"') 'active packaged pnpm shim has its exact executable'
  $nativePnpm = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $pnpmShim.Source) $Matches.relative))
  $direct = Start-Child $nativePnpm @('run', 'verify:test-db')
  Complete $direct 73
  Assert ($direct.Err.GetAwaiter().GetResult() -match 'use invoke-heavy-verifier.ps1 -Gate or -WorkspaceTest') 'unsafe packaged Node diagnostic names canonical entrypoint'
  Assert (@(Get-Content (Join-Path $artifacts 'body.jsonl')).Count -eq 2) 'prelaunch refusals and packaged pnpm have zero body effects'
  Assert (@(Get-ChildItem $runtime -Filter 'dispatch-launch-*.json').Count -eq 0) 'no fabricated dispatch'
  Write-Output 'PASS host Gate and closed workspace test: exact-once bodies, nested controls, one slot, bound receipts and exact exit'
} finally {
  foreach ($entry in $children) {
    if (-not $entry.Process.HasExited) {
      # Never clean a live or ambiguous owner. Preserve the fixture for diagnosis.
      Write-Warning "fixture still live pid=$($entry.Process.Id); preserved root=$root"
    }
  }
  # Evidence is retained for the governing reviewer, including baseline refusal.
  Write-Output "FIXTURE $root"
}
