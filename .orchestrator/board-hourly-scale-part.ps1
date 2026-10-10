[CmdletBinding()]
param([ValidateSet('all','candidate','baseline','issue-scan','no-linkage','ten-item')][string]$Arm = 'all')
$ErrorActionPreference = 'Stop'
[Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal'
. (Join-Path $PSScriptRoot 'board-scale-test-support.ps1')
. (Join-Path $PSScriptRoot 'routing-data-test-support.ps1')
$scope = Enter-RoutingDataTestScope
$root = Join-Path ([IO.Path]::GetTempPath()) ('board-scale-hourly-' + [guid]::NewGuid().ToString('N'))
try {
  $arms = if ($Arm -eq 'all') { @('candidate','baseline','issue-scan','no-linkage','ten-item') } else { @($Arm) }
  foreach ($name in $arms) {
    $f = New-BoardScaleFixture (Join-Path $root $name) $(if ($name -eq 'ten-item') { 10 } else { 2400 })
    if ($Arm -ne 'all' -and $name -ne 'candidate') { $warm = Measure-BoardReference $f.log; Write-Output "WARMUP standalone board arm=$name discarded reference seconds=$warm" }
    Invoke-BoardScaleArm $f $(if ($name -eq 'ten-item') { 'candidate' } else { $name })
    if ($name -eq 'candidate') { Invoke-BoardScaleArm $f 'inert' }
    if ($name -eq 'ten-item') {
      $scan = New-BoardScaleFixture (Join-Path $root 'ten-item-scan') 10
      Invoke-BoardScaleArm $scan 'ten-item-scan'
      Write-Output 'CONTROL ten-item issue scan is non-discriminating'
    }
    Write-Output "PASS board-live-scale-hourly-apply $name"
  }
} finally {
  Exit-RoutingDataTestScope $scope
  Remove-BoardScaleFixture $root
}
