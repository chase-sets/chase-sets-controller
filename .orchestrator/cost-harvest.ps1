<#
.SYNOPSIS
Harvest per-run cost and duration from lane stream-json transcripts into
cost-ledger.jsonl, so USD/artifact becomes computable from the loop's own
telemetry (model-routing SKILL.md, capability-matrix.json step 5).

WHY THIS EXISTS: dispatch-log.jsonl carries no cost or duration field — across
2,306 entries there was never one. Every cost figure the rubric quotes came from
`codeburn export`, which reports per-model DAILY AGGREGATES that cannot be joined
to a dispatch, a row, or an artifact. Meanwhile every Claude Code stream-json
`result` record has carried `total_cost_usd` and `duration_ms` the whole time.
This is a harvest of data we already had, not new instrumentation.

Cost is not knowable at dispatch time — it exists only once a run completes — so
it cannot be a log-event.ps1 parameter on the dispatch row. It is reconciled
afterwards, keyed by transcript, and joined to dispatch rows on issue/lane.

Idempotent: re-running skips transcripts already harvested at the same size
unless -Force. Safe to run on a cron or at the end of each lane.

.EXAMPLE
./cost-harvest.ps1                      # incremental harvest
./cost-harvest.ps1 -Backfill            # include every historical transcript
./cost-harvest.ps1 -Summary             # harvest, then print USD by model
#>
[CmdletBinding()]
param(
  # Harvest every transcript found, not just ones newer than the ledger.
  [switch]$Backfill,
  # Re-harvest transcripts already in the ledger (use after a parser fix).
  [switch]$Force,
  # Print a per-model / per-issue rollup after harvesting.
  [switch]$Summary,
  [switch]$Json,
  # Testing overrides; production reads/writes the canonical paths.
  [string]$TranscriptDir,
  [string]$Ledger
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "orchestration-log-lock.psm1") -Force -DisableNameChecking
. (Join-Path $PSScriptRoot 'routing-data.ps1') -Library
if (-not $TranscriptDir) { $TranscriptDir = $PSScriptRoot }
if (-not $Ledger) { $Ledger = Join-Path $PSScriptRoot "cost-ledger.jsonl" }

# Harvest is advisory. Missing routing authority degrades current-price
# telemetry, never the native reported cost or an effective-dated billed fact.
$routingData = $null
$routingSourceReason = $null
try { $routingData = Get-RoutingData } catch { $routingSourceReason = $_.Exception.Message }
$registryModelSet = if ($routingData) { @(Get-RoutingModelSet $routingData.registry) } else { @() }
$routingPricingIdentity = Get-RoutingPayloadDigest ([pscustomobject][ordered]@{
  benchmark=$(if ($routingData) { $routingData.benchmark } else { $null })
  policyGeneration=$(if ($routingData) { $routingData.policyGeneration } else { $null })
  registryAuthorityDigest=$(if ($routingData) { $routingData.registryAuthorityDigest } else { $null })
  registryModels=$registryModelSet
  usedLastKnownGood=$(if ($routingData) { $routingData.usedLastKnownGood } else { $false })
  sourceReason=$(if ($routingData) { $routingData.sourceReason } else { $routingSourceReason })
})

# Codex transcripts report TOKENS, not dollars:
#   usd        = billed-at-the-time estimate for spend governance
#   usdCurrent = unknown without current request-tier and cache authority
# Native reported USD retains its existing stream-json authority and source.
#
# Effective-dated prices below are historical billed estimates, not current
# routing prices. Current per-task estimates and standard token rates come
# only from the validated benchmark snapshot. That snapshot does not carry
# request-tier or cache rates, so it cannot authorize normalized token USD.
#
# OpenAI prices a REQUEST with >272K input tokens at 2x input / 1.5x output.
# Codex's turn.completed record is cumulative across the run, not per request.
# Therefore a cumulative run <=272K is provably short-context, while a larger
# historical run has an unknowable request-tier mix. Keep both billed bounds
# and use the historical long-tier upper bound for the billed estimate, not
# as current-price authority.
$codexPriceBaselineUtc = [datetime]::SpecifyKind(
  [datetime]"2026-01-01T00:00:00",
  [System.DateTimeKind]::Utc)
$codexPriceCutUtc = [datetime]::SpecifyKind(
  [datetime]"2026-07-30T00:00:00",
  [System.DateTimeKind]::Utc)
