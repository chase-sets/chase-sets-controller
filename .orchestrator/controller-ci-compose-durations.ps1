[CmdletBinding()]
param(
  [ValidateSet('Compose','Library')][string]$Mode='Compose',
  [string]$CalibrationProfile,
  [string]$HistoricalProfile,
  # Required identities whose parts were remeasured; every historical record of
  # these families (whole parents and old parts alike) is superseded.
  [string[]]$RemeasuredIdentity=@('test:dispatch-routing-data.test.ps1','test:cleanup-orphan-worktree-dirs.test.ps1','test:board-hourly-scale.test.ps1'),
  [string]$OutputPath
)
$ErrorActionPreference='Stop'
[Diagnostics.Process]::GetCurrentProcess().PriorityClass='BelowNormal'

function Read-CiDurationInput([string]$Path) {
  $profile=Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 40 -DateKind String
  if ($profile.schemaVersion -cne 'controller-ci-durations/v1') { throw "Not a controller CI duration profile: $Path" }
  $ids=@($profile.records | ForEach-Object { [string]$_.identity })
  if (@($ids | Select-Object -Unique).Count -ne $ids.Count) { throw "Duplicate duration identity in $Path" }
  return $profile
}

# Calibration wins: never a maximum across calibration and history. Surviving
# records keep their original head, run, digest and timestamp provenance.
function Merge-CiDurationProfiles($Calibration, $Historical, [string[]]$Remeasured) {
  $records=[Collections.Generic.List[object]]::new()
  $calibrated=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($record in @($Calibration.records)) { [void]$calibrated.Add([string]$record.identity); $records.Add($record) }
  foreach ($record in @($Historical.records)) {
    $required=([string]$record.identity -split '#',2)[0]
    if ($required -cin $Remeasured -or $calibrated.Contains([string]$record.identity)) { continue }
    $records.Add($record)
  }
  return [ordered]@{schemaVersion='controller-ci-durations/v1'
    estimation="calibration-first composition: every calibration record, plus historical records outside remeasured families ($($Remeasured -join ', ')); recorded maximum elapsedMs per input with original provenance"
    records=@($records | Sort-Object { [string]$_.identity } -Culture ([Globalization.CultureInfo]::InvariantCulture))}
}

if ($Mode -ceq 'Library') { return }
$calibration=Read-CiDurationInput $CalibrationProfile
$historical=Read-CiDurationInput $HistoricalProfile
$profile=Merge-CiDurationProfiles $calibration $historical $RemeasuredIdentity
[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath),($profile | ConvertTo-Json -Depth 40)+"`n",[Text.UTF8Encoding]::new($false))
Write-Output "COMPOSED durations=$(@($profile.records).Count) calibration=$(@($calibration.records).Count) historical=$(@($historical.records).Count) output=$OutputPath"
