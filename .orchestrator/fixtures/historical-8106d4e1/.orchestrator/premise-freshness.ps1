<#
.SYNOPSIS
Read-only premise-freshness predicate.

.DESCRIPTION
Evaluates a versioned candidate request against injected repository-owner
authority. The script contains no GitHub mutation path and performs no network
I/O. Dot-source it to call Invoke-PremiseFreshnessCheck with an authority
provider, or invoke it with -RequestPath/-RequestJson for a JSON verdict.
#>
[CmdletBinding()]
param(
  [string]$RequestPath,
  [string]$RequestJson
)

$ErrorActionPreference = "Stop"
$script:PremiseRequestSchema = "premise-freshness-request/v1"
$script:PremiseAuthoritySchema = "premise-freshness-authority/v1"
$script:PremisePaginationSchema = "github-pagination/v1"
$script:PremiseVerdictSchema = "premise-freshness-verdict/v1"
$script:MaxSupportedDepth = 256
$script:MaxRequestBytes = 1048576
$script:JsonImplementationDepth = $script:MaxSupportedDepth + 2

function Test-PfProperty($Value, [string]$Name) {
  return $null -ne $Value -and $null -ne $Value.PSObject.Properties[$Name]
}

function Stop-PfMalformed([string]$Code) {
  throw [ArgumentException]::new("PF:$Code")
}

function Read-PfRawJsonString([string]$Raw, [int]$Start, [bool]$Decode) {
  $builder = if ($Decode) { [Text.StringBuilder]::new() } else { $null }
  $valid = $true
  $index = $Start + 1
  $backslash = [char]0x5c
  while ($index -lt $Raw.Length) {
    $character = $Raw[$index]
    if ($character -eq '"') {
      return [pscustomobject]@{
        Next = $index + 1
        Closed = $true
        Valid = $valid
        Value = if ($Decode -and $valid) { $builder.ToString() } else { $null }
      }
    }
    if ($character -eq $backslash) {
      $index++
      if ($index -ge $Raw.Length) {
        return [pscustomobject]@{
          Next = $Raw.Length
          Closed = $false
          Valid = $false
          Value = $null
        }
      }
      $escape = $Raw[$index]
      if ($Decode) {
        switch -CaseSensitive ($escape) {
          '"' { [void]$builder.Append('"') }
          '\' { [void]$builder.Append($backslash) }
          '/' { [void]$builder.Append('/') }
          'b' { [void]$builder.Append([char]8) }
          'f' { [void]$builder.Append([char]12) }
          'n' { [void]$builder.Append([char]10) }
          'r' { [void]$builder.Append([char]13) }
          't' { [void]$builder.Append([char]9) }
          'u' {
            if ($index + 4 -ge $Raw.Length) {
              $valid = $false
            } else {
              $codeUnit = 0
              $hex = $Raw.Substring($index + 1, 4)
              if ([int]::TryParse(
                  $hex,
                  [Globalization.NumberStyles]::AllowHexSpecifier,
                  [Globalization.CultureInfo]::InvariantCulture,
                  [ref]$codeUnit
                )) {
                [void]$builder.Append([char]$codeUnit)
                $index += 4
              } else {
                $valid = $false
              }
            }
          }
          default { $valid = $false }
        }
      } elseif ($escape -eq 'u' -and $index + 4 -lt $Raw.Length) {
        $index += 4
      }
      $index++
      continue
    }
    if ([int]$character -lt 0x20) { $valid = $false }
    if ($Decode) { [void]$builder.Append($character) }
    $index++
  }
  return [pscustomobject]@{
    Next = $Raw.Length
    Closed = $false
    Valid = $false
    Value = $null
  }
}

