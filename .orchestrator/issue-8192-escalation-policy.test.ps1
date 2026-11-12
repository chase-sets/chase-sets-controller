[CmdletBinding()]
param(
  [string]$ControllerRoot = (Split-Path -Parent $PSScriptRoot),
  [string]$ExpectedControllerHead = ""
)

# #8192 pins Todd's 2026-09-25 rulings (#4388 5838576100, 5838600629,
# 5838628573): Todd receives only product priority/scope questions and packaged
# operator actions; process decisions stay with the host; optional decision lanes cover real
# product/domain tradeoffs; a two-lane product floor; hosted DB Profile Tests as DB proof
# while #8159 is open. Each mutant removes exactly one boundary.

$ErrorActionPreference = "Stop"
$controller = [IO.Path]::GetFullPath($ControllerRoot)
$skillPath = Join-Path $controller ".orchestrator/controller-skills/milestone-orchestrator/SKILL.md"
$script:assertions = 0

function Assert-8192([bool]$Condition, [string]$Message) {
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
  'Hard gates: production and money safety; secrets; Todd-only decisions;',
  'TCGplayer no contact/no credentials; explicit paid/one-shot action limits.',
  'Only Todd parks work, with an un-park condition.',
  'Failure counts, reviewer availability, tooling and environment never park it.',
  'Todd owns product priority and accepted scope changes.',
  'At least two lanes serve ready product; planning-to-ready precedes ops probes.',
  'Controller never takes product lanes.',
  'nothing preempts a live heavy owner.',
  'Hosted CI is proof on pushed head, including E2E, DB Profile, unit, static and build.',
  'local full E2E/DB/ harness runs are diagnostics, not push/ready/landing prerequisites.',
  'Same cause across three consecutive judged heads forces host step-back even if others shrink;',
  'no independent step-back/threshold decision lane/permission receipt.',
  'never process authorization.',
  'Do not change accepted outcome/acceptance or waive required counsel/provider/external approval.',
  'operator actions no lane can perform.',
  'Questions on live tracking issue: options, evidence, recommendation, blocked issues; never infer answer.',
  'now|later|done',
  'never repeats its list or lists host process decisions as waiting on Todd.',
  'Owner-authorized attempt/spend caps (zero without authority) survive every failure/replan/rename/ review/replacement.'
)

$script:forbidden = @(
  'Queue Todd-only decisions and operator actions without globally waiting.',
  'force replan-or-park and file a decision issue naming the artifact',
  'force replan-or-park',
  'parks with one terminal comment',
  '#8159 parks with a terminal comment',
  'replan with a material changed fact',
  'Escalate when a tradeoff would change the accepted product outcome or requires product, legal, or external authority',
  'queuing Todd decisions as tasks instead of waiting',
  'A decision is one comment on #4388 that states the question',
  'Choose the next committed outcome by explicit Todd steering first',
  'At every fourth counted implementation attempt',
  'At 15 or more dispatches',
  'query-ledgers.ps1 -DispatchIssue',
  'log-event.ps1 -DispatchDecision',
  '**An independent decision lane decides**',
  'the host resolves the question with a second independent lane.'
)

# Retired outcome tokens that must not appear in the live skill or any live
# controller contract (review finding F3).
$script:forbiddenTokens = @('TODD_RULING_NEEDED')

# v2.103 (Todd 4388/6022146271, #8903): re-entry needs no ceiling authority at all.
$script:ceilingRules = @(
  'It needs no attempt-ceiling authority and no Todd or decision-lane ceiling ruling',
  'Consumed counts are history, never a stop.',
  'A product scope conflict is not a planning disposition.',
  'Reviewer exhaustion never parks or stalls the artifact'
)

function Test-CeilingContract([string]$Contract) {
  $compact = Compact-Text $Contract
  foreach ($rule in $script:ceilingRules) {
    if (-not $compact.Contains((Compact-Text $rule), [StringComparison]::Ordinal)) { return $false }
  }
  if ($compact.Contains('Attempt-ceiling authority must be Todd-authored and already ruled', [StringComparison]::Ordinal)) { return $false }
  if ($compact.Contains('leaves the item parked', [StringComparison]::Ordinal)) { return $false }
  foreach ($token in $script:forbiddenTokens) {
    if ($Contract.Contains($token, [StringComparison]::Ordinal)) { return $false }
  }
  return $true
}

function Test-EscalationPolicy([string]$Text) {
  $compact = Compact-Text $Text
  if ([regex]::Matches((Normalize-Text $Text), '(?m)^# Milestone Orchestrator \(v2\.\d+, \d{4}-\d{2}-\d{2}\)$').Count -ne 1) { return $false }
  foreach ($rule in $script:sectionRules) { if (-not $compact.Contains((Compact-Text $rule), [StringComparison]::Ordinal)) { return $false } }
  foreach ($phrase in $script:forbidden) { if ($compact.Contains((Compact-Text $phrase))) { return $false } }
  foreach ($token in $script:forbiddenTokens) { if ($Text.Contains($token)) { return $false } }
  return $true
}

