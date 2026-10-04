[CmdletBinding()]
param(
  [string]$ControllerRoot = (Split-Path -Parent $PSScriptRoot),
  [string]$ExpectedControllerHead = ""
)

# #8192 pins Todd's 2026-09-25 rulings (#4388 5838576100, 5838600629,
# 5838628573): Todd receives only product priority/scope questions and packaged
# operator actions; process decisions stay with the host or a final independent
# decision lane; a two-lane product floor; hosted DB Profile Tests as DB proof
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
  @(1, 'Send Todd only product priority or scope questions and packaged operator actions (§11), and never wait globally on either.'),
  @(4, 'Todd owns product prioritization (4388/5838628573).'),
  @(4, 'Choose the next committed outcome within Todd''s current product priority by explicit Todd steering first'),
  @(4, 'These criteria never select a new product priority.'),
  @(4, 'When evidence suggests such a change, the host files one short priority question under §11 and keeps delivering on the current priority meanwhile.'),
  @(4, 'Inside that priority, agents still create, split, place and rank outcomes and issues.'),
  @(4, 'while ready, runnable `kind:product` work exists, at least two lanes serve it.'),
  @(4, 'Controller, platform, ops and test-infrastructure work take only the remaining capacity.'),
  @(4, 'When fewer than two product issues are ready, planning lanes that make product issues ready come before new ops or test-infrastructure probes.'),
  @(4, 'Heavy-verifier slot order is unchanged, and nothing preempts a live heavy owner.'),
  @(7, 'the normal final-head hosted `DB Profile Tests` job is the DB proof'),
  @(7, 'While #8159 is open, no brief, decision or host prompt makes a full local `verify:test-db` a prerequisite for push, draft, ready or landing.'),
  @(7, 'A brief that already names one takes the hosted substitution with a PR-body disclosure, and no per-issue decision is needed.'),
  @(7, 'Hosted gates, timeouts, skips and reviews are unchanged, and local failures are not classified as environmental.'),
  @(7, 'Local-gate investigation stays in the #8159 lineage, and no new local-gate probe or diagnostic issue opens outside it.'),
  @(7, 'When that lineage yields no bounded repair, #8159 parks with a terminal comment.'),
  @(7, 'force replan-or-park through an independent decision lane (§11) whose verdict is final.'),
  @(11, 'Todd receives exactly two kinds of request'),
  @(11, 'A decision is one comment on #4388 only when it is a product priority or scope question for Todd.'),
  @(11, 'Process decisions never become #4388 questions for Todd; they follow the host and decision-lane routes below.'),
  @(11, '**Product priority or scope question.**'),
  @(11, '**Packaged operator action.** A step no lane can perform'),
  @(11, 'Each request is one concrete runnable step, with its exact command or click path, and Todd can answer it without reading history.'),
  @(11, 'External approvals themselves, such as counsel sign-off, remain required and are never waived.'),
  @(11, '**The host decides** same-attempt, in-scope repairs itself and logs `decision-resolved` with its reasoning.'),
  @(11, '**An independent decision lane decides**'),
  @(11, 'Its verdict is final, and the host proceeds on it.'),
  @(11, 'A decision lane never returns a Todd ruling for a process question.'),
  @(11, 'the host resolves the question with a second independent lane.'),
  @(11, 'It goes to Todd only as a priority or scope question or a packaged operator action.'),
  @(11, 'Escalate to Todd only when a tradeoff would change product priority or accepted product scope.'),
  @(11, 'The existing Todd-reserved rules are unchanged: platform ownership transfer (§4), host rotation (§2), rollback (§3), and reclaiming unrecognized worktrees (§9).'),
  @(11, 'They never list process decisions as waiting on Todd.')
)

$script:forbidden = @(
  'Queue Todd-only decisions and operator actions without globally waiting.',
  'force replan-or-park and file a decision issue naming the artifact',
  'Escalate when a tradeoff would change the accepted product outcome or requires product, legal, or external authority',
  'queuing Todd decisions as tasks instead of waiting',
  'A decision is one comment on #4388 that states the question',
  'Choose the next committed outcome by explicit Todd steering first'
)

# Retired outcome tokens that must not appear in the live skill or any live
# controller contract (review finding F3).
$script:forbiddenTokens = @('TODD_RULING_NEEDED')

$script:ceilingRules = @(
  'Attempt-ceiling authority must already govern before admission.',
  'It is either a Todd-authored ruling or a recorded final independent decision-lane verdict under milestone-orchestrator section 11',
  'bound to that lineage root, terminal receipt, and exact absolute ceiling.',
  'That decision lane is separate from this replan''s author, repairer, and reviewers.',
  'Neither this replan nor its semantic PASS can supply it.'
)

function Test-CeilingContract([string]$Contract) {
  $compact = Compact-Text $Contract
  foreach ($rule in $script:ceilingRules) {
    if (-not $compact.Contains((Compact-Text $rule), [StringComparison]::Ordinal)) { return $false }
  }
  if ($compact.Contains('Attempt-ceiling authority must be Todd-authored and already ruled', [StringComparison]::Ordinal)) { return $false }
  foreach ($token in $script:forbiddenTokens) {
    if ($Contract.Contains($token, [StringComparison]::Ordinal)) { return $false }
  }
  return $true
}

