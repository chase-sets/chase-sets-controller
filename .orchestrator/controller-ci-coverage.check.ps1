param(
  [string]$BaselineHead='321915d57da6fbaf647a30080c90601470c2b2cb',
  [string]$EvidenceDirectory=(Join-Path ([IO.Path]::GetTempPath()) 'controller-ci-coverage-proof'),
  # Optional AC2/AC1 log evidence: 'identity#part=log path' entries, or a hosted
  # result directory whose shard receipts name the part logs.
  [string[]]$PartLogs=@(),
  [string]$PartResultDirectory='',
  [string]$RoutingWholeLog=(Join-Path $PSScriptRoot '../../.orchestrator/logs/controller-8661-hosted-gate-g1.evidence/H-result/controller-shard-8/002.log'),
  [string]$CleanupWholeLog=(Join-Path $PSScriptRoot '../../.orchestrator/logs/controller-8661-hosted-gate-g1.evidence/H-result/controller-shard-7/005.log')
)
$ErrorActionPreference='Stop'
[Diagnostics.Process]::GetCurrentProcess().PriorityClass='BelowNormal'
. (Join-Path $PSScriptRoot 'controller-ci.ps1') -Mode Library
. (Join-Path $PSScriptRoot 'landed-integration-test-parts.ps1')
. (Join-Path $PSScriptRoot 'suite-parts.ps1')
$root=Split-Path -Parent $PSScriptRoot
[void][IO.Directory]::CreateDirectory($EvidenceDirectory)
# Immutable pre-split oracles. Units are enumerated from these blobs, never
# from the changed suites, part map or manifest under test.
$BaselineBlobs=@{
  '.orchestrator/dispatch-routing-data.test.ps1'='b8d4d80433cf7b9d4b65068930c3fd452444b8dd'
  '.orchestrator/cleanup-orphan-worktree-dirs.test.ps1'='8610bd4d8a27d269b6f0433db12404ae59403b97'
  '.orchestrator/board-hourly-scale.test.ps1'='4eedaa85619279fa8b30595045acf95a6137e802'
}
function Read-Baseline([string]$Path) {
  if ($BaselineBlobs.ContainsKey($Path)) {
    $tree=(@(& git -C $root rev-parse "${BaselineHead}:$Path") -join '').Trim()
    Assert-Ci ($LASTEXITCODE -eq 0 -and $tree -ceq $BaselineBlobs[$Path]) "baseline blob moved: $Path"
    $lines=@(& git -C $root cat-file -p $BaselineBlobs[$Path])
  } else { $lines=@(& git -C $root show "${BaselineHead}:$Path") }
  Assert-Ci ($LASTEXITCODE -eq 0) "baseline source unavailable: $Path"
  return ($lines -join "`n")+"`n"
}
function Read-Current([string]$Path) { return [IO.File]::ReadAllText((Join-Path $root $Path)).Replace("`r`n","`n") }
function Parse-Source([string]$Source) {
  $tokens=$null;$errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseInput($Source,[ref]$tokens,[ref]$errors)
  Assert-Ci (@($errors).Count -eq 0) 'coverage source parser error'
  return $ast
}
function Get-AssertionText([string]$Source) {
  return @( (Parse-Source $Source).FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -like 'Assert-*'},$true) | ForEach-Object {$_.Extent.Text})
}
function Copy-Owners($Owners) { $copy=[ordered]@{}; foreach ($key in $Owners.Keys) { $copy[$key]=@($Owners[$key]) }; return $copy }
function Get-ManifestParts($Manifest, [string]$Identity) {
  $entry=@($Manifest.items | Where-Object identity -CEQ $Identity)
  Assert-Ci ($entry.Count -eq 1 -and $entry[0].selector -ceq '-Part') "manifest entry: $Identity"
  return @($entry[0].parts.name)
}
function Get-PartDeclaration($Owners) { return ",`n  [ValidateSet('all',$((@($Owners.Keys) | ForEach-Object { "'$_'" }) -join ','))][string]`$Part='all'" }
# The only plumbing a split may add: the -Part declaration, exact fixed lines,
# and region gates whose single variable is a [a-z-] key literal.
function Restore-SuiteSource([string]$Source, [string]$Suite, [string]$Declaration, [string[]]$FixedLines) {
  Assert-Ci (([regex]::Matches($Source,[regex]::Escape($Declaration))).Count -eq 1) "$Suite -Part declaration differs from its part map"
  $text=$Source.Replace($Declaration,'')
  $gate='^\s*(?:if\(Test-SuitePart ''(?<suite>[a-z-]+)'' \$Part ''[a-z][a-z:-]*''\)\{ # PART-BEGIN|\} # PART-END)$'
  $lines=$text.Split("`n")
  foreach ($fixed in $FixedLines) { Assert-Ci (@($lines | Where-Object { $_ -ceq $fixed }).Count -eq 1) "$Suite plumbing line not exactly once: $fixed" }
  $kept=foreach ($line in $lines) {
    if ($line -cin $FixedLines) { continue }
    $match=[regex]::Match($line,$gate)
    if ($match.Success) { Assert-Ci (-not $match.Groups['suite'].Success -or $match.Groups['suite'].Value -ceq $Suite) 'foreign suite gate'; continue }
    $line
  }
  return ($kept -join "`n")
}
function Get-GateKey($Node, [string]$Suite) {
  if ($Node -isnot [Management.Automation.Language.IfStatementAst] -or $Node.Clauses.Count -ne 1 -or $null -ne $Node.ElseClause) { return $null }
  $match=[regex]::Match($Node.Clauses[0].Item1.Extent.Text,"^Test-SuitePart '$Suite' \`$Part '([a-z][a-z:-]*)'$")
  if ($match.Success) { return $match.Groups[1].Value }
  return $null
}
function Get-Gates($Ast, [string]$Suite) {
  $gates=@($Ast.FindAll({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -clike 'Test-SuitePart *'},$true))
  foreach ($gate in $gates) {
    Assert-Ci ($null -ne (Get-GateKey $gate $Suite)) "malformed $Suite gate: $($gate.Clauses[0].Item1.Extent.Text)"
    for ($p=$gate.Parent; $null -ne $p; $p=$p.Parent) { Assert-Ci ($null -eq (Get-GateKey $p $Suite)) "nested $Suite gate" }
  }
  return ,$gates
}
function Get-EnclosingGate($Node, [string]$Suite) {
  for ($p=$Node.Parent; $null -ne $p; $p=$p.Parent) { $key=Get-GateKey $p $Suite; if ($key) { return $key } }
  return $null
}
function Assert-PartMap($Owners, [string[]]$ExpectedKeys, [string[]]$ManifestParts, [string]$Suite) {
  $keys=@($Owners.Values | ForEach-Object { $_ })
  Assert-Ci (@($keys | Select-Object -Unique).Count -eq $keys.Count) "$Suite unit assigned to more than one part"
  foreach ($key in $keys) { Assert-Ci ($key -cin $ExpectedKeys) "$Suite part map names an unknown or misassigned unit: $key" }
  foreach ($key in $ExpectedKeys) { Assert-Ci ($key -cin $keys) "$Suite unit has no part: $key" }
  foreach ($part in $Owners.Keys) {
    Assert-Ci ($part -cmatch '^[a-z][a-z-]*$') "$Suite part name: $part"
    Assert-Ci (@($Owners[$part]).Count -gt 0) "$Suite part owns nothing: $part"
  }
  Assert-Ci ((@($ManifestParts) -join ',') -ceq (@($Owners.Keys) -join ',') -and @($ManifestParts | Select-Object -Unique).Count -eq @($ManifestParts).Count) "$Suite manifest parts differ from its part map"
}

