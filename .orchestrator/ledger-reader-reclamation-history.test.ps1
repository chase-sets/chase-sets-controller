$ErrorActionPreference='Stop'
$checks=0
function Check([bool]$Condition,[string]$Message){$script:checks++;if(-not$Condition){throw "ASSERTION FAILED: $Message"}}
Import-Module (Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1') -Global -DisableNameChecking
$source=Join-Path $PSScriptRoot 'cleanup-orphan-worktree-dirs.ps1'
$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$null,[ref]$e)
Check ($e.Count-eq0) 'actual reclamation source parses'
foreach($name in @('Get-ReclamationPath','Get-ReclamationDispatch')){
  $nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-ceq$name},$true))
  Check ($nodes.Count-eq1) "one actual $name function"
  . ([scriptblock]::Create($nodes[0].Extent.Text))
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('ledger-reclamation-history-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$path=Join-Path $root 'dispatch-log.jsonl'
$worktree=Join-Path $root 'synthetic-lane';$branch='codex/synthetic-reclamation'
$old=([ordered]@{worktree=$worktree;branch=$branch;attemptId='900001-old'}|ConvertTo-Json -Compress)
$new=([ordered]@{worktree=$worktree;branch=$branch;attemptId='900002-new'}|ConvertTo-Json -Compress)
function Write-History([string]$Text,[bool]$Bom=$false){[IO.File]::WriteAllText($path,$Text,[Text.UTF8Encoding]::new($Bom))}
function Check-PartialRefusal {
  foreach($bom in @($false,$true)){
    foreach($prefix in @('',($old+"`n"))){
      foreach($tail in @($new,'{')){
        Write-History ($prefix+$tail) $bom
        $before=[Convert]::ToHexString([IO.File]::ReadAllBytes($path))
        $r=Get-ReclamationDispatch $root
        Check (-not$r.complete-and$r.paths.Count-eq0-and$r.branches.Count-eq0) 'partial authority refuses without retaining older identity'
        Check ([Convert]::ToHexString([IO.File]::ReadAllBytes($path))-ceq$before) 'partial bytes unchanged'
      }
    }
  }
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
function Read-CheckedReclamation([string]$Stage) {
  $stamp=Get-HistoryStamp
  $result=Get-ReclamationDispatch $root
  Check-WholeResult (Get-HistoryStamp) $stamp "$Stage leaves input hash/length/lastwrite unchanged"
  Write-Output -InputObject $result -NoEnumerate
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
function Check-LargeReclamation {
  $otherWorktree=Join-Path $root 'synthetic-other';$otherBranch='codex/synthetic-other'
  $early=([ordered]@{worktree=$otherWorktree;branch=$otherBranch;attemptId='910001-sole'}|ConvertTo-Json -Compress)
  $third=([ordered]@{worktree=$worktree;branch=$branch;attemptId='900003-appended'}|ConvertTo-Json -Compress)
  $expectedPaths=@{};$expectedBranches=@{}
  foreach($raw in @($early,$new)) {
    $row=$raw|ConvertFrom-Json
    $entry=[pscustomobject]@{path=$row.worktree;branch=$row.branch;attemptId=$row.attemptId
      fingerprint=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($raw)))}
    $expectedPaths[$entry.path]=$entry;$expectedBranches[$entry.branch]=$entry
  }
  $expected=[pscustomobject]@{complete=$true;paths=$expectedPaths;branches=$expectedBranches}
  Write-History ($early+"`n"+$old+"`n"+$new+"`n")
  $oracle=Read-CheckedReclamation 'small oracle'
  Check-WholeResult $oracle $expected 'whole small oracle has both exact path/branch identities and fingerprints'
  $padding=' '*700
  $stream=[IO.StreamWriter]::new($path,$false,[Text.UTF8Encoding]::new($false));$stream.NewLine="`n"
  try {
    $stream.WriteLine($early);$stream.WriteLine($old)
    for($i=0;$i-lt50000;$i++){$stream.WriteLine($padding)}
    $stream.WriteLine($new)
  }finally{$stream.Dispose()}
  $fullStamp=Get-HistoryStamp
  Check ($fullStamp.bytes-gt32MB) 'large actual reclamation input exceeds 32MiB'
  $fullPath=Join-Path $root 'full-history.jsonl';[IO.File]::Copy($path,$fullPath)
  $suffixPath=Join-Path $root 'suffix.jsonl';$prefixPath=Join-Path $root 'prefix.jsonl'
  $geometry=New-HistoryControls $fullPath $suffixPath $prefixPath 50003
  Check ($geometry.rows-gt50000) 'large actual reclamation input exceeds 50000 physical rows'
  $fullResult=Read-CheckedReclamation 'full history'
  Check-WholeResult $fullResult $oracle 'whole large reclamation result equals complete small oracle'
  try {
    [IO.File]::Copy($suffixPath,$path,$true)
    $suffixResult=Read-CheckedReclamation 'actual suffix'
    Check ($suffixResult.complete-and-not$suffixResult.paths.ContainsKey($otherWorktree)-and
      -not$suffixResult.branches.ContainsKey($otherBranch)) 'actual suffix loses the early sole mapping'
    $suffixExpected=[pscustomobject]@{complete=$true;paths=@{};branches=@{}}
    $suffixExpected.paths[$worktree]=$expected.paths[$worktree];$suffixExpected.branches[$branch]=$expected.branches[$branch]
    Check-WholeResult $suffixResult $suffixExpected 'whole suffix contains only the exact late mapping'
    [IO.File]::Copy($prefixPath,$path,$true)
    $prefixResult=Read-CheckedReclamation 'actual byte prefix'
    $oldEntry=[pscustomobject]@{path=$worktree;branch=$branch;attemptId='900001-old'
      fingerprint=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($old)))}
    $prefixExpected=[pscustomobject]@{complete=$true;paths=@{};branches=@{}}
    $prefixExpected.paths[$otherWorktree]=$expected.paths[$otherWorktree];$prefixExpected.branches[$otherBranch]=$expected.branches[$otherBranch]
    $prefixExpected.paths[$worktree]=$oldEntry;$prefixExpected.branches[$branch]=$oldEntry
    Check-WholeResult $prefixResult $prefixExpected 'whole byte prefix loses late revision/fingerprint and retains early mappings'
    Check ($prefixResult.paths[$worktree].fingerprint-cne$oracle.paths[$worktree].fingerprint) 'prefix is a genuine late-fingerprint discriminator'
  }finally{
    [IO.File]::Copy($fullPath,$path,$true);[IO.File]::SetLastWriteTimeUtc($path,[datetime]::new($fullStamp.writeTicks,[DateTimeKind]::Utc))
  }
  Check-WholeResult (Get-HistoryStamp) $fullStamp 'restoration preserves original full bytes/hash/lastwrite'
  Check-WholeResult (Read-CheckedReclamation 'restored full') $oracle 'restored full result equals small oracle'
  $writer=[IO.File]::Open($path,'Open','Write','ReadWrite')
  try {
    Check-WholeResult (Read-CheckedReclamation 'held writer before append') $oracle 'full history remains equivalent under genuine held writer'
    [void]$writer.Seek(0,[IO.SeekOrigin]::End)
    $append=[Text.Encoding]::UTF8.GetBytes($third+"`n");$writer.Write($append,0,$append.Length);$writer.Flush($true)
    $appended=Read-CheckedReclamation 'held writer after append'
    $thirdEntry=[pscustomobject]@{path=$worktree;branch=$branch;attemptId='900003-appended'
      fingerprint=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($third)))}
    $expected.paths[$worktree]=$thirdEntry;$expected.branches[$branch]=$thirdEntry
    Check-WholeResult $appended $expected 'whole append result has exact third fingerprint and untouched other identity'
    Check-WholeResult (Read-CheckedReclamation 'held writer replay') $appended 'whole held-writer append replay is identical'
  }finally{$writer.Dispose()}
  Check-WholeResult (Read-CheckedReclamation 'closed writer replay') $appended 'whole closed-writer replay is identical'
  $appendStamp=Get-HistoryStamp
  Check ($appendStamp.bytes-eq$fullStamp.bytes+$append.Length) 'append byte growth is exactly the third committed row'
  $appendReader=[IO.StreamReader]::new($path);$appendRows=0
  try{while($null-ne$appendReader.ReadLine()){$appendRows++}}finally{$appendReader.Dispose()}
  Check ($appendRows-eq50004) 'append retains every original physical row plus one'
  Write-Output ('QUALIFICATION reclamation '+([ordered]@{geometry=$geometry;fullStamp=$fullStamp;small=$oracle;full=$fullResult
    suffix=$suffixResult;prefix=$prefixResult;appended=$appended;appendRows=$appendRows;appendStamp=$appendStamp
    restoration=$true;replay=$true;padding='50000 whitespace-only 700-space rows; physical geometry only; rich-all-row and memory unqualified'}|ConvertTo-Json -Depth 100 -Compress))
}
try {
  Check-PartialRefusal
  foreach($bom in @($false,$true)){
    foreach($newline in @("`n","`r`n")){
      Write-History ($old+$newline+$new+$newline) $bom
      $r=Get-ReclamationDispatch $root
      $expectedHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($new)))
      Check ($r.complete-and$r.paths.Count-eq1-and$r.branches.Count-eq1-and
        $r.paths[$worktree].attemptId-ceq'900002-new'-and$r.branches[$branch].fingerprint-ceq$expectedHash) 'committed BOM/LF/CRLF preserve original latest-row identity/hash fold'
    }
    Write-History ($old+"`n{`n") $bom
    $r=Get-ReclamationDispatch $root
    Check (-not$r.complete-and$r.paths.Count-eq0-and$r.branches.Count-eq0) 'committed malformed row still refuses'
  }
  Write-History ($old+"`n"+$new)
  $writer=[IO.File]::Open($path,'Open','Write','ReadWrite')
  try {
    [void]$writer.Seek(0,[IO.SeekOrigin]::End)
    Check (-not(Get-ReclamationDispatch $root).complete) 'real append writer may remain open during partial refusal'
    $writer.WriteByte(10);$writer.Flush($true)
    $r=Get-ReclamationDispatch $root
    Check ($r.complete-and$r.paths[$worktree].attemptId-ceq'900002-new') 'same open writer commits authoritative new row with LF'
  }finally{$writer.Dispose()}
  $original=${function:Get-ReclamationDispatch}
  $removed=$original.ToString().Replace(' -RequireTerminated','')
  Check ($removed-cne$original.ToString()) 'exact strict-termination removal changes actual function'
  try {
    Set-Item Function:Get-ReclamationDispatch ([scriptblock]::Create($removed))
    $failure='';try{Check-PartialRefusal}catch{$failure=$_.Exception.Message}
    Check ($failure-like'*ASSERTION FAILED: partial authority refuses*') 'strict-termination removal killed by actual partial-authority control'
  }finally{Set-Item Function:Get-ReclamationDispatch $original}
  Check-LargeReclamation
  Write-Output "PASS ledger-reader-reclamation-history checks=$checks partialVariants=8 committedVariants=4 realWriter=true strictRemoval=KILLED"
}finally{
  $full=[IO.Path]::GetFullPath($root)
  if((Split-Path -Parent $full).TrimEnd('\','/')-cne([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/')-or
    (Split-Path -Leaf $full)-cnotlike'ledger-reclamation-history-*'){throw 'unsafe reclamation history cleanup'}
  Remove-Item -LiteralPath $full -Recurse -Force
}
