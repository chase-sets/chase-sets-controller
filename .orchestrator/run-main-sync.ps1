<#
.SYNOPSIS
Worker launched headlessly by run-main-sync.vbs from the
"ChaseSets Main Worktree Sync" scheduled task.
Runs UPDATE_MAIN_FROM_ORIGIN.ps1 and appends timestamped output to a log file.
#>

$ScriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) "UPDATE_MAIN_FROM_ORIGIN.ps1"
$LogPath = Join-Path $PSScriptRoot "main-sync.log"
$Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

# main stays unlocked between runs now, so each sync is normally a few seconds,
# but guard with a named mutex anyway (e.g. a slow fetch, or a manual -LockAfter
# run) to keep overlapping runs from racing on the same git state and
# interleaving writes into this log file.
$mutex = New-Object System.Threading.Mutex($false, "Global\ChaseSetsMainSync")
if (-not $mutex.WaitOne(0)) {
  Add-Content -LiteralPath $LogPath -Encoding utf8 -Value "=== $Timestamp === skipped: previous sync still running"
  exit 0
}

try {
  Add-Content -LiteralPath $LogPath -Encoding utf8 -Value "=== $Timestamp ==="

  # Redirect via cmd.exe rather than PowerShell's *>> operator: PowerShell wraps a
  # redirected native command's stderr lines as ErrorRecords, and the target script
  # sets $ErrorActionPreference = "Stop", so routine git stderr chatter (e.g.
  # "Already on 'main'") would abort the sync before it reaches `git reset --hard`.
  $cmdLine = "/c powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" >> `"$LogPath`" 2>&1"
  Start-Process -FilePath "cmd.exe" -ArgumentList $cmdLine -NoNewWindow -Wait
}
finally {
  $mutex.ReleaseMutex()
}
