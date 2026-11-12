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
  'Backfill next committed marker-order outcomes across tracks/windows, no Todd question.',
  'Current priority first claim; never preempt live work.',
  'Remove diagnostic blockers unless product cannot be written without result.',
  'Hosted CI is proof on pushed head, including E2E, DB Profile, unit, static and build.',
  'Push a draft once delivery skill scoped checks pass;',
  'local full E2E/DB/ harness runs are diagnostics, not push/ready/landing prerequisites.',
  'Do not conceal real failures as environmental; disclose hosted substitutions in the PR.',
  'Attempts count only pushed heads with hosted/review verdict; local/tooling stops do not count.',
  'Replacement never resets history or paid caps.',
  'Same cause across three consecutive judged heads forces host step-back even if others shrink;',
  'At least two lanes serve ready product;',
  'Every FLOOR UNMET: act on each qualified ready-idle/held PR or log concrete capacity/ordering reason',
  'UNKNOWN is not OK/ready/no-work proof; repair named gaps, no corpus sweep.'
)

$script:contractRules = @(
  'and it resets no lineage history or consumed count.',
  'The consumed count is the number of pushed heads that received a hosted CI verdict or an exact-head review verdict (milestone-orchestrator section 7); a local-only, preparation, harness or lane-tooling stop consumed no attempt.'
)

function Test-VelocityPolicy([string]$Text) {
  $compact = Compact-Text $Text
  if ([regex]::Matches((Normalize-Text $Text), '(?m)^# Milestone Orchestrator \(v2\.\d+, \d{4}-\d{2}-\d{2}\)$').Count -ne 1) { return $false }
  foreach ($rule in $script:sectionRules) { if (-not $compact.Contains((Compact-Text $rule), [StringComparison]::Ordinal)) { return $false } }
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
$landing = Get-Section $skill 8
Assert-8205 (-not (Compact-Text $landing).Contains('per-PR Reports', [StringComparison]::Ordinal)) 'section 8 has no velocity collection recipe'
Assert-8205 (-not (Compact-Text $skill).Contains('Everything else in the report is diagnostic context that never triggers work or files an issue.', [StringComparison]::Ordinal)) 'old no-work rule is absent'
$archivePath = Join-Path $controller ".orchestrator/docs/archive/milestone-orchestrator/rule-provenance-v2.24.md"
Assert-8205 ((Normalize-Text ([IO.File]::ReadAllText($archivePath))).Contains("Version 2.84 codifies Todd's 2026-09-26 velocity ruling on #4388 (5845981597;", [StringComparison]::Ordinal)) "v2.84 release note is not preserved in the provenance archive"

$mutants = [ordered]@{}
foreach ($rule in $script:sectionRules) {
  $pattern = ([regex]::Escape($rule)).Replace('\ ', '\s+')
  $mutated = [regex]::Replace($skill,$pattern,'MUTANT_REMOVED')
  Assert-8205 ($mutated -cne $skill) "negative control must change its boundary: $rule"
  $mutants[$rule] = $mutated
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