$RoutingSuite='dispatch-routing-data'
$RoutingFixed=@(". (Join-Path `$PSScriptRoot 'suite-parts.ps1')",
  'Confirm-SuitePartSelection ''dispatch-routing-data'' $Part ($Case -cne ''all'' -or [bool]$CapacityMutantsOnly)',
  '  if(-not(Test-SuitePart ''dispatch-routing-data'' $Part "case:$Name")){return} # PART-FILTER',
  '      if(-not(Test-SuitePart ''dispatch-routing-data'' $Part "capacity-mutant:$($m.name)")){continue} # PART-FILTER')
function Get-HashtableNames($Ast, [string]$Variable) {
  $assignments=@($Ast.FindAll({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq $Variable},$true))
  return @($assignments | ForEach-Object { $_.Right.FindAll({param($n) $n -is [Management.Automation.Language.HashtableAst]},$true) } | ForEach-Object {
    $pair=@($_.KeyValuePairs | Where-Object { $_.Item1.Extent.Text -ceq 'name' })
    if ($pair.Count -eq 1) { $pair[0].Item2.Extent.Text.Trim("'") } })
}
function Get-RoutingCoverage([string]$Source, [string]$Baseline, $Owners, [string[]]$ManifestParts) {
  $restored=Restore-SuiteSource $Source $RoutingSuite (Get-PartDeclaration $Owners) $RoutingFixed
  Assert-Ci ($restored -ceq $Baseline) 'routing split changed non-plumbing source'
  $base=Parse-Source $Baseline
  $casesAst=@($base.FindAll({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$cases'},$true))
  Assert-Ci ($casesAst.Count -eq 1) 'routing case inventory'
  $cases=@($casesAst[0].Right.FindAll({param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst]},$true) | ForEach-Object Value)
  $routingMutants=Get-HashtableNames $base '$mutants'
  $capacityMutants=Get-HashtableNames $base '$capacityMutants'
  Assert-Ci ($cases.Count -eq 15 -and $routingMutants.Count -eq 8 -and $capacityMutants.Count -eq 24) "routing unit inventory changed cases=$($cases.Count) routing=$($routingMutants.Count) capacity=$($capacityMutants.Count)"
  $expected=@($cases | ForEach-Object { "case:$_" })+@('routing-mutants')+@($capacityMutants | ForEach-Object { "capacity-mutant:$_" })
  Assert-PartMap $Owners $expected $ManifestParts $RoutingSuite
  $ast=Parse-Source $Source
  [void](Get-Gates $ast $RoutingSuite)
  $invoke=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Invoke-Case'},$true))
  Assert-Ci ($invoke.Count -eq 1 -and $invoke[0].Body.EndBlock.Statements[0].Extent.Text -ceq $RoutingFixed[2].Trim().Replace(' # PART-FILTER','')) 'case filter is not the first Invoke-Case statement'
  $loops=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.ForEachStatementAst]},$true))
  $caseLoop=@($loops | Where-Object { $_.Condition.Extent.Text -ceq '$cases' })
  $routingLoop=@($loops | Where-Object { $_.Condition.Extent.Text -ceq '$mutants' })
  $capacityLoop=@($loops | Where-Object { $_.Condition.Extent.Text -ceq '$capacityMutants' })
  Assert-Ci ($caseLoop.Count -eq 1 -and $routingLoop.Count -eq 1 -and $capacityLoop.Count -eq 1) 'routing loop inventory'
  Assert-Ci ($null -eq (Get-EnclosingGate $caseLoop[0] $RoutingSuite)) 'case loop gated; its per-case filter owns selection'
  Assert-Ci ((Get-EnclosingGate $routingLoop[0] $RoutingSuite) -ceq 'routing-mutants') 'routing mutant block is not gated by its routing-mutants key'
  Assert-Ci (@($routingLoop[0].Body.FindAll({param($n) $n.Extent.Text -clike '*Test-SuitePart*'},$true)).Count -eq 0) 'routing mutant loop carries a part filter'
  Assert-Ci ($null -eq (Get-EnclosingGate $capacityLoop[0] $RoutingSuite)) 'capacity mutant loop gated; its per-mutant filter owns selection'
  Assert-Ci ($capacityLoop[0].Body.Statements[0].Extent.Text -ceq $RoutingFixed[3].Trim().Replace(' # PART-FILTER','')) 'capacity filter is not the first capacity mutant statement'
  $table=[ordered]@{}
  foreach ($part in $Owners.Keys) {
    $owned=@($Owners[$part])
    $table[$part]=[ordered]@{cases=@($owned | Where-Object { $_ -clike 'case:*' } | ForEach-Object { $_.Substring(5) })
      routingMutants=$(if ('routing-mutants' -cin $owned) { $routingMutants } else { @() })
      capacityMutants=@($owned | Where-Object { $_ -clike 'capacity-mutant:*' } | ForEach-Object { $_.Substring(16) })}
  }
  return [ordered]@{cases=$cases.Count;routingMutants=$routingMutants.Count;capacityMutants=$capacityMutants.Count
    assertions=@(Get-AssertionText $Baseline).Count;parts=$table}
}