function Get-PfRawJsonPreflight([string]$Raw) {
  if ([Text.Encoding]::UTF8.GetByteCount($Raw) -gt $script:MaxRequestBytes) {
    Stop-PfMalformed "REQUEST_MALFORMED"
  }

  $containers = [Collections.Generic.Stack[char]]::new()
  $rootNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  $rootTokenSeen = $false
  $rootObject = $false
  $rootExpectName = $false
  $rootPendingName = $null
  $rootValueName = $null
  $rootDuplicate = $false
  $firstDepthOverflow = $null
  $index = 0

  while ($index -lt $Raw.Length) {
    $character = $Raw[$index]
    if ([char]::IsWhiteSpace($character)) {
      $index++
      continue
    }
    $isRootToken = -not $rootTokenSeen
    if ($isRootToken) { $rootTokenSeen = $true }

    if ($character -eq '"') {
      $decodeRootName = $rootObject -and
        $containers.Count -eq 1 -and
        $containers.Peek() -eq '{' -and
        $rootExpectName
      $string = Read-PfRawJsonString -Raw $Raw -Start $index -Decode $decodeRootName
      if ($decodeRootName) {
        $rootExpectName = $false
        $rootPendingName = if ($string.Closed -and $string.Valid) {
          [string]$string.Value
        } else {
          $null
        }
        if ($null -ne $rootPendingName -and -not $rootNames.Add($rootPendingName)) {
          $rootDuplicate = $true
        }
      }
      $index = $string.Next
      continue
    }

    if ($character -eq '{' -or $character -eq '[') {
      $containers.Push($character)
      if ($isRootToken -and $character -eq '{') {
        $rootObject = $true
        $rootExpectName = $true
      }
      if ($containers.Count -gt $script:MaxSupportedDepth -and
          $null -eq $firstDepthOverflow) {
        $firstDepthOverflow = [pscustomobject]@{
          Depth = $containers.Count
          RootMemberName = $rootValueName
        }
      }
      $index++
      continue
    }

    if ($character -eq ':' -and
        $rootObject -and
        $containers.Count -eq 1 -and
        $containers.Peek() -eq '{') {
      $rootValueName = $rootPendingName
      $rootPendingName = $null
      $index++
      continue
    }

    if ($character -eq ',' -and
        $rootObject -and
        $containers.Count -eq 1 -and
        $containers.Peek() -eq '{') {
      $rootValueName = $null
      $rootPendingName = $null
      $rootExpectName = $true
      $index++
      continue
    }

    if ($character -eq '}' -or $character -eq ']') {
      if ($containers.Count -gt 0) { [void]$containers.Pop() }
      if ($containers.Count -eq 0) {
        $rootObject = $false
        $rootExpectName = $false
        $rootPendingName = $null
        $rootValueName = $null
      }
      $index++
      continue
    }

    $index++
  }

  return [pscustomobject]@{
    RootDuplicate = $rootDuplicate
    FirstDepthOverflow = $firstDepthOverflow
  }
}

function Assert-PfNoDuplicateJsonMembers(
  [Parameter(Mandatory)][System.Text.Json.JsonElement]$Element
) {
  $stack = [Collections.Generic.Stack[object]]::new()
  $stack.Push([pscustomobject]@{
      Element = $Element
      AuthorityScope = $false
      Root = $true
    })
  $activeAuthorityScope = $false

  try {
    while ($stack.Count -gt 0) {
      $frame = $stack.Pop()
      $activeAuthorityScope = [bool]$frame.AuthorityScope
      $current = [System.Text.Json.JsonElement]$frame.Element

      if ($current.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
        $properties = @($current.EnumerateObject())
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($property in $properties) {
          if (-not $seen.Add($property.Name)) {
            Stop-PfMalformed $(if ($frame.Root -or -not $frame.AuthorityScope) {
                "REQUEST_MALFORMED"
              } else {
                "AUTHORITY_MALFORMED"
              })
          }
        }
        for ($childIndex = $properties.Count - 1; $childIndex -ge 0; $childIndex--) {
          $property = $properties[$childIndex]
          $childAuthorityScope = $frame.AuthorityScope -or ($frame.Root -and [string]::Equals(
              $property.Name,
              "authority",
              [StringComparison]::Ordinal
            ))
          $stack.Push([pscustomobject]@{
              Element = $property.Value
              AuthorityScope = $childAuthorityScope
              Root = $false
            })
        }
        continue
      }

      if ($current.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
        $items = @($current.EnumerateArray())
        for ($childIndex = $items.Count - 1; $childIndex -ge 0; $childIndex--) {
          $stack.Push([pscustomobject]@{
              Element = $items[$childIndex]
              AuthorityScope = $frame.AuthorityScope
              Root = $false
            })
        }
      }
    }
  } catch {
    if ($_.Exception.Message -match '^PF:[A-Z_]+$') { throw }
    Stop-PfMalformed $(if ($activeAuthorityScope) {
        "AUTHORITY_MALFORMED"
      } else {
        "REQUEST_MALFORMED"
      })
  }
}

