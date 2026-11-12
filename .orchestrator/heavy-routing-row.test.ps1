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
try {
. ([scriptblock]::Create((Read-Source 'dispatch-ownership.ps1')))
} catch {
  # ScriptBlock.Create has no file identity for the owner's literal import.
  # Retain the original load and repair only that specific source-load failure.
  if ($_.FullyQualifiedErrorId -cne 'ParameterArgumentValidationErrorEmptyStringNotAllowed,Microsoft.PowerShell.Commands.JoinPathCommand' -or
      $_.InvocationInfo.Line -notlike '*Import-Module (Join-Path $PSScriptRoot*') { throw }
  $ownerTokens = $null; $ownerErrors = $null
  $ownerAst = [Management.Automation.Language.Parser]::ParseInput((Read-Source 'dispatch-ownership.ps1'),
    (Join-Path $PSScriptRoot 'dispatch-ownership.ps1'), [ref]$ownerTokens, [ref]$ownerErrors)
  Assert-True ($ownerErrors.Count -eq 0) 'ownership source retains file identity'
  . $ownerAst.GetScriptBlock()
}
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput((Read-Source 'invoke-heavy-verifier.ps1'), [ref]$tokens, [ref]$errors)
Assert-True ($errors.Count -eq 0) 'guard source parses'
$definitions = @($ast.FindAll({ param($n)
  $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Get-HeavyRoutingRow'
}, $false))
Assert-True ($definitions.Count -eq 1) 'one production routing-row reader'
$observationDefinitions = @($ast.FindAll({ param($n)
  $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Assert-DispatchObservationTime'
}, $false))
Assert-True ($observationDefinitions.Count -eq 1) 'one production dispatch observation clock helper'
. ([scriptblock]::Create($observationDefinitions[0].Extent.Text))
# Retain the production file identity for its literal owner-module import.
$routingAst=[Management.Automation.Language.Parser]::ParseInput($definitions[0].Extent.Text,
  (Join-Path $PSScriptRoot 'invoke-heavy-verifier.ps1'),[ref]$tokens,[ref]$errors)
