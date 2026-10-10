[CmdletBinding()]param([string]$EvidenceRoot=[IO.Path]::GetTempPath(),[switch]$KeepEvidence)
$ErrorActionPreference='Stop'
$suiteClock=[Diagnostics.Stopwatch]::StartNew()
[Diagnostics.Process]::GetCurrentProcess().PriorityClass='BelowNormal'
. (Join-Path $PSScriptRoot 'cleanup-orphan-worktree-dirs.ps1')
$sourcePath=Join-Path $PSScriptRoot 'cleanup-orphan-worktree-dirs.ps1'
$root=Join-Path ([IO.Path]::GetFullPath($EvidenceRoot)) ('cleanup-orphan-test-'+[guid]::NewGuid().ToString('N'))
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
  $script:mutations=[Collections.Generic.List[string]]::new();$script:openCalls=0;$script:idleCalls=0
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
function Assert-IdleCallCount {
  foreach($reason in @('identity-unrecognized','dirty','locked','live-owner','head-not-in-base','open-head-pr-branch','open-pr-authority-unknown','open-child-pr')){
    Reset-Synthetic;&$cases[$reason];$r=Invoke-Synthetic -ReportOnly
    Assert-Cleanup ($script:idleCalls-eq0-and$r.rows[0].reasonCode-ceq$reason) "reclamation-idle-call-count $reason calls=$script:idleCalls"
  }
  Reset-Synthetic;$r=Invoke-Synthetic -ReportOnly
  Assert-Cleanup ($script:idleCalls-eq1-and$r.rows[0].removable) 'reclamation-idle-call-count eligible exactly one'
}
function Assert-IdleEarlyExit {
  $script:visited=0
  $r=Get-ReclamationIdle $script:earlyRoot ([datetime]::UtcNow.AddHours(-6)) {param($Entry)$script:visited++}
  Assert-Cleanup ($r.state-ceq'recent'-and$script:visited-eq1-and$null-eq$r.newestWriteUtc) "reclamation-idle-early-exit visited=$script:visited"
}
function Assert-NoReinventory {
  Reset-Synthetic
  $other=[pscustomobject]@{path=(Join-Path $root 'synthetic-other');head=$wt.head;branch='codex/900001-other';detached=$false;locked=$false}
  $script:worktrees+= $other;$script:branches+=@{branch=$other.branch;head=$other.head}
  Add-Content (Join-Path $root 'dispatch-log.jsonl') (@{worktree=$other.path;branch=$other.branch;attemptId='900001-other'}|ConvertTo-Json -Compress)
  $script:inventoryCalls=0;$original=${function:Get-ReclamationInventory}
  $body=$original.ToString();$ast=[Management.Automation.Language.Parser]::ParseInput($body,[ref]$null,[ref]$null)
  $offset=$ast.ParamBlock.Extent.EndOffset
  try{
    Set-Item Function:Get-ReclamationInventory ([scriptblock]::Create($body.Insert($offset,'; $script:inventoryCalls++;')))
    $r=Invoke-Synthetic
    Assert-Cleanup ($script:inventoryCalls-eq1-and$script:idleCalls-eq4-and$r.removedCount-eq2-and$script:openCalls-eq3) "reclamation-apply-no-reinventory inventory=$script:inventoryCalls idle=$script:idleCalls removed=$($r.removedCount)"
  }finally{Set-Item Function:Get-ReclamationInventory $original}
}

function Assert-BatchTransportException {
  $script:throwingGhCalls=0
  function gh {$script:throwingGhCalls++;throw 'synthetic gh process-launch failure'}
  $aliases=[ordered]@{i900001='issueOrPullRequest(number:900001){__typename}';i900002='issueOrPullRequest(number:900002){__typename}'}
  $r=Invoke-ReclamationAliasBatch 'synthetic/repository' $aliases
  Assert-Cleanup ($script:throwingGhCalls-eq1-and$r.Count-eq2) 'launch failure remains one batch'
  foreach($alias in $aliases.Keys){Assert-Cleanup ($null-eq$r[$alias].value-and$r[$alias].reason-ceq'query-failed') 'launch failure fails the whole batch closed'}
  Write-Output 'PASS reclamation-authority-batch-failure process-launch-exception gh=1 aliases=2'
}

