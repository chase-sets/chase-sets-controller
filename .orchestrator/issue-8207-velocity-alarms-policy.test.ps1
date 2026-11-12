[CmdletBinding()]
param(
  [string]$ControllerRoot = (Split-Path -Parent $PSScriptRoot),
  [string]$ExpectedControllerHead = ""
)

# #8207 pins the velocity alarms in milestone-orchestrator section 13 and the
# v2.85/v2.86/v2.87/v2.88 moves of release history out of the live skill. Each mutant removes
# exactly one boundary.

$ErrorActionPreference = "Stop"
$controller = [IO.Path]::GetFullPath($ControllerRoot)
$skillPath = Join-Path $controller ".orchestrator/controller-skills/milestone-orchestrator/SKILL.md"
$archivePath = Join-Path $controller ".orchestrator/docs/archive/milestone-orchestrator/rule-provenance-v2.24.md"
$reducerPath = Join-Path $controller ".orchestrator/velocity-metrics.ps1"
$script:assertions = 0

function Assert-8207([bool]$Condition, [string]$Message) {
  $script:assertions += 1
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}
function Normalize-Text([string]$Text) { return ($Text -replace "`r`n", "`n" -replace "`r", "`n") }
function Compact-Text([string]$Text) { return ((Normalize-Text $Text) -replace "\s+", " ").Trim() }
function Get-Section([string]$Text, [int]$Number) {
  $match = [regex]::Match((Normalize-Text $Text), "(?ms)^## $Number\.[^\n]*\n.*?(?=^## \d+\.|\z)")
  if (-not $match.Success) { return $null }
  return $match.Value
}

$script:rules = @(
  'One foreground `velocity-metrics.ps1 -Summary` per cycle, no per-PR Reports.',
  'Every FLOOR UNMET: act on each qualified ready-idle/held PR or log concrete capacity/ordering reason',
  'in `decision-resolved`, `velocity:FLOOR`, exact observation `ts` and every identity/action.',
  'No deferral marker/park.',
  'UNKNOWN is not OK/ready/no-work proof; repair named gaps, no corpus sweep.',
  'DROUGHT: 48 hours without product merge, re-armed each 48 hours;',
  'host repairs/simplifies, asks Todd only for external-blocked priority change.',
  'For unknown facts/holds read `references/velocity.md`.'
)

function Test-VelocityAlarms([string]$Text) {
  $compact = Compact-Text $Text
  if ([regex]::Matches((Normalize-Text $Text), '(?m)^# Milestone Orchestrator \(v2\.\d+, \d{4}-\d{2}-\d{2}\)$').Count -ne 1) { return $false }
  foreach ($rule in $script:rules) { if (-not $compact.Contains((Compact-Text $rule), [StringComparison]::Ordinal)) { return $false } }
  return $Text -notmatch '(?m)^Version 2\.\d+ '
}

function Remove-Phrase([string]$Text, [string]$Phrase) {
  $pattern = ([regex]::Escape($Phrase)) -replace '\\ ', '\s+'
  $match = [regex]::Match($Text, $pattern)
  Assert-8207 $match.Success "negative control must find its boundary: $Phrase"
  return $Text.Remove($match.Index, $match.Length)
}

