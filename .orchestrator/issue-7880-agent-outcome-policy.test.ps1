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

function Test-AgentOutcomePolicy([string]$Text) {
  $section1 = Get-Section $Text 1
  $section4 = Get-Section $Text 4
  $section11 = Get-Section $Text 11
  if ($null -eq $section1 -or $null -eq $section4 -or $null -eq $section11) { return $false }
  $mission = Compact-Text $section1
  $work = Compact-Text $section4
  $decisions = Compact-Text $section11
  $steering = [regex]::Match(
    $section4,
    "(?ms)Preserve the current TCGplayer-first steering.*?do not encode its live issue numbers\s+here\."
  )

  return (
    $Text.Contains('description: Run the chase-sets delivery loop — complete all committed, non-parked outcomes', [StringComparison]::Ordinal) -and
    [regex]::Matches($Text, "(?m)^# Milestone Orchestrator \(v2\.\d+, \d{4}-\d{2}-\d{2}\)$").Count -eq 1 -and
    [regex]::Matches($script:archiveText, "(?m)^Version 2\.63 implements Todd's 2026-09-11 outcome-planning ruling\.").Count -eq 1 -and
    $mission.Contains('Terminal condition: every committed, non-parked milestone is closed and no issue globally remains `status:needs-replan`', [StringComparison]::Ordinal) -and
    $mission.Contains('Candidate outcomes remain visible future triage outside terminal completion', [StringComparison]::Ordinal) -and
    $mission.Contains('Stopped implementation is active recovery work labeled `status:needs-replan`, not parked', [StringComparison]::Ordinal) -and
    $work.Contains('`scripts/milestone-policy.mjs` and `scripts/dispatch-window.mjs`', [StringComparison]::Ordinal) -and
    $work.Contains('`<!-- outcome: {"version":1,"track":"commerce","order":100,"status":"committed"} -->`', [StringComparison]::Ordinal) -and
    $work.Contains('`candidate` is triaged future work and never enters the pull window', [StringComparison]::Ordinal) -and
    $work.Contains('Malformed metadata fails closed', [StringComparison]::Ordinal) -and
    $work.Contains('untagged Wave/Mobile migration compatibility', [StringComparison]::Ordinal) -and
    $work.Contains('Never infer order from titles, milestone numbers, due dates, creation order, or board position', [StringComparison]::Ordinal) -and
    $work.Contains('pass `currentRevision.milestone` as `{id: milestone.node_id, number, title, description, state}`', [StringComparison]::Ordinal) -and
    $work.Contains('Regenerate a receipt that lacks any of those fields', [StringComparison]::Ordinal) -and
    $work.Contains('Any mismatch from the receipt''s bound milestone is stale authority', [StringComparison]::Ordinal) -and
    $work.Contains('a description change to `candidate` cannot dispatch on the issue''s unchanged `updatedAt`', [StringComparison]::Ordinal) -and
    $work.Contains('Agents create, split, rescope, place, and rank finite outcomes and their issues', [StringComparison]::Ordinal) -and
    $work.Contains('explicit Todd steering first, then native entry/exit gates and dependencies, blocking criticality', [StringComparison]::Ordinal) -and
    $work.Contains('Choose the next committed outcome within Todd''s current product priority by explicit Todd steering first', [StringComparison]::Ordinal) -and
    $work.Contains('These criteria never select a new product priority.', [StringComparison]::Ordinal) -and
    $work.Contains('the host files one short priority question under §11 and keeps delivering the remaining committed work meanwhile', [StringComparison]::Ordinal) -and
    $work.Contains('finishing the whole admitted outcome relative to remaining effort, continuity, and aging', [StringComparison]::Ordinal) -and
    $steering.Success -and
    -not $steering.Value.Contains('#', [StringComparison]::Ordinal) -and
    $work.Contains('Do not use the unvalidated impact-scoring pilot or invent a replacement score', [StringComparison]::Ordinal) -and
    $work.Contains('records one compact rationale on #4129, including any Todd override''s scope and until condition', [StringComparison]::Ordinal) -and
    $work.Contains('A comprehensive portfolio rerank happens at most weekly', [StringComparison]::Ordinal) -and
    $work.Contains('new intake, new Todd steering, or a real blocker may change the affected order immediately', [StringComparison]::Ordinal) -and
    $work.Contains('Stop refining once a finite runnable order exists', [StringComparison]::Ordinal) -and
    $work.Contains('A candidate is not a parking state for a failed or `status:needs-replan` commitment', [StringComparison]::Ordinal) -and
    $work.Contains('An outcome closes only when its admitted required scope is fulfilled, its terminal evidence passes, and native tracking reconciles every admitted issue', [StringComparison]::Ordinal) -and
    $work.Contains('Any optional remainder has an explicit destination before closure', [StringComparison]::Ordinal) -and
    $work.Contains('At most two concurrent lanes serve `kind:ops` or controller work', [StringComparison]::Ordinal) -and
    $work.Contains('Ops never preempts ready product work', [StringComparison]::Ordinal) -and
    $decisions.Contains('Do not send routine milestone creation, splitting, rescoping, placement, ordering, issue ranking, or scope tradeoffs within an accepted outcome to Todd', [StringComparison]::Ordinal) -and
    $decisions.Contains('Escalate to Todd only when a tradeoff would change product priority or accepted product scope', [StringComparison]::Ordinal) -and
    -not $work.Contains('The lowest wave with ready work', [StringComparison]::Ordinal) -and
    -not $work.Contains('in an executable wave', [StringComparison]::Ordinal)
  )
}

