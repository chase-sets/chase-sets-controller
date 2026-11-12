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
    literal=@(1,'$p=Join-Path $HOME ''dispatch-log.jsonl'';[IO.File]::ReadAllText($p)')
    split=@(1,'$p=Join-Path $HOME (''dispatch-''+''log.jsonl'');[IO.File]::ReadAllText($p)')
    unknown=@(1,'param([string]$Path);[IO.File]::ReadAllText($Path)')
    forward=@(1,'function Get-SyntheticPath { Join-Path $HOME ''dispatch-log.jsonl'' };$p=Get-SyntheticPath;[IO.File]::ReadAllText($p)')
    abbrev=@(1,'function Read-Synthetic {param($Path);[IO.File]::ReadAllText($Path)};Read-Synthetic -Pa (Join-Path $HOME ''dispatch-log.jsonl'')')
    unknownType=@(1,'param($p);[Synthetic.IO]::UnknownReadFamily($p)')
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
    Write-Output "PROVENANCE case=$name violations=$($result.violations.Count) expected=$($cases[$name][0])"
  }
  if ($EvidencePath) { $observed.ToArray() | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $EvidencePath -Encoding utf8 }
  if ($failures.Count) { throw "SURVIVED provenance controls: $($failures -join ',')" }
  Write-Output "PASS ledger reader provenance controls=$($cases.Count) realTrackedInventory=true"
} finally {
  $full=[IO.Path]::GetFullPath($temporary)
  if ((Split-Path -Parent $full).TrimEnd('\','/') -cne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/') -or (Split-Path -Leaf $full) -cnotlike 'ledger-provenance-*') { throw 'unsafe provenance fixture cleanup' }
  if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
}
