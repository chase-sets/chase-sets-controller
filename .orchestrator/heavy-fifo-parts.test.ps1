$ErrorActionPreference = 'Stop'
function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw "ASSERTION FAILED: $Message" } }
function Replace-One([string]$Text, [string]$Old, [string]$New) {
  Assert-True ([regex]::Matches($Text, [regex]::Escape($Old)).Count -eq 1) 'one exact split anchor'
  return $Text.Replace($Old, $New)
}
$root = Split-Path -Parent $PSScriptRoot
$source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'invoke-heavy-verifier-fifo.test.ps1')).Replace("`r`n", "`n")
$baseline = (@(& git -C $root cat-file blob '905ac018366b60cf382951db2068dafcafb4d3cf') -join "`n") + "`n"
Assert-True ($LASTEXITCODE -eq 0) 'exact pre-split ordinary source readable'
$prelude = @'
. (Join-Path $PSScriptRoot 'suite-parts.ps1')
$skipControllerOrder = $false
if ($Part -like 'hosted-*') {
  Assert-SuiteSelection $Part @('hosted-controller','hosted-main') $PSBoundParameters @('Mutant','GuardRevision','MutantMatrix','MatrixMutants','MatrixThrottle')
  $skipControllerOrder = $Part -ceq 'hosted-main'
  $Part = if ($skipControllerOrder) { 'all' } else { 'controller' }
}
'@
$prelude = $prelude.Replace("`r`n", "`n")
$expected = Replace-One $baseline "'isolation','controller')][string]`$Part" "'isolation','controller','hosted-controller','hosted-main')][string]`$Part"
$expected = Replace-One $expected "`$ErrorActionPreference = 'Stop'" ("`$ErrorActionPreference = 'Stop'`n" + $prelude)
$expected = Replace-One $expected "  if(`$Part-eq'all') {`n  Test-ControllerOrder" "  if(`$Part-eq'all') {`n  if (-not `$skipControllerOrder) { Test-ControllerOrder }"
Assert-True ($source -ceq $expected) 'full ordinary source, assertions, mutants and cleanup conserved with only hosted selector guards'

# End before the clock, source loading, temporary files or process fixtures.
$prefix = $source.Substring(0, $source.IndexOf('$suiteClock ='))
$probe = [scriptblock]::Create($prefix.Replace('$PSScriptRoot', "'$PSScriptRoot'") + @'
[pscustomobject]@{part=$Part;skipController=$skipControllerOrder}
'@)
foreach ($name in @('<default>','all','order','lifecycle','authority','recovery','isolation','controller','hosted-controller','hosted-main')) {
  $arguments = if ($name -ceq '<default>') { @{} } else { @{Part=$name} }
  $row = & $probe @arguments
  $want = switch ($name) { '<default>' { 'all' } 'hosted-controller' { 'controller' } 'hosted-main' { 'all' } default { $name } }
  Assert-True ($row.part -ceq $want -and $row.skipController -eq ($name -ceq 'hosted-main')) "exact legacy/hosted selection: $name"
}
foreach ($name in @('HOSTED-MAIN','HOSTED-CONTROLLER')) {
  $refused = $false
  try { & $probe -Part $name | Out-Null } catch { $refused = $_.Exception.Message -clike 'SUITE_PART:*' }
  Assert-True $refused "case-drifted hosted selector refuses before fixtures: $name"
}
$legacy = @{Mutant='';GuardRevision='';MutantMatrix=$false;MatrixMutants=@();MatrixThrottle=1}
foreach ($part in @('hosted-controller','hosted-main')) {
  foreach ($name in $legacy.Keys) {
    $refused = $false
    $arguments = @{Part=$part;$name=$legacy[$name]}
    try { & $probe @arguments | Out-Null } catch { $refused = $_.Exception.Message -ceq "SUITE_PART: Part conflicts with $name" }
    Assert-True $refused "explicit legacy selector conflicts even false/empty: $part/$name"
  }
}
. (Join-Path $PSScriptRoot 'controller-ci.ps1') -Mode Library
. (Join-Path $PSScriptRoot 'suite-parts.ps1')
$manifest = Get-Content (Join-Path $PSScriptRoot 'controller-ci-parts.json') -Raw | ConvertFrom-Json -Depth 50
$item = @($manifest.items | Where-Object identity -CEQ 'test:invoke-heavy-verifier-fifo.test.ps1')
Assert-True ($item.Count -eq 1) 'one complete FIFO split mapping'
$inventory = @([pscustomobject]@{identity=$item[0].identity;path='.orchestrator/invoke-heavy-verifier-fifo.test.ps1';command='synthetic';arguments=@();restriction=$null})
$only = @{schemaVersion='controller-ci-parts/v1';items=$item}
Assert-CiManifest $inventory $only $root
$tasks = New-CiAssignments $inventory '' $only -ShardCount 16
Assert-True ($tasks.Count -eq 2 -and @($tasks | Where-Object restriction).Count -eq 0) 'both FIFO partitions remain hosted requirements'
foreach ($name in @('hosted-controller','hosted-main')) {
  $bad = $only | ConvertTo-Json -Depth 50 | ConvertFrom-Json -Depth 50
  $bad.items[0].parts = @($bad.items[0].parts | Where-Object name -CNE $name)
  $refused = $false
  try { Assert-CiManifest $inventory $bad $root } catch { $refused = $true }
  Assert-True $refused "missing FIFO partition refuses: $name"
}
Write-Output 'PASS FIFO full-source conservation, default and legacy preservation, hosted partition selection and complete mapping; no ordinary fixture/native/Job/signal execution'
