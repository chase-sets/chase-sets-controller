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
$replays=@(foreach($count in @(16,17,18)){
  $tasks=New-CiAssignments $calibration.inventory '' $manifest $profile $root -ShardCount $count
  $invalid=@($tasks|Where-Object{$_.timingSource-cnotin@('recorded','recorded-part','local-only')})
  Assert-Ci ($invalid.Count-eq0) "unmeasured/stale hosted timings: $(@($invalid.identity)-join',')"
  $loads=@(0..($count-1)|ForEach-Object{$n=$_;[long](($tasks|Where-Object shard -EQ $n|Measure-Object estimatedMs -Sum).Sum)})
  [ordered]@{shardCount=$count;maxMs=[long](($loads|Measure-Object -Maximum).Maximum);sumMs=[long](($loads|Measure-Object -Sum).Sum)
    feasible=([long](($loads|Measure-Object -Maximum).Maximum)-le250000);loads=$loads
    timingSources=@($tasks|Group-Object timingSource|ForEach-Object{@{source=$_.Name;count=$_.Count}});executionItems=$tasks}
})
$feasible=@($replays|Where-Object feasible)
$chosen=if($feasible.Count){$feasible[0].shardCount}else{$null}
Write-CiJson @{calibrationPlanSha256=(Get-FileHash $CalibrationPlanPath -Algorithm SHA256).Hash.ToLowerInvariant()
  sourceHead=(Get-CiHead $root);sourceSetSha256=(Get-CiTreeDigest $root (Get-CiHead $root));chosenShardCount=$chosen;replays=$replays} (Join-Path $EvidenceDirectory 'prediction.json')
$replays|ForEach-Object{Write-Output "LPT N=$($_.shardCount) maxMs=$($_.maxMs) sumMs=$($_.sumMs) feasible=$($_.feasible)"}
Assert-Ci ($null-ne$chosen) 'no N in 16/17/18 fits 250000 ms; preserve evidence and stop for decomposition'
if($WriteProfile){$profile|Add-Member shardCount $chosen -Force;Write-CiJson $profile $profilePath}
Write-Output "CHOSEN smallestFeasibleN=$chosen"
