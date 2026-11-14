$ErrorActionPreference = 'Stop'
$errors = $null
$test = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'invoke-heavy-verifier.test.ps1'), [ref]$null, [ref]$errors)
if ($errors.Count) { throw 'ordinary verifier test must parse' }
$launch = @($test.FindAll({ param($node)
  $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$orphanWrapper'
}, $true))
if ($launch.Count -ne 1) { throw 'expected one actual orphan wrapper launch' }
$statements = @($launch[0].Parent.Statements)
$cleanup = @($statements | Where-Object { $_.Extent.Text -ceq 'Remove-Item -LiteralPath $reparseTarget -Recurse -Force' })
if ($cleanup.Count -ne 1) { throw 'expected one preceding reparse refusal cleanup' }
$boundary = @($statements | Where-Object {
  $_.Extent.StartOffset -gt $cleanup[0].Extent.EndOffset -and $_.Extent.StartOffset -le $launch[0].Extent.StartOffset
})
$source = $boundary.Extent.Text -join "`n"
$verifier = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'invoke-heavy-verifier.ps1'), [ref]$null, [ref]$errors)
if ($errors.Count) { throw 'actual verifier must parse' }
foreach ($name in @('Get-QueueTicketContext', 'Remove-QueueTicket')) {
  $definitions = @($verifier.FindAll({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
  }, $true))
  if ($definitions.Count -ne 1) { throw "expected one actual $name definition" }
  . ([scriptblock]::Create($definitions[0].Extent.Text))
}
$temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
$root = Join-Path $temp ('orphan-queue-handoff-' + [guid]::NewGuid().ToString('N'))
$orchestrator = Join-Path $root '.orchestrator'
$lock = Join-Path $orchestrator 'verify-lock.d'
$queueRecoveryPath = Join-Path $root 'absent-recovery'
$queuePath = Join-Path $orchestrator 'verify-queue.json'
$markerScript = 'inert-marker-script'
$identityChildScript = 'inert-identity-script'
$isQueueSlot = $true
$isControllerSlot = $false
$queueMaximumTickets = 256
$queueFixture = @{}
function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Test-PathEntry([string]$Path) { Test-Path -LiteralPath $Path }
function Get-QueueNow { [datetimeoffset]::Parse('2026-01-01T00:00:00Z') }
function Get-QueueClaimant { $script:claimant }
function Test-QueueTicketRetained($Ticket, $Now) { $true }
function Read-VerifyQueue { $script:queue }
function Assert-VerifyQueueUnchanged($Queue) {}
function Write-VerifyQueue($Queue) {
  $script:queue = $Queue
  [IO.File]::WriteAllText($queuePath, ($Queue | ConvertTo-Json -Depth 10 -Compress))
}
function Invoke-Guard([string]$Lane, [string[]]$ChildArguments) {
  $context = Get-QueueTicketContext
  if (-not $context.IsHead) { throw 'parent handoff must use its existing FIFO head ticket' }
  $script:admissions++
  if (-not $script:retainTicket) { Remove-QueueTicket $context }
  [IO.File]::WriteAllText($ChildArguments[3], 'inert admitted marker')
  return 0
}
function Start-Wrapper([string]$Lane, [string[]]$ChildArguments) {
  $script:claimant = [pscustomobject]@{ Key = 'wrapper'; Pid = 1002; StartIdentity = 'wrapper-start'; ChildPid = $null; ChildStartIdentity = $null }
  $context = Get-QueueTicketContext
  if (-not $context.IsHead) { throw 'orphan wrapper blocked by preceding live claimant' }
  return 'inert-wrapper'
}
function Assert-OrphanHandoff([string]$Boundary, [bool]$RetainTicket = $false) {
  $script:queue = [pscustomobject]@{ Tickets = @(); NextTicket = 1; Bytes = [byte[]]@(); Hash = 'inert' }
  $script:claimant = [pscustomobject]@{ Key = 'parent'; Pid = 1001; StartIdentity = 'parent-start'; ChildPid = $null; ChildStartIdentity = $null }
  $script:admissions = 0
  $script:retainTicket = $RetainTicket
  $prior = Get-QueueTicketContext
  if (-not $prior.IsHead -or $prior.Ticket.number -ne 1) { throw 'inert refusal must retain the original parent ticket' }
  . ([scriptblock]::Create($Boundary))
  if ($script:admissions -ne 1 -or $orphanWrapper -cne 'inert-wrapper' -or
      $script:queue.Tickets.Count -ne 1 -or $script:queue.Tickets[0].claimantKey -cne 'wrapper') {
    throw 'actual orphan boundary must retire only the parent ticket through normal admission before wrapper launch'
  }
}
try {
  [void][IO.Directory]::CreateDirectory($orchestrator)
  Assert-OrphanHandoff $source
  $handoff = @($boundary | Where-Object { $_.Find({ param($node)
    $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Invoke-Guard'
  }, $true) })
  if ($handoff.Count -ne 1) { throw 'expected one normal admission at the actual orphan boundary' }
  foreach ($case in @(
    @{ Source = $source.Replace($handoff[0].Extent.Text, ''); Retain = $false; Reason = 'orphan queue handoff retires the preceding claimant ticket' },
    @{ Source = $source; Retain = $true; Reason = 'orphan queue handoff retires the preceding claimant ticket' }
  )) {
    $reason = $null
    try { Assert-OrphanHandoff $case.Source $case.Retain } catch { $reason = $_.Exception.Message }
    if ($reason -cne $case.Reason) { throw "missing admission or retained parent ticket mutant must fail at its queue assertion: $reason" }
  }
  Write-Output 'PASS actual orphan boundary retires its preceding claimant through normal FIFO admission; missing handoff and retained ticket mutants refuse; no process, admission census, Job or signal'
} finally {
  $full = [IO.Path]::GetFullPath($root)
  if ([IO.Path]::GetDirectoryName($full) -ine $temp -or [IO.Path]::GetFileName($full) -cnotmatch '^orphan-queue-handoff-[0-9a-f]{32}$') { throw 'refusing cleanup outside private orphan handoff fixture' }
  if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
}
