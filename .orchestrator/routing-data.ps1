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

function Get-CapacityForecast {
  param([string]$StateRoot,[DateTimeOffset]$NowUtc=[DateTimeOffset]::UtcNow)
  $result=[pscustomobject]@{status='absent';forecast=$null;bytes=$null}
  $path=Join-Path (Get-RoutingStateRoot $StateRoot) 'capacity-forecast.json'
  try { if (-not (Test-Path -LiteralPath $path -ErrorAction Stop)) { return $result } }
  catch { $result.status='malformed';return $result }
  $result.status='malformed'
  try {
    $result.bytes=[IO.File]::ReadAllBytes($path)
    $f=[Text.UTF8Encoding]::new($false,$true).GetString($result.bytes) | ConvertFrom-Json -Depth 100 -DateKind String -NoEnumerate -ErrorAction Stop
    foreach($object in @($f,$f.providers,$f.providers.codex,$f.providers.claude,$f.balance)) {
      if ($object -is [array] -or -not (Test-RoutingObject $object)) { return $result } # CAPACITY_GUARD_OBJECT
    }
    if ($f.format -isnot [string] -or $f.format -cne 'capacity-forecast/v1' -or
        $f.mode -isnot [string] -or $f.mode -cnotin @('active','shadow') -or
        $f.decisionDigest -isnot [string] -or $f.decisionDigest -cnotmatch '^[a-f0-9]{16}$') { return $result } # CAPACITY_GUARD_HEADER
    foreach($provider in @('codex','claude')) {
      if ($f.providers.$provider.state -isnot [string] -or
          $f.providers.$provider.state -cnotin @('conserve','normal','spend','unknown')) { return $result } # CAPACITY_GUARD_STATE
    }
    if ($null -eq $f.balance.PSObject.Properties['toward'] -or
        ($null -ne $f.balance.toward -and ($f.balance.toward -isnot [string] -or $f.balance.toward -cnotin @('codex','claude'))) -or
        $f.balance.steps -isnot [long] -or $f.balance.steps -lt 0 -or $f.balance.steps -gt 4) { return $result } # CAPACITY_GUARD_BALANCE
    $generated=Convert-RoutingTimestamp $f.generatedAt
    $expires=Convert-RoutingTimestamp $f.staleAfter
    if ($generated -gt $NowUtc -or $expires -le $generated -or ($expires-$generated).TotalMinutes -gt 15) { return $result } # CAPACITY_GUARD_DURATION
    if ($NowUtc -ge $expires) { $result.status='stale'; return $result } # CAPACITY_GUARD_STALE
    if ($f.providers.codex.state -ceq 'unknown' -or $f.providers.claude.state -ceq 'unknown') { $result.status='unknown'; return $result } # CAPACITY_GUARD_UNKNOWN
    $result.status=if($f.mode -ceq 'active'){'in-force'}else{'shadow'}
    $result.forecast=$f
  } catch { $result.status='malformed' }
  return $result
}

# Multi-issue lanes can record authorship only in per-issue lifecycle rows.
# Unattributed model-bearing lifecycle rows remain unknown, not nonauthors.
$script:CapacityLifecycleKinds=@('review-complete','verify-complete','lane-blocked','landed','enqueue','lane-complete','stall','note',
  'bookkeeping','decision-filed','decision-resolved','deploy-verified','rule-change','gc','breaker-open','breaker-clear','escaped-defect',
  'dequeue','landing-stall','scale','review-gate-complete','re-verify-complete','repair-round-1-complete')

function Get-CapacityAuthorArtifact($Entry) {
  # 'code': the branch's implementation authorship; 'brief': the issue's
  # planning authorship; 'legacy': a role-less repair that cannot be split
  # (code for the code artifact, unknown for the brief artifact); $null: no
  # authorship; 'unknown': an unrecognized shape that fails closed.
  if (-not $Entry.kind) { return 'unknown' }
  $role=if ($null -ne $Entry.PSObject.Properties['laneRole']) { $Entry.laneRole } else { $null }
  $roleless=$null -eq $role -or $role -ceq ''
  # planning-repair/v1 plus completed in-body/in-place shapes in the canonical
  # census. REPAIR_REQUIRED and authorization/start/checkpoint prose are not repairs.
  $repaired=$Entry.outcome -is [string] -and (
    $Entry.outcome -cmatch '^(REPAIR_IN_PLACE|REPAIRED|REPLACED)($|[_ ])' -or
    $Entry.outcome -cmatch '_REPAIRED_IN_BODY$' -or
    $Entry.outcome -cin @('BLOCK_FIXABLE_REPAIRED','REPLAN_REPLACED','ISSUE_BODIES_REPAIRED',
      'COMPILE_REPAIRED','PLANNING_REPAIR_COMPLETE','SOURCE_REPAIRED_REVIEW_PENDING'))
  if ($Entry.kind -ceq 'dispatch') {
    if ($role -ceq 'implementation') { return 'code' }
    if ($role -ceq 'planning') { return 'brief' }
    if ($role -ceq 'review') { return $null }
    if ($roleless) { if ($Entry.authorModel) { return $null } else { return 'code' } }
    return 'unknown'
  }
  if ($Entry.kind -cin @('repair-complete','repair-start','continuation')) {
    # A model-less repair row is host bookkeeping; its authorship reaches the
    # history through the linked dispatch or receipt rows.
    if ($null -eq $Entry.PSObject.Properties['model'] -or $null -eq $Entry.model) { return $null }
    if ($role -ceq 'implementation') { return 'code' }
    if ($role -ceq 'planning') { return 'brief' }
    if ($role -ceq 'review' -and $null -ne $Entry.PSObject.Properties['reviewerPatch'] -and $Entry.reviewerPatch -isnot [bool]) { return 'unknown' }
    if (($roleless -or $role -ceq 'review') -and $repaired) {
      if (($Entry.pr -is [int] -or $Entry.pr -is [long]) -and $Entry.pr -gt 0) { return 'code' }
      return 'brief'
    }
    if ($role -ceq 'review') {
      if ($Entry.pr) { return 'code' }
      if ($Entry.reviewerPatch -eq $true) { return 'brief' }
      return 'unknown'
    }
    if ($roleless) { if ($Entry.pr) { return 'code' } else { return 'legacy' } }
    return 'unknown'
  }
  if ($Entry.kind -cin $script:CapacityLifecycleKinds) {
    if ($null -eq $Entry.PSObject.Properties['model'] -or $null -eq $Entry.model) { return $null }
    $planningReceipt=$Entry.kind -ceq 'review-complete' -and ($role -ceq 'planning' -or $Entry.planningContract)
    if ($role -ceq 'implementation') { return 'code' } # CAPACITY_LIFECYCLE_CODE
    if ($role -ceq 'planning' -and -not $planningReceipt) { return 'brief' } # CAPACITY_LIFECYCLE_BRIEF
    if (-not $roleless -and $role -cne 'review' -and -not $planningReceipt) { return 'unknown' }
    if ($repaired) {
      if (($Entry.pr -is [int] -or $Entry.pr -is [long]) -and $Entry.pr -gt 0) { return 'code' }
      return 'brief'
    }
    if ($Entry.kind -ceq 'review-complete' -and $Entry.reviewerPatch -ceq $true) { return $null }
    return 'lifecycle'
  }
  if ($null -ne $Entry.PSObject.Properties['model'] -and $null -ne $Entry.model) { return 'unknown' }
  return $null
}

