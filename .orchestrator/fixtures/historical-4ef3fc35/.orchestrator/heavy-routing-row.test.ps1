[CmdletBinding()]
param([string]$GuardRevision = '')

$ErrorActionPreference = 'Stop'
(Get-Process -Id $PID).PriorityClass = 'BelowNormal'
function Assert-True($Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}
function Read-Source([string]$Name) {
  if (-not $GuardRevision) { return [IO.File]::ReadAllText((Join-Path $PSScriptRoot $Name)) }
  $lines = @(& git -C (Split-Path -Parent $PSScriptRoot) show "${GuardRevision}:.orchestrator/$Name")
  if ($LASTEXITCODE -ne 0) { throw "cannot read $Name at $GuardRevision" }
  return $lines -join "`n"
}
. ([scriptblock]::Create((Read-Source 'dispatch-ownership.ps1')))
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput((Read-Source 'invoke-heavy-verifier.ps1'), [ref]$tokens, [ref]$errors)
Assert-True ($errors.Count -eq 0) 'guard source parses'
$definitions = @($ast.FindAll({ param($n)
  $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Get-HeavyRoutingRow'
}, $false))
Assert-True ($definitions.Count -eq 1) 'one production routing-row reader'
. ([scriptblock]::Create($definitions[0].Extent.Text))

# Run the real closed validator and routing reader against a private ledger.
# No dispatch, heavy reservation, process census or command body is started.
$temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
$root = Join-Path $temp ('heavy-routing-row-test-' + [guid]::NewGuid().ToString('N'))
$instant = [datetime]::SpecifyKind([datetime]'2026-01-01', [DateTimeKind]::Utc)
$record = [pscustomobject]@{
  launcherStartIdentity = $instant.AddSeconds(-2).ToString('o')
  recordedAt = $instant.AddSeconds(-1).ToString('o')
  childStartIdentity = $instant.ToString('o')
  label = 'synthetic-routing'; lane = 'synthetic-routing'; worktree = $root
  transcriptPath = (Join-Path $root 'synthetic-routing.jsonl')
  branch = 'synthetic/routing'; head = ('a' * 40)
  policyGeneration = 1; registryAuthorityDigest = 'synthetic-digest'
  family = 'astra'; slot = 'explicit'; usedLastKnownGood = $false
}
$missing = 'routing row missing or ambiguous for current launch'
$invalid = 'routing row invalid'
$cases = @(
  @{ Name = 'F1 ledger before recordedAt without issue'; Offset = -1500; Expected = '' }
  @{ Name = 'F2 issue-bearing v2 after recordedAt'; Offset = -500; Issue = 8549; Expected = '' }
  @{ Name = 'F1+F2 issue-bearing v2 before recordedAt'; Offset = -1500; Issue = 8549; Expected = '' }
  @{ Name = 'historical before launcher without issue'; Offset = -2001; Expected = $missing }
  @{ Name = 'historical before launcher with issue'; Offset = -2001; Issue = 8549; Expected = $missing }
  @{ Name = 'after child start'; Offset = 1; Issue = 8549; Expected = $missing }
  @{ Name = 'malformed issue zero'; Offset = -1500; Issue = 0; Expected = $invalid }
  @{ Name = 'malformed issue string'; Offset = -1500; Issue = '8549'; Expected = $invalid }
  @{ Name = 'unknown extra key'; Offset = -1500; Issue = 8549; Extra = $true; Expected = $invalid }
)
$failures = [Collections.Generic.List[string]]::new()
try {
  [IO.Directory]::CreateDirectory($root) | Out-Null
  foreach ($case in $cases) {
    $row = [ordered]@{
      ts = $instant.AddMilliseconds($case.Offset).ToString('o')
      kind = 'dispatch'; dispatchRoutingSchema = 'watchdog-dispatch-routing/v2'
      attemptId = 'synthetic-routing'; label = $record.label; lane = $record.lane; laneRole = 'implementation'
      transcript = 'synthetic-routing.jsonl'; harness = 'codex'; model = 'gpt-6-astra'; effort = 'high'
      row = '7'; placement = 'override-Todd'; worktree = $record.worktree; branch = $record.branch; head = $record.head
      policyGeneration = $record.policyGeneration; registryAuthorityDigest = $record.registryAuthorityDigest
      family = $record.family; slot = $record.slot; usedLastKnownGood = $record.usedLastKnownGood
    }
    if ($case.ContainsKey('Issue')) { $row.issue = $case.Issue }
    if ($case.ContainsKey('Extra')) { $row.unexpected = $true }
    [IO.File]::WriteAllText((Join-Path $root 'dispatch-log.jsonl'), ($row | ConvertTo-Json -Compress) + "`n")
    $reason = ''; $result = $null
    try { $result = Get-HeavyRoutingRow $record $root } catch { $reason = $_.Exception.Message }
    finally {
      # Refusal can leave the managed history iterator pending finalization.
      # Release its file handle before rewriting this private fixture ledger.
      [GC]::Collect()
      [GC]::WaitForPendingFinalizers()
    }
    $passed = $reason -ceq $case.Expected -and ($reason -or $result.Row -eq 7)
    $observed = if ($reason) { $reason } else { "ACCEPT row=$($result.Row)" }
    if ($passed) {
      Write-Output "PASS $($case.Name): $observed"
    } else {
      $failures.Add($case.Name)
      Write-Output "FAIL $($case.Name): expected='$($case.Expected)' observed='$observed'"
    }
  }
  Assert-True ($failures.Count -eq 0) "routing fixtures failed: $($failures -join '; ')"
  Write-Output "PASS heavy routing-row fixtures revision=$GuardRevision cases=$($cases.Count); no heavy reservation or command body executed"
} finally {
  $resolved = [IO.Path]::GetFullPath($root)
  Assert-True ((Split-Path -Parent $resolved) -ceq $temp -and
    (Split-Path -Leaf $resolved) -like 'heavy-routing-row-test-*') 'cleanup stays in this test-created temp root'
  if ([IO.Directory]::Exists($resolved)) { [IO.Directory]::Delete($resolved, $true) }
}
