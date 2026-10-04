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

Export-ModuleMember -Function @(
  "Get-OrchestrationLogMutexName",
  "Invoke-WithOrchestrationLogLock"
)