$codexPriceHistory = @{
  "claude-sonnet-5-5" = @(
    @{ effectiveUtc = [datetime]::SpecifyKind([datetime]"2026-09-28T00:00:00", [DateTimeKind]::Utc); shortInPerM = 2.00; shortOutPerM = 10.00; longInPerM = 2.00; longOutPerM = 10.00 }
  )
  "gpt-6.1-sol" = @(
    @{ effectiveUtc = [datetime]::SpecifyKind([datetime]"2026-09-29T00:00:00", [DateTimeKind]::Utc); shortInPerM = 2.00; shortOutPerM = 10.00; longInPerM = 4.00; longOutPerM = 15.00; cacheReadMultiplier = 0.05 }
  )
  "gpt-6-sol" = @( # historical pricing only
    @{ effectiveUtc = [datetime]::SpecifyKind([datetime]"2026-09-22T00:00:00", [DateTimeKind]::Utc); shortInPerM = 2.00; shortOutPerM = 10.00; longInPerM = 4.00; longOutPerM = 15.00 }
  )
  "gpt-6-luna" = @(
    @{ effectiveUtc = [datetime]::SpecifyKind([datetime]"2026-09-22T00:00:00", [DateTimeKind]::Utc); shortInPerM = 0.10; shortOutPerM = 0.50; longInPerM = 0.20; longOutPerM = 0.75 }
  )
  "gpt-6-astra" = @(
    @{ effectiveUtc = [datetime]::SpecifyKind([datetime]"2026-09-03T00:00:00", [DateTimeKind]::Utc); shortInPerM = 10.00; shortOutPerM = 50.00; longInPerM = 20.00; longOutPerM = 75.00 }
  )
  "gpt-5.6-sol" = @( # historical pricing only
    @{ effectiveUtc = $codexPriceBaselineUtc; shortInPerM = 5.00; shortOutPerM = 30.00; longInPerM = 10.00; longOutPerM = 45.00 }
  )
  "gpt-5.6-terra" = @( # historical pricing only
    @{ effectiveUtc = $codexPriceBaselineUtc; shortInPerM = 2.50; shortOutPerM = 15.00; longInPerM = 5.00; longOutPerM = 22.50 }
    @{ effectiveUtc = $codexPriceCutUtc; shortInPerM = 2.00; shortOutPerM = 12.00; longInPerM = 4.00; longOutPerM = 18.00 }
  )
  "gpt-5.6-luna" = @( # historical pricing only
    @{ effectiveUtc = $codexPriceBaselineUtc; shortInPerM = 1.00; shortOutPerM = 6.00; longInPerM = 2.00; longOutPerM = 9.00 }
    @{ effectiveUtc = $codexPriceCutUtc; shortInPerM = 0.20; shortOutPerM = 1.20; longInPerM = 0.40; longOutPerM = 1.80 }
  )
}
$historicalPricingModelSet = @($codexPriceHistory.Keys)
$longContextThresholdInputTokens = 272000
# Default cache economics: writes cost 1.25x base, reads 0.10x base.
$cacheWriteMultiplier = 1.25
$cacheReadMultiplier  = 0.10

function Get-BilledCodexPrice([string]$Model, [datetime]$CompletedUtc) {
  if (-not $Model -or -not $codexPriceHistory.ContainsKey($Model)) { return $null }
  $selected = $null
  foreach ($candidate in $codexPriceHistory[$Model]) {
    if ($candidate.effectiveUtc -le $CompletedUtc -and
        ($null -eq $selected -or $candidate.effectiveUtc -gt $selected.effectiveUtc)) {
      $selected = $candidate
    }
  }
  return $selected
}

function Get-CodexTokenCost($Facts, [double]$InPerM, [double]$OutPerM, [double]$CacheReadMultiplier) {
  if ($null -eq $InPerM -or $null -eq $OutPerM) { return $null }
  $cached = [double]($Facts.cachedInputTokens ?? 0)
  $wrote  = [double]($Facts.cacheWriteInputTokens ?? 0)
  # input_tokens is the TOTAL and already contains the cached and cache-write
  # portions; only the remainder bills at full rate.
  $plain = [math]::Max(0.0, [double]$Facts.inputTokens - $cached - $wrote)
  $out   = [double]($Facts.outputTokens ?? 0)

  return [math]::Round(
    ($plain  * $InPerM / 1e6) +
    ($cached * $InPerM * $CacheReadMultiplier  / 1e6) +
    ($wrote  * $InPerM * $cacheWriteMultiplier / 1e6) +
    ($out    * $OutPerM / 1e6), 4)
}

