<#
.SYNOPSIS
Regenerate the MEASURED fields of capability-matrix.json from the loop's own
telemetry, so cost/speed/quality numbers never need hand-reconciliation.

THE SPLIT THIS ENFORCES:
  measured facts  -> GENERATED here, never hand-edited (cost, speed, n, block rate)
  judgments       -> AUTHORED by a human (cell scores, vetoes, bars, provenance)

THE UNIT: a configuration — exact model version + exact effort (model-routing
v4.13). Every `measured` block, byRowConfig cell, and blockRateByRowConfig
cell is keyed by both. Per-model pooled figures are reported under
measuredAt.byModel for reference and never stand in for a configuration.

Hand-copied numbers go stale the moment another lane finishes. This script is
the deterministic alternative: run it after every cost-harvest and the matrix
is current by construction. The monthly recompute then only does the part that
actually needs judgment — adjudicating predictions and revising scores — instead
of transcribing figures.

DRIFT ALARM: each config keeps an `adjudicated` snapshot frozen at the last
human review. When a measured value moves more than -DriftPct from it, that is
reported — because that is the moment a routing decision might flip. Auto-update
without drift detection just hides the change; this surfaces it.

.EXAMPLE
./matrix-refresh.ps1                 # refresh + report drift
./matrix-refresh.ps1 -Adjudicate     # accept current values as the new baseline
./matrix-refresh.ps1 -DryRun         # show what would change, write nothing
                                     # (NOT -WhatIf: that name is reserved, and
                                     #  shadowing it binds downstream cmdlets'
                                     #  arguments to the inherited switch)
