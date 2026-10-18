. (Join-Path $PSScriptRoot "dispatch-ownership.ps1")

$script:FleetAdmissionSchema = "fleet-exclusive-admission/v1"
$script:FleetAdmissionDirectoryName = "fleet-admission.d"
$script:FleetAdmissionRecordName = "owner.json"
$script:FleetAdmissionTokenName = "CHASE_SETS_FLEET_ADMISSION_TOKEN"
$script:FleetAdmissionGates = @(
  "verify:static", "check:static", "test:scripts", "verify:test", "test",
  "test:fast", "build", "verify", "verify:build", "verify:test-db",
  "interrupted-canonical-integration"
)
$script:FleetAdmissionCountNames = @(
  "candidates", "examined", "active", "legacyLiveOwners",
  "lingeringAttempts", "inactive", "rejected", "probeFailures", "truncated"
)

function Get-FleetAdmissionPropertyNames {
  @(
    "schemaVersion", "leaseId", "ownerTokenSha256", "leaseHolder", "issue",
    "attempt", "host", "controllerRoot", "controllerRuntimeRoot", "controllerHead",
    "holderPid", "holderStartIdentity", "recordedAt", "state", "childPid",
    "childStartIdentity", "worktree", "branch", "claimedHead", "gate"
  )
}

function Get-FleetAdmissionPaths([string]$RuntimeRoot) {
  $runtime = Get-DispatchCanonicalExistingPath $RuntimeRoot
  if ([string]::IsNullOrWhiteSpace($runtime)) {
    throw "ADMISSION_DENIED: controller runtime root is absent or non-canonical"
  }
  $directory = Join-Path $runtime $script:FleetAdmissionDirectoryName
  [pscustomobject]@{
    runtime = $runtime
    directory = $directory
    record = Join-Path $directory $script:FleetAdmissionRecordName
  }
}

function Get-FleetAdmissionSha256([byte[]]$Bytes) {
  ([Convert]::ToHexString(
    [Security.Cryptography.SHA256]::HashData($Bytes)
  )).ToLowerInvariant()
}

function Test-FleetAdmissionSafeItem([string]$Path, [bool]$Container) {
  try {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ([bool]$item.PSIsContainer -ne $Container) { return $false }
    return (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne
      [IO.FileAttributes]::ReparsePoint)
  } catch {
    return $false
  }
}

function Test-FleetAdmissionRecordExact($Left, $Right) {
  if ($null -eq $Left -or $null -eq $Right) { return $false }
  $names = @(Get-FleetAdmissionPropertyNames)
  if (@($Left.PSObject.Properties.Name).Count -ne $names.Count -or
      @($Right.PSObject.Properties.Name).Count -ne $names.Count) { return $false }
  foreach ($name in $names) {
    $leftProperty = $Left.PSObject.Properties[$name]
    $rightProperty = $Right.PSObject.Properties[$name]
    if ($null -eq $leftProperty -or $null -eq $rightProperty) { return $false }
    if ($null -eq $leftProperty.Value -or $null -eq $rightProperty.Value) {
      if ($null -ne $leftProperty.Value -or $null -ne $rightProperty.Value) { return $false }
    } elseif (-not [string]::Equals(
        [string]$leftProperty.Value,
        [string]$rightProperty.Value,
        [StringComparison]::Ordinal
      )) {
      return $false
    }
  }
  return $true
}

