<#
.SYNOPSIS
Return only the stall remedies and defect constraints relevant to a dispatch.

.EXAMPLE
./query-ledgers.ps1 -Mode implementation -Text "Postgres schema migration" -Footprint "bounded-contexts/catalog/**"

.EXAMPLE
./query-ledgers.ps1 -Audit -Json
#>
[CmdletBinding()]
param(
  [ValidateSet("dispatch", "implementation", "irreversible", "all")]
  [string]$Mode = "implementation",
  [string]$Text,
  [string]$QueryFile,
  [string[]]$Footprint = @(),
  [ValidateRange(1, 30)]
  [int]$MaxResults = 12,
  [switch]$Json,
  [switch]$Audit,
  [Parameter(DontShow)]
  [string]$HistoricalDispatchLog,
  [Parameter(DontShow)]
  [string]$ReferenceRoot,
  [Parameter(DontShow)]
  [string]$InstalledReferenceRoot = (Join-Path $HOME ".claude/skills/milestone-orchestrator/references")
)

$ErrorActionPreference = "Stop"
if ($HistoricalDispatchLog) {
  # Historical dispatch evidence only; this path never selects a model or writes.
  Import-Module (Join-Path $PSScriptRoot '../../../review-head-contract.psm1') -Force -DisableNameChecking
  $history = Read-ExactHeadReviewHistory -Path $HistoricalDispatchLog
  if (-not $history.complete) { throw "historical dispatch ledger refused: $($history.reason)" }
  $retired = @('gpt-5.6-luna','gpt-5.6-terra','gpt-5.6-sol','claude-opus-5') # historical read only
  $matched = @($history.rows | Where-Object {
    $v=$_.value
    $v.model -cin $retired -or $v.reviewerModel -cin $retired -or $v.authorModel -cin $retired
  }).Count
  [pscustomobject]@{schemaVersion='historical-dispatch-ledger-read/v1';complete=$true;rows=@($history.rows).Count;retiredRows=$matched} | ConvertTo-Json -Compress
  return
}
$referencePath = if ($ReferenceRoot) {
  [IO.Path]::GetFullPath($ReferenceRoot)
} else {
  $sourceReferencePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "../references"))
  $sourceLedgerCount = @(
    "stall-gotchas.md",
    "defect-classes.md"
  ).Where({
    Test-Path -LiteralPath (Join-Path $sourceReferencePath $_) -PathType Leaf
  }).Count
  if ($sourceLedgerCount -eq 0 -and $InstalledReferenceRoot) {
    [IO.Path]::GetFullPath($InstalledReferenceRoot)
  } else {
    # A partial source pair is malformed and must fail closed instead of
    # silently mixing source and installed ledger authority.
    $sourceReferencePath
  }
}

$fieldNames = @{
  stall = @("Symptom", "Root cause", "Detection", "Remedy", "Standing rule")
  defect = @(
    "Defect",
    "Territory",
    "Territory globs",
    "Occurrences",
    "Guard issue",
    "Constraint for dispatch prompts",
    "Structural guard"
  )
}

function Get-Field {
  param(
    [string]$Body,
    [string]$Name,
    [string[]]$AllNames
  )

  $next = (
    @($AllNames) +
      @(
        "Occurrence",
        "Occurrences",
        "Occurrence correction",
        "Recurrence",
        "Recurrence/correction",
        "Correction",
        "Review guidance",
        "Guard shape",
        "PREVENTION",
        "Observed",
        "Mechanism",
        "Disproven claim"
      ) |
      Sort-Object -Unique |
      ForEach-Object { [regex]::Escape($_) }
  ) -join "|"
  $pattern = (
    "(?ms)^$([regex]::Escape($Name)):\s*(.*?)" +
    "(?=^(?:$next)[^\r\n]*:|^\*\*CORRECTION|^\d{4}-\d{2}-\d{2}[^\r\n]*:|^\s*$|\z)"
  )
  $match = [regex]::Match($Body, $pattern)
  if (-not $match.Success) { return $null }
  return (($match.Groups[1].Value -replace "\s+", " ").Trim())
}

