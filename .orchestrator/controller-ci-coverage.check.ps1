param(
  [string]$BaselineHead='2815303128f3151e10d71bfdd351dc9b659a2b47',
  [string]$EvidenceDirectory=(Join-Path $PSScriptRoot 'logs/controller-8661-ci-sharding-g1')
)
$ErrorActionPreference='Stop'
[Diagnostics.Process]::GetCurrentProcess().PriorityClass='BelowNormal'
. (Join-Path $PSScriptRoot 'controller-ci.ps1') -Mode Library
. (Join-Path $PSScriptRoot 'landed-integration-test-parts.ps1')
$root=Split-Path -Parent $PSScriptRoot
function Read-Baseline([string]$Path) {
  $lines=@(& git -C $root show "${BaselineHead}:$Path")
  Assert-Ci ($LASTEXITCODE -eq 0) "baseline source unavailable: $Path"
  return ($lines -join "`n")+"`n"
}
function Parse-Source([string]$Source) {
  $tokens=$null;$errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseInput($Source,[ref]$tokens,[ref]$errors)
  Assert-Ci (@($errors).Count -eq 0) 'coverage source parser error'
  return $ast
}
function Get-AssertionText([string]$Source) {
  return @( (Parse-Source $Source).FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -like 'Assert-*'},$true) | ForEach-Object {$_.Extent.Text})
}
$boardBaseline=Read-Baseline '.orchestrator/board-hourly-scale.test.ps1'
$board=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'board-hourly-scale-part.ps1')).Replace("`r`n","`n")
Assert-Ci ($board -ceq $boardBaseline) 'board orchestration changed while splitting'
foreach ($path in @('.orchestrator/board-scale-test-support.ps1','.orchestrator/routing-data-test-support.ps1')) {
  Assert-Ci ([IO.File]::ReadAllText((Join-Path $root $path)).Replace("`r`n","`n") -ceq (Read-Baseline $path)) "full fixture/assertion support changed: $path"
}
$wrapper=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'board-hourly-scale.test.ps1')).Replace("`r`n","`n")
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
  function New-BoardScaleFixture($Path,$ItemCount) { return @{items=$ItemCount;name=(Split-Path -Leaf $Path)} }
  function Invoke-BoardScaleArm($Fixture,$Name) { $script:trace.Add("$($Fixture.name)|$($Fixture.items)|$Name") }
  & ([scriptblock]::Create($Source)) -Arm $Arm | Out-Null
  return ,@($script:trace)
}
$expected=Get-BoardTrace $boardBaseline 'all'
$actual=@(foreach ($part in @($manifest.items | Where-Object identity -CEQ 'test:board-hourly-scale.test.ps1')[0].parts) { Get-BoardTrace $board $part.name | ForEach-Object { $_ } })
Assert-Ci (($actual -join ',') -ceq ($expected -join ',')) 'board union changed arm calls, full 2400-item tiers, inert reuse, or ten-item controls'
Assert-Ci ($expected.Count -eq 7) 'board case inventory changed'

$landedBaseline=Read-Baseline '.orchestrator/landed-integration-dispatch.test.ps1'
$landed=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'landed-integration-dispatch.test.ps1')).Replace("`r`n","`n")
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
$result=@{outcome='PASS';baselineHead=$BaselineHead;priority='BelowNormal';boardCalls=$expected
  landedAssertionCount=$originalAssertions.Count;landedParts=@($landedParts.name)
  boardFullFixtureAndSupport='byte-identical after newline normalization';landedOriginalSource='identical after removing partition plumbing'}
Write-CiJson $result (Join-Path $EvidenceDirectory 'coverage-proof.json')
Write-Output "PASS split union: board calls=$($expected.Count) full fixture/support unchanged; landed assertions=$($originalAssertions.Count) original source preserved, five disjoint regions"
