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
  [Parameter(DontShow)][string]$DispatchScript=(Join-Path $PSScriptRoot 'dispatch-lane.ps1'),
  [Parameter(DontShow)][string]$LogScript=(Join-Path $PSScriptRoot 'log-event.ps1'),
  [Parameter(DontShow)][string]$ActiveSnapshotObservedPath,
  [Parameter(DontShow)][string]$PublicationContinuePath,
  [Parameter(DontShow)][string]$HandoffEnteredPath,
  [Parameter(DontShow)][string]$HandoffContinuePath,
  [Parameter(DontShow)][string]$HandoffGitExecutable='git',
  [Parameter(DontShow)][switch]$NoPushIntegration,
  [Parameter(DontShow)][switch]$SynchronousDispatch
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'dispatch-ownership.ps1')
Import-Module (Join-Path $PSScriptRoot 'review-head-contract.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'landed-integration-evidence.psm1') -Force -DisableNameChecking

$graphFixture=$null
$graphFixtureIndex=0
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
  if($null-eq$landedIdentity-or$landedIdentity.number-isnot[long]-or[int64]$landedIdentity.number-ne$LandedPr-or
    [string]$landedIdentity.state-cne'MERGED'-or[string]$landedIdentity.headRefOid-cne$LandedHead-or
    $landedIdentity.changedFiles-isnot[long]-or[int64]$landedIdentity.changedFiles-lt0){throw 'CENSUS_UNKNOWN_LANDED_IDENTITY'}
  $prQuery='query($owner:String!,$name:String!,$pr:Int!,$cursor:String){repository(owner:$owner,name:$name){pullRequest(number:$pr){number headRefOid changedFiles files(first:100,after:$cursor){totalCount pageInfo{hasNextPage endCursor} nodes{path}}}}}'
  function Get-PrFiles([int]$Pr,[string]$Head,[long]$ChangedFiles){
    $result=Get-Connection $prQuery @{owner=$owner;name=$name;pr=$Pr}{param($p)
      $observed=$p.data.repository.pullRequest
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
  if($null-eq$landedAfter-or$landedAfter.number-isnot[long]-or[int64]$landedAfter.number-ne$LandedPr-or
    [string]$landedAfter.state-cne'MERGED'-or[string]$landedAfter.headRefOid-cne$LandedHead-or
    $landedAfter.changedFiles-isnot[long]-or[int64]$landedAfter.changedFiles-ne[int64]$landedIdentity.changedFiles){throw 'CENSUS_UNKNOWN_LANDED_MOVED'}
  $openQuery='query($owner:String!,$name:String!,$cursor:String){repository(owner:$owner,name:$name){pullRequests(first:100,after:$cursor,states:OPEN,orderBy:{field:CREATED_AT,direction:ASC}){totalCount pageInfo{hasNextPage endCursor} nodes{number headRefOid headRefName mergeable mergeStateStatus changedFiles}}}}'
  $open=Get-Connection $openQuery @{owner=$owner;name=$name}{param($p)$p.data.repository.pullRequests}
  $basePayload=Invoke-Graph 'query($owner:String!,$name:String!){repository(owner:$owner,name:$name){defaultBranchRef{target{oid}}}}' @{owner=$owner;name=$name}
  $base=[string]$basePayload.data.repository.defaultBranchRef.target.oid
  if($base-cnotmatch'^[a-f0-9]{40}$'){throw 'CENSUS_UNKNOWN_DEFAULT_HEAD'}
  $targetCoreQuery='query($owner:String!,$name:String!,$pr:Int!){repository(owner:$owner,name:$name){pullRequest(number:$pr){number state headRefOid headRefName mergeable mergeStateStatus changedFiles}}}'
  $openNumbers=[Collections.Generic.HashSet[long]]::new()
  foreach($pr in @($open.nodes)){
    if($null-eq$pr-or$pr.number-isnot[long]-or[int64]$pr.number-lt1-or[int64]$pr.number-gt[int]::MaxValue-or
      -not$openNumbers.Add([int64]$pr.number)-or$pr.headRefOid-cnotmatch'^[a-f0-9]{40}$'-or
      $pr.headRefName-cnotmatch'^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}$'-or$pr.changedFiles-isnot[long]-or[int64]$pr.changedFiles-lt0){throw 'CENSUS_UNKNOWN_OPEN_PR_IDENTITY'}
    $before=(Invoke-Graph $targetCoreQuery @{owner=$owner;name=$name;pr=[int]$pr.number}).data.repository.pullRequest
    if($null-eq$before-or$before.number-isnot[long]-or[string]$before.state-cne'OPEN'-or[int64]$before.number-ne[int64]$pr.number-or
      [string]$before.headRefOid-cne[string]$pr.headRefOid-or[string]$before.headRefName-cne[string]$pr.headRefName-or
      [string]$before.mergeable-cne[string]$pr.mergeable-or[string]$before.mergeStateStatus-cne[string]$pr.mergeStateStatus-or
      $before.changedFiles-isnot[long]-or$pr.changedFiles-isnot[long]-or[int64]$before.changedFiles-ne[int64]$pr.changedFiles){throw 'CENSUS_UNKNOWN_OPEN_PR_IDENTITY'}
    $pr|Add-Member -NotePropertyName files -NotePropertyValue (Get-PrFiles ([int]$pr.number) ([string]$pr.headRefOid) ([int64]$before.changedFiles)) -Force
    $after=(Invoke-Graph $targetCoreQuery @{owner=$owner;name=$name;pr=[int]$pr.number}).data.repository.pullRequest
    if($null-eq$after-or$after.number-isnot[long]-or[string]$after.state-cne'OPEN'-or[int64]$after.number-ne[int64]$before.number-or
      [string]$after.headRefOid-cne[string]$before.headRefOid-or[string]$after.headRefName-cne[string]$before.headRefName-or
      [string]$after.mergeable-cne[string]$before.mergeable-or[string]$after.mergeStateStatus-cne[string]$before.mergeStateStatus-or
      $after.changedFiles-isnot[long]-or[int64]$after.changedFiles-ne[int64]$before.changedFiles){throw 'CENSUS_UNKNOWN_OPEN_PR_MOVED'}
  }
  if($GraphFixturePath-and$script:graphFixtureIndex-ne$script:graphFixture.Count){throw 'CENSUS_UNKNOWN_GRAPH_UNUSED'}
  [pscustomobject]@{schemaVersion='landed-integration-census/v1';complete=$true;newBase=$base;landed=[pscustomobject]@{pr=$LandedPr;head=$LandedHead;files=$landedFiles};openPullRequests=$open}
}
function Resolve-Worktree([string]$Branch){
  $productRepositoryRoot=Join-Path $ContainerRoot 'main'
  $lines=@(& git -C $productRepositoryRoot worktree list --porcelain 2>$null);if($LASTEXITCODE-ne0){return $null}
  $path=$null
  foreach($line in $lines){if($line.StartsWith('worktree ')){$path=$line.Substring(9)}elseif($line-ceq"branch refs/heads/$Branch"){return [IO.Path]::GetFullPath($path)}}
  return $null
}
function Get-Identity([string]$Text){
  ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text)))).ToLowerInvariant()
}
function Test-StartInstant($Value){$parsed=[datetimeoffset]::MinValue;return $Value-is[string]-and[datetimeoffset]::TryParse([string]$Value,[ref]$parsed)}
function Read-StartAcknowledgement([string]$Path,[string]$RequestIdentity,[string]$ExpectedLabel,[string]$ExpectedWorktree,[string]$ExpectedBranch,[string]$ExpectedHead){
  if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
  $ack=Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json -DateKind String -ErrorAction Stop
  $expected=@('schemaVersion','requestIdentity','label','launchId','ownershipRecordPath','worktree','branch','head','harness','model','effort','row','placement','state','childPid','childStartIdentity')
  if(@($ack.PSObject.Properties).Count-ne$expected.Count-or@($expected|Where-Object{$_-cnotin$ack.PSObject.Properties.Name}).Count-ne0-or
    $ack.schemaVersion-cne'dispatch-start-ack/v1'-or$ack.requestIdentity-cne$RequestIdentity-or$ack.label-cne$ExpectedLabel-or
    -not[string]::Equals([IO.Path]::GetFullPath([string]$ack.worktree).TrimEnd('\','/'),[IO.Path]::GetFullPath($ExpectedWorktree).TrimEnd('\','/'),[StringComparison]::OrdinalIgnoreCase)-or
    [string]$ack.branch-cne$ExpectedBranch-or[string]$ack.head-cne$ExpectedHead-or$ack.harness-cne'codex'-or$ack.model-cne'gpt-5.6-terra'-or$ack.effort-cne'medium'-or
    $ack.row-isnot[long]-or$ack.row-ne2-or$ack.placement-cne'measured'-or$ack.state-cne'started'-or$ack.launchId-cnotmatch'^[a-f0-9-]{36}$'-or
    $ack.childPid-isnot[long]-or$ack.childPid-lt1-or-not(Test-StartInstant $ack.childStartIdentity)){throw 'INTEGRATION_DISPATCH_START_ACK_UNKNOWN'}
  $ownerExpected=Join-Path ([IO.Path]::GetFullPath($RuntimeRoot)) "dispatch-launch-$($ack.launchId).json"
  if(-not[string]::Equals([IO.Path]::GetFullPath([string]$ack.ownershipRecordPath),$ownerExpected,[StringComparison]::OrdinalIgnoreCase)){throw 'INTEGRATION_DISPATCH_START_ACK_OWNER_UNKNOWN'}
  return $ack
}
function Invoke-DispatchForAcknowledgement([string[]]$Arguments,[string]$AckPath,[string]$RequestIdentity,[string]$ExpectedLabel,[string]$ExpectedWorktree,[string]$ExpectedBranch,[string]$ExpectedHead){
  $existing=Read-StartAcknowledgement $AckPath $RequestIdentity $ExpectedLabel $ExpectedWorktree $ExpectedBranch $ExpectedHead
  if($existing){return [pscustomobject]@{status='STARTED';ack=$existing}}
  if($SynchronousDispatch){
    & pwsh @Arguments|Out-Null
    $dispatchExit=$LASTEXITCODE
    $ack=Read-StartAcknowledgement $AckPath $RequestIdentity $ExpectedLabel $ExpectedWorktree $ExpectedBranch $ExpectedHead
    return [pscustomobject]@{status=$(if($ack){'STARTED'}else{'LAUNCH_FAILED'});ack=$ack;exitCode=$dispatchExit}
  }
  $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName='pwsh';$start.UseShellExecute=$false;$start.CreateNoWindow=$true
  foreach($arg in $Arguments){[void]$start.ArgumentList.Add($arg)}
  $process=[Diagnostics.Process]::Start($start)
  try{
    $deadline=[DateTime]::UtcNow.AddSeconds(60)
    do{
      $ack=Read-StartAcknowledgement $AckPath $RequestIdentity $ExpectedLabel $ExpectedWorktree $ExpectedBranch $ExpectedHead
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
  $value=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json -DateKind String -ErrorAction Stop
  $keys=@('schemaVersion','obligationIdentity','ownerLaunchId','ownerRecordPath','branch','worktree','ownerPid','ownerStartIdentity','acceptedAt')
  $actual=@($value.PSObject.Properties.Name)
  if($actual.Count-ne$keys.Count-or@($keys|Where-Object{$_-cnotin$actual}).Count-ne0-or$value.schemaVersion-cne'landed-integration-owed-accept/v1'-or
    $value.obligationIdentity-cne$Identity-or$value.ownerLaunchId-cne[string]$Owner.launchId-or-not(Test-HandoffSamePath ([string]$value.ownerRecordPath) ([string]$Owner.ownershipRecordPath))-or
    $value.branch-cne[string]$Obligation.branch-or-not(Test-HandoffSamePath ([string]$value.worktree) ([string]$Obligation.worktree))-or
    [int64]$value.ownerPid-ne[int64]$Owner.launcherPid-or[string]$value.ownerStartIdentity-cne[string]$Owner.launcherStartIdentity-or-not(Test-DispatchUtcIdentity ([string]$value.acceptedAt))){throw 'CENSUS_UNKNOWN_HANDOFF_ACCEPTANCE'}
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
    [string]$value.resultStatus-cnotin@('CONTINUATION_LOGGED','REVIEW_REQUIRED','ALREADY_INTEGRATED')-or-not(Test-DispatchUtcIdentity ([string]$value.acknowledgedAt))){throw 'CENSUS_UNKNOWN_HANDOFF_ACKNOWLEDGEMENT'}
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
  try{$value=Get-Content -LiteralPath $candidate.FullName -Raw|ConvertFrom-Json -DateKind String -ErrorAction Stop}catch{throw 'CENSUS_UNKNOWN_HANDOFF_ACKNOWLEDGEMENT'}
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
  $ownership=Get-LiveDispatchOwnership -RuntimeRoot $RuntimeRoot -TempRoot ([IO.Path]::GetTempPath()) -ContainerRoot $ContainerRoot
  if($ownership.health.status-cne'ok'){throw 'CENSUS_UNKNOWN_ACTIVE_WRITERS'}
  return $ownership
}
function New-NoOwnerClaim($Obligation,[string]$Identity){
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
      if(-not$HandoffEnteredPath-or-not$HandoffContinuePath){throw 'CENSUS_UNKNOWN_HANDOFF_BARRIER'}
      [IO.File]::WriteAllText([IO.Path]::GetFullPath($HandoffEnteredPath),$deadline.ToString('o'),[Text.UTF8Encoding]::new($false))
      $barrierDeadline=[DateTime]::UtcNow.AddSeconds(15)
      while(-not(Test-Path -LiteralPath $HandoffContinuePath -PathType Leaf)){
        if([DateTime]::UtcNow-ge$barrierDeadline){throw 'CENSUS_UNKNOWN_HANDOFF_BARRIER_EXPIRED'}
        [Threading.Thread]::Sleep(25)
      }
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

$census=if($FixturePath){Get-Content -LiteralPath $FixturePath -Raw|ConvertFrom-Json -DateKind String -ErrorAction Stop}else{Get-ProductionCensus}
if($census.schemaVersion-cne'landed-integration-census/v1'-or$census.complete-ne$true-or
  [int64]$census.landed.pr-ne$LandedPr-or[string]$census.landed.head-cne$LandedHead-or
  $census.newBase-cnotmatch'^[a-f0-9]{40}$'-or$census.landed.files.complete-ne$true-or
  [int64]$census.landed.files.totalCount-ne@($census.landed.files.nodes).Count-or
  $census.openPullRequests.complete-ne$true-or[int64]$census.openPullRequests.totalCount-ne@($census.openPullRequests.nodes).Count){throw 'CENSUS_UNKNOWN_OR_INCOMPLETE'}
$landedFiles=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach($file in @($census.landed.files.nodes)){if([string]::IsNullOrWhiteSpace([string]$file.path)){throw 'CENSUS_UNKNOWN_FILE'};[void]$landedFiles.Add([string]$file.path)}

$activeBranches=@();$activeLanes=@()
if($FixturePath-and$null-ne$census.PSObject.Properties['activeBranches']){$activeBranches=@($census.activeBranches)}else{
  $ownership=Get-LiveDispatchOwnership -RuntimeRoot $RuntimeRoot -TempRoot ([IO.Path]::GetTempPath()) -ContainerRoot $ContainerRoot
  if($ownership.health.status-cne'ok'){throw 'CENSUS_UNKNOWN_ACTIVE_WRITERS'}
  $activeLanes=@($ownership.activeLanes);$activeBranches=@($activeLanes|ForEach-Object{$_.branch})
}
Wait-PublicationBarrier
$results=[Collections.Generic.List[object]]::new()
$orderedPullRequests=@($census.openPullRequests.nodes|Sort-Object number)
$resolvedMergeable=@('MERGEABLE','CONFLICTING')
$resolvedMergeState=@('BEHIND','BLOCKED','CLEAN','DIRTY','DRAFT','HAS_HOOKS','UNSTABLE')
foreach($pr in $orderedPullRequests){
  if($pr.number-isnot[long]-or[int64]$pr.number-lt1-or$pr.headRefOid-cnotmatch'^[a-f0-9]{40}$'-or$pr.headRefName-cnotmatch'^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}$'-or
    $pr.files.complete-ne$true-or[int64]$pr.files.totalCount-ne@($pr.files.nodes).Count){throw 'CENSUS_UNKNOWN_OPEN_PR'}
  if([string]$pr.mergeable-cnotin$resolvedMergeable-or[string]$pr.mergeStateStatus-cnotin$resolvedMergeState){throw 'CENSUS_UNKNOWN_NATIVE_MERGEABILITY'}
  foreach($file in @($pr.files.nodes)){if([string]::IsNullOrWhiteSpace([string]$file.path)){throw 'CENSUS_UNKNOWN_FILE'}}
}
foreach($pr in $orderedPullRequests){
  if([int64]$pr.number-eq$LandedPr){continue}
  $intersection=$false;foreach($file in @($pr.files.nodes)){if([string]::IsNullOrWhiteSpace([string]$file.path)){throw 'CENSUS_UNKNOWN_FILE'};if($landedFiles.Contains([string]$file.path)){$intersection=$true}}
  $reason=if([string]$pr.mergeable-ceq'CONFLICTING'){'CONFLICTING'}elseif([string]$pr.mergeStateStatus-ceq'DIRTY'){'DIRTY'}elseif($intersection){'INTERSECTING'}else{$null}
  if(-not$reason){continue}
  $worktree=if($pr.PSObject.Properties['worktree']){[string]$pr.worktree}else{Resolve-Worktree ([string]$pr.headRefName)}
  if([string]::IsNullOrWhiteSpace($worktree)-or-not(Test-Path -LiteralPath $worktree -PathType Container)){throw "CENSUS_UNKNOWN_WORKTREE_$($pr.number)"}
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
  $history=$null
  if(Test-Path -LiteralPath $HistoryPath -PathType Leaf){$history=Read-ExactHeadReviewHistory -Path $HistoryPath;if(-not$history.complete){throw "CENSUS_UNKNOWN_HISTORY_$($history.reason)"}}
  $alreadySuccessful=if($history){@($history.rows|Where-Object{$v=$_.value;$null-ne$v.PSObject.Properties['integrationDispatchSchema']-and[string]$v.integrationDispatchSchema-ceq'landed-integration-dispatch/v1'-and[int64]$v.landedPr-eq$LandedPr-and[string]$v.landedHead-ceq$LandedHead-and[int64]$v.pr-eq[int64]$pr.number})}else{@()}
  if(-not($consolidated-or$pendingHandoff-or$pendingAcknowledgement)-and$alreadySuccessful.Count-gt0){$results.Add([ordered]@{pr=[int]$pr.number;action='DUPLICATE_SKIPPED'});continue}
  if($consolidated-or$pendingHandoff-or$pendingAcknowledgement){
    if($reconciledAcknowledgement){
      $obligation=$reconciledAcknowledgement.obligation;$obligationLine=$reconciledAcknowledgement.line;$acknowledgementPath=$reconciledAcknowledgement.path
    }elseif($pendingHandoff){
      $obligationLine=([IO.File]::ReadAllText($owed)).Trim();$obligation=$obligationLine|ConvertFrom-Json -DateKind String -ErrorAction Stop
      $keys=@('schemaVersion','landedPr','landedHead','pr','targetHead','newBase','branch','worktree','integrationLane');$actual=@($obligation.PSObject.Properties.Name)
      if($actual.Count-ne$keys.Count-or@($keys|Where-Object{$_-cnotin$actual}).Count-ne0-or$obligation.schemaVersion-cne'landed-integration-owed/v1'-or
        [int64]$obligation.landedPr-ne$LandedPr-or[string]$obligation.landedHead-cne$LandedHead-or[int64]$obligation.pr-ne[int64]$pr.number-or
        [string]$obligation.targetHead-cnotmatch'^[a-f0-9]{40}$'-or[string]$obligation.newBase-cnotmatch'^[a-f0-9]{40}$'-or[string]$obligation.branch-cne[string]$pr.headRefName-or
        -not(Test-HandoffSamePath ([string]$obligation.worktree) $worktree)-or[string]$obligation.integrationLane-cne$lane){throw 'CENSUS_UNKNOWN_OWED_IDENTITY'}
    }elseif(-not$pendingAcknowledgement){
      $bytes=[Text.UTF8Encoding]::new($false).GetBytes($obligationLine);$stream=[IO.File]::Open($owed,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
      try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
      $owedBytesBefore=$bytes
    }
    $identity=Get-Identity $obligationLine
    if(-not$acknowledgementPath){$acknowledgementPath=Get-HandoffAcknowledgementPath $obligation $identity}
    $originalOwners=@($activeLanes|Where-Object{[string]$_.branch-ceq[string]$pr.headRefName})
    if($originalOwners.Count-gt1){throw 'CENSUS_UNKNOWN_HANDOFF_OWNER'}
    $handoff=Invoke-ObligationHandoff $obligation $identity $(if($originalOwners.Count-eq1){$originalOwners[0]}else{$null}) $acknowledgementPath
    if(-not$handoff.acknowledged){$results.Add([ordered]@{pr=[int]$pr.number;action='HANDOFF_RETRYABLE'});continue}
    if($alreadySuccessful.Count-eq0){
      & $LogScript -Log dispatch -Kind dispatch -Pr ([int]$pr.number) -IntegrationDispatchSchema landed-integration-dispatch/v1 `
        -LandedPr $LandedPr -LandedHead $LandedHead -TargetHead ([string]$pr.headRefOid) -TargetBranch ([string]$pr.headRefName) `
        -IntegrationReason $reason -IntegrationDisposition OWED_ACTIVE_WRITER -TargetIntegrationLane $lane -IntegrationWorktree $worktree `
        -Harness codex -Model gpt-5.6-terra -Effort medium -Row 2 -Placement measured -OutFile $HistoryPath -NoBoard | Out-Null
    }
    $terminalHistory=Read-ExactHeadReviewHistory -Path $HistoryPath
    $terminalRows=@($terminalHistory.rows|Where-Object{$v=$_.value;$v.integrationDispatchSchema-ceq'landed-integration-dispatch/v1'-and[int64]$v.landedPr-eq$LandedPr-and[string]$v.landedHead-ceq$LandedHead-and[int64]$v.pr-eq[int64]$pr.number})
    if(-not$terminalHistory.complete-or$terminalRows.Count-ne1){throw 'CENSUS_UNKNOWN_HANDOFF_TERMINAL'}
    if(Test-Path -LiteralPath $owed -PathType Leaf){
      if ($null -eq $owedBytesBefore -or (Get-RebaseHash ([IO.File]::ReadAllBytes($owed))) -cne (Get-RebaseHash $owedBytesBefore)) { throw 'CENSUS_UNKNOWN_OWED_IDENTITY: changed before deletion' }
      Remove-Item -LiteralPath $owed -Force
    }
    $terminalAcknowledgementPath=Get-HandoffAcknowledgementPath $obligation $identity
    if(Test-Path -LiteralPath $terminalAcknowledgementPath -PathType Leaf){Remove-Item -LiteralPath $terminalAcknowledgementPath -Force}
    if($alreadySuccessful.Count-gt0){$results.Add([ordered]@{pr=[int]$pr.number;action='DUPLICATE_SKIPPED';handoff=[string]$handoff.mode});continue}
    $results.Add([ordered]@{pr=[int]$pr.number;action='OWED_ACTIVE_WRITER';handoff=[string]$handoff.mode});continue
  }
  $review=Reduce-ExactHeadReview -Pr ([int]$pr.number) -CurrentHead ([string]$pr.headRefOid) -History (Read-ExactHeadReviewHistory -Path $HistoryPath)
  $hasQualifiedSource=$review.state-ceq'authorized'-and$review.latest.outcome-ceq'PASS'
  $sourceIdentity=if($hasQualifiedSource){[string]$review.latest.receiptIdentity}else{'ABSENT_REVIEW_REQUIRED'}
  $sourceHead=if($hasQualifiedSource){[string]$review.latest.reviewedHead}else{''}
  $requestIdentity=Get-Identity "landed-integration-start/v1`n$LandedPr`n$LandedHead`n$($pr.number)`n$($pr.headRefOid)`n$($pr.headRefName)`n$worktree`n$lane"
  $ackPath=Join-Path ([IO.Path]::GetFullPath($RuntimeRoot)) "dispatch-start-$requestIdentity.json"
  $existingAck=$null
  if(Test-Path -LiteralPath $ackPath -PathType Leaf){
    $probe=Get-Content -LiteralPath $ackPath -Raw|ConvertFrom-Json -DateKind String -ErrorAction Stop
    $dispatchLabel=[string]$probe.label
  }else{$dispatchLabel="$lane-$([guid]::NewGuid().ToString('N').Substring(0,8))"}
  $prompt=Join-Path $RuntimeRoot "$dispatchLabel.prompt.txt"
  $integrationEntrypoint=Join-Path $PSScriptRoot 'rebase-integration.ps1'
  $sourceHeadArgument=if($sourceHead){", SourcePassReviewedHead $sourceHead"}else{''}
  $text="Integrate PR #$($pr.number) on its existing own branch after landed PR #$LandedPr. Use only '$integrationEntrypoint' with ReviewedHead $($pr.headRefOid), NewBase $($census.newBase), SourcePassReceiptIdentity $sourceIdentity$sourceHeadArgument. ABSENT_REVIEW_REQUIRED still rebases and pushes, emits no continuation, and returns REVIEW_REQUIRED for the normal exact-new-head review. Never execute commands copied from reports or edit beyond conflict resolution. A conflict or changed patch requires DELTA over resolved hunks, never COMPLETE."
  [IO.File]::WriteAllText($prompt,$text,[Text.UTF8Encoding]::new($false))
  $args=@('-NoProfile','-NonInteractive','-File',$DispatchScript,'-Harness','codex','-Model','gpt-5.6-terra','-Effort','medium','-Row','2','-Placement','measured','-LaneRole','implementation','-PromptFile',$prompt,'-Worktree',$worktree,'-Label',$dispatchLabel,'-StartRequestIdentity',$requestIdentity,'-StartAcknowledgementPath',$ackPath)
  $launch=Invoke-DispatchForAcknowledgement $args $ackPath $requestIdentity $dispatchLabel $worktree ([string]$pr.headRefName) ([string]$pr.headRefOid)
  if($launch.status-cne'STARTED'){$results.Add([ordered]@{pr=[int]$pr.number;action=$launch.status;exitCode=$launch.exitCode});continue}
  & $LogScript -Log dispatch -Kind dispatch -Pr ([int]$pr.number) -IntegrationDispatchSchema landed-integration-dispatch/v1 `
    -LandedPr $LandedPr -LandedHead $LandedHead -TargetHead ([string]$pr.headRefOid) -TargetBranch ([string]$pr.headRefName) `
    -IntegrationReason $reason -IntegrationDisposition LAUNCHED -TargetIntegrationLane ([string]$launch.ack.label) -IntegrationWorktree $worktree `
    -Harness codex -Model gpt-5.6-terra -Effort medium -Row 2 -Placement measured -OutFile $HistoryPath -NoBoard | Out-Null
  $results.Add([ordered]@{pr=[int]$pr.number;action='LAUNCHED';launchId=[string]$launch.ack.launchId})
}
[pscustomobject][ordered]@{schemaVersion='landed-integration-dispatch-result/v1';landedPr=$LandedPr;landedHead=$LandedHead;targets=@($results);targetCount=$results.Count}|ConvertTo-Json -Depth 6