function Assert-PfRawRequestJson([string]$Raw) {
  $preflight = Get-PfRawJsonPreflight $Raw
  if ($preflight.RootDuplicate) {
    Stop-PfMalformed "REQUEST_MALFORMED"
  }
  if ($null -ne $preflight.FirstDepthOverflow) {
    Stop-PfMalformed $(if ([string]::Equals(
          $preflight.FirstDepthOverflow.RootMemberName,
          "authority",
          [StringComparison]::Ordinal
        )) {
        "AUTHORITY_MALFORMED"
      } else {
        "REQUEST_MALFORMED"
      })
  }

  $options = [System.Text.Json.JsonDocumentOptions]::new()
  $options.AllowTrailingCommas = $false
  $options.CommentHandling = [System.Text.Json.JsonCommentHandling]::Disallow
  $options.MaxDepth = $script:JsonImplementationDepth
  $document = $null
  try {
    $document = [System.Text.Json.JsonDocument]::Parse($Raw, $options)
    Assert-PfNoDuplicateJsonMembers -Element $document.RootElement
  } finally {
    if ($null -ne $document) { $document.Dispose() }
  }
}

function ConvertTo-PfInstant($Value, [string]$Code) {
  $profile = '\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,7})?(?:Z|[+-][0-9]{2}:[0-9]{2})\z'
  if ($Value -isnot [string] -or -not [regex]::IsMatch(
      $Value,
      $profile,
      [Text.RegularExpressions.RegexOptions]::CultureInvariant
    )) {
    Stop-PfMalformed $Code
  }
  [string[]]$formats = @(
    "yyyy-MM-dd'T'HH:mm:ss'Z'",
    "yyyy-MM-dd'T'HH:mm:ss.FFFFFFF'Z'",
    "yyyy-MM-dd'T'HH:mm:sszzz",
    "yyyy-MM-dd'T'HH:mm:ss.FFFFFFFzzz"
  )
  $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor
    [Globalization.DateTimeStyles]::AdjustToUniversal
  $parsed = [datetimeoffset]::MinValue
  if (-not [datetimeoffset]::TryParseExact(
      $Value,
      $formats,
      [Globalization.CultureInfo]::InvariantCulture,
      $styles,
      [ref]$parsed
    )) {
    Stop-PfMalformed $Code
  }
  return $parsed.ToUniversalTime()
}

function Test-PfWholeNumber($Value, [long]$Minimum = 0) {
  if ($Value -is [bool] -or $null -eq $Value) { return $false }
  $number = 0L
  return [long]::TryParse(
    "$Value",
    [Globalization.NumberStyles]::None,
    [Globalization.CultureInfo]::InvariantCulture,
    [ref]$number
  ) -and $number -ge $Minimum
}

function Test-PfRepository($Value) {
  return $Value -is [string] -and
    $Value -cmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
}

function Test-PfSameIdentity($Left, $Right) {
  return $Left -is [string] -and $Right -is [string] -and
    -not [string]::IsNullOrWhiteSpace($Left) -and
    -not [string]::IsNullOrWhiteSpace($Right) -and
    [string]::Equals($Left.Trim(), $Right.Trim(), [StringComparison]::OrdinalIgnoreCase)
}

function New-PfResult(
  [string]$Verdict,
  [string]$Reason,
  $AnalysisInstant,
  $Evidence = $null
) {
  [pscustomobject][ordered]@{
    schemaVersion = $script:PremiseVerdictSchema
    verdict = $Verdict
    reason = $Reason
    analysisInstant = if ($null -eq $AnalysisInstant) { $null } else { $AnalysisInstant.ToString("o") }
    evidence = $Evidence
  }
}

