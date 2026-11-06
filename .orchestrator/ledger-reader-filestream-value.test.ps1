$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'ledger-reader-census.psm1') -Force
$checks=0
function Check([bool]$Ok,[string]$Message){$script:checks++;if(-not $Ok){throw "ASSERTION FAILED: $Message"}}
Check ([bool](Get-Command 'dispatch-ledger-reader\Get-NonDispatchLedgerStream' -ErrorAction SilentlyContinue)) 'actual value-stream guard exported'
$root=Join-Path ([IO.Path]::GetTempPath()) ('ledger-stream-value-'+[guid]::NewGuid().ToString('N'))
try {
  [void][IO.Directory]::CreateDirectory((Join-Path $root '.orchestrator'))
  Copy-Item (Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1') (Join-Path $root '.orchestrator')
  $path=Join-Path $root 'ordinary.json'
  [IO.File]::WriteAllBytes($path,[byte[]]@(0xef,0xbb,0xbf,0x61,0x0d,0x0a,0xff,0x62))
  $stream=[IO.File]::Open($path,'Open','Read',([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
  try {
    $guarded=dispatch-ledger-reader\Get-NonDispatchLedgerStream -Stream $stream
    Check ([object]::ReferenceEquals($stream,$guarded) -and $stream.Position -eq 0 -and $stream.CanRead) 'identity, position and lifetime unchanged'
    foreach($bufferSize in @(128,1024)){
      $stream.Position=0
      $reader=[IO.StreamReader]::new((dispatch-ledger-reader\Get-NonDispatchLedgerStream -Stream $stream),[Text.Encoding]::UTF8,$true,$bufferSize,$true)
      try {Check ($reader.ReadToEnd() -ceq ("a`r`n"+[char]0xfffd+'b')) 'BOM CRLF replacement decoding unchanged'} finally {$reader.Dispose()}
      Check $stream.CanRead 'guard does not close caller stream'
    }
  } finally {$stream.Dispose()}
  Add-Type -TypeDefinition @'
using System.IO;
public class LedgerStreamValueSpoof : FileStream {
  public LedgerStreamValueSpoof(string path) : base(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite) {}
  public override string Name { get { return "ordinary.json"; } }
}
'@
  $refusals=0
  foreach($alias in @('dispatch-log.jsonl','DISPATCH-LOG.JSONL','dispatch-log.jsonl.','dispatch-log.jsonl ','dispatch-log.jsonl:stream')){
    $forbidden=Join-Path $root $alias
    [IO.File]::WriteAllText($forbidden,'inert')
    $stream=[IO.File]::Open($forbidden,'Open','Read','ReadWrite')
    try {
      $stream|Add-Member -MemberType NoteProperty -Name Name -Value 'ordinary.json' -Force
      $failure='';try {dispatch-ledger-reader\Get-NonDispatchLedgerStream -Stream $stream|Out-Null}catch{$failure=$_.Exception.Message}
      Check ($failure -match 'DISPATCH_LEDGER_OWNER_REQUIRED') "actual native Name defeats ETS spoof $alias"
      Check ($stream.Position -eq 0 -and $stream.CanRead) 'refusal neither reads nor disposes'
      $refusals++
    } finally {$stream.Dispose()}
  }
  $subclass=[LedgerStreamValueSpoof]::new((Join-Path $root 'dispatch-log.jsonl'))
  try {
    $subclass|Add-Member -MemberType ScriptMethod -Name GetType -Value {[IO.FileStream]} -Force
    $failure='';try {dispatch-ledger-reader\Get-NonDispatchLedgerStream -Stream $subclass|Out-Null}catch{$failure=$_.Exception.Message}
    Check ($failure -match 'NON_DISPATCH_FILE_STREAM_REQUIRED') 'CLR type defeats virtual Name and ETS GetType spoof'
  } finally {$subclass.Dispose()}
  $file=[IO.File]::Open((Join-Path $root 'dispatch-log.jsonl'),'Open','Read','ReadWrite')
  $anonymous=[IO.FileStream]::new($file.SafeFileHandle,[IO.FileAccess]::Read)
  try {
    $failure='';try {dispatch-ledger-reader\Get-NonDispatchLedgerStream -Stream $anonymous|Out-Null}catch{$failure=$_.Exception.Message}
    Check ($failure -match 'NON_DISPATCH_FILE_STREAM_REQUIRED' -and $anonymous.Position -eq 0) 'anonymous native handle cannot establish non-dispatch path authority'
  } finally {$anonymous.Dispose();$file.Dispose()}
  foreach($other in @([IO.MemoryStream]::new(),[pscustomobject]@{Name='ordinary.json'})){
    $failure='';try {dispatch-ledger-reader\Get-NonDispatchLedgerStream -Stream $other|Out-Null}catch{$failure=$_.Exception.Message}
    Check ([bool]$failure) 'non-file stream refuses, not converted to path'
    if($other -is [IDisposable]){$other.Dispose()}
  }
  $source=Join-Path $root 'reader.ps1'
  [IO.File]::WriteAllText($source,'# synthetic value-stream proof')
  & git -C $root init -q
  & git -C $root add reader.ps1 .orchestrator/dispatch-ledger-reader.psm1
  & git -C $root -c user.name=Synthetic -c user.email=synthetic@example.invalid commit -qm value-stream
  Check ($LASTEXITCODE -eq 0) 'synthetic census HEAD'
  $import='Import-Module (Join-Path $PSScriptRoot ''.orchestrator/dispatch-ledger-reader.psm1'') -Global -DisableNameChecking'
  $operand='(dispatch-ledger-reader\Get-NonDispatchLedgerStream -Stream $stream)'
  $read='$reader=[IO.StreamReader]::new('+$operand+',[Text.Encoding]::UTF8,$true)'
  $cases=[ordered]@{
    guarded=@($true,$read)
    strictFive=@($true,($read.Replace('[Text.Encoding]::UTF8,$true','[Text.UTF8Encoding]::new($false,$true),$false,1024,$true')))
    reassignedGuardedValue=@($true,('$stream=$Other;'+$read))
    constantStorageGuardedValue=@($true,('Set-Variable stream $Other -Option Constant;'+$read))
    removedGuard=@($false,$read.Replace($operand,'$stream'))
    unqualified=@($false,$read.Replace('dispatch-ledger-reader\',''))
    wrongModule=@($false,$read.Replace('dispatch-ledger-reader\','other\'))
    wrongParameter=@($false,$read.Replace('-Stream','-Path'))
    inlineParameter=@($false,$read.Replace('-Stream $stream','-Stream:$stream'))
    extraParameter=@($false,$read.Replace('-Stream $stream','-Stream $stream -Verbose'))
    pipedGuard=@($false,$read.Replace('-Stream $stream)','-Stream $stream | Select-Object -First 1)'))
    transformedOutput=@($false,$read.Replace($operand,('([string]'+$operand+')')))
    assignedOutput=@($false,('$value='+$operand+';$reader=[IO.StreamReader]::new($value)'))
    genericReader=@($false,$read.Replace('::new(','::new[int]('))
    extraReaderArgument=@($false,$read.Replace('$true)','$true,1,2,3)'))
    continuingTrap=@($false,('trap {continue};'+$read))
    rethrowTrap=@($true,('trap {throw $_.Exception};'+$read))
    missingImport=@($false,$read)
    lateImport=@($false,$read)
  }
  foreach($name in $cases.Keys){
    $prefix=if($name -cin @('missingImport','lateImport')){''}else{$import+"`n"}
    $text=$prefix+$cases[$name][1]+$(if($name -ceq 'lateImport'){"`n"+$import}else{''})
    $c=Get-LedgerReaderCensus -Root $root -SourceOverride @{'reader.ps1'=$text}
    $rows=@($c.rows|Where-Object {$_.path -ceq 'reader.ps1' -and $_.family -ceq 'StreamReader'})
    Check ($c.scanned -eq 2 -and $c.total -eq 2 -and $rows.Count -eq 1) "complete exact native inventory $name"
    Check ([bool]$rows[0].handled -eq $cases[$name][0]) "value-stream per-use proof $name"
  }
  $module=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1'))
  foreach($mutation in @(
    $module.Replace("[object].GetMethod('GetType').Invoke(`$Stream,`$null)",'$Stream.GetType()'),
    $module.Replace("[IO.FileStream].GetProperty('Name').GetValue(`$Stream)",'$Stream.Name'),
    $module.Replace("  if (-not [IO.Path]::IsPathFullyQualified(`$path)) { throw 'NON_DISPATCH_FILE_STREAM_REQUIRED' }",'# removed native name completeness'),
    $module.Replace('dispatch-ledger-reader\Assert-NonDispatchLedgerPath -Path $path','# removed stream assertion'),
    $module.Replace(',Get-NonDispatchLedgerStream,',','))){
    Check ($mutation -cne $module) 'authentication mutation changes actual module'
    $c=Get-LedgerReaderCensus -Root $root -SourceOverride @{'reader.ps1'=($import+"`n"+$read);'.orchestrator/dispatch-ledger-reader.psm1'=$mutation}
    $row=@($c.rows|Where-Object {$_.path -ceq 'reader.ps1' -and $_.family -ceq 'StreamReader'})
    Check ($row.Count -eq 1 -and -not $row[0].handled) 'tampered body/export never grants authority'
  }
  $actualSites=0;$actualRefusals=0;$actualRemovalReads=0
  foreach($file in @('controller-install-lock.psm1','controller-release-battery.ps1','invoke-heavy-verifier.ps1','landed-integration-evidence.psm1')){
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $file),[ref]$null,[ref]$null)
    $sites=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Static -and $n.Expression.Extent.Text -ceq '[IO.StreamReader]' -and $n.Member.Value -ceq 'new' -and $n.Arguments[0].Extent.Text -ceq $operand},$true))
    Check ($sites.Count -eq $(if($file -ceq 'controller-release-battery.ps1'){2}else{1})) "actual guarded constructor cardinality $file"
    foreach($site in $sites){
      $actualSites++
      $nativeOwner=$true;$encoding=[Text.UTF8Encoding]::new($false,$true)
      $expectedByBytes=@{}
      foreach($mode in @('actual','guardRemoval')){
        $expression=if($mode -ceq 'actual'){$site.Extent.Text}else{$site.Extent.Text.Replace($operand,'$stream')}
        $probe=[scriptblock]::Create('$reader='+$expression+';try {$reader.ReadToEnd()} finally {$reader.Dispose()}')
        foreach($inputBytes in @([Text.Encoding]::UTF8.GetBytes("ordinary`r`n"),[byte[]]@(0xef,0xbb,0xbf,0x61,0xff,0x62))){
          [IO.File]::WriteAllBytes($path,$inputBytes)
          $stream=[IO.File]::Open($path,'Open','Read','ReadWrite')
          try {
            $result='';$failure='';try {$result=& $probe}catch{$failure=$_.Exception.GetBaseException().GetType().FullName}
            $observed=[ordered]@{result=$result;failure=$failure}|ConvertTo-Json -Compress
            if($mode -ceq 'actual'){$expectedByBytes[[Convert]::ToHexString($inputBytes)]=$observed}
            else {Check ($observed -ceq $expectedByBytes[[Convert]::ToHexString($inputBytes)]) "actual decoder text/strictness unchanged $file/$($site.Extent.StartLineNumber)"}
          } finally {$stream.Dispose()}
        }
        $stream=[IO.File]::Open((Join-Path $root 'dispatch-log.jsonl'),'Open','Read','ReadWrite')
        try {
          $failure='';$result='';try {$result=& $probe}catch{$failure=$_.Exception.Message}
          if($mode -ceq 'actual'){Check ($failure -match 'DISPATCH_LEDGER_OWNER_REQUIRED' -and $stream.Position -eq 0 -and $stream.CanRead) 'actual decoder refuses before native read';$actualRefusals++}
          else {Check (-not $failure -and $result -ceq 'inert') 'actual guard-removal reads forbidden synthetic bytes';$actualRemovalReads++}
        } finally {$stream.Dispose()}
      }
    }
  }
  "PASS file-stream value guard checks=$checks cases=$($cases.Count) nativeNameRefusals=$refusals bodyExportMutants=5 actualSites=$actualSites actualRefusals=$actualRefusals actualGuardRemovalReads=$actualRemovalReads"
} finally {
  $full=[IO.Path]::GetFullPath($root)
  if((Split-Path -Parent $full).TrimEnd('\','/') -cne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/') -or (Split-Path -Leaf $full) -notlike 'ledger-stream-value-*'){throw 'unsafe fixture cleanup'}
  if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}
}