function Get-Family {
  param([string]$Slug, [string]$SearchText)

  $value = "$Slug $SearchText".ToLowerInvariant()
  $families = [ordered]@{
    "structural-guard" = "structural.guard|guard.*(?:scope|discover|exemption|idiom|partition|overbroad)"
    "evidence-authority" = "evidence|authority|provenance|golden"
    "provider-contract" = "provider|credential|webhook|registry|terraform|digitalocean|stripe"
    "heavy-verifier" = "heavy.verifier|node.verifier|vitest.wall.clock|host.memory"
    "e2e-seeding" = "e2e|playwright|seed|fixture"
    "telemetry-projection" = "telemetry|projection|snapshot|analytics"
    "workflow-advisory" = "workflow|advisory|terminalizer|cancellation"
    "lifecycle-state" = "lifecycle|state.machine|steady.state|retained.state"
    "schema-migration" = "schema|migration|sql|database|postgres"
    "concurrency-idempotency" = "concurr|idempoten|lost.update|retry.event|time.of.check"
    "launcher-runtime" = "dispatch|launcher|codex|claude|powershell|process|worktree|rebase"
  }
  foreach ($family in $families.GetEnumerator()) {
    if ($value -match $family.Value) { return $family.Key }
  }
  return "other"
}

function Get-CompactText {
  param(
    [string]$Value,
    [int]$MaxChars
  )

  if (-not $Value -or $Value.Length -le $MaxChars) { return $Value }
  $prefix = $Value.Substring(0, $MaxChars)
  $lastSpace = $prefix.LastIndexOf(" ")
  if ($lastSpace -gt [Math]::Floor($MaxChars * 0.7)) {
    $prefix = $prefix.Substring(0, $lastSpace)
  }
  return "$($prefix.TrimEnd()) … [abridged; see source entry]"
}

function Read-Ledger {
  param(
    [string]$Path,
    [ValidateSet("stall", "defect")]
    [string]$Kind
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "ledger query failed: missing $Path"
  }

  $raw = Get-Content -LiteralPath $Path -Raw
  $matches = [regex]::Matches($raw, "(?ms)^## (?!<)([^\r\n]+)\r?\n(.*?)(?=^## |\z)")
  foreach ($match in $matches) {
    $heading = $match.Groups[1].Value.Trim()
    $slug = ($heading -replace " \(.*$", "").Trim()
    $body = $match.Groups[2].Value
    $fields = [ordered]@{}
    foreach ($field in $fieldNames[$Kind]) {
      $fields[$field] = Get-Field -Body $body -Name $field -AllNames $fieldNames[$Kind]
    }
    $searchText = (@($slug, $heading) + @($fields.Values | Where-Object { $_ })) -join " "
    $line = (($raw.Substring(0, $match.Index) -split "\r?\n").Count)
    [pscustomobject]@{
      kind = $Kind
      slug = $slug
      heading = $heading
      retired = ($heading -match "(?i)retired|disproven")
      family = Get-Family -Slug $slug -SearchText $searchText
      source = [IO.Path]::GetFileName($Path)
      sourceLine = $line
      fields = [pscustomobject]$fields
      searchText = $searchText.ToLowerInvariant()
    }
  }
}

$stallPath = Join-Path $referencePath "stall-gotchas.md"
$defectPath = Join-Path $referencePath "defect-classes.md"
$stallEntries = @(Read-Ledger -Path $stallPath -Kind stall)
$defectEntries = @(Read-Ledger -Path $defectPath -Kind defect)
# Reviewed static additions remain separate from the machine-maintained pair.
# Keep the pair's partial/missing refusal intact; never replace its history.
$controllerDefects = if ($ReferenceRoot) { Join-Path $referencePath 'controller-defect-classes.md' }
  else { Join-Path $PSScriptRoot '../references/controller-defect-classes.md' }
$controllerEntries = @()
if (Test-Path -LiteralPath $controllerDefects -PathType Leaf) {
  $controllerEntries = @(Read-Ledger -Path $controllerDefects -Kind defect)
  $defectEntries += $controllerEntries
}

if ($Audit) {
  $duplicateSlugs = @(
    $stallEntries.slug |
      Where-Object { $defectEntries.slug -contains $_ } |
      Sort-Object -Unique
  )
  $auditResult = [ordered]@{
    schemaVersion = "ledger-query-audit/v1"
    stallEntries = $stallEntries.Count
    defectEntries = $defectEntries.Count
    duplicateSlugs = $duplicateSlugs
    defectWithTerritoryGlobs = @(
      $defectEntries | Where-Object { $_.fields."Territory globs" }
    ).Count
    defectMissingConstraint = @(
      $defectEntries | Where-Object { -not $_.fields."Constraint for dispatch prompts" }
    ).slug
    stallMissingRequiredFields = @(
      $stallEntries | ForEach-Object {
        $entry = $_
        $missing = @(
          $fieldNames.stall | Where-Object { -not $entry.fields.$_ }
        )
        if ($missing.Count -gt 0) {
          [ordered]@{ slug = $entry.slug; missing = $missing }
        }
      }
    )
  }
  if ($Json) {
    $auditResult | ConvertTo-Json -Depth 8
  } else {
    Write-Output "Ledger audit: $($auditResult.stallEntries) stall, $($auditResult.defectEntries) defect"
    Write-Output "Territory-glob coverage: $($auditResult.defectWithTerritoryGlobs)/$($auditResult.defectEntries)"
    Write-Output "Duplicate slugs: $($auditResult.duplicateSlugs.Count)"
    Write-Output "Defects missing constraints: $($auditResult.defectMissingConstraint.Count)"
    Write-Output "Stalls missing required fields: $($auditResult.stallMissingRequiredFields.Count)"
  }
  exit 0
}

