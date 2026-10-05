<#
.SYNOPSIS
Report or reclaim recognized incumbent work after exact same-cycle revalidation.

.DESCRIPTION
Report is the default. -Remove acts directly on rows that are still registered,
clean, unlocked, outside live ownership, and bound to exact MERGED PR evidence
or an idle HEAD reachable from base. Unknown authority always retains.
#>
[CmdletBinding()]
param([switch]$Remove, [switch]$Json, [string]$ReportPath)

$ErrorActionPreference = 'Stop'
$entryTimer = [Diagnostics.Stopwatch]::StartNew()
. (Join-Path $PSScriptRoot 'dispatch-ownership.ps1')

function Get-ReclamationPath([string]$Path) {
  [IO.Path]::GetFullPath($Path).TrimEnd('\','/')
}

function Test-ReclamationSamePath([string]$Left,[string]$Right) {
  try { [string]::Equals((Get-ReclamationPath $Left),(Get-ReclamationPath $Right),[StringComparison]::OrdinalIgnoreCase) } catch { $false }
}

function Invoke-ReclamationGit([string]$Root,[string[]]$Arguments) {
  $PSNativeCommandUseErrorActionPreference=$false
  $output=@(& git -C $Root @Arguments 2>&1); $code=$LASTEXITCODE
  [pscustomobject][ordered]@{ exitCode=$code; output=@($output|ForEach-Object{"$_"}); text=(@($output|ForEach-Object{"$_"})-join"`n").Trim() }
}

function Get-ReclamationRepositorySlug([string]$Repository) {
  $slug=(Invoke-ReclamationGit $Repository @('config','--get','remote.origin.url')).text
  if($slug -notmatch 'github\.com[/:](?<repo>[^/\s]+/[^/\s]+?)(?:\.git)?$'){return $null}
  [string]$Matches.repo
}

function Get-ReclamationWorktrees([string]$RepositoryRoot) {
  $probe=Invoke-ReclamationGit $RepositoryRoot @('worktree','list','--porcelain')
  if($probe.exitCode-ne0){throw "worktree inventory failed: $($probe.text)"}
  $rows=[Collections.Generic.List[object]]::new();$current=$null
  foreach($line in @($probe.output)+@('')){
    if(-not$line){if($current){$rows.Add([pscustomobject]$current);$current=$null};continue}
    if($line.StartsWith('worktree ')){$current=[ordered]@{path=Get-ReclamationPath $line.Substring(9);head='';branch='';detached=$false;locked=$false};continue}
    if(-not$current){continue}
    if($line.StartsWith('HEAD ')){$current.head=$line.Substring(5)}
    elseif($line.StartsWith('branch refs/heads/')){$current.branch=$line.Substring(18)}
    elseif($line-ceq'detached'){$current.detached=$true}
    elseif($line.StartsWith('locked')){$current.locked=$true}
  }
  @($rows)
}

function Get-ReclamationMergedPr([string]$Repository,[string]$Branch,[string]$Head) {
  if([string]::IsNullOrWhiteSpace($Branch)){return $null}
  $repoSlug=Get-ReclamationRepositorySlug $Repository
  if(-not$repoSlug){return $null}
  $raw=@(& gh pr list --repo $repoSlug --state merged --head $Branch --limit 2 --json number,state,headRefName,headRefOid,mergedAt 2>$null)
  if($LASTEXITCODE-ne0){return $null}
  try{$prs=@(($raw-join"`n")|ConvertFrom-Json -DateKind String)}catch{return $null}
  $matches=@($prs|Where-Object{[string]$_.state-ceq'MERGED'-and[string]$_.headRefName-ceq$Branch-and[string]$_.headRefOid-ceq$Head})
  if($matches.Count-ne1){return $null}
  $matches[0]
}

function Get-ReclamationOpenChildPrAuthority([string]$Repository,[string]$Branch) {
  if([string]::IsNullOrWhiteSpace($Branch)){return [pscustomobject][ordered]@{complete=$false;reason='missing-branch';openCount=$null;children=@()}}
  $repoSlug=Get-ReclamationRepositorySlug $Repository
  if(-not$repoSlug){return [pscustomobject][ordered]@{complete=$false;reason='repository-unknown';openCount=$null;children=@()}}
  $parts=@($repoSlug.Split('/'))
  if($parts.Count-ne2){return [pscustomobject][ordered]@{complete=$false;reason='repository-ambiguous';openCount=$null;children=@()}}
  $query='query($owner:String!,$name:String!,$base:String!){repository(owner:$owner,name:$name){pullRequests(states:OPEN,baseRefName:$base,first:1){totalCount nodes{number state baseRefName} pageInfo{hasNextPage endCursor}}}}'
  $raw=@(& gh api graphql -f "query=$query" -F "owner=$($parts[0])" -F "name=$($parts[1])" -F "base=$Branch" 2>$null)
  if($LASTEXITCODE-ne0){return [pscustomobject][ordered]@{complete=$false;reason='query-failed';openCount=$null;children=@()}}
  try{$payload=($raw-join"`n")|ConvertFrom-Json -DateKind String}catch{return [pscustomobject][ordered]@{complete=$false;reason='response-malformed';openCount=$null;children=@()}}
  $connection=$payload.data.repository.pullRequests
  if($null-eq$connection-or$null-eq$connection.totalCount){return [pscustomobject][ordered]@{complete=$false;reason='response-ambiguous';openCount=$null;children=@()}}
  $count=0
  if(-not[int]::TryParse([string]$connection.totalCount,[ref]$count)-or$count-lt0){return [pscustomobject][ordered]@{complete=$false;reason='count-ambiguous';openCount=$null;children=@()}}
  $children=@($connection.nodes)
  if($count-eq0){
    if($children.Count-ne0-or$connection.pageInfo.hasNextPage-ne$false){return [pscustomobject][ordered]@{complete=$false;reason='zero-result-truncated';openCount=$null;children=@()}}
    return [pscustomobject][ordered]@{complete=$true;reason='complete-zero-open-child-prs';openCount=0;children=@()}
  }
  if($children.Count-ne1-or[string]$children[0].state-cne'OPEN'-or[string]$children[0].baseRefName-cne$Branch){return [pscustomobject][ordered]@{complete=$false;reason='open-result-ambiguous';openCount=$null;children=@()}}
  [pscustomobject][ordered]@{complete=$true;reason='open-child-prs-present';openCount=$count;children=@($children)}
}

function Get-ReclamationBranches([string]$RepositoryRoot) {
  $probe=Invoke-ReclamationGit $RepositoryRoot @('for-each-ref','--format=%(refname:strip=2)%09%(objectname)','refs/heads/')
  if($probe.exitCode-ne0){throw 'local branch inventory failed'}
  foreach($line in $probe.output){
    if(-not$line){continue}
    $parts=$line.Split("`t")
    if($parts.Count-ne2-or$parts[1]-cnotmatch'^[0-9a-f]{40}$'){throw 'local branch inventory malformed'}
    [pscustomobject]@{branch=$parts[0];head=$parts[1]}
  }
}

function Test-ReclamationProtectedBranch([string]$Branch) {
  -not$Branch-or$Branch-ceq'main'-or$Branch.StartsWith('archive/',[StringComparison]::Ordinal)-or$Branch.StartsWith('salvage/',[StringComparison]::Ordinal)
}

function Test-ReclamationInside([string]$Path,[string]$Container) {
  try {
    $path=Get-ReclamationPath $Path
    if(-not$path.StartsWith($Container+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){return $false}
    # Lexical containment is insufficient if a parent redirects outside the container.
    for($p=$path;$p;$p=Split-Path -Parent $p){
      if((Test-Path -LiteralPath $p)-and((Get-Item -LiteralPath $p -Force).Attributes-band[IO.FileAttributes]::ReparsePoint)){return $false}
      if(Test-ReclamationSamePath $p $Container){break}
    }
    return $true
  }catch{return $false}
}

function Get-ReclamationRegister([string]$RuntimeRoot) {
  try {
    $text=[IO.File]::ReadAllText((Join-Path $RuntimeRoot 'platform-handoff.md'),[Text.UTF8Encoding]::new($false,$true))
    $table=[regex]::Match($text,'(?s)## 1\. Ownership register\s+(?<table>.*?)\r?\n## 2\.')
    if(-not$table.Success){throw 'missing ownership register'}
    $seen=[Collections.Generic.HashSet[int]]::new();$platform=[Collections.Generic.List[int]]::new();$default=$false
    foreach($line in ($table.Groups['table'].Value -split '\r?\n')){
      if($line-notmatch'^\|'){continue}
      $cells=@($line.Trim().Trim('|').Split('|')|ForEach-Object{$_.Trim()})
      if($cells.Count-ne3){throw 'malformed register row'}
      if($cells[0]-cmatch'^chase-sets milestone (?<number>[1-9][0-9]*) \([^|]+\)$'){
        $number=0
        if(-not[int]::TryParse($Matches.number,[ref]$number)-or-not$seen.Add($number)){throw 'conflicting register row'}
        if($cells[1]-cmatch'^platform(?: \(assigned [^|]+\))?$'){$platform.Add($number)}
        elseif($cells[1]-cnotmatch'^incumbent(?: \((?:rolled back|returned) [^|]+\))?$'){throw 'unknown register owner'}
      }elseif($cells[0]-ceq'every other chase-sets milestone, issue, PR, worktree, and the merge queue'){
        if($default-or$cells[1]-cne'incumbent'){throw 'conflicting default owner'};$default=$true
      }elseif($cells[0]-cmatch'^`[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+` \(all issues\)$'){
        if($cells[1]-cne'platform self loop (`m1`)'){throw 'unknown repository owner'}
      }elseif($cells[0]-cnotin@('Scope','---','WSL executor `/root/orchestration-m1/repo`')){throw 'unknown register scope'}
    }
    if(-not$default){throw 'missing incumbent default'}
    [pscustomobject]@{complete=$true;milestones=@($platform);fingerprint=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($text)))}
  }catch{[pscustomobject]@{complete=$false;milestones=@();fingerprint=''}}
}