function Get-CacheReadMultiplier($Price) {
  if ($null -ne $Price.cacheReadMultiplier) { return [double]$Price.cacheReadMultiplier }
  return $cacheReadMultiplier
}

function Get-HarvestBenchmarkFacts([string]$Model, [string]$Effort) {
  $result = [ordered]@{usdPerTask=$null;inputPerM=$null;outputPerM=$null;reason=$null}
  if (-not $routingData) { $result.reason='ROUTING_DATA_UNAVAILABLE'; return $result }
  if (-not $Model) { $result.reason='BENCHMARK_MODEL_UNRESOLVED'; return $result }
  if (-not (Get-RoutingModelIdentity $routingData.registry $Model)) { $result.reason='MODEL_NOT_IN_REGISTRY'; return $result }
  $rows = @($routingData.benchmark.snapshot.rows | Where-Object { $_.model -ceq $Model })
  if ($Effort) {
    $rows = @($rows | Where-Object { $_.effort -ceq $Effort })
    if ($rows.Count -ne 1) { $result.reason='BENCHMARK_CONFIGURATION_UNPRICED'; return $result }
    $price = Get-RoutingBenchmarkPrice $routingData $Model $Effort
    $result.usdPerTask = $price.usdPerTask
  }
  if ($rows.Count -eq 0) { $result.reason='BENCHMARK_MODEL_UNPRICED'; return $result }
  # With no exact effort, token rates are usable only when every same-model
  # row agrees. Per-task USD is never pooled across effort configurations.
  $rates = @()
  foreach ($row in $rows) {
    $inputRate = $row.pricing.price_1m_input_tokens
    $outputRate = $row.pricing.price_1m_output_tokens
    foreach ($rate in @($inputRate,$outputRate)) {
      if ($rate -isnot [ValueType] -or $rate -is [bool] -or
          [double]::IsNaN([double]$rate) -or [double]::IsInfinity([double]$rate) -or [double]$rate -lt 0) {
        $result.reason='BENCHMARK_STANDARD_PRICE_INVALID'; return $result
      }
    }
    $rates += [pscustomobject]@{input=[double]$inputRate;output=[double]$outputRate}
  }
  if (@($rates | Where-Object { $_.input -ne $rates[0].input -or $_.output -ne $rates[0].output }).Count) {
    $result.reason='BENCHMARK_STANDARD_PRICE_AMBIGUOUS'; return $result
  }
  $result.inputPerM = $rates[0].input
  $result.outputPerM = $rates[0].output
  $result.reason = 'BENCHMARK_CONTEXT_CACHE_RATES_UNAVAILABLE'
  return $result
}

# ---------------------------------------------------------------- existing ---
$already = @{}
if (Test-Path -LiteralPath $Ledger) {
  foreach ($line in (Get-Content -LiteralPath $Ledger -ErrorAction SilentlyContinue)) {
    if (-not $line.Trim()) { continue }
    try { $row = $line | ConvertFrom-Json } catch { continue }
    if ($row.transcript) { $already[$row.transcript] = $row }
  }
}

# ------------------------------------------------------------------ parse ---
function Get-UsableTokenCount($Value) {
  if ($Value -is [double] -or $Value -is [single]) {
    # The floating-point representation of Int64.MaxValue rounds up to 2^63.
    if ([double]::IsNaN($Value) -or [double]::IsInfinity($Value) -or
        $Value -lt 0 -or $Value -ge 9223372036854775808.0 -or
        [math]::Truncate($Value) -ne $Value) { return $null }
    return [long]$Value
  }
  if ($Value -isnot [sbyte] -and $Value -isnot [byte] -and
      $Value -isnot [short] -and $Value -isnot [ushort] -and
      $Value -isnot [int] -and $Value -isnot [uint] -and
      $Value -isnot [long] -and $Value -isnot [ulong] -and
      $Value -isnot [bigint] -and $Value -isnot [decimal]) { return $null }
  if ($Value -lt 0 -or $Value -gt [long]::MaxValue) { return $null }
  if ($Value -is [decimal] -and [decimal]::Truncate($Value) -ne $Value) { return $null }
  return [long]$Value
}

