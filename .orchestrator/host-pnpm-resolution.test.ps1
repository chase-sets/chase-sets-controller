param([string]$GuardRevision = '')
$ErrorActionPreference = 'Stop'
$source = if ($GuardRevision) {
  $text = @(& git -C (Split-Path -Parent $PSScriptRoot) show "${GuardRevision}:.orchestrator/invoke-heavy-verifier.ps1") -join "`n"
  if ($LASTEXITCODE -ne 0) { throw 'baseline verifier source unavailable' }
  $text
} else { [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'invoke-heavy-verifier.ps1')) }
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$errors)
if ($errors.Count) { throw 'verifier must parse' }
$resolver = @($ast.EndBlock.Statements | Where-Object {
  $_ -is [Management.Automation.Language.IfStatementAst] -and
    $_.Clauses[0].Item1.Extent.Text -ceq '$isHostVerifier' -and
    $_.Extent.Text.Contains('Get-Command node')
})
$safeFile = @($ast.FindAll({ param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Test-PrecursorSafeFile'
}, $true))
if ($resolver.Count -ne 1 -or $safeFile.Count -ne 1) { throw 'expected exact host resolver and safe-file predicate' }
$resolve = [scriptblock]::Create($resolver[0].Extent.Text)
$predicate = [scriptblock]::Create($safeFile[0].Extent.Text)
$root = Join-Path ([IO.Path]::GetTempPath()) ('host-pnpm-resolution-' + [guid]::NewGuid().ToString('N'))
try {
  $bin = Join-Path $root 'node_modules/pnpm/bin'
  [void][IO.Directory]::CreateDirectory($bin)
  $node = Join-Path $root 'node.exe'
  $shim = Join-Path $root 'pnpm.cmd'
  # Inert files only. Neither an executable, a shim nor pnpm is ever invoked.
  [IO.File]::WriteAllText($node, 'inert node path')
  [IO.File]::WriteAllText($shim, 'shim text must never be executed')
  $localShim = Join-Path $root 'node_modules/.bin/pnpm.cmd'
  [void][IO.Directory]::CreateDirectory((Split-Path -Parent $localShim))
  [IO.File]::WriteAllText($localShim, 'local shim text must never be executed')
  foreach ($case in @(
      @{Name='cjs'; Files=@('pnpm.cjs'); Expected='pnpm.cjs'},
      @{Name='mjs'; Files=@('pnpm.mjs'); Expected='pnpm.mjs'},
      @{Name='both'; Files=@('pnpm.cjs','pnpm.mjs'); Expected='pnpm.cjs'},
      @{Name='cjs-local-bin'; Files=@('pnpm.cjs'); Local=$true; Expected='pnpm.cjs'},
      @{Name='mjs-local-bin'; Files=@('pnpm.mjs'); Local=$true; Expected='pnpm.mjs'},
      @{Name='both-local-bin'; Files=@('pnpm.cjs','pnpm.mjs'); Local=$true; Expected='pnpm.cjs'},
      @{Name='missing'; Files=@(); Refused=$true},
      @{Name='directory'; Files=@(); Directory=$true; Refused=$true},
      @{Name='embedded-node'; Files=@('pnpm.mjs'); Embedded=$true; Refused=$true},
      @{Name='manifest-replay'; Files=@(); Replay=$true}
    )) {
    foreach ($name in @('pnpm.cjs','pnpm.mjs')) {
      $path = Join-Path $bin $name
      if (Test-Path -LiteralPath $path -PathType Container) { [IO.Directory]::Delete($path) }
      elseif (Test-Path -LiteralPath $path) { [IO.File]::Delete($path) }
    }
    foreach ($name in $case.Files) { [IO.File]::WriteAllText((Join-Path $bin $name), 'inert package entry') }
    if ($case.Directory) { [void][IO.Directory]::CreateDirectory((Join-Path $bin 'pnpm.mjs')) }
    $result = & {
      param($Case, $NodePath, $ShimPath, $Resolve, $Predicate)
      function Get-Command {
        [CmdletBinding()]param([string]$Name, [switch]$All, [string]$CommandType)
        if (-not $All -or $CommandType -cne 'Application') { throw 'resolver command lookup changed' }
        if ($Name -ceq 'node') {
          [pscustomobject]@{Source=$(if ($Case.Embedded) { Join-Path (Split-Path $NodePath) 'pnpm.exe' } else { $NodePath })}
        } elseif ($Name -ceq 'pnpm') { [pscustomobject]@{Source=$ShimPath} }
        else { throw "unexpected command lookup: $Name" }
      }
      . $Predicate
      $isHostVerifier = $true
      $isManifestReplay = [bool]$Case.Replay
      $hostNode = $null; $pnpmScript = $null; $failure = $null
      try { . $Resolve } catch { $failure = $_.Exception.Message }
      @{Node=$hostNode; Script=$pnpmScript; Failure=$failure}
    } $case $node $(if ($case.Local) { $localShim } else { $shim }) $resolve $predicate
    if ($case.Refused) {
      if ($result.Failure -cne 'heavy-verifier: invoke-heavy-verifier.ps1 requires a plain Node executable and Node-hosted pnpm distribution; no unguarded fallback') { throw "expected closed refusal for $($case.Name): $($result.Failure)" }
    } else {
      $expected = if ($case.Expected) { [IO.Path]::GetFullPath((Join-Path $bin $case.Expected)) } else { $null }
      if ($result.Failure -or $result.Node -cne $node -or $result.Script -cne $expected) { throw "host pnpm resolution failed for $($case.Name): $($result.Failure)" }
    }
  }
  Write-Output 'PASS actual host resolver: global/local-bin cjs/mjs/both, missing/directory/embedded-node refused, manifest replay preserved; no executable or admission run'
} finally {
  $resolved = [IO.Path]::GetFullPath($root)
  if ((Split-Path -Parent $resolved).TrimEnd('\','/') -cne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/') -or (Split-Path -Leaf $resolved) -notlike 'host-pnpm-resolution-*') { throw 'unsafe fixture cleanup' }
  if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
