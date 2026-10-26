<#
.SYNOPSIS
Fail when installed static controller-skill files differ from canonical source.

.DESCRIPTION
Also reports the installed controller release (from the release record the
tag installer writes), the container checkout head, and the newest
controller-v* tag on the release repository. A newer tag is reported as
updateAvailable; it never changes the exit code. A failed remote read is
reported as remoteError and never fails the check.
#>
[CmdletBinding()]
param(
  [string]$SourceRoot = (Join-Path $PSScriptRoot "controller-skills"),
  [string]$DestinationRoot = (Join-Path $HOME ".claude/skills"),
  [string]$ContainerRoot = (Split-Path -Parent $PSScriptRoot),
  [string]$ReleaseRepository = 'https://github.com/chase-sets/chase-sets-controller.git',
  [switch]$SkipRemote,
  [switch]$Json
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "controller-install-lock.psm1") -Force -DisableNameChecking
$files = @(Get-ControllerSkillInstallInventory | Where-Object { $_.transportText })

function Get-NormalizedSkillHash([string]$Path, [bool]$TransportText) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  $bytes = Get-ControllerTransportNormalizedBytes -Bytes ([IO.File]::ReadAllBytes($Path)) -TransportText $TransportText
  ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))).ToUpperInvariant()
}

$observations = foreach ($item in $files) {
  $relative = [string]$item.destination
  $source = Join-Path $SourceRoot $relative
  $destination = Join-Path $DestinationRoot $relative
  $sourceExists = Test-Path -LiteralPath $source -PathType Leaf
  $destinationExists = Test-Path -LiteralPath $destination -PathType Leaf
  $sourceHash = Get-NormalizedSkillHash $source ([bool]$item.transportText)
  $destinationHash = Get-NormalizedSkillHash $destination ([bool]$item.transportText)
  [pscustomobject]@{
    relative = $relative
    sourceExists = $sourceExists
    destinationExists = $destinationExists
    match = ($sourceExists -and $destinationExists -and $sourceHash -eq $destinationHash)
    sourceHash = $sourceHash
    destinationHash = $destinationHash
  }
}

$mismatches = @($observations | Where-Object { -not $_.match })
$markerPath = Join-Path ([IO.Path]::GetFullPath($ContainerRoot)) ".orchestrator/controller-review-strict-v1-capability.json"
$marker = [ordered]@{ path = $markerPath; state = "absent-pre-strict"; sha256 = $null }
if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
  try {
    $bytes = [IO.File]::ReadAllBytes($markerPath)
    if ($bytes.Length -lt 3 -or $bytes[0] -eq 0xEF -or $bytes[-1] -ne 0x0A -or ($bytes.Length -gt 1 -and $bytes[-2] -eq 0x0D)) { throw "marker bytes invalid" }
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    $value = $text | ConvertFrom-Json -DateKind String -ErrorAction Stop
    $required = @("schemaVersion","authorityMode","issue","priorControllerHead","controllerHead","dispatchReductionSha256")
    foreach ($name in $required) { if (-not $value.PSObject.Properties[$name]) { throw "marker shape invalid" } }
    if ($value.schemaVersion -cne "controller-review-strict-v1-capability/v1" -or $value.authorityMode -cne "strict-v1" -or
        [int]$value.issue -lt 1 -or [string]$value.priorControllerHead -cnotmatch '^[a-f0-9]{40}$' -or
        [string]$value.controllerHead -cnotmatch '^[a-f0-9]{40}$' -or
        [string]$value.dispatchReductionSha256 -cnotmatch '^[a-f0-9]{64}$') { throw "marker schema invalid" }
    $marker.state = "strict-v1"
    $marker.sha256 = ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))).ToLowerInvariant()
  } catch {
    $marker.state = "indeterminate"
    $mismatches += [pscustomobject]@{ relative = ".orchestrator/controller-review-strict-v1-capability.json"; sourceExists = $true; destinationExists = $true; match = $false; sourceHash = $null; destinationHash = $null }
  }
}
function Get-ReleaseVersion([string]$Tag) {
  $match = [regex]::Match($Tag, '^controller-v(\d+)\.(\d+)(?:\.(\d+))?$')
  if (-not $match.Success) { return $null }
  $patch = if ($match.Groups[3].Success) { [int]$match.Groups[3].Value } else { 0 }
  [version]::new([int]$match.Groups[1].Value, [int]$match.Groups[2].Value, $patch)
}

$release = [ordered]@{ installed = $null; installedCommit = $null; containerHead = $null; newest = $null; updateAvailable = $false; remoteError = $null }
$releaseRecord = Join-Path $DestinationRoot "native-db/release.json"
if (Test-Path -LiteralPath $releaseRecord -PathType Leaf) {
  try {
    $record = Get-Content -LiteralPath $releaseRecord -Raw | ConvertFrom-Json -DateKind String -ErrorAction Stop
    if ($record.schemaVersion -ceq "controller-release/v1" -and (Get-ReleaseVersion ([string]$record.tag))) {
      $release.installed = [string]$record.tag
      $release.installedCommit = [string]$record.commit
    }
  } catch {}
}
$containerHead = @(& git -C $ContainerRoot rev-parse HEAD 2>$null)
if ($LASTEXITCODE -eq 0 -and $containerHead.Count -eq 1) { $release.containerHead = ([string]$containerHead[0]).Trim() }
if (-not $SkipRemote) {
  $remoteTags = @(& git ls-remote --tags --refs $ReleaseRepository "refs/tags/controller-v*" 2>$null)
  if ($LASTEXITCODE -ne 0) {
    $release.remoteError = "ls-remote failed for $ReleaseRepository"
  } else {
    $newest = $remoteTags | ForEach-Object { ([string]$_ -split "`t")[-1] -replace '^refs/tags/', '' } |
      Where-Object { Get-ReleaseVersion $_ } | Sort-Object { Get-ReleaseVersion $_ } | Select-Object -Last 1
    if ($newest) {
      $release.newest = [string]$newest
      $installedVersion = if ($release.installed) { Get-ReleaseVersion $release.installed } else { $null }
      $release.updateAvailable = ($null -eq $installedVersion) -or ((Get-ReleaseVersion $newest) -gt $installedVersion)
    }
  }
}

$result = [ordered]@{
  schemaVersion = "controller-skill-freshness/v1"
  status = if ($mismatches.Count -eq 0) { "current" } else { "stale" }
  checked = $observations.Count
  mismatches = $mismatches
  marker = $marker
  release = $release
}

if ($Json) {
  $result | ConvertTo-Json -Depth 6
} else {
  Write-Output "Controller skill freshness: $($result.status) ($($result.checked) static files checked)"
  $installedText = if ($release.installed) { $release.installed } else { "none recorded" }
  $newestText = if ($release.newest) { $release.newest } elseif ($release.remoteError) { "unknown ($($release.remoteError))" } else { "not checked" }
  $updateText = if ($release.updateAvailable) { "; update available" } else { "" }
  Write-Output "Controller release: installed $installedText; newest $($newestText)$updateText"
  foreach ($mismatch in $mismatches) {
    Write-Output "MISMATCH $($mismatch.relative)"
  }
}

if ($mismatches.Count -gt 0) { exit 2 }
