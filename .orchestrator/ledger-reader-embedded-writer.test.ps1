[CmdletBinding()]
param([string]$EvidencePath='')
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ledger-reader-census.psm1') -Force
$root=Join-Path ([IO.Path]::GetTempPath()) ('ledger-embedded-writer-'+[guid]::NewGuid().ToString('N'))
$observed=[Collections.Generic.List[object]]::new();$failures=[Collections.Generic.List[string]]::new()
$prefix='using System.IO; class Synthetic { void M(string path) { '
$suffix=' } }'
$cases=[ordered]@{
  pathWrite=@(0,($prefix+'var s=new FileStream(path,FileMode.Open,FileAccess.Write);'+$suffix))
  handleWrite=@(0,'using System.IO;using Microsoft.Win32.SafeHandles;class Synthetic {void M(SafeFileHandle handle){var s=new FileStream(handle,FileAccess.Write);}}')
  namedWrite=@(0,($prefix+'var s=new FileStream(access:FileAccess.Write,path:path,mode:FileMode.Open);'+$suffix))
  qualifiedWrite=@(0,($prefix+'var s=new System.IO.FileStream(path,System.IO.FileMode.Open,System.IO.FileAccess.Write);'+$suffix))
  writerTrivia=@(0,($prefix+'var s=new FileStream /* stream */ (path,FileMode.Open, /* access */ FileAccess.Write);'+$suffix))
  pathRead=@(1,($prefix+'var s=new FileStream(path,FileMode.Open,FileAccess.Read);'+$suffix))
  readerTrivia=@(1,($prefix+'var s=new /* stream */ FileStream /* access */ (path,FileMode.Open,FileAccess.Read);'+$suffix))
  handleRead=@(1,'using System.IO;using Microsoft.Win32.SafeHandles;class Synthetic {void M(SafeFileHandle handle){var s=new FileStream(handle,FileAccess.Read);}}')
  readWrite=@(1,($prefix+'var s=new FileStream(path,FileMode.Open,FileAccess.ReadWrite);'+$suffix))
  defaultAccess=@(1,($prefix+'var s=new FileStream(path,FileMode.Open);'+$suffix))
  writeComment=@(1,($prefix+'var s=new FileStream(path,FileMode.Open,FileAccess.Read /* FileAccess.Write */);'+$suffix))
  writeString=@(1,($prefix+'var x="FileAccess.Write";var s=new FileStream(path,FileMode.Open,FileAccess.Read);'+$suffix))
  writeOtherArgument=@(1,($prefix+'var s=new FileStream("FileAccess.Write",FileMode.Open,FileAccess.Read);'+$suffix))
  dynamicAccess=@(1,'using System.IO;class Synthetic {void M(string path,FileAccess access){var s=new FileStream(path,FileMode.Open,access);}}')
  mutableAccess=@(1,($prefix+'var access=FileAccess.Write;access=FileAccess.Read;var s=new FileStream(path,FileMode.Open,access);'+$suffix))
  unknownEnum=@(1,'class Synthetic {void M(string path){var s=new FileStream(path,Unknown.Open,Unknown.Write);}}')
  fakeStream=@(1,'class FileStream {public FileStream(string p,int m,int a){}}class FileMode {public const int Open=3;}class FileAccess {public const int Write=2;}class Synthetic {void M(string p){var s=new FileStream(p,FileMode.Open,FileAccess.Write);}}')
  fakeEnum=@(1,'using System.IO;enum FileAccess { Write=1 }class Synthetic {void M(string p){var s=new FileStream(p,FileMode.Open,(System.IO.FileAccess)FileAccess.Write);}}')
  invalidCompilation=@(1,($prefix+'var s=new FileStream(path,FileMode.Open,FileAccess.Write);Missing();'+$suffix))
  readerSibling=@(1,($prefix+'var a=new FileStream(path,FileMode.Open,FileAccess.Write);var b=new FileStream(path,FileMode.Open,FileAccess.Read);'+$suffix))
  nativeReaderSibling=@(1,($prefix+'var s=new FileStream(path,FileMode.Open,FileAccess.Write);File.ReadAllText(path);'+$suffix))
  aliasReaderSibling=@(1,'using System.IO;using F=System.IO.File;class Synthetic {void M(string path){var s=new FileStream(path,FileMode.Open,FileAccess.Write);F.ReadAllText(path);}}')
  staticReaderSibling=@(1,'using System.IO;using static System.IO.File;class Synthetic {void M(string path){var s=new FileStream(path,FileMode.Open,FileAccess.Write);ReadAllText(path);}}')
  unknownReaderSibling=@(2,($prefix+'var s=new FileStream(path,FileMode.Open,FileAccess.Write);Unknown.ReadSomething(path);'+$suffix))
}
try {
  [void][IO.Directory]::CreateDirectory($root)
  $source=Join-Path $root 'reader.ps1'
  [IO.File]::WriteAllText($source,'# tracked synthetic source')
  & git -C $root init -q
  if($LASTEXITCODE){throw 'embedded writer fixture init failed'}
  & git -C $root add reader.ps1
  if($LASTEXITCODE){throw 'embedded writer fixture track failed'}
  & git -C $root -c user.name=Synthetic -c user.email=synthetic@example.invalid commit -qm embedded-writer
  if($LASTEXITCODE){throw 'embedded writer fixture commit failed'}
  foreach($name in $cases.Keys){
    # Bind syntax only; never emit or execute this untrusted C# payload.
    [IO.File]::WriteAllText($source,('Add-Type '''+$cases[$name][1]+''''))
    $census=Get-LedgerReaderCensus -Root $root
    $row=[pscustomobject]@{case=$name;expected=$cases[$name][0];violations=$census.violations.Count;rows=@($census.rows)}
    $observed.Add($row)
    $streams=@($census.rows|Where-Object family -CEQ 'embedded-C#.FileStream')
    if($census.total -ne 1 -or $census.scanned -ne 1 -or $census.violations.Count -ne $cases[$name][0] -or -not $streams.Count -or ($cases[$name][0] -eq 0 -and @($streams|Where-Object {$_.role -cne 'writer' -or -not $_.handled}).Count)){$failures.Add($name)}
    Write-Output "EMBEDDED-WRITER case=$name violations=$($census.violations.Count) expected=$($cases[$name][0])"
  }
  $production=[ordered]@{
    'controller-release-battery.ps1'=@('writer')
    'invoke-heavy-verifier.ps1'=@('reader','writer')
    'runtime-retention.ps1'=@('reader')
  }
  foreach($file in $production.Keys){
    [IO.File]::WriteAllText($source,[IO.File]::ReadAllText((Join-Path $PSScriptRoot $file)))
    $census=Get-LedgerReaderCensus -Root $root
    $streams=@($census.rows|Where-Object family -CEQ 'embedded-C#.FileStream')
    $roles=@($streams|ForEach-Object role)
    $observed.Add([pscustomobject]@{case=$file;expectedRoles=$production[$file];rows=$streams})
    if(($roles -join ',') -cne ($production[$file] -join ',')){$failures.Add($file)}
    Write-Output "EMBEDDED-WRITER production=$file roles=$($roles -join ',') expected=$($production[$file] -join ',')"
  }
  [IO.File]::WriteAllText($source,('Add-Type '''+$cases.readerTrivia[1]+''''))
  $unavailable=& (Get-Module ledger-reader-census) {
    param($Root)
    $saved=(Get-Item Function:Get-LedgerEmbeddedFileStreams).ScriptBlock
    try {
      Set-Item Function:script:Get-LedgerEmbeddedFileStreams { [pscustomobject]@{parsed=$false;sites=@()} }
      Get-LedgerReaderCensus -Root $Root
    } finally { Set-Item Function:script:Get-LedgerEmbeddedFileStreams $saved }
  } $root
  if($unavailable.violations.Count -ne 1 -or $unavailable.violations[0].family -cne 'embedded-C#.unclassified'){$failures.Add('syntaxUnavailable')}
  $observed.Add([pscustomobject]@{case='syntaxUnavailable';expected=1;violations=$unavailable.violations.Count;rows=@($unavailable.rows)})
  Write-Output "EMBEDDED-WRITER syntaxUnavailable violations=$($unavailable.violations.Count) expected=1"
  if($EvidencePath){$observed.ToArray()|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $EvidencePath -Encoding utf8}
  if($failures.Count){throw "SURVIVED embedded writer controls: $($failures -join ',')"}
  Write-Output "PASS embedded writer controls=$($cases.Count) production=$($production.Count) realTrackedInventory=true"
} finally {
  $full=[IO.Path]::GetFullPath($root)
  if((Split-Path -Parent $full).TrimEnd('\','/') -cne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/') -or (Split-Path -Leaf $full) -cnotlike 'ledger-embedded-writer-*'){throw 'unsafe embedded writer fixture cleanup'}
  if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}
}
