<# 
.SYNOPSIS
Updates the main worktree from origin/main while preserving the optional write lock.

.DESCRIPTION
Run this from any PowerShell prompt. The script lives beside the main worktree so
agents can still use it after the main worktree is locked.

Default behavior:
  1. Detect whether main is currently write-locked by this script.
  2. Temporarily remove that lock if present.
  3. Fetch/prune origin.
  4. Force-switch D:\...\chase-sets\main back to the main branch, discarding any
     local modifications that would block the switch.
  5. Hard reset it to refs/remotes/origin/main and remove untracked files.
  6. Reapply the lock if it was already locked, or if -LockAfter is passed.

main is a read-only reference worktree and must never carry working changes, so
any local edits or untracked files found there are discarded unconditionally.

The lock intentionally leaves main\.git writable. Git needs that shared metadata
directory to create, register, and remove sibling worktrees.

Examples:
  .\UPDATE_MAIN_FROM_ORIGIN.ps1
  .\UPDATE_MAIN_FROM_ORIGIN.ps1 -LockAfter
  .\UPDATE_MAIN_FROM_ORIGIN.ps1 -Status
  .\UPDATE_MAIN_FROM_ORIGIN.ps1 -UnlockOnly
#>

[CmdletBinding(DefaultParameterSetName = "Sync")]
param(
  [Parameter(ParameterSetName = "Sync")]
  [switch]$LockAfter,

  [Parameter(ParameterSetName = "Status")]
  [switch]$Status,

  [Parameter(ParameterSetName = "Lock")]
  [switch]$LockOnly,

  [Parameter(ParameterSetName = "Unlock")]
  [switch]$UnlockOnly
)

