Set-StrictMode -Version Latest
$routingLibrary = Join-Path $PSScriptRoot 'routing-data.ps1'
if (Test-Path -LiteralPath $routingLibrary -PathType Leaf) { . $routingLibrary -Library }

function Get-OrchestrationLeaseContract {
  [CmdletBinding()]
  param()

  [pscustomobject][ordered]@{
    version = "orchestration-lease/v2"
    schemaVersion = 2
    futureClockSkewMinutes = 5
    sessionIdentity = "holder"
    requiredIdentityFields = @("holder", "harness", "model", "effort")
  }
}

function ConvertTo-OrchestrationInstant {
  param([object]$Value)

  if ($Value -isnot [string] -or
      $Value -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$') {
    return $null
  }
  $parsed = [datetimeoffset]::MinValue
  if (-not [datetimeoffset]::TryParse(
      $Value,
      [cultureinfo]::InvariantCulture,
      [Globalization.DateTimeStyles]::RoundtripKind,
      [ref]$parsed)) {
    return $null
  }
  $parsed.ToUniversalTime()
}

function Test-OrchestrationPropertySet {
  param(
    [object]$Value,
    [string[]]$Expected
  )

  if ($null -eq $Value -or $Value -isnot [psobject] -or $Value -is [string]) {
    return $false
  }
  $actual = @($Value.PSObject.Properties.Name)
  if ($actual.Count -ne $Expected.Count) { return $false }
  foreach ($name in $Expected) {
    if ($name -cnotin $actual) { return $false }
  }
  return $true
}

function Test-OrchestrationIdentity {
  param([object]$Value,[switch]$HistoricalRead)

  if ([string]$Value.holder -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$') {
    return "holder-invalid"
  }
  if ([string]$Value.harness -cnotin @("codex", "claude")) {
    return "harness-invalid"
  }
  $model = [string]$Value.model
  try {
    $data = Get-RoutingData -ReadOnly
    $effortSet = if ($HistoricalRead) { @('low','medium','high','xhigh','max','minimal') }
      else { @(Get-RoutingEffortSet -Registry $data.registry -Scope all) }
    if ([string]$Value.effort -cnotin $effortSet) { return "effort-invalid" }
    $identity = Get-RoutingModelIdentity $data.registry $model
    # v2.86 reader compatibility; this literal is never admitted for new work.
    if ($null -eq $identity -and $HistoricalRead -and $model -ceq 'gpt-5.6-terra') { return $null }
    if ($null -eq $identity) { return "host-model-invalid" }
    # Host arms are a closed policy family set; harness and model provider
    # remain independent for host identity records.
    if (-not $identity.current) {
      if ($HistoricalRead) { return $null }
      return "retired host model '$model'; historical registry identity cannot acquire or renew"
    }
    if ($identity.family -cnotin @('astra','sol','opus','fable','sonnet') -and -not $HistoricalRead) { return "host-model-invalid" }
  } catch { return "host-model-invalid" }
  return $null
}

function New-OrchestrationLeaseResult {
  param(
    [string]$Status,
    [object]$Record,
    [string[]]$Diagnostics,
    [string]$Fingerprint,
    [byte[]]$Bytes,
    [string]$PreviousHolder = $null
  )

  [pscustomobject][ordered]@{
    status = $Status
    record = $Record
    diagnostics = @($Diagnostics)
    fingerprint = $Fingerprint
    bytes = $Bytes
    previousHolder = $PreviousHolder
  }
}

function Get-OrchestrationBytesFingerprint {
  param([byte[]]$Bytes)

  if ($null -eq $Bytes) { return "missing" }
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    ([Convert]::ToHexString($sha.ComputeHash($Bytes))).ToLowerInvariant()
  } finally {
    $sha.Dispose()
  }
}