$CleanupSuite='cleanup-orphan-worktree-dirs'
$CleanupFixed=@(". (Join-Path `$PSScriptRoot 'suite-parts.ps1')",'Confirm-SuitePartSelection ''cleanup-orphan-worktree-dirs'' $Part $false')
$ScaleAnchors=@('$scaleRoot=Join-Path $root ''scale''','scale fixture construction exceeded 12 minute safety bound','$wall=Measure-Command {$script:scaleResult=',
  'reclamation-scale-bound 200 x 2000 report under 60 seconds','scale exercises cheap refusal and native early exit','AC6 synthetic dry-run total under 300000 ms','PASS reclamation-scale-bound trees=200')
function Test-Inert($Statement) {
  return @($Statement.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and ($n.GetCommandName() -like 'Assert-*' -or $n.GetCommandName() -ceq 'Write-Output')},$true)).Count -eq 0
}
function Get-CleanupCoverage([string]$Source, [string]$Baseline, $Owners, [string[]]$ManifestParts) {
  $restored=Restore-SuiteSource $Source $CleanupSuite (Get-PartDeclaration $Owners) $CleanupFixed
  Assert-Ci ($restored -ceq $Baseline) 'cleanup split changed non-plumbing source'
  $ast=Parse-Source $Source
  $gates=Get-Gates $ast $CleanupSuite
  $try=@($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })
  Assert-Ci ($try.Count -eq 1) 'cleanup try inventory'
  $top=@($try[0].Body.Statements)
  Assert-Ci (@($gates | Where-Object { $_.Parent -ne $try[0].Body }).Count -eq 0) 'cleanup gate is not a top-level try statement'
  $units=[Collections.Generic.List[object]]::new();$flat=[Collections.Generic.List[string]]::new()
  foreach ($statement in $top) {
    $key=Get-GateKey $statement $CleanupSuite
    if ($null -eq $key) {
      Assert-Ci (Test-Inert $statement) "ungated cleanup statement asserts or reports: $($statement.Extent.StartLineNumber)"
      $flat.Add($statement.Extent.Text); continue
    }
    $owner=@($Owners.Keys | Where-Object { $key -cin @($Owners[$_]) })
    Assert-Ci ($owner.Count -eq 1) "cleanup region $key has $($owner.Count) owning parts"
    foreach ($inner in $statement.Clauses[0].Item2.Statements) { $units.Add([pscustomobject]@{part=$owner[0];statement=$inner}); $flat.Add($inner.Extent.Text) }
  }
  $expected=@($gates | ForEach-Object { Get-GateKey $_ $CleanupSuite } | Select-Object -Unique)
  Assert-PartMap $Owners $expected $ManifestParts $CleanupSuite
  # One-to-one: the flattened top-level sequence is exactly B's, so every
  # original asserting statement sits in exactly one single-owner region.
  $baseTry=@((Parse-Source $Baseline).EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })[0]
  Assert-Ci (($flat -join "`n`u{1}`n") -ceq (@($baseTry.Body.Statements.Extent.Text) -join "`n`u{1}`n")) 'cleanup top-level statements differ from baseline'
  $asserting=@($baseTry.Body.Statements | Where-Object { -not (Test-Inert $_) })
  Assert-Ci ($asserting.Count -le $units.Count) 'cleanup asserting statements lost'
  $scaleParts=@(foreach ($anchor in $ScaleAnchors) {
    $hits=@($units | Where-Object { $_.statement.Extent.Text.Contains($anchor) })
    Assert-Ci ($hits.Count -eq 1) "scale anchor not exactly once: $anchor"
    $hits[0].part })
  Assert-Ci (@($scaleParts | Select-Object -Unique).Count -eq 1) 'scale fixture, bounds and AC6 assertions split across parts'
  $mutants=@(foreach ($unit in $units) {
    foreach ($loop in $unit.statement.FindAll({param($n) $n -is [Management.Automation.Language.ForEachStatementAst] -and $n.Variable.VariablePath.UserPath -ceq 'mutant'},$true)) {
      Get-HashtableNames (Parse-Source "`$m=$($loop.Condition.Extent.Text)") '$m' } })
  Assert-Ci ($mutants.Count -eq 6 -and @($mutants | Select-Object -Unique).Count -eq 6) "cleanup mutant inventory changed: $($mutants -join ',')"
  $table=[ordered]@{}
  foreach ($part in $Owners.Keys) {
    $mine=@($units | Where-Object part -CEQ $part)
    $text=($mine.statement.Extent.Text -join "`n")
    $table[$part]=[ordered]@{statements=$mine.Count;firstLine=$(if ($mine.Count) { $mine[0].statement.Extent.StartLineNumber } else { 0 })
      assertions=@($mine | ForEach-Object { $_.statement.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -like 'Assert-*'},$true) }).Count
      mutants=@($mutants | Where-Object { $text.Contains("name='$_'") })
      baselineEquivalence=$text.Contains('baseline removable-set equivalence');nativeCases=$text.Contains("foreach(`$repositoryKind in @('product','container-meta'))")
      scale=($part -ceq $scaleParts[0])}
  }
  Assert-Ci (@($table.Values | Where-Object baselineEquivalence).Count -eq 1 -and @($table.Values | Where-Object nativeCases).Count -eq 1) 'baseline-equivalence or native cases not in exactly one part'
  $placed=(@($table.Values | ForEach-Object { $_.mutants }) | Sort-Object) -join ','
  Assert-Ci ($placed -ceq (($mutants | Sort-Object) -join ',')) 'cleanup mutants not each in exactly one part'
  return [ordered]@{topLevelStatements=$top.Count;assertingStatements=$asserting.Count;assertions=@(Get-AssertionText $Baseline).Count
    mutants=$mutants;scalePart=$scaleParts[0];parts=$table}
}

