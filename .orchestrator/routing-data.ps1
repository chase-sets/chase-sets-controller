<#
.SYNOPSIS
Resolve AgentPools policy family slots against the current model registry.
Dot-source with -Library. State and cache overrides support isolated fixtures.
#>
[CmdletBinding()]
param([string]$StateRoot,[string]$LkgPath,[switch]$Library)
$ErrorActionPreference = 'Stop'
$script:RoutingConfiguredStateRoot = $StateRoot
$script:RoutingConfiguredLkgPath = $LkgPath

function Get-RoutingStateRoot([string]$Override) {
  if ($Override) { return [IO.Path]::GetFullPath($Override) }
  if ($env:CHASE_SETS_ROUTING_DATA_ROOT) { return [IO.Path]::GetFullPath($env:CHASE_SETS_ROUTING_DATA_ROOT) }
  return 'D:\Users\ToddS\AgentPools\state'
}

function Get-RoutingLkgPath([string]$Override) {
  if ($Override) { return [IO.Path]::GetFullPath($Override) }
  if ($env:CHASE_SETS_ROUTING_LKG_PATH) { return [IO.Path]::GetFullPath($env:CHASE_SETS_ROUTING_LKG_PATH) }
  return (Join-Path $PSScriptRoot '.routing-data-lkg.json')
}

function Read-RoutingJson([string]$Path) {
  if (-not [IO.File]::Exists($Path)) { throw 'ROUTING_DATA_MISSING' }
  try { return [IO.File]::ReadAllText($Path) | ConvertFrom-Json -Depth 100 -DateKind String -ErrorAction Stop }
  catch { throw 'ROUTING_DATA_UNPARSEABLE' }
}

function Test-RoutingObject($Value) { return $null -ne $Value -and $Value -is [pscustomobject] }

function Test-RoutingStringArray($Value) {
  if ($Value -isnot [array]) { return $false }
  $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($item in $Value) {
    if ($item -isnot [string] -or [string]::IsNullOrWhiteSpace($item) -or -not $seen.Add($item)) { return $false }
  }
  return $true
}

