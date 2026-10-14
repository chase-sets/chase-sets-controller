<#
.SYNOPSIS
Reduce a bounded, complete review history for one PR and its current exact head.

.DESCRIPTION
Emits exactly one versioned result whose state is authorized, blocked, stale,
or unknown. It never mutates the history. Controller-release receipts keyed by
controllerHead are counted for audit and ignored for ordinary PR authority.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$Pr,
  [Parameter(Mandatory)][ValidatePattern("^[a-f0-9]{40}$")][string]$CurrentHead,
  [string]$HistoryPath = (Join-Path $PSScriptRoot "dispatch-log.jsonl"),
  [ValidateRange(1, 1000000)][int]$MaxHistoryRows = 50000,
  [ValidateRange(1, [long]::MaxValue)][long]$MaxHistoryBytes = 33554432
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "review-head-contract.psm1") -Force -DisableNameChecking
$history = Read-ExactHeadReviewHistory -Path $HistoryPath -MaxRows $MaxHistoryRows -MaxBytes $MaxHistoryBytes
$result = Reduce-ExactHeadReview -Pr $Pr -CurrentHead $CurrentHead -History $history
$result | ConvertTo-Json -Depth 8
