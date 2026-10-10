[CmdletBinding()]
param(
  [string]$BaselineHead='2815303128f3151e10d71bfdd351dc9b659a2b47',
  [string]$CandidateHead='',
  [string]$EvidenceDirectory=(Join-Path $PSScriptRoot 'logs/controller-8661-ci-sharding-g1')
)
$ErrorActionPreference='Stop'
[Diagnostics.Process]::GetCurrentProcess().PriorityClass='BelowNormal'
. (Join-Path $PSScriptRoot 'controller-ci.ps1') -Mode Library
$root=Split-Path -Parent $PSScriptRoot
function Get-RequiredIdentities([string]$Head) {
  $paths=if($Head){@(& git -C $root ls-tree -r --name-only $Head .orchestrator)}else{@(& git -C $root ls-files .orchestrator)}
  Assert-Ci ($LASTEXITCODE -eq 0) 'required inventory tree unavailable'
  $paths=[string[]]@($paths | Where-Object {$_ -cmatch '^\.orchestrator/.+\.test\.ps1$' -or $_ -cmatch '^\.orchestrator/issue-[^/]+-discriminator\.ps1$'})
  [array]::Sort($paths,[StringComparer]::Ordinal)
  return ,@('direct:fail-closed-guard-evidence')+@($paths | ForEach-Object {
    if ($_ -cmatch '^\.orchestrator/(issue-[^/]+)-discriminator\.ps1$') {'discriminator:'+$Matches[1]}
    else {'test:'+$_.Substring('.orchestrator/'.Length)}
  })
}
$before=Get-RequiredIdentities $BaselineHead
$after=Get-RequiredIdentities $CandidateHead
[IO.File]::WriteAllLines((Join-Path $EvidenceDirectory 'baseline-required.txt'),[string[]]$before)
[IO.File]::WriteAllLines((Join-Path $EvidenceDirectory 'candidate-required.txt'),[string[]]$after)
$diff=@(Compare-Object $before $after)
Write-CiJson @($diff) (Join-Path $EvidenceDirectory 'required-set-diff.json')
Assert-Ci ($diff.Count -eq 0) 'baseline/candidate required inventory differs'
$legacy=Get-Content (Join-Path $EvidenceDirectory '37233541379/plan.json') -Raw | ConvertFrom-Json -Depth 40
$inventory=@($before | ForEach-Object {
  $id=$_
  $old=@($legacy.inventory | Where-Object identity -CEQ $id)
  $path=if($id -like 'test:*'){'.orchestrator/'+$id.Substring(5)}elseif($id -like 'discriminator:*'){'.orchestrator/'+$id.Substring(14)+'-discriminator.ps1'}else{'.orchestrator/fail-closed-guard-evidence.ps1'}
  [pscustomobject]@{identity=$id;path=$path;arguments=@('-File',$path);command='prediction-only';restriction=$(if($old.Count){$old[0].restriction}else{Get-CiRestriction $id $root})}
})
$profile=Read-CiTimingProfile (Join-Path $PSScriptRoot 'controller-ci-durations.json')
$manifest=Get-Content (Join-Path $PSScriptRoot 'controller-ci-parts.json') -Raw | ConvertFrom-Json
$tasks=New-CiAssignments $inventory '' $manifest $profile $root
Assert-Ci (@($tasks.requiredIdentity | Select-Object -Unique).Count -eq $before.Count) 'prediction lost required identity'
$table=@(0..9 | ForEach-Object {
  $n=$_
  $assigned=@($tasks | Where-Object shard -EQ $n)
  [pscustomobject]@{shard=$n;estimatedMs=[long](($assigned | Measure-Object estimatedMs -Sum).Sum);executionItems=$assigned.Count
    fallbackItems=@($assigned | Where-Object timingSource -like 'fallback*' | ForEach-Object identity)}
})
$observed=@(foreach($run in @('37231788164','37233541379')){
  $final=Get-Content (Join-Path $EvidenceDirectory "$run/final.json") -Raw | ConvertFrom-Json -Depth 40
  @{runId=$run;controllerHead=$final.controllerHead;requiredCount=$final.execution.requiredCount;wholeRunMs=$final.execution.elapsedMs;shards=@($final.ci.shards | Select-Object shard,elapsedMs)}
})
$prediction=@{baselineHead=$BaselineHead;candidateHead=$CandidateHead;requiredCount=$before.Count;executionCount=$tasks.Count;requiredSetDiffCount=$diff.Count
  measuredRuns=$observed;prediction=$table;executionItems=$tasks;maximumPredictedShardMs=($table.estimatedMs | Measure-Object -Maximum).Maximum
  limitations='Execution wall-time estimates, not fresh hosted proof. Split weights include estimated repeated setup. VM setup and final merge are outside shard receipts. New/source-stale tests use deterministic fallback. Landed weights are unmeasured estimates.'}
Write-CiJson $prediction (Join-Path $EvidenceDirectory 'prediction.json')
"INVENTORY baseline=$($before.Count) candidate=$($after.Count) diff=$($diff.Count) executionParts=$($tasks.Count)"
$table | ForEach-Object {'SHARD {0} estimatedMinutes={1:n3} items={2} fallback={3}' -f $_.shard,($_.estimatedMs/60000),$_.executionItems,$_.fallbackItems.Count}
'MAXIMUM estimatedMinutes={0:n3}' -f ($prediction.maximumPredictedShardMs/60000)
