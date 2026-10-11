$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "premise-freshness.ps1")

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Copy-Fixture($Value) {
  return $Value | ConvertTo-Json -Depth 20 | ConvertFrom-Json -DateKind String
}

function New-Pagination([object[]]$Items, [int]$PageCount = 1) {
  [pscustomobject][ordered]@{
    pagination = [pscustomobject][ordered]@{
      schemaVersion = "github-pagination/v1"
      mode = "all-pages"
      complete = $true
      truncated = $false
      pageCount = $PageCount
      itemCount = @($Items).Count
    }
    items = @($Items)
  }
}

function New-Comment(
  [long]$Id,
  [string]$Body,
  [string]$Author,
  [string]$CreatedAt,
  [string]$UpdatedAt = $CreatedAt
) {
  [pscustomobject][ordered]@{
    id = $Id
    html_url = "https://github.com/chase-sets/chase-sets/issues/6761#issuecomment-$Id"
    body = $Body
    user = [pscustomobject][ordered]@{ login = $Author }
    created_at = $CreatedAt
    updated_at = $UpdatedAt
  }
}

function New-BodyEdit([string]$Actor, [string]$CreatedAt) {
  [pscustomobject][ordered]@{
    id = 9100
    html_url = "https://github.com/chase-sets/chase-sets/issues/6761#event-9100"
    field = "body"
    actor = [pscustomobject][ordered]@{ login = $Actor }
    created_at = $CreatedAt
  }
}

function New-SupersedingDecision([string]$Actor, [string]$LinkedAt) {
  [pscustomobject][ordered]@{
    issueNumber = 6990
    html_url = "https://github.com/chase-sets/chase-sets/issues/6990"
    linked_at = $LinkedAt
    linkedBy = [pscustomobject][ordered]@{ login = $Actor }
    supersedes = [pscustomobject][ordered]@{
      repository = "chase-sets/chase-sets"
      issueNumber = 6761
    }
  }
}

function New-Candidate(
  [string]$AnalysisInstant = "2026-08-13T14:58:00Z",
  [string]$FilingInstant = "2026-08-13T15:04:19Z"
) {
  [pscustomobject][ordered]@{
    decision = [pscustomobject][ordered]@{
      repository = "chase-sets/chase-sets"
      issueNumber = 6819
      filingInstant = $FilingInstant
    }
    analysisInstant = $AnalysisInstant
    premiseRules = @([pscustomobject][ordered]@{
        name = "decision #6761 ops rules"
        repository = "chase-sets/chase-sets"
        issueNumber = 6761
      })
  }
}

function New-Authority(
  [object[]]$Comments = @(),
  [object[]]$BodyEdits = @(),
  [object[]]$SupersedingDecisions = @()
) {
  [pscustomobject][ordered]@{
    schemaVersion = "premise-freshness-authority/v1"
    available = $true
    repository = [pscustomobject][ordered]@{
      nameWithOwner = "chase-sets/chase-sets"
    }
    repositoryOwner = [pscustomobject][ordered]@{ login = "todd-skelton" }
    premiseRule = [pscustomobject][ordered]@{
      name = "decision #6761 ops rules"
      repository = "chase-sets/chase-sets"
      issueNumber = 6761
    }
    issue = [pscustomobject][ordered]@{
      number = 6761
      html_url = "https://github.com/chase-sets/chase-sets/issues/6761"
    }
    comments = New-Pagination $Comments 2
    bodyEdits = New-Pagination $BodyEdits
    supersedingDecisions = New-Pagination $SupersedingDecisions
  }
}

function Invoke-Check($Candidate, $Authority) {
  $candidateCopy = Copy-Fixture $Candidate
  $authorityCopy = Copy-Fixture $Authority
  $provider = { param($Rule) return $authorityCopy }.GetNewClosure()
  return Invoke-PremiseFreshnessCheck -Candidate $candidateCopy -AuthorityProvider $provider
}

function Invoke-Test([string]$Name, [scriptblock]$Test) {
  & $Test
  Write-Output "PASS $Name"
}

function New-PublicRequest {
  [pscustomobject][ordered]@{
    schemaVersion = "premise-freshness-request/v1"
    candidate = Copy-Fixture (New-Candidate)
    authority = @((Copy-Fixture (New-Authority)))
  }
}

function Invoke-PublicRequestJson([string]$RequestJson) {
  $predicate = (Resolve-Path (Join-Path $PSScriptRoot "premise-freshness.ps1")).Path
  $output = @(& pwsh -NoProfile -NonInteractive -File $predicate -RequestJson $requestJson 2>&1)
  $exitCode = $LASTEXITCODE
  $result = ($output -join "`n") | ConvertFrom-Json -DateKind String
  return [pscustomobject]@{ exitCode = $exitCode; result = $result }
}

function Invoke-PublicRequestPath([string]$RequestPath) {
  $predicate = (Resolve-Path (Join-Path $PSScriptRoot "premise-freshness.ps1")).Path
  $output = @(& pwsh -NoProfile -NonInteractive -File $predicate -RequestPath $RequestPath 2>&1)
  $exitCode = $LASTEXITCODE
  $result = ($output -join "`n") | ConvertFrom-Json -DateKind String
  return [pscustomobject]@{ exitCode = $exitCode; result = $result }
}

function Invoke-PublicRequest($Request) {
  return Invoke-PublicRequestJson ($Request | ConvertTo-Json -Depth 20 -Compress)
}

function Replace-UniqueJsonText(
  [string]$Json,
  [string]$Needle,
  [string]$Replacement
) {
  $first = $Json.IndexOf($Needle, [StringComparison]::Ordinal)
  $last = $Json.LastIndexOf($Needle, [StringComparison]::Ordinal)
  if ($first -lt 0 -or $first -ne $last) {
    throw "test fixture marker must occur exactly once: $Needle"
  }
  return $Json.Substring(0, $first) + $Replacement +
    $Json.Substring($first + $Needle.Length)
}

function New-DeepObjectValue([int]$Layers, [string]$Leaf) {
  return ((('{"layer":' * $Layers) -join '') + $Leaf + (('}' * $Layers) -join ''))
}

function New-NestedArrayValue([int]$Levels, [string]$Leaf) {
  return ((('[' * $Levels) -join '') + $Leaf + ((']' * $Levels) -join ''))
}

function Assert-PublicRefusal([string]$Raw, [string]$Reason, [string]$Message) {
  $actual = Invoke-PublicRequestJson $Raw
  Assert-True (
    $actual.exitCode -eq 1 -and
    $actual.result.verdict -ceq "refuse" -and
    $actual.result.reason -ceq $Reason
  ) "$Message (exit=$($actual.exitCode) verdict=$($actual.result.verdict) reason=$($actual.result.reason))"
}

Invoke-Test "amendment after the analysis instant refuses adoption" {
  $comment = New-Comment -Id 5282120899 -Body "Amendment 5 (Todd working session): The rule is superseded." -Author "todd-skelton" -CreatedAt "2026-08-13T14:59:53Z"
  $result = Invoke-Check (New-Candidate) (New-Authority @($comment))
  Assert-True ($result.verdict -ceq "refuse" -and $result.reason -ceq "PREMISE_AMENDED_AFTER_ANALYSIS") "a later amendment must refuse with the stable reason"
  Assert-True ($result.evidence.premiseRule.issueNumber -eq 6761 -and $result.evidence.premiseRule.name -ceq "decision #6761 ops rules" -and $result.evidence.source.id -eq 5282120899 -and $result.evidence.source.htmlUrl -match "issuecomment-5282120899") "refusal must name the rule and exact comment"
}

