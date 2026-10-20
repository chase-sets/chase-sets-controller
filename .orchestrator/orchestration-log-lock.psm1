Set-StrictMode -Version Latest

# The installed product container keeps the machine-wide name, so its writers
# installed before and after the root-keyed rule never hold different names.
$script:OrchestrationLogContainerRoot = 'D:\Users\ToddS\Source\Repos\chase-sets\.orchestrator'.ToLowerInvariant()

function Get-OrchestrationLogMutexName {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Root)

  # Lexical, never a filesystem read: one name per canonical root, so a copied,
  # archived or temp runtime never shares a name with another root.
  $full = [IO.Path]::GetFullPath($Root)
  $pathRoot = [IO.Path]::GetPathRoot($full)
  $canonical = $full.TrimEnd('\', '/')
  if ($canonical.Length -lt $pathRoot.Length) { $canonical = $pathRoot }
  $canonical = $canonical.ToLowerInvariant()
  if ($canonical -ceq $script:OrchestrationLogContainerRoot) { return "Global\ChaseSetsOrchLog" }
  $digest = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($canonical))
  "Global\ChaseSetsOrchLog-" + [Convert]::ToHexString($digest).ToLowerInvariant()
}

function Invoke-WithOrchestrationLogLock {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][scriptblock]$Body,
    [timespan]$Timeout = ([timespan]::FromSeconds(30))
  )

  if ($Timeout -le [timespan]::Zero -or $Timeout -gt [timespan]::FromMinutes(5)) {
    throw "orchestration log lock refused: timeout is outside the closed bound"
  }
  $mutex = [Threading.Mutex]::new($false, (Get-OrchestrationLogMutexName -Root $Root))
  $owned = $false
  try {
    try { $owned = $mutex.WaitOne($Timeout) }
    catch [Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) { throw "orchestration log lock refused: exclusive writer lock timed out" }
    & $Body
  } finally {
    if ($owned) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
  }
}

function Open-OrchestrationLogAppendStream {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Path)

  # Retry only acquisition, never a body or write that may already have effects.
  # The caller retains the governed writer mutex throughout this bounded wait.
  $budgetMilliseconds = 30000
  $delayMilliseconds = 100
  $timer = [Diagnostics.Stopwatch]::StartNew()
  $lastSharingViolation = $null
  while ($true) {
    if ($lastSharingViolation -and $timer.ElapsedMilliseconds -ge $budgetMilliseconds) {
      $errorRecord = [Management.Automation.ErrorRecord]::new(
        [TimeoutException]::new('ORCHESTRATION_LOG_SHARING_RETRY_EXHAUSTED: ledger sharing violation persisted for 30 seconds', $lastSharingViolation),
        'ORCHESTRATION_LOG_SHARING_RETRY_EXHAUSTED', [Management.Automation.ErrorCategory]::ResourceBusy, $Path)
      $PSCmdlet.ThrowTerminatingError($errorRecord)
    }
    try {
      return [IO.File]::Open($Path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    } catch {
      $exception = $_.Exception
      while ($exception.InnerException) { $exception = $exception.InnerException }
      $sharingViolation = $exception -is [IO.IOException] -and $exception.HResult -eq -2147024864 # HRESULT_FROM_WIN32(ERROR_SHARING_VIOLATION=32)
      if (-not $sharingViolation) { throw }
      $lastSharingViolation = $exception
      $remaining = $budgetMilliseconds - $timer.ElapsedMilliseconds
      if ($remaining -gt 0) {
        [Threading.Thread]::Sleep([int][math]::Min($delayMilliseconds, $remaining))
        $delayMilliseconds = [math]::Min(1000, $delayMilliseconds * 2)
      }
    }
  }
}

Export-ModuleMember -Function @(
  "Get-OrchestrationLogMutexName",
  "Invoke-WithOrchestrationLogLock",
  "Open-OrchestrationLogAppendStream"
)
