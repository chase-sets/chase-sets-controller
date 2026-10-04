[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string]$ReceiptPath,

  [Parameter(Mandatory)]
  [string]$ExpectedControllerHead
)

$ErrorActionPreference = "Stop"

# These literal switches are intentionally source-mutation seams. The checker
# tests copy this script and change exactly one true value to false; the
# production file has no runtime bypass parameter.
$guardEnabled = [ordered]@{
  "C01-RECEIPT-MISSING" = $true
  "C02-RECEIPT-UNREADABLE" = $true
  "C03-RECEIPT-EMPTY" = $true
  "C04-UTF8-INVALID" = $true
  "C05-JSON-MALFORMED" = $true
  "C06-JSON-DUPLICATE-MEMBER" = $true
  "C07-SCHEMA-VERSION" = $true
  "C08-UNKNOWN-ROOT" = $true
  "C09-UNKNOWN-NESTED" = $true
  "C10-WRONG-TYPE" = $true
  "C11-FILE-SIZE-BOUND" = $true
  "C12-DEPTH-BOUND" = $true
  "C13-CLAIM-COUNT-BOUND" = $true
  "C14-OBJECT-MEMBER-BOUND" = $true
  "C15-SHORT-STRING-BOUND" = $true
  "C16-OBSERVATION-BOUND" = $true
  "C17-NUMBER-CANONICAL" = $true
  "C18-CLAIMS-NONEMPTY" = $true
  "C19-GUARD-ID-REQUIRED" = $true
  "C20-GUARD-ID-UNIQUE" = $true
  "C21-MUTANT-ID-REQUIRED" = $true
  "C22-MUTANT-ID-UNIQUE" = $true
  "C23-GOVERNING-POINTER" = $true
  "C25-ONE-LEAF-DIFF" = $true
  "C26-PRESERVED-PROJECTION" = $true
  "C27-CANDIDATE-EXECUTED" = $true
  "C28-MUTANT-EXECUTED" = $true
  "C29-CANDIDATE-EXPECTATION-RESULT" = $true
  "C30-MUTANT-EXPECTATION-RESULT" = $true
  "C31-CANDIDATE-GREEN" = $true
  "C32-MUTANT-RED" = $true
  "C34-SIGNATURE-REQUIRED" = $true
  "C35-SIGNATURE-MATCH" = $true
  "C36-ENUM-CLOSED" = $true
}

$failures = [Collections.Generic.List[string]]::new()
$failureSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)

function Test-GuardEnabled([string]$GuardId) {
  return [bool]$guardEnabled[$GuardId]
}

function Add-Failure([string]$Code, [string]$GuardId = "") {
  if ($GuardId -and -not (Test-GuardEnabled $GuardId)) { return }
  if ($failureSet.Add($Code)) { $failures.Add($Code) }
}

function Stop-InvalidReceipt {
  $ordered = @($failures)
  [Array]::Sort($ordered, [StringComparer]::Ordinal)
  throw "FAIL fail-closed-guard-evidence: $($ordered -join ',')"
}

function Complete-EarlyGuard([string]$Code, [string]$GuardId) {
  Add-Failure $Code $GuardId
  if ($failures.Count -gt 0) { Stop-InvalidReceipt }
  Write-Output "PASS fail-closed-guard-evidence bypass-witness=$GuardId"
}

