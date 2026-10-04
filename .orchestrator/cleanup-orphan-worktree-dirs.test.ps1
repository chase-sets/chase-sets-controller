[CmdletBinding()]param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'cleanup-orphan-worktree-dirs.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('cleanup-orphan-test-'+[guid]::NewGuid().ToString('N'))
function Assert-Cleanup([bool]$Condition,[string]$Message){if(-not$Condition){throw "ASSERTION FAILED: $Message"}}
function Invoke-TestGit([string]$At,[string[]]$Arguments){$out=@(& git.exe -C $At @Arguments 2>&1);if($LASTEXITCODE-ne0){throw "git failed: $($out-join"`n")"};(@($out)-join"`n").Trim()}
try{
  New-Item -ItemType Directory -Path $root|Out-Null
  Invoke-TestGit $root @('init','--initial-branch=main')|Out-Null
  Invoke-TestGit $root @('config','user.name','Synthetic Cleanup')|Out-Null
  Invoke-TestGit $root @('config','user.email','cleanup@example.invalid')|Out-Null
  [IO.File]::WriteAllText((Join-Path $root 'seed.txt'),'seed',[Text.UTF8Encoding]::new($false))
  Invoke-TestGit $root @('add','seed.txt')|Out-Null;Invoke-TestGit $root @('commit','-m','seed')|Out-Null
  $candidate=Join-Path $root 'lane-clean';Invoke-TestGit $root @('worktree','add','-b','synthetic/merged',$candidate)|Out-Null;$head=Invoke-TestGit $candidate @('rev-parse','HEAD')
  $dirty=Join-Path $root 'lane-dirty';Invoke-TestGit $root @('worktree','add','-b','synthetic/dirty',$dirty)|Out-Null;[IO.File]::WriteAllText((Join-Path $dirty 'dirty.txt'),'retain',[Text.UTF8Encoding]::new($false))
  $ownership={param($Runtime,$Temp,$Container)[pscustomobject]@{health=[ordered]@{status='ok';diagnostics=@()};activeLanes=@()}}
  $merged={param($Repository,$Branch,$Head)[pscustomobject]@{number=4388;state='MERGED';headRefName=$Branch;headRefOid=$Head;mergedAt='2026-09-10T12:00:00Z'}}
  $zeroChildren={param($Repository,$Branch)[pscustomobject][ordered]@{complete=$true;reason='complete-zero-open-child-prs';openCount=0;children=@()}}
  $report=Invoke-WorktreeReclamation $root $root $root -OwnershipResolver $ownership -PrResolver $merged -ChildPrResolver $zeroChildren
  Assert-Cleanup (@($report.rows|Where-Object{$_.removable}).Count-eq1-and@($report.rows|Where-Object{$_.reasonCode-ceq'dirty'}).Count-eq1) 'report does not isolate exact clean merged target'
  $applied=Invoke-WorktreeReclamation $root $root $root -Apply -OwnershipResolver $ownership -PrResolver $merged -ChildPrResolver $zeroChildren
  Assert-Cleanup (-not(Test-Path -LiteralPath $candidate)-and(Test-Path -LiteralPath $dirty)-and@($applied.applyResults).Count-eq1) 'apply did not remove only exact merged clean worktree'
  [void]@(& git -C $root show-ref --verify refs/heads/synthetic/merged 2>$null)
  Assert-Cleanup ($LASTEXITCODE-ne0) 'exact merged branch remains after removal'
  $live=Join-Path $root 'lane-live';Invoke-TestGit $root @('worktree','add','-b','synthetic/live',$live)|Out-Null
  $liveOwnership={param($Runtime,$Temp,$Container)[pscustomobject]@{health=[ordered]@{status='ok';diagnostics=@()};activeLanes=@([ordered]@{worktree=$live})}}
  $liveResult=Invoke-WorktreeReclamation $root $root $root -Apply -OwnershipResolver $liveOwnership -PrResolver $merged -ChildPrResolver $zeroChildren
  Assert-Cleanup ((Test-Path -LiteralPath $live)-and@($liveResult.applyResults).Count-eq0) 'live ownership was reclaimed'

  $syntheticRoot=Join-Path $root 'synthetic-merged-base'
  $script:syntheticWorktree=[pscustomobject][ordered]@{path=$syntheticRoot;head=('a'*40);branch='synthetic/merged-base';detached=$false;locked=$false}
  function Get-ReclamationWorktrees([string]$RepositoryRoot){@($script:syntheticWorktree)}
  function Invoke-ReclamationGit([string]$At,[string[]]$Arguments){
    if($Arguments[0]-ceq'status'){return [pscustomobject]@{exitCode=0;output=@();text=''}}
    throw "ASSERTION FAILED: synthetic retained target invoked git $($Arguments-join' ')"
  }
  $openChildren={param($Repository,$Branch)[pscustomobject][ordered]@{complete=$true;reason='open-child-prs-present';openCount=1;children=@([pscustomobject]@{number=9002;state='OPEN';baseRefName=$Branch})}}
  $openResult=Invoke-WorktreeReclamation $root $root $root -Apply -OwnershipResolver $ownership -PrResolver $merged -ChildPrResolver $openChildren
  Assert-Cleanup (@($openResult.applyResults).Count-eq0-and$openResult.rows[0].reasonCode-ceq'open-child-pr'-and$openResult.rows[0].openChildPr.number-eq9002) 'open child PR did not retain its merged base without git mutation'
  $unreadableChildren={param($Repository,$Branch)[pscustomobject][ordered]@{complete=$false;reason='query-failed';openCount=$null;children=@()}}
  $unreadableResult=Invoke-WorktreeReclamation $root $root $root -Apply -OwnershipResolver $ownership -PrResolver $merged -ChildPrResolver $unreadableChildren
  Assert-Cleanup (@($unreadableResult.applyResults).Count-eq0-and$unreadableResult.rows[0].reasonCode-ceq'open-child-pr-authority-unknown') 'unreadable child query did not retain its merged base without git mutation'

  $script:childQueryOrdinal=0
  $childAppears={
    param($Repository,$Branch)
    $script:childQueryOrdinal+=1
    if($script:childQueryOrdinal-eq1){return [pscustomobject][ordered]@{complete=$true;reason='complete-zero-open-child-prs';openCount=0;children=@()}}
    [pscustomobject][ordered]@{complete=$true;reason='open-child-prs-present';openCount=1;children=@([pscustomobject]@{number=9003;state='OPEN';baseRefName=$Branch})}
  }
  $revalidationFailure=$null
  try{Invoke-WorktreeReclamation $root $root $root -Apply -OwnershipResolver $ownership -PrResolver $merged -ChildPrResolver $childAppears|Out-Null}catch{$revalidationFailure=$_.Exception.Message}
  Assert-Cleanup ($revalidationFailure-like'reclamation target changed before removal:*'-and$script:childQueryOrdinal-eq2) 'same-cycle per-target revalidation did not stop when an open child appeared'
  Write-Output 'PASS cleanup requires exact merged clean inactive worktree plus complete zero-open-child authority; open/unreadable child controls retain'
}finally{
  $resolved=[IO.Path]::GetFullPath($root);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
  if((Split-Path -Parent $resolved).TrimEnd('\','/')-ne$temp-or(Split-Path -Leaf $resolved)-notlike'cleanup-orphan-test-*'){throw 'unsafe cleanup test root'}
  if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