# Board and landed splits retained from #8661 H'.
$boardBaseline=Read-Baseline '.orchestrator/board-hourly-scale.test.ps1'
$board=Read-Current '.orchestrator/board-hourly-scale-part.ps1'
$boardSupport=@{}
foreach ($path in @('.orchestrator/board-scale-test-support.ps1','.orchestrator/routing-data-test-support.ps1')) {
  $boardSupport[$path]=Read-Baseline $path
  Assert-Ci ((Read-Current $path) -ceq $boardSupport[$path]) "full fixture/assertion support changed: $path"
}
$wrapper=Read-Current '.orchestrator/board-hourly-scale.test.ps1'
Assert-Ci ($wrapper.Contains("& (Join-Path `$PSScriptRoot 'board-hourly-scale-part.ps1') -Arm `$Arm")) 'legacy board entry does not forward its exact selector'
$manifest=Get-Content (Join-Path $PSScriptRoot 'controller-ci-parts.json') -Raw | ConvertFrom-Json
function Get-BoardTrace([string]$Source,[string]$Arm) {
  # Replace only the two support imports with synthetic call recorders. Run the
  # unchanged orchestration, not the scale fixture or any timing assertion.
  $ast=Parse-Source $Source
  $imports=@($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.PipelineAst] -and $_.PipelineElements[0] -is [Management.Automation.Language.CommandAst] -and $_.PipelineElements[0].InvocationOperator -eq 'Dot' })
  Assert-Ci ($imports.Count -eq 2) 'board import seam changed'
  foreach ($import in $imports) { $Source=$Source.Replace($import.Extent.Text,'') }
  $script:trace=[Collections.Generic.List[string]]::new()
  function Enter-RoutingDataTestScope { return 0 }
  function Exit-RoutingDataTestScope($Scope) {}
  function Remove-BoardScaleFixture($Root) {}
  function New-BoardScaleFixture($Path,$ItemCount) { return @{items=$ItemCount;name=(Split-Path -Leaf $Path);log=(Join-Path $Path 'dispatch.jsonl')} }
  function Invoke-BoardScaleArm($Fixture,$Name) { $script:trace.Add("$($Fixture.name)|$($Fixture.items)|$Name") }
  function Measure-BoardReference($Path) { $script:trace.Add("warmup|$(Split-Path -Leaf (Split-Path -Parent $Path))"); return 0.0 }
  & ([scriptblock]::Create($Source)) -Arm $Arm | Out-Null
  return ,@($script:trace)
}
# AC3 precondition: standalone non-candidate parts take their asserted before
# after one discarded in-process reference on their own fixture; candidate
# stays cold; -Arm all, the support file and every formula are B's.
$BoardWarmup='    if ($Arm -ne ''all'' -and $name -ne ''candidate'') { $warm = Measure-BoardReference $f.log; Write-Output "WARMUP standalone board arm=$name discarded reference seconds=$warm" }'
function Get-BoardCoverage([string]$PartSource, [string]$Baseline, [string[]]$Parts, [string]$Warmup=$BoardWarmup) {
  Assert-Ci (@($PartSource.Split("`n") | Where-Object { $_ -ceq $Warmup }).Count -eq 1) 'board warm-up line not exactly once'
  Assert-Ci ($PartSource.Replace($Warmup+"`n",'') -ceq $Baseline) 'board orchestration changed beyond the standalone warm-up'
  $calls=Get-BoardTrace $Baseline 'all'
  Assert-Ci ($calls.Count -eq 7) 'board case inventory changed'
  Assert-Ci (((Get-BoardTrace $PartSource 'all') -join ',') -ceq ($calls -join ',')) 'board -Arm all call trace changed'
  $union=[Collections.Generic.List[string]]::new();$warm=[ordered]@{}
  foreach ($part in $Parts) {
    $trace=Get-BoardTrace $PartSource $part
    $warmups=@($trace | Where-Object { $_ -clike 'warmup|*' })
    if ($part -ceq 'candidate') { Assert-Ci ($warmups.Count -eq 0) 'cold candidate part warmed' }
    else { Assert-Ci ($warmups.Count -eq 1 -and $trace[0] -ceq "warmup|$part" -and $trace[1] -clike "$part|*") "standalone $part reference not warmed once on its own fixture before its arm" }
    $warm[$part]=$warmups.Count
    foreach ($entry in $trace) { if ($entry -cnotlike 'warmup|*') { $union.Add($entry) } }
  }
  Assert-Ci (($union -join ',') -ceq ($calls -join ',')) 'board union changed arm calls, full 2400-item tiers, inert reuse, or ten-item controls'
  return [ordered]@{calls=$calls;warmups=$warm}
}
$boardParts=@(@($manifest.items | Where-Object identity -CEQ 'test:board-hourly-scale.test.ps1')[0].parts.name)
$boardCoverage=Get-BoardCoverage $board $boardBaseline $boardParts
$expected=$boardCoverage.calls
Write-Output ("BOARD_WARMUP " + (@($boardCoverage.warmups.Keys | ForEach-Object { "$_=$($boardCoverage.warmups[$_])" }) -join ' '))