function Convert-RoutingTimestamp($Value) {
  $parsed = [DateTimeOffset]::MinValue
  if ($Value -isnot [string] -or $Value -cnotmatch '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|[+-]\d\d:\d\d)$' -or
      -not [DateTimeOffset]::TryParse($Value,[cultureinfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed)) { throw 'REGISTRY_TIMESTAMP_INVALID' }
  return $parsed.ToUniversalTime()
}

function Assert-RoutingShape($Policy,$Registry) {
  if (-not (Test-RoutingObject $Policy) -or $Policy.format -cne 'routing-policy/v1' -or
      $Policy.generation -isnot [long] -or $Policy.generation -lt 1 -or
      $Policy.approvedBy -isnot [string] -or [string]::IsNullOrWhiteSpace($Policy.approvedBy) -or
      -not (Test-RoutingObject $Policy.rows) -or @($Policy.rows.PSObject.Properties).Count -ne 15) {
    throw 'ROUTING_DATA_INVALID_POLICY'
  }
  if (-not (Test-RoutingObject $Registry) -or $Registry.format -cne 'model-registry/v2' -or
      -not (Test-RoutingObject $Registry.source) -or -not (Test-RoutingObject $Registry.families) -or
      @($Registry.families.PSObject.Properties).Count -eq 0 -or -not (Test-RoutingObject $Registry.models) -or
      $Registry.authorityDigest -isnot [string] -or $Registry.authorityDigest -cnotmatch '^[a-zA-Z0-9._:-]{1,128}$') {
    throw 'ROUTING_DATA_INVALID_REGISTRY'
  }
  $currents = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($family in $Registry.families.PSObject.Properties) {
    $entry = $family.Value
    if (-not (Test-RoutingObject $entry) -or $entry.provider -cnotin @('codex','claude') -or
        $entry.current -isnot [string] -or $entry.current -cnotmatch '^[a-z0-9][a-z0-9.-]{1,63}$' -or
        -not $currents.Add($entry.current) -or -not (Test-RoutingStringArray $entry.historical) -or
        $entry.historical -ccontains $entry.current) { throw 'ROUTING_DATA_INVALID_REGISTRY' }
  }
  foreach ($model in $Registry.models.PSObject.Properties) {
    $entry = $model.Value
    if (-not (Test-RoutingObject $entry) -or -not (Test-RoutingStringArray $entry.admittedEfforts) -or
        @($entry.admittedEfforts | Where-Object { $_ -cnotin @('low','medium','high','xhigh','max') }).Count -gt 0 -or
        -not (Test-RoutingObject $entry.usableAccountsByEffort) -or $entry.accounts -isnot [array]) {
      throw 'ROUTING_DATA_INVALID_REGISTRY'
    }
    foreach ($effort in $entry.usableAccountsByEffort.PSObject.Properties) {
      if ($effort.Name -cnotin @('low','medium','high','xhigh','max') -or -not (Test-RoutingStringArray $effort.Value)) {
        throw 'ROUTING_DATA_INVALID_REGISTRY'
      }
      foreach ($accountId in $effort.Value) {
        $accounts = @($entry.accounts | Where-Object { $_.account -ceq $accountId })
        if ($accounts.Count -ne 1 -or $accounts[0].stale -isnot [bool] -or $accounts[0].stale -or
            $accounts[0].usable -isnot [bool] -or -not $accounts[0].usable -or
            $accounts[0].disabled -isnot [bool] -or $accounts[0].disabled -or
            $accounts[0].routing -cne 'ready' -or
            -not (Test-RoutingStringArray $accounts[0].efforts) -or $accounts[0].efforts -cnotcontains $effort.Name) {
          throw 'ROUTING_DATA_INVALID_ACCOUNT_AUTHORITY'
        }
      }
    }
  }
  foreach ($rowNumber in 1..15) {
    $row = $Policy.rows.PSObject.Properties[[string]$rowNumber]
    if ($null -eq $row -or -not (Test-RoutingObject $row.Value.slots) -or
        @($row.Value.slots.PSObject.Properties).Count -eq 0) { throw 'ROUTING_DATA_INVALID_POLICY' }
    foreach ($slot in $row.Value.slots.PSObject.Properties) {
      $config = $slot.Value
      if (-not (Test-RoutingObject $config) -or $config.family -isnot [string]) { throw 'ROUTING_DATA_INVALID_POLICY' }
      $family = $Registry.families.PSObject.Properties[[string]$config.family]
      if ($slot.Name -cnotmatch '^(codex|claude)\.(primary|fallback)$' -or -not (Test-RoutingObject $config) -or
          $config.family -isnot [string] -or $null -eq $family -or
          $family.Value.provider -cne ($slot.Name -split '\.')[0] -or
          $config.effort -cnotin @('low','medium','high','xhigh','max') -or
          $config.placement -cnotmatch '^(measured|provisional|reserve|override-[A-Za-z0-9._-]+)$') {
        throw 'ROUTING_DATA_INVALID_POLICY'
      }
    }
  }
}

function Get-RoutingFreshnessReason($Registry,[DateTimeOffset]$NowUtc) {
  try {
    $generated = Convert-RoutingTimestamp $Registry.generatedAt
    $checked = Convert-RoutingTimestamp $Registry.source.statusCheckedAt
  } catch { return 'REGISTRY_TIMESTAMP_INVALID' }
  if ($generated -gt $NowUtc.AddMinutes(5) -or $checked -gt $NowUtc.AddMinutes(5)) { return 'REGISTRY_TIMESTAMP_FUTURE' }
  if (($NowUtc - $generated).TotalHours -gt 3) { return 'REGISTRY_STALE_GENERATED_AT' }
  if (($NowUtc - $checked).TotalHours -gt 3) { return 'REGISTRY_STALE_STATUS' }
  return $null
}

function Assert-RoutingBenchmark($Benchmark) {
  if (-not (Test-RoutingObject $Benchmark) -or -not (Test-RoutingObject $Benchmark.latest) -or
      $Benchmark.latest.file -isnot [string] -or $Benchmark.latest.file -cnotmatch '^[A-Za-z0-9._-]+\.json$' -or
      -not (Test-RoutingObject $Benchmark.snapshot) -or $Benchmark.snapshot.rows -isnot [array]) {
    throw 'ROUTING_DATA_INVALID_BENCHMARK'
  }
  $keys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($row in $Benchmark.snapshot.rows) {
    if ($row.model -isnot [string] -or $row.effort -isnot [string] -or
        -not $keys.Add("$($row.model)/$($row.effort)") -or
        ($null -ne $row.usdPerTask -and ($row.usdPerTask -isnot [ValueType] -or
          [double]::IsNaN([double]$row.usdPerTask) -or [double]::IsInfinity([double]$row.usdPerTask) -or
          [double]$row.usdPerTask -lt 0))) { throw 'ROUTING_DATA_INVALID_BENCHMARK' }
  }
}

function Get-RoutingPayloadDigest($Payload) {
  $bytes = [Text.Encoding]::UTF8.GetBytes(($Payload | ConvertTo-Json -Depth 100 -Compress))
  return ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))).ToLowerInvariant()
}

