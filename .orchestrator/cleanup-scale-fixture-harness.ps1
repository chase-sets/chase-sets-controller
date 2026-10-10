[CmdletBinding()]param(
  [Parameter(Mandatory)][ValidateSet('build','manifest','teardown')][string]$Mode,
  [Parameter(Mandatory)][string]$Root,[string]$Source='',[string]$OutPath='',
  [string]$EvidenceRoot='',[switch]$KeepEvidence,[switch]$FailBody,
  [string]$WindowStartUtc='',[string]$WindowEndUtc=''
)
# Non-discovered helper for cleanup-scale-fixture-equivalence.check.ps1. It
# executes the scale construction, report and finally regions of one exact
# cleanup test source (an immutable baseline blob or the candidate) in its own
# process, and observes only the resulting filesystem and authority state. It
# never derives an expected value from the source it executes.
$ErrorActionPreference='Stop'
$ConstructionStart='  Reset-Synthetic;$script:worktrees=@();$script:branches=@();$dispatchRows=[Collections.Generic.List[string]]::new()'
$ConstructionEnd='  $construction.Stop()'
$ReportEnd='  $wall=Measure-Command {$script:scaleResult=Invoke-WorktreeReclamation $root $root $root @scaleResolvers -ReportPath $scaleReport}'
$RowFields=@('kind','head','branch','branchTip','branchRemovable','detached','locked','clean','removable','reasonCode')

function Get-SourceLines([string]$Text){$lines=@($Text-split"`r?`n");if($lines.Count-and$lines[-1]-ceq''){$lines=$lines[0..($lines.Count-2)]};,$lines}
function Get-OnlyIndex([string[]]$Lines,[string]$Line,[string]$Name){
  $hits=@(for($i=0;$i-lt$Lines.Count;$i++){if($Lines[$i]-ceq$Line){$i}})
  if($hits.Count-ne1){throw "HARNESS anchor $Name occurs $($hits.Count) times"};$hits[0]
}
function Get-DispatchRows([string]$At){
  $text=[IO.File]::ReadAllText((Join-Path $At 'dispatch-log.jsonl'))
  [ordered]@{endsWithNewline=$text.EndsWith("`n");rows=@($text.TrimEnd("`n")-split"`n"|ForEach-Object{
    $row=$_|ConvertFrom-Json -AsHashtable;$sorted=[ordered]@{};foreach($key in @($row.Keys|Sort-Object)){$sorted[$key]=([string]$row[$key]).Replace($At,'{ROOT}')};$sorted
  })}
}
function Get-Manifest([string]$At,[datetime]$From,[datetime]$To){
  $From=$From.AddSeconds(-2);$To=$To.AddSeconds(2)
  $scale=[IO.DirectoryInfo]::new((Join-Path $At 'scale'))
  if(-not$scale.Exists){throw 'HARNESS scale root missing'}
  $trees=@($scale.GetFileSystemInfos()|Sort-Object Name|ForEach-Object -ThrottleLimit 4 -Parallel {
    $tree=$_;$lines=[Collections.Generic.List[string]]::new();$contents=@{};$outside=0
    $from=$using:From;$to=$using:To
    if($tree-isnot[IO.DirectoryInfo]-or($tree.Attributes-band[IO.FileAttributes]::ReparsePoint)){
      return [pscustomobject]@{name=$tree.Name;kind='not-a-real-directory';entries=0;digest='';contents=@{};outsideWindow=0}
    }
    $treeTime=$tree.LastWriteTimeUtc;if($treeTime-lt$from-or$treeTime-gt$to){$outside++}
    $sha=[Security.Cryptography.SHA256]::Create()
    try{
      foreach($entry in @($tree.GetFileSystemInfos()|Sort-Object Name)){
        if($entry-is[IO.DirectoryInfo]){$lines.Add("dir|$($entry.Name)");continue}
        $bytes=[IO.File]::ReadAllBytes($entry.FullName);$hash=[Convert]::ToHexString($sha.ComputeHash($bytes)).ToLowerInvariant()
        $lines.Add("file|$($entry.Name)|$($bytes.Length)|$hash");$contents[$hash]=1+[int]$contents[$hash]
        $time=$entry.LastWriteTimeUtc;if($time-lt$from-or$time-gt$to){$outside++}
      }
      $digest=[Convert]::ToHexString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($lines-join"`n")))).ToLowerInvariant()
    }finally{$sha.Dispose()}
    [pscustomobject]@{name=$tree.Name;kind='directory';entries=$lines.Count;digest=$digest;contents=$contents;outsideWindow=$outside}
  }|Sort-Object name)
  $contentCounts=@{};foreach($tree in $trees){foreach($key in $tree.contents.Keys){$contentCounts[$key]=$tree.contents[$key]+[int]$contentCounts[$key]}}
  $contents=[ordered]@{};foreach($key in @($contentCounts.Keys|Sort-Object)){$contents[$key]=$contentCounts[$key]}
  [ordered]@{
    trees=@($trees|ForEach-Object{[ordered]@{name=$_.name;kind=$_.kind;entries=$_.entries;digest=$_.digest}})
    contents=$contents
    outsideWindow=[int](($trees|Measure-Object outsideWindow -Sum).Sum)
    rootEntries=@([IO.DirectoryInfo]::new($At).GetFileSystemInfos()|Sort-Object Name|ForEach-Object Name)
    # Rows are serialized from plain hashtables, whose key order varies per
    # process in the baseline too; compare parsed rows, keys sorted.
    dispatchLog=(Get-DispatchRows $At)
    register=[IO.File]::ReadAllText((Join-Path $At 'platform-handoff.md'))
  }
}

