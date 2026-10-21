# The cross-loop contract is stated once, in orchestrator-shared. Each section's
# anchor sentence must be there and in neither loop skill nor the controller's
# platform-supervision reference; copying one back into any of them must fail.
$ErrorActionPreference = "Stop"
$skills = Join-Path $PSScriptRoot "controller-skills"
$strictUtf8 = [Text.UTF8Encoding]::new($false, $true)
$script:assertions = 0
$script:mutants = 0

function Read-Skill([string]$Name, [string]$File = "SKILL.md") { $strictUtf8.GetString([IO.File]::ReadAllBytes((Join-Path $skills "$Name/$File"))) }
function Compact-Text([string]$Text) { ($Text -replace "\s+", " ").Trim() }
function Assert-Shared([bool]$Condition, [string]$Message) {
  $script:assertions += 1
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

# Name, section heading, anchor sentence. A section may carry several anchors.
$anchors = @(
  [pscustomobject]@{ Key = 'Two loops'; Section = 'Two loops'; Value = 'It never cuts batches, runs controller batteries or precursors, dispatches controller reviews, or holds product lanes for controller work.' }
  [pscustomobject]@{ Key = 'Repository routing'; Section = 'Repository routing'; Value = 'Follow Repository routing in `main/docs/contributing/backlog-model.md`; work for the other loop is filed on the other loop''s repository.' }
  [pscustomobject]@{ Key = 'Releases'; Section = 'Releases'; Value = 'Release tags are the only install authority: never install an untagged commit or by any other path' }
  [pscustomobject]@{ Key = 'Releases-no-wait'; Section = 'Releases'; Value = 'The controller loop never waits for a product install: it keeps building and releasing, and tags may accumulate. The product loop installs only the newest tag' }
  [pscustomobject]@{ Key = 'Defects'; Section = 'Defects'; Value = 'The product loop files a controller defect as an issue on `chase-sets/chase-sets-controller` and continues product work.' }
  [pscustomobject]@{ Key = 'Platform handoff'; Section = 'Platform handoff'; Value = 'Labels and markers are the only transport between the product and platform loops; milestones play no part.' }
  [pscustomobject]@{ Key = 'Platform handoff-return'; Section = 'Platform handoff'; Value = 'The product loop owns the issue again only when neither label is present and a release marker is newer than its take-back.' }
)

function Test-StatedOnce([string]$Shared, [string]$Milestone, [string]$Controller, [string]$Supervision) {
  foreach ($entry in $anchors) {
    $section = [regex]::Match($Shared, "(?ms)^## $([regex]::Escape($entry.Section))\r?\n(.*?)(?=^## |\z)")
    Assert-Shared $section.Success "orchestrator-shared has section $($entry.Key)"
    Assert-Shared ((Compact-Text $section.Groups[1].Value).Contains($entry.Value, [StringComparison]::Ordinal)) "orchestrator-shared $($entry.Key) states its anchor"
    foreach ($loop in @(@('milestone-orchestrator', $Milestone), @('controller-orchestrator', $Controller), @('platform-supervision', $Supervision))) {
      Assert-Shared (-not (Compact-Text $loop[1]).Contains($entry.Value, [StringComparison]::Ordinal)) "$($loop[0]) restates orchestrator-shared $($entry.Key)"
    }
  }
  $frontmatter = [regex]::Match($Shared, '(?s)\A---\r?\n(.*?)\r?\n---\r?\n')
  Assert-Shared ($frontmatter.Success -and $frontmatter.Groups[1].Value -match '(?m)^name: orchestrator-shared\r?$') 'orchestrator-shared frontmatter names the skill'
  Assert-Shared ($Shared -notmatch '#\d|\b\d{4}-\d{2}-\d{2}\b|\bv\d+\.\d+|\bgpt-|\bclaude-|\b[0-9a-f]{8}-[0-9a-f]{4}-') 'orchestrator-shared carries no issue numbers, dates, versions, model names or thread ids'
}

function Assert-SharedMutant([string]$Name, [scriptblock]$Probe) {
  $script:mutants += 1
  $failure = $null
  try { & $Probe | Out-Null } catch { $failure = $_.Exception.Message }
  if ($null -eq $failure) { throw "MUTANT SURVIVED: $Name" }
  if (-not $failure.StartsWith("ASSERTION FAILED:", [StringComparison]::Ordinal)) { throw "MUTANT PROBE BROKEN: $($Name): $failure" }
}

$shared = Read-Skill 'orchestrator-shared'
$milestone = Read-Skill 'milestone-orchestrator'
$controller = Read-Skill 'controller-orchestrator'
$supervision = Read-Skill 'controller-orchestrator' 'references/platform-supervision.md'
Test-StatedOnce $shared $milestone $controller $supervision
foreach ($entry in $anchors) {
  $anchor = $entry.Value
  Assert-SharedMutant "copy-back-milestone-$($entry.Key)" { Test-StatedOnce $shared ($milestone + "`r`n" + $anchor + "`r`n") $controller $supervision }
  Assert-SharedMutant "copy-back-controller-$($entry.Key)" { Test-StatedOnce $shared $milestone ($controller + "`r`n" + $anchor + "`r`n") $supervision }
  Assert-SharedMutant "copy-back-supervision-$($entry.Key)" { Test-StatedOnce $shared $milestone $controller ($supervision + "`r`n" + $anchor + "`r`n") }
  Assert-SharedMutant "shared-drops-$($entry.Key)" { Test-StatedOnce ([regex]::Replace($shared, ((@($anchor -split ' ') | ForEach-Object { [regex]::Escape($_) }) -join '\s+'), 'removed text.')) $milestone $controller $supervision }
}
Assert-SharedMutant 'shared-dated' { Test-StatedOnce ($shared + "`r`nUpdated 2026-10-18.`r`n") $milestone $controller $supervision }
Assert-SharedMutant 'shared-platform-handoff-issue-number' { Test-StatedOnce ($shared.Replace('The merge queue is no exception.', 'The merge queue is no exception (#192).')) $milestone $controller $supervision }
Write-Output "PASS orchestrator-shared stated-once anchors=$($anchors.Count) assertions=$($script:assertions) mutants=$($script:mutants) survivors=0"
