$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'pnpm-test-support.ps1')
function Assert-True($Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}
function Assert-Refused([string[]]$Shims, [string]$Message) {
  $observed = $null
  try { Resolve-NativePnpmTestCommand -CommandShims $Shims | Out-Null } catch { $observed = $_.Exception.Message }
  Assert-True ($observed -ceq 'unable to resolve a native pnpm.CMD direct binary') $Message
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('pnpm-test-support-' + [guid]::NewGuid().ToString('N'))
try {
  [void][IO.Directory]::CreateDirectory($root)
  $nodeShim = Join-Path $root 'node.cmd'
  $nativeShim = Join-Path $root 'native.cmd'
  $siblingShim = Join-Path $root 'sibling.cmd'
  $missingShim = Join-Path $root 'missing.cmd'
  $wrongShim = Join-Path $root 'wrong.cmd'
  $nativeDirectory = Join-Path $root 'native package'
  [void][IO.Directory]::CreateDirectory($nativeDirectory)
  $native = Join-Path $nativeDirectory 'pnpm.exe'
  $sibling = Join-Path $root 'pnpm.exe'
  [IO.File]::WriteAllText($native, 'inert test bytes, never executed')
  [IO.File]::WriteAllText($sibling, 'inert sibling bytes, never executed')
  [IO.File]::WriteAllText((Join-Path $root 'not-pnpm.exe'), 'inert wrong-name bytes, never executed')
  [IO.File]::WriteAllText($nodeShim, '@node "%~dp0\node_modules\pnpm\bin\pnpm.cjs" %*')
  [IO.File]::WriteAllText($nativeShim, '@"%~dp0\native package\pnpm.exe" %*')
  [IO.File]::WriteAllText($siblingShim, '@"%~dp0\pnpm.exe" %*')
  [IO.File]::WriteAllText($missingShim, '@"%~dp0\missing\pnpm.exe" %*')
  [IO.File]::WriteAllText($wrongShim, '@"%~dp0\not-pnpm.exe" %*')
  $resolved = Resolve-NativePnpmTestCommand -CommandShims @($nodeShim, $missingShim, $nativeShim)
  Assert-True ($resolved.Source -ceq $nativeShim -and $resolved.NativePath -ceq $native) 'Node-hosted and missing-binary shims do not mask a later native wrapper'
  $resolved = Resolve-NativePnpmTestCommand -CommandShims @($siblingShim, $nativeShim)
  Assert-True ($resolved.Source -ceq $siblingShim -and $resolved.NativePath -ceq $sibling) 'sibling executable and first valid native wrapper are supported'
  Assert-Refused @($nodeShim) 'Node-hosted wrapper alone is not native proof'
  Assert-Refused @($missingShim) 'absent declared binary refuses'
  Assert-Refused @($wrongShim) 'another executable basename refuses'
  Assert-Refused @() 'no wrapper refuses'
  Write-Host 'PASS native pnpm fixture resolution: Node-first, missing, spaces, sibling, wrong-name and empty controls'
} finally {
  $resolvedRoot = [IO.Path]::GetFullPath($root)
  Assert-True ((Split-Path -Parent $resolvedRoot).TrimEnd('\','/') -ceq ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/') -and
    (Split-Path -Leaf $resolvedRoot) -like 'pnpm-test-support-*') 'owned fixture cleanup stays in its private temp root'
  if (Test-Path -LiteralPath $resolvedRoot) { Remove-Item -LiteralPath $resolvedRoot -Recurse -Force }
}