function New-PfRuleEvidence($Rule, [string]$Shape, [datetimeoffset]$Timestamp, $Source) {
  [pscustomobject][ordered]@{
    premiseRule = [pscustomobject][ordered]@{
      name = [string]$Rule.name
      repository = [string]$Rule.repository
      issueNumber = [long]$Rule.issueNumber
    }
    amendmentShape = $Shape
    timestamp = $Timestamp.ToString("o")
    source = $Source
  }
}

function Test-PfSemanticAmendment($Body) {
  if ($Body -isnot [string]) { return $false }
  $first = @($Body -split "`r?`n" |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      Select-Object -First 1)
  if ($first.Count -ne 1) { return $false }
  return $first[0] -cmatch '^\s{0,3}(?:#{1,6}\s+)?Amendment\s+[1-9][0-9]*\b'
}

function Assert-PfPagination($Collection) {
  if (-not (Test-PfProperty $Collection "pagination") -or
      -not (Test-PfProperty $Collection "items")) {
    Stop-PfMalformed "AUTHORITY_UNPAGINATED"
  }
  if ($Collection.items -isnot [array]) {
    Stop-PfMalformed "AUTHORITY_MALFORMED"
  }
  $pagination = $Collection.pagination
  foreach ($name in @("schemaVersion", "mode", "complete", "truncated", "pageCount", "itemCount")) {
    if (-not (Test-PfProperty $pagination $name)) { Stop-PfMalformed "AUTHORITY_UNPAGINATED" }
  }
  if ($pagination.schemaVersion -cne $script:PremisePaginationSchema -or
      $pagination.mode -cne "all-pages") {
    Stop-PfMalformed "AUTHORITY_UNPAGINATED"
  }
  if ($pagination.complete -isnot [bool] -or $pagination.truncated -isnot [bool]) {
    Stop-PfMalformed "AUTHORITY_MALFORMED"
  }
  if (-not $pagination.complete -or $pagination.truncated) {
    Stop-PfMalformed "AUTHORITY_TRUNCATED"
  }
  if (-not (Test-PfWholeNumber $pagination.pageCount 1) -or
      -not (Test-PfWholeNumber $pagination.itemCount 0)) {
    Stop-PfMalformed "AUTHORITY_MALFORMED"
  }
  $items = @($Collection.items)
  if ($items.Count -ne [long]$pagination.itemCount) {
    Stop-PfMalformed "AUTHORITY_TRUNCATED"
  }
  return $items
}

function Assert-PfCandidate($Candidate) {
  foreach ($name in @("decision", "analysisInstant", "premiseRules")) {
    if (-not (Test-PfProperty $Candidate $name)) { Stop-PfMalformed "REQUEST_MALFORMED" }
  }
  if ($Candidate.premiseRules -isnot [array]) {
    Stop-PfMalformed "REQUEST_MALFORMED"
  }
  foreach ($name in @("repository", "issueNumber", "filingInstant")) {
    if (-not (Test-PfProperty $Candidate.decision $name)) { Stop-PfMalformed "REQUEST_MALFORMED" }
  }
  if (-not (Test-PfRepository $Candidate.decision.repository) -or
      -not (Test-PfWholeNumber $Candidate.decision.issueNumber 1)) {
    Stop-PfMalformed "REQUEST_MALFORMED"
  }
  [void](ConvertTo-PfInstant $Candidate.decision.filingInstant "REQUEST_MALFORMED")
  $analysisInstant = ConvertTo-PfInstant $Candidate.analysisInstant "REQUEST_MALFORMED"
  $rules = @($Candidate.premiseRules)
  if ($rules.Count -eq 0) { Stop-PfMalformed "EMPTY_PREMISE_RULES" }
  $seen = @{}
  foreach ($rule in $rules) {
    foreach ($name in @("name", "repository", "issueNumber")) {
      if (-not (Test-PfProperty $rule $name)) { Stop-PfMalformed "REQUEST_MALFORMED" }
    }
    if ($rule.name -isnot [string] -or [string]::IsNullOrWhiteSpace($rule.name) -or
        -not (Test-PfRepository $rule.repository) -or
        -not (Test-PfWholeNumber $rule.issueNumber 1)) {
      Stop-PfMalformed "REQUEST_MALFORMED"
    }
    $key = "$($rule.repository.ToLowerInvariant())#$([long]$rule.issueNumber)"
    if ($seen.ContainsKey($key)) { Stop-PfMalformed "REQUEST_MALFORMED" }
    $seen[$key] = $true
  }
  return [pscustomobject]@{ analysisInstant = $analysisInstant; rules = $rules }
}

