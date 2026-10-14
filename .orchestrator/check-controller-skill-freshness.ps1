<#
.SYNOPSIS
Fail when installed static controller-skill files differ from canonical source.
#>
[CmdletBinding()]
param(
  [string]$SourceRoot = (Join-Path $PSScriptRoot "controller-skills"),
  [string]$DestinationRoot = (Join-Path $HOME ".claude/skills"),
  [string]$ContainerRoot = (Split-Path -Parent $PSScriptRoot),
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
$result = [ordered]@{
  schemaVersion = "controller-skill-freshness/v1"
  status = if ($mismatches.Count -eq 0) { "current" } else { "stale" }
  checked = $observations.Count
  mismatches = $mismatches
  marker = $marker
}

if ($Json) {
  $result | ConvertTo-Json -Depth 6
} else {
  Write-Output "Controller skill freshness: $($result.status) ($($result.checked) static files checked)"
  foreach ($mismatch in $mismatches) {
    Write-Output "MISMATCH $($mismatch.relative)"
  }
}

if ($mismatches.Count -gt 0) { exit 2 }
