[CmdletBinding()]
param([switch]$Library,[string]$RecordPlanPath,[string]$ResultPath,[string]$OutputPath,[switch]$Append,
  [string]$RepositoryRoot=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
if(-not (Get-Command Assert-Ci -ErrorAction SilentlyContinue)) {
  . (Join-Path $PSScriptRoot 'controller-ci.ps1') -Mode Library
}

function Read-CiGitBytes([string]$Root,[string[]]$Arguments) {
  $info=[Diagnostics.ProcessStartInfo]::new('git')
  $info.WorkingDirectory=$Root; $info.UseShellExecute=$false
  $info.CreateNoWindow=$true; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
  foreach($argument in $Arguments){$info.ArgumentList.Add($argument)}
  $process=[Diagnostics.Process]::Start($info)
  $errorTask=$process.StandardError.ReadToEndAsync()
  $bytes=[IO.MemoryStream]::new()
  try {
    $process.StandardOutput.BaseStream.CopyTo($bytes);$process.WaitForExit()
    $errorText=$errorTask.GetAwaiter().GetResult()
    Assert-Ci ($process.ExitCode -eq 0) "exact Git bytes unavailable: $($Arguments -join ' ')"
    return ,$bytes.ToArray()
  } finally {$bytes.Dispose();$process.Dispose()}
}

function ConvertFrom-CiUtf8([byte[]]$Bytes) {
  $text=[Text.UTF8Encoding]::new($false,$true).GetString($Bytes)
  if($text.StartsWith([string][char]0xfeff,[StringComparison]::Ordinal)){$text=$text.Substring(1)}
  return $text
}

function Get-CiTextDigest([byte[]]$Bytes) {
  $text=(ConvertFrom-CiUtf8 $Bytes).Replace("`r`n","`n")
  return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($text))).ToLowerInvariant()
}

function Get-CiBlobDigest([string]$Root,[string]$Head,[string]$Path) {
  if(-not$script:ciBlobDigests){$script:ciBlobDigests=@{}}
  $key="$Root|$Head|$Path"
  if(-not$script:ciBlobDigests.ContainsKey($key)){
    $script:ciBlobDigests[$key]=Get-CiTextDigest (Read-CiGitBytes $Root @('cat-file','blob',"${Head}:$Path"))
  }
  return $script:ciBlobDigests[$key]
}

function Get-CiTimingSourceSetDigest([string]$Root,[string]$Head,[string]$Path,[string]$RunnerHead=$Head) {
  if(-not$script:ciTimingSets){$script:ciTimingSets=@{}}
  $key="$Root|$Head|$Path|$RunnerHead"
  if($script:ciTimingSets.ContainsKey($key)){return $script:ciTimingSets[$key]}
  if(-not$script:ciTimingTrees){$script:ciTimingTrees=@{}}
  $treeKey="$Root|$Head"
  if(-not$script:ciTimingTrees.ContainsKey($treeKey)){
    $listing=ConvertFrom-CiUtf8 (Read-CiGitBytes $Root @('ls-tree','-r','--full-tree','-z',$Head))
    $script:ciTimingTrees[$treeKey]=@($listing.Split([char]0,[StringSplitOptions]::RemoveEmptyEntries))
  }
  $entries=$script:ciTimingTrees[$treeKey]
  $proofs=@($entries|ForEach-Object{($_-split"`t",2)[1]}|Where-Object{$_-cmatch'\.(test|check)\.ps1$'})
  $needed=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  [void]$needed.Add($Path)
  $queue=[Collections.Generic.Queue[string]]::new();$queue.Enqueue($Path)
  $usesParts=$false
  $ciCheck=$Path.StartsWith('.orchestrator/controller-ci',[StringComparison]::Ordinal)
  if(-not$script:ciTimingTexts){$script:ciTimingTexts=@{}}
  while(-not$ciCheck-and$queue.Count){
    $proofPath=$queue.Dequeue();$textKey="$Root|$Head|$proofPath"
    if(-not$script:ciTimingTexts.ContainsKey($textKey)){
      $script:ciTimingTexts[$textKey]=ConvertFrom-CiUtf8 (Read-CiGitBytes $Root @('cat-file','blob',"${Head}:$proofPath"))
    }
    $text=$script:ciTimingTexts[$textKey]
    if($text.Contains('suite-parts.ps1',[StringComparison]::Ordinal)){$usesParts=$true}
    foreach($proof in $proofs){
      if($text.Contains((Split-Path -Leaf $proof),[StringComparison]::Ordinal)-and$needed.Add($proof)){$queue.Enqueue($proof)}
    }
  }
  # Runtime/fixture inputs remain conservative. Proof entrypoints are included
  # through their source references, not because an unrelated suite changed.
  # CI-library checks observe the complete tree; ordinary suites do not execute
  # planning/recording code. Runner bytes come from the actual workflow head.
  $selected=@(foreach($entry in $entries){
    $name=($entry-split"`t",2)[1]
    if($name-ceq'.orchestrator/controller-ci-durations.json'){continue}
    if($name-cin@('.orchestrator/controller-ci.ps1','.github/workflows/controller-battery.yml')){
      "$name`t$(Get-CiBlobDigest $Root $RunnerHead $name)";continue
    }
    if(-not$ciCheck){
      if($name.StartsWith('.orchestrator/controller-ci',[StringComparison]::Ordinal)){continue}
      if($name-ceq'.orchestrator/suite-parts.ps1'-and-not$usesParts){continue}
      if($name-cmatch'\.(test|check)\.ps1$'-and-not$needed.Contains($name)){continue}
    }
    $entry
  })
  $selected=[string[]]$selected;[Array]::Sort($selected,[StringComparer]::Ordinal)
  $script:ciTimingSets[$key]=Get-CiTextDigest ([Text.Encoding]::UTF8.GetBytes(($selected-join"`n")))
  return $script:ciTimingSets[$key]
}