if($Mode-ceq'manifest'){
  $roundtrip={param($Text)[datetime]::Parse($Text,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)}
  $from=&$roundtrip $WindowStartUtc;$to=&$roundtrip $WindowEndUtc
  if($from.Kind-ne[DateTimeKind]::Utc-or$to.Kind-ne[DateTimeKind]::Utc){throw 'HARNESS window must be round-trip UTC'}
  $manifest=Get-Manifest $Root $from $to
  [IO.File]::WriteAllText($OutPath,($manifest|ConvertTo-Json -Depth 8));return
}

$text=[IO.File]::ReadAllText($Source);$lines=Get-SourceLines $text
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
if($errors.Count){throw "HARNESS source parse errors: $($errors.Count)"}

if($Mode-ceq'teardown'){
  # Execute the source's exact finally region around an optionally failing body.
  $finallyAt=Get-OnlyIndex $lines '}finally{' 'finally'
  if($lines[-1]-cne'}'){throw 'HARNESS finally region is not the source tail'}
  $body=($lines[($finallyAt+1)..($lines.Count-2)])-join"`n"
  $root=$Root;$suiteClock=[Diagnostics.Stopwatch]::StartNew();$construction=$null;$wall=$null
  $try=if($FailBody){"throw 'synthetic failure'"}else{''}
  . ([scriptblock]::Create("try{$try}finally{`n$body`n}"))
  return
}

# build: the source's own helpers, resolvers and synthetic git, then its exact
# construction region and report statements against a fresh root.
. (Join-Path $PSScriptRoot 'cleanup-orphan-worktree-dirs.ps1')
$definitions=@($ast.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.FunctionDefinitionAst]}|ForEach-Object{$_.Extent.Text})
$try=@($ast.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.TryStatementAst]})
if($try.Count-ne1){throw 'HARNESS source try inventory'}
$resolverText=@($try[0].Body.Statements|Where-Object{$_-is[Management.Automation.Language.AssignmentStatementAst]-and$_.Left.Extent.Text-ceq'$resolvers'}|ForEach-Object{$_.Extent.Text})
$mockText=@($try[0].Body.Statements|Where-Object{$_-is[Management.Automation.Language.FunctionDefinitionAst]-and$_.Name-in@('Get-ReclamationWorktrees','Get-ReclamationBranches','Invoke-ReclamationGit')}|ForEach-Object{$_.Extent.Text})
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
$rows=@($script:scaleResult.rows|ForEach-Object{
  $row=$_;$o=[ordered]@{path=([string]$row.canonicalPath).Replace($root,'{ROOT}')}
  foreach($field in $RowFields){$o[$field]=$row.$field};$o.recognized=$row.identity.recognized;$o.idleState=$row.idle.state;$o
})
$normalize={param($Item)$o=[ordered]@{};foreach($key in @($Item.Keys|Sort-Object)){$o[$key]=([string]$Item[$key]).Replace($root,'{ROOT}')};$o}
[IO.File]::WriteAllText($OutPath,([ordered]@{
  windowStartUtc=$windowStart.ToString('o');windowEndUtc=$windowEnd.ToString('o')
  constructionMs=$construction.Elapsed.TotalMilliseconds;reportMs=$wall.TotalMilliseconds
  worktrees=@($script:worktrees|ForEach-Object{&$normalize $_});branches=@($script:branches|ForEach-Object{&$normalize $_})
  rows=$rows;fixture=(Get-Manifest $root $windowStart $windowEnd)
}|ConvertTo-Json -Depth 8))