Invoke-Test "filing after an amendment still refuses on the analysis instant" {
  # Real #6819 timing: Amendment 5 precedes filing by four minutes. The
  # synthetic analysis instant is deliberately earlier than both.
  $comment = New-Comment -Id 5282120899 -Body "## Amendment 5 — measured fixture" -Author "todd-skelton" -CreatedAt "2026-08-13T14:59:53Z"
  $candidate = New-Candidate "2026-08-13T14:58:00Z" "2026-08-13T15:04:19Z"
  $result = Invoke-Check $candidate (New-Authority @($comment))
  Assert-True ($result.verdict -ceq "refuse" -and $result.analysisInstant -ceq "2026-08-13T14:58:00.0000000+00:00" -and $result.evidence.timestamp -ceq "2026-08-13T14:59:53.0000000+00:00") "the persisted analysis instant, not the later filing instant, must control"
}

Invoke-Test "edited comment counts as an amendment" {
  $comment = New-Comment -Id 9001 -Body "Amendment 6 implementation clarification" -Author "todd-skelton" -CreatedAt "2026-08-13T12:00:00Z" -UpdatedAt "2026-08-13T15:01:00Z"
  $result = Invoke-Check (New-Candidate) (New-Authority @($comment))
  Assert-True ($result.verdict -ceq "refuse" -and $result.evidence.amendmentShape -ceq "edited-comment" -and $result.evidence.timestamp -ceq "2026-08-13T15:01:00.0000000+00:00") "updated_at must expose an amendment folded into an older comment"
}

Invoke-Test "only owner-authored comments amend a rule" {
  $nonOwnerAmendment = New-Comment -Id 9002 -Body "Amendment 7 by a worker" -Author "codex-worker" -CreatedAt "2026-08-13T15:01:00Z"
  $ownerProse = New-Comment -Id 9003 -Body "Cycle note: this prose mentions Amendment 7 but does not ratify one." -Author "todd-skelton" -CreatedAt "2026-08-13T15:02:00Z"
  $lowercase = New-Comment -Id 9004 -Body "amendment 8 is only a lowercase prose label" -Author "todd-skelton" -CreatedAt "2026-08-13T15:03:00Z"
  $result = Invoke-Check (New-Candidate) (New-Authority @($nonOwnerAmendment, $ownerProse, $lowercase))
  Assert-True ($result.verdict -ceq "adopt" -and $result.reason -ceq "PREMISES_FRESH") "non-owner authors and prose mentions must not acquire amendment authority"
}

Invoke-Test "repository owner identity governs every amendment shape" {
  $workerEdit = [pscustomobject][ordered]@{
    id = 9098
    html_url = "https://github.com/chase-sets/chase-sets/issues/6761#event-9098"
    field = "body"
    actor = [pscustomobject][ordered]@{ login = "codex-worker" }
    created_at = "2026-08-13T15:01:00Z"
  }
  $workerLink = [pscustomobject][ordered]@{
    issueNumber = 6989
    html_url = "https://github.com/chase-sets/chase-sets/issues/6989"
    linked_at = "2026-08-13T15:02:00Z"
    linkedBy = [pscustomobject][ordered]@{ login = "codex-worker" }
    supersedes = [pscustomobject][ordered]@{
      repository = "chase-sets/chase-sets"
      issueNumber = 6761
    }
  }
  $result = Invoke-Check (New-Candidate) (New-Authority -BodyEdits @($workerEdit) -SupersedingDecisions @($workerLink))
  Assert-True ($result.verdict -ceq "adopt") "a worker cannot ratify body edits or supersession links"
}

Invoke-Test "empty and whitespace comment actor identities are malformed" {
  foreach ($identity in @("", " `t ")) {
    $comment = New-Comment -Id 9096 -Body "Amendment 6 malformed actor" -Author $identity -CreatedAt "2026-08-13T15:01:00Z"
    $result = Invoke-Check (New-Candidate) (New-Authority -Comments @($comment))
    Assert-True ($result.verdict -ceq "refuse" -and $result.reason -ceq "AUTHORITY_MALFORMED") "a blank comment user.login must fail closed"
  }
}

Invoke-Test "empty and whitespace body-edit actor identities are malformed" {
  foreach ($identity in @("", " `t ")) {
    $result = Invoke-Check (New-Candidate) (New-Authority -BodyEdits @(
        (New-BodyEdit -Actor $identity -CreatedAt "2026-08-13T15:01:00Z")
      ))
    Assert-True ($result.verdict -ceq "refuse" -and $result.reason -ceq "AUTHORITY_MALFORMED") "a blank body-edit actor.login must fail closed"
  }
}

Invoke-Test "empty and whitespace supersession actor identities are malformed" {
  foreach ($identity in @("", " `t ")) {
    $result = Invoke-Check (New-Candidate) (New-Authority -SupersedingDecisions @(
        (New-SupersedingDecision -Actor $identity -LinkedAt "2026-08-13T15:02:00Z")
      ))
    Assert-True ($result.verdict -ceq "refuse" -and $result.reason -ceq "AUTHORITY_MALFORMED") "a blank supersession linkedBy.login must fail closed"
  }
}

Invoke-Test "missing null and non-string actor identities are malformed" {
  foreach ($variant in @("missing", "null", "non-string")) {
    $comment = New-Comment -Id 9097 -Body "Amendment 7 malformed actor shape" -Author "placeholder" -CreatedAt "2026-08-13T15:01:00Z"
    $edit = New-BodyEdit -Actor "placeholder" -CreatedAt "2026-08-13T15:01:00Z"
    $link = New-SupersedingDecision -Actor "placeholder" -LinkedAt "2026-08-13T15:02:00Z"
    foreach ($actor in @($comment.user, $edit.actor, $link.linkedBy)) {
      if ($variant -ceq "missing") {
        $actor.PSObject.Properties.Remove("login")
      } elseif ($variant -ceq "null") {
        $actor.login = $null
      } else {
        $actor.login = 42
      }
    }
    foreach ($authority in @(
        (New-Authority -Comments @($comment)),
        (New-Authority -BodyEdits @($edit)),
        (New-Authority -SupersedingDecisions @($link))
      )) {
      $result = Invoke-Check (New-Candidate) $authority
      Assert-True ($result.verdict -ceq "refuse" -and $result.reason -ceq "AUTHORITY_MALFORMED") "$variant actor identities must fail closed for every amendment shape"
    }
  }
}

Invoke-Test "premise-rule body edit is an amendment shape" {
  $edit = [pscustomobject][ordered]@{
    id = 9100
    html_url = "https://github.com/chase-sets/chase-sets/issues/6761#event-9100"
    field = "body"
    actor = [pscustomobject][ordered]@{ login = "todd-skelton" }
    created_at = "2026-08-13T15:01:00Z"
  }
  $result = Invoke-Check (New-Candidate) (New-Authority -BodyEdits @($edit))
  Assert-True ($result.verdict -ceq "refuse" -and $result.evidence.amendmentShape -ceq "premise-rule-body-edit" -and $result.evidence.source.id -eq 9100) "an owner-performed premise body edit after analysis must refuse"
}

