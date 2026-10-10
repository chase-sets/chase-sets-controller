[CmdletBinding()]
param(
  [string]$BaselineHead='321915d57da6fbaf647a30080c90601470c2b2cb',
  [string]$CandidateHead='',
  [string]$EvidenceDirectory=(Join-Path ([IO.Path]::GetTempPath()) 'controller-ci-prediction'),
  # Hosted plan whose inventory supplies the runner's LOCAL_ONLY restrictions;
  # local container history would otherwise make hosted-only items look runnable.
  [string]$RestrictionPlanPath=(Join-Path $PSScriptRoot '../../.orchestrator/logs/controller-8661-hosted-gate-g1.evidence/H-plan/plan.json'),
  # Recorder output of the hosted calibration run (AC5); every record must be
  # planned at exactly its calibrated value.
  [string]$CalibrationProfile='',
  [int[]]$ShardCounts=@(16,17,18),
  [long]$PlannedMaximumMs=250000,
  [datetimeoffset]$Now=[datetimeoffset]::UtcNow
)
$ErrorActionPreference='Stop'
[Diagnostics.Process]::GetCurrentProcess().PriorityClass='BelowNormal'
. (Join-Path $PSScriptRoot 'controller-ci.ps1') -Mode Library
$root=Split-Path -Parent $PSScriptRoot
[void][IO.Directory]::CreateDirectory($EvidenceDirectory)
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
$hosted=Get-Content -LiteralPath $RestrictionPlanPath -Raw | ConvertFrom-Json -Depth 40 -DateKind String
$inventory=@($after | ForEach-Object {
  $id=$_
  $old=@($hosted.inventory | Where-Object identity -CEQ $id)
  Assert-Ci ($old.Count -eq 1) "restriction plan lacks required identity: $id"
  $path=if($id -like 'test:*'){'.orchestrator/'+$id.Substring(5)}elseif($id -like 'discriminator:*'){'.orchestrator/'+$id.Substring(14)+'-discriminator.ps1'}else{'.orchestrator/fail-closed-guard-evidence.ps1'}
  [pscustomobject]@{identity=$id;path=$path;arguments=@('-File',$path);command='prediction-only';restriction=$old[0].restriction}
})
$profile=Read-CiTimingProfile (Join-Path $PSScriptRoot 'controller-ci-durations.json')
$manifest=Get-Content (Join-Path $PSScriptRoot 'controller-ci-parts.json') -Raw | ConvertFrom-Json
$replays=@(foreach ($count in $ShardCounts) {
  $tasks=New-CiAssignments $inventory '' $manifest $profile $root $Now -ShardCount $count
  Assert-Ci (@($tasks.requiredIdentity | Select-Object -Unique).Count -eq $after.Count) 'prediction lost required identity'
  $loads=@(0..($count-1) | ForEach-Object { $n=$_; [long](($tasks | Where-Object shard -EQ $n | Measure-Object estimatedMs -Sum).Sum) })
  [pscustomobject]@{shardCount=$count;maximumMs=($loads | Measure-Object -Maximum).Maximum;loadsMs=$loads;tasks=$tasks}
})
$tasks=$replays[0].tasks
$census=[ordered]@{}
foreach ($group in @($tasks | Group-Object timingSource | Sort-Object Name)) { $census[$group.Name]=@($group.Group.identity | Sort-Object) }

# AC5 gate: zero fallback or split estimates; every calibration record planned
# at its value; every other estimate from an attributable record <=30 days old.
$reasons=[Collections.Generic.List[string]]::new()
$unmeasured=@($tasks | Where-Object { $_.timingSource -ceq 'fallback' -or $_.timingSource -clike '*-split-estimate' })
if ($unmeasured.Count) { $reasons.Add("unmeasured=$($unmeasured.Count)") }
$calibration=$null
if ($CalibrationProfile) {
  $calibration=Get-Content -LiteralPath $CalibrationProfile -Raw | ConvertFrom-Json -Depth 40 -DateKind String
  foreach ($record in @($calibration.records)) {
    $task=@($tasks | Where-Object identity -CEQ $record.identity)
    if ($task.Count -eq 0) { continue }  # whole-parent rows of split items are not execution items
    if ($task[0].estimatedMs -ne [long]$record.elapsedMs -or $task[0].timingSource -cnotin @('recorded','recorded-part')) {
      $reasons.Add("calibration-not-planned=$($record.identity)")
    }
  }
  foreach ($task in @($tasks | Where-Object { ($_.requiredIdentity) -cin @('test:dispatch-routing-data.test.ps1','test:cleanup-orphan-worktree-dirs.test.ps1','test:board-hourly-scale.test.ps1') })) {
    if (@($calibration.records | Where-Object identity -CEQ $task.identity).Count -ne 1) { $reasons.Add("part-not-calibrated=$($task.identity)") }
  }
} else { $reasons.Add('calibration-profile-absent') }
foreach ($task in @($tasks | Where-Object { $_.timingSource -cnotin @('local-only','fallback') -and $_.timingSource -cnotlike '*-split-estimate' })) {
  $record=@($profile.records | Where-Object identity -CEQ $task.identity)
  if ($record.Count -ne 1 -or [string]$record[0].runId -cnotmatch '^[1-9][0-9]*$' -or [string]$record[0].measuredControllerHead -cnotmatch '^[a-f0-9]{40}$') {
    $reasons.Add("unattributable=$($task.identity)")
  }
}
$fits=@($replays | Where-Object { $_.maximumMs -le $PlannedMaximumMs })
$selected=if ($fits.Count) { $fits[0].shardCount } else { $null }
if ($null -eq $selected) { $reasons.Add("no-shard-count-fits=$($ShardCounts -join '/')") }
elseif ($selected -ne $CiShardCount) { $reasons.Add("runner-shardCount=$CiShardCount selected=$selected") }
$prediction=[ordered]@{baselineHead=$BaselineHead;candidateHead=$CandidateHead;requiredCount=$before.Count;executionCount=$tasks.Count
  requiredSetDiffCount=$diff.Count;runnerShardCount=$CiShardCount;plannedMaximumMs=$PlannedMaximumMs;selectedShardCount=$selected
  replays=@($replays | ForEach-Object { [ordered]@{shardCount=$_.shardCount;maximumMs=$_.maximumMs;loadsMs=$_.loadsMs} })
  timingSourceCensus=$census;gateReady=($reasons.Count -eq 0);gateReasons=@($reasons)
  executionItems=@($tasks | Select-Object identity,requiredIdentity,estimatedMs,timingSource,shard)
  limitations='Planned execution estimates, not hosted proof. VM setup, queueing and final merge are outside item clocks; the hosted gate measures them.'}
Write-CiJson $prediction (Join-Path $EvidenceDirectory 'prediction.json')
"INVENTORY baseline=$($before.Count) candidate=$($after.Count) diff=$($diff.Count) executionItems=$($tasks.Count)"
foreach ($name in $census.Keys) { 'TIMING_SOURCE {0} count={1}' -f $name,$census[$name].Count }
foreach ($replay in $replays) { 'REPLAY shardCount={0} maximumSeconds={1:n3}' -f $replay.shardCount,($replay.maximumMs/1000) }
if ($unmeasured.Count) { 'UNMEASURED ' + (@($unmeasured.identity | Sort-Object) -join ',') }
"GATE ready=$($reasons.Count -eq 0) selectedShardCount=$selected runnerShardCount=$CiShardCount reasons=$(@($reasons | Select-Object -First 12) -join ';')"
if ($reasons.Count) { exit 1 }
