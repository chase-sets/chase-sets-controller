$ErrorActionPreference = 'Stop'
$errors = $null
$test = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'invoke-heavy-verifier.test.ps1'), [ref]$null, [ref]$errors)
if ($errors.Count) { throw 'ordinary verifier test must parse' }
function Find-Definition($Ast, [string]$Name) {
  $found = @($Ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $Name }, $true))
  if ($found.Count -ne 1) { throw "expected one actual $Name definition" }
  return $found[0]
}
$fixture = Find-Definition $test 'Test-ControllerFixtureEquivalence'
$slots = @($fixture.FindAll({ param($n) $n -is [Management.Automation.Language.ForEachStatementAst] -and $n.Variable.Extent.Text -ceq '$slot' }, $true))
if ($slots.Count -ne 1) { throw 'expected one actual controller/platform exclusivity loop' }
$cleanup = @($slots[0].Body.Statements | Where-Object { $_.Extent.Text -ceq 'Remove-Item -LiteralPath $slotLock -Recurse -Force' })
if ($cleanup.Count -ne 1) { throw 'expected one actual foreign-slot cleanup' }
$fixtureBoundary = (@($slots[0].Body.Statements | Where-Object { $_.Extent.StartOffset -gt $cleanup[0].Extent.EndOffset }).Extent.Text -join "`n")
$failure = @($test.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$failureOut' }, $true))
if ($failure.Count -ne 1) { throw 'expected one actual precursor child-failure case' }
$statements = @($failure[0].Parent.Statements)
$cleanup = @($statements | Where-Object { $_.Extent.EndOffset -lt $failure[0].Extent.StartOffset -and $_.Extent.Text -ceq 'Remove-DisposableLock' } | Select-Object -Last 1)
if ($cleanup.Count -ne 1) { throw 'expected the actual precursor live-owner cleanup' }
$precursorBoundary = (@($statements | Where-Object { $_.Extent.StartOffset -gt $cleanup[0].Extent.EndOffset -and $_.Extent.EndOffset -lt $failure[0].Extent.StartOffset }).Extent.Text -join "`n")
$verifier = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'invoke-heavy-verifier.ps1'), [ref]$null, [ref]$errors)
if ($errors.Count) { throw 'actual verifier must parse' }
foreach ($name in @('Get-QueueTicketContext', 'Remove-QueueTicket')) { . ([scriptblock]::Create((Find-Definition $verifier $name).Extent.Text)) }
. ([scriptblock]::Create((Find-Definition $fixture 'Get-FixtureParameters').Extent.Text))
$temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
$root = Join-Path $temp ('controller-queue-handoff-' + [guid]::NewGuid().ToString('N'))
$container = $root; $worktree = Join-Path $root 'worktree'; $tree = $worktree
$orchestrator = Join-Path $root '.orchestrator'
$lock = Join-Path $orchestrator 'controller-verify-lock.d'; $controllerLock = $lock
$queuePath = Join-Path $orchestrator 'controller-verify-queue.json'
$queueRecoveryPath = Join-Path $orchestrator 'absent-recovery'
$isQueueSlot = $true; $isControllerSlot = $true; $queueMaximumTickets = 128; $queueFixture = @{}
$evidence = Join-Path $root 'same-evidence'; $otherEvidence = Join-Path $root 'other-evidence'
$liveOut = '.orchestrator/artifacts/live-owner.json'; $otherOut = '.orchestrator/artifacts/other.json'
$slot = 'controller'
function Assert-True($Value, [string]$Message) { if (-not $Value) { throw $Message } }
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
function Invoke-TreeGit([string[]]$Arguments) { 'inert' }
function Invoke-InertAdmission([string]$Kind, [string]$Target) {
  $script:claimant.CommandIdentity = "$Kind|$Target"
  $context = Get-QueueTicketContext
  if (-not $context.IsHead) { throw "$Kind command blocked by retained FIFO claimant/command ticket" }
  $script:admissions++
  if (-not $script:retain) { Remove-QueueTicket $context }
  return [pscustomobject]@{ exitCode = 0; ran = $true }
}
function Invoke-FixtureRoute([hashtable]$Parameters) { Invoke-InertAdmission 'fixture' $Parameters.ControllerFixtureEvidenceDirectory }
function Assert-FixtureCompleted($Result, [string]$Evidence, [string]$Name) {
  Assert-True ($Result.exitCode -eq 0 -and $Result.ran) 'inert fixture handoff must complete normally'
}
function Invoke-PrecursorProcess([string]$Producer, [string]$Output) {
  Assert-True ($Producer -ceq 'fail-closed-guard-evidence') 'handoff must retry the original producer'
  $result = Invoke-InertAdmission 'precursor' $Output
  [IO.File]::WriteAllText((Join-Path $worktree $Output), 'inert artifact')
  return $result
}
function Assert-Handoff([string]$Kind, [string]$Boundary, [bool]$Retain = $false) {
  $script:queue = [pscustomobject]@{ Tickets = @(); NextTicket = 1; Bytes = [byte[]]@(); Hash = 'inert' }
  $target = if ($Kind -ceq 'fixture') { $evidence } else { $liveOut }
  $script:claimant = [pscustomobject]@{ Key = 'parent'; Pid = 1001; StartIdentity = 'parent-start'; ChildPid = $null; ChildStartIdentity = $null; CommandIdentity = "$Kind|$target" }
  $script:admissions = 0; $script:retain = $Retain
  $prior = Get-QueueTicketContext
  Assert-True ($prior.IsHead -and $prior.Ticket.number -eq 1) 'live-owner refusal retains its original FIFO ticket'
  . ([scriptblock]::Create($Boundary))
  $script:claimant.CommandIdentity = "$Kind|next-command"
  $next = Get-QueueTicketContext
  Assert-True ($next.IsHead) "$Kind next command blocked by retained FIFO claimant/command ticket"
  Assert-True ($script:admissions -eq 1 -and $script:queue.Tickets.Count -eq 1 -and $script:queue.Tickets[0].commandIdentity -ceq "$Kind|next-command") 'actual boundary must retire only its original ticket through normal admission'
}
try {
  [void][IO.Directory]::CreateDirectory($orchestrator)
  [void][IO.Directory]::CreateDirectory((Join-Path $worktree '.orchestrator/artifacts'))
  $failures = @()
  foreach ($case in @(@{ Kind = 'fixture'; Source = $fixtureBoundary }, @{ Kind = 'precursor'; Source = $precursorBoundary })) {
    try { Assert-Handoff $case.Kind $case.Source } catch { $failures += $_.Exception.Message }
  }
  if ($failures.Count) { throw ($failures -join '; ') }
  foreach ($case in @(@{ Kind = 'fixture'; Source = $fixtureBoundary }, @{ Kind = 'precursor'; Source = $precursorBoundary })) {
    $retainedReason = if ($case.Kind -ceq 'fixture') { 'fixture controller-owner handoff retires the original command ticket' } else { 'precursor live-owner handoff retires the original command ticket' }
    foreach ($mutant in @(@{ Source = ''; Retain = $false; Reason = "$($case.Kind) next command blocked by retained FIFO claimant/command ticket" }, @{ Source = $case.Source; Retain = $true; Reason = $retainedReason })) {
      $reason = $null
      try { Assert-Handoff $case.Kind $mutant.Source $mutant.Retain } catch { $reason = $_.Exception.Message }
      if ($reason -cne $mutant.Reason) { throw "missing handoff or retained-ticket mutant must fail at its named queue assertion: $reason" }
    }
    $wrong = if ($case.Kind -ceq 'fixture') { $case.Source.Replace('(Get-FixtureParameters $evidence)', '(Get-FixtureParameters $otherEvidence)') } else { $case.Source.Replace('$liveOut', '$otherOut') }
    if ($wrong -ceq $case.Source) { throw 'wrong-command mutant anchor missing' }
    $refused = $false
    try { Assert-Handoff $case.Kind $wrong } catch { $refused = $_.Exception.Message -match 'blocked by retained FIFO' }
    if (-not $refused) { throw 'a different command must not consume the original FIFO ticket' }
  }
  Write-Output 'PASS actual controller fixture/precursor boundaries retry the exact refused command before switching commands; actual queue retains FIFO and command binding; missing handoff, retained ticket and wrong-command mutants refuse; no process, census, native helper, Job or signal'
} finally {
  $full = [IO.Path]::GetFullPath($root)
  if ([IO.Path]::GetDirectoryName($full) -ine $temp -or [IO.Path]::GetFileName($full) -cnotmatch '^controller-queue-handoff-[0-9a-f]{32}$') { throw 'refusing cleanup outside private controller queue fixture' }
  if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
}
