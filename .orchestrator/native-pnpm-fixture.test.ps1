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
  $nodeShim = Join-Path $root 'node-pnpm.CMD'
  [IO.File]::WriteAllText($nodeShim, '@node "%~dp0\node_modules\pnpm\bin\pnpm.cjs" %*')
  if ((Get-NativePnpmFixtureShim $nodeShim $shim) -cne $shim -or
      (Resolve-NativePnpmFixture (Get-NativePnpmFixtureShim $nodeShim $shim)) -cne $binary) { throw 'separate native fixture did not coexist with active Node shim' }
  if ((Get-NativePnpmFixtureShim $shim '') -cne $shim) { throw 'ordinary installed-native fallback changed' }
  $previousNativeShim = $env:CONTROLLER_NATIVE_PNPM_SHIM
  try {
    $env:CONTROLLER_NATIVE_PNPM_SHIM = $shim
    if ((Resolve-NativePnpmFixture (Get-NativePnpmFixtureShim $nodeShim)) -cne $binary) { throw 'hosted environment did not select separate native fixture' }
  } finally { $env:CONTROLLER_NATIVE_PNPM_SHIM = $previousNativeShim }
  $failed = $false
  try { Resolve-NativePnpmFixture (Get-NativePnpmFixtureShim $shim $nodeShim) | Out-Null } catch {
    if ($_.Exception.Message -cne 'unable to resolve the active pnpm.CMD direct binary') { throw }
    $failed = $true
  }
  if (-not $failed) { throw 'configured JS shim silently fell back to native executable' }
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
  $setups = [regex]::Matches($workflow, '(?m)^      - (?:id: native_pnpm\n        )?uses: pnpm/action-setup@[^\n]+\n        with:\n(?<inputs>(?:          [^\n]+\n)+)')
  if ($setups.Count -ne 4) { throw 'expected separate native and Node-hosted pnpm in plan and shard' }
  foreach ($setup in $setups) {
    if ($setup.Groups['inputs'].Value -notmatch '(?m)^          version: 11\.21\.0$') { throw 'hosted pnpm pin missing' }
  }
  foreach ($offset in @(0, 2)) {
    if ($setups[$offset].Groups['inputs'].Value -notmatch '(?m)^          standalone: true$' -or
        $setups[$offset].Groups['inputs'].Value -notmatch '(?m)^          dest: ~/setup-native-pnpm$' -or
        $setups[$offset + 1].Groups['inputs'].Value -notmatch '(?m)^          standalone: false$') { throw 'native package must be separate and Node-hosted pnpm must remain last on PATH' }
  }
  if ($workflow -notmatch '(?m)^          CONTROLLER_NATIVE_PNPM_SHIM: \$\{\{ steps\.native_pnpm\.outputs\.bin_dest \}\}/pnpm\.cmd$') { throw 'shard native fixture binding missing' }
  Write-Output 'PASS separate real native fixture and active Node pnpm paths; explicit/extensionless native, JS/missing refused; dual hosted distributions pinned; no executable run'
} finally {
  $resolved = [IO.Path]::GetFullPath($root)
  if ((Split-Path -Parent $resolved).TrimEnd('\', '/') -cne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\', '/') -or (Split-Path -Leaf $resolved) -notlike 'native-pnpm-path-*') { throw 'unsafe path fixture cleanup' }
  if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
