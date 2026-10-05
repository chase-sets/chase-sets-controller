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
  [object]$DispatchIssue,
  [ValidateSet('open','closed','tracking-only','not-candidate','unknown')]
  [string]$DispatchCandidateState = 'unknown',
  [ValidateSet('clear','terminal-park','attempt-ceiling','counsel','operator','todd','unknown')]
  [string]$DispatchAuthority = 'unknown',
  [string]$DispatchLogPath,
  [string]$RuntimeRoot = 'D:/Users/ToddS/Source/Repos/chase-sets/.orchestrator',
  [Parameter(DontShow)][switch]$Library,
  [Parameter(DontShow)]
  [string]$HistoricalDispatchLog,
  [Parameter(DontShow)]
  [string]$ReferenceRoot,
  [Parameter(DontShow)]
  [string]$InstalledReferenceRoot = (Join-Path $HOME ".claude/skills/milestone-orchestrator/references")
)

$ErrorActionPreference = "Stop"

function Test-DispatchCountInteger($Value) {
  return ($Value -is [int] -or $Value -is [long]) -and $Value -gt 0 -and $Value -le [int]::MaxValue
}

function Get-DispatchCountDecision($History, $Issue, [string]$CandidateState, [string]$Authority) {
  $result = [ordered]@{schemaVersion='dispatch-count-query/v1';issue=$Issue;state='UNKNOWN';action='NONE'
    reason='HISTORY_INVALID';dispatchCount=$null;decision=$null;finalReceiptIdentity=$null;applicationId=$null;requiresOrdinaryAdmission=$true}
  if (-not (Test-DispatchCountInteger $Issue) -or $History.complete -isnot [bool] -or -not $History.complete) {
    return [pscustomobject]$result
  }
  $count=0; $landed=$false; $decision=$null; $finalIdentity=$null
  $dispatches=@{}
  $decisionDispatchCount=0
  foreach ($entry in $History.rows) {
    $row=$entry.value
    if ($null -eq $row -or $row -isnot [pscustomobject] -or
        ($entry.raw -is [string] -and -not $entry.raw.TrimStart().StartsWith('{'))) { return [pscustomobject]$result }
    $hasDecision=$null -ne $row.PSObject.Properties['dispatchDecision']
    if ($null -eq $row.PSObject.Properties['kind'] -and -not $hasDecision) { continue }
    if ($row.kind -isnot [string]) { return [pscustomobject]$result }
    if ($row.kind -cnotin @('dispatch','landed') -and -not $hasDecision) { continue }
    $hasIssue=$null -ne $row.PSObject.Properties['issue']
    if (-not $hasDecision -and ($row.issue -is [int] -or $row.issue -is [long]) -and $row.issue -lt 1) { continue }
    if (($hasIssue -and -not (Test-DispatchCountInteger $row.issue)) -or ($hasDecision -and -not $hasIssue)) {
      return [pscustomobject]$result
    }
    if (-not $hasIssue -or $row.issue -ne $Issue) { continue }
    if ($row.kind -ceq 'dispatch') {
      $count++; $dispatches[$entry.rawSha256]=$row
      if ($null -ne $decision -and $row.lane -ceq $decision.lane -and $row.transcript -ceq $decision.transcript) {
        $decisionDispatchCount++
        if ($decisionDispatchCount -gt 1) { return [pscustomobject]$result }
      }
    }
    if ($row.kind -ceq 'landed') {
      if (-not (Test-DispatchCountInteger $row.pr) -or $row.head -isnot [string] -or $row.head -cnotmatch '^[a-f0-9]{40}$') {
        return [pscustomobject]$result
      }
      $landed=$true
    }
    if (-not $hasDecision) { continue }
    $d=$row.dispatchDecision
    if ($d -isnot [pscustomobject]) { return [pscustomobject]$result }
    $fields=@('schemaVersion','id','phase','count','lane','transcript')
    if ($d.phase -cne 'CLAIMED') { $fields+='dispatchReceiptIdentity' }
    if ($d.phase -cin @('FINAL','APPLYING','APPLIED')) { $fields+='disposition' }
    if ($d.phase -cin @('APPLYING','APPLIED')) { $fields+='finalReceiptIdentity' }
    $names=@($d.PSObject.Properties.Name)
    if (@($fields | Where-Object { $_ -cnotin $names }).Count -or @($names | Where-Object { $_ -cnotin $fields }).Count -or
        $d.schemaVersion -cne 'dispatch-count-decision/v1' -or $d.id -cne "dispatch-count-$Issue-v1" -or
        $d.phase -cnotin @('CLAIMED','ACKNOWLEDGED','FINAL','APPLYING','APPLIED') -or
        -not (Test-DispatchCountInteger $d.count) -or $d.count -lt 15 -or
        $d.lane -isnot [string] -or $d.lane -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$' -or
        $d.transcript -isnot [string] -or $d.transcript -cnotmatch '^[^\r\n]{1,1024}$') { return [pscustomobject]$result }
    $expectedKind=if ($d.phase -cin @('CLAIMED','ACKNOWLEDGED')) {'decision-filed'} else {'decision-resolved'}
    if ($row.kind -cne $expectedKind) { return [pscustomobject]$result }
    if ($d.phase -ceq 'CLAIMED') {
      if ($null -ne $decision -or $landed -or $d.count -ne $count) { return [pscustomobject]$result }
      $dispatches=@{}
    } else {
      if ($null -eq $decision -or $d.id -cne $decision.id -or $d.count -ne $decision.count -or
          $d.lane -cne $decision.lane -or $d.transcript -cne $decision.transcript) { return [pscustomobject]$result }
      $previous=@{ACKNOWLEDGED='CLAIMED';FINAL='ACKNOWLEDGED';APPLYING='FINAL';APPLIED='APPLYING'}
      if ($decision.phase -cne $previous[$d.phase]) { return [pscustomobject]$result }
      if ($d.dispatchReceiptIdentity -isnot [string] -or $d.dispatchReceiptIdentity -cnotmatch '^[a-f0-9]{64}$') { return [pscustomobject]$result }
      $dispatch=$dispatches[$d.dispatchReceiptIdentity]
      if ($decisionDispatchCount -ne 1 -or $null -eq $dispatch -or $dispatch.lane -cne $d.lane -or $dispatch.transcript -cne $d.transcript -or
          $dispatch.laneRole -cnotin @('planning','review')) { return [pscustomobject]$result }
      if ($d.phase -cne 'ACKNOWLEDGED' -and $d.dispatchReceiptIdentity -cne $decision.dispatchReceiptIdentity) { return [pscustomobject]$result }
      if ($d.phase -cin @('FINAL','APPLYING','APPLIED') -and $d.disposition -cnotin @('REPLAN','PARK')) { return [pscustomobject]$result }
      if ($d.phase -cin @('APPLYING','APPLIED') -and
          ($d.disposition -cne $decision.disposition -or $d.finalReceiptIdentity -cne $finalIdentity)) { return [pscustomobject]$result }
    }
    $decision=$d
    if ($d.phase -ceq 'FINAL') { $finalIdentity=$entry.rawSha256 }
  }
  $result.dispatchCount=$count; $result.decision=$decision; $result.finalReceiptIdentity=$finalIdentity
  if ($null -ne $decision -and $decision.phase -cin @('FINAL','APPLYING','APPLIED')) {
    $result.applicationId="$($decision.id)-$($decision.disposition.ToLowerInvariant())"
  }
  if ($CandidateState -cin @('closed','tracking-only','not-candidate')) {
    $result.state='INELIGIBLE'; $result.reason='NOT_PRE_DISPATCH_CANDIDATE'
  } elseif ($CandidateState -cne 'open' -or $Authority -ceq 'unknown') {
    $result.reason='ADMISSION_UNKNOWN'
  } elseif ($Authority -cne 'clear') {
    $result.state='AUTHORITY_HOLD'; $result.reason=$Authority
  } elseif ($landed) {
    $result.state='LANDED'; $result.reason='CANONICAL_LANDING'
  } elseif ($null -ne $decision) {
    $result.reason='EXISTING_DECISION'
    switch -CaseSensitive ($decision.phase) {
      { $_ -cin @('CLAIMED','ACKNOWLEDGED') } { $result.state='PENDING'; $result.action='RECONCILE_DECISION' }
      'FINAL' { $result.state='FINAL'; $result.action='CLAIM_APPLICATION' }
      'APPLYING' { $result.state='APPLYING'; $result.action='RECONCILE_APPLICATION' }
      'APPLIED' { $result.state='APPLIED' }
    }
  } elseif ($count -ge 15) {
    $result.state='DUE'; $result.action='CLAIM_DECISION'; $result.reason='DISPATCH_THRESHOLD'
  } else {
    $result.state='BELOW_THRESHOLD'; $result.reason='DISPATCH_THRESHOLD'
  }
  return [pscustomobject]$result
}

