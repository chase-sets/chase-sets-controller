[CmdletBinding()]
param([ValidateSet('all','dispatch','lane-complete','review-complete','landed','landed-slow')][string]$Event = 'all')
$ErrorActionPreference = 'Stop'
[Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal'
. (Join-Path $PSScriptRoot 'board-scale-test-support.ps1')
. (Join-Path $PSScriptRoot 'routing-data-test-support.ps1')
$scope = Enter-RoutingDataTestScope
$previous = $env:ORCH_BOARD_SYNC
$env:ORCH_BOARD_SYNC = '1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('board-scale-event-' + [guid]::NewGuid().ToString('N'))
try {
  $events = if ($Event -eq 'all') { @('dispatch','lane-complete','review-complete','landed','landed-slow') } else { @($Event) }
  foreach ($kind in $events) {
    $f = New-BoardScaleFixture (Join-Path $root $kind)
    if ($kind -ne 'dispatch') {
      # Completion/landing clears a previously occupied item. Review completion
      # matches the role of its synthetic dispatch; all other history is frozen.
      if ($kind -eq 'review-complete') {
        $lines = [IO.File]::ReadAllLines($f.log)
        $first = $lines[0] | ConvertFrom-Json -AsHashtable; $first.laneRole = 'review'
        $lines[0] = $first | ConvertTo-Json -Depth 10 -Compress
        [IO.File]::WriteAllLines($f.log, $lines)
        $specPath = Join-Path $f.root 'watchdog-lane-synthetic-scale-1.json'
        $spec = Get-Content $specPath -Raw | ConvertFrom-Json -AsHashtable; $spec.laneRole = 'review'; Write-ScaleJson $specPath $spec
      }
      $itemPath = Join-Path $f.root 'item-8548.json'
      $item = Get-Content $itemPath -Raw | ConvertFrom-Json -AsHashtable; $item.status.name = 'In lane'; Write-ScaleJson $itemPath $item
    }
    Invoke-BoardScaleArm $f 'candidate' $(if ($kind -eq 'landed-slow') { 'landed' } else { $kind }) $(if ($kind -eq 'landed-slow') { 2000 } else { 0 })
    Write-Output "PASS board-live-scale-event $kind"
  }
} finally {
  $env:ORCH_BOARD_SYNC = $previous
  Exit-RoutingDataTestScope $scope
  Remove-BoardScaleFixture $root
}
