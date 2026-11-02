<#
.SYNOPSIS
Pre-flight and register an orchestrator host-trial arm, then print the exact
launch command. Does NOT start the session — the host is an interactive Claude
Code / Codex session Todd drives.

WHY A SCRIPT: the host seat is the one role with no external validator. This
reports the current host identity facts, verifies the exact model selection,
and records the arm so the block is attributable at the recompute.

.EXAMPLE
./start-host-trial.ps1 -Arm opus5-high
./start-host-trial.ps1 -Arm sonnet5-high -Register
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [ValidateSet("opus5-high", "sonnet5-high", "sol-high", "astra-high")]
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

$arms = @{
  "astra-high" = @{
    harness = "codex"; model = "gpt-6-astra"; effort = "high"
    guardrails = $null
    note = "Selectable Astra host arm (Todd, 2026-09-04); unmeasured host capability. Sol high remains the default. No predecessor evidence transfers."
  }
  "opus5-high" = @{
    harness = "claude"; model = "claude-opus-5"; effort = "high"
    guardrails = Join-Path $PSScriptRoot "host-trial-opus5-guardrails.md"
    note = "TRIAL ARM — registered tier-C active trial. Opus 5 has no measured host-seat data; its lane numbers do not transfer to a long-lived session."
  }
  "sonnet5-high" = @{
    harness = "claude"; model = "claude-sonnet-5"; effort = "high"
    guardrails = $null; note = "standing Claude-harness host (model-routing row 9)"
  }
  "sol-high" = @{
    harness = "codex"; model = "gpt-5.6-sol"; effort = "high"
    guardrails = $null; note = "standing Codex-harness host (model-routing row 9)"
  }
}
$a = $arms[$Arm]

$problems = @()

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
if ($a.model -eq "claude-opus-5") {
  Write-Output "identity: launch pins 'claude-opus-5' explicitly (never the bare 'opus' alias — it resolved to off-roster claude-opus-4-8 on Claude CLI 2.1.218)"
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
