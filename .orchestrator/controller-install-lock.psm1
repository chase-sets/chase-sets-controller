Set-StrictMode -Version Latest

function Get-ControllerInstallMutexName {
  [CmdletBinding()]
  param()
  "Global\ChaseSetsControllerInstall"
}

function Invoke-WithControllerInstallLock {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][scriptblock]$Body,
    [timespan]$Timeout = ([timespan]::FromSeconds(30))
  )
  if ($Timeout -le [timespan]::Zero -or $Timeout -gt [timespan]::FromMinutes(5)) {
    throw "controller install lock refused: timeout is outside the closed bound"
  }
  $mutex = [Threading.Mutex]::new($false, (Get-ControllerInstallMutexName))
  $owned = $false
  try {
    try { $owned = $mutex.WaitOne($Timeout) }
    catch [Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) { throw "controller install lock refused: exclusive writer lock timed out" }
    & $Body
  } finally {
    if ($owned) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
  }
}

function Test-ControllerInstallSamePath([string]$Left, [string]$Right) {
  try {
    return [string]::Equals(
      [IO.Path]::GetFullPath($Left).TrimEnd('\', '/'),
      [IO.Path]::GetFullPath($Right).TrimEnd('\', '/'),
      [StringComparison]::OrdinalIgnoreCase
    )
  } catch {
    return $false
  }
}

function Test-ControllerInstallSafeDirectory([string]$Path) {
  try {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    return $item.PSIsContainer -and
      (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne [IO.FileAttributes]::ReparsePoint)
  } catch {
    return $false
  }
}

function Test-ControllerInstallSafeFile([string]$Path) {
  try {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    return (-not $item.PSIsContainer) -and
      (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne [IO.FileAttributes]::ReparsePoint)
  } catch {
    return $false
  }
}

function Test-ControllerInstallUtc([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
  $parsed = [DateTimeOffset]::MinValue
  return [DateTimeOffset]::TryParse($Value, [ref]$parsed)
}

function Test-ControllerInstallPositivePid($Value) {
  if ($Value -isnot [int] -and $Value -isnot [long]) { return $false }
  $parsed = 0
  return [int]::TryParse([string]$Value, [ref]$parsed) -and $parsed -gt 0
}

function Get-ControllerInstallProcessIdentityState($ProcessId, [string]$StartIdentity) {
  if (-not (Test-ControllerInstallPositivePid $ProcessId) -or
      -not (Test-ControllerInstallUtc $StartIdentity)) { return 'ambiguous' }
  try {
    $candidate = @(Get-Process -Id ([int]$ProcessId) -ErrorAction SilentlyContinue)
    if ($candidate.Count -eq 0) { return 'dead' }
    if ($candidate.Count -ne 1) { return 'ambiguous' }
    $expected = [DateTimeOffset]::Parse($StartIdentity).ToUniversalTime().Ticks
    $actual = $candidate[0].StartTime.ToUniversalTime().Ticks
    return $(if ($actual -eq $expected) { 'live' } else { 'reused' })
  } catch {
    return 'ambiguous'
  }
}

function Test-ControllerInstallOwnerShape($Record) {
  if ($null -eq $Record) { return $false }
  $schemaProperty = $Record.PSObject.Properties['schemaVersion']
  if ($null -eq $schemaProperty -or $schemaProperty.Value -isnot [long] -or $schemaProperty.Value -notin @(2, 3, 4, 5)) { return $false }
  $schemaVersion = [long]$schemaProperty.Value
  $legacyCommon = @('schemaVersion', 'lockId', 'owner', 'lane', 'branch', 'pid', 'processStartUtc', 'startedUtc', 'gate', 'commandIdentity')
  $expected = if ($schemaVersion -in @(2, 3)) {
    @($legacyCommon) + @('state', 'childPid', 'childProcessStartUtc')
  } elseif ($schemaVersion -eq 4) {
    @($legacyCommon) + @('worktree', 'head', 'identityMode', 'state', 'childPid', 'childProcessStartUtc')
  } else {
    @($legacyCommon) + @('worktree', 'head', 'identityMode', 'state', 'childPid', 'childProcessStartUtc', 'admissionRoot')
  }
  $actual = @($Record.PSObject.Properties.Name)
  if ($actual.Count -ne $expected.Count) { return $false }
  foreach ($name in $expected) { if ($actual -cnotcontains $name) { return $false } }
  foreach ($name in @('lockId', 'owner', 'lane', 'pid', 'processStartUtc', 'startedUtc', 'gate', 'commandIdentity')) {
    if ([string]::IsNullOrWhiteSpace([string]$Record.$name)) { return $false }
  }
  if ($schemaVersion -lt 4 -and [string]::IsNullOrWhiteSpace([string]$Record.branch)) { return $false }
  if ($schemaVersion -in @(4, 5)) {
    if ([string]::IsNullOrWhiteSpace([string]$Record.worktree) -or
        "$($Record.head)" -cnotmatch '^[a-f0-9]{40}$' -or
        $Record.identityMode -cnotin @('branch', 'immutable-head') -or
        ($Record.identityMode -ceq 'branch' -and [string]::IsNullOrWhiteSpace([string]$Record.branch)) -or
        ($Record.identityMode -ceq 'immutable-head' -and $null -ne $Record.branch)) { return $false }
    try { if (-not [IO.Path]::IsPathFullyQualified([string]$Record.worktree)) { return $false } } catch { return $false }
  }
  if ($schemaVersion -eq 5) {
    if ($Record.state -cne 'attached' -or [string]::IsNullOrWhiteSpace([string]$Record.admissionRoot)) { return $false }
    try {
      $root = [IO.Path]::GetFullPath([string]$Record.admissionRoot).TrimEnd('\', '/')
      $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
      if ((Split-Path -Parent $root).TrimEnd('\', '/') -cne $temp -or
          (Split-Path -Leaf $root) -cnotmatch '^chase-sets-heavy-admission-[A-Za-z0-9_-]+$') { return $false }
    } catch { return $false }
  }
  if ("$($Record.lockId)" -cnotmatch '^[a-f0-9]{32}$' -or
      "$($Record.commandIdentity)" -cnotmatch '^[a-f0-9]{64}$' -or
      "$($Record.lane)" -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$' -or
      $Record.gate -cnotin @('verify:static', 'check:static', 'test:scripts', 'verify:test', 'test', 'test:fast', 'build', 'verify', 'verify:build', 'verify:test-db', 'test:e2e:suite', 'test:canonical-record', 'repository-gate', 'playwright', 'vitest-full', 'script-battery', 'diagnostic', 'manifest-replay') -or
      -not (Test-ControllerInstallPositivePid $Record.pid) -or
      -not (Test-ControllerInstallUtc ([string]$Record.processStartUtc)) -or
      -not (Test-ControllerInstallUtc ([string]$Record.startedUtc))) { return $false }
  $processStartedAt = [DateTimeOffset]::Parse([string]$Record.processStartUtc).ToUniversalTime()
  $recordedAt = [DateTimeOffset]::Parse([string]$Record.startedUtc).ToUniversalTime()
  if ($processStartedAt.Ticks -gt $recordedAt.Ticks -or $recordedAt.Ticks -gt [DateTimeOffset]::UtcNow.AddMinutes(5).Ticks) { return $false }
  if ($Record.schemaVersion -eq 3 -or ($Record.schemaVersion -in @(4, 5) -and $Record.state -ceq 'attached')) {
    if ($Record.state -cne 'attached' -or
        -not (Test-ControllerInstallPositivePid $Record.childPid) -or
        -not (Test-ControllerInstallUtc ([string]$Record.childProcessStartUtc))) { return $false }
    $guardedStartedAt = [DateTimeOffset]::Parse([string]$Record.childProcessStartUtc).ToUniversalTime()
    return $guardedStartedAt.Ticks -le $recordedAt.Ticks
  }
  if ($Record.state -ceq 'launching') { return $null -eq $Record.childPid -and $null -eq $Record.childProcessStartUtc }
  if ($Record.state -ceq 'started') {
    if (-not (Test-ControllerInstallPositivePid $Record.childPid) -or
        -not (Test-ControllerInstallUtc ([string]$Record.childProcessStartUtc))) { return $false }
    $childStartedAt = [DateTimeOffset]::Parse([string]$Record.childProcessStartUtc).ToUniversalTime()
    return $childStartedAt.Ticks -ge $recordedAt.Ticks -and
      $childStartedAt.Ticks -le [DateTimeOffset]::UtcNow.AddMinutes(5).Ticks
  }
  return $false
}

function Test-ControllerInstallPossibleOwnedChild($Record) {
  try {
    $recordedAt = [DateTimeOffset]::Parse([string]$Record.startedUtc).ToUniversalTime()
    $pending = [Collections.Generic.Queue[object]]::new()
    $known = @{}
    $roots = @([pscustomobject]@{ ProcessId = [int]$Record.pid; StartIdentity = [string]$Record.processStartUtc })
    if ($Record.state -in @('started', 'attached')) {
      $roots += [pscustomobject]@{ ProcessId = [int]$Record.childPid; StartIdentity = [string]$Record.childProcessStartUtc }
    }
    foreach ($root in $roots) {
      if ($known.ContainsKey($root.ProcessId)) { return $null }
      $known[$root.ProcessId] = $null
      $pending.Enqueue([pscustomobject]@{ ProcessId = $root.ProcessId; StartIdentity = $root.StartIdentity; CreationTicks = $null })
    }
    $getCreationUtc = {
      param($Candidate)
      if ($Candidate.CreationDate -is [DateTime]) { return ([DateTime]$Candidate.CreationDate).ToUniversalTime() }
      return [Management.ManagementDateTimeConverter]::ToDateTime([string]$Candidate.CreationDate).ToUniversalTime()
    }
    $testExactCimIdentity = {
      param([int]$ProcessId, [long]$CreationTicks)
      $exact = @(Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction Stop)
      if ($exact.Count -ne 1) { return $false }
      $exactPid = 0
      if (-not [int]::TryParse([string]$exact[0].ProcessId, [ref]$exactPid) -or $exactPid -ne $ProcessId) { return $false }
      return (& $getCreationUtc $exact[0]).Ticks -eq $CreationTicks
    }
    while ($pending.Count -gt 0) {
      $parent = $pending.Dequeue()
      $parentId = [int]$parent.ProcessId
      if ($null -eq $parent.CreationTicks) {
        if ((Get-ControllerInstallProcessIdentityState $parentId $parent.StartIdentity) -cnotin @('dead', 'reused')) { return $null }
      } elseif (-not (& $testExactCimIdentity $parentId ([long]$parent.CreationTicks))) { return $null }
      $candidates = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $parentId" -ErrorAction Stop)
      foreach ($candidate in $candidates) {
        $candidatePid = 0; $reportedParentId = 0
        if (-not [int]::TryParse([string]$candidate.ProcessId, [ref]$candidatePid) -or $candidatePid -le 0 -or
            -not [int]::TryParse([string]$candidate.ParentProcessId, [ref]$reportedParentId) -or $reportedParentId -ne $parentId) { return $null }
        $createdAt = & $getCreationUtc $candidate
        if (-not (& $testExactCimIdentity $candidatePid $createdAt.Ticks)) { return $null }
        if ($createdAt.Ticks -ge $recordedAt.Ticks) { return $true }
        if ($known.ContainsKey($candidatePid)) {
          if ($null -eq $known[$candidatePid] -or [long]$known[$candidatePid] -ne $createdAt.Ticks) { return $null }
          continue
        }
        $known[$candidatePid] = $createdAt.Ticks
        $pending.Enqueue([pscustomobject]@{ ProcessId = $candidatePid; StartIdentity = $null; CreationTicks = $createdAt.Ticks })
      }
      if ($null -eq $parent.CreationTicks) {
        if ((Get-ControllerInstallProcessIdentityState $parentId $parent.StartIdentity) -cnotin @('dead', 'reused')) { return $null }
      } elseif (-not (& $testExactCimIdentity $parentId ([long]$parent.CreationTicks))) { return $null }
    }
    return $false
  } catch {
    return $null
  }
}

function Test-ReclaimableOwner($Record) {
  if (-not (Test-ControllerInstallOwnerShape $Record)) { return $false }
  if ((Get-ControllerInstallProcessIdentityState $Record.pid ([string]$Record.processStartUtc)) -cne 'dead') { return $false }
  if ($Record.state -in @('started', 'attached')) {
    $childState = Get-ControllerInstallProcessIdentityState $Record.childPid ([string]$Record.childProcessStartUtc)
    if ($childState -cnotin @('dead', 'reused')) { return $false }
  }
  return (Test-ControllerInstallPossibleOwnedChild $Record) -eq $false
}

function Get-ControllerInstallOwnerSnapshot([string]$LockPath) {
  $ownerPath = Join-Path $LockPath 'owner.json'
  if (-not (Test-ControllerInstallSafeDirectory $LockPath) -or -not (Test-ControllerInstallSafeFile $ownerPath)) { return $null }
  try {
    $entries = @(Get-ChildItem -LiteralPath $LockPath -Force -ErrorAction Stop)
    if ($entries.Count -ne 1 -or -not (Test-ControllerInstallSamePath $entries[0].FullName $ownerPath)) { return $null }
    $openDeadline = [Diagnostics.Stopwatch]::StartNew()
    $stream = $null
    for ($openAttempt = 1; $null -eq $stream; $openAttempt++) {
      try {
        $stream = [IO.File]::Open($ownerPath, [IO.FileMode]::Open, [IO.FileAccess]::Read,
          ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
      } catch {
        $exception = $_.Exception.GetBaseException()
        $errorCode = [int]$exception.HResult -band 0xffff
        if (-not $IsWindows -or ($exception -isnot [IO.IOException] -and $exception -isnot [UnauthorizedAccessException]) -or
            $errorCode -notin @(5, 32) -or $openAttempt -ge 8 -or $openDeadline.ElapsedMilliseconds -ge 1000) { throw }
        [Threading.Thread]::Sleep([int][Math]::Min(10, [Math]::Max(1, 1000 - $openDeadline.ElapsedMilliseconds)))
        if ($openDeadline.ElapsedMilliseconds -ge 1000) { throw }
      }
    }
    try {
      $buffer = [IO.MemoryStream]::new()
      try { $stream.CopyTo($buffer); $bytes = $buffer.ToArray() } finally { $buffer.Dispose() }
    } finally { $stream.Dispose() }
    $raw = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    $record = $raw | ConvertFrom-Json -DateKind String -ErrorAction Stop
    return [pscustomobject]@{ Raw = $raw; Record = $record }
  } catch {
    return $null
  }
}

function Remove-ClaimedOwnerLock([string]$LockPath, [string]$ClaimPath, [string]$ExpectedRaw, [switch]$RequireDead) {
  $removed = $false
  $ownerPath = Join-Path $LockPath 'owner.json'
  try {
    if (-not (Test-ControllerInstallSafeDirectory $LockPath) -or -not (Test-ControllerInstallSafeFile $ClaimPath)) { return $false }
    $entries = @(Get-ChildItem -LiteralPath $LockPath -Force -ErrorAction Stop)
    if ($entries.Count -ne 1 -or -not (Test-ControllerInstallSamePath $entries[0].FullName $ClaimPath)) { return $false }
    $stream = [IO.File]::Open($ClaimPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Delete)
    try {
      $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false, $true), $false, 1024, $true)
      try { $raw = $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { $stream.Dispose() }
    if ($raw -cne $ExpectedRaw) { return $false }
    try { $record = $raw | ConvertFrom-Json -DateKind String -ErrorAction Stop } catch { return $false }
    if ($RequireDead -and -not (Test-ReclaimableOwner $record)) { return $false }
    if ($record.schemaVersion -eq 5 -and
        (Get-ControllerInstallProcessIdentityState $record.childPid ([string]$record.childProcessStartUtc)) -ceq 'dead') {
      $root = [IO.Path]::GetFullPath([string]$record.admissionRoot).TrimEnd('\', '/')
      if (Test-Path -LiteralPath $root) {
        if (-not (Test-ControllerInstallSafeDirectory $root)) { return $false }
        foreach ($item in @(Get-ChildItem -LiteralPath $root -Force -Recurse -ErrorAction Stop)) {
          if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq [IO.FileAttributes]::ReparsePoint)) { return $false }
        }
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $root) { return $false }
      }
    }
    [IO.File]::Delete($ClaimPath)
    $removed = $true
    if (Test-Path -LiteralPath $ClaimPath) { return $false }
    Remove-Item -LiteralPath $LockPath -Force -ErrorAction Stop
    return -not (Test-Path -LiteralPath $LockPath)
  } catch {
    return $false
  } finally {
    if (-not $removed -and (Test-ControllerInstallSafeFile $ClaimPath) -and -not (Test-Path -LiteralPath $ownerPath)) {
      try {
        $entries = @(Get-ChildItem -LiteralPath $LockPath -Force -ErrorAction Stop)
        if ($entries.Count -eq 1 -and (Test-ControllerInstallSamePath $entries[0].FullName $ClaimPath)) {
          [IO.File]::Move($ClaimPath, $ownerPath)
        }
      } catch {}
    }
  }
}

function Invoke-ReclaimableControllerVerifyOwner {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$ContainerRoot)
  $lockPath = Join-Path ([IO.Path]::GetFullPath($ContainerRoot)) '.orchestrator/verify-lock.d'
  $snapshot = Get-ControllerInstallOwnerSnapshot $lockPath
  if ($null -eq $snapshot -or -not (Test-ReclaimableOwner $snapshot.Record)) { return $false }
  $unchanged = Get-ControllerInstallOwnerSnapshot $lockPath
  if ($null -eq $unchanged -or $unchanged.Raw -cne $snapshot.Raw) { return $false }
  $claimPath = Join-Path $lockPath ('owner.reclaim.' + [guid]::NewGuid().ToString('N') + '.json')
  try { [IO.File]::Move((Join-Path $lockPath 'owner.json'), $claimPath) } catch { return $false }
  return Remove-ClaimedOwnerLock $lockPath $claimPath $snapshot.Raw -RequireDead
}

function Assert-ControllerLegacyReferencePath([string]$Path, [string]$TrustedRoot) {
  if (-not [IO.Path]::IsPathFullyQualified($Path) -or $Path.StartsWith('\\') -or $Path.StartsWith('//')) {
    throw 'legacy reference archive refused: path must be absolute and local'
  }
  $cursor = [IO.Path]::GetFullPath($Path)
  $boundary = if ($TrustedRoot) { [IO.Path]::GetFullPath($TrustedRoot).TrimEnd('\','/') } else { '' }
  if ($boundary -and -not ($cursor.Equals($boundary, [StringComparison]::OrdinalIgnoreCase) -or
      $cursor.StartsWith($boundary + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase))) {
    throw 'legacy reference archive refused: path escapes trusted root'
  }
  # Configured roots are authority, as in the installer's dropped-path guard.
  # They may resolve through host junctions; every descendant is still checked.
  while ($cursor -and -not $cursor.Equals($boundary, [StringComparison]::OrdinalIgnoreCase)) {
    $item = $null
    try { $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop }
    catch [System.Management.Automation.ItemNotFoundException] {}
    if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
      throw "legacy reference archive refused: reparse point: $cursor"
    }
    if ($cursor -ne $Path -and $item -and -not $item.PSIsContainer) {
      throw "legacy reference archive refused: non-directory ancestor: $cursor"
    }
    $parent = Split-Path -Parent $cursor
    if ($parent -eq $cursor) { break }
    $cursor = $parent
  }
}

function Test-ControllerLegacyReferenceBytes($Entry, [string]$Path) {
  $trustedRoot = if ($Path -ceq $Entry.Archive) { $Entry.ArchiveTrustedRoot } else { $Entry.TrustedRoot }
  Assert-ControllerLegacyReferencePath $Path $trustedRoot
  if (-not (Test-ControllerInstallSafeFile $Path)) { return $false }
  $bytes = [IO.File]::ReadAllBytes($Path)
  return [Convert]::ToBase64String($bytes) -ceq [Convert]::ToBase64String($Entry.Bytes) -and
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant() -ceq $Entry.Hash
}

function Get-ControllerLegacyReferenceArchivePlan {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$ContainerRoot,
    [Parameter(Mandatory)][string]$DestinationRoot,
    [Parameter(Mandatory)][string]$CodexSkillRoot)
  foreach ($path in @($ContainerRoot, $DestinationRoot, $CodexSkillRoot)) {
    Assert-ControllerLegacyReferencePath $path $path
  }
  $archiveRoot = [IO.Path]::GetFullPath((Join-Path $ContainerRoot '.orchestrator/archived-skill-references'))
  Assert-ControllerLegacyReferencePath $archiveRoot $ContainerRoot
  if ((Test-Path -LiteralPath $archiveRoot) -and -not (Test-ControllerInstallSafeDirectory $archiveRoot)) {
    throw 'legacy reference archive refused: archive is not an ordinary directory'
  }
  if (-not (Test-ControllerInstallSafeDirectory (Split-Path -Parent $archiveRoot))) {
    throw 'legacy reference archive refused: canonical runtime directory missing'
  }
  $discoveryRoots = @($DestinationRoot, $CodexSkillRoot)
  foreach ($base in @($HOME, $ContainerRoot)) {
    foreach ($relative in @('.agents/skills', '.claude/skills', '.codex/skills')) {
      $discoveryRoots += Join-Path $base $relative
    }
  }
  foreach ($root in $discoveryRoots) {
    $root = [IO.Path]::GetFullPath($root).TrimEnd('\','/')
    $prefix = $root + [IO.Path]::DirectorySeparatorChar
    if ($archiveRoot.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or
        $archiveRoot.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
        $root.StartsWith($archiveRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
      throw 'legacy reference archive refused: archive overlaps a skill-discovery root'
    }
  }
  if (($archiveRoot -split '[/\\]') -icontains 'skills') {
    throw 'legacy reference archive refused: archive has a skill-discovery ancestor'
  }
  $entries = @()
  foreach ($name in @('defect-classes.md', 'stall-gotchas.md',
      'defect-classes.md.bak-20261015T0925', 'defect-classes.md.bak-20261102T1400')) {
    $source = [IO.Path]::GetFullPath((Join-Path $DestinationRoot "milestone-orchestrator/references/$name"))
    Assert-ControllerLegacyReferencePath $source $DestinationRoot
    $item = $null
    try { $item = Get-Item -LiteralPath $source -Force -ErrorAction Stop }
    catch [System.Management.Automation.ItemNotFoundException] {}
    if (-not $item) { continue }
    if (-not (Test-ControllerInstallSafeFile $source)) {
      throw "legacy reference archive refused: not an ordinary file: $source"
    }
    $bytes = [IO.File]::ReadAllBytes($source)
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    $entry = [pscustomobject]@{ Source = $source; Archive = Join-Path $archiveRoot "$hash-$name"; Bytes = $bytes; Hash = $hash; TrustedRoot = $DestinationRoot; ArchiveTrustedRoot = $ContainerRoot }
    Assert-ControllerLegacyReferencePath $entry.Archive $entry.ArchiveTrustedRoot
    if ((Test-Path -LiteralPath $entry.Archive) -and -not (Test-ControllerLegacyReferenceBytes $entry $entry.Archive)) {
      throw "legacy reference archive refused: archive collision, no overwrite: $($entry.Archive)"
    }
    $entries += $entry
  }
  [pscustomobject]@{ ArchiveRoot = $archiveRoot; Entries = @($entries) }
}

function Write-ControllerLegacyReferenceNewFile([string]$Path, [byte[]]$Bytes) {
  $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
  try { $stream.Write($Bytes, 0, $Bytes.Length); $stream.Flush($true) }
  finally { $stream.Dispose() }
}

function Invoke-WithControllerLegacyReferenceArchive {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$ContainerRoot,
    [Parameter(Mandatory)][string]$DestinationRoot,
    [Parameter(Mandatory)][string]$CodexSkillRoot,
    [Parameter(Mandatory)][scriptblock]$Body, [switch]$Preview)
  # Caller holds the existing installer writer lock. Recheck paths and bytes
  # after verified copies, immediately before archiving any legacy input.
  $plan = Get-ControllerLegacyReferenceArchivePlan $ContainerRoot $DestinationRoot $CodexSkillRoot
  if ($Preview -or $plan.Entries.Count -eq 0) { & $Body; return }
  $created = [Collections.Generic.List[object]]::new()
  $removed = [Collections.Generic.List[object]]::new()
  $createdRoot = -not (Test-Path -LiteralPath $plan.ArchiveRoot)
  try {
    [void][IO.Directory]::CreateDirectory($plan.ArchiveRoot)
    foreach ($entry in $plan.Entries) {
      Assert-ControllerLegacyReferencePath $entry.Archive $entry.ArchiveTrustedRoot
      if (-not (Test-Path -LiteralPath $entry.Archive)) {
        Write-ControllerLegacyReferenceNewFile $entry.Archive $entry.Bytes
        $created.Add($entry)
      }
      if (-not (Test-ControllerLegacyReferenceBytes $entry $entry.Archive)) { throw 'legacy reference archive verification failed' }
    }
    foreach ($entry in $plan.Entries) {
      if (-not (Test-ControllerLegacyReferenceBytes $entry $entry.Source)) { throw 'legacy reference changed before removal' }
      [IO.File]::Delete($entry.Source)
      $removed.Add($entry)
    }
    & $Body
  } catch {
    $failure = $_
    $rollbackErrors = [Collections.Generic.List[string]]::new()
    foreach ($entry in $removed) {
      try {
        Assert-ControllerLegacyReferencePath $entry.Source $entry.TrustedRoot
        if (-not (Test-Path -LiteralPath $entry.Source)) { Write-ControllerLegacyReferenceNewFile $entry.Source $entry.Bytes }
        if (-not (Test-ControllerLegacyReferenceBytes $entry $entry.Source)) { throw 'source conflict; verified archive retained' }
      } catch { $rollbackErrors.Add($_.Exception.Message) }
    }
    foreach ($entry in $plan.Entries) {
      try {
        if (-not (Test-ControllerLegacyReferenceBytes $entry $entry.Source)) { throw 'original source bytes not restored; archive retained' }
      } catch { $rollbackErrors.Add($_.Exception.Message) }
    }
    if ($rollbackErrors.Count -eq 0) {
      foreach ($entry in $created) {
        if (Test-ControllerLegacyReferenceBytes $entry $entry.Archive) { [IO.File]::Delete($entry.Archive) }
      }
      if ($createdRoot) {
        Assert-ControllerLegacyReferencePath $plan.ArchiveRoot $ContainerRoot
        try { [IO.Directory]::Delete($plan.ArchiveRoot) } catch [IO.IOException] {}
      }
    } else {
      throw "legacy reference rollback refused to overwrite changed source; archives retained: $($rollbackErrors -join '; '); original: $($failure.Exception.Message)"
    }
    throw $failure
  }
}

function Get-ControllerSkillInstallInventory {
  [CmdletBinding()]
  param()
  @(
    [pscustomobject][ordered]@{ source = "model-routing/SKILL.md"; destination = "model-routing/SKILL.md"; preserveGenerated = $false; transportText = $true },
    [pscustomobject][ordered]@{ source = "model-routing/capability-matrix.json"; destination = "model-routing/capability-matrix.json"; preserveGenerated = $true; transportText = $false },
    [pscustomobject][ordered]@{ source = "model-routing/references/capability-recalibration.md"; destination = "model-routing/references/capability-recalibration.md"; preserveGenerated = $false; transportText = $true },
    [pscustomobject][ordered]@{ source = "model-routing/references/experiments.md"; destination = "model-routing/references/experiments.md"; preserveGenerated = $false; transportText = $true },
    [pscustomobject][ordered]@{ source = "model-routing/agents/openai.yaml"; destination = "model-routing/agents/openai.yaml"; preserveGenerated = $false; transportText = $true },
    [pscustomobject][ordered]@{ source = "milestone-orchestrator/SKILL.md"; destination = "milestone-orchestrator/SKILL.md"; preserveGenerated = $false; transportText = $true },
    [pscustomobject][ordered]@{ source = "milestone-orchestrator/references/integration-recovery.md"; destination = "milestone-orchestrator/references/integration-recovery.md"; preserveGenerated = $false; transportText = $true },
    [pscustomobject][ordered]@{ source = "milestone-orchestrator/references/lane-recovery.md"; destination = "milestone-orchestrator/references/lane-recovery.md"; preserveGenerated = $false; transportText = $true },
    [pscustomobject][ordered]@{ source = "milestone-orchestrator/references/landing-operations.md"; destination = "milestone-orchestrator/references/landing-operations.md"; preserveGenerated = $false; transportText = $true },
    [pscustomobject][ordered]@{ source = "milestone-orchestrator/references/velocity.md"; destination = "milestone-orchestrator/references/velocity.md"; preserveGenerated = $false; transportText = $true },
    [pscustomobject][ordered]@{ source = "milestone-orchestrator/references/brief-attribution.md"; destination = "milestone-orchestrator/references/brief-attribution.md"; preserveGenerated = $false; transportText = $true },
    [pscustomobject][ordered]@{ source = "milestone-orchestrator/references/one-shot-actions.md"; destination = "milestone-orchestrator/references/one-shot-actions.md"; preserveGenerated = $false; transportText = $true },
    [pscustomobject][ordered]@{ source = "milestone-orchestrator/references/replan.md"; destination = "milestone-orchestrator/references/replan.md"; preserveGenerated = $false; transportText = $true },
    [pscustomobject][ordered]@{ source = "milestone-orchestrator/agents/openai.yaml"; destination = "milestone-orchestrator/agents/openai.yaml"; preserveGenerated = $false; transportText = $true },
    [pscustomobject][ordered]@{ source = "orchestrator-shared/SKILL.md"; destination = "orchestrator-shared/SKILL.md"; preserveGenerated = $false; transportText = $true },
    [pscustomobject][ordered]@{ source = "orchestrator-shared/agents/openai.yaml"; destination = "orchestrator-shared/agents/openai.yaml"; preserveGenerated = $false; transportText = $true }
  )
}

function Get-ControllerTransportNormalizedBytes {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][byte[]]$Bytes,
    [Parameter(Mandatory)][bool]$TransportText
  )
  if (-not $TransportText) { return ,([byte[]]$Bytes.Clone()) }
  $utf8 = [Text.UTF8Encoding]::new($false, $true)
  $text = $utf8.GetString($Bytes)
  # Git-blob LF and a Windows checkout's CRLF are the only equivalent
  # transport forms. A lone CR remains content and therefore stays stale.
  $normalized = $text.Replace("`r`n", "`n")
  return ,([byte[]]$utf8.GetBytes($normalized))
}

function Merge-ControllerGeneratedMatrixBytes {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][byte[]]$CandidateBytes,
    [Parameter(Mandatory)][byte[]]$LiveBytes
  )
  $utf8 = [Text.UTF8Encoding]::new($false, $true)
  $src = ($utf8.GetString($CandidateBytes) | ConvertFrom-Json -DateKind String -ErrorAction Stop)
  $live = ($utf8.GetString($LiveBytes) | ConvertFrom-Json -DateKind String -ErrorAction Stop)

  # A configuration is identified by its exact model and effort; its literal id
  # is a derived key that a release may rename (model-routing v4.13 renamed all
  # twenty). Joining live to candidate by literal id alone made that rename an
  # empty join, so the live generated blocks were silently dropped and live's
  # old-id stamp was installed beside new-id configs. Index live by both.
  function Get-ConfigurationKey($Config) {
    $model = if ($Config.PSObject.Properties["model"]) { ([string]$Config.model).Trim().ToLowerInvariant() } else { "" }
    $effort = if ($Config.PSObject.Properties["effort"]) { ([string]$Config.effort).Trim().ToLowerInvariant() } else { "" }
    if (-not $model -or -not $effort) { return $null }
    return "$model/$effort"
  }
  $liveById = @{}
  $liveByKey = @{}
  foreach ($config in @($live.configs)) {
    if ($config.id) { $liveById[[string]$config.id] = $config }
    $key = Get-ConfigurationKey $config
    # Two live configs with one model+effort can arise only by hand-editing;
    # first wins, never silently last, so the join stays deterministic.
    if ($key -and -not $liveByKey.ContainsKey($key)) { $liveByKey[$key] = $config }
  }

  # Generated content transfers only within one generated schema. Across a
  # schema change (a stamp carrying a different `generatedSchema`, or none) the
  # candidate's freshly regenerated blocks and stamp win, because the live
  # blocks were produced by a script whose keying the candidate no longer
  # shares; the next refresh rebuilds them. The `adjudicated` snapshot is a
  # human baseline keyed to the configuration itself and transfers regardless.
  function Get-GeneratedSchema($Matrix) {
    if ($Matrix.PSObject.Properties["measuredAt"] -and $Matrix.measuredAt -and $Matrix.measuredAt.PSObject.Properties["generatedSchema"]) {
      return [string]$Matrix.measuredAt.generatedSchema
    }
    return ""
  }
  $sameSchema = (Get-GeneratedSchema $src) -ceq (Get-GeneratedSchema $live)

  $mergedIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($config in @($src.configs)) { if ($config.id) { [void]$mergedIds.Add([string]$config.id) } }
  # A live stamp that names configurations absent from the merged matrix (its
  # `configsWithoutEffortEvidence`) would be an orphaned stamp; keep the
  # candidate's instead.
  $liveStampOrphaned = $false
  if ($live.PSObject.Properties["measuredAt"] -and $live.measuredAt -and $live.measuredAt.PSObject.Properties["configsWithoutEffortEvidence"]) {
    foreach ($named in @($live.measuredAt.configsWithoutEffortEvidence)) {
      if ($named -and -not $mergedIds.Contains([string]$named)) { $liveStampOrphaned = $true; break }
    }
  }
  if ($live.PSObject.Properties["measuredAt"] -and $sameSchema -and -not $liveStampOrphaned) {
    if ($src.PSObject.Properties["measuredAt"]) { $src.measuredAt = $live.measuredAt }
    else { $src | Add-Member -NotePropertyName measuredAt -NotePropertyValue $live.measuredAt }
  }

  foreach ($config in @($src.configs)) {
    $liveConfig = $null
    if ($config.id -and $liveById.ContainsKey([string]$config.id)) { $liveConfig = $liveById[[string]$config.id] }
    else {
      $key = Get-ConfigurationKey $config
      if ($key -and $liveByKey.ContainsKey($key)) { $liveConfig = $liveByKey[$key] }
    }
    if ($null -eq $liveConfig) { continue }
    $carried = if ($sameSchema) { @("measured", "adjudicated") } else { @("adjudicated") }
    foreach ($generated in $carried) {
      if (-not $liveConfig.PSObject.Properties[$generated]) { continue }
      if ($config.PSObject.Properties[$generated]) { $config.$generated = $liveConfig.$generated }
      else { $config | Add-Member -NotePropertyName $generated -NotePropertyValue $liveConfig.$generated }
    }
  }
  $json = ($src | ConvertTo-Json -Depth 30) + [Environment]::NewLine
  [Text.UTF8Encoding]::new($false).GetBytes($json)
}

Export-ModuleMember -Function @(
  "Get-ControllerInstallMutexName",
  "Invoke-WithControllerInstallLock",
  "Get-ControllerSkillInstallInventory",
  "Get-ControllerLegacyReferenceArchivePlan",
  "Invoke-WithControllerLegacyReferenceArchive",
  "Get-ControllerTransportNormalizedBytes",
  "Merge-ControllerGeneratedMatrixBytes",
  "Invoke-ReclaimableControllerVerifyOwner"
)