function Get-RunFacts {
  param([string]$Path)

  $facts = [ordered]@{
    usd = $null; usdCurrent = $null
    usdLower = $null; usdUpper = $null
    usdCurrentLower = $null; usdCurrentUpper = $null
    durationSec = $null; durationApiSec = $null
    numTurns = $null; model = $null; effort = $null; isError = $null; subtype = $null
    costSource = "none"; routingCostSource = "none"; durationSrc = $null
    billedPriceEffectiveUtc = $null
    billedPriceInPerM = $null; billedPriceOutPerM = $null
    currentPriceInPerM = $null; currentPriceOutPerM = $null
    pricingContextTier = $null
    pricingContextThresholdInputTokens = $longContextThresholdInputTokens
    inputTokens = $null; cachedInputTokens = $null
    cacheWriteInputTokens = $null; outputTokens = $null; reasoningOutputTokens = $null
  }

  # Transcripts run to hundreds of MB; stream rather than Get-Content -Raw.
  # FileShare::ReadWrite is REQUIRED: live lanes hold their transcript open for
  # append, and an exclusive handle here would both fail the harvest and risk
  # contending with running work. Harvesting must never disturb a live lane.
  $stream = [System.IO.FileStream]::new(
    $Path,
    [System.IO.FileMode]::Open,
    [System.IO.FileAccess]::Read,
    [System.IO.FileShare]::ReadWrite)
  $reader = [System.IO.StreamReader]::new($stream)
  try {
    while ($null -ne ($line = $reader.ReadLine())) {
      if (-not $line.StartsWith("{")) { continue }

      # Cheap prefilter — full ConvertFrom-Json on every line of every
      # transcript is the difference between seconds and many minutes.
      $isInit   = $line.Contains('"subtype":"init"')
      $isResult = $line.Contains('"type":"result"')
      $isTurn   = $line.Contains('"type":"turn.completed"')
      if (-not ($isInit -or $isResult -or $isTurn)) { continue }

      try { $obj = $line | ConvertFrom-Json } catch { continue }

      if ($isInit -and -not $facts.model -and $obj.model) {
        $facts.model = [string]$obj.model
      }

      # Codex: one turn.completed per session carrying cumulative token usage.
      # No dollar figure is emitted, so cost is derived from the price table.
      if ($isTurn -and $obj.usage) {
        $u = $obj.usage
        if ($null -ne $u.input_tokens)            { $facts.inputTokens = [long]$u.input_tokens }
        if ($null -ne $u.cached_input_tokens)     { $facts.cachedInputTokens = [long]$u.cached_input_tokens }
        if ($null -ne $u.cache_write_input_tokens){ $facts.cacheWriteInputTokens = [long]$u.cache_write_input_tokens }
        if ($null -ne $u.output_tokens)           { $facts.outputTokens = [long]$u.output_tokens }
        # reasoning_output_tokens is a SUBSET of output_tokens — billed as
        # output and already counted there. Recorded for visibility, never
        # added to the cost or it double-charges reasoning.
        if ($null -ne $u.reasoning_output_tokens) { $facts.reasoningOutputTokens = [long]$u.reasoning_output_tokens }
      }
      if ($isResult -and $obj.type -eq "result") {
        # Last result record wins — resumed sessions emit more than one.
        if ($null -ne $obj.total_cost_usd) {
          $facts.usd = [double]$obj.total_cost_usd
          $facts.usdCurrent = $facts.usd
          $facts.costSource = "stream-json"
          $facts.routingCostSource = "stream-json"
        }
        # Last terminal usage wins, including unknown fields. Input is inclusive
        # only when all three components and their sum fit; reasoning is a subset
        # of output, not an extra charge. Reported USD remains authoritative.
        $u = $obj.usage
        $plain = Get-UsableTokenCount $u.input_tokens
        $read = Get-UsableTokenCount $u.cache_read_input_tokens
        $wrote = Get-UsableTokenCount $u.cache_creation_input_tokens
        $facts.inputTokens = $null
        $facts.cachedInputTokens = $read
        $facts.cacheWriteInputTokens = $wrote
        $facts.outputTokens = Get-UsableTokenCount $u.output_tokens
        $facts.reasoningOutputTokens = Get-UsableTokenCount $u.output_tokens_details.thinking_tokens
        if ($null -ne $plain -and $null -ne $read -and $null -ne $wrote) {
          $total = [decimal]$plain + [decimal]$read + [decimal]$wrote
          if ($total -le [long]::MaxValue) { $facts.inputTokens = [long]$total }
        }
        if ($null -ne $obj.duration_ms)     { $facts.durationSec = [math]::Round([double]$obj.duration_ms / 1000, 1); $facts.durationSrc = "stream-json" }
        if ($null -ne $obj.duration_api_ms) { $facts.durationApiSec = [math]::Round([double]$obj.duration_api_ms / 1000, 1) }
        if ($null -ne $obj.num_turns)       { $facts.numTurns = [int]$obj.num_turns }
        if ($null -ne $obj.is_error)        { $facts.isError = [bool]$obj.is_error }
        if ($obj.subtype)                   { $facts.subtype = [string]$obj.subtype }
      }
    }
  }
  finally { $reader.Dispose() }

  return $facts
}

