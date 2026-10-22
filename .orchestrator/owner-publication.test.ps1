[CmdletBinding()]
param(
  [ValidateSet('All', 'Primitive', 'Readers')][string]$Scenario = 'All',
  [string]$EvidencePath = ''
)
$ErrorActionPreference = 'Stop'
(Get-Process -Id $PID).PriorityClass = [Diagnostics.ProcessPriorityClass]::BelowNormal
$root = Split-Path -Parent $PSScriptRoot
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('owner-publication-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temporaryRoot)
$results = [Collections.Generic.List[object]]::new()
function Assert-Owner($Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}
function Read-Source([string]$Name) {
  return [IO.File]::ReadAllText((Join-Path $PSScriptRoot $Name))
}
function Test-PrecursorSafeFile([string]$Path) {
  try {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    return -not $item.PSIsContainer -and
      (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne [IO.FileAttributes]::ReparsePoint)
  } catch {
    return $false
  }
}
function Resolve-NodeExecutable {
  # Keep this identical to invoke-heavy-verifier.ps1's host-node rule: inspect
  # all application candidates, reject shims/reparse points, then select one.
  $resolved = @(Get-Command node -All -CommandType Application -ErrorAction SilentlyContinue | Where-Object {
    [IO.Path]::GetFileName($_.Source) -imatch '^node(?:\.exe)?$' -and (Test-PrecursorSafeFile $_.Source)
  }) | Select-Object -First 1 -ExpandProperty Source
  Assert-Owner ($resolved -is [string] -and -not [string]::IsNullOrWhiteSpace($resolved)) 'one safe Node executable resolves'
  return [IO.Path]::GetFullPath([string]$resolved)
}
function Get-PreRepairSource([string]$Source, [switch]$ReaderOnly) {
  if ($ReaderOnly) {
    # Build the local pre-repair reader only from this checkout.  Do not use a
    # historical commit: the installed variant differs solely at converted
    # reader share contracts, while the candidate remains the current source.
    $reverted = $Source
    $replacements = @(
      @('\[IO\.FileShare\]::ReadWrite\s*-bor\s*\[IO\.FileShare\]::Delete', '[IO.FileShare]::Read'),
      @('FileShare\.ReadWrite\s*\|\s*FileShare\.Delete', 'FileShare.Read')
    )
    $replaced = 0
    foreach ($replacement in $replacements) {
      $count = ([regex]::Matches($reverted, $replacement[0])).Count
      if ($count -gt 0) {
        $reverted = [regex]::Replace($reverted, $replacement[0], $replacement[1])
        $replaced += $count
      }
    }
    Assert-Owner ($replaced -gt 0) 'pre-repair reader share seam exists'
    return $reverted
  }
  # This is a local pre-repair control, not a historical checkout.  It models
  # only the two H3 seams that this file proves: Move publication and the
  # pre-repair sharing-violation throw.
  $replace = '[IO.File]::Replace($temporaryPath, $ownerPath, [NullString]::Value)'
  Assert-Owner (([regex]::Matches($Source, [regex]::Escape($replace))).Count -eq 1) 'pre-repair publication seam exists once'
  $reverted = $Source.Replace($replace, '[IO.File]::Move($temporaryPath, $ownerPath, $true)')
  $newline = if ($Source.Contains("`r`n")) { "`r`n" } else { "`n" }
  $claimPathPattern = '\$' + 'ClaimPath'
  $catchPattern = '(?ms)    try \{\r?\n      \$stream = \[IO\.File\]::Open\(' + $claimPathPattern + ', \[IO\.FileMode\]::Open, \[IO\.FileAccess\]::Read, \$share\)\r?\n    \} catch \[IO\.IOException\] \{\r?\n      if \(\(\$_.Exception\.GetBaseException\(\)\.HResult -band 0xffff\) -eq 32\) \{ return \$false \}\r?\n      throw\r?\n    \}\r?\n'
  Assert-Owner (([regex]::Matches($reverted, $catchPattern)).Count -eq 1) 'pre-repair claim opener seam exists once'
  $open = '    ' + ('$' + 'stream') + ' = [IO.File]::Open(' + ('$' + 'ClaimPath') + ', [IO.FileMode]::Open, [IO.FileAccess]::Read, ' + ('$' + 'share') + ')' + $newline
  return [regex]::Replace($reverted, $catchPattern, [Text.RegularExpressions.MatchEvaluator]{ param($match) $open })
}
function Get-Definition([string]$Source, [string]$Name) {
  $tokens = $null; $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseInput($Source, [ref]$tokens, [ref]$errors)
  Assert-Owner (-not $errors) "parse source for $Name"
  $definitions = @($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]}, $true) | Where-Object Name -CEQ $Name)
  Assert-Owner ($definitions.Count -eq 1) "one definition of $Name"
  return $definitions[0].Extent.Text
}
function Import-GuardFunctions([string]$Source) {
  foreach ($name in @('Test-SamePath','Test-SafeDirectory','Test-SafeFile','Get-OwnerSnapshot','Write-OwnerRecord','Restore-ClaimedOwner','Remove-ClaimedOwnerLock','Test-PositivePid','Test-UtcIdentity','Test-OwnerShape','Test-ReclaimableOwner','Get-ProcessIdentityState','Test-PossibleOwnedChild','Invoke-StaleLockReclamation','Test-ThisOwner','Release-ThisLock')) {
    . ([scriptblock]::Create((Get-Definition $Source $name)))
    Set-Item -Path "Function:script:$name" -Value (Get-Item "Function:$name").ScriptBlock
  }
}
function New-Lock {
  $script:lockPath = Join-Path $temporaryRoot ([guid]::NewGuid().ToString('N'))
  [void][IO.Directory]::CreateDirectory($lockPath)
  $script:ownerPath = Join-Path $lockPath 'owner.json'
}
function Read-Bytes([string]$Path) { return ,[IO.File]::ReadAllBytes($Path) }
function Get-Hex([byte[]]$Bytes) { return [Convert]::ToHexString($Bytes) }
function Get-SourceHash([string]$Source) {
  return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Source)))
}
function Assert-DistinctSources([string]$Installed, [string]$Candidate, [string]$Label) {
  $installedHash = Get-SourceHash $Installed
  $candidateHash = Get-SourceHash $Candidate
  Assert-Owner ($installedHash -cne $candidateHash) "$Label installed/candidate source hashes are distinct"
  [void]$results.Add([ordered]@{test='owner-reader-source-distinctness';site=$Label;installedHash=$installedHash;candidateHash=$candidateHash;distinct=$true})
  Write-Output "PASS $Label installed/candidate source hashes are distinct"
}
function Invoke-Primitive {
  $source = Read-Source 'invoke-heavy-verifier.ps1'
  $baseline = Get-PreRepairSource $source
  foreach ($variant in @('installed', 'candidate', 'move-mutant', 'share3-control')) {
    $copy = if ($variant -ceq 'installed') { $baseline } else { $source }
    if ($variant -ceq 'move-mutant') { $copy = $copy.Replace('[IO.File]::Replace($temporaryPath, $ownerPath, [NullString]::Value)', '[IO.File]::Move($temporaryPath, $ownerPath, $true)') }
    Import-GuardFunctions $copy
    foreach ($kind in @('ordinary-started','native-started','native-tuple')) {
      New-Lock
      $before = [ordered]@{schemaVersion=4;state='launching';lockId=('a'*32)}
      $after = [ordered]@{schemaVersion=4;state='started';lockId=('a'*32);childPid=123;childProcessStartUtc='2026-01-01T00:00:00Z'}
      if ($kind -like 'native-*') {
        $before.schemaVersion=6; $after.schemaVersion=6
        $before.native=@{linux=$null}; $after.native=@{linux=$null}
        if ($kind -ceq 'native-tuple') { $before.state='started'; $after.native.linux=@{bootId='12345678-1234-1234-1234-123456789abc';outerPid=42;startTicks='123';nspid=@(42,1);inode='456'} }
      }
      $raw = Write-OwnerRecord $before -CreateNew
      $share = if ($variant -ceq 'share3-control') { [IO.FileShare]::ReadWrite } else { [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete }
      $held = [IO.File]::Open($ownerPath, 'Open', 'Read', $share)
      $failure=$null; $published=$null
      try {
        try { $published=Write-OwnerRecord $after } catch { $failure=$_.Exception.Message }
        $actual=Get-Hex (Read-Bytes $ownerPath)
        $expectedRaw=if($after.schemaVersion-eq6){$after|ConvertTo-Json -Compress -Depth 16}else{$after|ConvertTo-Json -Compress}
        $ok=($null-eq$failure -and $published-ceq$expectedRaw -and $actual-ceq(Get-Hex ([Text.UTF8Encoding]::new($false).GetBytes($expectedRaw))))
        $entries=@(Get-ChildItem -LiteralPath $lockPath -Force | ForEach-Object Name)
        Assert-Owner ($entries.Count-eq1 -and $entries[0]-ceq'owner.json') 'publication leaves only owner.json'
        $results.Add([ordered]@{test='owner-replace-held-reader';variant=$variant;transition=$kind;green=$ok;error=$failure;entries=$entries;bytes=$actual})
        if($variant-ceq'candidate'){ Assert-Owner $ok "$kind candidate publishes with a held delete-sharing reader" }
        else { Assert-Owner (-not $ok) "$variant is RED for $kind" }
      } finally { $held.Dispose() }
    }
  }
  Import-GuardFunctions $source
  New-Lock
  [void](Write-OwnerRecord @{schemaVersion=4;state='launching'} -CreateNew)
  [IO.File]::Delete($ownerPath)
  $failed=$false
  try { [void](Write-OwnerRecord @{schemaVersion=4;state='started'}) } catch { $failed=$true }
  Assert-Owner ($failed -and -not(Test-Path $ownerPath) -and @(Get-ChildItem $lockPath -Force).Count-eq0) 'missing destination fails closed without fallback or leftover'
  $results.Add(@{test='owner-missing-destination';green=$true})

  foreach ($variant in @('installed','candidate')) {
    Import-GuardFunctions $(if($variant-ceq'installed'){$baseline}else{$source})
    foreach ($operation in @('release','reclaim')) {
      New-Lock
      $record=@{schemaVersion=4;state='started';lockId=('b'*32)}
      $raw=Write-OwnerRecord $record -CreateNew
      $before=Get-Hex (Read-Bytes $ownerPath)
      $held=[IO.File]::Open($ownerPath,'Open','Read',([IO.FileShare]::ReadWrite-bor[IO.FileShare]::Delete))
      $claim=Join-Path $lockPath ('owner.cleanup.'+[guid]::NewGuid().ToString('N')+'.json')
      [IO.File]::Move($ownerPath,$claim)
      $threw=$false; $removed=$null
      try { try { $removed=Remove-ClaimedOwnerLock $claim $raw } catch { $threw=$true }
        Assert-Owner ((Get-Hex (Read-Bytes $ownerPath))-ceq$before) 'claim failure restores exact owner bytes'
        $results.Add(@{test='owner-lifecycle-held-reader';variant=$variant;operation=$operation;threw=$threw;removed=$removed;entries=@(Get-ChildItem $lockPath -Force|ForEach-Object Name);bytes=$before})
        if($variant-ceq'candidate'){Assert-Owner (-not$threw -and $removed-eq$false) 'candidate sharing violation returns false'}
        else {Assert-Owner $threw 'installed claim primitive throws'}
      } finally {$held.Dispose()}
      [IO.File]::Move($ownerPath,$claim)
      Assert-Owner (Remove-ClaimedOwnerLock $claim $raw) 'later claimant removes exact record after reader closes'
      Assert-Owner (-not(Test-Path $lockPath)) 'later claim removes lock'
    }
  }
  Import-GuardFunctions $source
  $self=Get-Process -Id $PID
  $script:lockId=[guid]::NewGuid().ToString('N')
  $script:TestReplaceOwnerBeforeReclaim=$false
  foreach($operation in @('release','reclaim')) {
    New-Lock
    $script:owner=[ordered]@{schemaVersion=4;lockId=('a'*32);owner='fixture';lane='fixture';branch='codex/fixture';worktree=$temporaryRoot;head=('b'*40);identityMode='branch';pid=[int]::MaxValue;processStartUtc='2020-01-01T00:00:00Z';startedUtc=[datetime]::UtcNow.ToString('o');gate='test';commandIdentity=('c'*64);state='started';childPid=2147483646;childProcessStartUtc='2020-01-01T00:00:00Z'}
    if($operation-ceq'release'){$owner.pid=$PID;$owner.processStartUtc=$self.StartTime.ToUniversalTime().ToString('o')}
    $owner.childProcessStartUtc=$owner.startedUtc
    $script:ownedRaw=Write-OwnerRecord $owner -CreateNew
    $held=[IO.File]::Open($ownerPath,'Open','Read',7)
    try {
      $removed=if($operation-ceq'release'){Release-ThisLock}else{Invoke-StaleLockReclamation}
      Assert-Owner (-not$removed-and(Get-Hex (Read-Bytes $ownerPath))-ceq(Get-Hex ([Text.Encoding]::UTF8.GetBytes($ownedRaw)))) "$operation held reader fails closed with exact bytes"
      $results.Add(@{test='owner-lifecycle-held-reader';operation="actual $operation";removed=$removed;entries=@(Get-ChildItem $lockPath -Force|ForEach-Object Name);raw=$ownedRaw})
    } finally {$held.Dispose()}
    $removed=if($operation-ceq'release'){Release-ThisLock}else{Invoke-StaleLockReclamation}
    Assert-Owner ($removed-and-not(Test-Path $lockPath)) "$operation completes exactly after reader closes"
  }
  foreach($control in @('live','ambiguous','foreign')) {
    New-Lock
    $owner.pid=$PID;$owner.processStartUtc=$self.StartTime.ToUniversalTime().ToString('o')
    $script:ownedRaw=Write-OwnerRecord $owner -CreateNew
    if($control-ceq'ambiguous'){[IO.File]::WriteAllText($ownerPath,'{}')}
    if($control-ceq'foreign'){$script:ownedRaw='foreign raw'}
    $before=Get-Hex (Read-Bytes $ownerPath)
    $removed=if($control-ceq'foreign'){Release-ThisLock}else{Invoke-StaleLockReclamation}
    Assert-Owner (-not$removed-and(Get-Hex (Read-Bytes $ownerPath))-ceq$before) "$control refusal retains exact bytes"
    $results.Add(@{test='owner-lifecycle-held-reader';control=$control;removed=$removed;bytes=$before})
  }
  $open='$stream = [IO.File]::Open($ClaimPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)'
  Import-GuardFunctions ($source.Replace($open,"throw [IO.IOException]::new('injected non-sharing IO', 5)"))
  New-Lock
  $raw=Write-OwnerRecord @{schemaVersion=4} -CreateNew
  $claim=Join-Path $lockPath ('owner.cleanup.'+('a'*32)+'.json');[IO.File]::Move($ownerPath,$claim)
  $threw=$false
  try{Remove-ClaimedOwnerLock $claim $raw|Out-Null}catch{$threw=$_.Exception.GetBaseException().HResult-eq5}
  Assert-Owner ($threw-and(Test-Path $ownerPath)) 'non-sharing IO is not swallowed and still restores'
  $results.Add(@{test='owner-lifecycle-held-reader';control='non-sharing IO';threw=$threw;raw=$raw})
  Write-Output 'PASS owner-replace-held-reader; Move/share-3 controls RED; missing destination fails closed; owner-lifecycle-held-reader'
}
function Test-ReaderContract([hashtable]$Sources) {
  $failures = [Collections.Generic.List[string]]::new()
  foreach ($site in @(
    @('invoke-heavy-verifier.ps1','Get-OwnerSnapshot'),
    @('controller-release-battery.ps1','Get-BatteryFleetLoad'),
    @('controller-release-battery.ps1','Assert-BatteryAdmission'),
    @('landed-integration-evidence.psm1','Get-FleetLoadObservation'),
    @('host-heavy-verifier.test.ps1','Wait-NativeOwner')
  )) {
    $body=Get-Definition $Sources[$site[0]] $site[1]
    if ($body -match 'ReadAllText|ReadAllBytes|Get-Content' -or
        $body -notmatch 'FileShare\]::ReadWrite\s*-bor\s*\[IO.FileShare\]::Delete' -or
        ([regex]::Matches($body,'\[IO.File\]::Open\(')).Count -ne 1 -or
        $body -notmatch '\$stream\.Dispose\(\)') { $failures.Add(($site -join ':')) }
  }
  $cs=$Sources['heavy-nested-owner.cs']
  foreach($expression in @('ReadOwnerBytes(transition)','ReadOwnerBytes(Path.Combine(lockDirectory, "owner.json"))','raw = ReadOwnerBytes(ownerPath)')) {
    if (-not $cs.Contains($expression)) { $failures.Add("heavy-nested-owner.cs:$expression") }
  }
  if ($cs -notmatch 'FileShare.ReadWrite \| FileShare.Delete' -or
      $cs -notmatch 'using \(FileStream stream = new FileStream\(path, FileMode.Open, FileAccess.Read,' -or
      $cs -match 'File.ReadAllBytes\((transition|ownerPath|Path.Combine\(lockDirectory, "owner.json")') { $failures.Add('heavy-nested-owner.cs:ReadOwnerBytes') }
  foreach($name in @('liveOwnerMatchesToken','readNestedOwner')) {
    $start=$Sources['heavy-slot.cjs'].IndexOf("function $name(")
    $end=$Sources['heavy-slot.cjs'].IndexOf("`nfunction ",$start+1)
    $body=$Sources['heavy-slot.cjs'].Substring($start,$end-$start)
    if($body -notmatch 'fs.readFileSync\(ownerPath, "utf8"\)'){$failures.Add("heavy-slot.cjs:$name")}
  }
  return ,$failures
}
function Assert-ClassifiedOpeners([string[]]$Openers, [hashtable]$Classified) {
  $unknown=@($Openers | Where-Object {-not $Classified.ContainsKey($_)})
  Assert-Owner ($unknown.Count-eq0) "owner-reader-inventory unclassified openers: $($unknown -join ', ')"
}
function Invoke-ReaderInventory {
  $sources=@{}
  foreach($name in @('invoke-heavy-verifier.ps1','controller-release-battery.ps1','landed-integration-evidence.psm1','host-heavy-verifier.test.ps1','heavy-nested-owner.cs','heavy-slot.cjs')) { $sources[$name]=Read-Source $name }
  Assert-Owner ((Test-ReaderContract $sources).Count-eq0) 'owner-reader-inventory: every Bug-owned site delete-shares, closes and reopens'
  $table=[Collections.Generic.List[object]]::new()
  foreach($site in @(
    @('invoke-heavy-verifier.ps1','Get-OwnerSnapshot','ReadAllText + ReadAllBytes','1','BOM-aware UTF8; schema6 strict UTF8, no BOM, 16384 bytes','Test-ThisOwner; release; reclaim'),
    @('controller-release-battery.ps1','Get-BatteryFleetLoad','Get-Content -Raw','3','BOM-aware UTF8 / ConvertFrom-Json','battery item runner'),
    @('controller-release-battery.ps1','Assert-BatteryAdmission','ReadAllText','1','BOM-aware UTF8 / ConvertFrom-Json','battery admission poll'),
    @('landed-integration-evidence.psm1','Get-FleetLoadObservation','ReadAllText','1','BOM-aware UTF8 / ConvertFrom-RebaseJson','interrupted-integration-test-support.ps1:160,254,556,558'),
    @('host-heavy-verifier.test.ps1','Wait-NativeOwner','Get-Content -Raw','3','BOM-aware UTF8 / ConvertFrom-Json','native fixture wait')
  )) {
    $body=Get-Definition $sources[$site[0]] $site[1]
    $prefix=$sources[$site[0]].Substring(0,$sources[$site[0]].IndexOf($body,[StringComparison]::Ordinal))
    $line=1+[regex]::Matches($prefix,"`n").Count+[regex]::Matches($body.Substring(0,$body.IndexOf('[IO.File]::Open(')),"`n").Count
    $table.Add([ordered]@{site="$($site[0]):$line";api='File.Open / StreamReader (snapshot copies bytes once)';beforeApi=$site[2];shareBefore=$site[3];shareAfter=7;decoder=$site[4];callers=$site[5];owner='#9739'})
    $mutant=$sources.Clone()
    $sharePattern = '\[IO\.FileShare\]::ReadWrite\s*-bor\s*\[IO\.FileShare\]::Delete'
    $revertedBody = [regex]::Replace($body, $sharePattern, '[IO.FileShare]::Read')
    Assert-Owner ($revertedBody -cne $body) "revert $($site[1]) source seam exists"
    $mutant[$site[0]]=$mutant[$site[0]].Replace($body,$revertedBody)
    Assert-Owner ((Test-ReaderContract $mutant).Count-gt0) "revert $($site[1]) mutant is RED"
  }
  foreach($expression in @('ReadOwnerBytes(transition)','ReadOwnerBytes(Path.Combine(lockDirectory, "owner.json"))','raw = ReadOwnerBytes(ownerPath)')) {
    $line=1+[regex]::Matches($sources['heavy-nested-owner.cs'].Substring(0,$sources['heavy-nested-owner.cs'].IndexOf($expression)),"`n").Count
    $table.Add(@{site="heavy-nested-owner.cs:$line";api='ReadOwnerBytes / FileStream';beforeApi='File.ReadAllBytes';shareBefore=1;shareAfter=7;decoder='byte-exact comparison, then System.Text.Json';callers='CheckWriterEntries / CheckOwnerRecord';owner='#9739'})
    $mutant=$sources.Clone(); $mutant['heavy-nested-owner.cs']=$mutant['heavy-nested-owner.cs'].Replace($expression,$expression.Replace('ReadOwnerBytes','File.ReadAllBytes'))
    Assert-Owner ((Test-ReaderContract $mutant).Count-gt0) "revert C# $expression mutant is RED"
  }
  foreach($line in @(145,236)) {$table.Add(@{site="heavy-slot.cjs:$line";api='fs.readFileSync';shareBefore=7;shareAfter=7;decoder='UTF8 / JSON.parse or parseClosedJson';callers='liveOwnerMatchesToken / readNestedOwner';owner='#9739 (already delete-sharing libuv)'})}
  # Each fixture exception is a site, not a file exemption. These observations
  # inspect fixture-owned retained records; they do not define live publication.
  $fixtures=@{
    # 3212: the #99 sampler-transition-pause pre-fix Get-Content sampler (RED control).
    'controller-release-battery.test.ps1'=@(950,959,969,988,1593,1928,3226)
    'heavy-admission-preload.test.ps1'=@(82,582,611,980,986,1076,1133,1280,1326,1845,1849)
    'heavy-slot.test.ps1'=@(95,98,121,1722,2048,2225)
    # install-controller-skills.ps1 reads the installed release record, not heavy
    # owner state; the test-file sites compare fixture-retained owner bytes.
    'install-controller-skills.ps1'=@(145)
    'install-controller-skills.test.ps1'=@(208,225,230,319,340,354)
    # Complete current-site table for the combined head.  These are fixture
    # observations of retained owner bytes, not production publication.
    'invoke-heavy-verifier.test.ps1'=@(309,627,1104,1148,1160,1209,1213,1224,1249,1331,1768,1848,1858,1872,2166,2171,2190,2196,2423,2430,2442,2445,2455,2466,2488,2493,2505,2510,2527,2541)
    'invoke-fleet-exclusive-gate.test.ps1'=@(309,310)
    'landed-integration-dispatch.test.ps1'=@(540)
    'interrupted-integration-test-support.ps1'=@(898)
    'landed-integration-evidence-test-support.ps1'=@(219)
    'landed-integration-r3.test.ps1'=@(42)
    'lane-stall-watchdog.test.ps1'=@(505,551,554)
    'lease-contract.test.ps1'=@(87,88)
    'product-census-budget.test.ps1'=@(134,197,236)
  }
  foreach($name in $fixtures.Keys) {
    $lines=(Read-Source $name)-split "`n"
    foreach($line in $fixtures[$name]) {
      $table.Add(@{site="${name}:$line";api=$lines[$line-1].Trim();shareBefore='unchanged fixture API';shareAfter='unchanged';decoder='unchanged fixture decoder';callers='fixture-local assertion/observation';owner='fixture-only: synthetic lock or retained-byte assertion, not production publication'})
    }
  }
  foreach($line in @(462,469,560,562,593,691)) {
    $table.Add(@{site="host-heavy-verifier.test.ps1:$line";api=($sources['host-heavy-verifier.test.ps1']-split "`n")[$line-1].Trim();shareBefore='1/3/libuv';shareAfter='unchanged';decoder='unchanged';callers='interruption / teardown / embedded Node';owner='#9624, deliberately not converted'})
  }
  foreach($line in @(20,32,33,92,124,125,154,162,174,194,195,205,209,315,396,399,504,505,531,533)) {
    $table.Add(@{site="host-heavy-verifier.test.ps1:$line";api=($sources['host-heavy-verifier.test.ps1']-split "`n")[$line-1].Trim();shareBefore='Python read_text/read_bytes or pipe read';shareAfter='unchanged';decoder='unchanged Python decoder';callers='embedded native fixture setup / proc observation / pipe transport';owner='#9624; non-heavy-owner fixture/proc/transport reads, explicitly retained'})
  }
  $table.Add(@{site='controller-install-lock.psm1:226';api='File.Open / MemoryStream (snapshot copies bytes once)';shareBefore='new in #207';shareAfter=7;decoder='strict UTF8, no BOM / ConvertFrom-Json';callers='Get-ControllerInstallOwnerSnapshot / Invoke-ReclaimableControllerVerifyOwner';owner='#207 installer dead-owner reclaim (#210)'})
  $table.Add(@{site='controller-install-lock.psm1:247';api='File.Open / StreamReader (claim bytes read once)';shareBefore='new in #207';shareAfter=4;decoder='strict UTF8, no BOM / ConvertFrom-Json';callers='Remove-ClaimedOwnerLock (renamed claim, not live owner.json)';owner='#207 installer dead-owner reclaim (#210)'})
  $table.Add(@{site='fleet-exclusive-admission.psm1:92';api='File.ReadAllText(paths.record)';shareBefore=1;shareAfter=1;decoder='strict UTF8 / ConvertFrom-DispatchOwnershipJson';callers='Read-FleetAdmissionRecord';owner='separate fleet-admission.d protocol, not the heavy owner'})
  $table.Add(@{site='dispatch-ownership.ps1:518';api='File.ReadAllText(RecordPath)';shareBefore=1;shareAfter=1;decoder='UTF8 / ConvertFrom-DispatchOwnershipJson';callers='Get-ValidatedDispatchOwnershipRecord';owner='dispatch-launch record, never heavy owner.json'})
  # Discover owner/transition reads across tracked source languages, including
  # embedded Node/Python. Unknown sites are failures, never silently exempted.
  $classified=@{}; foreach($row in $table){$classified[$row.site]=$true}
  $unknown=[Collections.Generic.List[string]]::new()
  $readPattern='(?:ReadAll(?:Text|Bytes)|Get-Content|readFileSync|read_text|read_bytes|\[IO.File\]::Open|ReadOwnerBytes)'
  $pathPattern='(?:\$\w*owner\w*Path\b|\$RecordPath\b|\$ClaimPath\b|\bownerPath\b|owner\.json|transitionPath|ReadOwnerBytes\(transition|DERIVED_OWNER|E2E_OWNER|readFileSync\(lock,)'
  # A fixture exception must still name a discovered opener. A stale line would
  # otherwise exempt whatever opener later lands on it.
  $findStale={ param([hashtable]$Pins) @(foreach($name in $Pins.Keys){ $lines=(Read-Source $name)-split "`n"; foreach($line in $Pins[$name]){ if($line-gt$lines.Length -or -not($lines[$line-1]-match$readPattern-and$lines[$line-1]-match$pathPattern)){"${name}:$line"} } }) }
  $staleFixtures=@(& $findStale $fixtures)
  Assert-Owner ($staleFixtures.Count-eq0) "owner-reader-inventory stale fixture sites: $($staleFixtures -join ', ')"
  $stalePinMutant=$fixtures.Clone(); $stalePinMutant['install-controller-skills.ps1']=@(137,138)
  Assert-Owner ((@(& $findStale $stalePinMutant)) -ccontains 'install-controller-skills.ps1:137') 'stale fixture pin control is RED'
  $selfSource=Read-Source 'owner-publication.test.ps1'
  foreach($spec in @(@('Invoke-Primitive',4,'deliberately held positive/negative readers and injected claim opener'),@('Test-ReaderContract',3,'source-only regression expressions, not executed opens'),@('Invoke-ReaderInventory',3,'source-only inventory expressions, not executed opens'),@('Invoke-ReaderMatrix',1,'deliberately cached-handle negative control'))) {
    $body=Get-Definition $selfSource $spec[0]
    $base=1+[regex]::Matches($selfSource.Substring(0,$selfSource.IndexOf($body)),"`n").Count
    $siteMatches=@();$offset=0
    foreach($line in ($body-split"`n")) {
      if($line-match$readPattern-and$line-match$pathPattern){$siteMatches+=,@{site="owner-publication.test.ps1:$($base+$offset)";api=$line.Trim();shareBefore='fixture control';shareAfter='fixture control';decoder='fixture-local';callers=$spec[0];owner=$spec[2]}}
      $offset++
    }
    Assert-Owner ($siteMatches.Count-eq$spec[1]) "explicit self-inventory count $($spec[0])"
    foreach($row in $siteMatches){$table.Add($row);$classified[$row.site]=$true}
  }
  # These two production sites are writers or exclusive cleanup readers, not
  # observational owner readers. Keep their classification tied to the
  # production operation rather than treating them as generic exceptions.
  $invokeSource=Read-Source 'invoke-heavy-verifier.ps1'
  $ownerVariable='$' + 'ownerPath'
  $claimVariable='$' + 'ClaimPath'
  $writerExpression='[IO.File]::Open(' + $ownerVariable + ', [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)'
  $claimExpression='[IO.File]::Open(' + $claimVariable + ', [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)'
  $writerSite="invoke-heavy-verifier.ps1:$((1+[regex]::Matches($invokeSource.Substring(0,$invokeSource.IndexOf($writerExpression,[StringComparison]::Ordinal)),"`n").Count))"
  $claimSite="invoke-heavy-verifier.ps1:$((1+[regex]::Matches($invokeSource.Substring(0,$invokeSource.IndexOf($claimExpression,[StringComparison]::Ordinal)),"`n").Count))"
  $productionSites=@{
    $writerSite=@{site=$writerSite;api='File.Open($ownerPath, CreateNew, Write, None)';shareBefore=0;shareAfter=0;decoder='none';callers='Write-OwnerRecord -CreateNew';owner='writer, not a snapshot reader'}
    $claimSite=@{site=$claimSite;api='File.Open($ClaimPath, Open, Read, native/ordinary share)';shareBefore='Delete (native Read|Delete)';shareAfter='unchanged';decoder='unchanged';callers='Remove-ClaimedOwnerLock';owner='exclusive removal proof, not an observational reader'}
  }
  foreach($relative in @(& git -C $root ls-files '.orchestrator/*.ps1' '.orchestrator/*.psm1' '.orchestrator/*.cs' '.orchestrator/*.cjs' '.orchestrator/*.py' '.orchestrator/*.mjs' '.orchestrator/*.js')) {
    $name=[IO.Path]::GetFileName($relative); $lines=[IO.File]::ReadAllLines((Join-Path $root $relative))
    for($index=0;$index-lt$lines.Length;$index++) {
      $text=$lines[$index]
      if($text-match$readPattern -and $text-match$pathPattern) {
        $key="${name}:$($index+1)"
        if($key-ceq$writerSite) {
          $table.Add(@{site=$key;api='CreateNew / Write';shareBefore=0;shareAfter=0;decoder='none';callers='initial acquisition';owner='writer, not a snapshot reader'}); continue
        }
        if($key-ceq$claimSite) {
          $table.Add(@{site=$key;api='claim File.Open';shareBefore='Delete (native Read|Delete)';shareAfter='unchanged';decoder='unchanged';callers='Remove-ClaimedOwnerLock';owner='exclusive removal proof, not an observational reader'}); continue
        }
        if($productionSites.ContainsKey($key)) { $table.Add($productionSites[$key]); continue }
        if(-not$classified.ContainsKey($key)){$unknown.Add($key)}
      }
    }
  }
  Assert-ClassifiedOpeners $unknown $classified
  $refused=$false
  try { Assert-ClassifiedOpeners @('unknown-reader.ps1:1') $classified } catch {$refused=$_.Exception.Message.Contains('unclassified openers')}
  Assert-Owner $refused 'unclassified opener control is RED through the inventory checker'
  $results.Add(@{test='owner-reader-inventory';sites=$table;revertMutantsKilled=8;unclassifiedControl='RED'})
  Write-Output "PASS owner-reader-inventory: $($table.Count) classified sites; all converted-site revert mutants RED"
}
function Invoke-ReaderMatrix {
  $candidate=Read-Source 'invoke-heavy-verifier.ps1'
  $installed=Get-PreRepairSource $candidate -ReaderOnly
  Assert-DistinctSources $installed $candidate 'invoke-heavy-verifier.ps1'
  $sourcesByVariant=@{installed=$installed;candidate=$candidate}
  $readerSites=@(
    @('controller-release-battery.ps1','Get-BatteryFleetLoad'),
    @('controller-release-battery.ps1','Assert-BatteryAdmission'),
    @('landed-integration-evidence.psm1','Get-FleetLoadObservation'),
    @('host-heavy-verifier.test.ps1','Wait-NativeOwner')
  )
  $siteSources=@{}
  foreach($site in $readerSites) {
    $candidateSite=Read-Source $site[0]
    $installedSite=Get-PreRepairSource $candidateSite -ReaderOnly
    Assert-DistinctSources $installedSite $candidateSite "$($site[0])/$($site[1])"
    $siteSources["$($site[0])/$($site[1])"]=@{installed=$installedSite;candidate=$candidateSite}
  }
  $script:decodeEntries=[Collections.Generic.List[object]]::new()
  $now='2026-01-01T00:00:00.0000000Z'
  $script:validOwner=[ordered]@{schemaVersion=4;lockId=('a'*32);owner='fixture';lane='fixture';branch='codex/fixture';worktree=$temporaryRoot;head=('b'*40);identityMode='branch';pid=123;processStartUtc=$now;startedUtc=$now;gate='test';commandIdentity=('c'*64);state='started';childPid=124;childProcessStartUtc=$now}
  $cases=[ordered]@{
    valid=[Text.Encoding]::UTF8.GetBytes(($validOwner|ConvertTo-Json -Compress))
    ordinary=[Text.Encoding]::UTF8.GetBytes('{"schemaVersion":4,"state":"started","value":"A"}')
    native=[Text.Encoding]::UTF8.GetBytes('{"schemaVersion":6,"state":"started","native":{"linux":null}}')
    bom=([byte[]]@(239,187,191)+[Text.Encoding]::UTF8.GetBytes('{"schemaVersion":6}'))
    invalidUtf8=([Text.Encoding]::UTF8.GetBytes('{"schemaVersion":6,"value":"')+[byte[]]@(255)+[Text.Encoding]::UTF8.GetBytes('"}'))
    oversized=[Text.Encoding]::UTF8.GetBytes(('{"schemaVersion":6,"value":"'+('x'*16400)+'"}'))
    malformed=[Text.Encoding]::UTF8.GetBytes('{')
    wrongSchema=[Text.Encoding]::UTF8.GetBytes('{"schemaVersion":99}')
    wrongTuple=[Text.Encoding]::UTF8.GetBytes('{"schemaVersion":6,"native":{"linux":{"outerPid":0}}}')
    extraEntry=[Text.Encoding]::UTF8.GetBytes('{"schemaVersion":4}')
    reparse=[Text.Encoding]::UTF8.GetBytes('{"schemaVersion":4}')
  }
  foreach($case in $cases.Keys) {
    New-Lock
    [IO.File]::WriteAllBytes($ownerPath,$cases[$case])
    if($case-ceq'extraEntry'){[IO.File]::WriteAllText((Join-Path $lockPath 'unexpected'),'x')}
    if($case-ceq'reparse'){
      $target=Join-Path $temporaryRoot ([guid]::NewGuid().ToString('N'))
      [IO.File]::Move($ownerPath,$target)
      [void](New-Item -ItemType SymbolicLink -Path $ownerPath -Target $target)
    }
    $decodeEntries.Add(@{case=$case;path=$ownerPath;directory=$lockPath;bytes=[Convert]::ToBase64String($cases[$case])})
    $observations=@()
    foreach($source in @($installed,$candidate)) {
      Import-GuardFunctions $source
      . ([scriptblock]::Create((Get-Definition $source 'Read-NativeJson')))
      $snapshot=Get-OwnerSnapshot
      $observations+=,(ConvertTo-Json -InputObject $snapshot -Depth 16 -Compress)
    }
    Assert-Owner ($observations[0]-ceq$observations[1]) "owner-reader-decode-matrix $case byte-identical result"
    $results.Add(@{test='owner-reader-decode-matrix';site='Get-OwnerSnapshot';case=$case;installed=$observations[0];candidate=$observations[1]})
    foreach($site in $readerSites) {
      $observations=@()
      $sourcesByVariant=$siteSources["$($site[0])/$($site[1])"]
      foreach($variant in @('installed','candidate')) {
        $source=$sourcesByVariant[$variant]
        $body=Get-Definition $source $site[1]
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseInput($body,[ref]$tokens,[ref]$errors)
        # Exercise the unchanged per-site read/decoder, without entering the
        # caller's wait loop or changing its deadline. Policy remains below it.
        $assignment=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text-ceq'$owner'},$true))
        if($site[1]-ceq'Wait-NativeOwner') {
          $assignment=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text-ceq'$record'},$true))
        }
        Assert-Owner ($assignment.Count-ge1) "decoder assignment $($site[1])"
        $start=$body.IndexOf('$stream', [StringComparison]::Ordinal)
        $end=$assignment[0].Extent.EndOffset
        $decode=$body.Substring($start,$end-$start)
        $path=$ownerPath
        . ([scriptblock]::Create((Get-Definition (Read-Source 'landed-integration-evidence.psm1') 'ConvertFrom-RebaseJson')))
        try {
          $owner=$null;$record=$null
          . ([scriptblock]::Create($decode))
          $value=if($site[1]-ceq'Wait-NativeOwner'){$record}else{$owner}
          $observations+=,(ConvertTo-Json -InputObject $value -Compress -Depth 16)
        } catch {$observations+=,'DECODE_REFUSED'}
      }
      Assert-Owner ($observations[0]-ceq$observations[1]) "owner-reader-decode-matrix $($site[1]) $case identical result"
      $results.Add(@{test='owner-reader-decode-matrix';site=$site[1];case=$case;installed=$observations[0];candidate=$observations[1]})
    }
  }
  Import-GuardFunctions $candidate
  New-Lock
  $a=@{schemaVersion=4;value='A'}; $b=@{schemaVersion=4;value='B'}
  [void](Write-OwnerRecord $a -CreateNew)
  $first=Get-OwnerSnapshot
  $cached=[IO.File]::Open($ownerPath,'Open','Read',7)
  try {
    [void](Write-OwnerRecord $b)
    $second=Get-OwnerSnapshot
    $reader=[IO.StreamReader]::new($cached,[Text.Encoding]::UTF8,$true,1024,$true)
    try{$stale=$reader.ReadToEnd()|ConvertFrom-Json}finally{$reader.Dispose()}
    Assert-Owner ($first.Record.value-ceq'A'-and$second.Record.value-ceq'B'-and$stale.value-ceq'A') 'owner-snapshot-sees-replacement: A, replace, B; kept-handle mutant is RED'
  } finally {$cached.Dispose()}
  $results.Add(@{test='owner-snapshot-sees-replacement';first=$first;second=$second;keptHandleMutant=$stale;mutant='KILLED'})
  Write-Output 'PASS owner-reader-decode-matrix; owner-snapshot-sees-replacement; kept-handle mutant RED'
}
function Invoke-ManagedReaderMatrix {
  $candidateSource=Read-Source 'heavy-nested-owner.cs'
  $installedSource=Get-PreRepairSource $candidateSource -ReaderOnly
  Assert-DistinctSources $installedSource $candidateSource 'heavy-nested-owner.cs'
  $types=@()
  foreach($variant in @('installed','candidate')) {
    $suffix=if($variant-ceq'installed'){'Installed9739'}else{'Candidate9739'}
    $variantSource=if($variant-ceq'installed'){$installedSource}else{$candidateSource}
    $source=$variantSource.Replace('namespace ChaseSets.HeavyAdmission',"namespace ChaseSets.$suffix")
    Add-Type -TypeDefinition $source
    $types+=,@{server=("ChaseSets.$suffix.NestedOwnerServer"-as[type]);binding=("ChaseSets.$suffix.NestedOwnerBinding"-as[type])}
  }
  foreach($entry in $decodeEntries) {
    $observations=@()
    foreach($typeset in $types) {
      $server=[Runtime.CompilerServices.RuntimeHelpers]::GetUninitializedObject($typeset.server)
      $typeset.server.GetField('_ownerRawBytes',[Reflection.BindingFlags]'Instance,NonPublic').SetValue($server,[Convert]::FromBase64String($entry.bytes))
      $binding=[Activator]::CreateInstance($typeset.binding)
      $binding.LockDirectory=$entry.directory
      foreach($pair in @(@('LockId','lockId'),@('OwnerIdentity','owner'),@('Gate','gate'),@('State','state'),@('CommandIdentity','commandIdentity'),@('WrapperPid','pid'),@('WrapperStartUtc','processStartUtc'),@('RootPid','childPid'),@('RootStartUtc','childProcessStartUtc'),@('Lane','lane'),@('Worktree','worktree'),@('Branch','branch'),@('Head','head'),@('IdentityMode','identityMode'))) {$binding.($pair[0])=$validOwner.($pair[1])}
      $record=$typeset.server.GetMethod('CheckOwnerRecord',[Reflection.BindingFlags]'Instance,NonPublic').Invoke($server,[object[]]@($binding.PSObject.BaseObject))
      $writer=$typeset.server.GetMethod('CheckWriterEntries',[Reflection.BindingFlags]'Static,NonPublic').Invoke($null,[object[]]@([string]$entry.directory))
      $observations+=,(@{record=$record;writer=$writer}|ConvertTo-Json -Compress)
    }
    Assert-Owner ($observations[0]-ceq$observations[1]) "C# record/writer decode parity $($entry.case)"
    $results.Add(@{test='owner-reader-decode-matrix';site='CheckOwnerRecord / CheckWriterEntries';case=$entry.case;installed=$observations[0];candidate=$observations[1]})
  }
  # Also exercise both transition opens, not just the owner-only branch.
  $valid=@($decodeEntries|Where-Object case -CEQ 'valid')[0]
  $transition=Join-Path $valid.directory ('owner.transition.'+('d'*32)+'.tmp')
  foreach($conflict in @($false,$true)) {
    [IO.File]::WriteAllBytes($transition,[Convert]::FromBase64String($valid.bytes))
    if($conflict){[IO.File]::WriteAllText($transition,'{}')}
    $values=@($types|ForEach-Object {$_.server.GetMethod('CheckWriterEntries',[Reflection.BindingFlags]'Static,NonPublic').Invoke($null,[object[]]@([string]$valid.directory))})
    Assert-Owner ($values[0]-ceq$values[1]) 'transition-byte comparison unchanged'
    Assert-Owner (($null-ne$values[1])-eq$conflict) 'matching transition admitted; conflicting transition refused'
    $results.Add(@{test='owner-reader-decode-matrix';site='CheckWriterEntries both opens';case="transition-conflict=$conflict";installed=$values[0];candidate=$values[1]})
  }
  [IO.File]::Delete($transition)
  Write-Output 'PASS owner-reader-decode-matrix: C# owner and both transition readers'
}
function Invoke-NodeReaderMatrix {
  $inputPath=Join-Path $temporaryRoot 'node-input.json'
  $sourcePath=Join-Path $PSScriptRoot 'heavy-slot.cjs'
  [IO.File]::WriteAllText($inputPath,(@{source=$sourcePath;entries=@($decodeEntries);root=$temporaryRoot}|ConvertTo-Json -Depth 16))
  $scriptPath=Join-Path $temporaryRoot 'node-readers.cjs'
  [IO.File]::WriteAllText($scriptPath,@'
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const input = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const source = fs.readFileSync(input.source, 'utf8');
const stubRequire = (name) => name === 'node:child_process' ? { spawnSync: () => ({ status: 0 }) } : require(name);
const readers = new Function('require', 'module', '__dirname', source + '\nreturn { liveOwnerMatchesToken, readNestedOwner };')(stubRequire, { exports: {} }, path.dirname(input.source));
const output = [];
for (const entry of input.entries) {
  const container = path.join(input.root, 'node-' + entry.case);
  const lock = path.join(container, '.orchestrator', 'verify-lock.d');
  fs.mkdirSync(lock, { recursive: true });
  const owner = path.join(lock, 'owner.json');
  fs.writeFileSync(owner, Buffer.from(entry.bytes, 'base64'));
  if (entry.case === 'extraEntry') fs.writeFileSync(path.join(lock, 'unexpected'), 'x');
  if (entry.case === 'reparse') { fs.unlinkSync(owner); fs.symlinkSync(entry.path, owner); }
  const token = 'a'.repeat(32);
  const nested = readers.readNestedOwner(container, token);
  const live = readers.liveOwnerMatchesToken(container, token, 'fixture-pwsh');
  if (entry.case === 'valid') assert(nested.owner && live);
  output.push({ case: entry.case, nested, live });
  fs.unlinkSync(owner);
  assert(!readers.liveOwnerMatchesToken(container, token, 'fixture-pwsh'));
  assert(readers.readNestedOwner(container, token).failure);
}
process.stdout.write(JSON.stringify(output));
'@)
  $nodeOutput=& node $scriptPath $inputPath
  Assert-Owner ($LASTEXITCODE-eq0) 'Node owner reader decode and reopen matrix'
  $results.Add(@{test='owner-reader-decode-matrix';site='Node liveOwnerMatchesToken / readNestedOwner (unchanged)';rows=($nodeOutput|ConvertFrom-Json -Depth 20)})
  # libuv's Windows open uses share 7. Hold its actual descriptor across Replace.
  $nodeHold=Join-Path $temporaryRoot 'node-hold.cjs'
  [IO.File]::WriteAllText($nodeHold,@'
const fs = require('node:fs');
const fd = fs.openSync(process.argv[2], 'r');
fs.writeFileSync(process.argv[3], 'ready');
const cell = new Int32Array(new SharedArrayBuffer(4));
const until = Date.now() + 30000;
while (!fs.existsSync(process.argv[4]) && Date.now() < until) Atomics.wait(cell, 0, 0, 10);
fs.closeSync(fd);
'@)
  New-Lock
  [IO.File]::WriteAllText($ownerPath,'A')
  $ready=Join-Path $temporaryRoot 'node-ready';$release=Join-Path $temporaryRoot 'node-release'
  $start=[Diagnostics.ProcessStartInfo]::new((Resolve-NodeExecutable))
  $start.UseShellExecute=$false;$start.CreateNoWindow=$true
  foreach($argument in @($nodeHold,$ownerPath,$ready,$release)){$start.ArgumentList.Add($argument)}
  $child=[Diagnostics.Process]::Start($start)
  try {
    $until=[datetime]::UtcNow.AddSeconds(30)
    while(-not(Test-Path $ready)-and[datetime]::UtcNow-lt$until-and-not$child.HasExited){Start-Sleep -Milliseconds 10}
    Assert-Owner (Test-Path $ready) 'actual libuv descriptor opened'
    $next=Join-Path $lockPath 'next';[IO.File]::WriteAllText($next,'B')
    [IO.File]::Replace($next,$ownerPath,[NullString]::Value)
    $results.Add(@{test='owner-reader-inventory';site='Node fs.openSync libuv Windows';share='ReadWrite|Delete (actual held descriptor survives Replace)';green=$true})
  } finally {
    [IO.File]::WriteAllText($release,'release')
    if(-not$child.WaitForExit(30000)){$child.Kill();$child.WaitForExit();throw 'Node fixture did not release'}
  }
  Assert-Owner ($child.ExitCode-eq0) 'Node held reader exits'
  Write-Output 'PASS Node owner reader matrix; actual libuv held descriptor is delete-sharing'
}
try {
  if ($Scenario -in @('All','Primitive')) { Invoke-Primitive }
  if ($Scenario -in @('All','Readers')) { Invoke-ReaderInventory; Invoke-ReaderMatrix; Invoke-ManagedReaderMatrix; Invoke-NodeReaderMatrix }
} finally {
  if ($EvidencePath) { [IO.File]::WriteAllText($EvidencePath,($results|ConvertTo-Json -Depth 18),[Text.UTF8Encoding]::new($false)) }
  $resolved=[IO.Path]::GetFullPath($temporaryRoot)
  Assert-Owner ($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)) 'owned cleanup stays in temp'
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