function Get-ValidatedFleetAdmissionRecord(
  [string]$RuntimeRoot,
  [int]$MaxRecordBytes = 65536
) {
  try {
    $paths = Get-FleetAdmissionPaths $RuntimeRoot
    if (-not (Test-FleetAdmissionSafeItem $paths.directory $true)) { return $null }
    $children = @(Get-ChildItem -LiteralPath $paths.directory -Force -ErrorAction Stop)
    if ($children.Count -ne 1 -or
        -not [string]::Equals($children[0].Name, $script:FleetAdmissionRecordName, [StringComparison]::Ordinal) -or
        -not (Test-FleetAdmissionSafeItem $paths.record $false) -or
        $children[0].Length -le 0 -or $children[0].Length -gt $MaxRecordBytes) {
      return $null
    }
    $record = ConvertFrom-DispatchOwnershipJson ([IO.File]::ReadAllText(
      $paths.record, [Text.Encoding]::UTF8
    ))
    $names = @(Get-FleetAdmissionPropertyNames)
    $actual = @($record.PSObject.Properties.Name)
    if ($actual.Count -ne $names.Count) { return $null }
    foreach ($name in $names) {
      if ($actual -cnotcontains $name) { return $null }
    }
    if ($record.schemaVersion -isnot [string] -or
        $record.schemaVersion -cne $script:FleetAdmissionSchema -or
        $record.leaseId -isnot [string] -or
        [string]$record.leaseId -cnotmatch "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$" -or
        $record.ownerTokenSha256 -isnot [string] -or
        [string]$record.ownerTokenSha256 -cnotmatch "^[a-f0-9]{64}$" -or
        $record.leaseHolder -isnot [string] -or
        [string]$record.leaseHolder -cnotmatch "^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$" -or
        -not (Test-DispatchJsonInteger $record.issue 1) -or
        $record.attempt -isnot [string] -or
        [string]$record.attempt -cnotmatch "^[A-Za-z0-9][A-Za-z0-9._:-]{0,79}$" -or
        -not [string]$record.attempt.StartsWith("$([int]$record.issue)-", [StringComparison]::Ordinal) -or
        $record.host -isnot [string] -or
        [string]::IsNullOrWhiteSpace([string]$record.host) -or
        [string]$record.host -ne [string]$record.host.Trim() -or
        [string]$record.host.Length -gt 255 -or
        $record.controllerRoot -isnot [string] -or
        -not (Test-DispatchFullyQualifiedPath ([string]$record.controllerRoot)) -or
        $record.controllerRuntimeRoot -isnot [string] -or
        -not (Test-DispatchFullyQualifiedPath ([string]$record.controllerRuntimeRoot)) -or
        $record.controllerHead -isnot [string] -or
        [string]$record.controllerHead -cnotmatch "^[a-f0-9]{40}$" -or
        -not (Test-DispatchJsonInteger $record.holderPid 1) -or
        -not (Test-DispatchUtcRoundTripIdentity $record.holderStartIdentity) -or
        -not (Test-DispatchUtcRoundTripIdentity $record.recordedAt) -or
        $record.state -isnot [string] -or
        [string]$record.state -notin @("claiming", "running") -or
        $record.worktree -isnot [string] -or
        -not (Test-DispatchFullyQualifiedPath ([string]$record.worktree)) -or
        $record.branch -isnot [string] -or
        [string]::IsNullOrWhiteSpace([string]$record.branch) -or
        [string]$record.branch -ne [string]$record.branch.Trim() -or
        [string]$record.branch.Length -gt 512 -or
        $record.claimedHead -isnot [string] -or
        [string]$record.claimedHead -cnotmatch "^[a-f0-9]{40}$" -or
        $record.gate -isnot [string] -or
        [string]$record.gate -notin $script:FleetAdmissionGates) {
      return $null
    }
    if ([string]$record.state -ceq "claiming") {
      if ($null -ne $record.childPid -or $null -ne $record.childStartIdentity) { return $null }
    } elseif (-not (Test-DispatchJsonInteger $record.childPid 1) -or
        -not (Test-DispatchUtcRoundTripIdentity $record.childStartIdentity)) {
      return $null
    }
    if (-not (Test-DispatchSamePath ([string]$record.controllerRuntimeRoot) $paths.runtime) -or
        -not (Test-DispatchSamePath ([string]$record.controllerRoot) (Split-Path -Parent $paths.runtime))) {
      return $null
    }
    return $record
  } catch {
    return $null
  }
}