Invoke-Test "owner body edits are governed by the analysis instant" {
  $preAnalysisEdit = [pscustomobject][ordered]@{
    id = 9101
    html_url = "https://github.com/chase-sets/chase-sets/issues/6761#event-9101"
    field = "body"
    actor = [pscustomobject][ordered]@{ login = "todd-skelton" }
    created_at = "2026-08-12T09:00:00Z"
  }
  $preAnalysis = Invoke-Check (New-Candidate) (New-Authority -BodyEdits @($preAnalysisEdit))
  Assert-True ($preAnalysis.verdict -ceq "adopt" -and $preAnalysis.reason -ceq "PREMISES_FRESH") "an owner body edit before analysis must not be treated as a later amendment"

  $postAnalysisEdit = Copy-Fixture $preAnalysisEdit
  $postAnalysisEdit.id = 9102
  $postAnalysisEdit.created_at = "2026-08-13T15:01:00Z"
  $postAnalysis = Invoke-Check (New-Candidate) (New-Authority -BodyEdits @($postAnalysisEdit))
  Assert-True ($postAnalysis.verdict -ceq "refuse" -and $postAnalysis.reason -ceq "PREMISE_AMENDED_AFTER_ANALYSIS" -and $postAnalysis.evidence.amendmentShape -ceq "premise-rule-body-edit") "an owner body edit after analysis must still refuse"
}

Invoke-Test "linked superseding decision is an amendment shape" {
  $link = [pscustomobject][ordered]@{
    issueNumber = 6990
    html_url = "https://github.com/chase-sets/chase-sets/issues/6990"
    linked_at = "2026-08-13T15:02:00Z"
    linkedBy = [pscustomobject][ordered]@{ login = "todd-skelton" }
    supersedes = [pscustomobject][ordered]@{
      repository = "chase-sets/chase-sets"
      issueNumber = 6761
    }
  }
  $result = Invoke-Check (New-Candidate) (New-Authority -SupersedingDecisions @($link))
  Assert-True ($result.verdict -ceq "refuse" -and $result.evidence.amendmentShape -ceq "linked-superseding-decision" -and $result.evidence.source.issueNumber -eq 6990) "an owner-linked structured superseding decision must refuse"
}

Invoke-Test "owner superseding links are governed by the analysis instant" {
  $preAnalysisLink = [pscustomobject][ordered]@{
    issueNumber = 6991
    html_url = "https://github.com/chase-sets/chase-sets/issues/6991"
    linked_at = "2026-08-10T09:00:00Z"
    linkedBy = [pscustomobject][ordered]@{ login = "todd-skelton" }
    supersedes = [pscustomobject][ordered]@{
      repository = "chase-sets/chase-sets"
      issueNumber = 6761
    }
  }
  $preAnalysis = Invoke-Check (New-Candidate) (New-Authority -SupersedingDecisions @($preAnalysisLink))
  Assert-True ($preAnalysis.verdict -ceq "adopt" -and $preAnalysis.reason -ceq "PREMISES_FRESH") "an owner superseding link before analysis must not be treated as a later amendment"

  $postAnalysisLink = Copy-Fixture $preAnalysisLink
  $postAnalysisLink.issueNumber = 6992
  $postAnalysisLink.linked_at = "2026-08-13T15:02:00Z"
  $postAnalysis = Invoke-Check (New-Candidate) (New-Authority -SupersedingDecisions @($postAnalysisLink))
  Assert-True ($postAnalysis.verdict -ceq "refuse" -and $postAnalysis.reason -ceq "PREMISE_AMENDED_AFTER_ANALYSIS" -and $postAnalysis.evidence.amendmentShape -ceq "linked-superseding-decision") "an owner superseding link after analysis must still refuse"
}

Invoke-Test "amendment exactly at the analysis instant is not later" {
  $comment = New-Comment -Id 9005 -Body "Amendment 9 boundary" -Author "todd-skelton" -CreatedAt "2026-08-13T14:58:00Z"
  $result = Invoke-Check (New-Candidate) (New-Authority @($comment))
  Assert-True ($result.verdict -ceq "adopt") "the contract's later-than comparison must be strict"
}

Invoke-Test "candidate instants require the exact v1 ISO profile" {
  $nonIsoInstants = @(
    "2026-08-13 14:58:00Z",
    "08/13/2026 14:58:00Z",
    "August 13, 2026 14:58:00Z",
    "2026-8-13T14:58:00Z",
    " 2026-08-13T14:58:00Z",
    "2026-08-13T14:58:00Z ",
    "2026-08-13T14:58:00.12345678Z"
  )
  foreach ($instant in $nonIsoInstants) {
    $badAnalysis = Invoke-Check (New-Candidate -AnalysisInstant $instant) (New-Authority)
    Assert-True ($badAnalysis.verdict -ceq "refuse" -and $badAnalysis.reason -ceq "REQUEST_MALFORMED") "analysisInstant must reject non-ISO input: $instant"

    $badFiling = Invoke-Check (New-Candidate -FilingInstant $instant) (New-Authority)
    Assert-True ($badFiling.verdict -ceq "refuse" -and $badFiling.reason -ceq "REQUEST_MALFORMED") "decision.filingInstant must reject non-ISO input: $instant"
  }
}

Invoke-Test "authority instants require the exact v1 ISO profile" {
  $nonIsoInstant = "2026-08-13 15:01:00Z"
  $badCreated = New-Comment -Id 9110 -Body "Amendment 10 malformed created time" -Author "todd-skelton" -CreatedAt $nonIsoInstant
  $createdResult = Invoke-Check (New-Candidate) (New-Authority -Comments @($badCreated))
  Assert-True ($createdResult.verdict -ceq "refuse" -and $createdResult.reason -ceq "AUTHORITY_MALFORMED") "comment created_at must reject a non-ISO instant"

  $badUpdated = New-Comment -Id 9111 -Body "Amendment 11 malformed updated time" -Author "todd-skelton" -CreatedAt "2026-08-13T15:00:00Z" -UpdatedAt $nonIsoInstant
  $updatedResult = Invoke-Check (New-Candidate) (New-Authority -Comments @($badUpdated))
  Assert-True ($updatedResult.verdict -ceq "refuse" -and $updatedResult.reason -ceq "AUTHORITY_MALFORMED") "comment updated_at must reject a non-ISO instant"

  $editResult = Invoke-Check (New-Candidate) (New-Authority -BodyEdits @(
      (New-BodyEdit -Actor "todd-skelton" -CreatedAt $nonIsoInstant)
    ))
  Assert-True ($editResult.verdict -ceq "refuse" -and $editResult.reason -ceq "AUTHORITY_MALFORMED") "body-edit created_at must reject a non-ISO instant"

  $linkResult = Invoke-Check (New-Candidate) (New-Authority -SupersedingDecisions @(
      (New-SupersedingDecision -Actor "todd-skelton" -LinkedAt $nonIsoInstant)
    ))
  Assert-True ($linkResult.verdict -ceq "refuse" -and $linkResult.reason -ceq "AUTHORITY_MALFORMED") "supersession linked_at must reject a non-ISO instant"
}

Invoke-Test "valid v1 ISO instants normalize to UTC" {
  $cases = @(
    @{ Instant = "2026-08-13T14:58:00Z"; Expected = "2026-08-13T14:58:00.0000000+00:00" },
    @{ Instant = "2026-08-13T16:58:00+02:00"; Expected = "2026-08-13T14:58:00.0000000+00:00" },
    @{ Instant = "2026-08-13T09:28:00-05:30"; Expected = "2026-08-13T14:58:00.0000000+00:00" },
    @{ Instant = "2026-08-13T14:58:00.1Z"; Expected = "2026-08-13T14:58:00.1000000+00:00" },
    @{ Instant = "2026-08-13T16:58:00.1234567+02:00"; Expected = "2026-08-13T14:58:00.1234567+00:00" }
  )
  foreach ($case in $cases) {
    $result = Invoke-Check (New-Candidate -AnalysisInstant $case.Instant) (New-Authority)
    Assert-True ($result.verdict -ceq "adopt" -and $result.analysisInstant -ceq $case.Expected) "valid ISO instant must normalize deterministically: $($case.Instant)"
  }
}

