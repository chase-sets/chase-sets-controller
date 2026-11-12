[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$helper = Join-Path $PSScriptRoot 'one-shot-action-brief.ps1'
$script:checks = 0
function Assert-Brief([bool]$Condition, [string]$Message) {
  $script:checks++
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}
function Check-Limits([hashtable]$Changes=@{}) {
  $parameters = @{CheckLimits=$true;AttemptCap=1;AttemptsUsed=0;StepAttempts=1;SpendCap=0;SpendUsed=0;StepWorstCaseCost=0;HistoryKnown=$true}
  foreach ($key in $Changes.Keys) { $parameters[$key] = $Changes[$key] }
  & $helper @parameters | ConvertFrom-Json
}
function Refuses([hashtable]$Changes,[string]$Reason) {
  $result = Check-Limits $Changes
  Assert-Brief (-not $result.fitsWithinLimits -and $result.reason -ceq $Reason) "expected $Reason, got $($result | ConvertTo-Json -Compress)"
}

Assert-Brief (Check-Limits).fitsWithinLimits 'one unpaid attempt fits a one-attempt, zero-spend cap'
Assert-Brief (Check-Limits @{AttemptCap=3;AttemptsUsed=2;SpendCap=1.0d;SpendUsed=0.9d;StepWorstCaseCost=0.1d}).fitsWithinLimits 'exact attempt and decimal spend boundaries fit'
Refuses @{AttemptsUsed=1} 'attempt-cap'
Refuses @{AttemptsUsed=2} 'attempt-cap'
Refuses @{StepAttempts=2} 'attempt-cap'
Refuses @{AttemptCap=0} 'attempt-cap'
Refuses @{SpendCap=1;SpendUsed=1;StepWorstCaseCost=0.01d} 'spend-cap'
Refuses @{SpendUsed=1} 'spend-cap'
Refuses @{StepWorstCaseCost=0.01d} 'spend-cap'
Refuses @{HistoryKnown=$false;AttemptCap=5;SpendCap=100} 'unknown-history-or-outcome'
Refuses @{HistoryKnown='true'} 'unknown-history-or-outcome'
Refuses @{HistoryKnown=$null} 'unknown-history-or-outcome'
foreach ($field in @('AttemptCap','AttemptsUsed','StepAttempts')) {
  foreach ($value in @($null,-1,1.5,'1',$true,[double]::NaN)) { Refuses @{$field=$value} 'invalid-limits-or-cost' }
}
Refuses @{StepAttempts=0} 'invalid-limits-or-cost'
foreach ($field in @('SpendCap','SpendUsed','StepWorstCaseCost')) {
  foreach ($value in @($null,-1,'0',$true,0.1,1e-30,-1e-30,[double]::NaN,[double]::PositiveInfinity,[double]::NegativeInfinity,[double]::MaxValue)) {
    Refuses @{$field=$value} 'invalid-limits-or-cost'
  }
}
Refuses @{AttemptCap=[long]::MaxValue;AttemptsUsed=[long]::MaxValue;StepAttempts=1} 'attempt-cap'
Refuses @{SpendCap=[decimal]::MaxValue;SpendUsed=[decimal]::MaxValue;StepWorstCaseCost=1} 'spend-cap'
Refuses @{SpendCap=[decimal]::MaxValue;SpendUsed=0.01d;StepWorstCaseCost=[decimal]::MaxValue} 'spend-cap'
Refuses @{SpendCap=0;StepWorstCaseCost=0.0000000000000000000000000001d} 'spend-cap'
Assert-Brief (Check-Limits @{SpendCap=[decimal]::MaxValue;StepWorstCaseCost=[decimal]::MaxValue}).fitsWithinLimits 'maximum exact cost fits without overflow'

# Restart/replacement consumes the same totals; unknown outcomes never buy replay.
$remaining = @{AttemptCap=2;AttemptsUsed=1;SpendCap=10;SpendUsed=6;StepWorstCaseCost=4}
Assert-Brief (Check-Limits $remaining).fitsWithinLimits 'known prior reservation leaves exactly one affordable attempt'
$remaining.AttemptsUsed=2
Refuses $remaining 'attempt-cap'
$remaining.AttemptsUsed=1
$remaining.HistoryKnown=$false
Refuses $remaining 'unknown-history-or-outcome'

$template = (& $helper -Template | Out-String).Trim()
Assert-Brief ($template -ceq ((& $helper | Out-String).Trim())) 'default prints the same template'
Assert-Brief ($template.Length -lt 1000) 'template stays short'
foreach ($part in @('Goal:','Hard limits:','attempt cap per action','spend cap and currency','staging only','no secrets','credential access','TCGplayer: never contact','Steps:','worst-case cost','Result file:','execution-time deployed SHA')) {
  Assert-Brief ($template.Contains($part,[StringComparison]::Ordinal)) "template contains $part"
}
$skill = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'controller-skills/milestone-orchestrator/SKILL.md'))
$section = [regex]::Match($skill,'(?ms)^### One-shot external actions\r?\n(.*?)(?=^## |\z)').Value -replace '\s+',' '
foreach ($rule in @(
  'The brief grants no action, credential, or Todd-only authority.',
  'Review the brief once when production or money is involved; otherwise no brief review is required.',
  'No extra packet review, hash custody, operation-map, release-manifest, START-file, or executor-admission packet is required',
  'no process-permission decision lane is needed for this path',
  'read the target''s actual deployed SHA',
  'Do not pin to current main, require deployed SHA = main, or invalidate/rebind the brief on main merges',
  'Reserve its attempt units and worst-case cost in the result file before issuing it; if that write fails, do not act.',
  'Disable automatic retries unless each retry is explicitly within the same caps.',
  'An unknown outcome, uncertain submission, missing result history, or unknown cost stops further actions',
  'read-only reconciliation may resolve it, never replay it to find out.',
  'Renaming the brief, replacing an executor, replanning, or a review never resets a cap or authorizes extra paid attempts.'
)) { Assert-Brief ($section.Contains($rule,[StringComparison]::Ordinal)) "one-shot hard gate missing: $rule" }
Write-Output "PASS short one-shot brief: template, attempt/spend boundaries, invalid/unknown history and restart checks=$script:checks; no external actions"
