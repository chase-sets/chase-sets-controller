function Resolve-NativePnpmTestCommand {
  param([string[]]$CommandShims = @(
    Get-Command pnpm -All -ErrorAction Stop |
      Where-Object { $_.Source -like '*\pnpm.cmd' } |
      Select-Object -ExpandProperty Source
  ))
  foreach ($shim in $CommandShims) {
    $text = Get-Content -LiteralPath $shim -Raw -ErrorAction Stop
    $match = [regex]::Match($text, '"%~dp0\\(?<relative>(?:[^"]*\\)?pnpm\.exe)"', 'IgnoreCase')
    if (-not $match.Success) { continue }
    $native = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $shim) $match.Groups['relative'].Value))
    if (-not (Test-Path -LiteralPath $native -PathType Leaf)) { continue }
    return [pscustomobject]@{ Source = $shim; NativePath = $native }
  }
  throw 'unable to resolve a native pnpm.CMD direct binary'
}
