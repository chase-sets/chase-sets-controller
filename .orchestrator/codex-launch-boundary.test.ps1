Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

function ConvertTo-TestCanonicalNode {
  param($Value)
  if ($null -eq $Value) { return $null }
  if ($Value -is [string] -or $Value -is [bool] -or
      $Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or
      $Value -is [int64] -or $Value -is [uint16] -or $Value -is [uint32] -or
      $Value -is [uint64] -or $Value -is [single] -or $Value -is [double] -or
      $Value -is [decimal]) { return $Value }
  if ($Value -is [Collections.IDictionary]) {
    $result = [ordered]@{}
    $keys = @($Value.Keys | ForEach-Object { [string]$_ })
    [Array]::Sort($keys, [StringComparer]::Ordinal)
    foreach ($key in $keys) { $result[$key] = ConvertTo-TestCanonicalNode $Value[$key] }
    return $result
  }
  if ($Value -is [Collections.IEnumerable]) {
    return ,@($Value | ForEach-Object { ConvertTo-TestCanonicalNode $_ })
  }
  $properties = [ordered]@{}
  foreach ($property in $Value.PSObject.Properties) { $properties[$property.Name] = $property.Value }
  return ConvertTo-TestCanonicalNode $properties
}

function Get-TestProfileSha256 {
  param([Parameter(Mandatory)]$Record)
  $copy = [ordered]@{}
  if ($Record -is [Collections.IDictionary]) {
    foreach ($key in $Record.Keys) {
      if ([string]$key -cne "profileSha256") { $copy[[string]$key] = $Record[$key] }
    }
  } else {
    foreach ($property in $Record.PSObject.Properties) {
      if ($property.Name -cne "profileSha256") { $copy[$property.Name] = $property.Value }
    }
  }
  $json = (ConvertTo-TestCanonicalNode $copy) | ConvertTo-Json -Compress -Depth 100
  $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
  return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Get-SurfaceDecodedPayload {
  param(
    [Parameter(Mandatory)][string]$Surface,
    [Parameter(Mandatory)][string]$Label,
    [Parameter(Mandatory)][ValidateSet("stdout", "file")][string]$Kind
  )
  $start = $Surface.IndexOf($Label, [StringComparison]::Ordinal)
  if ($start -lt 0) { throw "ASSERTION FAILED: surface label missing: $Label" }
  $prefix = "${Kind}-base64: "
  $payloadStart = $Surface.IndexOf($prefix, $start, [StringComparison]::Ordinal)
  if ($payloadStart -lt 0) { throw "ASSERTION FAILED: encoded payload missing: $Label" }
  $payloadStart += $prefix.Length
  $payloadEnd = $Surface.IndexOf("`n", $payloadStart, [StringComparison]::Ordinal)
  if ($payloadEnd -lt 0) { throw "ASSERTION FAILED: encoded payload terminator missing: $Label" }
  return [Convert]::FromBase64String($Surface.Substring($payloadStart, $payloadEnd - $payloadStart))
}

function Set-SurfaceDecodedPayload {
  param(
    [Parameter(Mandatory)][string]$Surface,
    [Parameter(Mandatory)][string]$Label,
    [Parameter(Mandatory)][string]$Before,
    [Parameter(Mandatory)][string]$After
  )
  $start = $Surface.IndexOf($Label, [StringComparison]::Ordinal)
  if ($start -lt 0) { throw "ASSERTION FAILED: surface label missing: $Label" }
  $prefix = "stdout-base64: "
  $payloadStart = $Surface.IndexOf($prefix, $start, [StringComparison]::Ordinal)
  if ($payloadStart -lt 0) { throw "ASSERTION FAILED: encoded payload missing: $Label" }
  $payloadStart += $prefix.Length
  $payloadEnd = $Surface.IndexOf("`n", $payloadStart, [StringComparison]::Ordinal)
  $bytes = [Convert]::FromBase64String($Surface.Substring($payloadStart, $payloadEnd - $payloadStart))
  $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
  $changed = $text.Replace($Before, $After, [StringComparison]::Ordinal)
  if ($changed -ceq $text) { throw "ASSERTION FAILED: surface mutation source missing: $Before" }
  $replacement = [Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes($changed))
  return $Surface.Substring(0, $payloadStart) + $replacement + $Surface.Substring($payloadEnd)
}

$tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd(
  [IO.Path]::DirectorySeparatorChar,
  [IO.Path]::AltDirectorySeparatorChar
)
$testRoot = Join-Path $tempParent ("chase-sets-6721-boundary-test-$([Guid]::NewGuid().ToString('N'))")
[void][IO.Directory]::CreateDirectory($testRoot)
$junctionPath = $null

try {
  $testItem = Get-Item -LiteralPath $testRoot -Force
  Assert-True (
    $testItem.Parent.FullName.TrimEnd([IO.Path]::DirectorySeparatorChar) -ceq $tempParent -and
    $testItem.Name.StartsWith("chase-sets-6721-boundary-test-", [StringComparison]::Ordinal) -and
    -not $testItem.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)
  ) "test fixture is a unique ordinary direct child of system temp"

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

  # All pre-version path/kind refusals prove that no version child was created.
  $versionReads = [pscustomobject]@{ count = 0 }
  $versionReader = { param($Path) $versionReads.count++; return "codex-cli 999.1.2" }.GetNewClosure()
  $absent = Join-Path $testRoot "absent\codex.exe"
  $code = Get-RefusalCode {
    & $module {
      param($Path, $Reader)
      Resolve-CodexBoundaryHarnessInternal -ExecutablePath $Path -VersionReader $Reader
    } $absent $versionReader
  }
  Assert-True ($code -ceq "codex-boundary-harness-absent" -and $versionReads.count -eq 0) "absent harness refuses before child creation"

  foreach ($name in @("codex.cmd", "codex.ps1", "codex")) {
    $shim = Join-Path $testRoot $name
    [IO.File]::WriteAllText($shim, "inert shim", [Text.UTF8Encoding]::new($false))
    $code = Get-RefusalCode {
      & $module {
        param($Path, $Reader)
        Resolve-CodexBoundaryHarnessInternal -ExecutablePath $Path -VersionReader $Reader
      } $shim $versionReader
    }
    Assert-True ($code -ceq "codex-boundary-harness-not-native" -and $versionReads.count -eq 0) "$name refuses as non-native before child creation"
  }

  $syntheticNative = Join-Path $testRoot "observational-codex.exe"
  $nativeBytes = [byte[]]::new(128)
  $nativeBytes[0] = 0x4d
  $nativeBytes[1] = 0x5a
  [BitConverter]::GetBytes([int]64).CopyTo($nativeBytes, 0x3c)
  $nativeBytes[64] = 0x50
  $nativeBytes[65] = 0x45
  [IO.File]::WriteAllBytes($syntheticNative, $nativeBytes)
  $observedA = & $module {
    param($Path, $Reader)
    Resolve-CodexBoundaryHarnessInternal -ExecutablePath $Path -VersionReader $Reader
  } $syntheticNative $versionReader
  $nativeBytes[100] = $nativeBytes[100] -bxor 1
  [IO.File]::WriteAllBytes($syntheticNative, $nativeBytes)
  $observedB = & $module {
    param($Path, $Reader)
    Resolve-CodexBoundaryHarnessInternal -ExecutablePath $Path -VersionReader $Reader
  } $syntheticNative $versionReader
  [IO.File]::WriteAllBytes($syntheticNative, ($nativeBytes + [byte]0))
  $observedC = & $module {
    param($Path, $Reader)
    Resolve-CodexBoundaryHarnessInternal -ExecutablePath $Path -VersionReader $Reader
  } $syntheticNative $versionReader
  Assert-True ($observedA.sha256 -cne $observedB.sha256 -and $observedA.length -eq $observedB.length) "one changed executable byte changes only the observed digest"
  Assert-True ($observedB.sha256 -cne $observedC.sha256 -and $observedC.length -eq ($observedB.length + 1)) "one appended executable byte changes only the observed digest and length"
  Assert-True ($observedA.version -ceq "codex-cli 999.1.2" -and $observedB.version -ceq $observedA.version -and $observedC.version -ceq $observedA.version) "well-formed version changes are observational"

  $malformedVersionReads = [pscustomobject]@{ count = 0 }
  $malformedVersionReader = { param($Path) $malformedVersionReads.count++; return "not-a-codex-version" }.GetNewClosure()
  $code = Get-RefusalCode {
    & $module {
      param($Path, $Reader)
      Resolve-CodexBoundaryHarnessInternal -ExecutablePath $Path -VersionReader $Reader
    } $syntheticNative $malformedVersionReader
  }
  Assert-True ($code -ceq "codex-boundary-harness-version-unavailable" -and $malformedVersionReads.count -eq 1) "malformed reported version refuses after only the identity probe"
  $minimalEnvironment = & $module { param($Root) Get-CodexBoundaryMinimalEnvironment -FixtureRoot $Root } $testRoot
  $minimalKeys = @($minimalEnvironment.Keys)
  [Array]::Sort($minimalKeys, [StringComparer]::OrdinalIgnoreCase)
  $expectedMinimalKeys = @("APPDATA", "CODEX_HOME", "LOCALAPPDATA", "NO_COLOR", "PATH", "SystemRoot", "TEMP", "TERM", "TMP", "USERPROFILE", "WINDIR")
  [Array]::Sort($expectedMinimalKeys, [StringComparer]::OrdinalIgnoreCase)
  Assert-True (($minimalKeys -join "`n") -ceq ($expectedMinimalKeys -join "`n")) "behavioral child environment is an explicit closed set with no credential aliases"
  Write-Output "PASS codex boundary makes build identity observational while path/kind/version-shape discriminators fail closed"

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
  $fixturePath = Join-Path $PSScriptRoot "fixtures\codex-launch-boundary-surface-v1.txt"
  $surfaceSha = & $module { param($Harness) Assert-CodexBoundarySurface -Harness $Harness } $identity
  Assert-True ($surfaceSha -ceq $contract.surfaceFixtureSha256) "historical surface evidence retains its provenance digest"
  $surfaceText = [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes($fixturePath))
  Assert-True ($surfaceText.Contains("command: codex.exe exec --help", [StringComparison]::Ordinal)) "surface includes exec --help"
  Assert-True ($surfaceText.Contains("command: codex.exe features list", [StringComparison]::Ordinal)) "surface includes features list"
  Assert-True ($surfaceText.Contains("generated-file: codex_app_server_protocol.v2.schemas.json", [StringComparison]::Ordinal)) "surface includes aggregate protocol bundle"
  Assert-True ($surfaceText.Contains("generated-file: v2/ConfigReadResponse.json", [StringComparison]::Ordinal)) "surface includes build-emitted config schema"
  Assert-True ($surfaceText.Contains("generated-file: v2/PermissionProfileListResponse.json", [StringComparison]::Ordinal)) "surface includes build-emitted permission-profile schema"
  Assert-True ($surfaceText.Contains("generated-file: v2/WindowsSandboxReadinessResponse.json", [StringComparison]::Ordinal)) "surface includes readiness schema"

  $aggregateText = [Text.UTF8Encoding]::new($false, $true).GetString((
    Get-SurfaceDecodedPayload -Surface $surfaceText -Label "generated-file: codex_app_server_protocol.v2.schemas.json" -Kind file
  ))
  $aggregate = $aggregateText | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
  foreach ($typeName in $contract.referencedSchemaTypes) {
    Assert-True ($aggregate.definitions.Contains([string]$typeName)) "referenced schema type $typeName is captured"
  }
  $execHelp = [Text.UTF8Encoding]::new($false, $true).GetString((
    Get-SurfaceDecodedPayload -Surface $surfaceText -Label "command: codex.exe exec --help" -Kind stdout
  ))
  $featureText = [Text.UTF8Encoding]::new($false, $true).GetString((
    Get-SurfaceDecodedPayload -Surface $surfaceText -Label "command: codex.exe features list" -Kind stdout
  ))
  foreach ($token in $contract.emittedFlags) {
    Assert-True ($execHelp.Contains([string]$token, [StringComparison]::Ordinal)) "emitted argv token $token exists in exec help"
  }
  foreach ($key in $contract.emittedConfigKeys) {
    Assert-True ($aggregateText.Contains([string]$key, [StringComparison]::Ordinal)) "emitted config token $key exists in aggregate protocol vocabulary"
  }
  $featureOk = & $module {
    param($Text, $Expected) Assert-CodexBoundaryFeatureStatesInternal -FeatureText $Text -ExpectedStates $Expected
  } $featureText $contract.featureStates
  Assert-True $featureOk "effective feature state equals the pin"
  $networkProxyRow = [regex]::new(
    '^network_proxy(?<stageSpace>[^\S\r\n]+)experimental(?<valueSpace>[^\S\r\n]+)false$',
    [Text.RegularExpressions.RegexOptions]::Multiline -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant
  )
  Assert-True ($networkProxyRow.Matches($featureText).Count -eq 1) "feature drift control has one exact source row"
  $driftedFeatureText = $networkProxyRow.Replace(
    $featureText,
    'network_proxy${stageSpace}experimental${valueSpace}true'
  )
  $code = Get-RefusalCode {
    & $module {
      param($Text, $Expected) Assert-CodexBoundaryFeatureStatesInternal -FeatureText $Text -ExpectedStates $Expected
    } $driftedFeatureText $contract.featureStates
  }
  Assert-True ($code -ceq "codex-boundary-feature-state-drift") "feature drift reaches its exact discriminator"
  Write-Output "PASS codex boundary captures every command, feature, type, key, and flag it references"

  $semanticSurfaceText = [regex]::Replace(
    $surfaceText,
    '(?ms)^command: codex\.exe --version\n.*?^end-command\n',
    ''
  )
  $semanticSurfaceBytes = [Text.UTF8Encoding]::new($false).GetBytes($semanticSurfaceText)
  $semanticOk = & $module {
    param($Bytes) Assert-CodexBoundarySurfaceRequirements -Bytes $Bytes
  } $semanticSurfaceBytes
  Assert-True $semanticOk "historical non-version surface satisfies the semantic contract"
  $behaviorMutantText = Set-SurfaceDecodedPayload `
    -Surface $semanticSurfaceText `
    -Label "command: codex.exe exec --help" `
    -Before "--strict-config" `
    -After "--strict-confog"
  $code = Get-RefusalCode {
    & $module {
      param($Bytes) Assert-CodexBoundarySurfaceRequirements -Bytes $Bytes
    } ([Text.UTF8Encoding]::new($false).GetBytes($behaviorMutantText))
  }
  Assert-True ($code -ceq "codex-boundary-surface-drift") "required behavior mutant remains red"
  $malformedSurfaceBytes = [byte[]]$semanticSurfaceBytes.Clone()
  $malformedSurfaceBytes[0] = $malformedSurfaceBytes[0] -bxor 1
  $code = Get-RefusalCode {
    & $module {
      param($Bytes) Assert-CodexBoundarySurfaceRequirements -Bytes $Bytes
    } $malformedSurfaceBytes
  }
  Assert-True ($code -ceq "codex-boundary-surface-malformed") "malformed surface stream remains red"
  Write-Output "PASS codex boundary semantic admission kills behavior and malformed-stream mutants"

  $mutatedSurface = Join-Path $testRoot "mutated-surface.txt"
  [IO.File]::WriteAllBytes($mutatedSurface, [IO.File]::ReadAllBytes($fixturePath))
  $mutatedBytes = [IO.File]::ReadAllBytes($mutatedSurface)
  $mutatedBytes[0] = $mutatedBytes[0] -bxor 1
  [IO.File]::WriteAllBytes($mutatedSurface, $mutatedBytes)
  $liveReads = [pscustomobject]@{ count = 0 }
  $unusedLiveReader = { param($Harness) $liveReads.count++; return [IO.File]::ReadAllBytes($fixturePath) }.GetNewClosure()
  $code = Get-RefusalCode {
    & $module {
      param($Harness, $Path, $Expected, $Reader)
      Assert-CodexBoundarySurfaceInternal -Harness $Harness -FixturePath $Path -ExpectedSha256 $Expected -LiveSurfaceReader $Reader
    } $identity $mutatedSurface $contract.surfaceFixtureSha256 $unusedLiveReader
  }
  Assert-True ($code -ceq "codex-boundary-surface-drift" -and $liveReads.count -eq 0) "fixture mutation refuses before live probe"
  Write-Output "PASS codex boundary surface is byte-bound and mutation-sensitive"

  # Any reparse ancestor is rejected, while an ordinary path is accepted.
  $ordinaryRoot = Join-Path $testRoot "ordinary\child"
  [void][IO.Directory]::CreateDirectory($ordinaryRoot)
  $ordinaryResolved = & $module { param($Path) Resolve-CodexBoundaryRoot -LiteralPath $Path } $ordinaryRoot
  Assert-True ($ordinaryResolved -ceq (Get-Item -LiteralPath $ordinaryRoot).FullName) "ordinary root canonicalizes"

  $junctionTarget = Join-Path $testRoot "junction-target"
  [void][IO.Directory]::CreateDirectory((Join-Path $junctionTarget "normal-child"))
  $junctionPath = Join-Path $testRoot "junction-ancestor"
  [void](New-Item -ItemType Junction -Path $junctionPath -Target $junctionTarget)
  $code = Get-RefusalCode {
    & $module { param($Path) Resolve-CodexBoundaryRoot -LiteralPath $Path } (Join-Path $junctionPath "normal-child")
  }
  Assert-True ($code -ceq "codex-boundary-root-reparse-ancestor") "normal child beneath junction ancestor refuses"
  Remove-Item -LiteralPath $junctionPath -Force
  $junctionPath = $null
  Write-Output "PASS codex boundary rejects every reparse ancestor"

  # The canonical profile is built only from captured vocabulary and binds
  # enforcement, feature, isolated-home, and job-object fields.
  $readableRecord = & $module { param($Path) Get-CodexBoundaryRootRecord -LiteralPath $Path } $ordinaryRoot
  $writableRoot = Join-Path $testRoot "writable"
  [void][IO.Directory]::CreateDirectory($writableRoot)
  $profile = & $module {
    param($Harness, $Surface, $Readable, $Writable)
    New-CodexBoundaryProfileRecord -Harness $Harness -SurfaceSha256 $Surface -ReadableRoots @($Readable) -WritableRoot $Writable
  } $identity $surfaceSha $ordinaryRoot $writableRoot
  $profileKeys = @($profile.PSObject.Properties.Name)
  [Array]::Sort($profileKeys, [StringComparer]::Ordinal)
  $expectedProfileKeys = @(
    "argvTemplate", "descendantPolicy", "effectiveFeatureStates", "harness",
    "isolatedCodexHome", "networkPolicy", "profileSha256", "readableRoots",
    "schema", "surfaceFixtureSha256", "writableRoot"
  )
  Assert-True (($profileKeys -join "`n") -ceq ($expectedProfileKeys -join "`n")) "profile exact shape is closed"
  $configBytes = [Convert]::FromBase64String([string]$profile.isolatedCodexHome.files[0].contentBase64)
  $configText = [Text.UTF8Encoding]::new($false, $true).GetString($configBytes)
  Assert-True (([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($configBytes)).ToLowerInvariant()) -ceq [string]$profile.isolatedCodexHome.files[0].sha256) "isolated CODEX_HOME content digest binds exact bytes"
  foreach ($key in $contract.emittedConfigKeys) {
    Assert-True ($aggregateText.Contains([string]$key, [StringComparison]::Ordinal)) "profile key $key came from build vocabulary"
  }
  Assert-True (-not $configText.Contains("danger-full-access", [StringComparison]::Ordinal)) "profile never inherits hostile danger-full-access"
  $moduleSha = & $module { param($Record) Get-CodexBoundaryProfileSha256 -Record $Record } $profile
  Assert-True ($moduleSha -ceq $profile.profileSha256) "independent canonical digest equals module digest"

  foreach ($field in @($expectedProfileKeys | Where-Object { $_ -cne "profileSha256" })) {
    $clone = ($profile | ConvertTo-Json -Depth 100) | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
    if ($clone[$field] -is [string]) { $clone[$field] += "-drift" }
    elseif ($clone[$field] -is [Collections.IList]) { $clone[$field] += "drift" }
    else { $clone[$field]["digestMutation"] = $true }
    $changed = & $module { param($Record) Get-CodexBoundaryProfileSha256 -Record $Record } $clone
    Assert-True ($changed -cne $profile.profileSha256) "profile digest changes for $field"
  }
  Write-Output "PASS codex boundary canonical profile digest covers every material field"

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

  # Controller-owned job-object control: kill-on-close terminates the assigned
  # child, and no breakaway flag is enabled in the bound profile.
  $jobFixture = & $module { New-CodexBoundaryTempFixture -Purpose "job-control" }
  $jobProcess = $null
  $job = $null
  try {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.Environment.Clear()
    $jobEnvironment = & $module { param($Root) Get-CodexBoundaryMinimalEnvironment -FixtureRoot $Root } $jobFixture
    foreach ($entry in $jobEnvironment.GetEnumerator()) { $start.Environment[[string]$entry.Key] = [string]$entry.Value }
    foreach ($argument in @("-NoProfile", "-NonInteractive", "-Command", "Start-Sleep -Seconds 30")) { [void]$start.ArgumentList.Add($argument) }
    $jobProcess = [Diagnostics.Process]::new()
    $jobProcess.StartInfo = $start
    [void]$jobProcess.Start()
    $job = & $module { New-CodexBoundaryKillOnCloseJob }
    & $module { param($Handle, $Id) Add-CodexBoundaryProcessToJob -Job $Handle -ProcessId $Id } $job $jobProcess.Id
    $job.Dispose()
    $job = $null
    Assert-True ($jobProcess.WaitForExit(5000)) "kill-on-close terminates the assigned process"
    Assert-True ([string]$profile.descendantPolicy.breakaway -ceq "denied") "profile binds no-breakaway policy"
  } finally {
    if ($null -ne $job) { $job.Dispose() }
    if ($null -ne $jobProcess) {
      if (-not $jobProcess.HasExited) { $jobProcess.Kill($true); $jobProcess.WaitForExit() }
      $jobProcess.Dispose()
    }
    & $module { param($Root) Remove-CodexBoundaryTempFixture -LiteralPath $Root -Purpose "job-control" } $jobFixture
  }
  Write-Output "PASS P4 controller job object enforces kill-on-close with breakaway denied"
  Write-Output "FALLBACK #6720 trusted-static-extractor closed-packet pure-runner executor-adapter"
} finally {
  if ($null -ne $junctionPath -and (Test-Path -LiteralPath $junctionPath)) {
    $junctionItem = Get-Item -LiteralPath $junctionPath -Force
    if (-not $junctionItem.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
      throw "test junction cleanup identity mismatch"
    }
    Remove-Item -LiteralPath $junctionPath -Force
  }
  $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
  $cleanupItem = Get-Item -LiteralPath $resolvedTestRoot -Force -ErrorAction SilentlyContinue
  if ($null -ne $cleanupItem) {
    if ($cleanupItem.Parent.FullName.TrimEnd([IO.Path]::DirectorySeparatorChar) -cne $tempParent -or
        -not $cleanupItem.Name.StartsWith("chase-sets-6721-boundary-test-", [StringComparison]::Ordinal) -or
        $cleanupItem.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
      throw "test fixture cleanup identity mismatch"
    }
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
  }
}
