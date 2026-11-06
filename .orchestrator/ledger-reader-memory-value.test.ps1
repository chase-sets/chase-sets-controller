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
  $encoding=[Text.Encoding]::UTF8
  $encoding|Add-Member -MemberType ScriptMethod -Name GetBytes -Value {return ,([byte[]]@(99))} -Force
  try {
    Check ([Convert]::ToHexString([Text.Encoding]::UTF8.GetBytes('cost-ledger.jsonl')) -ceq '63') 'instance encoding result can be replaced by ETS'
  } finally {$encoding.PSObject.Members.Remove('GetBytes')}
  $literalCost=[byte[]][char[]](('cost-'+'ledger')+'.jsonl')
  Check ([Text.Encoding]::UTF8.GetString($literalCost) -ceq 'cost-ledger.jsonl') 'literal cost byte composition preserves decoded text'
  $replacementBytes=[byte[]][char[]]"dispatch-log.jsonl`n"
  $ordinaryBytes=[byte[]]::new($replacementBytes.Length)
  $ordinaryPath=Join-Path $root 'ordinary-bytes.json'
  [IO.File]::WriteAllBytes($ordinaryPath,$ordinaryBytes)
  $nativeFile=[IO.File]::OpenRead($ordinaryPath)
  try {
    $nativeFile|Add-Member -MemberType ScriptMethod -Name ReadExactly -Value ({param($bytes,$offset,$count) [Array]::Copy($replacementBytes,0,$bytes,$offset,$count)}.GetNewClosure()) -Force
    $returnedBytes=[byte[]]::new($nativeFile.Length)
    $nativeFile.ReadExactly($returnedBytes,0,$returnedBytes.Length)
    Check ([Text.Encoding]::UTF8.GetString($returnedBytes) -ceq "dispatch-log.jsonl`n") 'native stream instance can replace output bytes through ETS mutation'
    Check ([Convert]::ToHexString([IO.File]::ReadAllBytes($ordinaryPath)) -ceq [Convert]::ToHexString($ordinaryBytes)) 'instance output mutation does not change the ordinary input file'
  } finally {$nativeFile.Dispose()}
  [IO.File]::WriteAllText((Join-Path $root 'reader.ps1'),'# synthetic native memory operation')
  & git -C $root init -q
  & git -C $root add reader.ps1 .orchestrator/dispatch-ledger-reader.psm1
  & git -C $root -c user.name=Synthetic -c user.email=synthetic@example.invalid commit -qm memory-value
  Check ($LASTEXITCODE -eq 0) 'synthetic census HEAD'
  $import='Import-Module (Join-Path $PSScriptRoot ''.orchestrator/dispatch-ledger-reader.psm1'') -Global -DisableNameChecking'
  $copy='$bytes=dispatch-ledger-reader\Get-LedgerMemoryBytes -Stream $buffer'
  $decode='$reader=[IO.StreamReader]::new([IO.MemoryStream]::new($bytes,$false),[Text.Encoding]::UTF8,$true)'
  $reflection='[IO.File].GetMethod(''ReadAllBytes'',[type[]]@([string])).Invoke($null,[object[]]@([string]$Path))'
  $valid='$buffer=[IO.MemoryStream]::new();'+$copy+';'+$decode
  $cases=[ordered]@{
    exact=@($true,$valid)
    originalOpaque=@($false,$valid.Replace('dispatch-ledger-reader\Get-LedgerMemoryBytes -Stream $buffer','$buffer.ToArray()'))
    dispatchInput=@($false,('$buffer="dispatch-log.jsonl";'+$valid))
    uncertainInput=@($false,('$buffer=$other.ToArray();'+$valid))
    taintedResult=@($false,('$bytes="dispatch-log.jsonl";'+$valid))
    uncertainResult=@($false,('$bytes=$other.ToArray();'+$valid))
    reflectedRead=@($false,('$bytes=[IO.File].GetMethod(''ReadAllBytes'',[type[]]@([string])).Invoke($null,[object[]]@([string]$Path));'+$decode))
    propertyReceiver=@($false,('$bytes=[Text.Encoding]::UTF8.GetBytes($Text);'+$decode))
    factoryReceiver=@($false,('$bytes=[Text.Encoding]::GetEncoding(''utf-8'').GetBytes($Text);'+$decode))
    convertedReceiver=@($false,('$bytes=([Text.Encoding][Text.Encoding]::UTF8).GetBytes($Text);'+$decode))
    mixedNativeReceiver=@($false,('$bytes=if($takeData){[IO.File]::ReadAllBytes("ordinary.json")}else{[Text.Encoding]::UTF8.GetBytes($Text)};'+$decode))
    mixedOwnerReceiver=@($false,('$bytes=if($takeData){Read-DispatchLedgerSnapshot -Path "ordinary.json"}else{[Text.Encoding]::UTF8.GetBytes($Text)};'+$decode))
    mixedVariableReceiver=@($false,('$bytes=if($takeData){[IO.File]::ReadAllBytes("ordinary.json")}else{$other.ToArray()};'+$decode))
    pureNativeData=@($true,('$bytes=[IO.File]::ReadAllBytes("ordinary.json");'+$decode))
    instanceOwnerWrapper=@($false,('function Wrapper {Read-DispatchLedgerBytes -Path "ordinary.json"};$bytes=Wrapper;'+$decode))
    instanceOwnerTransitiveWrapper=@($false,('function Inner {Read-DispatchLedgerBytes -Path "ordinary.json"};function Wrapper {Inner};$bytes=Wrapper;'+$decode))
    pureNativeWrapper=@($true,('function Wrapper {[IO.File]::ReadAllBytes("ordinary.json")};$bytes=Wrapper;'+$decode))
    pureNativeTransitiveWrapper=@($true,('function Inner {[IO.File]::ReadAllBytes("ordinary.json")};function Wrapper {Inner};$bytes=Wrapper;'+$decode))
    wrapperProperty=@($false,('function Wrapper {if($takeData){Read-DispatchLedgerBytes -Path "ordinary.json"}else{[Text.Encoding]::UTF8.GetBytes($Text)}};$bytes=Wrapper;'+$decode))
    wrapperReflection=@($false,('function Wrapper {if($takeData){Read-DispatchLedgerBytes -Path "ordinary.json"}else{'+$reflection+'}};$bytes=Wrapper;'+$decode))
    wrapperInstanceTransitive=@($false,('function Inner {'+$reflection+'};function Wrapper {if($takeData){Read-DispatchLedgerBytes -Path "ordinary.json"}else{Inner}};$bytes=Wrapper;'+$decode))
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
    qualifiedBefore=@($false,('function global:dispatch-ledger-reader\Get-LedgerMemoryBytes {param($Stream) return ,([byte[]]@(99))}'+"`n"+$import+"`n"+$valid))
    qualifiedAfter=@($false,('function global:dispatch-ledger-reader\Get-LedgerMemoryBytes {param($Stream) return ,([byte[]]@(99))};'+$valid))
    providerReplacement=@($false,('Set-Item Function:global:dispatch-ledger-reader\Get-LedgerMemoryBytes {param($Stream) return ,([byte[]]@(99))};'+$valid))
    directoryProviderReplacement=@($false,('New-Item -Path Function:global:dispatch-ledger-reader\Get-LedgerMemoryBytes -ItemType Directory -Value {param($Stream) return ,([byte[]]@(99))};'+$valid))
    copyProviderAlias=@($false,('function Replacement {param($Stream) return ,([byte[]]@(99))};cp Function:Replacement Function:global:dispatch-ledger-reader\Get-LedgerMemoryBytes;'+$valid))
    copyProviderAliasLong=@($false,('function Replacement {param($Stream) return ,([byte[]]@(99))};copy Function:Replacement Function:global:dispatch-ledger-reader\Get-LedgerMemoryBytes;'+$valid))
    dynamicMutator=@($false,('$mutator="Set-Item";& $mutator Function:global:dispatch-ledger-reader\Get-LedgerMemoryBytes {param($Stream) return ,([byte[]]@(99))};'+$valid))
    wrapperOwner=@($false,('function Wrapper($buffer){if($choose){Read-DispatchLedgerSnapshot -Path "ordinary.json"}else{dispatch-ledger-reader\Get-LedgerMemoryBytes -Stream $buffer}};$buffer="dispatch-log.jsonl";$bytes=Wrapper $buffer;'+$decode))
    wrapperTransitive=@($false,('function Inner($buffer){if($choose){Read-DispatchLedgerSnapshot -Path "ordinary.json"}else{dispatch-ledger-reader\Get-LedgerMemoryBytes -Stream $buffer}};function Outer($buffer){Inner $buffer};$buffer="dispatch-log.jsonl";$bytes=Outer $buffer;'+$decode))
    wrapperUncertain=@($false,('function Wrapper($buffer){if($choose){Read-DispatchLedgerSnapshot -Path "ordinary.json"}else{dispatch-ledger-reader\Get-LedgerMemoryBytes -Stream $buffer}};$buffer=$other.ToArray();$bytes=Wrapper $buffer;'+$decode))
    wrapperOpaque=@($false,('function Wrapper($buffer){if($choose){Read-DispatchLedgerSnapshot -Path "ordinary.json"}else{& $cmd -Stream $buffer}};$bytes=Wrapper $buffer;'+$decode))
    dynamic=@($false,('$cmd="dispatch-ledger-reader\Get-LedgerMemoryBytes";'+$valid.Replace('dispatch-ledger-reader\Get-LedgerMemoryBytes','& $cmd')))
    aliasWithoutImport=@($false,('Set-Alias CopyBytes dispatch-ledger-reader\Get-LedgerMemoryBytes;'+$valid.Replace('dispatch-ledger-reader\Get-LedgerMemoryBytes','CopyBytes')))
    aliasBuiltinName=@($false,('Set-Alias Write-Output dispatch-ledger-reader\Get-LedgerMemoryBytes;'+$valid.Replace('dispatch-ledger-reader\Get-LedgerMemoryBytes','Write-Output')))
    dynamicMixedData=@($false,('$cmd="dispatch-ledger-reader\Get-LedgerMemoryBytes";$bytes=if($takeData){[IO.File]::ReadAllBytes("ordinary.json")}else{& $cmd -Stream $buffer};'+$decode))
    aliasMixedData=@($false,('Set-Alias CopyBytes dispatch-ledger-reader\Get-LedgerMemoryBytes;$bytes=if($takeData){Read-DispatchLedgerSnapshot -Path "ordinary.json"}else{CopyBytes -Stream $buffer};'+$decode))
  }
  foreach($scope in @('global','script','local','private')){
    $instanceWrapper='function '+$scope+':Inner {'+$reflection+'};function Wrapper {if($takeData){Read-DispatchLedgerBytes -Path "ordinary.json"}else{Inner}};$bytes=Wrapper;'+$decode
    $cases['instanceScopeWrapper'+$scope]=@($false,$instanceWrapper)
    $cases['instanceScopeCall'+$scope]=@($false,$instanceWrapper.Replace('else{Inner}','else{'+$scope+':Inner}'))
    $cases['instanceScopeUnscopedDefinition'+$scope]=@($false,$instanceWrapper.Replace(('function '+$scope+':Inner'),'function Inner').Replace('else{Inner}','else{'+$scope+':Inner}'))
    $wrapper='function '+$scope+':Inner($buffer){dispatch-ledger-reader\Get-LedgerMemoryBytes -Stream $buffer};function Outer($buffer){if($choose){Read-DispatchLedgerSnapshot -Path "ordinary.json"}else{Inner $buffer}};$buffer="dispatch-log.jsonl";$bytes=Outer $buffer;'+$decode
    $cases['scopeWrapper'+$scope]=@($false,$wrapper)
    $cases['scopeCall'+$scope]=@($false,$wrapper.Replace('else{Inner $buffer}','else{'+$scope+':Inner $buffer}'))
    $cases['scopeCallUnscopedDefinition'+$scope]=@($false,$wrapper.Replace(('function '+$scope+':Inner'),'function Inner').Replace('else{Inner $buffer}','else{'+$scope+':Inner $buffer}'))
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
    $prefix=if($name -cin @('backgroundImport','missingImport','lateImport','qualifiedBefore','aliasWithoutImport')){''}else{$import+"`n"}
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