Assert-8207 (Test-Path -LiteralPath $reducerPath -PathType Leaf) "velocity reducer is missing"
$skill = Normalize-Text ([IO.File]::ReadAllText($skillPath))
$archive = Normalize-Text ([IO.File]::ReadAllText($archivePath))
Assert-8207 (Test-VelocityAlarms $skill) "#8207 velocity alarm policy or history move is incomplete"
$movedV2109 = Normalize-Text @'
Version 2.109 (Todd 2026-10-10, 4388/6098327249 with correction; #9282) routes
every lane a Claude model can admissibly take to Claude while the capacity
forecast balances toward Claude: planning and review lanes join implementation
lanes as capacity-eligible, every off-Claude row flips to its own Claude slot
as `override-Todd`, and a strict controller review is prepared, prelogged, then
launched (section 5). Landing authority, holds, freshness rules, selection, gap
proofs and the closed watchdog table are unchanged; model-routing v4.25 holds
the routing rule.
'@
Assert-8207 ($archive.Contains($movedV2109, [StringComparison]::Ordinal)) 'archive lost the verbatim v2.109 release note'
$movedV2111 = Normalize-Text @'
Version 2.111 (Todd 2026-10-11, 4388/6112638067; #9373) lets a governing
install proof at `-Scope full` reuse `test:*` PASS rows from a completed hosted
battery run of the exact candidate head (section 7). Guards and
`-NoReuseIdentity` items always execute, impact-scope and local-prior reuse
stay author-iteration evidence, and a second safeguard occurrence ends CI
reuse. Landing authority, holds, freshness rules, selection, gap proofs, the
closed watchdog table and model-routing v4.25 are unchanged.
'@
Assert-8207 ($archive.Contains($movedV2111, [StringComparison]::Ordinal)) 'archive lost the verbatim v2.111 release note'
$movedV2110 = Normalize-Text @'
Version 2.110 recovers an ordinary implementation author's interrupted canonical
integration (#9334). A closed `interrupted-canonical-integration/v2` binding
proves the actual wrapper/relative-helper/logging/NoPush first stop from the
retained launch, transcript and routing row; the native plan is the sequencer's
topo-order no-merges pick list; the same admitted owner finishes with `-NoPush`,
commits repairs, and publishes once under the original-head lease. Landed v1
bindings, freshness, routing, selection, velocity, DROUGHT, landing, review and
hold authority and model-routing v4.25 are unchanged.
'@
Assert-8207 ($archive.Contains($movedV2110, [StringComparison]::Ordinal)) 'archive lost the verbatim v2.110 release note'
$movedV2112 = Normalize-Text @'
Version 2.112 paces new lanes to each provider's headroom before its reset
(#9316). The read-only `capacity-pacing.ps1` reducer emits `capacity-pacing/v1`:
each available account's headroom, hours to reset and the provider's measured
burn per lane-hour become a per-provider lane budget and new-lane allowance,
Fable capped at half the Claude budget and every allowance zero on an unknown
status or census. Section 10 makes that allowance a scaling condition and
supersedes 4388/6101785942 (the hand-read dashboard routine). Dispatch-lane,
routing, the watchdog, the forecast, landing, review and hold authority and
model-routing v4.25 are unchanged.
'@
Assert-8207 ($archive.Contains($movedV2112, [StringComparison]::Ordinal)) 'archive lost the verbatim v2.112 release note'
$movedV2114 = Normalize-Text @'
Version 2.114 (#9382) makes never-launched strict review prelogs voidable from
launcher evidence and prints the exact v1 prelog. Review and install authority
are unchanged.
'@
Assert-8207 ($archive.Contains($movedV2114, [StringComparison]::Ordinal)) 'archive lost the verbatim v2.114 release note'
$movedV2115 = Normalize-Text @'
Version 2.115 adds the AgentPools pace raise (#9737) so banked credits are
spent before they lapse, in steps of at most two new lanes per run. A positive
allowance with ready work is a reason to dispatch, not a ceiling to stay under.
'@
Assert-8207 ($archive.Contains($movedV2115, [StringComparison]::Ordinal)) 'archive lost the verbatim v2.115 release note'
$movedV2105 = Normalize-Text @'
## Release notes moved in v2.106

Version 2.105 binds velocity launch attribution to the validated launcher
start rather than the later ownership record timestamp (#8674), on top of
v2.104's unscoped host/lane runtime discovery fence and snapshot-derived
retention report counts (#9021). Judged recovery and model-routing v4.23 remain
unchanged (#8903, #8915).
Routing remains data-bound as in v2.87; prior release notes are archived in
`references/rule-provenance-v2.24.md`.
'@
Assert-8207 ($archive.Contains($movedV2105, [StringComparison]::Ordinal)) 'archive lost the complete v2.105 release note'
$movedV2104 = Normalize-Text @'
## Release notes moved in v2.105

Version 2.104 binds velocity launch attribution to the validated launcher
start rather than the later ownership record timestamp (#8674).

Version 2.104 fences unscoped host/lane runtime discovery and adds snapshot-derived
retention report counts (#9021). Judged recovery and model-routing v4.23 remain
unchanged (#8903, #8915).
Routing remains data-bound as in v2.87; prior release notes are archived in
`references/rule-provenance-v2.24.md`.
'@
Assert-8207 ($archive.Contains($movedV2104, [StringComparison]::Ordinal)) "archive lost either v2.104 release note under v2.105"
$movedV2103 = Normalize-Text @'
## Release notes moved in v2.104

Version 2.103 replaces attempt-count parking with judged recovery (Todd,
4388/6022146271, #8903): every non-PASS gets a classified next step, a repeated
cause escalates the recovery level, and the fourth-attempt and 15-dispatch
thresholds trigger a step-back review that never parks. It integrates
model-routing v4.23 (#8915 public-benchmark rebalance; protected rules unchanged).
Routing remains data-bound as in v2.87; prior release notes are archived in
`references/rule-provenance-v2.24.md`.
'@
Assert-8207 ($archive.Contains($movedV2103, [StringComparison]::Ordinal)) "archive lost the verbatim v2.103 release note under v2.104"
$movedV2102 = Normalize-Text @'
## Release notes moved in v2.103

Version 2.102 integrates model-routing v4.21 and Todd's capacity-balanced fresh
dispatch (#8494), with inert shadow evidence and exact-author calibration
partitions, and adds daily verified runtime retention (#8623).
Routing remains data-bound as in v2.87; prior release notes are archived in
`references/rule-provenance-v2.24.md`.

Version 4.21 consumes Todd's capacity forecast for fresh implementations (#8494), keeps
shadow decisions inert, and separates active flips from calibration. Prior release
notes are in milestone-orchestrator's `references/rule-provenance-v2.24.md`.
'@
Assert-8207 ($archive.Contains($movedV2102, [StringComparison]::Ordinal)) "archive lost the verbatim v2.102/v4.21 release notes under v2.103"
$movedV2101 = Normalize-Text @'
## Release notes moved in v2.102

Version 2.101 integrates model-routing v4.21 and Todd's capacity-balanced fresh
dispatch (#8494), with inert shadow evidence and exact-author calibration
partitions.
Routing remains data-bound as in v2.87; prior release notes are archived in
`references/rule-provenance-v2.24.md`.
'@
Assert-8207 ($archive.Contains($movedV2101, [StringComparison]::Ordinal)) "archive lost the verbatim v2.101 release note under v2.102"
$movedV2100AndV420 = Normalize-Text @'
## Release notes moved in v2.101

Version 2.100 adds per-cycle recognized-incumbent landed reclamation (#8622).
Routing remains data-bound as in v2.87; prior release notes are archived in
`references/rule-provenance-v2.24.md`.

Version 4.20 cross-references the exhausted-brief-reviewer proof route while
preserving v4.19's data-bound routing, placements and exclusions. Prior release
notes are in milestone-orchestrator's `references/rule-provenance-v2.24.md`.
'@
Assert-8207 ($archive.Contains($movedV2100AndV420, [StringComparison]::Ordinal)) "archive lost the verbatim v2.100/v4.20 release notes under v2.101"
$movedV299 = Normalize-Text @'
## Release notes moved in v2.100

Version 2.99 adds the once-only 15-dispatch replan-or-park decision (#8527)
and gap-scoped FLOOR proof without certifying incomplete facts (#8624).
It retains v2.98's one fresh product-census evaluation only after an exact Git
deadline, retaining the 5000 ms per-evaluation bound and all non-deadline
refusals (#8578). It preserves v2.97's observation of held PASS PRs as a FLOOR
cause, queued non-hold landing evidence, and live launch issue attribution
(#8526). It projects
implementation/review board ownership on events and runs
the capped reconciliation backstop at most hourly (#8478). Native role/routing
heavy-slot eligibility, role-specific verification prompts and trusted CI-prior
battery reuse (#8528) remain unchanged, as do model-routing v4.20,
host-attributed review handoffs, the nonterminal exhausted-brief-reviewer proof
route and strict review-history reduction. Repair battery logs bind the admitted
baseline receipt.
Routing remains data-bound as in v2.87; prior release notes are archived in
`references/rule-provenance-v2.24.md`.
'@
Assert-8207 ($archive.Contains($movedV299, [StringComparison]::Ordinal)) "archive lost the verbatim combined v2.99 release note under v2.100"
Assert-8207 ($archive.Contains("## Release notes moved in v2.99", [StringComparison]::Ordinal)) "archive lacks the v2.99 release-notes section"
Assert-8207 ($archive.Contains("## Release notes moved in v2.87", [StringComparison]::Ordinal)) "archive lacks the v2.87 release-notes section"
Assert-8207 ($archive.Contains("## Release notes moved in v2.88", [StringComparison]::Ordinal)) "archive lacks the v2.88 release-notes section"
Assert-8207 ($archive.Contains("## Release notes moved in v2.85", [StringComparison]::Ordinal)) "archive lacks the v2.85 release-notes section"
foreach ($note in @("Version 2.98 adds", "Version 2.87 adopts", "Version 4.19 resolves", "Version 2.84 codifies", "Version 2.83 bundles", "Version 2.82 codifies", "Version 2.60 removes overhead", "Version 2.56 replaces")) {
  Assert-8207 ($archive.Contains($note, [StringComparison]::Ordinal)) "archive lost release note: $note"
}

$mutants = [ordered]@{}
foreach ($rule in $script:rules) {
  $pattern = ([regex]::Escape($rule)).Replace('\ ', '\s+')
  $mutated = [regex]::Replace($skill,$pattern,'MUTANT_REMOVED')
  Assert-8207 ($mutated -cne $skill) "negative control must change its boundary: $rule"
  $mutants[$rule] = $mutated
}
$mutants['history-restored'] = $skill + "`nVersion 2.1 historical note"
foreach ($entry in $mutants.GetEnumerator()) {
  Assert-8207 ($entry.Value -cne $skill) "mutant did not change the skill: $($entry.Key)"
  Assert-8207 (-not (Test-VelocityAlarms $entry.Value)) "mutant survived: $($entry.Key)"
}
foreach($rule in $script:rules){
  $mutated=Remove-Phrase $skill $rule
  Assert-8207 (-not (Test-VelocityAlarms $mutated)) "isolated policy boundary survived: $rule"
}

if ($ExpectedControllerHead) {
  $head = (& git -C $controller rev-parse HEAD 2>&1 | Out-String).Trim()
  Assert-8207 ($LASTEXITCODE -eq 0 -and $head -ceq $ExpectedControllerHead) "expected controller head does not match"
}

Write-Output "PASS issue-8207 velocity alarms and release-history move assertions=$script:assertions mutants=$($mutants.Count)"
