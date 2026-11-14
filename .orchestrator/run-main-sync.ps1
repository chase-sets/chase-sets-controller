<#
.SYNOPSIS
Worker launched headlessly by run-main-sync.vbs from the
"ChaseSets Main Worktree Sync" scheduled task.
Runs UPDATE_MAIN_FROM_ORIGIN.ps1 and appends timestamped output to a log file.
#>

[CmdletBinding()]
param(
  [Parameter(DontShow)][string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
  [Parameter(DontShow)][string]$MutexName = 'Global\ChaseSetsMainSync'
)

$ErrorActionPreference = 'Stop'
$ScriptPath = Join-Path $ProjectRoot "UPDATE_MAIN_FROM_ORIGIN.ps1"
$LogPath = Join-Path $ProjectRoot '.orchestrator/main-sync.log'
$StatusPath = Join-Path $ProjectRoot '.orchestrator/main-sync-status.json'
$MainPath = Join-Path $ProjectRoot 'main'
$Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

function Write-SyncStatus([string]$Outcome, [string]$ErrorText) {
  $lastSuccess = $null
  if (Test-Path -LiteralPath $StatusPath) {
    try { $lastSuccess = (Get-Content -LiteralPath $StatusPath -Raw | ConvertFrom-Json).lastSuccessAt } catch {}
  }
  $now = [DateTime]::UtcNow.ToString('o')
  if ($Outcome -eq 'success') { $lastSuccess = $now }
  $record = [ordered]@{ checkedAt=$now; outcome=$Outcome; lastSuccessAt=$lastSuccess; lastError=$ErrorText }
  [IO.File]::WriteAllText($StatusPath, ($record | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
}

function Get-IndexLockSkipReason {
  $path = @(& git.exe -C $MainPath rev-parse --path-format=absolute --git-path index.lock 2>&1)
  if ($LASTEXITCODE -ne 0 -or $path.Count -ne 1) { throw 'Cannot resolve main Git index lock.' }
  $lockPath = [string]$path[0]
  if (-not (Test-Path -LiteralPath $lockPath)) { return $null }
  $lockFile = Get-Item -LiteralPath $lockPath -Force
  $newest = $lockFile.LastWriteTimeUtc
  if ($lockFile.CreationTimeUtc -gt $newest) { $newest = $lockFile.CreationTimeUtc }
  if ($newest -gt [DateTime]::UtcNow.AddMinutes(-10)) { return 'main index lock is less than ten minutes old' }
  # Windows process inventory does not expose cwd. Any git process therefore
  # defers recovery rather than guessing that it belongs to another checkout.
  $gitProcesses = @(Get-CimInstance Win32_Process -Filter "Name='git.exe'" -ErrorAction Stop)
  if ($gitProcesses.Count) { return 'git process is running; index lock ownership is unknown' }
  $handle = $null
  try {
    try { $handle = [IO.File]::Open($lockPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Delete) }
    catch [IO.IOException] { return 'main index lock is in use' }
    Remove-Item -LiteralPath $lockPath -Force
    Add-Content -LiteralPath $LogPath -Encoding utf8 -Value 'removed stale main index lock (older than ten minutes, no git process, exclusive write access)'
  } finally { if ($handle) { $handle.Dispose() } }
  return $null
}

# main stays unlocked between runs now, so each sync is normally a few seconds,
# but guard with a named mutex anyway (e.g. a slow fetch, or a manual -LockAfter
# run) to keep overlapping runs from racing on the same git state and
# interleaving writes into this log file.
$mutex = New-Object System.Threading.Mutex($false, $MutexName)
if (-not $mutex.WaitOne(0)) {
  Add-Content -LiteralPath $LogPath -Encoding utf8 -Value "=== $Timestamp === skipped: previous sync still running"
  $mutex.Dispose()
  exit 0
}

$exitCode = 1
try {
  Add-Content -LiteralPath $LogPath -Encoding utf8 -Value "=== $Timestamp ==="
  $skipReason = Get-IndexLockSkipReason
  if ($skipReason) {
    Add-Content -LiteralPath $LogPath -Encoding utf8 -Value "skipped: $skipReason"
    Write-SyncStatus 'skipped' $skipReason
    exit 0
  }

  # Redirect via cmd.exe rather than PowerShell's *>> operator: PowerShell wraps a
  # redirected native command's stderr lines as ErrorRecords, and the target script
  # sets $ErrorActionPreference = "Stop", so routine git stderr chatter (e.g.
  # "Already on 'main'") would abort the sync before it reaches `git reset --hard`.
  $cmdLine = "/c powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" >> `"$LogPath`" 2>&1"
  $child = Start-Process -FilePath "cmd.exe" -ArgumentList $cmdLine -WindowStyle Hidden -Wait -PassThru
  try { $exitCode = $child.ExitCode } finally { $child.Dispose() }
  if ($exitCode -eq 0) { Write-SyncStatus 'success' $null }
  else { Write-SyncStatus 'failed' "UPDATE_MAIN_FROM_ORIGIN.ps1 exited with code $exitCode; see main-sync.log" }
}
catch {
  Add-Content -LiteralPath $LogPath -Encoding utf8 -Value "failed: $($_.Exception.Message)"
  Write-SyncStatus 'failed' $_.Exception.Message
  $exitCode = 1
}
finally {
  $mutex.ReleaseMutex()
  $mutex.Dispose()
}
exit $exitCode