function Write-FleetAdmissionRecord([string]$RecordPath, $Record, [switch]$CreateNew) {
  $bytes = [Text.UTF8Encoding]::new($false).GetBytes(
    ($Record | ConvertTo-Json -Depth 4 -Compress)
  )
  if ($CreateNew) {
    $stream = [IO.File]::Open(
      $RecordPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None
    )
    try {
      $stream.Write($bytes, 0, $bytes.Length)
      $stream.Flush($true)
    } finally {
      $stream.Dispose()
    }
    return
  }
  $temporary = "$RecordPath.$([guid]::NewGuid().ToString('N')).tmp"
  $backup = $null
  try {
    $stream = [IO.File]::Open(
      $temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None
    )
    try {
      $stream.Write($bytes, 0, $bytes.Length)
      $stream.Flush($true)
    } finally {
      $stream.Dispose()
    }
    if ($PSVersionTable.PSEdition -ceq "Desktop") {
      $backup = "$RecordPath.$([guid]::NewGuid().ToString('N')).bak"
      [IO.File]::Replace($temporary, $RecordPath, $backup)
    } else {
      [IO.File]::Move($temporary, $RecordPath, $true)
    }
  } finally {
    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    if ($backup) { Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue }
  }
}

function Test-FleetAdmissionPossiblePendingChild($Record) {
  try {
    $recordedAt = [DateTimeOffset]::Parse([string]$Record.recordedAt).ToUniversalTime()
    $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $($Record.holderPid)" -ErrorAction Stop)
    foreach ($child in $children) {
      try {
        $createdAt = if ($child.CreationDate -is [DateTime]) {
          ([DateTime]$child.CreationDate).ToUniversalTime()
        } else {
          [Management.ManagementDateTimeConverter]::ToDateTime([string]$child.CreationDate).ToUniversalTime()
        }
        if ($createdAt.Ticks -ge $recordedAt.Ticks) { return $true }
      } catch {
        return $null
      }
    }
    return $false
  } catch {
    return $null
  }
}

function Get-FleetAdmissionObservation(
  [string]$RuntimeRoot,
  [string]$ExpectedHost = [Environment]::MachineName,
  [scriptblock]$ProcessStateResolver = {
    param($ProcessId, $StartIdentity)
    Get-DispatchProcessIdentityState ([int]$ProcessId) ([string]$StartIdentity)
  },
  [scriptblock]$PendingChildResolver = {
    param($Record)
    Test-FleetAdmissionPossiblePendingChild $Record
  },
  [datetimeoffset]$ObservedAtUtc = [datetimeoffset]::UtcNow
) {
  $paths = Get-FleetAdmissionPaths $RuntimeRoot
  if (-not (Test-Path -LiteralPath $paths.directory)) {
    return [pscustomobject]@{ status = "absent"; diagnostic = "fleet-lease-absent"; record = $null }
  }
  $record = Get-ValidatedFleetAdmissionRecord $paths.runtime
  if ($null -eq $record) {
    return [pscustomobject]@{ status = "indeterminate"; diagnostic = "fleet-lease-invalid"; record = $null }
  }
  if (-not [string]::Equals([string]$record.host, $ExpectedHost, [StringComparison]::OrdinalIgnoreCase)) {
    return [pscustomobject]@{ status = "indeterminate"; diagnostic = "foreign-host-fleet-lease"; record = $record }
  }
  $recordedAt = [DateTimeOffset]::Parse([string]$record.recordedAt).ToUniversalTime()
  if ($recordedAt -gt $ObservedAtUtc.ToUniversalTime().AddMinutes(5)) {
    return [pscustomobject]@{ status = "indeterminate"; diagnostic = "fleet-lease-clock-skew"; record = $record }
  }
  try { $holderState = & $ProcessStateResolver $record.holderPid $record.holderStartIdentity } catch { $holderState = "ambiguous" }
  if ($holderState -notin @("live", "dead", "ambiguous")) { $holderState = "ambiguous" }
  $childState = if ([string]$record.state -ceq "running") {
    try { & $ProcessStateResolver $record.childPid $record.childStartIdentity } catch { "ambiguous" }
  } else {
    "absent"
  }
  if ($childState -notin @("live", "dead", "ambiguous", "absent")) { $childState = "ambiguous" }
  try { $pendingChild = & $PendingChildResolver $record } catch { $pendingChild = $null }
  $reclaimable = $holderState -ceq "dead" -and
    $childState -in @("dead", "absent") -and $pendingChild -eq $false
  [pscustomobject]@{
    status = $(if ($reclaimable) { "proven-dead" } else { "occupied" })
    diagnostic = $(if ($reclaimable) { "fleet-lease-owner-proven-dead" } else { "fleet-lease-owner-not-proven-dead" })
    record = $record
    holderState = $holderState
    childState = $childState
    pendingChild = $pendingChild
    reclaimable = $reclaimable
  }
}

