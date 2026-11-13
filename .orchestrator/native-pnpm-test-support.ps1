function Resolve-NativePnpmFixture([string]$ShimPath) {
  $text = Get-Content -LiteralPath $ShimPath -Raw
  if ($text -notmatch '"%~dp0\\(?<relative>[^"]*\\pnpm(?:\.exe)?)"') {
    throw "unable to resolve the active pnpm.CMD direct binary"
  }
  $binary = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $ShimPath) $Matches.relative))
  if (-not $binary.EndsWith('.exe', [StringComparison]::OrdinalIgnoreCase)) { $binary += '.exe' }
  if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) { throw 'native pnpm fixture executable missing' }
  return $binary
}