function Get-CapacityReceiptArtifact($Entry) {
  # The artifact a review receipt (or legacy author-naming dispatch) speaks for.
  if ($Entry.planningContract -or $Entry.laneRole -ceq 'planning') { return 'brief' }
  if ($Entry.reviewContract -or $Entry.laneRole -ceq 'review' -or $Entry.pr -or $Entry.controllerReviewSchema -or $Entry.kind -ceq 'dispatch') { return 'code' }
  return 'legacy'
}

# The producer and the history reader share this boundary. Only explicit,
# earlier, validated attribution edges are followed; ordinary issue links keep
# their existing isolation. Raw identities exclude the JSONL line terminator.
function Get-BriefRawSha256([string]$Text) {
  return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text))).ToLowerInvariant()
}

function Assert-BriefObject($Value,[string[]]$Fields) {
  if (-not (Test-RoutingObject $Value) -or @($Value.PSObject.Properties).Count -ne $Fields.Count) { throw 'BRIEF_ATTRIBUTION_INVALID: object shape' }
  foreach($p in $Value.PSObject.Properties) { if ($p.Name -cnotin $Fields) { throw 'BRIEF_ATTRIBUTION_INVALID: unknown field' } }
}

function Assert-BriefString($Value,[string]$Pattern='^[^\s\x00-\x1f]{1,256}$') {
  if ($Value -isnot [string] -or $Value -cnotmatch $Pattern) { throw 'BRIEF_ATTRIBUTION_INVALID: string' }
}

function Assert-BriefJsonMembers($Element) {
  if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
    $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($p in $Element.EnumerateObject()) {
      if (-not $names.Add($p.Name)) { throw 'BRIEF_ATTRIBUTION_INVALID: duplicate field' }
      Assert-BriefJsonMembers $p.Value
    }
  } elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
    foreach($item in $Element.EnumerateArray()) { Assert-BriefJsonMembers $item }
  }
}

function ConvertFrom-BriefJson([string]$Text) {
  try {
    $doc=[Text.Json.JsonDocument]::Parse($Text)
    try { Assert-BriefJsonMembers $doc.RootElement } finally { $doc.Dispose() }
    return ConvertFrom-Json -InputObject $Text -DateKind String -Depth 100 -NoEnumerate
  } catch { throw "BRIEF_ATTRIBUTION_INVALID: $($_.Exception.Message)" }
}

function Assert-BriefTarget($Target) {
  Assert-BriefObject $Target @('issue','artifact','revision','bodySha256','observedAt')
  if (($Target.issue -isnot [long] -and $Target.issue -isnot [int]) -or $Target.issue -lt 1 -or $Target.issue -gt [int]::MaxValue) { throw 'BRIEF_ATTRIBUTION_INVALID: issue' }
  foreach($name in @('artifact','revision')) { Assert-BriefString $Target.$name }
  Assert-BriefString $Target.bodySha256 '^[a-f0-9]{64}$'
  [void](Convert-RoutingTimestamp $Target.observedAt)
}

function Get-BriefEffort($Row) {
  if ($Row.effortUsed) { return $Row.effortUsed }
  if ($Row.effort) { return $Row.effort }
  return $null
}

function Test-BriefAuthorMatch($Left,$Right) {
  foreach($name in @('issue','attemptId','dispatchRawSha256','evidenceRawSha256','model','effort')) {
    if ($Left.$name -cne $Right.$name) { return $false }
  }
  return $true
}

function Get-BriefBoundRow($Index,$Hash,[int]$Before,[DateTimeOffset]$At) {
  Assert-BriefString $Hash '^[a-f0-9]{64}$'
  if (-not $Index.ContainsKey($Hash) -or $Index[$Hash].Count -ne 1) { throw 'BRIEF_ATTRIBUTION_INVALID: missing or ambiguous row' }
  $bound=$Index[$Hash][0]
  if ($bound.id -ge $Before -or (Convert-RoutingTimestamp $bound.value.ts) -gt $At -or
      $bound.value.partial -eq $true -or $bound.value.truncated -eq $true -or $bound.value.historyComplete -eq $false) { throw 'BRIEF_ATTRIBUTION_INVALID: noncausal or partial row' }
  return $bound
}