function Get-ReclamationDispatch([string]$RuntimeRoot) {
  $paths=@{};$branches=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
  $reader=$null
  try {
    # The append order is authoritative: never fall back to an older recognizable row.
    $reader=[IO.File]::OpenText((Join-Path $RuntimeRoot 'dispatch-log.jsonl'))
    while($null-ne($line=$reader.ReadLine())){
      if([string]::IsNullOrWhiteSpace($line)){continue}
      $row=$line|ConvertFrom-Json -DateKind String
      if($row-isnot[pscustomobject]){throw 'malformed dispatch row'}
      if(-not$row.worktree){continue}
      $path=Get-ReclamationPath $row.worktree
      $entry=[pscustomobject]@{path=$path;branch=[string]$row.branch;attemptId=[string]$row.attemptId;fingerprint=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($line)))}
      $paths[$path]=$entry
      if($row.branch){$branches[[string]$row.branch]=$entry}
    }
    [pscustomobject]@{complete=$true;paths=$paths;branches=$branches}
  }catch{[pscustomobject]@{complete=$false;paths=@{};branches=@{}}}
  finally{if($reader){$reader.Dispose()}}
}

function Get-ReclamationIssue([int]$Number) {
  $raw=@(& gh api "repos/chase-sets/chase-sets/issues/$Number" 2>$null)
  if($LASTEXITCODE-ne0){return $null}
  try{($raw-join"`n")|ConvertFrom-Json -DateKind String}catch{return $null}
}