Invoke-Test "ISO parsing and later-than comparison are culture independent" {
  $originalCulture = [Threading.Thread]::CurrentThread.CurrentCulture
  try {
    foreach ($culture in @("en-US", "tr-TR", "fr-FR")) {
      [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo($culture)
      $comment = New-Comment -Id 9112 -Body "Amendment 12 culture control" -Author "TODD-SKELTON" -CreatedAt "2026-08-13T15:00:00Z"
      $candidate = New-Candidate -AnalysisInstant "2026-08-13T09:58:00-05:00" -FilingInstant "2026-08-13T10:04:19-05:00"
      $result = Invoke-Check $candidate (New-Authority -Comments @($comment))
      Assert-True ($result.verdict -ceq "refuse" -and $result.reason -ceq "PREMISE_AMENDED_AFTER_ANALYSIS") "valid offset comparison must be invariant in $culture"
    }
  } finally {
    [Threading.Thread]::CurrentThread.CurrentCulture = $originalCulture
  }
}

Invoke-Test "earliest later amendment supplies deterministic evidence" {
  $later = New-Comment -Id 9006 -Body "Amendment 11 later" -Author "todd-skelton" -CreatedAt "2026-08-13T15:03:00Z"
  $earlier = New-Comment -Id 9007 -Body "Amendment 10 earlier" -Author "todd-skelton" -CreatedAt "2026-08-13T15:01:00Z"
  $result = Invoke-Check (New-Candidate) (New-Authority @($later, $earlier))
  Assert-True ($result.evidence.source.id -eq 9007) "evidence selection must be stable and choose the earliest later event"
}

Invoke-Test "unavailable authority fails closed to refuse" {
  $candidate = Copy-Fixture (New-Candidate)
  $throwingProvider = { param($Rule) throw "synthetic transport unavailable" }
  $unavailable = Invoke-PremiseFreshnessCheck -Candidate $candidate -AuthorityProvider $throwingProvider
  Assert-True ($unavailable.verdict -ceq "refuse" -and $unavailable.reason -ceq "AUTHORITY_UNAVAILABLE") "a transport failure must refuse with a named reason"
  $nullProvider = Invoke-PremiseFreshnessCheck -Candidate $candidate -AuthorityProvider $null
  Assert-True ($nullProvider.verdict -ceq "refuse" -and $nullProvider.reason -ceq "AUTHORITY_UNAVAILABLE") "a missing injected transport must return a refusal rather than throw"

  $malformedAuthority = Copy-Fixture (New-Authority @((New-Comment -Id 9010 -Body "Amendment 12 malformed" -Author "todd-skelton" -CreatedAt "2026-08-13T15:01:00Z")))
  $malformedAuthority.comments.items[0].PSObject.Properties.Remove("updated_at")
  $malformed = Invoke-Check (New-Candidate) $malformedAuthority
  Assert-True ($malformed.verdict -ceq "refuse" -and $malformed.reason -ceq "AUTHORITY_MALFORMED") "a malformed exact comment field set must refuse"

  $truncatedAuthority = Copy-Fixture (New-Authority)
  $truncatedAuthority.comments.pagination.complete = $false
  $truncated = Invoke-Check (New-Candidate) $truncatedAuthority
  Assert-True ($truncated.verdict -ceq "refuse" -and $truncated.reason -ceq "AUTHORITY_TRUNCATED") "an incomplete page set must refuse"

  $countMismatchAuthority = Copy-Fixture (New-Authority)
  $countMismatchAuthority.comments.pagination.itemCount = 1
  $countMismatch = Invoke-Check (New-Candidate) $countMismatchAuthority
  Assert-True ($countMismatch.verdict -ceq "refuse" -and $countMismatch.reason -ceq "AUTHORITY_TRUNCATED") "a collected-count mismatch must refuse as truncated"

  $unpaginatedAuthority = Copy-Fixture (New-Authority)
  $unpaginatedAuthority.comments.PSObject.Properties.Remove("pagination")
  $unpaginated = Invoke-Check (New-Candidate) $unpaginatedAuthority
  Assert-True ($unpaginated.verdict -ceq "refuse" -and $unpaginated.reason -ceq "AUTHORITY_UNPAGINATED") "a payload without explicit all-pages proof must refuse"

  $emptyCandidate = Copy-Fixture (New-Candidate)
  $emptyCandidate.premiseRules = @()
  $empty = Invoke-Check $emptyCandidate (New-Authority)
  Assert-True ($empty.verdict -ceq "refuse" -and $empty.reason -ceq "EMPTY_PREMISE_RULES") "an empty premise-rule list must refuse"

  $nullRequest = Invoke-PremiseFreshnessRequest -Request $null
  Assert-True ($nullRequest.verdict -ceq "refuse" -and $nullRequest.reason -ceq "REQUEST_MALFORMED") "a null request must return a refusal rather than throw"
}

Invoke-Test "request wrapper refuses missing or duplicate authority" {
  $candidate = New-Candidate
  $missing = Invoke-PremiseFreshnessRequest ([pscustomobject][ordered]@{
      schemaVersion = "premise-freshness-request/v1"
      candidate = $candidate
      authority = @()
    })
  Assert-True ($missing.verdict -ceq "refuse" -and $missing.reason -ceq "AUTHORITY_UNAVAILABLE") "a request with no matching authority record must refuse"

  $authority = New-Authority
  $duplicate = Invoke-PremiseFreshnessRequest ([pscustomobject][ordered]@{
      schemaVersion = "premise-freshness-request/v1"
      candidate = $candidate
      authority = @($authority, (Copy-Fixture $authority))
    })
  Assert-True ($duplicate.verdict -ceq "refuse" -and $duplicate.reason -ceq "AUTHORITY_UNAVAILABLE") "ambiguous duplicate authority must refuse"
}

Invoke-Test "public entrypoint refuses singleton premiseRules objects" {
  $request = New-PublicRequest
  $request.candidate.premiseRules = $request.candidate.premiseRules[0]
  $actual = Invoke-PublicRequest $request
  Assert-True ($actual.exitCode -eq 1 -and $actual.result.verdict -ceq "refuse" -and $actual.result.reason -ceq "REQUEST_MALFORMED") "a singleton premiseRules object must not be coerced into a request array"
}

Invoke-Test "public entrypoint refuses singleton authority objects" {
  $request = New-PublicRequest
  $request.authority = $request.authority[0]
  $actual = Invoke-PublicRequest $request
  Assert-True ($actual.exitCode -eq 1 -and $actual.result.verdict -ceq "refuse" -and $actual.result.reason -ceq "REQUEST_MALFORMED") "a singleton authority object must not be coerced into a request array"
}

Invoke-Test "public entrypoint refuses singleton comment item objects" {
  $request = New-PublicRequest
  $comment = New-Comment -Id 9951 -Body "ordinary synthetic note" -Author "synthetic-foreign" -CreatedAt "2026-08-13T15:00:00Z"
  $request.authority[0].comments = New-Pagination @($comment)
  $request.authority[0].comments.items = $request.authority[0].comments.items[0]
  $actual = Invoke-PublicRequest $request
  Assert-True ($actual.exitCode -eq 1 -and $actual.result.verdict -ceq "refuse" -and $actual.result.reason -ceq "AUTHORITY_MALFORMED") "a singleton comments.items object must not be coerced into an authority array"
}

Invoke-Test "public entrypoint refuses singleton body-edit item objects" {
  $request = New-PublicRequest
  $edit = New-BodyEdit -Actor "synthetic-foreign" -CreatedAt "2026-08-13T15:00:00Z"
  $request.authority[0].bodyEdits = New-Pagination @($edit)
  $request.authority[0].bodyEdits.items = $request.authority[0].bodyEdits.items[0]
  $actual = Invoke-PublicRequest $request
  Assert-True ($actual.exitCode -eq 1 -and $actual.result.verdict -ceq "refuse" -and $actual.result.reason -ceq "AUTHORITY_MALFORMED") "a singleton bodyEdits.items object must not be coerced into an authority array"
}

Invoke-Test "public entrypoint refuses singleton superseding-decision item objects" {
  $request = New-PublicRequest
  $link = New-SupersedingDecision -Actor "synthetic-foreign" -LinkedAt "2026-08-13T15:00:00Z"
  $request.authority[0].supersedingDecisions = New-Pagination @($link)
  $request.authority[0].supersedingDecisions.items = $request.authority[0].supersedingDecisions.items[0]
  $actual = Invoke-PublicRequest $request
  Assert-True ($actual.exitCode -eq 1 -and $actual.result.verdict -ceq "refuse" -and $actual.result.reason -ceq "AUTHORITY_MALFORMED") "a singleton supersedingDecisions.items object must not be coerced into an authority array"
}

Invoke-Test "public entrypoint preserves valid empty arrays" {
  $request = New-PublicRequest
  $emptyItems = Invoke-PublicRequest $request
  Assert-True ($emptyItems.exitCode -eq 0 -and $emptyItems.result.verdict -ceq "adopt" -and $emptyItems.result.reason -ceq "PREMISES_FRESH") "empty paginated item arrays must remain valid"

  $request.authority = @()
  $emptyAuthority = Invoke-PublicRequest $request
  Assert-True ($emptyAuthority.exitCode -eq 1 -and $emptyAuthority.result.reason -ceq "AUTHORITY_UNAVAILABLE") "an empty authority array must retain its stable unavailable refusal"

  $request = New-PublicRequest
  $request.candidate.premiseRules = @()
  $emptyRules = Invoke-PublicRequest $request
  Assert-True ($emptyRules.exitCode -eq 1 -and $emptyRules.result.reason -ceq "EMPTY_PREMISE_RULES") "an empty premiseRules array must retain its stable empty-list refusal"
}

Invoke-Test "public entrypoint preserves valid one-element arrays" {
  $request = New-PublicRequest
  $request.authority[0].comments = New-Pagination @(
    (New-Comment -Id 9952 -Body "ordinary synthetic note" -Author "synthetic-foreign" -CreatedAt "2026-08-13T15:00:00Z")
  )
  $request.authority[0].bodyEdits = New-Pagination @(
    (New-BodyEdit -Actor "synthetic-foreign" -CreatedAt "2026-08-13T15:00:00Z")
  )
  $request.authority[0].supersedingDecisions = New-Pagination @(
    (New-SupersedingDecision -Actor "synthetic-foreign" -LinkedAt "2026-08-13T15:00:00Z")
  )
  $actual = Invoke-PublicRequest $request
  Assert-True ($actual.exitCode -eq 0 -and $actual.result.verdict -ceq "adopt" -and $actual.result.reason -ceq "PREMISES_FRESH") "one-element arrays at every collection boundary must remain valid"
}

$requestDuplicateJson = New-PublicRequest | ConvertTo-Json -Depth 20 -Compress
$requestDuplicateCases = @(
  [pscustomobject]@{
    name = "root schemaVersion"
    needle = '"schemaVersion":"premise-freshness-request/v1"'
    replacement = '"schemaVersion":"invalid","schemaVersion":"premise-freshness-request/v1"'
  },
  [pscustomobject]@{
    name = "candidate analysisInstant invalid-first valid-second"
    needle = '"analysisInstant":"2026-08-13T14:58:00Z"'
    replacement = '"analysisInstant":"not-an-instant","analysisInstant":"2026-08-13T14:58:00Z"'
  },
  [pscustomobject]@{
    name = "candidate analysisInstant valid-first invalid-second"
    needle = '"analysisInstant":"2026-08-13T14:58:00Z"'
    replacement = '"analysisInstant":"2026-08-13T14:58:00Z","analysisInstant":"not-an-instant"'
  },
  [pscustomobject]@{
    name = "decision filingInstant"
    needle = '"filingInstant":"2026-08-13T15:04:19Z"'
    replacement = '"filingInstant":"2026-08-13T15:04:19Z","filingInstant":"not-an-instant"'
  },
  [pscustomobject]@{
    name = "premise-rule name inside an array"
    needle = '"premiseRules":[{"name":"decision #6761 ops rules","repository":"chase-sets/chase-sets","issueNumber":6761}]'
    replacement = '"premiseRules":[{"name":"invalid","name":"decision #6761 ops rules","repository":"chase-sets/chase-sets","issueNumber":6761}]'
  },
  [pscustomobject]@{
    name = "premise-rule repository inside an array"
    needle = '"premiseRules":[{"name":"decision #6761 ops rules","repository":"chase-sets/chase-sets","issueNumber":6761}]'
    replacement = '"premiseRules":[{"name":"decision #6761 ops rules","repository":"invalid","repository":"chase-sets/chase-sets","issueNumber":6761}]'
  },
  [pscustomobject]@{
    name = "premise-rule issueNumber inside an array"
    needle = '"premiseRules":[{"name":"decision #6761 ops rules","repository":"chase-sets/chase-sets","issueNumber":6761}]'
    replacement = '"premiseRules":[{"name":"decision #6761 ops rules","repository":"chase-sets/chase-sets","issueNumber":0,"issueNumber":6761}]'
  },
  [pscustomobject]@{
    name = "JSON-escaped equivalent analysisInstant"
    needle = '"analysisInstant":"2026-08-13T14:58:00Z"'
    replacement = '"analysisInstant":"2026-08-13T14:58:00Z","analysis\u0049nstant":"2026-08-13T14:58:00Z"'
  },
  [pscustomobject]@{
    name = "root authority"
    needle = '"authority":['
    replacement = '"authority":[],"authority":['
  }
)
foreach ($case in $requestDuplicateCases) {
  Invoke-Test "public entrypoint rejects duplicate $($case.name) as request malformed" {
    $raw = Replace-UniqueJsonText $requestDuplicateJson $case.needle $case.replacement
    $actual = Invoke-PublicRequestJson $raw
    Assert-True (
      $actual.exitCode -eq 1 -and
      $actual.result.verdict -ceq "refuse" -and
      $actual.result.reason -ceq "REQUEST_MALFORMED"
    ) "duplicate $($case.name) must refuse REQUEST_MALFORMED"
  }
}

$authorityDuplicateRequest = New-PublicRequest
$authorityDuplicateRequest.authority[0].comments = New-Pagination @(
  (New-Comment 8001 "context only" "comment-worker" "2026-08-13T14:00:00Z" "2026-08-13T14:01:00Z")
) 2
$authorityDuplicateRequest.authority[0].bodyEdits = New-Pagination @(
  (New-BodyEdit "edit-worker" "2026-08-13T14:02:00Z")
)
$authorityDuplicateRequest.authority[0].supersedingDecisions = New-Pagination @(
  (New-SupersedingDecision "link-worker" "2026-08-13T14:03:00Z")
)
$authorityDuplicateJson = $authorityDuplicateRequest | ConvertTo-Json -Depth 20 -Compress
$authorityDuplicateCases = @(
  [pscustomobject]@{
    name = "pagination pageCount"
    needle = '"pageCount":2,"itemCount":1'
    replacement = '"pageCount":0,"pageCount":2,"itemCount":1'
  },
  [pscustomobject]@{
    name = "pagination itemCount"
    needle = '"pageCount":2,"itemCount":1'
    replacement = '"pageCount":2,"itemCount":0,"itemCount":1'
  },
  [pscustomobject]@{
    name = "repository-owner login"
    needle = '"repositoryOwner":{"login":"todd-skelton"}'
    replacement = '"repositoryOwner":{"login":"worker","login":"todd-skelton"}'
  },
  [pscustomobject]@{
    name = "comment created_at inside an items array"
    needle = '"created_at":"2026-08-13T14:00:00Z"'
    replacement = '"created_at":"not-an-instant","created_at":"2026-08-13T14:00:00Z"'
  },
  [pscustomobject]@{
    name = "comment updated_at inside an items array"
    needle = '"updated_at":"2026-08-13T14:01:00Z"'
    replacement = '"updated_at":"2026-08-13T14:01:00Z","updated_at":"not-an-instant"'
  },
  [pscustomobject]@{
    name = "comment actor login inside an items array"
    needle = '"user":{"login":"comment-worker"}'
    replacement = '"user":{"login":"invalid","login":"comment-worker"}'
  },
  [pscustomobject]@{
    name = "body-edit created_at inside an items array"
    needle = '"created_at":"2026-08-13T14:02:00Z"'
    replacement = '"created_at":"not-an-instant","created_at":"2026-08-13T14:02:00Z"'
  },
  [pscustomobject]@{
    name = "body-edit actor login inside an items array"
    needle = '"actor":{"login":"edit-worker"}'
    replacement = '"actor":{"login":"invalid","login":"edit-worker"}'
  },
  [pscustomobject]@{
    name = "supersession linked_at inside an items array"
    needle = '"linked_at":"2026-08-13T14:03:00Z"'
    replacement = '"linked_at":"not-an-instant","linked_at":"2026-08-13T14:03:00Z"'
  },
  [pscustomobject]@{
    name = "supersession linkedBy login inside an items array"
    needle = '"linkedBy":{"login":"link-worker"}'
    replacement = '"linkedBy":{"login":"invalid","login":"link-worker"}'
  },
  [pscustomobject]@{
    name = "JSON-escaped equivalent comment login"
    needle = '"user":{"login":"comment-worker"}'
    replacement = '"user":{"login":"comment-worker","log\u0069n":"comment-worker"}'
  }
)
foreach ($case in $authorityDuplicateCases) {
  Invoke-Test "public entrypoint rejects duplicate authority $($case.name)" {
    $raw = Replace-UniqueJsonText $authorityDuplicateJson $case.needle $case.replacement
    $actual = Invoke-PublicRequestJson $raw
    Assert-True (
      $actual.exitCode -eq 1 -and
      $actual.result.verdict -ceq "refuse" -and
      $actual.result.reason -ceq "AUTHORITY_MALFORMED"
    ) "duplicate authority $($case.name) must refuse AUTHORITY_MALFORMED"
  }
}

Invoke-Test "public entrypoint scopes repeated names independently per object" {
  $request = New-PublicRequest
  $request.authority[0].comments = New-Pagination @(
    (New-Comment 8101 "context only" "comment-worker-a" "2026-08-13T14:00:00Z"),
    (New-Comment 8102 "context only" "comment-worker-b" "2026-08-13T14:01:00Z")
  ) 2
  $raw = $request | ConvertTo-Json -Depth 20 -Compress
  $raw = Replace-UniqueJsonText `
    $raw `
    '"login":"comment-worker-a"' `
    '"log\u0069n":"comment-worker-a"'
  $actual = Invoke-PublicRequestJson $raw
  Assert-True (
    $actual.exitCode -eq 0 -and
    $actual.result.verdict -ceq "adopt" -and
    $actual.result.reason -ceq "PREMISES_FRESH"
  ) "escaped names and repeated names in separate array-item objects must remain valid"
}

Invoke-Test "public entrypoint rejects invalid JSON before materialization" {
  $actual = Invoke-PublicRequestJson '{"schemaVersion":"premise-freshness-request/v1","candidate":'
  Assert-True (
    $actual.exitCode -eq 1 -and
    $actual.result.verdict -ceq "refuse" -and
    $actual.result.reason -ceq "REQUEST_MALFORMED"
  ) "invalid JSON must fail closed with the request-envelope reason"
}

Invoke-Test "public entrypoint classifies deep authority duplicates by scope at the 60/61 boundary" {
  foreach ($layers in 60, 61) {
    $deep = New-DeepObjectValue $layers '{"dup":1,"dup":2}'
    Assert-PublicRefusal `
      ('{"authority":[{"opaque":' + $deep + '}]}') `
      "AUTHORITY_MALFORMED" `
      "a duplicate at $layers nested object layers must retain authority scope"
  }
}

