<#
.SYNOPSIS
Consumes one landed PR identity, performs a complete open-PR/file census, and
dispatches exactly one own-branch integration for each intersecting, DIRTY, or
CONFLICTING PR. Unknown or incomplete authority dispatches nothing.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateRange(1,[int]::MaxValue)][int]$LandedPr,
  [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string]$LandedHead,
  [string]$Repository='chase-sets/chase-sets',
  [string]$RecoverCompletedRebasePath,
  [string]$HistoryPath=(Join-Path $PSScriptRoot 'dispatch-log.jsonl'),
  [string]$RuntimeRoot=$PSScriptRoot,
  [string]$ContainerRoot=(Split-Path -Parent $PSScriptRoot),
  [Parameter(DontShow)][string]$FixturePath,
  [Parameter(DontShow)][string]$GraphFixturePath,
  [Parameter(DontShow)][string]$IntegrationAuthorityFixturePath,
  [Parameter(DontShow)][string]$PoolStatusFixturePath,
  [Parameter(DontShow)][string]$DispatchScript=(Join-Path $PSScriptRoot 'dispatch-lane.ps1'),
  [Parameter(DontShow)][string]$LogScript=(Join-Path $PSScriptRoot 'log-event.ps1'),
  [Parameter(DontShow)][string]$ActiveSnapshotObservedPath,
  [Parameter(DontShow)][string]$PublicationContinuePath,
  [Parameter(DontShow)][scriptblock]$BeforeApply,
  [Parameter(DontShow)][string]$HandoffEnteredPath,
  [Parameter(DontShow)][string]$HandoffContinuePath,
  [Parameter(DontShow)][string]$HandoffGitExecutable='git',
  [Parameter(DontShow)][switch]$NoPushIntegration,
  [Parameter(DontShow)][switch]$SynchronousDispatch
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'dispatch-ownership.ps1')
. (Join-Path $PSScriptRoot 'integration-dispatch-contract.ps1')
Import-Module (Join-Path $PSScriptRoot 'review-head-contract.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'landed-integration-evidence.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'fleet-exclusive-admission.psm1') -Force -DisableNameChecking

$graphFixture=$null
$graphFixtureIndex=0
$ownershipInvalid=@{}
$ownershipSnapshots=@{}
if($GraphFixturePath){
  $graphFixture=@(Get-Content -LiteralPath $GraphFixturePath -Raw|ConvertFrom-Json -DateKind String -ErrorAction Stop)
  if($graphFixture.Count-lt1){throw 'CENSUS_UNKNOWN_GRAPH_FIXTURE'}
}