function Get-ReclamationIdentity($Candidate,$Dispatch,$Register,[scriptblock]$IssueResolver) {
  $reason='recognized-incumbent';$row=$null;$number=0;$milestone=$null
  if(-not$Dispatch.complete){$reason='identity-unreadable'}
  elseif($Candidate.kind-ceq'orphan-branch'){
    if($Dispatch.branches.ContainsKey($Candidate.branch)){$row=$Dispatch.branches[$Candidate.branch]}
  }elseif($Dispatch.paths.ContainsKey($Candidate.path)){$row=$Dispatch.paths[$Candidate.path]}
  if($reason-ceq'recognized-incumbent'){
    if(-not$row){$reason='identity-unrecognized'}
    elseif(-not$Dispatch.paths.ContainsKey($row.path)-or$Dispatch.paths[$row.path].fingerprint-cne$row.fingerprint){$reason='identity-conflicting'}
    elseif($Candidate.detached-and-not$row.branch){$reason='detached-unbound'}
    elseif($Candidate.branch-and$Candidate.branch-cne$row.branch){$reason='identity-conflicting'}
    else {
      $attempt=0;$branchIssue=0
      if($row.attemptId-cmatch'^(?<number>[1-9][0-9]*)(?:-|$)'){[void][int]::TryParse($Matches.number,[ref]$attempt)}
      if($row.branch-cmatch'^codex/(?<number>[1-9][0-9]*)-'){[void][int]::TryParse($Matches.number,[ref]$branchIssue)}
      if($attempt-and$branchIssue-and$attempt-ne$branchIssue){$reason='identity-conflicting'}
      else{$number=if($attempt){$attempt}else{$branchIssue};if(-not$number){$reason='identity-unrecognized'}}
    }
  }
  if($reason-ceq'recognized-incumbent'){
    if(-not$Register.complete){$reason='register-unreadable'}
    else {
      try{$issue=&$IssueResolver $number}catch{$issue=$null}
      if($null-eq$issue-or$issue.number-ne$number-or'milestone'-cnotin@($issue.PSObject.Properties.Name)){$reason='issue-unreadable'}
      elseif($null-ne$issue.milestone){
        $milestone=0
        if(-not[int]::TryParse([string]$issue.milestone.number,[ref]$milestone)-or$milestone-lt1){$reason='issue-unreadable'}
        elseif($milestone-in$Register.milestones){$reason='platform-owned-milestone'}
      }
    }
  }
  [pscustomobject]@{recognized=$reason-ceq'recognized-incumbent';reasonCode=$reason;issue=$number;milestone=$milestone;dispatchPath=$row.path;branch=$row.branch;dispatchFingerprint=$row.fingerprint;registerFingerprint=$Register.fingerprint}
}

function Test-ReclamationOpenPrRows($Authority) {
  if($null-eq$Authority-or$Authority.complete-ne$true-or$null-eq$Authority.totalCount-or$Authority.nodes-isnot[array]){return $false}
  $count=0
  if(-not[int]::TryParse([string]$Authority.totalCount,[ref]$count)-or$count-lt0-or$count-ne$Authority.nodes.Count){return $false}
  $seen=[Collections.Generic.HashSet[int]]::new()
  foreach($node in $Authority.nodes){
    $number=0
    if(-not[int]::TryParse([string]$node.number,[ref]$number)-or$number-lt1-or-not$seen.Add($number)-or[string]::IsNullOrWhiteSpace($node.headRefName)-or[string]$node.headRefOid-cnotmatch'^[0-9a-f]{40}$'){return $false}
  }
  $true
}

