[CmdletBinding()]
param(
  [Parameter(Mandatory)][string[]]$FinalResultPath,
  [string]$ControllerRoot=(Split-Path -Parent $PSScriptRoot),
  [Parameter(Mandatory)][string]$OutputPath
)
$ErrorActionPreference='Stop'
[Diagnostics.Process]::GetCurrentProcess().PriorityClass='BelowNormal'
. (Join-Path $PSScriptRoot 'controller-ci-planning.ps1')
$records=@{}
$manifest=Get-Content (Join-Path $PSScriptRoot 'controller-ci-parts.json') -Raw | ConvertFrom-Json -Depth 40
foreach ($path in $FinalResultPath) {
  $final=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 40 -DateKind String
  if ($final.schemaVersion -cne 'controller-battery-result/v1' -or
      $final.execution.mode -cne 'github-actions-sharded-file-serial' -or
      [string]$final.ci.runId -cnotmatch '^[1-9][0-9]*$') { throw 'Not a hosted controller duration receipt' }
  foreach ($row in @($final.results)+@($final.ci.executionResults)) {
    if ($row.result -cnotin @('PASS','FAIL') -or
        ($row.elapsedMs -isnot [long] -and $row.elapsedMs -isnot [int]) -or $row.elapsedMs -le 0) { continue }
    $requiredIdentity=([string]$row.identity -split '#',2)[0]
    $item=@($final.inventory | Where-Object identity -CEQ $requiredIdentity)
    if ($item.Count -ne 1) { throw 'Timing row has no unique required identity' }
    $source=Join-Path $ControllerRoot $item[0].path
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { continue }
    $measured=@(& git -C $ControllerRoot show "$($final.controllerHead):$($item[0].path)")
    if ($LASTEXITCODE -ne 0) { throw 'Measured source unavailable; retain the existing profile or import with its source history' }
    $measuredText=($measured -join "`n")+"`n"
    $measuredSha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($measuredText))).ToLowerInvariant()
    $binding=$measuredSha256
    $compatibility=@($manifest.items | Where-Object identity -CEQ $requiredIdentity)
    if ($compatibility.Count -eq 1 -and
        $compatibility[0].durationCompatibility.measuredSourceSha256 -ceq $measuredSha256 -and
        $compatibility[0].durationCompatibility.candidateSourceSha256 -ceq (Get-CiSourceDigest $source)) {
      $binding=$compatibility[0].durationCompatibility.candidateSourceSha256
    }
    $record=[pscustomobject]@{identity=$row.identity;elapsedMs=[long]$row.elapsedMs;recordedAtUtc=$row.finishedUtc
      sourceSha256=$binding;measuredSourceSha256=$measuredSha256
      measuredControllerHead=$final.controllerHead;runId=[string]$final.ci.runId}
    if (-not $records.ContainsKey($row.identity) -or $records[$row.identity].elapsedMs -lt $record.elapsedMs) { $records[$row.identity]=$record }
  }
}
$profile=@{schemaVersion='controller-ci-durations/v1';estimation='maximum recorded elapsedMs; measured-source binding except the explicitly reviewed split-source compatibility mapping; split parents use declared estimated weights until part measurements exist'
  records=@($records.Values | Sort-Object identity)}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath),($profile | ConvertTo-Json -Depth 40)+"`n",[Text.UTF8Encoding]::new($false))
Write-Output "RECORDED durations=$($records.Count) output=$OutputPath"
