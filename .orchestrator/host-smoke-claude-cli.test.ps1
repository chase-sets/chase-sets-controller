Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
# #8580 AC2 host smoke (LOCAL_ONLY in CI): the installed Claude CLI must still
# be the pinned version and must still accept the exact dispatch-lane argument
# vector recorded in fixtures/claude-cli-help-v1.json. dispatch-lane.test.ps1
# consumes that fixture everywhere; drift of the installed CLI fails here.
# --help is bounded and exits before session creation, authentication, or a
# model request.
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "ASSERTION FAILED: $Message" } }

$fixturePath = Join-Path $PSScriptRoot "fixtures/claude-cli-help-v1.json"
$fixture = Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json -DateKind String
Assert-True ($fixture.schemaVersion -ceq "claude-cli-help-fixture/v1" -and @($fixture.arguments).Count -ge 1) "captured Claude argument fixture is readable"

$installed = Get-Command claude -CommandType Application -ErrorAction Stop | Select-Object -First 1
Assert-True ((Split-Path -Leaf $installed.Source) -ceq [string]$fixture.executableLeaf) "installed Claude CLI is the pinned executable kind ($($fixture.executableLeaf))"
$version = ((& $installed.Source --version 2>&1) -join "`n").Trim()
Assert-True ($LASTEXITCODE -eq 0) "installed Claude CLI reports its version"
Assert-True ($version -ceq [string]$fixture.version) "installed Claude CLI version '$version' equals the pinned fixture version '$($fixture.version)' (drift control)"
Write-Output "PASS host smoke: installed Claude CLI version $version matches the pinned fixture"

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("host-smoke-claude-cli-" + [guid]::NewGuid().ToString("N"))
[void][IO.Directory]::CreateDirectory($testRoot)
$process = $null
try {
  $helpOutput = Join-Path $testRoot "claude-argument-fixture.out"
  $helpError = Join-Path $testRoot "claude-argument-fixture.err"
  $process = Start-Process -FilePath $installed.Source `
    -ArgumentList @(@($fixture.arguments) + [string]$fixture.helpArgument) -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput $helpOutput -RedirectStandardError $helpError
  $exited = $process.WaitForExit([int]$fixture.boundMs)
  if (-not $exited) {
    $process.Kill($true)
    [void]$process.WaitForExit(5000)
  }
  Assert-True ($exited) "installed Claude argument fixture exits within 10 seconds without launching a model"
  Assert-True ($process.ExitCode -eq 0) "installed Claude CLI accepts the exact disallowed-tool argument shape"
  $helpBytes = [IO.File]::ReadAllBytes($helpOutput)
  $helpText = [Text.UTF8Encoding]::new($false, $true).GetString($helpBytes)
  Assert-True ($helpText -match "--disallowedTools") "installed Claude help confirms the supported disallowed-tools option"
  $helpSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($helpBytes)).ToLowerInvariant()
  Assert-True ($helpSha256 -ceq [string]$fixture.stdoutSha256 -and $helpBytes.Length -eq [int64]$fixture.stdoutBytes) "installed Claude help output digest $helpSha256 equals the captured fixture digest $($fixture.stdoutSha256) (drift control)"
  Write-Output "PASS host smoke: installed Claude CLI parses the exact argument vector (exit 0, $($helpBytes.Length) help bytes, digest unchanged)"
} finally {
  if ($process) { $process.Dispose() }
  Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