# Filenames encode intent by convention, e.g.
#   lane-01-5883-fable-final.jsonl · 6046-sol-block-repair.jsonl
# Issue/PR number is the first 3-5 digit run that is not a lane ordinal.
function Get-NameFacts {
  param([string]$Name)

  $out = [ordered]@{ issue = $null; lane = $null; slug = $null; model = $null; effort = $null }
  $base = [System.IO.Path]::GetFileNameWithoutExtension($Name)

  if ($base -match '^(lane-\d{2})-') { $out.lane = $Matches[1] }

  $stripped = if ($out.lane) { $base -replace '^lane-\d{2}-', '' } else { $base }
  if ($stripped -match '(\d{3,5})') { $out.issue = [int]$Matches[1] }
  $out.slug = $stripped

  # Look ahead so adjacent labels sharing a hyphen boundary are all counted.
  # The short historical token inside a full selector is not a second label.
  # Billed-history identities remain parsable if current routing data is lost.
  # This frozen evidence grammar is not a selectable-model allowlist.
  $exactModelSet = @(@($registryModelSet)+@($historicalPricingModelSet) | Where-Object { $_ } | Sort-Object -Unique -CaseSensitive)
  $exactSelectors = @($exactModelSet | ForEach-Object { [regex]::Escape($_) }) -join '|'
  # These versioned shorthands are frozen historical filename grammars. They
  # never follow a family's current ID and never grant dispatch admission.
  $modern = (@($exactSelectors,'astra6|sol61|sol6|luna6|opus55|sonnet55|fable51') | Where-Object { $_ }) -join '|'
  $found = @([regex]::Matches($stripped, "(?=(?:^|-)(?<selector>$modern)(?:--|$))") |
    ForEach-Object { $_.Groups['selector'] })
  $found += @([regex]::Matches($stripped, '(?=(?:^|-)(?<selector>gpt-5\.6-(?:sol|terra|luna))(?=-|$))', 'IgnoreCase') |
    ForEach-Object { $_.Groups['selector'] })
  $found += @([regex]::Matches($stripped, '(?=(?:^|-)(?<!gpt-[^-]+-)(?<selector>sol|terra|luna)(?=-|$))', 'IgnoreCase') |
    ForEach-Object { $_.Groups['selector'] })
  $found += @([regex]::Matches($stripped, '(?=(?:^|-)(?<selector>opus5|sonnet5|fable5(?:\.1|1)?)(?=-|$))', 'IgnoreCase') |
    ForEach-Object { $_.Groups['selector'] })
  $models = @($found | ForEach-Object {
    if ($exactModelSet -ccontains $_.Value) { $_.Value; return }
    switch -CaseSensitive -Regex ($_.Value) {
      '^astra6$' { 'gpt-6-astra'; break }
      '^sol61$' { 'gpt-6.1-sol'; break }
      '^sol6$' { 'gpt-6-sol'; break }
      '^luna6$' { 'gpt-6-luna'; break }
      '^opus55$' { 'claude-opus-5-5'; break }
      '^sonnet55$' { 'claude-sonnet-5-5'; break }
      '^fable51$' { 'claude-fable-5-1'; break }
      default {
        if ($_ -match 'gpt-5\.6-(sol|terra|luna)$') { "gpt-5.6-$($Matches[1].ToLowerInvariant())" }
        elseif ($_ -match '^(sol|terra|luna)$') { "gpt-5.6-$($_.ToLowerInvariant())" }
        elseif ($_ -match '^fable5(\.1|1)$') { 'claude-fable-5-1' }
        elseif ($_ -match '^fable5$') { 'claude-fable-5' }
        elseif ($_ -match '^opus5$') { 'claude-opus-5' }
        else { 'claude-sonnet-5' }
      }
    }
  } | Select-Object -Unique)
  $efforts = @($found | ForEach-Object {
    $tail = $stripped.Substring($_.Index + $_.Length)
    if ($tail -cmatch '^--(low|medium|high|xhigh|max)(-|$)') { $Matches[1] }
    elseif ($_.Value -match '^(gpt-5\.6-|sol$|terra$|luna$|opus5$|sonnet5$|fable5)' -and $tail -match '^-(minimal|low|medium|high|xhigh|max)(-|$)') { $Matches[1].ToLowerInvariant() }
  } | Select-Object -Unique)
  if ($models.Count -gt 1 -or $efforts.Count -gt 1) { return $out }
  if ($models.Count -eq 1) {
    # Never reinterpret an unsupported versioned selector as a legacy alias.
    $legacyOnly = @($found | Where-Object { $_.Value -match '^(sol|terra|luna)$' }).Count -eq $found.Count
    if ($legacyOnly -and $stripped -match '(^|-)(gpt-[0-9]|sol6|luna6|astra6)') { return $out }
    $out.model = $models[0]
    if ($efforts.Count -eq 1) { $out.effort = $efforts[0] }
  }

  return $out
}