function Assert-BriefAuthor($Author,$Index,[int]$Before,[DateTimeOffset]$At,$Registry) {
  Assert-BriefObject $Author @('issue','attemptId','dispatchRawSha256','evidenceRawSha256','model','effort')
  if (($Author.issue -isnot [long] -and $Author.issue -isnot [int]) -or $Author.issue -lt 1 -or $Author.issue -gt [int]::MaxValue) { throw 'BRIEF_ATTRIBUTION_INVALID: author issue' }
  Assert-BriefString $Author.attemptId
  Assert-BriefString $Author.model
  if (-not (Get-RoutingModelIdentity $Registry $Author.model)) { throw 'BRIEF_ATTRIBUTION_INVALID: model' }
  if ($null -ne $Author.effort) { Assert-BriefString $Author.effort '^(low|medium|high|xhigh|max|minimal)$' }
  $dispatch=Get-BriefBoundRow $Index $Author.dispatchRawSha256 $Before $At
  $evidence=Get-BriefBoundRow $Index $Author.evidenceRawSha256 $Before $At
  $d=$dispatch.value;$e=$evidence.value
  foreach($source in @($d,$e)) {
    if (($source.issue -isnot [int] -and $source.issue -isnot [long]) -or $source.issue -lt 1) { throw 'BRIEF_ATTRIBUTION_INVALID: source issue type' }
  }
  if ($d.kind -cne 'dispatch' -or $d.issue -ne $Author.issue -or $d.attemptId -cne $Author.attemptId -or
      $d.model -cne $Author.model -or $e.issue -ne $Author.issue -or $e.model -cne $Author.model -or
      $dispatch.id -gt $evidence.id -or (Convert-RoutingTimestamp $d.ts) -gt (Convert-RoutingTimestamp $e.ts) -or
      (Get-BriefEffort $e) -cne $Author.effort) { throw 'BRIEF_ATTRIBUTION_INVALID: author binding' }
  if ($evidence.id -ne $dispatch.id -and $e.attemptId -cne $Author.attemptId -and
      $e.lane -cne $Author.attemptId -and (-not $d.transcript -or $e.transcript -cne $d.transcript)) { throw 'BRIEF_ATTRIBUTION_INVALID: evidence attempt' }
  # A second dispatch cannot silently redefine an attempt, even at another effort.
  foreach($matches in $Index.Values) { foreach($row in $matches) {
    if ($row.id -lt $Before -and $row.value.kind -ceq 'dispatch' -and $row.value.issue -eq $Author.issue -and
        $row.value.attemptId -ceq $Author.attemptId -and $row.id -ne $dispatch.id) { throw 'BRIEF_ATTRIBUTION_INVALID: ambiguous attempt' }
  } }
}