$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $PSCommandPath
$MainPath = Join-Path $ProjectRoot "main"
$LockMarkerPath = Join-Path $ProjectRoot ".main-worktree-write-lock.json"
$LegacyLockMarkerPath = Join-Path $ProjectRoot ".main-directory-write-lock.json"
$ChildLockRights = [System.Security.AccessControl.FileSystemRights]::Write `
  -bor [System.Security.AccessControl.FileSystemRights]::Delete `
  -bor [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles
$RootLockRights = $ChildLockRights
$LegacyLockRights = $ChildLockRights
$GitMetadataAllowRights = [System.Security.AccessControl.FileSystemRights]::Modify
$NoInheritanceFlags = [System.Security.AccessControl.InheritanceFlags]::None
$InheritanceFlags = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit `
  -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
$PropagationFlags = [System.Security.AccessControl.PropagationFlags]::None
$AccessControlType = [System.Security.AccessControl.AccessControlType]::Deny
$AllowAccessControlType = [System.Security.AccessControl.AccessControlType]::Allow
$CurrentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$GitMetadataDirectoryName = ".git"

function Assert-MainWorktree {
  if (-not (Test-Path -LiteralPath $MainPath -PathType Container)) {
    throw "Expected main worktree at '$MainPath'."
  }

  git -C $MainPath rev-parse --is-inside-work-tree *> $null
  if ($LASTEXITCODE -ne 0) {
    throw "'$MainPath' is not a Git worktree."
  }
}

function New-LockRule {
  param(
    [Parameter(Mandatory = $true)]
    [System.Security.AccessControl.FileSystemRights]$Rights,

    [Parameter(Mandatory = $true)]
    [System.Security.AccessControl.InheritanceFlags]$RuleInheritanceFlags
  )

  New-Object System.Security.AccessControl.FileSystemAccessRule(
    $CurrentIdentity,
    $Rights,
    $RuleInheritanceFlags,
    $PropagationFlags,
    $AccessControlType
  )
}

function New-GitMetadataAllowRule {
  New-Object System.Security.AccessControl.FileSystemAccessRule(
    $CurrentIdentity,
    $GitMetadataAllowRights,
    $InheritanceFlags,
    $PropagationFlags,
    $AllowAccessControlType
  )
}

function Test-ScriptDenyRule {
  param(
    [Parameter(Mandatory = $true)]
    [System.Security.AccessControl.FileSystemAccessRule]$Rule
  )

  if ($Rule.IdentityReference.Value -ne $CurrentIdentity) {
    return $false
  }

  if ($Rule.AccessControlType -ne $AccessControlType) {
    return $false
  }

  $scriptRights = $RootLockRights -bor $ChildLockRights -bor $LegacyLockRights
  return (($Rule.FileSystemRights -band $scriptRights) -ne 0)
}

function Remove-ScriptDenyRules {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    return
  }

  $acl = Get-Acl -LiteralPath $Path
  $changed = $false

  foreach ($rule in @($acl.Access)) {
    if (Test-ScriptDenyRule -Rule $rule) {
      [void]$acl.RemoveAccessRuleSpecific($rule)
      $changed = $true
    }
  }

  if ($changed) {
    Set-Acl -LiteralPath $Path -AclObject $acl
  }
}

function Remove-GitMetadataAllowRule {
  $gitMetadataPath = Join-Path $MainPath $GitMetadataDirectoryName
  if (-not (Test-Path -LiteralPath $gitMetadataPath -PathType Container)) {
    return
  }

  $acl = Get-Acl -LiteralPath $gitMetadataPath
  $rule = New-GitMetadataAllowRule
  [void]$acl.RemoveAccessRuleSpecific($rule)
  Set-Acl -LiteralPath $gitMetadataPath -AclObject $acl
}

function Test-MainWriteLock {
  if (-not (Test-Path -LiteralPath $MainPath -PathType Container)) {
    return $false
  }

  $acl = Get-Acl -LiteralPath $MainPath
  foreach ($rule in $acl.Access) {
    if (Test-ScriptDenyRule -Rule $rule) {
      return $true
    }
  }

  return (Test-Path -LiteralPath $LockMarkerPath) -or (Test-Path -LiteralPath $LegacyLockMarkerPath)
}

function Lock-MainWorktree {
  Assert-MainWorktree

  # Rebuild the lock every time so legacy whole-directory locks are converted to
  # the metadata-friendly shape that still permits git worktree operations.
  Unlock-MainWorktree -Quiet

  $gitMetadataPath = Join-Path $MainPath $GitMetadataDirectoryName
  if (Test-Path -LiteralPath $gitMetadataPath -PathType Container) {
    $gitAcl = Get-Acl -LiteralPath $gitMetadataPath
    $gitAcl.AddAccessRule((New-GitMetadataAllowRule))
    Set-Acl -LiteralPath $gitMetadataPath -AclObject $gitAcl
  }

  $acl = Get-Acl -LiteralPath $MainPath
  $acl.AddAccessRule((New-LockRule -Rights $RootLockRights -RuleInheritanceFlags $InheritanceFlags))
  Set-Acl -LiteralPath $MainPath -AclObject $acl

  [pscustomobject]@{
    lockedAt = (Get-Date).ToString("o")
    identity = $CurrentIdentity
    mainPath = $MainPath
    gitMetadataPath = Join-Path $MainPath $GitMetadataDirectoryName
    note = "Working tree is write-locked, but .git is writable so git worktree add can still work. Use UPDATE_MAIN_FROM_ORIGIN.ps1 to sync main."
  } | ConvertTo-Json | Set-Content -LiteralPath $LockMarkerPath -Encoding UTF8

  if (Test-Path -LiteralPath $LegacyLockMarkerPath) {
    Remove-Item -LiteralPath $LegacyLockMarkerPath -Force
  }

  Write-Host "Locked main working tree against accidental writes for $CurrentIdentity. Git metadata remains writable."
}

function Unlock-MainWorktree {
  param(
    [switch]$Quiet
  )

  if (-not (Test-Path -LiteralPath $MainPath -PathType Container)) {
    return
  }

  Remove-ScriptDenyRules -Path $MainPath

  foreach ($child in Get-ChildItem -Force -LiteralPath $MainPath) {
    Remove-ScriptDenyRules -Path $child.FullName
  }

  Remove-GitMetadataAllowRule

  foreach ($marker in @($LockMarkerPath, $LegacyLockMarkerPath)) {
    if (Test-Path -LiteralPath $marker) {
      Remove-Item -LiteralPath $marker -Force
    }
  }

  if (-not $Quiet) {
    Write-Host "Unlocked main working tree for $CurrentIdentity."
  }
}

function Show-Status {
  Assert-MainWorktree

  $isLocked = Test-MainWriteLock
  Write-Host "main path: $MainPath"
  Write-Host "write lock: $isLocked"
  git -C $MainPath status --short --branch
  git -C $MainPath log --oneline -1 HEAD
}

function Sync-MainWorktree {
  Assert-MainWorktree

  $wasLocked = Test-MainWriteLock
  if ($wasLocked) {
    Unlock-MainWorktree
  }

  try {
    git -C $MainPath fetch --prune origin
    if ($LASTEXITCODE -ne 0) {
      throw "git fetch --prune origin failed."
    }

    git -C $MainPath switch --force main
    if ($LASTEXITCODE -ne 0) {
      throw "git switch --force main failed. Another worktree may have main checked out."
    }

    git -C $MainPath reset --hard refs/remotes/origin/main
    if ($LASTEXITCODE -ne 0) {
      throw "git reset --hard refs/remotes/origin/main failed."
    }

    git -C $MainPath clean -fd
    if ($LASTEXITCODE -ne 0) {
      throw "git clean -fd failed."
    }

    # main is a dependency-free read-only reference, but `clean -fd` skips
    # ignored files, so installs/logs/artifacts left behind by tooling persist
    # across syncs (stale node_modules, .codex-logs, orphaned workspace dirs
    # whose only contents are ignored files). Sweep all ignored/untracked
    # clutter; .env.*.local files are deliberately preserved.
    git -C $MainPath clean -fdx -e ".env.*.local"
    if ($LASTEXITCODE -ne 0) {
      throw "git clean -fdx (ignored clutter sweep) failed."
    }

    git -C $MainPath status --short --branch
    git -C $MainPath log --oneline -1 HEAD
  }
  finally {
    if ($wasLocked -or $LockAfter) {
      Lock-MainWorktree
    }
  }
}

Assert-MainWorktree

if ($Status) {
  Show-Status
}
elseif ($LockOnly) {
  Lock-MainWorktree
}
elseif ($UnlockOnly) {
  Unlock-MainWorktree
}
else {
  Sync-MainWorktree
}
