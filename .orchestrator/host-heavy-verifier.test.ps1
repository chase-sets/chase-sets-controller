param([switch]$Baseline, [switch]$NativeDbOnly,
  [ValidateSet('', 'host-ready-latency-injection', 'forced-failure-release', 'transition-pause-injection', 'claimant-pause-injection', 'native-terminal-controls', 'harness-controls', 'canonical-record-script-pin')][string]$Control = '')
$ErrorActionPreference = 'Stop'
function Read-FixtureOwner([string]$OwnerPath) {
  $stream=[IO.File]::Open($OwnerPath,'Open','Read',([IO.FileShare]::ReadWrite-bor[IO.FileShare]::Delete))
  try {
    $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$true)
    try { $raw=$reader.ReadToEnd() } finally { $reader.Dispose() }
  } finally { $stream.Dispose() }
  return $raw
}
function Select-NativeReply($Lines, [int]$Correlation, [string]$Status) {
  $typedReplies = @($Lines | ForEach-Object {
    try { "$_" | ConvertFrom-Json -DateKind String } catch { }
  } | Where-Object { $_.correlation -eq $Correlation -and $_.status -ceq $Status })
  if ($typedReplies.Count -ne 1) { throw "native reply must be unique for correlation=$Correlation status=$Status; actual=$($typedReplies.Count)" }
  return $typedReplies[0]
}
function Wait-FixtureSignal([string]$Path, $Producer, [string]$Name) {
  while (-not [IO.File]::Exists($Path)) {
    if ($Producer.HasExited) { throw "$Name producer exited before signal: $($Producer.ExitCode)" }
    Start-Sleep -Milliseconds 25
  }
}
function Release-FixtureChildren([string]$Artifacts, $Children) {
  if (Test-Path $Artifacts) {
    [IO.File]::WriteAllText((Join-Path $Artifacts 'release'), 'release')
  }
  foreach ($entry in $Children) { [void]$entry.Process.WaitForExit() }
}
function Get-FixtureDefinition([string]$Source, [string]$Name) {
  $errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseInput($Source,[ref]$null,[ref]$errors)
  if ($errors) { throw "fixture source does not parse: $errors" }
  $definition=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $Name},$true))
  if ($definition.Count -ne 1) { throw "fixture requires one definition of $Name" }
  return $definition[0].Extent.Text
}
function Assert-Harness($Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}
function Test-TransitionPause {
  $testSource=[IO.File]::ReadAllText($PSCommandPath)
  $guardSource=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'invoke-heavy-verifier.ps1'))
  $writer=Get-FixtureDefinition $guardSource 'Write-OwnerRecord'
  $initialize=Get-FixtureDefinition $guardSource 'Initialize-OwnerRename'
  $anchor='[ChaseSets.HeavyAdmission.OwnerRename]::Publish($temporaryPath, $ownerPath, $destination)'
  Assert-Harness ($writer.Split($anchor).Count -eq 2) 'transition-pause-injection has one exact publication anchor'
  $controlRoot=Join-Path ([IO.Path]::GetTempPath()) ('hhv-transition-'+[guid]::NewGuid().ToString('N'))
  [void][IO.Directory]::CreateDirectory($controlRoot)
  $rows=[Collections.Generic.List[object]]::new()
  foreach ($kind in @('ordinary-started','native-started','native-tuple')) {
    foreach ($site in @('Read-FixtureOwner','Wait-NativeOwner')) {
      foreach ($variant in @('candidate','share-read-mutant')) {
        $lockPath=Join-Path $controlRoot "$kind-$site-$variant"
        [void][IO.Directory]::CreateDirectory($lockPath)
        $ownerPath=Join-Path $lockPath 'owner.json'
        $before=@{schemaVersion=4;state='launching';native=@{linux=$null}}
        $after=@{schemaVersion=4;state='started';native=@{linux=$null}}
        if ($kind -like 'native-*') { $before.schemaVersion=6; $after.schemaVersion=6 }
        if ($kind -ceq 'native-tuple') {
          $before.state='started'
          $after.native.linux=@{outerPid=42;startTicks='123';bootId='12345678-1234-1234-1234-123456789abc';nspid=@(42,1);inode='456'}
        }
        . ([scriptblock]::Create($writer))
        $beforeRaw=Write-OwnerRecord $before -CreateNew
        $pending=Join-Path $lockPath 'pending'; $release=Join-Path $lockPath 'publication.release'
        $pause="[IO.File]::WriteAllText('$pending','pending'); while (-not [IO.File]::Exists('$release')) { Start-Sleep -Milliseconds 10 }; "
        $publisher=Join-Path $lockPath 'publisher.ps1'
        $scriptText='$ErrorActionPreference="Stop"; $lockPath=' + "'$lockPath'; " + '$ownerPath=' + "'$ownerPath'`n" + $initialize + "`nInitialize-OwnerRename`n" + $writer.Replace($anchor,$pause+$anchor) + "`n" + '$after=' + "'$($after|ConvertTo-Json -Depth 16 -Compress)'|ConvertFrom-Json -AsHashtable; Write-OwnerRecord `$after"
        [IO.File]::WriteAllText($publisher,$scriptText)
        $start=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
        $start.UseShellExecute=$false; $start.CreateNoWindow=$true; $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
        foreach ($arg in @('-NoProfile','-File',$publisher)) { $start.ArgumentList.Add($arg) }
        $child=[Diagnostics.Process]::Start($start)
        $stdout=$child.StandardOutput.ReadToEndAsync(); $stderr=$child.StandardError.ReadToEndAsync()
        try {
          Wait-FixtureSignal $pending $child 'transition pause'
          $reader=Get-FixtureDefinition $testSource $site
          if ($site -ceq 'Wait-NativeOwner') {
            # Execute precisely its snapshot/decoder, not the surrounding wait.
            $begin=$reader.IndexOf('$stream=')
            $end=$reader.IndexOf("`n          if (`$record.schemaVersion",$begin)
            $reader='param($OwnerPath)' + "`n" + '$path=$OwnerPath;' + $reader.Substring($begin,$end-$begin) + '; return $raw'
          }
          $openLine=@($reader -split "`n" | Where-Object { $_.Contains('$stream=[IO.File]::Open(') })[0]
          Assert-Harness ([bool]$openLine) "$site has a snapshot open to pause"
          $reader=$reader.Replace($openLine,$openLine+"`n [IO.File]::WriteAllText('$release','release'); `$child.WaitForExit()")
          if ($variant -ceq 'share-read-mutant') { $reader=$reader.Replace('([IO.FileShare]::ReadWrite-bor[IO.FileShare]::Delete)','[IO.FileShare]::Read') }
          if ($site -ceq 'Read-FixtureOwner') {
            . ([scriptblock]::Create($reader))
            $observed=Read-FixtureOwner $ownerPath
          } else { $observed=& ([scriptblock]::Create($reader)) $ownerPath }
          $output=$stdout.GetAwaiter().GetResult(); $errorText=$stderr.GetAwaiter().GetResult()
          $failure=$null
          try {
            Assert-Harness ($child.ExitCode -eq 0) "$site $kind paused publication succeeds while the snapshot handle is open"
          } catch { $failure=$_.Exception.Message }
          $rows.Add(@{site=$site;transition=$kind;variant=$variant;exit=$child.ExitCode;assertion=$failure;output=$output;error=$errorText})
          if ($variant -ceq 'candidate') {
            if ($failure) { throw $failure }
            Assert-Harness ($observed -ceq $beforeRaw) "$site $kind takes one old-record snapshot"
            $fresh=Read-FixtureOwner $ownerPath
            Assert-Harness ($fresh -ceq $output.Trim() -and ($fresh|ConvertFrom-Json).state -ceq 'started') "$site $kind reopens the published state and tuple"
          } else {
            Assert-Harness ($failure -clike '*paused publication succeeds*') "$site $kind share mutant dies at its publication assertion"
            Write-Output "MUTANT_RED share-read/$site/$kind $failure"
          }
        } finally {
          [IO.File]::WriteAllText($release,'release')
          [void]$child.WaitForExit()
        }
      }
    }
  }
  [IO.File]::WriteAllText((Join-Path $controlRoot 'results.json'),($rows|ConvertTo-Json -Depth 16))
  Write-Output "CONTROL transition-pause-injection GREEN evidence=$controlRoot"
}
function Test-HarnessControls {
  $lines=@('{"correlation":1,"status":"refused","proof":"expected"}', '{"correlation":2,"status":"refused","proof":"wrong-correlation"}', '{"correlation":1,"status":"completed","proof":"wrong-status"}', 'not json')
  foreach ($order in @(@(0,1,2,3),@(3,2,1,0),@(1,0,3,2))) {
    $reply=Select-NativeReply $lines[$order] 1 'refused'
    Assert-Harness ($reply.proof -ceq 'expected') 'typed reply is bound to correlation and status regardless of stream order'
  }
  foreach ($bad in @(@($lines[1]),@($lines[0],$lines[0]))) {
    $refused=$false
    try { [void](Select-NativeReply $bad 1 'refused') } catch { $refused=$_.Exception.Message -clike 'native reply must be unique*' }
    Assert-Harness $refused 'missing or duplicated typed reply is refused'
  }
  $source=[IO.File]::ReadAllText($PSCommandPath)
  $selector=Get-FixtureDefinition $source 'Select-NativeReply'
  foreach ($seam in @('$_.correlation -eq $Correlation -and ', ' -and $_.status -ceq $Status')) {
    $mutant=$selector.Replace($seam,'')
    . ([scriptblock]::Create($mutant))
    $killed=$false
    try { $reply=Select-NativeReply $lines 1 'refused'; Assert-Harness ($reply.proof -ceq 'expected') 'typed reply is bound to correlation and status regardless of stream order' } catch { $killed=$true; Write-Output "MUTANT_RED reply-selector $($_.Exception.Message)" }
    Assert-Harness $killed 'typed-reply mutant is killed by the correlation/status assertion'
  }
  . ([scriptblock]::Create($selector))
  $root=Join-Path ([IO.Path]::GetTempPath()) ('hhv-signal-'+[guid]::NewGuid().ToString('N'))
  [void][IO.Directory]::CreateDirectory($root)
  $signal=Join-Path $root 'signal'
  [IO.File]::WriteAllText($signal,'signal')
  Wait-FixtureSignal $signal ([pscustomobject]@{HasExited=$true;ExitCode=7}) 'positive'
  $refused=$false
  try { Wait-FixtureSignal (Join-Path $root 'absent') ([pscustomobject]@{HasExited=$true;ExitCode=7}) 'negative' } catch { $refused=$_.Exception.Message -ceq 'negative producer exited before signal: 7' }
  Assert-Harness $refused 'terminal producer without signal deterministically fails naming exit and code'
  $wait=Get-FixtureDefinition $source 'Wait-FixtureSignal'
  . ([scriptblock]::Create($wait.Replace('if ($Producer.HasExited)', 'if (-not $Producer.HasExited)')))
  $failure=$null
  try { Wait-FixtureSignal (Join-Path $root 'absent') ([pscustomobject]@{HasExited=$false;ExitCode=$null}) 'live' } catch { $failure=$_.Exception.Message }
  Assert-Harness ($failure -ceq 'live producer exited before signal: ') 'inverted terminal guard fails at its premature producer-exit assertion'
  Write-Output "MUTANT_RED signal-terminal $failure"
  . ([scriptblock]::Create($wait))
  $cleanup=Get-FixtureDefinition $source 'Release-FixtureChildren'
  foreach ($variant in @('candidate','omit-release-mutant')) {
    $releasePath=Join-Path $root 'release'
    if (Test-Path $releasePath) { Remove-Item -LiteralPath $releasePath }
    $process=[pscustomobject]@{ReleasePath=$releasePath;Observed=$false}
    $process | Add-Member ScriptMethod WaitForExit {
      Assert-Harness ([IO.File]::Exists($this.ReleasePath)) 'failure cleanup releases fixture before observing child exit'
      $this.Observed=$true
    }
    $definition=$cleanup
    if ($variant -ceq 'omit-release-mutant') { $definition=$definition.Replace("(Join-Path `$Artifacts 'release')", "(Join-Path `$Artifacts 'wrong-release')") }
    . ([scriptblock]::Create($definition))
    $failure=$null
    try { Release-FixtureChildren $root @(@{Process=$process}) } catch { $failure=$_.Exception.Message }
    if ($variant -ceq 'candidate') {
      Assert-Harness (-not $failure -and $process.Observed) 'failure cleanup observes child terminal state after release'
    } else {
      Assert-Harness ($failure -clike '*ASSERTION FAILED: failure cleanup releases fixture before observing child exit*') 'release mutant dies at its release-before-exit assertion'
      Write-Output "MUTANT_RED failure-release $failure"
    }
  }
  . ([scriptblock]::Create($cleanup))
  Write-Output 'CONTROL harness-controls GREEN reply order, missing/duplicate replies, signal-before-exit and terminal-without-signal'
}
function Test-NativeTerminalControls {
  $source=[IO.File]::ReadAllText($PSCommandPath)
  $ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$null,[ref]$null)
  $root=Join-Path ([IO.Path]::GetTempPath()) ('hhv-native-terminal-'+[guid]::NewGuid().ToString('N'))
  [void][IO.Directory]::CreateDirectory($root)
  $terminal=@{process=[pscustomobject]@{HasExited=$true;ExitCode=7}}
  foreach ($name in @('owner','static-body','resumed','precleanup','next')) {
    $message=switch ($name) {
      owner { 'native fixture producer exited before owner publication: 7' }
      static-body { 'Windows Gate fixture producer exited before static-body signal: 7' }
      resumed { 'resumed claimant exited before publishing a new owner: 7' }
      precleanup { 'precleanup producer exited before boundary signal: 7' }
      next { 'next claimant exited before publishing a new owner: 7' }
    }
    if ($name -ceq 'owner') {
      $definition=Get-FixtureDefinition $source 'Wait-NativeOwner'
      $guard='$Producer -and $Producer.process.HasExited'
      $body=$definition+"`nWait-NativeOwner 6 -Producer `$terminal"
    } else {
      $loop=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.WhileStatementAst] -and $n.Extent.Text.Contains($message.Split(':')[0])},$true))
      Assert-Harness ($loop.Count -eq 1) "$name has one native terminal wait"
      $body=$loop[0].Extent.Text
      $guard=switch ($name) {
        static-body { '$windows.process.HasExited' }
        resumed { '$resumed.process.HasExited' }
        precleanup { '$precleanup.process.HasExited' }
        next { '$next.process.HasExited' }
      }
    }
    foreach ($variant in @('candidate','omit-terminal-mutant')) {
      $runtime=Join-Path $root ([guid]::NewGuid().ToString('N'))
      $artifacts=$runtime; [void][IO.Directory]::CreateDirectory((Join-Path $runtime 'verify-lock.d'))
      $precleanupMarker=Join-Path $runtime 'precleanup'
      $windows=$resumed=$precleanup=$next=$terminal
      $resumedOwner=$interruptedOwner=$nextOwner=$precleanupOwner=[pscustomobject]@{lockId='old'}
      # A deterministic later signal makes a missing terminal arm return, not hang.
      function Start-Sleep {
        param($Milliseconds)
        [IO.File]::WriteAllText((Join-Path $runtime 'verify-lock.d/owner.json'),'{"schemaVersion":6,"state":"started","native":{"linux":{"outerPid":42}}}')
        [IO.File]::WriteAllText((Join-Path $artifacts 'static-body'),'late')
        [IO.File]::WriteAllText($precleanupMarker,'late')
      }
      Set-Item function:Wait-NativeOwner -Value { param($Schema,$Producer) [pscustomobject]@{lockId='new'} }
      $script=$body
      if ($variant -ceq 'omit-terminal-mutant') { $script=$script.Replace("if ($guard)",'if ($false)') }
      $failure=$null
      try { & ([scriptblock]::Create($script)) | Out-Null } catch { $failure=$_.Exception.Message }
      $assertion=$null
      try { Assert-Harness ($failure -ceq $message) "$name terminal state fails before a later signal: expected '$message'; actual '$failure'" } catch { $assertion=$_.Exception.Message }
      if ($variant -ceq 'candidate') { if ($assertion) { throw $assertion } }
      else {
        Assert-Harness ($assertion -clike "ASSERTION FAILED: $name terminal state fails before a later signal*") "$name mutant reaches its terminal assertion"
        Write-Output "MUTANT_RED native-$name $assertion"
      }
    }
  }
  $texts=@{}
  foreach ($name in @('fixture','readyPython')) {
    $assignment=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq ('$'+$name)},$true))
    Assert-Harness ($assignment.Count -eq 1) "$name has one embedded native fixture"
    $texts[$name]=$assignment[0].Right.Expression.Value
  }
  $python=@'