function Remove-Phrase([string]$Text, [string]$Phrase) {
  $pattern = ([regex]::Escape($Phrase)) -replace '\\ ', '\s+'
  $match = [regex]::Match($Text, $pattern)
  Assert-8192 $match.Success "negative control must find its boundary: $Phrase"
  return $Text.Remove($match.Index, $match.Length)
}

Assert-8192 (Test-Path -LiteralPath $skillPath -PathType Leaf) "milestone-orchestrator source is missing"
$skill = Normalize-Text ([IO.File]::ReadAllText($skillPath))
Assert-8192 (Test-EscalationPolicy $skill) "#8192 escalation, product-floor or hosted DB-proof policy is incomplete"
$archivePath = Join-Path $controller ".orchestrator/docs/archive/milestone-orchestrator/rule-provenance-v2.24.md"
Assert-8192 ((Normalize-Text ([IO.File]::ReadAllText($archivePath))).Contains("Version 2.82 codifies Todd's three 2026-09-25 rulings on #4388", [StringComparison]::Ordinal)) "v2.82 release note is not preserved in the provenance archive"

$contractRoot = Join-Path $controller ".orchestrator/contracts"
$contractTexts = [ordered]@{}
foreach ($file in @(Get-ChildItem -LiteralPath $contractRoot -Filter "*.md" -File | Sort-Object Name)) {
  $contractTexts[$file.Name] = Normalize-Text ([IO.File]::ReadAllText($file.FullName))
}
Assert-8192 ($contractTexts.Contains("planning-repair-v1.md")) "planning-repair contract is missing"
foreach ($entry in $contractTexts.GetEnumerator()) {
  foreach ($token in $script:forbiddenTokens) {
    Assert-8192 (-not $entry.Value.Contains($token, [StringComparison]::Ordinal)) "live contract $($entry.Key) carries retired outcome $token"
  }
}
$planningContract = $contractTexts["planning-repair-v1.md"]
Assert-8192 (Test-CeilingContract $planningContract) "planning-repair re-entry still requires ceiling authority or can park"
$contractMutants = [ordered]@{
  "ceiling-todd-only-restored" = $planningContract -replace 'It\s+needs\s+no\s+attempt-ceiling\s+authority\s+and\s+no\s+Todd\s+or\s+decision-lane\s+ceiling\s+ruling', 'Attempt-ceiling authority must be Todd-authored and already ruled'
  "consumed-count-stops-work" = Remove-Phrase $planningContract 'Consumed counts are history, never a stop.'
  "scope-conflict-planned-around" = Remove-Phrase $planningContract 'A product scope conflict is not a planning disposition.'
  "reviewer-exhaustion-parks" = $planningContract -replace 'Reviewer\s+exhaustion\s+never\s+parks\s+or\s+stalls\s+the\s+artifact', 'Reviewer exhaustion leaves the item parked'
  "contract-todd-ruling-outcome-added" = $planningContract -replace 'Consumed\s+counts\s+are\s+history,\s+never\s+a\s+stop\.', 'Consumed counts are history, never a stop. Decision outcomes: FINAL, TODD_RULING_NEEDED.'
}


$mutants = [ordered]@{}
foreach ($rule in $script:sectionRules) {
  $pattern = ([regex]::Escape($rule)).Replace('\ ', '\s+')
  $mutated = [regex]::Replace($skill,$pattern,'MUTANT_REMOVED')
  Assert-8192 ($mutated -cne $skill) "negative control must change its boundary: $rule"
  $mutants[$rule] = $mutated
}
foreach ($obsolete in @('At every fourth counted implementation attempt', 'At 15 or more dispatches',
    'query-ledgers.ps1 -DispatchIssue', 'log-event.ps1 -DispatchDecision',
    '**An independent decision lane decides**', 'the host resolves the question with a second independent lane.')) {
  $mutants["obsolete-process-restored:$obsolete"] = $skill + "`n$obsolete"
}
foreach ($entry in $mutants.GetEnumerator()) {
  Assert-8192 ($entry.Value -cne $skill) "mutant did not change the skill: $($entry.Key)"
  Assert-8192 (-not (Test-EscalationPolicy $entry.Value)) "mutant survived: $($entry.Key)"
}
foreach ($entry in $contractMutants.GetEnumerator()) {
  Assert-8192 ($entry.Value -cne $planningContract) "mutant did not change the contract: $($entry.Key)"
  Assert-8192 (-not (Test-CeilingContract $entry.Value)) "mutant survived: $($entry.Key)"
}

if ($ExpectedControllerHead) {
  $head = (& git -C $controller rev-parse HEAD 2>&1 | Out-String).Trim()
  Assert-8192 ($LASTEXITCODE -eq 0 -and $head -ceq $ExpectedControllerHead) "expected controller head does not match"
}

Write-Output "PASS issue-8192 escalation, product-floor, hosted DB-proof and ceiling-authority policy assertions=$script:assertions mutants=$($mutants.Count + $contractMutants.Count)"