Invoke-Test "public entrypoint keeps authority scope past the materialization depth limit" {
  foreach ($layers in 200, 1025) {
    $deep = New-DeepObjectValue $layers '{"dup":1,"dup":2}'
    Assert-PublicRefusal `
      ('{"authority":[{"opaque":' + $deep + '}]}') `
      "AUTHORITY_MALFORMED" `
      "the implementation materializers must not decide scope at $layers layers"
  }
}

Invoke-Test "depth policy refuses with the scope in force at the overflow" {
  $overDepthArrays = $script:MaxSupportedDepth
  $overDepthArraysWithObject = $script:MaxSupportedDepth - 1
  $authorityDuplicateFree = '{"authority":' +
    (New-NestedArrayValue $overDepthArrays '0') + '}'
  $requestDuplicateFree = '{"candidate":' +
    (New-NestedArrayValue $overDepthArrays '0') + ',"authority":[]}'
  $authorityDuplicate = '{"authority":' +
    (New-NestedArrayValue $overDepthArraysWithObject '{"dup":1,"dup":2}') + '}'
  $requestDuplicate = '{"candidate":' +
    (New-NestedArrayValue $overDepthArraysWithObject '{"dup":1,"dup":2}') +
    ',"authority":[]}'

  foreach ($raw in @($authorityDuplicateFree, $authorityDuplicate)) {
    Assert-PublicRefusal $raw "AUTHORITY_MALFORMED" "over-depth authority input must use the authority policy reason"
  }
  foreach ($raw in @($requestDuplicateFree, $requestDuplicate)) {
    Assert-PublicRefusal $raw "REQUEST_MALFORMED" "over-depth request input must use the request policy reason"
  }

  $atLimitArraysWithObject = $script:MaxSupportedDepth - 2
  Assert-PublicRefusal `
    ('{"authority":' + (New-NestedArrayValue $atLimitArraysWithObject '{"dup":1,"dup":2}') + '}') `
    "AUTHORITY_MALFORMED" `
    "the policy limit itself must remain reachable by the duplicate scan"
  Assert-PublicRefusal `
    ('{"candidate":' + (New-NestedArrayValue $atLimitArraysWithObject '{"dup":1,"dup":2}') + ',"authority":[]}') `
    "REQUEST_MALFORMED" `
    "the request-scope policy limit itself must remain reachable by the duplicate scan"
}

Invoke-Test "oversized request refuses before materialization" {
  $temporaryPath = Join-Path ([IO.Path]::GetTempPath()) (
    "premise-freshness-oversize-{0}.json" -f [guid]::NewGuid().ToString("N")
  )
  try {
    $raw = '{"padding":"' + ('x' * $script:MaxRequestBytes) + '"}'
    [IO.File]::WriteAllText($temporaryPath, $raw, [Text.UTF8Encoding]::new($false))
    $actual = Invoke-PublicRequestPath $temporaryPath
    Assert-True (
      $actual.exitCode -eq 1 -and
      $actual.result.verdict -ceq "refuse" -and
      $actual.result.reason -ceq "REQUEST_MALFORMED"
    ) "a request above $script:MaxRequestBytes UTF-8 bytes must refuse before JSON materialization"
  } finally {
    if (Test-Path -LiteralPath $temporaryPath) {
      Remove-Item -LiteralPath $temporaryPath -Force
    }
  }
}

Invoke-Test "root duplicate outranks the depth policy" {
  $overDepth = New-NestedArrayValue $script:MaxSupportedDepth '0'
  Assert-PublicRefusal `
    ('{"authority":' + $overDepth + ',"authority":[]}') `
    "REQUEST_MALFORMED" `
    "a duplicated root authority must outrank an earlier authority depth overflow"
}

Invoke-Test "deep authority duplicates refuse in both orders" {
  foreach ($leaf in @(
      '{"dup":"invalid","dup":"valid"}',
      '{"dup":"valid","dup":"invalid"}'
    )) {
    $deep = New-DeepObjectValue 200 $leaf
    Assert-PublicRefusal `
      ('{"authority":[{"opaque":' + $deep + '}]}') `
      "AUTHORITY_MALFORMED" `
      "duplicate value order must not alter a deep authority refusal"
  }
}

Invoke-Test "escaped root member names resolve to the same ordinal identity" {
  Assert-PublicRefusal `
    '{"\u0061uthority":[],"authority":[]}' `
    "REQUEST_MALFORMED" `
    "an escaped authority spelling must collide with the plain root spelling"

  $emoji = [char]::ConvertFromUtf32(0x1F600)
  Assert-PublicRefusal `
    ('{"' + $emoji + '":1,"\uD83D\uDE00":2}') `
    "REQUEST_MALFORMED" `
    "a literal surrogate pair must collide with its escaped root spelling"

  $overDepth = New-NestedArrayValue $script:MaxSupportedDepth '0'
  Assert-PublicRefusal `
    ('{"\u0061uthority":' + $overDepth + '}') `
    "AUTHORITY_MALFORMED" `
    "an escaped unique authority name must establish scope for depth policy"
}

Invoke-Test "lexical preflight preserves structural characters quotes and backslashes in strings" {
  $requestJson = New-PublicRequest | ConvertTo-Json -Depth 20 -Compress
  $decorated = '{"na{}[]\\me":0,"decor":"{}[]\"quoted\"\\",' +
    $requestJson.Substring(1)
  $valid = Invoke-PublicRequestJson $decorated
  Assert-True (
    $valid.exitCode -eq 0 -and
    $valid.result.verdict -ceq "adopt" -and
    $valid.result.reason -ceq "PREMISES_FRESH"
  ) "structural characters and an ending backslash inside names and values must not affect depth"

  $overDepth = New-NestedArrayValue $script:MaxSupportedDepth '0'
  Assert-PublicRefusal `
    ('{"decor":"{}[]\"quoted\"\\","\u0061uthority":' + $overDepth + '}') `
    "AUTHORITY_MALFORMED" `
    "string contents must not obscure an escaped authority scope"
}

Invoke-Test "explicit stack preserves document order across request and authority branches" {
  Assert-PublicRefusal `
    '{"candidate":{"dup":1,"dup":2},"authority":[{"dup":1,"dup":2}]}' `
    "REQUEST_MALFORMED" `
    "a request duplicate in the first root branch must win"
  Assert-PublicRefusal `
    '{"authority":[{"dup":1,"dup":2}],"candidate":{"dup":1,"dup":2}}' `
    "AUTHORITY_MALFORMED" `
    "an authority duplicate in the first root branch must win"
  Assert-PublicRefusal `
    '{"authority":[[[{"dup":1,"dup":2}]]]}' `
    "AUTHORITY_MALFORMED" `
    "objects beneath nested arrays must remain in authority scope"
}

Invoke-Test "truncation refuses as request malformed on both sides of the authority boundary" {
  foreach ($raw in @(
      '{"candidate":',
      '{"authority":[{"value":',
      '[]'
    )) {
    Assert-PublicRefusal $raw "REQUEST_MALFORMED" "truncated or non-object root JSON must refuse uniformly"
  }
}

Invoke-Test "predicate enumerates every configured request depth and size threshold" {
  $predicatePath = Join-Path $PSScriptRoot "premise-freshness.ps1"
  $source = Get-Content -LiteralPath $predicatePath -Raw
  Assert-True ($script:MaxSupportedDepth -eq 256) "MaxSupportedDepth must remain exactly 256"
  Assert-True ($script:MaxRequestBytes -eq 1048576) "MaxRequestBytes must remain exactly 1048576"
  Assert-True (
    $script:JsonImplementationDepth -eq $script:MaxSupportedDepth + 2
  ) "every request materializer must sit strictly above the supported policy depth"
  Assert-True (
    ([regex]::Matches($source, 'GetByteCount\(\$Raw\)').Count -eq 1) -and
    ([regex]::Matches($source, '\$options\.MaxDepth\s*=\s*\$script:JsonImplementationDepth').Count -eq 1) -and
    ([regex]::Matches($source, 'ConvertFrom-Json\s*`\s*\r?\n\s*-Depth\s+\$script:JsonImplementationDepth').Count -eq 1)
  ) "the request path must expose exactly one byte bound and two explicit +2 materializer thresholds"
  Assert-True (
    ([regex]::Matches($source, 'ConvertTo-Json\s+-Depth\s+12').Count -eq 1)
  ) "the only other depth API must remain the fixed shallow verdict serializer"
}

Invoke-Test "public entrypoint refuses in every supported invocation mode" {
  $predicate = (Resolve-Path (Join-Path $PSScriptRoot "premise-freshness.ps1")).Path
  $raw = '{"authority":[{"dup":1,"dup":2}]}'
  $path64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($predicate))
  $raw64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($raw))

  function Invoke-ModeCommand([string]$ModeBody) {
    $command = @"
`$p=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$path64'))
`$raw=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$raw64'))
$ModeBody
"@
    $output = @(& pwsh -NoProfile -NonInteractive -Command $command 2>&1)
    return [pscustomobject]@{ exitCode = $LASTEXITCODE; text = ($output -join "`n") }
  }

  $fileMode = Invoke-PublicRequestJson $raw
  Assert-True (
    $fileMode.exitCode -eq 1 -and $fileMode.result.reason -ceq "AUTHORITY_MALFORMED"
  ) "-File must refuse the duplicate in authority scope"

  $direct = Invoke-ModeCommand '& $p -RequestJson $raw'
  $dotSourceBody = @'
. $p
$result = try {
  Assert-PfRawRequestJson $raw
  [pscustomobject]@{ verdict = "adopt"; reason = "unexpected" }
} catch {
  $reason = if ($_.Exception.Message -match '^PF:([A-Z_]+)$') { $Matches[1] } else { "REQUEST_MALFORMED" }
  [pscustomobject]@{ verdict = "refuse"; reason = $reason }
}
$result | ConvertTo-Json -Compress
'@
  $dotSource = Invoke-ModeCommand $dotSourceBody
  $nested = Invoke-ModeCommand ('& { ' + $dotSourceBody + ' }')
  $doubleNested = Invoke-ModeCommand ('& { & { ' + $dotSourceBody + ' } }')
  $dynamicModuleBody = @'
$module = New-Module -ScriptBlock {
  param($PredicatePath, $RawJson)
  . $PredicatePath
  function Invoke-PfModuleRaw {
    try {
      Assert-PfRawRequestJson $RawJson
      [pscustomobject]@{ verdict = "adopt"; reason = "unexpected" }
    } catch {
      $reason = if ($_.Exception.Message -match '^PF:([A-Z_]+)$') { $Matches[1] } else { "REQUEST_MALFORMED" }
      [pscustomobject]@{ verdict = "refuse"; reason = $reason }
    }
  }
  Export-ModuleMember -Function Invoke-PfModuleRaw
} -ArgumentList $p, $raw
Import-Module $module
Invoke-PfModuleRaw | ConvertTo-Json -Compress
'@
  $dynamicModule = Invoke-ModeCommand $dynamicModuleBody

  foreach ($mode in @(
      @{ name = "-Command"; actual = $direct },
      @{ name = "dot-source"; actual = $dotSource },
      @{ name = "nested"; actual = $nested },
      @{ name = "double-nested"; actual = $doubleNested },
      @{ name = "dynamic-module"; actual = $dynamicModule }
    )) {
    $result = $mode.actual.text | ConvertFrom-Json -DateKind String
    Assert-True (
      $result.verdict -ceq "refuse" -and $result.reason -ceq "AUTHORITY_MALFORMED"
    ) "$($mode.name) must return the same authority-scoped refusal"
  }

  $commandError = @(& pwsh -NoProfile -NonInteractive -Command "& '$predicate' -RequestJson" 2>&1)
  Assert-True (
    $LASTEXITCODE -ne 0 -and ($commandError -join "`n") -notmatch '"verdict"\s*:\s*"adopt"'
  ) "a command-mode binding error must remain non-adopting"
}

