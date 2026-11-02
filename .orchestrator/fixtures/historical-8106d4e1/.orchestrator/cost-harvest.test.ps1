$ErrorActionPreference = "Stop"

$harvestScript = Join-Path $PSScriptRoot "cost-harvest.ps1"
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("cost-harvest-test-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $testRoot | Out-Null

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
Assert-True ([math]::Abs($sol.usdCurrent - 9.60) -lt 0.01) "unchanged Sol pricing normalizes to the same upper bound"
Assert-True ($sol.costSource -eq "token-derived-long-upper-bound") "costSource exposes tier uncertainty"
Assert-True ($sol.routingCostSource -eq "current-price-token-derived-long-upper-bound") "routing source exposes conservative normalization"
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

# --- 12. current Terra and Luna prices apply to current runs ----------------
# These cumulative totals are over the boundary, so the selected point is the
# long-tier upper bound while the short-tier counterfactual remains recorded.
New-CodexTranscript -Name "6103-terra-implementation.jsonl" `
  -In 1000000 -Cached 0 -Wrote 0 -Out 100000 | Out-Null
& $harvestScript -TranscriptDir $testRoot -Ledger $ledger -Backfill | Out-Null
$terra = (Get-Latest)["6103-terra-implementation.jsonl"]
Assert-True ($terra.model -eq "gpt-5.6-terra") "terra inferred (got $($terra.model))"
Assert-True ([math]::Abs($terra.usdLower - 3.20) -lt 0.01) "current Terra short lower bound is 3.20"
Assert-True ([math]::Abs($terra.usd - 5.80) -lt 0.01) "current Terra ambiguous run uses $4/$18 upper bound (got $($terra.usd), expected 5.80)"
Assert-True ([math]::Abs($terra.usdCurrent - 5.80) -lt 0.01) "current Terra routing cost uses the same upper bound"

New-CodexTranscript -Name "6104-luna-triage.jsonl" `
  -In 1000000 -Cached 0 -Wrote 0 -Out 100000 | Out-Null
& $harvestScript -TranscriptDir $testRoot -Ledger $ledger -Backfill | Out-Null
$luna = (Get-Latest)["6104-luna-triage.jsonl"]
Assert-True ([math]::Abs($luna.usdLower - 0.32) -lt 0.01) "current Luna short lower bound is 0.32"
Assert-True ([math]::Abs($luna.usd - 0.58) -lt 0.01) "current Luna ambiguous run uses $0.40/$1.80 upper bound (got $($luna.usd), expected 0.58)"
Assert-True ([math]::Abs($luna.usdCurrent - 0.58) -lt 0.01) "current Luna routing cost uses the same upper bound"
Write-Output "PASS cost-harvest applies current Terra and Luna prices"

# --- 13. historical billed USD and today's routing USD stay separate -------
# A pre-cut Terra trace was billed at $2.50/$15 ($4.00 here), but selecting a
# model today must compare that exact work at $2/$12 ($3.20).
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
Assert-True ([math]::Abs($terraOld.usdCurrentLower - 3.20) -lt 0.01) "pre-cut Terra short trace reprices to today's 3.20"
Assert-True ([math]::Abs($terraOld.usdCurrent - 5.80) -lt 0.01) "pre-cut Terra routing point uses today's long upper bound"
Assert-True ([math]::Abs($lunaOld.usdLower - 1.60) -lt 0.01) "pre-cut Luna short billed lower bound remains 1.60"
Assert-True ([math]::Abs($lunaOld.usd - 2.90) -lt 0.01) "pre-cut Luna billed estimate uses conservative long upper bound"
Assert-True ([math]::Abs($lunaOld.usdCurrentLower - 0.32) -lt 0.01) "pre-cut Luna short trace reprices to today's 0.32"
Assert-True ([math]::Abs($lunaOld.usdCurrent - 0.58) -lt 0.01) "pre-cut Luna routing point uses today's long upper bound"
Assert-True (([datetime]$terraOld.billedPriceEffectiveUtc).ToString("yyyy-MM-dd") -eq "2026-01-01") "historical price basis is auditable (got $($terraOld.billedPriceEffectiveUtc))"
Write-Output "PASS cost-harvest separates billed-at-the-time and current-price routing USD"

# --- 14. 272K boundary is per request; cumulative history fails closed -----
New-CodexTranscript -Name "6107-terra-boundary-short.jsonl" `
  -In 272000 -Cached 0 -Wrote 0 -Out 1000 | Out-Null
New-CodexTranscript -Name "6108-terra-boundary-ambiguous.jsonl" `
  -In 272001 -Cached 0 -Wrote 0 -Out 1000 | Out-Null
& $harvestScript -TranscriptDir $testRoot -Ledger $ledger -Backfill | Out-Null
$atBoundary = (Get-Latest)["6107-terra-boundary-short.jsonl"]
$overBoundary = (Get-Latest)["6108-terra-boundary-ambiguous.jsonl"]
Assert-True ($atBoundary.pricingContextTier -eq "short-exact") "272K cumulative input is provably short"
Assert-True ($atBoundary.usdCurrent -eq $atBoundary.usdCurrentLower) "exact-short point has no uncertainty spread"
Assert-True ($overBoundary.pricingContextTier -eq "request-tier-unknown-conservative-long") ">272K cumulative input is not misclassified as one long request"
Assert-True ($overBoundary.usdCurrent -eq $overBoundary.usdCurrentUpper) "ambiguous point fails closed to long upper bound"
Assert-True ($overBoundary.usdCurrent -gt $overBoundary.usdCurrentLower) "ambiguous run retains a visible short/long range"
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
Assert-True ([math]::Abs($astraShort.usdCurrent - 1.01) -lt 0.0001) "Astra short price includes cache read/write rates"
Assert-True ($astraLong.model -ceq "gpt-6-astra" -and [math]::Abs($astraLong.usdCurrentLower - 10.10) -lt 0.0001 -and [math]::Abs($astraLong.usdCurrentUpper - 17.70) -lt 0.0001) "Astra versioned shorthand retains conservative long bounds"
Assert-True ($astraExact.model -ceq "gpt-6-astra" -and [math]::Abs($astraExact.usdCurrent - 1.01) -lt 0.0001) "end-of-name exact Astra selector remains attributable"
Assert-True ($null -eq $astraAlias.model -and $null -eq $astraAlias.usdCurrent) "unversioned Astra filename cannot fabricate evidence"
foreach ($name in $unsupportedAstraNames) {
  $unsupported = (Get-Latest)[$name]
  Assert-True ($null -eq $unsupported.model -and $null -eq $unsupported.usd -and $null -eq $unsupported.usdCurrent) "$name cannot fabricate Astra model or price evidence"
  Assert-True ($unsupported.inputTokens -eq 123456 -and $unsupported.cachedInputTokens -eq 23456 -and $unsupported.cacheWriteInputTokens -eq 10000 -and $unsupported.outputTokens -eq 7890) "$name retains unattributed token facts"
  Assert-True ($unsupported.costSource -ceq "tokens-no-model" -and $unsupported.routingCostSource -ceq "tokens-no-model") "$name labels unattributed token facts"
}
Write-Output "PASS cost-harvest prices exact Astra separately from Sol"

Remove-Item -LiteralPath $testRoot -Recurse -Force
Write-Output "ALL cost-harvest tests passed"
