Set-StrictMode -Version Latest

function Get-OrchestrationLogMutexName {
  [CmdletBinding()]
  param()
  "Global\ChaseSetsOrchLog"
}

function Invoke-WithOrchestrationLogLock {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][scriptblock]$Body,
    [timespan]$Timeout = ([timespan]::FromSeconds(30))
  )

  if ($Timeout -le [timespan]::Zero -or $Timeout -gt [timespan]::FromMinutes(5)) {
    throw "orchestration log lock refused: timeout is outside the closed bound"
  }
  $mutex = [Threading.Mutex]::new($false, (Get-OrchestrationLogMutexName))
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
