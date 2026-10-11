$ErrorActionPreference = "Stop"
# Proof-arm relevance (#8207): in an impact battery a guard-omission mutant or a
# #8102 classifier leg runs only when its guarded file or the carrier support
# changed; with no impact list (direct runs, full batteries) every arm runs.
. (Join-Path $PSScriptRoot "interrupted-integration-test-support.ps1")
$script:assertions = 0
function Assert-Relevance([bool]$Condition, [string]$Message) {
  $script:assertions++
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}
$saved = $env:CHASE_SETS_BATTERY_IMPACT_PATHS
try {
  $env:CHASE_SETS_BATTERY_IMPACT_PATHS = $null
  Assert-Relevance (Test-BatteryProofRelevant @("landed-integration-evidence.psm1")) "unset impact list must run every arm"
  $env:CHASE_SETS_BATTERY_IMPACT_PATHS = "   "
  Assert-Relevance (Test-BatteryProofRelevant @("landed-integration-evidence.psm1")) "blank impact list must run every arm"
  $env:CHASE_SETS_BATTERY_IMPACT_PATHS = ".orchestrator/dispatch-lane.ps1;.orchestrator/SKILL-notes.md"
  Assert-Relevance (Test-BatteryProofRelevant @("dispatch-lane.ps1")) "changed guarded file must run its arm"
  Assert-Relevance (-not (Test-BatteryProofRelevant @("landed-integration-evidence.psm1"))) "unchanged guarded file must skip its arm"
  Assert-Relevance (Test-BatteryProofRelevant @("landed-integration-evidence.psm1", "dispatch-lane.ps1")) "any changed file in the set must run the arm"
  Assert-Relevance (-not (Test-BatteryProofRelevant @("Dispatch-Lane.ps1"))) "matching is exact and case-sensitive"
  $env:CHASE_SETS_BATTERY_IMPACT_PATHS = ".orchestrator/interrupted-integration-test-support.ps1"
  Assert-Relevance (Test-BatteryProofRelevant @("landed-integration-evidence.psm1")) "a support change must run every arm"
  $env:CHASE_SETS_BATTERY_IMPACT_PATHS = "none"
  Assert-Relevance (-not (Test-BatteryProofRelevant @("dispatch-lane.ps1"))) "an impact run with no orchestrator change skips arms"
} finally {
  $env:CHASE_SETS_BATTERY_IMPACT_PATHS = $saved
}

# Source controls: candidate arms never skip; skipped mutants return null and
# every mutant consumer guards on it; classifier legs run whole carriers.
$support = [IO.File]::ReadAllText((Join-Path $PSScriptRoot "interrupted-integration-test-support.ps1")).Replace("`r`n", "`n")
$discriminator = $support.Substring($support.IndexOf("  function Discriminator("))
$discriminator = $discriminator.Substring(0, $discriminator.IndexOf("`n  function Race("))
Assert-Relevance ($discriminator.IndexOf('$candidate=Launch $f $Extra') -ge 0 -and
  $discriminator.IndexOf('$candidate=Launch $f $Extra') -lt $discriminator.IndexOf('if([string]::IsNullOrEmpty($MutantPath))')) "the candidate arm must run before any mutant skip"
# [string]$MutantPath coerces a skipped mutant's null to an empty string.
Assert-Relevance (-not $discriminator.Contains('if($null-eq$MutantPath)')) "a typed [string] mutant path must be skipped on empty, not only null"
Assert-Relevance ($support.Contains("[void]`$psi.Environment.Remove('CHASE_SETS_BATTERY_IMPACT_PATHS')")) "classifier-leg carrier copies must clear the impact list"
foreach ($guard in @('if($omission){', 'if($skip){', 'if($resumeOmission){', 'if($raceMutant){')) {
  Assert-Relevance ($support.Contains($guard)) "mutant consumer is not null-guarded: $guard"
}
foreach ($test in @("dispatch-lane.test.ps1", "landed-integration-r3.test.ps1")) {
  $text = [IO.File]::ReadAllText((Join-Path $PSScriptRoot $test))
  Assert-Relevance ($text.Contains("Test-BatteryProofRelevant @('landed-integration-evidence.psm1','$test')")) "$test classifier legs are not gated on their classifier files"
}
$dispatchTest = [IO.File]::ReadAllText((Join-Path $PSScriptRoot "dispatch-lane.test.ps1"))
Assert-Relevance ([regex]::Matches($dispatchTest, [regex]::Escape("Invoke-7963ResumeCarriers @('dispatch')")).Count -eq 2) "the unmodified dispatch carrier must run on both the gated and the full path"
Write-Output "PASS battery proof-arm relevance assertions=$script:assertions"