#>
[CmdletBinding()]
param(
  [int]$SinceDays = 30,
  # Percentage move from the adjudicated baseline that counts as material.
  [int]$DriftPct = 25,
  # Freeze current measurements as the new adjudicated baseline. Do this at the
  # recompute, after a human has looked — never automatically.
  [switch]$Adjudicate,
  [switch]$DryRun,
  [switch]$Json,
  [string]$Matrix,
  [string]$CostLedger,
  [string]$DispatchLog
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "controller-install-lock.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot "review-head-contract.psm1") -Force -DisableNameChecking
if (-not $Matrix)      { $Matrix = Join-Path $HOME ".claude/skills/model-routing/capability-matrix.json" }
if (-not $CostLedger)  { $CostLedger = Join-Path $PSScriptRoot "cost-ledger.jsonl" }
if (-not $DispatchLog) { $DispatchLog = Join-Path $PSScriptRoot "dispatch-log.jsonl" }

if (-not (Test-Path -LiteralPath $Matrix)) { throw "capability matrix not found: $Matrix" }

Invoke-WithControllerInstallLock -Body {

$nowUtc = (Get-Date).ToUniversalTime()
$cutoff = $nowUtc.AddDays(-$SinceDays)

function Read-Jsonl([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return @() }
  $out = @()
  foreach ($line in Get-Content -LiteralPath $Path) {
    if (-not $line.Trim()) { continue }
    try { $out += ($line | ConvertFrom-Json -DateKind String) } catch { continue }
  }
  $out
}

# Exact model version is evidence identity. A successor never inherits its
# predecessor's evidence, vetoes, or rates.
#
# THE LINE THIS DRAWS, and why it moved: v4.0 excluded every non-canonical
# spelling, to stop an earlier repair that had guessed bare aliases into one
# bucket. Correct in intent, too wide in effect — it also discarded spellings
# that ALREADY NAME THE VERSION. `sonnet-5` and `Sonnet 5` differ from
# `claude-sonnet-5` in punctuation, not identity, so folding them in is a
# spelling repair and cannot transfer evidence to a successor: the version
# digit is carried through, never inferred.
#
# `sonnet` / `fable` / `opus` bare stay excluded. Those cannot be resolved to a
# version at all, and resolving them is exactly the guess v4.0 was protecting
# against. That protection is intact.
#
# This mattered: the excluded set was not random. Every contaminated spelling
# was a Claude config, so the exclusion silently shrank one side of precisely
# the comparison the P1/P2/P5/P6 experiments turn on. The emitter has rejected
# aliases outright since 2026-07-26 (log-event.ps1 Assert-ExactModelVersion),
# so this repair is bounded to the 07-16 → 07-24 history and cannot regrow.
function Get-CanonicalModel([string]$Name) {
  if (-not $Name) { return $null }
  # Whitespace forms ("Sonnet 5", "GPT-5.6 Sol") are the same identity.
  $n = ($Name.Trim().ToLowerInvariant() -replace '\s+', '-')

  $canon = $null
  if ($n -match '^(?:claude-)?(fable|opus|sonnet)-(\d+(?:[-.]\d+)*)$') {
    $version = $Matches[2] -replace '\.', '-'
    $canon = "claude-$($Matches[1])-$version"
  }
  elseif ($n -match '^gpt-\d+(?:\.\d+)*-[a-z0-9]+(?:-[a-z0-9]+)*$') {
    $canon = $n
  }
  # Checked AFTER normalization so a bare `opus-4-8` cannot slip the deprecation.
  if ($canon -eq "claude-opus-4-8") { return $null }
  return $canon
}

# Every spelling encountered, so exclusion is never silent again. The failure
# this closes was not that rows were dropped — dropping ambiguous rows is
# correct — it was that nothing said how many, or whose.
$identityAudit = @{}
function Add-IdentityAudit([string]$Raw) {
  if (-not $Raw) { return }
  $canon = Get-CanonicalModel $Raw
  if (-not $identityAudit.ContainsKey($Raw)) {
    $identityAudit[$Raw] = [ordered]@{
      canonical = $canon
      repaired  = [bool]($canon -and $canon -ne $Raw)
      rows      = 0
    }
  }
  $identityAudit[$Raw].rows += 1
}

# Outcome vocabulary drifted the same way model names did — 17 distinct values
# across the log. Treating "anything not BLOCK*" as a pass silently counts
# RETRY / skip / LOAD_SENSITIVE / TIMEOUT_ONLY_* as successes and biases every
# block rate DOWNWARD. Indeterminate outcomes are excluded from the denominator
# instead of being scored as wins.
function Get-OutcomeClass([string]$Outcome) {
  if (-not $Outcome) { return "exclude" }
  $o = $Outcome.Trim().ToUpperInvariant()
  # ORDER IS LOad-BEARING: every mechanical pattern must be tested before the
  # generic ^BLOCK, or it is swallowed by it. That swallowing was the bug —
  # BLOCKED_MECHANICAL and MECHANICAL_PROMPT_BLOCK scored as author-quality
  # blocks, so a config that drew a flaky harness looked like a config that
  # wrote bad code, and every per-config rate was biased UPWARD.
  switch -Regex ($o) {
    '^BLOCK_MECHANICAL$'   { return "mechanical" }
    '^BLOCKED_MECHANICAL$' { return "mechanical" }
    '^MECHANICAL'          { return "mechanical" } # MECHANICAL_PROMPT_BLOCK
    '^FAILED_CLEAN_MAIN$'  { return "mechanical" } # reproduces without the change
    '^BLOCK'               { return "block" }   # BLOCK, BLOCK_FIXABLE, BLOCK_REPLAN
    '^REPLAN_REQUIRED$'    { return "block" }
    '^READY_FOR_REPAIR$'   { return "block" }   # review says repair needed
    '^REJECT'              { return "block" }   # a rejection is a block by another name
    '^FAILED$'             { return "block" }
    '^PASS'                { return "pass" }    # PASS, PASS_CI, PASS_SERIALIZED, PASS_EXTERNAL_FLAKE
    '^SHIPPED'             { return "pass" }
    '^RECOVERED'           { return "pass" }
    default                { return "exclude" } # skip, RETRY, LOAD_SENSITIVE,
                                                # INDETERMINATE,
                                                # GREEN_LOAD_DISCRIMINATED,
                                                # BLOCKED_ON_PRODUCT_DEFECTS,
                                                # TIMEOUT_ONLY_PENDING_DISCRIMINATOR
  }
}

function Get-Median([double[]]$Values) {
  if (-not $Values -or $Values.Count -eq 0) { return $null }
  $s = @($Values | Sort-Object)
  $mid = [math]::Floor($s.Count / 2)
  if ($s.Count % 2 -eq 1) { return [double]$s[$mid] }
  return (([double]$s[$mid - 1] + [double]$s[$mid]) / 2)
}

# ------------------------------------------------------------------- inputs --
# De-dupe the ledger: later rows for a transcript supersede earlier ones.
$byTranscript = @{}
foreach ($r in (Read-Jsonl $CostLedger)) {
  if ($r.transcript) { $byTranscript[$r.transcript] = $r }
}
$ledger = @()
foreach ($r in $byTranscript.Values) {
  $routingUsd = if ($r.PSObject.Properties["usdCurrent"] -and $null -ne $r.usdCurrent) {
    [double]$r.usdCurrent
  } elseif ($null -ne $r.usd) {
    # Backward compatibility for reported-cost rows and ledgers harvested
    # before usdCurrent existed. Force-reharvest Codex traces after a price
    # change so this fallback never mixes price eras in a routing comparison.
    [double]$r.usd
  } else {
    $null
  }
  if ($null -eq $routingUsd) { continue }
  $routingSource = if ($r.PSObject.Properties["routingCostSource"] -and $r.routingCostSource) {
    "$($r.routingCostSource)"
  } else {
    "$($r.costSource)"
  }
  $r | Add-Member -NotePropertyName routingUsd -NotePropertyValue $routingUsd -Force
  $r | Add-Member -NotePropertyName routingCostSource -NotePropertyValue $routingSource -Force
  $ts = $null
  try { $ts = [datetime]::Parse($r.ts, $null, [System.Globalization.DateTimeStyles]::AdjustToUniversal) } catch { continue }
  if ($ts -lt $cutoff) { continue }
  $ledger += $r
}
foreach ($r in $ledger) { Add-IdentityAudit "$($r.model)" }
$excludedModelLedger = @($ledger | Where-Object { -not (Get-CanonicalModel $_.model) })
$excludedModelUsd = (($excludedModelLedger | Measure-Object -Property routingUsd -Sum).Sum)
$ledger = @($ledger | Where-Object { Get-CanonicalModel $_.model })

$dispatch = Read-Jsonl $DispatchLog

# ----------------------------------------------------------- effort identity --
# The routing unit is a CONFIGURATION: exact model version + exact effort
# (model-routing v4.13). Until v4.13 every measured block was pooled per
# model, so `sol-max` reported Sol's whole sample as its own n and an effort
# cell could never be falsified. The ledger carries no effort, so it is joined
# from the dispatch log on the transcript (the documented join key), reading
# `effortUsed` over the requested `effort`, and otherwise parsed from the
# transcript name's `<issue>-<model token>-<effort>-` convention — the same
# convention cost-harvest.ps1 already trusts for Codex model identity. A run
# whose effort resolves neither way still counts for its model and its row,
# but for no configuration: unknown is reported, never guessed.
$validEfforts = @("minimal", "low", "medium", "high", "xhigh", "max")
function Get-CanonicalEffort([string]$Value) {
  if (-not $Value) { return $null }
  $e = $Value.Trim().ToLowerInvariant()
  if ($e -in $validEfforts) { return $e }
  return $null
}
function Get-EffortFromTranscriptName([string]$Name) {
  if (-not $Name) { return $null }
  $base = [IO.Path]::GetFileNameWithoutExtension($Name).ToLowerInvariant()
  # Legacy Sol/Terra/Luna and Claude labels: `<issue>-<token>-<effort>-...`.
  if ($base -match '(^|-)\d{3,5}-(?:sol|terra|luna|opus5|sonnet5|fable5(?:\.1|1)?)-(minimal|low|medium|high|xhigh|max)(-|$)') { return $Matches[2] }
  # Astra closes its selector with the unambiguous double-hyphen delimiter.
  if ($base -cmatch '(^|-)(?:gpt-6-astra|astra6)--(minimal|low|medium|high|xhigh|max)(-|$)') { return $Matches[2] }
  return $null
}

$effortByTranscript = @{}
# Author-shaped dispatches (implementation/planning, or legacy rows that name
# no author) keyed by issue + exact model, as (ts, effort) pairs. A review
# receipt without `authorEffort` resolves its author's effort from this only
# when every author dispatch up to the receipt's own instant agrees.
$authorDispatchEfforts = @{}
foreach ($e in $dispatch) {
  if ($e.kind -ne "dispatch") { continue }
  $used = if ($e.PSObject.Properties["effortUsed"] -and $e.effortUsed) { "$($e.effortUsed)" } else { $null }
  $req  = if ($e.PSObject.Properties["effort"] -and $e.effort) { "$($e.effort)" } else { $null }
  $effort = Get-CanonicalEffort $(if ($used) { $used } else { $req })
  if (-not $effort) { continue }
  if ($e.PSObject.Properties["transcript"] -and $e.transcript) { $effortByTranscript["$($e.transcript)"] = $effort }
  $laneRole = if ($e.PSObject.Properties["laneRole"] -and $e.laneRole) { "$($e.laneRole)" } else { $null }
  $namesAuthor = $e.PSObject.Properties["authorModel"] -and $e.authorModel
  $authorShaped = ($laneRole -in @("implementation", "planning")) -or (-not $laneRole -and -not $namesAuthor)
  if (-not $authorShaped -or -not $e.issue) { continue }
  $exactModel = Get-CanonicalModel $e.model
  if (-not $exactModel) { continue }
  $ts = $null
  try { $ts = [datetime]::Parse($e.ts, $null, [System.Globalization.DateTimeStyles]::AdjustToUniversal) } catch { $ts = [datetime]::MinValue }
  $k = "$($e.issue)`u{001f}$exactModel"
  if (-not $authorDispatchEfforts.ContainsKey($k)) { $authorDispatchEfforts[$k] = @() }
  $authorDispatchEfforts[$k] += ,@($ts, $effort)
}

$effortIdentity = [ordered]@{
  ledgerRunsResolved = 0; byDispatchTranscript = 0; byTranscriptName = 0
  ledgerRunsUnresolved = 0; ledgerUsdUnresolved = 0.0
  reviewRowsResolved = 0; byAuthorEffortField = 0; byUniqueAuthorDispatch = 0
  reviewRowsAmbiguous = 0; reviewRowsUnresolved = 0
}
foreach ($r in $ledger) {
  $effort = $null; $source = $null
  if ($r.transcript -and $effortByTranscript.ContainsKey("$($r.transcript)")) { $effort = $effortByTranscript["$($r.transcript)"]; $source = "dispatch" }
  if (-not $effort) { $effort = Get-EffortFromTranscriptName "$($r.transcript)"; if ($effort) { $source = "name" } }
  $r | Add-Member -NotePropertyName routingEffort -NotePropertyValue $effort -Force
  if ($effort) {
    $effortIdentity.ledgerRunsResolved += 1
    if ($source -eq "dispatch") { $effortIdentity.byDispatchTranscript += 1 } else { $effortIdentity.byTranscriptName += 1 }
  } else {
    $effortIdentity.ledgerRunsUnresolved += 1
    $effortIdentity.ledgerUsdUnresolved += [double]$r.routingUsd
  }
}

function New-RunFacts($Group) {
  $sum  = ($Group | Measure-Object -Property routingUsd -Sum).Sum
  $durs = @($Group | Where-Object { $_.durationSec } | ForEach-Object { [double]$_.durationSec })
  $med  = Get-Median $durs
  $perRun = [math]::Round($sum / @($Group).Count, 2)
  [ordered]@{
    usdPerRun = $perRun
    medianMin = if ($null -ne $med) { [math]::Round($med / 60, 1) } else { $null }
    usdPerMin = if ($null -ne $med -and $med -gt 0) { [math]::Round($perRun / ($med / 60), 2) } else { $null }
    n         = @($Group).Count
    src       = (($Group.routingCostSource | Sort-Object -Unique) -join ",")
    durSrc    = (($Group.durationSrc | Where-Object { $_ } | Sort-Object -Unique) -join ",")
  }
}

# ---------------------------------------------------------- per-model facts --
# Pooled across efforts. Reported under measuredAt.byModel for reference and
# never written to a config's `measured` block: that pooling was the defect.
$modelFacts = @{}
foreach ($g in ($ledger | Group-Object { Get-CanonicalModel $_.model })) {
  if (-not $g.Name) { continue }
  $modelFacts[$g.Name] = New-RunFacts $g.Group
}

# --------------------------------------------------------- per-config facts --
$configFacts = @{}
foreach ($g in ($ledger | Where-Object { $_.routingEffort } | Group-Object { "$(Get-CanonicalModel $_.model)`u{001f}$($_.routingEffort)" })) {
  if (-not $g.Name) { continue }
  $configFacts[$g.Name] = New-RunFacts $g.Group
}

# ------------------------------------------------------------ per-row costs --
$rowByIssueModel = @{}
$rowByIssue = @{}
foreach ($e in $dispatch) {
  $row = if ($e.PSObject.Properties["row"] -and $e.row) { "$($e.row)" }
         elseif ($e.PSObject.Properties["routingRow"] -and $e.routingRow) { "$($e.routingRow)" }
         else { $null }
  if (-not $row -or -not $e.issue) { continue }
  $exactModel = Get-CanonicalModel $e.model
  if ($exactModel) { $rowByIssueModel["$($e.issue)`u{001f}$exactModel"] = $row }
  if (-not $rowByIssue.ContainsKey("$($e.issue)")) { $rowByIssue["$($e.issue)"] = $row }
}

$rowFacts = @{}
# Per-row cost POOLS every model on that row, so it cannot answer the only
# question the experiments actually ask: what does THIS config cost on THIS
# row, against the incumbent it is challenging. P1 ("<=50% USD/artifact" on
# row 8) and P2 ("<=60%" on row 7) are both stated that way, and the rubric
# forbids routing off a pooled aggregate — yet the pooled cell was all this
# script emitted, so every adjudication had to recompute the split by hand.
$rowModelFacts = @{}
# Row x model still pools every effort of that model, so it cannot compare a
# challenger configuration against an incumbent configuration on the row they
# contest — which is how every v4.12 quota threshold is written. byRowConfig
# is that comparison; byRowModel remains the per-model row cost.
$rowConfigFacts = @{}
$unattributed = 0.0
foreach ($c in $ledger) {
  $row = $null
  $exactModel = Get-CanonicalModel $c.model
  if ($c.issue) {
    $k = if ($exactModel) { "$($c.issue)`u{001f}$exactModel" } else { $null }
    if ($k -and $rowByIssueModel.ContainsKey($k)) { $row = $rowByIssueModel[$k] }
    elseif ($rowByIssue.ContainsKey("$($c.issue)")) { $row = $rowByIssue["$($c.issue)"] }
  }
  if (-not $row) { $unattributed += [double]$c.routingUsd; continue }
  if (-not $rowFacts.ContainsKey($row)) { $rowFacts[$row] = [ordered]@{ runs = 0; usd = 0.0 } }
  $rowFacts[$row].runs += 1
  $rowFacts[$row].usd += [double]$c.routingUsd

  if ($exactModel) {
    $rmKey = "row$row`u{001f}$exactModel"
    if (-not $rowModelFacts.ContainsKey($rmKey)) {
      $rowModelFacts[$rmKey] = [ordered]@{ row = $row; model = $exactModel; runs = 0; usd = 0.0; durs = @() }
    }
    $rowModelFacts[$rmKey].runs += 1
    $rowModelFacts[$rmKey].usd += [double]$c.routingUsd
    if ($c.durationSec) { $rowModelFacts[$rmKey].durs += [double]$c.durationSec }

    if ($c.routingEffort) {
      $rcKey = "row$row`u{001f}$exactModel`u{001f}$($c.routingEffort)"
      if (-not $rowConfigFacts.ContainsKey($rcKey)) {
        $rowConfigFacts[$rcKey] = [ordered]@{ row = $row; model = $exactModel; effort = $c.routingEffort; runs = 0; usd = 0.0; durs = @() }
      }
      $rowConfigFacts[$rcKey].runs += 1
      $rowConfigFacts[$rcKey].usd += [double]$c.routingUsd
      if ($c.durationSec) { $rowConfigFacts[$rcKey].durs += [double]$c.durationSec }
    }
  }
}
foreach ($k in @($rowFacts.Keys)) {
  $rowFacts[$k].usdPerRun = [math]::Round($rowFacts[$k].usd / $rowFacts[$k].runs, 2)
  $rowFacts[$k].usd = [math]::Round($rowFacts[$k].usd, 2)
}
foreach ($table in @($rowModelFacts, $rowConfigFacts)) {
  foreach ($k in @($table.Keys)) {
    $cell = $table[$k]
    $med = Get-Median ([double[]]$cell.durs)
    $cell.usdPerRun = [math]::Round($cell.usd / $cell.runs, 2)
    $cell.usd = [math]::Round($cell.usd, 2)
    $cell.medianMin = if ($null -ne $med) { [math]::Round($med / 60, 1) } else { $null }
    $cell.Remove("durs")
  }
}

# ------------------------------------------------- block rate by author model --
$blockRate = @{}
$blockRateByRow = @{}
# Row x author CONFIGURATION. A receipt's own `effort` is the reviewer's dial,
# not the author's; the author's effort comes from the receipt's `authorEffort`
# (log-event.ps1 -AuthorEffort, v4.13) or, for history, from the author's own
# dispatch rows when they agree. Disagreement is reported as ambiguous and the
# receipt still scores the author's model, never a guessed configuration.
$blockRateByRowConfig = @{}
$excludedOutcomes = 0
$mechanicalExcluded = 0
foreach ($e in ($dispatch | Where-Object {
  if ($_.kind -notin @("review-complete","verify-complete") -or -not $_.authorModel -or -not $_.outcome) { return $false }
  $classification = Get-ControllerReviewRowClassification $_
  return -not $classification.strict -or ($classification.valid -and $classification.reviewAuthority -ceq "governing")
})) {
  Add-IdentityAudit "$($e.authorModel)"
  $class = Get-OutcomeClass "$($e.outcome)"
  # A mechanical failure is not evidence about the author — the rubric says so
  # for escalation, and it has to hold for measurement too, or the config that
  # drew a flaky harness is charged for it.
  if ($class -eq "mechanical") { $mechanicalExcluded += 1; continue }
  if ($class -eq "exclude") { $excludedOutcomes += 1; continue }
  $a = Get-CanonicalModel "$($e.authorModel)"
  if (-not $a) { $excludedOutcomes += 1; continue }
  if (-not $blockRate.ContainsKey($a)) { $blockRate[$a] = [ordered]@{ reviews = 0; blocks = 0 } }
  $blockRate[$a].reviews += 1
  if ($class -eq "block") { $blockRate[$a].blocks += 1 }

  $authorEffort = $null
  $authorEffortAmbiguous = $false
  if ($e.PSObject.Properties["authorEffort"] -and $e.authorEffort) {
    $authorEffort = Get-CanonicalEffort "$($e.authorEffort)"
    if ($authorEffort) { $effortIdentity.byAuthorEffortField += 1 }
  }
  if (-not $authorEffort -and $e.issue -and $authorDispatchEfforts.ContainsKey("$($e.issue)`u{001f}$a")) {
    $receiptTs = [datetime]::MaxValue
    try { $receiptTs = [datetime]::Parse($e.ts, $null, [System.Globalization.DateTimeStyles]::AdjustToUniversal) } catch { }
    $seen = @($authorDispatchEfforts["$($e.issue)`u{001f}$a"] | Where-Object { $_[0] -le $receiptTs } | ForEach-Object { $_[1] } | Sort-Object -Unique)
    if ($seen.Count -eq 1) { $authorEffort = $seen[0]; $effortIdentity.byUniqueAuthorDispatch += 1 }
    elseif ($seen.Count -gt 1) { $authorEffortAmbiguous = $true }
  }
  if ($authorEffort) { $effortIdentity.reviewRowsResolved += 1 }
  elseif ($authorEffortAmbiguous) { $effortIdentity.reviewRowsAmbiguous += 1 }
  else { $effortIdentity.reviewRowsUnresolved += 1 }

  # Stratify by routing row. The aggregate is difficulty-confounded — Sol and
  # Fable draw the full-path work — so a per-row rate is the only fair
  # comparison between two configs.
  $r = if ($e.issue -and $rowByIssue.ContainsKey("$($e.issue)")) { $rowByIssue["$($e.issue)"] } else { $null }
  if ($r) {
    $key = "row$r`u{001f}$a"
    if (-not $blockRateByRow.ContainsKey($key)) { $blockRateByRow[$key] = [ordered]@{ row = $r; model = $a; reviews = 0; blocks = 0 } }
    $blockRateByRow[$key].reviews += 1
    if ($class -eq "block") { $blockRateByRow[$key].blocks += 1 }
    if ($authorEffort) {
      $ckey = "row$r`u{001f}$a`u{001f}$authorEffort"
      if (-not $blockRateByRowConfig.ContainsKey($ckey)) { $blockRateByRowConfig[$ckey] = [ordered]@{ row = $r; model = $a; effort = $authorEffort; reviews = 0; blocks = 0 } }
      $blockRateByRowConfig[$ckey].reviews += 1
      if ($class -eq "block") { $blockRateByRowConfig[$ckey].blocks += 1 }
    }
  }
}
foreach ($k in @($blockRate.Keys)) {
  $blockRate[$k].blockRate = [math]::Round($blockRate[$k].blocks / $blockRate[$k].reviews, 2)
}
# Keep only cells with enough n to say anything; below 3 it is noise.
foreach ($table in @($blockRateByRow, $blockRateByRowConfig)) {
  foreach ($k in @($table.Keys)) {
    if ($table[$k].reviews -lt 3) { $table.Remove($k); continue }
    $table[$k].blockRate = [math]::Round($table[$k].blocks / $table[$k].reviews, 2)
  }
}

# ------------------------------------------------------------------ rewrite --
$m = Get-Content -LiteralPath $Matrix -Raw | ConvertFrom-Json

$drift = @()
$updated = 0
$withoutEffortEvidence = @()
foreach ($cfg in $m.configs) {
  $cfgEffort = Get-CanonicalEffort "$($cfg.effort)"
  $cfgModel = Get-CanonicalModel "$($cfg.model)"
  # A configuration is two-dimensional (exact model + effort); its id is the
  # DERIVED key `<exact selector>/<effort>`, never a nickname. A hand-named id
  # is how `astra-high` shipped without a version and how a successor could
  # inherit a predecessor's key, so a mismatch refuses the whole refresh
  # rather than guessing which of the two the author meant.
  if (-not $cfgModel -or -not $cfgEffort -or "$($cfg.id)" -cne "$cfgModel/$cfgEffort") {
    throw "capability matrix config id '$($cfg.id)' must be exactly '<exact model selector>/<effort>' for model '$($cfg.model)' and effort '$($cfg.effort)' (expected '$cfgModel/$cfgEffort')"
  }
  $facts = $configFacts["$cfgModel`u{001f}$cfgEffort"]
  if (-not $facts) {
    # No run resolved to this exact configuration. A pooled model figure must
    # not stand in for it, and a stale pooled block must not linger.
    if ($cfg.PSObject.Properties["measured"]) { $cfg.PSObject.Properties.Remove("measured") }
    $withoutEffortEvidence += $cfg.id
    continue
  }

  $prior = if ($cfg.PSObject.Properties["adjudicated"]) { $cfg.adjudicated } else { $null }
  if ($prior -and $prior.usdPerRun -and $facts.usdPerRun) {
    $delta = [math]::Abs($facts.usdPerRun - $prior.usdPerRun) / [double]$prior.usdPerRun * 100
    if ($delta -ge $DriftPct) {
      $drift += [pscustomobject]@{
        config = $cfg.id
        was    = $prior.usdPerRun
        now    = $facts.usdPerRun
        pct    = [math]::Round($delta, 0)
        since  = $prior.at
      }
    }
  }

  $measured = [ordered]@{
    usdPerRun = $facts.usdPerRun; medianMin = $facts.medianMin
    usdPerMin = $facts.usdPerMin; n = $facts.n
    src = $facts.src; durSrc = $facts.durSrc
    # Exact model + exact effort. Pooled per-model figures live only in
    # measuredAt.byModel.
    basis = "model+effort"
  }
  # Remove the hand-written cost fields this block supersedes — two sources
  # for the same number is a staleness trap, and the generated one wins.
  foreach ($legacy in @("usdPerRun","medianMin","usdPerMin","usdSrc","usdN","usdPerArtifact")) {
    if ($cfg.PSObject.Properties[$legacy]) { $cfg.PSObject.Properties.Remove($legacy) }
  }
  if ($cfg.PSObject.Properties["measured"]) { $cfg.measured = [pscustomobject]$measured }
  else { $cfg | Add-Member -NotePropertyName measured -NotePropertyValue ([pscustomobject]$measured) }

  if ($Adjudicate) {
    $snap = [pscustomobject][ordered]@{ usdPerRun = $facts.usdPerRun; medianMin = $facts.medianMin; n = $facts.n; at = $nowUtc.ToString("yyyy-MM-dd") }
    if ($cfg.PSObject.Properties["adjudicated"]) { $cfg.adjudicated = $snap }
    else { $cfg | Add-Member -NotePropertyName adjudicated -NotePropertyValue $snap }
  }
  $updated++
}

$stamp = [pscustomobject][ordered]@{
  at              = $nowUtc.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
  # The shape of every generated block and table this script writes. An
  # install carries live generated content onto a candidate only within one
  # schema (controller-install-lock.psm1); across a change the candidate's
  # freshly regenerated content wins and the next refresh rebuilds the rest.
  generatedSchema = "measured-by-configuration/v1"
  windowDays      = $SinceDays
  runsWithCost    = $ledger.Count
  costBasis       = "current-price-normalized"
  totalUsd        = [math]::Round((($ledger | Measure-Object -Property routingUsd -Sum).Sum), 2)
  configsUpdated  = $updated
  # Configs whose exact model + effort resolved to no costed run in the window.
  # They carry no `measured` block: unknown routes conservatively.
  configsWithoutEffortEvidence = @($withoutEffortEvidence)
  byRow           = [pscustomobject]$rowFacts
  # Pooled per model across efforts. Reference only; never a config's cost.
  byModel         = [pscustomobject]$modelFacts
  # byRow pools every model on the row; byRowModel pools every effort of one
  # model on the row. Neither compares two configurations.
  byRowModel      = [pscustomobject]$rowModelFacts
  # Row x exact model x exact effort: the cost contract for every quota
  # threshold and rebalance comparison (model-routing v4.13).
  byRowConfig     = [pscustomobject]$rowConfigFacts
  blockRateByAuthor = [pscustomobject]$blockRate
  # The aggregate above is difficulty-confounded; this is the fair comparison.
  blockRateByRow    = [pscustomobject]$blockRateByRow
  # Row x author configuration. The quality side of the config comparison.
  blockRateByRowConfig = [pscustomobject]$blockRateByRowConfig
  effortIdentity = [pscustomobject]([ordered]@{
    ledgerRunsResolved = $effortIdentity.ledgerRunsResolved
    byDispatchTranscript = $effortIdentity.byDispatchTranscript
    byTranscriptName = $effortIdentity.byTranscriptName
    ledgerRunsUnresolved = $effortIdentity.ledgerRunsUnresolved
    ledgerUsdUnresolved = [math]::Round($effortIdentity.ledgerUsdUnresolved, 2)
    reviewRowsResolved = $effortIdentity.reviewRowsResolved
    byAuthorEffortField = $effortIdentity.byAuthorEffortField
    byUniqueAuthorDispatch = $effortIdentity.byUniqueAuthorDispatch
    reviewRowsAmbiguous = $effortIdentity.reviewRowsAmbiguous
    reviewRowsUnresolved = $effortIdentity.reviewRowsUnresolved
  })
  effortIdentityNote = "A run's effort is the dispatch row joined on its transcript (effortUsed over effort), else the <issue>-<model>-<effort>- transcript-name token; a receipt's author effort is its authorEffort field, else the author's own dispatch rows up to the receipt instant when they agree. Unresolved or ambiguous rows count for the model and the row but for no configuration."
  outcomesExcluded  = $excludedOutcomes
  outcomeNote       = "Indeterminate outcomes (RETRY, skip, LOAD_SENSITIVE, GREEN_LOAD_DISCRIMINATED, BLOCKED_ON_PRODUCT_DEFECTS, TIMEOUT_ONLY_*) are excluded from the denominator, not scored as passes."
  mechanicalExcluded = $mechanicalExcluded
  mechanicalNote    = "Mechanical failures (BLOCK_MECHANICAL, MECHANICAL_PROMPT_BLOCK, FAILED_CLEAN_MAIN) are excluded from author block rate: they measure the harness, not the author. Counting them as blocks biases every per-config rate upward."
  modelIdentityRowsExcluded = $excludedModelLedger.Count
  modelIdentityUsdExcluded = [math]::Round($(if ($null -eq $excludedModelUsd) { 0 } else { $excludedModelUsd }), 2)
  # Per-spelling, so an exclusion can never again be large, one-sided and silent.
  modelIdentityAudit = [pscustomobject]$identityAudit
  modelIdentityNote = "Version-EXPLICIT spellings (sonnet-5, 'Sonnet 5') are normalized onto their canonical id: the version is carried through, never inferred. Bare family aliases (sonnet, fable, opus) and deprecated versions remain excluded rather than mapped onto a successor."
  usdNotJoinedToRow = [math]::Round($unattributed, 2)
  generatedBy     = ".orchestrator/matrix-refresh.ps1 — do NOT hand-edit any `measured` block or this stamp"
}
if ($m.PSObject.Properties["measuredAt"]) { $m.measuredAt = $stamp }
else { $m | Add-Member -NotePropertyName measuredAt -NotePropertyValue $stamp }

if (-not $DryRun) {
  # NOT $json: PowerShell variable names are case-insensitive, so that would
  # assign a String to the [switch]$Json PARAMETER, which keeps its type
  # constraint for the whole scope — a String->SwitchParameter cast error whose
  # message dumps the entire matrix and hides the real cause.
  $payload = $m | ConvertTo-Json -Depth 30
  Invoke-WithControllerInstallLock -Body {
    Set-Content -LiteralPath $Matrix -Encoding utf8 -Value $payload
  }
}

$result = [ordered]@{
  matrix = $Matrix; windowDays = $SinceDays
  configsUpdated = $updated; runsWithCost = $ledger.Count
  configsWithoutEffortEvidence = @($withoutEffortEvidence)
  effortIdentity = $stamp.effortIdentity
  totalUsd = $stamp.totalUsd; rowsCosted = @($rowFacts.Keys).Count
  driftAlerts = @($drift); adjudicated = [bool]$Adjudicate; dryRun = [bool]$DryRun
}

if ($Json) { $result | ConvertTo-Json -Depth 6; return }

Write-Output "matrix-refresh: $updated configs updated from $($ledger.Count) costed runs (`$$($stamp.totalUsd), last ${SinceDays}d)$(if ($DryRun) { ' [DryRun — nothing written]' })"
Write-Output "  rows costed: $(@($rowFacts.Keys).Count) | unattributed: `$$($stamp.usdNotJoinedToRow)"
Write-Output "  effort identity: $($stamp.effortIdentity.ledgerRunsResolved) runs resolved ($($stamp.effortIdentity.byDispatchTranscript) dispatch, $($stamp.effortIdentity.byTranscriptName) name), $($stamp.effortIdentity.ledgerRunsUnresolved) unresolved (`$$($stamp.effortIdentity.ledgerUsdUnresolved)); receipts $($stamp.effortIdentity.reviewRowsResolved) resolved, $($stamp.effortIdentity.reviewRowsAmbiguous) ambiguous, $($stamp.effortIdentity.reviewRowsUnresolved) unresolved"
if ($withoutEffortEvidence.Count -gt 0) { Write-Output "  configs without effort-resolved evidence: $($withoutEffortEvidence -join ', ')" }
if ($drift.Count -gt 0) {
  Write-Output "  DRIFT >= ${DriftPct}% from the adjudicated baseline — a routing choice may have flipped:"
  $drift | ForEach-Object { Write-Output "    $($_.config): `$$($_.was) -> `$$($_.now) ($($_.pct)% since $($_.since))" }
} elseif ($Adjudicate) {
  Write-Output "  adjudicated: current values frozen as the new baseline"
} else {
  Write-Output "  no material drift from the adjudicated baseline"
}
}