function Get-CiTreeDigest([string]$Root,[string]$Head) {
  # Deliberately conservative import/copy closure: every tracked byte except
  # this self-referential profile. This includes runner, workflows, fixtures,
  # modules, contracts and the source-copy siblings, not only direct imports.
  $listing=ConvertFrom-CiUtf8 (Read-CiGitBytes $Root @('ls-tree','-r','--full-tree','-z',$Head))
  $entries=@($listing.Split([char]0,[StringSplitOptions]::RemoveEmptyEntries) | Where-Object {
    ($_ -split "`t",2)[1] -cne '.orchestrator/controller-ci-durations.json'
  })
  $entries=[string[]]$entries
  [Array]::Sort($entries,[StringComparer]::Ordinal)
  return Get-CiTextDigest ([Text.Encoding]::UTF8.GetBytes(($entries -join "`n")))
}

function New-CiDurationRecords($Plan,$Result,[string]$PlanDigest,[string]$Root) {
  Assert-Ci ($Result.ci.checkoutHead -ceq $Plan.checkoutHead -and $Result.controllerHead -ceq $Plan.controllerHead -and
    $Result.ci.runnerHead -ceq $Plan.runnerHead -and $Result.ci.productSha -ceq $Plan.productSha -and
    $Result.ci.planSha256 -ceq $PlanDigest -and [string]$Result.ci.runId -cmatch '^\d+$') 'duration receipt binding mismatch'
  $tasks=@($Plan.executionItems);$rows=@($Result.ci.executionResults)
  Assert-Ci ($rows.Count -eq $tasks.Count) 'duration receipt cardinality mismatch'
  $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  $records=@(foreach($row in $rows){
    Assert-Ci ($seen.Add([string]$row.identity)) 'duplicate duration receipt'
    $item=@($tasks|Where-Object identity -CEQ $row.identity)
    Assert-Ci ($item.Count -eq 1) 'unknown duration receipt'
    if($null-ne$item[0].restriction){Assert-Ci ($row.result-ceq'LOCAL_ONLY'-and$row.exitCode-eq125) 'duration exclusion mismatch';continue}
    Assert-Ci ((($row.result-ceq'PASS'-and$row.exitCode-eq0)-or($row.result-ceq'FAIL'-and$row.exitCode-ne0))-and
      ($row.elapsedMs-is[int]-or$row.elapsedMs-is[long])-and$row.elapsedMs-gt0) 'invalid measured duration'
    [ordered]@{identity=$row.identity;elapsedMs=[long]$row.elapsedMs;recordedAtUtc=$row.finishedUtc
      sourceSha256=(Get-CiBlobDigest $Root $Plan.checkoutHead $item[0].path)
      sourceSetSha256=(Get-CiTimingSourceSetDigest $Root $Plan.checkoutHead $item[0].path $Plan.runnerHead)
      controllerHead=$Plan.controllerHead;checkoutHead=$Plan.checkoutHead;runnerHead=$Plan.runnerHead
      productSha=$Plan.productSha;runId=[string]$Result.ci.runId;planSha256=$PlanDigest
      result=$row.result;exitCode=$row.exitCode}
  })
  return ,$records
}

# Appending merges records (first copy of identity/run/plan wins) and keeps the
# profile's chosen shardCount; dropping it would silently replan the 18-shard
# fallback ([#123 Run dispatch-lane.test.ps1 on hosted CI in parts within the
# shard bound](https://github.com/chase-sets/chase-sets-controller/issues/123)).
# A fresh (non-append) profile has no shardCount until prediction writes one.
function New-CiDurationProfile($Existing,[object[]]$Records) {
  $all=@(if($null-ne$Existing){@($Existing.records)})+@($Records)
  $unique=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  $merged=@(foreach($record in $all){
    $key="$($record.identity)|$($record.runId)|$($record.planSha256)"
    if($unique.Add($key)){$record}
  })
  $profileOut=@{schemaVersion='controller-ci-durations/v1';records=$merged}
  if($null-ne$Existing-and$null-ne$Existing.shardCount){$profileOut.shardCount=Get-CiShardCount @{shardCount=$Existing.shardCount}}
  return $profileOut
}

if($Library){return}
$plan=Get-Content -LiteralPath $RecordPlanPath -Raw|ConvertFrom-Json -Depth 50 -DateKind String
$result=Get-Content -LiteralPath $ResultPath -Raw|ConvertFrom-Json -Depth 50 -DateKind String
$digest=(Get-FileHash -LiteralPath $RecordPlanPath -Algorithm SHA256).Hash.ToLowerInvariant()
$records=New-CiDurationRecords $plan $result $digest $RepositoryRoot
$existing=$null
if($Append-and(Test-Path -LiteralPath $OutputPath)){
  $existing=Read-CiTimingProfile $OutputPath
  Assert-Ci ($null-ne$existing) 'cannot append unreadable timing profile'
}
$durationProfile=New-CiDurationProfile $existing $records
Write-CiJson $durationProfile $OutputPath
Write-Output "RECORDED run=$($result.ci.runId) records=$($durationProfile.records.Count) shardCount=$($durationProfile.shardCount) output=$OutputPath"