$landedBaseline=Read-Baseline '.orchestrator/landed-integration-dispatch.test.ps1'
$landed=Read-Current '.orchestrator/landed-integration-dispatch.test.ps1'
$originalAssertions=Get-AssertionText $landedBaseline
$newAssertions=Get-AssertionText $landed
Assert-Ci (($originalAssertions -join "`n") -ceq ($newAssertions -join "`n")) 'landed assertion bodies/order changed'
# Remove only the reviewed partition plumbing. Exact whole-source equality
# proves fixture sizes, loops, mutants, deadlines and all original statements survive.
$restored=$landed.Replace((Parse-Source $landed).ParamBlock.Extent.Text,(Parse-Source $landedBaseline).ParamBlock.Extent.Text)
foreach ($line in @(
  "[Diagnostics.Process]::GetCurrentProcess().PriorityClass='BelowNormal'",
  ". (Join-Path `$PSScriptRoot 'landed-integration-test-parts.ps1')",
  '`$partSelection=Get-LandedIntegrationPartSelection `$Part ([bool]`$AuthorityOnly) ([bool]`$OwnershipOnly) ([bool]`$ProductCensusOnly)'.Replace('`','')
)) { $restored=$restored.Replace($line+"`n",'') }
$restored=$restored.Replace('if ($partSelection.productCensus) {','if ($ProductCensusOnly -or (-not $AuthorityOnly -and -not $OwnershipOnly)) {')
$restored=$restored.Replace("if (`$ProductCensusOnly -or `$Part -ceq 'product-census') { return }",'if ($ProductCensusOnly) { return }')
$restored=$restored.Replace('  if($partSelection.authority){','  if(-not$OwnershipOnly){')
$restored=$restored.Replace("  if(`$AuthorityOnly){return}`n  }`n  if(`$Part -ceq 'authority'){return}`n  if(`$partSelection.dispatch){","  if(`$AuthorityOnly){return}")
$restored=$restored.Replace('  if($partSelection.collector){','  if(-not$OwnershipOnly){')
$restored=$restored.Replace("  if(`$partSelection.ownership){`n",'')
$restored=$restored.Replace("  }`n  Assert-SyntheticIntegrationWitnesses `$root","  Assert-SyntheticIntegrationWitnesses `$root")
Assert-Ci ($restored -ceq $landedBaseline) 'landed split changed non-plumbing source'
$landedParts=@($manifest.items | Where-Object identity -CEQ 'test:landed-integration-dispatch.test.ps1')[0].parts
$selections=@($landedParts | ForEach-Object { Get-LandedIntegrationPartSelection $_.name $false $false $false })
foreach ($region in @('productCensus','authority','dispatch','collector','ownership')) {
  Assert-Ci (@($selections | Where-Object { $_.$region }).Count -eq 1) "landed region lost or duplicated: $region"
  Assert-Ci ((Get-LandedIntegrationPartSelection 'all' $false $false $false).$region) "legacy full entry lost region: $region"
}
$refused=$false;try { Get-LandedIntegrationPartSelection 'ownership' $true $false $false | Out-Null } catch { $refused=$true }
Assert-Ci $refused 'ambiguous part/legacy selector accepted'
Write-Output "PASS split union: board calls=$($expected.Count) full fixture/support unchanged; landed assertions=$($originalAssertions.Count) original source preserved, five disjoint regions"

