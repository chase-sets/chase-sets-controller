[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}$')][string]$Branch,
  [Parameter(Mandatory)][string]$Worktree,
  [string]$RuntimeRoot=$PSScriptRoot,
  [string]$HistoryPath=(Join-Path $PSScriptRoot 'dispatch-log.jsonl'),
  [Parameter(DontShow)][string]$IntegrationScript=(Join-Path $PSScriptRoot 'rebase-integration.ps1'),
  [Parameter(DontShow)][string]$AcceptingOwnerRecordPath,
  [Parameter(DontShow)][string]$AcceptingOwnerLaunchId,
  [Parameter(DontShow)][ref]$AcceptingOwnerRecord,
  [Parameter(DontShow)][string]$ReleaseScanObservedPath,
  [Parameter(DontShow)][string]$ReleaseScanContinuePath,
  [Parameter(DontShow)][string]$GitExecutable='git',
  [Parameter(DontShow)][switch]$NoPush
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'dispatch-ownership.ps1')
Import-Module (Join-Path $PSScriptRoot 'review-head-contract.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'landed-integration-evidence.psm1') -Force -DisableNameChecking
$root=[IO.Path]::GetFullPath($Worktree).TrimEnd('\','/')
$runtime=[IO.Path]::GetFullPath($RuntimeRoot).TrimEnd('\','/')

function Invoke-ConsumerGit([string[]]$Arguments,[switch]$AllowFailure){
  $output=@(& $GitExecutable -C $root @Arguments 2>&1);$code=$LASTEXITCODE
  if(-not$AllowFailure-and$code-ne0){throw "landed-integration-consume: git failed ($($output-join"`n"))"}
  [pscustomobject]@{exitCode=$code;stdout=($output-join"`n").Trim()}
}
function Get-ConsumerIdentity([string]$Text){
  ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text)))).ToLowerInvariant()
}
function Test-ExactKeys($Value,[string[]]$Expected){$actual=@($Value.PSObject.Properties.Name);return $actual.Count-eq$Expected.Count-and@($Expected|Where-Object{$_-cnotin$actual}).Count-eq0}
function Test-ConsumerSamePath([string]$Left,[string]$Right){
  try{return [string]::Equals([IO.Path]::GetFullPath($Left).TrimEnd('\','/'),[IO.Path]::GetFullPath($Right).TrimEnd('\','/'),[StringComparison]::OrdinalIgnoreCase)}catch{return $false}
}
function Wait-ConsumerBarrier([string]$ObservedPath,[string]$ContinuePath){
  if(-not$ObservedPath-and-not$ContinuePath){return}
  if(-not$ObservedPath-or-not$ContinuePath){throw 'OWED_INTEGRATION_RELEASE_BARRIER_INVALID'}
  [IO.File]::WriteAllText([IO.Path]::GetFullPath($ObservedPath),'scanned',[Text.UTF8Encoding]::new($false))
  $deadline=[DateTime]::UtcNow.AddSeconds(15)
  while(-not(Test-Path -LiteralPath $ContinuePath -PathType Leaf)){
    if([DateTime]::UtcNow-ge$deadline){throw 'OWED_INTEGRATION_RELEASE_BARRIER_EXPIRED'}
    [Threading.Thread]::Sleep(25)
  }
}
function Assert-Acknowledgement($Ack,$Obligation,[string]$CurrentHead){
  if ($Ack.schemaVersion -ceq 'landed-integration-owed-ack/v3') { Assert-RebaseAcknowledgement $Ack $Obligation $runtime $GitExecutable; return }
  $keys=@('schemaVersion','obligationIdentity','landedPr','landedHead','pr','targetHead','newBase','branch','worktree','integrationLane','predecessorHead','resultHead','resultStatus','acknowledgedAt')
  if(-not(Test-ExactKeys $Ack $keys)-or$Ack.schemaVersion-cne'landed-integration-owed-ack/v2'-or
    $Ack.obligationIdentity-cne(Get-ConsumerIdentity (($Obligation|ConvertTo-Json -Compress)))-or
    [int64]$Ack.landedPr-ne[int64]$Obligation.landedPr-or[string]$Ack.landedHead-cne[string]$Obligation.landedHead-or
    [int64]$Ack.pr-ne[int64]$Obligation.pr-or[string]$Ack.targetHead-cne[string]$Obligation.targetHead-or
    [string]$Ack.newBase-cne[string]$Obligation.newBase-or
    [string]$Ack.branch-cne[string]$Obligation.branch-or-not[string]::Equals([string]$Ack.worktree,[string]$Obligation.worktree,[StringComparison]::OrdinalIgnoreCase)-or
    [string]$Ack.integrationLane-cne[string]$Obligation.integrationLane-or[string]$Ack.predecessorHead-cnotmatch'^[a-f0-9]{40}$'-or
    [string]$Ack.resultHead-cnotmatch'^[a-f0-9]{40}$'-or[string]$Ack.resultStatus-cnotin@('CONTINUATION_LOGGED','REVIEW_REQUIRED','ALREADY_INTEGRATED')){throw 'OWED_INTEGRATION_ACK_UNKNOWN'}
  $object=Invoke-ConsumerGit @('cat-file','-e',"$($Ack.resultHead)^{commit}") -AllowFailure
  if($object.exitCode-ne0-or-not[string]::IsNullOrWhiteSpace([string]$object.stdout)){throw 'OWED_INTEGRATION_ACK_UNKNOWN'}
  if([string]$Ack.resultHead-ceq$CurrentHead){return}
  $ancestry=if($object.exitCode-eq0){Invoke-ConsumerGit @('merge-base','--is-ancestor',[string]$Ack.resultHead,$CurrentHead) -AllowFailure}else{$null}
  if($object.exitCode-ne0-or$null-eq$ancestry-or$ancestry.exitCode-ne0-or-not[string]::IsNullOrWhiteSpace([string]$object.stdout)-or-not[string]::IsNullOrWhiteSpace([string]$ancestry.stdout)){throw 'OWED_INTEGRATION_ACK_UNKNOWN'}
}
function Publish-OwnerAcceptance($Obligation,[string]$Identity){
  if(-not$AcceptingOwnerRecordPath-and-not$AcceptingOwnerLaunchId){return}
  if(-not$AcceptingOwnerRecordPath-or$AcceptingOwnerLaunchId-cnotmatch'^[a-f0-9-]{36}$'){throw 'OWED_INTEGRATION_ACCEPT_OWNER_UNKNOWN'}
  $owner=Get-ValidatedDispatchOwnershipRecord ([IO.Path]::GetFullPath($AcceptingOwnerRecordPath)) $runtime ([IO.Path]::GetTempPath())
  if($null-eq$owner-or$owner.schemaVersion-notin@(4,5)-or[string]$owner.launchId-cne$AcceptingOwnerLaunchId-or$owner.laneRole-cne'implementation'-or$owner.identityMode-cne'branch'-or
    [string]$owner.branch-cne[string]$Obligation.branch-or-not(Test-ConsumerSamePath ([string]$owner.worktree) $root)-or
    (Get-DispatchProcessIdentityState ([int]$owner.launcherPid) ([string]$owner.launcherStartIdentity))-cne'live'){throw 'OWED_INTEGRATION_ACCEPT_OWNER_UNKNOWN'}
  $acceptance=[ordered]@{schemaVersion='landed-integration-owed-accept/v1';obligationIdentity=$Identity;ownerLaunchId=[string]$owner.launchId;ownerRecordPath=[IO.Path]::GetFullPath($AcceptingOwnerRecordPath);branch=[string]$Obligation.branch;worktree=$root;ownerPid=[long]$owner.launcherPid;ownerStartIdentity=[string]$owner.launcherStartIdentity;acceptedAt=[datetimeoffset]::UtcNow.ToString('o')}
  $acceptPath=Join-Path $runtime "integration-owed-accept-$Identity-$($owner.launchId).json";$line=$acceptance|ConvertTo-Json -Compress
  if(Test-Path -LiteralPath $acceptPath -PathType Leaf){
    $existing=Get-Content -LiteralPath $acceptPath -Raw|ConvertFrom-Json -DateKind String -ErrorAction Stop
    $keys=@('schemaVersion','obligationIdentity','ownerLaunchId','ownerRecordPath','branch','worktree','ownerPid','ownerStartIdentity','acceptedAt')
    if(-not(Test-ExactKeys $existing $keys)-or$existing.schemaVersion-cne'landed-integration-owed-accept/v1'-or$existing.obligationIdentity-cne$Identity-or$existing.ownerLaunchId-cne[string]$owner.launchId-or
      -not(Test-ConsumerSamePath ([string]$existing.ownerRecordPath) $AcceptingOwnerRecordPath)-or$existing.branch-cne[string]$Obligation.branch-or-not(Test-ConsumerSamePath ([string]$existing.worktree) $root)-or
      [int64]$existing.ownerPid-ne[int64]$owner.launcherPid-or[string]$existing.ownerStartIdentity-cne[string]$owner.launcherStartIdentity-or-not(Test-DispatchUtcIdentity ([string]$existing.acceptedAt))){throw 'OWED_INTEGRATION_ACCEPT_UNKNOWN'}
    return
  }
  $bytes=[Text.UTF8Encoding]::new($false).GetBytes($line);$stream=[IO.File]::Open($acceptPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
  try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
}

$top=(Invoke-ConsumerGit @('rev-parse','--show-toplevel')).stdout
if(-not[string]::Equals([IO.Path]::GetFullPath($top).TrimEnd('\','/'),$root,[StringComparison]::OrdinalIgnoreCase)){throw 'landed-integration-consume: Worktree must be the canonical Git worktree root'}
$attached=(Invoke-ConsumerGit @('branch','--show-current')).stdout
if($attached-cne$Branch){throw 'landed-integration-consume: exact attached branch changed before owed integration'}
$results=[Collections.Generic.List[object]]::new()
$processed=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$obligationPaths=@(Get-ChildItem -LiteralPath $runtime -Filter 'integration-owed-*.json' -File|Where-Object{$_.Name-notlike'integration-owed-ack-*'-and$_.Name-notlike'integration-owed-accept-*'}|Sort-Object Name)
Wait-ConsumerBarrier $ReleaseScanObservedPath $ReleaseScanContinuePath
foreach($path in $obligationPaths){
  $obligation=Get-Content -LiteralPath $path.FullName -Raw|ConvertFrom-Json -DateKind String -ErrorAction Stop
  $keys=@('schemaVersion','landedPr','landedHead','pr','targetHead','newBase','branch','worktree','integrationLane')
  if(-not(Test-ExactKeys $obligation $keys)-or$obligation.schemaVersion-cne'landed-integration-owed/v1'-or
    $obligation.landedPr-isnot[long]-or$obligation.landedPr-lt1-or$obligation.pr-isnot[long]-or$obligation.pr-lt1-or
    $obligation.landedHead-cnotmatch'^[a-f0-9]{40}$'-or$obligation.targetHead-cnotmatch'^[a-f0-9]{40}$'-or$obligation.newBase-cnotmatch'^[a-f0-9]{40}$'-or
    $obligation.branch-cnotmatch'^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}$'-or$obligation.integrationLane-cnotmatch'^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$'-or
    [string]::IsNullOrWhiteSpace([string]$obligation.worktree)){throw 'OWED_INTEGRATION_UNKNOWN'}
  if([string]$obligation.branch-cne$Branch){continue}
  if(-not[string]::Equals([IO.Path]::GetFullPath([string]$obligation.worktree).TrimEnd('\','/'),$root,[StringComparison]::OrdinalIgnoreCase)){throw 'OWED_INTEGRATION_BRANCH_WORKTREE_MISMATCH'}
  $predecessor=(Invoke-ConsumerGit @('rev-parse','HEAD')).stdout.ToLowerInvariant()
  $identity=Get-ConsumerIdentity ($obligation|ConvertTo-Json -Compress)
  [void]$processed.Add($identity)
  Publish-OwnerAcceptance $obligation $identity
  $legacyAckPath=Join-Path $runtime "integration-owed-ack-$identity.json"
  if(Test-Path -LiteralPath $legacyAckPath -PathType Leaf){throw 'OWED_INTEGRATION_ACK_UNKNOWN'}
  $ackPath=Join-Path $runtime "integration-owed-ack-v2-$($obligation.landedPr)-$($obligation.landedHead)-$($obligation.pr)-$identity.json"
  $v3Path=Join-Path $runtime "integration-owed-ack-v3-$($obligation.landedPr)-$($obligation.landedHead)-$($obligation.pr)-$identity.json"
  if ((Test-Path -LiteralPath $ackPath) -and (Test-Path -LiteralPath $v3Path)) { throw 'OWED_INTEGRATION_ACK_UNKNOWN: conflicting versions' }
  if (Test-Path -LiteralPath $v3Path) { $ackPath=$v3Path }
  if(Test-Path -LiteralPath $ackPath -PathType Leaf){
    $ack=Read-RebaseJson $ackPath
    Assert-Acknowledgement $ack $obligation $predecessor
    $results.Add([ordered]@{pr=[long]$obligation.pr;status='ACKNOWLEDGED_REPLAY';head=[string]$ack.resultHead});continue
  }
  $completion=Read-RebaseCompletion $obligation $runtime $GitExecutable
  if (-not $completion -and $AcceptingOwnerRecordPath) { $completion=Complete-RebaseOwner $obligation $runtime $AcceptingOwnerRecordPath }
  if ($completion) {
    # Re-read the immutable evidence through the replay reader before producing
    # the only acknowledgement accepted for a completed conflict rebase.
    $completion=Read-RebaseCompletion $obligation $runtime $GitExecutable
    $ack=[ordered]@{schemaVersion='landed-integration-owed-ack/v3';obligationIdentity=$identity;landedPr=$obligation.landedPr;landedHead=$obligation.landedHead;pr=$obligation.pr;targetHead=$obligation.targetHead;newBase=$obligation.newBase;branch=$obligation.branch;worktree=$obligation.worktree;integrationLane=$obligation.integrationLane;predecessorHead=$completion.predecessorHead;resultHead=$completion.resultHead;resultStatus='REVIEW_REQUIRED';acknowledgedAt=[datetimeoffset]::UtcNow.ToString('o');completionIdentity=(Get-RebaseRecordIdentity $completion)}
    Assert-RebaseAcknowledgement $ack $obligation $runtime $GitExecutable
    Write-RebaseRecord $v3Path $ack
    $results.Add([ordered]@{pr=[long]$obligation.pr;status='REVIEW_REQUIRED';head=$completion.resultHead});continue
  }
  if((Invoke-ConsumerGit @('merge-base','--is-ancestor',[string]$obligation.targetHead,$predecessor) -AllowFailure).exitCode-ne0){throw 'OWED_INTEGRATION_TARGET_HEAD_NOT_ANCESTOR'}
  $review=Reduce-ExactHeadReview -Pr ([int]$obligation.pr) -CurrentHead $predecessor -History (Read-ExactHeadReviewHistory -Path $HistoryPath)
  $qualified=$review.state-ceq'authorized'-and$review.latest.outcome-ceq'PASS'
  $sourceIdentity=if($qualified){[string]$review.latest.receiptIdentity}else{'ABSENT_REVIEW_REQUIRED'}
  $arguments=@('-NoProfile','-NonInteractive','-File',$IntegrationScript,'-Pr',[string]$obligation.pr,'-ReviewedHead',$predecessor,'-NewBase',[string]$obligation.newBase,'-SourcePassReceiptIdentity',$sourceIdentity,'-IntegrationLane',[string]$obligation.integrationLane,'-Worktree',$root,'-HistoryPath',$HistoryPath)
  if ($IntegrationScript -ceq (Join-Path $PSScriptRoot 'rebase-integration.ps1')) { $arguments+=@('-RuntimeRoot',$runtime) }
  if($qualified){$arguments+=@('-SourcePassReviewedHead',[string]$review.latest.reviewedHead)}
  if($NoPush){$arguments+='-NoPush'}
  if ($AcceptingOwnerRecordPath -and $IntegrationScript -ceq (Join-Path $PSScriptRoot 'rebase-integration.ps1')) {
    $record=Get-ValidatedDispatchOwnershipRecord $AcceptingOwnerRecordPath $runtime ([IO.Path]::GetTempPath())
    if ($record.launcherPid -ne $PID -or $record.launcherStartIdentity -cne (Get-DispatchProcessStartIdentity $PID)) { throw 'OWED_REBASE_OWNER_UNAUTHORIZED: consumer launcher' }
    if ($AcceptingOwnerRecord -and -not(Test-DispatchOwnershipRecordExact $record $AcceptingOwnerRecord.Value)) { throw 'OWED_REBASE_OWNER_UNAUTHORIZED: expected owner changed' }
    $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName='pwsh';$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    foreach ($argument in $arguments) { [void]$psi.ArgumentList.Add($argument) }
    $child=[Diagnostics.Process]::Start($psi)
    try {
      $published=Get-ValidatedDispatchOwnershipRecord $AcceptingOwnerRecordPath $runtime ([IO.Path]::GetTempPath())
      if (-not(Test-DispatchOwnershipRecordExact $published $record)) { throw 'OWED_REBASE_OWNER_UNAUTHORIZED: owner changed before child publication' }
      $record.childPid=$child.Id;$record.childStartIdentity=Get-DispatchProcessStartIdentity $child.Id;$record.state='started'
      Write-DispatchOwnershipRecord $AcceptingOwnerRecordPath $record
      if ($AcceptingOwnerRecord) {
        $AcceptingOwnerRecord.Value.childPid=$record.childPid
        $AcceptingOwnerRecord.Value.childStartIdentity=$record.childStartIdentity
        $AcceptingOwnerRecord.Value.state=$record.state
      }
      $outputTask=$child.StandardOutput.ReadToEndAsync();$errorTask=$child.StandardError.ReadToEndAsync()
      $child.WaitForExit();$raw=@($outputTask.GetAwaiter().GetResult() -split "\r?\n" | Where-Object { $_ });$code=$child.ExitCode
      $errorText=$errorTask.GetAwaiter().GetResult();if ($errorText) { [Console]::Error.WriteLine($errorText) }
    } finally { if(-not $child.HasExited){$child.WaitForExit()};$child.Dispose() }
  } else { $raw=@(& pwsh @arguments);$code=$LASTEXITCODE }
  $result=$null
  foreach($line in @($raw|Select-Object -Last 1)){try{$result=$line|ConvertFrom-Json -DateKind String -ErrorAction Stop}catch{}}
  if($code-ne0-or$null-eq$result-or$result.status-cnotin@('CONTINUATION_LOGGED','REVIEW_REQUIRED','ALREADY_INTEGRATED')){throw "OWED_INTEGRATION_EXECUTION_FAILED_$code"}
  $acknowledgement=[ordered]@{schemaVersion='landed-integration-owed-ack/v2';obligationIdentity=$identity;landedPr=[long]$obligation.landedPr;landedHead=[string]$obligation.landedHead;pr=[long]$obligation.pr;targetHead=[string]$obligation.targetHead;newBase=[string]$obligation.newBase;branch=[string]$obligation.branch;worktree=[string]$obligation.worktree;integrationLane=[string]$obligation.integrationLane;predecessorHead=$predecessor;resultHead=[string]$result.newHead;resultStatus=[string]$result.status;acknowledgedAt=[datetimeoffset]::UtcNow.ToString('o')}
  $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($acknowledgement|ConvertTo-Json -Compress));$stream=[IO.File]::Open($ackPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
  try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
  $results.Add([ordered]@{pr=[long]$obligation.pr;status=[string]$result.status;head=[string]$result.newHead})
}
# A crash may leave only the acknowledgement. Validate it even without an owed
# file, so the consumer and producer agree about reset/missing-object replay.
foreach ($file in @(Get-ChildItem -LiteralPath $runtime -Filter 'integration-owed-ack-v*-*.json' -File)) {
  $ack=Read-RebaseJson $file.FullName
  if ([string]$ack.branch -cne $Branch -or $processed.Contains([string]$ack.obligationIdentity)) { continue }
  $o=[ordered]@{schemaVersion='landed-integration-owed/v1';landedPr=$ack.landedPr;landedHead=$ack.landedHead;pr=$ack.pr;targetHead=$ack.targetHead;newBase=$ack.newBase;branch=$ack.branch;worktree=$ack.worktree;integrationLane=$ack.integrationLane}
  Assert-RebaseObligation $o
  if (-not(Test-ConsumerSamePath $o.worktree $root)) { throw 'OWED_INTEGRATION_ACK_UNKNOWN: worktree' }
  $id=Get-RebaseObligationIdentity $o
  $peers=@(Get-ChildItem -LiteralPath $runtime -Filter "integration-owed-ack-v?-$($o.landedPr)-$($o.landedHead)-$($o.pr)-*.json" -File)
  if ($peers.Count -ne 1 -or $ack.obligationIdentity -cne $id) { throw 'OWED_INTEGRATION_ACK_UNKNOWN: ambiguous acknowledgement-only state' }
  Assert-Acknowledgement $ack $o (Invoke-ConsumerGit @('rev-parse','HEAD')).stdout
  [void]$processed.Add($id)
  $results.Add([ordered]@{pr=[long]$o.pr;status='ACKNOWLEDGED_REPLAY';head=$ack.resultHead})
}
[pscustomobject][ordered]@{schemaVersion='landed-integration-consume-result/v1';branch=$Branch;worktree=$root;consumed=$results.Count;results=@($results)}|ConvertTo-Json -Depth 5
