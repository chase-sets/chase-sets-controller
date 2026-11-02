$ErrorActionPreference = "Stop"

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "FAIL: $Message" }
}

$sandbox = Join-Path ([IO.Path]::GetTempPath()) "ledger-query-$([guid]::NewGuid().ToString('N'))"
try {
  New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
  @"
# Stall-gotcha ledger

## codex-stdin (first seen 2026-07-01)
Symptom: Codex waits for stdin.
Root cause: inherited stdin stays open.
Detection: output stops at the stdin banner.
Remedy: close stdin before launching Codex.
Standing rule: launcher.

## deploy-mask (first seen 2026-07-01)
Symptom: staging is stale.
Root cause: resolver job is mistaken for deploy.
Detection: inspect the executed deploy job.
Remedy: select the actual deploy job.
Standing rule: landing.
"@ | Set-Content -LiteralPath (Join-Path $sandbox "stall-gotchas.md") -Encoding utf8

  @"
# Defect-class ledger

## schema-without-migration (first bitten 2026-07-01)
Defect: runtime SQL references a column no migration creates.
Territory: Postgres schema and migration files.
Territory globs: bounded-contexts/*/support/migrations/**
Occurrences: one.
Guard issue: #1.
Constraint for dispatch prompts: Ship the migration with the schema consumer.
Structural guard: migration checker.

## css-only-regression (first bitten 2026-07-01)
Defect: responsive geometry is not exercised.
Territory: CSS and visual evidence.
Occurrences: one.
Constraint for dispatch prompts: Capture responsive evidence.
Structural guard: visual test.
"@ | Set-Content -LiteralPath (Join-Path $sandbox "defect-classes.md") -Encoding utf8

  $script = Join-Path $PSScriptRoot "query-ledgers.ps1"
  $query = @(
    & pwsh -NoProfile -NonInteractive -File $script `
      -ReferenceRoot $sandbox `
      -Mode implementation `
      -Text "Postgres schema change" `
      -Footprint "bounded-contexts/catalog/support/migrations/001.sql" `
      -Json
  ) -join "`n"
  Assert-True ($LASTEXITCODE -eq 0) "query should succeed"
  $result = $query | ConvertFrom-Json
  Assert-True ($result.resultCount -ge 1) "schema query should return a match"
  Assert-True ($result.entries[0].slug -eq "schema-without-migration") "schema entry should rank first"
  Assert-True ($result.entries[0].instruction -match "migration") "query should return the compact constraint"

  $auditText = @(
    & pwsh -NoProfile -NonInteractive -File $script `
      -ReferenceRoot $sandbox `
      -Audit `
      -Json
  ) -join "`n"
  Assert-True ($LASTEXITCODE -eq 0) "audit should succeed"
  $audit = $auditText | ConvertFrom-Json
  Assert-True ($audit.stallEntries -eq 2) "audit counts stall entries"
  Assert-True ($audit.defectEntries -eq 2) "audit counts defect entries"
  Assert-True ($audit.defectWithTerritoryGlobs -eq 1) "audit reports glob coverage"

  $fallbackText = @(
    & pwsh -NoProfile -NonInteractive -File $script `
      -InstalledReferenceRoot $sandbox `
      -Audit `
      -Json
  ) -join "`n"
  Assert-True ($LASTEXITCODE -eq 0) "source skill without mutable ledgers should use the installed reference root"
  $fallback = $fallbackText | ConvertFrom-Json
  Assert-True ($fallback.stallEntries -eq 2) "installed fallback counts stall entries"
  Assert-True ($fallback.defectEntries -eq 2) "installed fallback counts defect entries"

  Write-Output "PASS query-ledgers relevance and audit coverage"
} finally {
  if (Test-Path -LiteralPath $sandbox) {
    Remove-Item -LiteralPath $sandbox -Recurse -Force
  }
}
