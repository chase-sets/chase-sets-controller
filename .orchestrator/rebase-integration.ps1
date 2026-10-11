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
  [switch]$ContinueInterruptedIntegration,
  [Parameter(DontShow)][switch]$NoPush
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($Worktree).TrimEnd('\','/')

function Invoke-IntegrationGit([string[]]$Arguments, [switch]$AllowFailure, [switch]$RequireOutput) {
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
    if ($RequireOutput -and $process.ExitCode -eq 0 -and [string]::IsNullOrWhiteSpace($result.stdout)) {
      throw 'rebase-integration: git single-line read returned empty at exit zero'
    }
    return $result
  } finally { $process.Dispose() }
}

function Get-IntegrationBranch {
  for ($read = 0; $read -lt 2; $read++) {
    $result = Invoke-IntegrationGit @('symbolic-ref','--quiet','HEAD') -AllowFailure
    if ($result.exitCode -eq 1) { throw 'rebase-integration: an attached own branch is required' }
    if ($result.exitCode -ne 0) { throw "rebase-integration: git symbolic-ref failed ($($result.stderr))" }
    if (-not [string]::IsNullOrWhiteSpace($result.stdout)) {
      if (-not $result.stdout.StartsWith('refs/heads/', [StringComparison]::Ordinal)) { throw 'rebase-integration: an attached own branch is required' }
      return $result.stdout.Substring('refs/heads/'.Length)
    }
  }
  throw 'rebase-integration: attached branch read returned empty at exit zero twice'
}

$top = (Invoke-IntegrationGit @('rev-parse','--show-toplevel') -RequireOutput).stdout
if (-not [string]::Equals([IO.Path]::GetFullPath($top).TrimEnd('\','/'), $root, [StringComparison]::OrdinalIgnoreCase)) {
  throw 'rebase-integration: Worktree must be the canonical Git worktree root'
}
if ($ContinueInterruptedIntegration) {
  Import-Module (Join-Path $PSScriptRoot 'landed-integration-evidence.psm1') -Force -DisableNameChecking
  $child = Get-InterruptedIntegrationChild $RuntimeRoot $env:CHASE_SETS_INTERRUPTED_INTEGRATION_OWNER
  $o = $child.binding.obligation
  if ($o.pr -ne $Pr -or $o.targetHead -cne $ReviewedHead -or $o.newBase -cne $NewBase -or
      -not [string]::Equals($o.worktree,$root,[StringComparison]::OrdinalIgnoreCase)) { throw 'INTEGRATION_RESUME_CHILD: immutable request mismatch' }
  $nativePath = (Invoke-IntegrationGit @('rev-parse','--git-path','rebase-merge') -RequireOutput).stdout
  if (-not [IO.Path]::IsPathFullyQualified($nativePath)) { $nativePath = Join-Path $root $nativePath }
  foreach ($key in @('head-name','orig-head','onto')) {
    $expected = switch ($key) { 'head-name' { "refs/heads/$($o.branch)" }; 'orig-head' { $o.targetHead }; 'onto' { $o.newBase } }
    if ([IO.File]::ReadAllText((Join-Path $nativePath $key)).Trim() -cne $expected) { throw 'INTEGRATION_RESUME_CHILD: native operation mismatch' }
  }
  $result = Invoke-IntegrationGit @('-c','core.editor=true','rebase','--continue') -AllowFailure
  if ($result.exitCode -ne 0) {
    Save-InterruptedIntegrationStop $RuntimeRoot $env:CHASE_SETS_INTERRUPTED_INTEGRATION_OWNER
    $conflicts = @((Invoke-IntegrationGit @('diff','--name-only','--diff-filter=U')).stdout -split "`r?`n" | Where-Object { $_ })
    [ordered]@{schemaVersion='rebase-integration-result/v1';status='DELTA_REQUIRED';pr=$Pr;reviewedHead=$ReviewedHead;newBase=$NewBase;conflictPaths=$conflicts;reason='REBASE_CONFLICT'} | ConvertTo-Json -Depth 5 -Compress
    exit 2
  }
  $newHead = (Invoke-IntegrationGit @('rev-parse','HEAD') -RequireOutput).stdout
  if ((Get-IntegrationBranch) -cne $o.branch -or (Invoke-IntegrationGit @('status','--porcelain=v1','--untracked-files=normal')).stdout) { throw 'INTEGRATION_RESUME_CHILD: incomplete finish' }
  if (-not $NoPush) { [void](Invoke-IntegrationGit @('push',"--force-with-lease=$($o.branch):$ReviewedHead",'origin',"HEAD:$($o.branch)")) }
  [ordered]@{schemaVersion='rebase-integration-result/v1';status='REVIEW_REQUIRED';pr=$Pr;predecessorHead=$ReviewedHead;newHead=$newHead;newBase=$NewBase;pushed=(-not $NoPush);continuationAuthority=$false;review='NORMAL_EXACT_NEW_HEAD_REQUIRED'} | ConvertTo-Json -Compress
  return
}
$branch = Get-IntegrationBranch
$head = (Invoke-IntegrationGit @('rev-parse','HEAD') -RequireOutput).stdout.ToLowerInvariant()
if ($head -cne $ReviewedHead) { throw 'rebase-integration: own branch is not at the reviewed head' }
if (-not [string]::IsNullOrWhiteSpace((Invoke-IntegrationGit @('status','--porcelain=v1','--untracked-files=normal')).stdout)) {
  throw 'rebase-integration: own branch worktree is not clean'
}
$oldBase = (Invoke-IntegrationGit @('merge-base',$ReviewedHead,$NewBase) -RequireOutput).stdout
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

$newHead = (Invoke-IntegrationGit @('rev-parse','HEAD') -RequireOutput).stdout.ToLowerInvariant()
$attachedBranch = Get-IntegrationBranch
$localBranchHead = (Invoke-IntegrationGit @('rev-parse',"refs/heads/$branch") -RequireOutput).stdout.ToLowerInvariant()
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
