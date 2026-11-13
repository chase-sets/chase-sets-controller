[CmdletBinding()]
param([string]$EvidencePath='')
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ledger-reader-census.psm1') -Force
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('ledger-provenance-'+[guid]::NewGuid().ToString('N'))
$observed=[Collections.Generic.List[object]]::new()
$failures=[Collections.Generic.List[string]]::new()
try {
  [void][IO.Directory]::CreateDirectory($temporary)
  & git -C $temporary init -q
  if ($LASTEXITCODE) { throw 'synthetic repository init failed' }
  $path=Join-Path $temporary 'reader.ps1'
  [IO.File]::WriteAllText($path,'# synthetic tracked source')
  & git -C $temporary add reader.ps1
  if ($LASTEXITCODE) { throw 'synthetic repository track failed' }
  & git -C $temporary -c user.name=Synthetic -c user.email=synthetic@example.invalid commit -qm provenance
  if ($LASTEXITCODE) { throw 'synthetic repository commit failed' }
  $cases=[ordered]@{
    uncertainHelper=@(0,'param($root,$name);$p="$root/$name";Invoke-Synthetic -Path $p')
    uncertainInstance=@(0,'param($root,$name,$x);$p="$root/$name";$x.Read($p)')
    mixedHelper=@(1,'param($root,$name);$p="dispatch-log.jsonl";if($name){$p="$root/$name"};Invoke-Synthetic -Path $p')
    mixedInstance=@(1,'param($root,$name,$x);$p="dispatch-log.jsonl";if($name){$p="$root/$name"};$x.Read($p)')
    mixedNativeRhs=@(1,'$p="dispatch-log.jsonl";$v=if($flag){[IO.File]::ReadAllBytes("receipt.json")}else{$p};Invoke-Unclassified -Value $v')
    shadowedParameter=@(0,'$Path="dispatch-log.jsonl";function Invoke-Synthetic {param($Path);Invoke-Unclassified -Path $Path};Invoke-Synthetic "receipt.json"')
    shadowedDefault=@(0,'$Path="dispatch-log.jsonl";function Invoke-Synthetic {param($Path="receipt.json");Invoke-Unclassified -Path $Path};Invoke-Synthetic')
    shadowedMixed=@(1,'$Path="dispatch-log.jsonl";function Invoke-Synthetic {param($Path);Invoke-Unclassified -Path $Path};Invoke-Synthetic "receipt.json";Invoke-Synthetic "dispatch-log.jsonl"')
    explicitScriptParameter=@(1,'$Path="dispatch-log.jsonl";function Invoke-Synthetic {param($Path);Invoke-Unclassified -Path $script:Path};Invoke-Synthetic "receipt.json"')
    unshadowedScript=@(1,'$Path="dispatch-log.jsonl";function Invoke-Synthetic {Invoke-Unclassified -Path $Path};Invoke-Synthetic')
    shadowedNative=@(1,'$Path="dispatch-log.jsonl";function Read-Synthetic {param([string]$Path);[IO.File]::ReadAllText($Path)};Read-Synthetic "receipt.json"')
    selfDefault=@(1,'$Path="dispatch-log.jsonl";function Invoke-Synthetic {param($Path=$Path);Invoke-Unclassified -Path $Path};Invoke-Synthetic')
    abbreviatedDispatch=@(1,'$Path="dispatch-log.jsonl";function Invoke-Synthetic {param($Path);Invoke-Unclassified -Path $Path};Invoke-Synthetic -Pa $Path')
    abbreviatedOther=@(0,'$Path="dispatch-log.jsonl";function Invoke-Synthetic {param($Path);Invoke-Unclassified -Path $Path};Invoke-Synthetic -Pa "receipt.json"')
    exactNamedDispatch=@(1,'$Path="dispatch-log.jsonl";function Invoke-Synthetic {param($Path,$PathOther);Invoke-Unclassified -Path $Path};Invoke-Synthetic -Path $Path')
    literal=@(1,'$p=Join-Path $HOME ''dispatch-log.jsonl'';[IO.File]::ReadAllText($p)')
    split=@(1,'$p=Join-Path $HOME (''dispatch-''+''log.jsonl'');[IO.File]::ReadAllText($p)')
    unknown=@(1,'param([string]$Path);[IO.File]::ReadAllText($Path)')
    forward=@(1,'function Get-SyntheticPath { Join-Path $HOME ''dispatch-log.jsonl'' };$p=Get-SyntheticPath;[IO.File]::ReadAllText($p)')
    abbrev=@(1,'function Read-Synthetic {param($Path);[IO.File]::ReadAllText($Path)};Read-Synthetic -Pa (Join-Path $HOME ''dispatch-log.jsonl'')')
    unknownType=@(0,'param($p);[Synthetic.IO]::UnknownReadFamily($p)')
    dispatchUnknownType=@(1,'$p=''dispatch-log.jsonl'';[Synthetic.IO]::UnknownReadFamily($p)')
    unknownAfterCost=@(1,'param($Path);$p=''cost-ledger.jsonl'';$p=$Path;[IO.File]::ReadAllText($p)')
    opaqueCostDefault=@(1,'param($Path=''cost-ledger.jsonl'');[IO.File]::ReadAllText($Path)')
    falseCostBranch=@(1,'$p=Join-Path $HOME ''dispatch-log.jsonl'';if($DispatchHistory){Write-Output ''noop''}else{[IO.File]::ReadAllText($p)}')
    bodyMention=@(1,'$p=Join-Path $HOME ''dispatch-log.jsonl'';if($true){Write-Output $DispatchHistory}else{[IO.File]::ReadAllText($p)}')
    nestedMention=@(1,'$p=Join-Path $HOME ''dispatch-log.jsonl'';if($true){if($DispatchHistory){Write-Output ''noop''}}else{[IO.File]::ReadAllText($p)}')
    csLiteral=@(1,'Add-Type ''class Synthetic {void Read(){foreach(var x in System.IO.File.ReadLines("dispatch-log.jsonl")) {}}}''')
    csSpaced=@(1,'Add-Type ''class Synthetic {void Read(){foreach(var x in File . ReadLines("dispatch-log.jsonl")) {}}}''')
    csAlias=@(1,'Add-Type ''using F = System.IO.File; class Synthetic {void Read(){foreach(var x in F.ReadLines("dispatch-log.jsonl")) {}}}''')
    csStatic=@(1,'Add-Type ''using static System.IO.File; class Synthetic {void Read(){foreach(var x in ReadLines("dispatch-log.jsonl")) {}}}''')
    csUnknown=@(1,'Add-Type ''class Synthetic {void Read(){Synthetic.IO.UnknownReadFamily("dispatch-log.jsonl");}}''')
    csOpaque=@(1,'Add-Type ''class Synthetic {void Read(string p){System.IO.File.ReadLines(p);}}''')
    csAliasOpaque=@(1,'Add-Type ''using F=System.IO.File;class Synthetic {void Read(string p){F.ReadLines(p);}}''')
    csStaticOpaque=@(1,'Add-Type ''using static System.IO.File;class Synthetic {void Read(string p){ReadLines(p);}}''')
    writerComment=@(1,'$p=''dispatch-log.jsonl'';[IO.File]::Open($p,[IO.FileMode]::Open,[IO.FileAccess]::Read <# [IO.FileAccess]::Write #>)')
    modeComment=@(1,'$p=''dispatch-log.jsonl'';[IO.File]::ReadAllText($p <# [IO.FileMode]::Create #>)')
    nativeWriter=@(0,'$p=''dispatch-log.jsonl'';[IO.File]::Open($p,[IO.FileMode]::Open,[IO.FileAccess]::Write)')
    nativeCreate=@(0,'$p=''dispatch-log.jsonl'';[IO.FileStream]::new($p,[IO.FileMode]::Create)')
    cost=@(0,'$p=Join-Path $HOME ''cost-ledger.jsonl'';[IO.File]::ReadAllText($p)')
    unrelated=@(0,'$p=Join-Path $HOME ''receipt.json'';[IO.File]::ReadAllText($p)')
    unrelatedLiteral=@(0,'[IO.File]::ReadAllText(''receipt.json'')')
    unrelatedAlias=@(0,'$p=Join-Path $HOME ''receipt.json'';$q=$p;[IO.File]::ReadAllText($q)')
    unknownAfterOther=@(1,'param($Path);$p=''receipt.json'';$p=$Path;[IO.File]::ReadAllText($p)')
    otherAssignedLater=@(1,'[IO.File]::ReadAllText($p);$p=''receipt.json''')
    otherAssignedConditionally=@(1,'if($false){$p=''receipt.json''};[IO.File]::ReadAllText($p)')
    otherPassedByReference=@(1,'$p=''receipt.json'';Set-Synthetic -Value ([ref]$p);[IO.File]::ReadAllText($p)')
    owned=@(0,'$p=Join-Path $HOME ''dispatch-log.jsonl'';Read-DispatchLedgerSnapshot -Path $p')
    alias=@(1,'$p=Join-Path $HOME ''dispatch-log.jsonl'';Set-Alias ledgerRead Get-Content;ledgerRead -LiteralPath $p')
  }
  foreach ($name in $cases.Keys) {
    [IO.File]::WriteAllText($path,$cases[$name][1])
    $result=Get-LedgerReaderCensus -Root $temporary
    $row=[pscustomobject]@{case=$name;expectedViolation=([int]$cases[$name][0] -gt 0);violations=$result.violations.Count;scanned=$result.scanned;total=$result.total;rows=@($result.rows)}
    $observed.Add($row)
    if ($result.scanned -ne 1 -or $result.total -ne 1 -or (($result.violations.Count -gt 0) -ne $row.expectedViolation)) { $failures.Add($name) }
    if ($name -in @('uncertainHelper','uncertainInstance','unknownType')) {
      $diagnostic=@($result.rows | Where-Object { -not $_.handled -and -not $_.dispatchInput -and -not $_.violationReason })
      if (-not $diagnostic.Count) { $failures.Add("diagnostic:$name") }
    }
    if ($name -in @('mixedHelper','mixedInstance','dispatchUnknownType','shadowedMixed','explicitScriptParameter','unshadowedScript')) {
      $dispatch=@($result.violations | Where-Object { $_.dispatchInput -and $_.violationReason -ceq 'dispatch-provenance' })
      if (-not $dispatch.Count) { $failures.Add("dispatch:$name") }
    }
    if ($name -ceq 'shadowedNative') {
      $native=@($result.violations | Where-Object { $_.family -ceq 'IO.File.ReadAllText' -and -not $_.dispatchInput -and $_.violationReason -ceq 'native-reader' })
      if ($native.Count -ne 1) { $failures.Add("native:$name") }
    }
    if ($name -in @('selfDefault','abbreviatedDispatch','exactNamedDispatch','mixedNativeRhs')) {
      $forwarded=@($result.violations | Where-Object { $_.family -ceq 'invoke-unclassified' -and $_.dispatchInput })
      if ($forwarded.Count -ne 1) { $failures.Add("forwarded:$name") }
    }
    Write-Output "PROVENANCE case=$name violations=$($result.violations.Count) expected=$($cases[$name][0])"
  }
  # Use the actual owner so its internal instance reads participate in the
  # transitive function analysis, not an unimplemented synthetic reader name.
  $ownerDirectory=Join-Path $temporary '.orchestrator'
  [void][IO.Directory]::CreateDirectory($ownerDirectory)
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1') -Destination $ownerDirectory
  & git -C $temporary add .orchestrator/dispatch-ledger-reader.psm1
  if ($LASTEXITCODE) { throw 'owner fixture track failed' }
  $ownerCases=[ordered]@{
    ownerData=@(0,'$Path="dispatch-log.jsonl";$snapshot=Read-DispatchLedgerSnapshot -Path $Path;Invoke-Unclassified -Value $snapshot')
    ownerDataMixed=@(1,'$Path="dispatch-log.jsonl";$snapshot=Read-DispatchLedgerSnapshot -Path $Path;$value=$snapshot;if($flag){$value=$Path};Invoke-Unclassified -Value $value')
    ownerDataOpaque=@(1,'$Path="dispatch-log.jsonl";$snapshot=& Read-DispatchLedgerSnapshot -Path $Path;Invoke-Unclassified -Value $snapshot')
    ownerDataNative=@(1,'$Path="dispatch-log.jsonl";$snapshot=Read-DispatchLedgerSnapshot -Path $Path;[IO.File]::ReadAllText($snapshot)')
    ownerDataConditional=@(0,'$p="dispatch-log.jsonl";$v=if($flag){Read-DispatchLedgerSnapshot -Path $p}else{Read-DispatchLedgerBytes -Path $p};Invoke-Unclassified -Value $v')
    ownerDataMixedRhs=@(1,'$p="dispatch-log.jsonl";$v=if($flag){Read-DispatchLedgerSnapshot -Path $p}else{$p};Invoke-Unclassified -Value $v')
    ownerDataMixedWrapper=@(2,'function Wrapper {param($p);if($flag){Read-DispatchLedgerSnapshot -Path $p}else{$p}};$v=Wrapper -p "dispatch-log.jsonl";Invoke-Unclassified -Value $v')
    ownerDataForeach=@(0,'$p="dispatch-log.jsonl";foreach($v in (Read-DispatchLedgerSnapshot -Path $p)){Invoke-Unclassified -Value $v}')
    ownerDataArgument=@(0,'$p="dispatch-log.jsonl";Invoke-Unclassified -Value (Read-DispatchLedgerSnapshot -Path $p)')
    ownerDataBound=@(0,'function Consumer {param($Value);Invoke-Unclassified -Value $Value};$p="dispatch-log.jsonl";Consumer -Value (Read-DispatchLedgerSnapshot -Path $p)')
    ownerDataStaticArgument=@(0,'$p="dispatch-log.jsonl";[Synthetic.IO]::UnknownReadFamily((Read-DispatchLedgerSnapshot -Path $p))')
    ownerDataMixedForeach=@(1,'$p="dispatch-log.jsonl";foreach($v in $(if($flag){Read-DispatchLedgerSnapshot -Path $p}else{$p})){Invoke-Unclassified -Value $v}')
    ownerDataMixedArgument=@(1,'$p="dispatch-log.jsonl";Invoke-Unclassified -Value $(if($flag){Read-DispatchLedgerSnapshot -Path $p}else{$p})')
    ownerDataMixedBound=@(1,'function Consumer {param($Value);Invoke-Unclassified -Value $Value};$p="dispatch-log.jsonl";Consumer -Value $(if($flag){Read-DispatchLedgerSnapshot -Path $p}else{$p})')
    ownerDataWrapper=@(0,'function Wrapper {param($p);Read-DispatchLedgerSnapshot -Path $p};$p="dispatch-log.jsonl";$v=Wrapper -p $p;Invoke-Unclassified -Value $v')
    ownerDataWrapperReturn=@(0,'function Wrapper {param($p);return (Read-DispatchLedgerSnapshot -Path $p)};$p="dispatch-log.jsonl";$v=Wrapper -p $p;Invoke-Unclassified -Value $v')
    ownerDataWrapperAssignment=@(0,'function Wrapper {param($p);$data=Read-DispatchLedgerSnapshot -Path $p;return $data};$p="dispatch-log.jsonl";$v=Wrapper -p $p;Invoke-Unclassified -Value $v')
    ownerDataWrapperTransitive=@(0,'function Wrapper {param($p);$data=Inner -p $p;return $data};function Inner {param($p);Read-DispatchLedgerSnapshot -Path $p};$p="dispatch-log.jsonl";$v=Wrapper -p $p;Invoke-Unclassified -Value $v')
    ownerDataWrapperNative=@(3,'function Wrapper {param($p);Read-DispatchLedgerSnapshot -Path $p;[IO.File]::ReadAllText($p)};$p="dispatch-log.jsonl";$v=Wrapper -p $p;Invoke-Unclassified -Value $v')
    ownerDataWrapperRawReturn=@(2,'function Wrapper {param($p);$data=Read-DispatchLedgerSnapshot -Path $p;return $p};$p="dispatch-log.jsonl";$v=Wrapper -p $p;Invoke-Unclassified -Value $v')
    ownerDataWrapperReassigned=@(2,'function Wrapper {param($p);$data=Read-DispatchLedgerSnapshot -Path $p;$data=$p;return $data};$p="dispatch-log.jsonl";$v=Wrapper -p $p;Invoke-Unclassified -Value $v')
    ownerDataWrapperDuplicate=@(2,'function Wrapper {param($p);Read-DispatchLedgerSnapshot -Path $p};function Wrapper {param($p);$p};$p="dispatch-log.jsonl";$v=Wrapper -p $p;Invoke-Unclassified -Value $v')
    ownerDataWrapperScopeCollision=@(2,'function Wrapper {param($p);Read-DispatchLedgerSnapshot -Path $p};function global:Wrapper {param($p);$p};$p="dispatch-log.jsonl";$v=Wrapper -p $p;Invoke-Unclassified -Value $v')
    ownerDataWrapperOpaque=@(2,'function Wrapper {param($p);& Read-DispatchLedgerSnapshot -Path $p};$p="dispatch-log.jsonl";$v=Wrapper -p $p;Invoke-Unclassified -Value $v')
    ownerDataWrapperTrap=@(2,'function Wrapper {param($p);trap {continue};Read-DispatchLedgerSnapshot -Path $p};$p="dispatch-log.jsonl";$v=Wrapper -p $p;Invoke-Unclassified -Value $v')
    ownerDataWrapperDefault=@(2,'function Wrapper {param($p=$(return "dispatch-log.jsonl"));Read-DispatchLedgerSnapshot -Path $p};$p="dispatch-log.jsonl";$v=Wrapper -p $p;Invoke-Unclassified -Value $v')
    ownerDataWrapperArgumentReturn=@(2,'function Wrapper {param($p);Read-DispatchLedgerSnapshot -Path $(return $p)};$p="dispatch-log.jsonl";$v=Wrapper -p $p;Invoke-Unclassified -Value $v')
    ownerDataWrapperAssignedArgumentReturn=@(2,'function Wrapper {param($p);$data=Read-DispatchLedgerSnapshot -Path $(if($flag){return $p}else{$p});return $data};$p="dispatch-log.jsonl";$v=Wrapper -p $p;Invoke-Unclassified -Value $v')
  }
  foreach ($name in $ownerCases.Keys) {
    [IO.File]::WriteAllText($path,$ownerCases[$name][1])
    $result=Get-LedgerReaderCensus -Root $temporary
    $violations=@($result.violations | Where-Object path -ceq 'reader.ps1')
    if ($result.scanned -ne 2 -or $result.total -ne 2 -or $violations.Count -ne $ownerCases[$name][0]) { $failures.Add($name) }
    if ($name -ceq 'ownerDataMixed' -and -not @($violations | Where-Object { $_.family -ceq 'invoke-unclassified' -and $_.dispatchInput }).Count) { $failures.Add("dispatch:$name") }
    if ($name -in @('ownerDataMixedRhs','ownerDataMixedWrapper','ownerDataMixedForeach','ownerDataMixedArgument','ownerDataMixedBound') -and @($violations | Where-Object { $_.family -ceq 'invoke-unclassified' -and $_.dispatchInput }).Count -ne 1) { $failures.Add("dispatch:$name") }
    if ($name -ceq 'ownerDataNative' -and -not @($violations | Where-Object { $_.family -ceq 'IO.File.ReadAllText' -and -not $_.dispatchInput -and $_.violationReason -ceq 'native-reader' }).Count) { $failures.Add("native:$name") }
    if ($name -like 'ownerDataWrapper*' -and $ownerCases[$name][0] -gt 0 -and @($violations | Where-Object { $_.family -ceq 'invoke-unclassified' -and $_.dispatchInput }).Count -ne 1) { $failures.Add("dispatch:$name") }
    if ($name -ceq 'ownerDataWrapperNative' -and @($violations | Where-Object { $_.family -ceq 'IO.File.ReadAllText' -and $_.dispatchInput }).Count -ne 1) { $failures.Add("native:$name") }
    $observed.Add([pscustomobject]@{case=$name;expectedViolation=([int]$ownerCases[$name][0] -gt 0);violations=$violations.Count;scanned=$result.scanned;total=$result.total;rows=@($result.rows)})
    Write-Output "PROVENANCE case=$name violations=$($violations.Count) expected=$($ownerCases[$name][0])"
  }
  if ($EvidencePath) { $observed.ToArray() | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $EvidencePath -Encoding utf8 }
  if ($failures.Count) { throw "SURVIVED provenance controls: $($failures -join ',')" }
  Write-Output "PASS ledger reader provenance controls=$($cases.Count+$ownerCases.Count) realTrackedInventory=true"
} finally {
  $full=[IO.Path]::GetFullPath($temporary)
  if ((Split-Path -Parent $full).TrimEnd('\','/') -cne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/') -or (Split-Path -Leaf $full) -cnotlike 'ledger-provenance-*') { throw 'unsafe provenance fixture cleanup' }
  if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
}