$queryParts = @()
if ($Text) { $queryParts += $Text }
if ($QueryFile) {
  $resolvedQueryFile = [IO.Path]::GetFullPath($QueryFile)
  if (-not (Test-Path -LiteralPath $resolvedQueryFile -PathType Leaf)) {
    throw "ledger query failed: query file missing: $resolvedQueryFile"
  }
  $queryParts += Get-Content -LiteralPath $resolvedQueryFile -Raw
}
if ($Footprint.Count -gt 0) { $queryParts += ($Footprint -join " ") }
$query = ($queryParts -join " ").Trim().ToLowerInvariant()
if (-not $query) {
  throw "ledger query requires -Text, -QueryFile, or -Footprint"
}

$stopWords = @(
  "about", "after", "before", "change", "changes", "from", "have", "implementation",
  "into", "issue", "must", "should", "that", "their", "there", "these", "this",
  "through", "using", "when", "where", "which", "with", "work"
)
$tokens = @(
  [regex]::Matches($query, "[a-z0-9][a-z0-9._/-]{2,}") |
    ForEach-Object { $_.Value } |
    Where-Object { $_ -notin $stopWords } |
    Sort-Object -Unique
)

$candidates = switch ($Mode) {
  "dispatch" { @($stallEntries) + @($controllerEntries) }
  "implementation" { @($stallEntries) + @($defectEntries) }
  "irreversible" { @($stallEntries) + @($defectEntries) }
  "all" { @($stallEntries) + @($defectEntries) }
}
if ($Mode -ne "all") {
  $candidates = @($candidates | Where-Object { -not $_.retired })
}

$scored = foreach ($entry in $candidates) {
  $score = 0
  $matched = @()
  foreach ($token in $tokens) {
    if ($entry.searchText.Contains($token, [StringComparison]::Ordinal)) {
      $weight = if ($token.Contains("/") -or $token.Contains(".")) {
        5
      } elseif ($token.Length -ge 9) {
        3
      } elseif ($token.Length -ge 6) {
        2
      } else {
        1
      }
      $score += $weight
      $matched += $token
    }
  }
  if ($Mode -eq "irreversible" -and $entry.searchText -match "provider|terraform|destroy|credential|deploy|migration|schema|secret") {
    $score += 4
    $matched += "irreversible-domain"
  }
  if ($score -ge 2) {
    $instructionRaw = if ($entry.kind -eq "defect") {
      $entry.fields."Constraint for dispatch prompts"
    } else {
      $entry.fields.Remedy
    }
    $guardRaw = if ($entry.kind -eq "defect") {
      $entry.fields."Structural guard"
    } else {
      $entry.fields."Standing rule"
    }
    [pscustomobject]@{
      score = $score
      kind = $entry.kind
      family = $entry.family
      slug = $entry.slug
      matched = @($matched | Sort-Object -Unique)
      instruction = Get-CompactText -Value $instructionRaw -MaxChars 700
      guard = Get-CompactText -Value $guardRaw -MaxChars 280
      source = $entry.source
      sourceLine = $entry.sourceLine
    }
  }
}

$selected = @(
  $scored |
    Sort-Object @{ Expression = "score"; Descending = $true }, kind, family, slug |
    Select-Object -First $MaxResults
)

$result = [ordered]@{
  schemaVersion = "ledger-query-result/v1"
  mode = $Mode
  queryTokens = $tokens
  resultCount = $selected.Count
  truncated = $scored.Count -gt $selected.Count
  entries = $selected
}

if ($Json) {
  $result | ConvertTo-Json -Depth 8
  exit 0
}

if ($selected.Count -eq 0) {
  Write-Output "No ledger entry met the relevance threshold. Refine -Text/-Footprint or use rg on the ledgers for a named domain."
  exit 0
}

Write-Output "Relevant ledger constraints ($($selected.Count)$(if ($result.truncated) { ', truncated' } else { '' })):"
foreach ($entry in $selected) {
  Write-Output ""
  Write-Output "- [$($entry.kind)/$($entry.family)] $($entry.slug) (score $($entry.score); $($entry.source):$($entry.sourceLine))"
  if ($entry.instruction) { Write-Output "  Constraint: $($entry.instruction)" }
  if ($entry.guard) { Write-Output "  Guard: $($entry.guard)" }
}