# #9272 routing and cleanup partitions against blobs b8d4d804 and 8610bd4d.
$routingBaseline=Read-Baseline '.orchestrator/dispatch-routing-data.test.ps1'
$routingSource=Read-Current '.orchestrator/dispatch-routing-data.test.ps1'
$routingOwners=Copy-Owners $SuitePartOwners[$RoutingSuite]
$routingManifest=Get-ManifestParts $manifest 'test:dispatch-routing-data.test.ps1'
$routing=Get-RoutingCoverage $routingSource $routingBaseline $routingOwners $routingManifest
foreach ($part in @($routing.parts.Keys)) {
  $p=$routing.parts[$part]
  Write-Output ("ROUTING_PART {0} cases={1} routingMutants={2} capacityMutants={3}" -f $part,($p.cases -join '|'),($p.routingMutants -join '|'),($p.capacityMutants -join '|'))
}
# Runtime selector contract of the helper the suites dot-source.
foreach ($key in @($routingOwners.Values | ForEach-Object { $_ })) {
  Assert-Ci (Test-SuitePart $RoutingSuite 'all' $key) "default all does not run $key"
  Assert-Ci (@($routingOwners.Keys | Where-Object { Test-SuitePart $RoutingSuite $_ $key }).Count -eq 1) "named parts do not run $key exactly once"
}
foreach ($legacy in @(@{case='policy';only=$false},@{case='all';only=$true})) {
  $refused=$false;try { Confirm-SuitePartSelection $RoutingSuite 'cases-core' ($legacy.case -cne 'all' -or $legacy.only) } catch { $refused=$true }
  Assert-Ci $refused "named routing part combined with legacy selector accepted: -Case $($legacy.case) -CapacityMutantsOnly:$($legacy.only)"
}
Confirm-SuitePartSelection $RoutingSuite 'all' $true
Write-Output "PASS routing partition: cases=$($routing.cases) routing-mutants=$($routing.routingMutants) capacity-mutants=$($routing.capacityMutants) assertions=$($routing.assertions) each in exactly one of $($routing.parts.Count) parts; default/-Case/-CapacityMutantsOnly source byte-equal to b8d4d804"

$cleanupBaseline=Read-Baseline '.orchestrator/cleanup-orphan-worktree-dirs.test.ps1'
$cleanupSource=Read-Current '.orchestrator/cleanup-orphan-worktree-dirs.test.ps1'
$cleanupOwners=Copy-Owners $SuitePartOwners[$CleanupSuite]
$cleanupManifest=Get-ManifestParts $manifest 'test:cleanup-orphan-worktree-dirs.test.ps1'
$cleanup=Get-CleanupCoverage $cleanupSource $cleanupBaseline $cleanupOwners $cleanupManifest
foreach ($part in @($cleanup.parts.Keys)) {
  $p=$cleanup.parts[$part]
  Write-Output ("CLEANUP_PART {0} statements={1} assertions={2} mutants={3} baselineEquivalence={4} native={5} scale={6}" -f $part,$p.statements,$p.assertions,($p.mutants -join '|'),$p.baselineEquivalence,$p.nativeCases,$p.scale)
}
Write-Output "PASS cleanup partition: asserting statements=$($cleanup.assertingStatements) assertions=$($cleanup.assertions) mutants=$($cleanup.mutants.Count) each in exactly one of $($cleanup.parts.Count) parts; whole 200x2000 fixture, 12-minute, <60 s and 300000 ms bounds in part $($cleanup.scalePart); source byte-equal to 8610bd4d"