Assert-7880 (Test-Path -LiteralPath $skillPath -PathType Leaf) "milestone-orchestrator source is missing"
$skill = Normalize-Text ([IO.File]::ReadAllText($skillPath))
# v2.85 moved release notes to the provenance archive (#8207).
$script:archiveText = Normalize-Text ([IO.File]::ReadAllText((Join-Path (Split-Path -Parent $skillPath) "references/rule-provenance-v2.24.md")))
Assert-7880 (Test-AgentOutcomePolicy $skill) "agent-owned outcome policy is incomplete"

$mutants = [ordered]@{
  "candidate-enters-pull-window" = $skill.Replace('never enters the pull window', 'enters the pull window when refined')
  "todd-steering-loses-precedence" = $skill.Replace('explicit Todd steering first', 'agent scoring first')
  "heuristics-select-product-priority" = $skill -replace 'Choose the next committed outcome within Todd''s current product priority by\s+explicit', 'Choose the next committed outcome by explicit'
  "heuristics-may-pick-new-priority" = $skill -replace 'These criteria never\s+select a new product priority\.', 'These criteria may select the next product priority.'
  "impact-pilot-becomes-authority" = $skill.Replace('Do not use the unvalidated impact-scoring pilot', 'Use the impact-scoring pilot')
  "stale-receipt-dispatches-candidate" = $skill -replace 'a description change to `candidate` cannot\s+dispatch', 'a description change to `candidate` may dispatch'
  "candidate-blocks-terminal" = $skill.Replace('every committed, non-parked milestone', 'every non-parked milestone')
  "catalog-reinstates-candidate-completion" = $skill.Replace('complete all committed, non-parked outcomes', 'complete all non-parked milestones')
  "global-recovery-dropped" = $skill -replace 'and no\s+issue globally remains `status:needs-replan`', ''
  "routine-ranking-escalates" = $skill.Replace('Do not send routine milestone creation', 'Send routine milestone creation')
  "closure-required-scope-weakened" = $skill -replace 'its admitted required scope is\s+fulfilled', 'some admitted required scope is fulfilled'
  "closure-terminal-evidence-weakened" = $skill.Replace('its terminal evidence passes', 'terminal evidence exists')
  "closure-tracking-weakened" = $skill -replace 'native tracking reconciles every\s+admitted issue', 'native tracking is updated'
  "closure-optional-remainder-unassigned" = $skill -replace 'Any optional remainder has an explicit destination before\s+closure', 'Optional remainder may remain unassigned at closure'
}
foreach ($entry in $mutants.GetEnumerator()) {
  Assert-7880 (-not (Test-AgentOutcomePolicy $entry.Value)) "mutant survived: $($entry.Key)"
}

if ($ExpectedControllerHead) {
  $head = (& git -C $controller rev-parse HEAD 2>&1 | Out-String).Trim()
  Assert-7880 ($LASTEXITCODE -eq 0 -and $head -ceq $ExpectedControllerHead) "expected controller head does not match"
}

Write-Output "PASS issue-7880 agent-owned outcome policy assertions=$script:assertions mutants=$($mutants.Count)"