function Get-RoutingData {
  [CmdletBinding()]
  param([string]$StateRoot,[string]$LkgPath,[DateTimeOffset]$NowUtc=[DateTimeOffset]::UtcNow,[switch]$ReadOnly)
  $root = Get-RoutingStateRoot $(if ($StateRoot) { $StateRoot } else { $script:RoutingConfiguredStateRoot })
  $cachePath = Get-RoutingLkgPath $(if ($LkgPath) { $LkgPath } else { $script:RoutingConfiguredLkgPath })
  $sourceReason = $null
  $usedLkg = $false
  try {
    $policy = Read-RoutingJson (Join-Path $root 'routing-policy.json')
    $registry = Read-RoutingJson (Join-Path $root 'model-registry.json')
    Assert-RoutingShape $policy $registry
    $reason = Get-RoutingFreshnessReason $registry $NowUtc
    if ($reason) { throw $reason }
    $latest = Read-RoutingJson (Join-Path $root 'benchmarks/latest.json')
    if ($latest.file -isnot [string] -or $latest.file -cnotmatch '^[A-Za-z0-9._-]+\.json$') {
      throw 'ROUTING_DATA_INVALID_BENCHMARK'
    }
    $snapshot = Read-RoutingJson (Join-Path $root "benchmarks/$($latest.file)")
    $benchmark = [pscustomobject]@{latest=$latest;snapshot=$snapshot}
    Assert-RoutingBenchmark $benchmark
    $payload = [pscustomobject][ordered]@{
      sourceRoot=$root;validatedAt=$NowUtc.ToString('o');policy=$policy;registry=$registry;benchmark=$benchmark
    }
  } catch {
    $sourceReason = $_.Exception.Message
    try {
      $cache = Read-RoutingJson $cachePath
      $payload = $cache.payload
      if ($cache.format -cne 'routing-data-lkg/v1' -or -not (Test-RoutingObject $payload) -or
          -not [string]::Equals([string]$payload.sourceRoot,$root,[StringComparison]::OrdinalIgnoreCase) -or
          $cache.sha256 -cne (Get-RoutingPayloadDigest $payload)) { throw 'ROUTING_DATA_INVALID_LKG' }
      $validatedAt = Convert-RoutingTimestamp $payload.validatedAt
      if ($validatedAt -gt $NowUtc.AddMinutes(5)) { throw 'ROUTING_DATA_INVALID_LKG' }
      Assert-RoutingShape $payload.policy $payload.registry
      Assert-RoutingBenchmark $payload.benchmark
      if (Get-RoutingFreshnessReason $payload.registry $validatedAt) { throw 'ROUTING_DATA_INVALID_LKG' }
      $currentClockReason = Get-RoutingFreshnessReason $payload.registry $NowUtc
      if ($currentClockReason -cin @('REGISTRY_TIMESTAMP_FUTURE','REGISTRY_TIMESTAMP_INVALID')) { throw 'ROUTING_DATA_INVALID_LKG' }
      $policy=$payload.policy;$registry=$payload.registry;$benchmark=$payload.benchmark
      $usedLkg = $true
    } catch { throw ('ROUTING_DATA_REFUSED:' + $sourceReason + ':NO_VALID_LKG') }
  }
  # Cache publication failure must not revive an older account authority.
  if (-not $ReadOnly -and -not $usedLkg) {
    $temporary = "$cachePath.$([guid]::NewGuid().ToString('N')).tmp"
    try {
      $cache = [ordered]@{format='routing-data-lkg/v1';payload=$payload;sha256=(Get-RoutingPayloadDigest $payload)}
      [IO.Directory]::CreateDirectory((Split-Path -Parent $cachePath)) | Out-Null
      [IO.File]::WriteAllText($temporary,($cache | ConvertTo-Json -Depth 100),[Text.UTF8Encoding]::new($false))
      [IO.File]::Move($temporary,$cachePath,$true)
    } catch { throw 'ROUTING_LKG_WRITE_FAILED' }
    finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
  }
  return [pscustomobject]@{
    policy=$policy;registry=$registry;benchmark=$benchmark;stateRoot=$root;lkgPath=$cachePath
    policyGeneration=$policy.generation;registryAuthorityDigest=$registry.authorityDigest
    usedLastKnownGood=$usedLkg;sourceReason=$sourceReason
  }
}

