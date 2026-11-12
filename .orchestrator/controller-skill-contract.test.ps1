$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'review-head-contract.psm1') -Force -DisableNameChecking
$contract = Get-ExactHeadReviewContract
$markers = @($contract.receiptSchema, $contract.reducerSchema, 'landing-preflight/v1')

function Assert-SkillReviewContract([string]$Text) {
  foreach ($marker in $markers) {
    if (-not $Text.Contains($marker, [StringComparison]::Ordinal)) {
      throw "staged skill/runtime controller contract drift (missing marker '$marker')"
    }
  }
}

$skill = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'controller-skills/milestone-orchestrator/SKILL.md'))
Assert-SkillReviewContract $skill
foreach ($marker in $markers) {
  $mutant = $skill.Replace($marker, 'MUTANT_REMOVED')
  if ($mutant -ceq $skill) { throw "marker omission mutant did not change the real skill: $marker" }
  $failure = ''
  try { Assert-SkillReviewContract $mutant } catch { $failure = $_.Exception.Message }
  if (-not $failure.Contains("missing marker '$marker'")) { throw "marker omission mutant survived: $marker" }
}
Write-Output 'PASS real staged skill/runtime contract; three marker omission mutants rejected'
