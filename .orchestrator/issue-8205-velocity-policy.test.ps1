[CmdletBinding()]
param(
  [string]$ControllerRoot = (Split-Path -Parent $PSScriptRoot),
  [string]$ExpectedControllerHead = ""
)

# #8205 pins Todd's 2026-09-26 velocity ruling (#4388 5845981597): hosted CI
# is the proof for every product attempt; an attempt counts only with a hosted
# CI or exact-head review verdict; no product issue waits on a diagnostic
# issue; serial blocking backfills the two-lane product floor from the next
# committed outcomes. Each mutant removes exactly one boundary.

$ErrorActionPreference = "Stop"
$controller = [IO.Path]::GetFullPath($ControllerRoot)
$skillPath = Join-Path $controller ".orchestrator/controller-skills/milestone-orchestrator/SKILL.md"
$contractPath = Join-Path $controller ".orchestrator/contracts/planning-repair-v1.md"
$script:assertions = 0

function Assert-8205([bool]$Condition, [string]$Message) {
  $script:assertions += 1
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Normalize-Text([string]$Text) {
  return ($Text -replace "`r`n", "`n" -replace "`r", "`n")
}

function Compact-Text([string]$Text) {
  return ((Normalize-Text $Text) -replace "\s+", " ").Trim()
}

function Get-Section([string]$Text, [int]$Number) {
  $match = [regex]::Match((Normalize-Text $Text), "(?ms)^## $Number\.[^\n]*\n.*?(?=^## \d+\.|\z)")
  if (-not $match.Success) { return $null }
  return $match.Value.TrimEnd("`n")
}

$script:sectionRules = @(
  @(4, 'Serial blocking backfills the floor (4388/5845981597).'),
  @(4, 'When Todd''s current priority outcome has fewer ready product issues than the floor, the remaining product lanes take ready `kind:product` issues from the next committed outcomes in marker order, regardless of track or the per-track pull window.'),
  @(4, 'Backfill is not a priority change and files no §11 question.'),
  @(4, 'The current priority keeps first claim on each lane that frees, and backfill never preempts a running lane.'),
  @(4, 'shared dispatch window or admitted by the floor backfill above.'),
  @(4, 'A probe, diagnostic or test-infrastructure issue never blocks a product issue unless the product change cannot be written without its output (4388/5845981597).'),
  @(4, 'The host removes such a link, records it on #4129, and the diagnostic runs in parallel.'),
  @(7, 'Hosted CI is the proof for every product attempt, not only DB (4388/5845981597).'),
  @(7, 'The hosted jobs on the pushed head decide it, including E2E, DB Profile, unit, static and build.'),
  @(7, 'Local E2E, local `verify:test-db` and other local full or harness runs are diagnostics only.'),
  @(7, 'No brief, decision or host prompt makes one a prerequisite for push, draft, ready or landing.'),
  @(7, 'A local-harness, environment or lock failure never parks, fails or classifies a candidate.'),
  @(7, 'The lane pushes its candidate to its draft PR and hosted CI judges it.'),
  @(7, 'An implementation attempt counts only when a pushed head receives a hosted CI verdict or an exact-head review verdict (4388/5845981597).'),
  @(7, 'Local-only failures, preparation stops, harness or environment failures, lock refusals and a lane''s own tooling defects do not count; the lane repairs them within the same attempt.'),
  @(7, 'Existing counts are recounted under this definition.'),
  @(7, 'That is a recount, not a reset: an attempt that did receive a hosted or review verdict keeps counting.'),
  @(7, 'Review, repair, and planning rounds never count toward this step-back trigger.'),
  @(12, 'Replacement never resets an attempt count, and counts follow the §7 attempt definition'),
  @(4, 'Choose the next committed outcome within Todd''s current product priority by explicit Todd steering first'),
  @(4, 'while ready, runnable `kind:product` work exists, at least two lanes serve it.')
)

$script:contractRules = @(
  'and it resets no lineage history or consumed count.',
  'The consumed count is the number of pushed heads that received a hosted CI verdict or an exact-head review verdict (milestone-orchestrator section 7); a local-only, preparation, harness or lane-tooling stop consumed no attempt.'
)

function Test-VelocityPolicy([string]$Text) {
  $normalized = Normalize-Text $Text
  if ([regex]::Matches($normalized, "(?m)^# Milestone Orchestrator \(v2\.\d+, \d{4}-\d{2}-\d{2}\)$").Count -ne 1) { return $false }
  foreach ($rule in $script:sectionRules) {
    $section = Get-Section $normalized $rule[0]
    if ($null -eq $section) { return $false }
    if (-not (Compact-Text $section).Contains((Compact-Text $rule[1]), [StringComparison]::Ordinal)) { return $false }
  }
  return $true
}

function Test-ContractPolicy([string]$Text) {
  $compact = Compact-Text $Text
  foreach ($rule in $script:contractRules) {
    if (-not $compact.Contains((Compact-Text $rule), [StringComparison]::Ordinal)) { return $false }
  }
  if ($Text -match '[^\x00-\x7F]') { return $false }
  return $true
}

function Remove-Phrase([string]$Text, [string]$Phrase) {
  $pattern = ([regex]::Escape($Phrase)) -replace '\\ ', '\s+'
  $match = [regex]::Match($Text, $pattern)
  Assert-8205 $match.Success "negative control must find its boundary: $Phrase"
  return $Text.Remove($match.Index, $match.Length)
}

Assert-8205 (Test-Path -LiteralPath $skillPath -PathType Leaf) "milestone-orchestrator source is missing"
Assert-8205 (Test-Path -LiteralPath $contractPath -PathType Leaf) "planning-repair contract is missing"
$skill = Normalize-Text ([IO.File]::ReadAllText($skillPath))
$contract = Normalize-Text ([IO.File]::ReadAllText($contractPath))
Assert-8205 (Test-VelocityPolicy $skill) "#8205 hosted-proof, attempt-count, diagnostic-blocker or backfill policy is incomplete"
Assert-8205 (Test-ContractPolicy $contract) "planning-repair consumed-count definition is incomplete"
$archivePath = Join-Path $controller ".orchestrator/controller-skills/milestone-orchestrator/references/rule-provenance-v2.24.md"
Assert-8205 ((Normalize-Text ([IO.File]::ReadAllText($archivePath))).Contains("Version 2.84 codifies Todd's 2026-09-26 velocity ruling on #4388 (5845981597;", [StringComparison]::Ordinal)) "v2.84 release note is not preserved in the provenance archive"

$mutants = [ordered]@{
  "backfill-dropped" = Remove-Phrase $skill 'Serial blocking backfills the floor (4388/5845981597).'
  "backfill-bound-to-pull-window" = $skill.Replace('regardless of track or the per-track pull window', 'within the per-track pull window')
  "backfill-files-priority-question" = Remove-Phrase $skill 'Backfill is not a priority change and files no §11 question.'
  "backfill-preempts-or-outranks-priority" = Remove-Phrase $skill 'The current priority keeps first claim on each lane that frees, and backfill never preempts a running lane.'
  "backfill-not-ready" = Remove-Phrase $skill ' or admitted by the floor backfill above'
  "diagnostic-blocks-product" = Remove-Phrase $skill 'A probe, diagnostic or test-infrastructure issue never blocks a product issue unless the product change cannot be written without its output (4388/5845981597).'
  "diagnostic-link-kept" = Remove-Phrase $skill 'The host removes such a link, records it on #4129, and the diagnostic runs in parallel.'
  "hosted-proof-db-only" = $skill.Replace('Hosted CI is the proof for every product attempt, not only DB', 'Hosted CI is the proof for DB')
  "hosted-jobs-narrowed" = $skill -replace 'including E2E,\s+DB Profile, unit, static and build', 'including DB Profile'
  "local-e2e-gate" = Remove-Phrase $skill 'Local E2E, local `verify:test-db` and other local full or harness runs are diagnostics only.'
  "local-run-prerequisite" = Remove-Phrase $skill 'No brief, decision or host prompt makes one a prerequisite for push, draft, ready or landing.'
  "local-failure-parks" = Remove-Phrase $skill 'A local-harness, environment or lock failure never parks, fails or classifies a candidate.'
  "no-push-to-hosted" = Remove-Phrase $skill 'The lane pushes its candidate to its draft PR and hosted CI judges it.'
  "attempt-unbound-to-hosted-verdict" = Remove-Phrase $skill 'An implementation attempt counts only when a pushed head receives a hosted CI verdict or an exact-head review verdict (4388/5845981597).'
  "local-stops-count" = Remove-Phrase $skill 'Local-only failures, preparation stops, harness or environment failures, lock refusals and a lane''s own tooling defects do not count; the lane repairs them within the same attempt.'
  "no-recount" = Remove-Phrase $skill 'Existing counts are recounted under this definition.'
  "recount-becomes-reset" = Remove-Phrase $skill 'That is a recount, not a reset: an attempt that did receive a hosted or review verdict keeps counting.'
  "park-ignores-definition" = $skill.Replace('Replacement never resets an attempt count, and counts follow' + "`n" + 'the §7 attempt definition', 'Replacement never resets an attempt count')
  "floor-dropped" = Remove-Phrase $skill 'at least two lanes serve it.'
  # The exact release version is pinned once, by issue-6997; this test pins only a well-formed header.
  "header-malformed" = ($skill -replace '(?m)^# Milestone Orchestrator \(v2\.\d+, \d{4}-\d{2}-\d{2}\)', '# Milestone Orchestrator')
}
$contractMutants = [ordered]@{
  "contract-consumed-count-undefined" = Remove-Phrase $contract 'The consumed count is the number of pushed heads that received a hosted CI verdict or an exact-head review verdict (milestone-orchestrator section 7); a local-only, preparation, harness or lane-tooling stop consumed no attempt.'
  "contract-local-stop-consumes" = ($contract -replace 'a local-only,\s+preparation, harness or lane-tooling stop consumed no attempt', 'a local-only stop also consumed an attempt')
  "contract-reset-allowed" = Remove-Phrase $contract 'and it resets no lineage history or consumed count.'
  "contract-non-ascii" = $contract.Replace('section 7); a local-only', 'section 7) ' + [string][char]0x2014 + ' a local-only')
}
foreach ($entry in $mutants.GetEnumerator()) {
  Assert-8205 ($entry.Value -cne $skill) "mutant did not change the skill: $($entry.Key)"
  Assert-8205 (-not (Test-VelocityPolicy $entry.Value)) "mutant survived: $($entry.Key)"
}
foreach ($entry in $contractMutants.GetEnumerator()) {
  Assert-8205 ($entry.Value -cne $contract) "mutant did not change the contract: $($entry.Key)"
  Assert-8205 (-not (Test-ContractPolicy $entry.Value)) "mutant survived: $($entry.Key)"
}

if ($ExpectedControllerHead) {
  $head = (& git -C $controller rev-parse HEAD 2>&1 | Out-String).Trim()
  Assert-8205 ($LASTEXITCODE -eq 0 -and $head -ceq $ExpectedControllerHead) "expected controller head does not match"
}

Write-Output "PASS issue-8205 hosted-proof, attempt-count, diagnostic-blocker and floor-backfill policy assertions=$script:assertions mutants=$($mutants.Count + $contractMutants.Count)"