function New-OrdinalMap {
  return [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
}

function Test-Map($Value) {
  return $Value -is [Collections.Generic.Dictionary[string, object]]
}

function Has-Key($Map, [string]$Name) {
  return (Test-Map $Map) -and $Map.ContainsKey($Name)
}

function Get-Key($Map, [string]$Name) {
  if (Has-Key $Map $Name) { return ,$Map[$Name] }
  return $null
}

function Convert-JsonElement([System.Text.Json.JsonElement]$Element) {
  switch ($Element.ValueKind) {
    ([System.Text.Json.JsonValueKind]::Object) {
      $map = New-OrdinalMap
      foreach ($property in $Element.EnumerateObject()) {
        $map[$property.Name] = Convert-JsonElement $property.Value
      }
      return $map
    }
    ([System.Text.Json.JsonValueKind]::Array) {
      $items = [Collections.Generic.List[object]]::new()
      foreach ($item in $Element.EnumerateArray()) {
        $items.Add((Convert-JsonElement $item))
      }
      return ,$items.ToArray()
    }
    ([System.Text.Json.JsonValueKind]::String) {
      return $Element.GetString()
    }
    ([System.Text.Json.JsonValueKind]::Number) {
      $number = 0L
      if ($Element.TryGetInt64([ref]$number)) { return $number }
      return [pscustomobject]@{ invalidNumberToken = $Element.GetRawText() }
    }
    ([System.Text.Json.JsonValueKind]::True) { return $true }
    ([System.Text.Json.JsonValueKind]::False) { return $false }
    ([System.Text.Json.JsonValueKind]::Null) { return $null }
    default { return $null }
  }
}

function Get-Canonical($Value) {
  if ($null -eq $Value) { return "n" }
  if ($Value -is [bool]) { return $(if ($Value) { "b:true" } else { "b:false" }) }
  if ($Value -is [sbyte] -or $Value -is [byte] -or
      $Value -is [int16] -or $Value -is [uint16] -or
      $Value -is [int32] -or $Value -is [uint32] -or
      $Value -is [int64]) {
    return "i:$([Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture))"
  }
  if ($Value -is [string]) {
    return "s:$([System.Text.Json.JsonSerializer]::Serialize(
        [string]$Value,
        [System.Text.Json.JsonSerializerOptions]::new()
      ))"
  }
  if (Test-Map $Value) {
    $keys = [string[]]@($Value.Keys)
    [Array]::Sort($keys, [StringComparer]::Ordinal)
    $parts = foreach ($key in $keys) {
      "$([System.Text.Json.JsonSerializer]::Serialize(
          [string]$key,
          [System.Text.Json.JsonSerializerOptions]::new()
        ))=$(Get-Canonical $Value[$key])"
    }
    return "o:{$($parts -join ';')}"
  }
  if ($Value -is [Array]) {
    $parts = foreach ($item in $Value) { Get-Canonical $item }
    return "a:[$($parts -join ';')]"
  }
  if ($Value.PSObject.Properties["invalidNumberToken"]) {
    return "x:$($Value.invalidNumberToken)"
  }
  return "x:$([string]$Value)"
}

function Copy-GenericValue($Value) {
  if (Test-Map $Value) {
    $copy = New-OrdinalMap
    foreach ($key in $Value.Keys) { $copy[$key] = Copy-GenericValue $Value[$key] }
    return $copy
  }
  if ($Value -is [Array]) {
    $items = [Collections.Generic.List[object]]::new()
    foreach ($item in $Value) { $items.Add((Copy-GenericValue $item)) }
    return ,$items.ToArray()
  }
  return $Value
}

function Escape-PointerSegment([string]$Segment) {
  return $Segment.Replace("~", "~0").Replace("/", "~1")
}

function Get-InputDiffs($Left, $Right, [string]$Path, [Collections.Generic.List[string]]$Diffs) {
  if ((Test-Map $Left) -and (Test-Map $Right)) {
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($key in $Left.Keys) { [void]$names.Add($key) }
    foreach ($key in $Right.Keys) { [void]$names.Add($key) }
    $sorted = [string[]]@($names)
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    foreach ($key in $sorted) {
      $child = "$Path/$(Escape-PointerSegment $key)"
      if (-not $Left.ContainsKey($key) -or -not $Right.ContainsKey($key)) {
        $Diffs.Add($child)
      } else {
        Get-InputDiffs $Left[$key] $Right[$key] $child $Diffs
      }
    }
    return
  }
  if (($Left -is [Array]) -and ($Right -is [Array])) {
    if ((Get-Canonical $Left) -cne (Get-Canonical $Right)) { $Diffs.Add($Path) }
    return
  }
  if ((Get-Canonical $Left) -cne (Get-Canonical $Right)) { $Diffs.Add($Path) }
}

function ConvertFrom-Pointer([string]$Pointer) {
  if ([string]::IsNullOrWhiteSpace($Pointer) -or $Pointer.Length -gt 512 -or
      $Pointer[0] -cne "/" -or $Pointer -match "~(?![01])") {
    return $null
  }
  $raw = $Pointer.Substring(1).Split("/")
  if ($raw.Count -lt 2) { return $null }
  $segments = [Collections.Generic.List[string]]::new()
  foreach ($segment in $raw) {
    $decoded = $segment.Replace("~1", "/").Replace("~0", "~")
    if ([string]::IsNullOrEmpty($decoded) -or $decoded -ceq "-") {
      return $null
    }
    $segments.Add($decoded)
  }
  return ,$segments.ToArray()
}