function Get-BriefAttributionProjection($Rows,$Hashes,$Registry) {
  $index=[Collections.Generic.Dictionary[string,Collections.Generic.List[object]]]::new([StringComparer]::Ordinal)
  for($i=0;$i -lt $Rows.Count;$i++) {
    $hash=$Hashes[$i]
    if (-not $index.ContainsKey($hash)) { $index[$hash]=[Collections.Generic.List[object]]::new() }
    $index[$hash].Add([pscustomobject]@{id=$i;value=$Rows[$i]})
  }
  $validated=@{};$latest=@{};$overrides=@{};$errors=@{};$eligible=@{};$stale=@{}
  for($i=0;$i -lt $Rows.Count;$i++) {
    $row=$Rows[$i]
    $present=$null -ne $row.PSObject.Properties['briefSchema'] -or $null -ne $row.PSObject.Properties['briefRevision'] -or $null -ne $row.PSObject.Properties['briefAttribution']
    if (-not $present) {
      # A completed in-body repair after the declaration needs a fresh binding.
      if ($eligible.ContainsKey([string]$row.issue) -and $row.kind -cne 'dispatch' -and (Get-CapacityAuthorArtifact $row) -ceq 'brief') {
        $stale[[string]$row.issue]=$i
      }
      continue
    }
    $issueKey=[string]$row.issue
    $eligible[$issueKey]=$true
    try {
      Assert-BriefObject $row @('ts','kind','issue','briefSchema','briefRevision','briefAttribution')
      Assert-BriefString $row.kind '^decision-resolved$'
      Assert-BriefString $row.briefSchema '^brief-attribution/v1$'
      $target=$row.briefRevision;Assert-BriefTarget $target
      if (($row.issue -isnot [int] -and $row.issue -isnot [long]) -or $row.issue -ne $target.issue) { throw 'BRIEF_ATTRIBUTION_INVALID: target issue' }
      $at=Convert-RoutingTimestamp $row.ts;$observed=Convert-RoutingTimestamp $target.observedAt
      if ($observed -gt $at) { throw 'BRIEF_ATTRIBUTION_INVALID: future target' }
      $a=$row.briefAttribution
      if ($null -eq $a) { throw 'BRIEF_ATTRIBUTION_REQUIRED' }
      Assert-BriefObject $a @('operation','originalRowSha256','authors','host','consumed','byteProof')
      Assert-BriefString $a.operation '^(publication|retrospective|participation|attestation)$'
      if ($a.authors -isnot [array] -or $a.consumed -isnot [array]) { throw 'BRIEF_ATTRIBUTION_INVALID: declaration arrays' }
      $models=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
      $artifacts=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
      [void]$artifacts.Add("$($target.issue):$($target.artifact)")
      $authorKeys=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
      foreach($author in $a.authors) {
        Assert-BriefAuthor $author $index $i $observed $Registry
        if ($author.issue -ne $target.issue) { throw 'BRIEF_ATTRIBUTION_INVALID: local author issue' }
        if (-not $authorKeys.Add($author.dispatchRawSha256+':'+$author.evidenceRawSha256)) { throw 'BRIEF_ATTRIBUTION_INVALID: duplicate author' }
        [void]$models.Add($author.model)
      }
      $original=$null
      if ($null -ne $a.originalRowSha256) {
        $original=Get-BriefBoundRow $index $a.originalRowSha256 $i $observed
        if ($null -ne $original.value.PSObject.Properties['briefSchema'] -or
            $null -ne $original.value.PSObject.Properties['briefRevision'] -or
            $null -ne $original.value.PSObject.Properties['briefAttribution']) { throw 'BRIEF_ATTRIBUTION_INVALID: original is an attribution' }
        if (($original.value.issue -isnot [int] -and $original.value.issue -isnot [long]) -or $original.value.issue -ne $target.issue) { throw 'BRIEF_ATTRIBUTION_INVALID: original issue' }
      }
      if ($a.operation -cin @('retrospective','participation') -and $null -eq $original) { throw 'BRIEF_ATTRIBUTION_INVALID: original required' }
      if ($a.operation -ceq 'attestation') {
        if ($a.authors.Count -ne 1 -or $null -ne $a.host -or $a.consumed.Count -ne 0 -or $null -ne $a.originalRowSha256) { throw 'BRIEF_ATTRIBUTION_INVALID: attestation shape' }
        Assert-BriefObject $a.byteProof @('reportSha256','bodySha256','attestorDispatchRawSha256')
        foreach($name in @('reportSha256','bodySha256','attestorDispatchRawSha256')) { Assert-BriefString $a.byteProof.$name '^[a-f0-9]{64}$' }
        if ($a.byteProof.bodySha256 -cne $target.bodySha256 -or $a.byteProof.attestorDispatchRawSha256 -cne $a.authors[0].dispatchRawSha256) { throw 'BRIEF_ATTRIBUTION_INVALID: attested bytes' }
      } else {
        Assert-BriefObject $a.host @('model','effort','writing')
        Assert-BriefString $a.host.model
        if ($a.host.writing -isnot [bool] -or -not (Get-RoutingModelIdentity $Registry $a.host.model)) { throw 'BRIEF_ATTRIBUTION_INVALID: host' }
        if ($null -ne $a.host.effort) { Assert-BriefString $a.host.effort '^(low|medium|high|xhigh|max|minimal)$' }
        if ($a.operation -ceq 'participation') {
          $key="$($target.issue):$($target.artifact)"
          if (-not $latest.ContainsKey($key)) { throw 'BRIEF_ATTRIBUTION_INVALID: participation target missing' }
          $current=$index[$latest[$key]][0].value.briefRevision
          if ($current.revision -cne $target.revision -or $current.bodySha256 -cne $target.bodySha256) { throw 'BRIEF_ATTRIBUTION_INVALID: participation target stale' }
          if ($a.host.writing -or $a.authors.Count -or $a.consumed.Count -or $null -ne $a.byteProof -or
              (Get-CapacityAuthorArtifact $original.value) -cne 'lifecycle' -or $original.value.model -cne $a.host.model -or
              (Get-BriefEffort $original.value) -cne $a.host.effort) { throw 'BRIEF_ATTRIBUTION_WRITER_CONFLICT: participation' }
        } elseif ($null -ne $a.byteProof) {
          Assert-BriefObject $a.byteProof @('attestationRawSha256')
          $bound=Get-BriefBoundRow $index $a.byteProof.attestationRawSha256 $i $(if($a.operation -ceq 'retrospective'){$at}else{$observed})
          if (-not $validated.ContainsKey($a.byteProof.attestationRawSha256) -or
              $bound.value.briefAttribution.operation -cne 'attestation' -or $bound.value.briefRevision.issue -ne $target.issue -or
              $bound.value.briefRevision.bodySha256 -cne $target.bodySha256 -or $bound.value.briefRevision.artifact -cne $target.artifact -or
              (Convert-RoutingTimestamp $bound.value.briefRevision.observedAt) -gt $observed) { throw 'BRIEF_ATTRIBUTION_WRITER_CONFLICT: unbound bytes' }
          $writer=$bound.value.briefAttribution.authors[0]
          if ($a.authors.Count -ne 1 -or -not (Test-BriefAuthorMatch $a.authors[0] $writer) -or
              ($a.host.writing -and $a.host.model -cne $writer.model)) { throw 'BRIEF_ATTRIBUTION_WRITER_CONFLICT: bound writer' }
        } elseif ($a.operation -ceq 'publication') {
          if (-not $a.host.writing -or $a.authors.Count) { throw 'BRIEF_ATTRIBUTION_WRITER_CONFLICT: unmatched publication' }
        } elseif (-not $a.host.writing -and $a.authors.Count -eq 0) { throw 'BRIEF_ATTRIBUTION_WRITER_CONFLICT: retrospective writer missing' }
        if ($a.host.writing) { [void]$models.Add($a.host.model) }
      }
      if ($a.operation -ceq 'publication') {
        foreach($hash in $validated.Keys) {
          $prior=$index[$hash][0].value
          if ($prior.briefAttribution.operation -ceq 'attestation' -and $prior.briefRevision.issue -eq $target.issue -and
              $prior.briefRevision.artifact -ceq $target.artifact -and $prior.briefRevision.bodySha256 -ceq $target.bodySha256) {
            if ($null -eq $a.byteProof -or $a.authors.Count -ne 1 -or
                -not (Test-BriefAuthorMatch $prior.briefAttribution.authors[0] $a.authors[0])) { throw 'BRIEF_ATTRIBUTION_WRITER_CONFLICT: ambiguous or omitted byte source' }
          }
        }
      }
      if ($a.operation -ceq 'retrospective' -and -not $a.host.writing -and $null -eq $a.byteProof -and
          @($a.authors | Where-Object { $_.model -cne $original.value.model }).Count) { throw 'BRIEF_ATTRIBUTION_WRITER_CONFLICT: retrospective transport needs byte proof' }
      if ($a.operation -ceq 'retrospective' -and $a.host.writing -and
          ($original.value.model -cne $a.host.model -or (Get-BriefEffort $original.value) -cne $a.host.effort)) { throw 'BRIEF_ATTRIBUTION_WRITER_CONFLICT: original host writer' }
      $edgeKeys=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
      foreach($edge in $a.consumed) {
        Assert-BriefObject $edge @('issue','artifact','revision','bodySha256','attributionRawSha256')
        if (($edge.issue -isnot [long] -and $edge.issue -isnot [int]) -or $edge.issue -lt 1 -or $edge.issue -gt [int]::MaxValue) { throw 'BRIEF_ATTRIBUTION_INVALID: source issue' }
        foreach($name in @('artifact','revision')) { Assert-BriefString $edge.$name }
        Assert-BriefString $edge.bodySha256 '^[a-f0-9]{64}$'
        $bound=Get-BriefBoundRow $index $edge.attributionRawSha256 $i $observed
        $source=$bound.value.briefRevision;$key="$($edge.issue):$($edge.artifact)"
        if (-not $edgeKeys.Add($key) -or $edge.issue -eq $target.issue -and $edge.artifact -ceq $target.artifact -or
            -not $validated.ContainsKey($edge.attributionRawSha256) -or $bound.value.briefAttribution.operation -cin @('participation','attestation') -or
            $source.issue -ne $edge.issue -or $source.artifact -cne $edge.artifact -or $source.revision -cne $edge.revision -or
            $source.bodySha256 -cne $edge.bodySha256 -or $latest[$key] -cne $edge.attributionRawSha256 -or $errors.ContainsKey([string]$edge.issue) -or $stale.ContainsKey([string]$edge.issue)) { throw 'BRIEF_ATTRIBUTION_INVALID: stale or conflicting edge' }
        if ($validated[$edge.attributionRawSha256].artifacts -ccontains "$($target.issue):$($target.artifact)") { throw 'BRIEF_ATTRIBUTION_INVALID: ancestry cycle' }
        foreach($model in $validated[$edge.attributionRawSha256].models) { [void]$models.Add($model) }
        foreach($artifact in $validated[$edge.attributionRawSha256].artifacts) { [void]$artifacts.Add($artifact) }
      }
      $key="$($target.issue):$($target.artifact)"
      if ($a.operation -cnotin @('participation','attestation')) {
        if ($latest.ContainsKey($key)) {
          $prior=$index[$latest[$key]][0].value.briefRevision
          if ($observed -le (Convert-RoutingTimestamp $prior.observedAt) -or $prior.revision -ceq $target.revision) { throw 'BRIEF_ATTRIBUTION_INVALID: revision conflict' }
          if ($validated.ContainsKey($latest[$key])) {
            foreach($model in $validated[$latest[$key]].models) { [void]$models.Add($model) }
            foreach($artifact in $validated[$latest[$key]].artifacts) { [void]$artifacts.Add($artifact) }
          }
        }
        $latest[$key]=$Hashes[$i]
        if ($stale.ContainsKey($issueKey)) {
          if ($observed -lt (Convert-RoutingTimestamp $Rows[$stale[$issueKey]].ts)) { throw 'BRIEF_ATTRIBUTION_INVALID: revision predates repair' }
          $stale.Remove($issueKey)
        }
      }
      if ($null -ne $original) {
        if ($overrides.ContainsKey($original.id)) { throw 'BRIEF_ATTRIBUTION_INVALID: original already attributed' }
        $overrides[$original.id]=$Hashes[$i]
      }
      $validated[$Hashes[$i]]=[pscustomobject]@{models=@($models);artifacts=@($artifacts);issue=$row.issue;operation=$a.operation}
    } catch {
      $reason=if($_.Exception.Message.StartsWith('BRIEF_ATTRIBUTION_')){$_.Exception.Message}else{"BRIEF_ATTRIBUTION_INVALID: $($_.Exception.Message)"}
      $errors[$issueKey]=$reason
      $targetIssue=$row.briefRevision.issue
      if (($targetIssue -is [int] -or $targetIssue -is [long]) -and $targetIssue -gt 0) { $errors[[string]$targetIssue]=$reason }
      elseif (($row.issue -isnot [int] -and $row.issue -isnot [long]) -or $row.issue -lt 1) { $errors['*']=$reason }
    }
  }
  return [pscustomobject]@{validated=$validated;overrides=$overrides;errors=$errors;eligible=$eligible;latest=$latest;stale=$stale}
}