function Assert-BatchedAuthority {
  Assert-BatchTransportException
  # Mock the executable boundary, not the batch resolver: every gh invocation,
  # including the unchanged open-head census, is counted here.
  function gh {
    $arguments=@($args);$query=@($arguments|Where-Object{$_-like'query=*'})[0].Substring(6)
    $script:ghCalls.Add($query);$global:LASTEXITCODE=0
    $repository=[ordered]@{};$payload=@{data=@{repository=$repository}}
    if($query.Contains('issueOrPullRequest')){
      Assert-Cleanup ($query.Contains('... on Issue{number milestone{number}}')-and$query.Contains('... on PullRequest{number milestone{number}}')) 'Issue and PR identity fragments'
      $aliases=[regex]::Matches($query,'(?<alias>i[0-9]+):issueOrPullRequest\(number:(?<number>[0-9]+)\)')
      Assert-Cleanup ($aliases.Count-ge1-and$aliases.Count-le100) 'identity request alias bound'
      foreach($alias in $aliases){$repository[$alias.Groups['alias'].Value]=@{number=[int]$alias.Groups['number'].Value;milestone=$null}}
      $kind='issue'
    }elseif($query.Contains('states:MERGED')){
      $aliases=[regex]::Matches($query,'(?<alias>[mc][0-9]+):pullRequests\(states:(?<state>MERGED|OPEN),(?:headRefName|baseRefName):(?<branch>"(?:[^"\\]|\\.)*"),first:(?<first>[12])\)')
      Assert-Cleanup ($aliases.Count-ge2-and$aliases.Count-le100-and$aliases.Count%2-eq0) 'PR request branch bound'
      foreach($alias in $aliases){
        $branch=$alias.Groups['branch'].Value|ConvertFrom-Json
        if($alias.Groups['state'].Value-ceq'MERGED'){
          Assert-Cleanup ($alias.Groups['first'].Value-ceq'2') 'merged first two'
          $nodes=if($script:batchMerged){@(@{number=990001;state='MERGED';headRefName=$branch;headRefOid=('a'*40);mergedAt='2026-10-04T00:00:00Z'})}else{@()}
          $repository[$alias.Groups['alias'].Value]=@{nodes=@($nodes)}
        }else{
          Assert-Cleanup ($alias.Groups['first'].Value-ceq'1') 'child first one'
          $repository[$alias.Groups['alias'].Value]=@{totalCount=0;nodes=@();pageInfo=@{hasNextPage=$false;endCursor=$null}}
        }
      }
      $kind='pr'
    }else{
      Assert-Cleanup ($arguments-contains'--paginate'-and$arguments-contains'--slurp') 'unchanged complete open-head census'
      $repository.pullRequests=@{totalCount=0;nodes=@();pageInfo=@{hasNextPage=$false;endCursor=$null}}
      return ConvertTo-Json -InputObject @($payload) -Depth 20 -Compress
    }
    Assert-Cleanup ($arguments-contains'--include') 'HTTP envelope distinguishes transport from GraphQL errors'
    $response=@{payload=$payload;status=200;code=0;raw=$null}
    if($script:batchFault){&$script:batchFault $kind $repository $response}
    $global:LASTEXITCODE=$response.code
    $body=if($null-ne$response.raw){$response.raw}else{ConvertTo-Json -InputObject $response.payload -Depth 20 -Compress}
    "HTTP/2.0 $($response.status) Synthetic`nContent-Type: application/json`n`n$body"
  }
  function New-BatchRows([int]$Count,[switch]$SharedIssue){
    Reset-Synthetic;$script:worktrees=@();$script:branches=@()
    $dispatch=[Collections.Generic.List[string]]::new()
    for($i=0;$i-lt$Count;$i++){
      $number=if($SharedIssue){900001}else{900001+$i};$branch="codex/$number-batch-$i";$path=Join-Path $root "batch-$i"
      $script:worktrees+= [pscustomobject]@{path=$path;head=('a'*40);branch=$branch;detached=$false;locked=$false}
      $script:branches+= [pscustomobject]@{branch=$branch;head=('a'*40)}
      $dispatch.Add((@{worktree=$path;branch=$branch;attemptId="$number-batch"}|ConvertTo-Json -Compress))
    }
    Write-Fixture (Join-Path $root 'dispatch-log.jsonl') (($dispatch-join"`n")+"`n")
    $script:batchFault=$null;$script:batchMerged=$false
  }
  function Invoke-BatchRows([switch]$Apply,[scriptblock]$BeforeApply){
    $script:ghCalls=[Collections.Generic.List[string]]::new();$script:statusPaths=[Collections.Generic.List[string]]::new()
    Invoke-WorktreeReclamation $root $root $root -Apply:$Apply -OwnershipResolver $resolvers.OwnershipResolver -IdleResolver $resolvers.IdleResolver -BeforeApplyObserver $BeforeApply
  }
  function Assert-BatchBound([int]$Count=300,[switch]$SharedIssue){
    New-BatchRows $Count -SharedIssue:$SharedIssue
    $timer=[Diagnostics.Stopwatch]::StartNew();$r=Invoke-BatchRows
    $issues=if($SharedIssue){1}else{$Count};$bound=[Math]::Ceiling($issues/100)+[Math]::Ceiling($Count/50)+1
    Assert-Cleanup ($r.rows.Count-eq$Count-and@($r.rows|Where-Object{$_.removable}).Count-eq$Count) 'batch control evaluates every row'
    Assert-Cleanup (($script:statusPaths-join'|')-ceq($script:worktrees.path-join'|')) 'serial status exactly once in worktree order'
    Assert-Cleanup ($script:ghCalls.Count-eq$bound) "reclamation-authority-batched rows=$Count distinctIssues=$issues gh=$($script:ghCalls.Count) bound=$bound"
    Write-Output "PASS reclamation-authority-batched rows=$Count distinctIssues=$issues gh=$($script:ghCalls.Count) fixed=1 wallMs=$($timer.Elapsed.TotalMilliseconds)"
  }
  Assert-BatchBound
  Assert-BatchBound 301
  Assert-BatchBound 300 -SharedIssue
  # Same aliases must be resolved again on the next pass and each apply target.
  New-BatchRows 2;$r=Invoke-BatchRows -Apply -BeforeApply {$script:batchFault={param($Kind,$Repository,$Response)if($Kind-ceq'issue'){$Repository.i900001=$null}}}
  Assert-Cleanup ($r.removedCount-eq1-and$r.applyResults[0].result-ceq'changed-before-apply'-and$script:ghCalls.Count-eq8) 'fresh single-target batches refuse changed identity without full reinventory'
  Write-Output "PASS reclamation-authority-fresh-target gh=$($script:ghCalls.Count) removed=$($r.removedCount)"

  foreach($kind in @('issue','pr')){foreach($failure in @('http','transport','malformed','missing-data','unpathed','unknown-alias','nonzero-no-errors')){
    New-BatchRows 2
    $script:batchFailure=$failure
    $script:batchFault={param($Kind,$Repository,$Response)
      if($Kind-cne$failureKind){return}
      switch($script:batchFailure){
        'http' {$Response.status=503;$Response.code=1}
        'transport' {$Response.status=0;$Response.code=1;$Response.raw=''}
        'malformed' {$Response.raw='{'}
        'missing-data' {$Response.payload=@{errors=@(@{path=@('repository','i900001')})}}
        'unpathed' {$Response.payload.errors=@(@{message='synthetic whole failure'});$Response.code=1}
        'unknown-alias' {$Response.payload.errors=@(@{path=@('repository','unexpected')});$Response.code=1}
        'nonzero-no-errors' {$Response.code=1}
      }
    }
    $failureKind=$kind;$r=Invoke-BatchRows
    $reason=if($kind-ceq'issue'){'issue-unreadable'}else{'open-child-pr-authority-unknown'}
    Assert-Cleanup (@($r.rows|Where-Object{$_.reasonCode-ceq$reason-and-not$_.removable}).Count-eq2) "whole-batch $kind $failure"
    Write-Output "PASS reclamation-authority-batch-failure whole=$kind/$failure gh=$($script:ghCalls.Count)"
  }}
  foreach($failure in @('missing','null','wrong-number','missing-milestone','error')){
    New-BatchRows 2
    $script:batchFailure=$failure
    $script:batchFault={param($Kind,$Repository,$Response)
      if($Kind-cne'issue'){return}
      switch($script:batchFailure){
        'missing' {$Repository.Remove('i900001')}
        'null' {$Repository.i900001=$null}
        'wrong-number' {$Repository.i900001.number=900002}
        'missing-milestone' {$Repository.i900001.Remove('milestone')}
        'error' {$Response.payload.errors=@(@{path=@('repository','i900001','milestone')});$Response.code=1}
      }
    }
    $r=Invoke-BatchRows
    Assert-Cleanup ($r.rows[0].reasonCode-ceq'issue-unreadable'-and$r.rows[1].removable) "issue alias isolation $failure"
    Write-Output "PASS reclamation-authority-batch-failure alias=issue/$failure gh=$($script:ghCalls.Count)"
  }
  foreach($failure in @('missing','null','error','count','truncated','wrong-base','wrong-state','present')){
    New-BatchRows 2
    $script:batchFailure=$failure
    $script:batchFault={param($Kind,$Repository,$Response)
      if($Kind-cne'pr'){return}
      switch($script:batchFailure){
        'missing' {$Repository.Remove('c0')}
        'null' {$Repository.c0=$null}
        'error' {$Response.payload.errors=@(@{path=@('repository','c0')});$Response.code=1}
        'count' {$Repository.c0.totalCount=-1}
        'truncated' {$Repository.c0.pageInfo.hasNextPage=$true}
        default {
          $Repository.c0.totalCount=1;$Repository.c0.nodes=@(@{number=990002;state='OPEN';baseRefName='codex/900001-batch-0'})
          if($script:batchFailure-ceq'wrong-base'){$Repository.c0.nodes[0].baseRefName='synthetic/wrong'}
          if($script:batchFailure-ceq'wrong-state'){$Repository.c0.nodes[0].state='CLOSED'}
        }
      }
    }
    $r=Invoke-BatchRows;$reason=if($failure-ceq'present'){'open-child-pr'}else{'open-child-pr-authority-unknown'}
    Assert-Cleanup ($r.rows[0].reasonCode-ceq$reason-and$r.rows[1].removable) "child alias isolation $failure"
    $detail=switch($failure){'missing'{'response-ambiguous'} 'null'{'response-ambiguous'} 'error'{'query-failed'} 'count'{'count-ambiguous'} 'truncated'{'zero-result-truncated'} 'present'{'open-child-prs-present'} default{'open-result-ambiguous'}}
    Assert-Cleanup ($r.rows[0].openChildAuthority.reason-ceq$detail) "child existing completeness reason $failure"
    Write-Output "PASS reclamation-authority-batch-failure alias=child/$failure reason=$detail gh=$($script:ghCalls.Count)"
  }
  foreach($failure in @('missing','null','error','duplicate','wrong-head','wrong-branch','wrong-state','exact')){
    New-BatchRows 2;$script:batchMerged=$true;$script:reachable=$false
    $script:batchFailure=$failure
    $script:batchFault={param($Kind,$Repository,$Response)
      if($Kind-cne'pr'){return}
      switch($script:batchFailure){
        'missing' {$Repository.Remove('m0')}
        'null' {$Repository.m0=$null}
        'error' {$Response.payload.errors=@(@{path=@('repository','m0')});$Response.code=1}
        'duplicate' {$Repository.m0.nodes+= $Repository.m0.nodes[0]}
        'wrong-head' {$Repository.m0.nodes[0].headRefOid='b'*40}
        'wrong-branch' {$Repository.m0.nodes[0].headRefName='synthetic/wrong'}
        'wrong-state' {$Repository.m0.nodes[0].state='OPEN'}
      }
    }
    $r=Invoke-BatchRows;$reason=if($failure-ceq'exact'){'exact-merged-pr-zero-open-children'}else{'head-not-in-base'}
    Assert-Cleanup ($r.rows[0].reasonCode-ceq$reason-and$r.rows[1].reasonCode-ceq'exact-merged-pr-zero-open-children') "merged alias isolation $failure"
    Write-Output "PASS reclamation-authority-batch-failure alias=merged/$failure gh=$($script:ghCalls.Count)"
  }
  # Bound failures to one request as well as one alias; never poison the next batch.
  New-BatchRows 101;$script:batchFault={param($Kind,$Repository,$Response)if($Kind-ceq'issue'-and$Repository.Contains('i900001')){$Response.status=503;$Response.code=1}}
  $r=Invoke-BatchRows
  Assert-Cleanup (@($r.rows|Where-Object{$_.reasonCode-ceq'issue-unreadable'}).Count-eq100-and@($r.rows|Where-Object{$_.removable}).Count-eq1) 'whole issue failure limited to its batch'
  New-BatchRows 51;$script:batchFault={param($Kind,$Repository,$Response)if($Kind-ceq'pr'-and$Repository.Contains('c0')){$Response.status=503;$Response.code=1}}
  $r=Invoke-BatchRows
  Assert-Cleanup (@($r.rows|Where-Object{$_.reasonCode-ceq'open-child-pr-authority-unknown'}).Count-eq50-and@($r.rows|Where-Object{$_.removable}).Count-eq1) 'whole PR failure limited to its batch'
  Write-Output 'PASS reclamation-authority-batch-failure request-boundaries'

  $original=${function:Get-ReclamationRows};$body=$original.ToString()
  $issueAnchor='$issues=Get-ReclamationIssueBatch $numbers';$prAnchor='$prs=Get-ReclamationPrBatch $Context.authorityRepository $eligible'
  Assert-Cleanup ($body.Contains($issueAnchor)-and$body.Contains($prAnchor)) 'per-row-authority mutant anchors'
  $body=$body.Replace($issueAnchor,'$issues=@{}; foreach($number in $numbers){$issues[$number]=Get-ReclamationIssue $number}')
  $body=$body.Replace($prAnchor,'$prs=@{}; foreach($branch in $eligible){$one=Get-ReclamationPrBatch $Context.authorityRepository @($branch); $prs[$branch]=$one[$branch]}')
  try{
    Set-Item Function:Get-ReclamationRows ([scriptblock]::Create($body));$killed=$false
    try{Assert-BatchBound}catch{if($_.Exception.Message-like'ASSERTION FAILED: reclamation-authority-batched*'){$killed=$true;Write-Output "MUTANT_RED per-row-authority: $($_.Exception.Message)"}else{throw}}
    Assert-Cleanup ($killed-and$script:ghCalls.Count-eq601) 'per-row-authority killed by actual gh calls, not loader failure'
    Write-Output 'PASS landed-worktree-mutants KILLED per-row-authority gh=601 bound=10'
  }finally{Set-Item Function:Get-ReclamationRows $original;$script:statusPaths=$null}
}
try {
  New-Item -ItemType Directory -Path $root|Out-Null
  $resolvers=@{
    OwnershipResolver={param($Runtime,$Temp,$Container)$script:ownership}
    PrResolver={param($Repository,$Branch,$Head)$script:authorityRepositories.Add($Repository);if($script:merged){[pscustomobject]@{number=900011;state='MERGED';headRefName=$Branch;headRefOid=$Head}}}
    ChildPrResolver={param($Repository,$Branch)$script:authorityRepositories.Add($Repository);$script:children}
    OpenPrResolver={param($Repository)$script:authorityRepositories.Add($Repository);$script:openCalls++;$script:open}
    IssueResolver={param($Number)$script:issue}
    IdleResolver={param($Path,$Cutoff)$script:idleCalls++;$script:idle}
  }
  $nativeGit=${function:Invoke-ReclamationGit};$nativeTrees=${function:Get-ReclamationWorktrees};$nativeBranches=${function:Get-ReclamationBranches}
  function Get-ReclamationWorktrees([string]$RepositoryRoot){@($script:worktrees)}
  function Get-ReclamationBranches([string]$RepositoryRoot){@($script:branches)}
  function Invoke-ReclamationGit([string]$At,[string[]]$Arguments){
    $text='';$code=0
    switch($Arguments[0]){
      'status' {if($null-ne$script:statusPaths){$script:statusPaths.Add($At)};if($script:dirty){$text='?? synthetic-dirt'}}
      'config' {$text='https://github.com/synthetic/reclamation-test.git'}
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
  Assert-IdleCallCount;Write-Output 'PASS reclamation-idle-call-count'
  # A recent result is partial even if wall time crosses the six-hour boundary
  # between detecting its entry and calculating idleHours.
  Reset-Synthetic;$script:idle=[pscustomobject]@{complete=$true;state='recent';newestWriteUtc=$null;idleHours=6}
  Assert-Retained 'idle-under-six-hours' 'reclamation-recent-boundary'
  Assert-NoReinventory;Write-Output 'PASS reclamation-apply-no-reinventory'
  $script:earlyRoot=Join-Path $root 'early-exit';[void][IO.Directory]::CreateDirectory($script:earlyRoot)
  for($i=0;$i-lt100;$i++){Write-Fixture (Join-Path $script:earlyRoot "$i.txt") 'synthetic'}
  Assert-IdleEarlyExit;Write-Output 'PASS reclamation-idle-early-exit'
  $script:visited=0;$full=Get-ReclamationIdle $script:earlyRoot $null {param($Entry)$script:visited++}
  Assert-Cleanup ($full.complete-and$full.newestWriteUtc-and$script:visited-eq101) 'exact-merged full newest observation, even recent'
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
  foreach($mergedCase in @($false,$true)){
    Reset-Synthetic;$script:merged=$mergedCase
    $r=Invoke-Synthetic -Observer {$script:idle=[pscustomobject]@{complete=$true;newestWriteUtc='2026-10-03T23:00:00Z';idleHours=13}}
    Assert-Cleanup ($script:mutations.Count-eq0-and$r.applyResults[0].result-ceq'changed-before-apply') "newest-write-changed-before-apply merged=$mergedCase"
  }
  foreach($change in @({$script:wt.locked=$true},{Write-Register 7001},{$script:reachable=$false},{$script:worktrees=@()})){
    Reset-Synthetic;$r=Invoke-Synthetic -Observer $change
    Assert-Cleanup ($script:mutations.Count-eq0-and$r.applyResults[0].result-ceq'changed-before-apply') 'fresh lock/register/base/worktree refusal'
  }
  Reset-Synthetic;$script:worktrees=@();$r=Invoke-Synthetic -Observer {$script:wt.detached=$true;$script:wt.branch='';$script:worktrees=@($wt)}
  Assert-Cleanup ($script:mutations.Count-eq0) 'orphan bound-detached attachment refusal'
  $originalTarget=${function:Get-ReclamationTarget}
  try{
    Set-Item Function:Get-ReclamationTarget ([scriptblock]::Create($originalTarget.ToString().Replace('([datetime]::UtcNow-$ObservedAt).TotalHours','([datetime]::UtcNow-$ObservedAt.AddHours(-6)).TotalHours')))
    Reset-Synthetic;$r=Invoke-Synthetic
    Assert-Cleanup ($script:mutations.Count-eq0-and$r.applyResults[0].result-ceq'changed-before-apply') 'stale landed report refused'
    Reset-Synthetic;$script:merged=$true;$script:idle.idleHours=0;$r=Invoke-Synthetic
    Assert-Cleanup ($script:mutations.Count-eq2) 'stale landed-only rule does not change exact-merged eligibility'
  }finally{Set-Item Function:Get-ReclamationTarget $originalTarget}
  Write-Output 'PASS reclamation-apply-route-and-observation-refusals'
  Reset-Synthetic;$script:merged=$true;$script:reachable=$false
  [void][IO.Directory]::CreateDirectory($wt.path)
  $leaf=Join-Path $wt.path 'recent.txt';Write-Fixture $leaf 'synthetic'
  $nativeResolvers=$resolvers.Clone();$nativeResolvers.Remove('IdleResolver')
  $r=Invoke-WorktreeReclamation $root $root $root -Apply @nativeResolvers -BeforeApplyObserver {
    [IO.File]::SetLastWriteTimeUtc($leaf,[datetime]::UtcNow.AddMinutes(1))
  }
  Assert-Cleanup ($r.rows[0].idle.state-ceq'complete'-and$r.rows[0].idle.newestWriteUtc-and$script:mutations.Count-eq0-and$r.applyResults[0].result-ceq'changed-before-apply') 'exact-merged native newest-write comparison cannot use recent/null shortcut'
  Write-Output 'PASS exact-merged-native-newest-write-changed-before-apply'
  Reset-Synthetic;$script:branches=@(@{branch=$wt.branch;head=('b'*40)});$r=Invoke-Synthetic;Assert-Cleanup (@($script:mutations|Where-Object{$_-like'update-ref*'}).Count-eq0) 'different branch tip retained'
  Reset-Synthetic;$script:branches=@();$script:wt.detached=$true;$script:wt.branch='';$r=Invoke-Synthetic;Assert-Cleanup ($r.rows[0].identity.recognized-and$script:mutations.Count-eq1) 'detached-bound absent local branch'
  Reset-Synthetic;$script:worktrees+=([pscustomobject]@{path=(Join-Path $root 'unrecognized');head=('b'*40);branch='synthetic/unrecognized';detached=$false;locked=$false})
  $reportPath=Join-Path $root 'report.json';Write-Fixture $reportPath 'old';$r=Invoke-Synthetic -ReportPath $reportPath;$saved=Get-Content $reportPath -Raw|ConvertFrom-Json
  Assert-Cleanup ($saved.schemaVersion-ceq'worktree-reclamation-report/v4'-and$saved.removedCount-eq1-and$saved.retainedCount-eq1-and$saved.applyResults.Count-eq1) 'reclamation-report-written'
  foreach($key in @('inventory','idle','authority','apply','total')){
    Assert-Cleanup ($key-cin$saved.phaseTimings.PSObject.Properties.Name-and$saved.phaseTimings.$key-ge0) "reclamation-report-written timing $key"
  }
  Assert-Cleanup ($saved.phaseTimings.total-ge$saved.phaseTimings.inventory-and$saved.phaseTimings.total-ge$saved.phaseTimings.apply-and$saved.phaseTimings.idle-gt0-and$saved.phaseTimings.authority-gt0) 'independent total covers nested phases'
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
  Assert-BatchedAuthority
  foreach($mutant in @(
    @{name='drop-idle';function='Get-ReclamationRow';from='elseif (-not $idleEligible)';to='elseif ($false)';control=$cases['idle-under-six-hours'];reason='idle-under-six-hours'},
    @{name='drop-base';function='Get-ReclamationRow';from='$reachable = $baseProbe.exitCode -eq 0';to='$reachable = $true';control=$cases['head-not-in-base'];reason='head-not-in-base'},
    @{name='drop-identity';function='Get-ReclamationRowPreparation';from='$identity=Get-ReclamationIdentity $candidate $dispatch $register $IssueResolver';to='$identity=Get-ReclamationIdentity $candidate $dispatch $register $IssueResolver; $identity.recognized=$true';control=$cases['identity-unrecognized'];reason='identity-unrecognized'}
  )){
    $source=[IO.File]::ReadAllText($sourcePath);Assert-Cleanup ($source.Contains($mutant.from)) "mutant anchor $($mutant.name)"
    $ast=[Management.Automation.Language.Parser]::ParseInput($source.Replace($mutant.from,$mutant.to),[ref]$null,[ref]$null)
    $inventory=$ast.Find({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq$mutant.function},$true)
    $original=(Get-Item "Function:$($mutant.function)").ScriptBlock
    try{
      $body=$inventory.Body.Extent.Text.Trim();Set-Item "Function:$($mutant.function)" ([scriptblock]::Create($body.Substring(1,$body.Length-2)))
      Reset-Synthetic;&$mutant.control;$killed=$false
      try{Assert-Retained $mutant.reason}catch{if($_.Exception.Message-like'ASSERTION FAILED:*'){$killed=$true;Write-Output "MUTANT_RED $($mutant.name): $($_.Exception.Message)"}else{throw}}
      Assert-Cleanup ($script:mutations.Count-gt0) "mutant must exercise unsafe removal: $($mutant.name)"
      Assert-Cleanup $killed "mutant survived: $($mutant.name)";Write-Output "PASS landed-worktree-mutants KILLED $($mutant.name)"
    }finally{Set-Item "Function:$($mutant.function)" $original}
  }
  foreach($mutant in @(
    @{name='remove-early-exit';function='Get-ReclamationIdle';from='if($null-ne$RecentCutoff-and$newest-gt$RecentCutoff)';to='if($false)';probe={Assert-IdleEarlyExit}},
    @{name='walk-before-cheap-predicates';function='Get-ReclamationRow';from='$open=$Context.open;$pr=$null;$child=$null;$idle=$null;$reachable=$null';to='$open=$Context.open;$pr=$null;$child=$null;$idle=$null;$reachable=$null; if(-not$orphan){$null=&$IdleResolver $path ([datetime]::UtcNow.AddHours(-6))}';probe={Assert-IdleCallCount}},
    @{name='per-target-full-reinventory';function='Invoke-WorktreeReclamation';from='$fresh=Get-ReclamationTarget -Target $target -ObservedAt $initial.observedAt @inventoryArgs';to='$current=Get-ReclamationInventory @inventoryArgs; $fresh=@($current.rows|Where-Object{$_.repository-ceq$target.repository-and$_.kind-ceq$target.kind-and$_.branch-ceq$target.branch-and(Test-ReclamationSamePath $_.canonicalPath $target.canonicalPath)})[0]';probe={Assert-NoReinventory}}
  )){
    $source=[IO.File]::ReadAllText($sourcePath);Assert-Cleanup ($source.Contains($mutant.from)) "mutant anchor $($mutant.name)"
    $errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($source.Replace($mutant.from,$mutant.to),[ref]$null,[ref]$errors)
    Assert-Cleanup ($errors.Count-eq0) "mutant parses $($mutant.name)"
    $definition=$ast.Find({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq$mutant.function},$true)
    $original=(Get-Item "Function:$($mutant.function)").ScriptBlock
    try{
      $parameters=if($definition.Parameters.Count){'param('+($definition.Parameters.Extent.Text-join',')+")`n"}else{''}
      $body=$definition.Body.Extent.Text.Trim();Set-Item "Function:$($mutant.function)" ([scriptblock]::Create($parameters+$body.Substring(1,$body.Length-2)))
      if($mutant.name-ceq'remove-early-exit'){
        $script:visited=0;$control=Get-ReclamationIdle $script:earlyRoot ([datetime]::UtcNow.AddHours(-6)) {param($Entry)$script:visited++}
        Assert-Cleanup ($control.complete-and$control.state-ceq'complete'-and$script:visited-eq101) 'early-exit mutant really completes the full walk'
      }
      $killed=$false
      try{&$mutant.probe}catch{if($_.Exception.Message-like'ASSERTION FAILED:*'){$killed=$true;Write-Output "MUTANT_RED $($mutant.name): $($_.Exception.Message)"}else{throw}}
      Assert-Cleanup $killed "mutant survived: $($mutant.name)";Write-Output "PASS landed-worktree-mutants KILLED $($mutant.name)"
    }finally{Set-Item "Function:$($mutant.function)" $original}
  }
  # Compare the installed #8622 classifier on the same synthetic authority and
  # worktree state. The baseline is immutable, not a second implementation.
  $baselineBytes=[IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'fixtures/cleanup-orphan-worktree-dirs.pre-8670.ps1'))
  $baselineHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($baselineBytes)).ToLowerInvariant()
  Assert-Cleanup ($baselineBytes.Length-eq28742-and$baselineHash-ceq'408074cb0f0f29329544253616f752716fba064711a6d8439bb238d33faebcd6') 'exact LF installed baseline fixture hash and size'
  $baselineSource=[Text.UTF8Encoding]::new($false,$true).GetString($baselineBytes)
  $ast=[Management.Automation.Language.Parser]::ParseInput($baselineSource,[ref]$null,[ref]$null)
  $definition=$ast.Find({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq'Get-ReclamationInventory'},$true)
  $body=$definition.Body.Extent.Text.Trim();$baselineInventory=[scriptblock]::Create($body.Substring(1,$body.Length-2))
  $equivalence=[ordered]@{landed={};'exact-merged'={$script:merged=$true;$script:reachable=$false;$script:idle.idleHours=0};'orphan-base'={$script:worktrees=@()};'orphan-merged'={$script:worktrees=@();$script:merged=$true;$script:reachable=$false};'orphan-neither'={$script:worktrees=@();$script:reachable=$false}}
  foreach($case in $cases.GetEnumerator()){$equivalence[$case.Key]=$case.Value}
  foreach($case in $equivalence.GetEnumerator()){
    Reset-Synthetic;&$case.Value
    $before=&$baselineInventory $root $root $root @resolvers
    if($case.Key-ceq'identity-unrecognized'){
      Assert-Cleanup ($script:idleCalls-eq1) 'baseline reproduces walk before identity refusal'
      Write-Output 'BASELINE_REPRO idleCalls=1 for identity-unrecognized (candidate requires zero)'
    }
    $after=Invoke-Synthetic -ReportOnly
    $fields=@('kind','canonicalPath','head','branch','branchTip','branchRemovable','detached','locked','clean','removable','reasonCode')
    Assert-Cleanup (($before.rows|Select-Object $fields|ConvertTo-Json -Compress)-ceq($after.rows|Select-Object $fields|ConvertTo-Json -Compress)) "baseline removable-set equivalence $($case.Key)"
  }
  Write-Output "PASS reclamation-baseline-equivalence cases=$($equivalence.Count)"
  # AC4 measures report mode only; construction is separately timed and bounded.
  Reset-Synthetic;$script:worktrees=@();$script:branches=@();$dispatchRows=[Collections.Generic.List[string]]::new()
  $scaleRoot=Join-Path $root 'scale';[void][IO.Directory]::CreateDirectory($scaleRoot)
  $scaleCpuStart=(Get-CimInstance Win32_Processor|Measure-Object LoadPercentage -Average).Average
  Write-Output "SCALE_START cpu=$scaleCpuStart root=$scaleRoot"
  $construction=[Diagnostics.Stopwatch]::StartNew()
  for($tree=0;$tree-lt200;$tree++){
    if($construction.Elapsed.TotalMinutes-ge12){throw 'scale fixture construction exceeded 12 minute safety bound'}
    $path=Join-Path $scaleRoot ('tree-{0:d3}'-f$tree);[void][IO.Directory]::CreateDirectory($path)
    for($file=0;$file-lt2000;$file++){[IO.File]::WriteAllText([IO.Path]::Combine($path,('{0:d4}.txt'-f$file)),'synthetic')}
    $branch="codex/900001-scale-$tree";$script:worktrees+=@{path=$path;head=('a'*40);branch=$branch;detached=$false;locked=$false}
    $script:branches+=@{branch=$branch;head=('a'*40)}
    if($tree%4-eq0){$dispatchRows.Add((@{worktree=$path;branch=$branch;attemptId='900001-scale'}|ConvertTo-Json -Compress))}
  }
  Write-Fixture (Join-Path $root 'dispatch-log.jsonl') (($dispatchRows-join"`n")+"`n")
  $construction.Stop()
  $scaleResolvers=$resolvers.Clone();$scaleResolvers.Remove('IdleResolver')
  $scaleReport=Join-Path $root 'scale-report.json'
  $wall=Measure-Command {$script:scaleResult=Invoke-WorktreeReclamation $root $root $root @scaleResolvers -ReportPath $scaleReport}
  $scaleCpuEnd=(Get-CimInstance Win32_Processor|Measure-Object LoadPercentage -Average).Average
  Assert-Cleanup ($wall.TotalSeconds-lt60-and$script:scaleResult.rows.Count-eq200-and@($script:scaleResult.rows|Where-Object{$_.removable}).Count-eq0) 'reclamation-scale-bound 200 x 2000 report under 60 seconds'
  Assert-Cleanup (@($script:scaleResult.rows|Where-Object{$_.reasonCode-ceq'identity-unrecognized'}).Count-eq150-and@($script:scaleResult.rows|Where-Object{$_.reasonCode-ceq'idle-under-six-hours'-and$_.idle.state-ceq'recent'}).Count-eq50) 'scale exercises cheap refusal and native early exit'
  Assert-Cleanup ($script:scaleResult.phaseTimings.total-lt300000-and$script:scaleResult.phaseTimings.total-le$wall.TotalMilliseconds) 'AC6 synthetic dry-run total under 300000 ms'
  Write-Output "PASS reclamation-scale-bound trees=200 filesPerTree=2000 constructionMs=$($construction.Elapsed.TotalMilliseconds) reportWallMs=$($wall.TotalMilliseconds) totalMs=$($script:scaleResult.phaseTimings.total) cpuStart=$scaleCpuStart cpuEnd=$scaleCpuEnd report=$scaleReport"
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
  $old=[datetime]::UtcNow.AddHours(-7);$junction=Join-Path $root 'idle-junction';$destination=Join-Path $root 'junction-destination'
  [void][IO.Directory]::CreateDirectory($destination);[void][IO.Directory]::CreateDirectory($junction)
  New-Item -ItemType Junction -Path (Join-Path $junction 'redirect') -Target $destination|Out-Null
  [IO.Directory]::SetLastWriteTimeUtc($junction,$old)
  Assert-Cleanup ((Get-ReclamationIdle $junction ([datetime]::UtcNow.AddHours(-6))).state-ceq'idle-unreadable') 'reclamation-idle-unreadable reparse'
  $unreadable=Join-Path $root 'idle-enumeration-error';[void][IO.Directory]::CreateDirectory($unreadable);[IO.Directory]::SetLastWriteTimeUtc($unreadable,$old)
  $failed=Get-ReclamationIdle $unreadable ([datetime]::UtcNow.AddHours(-6)) {param($Entry)[IO.Directory]::Delete($Entry.FullName)}
  Assert-Cleanup ($failed.state-ceq'idle-unreadable') 'reclamation-idle-unreadable enumeration error'
  $oldTree=Join-Path $root 'idle-complete';[void][IO.Directory]::CreateDirectory($oldTree);$leaf=Join-Path $oldTree 'old.txt';Write-Fixture $leaf 'synthetic'
  [IO.File]::SetLastWriteTimeUtc($leaf,$old.AddMinutes(1));[IO.Directory]::SetLastWriteTimeUtc($oldTree,$old)
  $complete=Get-ReclamationIdle $oldTree ([datetime]::UtcNow.AddHours(-6))
  Assert-Cleanup ($complete.complete-and$complete.newestWriteUtc-ceq$old.AddMinutes(1).ToString('o')) 'completed idle walk preserves newest timestamp'
  Write-Output 'PASS reclamation-idle-unreadable reparse and enumeration; completed newest timestamp'
  $skill=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'controller-skills/milestone-orchestrator/SKILL.md')) -replace '\s+',' '
  Assert-Cleanup ($skill.Contains('cleanup-orphan-worktree-dirs.ps1 -Remove -ReportPath')-and$skill.Contains('worktree-reclamation-<yyyyMMddTHHmmssZ>.json')-and$skill.Contains('2026-10-04 directive')) 'cycle and directive contract'
  Write-Output 'PASS cleanup-orphan-worktree-dirs all focused controls'
}finally{
  $teardown=[Diagnostics.Stopwatch]::StartNew()
  $resolved=[IO.Path]::GetFullPath($root);$evidence=[IO.Path]::GetFullPath($EvidenceRoot).TrimEnd('\','/')
  if((Split-Path -Parent $resolved).TrimEnd('\','/')-ne$evidence-or(Split-Path -Leaf $resolved)-notlike'cleanup-orphan-test-*'){throw 'unsafe cleanup test root'}
  if($KeepEvidence){Write-Output "EVIDENCE_ROOT $resolved"}
  elseif(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
  # Inclusive phase receipt: scale construction and report, synchronous root
  # teardown, and the in-process full item measured from script start.
  $teardown.Stop();Write-Output "PHASE scale constructionMs=$($construction.Elapsed.TotalMilliseconds) reportMs=$($wall.TotalMilliseconds) teardownMs=$($teardown.Elapsed.TotalMilliseconds) fullItemMs=$($suiteClock.Elapsed.TotalMilliseconds)"
}
