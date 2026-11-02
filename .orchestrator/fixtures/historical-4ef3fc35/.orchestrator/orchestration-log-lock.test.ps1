$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "orchestration-log-lock.psm1") -Force -DisableNameChecking

if ((Get-OrchestrationLogMutexName) -cne "Global\ChaseSetsOrchLog") {
  throw "ASSERTION FAILED: governed log mutex name moved"
}
$trace = [Collections.Generic.List[string]]::new()
$value = Invoke-WithOrchestrationLogLock -Body { $trace.Add("inside"); "held" }
if ($value -cne "held" -or $trace.Count -ne 1 -or $trace[0] -cne "inside") {
  throw "ASSERTION FAILED: governed log lock did not execute exactly once"
}
foreach ($writer in @("log-event.ps1", "cost-harvest.ps1")) {
  $text = Get-Content -LiteralPath (Join-Path $PSScriptRoot $writer) -Raw
  if (-not $text.Contains("orchestration-log-lock.psm1", [StringComparison]::Ordinal) -or
      -not $text.Contains("Invoke-WithOrchestrationLogLock", [StringComparison]::Ordinal) -or
      $text.Contains('New-Object System.Threading.Mutex($false, "Global\ChaseSetsOrchLog")', [StringComparison]::Ordinal)) {
    throw "ASSERTION FAILED: $writer does not use the governed log lock"
  }
}
Write-Output "PASS orchestration log lock tests writers=2 order-root=log"