# Named controls: each one-variable corruption must be refused for its reason.
function Refuses([scriptblock]$Body, [string]$Expected) {
  $message=$null;try { & $Body | Out-Null } catch { $message=$_.Exception.Message }
  Assert-Ci ($null -ne $message) "coverage control accepted: $Expected"
  Assert-Ci ($message.Contains($Expected)) "coverage control refused for another reason ($Expected): $message"
}
$RoutingGate="  if(Test-SuitePart 'dispatch-routing-data' `$Part 'routing-mutants'){ # PART-BEGIN`n"
$controls=[ordered]@{
  'routing-drop-capacity-mutant'=@{expected='unit has no part: capacity-mutant:override-omission';body={
    $o=Copy-Owners $routingOwners;$o['capacity-mutants-flip']=@($o['capacity-mutants-flip'] | Where-Object { $_ -cne 'capacity-mutant:override-omission' })
    Get-RoutingCoverage $routingSource $routingBaseline $o $routingManifest }}
  'routing-duplicate-capacity-mutant'=@{expected='unit assigned to more than one part';body={
    $o=Copy-Owners $routingOwners;$o['capacity-mutants-history']+=@('capacity-mutant:override-omission')
    Get-RoutingCoverage $routingSource $routingBaseline $o $routingManifest }}
  'routing-misassigned-mutant-as-case'=@{expected='unknown or misassigned unit: case:override-omission';body={
    $o=Copy-Owners $routingOwners;$o['capacity-mutants-flip']=@($o['capacity-mutants-flip'] | ForEach-Object { $_.Replace('capacity-mutant:override-omission','case:override-omission') })
    Get-RoutingCoverage $routingSource $routingBaseline $o $routingManifest }}
  'routing-misassigned-mutant-as-routing'=@{expected='unknown or misassigned unit: routing-mutant:freeze-row';body={
    $o=Copy-Owners $routingOwners;$o['cases-core']+=@('routing-mutant:freeze-row')
    Get-RoutingCoverage $routingSource $routingBaseline $o $routingManifest }}
  'routing-drop-case'=@{expected='unit has no part: case:policy';body={
    $o=Copy-Owners $routingOwners;$o['cases-core']=@($o['cases-core'] | Where-Object { $_ -cne 'case:policy' })
    Get-RoutingCoverage $routingSource $routingBaseline $o $routingManifest }}
  'routing-drop-mutant-source'=@{expected='routing split changed non-plumbing source';body={
    $s=[regex]::Replace($routingSource,"(?m)^      @\{name='drop-slot'[^\n]*\n",'')
    Assert-Ci ($s -cne $routingSource) 'control seam';Get-RoutingCoverage $s $routingBaseline $routingOwners $routingManifest }}
  'routing-ungated-routing-mutants'=@{expected='routing mutant block is not gated';body={
    $s=$routingSource.Replace($RoutingGate,'').Replace("  } # PART-END`n",'')
    Get-RoutingCoverage $s $routingBaseline $routingOwners $routingManifest }}
  'routing-capacity-loop-gated'=@{expected='capacity mutant loop gated';body={
    $s=$routingSource.Replace("  } # PART-END`n",'').Replace("} finally {`n","  } # PART-END`n} finally {`n")
    Get-RoutingCoverage $s $routingBaseline $routingOwners $routingManifest }}
  'routing-filter-in-wrong-loop'=@{expected='routing mutant loop carries a part filter';body={
    $s=$routingSource.Replace($RoutingFixed[3]+"`n",'').Replace("    foreach(`$m in `$mutants){`n","    foreach(`$m in `$mutants){`n"+$RoutingFixed[3]+"`n")
    Get-RoutingCoverage $s $routingBaseline $routingOwners $routingManifest }}
  'routing-child-self-call-captured'=@{expected='routing split changed non-plumbing source';body={
    $s=$routingSource.Replace("'-Case',`$m.case)","'-Case',`$m.case,'-Part','all')")
    Assert-Ci ($s -cne $routingSource) 'control seam';Get-RoutingCoverage $s $routingBaseline $routingOwners $routingManifest }}
  'routing-manifest-missing-part'=@{expected='manifest parts differ from its part map';body={
    Get-RoutingCoverage $routingSource $routingBaseline $routingOwners @($routingManifest | Select-Object -SkipLast 1) }}
  'cleanup-region-ungated'=@{expected='ungated cleanup statement asserts or reports';body={
    $s=$cleanupSource.Replace("  if(Test-SuitePart 'cleanup-orphan-worktree-dirs' `$Part 'batched-authority'){ # PART-BEGIN`n  Assert-BatchedAuthority`n  } # PART-END`n","  Assert-BatchedAuthority`n")
    Assert-Ci ($s -cne $cleanupSource) 'control seam';Get-CleanupCoverage $s $cleanupBaseline $cleanupOwners $cleanupManifest }}
  'cleanup-region-unowned'=@{expected='cleanup region mutantz has 0 owning parts';body={
    $s=$cleanupSource.Replace("`$Part 'mutants'){ # PART-BEGIN","`$Part 'mutantz'){ # PART-BEGIN")
    Get-CleanupCoverage $s $cleanupBaseline $cleanupOwners $cleanupManifest }}
  'cleanup-region-duplicate-owner'=@{expected='cleanup region mutants has 2 owning parts';body={
    $o=Copy-Owners $cleanupOwners;$o['native']+=@('mutants');Get-CleanupCoverage $cleanupSource $cleanupBaseline $o $cleanupManifest }}
  'cleanup-drop-part'=@{expected='cleanup region native has 0 owning parts';body={
    $o=Copy-Owners $cleanupOwners;$o.Remove('native')
    $s=$cleanupSource.Replace(",'scale','native')]",",'scale')]");Get-CleanupCoverage $s $cleanupBaseline $o @($cleanupManifest | Where-Object { $_ -cne 'native' }) }}
  'cleanup-scale-assertion-split'=@{expected='scale fixture, bounds and AC6 assertions split across parts';body={
    $line=@($cleanupSource.Split("`n") | Where-Object { $_.Contains('AC6 synthetic dry-run total under 300000 ms') })[0]
    $s=$cleanupSource.Replace($line+"`n","  } # PART-END`n  if(Test-SuitePart 'cleanup-orphan-worktree-dirs' `$Part 'native'){ # PART-BEGIN`n"+$line+"`n")
    Get-CleanupCoverage $s $cleanupBaseline $cleanupOwners $cleanupManifest }}
  'cleanup-duplicate-statement'=@{expected='cleanup split changed non-plumbing source';body={
    $s=$cleanupSource.Replace("  if(Test-SuitePart 'cleanup-orphan-worktree-dirs' `$Part 'mutants'){ # PART-BEGIN`n","  if(Test-SuitePart 'cleanup-orphan-worktree-dirs' `$Part 'mutants'){ # PART-BEGIN`n  Assert-BatchedAuthority`n")
    Get-CleanupCoverage $s $cleanupBaseline $cleanupOwners $cleanupManifest }}
  'cleanup-manifest-duplicate-part'=@{expected='manifest parts differ from its part map';body={
    Get-CleanupCoverage $cleanupSource $cleanupBaseline $cleanupOwners (@($cleanupManifest)+@('native')) }}
  # Board controls keep the exact-line guard satisfied so the trace guard itself must refuse.
  'board-warmup-leaks-into-all'=@{expected='board -Arm all call trace changed';body={
    $line=$BoardWarmup.Replace('$Arm -ne ''all'' -and ',''); Get-BoardCoverage $board.Replace($BoardWarmup,$line) $boardBaseline $boardParts $line }}
  'board-candidate-warmed'=@{expected='cold candidate part warmed';body={
    $line=$BoardWarmup.Replace(' -and $name -ne ''candidate''',''); Get-BoardCoverage $board.Replace($BoardWarmup,$line) $boardBaseline $boardParts $line }}
  'board-warmup-foreign-fixture'=@{expected='not warmed once on its own fixture';body={
    $line=$BoardWarmup.Replace('Measure-BoardReference $f.log','Measure-BoardReference (Join-Path $root ''candidate/dispatch.jsonl'')'); Get-BoardCoverage $board.Replace($BoardWarmup,$line) $boardBaseline $boardParts $line }}
  'board-warmup-after-arm'=@{expected='not warmed once on its own fixture before its arm';body={
    $s=$board.Replace($BoardWarmup+"`n",'').Replace("    if (`$name -eq 'candidate') { Invoke-BoardScaleArm `$f 'inert' }`n","    if (`$name -eq 'candidate') { Invoke-BoardScaleArm `$f 'inert' }`n"+$BoardWarmup+"`n")
    Assert-Ci ($s -cne $board) 'control seam'; Get-BoardCoverage $s $boardBaseline $boardParts }}
  'board-arm-dropped'=@{expected='board orchestration changed beyond the standalone warm-up';body={
    $s=$board.Replace("'issue-scan','no-linkage','ten-item'","'issue-scan','ten-item'"); Assert-Ci ($s -cne $board) 'control seam'; Get-BoardCoverage $s $boardBaseline $boardParts }}
  'board-part-missing'=@{expected='board union changed arm calls';body={ Get-BoardCoverage $board $boardBaseline @($boardParts | Where-Object { $_ -cne 'no-linkage' }) }}
}
foreach ($name in $controls.Keys) { Refuses $controls[$name].body $controls[$name].expected; Write-Output "PASS coverage control $name refused" }

