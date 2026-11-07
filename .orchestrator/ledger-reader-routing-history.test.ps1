$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'routing-data.ps1') -Library
$checks=0
function Check([bool]$Condition,[string]$Message) {
  $script:checks++
  if(-not $Condition){throw "ASSERTION FAILED: $Message"}
}
function Get-HistoryStamp {
  $item=Get-Item -LiteralPath $path
  $inputStream=[IO.File]::Open($path,'Open','Read','ReadWrite')
  try{$hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($inputStream))}finally{$inputStream.Dispose()}
  [pscustomobject]@{bytes=$item.Length;sha256=$hash;writeTicks=$item.LastWriteTimeUtc.Ticks}
}
function Check-WholeResult($Actual,$Expected,[string]$Message) {
  $actualJson=ConvertTo-Json -InputObject $Actual -Depth 100 -Compress
  $expectedJson=ConvertTo-Json -InputObject $Expected -Depth 100 -Compress
  Check ([Text.Json.Nodes.JsonNode]::DeepEquals([Text.Json.Nodes.JsonNode]::Parse($actualJson),
    [Text.Json.Nodes.JsonNode]::Parse($expectedJson))) $Message
}
function Read-CheckedRouting([string]$Stage) {
  $stamp=Get-HistoryStamp;$results=[ordered]@{}
  foreach($key in $scopes.Keys) {
    $scope=$scopes[$key]
    $results[$key]=Get-CapacityAuthorHistory -Path $path @scope -Registry $largeRegistry
  }
  Check-WholeResult (Get-HistoryStamp) $stamp "$Stage leaves input hash/length/lastwrite unchanged"
  Write-Output -InputObject $results -NoEnumerate
}
function New-HistoryControls([string]$FullPath,[string]$SuffixPath,[string]$PrefixPath,[int]$Rows) {
  $reader=[IO.StreamReader]::new($FullPath,[Text.UTF8Encoding]::new($false,$true))
  $suffix=[IO.StreamWriter]::new($SuffixPath,$false,[Text.UTF8Encoding]::new($false));$suffix.NewLine="`n"
  $prefix=[IO.StreamWriter]::new($PrefixPath,$false,[Text.UTF8Encoding]::new($false));$prefix.NewLine="`n"
  $count=0;$suffixRows=0;$prefixRows=0;$prefixBytes=0L;$prefixDone=$false;$firstExcludedBytes=0
  try {
    while($null-ne($line=$reader.ReadLine())) {
      $count++;$lineBytes=[Text.Encoding]::UTF8.GetByteCount($line)+1
      if($count-gt($Rows-50000)){$suffix.WriteLine($line);$suffixRows++}
      if(-not$prefixDone-and($prefixBytes+$lineBytes)-le32MB){
        $prefix.WriteLine($line);$prefixRows++;$prefixBytes+=$lineBytes
      }elseif(-not$prefixDone){$prefixDone=$true;$firstExcludedBytes=$lineBytes}
    }
  }finally{$reader.Dispose();$suffix.Dispose();$prefix.Dispose()}
  Check ($count-eq$Rows-and$suffixRows-eq50000) 'actual physical last-50000 suffix constructed'
  Check ($prefixBytes-le32MB-and$prefixBytes+$firstExcludedBytes-gt32MB) 'actual maximal line-complete 32MiB prefix constructed'
  [pscustomobject]@{rows=$count;suffixRows=$suffixRows;suffixBytes=(Get-Item $SuffixPath).Length;prefixRows=$prefixRows;prefixBytes=$prefixBytes}
}
function Check-LargeRouting {
  $largeRegistry=$registry|ConvertTo-Json -Depth 10|ConvertFrom-Json
  $largeRegistry.families|Add-Member -NotePropertyName gamma -NotePropertyValue ([pscustomobject]@{current='model-c';historical=@();provider='codex'})
  $third=$row.Replace('model-a','model-c')
  $scopes=[ordered]@{branch=@{Branch='synthetic'};issueAll=@{Issue=1;Artifact='all'}
    issueCode=@{Issue=1;Artifact='code'};issueBrief=@{Issue=1;Artifact='brief'}}
  $expected=[ordered]@{}
  foreach($key in $scopes.Keys) {
    $models=if($key-ceq'issueBrief'){@()}else{@('model-a','model-b')}
    $expected[$key]=[pscustomobject]@{complete=$true;models=@($models)}
  }
  [IO.File]::WriteAllText($path,$row+"`n"+$second+"`n",[Text.UTF8Encoding]::new($false))
  $oracle=Read-CheckedRouting 'small oracle'
  Check-WholeResult $oracle $expected 'whole small oracle preserves branch/issue all/code authors and empty brief array'
  $smallStamp=Get-HistoryStamp
  foreach($key in $scopes.Keys) {
    $scope=$scopes[$key]
    $baseline=Get-OriginalCapacityAuthorHistory -Path $path @scope -Registry $largeRegistry
    Check-WholeResult $oracle[$key] $baseline "whole small $key result equals immutable original native-reader fold"
  }
  Check-WholeResult (Get-HistoryStamp) $smallStamp 'immutable small-fold baseline preserves input hash/lastwrite'
  $padding=' '*700
  $stream=[IO.StreamWriter]::new($path,$false,[Text.UTF8Encoding]::new($false));$stream.NewLine="`n"
  try {
    $stream.WriteLine($row)
    for($i=0;$i-lt50000;$i++){$stream.WriteLine($padding)}
    $stream.WriteLine($second)
  }finally{$stream.Dispose()}
  $fullStamp=Get-HistoryStamp
  Check ($fullStamp.bytes-gt32MB) 'large actual routing input exceeds 32MiB'
  $fullPath=Join-Path $root 'full-history.jsonl';[IO.File]::Copy($path,$fullPath)
  $suffixPath=Join-Path $root 'suffix.jsonl';$prefixPath=Join-Path $root 'prefix.jsonl'
  $geometry=New-HistoryControls $fullPath $suffixPath $prefixPath 50002
  Check ($geometry.rows-gt50000) 'large actual routing input exceeds 50000 physical rows'
  $fullResult=Read-CheckedRouting 'full history'
  Check-WholeResult $fullResult $oracle 'whole large branch/issue all/code/brief results equal complete small oracle'
  try {
    [IO.File]::Copy($suffixPath,$path,$true)
    $suffixResult=Read-CheckedRouting 'actual suffix'
    [IO.File]::Copy($prefixPath,$path,$true)
    $prefixResult=Read-CheckedRouting 'actual byte prefix'
    foreach($key in $scopes.Keys) {
      $suffixModels=if($key-ceq'issueBrief'){@()}else{@('model-b')}
      $prefixModels=if($key-ceq'issueBrief'){@()}else{@('model-a')}
      Check-WholeResult $suffixResult[$key] ([pscustomobject]@{complete=$true;models=@($suffixModels)}) "whole suffix $key loses early sole author"
      Check-WholeResult $prefixResult[$key] ([pscustomobject]@{complete=$true;models=@($prefixModels)}) "whole byte prefix $key loses late distinct author"
    }
  }finally{
    [IO.File]::Copy($fullPath,$path,$true);[IO.File]::SetLastWriteTimeUtc($path,[datetime]::new($fullStamp.writeTicks,[DateTimeKind]::Utc))
  }
  Check-WholeResult (Get-HistoryStamp) $fullStamp 'restoration preserves original full bytes/hash/lastwrite'
  Check-WholeResult (Read-CheckedRouting 'restored full') $oracle 'restored full whole results equal small oracle'
  $writer=[IO.File]::Open($path,'Open','Write','ReadWrite')
  try {
    Check-WholeResult (Read-CheckedRouting 'held writer before append') $oracle 'full history remains equivalent under genuine held writer'
    [void]$writer.Seek(0,[IO.SeekOrigin]::End)
    $append=[Text.Encoding]::UTF8.GetBytes($third+"`n");$writer.Write($append,0,$append.Length);$writer.Flush($true)
    $appended=Read-CheckedRouting 'held writer after append'
    foreach($key in $scopes.Keys) {
      $models=if($key-ceq'issueBrief'){@()}else{@('model-a','model-b','model-c')}
      $expected[$key]=[pscustomobject]@{complete=$true;models=@($models)}
    }
    Check-WholeResult $appended $expected 'whole append results retain both prior authors and add the third admitted author exactly once'
    Check-WholeResult (Read-CheckedRouting 'held writer replay') $appended 'whole held-writer append replay is identical'
  }finally{$writer.Dispose()}
  Check-WholeResult (Read-CheckedRouting 'closed writer replay') $appended 'whole closed-writer replay is identical'
  $appendStamp=Get-HistoryStamp
  Check ($appendStamp.bytes-eq$fullStamp.bytes+$append.Length) 'append byte growth is exactly the third committed row'
  $appendReader=[IO.StreamReader]::new($path);$appendRows=0
  try{while($null-ne$appendReader.ReadLine()){$appendRows++}}finally{$appendReader.Dispose()}
  Check ($appendRows-eq50003) 'append retains every original physical row plus one'
  Write-Output ('QUALIFICATION routing '+([ordered]@{geometry=$geometry;fullStamp=$fullStamp;small=$oracle;full=$fullResult
    suffix=$suffixResult;prefix=$prefixResult;appended=$appended;appendRows=$appendRows;appendStamp=$appendStamp
    restoration=$true;replay=$true;padding='50000 whitespace-only 700-space rows; physical geometry only; rich-all-row and memory unqualified'}|ConvertTo-Json -Depth 100 -Compress))
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('ledger-routing-history-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try {
  $path=Join-Path $root 'dispatch-log.jsonl'
  $registry='{"families":{"alpha":{"current":"model-a","historical":[],"provider":"codex"},"beta":{"current":"model-b","historical":[],"provider":"claude"}}}'|ConvertFrom-Json
  $row='{"kind":"dispatch","laneRole":"implementation","branch":"synthetic","issue":1,"model":"model-a"}'
  $second=$row.Replace('model-a','model-b')
  [IO.File]::WriteAllText($path,$row+"`n",[Text.UTF8Encoding]::new($false))
  $writer=[IO.File]::Open($path,'Open','Write','ReadWrite')
  try {
    $history=Get-CapacityAuthorHistory -Path $path -Branch synthetic -Registry $registry
    Check ($history.complete -and ($history.models -join ',') -ceq 'model-a') 'complete author lineage remains readable while a genuine append writer holds the canonical ledger'
    [void]$writer.Seek(0,[IO.SeekOrigin]::End)
    $append=[Text.Encoding]::UTF8.GetBytes($second+"`n");$writer.Write($append,0,$append.Length);$writer.Flush($true)
    $history=Get-CapacityAuthorHistory -Path $path -Branch synthetic -Registry $registry
    Check ($history.complete -and (@($history.models|Sort-Object) -join ',') -ceq 'model-a,model-b') 'same held writer persists another author without losing or duplicating lineage'
  } finally {$writer.Dispose()}
  $old=@(& git -C (Split-Path $PSScriptRoot -Parent) show 'd0b12cc7d6b0012e98c26d89c6530b6259286a89:.orchestrator/routing-data.ps1') -join "`n"
  Check ($LASTEXITCODE -eq 0) 'exact pre-change history oracle available'
  $errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($old,[ref]$null,[ref]$errors)
  $function=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-CapacityAuthorHistory'},$true)
  Check ($errors.Count -eq 0 -and $null -ne $function) 'complete original history body selected'
  . ([scriptblock]::Create($function.Extent.Text.Replace('function Get-CapacityAuthorHistory {','function Get-OriginalCapacityAuthorHistory {')))
  foreach($bom in @($false,$true)) {
    foreach($text in @(($row+"`n"),($row+"`r`n`n"+$second+"`r`n"),($row+"`n"+$second),($row+"`n{malformed`n"),($row.Replace('"kind":','"KIND":"dispatch","kind":')+"`n"),'')) {
      [IO.File]::WriteAllText($path,$text,[Text.UTF8Encoding]::new($bom))
      $bytes=[IO.File]::ReadAllBytes($path)
      foreach($scope in @(@{Branch='synthetic'},@{Issue=1;Artifact='all'})) {
        $before=Get-OriginalCapacityAuthorHistory -Path $path @scope -Registry $registry
        $after=Get-CapacityAuthorHistory -Path $path @scope -Registry $registry
        Check (($before|ConvertTo-Json -Compress) -ceq ($after|ConvertTo-Json -Compress)) 'complete raw history fold preserves branch/issue results and strict unknowns against original native reader'
      }
      Check ([Convert]::ToHexString([IO.File]::ReadAllBytes($path)) -ceq [Convert]::ToHexString($bytes)) 'all projections leave exact bytes unchanged'
    }
  }
  [IO.File]::WriteAllText($path,$row+"`n",[Text.UTF8Encoding]::new($false))
  $held=[IO.File]::Open($path,'Open','ReadWrite','None')
  try {Check (-not (Get-CapacityAuthorHistory -Path $path -Branch synthetic -Registry $registry).complete) 'exclusive real handle still produces UNKNOWN'} finally {$held.Dispose()}
  [IO.File]::WriteAllBytes($path,[byte[]]@(123,34,255,34,125,10))
  Check (-not (Get-CapacityAuthorHistory -Path $path -Branch synthetic -Registry $registry).complete) 'invalid UTF8 remains UNKNOWN'
  $source=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'routing-data.ps1'))
  $ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$null,[ref]$null)
  $function=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-CapacityAuthorHistory'},$true)
  Check ($function.Extent.Text -match 'dispatch-ledger-reader\\Read-DispatchLedgerSnapshot -Path \$Path -RequireTerminated' -and $function.Extent.Text -notmatch 'StreamReader|BaseStream|IncludeUnterminated') 'canonical history has only a strict owner snapshot, never a non-dispatch guard or raw-tail opt-in'
  Check-LargeRouting
  Write-Output "PASS ledger-reader-routing-history checks=$checks realHeldWriter=true originalFold=preserved strictUnknowns=true"
} finally {
  $full=[IO.Path]::GetFullPath($root)
  if((Split-Path -Parent $full).TrimEnd('\','/') -cne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/') -or
    (Split-Path -Leaf $full) -cnotlike 'ledger-routing-history-*'){throw 'unsafe routing history fixture cleanup'}
  Remove-Item -LiteralPath $full -Recurse -Force
}
