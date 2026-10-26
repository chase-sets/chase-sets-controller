[CmdletBinding()]
param([switch]$RemoveOrderingCheck)

$ErrorActionPreference = 'Stop'
function Assert-True($Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
  (Join-Path $PSScriptRoot 'invoke-heavy-verifier.ps1'), [ref]$tokens, [ref]$errors)
Assert-True (-not $errors) 'guard source parses'
$definition = @($ast.FindAll({ param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq 'Test-PossibleOwnedChild'
}, $false))
Assert-True ($definition.Count -eq 1) 'one production descendant walk'
$source = $definition[0].Extent.Text
if ($RemoveOrderingCheck) {
  $check = 'if ($createdAt.Ticks -lt $parentCreationTicks) { continue }'
  Assert-True ($source.Contains($check)) 'ordering-check mutant target exists'
  $source = $source.Replace($check, '# ordering check removed')
}
. ([scriptblock]::Create($source))

# Function-local doubles feed the unmodified production walk, including its
# exact-identity rechecks. No live process table or clock decides these tests.
$instant = [datetime]::SpecifyKind([datetime]'2026-01-01', [DateTimeKind]::Utc)
function New-Candidate([int]$Id, [int]$Parent, [long]$Ticks) {
  [pscustomobject]@{ ProcessId=$Id; ParentProcessId=$Parent; CreationDate=$instant.AddTicks($Ticks) }
}
function Get-ProcessIdentityState { return $rootState }
function Get-CimInstance($ClassName, [string]$Filter, $ErrorAction) {
  [void]$queries.Add($Filter)
  if ($Filter -match '^ParentProcessId = (\d+)$') {
    $parentId = [int]$Matches[1]
    return @($table | Where-Object ParentProcessId -EQ $parentId)
  }
  if ($Filter -match '^ProcessId = (\d+)$') {
    $candidateId = [int]$Matches[1]
    return @($table | Where-Object ProcessId -EQ $candidateId)
  }
  throw "unexpected CIM query: $ClassName $Filter"
}
$record = [pscustomobject]@{
  pid=100; processStartUtc=$instant.AddTicks(10).ToString('o')
  childPid=200; childProcessStartUtc=$instant.AddTicks(20).ToString('o')
  startedUtc=$instant.AddTicks(100).ToString('o'); state='attached'
}
$queries = [Collections.Generic.List[string]]::new()
foreach ($rootState in @('dead', 'reused')) {
  foreach ($rootId in @(100, 200)) {
    $guardedOnly = $rootId -eq 200
    # The old child belongs to a previous incarnation of this root PID. Its
    # newer descendant must never turn it into possible owned work.
    $table = @((New-Candidate 300 $rootId 5), (New-Candidate 400 300 110))
    $queries.Clear()
    $result = Test-PossibleOwnedChild $record -GuardedRootOnly:$guardedOnly
    Assert-True ($result -ceq $false) "reused-parent $rootId ($rootState) excludes older child and newer foreign descendant (actual=$result)"
    Assert-True (-not $queries.Contains('ParentProcessId = 300')) 'older root candidate is not queued'

    # A candidate can also predate a discovered node, rather than a root.
    $table = @((New-Candidate 300 $rootId 40), (New-Candidate 400 300 30), (New-Candidate 500 400 110))
    $queries.Clear()
    Assert-True ((Test-PossibleOwnedChild $record -GuardedRootOnly:$guardedOnly) -ceq $false) 'walked-parent reuse excludes foreign subtree'
    Assert-True (-not $queries.Contains('ParentProcessId = 400')) 'older walked candidate is not queued'

    foreach ($workerTicks in @(100, 110)) {
      $table = @((New-Candidate 300 $rootId 40), (New-Candidate 400 300 70), (New-Candidate 500 400 $workerTicks))
      Assert-True ((Test-PossibleOwnedChild $record -GuardedRootOnly:$guardedOnly) -ceq $true) 'genuine older relays still lead to worker at or after startedUtc'
    }
    $table = @((New-Candidate 300 $rootId 40), (New-Candidate 400 300 70))
    $queries.Clear()
    Assert-True ((Test-PossibleOwnedChild $record -GuardedRootOnly:$guardedOnly) -ceq $false) 'genuine tree entirely before startedUtc drains'
    Assert-True ($queries.Contains('ParentProcessId = 400')) 'genuine older descendants are still walked'

    $rootTicks = if ($rootId -eq 100) { 10 } else { 20 }
    $table = @((New-Candidate 300 $rootId $rootTicks), (New-Candidate 400 300 $rootTicks), (New-Candidate 500 400 110))
    Assert-True ((Test-PossibleOwnedChild $record -GuardedRootOnly:$guardedOnly) -ceq $true) 'equal creation ticks remain eligible at roots and walked nodes'
    Write-Output "PASS descendant ordering root=$rootId state=$rootState; foreign subtrees skipped, genuine relays and tick ties retained"
  }
}
# A root identity keeps 100 ns while CIM creation is whole microseconds: a
# child in the root's own microsecond stays eligible, an earlier one does not.
$rootState = 'dead'
$record.childProcessStartUtc = $instant.AddTicks(15).ToString('o')
$table = @((New-Candidate 300 200 10), (New-Candidate 400 300 110))
Assert-True ((Test-PossibleOwnedChild $record -GuardedRootOnly) -ceq $true) 'child in the root microsecond stays eligible'
$table = @((New-Candidate 300 200 0), (New-Candidate 400 300 110))
Assert-True ((Test-PossibleOwnedChild $record -GuardedRootOnly) -ceq $false) 'child in an earlier microsecond is excluded'
# This edge predates the root but is itself newer than startedUtc: filtering
# must happen before the immediate possible-worker return as well as enqueue.
$record.childProcessStartUtc = $instant.AddTicks(120).ToString('o')
$table = @((New-Candidate 300 200 110))
Assert-True ((Test-PossibleOwnedChild $record -GuardedRootOnly) -ceq $false) 'older candidate is not returned as a possible worker'
$rootState = 'live'
Assert-True ($null -eq (Test-PossibleOwnedChild $record -GuardedRootOnly)) 'live root remains indeterminate'
Write-Output 'PASS deterministic descendant ordering controls'