# Optional log evidence: the union of part logs repeats every PASS line of the
# whole-suite log exactly once (run-varying timings and paths normalized).
function Get-PassLines([string]$Path) {
  return @(Get-Content -LiteralPath $Path | Where-Object { $_ -clike 'PASS *' } | ForEach-Object {
    [regex]::Replace($_,'\b(wallMs|constructionMs|reportWallMs|totalMs|cpuStart|cpuEnd|report|root)=\S+','$1=*') } | Sort-Object)
}
$logEvidence=[ordered]@{}
if ($PartResultDirectory) {
  $PartLogs=@(Get-ChildItem -LiteralPath $PartResultDirectory -Filter shard.json -Recurse -File | ForEach-Object {
    $dir=$_.DirectoryName
    (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).results | Where-Object { $_.identity -like '*#*' } | ForEach-Object { "$($_.identity)=$(Join-Path $dir $_.provenance.log)" } })
}
if ($PartLogs.Count) {
  foreach ($suite in @(@{identity='test:dispatch-routing-data.test.ps1';whole=$RoutingWholeLog;parts=$routingManifest},@{identity='test:cleanup-orphan-worktree-dirs.test.ps1';whole=$CleanupWholeLog;parts=$cleanupManifest})) {
    $logs=@($PartLogs | Where-Object { $_.StartsWith("$($suite.identity)#") })
    if ($logs.Count -eq 0) { continue }
    $named=@($logs | ForEach-Object { $_.Substring($suite.identity.Length+1).Split('=',2)[0] })
    Assert-Ci ((@($named | Sort-Object) -join ',') -ceq (@($suite.parts | Sort-Object) -join ',')) "part logs do not cover every $($suite.identity) part exactly once"
    $union=@($logs | ForEach-Object { Get-PassLines $_.Split('=',2)[1] } | Sort-Object)
    $whole=Get-PassLines $suite.whole
    $diff=@(Compare-Object $whole $union -SyncWindow ([Math]::Max($whole.Count,$union.Count)))
    Write-CiJson @($diff) (Join-Path $EvidenceDirectory ("pass-line-diff-{0}.json" -f ($suite.identity -replace '[^a-z-]','')))
    Assert-Ci ($diff.Count -eq 0) "part logs do not repeat every $($suite.identity) PASS line exactly once (diff=$($diff.Count))"
    $logEvidence[$suite.identity]=@{wholeLog=$suite.whole;passLines=$whole.Count;partLogs=$logs}
    Write-Output "PASS part-log union $($suite.identity): $($whole.Count) PASS lines, each exactly once across $($logs.Count) part logs"
  }
}
$result=@{outcome='PASS';baselineHead=$BaselineHead;baselineBlobs=$BaselineBlobs;priority='BelowNormal';boardCalls=$expected
  landedAssertionCount=$originalAssertions.Count;landedParts=@($landedParts.name);routing=$routing;cleanup=$cleanup
  controls=@($controls.Keys);partLogEvidence=$logEvidence
  boardFullFixtureAndSupport='byte-identical after newline normalization';landedOriginalSource='identical after removing partition plumbing'}
Write-CiJson $result (Join-Path $EvidenceDirectory 'coverage-proof.json')
Write-Output "PASS coverage controls=$($controls.Count) refused for their named reasons"