function Get-CapacityAuthorHistory {
  # Branch-rooted (implementation): the complete single-branch lineage, as
  # before. Issue-rooted (planning/review): every row of that issue on any
  # branch; rows carrying another issue belong to another artifact and are
  # neither authors nor followed. Artifact 'code', 'brief' or 'all' selects the
  # returned authorship; read-only reviewers are never authors.
  param([string]$Path,[string]$Branch,[int]$Issue=0,[ValidateSet('code','brief','all')][string]$Artifact='code',$Registry)
  $unknown=[pscustomobject]@{complete=$false;models=@()}
  if ((-not $Branch -and $Issue -lt 1) -or -not [IO.File]::Exists($Path)) { return $unknown }
  $rows=[Collections.Generic.List[object]]::new()
  $hashes=[Collections.Generic.List[string]]::new()
  $links=[Collections.Generic.Dictionary[string,Collections.Generic.List[int]]]::new([StringComparer]::Ordinal)
  $reader=$null
  try {
    # Read the complete stable ledger, not a schema-filtered tail. Malformed or
    # concurrently truncated bytes cannot prove that an author is absent.
    $before=Get-Item -LiteralPath $Path
    $length=$before.Length;$write=$before.LastWriteTimeUtc
    $reader=[IO.StreamReader]::new($Path,[Text.UTF8Encoding]::new($false,$true))
    if($length -gt 0){
      [void]$reader.BaseStream.Seek(-1,[IO.SeekOrigin]::End)
      if($reader.BaseStream.ReadByte() -ne 10){return $unknown}
      [void]$reader.BaseStream.Seek(0,[IO.SeekOrigin]::Begin)
    }
    while($null -ne ($line=$reader.ReadLine())) {
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      $document=[Text.Json.JsonDocument]::Parse($line)
      try {
        if($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object){return $unknown}
        $members=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($property in $document.RootElement.EnumerateObject()){
          if(-not $members.Add($property.Name)){return $unknown} # CAPACITY_GUARD_UNIQUE_HISTORY
          if ($property.Name -cin @('briefRevision','briefAttribution')) { Assert-BriefJsonMembers $property.Value }
        }
      } finally { $document.Dispose() }
      $e=$line | ConvertFrom-Json -DateKind String -Depth 100 -NoEnumerate -ErrorAction Stop
      if (-not (Test-RoutingObject $e)) { return $unknown }
      $id=$rows.Count;$rows.Add($e)
      $hashes.Add((Get-BriefRawSha256 $line))
      foreach($pair in @(@('attempt','attemptId'),@('attempt','authorAttempt'),@('attempt','repairAttempt'),
          @('attempt','resumeOfAttemptId'),@('transcript','transcript'),@('transcript','resumedPartial'),
          @('branch','branch'),@('branch','targetBranch'),@('artifact','artifactId'),@('issue','issue'),@('pr','pr'))) {
        $value=$e.PSObject.Properties[$pair[1]]
        if ($null -eq $value -or $null -eq $value.Value -or $value.Value -ceq '') { continue }
        if ($pair[0] -cin @('issue','pr')) {
          if (($value.Value -isnot [int] -and $value.Value -isnot [long]) -or $value.Value -lt 1) { continue }
        } elseif ($value.Value -isnot [string]) { return $unknown }
        $tokenValue=[string]$value.Value
        if ($pair[0] -ceq 'transcript') { $tokenValue=($tokenValue -replace '\\','/').Split('/')[-1] }
        $key="$($pair[0]):$tokenValue"
        if (-not $links.ContainsKey($key)) { $links[$key]=[Collections.Generic.List[int]]::new() }
        $links[$key].Add($id)
      }
    }
    $after=Get-Item -LiteralPath $Path
    if ($after.Length -ne $length -or $after.LastWriteTimeUtc -ne $write) { return $unknown }
  } catch { return $unknown } finally { if($null -ne $reader){$reader.Dispose()} }
  $byRow=@{}
  foreach($key in $links.Keys) { foreach($id in $links[$key]) {
    if(-not $byRow.ContainsKey($id)){$byRow[$id]=[Collections.Generic.List[string]]::new()};$byRow[$id].Add($key)
  } }
  $issueRooted=-not $Branch
  $queue=[Collections.Generic.Queue[string]]::new();$queue.Enqueue($(if($issueRooted){"issue:$Issue"}else{"branch:$Branch"}))
  $seenKeys=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  $seenRows=[Collections.Generic.HashSet[int]]::new()
  while($queue.Count) {
    $key=$queue.Dequeue();if(-not $seenKeys.Add($key) -or -not $links.ContainsKey($key)){continue}
    if(-not $issueRooted -and $key.StartsWith('branch:') -and $key -cne "branch:$Branch"){return $unknown}
    foreach($id in $links[$key]) {
      if($issueRooted){
        $rowIssue=$rows[$id].PSObject.Properties['issue']
        if($null -ne $rowIssue -and ($rowIssue.Value -is [int] -or $rowIssue.Value -is [long]) -and $rowIssue.Value -ge 1 -and $rowIssue.Value -ne $Issue){continue} # CAPACITY_GUARD_OTHER_ARTIFACT
      }
      if($seenRows.Add($id)){foreach($next in $byRow[$id]){$queue.Enqueue($next)}}
    }
  }
  $code=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  $brief=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  $legacyAmbiguous=$false
  try {
    $briefProjection=Get-BriefAttributionProjection $rows $hashes $Registry
    if ($briefProjection.errors.ContainsKey('*') -or ($Issue -gt 0 -and
        ($briefProjection.errors.ContainsKey([string]$Issue) -or $briefProjection.stale.ContainsKey([string]$Issue)))) { return $unknown }
    $lineageModels=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($id in $seenRows) {
      $source=$rows[$id]
      if (($source.kind -cin @('dispatch','repair-complete','repair-start','continuation') -or
           (Get-CapacityAuthorArtifact $source) -cin @('code','brief','legacy')) -and
          $source.model -is [string] -and (Get-RoutingModelIdentity $Registry $source.model)) {
        [void]$lineageModels.Add($source.model)
      }
      if ($source.kind -ceq 'review-complete' -and $source.reviewerPatch -is [bool] -and $source.reviewerPatch) {
        $patchModel=if($source.controllerReviewSchema){$source.reviewerModel}else{$source.model}
        if ($patchModel -is [string] -and (Get-RoutingModelIdentity $Registry $patchModel)) { [void]$lineageModels.Add($patchModel) }
      }
    }
    foreach($id in $seenRows) {
      $e=$rows[$id]
      if ($e.historyComplete -eq $false -or $e.partial -eq $true -or $e.truncated -eq $true) { return $unknown } # CAPACITY_GUARD_COMPLETE
      if ($briefProjection.errors.ContainsKey([string]$e.issue) -or $briefProjection.stale.ContainsKey([string]$e.issue)) { return $unknown }
      $binding=if($briefProjection.overrides.ContainsKey($id)){$briefProjection.overrides[$id]}elseif($briefProjection.validated.ContainsKey($hashes[$id])){$hashes[$id]}else{$null}
      if ($binding) {
        $fact=$briefProjection.validated[$binding]
        if ($fact.operation -cne 'attestation') { foreach($model in $fact.models) { [void]$brief.Add($model) } }
        # An explicit brief fact replaces only lifecycle inference. A Packet's
        # original implementation dispatch still contributes its code history.
        if ($e.briefSchema -or (Get-CapacityAuthorArtifact $e) -ceq 'lifecycle') { continue }
      }
      $rowArtifact=Get-CapacityAuthorArtifact $e
      if ($rowArtifact -ceq 'unknown') { return $unknown }
      if ($rowArtifact -ceq 'lifecycle' -and -not $lineageModels.Contains([string]$e.model)) { return $unknown }
      $attributed=[Collections.Generic.List[object]]::new()
      $authors=[Collections.Generic.List[object]]::new()
      if ($rowArtifact -cin @('code','brief','legacy')) {
        $authors.Add($e.model) # CAPACITY_GUARD_GENERIC_HISTORY
      }
      if ($e.kind -ceq 'review-complete' -or ($e.kind -ceq 'dispatch' -and -not $e.laneRole -and $e.authorModel)) {
        $receiptArtifact=Get-CapacityReceiptArtifact $e
        if ($e.authorModel) { $attributed.Add(@($receiptArtifact,$e.authorModel)) }
        if ($e.kind -ceq 'review-complete' -and $null -ne $e.PSObject.Properties['reviewerPatch']) {
          if ($e.reviewerPatch -isnot [bool]) { return $unknown }
          if ($e.reviewerPatch) { # CAPACITY_GUARD_PATCH_AUTHOR
            if ($null -eq $e.PSObject.Properties['controllerReviewSchema']) { $attributed.Add(@($receiptArtifact,$e.model)) }
            elseif ($e.controllerReviewSchema -cin @('controller-review-receipt/v1','controller-review-receipt/v2')) { $attributed.Add(@($receiptArtifact,$e.reviewerModel)) }
            else { return $unknown }
          }
        }
      }
      foreach($field in @('authorLadder','unusedAuthorModels')) {
        if ($null -ne $e.PSObject.Properties[$field]) {
          if ($e.$field -isnot [array]) { return $unknown }
          foreach($model in $e.$field) { $attributed.Add(@($(if($rowArtifact -cin @('code','brief','legacy')){$rowArtifact}else{'all'}),$model)) }
        }
      }
      foreach($model in $authors) { $attributed.Add(@($rowArtifact,$model)) }
      foreach($entry in $attributed) {
        $bucket=$entry[0];$model=$entry[1]
        if ($model -isnot [string] -or -not (Get-RoutingModelIdentity $Registry $model)) { return $unknown }
        if ($bucket -ceq 'legacy') { $legacyAmbiguous=$true }
        if ($bucket -cin @('code','legacy','all')) { [void]$code.Add($model) }
        if ($bucket -cin @('brief','all')) { [void]$brief.Add($model) }
      }
    }
  } catch { return $unknown }
  $models=switch ($Artifact) {
    'code' { @($code) }
    'brief' { if ($legacyAmbiguous) { return $unknown }; @($brief) }
    'all' { @(@($code)+@($brief) | Sort-Object -Unique -CaseSensitive) }
  }
  return [pscustomobject]@{complete=$true;models=@($models)}
}

