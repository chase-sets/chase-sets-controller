Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# #8580 AC3 host smoke (LOCAL_ONLY in CI): the native carriers observe the fleet
# through Resolve-7963FleetContainer. Its default is the real container holding
# this checkout; CI and copy legs observe vacant or synthetic fleets through the
# same seam. This item proves the real host read: the default resolves to the
# installed container (which carries orchestrator runtime state), the
# observation names that container's heavy-verifier owner record, and
# held/vacant agrees with the verifier's own liveness rule recomputed here.
# The slot is only observed, never taken or waited on.
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "ASSERTION FAILED: $Message" } }
Import-Module (Join-Path $PSScriptRoot 'landed-integration-evidence.psm1') -Force -DisableNameChecking
. (Join-Path $PSScriptRoot 'dispatch-ownership.ps1')
. (Join-Path $PSScriptRoot 'interrupted-integration-test-support.ps1')

$savedOverride = $env:CHASE_SETS_TEST_FLEET_CONTAINER
$synthetic = Join-Path ([IO.Path]::GetTempPath()) ('host-smoke-fleet-' + [guid]::NewGuid().ToString('N'))
try {
  Remove-Item Env:CHASE_SETS_TEST_FLEET_CONTAINER -ErrorAction SilentlyContinue
  $default = Resolve-7963FleetContainer
  $expected = [IO.Path]::GetFullPath((Split-Path -Parent (Split-Path -Parent $PSScriptRoot))).TrimEnd('\', '/')
  Assert-True ($default -ceq $expected) "default fleet source is the container holding this checkout: $default"
  Assert-True (Test-Path -LiteralPath (Join-Path $default '.orchestrator') -PathType Container) "the real host container carries orchestrator runtime state: $default\.orchestrator"
  $ownerPath = Join-Path $default '.orchestrator/verify-lock.d/owner.json'
  $first = Get-FleetLoadObservation $default
  Assert-True ([string]$first.ownerPath -ceq $ownerPath) "observation reads the real container heavy-verifier owner record $ownerPath"
  if (Test-Path -LiteralPath $ownerPath -PathType Leaf) {
    $owner = $null
    try { $owner = Get-Content -LiteralPath $ownerPath -Raw | ConvertFrom-Json -DateKind String } catch { $owner = $null }
    if ($null -eq $owner) {
      Assert-True (-not $first.held -and [string]$first.reason -ceq 'unparseable') 'unreadable owner record is observed as not held'
    } else {
      $wrapperLive = ($owner.pid -is [long] -or $owner.pid -is [int]) -and (Get-DispatchProcessIdentityState ([int]$owner.pid) ([string]$owner.processStartUtc)) -ceq 'live'
      $childLive = $false
      if (-not $wrapperLive -and ($owner.schemaVersion -is [long] -or $owner.schemaVersion -is [int]) -and [long]$owner.schemaVersion -ge 2 -and [long]$owner.schemaVersion -le 5 -and ([string]$owner.state) -cin @('started', 'attached')) {
        $childLive = ($owner.childPid -is [long] -or $owner.childPid -is [int]) -and (Get-DispatchProcessIdentityState ([int]$owner.childPid) ([string]$owner.childProcessStartUtc)) -ceq 'live'
      }
      Assert-True ([bool]$first.held -eq ($wrapperLive -or $childLive)) "held=$($first.held) agrees with the heavy verifier liveness rule (wrapper=$wrapperLive child=$childLive)"
      Assert-True ([string]$first.reason -ceq $(if ($first.held) { 'live' } else { 'stale' })) "observation reason '$($first.reason)' matches liveness"
      if ($first.held) { Assert-True (([string]$first.holder).Contains("lockId=$($owner.lockId)")) 'held observation names the live owner lockId' }
    }
  } else {
    Assert-True (-not $first.held -and [string]$first.reason -ceq 'absent' -and [string]$first.holder -ceq 'none') 'absent owner record is observed as a vacant fleet'
  }
  $second = Get-FleetLoadObservation $default
  $window = Get-FleetLoadWindow $first $second
  Assert-True ([bool]$window.held -eq ([bool]$first.held -and [bool]$second.held -and ([string]$first.holder) -ceq ([string]$second.holder))) 'a window is held only across one identical live holder'
  Write-Output "PASS host smoke: real host fleet source $default held=$($first.held) reason=$($first.reason) holder=$($first.holder)"

  # The injection seam: an override is honored exactly and must be a directory.
  [void][IO.Directory]::CreateDirectory($synthetic)
  $env:CHASE_SETS_TEST_FLEET_CONTAINER = $synthetic
  $injected = Resolve-7963FleetContainer
  Assert-True ($injected -ceq [IO.Path]::GetFullPath($synthetic).TrimEnd('\', '/')) "override resolves to the injected container $injected"
  $vacant = Get-FleetLoadObservation $injected
  Assert-True (-not $vacant.held -and [string]$vacant.reason -ceq 'absent' -and ([string]$vacant.ownerPath).StartsWith($injected, [StringComparison]::Ordinal)) 'injected empty container is a vacant fleet observed under its own path'
  $env:CHASE_SETS_TEST_FLEET_CONTAINER = Join-Path $synthetic 'missing'
  $refused = $null
  try { [void](Resolve-7963FleetContainer) } catch { $refused = $_.Exception.Message }
  Assert-True ($refused -like '*fleet container override is not a directory*') "missing override directory refuses: $refused"
  Write-Output 'PASS host smoke: fleet source override is honored exactly and refuses a missing directory'
} finally {
  if ($null -eq $savedOverride) { Remove-Item Env:CHASE_SETS_TEST_FLEET_CONTAINER -ErrorAction SilentlyContinue } else { $env:CHASE_SETS_TEST_FLEET_CONTAINER = $savedOverride }
  Remove-Item -LiteralPath $synthetic -Recurse -Force -ErrorAction SilentlyContinue
}