function Insert-AtPointer($Preserved, [string[]]$Segments, $Value) {
  if (-not (Test-Map $Preserved) -or $null -eq $Segments) { return $null }
  $copy = Copy-GenericValue $Preserved
  $cursor = $copy
  for ($index = 0; $index -lt $Segments.Count; $index++) {
    $segment = $Segments[$index]
    if ($cursor.ContainsKey($segment)) { return $null }
    if ($index -eq $Segments.Count - 1) {
      $cursor[$segment] = Copy-GenericValue $Value
    } else {
      $next = New-OrdinalMap
      $cursor[$segment] = $next
      $cursor = $next
    }
  }
  return $copy
}

function Assert-StructuralObject(
  $Value,
  [string[]]$Allowed,
  [string[]]$Required,
  [string]$ClosureGuard
) {
  if (-not (Test-Map $Value)) {
    Add-Failure "WRONG_TYPE" "C10-WRONG-TYPE"
    return $false
  }
  $allowedSet = [Collections.Generic.HashSet[string]]::new($Allowed, [StringComparer]::Ordinal)
  foreach ($key in $Value.Keys) {
    if (-not $allowedSet.Contains($key)) {
      Add-Failure "UNKNOWN_PROPERTY" $ClosureGuard
    }
  }
  foreach ($key in $Required) {
    if (-not $Value.ContainsKey($key)) {
      Add-Failure "REQUIRED_PROPERTY_MISSING" "C10-WRONG-TYPE"
    }
  }
  return $true
}

function Assert-String(
  $Value,
  [string]$Code,
  [string]$GuardId,
  [int]$Maximum,
  [bool]$NonBlank = $false
) {
  if ($Value -isnot [string]) {
    Add-Failure "WRONG_TYPE" "C10-WRONG-TYPE"
    return $false
  }
  if (($NonBlank -and [string]::IsNullOrWhiteSpace($Value)) -or $Value.Length -gt $Maximum) {
    Add-Failure $Code $GuardId
    return $false
  }
  return $true
}

function Inspect-TokenTree(
  [System.Text.Json.JsonElement]$Element,
  [int]$Depth
) {
  if ($Depth -gt 32) { Add-Failure "DEPTH_LIMIT_EXCEEDED" "C12-DEPTH-BOUND" }
  switch ($Element.ValueKind) {
    ([System.Text.Json.JsonValueKind]::Object) {
      $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
      $count = 0
      foreach ($property in $Element.EnumerateObject()) {
        $count += 1
        if (-not $names.Add($property.Name)) {
          Add-Failure "DUPLICATE_JSON_MEMBER" "C06-JSON-DUPLICATE-MEMBER"
        }
        Inspect-TokenTree $property.Value ($Depth + 1)
      }
      if ($count -gt 256) { Add-Failure "OBJECT_MEMBER_LIMIT_EXCEEDED" "C14-OBJECT-MEMBER-BOUND" }
    }
    ([System.Text.Json.JsonValueKind]::Array) {
      foreach ($item in $Element.EnumerateArray()) { Inspect-TokenTree $item ($Depth + 1) }
    }
    ([System.Text.Json.JsonValueKind]::String) {
      if ($Element.GetString().Length -gt 4096) {
        Add-Failure "STRING_LIMIT_EXCEEDED" "C16-OBSERVATION-BOUND"
      }
    }
    ([System.Text.Json.JsonValueKind]::Number) {
      $token = $Element.GetRawText()
      $parsed = 0L
      if ($token -cnotmatch "^(0|-[1-9][0-9]*|[1-9][0-9]*)$" -or
          -not [long]::TryParse(
            $token,
            [Globalization.NumberStyles]::AllowLeadingSign,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$parsed
          )) {
        Add-Failure "NUMBER_NOT_CANONICAL" "C17-NUMBER-CANONICAL"
      }
    }
  }
}

