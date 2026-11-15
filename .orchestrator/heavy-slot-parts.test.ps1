$ErrorActionPreference = 'Stop'
function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw "ASSERTION FAILED: $Message" } }
function Replace-One([string]$Text, [string]$Old, [string]$New) {
  Assert-True ([regex]::Matches($Text, [regex]::Escape($Old)).Count -eq 1) 'one exact split anchor'
  return $Text.Replace($Old, $New)
}
$path = Join-Path $PSScriptRoot 'heavy-slot.test.ps1'
$source = [IO.File]::ReadAllText($path).Replace("`r`n", "`n")
$baseline = (@(& git -C (Split-Path -Parent $PSScriptRoot) cat-file blob 'f9453fcc16206ba259070925e950c41019550fce') -join "`n") + "`n"
Assert-True ($LASTEXITCODE -eq 0) 'exact pre-split ordinary source readable'
$oldHeader = $baseline.Split("`n")[0]
$newHeader = $oldHeader.Substring(0, $oldHeader.Length - 1) + ", [string]`$Part = '')"
$prelude = @'
. (Join-Path $PSScriptRoot 'suite-parts.ps1')
Assert-SuiteSelection $Part @('contracts','measurements','mutants') $PSBoundParameters @('OwnerTransitionOnly','FilteredTestOnly','BrowserOnly','BrowserBaseline','CensusOnly','CurrentBindingOnly','IdentityOnly','LauncherNonReentryOnly','Baseline','CleanupDiscriminator','NestedSmoke','NestedOnly','MeasurementsAndMutantsOnly','MutantsOnly','MutantStartAt')
if ($Part -ceq 'measurements') { $MeasurementsAndMutantsOnly = $true }
if ($Part -ceq 'mutants') { $MutantsOnly = $true }
'@
$expected = Replace-One $baseline $oldHeader $newHeader
$expected = Replace-One $expected '. (Join-Path $PSScriptRoot ''heavy-slot-fixture-test-support.ps1'')' ($prelude + "`n. (Join-Path `$PSScriptRoot 'heavy-slot-fixture-test-support.ps1')")
$expected = Replace-One $expected '  # AC1 measurement: complete unchanged work (one root, nineteen sequential' ("  if (Test-SuitePart `$Part 'measurements') {`n  # AC1 measurement: complete unchanged work (one root, nineteen sequential")
$expected = Replace-One $expected '  # Per-guard candidate/bypass mutants: one governing variable each, every' ("  }`n  if (Test-SuitePart `$Part 'mutants') {`n  # Per-guard candidate/bypass mutants: one governing variable each, every")
$expected = Replace-One $expected '  Write-Output "PASS heavy slot artifact acquisition, token identity, refusal, nesting, nested authority, and re-entrancy"' ("  }`n  Write-Output `"PASS heavy slot artifact acquisition, token identity, refusal, nesting, nested authority, and re-entrancy`"")
Assert-True ($source -ceq $expected) 'full ordinary source conserved: only selector prelude and part guards added'

# Execute only the selector prelude, ending before any fixture/native support.
$prefix = $source.Substring(0, $source.IndexOf(". (Join-Path `$PSScriptRoot 'heavy-slot-fixture-test-support.ps1')"))
$probe = [scriptblock]::Create($prefix.Replace('$PSScriptRoot', "'$PSScriptRoot'") + @'
if ($MutantsOnly) { $MeasurementsAndMutantsOnly = $true }
[pscustomobject]@{
  contracts = -not $MeasurementsAndMutantsOnly
  measurements = (Test-SuitePart $Part 'measurements') -and -not $MutantsOnly
  mutants = Test-SuitePart $Part 'mutants'
}
'@)
foreach ($name in @('<default>','contracts','measurements','mutants')) {
  $arguments = if ($name -ceq '<default>') { @{} } else { @{Part=$name} }
  $row = & $probe @arguments
  foreach ($stage in @('contracts','measurements','mutants')) {
    Assert-True ($row.$stage -eq ($name -ceq '<default>' -or $name -ceq $stage)) "exact split selection: $name/$stage"
  }
}
$legacyNames = @('OwnerTransitionOnly','FilteredTestOnly','BrowserOnly','BrowserBaseline','CensusOnly','CurrentBindingOnly','IdentityOnly','LauncherNonReentryOnly','Baseline','CleanupDiscriminator','NestedSmoke','NestedOnly','MeasurementsAndMutantsOnly','MutantsOnly','MutantStartAt')
foreach ($name in @('','unknown','CONTRACTS')) {
  $refused = $false
  try { & $probe -Part $name | Out-Null } catch { $refused = $_.Exception.Message -clike 'SUITE_PART:*' }
  Assert-True $refused "explicit invalid part refused before fixture: '$name'"
}
foreach ($legacy in $legacyNames) {
  $refused = $false
  $arguments = @{Part='contracts';$legacy=$false}
  try { & $probe @arguments | Out-Null } catch { $refused = $_.Exception.Message -ceq "SUITE_PART: Part conflicts with $legacy" }
  Assert-True $refused "all explicit legacy selectors conflict, even false: $legacy"
}
. (Join-Path $PSScriptRoot 'controller-ci.ps1') -Mode Library
. (Join-Path $PSScriptRoot 'suite-parts.ps1')
$manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'controller-ci-parts.json') -Raw | ConvertFrom-Json -Depth 50
$item = @($manifest.items | Where-Object identity -CEQ 'test:heavy-slot.test.ps1')
Assert-True ($item.Count -eq 1) 'one complete heavy-slot split mapping'
$inventory = @([pscustomobject]@{identity=$item[0].identity;path='.orchestrator/heavy-slot.test.ps1';command='synthetic';arguments=@();restriction=$null})
$only = @{schemaVersion='controller-ci-parts/v1';items=$item}
Assert-CiManifest $inventory $only (Split-Path -Parent $PSScriptRoot)
$tasks = New-CiAssignments $inventory '' $only -ShardCount 16
Assert-True ($tasks.Count -eq 3 -and @($tasks | Where-Object restriction).Count -eq 0) 'all three parts remain hosted requirements'
foreach ($missing in @('contracts','measurements','mutants')) {
  $bad = $only | ConvertTo-Json -Depth 50 | ConvertFrom-Json -Depth 50
  $bad.items[0].parts = @($bad.items[0].parts | Where-Object name -CNE $missing)
  $refused = $false
  try { Assert-CiManifest $inventory $bad (Split-Path -Parent $PSScriptRoot) } catch { $refused = $true }
  Assert-True $refused "missing part refuses planning: $missing"
}
Write-Output 'PASS heavy-slot full-source conservation, default union, exact isolated selectors, all legacy conflicts and complete hosted mapping; no fixture/native/Job/signal execution'