# dispatch-lane.ps1 records every launch as a dispatch row carrying the exact
# transcript name and model. That exact binding attributes transcripts whose
# filenames carry no model label (goal-*, controller-*), which otherwise carry
# tokens with no price and drop out of every per-model comparison. It is a
# recorded fact, not a filename guess; a transcript bound to two different
# models is ambiguous and stays unattributed.
function Get-DispatchModels {
  param([string]$Path)
  $models = @{}
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $models }
  $ambiguous = @{}
  $stream = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
  $reader = [System.IO.StreamReader]::new($stream)
  try {
    while ($null -ne ($line = $reader.ReadLine())) {
      if (-not $line.Contains('"kind":"dispatch"') -or -not $line.Contains('"transcript"')) { continue }
      try { $row = $line | ConvertFrom-Json } catch { continue }
      if ($row.kind -ne "dispatch" -or -not $row.transcript -or -not $row.model) { continue }
      $transcript = [string]$row.transcript
      $effort = if ($row.effort -cin @('minimal','low','medium','high','xhigh','max')) { [string]$row.effort } else { $null }
      if ($models.ContainsKey($transcript)) {
        if ($models[$transcript].model -cne [string]$row.model) { $ambiguous[$transcript] = $true }
        if ($models[$transcript].effort -cne $effort) { $models[$transcript].effort = $null }
      } else {
        $models[$transcript] = [pscustomobject]@{model=[string]$row.model;effort=$effort}
      }
      $models[$transcript].model = [string]$row.model
    }
  }
  finally { $reader.Dispose() }
  foreach ($key in @($ambiguous.Keys)) { $models.Remove($key) }
  return $models
}

# ---------------------------------------------------------------- harvest ---
$dispatchModels = Get-DispatchModels -Path (Join-Path $TranscriptDir "dispatch-log.jsonl")
$transcripts = Get-ChildItem -LiteralPath $TranscriptDir -Filter "*.jsonl" -File |
  Where-Object { $_.Name -notin @("dispatch-log.jsonl", "flow-log.jsonl", "cost-ledger.jsonl") }

