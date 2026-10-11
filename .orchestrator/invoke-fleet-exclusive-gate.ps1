<#
.SYNOPSIS
Authenticates one controller-owned fleet-exclusive claimant and runs one fixed
heavy verifier gate in the foreground while holding the fleet-exclusive lock.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$Issue,
  [Parameter(Mandatory)][ValidatePattern("^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$")][string]$LeaseHolder,
  [Parameter(Mandatory)][ValidatePattern("^[A-Za-z0-9][A-Za-z0-9._:-]{0,79}$")][string]$Attempt,
  [Parameter(Mandatory)][string]$Worktree,
  [Parameter(Mandatory)][string]$Branch,
  [Parameter(Mandatory)][ValidatePattern("^[a-f0-9]{40}$")][string]$ClaimedHead,
  [Parameter(Mandatory)][ValidateSet("verify:static", "check:static", "test:scripts", "verify:test", "test", "test:fast", "build", "verify", "verify:build", "verify:test-db")][string]$Gate
)

$ErrorActionPreference = "Stop"
$tokenName = "CHASE_SETS_FLEET_ADMISSION_TOKEN"
$fleetOwner = $null
$verifierProcess = $null
$verifierExitCode = $null
$releaseFailed = $false

Import-Module (Join-Path $PSScriptRoot "fleet-exclusive-admission.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot "lease-contract.psm1") -Force -DisableNameChecking

try {
  if (Test-Path "Env:$tokenName") {
    throw "ADMISSION_DENIED: nested fleet admission is forbidden"
  }
  if (-not $Attempt.StartsWith("$Issue-", [StringComparison]::Ordinal)) {
    throw "ADMISSION_DENIED: attempt does not bind the supplied issue"
  }

  $controllerRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd("\", "/")
  $runtimeRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd("\", "/")
  $expectedRuntime = Join-Path $controllerRoot ".orchestrator"
  if (-not [string]::Equals($runtimeRoot, [IO.Path]::GetFullPath($expectedRuntime).TrimEnd("\", "/"), [StringComparison]::OrdinalIgnoreCase)) {
    throw "ADMISSION_DENIED: controller runtime root is foreign"
  }

  function Invoke-IdentityGit([string]$Root, [string[]]$Arguments, [string]$Diagnostic) {
    $output = @(& git -C $Root @Arguments 2>$null)
    if ($LASTEXITCODE -ne 0) { throw "ADMISSION_DENIED: $Diagnostic" }
    ($output -join "`n").Trim()
  }

  $controllerTop = Invoke-IdentityGit $controllerRoot @("rev-parse", "--show-toplevel") "controller root is not a Git worktree"
  if (-not [string]::Equals([IO.Path]::GetFullPath($controllerTop).TrimEnd("\", "/"), $controllerRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "ADMISSION_DENIED: controller root is not canonical"
  }
  $controllerHead = (Invoke-IdentityGit $controllerRoot @("rev-parse", "--verify", "HEAD") "controller HEAD is unavailable").ToLowerInvariant()
  if ($controllerHead -cnotmatch "^[a-f0-9]{40}$") {
    throw "ADMISSION_DENIED: controller HEAD is invalid"
  }
  foreach ($relative in @(
    ".orchestrator/invoke-fleet-exclusive-gate.ps1",
    ".orchestrator/fleet-exclusive-admission.psm1",
    ".orchestrator/dispatch-ownership.ps1",
    ".orchestrator/lease-contract.psm1",
    ".orchestrator/invoke-heavy-verifier.ps1"
  )) {
    $expectedBlob = Invoke-IdentityGit $controllerRoot @("rev-parse", "$controllerHead`:$relative") "controller release member is absent: $relative"
    $path = Join-Path $controllerRoot $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
        (Get-Item -LiteralPath $path -Force).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
      throw "ADMISSION_DENIED: controller release member is absent or unsafe: $relative"
    }
    $actualBlob = Invoke-IdentityGit $controllerRoot @("hash-object", "--", $path) "controller release member cannot be hashed: $relative"
    if ($actualBlob -cne $expectedBlob) {
      throw "ADMISSION_DENIED: controller release identity mismatch: $relative"
    }
  }

  $orchestrationLease = Read-OrchestrationLease -Path (Join-Path $runtimeRoot "lease.json") -ObservedAtUtc ([datetimeoffset]::UtcNow)
  if ($orchestrationLease.status -cne "ok" -or $null -eq $orchestrationLease.record -or
      [string]$orchestrationLease.record.holder -cne $LeaseHolder) {
    throw "ADMISSION_DENIED: host identity record does not name the exact holder"
  }

  $worktreeFull = [IO.Path]::GetFullPath($Worktree).TrimEnd("\", "/")
  if ($worktreeFull -eq $controllerRoot -or
      -not [string]::Equals((Split-Path -Parent $worktreeFull), $controllerRoot, [StringComparison]::OrdinalIgnoreCase) -or
      -not (Test-Path -LiteralPath $worktreeFull -PathType Container)) {
    throw "ADMISSION_DENIED: worktree must be one canonical direct child of the controller root"
  }
  $worktreeTop = Invoke-IdentityGit $worktreeFull @("rev-parse", "--show-toplevel") "worktree root is unavailable"
  if (-not [string]::Equals([IO.Path]::GetFullPath($worktreeTop).TrimEnd("\", "/"), $worktreeFull, [StringComparison]::OrdinalIgnoreCase)) {
    throw "ADMISSION_DENIED: worktree root is aliased or non-canonical"
  }
  $liveBranch = Invoke-IdentityGit $worktreeFull @("branch", "--show-current") "worktree branch is unavailable"
  $liveHead = (Invoke-IdentityGit $worktreeFull @("rev-parse", "--verify", "HEAD") "worktree HEAD is unavailable").ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($Branch) -or $Branch -cne $liveBranch) {
    throw "ADMISSION_DENIED: branch identity mismatch"
  }
  if ($liveHead -cne $ClaimedHead) {
    throw "ADMISSION_DENIED: claimed immutable head mismatch"
  }
  $status = @(& git --no-optional-locks -C $worktreeFull status --porcelain=v1 --untracked-files=normal 2>$null)
  if ($LASTEXITCODE -ne 0 -or $status.Count -ne 0) {
    throw "ADMISSION_DENIED: exact candidate worktree is not clean"
  }

  $fleetOwner = Enter-FleetExclusiveAdmission `
    -RuntimeRoot $runtimeRoot -LeaseHolder $LeaseHolder -Issue $Issue -Attempt $Attempt `
    -ControllerRoot $controllerRoot -ControllerHead $controllerHead -Worktree $worktreeFull `
    -Branch $Branch -ClaimedHead $ClaimedHead -Gate $Gate # FLEET_ADMISSION_GUARD_LEASE_PUBLISHED_BEFORE_CENSUS

  Assert-FleetExclusiveLaneCensusVacant `
    -RuntimeRoot $runtimeRoot -TempRoot ([IO.Path]::GetTempPath()) -ContainerRoot $controllerRoot | Out-Null # FLEET_ADMISSION_GUARD_LANE_CENSUS_INSPECTION
  Assert-FleetExclusiveLaneCensusVacant `
    -RuntimeRoot $runtimeRoot -TempRoot ([IO.Path]::GetTempPath()) -ContainerRoot $controllerRoot | Out-Null # FLEET_ADMISSION_GUARD_LANE_CENSUS_REREAD

  $heavyVerifier = Join-Path $runtimeRoot "invoke-heavy-verifier.ps1"
  $powershell = (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
  if (-not (Get-Command Start-Process).Parameters.ContainsKey("Environment")) {
    throw "ADMISSION_DENIED: PowerShell cannot publish the child-only admission token"
  }
  $arguments = @(
    "-NoProfile", "-NonInteractive", "-File", $heavyVerifier,
    "-Gate", $Gate, "-Worktree", $worktreeFull, "-Lane", $Attempt,
    "-Branch", $Branch, "-ClaimedHead", $ClaimedHead
  )
  $verifierProcess = Start-Process -FilePath $powershell -ArgumentList $arguments `
    -WorkingDirectory $worktreeFull -Environment @{ $tokenName = $fleetOwner.token } `
    -WindowStyle Hidden -PassThru
  try {
    $childStartIdentity = (Get-Process -Id $verifierProcess.Id -ErrorAction Stop).StartTime.ToUniversalTime().ToString("o")
  } catch {
    $childStartIdentity = $null
  }
  $fleetOwner = Set-FleetExclusiveAdmissionChild $fleetOwner $verifierProcess.Id $childStartIdentity
  Write-Output "FLEET_ADMISSION|issue=$Issue|attempt=$Attempt|controllerHead=$controllerHead|candidateHead=$ClaimedHead|gate=$Gate"
  $verifierProcess.WaitForExit()
  $verifierExitCode = $verifierProcess.ExitCode
} catch {
  $message = $_.Exception.Message
  [Console]::Error.WriteLine($message)
  if ($message.StartsWith("ADMISSION_DENIED", [StringComparison]::Ordinal)) {
    $verifierExitCode = 73
  } elseif ($message.StartsWith("ADMISSION_RESIDUE", [StringComparison]::Ordinal)) {
    $verifierExitCode = 74
  } else {
    $verifierExitCode = 1
  }
} finally {
  if ($verifierProcess) { $verifierProcess.Dispose() }
  if ($fleetOwner) {
    if (-not (Exit-FleetExclusiveAdmission $fleetOwner)) {
      [Console]::Error.WriteLine("ADMISSION_RESIDUE: exact fleet lease release was not proven")
      $releaseFailed = $true
    }
  }
}

if ($releaseFailed) { exit 74 }
exit $verifierExitCode