function ConvertTo-ReclamationOpenPrAuthority([object[]]$Pages) {
  $unknown=[pscustomobject]@{complete=$false;totalCount=$null;nodes=@()}
  $nodes=[Collections.Generic.List[object]]::new();$total=$null;$cursors=[Collections.Generic.HashSet[string]]::new()
  if(-not$Pages.Count){return $unknown}
  for($i=0;$i-lt$Pages.Count;$i++){
    $page=$Pages[$i];$connection=$page.data.repository.pullRequests;$count=0
    if($page.errors-or$null-eq$connection-or$null-eq$connection.totalCount-or-not[int]::TryParse([string]$connection.totalCount,[ref]$count)-or$count-lt0-or$connection.nodes-isnot[array]){return $unknown}
    if($null-ne$total-and$total-ne$count){return $unknown};$total=$count
    if($connection.pageInfo.hasNextPage-isnot[bool]-or$connection.pageInfo.hasNextPage-ne($i-lt$Pages.Count-1)){return $unknown}
    if($connection.pageInfo.hasNextPage-and([string]::IsNullOrWhiteSpace($connection.pageInfo.endCursor)-or-not$cursors.Add($connection.pageInfo.endCursor))){return $unknown}
    foreach($node in $connection.nodes){$nodes.Add($node)}
  }
  $authority=[pscustomobject]@{complete=$true;totalCount=$total;nodes=@($nodes)}
  if(-not(Test-ReclamationOpenPrRows $authority)){return $unknown}
  $authority
}

function Get-ReclamationOpenPrAuthority([string]$Repository) {
  $slug=Get-ReclamationRepositorySlug $Repository
  if(-not$slug){return ConvertTo-ReclamationOpenPrAuthority @()}
  $parts=$slug.Split('/')
  $query='query($owner:String!,$name:String!,$endCursor:String){repository(owner:$owner,name:$name){pullRequests(states:OPEN,first:100,after:$endCursor){totalCount nodes{number headRefName headRefOid baseRefName} pageInfo{hasNextPage endCursor}}}}'
  $raw=@(& gh api graphql --paginate --slurp -f "query=$query" -F "owner=$($parts[0])" -F "name=$($parts[1])" 2>$null)
  if($LASTEXITCODE-ne0){return ConvertTo-ReclamationOpenPrAuthority @()}
  try{$pages=@(($raw-join"`n")|ConvertFrom-Json -DateKind String);ConvertTo-ReclamationOpenPrAuthority $pages}catch{ConvertTo-ReclamationOpenPrAuthority @()}
}

function Get-ReclamationIdle([string]$Path,[Nullable[datetime]]$RecentCutoff,[scriptblock]$EntryObserver) {
  $enumerators=[Collections.Generic.Stack[IDisposable]]::new()
  try {
    $newest=[datetime]::MinValue
    $item=[IO.DirectoryInfo]::new($Path)
    if(-not$item.Exists){throw 'missing idle directory'}
    while($null-ne$item){
      if($item.Attributes-band[IO.FileAttributes]::ReparsePoint){throw 'unreadable idle subtree'}
      if($EntryObserver){&$EntryObserver $item}
      if($item.LastWriteTimeUtc-gt$newest){$newest=$item.LastWriteTimeUtc}
      if($null-ne$RecentCutoff-and$newest-gt$RecentCutoff){
        return [pscustomobject]@{complete=$true;newestWriteUtc=$null;idleHours=([datetime]::UtcNow-$newest).TotalHours;state='recent'}
      }
      if($item-is[IO.DirectoryInfo]){$enumerators.Push($item.EnumerateFileSystemInfos().GetEnumerator())}
      $item=$null
      while($enumerators.Count-and$null-eq$item){
        $iterator=$enumerators.Peek()
        if(-not$iterator.MoveNext()){$enumerators.Pop().Dispose();continue}
        if($iterator.Current.Name-in@('.git','node_modules')){continue}
        $item=$iterator.Current
      }
    }
    [pscustomobject]@{complete=$true;newestWriteUtc=$newest.ToString('o');idleHours=([datetime]::UtcNow-$newest).TotalHours;state='complete'}
  }catch{[pscustomobject]@{complete=$false;newestWriteUtc=$null;idleHours=$null;state='idle-unreadable'}}
  finally{while($enumerators.Count){$enumerators.Pop().Dispose()}}
}