function Get-PfAmendments($Rule, $Authority, [datetimeoffset]$AnalysisInstant) {
  if ($null -eq $Authority) { Stop-PfMalformed "AUTHORITY_UNAVAILABLE" }
  foreach ($name in @(
      "schemaVersion", "available", "repository", "repositoryOwner", "premiseRule", "issue",
      "comments", "bodyEdits", "supersedingDecisions"
    )) {
    if (-not (Test-PfProperty $Authority $name)) { Stop-PfMalformed "AUTHORITY_MALFORMED" }
  }
  if ($Authority.schemaVersion -cne $script:PremiseAuthoritySchema -or
      $Authority.available -isnot [bool]) {
    Stop-PfMalformed "AUTHORITY_MALFORMED"
  }
  if (-not $Authority.available) { Stop-PfMalformed "AUTHORITY_UNAVAILABLE" }
  if (-not (Test-PfProperty $Authority.repository "nameWithOwner") -or
      -not (Test-PfProperty $Authority.repositoryOwner "login") -or
      -not (Test-PfSameIdentity $Authority.repository.nameWithOwner $Rule.repository) -or
      $Authority.repositoryOwner.login -isnot [string] -or
      [string]::IsNullOrWhiteSpace($Authority.repositoryOwner.login)) {
    Stop-PfMalformed "AUTHORITY_MALFORMED"
  }
  foreach ($name in @("name", "repository", "issueNumber")) {
    if (-not (Test-PfProperty $Authority.premiseRule $name)) { Stop-PfMalformed "AUTHORITY_MALFORMED" }
  }
  if ($Authority.premiseRule.name -cne $Rule.name -or
      -not (Test-PfSameIdentity $Authority.premiseRule.repository $Rule.repository) -or
      -not (Test-PfWholeNumber $Authority.premiseRule.issueNumber 1) -or
      [long]$Authority.premiseRule.issueNumber -ne [long]$Rule.issueNumber) {
    Stop-PfMalformed "AUTHORITY_MALFORMED"
  }
  if (-not (Test-PfProperty $Authority.issue "number") -or
      -not (Test-PfProperty $Authority.issue "html_url") -or
      -not (Test-PfWholeNumber $Authority.issue.number 1) -or
      [long]$Authority.issue.number -ne [long]$Rule.issueNumber -or
      $Authority.issue.html_url -isnot [string] -or
      [string]::IsNullOrWhiteSpace($Authority.issue.html_url)) {
    Stop-PfMalformed "AUTHORITY_MALFORMED"
  }

  $owner = [string]$Authority.repositoryOwner.login
  $events = [Collections.Generic.List[object]]::new()

  foreach ($comment in @(Assert-PfPagination $Authority.comments)) {
    foreach ($name in @("id", "html_url", "body", "user", "created_at", "updated_at")) {
      if (-not (Test-PfProperty $comment $name)) { Stop-PfMalformed "AUTHORITY_MALFORMED" }
    }
    if (-not (Test-PfProperty $comment.user "login") -or
        -not (Test-PfWholeNumber $comment.id 1) -or
        $comment.html_url -isnot [string] -or [string]::IsNullOrWhiteSpace($comment.html_url) -or
        $comment.body -isnot [string] -or $comment.user.login -isnot [string] -or
        [string]::IsNullOrWhiteSpace($comment.user.login)) {
      Stop-PfMalformed "AUTHORITY_MALFORMED"
    }
    $created = ConvertTo-PfInstant $comment.created_at "AUTHORITY_MALFORMED"
    $updated = ConvertTo-PfInstant $comment.updated_at "AUTHORITY_MALFORMED"
    if ($updated -lt $created) { Stop-PfMalformed "AUTHORITY_MALFORMED" }
    if (-not (Test-PfSameIdentity $comment.user.login $owner) -or
        -not (Test-PfSemanticAmendment $comment.body)) {
      continue
    }
    $source = [pscustomobject][ordered]@{
      kind = "comment"
      id = [long]$comment.id
      htmlUrl = [string]$comment.html_url
    }
    if ($created -gt $AnalysisInstant) {
      $events.Add((New-PfRuleEvidence $Rule "new-comment" $created $source))
    }
    if ($updated -gt $created -and $updated -gt $AnalysisInstant) {
      $events.Add((New-PfRuleEvidence $Rule "edited-comment" $updated $source))
    }
  }

  foreach ($edit in @(Assert-PfPagination $Authority.bodyEdits)) {
    foreach ($name in @("id", "html_url", "field", "actor", "created_at")) {
      if (-not (Test-PfProperty $edit $name)) { Stop-PfMalformed "AUTHORITY_MALFORMED" }
    }
    if (-not (Test-PfProperty $edit.actor "login") -or
        -not (Test-PfWholeNumber $edit.id 1) -or $edit.field -cne "body" -or
        $edit.html_url -isnot [string] -or [string]::IsNullOrWhiteSpace($edit.html_url) -or
        $edit.actor.login -isnot [string] -or
        [string]::IsNullOrWhiteSpace($edit.actor.login)) {
      Stop-PfMalformed "AUTHORITY_MALFORMED"
    }
    $edited = ConvertTo-PfInstant $edit.created_at "AUTHORITY_MALFORMED"
    if ((Test-PfSameIdentity $edit.actor.login $owner) -and $edited -gt $AnalysisInstant) {
      $events.Add((New-PfRuleEvidence $Rule "premise-rule-body-edit" $edited ([pscustomobject][ordered]@{
        kind = "body-edit"
        id = [long]$edit.id
        htmlUrl = [string]$edit.html_url
      })))
    }
  }

  foreach ($link in @(Assert-PfPagination $Authority.supersedingDecisions)) {
    foreach ($name in @("issueNumber", "html_url", "linked_at", "linkedBy", "supersedes")) {
      if (-not (Test-PfProperty $link $name)) { Stop-PfMalformed "AUTHORITY_MALFORMED" }
    }
    if (-not (Test-PfProperty $link.linkedBy "login") -or
        -not (Test-PfProperty $link.supersedes "repository") -or
        -not (Test-PfProperty $link.supersedes "issueNumber") -or
        -not (Test-PfWholeNumber $link.issueNumber 1) -or
        $link.html_url -isnot [string] -or [string]::IsNullOrWhiteSpace($link.html_url) -or
        $link.linkedBy.login -isnot [string] -or
        [string]::IsNullOrWhiteSpace($link.linkedBy.login) -or
        -not (Test-PfSameIdentity $link.supersedes.repository $Rule.repository) -or
        -not (Test-PfWholeNumber $link.supersedes.issueNumber 1) -or
        [long]$link.supersedes.issueNumber -ne [long]$Rule.issueNumber) {
      Stop-PfMalformed "AUTHORITY_MALFORMED"
    }
    $linked = ConvertTo-PfInstant $link.linked_at "AUTHORITY_MALFORMED"
    if ((Test-PfSameIdentity $link.linkedBy.login $owner) -and $linked -gt $AnalysisInstant) {
      $events.Add((New-PfRuleEvidence $Rule "linked-superseding-decision" $linked ([pscustomobject][ordered]@{
        kind = "decision"
        issueNumber = [long]$link.issueNumber
        htmlUrl = [string]$link.html_url
      })))
    }
  }

  return @($events)
}

