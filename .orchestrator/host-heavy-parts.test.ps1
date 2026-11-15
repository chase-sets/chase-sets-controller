$ErrorActionPreference = 'Stop'
function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw "ASSERTION FAILED: $Message" } }
function Replace-One([string]$Text, [string]$Old, [string]$New) {
  Assert-True ([regex]::Matches($Text, [regex]::Escape($Old)).Count -eq 1) 'one exact host split anchor'
  return $Text.Replace($Old, $New)
}
$path = Join-Path $PSScriptRoot 'host-heavy-verifier.test.ps1'
$source = [IO.File]::ReadAllText($path).Replace("`r`n", "`n")
$baseline = (@(& git -C (Split-Path -Parent $PSScriptRoot) cat-file blob '94b6fcfce2d9f96bfd6ac0ecc3150cbc43e054e1') -join "`n") + "`n"
Assert-True ($LASTEXITCODE -eq 0) 'exact original host suite readable'
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($baseline, [ref]$null, [ref]$errors)
Assert-True ($errors.Count -eq 0) 'original host suite parses'
$header = $ast.ParamBlock.Extent.Text
$expected = Replace-One $baseline $header ($header.Substring(0, $header.Length - 1) + ", [string]`$Part = '')")
$prelude = @'
. (Join-Path $PSScriptRoot 'suite-parts.ps1')
Assert-SuiteSelection $Part @('windows','native') $PSBoundParameters @('Baseline','NativeDbOnly','Control')
if ($Part -ceq 'native') { $NativeDbOnly = $true }
'@
$prelude = $prelude.Replace("`r`n", "`n")
$expected = Replace-One $expected "`$ErrorActionPreference = 'Stop'`nfunction Read-FixtureOwner" ("`$ErrorActionPreference = 'Stop'`n" + $prelude + "`nfunction Read-FixtureOwner")
$expected = Replace-One $expected 'if (-not $Baseline -and -not $Control) { & $PSCommandPath -NativeDbOnly }' 'if ((Test-SuitePart $Part ''native'') -and -not $Baseline -and -not $Control) { & $PSCommandPath -NativeDbOnly }'
Assert-True ($source -ceq $expected) 'full host source conserved: only selector prelude and native-call guard added'

# Stop before even defining the fixture helpers; exercise real parameter binding.
$prefix = $source.Substring(0, $source.IndexOf('function Read-FixtureOwner'))
$probe = [scriptblock]::Create($prefix.Replace('$PSScriptRoot', "'$PSScriptRoot'") + @'
[pscustomobject]@{
  native = [bool]$NativeDbOnly -or ((Test-SuitePart $Part 'native') -and -not $Baseline -and -not $Control)
  windows = -not $NativeDbOnly
}
'@)
foreach ($name in @('<default>','windows','native')) {
  $arguments = if ($name -ceq '<default>') { @{} } else { @{Part=$name} }
  $row = & $probe @arguments
  foreach ($stage in @('windows','native')) {
    Assert-True ($row.$stage -eq ($name -ceq '<default>' -or $name -ceq $stage)) "exact host selection $name/$stage"
  }
}
foreach ($name in @('','unknown','WINDOWS')) {
  $refused = $false
  try { & $probe -Part $name | Out-Null } catch { $refused = $_.Exception.Message -clike 'SUITE_PART:*' }
  Assert-True $refused "invalid host part refused: '$name'"
}
foreach ($legacy in @('Baseline','NativeDbOnly','Control')) {
  $refused = $false
  $arguments = @{Part='windows';$legacy=$(if ($legacy -ceq 'Control') { '' } else { $false })}
  try { & $probe @arguments | Out-Null } catch { $refused = $_.Exception.Message -ceq "SUITE_PART: Part conflicts with $legacy" }
  Assert-True $refused "all explicit host legacy selectors conflict, even false/empty: $legacy"
}
$legacyNative = & $probe -NativeDbOnly
Assert-True ($legacyNative.native -and -not $legacyNative.windows) 'legacy NativeDbOnly still owns the full native route'
. (Join-Path $PSScriptRoot 'controller-ci.ps1') -Mode Library
$manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'controller-ci-parts.json') -Raw | ConvertFrom-Json -Depth 50
$item = @($manifest.items | Where-Object identity -CEQ 'test:host-heavy-verifier.test.ps1')
Assert-True ($item.Count -eq 1) 'one complete host split mapping'
$inventory = @([pscustomobject]@{identity=$item[0].identity;path='.orchestrator/host-heavy-verifier.test.ps1';command='synthetic';arguments=@();restriction=$null})
$only = @{schemaVersion='controller-ci-parts/v1';items=$item}
$controllerRoot = Split-Path -Parent $PSScriptRoot
function Assert-HostMapping($Mapping) {
  Assert-CiManifest $inventory $Mapping $controllerRoot
  $tasks = New-CiAssignments $inventory '' $Mapping -ShardCount 16
  Assert-True ($tasks.Count -eq 2) 'both host routes remain required'
  $windows = @($tasks | Where-Object identity -CEQ 'test:host-heavy-verifier.test.ps1#windows')
  $native = @($tasks | Where-Object identity -CEQ 'test:host-heavy-verifier.test.ps1#native')
  Assert-True ($windows.Count -eq 1 -and $null -eq $windows[0].restriction) 'Windows controls cannot be excluded'
  Assert-True ($native.Count -eq 1 -and $native[0].restriction.classification -ceq 'LOCAL_ONLY' -and $native[0].restriction.reason -match 'Ubuntu WSL.*?/srv/chase-sets-pg-probe') 'native route retains its exact host-resource requirement, not an assertion exemption'
}
Assert-HostMapping $only
foreach ($variant in @('missing-windows','missing-native','excluded-windows','unrestricted-native')) {
  $bad = $only | ConvertTo-Json -Depth 50 | ConvertFrom-Json -Depth 50
  if ($variant -like 'missing-*') { $bad.items[0].parts = @($bad.items[0].parts | Where-Object name -CNE $variant.Substring(8)) }
  if ($variant -ceq 'excluded-windows') { $bad.items[0].parts[0] | Add-Member restriction $bad.items[0].parts[1].restriction }
  if ($variant -ceq 'unrestricted-native') { $bad.items[0].parts[1].restriction = $null }
  $refused = $false
  try { Assert-HostMapping $bad } catch { $refused = $true }
  Assert-True $refused "host resource-boundary mutant refused: $variant"
}
Write-Output 'PASS complete original host/native source, default union, isolated selectors, legacy conflicts and required host-resource mapping; native/fixture/Job/signal bodies NOT_RUN'
