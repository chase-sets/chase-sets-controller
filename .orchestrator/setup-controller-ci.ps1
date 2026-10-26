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