function Remove-FleetAdmissionRecordExact([string]$RuntimeRoot, $ExpectedRecord) {
  try {
    $paths = Get-FleetAdmissionPaths $RuntimeRoot
    $current = Get-ValidatedFleetAdmissionRecord $paths.runtime
    if (-not (Test-FleetAdmissionRecordExact $current $ExpectedRecord)) { return $false }
    $children = @(Get-ChildItem -LiteralPath $paths.directory -Force -ErrorAction Stop)
    if ($children.Count -ne 1 -or
        -not [string]::Equals($children[0].Name, $script:FleetAdmissionRecordName, [StringComparison]::Ordinal) -or
        -not (Test-FleetAdmissionSafeItem $paths.record $false)) { return $false }
    Remove-Item -LiteralPath $paths.record -Force -ErrorAction Stop
    [IO.Directory]::Delete($paths.directory, $false)
    return -not (Test-Path -LiteralPath $paths.directory)
  } catch {
    return $false
  }
}

function Enter-FleetExclusiveAdmission {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$RuntimeRoot,
    [Parameter(Mandatory)][string]$LeaseHolder,
    [Parameter(Mandatory)][int]$Issue,
    [Parameter(Mandatory)][string]$Attempt,
    [Parameter(Mandatory)][string]$ControllerRoot,
    [Parameter(Mandatory)][string]$ControllerHead,
    [Parameter(Mandatory)][string]$Worktree,
    [Parameter(Mandatory)][string]$Branch,
    [Parameter(Mandatory)][string]$ClaimedHead,
    [Parameter(Mandatory)][string]$Gate,
    [string]$HostIdentity = [Environment]::MachineName,
    [scriptblock]$ProcessStateResolver = {
      param($ProcessId, $StartIdentity)
      Get-DispatchProcessIdentityState ([int]$ProcessId) ([string]$StartIdentity)
    },
    [scriptblock]$PendingChildResolver = {
      param($Record)
      Test-FleetAdmissionPossiblePendingChild $Record
    },
    [scriptblock]$BeforeReclaim,
    [datetimeoffset]$ObservedAtUtc = [datetimeoffset]::UtcNow
  )
  if ($Issue -le 0 -or $LeaseHolder -cnotmatch "^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$" -or
      $Attempt -cnotmatch "^[A-Za-z0-9][A-Za-z0-9._:-]{0,79}$" -or
      -not $Attempt.StartsWith("$Issue-", [StringComparison]::Ordinal) -or
      $ControllerHead -cnotmatch "^[a-f0-9]{40}$" -or
      $ClaimedHead -cnotmatch "^[a-f0-9]{40}$" -or
      $Gate -notin $script:FleetAdmissionGates -or
      [string]::IsNullOrWhiteSpace($HostIdentity)) {
    throw "ADMISSION_DENIED: fleet claimant identity is invalid"
  }
  $paths = Get-FleetAdmissionPaths $RuntimeRoot
  $controllerCanonical = Get-DispatchCanonicalExistingPath $ControllerRoot
  $worktreeCanonical = Get-DispatchCanonicalExistingPath $Worktree
  if ([string]::IsNullOrWhiteSpace($controllerCanonical) -or
      [string]::IsNullOrWhiteSpace($worktreeCanonical) -or
      -not (Test-DispatchSamePath $controllerCanonical (Split-Path -Parent $paths.runtime))) {
    throw "ADMISSION_DENIED: fleet claimant roots are invalid"
  }

  if (Test-Path -LiteralPath $paths.directory) {
    $observation = Get-FleetAdmissionObservation $paths.runtime $HostIdentity `
      $ProcessStateResolver $PendingChildResolver $ObservedAtUtc
    if ($observation.status -cne "proven-dead") {
      throw "ADMISSION_DENIED: $($observation.diagnostic)"
    }
    if ($BeforeReclaim) { & $BeforeReclaim $observation.record $paths.directory }
    $reread = Get-FleetAdmissionObservation $paths.runtime $HostIdentity `
      $ProcessStateResolver $PendingChildResolver $ObservedAtUtc
    if ($reread.status -cne "proven-dead" -or
        -not (Test-FleetAdmissionRecordExact $reread.record $observation.record) -or
        -not (Remove-FleetAdmissionRecordExact $paths.runtime $observation.record)) {
      throw "ADMISSION_DENIED: fleet lease changed after proven-dead validation"
    }
  }

  try {
    New-Item -ItemType Directory -Path $paths.directory -ErrorAction Stop | Out-Null
  } catch {
    throw "ADMISSION_DENIED: fleet lease acquisition collision"
  }
  $tokenBytes = [byte[]]::new(32)
  [Security.Cryptography.RandomNumberGenerator]::Fill($tokenBytes)
  $token = [Convert]::ToHexString($tokenBytes).ToLowerInvariant()
  $holderStart = Get-DispatchProcessStartIdentity $PID
  if (-not $holderStart) {
    try { [IO.Directory]::Delete($paths.directory, $false) } catch {}
    throw "ADMISSION_RESIDUE: fleet holder process identity is unavailable"
  }
  $record = [ordered]@{
    schemaVersion = $script:FleetAdmissionSchema
    leaseId = [guid]::NewGuid().ToString()
    ownerTokenSha256 = Get-FleetAdmissionSha256 ([Text.Encoding]::UTF8.GetBytes($token))
    leaseHolder = $LeaseHolder
    issue = $Issue
    attempt = $Attempt
    host = $HostIdentity
    controllerRoot = $controllerCanonical
    controllerRuntimeRoot = $paths.runtime
    controllerHead = $ControllerHead
    holderPid = $PID
    holderStartIdentity = $holderStart
    recordedAt = [DateTime]::UtcNow.ToString("o")
    state = "claiming"
    childPid = $null
    childStartIdentity = $null
    worktree = $worktreeCanonical
    branch = $Branch
    claimedHead = $ClaimedHead
    gate = $Gate
  }
  try {
    Write-FleetAdmissionRecord $paths.record $record -CreateNew
    $validated = Get-ValidatedFleetAdmissionRecord $paths.runtime
    if (-not (Test-FleetAdmissionRecordExact $validated ([pscustomobject]$record))) {
      throw "fleet record readback mismatch"
    }
  } catch {
    try {
      Remove-Item -LiteralPath $paths.record -Force -ErrorAction SilentlyContinue
      [IO.Directory]::Delete($paths.directory, $false)
    } catch {}
    if (Test-Path -LiteralPath $paths.directory) {
      throw "ADMISSION_RESIDUE: fleet lease publication failed and residue survived"
    }
    throw "ADMISSION_DENIED: fleet lease publication failed"
  }
  [pscustomobject]@{
    runtimeRoot = $paths.runtime
    directory = $paths.directory
    recordPath = $paths.record
    token = $token
    record = [pscustomobject]$record
  }
}

