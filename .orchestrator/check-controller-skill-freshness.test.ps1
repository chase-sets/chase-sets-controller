$ErrorActionPreference = "Stop"

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "FAIL: $Message" }
}

$sandbox = Join-Path ([IO.Path]::GetTempPath()) "controller-freshness-$([guid]::NewGuid().ToString('N'))"
try {
  $source = Join-Path $sandbox "source"
  $destination = Join-Path $sandbox "destination"
  $relativeFiles = @(
    "model-routing/SKILL.md",
    "model-routing/references/capability-recalibration.md",
    "model-routing/references/experiments.md",
    "model-routing/agents/openai.yaml",
    "milestone-orchestrator/SKILL.md",
    "milestone-orchestrator/references/rule-provenance-v2.24.md",
    "milestone-orchestrator/references/controller-defect-classes.md",
    "milestone-orchestrator/scripts/query-ledgers.ps1",
    "milestone-orchestrator/scripts/query-ledgers.test.ps1",
    "milestone-orchestrator/agents/openai.yaml",
    "orchestrator-shared/SKILL.md",
    "orchestrator-shared/agents/openai.yaml"
  )
  foreach ($relative in $relativeFiles) {
    foreach ($root in @($source, $destination)) {
      $path = Join-Path $root $relative
      New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
      Set-Content -LiteralPath $path -Value "same:$relative"
    }
  }

  $script = Join-Path $PSScriptRoot "check-controller-skill-freshness.ps1"
  & pwsh -NoProfile -NonInteractive -File $script -SourceRoot $source -DestinationRoot $destination -SkipRemote | Out-Null
  Assert-True ($LASTEXITCODE -eq 0) "matching trees should pass"

  Set-Content -LiteralPath (Join-Path $destination "milestone-orchestrator/SKILL.md") -Value "stale"
  $output = @(
    & pwsh -NoProfile -NonInteractive -File $script -SourceRoot $source -DestinationRoot $destination -SkipRemote -Json
  ) -join "`n"
  Assert-True ($LASTEXITCODE -eq 2) "stale file should fail"
  $result = $output | ConvertFrom-Json
  Assert-True ($result.status -eq "stale") "stale result is explicit"
  Assert-True ($result.mismatches[0].relative -eq "milestone-orchestrator/SKILL.md") "mismatch identifies the file"

  foreach ($relative in $relativeFiles) {
    $sourcePath = Join-Path $source $relative
    $destinationPath = Join-Path $destination $relative
    $lf = [Text.UTF8Encoding]::new($false).GetBytes("alpha`nbeta`n")
    $crlf = [Text.UTF8Encoding]::new($false).GetBytes("alpha`r`nbeta`r`n")
    [IO.File]::WriteAllBytes($sourcePath, $crlf)
    [IO.File]::WriteAllBytes($destinationPath, $lf)
  }
  & pwsh -NoProfile -NonInteractive -File $script -SourceRoot $source -DestinationRoot $destination -SkipRemote | Out-Null
  Assert-True ($LASTEXITCODE -eq 0) "declared text inventory should treat CRLF and LF as transport-equivalent"

  [IO.File]::WriteAllBytes(
    (Join-Path $destination "model-routing/SKILL.md"),
    [Text.UTF8Encoding]::new($false).GetBytes("alpha`nbeta changed`n")
  )
  & pwsh -NoProfile -NonInteractive -File $script -SourceRoot $source -DestinationRoot $destination -SkipRemote | Out-Null
  Assert-True ($LASTEXITCODE -eq 2) "content changes after EOL normalization must remain stale"

  Import-Module (Join-Path $PSScriptRoot "controller-install-lock.psm1") -Force -DisableNameChecking
  $payload = [byte[]](0,13,10,255,13,65,10)
  $payloadNormalized = Get-ControllerTransportNormalizedBytes -Bytes $payload -TransportText $false
  Assert-True ([Linq.Enumerable]::SequenceEqual($payload, $payloadNormalized)) "non-text payload bytes must remain exact"

  # --- release reporting ------------------------------------------------
  foreach ($relative in $relativeFiles) {
    foreach ($root in @($source, $destination)) { Set-Content -LiteralPath (Join-Path $root $relative) -Value "same:$relative" }
  }
  $publisher = Join-Path $sandbox "publisher"
  New-Item -ItemType Directory -Path $publisher -Force | Out-Null
  & git -C $publisher init -b main --quiet
  & git -C $publisher -c user.email=freshness@example.invalid -c user.name=freshness commit -q --allow-empty -m "release"
  foreach ($tag in @("controller-v1.2", "controller-v1.10", "controller-v1.9.3")) {
    & git -C $publisher -c user.email=freshness@example.invalid -c user.name=freshness tag -a $tag -m $tag
  }
  & git -C $publisher tag "unrelated-v9.9"
  $publisherHead = (& git -C $publisher rev-parse HEAD).Trim()
  New-Item -ItemType Directory -Path (Join-Path $destination "native-db") -Force | Out-Null
  $releaseRecord = Join-Path $destination "native-db/release.json"
  Set-Content -LiteralPath $releaseRecord -Value (@{ schemaVersion = "controller-release/v1"; tag = "controller-v1.2"; commit = $publisherHead } | ConvertTo-Json -Compress)
  function Invoke-Release([string[]]$Extra) {
    $text = @(& pwsh -NoProfile -NonInteractive -File $script -SourceRoot $source -DestinationRoot $destination -ContainerRoot $publisher -Json @Extra) -join "`n"
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Result = ($text | ConvertFrom-Json) }
  }
  $behind = Invoke-Release @("-ReleaseRepository", $publisher)
  Assert-True ($behind.ExitCode -eq 0 -and $behind.Result.status -eq "current") "an available update never changes the file verdict or exit code"
  Assert-True ($behind.Result.release.installed -ceq "controller-v1.2" -and $behind.Result.release.installedCommit -ceq $publisherHead) "installed release comes from the release record"
  Assert-True ($behind.Result.release.newest -ceq "controller-v1.10") "newest release is ordered by version, not text: $($behind.Result.release.newest)"
  Assert-True ($behind.Result.release.updateAvailable -eq $true -and $behind.Result.release.containerHead -ceq $publisherHead) "update availability and container head are reported"

  Set-Content -LiteralPath $releaseRecord -Value (@{ schemaVersion = "controller-release/v1"; tag = "controller-v1.10"; commit = $publisherHead } | ConvertTo-Json -Compress)
  $currentRelease = Invoke-Release @("-ReleaseRepository", $publisher)
  Assert-True ($currentRelease.Result.release.updateAvailable -eq $false) "the newest installed release reports no update"

  $offline = Invoke-Release @("-ReleaseRepository", (Join-Path $sandbox "missing-repository"))
  Assert-True ($offline.ExitCode -eq 0 -and $offline.Result.release.remoteError -and $null -eq $offline.Result.release.newest -and
    $offline.Result.release.updateAvailable -eq $false) "an unreadable release repository is reported, never a failure"

  Remove-Item -LiteralPath $releaseRecord -Force
  $unrecorded = Invoke-Release @("-ReleaseRepository", $publisher)
  Assert-True ($null -eq $unrecorded.Result.release.installed -and $unrecorded.Result.release.updateAvailable -eq $true) "a missing release record means no installed release, so any release is an update"
  $skipped = Invoke-Release @("-SkipRemote")
  Assert-True ($null -eq $skipped.Result.release.newest -and $null -eq $skipped.Result.release.remoteError) "-SkipRemote reads no remote"

  Write-Output "PASS controller skill freshness including CRLF/LF transport equivalence, payload identity and release reporting"
} finally {
  if (Test-Path -LiteralPath $sandbox) {
    Remove-Item -LiteralPath $sandbox -Recurse -Force
  }
}