function Invoke-PremiseFreshnessCheck {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][AllowNull()]$Candidate,
    [Parameter(Mandatory)][AllowNull()][scriptblock]$AuthorityProvider
  )

  $analysisInstant = $null
  try {
    $validated = Assert-PfCandidate $Candidate
    $analysisInstant = $validated.analysisInstant
    if ($null -eq $AuthorityProvider) {
      return New-PfResult "refuse" "AUTHORITY_UNAVAILABLE" $analysisInstant
    }
    $allEvents = [Collections.Generic.List[object]]::new()
    foreach ($rule in @($validated.rules)) {
      try {
        $authority = & $AuthorityProvider $rule
      } catch {
        return New-PfResult "refuse" "AUTHORITY_UNAVAILABLE" $analysisInstant ([pscustomobject][ordered]@{
          premiseRule = [pscustomobject][ordered]@{
            name = [string]$rule.name
            repository = [string]$rule.repository
            issueNumber = [long]$rule.issueNumber
          }
          amendmentShape = $null
          timestamp = $null
          source = $null
        })
      }
      foreach ($event in @(Get-PfAmendments $rule $authority $analysisInstant)) {
        $allEvents.Add($event)
      }
    }
    if ($allEvents.Count -gt 0) {
      $first = @($allEvents |
          Sort-Object { [datetimeoffset]$_.timestamp }, { $_.premiseRule.repository },
            { [long]$_.premiseRule.issueNumber } |
          Select-Object -First 1)[0]
      return New-PfResult "refuse" "PREMISE_AMENDED_AFTER_ANALYSIS" $analysisInstant $first
    }
    return New-PfResult "adopt" "PREMISES_FRESH" $analysisInstant
  } catch {
    $reason = if ($_.Exception.Message -match '^PF:([A-Z_]+)$') {
      $Matches[1]
    } else {
      "AUTHORITY_MALFORMED"
    }
    return New-PfResult "refuse" $reason $analysisInstant
  }
}