function Get-ReclamationContext {
  param(
    [string]$ContainerRoot,[string]$RuntimeRoot,[string]$TempRoot,
    [scriptblock]$OwnershipResolver,[scriptblock]$OpenPrResolver,[hashtable]$PhaseTimings
  )
  $container=Get-ReclamationPath $ContainerRoot
  try{$ownership=&$OwnershipResolver $RuntimeRoot $TempRoot $container}catch{$ownership=$null}
  $ownershipHealthy=$null-ne$ownership-and[string]$ownership.health.status-ceq'ok'
  $live=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $liveBranches=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach($lane in @($ownership.activeLanes)){
    if($lane.worktree){[void]$live.Add((Get-ReclamationPath([string]$lane.worktree)))}
    if($lane.branch){[void]$liveBranches.Add([string]$lane.branch)}
  }
  $register=Get-ReclamationRegister $RuntimeRoot;$dispatch=Get-ReclamationDispatch $RuntimeRoot
  $repositories=@([pscustomobject]@{identity='container-meta';root=$container;base='refs/heads/main'})
  $product=Join-Path $container 'main'
  if(Test-Path -LiteralPath $product -PathType Container){$repositories+=[pscustomobject]@{identity='product';root=Get-ReclamationPath $product;base='refs/remotes/origin/main'}}
  # Container-meta has no origin. Both stores belong to the product's issues
  # and PRs, so obtain one complete product PR census per inventory pass.
  $authorityRepository=if($repositories.Count-eq2){$product}else{$container}
  $timer=[Diagnostics.Stopwatch]::StartNew()
  try{$open=&$OpenPrResolver $authorityRepository}catch{$open=$null}
  finally{$PhaseTimings.authority+=$timer.Elapsed.TotalMilliseconds}
  $openComplete=Test-ReclamationOpenPrRows $open
  [pscustomobject]@{container=$container;ownership=$ownership;ownershipHealthy=$ownershipHealthy;live=$live;liveBranches=$liveBranches;register=$register;dispatch=$dispatch;repositories=$repositories;authorityRepository=$authorityRepository;open=$open;openComplete=$openComplete}
}

function Get-ReclamationRow {
  param($Context,$Repository,$Candidate,[object[]]$Worktrees,[object[]]$Branches,
    [scriptblock]$PrResolver,[scriptblock]$ChildPrResolver,[scriptblock]$IssueResolver,[scriptblock]$IdleResolver,[hashtable]$PhaseTimings)
  $orphan=$candidate.kind-ceq'orphan-branch'
  $dispatch=$Context.dispatch;$register=$Context.register
  $timer=[Diagnostics.Stopwatch]::StartNew()
  try{$identity=Get-ReclamationIdentity $candidate $dispatch $register $IssueResolver}
  finally{$PhaseTimings.authority+=$timer.Elapsed.TotalMilliseconds}
  $path=if($orphan){[string]$identity.dispatchPath}else{$candidate.path}
  $branch=if($candidate.detached){[string]$identity.branch}else{$candidate.branch}
  $inside=Test-ReclamationInside $path $Context.container
  $status=if(-not$orphan){Invoke-ReclamationGit $path @('status','--porcelain=v1','--untracked-files=normal')}else{$null}
  $clean=$orphan-or($null-ne$status-and$status.exitCode-eq0-and-not$status.text)
  $tip=@($branches|Where-Object{$_.branch-ceq$branch})
  $branchTip=if($tip.Count-eq1){[string]$tip[0].head}else{''}
  $open=$Context.open;$pr=$null;$child=$null;$idle=$null;$reachable=$null
  $reason=if($orphan-and(Test-ReclamationProtectedBranch $branch)){'protected-branch'}
    elseif(-not$Context.ownershipHealthy){'ownership-unknown'}
    elseif($Context.live.Contains($path)-or$Context.liveBranches.Contains($branch)){'live-owner'}
    elseif($candidate.locked){'locked'}
    elseif(-not$clean){'dirty'}
    elseif (-not $identity.recognized) {$identity.reasonCode}
    elseif(-not$inside){'outside-container'}
    elseif(-not$Context.openComplete){'open-pr-authority-unknown'}
    elseif(@($open.nodes|Where-Object{$_.headRefName-ceq$branch}).Count){'open-head-pr-branch'}
    elseif(@($open.nodes|Where-Object{$_.headRefOid-ceq$candidate.head}).Count){'open-head-pr-sha'}
    else{$null}
  if(-not$reason){
    $timer=[Diagnostics.Stopwatch]::StartNew()
    try{
      try{$pr=&$PrResolver $Context.authorityRepository $branch $candidate.head}catch{$pr=$null}
      try{$child=&$ChildPrResolver $Context.authorityRepository $branch $candidate.head}catch{$child=$null}
    }finally{$PhaseTimings.authority+=$timer.Elapsed.TotalMilliseconds}
    $reason=if($null-eq$child-or$child.complete-ne$true-or$null-eq$child.openCount){'open-child-pr-authority-unknown'}
      elseif($child.openCount-gt0){'open-child-pr'}
      elseif($child.openCount-ne0){'open-child-pr-authority-ambiguous'}
      else{$null}
  }
  if(-not$reason){
    $exactMerged=$null-ne$pr-and[string]$pr.state-ceq'MERGED'-and[string]$pr.headRefName-ceq$branch-and[string]$pr.headRefOid-ceq$candidate.head
    if(-not$exactMerged){
      $baseProbe=Invoke-ReclamationGit $repository.root @('merge-base','--is-ancestor',$candidate.head,$repository.base)
      $reachable = $baseProbe.exitCode -eq 0
    }
    if($exactMerged-or$reachable){
      if(-not$orphan){
        # Exact-merged needs the complete observation for apply change detection,
        # but only landed eligibility may stop at a recent entry.
        $cutoff=if($exactMerged){$null}else{[datetime]::UtcNow.AddHours(-6)}
        $timer=[Diagnostics.Stopwatch]::StartNew()
        try{$idle=&$IdleResolver $path $cutoff}catch{$idle=$null}
        finally{$PhaseTimings.idle+=$timer.Elapsed.TotalMilliseconds}
      }
    }
    $idleEligible=$orphan-or($null-ne$idle-and$idle.complete-eq$true-and$idle.state-cne'recent'-and$null-ne$idle.idleHours-and$idle.idleHours-ge6)
    $reason=if($exactMerged){'exact-merged-pr-zero-open-children'}
      elseif(-not$reachable){'head-not-in-base'}
      elseif (-not $idleEligible) {if($null-eq$idle-or$idle.complete-ne$true){'idle-unreadable'}else{'idle-under-six-hours'}}
      else{'landed-worktree'}
  }
  $removable=$reason-cin@('exact-merged-pr-zero-open-children','landed-worktree')
  if($orphan-and$removable){$reason='orphan-branch'}
  $branchRemovable=-not(Test-ReclamationProtectedBranch $branch)-and$branchTip-ceq$candidate.head-and@($worktrees|Where-Object{$_.branch-ceq$branch-and-not(Test-ReclamationSamePath $_.path $path)}).Count-eq0
  [pscustomobject][ordered]@{kind=$candidate.kind;repository=$repository.identity;repositoryRoot=$repository.root;canonicalPath=$path;head=$candidate.head;branch=$branch;branchTip=$branchTip;branchRemovable=$branchRemovable;detached=$candidate.detached;locked=$candidate.locked;clean=$clean;identity=$identity;baseRef=$repository.base;reachable=$reachable;idle=$idle;prEvidence=$pr;openPrAuthority=$open;openChildAuthority=$child;openChildPr=@($child.children|Select-Object -First 1)[0];removable=$removable;reasonCode=$reason}
}

