<#
.SYNOPSIS
Report or remove merged worktrees after exact same-cycle revalidation.

.DESCRIPTION
Report is the default. -Remove acts directly on rows that are still registered,
clean, unlocked, outside live ownership, and bound to exact MERGED PR evidence.
There is no disposition packet or replacement reclamation ceremony. Unknown,
dirty, detached, unmerged, locked, or live work is reported and retained.
#>
[CmdletBinding()]
param([switch]$Remove, [switch]$Json)

$ErrorActionPreference = 'Stop'
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

function Get-ReclamationInventory(
  [string]$ContainerRoot,[string]$RuntimeRoot,[string]$TempRoot,
  [scriptblock]$OwnershipResolver={param($Runtime,$Temp,$Container)Get-LiveDispatchOwnership $Runtime $Temp $Container},
  [scriptblock]$PrResolver={param($Repository,$Branch,$Head)Get-ReclamationMergedPr $Repository $Branch $Head},
  [scriptblock]$ChildPrResolver={param($Repository,$Branch)Get-ReclamationOpenChildPrAuthority $Repository $Branch}
) {
  $container=Get-ReclamationPath $ContainerRoot
  $ownership=&$OwnershipResolver $RuntimeRoot $TempRoot $container
  $ownershipHealthy=$null-ne$ownership-and[string]$ownership.health.status-ceq'ok'
  $live=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach($lane in @($ownership.activeLanes)){if($lane.worktree){[void]$live.Add((Get-ReclamationPath([string]$lane.worktree)))}}
  $repositories=@([pscustomobject]@{identity='container-meta';root=$container})
  $product=Join-Path $container 'main';if(Test-Path -LiteralPath $product -PathType Container){$repositories+= [pscustomobject]@{identity='product';root=Get-ReclamationPath $product}}
  $rows=[Collections.Generic.List[object]]::new()
  foreach($repository in $repositories){
    foreach($worktree in Get-ReclamationWorktrees $repository.root){
      if(Test-ReclamationSamePath $worktree.path $repository.root){continue}
      $inside=$worktree.path.StartsWith($container+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)
      $status=Invoke-ReclamationGit $worktree.path @('status','--porcelain=v1','--untracked-files=normal')
      $clean=$status.exitCode-eq0-and@($status.output|Where-Object{$_}).Count-eq0
      $pr=if($inside-and-not$worktree.detached-and$worktree.branch){&$PrResolver $repository.root $worktree.branch $worktree.head}else{$null}
      $exactMerged=$null-ne$pr-and[string]$pr.state-ceq'MERGED'-and[string]$pr.headRefName-ceq$worktree.branch-and[string]$pr.headRefOid-ceq$worktree.head
      $childAuthority=if($exactMerged){&$ChildPrResolver $repository.root $worktree.branch}else{$null}
      $zeroOpenChildren=$null-ne$childAuthority-and$childAuthority.complete-eq$true-and[int]$childAuthority.openCount-eq0
      $reason=if(-not$inside){'outside-container'}elseif(-not$ownershipHealthy){'ownership-unknown'}elseif($live.Contains($worktree.path)){'live-owner'}elseif($worktree.locked){'locked'}elseif($worktree.detached){'detached'}elseif(-not$clean){'dirty'}elseif(-not$exactMerged){'no-exact-merged-pr'}elseif($null-eq$childAuthority-or$childAuthority.complete-ne$true){'open-child-pr-authority-unknown'}elseif([int]$childAuthority.openCount-gt0){'open-child-pr'}elseif(-not$zeroOpenChildren){'open-child-pr-authority-ambiguous'}else{'exact-merged-pr-zero-open-children'}
      $rows.Add([pscustomobject][ordered]@{repository=$repository.identity;repositoryRoot=$repository.root;canonicalPath=$worktree.path;head=$worktree.head;branch=$worktree.branch;detached=$worktree.detached;locked=$worktree.locked;clean=$clean;prEvidence=$pr;openChildAuthority=$childAuthority;openChildPr=if($null-ne$childAuthority){@($childAuthority.children|Select-Object -First 1)[0]}else{$null};removable=$reason-ceq'exact-merged-pr-zero-open-children';reasonCode=$reason})
    }
  }
  [pscustomobject][ordered]@{ownership=$ownership;repositories=$repositories;rows=@($rows|Sort-Object repository,canonicalPath)}
}

