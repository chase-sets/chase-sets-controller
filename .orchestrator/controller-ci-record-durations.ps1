[CmdletBinding()]
param([switch]$Library,[string]$RecordPlanPath,[string]$ResultPath,[string]$OutputPath,
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
  return Get-CiTextDigest (Read-CiGitBytes $Root @('cat-file','blob',"${Head}:$Path"))
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
  $closure=Get-CiTreeDigest $Root $Plan.checkoutHead
  $records=@(foreach($row in $rows){
    Assert-Ci ($seen.Add([string]$row.identity)) 'duplicate duration receipt'
    $item=@($tasks|Where-Object identity -CEQ $row.identity)
    Assert-Ci ($item.Count -eq 1) 'unknown duration receipt'
    if($null-ne$item[0].restriction){Assert-Ci ($row.result-ceq'LOCAL_ONLY'-and$row.exitCode-eq125) 'duration exclusion mismatch';continue}
    Assert-Ci ((($row.result-ceq'PASS'-and$row.exitCode-eq0)-or($row.result-ceq'FAIL'-and$row.exitCode-ne0))-and
      ($row.elapsedMs-is[int]-or$row.elapsedMs-is[long])-and$row.elapsedMs-gt0) 'invalid measured duration'
    [ordered]@{identity=$row.identity;elapsedMs=[long]$row.elapsedMs;recordedAtUtc=$row.finishedUtc
      sourceSha256=(Get-CiBlobDigest $Root $Plan.checkoutHead $item[0].path);sourceSetSha256=$closure
      controllerHead=$Plan.controllerHead;checkoutHead=$Plan.checkoutHead;runnerHead=$Plan.runnerHead
      productSha=$Plan.productSha;runId=[string]$Result.ci.runId;planSha256=$PlanDigest
      result=$row.result;exitCode=$row.exitCode}
  })
  return ,$records
}

if($Library){return}
$plan=Get-Content -LiteralPath $RecordPlanPath -Raw|ConvertFrom-Json -Depth 50 -DateKind String
$result=Get-Content -LiteralPath $ResultPath -Raw|ConvertFrom-Json -Depth 50 -DateKind String
$digest=(Get-FileHash -LiteralPath $RecordPlanPath -Algorithm SHA256).Hash.ToLowerInvariant()
$records=New-CiDurationRecords $plan $result $digest $RepositoryRoot
Write-CiJson @{schemaVersion='controller-ci-durations/v1';records=$records} $OutputPath
Write-Output "RECORDED run=$($result.ci.runId) records=$($records.Count) output=$OutputPath"