function Get-ReclamationInventory {
  param(
    [string]$ContainerRoot,[string]$RuntimeRoot,[string]$TempRoot,
    [scriptblock]$OwnershipResolver={param($Runtime,$Temp,$Container)Get-LiveDispatchOwnership $Runtime $Temp $Container},
    [scriptblock]$PrResolver={param($Repository,$Branch,$Head)Get-ReclamationMergedPr $Repository $Branch $Head},
    [scriptblock]$ChildPrResolver={param($Repository,$Branch)Get-ReclamationOpenChildPrAuthority $Repository $Branch},
    [scriptblock]$OpenPrResolver={param($Repository)Get-ReclamationOpenPrAuthority $Repository},
    [scriptblock]$IssueResolver={param($Number)Get-ReclamationIssue $Number},
    [scriptblock]$IdleResolver={param($Path,$Cutoff)Get-ReclamationIdle $Path $Cutoff},
    [hashtable]$PhaseTimings=@{inventory=0.0;idle=0.0;authority=0.0;apply=0.0;total=0.0}
  )
  $timer=[Diagnostics.Stopwatch]::StartNew()
  $observedAt=[datetime]::UtcNow
  $context=Get-ReclamationContext $ContainerRoot $RuntimeRoot $TempRoot $OwnershipResolver $OpenPrResolver $PhaseTimings
  $dispatch=$context.dispatch
  $rows=[Collections.Generic.List[object]]::new()
  foreach($repository in $context.repositories){
    $worktrees=@(Get-ReclamationWorktrees $repository.root);$branches=@(Get-ReclamationBranches $repository.root)
    $candidates=[Collections.Generic.List[object]]::new()
    foreach($worktree in $worktrees){
      if(Test-ReclamationSamePath $worktree.path $repository.root){continue}
      $candidates.Add([pscustomobject]@{kind='worktree';path=$worktree.path;head=$worktree.head;branch=$worktree.branch;detached=$worktree.detached;locked=$worktree.locked})
    }
    foreach($branch in $branches){
      if(@($worktrees|Where-Object{$_.branch-ceq$branch.branch}).Count){continue}
      # A bound detached worktree owns this branch's reclamation route too.
      if(@($worktrees|Where-Object{$_.detached-and$dispatch.paths.ContainsKey($_.path)-and$dispatch.paths[$_.path].branch-ceq$branch.branch}).Count){continue}
      $candidates.Add([pscustomobject]@{kind='orphan-branch';path='';head=$branch.head;branch=$branch.branch;detached=$false;locked=$false})
    }
    foreach($candidate in $candidates){
      $rows.Add((Get-ReclamationRow $context $repository $candidate $worktrees $branches $PrResolver $ChildPrResolver $IssueResolver $IdleResolver $PhaseTimings))
    }
  }
  $PhaseTimings.inventory+=$timer.Elapsed.TotalMilliseconds
  [pscustomobject]@{ownership=$context.ownership;repositories=$context.repositories;rows=@($rows|Sort-Object repository,kind,canonicalPath,branch);observedAt=$observedAt}
}

