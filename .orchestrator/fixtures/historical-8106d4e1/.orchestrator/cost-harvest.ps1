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
if (-not $TranscriptDir) { $TranscriptDir = $PSScriptRoot }
if (-not $Ledger) { $Ledger = Join-Path $PSScriptRoot "cost-ledger.jsonl" }

# Codex transcripts report TOKENS, not dollars, so two cost bases are derived:
#   usd        = billed-at-the-time estimate for spend governance
#   usdCurrent = the same token trace repriced at today's rates for routing
#
# Keep BOTH tables in step with model-routing/SKILL.md. A timeless price table
# cannot serve both purposes: preserving old prices makes today's frontier
# wrong, while rewriting history makes spend governance wrong.
#
# OpenAI prices a REQUEST with >272K input tokens at 2x input / 1.5x output.
# Codex's turn.completed record is cumulative across the run, not per request.
# Therefore a cumulative run <=272K is provably short-context, while a larger
# historical run has an unknowable request-tier mix. Keep both bounds and use
# the conservative long-tier upper bound for the routing point estimate rather
# than silently understating it.
$currentCodexPrices = @{
  "gpt-6-astra"   = @{ shortInPerM = 10.00; shortOutPerM = 50.00; longInPerM = 20.00; longOutPerM = 75.00 }
  "gpt-5.6-sol"   = @{ shortInPerM = 5.00; shortOutPerM = 30.00; longInPerM = 10.00; longOutPerM = 45.00 }
  "gpt-5.6-terra" = @{ shortInPerM = 2.00; shortOutPerM = 12.00; longInPerM =  4.00; longOutPerM = 18.00 }
  "gpt-5.6-luna"  = @{ shortInPerM = 0.20; shortOutPerM =  1.20; longInPerM =  0.40; longOutPerM =  1.80 }
}
$codexPriceBaselineUtc = [datetime]::SpecifyKind(
  [datetime]"2026-01-01T00:00:00",
  [System.DateTimeKind]::Utc)
$codexPriceCutUtc = [datetime]::SpecifyKind(
  [datetime]"2026-07-30T00:00:00",
  [System.DateTimeKind]::Utc)
$codexPriceHistory = @{
  "gpt-6-astra" = @(
    @{ effectiveUtc = [datetime]::SpecifyKind([datetime]"2026-09-03T00:00:00", [DateTimeKind]::Utc); shortInPerM = 10.00; shortOutPerM = 50.00; longInPerM = 20.00; longOutPerM = 75.00 }
  )
  "gpt-5.6-sol" = @(
    @{ effectiveUtc = $codexPriceBaselineUtc; shortInPerM = 5.00; shortOutPerM = 30.00; longInPerM = 10.00; longOutPerM = 45.00 }
  )
  "gpt-5.6-terra" = @(
    @{ effectiveUtc = $codexPriceBaselineUtc; shortInPerM = 2.50; shortOutPerM = 15.00; longInPerM = 5.00; longOutPerM = 22.50 }
    @{ effectiveUtc = $codexPriceCutUtc; shortInPerM = 2.00; shortOutPerM = 12.00; longInPerM = 4.00; longOutPerM = 18.00 }
  )
  "gpt-5.6-luna" = @(
    @{ effectiveUtc = $codexPriceBaselineUtc; shortInPerM = 1.00; shortOutPerM = 6.00; longInPerM = 2.00; longOutPerM = 9.00 }
    @{ effectiveUtc = $codexPriceCutUtc; shortInPerM = 0.20; shortOutPerM = 1.20; longInPerM = 0.40; longOutPerM = 1.80 }
  )
}
$longContextThresholdInputTokens = 272000
# GPT-5.6 cache economics: writes cost 1.25x base, reads 0.10x base.
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

function Get-CodexTokenCost($Facts, [double]$InPerM, [double]$OutPerM) {
  if ($null -eq $InPerM -or $null -eq $OutPerM) { return $null }
  $cached = [double]($Facts.cachedInputTokens ?? 0)
  $wrote  = [double]($Facts.cacheWriteInputTokens ?? 0)
  # input_tokens is the TOTAL and already contains the cached and cache-write
  # portions; only the remainder bills at full rate.
  $plain = [math]::Max(0.0, [double]$Facts.inputTokens - $cached - $wrote)
  $out   = [double]($Facts.outputTokens ?? 0)

  return [math]::Round(
    ($plain  * $InPerM / 1e6) +
    ($cached * $InPerM * $cacheReadMultiplier  / 1e6) +
    ($wrote  * $InPerM * $cacheWriteMultiplier / 1e6) +
    ($out    * $OutPerM / 1e6), 4)
}

# ---------------------------------------------------------------- existing ---
$already = @{}
if (Test-Path -LiteralPath $Ledger) {
  foreach ($line in (Get-Content -LiteralPath $Ledger -ErrorAction SilentlyContinue)) {
    if (-not $line.Trim()) { continue }
    try { $row = $line | ConvertFrom-Json } catch { continue }
    if ($row.transcript) { $already[$row.transcript] = $row.bytes }
  }
}