function Test-EscalationPolicy([string]$Text) {
  $normalized = Normalize-Text $Text
  if ([regex]::Matches($normalized, "(?m)^# Milestone Orchestrator \(v2\.\d+, \d{4}-\d{2}-\d{2}\)$").Count -ne 1) { return $false }
  if (-not $normalized.Contains('sending Todd only product priority or scope questions and packaged operator actions.', [StringComparison]::Ordinal)) { return $false }
  foreach ($rule in $script:sectionRules) {
    $section = Get-Section $normalized $rule[0]
    if ($null -eq $section) { return $false }
    if (-not (Compact-Text $section).Contains((Compact-Text $rule[1]), [StringComparison]::Ordinal)) { return $false }
  }
  $compact = Compact-Text $normalized
  foreach ($phrase in $script:forbidden) {
    if ($compact.Contains((Compact-Text $phrase), [StringComparison]::Ordinal)) { return $false }
  }
  foreach ($token in $script:forbiddenTokens) {
    if ($normalized.Contains($token, [StringComparison]::Ordinal)) { return $false }
  }
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
$archivePath = Join-Path $controller ".orchestrator/controller-skills/milestone-orchestrator/references/rule-provenance-v2.24.md"
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
Assert-8192 (Test-CeilingContract $planningContract) "planning-repair ceiling authority does not admit a bound, final independent decision"
$contractMutants = [ordered]@{
  "ceiling-todd-only-restored" = $planningContract -replace 'Attempt-ceiling\s+authority must already govern before admission\.', 'Attempt-ceiling authority must be Todd-authored and already ruled; it must already govern before admission.'
  "ceiling-decision-unbound" = Remove-Phrase $planningContract 'bound to that lineage root, terminal receipt, and exact absolute ceiling.'
  "ceiling-decision-not-separate" = Remove-Phrase $planningContract 'That decision lane is separate from this replan''s author, repairer, and reviewers.'
  "ceiling-self-supplied" = Remove-Phrase $planningContract 'Neither this replan nor its semantic PASS can supply it.'
  "contract-todd-ruling-outcome-added" = $planningContract -replace 'Neither this replan nor its\s+semantic PASS can supply it\.', 'Neither this replan nor its semantic PASS can supply it. Decision outcomes: FINAL, TODD_RULING_NEEDED.'
}


$mutants = [ordered]@{
  "decision-lane-may-escalate" = Remove-Phrase $skill 'A decision lane never returns a Todd ruling for a process question.'
  "decision-lane-verdict-not-final" = Remove-Phrase $skill 'Its verdict is final, and the host proceeds on it.'
  "operator-action-unpackaged" = Remove-Phrase $skill 'Each request is one concrete runnable step, with its exact command or click path, and Todd can answer it without reading history.'
  "external-approval-waived" = Remove-Phrase $skill 'External approvals themselves, such as counsel sign-off, remain required and are never waived.'
  "host-routine-repairs-escalate" = Remove-Phrase $skill '**The host decides** same-attempt, in-scope repairs itself'
  "status-lists-process-decisions" = Remove-Phrase $skill 'They never list process decisions as waiting on Todd.'
  "product-priority-agent-owned" = Remove-Phrase $skill 'Todd owns product prioritization (4388/5838628573).'
  "product-floor-dropped" = Remove-Phrase $skill 'at least two lanes serve it.'
  "ready-planning-not-preferred" = Remove-Phrase $skill 'When fewer than two product issues are ready, planning lanes that make product issues ready come before new ops or test-infrastructure probes.'
  "heavy-owner-preempted" = Remove-Phrase $skill 'Heavy-verifier slot order is unchanged, and nothing preempts a live heavy owner.'
  "local-db-gate-required" = Remove-Phrase $skill 'While #8159 is open, no brief, decision or host prompt makes a full local `verify:test-db` a prerequisite for push, draft, ready or landing.'
  "hosted-gates-weakened" = Remove-Phrase $skill 'Hosted gates, timeouts, skips and reviews are unchanged, and local failures are not classified as environmental.'
  "local-gate-probes-unbounded" = Remove-Phrase $skill 'Local-gate investigation stays in the #8159 lineage, and no new local-gate probe or diagnostic issue opens outside it.'
  "ceiling-goes-to-todd" = $skill.Replace('force replan-or-park through an independent decision lane (§11)', 'force replan-or-park and file a decision issue naming the artifact (§11)')
  "todd-reserved-rules-dropped" = Remove-Phrase $skill 'The existing Todd-reserved rules are unchanged'
  "old-queue-invariant-restored" = $skill.Replace('- Send Todd only product priority or scope questions and packaged operator', '- Queue Todd-only decisions and operator actions without globally waiting.`n- Send Todd only product priority or scope questions and packaged operator')
  "todd-ruling-outcome-added" = $skill.Replace('A decision lane never returns a Todd ruling for a process question.', 'Accepted decision lane outcomes: FINAL, TODD_RULING_NEEDED. A decision lane never returns a Todd ruling for a process question.')
  "universal-todd-decision-restored" = $skill.Replace('A decision is one comment on #4388 only when it is a product priority or scope' + "`n" + 'question for Todd. That comment states', 'A decision is one comment on #4388 that states')
  "process-decisions-become-todd-questions" = Remove-Phrase $skill 'Process decisions never become #4388 questions for Todd; they follow the host and decision-lane routes below.'
  "unscoped-next-outcome-restored" = $skill -replace 'Choose the next committed outcome within Todd''s current product priority by\s+explicit', 'Choose the next committed outcome by explicit'
  "heuristics-may-pick-new-priority" = Remove-Phrase $skill 'These criteria never select a new product priority.'
  "old-escalation-restored" = $skill.Replace('Other legal and external', 'Escalate when a tradeoff would change the accepted product outcome or requires product, legal, or external authority. Other legal and external')
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
