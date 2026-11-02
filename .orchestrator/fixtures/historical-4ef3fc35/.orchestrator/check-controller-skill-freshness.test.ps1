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
    "milestone-orchestrator/agents/openai.yaml"
  )
  foreach ($relative in $relativeFiles) {
    foreach ($root in @($source, $destination)) {
      $path = Join-Path $root $relative
      New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
      Set-Content -LiteralPath $path -Value "same:$relative"
    }
  }

  $script = Join-Path $PSScriptRoot "check-controller-skill-freshness.ps1"
  & pwsh -NoProfile -NonInteractive -File $script -SourceRoot $source -DestinationRoot $destination | Out-Null
  Assert-True ($LASTEXITCODE -eq 0) "matching trees should pass"

  Set-Content -LiteralPath (Join-Path $destination "milestone-orchestrator/SKILL.md") -Value "stale"
  $output = @(
    & pwsh -NoProfile -NonInteractive -File $script -SourceRoot $source -DestinationRoot $destination -Json
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
  & pwsh -NoProfile -NonInteractive -File $script -SourceRoot $source -DestinationRoot $destination | Out-Null
  Assert-True ($LASTEXITCODE -eq 0) "declared text inventory should treat CRLF and LF as transport-equivalent"

  [IO.File]::WriteAllBytes(
    (Join-Path $destination "model-routing/SKILL.md"),
    [Text.UTF8Encoding]::new($false).GetBytes("alpha`nbeta changed`n")
  )
  & pwsh -NoProfile -NonInteractive -File $script -SourceRoot $source -DestinationRoot $destination | Out-Null
  Assert-True ($LASTEXITCODE -eq 2) "content changes after EOL normalization must remain stale"

  Import-Module (Join-Path $PSScriptRoot "controller-install-lock.psm1") -Force -DisableNameChecking
  $payload = [byte[]](0,13,10,255,13,65,10)
  $payloadNormalized = Get-ControllerTransportNormalizedBytes -Bytes $payload -TransportText $false
  Assert-True ([Linq.Enumerable]::SequenceEqual($payload, $payloadNormalized)) "non-text payload bytes must remain exact"

  Write-Output "PASS controller skill freshness including CRLF/LF transport equivalence and payload identity"
} finally {
  if (Test-Path -LiteralPath $sandbox) {
    Remove-Item -LiteralPath $sandbox -Recurse -Force
  }
}
