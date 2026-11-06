[CmdletBinding()]
param([string]$EvidencePath='')
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ledger-reader-census.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1') -Force -DisableNameChecking
$root=Join-Path ([IO.Path]::GetTempPath()) ('ledger-path-value-'+[guid]::NewGuid().ToString('N'))
$observed=[Collections.Generic.List[object]]::new();$failures=[Collections.Generic.List[string]]::new()
$ownerSource=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1')).Replace("`r`n","`n")
$valueBody=(@'
function Get-NonDispatchLedgerPath {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Path)
  dispatch-ledger-reader\Assert-NonDispatchLedgerPath -Path $Path
  return $Path
}
'@).Replace("`r`n","`n")
if (-not $ownerSource.Contains($valueBody)) { throw 'path-value owner mutation seam missing' }
$untypedValue=$ownerSource.Replace($valueBody,$valueBody.Replace('[string]$Path','$Path'))
$import='Import-Module (Join-Path $PSScriptRoot ''.orchestrator/dispatch-ledger-reader.psm1'')'
$value='dispatch-ledger-reader\Get-NonDispatchLedgerPath -Path $Path'
try {
  [void][IO.Directory]::CreateDirectory((Join-Path $root '.orchestrator'))
  $dispatch=Join-Path $root 'dispatch-log.jsonl';$receipt=Join-Path $root 'receipt.json'
  [IO.File]::WriteAllText($dispatch,'not-json')
  [IO.File]::WriteAllText($receipt,'receipt-value')
  $tokens=$null;$errors=$null
  $pacing=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'capacity-pacing.ps1'),[ref]$tokens,[ref]$errors)
  if ($errors.Count) { throw 'pacing source does not parse' }
  $roles=& {
    foreach ($name in @('Read-PacingStatus','Get-PacingCensus')) {
      $definition=@($pacing.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true))
      if ($definition.Count -ne 1) { throw "pacing definition missing: $name" }
      . ([scriptblock]::Create($definition[0].Extent.Text))
    }
    [pscustomobject]@{status=(Read-PacingStatus $dispatch '' ([datetimeoffset]::UtcNow));census=(Get-PacingCensus $dispatch '' '' @{})}
  }
  if ($roles.status.reason -cne 'STATUS_UNREACHABLE' -or $roles.census.reason -cne 'CENSUS_UNAVAILABLE:DISPATCH_LEDGER_OWNER_REQUIRED') { throw 'actual pacing fixture readers did not refuse the canonical path before JSON/native access' }
  $script:pathConversions=0
  $script:receiptValue=$receipt;$script:dispatchValue=$dispatch
  $changing=[pscustomobject]@{}
  $changing|Add-Member -MemberType ScriptMethod -Name ToString -Force -Value {
    $script:pathConversions++
    if ($script:pathConversions -eq 1) { return $script:receiptValue }
    return $script:dispatchValue
  }
  $read=[IO.File]::ReadAllText((dispatch-ledger-reader\Get-NonDispatchLedgerPath -Path $changing))
  if ($read -cne 'receipt-value' -or $script:pathConversions -ne 1) { throw 'guarded value did not freeze exactly one object-to-string conversion' }
  $lock=[IO.File]::Open($dispatch,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
  try {
    $failure=$null
    try { [IO.File]::ReadAllText((dispatch-ledger-reader\Get-NonDispatchLedgerPath -Path $dispatch))|Out-Null } catch { $failure=$_.Exception.Message }
    if ($failure -cne 'DISPATCH_LEDGER_OWNER_REQUIRED') { throw "native read preceded value guard: $failure" }
  } finally { $lock.Dispose() }
  foreach($path in @($receipt,'cost-ledger.jsonl')) {
    $result=@(dispatch-ledger-reader\Get-NonDispatchLedgerPath -Path $path)
    if ($result.Count -ne 1 -or $result[0] -isnot [string] -or $result[0] -cne $path) { throw 'value guard altered allowed input or emitted extra output' }
  }
  $reader=Join-Path $root 'reader.ps1';$owner=Join-Path $root '.orchestrator/dispatch-ledger-reader.psm1'
  [IO.File]::WriteAllText($reader,'# synthetic source');[IO.File]::WriteAllText($owner,$ownerSource)
  & git -C $root init -q
  if ($LASTEXITCODE) { throw 'path-value fixture init failed' }
  & git -C $root add reader.ps1 .orchestrator/dispatch-ledger-reader.psm1
  if ($LASTEXITCODE) { throw 'path-value fixture track failed' }
  & git -C $root -c user.name=Synthetic -c user.email=synthetic@example.invalid commit -qm value
  if ($LASTEXITCODE) { throw 'path-value fixture commit failed' }
  $baseline=Get-LedgerReaderCensus -Root $root
  $ownerUnknown=@($baseline.violations | Where-Object path -CEQ '.orchestrator/dispatch-ledger-reader.psm1').Count
  Write-Output "PATH-VALUE fixture owner UNKNOWN=$ownerUnknown; production owner provenance remains a separate global contract gate"
  $native="$import;function Read-Synthetic {param(`$Path);[IO.File]::ReadAllText(($value))}"
  $cases=[ordered]@{
    native=@(0,$native)
    globalImport=@(0,$native.Replace($import,"$import -Global"))
    stopImport=@(0,$native.Replace($import,"$import -ErrorAction Stop"))
    quotedStopImport=@(0,$native.Replace($import,"$import -ErrorAction 'Stop'"))
    checkpointImport=@(0,$native.Replace($import,"$import -Global -DisableNameChecking -ErrorAction Stop"))
    continueImport=@(1,$native.Replace($import,"$import -ErrorAction Continue"))
    numericStopImport=@(1,$native.Replace($import,"$import -ErrorAction 1"))
    dynamicStopImport=@(1,$native.Replace($import,"$import -ErrorAction `$action"))
    missingStopImport=@(1,$native.Replace($import,"$import -ErrorAction"))
    inlineStopImport=@(1,$native.Replace($import,"$import -ErrorAction:Stop"))
    changedStopImport=@(1,$native.Replace($import,"$import -ErrorAction Stop -ErrorAction Continue"))
    duplicateStopImport=@(1,$native.Replace($import,"$import -ErrorAction Stop -eRrOrAcTiOn Stop"))
    duplicateSwitchImport=@(1,$native.Replace($import,"$import -Global -global"))
    scopedImport=@(1,$native.Replace($import,"$import -Scope Global"))
    globalArgument=@(1,$native.Replace($import,"$import -Global:`$false"))
    content=@(0,"$import;function Read-Synthetic {param(`$Path);Get-Content -LiteralPath ($value)}")
    expression=@(0,"$import;function Read-Synthetic {param(`$Item);[IO.File]::ReadAllBytes((dispatch-ledger-reader\Get-NonDispatchLedgerPath -Path `$Item.path))}")
    dispatchLiteral=@(0,"$import;[IO.File]::ReadAllText((dispatch-ledger-reader\Get-NonDispatchLedgerPath -Path 'dispatch-log.jsonl'))")
    assigned=@(0,"$import;function Read-Synthetic {param(`$Path);`$safe=($value);[IO.File]::ReadAllText(`$safe)}")
    originalObject=@(1,"$import;function Read-Synthetic {param(`$Path);$value;[IO.File]::ReadAllText(`$Path)}")
    interveningCommand=@(1,"$import;function Read-Synthetic {param(`$Path);`$safe=($value);Invoke-Synthetic;[IO.File]::ReadAllText(`$safe)}")
    pipelineMutation=@(1,"$import;function Read-Synthetic {param(`$Path);[IO.File]::ReadAllText(($value | ForEach-Object {'dispatch-log.jsonl'}))}")
    changedValue=@(1,"$import;function Read-Synthetic {param(`$Path);[IO.File]::ReadAllText((($value)+'dispatch-log.jsonl'))}")
    nestedNative=@(1,"$import;[IO.File]::ReadAllText((dispatch-ledger-reader\Get-NonDispatchLedgerPath -Path ([IO.File]::ReadAllText('dispatch-log.jsonl'))))")
    changedLeaf=@(1,"$import;[IO.File]::ReadAllText([IO.Path]::Combine((dispatch-ledger-reader\Get-NonDispatchLedgerPath -Path 'safe-root'),'dispatch-log.jsonl'))")
    unqualified=@(1,$native.Replace('dispatch-ledger-reader\Get-NonDispatchLedgerPath','Get-NonDispatchLedgerPath'))
    wrongQualifier=@(1,$native.Replace('dispatch-ledger-reader\Get-NonDispatchLedgerPath','other\Get-NonDispatchLedgerPath'))
    missingImport=@(1,$native.Replace("$import;",''))
    laterImport=@(1,($native.Replace("$import;",'')+";$import"))
    conditionalImport=@(1,$native.Replace($import,"if(`$false){$import}"))
    prefixedImport=@(1,$native.Replace($import,"$import -Prefix Other"))
    missingExport=@(1,$native,$ownerSource.Replace(',Get-NonDispatchLedgerPath,',','))
    weakenedGuard=@(1,$native,$ownerSource.Replace('OrdinalIgnoreCase','Ordinal'))
    missingGuardCall=@(1,$native,$ownerSource.Replace('  dispatch-ledger-reader\Assert-NonDispatchLedgerPath -Path $Path','  Write-Verbose ''no guard'''))
    changedReturn=@(1,$native,$ownerSource.Replace('  return $Path','  return ''dispatch-log.jsonl'''))
    additionalOutput=@(1,$native,$ownerSource.Replace('  return $Path','  Write-Output ''dispatch-log.jsonl''; return $Path'))
    untypedValue=@(1,$native,$untypedValue)
    duplicateValue=@(1,$native,($ownerSource+"`nfunction Get-NonDispatchLedgerPath { param(`$Path);return `$Path }"))
    missingAssertionExport=@(1,$native,$ownerSource.Replace('-Function Assert-NonDispatchLedgerPath,','-Function '))
    wrongParameter=@(1,$native.Replace('Get-NonDispatchLedgerPath -Path','Get-NonDispatchLedgerPath -LiteralPath'))
    extraArgument=@(1,$native.Replace('-Path $Path))','-Path $Path $Other))'))
    trappedValue=@(1,$native.Replace('param($Path);','param($Path);trap {continue};'))
    redirectedValue=@(1,$native.Replace('-Path $Path))','-Path $Path 2>&1))'))
  }
  foreach($name in $cases.Keys) {
    if ($cases[$name].Count -gt 2 -and $cases[$name][2] -ceq $ownerSource) { throw "path-value mutant not applied: $name" }
    [IO.File]::WriteAllText($reader,$cases[$name][1])
    [IO.File]::WriteAllText($owner,$(if($cases[$name].Count -gt 2){$cases[$name][2]}else{$ownerSource}))
    $c=Get-LedgerReaderCensus -Root $root
    $expected=[int]$cases[$name][0] -gt 0
    $readerRows=@($c.rows | Where-Object { $_.path -ceq 'reader.ps1' -and $_.role -ceq 'reader' })
    $violations=@($c.violations | Where-Object path -CEQ 'reader.ps1')
    $nativeUnknown=@($violations | Where-Object role -CEQ 'reader').Count
    $forwarding=@($violations | Where-Object role -CEQ 'path-forwarder')
    # Keep instance-derived forwarding uncertainty enforced independently of
    # the native path-value proof; neither inventory nor old mutants disappear.
    $badForwarding=@($forwarding | Where-Object { $_.family -cne 'get-nondispatchledgerpath' -or $_.authority -cne 'indeterminate' -or $_.handled -or $_.owner -or $_.test })
    $observed.Add([pscustomobject]@{case=$name;expectedNativeViolation=$expected;nativeViolations=$nativeUnknown;forwardingViolations=$forwarding.Count;violations=$violations.Count;allViolations=$c.violations.Count;rows=@($c.rows)})
    if ($c.scanned -ne 2 -or $c.total -ne 2 -or -not $readerRows.Count -or (($nativeUnknown -gt 0) -ne $expected) -or
        $violations.Count -ne ($nativeUnknown+$forwarding.Count) -or $badForwarding.Count -or
        ($name -ne 'missingGuardCall' -and $forwarding.Count -ne 1) -or ($name -eq 'missingGuardCall' -and $forwarding.Count -ne 0)) { $failures.Add($name) }
    Write-Output "PATH-VALUE case=$name nativeViolations=$nativeUnknown forwardingViolations=$($forwarding.Count) expectedNative=$([int]$expected) globalUnknown=$($c.violations.Count)"
  }
  if ($EvidencePath) { $observed.ToArray()|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $EvidencePath -Encoding utf8 }
  if ($failures.Count) { throw "SURVIVED path-value controls: $($failures -join ',')" }
  Write-Output "PASS ledger path-value controls=$($cases.Count) oneConversion=true guardBeforeNative=true realTrackedInventory=true"
} finally {
  $full=[IO.Path]::GetFullPath($root)
  if ((Split-Path -Parent $full).TrimEnd('\','/') -cne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/') -or (Split-Path -Leaf $full) -cnotlike 'ledger-path-value-*') { throw 'unsafe path-value fixture cleanup' }
  if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
}