Assert-True ($errors.Count -eq 0) 'routing definition retains source identity'
. $routingAst.GetScriptBlock()

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

  # Small cardinality, real physical cliffs: only A/B (then C) are routing rows.
  # Every read below still invokes the complete AST-extracted production caller.
  $ledger = Join-Path $root 'dispatch-log.jsonl'
  $utf8 = [Text.UTF8Encoding]::new($false)
  function Get-PrivateHistoryIdentity {
    $file = Get-Item -LiteralPath $ledger
    return [pscustomobject][ordered]@{
      length = $file.Length; lastWriteUtcTicks = $file.LastWriteTimeUtc.Ticks
      sha256 = (Get-FileHash -LiteralPath $ledger -Algorithm SHA256).Hash
    }
  }
  function Assert-PrivateRoutingRead($Launch, $Expected, [string]$ExpectedReason, [string]$Phase) {
    $before = Get-PrivateHistoryIdentity | ConvertTo-Json -Compress
    $reason = ''; $actual = $null
    try { $actual = Get-HeavyRoutingRow $Launch $root } catch { $reason = $_.Exception.Message }
    finally {
      [GC]::Collect()
      [GC]::WaitForPendingFinalizers()
    }
    $after = Get-PrivateHistoryIdentity | ConvertTo-Json -Compress
    Assert-True ($before -ceq $after) "$Phase preserves hash/length/lastwrite per read"
    Assert-True ($reason -ceq $ExpectedReason) "$Phase exact reason: expected='$ExpectedReason' actual='$reason'"
    $actualJson = ConvertTo-Json -InputObject $actual -Depth 10 -Compress
    $expectedJson = ConvertTo-Json -InputObject $Expected -Depth 10 -Compress
    Assert-True ($actualJson -ceq $expectedJson) "$Phase complete Row/Raw result equals exact oracle"
    Write-Host "PASS $Phase input=$before reason='$reason' complete=$actualJson"
    return ,$actual
  }
  $launches = @(); $rawRows = @(); $oracles = @()
  for ($index = 0; $index -lt 3; $index++) {
    $name = 'synthetic-history-' + @('A','B','C')[$index]
    $launchInstant = $instant.AddMinutes($index + 1)
    $launch = [pscustomobject]@{
      launcherStartIdentity = $launchInstant.AddSeconds(-2).ToString('o')
      recordedAt = $launchInstant.AddSeconds(-1).ToString('o')
      childStartIdentity = $launchInstant.ToString('o')
      label = $name; lane = $name; worktree = $root
      transcriptPath = (Join-Path $root "$name.jsonl")
      branch = 'synthetic/routing'; head = ('a' * 40)
      policyGeneration = 1; registryAuthorityDigest = 'synthetic-digest'
      family = 'astra'; slot = 'explicit'; usedLastKnownGood = $false
    }
    $routingRow = [ordered]@{
      ts = $launchInstant.AddMilliseconds(-1500).ToString('o')
      kind = 'dispatch'; dispatchRoutingSchema = 'watchdog-dispatch-routing/v2'
      attemptId = $name; label = $name; lane = $name; laneRole = 'implementation'
      transcript = "$name.jsonl"; harness = 'codex'; model = 'gpt-6-astra'; effort = 'high'
      row = [string](7 + $index); placement = 'override-Todd'
      worktree = $launch.worktree; branch = $launch.branch; head = $launch.head
      policyGeneration = $launch.policyGeneration; registryAuthorityDigest = $launch.registryAuthorityDigest
      family = $launch.family; slot = $launch.slot; usedLastKnownGood = $launch.usedLastKnownGood
    }
    $raw = $routingRow | ConvertTo-Json -Compress
    $launches += $launch; $rawRows += $raw
    $oracles += [pscustomobject]@{ Row = (7 + $index); Raw = $raw }
  }
  [IO.File]::WriteAllText($ledger, ($rawRows[0..1] -join "`n") + "`n", $utf8)
  $smallResults = @()
  for ($index = 0; $index -lt 2; $index++) {
    $smallResults += Assert-PrivateRoutingRead $launches[$index] $oracles[$index] '' "small-$index"
  }
  $writer = [IO.StreamWriter]::new($ledger, $false, $utf8)
  try {
    $writer.NewLine = "`n"
    $writer.WriteLine($rawRows[0])
    $padding = ' ' * 672
    for ($line = 0; $line -lt 51000; $line++) { $writer.WriteLine($padding) }
    $writer.WriteLine($rawRows[1])
  } finally { $writer.Dispose() }
  $fullBytes = [IO.File]::ReadAllBytes($ledger)
  $physicalLines = 0
  foreach ($line in [IO.File]::ReadLines($ledger)) { $physicalLines++ }
  Assert-True ($physicalLines -gt 50000 -and $fullBytes.Length -gt 32MB -and
    $fullBytes[-1] -eq 10) 'private history exceeds both physical LF and byte cliffs'
  $originalIdentity = Get-PrivateHistoryIdentity
  Write-Output "PASS abovecliff physicalLF=$physicalLines bytes=$($fullBytes.Length) routingRows=2 identity=$($originalIdentity | ConvertTo-Json -Compress)"
  $fullResults = @()
  for ($index = 0; $index -lt 2; $index++) {
    $fullResults += Assert-PrivateRoutingRead $launches[$index] $smallResults[$index] '' "full-$index"
  }
  # Slice the actual full fixture, not a model of either former bound.
  $suffixStart = 0
  for ($line = 0; $line -lt $physicalLines - 50000; $line++) {
    $suffixStart = [Array]::IndexOf($fullBytes, [byte]10, $suffixStart) + 1
  }
  $suffixBytes = [byte[]]::new($fullBytes.Length - $suffixStart)
  [Array]::Copy($fullBytes, $suffixStart, $suffixBytes, 0, $suffixBytes.Length)
  $prefixLength = [Array]::LastIndexOf($fullBytes, [byte]10, (32MB - 1), 32MB) + 1
  Assert-True ($prefixLength -gt 0 -and $prefixLength -le 32MB -and
    [Array]::IndexOf($fullBytes, [byte]10, $prefixLength) + 1 -gt 32MB) '32MiB prefix is maximal and line-complete'
  $prefixBytes = [byte[]]::new($prefixLength)
  [Array]::Copy($fullBytes, $prefixBytes, $prefixLength)
  try {
    [IO.File]::WriteAllBytes($ledger, $suffixBytes)
    $suffixLines = 0
    foreach ($line in [IO.File]::ReadLines($ledger)) { $suffixLines++ }
    Assert-True ($suffixLines -eq 50000) 'actual suffix contains exactly last 50000 LF rows'
    $null = Assert-PrivateRoutingRead $launches[0] $null $missing 'suffix-loses-A'
    $null = Assert-PrivateRoutingRead $launches[1] $fullResults[1] '' 'suffix-retains-B'
    [IO.File]::WriteAllBytes($ledger, $prefixBytes)
    $null = Assert-PrivateRoutingRead $launches[0] $fullResults[0] '' 'prefix-retains-A'
    $null = Assert-PrivateRoutingRead $launches[1] $null $missing 'prefix-loses-B'
    Write-Output "PASS actual controls suffixLF=$suffixLines suffixBytes=$($suffixBytes.Length) maximalPrefixBytes=$prefixLength missing='$missing'"
  } finally {
    [IO.File]::WriteAllBytes($ledger, $fullBytes)
    [IO.File]::SetLastWriteTimeUtc($ledger, [datetime]::new($originalIdentity.lastWriteUtcTicks, [DateTimeKind]::Utc))
  }
  Assert-True (($originalIdentity | ConvertTo-Json -Compress) -ceq
    (Get-PrivateHistoryIdentity | ConvertTo-Json -Compress)) 'full original hash/length/lastwrite restored after controls'
  for ($index = 0; $index -lt 2; $index++) {
    $null = Assert-PrivateRoutingRead $launches[$index] $fullResults[$index] '' "restored-$index"
  }
  [IO.File]::WriteAllText($ledger, ($rawRows -join "`n") + "`n", $utf8)
  $smallAppended = @()
  for ($index = 0; $index -lt 3; $index++) {
    $smallAppended += Assert-PrivateRoutingRead $launches[$index] $oracles[$index] '' "small-appended-$index"
  }
  [IO.File]::WriteAllBytes($ledger, $fullBytes)
  [IO.File]::AppendAllText($ledger, $rawRows[2] + "`n", $utf8)
  $appendedResults = @()
  for ($index = 0; $index -lt 3; $index++) {
    $appendedResults += Assert-PrivateRoutingRead $launches[$index] $smallAppended[$index] '' "full-appended-$index"
  }
  for ($index = 0; $index -lt 3; $index++) {
    $null = Assert-PrivateRoutingRead $launches[$index] $appendedResults[$index] '' "replay-$index"
  }
  Write-Output 'PASS bounded ordinary routing history: whole Row/Raw small/full A/B/C, actual suffix/prefix, restoration, append and deterministic replay; no heavy execution'
} finally {
  $resolved = [IO.Path]::GetFullPath($root)
  Assert-True ((Split-Path -Parent $resolved) -ceq $temp -and
    (Split-Path -Leaf $resolved) -like 'heavy-routing-row-test-*') 'cleanup stays in this test-created temp root'
  if ([IO.Directory]::Exists($resolved)) { [IO.Directory]::Delete($resolved, $true) }
}
