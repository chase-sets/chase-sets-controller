<#
.SYNOPSIS
Bootstraps or repairs the chase-sets container directory.

.DESCRIPTION
Idempotent. Run from any PowerShell prompt after cloning the container meta-repo
(or whenever the junctions are missing):
  1. Clones the chase-sets repo into main/ if it is not present.
  2. Recreates the .agents and .codex directory junctions into main/.
  3. Reports layout status.

Junctions (not symlinks) are used on purpose: they need no admin rights or
Developer Mode and look like real directories to every tool.

Worktrees are not created here — spawn them as needed:
  git -C main worktree add ../<name> <ref>
#>

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSCommandPath
$MainPath = Join-Path $Root "main"
$RepoUrl = "https://github.com/chase-sets/chase-sets.git"

if (-not (Test-Path -LiteralPath (Join-Path $MainPath ".git"))) {
  Write-Host "main/ missing - cloning $RepoUrl"
  git clone $RepoUrl $MainPath
  if ($LASTEXITCODE -ne 0) {
    throw "git clone failed."
  }
}

foreach ($junction in @(
  @{ Path = Join-Path $Root ".agents"; Target = Join-Path $MainPath ".agents" },
  @{ Path = Join-Path $Root ".codex"; Target = Join-Path $MainPath ".codex" }
)) {
  $item = Get-Item -LiteralPath $junction.Path -ErrorAction SilentlyContinue
  if ($item -and $item.LinkType -eq "Junction" -and $item.Target -eq $junction.Target) {
    continue
  }
  if ($item) {
    throw "'$($junction.Path)' exists but is not the expected junction to '$($junction.Target)'. Inspect and remove it manually, then re-run."
  }
  New-Item -ItemType Junction -Path $junction.Path -Target $junction.Target | Out-Null
  Write-Host "Created junction $($junction.Path) -> $($junction.Target)"
}

Write-Host "main: $(git -C $MainPath log --oneline -1 HEAD)"
git -C $MainPath worktree list
Write-Host "Container ready."
