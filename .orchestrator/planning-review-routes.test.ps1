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
    'host-dispatched eligible review', 'full artifact history and row-slot admission'
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
foreach ($relative in @('contracts/planning-repair-v1.md', 'contracts/review-v2.md')) {
  $text = [IO.File]::ReadAllText((Join-Path $root $relative)) -replace '\s+', ' '
  foreach ($term in @($standing, 'brief-sweep2-authority-decision-r1', 'current body/dependencies and full findings',
    'trusted readiness and ordinary admission', 'fresh-session reviewer on the row''s policy slot',
    'whole brief and all findings', 'This is not a brief semantic PASS.',
    'Terminal re-entry, changed semantics, missing authority or no eligible implementation reviewer')) {
    Assert-Route $text.Contains($term) "$relative lacks standing rule: $term"
  }
}
Assert-Route (($planning -replace '\s+', ' ').Contains('does not replace the fresh independent semantic PASS required for terminal re-entry')) 'terminal re-entry distinction missing'
$routing = [IO.File]::ReadAllText((Join-Path $root 'controller-skills/model-routing/SKILL.md'))
Assert-Route $routing.Contains('fresh lane and session with no shared') 'routing fresh-session independence missing'
$core = [IO.File]::ReadAllText((Join-Path $root 'controller-skills/milestone-orchestrator/SKILL.md')) -replace '\s+',' '
$coreTerms = @('Lanes never launch model CLIs/subprocess reviewers;', 'PENDING_HOST_REVIEW',
  'fresh lane/session, no author transcript/conversation state', 'independent current-brief semantic PASS',
  'no independent step-back/threshold decision lane/permission receipt.')
function Test-CoreHandoff([string]$Text) {
  foreach ($term in $coreTerms) { Assert-Route ($Text.Contains($term)) "compact handoff lacks $term" }
}
Test-CoreHandoff $core
foreach ($term in $coreTerms) {
  $mutated = $core.Replace($term,'MUTANT_REMOVED')
  $failure = ''
  try { Test-CoreHandoff $mutated } catch { $failure = $_.Exception.Message }
  Assert-Route ($mutated -cne $core -and $failure.StartsWith('ASSERTION FAILED:')) "core handoff mutant survived: $term"
}
$sandbox = Join-Path ([IO.Path]::GetTempPath()) "planning-review-routes-$([guid]::NewGuid().ToString('N'))"
try {
  New-Item -ItemType Directory -Path $sandbox | Out-Null
  # Named historical-query proof: use the committed archive explicitly, with
  # isolated mutable catalogs, never the host's installed skill or a default load.
  [IO.File]::WriteAllText((Join-Path $sandbox 'stall-gotchas.md'), "# Synthetic empty stall ledger`n")
  [IO.File]::WriteAllText((Join-Path $sandbox 'defect-classes.md'), "# Synthetic empty defect ledger`n")
  Copy-Item -LiteralPath (Join-Path $root 'docs/archive/milestone-orchestrator/controller-defect-classes.md') -Destination $sandbox
  $query = Join-Path $root 'controller-skills/milestone-orchestrator/scripts/query-ledgers.ps1'
  $text = (& pwsh -NoProfile -NonInteractive -File $query -InstalledReferenceRoot $sandbox -ReferenceRoot $sandbox -Mode dispatch -Text 'planning-repair unsupported_encrypted_delegation' -Footprint '.orchestrator/contracts/planning-repair-v1.md' -Json | Out-String)
  Assert-Route ($LASTEXITCODE -eq 0) 'explicit archive query succeeds without installed catalogs'
  $result = $text | ConvertFrom-Json
  $entry = @($result.entries | Where-Object slug -eq 'unattributed-nested-model-dispatch')
  Assert-Route ($entry.Count -eq 1 -and $entry[0].instruction.Contains('review-probe-live-provider-credential-inheritance') -and
    $entry[0].instruction.Contains('review-isolation-opt-in-by-default') -and
    $entry[0].guard.Contains('CONTRACT_AND_REGRESSION')) 'query must preserve both cross-references and guard status'
} finally {
  if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force }
}
Write-Output 'PASS planning/review handoff, fresh-session authority, explicit archived query and contract mutants'