function New-FallbackReceiptText([string]$Head) {
  $fallback = [ordered]@{
    schemaVersion = "fail-closed-guard-evidence/v1"
    subject = [ordered]@{ controllerHead = $Head; batteryId = "malformed-json-bypass-witness" }
    claims = @(
      [ordered]@{
        guardId = "fallback"
        governingVariable = [ordered]@{ pointer = "/guards/fallback/enabled"; candidateValue = $true; bypassValue = $false }
        preservedVariables = [ordered]@{}
        candidate = [ordered]@{
          inputs = [ordered]@{ guards = [ordered]@{ fallback = [ordered]@{ enabled = $true } } }
          executed = $true
          expectation = [ordered]@{ testOutcome = "pass"; observation = "PASS"; failureSignature = $null }
          result = [ordered]@{ testOutcome = "pass"; observation = "PASS"; failureSignature = $null }
        }
        bypassMutant = [ordered]@{
          id = "fallback-mutant"
          change = "fallback"
          inputs = [ordered]@{ guards = [ordered]@{ fallback = [ordered]@{ enabled = $false } } }
          executed = $true
          expectation = [ordered]@{ testOutcome = "fail"; observation = "FAIL"; failureSignature = "fallback-killed" }
          result = [ordered]@{ testOutcome = "fail"; observation = "FAIL"; failureSignature = "fallback-killed" }
        }
        failureSignature = "fallback-killed"
      }
    )
  }
  return $fallback | ConvertTo-Json -Compress -Depth 12
}

if ($ExpectedControllerHead -cnotmatch "^[a-f0-9]{40}$") {
  Add-Failure "EXPECTED_CONTROLLER_HEAD_INVALID"
  Stop-InvalidReceipt
}

$resolvedReceipt = $null
try { $resolvedReceipt = [IO.Path]::GetFullPath($ReceiptPath) } catch {}
if (-not $resolvedReceipt -or -not (Test-Path -LiteralPath $resolvedReceipt)) {
  Complete-EarlyGuard "RECEIPT_MISSING" "C01-RECEIPT-MISSING"
  return
}
if (-not (Test-Path -LiteralPath $resolvedReceipt -PathType Leaf)) {
  Complete-EarlyGuard "RECEIPT_UNREADABLE" "C02-RECEIPT-UNREADABLE"
  return
}

try {
  $bytes = [IO.File]::ReadAllBytes($resolvedReceipt)
} catch {
  Complete-EarlyGuard "RECEIPT_UNREADABLE" "C02-RECEIPT-UNREADABLE"
  return
}
if ($bytes.Length -gt 1MB) {
  Complete-EarlyGuard "RECEIPT_TOO_LARGE" "C11-FILE-SIZE-BOUND"
  return
}
if ($bytes.Length -eq 0) {
  Complete-EarlyGuard "RECEIPT_EMPTY" "C03-RECEIPT-EMPTY"
  return
}

$text = $null
try {
  $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
} catch {
  if (Test-GuardEnabled "C04-UTF8-INVALID") {
    Complete-EarlyGuard "INVALID_UTF8" "C04-UTF8-INVALID"
    return
  }
  $text = [Text.UTF8Encoding]::new($false, $false).GetString($bytes)
}
if ([string]::IsNullOrWhiteSpace($text)) {
  Complete-EarlyGuard "RECEIPT_EMPTY" "C03-RECEIPT-EMPTY"
  return
}

$document = $null
try {
  $options = [System.Text.Json.JsonDocumentOptions]::new()
  $options.MaxDepth = 2048
  $options.AllowTrailingCommas = $false
  $options.CommentHandling = [System.Text.Json.JsonCommentHandling]::Disallow
  $document = [System.Text.Json.JsonDocument]::Parse($text, $options)
} catch {
  if (Test-GuardEnabled "C05-JSON-MALFORMED") {
    Complete-EarlyGuard "MALFORMED_JSON" "C05-JSON-MALFORMED"
    return
  }
  $document = [System.Text.Json.JsonDocument]::Parse((New-FallbackReceiptText $ExpectedControllerHead))
}

