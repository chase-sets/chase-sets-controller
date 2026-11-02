$ErrorActionPreference = "Stop"

$harvestScript = Join-Path $PSScriptRoot "cost-harvest.ps1"
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("cost-harvest-test-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $testRoot | Out-Null
. (Join-Path $PSScriptRoot 'routing-data-test-support.ps1')
$routingTestScope=Enter-RoutingDataTestScope
$oldRoutingRoot=$env:CHASE_SETS_ROUTING_DATA_ROOT;$oldRoutingLkg=$env:CHASE_SETS_ROUTING_LKG_PATH
$snapshot=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'controller-skills/model-routing/capability-matrix.json') | ConvertFrom-Json
$fixture=New-RoutingMatrixFixture -Root (Join-Path $testRoot 'routing-state') -Snapshot $snapshot -BenchmarkRows @(New-RoutingCostBenchmarkRows)
$env:CHASE_SETS_ROUTING_DATA_ROOT=$fixture.stateRoot;$env:CHASE_SETS_ROUTING_LKG_PATH=$fixture.lkgPath
try {

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function New-Transcript {
  param(
    [string]$Name,
    [string]$Model = "claude-opus-5",
    [nullable[double]]$Usd = 2.50,
    [int]$DurationMs = 480000,
    [int]$Turns = 30,
    [switch]$NoResult
  )
  $path = Join-Path $testRoot $Name
  $lines = @(
    '{"type":"system","subtype":"hook_started","hook_name":"SessionStart:startup"}',
    ('{"type":"system","subtype":"init","cwd":"C:\\x","model":"' + $Model + '"}'),
    '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}'
  )
  if (-not $NoResult) {
    $usdPart = if ($null -ne $Usd) { ',"total_cost_usd":' + $Usd } else { '' }
    $lines += ('{"type":"result","subtype":"success","is_error":false,"duration_ms":' + $DurationMs +
               ',"duration_api_ms":120000,"num_turns":' + $Turns + $usdPart + ',"result":"done"}')
  }
  Set-Content -LiteralPath $path -Encoding utf8 -Value $lines
  return $path
}

$ledger = Join-Path $testRoot "cost-ledger.jsonl"
function Get-Ledger {
  if (-not (Test-Path $ledger)) { return @() }
  @(Get-Content $ledger | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
}
function Get-Latest {
  $rows = Get-Ledger
  $map = @{}
  foreach ($r in $rows) { $map[$r.transcript] = $r }
  $map
}

# --- 1. extracts cost, duration, turns, model from a result record ----------
New-Transcript -Name "lane-03-6072-opus5-high-ready-gate-repair.jsonl" -Usd 4.07 -DurationMs 498000 -Turns 52 | Out-Null
& $harvestScript -TranscriptDir $testRoot -Ledger $ledger -Backfill | Out-Null

$row = (Get-Latest)["lane-03-6072-opus5-high-ready-gate-repair.jsonl"]
Assert-True ($null -ne $row) "transcript harvested into ledger"
Assert-True ([math]::Abs($row.usd - 4.07) -lt 0.001) "usd extracted from total_cost_usd (got $($row.usd))"
Assert-True ($row.durationSec -eq 498) "duration_ms converted to seconds (got $($row.durationSec))"
Assert-True ($row.numTurns -eq 52) "num_turns extracted (got $($row.numTurns))"
Assert-True ($row.model -eq "claude-opus-5") "model read from init record (got $($row.model))"
Assert-True ($row.costSource -eq "stream-json") "costSource tagged"
Write-Output "PASS cost-harvest extracts cost/duration/turns/model"

# --- 2. filename parsing: lane ordinal is not the issue number -------------
Assert-True ($row.issue -eq 6072) "issue parsed from filename, not the lane ordinal (got $($row.issue))"
Assert-True ($row.lane -eq "lane-03") "lane parsed from filename (got $($row.lane))"
Write-Output "PASS cost-harvest parses issue/lane without mistaking the lane ordinal"

# --- 3. idempotent: unchanged transcripts are not re-harvested -------------
$before = (Get-Ledger).Count
& $harvestScript -TranscriptDir $testRoot -Ledger $ledger -Backfill | Out-Null
Assert-True ((Get-Ledger).Count -eq $before) "re-run does not duplicate unchanged transcripts"
Write-Output "PASS cost-harvest is idempotent"

# --- 4. -Force re-harvests (used after a parser fix) -----------------------
& $harvestScript -TranscriptDir $testRoot -Ledger $ledger -Force | Out-Null
Assert-True ((Get-Ledger).Count -gt $before) "-Force appends a fresh row"
$latest = (Get-Latest)["lane-03-6072-opus5-high-ready-gate-repair.jsonl"]
Assert-True ([math]::Abs($latest.usd - 4.07) -lt 0.001) "latest row still correct after -Force"
Write-Output "PASS cost-harvest -Force re-harvests and latest row wins"

# --- 5. a transcript with no result record yields no cost, not a crash -----
New-Transcript -Name "6045-sol-ready-resume.jsonl" -NoResult | Out-Null
& $harvestScript -TranscriptDir $testRoot -Ledger $ledger -Backfill | Out-Null
$noCost = (Get-Latest)["6045-sol-ready-resume.jsonl"]
Assert-True ($null -ne $noCost) "cost-less transcript still recorded"
Assert-True ($null -eq $noCost.usd) "cost-less transcript has null usd, not 0"
Assert-True ($noCost.costSource -eq "none") "costSource marks the gap"
Write-Output "PASS cost-harvest records cost-less transcripts without inventing a zero"

# --- 6. REGRESSION: a live lane holds its transcript open for append -------
# The first live run of this script died on exactly this. Harvesting must never
# contend with a running lane, so the reader opens with FileShare::ReadWrite.
$livePath = New-Transcript -Name "lane-06-6099-live-append.jsonl" -Usd 1.23
$live = [System.IO.FileStream]::new(
  $livePath, [System.IO.FileMode]::Append,
  [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
try {
  & $harvestScript -TranscriptDir $testRoot -Ledger $ledger -Backfill | Out-Null
  $liveRow = (Get-Latest)["lane-06-6099-live-append.jsonl"]
  Assert-True ($null -ne $liveRow) "transcript held open by a live lane is still harvested"
  Assert-True ([math]::Abs($liveRow.usd - 1.23) -lt 0.001) "live-lane cost extracted (got $($liveRow.usd))"
}
finally { $live.Dispose() }
Write-Output "PASS cost-harvest reads transcripts held open by a running lane"

# --- 7. the logs themselves are never harvested as transcripts -------------
Set-Content -LiteralPath (Join-Path $testRoot "dispatch-log.jsonl") -Encoding utf8 -Value '{"ts":"2026-07-24T00:00:00.000Z","kind":"dispatch"}'
& $harvestScript -TranscriptDir $testRoot -Ledger $ledger -Backfill | Out-Null
Assert-True (-not (Get-Latest).ContainsKey("dispatch-log.jsonl")) "dispatch-log.jsonl is not treated as a transcript"
Write-Output "PASS cost-harvest excludes the orchestrator logs"

# --- 8. summary rollup totals match the ledger ------------------------------
$json = & $harvestScript -TranscriptDir $testRoot -Ledger $ledger -Backfill -Json | ConvertFrom-Json
$expected = ((Get-Latest).Values | Where-Object { $null -ne $_.usd } | Measure-Object usd -Sum).Sum
Assert-True ([math]::Abs($json.totalUsd - [math]::Round($expected, 2)) -lt 0.02) "rollup total matches ledger (got $($json.totalUsd), expected $([math]::Round($expected,2)))"
Assert-True ($json.withoutCost -ge 1) "rollup counts cost-less runs separately"
Write-Output "PASS cost-harvest rollup totals reconcile with the ledger"

# --- 9. codex: cost derived from tokens, with cache economics --------------
function New-CodexTranscript {
  param(
    [string]$Name,
    [long]$In,
    [long]$Cached,
    [long]$Wrote,
    [long]$Out,
    [long]$Reasoning = 0,
    [nullable[datetime]]$CompletedUtc
  )
  $path = Join-Path $testRoot $Name
  Set-Content -LiteralPath $path -Encoding utf8 -Value @(
    '{"type":"thread.started","thread_id":"t1"}',
    '{"type":"command_execution","command":"pnpm test"}',
    ('{"type":"turn.completed","usage":{"input_tokens":' + $In +
     ',"cached_input_tokens":' + $Cached +
     ',"cache_write_input_tokens":' + $Wrote +
     ',"output_tokens":' + $Out +
     ',"reasoning_output_tokens":' + $Reasoning + '}}')
  )
  if ($null -ne $CompletedUtc) {
    [System.IO.File]::SetLastWriteTimeUtc($path, $CompletedUtc.ToUniversalTime())
  }
  return $path
}

# The run's cumulative input exceeds 272K, so its per-request tier is unknown.
# The ledger keeps the $5/$30 short lower bound and conservatively selects the
# $10/$45 long upper bound; cache reads are 0.10x, writes 1.25x.
# plain = 1,000,000 - 600,000 - 200,000 = 200,000
# Short lower = 5.55. Long upper:
#   plain   200000 * 10    / 1e6 = 2.00
#   cached  600000 * 10*.10/1e6 = 0.60
#   wrote   200000 * 10*1.25/1e6 = 2.50
#   output  100000 * 45    / 1e6 = 4.50  -> 9.60
New-CodexTranscript -Name "lane-09-6100-sol-implementation.jsonl" `
  -In 1000000 -Cached 600000 -Wrote 200000 -Out 100000 -Reasoning 40000 | Out-Null
& $harvestScript -TranscriptDir $testRoot -Ledger $ledger -Backfill | Out-Null
$sol = (Get-Latest)["lane-09-6100-sol-implementation.jsonl"]
Assert-True ($null -ne $sol) "codex transcript harvested"
Assert-True ($sol.model -eq "gpt-5.6-sol") "model inferred from filename (got $($sol.model))"
Assert-True ([math]::Abs($sol.usdLower - 5.55) -lt 0.01) "short-context lower bound preserves cache economics"
Assert-True ([math]::Abs($sol.usd - 9.60) -lt 0.01) "ambiguous run uses conservative long-context upper bound (got $($sol.usd), expected 9.60)"
Assert-True ($null -eq $sol.usdCurrent -and $null -eq $sol.usdCurrentUpper -and $null -eq $sol.usdCurrentLower) "standard benchmark rates cannot invent long/cache normalization"
Assert-True ($sol.costSource -eq "token-derived-long-upper-bound") "costSource exposes tier uncertainty"
Assert-True ($sol.routingCostSource -ceq 'BENCHMARK_CONTEXT_CACHE_RATES_UNAVAILABLE' -and $sol.currentPriceInPerM -eq 5 -and $sol.currentPriceOutPerM -eq 30) "routing source names the gap and keeps only supplied standard rates"
Assert-True ($sol.pricingContextTier -eq "request-tier-unknown-conservative-long") "cumulative input cannot be mistaken for a request tier"
Assert-True ($sol.cacheWriteInputTokens -eq 200000) "cache-write tokens are retained for future repricing"
Write-Output "PASS cost-harvest derives codex cost from tokens with cache economics"

# --- 10. reasoning tokens are a SUBSET of output, never added again --------
# Same run with reasoning declared as zero must cost exactly the same; if
# reasoning were being added to output the totals would diverge.
New-CodexTranscript -Name "lane-09-6101-sol-implementation.jsonl" `
  -In 1000000 -Cached 600000 -Wrote 200000 -Out 100000 -Reasoning 0 | Out-Null
& $harvestScript -TranscriptDir $testRoot -Ledger $ledger -Backfill | Out-Null
$noReason = (Get-Latest)["lane-09-6101-sol-implementation.jsonl"]
Assert-True ([math]::Abs($noReason.usd - $sol.usd) -lt 0.0001) "reasoning tokens are not double-charged (got $($noReason.usd) vs $($sol.usd))"
Write-Output "PASS cost-harvest does not double-charge reasoning tokens"

# --- 11. model inference must not fire on substrings ------------------------
# "console"/"serialized" contain 'sol'; a substring match would mis-price them
# as Sol. Unpriceable runs keep their tokens and get no invented dollar figure.
New-CodexTranscript -Name "6102-console-serialized-repair.jsonl" `
  -In 1000 -Cached 0 -Wrote 0 -Out 100 | Out-Null
& $harvestScript -TranscriptDir $testRoot -Ledger $ledger -Backfill | Out-Null
$amb = (Get-Latest)["6102-console-serialized-repair.jsonl"]
Assert-True ($null -eq $amb.model) "'console'/'serialized' are not read as sol (got $($amb.model))"
Assert-True ($null -eq $amb.usd) "unpriceable run gets no invented cost"
Assert-True ($amb.costSource -eq "tokens-no-model") "costSource flags tokens without a model"
Assert-True ($amb.inputTokens -eq 1000) "tokens still recorded for later pricing"
Write-Output "PASS cost-harvest anchors model inference on hyphen boundaries"

# --- 12. effective-dated Terra and Luna billed prices stay historical -------
# These cumulative totals are over the boundary, so the selected point is the
# long-tier upper bound while the short-tier counterfactual remains recorded.
New-CodexTranscript -Name "6103-terra-implementation.jsonl" `
  -In 1000000 -Cached 0 -Wrote 0 -Out 100000 | Out-Null
& $harvestScript -TranscriptDir $testRoot -Ledger $ledger -Backfill | Out-Null
$terra = (Get-Latest)["6103-terra-implementation.jsonl"]
Assert-True ($terra.model -eq "gpt-5.6-terra") "terra inferred (got $($terra.model))"
Assert-True ([math]::Abs($terra.usdLower - 3.20) -lt 0.01) "current Terra short lower bound is 3.20"
Assert-True ([math]::Abs($terra.usd - 5.80) -lt 0.01) "current Terra ambiguous run uses $4/$18 upper bound (got $($terra.usd), expected 5.80)"
Assert-True ($null -eq $terra.usdCurrent -and $terra.currentPriceInPerM -eq 2 -and $terra.currentPriceOutPerM -eq 12) "Terra standard data cannot authorize a long-context normalization"

New-CodexTranscript -Name "6104-luna-triage.jsonl" `
  -In 1000000 -Cached 0 -Wrote 0 -Out 100000 | Out-Null
& $harvestScript -TranscriptDir $testRoot -Ledger $ledger -Backfill | Out-Null
$luna = (Get-Latest)["6104-luna-triage.jsonl"]
Assert-True ([math]::Abs($luna.usdLower - 0.32) -lt 0.01) "current Luna short lower bound is 0.32"
Assert-True ([math]::Abs($luna.usd - 0.58) -lt 0.01) "current Luna ambiguous run uses $0.40/$1.80 upper bound (got $($luna.usd), expected 0.58)"
Assert-True ($null -eq $luna.usdCurrent -and $luna.currentPriceInPerM -eq 0.2 -and $luna.currentPriceOutPerM -eq 1.2) "Luna standard data cannot authorize a long-context normalization"
Write-Output "PASS cost-harvest preserves effective-dated Terra and Luna billed prices"

# --- 13. historical billed USD and current standard rates stay separate -----
# Snapshot standard rates do not supply long-context/cache authority.
New-CodexTranscript -Name "6105-terra-pre-cut.jsonl" `
  -In 1000000 -Cached 0 -Wrote 0 -Out 100000 `
  -CompletedUtc ([datetime]"2026-07-29T23:59:00Z") | Out-Null
New-CodexTranscript -Name "6106-luna-pre-cut.jsonl" `
  -In 1000000 -Cached 0 -Wrote 0 -Out 100000 `
  -CompletedUtc ([datetime]"2026-07-29T23:59:00Z") | Out-Null
& $harvestScript -TranscriptDir $testRoot -Ledger $ledger -Backfill | Out-Null
$terraOld = (Get-Latest)["6105-terra-pre-cut.jsonl"]
$lunaOld = (Get-Latest)["6106-luna-pre-cut.jsonl"]
Assert-True ([math]::Abs($terraOld.usdLower - 4.00) -lt 0.01) "pre-cut Terra short billed lower bound remains 4.00"
Assert-True ([math]::Abs($terraOld.usd - 7.25) -lt 0.01) "pre-cut Terra billed estimate uses conservative long upper bound"
Assert-True ($null -eq $terraOld.usdCurrentLower -and $null -eq $terraOld.usdCurrent -and $terraOld.currentPriceInPerM -eq 2) "pre-cut Terra keeps new standard telemetry separate from preserved billing"
Assert-True ([math]::Abs($lunaOld.usdLower - 1.60) -lt 0.01) "pre-cut Luna short billed lower bound remains 1.60"
Assert-True ([math]::Abs($lunaOld.usd - 2.90) -lt 0.01) "pre-cut Luna billed estimate uses conservative long upper bound"
Assert-True ($null -eq $lunaOld.usdCurrentLower -and $null -eq $lunaOld.usdCurrent -and $lunaOld.currentPriceInPerM -eq 0.2) "pre-cut Luna keeps new standard telemetry separate from preserved billing"
Assert-True (([datetime]$terraOld.billedPriceEffectiveUtc).ToString("yyyy-MM-dd") -eq "2026-01-01") "historical price basis is auditable (got $($terraOld.billedPriceEffectiveUtc))"
Write-Output "PASS cost-harvest separates historical billed USD from benchmark standard rates and unknown normalization"

# --- 14. 272K boundary is per request; cumulative history fails closed -----
New-CodexTranscript -Name "6107-terra-boundary-short.jsonl" `
  -In 272000 -Cached 0 -Wrote 0 -Out 1000 | Out-Null
New-CodexTranscript -Name "6108-terra-boundary-ambiguous.jsonl" `
  -In 272001 -Cached 0 -Wrote 0 -Out 1000 | Out-Null
& $harvestScript -TranscriptDir $testRoot -Ledger $ledger -Backfill | Out-Null
$atBoundary = (Get-Latest)["6107-terra-boundary-short.jsonl"]
$overBoundary = (Get-Latest)["6108-terra-boundary-ambiguous.jsonl"]
Assert-True ($atBoundary.pricingContextTier -eq "short-exact") "272K cumulative input is provably short"
Assert-True ($null -eq $atBoundary.usdCurrent -and $null -eq $atBoundary.usdCurrentLower) "historical request boundary does not invent current cache/context authority"
Assert-True ($overBoundary.pricingContextTier -eq "request-tier-unknown-conservative-long") ">272K cumulative input is not misclassified as one long request"
Assert-True ($null -eq $overBoundary.usdCurrent -and $null -eq $overBoundary.usdCurrentUpper -and $null -eq $overBoundary.usdCurrentLower) "current long-context gap stays unknown"
Assert-True ($overBoundary.usdUpper -gt $overBoundary.usdLower) "historical billed run retains a visible short/long range"
Write-Output "PASS cost-harvest enforces and audits the 272K request-tier boundary"

# Astra is a separate version and has independent short/long cost bounds. Its
# exact selector/shorthand must end or use the closed double-hyphen delimiter;
# single-hyphen continuations remain unattributable token facts.
New-CodexTranscript -Name "7700-gpt-6-astra--high-short.jsonl" -In 100000 -Cached 60000 -Wrote 20000 -Out 10000 | Out-Null
New-CodexTranscript -Name "7701-astra6--high-long.jsonl" -In 1000000 -Cached 600000 -Wrote 200000 -Out 100000 | Out-Null
New-CodexTranscript -Name "gpt-6-astra.jsonl" -In 100000 -Cached 60000 -Wrote 20000 -Out 10000 | Out-Null
New-CodexTranscript -Name "7702-astra-high-ambiguous.jsonl" -In 100000 -Out 10000 | Out-Null
$unsupportedAstraNames = @(
  "7703-gpt-6-astra-future-high.jsonl",
  "7704-gpt-6-astra-2026-09-04-high.jsonl",
  "7705-gpt-6-high.jsonl",
  "7706-astra-family-high.jsonl",
  "7707-GPT-6-ASTRA--high.jsonl"
)
foreach ($name in $unsupportedAstraNames) {
  New-CodexTranscript -Name $name -In 123456 -Cached 23456 -Wrote 10000 -Out 7890 | Out-Null
}
& $harvestScript -TranscriptDir $testRoot -Ledger $ledger -Backfill | Out-Null
$astraShort = (Get-Latest)["7700-gpt-6-astra--high-short.jsonl"]
$astraLong = (Get-Latest)["7701-astra6--high-long.jsonl"]
$astraExact = (Get-Latest)["gpt-6-astra.jsonl"]
$astraAlias = (Get-Latest)["7702-astra-high-ambiguous.jsonl"]
Assert-True ($astraShort.model -ceq "gpt-6-astra" -and $astraShort.pricingContextTier -eq "short-exact") "Astra exact selector is attributed separately"
Assert-True ([math]::Abs($astraShort.usd - 1.01) -lt 0.0001 -and $null -eq $astraShort.usdCurrent -and $astraShort.currentPriceInPerM -eq 10) "Astra preserves billed cache prices but does not invent current cache rates"
Assert-True ($astraLong.model -ceq "gpt-6-astra" -and [math]::Abs($astraLong.usdLower - 10.10) -lt 0.0001 -and [math]::Abs($astraLong.usdUpper - 17.70) -lt 0.0001 -and $null -eq $astraLong.usdCurrent) "Astra versioned shorthand retains billed bounds and unknown current normalization"
Assert-True ($astraExact.model -ceq "gpt-6-astra" -and [math]::Abs($astraExact.usd - 1.01) -lt 0.0001 -and $null -eq $astraExact.benchmarkUsdPerTask) "end-of-name exact Astra is attributable without inventing effort or per-task USD"
Assert-True ($null -eq $astraAlias.model -and $null -eq $astraAlias.usdCurrent) "unversioned Astra filename cannot fabricate evidence"
foreach ($name in $unsupportedAstraNames) {
  $unsupported = (Get-Latest)[$name]
  Assert-True ($null -eq $unsupported.model -and $null -eq $unsupported.usd -and $null -eq $unsupported.usdCurrent) "$name cannot fabricate Astra model or price evidence"
  Assert-True ($unsupported.inputTokens -eq 123456 -and $unsupported.cachedInputTokens -eq 23456 -and $unsupported.cacheWriteInputTokens -eq 10000 -and $unsupported.outputTokens -eq 7890) "$name retains unattributed token facts"
  Assert-True ($unsupported.costSource -ceq "tokens-no-model" -and $unsupported.routingCostSource -ceq "tokens-no-model") "$name labels unattributed token facts"
}
Write-Output "PASS cost-harvest prices exact Astra separately from Sol"

# --- Claude usage: exact captured probe layout, entirely synthetic data -----
function New-SyntheticClaudeResult {
  # token-burn-result-usage-probe.json key layout, not a modified real identity.
  [ordered]@{
    observedAt = "2026-09-16T01:02:03.0000000+00:00"
    source = "synthetic-claude-usage-probe.jsonl"
    type = "result"
    subtype = "success"
    usage = [ordered]@{
      input_tokens = 100L
      cache_creation_input_tokens = 300L
      cache_read_input_tokens = 200L
      output_tokens = 80L
      output_tokens_details = [ordered]@{ thinking_tokens = 50L }
      server_tool_use = [ordered]@{ web_search_requests = 0; web_fetch_requests = 0 }
      service_tier = "standard"
      cache_creation = [ordered]@{ ephemeral_1h_input_tokens = 300; ephemeral_5m_input_tokens = 0 }
      inference_geo = "not_available"
      iterations = @([ordered]@{
        input_tokens = 10
        output_tokens = 8
        cache_read_input_tokens = 20
        cache_creation_input_tokens = 30
        cache_creation = [ordered]@{ ephemeral_5m_input_tokens = 0; ephemeral_1h_input_tokens = 30 }
        type = "message"
        model = $null
      })
      speed = "standard"
    }
    total_cost_usd = 1.234567
  }
}
$completeTokens = @{
  inputTokens = 600L; cachedInputTokens = 200L; cacheWriteInputTokens = 300L
  outputTokens = 80L; reasoningOutputTokens = 50L
}
$unknownTokens = @{
  inputTokens = $null; cachedInputTokens = $null; cacheWriteInputTokens = $null
  outputTokens = $null; reasoningOutputTokens = $null
}
$usageAbsent = New-SyntheticClaudeResult
$usageAbsent.Remove("usage")
$usageCases = @(
  @{ Name = "complete"; Record = (New-SyntheticClaudeResult); Expected = $completeTokens },
  @{ Name = "absent"; Record = $usageAbsent; Expected = $unknownTokens }
)
$tokenFields = [ordered]@{
  input_tokens = "inputTokens"
  cache_read_input_tokens = "cachedInputTokens"
  cache_creation_input_tokens = "cacheWriteInputTokens"
  output_tokens = "outputTokens"
  thinking_tokens = "reasoningOutputTokens"
}
$invalidCounts = [ordered]@{
  missing = $null; fractional = 1.5; negative = -1; string = "12"
  overflow = [bigint]::Parse("9223372036854775808"); boolean = $true
  null = $null; array = @(1, 2); object = @{ value = 1 }
}
foreach ($field in $tokenFields.Keys) {
  foreach ($invalid in $invalidCounts.Keys) {
    $record = New-SyntheticClaudeResult
    $target = if ($field -ceq "thinking_tokens") { $record.usage.output_tokens_details } else { $record.usage }
    if ($invalid -ceq "missing") { $target.Remove($field) }
    else { $target[$field] = $invalidCounts[$invalid] }
    $expectedTokens = $completeTokens.Clone()
    $expectedTokens[$tokenFields[$field]] = $null
    if ($field -in @("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens")) {
      $expectedTokens.inputTokens = $null
    }
    $usageCases += @{ Name = "$field-$invalid"; Record = $record; Expected = $expectedTokens }
  }
}
# Valid zero and Int64.MaxValue stay numeric; an overflowing sum stays unknown.
$zeroUsage = New-SyntheticClaudeResult
$maxUsage = New-SyntheticClaudeResult
$sumOverflowUsage = New-SyntheticClaudeResult
foreach ($field in @("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "output_tokens")) {
  $zeroUsage.usage[$field] = 0L
}
$zeroUsage.usage.output_tokens_details.thinking_tokens = 0L
$maxUsage.usage.input_tokens = [long]::MaxValue
$maxUsage.usage.cache_read_input_tokens = 0L
$maxUsage.usage.cache_creation_input_tokens = 0L
$sumOverflowUsage.usage.input_tokens = [long]::MaxValue
$sumOverflowExpected = $completeTokens.Clone()
$sumOverflowExpected.inputTokens = $null
$usageCases += @(
  @{ Name = "zero"; Record = $zeroUsage; Expected = @{ inputTokens = 0L; cachedInputTokens = 0L; cacheWriteInputTokens = 0L; outputTokens = 0L; reasoningOutputTokens = 0L } },
  @{ Name = "int64-max"; Record = $maxUsage; Expected = @{ inputTokens = [long]::MaxValue; cachedInputTokens = 0L; cacheWriteInputTokens = 0L; outputTokens = 80L; reasoningOutputTokens = 50L } },
  @{ Name = "sum-overflow"; Record = $sumOverflowUsage; Expected = $sumOverflowExpected }
)
foreach ($case in $usageCases) {
  $name = "synthetic-claude-usage-$($case.Name).jsonl"
  $case.Record.source = $name
  Set-Content -LiteralPath (Join-Path $testRoot $name) -Encoding utf8 -Value @(
    '{"type":"system","subtype":"init","cwd":"C:\\synthetic-usage-fixture","model":"claude-opus-5"}',
    ($case.Record | ConvertTo-Json -Depth 10 -Compress)
  )
}
& $harvestScript -TranscriptDir $testRoot -Ledger $ledger -Backfill | Out-Null
$usageRows = Get-Latest
function Assert-UsageFieldPresent($Row, [string]$CaseName, [string]$Field) {
  Assert-True ($null -ne $Row.PSObject.Properties[$Field]) "$CaseName`: $Field is present"
}
foreach ($case in $usageCases) {
  $usageRow = $usageRows["synthetic-claude-usage-$($case.Name).jsonl"]
  Assert-True ($null -ne $usageRow) "$($case.Name): synthetic usage transcript harvested"
  foreach ($field in $completeTokens.Keys) {
    Assert-UsageFieldPresent $usageRow $case.Name $field
    if ($null -eq $case.Expected[$field]) {
      Assert-True ($null -eq $usageRow.$field) "$($case.Name): $field stays null"
    } else {
      Assert-True ($null -ne $usageRow.$field -and $usageRow.$field -eq $case.Expected[$field]) "$($case.Name): $field preserves its exact value"
    }
  }
  Assert-True ($usageRow.usd -eq 1.234567 -and $usageRow.costSource -ceq "stream-json") "$($case.Name): reported USD and costSource survive"
  Assert-True ($usageRow.model -ceq "claude-opus-5") "$($case.Name): init model remains authoritative"
}
Write-Output "PASS cost-harvest preserves strict unknowns and independent real-shape Claude usage fields"

# --- emitted reasoning field: same complete input, row-without-key mutant ---
$completeRoot = Join-Path $testRoot "synthetic-complete-row"
New-Item -ItemType Directory -Path $completeRoot | Out-Null
$completeTranscript = Join-Path $completeRoot "synthetic-claude-usage-complete.jsonl"
Copy-Item -LiteralPath (Join-Path $testRoot "synthetic-claude-usage-complete.jsonl") -Destination $completeTranscript
$completeHash = (Get-FileHash -LiteralPath $completeTranscript).Hash
$completeLedger = Join-Path $testRoot "synthetic-complete-candidate-ledger.jsonl"
& $harvestScript -TranscriptDir $completeRoot -Ledger $completeLedger -Backfill | Out-Null
$completeRow = Get-Content -LiteralPath $completeLedger | ConvertFrom-Json
Assert-UsageFieldPresent $completeRow "complete" "reasoningOutputTokens"
Assert-True ($completeRow.reasoningOutputTokens -eq 50) "complete: emitted reasoning preserves the parsed value"

$reasoningRowField = '    reasoningOutputTokens = $facts.reasoningOutputTokens'
$harvestSource = [IO.File]::ReadAllText($harvestScript)
Assert-True ([regex]::Matches($harvestSource, [regex]::Escape($reasoningRowField)).Count -eq 1) "row-without-key has exactly one emission replacement"
$rowMutantSource = $harvestSource.Replace($reasoningRowField, '    # MUTANT row-without-key: omit the parsed reasoning field.')
Assert-True ($rowMutantSource -cne $harvestSource -and -not $rowMutantSource.Contains($reasoningRowField)) "row-without-key replacement occurred"
$rowMutantScript = Join-Path $testRoot "cost-harvest-row-without-key.ps1"
[IO.File]::WriteAllText($rowMutantScript, $rowMutantSource, [Text.UTF8Encoding]::new($false))
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "orchestration-log-lock.psm1") -Destination $testRoot
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'routing-data.ps1') -Destination $testRoot
$rowMutantLedger = Join-Path $testRoot "synthetic-complete-mutant-ledger.jsonl"
& $rowMutantScript -TranscriptDir $completeRoot -Ledger $rowMutantLedger -Backfill | Out-Null
$rowMutant = Get-Content -LiteralPath $rowMutantLedger | ConvertFrom-Json
Assert-True ($null -ne $rowMutant -and $rowMutant.outputTokens -eq 80 -and $rowMutant.usd -eq 1.234567) "row-without-key still emits the complete transcript's independent facts"
$rowMutantRejected = $false
try { Assert-UsageFieldPresent $rowMutant "complete" "reasoningOutputTokens" }
catch {
  if ($_.Exception.Message -cne "ASSERTION FAILED: complete: reasoningOutputTokens is present") { throw }
  $rowMutantRejected = $true
}
Assert-True $rowMutantRejected "row-without-key fails the same complete presence assertion that the candidate passes"
Assert-True ((Get-FileHash -LiteralPath $completeTranscript).Hash -ceq $completeHash) "candidate and row-without-key used identical complete input"
Write-Output "PASS cost-harvest complete reasoningOutputTokens presence discriminator rejects row-without-key"

# --- dispatch-log binding attributes unlabeled transcripts exactly ---------
New-CodexTranscript -Name "synthetic-binding-bound.jsonl" -In 200000 -Cached 150000 -Wrote 0 -Out 5000 | Out-Null
New-CodexTranscript -Name "synthetic-binding-ambiguous.jsonl" -In 200000 -Cached 150000 -Wrote 0 -Out 5000 | Out-Null
New-CodexTranscript -Name "synthetic-binding-nondispatch.jsonl" -In 200000 -Cached 150000 -Wrote 0 -Out 5000 | Out-Null
New-CodexTranscript -Name "synthetic-binding-absent.jsonl" -In 200000 -Cached 150000 -Wrote 0 -Out 5000 | Out-Null
New-CodexTranscript -Name "synthetic-99999-sol-high-named.jsonl" -In 200000 -Cached 150000 -Wrote 0 -Out 5000 | Out-Null
New-Transcript -Name "synthetic-init-authority.jsonl" -Model "claude-opus-5" | Out-Null
Set-Content -LiteralPath (Join-Path $testRoot "dispatch-log.jsonl") -Encoding utf8 -Value @(
  '{"ts":"2026-09-10T00:00:00.000Z","kind":"dispatch","issue":99999,"laneRole":"implementation","harness":"codex","model":"gpt-6-astra","effort":"high","transcript":"synthetic-binding-bound.jsonl"}',
  '{"ts":"2026-09-10T00:00:00.000Z","kind":"dispatch","issue":99999,"laneRole":"implementation","harness":"codex","model":"gpt-5.6-sol","effort":"high","transcript":"synthetic-binding-ambiguous.jsonl"}',
  '{"ts":"2026-09-10T00:01:00.000Z","kind":"dispatch","issue":99999,"laneRole":"implementation","harness":"codex","model":"gpt-6-astra","effort":"high","transcript":"synthetic-binding-ambiguous.jsonl"}',
  '{"ts":"2026-09-10T00:00:00.000Z","kind":"review-complete","issue":99999,"model":"claude-opus-5","transcript":"synthetic-binding-nondispatch.jsonl"}',
  '{"ts":"2026-09-10T00:00:00.000Z","kind":"dispatch","issue":99999,"laneRole":"implementation","harness":"codex","model":"gpt-6-astra","effort":"high","transcript":"synthetic-99999-sol-high-named.jsonl"}',
  '{"ts":"2026-09-10T00:00:00.000Z","kind":"dispatch","issue":99999,"laneRole":"implementation","harness":"codex","model":"gpt-6-astra","effort":"high","transcript":"synthetic-init-authority.jsonl"}',
  'not json'
)
& $harvestScript -TranscriptDir $testRoot -Ledger $ledger -Backfill | Out-Null
$bound = (Get-Latest)["synthetic-binding-bound.jsonl"]
$ambiguousRow = (Get-Latest)["synthetic-binding-ambiguous.jsonl"]
$unbound = (Get-Latest)["synthetic-binding-nondispatch.jsonl"]
$absentBinding = (Get-Latest)["synthetic-binding-absent.jsonl"]
$named = (Get-Latest)["synthetic-99999-sol-high-named.jsonl"]
$initAuthority = (Get-Latest)["synthetic-init-authority.jsonl"]
Assert-True ($bound.model -ceq "gpt-6-astra" -and $null -ne $bound.usd -and $null -eq $bound.usdCurrent -and $bound.benchmarkUsdPerTask -eq 6 -and $bound.costSource -ceq "token-derived-short-exact") "exact dispatch binds historical billing and configuration benchmark, not fabricated normalization"
Assert-True ($null -eq $ambiguousRow.model -and $ambiguousRow.costSource -ceq "tokens-no-model") "a transcript bound to two models stays unattributed"
Assert-True ($null -eq $unbound.model -and $unbound.costSource -ceq "tokens-no-model") "a non-dispatch row does not bind a model"
Assert-True ($null -eq $absentBinding.model -and $absentBinding.costSource -ceq "tokens-no-model") "an absent dispatch binding does not invent a model"
Assert-True ($named.model -ceq "gpt-5.6-sol") "the filename convention still wins over the dispatch row"
Assert-True ($initAuthority.model -ceq "claude-opus-5" -and $initAuthority.usd -eq 2.50) "the init model and reported USD still win over the dispatch row"
Assert-True ($null -eq (Get-Latest)["dispatch-log.jsonl"]) "dispatch-log.jsonl itself is not harvested"
Write-Output "PASS cost-harvest binds models from exact dispatch rows"

# --- isolated exact-transcript conflict and named ambiguity-bypass mutant ---
$conflictRoot = Join-Path $testRoot "synthetic-dispatch-conflict"
New-Item -ItemType Directory -Path $conflictRoot | Out-Null
$conflictName = "synthetic-exact-binding-conflict.jsonl"
$conflictTranscript = Join-Path $conflictRoot $conflictName
# No init/model event, no model label in the filename, no reported USD.
Set-Content -LiteralPath $conflictTranscript -Encoding utf8 -Value '{"type":"turn.completed","usage":{"input_tokens":1000,"cached_input_tokens":200,"cache_write_input_tokens":0,"output_tokens":100}}'
[IO.File]::SetLastWriteTimeUtc($conflictTranscript, [datetime]"2026-09-16T00:00:00Z")
$conflictDispatch = Join-Path $conflictRoot "dispatch-log.jsonl"
$dispatchRows = @(
  [ordered]@{ ts = "2026-09-16T00:00:00.000Z"; kind = "dispatch"; issue = 99999; lane = "synthetic-conflict-lane"; laneRole = "implementation"; harness = "codex"; model = "gpt-5.6-sol"; effort = "high"; transcript = $conflictName },
  [ordered]@{ ts = "2026-09-16T00:00:01.000Z"; kind = "dispatch"; issue = 99999; lane = "synthetic-conflict-lane"; laneRole = "implementation"; harness = "codex"; model = "gpt-5.6-sol"; effort = "high"; transcript = $conflictName }
)
Set-Content -LiteralPath $conflictDispatch -Encoding utf8 -Value @($dispatchRows | ForEach-Object { $_ | ConvertTo-Json -Compress })
$boundLedger = Join-Path $testRoot "synthetic-conflict-bound-ledger.jsonl"
& $harvestScript -TranscriptDir $conflictRoot -Ledger $boundLedger -Backfill | Out-Null
$boundControl = Get-Content -LiteralPath $boundLedger | ConvertFrom-Json
Assert-True ($boundControl.model -ceq "gpt-5.6-sol" -and $boundControl.costSource -ceq "token-derived-short-exact") "isolated identical dispatch bindings attribute the transcript"

# Only the second valid dispatch model changes; all other inputs stay fixed.
$dispatchRows[1].model = "gpt-6-astra"
Set-Content -LiteralPath $conflictDispatch -Encoding utf8 -Value @($dispatchRows | ForEach-Object { $_ | ConvertTo-Json -Compress })
$conflictHashes = @((Get-FileHash -LiteralPath $conflictTranscript).Hash, (Get-FileHash -LiteralPath $conflictDispatch).Hash)
function Assert-UnknownDispatchModel($Row) {
  Assert-True ($null -ne $Row -and $null -eq $Row.model -and $Row.costSource -ceq "tokens-no-model") "exact-transcript model conflict remains unknown"
}
$candidateLedger = Join-Path $testRoot "synthetic-conflict-candidate-ledger.jsonl"
& $harvestScript -TranscriptDir $conflictRoot -Ledger $candidateLedger -Backfill | Out-Null
$conflictCandidate = Get-Content -LiteralPath $candidateLedger | ConvertFrom-Json
Assert-UnknownDispatchModel $conflictCandidate

$ambiguityGuard = '  foreach ($key in @($ambiguous.Keys)) { $models.Remove($key) }'
$harvestSource = [IO.File]::ReadAllText($harvestScript)
Assert-True ([regex]::Matches($harvestSource, [regex]::Escape($ambiguityGuard)).Count -eq 1) "ambiguity-check-bypass has exactly one guard replacement"
$mutantSource = $harvestSource.Replace($ambiguityGuard, '  # MUTANT ambiguity-check-bypass: retain the conflicting binding.')
Assert-True ($mutantSource -cne $harvestSource -and -not $mutantSource.Contains($ambiguityGuard)) "ambiguity-check-bypass replacement occurred"
$mutantScript = Join-Path $testRoot "cost-harvest-ambiguity-check-bypass.ps1"
[IO.File]::WriteAllText($mutantScript, $mutantSource, [Text.UTF8Encoding]::new($false))
$mutantLedger = Join-Path $testRoot "synthetic-conflict-mutant-ledger.jsonl"
& $mutantScript -TranscriptDir $conflictRoot -Ledger $mutantLedger -Backfill | Out-Null
$conflictMutant = Get-Content -LiteralPath $mutantLedger | ConvertFrom-Json
Assert-True ($conflictMutant.model -ceq "gpt-6-astra" -and $null -ne $conflictMutant.usd) "ambiguity-check-bypass attributes and prices the same transcript"
Assert-True ($conflictMutant.costSource -cne "tokens-no-model" -and $conflictMutant.costSource -ceq "token-derived-short-exact") "ambiguity-check-bypass cannot be unknown through another prerequisite"
$mutantRejected = $false
try { Assert-UnknownDispatchModel $conflictMutant }
catch {
  if ($_.Exception.Message -cne "ASSERTION FAILED: exact-transcript model conflict remains unknown") { throw }
  $mutantRejected = $true
}
Assert-True $mutantRejected "ambiguity-check-bypass fails the same expected-unknown assertion that the candidate passes"
Assert-True ((Get-FileHash -LiteralPath $conflictTranscript).Hash -ceq $conflictHashes[0] -and (Get-FileHash -LiteralPath $conflictDispatch).Hash -ceq $conflictHashes[1]) "candidate and ambiguity-check-bypass used identical inputs"
Write-Output "PASS cost-harvest exact-transcript conflict discriminator rejects ambiguity-check-bypass"

Write-Output "ALL cost-harvest tests passed"
} finally {
  $env:CHASE_SETS_ROUTING_DATA_ROOT=$oldRoutingRoot;$env:CHASE_SETS_ROUTING_LKG_PATH=$oldRoutingLkg
  $resolved=[IO.Path]::GetFullPath($testRoot);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
  if ((Split-Path -Parent $resolved).TrimEnd('\','/') -cne $temp -or (Split-Path -Leaf $resolved) -notlike 'cost-harvest-test-*') { throw 'unsafe cost harvest cleanup root' }
  Remove-Item -LiteralPath $resolved -Recurse -Force
  Exit-RoutingDataTestScope $routingTestScope
}
