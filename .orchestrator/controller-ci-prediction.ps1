[CmdletBinding()]
param([Parameter(Mandatory)][string]$EvidenceDirectory,[string]$CalibrationPlanPath,[switch]$WriteProfile)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'controller-ci.ps1') -Mode Library
. (Join-Path $PSScriptRoot 'controller-ci-record-durations.ps1') -Library
if(-not$CalibrationPlanPath){$CalibrationPlanPath=Join-Path $EvidenceDirectory 'calibration/plan/plan.json'}
$calibration=Get-Content -LiteralPath $CalibrationPlanPath -Raw|ConvertFrom-Json -Depth 50 -DateKind String
$profilePath=Join-Path $PSScriptRoot 'controller-ci-durations.json'
$profile=Read-CiTimingProfile $profilePath
Assert-Ci ($null-ne$profile) 'measured timing profile required'
$manifest=Get-Content (Join-Path $PSScriptRoot 'controller-ci-parts.json') -Raw|ConvertFrom-Json -Depth 50
$root=Split-Path -Parent $PSScriptRoot
# Every estimate must be a hosted observation of that exact execution identity
# (the slowest one within 30 days); fallback and equal-weight split estimates
# are not observations. Stale records are observations of earlier bytes.
$observed=@('recorded','recorded-part','stale-recorded','stale-recorded-part','local-only')
$targetMs=200000L;$boundMs=300000L;$maxShards=32
$replays=@(foreach($count in 16..$maxShards){
  $tasks=New-CiAssignments $calibration.inventory '' $manifest $profile $root -ShardCount $count
  $invalid=@($tasks|Where-Object{$_.timingSource-cnotin$observed})
  Assert-Ci ($invalid.Count-eq0) "unobserved hosted timings: $(@($invalid.identity)-join',')"
  $loads=@(0..($count-1)|ForEach-Object{$n=$_;[long](($tasks|Where-Object shard -EQ $n|Measure-Object estimatedMs -Sum).Sum)})
  $max=[long](($loads|Measure-Object -Maximum).Maximum)
  [ordered]@{shardCount=$count;maxMs=$max;sumMs=[long](($loads|Measure-Object -Sum).Sum)
    feasible=($max-le$targetMs);withinBound=($max-le$boundMs);loads=$loads
    largestItems=@($tasks|Sort-Object estimatedMs -Descending|Select-Object -First 5|ForEach-Object{@{identity=$_.identity;estimatedMs=$_.estimatedMs;shard=$_.shard}})
    timingSources=@($tasks|Group-Object timingSource|ForEach-Object{@{source=$_.Name;count=$_.Count}});executionItems=$tasks}
})
# Raise N until the predicted maximum shard meets the target, capped at 32.
$feasible=@($replays|Where-Object feasible)
$capped=$replays[-1]
$chosen=if($feasible.Count){$feasible[0].shardCount}elseif($capped.withinBound){$capped.shardCount}else{$null}
Write-CiJson @{calibrationPlanSha256=(Get-FileHash $CalibrationPlanPath -Algorithm SHA256).Hash.ToLowerInvariant()
  sourceHead=(Get-CiHead $root);sourceSetSha256=(Get-CiTreeDigest $root (Get-CiHead $root));chosenShardCount=$chosen;targetMs=$targetMs;boundMs=$boundMs
  targetMet=[bool]$feasible.Count;replays=$replays
  weighting='maximum hosted observation per execution identity within 30 days (source/dependency-matching records first)'
  profileRecordCount=@($profile.records).Count
  recordRuns=@($profile.records|Group-Object runId|ForEach-Object{@{runId=$_.Name;records=$_.Count}})} (Join-Path $EvidenceDirectory 'prediction.json')
$replays|ForEach-Object{Write-Output "LPT N=$($_.shardCount) maxMs=$($_.maxMs) sumMs=$($_.sumMs) feasible=$($_.feasible)"}
if(-not$feasible.Count){Write-Output "TARGET_UNMET no N in 16..$maxShards has predicted max <= $targetMs ms; N=$maxShards maxMs=$($capped.maxMs) largest=$(@($capped.largestItems|ForEach-Object{"$($_.identity)=$($_.estimatedMs)"})-join',')"}
Assert-Ci ($null-ne$chosen) "no N in 16..$maxShards fits $boundMs ms; preserve evidence and stop for decomposition"
if($WriteProfile){$profile|Add-Member shardCount $chosen -Force;Write-CiJson $profile $profilePath}
Write-Output "CHOSEN shardCount=$chosen targetMet=$([bool]$feasible.Count)"
