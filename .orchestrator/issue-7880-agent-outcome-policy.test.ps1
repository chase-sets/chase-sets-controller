[CmdletBinding()]
param(
  [string]$ControllerRoot = (Split-Path -Parent $PSScriptRoot),
  [string]$ExpectedControllerHead = ""
)

$ErrorActionPreference = "Stop"
$controller = [IO.Path]::GetFullPath($ControllerRoot)
$skillPath = Join-Path $controller ".orchestrator/controller-skills/milestone-orchestrator/SKILL.md"
$script:assertions = 0

function Assert-7880([bool]$Condition, [string]$Message) {
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

$script:outcomeRules = @(
  'complete all committed, non-parked outcomes',
  'Terminal condition: every committed, non-parked milestone is closed and no issue globally remains `status:needs-replan`.',
  'Candidate outcomes are future triage, outside completion.',
  'Only committed outcomes enter the pull window; candidate/malformed metadata does not dispatch.',
  'Never infer order from titles, numbers, dates or board position.',
  'Todd owns product priority and accepted scope changes.',
  'never choose a new product priority.',
  'Preserve recorded TCGplayer-first steering until its condition is met or Todd supersedes it.',
  '`scripts/milestone-policy.mjs` and `scripts/dispatch-window.mjs`',
  '`<!-- outcome: {"version":1,"track":"commerce","order":100,"status":"committed"} -->`',
  'Bind `issue-readiness/v1` to current body and milestone `{id: milestone.node_id, number, title, description, state}`.',
  'Missing/mismatch requires fresh receipt; unchanged `updatedAt` cannot mask milestone changes.',
  'Close only when all required scope, terminal evidence and native tracking reconcile every admitted issue; optional remainder gets a destination.',
  'Candidate is not failure parking.',
  'Agents create/split/rank inside it: Todd steering first',
  'At least two lanes serve ready product;',
  'Controller never takes product lanes.'
)

function Test-AgentOutcomePolicy([string]$Text) {
  $compact = Compact-Text $Text
  if ([regex]::Matches((Normalize-Text $Text), '(?m)^# Milestone Orchestrator \(v2\.\d+, \d{4}-\d{2}-\d{2}\)$').Count -ne 1) { return $false }
  foreach ($rule in $script:outcomeRules) { if (-not $compact.Contains((Compact-Text $rule), [StringComparison]::Ordinal)) { return $false } }
  return $true
}

Assert-7880 (Test-Path -LiteralPath $skillPath -PathType Leaf) "milestone-orchestrator source is missing"
$skill = Normalize-Text ([IO.File]::ReadAllText($skillPath))
# v2.85 moved release notes to the provenance archive (#8207).
$script:archiveText = Normalize-Text ([IO.File]::ReadAllText((Join-Path (Split-Path -Parent $skillPath) "../../docs/archive/milestone-orchestrator/rule-provenance-v2.24.md")))
Assert-7880 (Test-AgentOutcomePolicy $skill) "agent-owned outcome policy is incomplete"

$mutants = [ordered]@{}
foreach ($rule in $script:outcomeRules) {
  $pattern = ([regex]::Escape($rule)).Replace('\ ', '\s+')
  $mutated = [regex]::Replace($skill,$pattern,'MUTANT_REMOVED')
  Assert-7880 ($mutated -cne $skill) "negative control must change its boundary: $rule"
  $mutants[$rule] = $mutated
}
foreach ($entry in $mutants.GetEnumerator()) {
  Assert-7880 (-not (Test-AgentOutcomePolicy $entry.Value)) "mutant survived: $($entry.Key)"
}

if ($ExpectedControllerHead) {
  $head = (& git -C $controller rev-parse HEAD 2>&1 | Out-String).Trim()
  Assert-7880 ($LASTEXITCODE -eq 0 -and $head -ceq $ExpectedControllerHead) "expected controller head does not match"
}

Write-Output "PASS issue-7880 agent-owned outcome policy assertions=$script:assertions mutants=$($mutants.Count)"