function Get-RoutingModelIdentity($Registry,[string]$Model) {
  foreach ($family in $Registry.families.PSObject.Properties) {
    if ($family.Value.current -ceq $Model) {
      return [pscustomobject]@{family=$family.Name;provider=$family.Value.provider;current=$true;historical=$false}
    }
  }
  foreach ($family in $Registry.families.PSObject.Properties) {
    if ($family.Value.historical -ccontains $Model) {
      return [pscustomobject]@{family=$family.Name;provider=$family.Value.provider;current=$false;historical=$true}
    }
  }
  return $null
}

function Get-RoutingAdmissionReason($Registry,[string]$Model,[string]$Effort) {
  $entry = $Registry.models.PSObject.Properties[$Model]
  if ($null -eq $entry) { return 'MODEL_NOT_IN_REGISTRY' }
  if ($entry.Value.admittedEfforts -cnotcontains $Effort) { return 'EFFORT_NOT_ADMITTED' }
  $accounts = $entry.Value.usableAccountsByEffort.PSObject.Properties[$Effort]
  if ($null -eq $accounts -or @($accounts.Value).Count -eq 0) { return 'REGISTRY_NO_USABLE_ACCOUNTS' }
  return $null
}

function Get-RoutingModelSet {
  # Roster membership is for identity readers, not dispatch admission. Call
  # Resolve-RoutingSelection before starting work, even for a current ID.
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]$Registry,
    [ValidateSet('current','historical','all')][string]$Scope='all',
    [ValidateSet('codex','claude')][string]$Harness
  )
  $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($family in $Registry.families.PSObject.Properties) {
    if ($Harness -and $family.Value.provider -cne $Harness) { continue }
    if ($Scope -cne 'historical') { [void]$seen.Add([string]$family.Value.current) }
    if ($Scope -cne 'current') {
      foreach ($model in @($family.Value.historical)) { [void]$seen.Add([string]$model) }
    }
  }
  return @($seen | Sort-Object -CaseSensitive)
}

function Get-RoutingEffortSet {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]$Registry,
    [ValidateSet('current','historical','all')][string]$Scope='all'
  )
  $models = @(Get-RoutingModelSet -Registry $Registry -Scope $Scope)
  $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($model in $models) {
    $entry = $Registry.models.PSObject.Properties[[string]$model]
    if ($null -eq $entry) { continue }
    foreach ($effort in @($entry.Value.admittedEfforts)) {
      if ($effort) { [void]$seen.Add([string]$effort) }
    }
  }
  return @($seen | Sort-Object -CaseSensitive)
}

function Get-RoutingBenchmarkPrice($Data,[string]$Model,[string]$Effort) {
  $rows = @($Data.benchmark.snapshot.rows | Where-Object { $_.model -ceq $Model -and $_.effort -ceq $Effort })
  if ($rows.Count -ne 1) { return $null }
  return [pscustomobject]@{usdPerTask=$rows[0].usdPerTask;pricing=$rows[0].pricing;snapshot=$Data.benchmark.latest.file}
}

