[CmdletBinding()]
param(
  [ValidateSet('', 'bypass-fifo', 'skip-absent-head', 'renumber-on-retry', 'prune-live', 'never-expire', 'reset-without-authority', 'quarantine-early', 'ignore-marker', 'rename-completes')]
  [string]$Mutant = '',
  [string]$GuardRevision = ''
)
$ErrorActionPreference = 'Stop'
$guardPath = Join-Path $PSScriptRoot 'invoke-heavy-verifier.ps1'
$root = Split-Path -Parent $PSScriptRoot
$source = if ($GuardRevision) {
  $text = @(& git -C $root show "${GuardRevision}:.orchestrator/invoke-heavy-verifier.ps1")
  if ($LASTEXITCODE -ne 0) { throw "unable to read guard revision $GuardRevision" }
  $text -join "`n"
} else { [IO.File]::ReadAllText($guardPath) }
function Assert-Fifo($Condition, [string]$Message) { if (-not $Condition) { throw "ASSERTION FAILED: $Message" } }
$mutations = @{
  'bypass-fifo' = @('if (-not $queueContext.IsHead) {', 'if ($false) {')
  'skip-absent-head' = @('$reserved = -not (Test-Path -LiteralPath $lockPath)', '$reserved = $false')
  'renumber-on-retry' = @('$ticket.presentedUtc = $now.ToString(''o''); $changed = $true', '$ticket.number = $queue.NextTicket; $ticket.presentedUtc = $now.ToString(''o''); $changed = $true')
  'prune-live' = @("if (`$state -in @('live','ambiguous')) { return `$true }", "if (`$state -eq 'ambiguous') { return `$true }")
  'never-expire' = @("if ((`$Now - `$presented).TotalSeconds -gt `$queueRetentionSeconds) { return `$false }", "if (`$false) { return `$false }")
  'reset-without-authority' = @("if (`$marker.sha256 -cne `$QuarantineQueue -or `$marker.path -cne `$queuePath -or", "if (`$false -or `$marker.path -cne `$queuePath -or")
  'quarantine-early' = @("if (([DateTimeOffset]::UtcNow - [DateTimeOffset]::Parse(`$marker.wrapperUtc)).TotalSeconds -le `$queueRetentionSeconds)", "if (`$false)")
  'ignore-marker' = @("if (Test-Path -LiteralPath `$queueRecoveryPath) { throw `"heavy-verifier: verify queue recovery marker present (`$queueRecoveryPath)`" }", "if (`$false) { throw `"heavy-verifier: verify queue recovery marker present (`$queueRecoveryPath)`" }")
  'rename-completes' = @("[IO.File]::Move(`$queuePath, `$recordQueue)", "Copy-Item -LiteralPath `$queuePath -Destination `$recordQueue")
}
if ($Mutant) {
  $edit = $mutations[$Mutant]
  $count = ([regex]::Matches($source, [regex]::Escape($edit[0]))).Count
  Assert-Fifo ($count -eq 1) "mutant anchor occurs once: $Mutant (observed $count)"
  $source = $source.Replace($edit[0], $edit[1])
}
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
Assert-Fifo ($errors.Count -eq 0) 'candidate guard parses'
$functionNames = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object Name)
foreach ($name in @('Get-QueueClaimant','Read-VerifyQueue','Write-VerifyQueue','Get-QueueTicketContext','Remove-QueueTicket','Invoke-QueueQuarantine')) {
  Assert-Fifo ($functionNames -contains $name) "queue function missing: $name"
}
Assert-Fifo ($source -match '\$queuePath = Join-Path \$container.*verify-queue\.json') 'queue is outside the lock directory'
Assert-Fifo ($source -match '\$queueRetentionSeconds = 600') 'waiter liveness bound is explicit'
Assert-Fifo ($source -match '\$queueMaximumTickets = 128' -and $source -match '\$queueMaximumBytes = 256 \* 1024') 'queue bounds are explicit'
Assert-Fifo ($source -match 'if \(-not \$queueContext\.IsHead\)') 'non-head claimants refuse before acquisition'
Assert-Fifo ($source -match 'retry within \$queueRetentionSeconds seconds') 'queued refusal names retry window'
Assert-Fifo ($source -match 'Assert-VerifyQueueUnchanged \$Context\.Queue') 'ticket removal revalidates queue bytes'
Assert-Fifo ($source -match 'if \(\$isControllerBattery -or \$isControllerPrecursor -or \$isControllerFixture\)') 'controller slots retain isolation'
Assert-Fifo ($source -match 'if \(\$QuarantineQueue\)') 'quarantine is an explicit host action'
if (-not $Mutant) {
  $result = & pwsh -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'invoke-heavy-verifier.test.ps1') -RoleAdmissionOnly 2>&1
  if ($LASTEXITCODE -ne 0) { throw "real entrypoint smoke failed (exit=$LASTEXITCODE): $($result -join "`n")" }
  Write-Output 'PASS FIFO real entrypoint smoke: Gate/Attach/NativeDb eligibility and controller-slot isolation'
  Write-Output 'PASS FIFO baseline: queue path, bounded tickets, stable claimant, head-only admission, atomic removal, and marker quarantine anchors'
} else {
  throw "MUTANT RED: $Mutant"
}
