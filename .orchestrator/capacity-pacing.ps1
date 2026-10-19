<#
.SYNOPSIS
Read-only capacity pacing reducer (#9316): per-provider new-lane allowance.

.DESCRIPTION
Turns each AgentPools account's headroom, time to reset and the provider's
measured burn per lane-hour into a per-provider lane budget and new-lane
allowance, emitted as one `capacity-pacing/v1` JSON object. Inputs are a
status snapshot (live GET or a -StatusPath fixture), the capacity forecast and
model registry (routing-data.ps1), the live census (dispatch-ownership.ps1 or a
-CensusPath fixture), the dispatch log with its transcripts, and -NowUtc.
Replay with the same inputs and -NowUtc is byte-identical. Unknown, missing,
malformed or stale status or census never authorizes a lane; an invalid or
stale forecast, or too few lane-hours, only falls back to the default burn.
A status is malformed when any consumed account or window field is missing or
invalid, or when it repeats an account identity; nothing is skipped, clamped
or deduplicated. The script mutates nothing. Dot-source with -Library to call
the functions.
#>
[CmdletBinding()]
param(
  [string]$StatusPath,
  [string]$StatusUrl,
  [string]$StateRoot,
  [string]$LkgPath,
  [string]$CensusPath,
  [string]$RuntimeRoot,
  [string]$ContainerRoot,
  [string]$DispatchLogPath,
  [string]$TranscriptRoot,
  [string]$NowUtc,
  [string]$OutFile,
  [switch]$Library
)
$ErrorActionPreference = 'Stop'
# routing-data.ps1 declares its own StateRoot/LkgPath/Library parameters;
# dot-sourcing it rebinds those names in this scope, so capture ours first.
$script:PacingInvocation = [ordered]@{
  StatusPath=$StatusPath;StatusUrl=$StatusUrl;StateRoot=$StateRoot;LkgPath=$LkgPath;CensusPath=$CensusPath
  RuntimeRoot=$RuntimeRoot;ContainerRoot=$ContainerRoot;DispatchLogPath=$DispatchLogPath;TranscriptRoot=$TranscriptRoot
  NowUtc=$NowUtc;OutFile=$OutFile;Library=[bool]$Library
}
. (Join-Path $PSScriptRoot 'routing-data.ps1') -Library

$script:PacingSchema = 'capacity-pacing/v1'
$script:PacingProviders = @('claude', 'codex')
# Defaults are the 7-day measurements in #9316 (units per lane-hour).
$script:PacingConfig = [ordered]@{
  reserve = 0.10
  defaultBurnPerLaneHour = [ordered]@{ claude = 0.015; codex = 0.009 }
  minLaneHours = 24
  windowHours = 168
  fableShare = $null # Compatibility field; provider window capacity is not a policy share.
  statusMaxAgeMinutes = 30
  statusTimeoutSeconds = 3
  defaultStatusUrl = 'http://127.0.0.1:8318/api/status'
}

function Get-PacingProperty($Object, [string]$Name) {
  # The unary comma keeps array values intact; a bare return would unroll an
  # empty array to nothing and a one-element array to its element.
  if ($null -eq $Object) { return $null }
  if ($Object -is [Collections.IDictionary]) { if ($Object.Contains($Name)) { return ,$Object[$Name] } ; return $null }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -ne $property) { return ,$property.Value }
  return $null
}
function Test-PacingObject($Value) {
  return $null -ne $Value -and (($Value -is [pscustomobject]) -or ($Value -is [Collections.IDictionary]))
}
function Test-PacingFiniteNumber($Value) {
  if ($null -eq $Value -or $Value -is [bool] -or $Value -is [string] -or $Value -isnot [ValueType]) { return $false }
  $number = 0.0
  try { $number = [double]$Value } catch { return $false }
  return -not ([double]::IsNaN($number) -or [double]::IsInfinity($number))
}
function ConvertTo-PacingInstant($Value) {
  if ($Value -isnot [string] -or $Value -cnotmatch '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|[+-]\d\d:\d\d)$') { throw 'PACING_INSTANT_INVALID' }
  $parsed = [DateTimeOffset]::MinValue
  if (-not [DateTimeOffset]::TryParse($Value, [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) { throw 'PACING_INSTANT_INVALID' }
  return $parsed.ToUniversalTime()
}
function Format-PacingInstant([DateTimeOffset]$Value) { return $Value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'") }
function Format-PacingNumber([double]$Value) { return [Math]::Round($Value, 6) }
function Test-PacingHasProperty($Object, [string]$Name) {
  if ($null -eq $Object) { return $false }
  if ($Object -is [Collections.IDictionary]) { return $Object.Contains($Name) }
  return $null -ne $Object.PSObject.Properties[$Name]
}

function Get-PacingAccountIdentity($Account) {
  # The account's `id` is its identity; `name` is the documented fallback only
  # when no `id` was supplied. A supplied non-string or blank value, or neither
  # field, is no identity (null).
  $identity = if (Test-PacingHasProperty $Account 'id') { Get-PacingProperty $Account 'id' } else { Get-PacingProperty $Account 'name' }
  if ($identity -is [string] -and -not [string]::IsNullOrWhiteSpace($identity)) { return $identity }
  return $null
}

function Test-PacingWindow($Window) {
  # A quota window is usable only when every consumed field is present and
  # valid: boolean `common`, string `scope`, finite `used` in [0,100] and a
  # `resetAt` that is null or epoch milliseconds. A missing or invalid field
  # makes the whole status malformed; it is never skipped or clamped.
  if (-not (Test-PacingObject $Window)) { return $false }
  foreach ($name in @('common', 'scope', 'used', 'resetAt')) { if (-not (Test-PacingHasProperty $Window $name)) { return $false } }
  if ((Get-PacingProperty $Window 'common') -isnot [bool]) { return $false }
  if ((Get-PacingProperty $Window 'scope') -isnot [string]) { return $false }
  $used = Get-PacingProperty $Window 'used'
  if (-not (Test-PacingFiniteNumber $used)) { return $false }
  if ([double]$used -lt 0 -or [double]$used -gt 100) { return $false }
  $reset = Get-PacingProperty $Window 'resetAt'
  if ($null -ne $reset -and $null -eq (Get-PacingWindowReset $Window)) { return $false }
  return $true
}

function Read-PacingStatus([string]$Path, [string]$Url, [DateTimeOffset]$Now) {
  # One fixture read or one HTTP GET with a 3 s timeout. Any failure, shape
  # defect or a snapshot older than statusMaxAgeMinutes (or from the future)
  # is unknown; unknown never authorizes. Shape covers every field the budget
  # consumes: each account needs an identity that no other account of the
  # same provider repeats; a non-disabled available account needs its window
  # collection; every supplied window must pass Test-PacingWindow.
  $result = [ordered]@{status='unknown';source=$(if ($Path) { 'fixture' } else { 'live' });reason=$null;checkedAt=$null;accounts=@()}
  $body = $null
  try {
    if ($Path) {
      $body = [IO.File]::ReadAllText([IO.Path]::GetFullPath($Path))
    } else {
      $target = if ($Url) { $Url } elseif ($env:CODEX_POOL_STATUS_URL) { $env:CODEX_POOL_STATUS_URL } else { $script:PacingConfig.defaultStatusUrl }
      $body = (Invoke-WebRequest -Uri $target -TimeoutSec $script:PacingConfig.statusTimeoutSeconds -NoProxy -ErrorAction Stop).Content
    }
  } catch { $result.reason = 'STATUS_UNREACHABLE'; return $result }
  $status = $null
  try { $status = $body | ConvertFrom-Json -Depth 100 -DateKind String -NoEnumerate -ErrorAction Stop } catch { $result.reason = 'STATUS_MALFORMED'; return $result }
  $result.reason = 'STATUS_MALFORMED'
  if (-not (Test-PacingObject $status) -or $status -is [array]) { return $result }
  if ($null -ne (Get-PacingProperty $status 'error')) { return $result }
  $accounts = Get-PacingProperty $status 'accounts'
  if ($accounts -isnot [array]) { return $result }
  $identities = [hashtable]::new([StringComparer]::Ordinal)
  foreach ($account in $accounts) {
    if (-not (Test-PacingObject $account) -or
        (Get-PacingProperty $account 'provider') -isnot [string] -or
        (Get-PacingProperty $account 'disabled') -isnot [bool] -or
        (Get-PacingProperty $account 'status') -isnot [string]) { return $result }
    $identity = Get-PacingAccountIdentity $account
    if ($null -eq $identity) { return $result }
    $identityKey = (Get-PacingProperty $account 'provider') + "`0" + $identity
    if ($identities.ContainsKey($identityKey)) { return $result }
    $identities[$identityKey] = $true
    $windows = Get-PacingProperty $account 'quotaWindows'
    if ($null -eq $windows) {
      if (-not (Get-PacingProperty $account 'disabled') -and (Get-PacingProperty $account 'status') -ceq 'available') { return $result }
    } else {
      if ($windows -isnot [array]) { return $result }
      foreach ($window in $windows) { if (-not (Test-PacingWindow $window)) { return $result } }
    }
  }
  $checkedAt = [DateTimeOffset]::MinValue
  try { $checkedAt = ConvertTo-PacingInstant (Get-PacingProperty $status 'checkedAt') } catch { return $result }
  $result.checkedAt = Format-PacingInstant $checkedAt
  if ($checkedAt -gt $Now.AddMinutes(5) -or ($Now - $checkedAt).TotalMinutes -gt $script:PacingConfig.statusMaxAgeMinutes) { $result.reason = 'STATUS_STALE'; return $result }
  $result.status = 'ok'; $result.reason = $null; $result.accounts = @($accounts)
  return $result
}

function Get-PacingWindowReset($Window) {
  # resetAt is epoch milliseconds (AgentPools quotaWindows); anything else is unknown.
  $value = Get-PacingProperty $Window 'resetAt'
  if (-not (Test-PacingFiniteNumber $value)) { return $null }
  $milliseconds = [double]$value
  if ($milliseconds -lt 0 -or $milliseconds -gt 253402300799999) { return $null }
  return [DateTimeOffset]::FromUnixTimeMilliseconds([long][Math]::Floor($milliseconds))
}

function Get-PacingAccountBudget($Account, [DateTimeOffset]$Now, [double]$Burn, [double]$Reserve, [string]$Scope) {
  # Scope 'common': the binding window is the common window with the highest
  # used percentage (ties take the latest known reset). Scope 'fable': the
  # Fable-scoped window. lanes = max(0, headroom - reserve) / (burn * hours).
  # Read-PacingStatus has already validated every window field consumed here.
  $id = Get-PacingAccountIdentity $Account
  $status = [string](Get-PacingProperty $Account 'status')
  $entry = [ordered]@{account=$id;status=$status;disabled=[bool](Get-PacingProperty $Account 'disabled');scope=$Scope;contributes=$false;reason=$null
    windowId=$null;used=$null;headroom=$null;resetAt=$null;hours=$null;lanes=0}
  $result = [pscustomobject]@{entry=$entry;lanes=0.0}
  if ($entry.disabled) { $entry.reason = 'ACCOUNT_DISABLED'; return $result }
  if ((Get-PacingProperty $Account 'usageStale') -eq $true) { $entry.reason = 'ACCOUNT_STALE'; return $result }
  if ($status -ceq 'exhausted') { $entry.reason = 'ACCOUNT_EXHAUSTED'; return $result }
  if ($status -cne 'available') { $entry.reason = 'ACCOUNT_UNKNOWN'; return $result }
  $windows = Get-PacingProperty $Account 'quotaWindows'
  $candidates = @(foreach ($window in @($windows)) {
    $selected = if ($Scope -ceq 'common') { (Get-PacingProperty $window 'common') -eq $true }
      else { $windowScope = Get-PacingProperty $window 'scope'; $windowScope -is [string] -and $windowScope -ceq 'Fable' }
    if (-not $selected) { continue }
    $windowId = Get-PacingProperty $window 'id'
    [pscustomobject]@{id=$(if ($windowId -is [string]) { $windowId } else { $null });used=[double](Get-PacingProperty $window 'used');resetAt=(Get-PacingWindowReset $window)}
  })
  if ($candidates.Count -eq 0) { $entry.reason = 'NO_WINDOW'; return $result }
  $binding = $null
  foreach ($candidate in $candidates) {
    if ($null -eq $binding -or $candidate.used -gt $binding.used) { $binding = $candidate; continue }
    if ($candidate.used -eq $binding.used) {
      $candidateReset = if ($null -eq $candidate.resetAt) { [DateTimeOffset]::MinValue } else { $candidate.resetAt }
      $bindingReset = if ($null -eq $binding.resetAt) { [DateTimeOffset]::MinValue } else { $binding.resetAt }
      if ($candidateReset -gt $bindingReset) { $binding = $candidate }
    }
  }
  $entry.windowId = $binding.id; $entry.used = Format-PacingNumber $binding.used
  if ($null -eq $binding.resetAt) { $entry.reason = 'RESET_UNKNOWN'; return $result }
  $headroom = (100.0 - $binding.used) / 100.0
  $hours = [Math]::Max(1.0, ($binding.resetAt - $Now).TotalHours)
  $lanes = [Math]::Max(0.0, $headroom - $Reserve) / ($Burn * $hours)
  $entry.headroom = Format-PacingNumber $headroom; $entry.resetAt = Format-PacingInstant $binding.resetAt
  $entry.hours = Format-PacingNumber $hours; $entry.lanes = Format-PacingNumber $lanes; $entry.contributes = $true
  $result.lanes = $lanes
  return $result
}

function Get-PacingRegistryFamilies([string]$Root, [string]$Lkg, [DateTimeOffset]$Now) {
  # families.<f>.provider from the validated registry (or its last-known-good copy).
  $result = [ordered]@{status='unknown';reason=$null;registryAuthorityDigest=$null;usedLastKnownGood=$null;families=[hashtable]::new([StringComparer]::Ordinal)}
  try {
    $data = Get-RoutingData -StateRoot $Root -LkgPath $Lkg -NowUtc $Now -ReadOnly
    foreach ($family in $data.registry.families.PSObject.Properties) {
      $provider = Get-PacingProperty $family.Value 'provider'
      if ($provider -is [string] -and $provider -cin $script:PacingProviders) { $result.families[$family.Name] = $provider }
    }
    $result.registryAuthorityDigest = [string]$data.registryAuthorityDigest
    $result.usedLastKnownGood = [bool]$data.usedLastKnownGood
    $result.status = 'ok'
  } catch { $result.reason = 'REGISTRY_UNAVAILABLE:' + $_.Exception.Message }
  return $result
}

function Resolve-PacingProvider($Record, [hashtable]$FamilyProvider) {
  # family through the registry; otherwise the slot prefix (`<provider>.<name>`)
  # or an explicit harness; otherwise unmapped.
  $family = Get-PacingProperty $Record 'family'
  if ($family -is [string] -and $FamilyProvider.ContainsKey($family)) { return $FamilyProvider[$family] }
  $slot = Get-PacingProperty $Record 'slot'
  if ($slot -is [string]) { $prefix = ($slot -split '\.')[0]; if ($prefix -cin $script:PacingProviders) { return $prefix } }
  $harness = Get-PacingProperty $Record 'harness'
  if ($harness -is [string] -and $harness -cin $script:PacingProviders) { return $harness }
  return $null
}

function Get-PacingLaneHours([string]$LogPath, [string]$TranscriptDir, [DateTimeOffset]$Now, [hashtable]$FamilyProvider) {
  # Lane-hours per provider over the last windowHours: each dispatch row with
  # a transcript runs from its ts to the transcript's last write, clipped to
  # the window. One transcript counts once from its earliest dispatch row.
  $hours = [ordered]@{claude=0.0;codex=0.0}
  $diagnostics = [ordered]@{status='ok';reason=$null;rows=0;counted=0;transcriptsMissing=0;unmapped=0;duplicates=0;windowStart=(Format-PacingInstant $Now.AddHours(-$script:PacingConfig.windowHours))}
  $windowStart = $Now.AddHours(-$script:PacingConfig.windowHours)
  if (-not $LogPath -or -not [IO.File]::Exists($LogPath)) {
    $diagnostics.status = 'unknown'; $diagnostics.reason = 'DISPATCH_LOG_MISSING'
    return [pscustomobject]@{hours=$hours;diagnostics=$diagnostics}
  }
  $seen = [hashtable]::new([StringComparer]::Ordinal)
  foreach ($line in [IO.File]::ReadLines($LogPath)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $row = $null
    try { $row = $line | ConvertFrom-Json -Depth 50 -DateKind String -ErrorAction Stop } catch { continue }
    if (-not (Test-PacingObject $row) -or (Get-PacingProperty $row 'kind') -cne 'dispatch') { continue }
    $transcript = Get-PacingProperty $row 'transcript'
    if ($transcript -isnot [string] -or [string]::IsNullOrWhiteSpace($transcript)) { continue }
    $diagnostics.rows += 1
    $start = [DateTimeOffset]::MinValue
    try { $start = ConvertTo-PacingInstant (Get-PacingProperty $row 'ts') } catch { continue }
    if ($start -gt $Now) { continue }
    $provider = Resolve-PacingProvider $row $FamilyProvider
    if (-not $provider) { $diagnostics.unmapped += 1; continue }
    $path = if ([IO.Path]::IsPathRooted($transcript)) { $transcript } else { Join-Path $TranscriptDir $transcript }
    $key = [IO.Path]::GetFullPath($path)
    if ($seen.ContainsKey($key)) {
      $diagnostics.duplicates += 1
      if ($start -lt $seen[$key].start) { $seen[$key].start = $start }
      continue
    }
    $seen[$key] = @{start=$start;provider=$provider;path=$key}
  }
  [string[]]$keys = @($seen.Keys)
  [Array]::Sort($keys, [StringComparer]::Ordinal)
  foreach ($key in $keys) {
    $item = $seen[$key]
    if (-not [IO.File]::Exists($item.path)) { $diagnostics.transcriptsMissing += 1; continue }
    $end = [DateTimeOffset]::new([IO.File]::GetLastWriteTimeUtc($item.path))
    $start = if ($item.start -lt $windowStart) { $windowStart } else { $item.start }
    if ($end -gt $Now) { $end = $Now }
    if ($end -le $start) { continue }
    $hours[$item.provider] += ($end - $start).TotalHours
    $diagnostics.counted += 1
  }
  return [pscustomobject]@{hours=$hours;diagnostics=$diagnostics}
}

function Get-PacingBurn([string]$Provider, $Forecast, [double]$LaneHours) {
  # burnPerLaneHour = demand.last168h * windowHours / lane-hours, measured only
  # from an in-force or shadow forecast with at least minLaneHours; otherwise
  # the config default, with burnSource 'default' and the reason.
  $default = [double]$script:PacingConfig.defaultBurnPerLaneHour[$Provider]
  $entry = [ordered]@{burnPerLaneHour=$default;burnSource='default';burnReason=$null;demandUnitsPerHour=$null;laneHours=(Format-PacingNumber $LaneHours)}
  $result = [pscustomobject]@{entry=$entry;burn=$default}
  if ($Forecast.status -cnotin @('in-force', 'shadow')) { $entry.burnReason = 'FORECAST_' + ([string]$Forecast.status).ToUpperInvariant().Replace('-', '_'); return $result }
  $demand = Get-PacingProperty (Get-PacingProperty (Get-PacingProperty $Forecast.forecast.providers $Provider) 'demand') 'last168h'
  if (-not (Test-PacingFiniteNumber $demand) -or [double]$demand -lt 0) { $entry.burnReason = 'FORECAST_DEMAND_INVALID'; return $result }
  $entry.demandUnitsPerHour = Format-PacingNumber ([double]$demand)
  if ($LaneHours -lt $script:PacingConfig.minLaneHours) { $entry.burnReason = 'LANE_HOURS_BELOW_MINIMUM'; return $result }
  $burn = ([double]$demand * $script:PacingConfig.windowHours) / $LaneHours
  if ([double]::IsNaN($burn) -or [double]::IsInfinity($burn) -or $burn -le 0) { $entry.burnReason = 'BURN_NONPOSITIVE'; return $result }
  $entry.burnPerLaneHour = Format-PacingNumber $burn; $entry.burnSource = 'measured'
  $result.burn = $burn
  return $result
}

function Get-PacingCensus([string]$Path, [string]$Runtime, [string]$Container, [hashtable]$FamilyProvider) {
  # Live lanes per provider from the ownership census (activeLanes[].family
  # through the registry). A missing, malformed, unhealthy or unmappable
  # census is unknown; unknown never authorizes.
  $result = [ordered]@{status='unknown';source=$(if ($Path) { 'fixture' } else { 'live' });reason=$null;health=$null;activeLanes=0;unmapped=0;liveLanes=[ordered]@{claude=0;codex=0}}
  $census = $null
  try {
    if ($Path) {
      $census = [IO.File]::ReadAllText([IO.Path]::GetFullPath($Path)) | ConvertFrom-Json -Depth 100 -DateKind String -NoEnumerate -ErrorAction Stop
    } else {
      . (Join-Path $PSScriptRoot 'dispatch-ownership.ps1')
      $census = Get-LiveDispatchOwnership -RuntimeRoot $Runtime -TempRoot ([IO.Path]::GetTempPath()) -ContainerRoot $Container
    }
  } catch { $result.reason = 'CENSUS_UNAVAILABLE:' + $_.Exception.Message; return $result }
  $lanes = Get-PacingProperty $census 'activeLanes'
  if (-not (Test-PacingObject $census) -or $lanes -isnot [array]) { $result.reason = 'CENSUS_MALFORMED'; return $result }
  $health = Get-PacingProperty (Get-PacingProperty $census 'health') 'status'
  $result.health = if ($health -is [string]) { $health } else { $null }
  if ($result.health -cne 'ok') { $result.reason = 'CENSUS_UNHEALTHY'; return $result }
  foreach ($lane in $lanes) {
    $result.activeLanes += 1
    $provider = Resolve-PacingProvider $lane $FamilyProvider
    if ($provider) { $result.liveLanes[$provider] += 1 } else { $result.unmapped += 1 }
  }
  if ($result.unmapped -gt 0) { $result.reason = 'CENSUS_FAMILY_UNMAPPED'; return $result }
  $result.status = 'ok'
  return $result
}

function Get-PacingCreditTarget([string]$Provider, $Forecast, [DateTimeOffset]$Now, [double]$Burn) {
  # Pace is unvalidated forecast data. Only an in-force forecast and a fresh,
  # well-formed pace may raise the existing headroom budget (#9737).
  $entry = [ordered]@{paceSource='invalid';targetUnitsPerHour=$null;paceBudget=0;creditsLapsing=$null;nextCreditExpiry=$null}
  if ($Forecast.status -ceq 'absent') { $entry.paceSource='absent'; return $entry }
  if ($Forecast.status -ceq 'stale') { $entry.paceSource='stale'; return $entry }
  if ($Forecast.status -cne 'in-force') { return $entry }
  $providerForecast = Get-PacingProperty $Forecast.forecast.providers $Provider
  $expiries = Get-PacingProperty (Get-PacingProperty $providerForecast 'supply') 'creditExpiries'
  if ($expiries -is [array] -and $expiries.Count -gt 0) {
    try { $null = ConvertTo-PacingInstant $expiries[0]; $entry.nextCreditExpiry=$expiries[0] } catch { }
  }
  $pace = Get-PacingProperty $providerForecast 'pace'
  if ($null -eq $pace) { $entry.paceSource='absent'; return $entry }
  if (-not (Test-PacingObject $pace)) { return $entry }
  try { $computed = ConvertTo-PacingInstant (Get-PacingProperty $pace 'computedAt') } catch { return $entry }
  if ($computed -gt $Now) { return $entry }
  if (($Now - $computed).TotalMinutes -gt 15) { $entry.paceSource='stale'; return $entry }
  $demand = Get-PacingProperty $pace 'atDemand'
  if (-not (Test-PacingObject $demand)) { return $entry }
  foreach ($field in @('unitsPerHour','usedUnits','lostUnits','creditsUsed','creditsLapsing','shortHours')) {
    $value = Get-PacingProperty $demand $field
    if (-not (Test-PacingFiniteNumber $value) -or [double]$value -lt 0) { return $entry }
    if ($field -cin @('creditsUsed','creditsLapsing','shortHours') -and [Math]::Floor([double]$value) -ne [double]$value) { return $entry }
  }
  if (-not (Test-PacingHasProperty $demand 'firstShortAt')) { return $entry }
  if ($null -ne $demand.firstShortAt) { try { $null = ConvertTo-PacingInstant $demand.firstShortAt } catch { return $entry } }
  $steps = Get-PacingProperty $pace 'steps'
  if ($steps -isnot [array]) { return $entry }
  $lastReachable = $null
  foreach ($step in $steps) {
    if (-not (Test-PacingObject $step)) { return $entry }
    $credits = Get-PacingProperty $step 'credits'; $rate = Get-PacingProperty $step 'unitsPerHour'
    if (-not (Test-PacingFiniteNumber $credits) -or [double]$credits -lt 1 -or [Math]::Floor([double]$credits) -ne [double]$credits -or
        (Get-PacingProperty $step 'reachable') -isnot [bool] -or -not (Test-PacingHasProperty $step 'unitsPerHour')) { return $entry }
    if ($step.reachable) {
      if (-not (Test-PacingFiniteNumber $rate) -or [double]$rate -lt 0) { return $entry }
      $lastReachable = [double]$rate
    } elseif ($null -ne $rate) { return $entry }
    if ($null -ne (Get-PacingProperty $step 'spentBy')) { try { $null = ConvertTo-PacingInstant $step.spentBy } catch { return $entry } }
  }
  foreach ($field in @('fullUse','then')) { if (-not (Test-PacingHasProperty $pace $field)) { return $entry } }
  $fullUse = Get-PacingProperty $pace 'fullUse'; $then = Get-PacingProperty $pace 'then'
  foreach ($plan in @($fullUse,$then)) {
    if ($null -eq $plan) { continue }
    $rate = Get-PacingProperty $plan 'unitsPerHour'
    if (-not (Test-PacingObject $plan) -or -not (Test-PacingFiniteNumber $rate) -or [double]$rate -lt 0) { return $entry }
  }
  $thenFrom = $null
  if ($null -ne $then) { try { $thenFrom = ConvertTo-PacingInstant $then.from } catch { return $entry } }
  $entry.creditsLapsing = $demand.creditsLapsing
  if ($entry.creditsLapsing -eq 0) { $entry.paceSource='no-lapsing-credits'; return $entry }
  $target = if ($null -ne $fullUse) { [double]$fullUse.unitsPerHour } else { $lastReachable }
  if ($null -ne $then -and $Now -ge $thenFrom) { $target = [double]$then.unitsPerHour }
  if ($null -eq $target) { return $entry }
  $budget = [Math]::Floor($target / $Burn + 0.5)
  if (-not (Test-PacingFiniteNumber $budget) -or $budget -gt [int]::MaxValue) { return $entry }
  $entry.paceSource='pace'; $entry.targetUnitsPerHour=$target; $entry.paceBudget=[int]$budget
  return $entry
}

function Invoke-CapacityPacing {
  [CmdletBinding()]
  param(
    [string]$StatusPath, [string]$StatusUrl, [string]$StateRoot, [string]$LkgPath, [string]$CensusPath,
    [string]$RuntimeRoot, [string]$ContainerRoot, [string]$DispatchLogPath, [string]$TranscriptRoot, [string]$NowUtc
  )
  $now = if ($NowUtc) { ConvertTo-PacingInstant $NowUtc } else { [DateTimeOffset]::UtcNow }
  $runtime = if ($RuntimeRoot) { [IO.Path]::GetFullPath($RuntimeRoot) } else { $PSScriptRoot }
  $container = if ($ContainerRoot) { [IO.Path]::GetFullPath($ContainerRoot) } else { Split-Path -Parent $runtime }
  $logPath = if ($DispatchLogPath) { [IO.Path]::GetFullPath($DispatchLogPath) } else { Join-Path $runtime 'dispatch-log.jsonl' }
  $transcriptDir = if ($TranscriptRoot) { [IO.Path]::GetFullPath($TranscriptRoot) } else { Split-Path -Parent $logPath }
  $config = [ordered]@{}
  foreach ($key in $script:PacingConfig.Keys) { $config[$key] = $script:PacingConfig[$key] }

  $status = Read-PacingStatus $StatusPath $StatusUrl $now
  $registry = Get-PacingRegistryFamilies $StateRoot $LkgPath $now
  $forecast = Get-CapacityForecast -StateRoot $StateRoot -NowUtc $now
  $laneHours = Get-PacingLaneHours $logPath $transcriptDir $now $registry.families
  $census = Get-PacingCensus $CensusPath $runtime $container $registry.families

  $reasons = @()
  if ($status.status -cne 'ok') { $reasons += $status.reason }
  if ($registry.status -cne 'ok') { $reasons += $registry.reason }
  if ($census.status -cne 'ok') { $reasons += $census.reason }
  $overall = if ($reasons.Count -eq 0) { 'ok' } else { 'unknown' }
  $providerReason = if ($status.status -cne 'ok') { 'STATUS_UNKNOWN' } elseif ($overall -cne 'ok') { 'CENSUS_UNKNOWN' } else { $null }

  $providers = [ordered]@{}
  foreach ($provider in $script:PacingProviders) {
    $burn = Get-PacingBurn $provider $forecast ([double]$laneHours.hours[$provider])
    $accounts = @(); $sum = 0.0; $available = 0
    if ($status.status -ceq 'ok') {
      foreach ($account in @($status.accounts | Where-Object { (Get-PacingProperty $_ 'provider') -ceq $provider })) {
        $budget = Get-PacingAccountBudget $account $now $burn.burn $script:PacingConfig.reserve 'common'
        $accounts += $budget.entry
        if ($budget.entry.contributes) { $available += 1; $sum += $budget.lanes }
      }
    }
    $laneBudget = [int][Math]::Floor($sum + 0.5)
    $liveLanes = if ($census.status -ceq 'ok') { [int]$census.liveLanes[$provider] } else { 0 }
    $pace = Get-PacingCreditTarget $provider $forecast $now $burn.burn
    if ($overall -ceq 'ok' -and $available -gt 0 -and $pace.paceSource -ceq 'pace') {
      # Cap only the raise: never lower #9316's existing headroom budget.
      $laneBudget = [int][Math]::Max($laneBudget, [Math]::Min($pace.paceBudget, $liveLanes + 2))
    }
    $allowance = if ($overall -cne 'ok') { 0 } else { [Math]::Max(0, $laneBudget - $liveLanes) }
    $reason = if ($providerReason) { $providerReason } elseif ($available -eq 0) { 'NO_AVAILABLE_ACCOUNT' } else { $null }
    $entry = [ordered]@{
      burnPerLaneHour=$burn.entry.burnPerLaneHour;burnSource=$burn.entry.burnSource;burnReason=$burn.entry.burnReason
      demandUnitsPerHour=$burn.entry.demandUnitsPerHour;laneHours=$burn.entry.laneHours
      accounts=@($accounts);availableAccounts=$available;laneBudget=$laneBudget;liveLanes=$liveLanes
      newLaneAllowance=[int]$allowance;reason=$reason;fableLaneBudget=$null;fableLaneBudgetUncapped=$null;fableAccounts=@()
      paceSource=$pace.paceSource;targetUnitsPerHour=$pace.targetUnitsPerHour;paceBudget=$pace.paceBudget
      creditsLapsing=$pace.creditsLapsing;nextCreditExpiry=$pace.nextCreditExpiry
    }
    if ($provider -ceq 'claude') {
      $fableAccounts = @(); $fableSum = 0.0
      if ($status.status -ceq 'ok') {
        foreach ($account in @($status.accounts | Where-Object { (Get-PacingProperty $_ 'provider') -ceq $provider })) {
          $budget = Get-PacingAccountBudget $account $now $burn.burn $script:PacingConfig.reserve 'fable'
          $fableAccounts += $budget.entry
          if ($budget.entry.contributes) { $fableSum += $budget.lanes }
        }
      }
      $fableRounded = [int][Math]::Floor($fableSum + 0.5)
      $entry.fableLaneBudgetUncapped = $fableRounded
      $entry.fableLaneBudget = if ($overall -cne 'ok') { 0 } else { $fableRounded }
      $entry.fableAccounts = @($fableAccounts)
    }
    $providers[$provider] = $entry
  }

  return [ordered]@{
    format=$script:PacingSchema
    nowUtc=(Format-PacingInstant $now)
    status=$overall
    reasons=@($reasons)
    statusSource=$status.source;statusReason=$status.reason;statusCheckedAt=$status.checkedAt
    forecastStatus=$forecast.status
    registryStatus=$registry.status;registryReason=$registry.reason;registryAuthorityDigest=$registry.registryAuthorityDigest;usedLastKnownGood=$registry.usedLastKnownGood
    censusStatus=$census.status;censusSource=$census.source;censusReason=$census.reason;censusHealth=$census.health;censusActiveLanes=$census.activeLanes
    laneHours=$laneHours.diagnostics
    config=$config
    providers=$providers
  }
}

if (-not $script:PacingInvocation.Library) {
  $invocation = $script:PacingInvocation
  $result = Invoke-CapacityPacing -StatusPath $invocation.StatusPath -StatusUrl $invocation.StatusUrl -StateRoot $invocation.StateRoot `
    -LkgPath $invocation.LkgPath -CensusPath $invocation.CensusPath -RuntimeRoot $invocation.RuntimeRoot -ContainerRoot $invocation.ContainerRoot `
    -DispatchLogPath $invocation.DispatchLogPath -TranscriptRoot $invocation.TranscriptRoot -NowUtc $invocation.NowUtc
  $json = ($result | ConvertTo-Json -Depth 20).Replace("`r`n", "`n")
  if ($invocation.OutFile) {
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($invocation.OutFile), $json + "`n", [Text.UTF8Encoding]::new($false))
  }
  Write-Output $json
}
