[CmdletBinding()]param()
$ErrorActionPreference='Stop'
[Diagnostics.Process]::GetCurrentProcess().PriorityClass='BelowNormal'
. (Join-Path $PSScriptRoot 'cleanup-orphan-worktree-dirs.ps1')
$sourcePath=Join-Path $PSScriptRoot 'cleanup-orphan-worktree-dirs.ps1'
$root=Join-Path ([IO.Path]::GetTempPath()) ('cleanup-orphan-test-'+[guid]::NewGuid().ToString('N'))
function Assert-Cleanup([bool]$Condition,[string]$Message){if(-not$Condition){throw "ASSERTION FAILED: $Message"}}
function Invoke-TestGit([string]$At,[string[]]$Arguments){$out=@(& git -C $At @Arguments 2>&1);if($LASTEXITCODE-ne0){throw "git failed: $($out-join"`n")"};(@($out)-join"`n").Trim()}
function Write-Fixture([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))}
function Write-Register([int]$Platform=7002){
  Write-Fixture (Join-Path $root 'platform-handoff.md') @"
## 1. Ownership register
| Scope | Owner | Notes |
| --- | --- | --- |
| chase-sets milestone $Platform (Synthetic platform) | platform | synthetic |
| every other chase-sets milestone, issue, PR, worktree, and the merge queue | incumbent | synthetic |
## 2. Route
"@
}
function Write-Dispatch([string]$Path,[string]$Branch,[string]$Attempt='900001-synthetic'){
  Write-Fixture (Join-Path $root 'dispatch-log.jsonl') ((@{ts='2026-10-04T10:00:00Z';kind='dispatch';worktree=$Path;branch=$Branch;head=('a'*40);attemptId=$Attempt}|ConvertTo-Json -Compress)+"`n")
}
function Reset-Synthetic {
  $script:wt=[pscustomobject]@{path=(Join-Path $root 'synthetic-lane');head=('a'*40);branch='codex/900001-synthetic';detached=$false;locked=$false}
  $script:branches=@([pscustomobject]@{branch=$script:wt.branch;head=$script:wt.head})
  $script:worktrees=@($script:wt);$script:dirty=$false;$script:reachable=$true;$script:merged=$false
  $script:idle=[pscustomobject]@{complete=$true;newestWriteUtc='2026-10-04T00:00:00Z';idleHours=12}
  $script:ownership=[pscustomobject]@{health=@{status='ok'};activeLanes=@()}
  $script:issue=[pscustomobject]@{number=900001;milestone=[pscustomobject]@{number=7001}}
  $script:open=[pscustomobject]@{complete=$true;totalCount=0;nodes=@()}
  $script:children=[pscustomobject]@{complete=$true;openCount=0;children=@()}
  $script:mutations=[Collections.Generic.List[string]]::new();$script:openCalls=0
  $script:authorityRepositories=[Collections.Generic.List[string]]::new()
  Write-Register;Write-Dispatch $script:wt.path $script:wt.branch
}
function Invoke-Synthetic([scriptblock]$Observer,[switch]$ReportOnly,[string]$ReportPath='') {
  Invoke-WorktreeReclamation $root $root $root -Apply:(-not$ReportOnly) @resolvers -BeforeApplyObserver $Observer -ReportPath $ReportPath
}
function Assert-Retained([string]$Reason,[string]$Label='landed-worktree-retained'){
  $r=Invoke-Synthetic
  $row=if($script:worktrees.Count){@($r.rows|Where-Object{$_.kind-ceq'worktree'})[0]}else{$r.rows[0]}
  Assert-Cleanup ($row.reasonCode-ceq$Reason-and-not$row.removable-and$script:mutations.Count-eq0) "$Label-$Reason (actual $($row.reasonCode))"
  Write-Output "PASS $Label-$Reason"
}
try {
  New-Item -ItemType Directory -Path $root|Out-Null
  $resolvers=@{
    OwnershipResolver={param($Runtime,$Temp,$Container)$script:ownership}
    PrResolver={param($Repository,$Branch,$Head)$script:authorityRepositories.Add($Repository);if($script:merged){[pscustomobject]@{number=900011;state='MERGED';headRefName=$Branch;headRefOid=$Head}}}
    ChildPrResolver={param($Repository,$Branch)$script:authorityRepositories.Add($Repository);$script:children}
    OpenPrResolver={param($Repository)$script:authorityRepositories.Add($Repository);$script:openCalls++;$script:open}
    IssueResolver={param($Number)$script:issue}
    IdleResolver={param($Path)$script:idle}
  }
  $nativeGit=${function:Invoke-ReclamationGit};$nativeTrees=${function:Get-ReclamationWorktrees};$nativeBranches=${function:Get-ReclamationBranches}
  function Get-ReclamationWorktrees([string]$RepositoryRoot){@($script:worktrees)}
  function Get-ReclamationBranches([string]$RepositoryRoot){@($script:branches)}
  function Invoke-ReclamationGit([string]$At,[string[]]$Arguments){
    $text='';$code=0
    switch($Arguments[0]){
      'status' {if($script:dirty){$text='?? synthetic-dirt'}}
      'merge-base' {if(-not$script:reachable){$code=1}}
      'worktree' {$script:mutations.Add(($Arguments-join' '));$script:worktrees=@($script:worktrees|Where-Object{$_.path-cne$Arguments[3]})}
      'update-ref' {$script:mutations.Add(($Arguments-join' '))}
      default {throw "unexpected synthetic git: $($Arguments-join' ')"}
    }
    [pscustomobject]@{exitCode=$code;text=$text;output=@($text|Where-Object{$_})}
  }
  Reset-Synthetic;$r=Invoke-Synthetic
  Assert-Cleanup ($r.schemaVersion-ceq'worktree-reclamation-report/v4'-and$r.rows[0].identity.recognized-and$r.applyResults.Count-eq1-and$script:mutations.Count-eq2) 'landed-worktree-reclaimed'
  Assert-Cleanup ($script:mutations[1]-ceq"update-ref --no-deref -d refs/heads/$($wt.branch) $($wt.head)") 'exact-SHA deletion'
  Assert-Cleanup ($script:openCalls-eq2) 'open PR authority queried at report and before removal'
  Write-Output 'PASS landed-worktree-reclaimed synthetic'
  Reset-Synthetic;$script:merged=$true;$script:reachable=$false;$script:idle.idleHours=0;$r=Invoke-Synthetic
  Assert-Cleanup ($r.rows[0].reasonCode-ceq'exact-merged-pr-zero-open-children'-and$script:mutations.Count-eq2) 'exact merged class preserved without landed idle/base requirements'
  Write-Output 'PASS exact-merged-worktree-reclaimed'
  $cases=[ordered]@{
    'head-not-in-base'={$script:reachable=$false}
    'idle-under-six-hours'={$script:idle.idleHours=5.99}
    'idle-unreadable'={$script:idle.complete=$false}
    'open-head-pr-branch'={$script:open.nodes=@(@{number=900012;headRefName=$wt.branch;headRefOid=('b'*40);baseRefName='main'});$script:open.totalCount=1}
    'open-head-pr-sha'={$script:open.nodes=@(@{number=900012;headRefName='synthetic/other';headRefOid=$wt.head;baseRefName='main'});$script:open.totalCount=1}
    'open-pr-authority-unknown'={$script:open.complete=$false}
    'open-child-pr-authority-unknown'={$script:children.complete=$false}
    'open-child-pr'={$script:children.openCount=1;$script:children.children=@(@{number=900013})}
    'dirty'={$script:dirty=$true}
    'locked'={$script:wt.locked=$true}
    'live-owner'={$script:ownership.activeLanes=@(@{worktree=$wt.path})}
    'ownership-unknown'={$script:ownership.health.status='unknown'}
    'identity-unrecognized'={Write-Fixture (Join-Path $root 'dispatch-log.jsonl') ''}
    'identity-conflicting'={Write-Dispatch $wt.path $wt.branch '900002-synthetic'}
    'platform-owned-milestone'={$script:issue.milestone.number=7002}
    'register-unreadable'={Write-Fixture (Join-Path $root 'platform-handoff.md') 'malformed synthetic register'}
    'issue-unreadable'={$script:issue=$null}
    'detached-unbound'={$script:wt.detached=$true;$script:wt.branch='';Write-Dispatch $wt.path ''}
  }
  foreach($case in $cases.GetEnumerator()){Reset-Synthetic;&$case.Value;Assert-Retained $case.Key}
  foreach($reason in @('identity-unrecognized','identity-conflicting','platform-owned-milestone','register-unreadable','issue-unreadable')){Reset-Synthetic;$script:merged=$true;&$cases[$reason];Assert-Retained $reason 'exact-merged-retained'}
  foreach($reason in @('open-head-pr-branch','open-head-pr-sha','open-pr-authority-unknown','open-child-pr','open-child-pr-authority-unknown')){Reset-Synthetic;$script:merged=$true;&$cases[$reason];Assert-Retained $reason 'exact-merged-retained'}
  Reset-Synthetic;Write-Dispatch $wt.path 'codex/900001-different';Assert-Retained 'identity-conflicting'
  Reset-Synthetic;Write-Fixture (Join-Path $root 'dispatch-log.jsonl') '{';Assert-Retained 'identity-unreadable'
  Reset-Synthetic;Add-Content (Join-Path $root 'dispatch-log.jsonl') (@{worktree=$wt.path;branch=$wt.branch;attemptId='900002-newest'}|ConvertTo-Json -Compress);Assert-Retained 'identity-conflicting' 'newest-dispatch-retained'
  Reset-Synthetic;Write-Register 7001;Assert-Retained 'platform-owned-milestone' 'dynamic-register-retained'
  Reset-Synthetic;Write-Register 7001;$registerPath=Join-Path $root 'platform-handoff.md'
  Write-Fixture $registerPath ([IO.File]::ReadAllText($registerPath).Replace('| platform |','| platform (assigned 2026-10-04T00:00:00Z; NOT LAUNCHED) |'))
  Assert-Retained 'platform-owned-milestone' 'annotated-register-retained'
  foreach($annotation in @('returned','rolled back')){
    Reset-Synthetic;Write-Register 7001
    Write-Fixture $registerPath ([IO.File]::ReadAllText($registerPath).Replace('| platform |',"| incumbent ($annotation 2026-10-04T00:00:00Z) |"))
    $r=Invoke-Synthetic;Assert-Cleanup ($script:mutations.Count-eq2) "annotated-register-incumbent-$annotation"
  }
  Reset-Synthetic;$script:idle.idleHours=6;$r=Invoke-Synthetic;Assert-Cleanup ($script:mutations.Count-eq2) 'six-hour boundary'
  foreach($name in @('main','archive/synthetic','salvage/synthetic')){
    foreach($mergedCase in @($false,$true)){
      Reset-Synthetic;$script:merged=$mergedCase;$script:wt.branch=$name;$script:branches=@(@{branch=$name;head=$wt.head});Write-Dispatch $wt.path $name;$r=Invoke-Synthetic
      Assert-Cleanup (@($script:mutations|Where-Object{$_-like'update-ref*'}).Count-eq0) "protected-name worktree $name merged=$mergedCase"
    }
    Reset-Synthetic;$script:worktrees=@();$script:branches=@(@{branch=$name;head=$wt.head});Write-Dispatch $wt.path $name;Assert-Retained 'protected-branch' 'orphan-branch-retained'
  }
  Write-Output 'PASS protected names bind every branch-deletion route'
  foreach($via in @('base','merged')){
    Reset-Synthetic;$script:worktrees=@();$script:reachable=$via-ceq'base';$script:merged=$via-ceq'merged';$r=Invoke-Synthetic
    Assert-Cleanup ($r.rows[0].kind-ceq'orphan-branch'-and$script:mutations.Count-eq1-and$script:mutations[0]-like'update-ref --no-deref -d *') "orphan-branch-reclaimed-$via";Write-Output "PASS orphan-branch-reclaimed-$via"
  }
  foreach($reason in @('open-child-pr','open-child-pr-authority-unknown','open-pr-authority-unknown','identity-unrecognized','platform-owned-milestone')){Reset-Synthetic;$script:worktrees=@();&$cases[$reason];Assert-Retained $reason 'orphan-branch-retained'}
  Reset-Synthetic;$script:worktrees=@();$script:open.totalCount=1;Assert-Retained 'open-pr-authority-unknown' 'orphan-branch-retained-truncated'
  $changes=[ordered]@{
    'head-only'={$script:wt.head='b'*40}
    'dirt-only'={$script:dirty=$true}
    'ownership-only'={$script:ownership.activeLanes=@(@{worktree=$wt.path})}
    'identity-only'={Write-Dispatch $wt.path $wt.branch '900002-changed'}
    'branch-tip-only'={$script:branches=@(@{branch=$wt.branch;head=('b'*40)})}
    'idle-only'={$script:idle.idleHours=0}
    'branch-only'={$script:wt.branch='codex/900001-changed'}
    'open-pr-only'={$script:open.complete=$false}
    'child-only'={$script:children.openCount=1}
  }
  foreach($change in $changes.GetEnumerator()){
    Reset-Synthetic;$r=Invoke-Synthetic -Observer $change.Value
    Assert-Cleanup ($script:mutations.Count-eq0-and$r.applyResults[0].result-ceq'changed-before-apply') "landed-worktree-changed-before-apply-$($change.Key)";Write-Output "PASS landed-worktree-changed-before-apply-$($change.Key)"
  }
  Reset-Synthetic;$script:worktrees=@();$r=Invoke-Synthetic -Observer {$script:worktrees=@($wt)}
  Assert-Cleanup ($script:mutations.Count-eq0-and$r.applyResults[0].result-ceq'changed-before-apply') 'orphan-branch-attached-before-apply';Write-Output 'PASS orphan-branch-attached-before-apply'
  Reset-Synthetic;$script:branches=@(@{branch=$wt.branch;head=('b'*40)});$r=Invoke-Synthetic;Assert-Cleanup (@($script:mutations|Where-Object{$_-like'update-ref*'}).Count-eq0) 'different branch tip retained'
  Reset-Synthetic;$script:branches=@();$script:wt.detached=$true;$script:wt.branch='';$r=Invoke-Synthetic;Assert-Cleanup ($r.rows[0].identity.recognized-and$script:mutations.Count-eq1) 'detached-bound absent local branch'
  Reset-Synthetic;$script:worktrees+=([pscustomobject]@{path=(Join-Path $root 'unrecognized');head=('b'*40);branch='synthetic/unrecognized';detached=$false;locked=$false})
  $reportPath=Join-Path $root 'report.json';Write-Fixture $reportPath 'old';$r=Invoke-Synthetic -ReportPath $reportPath;$saved=Get-Content $reportPath -Raw|ConvertFrom-Json
  Assert-Cleanup ($saved.schemaVersion-ceq'worktree-reclamation-report/v4'-and$saved.removedCount-eq1-and$saved.retainedCount-eq1-and$saved.applyResults.Count-eq1) 'reclamation-report-written'
  Assert-Cleanup (@(Get-ChildItem $root -Filter 'report.json.*.tmp').Count-eq0) 'atomic report leaves no temporary file';Write-Output 'PASS reclamation-report-written'
  $goodNode=[pscustomobject]@{number=900021;headRefName='synthetic/head';headRefOid=('c'*40);baseRefName='main'}
  function New-Page($Nodes,[int]$Count,[bool]$Next=$false,[string]$Cursor=''){
    [pscustomobject]@{data=@{repository=@{pullRequests=@{totalCount=$Count;nodes=@($Nodes);pageInfo=@{hasNextPage=$Next;endCursor=$Cursor}}}}}
  }
  Assert-Cleanup ((ConvertTo-ReclamationOpenPrAuthority @(New-Page @($goodNode) 1)).complete) 'captured authority row shape'
  $otherNode=[pscustomobject]@{number=900022;headRefName='synthetic/other';headRefOid=('d'*40);baseRefName='main'}
  Assert-Cleanup ((ConvertTo-ReclamationOpenPrAuthority @((New-Page @($goodNode) 2 $true 'cursor1'),(New-Page @($otherNode) 2))).complete) 'paginated authority'
  $badPages=@(
    @{name='missing-branch';pages=@(New-Page @(@{number=900021;headRefOid=('c'*40)}) 1)},
    @{name='missing-sha';pages=@(New-Page @(@{number=900021;headRefName='synthetic/head'}) 1)},
    @{name='duplicate';pages=@(New-Page @($goodNode,$goodNode) 2)},
    @{name='count-mismatch';pages=@(New-Page @($goodNode) 2)},
    @{name='missing-page';pages=@(New-Page @($goodNode) 1 $true 'cursor1')},
    @{name='moving-total';pages=@((New-Page @($goodNode) 2 $true 'cursor1'),(New-Page @($otherNode) 3))},
    @{name='graphql-errors';pages=@(@{errors=@(@{message='synthetic failure'})})}
  )
  foreach($bad in $badPages){Assert-Cleanup (-not(ConvertTo-ReclamationOpenPrAuthority $bad.pages).complete) "authority-$($bad.name)";Write-Output "PASS authority-$($bad.name)"}
  foreach($mutant in @(
    @{name='drop-idle';from='elseif (-not $idleEligible)';to='elseif ($false)';control=$cases['idle-under-six-hours'];reason='idle-under-six-hours'},
    @{name='drop-base';from='$reachable = $baseProbe.exitCode -eq 0';to='$reachable = $true';control=$cases['head-not-in-base'];reason='head-not-in-base'},
    @{name='drop-identity';from='$identity=Get-ReclamationIdentity $candidate $dispatch $register $IssueResolver';to='$identity=Get-ReclamationIdentity $candidate $dispatch $register $IssueResolver; $identity.recognized=$true';control=$cases['identity-unrecognized'];reason='identity-unrecognized'}
  )){
    $source=[IO.File]::ReadAllText($sourcePath);Assert-Cleanup ($source.Contains($mutant.from)) "mutant anchor $($mutant.name)"
    $ast=[Management.Automation.Language.Parser]::ParseInput($source.Replace($mutant.from,$mutant.to),[ref]$null,[ref]$null)
    $inventory=$ast.Find({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq'Get-ReclamationInventory'},$true)
    $original=${function:Get-ReclamationInventory}
    try{
      $body=$inventory.Body.Extent.Text.Trim();Set-Item Function:Get-ReclamationInventory ([scriptblock]::Create($body.Substring(1,$body.Length-2)))
      Reset-Synthetic;&$mutant.control;$killed=$false
      try{Assert-Retained $mutant.reason}catch{if($_.Exception.Message-like'ASSERTION FAILED:*'){$killed=$true;Write-Output "MUTANT_RED $($mutant.name): $($_.Exception.Message)"}else{throw}}
      Assert-Cleanup ($script:mutations.Count-gt0) "mutant must exercise unsafe removal: $($mutant.name)"
      Assert-Cleanup $killed "mutant survived: $($mutant.name)";Write-Output "PASS landed-worktree-mutants KILLED $($mutant.name)"
    }finally{Set-Item Function:Get-ReclamationInventory $original}
  }
  Set-Item Function:Invoke-ReclamationGit $nativeGit;Set-Item Function:Get-ReclamationWorktrees $nativeTrees;Set-Item Function:Get-ReclamationBranches $nativeBranches
  foreach($repositoryKind in @('product','container-meta')){foreach($detached in @($false,$true)){
    $caseRoot=Join-Path $root ("native-$repositoryKind-$detached");New-Item -ItemType Directory $caseRoot|Out-Null;Invoke-TestGit $caseRoot @('init','--initial-branch=main')|Out-Null
    $repository=$caseRoot
    if($repositoryKind-ceq'product'){$repository=Join-Path $caseRoot 'main';New-Item -ItemType Directory $repository|Out-Null;Invoke-TestGit $repository @('init','--initial-branch=main')|Out-Null}
    $expectedAuthorityRepository=Join-Path $caseRoot 'main'
    if($repositoryKind-ceq'container-meta'){New-Item -ItemType Directory $expectedAuthorityRepository|Out-Null;Invoke-TestGit $expectedAuthorityRepository @('init','--initial-branch=main')|Out-Null}
    Invoke-TestGit $repository @('config','user.name','Synthetic Cleanup')|Out-Null;Invoke-TestGit $repository @('config','user.email','cleanup@example.invalid')|Out-Null
    Write-Fixture (Join-Path $repository 'seed.txt') 'synthetic';Invoke-TestGit $repository @('add','seed.txt')|Out-Null;Invoke-TestGit $repository @('commit','-m','synthetic seed')|Out-Null
    $head=Invoke-TestGit $repository @('rev-parse','HEAD');if($repositoryKind-ceq'product'){Invoke-TestGit $repository @('update-ref','refs/remotes/origin/main',$head)|Out-Null}
    $lane=Join-Path $caseRoot 'lane';$branch='codex/900001-synthetic';Invoke-TestGit $repository @('worktree','add','-b',$branch,$lane)|Out-Null
    if($detached){Invoke-TestGit $lane @('checkout','--detach')|Out-Null}
    Reset-Synthetic;Write-Dispatch $lane $branch
    $old=[datetime]::UtcNow.AddHours(-7);Get-ChildItem $lane -Force|ForEach-Object{$_.LastWriteTimeUtc=$old};(Get-Item $lane).LastWriteTimeUtc=$old
    $nativeResolvers=$resolvers.Clone();$nativeResolvers.Remove('IdleResolver');$r=Invoke-WorktreeReclamation $caseRoot $root $root -Apply @nativeResolvers
    Assert-Cleanup ($script:openCalls-eq2-and@($script:authorityRepositories|Where-Object{$_-cne$expectedAuthorityRepository}).Count-eq0) 'both Git inventories use one product PR authority census per pass'
    Assert-Cleanup (-not(Test-Path $lane)-and$r.removedCount-eq1) "native landed-worktree-reclaimed $repositoryKind detached=$detached"
    Assert-Cleanup ((Invoke-ReclamationGit $repository @('show-ref','--verify',"refs/heads/$branch")).exitCode-ne0) 'native exact branch removed'
    Write-Output "PASS landed-worktree-reclaimed $repositoryKind detached=$detached"
    Invoke-TestGit $repository @('symbolic-ref',"refs/heads/$branch",'refs/heads/main')|Out-Null
    $r=Invoke-WorktreeReclamation $caseRoot $root $root -Apply @nativeResolvers
    Assert-Cleanup ($r.applyResults[0].result-ceq'orphan-branch-reclaimed'-and(Invoke-TestGit $repository @('rev-parse','refs/heads/main'))-ceq$head) 'orphan symbolic alias cannot delete protected main'
    Assert-Cleanup ((Invoke-ReclamationGit $repository @('show-ref','--verify',"refs/heads/$branch")).exitCode-ne0) 'native orphan alias removed'
    Write-Output "PASS orphan-branch-reclaimed native protected-alias $repositoryKind detached=$detached"
  }}
  $idleRoot=Join-Path $root 'idle-walk';New-Item -ItemType Directory $idleRoot|Out-Null
  foreach($ignored in @('.git','node_modules')){New-Item -ItemType Directory (Join-Path $idleRoot $ignored)|Out-Null;Write-Fixture (Join-Path $idleRoot "$ignored/fresh") 'synthetic ignored'}
  (Get-Item $idleRoot).LastWriteTimeUtc=[datetime]::UtcNow.AddHours(-7);Assert-Cleanup ((Get-ReclamationIdle $idleRoot).idleHours-ge6) 'idle ignores .git and node_modules'
  Write-Fixture (Join-Path $idleRoot 'fresh') 'synthetic recent';Assert-Cleanup ((Get-ReclamationIdle $idleRoot).idleHours-lt6) 'idle includes newest content'
  Assert-Cleanup (-not(Get-ReclamationIdle (Join-Path $root 'missing')).complete) 'idle missing timestamp retains'
  $skill=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'controller-skills/milestone-orchestrator/SKILL.md')) -replace '\s+',' '
  Assert-Cleanup ($skill.Contains('cleanup-orphan-worktree-dirs.ps1 -Remove -ReportPath')-and$skill.Contains('worktree-reclamation-<yyyyMMddTHHmmssZ>.json')-and$skill.Contains('2026-10-04 directive')) 'cycle and directive contract'
  Write-Output 'PASS cleanup-orphan-worktree-dirs all focused controls'
}finally{
  $resolved=[IO.Path]::GetFullPath($root);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
  if((Split-Path -Parent $resolved).TrimEnd('\','/')-ne$temp-or(Split-Path -Leaf $resolved)-notlike'cleanup-orphan-test-*'){throw 'unsafe cleanup test root'}
  if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