function Get-CapacityFableWindowState($Forecast) {
  # Legacy forecast reader retained for compatibility; live provider windows govern capacity.
  # Missing, non-object or non-string input is $null, never inferred from the
  # provider states. This is telemetry, not a model-specific share policy.
  $decision=if (Test-RoutingObject $Forecast) { $Forecast.PSObject.Properties['decision'] } else { $null }
  if ($null -eq $decision -or $decision.Value -is [array] -or -not (Test-RoutingObject $decision.Value)) { return $null }
  $windows=$decision.Value.PSObject.Properties['modelWindowStates']
  if ($null -eq $windows -or $windows.Value -is [array] -or -not (Test-RoutingObject $windows.Value)) { return $null }
  $claude=$windows.Value.PSObject.Properties['claude']
  if ($null -eq $claude -or $claude.Value -is [array] -or -not (Test-RoutingObject $claude.Value)) { return $null }
  $state=$claude.Value.PSObject.Properties['Fable']
  if ($null -eq $state -or $state.Value -isnot [string]) { return $null }
  return $state.Value
}

# Mirror of the watchdog's closed quota/session table (lane-stall-watchdog.ps1),
# keyed row|family/effort -> continuation family. The watchdog owns the table and
# dispatch-routing-data.test.ps1 pins this mirror to its source. Rows the table
# does not reach follow the watchdog's policy-slot fallback: the row's
# other-harness slot, primary before fallback, first admitted configuration;
# rows 7/9/11/12/14/15 have no policy fallback.
$script:CapacityClosedContinuations=@{
  '2|luna/medium'='sol'
  '4|astra/high'='sol';'4|sol/medium'='sol';'5|astra/high'='sol';'5|sol/xhigh'='sol'
  '6|opus/high'='sol';'6|astra/high'='sol';'7|fable/high'='astra'
  '10|astra/high'='sol';'10|sonnet/high'='sol'
  '14|fable/medium'='astra';'14|fable/high'='astra';'15|fable/high'='astra'
  '7|astra/high'='fable';'14|astra/high'='fable';'15|astra/high'='fable'
  '4|sol/high'='opus';'5|sol/high'='opus';'6|sol/high'='opus';'7|sol/high'='opus';'10|sol/high'='opus'
  '3|sol/medium'='opus';'13|sol/medium'='opus'
  '3|opus/medium'='sol';'13|opus/medium'='sol';'13|opus/low'='sol'
  '10|opus/medium'='sol';'4|opus/medium'='sol';'5|opus/high'='sol'
}