# ------------------------------------------------------------------ parse ---
function Get-RunFacts {
  param([string]$Path)

  $facts = [ordered]@{
    usd = $null; usdCurrent = $null
    usdLower = $null; usdUpper = $null
    usdCurrentLower = $null; usdCurrentUpper = $null
    durationSec = $null; durationApiSec = $null
    numTurns = $null; model = $null; isError = $null; subtype = $null
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

  $out = [ordered]@{ issue = $null; lane = $null; slug = $null; model = $null }
  $base = [System.IO.Path]::GetFileNameWithoutExtension($Name)

  if ($base -match '^(lane-\d{2})-') { $out.lane = $Matches[1] }

  $stripped = if ($out.lane) { $base -replace '^lane-\d{2}-', '' } else { $base }
  if ($stripped -match '(\d{3,5})') { $out.issue = [int]$Matches[1] }

  # Codex transcripts carry no init record, so the model comes from the naming
  # convention. Astra's selector is closed by end-of-name or the unambiguous
  # double-hyphen label delimiter; a single hyphen may continue an unsupported
  # model identity and therefore cannot establish price authority. Legacy
  # Sol/Terra/Luna labels retain their established single-hyphen convention.
  # An unmatched name yields tokens with no price rather than a guessed model.
  if ($stripped -cmatch '(^|-)(gpt-6-astra|astra6)(--|$)') {
    $out.model = 'gpt-6-astra'
  }
  elseif ($stripped -match '(^|-)(sol|terra|luna)(-|$)') {
    $out.model = "gpt-5.6-$($Matches[2])"
  }

  $out.slug = $stripped
  return $out
}

# ---------------------------------------------------------------- harvest ---
$transcripts = Get-ChildItem -LiteralPath $TranscriptDir -Filter "*.jsonl" -File |
  Where-Object { $_.Name -notin @("dispatch-log.jsonl", "flow-log.jsonl", "cost-ledger.jsonl") }

$harvested = @()
$skipped = 0
foreach ($t in $transcripts) {
  if (-not $Force -and $already.ContainsKey($t.Name) -and $already[$t.Name] -eq $t.Length) {
    $skipped++
    continue
  }
  if (-not $Backfill -and -not $Force -and $already.ContainsKey($t.Name)) { $skipped++; continue }

  $facts = Get-RunFacts -Path $t.FullName
  $name  = Get-NameFacts -Name $t.Name

  # --- Codex: derive cost from tokens ---------------------------------------
  # Claude reports dollars directly; Codex reports only tokens, so without this
  # Sol/Terra/Luna spend is invisible and any cheapest-clearing comparison that
  # spans harnesses is invalid.
  if ($null -eq $facts.usd -and $null -ne $facts.inputTokens) {
    if (-not $facts.model -and $name.model) { $facts.model = $name.model }
    $billedPrice = Get-BilledCodexPrice -Model $facts.model -CompletedUtc $t.LastWriteTimeUtc
    $currentPrice = if ($facts.model -and $currentCodexPrices.ContainsKey($facts.model)) {
      $currentCodexPrices[$facts.model]
    } else {
      $null
    }
    if ($billedPrice -and $currentPrice) {
      $billedShort = Get-CodexTokenCost -Facts $facts -InPerM $billedPrice.shortInPerM -OutPerM $billedPrice.shortOutPerM
      $billedLong = Get-CodexTokenCost -Facts $facts -InPerM $billedPrice.longInPerM -OutPerM $billedPrice.longOutPerM
      $currentShort = Get-CodexTokenCost -Facts $facts -InPerM $currentPrice.shortInPerM -OutPerM $currentPrice.shortOutPerM
      $currentLong = Get-CodexTokenCost -Facts $facts -InPerM $currentPrice.longInPerM -OutPerM $currentPrice.longOutPerM
      $provablyShort = [long]$facts.inputTokens -le $longContextThresholdInputTokens

      $facts.usdLower = $billedShort
      $facts.usdUpper = if ($provablyShort) { $billedShort } else { $billedLong }
      $facts.usdCurrentLower = $currentShort
      $facts.usdCurrentUpper = if ($provablyShort) { $currentShort } else { $currentLong }
      $facts.usd = $facts.usdUpper
      $facts.usdCurrent = $facts.usdCurrentUpper
      $facts.billedPriceEffectiveUtc = $billedPrice.effectiveUtc.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
      if ($provablyShort) {
        $facts.pricingContextTier = "short-exact"
        $facts.costSource = "token-derived-short-exact"
        $facts.routingCostSource = "current-price-token-derived-short-exact"
        $facts.billedPriceInPerM = $billedPrice.shortInPerM
        $facts.billedPriceOutPerM = $billedPrice.shortOutPerM
        $facts.currentPriceInPerM = $currentPrice.shortInPerM
        $facts.currentPriceOutPerM = $currentPrice.shortOutPerM
      } else {
        $facts.pricingContextTier = "request-tier-unknown-conservative-long"
        $facts.costSource = "token-derived-long-upper-bound"
        $facts.routingCostSource = "current-price-token-derived-long-upper-bound"
        $facts.billedPriceInPerM = $billedPrice.longInPerM
        $facts.billedPriceOutPerM = $billedPrice.longOutPerM
        $facts.currentPriceInPerM = $currentPrice.longInPerM
        $facts.currentPriceOutPerM = $currentPrice.longOutPerM
      }
    } else {
      $facts.costSource = "tokens-no-model"
      $facts.routingCostSource = "tokens-no-model"
    }
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
    cachedInputTokens = $facts.cachedInputTokens
    cacheWriteInputTokens = $facts.cacheWriteInputTokens
    billedPriceEffectiveUtc = $facts.billedPriceEffectiveUtc
    billedPriceInPerM = $facts.billedPriceInPerM
    billedPriceOutPerM = $facts.billedPriceOutPerM
    currentPriceInPerM = $facts.currentPriceInPerM
    currentPriceOutPerM = $facts.currentPriceOutPerM
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