function Set-FleetExclusiveAdmissionChild(
  [Parameter(Mandatory)]$Owner,
  [Parameter(Mandatory)][int]$ChildPid,
  [Parameter(Mandatory)][string]$ChildStartIdentity
) {
  if ($ChildPid -le 0 -or -not (Test-DispatchUtcRoundTripIdentity $ChildStartIdentity)) {
    throw "ADMISSION_RESIDUE: verifier child identity is invalid"
  }
  $current = Get-ValidatedFleetAdmissionRecord $Owner.runtimeRoot
  if (-not (Test-FleetAdmissionRecordExact $current $Owner.record)) {
    throw "ADMISSION_RESIDUE: fleet lease changed before verifier child publication"
  }
  $updated = [ordered]@{}
  foreach ($property in $Owner.record.PSObject.Properties) {
    $updated[$property.Name] = $property.Value
  }
  $updated.state = "running"
  $updated.childPid = $ChildPid
  $updated.childStartIdentity = $ChildStartIdentity
  Write-FleetAdmissionRecord $Owner.recordPath $updated
  $validated = Get-ValidatedFleetAdmissionRecord $Owner.runtimeRoot
  if (-not (Test-FleetAdmissionRecordExact $validated ([pscustomobject]$updated))) {
    throw "ADMISSION_RESIDUE: verifier child publication readback failed"
  }
  $Owner.record = [pscustomobject]$updated
  return $Owner
}

