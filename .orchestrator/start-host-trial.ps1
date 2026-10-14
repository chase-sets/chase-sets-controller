<#
.SYNOPSIS
Pre-flight and register an orchestrator host-trial arm, then print the exact
launch command. Does NOT start the session — the host is an interactive Claude
Code / Codex session Todd drives.

WHY A SCRIPT: the host seat is the one role with no external validator. This
reports the current host identity facts, verifies the exact model selection,
and records the arm so the block is attributable at the recompute.

.EXAMPLE
./start-host-trial.ps1 -Arm opus55-high
./start-host-trial.ps1 -Arm sonnet55-high -Register
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [ValidateSet("opus55-high", "sonnet55-high", "sol61-high", "astra-high")]
  [string]$Arm,
  # Write the arm-start marker to dispatch-log.jsonl. Omit for a dry pre-flight.
  [switch]$Register,
  [string]$Lease,
  [string]$DispatchLog,
  # Opaque, caller-created orchestration session identity. Never inferred from
  # a process, worktree, model, or historical telemetry row.
  [string]$Holder
)

$ErrorActionPreference = "Stop"
if (-not $Lease)       { $Lease = Join-Path $PSScriptRoot "lease.json" }
if (-not $DispatchLog) { $DispatchLog = Join-Path $PSScriptRoot "dispatch-log.jsonl" }
Import-Module (Join-Path $PSScriptRoot "lease-contract.psm1") -Force -DisableNameChecking
. (Join-Path $PSScriptRoot 'routing-data.ps1') -Library

$routingData = $null
$routingFailure = $null
try { $routingData = Get-RoutingData -ReadOnly } catch { $routingFailure = $_.Exception.Message }

$arms = @{
  "astra-high" = @{
    harness = "codex"; family = "astra"; effort = "high"
    guardrails = $null
    note = "Selectable Astra host arm (Todd, 2026-09-04); unmeasured host capability. Sol high remains the default. No predecessor evidence transfers."
  }
  "opus55-high" = @{
    harness = "claude"; family = "opus"; effort = "high"
    guardrails = Join-Path $PSScriptRoot "host-opus55-guardrails.md"
    note = "Provisional successor host arm. Opus 5.5 has no local host-seat evidence; predecessor and lane measurements do not transfer."
  }
  "sonnet55-high" = @{
    harness = "claude"; family = "sonnet"; effort = "high"
    guardrails = $null; note = "In-place Sonnet 5.5 host arm, override-Todd until measured; not the default host. Only Todd selects or rotates the host. No Sonnet 5 evidence transfers."
  }
  "sol61-high" = @{
    harness = "codex"; family = "sol"; effort = "high"
    guardrails = $null; note = "standing Codex-harness host (model-routing row 9); in-place Sol 6.1 replacement of sol6-high, provisional, no Sol 6 evidence transfers"
  }
}
$a = $arms[$Arm]
$a.model = if ($routingData -and $routingData.registry.families.PSObject.Properties[$a.family]) {
  [string]$routingData.registry.families.PSObject.Properties[$a.family].Value.current
} else { $null }

$problems = @()
if (-not $routingData) { $problems += "routing registry unavailable: $routingFailure" }
elseif ([string]::IsNullOrWhiteSpace($a.model)) { $problems += "routing family '$($a.family)' has no current model" }
else {
  $admissionReason = Get-RoutingAdmissionReason $routingData.registry $a.model $a.effort
  if ($admissionReason) { $problems += "host arm is not admitted: $admissionReason" }
}

# --- 1. host identity facts -------------------------------------------------
$leaseReading = Read-OrchestrationLease -Path $Lease
switch ($leaseReading.status) {
  "missing" { Write-Output "host identity: absent — acquire writes this host's identity" }
  "ok" {
    Write-Output "host identity: holder='$($leaseReading.record.holder)' model='$($leaseReading.record.model)' effort='$($leaseReading.record.effort)' renewedAt='$($leaseReading.record.renewedAt)' — acquire or renew may overwrite it"
  }
  default {
    $problems += "The host identity record cannot be read (status=$($leaseReading.status), diagnostics=$($leaseReading.diagnostics -join ','))."
  }
}
if ($Register -and -not $Holder) {
  $problems += "-Register requires -Holder with a new opaque orchestration session identity; identity is never inferred."
}

# --- 2. Opus 4.8 must not be reachable through an alias ---------------------
if ($a.family -eq "opus") {
  Write-Output "identity: launch pins 'claude-opus-5-5' explicitly (never the bare 'opus' alias — it resolved to off-roster claude-opus-4-8 on Claude CLI 2.1.218)"
}

# --- 3. guardrail file must exist for arms that declare one ----------------
if ($a.guardrails -and -not (Test-Path -LiteralPath $a.guardrails)) {
  $problems += "guardrail file missing: $($a.guardrails)"
}

if ($problems.Count -gt 0) {
  Write-Output ""
  Write-Output "PRE-FLIGHT FAILED:"
  $problems | ForEach-Object { Write-Output "  - $_" }
  exit 1
}

# --- 4. register the arm ----------------------------------------------------
if ($Register) {
  Write-Output ""
  Write-Output "registered: host-trial arm '$Arm'; lease.ps1 records the live host identity"
}

# --- 5. print the launch ----------------------------------------------------
Write-Output ""
Write-Output "=== HOST ARM: $Arm ==="
Write-Output "  harness   : $($a.harness)"
Write-Output "  model     : $($a.model)   (pin explicitly — never an alias)"
Write-Output "  effort    : $($a.effort)"
if ($Arm -ceq 'sonnet55-high') {
  Write-Output '  placement : override-Todd'
  Write-Output "  note      : $($a.note)"
}
if ($Holder) {
  Write-Output "  holder    : $Holder (opaque orchestration session identity)"
  Write-Output "  acquire   : .\lease.ps1 -Action Acquire -Holder '$Holder' -Harness '$($a.harness)' -Model '$($a.model)' -Effort '$($a.effort)'"
  Write-Output "  renew     : .\lease.ps1 -Action Renew -Holder '$Holder' -Harness '$($a.harness)' -Model '$($a.model)' -Effort '$($a.effort)'"
} else {
  Write-Output "  holder    : REQUIRED before launch; supply -Holder with a new opaque session identity"
}
if ($a.guardrails) { Write-Output "  guardrails: $($a.guardrails)  <- paste into the session at start" }
Write-Output ""
if ($a.harness -eq "claude") {
  Write-Output "Launch from the container root:"
  Write-Output "  claude --model $($a.model) --effort $($a.effort)"
} else {
  Write-Output "Launch from the container root:"
  Write-Output "  codex --model $($a.model) --config model_reasoning_effort=$($a.effort)"
}
Write-Output ""
Write-Output "First actions in the session:"
Write-Output "  1. Confirm the reported model identity is exactly '$($a.model)'. If not, STOP — do not write the host identity record."
Write-Output "  2. Load the milestone-orchestrator skill."
if ($a.guardrails) { Write-Output "  3. Paste the guardrails file above." }
Write-Output "  $(if ($a.guardrails) { 4 } else { 3 }). Acquire through lease.ps1 with the exact holder above; renew through the same helper every cycle."
Write-Output "  $(if ($a.guardrails) { 5 } else { 4 }). Run the daily sweep (cost-harvest.ps1, then matrix-refresh.ps1)."
if (-not $Register) {
  Write-Output ""
  Write-Output "(pre-flight only — re-run with -Register to record the arm start)"
}