function Invoke-PremiseFreshnessRequest {
  [CmdletBinding()]
  param([Parameter(Mandatory)][AllowNull()]$Request)

  try {
    if (-not (Test-PfProperty $Request "schemaVersion") -or
        $Request.schemaVersion -cne $script:PremiseRequestSchema -or
        -not (Test-PfProperty $Request "candidate") -or
        -not (Test-PfProperty $Request "authority") -or
        $Request.authority -isnot [array]) {
      Stop-PfMalformed "REQUEST_MALFORMED"
    }
    $records = @($Request.authority)
    $provider = {
      param($Rule)
      $matches = @($records | Where-Object {
          (Test-PfProperty $_ "premiseRule") -and
          (Test-PfProperty $_.premiseRule "repository") -and
          (Test-PfProperty $_.premiseRule "issueNumber") -and
          (Test-PfSameIdentity $_.premiseRule.repository $Rule.repository) -and
          (Test-PfWholeNumber $_.premiseRule.issueNumber 1) -and
          [long]$_.premiseRule.issueNumber -eq [long]$Rule.issueNumber
        })
      if ($matches.Count -ne 1) { throw "authority lookup unavailable" }
      return $matches[0]
    }
    return Invoke-PremiseFreshnessCheck -Candidate $Request.candidate -AuthorityProvider $provider
  } catch {
    $reason = if ($_.Exception.Message -match '^PF:([A-Z_]+)$') {
      $Matches[1]
    } else {
      "REQUEST_MALFORMED"
    }
    return New-PfResult "refuse" $reason $null
  }
}

if ($MyInvocation.InvocationName -ne ".") {
  $result = $null
  try {
    if ([string]::IsNullOrWhiteSpace($RequestPath) -eq
        [string]::IsNullOrWhiteSpace($RequestJson)) {
      Stop-PfMalformed "REQUEST_MALFORMED"
    }
    $raw = if (-not [string]::IsNullOrWhiteSpace($RequestPath)) {
      if (-not (Test-Path -LiteralPath $RequestPath -PathType Leaf)) {
        Stop-PfMalformed "AUTHORITY_UNAVAILABLE"
      }
      Get-Content -LiteralPath $RequestPath -Raw
    } else {
      $RequestJson
    }
    Assert-PfRawRequestJson $raw
    $request = $raw | ConvertFrom-Json `
      -Depth $script:JsonImplementationDepth `
      -DateKind String `
      -ErrorAction Stop
    $result = Invoke-PremiseFreshnessRequest -Request $request
  } catch {
    $reason = if ($_.Exception.Message -match '^PF:([A-Z_]+)$') {
      $Matches[1]
    } else {
      "REQUEST_MALFORMED"
    }
    $result = New-PfResult "refuse" $reason $null
  }
  $result | ConvertTo-Json -Depth 12 -Compress
  if ($result.verdict -cne "adopt") { exit 1 }
}
