<#
.SYNOPSIS
Print the short action brief or check one step's attempt and spend arithmetic.
.DESCRIPTION
Read-only: no action execution, credential access, permission grant, or state
storage. Totals must include prior runs and reservations from the result file.
Costs use the brief's single currency as exact decimal or integer values.
.EXAMPLE
./one-shot-action-brief.ps1 -Template
.EXAMPLE
./one-shot-action-brief.ps1 -CheckLimits -AttemptCap 1 -AttemptsUsed 0 -StepAttempts 1 -SpendCap 0 -SpendUsed 0 -StepWorstCaseCost 0 -HistoryKnown $true
#>
[CmdletBinding(DefaultParameterSetName='Template')]
param(
  [Parameter(ParameterSetName='Template')][switch]$Template,
  [Parameter(Mandatory,ParameterSetName='Limits')][switch]$CheckLimits,
  [Parameter(Mandatory,ParameterSetName='Limits')][AllowNull()][object]$AttemptCap,
  [Parameter(Mandatory,ParameterSetName='Limits')][AllowNull()][object]$AttemptsUsed,
  [Parameter(Mandatory,ParameterSetName='Limits')][AllowNull()][object]$StepAttempts,
  [Parameter(Mandatory,ParameterSetName='Limits')][AllowNull()][object]$SpendCap,
  [Parameter(Mandatory,ParameterSetName='Limits')][AllowNull()][object]$SpendUsed,
  [Parameter(Mandatory,ParameterSetName='Limits')][AllowNull()][object]$StepWorstCaseCost,
  [Parameter(Mandatory,ParameterSetName='Limits')][AllowNull()][object]$HistoryKnown
)
$ErrorActionPreference='Stop'

if ($PSCmdlet.ParameterSetName -ceq 'Template') {
  $skill = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'controller-skills/milestone-orchestrator/SKILL.md'))
  $match = [regex]::Match($skill, '(?m)^```one-shot-action-brief\r?\n(?<brief>[\s\S]*?)^```\r?$')
  if (-not $match.Success) { throw 'short action brief template is missing' }
  $match.Groups['brief'].Value.TrimEnd("`r", "`n")
  return
}

function Test-WholeCount($Value) {
  return ($Value -is [int] -or $Value -is [long]) -and $Value -ge 0
}
function Test-Cost($Value) {
  # No binary floating-point rounding or string/bool coercion in money checks.
  return ($Value -is [int] -or $Value -is [long] -or $Value -is [decimal]) -and $Value -ge 0
}
function Get-CostUnits($Value) {
  # Compare at a common exact scale, including tiny costs beside decimal.MaxValue.
  $bits = [decimal]::GetBits([decimal]$Value)
  $units = [Numerics.BigInteger]($bits[0] -band 0xffffffffL) +
    ([Numerics.BigInteger]($bits[1] -band 0xffffffffL) -shl 32) +
    ([Numerics.BigInteger]($bits[2] -band 0xffffffffL) -shl 64)
  $scale = ($bits[3] -shr 16) -band 0xff
  return $units * [Numerics.BigInteger]::Pow(10, (28 - $scale))
}

$reason = 'within-limits'
if ($HistoryKnown -isnot [bool] -or -not $HistoryKnown) {
  $reason = 'unknown-history-or-outcome'
} elseif (-not (Test-WholeCount $AttemptCap) -or -not (Test-WholeCount $AttemptsUsed) -or
    -not (Test-WholeCount $StepAttempts) -or $StepAttempts -eq 0 -or
    -not (Test-Cost $SpendCap) -or -not (Test-Cost $SpendUsed) -or -not (Test-Cost $StepWorstCaseCost)) {
  $reason = 'invalid-limits-or-cost'
} elseif ($AttemptsUsed -gt $AttemptCap -or $StepAttempts -gt ($AttemptCap - $AttemptsUsed)) {
  $reason = 'attempt-cap'
} elseif ((Get-CostUnits $SpendUsed) + (Get-CostUnits $StepWorstCaseCost) -gt (Get-CostUnits $SpendCap)) {
  $reason = 'spend-cap'
}
[pscustomobject][ordered]@{
  fitsWithinLimits = $reason -ceq 'within-limits'
  reason = $reason
} | ConvertTo-Json -Compress
