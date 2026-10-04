[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
[Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal'
. (Join-Path $PSScriptRoot 'board-reconcile.test.ps1') -FunctionsOnly
$root = Join-Path ([IO.Path]::GetTempPath()) ('board-index-refusal-' + [guid]::NewGuid().ToString('N'))
function Invoke-RefusalCase([string]$Path, [string]$Case, [string]$Arm) {
  $initialStatus = if ($Case -in @('spec-race','ledger-append')) { 'In review' } else { 'In lane' }
  $f = New-BoardFixture (Join-Path $root "$Path-$Case-$Arm") @((New-BoardItem 908548 $initialStatus))
  $runtime = Join-Path $f.root 'runtime'; [void][IO.Directory]::CreateDirectory($runtime)
  $source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'board-reconcile.ps1'))
  if ($Arm -eq 'missing-history-error') {
    $source = $source.Replace('foreach ($errorText in $History.errors)', 'foreach ($errorText in @())')
  }
  if ($Arm -eq 'stale-observation') {
    $source = $source.Replace('function Test-BoardObservationUnchanged($Before, $After) {', 'function Test-BoardObservationUnchanged($Before, $After) { return $true')
  }
  [IO.File]::WriteAllText((Join-Path $runtime 'board-reconcile.ps1'), $source)
  foreach ($file in @('board-set.ps1','dispatch-ownership.ps1')) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $runtime }
  $logger = (Join-Path $PSScriptRoot 'log-event.ps1').Replace("'", "''")
  [IO.File]::WriteAllText((Join-Path $runtime 'log-event.ps1'), "& '$logger' @args")
  if ($Case -eq 'history-error') { [IO.File]::WriteAllText($f.log, "`n{broken`n") }
  else {
    $race = @{ atRead = $(if ($Path -eq 'event' -or $Case -eq 'writer-race') { 2 } else { 1 }); status = 'In review' }
    if ($Case -eq 'replacement') { $race.Remove('status'); $race.replaceLog = '{broken' }
    if ($Case -eq 'issue-race') { $race.Remove('status'); $race.state = 'CLOSED' }
    if ($Case -in @('spec-race','ledger-append')) {
      $race.Remove('status')
      $attempt = Add-BoardAttempt $f 908548 'changing-owner'
      if ($Case -eq 'spec-race') { $attempt.spec.state = 'exited'; $race.spec = $attempt.spec }
      else { $attempt.row.kind = 'lane-complete'; $race.row = $attempt.row }
    }
    [IO.File]::WriteAllText($f.race, ($race | ConvertTo-Json -Compress))
  }
  if ($Path -eq 'event') {
    $r = & (Join-Path $runtime 'board-set.ps1') -Issue 908548 -EventKind lane-complete -LaneRole implementation -DispatchLog $f.log -GhCommand $f.gh -Strict | ConvertFrom-Json
  } else {
    $r = & (Join-Path $runtime 'board-reconcile.ps1') -Apply -DispatchLog $f.log -GhCommand $f.gh | ConvertFrom-Json
  }
  $calls = @(Get-BoardCalls $f 'mutation')
  $observations = @(Get-Content (Join-Path $f.root 'observations.jsonl') | ConvertFrom-Json)
  $evidence = Join-Path $PSScriptRoot 'logs/board-index-refusal'
  [void][IO.Directory]::CreateDirectory($evidence)
  [IO.File]::WriteAllText((Join-Path $evidence "$Path-$Case-$Arm.json"), (@{
    synthetic = $true; path = $Path; case = $Case; arm = $Arm; observations = $observations
    result = $r; mutations = $calls; calls = @(Get-Content $f.calls)
  } | ConvertTo-Json -Depth 30))
  if ($Arm -eq 'candidate') {
    Assert-Board ($calls.Count -eq 0) "$Path/$Case candidate refuses"
    if ($Case -ne 'history-error') {
      Assert-Board ($observations.Count -ge 2) "$Path/$Case initial and fresh payloads"
      if ($Case -in @('status-race','writer-race')) {
        $initialStatus = if ($Path -eq 'event') { $observations[0].item.status.name } else { $observations[0].items[0].status.name }
        Assert-Board ($initialStatus -eq 'In lane' -and $observations[-1].item.status.name -eq 'In review') "$Path/$Case ordered authority observations"
      }
    }
  } else { Assert-Board ($calls.Count -eq 1) "$Path/$Case $Arm must expose unsafe mutation" }
  Write-Output "PASS board-index-refusal-and-race $Path/$Case/$Arm writes=$($calls.Count) observations=$($observations.Count)"
}
try {
  foreach ($path in @('event','hourly')) {
    foreach ($case in @('history-error','status-race','writer-race','replacement','issue-race','spec-race','ledger-append')) { Invoke-RefusalCase $path $case 'candidate' }
    Invoke-RefusalCase $path 'history-error' 'missing-history-error'
    Invoke-RefusalCase $path 'status-race' 'stale-observation'
    Invoke-RefusalCase $path 'writer-race' 'stale-observation'
  }
} finally {
  $resolved = [IO.Path]::GetFullPath($root)
  if ((Split-Path -Parent $resolved) -ne [IO.Path]::GetTempPath().TrimEnd('\','/') -or (Split-Path -Leaf $resolved) -notlike 'board-index-refusal-*') { throw 'unsafe refusal cleanup' }
  if (Test-Path $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