$harvested = @()
$skipped = 0
foreach ($t in $transcripts) {
  $binding = if ($dispatchModels.ContainsKey($t.Name)) { $dispatchModels[$t.Name] } else { $null }
  $bindingIdentity = Get-RoutingPayloadDigest $binding
  $samePriceAuthority = $already.ContainsKey($t.Name) -and
    $already[$t.Name].routingPricingIdentity -ceq $routingPricingIdentity -and
    $already[$t.Name].dispatchBindingIdentity -ceq $bindingIdentity
  if (-not $Force -and $samePriceAuthority -and $already[$t.Name].bytes -eq $t.Length) {
    $skipped++
    continue
  }
  if (-not $Backfill -and -not $Force -and $samePriceAuthority) { $skipped++; continue }

  $facts = Get-RunFacts -Path $t.FullName
  $name  = Get-NameFacts -Name $t.Name
  if (-not $facts.model) {
    if ($name.model) { $facts.model = $name.model }
    elseif ($binding) { $facts.model = $binding.model }
  }
  if ($name.model -ceq $facts.model -and $name.effort) { $facts.effort = $name.effort }
  elseif ($binding -and $binding.model -ceq $facts.model) { $facts.effort = $binding.effort }
  $benchmarkFacts = Get-HarvestBenchmarkFacts $facts.model $facts.effort
  $facts.currentPriceInPerM = $benchmarkFacts.inputPerM
  $facts.currentPriceOutPerM = $benchmarkFacts.outputPerM

  # --- Codex: derive cost from tokens ---------------------------------------
  # Claude reports dollars directly; Codex reports only tokens, so without this
  # Sol/Terra/Luna spend is invisible and any cheapest-clearing comparison that
  # spans harnesses is invalid.
  if ($null -eq $facts.usd -and $null -ne $facts.inputTokens) {
    $billedPrice = Get-BilledCodexPrice -Model $facts.model -CompletedUtc $t.LastWriteTimeUtc
    if ($billedPrice) {
      $billedReadMultiplier = Get-CacheReadMultiplier $billedPrice
      $billedShort = Get-CodexTokenCost -Facts $facts -InPerM $billedPrice.shortInPerM -OutPerM $billedPrice.shortOutPerM -CacheReadMultiplier $billedReadMultiplier
      $billedLong = Get-CodexTokenCost -Facts $facts -InPerM $billedPrice.longInPerM -OutPerM $billedPrice.longOutPerM -CacheReadMultiplier $billedReadMultiplier
      $provablyShort = [long]$facts.inputTokens -le $longContextThresholdInputTokens

      $facts.usdLower = $billedShort
      $facts.usdUpper = if ($provablyShort) { $billedShort } else { $billedLong }
      $facts.usd = $facts.usdUpper
      $facts.billedPriceEffectiveUtc = $billedPrice.effectiveUtc.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
      if ($provablyShort) {
        $facts.pricingContextTier = "short-exact"
        $facts.costSource = "token-derived-short-exact"
        $facts.billedPriceInPerM = $billedPrice.shortInPerM
        $facts.billedPriceOutPerM = $billedPrice.shortOutPerM
      } else {
        $facts.pricingContextTier = "request-tier-unknown-conservative-long"
        $facts.costSource = "token-derived-long-upper-bound"
        $facts.billedPriceInPerM = $billedPrice.longInPerM
        $facts.billedPriceOutPerM = $billedPrice.longOutPerM
      }
    } else {
      $facts.costSource = if ($facts.model) { 'tokens-no-billed-price' } else { 'tokens-no-model' }
    }
    $facts.routingCostSource = if ($facts.model) { $benchmarkFacts.reason } else { 'tokens-no-model' }
  }

  # Codex emits no wall-clock. The file's write span is a defensible proxy for
  # run duration — tagged so it is never confused with a measured figure.
  if ($null -eq $facts.durationSec -and $t.CreationTimeUtc -lt $t.LastWriteTimeUtc) {
    $span = ($t.LastWriteTimeUtc - $t.CreationTimeUtc).TotalSeconds
    if ($span -gt 0 -and $span -lt 86400) {
      $facts.durationSec = [math]::Round($span, 1)
      $facts.durationSrc = "file-span-estimate"
    }
  }

  $row = [ordered]@{
    ts             = $t.LastWriteTimeUtc.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
    transcript     = $t.Name
    bytes          = $t.Length
    issue          = $name.issue
    lane           = $name.lane
    slug           = $name.slug
    model          = $facts.model
    effort         = $facts.effort
    usd            = $facts.usd
    usdCurrent     = $facts.usdCurrent
    usdLower       = $facts.usdLower
    usdUpper       = $facts.usdUpper
    usdCurrentLower = $facts.usdCurrentLower
    usdCurrentUpper = $facts.usdCurrentUpper
    durationSec    = $facts.durationSec
    durationApiSec = $facts.durationApiSec
    numTurns       = $facts.numTurns
    isError        = $facts.isError
    subtype        = $facts.subtype
    costSource     = $facts.costSource
    routingCostSource = $facts.routingCostSource
    durationSrc    = $facts.durationSrc
    inputTokens    = $facts.inputTokens
    outputTokens   = $facts.outputTokens
    reasoningOutputTokens = $facts.reasoningOutputTokens
    cachedInputTokens = $facts.cachedInputTokens
    cacheWriteInputTokens = $facts.cacheWriteInputTokens
    billedPriceEffectiveUtc = $facts.billedPriceEffectiveUtc
    billedPriceInPerM = $facts.billedPriceInPerM
    billedPriceOutPerM = $facts.billedPriceOutPerM
    currentPriceInPerM = $facts.currentPriceInPerM
    currentPriceOutPerM = $facts.currentPriceOutPerM
    benchmarkPriceBasis = 'standard-input-output-only'
    benchmarkUsdPerTask = $benchmarkFacts.usdPerTask
    benchmarkPricingReason = $benchmarkFacts.reason
    benchmarkSnapshot = $(if ($routingData) { $routingData.benchmark.latest.file } else { $null })
    policyGeneration = $(if ($routingData) { $routingData.policyGeneration } else { $null })
    registryAuthorityDigest = $(if ($routingData) { $routingData.registryAuthorityDigest } else { $null })
    usedLastKnownGood = $(if ($routingData) { $routingData.usedLastKnownGood } else { $false })
    routingSourceReason = $(if ($routingData) { $routingData.sourceReason } else { $routingSourceReason })
    routingPricingIdentity = $routingPricingIdentity
    dispatchBindingIdentity = $bindingIdentity
    pricingContextTier = $facts.pricingContextTier
    pricingContextThresholdInputTokens = $facts.pricingContextThresholdInputTokens
  }
  $harvested += [pscustomobject]$row
}