import ast, copy, json, subprocess, sys, types
texts=json.load(sys.stdin)
rows=[]
for name,source in texts.items():
    tree=ast.parse(source)
    for parent in ast.walk(tree):
        for field,value in ast.iter_fields(parent):
            if not isinstance(value,list): continue
            for index,node in enumerate(value[:-1]):
                if not isinstance(node,ast.While) or not isinstance(value[index+1],ast.Assert): continue
                following=value[index+1]
                arms=[]
                for arm in node.test.values if isinstance(node.test,ast.BoolOp) else []:
                    rendered=ast.unparse(arm)
                    if 'process.poll()' in rendered: arms.append(('producer-exit',arm))
                    elif 'result.json' in rendered: arms.append(('result-terminal',arm))
                    elif "'/proc'" in rendered: arms.append(('init-absent',arm))
                if not arms: continue
                for terminal,target in arms:
                    label=f'{name}:{node.lineno}:{terminal}'
                    for mutant in (False,True):
                        state={'late':False}
                        class Path:
                            def __init__(self,*parts): self.text='/'.join(map(str,parts))
                            def __truediv__(self,part): return Path(self.text,part)
                            def exists(self):
                                if 'result.json' in self.text: return terminal=='result-terminal'
                                if '/proc' in self.text: return terminal!='init-absent'
                                return state['late']
                            def read_text(self): return '42' if '/children' in self.text else '{"status":"completed"}'
                        def poll(): return 7 if terminal=='producer-exit' else None
                        def pace(_): state['late']=True
                        env={'root':Path('/fixture'),'pathlib':types.SimpleNamespace(Path=Path),
                             'process':types.SimpleNamespace(poll=poll),'time':types.SimpleNamespace(sleep=pace),
                             'members':[],'expected':{'outerPid':41},'inner':1,'pid':41,
                             'module':types.SimpleNamespace(identity=lambda outer:{'nspid':[outer,1]})}
                        loop=copy.deepcopy(node)
                        if mutant:
                            arm_index=node.test.values.index(target)
                            loop.test.values[arm_index]=ast.Constant(True)
                        block=ast.fix_missing_locations(ast.Module(body=[loop,copy.deepcopy(following)],type_ignores=[]))
                        failure=None
                        try: exec(compile(block,'native-wait-control','exec'),env)
                        except AssertionError as error: failure=str(error)
                        assertion=None
                        try:
                            diagnostic=eval(compile(ast.Expression(following.msg),'native-diagnostic','eval'),env)
                            assert failure==diagnostic and not state['late'], f'{label} terminal state must fail at the native missing-signal assertion before a later signal; actual={failure!r}'
                        except AssertionError as error: assertion=str(error)
                        if mutant:
                            assert assertion is not None, f'{label} mutant survived'
                            print('MUTANT_RED '+assertion,flush=True)
                        else:
                            assert assertion is None, assertion
                        rows.append((label,mutant,failure,assertion))
    if name=='fixture':
        function=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='line')
        for index in (1,3):
            for mutant in (False,True):
                fn=copy.deepcopy(function)
                if mutant: fn.body[index].test=ast.Constant(True)
                env={'select':types.SimpleNamespace(select=lambda *args:([] if index==1 else [1],[],[])),
                     'json':types.SimpleNamespace(loads=lambda raw:{})}
                exec(compile(ast.fix_missing_locations(ast.Module(body=[fn],type_ignores=[])),'native-eof-control','exec'),env)
                failure=None
                try: env['line'](types.SimpleNamespace(stdout=types.SimpleNamespace(readline=lambda:b'')))
                except AssertionError as error: failure=str(error)
                expected='fixture producer reached EOF before reply' if index==1 else 'fixture producer EOF before reply'
                assertion=None
                try: assert failure==expected, f'line:{index} EOF must fail at its named assertion; actual={failure!r}'
                except AssertionError as error: assertion=str(error)
                if mutant:
                    assert assertion is not None
                    print('MUTANT_RED '+assertion,flush=True)
                else: assert assertion is None,assertion
                rows.append((f'line:{index}',mutant,failure,assertion))
