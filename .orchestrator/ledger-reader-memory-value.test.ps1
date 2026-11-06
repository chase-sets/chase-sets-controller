$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'ledger-reader-census.psm1') -Force
$checks=0
function Check([bool]$Ok,[string]$Message){$script:checks++;if(-not $Ok){throw "ASSERTION FAILED: $Message"}}
Check ([bool](Get-Command 'dispatch-ledger-reader\Get-LedgerMemoryBytes' -ErrorAction SilentlyContinue)) 'native memory operation exported'
$root=Join-Path ([IO.Path]::GetTempPath()) ('ledger-memory-value-'+[guid]::NewGuid().ToString('N'))
try {
  [void][IO.Directory]::CreateDirectory((Join-Path $root '.orchestrator'))
  Copy-Item (Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1') (Join-Path $root '.orchestrator')
  foreach($bytes in @([byte[]]@(),[byte[]]@(7),[byte[]]@(0,255,13,10,239,187,191))){
    $stream=[IO.MemoryStream]::new()
    try {
      $stream.Write($bytes,0,$bytes.Length)
      $stream.Position=0
      $copied=dispatch-ledger-reader\Get-LedgerMemoryBytes -Stream $stream
      Check ($copied -is [byte[]] -and [Convert]::ToHexString($copied) -ceq [Convert]::ToHexString($bytes)) 'empty/single/multiple bytes preserved without pipeline enumeration'
      Check ($stream.Position -eq 0 -and $stream.CanRead -and $stream.CanWrite) 'copy does not seek, consume or dispose'
      if($copied.Length){$copied[0]=$copied[0] -bxor 1;Check ($stream.ToArray()[0] -eq $bytes[0]) 'independent snapshot allocation'}
      $stream|Add-Member -MemberType ScriptMethod -Name ToArray -Value {throw 'ETS ToArray must not execute'} -Force
      $copied=dispatch-ledger-reader\Get-LedgerMemoryBytes -Stream $stream
      Check ([Convert]::ToHexString($copied) -ceq [Convert]::ToHexString($bytes)) 'native operation bypasses ETS method spoof'
      $stream.Dispose()
      $copied=dispatch-ledger-reader\Get-LedgerMemoryBytes -Stream $stream
      Check ([Convert]::ToHexString($copied) -ceq [Convert]::ToHexString($bytes)) 'native ToArray remains valid after disposal'
    } finally {$stream.Dispose()}
  }
  Add-Type -TypeDefinition @'
using System.IO;
public class LedgerMemoryValueSpoof : MemoryStream {
  public override byte[] ToArray() { return new byte[] { 99 }; }
}
'@
  $subclass=[LedgerMemoryValueSpoof]::new()
  try {
    $subclass|Add-Member -MemberType ScriptMethod -Name GetType -Value {[IO.MemoryStream]} -Force
    $failure='';try {dispatch-ledger-reader\Get-LedgerMemoryBytes -Stream $subclass|Out-Null}catch{$failure=$_.Exception.Message}
    Check ($failure -match 'NATIVE_MEMORY_STREAM_REQUIRED') 'exact CLR type rejects virtual method and ETS type spoof'
  } finally {$subclass.Dispose()}
  foreach($value in @($null,[pscustomobject]@{ToArray='inert'},[IO.StringReader]::new('inert'))){
    $failure='';try {dispatch-ledger-reader\Get-LedgerMemoryBytes -Stream $value|Out-Null}catch{$failure=$_.Exception.Message}
    Check ([bool]$failure) 'non-native memory input refuses'
    if($value -is [IDisposable]){$value.Dispose()}
  }
  [IO.File]::WriteAllText((Join-Path $root 'reader.ps1'),'# synthetic native memory operation')
  & git -C $root init -q
  & git -C $root add reader.ps1 .orchestrator/dispatch-ledger-reader.psm1
  & git -C $root -c user.name=Synthetic -c user.email=synthetic@example.invalid commit -qm memory-value
  Check ($LASTEXITCODE -eq 0) 'synthetic census HEAD'
  $import='Import-Module (Join-Path $PSScriptRoot ''.orchestrator/dispatch-ledger-reader.psm1'') -Global -DisableNameChecking'
  $copy='$bytes=dispatch-ledger-reader\Get-LedgerMemoryBytes -Stream $buffer'
  $decode='$reader=[IO.StreamReader]::new([IO.MemoryStream]::new($bytes,$false),[Text.Encoding]::UTF8,$true)'
  $valid='$buffer=[IO.MemoryStream]::new();'+$copy+';'+$decode
  $cases=[ordered]@{
    exact=@($true,$valid)
    originalOpaque=@($false,$valid.Replace('dispatch-ledger-reader\Get-LedgerMemoryBytes -Stream $buffer','$buffer.ToArray()'))
    dispatchInput=@($false,('$buffer="dispatch-log.jsonl";'+$valid))
    uncertainInput=@($false,('$buffer=$other.ToArray();'+$valid))
    taintedResult=@($false,('$bytes="dispatch-log.jsonl";'+$valid))
    uncertainResult=@($false,('$bytes=$other.ToArray();'+$valid))
    mixedDataRead=@($false,('$buffer="dispatch-log.jsonl";$bytes=if($takeData){[IO.File]::ReadAllBytes("ordinary.json")}else{dispatch-ledger-reader\Get-LedgerMemoryBytes -Stream $buffer};'+$decode))
    mixedOwnerCall=@($false,('$buffer="dispatch-log.jsonl";$bytes=if($takeData){Read-DispatchLedgerSnapshot -Path "ordinary.json"}else{dispatch-ledger-reader\Get-LedgerMemoryBytes -Stream $buffer};'+$decode))
    unqualified=@($false,$valid.Replace('dispatch-ledger-reader\',''))
    wrongModule=@($false,$valid.Replace('dispatch-ledger-reader\','other\'))
    wrongParameter=@($false,$valid.Replace('-Stream','-Path'))
    extraParameter=@($false,$valid.Replace('-Stream $buffer','-Stream $buffer -Verbose'))
    inlineParameter=@($false,$valid.Replace('-Stream $buffer','-Stream:$buffer'))
    piped=@($false,$valid.Replace('-Stream $buffer;','-Stream $buffer | Select-Object -First 1;'))
    redirected=@($false,$valid.Replace('-Stream $buffer;','-Stream $buffer 2>$null;'))
    background=@($false,$valid.Replace('-Stream $buffer;','-Stream $buffer &'+"`n"))
    continuingTrap=@($false,('trap {continue};'+$valid))
    terminalTrap=@($true,('trap {throw $_.Exception};'+$valid))
    backgroundImport=@($false,($import+" &`n"+$valid))
    missingImport=@($false,$valid)
    lateImport=@($false,($valid+"`n"+$import))
  }
  function CensusRow([string]$Text,[string]$Module=''){
    $overrides=@{'reader.ps1'=$Text}
    if($Module){$overrides['.orchestrator/dispatch-ledger-reader.psm1']=$Module}
    $c=Get-LedgerReaderCensus -Root $root -SourceOverride $overrides
    $row=@($c.rows|Where-Object {$_.path -ceq 'reader.ps1' -and $_.family -ceq 'StreamReader'})
    Check ($c.scanned -eq 2 -and $c.total -eq 2 -and $row.Count -eq 1) 'complete native decoder inventory'
    return $row[0]
  }
  foreach($name in $cases.Keys){
    $prefix=if($name -cin @('backgroundImport','missingImport','lateImport')){''}else{$import+"`n"}
    $row=CensusRow ($prefix+$cases[$name][1])
    Check ([bool]$row.handled -eq $cases[$name][0]) "memory operation proof preserves uncertainty $name"
  }
  $module=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1'))
  $ast=[Management.Automation.Language.Parser]::ParseInput($module,[ref]$null,[ref]$null)
  $definition=@($ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -ceq 'Get-LedgerMemoryBytes'})[0].Extent.Text
  $mutants=@(
    $module.Replace("[object].GetMethod('GetType').Invoke(`$Stream,`$null)",'$Stream.GetType()'),
    $module.Replace("[IO.MemoryStream].GetMethod('ToArray', [type[]]@()).Invoke(`$Stream,`$null)",'$Stream.ToArray()'),
    $module.Replace(',Get-LedgerMemoryBytes,',','),
    $module.Replace($definition,('function Dormant {'+$definition+'}')),
    $module.Replace($definition,('function Get-LedgerMemoryBytes {param($Stream) Read-DispatchLedgerSnapshot -Path "ordinary.json"; return ,([byte[]]@(1))}')),
    ($module+"`n"+'Set-Item -Path Function:Get-LedgerMemoryBytes -Value {param($Stream) [byte[]]@(1)}'))
  foreach($scope in @('script','global','local','private')){$mutants+=($module+"`n"+'function '+$scope+':Get-LedgerMemoryBytes {param($Stream) [byte[]]@(1)}')}
  foreach($mutation in $mutants){
    Check ($mutation -cne $module) 'module mutant changes actual source'
    $row=CensusRow ($import+"`n"+$valid) $mutation
    Check (-not $row.handled) 'tampered operation/export/binding retains decoder refusal'
  }
  $entry=Join-Path $PSScriptRoot 'invoke-heavy-verifier.ps1'
  $heavy=[Management.Automation.Language.Parser]::ParseFile($entry,[ref]$null,[ref]$null)
  foreach($name in @('Test-SamePath','Test-SafeDirectory','Test-SafeFile','Read-NativeJson','Get-OwnerSnapshot')){
    $fn=@($heavy.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true))
    Check ($fn.Count -eq 1) "one actual body $name"
    . ([scriptblock]::Create($fn[0].Extent.Text))
    if($name -ceq 'Get-OwnerSnapshot'){$actual=$fn[0].Extent.Text}
  }
  $operation='dispatch-ledger-reader\Get-LedgerMemoryBytes -Stream $buffer'
  Check ($actual.Split($operation,[StringSplitOptions]::None).Count -eq 2) 'actual owner snapshot uses exact native copy once'
  $before=$actual.Replace('function Get-OwnerSnapshot(', 'function Get-PriorOwnerSnapshot(').Replace($operation,'$buffer.ToArray()')
  . ([scriptblock]::Create($before))
  $lockPath=Join-Path $root 'verify-lock.d';[void][IO.Directory]::CreateDirectory($lockPath)
  $ownerPath=Join-Path $lockPath 'owner.json'
  $encodings=@([Text.UTF8Encoding]::new($false),[Text.UTF8Encoding]::new($true),[Text.UnicodeEncoding]::new($false,$true),[Text.UnicodeEncoding]::new($true,$true),[Text.UTF32Encoding]::new($false,$true),[Text.UTF32Encoding]::new($true,$true))
  foreach($encoding in $encodings){foreach($schema in @(4,6)){
    $json='{"schemaVersion":'+$schema+',"text":"caf'+[char]0xe9+'"}'
    [IO.File]::WriteAllBytes($ownerPath,([byte[]]($encoding.GetPreamble()+$encoding.GetBytes($json))))
    $old=Get-PriorOwnerSnapshot;$new=Get-OwnerSnapshot
    Check (($old|ConvertTo-Json -Depth 10 -Compress) -ceq ($new|ConvertTo-Json -Depth 10 -Compress)) "actual owner snapshot parity $($encoding.CodePage)/$schema"
  }}
  foreach($schema in @(4,6)){
    $bytes=[Text.Encoding]::UTF8.GetBytes(('{"schemaVersion":'+$schema+',"text":"x"}'));$bytes[$bytes.Length-3]=255
    [IO.File]::WriteAllBytes($ownerPath,$bytes)
    $old=Get-PriorOwnerSnapshot;$new=Get-OwnerSnapshot
    Check (($old|ConvertTo-Json -Depth 10 -Compress) -ceq ($new|ConvertTo-Json -Depth 10 -Compress)) "actual invalid UTF8 parity schema $schema"
    Check (($schema -eq 4 -and $null -ne $new) -or ($schema -eq 6 -and $null -eq $new)) 'legacy replacement and native strict refusal unchanged'
  }
  "PASS memory-value checks=$checks cases=$($cases.Count) moduleMutants=$($mutants.Count) actualEncodingCases=14"
} finally {
  $full=[IO.Path]::GetFullPath($root)
  if((Split-Path -Parent $full).TrimEnd('\','/') -cne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/') -or (Split-Path -Leaf $full) -notlike 'ledger-memory-value-*'){throw 'unsafe fixture cleanup'}
  if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}
}
