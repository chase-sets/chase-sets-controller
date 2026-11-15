param([string]$GuardRevision = '')
$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot 'heavy-admission-preload.test.ps1'
$errors = $null
if ($GuardRevision) {
  $source = @(& git -C (Split-Path -Parent $PSScriptRoot) show "${GuardRevision}:.orchestrator/heavy-admission-preload.test.ps1") -join "`n"
  if ($LASTEXITCODE -ne 0) { throw 'baseline preload source unavailable' }
  $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$errors)
} else {
  $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
}
if ($errors.Count) { throw 'preload test must parse' }
$outer = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })
if ($outer.Count -ne 1 -or -not $outer[0].Finally) { throw 'expected one real outer preload try/finally' }
$setup = @($outer[0].Body.Statements | Where-Object {
  $_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -ceq '$pnpmCommandShim'
})
if ($setup.Count -ne 1) { throw 'expected one pnpm resolution boundary' }
$prefix = @($outer[0].Body.Statements | Where-Object { $_.Extent.EndOffset -lt $setup[0].Extent.StartOffset } | ForEach-Object { $_.Extent.Text }) -join "`n"
$finally = $outer[0].Finally.Extent.Text
$script = "`$PSScriptRoot = '$($PSScriptRoot.Replace("'", "''"))'`ntry {`n$prefix`nthrow 'synthetic early setup failure'`n} finally $finally"
foreach ($mutant in @($false, $true)) {
  & {
    param($PassUnknownSpawnShapeMutant, $Body)
    $routingTestScope = 'inert-scope'
    $script:scopeExits = 0
    function Exit-RoutingDataTestScope($Scope) {
      if ($Scope -cne 'inert-scope') { throw 'routing scope changed' }
      $script:scopeExits++
    }
    $failure = $null
    try { & ([scriptblock]::Create($Body)) } catch { $failure = $_ }
    if ($script:scopeExits -ne 1) { throw 'real finally must close routing scope once' }
    if (-not $failure) { throw 'early setup or native guard failure disappeared' }
    if (-not $PassUnknownSpawnShapeMutant) {
      if ($failure.Exception.Message -cne 'synthetic early setup failure') { throw "original setup error masked: $($failure.Exception.Message)" }
    } elseif ($failure.Exception.Message -notlike '*native spawn shape/refusal control exits 0*') {
      throw "native refusal mutant did not fail the ordinary guard: $($failure.Exception.Message)"
    }
  } $mutant $script
}
Write-Output 'PASS actual early setup/finally preserves original failure and ordinary native guard mutant; endpoints inert, no census/Job/signal'
