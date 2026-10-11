$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
function Assert-Route([bool]$Value, [string]$Message) {
  if (-not $Value) { throw "ASSERTION FAILED: $Message" }
}
function Test-Handoff([string]$Text) {
  $Text = $Text -replace '\s+', ' '
  foreach ($required in @(
    'A lane must not launch model CLIs or subprocess reviewers itself',
    'PENDING_HOST_REVIEW', 'unsupported_encrypted_delegation',
    'attempted native-CLI fallback', 'never a semantic verdict',
    'host-dispatched eligible review', 'full artifact author/repair-history'
  )) {
    Assert-Route $Text.Contains($required) "handoff lacks $required"
  }
}
$planning = [IO.File]::ReadAllText((Join-Path $root 'contracts/planning-repair-v1.md'))
$review = [IO.File]::ReadAllText((Join-Path $root 'contracts/review-v2.md'))
Test-Handoff $planning
Test-Handoff $review
foreach ($term in @('PENDING_HOST_REVIEW', 'unsupported_encrypted_delegation', 'never a semantic verdict')) {
  $failure = ''
  try { Test-Handoff $planning.Replace($term, 'MUTANT_REMOVED') } catch { $failure = $_.Exception.Message }
  Assert-Route ($failure.StartsWith('ASSERTION FAILED:')) "handoff mutant survived: $term"
}
$standing = "Count every in-body brief repair in that model's artifact repair history."
foreach ($relative in @('controller-skills/milestone-orchestrator/SKILL.md', 'contracts/planning-repair-v1.md', 'contracts/review-v2.md')) {
  $text = [IO.File]::ReadAllText((Join-Path $root $relative)) -replace '\s+', ' '
  foreach ($term in @($standing, 'brief-sweep2-authority-decision-r1', 'current body/dependencies and full findings',
    'trusted readiness and ordinary admission', 'fresh code-history-independent reviewer',
    'whole brief and all findings', 'This is not a brief semantic PASS.',
    'Terminal re-entry, changed semantics, missing authority or no eligible implementation reviewer')) {
    Assert-Route $text.Contains($term) "$relative lacks standing rule: $term"
  }
}
Assert-Route (($planning -replace '\s+', ' ').Contains('does not replace the fresh independent semantic PASS required for terminal re-entry')) 'terminal re-entry distinction missing'
$routing = [IO.File]::ReadAllText((Join-Path $root 'controller-skills/model-routing/SKILL.md'))
Assert-Route $routing.Contains('brief-repair-exhausts-independent-reviewers') 'routing exclusion cross-reference missing'
$result = & (Join-Path $root 'controller-skills/milestone-orchestrator/scripts/query-ledgers.ps1') -Mode dispatch `
  -Text 'planning-repair independent review unsupported_encrypted_delegation' -Footprint '.orchestrator/contracts/planning-repair-v1.md' -Json | ConvertFrom-Json
$entry = @($result.entries | Where-Object slug -eq 'unattributed-nested-model-dispatch')
Assert-Route ($entry.Count -eq 1) 'planning-repair footprint must retrieve the nested-dispatch constraint'
Assert-Route ($entry[0].instruction.Contains('review-probe-live-provider-credential-inheritance') -and
  $entry[0].instruction.Contains('review-isolation-opt-in-by-default') -and
  $entry[0].guard.Contains('CONTRACT_AND_REGRESSION')) 'query must preserve both cross-references and guard status'
Write-Output 'PASS planning/review handoff, exhausted-roster rule and contract mutants'