Invoke-Test "predicate exposes no runtime caller or write token" {
  $repoRoot = Split-Path $PSScriptRoot -Parent
  $callerLines = @(& git -C $repoRoot grep -n -I -E `
      'Invoke-PremiseFreshness(Check|Request)|premise-freshness\.ps1' `
      -- '*.ps1' '*.psm1' '*.cjs' '*.mjs' 2>$null)
  $unexpectedCallers = @($callerLines | Where-Object {
      $_ -notmatch '^\.orchestrator/premise-freshness(?:\.test)?\.ps1:'
    })
  Assert-True ($unexpectedCallers.Count -eq 0) "no runtime file outside the predicate test may call this inert slice"

  $predicateSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot "premise-freshness.ps1") -Raw
  $mutationOrNetworkTokens = [regex]::Matches(
    $predicateSource,
    '(?im)\b(?:gh|curl|wget)\s|Invoke-(?:WebRequest|RestMethod)|HttpClient|System\.Net|Set-Content|Add-Content|Out-File|New-Item|Remove-Item|Move-Item|Copy-Item|Start-Process'
  )
  Assert-True ($mutationOrNetworkTokens.Count -eq 0) "the predicate must contain no provider, network, process, or filesystem-mutation token"
}

Invoke-Test "request wrapper adopts through a non-global command scope" {
  $requestJson = [pscustomobject][ordered]@{
    schemaVersion = "premise-freshness-request/v1"
    candidate = New-Candidate
    authority = @(New-Authority)
  } | ConvertTo-Json -Depth 20 -Compress
  $scriptPathBase64 = [Convert]::ToBase64String(
    [Text.Encoding]::UTF8.GetBytes((Resolve-Path (Join-Path $PSScriptRoot "premise-freshness.ps1")).Path)
  )
  $requestBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($requestJson))
  $command = @"
