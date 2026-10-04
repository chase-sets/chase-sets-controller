[CmdletBinding()]
param(
  [switch]$FifoOnly,
  [string]$FifoGuardPath,
  [switch]$NativeDbOnly,
  [switch]$DiscriminatorOnly,
  [switch]$RulingFourOnly,
  [switch]$PrecursorAdmissionDiscriminatorOnly,
  [switch]$PrecursorOnly,
  [switch]$LegacyOnly,
  [string]$GuardRevision = ""
)

$ErrorActionPreference = "Stop"
if($FifoOnly){
  & (Join-Path $PSScriptRoot 'invoke-heavy-verifier-fifo.test.ps1') -GuardPath $FifoGuardPath
  exit $LASTEXITCODE
}
$guard = Join-Path $PSScriptRoot "invoke-heavy-verifier.ps1"
function Assert-True($Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}
if ($NativeDbOnly) {
  $tokens = $null; $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($guard, [ref]$tokens, [ref]$errors)
  Assert-True ($errors.Count -eq 0) 'native wrapper parses'
  Assert-True ($ast.ParamBlock.Parameters.Name.VariablePath.UserPath -ccontains 'NativeDbProfile') 'closed NativeDbProfile entry exists'
  Assert-True ($ast.ParamBlock.Parameters.Name.VariablePath.UserPath -ccontains 'NativeRequestPath') 'closed NativeRequestPath entry exists'
  foreach ($function in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($function.Extent.Text))
  }
  function Native-Refuses([scriptblock]$Action, [string]$Name) {
    $refused = $false
    try { & $Action } catch { $refused = $true }
    Assert-True $refused "native negative: $Name"
  }
  $request = [ordered]@{
    schemaVersion = 1; correlation = 1; profile = 'reconciliation-pg16/v1'; run = 'synthetic-native-component'
    issue = 2147483647; attempt = 1; executorHead = ('a' * 40)
    product = @{ repository = 'synthetic/native-fixture'; head = ('b' * 40); tree = ('c' * 40) }
    declaration = @{ version = 1; profile = 'reconciliation-pg16/v1'; files = @(
      @{ file = 'bounded-contexts/channels/features/reconciliation/tests/channel-drift-classification-table.test.ts'; cases = @('synthetic') },
      @{ file = 'bounded-contexts/channels/features/reconciliation/tests/channel-reconciliation-runtime.db.test.ts'; cases = @('synthetic') },
      @{ file = 'deployables/platform-worker/__tests__/channels-reconciliation-runners.db.test.ts'; cases = @('synthetic') }
    ); mutants = @() }
    patchDigests = @(); stagedInputDirectory = '/srv/chase-sets-native-db-input/synthetic'
  }
  $requestRaw = $request | ConvertTo-Json -Compress -Depth 16
  $valid = Read-NativeJson $requestRaw 65536
  Assert-NativeRequest $valid
  $negativeCases = @(
    @{ name='missing root'; edit={ param($x) $x.PSObject.Properties.Remove('attempt') } },
    @{ name='unknown root'; edit={ param($x) $x | Add-Member unexpected 1 } },
    @{ name='command'; edit={ param($x) $x | Add-Member command 'echo' } },
    @{ name='env'; edit={ param($x) $x | Add-Member env @{ PGHOSTADDR='sentinel' } } },
    @{ name='unknown product'; edit={ param($x) $x.product | Add-Member unexpected 1 } },
    @{ name='missing product'; edit={ param($x) $x.product.PSObject.Properties.Remove('tree') } },
    @{ name='unknown declaration'; edit={ param($x) $x.declaration | Add-Member unexpected 1 } },
    @{ name='unknown file'; edit={ param($x) $x.declaration.files[0] | Add-Member unexpected 1 } },
    @{ name='missing cases'; edit={ param($x) $x.declaration.files[0].PSObject.Properties.Remove('cases') } },
    @{ name='case object'; edit={ param($x) $x.declaration.files[0].cases = @(@{ name='synthetic' }) } },
    @{ name='duplicate case'; edit={ param($x) $x.declaration.files[0].cases = @('synthetic','synthetic') } },
    @{ name='case too long'; edit={ param($x) $x.declaration.files[0].cases = @('x' * 513) } },
    @{ name='too many cases'; edit={ param($x) $x.declaration.files[0].cases = @(1..257 | ForEach-Object { "case-$_" }) } },
    @{ name='file traversal'; edit={ param($x) $x.declaration.files[0].file = '../escape' } },
    @{ name='duplicate file'; edit={ param($x) $x.declaration.files[1].file = $x.declaration.files[0].file } },
    @{ name='files object'; edit={ param($x) $x.declaration.files = @{} } },
    @{ name='zero correlation'; edit={ param($x) $x.correlation = 0 } },
    @{ name='correlation overflow'; edit={ param($x) $x.correlation = [long]9007199254740992 } },
    @{ name='fraction'; edit={ param($x) $x.correlation = 1.5 } },
    @{ name='coerced number'; edit={ param($x) $x.attempt = '1' } },
    @{ name='boolean number'; edit={ param($x) $x.attempt = $true } },
    @{ name='issue overflow'; edit={ param($x) $x.issue = [long]2147483648 } },
    @{ name='profile case'; edit={ param($x) $x.profile = 'Reconciliation-pg16/v1' } },
    @{ name='boolean profiles'; edit={ param($x) $x.profile = $true; $x.declaration.profile = $true } },
    @{ name='date-only hash'; edit={ param($x) $x.product.head = '2026-09-16' } },
    @{ name='input traversal'; edit={ param($x) $x.stagedInputDirectory = '/srv/chase-sets-native-db-input/..' } },
    @{ name='input wrong parent'; edit={ param($x) $x.stagedInputDirectory = '/root/synthetic' } },
    @{ name='run overflow'; edit={ param($x) $x.run = 'x' * 129 } }
  )
  foreach ($negative in $negativeCases) {
    $copy = Read-NativeJson $requestRaw 65536
    & $negative.edit $copy
    Native-Refuses { Assert-NativeRequest $copy } $negative.name
  }
  $maximum = Read-NativeJson $requestRaw 65536
  $maximum.correlation = [long]9007199254740991; $maximum.attempt = 2147483647; $maximum.run = 'x' * 128
  foreach ($file in $maximum.declaration.files) { $file.cases = @(1..256 | ForEach-Object { "case-$_" }) }
  $maximum.declaration.mutants = @(1..3 | ForEach-Object { [pscustomobject]@{ id="mutant-$_"; file='synthetic/source.ts'; cases=@('x' * 512); assertion=('x' * 2048) } })
  $maximum.patchDigests = @(1..3 | ForEach-Object { [pscustomobject]@{ id="mutant-$_"; digest=('f' * 64) } })
  Assert-NativeRequest $maximum
  foreach ($target in @($maximum.declaration.mutants[0], $maximum.patchDigests[0])) {
    $target | Add-Member unexpected 1
    Native-Refuses { Assert-NativeRequest $maximum } 'unknown mutant/patch key'
    $target.PSObject.Properties.Remove('unexpected')
  }
  Native-Refuses { Read-NativeJson (' ' * 65537) 65536 } 'request byte bound'
  Native-Refuses { Read-NativeJson (' ' * 8193) 8192 } 'reply byte bound'
  Native-Refuses { Read-NativeJson '{"correlation":1,"correlation":2}' 65536 } 'duplicate key'
  Native-Refuses { Read-NativeJson (('[' * 17) + '0' + (']' * 17)) 65536 } 'depth'
  $tuple = Read-NativeJson '{"bootId":"00000000-0000-0000-0000-000000000001","outerPid":2147483647,"startTicks":"18446744073709551615","nspid":[2147483647,1],"inode":"18446744073709551615"}' 8192
  Assert-True (Test-NativeTuple $tuple) 'maximum Linux tuple'
  foreach ($edit in @(
      { param($x) $x.startTicks='18446744073709551616' },
      { param($x) $x.inode=1 }, { param($x) $x.nspid=@(1) },
      { param($x) $x.nspid=@($x.outerPid,2) }, { param($x) $x.bootId='2026-09-16' },
      { param($x) $x | Add-Member unexpected 1 }
    )) {
    $copy = Read-NativeJson ($tuple | ConvertTo-Json -Compress) 8192
    & $edit $copy
    Assert-True (-not (Test-NativeTuple $copy)) 'tuple negative retains owner'
  }
  Write-Output "PASS native DB request parser: minimum, maximum, $($negativeCases.Count) mutations, byte/depth/duplicate and Linux tuple bounds"
  $nativeRoot = Join-Path ([IO.Path]::GetTempPath()) ('native-descendants-' + [guid]::NewGuid().ToString('N'))
  [void][IO.Directory]::CreateDirectory($nativeRoot)
  $treeScript = Join-Path $nativeRoot 'tree.ps1'
  [IO.File]::WriteAllText($treeScript, @'
param([string]$Root,[int]$Stage)
$self = Get-Process -Id $PID
[IO.File]::WriteAllText((Join-Path $Root "$Stage.json"), (@{pid=$PID;start=$self.StartTime.ToUniversalTime().ToString('o')} | ConvertTo-Json -Compress))
if ($Stage -eq 1) { while (-not (Test-Path (Join-Path $Root 'spawn'))) { Start-Sleep -Milliseconds 25 } }
if ($Stage -gt 0) {
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = $self.Path; $start.UseShellExecute=$false; $start.CreateNoWindow=$true
  foreach ($arg in @('-NoProfile','-File',$PSCommandPath,'-Root',$Root,'-Stage',"$($Stage-1)")) { $start.ArgumentList.Add($arg) }
  [void][Diagnostics.Process]::Start($start)
}
while (-not (Test-Path (Join-Path $Root "release-$Stage"))) { Start-Sleep -Milliseconds 25 }
'@)
  function Wait-NativeFixture([scriptblock]$Predicate, [string]$Name) {
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while (-not (& $Predicate)) { if ([DateTime]::UtcNow -gt $deadline) { throw "native fixture expired: $Name" }; Start-Sleep -Milliseconds 25 }
  }
  function Stop-NativeFixture($Identity) {
    $live = Get-Process -Id $Identity.pid -ErrorAction SilentlyContinue
    if ($live -and $live.StartTime.ToUniversalTime().Ticks -eq [DateTimeOffset]::Parse($Identity.start).Ticks) {
      $live.Kill(); Assert-True ($live.WaitForExit(30000)) 'owned Windows fixture exits'
    }
  }
  try {
    foreach ($mode in @('normal','later')) {
      $caseRoot = Join-Path $nativeRoot $mode
      [void][IO.Directory]::CreateDirectory($caseRoot)
      $start = [Diagnostics.ProcessStartInfo]::new()
      $start.FileName = (Get-Process -Id $PID).Path; $start.UseShellExecute=$false; $start.CreateNoWindow=$true
      foreach ($arg in @('-NoProfile','-File',$treeScript,'-Root',$caseRoot,'-Stage','3')) { $start.ArgumentList.Add($arg) }
      $tree = [Diagnostics.Process]::Start($start)
      Wait-NativeFixture { Test-Path (Join-Path $caseRoot '1.json') } 'older relay exists'
      $identities = @{}
      foreach ($stage in @(1,2,3)) { $identities[$stage] = Get-Content (Join-Path $caseRoot "$stage.json") | ConvertFrom-Json -DateKind String }
      $boundary = [DateTimeOffset]::UtcNow
      [IO.File]::WriteAllText((Join-Path $caseRoot 'spawn'), 'spawn')
      Wait-NativeFixture { Test-Path (Join-Path $caseRoot '0.json') } 'deepest grandchild exists'
      $identities[0] = Get-Content (Join-Path $caseRoot '0.json') | ConvertFrom-Json -DateKind String
      foreach ($stage in @(0,1,2)) {
        $actual = Get-CimInstance Win32_Process -Filter "ProcessId = $($identities[$stage].pid)"
        Assert-True ($actual.ParentProcessId -eq $identities[$stage+1].pid) 'real exact Windows tree parent'
      }
      # Synthetic ownership boundary deliberately straddles the real relay and
      # deepest worker, discriminating breadth-first versus one-hop traversal.
      $record = Read-NativeJson ((@{
        schemaVersion=6;lockId=('d'*32);owner='synthetic';lane='synthetic';branch='codex/synthetic';head=('a'*40)
        worktree=$caseRoot;identityMode='branch';pid=$identities[3].pid;processStartUtc=$identities[3].start
        startedUtc=$boundary.UtcDateTime.ToString('o');gate='verify:test-db';commandIdentity=('e'*64);state='started'
        childPid=$identities[2].pid;childProcessStartUtc=$boundary.AddTicks(1).UtcDateTime.ToString('o')
        native=@{profile='reconciliation-pg16/v1';request=@{path=(Join-Path $caseRoot '.orchestrator/artifacts/request.json');digest=('f'*64)};root=('/srv/chase-sets-pg-probe/native-db-'+('d'*32));linux=$tuple}
      }) | ConvertTo-Json -Depth 16 -Compress) 16384
      Assert-True (Test-OwnerShape $record) 'closed schema6 with maximum Linux tuple'
      $record.native.profile=$true
      Assert-True (-not (Test-OwnerShape $record)) 'schema6 profile rejects boolean coercion'
      $record.native.profile='reconciliation-pg16/v1'
      $savedPath=$record.native.request.path; $record.native.request.path=@($savedPath)
      Assert-True (-not (Test-OwnerShape $record)) 'schema6 request path rejects array coercion'
      $record.native.request.path=$savedPath
      foreach ($nested in @($record, $record.native, $record.native.request, $record.native.linux)) {
        $nested | Add-Member unexpected 1
        Assert-True (-not (Test-OwnerShape $record)) 'schema6 closes every nested object'
        $nested.PSObject.Properties.Remove('unexpected')
      }
      foreach ($key in @('processStartUtc','startedUtc','childProcessStartUtc')) {
        $saved = $record.$key; $record.$key='2026-09-16'
        Assert-True (-not (Test-OwnerShape $record)) 'schema6 rejects date-only instant'
        $record.$key=$saved
      }
      Stop-NativeFixture $identities[2]
      if ($mode -ceq 'later') { Stop-NativeFixture $identities[3] }
      Assert-True ((Test-PossibleOwnedChild $record -GuardedRootOnly) -eq $true) 'full guarded-root BFS finds real deepest grandchild'
      $eligible = if ($mode -ceq 'normal') { Test-NativeNormalRelease $record } else { Test-ReclaimableOwner $record }
      Assert-True (-not $eligible) "$mode schema6 refuses real deepest grandchild"
      Stop-NativeFixture $identities[0]
      Wait-NativeFixture { (Test-PossibleOwnedChild $record -GuardedRootOnly) -eq $false } 'deepest exact absence'
      $eligible = if ($mode -ceq 'normal') { Test-NativeNormalRelease $record } else { Test-ReclaimableOwner $record }
      Assert-True $eligible "$mode schema6 Windows prerequisite after deepest death"
      if ($mode -ceq 'normal') {
        Assert-True ((Test-PossibleOwnedChild $record) -ne $false) 'all-root substitution cannot release normal live wrapper'
        $normalSource=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Test-NativeNormalRelease'}, $false).Extent.Text
        . ([scriptblock]::Create($normalSource.Replace(' -GuardedRootOnly', '')))
        Assert-True (-not (Test-NativeNormalRelease $record)) 'normal all-root mutant prevents release with every other input frozen'
        . ([scriptblock]::Create($normalSource))
      }
      $lockPath = Join-Path $caseRoot 'verify-lock.d'
      $ownerPath = Join-Path $lockPath 'owner.json'
      $claim = Join-Path $lockPath 'owner.synthetic-claim.json'
      $raw = $record | ConvertTo-Json -Depth 16 -Compress
      [void][IO.Directory]::CreateDirectory($lockPath)
      foreach ($encoding in @([Text.UTF8Encoding]::new($true), [Text.Encoding]::Unicode)) {
        [byte[]]$encoded = $encoding.GetPreamble() + $encoding.GetBytes($raw)
        [IO.File]::WriteAllBytes($ownerPath, $encoded)
        Assert-True ($null -eq (Get-OwnerSnapshot)) 'schema6 owner must not normalize changed encoding bytes into unchanged ownership'
        Remove-Item -LiteralPath $ownerPath
      }
      [IO.File]::WriteAllText($claim, $raw)
      # Synthetic Linux uncertainty is the only changed input in this pair.
      # The separate copied-runtime test owns real kernel cleanup evidence.
      function Complete-NativeReconciliation($Record) { return $false }
      $releaseArguments = @{ ClaimPath=$claim; ExpectedRaw=$raw; RequireDead=($mode -ceq 'later') }
      Assert-True (-not (Remove-ClaimedOwnerLock @releaseArguments)) "$mode Linux uncertainty refuses unchanged-owner release"
      Assert-True ([IO.File]::ReadAllText($ownerPath) -ceq $raw) "$mode Linux refusal restores byte-identical owner"
      [IO.File]::Move($ownerPath, $claim)
      $releaseSource = $ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Remove-ClaimedOwnerLock'}, $false).Extent.Text
      $bypass = $releaseSource.Replace('if (-not (Complete-NativeReconciliation $record)) { return $false }', '# synthetic bypass of Linux absence only')
      Assert-True ($bypass -cne $releaseSource) 'Linux bypass mutation applied exactly'
      . ([scriptblock]::Create($bypass))
      Assert-True (Remove-ClaimedOwnerLock @releaseArguments) "$mode Linux-bypass mutant violates the intended retained-owner assertion"
      . ([scriptblock]::Create($releaseSource))
      function Get-CimInstance { throw 'synthetic unreadable process enumeration' }
      try {
        $eligible = if ($mode -ceq 'normal') { Test-NativeNormalRelease $record } else { Test-ReclaimableOwner $record }
        Assert-True (-not $eligible) "$mode ambiguous Windows enumeration retains owner"
      } finally { Remove-Item Function:\Get-CimInstance }
      $savedTuple = $record.native.linux; $record.native.linux=$null
      $eligible = if ($mode -ceq 'normal') { Test-NativeNormalRelease $record } else { Test-ReclaimableOwner $record }
      Assert-True (-not $eligible) "$mode missing Linux tuple retains owner"
      $record.native.linux=$savedTuple
      $record.childPid=$PID; $record.childProcessStartUtc=$boundary.UtcDateTime.ToString('o')
      $eligible = if ($mode -ceq 'normal') { Test-NativeNormalRelease $record } else { Test-ReclaimableOwner $record }
      Assert-True (-not $eligible) "$mode reused child retains owner"
      Stop-NativeFixture $identities[1]; Stop-NativeFixture $identities[3]
      Write-Output "PASS schema6 $mode real deepest-grandchild refusal, full traversal, missing tuple and reused PID retention"
    }
  } finally {
    foreach ($mode in @('normal','later')) {
      foreach ($stage in @(0,1,2,3)) {
        $path = Join-Path $nativeRoot "$mode/$stage.json"
        if (Test-Path $path) { Stop-NativeFixture (Get-Content $path | ConvertFrom-Json -DateKind String) }
      }
    }
    $resolved = [IO.Path]::GetFullPath($nativeRoot)
    Assert-True ($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) 'native fixture confined to temp'
    Remove-Item -LiteralPath $resolved -Recurse -Force
  }
  Write-Output 'PASS native DB closed entry'
  return
}
if (-not ($DiscriminatorOnly -or $RulingFourOnly -or $PrecursorAdmissionDiscriminatorOnly -or $PrecursorOnly -or $LegacyOnly)) {
  & $PSCommandPath -NativeDbOnly
}
function Assert-PrecursorAdmissionSurface([string]$Source) {
  Assert-True ($Source -match 'ParameterSetName\s*=\s*"ControllerPrecursor"') `
    "ControllerPrecursor parameter set is absent"
  foreach ($producer in @(
      "fail-closed-guard-evidence",
      "issue-6254-fail-closed-guard-evidence"
    )) {
    Assert-True ($Source -match ('"' + [regex]::Escape($producer) + '"\s*=\s*\[ordered\]')) `
      "closed producer mapping is absent: $producer"
  }
  Assert-True ($Source -match '(?s)Parameter\(ParameterSetName\s*=\s*"Gate",\s*DontShow\)\]\s*\[Parameter\(ParameterSetName\s*=\s*"ControllerBattery",\s*DontShow\)\]\s*\[Parameter\(ParameterSetName\s*=\s*"Attach",\s*DontShow\)\]\s*\[string\]\$CommandPath') `
    "CommandPath is not confined to the Gate parameter set"
  Assert-True ($Source -match 'controller precursor authoritative output already exists' -and
    $Source -match 'succeeded without its required safe output artifact') `
    "precursor create-once output contract is incomplete"
}
if ($PrecursorAdmissionDiscriminatorOnly) {
  $source = if ([string]::IsNullOrWhiteSpace($GuardRevision)) {
    Get-Content -LiteralPath $guard -Raw
  } else {
    $controllerRoot = Split-Path -Parent $PSScriptRoot
    $specification = "$GuardRevision`:.orchestrator/invoke-heavy-verifier.ps1"
    $lines = @(& git -C $controllerRoot show $specification 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "unable to read guard revision $GuardRevision" }
    $lines -join "`n"
  }
  Assert-PrecursorAdmissionSurface $source
  Write-Output "PASS heavy verifier ControllerPrecursor admission discriminator"
  return
}
$systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
$root = Join-Path $systemTemp ("heavy-verifier-test-" + [guid]::NewGuid().ToString("N"))
$container = Join-Path $root "container with spaces"
$worktree = Join-Path $container "lane with spaces"
$orchestrator = Join-Path $container ".orchestrator"
$lock = Join-Path $orchestrator "verify-lock.d"
$ownerPath = Join-Path $lock "owner.json"
$testWrapperIdentities = [Collections.Generic.List[object]]::new()
$worktreeOrchestrator = Join-Path $worktree ".orchestrator"
$artifacts = Join-Path $worktreeOrchestrator "artifacts"
New-Item -ItemType Directory -Path $worktree, $orchestrator, $worktreeOrchestrator -Force | Out-Null
function Invoke-FixtureGit([string[]]$Arguments) {
  $output = @(& git -C $worktree @Arguments 2>&1)
  if ($LASTEXITCODE -ne 0) {
    throw "fixture git command failed: git $($Arguments -join ' ')`n$($output -join "`n")"
  }
  return ($output -join "`n").Trim()
}
function Test-IsReparse([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return $false }
  $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
  return ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq [IO.FileAttributes]::ReparsePoint
}
function Assert-DisposableRoot {
  $resolved = [IO.Path]::GetFullPath($root).TrimEnd('\','/')
  Assert-True ($resolved.StartsWith($systemTemp + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) "disposable root stays below system temp"
  Assert-True (-not (Test-IsReparse $root)) "disposable root is not a reparse target"
}
function Remove-DisposableLock {
  if (-not (Test-Path -LiteralPath $lock)) { return }
  Assert-DisposableRoot
  Assert-True (-not (Test-IsReparse $lock)) "ordinary disposable lock is not a reparse target"
  Remove-Item -LiteralPath $lock -Recurse -Force
}
function Invoke-Guard([string]$Lane, [string[]]$ChildArguments, [hashtable]$Extra = @{}) {
  $parameters = @{
    Gate = "verify:static"
    Worktree = $worktree
    Lane = $Lane
    Branch = "codex/test"
    ClaimedHead = Invoke-FixtureGit @("rev-parse", "HEAD")
    ContainerRoot = $container
    CommandPath = (Join-Path $PSHOME "pwsh.exe")
    CommandArgumentList = $ChildArguments
  }
  if ($Extra.ContainsKey("ImmutableHead")) {
    [void]$parameters.Remove("Branch")
    [void]$parameters.Remove("ClaimedHead")
  }
  foreach ($entry in $Extra.GetEnumerator()) { $parameters[$entry.Key] = $entry.Value }
  & $guard @parameters
  return $LASTEXITCODE
}
function Read-Owner {
  if (-not (Test-Path -LiteralPath $ownerPath -PathType Leaf)) { return $null }
  try { return Get-Content -LiteralPath $ownerPath -Raw -ErrorAction Stop | ConvertFrom-Json -DateKind String -ErrorAction Stop } catch { return $null }
}
function Wait-Condition([scriptblock]$Condition, [string]$Message) {
  for ($attempt = 0; $attempt -lt 400; $attempt++) {
    if (& $Condition) { return }
    Start-Sleep -Milliseconds 25
  }
  throw "ASSERTION FAILED: timed out waiting for $Message"
}
function Get-ProcessIdentity([int]$ProcessId) {
  $candidate = Get-Process -Id $ProcessId -ErrorAction Stop
  return [pscustomobject]@{
    pid = $candidate.Id
    processStartUtc = $candidate.StartTime.ToUniversalTime().ToString("o")
  }
}
function Test-ExactProcess($Identity) {
  try {
    $candidate = Get-Process -Id ([int]$Identity.pid) -ErrorAction Stop
    return $candidate.StartTime.ToUniversalTime().Ticks -eq
      [DateTimeOffset]::Parse([string]$Identity.processStartUtc).ToUniversalTime().Ticks
  } catch {
    return $false
  }
}
function Stop-ExactProcess($Identity) {
  Assert-True (Test-ExactProcess $Identity) "hard-kill target PID/start identity is exact"
  $candidate = Get-Process -Id ([int]$Identity.pid) -ErrorAction Stop
  Stop-Process -InputObject $candidate -Force
  $candidate.WaitForExit()
  Assert-True (-not (Test-ExactProcess $Identity)) "hard-kill target exact identity is dead"
}
function Write-Owner([hashtable]$Values) {
  New-Item -ItemType Directory -Path $lock -ErrorAction Stop | Out-Null
  [IO.File]::WriteAllText($ownerPath, ($Values | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
}
function New-OwnerRecord(
  [string]$LockId,
  [int]$WrapperPid,
  [string]$WrapperStart,
  [string]$State = "started",
  $ChildPid = 999998,
  [string]$ChildStart
) {
  $recordedAt = [DateTime]::UtcNow.AddMinutes(-31)
  if ([string]::IsNullOrWhiteSpace($ChildStart)) {
    $ChildStart = $recordedAt.AddSeconds(1).ToString("o")
  }
  return @{
    schemaVersion = 2
    lockId = $LockId
    owner = "test"
    lane = "other"
    branch = "codex/other"
    pid = $WrapperPid
    processStartUtc = $WrapperStart
    startedUtc = $recordedAt.ToString("o")
    gate = "verify:static"
    commandIdentity = ("b" * 64)
    state = $State
    childPid = $(if ($State -ceq "started") { $ChildPid } else { $null })
    childProcessStartUtc = $(if ($State -ceq "started") { $ChildStart } else { $null })
  }
}

$markerScript = Join-Path $root "marker script with spaces.ps1"
$environmentChildScript = Join-Path $root "environment child with spaces.ps1"
$identityChildScript = Join-Path $root "identity child with spaces.ps1"
$descendantChildScript = Join-Path $root "descendant child with spaces.ps1"
$descendantRelayScript = Join-Path $root "descendant relay with spaces.ps1"
$deepWorkerScript = Join-Path $root "deep worker with spaces.ps1"
$runner = Join-Path $root "wrapper runner with spaces.ps1"
$precursorRunner = Join-Path $root "precursor wrapper runner with spaces.ps1"
$seedPath = Join-Path $worktree "identity-seed.txt"
$ignorePath = Join-Path $worktree ".gitignore"
Invoke-FixtureGit @("init", "--initial-branch=codex/test") | Out-Null
Invoke-FixtureGit @("config", "user.name", "Heavy Verifier Test") | Out-Null
Invoke-FixtureGit @("config", "user.email", "heavy-verifier-test@example.invalid") | Out-Null
Set-Content -LiteralPath $seedPath -Value "seed"
Set-Content -LiteralPath $ignorePath -Value ".orchestrator/artifacts/"
Set-Content -LiteralPath (Join-Path $worktreeOrchestrator "fail-closed-guard-evidence.test.ps1") -Value @'
[CmdletBinding()]
param([string]$Scenario="All",[string]$ExpectedControllerHead="",[string]$SuiteResultOut="")
if((Split-Path -Leaf $SuiteResultOut)-ceq"missing-output.json"){exit 0}
if((Split-Path -Leaf $SuiteResultOut)-ceq"child-failure.json"){exit 29}
$root=Split-Path -Parent $PSScriptRoot
$out=Join-Path $root $SuiteResultOut
[IO.File]::WriteAllText($out,([ordered]@{producer="fail-closed-guard-evidence";scenario=$Scenario;head=$ExpectedControllerHead;output=$SuiteResultOut}|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
exit 0
'@
Set-Content -LiteralPath (Join-Path $worktreeOrchestrator "issue-6254-fail-closed-guard-evidence.test.ps1") -Value @'
[CmdletBinding()]
param([string]$ControllerRoot="",[string]$ExpectedControllerHead="",[string]$SuiteResultOut="")
$out=Join-Path $ControllerRoot $SuiteResultOut
[IO.File]::WriteAllText($out,([ordered]@{producer="issue-6254-fail-closed-guard-evidence";controllerRoot=$ControllerRoot;head=$ExpectedControllerHead;output=$SuiteResultOut}|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
exit 0
'@
Invoke-FixtureGit @("add", "--", ".") | Out-Null
Invoke-FixtureGit @("commit", "-m", "identity seed") | Out-Null
Set-Content -LiteralPath $markerScript -Value @'
param($Path,[int]$Code=0,[int]$DelayMilliseconds=0)
if ($DelayMilliseconds -gt 0) { Start-Sleep -Milliseconds $DelayMilliseconds }
Set-Content -LiteralPath $Path -Value ran
exit $Code
'@
Set-Content -LiteralPath $environmentChildScript -Value @'
param($Path)
[ordered]@{
  nodeOptions = $env:NODE_OPTIONS
  admissionConfigPresent = Test-Path "Env:CHASE_SETS_HEAVY_ADMISSION_CONFIG"
  originalOptionsPresent = Test-Path "Env:CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_NODE_OPTIONS"
  scriptShell = $env:npm_config_script_shell
  originalScriptShellPresent = Test-Path "Env:CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_SCRIPT_SHELL"
  scriptShellMarkerPresent = Test-Path "Env:CHASE_SETS_HEAVY_ADMISSION_PNPM_SCRIPT_SHELL"
} | ConvertTo-Json -Compress | Set-Content -LiteralPath $Path
exit 0
'@
Set-Content -LiteralPath $identityChildScript -Value @'
param($IdentityPath,[int]$DelayMilliseconds=30000)
$process = Get-Process -Id $PID
$identity = [ordered]@{ pid=$PID; processStartUtc=$process.StartTime.ToUniversalTime().ToString("o") }
[IO.File]::WriteAllText($IdentityPath, ($identity | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
Start-Sleep -Milliseconds $DelayMilliseconds
exit 0
'@
Set-Content -LiteralPath $deepWorkerScript -Value @'
param($IdentityPath,[int]$DelayMilliseconds=30000)
$process = Get-Process -Id $PID
$identity = [ordered]@{ pid=$PID; processStartUtc=$process.StartTime.ToUniversalTime().ToString("o") }
[IO.File]::WriteAllText($IdentityPath, ($identity | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
Start-Sleep -Milliseconds $DelayMilliseconds
exit 0
'@
Set-Content -LiteralPath $descendantRelayScript -Value @'
param($IdentityPath,$WorkerIdentityPath,$SpawnSignalPath,$WorkerScript,$ReleaseSignalPath,$ReleaseObservedPath,[int]$DelayMilliseconds=30000)
$process = Get-Process -Id $PID
$identity = [ordered]@{ pid=$PID; processStartUtc=$process.StartTime.ToUniversalTime().ToString("o") }
[IO.File]::WriteAllText($IdentityPath, ($identity | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
while (-not (Test-Path -LiteralPath $SpawnSignalPath -PathType Leaf)) {
  Start-Sleep -Milliseconds 25
}
$start = [Diagnostics.ProcessStartInfo]::new()
$start.FileName = Join-Path $PSHOME "pwsh.exe"
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
[void]$start.ArgumentList.Add("-NoProfile")
[void]$start.ArgumentList.Add("-File")
[void]$start.ArgumentList.Add($WorkerScript)
[void]$start.ArgumentList.Add($WorkerIdentityPath)
[void]$start.ArgumentList.Add("$DelayMilliseconds")
$worker = [Diagnostics.Process]::Start($start)
$worker.WaitForExit()
while (-not (Test-Path -LiteralPath $ReleaseSignalPath -PathType Leaf)) {
  Start-Sleep -Milliseconds 25
}
[IO.File]::WriteAllText($ReleaseObservedPath, "released", [Text.UTF8Encoding]::new($false))
while (Test-Path -LiteralPath $ReleaseSignalPath -PathType Leaf) {
  Start-Sleep -Milliseconds 25
}
exit 0
'@
Set-Content -LiteralPath $descendantChildScript -Value @'
param($IdentityPath,$RelayIdentityPath,$WorkerIdentityPath,$SpawnSignalPath,$RelayScript,$WorkerScript,$ReleaseSignalPath,$ReleaseObservedPath,[int]$DelayMilliseconds=30000)
$process = Get-Process -Id $PID
$identity = [ordered]@{ pid=$PID; processStartUtc=$process.StartTime.ToUniversalTime().ToString("o") }
[IO.File]::WriteAllText($IdentityPath, ($identity | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
$start = [Diagnostics.ProcessStartInfo]::new()
$start.FileName = Join-Path $PSHOME "pwsh.exe"
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
[void]$start.ArgumentList.Add("-NoProfile")
[void]$start.ArgumentList.Add("-File")
[void]$start.ArgumentList.Add($RelayScript)
[void]$start.ArgumentList.Add($RelayIdentityPath)
[void]$start.ArgumentList.Add($WorkerIdentityPath)
[void]$start.ArgumentList.Add($SpawnSignalPath)
[void]$start.ArgumentList.Add($WorkerScript)
[void]$start.ArgumentList.Add($ReleaseSignalPath)
[void]$start.ArgumentList.Add($ReleaseObservedPath)
[void]$start.ArgumentList.Add("$DelayMilliseconds")
[void][Diagnostics.Process]::Start($start)
Start-Sleep -Milliseconds $DelayMilliseconds
exit 0
'@
Set-Content -LiteralPath $runner -Value @'
$parameters = @{
  Gate = "verify:static"
  Worktree = $env:HV_WORKTREE
  Lane = $env:HV_LANE
  ContainerRoot = $env:HV_CONTAINER
  CommandPath = (Join-Path $PSHOME "pwsh.exe")
  CommandArgumentList = @((ConvertFrom-Json $env:HV_CHILD_ARGUMENTS))
}
if (-not [string]::IsNullOrWhiteSpace($env:HV_BRANCH)) {
  $parameters.Branch = $env:HV_BRANCH
  $parameters.ClaimedHead = $env:HV_CLAIMED_HEAD
} elseif (-not [string]::IsNullOrWhiteSpace($env:HV_IMMUTABLE_HEAD)) {
  $parameters.ImmutableHead = $env:HV_IMMUTABLE_HEAD
}
if ([int]$env:HV_IDENTITY_DELAY -gt 0) {
  $parameters.TestDelayIdentityRevalidationMilliseconds = [int]$env:HV_IDENTITY_DELAY
}
if ([int]$env:HV_PUBLICATION_DELAY -gt 0) {
  $parameters.TestDelayChildPublicationMilliseconds = [int]$env:HV_PUBLICATION_DELAY
}
& $env:HV_GUARD @parameters
exit $LASTEXITCODE
'@
Set-Content -LiteralPath $precursorRunner -Value @'
$ErrorActionPreference="Stop"
$parameters=@{
  ControllerPrecursor=$env:HV_PRECURSOR
  ControllerPrecursorArtifactPath=$env:HV_PRECURSOR_OUTPUT
  Worktree=$env:HV_WORKTREE
  Lane=$env:HV_LANE
  ContainerRoot=$env:HV_CONTAINER
}
if(-not[string]::IsNullOrWhiteSpace($env:HV_PRECURSOR_SCENARIO)){$parameters.ControllerPrecursorScenario=$env:HV_PRECURSOR_SCENARIO}
if(-not[string]::IsNullOrWhiteSpace($env:HV_BRANCH)){$parameters.Branch=$env:HV_BRANCH;$parameters.ClaimedHead=$env:HV_CLAIMED_HEAD}
elseif(-not[string]::IsNullOrWhiteSpace($env:HV_IMMUTABLE_HEAD)){$parameters.ImmutableHead=$env:HV_IMMUTABLE_HEAD}
if([int]$env:HV_IDENTITY_DELAY-gt0){$parameters.TestDelayIdentityRevalidationMilliseconds=[int]$env:HV_IDENTITY_DELAY}
if($env:HV_CANCEL-ceq"1"){$parameters.TestCancelAfterAcquisition=$true}
if($env:HV_INJECT_COMMAND-ceq"1"){$parameters.CommandPath=(Join-Path $PSHOME "pwsh.exe");$parameters.CommandArgumentList=@("-NoProfile","-Command","exit 0")}
if($env:HV_INJECT_SCRIPT-ceq"1"){$parameters.ScriptPath=(Join-Path $PSHOME "pwsh.exe")}
if((Get-Command $env:HV_GUARD).Parameters.ContainsKey('ControllerClaimantPid')){
  $parameters.ControllerClaimantPid=$PID
  $parameters.ControllerClaimantStartUtc=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
}
& $env:HV_GUARD @parameters
exit $LASTEXITCODE
'@
function Start-Wrapper(
  [string]$Lane,
  [string[]]$ChildArguments,
  [int]$PublicationDelay = 0,
  [int]$IdentityDelay = 0,
  [hashtable]$Identity = @{}
) {
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = Join-Path $PSHOME "pwsh.exe"
  $start.UseShellExecute = $false
  $start.CreateNoWindow = $true
  [void]$start.ArgumentList.Add("-NoProfile")
  [void]$start.ArgumentList.Add("-File")
  [void]$start.ArgumentList.Add($runner)
  $start.Environment["HV_GUARD"] = $guard
  $start.Environment["HV_WORKTREE"] = $worktree
  $start.Environment["HV_CONTAINER"] = $container
  $start.Environment["HV_LANE"] = $Lane
  if ($Identity.ContainsKey("ImmutableHead")) {
    $start.Environment["HV_BRANCH"] = ""
    $start.Environment["HV_IMMUTABLE_HEAD"] = [string]$Identity.ImmutableHead
  } else {
    $start.Environment["HV_BRANCH"] = $(if ($Identity.ContainsKey("Branch")) { [string]$Identity.Branch } else { "codex/test" })
    $start.Environment["HV_CLAIMED_HEAD"] = $(if ($Identity.ContainsKey("ClaimedHead")) {
      [string]$Identity.ClaimedHead
    } else {
      Invoke-FixtureGit @("rev-parse", "HEAD")
    })
    $start.Environment["HV_IMMUTABLE_HEAD"] = ""
  }
  $start.Environment["HV_CHILD_ARGUMENTS"] = ConvertTo-Json @($ChildArguments) -Compress
  $start.Environment["HV_PUBLICATION_DELAY"] = "$PublicationDelay"
  $start.Environment["HV_IDENTITY_DELAY"] = "$IdentityDelay"
  $wrapper = [Diagnostics.Process]::Start($start)
  $testWrapperIdentities.Add([pscustomobject]@{
    pid = $wrapper.Id
    processStartUtc = $wrapper.StartTime.ToUniversalTime().ToString("o")
  })
  return $wrapper
}
function Get-DefaultPrecursorScenario([string]$Producer) {
  switch ($Producer) {
    "fail-closed-guard-evidence" { return "ReceiptClaims" }
    default { return "" }
  }
}
function Start-PrecursorWrapper(
  [string]$Producer,
  [string]$Output,
  [hashtable]$Extra = @{}
) {
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = Join-Path $PSHOME "pwsh.exe"
  $start.UseShellExecute = $false
  $start.CreateNoWindow = $true
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  [void]$start.ArgumentList.Add("-NoProfile")
  [void]$start.ArgumentList.Add("-File")
  [void]$start.ArgumentList.Add($precursorRunner)
  $start.Environment["HV_GUARD"] = $guard
  $start.Environment["HV_WORKTREE"] = $(if ($Extra.ContainsKey("Worktree")) { [string]$Extra.Worktree } else { $worktree })
  $start.Environment["HV_CONTAINER"] = $container
  $start.Environment["HV_LANE"] = $(if ($Extra.ContainsKey("Lane")) { [string]$Extra.Lane } else { "precursor-test" })
  $start.Environment["HV_PRECURSOR"] = $Producer
  $start.Environment["HV_PRECURSOR_OUTPUT"] = $Output
  $start.Environment["HV_PRECURSOR_SCENARIO"] = $(if ($Extra.ContainsKey("Scenario")) { [string]$Extra.Scenario } else { Get-DefaultPrecursorScenario $Producer })
  if ($Extra.ContainsKey("ImmutableHead")) {
    $start.Environment["HV_BRANCH"] = ""
    $start.Environment["HV_CLAIMED_HEAD"] = ""
    $start.Environment["HV_IMMUTABLE_HEAD"] = [string]$Extra.ImmutableHead
  } else {
    $start.Environment["HV_BRANCH"] = $(if ($Extra.ContainsKey("Branch")) { [string]$Extra.Branch } else { Invoke-FixtureGit @("branch", "--show-current") })
    $start.Environment["HV_CLAIMED_HEAD"] = $(if ($Extra.ContainsKey("ClaimedHead")) { [string]$Extra.ClaimedHead } else { Invoke-FixtureGit @("rev-parse", "HEAD") })
    $start.Environment["HV_IMMUTABLE_HEAD"] = ""
  }
  $start.Environment["HV_IDENTITY_DELAY"] = $(if ($Extra.ContainsKey("IdentityDelay")) { [string]$Extra.IdentityDelay } else { "0" })
  $start.Environment["HV_CANCEL"] = $(if ($Extra.ContainsKey("Cancel") -and $Extra.Cancel) { "1" } else { "0" })
  $start.Environment["HV_INJECT_COMMAND"] = $(if ($Extra.ContainsKey("InjectCommand") -and $Extra.InjectCommand) { "1" } else { "0" })
  $start.Environment["HV_INJECT_SCRIPT"] = $(if ($Extra.ContainsKey("InjectScript") -and $Extra.InjectScript) { "1" } else { "0" })
  $wrapper = [Diagnostics.Process]::Start($start)
  $testWrapperIdentities.Add([pscustomobject]@{
    pid = $wrapper.Id
    processStartUtc = $wrapper.StartTime.ToUniversalTime().ToString("o")
  })
  return $wrapper
}
function Complete-PrecursorWrapper([Diagnostics.Process]$Process, [int]$Seconds = 20) {
  if (-not $Process.WaitForExit($Seconds * 1000)) {
    try { $Process.Kill($true) } catch {}
    throw "ASSERTION FAILED: precursor fixture process did not exit"
  }
  return [pscustomobject]@{
    exitCode = $Process.ExitCode
    output = (($Process.StandardOutput.ReadToEnd() + "`n" + $Process.StandardError.ReadToEnd()).Trim())
  }
}
function Invoke-PrecursorProcess([string]$Producer, [string]$Output, [hashtable]$Extra = @{}) {
  return Complete-PrecursorWrapper (Start-PrecursorWrapper $Producer $Output $Extra)
}
function Invoke-Precursor([string]$Producer, [string]$Output, [hashtable]$Extra = @{}) {
  $parameters = @{
    ControllerPrecursor = $Producer
    ControllerPrecursorArtifactPath = $Output
    Worktree = $(if ($Extra.ContainsKey("Worktree")) { [string]$Extra.Worktree } else { $worktree })
    Lane = $(if ($Extra.ContainsKey("Lane")) { [string]$Extra.Lane } else { "precursor-test" })
    ContainerRoot = $container
  }
  $scenario = $(if ($Extra.ContainsKey("Scenario")) { [string]$Extra.Scenario } else { Get-DefaultPrecursorScenario $Producer })
  if (-not [string]::IsNullOrWhiteSpace($scenario)) { $parameters.ControllerPrecursorScenario = $scenario }
  if ($Extra.ContainsKey("ImmutableHead")) {
    $parameters.ImmutableHead = [string]$Extra.ImmutableHead
  } else {
    $parameters.Branch = $(if ($Extra.ContainsKey("Branch")) { [string]$Extra.Branch } else { Invoke-FixtureGit @("branch", "--show-current") })
    $parameters.ClaimedHead = $(if ($Extra.ContainsKey("ClaimedHead")) { [string]$Extra.ClaimedHead } else { Invoke-FixtureGit @("rev-parse", "HEAD") })
  }
  if ($Extra.ContainsKey("Cancel") -and $Extra.Cancel) { $parameters.TestCancelAfterAcquisition = $true }
  if ($Extra.ContainsKey("InjectCommand") -and $Extra.InjectCommand) {
    $parameters.CommandPath = Join-Path $PSHOME "pwsh.exe"
    $parameters.CommandArgumentList = @("-NoProfile", "-Command", "exit 0")
  }
  if ($Extra.ContainsKey("InjectScript") -and $Extra.InjectScript) {
    $parameters.ScriptPath = Join-Path $PSHOME "pwsh.exe"
  }
  try {
    $observed = (& $guard @parameters 2>&1 | Out-String).Trim()
    $result=[pscustomobject]@{ exitCode = $LASTEXITCODE; output = $observed }
    # These one-shot owner controls do not retry. Withdraw their own ticket so
    # the next case exercises owner validation rather than a previous waiter.
    $queue=Join-Path $container '.orchestrator/controller-verify-queue.json'
    if($result.exitCode-eq73-and(Test-Path $queue)){
      $claims=@((Get-Content $queue -Raw|ConvertFrom-Json).claims|Where-Object{$_.lane-ceq$parameters.Lane})
      if($claims.Count){& $guard @parameters -CancelControllerClaim|Out-Null}
    }
    return $result
  } catch {
    return [pscustomobject]@{ exitCode = 1; output = $_.Exception.Message }
  }
}
function Read-PrecursorArtifact([string]$RelativePath) {
  return Get-Content -LiteralPath (Join-Path $worktree $RelativePath) -Raw -ErrorAction Stop | ConvertFrom-Json -DateKind String -ErrorAction Stop
}
function Read-ChildIdentity([string]$Path) {
  return Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -DateKind String -ErrorAction Stop
}
function Assert-ExactParent($ChildIdentity, $ParentIdentity, [string]$Message) {
  Assert-True (Test-ExactProcess $ChildIdentity) "$Message child identity is exact"
  Assert-True (Test-ExactProcess $ParentIdentity) "$Message parent identity is exact"
  $candidate = @(Get-CimInstance Win32_Process -Filter "ProcessId = $($ChildIdentity.pid)" -ErrorAction Stop)
  Assert-True ($candidate.Count -eq 1 -and
    [int]$candidate[0].ParentProcessId -eq [int]$ParentIdentity.pid) $Message
}
function Invoke-HardKillDiscriminator {
  $childIdentityPath = Join-Path $root "discriminator-child.json"
  $marker = Join-Path $root "discriminator-marker.txt"
  $wrapper = Start-Wrapper "discriminator-owner" @("-NoProfile", "-File", $identityChildScript, $childIdentityPath, "30000")
  $wrapperIdentity = [pscustomobject]@{ pid=$wrapper.Id; processStartUtc=$wrapper.StartTime.ToUniversalTime().ToString("o") }
  Wait-Condition { Test-Path -LiteralPath $childIdentityPath -PathType Leaf } "discriminator child identity publication"
  Wait-Condition { Test-Path -LiteralPath $ownerPath -PathType Leaf } "discriminator owner publication"
  $published = Read-Owner
  if ($published.schemaVersion -eq 2) {
    Wait-Condition { (Read-Owner).state -ceq "started" } "schema-v2 started transition"
  }
  $childIdentity = Read-ChildIdentity $childIdentityPath
  Stop-ExactProcess $wrapperIdentity
  Stop-ExactProcess $childIdentity
  $completed = $false
  try {
    $completed = (Invoke-Guard "discriminator-contender" @("-NoProfile", "-File", $markerScript, $marker, "0")) -eq 0
  } catch {
    $completed = $false
  }
  return $completed -and (Test-Path -LiteralPath $marker) -and -not (Test-Path -LiteralPath $lock)
}
function Invoke-GrandchildHardKillDiscriminator {
  $childIdentityPath = Join-Path $root "grandchild-child.json"
  $relayIdentityPath = Join-Path $root "grandchild-relay.json"
  $workerIdentityPath = Join-Path $root "grandchild-worker.json"
  $spawnSignalPath = Join-Path $root "grandchild-spawn.signal"
  $releaseSignalPath = Join-Path $root "grandchild-release.signal"
  $releaseObservedPath = Join-Path $root "grandchild-release.observed"
  $marker = Join-Path $root "grandchild-contender.txt"
  function Test-RelayLifetimeHandshakeContract([string]$Source) {
    $hasReleaseArguments = $Source -match 'ReleaseSignalPath' -and $Source -match 'ReleaseObservedPath'
    $hasHandshake = $Source -match '(?s)WaitForExit\(\).*?Test-Path -LiteralPath \$ReleaseSignalPath.*?WriteAllText\(\$ReleaseObservedPath'
    $oldSelfExpiry = $Source -match '(?s)WaitForExit\(\)\s*Start-Sleep -Milliseconds \$DelayMilliseconds\s*exit 0'
    return $hasReleaseArguments -and $hasHandshake -and -not $oldSelfExpiry
  }
  $relaySource = Get-Content -LiteralPath $descendantRelayScript -Raw
  Assert-True (Test-RelayLifetimeHandshakeContract $relaySource) "relay lifetime is fixture-handshake-owned"
  $oldRelayShape = @'
$worker.WaitForExit()
Start-Sleep -Milliseconds $DelayMilliseconds
exit 0
'@
  Assert-True (-not (Test-RelayLifetimeHandshakeContract $oldRelayShape)) `
    "elapsed-time relay self-expiry is rejected by the lifecycle control"
  try {
    $wrapper = Start-Wrapper "grandchild-owner" @(
      "-NoProfile", "-File", $descendantChildScript,
      $childIdentityPath, $relayIdentityPath, $workerIdentityPath, $spawnSignalPath,
      $descendantRelayScript, $deepWorkerScript, $releaseSignalPath, $releaseObservedPath, "30000"
    )
    $wrapperIdentity = [pscustomobject]@{
      pid = $wrapper.Id
      processStartUtc = $wrapper.StartTime.ToUniversalTime().ToString("o")
    }
    Wait-Condition { Test-Path -LiteralPath $childIdentityPath -PathType Leaf } "grandchild tracked child identity"
    Wait-Condition { Test-Path -LiteralPath $relayIdentityPath -PathType Leaf } "grandchild relay identity"
    Wait-Condition { $record = Read-Owner; $record -and $record.state -ceq "started" } "grandchild started owner"
    $childIdentity = Read-ChildIdentity $childIdentityPath
    $relayIdentity = Read-ChildIdentity $relayIdentityPath
    $published = Read-Owner
    Assert-True ([int]$published.childPid -eq [int]$childIdentity.pid -and
      [DateTimeOffset]::Parse([string]$published.childProcessStartUtc).ToUniversalTime().Ticks -eq
        [DateTimeOffset]::Parse([string]$childIdentity.processStartUtc).ToUniversalTime().Ticks) "grandchild owner initially tracks the exact child"
    Assert-ExactParent $childIdentity $wrapperIdentity "wrapper -> tracked child topology is exact"
    Assert-ExactParent $relayIdentity $childIdentity "tracked child -> relay topology is exact"

  # Put the inert relay just before a valid ownership boundary and its worker
  # just after it. Once the exact tracked child is killed, its shifted stored
  # timestamp is intentionally uncertain: a one-hop scan ignores the older
  # relay, while a full walk must reach and preserve the later worker.
  Start-Sleep -Milliseconds 25
  $discriminatorStartedAt = [DateTimeOffset]::UtcNow
  Assert-True (
    [DateTimeOffset]::Parse([string]$relayIdentity.processStartUtc).ToUniversalTime().Ticks -lt
      $discriminatorStartedAt.Ticks
  ) "relay predates the discriminator ownership boundary"
  $published.startedUtc = $discriminatorStartedAt.ToString("o")
  $published.childProcessStartUtc = $discriminatorStartedAt.AddTicks(1).ToString("o")
  $grandchildOwnerRaw = $published | ConvertTo-Json -Compress
  [IO.File]::WriteAllText($ownerPath, $grandchildOwnerRaw, [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText($spawnSignalPath, "spawn", [Text.UTF8Encoding]::new($false))
  Wait-Condition { Test-Path -LiteralPath $workerIdentityPath -PathType Leaf } "grandchild deepest worker identity"
  $workerIdentity = Read-ChildIdentity $workerIdentityPath
  Assert-ExactParent $workerIdentity $relayIdentity "relay -> deepest worker topology is exact"
  Assert-True (
    [DateTimeOffset]::Parse([string]$workerIdentity.processStartUtc).ToUniversalTime().Ticks -ge
      $discriminatorStartedAt.Ticks
  ) "deepest worker starts inside the discriminator ownership window"

  Stop-ExactProcess $wrapperIdentity
  Stop-ExactProcess $childIdentity
  Assert-True (Test-ExactProcess $relayIdentity) "grandchild relay remains live after wrapper/child hard-kill"
  Assert-True (Test-ExactProcess $workerIdentity) "deepest exact worker remains live after wrapper/child hard-kill"

  $refused = $false
  try {
    Invoke-Guard "grandchild-contender" @("-NoProfile", "-File", $markerScript, $marker, "0") | Out-Null
  } catch {
    $refused = $true
  }
  Assert-True ($refused -and
    -not (Test-Path -LiteralPath $marker) -and
    (Get-Content -LiteralPath $ownerPath -Raw) -ceq $grandchildOwnerRaw) "deepest live descendant preserves the exact lock and contender never runs"

    Stop-ExactProcess $workerIdentity
    Wait-Condition {
      try {
        $relayChildren = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $($relayIdentity.pid)" -ErrorAction Stop)
        foreach ($relayChild in $relayChildren) {
          $relayChildPid = 0
          if (-not [int]::TryParse([string]$relayChild.ProcessId, [ref]$relayChildPid)) { return $false }
          if ($relayChildPid -eq [int]$workerIdentity.pid) { return $false }
        }
        return $true
      } catch {
        return $false
      }
    } "exact deepest worker absence from relay CIM child view"
    Assert-True (Test-ExactProcess $relayIdentity) "pre-record relay remains exact after deepest worker exit"
    $completed = (Invoke-Guard "grandchild-recovery" @("-NoProfile", "-File", $markerScript, $marker, "0")) -eq 0
    Assert-True (Test-ExactProcess $relayIdentity) "handshake-owned relay remains exact after recovery"
    [IO.File]::WriteAllText($releaseSignalPath, "release", [Text.UTF8Encoding]::new($false))
    Wait-Condition { Test-Path -LiteralPath $releaseObservedPath -PathType Leaf } "relay release acknowledgement"
    Assert-True (Test-ExactProcess $relayIdentity) "relay remains live after explicit release acknowledgement"
    Stop-ExactProcess $relayIdentity
    return $completed -and (Test-Path -LiteralPath $marker) -and -not (Test-Path -LiteralPath $lock)
  } finally {
    foreach ($path in @($releaseObservedPath, $releaseSignalPath)) {
      if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
  }
}
function Assert-StalePreparedBranchRefused(
  [string]$Scenario,
  [string]$ClaimedBranch,
  [string]$ClaimedHead
) {
  $liveBranch = Invoke-FixtureGit @("branch", "--show-current")
  $liveHead = Invoke-FixtureGit @("rev-parse", "HEAD")
  Assert-True ($liveBranch -ceq $ClaimedBranch -and $liveHead -cne $ClaimedHead) "$Scenario control retains the branch name while changing its exact HEAD"

  $marker = Join-Path $root "stale-$Scenario-negative-control.txt"
  $live = Get-ProcessIdentity $PID
  $existingOwner = New-OwnerRecord ("7" * 32) $live.pid $live.processStartUtc "launching"
  $existingOwner.startedUtc = [DateTime]::UtcNow.ToString("o")
  Write-Owner $existingOwner
  $existingRaw = Get-Content -LiteralPath $ownerPath -Raw
  $refused = $false
  try {
    Invoke-Guard "lane-stale-$Scenario" @("-NoProfile", "-File", $markerScript, $marker, "0") @{
      Branch = $ClaimedBranch
      ClaimedHead = $ClaimedHead
    } | Out-Null
  } catch {
    $refused = $_.Exception.Message -match "exact launch-time HEAD does not match the live Git HEAD"
  }
  Assert-True ($refused -and
    -not (Test-Path -LiteralPath $marker) -and
    (Get-Content -LiteralPath $ownerPath -Raw) -ceq $existingRaw) "$Scenario stale caller refuses before its body and preserves the existing valid owner byte-exact"
  Remove-DisposableLock
}
function Get-DeadFixturePid([int]$Exclude = 0) {
  for ($candidatePid = 999999; $candidatePid -gt 999000; $candidatePid--) {
    if ($candidatePid -ne $Exclude -and
        @(Microsoft.PowerShell.Management\Get-Process -Id $candidatePid -ErrorAction SilentlyContinue).Count -eq 0) {
      return $candidatePid
    }
  }
  throw "ASSERTION FAILED: unable to reserve a dead fixture PID"
}
function Invoke-RulingFourContender([ValidateSet("platform", "controller")][string]$Slot, [string]$Scenario) {
  if ($Slot -ceq "controller") {
    $relativeOutput = ".orchestrator/artifacts/ruling-four-$Slot-$Scenario.json"
    $result = Invoke-Precursor "fail-closed-guard-evidence" $relativeOutput
    return [pscustomobject]@{
      exitCode = $result.exitCode
      output = $result.output
      bodyRan = Test-Path -LiteralPath (Join-Path $worktree $relativeOutput) -PathType Leaf
    }
  }
  $marker = Join-Path $root "ruling-four-$Slot-$Scenario.txt"
  try {
    $exitCode = Invoke-Guard "ruling-four-$Scenario" @("-NoProfile", "-File", $markerScript, $marker, "0")
    return [pscustomobject]@{ exitCode = $exitCode; output = ""; bodyRan = Test-Path -LiteralPath $marker -PathType Leaf }
  } catch {
    return [pscustomobject]@{ exitCode = 1; output = $_.Exception.Message; bodyRan = Test-Path -LiteralPath $marker -PathType Leaf }
  }
}
function Assert-RulingFourForCurrentSlot([ValidateSet("platform", "controller")][string]$Slot) {
  $deadWrapperPid = Get-DeadFixturePid

  $liveChild = Get-ProcessIdentity $PID
  $actualChildStart = [DateTimeOffset]::Parse([string]$liveChild.processStartUtc).ToUniversalTime()
  $recordedChildStart = $actualChildStart.AddTicks(-1)
  $reusedOwner = New-OwnerRecord ("1" * 32) $deadWrapperPid "2000-01-01T00:00:00.0000000Z" `
    "started" $liveChild.pid $recordedChildStart.ToString("o")
  $reusedOwner.startedUtc = $recordedChildStart.AddSeconds(-1).ToString("o")
  Write-Owner $reusedOwner
  $reusedResult = Invoke-RulingFourContender $Slot "reused-child"
  Assert-True ($reusedResult.exitCode -eq 0 -and $reusedResult.bodyRan -and
    -not (Test-Path -LiteralPath $lock) -and (Test-ExactProcess $liveChild)) `
    "$Slot slot reclaims an actual dead-wrapper/reused-child owner, re-acquires, runs, and leaves the reused process untouched"

  $liveOwner = New-OwnerRecord ("2" * 32) $deadWrapperPid "2000-01-01T00:00:00.0000000Z" `
    "started" $liveChild.pid $actualChildStart.ToString("o")
  $liveOwner.startedUtc = $actualChildStart.AddSeconds(-1).ToString("o")
  Write-Owner $liveOwner
  $liveRaw = Get-Content -LiteralPath $ownerPath -Raw
  $liveResult = Invoke-RulingFourContender $Slot "exact-live-child"
  Assert-True ($liveResult.exitCode -ne 0 -and -not $liveResult.bodyRan -and
    ($Slot -ceq "controller" -or $liveResult.output -match "live-owner") -and
    (Get-Content -LiteralPath $ownerPath -Raw) -ceq $liveRaw) `
    "$Slot slot refuses an exact-start live child and preserves its owner byte-exact"
  Remove-DisposableLock

  foreach ($identityFault in @("unreadable", "multiple")) {
    $faultPid = Get-DeadFixturePid $deadWrapperPid
    $faultStart = [DateTimeOffset]::UtcNow.AddMinutes(-1)
    $faultOwner = New-OwnerRecord (($(if ($identityFault -ceq "unreadable") { "3" } else { "4" })) * 32) `
      $deadWrapperPid "2000-01-01T00:00:00.0000000Z" "started" $faultPid $faultStart.ToString("o")
    $faultOwner.startedUtc = $faultStart.AddSeconds(-1).ToString("o")
    Write-Owner $faultOwner
    $faultRaw = Get-Content -LiteralPath $ownerPath -Raw
    $global:HeavyVerifierFaultPid = $faultPid
    $global:HeavyVerifierFaultMode = $identityFault
    function global:Get-Process {
      [CmdletBinding()]
      param([int[]]$Id)
      if ($Id.Count -eq 1 -and $Id[0] -eq $global:HeavyVerifierFaultPid) {
        if ($global:HeavyVerifierFaultMode -ceq "unreadable") {
          throw [UnauthorizedAccessException]::new("synthetic unreadable process identity")
        }
        return @(
          [pscustomobject]@{ Id = $Id[0]; StartTime = [DateTime]::UtcNow },
          [pscustomobject]@{ Id = $Id[0]; StartTime = [DateTime]::UtcNow }
        )
      }
      return Microsoft.PowerShell.Management\Get-Process @PSBoundParameters
    }
    try {
      $faultResult = Invoke-RulingFourContender $Slot "$identityFault-child"
    } finally {
      Remove-Item Function:\Get-Process -Force
      Remove-Variable HeavyVerifierFaultPid, HeavyVerifierFaultMode -Scope Global -ErrorAction SilentlyContinue
    }
    Assert-True ($faultResult.exitCode -ne 0 -and -not $faultResult.bodyRan -and
      ($Slot -ceq "controller" -or $faultResult.output -match "ambiguous-owner") -and
      (Get-Content -LiteralPath $ownerPath -Raw) -ceq $faultRaw) `
      "$Slot slot keeps an $identityFault child identity ambiguous and preserves its owner byte-exact"
    Remove-DisposableLock
  }
  Write-Output "PASS heavy verifier ruling 4 reclamation and ambiguity controls ($Slot slot)"
}

try {
  Assert-DisposableRoot
  Assert-True (-not ($PrecursorOnly -and $LegacyOnly)) "PrecursorOnly and LegacyOnly are mutually exclusive"
  if ($RulingFourOnly) {
    $platformLock = $lock
    $platformOwnerPath = $ownerPath
    $lock = Join-Path $orchestrator "controller-verify-lock.d"
    $ownerPath = Join-Path $lock "owner.json"
    Assert-RulingFourForCurrentSlot "controller"
    $lock = $platformLock
    $ownerPath = $platformOwnerPath
    Assert-RulingFourForCurrentSlot "platform"
    Write-Output "PASS heavy verifier ruling 4 both-slot discriminator"
    return
  }
  if (-not $LegacyOnly) {
  Assert-PrecursorAdmissionSurface (Get-Content -LiteralPath $guard -Raw)

  # Controller precursors take the controller slot (Todd ruling 2026-09-10).
  # Every lock assertion in this block reads that slot; the platform lock must
  # stay absent throughout and is restored as the subject afterwards.
  $platformLock = $lock
  $platformOwnerPath = $ownerPath
  $lock = Join-Path $orchestrator "controller-verify-lock.d"
  $ownerPath = Join-Path $lock "owner.json"

  # The artifact root itself may never redirect producer output outside the
  # fixture worktree. This runs before any positive artifact is created.
  $precursorReparseTarget = Join-Path $root "precursor-reparse-target"
  New-Item -ItemType Directory -Path $precursorReparseTarget | Out-Null
  New-Item -ItemType Junction -Path $artifacts -Target $precursorReparseTarget | Out-Null
  $reparseAttempt = Invoke-Precursor "fail-closed-guard-evidence" ".orchestrator/artifacts/reparse-escape.json"
  Assert-True ($reparseAttempt.exitCode -ne 0 -and
    $reparseAttempt.output -match "reparse point" -and
    -not (Test-Path -LiteralPath (Join-Path $precursorReparseTarget "reparse-escape.json")) -and
    -not (Test-Path -LiteralPath $lock)) "precursor artifact-root reparse escape refuses before child and lock acquisition (observed=$($reparseAttempt.output))"
  Remove-Item -LiteralPath $artifacts -Force
  Assert-True (-not (Test-Path -LiteralPath $artifacts) -and (Test-Path -LiteralPath $precursorReparseTarget)) `
    "precursor reparse control removes only its disposable junction"
  Remove-Item -LiteralPath $precursorReparseTarget -Recurse -Force

  # Both remaining guard-evidence producers resolve through the real create-only
  # lock path to their exact tracked script and fixed safe argument grammar.
  $checkerOut = ".orchestrator/artifacts/checker-positive.json"
  $productionOut = ".orchestrator/artifacts/production-positive.json"
  $checkerResult = Invoke-Precursor "fail-closed-guard-evidence" $checkerOut
  Assert-True ($checkerResult.exitCode -eq 0) "checker precursor mapping succeeds through shared admission"
  $checkerArtifact = Read-PrecursorArtifact $checkerOut
  Assert-True ($checkerArtifact.producer -ceq "fail-closed-guard-evidence" -and
    $checkerArtifact.scenario -ceq "ReceiptClaims" -and
    $checkerArtifact.head -ceq (Invoke-FixtureGit @("rev-parse", "HEAD"))) "checker mapping fixes script, ReceiptClaims scenario, and exact head"

  $productionResult = Invoke-Precursor "issue-6254-fail-closed-guard-evidence" $productionOut
  Assert-True ($productionResult.exitCode -eq 0) "#6254 production precursor mapping succeeds through shared admission"
  $productionArtifact = Read-PrecursorArtifact $productionOut
  Assert-True ($productionArtifact.producer -ceq "issue-6254-fail-closed-guard-evidence" -and
    [IO.Path]::GetFullPath([string]$productionArtifact.controllerRoot) -ceq [IO.Path]::GetFullPath($worktree) -and
    $productionArtifact.head -ceq (Invoke-FixtureGit @("rev-parse", "HEAD"))) "#6254 mapping fixes script, controller root, and exact head"

  # Producer, scenario, command, script, and free-form argument substitution
  # are all outside the ControllerPrecursor parameter set.
  $unknownOut = ".orchestrator/artifacts/unknown-producer.json"
  $unknownProducer = Invoke-Precursor "not-a-producer" $unknownOut
  Assert-True ($unknownProducer.exitCode -ne 0 -and $unknownProducer.output -match "ValidateSet" -and
    -not (Test-Path -LiteralPath (Join-Path $worktree $unknownOut))) "unknown precursor producer is rejected by the closed allowlist"
  $wrongScenarioOut = ".orchestrator/artifacts/wrong-scenario.json"
  $wrongScenario = Invoke-Precursor "fail-closed-guard-evidence" $wrongScenarioOut @{ Scenario = "All" }
  Assert-True ($wrongScenario.exitCode -ne 0 -and $wrongScenario.output -match "ValidateSet" -and
    -not (Test-Path -LiteralPath (Join-Path $worktree $wrongScenarioOut))) "producer-specific scenario substitution is refused"
  $issueScenarioOut = ".orchestrator/artifacts/issue-scenario.json"
  $issueScenario = Invoke-Precursor "issue-6254-fail-closed-guard-evidence" $issueScenarioOut @{ Scenario = "ReceiptClaims" }
  Assert-True ($issueScenario.exitCode -ne 0 -and $issueScenario.output -match "does not accept a scenario" -and
    -not (Test-Path -LiteralPath (Join-Path $worktree $issueScenarioOut))) "scenario-free producer rejects scenario injection"
  $commandOut = ".orchestrator/artifacts/command-injection.json"
  $commandInjection = Invoke-Precursor "fail-closed-guard-evidence" $commandOut @{ InjectCommand = $true }
  Assert-True ($commandInjection.exitCode -ne 0 -and
    $commandInjection.output -match "parameter set" -and
    -not (Test-Path -LiteralPath (Join-Path $worktree $commandOut))) "CommandPath and arbitrary argument list are unavailable to ControllerPrecursor"
  $scriptOut = ".orchestrator/artifacts/script-injection.json"
  $scriptInjection = Invoke-Precursor "fail-closed-guard-evidence" $scriptOut @{ InjectScript = $true }
  Assert-True ($scriptInjection.exitCode -ne 0 -and
    $scriptInjection.output -match "ScriptPath" -and
    -not (Test-Path -LiteralPath (Join-Path $worktree $scriptOut))) "arbitrary script substitution is unavailable to ControllerPrecursor"

  foreach ($invalidPath in @(
      [ordered]@{ name = "traversal"; value = ".orchestrator/artifacts/../escape.json" },
      [ordered]@{ name = "absolute"; value = (Join-Path $root "external.json") },
      [ordered]@{ name = "location"; value = ".orchestrator/not-artifacts.json" },
      [ordered]@{ name = "nested"; value = ".orchestrator/artifacts/nested/output.json" },
      [ordered]@{ name = "extension"; value = ".orchestrator/artifacts/output.txt" }
    )) {
    $invalid = Invoke-Precursor "fail-closed-guard-evidence" $invalidPath.value
    $invalidFull = if ([IO.Path]::IsPathFullyQualified([string]$invalidPath.value)) {
      [string]$invalidPath.value
    } else {
      Join-Path $worktree $invalidPath.value
    }
    Assert-True ($invalid.exitCode -ne 0 -and -not (Test-Path -LiteralPath $invalidFull) -and
      -not (Test-Path -LiteralPath $lock)) "precursor $($invalidPath.name) output path is rejected before body"
  }

  $preexistingOut = ".orchestrator/artifacts/preexisting.json"
  $preexistingFull = Join-Path $worktree $preexistingOut
  [IO.File]::WriteAllText($preexistingFull, "authoritative-preserve", [Text.UTF8Encoding]::new($false))
  $preexisting = Invoke-Precursor "fail-closed-guard-evidence" $preexistingOut
  Assert-True ($preexisting.exitCode -ne 0 -and $preexisting.output -match "already exists" -and
    [IO.File]::ReadAllText($preexistingFull) -ceq "authoritative-preserve" -and
    -not (Test-Path -LiteralPath $lock)) "pre-existing authoritative output is preserved byte-exact and never overwritten"

  $missingOut = ".orchestrator/artifacts/missing-output.json"
  $missing = Invoke-Precursor "fail-closed-guard-evidence" $missingOut
  Assert-True ($missing.exitCode -ne 0 -and $missing.output -match "succeeded without its required safe output" -and
    -not (Test-Path -LiteralPath (Join-Path $worktree $missingOut)) -and
    -not (Test-Path -LiteralPath $lock)) "successful child without required output fails closed and releases its exact lock"

  $dirtyPath = Join-Path $worktree "dirty-precursor.txt"
  [IO.File]::WriteAllText($dirtyPath, "dirty", [Text.UTF8Encoding]::new($false))
  $dirtyOut = ".orchestrator/artifacts/dirty.json"
  $dirty = Invoke-Precursor "fail-closed-guard-evidence" $dirtyOut
  Assert-True ($dirty.exitCode -ne 0 -and $dirty.output -match "clean exact-head worktree" -and
    -not (Test-Path -LiteralPath (Join-Path $worktree $dirtyOut)) -and
    -not (Test-Path -LiteralPath $lock)) "dirty precursor worktree refuses before admission"
  Remove-Item -LiteralPath $dirtyPath -Force

  $wrongHeadOut = ".orchestrator/artifacts/wrong-head.json"
  $wrongHead = Invoke-Precursor "fail-closed-guard-evidence" $wrongHeadOut @{ ClaimedHead = ("0" * 40) }
  Assert-True ($wrongHead.exitCode -ne 0 -and $wrongHead.output -match "exact launch-time HEAD" -and
    -not (Test-Path -LiteralPath (Join-Path $worktree $wrongHeadOut))) "precursor wrong exact head refuses before lock and body"
  $wrongBranchOut = ".orchestrator/artifacts/wrong-branch.json"
  $wrongBranch = Invoke-Precursor "fail-closed-guard-evidence" $wrongBranchOut @{ Branch = "codex/not-live" }
  Assert-True ($wrongBranch.exitCode -ne 0 -and $wrongBranch.output -match "does not match the live Git branch" -and
    -not (Test-Path -LiteralPath (Join-Path $worktree $wrongBranchOut))) "precursor wrong branch refuses before lock and body"
  $wrongWorktreeOut = ".orchestrator/artifacts/wrong-worktree.json"
  $wrongWorktree = Invoke-Precursor "fail-closed-guard-evidence" $wrongWorktreeOut @{ Worktree = $artifacts }
  Assert-True ($wrongWorktree.exitCode -ne 0 -and $wrongWorktree.output -match "canonical Git worktree root" -and
    -not (Test-Path -LiteralPath (Join-Path $worktree $wrongWorktreeOut))) "precursor noncanonical worktree identity refuses before lock and body"

  $headMoveOut = ".orchestrator/artifacts/head-movement.json"
  $headMover = Start-PrecursorWrapper "fail-closed-guard-evidence" $headMoveOut @{ IdentityDelay = 900 }
  Wait-Condition { $record = Read-Owner; $record -and $record.state -ceq "launching" } "precursor HEAD-movement acquisition"
  Invoke-FixtureGit @("commit", "--allow-empty", "-m", "precursor head movement") | Out-Null
  $headMoved = Complete-PrecursorWrapper $headMover
  Assert-True ($headMoved.exitCode -ne 0 -and $headMoved.output -match "branch or HEAD changed after acquisition" -and
    -not (Test-Path -LiteralPath (Join-Path $worktree $headMoveOut)) -and
    -not (Test-Path -LiteralPath $lock)) "precursor HEAD movement refuses before child and cleans only its owner"

  $branchMoveOut = ".orchestrator/artifacts/branch-movement.json"
  $branchMover = Start-PrecursorWrapper "fail-closed-guard-evidence" $branchMoveOut @{ IdentityDelay = 900 }
  Wait-Condition { $record = Read-Owner; $record -and $record.state -ceq "launching" } "precursor branch-movement acquisition"
  Invoke-FixtureGit @("checkout", "-b", "codex/precursor-moved") | Out-Null
  $branchMoved = Complete-PrecursorWrapper $branchMover
  Assert-True ($branchMoved.exitCode -ne 0 -and $branchMoved.output -match "branch or HEAD changed after acquisition" -and
    -not (Test-Path -LiteralPath (Join-Path $worktree $branchMoveOut)) -and
    -not (Test-Path -LiteralPath $lock)) "precursor branch movement refuses before child and cleans only its owner"
  Invoke-FixtureGit @("checkout", "codex/test") | Out-Null

  $worktreeMoveOut = ".orchestrator/artifacts/worktree-movement.json"
  $movedWorktree = Join-Path $container "lane moved during acquisition"
  Assert-True ((Split-Path -Parent ([IO.Path]::GetFullPath($movedWorktree))) -ceq [IO.Path]::GetFullPath($container) -and
    -not (Test-Path -LiteralPath $movedWorktree)) "worktree movement target is one new child of the disposable container"
  $worktreeMover = Start-PrecursorWrapper "fail-closed-guard-evidence" $worktreeMoveOut @{ IdentityDelay = 900 }
  Wait-Condition { $record = Read-Owner; $record -and $record.state -ceq "launching" } "precursor worktree-movement acquisition"
  [IO.Directory]::Move($worktree, $movedWorktree)
  try {
    $worktreeMoved = Complete-PrecursorWrapper $worktreeMover
  } finally {
    [IO.Directory]::Move($movedWorktree, $worktree)
  }
  Assert-True ($worktreeMoved.exitCode -ne 0 -and $worktreeMoved.output -match "unable to resolve live Git worktree" -and
    -not (Test-Path -LiteralPath (Join-Path $worktree $worktreeMoveOut)) -and
    -not (Test-Path -LiteralPath $lock)) "precursor canonical worktree movement refuses before child and cleans only its owner"

  $live = Get-ProcessIdentity $PID
  $precursorLiveOwner = New-OwnerRecord ("6" * 32) $live.pid $live.processStartUtc "launching"
  $precursorLiveOwner.startedUtc = [DateTime]::UtcNow.ToString("o")
  Write-Owner $precursorLiveOwner
  $precursorLiveRaw = Get-Content -LiteralPath $ownerPath -Raw
  $liveOut = ".orchestrator/artifacts/live-owner.json"
  $liveRefusal = Invoke-PrecursorProcess "fail-closed-guard-evidence" $liveOut
  Assert-True ($liveRefusal.exitCode -eq 73 -and $liveRefusal.output -match "live-owner" -and
    -not (Test-Path -LiteralPath (Join-Path $worktree $liveOut)) -and
    (Get-Content -LiteralPath $ownerPath -Raw) -ceq $precursorLiveRaw) "live owner exits 73 with no child/artifact and preserves owner byte-exact"
  Remove-DisposableLock

  $failureOut = ".orchestrator/artifacts/child-failure.json"
  $failure = Invoke-Precursor "fail-closed-guard-evidence" $failureOut
  Assert-True ($failure.exitCode -eq 29 -and -not (Test-Path -LiteralPath (Join-Path $worktree $failureOut)) -and
    -not (Test-Path -LiteralPath $lock)) "precursor child failure propagates and releases only after its foreground tree exits"
  $cancelOut = ".orchestrator/artifacts/cancelled.json"
  $cancel = Invoke-Precursor "fail-closed-guard-evidence" $cancelOut @{ Cancel = $true }
  Assert-True ($cancel.exitCode -ne 0 -and $cancel.output -match "test cancellation" -and
    -not (Test-Path -LiteralPath (Join-Path $worktree $cancelOut)) -and
    -not (Test-Path -LiteralPath $lock)) "precursor cancellation creates no artifact and releases its exact lock"

  # A live PLATFORM owner never blocks a controller precursor, and the
  # precursor never touches that owner (Todd ruling 2026-09-10).
  New-Item -ItemType Directory -Path $platformLock -ErrorAction Stop | Out-Null
  $platformOwner = New-OwnerRecord ("5" * 32) $live.pid $live.processStartUtc "launching"
  $platformOwner.startedUtc = [DateTime]::UtcNow.ToString("o")
  [IO.File]::WriteAllText($platformOwnerPath, ($platformOwner | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
  $platformRaw = Get-Content -LiteralPath $platformOwnerPath -Raw
  $besideOut = ".orchestrator/artifacts/beside-platform-owner.json"
  $beside = Invoke-Precursor "fail-closed-guard-evidence" $besideOut
  Assert-True ($beside.exitCode -eq 0 -and
    (Test-Path -LiteralPath (Join-Path $worktree $besideOut)) -and
    -not (Test-Path -LiteralPath $lock) -and
    (Get-Content -LiteralPath $platformOwnerPath -Raw) -ceq $platformRaw) "controller precursor runs beside a live platform owner, releases its own slot, and leaves the platform owner byte-exact"
  Remove-Item -LiteralPath $platformLock -Recurse -Force
  Assert-True (-not (Test-Path -LiteralPath $platformLock)) "controller precursors never create the platform lock"

  # Coordination mutexes are per slot (r3 F3): a held PLATFORM coordination
  # mutex never delays controller acquisition, and a held CONTROLLER
  # coordination mutex never delays a platform gate. Both bounded; on a shared
  # key either side blocks past its bound and the assertion fails.
  $coordinationRoot = ([IO.Path]::GetFullPath($container).TrimEnd('\','/')).ToUpperInvariant()
  $platformCoordination = [Threading.Mutex]::new($false, ("Global\chase-sets-heavy-verifier-" + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($coordinationRoot))).ToLowerInvariant()))
  Assert-True ($platformCoordination.WaitOne(5000)) "test holds the platform coordination mutex"
  try {
    $besideMutexOut = ".orchestrator/artifacts/beside-platform-mutex.json"
    $besideMutex = Complete-PrecursorWrapper (Start-PrecursorWrapper "fail-closed-guard-evidence" $besideMutexOut) 20
    Assert-True ($besideMutex.exitCode -eq 0 -and
      (Test-Path -LiteralPath (Join-Path $worktree $besideMutexOut)) -and
      -not (Test-Path -LiteralPath $lock)) "controller precursor acquires, succeeds, and releases while the platform coordination mutex is held"
  } finally {
    $platformCoordination.ReleaseMutex()
    $platformCoordination.Dispose()
  }
  $controllerCoordination = [Threading.Mutex]::new($false, ("Global\chase-sets-heavy-verifier-" + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($coordinationRoot + "`n" + "controller-verify-lock.d"))).ToLowerInvariant()))
  Assert-True ($controllerCoordination.WaitOne(5000)) "test holds the controller coordination mutex"
  try {
    $besideControllerMarker = Join-Path $root "beside-controller-mutex.txt"
    $platformWrapper = Start-Wrapper "beside-controller-mutex" @("-NoProfile", "-File", $markerScript, $besideControllerMarker, "0")
    if (-not $platformWrapper.WaitForExit(20000)) {
      try { $platformWrapper.Kill($true) } catch {}
      throw "ASSERTION FAILED: platform gate waited on the controller coordination mutex"
    }
    Assert-True ($platformWrapper.ExitCode -eq 0 -and
      (Test-Path -LiteralPath $besideControllerMarker) -and
      -not (Test-Path -LiteralPath $platformLock)) "platform gate acquires, runs, and releases while the controller coordination mutex is held"
  } finally {
    $controllerCoordination.ReleaseMutex()
    $controllerCoordination.Dispose()
  }
  Assert-RulingFourForCurrentSlot "controller"
  Write-Output "PASS heavy verifier per-slot coordination mutexes never delay the other slot"
  $lock = $platformLock
  $ownerPath = $platformOwnerPath
  Write-Output "PASS heavy verifier ControllerPrecursor production-shaped coverage"
  }
  if ($PrecursorOnly) { return }

  Assert-RulingFourForCurrentSlot "platform"
  Assert-True (Invoke-HardKillDiscriminator) "hard-kill discriminator reclaims an exact dead wrapper/child lock"
  Assert-True (Invoke-GrandchildHardKillDiscriminator) "grandchild discriminator refuses reclamation until the deepest exact process exits"
  if ($DiscriminatorOnly) {
    Write-Output "PASS heavy verifier hard-kill discriminator"
    Write-Output "PASS heavy verifier grandchild hard-kill discriminator"
    return
  }

  # A branch-mode caller is a launch-time branch + exact-HEAD claim. Reusing
  # the same branch name after every common ref movement must fail before lock
  # inspection, leaving an existing valid owner byte-for-byte unchanged.
  Invoke-FixtureGit @("checkout", "codex/test") | Out-Null
  $advanceBranch = "codex/stale-advance"
  Invoke-FixtureGit @("checkout", "-b", $advanceBranch) | Out-Null
  $advanceClaim = Invoke-FixtureGit @("rev-parse", "HEAD")
  Invoke-FixtureGit @("commit", "--allow-empty", "-m", "advance branch") | Out-Null
  Assert-StalePreparedBranchRefused "advance" $advanceBranch $advanceClaim
  Invoke-FixtureGit @("checkout", "codex/test") | Out-Null

  $rebaseUpstream = "codex/stale-rebase-upstream"
  Invoke-FixtureGit @("checkout", "-b", $rebaseUpstream) | Out-Null
  Invoke-FixtureGit @("commit", "--allow-empty", "-m", "new rebase base") | Out-Null
  Invoke-FixtureGit @("checkout", "-b", "codex/stale-rebase", "codex/test") | Out-Null
  Invoke-FixtureGit @("commit", "--allow-empty", "-m", "prepared rebase caller") | Out-Null
  $rebaseClaim = Invoke-FixtureGit @("rev-parse", "HEAD")
  Invoke-FixtureGit @("rebase", "--onto", $rebaseUpstream, "codex/test") | Out-Null
  Assert-StalePreparedBranchRefused "rebase" "codex/stale-rebase" $rebaseClaim
  Invoke-FixtureGit @("checkout", "codex/test") | Out-Null

  $resetBranch = "codex/stale-reset"
  Invoke-FixtureGit @("checkout", "-b", $resetBranch) | Out-Null
  Invoke-FixtureGit @("commit", "--allow-empty", "-m", "prepared reset caller") | Out-Null
  $resetClaim = Invoke-FixtureGit @("rev-parse", "HEAD")
  Invoke-FixtureGit @("reset", "--hard", "codex/test") | Out-Null
  Assert-StalePreparedBranchRefused "reset" $resetBranch $resetClaim
  Invoke-FixtureGit @("checkout", "codex/test") | Out-Null

  $reusedBranch = "codex/stale-reused"
  Invoke-FixtureGit @("checkout", "-b", $reusedBranch) | Out-Null
  Invoke-FixtureGit @("commit", "--allow-empty", "-m", "prepared reused caller") | Out-Null
  $reusedClaim = Invoke-FixtureGit @("rev-parse", "HEAD")
  Invoke-FixtureGit @("checkout", "codex/test") | Out-Null
  Invoke-FixtureGit @("branch", "-D", $reusedBranch) | Out-Null
  Invoke-FixtureGit @("checkout", "-b", $reusedBranch, $rebaseUpstream) | Out-Null
  Assert-StalePreparedBranchRefused "reused" $reusedBranch $reusedClaim
  Invoke-FixtureGit @("checkout", "codex/test") | Out-Null

  # A caller prepared for branch A must fail before acquiring when the same
  # persistent worktree has moved to a different branch and commit.
  Invoke-FixtureGit @("checkout", "-b", "codex/reuse-a") | Out-Null
  $delayedBranchACaller = @{
    Branch = "codex/reuse-a"
    ClaimedHead = Invoke-FixtureGit @("rev-parse", "HEAD")
  }
  Invoke-FixtureGit @("checkout", "-b", "codex/reuse-b") | Out-Null
  Invoke-FixtureGit @("commit", "--allow-empty", "-m", "branch B differs") | Out-Null
  $staleBranchMarker = Join-Path $root "stale-branch-negative-control.txt"
  $staleBranchFailed = $false
  try {
    Invoke-Guard "lane-stale-branch" @("-NoProfile", "-File", $markerScript, $staleBranchMarker, "0") $delayedBranchACaller | Out-Null
  } catch {
    $staleBranchFailed = $_.Exception.Message -match "does not match the live Git branch"
  }
  Assert-True ($staleBranchFailed -and
    -not (Test-Path -LiteralPath $staleBranchMarker) -and
    -not (Test-Path -LiteralPath $lock)) "reused-worktree stale branch refuses before body and owner creation"

  # Branch names are identity, even when both happen to point at one commit.
  Invoke-FixtureGit @("checkout", "codex/test") | Out-Null
  Invoke-FixtureGit @("branch", "codex/reuse-same-a") | Out-Null
  $sameCommitHead = Invoke-FixtureGit @("rev-parse", "HEAD")
  Invoke-FixtureGit @("checkout", "-b", "codex/reuse-same-b") | Out-Null
  Assert-True ((Invoke-FixtureGit @("rev-parse", "HEAD")) -ceq $sameCommitHead) "same-commit discriminator controls the commit"
  $sameCommitMarker = Join-Path $root "same-commit-stale-branch-negative-control.txt"
  $sameCommitFailed = $false
  try {
    Invoke-Guard "lane-same-commit-stale" @("-NoProfile", "-File", $markerScript, $sameCommitMarker, "0") @{
      Branch = "codex/reuse-same-a"
      ClaimedHead = $sameCommitHead
    } | Out-Null
  } catch {
    $sameCommitFailed = $_.Exception.Message -match "does not match the live Git branch"
  }
  Assert-True ($sameCommitFailed -and
    -not (Test-Path -LiteralPath $sameCommitMarker) -and
    -not (Test-Path -LiteralPath $lock)) "same-commit different-branch caller refuses before body and owner creation"
  Invoke-FixtureGit @("checkout", "codex/test") | Out-Null

  # HEAD drift after owner acquisition is caught before the guarded child is
  # created, with the marker providing an observable negative control.
  $headDriftMarker = Join-Path $root "head-drift-negative-control.txt"
  $headDriftWrapper = Start-Wrapper "lane-head-drift" @("-NoProfile", "-File", $markerScript, $headDriftMarker, "0") 0 1200
  Wait-Condition { $record = Read-Owner; $record -and $record.schemaVersion -eq 4 -and $record.state -ceq "launching" } "HEAD-drift acquisition"
  Invoke-FixtureGit @("commit", "--allow-empty", "-m", "launch-window HEAD drift") | Out-Null
  Assert-True ($headDriftWrapper.WaitForExit(10000)) "HEAD-drift wrapper exits within ten seconds"
  Assert-True ($headDriftWrapper.ExitCode -ne 0 -and
    -not (Test-Path -LiteralPath $headDriftMarker) -and
    -not (Test-Path -LiteralPath $lock)) "launch-window HEAD drift refuses the child body and releases its exact owner"

  # Detached reviews require an explicit exact immutable SHA. Matching state is
  # admitted; a detached HEAD change in the acquisition window is refused.
  $detachedHead = Invoke-FixtureGit @("rev-parse", "HEAD")
  Invoke-FixtureGit @("checkout", "--detach", $detachedHead) | Out-Null
  $detachedWrongMarker = Join-Path $root "detached-wrong-head-negative-control.txt"
  $detachedWrongFailed = $false
  try {
    Invoke-Guard "lane-detached-wrong" @("-NoProfile", "-File", $markerScript, $detachedWrongMarker, "0") @{
      ImmutableHead = ("0" * 40)
    } | Out-Null
  } catch {
    $detachedWrongFailed = $_.Exception.Message -match "exact supplied SHA"
  }
  Assert-True ($detachedWrongFailed -and
    -not (Test-Path -LiteralPath $detachedWrongMarker) -and
    -not (Test-Path -LiteralPath $lock)) "detached immutable mode rejects a nonmatching exact SHA before acquisition"
  $detachedMarker = Join-Path $root "detached-exact-success.txt"
  Assert-True ((Invoke-Guard "lane-detached-exact" @("-NoProfile", "-File", $markerScript, $detachedMarker, "0") @{
    ImmutableHead = $detachedHead
  }) -eq 0) "explicit detached immutable HEAD admits its exact SHA"
  Assert-True ((Test-Path -LiteralPath $detachedMarker) -and -not (Test-Path -LiteralPath $lock)) "detached exact success runs and releases"
  $detachedDriftMarker = Join-Path $root "detached-drift-negative-control.txt"
  $detachedDriftWrapper = Start-Wrapper "lane-detached-drift" @(
    "-NoProfile", "-File", $markerScript, $detachedDriftMarker, "0"
  ) 0 1200 @{ ImmutableHead = $detachedHead }
  Wait-Condition { $record = Read-Owner; $record -and $record.identityMode -ceq "immutable-head" } "detached drift acquisition"
  Invoke-FixtureGit @("commit", "--allow-empty", "-m", "detached HEAD drift") | Out-Null
  Assert-True ($detachedDriftWrapper.WaitForExit(10000)) "detached-drift wrapper exits within ten seconds"
  Assert-True ($detachedDriftWrapper.ExitCode -ne 0 -and
    -not (Test-Path -LiteralPath $detachedDriftMarker) -and
    -not (Test-Path -LiteralPath $lock)) "detached immutable-head drift refuses before body and releases its exact owner"
  Invoke-FixtureGit @("checkout", "codex/test") | Out-Null

  $marker = Join-Path $root "marker with spaces.txt"
  Assert-True ((Invoke-Guard "lane-a" @("-NoProfile", "-File", $markerScript, $marker, "0")) -eq 0) "command with spaces succeeds"
  Assert-True (Test-Path -LiteralPath $marker) "quoted command arguments reach the child"
  Assert-True (-not (Test-Path -LiteralPath $lock)) "success releases this lock"
  $environmentResultPath = Join-Path $root "wrapped-child-environment.json"
  $priorNodeOptions = $env:NODE_OPTIONS
  $priorAdmissionConfig = $env:CHASE_SETS_HEAVY_ADMISSION_CONFIG
  $priorOriginalNodeOptions = $env:CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_NODE_OPTIONS
  $priorScriptShell = $env:npm_config_script_shell
  $priorOriginalScriptShell = $env:CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_SCRIPT_SHELL
  $priorScriptShellMarker = $env:CHASE_SETS_HEAVY_ADMISSION_PNPM_SCRIPT_SHELL
  try {
    $env:NODE_OPTIONS = "--require=C:\inert\heavy-admission-preload.cjs"
    $env:CHASE_SETS_HEAVY_ADMISSION_CONFIG = "inert-config"
    $env:CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_NODE_OPTIONS = "--trace-warnings"
    $env:npm_config_script_shell = "C:\inert\heavy-admission-script-shell.cmd"
    $env:CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_SCRIPT_SHELL = "C:\original\script-shell.exe"
    $env:CHASE_SETS_HEAVY_ADMISSION_PNPM_SCRIPT_SHELL = "node-check-proxy"
    Assert-True ((Invoke-Guard "lane-wrapper-inheritance" @("-NoProfile", "-File", $environmentChildScript, $environmentResultPath)) -eq 0) "explicit wrapper child executes after admission environment normalization"
  } finally {
    $env:NODE_OPTIONS = $priorNodeOptions
    $env:CHASE_SETS_HEAVY_ADMISSION_CONFIG = $priorAdmissionConfig
    $env:CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_NODE_OPTIONS = $priorOriginalNodeOptions
    $env:npm_config_script_shell = $priorScriptShell
    $env:CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_SCRIPT_SHELL = $priorOriginalScriptShell
    $env:CHASE_SETS_HEAVY_ADMISSION_PNPM_SCRIPT_SHELL = $priorScriptShellMarker
  }
  $wrappedEnvironment = Get-Content -LiteralPath $environmentResultPath -Raw | ConvertFrom-Json
  Assert-True ($wrappedEnvironment.nodeOptions -ceq "--trace-warnings" -and
    $wrappedEnvironment.scriptShell -ceq "C:\original\script-shell.exe" -and
    -not $wrappedEnvironment.admissionConfigPresent -and
    -not $wrappedEnvironment.originalOptionsPresent -and
    -not $wrappedEnvironment.originalScriptShellPresent -and
    -not $wrappedEnvironment.scriptShellMarkerPresent) "explicit wrapper child inherits only original admission settings and cannot self-contend"
  Assert-True ((Invoke-Guard "lane-fail" @("-NoProfile", "-File", $markerScript, $marker, "23")) -eq 23) "child failure is propagated"
  Assert-True (-not (Test-Path -LiteralPath $lock)) "failure releases this lock"

  $cancelled = $false
  try {
    Invoke-Guard "lane-cancel" @("-NoProfile", "-Command", "exit 0") @{ TestCancelAfterAcquisition = $true } | Out-Null
  } catch {
    $cancelled = $_.Exception -is [OperationCanceledException]
  }
  Assert-True ($cancelled -and -not (Test-Path -LiteralPath $lock)) "cancellation cleanup releases only the caller lock"

  $live = Get-ProcessIdentity $PID
  $liveOwner = New-OwnerRecord ("a" * 32) $live.pid $live.processStartUtc "launching"
  $liveOwner.startedUtc = [DateTime]::UtcNow.ToString("o")
  Write-Owner $liveOwner
  $liveRaw = Get-Content -LiteralPath $ownerPath -Raw
  $liveFailed = $false; $liveOutput = $null
  try {
    Invoke-Guard "lane-live" @("-NoProfile", "-Command", "exit 0") | Out-Null
  } catch {
    $liveFailed = $true; $liveOutput = $_.Exception.Message
  }
  Assert-True ($liveFailed -and "$liveOutput" -match "live-owner" -and (Get-Content -LiteralPath $ownerPath -Raw) -ceq $liveRaw) "live owner fails closed and remains byte-exact"
  Remove-DisposableLock

  $reuse = New-OwnerRecord ("c" * 32) $PID "2000-01-01T00:00:00.0000000Z"
  Write-Owner $reuse
  $reuseFailed = $false
  try { Invoke-Guard "lane-pid-reuse" @("-NoProfile", "-Command", "exit 0") | Out-Null } catch { $reuseFailed = $true }
  Assert-True ($reuseFailed -and (Test-Path -LiteralPath $lock)) "wrapper PID reuse is preserved"
  Remove-DisposableLock

  New-Item -ItemType Directory -Path $lock | Out-Null
  [IO.File]::WriteAllText($ownerPath, '{"forged":true}', [Text.UTF8Encoding]::new($false))
  $forgedRaw = Get-Content -LiteralPath $ownerPath -Raw
  $forgedFailed = $false
  try { Invoke-Guard "lane-forged" @("-NoProfile", "-Command", "exit 0") | Out-Null } catch { $forgedFailed = $true }
  Assert-True ($forgedFailed -and (Get-Content -LiteralPath $ownerPath -Raw) -ceq $forgedRaw) "malformed owner remains untouched"
  Remove-DisposableLock

  New-Item -ItemType Directory -Path $lock | Out-Null
  $prePublicationFailed = $false
  try { Invoke-Guard "lane-pre-publication" @("-NoProfile", "-Command", "exit 0") | Out-Null } catch { $prePublicationFailed = $true }
  Assert-True ($prePublicationFailed -and (Test-Path -LiteralPath $lock) -and -not (Test-Path -LiteralPath $ownerPath)) "pre-publication lock remains fail-closed"
  Remove-DisposableLock

  $mismatch = Invoke-Guard "lane-mismatch" @("-NoProfile", "-Command", "exit 0") @{ TestReplaceOwnerBeforeCleanup = $true } 2>&1
  Assert-True ((Test-Path -LiteralPath $lock) -and ((Get-Content -Raw $ownerPath) -match "forged")) "cleanup fails closed and never removes a mismatched owner"
  Remove-DisposableLock

  $changed = New-OwnerRecord ("e" * 32) 999999 "2000-01-01T00:00:00.0000000Z"
  Write-Owner $changed
  $changedFailed = $false
  try {
    Invoke-Guard "lane-changed" @("-NoProfile", "-Command", "exit 0") @{ TestReplaceOwnerBeforeReclaim = $true } | Out-Null
  } catch {
    $changedFailed = $true
  }
  Assert-True ($changedFailed -and ((Get-Content -LiteralPath $ownerPath -Raw) -match "forged")) "changed-after-validation owner cannot be reclaimed"
  Remove-DisposableLock

  $reparseTarget = Join-Path $root "reparse-target"
  New-Item -ItemType Directory -Path $reparseTarget | Out-Null
  $targetOwner = Join-Path $reparseTarget "owner.json"
  [IO.File]::WriteAllText($targetOwner, '{"poison":"preserve"}', [Text.UTF8Encoding]::new($false))
  New-Item -ItemType Junction -Path $lock -Target $reparseTarget | Out-Null
  $reparseFailed = $false
  try { Invoke-Guard "lane-reparse" @("-NoProfile", "-Command", "exit 0") | Out-Null } catch { $reparseFailed = $true }
  Assert-True ($reparseFailed -and (Test-IsReparse $lock) -and (Test-Path -LiteralPath $targetOwner)) "reparse lock and target remain untouched"
  Remove-Item -LiteralPath $lock -Force
  Assert-True (-not (Test-Path -LiteralPath $lock) -and (Test-Path -LiteralPath $targetOwner)) "only the disposable junction was removed"
  Remove-Item -LiteralPath $reparseTarget -Recurse -Force

  $orphanIdentityPath = Join-Path $root "orphan-child.json"
  $orphanMarker = Join-Path $root "orphan-contender.txt"
  $orphanWrapper = Start-Wrapper "lane-orphan" @("-NoProfile", "-File", $identityChildScript, $orphanIdentityPath, "30000")
  $orphanWrapperIdentity = [pscustomobject]@{ pid=$orphanWrapper.Id; processStartUtc=$orphanWrapper.StartTime.ToUniversalTime().ToString("o") }
  Wait-Condition { Test-Path -LiteralPath $orphanIdentityPath -PathType Leaf } "orphan child identity"
  Wait-Condition { $record = Read-Owner; $record -and $record.state -ceq "started" } "orphan started owner"
  $orphanChildIdentity = Read-ChildIdentity $orphanIdentityPath
  $orphanOwnerRaw = Get-Content -LiteralPath $ownerPath -Raw
  Stop-ExactProcess $orphanWrapperIdentity
  Assert-True (Test-ExactProcess $orphanChildIdentity) "orphan child remains live after wrapper hard-kill"
  $orphanFailed = $false
  try { Invoke-Guard "lane-orphan-contender" @("-NoProfile", "-File", $markerScript, $orphanMarker, "0") | Out-Null } catch { $orphanFailed = $true }
  Assert-True ($orphanFailed -and -not (Test-Path -LiteralPath $orphanMarker) -and (Get-Content -LiteralPath $ownerPath -Raw) -ceq $orphanOwnerRaw) "live orphan child preserves exact lock and contender never runs"
  Stop-ExactProcess $orphanChildIdentity
  Assert-True ((Invoke-Guard "lane-orphan-recovery" @("-NoProfile", "-File", $markerScript, $orphanMarker, "0")) -eq 0) "orphan lock reclaims only after exact child death"
  Assert-True ((Test-Path -LiteralPath $orphanMarker) -and -not (Test-Path -LiteralPath $lock)) "orphan recovery completes and cleans its own lock"

  $pendingIdentityPath = Join-Path $root "pending-child.json"
  $pendingMarker = Join-Path $root "pending-contender.txt"
  $pendingWrapper = Start-Wrapper "lane-pending" @("-NoProfile", "-File", $identityChildScript, $pendingIdentityPath, "30000") 10000
  $pendingWrapperIdentity = [pscustomobject]@{ pid=$pendingWrapper.Id; processStartUtc=$pendingWrapper.StartTime.ToUniversalTime().ToString("o") }
  Wait-Condition { Test-Path -LiteralPath $pendingIdentityPath -PathType Leaf } "pending child identity"
  Wait-Condition { $record = Read-Owner; $record -and $record.state -ceq "launching" } "launching owner in child-publication window"
  $pendingChildIdentity = Read-ChildIdentity $pendingIdentityPath
  $pendingOwnerRaw = Get-Content -LiteralPath $ownerPath -Raw
  Stop-ExactProcess $pendingWrapperIdentity
  Assert-True (Test-ExactProcess $pendingChildIdentity) "publication-window child remains live"
  $pendingFailed = $false
  try { Invoke-Guard "lane-pending-contender" @("-NoProfile", "-File", $markerScript, $pendingMarker, "0") | Out-Null } catch { $pendingFailed = $true }
  Assert-True ($pendingFailed -and -not (Test-Path -LiteralPath $pendingMarker) -and (Get-Content -LiteralPath $ownerPath -Raw) -ceq $pendingOwnerRaw) "discoverable unrecorded child keeps publication window fail-closed"
  Stop-ExactProcess $pendingChildIdentity
  Assert-True ((Invoke-Guard "lane-pending-recovery" @("-NoProfile", "-File", $markerScript, $pendingMarker, "0")) -eq 0) "pending lock reclaims only after discoverable child death"
  Assert-True ((Test-Path -LiteralPath $pendingMarker) -and -not (Test-Path -LiteralPath $lock)) "pending-child recovery completes exactly"

  $outside = Join-Path $root "outside"
  New-Item -ItemType Directory -Path $outside | Out-Null
  $currentFixtureHead = Invoke-FixtureGit @("rev-parse", "HEAD")
  $pathBody = Join-Path $outside "path-body.txt"
  Set-Content -LiteralPath (Join-Path $outside "package.json") -Value (@{
    scripts = @{ "verify:static" = 'node -e "require(''fs'').writeFileSync(''path-body.txt'',''executed'')"' }
  } | ConvertTo-Json -Depth 3)
  Assert-True (-not (Test-Path -LiteralPath $lock)) "path refusal starts without a lock"
  foreach ($existingLock in @($false, $true)) {
    if ($existingLock) {
      New-Item -ItemType Directory -Path $lock | Out-Null
      Set-Content -LiteralPath $ownerPath -Value '{"synthetic":"path-refusal-preserved-owner"}'
      $pathOwnerBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($ownerPath))
    }
    $pathOutput = @(& (Join-Path $PSHOME "pwsh.exe") -NoProfile -NonInteractive -File $guard `
      -Gate "verify:static" -Worktree $outside -Lane "lane-path" -Branch "codex/test" `
      -ClaimedHead $currentFixtureHead -ContainerRoot $container 2>&1)
    $pathExit = $LASTEXITCODE
    Assert-True ($pathExit -eq 73 -and $pathOutput.Count -eq 1 -and
      [string]$pathOutput[0] -ceq "heavy-verifier: worktree must be an existing child of the container root") `
      "path traversal/outside root refuses with native exit 73 and exact diagnostic"
    Assert-True (-not (Test-Path -LiteralPath $pathBody) -and
      @(Get-ChildItem -LiteralPath $outside -Force).Count -eq 1) "path refusal has zero body effects"
    if ($existingLock) {
      Assert-True ((Test-Path -LiteralPath $ownerPath -PathType Leaf) -and
        @(Get-ChildItem -LiteralPath $lock -Force).Count -eq 1 -and
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($ownerPath)) -ceq $pathOwnerBytes) `
        "path refusal preserves the existing lock and exact owner bytes"
      Remove-Item -LiteralPath $ownerPath
      Remove-Item -LiteralPath $lock
    } else {
      Assert-True (-not (Test-Path -LiteralPath $lock)) "path refusal creates no lock"
    }
  }
  $worktreeSubdirectory = Join-Path $worktree "not-the-worktree-root"
  $canonicalMarker = Join-Path $root "noncanonical-worktree-negative-control.txt"
  New-Item -ItemType Directory -Path $worktreeSubdirectory | Out-Null
  $canonicalFailed = $false
  try {
    & $guard -Gate "verify:static" -Worktree $worktreeSubdirectory -Lane "lane-noncanonical" -Branch "codex/test" -ClaimedHead $currentFixtureHead `
      -ContainerRoot $container -CommandPath (Join-Path $PSHOME "pwsh.exe") `
      -CommandArgumentList @("-NoProfile", "-File", $markerScript, $canonicalMarker, "0")
  } catch {
    $canonicalFailed = $_.Exception.Message -match "canonical Git worktree root"
  }
  Assert-True ($canonicalFailed -and
    -not (Test-Path -LiteralPath $canonicalMarker) -and
    -not (Test-Path -LiteralPath $lock)) "noncanonical worktree path refuses before body and owner creation"
  $bypassFailed = $false; $bypassOutput = $null
  try { & $guard -Gate "not-a-heavy-gate" -Worktree $worktree -Lane "lane-bypass" -Branch "codex/test" -ClaimedHead $currentFixtureHead -ContainerRoot $container } catch { $bypassFailed = $true; $bypassOutput = $_.Exception.Message }
  Assert-True ($bypassFailed -and "$bypassOutput" -match "ValidateSet") "unsupported gate bypass is refused"

  $freshRaceA = Join-Path $root "fresh-race-a.txt"
  $freshRaceB = Join-Path $root "fresh-race-b.txt"
  $freshA = Start-Wrapper "fresh-race-a" @("-NoProfile", "-File", $markerScript, $freshRaceA, "0", "600")
  $freshB = Start-Wrapper "fresh-race-b" @("-NoProfile", "-File", $markerScript, $freshRaceB, "0", "600")
  $freshA.WaitForExit()
  $freshB.WaitForExit()
  $freshRaceMarkers = @(@($freshRaceA, $freshRaceB) | Where-Object { Test-Path -LiteralPath $_ })
  Assert-True ($freshRaceMarkers.Count -eq 1) "fresh contention runs exactly one inert body"
  Assert-True (($freshA.ExitCode -ne 0) -xor ($freshB.ExitCode -ne 0)) "fresh contention has one owner and one bounded refusal"
  Assert-True (-not (Test-Path -LiteralPath $lock)) "fresh contention winner cleans up"

  $raceA = Join-Path $root "stale-race-a.txt"
  $raceB = Join-Path $root "stale-race-b.txt"
  Write-Owner (New-OwnerRecord ("f" * 32) 999999 "2000-01-01T00:00:00.0000000Z")
  $a = Start-Wrapper "race-a" @("-NoProfile", "-File", $markerScript, $raceA, "0", "600")
  $b = Start-Wrapper "race-b" @("-NoProfile", "-File", $markerScript, $raceB, "0", "600")
  $a.WaitForExit()
  $b.WaitForExit()
  $raceMarkers = @(@($raceA, $raceB) | Where-Object { Test-Path -LiteralPath $_ })
  Assert-True ($raceMarkers.Count -eq 1) "concurrent stale contenders run exactly one inert body"
  Assert-True (($a.ExitCode -ne 0) -xor ($b.ExitCode -ne 0)) "concurrent stale contenders have one owner and one bounded refusal"
  Assert-True (-not (Test-Path -LiteralPath $lock)) "stale contention winner cleans up"

  Write-Output "PASS heavy verifier guard coverage"
  if(-not$LegacyOnly){& (Join-Path $PSScriptRoot 'invoke-heavy-verifier-fifo.test.ps1')}
} finally {
  foreach ($identity in $testWrapperIdentities) {
    try {
      if (Test-ExactProcess $identity) { Stop-ExactProcess $identity }
    } catch {
      # Final cleanup remains bounded to wrappers started by this temp-root test.
    }
  }
  foreach ($identityPath in @(
      (Join-Path $root "discriminator-child.json"),
      (Join-Path $root "grandchild-child.json"),
      (Join-Path $root "grandchild-relay.json"),
      (Join-Path $root "grandchild-worker.json"),
      (Join-Path $root "orphan-child.json"),
      (Join-Path $root "pending-child.json")
    )) {
    if (Test-Path -LiteralPath $identityPath -PathType Leaf) {
      try {
        $identity = Read-ChildIdentity $identityPath
        if (Test-ExactProcess $identity) { Stop-ExactProcess $identity }
      } catch {
        # Final cleanup remains bounded to identities published in this temp root.
      }
    }
  }
  if (Test-Path -LiteralPath $root) {
    Assert-DisposableRoot
    Remove-Item -LiteralPath $root -Recurse -Force
  }
}
