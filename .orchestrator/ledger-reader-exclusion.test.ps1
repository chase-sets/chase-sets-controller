[CmdletBinding()]
param([string]$EvidencePath='')
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ledger-reader-census.psm1') -Force
$root=Join-Path ([IO.Path]::GetTempPath()) ('ledger-exclusion-'+[guid]::NewGuid().ToString('N'))
$guard=@'
function Assert-NonDispatchLedgerPath {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Path)
  $leaf=([IO.Path]::GetFileName($Path) -split ':',2)[0].TrimEnd(' ','.')
  if ([string]::Equals($leaf,'dispatch-log.jsonl',[StringComparison]::OrdinalIgnoreCase)) {
    throw 'DISPATCH_LEDGER_OWNER_REQUIRED'
  }
}
Export-ModuleMember -Function Assert-NonDispatchLedgerPath
'@
$import='Import-Module (Join-Path $PSScriptRoot ''.orchestrator/dispatch-ledger-reader.psm1'')'
$assert='dispatch-ledger-reader\Assert-NonDispatchLedgerPath -Path $Path'
$observed=[Collections.Generic.List[object]]::new()
$failures=[Collections.Generic.List[string]]::new()
try {
  [void][IO.Directory]::CreateDirectory((Join-Path $root '.orchestrator'))
  $reader=Join-Path $root 'reader.ps1';$owner=Join-Path $root '.orchestrator/dispatch-ledger-reader.psm1'
  [IO.File]::WriteAllText($reader,'# synthetic source')
  [IO.File]::WriteAllText($owner,$guard)
  & git -C $root init -q
  if ($LASTEXITCODE) { throw 'exclusion fixture init failed' }
  & git -C $root add reader.ps1 .orchestrator/dispatch-ledger-reader.psm1
  if ($LASTEXITCODE) { throw 'exclusion fixture track failed' }
  & git -C $root -c user.name=Synthetic -c user.email=synthetic@example.invalid commit -qm exclusion
  if ($LASTEXITCODE) { throw 'exclusion fixture commit failed' }
  $cases=[ordered]@{
    native=@(0,"$import;function Read-Synthetic {param(`$Path);$assert;[IO.File]::ReadAllText(`$Path)}")
    content=@(0,"$import;function Read-Synthetic {param(`$Path);$assert;Get-Content -LiteralPath `$Path}")
    mixed=@(0,"$import;function Read-Synthetic {param(`$Path,`$DispatchHistory);if(`$DispatchHistory){Read-DispatchLedgerLines -Path `$Path}else{$assert;[IO.File]::ReadAllLines(`$Path)}}")
    wrongVariable=@(1,"$import;function Read-Synthetic {param(`$Path,`$Other);dispatch-ledger-reader\Assert-NonDispatchLedgerPath -Path `$Other;[IO.File]::ReadAllText(`$Path)}")
    laterGuard=@(1,"$import;function Read-Synthetic {param(`$Path);[IO.File]::ReadAllText(`$Path);$assert}")
    conditionalGuard=@(1,"$import;function Read-Synthetic {param(`$Path);if(`$false){$assert};[IO.File]::ReadAllText(`$Path)}")
    reassigned=@(1,"$import;function Read-Synthetic {param(`$Path);$assert;`$Path='dispatch-log.jsonl';[IO.File]::ReadAllText(`$Path)}")
    wrongQualifier=@(1,"$import;function Read-Synthetic {param(`$Path);other-module\Assert-NonDispatchLedgerPath -Path `$Path;[IO.File]::ReadAllText(`$Path)}")
    missingImport=@(1,"function Read-Synthetic {param(`$Path);$assert;[IO.File]::ReadAllText(`$Path)}")
    conditionalImport=@(1,"if(`$false){$import};function Read-Synthetic {param(`$Path);$assert;[IO.File]::ReadAllText(`$Path)}")
    wrongImport=@(1,"Import-Module (Join-Path `$PSScriptRoot 'other.psm1');function Read-Synthetic {param(`$Path);$assert;[IO.File]::ReadAllText(`$Path)}")
    laterImport=@(1,"function Read-Synthetic {param(`$Path);$assert;[IO.File]::ReadAllText(`$Path)};$import")
    prefixedImport=@(1,"$import -Prefix Synthetic;function Read-Synthetic {param(`$Path);$assert;[IO.File]::ReadAllText(`$Path)}")
    missingExport=@(1,"$import;function Read-Synthetic {param(`$Path);$assert;[IO.File]::ReadAllText(`$Path)}",$guard.Replace('Export-ModuleMember -Function Assert-NonDispatchLedgerPath','Export-ModuleMember -Function Other'))
    weakenedGuard=@(1,"$import;function Read-Synthetic {param(`$Path);$assert;[IO.File]::ReadAllText(`$Path)}",$guard.Replace('OrdinalIgnoreCase','Ordinal'))
    wrongGuardLeaf=@(1,"$import;function Read-Synthetic {param(`$Path);$assert;[IO.File]::ReadAllText(`$Path)}",$guard.Replace('dispatch-log.jsonl','cost-ledger.jsonl'))
    removedThrow=@(1,"$import;function Read-Synthetic {param(`$Path);$assert;[IO.File]::ReadAllText(`$Path)}",$guard.Replace("throw 'DISPATCH_LEDGER_OWNER_REQUIRED'","Write-Output 'DISPATCH_LEDGER_OWNER_REQUIRED'"))
    removedNormalization=@(1,"$import;function Read-Synthetic {param(`$Path);$assert;[IO.File]::ReadAllText(`$Path)}",$guard.Replace(".TrimEnd(' ','.')",''))
    contentLiteral=@(0,'Get-Content -LiteralPath ''receipt.json''')
    contentPositional=@(0,'Get-Content ''receipt.json''')
    contentUnknown=@(1,'param($Path);Get-Content -LiteralPath $Path')
    contentSplat=@(1,'param($Parameters);Get-Content @Parameters')
    constructorTypeIsNotPath=@(1,'param($Path);New-Object System.IO.StreamReader -ArgumentList $Path')
    untypedGuardPath=@(1,"$import;function Read-Untyped {param(`$Path);$assert;[IO.File]::ReadAllText(`$Path)}")
  }
  foreach ($name in $cases.Keys) {
    # Match the real helpers' string binding. The separate untyped sibling
    # must refuse rather than assume two object-to-string conversions agree.
    $source=$cases[$name][1].Replace('function Read-Synthetic {param($Path','function Read-Synthetic {param([string]$Path')
    [IO.File]::WriteAllText($reader,$source)
    [IO.File]::WriteAllText($owner,$(if($cases[$name].Count -gt 2){$cases[$name][2]}else{$guard}))
    $c=Get-LedgerReaderCensus -Root $root
    $expected=[int]$cases[$name][0] -gt 0
    $observed.Add([pscustomobject]@{case=$name;expectedViolation=$expected;violations=$c.violations.Count;rows=@($c.rows)})
    if ($c.scanned -ne 2 -or $c.total -ne 2 -or (($c.violations.Count -gt 0) -ne $expected)) { $failures.Add($name) }
    Write-Output "EXCLUSION case=$name violations=$($c.violations.Count) expected=$([int]$expected)"
  }
  if ($EvidencePath) { $observed.ToArray() | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $EvidencePath -Encoding utf8 }
  if ($failures.Count) { throw "SURVIVED exclusion controls: $($failures -join ',')" }
  Write-Output "PASS ledger exclusion controls=$($cases.Count) realTrackedInventory=true"
} finally {
  $full=[IO.Path]::GetFullPath($root)
  if ((Split-Path -Parent $full).TrimEnd('\','/') -cne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/') -or (Split-Path -Leaf $full) -cnotlike 'ledger-exclusion-*') { throw 'unsafe exclusion fixture cleanup' }
  if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
}
