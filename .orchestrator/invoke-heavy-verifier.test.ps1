[CmdletBinding()]
param(
  [switch]$NativeDbOnly,
  [switch]$DiscriminatorOnly,
  [switch]$RulingFourOnly,
  [switch]$EligibilityOnly,
  [switch]$RoleAdmissionOnly,
  [ValidateSet('', 'role-spoof', 'missing-role', 'host-denied', 'bypass-check')][string]$EligibilityMutant = '',
  [switch]$PrecursorAdmissionDiscriminatorOnly,
  [switch]$PrecursorOnly,
  [switch]$LegacyOnly,
  [switch]$FixtureEquivalenceOnly,
  # #206: only the disposable-root teardown discriminator.
  [switch]$TeardownOnly,
  # #9627 named bypass mutants of the ControllerFixtureEquivalence route.
  [ValidateSet('', 'arbitrary-phase', 'forward-baseline', 'unchecked-evidence', 'untracked-check', 'unbound-source-bytes', 'unchecked-ancestry', 'platform-slot', 'early-release', 'bypass-eligibility')][string]$FixtureMutant = '',
  [string]$GuardRevision = ""
)

$ErrorActionPreference = "Stop"
$guard = Join-Path $PSScriptRoot "invoke-heavy-verifier.ps1"
function Assert-True($Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}
if ($EligibilityOnly) {
  $source = if ($GuardRevision) {
    (@(& git -C (Split-Path -Parent $PSScriptRoot) show "${GuardRevision}:.orchestrator/invoke-heavy-verifier.ps1") -join "`n")
  } else { [IO.File]::ReadAllText($guard) }
  $tokens = $null; $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
  $functions = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false))
  $eligibility = @($functions | Where-Object Name -eq 'Assert-HeavyCallerEligibility')
  Assert-True ($eligibility.Count -eq 1) 'all modes require native caller eligibility before reservation'
  $snapshotRead = @($ast.FindAll({param($n)
    $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$snapshots[$path]'
  }, $true))
  Assert-True ($snapshotRead.Count -eq 1) 'one native ownership snapshot read'
  $reader = $snapshotRead[0].Right.Extent.Text
  Assert-True ($source.Split([string[]]@($reader), [StringSplitOptions]::None).Count -eq 3) 'snapshot and revalidation use the same byte-preserving reader'
  $path = Join-Path ([IO.Path]::GetTempPath()) ('heavy-encoding-' + [guid]::NewGuid().ToString('N'))
  try {
    [IO.File]::WriteAllText($path, '{"laneRole":"implementation"}', [Text.UTF8Encoding]::new($false))
    $before = & ([scriptblock]::Create($reader))
    $normalizedBefore = [IO.File]::ReadAllText($path)
    [IO.File]::WriteAllText($path, '{"laneRole":"implementation"}', [Text.UTF8Encoding]::new($true))
    $after = & ([scriptblock]::Create($reader))
    Assert-True (-not [string]::Equals($before, $after, [StringComparison]::Ordinal)) 'encoding-only ownership replacement changes exact snapshot'
    Assert-True ($normalizedBefore -ceq [IO.File]::ReadAllText($path)) 'normalizing-reader mutant loses the changed bytes'
    Write-Output 'PASS ownership encoding-only replacement detected; normalizing-reader mutant loses byte identity'
  } finally { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
  foreach ($definition in $functions) { . ([scriptblock]::Create($definition.Extent.Text)) }
  & {
    $instant = [datetime]::SpecifyKind([datetime]'2026-01-01', [DateTimeKind]::Utc)
    $script:ancestryTimes = @{ 101 = $instant.AddSeconds(3); 102 = $instant.AddSeconds(2); 103 = $instant; 104 = $instant.AddSeconds(-1) }
    $script:ancestrySnapshots = 0
    $script:heavyCallerAncestry = $null
    function Get-Process([int]$Id) {
      if (-not $script:ancestryTimes.ContainsKey($Id)) { throw 'fixture process exited' }
      return [pscustomobject]@{ StartTime = $script:ancestryTimes[$Id] }
    }
    function Get-CimInstance {
      $script:ancestrySnapshots++
      foreach ($id in @(101, 102, 103, 104)) {
        if ($script:ancestryTimes.ContainsKey($id)) {
          [pscustomobject]@{ ProcessId = $id; ParentProcessId = $id + 1; CreationDate = $script:ancestryTimes[$id] }
        }
      }
    }
    $start = $script:ancestryTimes[101].ToString('o')
    $oldest = $script:ancestryTimes[102].Ticks
    $first = Get-HeavyCallerAncestry 101 $start $oldest @(102)
    $second = Get-HeavyCallerAncestry 101 $start $oldest @(102)
    Assert-True ($script:ancestrySnapshots -eq 1 -and $second[102] -eq $first[102]) 'exact live ancestry reuses immutable edges'
    Get-HeavyCallerAncestry 101 $start $oldest @(102, 103) | Out-Null
    Assert-True ($script:ancestrySnapshots -eq 2) 'new candidate forces a fresh ancestry snapshot'
    $script:ancestryTimes[102] = $instant.AddSeconds(4)
    $refused = $false
    try { Get-HeavyCallerAncestry 101 $start $oldest @(102, 103) | Out-Null } catch { $refused = $_.Exception.Message -match 'PID reused' }
    Assert-True ($refused -and $script:ancestrySnapshots -eq 3) 'reused ancestor invalidates cached edges and refuses'
    $script:ancestryTimes[102] = $instant.AddSeconds(2)
    Get-HeavyCallerAncestry 101 $start $oldest @(102) | Out-Null
    $script:ancestryTimes.Remove(102)
    $refused = $false
    try { Get-HeavyCallerAncestry 101 $start $oldest @(102) | Out-Null } catch { $refused = $_.Exception.Message -match 'lookup failed' }
    Assert-True $refused 'exited ancestor invalidates cached edges and refuses'
    $script:heavyCallerAncestry = $null
    Write-Output 'PASS immutable ancestry reuse revalidates exact starts; new candidates, PID reuse and exit invalidate'
  }
  function Get-HeavyCallerBinding { return $script:fixtureBinding }
  $isHostVerifier = $true
  foreach ($role in @('planning', 'review', 'implementation', '', 'observer')) {
    foreach ($row in @(7, 13)) {
      $script:fixtureBinding = [pscustomobject]@{ Record = [pscustomobject]@{ laneRole = $role }; Row = $row; Reason = $null }
      $refused = $false
      try { Assert-HeavyCallerEligibility | Out-Null } catch { $refused = $_.Exception.Message -match 'heavy-verifier: caller eligibility:' }
      Assert-True ($refused -eq ($role -cne 'implementation' -or $row -eq 13)) "role=$role row=$row ignores host-shaped spoof"
    }
  }
  $script:fixtureBinding = [pscustomobject]@{ Record = $null; Row = $null; Reason = $null }
  Assert-HeavyCallerEligibility | Out-Null
  Write-Output 'PASS healthy standalone host remains eligible'
  $expected = [pscustomobject]@{Path='synthetic';Raw=$before;RoutingRaw='synthetic-row'}
  $script:fixtureBinding = [pscustomobject]@{Record=$null;Row=$null;Reason=$null;Path='synthetic';Raw=$after;RoutingRaw='synthetic-row'}
  $refused = $false
  try { Assert-HeavyCallerEligibility $expected | Out-Null } catch { $refused = $_.Exception.Message -match 'launch or routing identity changed' }
  Assert-True $refused 'encoding-only replacement refuses authority revalidation'
  $script:fixtureBinding.Reason = 'synthetic failed census'
  $refused = $false
  try { Assert-HeavyCallerEligibility | Out-Null } catch { $refused = $true }
  Assert-True $refused 'missing/failed census is not host authority'
  Write-Output 'PASS role-spoof, missing-role fail-closed and host controls'
  return
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
      # Native ownership records the real root identity; a separate walk-only
      # boundary straddles the relay and worker to discriminate full traversal.
      $record = Read-NativeJson ((@{
        schemaVersion=6;lockId=('d'*32);owner='synthetic';lane='synthetic';branch='codex/synthetic';head=('a'*40)
        worktree=$caseRoot;identityMode='branch';pid=$identities[3].pid;processStartUtc=$identities[3].start
        startedUtc=$identities[2].start;gate='verify:test-db';commandIdentity=('e'*64);state='started'
        childPid=$identities[2].pid;childProcessStartUtc=$identities[2].start
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
      $walkRecord = $record.PSObject.Copy(); $walkRecord.startedUtc=$boundary.UtcDateTime.ToString('o')
      Stop-NativeFixture $identities[2]
      if ($mode -ceq 'later') { Stop-NativeFixture $identities[3] }
      Assert-True ((Test-PossibleOwnedChild $walkRecord -GuardedRootOnly) -eq $true) 'full guarded-root BFS finds real deepest grandchild'
      $eligible = if ($mode -ceq 'normal') { Test-NativeNormalRelease $record } else { Test-ReclaimableOwner $record }
      Assert-True (-not $eligible) "$mode schema6 refuses real deepest grandchild"
      Stop-NativeFixture $identities[0]
      Wait-NativeFixture { (Test-PossibleOwnedChild $walkRecord -GuardedRootOnly) -eq $false } 'deepest exact absence'
      $eligible = if ($mode -ceq 'normal') { Test-NativeNormalRelease $record } else { Test-ReclaimableOwner $record }
      Assert-True (-not $eligible) "$mode schema6 still protects genuine older relay after deepest death"
      Stop-NativeFixture $identities[1] # Native ownership also protects the genuine older relay.
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
if (-not ($DiscriminatorOnly -or $RulingFourOnly -or $RoleAdmissionOnly -or $PrecursorAdmissionDiscriminatorOnly -or $PrecursorOnly -or $LegacyOnly -or $FixtureEquivalenceOnly -or $TeardownOnly)) {
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
# #9627: the closed evidence root sits beside the disposable container.
$fixtureEvidenceRoot = Join-Path $root "container with spaces-heavy-evidence"
# Inert tracked stand-ins for the H-only #9275 check and harness. They record
# exactly how the route invoked them; they are never fixture-equivalence proof.
$fixtureStandInCheck = @'
param([string]$BaselineHead, [string]$EvidenceDirectory, [string]$Phase, [string]$RunDirectory)
$self = Get-Process -Id $PID
$controllerOwner = Join-Path $env:HV_FIXTURE_RUNTIME 'controller-verify-lock.d/owner.json'
$platformOwner = Join-Path $env:HV_FIXTURE_RUNTIME 'verify-lock.d/owner.json'
$record = [ordered]@{
  argv = @([Environment]::GetCommandLineArgs() | Select-Object -Skip 1)
  bound = @($PSBoundParameters.Keys | Sort-Object)
  unbound = @($args).Count
  script = $PSCommandPath
  pid = $PID; processStartUtc = $self.StartTime.ToUniversalTime().ToString('o')
  slot = $env:CHASE_SETS_HEAVY_SLOT_ID
  owner = $(if (Test-Path -LiteralPath $controllerOwner) { [IO.File]::ReadAllText($controllerOwner) } else { $null })
  platformOwner = $(if (Test-Path -LiteralPath $platformOwner) { [IO.File]::ReadAllText($platformOwner) } else { $null })
  evidenceEntries = $(if ($EvidenceDirectory -and (Test-Path -LiteralPath $EvidenceDirectory)) { @(Get-ChildItem -LiteralPath $EvidenceDirectory -Force).Count } else { -1 })
}
[IO.File]::WriteAllText($env:HV_FIXTURE_BODY, ($record | ConvertTo-Json -Compress -Depth 4))
if ($env:HV_FIXTURE_STANDIN -ceq 'fail') { exit 29 }
if ($env:HV_FIXTURE_STANDIN -ceq 'descendant') {
  $start = [Diagnostics.ProcessStartInfo]::new($self.Path)
  $start.UseShellExecute = $false; $start.CreateNoWindow = $true
  foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', (Join-Path $PSScriptRoot 'cleanup-scale-fixture-harness.ps1'), $env:HV_FIXTURE_GRANDCHILD, $env:HV_FIXTURE_RELEASE)) { [void]$start.ArgumentList.Add($argument) }
  [void][Diagnostics.Process]::Start($start)
}
exit 0
'@
$fixtureStandInHarness = @'
param([string]$IdentityPath, [string]$ReleasePath)
$self = Get-Process -Id $PID
[IO.File]::WriteAllText($IdentityPath, ([ordered]@{ pid = $PID; processStartUtc = $self.StartTime.ToUniversalTime().ToString('o') } | ConvertTo-Json -Compress))
$deadline = [DateTime]::UtcNow.AddSeconds(90)
while (-not (Test-Path -LiteralPath $ReleasePath) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
exit 0
'@
# Each mutant is one exact edit of the candidate route; an absent anchor fails
# the test rather than silently running the unmutated route.
$fixtureMutantEdits = @{
  'arbitrary-phase' = @(, @('"-Phase", "fixture"', '"-Phase", "all"'))
  'forward-baseline' = @(, @('"-EvidenceDirectory", $fixtureEvidence)', '"-EvidenceDirectory", $fixtureEvidence, "-BaselineHead", $acquiredGitIdentity.Head)'))
  'unchecked-evidence' = @(, @('$insideRoot = [string]::Equals(', '$insideRoot = $true -or [string]::Equals('))
  'untracked-check' = @(, @('if (-not $blob) {', 'if ($false) {'))
  'unbound-source-bytes' = @(, @('if (-not (Test-ControllerFixtureSourceBytes $sourcePath $blob)) {', 'if ($false) {'))
  'unchecked-ancestry' = @(, @('if ((Test-PathEntry $ancestor) -and -not (Test-PrecursorSafeDirectory $ancestor)) {', 'if ($false) {'))
  'platform-slot' = @(, @('$lockDirectoryName = if ($isControllerBattery -or $isControllerPrecursor -or $isControllerFixture)', '$lockDirectoryName = if ($isControllerBattery -or $isControllerPrecursor)'))
  'early-release' = @(
    @('if ($isControllerPrecursor -or $isHostVerifier -or $isControllerFixture) {', 'if ($isControllerPrecursor -or $isHostVerifier) {'),
    @('if (($isHostVerifier -or $isControllerFixture) -and $null -ne $child -and', 'if ($isHostVerifier -and $null -ne $child -and'))
  'bypass-eligibility' = @(, @('$binding = Get-HeavyCallerBinding', '$binding = Get-HeavyCallerBinding; if ($isControllerFixture) { return [pscustomobject]@{ Record = $null; Path = $null; Raw = $null; RoutingRaw = $null } }'))
}
function Get-FixtureMutantSource([string]$Source) {
  if (-not $FixtureMutant) { return $Source }
  Assert-True (-not $EligibilityMutant) 'FixtureMutant and EligibilityMutant are mutually exclusive'
  foreach ($edit in $fixtureMutantEdits[$FixtureMutant]) {
    $count = ([regex]::Matches($Source, [regex]::Escape($edit[0]))).Count
    Assert-True ($count -eq 1) "fixture mutant $FixtureMutant anchor occurs once (observed $count): $($edit[0])"
    $Source = $Source.Replace($edit[0], $edit[1])
  }
  return $Source
}
function Get-GuardSource {
  if ($GuardRevision) { return (@(& git -C (Split-Path -Parent $PSScriptRoot) show "${GuardRevision}:.orchestrator/invoke-heavy-verifier.ps1") -join "`n") }
  return [IO.File]::ReadAllText($guard)
}
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
# #206: teardown removes the disposable root only after every process this test
# started under it has exited. Ownership is proven by exact ancestry, never by a
# path match alone: a live process is this test's when its parent chain reaches
# this test process, or a live exact identity the test recorded (a wrapper, or a
# child identity published in the root), each link started no earlier than its
# parent. It is under the root when that chain names the root or ends at a
# recorded identity. Nothing else is ever stopped; a root it holds is retained.
function ConvertTo-TeardownIdentity($Value) {
  $processId = 0; $start = [DateTimeOffset]::MinValue
  if ($null -eq $Value -or -not [int]::TryParse([string]$Value.pid, [ref]$processId) -or $processId -le 0 -or
      -not [DateTimeOffset]::TryParse([string]$Value.processStartUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$start)) {
    return
  }
  return [pscustomobject]@{ Id = $processId; StartTicks = $start.UtcTicks }
}
function Get-TeardownKnownIdentities([string]$Path, $Recorded) {
  foreach ($value in @($Recorded)) { ConvertTo-TeardownIdentity $value }
  foreach ($file in @(Get-ChildItem -LiteralPath $Path -Filter '*.json' -File -Force -ErrorAction SilentlyContinue)) {
    try { ConvertTo-TeardownIdentity ([IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json -DateKind String) } catch {}
  }
}
function Get-TeardownProcessTable {
  $table = @{}
  foreach ($entry in @(CimCmdlets\Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, CreationDate, Name, CommandLine, ExecutablePath -ErrorAction Stop)) {
    if ($null -eq $entry.CreationDate) { continue }
    $table[[int]$entry.ProcessId] = [pscustomobject]@{
      Id = [int]$entry.ProcessId; ParentId = [int]$entry.ParentProcessId; StartTicks = ([datetime]$entry.CreationDate).ToUniversalTime().Ticks
      Name = [string]$entry.Name; CommandLine = [string]$entry.CommandLine; Text = "$($entry.ExecutablePath) $($entry.CommandLine)"
    }
  }
  return $table
}
# CIM creation times carry microseconds and recorded identities 100 ns ticks,
# so a PID matches a recorded identity when the starts agree within 10 ticks.
function Test-TeardownRecorded($ById, [int]$Id, [long]$Ticks, [switch]$AtOrBefore) {
  if (-not $ById.ContainsKey($Id)) { return $false }
  foreach ($recorded in $ById[$Id]) {
    if ($(if ($AtOrBefore) { $recorded -le $Ticks + 10 } else { [Math]::Abs($recorded - $Ticks) -le 10 })) { return $true }
  }
  return $false
}
function Select-TeardownProcesses($Table, $Known, [string]$Path, [int]$SelfId) {
  $byId = @{}
  foreach ($identity in @($Known)) {
    if ($null -eq $identity) { continue }
    if (-not $byId.ContainsKey($identity.Id)) { $byId[$identity.Id] = [Collections.Generic.List[long]]::new() }
    $byId[$identity.Id].Add($identity.StartTicks)
  }
  $self = $Table[$SelfId]
  $ancestors = @{}
  for ($walk = $self; $null -ne $walk -and -not $ancestors.ContainsKey($walk.ParentId); $walk = $Table[$walk.ParentId]) { $ancestors[$walk.ParentId] = $true }
  foreach ($process in @($Table.Values)) {
    # Console hosts are skipped, as in the guard's own descendant census.
    if ($process.Id -eq $SelfId -or $ancestors.ContainsKey($process.Id) -or $process.Name -iin @('conhost.exe', 'openconsole.exe')) { continue }
    $named = $false; $owner = $null; $current = $process
    for ($depth = 0; $depth -lt 64 -and $null -eq $owner; $depth++) {
      if ($current.Text.IndexOf($Path, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $named = $true }
      $parent = $Table[$current.ParentId]
      if (Test-TeardownRecorded $byId $current.Id $current.StartTicks) { $owner = 'recorded' }
      elseif ($current.ParentId -eq $SelfId) { $owner = if ($null -ne $self -and $current.StartTicks -ge $self.StartTicks - 10) { 'self' } else { 'none' } }
      elseif (Test-TeardownRecorded $byId $current.ParentId $current.StartTicks -AtOrBefore) {
        # Only a live, exact recorded parent vouches for its child. Once it has
        # exited, a reused PID can parent anything: only an exact record counts.
        $owner = if ($null -ne $parent -and (Test-TeardownRecorded $byId $parent.Id $parent.StartTicks)) { 'recorded' } else { 'none' }
      } elseif ($null -eq $parent -or $parent.StartTicks -gt $current.StartTicks + 10) { $owner = 'none' }
      else { $current = $parent }
    }
    if ($owner -ceq 'recorded' -or ($owner -ceq 'self' -and $named)) { $process }
  }
}
function Stop-TeardownProcess($Process) {
  try {
    $live = [Diagnostics.Process]::GetProcessById($Process.Id)
    if ([Math]::Abs($live.StartTime.ToUniversalTime().Ticks - $Process.StartTicks) -gt 10) { return $false }
    $live.Kill()
    return $live.WaitForExit(10000)
  } catch { return $false }
}
# Never throws, so it cannot replace a body failure that is already propagating.
function Complete-DisposableTeardown([string]$Path, $Recorded, [int]$Attempts = 10) {
  $stopped = [Collections.Generic.List[object]]::new()
  $reason = $null; $attempt = 0
  try {
    $resolved = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    if (-not $resolved.StartsWith($systemTemp + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or (Test-IsReparse $resolved)) {
      $reason = 'it is not an ordinary directory below system temp, so nothing was stopped or removed.'
      $Attempts = 0
    }
    while ($attempt -lt $Attempts -and (Test-Path -LiteralPath $resolved)) {
      $attempt++
      if ($attempt -gt 1) { Start-Sleep -Milliseconds ([Math]::Min(2000, 250 * ($attempt - 1))) }
      try {
        # Census again after each kill: a target can start a child in between.
        for ($round = 0; $round -lt 5; $round++) {
          $known = @(Get-TeardownKnownIdentities $resolved $Recorded) + @($stopped)
          $progress = $false
          foreach ($target in @(Select-TeardownProcesses (Get-TeardownProcessTable) $known $resolved $PID | Sort-Object StartTicks)) {
            if (Stop-TeardownProcess $target) { $stopped.Add($target); $progress = $true }
          }
          if (-not $progress) { break }
        }
      } catch { $reason = "process census failed: $($_.Exception.Message)" }
      try { Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop } catch { $reason = $_.Exception.Message }
    }
  } catch { $reason = "teardown error: $($_.Exception.Message)" }
  $removed = -not (Test-Path -LiteralPath $Path)
  return [pscustomobject]@{ Removed = $removed; Reason = $(if ($removed) { $null } else { $reason }); Attempts = $attempt; Stopped = $stopped }
}
function Write-TeardownReport([string]$Path, $Teardown) {
  try {
    $describe = { param($Process) $text = ("$($Process.CommandLine)" -replace '\s+', ' ').Trim(); "pid=$($Process.Id) $($Process.Name) $($text.Substring(0, [Math]::Min(300, $text.Length)))" }
    if ($Teardown.Stopped.Count) {
      [Console]::Error.WriteLine("TEARDOWN stopped $($Teardown.Stopped.Count) process(es) this test started under ${Path}: $(@($Teardown.Stopped | ForEach-Object { & $describe $_ }) -join ' | ')")
    }
    if (-not $Teardown.Removed) {
      $holders = 'unavailable'
      try {
        $naming = @((Get-TeardownProcessTable).Values | Where-Object { $_.Text.IndexOf($Path, [StringComparison]::OrdinalIgnoreCase) -ge 0 } | ForEach-Object { & $describe $_ })
        $holders = if ($naming.Count) { $naming -join ' | ' } else { 'none' }
      } catch {}
      [Console]::Error.WriteLine("TEARDOWN FAILED: retained $Path after $($Teardown.Attempts) removal attempt(s): $($Teardown.Reason) Live processes naming the root, left running: $holders.")
    }
  } catch {
    [Console]::Error.WriteLine("TEARDOWN report error for ${Path}: $($_.Exception.Message)")
  }
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
function Wait-Condition([scriptblock]$Condition, [string]$Message, [int]$TimeoutSeconds = 0) {
  # Default: 400 polls. A fixture whose startup chains several cold pwsh
  # launches adds a wall-clock deadline; the wait is never shorter (#206).
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  for ($attempt = 0; $attempt -lt 400 -or [DateTime]::UtcNow -lt $deadline; $attempt++) {
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
    return [pscustomobject]@{ exitCode = $LASTEXITCODE; output = $observed }
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

  # Put the inert relay just before a valid attached ownership boundary and its
  # worker just after it. Keep the exact tracked child's real start identity:
  # a one-hop scan ignores the older relay, while a full walk must reach and
  # preserve the later worker after the tracked child is killed.
  Start-Sleep -Milliseconds 25
  $discriminatorStartedAt = [DateTimeOffset]::UtcNow
  Assert-True (
    [DateTimeOffset]::Parse([string]$relayIdentity.processStartUtc).ToUniversalTime().Ticks -lt
      $discriminatorStartedAt.Ticks
  ) "relay predates the discriminator ownership boundary"
  $published.startedUtc = $discriminatorStartedAt.ToString("o")
  $published.state = 'attached'
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

function Test-NativeRoleAdmission {
  $nativeTree = Join-Path $container 'role-fixture'
  $cloneOutput = @(& git clone --quiet $worktree $nativeTree 2>&1)
  Assert-True ($LASTEXITCODE -eq 0) 'native role fixture clone'
  $nativeHead = (& git -C $nativeTree rev-parse HEAD).Trim()
  $nativeBranch = (& git -C $nativeTree branch --show-current).Trim()
  $copyRoot = $orchestrator
  foreach ($dependency in @('dispatch-ownership.ps1','heavy-nested-owner.cs','heavy-nested-client.cjs',
      'heavy-admission-preload.cjs','heavy-slot.cjs','heavy-admission-holder-launcher.cjs')) {
    Copy-Item (Join-Path $PSScriptRoot $dependency) $copyRoot
  }
  $source = if ($GuardRevision) { (@(& git -C (Split-Path -Parent $PSScriptRoot) show "${GuardRevision}:.orchestrator/invoke-heavy-verifier.ps1") -join "`n") } else { [IO.File]::ReadAllText($guard) }
  switch ($EligibilityMutant) {
    'role-spoof' { $source = $source.Replace('$binding = Get-HeavyCallerBinding', '$binding = Get-HeavyCallerBinding; if ($isHostVerifier -and $binding.Record.laneRole -ceq "review") { return [pscustomobject]@{ Record=$null } }') }
    'missing-role' { $source = $source.Replace("if (`$null -eq `$record) { throw 'dispatch record malformed or missing role' }", 'if ($null -eq $record) { return [pscustomobject]@{Record=$null;Reason=$null} }').Replace("throw 'dispatch census unknown or incomplete'", 'return [pscustomobject]@{Record=$null;Reason=$null}') }
    'host-denied' { $source = $source.Replace('$binding = Get-HeavyCallerBinding', '$binding = Get-HeavyCallerBinding; if (-not $binding.Record) { throw "heavy-verifier: caller eligibility: host denied mutant" }') }
    'bypass-check' { $source = $source.Replace('$callerBinding = Assert-HeavyCallerEligibility', '$callerBinding = $null # Assert-HeavyCallerEligibility') }
  }
  $source = Get-FixtureMutantSource $source
  $reservationMarker=Join-Path $root 'role-reservation.marker'
  $reservationAnchor='$coordinationMutex = [Threading.Mutex]'
  Assert-True ($source.Contains($reservationAnchor)) 'reservation probe has its exact acquisition boundary'
  $source=$source.Replace($reservationAnchor,"[IO.File]::WriteAllText('$reservationMarker','entered')`n$reservationAnchor")
  $nativeGuard = Join-Path $copyRoot 'invoke-heavy-verifier.ps1'
  [IO.File]::WriteAllText($nativeGuard, $source)
  $roleRunner=Join-Path $copyRoot 'run.ps1'
  [IO.File]::WriteAllText($roleRunner, 'param($Guard,$InputPath); $p=Get-Content -LiteralPath $InputPath -Raw | ConvertFrom-Json -AsHashtable -DateKind String; & $Guard @p; exit $LASTEXITCODE')
  function Invoke-RoleWrapper($Parameters) {
    $inputPath=Join-Path $copyRoot 'input.json'
    [IO.File]::WriteAllText($inputPath,($Parameters | ConvertTo-Json -Depth 8))
    $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    foreach($arg in @('-NoProfile','-File',$roleRunner,$nativeGuard,$inputPath)){[void]$start.ArgumentList.Add($arg)}
    $child=[Diagnostics.Process]::Start($start)
    $stdout=$child.StandardOutput.ReadToEndAsync(); $stderr=$child.StandardError.ReadToEndAsync()
    if(-not $child.WaitForExit(60000)){ $child.Kill($true); $child.WaitForExit(); throw 'inert role wrapper exceeded existing bounded fixture window' }
    return @{Code=$child.ExitCode;Output=$stdout.GetAwaiter().GetResult()+$stderr.GetAwaiter().GetResult()}
  }
  $self = Get-Process -Id $PID
  $parentId = [int](Get-CimInstance Win32_Process -Filter "ProcessId = $PID").ParentProcessId
  $parent = Get-Process -Id $parentId
  $launchId = [guid]::NewGuid().ToString()
  $recordPath = Join-Path $orchestrator "dispatch-launch-$launchId.json"
  $label = 'role-admission-fixture'
  $transcript = Join-Path $orchestrator "$label.jsonl"
  $record = [ordered]@{
    schemaVersion=4; launchId=$launchId; laneRole='implementation'
    promptPath=(Join-Path $orchestrator "dispatch-heavy-verifier-$launchId.prompt.txt"); reviewIsolationRoot=$null
    launcherPid=$parentId; launcherStartIdentity=$parent.StartTime.ToUniversalTime().ToString('o')
    recordedAt=$self.StartTime.ToUniversalTime().AddSeconds(-1).ToString('o'); state='started'
    childPid=$PID; childStartIdentity=$self.StartTime.ToUniversalTime().ToString('o')
    worktree=$nativeTree; lane='role-fixture'; identityMode='branch'; branch=$nativeBranch; head=$nativeHead
    label=$label; transcriptPath=$transcript
  }
  $route = [ordered]@{
    ts=$self.StartTime.ToUniversalTime().AddMilliseconds(-1).ToString('o'); kind='dispatch'; dispatchRoutingSchema='watchdog-dispatch-routing/v1'
    attemptId=$label; label=$label; lane='role-fixture'; laneRole='implementation'; transcript="$label.jsonl"
    harness='codex'; model='gpt-6-astra'; effort='high'; row='13'; placement='override-Todd'
    worktree=$nativeTree; branch=$nativeBranch; head=$nativeHead
  }
  $history = Join-Path $orchestrator 'dispatch-log.jsonl'
  [IO.File]::WriteAllText($history, ($route | ConvertTo-Json -Compress) + "`n")
  [IO.File]::WriteAllText($record.promptPath, 'synthetic inert role test')
  [IO.File]::WriteAllText($transcript, "{`"type`":`"item.completed`"}`n")
  $body = Join-Path $root 'role-body.txt'
  [IO.File]::WriteAllText((Join-Path $nativeTree 'package.json'),'{"name":"synthetic-role-admission","private":true,"scripts":{"verify:static":"node role-body.cjs"}}')
  [IO.File]::WriteAllText((Join-Path $nativeTree 'pnpm-lock.yaml'), "lockfileVersion: '9.0'`n`nsettings:`n  autoInstallPeers: true`n  excludeLinksFromLockfile: false`n`nimporters:`n`n  .: {}`n")
  [IO.File]::WriteAllText((Join-Path $nativeTree 'role-body.cjs'),("require('node:fs').writeFileSync(" + ($body|ConvertTo-Json -Compress) + ", 'forbidden');"))
  $batteryFixture = Join-Path $nativeTree '.orchestrator/controller-release-battery.ps1'
  # #9373/#120: the fake records -NoReuseIdentity, -ConcurrentIdentity and any unbound argument.
  $noReuseReceipt = Join-Path $root 'no-reuse-identity.json'
  $noReuseList = 'test:synthetic-a-9373.test.ps1;test:synthetic-b-9373.test.ps1'; $concurrentList = 'test:synthetic-a-120.test.ps1;test:synthetic-b-120.test.ps1'
  [IO.File]::WriteAllText($batteryFixture, @"
param(`$ControllerRoot,`$ExpectedControllerHead,`$EvidenceReceiptPath,`$ResultPath,`$BaselineHead,`$RepairIssue,`$RepairHistoryPath,`$Scope,`$PriorResultPath,`$NoReuseIdentity,`$ConcurrentIdentity,`$OnFailure,[switch]`$AdmissionOwned)
`$owner=Get-Content -LiteralPath '$((Join-Path $orchestrator 'controller-verify-lock.d/owner.json').Replace("'","''"))' -Raw | ConvertFrom-Json
if(-not `$AdmissionOwned -or `$owner.lockId -cne `$env:CHASE_SETS_HEAVY_SLOT_ID){throw 'fixture battery requires exact singleton owner'}
[IO.File]::WriteAllText('$noReuseReceipt',(@{value=`$NoReuseIdentity;concurrent=`$ConcurrentIdentity;unbound=@(`$args).Count} | ConvertTo-Json -Compress))
[IO.File]::WriteAllText('$body','allowed')
"@)
  # #9627: the inert fixture-equivalence stand-in records its body at $body.
  [IO.File]::WriteAllText((Join-Path $nativeTree '.orchestrator/cleanup-scale-fixture-equivalence.check.ps1'), $fixtureStandInCheck)
  [IO.File]::WriteAllText((Join-Path $nativeTree '.orchestrator/cleanup-scale-fixture-harness.ps1'), $fixtureStandInHarness)
  $env:HV_FIXTURE_BODY = $body
  $env:HV_FIXTURE_RUNTIME = $orchestrator
  & git -C $nativeTree add .orchestrator/controller-release-battery.ps1 .orchestrator/cleanup-scale-fixture-equivalence.check.ps1 .orchestrator/cleanup-scale-fixture-harness.ps1 package.json role-body.cjs pnpm-lock.yaml
  & git -C $nativeTree -c user.name=Fixture -c user.email=fixture@example.invalid commit --quiet -m 'inert standalone battery'
  Assert-True ($LASTEXITCODE -eq 0) 'inert battery committed in disposable fixture'
  $nativeHead=(& git -C $nativeTree rev-parse HEAD).Trim()
  $record.head=$nativeHead; $route.head=$nativeHead
  [IO.File]::WriteAllText($history, ($route | ConvertTo-Json -Compress) + "`n")
  $base = @{ Worktree=$nativeTree; Lane='erased-lane'; Branch=$nativeBranch; ClaimedHead=$nativeHead; ContainerRoot=$container }
  $modes = @{
    Gate=@{Gate='verify:static'}
    WorkspaceTest=@{WorkspaceTest='@chase-sets/ordering'}
    WorkspaceDbTest=@{WorkspaceDbTest='@chase-sets/payments';WorkspaceDbBudgetSeconds=1}
    Diagnostic=@{Diagnostic='worst13-no-fit';DiagnosticScriptPath='.orchestrator/artifacts/diagnostic.mjs';DiagnosticSha256=('a'*64);DiagnosticBudgetSeconds=1}
    NativeDb=@{NativeDbProfile='reconciliation-pg16/v1';NativeRequestPath=(Join-Path $root 'absent-request.json')}
    ControllerBattery=@{ControllerBattery=$true}
    ControllerPrecursor=@{ControllerPrecursor='fail-closed-guard-evidence';ControllerPrecursorArtifactPath='.orchestrator/artifacts/denied.json';ControllerPrecursorScenario='ReceiptClaims'}
    Attach=@{AdmissionKind='build';GuardedPid=$PID;GuardedProcessStartUtc=$record.childStartIdentity;AdmissionNonce=('a'*32);AdmissionCommand='build'}
    ControllerFixtureEquivalence=@{ControllerFixtureEquivalence=$true;ControllerFixtureEvidenceDirectory=(Join-Path $fixtureEvidenceRoot 'role-denied')}
  }
  # Derive mode completeness from the production parameter declaration.
  $tokens=$null; $errors=$null
  $modeAst=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
  $declaredModes=@($modeAst.ParamBlock.Parameters.Attributes.NamedArguments | Where-Object ArgumentName -CEQ 'ParameterSetName' | ForEach-Object {$_.Argument.Value} | Sort-Object -Unique)
  Assert-True (($declaredModes -join ',') -ceq ((@($modes.Keys | Sort-Object)) -join ',')) 'matrix covers every declared wrapper mode'
  foreach($mode in @('Gate','ControllerBattery')) {
    # ControllerBattery runs with both lists omitted, whose '' defaults the admitted
    # child must still receive, then with each list (#9373 -NoReuseIdentity, #120 -ConcurrentIdentity).
    $cases=if($mode -eq 'ControllerBattery'){@(@{},@{ControllerBatteryNoReuseIdentity=$noReuseList},@{ControllerBatteryConcurrentIdentity=$concurrentList})}else{@(@{})}
    foreach($case in $cases) {
      $parameters=$base + $modes[$mode] + $case + @{CommandPath=(Join-Path $PSHOME 'pwsh.exe');CommandArgumentList=@('-NoProfile','-Command',"[IO.File]::WriteAllText('$body','allowed')")}
      $result=Invoke-RoleWrapper $parameters; $output=$result.Output; $code=$result.Code
      Assert-True ($code -eq 0 -and (Test-Path $body)) "standalone $mode executes under ownership (exit=$code $($output -join ' '))"
      if($mode -eq 'ControllerBattery') {
        $expected=if($case.ContainsKey('ControllerBatteryNoReuseIdentity')){$noReuseList}else{''}; $expectedConcurrent=if($case.ContainsKey('ControllerBatteryConcurrentIdentity')){$concurrentList}else{''}
        $received=[IO.File]::ReadAllText($noReuseReceipt)
        $observed=$received | ConvertFrom-Json
        Assert-True ($observed.value -is [string] -and $observed.value -ceq $expected -and $observed.concurrent -is [string] -and $observed.concurrent -ceq $expectedConcurrent -and $observed.unbound -eq 0) "admitted battery child receives -NoReuseIdentity '$expected' and -ConcurrentIdentity '$expectedConcurrent' each as one argument: $received"
        Remove-Item -LiteralPath $noReuseReceipt
      }
      Remove-Item -LiteralPath $body
      Remove-Item -LiteralPath $reservationMarker
      Write-Output "PASS standalone-$mode exit=0 marker=1"
    }
  }
  # The closed fixture route has no command seam: its standalone positive runs
  # the tracked inert stand-in with the fixed grammar into a fresh directory.
  function Invoke-FixtureRolePositive([string]$Name) {
    $evidence = Join-Path $fixtureEvidenceRoot $Name
    $result = Invoke-RoleWrapper ($base + @{ControllerFixtureEquivalence=$true;ControllerFixtureEvidenceDirectory=$evidence})
    $ran = if (Test-Path $body) { [IO.File]::ReadAllText($body) | ConvertFrom-Json } else { $null }
    Assert-True ($result.Code -eq 0 -and $ran -and ($ran.argv -join '|') -ceq ((@('-NoProfile','-NonInteractive','-File',[IO.Path]::GetFullPath((Join-Path $nativeTree '.orchestrator/cleanup-scale-fixture-equivalence.check.ps1')),'-Phase','fixture','-EvidenceDirectory',$evidence)) -join '|') -and
      (Test-Path (Join-Path $evidence 'heavy-verifier-receipt.json')) -and -not (Test-Path (Join-Path $orchestrator 'controller-verify-lock.d'))) "$Name ControllerFixtureEquivalence executes its fixed command under ownership (exit=$($result.Code) $($result.Output))"
    Remove-Item -LiteralPath $body
    Remove-Item -LiteralPath $reservationMarker
  }
  Invoke-FixtureRolePositive 'standalone-fixture'
  Write-Output 'PASS standalone-ControllerFixtureEquivalence exit=0 marker=1 fixed-command=1 receipt=1'
  $roles=if($EligibilityMutant -ceq 'role-spoof'){@('review','missing','planning','implementation')}else{@('missing','review','planning','implementation')}
  foreach ($role in $roles) {
    $record.laneRole=$role
    $record.reviewIsolationRoot=if($role -cin @('review','planning')) { Join-Path ([IO.Path]::GetTempPath()) "chase-sets-$role-$launchId" } else { $null }
    $raw=$record | ConvertTo-Json -Compress
    if($role -eq 'missing') { $raw=$raw.Replace('"laneRole":"missing",','') }
    [IO.File]::WriteAllText($recordPath,$raw)
    foreach ($occupancy in @('idle','foreign-live')) {
      $foreign = @{}
      if($occupancy -eq 'foreign-live') {
        foreach($slot in @('verify-lock.d','controller-verify-lock.d')) {
          $directory=Join-Path $orchestrator $slot
          New-Item -ItemType Directory -Path $directory | Out-Null
          $ownerFile=Join-Path $directory 'owner.json'
          $ownerRaw=(New-OwnerRecord ('f'*32) $PID $record.childStartIdentity -ChildPid $PID -ChildStart $record.childStartIdentity) | ConvertTo-Json -Compress
          [IO.File]::WriteAllText($ownerFile,$ownerRaw); $foreign[$ownerFile]=$ownerRaw
        }
      }
      foreach($mode in @('GateFixture','Gate','WorkspaceTest','WorkspaceDbTest','NativeDb','Attach','ControllerBattery','ControllerPrecursor','ControllerFixtureEquivalence')) {
        $parameters=$base + $(if($mode -eq 'GateFixture'){$modes.Gate}else{$modes[$mode]})
        if($mode -eq 'GateFixture') {
          $parameters.CommandPath=Join-Path $PSHOME 'pwsh.exe'
          $parameters.CommandArgumentList=@('-NoProfile','-Command',"[IO.File]::WriteAllText('$body','forbidden')")
        }
        $admissionDirectory=$null
        if($mode -eq 'Attach') {
          $admissionDirectory=Join-Path ([IO.Path]::GetTempPath()) ('chase-sets-heavy-admission-'+[guid]::NewGuid().ToString('N'))
          New-Item -ItemType Directory -Path $admissionDirectory | Out-Null
          $parameters.AdmissionResultPath=Join-Path $admissionDirectory 'result.json'
        }
        $result=Invoke-RoleWrapper $parameters; $output=$result.Output; $code=$result.Code
        $reason=if($role -eq 'implementation'){'role=implementation routing-row=13'}elseif($role -eq 'missing'){'census unknown|malformed or missing role'}else{"role=$role"}
        Assert-True ($code -eq 73 -and ($output -join "`n") -match 'caller eligibility:' -and ($output -join "`n") -match $reason) "$role/$mode/$occupancy refuses by role/routing before command resolution (exit=$code body=$(Test-Path $body) $($output -join ' '))"
        Assert-True (-not (Test-Path $body) -and -not (Test-Path $reservationMarker) -and -not (Test-Path (Join-Path $nativeTree '.orchestrator/artifacts/denied.json')) -and
          -not (Test-Path $modes.ControllerFixtureEquivalence.ControllerFixtureEvidenceDirectory)) 'denial enters no reservation/wait/body/precursor/evidence boundary'
        foreach($entry in $foreign.GetEnumerator()) { Assert-True ([IO.File]::ReadAllText($entry.Key) -ceq $entry.Value) 'foreign record byte-identical' }
        if($occupancy -eq 'idle') { foreach($slot in @('verify-lock.d','controller-verify-lock.d')) { Assert-True (-not (Test-Path (Join-Path $orchestrator $slot))) 'denied caller creates no reservation' } }
        if($admissionDirectory) { Remove-Item -LiteralPath $admissionDirectory -Recurse -Force }
        Write-Output "PASS role=$role mode=$mode occupancy=$occupancy exit=73 no-reservation"
      }
      foreach($entry in $foreign.GetEnumerator()) { Remove-Item -LiteralPath (Split-Path -Parent $entry.Key) -Recurse -Force }
    }
  }
  $record.laneRole='implementation'; $record.reviewIsolationRoot=$null
  $route.row='7'
  [IO.File]::WriteAllText($recordPath,($record | ConvertTo-Json -Compress))
  [IO.File]::WriteAllText($history,($route | ConvertTo-Json -Compress)+"`n")
  $positive=$base + $modes.Gate + @{CommandPath=(Join-Path $PSHOME 'pwsh.exe');CommandArgumentList=@('-NoProfile','-Command',"[IO.File]::WriteAllText('$body','allowed')")}
  $result=Invoke-RoleWrapper $positive
  Assert-True ($result.Code -eq 0 -and (Test-Path $body)) "non-doc implementation executes (exit=$($result.Code) $($result.Output))"
  Remove-Item -LiteralPath $body
  Remove-Item -LiteralPath $reservationMarker
  Write-Output 'PASS implementation-row7 exit=0 marker=1'
  Invoke-FixtureRolePositive 'implementation-row7-fixture'
  Write-Output 'PASS implementation-row7 ControllerFixtureEquivalence exit=0 marker=1 fixed-command=1 receipt=1'
  $provenance=@{policyGeneration=1;registryAuthorityDigest='synthetic-8528';family='astra';slot='explicit';usedLastKnownGood=$false}
  foreach($name in $provenance.Keys){$record[$name]=$provenance[$name];$route[$name]=$provenance[$name]}
  $route.dispatchRoutingSchema='watchdog-dispatch-routing/v2'
  [IO.File]::WriteAllText($recordPath,($record|ConvertTo-Json -Compress))
  foreach($row in @(13,7)) {
    $route.row=[string]$row
    [IO.File]::WriteAllText($history,($route|ConvertTo-Json -Compress)+"`n")
    if($row -eq 7) {
      $unrelated=$route | ConvertTo-Json -Compress | ConvertFrom-Json -AsHashtable -DateKind String
      $unrelated.label='unrelated-newer-docs';$unrelated.transcript='unrelated-newer-docs.jsonl';$unrelated.row='13'
      [IO.File]::AppendAllText($history,((($unrelated|ConvertTo-Json -Compress)+"`n") * 2048))
    }
    $result=Invoke-RoleWrapper $positive
    if($row -eq 13){Assert-True ($result.Code -eq 73 -and $result.Output -match 'routing-row=13' -and -not(Test-Path $reservationMarker)) 'shared v2 row validator denies docs before reservation'}
    else {
      Assert-True ($result.Code -eq 0 -and (Test-Path $body)) "shared v2 row validator retains implementation: $($result.Output)"
      Remove-Item -LiteralPath $body,$reservationMarker
    }
    Write-Output "PASS native-v2 row=$row exit=$($result.Code) complete-history-unrelated-tail=$($row -eq 7)"
  }
  foreach($case in @('missing-row','ambiguous-row','wrong-head','provenance-mismatch','terminal','launching','PID-reused','missing-transcript')) {
    $originalRoute=$route | ConvertTo-Json -Compress
    $originalRecord=$record | ConvertTo-Json -Compress
    switch($case) {
      'missing-row' { [IO.File]::WriteAllText($history,'') }
      'ambiguous-row' { [IO.File]::WriteAllText($history,"$originalRoute`n$originalRoute`n") }
      'wrong-head' { $bad=$originalRoute|ConvertFrom-Json -AsHashtable -DateKind String;$bad.head='f'*40;[IO.File]::WriteAllText($history,($bad|ConvertTo-Json -Compress)+"`n") }
      'provenance-mismatch' { $bad=$originalRoute|ConvertFrom-Json -AsHashtable -DateKind String;$bad.registryAuthorityDigest='synthetic-foreign';[IO.File]::WriteAllText($history,($bad|ConvertTo-Json -Compress)+"`n") }
      'terminal' { [IO.File]::WriteAllText($transcript,"{`"type`":`"turn.completed`"}`n") }
      'launching' { $bad=$originalRecord|ConvertFrom-Json -AsHashtable -DateKind String;$bad.state='launching';$bad.childPid=$null;$bad.childStartIdentity=$null;[IO.File]::WriteAllText($recordPath,($bad|ConvertTo-Json -Compress)) }
      'PID-reused' { $bad=$originalRecord|ConvertFrom-Json -AsHashtable -DateKind String;$bad.childStartIdentity=$self.StartTime.ToUniversalTime().AddSeconds(-1).ToString('o');[IO.File]::WriteAllText($recordPath,($bad|ConvertTo-Json -Compress)) }
      'missing-transcript' { Remove-Item -LiteralPath $transcript }
    }
    $result=Invoke-RoleWrapper $positive
    Assert-True ($result.Code -eq 73 -and $result.Output -match 'caller eligibility:' -and -not (Test-Path $body) -and -not (Test-Path $reservationMarker) -and -not (Test-Path $lock)) "native $case fails closed"
    [IO.File]::WriteAllText($recordPath,$originalRecord)
    [IO.File]::WriteAllText($history,"$originalRoute`n")
    [IO.File]::WriteAllText($transcript,"{`"type`":`"item.completed`"}`n")
    Write-Output "PASS native $case exit=73 marker=0 owner=0"
  }
  Remove-Item -LiteralPath $recordPath
  $unrelatedStart=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
  $unrelatedStart.UseShellExecute=$false; $unrelatedStart.CreateNoWindow=$true
  foreach($arg in @('-NoProfile','-Command','Start-Sleep -Seconds 60')){[void]$unrelatedStart.ArgumentList.Add($arg)}
  $unrelated=[Diagnostics.Process]::Start($unrelatedStart)
  $unrelatedIdentity=$unrelated.StartTime.ToUniversalTime().Ticks
  try {
    $record.laneRole='review';$record.reviewIsolationRoot=Join-Path ([IO.Path]::GetTempPath()) "chase-sets-review-$launchId"
    $record.launcherPid=$PID;$record.launcherStartIdentity=$self.StartTime.ToUniversalTime().ToString('o')
    $record.childPid=$unrelated.Id;$record.childStartIdentity=$unrelated.StartTime.ToUniversalTime().ToString('o')
    [IO.File]::WriteAllText($recordPath,($record|ConvertTo-Json -Compress))
    $result=Invoke-RoleWrapper $positive
    Assert-True ($result.Code -eq 0 -and (Test-Path $body)) "unrelated healthy review does not deny host: $($result.Output)"
    Remove-Item -LiteralPath $body
    Write-Output 'PASS unrelated-review host exit=0 marker=1'
  } finally {
    if(-not $unrelated.HasExited -and $unrelated.StartTime.ToUniversalTime().Ticks -eq $unrelatedIdentity){$unrelated.Kill();$unrelated.WaitForExit()}
    Remove-Item -LiteralPath $recordPath
  }
  Remove-Item -LiteralPath $reservationMarker
  $reader=Join-Path $copyRoot 'dispatch-ownership.ps1'
  $readerBytes=[IO.File]::ReadAllBytes($reader)
  try {
    Remove-Item -LiteralPath $reader
    $result=Invoke-RoleWrapper ($base + $modes.ControllerBattery)
    Assert-True ($result.Code -eq 73 -and $result.Output -match 'caller eligibility: ownership reader unavailable' -and
      -not(Test-Path $body) -and -not(Test-Path $reservationMarker)) 'missing reader never grants standalone host authority'
    Write-Output 'PASS missing-ownership-reader host-ControllerBattery exit=73 body=0 reservation=0'
  } finally { [IO.File]::WriteAllBytes($reader,$readerBytes) }
}

# #9627 AC1/AC2: the closed ControllerFixtureEquivalence route, end to end
# through a disposable standalone-host container and an inert tracked stand-in.
function Test-ControllerFixtureEquivalence {
  $tree = Join-Path $container 'fixture-equivalence'
  $cloneOutput = @(& git clone --quiet $worktree $tree 2>&1)
  Assert-True ($LASTEXITCODE -eq 0) "fixture route clone: $cloneOutput"
  function Invoke-TreeGit([string[]]$Arguments) {
    $output = @(& git -C $tree -c user.name=Fixture -c user.email=fixture@example.invalid @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "fixture route git $($Arguments -join ' ') failed: $($output -join ' ')" }
    return ($output -join "`n").Trim()
  }
  # Pin the CRLF checkout the source-byte binding must accept on Windows.
  Invoke-TreeGit @('config', 'core.autocrlf', 'true') | Out-Null
  $checkRelative = '.orchestrator/cleanup-scale-fixture-equivalence.check.ps1'
  $harnessRelative = '.orchestrator/cleanup-scale-fixture-harness.ps1'
  $checkFull = [IO.Path]::GetFullPath((Join-Path $tree $checkRelative))
  [IO.File]::WriteAllText($checkFull, $fixtureStandInCheck)
  [IO.File]::WriteAllText((Join-Path $tree $harnessRelative), $fixtureStandInHarness)
  Invoke-TreeGit @('add', '--', $checkRelative, $harnessRelative) | Out-Null
  Invoke-TreeGit @('commit', '--quiet', '-m', 'inert fixture-equivalence stand-in') | Out-Null
  $branch = Invoke-TreeGit @('branch', '--show-current')
  # Heads whose check or harness is ignored but present: clean status, untracked source.
  $untracked = [ordered]@{}
  foreach ($relative in @($checkRelative, $harnessRelative)) {
    $name = if ($relative -ceq $checkRelative) { 'codex/fixture-untracked-check' } else { 'codex/fixture-untracked-harness' }
    Invoke-TreeGit @('checkout', '--quiet', '-b', $name) | Out-Null
    Invoke-TreeGit @('rm', '--quiet', '--cached', '--', $relative) | Out-Null
    [IO.File]::AppendAllText((Join-Path $tree '.gitignore'), "$relative`n")
    Invoke-TreeGit @('add', '--', '.gitignore') | Out-Null
    Invoke-TreeGit @('commit', '--quiet', '-m', "ignore $relative") | Out-Null
    $untracked[$relative] = [pscustomobject]@{ Branch = $name; Head = Invoke-TreeGit @('rev-parse', 'HEAD') }
    Invoke-TreeGit @('checkout', '--quiet', '-f', $branch) | Out-Null
  }
  Assert-True ((Invoke-TreeGit @('status', '--porcelain=v1', '--untracked-files=all')) -ceq '') 'fixture route tree is clean on its main branch'

  $fixtureGuardRoot = Join-Path $root 'fixture-guard'
  New-Item -ItemType Directory -Path $fixtureGuardRoot | Out-Null
  Copy-Item (Join-Path $PSScriptRoot 'dispatch-ownership.ps1') $fixtureGuardRoot
  $fixtureGuard = Join-Path $fixtureGuardRoot 'invoke-heavy-verifier.ps1'
  [IO.File]::WriteAllText($fixtureGuard, (Get-FixtureMutantSource (Get-GuardSource)))
  $fixtureRunner = Join-Path $fixtureGuardRoot 'run.ps1'
  # An uncaught refusal still exits 1; its message stays unwrapped for matching.
  [IO.File]::WriteAllText($fixtureRunner, 'param($Guard,$InputPath); $ErrorActionPreference=''Stop''; $p=Get-Content -LiteralPath $InputPath -Raw | ConvertFrom-Json -AsHashtable; try { & $Guard @p; exit $LASTEXITCODE } catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }')
  $controllerLock = Join-Path $orchestrator 'controller-verify-lock.d'
  $platformLock = Join-Path $orchestrator 'verify-lock.d'
  $fixtureBody = Join-Path $root 'fixture-route-body.json'
  $grandchildIdentity = Join-Path $root 'fixture-route-grandchild.json'
  $grandchildRelease = Join-Path $root 'fixture-route-grandchild.release'
  $script:fixtureSequence = 0
  function New-FixtureEvidence { $script:fixtureSequence++; return (Join-Path $fixtureEvidenceRoot "route-$script:fixtureSequence") }
  function Get-FixtureParameters([string]$Evidence, [hashtable]$Extra = @{}) {
    $parameters = @{
      ControllerFixtureEquivalence = $true; ControllerFixtureEvidenceDirectory = $Evidence
      Worktree = $tree; Lane = 'fixture-route'; Branch = (Invoke-TreeGit @('branch', '--show-current'))
      ClaimedHead = (Invoke-TreeGit @('rev-parse', 'HEAD')); ContainerRoot = $container
    }
    foreach ($entry in $Extra.GetEnumerator()) {
      if ($null -eq $entry.Value) { [void]$parameters.Remove($entry.Key) } else { $parameters[$entry.Key] = $entry.Value }
    }
    return $parameters
  }
  function Start-FixtureRoute([hashtable]$Parameters, [string]$Mode = '') {
    $inputPath = Join-Path $fixtureGuardRoot ('input-' + [guid]::NewGuid().ToString('N') + '.json')
    [IO.File]::WriteAllText($inputPath, ($Parameters | ConvertTo-Json -Depth 8))
    $start = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    foreach ($argument in @('-NoProfile', '-File', $fixtureRunner, $fixtureGuard, $inputPath)) { [void]$start.ArgumentList.Add($argument) }
    $start.Environment['HV_FIXTURE_STANDIN'] = $Mode
    $start.Environment['HV_FIXTURE_BODY'] = $fixtureBody
    $start.Environment['HV_FIXTURE_RUNTIME'] = $orchestrator
    $start.Environment['HV_FIXTURE_GRANDCHILD'] = $grandchildIdentity
    $start.Environment['HV_FIXTURE_RELEASE'] = $grandchildRelease
    $process = [Diagnostics.Process]::Start($start)
    $testWrapperIdentities.Add([pscustomobject]@{ pid = $process.Id; processStartUtc = $process.StartTime.ToUniversalTime().ToString('o') })
    return [pscustomobject]@{ Process = $process; Out = $process.StandardOutput.ReadToEndAsync(); Err = $process.StandardError.ReadToEndAsync() }
  }
  function Complete-FixtureRoute($Route) {
    if (-not $Route.Process.WaitForExit(90000)) { try { $Route.Process.Kill($true) } catch {}; throw 'ASSERTION FAILED: fixture route wrapper did not exit' }
    $Route.Process.WaitForExit()
    return [pscustomobject]@{ exitCode = $Route.Process.ExitCode; output = ($Route.Out.GetAwaiter().GetResult() + "`n" + $Route.Err.GetAwaiter().GetResult()).Trim() }
  }
  function Invoke-FixtureRoute([hashtable]$Parameters, [string]$Mode = '') { return Complete-FixtureRoute (Start-FixtureRoute $Parameters $Mode) }
  function Read-FixtureBody { if (Test-Path -LiteralPath $fixtureBody) { return [IO.File]::ReadAllText($fixtureBody) | ConvertFrom-Json -DateKind String } return $null }
  function Get-ExpectedArgv([string]$Evidence) { return @('-NoProfile', '-NonInteractive', '-File', $checkFull, '-Phase', 'fixture', '-EvidenceDirectory', $Evidence) -join '|' }
  # A refused route runs no body, leaves no controller owner and creates no evidence.
  function Assert-FixtureRefused($Result, [string]$Evidence, [string]$Pattern, [string]$Name, [int]$ExitCode = -1) {
    Assert-True ($Result.exitCode -ne 0 -and ($ExitCode -lt 0 -or $Result.exitCode -eq $ExitCode) -and $Result.output -match $Pattern -and
      -not (Test-Path -LiteralPath $fixtureBody) -and -not (Test-Path -LiteralPath $controllerLock) -and
      -not (Test-Path -LiteralPath $Evidence)) "fixture route $Name refuses before body (exit=$($Result.exitCode) body=$(Test-Path -LiteralPath $fixtureBody) lock=$(Test-Path -LiteralPath $controllerLock) evidence=$(Test-Path -LiteralPath $Evidence) output=$($Result.output))"
    Write-Output "PASS fixture-route $Name refused exit=$($Result.exitCode) body=0 owner=0 evidence=0"
  }
  function Assert-FixtureCompleted($Result, [string]$Evidence, [string]$Name, [int]$ExitCode = 0, [string]$IdentityMode = 'branch') {
    $ran = Read-FixtureBody
    Assert-True ($Result.exitCode -eq $ExitCode -and $ran) "fixture route $Name runs its body once and returns the child exit (exit=$($Result.exitCode) output=$($Result.output))"
    Assert-True (($ran.argv -join '|') -ceq (Get-ExpectedArgv $Evidence) -and ($ran.bound -join ',') -ceq 'EvidenceDirectory,Phase' -and $ran.unbound -eq 0 -and
      [IO.Path]::GetFullPath($ran.script) -ceq $checkFull) "fixture route $Name child is exactly the tracked check, -Phase fixture and the validated evidence (argv=$($ran.argv -join '|'))"
    Assert-True ($ran.evidenceEntries -eq 0) "fixture route $Name evidence was fresh and empty at child start"
    Assert-True (-not [string]::IsNullOrEmpty($ran.owner)) "fixture route $Name child runs under a published controller-slot owner (platform owner present=$(-not [string]::IsNullOrEmpty($ran.platformOwner)))"
    $owner = $ran.owner | ConvertFrom-Json -DateKind String
    $head = Invoke-TreeGit @('rev-parse', 'HEAD')
    Assert-True ($owner.lockId -ceq $ran.slot -and $owner.gate -ceq 'script-battery' -and $owner.state -ceq 'started' -and
      [int]$owner.childPid -eq [int]$ran.pid -and $owner.lane -ceq 'fixture-route' -and $owner.head -ceq $head -and
      $owner.identityMode -ceq $IdentityMode -and [IO.Path]::GetFullPath($owner.worktree) -ceq [IO.Path]::GetFullPath($tree)) "fixture route $Name child runs under its exact controller-slot owner ($($ran.owner))"
    $receiptPath = Join-Path $Evidence 'heavy-verifier-receipt.json'
    $receipt = if (Test-Path -LiteralPath $receiptPath) { [IO.File]::ReadAllText($receiptPath) | ConvertFrom-Json -DateKind String } else { $null }
    Assert-True ($receipt -and $receipt.exit -eq $ExitCode -and $receipt.head -ceq $head -and $receipt.lane -ceq 'fixture-route' -and
      $receipt.slot -ceq 'controller-verify-lock.d' -and $receipt.lockId -ceq $owner.lockId -and [int]$receipt.child.pid -eq [int]$ran.pid -and
      ($receipt.arguments -join '|') -ceq (Get-ExpectedArgv $Evidence) -and $receipt.released -eq $true -and
      $receipt.sources.$checkRelative -ceq (Invoke-TreeGit @('rev-parse', "HEAD:$checkRelative")) -and
      $receipt.sources.$harnessRelative -ceq (Invoke-TreeGit @('rev-parse', "HEAD:$harnessRelative")) -and
      $receipt.wrapper.sha256 -ceq [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($fixtureGuard))).ToLowerInvariant()) "fixture route $Name writes its post-release owner receipt"
    Assert-True (-not (Test-Path -LiteralPath $controllerLock)) "fixture route $Name releases its exact controller owner"
    Remove-Item -LiteralPath $fixtureBody
    $script:fixtureLastBody = $ran
    Write-Output "PASS fixture-route $Name exit=$ExitCode fixed-command=1 controller-owner=1 receipt=1 released=1"
  }
  # Observes one refusal without asserting, so a failing-first run reports every
  # boundary case; a stray body record is cleared so the next case starts clean.
  function Get-FixtureRefusalState($Result, [string]$Evidence, [string]$Pattern, [string]$Name, [string]$Untouched = '') {
    $state = [pscustomobject]@{
      Name = $Name; Exit = $Result.exitCode; Matched = $Result.output -match $Pattern; Output = $Result.output
      Body = Test-Path -LiteralPath $fixtureBody; Owner = Test-Path -LiteralPath $controllerLock
      Evidence = Test-Path -LiteralPath $Evidence; Written = [bool]$Untouched -and (Test-Path -LiteralPath $Untouched)
    }
    if ($state.Body) { Remove-Item -LiteralPath $fixtureBody }
    return $state
  }

  try {
    # AC1: the eligible standalone host selects exactly the fixed full-phase command.
    $evidence = New-FixtureEvidence
    Assert-FixtureCompleted (Invoke-FixtureRoute (Get-FixtureParameters $evidence)) $evidence 'branch-positive'
    Assert-True ($null -eq $script:fixtureLastBody.platformOwner -and -not (Test-Path -LiteralPath $platformLock)) 'fixture route never takes the platform slot'
    Invoke-TreeGit @('checkout', '--quiet', '--detach') | Out-Null
    $evidence = New-FixtureEvidence
    Assert-FixtureCompleted (Invoke-FixtureRoute (Get-FixtureParameters $evidence @{ Branch = $null; ClaimedHead = $null; ImmutableHead = (Invoke-TreeGit @('rev-parse', 'HEAD')) })) $evidence 'immutable-head-positive' 0 'immutable-head'
    Invoke-TreeGit @('checkout', '--quiet', $branch) | Out-Null

    # AC1 one-variable selector, head and source controls.
    $evidence = New-FixtureEvidence
    Assert-FixtureRefused (Invoke-FixtureRoute (Get-FixtureParameters $evidence @{ ControllerFixturePhase = 'all' })) $evidence 'ControllerFixturePhase' 'unknown-selector'
    Assert-FixtureRefused (Invoke-FixtureRoute (Get-FixtureParameters $evidence @{ CommandPath = (Join-Path $PSHOME 'pwsh.exe'); CommandArgumentList = @('-NoProfile', '-Command', 'exit 0') })) $evidence 'parameter set' 'command-seam'
    Assert-FixtureRefused (Invoke-FixtureRoute (Get-FixtureParameters $evidence @{ Gate = 'verify:static' })) $evidence 'parameter set' 'mixed-selector'
    Assert-FixtureRefused (Invoke-FixtureRoute (Get-FixtureParameters $evidence @{ ClaimedHead = ('0' * 40) })) $evidence 'exact launch-time HEAD' 'wrong-head'
    Assert-FixtureRefused (Invoke-FixtureRoute (Get-FixtureParameters $evidence @{ Branch = 'codex/not-live' })) $evidence 'does not match the live Git branch' 'wrong-branch'
    $dirty = Join-Path $tree 'dirty.txt'
    [IO.File]::WriteAllText($dirty, 'dirty')
    Assert-FixtureRefused (Invoke-FixtureRoute (Get-FixtureParameters $evidence)) $evidence 'clean exact-head worktree' 'dirty-worktree'
    Remove-Item -LiteralPath $dirty
    [IO.File]::AppendAllText($checkFull, "`n# substituted`n")
    Assert-FixtureRefused (Invoke-FixtureRoute (Get-FixtureParameters $evidence)) $evidence 'clean exact-head worktree' 'modified-check'
    Invoke-TreeGit @('checkout', '--quiet', '--', $checkRelative) | Out-Null
    foreach ($relative in $untracked.Keys) {
      Invoke-TreeGit @('checkout', '--quiet', $untracked[$relative].Branch) | Out-Null
      [IO.File]::WriteAllText((Join-Path $tree $relative), $(if ($relative -ceq $checkRelative) { $fixtureStandInCheck } else { $fixtureStandInHarness }))
      Assert-True ((Invoke-TreeGit @('status', '--porcelain=v1', '--untracked-files=all')) -ceq '') "ignored $relative leaves a clean status"
      Assert-FixtureRefused (Invoke-FixtureRoute (Get-FixtureParameters $evidence)) $evidence 'not one exact tracked regular script' "untracked-$(Split-Path -Leaf $relative)"
      Invoke-TreeGit @('checkout', '--quiet', '-f', $branch) | Out-Null
    }

    # AC1 evidence-path controls: one closed root beside the container, one fresh leaf.
    foreach ($case in @(
        @('relative', 'fixture-relative', 'absolute directory below the closed evidence root'),
        @('inside-worktree', (Join-Path $tree 'fixture-evidence'), 'directly below the closed evidence root'),
        @('inside-runtime', (Join-Path $orchestrator 'fixture-evidence'), 'directly below the closed evidence root'),
        @('system-temp', (Join-Path $systemTemp ('fixture-evidence-' + [guid]::NewGuid().ToString('N'))), 'directly below the closed evidence root'),
        @('nested', (Join-Path $fixtureEvidenceRoot 'nested\leaf'), 'directly below the closed evidence root'),
        @('traversal', ($fixtureEvidenceRoot + '\up\..\traversal'), 'directly below the closed evidence root'),
        @('leaf-space', (Join-Path $fixtureEvidenceRoot 'bad name'), 'directly below the closed evidence root'),
        @('leaf-dot', (Join-Path $fixtureEvidenceRoot 'dotted.leaf'), 'directly below the closed evidence root'))) {
      Assert-FixtureRefused (Invoke-FixtureRoute (Get-FixtureParameters $case[1])) $case[1] $case[2] "evidence-$($case[0])"
    }
    $reused = Join-Path $fixtureEvidenceRoot 'reused'
    New-Item -ItemType Directory -Path $reused | Out-Null
    [IO.File]::WriteAllText((Join-Path $reused 'prior.txt'), 'prior')
    $result = Invoke-FixtureRoute (Get-FixtureParameters $reused)
    Assert-True ($result.exitCode -ne 0 -and $result.output -match 'already exists' -and -not (Test-Path -LiteralPath $fixtureBody) -and
      @(Get-ChildItem -LiteralPath $reused -Force).Count -eq 1 -and -not (Test-Path -LiteralPath $controllerLock)) "fixture route refuses a reused evidence directory and preserves it ($($result.output))"
    Write-Output 'PASS fixture-route evidence-reused refused body=0 owner=0 preserved=1'
    $reparseTarget = Join-Path $root 'fixture-reparse-target'
    New-Item -ItemType Directory -Path $reparseTarget | Out-Null
    $leafJunction = Join-Path $fixtureEvidenceRoot 'junction-leaf'
    New-Item -ItemType Junction -Path $leafJunction -Target $reparseTarget | Out-Null
    $result = Invoke-FixtureRoute (Get-FixtureParameters $leafJunction)
    Assert-True ($result.exitCode -ne 0 -and $result.output -match 'already exists' -and -not (Test-Path -LiteralPath $fixtureBody) -and
      @(Get-ChildItem -LiteralPath $reparseTarget -Force).Count -eq 0) "fixture route refuses a reparse evidence leaf without writing through it ($($result.output))"
    Remove-Item -LiteralPath $leafJunction -Force
    Write-Output 'PASS fixture-route evidence-reparse-leaf refused body=0 target-untouched=1'
    $asideRoot = Join-Path $root 'fixture-evidence-root-aside'
    [IO.Directory]::Move($fixtureEvidenceRoot, $asideRoot)
    try {
      New-Item -ItemType Junction -Path $fixtureEvidenceRoot -Target $reparseTarget | Out-Null
      $evidence = Join-Path $fixtureEvidenceRoot 'through-root-junction'
      $result = Invoke-FixtureRoute (Get-FixtureParameters $evidence)
      Assert-True ($result.exitCode -ne 0 -and $result.output -match 'reparse point' -and -not (Test-Path -LiteralPath $fixtureBody) -and
        @(Get-ChildItem -LiteralPath $reparseTarget -Force).Count -eq 0 -and -not (Test-Path -LiteralPath $controllerLock)) "fixture route refuses a reparse evidence root before admission ($($result.output))"
      Remove-Item -LiteralPath $fixtureEvidenceRoot -Force
    } finally {
      if (-not (Test-Path -LiteralPath $fixtureEvidenceRoot)) { [IO.Directory]::Move($asideRoot, $fixtureEvidenceRoot) }
    }
    Write-Output 'PASS fixture-route evidence-reparse-root refused body=0 owner=0 target-untouched=1'
    $gitMarker = Join-Path $root '.git'
    New-Item -ItemType Directory -Path $gitMarker | Out-Null
    try {
      $evidence = New-FixtureEvidence
      Assert-FixtureRefused (Invoke-FixtureRoute (Get-FixtureParameters $evidence)) $evidence 'inside a Git worktree' 'evidence-inside-git'
    } finally { Remove-Item -LiteralPath $gitMarker -Recurse -Force }

    # AC1 executed bytes: a fresh LF checkout (the exact HEAD blob) and a fresh
    # core.autocrlf CRLF checkout both run.
    foreach ($ending in @('lf', 'crlf')) {
      Invoke-TreeGit @('config', 'core.autocrlf', $(if ($ending -ceq 'crlf') { 'true' } else { 'false' })) | Out-Null
      foreach ($relative in @($checkRelative, $harnessRelative)) { Remove-Item -LiteralPath (Join-Path $tree $relative) }
      Invoke-TreeGit @('checkout', '--quiet', '--', $checkRelative, $harnessRelative) | Out-Null
      foreach ($relative in @($checkRelative, $harnessRelative)) {
        $raw = Invoke-TreeGit @('hash-object', '--no-filters', '--', $relative)
        Assert-True (($raw -ceq (Invoke-TreeGit @('rev-parse', "HEAD:$relative"))) -eq ($ending -ceq 'lf')) "$ending $relative is $(if ($ending -ceq 'lf') { 'the exact blob' } else { 'a CRLF rendering, not the blob' })"
      }
      Assert-True ((Invoke-TreeGit @('status', '--porcelain=v1', '--untracked-files=all')) -ceq '') "$ending sources leave a clean status"
      $evidence = New-FixtureEvidence
      Assert-FixtureCompleted (Invoke-FixtureRoute (Get-FixtureParameters $evidence)) $evidence "$ending-sources-positive"
    }

    # AC1 boundary cases (#9627 gov-r1 F1/F2), judged together after all ran.
    $boundary = [Collections.Generic.List[object]]::new()
    # F1: an index flag hides substituted check or harness bytes from status.
    foreach ($flag in @('assume-unchanged', 'skip-worktree')) {
      foreach ($relative in @($checkRelative, $harnessRelative)) {
        Invoke-TreeGit @('update-index', "--$flag", '--', $relative) | Out-Null
        try {
          [IO.File]::AppendAllText((Join-Path $tree $relative), "`n# substituted under $flag`n")
          Assert-True ((Invoke-TreeGit @('status', '--porcelain=v1', '--untracked-files=all')) -ceq '') "$flag hides substituted $relative from status"
          $evidence = New-FixtureEvidence
          $boundary.Add((Get-FixtureRefusalState (Invoke-FixtureRoute (Get-FixtureParameters $evidence)) $evidence 'do not match the exact HEAD blob' "$flag-$(Split-Path -Leaf $relative)"))
        } finally {
          Invoke-TreeGit @('update-index', "--no-$flag", '--', $relative) | Out-Null
          Invoke-TreeGit @('checkout', '--quiet', '--', $relative) | Out-Null
        }
      }
    }
    # F1 on the existing post-acquisition recheck: bytes hidden after admission.
    $evidence = New-FixtureEvidence
    $route = Start-FixtureRoute (Get-FixtureParameters $evidence @{ TestDelayIdentityRevalidationMilliseconds = 1500 })
    try {
      Wait-Condition { $o = if (Test-Path -LiteralPath (Join-Path $controllerLock 'owner.json')) { try { [IO.File]::ReadAllText((Join-Path $controllerLock 'owner.json')) | ConvertFrom-Json } catch { $null } }; $o -and $o.state -ceq 'launching' } 'fixture route acquisition before hidden substitution'
      Invoke-TreeGit @('update-index', '--skip-worktree', '--', $checkRelative) | Out-Null
      [IO.File]::AppendAllText($checkFull, "`n# substituted after admission`n")
      $boundary.Add((Get-FixtureRefusalState (Complete-FixtureRoute $route) $evidence 'do not match the exact HEAD blob' 'recheck-skip-worktree-check'))
    } finally {
      Invoke-TreeGit @('update-index', '--no-skip-worktree', '--', $checkRelative) | Out-Null
      Invoke-TreeGit @('checkout', '--quiet', '--', $checkRelative) | Out-Null
    }
    Assert-True ((Invoke-TreeGit @('status', '--porcelain=v1', '--untracked-files=all')) -ceq '') 'index-flag cases restore a clean tree'
    # F2: one variable, the evidence ancestry. The container is spelled through an
    # ancestor junction into a synthetic Git worktree whose .git lies outside the
    # lexical ancestry; a nested junction keeps the physical container, lock and
    # census unchanged.
    $gitTarget = Join-Path $root 'fixture-ancestor-git'
    $gitNested = Join-Path $gitTarget 'nested'
    New-Item -ItemType Directory -Path $gitNested | Out-Null
    $initOutput = @(& git init --quiet $gitTarget 2>&1)
    Assert-True ($LASTEXITCODE -eq 0) "synthetic ancestor-junction Git worktree: $initOutput"
    $containerLeaf = Split-Path -Leaf $container
    $containerLink = Join-Path $gitNested $containerLeaf
    $ancestorJunction = Join-Path $root 'fixture-ancestor-junction'
    $aliasContainer = Join-Path $ancestorJunction $containerLeaf
    $aliasEvidenceRoot = Join-Path $ancestorJunction "$containerLeaf-heavy-evidence"
    $physicalEvidenceRoot = Join-Path $gitNested "$containerLeaf-heavy-evidence"
    # Runs only the evidence-path functions of the guard under test, so the
    # ancestry is the single variable even though route identity refuses first.
    $evidenceProbe = Join-Path $fixtureGuardRoot 'evidence-probe.ps1'
    [IO.File]::WriteAllText($evidenceProbe, @'
param([string]$Guard, [string]$Container, [string]$Evidence)
$ErrorActionPreference = 'Stop'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($Guard, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'guard parse failed' }
$names = @('Test-PathEntry', 'Test-PrecursorSafeDirectory', 'Resolve-ControllerFixtureEvidence', 'Assert-ControllerFixtureEvidencePath', 'Assert-ControllerFixtureEvidenceFresh', 'New-ControllerFixtureEvidence')
foreach ($function in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $names -ccontains $node.Name }, $true)) {
  . ([scriptblock]::Create($function.Extent.Text))
}
$container = $Container
try { Resolve-ControllerFixtureEvidence $Evidence; New-ControllerFixtureEvidence; 'evidence guard accepted'; exit 0 }
catch { $_.Exception.Message; exit 1 }
'@)
    function Invoke-EvidenceGuardProbe([string]$ContainerPath, [string]$Evidence) {
      $output = @(& (Join-Path $PSHOME 'pwsh.exe') -NoProfile -NonInteractive -File $evidenceProbe $fixtureGuard $ContainerPath $Evidence 2>&1)
      return [pscustomobject]@{ exitCode = $LASTEXITCODE; output = ($output -join "`n").Trim() }
    }
    $evidence = Join-Path $fixtureEvidenceRoot 'guard-plain'
    $result = Invoke-EvidenceGuardProbe $container $evidence
    Assert-True ($result.exitCode -eq 0 -and (Test-Path -LiteralPath $evidence -PathType Container)) "evidence guard accepts the plain container spelling ($($result.output))"
    Write-Output 'PASS fixture-route guard-plain-ancestry accepted=1 created=1'
    try {
      New-Item -ItemType Junction -Path $containerLink -Target $container | Out-Null
      New-Item -ItemType Junction -Path $ancestorJunction -Target $gitNested | Out-Null
      # End to end the worktree must sit below that container too, and Git names
      # its junction-resolved root, so worktree identity refuses first.
      $evidence = Join-Path $aliasEvidenceRoot 'route-ancestor-junction'
      $parameters = Get-FixtureParameters $evidence @{ ContainerRoot = $aliasContainer; Worktree = (Join-Path $aliasContainer (Split-Path -Leaf $tree)) }
      $boundary.Add((Get-FixtureRefusalState (Invoke-FixtureRoute $parameters) $evidence 'canonical Git worktree root' 'route-ancestor-junction' $physicalEvidenceRoot))
      $evidence = Join-Path $aliasEvidenceRoot 'guard-ancestor-junction'
      $boundary.Add((Get-FixtureRefusalState (Invoke-EvidenceGuardProbe $aliasContainer $evidence) $evidence 'evidence ancestor is a symlink, reparse point' 'guard-ancestor-junction' $physicalEvidenceRoot))
    } finally {
      # Delete only the links, never through them.
      foreach ($link in @($ancestorJunction, $containerLink)) { if (Test-Path -LiteralPath $link) { [IO.Directory]::Delete($link, $false) } }
    }
    foreach ($state in $boundary) {
      $flat = $state.Output -replace '\s+', ' '
      Write-Output "CASE fixture-route $($state.Name) exit=$($state.Exit) matched=$($state.Matched) body=$([int]$state.Body) owner=$([int]$state.Owner) evidence=$([int]$state.Evidence) target-write=$([int]$state.Written) output=$($flat.Substring(0, [Math]::Min(240, $flat.Length)))"
    }
    foreach ($state in $boundary) {
      Assert-True ($state.Exit -ne 0 -and $state.Matched -and -not ($state.Body -or $state.Owner -or $state.Evidence -or $state.Written)) "fixture route $($state.Name) refuses before body, owner, evidence or target write ($($state.Output))"
      Write-Output "PASS fixture-route $($state.Name) refused exit=$($state.Exit) body=0 owner=0 evidence=0 target-write=0"
    }

    # AC2: controller-slot exclusivity and independence from the platform slot.
    $live = Get-ProcessIdentity $PID
    foreach ($slot in @('controller', 'platform')) {
      $slotLock = if ($slot -ceq 'controller') { $controllerLock } else { $platformLock }
      New-Item -ItemType Directory -Path $slotLock | Out-Null
      $foreign = New-OwnerRecord ('7' * 32) $live.pid $live.processStartUtc 'launching'
      $foreign.startedUtc = [DateTime]::UtcNow.ToString('o')
      [IO.File]::WriteAllText((Join-Path $slotLock 'owner.json'), ($foreign | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
      $foreignRaw = [IO.File]::ReadAllText((Join-Path $slotLock 'owner.json'))
      $evidence = New-FixtureEvidence
      $result = Invoke-FixtureRoute (Get-FixtureParameters $evidence)
      if ($slot -ceq 'controller') {
        Assert-True ($result.exitCode -eq 73 -and $result.output -match 'lock unavailable \(live-owner' -and -not (Test-Path -LiteralPath $fixtureBody) -and
          -not (Test-Path -LiteralPath $evidence)) "live controller owner refuses the fixture route with 73 before evidence or body (exit=$($result.exitCode) $($result.output))"
        Write-Output 'PASS fixture-route live-controller-owner exit=73 body=0 evidence=0'
      } else {
        Assert-FixtureCompleted $result $evidence 'beside-live-platform-owner'
      }
      Assert-True ([IO.File]::ReadAllText((Join-Path $slotLock 'owner.json')) -ceq $foreignRaw) "foreign $slot owner stays byte-exact"
      Remove-Item -LiteralPath $slotLock -Recurse -Force
    }

    # AC2: native failure exit, cancellation and HEAD movement after acquisition.
    $evidence = New-FixtureEvidence
    Assert-FixtureCompleted (Invoke-FixtureRoute (Get-FixtureParameters $evidence) 'fail') $evidence 'child-failure' 29
    $evidence = New-FixtureEvidence
    $result = Invoke-FixtureRoute (Get-FixtureParameters $evidence @{ TestCancelAfterAcquisition = $true })
    Assert-True ($result.exitCode -ne 0 -and $result.output -match 'test cancellation' -and -not (Test-Path -LiteralPath $fixtureBody) -and
      -not (Test-Path -LiteralPath $controllerLock) -and -not (Test-Path -LiteralPath (Join-Path $evidence 'heavy-verifier-receipt.json'))) "fixture route cancellation runs no body and releases its exact owner ($($result.output))"
    Write-Output 'PASS fixture-route cancellation body=0 released=1 receipt=0'
    $evidence = New-FixtureEvidence
    $mover = Start-FixtureRoute (Get-FixtureParameters $evidence @{ TestDelayIdentityRevalidationMilliseconds = 1500 })
    Wait-Condition { $o = if (Test-Path -LiteralPath (Join-Path $controllerLock 'owner.json')) { try { [IO.File]::ReadAllText((Join-Path $controllerLock 'owner.json')) | ConvertFrom-Json } catch { $null } }; $o -and $o.state -ceq 'launching' } 'fixture route acquisition before HEAD movement'
    Invoke-TreeGit @('commit', '--quiet', '--allow-empty', '-m', 'fixture route head movement') | Out-Null
    $result = Complete-FixtureRoute $mover
    Assert-FixtureRefused $result $evidence 'branch or HEAD changed after acquisition' 'head-moved-after-acquisition'

    # AC2: a surviving descendant keeps the exact owner until the whole tree exits.
    $evidence = New-FixtureEvidence
    $route = Start-FixtureRoute (Get-FixtureParameters $evidence) 'descendant'
    try {
      # Publication chains three cold pwsh starts (wrapper, stand-in, harness)
      # and outlasts the 400-poll default under load (#206), so it gets the
      # route's own 90-second budget.
      Wait-Condition { (Test-Path -LiteralPath $grandchildIdentity) -and (Test-Path -LiteralPath $fixtureBody) } 'fixture route descendant publication' 90
      $standIn = Read-FixtureBody
      Wait-Condition { -not (Test-ExactProcess ([pscustomobject]@{ pid = $standIn.pid; processStartUtc = $standIn.processStartUtc })) } 'fixture route child exit'
      $grandchild = Read-ChildIdentity $grandchildIdentity
      for ($sample = 0; $sample -lt 8; $sample++) {
        Start-Sleep -Milliseconds 250
        Assert-True ((Test-ExactProcess $grandchild) -and -not $route.Process.HasExited -and (Test-Path -LiteralPath (Join-Path $controllerLock 'owner.json'))) "fixture route retains its exact owner while a descendant survives its child (sample $sample)"
      }
    } finally {
      [IO.File]::WriteAllText($grandchildRelease, 'release')
    }
    $result = Complete-FixtureRoute $route
    Remove-Item -LiteralPath $grandchildRelease, $grandchildIdentity
    Assert-FixtureCompleted $result $evidence 'surviving-descendant'
    Write-Output 'PASS fixture-route surviving-descendant owner-retained=1 released-after-tree=1'
  } finally {
    if (Test-Path -LiteralPath $grandchildIdentity) {
      try { $identity = Read-ChildIdentity $grandchildIdentity; if (Test-ExactProcess $identity) { Stop-ExactProcess $identity } } catch {}
    }
  }
  Write-Output "PASS heavy verifier ControllerFixtureEquivalence closed route (mutant=$(if ($FixtureMutant) { $FixtureMutant } else { 'none' }))"
}
# #206 discriminator. A synthetic census pins exactly which processes teardown
# may stop. Then a recorded relay starts a holder whose working directory is
# inside a probe and exits, the shape of the fixture-route harness after its
# stand-in: plain removal fails, teardown leaves that orphan running while only
# its exited relay is recorded, and stops it and removes the probe once the
# holder's own identity is recorded explicitly.
function Test-DisposableTeardown {
  $base = [DateTime]::UtcNow.Ticks
  $named = "pwsh.exe -File $root\fixture.ps1"
  $table = @{}
  foreach ($row in @(
      @(-1, -2, -100, $named),                            # ancestor of this test: never selected
      @($PID, -1, 0, 'pwsh.exe -File test.ps1'),
      @(-10, $PID, 10, $named),                           # child naming the root: selected
      @(-11, -10, 20, 'git.exe status'),                  # its unnamed child: selected through it
      @(-12, $PID, 10, 'pwsh.exe -Command Start-Sleep'),  # child outside the root: kept
      @(-20, -99, 30, 'harness'),                         # unrecorded orphan of exited recorded -99: kept
      @(-23, -99, 35, 'harness'),                         # recorded orphan of exited recorded -99: selected
      @(-21, -98, 30, $named),                            # orphan of unrecorded -98 naming the root: kept
      @(-22, -1, 30, $named),                             # sibling of this test naming the root: kept
      @(-97, -1, 50, 'reused'),                           # newer holder of recorded PID -97: kept
      @(-30, -97, 60, $named),                            # its child: kept
      @(-31, -97, 40, 'orphan'),                          # unrecorded, predates that reuse: kept
      @(-50, -2, 42, 'wrapper'),                          # live exact recorded wrapper: selected
      @(-51, -50, 45, 'harness'),                         # its unrecorded child: selected through it
      @(-40, -96, 70, 'published'))) {                    # exact published identity: selected
    $table[[int]$row[0]] = [pscustomobject]@{ Id = [int]$row[0]; ParentId = [int]$row[1]; StartTicks = $base + 1000 * $row[2]; Name = 'synthetic'; Text = [string]$row[3] }
  }
  $known = @(foreach ($recorded in @(@(-99, 5), @(-97, 5), @(-40, 70), @(-23, 35), @(-50, 42))) { [pscustomobject]@{ Id = $recorded[0]; StartTicks = $base + 1000 * $recorded[1] } })
  $selected = @(Select-TeardownProcesses $table $known $root $PID | ForEach-Object { $_.Id } | Sort-Object)
  Assert-True (($selected -join ',') -ceq '-51,-50,-40,-23,-11,-10') "teardown selects only exact descendants of this test or of a live recorded identity, or exact recorded identities, under the root (selected=$($selected -join ','))"

  $probe = Join-Path $root 'teardown-probe'
  $held = Join-Path $probe 'held'
  New-Item -ItemType Directory -Path $held | Out-Null
  # Not *.json, so the holder stays unrecorded until the test records it explicitly.
  $holderIdentityPath = Join-Path $probe 'holder.identity'
  $relayScript = Join-Path $probe 'relay.ps1'
  [IO.File]::WriteAllText($relayScript, @'
param([string]$Held, [string]$IdentityPath)
$start = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
$start.UseShellExecute = $false; $start.CreateNoWindow = $true; $start.WorkingDirectory = $Held
$start.Environment['HV_TEARDOWN_HOLDER'] = $IdentityPath
foreach ($argument in @('-NoProfile', '-NonInteractive', '-Command', '$self = Get-Process -Id $PID; [IO.File]::WriteAllText($env:HV_TEARDOWN_HOLDER, ([ordered]@{ pid = $PID; processStartUtc = $self.StartTime.ToUniversalTime().ToString(''o'') } | ConvertTo-Json -Compress)); Start-Sleep -Seconds 120')) { [void]$start.ArgumentList.Add($argument) }
[void][Diagnostics.Process]::Start($start)
exit 0
'@)
  $relayStart = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
  $relayStart.UseShellExecute = $false; $relayStart.CreateNoWindow = $true
  foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $relayScript, $held, $holderIdentityPath)) { [void]$relayStart.ArgumentList.Add($argument) }
  $relay = [Diagnostics.Process]::Start($relayStart)
  $relayIdentity = [pscustomobject]@{ pid = $relay.Id; processStartUtc = $relay.StartTime.ToUniversalTime().ToString('o') }
  # Recorded like a wrapper. The holder is recorded too once it publishes: with
  # its relay exited, only its own exact identity lets a teardown stop it.
  $testWrapperIdentities.Add($relayIdentity)
  $holder = $null
  try {
    Wait-Condition { $relay.HasExited -and $(try { $null -ne (Read-ChildIdentity $holderIdentityPath).pid } catch { $false }) } 'teardown probe holder publication after its relay exits' 90
    $holder = Read-ChildIdentity $holderIdentityPath
    $testWrapperIdentities.Add($holder)
    $blocked = $false
    try { Remove-Item -LiteralPath $probe -Recurse -Force } catch { $blocked = $true }
    Assert-True ($blocked -and (Test-ExactProcess $holder) -and (Test-Path -LiteralPath $held)) "plain removal fails while the exited relay's orphan holds its working directory (control)"
    # Control: with only the exited relay recorded, the holder is an unrecorded
    # child of an absent parent, which PID reuse could fake, so it is left running.
    $unrecorded = Complete-DisposableTeardown $probe @($relayIdentity) 1
    Assert-True (-not $unrecorded.Removed -and $unrecorded.Stopped.Count -eq 0 -and (Test-ExactProcess $holder) -and (Test-Path -LiteralPath $held)) "teardown leaves the exited relay's unrecorded orphan running and retains the probe (control: removed=$($unrecorded.Removed) stopped=$($unrecorded.Stopped.Count))"
    $result = Complete-DisposableTeardown $probe @($relayIdentity, $holder) 3
    Assert-True ($result.Removed -and -not (Test-Path -LiteralPath $probe) -and -not (Test-ExactProcess $holder) -and
      @($result.Stopped | Where-Object { $_.Id -eq [int]$holder.pid }).Count -eq 1) "teardown stops the explicitly recorded orphan and removes the probe (removed=$($result.Removed) reason=$($result.Reason))"
  } finally {
    foreach ($identity in @($holder, $relayIdentity)) {
      if ($identity -and (Test-ExactProcess $identity)) { Stop-ExactProcess $identity }
    }
  }
  Write-Output 'PASS teardown stops only exact descendants under the root: synthetic census, unrecorded orphan of an exited relay kept, recorded orphan stopped, probe removed'
}
$bodyFailed = $false
try {
  Assert-DisposableRoot
  if ($TeardownOnly -or -not ($DiscriminatorOnly -or $RulingFourOnly -or $RoleAdmissionOnly -or $PrecursorOnly -or $LegacyOnly -or $FixtureEquivalenceOnly)) { Test-DisposableTeardown }
  if ($TeardownOnly) { return }
  if ($RoleAdmissionOnly -or $RulingFourOnly -or -not ($DiscriminatorOnly -or $PrecursorOnly -or $LegacyOnly -or $FixtureEquivalenceOnly)) { Test-NativeRoleAdmission }
  if ($RoleAdmissionOnly) { return }
  if ($FixtureEquivalenceOnly -or -not ($DiscriminatorOnly -or $RulingFourOnly -or $PrecursorOnly -or $LegacyOnly)) { Test-ControllerFixtureEquivalence }
  if ($FixtureEquivalenceOnly) { return }
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
} catch {
  $bodyFailed = $true
  throw
} finally {
  # #206: recorded wrappers, published child identities and exact descendants
  # of either or of this test under the root are stopped before it is removed.
  $teardown = Complete-DisposableTeardown $root $testWrapperIdentities
  Write-TeardownReport $root $teardown
  # A teardown failure is reported on its own line and never replaces a body
  # failure; after a passing body it exits 3, distinct from an assertion's 1.
  if (-not $teardown.Removed -and -not $bodyFailed) { exit 3 }
}