function Get-ReclamationTarget {
  param($Target,[datetime]$ObservedAt,[string]$ContainerRoot,[string]$RuntimeRoot,[string]$TempRoot,
    [scriptblock]$OwnershipResolver,[scriptblock]$PrResolver,[scriptblock]$ChildPrResolver,
    [scriptblock]$OpenPrResolver,[scriptblock]$IssueResolver,[scriptblock]$IdleResolver,[hashtable]$PhaseTimings)
  # An old landed observation cannot prove that still-idle means unchanged.
  if($Target.reasonCode-ceq'landed-worktree'-and([datetime]::UtcNow-$ObservedAt).TotalHours-ge6){return $null}
  $context=Get-ReclamationContext $ContainerRoot $RuntimeRoot $TempRoot $OwnershipResolver $OpenPrResolver $PhaseTimings
  $repositories=@($context.repositories|Where-Object{$_.identity-ceq$Target.repository-and(Test-ReclamationSamePath $_.root $Target.repositoryRoot)})
  if($repositories.Count-ne1){return $null}
  $repository=$repositories[0]
  $worktrees=@(Get-ReclamationWorktrees $repository.root)
  $branches=@(Get-ReclamationBranches $repository.root)
  if($Target.kind-ceq'worktree'){
    $matches=@($worktrees|Where-Object{Test-ReclamationSamePath $_.path $Target.canonicalPath})
    if($matches.Count-ne1-or(Test-ReclamationSamePath $matches[0].path $repository.root)){return $null}
    $wt=$matches[0]
    $candidate=[pscustomobject]@{kind='worktree';path=$wt.path;head=$wt.head;branch=$wt.branch;detached=$wt.detached;locked=$wt.locked}
  }else{
    $matches=@($branches|Where-Object{$_.branch-ceq$Target.branch})
    if($matches.Count-ne1){return $null}
    foreach($wt in $worktrees){
      if($wt.branch-ceq$Target.branch-or($wt.detached-and$context.dispatch.paths.ContainsKey($wt.path)-and$context.dispatch.paths[$wt.path].branch-ceq$Target.branch)){return $null}
    }
    $candidate=[pscustomobject]@{kind='orphan-branch';path='';head=$matches[0].head;branch=$matches[0].branch;detached=$false;locked=$false}
  }
  $row=Get-ReclamationRow $context $repository $candidate $worktrees $branches $PrResolver $ChildPrResolver $IssueResolver $IdleResolver $PhaseTimings
  if($row.branch-ceq$Target.branch-and(Test-ReclamationSamePath $row.canonicalPath $Target.canonicalPath)){$row}
}