try {
  Inspect-TokenTree $document.RootElement 1
  $root = Convert-JsonElement $document.RootElement

  if (-not (Assert-StructuralObject $root @("schemaVersion", "subject", "claims") @("schemaVersion", "subject", "claims") "C08-UNKNOWN-ROOT")) {
    Stop-InvalidReceipt
  }
  if ((Get-Key $root "schemaVersion") -isnot [string] -or
      (Get-Key $root "schemaVersion") -cne "fail-closed-guard-evidence/v1") {
    Add-Failure "UNSUPPORTED_SCHEMA_VERSION" "C07-SCHEMA-VERSION"
  }

  $subject = Get-Key $root "subject"
  if (Assert-StructuralObject $subject @("controllerHead", "batteryId") @("controllerHead", "batteryId") "C09-UNKNOWN-NESTED") {
    $controllerHead = Get-Key $subject "controllerHead"
    if ($controllerHead -isnot [string] -or
        $controllerHead -cnotmatch "^[a-f0-9]{40}$" -or
        $controllerHead -cne $ExpectedControllerHead) {
      Add-Failure "CONTROLLER_HEAD_MISMATCH"
    }
    [void](Assert-String (Get-Key $subject "batteryId") "SHORT_STRING_LIMIT_EXCEEDED" "C15-SHORT-STRING-BOUND" 512 $true)
  }

  $claims = Get-Key $root "claims"
  if ($claims -isnot [Array]) {
    Add-Failure "WRONG_TYPE" "C10-WRONG-TYPE"
    if ($failures.Count -gt 0) { Stop-InvalidReceipt }
    Write-Output "PASS fail-closed-guard-evidence bypass-witness=C10-WRONG-TYPE"
    return
  }
  if ($claims.Count -gt 256) { Add-Failure "CLAIM_COUNT_LIMIT_EXCEEDED" "C13-CLAIM-COUNT-BOUND" }
  if ($claims.Count -lt 1) { Add-Failure "CLAIMS_EMPTY" "C18-CLAIMS-NONEMPTY" }

  $guardIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  $mutantIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)

  foreach ($claim in $claims) {
    if (-not (Assert-StructuralObject $claim @(
          "guardId", "governingVariable", "preservedVariables", "candidate",
          "bypassMutant", "failureSignature"
        ) @(
          "guardId", "governingVariable", "preservedVariables", "candidate",
          "bypassMutant", "failureSignature"
        ) "C09-UNKNOWN-NESTED")) {
      continue
    }

    $guardId = Get-Key $claim "guardId"
    if (-not (Assert-String $guardId "GUARD_ID_REQUIRED" "C19-GUARD-ID-REQUIRED" 512 $true)) {
      $guardId = ""
    } elseif (-not $guardIds.Add($guardId)) {
      Add-Failure "GUARD_ID_DUPLICATE" "C20-GUARD-ID-UNIQUE"
    }

    $claimSignature = Get-Key $claim "failureSignature"
    [void](Assert-String $claimSignature "FAILURE_SIGNATURE_REQUIRED" "C34-SIGNATURE-REQUIRED" 512 $true)

    $governing = Get-Key $claim "governingVariable"
    $governingValid = Assert-StructuralObject $governing @(
      "pointer", "candidateValue", "bypassValue"
    ) @(
      "pointer", "candidateValue", "bypassValue"
    ) "C09-UNKNOWN-NESTED"
    $pointer = if ($governingValid) { Get-Key $governing "pointer" } else { $null }
    $pointerStringValid = Assert-String $pointer "GOVERNING_POINTER_INVALID" "C23-GOVERNING-POINTER" 512 $true
    $segments = if ($pointerStringValid) { ConvertFrom-Pointer $pointer } else { $null }
    if ($null -eq $segments) { Add-Failure "GOVERNING_POINTER_INVALID" "C23-GOVERNING-POINTER" }

    $candidateValue = if ($governingValid) { Get-Key $governing "candidateValue" } else { $null }
    $bypassValue = if ($governingValid) { Get-Key $governing "bypassValue" } else { $null }
    $candidateScalar = $null -eq $candidateValue -or
      $candidateValue -is [string] -or $candidateValue -is [bool] -or
      $candidateValue -is [ValueType]
    $bypassScalar = $null -eq $bypassValue -or
      $bypassValue -is [string] -or $bypassValue -is [bool] -or
      $bypassValue -is [ValueType]
    if (-not $candidateScalar -or -not $bypassScalar) {
      Add-Failure "WRONG_TYPE" "C10-WRONG-TYPE"
    }

    $preserved = Get-Key $claim "preservedVariables"
    if (-not (Test-Map $preserved)) { Add-Failure "WRONG_TYPE" "C10-WRONG-TYPE" }

    $candidate = Get-Key $claim "candidate"
    $candidateValid = Assert-StructuralObject $candidate @(
      "inputs", "executed", "expectation", "result"
    ) @(
      "inputs", "executed", "expectation", "result"
    ) "C09-UNKNOWN-NESTED"
    $mutant = Get-Key $claim "bypassMutant"
    $mutantValid = Assert-StructuralObject $mutant @(
      "id", "change", "inputs", "executed", "expectation", "result"
    ) @(
      "id", "change", "inputs", "executed", "expectation", "result"
    ) "C09-UNKNOWN-NESTED"

    if ($mutantValid) {
      $mutantId = Get-Key $mutant "id"
      if (-not (Assert-String $mutantId "MUTANT_ID_REQUIRED" "C21-MUTANT-ID-REQUIRED" 512 $true)) {
        $mutantId = ""
      } elseif (-not $mutantIds.Add($mutantId)) {
        Add-Failure "MUTANT_ID_DUPLICATE" "C22-MUTANT-ID-UNIQUE"
      }
      [void](Assert-String (Get-Key $mutant "change") "SHORT_STRING_LIMIT_EXCEEDED" "C15-SHORT-STRING-BOUND" 512 $true)
    }

    $candidateInputs = if ($candidateValid) { Get-Key $candidate "inputs" } else { $null }
    $mutantInputs = if ($mutantValid) { Get-Key $mutant "inputs" } else { $null }
    if (-not (Test-Map $candidateInputs) -or -not (Test-Map $mutantInputs)) {
      Add-Failure "WRONG_TYPE" "C10-WRONG-TYPE"
    }

    $candidateExecuted = if ($candidateValid) { Get-Key $candidate "executed" } else { $null }
    if ($candidateValid -and $candidateExecuted -isnot [bool]) {
      Add-Failure "WRONG_TYPE" "C10-WRONG-TYPE"
    } elseif ($candidateValid -and $candidateExecuted -cne $true) {
      Add-Failure "CANDIDATE_NOT_EXECUTED" "C27-CANDIDATE-EXECUTED"
    }
    $mutantExecuted = if ($mutantValid) { Get-Key $mutant "executed" } else { $null }
    if ($mutantValid -and $mutantExecuted -isnot [bool]) {
      Add-Failure "WRONG_TYPE" "C10-WRONG-TYPE"
    } elseif ($mutantValid -and $mutantExecuted -cne $true) {
      Add-Failure "MUTANT_NOT_EXECUTED" "C28-MUTANT-EXECUTED"
    }

    if ($null -ne $segments -and (Test-Map $preserved) -and
        (Test-Map $candidateInputs) -and (Test-Map $mutantInputs)) {
      $diffs = [Collections.Generic.List[string]]::new()
      Get-InputDiffs $candidateInputs $mutantInputs "" $diffs
      $isolated = $diffs.Count -eq 1 -and $diffs[0] -ceq $pointer -and
        (Get-Canonical $candidateValue) -cne (Get-Canonical $bypassValue)
      if (-not $isolated) {
        Add-Failure "GOVERNING_VARIABLE_NOT_ISOLATED" "C25-ONE-LEAF-DIFF"
      }

      $expectedCandidate = Insert-AtPointer $preserved $segments $candidateValue
      $expectedMutant = Insert-AtPointer $preserved $segments $bypassValue
      if ($null -eq $expectedCandidate -or $null -eq $expectedMutant -or
          (Get-Canonical $candidateInputs) -cne (Get-Canonical $expectedCandidate) -or
          (Get-Canonical $mutantInputs) -cne (Get-Canonical $expectedMutant)) {
        Add-Failure "PRESERVED_VARIABLES_CHANGED" "C26-PRESERVED-PROJECTION"
      }
    }

    $candidateExpectation = if ($candidateValid) { Get-Key $candidate "expectation" } else { $null }
    $candidateResult = if ($candidateValid) { Get-Key $candidate "result" } else { $null }
    $mutantExpectation = if ($mutantValid) { Get-Key $mutant "expectation" } else { $null }
    $mutantResult = if ($mutantValid) { Get-Key $mutant "result" } else { $null }
    $observationAllowed = @("testOutcome", "observation", "failureSignature")
    $observationRequired = @("testOutcome", "observation", "failureSignature")
    $candidateExpectationValid = Assert-StructuralObject $candidateExpectation $observationAllowed $observationRequired "C09-UNKNOWN-NESTED"
    $candidateResultValid = Assert-StructuralObject $candidateResult $observationAllowed $observationRequired "C09-UNKNOWN-NESTED"
    $mutantExpectationValid = Assert-StructuralObject $mutantExpectation $observationAllowed $observationRequired "C09-UNKNOWN-NESTED"
    $mutantResultValid = Assert-StructuralObject $mutantResult $observationAllowed $observationRequired "C09-UNKNOWN-NESTED"

    foreach ($observation in @($candidateExpectation, $candidateResult, $mutantExpectation, $mutantResult)) {
      if (Test-Map $observation) {
        [void](Assert-String (Get-Key $observation "observation") "STRING_LIMIT_EXCEEDED" "C16-OBSERVATION-BOUND" 4096 $false)
      }
    }

    if ($candidateExpectationValid -and $candidateResultValid -and
        (Get-Canonical $candidateExpectation) -cne (Get-Canonical $candidateResult)) {
      Add-Failure "CANDIDATE_EXPECTATION_RESULT_MISMATCH" "C29-CANDIDATE-EXPECTATION-RESULT"
    }
    if ($mutantExpectationValid -and $mutantResultValid -and
        (Get-Canonical $mutantExpectation) -cne (Get-Canonical $mutantResult)) {
      Add-Failure "MUTANT_EXPECTATION_RESULT_MISMATCH" "C30-MUTANT-EXPECTATION-RESULT"
    }

    $candidateOutcome = if ($candidateResultValid) { Get-Key $candidateResult "testOutcome" } else { $null }
    $mutantOutcome = if ($mutantResultValid) { Get-Key $mutantResult "testOutcome" } else { $null }
    if ($candidateOutcome -isnot [string] -or $candidateOutcome -notin @("pass", "fail") -or
        $mutantOutcome -isnot [string] -or $mutantOutcome -notin @("pass", "fail")) {
      Add-Failure "UNKNOWN_ENUM" "C36-ENUM-CLOSED"
    }
    if ($candidateOutcome -in @("pass", "fail") -and
        ($candidateOutcome -cne "pass" -or $null -ne (Get-Key $candidateResult "failureSignature"))) {
      Add-Failure "CANDIDATE_NOT_PASS" "C31-CANDIDATE-GREEN"
    }
    if ($mutantOutcome -in @("pass", "fail") -and $mutantOutcome -cne "fail") {
      Add-Failure "MUTANT_NOT_FAIL" "C32-MUTANT-RED"
    }
    if ($candidateResultValid -and $mutantResultValid -and
        (Get-Canonical $candidateResult) -ceq (Get-Canonical $mutantResult)) {
      Add-Failure "SAME_RESULT_EVIDENCE"
    }

    if ($mutantResultValid -and $mutantOutcome -ceq "fail") {
      $mutantSignature = Get-Key $mutantResult "failureSignature"
      if ($mutantSignature -isnot [string] -or
          [string]::IsNullOrWhiteSpace($mutantSignature) -or
          $mutantSignature.Length -gt 512) {
        Add-Failure "FAILURE_SIGNATURE_REQUIRED" "C34-SIGNATURE-REQUIRED"
      }
      if ($claimSignature -is [string] -and
          ($mutantSignature -isnot [string] -or $mutantSignature -cne $claimSignature -or
           (Get-Key $mutantExpectation "failureSignature") -cne $claimSignature)) {
        Add-Failure "FAILURE_SIGNATURE_MISMATCH" "C35-SIGNATURE-MATCH"
      }
    }
  }

  if ($failures.Count -gt 0) { Stop-InvalidReceipt }
  Write-Output "PASS fail-closed-guard-evidence head=$ExpectedControllerHead claims=$($claims.Count)"
} finally {
  if ($null -ne $document) { $document.Dispose() }
}