& {
  function Invoke-ScopedPremiseRequest {
    `$scriptPath = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$scriptPathBase64'))
    . `$scriptPath
    `$requestJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$requestBase64'))
    `$request = `$requestJson | ConvertFrom-Json -DateKind String
    Invoke-PremiseFreshnessRequest -Request `$request
  }
  Invoke-ScopedPremiseRequest | ConvertTo-Json -Depth 12 -Compress
}
"@
  $output = @(& pwsh -NoProfile -Command $command 2>&1)
  $exitCode = $LASTEXITCODE
  $result = ($output -join "`n") | ConvertFrom-Json -DateKind String
  Assert-True ($exitCode -eq 0 -and $result.verdict -ceq "adopt" -and $result.reason -ceq "PREMISES_FRESH") "valid exact authority must adopt when the wrapper and helpers live outside global scope (exit=$exitCode verdict=$($result.verdict) reason=$($result.reason))"
}

Invoke-Test "request wrapper routes exact authority for multiple premises" {
  $candidate = Copy-Fixture (New-Candidate)
  $candidate.premiseRules = @($candidate.premiseRules) + @([pscustomobject][ordered]@{
      name = "decision #6893 premise freshness"
      repository = "chase-sets/chase-sets"
      issueNumber = 6893
    })

  $firstAuthority = New-Authority
  $secondAuthority = Copy-Fixture (New-Authority)
  $secondAuthority.premiseRule.name = "decision #6893 premise freshness"
  $secondAuthority.premiseRule.issueNumber = 6893
  $secondAuthority.issue.number = 6893
  $secondAuthority.issue.html_url = "https://github.com/chase-sets/chase-sets/issues/6893"

  $exact = Invoke-PremiseFreshnessRequest ([pscustomobject][ordered]@{
      schemaVersion = "premise-freshness-request/v1"
      candidate = $candidate
      authority = @($firstAuthority, $secondAuthority)
    })
  Assert-True ($exact.verdict -ceq "adopt" -and $exact.reason -ceq "PREMISES_FRESH") "two premise rules with two exact complete authority records must adopt"

  $mismatchedAuthority = Copy-Fixture $secondAuthority
  $mismatchedAuthority.premiseRule.issueNumber = 6999
  $mismatchedAuthority.issue.number = 6999
  $mismatchedAuthority.issue.html_url = "https://github.com/chase-sets/chase-sets/issues/6999"
  $mismatched = Invoke-PremiseFreshnessRequest ([pscustomobject][ordered]@{
      schemaVersion = "premise-freshness-request/v1"
      candidate = $candidate
      authority = @($firstAuthority, $mismatchedAuthority)
    })
  Assert-True ($mismatched.verdict -ceq "refuse" -and $mismatched.reason -ceq "AUTHORITY_UNAVAILABLE") "a mismatched authority record must remain unavailable"

  $junkRecord = [pscustomobject][ordered]@{ premiseRule = [pscustomobject]@{} }
  $withJunk = Invoke-PremiseFreshnessRequest ([pscustomobject][ordered]@{
      schemaVersion = "premise-freshness-request/v1"
      candidate = $candidate
      authority = @($firstAuthority, $secondAuthority, $junkRecord)
    })
  Assert-True ($withJunk.verdict -ceq "adopt" -and $withJunk.reason -ceq "PREMISES_FRESH") "a junk record must be filtered without poisoning exact authority matches"
}

Write-Output "PASS premise-freshness contract and read-only predicate"
