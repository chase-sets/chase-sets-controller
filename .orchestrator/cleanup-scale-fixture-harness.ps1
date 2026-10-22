[CmdletBinding()]param(
  [Parameter(Mandatory)][ValidateSet('build','manifest','teardown')][string]$Mode,
  [Parameter(Mandatory)][string]$Root,[string]$Source='',[string]$OutPath='',
  [string]$EvidenceRoot='',[switch]$KeepEvidence,[switch]$FailBody,[string]$ReplaceScaleWith='',
  [string]$WindowStartUtc='',[string]$WindowEndUtc=''
)
# Non-discovered helper for cleanup-scale-fixture-equivalence.check.ps1 (#9275).
# Each process runs one exact cleanup test source (the immutable baseline blob,
# the candidate or a named mutant) and reports only the filesystem and authority
# state it observes; it never derives an expected value from that source.
#   build    the source's helpers and synthetic git, then its exact scale
#            construction region and report statements against a fresh root.
#   manifest re-read an existing fixture (controls change it between reads).
#   teardown the source's exact finally statements in order, after a body that
#            optionally fails. -ReplaceScaleWith swaps root\scale for a junction
#            to that path immediately after the containment check statement.
$ErrorActionPreference='Stop'
$ConstructionStart='  Reset-Synthetic;$script:worktrees=@();$script:branches=@();$dispatchRows=[Collections.Generic.List[string]]::new()'
$ConstructionEnd='  $construction.Stop()'
$ReportEnd='  $wall=Measure-Command {$script:scaleResult=Invoke-WorktreeReclamation $root $root $root @scaleResolvers -ReportPath $scaleReport}'
$ContainmentCheck='if((Split-Path -Parent $resolved).TrimEnd(''\'',''/'')-ne$evidence-or(Split-Path -Leaf $resolved)-notlike''cleanup-orphan-test-*''){throw ''unsafe cleanup test root''}'
$RowFields=@('kind','head','branch','branchTip','branchRemovable','detached','locked','clean','removable','reasonCode')

function Get-OnlyIndex([string[]]$Lines,[string]$Line,[string]$Name){
  $hits=@(for($i=0;$i-lt$Lines.Count;$i++){if($Lines[$i]-ceq$Line){$i}})
  if($hits.Count-ne1){throw "HARNESS anchor $Name occurs $($hits.Count) times"};$hits[0]
}
function Get-DispatchRows([string]$At){
  # Rows serialize plain hashtables whose key order varies per process, in the
  # baseline too: compare parsed rows with sorted keys.
  $text=[IO.File]::ReadAllText((Join-Path $At 'dispatch-log.jsonl'))
  [ordered]@{endsWithNewline=$text.EndsWith("`n");rows=@($text.TrimEnd("`n")-split"`n"|ForEach-Object{
    $row=$_|ConvertFrom-Json -AsHashtable;$sorted=[ordered]@{};foreach($key in @($row.Keys|Sort-Object)){$sorted[$key]=([string]$row[$key]).Replace($At,'{ROOT}')};$sorted
  })}
}
function Get-Manifest([string]$At,[datetime]$From,[datetime]$To){
  # Two seconds of slack absorbs filesystem timestamp granularity at the edges.
  $From=$From.AddSeconds(-2);$To=$To.AddSeconds(2)
  $scale=[IO.DirectoryInfo]::new((Join-Path $At 'scale'))
  if(-not$scale.Exists){throw 'HARNESS scale root missing'}
  $trees=@($scale.GetFileSystemInfos()|ForEach-Object -ThrottleLimit 4 -Parallel {
    $tree=$_;$from=$using:From;$to=$using:To
    if($tree-isnot[IO.DirectoryInfo]-or($tree.Attributes-band[IO.FileAttributes]::ReparsePoint)){
      return [pscustomobject]@{name=$tree.Name;kind='not-a-real-directory';entries=0;digest='';contents=@{};outsideWindow=0}
    }
    $lines=[Collections.Generic.List[string]]::new();$contents=@{};$outside=0
    if($tree.LastWriteTimeUtc-lt$from-or$tree.LastWriteTimeUtc-gt$to){$outside++}
    $sha=[Security.Cryptography.SHA256]::Create()
    try{
      foreach($entry in @($tree.GetFileSystemInfos()|Sort-Object Name)){
        if($entry-isnot[IO.FileInfo]){$lines.Add("other|$($entry.Name)");continue}
        $bytes=[IO.File]::ReadAllBytes($entry.FullName);$hash=[Convert]::ToHexString($sha.ComputeHash($bytes)).ToLowerInvariant()
        $lines.Add("file|$($entry.Name)|$($bytes.Length)|$hash");$contents[$hash]=1+[int]$contents[$hash]
        if($entry.LastWriteTimeUtc-lt$from-or$entry.LastWriteTimeUtc-gt$to){$outside++}
      }
      $digest=[Convert]::ToHexString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($lines-join"`n")))).ToLowerInvariant()
    }finally{$sha.Dispose()}
    [pscustomobject]@{name=$tree.Name;kind='directory';entries=$lines.Count;digest=$digest;contents=$contents;outsideWindow=$outside}
  }|Sort-Object name)
  $counts=@{};foreach($tree in $trees){foreach($key in $tree.contents.Keys){$counts[$key]=$tree.contents[$key]+[int]$counts[$key]}}
  $contents=[ordered]@{};foreach($key in @($counts.Keys|Sort-Object)){$contents[$key]=$counts[$key]}
  [ordered]@{
    trees=@($trees|ForEach-Object{[ordered]@{name=$_.name;kind=$_.kind;entries=$_.entries;digest=$_.digest}})
    contents=$contents
    outsideWindow=[int](($trees|Measure-Object outsideWindow -Sum).Sum)
    rootEntries=@([IO.DirectoryInfo]::new($At).GetFileSystemInfos()|Sort-Object Name|ForEach-Object Name)
    dispatchLog=(Get-DispatchRows $At)
    register=[IO.File]::ReadAllText((Join-Path $At 'platform-handoff.md')).Replace($At,'{ROOT}')
  }
}