assert len(rows)==24, rows
print('CONTROL native Python terminal guards GREEN cases='+str(len(rows)),flush=True)
'@
  $start=[Diagnostics.ProcessStartInfo]::new('C:\Windows\System32\wsl.exe')
  $start.UseShellExecute=$false; $start.CreateNoWindow=$true
  $start.RedirectStandardInput=$true; $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
  $start.Environment['WSLENV']=''
  foreach ($arg in @('-d','Ubuntu','--exec','/usr/bin/python3','-c',$python)) { $start.ArgumentList.Add($arg) }
  $child=[Diagnostics.Process]::Start($start)
  $stdout=$child.StandardOutput.ReadToEndAsync(); $stderr=$child.StandardError.ReadToEndAsync()
  $child.StandardInput.WriteLine(($texts|ConvertTo-Json -Compress)); $child.StandardInput.Close()
  [void]$child.WaitForExit()
  Write-Output $stdout.GetAwaiter().GetResult(); Write-Output $stderr.GetAwaiter().GetResult()
  Assert-Harness ($child.ExitCode -eq 0) 'native Python terminal control exits zero'
  Write-Output 'CONTROL native-terminal-controls GREEN'
}
if ($Control -ceq 'native-terminal-controls') { Test-NativeTerminalControls; return }
if ($Control -ceq 'transition-pause-injection') { Test-TransitionPause; return }
if ($Control -ceq 'harness-controls') { Test-HarnessControls; return }
if ($Control -ceq 'claimant-pause-injection' -and -not $NativeDbOnly) {
  foreach ($kind in @('ordinary-started','native-started','native-tuple')) {
    foreach ($site in @('Read-FixtureOwner','Wait-NativeOwner')) {
      foreach ($variant in @('candidate','share-read-mutant')) {
        $start=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
        $start.UseShellExecute=$false; $start.CreateNoWindow=$true
        $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
        $start.Environment['HHV_PAUSE_KIND']=$kind; $start.Environment['HHV_PAUSE_SITE']=$site; $start.Environment['HHV_PAUSE_VARIANT']=$variant
        foreach ($arg in @('-NoProfile','-File',$PSCommandPath,'-NativeDbOnly','-Control','claimant-pause-injection')) { $start.ArgumentList.Add($arg) }
        $child=[Diagnostics.Process]::Start($start)
        $stdout=$child.StandardOutput.ReadToEndAsync(); $stderr=$child.StandardError.ReadToEndAsync()
        [void]$child.WaitForExit()
        Write-Output $stdout.GetAwaiter().GetResult(); Write-Output $stderr.GetAwaiter().GetResult()
        Assert-Harness ($child.ExitCode -eq 0) "$kind $site $variant full claimant control exits zero"
      }
    }
  }
  Write-Output 'CONTROL claimant-pause-injection GREEN twelve complete claimant cases'
  return
}
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
    ready, _, _ = select.select([process.stdout], [], [])
    assert ready, 'fixture producer reached EOF before reply'
    raw = process.stdout.readline()
    assert raw, 'fixture producer EOF before reply'
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
    result = subprocess.run(command('reconcile', root), input=(json.dumps({'linux':expected})+'\n').encode(), capture_output=True)
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
    assert process.wait() == 0
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
        while pathlib.Path('/proc',str(pid)).exists(): time.sleep(.01)
        assert not pathlib.Path('/proc',str(pid)).exists()
    raise ProcessLookupError('synthetic pidfd exit race')