function Read-DispatchCountHistory([string]$Path, $PrefixHistory = $null) {
  $failure=[pscustomobject]@{complete=$false;rows=@();audit=@{bytes=0};reason='HISTORY_UNREADABLE'}
  $snapshot=$null
  try {
    if ($null -ne $PrefixHistory -and -not $PrefixHistory.complete) { return $PrefixHistory }
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    try {
      $length=$stream.Length
      $failure.audit.bytes=$length
      if ($length -gt 33554432) { $failure.reason='HISTORY_TRUNCATED'; return $failure }
      $prefixLength=if ($null -ne $PrefixHistory) { [long]$PrefixHistory.snapshotLength } else { 0L }
      $failure.reason='HISTORY_UNTERMINATED_OR_MOVED'
      if ($length -lt $prefixLength) { return $failure }
      $bytes=[byte[]]::new($length)
      $stream.ReadExactly($bytes,0,$bytes.Length)
      if ($stream.Length -lt $length -or ($length -gt 0 -and $bytes[-1] -ne 10)) { return $failure }
      # Appends after captured EOF are harmless; a short read or changed boundary is not.
      if ($length -gt 0) {
        [void]$stream.Seek($length-1,[IO.SeekOrigin]::Begin)
        if ($stream.ReadByte() -ne 10) { return $failure }
      }
    } finally { $stream.Dispose() }
    $hash=[Security.Cryptography.SHA256]::Create()
    try {
      if ($null -ne $PrefixHistory) {
        $prefixHash=[Convert]::ToHexString($hash.ComputeHash($bytes,0,$prefixLength)).ToLowerInvariant()
        if ($prefixHash -cne $PrefixHistory.snapshotHash -or ($prefixLength -gt 0 -and $bytes[$prefixLength-1] -ne 10)) { return $failure }
      }
      $snapshotHash=[Convert]::ToHexString($hash.ComputeHash($bytes)).ToLowerInvariant()
    } finally { $hash.Dispose() }
    # The shared strict parser still owns malformed/duplicate JSON and row caps.
    # Only the tail is parsed while the logger holds the append mutex.
    $snapshot=[IO.Path]::GetTempFileName()
    $copy=[IO.File]::OpenWrite($snapshot)
    try { $copy.Write($bytes,$prefixLength,$bytes.Length-$prefixLength) } finally { $copy.Dispose() }
    $prefixLines=if ($null -ne $PrefixHistory) { $PrefixHistory.snapshotLines } else { 0 }
    $tailLines=[IO.File]::ReadAllLines($snapshot).Length
    if ($prefixLines+$tailLines -gt 50000) { $failure.reason='HISTORY_TRUNCATED'; return $failure }
    $history=Read-ExactHeadReviewHistory -Path $snapshot
    if (-not $history.complete) { return $history }
    if ($null -ne $PrefixHistory) {
      foreach ($row in $history.rows) { $row.line+=$prefixLines }
      $history.rows=@($PrefixHistory.rows)+@($history.rows)
      $history.audit.rows+=$PrefixHistory.audit.rows
      $history.audit.parsedRows+=$PrefixHistory.audit.parsedRows
    }
    $history.audit.bytes=$length
    $history | Add-Member snapshotLength $length
    $history | Add-Member snapshotLines ($prefixLines+$tailLines)
    $history | Add-Member snapshotHash $snapshotHash
    return $history
  } catch { return $failure }
  finally { if ($null -ne $snapshot) { [IO.File]::Delete($snapshot) } }
}

if ($Library) { return }
if ($PSBoundParameters.ContainsKey('DispatchIssue')) {
  if ($DispatchIssue -is [string] -and $DispatchIssue -cmatch '^[1-9][0-9]{0,9}$') {
    $DispatchIssue=[long]$DispatchIssue
  }
  Import-Module (Join-Path $RuntimeRoot 'review-head-contract.psm1') -Force -DisableNameChecking
  $path=if ($DispatchLogPath) {$DispatchLogPath} else {Join-Path $RuntimeRoot 'dispatch-log.jsonl'}
  $history=Read-DispatchCountHistory $path
  Get-DispatchCountDecision $history $DispatchIssue $DispatchCandidateState $DispatchAuthority | ConvertTo-Json -Depth 6
  return
}
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