function Get-OrchestrationLeaseFileSnapshot {
  param([Parameter(Mandatory)][string]$Path)

  $fullPath = [IO.Path]::GetFullPath($Path)
  if (-not [IO.File]::Exists($fullPath)) {
    return [pscustomobject]@{
      path = $fullPath
      exists = $false
      bytes = $null
      fingerprint = "missing"
      object = $null
      parseStatus = "missing"
    }
  }

  try {
    $bytes = [IO.File]::ReadAllBytes($fullPath)
  } catch {
    return [pscustomobject]@{
      path = $fullPath
      exists = $true
      bytes = $null
      fingerprint = "unreadable"
      object = $null
      parseStatus = "unreadable"
    }
  }
  $fingerprint = Get-OrchestrationBytesFingerprint $bytes
  try {
    $encoding = [Text.UTF8Encoding]::new($false, $true)
    $text = $encoding.GetString($bytes)
    if (-not $text.Trim()) { throw "empty lease" }
    # PowerShell 7.5+ otherwise materializes ISO strings as DateTime objects,
    # erasing the exact representation that renewal must preserve byte-for-byte.
    $value = $text | ConvertFrom-Json -DateKind String -ErrorAction Stop
    return [pscustomobject]@{
      path = $fullPath
      exists = $true
      bytes = $bytes
      fingerprint = $fingerprint
      object = $value
      parseStatus = "parsed"
    }
  } catch {
    return [pscustomobject]@{
      path = $fullPath
      exists = $true
      bytes = $bytes
      fingerprint = $fingerprint
      object = $null
      parseStatus = "malformed-json"
    }
  }
}

function Resolve-OrchestrationLeaseObject {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][object]$Value,
    [datetimeoffset]$ObservedAtUtc = [datetimeoffset]::UtcNow,
    [string]$Fingerprint = "object",
    [byte[]]$Bytes = $null
  )

  $contract = Get-OrchestrationLeaseContract
  $canonicalFields = @(
    "version", "holder", "harness", "model", "effort", "acquiredAt", "renewedAt"
  )
  $isCanonical = Test-OrchestrationPropertySet $Value $canonicalFields
  if (-not $isCanonical) {
    return New-OrchestrationLeaseResult "malformed" $null @("lease-shape-invalid") $Fingerprint $Bytes
  }

  if ($isCanonical -and [string]$Value.version -cne $contract.version) {
    return New-OrchestrationLeaseResult "unsupported-version" $null @("lease-version-unsupported") $Fingerprint $Bytes
  }

  $identityProblem = Test-OrchestrationIdentity $Value -HistoricalRead
  if ($identityProblem) {
    return New-OrchestrationLeaseResult "malformed" $null @($identityProblem) $Fingerprint $Bytes
  }

  $renewedAt = ConvertTo-OrchestrationInstant $Value.renewedAt
  if ($null -eq $renewedAt) {
    return New-OrchestrationLeaseResult "malformed" $null @("renewed-at-invalid") $Fingerprint $Bytes
  }
  if ($renewedAt -gt $ObservedAtUtc.AddMinutes($contract.futureClockSkewMinutes)) {
    return New-OrchestrationLeaseResult "malformed" $null @("renewed-at-in-future") $Fingerprint $Bytes
  }

  $acquiredAt = ConvertTo-OrchestrationInstant $Value.acquiredAt
  if ($null -eq $acquiredAt) {
    return New-OrchestrationLeaseResult "malformed" $null @("acquired-at-invalid") $Fingerprint $Bytes
  }
  if ($acquiredAt -gt $renewedAt) {
    return New-OrchestrationLeaseResult "malformed" $null @("lease-time-order-invalid") $Fingerprint $Bytes
  }

  New-OrchestrationLeaseResult "ok" $Value @() $Fingerprint $Bytes
}