if($Mode-ceq'manifest'){
  $parse={param($Text)[datetime]::Parse($Text,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)}
  $from=&$parse $WindowStartUtc;$to=&$parse $WindowEndUtc
  if($from.Kind-ne[DateTimeKind]::Utc-or$to.Kind-ne[DateTimeKind]::Utc){throw 'HARNESS window must be round-trip UTC'}
  [IO.File]::WriteAllText($OutPath,((Get-Manifest $Root $from $to)|ConvertTo-Json -Depth 8));return
}

$text=[IO.File]::ReadAllText($Source).Replace("`r`n","`n")
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
if($errors.Count){throw "HARNESS source does not parse: $($errors.Count) errors"}
$try=@($ast.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.TryStatementAst]})
if($try.Count-ne1-or$null-eq$try[0].Finally){throw 'HARNESS source try/finally inventory'}

if($Mode-ceq'teardown'){
  # Statements are dot-sourced into this scope, which supplies the variables the
  # finally region reads: $root (= -Root), $EvidenceRoot and $KeepEvidence.
  $statements=@($try[0].Finally.Statements|ForEach-Object{$_.Extent.Text})
  if($ReplaceScaleWith-and@($statements|Where-Object{$_-ceq$ContainmentCheck}).Count-ne1){throw 'HARNESS replacement seam absent'}
  $suiteClock=[Diagnostics.Stopwatch]::StartNew();$construction=$null;$wall=$null
  try{if($FailBody){throw 'synthetic failure'}}
  finally{
    foreach($statement in $statements){
      . ([scriptblock]::Create($statement))
      if($ReplaceScaleWith-and$statement-ceq$ContainmentCheck){
        $scale=Join-Path $Root 'scale'
        Move-Item -LiteralPath $scale -Destination (Join-Path $Root 'original-scale')
        New-Item -ItemType Junction -Path $scale -Target $ReplaceScaleWith|Out-Null
        Write-Output 'HARNESS scale replaced by an outside junction after the containment check'
      }
    }
  }
  return
}

# build
. (Join-Path $PSScriptRoot 'cleanup-orphan-worktree-dirs.ps1')
$lines=@($text.TrimEnd("`n")-split"`n")
$definitions=@($ast.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.FunctionDefinitionAst]}|ForEach-Object{$_.Extent.Text})
$resolverText=@($try[0].Body.Statements|Where-Object{$_-is[Management.Automation.Language.AssignmentStatementAst]-and$_.Left.Extent.Text-ceq'$resolvers'}|ForEach-Object{$_.Extent.Text})
$mockText=@($try[0].Body.Statements|Where-Object{$_-is[Management.Automation.Language.FunctionDefinitionAst]-and$_.Name-cin@('Get-ReclamationWorktrees','Get-ReclamationBranches','Invoke-ReclamationGit')}|ForEach-Object{$_.Extent.Text})
if($resolverText.Count-ne1-or$mockText.Count-ne3){throw 'HARNESS resolver/synthetic git inventory'}
$start=Get-OnlyIndex $lines $ConstructionStart 'construction-start';$end=Get-OnlyIndex $lines $ConstructionEnd 'construction-end'
$reportEnd=Get-OnlyIndex $lines $ReportEnd 'report-end'
if(-not($start-lt$end-and$end-lt$reportEnd)){throw 'HARNESS region order'}
$root=[IO.Path]::GetFullPath($Root);[void][IO.Directory]::CreateDirectory($root)
. ([scriptblock]::Create(($definitions+$resolverText+$mockText)-join"`n"))
$windowStart=[datetime]::UtcNow
. ([scriptblock]::Create(($lines[$start..$end])-join"`n"))
$windowEnd=[datetime]::UtcNow
. ([scriptblock]::Create(($lines[($end+1)..$reportEnd])-join"`n"))
$normalize={param($Item)$o=[ordered]@{};foreach($key in @($Item.Keys|Sort-Object)){$o[$key]=([string]$Item[$key]).Replace($root,'{ROOT}')};$o}
$rows=@($script:scaleResult.rows|ForEach-Object{
  $row=$_;$o=[ordered]@{path=([string]$row.canonicalPath).Replace($root,'{ROOT}')}
  foreach($field in $RowFields){$o[$field]=$row.$field};$o.recognized=$row.identity.recognized;$o.idleState=$row.idle.state;$o
})
[IO.File]::WriteAllText($OutPath,([ordered]@{
  windowStartUtc=$windowStart.ToString('o');windowEndUtc=$windowEnd.ToString('o')
  constructionMs=$construction.Elapsed.TotalMilliseconds;reportMs=$wall.TotalMilliseconds
  worktrees=@($script:worktrees|ForEach-Object{&$normalize $_});branches=@($script:branches|ForEach-Object{&$normalize $_})
  rows=$rows;fixture=(Get-Manifest $root $windowStart $windowEnd)
}|ConvertTo-Json -Depth 8))