function Invoke-WorktreeReclamation(
  [string]$ContainerRoot,[string]$RuntimeRoot,[string]$TempRoot,[switch]$Apply,
  [scriptblock]$OwnershipResolver={param($Runtime,$Temp,$Container)Get-LiveDispatchOwnership $Runtime $Temp $Container},
  [scriptblock]$PrResolver={param($Repository,$Branch,$Head)Get-ReclamationMergedPr $Repository $Branch $Head},
  [scriptblock]$ChildPrResolver={param($Repository,$Branch)Get-ReclamationOpenChildPrAuthority $Repository $Branch},
  [Parameter(DontShow)][scriptblock]$BeforeApplyObserver
) {
  $initial=Get-ReclamationInventory $ContainerRoot $RuntimeRoot $TempRoot $OwnershipResolver $PrResolver $ChildPrResolver
  $result=[pscustomobject][ordered]@{schemaVersion='worktree-reclamation-report/v3';mode=$(if($Apply){'apply'}else{'report'});containerRoot=Get-ReclamationPath $ContainerRoot;ownershipHealth=[string]$initial.ownership.health.status;rows=@($initial.rows);applyResults=@()}
  if(-not$Apply){return $result}
  $targets=@($initial.rows|Where-Object{$_.removable})
  if($BeforeApplyObserver){&$BeforeApplyObserver $initial.rows}
  $applied=[Collections.Generic.List[object]]::new()
  foreach($target in $targets){
    $current=Get-ReclamationInventory $ContainerRoot $RuntimeRoot $TempRoot $OwnershipResolver $PrResolver $ChildPrResolver
    $matches=@($current.rows|Where-Object{[string]$_.repository-ceq[string]$target.repository-and(Test-ReclamationSamePath $_.canonicalPath $target.canonicalPath)})
    if($matches.Count-ne1-or-not$matches[0].removable-or[string]$matches[0].head-cne[string]$target.head){throw "reclamation target changed before removal: $($target.canonicalPath)"}
    $remove=Invoke-ReclamationGit $target.repositoryRoot @('worktree','remove','--',$target.canonicalPath)
    if($remove.exitCode-ne0){throw "git worktree remove failed: $($remove.text)"}
    $deleteRef=Invoke-ReclamationGit $target.repositoryRoot @('update-ref','-d',"refs/heads/$($target.branch)",$target.head)
    if($deleteRef.exitCode-ne0){throw "exact branch deletion failed: $($deleteRef.text)"}
    $applied.Add([pscustomobject][ordered]@{repository=$target.repository;path=$target.canonicalPath;head=$target.head;branch=$target.branch;result='removed-merged-worktree-and-branch'})
  }
  $result.applyResults=@($applied);$result
}

if($MyInvocation.InvocationName-cne'.'){
  $container=Split-Path -Parent $PSScriptRoot
  $report=Invoke-WorktreeReclamation $container $PSScriptRoot ([IO.Path]::GetTempPath()) -Apply:$Remove
  if($Json){$report|ConvertTo-Json -Depth 12}else{$report.rows|Select-Object repository,canonicalPath,head,branch,reasonCode|Format-Table -AutoSize|Out-String|Write-Output;foreach($a in $report.applyResults){Write-Output "$($a.result): $($a.path)"};if(-not$Remove){Write-Output '(report only; rerun with -Remove to remove only exact merged, clean, inactive worktrees)'}}
}
