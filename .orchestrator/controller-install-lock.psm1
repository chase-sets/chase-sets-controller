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
  if ($null -eq $Record -or $Record.schemaVersion -isnot [long] -or $Record.schemaVersion -notin @(2, 3, 4, 5)) { return $false }
  $legacyCommon = @('schemaVersion', 'lockId', 'owner', 'lane', 'branch', 'pid', 'processStartUtc', 'startedUtc', 'gate', 'commandIdentity')
  $expected = if ($Record.schemaVersion -in @(2, 3)) {
    @($legacyCommon) + @('state', 'childPid', 'childProcessStartUtc')
  } elseif ($Record.schemaVersion -eq 4) {
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
  if ($Record.schemaVersion -lt 4 -and [string]::IsNullOrWhiteSpace([string]$Record.branch)) { return $false }
  if ($Record.schemaVersion -in @(4, 5)) {
    if ([string]::IsNullOrWhiteSpace([string]$Record.worktree) -or
        "$($Record.head)" -cnotmatch '^[a-f0-9]{40}$' -or
        $Record.identityMode -cnotin @('branch', 'immutable-head') -or
        ($Record.identityMode -ceq 'branch' -and [string]::IsNullOrWhiteSpace([string]$Record.branch)) -or
        ($Record.identityMode -ceq 'immutable-head' -and $null -ne $Record.branch)) { return $false }
    try { if (-not [IO.Path]::IsPathFullyQualified([string]$Record.worktree)) { return $false } } catch { return $false }
  }
  if ($Record.schemaVersion -eq 5) {
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
      $Record.gate -cnotin @('verify:static', 'check:static', 'test:scripts', 'verify:test', 'test', 'test:fast', 'build', 'verify', 'verify:build', 'verify:test-db', 'test:e2e:suite', 'repository-gate', 'playwright', 'vitest-full', 'script-battery', 'diagnostic') -or
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
  if (-not (Test-ControllerInstallOwnerShape $Record) -or $Record.schemaVersion -notin @(2, 3, 4, 5)) { return $false }
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
        if (-not $IsWindows -or $exception -isnot [IO.IOException] -and $exception -isnot [UnauthorizedAccessException] -or
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
    [pscustomobject][ordered]@{ source = "milestone-orchestrator/references/rule-provenance-v2.24.md"; destination = "milestone-orchestrator/references/rule-provenance-v2.24.md"; preserveGenerated = $false; transportText = $true },
    [pscustomobject][ordered]@{ source = "milestone-orchestrator/references/controller-defect-classes.md"; destination = "milestone-orchestrator/references/controller-defect-classes.md"; preserveGenerated = $false; transportText = $true },
    [pscustomobject][ordered]@{ source = "milestone-orchestrator/scripts/query-ledgers.ps1"; destination = "milestone-orchestrator/scripts/query-ledgers.ps1"; preserveGenerated = $false; transportText = $true },
    [pscustomobject][ordered]@{ source = "milestone-orchestrator/scripts/query-ledgers.test.ps1"; destination = "milestone-orchestrator/scripts/query-ledgers.test.ps1"; preserveGenerated = $false; transportText = $true },
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
  "Get-ControllerTransportNormalizedBytes",
  "Merge-ControllerGeneratedMatrixBytes",
  "Invoke-ReclaimableControllerVerifyOwner"
)
