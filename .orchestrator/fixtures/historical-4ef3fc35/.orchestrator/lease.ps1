<#
.SYNOPSIS
Acquire or renew the canonical orchestration lease.

The caller supplies `holder`; that opaque value is the orchestration session
identity. It is never derived from a process, model, worktree, or prior row.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [ValidateSet("Acquire", "Renew", "HandoffCutoverRecovery")]
  [string]$Action,
  [string]$Lease,
  [Parameter(Mandatory)][string]$Holder,
  [Parameter(Mandatory)][string]$Harness,
  [Parameter(Mandatory)][string]$Model,
  [string]$Effort = "high",
  [Parameter(DontShow)][datetimeoffset]$NowUtc = [datetimeoffset]::UtcNow,
  [string]$CurrentRecordPath,
  [string]$RecoveryCapabilityPath,
  [string]$HandoffReceiptPath,
  [ValidatePattern("^[a-f0-9]{32}$")][string]$TransactionId
)

$ErrorActionPreference = "Stop"
if (-not $Lease) { $Lease = Join-Path $PSScriptRoot "lease.json" }
Import-Module (Join-Path $PSScriptRoot "lease-contract.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "orchestration-log-lock.psm1") -Force -DisableNameChecking

if ($Action -eq "HandoffCutoverRecovery") {
  if (-not $CurrentRecordPath -or -not $RecoveryCapabilityPath -or -not $HandoffReceiptPath -or -not $TransactionId) {
    throw "orchestration recovery handoff refused: required inputs missing"
  }
  $handoff = Invoke-WithOrchestrationLogLock -Body {
    Handoff-CutoverRecoveryLease -Path $Lease -CurrentRecordPath $CurrentRecordPath `
      -RecoveryCapabilityPath $RecoveryCapabilityPath -HandoffReceiptPath $HandoffReceiptPath `
      -TransactionId $TransactionId -Holder $Holder -Harness $Harness -Model $Model -Effort $Effort -NowUtc $NowUtc
  }
  $handoff.record | ConvertTo-Json -Compress -Depth 20
  return
}

$arguments = @{
  Path = $Lease
  Holder = $Holder
  Harness = $Harness
  Model = $Model
  Effort = $Effort
  NowUtc = $NowUtc
}
$result = if ($Action -eq "Acquire") {
  Acquire-OrchestrationLease @arguments
} else {
  Renew-OrchestrationLease @arguments
}
$result.record | ConvertTo-Json -Compress
