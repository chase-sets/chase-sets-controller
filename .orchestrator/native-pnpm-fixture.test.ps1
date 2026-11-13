$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'native-pnpm-test-support.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ('native-pnpm-path-' + [guid]::NewGuid().ToString('N'))
try {
  [void][IO.Directory]::CreateDirectory((Join-Path $root 'node_modules/@pnpm/exe'))
  $shim = Join-Path $root 'pnpm.CMD'
  $binary = [IO.Path]::GetFullPath((Join-Path $root 'node_modules/@pnpm/exe/pnpm.exe'))
  # Inert path-resolution fixture only; this placeholder is never executed.
  [IO.File]::WriteAllText($binary, 'not an executable')
  foreach ($relative in @('node_modules\@pnpm\exe\pnpm.exe', 'node_modules\@pnpm\exe\pnpm')) {
    [IO.File]::WriteAllText($shim, ('@"%~dp0\' + $relative + '" %*'))
    if ((Resolve-NativePnpmFixture $shim) -cne $binary) { throw 'native shim did not resolve exact executable' }
  }
  [IO.File]::WriteAllText($shim, '@node "%~dp0\node_modules\pnpm\bin\pnpm.cjs" %*')
  $failed = $false
  try { Resolve-NativePnpmFixture $shim | Out-Null } catch {
    if ($_.Exception.Message -cne 'unable to resolve the active pnpm.CMD direct binary') { throw }
    $failed = $true
  }
  if (-not $failed) { throw 'JS shim accepted as native executable' }
  [IO.File]::WriteAllText($shim, '@"%~dp0\missing\pnpm" %*')
  $failed = $false
  try { Resolve-NativePnpmFixture $shim | Out-Null } catch {
    if ($_.Exception.Message -cne 'native pnpm fixture executable missing') { throw }
    $failed = $true
  }
  if (-not $failed) { throw 'missing native executable accepted' }
  $workflow = [IO.File]::ReadAllText((Join-Path (Split-Path -Parent $PSScriptRoot) '.github/workflows/controller-battery.yml')).Replace("`r`n", "`n")
  $setups = [regex]::Matches($workflow, '(?m)^      - uses: pnpm/action-setup@[^\n]+\n        with:\n(?<inputs>(?:          [^\n]+\n)+)')
  if ($setups.Count -ne 2) { throw 'expected plan and shard pnpm setup' }
  foreach ($setup in $setups) {
    if ($setup.Groups['inputs'].Value -notmatch '(?m)^          version: 11\.21\.0$' -or $setup.Groups['inputs'].Value -notmatch '(?m)^          standalone: true$') { throw 'hosted native pnpm prerequisite missing' }
  }
  Write-Output 'PASS actual native pnpm shim resolver: explicit/extensionless native, JS/missing refused; hosted plan/shard native package pinned; no executable run'
} finally {
  $resolved = [IO.Path]::GetFullPath($root)
  if ((Split-Path -Parent $resolved).TrimEnd('\', '/') -cne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\', '/') -or (Split-Path -Leaf $resolved) -notlike 'native-pnpm-path-*') { throw 'unsafe path fixture cleanup' }
  if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
