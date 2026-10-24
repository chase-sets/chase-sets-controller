<#
.SYNOPSIS
Performs one own-branch integration and emits a continuation only when Git
proves the rebase was conflict-free and every reviewed commit keeps its stable
patch id. Conflict or patch change returns DELTA_REQUIRED and never fabricates
review authority.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateRange(1,[int]::MaxValue)][int]$Pr,
  [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string]$ReviewedHead,
  [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string]$NewBase,
  [Parameter(Mandatory)][ValidateScript({$_ -ceq 'ABSENT_REVIEW_REQUIRED' -or $_ -cmatch '^[a-f0-9]{64}$'})][string]$SourcePassReceiptIdentity,
  [ValidatePattern('^$|^[a-f0-9]{40}$')][string]$SourcePassReviewedHead = '',
  [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$')][string]$IntegrationLane,
  [Parameter(Mandatory)][string]$Worktree,
  [string]$HistoryPath = (Join-Path $PSScriptRoot 'dispatch-log.jsonl'),
  [string]$RuntimeRoot = $(if($env:CHASE_SETS_INTEGRATION_RUNTIME){$env:CHASE_SETS_INTEGRATION_RUNTIME}else{$PSScriptRoot}),
  [Parameter(DontShow)][switch]$NoPush
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($Worktree).TrimEnd('\','/')

function Invoke-IntegrationGit([string[]]$Arguments, [switch]$AllowFailure) {
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = 'git'
  $start.WorkingDirectory = $root
  $start.UseShellExecute = $false
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  $start.Environment['GIT_TERMINAL_PROMPT'] = '0'
  $start.Environment['GIT_EDITOR'] = 'true'
  $start.Environment['GIT_SEQUENCE_EDITOR'] = 'true'
  foreach ($argument in $Arguments) { [void]$start.ArgumentList.Add($argument) }
  $process = [Diagnostics.Process]::Start($start)
  try {
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    $result = [pscustomobject]@{ exitCode=$process.ExitCode; stdout=$stdout.Trim(); stderr=$stderr.Trim() }
    if (-not $AllowFailure -and $process.ExitCode -ne 0) {
      throw "rebase-integration: git invocation failed ($($stderr.Trim()))"
    }
    return $result
  } finally { $process.Dispose() }
}

$top = (Invoke-IntegrationGit @('rev-parse','--show-toplevel')).stdout
if (-not [string]::Equals([IO.Path]::GetFullPath($top).TrimEnd('\','/'), $root, [StringComparison]::OrdinalIgnoreCase)) {
  throw 'rebase-integration: Worktree must be the canonical Git worktree root'
}
$branch = (Invoke-IntegrationGit @('branch','--show-current')).stdout
if ([string]::IsNullOrWhiteSpace($branch)) { throw 'rebase-integration: an attached own branch is required' }
$head = (Invoke-IntegrationGit @('rev-parse','HEAD')).stdout.ToLowerInvariant()
if ($head -cne $ReviewedHead) { throw 'rebase-integration: own branch is not at the reviewed head' }
if (-not [string]::IsNullOrWhiteSpace((Invoke-IntegrationGit @('status','--porcelain=v1','--untracked-files=normal')).stdout)) {
  throw 'rebase-integration: own branch worktree is not clean'
}
$oldBase = (Invoke-IntegrationGit @('merge-base',$ReviewedHead,$NewBase)).stdout
if ($oldBase -cnotmatch '^[a-f0-9]{40}$') { throw 'rebase-integration: reviewed base is not an immutable commit' }

if ($SourcePassReceiptIdentity -ceq 'ABSENT_REVIEW_REQUIRED') {
  if ($SourcePassReviewedHead) { throw 'rebase-integration: absent source PASS cannot name a reviewed PASS head' }
} elseif (-not $SourcePassReviewedHead) {
  $SourcePassReviewedHead = $ReviewedHead
}

$alreadyIntegrated = Invoke-IntegrationGit @('merge-base','--is-ancestor',$NewBase,$ReviewedHead) -AllowFailure
if ($alreadyIntegrated.exitCode -eq 0) {
  [pscustomobject][ordered]@{
    schemaVersion='rebase-integration-result/v1';status=$(if($SourcePassReceiptIdentity-ceq'ABSENT_REVIEW_REQUIRED'){'REVIEW_REQUIRED'}else{'ALREADY_INTEGRATED'});pr=$Pr
    predecessorHead=$ReviewedHead;newHead=$ReviewedHead;newBase=$NewBase;pushed=$false
    continuationAuthority=$(if($SourcePassReceiptIdentity-ceq'ABSENT_REVIEW_REQUIRED'){$false}else{$null})
    review=$(if($SourcePassReceiptIdentity-ceq'ABSENT_REVIEW_REQUIRED'){'NORMAL_EXACT_NEW_HEAD_REQUIRED'}else{'QUALIFIED_EXISTING_AUTHORITY'})
  } | ConvertTo-Json -Depth 5 -Compress
  return
}

Import-Module (Join-Path $PSScriptRoot 'landed-integration-evidence.psm1') -Force -DisableNameChecking
$rebaseStarts = @()
foreach ($owed in @(Get-RebaseOwed $RuntimeRoot $branch $root)) {
  $ownerFiles=@(Get-ChildItem -LiteralPath $RuntimeRoot -Filter 'dispatch-launch-*.json' -File)
  if ($ownerFiles.Count -gt 0 -and $owed.pr -eq $Pr -and $owed.newBase -ceq $NewBase) {
    $rebaseStarts += New-RebaseStart $owed $RuntimeRoot ''
  }
}
$rebase = Invoke-IntegrationGit @('rebase','--onto',$NewBase,$oldBase) -AllowFailure
if ($rebase.exitCode -ne 0) {
  $conflicts = @(((Invoke-IntegrationGit @('diff','--name-only','--diff-filter=U') -AllowFailure).stdout -split "`r?`n") | Where-Object { $_ })
  if ($conflicts.Count -gt 0) { foreach ($startEvidence in $rebaseStarts) { Save-RebaseConflict $startEvidence $RuntimeRoot } }
  [pscustomobject][ordered]@{
    schemaVersion='rebase-integration-result/v1'; status='DELTA_REQUIRED'; pr=$Pr
    reviewedHead=$ReviewedHead; newBase=$NewBase; conflictPaths=@($conflicts)
    reason=$(if($conflicts.Count -gt 0){'REBASE_CONFLICT'}else{'REBASE_FAILED'})
  } | ConvertTo-Json -Depth 5 -Compress
  exit 2
}

$newHead = (Invoke-IntegrationGit @('rev-parse','HEAD')).stdout.ToLowerInvariant()
$attachedBranch = (Invoke-IntegrationGit @('branch','--show-current')).stdout
$localBranchHead = (Invoke-IntegrationGit @('rev-parse',"refs/heads/$branch")).stdout.ToLowerInvariant()
if ($attachedBranch -cne $branch -or $localBranchHead -cne $newHead) {
  throw 'rebase-integration: successful rebase did not preserve the attached own-branch ref'
}
if (-not $NoPush) {
  [void](Invoke-IntegrationGit @('push',"--force-with-lease=$branch`:$ReviewedHead",'origin',"HEAD`:$branch"))
}

if ($SourcePassReceiptIdentity -ceq 'ABSENT_REVIEW_REQUIRED') {
  [pscustomobject][ordered]@{
    schemaVersion='rebase-integration-result/v1';status='REVIEW_REQUIRED';pr=$Pr
    predecessorHead=$ReviewedHead;newHead=$newHead;newBase=$NewBase;pushed=(-not $NoPush)
    continuationAuthority=$false;review='NORMAL_EXACT_NEW_HEAD_REQUIRED'
  } | ConvertTo-Json -Depth 5 -Compress
  return
}

try {
  & (Join-Path $PSScriptRoot 'log-event.ps1') -Log dispatch -Kind repair-complete -Pr $Pr `
    -ReviewedHead $SourcePassReviewedHead -ContinuationPredecessorHead $ReviewedHead -ContinuationSchema 'rebase-only-continuation/v1' `
    -ContinuationNewHead $newHead -ContinuationNewBase $NewBase `
    -SourcePassReceiptIdentity $SourcePassReceiptIdentity -IntegrationLane $IntegrationLane `
    -ContinuationWorktree $root -OutFile $HistoryPath -NoBoard
} catch {
  [pscustomobject][ordered]@{
    schemaVersion='rebase-integration-result/v1'; status='DELTA_REQUIRED'; pr=$Pr
    reviewedHead=$ReviewedHead; newHead=$newHead; newBase=$NewBase
    conflictPaths=@(); reason='PATCH_OR_SOURCE_AUTHORITY_CHANGED'; diagnostic=$_.Exception.Message
  } | ConvertTo-Json -Depth 5 -Compress
  exit 2
}

[pscustomobject][ordered]@{
  schemaVersion='rebase-integration-result/v1'; status='CONTINUATION_LOGGED'; pr=$Pr
  reviewedHead=$SourcePassReviewedHead; predecessorHead=$ReviewedHead; newHead=$newHead; newBase=$NewBase; pushed=(-not $NoPush)
} | ConvertTo-Json -Depth 5 -Compress
