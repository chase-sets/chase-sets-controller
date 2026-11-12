$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
Import-Module (Join-Path $root 'controller-install-lock.psm1') -Force -DisableNameChecking
$skillRoot = Join-Path $root 'controller-skills/milestone-orchestrator'
$bytes = [IO.File]::ReadAllBytes((Join-Path $skillRoot 'SKILL.md'))
$utf8 = [Text.UTF8Encoding]::new($false, $true)
$core = $utf8.GetString($bytes)
$script:checks = 0
function Assert-Pruned([bool]$Value, [string]$Message) {
  $script:checks++
  if (-not $Value) { throw "ASSERTION FAILED: $Message" }
}
function Test-Core([byte[]]$Bytes) {
  if ($Bytes.Length -gt 20000) { return $false }
  $text = $utf8.GetString($Bytes) -replace '\s+', ' '
  foreach ($needle in @(
    'Only committed outcomes enter the pull window',
    'Backfill next committed marker-order outcomes',
    'Every dispatch uses `.orchestrator/dispatch-lane.ps1`',
    'one focused non-author review per change',
    'PR, reviewed head, reviewer model, verdict and finding counts',
    'Live head must equal reviewed head',
    'later PASS supersedes older block',
    '`landing-preflight.ps1 -Action Apply`',
    'deployed digest/commit against actual deploy head',
    '`digest-publish.ps1`',
    '`lane-stall-watchdog-batch.ps1 -LanesPath',
    'never signal others',
    'The host decides non-Todd process questions directly',
    'production and money safety; secrets; Todd-only decisions',
    'Chase Sets never contacts TCGplayer servers or stores/uses TCGplayer credentials',
    'only limit owner may raise caps',
    'No-signal or stopped/malformed evidence is not success',
    'No PowerShell Jobs',
    'Controller never takes product lanes',
    'Load only a named-needed reference section, never all at start/ordinary dispatch'
  )) { if (-not $text.Contains($needle, [StringComparison]::OrdinalIgnoreCase)) { return $false } }
  return $true
}
Assert-Pruned (Test-Core $bytes) 'bounded core must retain executable workflow and hard gates'
Assert-Pruned (-not (Test-Core ($utf8.GetBytes($core + (' ' * 20000))))) 'oversized-core negative control'
foreach ($needle in @('Only committed outcomes', 'Live head must equal reviewed head',
    'later PASS supersedes older block', 'No PowerShell Jobs', 'production and money safety',
    'never signal others', 'Chase Sets never contacts TCGplayer servers')) {
  $mutated = $core.Replace($needle, 'MUTANT_REMOVED')
  Assert-Pruned ($mutated -cne $core -and -not (Test-Core ($utf8.GetBytes($mutated)))) "workflow/gate mutant: $needle"
}
$inventory = @(Get-ControllerSkillInstallInventory)
$milestone = @($inventory | Where-Object source -like 'milestone-orchestrator/*')
$references = @($milestone | Where-Object source -like '*/references/*')
Assert-Pruned ($references.Count -gt 0) 'focused operation references must ship'
foreach ($entry in $references) {
  $relative = $entry.source.Substring('milestone-orchestrator/'.Length)
  Assert-Pruned ($core.Contains($relative, [StringComparison]::Ordinal)) "reference has a named need: $relative"
  Assert-Pruned (Test-Path -LiteralPath (Join-Path $skillRoot $relative) -PathType Leaf) "reference exists: $relative"
}
foreach ($match in [regex]::Matches($core, '`(references/[^`]+\.md)`')) {
  Assert-Pruned ($milestone.source -contains ('milestone-orchestrator/' + $match.Groups[1].Value)) 'all core operational references install'
}
function Test-NoArchiveInstall($Entries) {
  return @($Entries | Where-Object {
    $_.source -match '(?i)\.bak(?:$|[./])|rule-provenance|defect-classes|stall-gotchas|/archive/' -or
    $_.destination -match '(?i)\.bak(?:$|[./])|rule-provenance|defect-classes|stall-gotchas|/archive/'
  }).Count -eq 0
}
Assert-Pruned (Test-NoArchiveInstall $inventory) 'historical catalogs/backups are not install inputs'
foreach ($path in @('milestone-orchestrator/references/defect-classes.md.bak',
    'milestone-orchestrator/references/rule-provenance-v2.24.md')) {
  Assert-Pruned (-not (Test-NoArchiveInstall ($inventory + [pscustomobject]@{source=$path;destination=$path}))) "inventory negative control: $path"
}
foreach ($name in @('rule-provenance-v2.24.md', 'controller-defect-classes.md')) {
  Assert-Pruned (Test-Path -LiteralPath (Join-Path $root "docs/archive/milestone-orchestrator/$name") -PathType Leaf) 'historical evidence preserved outside installed skill'
  Assert-Pruned (-not (Test-Path -LiteralPath (Join-Path $skillRoot "references/$name"))) 'history removed from discovered skill'
}
Assert-Pruned (-not ($core -match 'query-ledgers\.ps1|strictPrelogV1|PrepareRoute')) 'no automatic archaeology/prelog dispatch dependency'
Write-Output "PASS skill-pruning bytes=$($bytes.Length) limit=20000 references=$($references.Count) checks=$script:checks; no live dispatch or external actions"