function Resolve-RoutingSelection {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][ValidateRange(0,15)][int]$Row,
    [Parameter(Mandatory)][ValidateSet('codex','claude')][string]$Harness,
    [string]$Slot,[string]$Model,[string]$Effort,[string]$ExcludeFamily,
    [string]$StateRoot,[string]$LkgPath,[DateTimeOffset]$NowUtc=[DateTimeOffset]::UtcNow,[switch]$ReadOnly
  )
  $data = Get-RoutingData -StateRoot $StateRoot -LkgPath $LkgPath -NowUtc $NowUtc -ReadOnly:$ReadOnly
  if ([bool]$Model -ne [bool]$Effort) { throw 'ROUTING_EXPLICIT_INCOMPLETE' }
  if ($Row -eq 0 -and -not $Model) { throw 'ROUTING_ROW_REQUIRED' }
  $slots = if ($Row -gt 0) { $data.policy.rows.PSObject.Properties[[string]$Row].Value.slots } else { $null }
  $resolvedSlot = $null
  $placement = $null
  if ($Model) {
    $identity = Get-RoutingModelIdentity $data.registry $Model
    if ($null -eq $identity) { throw 'EXPLICIT_MODEL_NOT_CURRENT' }
    if (-not $identity.current) { throw 'EXPLICIT_HISTORICAL_OR_RETIRED_MODEL' }
    if ($identity.provider -cne $Harness) { throw 'MODEL_HARNESS_MISMATCH' }
    $reason = Get-RoutingAdmissionReason $data.registry $Model $Effort
    if ($reason) { throw $reason }
    $family = $identity.family
    $resolvedSlot = 'explicit'
    $matching = if ($slots) { @($slots.PSObject.Properties | Where-Object {
      $_.Value.family -ceq $family -and $_.Value.effort -ceq $Effort
    } | Select-Object -First 1) } else { @() }
    if ($matching.Count -eq 1) { $placement = $matching[0].Value.placement }
  } else {
    if ($Slot -and ($Slot -cnotmatch '^(codex|claude)\.(primary|fallback)$' -or $null -eq $slots.PSObject.Properties[$Slot])) {
      throw 'ROUTING_SLOT_NOT_DEFINED'
    }
    $preferred = if ($Slot) { $Slot } elseif ($slots.PSObject.Properties["$Harness.primary"]) { "$Harness.primary" } else { "$Harness.fallback" }
    $candidates = @($slots.PSObject.Properties | Where-Object {
      $_.Value.family -cne $ExcludeFamily
    } | Sort-Object {
      if ($_.Name -ceq $preferred) { 0 } elseif ($_.Name -ceq "$Harness.fallback") { 1 }
      elseif ($_.Name -like '*.fallback') { 2 } else { 3 }
    })
    $failures = [Collections.Generic.List[string]]::new()
    foreach ($candidate in $candidates) {
      $candidateModel = [string]$data.registry.families.PSObject.Properties[[string]$candidate.Value.family].Value.current
      $reason = Get-RoutingAdmissionReason $data.registry $candidateModel ([string]$candidate.Value.effort)
      if ($reason) { $failures.Add($reason); continue }
      $Model=$candidateModel;$Effort=[string]$candidate.Value.effort
      $family=[string]$candidate.Value.family;$resolvedSlot=$candidate.Name
      $Harness=($candidate.Name -split '\.')[0];$placement=[string]$candidate.Value.placement
      break
    }
    if (-not $resolvedSlot) {
      if ($failures -ccontains 'REGISTRY_NO_USABLE_ACCOUNTS') { throw 'REGISTRY_NO_USABLE_ACCOUNTS' }
      throw 'NO_QUALIFIED_FALLBACK'
    }
  }
  $price = Get-RoutingBenchmarkPrice $data $Model $Effort
  return [pscustomobject]@{
    model=$Model;effort=$Effort;harness=$Harness;row=$Row;family=$family;slot=$resolvedSlot;placement=$placement
    policyGeneration=$data.policyGeneration;registryAuthorityDigest=$data.registryAuthorityDigest
    usedLastKnownGood=$data.usedLastKnownGood;sourceReason=$data.sourceReason
    expectedUsdPerTask=$(if ($price) { $price.usdPerTask } else { $null })
  }
}

if (-not $Library) {
  Get-RoutingData -StateRoot $StateRoot -LkgPath $LkgPath -ReadOnly |
    Select-Object policyGeneration,registryAuthorityDigest,usedLastKnownGood,sourceReason,lkgPath |
    ConvertTo-Json -Compress
}