function Get-CapacityRouteContinuation($Data,[int]$Row,[string]$Family,[string]$Effort) {
  # The exact current model a quota/session continuation of this route would
  # run as, or $null when the watchdog records NO_QUALIFIED_FALLBACK.
  $key="$Row|$Family/$Effort";$continuation=$null
  if ($script:CapacityClosedContinuations.ContainsKey($key)) { $continuation=[string]$script:CapacityClosedContinuations[$key] }
  elseif ($Row -notin @(7,9,11,12,14,15)) {
    $identity=$Data.registry.families.PSObject.Properties[$Family]
    if ($null -eq $identity) { return $null }
    $other=if($identity.Value.provider -ceq 'codex'){'claude'}else{'codex'}
    $slots=$Data.policy.rows.PSObject.Properties[[string]$Row].Value.slots
    foreach($name in @("$other.primary","$other.fallback")) {
      $slot=$slots.PSObject.Properties[$name]
      if ($null -eq $slot) { continue }
      $entry=$Data.registry.families.PSObject.Properties[[string]$slot.Value.family]
      if ($null -eq $entry -or (Get-RoutingAdmissionReason $Data.registry ([string]$entry.Value.current) ([string]$slot.Value.effort))) { continue }
      $continuation=[string]$slot.Value.family;break
    }
  }
  if (-not $continuation) { return $null }
  $continuationFamily=$Data.registry.families.PSObject.Properties[$continuation]
  if ($null -eq $continuationFamily) { return $null }
  return [string]$continuationFamily.Value.current
}