function Read-OrchestrationLease {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Path,
    [datetimeoffset]$ObservedAtUtc = [datetimeoffset]::UtcNow
  )

  $snapshot = Get-OrchestrationLeaseFileSnapshot $Path
  switch ($snapshot.parseStatus) {
    "missing" {
      return New-OrchestrationLeaseResult "missing" $null @("lease-missing") "missing" $null
    }
    "unreadable" {
      return New-OrchestrationLeaseResult "unreadable" $null @("lease-unreadable") "unreadable" $null
    }
    "malformed-json" {
      return New-OrchestrationLeaseResult "malformed" $null @("lease-json-malformed") $snapshot.fingerprint $snapshot.bytes
    }
    default {
      return Resolve-OrchestrationLeaseObject -Value $snapshot.object `
        -ObservedAtUtc $ObservedAtUtc -Fingerprint $snapshot.fingerprint -Bytes $snapshot.bytes
    }
  }
}

function Get-OrchestrationLeaseMutexName {
  param([Parameter(Mandatory)][string]$Path)

  $canonical = [IO.Path]::GetFullPath($Path).ToLowerInvariant()
  $bytes = [Text.Encoding]::UTF8.GetBytes($canonical)
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $suffix = [Convert]::ToHexString($sha.ComputeHash($bytes)).ToLowerInvariant()
  } finally {
    $sha.Dispose()
  }
  "Global\ChaseSetsOrchestrationLease-$suffix"
}

function Invoke-WithOrchestrationLeaseLock {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][scriptblock]$Body
  )

  $mutex = [Threading.Mutex]::new($false, (Get-OrchestrationLeaseMutexName $Path))
  $owned = $false
  try {
    try {
      $owned = $mutex.WaitOne([timespan]::FromSeconds(30))
    } catch [Threading.AbandonedMutexException] {
      $owned = $true
    }
    if (-not $owned) { throw "orchestration lease write refused: exclusive writer lock timed out" }
    & $Body
  } finally {
    if ($owned) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
  }
}

function Write-OrchestrationLeaseAtomic {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][object]$Record,
    [Parameter(Mandatory)][string]$ExpectedFingerprint,
    [scriptblock]$BeforeCommit
  )

  $fullPath = [IO.Path]::GetFullPath($Path)
  $directory = Split-Path -Parent $fullPath
  if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
    throw "orchestration lease write refused: parent directory is missing"
  }

  $json = ($Record | ConvertTo-Json -Compress -Depth 4) + "`n"
  $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
  $temporary = Join-Path $directory (".$([IO.Path]::GetFileName($fullPath)).$([guid]::NewGuid().ToString('N')).tmp")
  try {
    $stream = [IO.FileStream]::new(
      $temporary,
      [IO.FileMode]::CreateNew,
      [IO.FileAccess]::Write,
      [IO.FileShare]::None
    )
    try {
      $stream.Write($bytes, 0, $bytes.Length)
      $stream.Flush($true)
    } finally {
      $stream.Dispose()
    }

    if ($BeforeCommit) { & $BeforeCommit $fullPath $temporary }

    $current = Get-OrchestrationLeaseFileSnapshot $fullPath
    if ($current.fingerprint -cne $ExpectedFingerprint) {
      throw "orchestration lease write refused: lease changed during compare-and-write"
    }

    if ($ExpectedFingerprint -ceq "missing") {
      [IO.File]::Move($temporary, $fullPath, $false)
    } else {
      [IO.File]::Move($temporary, $fullPath, $true)
    }
  } finally {
    if (Test-Path -LiteralPath $temporary -PathType Leaf) {
      Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
  }
}

function Assert-OrchestrationLeaseIdentityArguments {
  param(
    [string]$Holder,
    [string]$Harness,
    [string]$Model,
    [string]$Effort
  )

  $probe = [pscustomobject]@{
    holder = $Holder
    harness = $Harness
    model = $Model
    effort = $Effort
  }
  $problem = Test-OrchestrationIdentity $probe
  if ($problem) { throw "orchestration lease identity refused: $problem" }
}

function Acquire-OrchestrationLease {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Holder,
    [Parameter(Mandatory)][string]$Harness,
    [Parameter(Mandatory)][string]$Model,
    [Parameter(Mandatory)][string]$Effort,
    [datetimeoffset]$NowUtc = [datetimeoffset]::UtcNow,
    [Parameter(DontShow)][scriptblock]$BeforeCommit
  )

  Assert-OrchestrationLeaseIdentityArguments $Holder $Harness $Model $Effort
  Invoke-WithOrchestrationLeaseLock -Path $Path -Body {
    $current = Read-OrchestrationLease -Path $Path -ObservedAtUtc $NowUtc
    if ($current.status -notin @("missing", "ok")) {
      throw "orchestration lease acquisition refused: lease status=$($current.status) diagnostics=$($current.diagnostics -join ',')"
    }
    $previousHolder = if ($current.record) { [string]$current.record.holder } else { $null }

    $instant = $NowUtc.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
    $record = [pscustomobject][ordered]@{
      version = (Get-OrchestrationLeaseContract).version
      holder = $Holder
      harness = $Harness
      model = $Model
      effort = $Effort
      acquiredAt = $instant
      renewedAt = $instant
    }
    Write-OrchestrationLeaseAtomic -Path $Path -Record $record `
      -ExpectedFingerprint $current.fingerprint -BeforeCommit $BeforeCommit
    $written = Read-OrchestrationLease -Path $Path -ObservedAtUtc $NowUtc
    if ($written.status -ne "ok" -or
        $written.record.holder -cne $Holder -or
        $written.record.acquiredAt -cne $instant -or
        $written.record.renewedAt -cne $instant) {
      throw "orchestration lease acquisition verification failed: status=$($written.status) diagnostics=$($written.diagnostics -join ',')"
    }
    $written.previousHolder = $previousHolder
    $written
  }
}

function Renew-OrchestrationLease {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Holder,
    [Parameter(Mandatory)][string]$Harness,
    [Parameter(Mandatory)][string]$Model,
    [Parameter(Mandatory)][string]$Effort,
    [datetimeoffset]$NowUtc = [datetimeoffset]::UtcNow,
    [Parameter(DontShow)][scriptblock]$BeforeCommit
  )

  Assert-OrchestrationLeaseIdentityArguments $Holder $Harness $Model $Effort
  Invoke-WithOrchestrationLeaseLock -Path $Path -Body {
    $current = Read-OrchestrationLease -Path $Path -ObservedAtUtc $NowUtc
    if ($current.status -ne "ok") {
      throw "orchestration lease renewal refused: identity record status=$($current.status)"
    }

    $oldRenewed = ConvertTo-OrchestrationInstant $current.record.renewedAt
    $sameHolder = [string]$current.record.holder -ceq $Holder
    if ($sameHolder -and $NowUtc -le $oldRenewed) {
      throw "orchestration lease renewal refused: renewedAt must advance"
    }
    $previousHolder = [string]$current.record.holder
    $renewed = $NowUtc.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
    $record = [pscustomobject][ordered]@{
      version = (Get-OrchestrationLeaseContract).version
      holder = $Holder
      harness = $Harness
      model = $Model
      effort = $Effort
      acquiredAt = if ($sameHolder) { $current.record.acquiredAt } else { $renewed }
      renewedAt = $renewed
    }
    Write-OrchestrationLeaseAtomic -Path $Path -Record $record `
      -ExpectedFingerprint $current.fingerprint -BeforeCommit $BeforeCommit
    $written = Read-OrchestrationLease -Path $Path -ObservedAtUtc $NowUtc
    if ($written.status -ne "ok" -or
        $written.record.holder -cne $Holder -or
        $written.record.acquiredAt -cne $record.acquiredAt -or
        $written.record.renewedAt -cne $renewed) {
      throw "orchestration lease renewal verification failed: status=$($written.status) diagnostics=$($written.diagnostics -join ',')"
    }
    $written.previousHolder = $previousHolder
    $written
  }
}

Export-ModuleMember -Function @(
  "Get-OrchestrationLeaseContract",
  "Resolve-OrchestrationLeaseObject",
  "Read-OrchestrationLease",
  "Get-OrchestrationLeaseMutexName",
  "Invoke-WithOrchestrationLeaseLock",
  "Acquire-OrchestrationLease",
  "Renew-OrchestrationLease"
)