function Exit-FleetExclusiveAdmission([Parameter(Mandatory)]$Owner) {
  Remove-FleetAdmissionRecordExact $Owner.runtimeRoot $Owner.record
}

function Assert-FleetExclusiveLeaseVacantForDispatch {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$RuntimeRoot,
    [string]$ExpectedHost = [Environment]::MachineName
  )
  $observation = Get-FleetAdmissionObservation $RuntimeRoot $ExpectedHost
  if ($observation.status -cne "absent") {
    throw "ADMISSION_DENIED: $($observation.diagnostic)"
  }
}

function Assert-FleetExclusiveLaneCensusVacant {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$RuntimeRoot,
    [Parameter(Mandatory)][string]$TempRoot,
    [Parameter(Mandatory)][string]$ContainerRoot,
    [int]$MaxRecords = 64,
    [int]$DeadlineMs = 5000,
    [scriptblock]$CensusResolver = {
      param($Runtime, $Temp, $Container, $Cap, $Deadline)
      Get-LiveDispatchOwnership $Runtime $Temp $Container -MaxRecords $Cap -DeadlineMs $Deadline
    }
  )
  $census = & $CensusResolver $RuntimeRoot $TempRoot $ContainerRoot $MaxRecords $DeadlineMs
  if ($null -eq $census -or $null -eq $census.health -or $null -eq $census.health.counts) {
    throw "ADMISSION_DENIED: lane census is absent"
  }
  $actualCountNames = if ($census.health.counts -is [Collections.IDictionary]) {
    @($census.health.counts.Keys)
  } else {
    @($census.health.counts.PSObject.Properties.Name)
  }
  if ($actualCountNames.Count -ne $script:FleetAdmissionCountNames.Count) {
    throw "ADMISSION_DENIED: lane census counter shape is invalid"
  }
  foreach ($name in $script:FleetAdmissionCountNames) {
    if ($actualCountNames -cnotcontains $name -or
        -not (Test-DispatchJsonInteger $census.health.counts.$name 0)) {
      throw "ADMISSION_DENIED: lane census counter shape is invalid"
    }
  }
  $blockingDiagnostics = @($census.health.diagnostics | Where-Object {
    (Get-LaneDiagnosticSeverity ([string]$_.code)) -ceq "blocking"
  })
  $counts = $census.health.counts
  $denied = [string]$census.health.status -cne "ok" -or
    [int]$counts.active -ne 0 -or [int]$counts.truncated -ne 0 -or
    [int]$counts.probeFailures -ne 0 -or [int]$counts.rejected -ne 0 -or
    [int]$counts.legacyLiveOwners -ne 0 -or [int]$counts.lingeringAttempts -ne 0 -or
    $blockingDiagnostics.Count -ne 0
  if ($denied) {
    $codes = @($blockingDiagnostics | ForEach-Object { [string]$_.code }) -join ","
    throw (
      "ADMISSION_DENIED: lane census status=$($census.health.status) " +
      "active=$($counts.active) truncated=$($counts.truncated) " +
      "probeFailures=$($counts.probeFailures) rejected=$($counts.rejected) " +
      "legacyLiveOwners=$($counts.legacyLiveOwners) lingeringAttempts=$($counts.lingeringAttempts) " +
      "diagnostics=$codes"
    )
  }
  return $census
}

Export-ModuleMember -Function @(
  "Get-FleetAdmissionPropertyNames",
  "Get-FleetAdmissionPaths",
  "Get-ValidatedFleetAdmissionRecord",
  "Test-FleetAdmissionRecordExact",
  "Test-FleetAdmissionPossiblePendingChild",
  "Get-FleetAdmissionObservation",
  "Enter-FleetExclusiveAdmission",
  "Set-FleetExclusiveAdmissionChild",
  "Exit-FleetExclusiveAdmission",
  "Assert-FleetExclusiveLeaseVacantForDispatch",
  "Assert-FleetExclusiveLaneCensusVacant"
)
