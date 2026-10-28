[CmdletBinding()]
param(
  [ValidateSet('All', 'Primitive', 'Readers', 'Continuous')][string]$Scenario = 'All',
  [string]$EvidencePath = '',
  [switch]$Stress
)
$ErrorActionPreference = 'Stop'
(Get-Process -Id $PID).PriorityClass = [Diagnostics.ProcessPriorityClass]::BelowNormal
$root = Split-Path -Parent $PSScriptRoot
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('owner-publication-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temporaryRoot)
$results = [Collections.Generic.List[object]]::new()
$definitionCache = @{}
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
  $replace = '[ChaseSets.HeavyAdmission.OwnerRename]::Publish($temporaryPath, $ownerPath, $destination)'
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
  if (-not $definitionCache.ContainsKey($Source)) {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($Source, [ref]$tokens, [ref]$errors)
    Assert-Owner (-not $errors) "parse source for $Name"
    $definitionCache[$Source] = @($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]}, $true))
  }
  $definitions = @($definitionCache[$Source] | Where-Object Name -CEQ $Name)
  Assert-Owner ($definitions.Count -eq 1) "one definition of $Name"
  return $definitions[0].Extent.Text
}
function Import-GuardFunctions([string]$Source) {
  $errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseInput($Source,[ref]$null,[ref]$errors)
  Assert-Owner (-not $errors) 'parse guard functions'
  $definitions=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true))
  foreach ($name in @('Test-SamePath','Test-SafeDirectory','Test-SafeFile','Get-OwnerSnapshot','Write-OwnerRecord','Restore-ClaimedOwner','Remove-ClaimedOwnerLock','Test-PositivePid','Test-UtcIdentity','Test-OwnerShape','Test-ReclaimableOwner','Get-ProcessIdentityState','Test-PossibleOwnedChild','Invoke-StaleLockReclamation','Test-ThisOwner','Release-ThisLock')) {
    $definition=@($definitions | Where-Object Name -CEQ $name)
    Assert-Owner ($definition.Count -eq 1) "one definition of $name"
    . ([scriptblock]::Create($definition[0].Extent.Text))
    Set-Item -Path "Function:script:$name" -Value (Get-Item "Function:$name").ScriptBlock
  }
  if ($Source.Contains('function Initialize-OwnerRename')) {
    $definition=@($definitions | Where-Object Name -CEQ 'Initialize-OwnerRename')
    Assert-Owner ($definition.Count -eq 1) 'one definition of Initialize-OwnerRename'
    . ([scriptblock]::Create($definition[0].Extent.Text))
    Initialize-OwnerRename
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
  $rename = '[ChaseSets.HeavyAdmission.OwnerRename]::Publish($temporaryPath, $ownerPath, $destination)'
  foreach ($variant in @('installed', 'candidate', 'move-mutant', 'replace-mutant', 'share3-control')) {
    $copy = if ($variant -ceq 'installed') { $baseline } else { $source }
    if ($variant -ceq 'move-mutant') { $copy = $copy.Replace($rename, '[IO.File]::Move($temporaryPath, $ownerPath, $true)') }
    if ($variant -ceq 'replace-mutant') { $copy = $copy.Replace($rename, '[IO.File]::Replace($temporaryPath, $ownerPath, [NullString]::Value)') }
    if ($variant -cne 'candidate' -and $variant -cne 'share3-control') { Assert-DistinctSources $copy $source "owner-replace-held-reader/$variant" }
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
        if($variant-in@('candidate','replace-mutant')){ Assert-Owner $ok "$kind $variant publishes with a held delete-sharing reader" }
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
function Invoke-ContinuousPublication {
  $source = Read-Source 'invoke-heavy-verifier.ps1'
  $rename = '[ChaseSets.HeavyAdmission.OwnerRename]::Publish($temporaryPath, $ownerPath, $destination)'
  $variants = [ordered]@{candidate=$source}
  if ($source.Contains($rename)) {
    $variants['replace-mutant'] = $source.Replace($rename, '[IO.File]::Replace($temporaryPath, $ownerPath, [NullString]::Value)')
    $variants['move-mutant'] = $source.Replace($rename, '[IO.File]::Move($temporaryPath, $ownerPath, $true)')
  }
  $poller = Join-Path $temporaryRoot 'continuous.cjs'
  [IO.File]::WriteAllText($poller, @'
const fs = require('node:fs');
const path = require('node:path');
const [owner, ready, stop, result, sourcePath] = process.argv.slice(2);
const source = fs.readFileSync(sourcePath, 'utf8');
const { readOwnerText } = new Function('require', 'module', '__dirname', source + '\nreturn { readOwnerText };')(require, { exports: {} }, path.dirname(sourcePath));
let absent = 0, failures = 0, polls = 0, maxEntries = 0; const errors = [];
fs.writeFileSync(ready, 'ready');
while (!fs.existsSync(stop)) {
  try {
    fs.lstatSync(owner);
    JSON.parse(readOwnerText(owner));
    const entries = fs.readdirSync(path.dirname(owner));
    maxEntries = Math.max(maxEntries, entries.length);
    if (entries.some(n => n !== 'owner.json' && !/^owner\.transition\.[a-f0-9]{32}\.tmp$/.test(n))) failures++;
  } catch (e) {
    if (e.code === 'ENOENT') absent++; else failures++;
    if (errors.length < 20) errors.push({code:e.code, errno:e.errno, syscall:e.syscall, message:e.message});
  }
  polls++;
}
fs.writeFileSync(result, JSON.stringify({absent, failures, polls, maxEntries, errors}));
'@)
  $managedPoller = Join-Path $temporaryRoot 'continuous.ps1'
  [IO.File]::WriteAllText($managedPoller, @'
param($Owner, $Ready, $Stop, $Result, $OpenSource)
$absent=0; $failures=0; $polls=0; $errors=[Collections.Generic.List[object]]::new()
$RecordPath=$Owner
$openOwner=[scriptblock]::Create([IO.File]::ReadAllText($OpenSource))
[IO.File]::WriteAllText($Ready,'ready')
while (-not [IO.File]::Exists($Stop)) {
  try {
    . $openOwner
    try { $reader=[IO.StreamReader]::new($stream); try { $null=$reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() } } finally { $stream.Dispose() }
  } catch {
    $exception=$_.Exception.GetBaseException()
    if($errors.Count-lt20){$errors.Add(@{type=$exception.GetType().FullName;code=($exception.HResult-band 0xffff);hresult=$exception.HResult;message=$exception.Message;attempts=$openAttempt;elapsedMs=$openDeadline.Elapsed.TotalMilliseconds})}
    if (-not [IO.File]::Exists($Owner)) { $absent++ } else { $failures++ }
  }
  $polls++
}
[IO.File]::WriteAllText($Result,(@{absent=$absent;failures=$failures;polls=$polls;errors=@($errors)}|ConvertTo-Json -Compress -Depth 6))
'@)
  $snapshot=Get-Definition $source 'Get-OwnerSnapshot'
  $openStart=$snapshot.IndexOf('$openDeadline =')
  $openEnd=$snapshot.IndexOf('$buffer =', $openStart)
  Assert-Owner ($openStart-ge0 -and $openEnd-gt$openStart) 'continuous reader executes the production Get-OwnerSnapshot opener'
  $openSource=Join-Path $temporaryRoot 'open-owner.ps1'
  [IO.File]::WriteAllText($openSource,$snapshot.Substring($openStart,$openEnd-$openStart))
  foreach ($variant in $variants.Keys) {
    $copy = $variants[$variant]
    if ($variant -cne 'candidate') { Assert-DistinctSources $copy $source "owner-rename-continuous/$variant" }
    Import-GuardFunctions $copy
    foreach ($kind in @('ordinary-started','native-started','native-tuple')) {
      New-Lock
      $before = @{schemaVersion=4;state='launching';childPid=$null;native=@{linux=$null}}
      $after = @{schemaVersion=4;state='started';childPid=123;native=@{linux=$null}}
      if ($kind -like 'native-*') { $before.schemaVersion=6; $after.schemaVersion=6 }
      if ($kind -ceq 'native-tuple') { $before.state='started'; $after.native.linux=@{bootId='12345678-1234-1234-1234-123456789abc';outerPid=42;startTicks='123';nspid=@(42,1);inode='456'} }
      [void](Write-OwnerRecord $before -CreateNew)
      $processes = @(); $signals = @()
      foreach ($readerKind in @('node','powershell')) {
        $prefix = Join-Path $temporaryRoot ([guid]::NewGuid().ToString('N'))
        $signals += @{ready="$prefix.ready";stop="$prefix.stop";result="$prefix.json"}
        $signal = $signals[-1]
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = if ($readerKind -ceq 'node') { Resolve-NodeExecutable } else { (Get-Process -Id $PID).Path }
        $start.UseShellExecute=$false; $start.CreateNoWindow=$true
        $arguments = if ($readerKind -ceq 'node') { @($poller) } else { @('-NoProfile','-File',$managedPoller) }
        foreach ($argument in @($arguments) + @($ownerPath,$signal.ready,$signal.stop,$signal.result)) { $start.ArgumentList.Add($argument) }
        $start.ArgumentList.Add($(if($readerKind-ceq'node'){Join-Path $PSScriptRoot 'heavy-slot.cjs'}else{$openSource}))
        $processes += [Diagnostics.Process]::Start($start)
      }
      $writerFailures=0; $writerErrors=@()
      try {
        $deadline=[datetime]::UtcNow.AddSeconds(30)
        while (@($signals | Where-Object {-not [IO.File]::Exists($_.ready)}).Count -gt 0 -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 10 }
        Assert-Owner (@($signals | Where-Object {-not [IO.File]::Exists($_.ready)}).Count -eq 0) 'continuous readers ready'
        $held=[IO.File]::Open($ownerPath,'Open','Read',([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try {
          for ($iteration=0; $iteration -lt 4000; $iteration++) {
            try { [void](Write-OwnerRecord $(if ($iteration % 2) { $before } else { $after })) } catch { $writerFailures++; if ($writerErrors.Count -lt 3) { $writerErrors += $_.Exception.ToString() } }
          }
        } finally { $held.Dispose() }
      } finally {
        foreach ($signal in $signals) { [IO.File]::WriteAllText($signal.stop,'stop') }
        foreach ($process in $processes) { if (-not $process.WaitForExit(30000)) { $process.Kill(); $process.WaitForExit(); throw 'continuous reader did not stop' }; Assert-Owner ($process.ExitCode -eq 0) 'continuous reader exits' }
      }
      $observations=@($signals | ForEach-Object { [IO.File]::ReadAllText($_.result) | ConvertFrom-Json })
      $absent=($observations | Measure-Object absent -Sum).Sum
      $failures=$writerFailures + ($observations | Measure-Object failures -Sum).Sum
      $maxEntries=$observations[0].maxEntries
      $green=($absent -eq 0 -and $failures -eq 0 -and $maxEntries -le 2 -and $observations[0].polls -gt 0 -and $observations[1].polls -gt 0)
      $row=@{test='owner-rename-continuous';variant=$variant;transition=$kind;replacements=4000;absent=$absent;failures=$failures;writerFailures=$writerFailures;writerErrors=$writerErrors;readers=$observations;maxEntries=$maxEntries;hash=(Get-SourceHash $copy);green=$green}
      $results.Add($row)
      Write-Output "CONTROL owner-rename-continuous variant=$variant transition=$kind replacements=4000 absent=$absent failures=$failures writerFailures=$writerFailures maxEntries=$maxEntries green=$green hash=$($row.hash)"
      if (-not $green -and $variant -ceq 'candidate') { Write-Output ($row | ConvertTo-Json -Compress -Depth 8) }
      if ($variant -ceq 'candidate') { if (-not $green) { $candidateFailed=$true } }
      elseif ($variant -ceq 'replace-mutant') { Assert-Owner ($absent -gt 0) 'replace-mutant is RED on absence' }
      else { Assert-Owner ($writerFailures -gt 0) 'move-mutant is RED on failures' }
    }
  }
  Assert-Owner (-not $candidateFailed) 'owner-rename-continuous candidate is GREEN for every transition'
}
function Invoke-VanishedPublication {
  $source=Read-Source 'invoke-heavy-verifier.ps1'
  $anchor='[ChaseSets.HeavyAdmission.OwnerRename]::Publish($temporaryPath, $ownerPath, $destination)'
  Assert-Owner ($source.Contains($anchor)) 'vanished publication seam exists'
  foreach ($variant in @('candidate','no-link-check')) {
    $copy=$source
    if ($variant -ceq 'no-link-check') {
      $check='!inspected || replaced.NumberOfLinks != 0'
      Assert-Owner ($copy.Contains($check)) 'link-check mutant seam exists'
      $copy=$copy.Replace($check,'!inspected')
      Assert-DistinctSources $copy $source 'owner-rename-vanished/no-link-check'
    }
    # Separate compiled namespaces keep the bypass and candidate independent.
    $copy=$copy.Replace('ChaseSets.HeavyAdmission',"ChaseSets.Vanished$($variant.Replace('-',''))")
    $call=$anchor.Replace('ChaseSets.HeavyAdmission',"ChaseSets.Vanished$($variant.Replace('-',''))")
    $copy=$copy.Replace($call,('[IO.File]::Move($ownerPath, $script:vanishedClaim); ' + $call))
    Import-GuardFunctions $copy
    New-Lock
    $script:vanishedClaim=Join-Path $lockPath ('owner.cleanup.'+('e'*32)+'.json')
    $raw=Write-OwnerRecord @{schemaVersion=4;state='launching'} -CreateNew
    $threw=$false
    try { [void](Write-OwnerRecord @{schemaVersion=4;state='started'}) } catch { $threw=$true }
    $entries=@(Get-ChildItem $lockPath -Force | ForEach-Object Name)
    $bytesUnchanged=([Text.Encoding]::UTF8.GetString((Read-Bytes $vanishedClaim)) -ceq $raw)
    $green=($threw -and $entries.Count -eq 1 -and $entries[0] -ceq (Split-Path -Leaf $vanishedClaim) -and $bytesUnchanged)
    $results.Add(@{test='owner-rename-vanished';variant=$variant;green=$green;threw=$threw;entries=$entries;claimBytesUnchanged=$bytesUnchanged})
    Write-Output "CONTROL owner-rename-vanished variant=$variant green=$green threw=$threw entries=$($entries -join ',') claimBytesUnchanged=$bytesUnchanged"
    if ($variant -ceq 'candidate') { Assert-Owner $green 'vanished owner is never recreated' }
    else { Assert-Owner (-not $green -and -not $threw -and $entries.Count -eq 2 -and $bytesUnchanged) 'missing link check mutant is RED' }
  }
}
function Test-ReaderContract([hashtable]$Sources) {
  $failures = [Collections.Generic.List[string]]::new()
  foreach ($site in @(
    @('invoke-heavy-verifier.ps1','Get-OwnerSnapshot'),
    @('controller-release-battery.ps1','Get-BatteryFleetLoad'),
    @('controller-release-battery.ps1','Assert-BatteryAdmission'),
    @('landed-integration-evidence.psm1','Get-FleetLoadObservation'),
    @('host-heavy-verifier.test.ps1','Wait-NativeOwner'),
    @('controller-install-lock.psm1','Get-ControllerInstallOwnerSnapshot')
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
      $cs -notmatch 'new FileStream\(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite \| FileShare.Delete\)' -or
      $cs -match 'File.ReadAllBytes\((transition|ownerPath|Path.Combine\(lockDirectory, "owner.json")') { $failures.Add('heavy-nested-owner.cs:ReadOwnerBytes') }
  foreach($name in @('liveOwnerMatchesToken','readNestedOwner')) {
    $start=$Sources['heavy-slot.cjs'].IndexOf("function $name(")
    $end=$Sources['heavy-slot.cjs'].IndexOf("`nfunction ",$start+1)
    $body=$Sources['heavy-slot.cjs'].Substring($start,$end-$start)
    if($body -notmatch 'readOwnerText\(ownerPath\)'){$failures.Add("heavy-slot.cjs:$name")}
  }
  return ,$failures
}
function Assert-ClassifiedOpeners([string[]]$Openers, [hashtable]$Classified) {
  $unknown=@($Openers | Where-Object {-not $Classified.ContainsKey($_)})
  Assert-Owner ($unknown.Count-eq0) "owner-reader-inventory unclassified openers: $($unknown -join ', ')"
}
function Invoke-ReaderInventory {
  $sources=@{}
  foreach($name in @('invoke-heavy-verifier.ps1','controller-release-battery.ps1','landed-integration-evidence.psm1','host-heavy-verifier.test.ps1','controller-install-lock.psm1','heavy-nested-owner.cs','heavy-slot.cjs')) { $sources[$name]=Read-Source $name }
  Assert-Owner ((Test-ReaderContract $sources).Count-eq0) 'owner-reader-inventory: every Bug-owned site delete-shares, closes and reopens'
  $table=[Collections.Generic.List[object]]::new()
  foreach($site in @(
    @('invoke-heavy-verifier.ps1','Get-OwnerSnapshot','ReadAllText + ReadAllBytes','1','BOM-aware UTF8; schema6 strict UTF8, no BOM, 16384 bytes','Test-ThisOwner; release; reclaim'),
    @('controller-release-battery.ps1','Get-BatteryFleetLoad','Get-Content -Raw','3','BOM-aware UTF8 / ConvertFrom-Json','battery item runner'),
    @('controller-release-battery.ps1','Assert-BatteryAdmission','ReadAllText','1','BOM-aware UTF8 / ConvertFrom-Json','battery admission poll'),
    @('landed-integration-evidence.psm1','Get-FleetLoadObservation','ReadAllText','1','BOM-aware UTF8 / ConvertFrom-RebaseJson','interrupted-integration-test-support.ps1:160,254,556,558'),
    @('host-heavy-verifier.test.ps1','Wait-NativeOwner','Get-Content -Raw','3','BOM-aware UTF8 / ConvertFrom-Json','native fixture wait'),
    @('controller-install-lock.psm1','Get-ControllerInstallOwnerSnapshot','FileStream / MemoryStream','7','strict UTF8, no BOM / ConvertFrom-Json','installer dead-owner reclaim')
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
  foreach($line in @(83)) {$table.Add(@{site="heavy-slot.cjs:$line";api='readOwnerText / fs.readFileSync';shareBefore=7;shareAfter=7;decoder='UTF8 / JSON.parse or parseClosedJson';callers='liveOwnerMatchesToken / readNestedOwner';owner='bounded transient-open retry'})}
  # Each fixture exception is a site, not a file exemption. These observations
  # inspect fixture-owned retained records; they do not define live publication.
  $fixtures=@{
    # 3242: the #99 sampler-transition-pause pre-fix Get-Content sampler (RED control).
    'controller-release-battery.test.ps1'=@(950,959,969,988,1593,1928,3242)
    'heavy-admission-preload.test.ps1'=@(128,613,642,750,1044,1050,1143,1200,1347,1394,1914,1918)
    'heavy-slot.test.ps1'=@(95,98,121,1892,2218,2395)
    # install-controller-skills.ps1 reads the installed release record, not heavy
    # owner state; the test-file sites compare fixture-retained owner bytes.
    'install-controller-skills.ps1'=@(145)
    'install-controller-skills.test.ps1'=@(208,225,230,319,340,354)
    # Complete current-site table for the combined head.  These are fixture
    # observations of retained owner bytes, not production publication.
    'invoke-heavy-verifier.test.ps1'=@(422,742,1307,1354,1366,1415,1419,1430,1455,1537,1551,1759,2154,2234,2244,2258,2553,2558,2577,2583,2810,2817,2829,2832,2842,2853,2875,2880,2892,2897,2914,2928)
    'long-product-gate.test.ps1'=@(154,161,177,762)
    'invoke-fleet-exclusive-gate.test.ps1'=@(309,310)
    'landed-integration-dispatch.test.ps1'=@(540)
    'interrupted-integration-test-support.ps1'=@(987)
    'landed-integration-evidence-test-support.ps1'=@(245)
    'landed-integration-r3.test.ps1'=@(49)
    'lane-stall-watchdog.test.ps1'=@(528,574,577)
    'lease-contract.test.ps1'=@(87,88)
    'product-census-budget.test.ps1'=@(243,308,347)
  }
  foreach($name in $fixtures.Keys) {
    $lines=(Read-Source $name)-split "`n"
    foreach($line in $fixtures[$name]) {
      $table.Add(@{site="${name}:$line";api=$lines[$line-1].Trim();shareBefore='unchanged fixture API';shareAfter='unchanged';decoder='unchanged fixture decoder';callers='fixture-local assertion/observation';owner='fixture-only: synthetic lock or retained-byte assertion, not production publication'})
    }
  }
  foreach($line in @(5,1136)) {
    $table.Add(@{site="host-heavy-verifier.test.ps1:$line";api=($sources['host-heavy-verifier.test.ps1']-split "`n")[$line-1].Trim();shareBefore='1/3/libuv';shareAfter='unchanged';decoder='unchanged';callers='interruption / teardown / embedded Node';owner='#9624, deliberately not converted'})
  }
  foreach($line in @(374,387,446,477,478,507,515,527,546,547,556,559,667,750,753,764,938,939,965,967)) {
    $table.Add(@{site="host-heavy-verifier.test.ps1:$line";api=($sources['host-heavy-verifier.test.ps1']-split "`n")[$line-1].Trim();shareBefore='Python read_text/read_bytes or pipe read';shareAfter='unchanged';decoder='unchanged Python decoder';callers='embedded native fixture setup / proc observation / pipe transport';owner='#9624; non-heavy-owner fixture/proc/transport reads, explicitly retained'})
  }
  $table.Add(@{site='controller-install-lock.psm1:230';api='File.Open / MemoryStream (snapshot copies bytes once)';shareBefore='new in #207';shareAfter=7;decoder='strict UTF8, no BOM / ConvertFrom-Json';callers='Get-ControllerInstallOwnerSnapshot / Invoke-ReclaimableControllerVerifyOwner';owner='#207 installer dead-owner reclaim (#210)'})
  $table.Add(@{site='controller-install-lock.psm1:260';api='File.Open / StreamReader (claim bytes read once)';shareBefore='new in #207';shareAfter=4;decoder='strict UTF8, no BOM / ConvertFrom-Json';callers='Remove-ClaimedOwnerLock (renamed claim, not live owner.json)';owner='#207 installer dead-owner reclaim (#210)'})
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
  # Pinned historical fixture bytes (fixtures/historical-*/README.md blob pins)
  # are only copied into synthetic temp roots by New-HistoricalDispatchFixture.
  # Their sites are keyed by repository-relative path, so a historical opener
  # can never borrow the classification of a current file with the same name
  # and line. Each pinned site must still name a discovered opener.
  $historicalSites=[ordered]@{
    '.orchestrator/fixtures/historical-0b6e67e8/.orchestrator/dispatch-ownership.ps1'=@(258)
    '.orchestrator/fixtures/historical-0b6e67e8/.orchestrator/invoke-heavy-verifier.ps1'=@(474,745,792)
    '.orchestrator/fixtures/historical-aa62899/.orchestrator/dispatch-ownership.ps1'=@(514)
    '.orchestrator/fixtures/historical-aa62899/.orchestrator/landed-integration-evidence.psm1'=@(993)
    '.orchestrator/fixtures/historical-b3b4ac2/.orchestrator/dispatch-ownership.ps1'=@(278)
    '.orchestrator/fixtures/historical-b3b4ac2/.orchestrator/invoke-heavy-verifier.ps1'=@(693,696,1017,1067)
    '.orchestrator/fixtures/historical-b3b4ac2/.orchestrator/landed-integration-evidence.psm1'=@(924)
    '.orchestrator/fixtures/historical-f67fc96a/.orchestrator/dispatch-ownership.ps1'=@(278)
    '.orchestrator/fixtures/historical-f67fc96a/.orchestrator/invoke-heavy-verifier.ps1'=@(474,745,792)
  }
  function Get-ReaderSiteKey([string]$Relative,[int]$Line) {
    if($Relative -clike '.orchestrator/fixtures/historical-*/*'){ return "${Relative}:$Line" }
    return "$([IO.Path]::GetFileName($Relative)):$Line"
  }
  $findStaleHistorical={ param($Pins) @(foreach($relative in $Pins.Keys){ $lines=[IO.File]::ReadAllLines((Join-Path $root $relative)); foreach($line in $Pins[$relative]){ if($line-gt$lines.Length -or -not($lines[$line-1]-match$readPattern-and$lines[$line-1]-match$pathPattern)){Get-ReaderSiteKey $relative $line} } }) }
  $staleHistorical=@(& $findStaleHistorical $historicalSites)
  Assert-Owner ($staleHistorical.Count-eq0) "owner-reader-inventory stale historical fixture sites: $($staleHistorical -join ', ')"
  $staleHistoricalMutant=[ordered]@{'.orchestrator/fixtures/historical-0b6e67e8/.orchestrator/dispatch-ownership.ps1'=@(259)}
  Assert-Owner ((@(& $findStaleHistorical $staleHistoricalMutant)) -ccontains '.orchestrator/fixtures/historical-0b6e67e8/.orchestrator/dispatch-ownership.ps1:259') 'stale historical fixture pin control is RED'
  foreach($relative in $historicalSites.Keys) {
    $fixtureRoot=[regex]::Match($relative,'^\.orchestrator/fixtures/historical-[^/]+').Value
    $inner=$relative.Substring($fixtureRoot.Length+1)
    $pin=@(Get-Content -LiteralPath (Join-Path $root "$fixtureRoot/README.md") | ForEach-Object { if($_ -match '^\- (?<path>\.orchestrator/[^|]+?)\s*\| blob `(?<blob>[0-9a-f]{40})`$' -and $Matches.path.Trim() -ceq $inner){$Matches.blob} })
    # Committed fixture files carry CRLF; the README pins the historical LF blob.
    $raw=[IO.File]::ReadAllBytes((Join-Path $root $relative)); $lfList=[Collections.Generic.List[byte]]::new($raw.Length)
    for($i=0;$i-lt$raw.Length;$i++){ if(-not($raw[$i]-eq13-and$i+1-lt$raw.Length-and$raw[$i+1]-eq10)){$lfList.Add($raw[$i])} }
    $lf=$lfList.ToArray()
    $actual=[Convert]::ToHexString([Security.Cryptography.SHA1]::HashData([byte[]]([Text.Encoding]::ASCII.GetBytes("blob $($lf.Length)`0")+$lf))).ToLowerInvariant()
    Assert-Owner ($pin.Count-eq1 -and $actual-ceq$pin[0]) "historical fixture bytes are not the README-pinned blob: $relative"
    $lines=[IO.File]::ReadAllLines((Join-Path $root $relative))
    foreach($line in $historicalSites[$relative]) {
      $key=Get-ReaderSiteKey $relative $line
      $table.Add(@{site=$key;api=$lines[$line-1].Trim();shareBefore='pinned historical bytes';shareAfter='unchanged';decoder='unchanged historical decoder';callers='New-HistoricalDispatchFixture copy into a synthetic temp root';owner="pinned historical fixture bytes (blob $($pin[0])), never live publication"})
      $classified[$key]=$true
    }
  }
  # Control: a current-file entry with the same file name and line must not
  # classify a historical site. The bare-name key would have accepted it.
  $borrowProbe='.orchestrator/fixtures/historical-0b6e67e8/.orchestrator/dispatch-ownership.ps1'
  $borrowed=@{}; foreach($key in $classified.Keys){ if($key -notlike '.orchestrator/fixtures/historical-*'){ $borrowed[$key]=$true } }
  $borrowed["$([IO.Path]::GetFileName($borrowProbe)):258"]=$true
  Assert-Owner ($borrowed.ContainsKey("$([IO.Path]::GetFileName($borrowProbe)):258")) 'historical borrow control has a same-name current-file entry'
  $refused=$false
  try { Assert-ClassifiedOpeners @(Get-ReaderSiteKey $borrowProbe 258) $borrowed } catch {$refused=$_.Exception.Message.Contains('unclassified openers')}
  Assert-Owner $refused 'historical site cannot borrow a current-file classification control is RED'
  $selfSource=Read-Source 'owner-publication.test.ps1'
  foreach($spec in @(@('Invoke-Primitive',4,'deliberately held positive/negative readers and injected claim opener'),@('Invoke-ContinuousPublication',1,'held delete-sharing reader across continuous fixture publications'),@('Test-ReaderContract',2,'source-only regression expressions, not executed opens'),@('Invoke-ReaderInventory',3,'source-only inventory expressions, not executed opens'),@('Invoke-ReaderMatrix',1,'deliberately cached-handle negative control'))) {
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
  $boundWriterExpression='[ChaseSets.HeavyAdmission.OwnerRename]::OpenDestination(' + $ownerVariable + ')'
  Assert-Owner ($invokeSource.Contains($boundWriterExpression)) 'handle-bound owner publication is classified'
  $boundWriterLine=1+[regex]::Matches($invokeSource.Substring(0,$invokeSource.IndexOf($boundWriterExpression,[StringComparison]::Ordinal)),"`n").Count
  $table.Add(@{site="invoke-heavy-verifier.ps1:$boundWriterLine";api='OwnerRename.OpenDestination / CreateFileW(FILE_READ_ATTRIBUTES, share 7)';shareBefore='File.Replace';shareAfter=7;decoder='none';callers='Write-OwnerRecord non-create';owner='bound rename writer and replaced-file unlink proof, not a snapshot reader'})
  foreach($relative in @(& git -C $root ls-files '.orchestrator/*.ps1' '.orchestrator/*.psm1' '.orchestrator/*.cs' '.orchestrator/*.cjs' '.orchestrator/*.py' '.orchestrator/*.mjs' '.orchestrator/*.js')) {
    $name=[IO.Path]::GetFileName($relative); $lines=[IO.File]::ReadAllLines((Join-Path $root $relative))
    for($index=0;$index-lt$lines.Length;$index++) {
      $text=$lines[$index]
      if($text-match$readPattern -and $text-match$pathPattern) {
        $key=Get-ReaderSiteKey $relative ($index+1)
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
  $otherException=[Exception]::new('not an IO denial')
  [Exception].GetProperty('HResult').SetValue($otherException,5)
  $policyCases=@(
    @{name='Windows IO access denial';windows=$true;error=[IO.IOException]::new('denied',5);attempt=1;elapsed=0;stop=$false},
    @{name='Windows unauthorized';windows=$true;error=[UnauthorizedAccessException]::new('denied');attempt=1;elapsed=0;stop=$false},
    @{name='Windows sharing violation';windows=$true;error=[IO.IOException]::new('sharing',32);attempt=1;elapsed=0;stop=$false},
    @{name='non-Windows IO denial';windows=$false;error=[IO.IOException]::new('denied',5);attempt=1;elapsed=0;stop=$true},
    @{name='non-Windows unauthorized';windows=$false;error=[UnauthorizedAccessException]::new('denied');attempt=1;elapsed=0;stop=$true},
    @{name='non-Windows sharing';windows=$false;error=[IO.IOException]::new('sharing',32);attempt=1;elapsed=0;stop=$true},
    @{name='absent';windows=$true;error=[IO.IOException]::new('absent',2);attempt=1;elapsed=0;stop=$true},
    @{name='wrong exception type';windows=$true;error=$otherException;attempt=1;elapsed=0;stop=$true},
    @{name='attempt cap';windows=$true;error=[UnauthorizedAccessException]::new('denied');attempt=8;elapsed=0;stop=$true},
    @{name='time cap';windows=$true;error=[UnauthorizedAccessException]::new('denied');attempt=1;elapsed=1000;stop=$true}
  )
  foreach($site in @(
    @('invoke-heavy-verifier.ps1','Get-OwnerSnapshot'),
    @('controller-release-battery.ps1','Get-BatteryFleetLoad'),
    @('controller-release-battery.ps1','Assert-BatteryAdmission'),
    @('landed-integration-evidence.psm1','Get-FleetLoadObservation'),
    @('controller-install-lock.psm1','Get-ControllerInstallOwnerSnapshot')
  )) {
    $body=Get-Definition (Read-Source $site[0]) $site[1]
    $ast=[Management.Automation.Language.Parser]::ParseInput($body,[ref]$null,[ref]$null)
    $predicates=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text.Contains('$errorCode -notin @(5, 32)')},$true))
    Assert-Owner ($predicates.Count-eq1) "one retry predicate for $($site[1])"
    $decision=$predicates[0].Clauses[0].Item1.Extent.Text.Replace('$IsWindows','$windows')
    foreach($policyCase in $policyCases) {
      $stops=& {
        param($Decision,$Case)
        $windows=$Case.windows; $exception=$Case.error; $errorCode=[int]$exception.HResult-band 0xffff
        $openAttempt=$Case.attempt; $openDeadline=[pscustomobject]@{ElapsedMilliseconds=$Case.elapsed}
        & ([scriptblock]::Create($Decision))
      } $decision $policyCase
      Assert-Owner ($stops-eq$policyCase.stop) "$($site[1]) retry predicate: $($policyCase.name)"
      $results.Add(@{test='owner-open-policy';site=$site[1];case=$policyCase.name;stops=$stops})
    }
  }
  Write-Output 'PASS PowerShell owner open policy: all five sites, Windows-only denial codes, exception types, attempt/time caps'
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
  $retryProbe=Join-Path $temporaryRoot 'node-owner-retry-probe.cjs'
  [IO.File]::WriteAllText($retryProbe,@'
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const input = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const source = fs.readFileSync(input.source, 'utf8');
const lock = path.join(input.root, '.orchestrator', 'verify-lock.d');
fs.mkdirSync(lock, {recursive:true});
const owner = path.join(lock, 'owner.json');
fs.writeFileSync(owner, JSON.stringify({schemaVersion:4,lockId:'a'.repeat(32),owner:'fixture',lane:'fixture',branch:'codex/fixture',worktree:input.root,head:'b'.repeat(40),identityMode:'branch',pid:1,processStartUtc:'2026-01-01T00:00:00.0000000Z',startedUtc:'2026-01-01T00:00:00.0000000Z',gate:'test',commandIdentity:'c'.repeat(64),state:'started',childPid:2,childProcessStartUtc:'2026-01-01T00:00:00.0000000Z'}));
const original = fs.readFileSync.bind(fs);
const readers = new Function('require', 'module', '__dirname', source + '\nreturn { readNestedOwner, readOwnerText };')((name) => name === 'node:fs' ? fs : require(name), {exports:{}}, path.dirname(input.source));
let transient = 3;
fs.readFileSync = (candidate, encoding) => {
  if (candidate === owner && transient > 0) { transient -= 1; const error = new Error('transient owner open denial'); error.code = 'EPERM'; error.syscall = 'open'; throw error; }
  return original(candidate, encoding);
};
const recovered = readers.readNestedOwner(input.root, 'a'.repeat(32));
assert(recovered.owner && transient === 0, 'bounded retry recovers transient EPERM');
transient = 3;
fs.readFileSync = (candidate, encoding) => {
  if (candidate === owner && transient > 0) { transient -= 1; const error = new Error('transient sharing violation'); error.code = 'EBUSY'; error.syscall = 'open'; throw error; }
  return original(candidate, encoding);
};
assert(readers.readNestedOwner(input.root, 'a'.repeat(32)).owner && transient === 0, 'bounded retry recovers Windows sharing violation');
const mutantSource = source.replace('const ownerOpenRetryAttempts = 8;', 'const ownerOpenRetryAttempts = 1;');
assert.notEqual(mutantSource, source);
const mutant = new Function('require', 'module', '__dirname', mutantSource + '\nreturn { readNestedOwner };')((name) => name === 'node:fs' ? fs : require(name), {exports:{}}, path.dirname(input.source));
transient = 3;
assert.equal(mutant.readNestedOwner(input.root, 'a'.repeat(32)).failure, 'owner record was unreadable', 'retry-removal mutant is RED');
const capMutantSource = source.replace('const ownerOpenRetryAttempts = 8;', 'const ownerOpenRetryAttempts = 7;');
assert.notEqual(capMutantSource, source);
const capMutant = new Function('require', 'module', '__dirname', capMutantSource + '\nreturn { readNestedOwner };')((name) => name === 'node:fs' ? fs : require(name), {exports:{}}, path.dirname(input.source));
let stableAttempts = 0;
fs.readFileSync = () => { stableAttempts += 1; const error = new Error('stable permission denial'); error.code = 'EACCES'; error.syscall = 'open'; throw error; };
const originalClock = process.hrtime.bigint;
let clockCalls = 0;
try {
  process.hrtime.bigint = () => 0n;
  const refused = readers.readNestedOwner(input.root, 'a'.repeat(32));
  assert(refused.failure === 'owner record was unreadable', 'stable EACCES remains fail-closed');
  assert.equal(stableAttempts, 8, 'stable denial exhausts exactly eight opens without wall-clock expiry');
  let capMutantAttempts = 0;
  fs.readFileSync = () => { capMutantAttempts += 1; const error = new Error('stable permission denial'); error.code = 'EACCES'; error.syscall = 'open'; throw error; };
  assert.throws(() => {
    const mutantRefused = capMutant.readNestedOwner(input.root, 'a'.repeat(32));
    assert(mutantRefused.failure === 'owner record was unreadable', 'stable EACCES cap mutant remains fail-closed');
    assert.equal(capMutantAttempts, 8, 'stable denial cap mutant must fail the eight-open control');
  }, /stable denial cap mutant must fail the eight-open control/);
  assert.equal(capMutantAttempts, 7, '8-to-7 cap mutant is killed by the stable-denial control');
  stableAttempts = 0;
  fs.readFileSync = () => { stableAttempts += 1; const error = new Error('stable permission denial'); error.code = 'EACCES'; error.syscall = 'open'; throw error; };
  process.hrtime.bigint = () => clockCalls++ === 0 ? 0n : 1000000000n;
  assert.throws(() => readers.readOwnerText(owner), {code:'EACCES'});
  assert.equal(stableAttempts, 1, 'one-second deadline prevents another open');
} finally { process.hrtime.bigint = originalClock; }
for (const [code, syscall] of [['ENOENT','open'], ['EIO','open'], ['EPERM','read']]) {
  let attempts = 0;
  fs.readFileSync = () => { attempts++; const error = new Error('not a transient open denial'); Object.assign(error, {code,syscall}); throw error; };
  assert.throws(() => readers.readOwnerText(owner), {code,syscall});
  assert.equal(attempts, 1, `${code}/${syscall} is never retried`);
}
'@)
  $retryInput=Join-Path $temporaryRoot 'node-owner-retry-input.json'
  [IO.File]::WriteAllText($retryInput,(@{source=$sourcePath;root=$temporaryRoot}|ConvertTo-Json -Compress))
  & (Resolve-NodeExecutable) $retryProbe $retryInput
  Assert-Owner ($LASTEXITCODE-eq0) 'Node owner reader bounded retry and stable-denial controls'
  Write-Output 'PASS Node owner reader bounded retry recovers transient EPERM and EBUSY; retry-removal mutant RED; stable EACCES refused after eight opens'
}
try {
  # The hosted battery runs without -Stress. Keep the 4000-replacement,
  # production-reader diagnostic opt-in; deterministic removal controls below
  # still exercise the production remedy on every default run.
  if ($Scenario -eq 'Continuous' -and -not $Stress) { throw 'Continuous production-reader stress requires -Stress' }
  if ($Stress -and $Scenario -in @('All','Continuous')) { Invoke-ContinuousPublication }
  if ($Scenario -in @('All','Primitive')) { Invoke-Primitive; Invoke-VanishedPublication }
  if ($Scenario -in @('All','Readers')) { Invoke-ReaderInventory; Invoke-ReaderMatrix; Invoke-ManagedReaderMatrix; Invoke-NodeReaderMatrix }
} finally {
  if ($EvidencePath) { [IO.File]::WriteAllText($EvidencePath,($results|ConvertTo-Json -Depth 18),[Text.UTF8Encoding]::new($false)) }
  $resolved=[IO.Path]::GetFullPath($temporaryRoot)
  Assert-Owner ($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)) 'owned cleanup stays in temp'
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