function Invoke-Native([string]$File,[string[]]$Arguments){
  $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$File;$start.UseShellExecute=$false
  $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
  foreach($argument in $Arguments){[void]$start.ArgumentList.Add($argument)}
  $process=[Diagnostics.Process]::Start($start)
  try{$stdout=$process.StandardOutput.ReadToEnd();$stderr=$process.StandardError.ReadToEnd();$process.WaitForExit();if($process.ExitCode-ne0){throw "$File failed ($($stderr.Trim()))"};return $stdout.Trim()}finally{$process.Dispose()}
}
function Invoke-Graph([string]$Query,[hashtable]$Variables){
  if($GraphFixturePath){
    if($script:graphFixtureIndex-ge$script:graphFixture.Count){throw 'CENSUS_UNKNOWN_GRAPH_ERROR'}
    $entry=$script:graphFixture[$script:graphFixtureIndex++]
    if(-not[string]::IsNullOrWhiteSpace([string]$entry.queryContains)-and-not$Query.Contains([string]$entry.queryContains,[StringComparison]::Ordinal)){throw 'CENSUS_UNKNOWN_GRAPH_QUERY'}
    foreach($property in @($entry.variables.PSObject.Properties)){
      if(-not$Variables.ContainsKey($property.Name)){throw 'CENSUS_UNKNOWN_GRAPH_VARIABLE'}
      if($null-eq$property.Value){if($null-ne$Variables[$property.Name]){throw 'CENSUS_UNKNOWN_GRAPH_VARIABLE'}}
      elseif([string]$Variables[$property.Name]-cne[string]$property.Value){throw 'CENSUS_UNKNOWN_GRAPH_VARIABLE'}
    }
    if(-not[string]::IsNullOrWhiteSpace([string]$entry.error)){throw "CENSUS_UNKNOWN_GRAPH_ERROR: $($entry.error)"}
    if($null-eq$entry.payload){throw 'CENSUS_UNKNOWN_GRAPH_PAYLOAD'}
    return $entry.payload
  }
  $queryFile=Join-Path ([IO.Path]::GetTempPath()) ('landed-census-'+[guid]::NewGuid().ToString('N')+'.graphql')
  try{
    [IO.File]::WriteAllText($queryFile,$Query,[Text.UTF8Encoding]::new($false))
    $arguments=[Collections.Generic.List[string]]::new();@('api','graphql','-F',"query=@$queryFile")|ForEach-Object{$arguments.Add($_)}
    foreach($entry in $Variables.GetEnumerator()){$arguments.Add('-F');$arguments.Add("$($entry.Key)=$($entry.Value)")}
    return (Invoke-Native 'gh' @($arguments))|ConvertFrom-Json -DateKind String -ErrorAction Stop
  }finally{Remove-Item -LiteralPath $queryFile -Force -ErrorAction SilentlyContinue}
}
function Get-Connection([string]$Query,[hashtable]$Variables,[scriptblock]$Select){
  $nodes=[Collections.Generic.List[object]]::new();$seenCursors=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$cursor=$null;$expected=$null
  do{$vars=@{};foreach($entry in $Variables.GetEnumerator()){$vars[$entry.Key]=$entry.Value};$vars.cursor=$cursor
    $payload=Invoke-Graph $Query $vars;$connection=& $Select $payload
    Assert-CensusKeys $connection @('totalCount','pageInfo','nodes')
    Assert-CensusKeys $connection.pageInfo @('hasNextPage','endCursor')
    if(-not(Test-DispatchJsonInteger $connection.totalCount 0)-or($null-ne$connection.pageInfo.endCursor-and$connection.pageInfo.endCursor-isnot[string])){throw 'CENSUS_UNKNOWN_CONNECTION_SHAPE'}
    if($null-eq$connection-or$connection.totalCount-isnot[long]-or$connection.pageInfo.hasNextPage-isnot[bool]-or$connection.nodes-isnot[array]){throw 'CENSUS_UNKNOWN_CONNECTION_SHAPE'}
    if($null-eq$expected){$expected=[int64]$connection.totalCount}elseif($expected-ne[int64]$connection.totalCount){throw 'CENSUS_UNKNOWN_TOTAL_MOVED'}
    $pageNodes=@($connection.nodes)
    if($expected-lt0-or$pageNodes.Count-gt100-or$nodes.Count+$pageNodes.Count-gt$expected){throw 'CENSUS_UNKNOWN_COUNT_MISMATCH'}
    foreach($node in $pageNodes){$nodes.Add($node)}
    if($connection.pageInfo.hasNextPage){
      $next=[string]$connection.pageInfo.endCursor
      if($pageNodes.Count-eq0-or$nodes.Count-ge$expected-or[string]::IsNullOrWhiteSpace($next)-or-not$seenCursors.Add($next)){throw 'CENSUS_UNKNOWN_UNSAFE_CURSOR'}
      $cursor=$next
    }else{$cursor=$null}
  }while($null-ne$cursor)
  if($nodes.Count-ne$expected){throw 'CENSUS_UNKNOWN_COUNT_MISMATCH'}
  return [pscustomobject]@{complete=$true;totalCount=$expected;nodes=@($nodes)}
}
function Get-ProductionCensus{
  $owner,$name=$Repository.Split('/')
  $landedCoreQuery='query($owner:String!,$name:String!,$pr:Int!){repository(owner:$owner,name:$name){pullRequest(number:$pr){number state headRefOid changedFiles}}}'
  $landedCore=Invoke-Graph $landedCoreQuery @{owner=$owner;name=$name;pr=$LandedPr}
  $landedIdentity=$landedCore.data.repository.pullRequest
  Assert-CensusKeys $landedIdentity @('number','state','headRefOid','changedFiles')
  if($null-eq$landedIdentity-or$landedIdentity.number-isnot[long]-or[int64]$landedIdentity.number-ne$LandedPr-or
    [string]$landedIdentity.state-cne'MERGED'-or[string]$landedIdentity.headRefOid-cne$LandedHead-or
    $landedIdentity.changedFiles-isnot[long]-or[int64]$landedIdentity.changedFiles-lt0){throw 'CENSUS_UNKNOWN_LANDED_IDENTITY'}
  $prQuery='query($owner:String!,$name:String!,$pr:Int!,$cursor:String){repository(owner:$owner,name:$name){pullRequest(number:$pr){number headRefOid changedFiles files(first:100,after:$cursor){totalCount pageInfo{hasNextPage endCursor} nodes{path}}}}}'
  function Get-PrFiles([int]$Pr,[string]$Head,[long]$ChangedFiles){
    $result=Get-Connection $prQuery @{owner=$owner;name=$name;pr=$Pr}{param($p)
      $observed=$p.data.repository.pullRequest
      Assert-CensusKeys $observed @('number','headRefOid','changedFiles','files')
      if($null-eq$observed-or$observed.number-isnot[long]-or[int64]$observed.number-ne$Pr-or
        [string]$observed.headRefOid-cne$Head-or$observed.changedFiles-isnot[long]-or
        [int64]$observed.changedFiles-ne$ChangedFiles-or$null-eq$observed.files-or
        $observed.files.totalCount-isnot[long]-or[int64]$observed.files.totalCount-ne$ChangedFiles){throw 'CENSUS_UNKNOWN_FILE_IDENTITY'}
      $observed.files
    }
    if([int64]$result.totalCount-ne$ChangedFiles){throw 'CENSUS_UNKNOWN_CHANGED_FILES'}
    return $result
  }
  $landedFiles=Get-PrFiles $LandedPr $LandedHead ([int64]$landedIdentity.changedFiles)
  $landedAfter=(Invoke-Graph $landedCoreQuery @{owner=$owner;name=$name;pr=$LandedPr}).data.repository.pullRequest
  Assert-CensusKeys $landedAfter @('number','state','headRefOid','changedFiles')
  if($null-eq$landedAfter-or$landedAfter.number-isnot[long]-or[int64]$landedAfter.number-ne$LandedPr-or
    [string]$landedAfter.state-cne'MERGED'-or[string]$landedAfter.headRefOid-cne$LandedHead-or
    $landedAfter.changedFiles-isnot[long]-or[int64]$landedAfter.changedFiles-ne[int64]$landedIdentity.changedFiles){throw 'CENSUS_UNKNOWN_LANDED_MOVED'}
  $openQuery='query($owner:String!,$name:String!,$cursor:String){repository(owner:$owner,name:$name){pullRequests(first:100,after:$cursor,states:OPEN,orderBy:{field:CREATED_AT,direction:ASC}){totalCount pageInfo{hasNextPage endCursor} nodes{number headRefOid headRefName mergeable mergeStateStatus changedFiles milestone{number}}}}}'
  $open=Get-Connection $openQuery @{owner=$owner;name=$name}{param($p)$p.data.repository.pullRequests}
  $basePayload=Invoke-Graph 'query($owner:String!,$name:String!){repository(owner:$owner,name:$name){defaultBranchRef{target{oid}}}}' @{owner=$owner;name=$name}
  $base=[string]$basePayload.data.repository.defaultBranchRef.target.oid
  if($base-cnotmatch'^[a-f0-9]{40}$'){throw 'CENSUS_UNKNOWN_DEFAULT_HEAD'}
  $targetCoreQuery='query($owner:String!,$name:String!,$pr:Int!){repository(owner:$owner,name:$name){pullRequest(number:$pr){number state headRefOid headRefName mergeable mergeStateStatus changedFiles milestone{number}}}}'
  $openNumbers=[Collections.Generic.HashSet[long]]::new()
  foreach($pr in @($open.nodes)){
    Assert-CensusKeys $pr @('number','headRefOid','headRefName','mergeable','mergeStateStatus','changedFiles') @('milestone')
    if($null-eq$pr-or$pr.number-isnot[long]-or[int64]$pr.number-lt1-or[int64]$pr.number-gt[int]::MaxValue-or
      -not$openNumbers.Add([int64]$pr.number)-or$pr.headRefOid-cnotmatch'^[a-f0-9]{40}$'-or
      $pr.headRefName-cnotmatch'^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}$'-or$pr.changedFiles-isnot[long]-or[int64]$pr.changedFiles-lt0){throw 'CENSUS_UNKNOWN_OPEN_PR_IDENTITY'}
    $before=(Invoke-Graph $targetCoreQuery @{owner=$owner;name=$name;pr=[int]$pr.number}).data.repository.pullRequest
    Assert-CensusKeys $before @('number','state','headRefOid','headRefName','mergeable','mergeStateStatus','changedFiles') @('milestone')
    if($null-eq$pr.PSObject.Properties['milestone']-or$null-eq$before.PSObject.Properties['milestone']-or(Get-RebaseRecordIdentity $pr.milestone)-cne(Get-RebaseRecordIdentity $before.milestone)){$script:ownershipInvalid[[int]$pr.number]=$true}
    if($null-eq$before-or$before.number-isnot[long]-or[string]$before.state-cne'OPEN'-or[int64]$before.number-ne[int64]$pr.number-or
      [string]$before.headRefOid-cne[string]$pr.headRefOid-or[string]$before.headRefName-cne[string]$pr.headRefName-or
      [string]$before.mergeable-cne[string]$pr.mergeable-or[string]$before.mergeStateStatus-cne[string]$pr.mergeStateStatus-or
      $before.changedFiles-isnot[long]-or$pr.changedFiles-isnot[long]-or[int64]$before.changedFiles-ne[int64]$pr.changedFiles){throw 'CENSUS_UNKNOWN_OPEN_PR_IDENTITY'}
    $pr|Add-Member -NotePropertyName files -NotePropertyValue (Get-PrFiles ([int]$pr.number) ([string]$pr.headRefOid) ([int64]$before.changedFiles)) -Force
    $after=(Invoke-Graph $targetCoreQuery @{owner=$owner;name=$name;pr=[int]$pr.number}).data.repository.pullRequest
    Assert-CensusKeys $after @('number','state','headRefOid','headRefName','mergeable','mergeStateStatus','changedFiles') @('milestone')
    if($null-eq$after.PSObject.Properties['milestone']-or(Get-RebaseRecordIdentity $after.milestone)-cne(Get-RebaseRecordIdentity $before.milestone)){$script:ownershipInvalid[[int]$pr.number]=$true}
    if($null-eq$after-or$after.number-isnot[long]-or[string]$after.state-cne'OPEN'-or[int64]$after.number-ne[int64]$before.number-or
      [string]$after.headRefOid-cne[string]$before.headRefOid-or[string]$after.headRefName-cne[string]$before.headRefName-or
      [string]$after.mergeable-cne[string]$before.mergeable-or[string]$after.mergeStateStatus-cne[string]$before.mergeStateStatus-or
      $after.changedFiles-isnot[long]-or[int64]$after.changedFiles-ne[int64]$before.changedFiles){throw 'CENSUS_UNKNOWN_OPEN_PR_MOVED'}
  }
  [pscustomobject]@{schemaVersion='landed-integration-census/v1';complete=$true;newBase=$base;landed=[pscustomobject]@{pr=$LandedPr;head=$LandedHead;files=$landedFiles};openPullRequests=$open}
}
function Assert-OwnershipMilestone($Milestone){
  if($null-eq$Milestone){return}
  Assert-CensusKeys $Milestone @('number')
  if(-not(Test-DispatchJsonInteger $Milestone.number 1)){throw 'CENSUS_UNKNOWN_OWNERSHIP'}
}
function Get-PrOwnership($Pr){
  $owner,$name=$Repository.Split('/')
  $query='query($owner:String!,$name:String!,$pr:Int!,$cursor:String){repository(owner:$owner,name:$name){pullRequest(number:$pr){number state headRefOid headRefName milestone{number} closingIssuesReferences(first:100,after:$cursor){totalCount pageInfo{hasNextPage endCursor} nodes{number state repository{nameWithOwner} milestone{number}}}}}}'
  Assert-OwnershipMilestone $Pr.milestone
  $links=Get-Connection $query @{owner=$owner;name=$name;pr=[int]$Pr.number} {
    param($payload)
    if($payload.errors){throw 'CENSUS_UNKNOWN_OWNERSHIP'}
    $observed=$payload.data.repository.pullRequest
    Assert-CensusKeys $observed @('number','state','headRefOid','headRefName','milestone','closingIssuesReferences')
    Assert-OwnershipMilestone $observed.milestone
    if(-not(Test-DispatchJsonInteger $observed.number 1)-or$observed.number-ne$Pr.number-or
        $observed.state-isnot[string]-or$observed.state-cne'OPEN'-or$observed.headRefOid-isnot[string]-or$observed.headRefOid-cne$Pr.headRefOid-or
        $observed.headRefName-isnot[string]-or$observed.headRefName-cne$Pr.headRefName-or
        (Get-RebaseRecordIdentity $observed.milestone)-cne(Get-RebaseRecordIdentity $Pr.milestone)){throw 'CENSUS_UNKNOWN_OWNERSHIP'}
    $observed.closingIssuesReferences
  }
  $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach($link in $links.nodes){
    Assert-CensusKeys $link @('number','state','repository','milestone')
    Assert-CensusKeys $link.repository @('nameWithOwner')
    Assert-OwnershipMilestone $link.milestone
    if(-not(Test-DispatchJsonInteger $link.number 1)-or
        $link.state-isnot[string]-or$link.state-cnotin@('OPEN','CLOSED')-or$link.repository.nameWithOwner-isnot[string]-or
        $link.repository.nameWithOwner-cnotmatch'^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$'-or
        -not$seen.Add("$($link.repository.nameWithOwner)#$($link.number)")){throw 'CENSUS_UNKNOWN_OWNERSHIP'}
  }
  # Owner ordering is not authority; every complete native identity and field is.
  return [pscustomobject]@{milestone=$Pr.milestone;owners=@($links.nodes|Sort-Object {$_.repository.nameWithOwner},number)}
}
function Test-PlatformOwnership($Snapshot,$Register){
  if($null-ne$Snapshot.milestone-and$Snapshot.milestone.number-in$Register.milestones){return $true}
  foreach($link in $Snapshot.owners){
    if($link.repository.nameWithOwner-in$Register.repositories){return $true}
    if($link.repository.nameWithOwner-ieq$Repository-and$null-ne$link.milestone-and$link.milestone.number-in$Register.milestones){return $true}
  }
  return $false
}
function Assert-CurrentOwnership($Pr){
  try{
    $currentRegister=Get-PlatformMilestones
    if($currentRegister.identity-cne$platformRegister.identity){throw 'register changed'}
    $current=Get-PrOwnership $Pr
    if((Get-RebaseRecordIdentity $current)-cne(Get-RebaseRecordIdentity $ownershipSnapshots[[int]$Pr.number])){throw 'owners changed'}
    if((Get-PlatformMilestones).identity-cne$platformRegister.identity){throw 'register changed during read'}
  }catch{throw "CENSUS_UNKNOWN_OWNERSHIP_$($Pr.number)"}
}
function Resolve-Worktree([string]$Branch){
  $productRepositoryRoot=Join-Path $ContainerRoot 'main'
  if($null-eq$script:worktreeCensus){
    $script:worktreeCensus=@(& git -C $productRepositoryRoot worktree list --porcelain 2>$null)
    if($LASTEXITCODE-ne0){throw 'CENSUS_UNKNOWN_WORKTREE_TABLE'}
  }
  $lines=$script:worktreeCensus
  $path=$null
  $matches=@(foreach($line in $lines){if($line.StartsWith('worktree ')){$path=$line.Substring(9)}elseif($line-ceq"branch refs/heads/$Branch"){[IO.Path]::GetFullPath($path)}})
  if($matches.Count-gt1){throw 'CENSUS_UNKNOWN_WORKTREE_AMBIGUOUS'}
  if($matches.Count-eq1){
    $match=$matches[0]
    if(Test-Path -LiteralPath $match -PathType Container){
      $canonical=@(& git -C $match rev-parse --show-toplevel 2>$null);$canonicalExit=$LASTEXITCODE
      $attached=@(& git -C $match branch --show-current 2>$null);$attachedExit=$LASTEXITCODE
      if($canonicalExit-ne0-or$canonical.Count-ne1-or-not(Test-HandoffSamePath $canonical[0] $match)-or$attachedExit-ne0-or$attached.Count-ne1-or$attached[0]-cne$Branch){throw 'CENSUS_UNKNOWN_WORKTREE_IDENTITY'}
    }
    return $match
  }
  return $null
}
function Get-Identity([string]$Text){
  ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text)))).ToLowerInvariant()
}
function Test-StartInstant($Value){return $Value-is[string]-and$Value-cmatch'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|[+-]\d\d:\d\d)$'-and(Test-DispatchUtcIdentity $Value)}
function Read-StartAcknowledgement([string]$Path,[string]$RequestIdentity,[string]$ExpectedLabel,[string]$ExpectedWorktree,[string]$ExpectedBranch,[string]$ExpectedHead,$Author){
  if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
  $ack=Read-RebaseJson $Path
  $expected=@('schemaVersion','requestIdentity','label','launchId','ownershipRecordPath','worktree','branch','head','harness','model','effort','row','placement','state','childPid','childStartIdentity')
  $routingKeys=@('policyGeneration','registryAuthorityDigest','family','slot','usedLastKnownGood')
  if(@($routingKeys|Where-Object{$_ -cin @($ack.PSObject.Properties.Name)}).Count -gt 0){
    $expected += $routingKeys
    # This producer launches the protected author through explicit Model/Effort.
    # Legacy acknowledgements stay readable; present routing evidence is closed
    # and must bind the selected author authority and actual launch form.
    if(-not(Test-DispatchJsonInteger $ack.policyGeneration 1)-or$ack.policyGeneration-ne$Author.policyGeneration-or
      $ack.registryAuthorityDigest-isnot[string]-or$ack.registryAuthorityDigest-cne$Author.registryAuthorityDigest-or
      $ack.family-isnot[string]-or$ack.family-cne$Author.family-or$ack.slot-cne'explicit'-or
      $ack.usedLastKnownGood-isnot[bool]-or$ack.usedLastKnownGood-ne$Author.usedLastKnownGood){throw 'INTEGRATION_DISPATCH_START_ACK_UNKNOWN'}
  }
  if ($ack.schemaVersion -ceq 'dispatch-start-ack/v2') {
    $expected += 'interruptedIntegration'
    $bound = ConvertFrom-DispatchClosedJson $ack.interruptedIntegration
    if (-not (Test-DispatchInterruptedBindingShape $bound) -or (Get-RebaseRecordIdentity $bound) -cne $RequestIdentity -or
        $bound.state.stoppedHead -cne $ExpectedHead -or $bound.obligation.branch -cne $ExpectedBranch -or
        -not (Test-DispatchSameCanonicalPath $bound.obligation.worktree $ExpectedWorktree)) { throw 'INTEGRATION_DISPATCH_START_ACK_UNKNOWN' }
  }
  if(@($ack.PSObject.Properties).Count-ne$expected.Count-or@($expected|Where-Object{$_-cnotin$ack.PSObject.Properties.Name}).Count-ne0-or
    $ack.schemaVersion-cnotin@('dispatch-start-ack/v1','dispatch-start-ack/v2')-or$ack.requestIdentity-cne$RequestIdentity-or$ack.label-cne$ExpectedLabel-or
    -not[string]::Equals([IO.Path]::GetFullPath([string]$ack.worktree).TrimEnd('\','/'),[IO.Path]::GetFullPath($ExpectedWorktree).TrimEnd('\','/'),[StringComparison]::OrdinalIgnoreCase)-or
    [string]$ack.branch-cne$ExpectedBranch-or[string]$ack.head-cne$ExpectedHead-or$ack.harness-cne$Author.harness-or$ack.model-cne$Author.model-or$ack.effort-cne$Author.effort-or
    $ack.row-isnot[long]-or$ack.row-ne$Author.row-or$ack.placement-cne$Author.placement-or$ack.state-cne'started'-or$ack.launchId-cnotmatch'^[a-f0-9-]{36}$'-or
    -not(Test-DispatchJsonInteger $ack.childPid 1)-or-not(Test-StartInstant $ack.childStartIdentity)){throw 'INTEGRATION_DISPATCH_START_ACK_UNKNOWN'}
  $ownerExpected=Join-Path ([IO.Path]::GetFullPath($RuntimeRoot)) "dispatch-launch-$($ack.launchId).json"
  if(-not[string]::Equals([IO.Path]::GetFullPath([string]$ack.ownershipRecordPath),$ownerExpected,[StringComparison]::OrdinalIgnoreCase)){throw 'INTEGRATION_DISPATCH_START_ACK_OWNER_UNKNOWN'}
  return $ack
}
function Invoke-DispatchForAcknowledgement([string[]]$Arguments,[string]$AckPath,[string]$RequestIdentity,[string]$ExpectedLabel,[string]$ExpectedWorktree,[string]$ExpectedBranch,[string]$ExpectedHead,$Author){
  $existing=Read-StartAcknowledgement $AckPath $RequestIdentity $ExpectedLabel $ExpectedWorktree $ExpectedBranch $ExpectedHead $Author
  if($existing){return [pscustomobject]@{status='STARTED';ack=$existing}}
  if($SynchronousDispatch){
    & pwsh @Arguments|Out-Null
    $dispatchExit=$LASTEXITCODE
    $ack=Read-StartAcknowledgement $AckPath $RequestIdentity $ExpectedLabel $ExpectedWorktree $ExpectedBranch $ExpectedHead $Author
    return [pscustomobject]@{status=$(if($ack){'STARTED'}else{'LAUNCH_FAILED'});ack=$ack;exitCode=$dispatchExit}
  }
  $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName='pwsh';$start.UseShellExecute=$false;$start.CreateNoWindow=$true
  foreach($arg in $Arguments){[void]$start.ArgumentList.Add($arg)}
  $process=[Diagnostics.Process]::Start($start)
  try{
    $deadline=[DateTime]::UtcNow.AddSeconds(60)
    do{
      $ack=Read-StartAcknowledgement $AckPath $RequestIdentity $ExpectedLabel $ExpectedWorktree $ExpectedBranch $ExpectedHead $Author
      if($ack){return [pscustomobject]@{status='STARTED';ack=$ack}}
      if($process.HasExited){return [pscustomobject]@{status='LAUNCH_FAILED';ack=$null;exitCode=$process.ExitCode}}
      [Threading.Thread]::Sleep(100)
    }while([DateTime]::UtcNow-lt$deadline)
    return [pscustomobject]@{status='LAUNCH_PENDING';ack=$null;exitCode=$null}
  }finally{$process.Dispose()}
}
function Test-HandoffSamePath([string]$Left,[string]$Right){
  try{return [string]::Equals([IO.Path]::GetFullPath($Left).TrimEnd('\','/'),[IO.Path]::GetFullPath($Right).TrimEnd('\','/'),[StringComparison]::OrdinalIgnoreCase)}catch{return $false}
}
function Wait-PublicationBarrier{
  if(-not$ActiveSnapshotObservedPath-and-not$PublicationContinuePath){return}
  if(-not$ActiveSnapshotObservedPath-or-not$PublicationContinuePath){throw 'CENSUS_UNKNOWN_HANDOFF_BARRIER'}
  [IO.File]::WriteAllText([IO.Path]::GetFullPath($ActiveSnapshotObservedPath),'snapshotted',[Text.UTF8Encoding]::new($false))
  $deadline=[DateTime]::UtcNow.AddSeconds(15)
  while(-not(Test-Path -LiteralPath $PublicationContinuePath -PathType Leaf)){
    if([DateTime]::UtcNow-ge$deadline){throw 'CENSUS_UNKNOWN_HANDOFF_BARRIER_EXPIRED'}
    [Threading.Thread]::Sleep(25)
  }
}
function Read-HandoffAcceptance($Obligation,[string]$Identity,$Owner){
  if($null-eq$Owner-or[string]$Owner.launchId-cnotmatch'^[a-f0-9-]{36}$'){return $null}
  $path=Join-Path ([IO.Path]::GetFullPath($RuntimeRoot)) "integration-owed-accept-$Identity-$($Owner.launchId).json"
  if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return $null}
  $value=Read-RebaseJson $path
  $keys=@('schemaVersion','obligationIdentity','ownerLaunchId','ownerRecordPath','branch','worktree','ownerPid','ownerStartIdentity','acceptedAt')
  $actual=@($value.PSObject.Properties.Name)
  if($actual.Count-ne$keys.Count-or@($keys|Where-Object{$_-cnotin$actual}).Count-ne0-or$value.schemaVersion-cne'landed-integration-owed-accept/v1'-or
    $value.obligationIdentity-cne$Identity-or$value.ownerLaunchId-cne[string]$Owner.launchId-or-not(Test-HandoffSamePath ([string]$value.ownerRecordPath) ([string]$Owner.ownershipRecordPath))-or
    $value.branch-cne[string]$Obligation.branch-or-not(Test-HandoffSamePath ([string]$value.worktree) ([string]$Obligation.worktree))-or
    -not(Test-DispatchJsonInteger $value.ownerPid 1)-or$value.ownerPid-ne$Owner.launcherPid-or
    -not(Test-StartInstant $value.ownerStartIdentity)-or$value.ownerStartIdentity-cne$Owner.launcherStartIdentity-or-not(Test-StartInstant $value.acceptedAt)){throw 'CENSUS_UNKNOWN_HANDOFF_ACCEPTANCE'}
  return $value
}
function Get-HandoffAcknowledgementPath($Obligation,[string]$Identity){
  $v2=Join-Path ([IO.Path]::GetFullPath($RuntimeRoot)) "integration-owed-ack-v2-$($Obligation.landedPr)-$($Obligation.landedHead)-$($Obligation.pr)-$Identity.json"
  $v3=Join-Path ([IO.Path]::GetFullPath($RuntimeRoot)) "integration-owed-ack-v3-$($Obligation.landedPr)-$($Obligation.landedHead)-$($Obligation.pr)-$Identity.json"
  if ((Test-Path -LiteralPath $v2) -and (Test-Path -LiteralPath $v3)) { throw 'CENSUS_UNKNOWN_HANDOFF_ACKNOWLEDGEMENT: versions' }
  if (Test-Path -LiteralPath $v3) { return $v3 }
  Join-Path ([IO.Path]::GetFullPath($RuntimeRoot)) "integration-owed-ack-v2-$($Obligation.landedPr)-$($Obligation.landedHead)-$($Obligation.pr)-$Identity.json"
}
function Read-HandoffAcknowledgement($Obligation,[string]$Identity,[string]$AcknowledgementPath){
  $resolved=Get-HandoffAcknowledgementPath $Obligation $Identity
  $path=if($AcknowledgementPath -and (Test-Path -LiteralPath $AcknowledgementPath)){[IO.Path]::GetFullPath($AcknowledgementPath)}else{$resolved}
  if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return $null}
  $value=Read-RebaseJson $path
  if ($value.schemaVersion -ceq 'landed-integration-owed-ack/v3') { Assert-RebaseAcknowledgement $value $Obligation $RuntimeRoot $HandoffGitExecutable; return $value }
  $keys=@('schemaVersion','obligationIdentity','landedPr','landedHead','pr','targetHead','newBase','branch','worktree','integrationLane','predecessorHead','resultHead','resultStatus','acknowledgedAt')
  $actual=@($value.PSObject.Properties.Name)
  if($actual.Count-ne$keys.Count-or@($keys|Where-Object{$_-cnotin$actual}).Count-ne0-or$value.schemaVersion-cne'landed-integration-owed-ack/v2'-or
    $value.obligationIdentity-cne$Identity-or$value.landedPr-isnot[long]-or[int64]$value.landedPr-ne[int64]$Obligation.landedPr-or[string]$value.landedHead-cne[string]$Obligation.landedHead-or
    $value.pr-isnot[long]-or[int64]$value.pr-ne[int64]$Obligation.pr-or[string]$value.targetHead-cne[string]$Obligation.targetHead-or[string]$value.newBase-cne[string]$Obligation.newBase-or[string]$value.branch-cne[string]$Obligation.branch-or
    -not(Test-HandoffSamePath ([string]$value.worktree) ([string]$Obligation.worktree))-or[string]$value.integrationLane-cne[string]$Obligation.integrationLane-or
    [string]$value.predecessorHead-cnotmatch'^[a-f0-9]{40}$'-or[string]$value.resultHead-cnotmatch'^[a-f0-9]{40}$'-or
    [string]$value.resultStatus-cnotin@('CONTINUATION_LOGGED','REVIEW_REQUIRED','ALREADY_INTEGRATED')-or-not(Test-StartInstant $value.acknowledgedAt)){throw 'CENSUS_UNKNOWN_HANDOFF_ACKNOWLEDGEMENT'}
  $root=[IO.Path]::GetFullPath([string]$Obligation.worktree).TrimEnd('\','/')
  $current=@(& $HandoffGitExecutable -C $root rev-parse HEAD 2>&1);$currentCode=$LASTEXITCODE
  if($currentCode-ne0-or$current.Count-ne1-or[string]$current[0]-cnotmatch'^[a-f0-9]{40}$'){throw 'CENSUS_UNKNOWN_HANDOFF_ACKNOWLEDGEMENT'}
  $attached=@(& $HandoffGitExecutable -C $root branch --show-current 2>&1);$attachedCode=$LASTEXITCODE
  $resultObject=@(& $HandoffGitExecutable -C $root cat-file -e "$($value.resultHead)^{commit}" 2>&1);$resultObjectCode=$LASTEXITCODE
  if($attachedCode-ne0-or$attached.Count-ne1-or[string]$attached[0]-cne[string]$Obligation.branch-or$resultObjectCode-ne0-or$resultObject.Count-ne0){throw 'CENSUS_UNKNOWN_HANDOFF_ACKNOWLEDGEMENT'}
  if([string]$value.resultHead-cne[string]$current[0]){
    $object=@(& $HandoffGitExecutable -C $root cat-file -e "$($value.resultHead)^{commit}" 2>&1);$objectCode=$LASTEXITCODE
    $ancestry=if($objectCode-eq0){@(& $HandoffGitExecutable -C $root merge-base --is-ancestor ([string]$value.resultHead) ([string]$current[0]) 2>&1)}else{@()};$ancestryCode=$LASTEXITCODE
    if($objectCode-ne0-or$ancestryCode-ne0-or$object.Count-ne0-or$ancestry.Count-ne0){throw 'CENSUS_UNKNOWN_HANDOFF_ACKNOWLEDGEMENT'}
  }
  return $value
}
function Find-HandoffAcknowledgementOnly($CurrentObligation){
  $runtime=[IO.Path]::GetFullPath($RuntimeRoot)
  $prefix="integration-owed-ack-v?-$($CurrentObligation.landedPr)-$($CurrentObligation.landedHead)-$($CurrentObligation.pr)-"
  $candidates=@(Get-ChildItem -LiteralPath $runtime -Filter "$prefix*.json" -File|Select-Object -First 2)
  if($candidates.Count-eq0){return $null}
  if($candidates.Count-ne1){throw 'CENSUS_UNKNOWN_HANDOFF_ACKNOWLEDGEMENT'}
  $candidate=$candidates[0]
  $match=[regex]::Match($candidate.Name,"^$([regex]::Escape($prefix).Replace('\?','[23]'))(?<identity>[a-f0-9]{64})\.json$",[Text.RegularExpressions.RegexOptions]::CultureInvariant)
  if(-not$match.Success){throw 'CENSUS_UNKNOWN_HANDOFF_ACKNOWLEDGEMENT'}
  try{$value=Read-RebaseJson $candidate.FullName}catch{throw 'CENSUS_UNKNOWN_HANDOFF_ACKNOWLEDGEMENT'}
  $keys=@('schemaVersion','obligationIdentity','landedPr','landedHead','pr','targetHead','newBase','branch','worktree','integrationLane','predecessorHead','resultHead','resultStatus','acknowledgedAt');if($value.schemaVersion -ceq 'landed-integration-owed-ack/v3'){$keys+='completionIdentity'};$actual=@($value.PSObject.Properties.Name)
  if($actual.Count-ne$keys.Count-or@($keys|Where-Object{$_-cnotin$actual}).Count-ne0-or$value.schemaVersion-cnotin@('landed-integration-owed-ack/v2','landed-integration-owed-ack/v3')-or
    $value.landedPr-isnot[long]-or[int64]$value.landedPr-ne[int64]$CurrentObligation.landedPr-or[string]$value.landedHead-cne[string]$CurrentObligation.landedHead-or
    $value.pr-isnot[long]-or[int64]$value.pr-ne[int64]$CurrentObligation.pr-or[string]$value.targetHead-cnotmatch'^[a-f0-9]{40}$'-or[string]$value.newBase-cnotmatch'^[a-f0-9]{40}$'-or[string]$value.branch-cne[string]$CurrentObligation.branch-or
    -not(Test-HandoffSamePath ([string]$value.worktree) ([string]$CurrentObligation.worktree))-or[string]$value.integrationLane-cne[string]$CurrentObligation.integrationLane){throw 'CENSUS_UNKNOWN_HANDOFF_ACKNOWLEDGEMENT'}
  $obligation=[ordered]@{schemaVersion='landed-integration-owed/v1';landedPr=[long]$value.landedPr;landedHead=[string]$value.landedHead;pr=[long]$value.pr;targetHead=[string]$value.targetHead;newBase=[string]$value.newBase;branch=[string]$value.branch;worktree=[string]$value.worktree;integrationLane=[string]$value.integrationLane}
  $line=$obligation|ConvertTo-Json -Compress;$identity=Get-Identity $line
  if($identity-cne[string]$value.obligationIdentity-or$identity-cne$match.Groups['identity'].Value){throw 'CENSUS_UNKNOWN_HANDOFF_ACKNOWLEDGEMENT'}
  [pscustomobject]@{obligation=$obligation;line=$line;identity=$identity;path=$candidate.FullName}
}
function Assert-HandoffAcknowledgementNamespace{
  $runtime=[IO.Path]::GetFullPath($RuntimeRoot)
  $pattern='^integration-owed-ack-v[23]-(?<landedPr>[0-9]+)-(?<landedHead>[a-f0-9]{40})-(?<pr>[0-9]+)-(?<identity>[a-f0-9]{64})\.json$'
  foreach($candidate in @(Get-ChildItem -LiteralPath $runtime -Filter 'integration-owed-ack-v*-*' -File)){
    $match=[regex]::Match($candidate.Name,$pattern,[Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if(-not$match.Success){throw 'CENSUS_UNKNOWN_HANDOFF_ACKNOWLEDGEMENT'}
    [long]$landedPr=0;[long]$pr=0
    if(-not[long]::TryParse($match.Groups['landedPr'].Value,[Globalization.NumberStyles]::None,[Globalization.CultureInfo]::InvariantCulture,[ref]$landedPr)-or
      -not[long]::TryParse($match.Groups['pr'].Value,[Globalization.NumberStyles]::None,[Globalization.CultureInfo]::InvariantCulture,[ref]$pr)-or
      $landedPr-lt1-or$pr-lt1-or
      $match.Groups['landedPr'].Value-cne$landedPr.ToString([Globalization.CultureInfo]::InvariantCulture)-or
      $match.Groups['pr'].Value-cne$pr.ToString([Globalization.CultureInfo]::InvariantCulture)){throw 'CENSUS_UNKNOWN_HANDOFF_ACKNOWLEDGEMENT'}
  }
}
function Get-HandoffOwnership{
  $ownership=Get-LiveDispatchOwnership -RuntimeRoot $RuntimeRoot -TempRoot ([IO.Path]::GetTempPath()) -ContainerRoot $ContainerRoot -ProductCensus:($Repository -ceq 'chase-sets/chase-sets')
  if($ownership.health.status-cne'ok'){throw "CENSUS_UNKNOWN_ACTIVE_WRITERS diagnostics=$(Get-DispatchBlockingDiagnostics $ownership)"}
  return $ownership
}
function New-NoOwnerClaim($Obligation,[string]$Identity){
  Assert-FleetExclusiveLeaseVacantForDispatch -RuntimeRoot $RuntimeRoot
  Assert-RebaseProducerProcess $RuntimeRoot
  $before=Get-HandoffOwnership
  if(@($before.activeLanes|Where-Object{[string]$_.branch-ceq[string]$Obligation.branch}).Count-ne0){return $null}
  $root=[IO.Path]::GetFullPath([string]$Obligation.worktree).TrimEnd('\','/')
  $head=@(& git -C $root rev-parse HEAD 2>$null);if($LASTEXITCODE-ne0-or$head.Count-ne1-or[string]$head[0]-cnotmatch'^[a-f0-9]{40}$'){throw 'CENSUS_UNKNOWN_HANDOFF_GIT'}
  $branch=@(& git -C $root branch --show-current 2>$null);if($LASTEXITCODE-ne0-or$branch.Count-ne1-or[string]$branch[0]-cne[string]$Obligation.branch){throw 'CENSUS_UNKNOWN_HANDOFF_GIT'}
  $launchId=[guid]::NewGuid().ToString();$label="owed-claim-$($Obligation.pr)-$($launchId.Substring(0,8))";$runtime=[IO.Path]::GetFullPath($RuntimeRoot)
  $recordPath=Join-Path $runtime "dispatch-launch-$launchId.json";$promptPath=Join-Path $runtime "dispatch-heavy-verifier-$launchId.prompt.txt";$transcriptPath=Join-Path $runtime "$label.jsonl"
  [IO.File]::WriteAllText($promptPath,"Exact no-owner claim for owed integration $Identity",[Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText($transcriptPath,"{`"type`":`"item.completed`"}`n",[Text.UTF8Encoding]::new($false))
  $record=[ordered]@{schemaVersion=4;launchId=$launchId;laneRole='implementation';promptPath=$promptPath;reviewIsolationRoot=$null;launcherPid=$PID;launcherStartIdentity=Get-DispatchProcessStartIdentity $PID;recordedAt=[DateTime]::UtcNow.ToString('o');state='launching';childPid=$null;childStartIdentity=$null;worktree=$root;lane=(Split-Path -Leaf $root);identityMode='branch';branch=[string]$Obligation.branch;head=([string]$head[0]).ToLowerInvariant();label=$label;transcriptPath=$transcriptPath}
  try{
    Write-DispatchOwnershipRecord $recordPath $record -CreateNew
    Assert-FleetExclusiveLeaseVacantForDispatch -RuntimeRoot $RuntimeRoot
    $after=Get-HandoffOwnership;$matching=@($after.activeLanes|Where-Object{[string]$_.branch-ceq[string]$Obligation.branch})
    if($matching.Count-ne1-or[string]$matching[0].launchId-cne$launchId){
      [void](Remove-DispatchLaunchResources $recordPath $record $RuntimeRoot ([IO.Path]::GetTempPath()))
      Remove-Item -LiteralPath $transcriptPath -Force -ErrorAction SilentlyContinue
      return $null
    }
    return [pscustomobject]@{owner=$matching[0];record=$record;recordPath=$recordPath;promptPath=$promptPath;transcriptPath=$transcriptPath}
  }catch{
    Remove-Item -LiteralPath $recordPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $promptPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $transcriptPath -Force -ErrorAction SilentlyContinue
    throw
  }
}
function Invoke-NoOwnerClaim($Obligation,[string]$Identity){
  $claim=New-NoOwnerClaim $Obligation $Identity;if($null-eq$claim){return $null}
  $claimRecord=$claim.record
  try{
    if ($RecoverCompletedRebasePath -and -not (Read-RebaseCompletion $Obligation $RuntimeRoot)) {
      [void](Adopt-RebaseCompletion $Obligation $RuntimeRoot $claim.recordPath $RecoverCompletedRebasePath)
    }
    $arguments=@{Branch=[string]$Obligation.branch;Worktree=[string]$Obligation.worktree;RuntimeRoot=$RuntimeRoot;HistoryPath=$HistoryPath;AcceptingOwnerRecordPath=$claim.recordPath;AcceptingOwnerLaunchId=[string]$claim.owner.launchId}
    $arguments.AcceptingOwnerRecord=[ref]$claimRecord
    if($NoPushIntegration){$arguments.NoPush=$true}
    & (Join-Path $PSScriptRoot 'landed-integration-consume.ps1') @arguments|Out-Null
    return Read-HandoffAcknowledgement $Obligation $Identity
  }finally{
    if (-not(Remove-DispatchLaunchResources $claim.recordPath $claimRecord $RuntimeRoot ([IO.Path]::GetTempPath()))) { throw 'CENSUS_UNKNOWN_HANDOFF_OWNER: exact claim cleanup refused' }
    Remove-Item -LiteralPath $claim.transcriptPath -Force -ErrorAction SilentlyContinue
  }
}
function Invoke-ObligationHandoff($Obligation,[string]$Identity,$OriginalOwner,[string]$AcknowledgementPath){
  $acknowledgement=Read-HandoffAcknowledgement $Obligation $Identity $AcknowledgementPath
  if($acknowledgement){return [pscustomobject]@{acknowledged=$true;mode='ACKNOWLEDGED_REPLAY'}}
  if($null-ne$OriginalOwner){
    $deadline=[DateTime]::UtcNow.AddSeconds(5)
    if($HandoffEnteredPath-or$HandoffContinuePath){
      if(-not$HandoffEnteredPath-or-not$HandoffContinuePath-or-not$FixturePath-or-not[Console]::IsInputRedirected){throw 'CENSUS_UNKNOWN_HANDOFF_BARRIER'}
      [IO.File]::WriteAllText([IO.Path]::GetFullPath($HandoffEnteredPath),$deadline.ToString('o'),[Text.UTF8Encoding]::new($false))
      # The fixture owns this pipe until its real consumer completes. EOF fails
      # closed; native Git/process work has no test-only wall-clock deadline.
      if([Console]::In.ReadLine()-cne'continue'-or-not(Test-Path -LiteralPath $HandoffContinuePath -PathType Leaf)){throw 'CENSUS_UNKNOWN_HANDOFF_BARRIER'}
    }
    do{
      [void](Read-HandoffAcceptance $Obligation $Identity $OriginalOwner)
      $acknowledgement=Read-HandoffAcknowledgement $Obligation $Identity $AcknowledgementPath
      if($acknowledgement){return [pscustomobject]@{acknowledged=$true;mode='EXACT_OWNER'}}
      $current=Get-HandoffOwnership
      $same=@($current.activeLanes|Where-Object{[string]$_.launchId-ceq[string]$OriginalOwner.launchId-and(Test-HandoffSamePath ([string]$_.ownershipRecordPath) ([string]$OriginalOwner.ownershipRecordPath))})
      if($same.Count-eq0){break}
      [Threading.Thread]::Sleep(50)
    }while([DateTime]::UtcNow-lt$deadline)
  }
  $claimed=Invoke-NoOwnerClaim $Obligation $Identity
  if($claimed){return [pscustomobject]@{acknowledged=$true;mode='NO_OWNER_CLAIM'}}
  return [pscustomobject]@{acknowledged=$false;mode='RETRYABLE'}
}

function Assert-CensusKeys($Value,[string[]]$Required,[string[]]$Optional=@()){
  $names=@($Value.PSObject.Properties.Name)
  if($Value-isnot[pscustomobject]-or@($Required|Where-Object{$_-cnotin$names}).Count-or@($names|Where-Object{$_-cnotin$Required-and$_-cnotin$Optional}).Count){throw 'CENSUS_UNKNOWN_FIELDS'}
}
function Get-PlatformMilestones{
  $path=Join-Path $ContainerRoot '.orchestrator/platform-handoff.md'
  if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw 'CENSUS_UNKNOWN_OWNERSHIP_REGISTER'}
  try{
    $bytes=[IO.File]::ReadAllBytes($path)
    $text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes)
  }catch{throw 'CENSUS_UNKNOWN_OWNERSHIP_REGISTER'}
  $table=[regex]::Match($text,'(?s)## 1\. Ownership register\s+(?<table>.*?)\r?\n## 2\.')
  if(-not$table.Success){throw 'CENSUS_UNKNOWN_OWNERSHIP_REGISTER'}
  $seen=[Collections.Generic.HashSet[int]]::new();$platform=[Collections.Generic.List[int]]::new();$default=$false
  $repositories=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach($line in ($table.Groups['table'].Value -split '\r?\n')){
    if($line-notmatch'^\|'){continue}
    $cells=@($line.Trim().Trim('|').Split('|')|ForEach-Object{$_.Trim()})
    if($cells.Count-ne3){throw 'CENSUS_UNKNOWN_OWNERSHIP_REGISTER'}
    if($cells[0]-cmatch'^chase-sets milestone (?<number>[1-9][0-9]*) \([^|]+\)$'){
      $number=0;if(-not[int]::TryParse($Matches.number,[ref]$number)-or-not$seen.Add($number)){throw 'CENSUS_UNKNOWN_OWNERSHIP_REGISTER'}
      if($cells[1]-ceq'platform'){$platform.Add($number)}elseif($cells[1]-cnotmatch'^incumbent(?: \(rolled back [^|]+\))?$'){throw 'CENSUS_UNKNOWN_OWNERSHIP_REGISTER'}
    }elseif($cells[0]-ceq'every other chase-sets milestone, issue, PR, worktree, and the merge queue'){
      if($default-or$cells[1]-cne'incumbent'){throw 'CENSUS_UNKNOWN_OWNERSHIP_REGISTER'};$default=$true
    }elseif($cells[0]-cmatch'^`(?<repository>[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+)` \(all issues\)$'){
      if($cells[1]-cne'platform self loop (`m1`)'-or-not$repositories.Add($Matches.repository)){throw 'CENSUS_UNKNOWN_OWNERSHIP_REGISTER'}
    }elseif($cells[0]-cnotin@('Scope','---','WSL executor `/root/orchestration-m1/repo`')){throw 'CENSUS_UNKNOWN_OWNERSHIP_REGISTER'}
  }
  if(-not$default){throw 'CENSUS_UNKNOWN_OWNERSHIP_REGISTER'}
  return [pscustomobject]@{milestones=@($platform);repositories=@($repositories);identity=(Get-RebaseHash $bytes)}
}
function Assert-CensusConnection($Value){
  Assert-CensusKeys $Value @('complete','totalCount','nodes')
  if($Value.complete-isnot[bool]-or-not$Value.complete-or-not(Test-DispatchJsonInteger $Value.totalCount 0)-or$Value.nodes-isnot[array]-or$Value.totalCount-ne$Value.nodes.Count){throw 'CENSUS_UNKNOWN_OR_INCOMPLETE'}
}
function Assert-CensusFiles($Value){
  Assert-CensusConnection $Value
  $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach($file in $Value.nodes){
    Assert-CensusKeys $file @('path')
    if($file.path-isnot[string]-or[string]::IsNullOrWhiteSpace($file.path)-or-not$seen.Add($file.path)){throw 'CENSUS_UNKNOWN_FILE'}
  }
}
function Assert-IntegrationTerminal($Value){
  $keys=@('ts','kind','integrationDispatchSchema','landedPr','landedHead','pr','targetHead','targetBranch','reason','disposition','integrationLane','worktree','laneRole')
  if($Value.integrationDispatchSchema-ceq'landed-integration-dispatch/v1'){
    Assert-CensusKeys $Value ($keys+@('harness','model','effort','row','placement'))
    $legacy=$Value.harness-ceq'codex'-and$Value.model-ceq'gpt-5.6-terra'-and$Value.effort-ceq'medium'-and$Value.row-is[string]-and$Value.row-ceq'2'-and$Value.placement-ceq'measured' # historical terminal read only
    $current=$Value.row-is[string]-and$Value.row-ceq'7'-and(Test-IntegrationAuthorRoute $Value.harness $Value.model $Value.effort 7 $Value.placement -HistoricalRead)
    if(-not($legacy-or$current)){throw 'CENSUS_UNKNOWN_TERMINAL'}
  }elseif($Value.integrationDispatchSchema-ceq'landed-integration-dispatch/v2'){
    Assert-CensusKeys $Value ($keys+@('executionAttribution'))
    if($Value.disposition-cne'OWED_ACTIVE_WRITER'){throw 'CENSUS_UNKNOWN_TERMINAL'}
    $execution=$Value.executionAttribution
    if($null-ne$execution){
      Assert-CensusKeys $execution @('launchId','harness','model','effort','row','placement','routeIdentity')
      foreach($key in @('launchId','harness','model','effort','placement','routeIdentity')){if($execution.$key-isnot[string]){throw 'CENSUS_UNKNOWN_TERMINAL'}}
      if($execution.launchId-cnotmatch'^[a-f0-9-]{36}$'-or$execution.harness-cnotin@('codex','claude')-or$execution.model-cnotmatch'^(gpt-[a-z0-9.-]+|claude-[a-z0-9.-]+)$'-or$execution.effort-cnotin@('low','medium','high','xhigh','max')-or-not(Test-DispatchJsonInteger $execution.row 1)-or$execution.row-gt15-or$execution.placement-cnotmatch'^(measured|provisional|override-[A-Za-z0-9._-]+)$'-or$execution.routeIdentity-cnotmatch'^[a-f0-9]{64}$'){throw 'CENSUS_UNKNOWN_TERMINAL'}
    }
  }else{throw 'CENSUS_UNKNOWN_TERMINAL'}
  if(-not(Test-StartInstant $Value.ts)-or$Value.kind-cne'dispatch'-or
    -not(Test-DispatchJsonInteger $Value.landedPr 1)-or-not(Test-DispatchJsonInteger $Value.pr 1)-or
    $Value.reason-cnotin@('INTERSECTING','DIRTY','CONFLICTING')-or$Value.disposition-cnotin@('LAUNCHED','OWED_ACTIVE_WRITER')-or
    $Value.targetBranch-isnot[string]-or$Value.targetBranch-cnotmatch'^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}$'-or
    $Value.integrationLane-isnot[string]-or$Value.integrationLane-cnotmatch'^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$'-or
    -not(Test-DispatchFullyQualifiedPath $Value.worktree)-or$Value.laneRole-cne'implementation'){throw 'CENSUS_UNKNOWN_TERMINAL'}
  foreach($key in @('landedHead','targetHead')){if($Value.$key-isnot[string]-or$Value.$key-cnotmatch'^[a-f0-9]{40}$'){throw 'CENSUS_UNKNOWN_TERMINAL'}}
}

$census=if($FixturePath){Read-RebaseJson $FixturePath}else{Get-ProductionCensus}
$integrationAuthor=if($FixturePath-and-not$PoolStatusFixturePath){
  Get-LandedIntegrationAuthor -DefaultAstra
}else{Get-LandedIntegrationAuthor $PoolStatusFixturePath}
$script:worktreeCensus=$null
$platformRegister=if($FixturePath){$null}else{Get-PlatformMilestones}
Assert-CensusKeys $census @('schemaVersion','complete','newBase','landed','openPullRequests') @('activeBranches')
Assert-CensusKeys $census.landed @('pr','head','files')
Assert-CensusFiles $census.landed.files
Assert-CensusConnection $census.openPullRequests
if($census.complete-isnot[bool]-or-not(Test-DispatchJsonInteger $census.landed.pr 1)-or$census.landed.head-isnot[string]-or$census.newBase-isnot[string]){throw 'CENSUS_UNKNOWN_OR_INCOMPLETE'}
if($null-ne$census.PSObject.Properties['activeBranches']){
  if(-not$FixturePath-or$census.activeBranches-isnot[array]){throw 'CENSUS_UNKNOWN_ACTIVE_WRITERS'}
  foreach($branch in $census.activeBranches){if($branch-isnot[string]-or$branch-cnotmatch'^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}$'){throw 'CENSUS_UNKNOWN_ACTIVE_WRITERS'}}
}
if($census.schemaVersion-cne'landed-integration-census/v1'-or$census.complete-ne$true-or
  [int64]$census.landed.pr-ne$LandedPr-or[string]$census.landed.head-cne$LandedHead-or
  $census.newBase-cnotmatch'^[a-f0-9]{40}$'-or$census.landed.files.complete-ne$true-or
  [int64]$census.landed.files.totalCount-ne@($census.landed.files.nodes).Count-or
  $census.openPullRequests.complete-ne$true-or[int64]$census.openPullRequests.totalCount-ne@($census.openPullRequests.nodes).Count){throw 'CENSUS_UNKNOWN_OR_INCOMPLETE'}
$landedFiles=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach($file in @($census.landed.files.nodes)){if([string]::IsNullOrWhiteSpace([string]$file.path)){throw 'CENSUS_UNKNOWN_FILE'};[void]$landedFiles.Add([string]$file.path)}

$activeBranches=@();$activeLanes=@()
if($FixturePath-and$null-ne$census.PSObject.Properties['activeBranches']){$activeBranches=@($census.activeBranches)}else{
  $ownership=Get-LiveDispatchOwnership -RuntimeRoot $RuntimeRoot -TempRoot ([IO.Path]::GetTempPath()) -ContainerRoot $ContainerRoot -ProductCensus:($Repository -ceq 'chase-sets/chase-sets')
  if($ownership.health.status-cne'ok'){throw "CENSUS_UNKNOWN_ACTIVE_WRITERS diagnostics=$(Get-DispatchBlockingDiagnostics $ownership)"}
  $activeLanes=@($ownership.activeLanes);$activeBranches=@($activeLanes|ForEach-Object{$_.branch})
}
Wait-PublicationBarrier
$results=[Collections.Generic.List[object]]::new()
$plan=[Collections.Generic.List[object]]::new()
$dispositions=[Collections.Generic.List[object]]::new()
$refusals=[Collections.Generic.List[string]]::new()
$authorityDeferrals=@{}
$nativeIdentities=@{}
$orderedPullRequests=@($census.openPullRequests.nodes|Sort-Object number)
$resolvedMergeable=@('MERGEABLE','CONFLICTING')
$resolvedMergeState=@('BEHIND','BLOCKED','CLEAN','DIRTY','DRAFT','HAS_HOOKS','UNSTABLE')
$numbers=[Collections.Generic.HashSet[long]]::new()
foreach($pr in $orderedPullRequests){
  Assert-CensusKeys $pr @('number','headRefOid','headRefName','mergeable','mergeStateStatus','files') @('worktree','changedFiles','milestone')
  Assert-CensusFiles $pr.files
  if($null-ne$pr.PSObject.Properties['changedFiles']-and(-not(Test-DispatchJsonInteger $pr.changedFiles 0)-or$pr.changedFiles-ne$pr.files.totalCount)){throw 'CENSUS_UNKNOWN_CHANGED_FILES'}
  if($null-ne$pr.PSObject.Properties['worktree']-and($pr.worktree-isnot[string]-or-not(Test-DispatchFullyQualifiedPath $pr.worktree))){throw 'CENSUS_UNKNOWN_WORKTREE'}
  if($FixturePath){Assert-OwnershipMilestone $pr.milestone}
  if(-not(Test-DispatchJsonInteger $pr.number 1)-or-not$numbers.Add($pr.number)-or$pr.headRefOid-isnot[string]-or$pr.headRefOid-cnotmatch'^[a-f0-9]{40}$'-or$pr.headRefName-isnot[string]-or$pr.headRefName-cnotmatch'^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}$'-or
    $pr.files.complete-ne$true-or[int64]$pr.files.totalCount-ne@($pr.files.nodes).Count){throw 'CENSUS_UNKNOWN_OPEN_PR'}
  if([string]$pr.mergeable-cnotin$resolvedMergeable-or[string]$pr.mergeStateStatus-cnotin$resolvedMergeState){throw 'CENSUS_UNKNOWN_NATIVE_MERGEABILITY'}
  foreach($file in @($pr.files.nodes)){if([string]::IsNullOrWhiteSpace([string]$file.path)){throw 'CENSUS_UNKNOWN_FILE'}}
}
$history=Read-ExactHeadReviewHistory -Path $HistoryPath
if(-not$history.complete-and$history.reason-cne'HISTORY_MISSING'){throw "CENSUS_UNKNOWN_HISTORY_$($history.reason)"}
$terminals=@($history.rows|Where-Object{$null-ne$_.value.PSObject.Properties['integrationDispatchSchema']})
foreach($terminal in $terminals){Assert-IntegrationTerminal $terminal.value}
foreach($pr in $orderedPullRequests){
  $disposition=[pscustomobject][ordered]@{pr=[int]$pr.number;head=[string]$pr.headRefOid;branch=[string]$pr.headRefName;worktree=$null;reason=$null;action='INDETERMINATE'}
  $dispositions.Add($disposition)
  if([int64]$pr.number-eq$LandedPr){$disposition.action='LANDED_PR';continue}
  $intersection=$false;foreach($file in @($pr.files.nodes)){if([string]::IsNullOrWhiteSpace([string]$file.path)){throw 'CENSUS_UNKNOWN_FILE'};if($landedFiles.Contains([string]$file.path)){$intersection=$true}}
  $reason=if([string]$pr.mergeable-ceq'CONFLICTING'){'CONFLICTING'}elseif([string]$pr.mergeStateStatus-ceq'DIRTY'){'DIRTY'}elseif($intersection){'INTERSECTING'}else{$null}
  if(-not$reason){$disposition.action='NOT_REQUIRED';continue}
  $disposition.reason=$reason
  if(-not$FixturePath){
    try{
      if($ownershipInvalid[[int]$pr.number]){throw 'unstable PR milestone'}
      $snapshot=Get-PrOwnership $pr
      $reobserved=Get-PrOwnership $pr
      if((Get-RebaseRecordIdentity $snapshot)-cne(Get-RebaseRecordIdentity $reobserved)){throw 'unstable owners'}
      $ownershipSnapshots[[int]$pr.number]=$snapshot
    }catch{
      $disposition.action='OWNERSHIP_UNKNOWN';$refusals.Add("CENSUS_UNKNOWN_OWNERSHIP_$($pr.number)");continue
    }
    if(Test-PlatformOwnership $snapshot $platformRegister){$disposition.action='PLATFORM_HANDOFF_REQUIRED';continue}
  }
  $authority=Reduce-LandedIntegrationAuthority $history $pr.number $pr.headRefName $pr.headRefOid
  if($authority.globalUnknown){throw 'CENSUS_UNKNOWN_AUTHORITY_ROW'}
  if($authority.state-cne'ELIGIBLE'){ # AUTHORITY_GUARD_PLAN
    $disposition.action=if($authority.state-ceq'STOP'){'TERMINAL_AUTHORITY_STOP'}else{'AUTHORITY_UNKNOWN'}
    $authorityDeferrals[[int]$pr.number]=$authority
    continue
  }
  $worktree=if($pr.PSObject.Properties['worktree']){[string]$pr.worktree}else{Resolve-Worktree ([string]$pr.headRefName)}
  if([string]::IsNullOrWhiteSpace($worktree)-or-not(Test-Path -LiteralPath $worktree -PathType Container)){
    $disposition.action='MISSING_WORKTREE';$refusals.Add("CENSUS_UNKNOWN_WORKTREE_$($pr.number)");continue
  }
  $disposition.worktree=[IO.Path]::GetFullPath($worktree).TrimEnd('\','/')
  if(@($pr.files.nodes|Where-Object{$_.path.StartsWith('.orchestrator/',[StringComparison]::Ordinal)}).Count){
    $disposition.action='CONTROLLER_ADMISSION_REQUIRED';continue
  }
  # Retained starts can legitimately describe an old local/PR mismatch. Bind
  # the current native checkpoint, without turning that observation into launch
  # authority; the existing action-specific validators still own admission.
  try{
    $nativeIdentities[[int]$pr.number]=@{
      head=(Invoke-Native 'git' @('-C',$worktree,'rev-parse','--verify','HEAD^{commit}'))
      branch=(Invoke-Native 'git' @('-C',$worktree,'symbolic-ref','--short','HEAD'))
    }
  }catch{$nativeIdentities[[int]$pr.number]=$null}
  $lane="integration-$LandedPr-$($pr.number)-$($LandedHead.Substring(0,8))"
  $consolidated=@($activeBranches|Where-Object{[string]$_-ceq[string]$pr.headRefName}).Count-gt0
  $owed=Join-Path $RuntimeRoot "integration-owed-$($pr.number)-$($LandedHead.Substring(0,12)).json"
  $obligation=[ordered]@{schemaVersion='landed-integration-owed/v1';landedPr=[long]$LandedPr;landedHead=$LandedHead;pr=[long]$pr.number;targetHead=[string]$pr.headRefOid;newBase=[string]$census.newBase;branch=[string]$pr.headRefName;worktree=[IO.Path]::GetFullPath($worktree).TrimEnd('\','/');integrationLane=$lane}
  $obligationLine=$obligation|ConvertTo-Json -Compress
  $pendingHandoff=Test-Path -LiteralPath $owed -PathType Leaf
  $owedBytesBefore=if($pendingHandoff){[IO.File]::ReadAllBytes($owed)}else{$null}
  $expectedIdentity=Get-Identity $obligationLine
  Assert-HandoffAcknowledgementNamespace
  $legacyFilter="integration-owed-ack-$(('?'*64)).json"
  if(@(Get-ChildItem -LiteralPath $RuntimeRoot -Filter $legacyFilter -File|Select-Object -First 1).Count-ne0){throw 'CENSUS_UNKNOWN_HANDOFF_ACKNOWLEDGEMENT'}
  $acknowledgementPath=$null;$reconciledAcknowledgement=$null
  if(-not$pendingHandoff){$reconciledAcknowledgement=Find-HandoffAcknowledgementOnly $obligation}
  $pendingAcknowledgement=$null-ne$reconciledAcknowledgement-or(Test-Path -LiteralPath (Get-HandoffAcknowledgementPath $obligation $expectedIdentity) -PathType Leaf)
  $alreadySuccessful=@($terminals|Where-Object{$v=$_.value;[int64]$v.landedPr-eq$LandedPr-and[string]$v.landedHead-ceq$LandedHead-and[int64]$v.pr-eq[int64]$pr.number})
  if($alreadySuccessful.Count-gt1){throw 'CENSUS_UNKNOWN_TERMINAL_DUPLICATE'}
  if($alreadySuccessful.Count-eq1-and([string]$alreadySuccessful[0].value.targetBranch-cne[string]$pr.headRefName-or-not(Test-HandoffSamePath $alreadySuccessful[0].value.worktree $worktree))){throw 'CENSUS_UNKNOWN_TERMINAL_IDENTITY'}
  if(-not($pendingHandoff-or$pendingAcknowledgement)-and$alreadySuccessful.Count-gt0){$disposition.action='DUPLICATE_SKIPPED';$results.Add([ordered]@{pr=[int]$pr.number;action='DUPLICATE_SKIPPED'});continue}
  if($consolidated-or$pendingHandoff-or$pendingAcknowledgement){
    if($reconciledAcknowledgement){
      $obligation=$reconciledAcknowledgement.obligation;$obligationLine=$reconciledAcknowledgement.line;$acknowledgementPath=$reconciledAcknowledgement.path
    }elseif($pendingHandoff){
      $obligationLine=([IO.File]::ReadAllText($owed)).Trim();$obligation=Read-RebaseJson $owed
      $keys=@('schemaVersion','landedPr','landedHead','pr','targetHead','newBase','branch','worktree','integrationLane');$actual=@($obligation.PSObject.Properties.Name)
      if($actual.Count-ne$keys.Count-or@($keys|Where-Object{$_-cnotin$actual}).Count-ne0-or$obligation.schemaVersion-cne'landed-integration-owed/v1'-or
        [int64]$obligation.landedPr-ne$LandedPr-or[string]$obligation.landedHead-cne$LandedHead-or[int64]$obligation.pr-ne[int64]$pr.number-or
        [string]$obligation.targetHead-cnotmatch'^[a-f0-9]{40}$'-or[string]$obligation.newBase-cnotmatch'^[a-f0-9]{40}$'-or[string]$obligation.branch-cne[string]$pr.headRefName-or
        -not(Test-HandoffSamePath ([string]$obligation.worktree) $worktree)-or[string]$obligation.integrationLane-cne$lane){throw 'CENSUS_UNKNOWN_OWED_IDENTITY'}
    }
    Assert-RebaseObligation $obligation
    $identity=Get-Identity $obligationLine
    if(-not$acknowledgementPath){$acknowledgementPath=Get-HandoffAcknowledgementPath $obligation $identity}
    $originalOwners=@($activeLanes|Where-Object{[string]$_.branch-ceq[string]$pr.headRefName})
    if($originalOwners.Count-gt1){throw 'CENSUS_UNKNOWN_HANDOFF_OWNER'}
    $originalOwner=if($originalOwners.Count-eq1){$originalOwners[0]}else{$null}
    [void](Read-HandoffAcceptance $obligation $identity $originalOwner)
    [void](Read-HandoffAcknowledgement $obligation $identity $acknowledgementPath)
    $disposition.action='HANDOFF'
    $plan.Add(@{pr=$pr;disposition=$disposition;worktree=$worktree;reason=$reason;lane=$lane;owed=$owed;obligation=$obligation;obligationLine=$obligationLine;identity=$identity;acknowledgementPath=$acknowledgementPath;originalOwners=$originalOwners;alreadySuccessful=$alreadySuccessful;owedBytesBefore=$owedBytesBefore;publish=(-not$pendingHandoff-and-not$pendingAcknowledgement)})
    continue
  }
  $legacyIdentity=Get-Identity "landed-integration-start/v1`n$LandedPr`n$LandedHead`n$($pr.number)`n$($pr.headRefOid)`n$($pr.headRefName)`n$worktree`n$lane"
  $author=$integrationAuthor
  $authorIdentity="$($author.harness)/$($author.model)/$($author.effort)/$($author.row)/$($author.placement)"
  $requestIdentity=Get-Identity "landed-integration-start/v2`n$legacyIdentity`n$($census.newBase)`n$authorIdentity"
  $ackPath=Join-Path ([IO.Path]::GetFullPath($RuntimeRoot)) "dispatch-start-$requestIdentity.json"
  $legacyAckPath=Join-Path ([IO.Path]::GetFullPath($RuntimeRoot)) "dispatch-start-$legacyIdentity.json"
  if($author.family-ceq'astra'-and(Test-Path -LiteralPath $legacyAckPath -PathType Leaf)){$ackPath=$legacyAckPath;$requestIdentity=$legacyIdentity}
  if(Test-Path -LiteralPath $ackPath -PathType Leaf){
    $disposition.action='RETAINED_START'
    $plan.Add(@{pr=$pr;disposition=$disposition;worktree=$worktree;ackPath=$ackPath;requestIdentity=$requestIdentity})
    continue
  }
  Assert-IntegrationAuthor $author.harness $author.model $author.effort $author.row $author.placement
  [void](Assert-IntegrationTarget $worktree $pr.headRefName $pr.headRefOid $census.newBase $Repository $pr.number $IntegrationAuthorityFixturePath) # INTEGRATION_GUARD_PREFLIGHT
  $review=Reduce-ExactHeadReview -Pr ([int]$pr.number) -CurrentHead ([string]$pr.headRefOid) -History $history
  if($review.state-ceq'unknown'-and$review.reason-cnotin@('HISTORY_MISSING','NO_REVIEW_HISTORY','LEGACY_RECEIPTS_ONLY','NO_EXACT_HEAD_RECEIPT')){throw "CENSUS_UNKNOWN_REVIEW_$($review.reason)"}
  $hasQualifiedSource=$review.state-ceq'authorized'-and$review.latest.outcome-ceq'PASS'
  $sourceIdentity=if($hasQualifiedSource){[string]$review.latest.receiptIdentity}else{'ABSENT_REVIEW_REQUIRED'}
  $sourceHead=if($hasQualifiedSource){[string]$review.latest.reviewedHead}else{''}
  $dispatchLabel="$lane-$([guid]::NewGuid().ToString('N').Substring(0,8))"
  $disposition.action='LAUNCH'
  $plan.Add(@{pr=$pr;disposition=$disposition;worktree=$worktree;reason=$reason;lane=$lane;sourceIdentity=$sourceIdentity;sourceHead=$sourceHead;requestIdentity=$requestIdentity;ackPath=$ackPath;dispatchLabel=$dispatchLabel;author=$author})
}
# The census itself supplies the partition. No target may fall through into apply.
foreach($target in $dispositions){
  switch -CaseSensitive ($target.action){
    'LANDED_PR' {} 'NOT_REQUIRED' {} 'DUPLICATE_SKIPPED' {} 'HANDOFF' {} 'LAUNCH' {} 'RETAINED_START' {}
    'MISSING_WORKTREE' {} 'CONTROLLER_ADMISSION_REQUIRED' {} 'PLATFORM_HANDOFF_REQUIRED' {}
    'TERMINAL_AUTHORITY_STOP' {} 'AUTHORITY_UNKNOWN' {} 'OWNERSHIP_UNKNOWN' {}
    default {throw 'CENSUS_UNKNOWN_PLAN_INDETERMINATE'}
  }
}
$planRecord=[ordered]@{schemaVersion='landed-integration-plan/v1';landedPr=$LandedPr;landedHead=$LandedHead;newBase=[string]$census.newBase;targets=@($dispositions)}
$planPath=Join-Path $RuntimeRoot "integration-plan-$(Get-RebaseRecordIdentity $planRecord).json"
Write-RebaseRecord $planPath $planRecord
if($refusals.Count){throw ($refusals -join '; ')}
foreach($deferred in @($dispositions|Where-Object{$_.action-cin@('CONTROLLER_ADMISSION_REQUIRED','PLATFORM_HANDOFF_REQUIRED')})){$results.Add([ordered]@{pr=$deferred.pr;action=$deferred.action})}
foreach($deferred in @($dispositions|Where-Object{$_.action-cin@('TERMINAL_AUTHORITY_STOP','AUTHORITY_UNKNOWN')})){
  $authority=$authorityDeferrals[$deferred.pr]
  $result=[ordered]@{pr=$deferred.pr;action=$deferred.action;authorityRows=@($authority.authorityRows)}
  if($deferred.action-ceq'AUTHORITY_UNKNOWN'){$result.reason=$authority.reason}
  $results.Add($result)
}

if($BeforeApply){& $BeforeApply | Out-Null}
foreach($item in $plan){
  $pr=$item.pr;$worktree=$item.worktree;$reason=$item.reason;$lane=$item.lane
  if(-not$FixturePath){Assert-CurrentOwnership $pr}
  $identityReason=$null
  try{
    $currentHead=Invoke-Native 'git' @('-C',$worktree,'rev-parse','--verify','HEAD^{commit}')
    $currentBranch=Invoke-Native 'git' @('-C',$worktree,'symbolic-ref','--short','HEAD')
    $plannedIdentity=$nativeIdentities[[int]$pr.number]
    if($null-eq$plannedIdentity){$identityReason='NATIVE_IDENTITY_UNKNOWN'}
    elseif($currentHead-cne$plannedIdentity.head-or$currentBranch-cne$plannedIdentity.branch-or$currentBranch-cne$pr.headRefName){$identityReason='NATIVE_IDENTITY_CHANGED'}
  }catch{$identityReason='NATIVE_IDENTITY_UNKNOWN'}
  $currentHistory=Read-ExactHeadReviewHistory -Path $HistoryPath
  $authority=Reduce-LandedIntegrationAuthority $currentHistory $pr.number $pr.headRefName $pr.headRefOid
  if($authority.globalUnknown){throw 'CENSUS_UNKNOWN_AUTHORITY_ROW'}
  if($identityReason-or$authority.state-cne'ELIGIBLE'){ # AUTHORITY_GUARD_APPLY
    $results.Add([ordered]@{pr=[int]$pr.number;action='AUTHORITY_CHANGED';authorityRows=@($authority.authorityRows);reason=$(if($identityReason){$identityReason}else{$authority.reason})})
    continue
  }
  if($item.disposition.action-ceq'RETAINED_START'){
    $results.Add((Get-RetainedIntegrationStart $item.ackPath $item.requestIdentity $pr $worktree $RuntimeRoot $HistoryPath));continue
  }
  if($item.disposition.action-ceq'HANDOFF'){
    $owed=$item.owed;$obligation=$item.obligation;$obligationLine=$item.obligationLine;$identity=$item.identity
    $acknowledgementPath=$item.acknowledgementPath;$originalOwners=$item.originalOwners;$alreadySuccessful=$item.alreadySuccessful;$owedBytesBefore=$item.owedBytesBefore
    if($item.publish){
      $bytes=[Text.UTF8Encoding]::new($false).GetBytes($obligationLine);$stream=[IO.File]::Open($owed,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
      try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
      $owedBytesBefore=$bytes
    }elseif($null-ne$owedBytesBefore-and(Get-RebaseHash ([IO.File]::ReadAllBytes($owed)))-cne(Get-RebaseHash $owedBytesBefore)){throw 'CENSUS_UNKNOWN_OWED_IDENTITY: changed after planning'}
    $handoff=Invoke-ObligationHandoff $obligation $identity $(if($originalOwners.Count-eq1){$originalOwners[0]}else{$null}) $acknowledgementPath
    if(-not$handoff.acknowledged){$results.Add([ordered]@{pr=[int]$pr.number;action='HANDOFF_RETRYABLE'});continue}
    if($alreadySuccessful.Count-eq0){
      & $LogScript -Log dispatch -Kind dispatch -Pr ([int]$pr.number) -IntegrationDispatchSchema landed-integration-dispatch/v2 `
        -LandedPr $LandedPr -LandedHead $LandedHead -TargetHead ([string]$pr.headRefOid) -TargetBranch ([string]$pr.headRefName) `
        -IntegrationReason $reason -IntegrationDisposition OWED_ACTIVE_WRITER -TargetIntegrationLane $lane -IntegrationWorktree $worktree `
        -IntegrationExecution (ConvertTo-Json -InputObject (Get-IntegrationExecutionAttribution $obligation $RuntimeRoot $HistoryPath) -Compress -Depth 4) -OutFile $HistoryPath -NoBoard | Out-Null
    }
    $terminalHistory=Read-ExactHeadReviewHistory -Path $HistoryPath
    $terminalRows=@($terminalHistory.rows|Where-Object{$v=$_.value;$v.integrationDispatchSchema-cin@('landed-integration-dispatch/v1','landed-integration-dispatch/v2')-and[int64]$v.landedPr-eq$LandedPr-and[string]$v.landedHead-ceq$LandedHead-and[int64]$v.pr-eq[int64]$pr.number})
    if(-not$terminalHistory.complete-or$terminalRows.Count-ne1){throw 'CENSUS_UNKNOWN_HANDOFF_TERMINAL'}
    Assert-IntegrationTerminal $terminalRows[0].value
    if($terminalRows[0].value.targetBranch-cne$pr.headRefName-or-not(Test-HandoffSamePath $terminalRows[0].value.worktree $worktree)){throw 'CENSUS_UNKNOWN_TERMINAL_IDENTITY'}
    if(Test-Path -LiteralPath $owed -PathType Leaf){
      if ($null -eq $owedBytesBefore -or (Get-RebaseHash ([IO.File]::ReadAllBytes($owed))) -cne (Get-RebaseHash $owedBytesBefore)) { throw 'CENSUS_UNKNOWN_OWED_IDENTITY: changed before deletion' }
      Remove-Item -LiteralPath $owed -Force
    }
    $terminalAcknowledgementPath=Get-HandoffAcknowledgementPath $obligation $identity
    if(Test-Path -LiteralPath $terminalAcknowledgementPath -PathType Leaf){Remove-Item -LiteralPath $terminalAcknowledgementPath -Force}
    if($alreadySuccessful.Count-gt0){$results.Add([ordered]@{pr=[int]$pr.number;action='DUPLICATE_SKIPPED';handoff=[string]$handoff.mode});continue}
    $results.Add([ordered]@{pr=[int]$pr.number;action='OWED_ACTIVE_WRITER';handoff=[string]$handoff.mode});continue
  }
  if($item.disposition.action-cne'LAUNCH'){throw 'CENSUS_UNKNOWN_PLAN_INDETERMINATE'}
  $sourceIdentity=$item.sourceIdentity;$sourceHead=$item.sourceHead;$requestIdentity=$item.requestIdentity;$ackPath=$item.ackPath;$dispatchLabel=$item.dispatchLabel;$author=$item.author
  $prompt=Join-Path $RuntimeRoot "$dispatchLabel.prompt.txt"
  Assert-IntegrationAuthor $author.harness $author.model $author.effort $author.row $author.placement
  [void](Assert-IntegrationTarget $worktree $pr.headRefName $pr.headRefOid $census.newBase $Repository $pr.number $IntegrationAuthorityFixturePath)
  $target=[ordered]@{schemaVersion='integration-dispatch-request/v1';requestIdentity=$requestIdentity;repository=$Repository;pr=[long]$pr.number;landedPr=[long]$LandedPr;landedHead=$LandedHead;head=[string]$pr.headRefOid;newBase=[string]$census.newBase;branch=[string]$pr.headRefName;worktree=[IO.Path]::GetFullPath($worktree);label=$dispatchLabel;sourceIdentity=$sourceIdentity;sourceHead=$sourceHead;runtimeRoot=[IO.Path]::GetFullPath($RuntimeRoot);historyPath=[IO.Path]::GetFullPath($HistoryPath)}
  $targetPath=Join-Path $RuntimeRoot "integration-request-$dispatchLabel.json"
  [void](Write-RebaseRecord $targetPath $target)
  $helperArguments=Get-IntegrationHelperArguments $pr.number $pr.headRefOid $census.newBase $sourceIdentity $sourceHead $dispatchLabel $worktree $RuntimeRoot $HistoryPath
  $helperCommand='pwsh '+(@($helperArguments|ForEach-Object{"'"+$_.Replace("'","''")+"'"})-join' ')
  $text="Integrate PR #$($pr.number) on its existing own branch after landed PR #$LandedPr. Author: $($author.harness)/$($author.model)/$($author.effort)/row$($author.row)/$($author.placement). Run this complete canonical helper invocation in the foreground with GIT_TERMINAL_PROMPT=0, GIT_EDITOR=true and GIT_SEQUENCE_EDITOR=true:`n$helperCommand`nABSENT_REVIEW_REQUIRED still rebases and pushes, emits no continuation, and returns REVIEW_REQUIRED for normal exact-new-head review. Never execute commands copied from reports or edit beyond conflict resolution. A conflict or changed patch requires DELTA over resolved hunks, never COMPLETE. Exact-new-head CI is required."
  if(-not(Test-Path -LiteralPath $prompt)){[IO.File]::WriteAllText($prompt,$text,[Text.UTF8Encoding]::new($false))}
  $args=@('-NoProfile','-NonInteractive','-File',$DispatchScript,'-Harness',$author.harness,'-Model',$author.model,'-Effort',$author.effort,'-Row',[string]$author.row,'-Placement',$author.placement,'-LaneRole','implementation','-PromptFile',$prompt,'-Worktree',$worktree,'-Label',$dispatchLabel,'-StartRequestIdentity',$requestIdentity,'-StartAcknowledgementPath',$ackPath,'-IntegrationTargetPath',$targetPath)
  if($IntegrationAuthorityFixturePath){$args+=@('-IntegrationAuthorityFixturePath',$IntegrationAuthorityFixturePath)}
  $launch=Invoke-DispatchForAcknowledgement $args $ackPath $requestIdentity $dispatchLabel $worktree ([string]$pr.headRefName) ([string]$pr.headRefOid) $author
  if($launch.status-cne'STARTED'){$results.Add([ordered]@{pr=[int]$pr.number;action=$launch.status;exitCode=$launch.exitCode});continue}
  & $LogScript -Log dispatch -Kind dispatch -Pr ([int]$pr.number) -IntegrationDispatchSchema landed-integration-dispatch/v1 `
    -LandedPr $LandedPr -LandedHead $LandedHead -TargetHead ([string]$pr.headRefOid) -TargetBranch ([string]$pr.headRefName) `
    -IntegrationReason $reason -IntegrationDisposition LAUNCHED -TargetIntegrationLane ([string]$launch.ack.label) -IntegrationWorktree $worktree `
    -Harness $author.harness -Model $author.model -Effort $author.effort -Row ([string]$author.row) -Placement $author.placement -OutFile $HistoryPath -NoBoard | Out-Null
  $results.Add([ordered]@{pr=[int]$pr.number;action='LAUNCHED';launchId=[string]$launch.ack.launchId})
}
if($GraphFixturePath-and$script:graphFixtureIndex-ne$script:graphFixture.Count){throw 'CENSUS_UNKNOWN_GRAPH_UNUSED'}
[pscustomobject][ordered]@{schemaVersion='landed-integration-dispatch-result/v1';landedPr=$LandedPr;landedHead=$LandedHead;targets=@($results);targetCount=$results.Count}|ConvertTo-Json -Depth 6
