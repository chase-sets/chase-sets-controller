[CmdletBinding()]
param(
  [string]$GuardRevision = '',
  [ValidateSet('All', 'Order', 'Lifecycle', 'Integrity', 'Recovery')][string]$Section = 'All',
  [ValidateSet('Both', 'Gate', 'Attach')][string]$AdmissionModes = 'Both',
  [ValidateSet('', 'bypass-fifo', 'skip-absent-head', 'renumber-on-retry', 'prune-live', 'never-expire',
    'reset-without-authority', 'quarantine-early', 'ignore-marker', 'rename-completes', 'owner-schema-drift')][string]$Mutant = ''
)
$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('heavy-fifo-9590-' + [guid]::NewGuid().ToString('N'))
$runtime = Join-Path $root '.orchestrator'
$tree = Join-Path $root 'candidate'
$guard = Join-Path $runtime 'invoke-heavy-verifier.ps1'
$queue = Join-Path $runtime 'verify-queue.json'
$lock = Join-Path $runtime 'verify-lock.d'
$ownerPath = Join-Path $lock 'owner.json'
$sessions = [Collections.Generic.List[object]]::new()
$script:checks = 0
function Assert-Fifo($Value, [string]$Name) {
  if (-not $Value) { throw "ASSERTION FAILED: $Name" }
  $script:checks++
  [Console]::WriteLine("PASS $Name")
}
function Git-Fixture([string[]]$Arguments) {
  $out = @(& git -C $tree @Arguments 2>&1)
  if ($LASTEXITCODE -ne 0) { throw "fixture git failed: $($out -join ' ')" }
  return ($out -join "`n").Trim()
}
function Start-Session([string]$Name) {
  $start = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
  $start.UseShellExecute = $false; $start.CreateNoWindow = $true
  $start.RedirectStandardInput = $true; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
  foreach ($arg in @('-NoProfile', '-NonInteractive', '-File', (Join-Path $root 'parent.ps1'))) { $start.ArgumentList.Add($arg) }
  $p = [Diagnostics.Process]::Start($start)
  $errors = $p.StandardError.ReadToEndAsync()
  Assert-Fifo ($p.StandardOutput.ReadLine() -ceq 'READY') "fixture parent ready $Name"
  $session = @{ Process = $p; Errors = $errors; Name = $Name }
  $sessions.Add($session)
  return $session
}
function Invoke-Fifo($Session, [string]$Mode = 'Gate', [hashtable]$Extra = @{}, [hashtable]$Environment = @{}) {
  $marker = Join-Path $root ($Session.Name + '.marker')
  [IO.File]::Delete($marker)
  $parameters = @{ Worktree = $tree; Lane = $Session.Name; Branch = 'synthetic/fifo';
    ClaimedHead = Git-Fixture @('rev-parse', 'HEAD'); ContainerRoot = $root }
  if ($Mode -ceq 'Gate') {
    $parameters.Gate = 'verify:static'; $parameters.CommandPath = Join-Path $PSHOME 'pwsh.exe'
    $parameters.CommandArgumentList = @('-NoProfile', '-File', (Join-Path $root 'body.ps1'), $marker)
  } elseif ($Mode -ceq 'Attach') {
    $parameters.AdmissionKind = 'repository-gate'; $parameters.AdmissionCommand = 'synthetic inert root'
    $parameters.AdmissionNonce = [guid]::NewGuid().ToString('N')
  } elseif ($Mode -ceq 'Recovery') { $parameters.QuarantineQueue = $Extra.QuarantineQueue }
  foreach ($key in $Extra.Keys) { $parameters[$key] = $Extra[$key] }
  $request = @{ guard = $guard; parameters = $parameters; mode = $Mode; marker = $marker; root = $root; environment = $Environment }
  $Session.Process.StandardInput.WriteLine(($request | ConvertTo-Json -Compress -Depth 10))
  $line = $Session.Process.StandardOutput.ReadLine()
  if (-not $line) { throw "fixture parent exited: $($Session.Errors.Result)" }
  $reply = $line | ConvertFrom-Json
  $reply | Add-Member body ([IO.File]::Exists($marker))
  return $reply
}
function Set-Barrier {
  [void][IO.Directory]::CreateDirectory($lock)
  $value = [ordered]@{ schemaVersion = 4; lockId = ('1' * 32); owner = 'synthetic'; lane = 'barrier';
    branch = 'synthetic/fifo'; worktree = $tree; head = Git-Fixture @('rev-parse', 'HEAD'); identityMode = 'branch';
    pid = $PID; processStartUtc = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o');
    startedUtc = [DateTime]::UtcNow.ToString('o'); gate = 'verify:static'; commandIdentity = ('b' * 64);
    state = 'launching'; childPid = $null; childProcessStartUtc = $null }
  [IO.File]::WriteAllText($ownerPath, ($value | ConvertTo-Json -Compress))
}
function Release-Barrier {
  $value = [IO.File]::ReadAllText($ownerPath) | ConvertFrom-Json
  if ($value.lockId -cne ('1' * 32) -or $value.pid -ne $PID) { throw 'foreign fixture owner' }
  [IO.File]::Delete($ownerPath); [IO.Directory]::Delete($lock)
}
try {
  [void][IO.Directory]::CreateDirectory($runtime); [void][IO.Directory]::CreateDirectory($tree)
  foreach ($dependency in @('dispatch-ownership.ps1', 'heavy-nested-owner.cs', 'heavy-nested-client.cjs')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $dependency) -Destination $runtime
  }
  $source = if ($GuardRevision) {
    $lines = @(& git -C (Split-Path -Parent $PSScriptRoot) show "${GuardRevision}:.orchestrator/invoke-heavy-verifier.ps1")
    if ($LASTEXITCODE -ne 0) { throw 'guard revision unavailable' }; $lines -join "`n"
  } else { [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'invoke-heavy-verifier.ps1')) }
  $mutations = @{
    'bypass-fifo' = @('if ($position -ne 1)', 'if ($false)')
    'skip-absent-head' = @('if ($position -ne 1)', 'if ($position -ne 1 -and -not $reserved)')
    'renumber-on-retry' = @('$mine = @($q.claims | Where-Object key -CEQ $claimant.key)', '$q.claims = @($q.claims | Where-Object key -CNE $claimant.key); $mine = @()')
    'prune-live' = @("if (`$state -cin @('dead', 'reused'))", 'if ($true)')
    'never-expire' = @('if ($age -gt 600)', 'if ($false)')
    'reset-without-authority' = @('throw (Format-ProductQueueFault $snapshot)', '[IO.File]::Delete($queuePath); return New-ProductQueueSnapshot')
    'quarantine-early' = @('if ($elapsed -le 600)', 'if ($false)')
    'ignore-marker' = @('if (Test-Path -LiteralPath $queueRecoveryPath)', 'if ($false)')
    'rename-completes' = @('# QUEUE_RECOVERY_MOVED', '[IO.File]::Delete($queueRecoveryPath); return $marker.record # QUEUE_RECOVERY_MOVED')
    'owner-schema-drift' = @('$expected = if ($Record.schemaVersion -eq 1)', '$expected = if ($Record.schemaVersion -eq 0)')
  }
  if ($Mutant) {
    $pair = $mutations[$Mutant]
    Assert-Fifo ($source.Contains($pair[0])) "mutant anchor $Mutant"
    $source = $source.Replace($pair[0], $pair[1])
  }
  [IO.File]::WriteAllText($guard, $source)
  [IO.File]::WriteAllText((Join-Path $root 'body.ps1'), 'param($Marker); [IO.File]::AppendAllText($Marker,"inert`n")')
  [IO.File]::WriteAllText((Join-Path $root 'attached.ps1'), @'
param($Reply,$Marker)
while(-not [IO.File]::Exists($Reply)){Start-Sleep -Milliseconds 25}
$r=[IO.File]::ReadAllText($Reply)|ConvertFrom-Json
if($r.accepted){[IO.File]::AppendAllText($Marker,"inert`n")}
'@)
  [IO.File]::WriteAllText((Join-Path $root 'parent.ps1'), @'
$ErrorActionPreference='Stop'
function Start-Child($Arguments,$Environment=@{}){
  $s=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
  $s.UseShellExecute=$false;$s.CreateNoWindow=$true;$s.RedirectStandardOutput=$true;$s.RedirectStandardError=$true
  foreach($a in $Arguments){$s.ArgumentList.Add([string]$a)}
  foreach($key in $Environment.Keys){$s.Environment[$key]=[string]$Environment[$key]}
  return [Diagnostics.Process]::Start($s)
}
[Console]::WriteLine('READY')
while($line=[Console]::ReadLine()){
  $r=$line|ConvertFrom-Json -AsHashtable -DateKind String
  $inputPath=Join-Path $r.root ([guid]::NewGuid().ToString('N')+'.json')
  $attached=$null
  if($r.mode-ceq'Attach'){
    $replyRoot=Join-Path ([IO.Path]::GetTempPath()) ('chase-sets-heavy-admission-'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($replyRoot)
    $reply=Join-Path $replyRoot 'reply.json'
    $attached=Start-Child @('-NoProfile','-File',(Join-Path $r.root 'attached.ps1'),$reply,$r.marker)
    $r.parameters.GuardedPid=$attached.Id
    $r.parameters.GuardedProcessStartUtc=$attached.StartTime.ToUniversalTime().ToString('o')
    $r.parameters.AdmissionResultPath=$reply
  }
  [IO.File]::WriteAllText($inputPath,($r.parameters|ConvertTo-Json -Depth 10))
  $runner=Join-Path $r.root 'wrapper.ps1'
  $p=Start-Child @('-NoProfile','-File',$runner,$r.guard,$inputPath) $r.environment
  $out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync()
  $p.WaitForExit()
  if($attached){$attached.WaitForExit();$attached.Dispose()}
  [Console]::WriteLine((@{code=$p.ExitCode;text=$out.Result+$err.Result}|ConvertTo-Json -Compress))
  $p.Dispose();[IO.File]::Delete($inputPath)
}
'@)
  [IO.File]::WriteAllText((Join-Path $root 'wrapper.ps1'), 'param($Guard,$InputPath); $p=[IO.File]::ReadAllText($InputPath)|ConvertFrom-Json -AsHashtable -DateKind String; & $Guard @p; exit $LASTEXITCODE')
  Git-Fixture @('init', '-q', '-b', 'synthetic/fifo') | Out-Null
  [IO.File]::WriteAllText((Join-Path $tree 'fixture.txt'), 'synthetic')
  Git-Fixture @('add', '.') | Out-Null
  Git-Fixture @('-c', 'user.name=Synthetic', '-c', 'user.email=synthetic@example.invalid', 'commit', '-qm', 'fixture') | Out-Null
  $a = Start-Session A; $b = Start-Session B; $c = Start-Session C
  if ($Section -cin @('All', 'Order') -and $Mutant -cnotin @('prune-live', 'never-expire', 'reset-without-authority', 'quarantine-early', 'ignore-marker', 'rename-completes')) {
  $modes = if ($AdmissionModes -ceq 'Both') { @('Gate', 'Attach') } else { @($AdmissionModes) }
  foreach ($mode in $modes) {
    $control = Invoke-Fifo $a $mode
    Assert-Fifo ($control.code -eq 0 -and $control.body) "AC2 no-waiter control $mode exit=$($control.code) output=$($control.text)"
    Set-Barrier
    $raw = [IO.File]::ReadAllText($ownerPath)
    foreach ($s in @($a, $b, $c)) {
      $r = Invoke-Fifo $s $mode
      Assert-Fifo ($r.code -ne 0 -and -not $r.body -and [IO.File]::ReadAllText($ownerPath) -ceq $raw) "AC4 barrier preserves owner $mode $($s.Name)"
      if ($r.text -notmatch 'ticket=') { [Console]::WriteLine("DIAGNOSTIC $($r.text)") }
    }
    Release-Barrier
    foreach ($s in @($b, $c)) {
      $r = Invoke-Fifo $s $mode
      Assert-Fifo ($r.code -eq 73 -and -not $r.body -and $r.text -match 'ticket=\d+ position=[23].*reserved') "AC1 absent-head reservation $mode $($s.Name) exit=$($r.code) output=$($r.text)"
    }
    $before = [IO.File]::ReadAllText($queue) | ConvertFrom-Json
    $r = Invoke-Fifo $c $mode
    $after = [IO.File]::ReadAllText($queue) | ConvertFrom-Json
    Assert-Fifo ($r.code -eq 73 -and ($before.claims.ticket -join ',') -ceq ($after.claims.ticket -join ',')) "AC1 retry keeps number/order $mode"
    $r = Invoke-Fifo $a $mode
    Assert-Fifo ($r.code -eq 0 -and $r.body -and [IO.File]::ReadAllLines((Join-Path $root 'A.marker')).Count -eq 1) "AC1 earliest executes one marker $mode"
    $r = Invoke-Fifo $a $mode
    Assert-Fifo ($r.code -eq 73 -and -not $r.body) "AC2 immediate reclaimer behind waiters $mode"
    [IO.File]::AppendAllText((Join-Path $tree 'fixture.txt'), 'new head')
    Git-Fixture @('add', '.') | Out-Null
    Git-Fixture @('-c', 'user.name=Synthetic', '-c', 'user.email=synthetic@example.invalid', 'commit', '-qm', 'head change') | Out-Null
    $beforeHeadRetry = [IO.File]::ReadAllText($queue) | ConvertFrom-Json
    $changedCommand = if ($mode -ceq 'Gate') { @{ Gate = 'build' } } else { @{ AdmissionKind = 'build'; AdmissionCommand = 'synthetic inert continuation' } }
    $r = Invoke-Fifo $a $mode $changedCommand
    $afterHeadRetry = [IO.File]::ReadAllText($queue) | ConvertFrom-Json
    Assert-Fifo ($r.code -eq 73 -and -not $r.body -and
      ($beforeHeadRetry.claims.ticket -join ',') -ceq ($afterHeadRetry.claims.ticket -join ',')) "AC2 changed-command/head reclaimer retains position behind waiters $mode"
    foreach ($s in @($b, $c, $a)) { $r = Invoke-Fifo $s $mode; Assert-Fifo ($r.code -eq 0 -and $r.body) "AC3 wrapper exit retains claimant $mode $($s.Name)" }
  }
  # r17's repeated later arrivals must not win any of its 25 non-executions.
  Set-Barrier
  foreach ($s in @($a, $b, $c)) { Invoke-Fifo $s | Out-Null }
  Release-Barrier
  for ($i = 0; $i -lt 25; $i++) {
    $r = Invoke-Fifo $(if ($i % 2) { $b } else { $c })
    Assert-Fifo ($r.code -eq 73 -and -not $r.body -and -not (Test-Path $lock)) "AC1 r17 reversed presentation $i"
  }
  $r = Invoke-Fifo $a
  Assert-Fifo ($r.code -eq 0 -and $r.body) 'AC1 r17 established waiter wins next turnover'
  foreach ($s in @($b, $c)) { Invoke-Fifo $s | Out-Null }
  }
  if ($Section -ceq 'Order') { Write-Output "RESULT PASS checks=$script:checks"; return }
  if (-not (Test-Path -LiteralPath $queue)) { [IO.File]::WriteAllText($queue, '{"schemaVersion":1,"nextTicket":1,"claims":[]}') }

  $tokens = $null; $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($guard, [ref]$tokens, [ref]$errors)
  Assert-Fifo ($errors.Count -eq 0) 'candidate guard parses'
  $queueCalls = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Enter-ProductQueue' }, $true))
  $queueFence = if ($queueCalls.Count -eq 1) { $queueCalls[0].Parent } else { $null }
  while ($queueFence -and $queueFence -isnot [Management.Automation.Language.IfStatementAst]) { $queueFence = $queueFence.Parent }
  Assert-Fifo ($queueCalls.Count -eq 1 -and $queueFence -and $queueFence.Extent.Text.Contains('-not $isControllerBattery') -and
    $queueFence.Extent.Text.Contains('-not $isControllerPrecursor') -and
    $queueFence.Extent.Text.Contains('-not $env:CHASE_SETS_HEAVY_SLOT_ID') -and
    $queueFence.Extent.Text.Contains('-not $env:CHASE_SETS_HEAVY_SLOT_TRANSPORT')) 'AC4 controller, nested-owner and inherited-token isolation at sole queue call'
  # Committed LF-normalized AST hashes from the installed baseline also work
  # in the hosted battery's parentless controller snapshot.
  $ownerPins = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/heavy-owner-contract-4e36ef8a.json') -Raw | ConvertFrom-Json
  Assert-Fifo ($ownerPins.schemaVersion -eq 1 -and $ownerPins.baselineHead -ceq '4e36ef8aa627cad63f5163f619187eca1b7c069e') 'AC4 owner contract fixture baseline'
  foreach ($name in @('Test-OwnerShape', 'Write-OwnerRecord', 'Test-ReclaimableOwner', 'Test-PossibleOwnedChild', 'Release-ThisLock', 'Start-NestedOwner')) {
    $definitions = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name }, $false))
    Assert-Fifo ($definitions.Count -eq 1) "AC4 unique owner/descendant/nested contract $name"
    $after = $definitions[0].Extent.Text.Replace("`r`n", "`n")
    $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($after))).ToLowerInvariant()
    Assert-Fifo ($ownerPins.functions.$name -ceq $digest) "AC4 unchanged owner/descendant/nested contract $name"
  }
  foreach ($definition in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($definition.Extent.Text))
  }
  $now = [DateTime]::UtcNow
  $claim = [pscustomobject]@{ kind = 'parent'; launchId = $null; roots = @(
    [pscustomobject]@{ pid = 9971; start = $now.AddHours(-1).ToString('o') }); presentedUtc = $null }
  function Get-ProcessIdentityState($ProcessId, [string]$StartIdentity) { $script:identityProbes++; return $script:fixtureState }
  function Test-PossibleOwnedChild($Record) { $script:lastDescendantProbe = $Record; return $script:fixtureDescendant }
  $probeCountsValid = $true
  foreach ($state in @('dead', 'reused', 'live', 'ambiguous')) {
    foreach ($descendant in @($false, $null)) {
      foreach ($age in @(599, 601)) {
        $script:fixtureState = $state; $script:fixtureDescendant = $descendant
        $script:identityProbes = 0
        $claim.presentedUtc = $now.AddSeconds(-$age).ToString('o')
        $retained = Test-ProductTicketRetained $claim $now
        $expected = $age -le 600 -and -not ($state -cin @('dead', 'reused') -and $descendant -eq $false)
        $probeCountsValid = $probeCountsValid -and $script:identityProbes -eq $(if ($age -gt 600) { 0 } else { 1 })
        Assert-Fifo ($retained -eq $expected) "AC3 state=$state descendant=$descendant age=$age retained=$expected"
      }
    }
  }
  Assert-Fifo $probeCountsValid 'AC3 one identity probe per retained ticket; expiry needs no process probe'
  $launchClaim = @{ kind = 'launch'; presentedUtc = $now.ToString('o'); roots = @(
    @{ pid = 9911; start = $now.AddHours(-2).ToString('o') }, @{ pid = 9912; start = $now.AddHours(-1).ToString('o') }) }
  $script:fixtureState = 'dead'; $script:fixtureDescendant = $null; $script:identityProbes = 0
  Assert-Fifo ((Test-ProductTicketRetained $launchClaim $now) -and $script:identityProbes -eq 1 -and
    $script:lastDescendantProbe.pid -eq 9911 -and $script:lastDescendantProbe.childPid -eq 9912 -and
    $script:lastDescendantProbe.state -ceq 'started') 'AC3 launch claimant uses one probe and full launch descendant record; unknown retains'
  $script:fixtureState = 'live'
  $binding = @{ Record = @{ launchId = [guid]::NewGuid().ToString(); launcherPid = 9911; childPid = 9912;
    launcherStartIdentity = $now.AddHours(-2).ToString('o'); childStartIdentity = $now.AddHours(-1).ToString('o'); head = ('a' * 40) } }
  $first = Get-ProductClaimant $binding
  $binding.Record.head = 'b' * 40
  $second = Get-ProductClaimant $binding
  Assert-Fifo ($first.key -ceq $second.key) 'AC3 stable containing launch ignores head/command changes'
  $binding.Record.launchId = [guid]::NewGuid().ToString()
  Assert-Fifo ((Get-ProductClaimant $binding).key -cne $first.key) 'AC3 new containing launch never inherits'
  $parentClaim = @{ kind = 'parent'; launchId = $null; roots = @(@{ pid = 123; start = $now.AddHours(-1).ToString('o') }) }
  $parentKey = Get-ProductClaimKey $parentClaim
  $parentClaim.roots[0].start = $now.ToString('o')
  Assert-Fifo ((Get-ProductClaimKey $parentClaim) -cne $parentKey) 'AC3 reused standalone parent never inherits earlier identity'

  if ($Section -cin @('All', 'Lifecycle')) {
  # Expiry prunes stale interest only. A current absent head still reserves.
  $q = [IO.File]::ReadAllText($queue) | ConvertFrom-Json
  $stale = [pscustomobject]@{ ticket = $q.nextTicket; key = ''; kind = 'parent'; launchId = $null;
    roots = @([pscustomobject]@{ pid = $a.Process.Id; start = $a.Process.StartTime.ToUniversalTime().ToString('o') });
    presentedUtc = [DateTime]::UtcNow.AddSeconds(-601).ToString('o') }
  # Fixture parents started recently, so use a long-lived exact parent here.
  $stale.roots[0].pid = $PID; $stale.roots[0].start = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
  $stale.presentedUtc = $stale.roots[0].start
  $stale.key = Get-ProductClaimKey $stale
  $q.nextTicket++; $q.claims = @($stale)
  [IO.File]::WriteAllText($queue, ($q | ConvertTo-Json -Depth 8 -Compress))
  $clock = [DateTime]::UtcNow.AddSeconds(601).ToString('o')
  $r = Invoke-Fifo $a 'Gate' @{ TestQueueUtc = $clock }
  Assert-Fifo ($r.code -eq 0 -and $r.body) 'AC3 expired live ticket loses position, not process lifetime'
  $r = Invoke-Fifo $a
  # The test clock is deliberately ahead; reset only this owned fixture file.
  [IO.File]::WriteAllText($queue, '{"schemaVersion":1,"nextTicket":1,"claims":[]}')
  $q = [IO.File]::ReadAllText($queue) | ConvertFrom-Json
  $stale.ticket = 1; $stale.presentedUtc = [DateTime]::UtcNow.ToString('o')
  $retained = [pscustomobject]@{ ticket = [long]2; kind = 'parent'; launchId = $null;
    roots = @([pscustomobject]@{ pid = $b.Process.Id; start = $b.Process.StartTime.ToUniversalTime().ToString('o') });
    presentedUtc = [DateTime]::UtcNow.AddSeconds(2).ToString('o') }
  $retained | Add-Member key (Get-ProductClaimKey $retained)
  $q.nextTicket = 3; $q.claims = @($stale, $retained)
  [IO.File]::WriteAllText($queue, ($q | ConvertTo-Json -Depth 8 -Compress))
  $clock = [DateTime]::UtcNow.AddSeconds(601).ToString('o')
  $r = Invoke-Fifo $c 'Gate' @{ TestQueueUtc = $clock }
  $afterPrune = [IO.File]::ReadAllText($queue) | ConvertFrom-Json
  Assert-Fifo ($r.code -eq 73 -and -not $r.body -and $r.text -match 'position=2 reserved' -and
    $afterPrune.claims.Count -eq 2 -and $afterPrune.claims[0].ticket -eq 2) 'AC1 refusal after stale-head prune retains next absent reservation'
  [IO.File]::WriteAllText($queue, '{"schemaVersion":1,"nextTicket":1,"claims":[]}')
  }
  if ($Section -ceq 'Lifecycle') { Write-Output "RESULT PASS checks=$script:checks"; return }

  $validRaw = [IO.File]::ReadAllText($queue)
  $candidateSource = [IO.File]::ReadAllText($guard)
  if ($Section -cin @('All', 'Integrity')) {
  foreach ($invalid in @('{}', '{"schemaVersion":1,"schemaVersion":1,"nextTicket":1,"claims":[]}',
      '{"schemaVersion":1,"nextTicket":0,"claims":[]}', ('x' * 262145))) {
    [IO.File]::WriteAllText($queue, $invalid)
    $bytes = [IO.File]::ReadAllBytes($queue); $hash = (Get-FileHash -LiteralPath $queue).Hash.ToLowerInvariant()
    Set-Barrier; $raw = [IO.File]::ReadAllText($ownerPath)
    for ($i = 0; $i -lt 2; $i++) {
      $r = Invoke-Fifo $a
      Assert-Fifo ($r.code -eq 73 -and -not $r.body -and $r.text.Contains($queue) -and
        $r.text.Contains("sha256=$hash") -and $r.text -match 'size=\d+.*reason=' -and
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($queue)) -ceq [Convert]::ToBase64String($bytes) -and
        [IO.File]::ReadAllText($ownerPath) -ceq $raw) "AC4 corrupt/over-cap repeated refusal $i bytes=$($bytes.Length)"
    }
    Release-Barrier
  }
  [IO.File]::WriteAllText($queue, $validRaw)
  $queuePath = $queue
  [IO.File]::WriteAllText($queue, $validRaw.PadRight(262144, ' '))
  Assert-Fifo ((Read-ProductQueue).record.claims.Count -eq 0) 'AC4 exact 256-KiB queue is valid'
  $capQueue = [pscustomobject]@{ schemaVersion = [long]1; nextTicket = [long]129; claims = @() }
  for ($i = 1; $i -le 128; $i++) {
    $ticket = [pscustomobject]@{ ticket = [long]$i; key = ''; kind = 'parent'; launchId = $null;
      roots = @([pscustomobject]@{ pid = 900000 + $i; start = '2026-01-01T00:00:00.0000000Z' });
      presentedUtc = [DateTime]::UtcNow.ToString('o') }
    $ticket.key = Get-ProductClaimKey $ticket
    $capQueue.claims += $ticket
  }
  [IO.File]::WriteAllText($queue, ($capQueue | ConvertTo-Json -Depth 8 -Compress))
  Assert-Fifo ((Read-ProductQueue).record.claims.Count -eq 128) 'AC4 exact 128-ticket queue is valid'
  $capQueue.claims += $capQueue.claims[0]; $capQueue.nextTicket = 130
  $capBytes = $capQueue | ConvertTo-Json -Depth 8 -Compress
  [IO.File]::WriteAllText($queue, $capBytes)
  $r = Invoke-Fifo $a
  Assert-Fifo ($r.code -eq 73 -and -not $r.body -and [IO.File]::ReadAllText($queue) -ceq $capBytes) 'AC4 129-ticket queue refuses byte-exact without granting ticket'
  [IO.File]::WriteAllText($queue, $validRaw)
  # Duplicate tickets and duplicate stable identities are independently invalid.
  Set-Barrier; Invoke-Fifo $a | Out-Null
  $original = [IO.File]::ReadAllText($queue)
  foreach ($sameTicket in @($true, $false)) {
    $q = $original | ConvertFrom-Json
    $duplicate = ($q.claims[0] | ConvertTo-Json -Depth 8) | ConvertFrom-Json
    if (-not $sameTicket) { $duplicate.ticket = $q.nextTicket; $q.nextTicket++ }
    $q.claims += $duplicate
    [IO.File]::WriteAllText($queue, ($q | ConvertTo-Json -Depth 8 -Compress))
    $r = Invoke-Fifo $b
    Assert-Fifo ($r.code -eq 73 -and -not $r.body) "AC4 duplicate ticket=$sameTicket refuses"
  }
  Release-Barrier; [IO.File]::WriteAllText($queue, $validRaw)

  # Fault injection changes the disposable source, never production authority.
  $candidateSource = [IO.File]::ReadAllText($guard)
  $writeAnchor = '$current = Get-ProductQueueFile $queuePath'
  $replacedSource = $candidateSource.Replace($writeAnchor, '[IO.File]::Move($queuePath,$queuePath+".replaced"); [IO.File]::WriteAllText($queuePath,$Snapshot.raw); ' + $writeAnchor)
  [IO.File]::WriteAllText($guard, $replacedSource)
  $r = Invoke-Fifo $a
  Assert-Fifo ($r.code -eq 73 -and -not $r.body -and $r.text -match 'replaced before persistence' -and
    [IO.File]::ReadAllText($queue) -ceq $validRaw) 'AC4 same-byte different-file replacement refuses'
  [IO.File]::WriteAllText($guard, $candidateSource); [IO.File]::Delete($queue + '.replaced')
  $removeAnchor = '$productTicket.snapshot.record.claims = @('
  [IO.File]::WriteAllText($guard, $candidateSource.Replace($removeAnchor, 'throw "injected ticket removal failure"; ' + $removeAnchor))
  $r = Invoke-Fifo $a
  Assert-Fifo ($r.code -eq 73 -and -not $r.body -and -not (Test-Path $lock) -and
    ([IO.File]::ReadAllText($queue) | ConvertFrom-Json).claims.Count -eq 1) 'AC4 ticket-removal persistence failure releases new owner, runs no body'
  [IO.File]::WriteAllText($guard, $candidateSource); [IO.File]::WriteAllText($queue, $validRaw)
  }
  if ($Section -ceq 'Integrity') { Write-Output "RESULT PASS checks=$script:checks"; return }

  $markerPath = Join-Path $runtime 'verify-queue.recovery'
  function Reset-Recovery {
    [IO.File]::Delete($markerPath); [IO.File]::Delete($queue)
    $records = Join-Path $runtime 'verify-queue-quarantine'
    if (Test-Path -LiteralPath $records) { Remove-Item -LiteralPath $records -Recurse -Force }
    [IO.File]::WriteAllText($queue, '{}')
    return (Get-FileHash -LiteralPath $queue).Hash.ToLowerInvariant()
  }
  $hash = Reset-Recovery
  $r = Invoke-Fifo $a 'Recovery' @{ QuarantineQueue = $hash } @{ CHASE_SETS_HEAVY_SLOT_ID = ('e' * 32) }
  Assert-Fifo ($r.code -eq 73 -and -not (Test-Path $markerPath)) 'AC4 inherited-token recovery refuses without writes'
  $r = Invoke-Fifo $a 'Recovery' @{ QuarantineQueue = ('e' * 64) }
  Assert-Fifo ($r.code -eq 73 -and -not (Test-Path $markerPath)) 'AC4 changed-hash recovery refuses without writes'
  $r = Invoke-Fifo $a 'Recovery' @{ QuarantineQueue = $hash; Gate = 'verify:static' }
  Assert-Fifo ($r.code -eq 73 -and -not (Test-Path $markerPath) -and [IO.File]::ReadAllText($queue) -ceq '{}') 'AC4 recovery/execution mixed grammar refuses before writes'
  $r = Invoke-Fifo $a 'NoGate'
  Assert-Fifo ($r.code -eq 73 -and -not $r.body -and [IO.File]::ReadAllText($queue) -ceq '{}') 'AC4 missing execution Gate never initializes queue or runs body'
  $launchId = [guid]::NewGuid().ToString()
  $label = 'synthetic-fifo-lane'
  $recordPath = Join-Path $runtime "dispatch-launch-$launchId.json"
  $launch = [ordered]@{ schemaVersion = 4; launchId = $launchId; laneRole = 'implementation';
    promptPath = (Join-Path $runtime "dispatch-heavy-verifier-$launchId.prompt.txt"); reviewIsolationRoot = $null;
    launcherPid = $PID; launcherStartIdentity = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o');
    recordedAt = $a.Process.StartTime.ToUniversalTime().AddSeconds(-1).ToString('o'); state = 'started';
    childPid = $a.Process.Id; childStartIdentity = $a.Process.StartTime.ToUniversalTime().ToString('o');
    worktree = $tree; lane = 'candidate'; identityMode = 'branch'; branch = 'synthetic/fifo'; head = Git-Fixture @('rev-parse', 'HEAD');
    label = $label; transcriptPath = (Join-Path $runtime "$label.jsonl") }
  $route = [ordered]@{ ts = $a.Process.StartTime.ToUniversalTime().AddMilliseconds(-1).ToString('o'); kind = 'dispatch';
    dispatchRoutingSchema = 'watchdog-dispatch-routing/v1'; attemptId = $label; label = $label; lane = 'candidate';
    laneRole = 'implementation'; transcript = "$label.jsonl"; harness = 'codex'; model = 'gpt-6.1-sol'; effort = 'high';
    row = '7'; placement = 'provisional'; worktree = $tree; branch = 'synthetic/fifo'; head = $launch.head }
  [IO.File]::WriteAllText($launch.promptPath, 'synthetic inert fixture')
  [IO.File]::WriteAllText($launch.transcriptPath, "{`"type`":`"item.completed`"}`n")
  [IO.File]::WriteAllText((Join-Path $runtime 'dispatch-log.jsonl'), ($route | ConvertTo-Json -Compress) + "`n")
  [IO.File]::WriteAllText($recordPath, ($launch | ConvertTo-Json -Compress))
  $r = Invoke-Fifo $a 'Recovery' @{ QuarantineQueue = $hash }
  Assert-Fifo ($r.code -eq 73 -and $r.text -match 'requires proven standalone host' -and -not (Test-Path $markerPath)) "AC4 containing-lane recovery refuses without writes output=$($r.text)"
  foreach ($role in @('review', 'planning')) {
    $launch.laneRole = $role
    [IO.File]::WriteAllText($recordPath, ($launch | ConvertTo-Json -Compress))
    $r = Invoke-Fifo $a
    Assert-Fifo ($r.code -eq 73 -and $r.text -match 'caller eligibility' -and [IO.File]::ReadAllText($queue) -ceq '{}') "AC4 ineligible $role never touches queue"
  }
  foreach ($path in @($recordPath, $launch.promptPath, $launch.transcriptPath, (Join-Path $runtime 'dispatch-log.jsonl'))) { [IO.File]::Delete($path) }

  [IO.File]::Delete($queue)
  $reparseTarget = Join-Path $root 'reparse-target'
  [void][IO.Directory]::CreateDirectory($reparseTarget)
  New-Item -ItemType Junction -Path $queue -Target $reparseTarget | Out-Null
  $r = Invoke-Fifo $a 'Recovery' @{ QuarantineQueue = $hash }
  Assert-Fifo ($r.code -eq 73 -and -not (Test-Path $markerPath) -and
    (Get-Item -LiteralPath $queue -Force).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) 'AC4 reparse recovery refuses and retains evidence'
  $r = Invoke-Fifo $a
  Assert-Fifo ($r.code -eq 73 -and -not $r.body -and $r.text -match 'unsafe-file') 'AC4 ordinary reparse queue refuses without reset'
  [IO.Directory]::Delete($queue)
  foreach ($step in @('marker', 'record', 'move', 'empty-stage', 'empty-proof', 'empty-publish', 'empty-readback', 'before-delete')) {
    $hash = Reset-Recovery
    Set-Barrier; $ownerBytes = [IO.File]::ReadAllText($ownerPath)
    $controllerLock = Join-Path $runtime 'controller-verify-lock.d'
    [void][IO.Directory]::CreateDirectory($controllerLock)
    $controllerOwner = Join-Path $controllerLock 'owner.json'
    [IO.File]::WriteAllText($controllerOwner, 'synthetic controller bytes')
    $r = Invoke-Fifo $a 'Recovery' @{ QuarantineQueue = $hash; TestRecoveryStopAfter = 'marker' }
    Assert-Fifo ($r.code -eq 73 -and (Test-Path $markerPath)) "AC4 recovery marker create-once $step"
    $markerBytes = [IO.File]::ReadAllText($markerPath)
    $m = $markerBytes | ConvertFrom-Json
    $later = [DateTimeOffset]::Parse($m.utc).UtcDateTime.AddSeconds(601).ToString('o')
    $r = Invoke-Fifo $a 'Recovery' @{ QuarantineQueue = $hash }
    Assert-Fifo ($r.code -eq 73 -and [IO.File]::ReadAllText($queue) -ceq '{}') "AC4 early quarantine refuses $step"
    if ($step -cne 'marker') {
      $r = Invoke-Fifo $a 'Recovery' @{ QuarantineQueue = $hash; TestQueueUtc = $later; TestRecoveryStopAfter = $step }
      Assert-Fifo ($r.code -eq 73 -and $r.text.Contains("test-stop=$step")) "AC4 recovery stops after $step output=$($r.text)"
    }
    $exists = Test-Path -LiteralPath $queue
    $queueBytes = if ($exists) { [IO.File]::ReadAllText($queue) } else { $null }
    $r = Invoke-Fifo $b
    Assert-Fifo ($r.code -eq 73 -and -not $r.body -and $r.text.Contains($markerPath) -and
      (Test-Path -LiteralPath $queue) -eq $exists -and
      (-not $exists -or [IO.File]::ReadAllText($queue) -ceq $queueBytes) -and
      [IO.File]::ReadAllText($markerPath) -ceq $markerBytes -and [IO.File]::ReadAllText($ownerPath) -ceq $ownerBytes -and
      [IO.File]::ReadAllText($controllerOwner) -ceq 'synthetic controller bytes') "AC4 ordinary admission stays blocked after $step"
    $r = Invoke-Fifo $a 'Recovery' @{ QuarantineQueue = $hash; TestQueueUtc = $later }
    Assert-Fifo ($r.code -eq 0 -and -not (Test-Path $markerPath) -and (Test-Path -LiteralPath $queue) -and
      [IO.File]::ReadAllText($queue) -ceq $validRaw -and [IO.File]::ReadAllText($ownerPath) -ceq $ownerBytes) "AC4 stopped $step resumes only proven next step output=$($r.text)"
    $archive = Join-Path $runtime ($m.record + '/verify-queue.json')
    Assert-Fifo ([IO.File]::ReadAllText($archive) -ceq '{}' -and (Get-FileHash $archive).Hash.ToLowerInvariant() -ceq $hash) "AC4 original evidence retained $step"
    Release-Barrier
    $r = Invoke-Fifo $b
    Assert-Fifo ($r.code -eq 0 -and $r.body) "AC4 only completed recovery admits $step"
    [IO.File]::Delete($controllerOwner); [IO.Directory]::Delete($controllerLock)
  }
  foreach ($fault in @('replaced', 'changed-hash', 'pre-move', 'archive', 'empty', 'unexpected')) {
    $hash = Reset-Recovery
    $r = Invoke-Fifo $a 'Recovery' @{ QuarantineQueue = $hash }
    Assert-Fifo ($r.code -eq 73 -and (Test-Path $markerPath)) "AC4 fault marker established $fault"
    $markerBytes = [IO.File]::ReadAllText($markerPath)
    $m = $markerBytes | ConvertFrom-Json -DateKind String
    $later = [DateTimeOffset]::Parse($m.utc).UtcDateTime.AddSeconds(601).ToString('o')
    if ($fault -cin @('archive', 'empty', 'unexpected')) {
      $stop = if ($fault -ceq 'empty') { 'empty-publish' } else { 'move' }
      Invoke-Fifo $a 'Recovery' @{ QuarantineQueue = $hash; TestQueueUtc = $later; TestRecoveryStopAfter = $stop } | Out-Null
      $record = Join-Path $runtime $m.record
      if ($fault -ceq 'archive') { [IO.File]::WriteAllText((Join-Path $record 'verify-queue.json'), '{"changed":true}') }
      elseif ($fault -ceq 'empty') {
        [IO.File]::Move($queue, $queue + '.original-empty'); [IO.File]::WriteAllText($queue, $validRaw)
      } else { [IO.File]::WriteAllText((Join-Path $record 'foreign'), 'unexpected') }
    } elseif ($fault -ceq 'replaced') {
      [IO.File]::Move($queue, $queue + '.original'); [IO.File]::WriteAllText($queue, '{}')
    } elseif ($fault -ceq 'changed-hash') { [IO.File]::WriteAllText($queue, '{"changed":true}') }
    else {
      $anchor = "if (-not (Test-ProductQueueSame `$original `$unchanged)) { throw 'heavy-verifier: queue recovery pre-move replacement' }"
      Assert-Fifo ($candidateSource.Contains($anchor)) 'pre-move replacement exact fixture anchor'
      $inject = '[IO.File]::Move($queuePath,$queuePath+".original"); [IO.File]::WriteAllText($queuePath,$original.raw); $unchanged=Get-ProductQueueFile $queuePath; '
      [IO.File]::WriteAllText($guard, $candidateSource.Replace($anchor, $inject + $anchor))
    }
    $r = Invoke-Fifo $a 'Recovery' @{ QuarantineQueue = $hash; TestQueueUtc = $later }
    Assert-Fifo ($r.code -eq 73 -and [IO.File]::ReadAllText($markerPath) -ceq $markerBytes) "AC4 recovery mismatch retains marker $fault output=$($r.text)"
    $r = Invoke-Fifo $b
    Assert-Fifo ($r.code -eq 73 -and -not $r.body -and $r.text.Contains($markerPath)) "AC4 mismatch still blocks ordinary admission $fault"
    [IO.File]::WriteAllText($guard, $candidateSource)
    foreach ($suffix in @('.original', '.original-empty')) { [IO.File]::Delete($queue + $suffix) }
  }
  $hash = Reset-Recovery
  [IO.File]::WriteAllText($queue, ('x' * 262145))
  $hash = (Get-FileHash -LiteralPath $queue).Hash.ToLowerInvariant()
  $r = Invoke-Fifo $a 'Recovery' @{ QuarantineQueue = $hash }
  Assert-Fifo ($r.code -eq 73 -and (Test-Path $markerPath)) 'AC4 over-cap recovery begins pending, never resets automatically'
  $m = [IO.File]::ReadAllText($markerPath) | ConvertFrom-Json -DateKind String
  $r = Invoke-Fifo $a 'Recovery' @{ QuarantineQueue = $hash; TestQueueUtc = [DateTimeOffset]::Parse($m.utc).UtcDateTime.AddSeconds(601).ToString('o') }
  Assert-Fifo ($r.code -eq 0 -and (Get-FileHash (Join-Path $runtime ($m.record + '/verify-queue.json'))).Hash.ToLowerInvariant() -ceq $hash) 'AC4 over-cap evidence is streamed, retained and recovered exactly'
  Write-Output "RESULT PASS checks=$script:checks"
} finally {
  foreach ($s in $sessions) {
    $s.Process.StandardInput.Close()
    if (-not $s.Process.WaitForExit(30000)) { $s.Process.Kill($true); $s.Process.WaitForExit() }
    $s.Process.Dispose()
  }
  $resolved = [IO.Path]::GetFullPath($root)
  if (-not $resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) { throw 'unsafe fixture cleanup' }
  if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