if ($harvested.Count -gt 0) {
  Invoke-WithOrchestrationLogLock -Body {
    foreach ($row in $harvested) {
      Add-Content -LiteralPath $Ledger -Encoding utf8 -Value ($row | ConvertTo-Json -Compress -Depth 4)
    }
  }
}

# ---------------------------------------------------------------- rollup ---
$all = @()
if (Test-Path -LiteralPath $Ledger) {
  foreach ($line in (Get-Content -LiteralPath $Ledger)) {
    if (-not $line.Trim()) { continue }
    try { $all += ($line | ConvertFrom-Json) } catch { continue }
  }
}
# De-dupe: later rows for the same transcript supersede earlier ones.
$latest = @{}
foreach ($r in $all) { $latest[$r.transcript] = $r }
$rows = $latest.Values

$withCost = @($rows | Where-Object { $null -ne $_.usd })
$totalUsd = ($withCost | Measure-Object -Property usd -Sum).Sum
if (-not $totalUsd) { $totalUsd = 0 }

function Get-Median([double[]]$Values) {
  if (-not $Values -or $Values.Count -eq 0) { return $null }
  $s = $Values | Sort-Object
  $mid = [math]::Floor($s.Count / 2)
  if ($s.Count % 2 -eq 1) { return $s[$mid] }
  return (($s[$mid - 1] + $s[$mid]) / 2)
}

$byModel = $withCost | Group-Object model | ForEach-Object {
  $sum  = ($_.Group | Measure-Object -Property usd -Sum).Sum
  $durs = @($_.Group | Where-Object { $_.durationSec } | ForEach-Object { [double]$_.durationSec })
  $med  = Get-Median $durs
  [pscustomobject]@{
    model     = if ($_.Name) { $_.Name } else { "(unknown)" }
    runs      = $_.Count
    usd       = [math]::Round($sum, 2)
    usdPerRun = [math]::Round($sum / $_.Count, 2)
    # Speed is the third optimization axis alongside correctness and cost.
    medMin    = if ($null -ne $med) { [math]::Round($med / 60, 1) } else { $null }
    usdPerMin = if ($null -ne $med -and $med -gt 0) { [math]::Round(($sum / $_.Count) / ($med / 60), 2) } else { $null }
    costSrc   = (($_.Group.costSource | Sort-Object -Unique) -join ",")
  }
} | Sort-Object -Property usd -Descending

$result = [ordered]@{
  ledger           = $Ledger
  harvestedNow     = $harvested.Count
  skipped          = $skipped
  transcriptsTotal = @($rows).Count
  withCost         = $withCost.Count
  withoutCost      = @($rows).Count - $withCost.Count
  totalUsd         = [math]::Round($totalUsd, 2)
  byModel          = @($byModel)
}

if ($Json) {
  $result | ConvertTo-Json -Depth 6
  return
}

Write-Output "cost-harvest: +$($harvested.Count) harvested, $skipped skipped, $($result.transcriptsTotal) transcripts in ledger"
Write-Output "  cost attributed: $($withCost.Count) runs, `$$($result.totalUsd) total"
Write-Output "  no cost record:  $($result.withoutCost) runs (codex transcripts and aborted sessions do not emit one)"

if ($Summary) {
  Write-Output ""
  Write-Output "USD by model:"
  $byModel | Format-Table -AutoSize | Out-String -Width 200 | Write-Output

  Write-Output "Top 10 runs by cost:"
  $withCost | Sort-Object -Property usd -Descending | Select-Object -First 10 |
    Select-Object @{n='usd';e={[math]::Round($_.usd,2)}}, model, issue, @{n='min';e={[math]::Round($_.durationSec/60,1)}}, transcript |
    Format-Table -AutoSize | Out-String -Width 200 | Write-Output
}