function Resolve-CapacityRouting {
  param($Selection,[string]$StateRoot,[string]$LkgPath,[string]$HistoryPath,[string]$Branch,[int]$Issue=0,
    [ValidateSet('implementation','planning','review')][string]$LaneRole='implementation',
    [ValidateSet('','brief','code')][string]$ReviewArtifact='',
    [bool]$Exempt=$false,[DateTimeOffset]$NowUtc=[DateTimeOffset]::UtcNow)
  $result=[pscustomobject]@{selection=$Selection;capacityForecastStatus='not-evaluated';capacityDecisionDigest=$null
    capacityFlip=$null;capacityShadowFlip=$null;capacityFlipSkip=$null;forecastBytes=$null}
  if ($Exempt) { return $result } # CAPACITY_GUARD_EXEMPT
  $inputForecast=Get-CapacityForecast -StateRoot $StateRoot -NowUtc $NowUtc
  $result.capacityForecastStatus=$inputForecast.status
  $result.forecastBytes=$inputForecast.bytes
  if ($null -eq $inputForecast.forecast) { return $result }
  $f=$inputForecast.forecast;$result.capacityDecisionDigest=$f.decisionDigest
  $toward=$f.balance.toward;$steps=$f.balance.steps
  # Toward Claude every off-toward row flips once steps >= 1 (Todd
  # 4388/6098327249); toward Codex the ordered prefix still bounds the first
  # `steps` rows. An already-on-toward selection is never flipped.
  if (-not $toward -or $steps -eq 0 -or $Selection.harness -ceq $toward) { return $result } # CAPACITY_GUARD_DIRECTION
  if ($toward -ceq 'codex' -and $Selection.row -notin @(@(3,13,10,4) | Select-Object -First $steps)) { return $result } # CAPACITY_GUARD_PREFIX
  try {
    $target=Resolve-RoutingSelection -Row $Selection.row -Harness $toward -StateRoot $StateRoot -LkgPath $LkgPath -NowUtc $NowUtc -ReadOnly
    $data=Get-RoutingData -StateRoot $StateRoot -LkgPath $LkgPath -NowUtc $NowUtc -ReadOnly
    $slots=$data.policy.rows.PSObject.Properties[[string]$Selection.row].Value.slots
    $ownSlot=if($slots.PSObject.Properties["$toward.primary"]){"$toward.primary"}else{"$toward.fallback"}
    if ($target.harness -cne $toward -or $target.slot -cne $ownSlot) { throw 'SLOT_NOT_ADMITTED' }
    # Todd placed every Claude flip (4388/6098327249): family, effort and slot
    # stay the own slot's; v3 evidence and author records log override-Todd.
    if ($toward -ceq 'claude') { $target.placement='override-Todd' } # CAPACITY_GUARD_RULED_PLACEMENT
  } catch { $result.capacityFlipSkip='SLOT_NOT_ADMITTED';return $result }
  # Independence is per artifact and per route: implementation reads the
  # complete branch lineage, planning the whole issue, review the named
  # artifact (brief or code) of the issue. Skips grant nothing.
  $historyArguments=switch ($LaneRole) {
    'implementation' { @{Branch=$Branch;Artifact='code'} }
    'planning' { @{Issue=$Issue;Artifact='all'} }
    'review' { @{Issue=$Issue;Artifact=$ReviewArtifact} }
  }
  if (($LaneRole -cne 'implementation' -and $Issue -lt 1) -or -not $historyArguments.Artifact) { $result.capacityFlipSkip='REVIEWER_HISTORY_UNKNOWN';return $result } # CAPACITY_GUARD_ARTIFACT
  $history=Get-CapacityAuthorHistory -Path $HistoryPath @historyArguments -Registry $data.registry
  if (-not $history.complete) { $result.capacityFlipSkip='REVIEWER_HISTORY_UNKNOWN';return $result }
  # Authorship does not exclude a model family. Fresh lane/session independence
  # and exact-head receipt gates are enforced by the review contract, not by
  # reserving a third model during capacity selection.

  $flip=[pscustomobject]@{row=[int]$Selection.row;toward=$toward;steps=[int]$steps
    from=[pscustomobject]@{harness=$Selection.harness;family=$Selection.family;effort=$Selection.effort;slot=$Selection.slot}
    to=[pscustomobject]@{harness=$target.harness;family=$target.family;effort=$target.effort;slot=$target.slot;placement=$target.placement}}
  if ($inputForecast.status -ceq 'shadow') { $result.capacityShadowFlip=$flip }
  else { $result.capacityFlip=$flip;$result.selection=$target }
  return $result
}

if (-not $Library) {
  Get-RoutingData -StateRoot $StateRoot -LkgPath $LkgPath -ReadOnly |
    Select-Object policyGeneration,registryAuthorityDigest,usedLastKnownGood,sourceReason,lkgPath |
    ConvertTo-Json -Compress
}
