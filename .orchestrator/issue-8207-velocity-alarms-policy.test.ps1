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
$archivePath = Join-Path $controller ".orchestrator/controller-skills/milestone-orchestrator/references/rule-provenance-v2.24.md"
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
  'Every cycle the host runs `.orchestrator/velocity-metrics.ps1 -Summary`, which records one observation and reports `velocity-report/v1`.',
  'It raises only two alarms. Everything else in the report is diagnostic context that never triggers work or files an issue.',
  'FLOOR: fewer than two product issues have an agent-owned next step (a live lane, running hosted CI, or the unblocked merge queue) while a ready product issue is idle or an exact-head PASS product PR is held, continuously for 60 minutes.',
  'count each PR once with its hold identities, never as ready idle or queue-only flow.',
  'Name both idle and held causes and the host action.',
  'The host fixes it the same cycle by dispatching, backfilling (§4) or unblocking, and logs `decision-resolved` with `velocity:FLOOR` in the note. It needs no retro.',
  'DROUGHT: no product-milestone merge for 48 hours, re-armed every further 48 hours.',
  'For these metrics, `committed-product-milestone/v1` counts every issue kind',
  'canonical dispatch/review controller evidence at any age excludes controller-owned issues. Ownership does not expire with the observation window.',
  'Kind changes never produce `lateProductRelabels`; that compatibility field remains empty',
  'The host dispatches one independent diagnosis decision lane with the report, bounded to 60 minutes, and logs `velocity:DROUGHT`.',
  'a rule change that removes at least as many skill lines as it adds',
  'or, only when Todd''s current priority is blocked by something external, one priority question under §11.',
  'UNKNOWN facts raise no alarm and never read as OK; the host repairs the named gap.',
  'A miss re-diagnoses; it never auto-reverts and never adds a rule by itself.',
  'Until the heartbeat ships in #8222, the host checks `unacted` in each cycle''s summary (FLOOR 2 hours, DROUGHT 4 hours).',
  'It asks Todd nothing.'
)

function Test-VelocityAlarms([string]$Text) {
  $normalized = Normalize-Text $Text
  if ([regex]::Matches($normalized, "(?m)^# Milestone Orchestrator \(v2\.\d+, \d{4}-\d{2}-\d{2}\)$").Count -ne 1) { return $false }
  $section = Get-Section $normalized 13
  if ($null -eq $section) { return $false }
  $compact = Compact-Text $section
  foreach ($rule in $script:rules) {
    if (-not $compact.Contains((Compact-Text $rule), [StringComparison]::Ordinal)) { return $false }
  }
  # Release history lives in the archive; only the current release note remains.
  $notes = [regex]::Matches($normalized, "(?m)^Version 2\.\d+ ")
  if ($notes.Count -ne 1 -or -not $notes[0].Value.StartsWith("Version 2.99 ", [StringComparison]::Ordinal)) { return $false }
  return $true
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
Assert-8207 ($archive.Contains("## Release notes moved in v2.87", [StringComparison]::Ordinal)) "archive lacks the v2.87 release-notes section"
Assert-8207 ($archive.Contains("## Release notes moved in v2.88", [StringComparison]::Ordinal)) "archive lacks the v2.88 release-notes section"
Assert-8207 ($archive.Contains("## Release notes moved in v2.85", [StringComparison]::Ordinal)) "archive lacks the v2.85 release-notes section"
foreach ($note in @("Version 2.87 adopts", "Version 4.19 resolves", "Version 2.84 codifies", "Version 2.83 bundles", "Version 2.82 codifies", "Version 2.60 removes overhead", "Version 2.56 replaces")) {
  Assert-8207 ($archive.Contains($note, [StringComparison]::Ordinal)) "archive lost release note: $note"
}

$mutants = [ordered]@{
  "reducer-not-run" = Remove-Phrase $skill 'Every cycle the host runs'
  "diagnostics-trigger-work" = Remove-Phrase $skill 'Everything else in the report is diagnostic context that never triggers work or files an issue.'
  "floor-without-continuity" = Remove-Phrase $skill ', continuously for 60 minutes'
  "floor-not-logged" = Remove-Phrase $skill 'with `velocity:FLOOR` in the note'
  "floor-needs-retro" = Remove-Phrase $skill 'It needs no retro.'
  "drought-threshold-moved" = $skill.Replace('merge for 48 hours, re-armed', 'merge for 24 hours, re-armed')
  "drought-unbounded" = Remove-Phrase $skill 'bounded to 60 minutes,'
  "drought-rule-growth" = Remove-Phrase $skill 'a rule change that removes at least as many skill lines as it adds'
  "drought-asks-todd-freely" = Remove-Phrase $skill 'only when Todd''s current priority is blocked by something external,'
  "unknown-reads-ok" = Remove-Phrase $skill 'UNKNOWN facts raise no alarm and never read as OK; the host repairs the named gap.'
  "rule-check-autoreverts" = Remove-Phrase $skill 'it never auto-reverts and never adds a rule by itself.'
  "heartbeat-host-duty-omitted" = Remove-Phrase $skill 'the host checks `unacted` in each cycle''s summary'
  "heartbeat-present-tense-restored" = $skill.Replace("Until the heartbeat ships in #8222, the host checks ``unacted`` in each cycle's`n  summary (FLOOR 2 hours, DROUGHT 4 hours).", 'A heartbeat outside the host runs the same reducer and messages the host only about an alarm unacted past its grace (FLOOR 2 hours, DROUGHT 4 hours).')
  "summary-asks-todd" = Remove-Phrase $skill 'It asks Todd nothing.'
  "history-restored" = $skill.Replace('Version 2.99 integrates', "Version 2.94 adds archived history.`n`nVersion 2.99 integrates")
  "held-counts-as-flow" = Remove-Phrase $skill 'never as ready idle or queue-only flow.'
  "held-no-host-action" = Remove-Phrase $skill 'Name both idle and held causes and the host action.'
  "kind-filter-restored" = Remove-Phrase $skill 'counts every issue kind'
  "controller-ownership-expires" = $skill.Replace('evidence at any', 'evidence at recent')
  "late-kind-relabel-restored" = Remove-Phrase $skill 'that compatibility field remains empty'
}
foreach ($entry in $mutants.GetEnumerator()) {
  Assert-8207 ($entry.Value -cne $skill) "mutant did not change the skill: $($entry.Key)"
  Assert-8207 (-not (Test-VelocityAlarms $entry.Value)) "mutant survived: $($entry.Key)"
}

if ($ExpectedControllerHead) {
  $head = (& git -C $controller rev-parse HEAD 2>&1 | Out-String).Trim()
  Assert-8207 ($LASTEXITCODE -eq 0 -and $head -ceq $ExpectedControllerHead) "expected controller head does not match"
}

Write-Output "PASS issue-8207 velocity alarms and release-history move assertions=$script:assertions mutants=$($mutants.Count)"