m.os.pidfd_open=raced_open
m.reconcile(m.execution_root(sys.argv[2]))
'''
    for state in ('present','absent'):
        raced = subprocess.run(['/usr/bin/python3','-c',race_source,str(helper),str(root),state], input=(json.dumps(publication)+'\n').encode(), capture_output=True)
        assert (raced.returncode == 0) == (state == 'absent'), raced.stderr.decode()
        if state == 'present': assert module.identity(publication['linux']['outerPid']) == publication['linux'] and root.exists()
        else: assert not root.exists() and json.loads(raced.stdout)['initAbsent']
    process.stdin.close(); process.wait()
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
        while proc.exists(): time.sleep(.01)
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
    def esrch(arm, root, expected):
        return subprocess.run(['/usr/bin/python3','-c',esrch_source,str(helper),str(root),arm,str(expected['outerPid']),str(reaper_of(expected))], input=(json.dumps({'linux':expected})+'\n').encode(), capture_output=True)
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
    retained(esrch('bound-nokill', root, expected), root, expected, b'exact init absence unknown')
    retained(esrch('wait-present', root, expected), root, expected, b'synthetic ESRCH inside bounded wait')
    released(esrch('bound-kill', root, expected), root, expected)
    process.wait()
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
    process.wait()
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
    assert process.wait() != 0, 'midlaunch parent EOF must refuse'
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
    while not (root/'scratch/proof.json').exists() and process.poll() is None and not (root/'result.json').exists():
        time.sleep(.05)
    assert (root/'scratch/proof.json').exists(), 'payload missing: result terminal: ' + (root/'result.json').read_text() if (root/'result.json').exists() else f'payload missing: producer exited ({process.poll()})'
    proof = json.loads((root/'scratch/proof.json').read_text())
    assert proof['uid'] == proof['gid'] == 65534 and proof['groups'] == [], proof
    assert 'NoNewPrivs:\t1' in proof['status']
    assert set(proof['env']) <= {'PATH','HOME','LANG','TMPDIR','LC_CTYPE'}, proof['env']
    assert proof['mount'] != os.readlink('/proc/self/ns/mnt')
    assert proof['proc'] != os.readlink('/proc/self/ns/pid')
    while not (root/'scratch/grandchild').exists() and process.poll() is None and not (root/'result.json').exists():
        time.sleep(.025)
    assert (root/'scratch/grandchild').exists(), f'real double-fork/setsid grandchild missing: producer exit={process.poll()}, result terminal={(root/"result.json").exists()}'
    inner = int((root/'scratch/grandchild').read_text())
    members = []
    while not members and process.poll() is None and pathlib.Path('/proc',str(expected['outerPid'])).exists():
        for outer in pathlib.Path(f"/proc/{expected['outerPid']}/task/{expected['outerPid']}/children").read_text().split():
            observed = module.identity(int(outer))
            if observed['nspid'] == [int(outer), inner]: members.append(observed)
        if not members: time.sleep(.025)
    assert len(members)==1, f'exact reparented deepest grandchild identity: producer exit={process.poll()}, init absent={not pathlib.Path("/proc",str(expected["outerPid"])).exists()}'
    process.kill(); process.wait()
    assert module.identity(expected['outerPid']) == expected, 'helper death must not imply Linux init death'
    reconcile(root, expected)
    process.wait()
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
    while not (root/'scratch/proof.json').exists() and process.poll() is None and not (root/'result.json').exists():
        time.sleep(.025)
    assert (root/'scratch/proof.json').exists(), f'tuple bypass must violate the pre-ack no-payload assertion: producer exit={process.poll()}, result terminal={(root/"result.json").exists()}'
    process.kill(); process.wait()
    reconcile(root, publication['linux'])
    helper.write_text(text)
    print('PASS tuple-gate bypass discrimination: same request, runner, tools and environment; only init acknowledgement gate removed; inert payload entered before acknowledgement', flush=True)
finally:
    for process in processes:
        if process.stdin and not process.stdin.closed: process.stdin.close()
    for root, expected in tuples.items():
        if root.exists() or pathlib.Path('/proc',str(expected['outerPid'])).exists():
            reconcile(root, expected)
    for process in processes:
        if process.poll() is None:
            process.wait()
    assert all(not root.exists() for root in roots), 'owned execution roots remain'
    assert fixture.resolve().parent == parent and fixture.name.startswith('native-db-component-')
    shutil.rmtree(fixture)
    print('PASS copied native fixture cleanup: all owned processes exited; exact fixture root absent', flush=True)
'@
  if ($Control -cne 'claimant-pause-injection') {
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = 'C:\Windows\System32\wsl.exe'; $start.UseShellExecute = $false; $start.CreateNoWindow = $true
  $start.RedirectStandardInput = $true; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
  $start.Environment['WSLENV'] = ''
  foreach ($argument in @('-d','Ubuntu','--exec','/usr/bin/env','-i','PATH=/usr/bin:/bin','LANG=C','/usr/bin/python3','-',$linuxHelper)) { $start.ArgumentList.Add($argument) }
  $process = [Diagnostics.Process]::Start($start)
  $output = $process.StandardOutput.ReadToEndAsync(); $errors = $process.StandardError.ReadToEndAsync()
  $process.StandardInput.WriteLine($fixture); $process.StandardInput.Close()
  [void]$process.WaitForExit()
  Write-Output $output.GetAwaiter().GetResult()
  Write-Output $errors.GetAwaiter().GetResult()
  if ($process.ExitCode -ne 0) { throw "native copied-runtime qualification failed: $($process.ExitCode)" }
  }
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
    [void]$Entry.process.WaitForExit()
    $text=$Entry.out.GetAwaiter().GetResult()+$Entry.err.GetAwaiter().GetResult()
    if ($Entry.process.ExitCode -ne $Exit) { throw "native fixture expected $Exit got $($Entry.process.ExitCode): $text" }
    return $text
  }
  function Wait-NativeOwner([int]$Schema, [string]$LockName = 'verify-lock.d', [hashtable]$Producer) {
    $path=Join-Path $runtime "$LockName/owner.json"
    while ($true) {
      if (Test-Path $path) {
        try {
          $stream=[IO.File]::Open($path,'Open','Read',([IO.FileShare]::ReadWrite-bor[IO.FileShare]::Delete))
          try {
            $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$true)
            try { $raw=$reader.ReadToEnd() } finally { $reader.Dispose() }
          } finally { $stream.Dispose() }
          $record=$raw | ConvertFrom-Json -DateKind String
          if ($record.schemaVersion -eq $Schema -and $record.state -ceq 'started' -and ($Schema -ne 6 -or $record.native.linux)) { return $record }
        } catch {}
      }
      if ($Producer -and $Producer.process.HasExited) { throw "native fixture producer exited before owner publication: $($Producer.process.ExitCode)" }
      Start-Sleep -Milliseconds 50
    }
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
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'dispatch-ownership.ps1') -Destination $runtime
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
    if ($Control -cne 'claimant-pause-injection') {
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
    $record = Select-NativeReply $reply $request.correlation 'refused'
    if ($record.status -cne 'refused' -or -not $record.owner -or -not $record.evidencePath) { throw 'native missing runner lacks typed refusal/evidence' }
    $evidence=Get-Content -LiteralPath $record.evidencePath -Raw | ConvertFrom-Json -DateKind String
    if (-not $evidence.cleanup.initAbsent -or -not $evidence.cleanup.rootAbsent -or $evidence.releasedUtc -notmatch 'T.*Z$') { throw 'native evidence lacks actual release and independent cleanup proof' }
    if (Test-Path (Join-Path $runtime 'verify-lock.d')) { throw 'native missing runner retained owner despite exact cleanup' }
    Write-Output 'PASS copied wrapper: real Windows schema6 publication, real Linux missing-runner refusal, guarded-root release, unchanged product slot'
    $replay=Start-NativeFixture @('-NativeDbProfile','reconciliation-pg16/v1','-NativeRequestPath',$requestPath)
    $replayText=Complete-NativeFixture $replay 73
    if ($replayText -notmatch 'correlation already consumed' -or (Test-Path (Join-Path $runtime 'verify-lock.d'))) { throw 'duplicate correlation must refuse before acquisition' }
    }
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
runner.write_text("import pathlib,os,time\nr=pathlib.Path(os.environ['HOME'])\n(r/'ready').write_text('inert')\nwhile not (r/'release').exists() and not pathlib.Path("+repr(str(root/'release'))+").exists(): time.sleep(.025)\n")
pathlib.Path(str(runner)+'.sha256').write_text(hashlib.sha256(runner.read_bytes()).hexdigest())
'@
    & C:\Windows\System32\wsl.exe -d Ubuntu --exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=C /usr/bin/python3 -c $inertSetup $linuxRoot
    if ($LASTEXITCODE -ne 0) { throw 'inert copied runner setup failed' }
    $copy=$copy.Replace('/srv/chase-sets-native-db-input/', "$linuxRoot/inputs/")
    [IO.File]::WriteAllText((Join-Path $runtime 'invoke-heavy-verifier.ps1'),$copy)
    $request.stagedInputDirectory="$linuxRoot/inputs/synthetic"; $request.correlation=2
    [IO.File]::WriteAllText($requestPath,($request | ConvertTo-Json -Depth 12 -Compress))
    $readyPython=@'
import json,pathlib,sys,time
root=pathlib.Path(sys.argv[1]); assert root.parent==pathlib.Path('/srv/chase-sets-pg-probe') and root.name.startswith('native-db-') and root.resolve()==root
pid=json.loads((root/'linux.json').read_text())['outerPid']
while not (root/'scratch/ready').exists() and pathlib.Path('/proc',str(pid)).exists() and not (root/'result.json').exists(): time.sleep(.025)
assert (root/'scratch/ready').exists(), 'inert payload did not enter: init absent or result terminal'
'@
    if ($Control -ceq 'claimant-pause-injection') {
      $kind=$env:HHV_PAUSE_KIND; $site=$env:HHV_PAUSE_SITE; $variant=$env:HHV_PAUSE_VARIANT
      Assert-Harness ($kind -cin @('ordinary-started','native-started','native-tuple') -and $site -cin @('Read-FixtureOwner','Wait-NativeOwner') -and $variant -cin @('candidate','share-read-mutant')) 'full claimant control has explicit case identity'
      $pending=Join-Path $artifacts 'publication-pending'; $publicationRelease=Join-Path $artifacts 'publication-release'; $done=Join-Path $artifacts 'publication-done'
      $predicate=switch ($kind) {
        ordinary-started { '$Record.schemaVersion -eq 4 -and $Record.state -ceq "started"' }
        native-started { '$Record.schemaVersion -eq 6 -and $Record.state -ceq "started" -and -not $Record.native.linux' }
        native-tuple { '$Record.schemaVersion -eq 6 -and $Record.state -ceq "started" -and $Record.native.linux' }
      }
      $publication='[ChaseSets.HeavyAdmission.OwnerRename]::Publish($temporaryPath, $ownerPath, $destination)'
      Assert-Harness ($copy.Split($publication).Count -eq 2) 'full claimant pause has one exact publication anchor'
      $hook="if ($predicate) { [IO.File]::WriteAllText('$pending',`$raw); while (-not [IO.File]::Exists('$publicationRelease')) { Start-Sleep -Milliseconds 10 }; try { $publication; [IO.File]::WriteAllText('$done','published') } catch { [IO.File]::WriteAllText('$done','failed'); throw } } else { $publication }"
      [IO.File]::WriteAllText((Join-Path $runtime 'invoke-heavy-verifier.ps1'),$copy.Replace($publication,$hook))
      $mode=if ($kind -ceq 'ordinary-started') { @('-Gate','verify:static') } else { $nativeMode }
      $claimant=Start-NativeFixture $mode
      try {
        Wait-FixtureSignal $pending $claimant.process 'full claimant publication pause'
        $attempt=Get-Content $pending -Raw | ConvertFrom-Json -DateKind String
        $reader=Get-FixtureDefinition ([IO.File]::ReadAllText($PSCommandPath)) $site
        if ($site -ceq 'Wait-NativeOwner') {
          $begin=$reader.IndexOf('$stream='); $end=$reader.IndexOf("`n          if (`$record.schemaVersion",$begin)
          $reader='param($OwnerPath)' + "`n" + '$path=$OwnerPath;' + $reader.Substring($begin,$end-$begin) + '; return $raw'
        }
        $openLine=@($reader -split "`n" | Where-Object { $_.Contains('$stream=[IO.File]::Open(') })[0]
        Assert-Harness ([bool]$openLine) "$site full claimant snapshot has one open"
        $reader=$reader.Replace($openLine,$openLine+"`n [IO.File]::WriteAllText('$publicationRelease','release'); Wait-FixtureSignal '$done' `$claimant.process 'held-handle publication'")
        if ($variant -ceq 'share-read-mutant') { $reader=$reader.Replace('([IO.FileShare]::ReadWrite-bor[IO.FileShare]::Delete)','[IO.FileShare]::Read') }
        if ($site -ceq 'Read-FixtureOwner') {
          & { . ([scriptblock]::Create($reader)); Read-FixtureOwner (Join-Path $runtime 'verify-lock.d/owner.json') } | Out-Null
        } else { & ([scriptblock]::Create($reader)) (Join-Path $runtime 'verify-lock.d/owner.json') | Out-Null }
        $failure=$null
        try { Assert-Harness ((Get-Content $done -Raw) -ceq 'published') "$site $kind full claimant publishes while the snapshot handle is held" } catch { $failure=$_.Exception.Message }
        if ($variant -ceq 'share-read-mutant') {
          Assert-Harness ($failure -ceq "ASSERTION FAILED: $site $kind full claimant publishes while the snapshot handle is held") 'full claimant observer mutant dies at its publication assertion'
          Write-Output "MUTANT_RED full-claimant/$kind/$site $failure"
        } else {
          if ($failure) { throw $failure }
          $schema=if ($kind -ceq 'ordinary-started') { 4 } else { 6 }
          $observed=Wait-NativeOwner $schema -Producer $claimant
          Assert-Harness ($observed.childPid -eq $attempt.childPid -and $observed.state -ceq 'started') "$kind full claimant publishes the exact started child"
          if ($schema -eq 6) {
            Assert-Harness ([bool]$observed.native.linux) "$kind full claimant publishes its Linux tuple"
            $nativeOwner=$observed
            & C:\Windows\System32\wsl.exe -d Ubuntu --exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=C /usr/bin/python3 -c $readyPython $observed.native.root
            Assert-Harness ($LASTEXITCODE -eq 0) "$kind full claimant enters inert payload after tuple publication"
          } else { Wait-FixtureSignal (Join-Path $artifacts 'static-body') $claimant.process 'full ordinary claimant body' }
        }
      } finally {
        [IO.File]::WriteAllText($publicationRelease,'release')
        [IO.File]::WriteAllText((Join-Path $artifacts 'static-release'),'release')
        $release="import pathlib,sys; r=pathlib.Path(sys.argv[1]); assert r.resolve()==r and r.parent==pathlib.Path('/srv/chase-sets-pg-probe') and r.name.startswith('native-db-component-'); (r/'release').write_text('release')"
        & C:\Windows\System32\wsl.exe -d Ubuntu --exec /usr/bin/python3 -c $release $linuxRoot
        Assert-Harness ($LASTEXITCODE -eq 0) 'full claimant control releases its own inert runner'
        [void]$claimant.process.WaitForExit()
      }
      $text=$claimant.out.GetAwaiter().GetResult()+$claimant.err.GetAwaiter().GetResult()
      [IO.File]::WriteAllText((Join-Path $artifacts 'claimant.log'),$text)
      if ($variant -ceq 'candidate') {
        Assert-Harness ($claimant.process.ExitCode -eq 0) "$kind full claimant completes successfully: $text"
        if ($kind -cne 'ordinary-started') {
          $reply=Select-NativeReply ($text -split "`n") $request.correlation 'completed'
          $completion=Get-Content $reply.evidencePath -Raw | ConvertFrom-Json -DateKind String
          Assert-Harness ($reply.owner.lockId -ceq $observed.lockId -and $completion.owner.native.linux.outerPid -eq $observed.native.linux.outerPid -and $completion.cleanup.initAbsent -and $completion.cleanup.rootAbsent) "$kind completion is bound to the published Linux tuple and exact absence proof"
        }
        Assert-Harness (-not (Test-Path (Join-Path $runtime 'verify-lock.d'))) "$kind full claimant releases its private owner"
      } else {
        Assert-Harness ($claimant.process.ExitCode -ne 0) "$kind observer mutant refuses instead of silently accepting publication failure"
        if ($attempt.native.linux) {
          @{linux=$attempt.native.linux} | ConvertTo-Json -Compress -Depth 8 | & C:\Windows\System32\wsl.exe -d Ubuntu --exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=C /usr/bin/python3 "$linuxRoot/admission.py" reconcile $attempt.native.root
          Assert-Harness ($LASTEXITCODE -eq 0) 'full claimant mutant independently reconciles its exact unpublished tuple'
        }
      }
      $owned=Get-Process -Id $attempt.childPid -ErrorAction SilentlyContinue
      if ($owned -and $owned.StartTime.ToUniversalTime().Ticks -eq [DateTimeOffset]::Parse($attempt.childProcessStartUtc).UtcTicks) { [void]$owned.WaitForExit() }
      $live=Get-Process -Id $attempt.childPid -ErrorAction SilentlyContinue
      Assert-Harness (-not $live -or $live.StartTime.ToUniversalTime().Ticks -ne [DateTimeOffset]::Parse($attempt.childProcessStartUtc).UtcTicks) "$kind full claimant child identity is absent"
      Write-Output "CONTROL full-claimant GREEN kind=$kind site=$site variant=$variant wrapper=$($claimant.process.Id) child=$($attempt.childPid) exit=$($claimant.process.ExitCode)"
      return
    }
    $native=Start-NativeFixture @('-NativeDbProfile','reconciliation-pg16/v1','-NativeRequestPath',$requestPath)
    $nativeOwner=Wait-NativeOwner 6 -Producer $native
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
    [void](Wait-NativeOwner 4 -Producer $windows)
    while (-not (Test-Path (Join-Path $artifacts 'static-body'))) {
      if ($windows.process.HasExited) { throw "Windows Gate fixture producer exited before static-body signal: $($windows.process.ExitCode)" }
      Start-Sleep -Milliseconds 25
    }
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
      $bypassOwner=Wait-NativeOwner 6 'native-bypass-lock.d' $bypass
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
    $interruptedOwner=Wait-NativeOwner 6 -Producer $interrupted
    & C:\Windows\System32\wsl.exe -d Ubuntu --exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=C /usr/bin/python3 -c $readyPython $interruptedOwner.native.root
    if ($LASTEXITCODE -ne 0) { throw 'midpayload fixture did not enter payload' }
    $retainedRaw=Read-FixtureOwner (Join-Path $runtime 'verify-lock.d/owner.json')
    $interrupted.process.Kill(); [void]$interrupted.process.WaitForExit()
    $oldChild=Get-Process -Id $interruptedOwner.childPid -ErrorAction SilentlyContinue
    if ($oldChild) {
      if ($oldChild.StartTime.ToUniversalTime().Ticks -ne [DateTimeOffset]::Parse($interruptedOwner.childProcessStartUtc).Ticks) { throw 'interrupted child identity changed' }
      $oldChild.Kill(); [void]$oldChild.WaitForExit()
    }
    if ((Read-FixtureOwner (Join-Path $runtime 'verify-lock.d/owner.json')) -cne $retainedRaw) { throw 'Windows death changed owner bytes' }
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
    $resumedOwner=Wait-NativeOwner 6 -Producer $resumed
    while ($resumedOwner.lockId -ceq $interruptedOwner.lockId) {
      if ($resumed.process.HasExited) { throw "resumed claimant exited before publishing a new owner: $($resumed.process.ExitCode)" }
      Start-Sleep -Milliseconds 100; $resumedOwner=Wait-NativeOwner 6 -Producer $resumed
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
    $failedOwner=Wait-NativeOwner 6 -Producer $failed
    & C:\Windows\System32\wsl.exe -d Ubuntu --exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=C /usr/bin/python3 -c $readyPython $failedOwner.native.root
    if ($LASTEXITCODE -ne 0) { throw 'failure fixture body absent' }
    & C:\Windows\System32\wsl.exe -d Ubuntu --exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=C /usr/bin/python3 -c $releasePython $failedOwner.native.root
    $failedReply=Select-NativeReply ((Complete-NativeFixture $failed 1) -split "`n") $request.correlation 'completed'
    $failedEvidence=Get-Content $failedReply.evidencePath -Raw | ConvertFrom-Json -DateKind String
    if ($failedReply.status -cne 'completed' -or $failedEvidence.result.exit -ne 7 -or -not $failedEvidence.cleanup.rootAbsent) { throw 'payload failure must preserve exit, not import PASS, and still clean exactly' }
    Write-Output 'PASS inert payload failure: actual exit 7 retained, lifecycle completed is not PASS, wrapper exit 1 and exact cleanup'
    $request.correlation=7
    [IO.File]::WriteAllText($requestPath,($request | ConvertTo-Json -Depth 12 -Compress))
    $helperLost=Start-NativeFixture @('-NativeDbProfile','reconciliation-pg16/v1','-NativeRequestPath',$requestPath)
    $helperLostOwner=Wait-NativeOwner 6 -Producer $helperLost
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
    $pause="[IO.File]::WriteAllText('$precleanupMarker','paused'); while (-not [IO.File]::Exists('$precleanupMarker-release')) { Start-Sleep -Milliseconds 25 }"
    $pausedCopy=$copy.Replace('$script:nativeResult = $result', $pause+'; $script:nativeResult = $result')
    if ($pausedCopy -ceq $copy) { throw 'precleanup fixture pause did not apply' }
    [IO.File]::WriteAllText((Join-Path $runtime 'invoke-heavy-verifier.ps1'),$pausedCopy)
    $request.correlation=8
    [IO.File]::WriteAllText($requestPath,($request | ConvertTo-Json -Depth 12 -Compress))
    $precleanup=Start-NativeFixture @('-NativeDbProfile','reconciliation-pg16/v1','-NativeRequestPath',$requestPath)
    $precleanupOwner=Wait-NativeOwner 6 -Producer $precleanup
    & C:\Windows\System32\wsl.exe -d Ubuntu --exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=C /usr/bin/python3 -c $readyPython $precleanupOwner.native.root
    & C:\Windows\System32\wsl.exe -d Ubuntu --exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=C /usr/bin/python3 -c $releasePython $precleanupOwner.native.root
    while (-not (Test-Path $precleanupMarker)) {
      if ($precleanup.process.HasExited) { throw "precleanup producer exited before boundary signal: $($precleanup.process.ExitCode)" }
      Start-Sleep -Milliseconds 25
    }
    $precleanupRaw=Read-FixtureOwner (Join-Path $runtime 'verify-lock.d/owner.json')
    $precleanup.process.Kill(); [void]$precleanup.process.WaitForExit()
    if ((Read-FixtureOwner (Join-Path $runtime 'verify-lock.d/owner.json')) -cne $precleanupRaw) { throw 'precleanup wrapper death changed owner bytes' }
    [IO.File]::WriteAllText((Join-Path $runtime 'invoke-heavy-verifier.ps1'),$copy)
    $request.correlation=9
    [IO.File]::WriteAllText($requestPath,($request | ConvertTo-Json -Depth 12 -Compress))
    $next=Start-NativeFixture @('-NativeDbProfile','reconciliation-pg16/v1','-NativeRequestPath',$requestPath)
    $nextOwner=Wait-NativeOwner 6 -Producer $next
    while ($nextOwner.lockId -ceq $precleanupOwner.lockId) {
      if ($next.process.HasExited) { throw "next claimant exited before publishing a new owner: $($next.process.ExitCode)" }
      Start-Sleep -Milliseconds 100; $nextOwner=Wait-NativeOwner 6 -Producer $next
    }
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
    if ($precleanupMarker) { [IO.File]::WriteAllText("$precleanupMarker-release",'release') }
    $releaseFixture = "import pathlib,sys; root=pathlib.Path(sys.argv[1]); assert root.parent==pathlib.Path('/srv/chase-sets-pg-probe') and root.name.startswith('native-db-component-') and root.resolve()==root; (root/'release').write_text('release') if root.exists() else None"
    & C:\Windows\System32\wsl.exe -d Ubuntu --exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=C /usr/bin/python3 -c $releaseFixture $linuxRoot
    if ($LASTEXITCODE -ne 0) { throw 'native fixture release marker failed' }
    $releaseRoot = "import pathlib,sys; root=pathlib.Path(sys.argv[1]); assert root.parent==pathlib.Path('/srv/chase-sets-pg-probe') and root.name.startswith('native-db-') and root.resolve()==root; (root/'scratch/release').write_text('release') if (root/'scratch').exists() else None"
    foreach ($identity in $identities) {
      if ($identity.native.root) {
        & C:\Windows\System32\wsl.exe -d Ubuntu --exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=C /usr/bin/python3 -c $releaseRoot $identity.native.root
        if ($LASTEXITCODE -ne 0) { throw "owned synthetic native release signal failed: $($identity.native.root)" }
      }
    }
    foreach ($entry in $nativeChildren) {
      if (-not $entry.process.HasExited) { [void]$entry.process.WaitForExit() }
      if ($entry.process.HasExited) {
        [IO.File]::WriteAllText((Join-Path $artifacts "process-$($entry.process.Id).log"), $entry.out.GetAwaiter().GetResult()+$entry.err.GetAwaiter().GetResult())
      }
    }
    foreach ($fixtureLock in @('verify-lock.d','native-bypass-lock.d')) {
    $retainedPath=Join-Path $runtime "$fixtureLock/owner.json"
    if (Test-Path $retainedPath) {
      $retained=(Read-FixtureOwner $retainedPath) | ConvertFrom-Json -DateKind String
      if ($retained.schemaVersion -eq 6 -and $retained.native.linux) {
        $live=Get-Process -Id $retained.childPid -ErrorAction SilentlyContinue
        if ($live -and $live.StartTime.ToUniversalTime().Ticks -eq [DateTimeOffset]::Parse($retained.childProcessStartUtc).Ticks) { $live.Kill(); [void]$live.WaitForExit() }
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
function Invoke-CanonicalRecordScriptPinControl {
  $source = $PSScriptRoot
  $pwsh = (Get-Process -Id $PID).Path
  $expected = 'vitest run --config ./vitest.scripts.config.mjs scripts/canonical-record.test.mjs --maxWorkers=1 --fileParallelism=false --silent=false'
  $runCase = {
    param([string]$Name, [string]$HeadPackage, [string]$WorktreePackage = $null, [string]$GuardMutant = '')
    $root = Join-Path ([IO.Path]::GetTempPath()) ('canonical-record-pin-' + $Name + '-' + [guid]::NewGuid().ToString('N'))
    $runtime = Join-Path $root '.orchestrator'
    $worktree = Join-Path $root 'lane'
    $artifacts = Join-Path $worktree '.orchestrator/artifacts'
    $assumeUnchanged = $null -ne $WorktreePackage
    try {
      New-Item -ItemType Directory -Path $runtime, $worktree, $artifacts, (Join-Path $worktree 'node_modules/.bin') -Force | Out-Null
      foreach ($file in @('invoke-heavy-verifier.ps1', 'heavy-admission-preload.cjs', 'heavy-slot.cjs', 'heavy-nested-owner.cs', 'heavy-nested-client.cjs', 'heavy-admission-holder-launcher.cjs', 'dispatch-ownership.ps1')) {
        Copy-Item -LiteralPath (Join-Path $source $file) -Destination (Join-Path $runtime $file)
      }
      [IO.File]::WriteAllText((Join-Path $worktree '.gitignore'), ".orchestrator/artifacts/`nnode_modules/`npnpm-lock.yaml`n")
      [IO.File]::WriteAllText((Join-Path $worktree 'package.json'), $HeadPackage)
      [IO.File]::WriteAllText((Join-Path $worktree 'pnpm-lock.yaml'), "lockfileVersion: '9.0'`n")
      [IO.File]::WriteAllText((Join-Path $worktree 'node_modules/.bin/vitest.cmd'), "@echo off`r`nnode `"%~dp0vitest.cjs`" %*`r`n")
      [IO.File]::WriteAllText((Join-Path $worktree 'node_modules/.bin/vitest.cjs'), "require('node:fs').writeFileSync(process.env.CANONICAL_RECORD_BODY, process.argv.slice(2).join(' '));")
      & git -C $worktree init -b synthetic-canonical --quiet | Out-Null
      & git -C $worktree -c user.name=Synthetic -c user.email=synthetic@example.invalid add package.json .gitignore | Out-Null
      & git -C $worktree -c user.name=Synthetic -c user.email=synthetic@example.invalid commit -m synthetic --quiet | Out-Null
      $head = (& git -C $worktree rev-parse HEAD).Trim()
      & git -C $worktree checkout --detach $head --quiet | Out-Null
      if ($WorktreePackage) {
        [IO.File]::WriteAllText((Join-Path $worktree 'package.json'), $WorktreePackage)
        & git -C $worktree update-index --assume-unchanged package.json | Out-Null
      }
      $guard = [IO.File]::ReadAllText((Join-Path $source 'invoke-heavy-verifier.ps1'))
      if ($GuardMutant -ceq 'worktree-package') {
        $old = '$packageLines = @(& git -C $worktreeFull cat-file blob $objectName 2>$null)'
        $new = '$packageLines = @([IO.File]::ReadAllText((Join-Path $worktreeFull ''package.json'')))'
        Assert-Harness ($guard.Contains($old)) 'canonical-record worktree mutant has one exact HEAD read anchor'
        $guard = $guard.Replace($old, $new)
      }
      if ($GuardMutant -ceq 'pnpm-run') {
        $old = "elseif (`$Gate -ceq 'test:canonical-record') { Get-CanonicalRecordPinnedLaunch }"
        $new = "elseif (`$Gate -ceq 'test:canonical-record') { @(`$pnpmScript, 'run', `$Gate) }"
        Assert-Harness ($guard.Contains($old)) 'canonical-record pnpm-run mutant has one exact pinned launch anchor'
        $guard = $guard.Replace($old, $new)
      }
      if ($GuardMutant -ceq 'receipt-script-body') {
        $old = "            `$receipt.Add('scriptBody', `$canonicalRecordScriptExpected)"
        Assert-Harness ($guard.Contains($old)) 'canonical-record receipt mutant has one exact script-body anchor'
        $guard = $guard.Replace($old, "            # MUTANT receipt script body omitted")
      }
      [IO.File]::WriteAllText((Join-Path $runtime 'invoke-heavy-verifier.ps1'), $guard)
      $marker = Join-Path $artifacts 'canonical-record-body.txt'
      $arguments = @('-NoProfile', '-File', (Join-Path $runtime 'invoke-heavy-verifier.ps1'), '-Gate', 'test:canonical-record', '-Worktree', $worktree, '-Lane', 'canonical-pin', '-ImmutableHead', $head, '-ContainerRoot', $root)
      $env:CANONICAL_RECORD_BODY = $marker
      $output = @(& $pwsh @arguments 2>&1)
      $exit = $LASTEXITCODE
      $receiptFiles = @(Get-ChildItem -LiteralPath $artifacts -Filter 'host-heavy-verifier-*.json' -File -ErrorAction SilentlyContinue)
      $receipt = if ($receiptFiles.Count -eq 1) { Get-Content -LiteralPath $receiptFiles[0].FullName -Raw | ConvertFrom-Json -DateKind String } else { $null }
      return [pscustomobject]@{ Name = $Name; Exit = $exit; Output = ($output -join "`n"); Receipt = $receipt; Body = if (Test-Path -LiteralPath $marker) { Get-Content -LiteralPath $marker -Raw } else { $null } }
    } finally {
      if ($assumeUnchanged) { & git -C $worktree update-index --no-assume-unchanged package.json 2>$null | Out-Null }
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
  $exact = [ordered]@{ name = 'synthetic-canonical'; private = $true; scripts = [ordered]@{ 'test:canonical-record' = $expected } } | ConvertTo-Json -Compress
  $missing = [ordered]@{ name = 'synthetic-canonical'; private = $true; scripts = [ordered]@{} } | ConvertTo-Json -Compress
  $oneByteDifferent = $expected.Replace('silent=false', 'silent=falsE')
  $changed = [ordered]@{ name = 'synthetic-canonical'; private = $true; scripts = [ordered]@{ 'test:canonical-record' = $oneByteDifferent } } | ConvertTo-Json -Compress

  $control = & $runCase 'control' $exact
  Assert-Harness ($control.Exit -eq 0 -and $control.Body -eq 'run --config ./vitest.scripts.config.mjs scripts/canonical-record.test.mjs --maxWorkers=1 --fileParallelism=false --silent=false' -and
    $control.Receipt -and $control.Receipt.gate -ceq 'test:canonical-record' -and $control.Receipt.head -match '^[a-f0-9]{40}$' -and
    $control.Receipt.owner -and $control.Receipt.exit -eq 0 -and $control.Receipt.scriptBody -ceq $expected -and
    $control.Receipt.scriptBodySource -ceq 'HEAD:package.json' -and $control.Receipt.scriptPin.status -ceq 'accepted' -and
    $control.Receipt.scriptLaunch -and $control.Receipt.scriptLaunch.arguments[1] -ceq 'exec' -and
    (@($control.Receipt.scriptLaunch.arguments | Select-Object -Skip 2) -join ' ') -ceq $expected) 'canonical-record exact script control launches the pinned body with pnpm exec and records the exact argv'
  Write-Output 'PASS canonical-record control exit=0 pnpm-exec=1 body=1 receipt-script-pin=1'

  $missingResult = & $runCase 'missing' $missing
  Assert-Harness ($missingResult.Exit -eq 73 -and $null -eq $missingResult.Body -and $missingResult.Receipt -and
    $missingResult.Receipt.exit -eq 73 -and $missingResult.Receipt.scriptBody -ceq $expected -and
    $missingResult.Receipt.scriptPin.status -ceq 'refused' -and $missingResult.Output -match 'script pin refusal') 'missing script control refuses before the body and records classified refusal'
  Write-Output 'PASS canonical-record missing-script exit=73 body=0 receipt=1'

  $oneByteResult = & $runCase 'one-byte' $changed
  Assert-Harness ($oneByteResult.Exit -eq 73 -and $null -eq $oneByteResult.Body -and $oneByteResult.Receipt.scriptBody -ceq $expected -and
    $oneByteResult.Receipt.scriptPin.status -ceq 'refused') 'one-byte script mutant goes red before the product body'
  Write-Output 'MUTANT_RED canonical-record one-byte-script-change exit=73 body=0'

  $worktreeResult = & $runCase 'worktree-edit' $exact $changed
  Assert-Harness ($worktreeResult.Exit -eq 0 -and $worktreeResult.Body -eq 'run --config ./vitest.scripts.config.mjs scripts/canonical-record.test.mjs --maxWorkers=1 --fileParallelism=false --silent=false' -and
    $worktreeResult.Receipt.scriptBody -ceq $expected -and $worktreeResult.Receipt.scriptBodyObserved -ceq $expected -and
    $worktreeResult.Receipt.scriptLaunch -and $worktreeResult.Receipt.scriptLaunch.arguments[1] -ceq 'exec' -and
    (@($worktreeResult.Receipt.scriptLaunch.arguments | Select-Object -Skip 2) -join ' ') -ceq $expected) 'changed worktree control executes the exact HEAD-pinned body and argv'
  $worktreeLaunchMutant = & $runCase 'worktree-launch-mutant' $exact $changed 'pnpm-run'
  Assert-Harness ($worktreeLaunchMutant.Exit -eq 0 -and $worktreeLaunchMutant.Body -and $worktreeLaunchMutant.Body -cne 'run --config ./vitest.scripts.config.mjs scripts/canonical-record.test.mjs --maxWorkers=1 --fileParallelism=false --silent=false') 'pnpm-run mutant executes the changed worktree body and goes red'
  $worktreeMutant = & $runCase 'worktree-source-mutant' $missing $exact 'worktree-package'
  Assert-Harness ($worktreeMutant.Exit -eq 0 -and $worktreeMutant.Body) 'worktree-read mutant is observable as an incorrect admission'
  Assert-Harness ($worktreeResult.Receipt.scriptBodySource -ceq 'HEAD:package.json' -and $worktreeMutant.Receipt.scriptPin.status -ceq 'accepted') 'worktree source mutant is distinguished from the HEAD pin control'
  Write-Output 'MUTANT_RED canonical-record-pnpm-run body=1 changed-worktree-body=1'
  Write-Output 'MUTANT_RED canonical-record-worktree-read exit=0 body=1 where HEAD control refuses'

  $receiptMutant = & $runCase 'receipt-script-body-mutant' $exact $null 'receipt-script-body'
  Assert-Harness ($receiptMutant.Exit -eq 0 -and $null -eq $receiptMutant.Receipt.scriptBody) 'receipt missing script body mutant goes red'
  Assert-Harness ($control.Receipt.scriptBody -ceq $expected) 'receipt control retains the pinned script body'
  Write-Output 'MUTANT_RED canonical-record-receipt-script-body exit=0 missing-scriptBody=1'
}
if (-not $Baseline -and -not $Control) { & $PSCommandPath -NativeDbOnly }
if ($Control -ceq 'canonical-record-script-pin') { Invoke-CanonicalRecordScriptPinControl; exit 0 }
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
  [void]$Entry.Process.WaitForExit()
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
if (process.env.HOST_READY_LATENCY_INJECTION === '1') {
  fs.writeFileSync(path.join(out, 'ready-delay-started'), 'started');
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 40000);
}
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
  $run = Start-Child $pwsh ($common + @('-Gate', 'verify:test-db')) @{HOST_WAIT='1';HOST_READY_LATENCY_INJECTION=$(if($Control -ceq 'host-ready-latency-injection'){'1'}else{'0'})}
  $ready = Join-Path $artifacts 'ready.json'
  Wait-FixtureSignal $ready $run.Process 'host body'
  $state = Get-Content $ready -Raw | ConvertFrom-Json
  if ($Control -ceq 'forced-failure-release') { throw 'INJECTED forced-failure-release' }
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
  Release-FixtureChildren $artifacts $children
  $census = [Collections.Generic.List[object]]::new()
  foreach ($entry in $children) {
    if (-not $entry.Process.HasExited) {
      [void]$entry.Process.WaitForExit()
    }
    $census.Add(@{pid=$entry.Process.Id;start=$entry.Start;exited=$entry.Process.HasExited})
    if (Test-Path $artifacts) {
      [IO.File]::WriteAllText((Join-Path $artifacts "process-$($entry.Process.Id).log"), $entry.Out.GetAwaiter().GetResult()+$entry.Err.GetAwaiter().GetResult())
    }
  }
  # Receipts and the ready record bind transitive roots to the launches above.
  $rootIdentities=@()
  if (Test-Path (Join-Path $artifacts 'ready.json')) {
    $readyOwner=(Get-Content (Join-Path $artifacts 'ready.json') -Raw|ConvertFrom-Json -DateKind String).owner
    $rootIdentities+=@{pid=$readyOwner.childPid;start=[DateTimeOffset]::Parse($readyOwner.childProcessStartUtc).UtcTicks}
  }
  foreach ($receiptFile in @(Get-ChildItem $artifacts -Filter 'host-heavy-verifier-*.json' -ErrorAction SilentlyContinue)) {
    $rootIdentity=(Get-Content $receiptFile.FullName -Raw|ConvertFrom-Json -DateKind String).root
    $rootIdentities+=@{pid=$rootIdentity.pid;start=[DateTimeOffset]::Parse($rootIdentity.processStartUtc).UtcTicks}
  }
  foreach ($identity in $rootIdentities) {
    $owned=Get-Process -Id $identity.pid -ErrorAction SilentlyContinue
    if ($owned -and $owned.StartTime.ToUniversalTime().Ticks -eq $identity.start) { [void]$owned.WaitForExit() }
    $live=Get-Process -Id $identity.pid -ErrorAction SilentlyContinue
    $census.Add(@{pid=$identity.pid;start=$identity.start;exited=(-not $live -or $live.StartTime.ToUniversalTime().Ticks -ne $identity.start)})
  }
  if (Test-Path $artifacts) {
    [IO.File]::WriteAllText((Join-Path $artifacts 'owned-process-census.json'), ($census | ConvertTo-Json -Depth 8))
  }
  # Evidence is retained for the governing reviewer, including baseline refusal.
  Write-Output "FIXTURE $root"
}
