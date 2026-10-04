Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
# #8580 AC3 host smoke (LOCAL_ONLY in CI): the real-host assertions of
# codex-launch-boundary.test.ps1 against the installed Codex build. The pinned
# native harness and its observed identity, PATH-decoy immunity, live surface
# admission, the real profile record and its construction-to-launch
# revalidation, and the P1 sandbox zero-byte control run here; every portable
# control stays in codex-launch-boundary.test.ps1. Model CLI execution remains
# prohibited: only --version, surface metadata commands and the sandbox actor run.

function Assert-True {
  param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Get-RefusalCode {
  param([Parameter(Mandatory)][scriptblock]$Body)
  try {
    & $Body
  } catch {
    return $_.Exception.Message
  }
  throw "ASSERTION FAILED: expected refusal"
}

$tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd(
  [IO.Path]::DirectorySeparatorChar,
  [IO.Path]::AltDirectorySeparatorChar
)
$testRoot = Join-Path $tempParent ("chase-sets-6721-host-smoke-$([Guid]::NewGuid().ToString('N'))")
[void][IO.Directory]::CreateDirectory($testRoot)

try {
  $modulePath = Join-Path $PSScriptRoot "codex-launch-boundary.psm1"
  $module = Import-Module $modulePath -Force -PassThru
  $contract = & $module { $script:CodexBoundaryContract }

  # Live identity: the canonical path is pinned; digest, length, and version are
  # observed for exact construction-to-launch closure, not release admission.
  $identity = Resolve-CodexBoundaryHarness
  Assert-True ([IO.Path]::IsPathFullyQualified($identity.path)) "harness path is absolute"
  Assert-True ($identity.path -ceq $contract.harnessPath) "harness path is the pinned native executable"
  Assert-True ($identity.sha256 -ceq (Get-FileHash -LiteralPath $identity.path -Algorithm SHA256).Hash.ToLowerInvariant()) "harness SHA-256 is observed"
  Assert-True ($identity.length -eq (Get-Item -LiteralPath $identity.path).Length) "harness byte length is observed"
  Assert-True ($identity.version -cmatch '^codex-cli [0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$') "harness reported version is observed and well formed"
  Write-Output "PASS codex boundary resolves the canonical live native harness and observes its identity"

  $decoyDirectory = Join-Path $testRoot "decoy-path"
  [void][IO.Directory]::CreateDirectory($decoyDirectory)
  [IO.File]::WriteAllText((Join-Path $decoyDirectory "codex.exe"), "not a PE", [Text.UTF8Encoding]::new($false))
  $oldPath = $env:PATH
  try {
    $env:PATH = "$decoyDirectory;$oldPath"
    $decoyResult = Resolve-CodexBoundaryHarness
    Assert-True ($decoyResult.path -ceq $contract.harnessPath) "earlier PATH decoy cannot change the pinned path"
  } finally {
    $env:PATH = $oldPath
  }
  Write-Output "PASS codex boundary resolution never consults PATH order or shims"

  # Retain the historical evidence bytes, but admit the live build from its
  # closed behavioral/capability surface rather than byte equality.
  $surfaceSha = & $module { param($Harness) Assert-CodexBoundarySurface -Harness $Harness } $identity
  Assert-True ($surfaceSha -ceq $contract.surfaceFixtureSha256) "historical surface evidence retains its provenance digest"
  Write-Output "PASS codex boundary admits the live build from its closed behavioral surface"

  # The real profile binds the live harness and the admitted surface.
  $ordinaryRoot = Join-Path $testRoot "ordinary\child"
  [void][IO.Directory]::CreateDirectory($ordinaryRoot)
  $writableRoot = Join-Path $testRoot "writable"
  [void][IO.Directory]::CreateDirectory($writableRoot)
  $profile = & $module {
    param($Harness, $Surface, $Readable, $Writable)
    New-CodexBoundaryProfileRecord -Harness $Harness -SurfaceSha256 $Surface -ReadableRoots @($Readable) -WritableRoot $Writable
  } $identity $surfaceSha $ordinaryRoot $writableRoot
  Assert-True ([string]$profile.harness.path -ceq $identity.path -and [string]$profile.harness.sha256 -ceq $identity.sha256 -and [int64]$profile.harness.length -eq $identity.length -and [string]$profile.harness.version -ceq $identity.version) "profile binds the live harness identity"
  $moduleSha = & $module { param($Record) Get-CodexBoundaryProfileSha256 -Record $Record } $profile
  Assert-True ($moduleSha -ceq $profile.profileSha256) "independent canonical digest equals module digest"
  $configBytes = [Convert]::FromBase64String([string]$profile.isolatedCodexHome.files[0].contentBase64)
  Assert-True (([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($configBytes)).ToLowerInvariant()) -ceq [string]$profile.isolatedCodexHome.files[0].sha256) "isolated CODEX_HOME content digest binds exact bytes"
  Assert-True (Test-CodexLaunchBoundaryStillValid -Boundary $profile) "unchanged real profile revalidates against the live harness and surface"
  Write-Output "PASS codex boundary real profile binds the live harness and revalidates"

  # Revalidation binds root object identity, not only a stable spelling.
  $boundary = ($profile | ConvertTo-Json -Depth 100) | ConvertFrom-Json -Depth 100 -DateKind String
  Move-Item -LiteralPath $ordinaryRoot -Destination (Join-Path $testRoot "ordinary\old-child")
  [void][IO.Directory]::CreateDirectory($ordinaryRoot)
  $code = Get-RefusalCode { Test-CodexLaunchBoundaryStillValid -Boundary $boundary }
  Assert-True ($code -ceq "codex-boundary-revalidation-drift") "same path with changed filesystem identity refuses revalidation"
  Write-Output "PASS codex boundary revalidation detects construction-to-launch root drift"

  # Exact credential-bearing source control: the sandbox actor reports only
  # a byte count. It never prints or copies source content.
  $containerRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
  $credentialBearingSource = Join-Path $containerRoot "main\deployables\marketplace\e2e\support\seed-contract.ts"
  $actor = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
  $probeScript = @'
$bytesRead = 0
try {
  $stream = [IO.File]::OpenRead('__SOURCE__')
  try { if ($stream.ReadByte() -ge 0) { $bytesRead = 1 } } finally { $stream.Dispose() }
} catch {}
Write-Output $bytesRead
'@.Replace("__SOURCE__", $credentialBearingSource.Replace("'", "''"))
  $probeEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probeScript))
  $probeEnvironment = & $module { param($Root) Get-CodexBoundaryMinimalEnvironment -FixtureRoot $Root } $testRoot
  [IO.File]::WriteAllBytes((Join-Path $probeEnvironment.CODEX_HOME "config.toml"), $configBytes)
  $probeResult = & $module {
    param($HarnessPath, $ActorPath, $Encoded, $Root)
    Invoke-CodexBoundaryNativeProcess -ExecutablePath $HarnessPath -Arguments @(
      "sandbox", "-P", "chase_sets_boundary", "--sandbox-state-disable-network", "--",
      $ActorPath, "-NoProfile", "-NonInteractive", "-EncodedCommand", $Encoded
    ) -FixtureRoot $Root
  } $identity.path $actor $probeEncoded $testRoot
  $reportedBytes = [Text.UTF8Encoding]::new($false, $true).GetString($probeResult.stdoutBytes).Trim()
  Assert-True ($reportedBytes -ceq "0") "exact credential-bearing source yields zero bytes with no content output"
  Write-Output "PASS P1 exact-source control obtains zero bytes without printing or copying content"
} finally {
  $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
  $cleanupItem = Get-Item -LiteralPath $resolvedTestRoot -Force -ErrorAction SilentlyContinue
  if ($null -ne $cleanupItem) {
    if ($cleanupItem.Parent.FullName.TrimEnd([IO.Path]::DirectorySeparatorChar) -cne $tempParent -or
        -not $cleanupItem.Name.StartsWith("chase-sets-6721-host-smoke-", [StringComparison]::Ordinal)) {
      throw "refusing unsafe host smoke cleanup: $resolvedTestRoot"
    }
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