function Write-ReclamationReport([string]$Path,$Report) {
  $full=[IO.Path]::GetFullPath($Path);$temporary=$full+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
  [void][IO.Directory]::CreateDirectory((Split-Path -Parent $full))
  try {
    [IO.File]::WriteAllText($temporary,($Report|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temporary,$full,$true)
  }finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
}

function Invoke-WorktreeReclamation {
  param(
    [string]$ContainerRoot,[string]$RuntimeRoot,[string]$TempRoot,[switch]$Apply,
    [scriptblock]$OwnershipResolver={param($Runtime,$Temp,$Container)Get-LiveDispatchOwnership $Runtime $Temp $Container},
    [scriptblock]$PrResolver={param($Repository,$Branch,$Head)Get-ReclamationMergedPr $Repository $Branch $Head},
    [scriptblock]$ChildPrResolver={param($Repository,$Branch)Get-ReclamationOpenChildPrAuthority $Repository $Branch},
    [scriptblock]$OpenPrResolver={param($Repository)Get-ReclamationOpenPrAuthority $Repository},
    [scriptblock]$IssueResolver={param($Number)Get-ReclamationIssue $Number},
    [scriptblock]$IdleResolver={param($Path,$Cutoff)Get-ReclamationIdle $Path $Cutoff},
    [Parameter(DontShow)][scriptblock]$BeforeApplyObserver,[string]$ReportPath,
    [Parameter(DontShow)][Diagnostics.Stopwatch]$TotalTimer=[Diagnostics.Stopwatch]::StartNew()
  )
  $phaseTimings=@{inventory=0.0;idle=0.0;authority=0.0;apply=0.0;total=0.0}
  $inventoryArgs=@{ContainerRoot=$ContainerRoot;RuntimeRoot=$RuntimeRoot;TempRoot=$TempRoot;OwnershipResolver=$OwnershipResolver;PrResolver=$PrResolver;ChildPrResolver=$ChildPrResolver;OpenPrResolver=$OpenPrResolver;IssueResolver=$IssueResolver;IdleResolver=$IdleResolver;PhaseTimings=$phaseTimings}
  $initial=Get-ReclamationInventory @inventoryArgs
  $result=[pscustomobject][ordered]@{schemaVersion='worktree-reclamation-report/v4';mode=$(if($Apply){'apply'}else{'report'});containerRoot=Get-ReclamationPath $ContainerRoot;ownershipHealth=[string]$initial.ownership.health.status;rows=@($initial.rows);applyResults=@();removedCount=0;retainedCount=$initial.rows.Count;phaseTimings=$phaseTimings}
  $applied=[Collections.Generic.List[object]]::new()
  if($Apply){
    $applyTimer=[Diagnostics.Stopwatch]::StartNew()
    $targets=@($initial.rows|Where-Object{$_.removable})
    if($BeforeApplyObserver){&$BeforeApplyObserver $initial.rows}
    foreach($target in $targets){
      $outcome=[pscustomobject][ordered]@{repository=$target.repository;path=$target.canonicalPath;head=$target.head;branch=$target.branch;result='changed-before-apply';branchResult='retained';reasonCode='changed-before-apply'}
      try{$fresh=Get-ReclamationTarget -Target $target -ObservedAt $initial.observedAt @inventoryArgs}
      catch{$outcome.reasonCode='inventory-unreadable';$applied.Add($outcome);continue}
      $same=$null-ne$fresh-and$fresh.removable
      foreach($field in @('head','branchTip','branchRemovable','clean','locked','detached','reasonCode')){if($null-eq$fresh-or$fresh.$field-cne$target.$field){$same=$false}}
      if($null-eq$fresh-or($fresh.identity|ConvertTo-Json -Compress)-cne($target.identity|ConvertTo-Json -Compress)-or$fresh.idle.newestWriteUtc-cne$target.idle.newestWriteUtc){$same=$false}
      if(-not$same){$applied.Add($outcome);continue}
      if($target.kind-ceq'worktree'){
        $remove=Invoke-ReclamationGit $target.repositoryRoot @('worktree','remove','--',$target.canonicalPath)
        if($remove.exitCode-ne0){$outcome.result='removal-failed';$outcome.reasonCode='git-worktree-remove-failed';$applied.Add($outcome);continue}
        $outcome.result=if($target.reasonCode-ceq'landed-worktree'){'landed-worktree-reclaimed'}else{'removed-merged-worktree-and-branch'}
      }else{$outcome.result='orphan-branch-reclaimed'}
      if($fresh.branchRemovable-and-not(Test-ReclamationProtectedBranch $target.branch)){
        # A new checkout must not lose its ref even at an unchanged SHA.
        try{$attached=@(Get-ReclamationWorktrees $target.repositoryRoot|Where-Object{$_.branch-ceq$target.branch});$attachmentKnown=$true}
        catch{$attachmentKnown=$false;$outcome.branchResult='worktree-authority-unknown'}
        if($attachmentKnown-and-not$attached.Count){
          # Do not follow a symbolic branch alias into a protected ref.
          $delete=Invoke-ReclamationGit $target.repositoryRoot @('update-ref','--no-deref','-d',"refs/heads/$($target.branch)",$target.head)
          $outcome.branchResult=if($delete.exitCode-eq0){'deleted-exact-sha'}else{'exact-ref-delete-failed'}
        }
      }
      if($target.kind-ceq'orphan-branch'-and$outcome.branchResult-cne'deleted-exact-sha'){$outcome.result='changed-before-apply'}
      elseif($target.kind-ceq'worktree'-and$outcome.result-ceq'removed-merged-worktree-and-branch'-and$outcome.branchResult-cne'deleted-exact-sha'){$outcome.result='removed-merged-worktree-branch-retained'}
      $outcome.reasonCode=$outcome.result
      if($outcome.result-cne'changed-before-apply'){$result.removedCount++}
      $applied.Add($outcome)
    }
    $phaseTimings.apply=$applyTimer.Elapsed.TotalMilliseconds
  }
  $result.applyResults=@($applied);$result.retainedCount=$result.rows.Count-$result.removedCount
  $phaseTimings.total=$TotalTimer.Elapsed.TotalMilliseconds
  if($ReportPath){Write-ReclamationReport $ReportPath $result}
  $result
}

if($MyInvocation.InvocationName-cne'.'){
  $container=Split-Path -Parent $PSScriptRoot
  $report=Invoke-WorktreeReclamation $container $PSScriptRoot ([IO.Path]::GetTempPath()) -Apply:$Remove -ReportPath $ReportPath -TotalTimer $entryTimer
  if($Json){$report|ConvertTo-Json -Depth 20}else{$report.rows|Select-Object repository,kind,canonicalPath,head,branch,reasonCode|Format-Table -AutoSize|Out-String|Write-Output;foreach($a in $report.applyResults){Write-Output "$($a.result): $($a.path)"};if(-not$Remove){Write-Output '(report only; rerun with -Remove for recognized incumbent reclamation)'}}
}
