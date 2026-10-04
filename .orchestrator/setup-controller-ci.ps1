param([switch]$Toolchain)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted') {
  throw 'Only GitHub-hosted runners may provision the CI toolchain'
}
$destination = 'C:/Users/ToddS/.cache/codex-runtimes/codex-primary-runtime/dependencies/native/powershell'
$archive = Join-Path $env:RUNNER_TEMP 'PowerShell-7.6.5-win-x64.zip'
Invoke-WebRequest 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.5/PowerShell-7.6.5-win-x64.zip' -OutFile $archive
if ((Get-FileHash $archive -Algorithm SHA256).Hash -cne '32EB8F6CDCE08F86E987D625A2733E54AC3E289AE7E1621B14C0B5BCEC2434EA') {
  throw 'PowerShell release checksum mismatch'
}
Expand-Archive -LiteralPath $archive -DestinationPath $destination
Add-Content -LiteralPath $env:GITHUB_PATH -Value $destination
Add-Content -LiteralPath $env:GITHUB_ENV -Value "CONTROLLER_PWSH=$destination/pwsh.exe"
& "$destination/pwsh.exe" -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
if ($LASTEXITCODE -ne 0) { throw 'PowerShell runtime validation failed' }

# A private, writable carrier is inherited by every fixture and its children.
# Do not change machine ACLs or relax the controller's path/ownership checks.
$fixtureParent = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Temp'
# Each job owns a fresh VM. A short private carrier avoids MAX_PATH failures
# in the unchanged fixtures' nested repositories and Git rebase internals.
$temp = Join-Path $fixtureParent 'cci'
if (Test-Path -LiteralPath $temp) { throw 'CI temporary carrier already exists' }
[void][IO.Directory]::CreateDirectory($temp)
if ((Get-Item -LiteralPath $temp).Attributes -band [IO.FileAttributes]::ReparsePoint) {
  throw 'CI temporary carrier must be a plain directory'
}
$probe = Join-Path $temp 'write-probe'
[IO.File]::WriteAllText($probe, 'writable')
Remove-Item -LiteralPath $probe
Add-Content -LiteralPath $env:GITHUB_ENV -Value "TEMP=$temp`nTMP=$temp"

if ($Toolchain) {
  $tools = Join-Path $env:RUNNER_TEMP 'controller-pnpm'
  $native = Join-Path $tools 'native'
  $alternate = Join-Path $tools 'alternate'
  $nodePnpm = Join-Path $tools 'node-pnpm'
  foreach ($directory in @($native,$alternate,$nodePnpm)) { [void][IO.Directory]::CreateDirectory($directory) }
  $package = Join-Path $tools 'win-x64-11.21.0.tgz'
  Invoke-WebRequest 'https://registry.npmjs.org/@pnpm/win-x64/-/win-x64-11.21.0.tgz' -OutFile $package
  $integrity = [Convert]::ToBase64String([Security.Cryptography.SHA512]::HashData([IO.File]::ReadAllBytes($package)))
  if ($integrity -cne 'zT3TufmVOroWPrzXTPPPgYvIsTZIsK13kjpmgXlICyEFrhd16RFLoTWFhP+8UqHXpTNmVbtTHzg+fEVYy9rlEQ==') {
    throw 'Native pnpm package integrity mismatch'
  }
  & tar.exe -xzf $package -C $native
  if ($LASTEXITCODE -ne 0) { throw 'Native pnpm extraction failed' }
  # pnpm 11's SEA binary loads companion modules from @pnpm/exe/dist.
  $companion = Join-Path $tools 'exe-11.21.0.tgz'
  Invoke-WebRequest 'https://registry.npmjs.org/@pnpm/exe/-/exe-11.21.0.tgz' -OutFile $companion
  $integrity = [Convert]::ToBase64String([Security.Cryptography.SHA512]::HashData([IO.File]::ReadAllBytes($companion)))
  if ($integrity -cne 'zawQxIewH1od72HhlmXWq3No6XyuWn+nMvQ9BjWWGNBVskmS+RDlTu7ey2ruL650PbbyuCATYSal1DaXFKBdcw==') {
    throw 'Native pnpm companion integrity mismatch'
  }
  & tar.exe -xzf $companion -C $native
  if ($LASTEXITCODE -ne 0) { throw 'Native pnpm companion extraction failed' }
  $executable = Join-Path $native 'package/pnpm.exe'
  if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw 'Native pnpm executable missing' }
  Copy-Item -LiteralPath $executable -Destination (Join-Path $alternate 'pnpm.exe')
  Copy-Item -LiteralPath (Join-Path $native 'package/dist') -Destination (Join-Path $alternate 'dist') -Recurse
  # Match the host's direct-binary shim contract, without changing its resolver.
  [IO.File]::WriteAllText((Join-Path $native 'pnpm.CMD'), "@SETLOCAL`r`n@`"%~dp0\package\pnpm.exe`" %*`r`n", [Text.ASCIIEncoding]::new())
  & npm.cmd install --global --prefix $nodePnpm --ignore-scripts --no-audit --no-fund pnpm@11.21.0
  if ($LASTEXITCODE -ne 0) { throw 'Node-hosted pnpm provisioning failed' }
  foreach ($binary in @($executable, (Join-Path $alternate 'pnpm.exe'), (Join-Path $nodePnpm 'pnpm.cmd'))) {
    $version = & $binary --version
    if ($LASTEXITCODE -ne 0 -or $version -cne '11.21.0') { throw 'pnpm version mismatch' }
  }
  # GITHUB_PATH prepends the last entry first. Keep the exact native shim first,
  # the distinct native binary second, and the safe Node distribution discoverable.
  Add-Content -LiteralPath $env:GITHUB_PATH -Value "$nodePnpm`n$alternate`n$native"
}
