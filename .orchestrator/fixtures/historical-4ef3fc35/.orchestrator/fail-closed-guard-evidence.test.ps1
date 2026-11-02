[CmdletBinding()]
param(
  [ValidateSet("All", "BypassMutants", "ManifestSatisfiability", "ReceiptClaims")]
  [string]$Scenario = "All",

  [string]$ExpectedControllerHead = "",

  [string]$SuiteResultOut = ""
)

$ErrorActionPreference = "Stop"
$checker = Join-Path $PSScriptRoot "fail-closed-guard-evidence.ps1"
$controllerRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("fail-closed-guard-evidence-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $testRoot | Out-Null

$manifest = @(
  [ordered]@{ id = "C01-RECEIPT-MISSING"; mutant = "bypass-receipt-missing" },
  [ordered]@{ id = "C02-RECEIPT-UNREADABLE"; mutant = "bypass-receipt-unreadable" },
  [ordered]@{ id = "C03-RECEIPT-EMPTY"; mutant = "bypass-receipt-empty" },
  [ordered]@{ id = "C04-UTF8-INVALID"; mutant = "bypass-utf8-validation" },
  [ordered]@{ id = "C05-JSON-MALFORMED"; mutant = "bypass-json-parse" },
  [ordered]@{ id = "C06-JSON-DUPLICATE-MEMBER"; mutant = "bypass-duplicate-member-scan" },
  [ordered]@{ id = "C07-SCHEMA-VERSION"; mutant = "bypass-schema-version" },
  [ordered]@{ id = "C08-UNKNOWN-ROOT"; mutant = "bypass-root-closure" },
  [ordered]@{ id = "C09-UNKNOWN-NESTED"; mutant = "bypass-nested-closure" },
  [ordered]@{ id = "C10-WRONG-TYPE"; mutant = "bypass-type-check" },
  [ordered]@{ id = "C11-FILE-SIZE-BOUND"; mutant = "remove-file-size-bound" },
  [ordered]@{ id = "C12-DEPTH-BOUND"; mutant = "remove-depth-bound" },
  [ordered]@{ id = "C13-CLAIM-COUNT-BOUND"; mutant = "remove-claim-count-bound" },
  [ordered]@{ id = "C14-OBJECT-MEMBER-BOUND"; mutant = "remove-object-member-bound" },
  [ordered]@{ id = "C15-SHORT-STRING-BOUND"; mutant = "remove-short-string-bound" },
  [ordered]@{ id = "C16-OBSERVATION-BOUND"; mutant = "remove-observation-bound" },
  [ordered]@{ id = "C17-NUMBER-CANONICAL"; mutant = "bypass-number-token-check" },
  [ordered]@{ id = "C18-CLAIMS-NONEMPTY"; mutant = "allow-empty-claims" },
  [ordered]@{ id = "C19-GUARD-ID-REQUIRED"; mutant = "remove-guard-id-required" },
  [ordered]@{ id = "C20-GUARD-ID-UNIQUE"; mutant = "remove-guard-id-unique" },
  [ordered]@{ id = "C21-MUTANT-ID-REQUIRED"; mutant = "remove-mutant-id-required" },
  [ordered]@{ id = "C22-MUTANT-ID-UNIQUE"; mutant = "remove-mutant-id-unique" },
  [ordered]@{ id = "C23-GOVERNING-POINTER"; mutant = "remove-governing-pointer-check" },
  [ordered]@{ id = "C25-ONE-LEAF-DIFF"; mutant = "allow-multiple-input-diffs" },
  [ordered]@{ id = "C26-PRESERVED-PROJECTION"; mutant = "remove-preserved-projection-equality" },
  [ordered]@{ id = "C27-CANDIDATE-EXECUTED"; mutant = "allow-unexecuted-candidate" },
  [ordered]@{ id = "C28-MUTANT-EXECUTED"; mutant = "allow-unexecuted-mutant" },
  [ordered]@{ id = "C29-CANDIDATE-EXPECTATION-RESULT"; mutant = "ignore-candidate-expectation-result-mismatch" },
  [ordered]@{ id = "C30-MUTANT-EXPECTATION-RESULT"; mutant = "ignore-mutant-expectation-result-mismatch" },
  [ordered]@{ id = "C31-CANDIDATE-GREEN"; mutant = "allow-candidate-nonpass" },
  [ordered]@{ id = "C32-MUTANT-RED"; mutant = "allow-mutant-nonfail" },
  [ordered]@{ id = "C34-SIGNATURE-REQUIRED"; mutant = "remove-failure-signature-required" },
  [ordered]@{ id = "C35-SIGNATURE-MATCH"; mutant = "ignore-failure-signature-mismatch" },
  [ordered]@{ id = "C36-ENUM-CLOSED"; mutant = "allow-unknown-enum" }
)

function Assert-Test([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Get-LiveHead {
  $head = (& git -C $controllerRoot rev-parse HEAD 2>&1 | Out-String).Trim()
  Assert-Test ($LASTEXITCODE -eq 0 -and $head -cmatch "^[a-f0-9]{40}$") "cannot resolve controller HEAD"
  return $head
}

function New-Preserved {
  return [ordered]@{
    controllerRoot = "."
    fixture = "minimal-valid-v1"
    parallelism = 1
    schemaVersion = "fail-closed-guard-evidence/v1"
    testCommand = "pwsh -NoProfile -NonInteractive -File .orchestrator/fail-closed-guard-evidence.test.ps1 -Scenario BypassMutants"
  }
}

function Copy-Map($Value) {
  if ($Value -is [Collections.IDictionary]) {
    $copy = [ordered]@{}
    foreach ($key in $Value.Keys) { $copy[$key] = Copy-Map $Value[$key] }
    return $copy
  }
  if ($Value -is [Array]) {
    return ,@($Value | ForEach-Object { Copy-Map $_ })
  }
  return $Value
}

function Insert-TestPointer($Preserved, [string]$Pointer, $Value) {
  $copy = Copy-Map $Preserved
  $segments = @($Pointer.Substring(1).Split("/") | ForEach-Object {
    $_.Replace("~1", "/").Replace("~0", "~")
  })
  $cursor = $copy
  for ($index = 0; $index -lt $segments.Count; $index++) {
    if ($index -eq $segments.Count - 1) {
      $cursor[$segments[$index]] = $Value
    } else {
      $cursor[$segments[$index]] = [ordered]@{}
      $cursor = $cursor[$segments[$index]]
    }
  }
  return $copy
}

function New-Claim(
  [string]$GuardId,
  [string]$MutantId,
  [string]$Pointer = ""
) {
  if (-not $Pointer) { $Pointer = "/checkerGuards/$GuardId/enabled" }
  $preserved = New-Preserved
  $signature = "MUTANT_KILLED:$MutantId"
  return [ordered]@{
    guardId = $GuardId
    governingVariable = [ordered]@{
      pointer = $Pointer
      candidateValue = $true
      bypassValue = $false
    }
    preservedVariables = $preserved
    candidate = [ordered]@{
      inputs = Insert-TestPointer $preserved $Pointer $true
      executed = $true
      expectation = [ordered]@{ testOutcome = "pass"; observation = "PASS"; failureSignature = $null }
      result = [ordered]@{ testOutcome = "pass"; observation = "PASS"; failureSignature = $null }
    }
    bypassMutant = [ordered]@{
      id = $MutantId
      change = $MutantId
      inputs = Insert-TestPointer $preserved $Pointer $false
      executed = $true
      expectation = [ordered]@{ testOutcome = "fail"; observation = "FAIL"; failureSignature = $signature }
      result = [ordered]@{ testOutcome = "fail"; observation = "FAIL"; failureSignature = $signature }
    }
    failureSignature = $signature
  }
}

function New-Receipt([object[]]$Claims, [string]$Head) {
  return [ordered]@{
    schemaVersion = "fail-closed-guard-evidence/v1"
    subject = [ordered]@{
      controllerHead = $Head
      batteryId = "checker-suite"
    }
    claims = @($Claims)
  }
}

function Write-Receipt($Receipt, [string]$Path, [int]$Depth = 100) {
  [IO.File]::WriteAllText(
    $Path,
    ($Receipt | ConvertTo-Json -Compress -Depth $Depth),
    [Text.UTF8Encoding]::new($false)
  )
}

function Invoke-CheckerProcess(
  [string]$CheckerPath,
  [string]$ReceiptPath,
  [string]$Head
) {
  $output = & pwsh -NoProfile -NonInteractive -File $CheckerPath `
    -ReceiptPath $ReceiptPath -ExpectedControllerHead $Head 2>&1 | Out-String
  return [pscustomobject]@{ exitCode = $LASTEXITCODE; output = $output.Trim() }
}

function Assert-Rejected(
  [string]$CheckerPath,
  [string]$ReceiptPath,
  [string]$Head,
  [string]$Signature
) {
  $result = Invoke-CheckerProcess $CheckerPath $ReceiptPath $Head
  Assert-Test ($result.exitCode -ne 0) "invalid witness unexpectedly passed for $Signature"
  Assert-Test ($result.output -match [regex]::Escape($Signature)) "rejection did not contain $Signature (observed=$($result.output))"
  return $result
}

function Assert-Accepted(
  [string]$CheckerPath,
  [string]$ReceiptPath,
  [string]$Head,
  [string]$Context
) {
  $result = Invoke-CheckerProcess $CheckerPath $ReceiptPath $Head
  Assert-Test ($result.exitCode -eq 0) "$Context was rejected (observed=$($result.output))"
  return $result
}

function Add-DeepData($Receipt) {
  $cursor = [ordered]@{}
  $Receipt.claims[0].preservedVariables.deep = $cursor
  for ($index = 1; $index -le 31; $index++) {
    $cursor.next = [ordered]@{}
    $cursor = $cursor.next
  }
  $Receipt.claims[0].candidate.inputs = Insert-TestPointer $Receipt.claims[0].preservedVariables `
    $Receipt.claims[0].governingVariable.pointer $true
  $Receipt.claims[0].bypassMutant.inputs = Insert-TestPointer $Receipt.claims[0].preservedVariables `
    $Receipt.claims[0].governingVariable.pointer $false
}

function New-Witness(
  [string]$GuardId,
  [string]$MutantId,
  [string]$Head,
  [string]$Path
) {
  $pointer = if ($GuardId -ceq "C23-GOVERNING-POINTER") { "/onlyone" } else { "" }
  $claim = New-Claim $GuardId $MutantId $pointer
  $receipt = New-Receipt @($claim) $Head
  $rawTransform = $null

  switch ($GuardId) {
    "C01-RECEIPT-MISSING" {
      return [pscustomobject]@{ path = (Join-Path $testRoot "missing.json"); code = "RECEIPT_MISSING" }
    }
    "C02-RECEIPT-UNREADABLE" {
      $directory = Join-Path $testRoot "unreadable"
      New-Item -ItemType Directory -Path $directory -Force | Out-Null
      return [pscustomobject]@{ path = $directory; code = "RECEIPT_UNREADABLE" }
    }
    "C03-RECEIPT-EMPTY" {
      [IO.File]::WriteAllBytes($Path, [byte[]]@())
      return [pscustomobject]@{ path = $Path; code = "RECEIPT_EMPTY" }
    }
    "C04-UTF8-INVALID" {
      $receipt.subject.batteryId = "utf8-X"
      $text = $receipt | ConvertTo-Json -Compress -Depth 100
      $bytes = [Text.Encoding]::UTF8.GetBytes($text)
      $marker = [Text.Encoding]::UTF8.GetBytes("utf8-X")
      $start = -1
      for ($index = 0; $index -le $bytes.Length - $marker.Length; $index++) {
        $match = $true
        for ($offset = 0; $offset -lt $marker.Length; $offset++) {
          if ($bytes[$index + $offset] -ne $marker[$offset]) { $match = $false; break }
        }
        if ($match) { $start = $index; break }
      }
      Assert-Test ($start -ge 0) "UTF-8 witness marker was not found"
      $bytes[$start + 5] = 0xff
      [IO.File]::WriteAllBytes($Path, $bytes)
      return [pscustomobject]@{ path = $Path; code = "INVALID_UTF8" }
    }
    "C05-JSON-MALFORMED" {
      [IO.File]::WriteAllText($Path, "{", [Text.UTF8Encoding]::new($false))
      return [pscustomobject]@{ path = $Path; code = "MALFORMED_JSON" }
    }
    "C06-JSON-DUPLICATE-MEMBER" {
      $rawTransform = {
        param($json)
        $json.Replace(
          '"schemaVersion":"fail-closed-guard-evidence/v1"',
          '"schemaVersion":"fail-closed-guard-evidence/v1","schemaVersion":"fail-closed-guard-evidence/v1"'
        )
      }
    }
    "C07-SCHEMA-VERSION" { $receipt.schemaVersion = "fail-closed-guard-evidence/v2" }
    "C08-UNKNOWN-ROOT" { $receipt.complete = $true }
    "C09-UNKNOWN-NESTED" { $receipt.subject.complete = $true }
    "C10-WRONG-TYPE" { $receipt.claims = "wrong" }
    "C11-FILE-SIZE-BOUND" {
      $json = $receipt | ConvertTo-Json -Compress -Depth 100
      [IO.File]::WriteAllText($Path, $json + (" " * (1MB + 1)), [Text.UTF8Encoding]::new($false))
      return [pscustomobject]@{ path = $Path; code = "RECEIPT_TOO_LARGE" }
    }
    "C12-DEPTH-BOUND" { Add-DeepData $receipt }
    "C13-CLAIM-COUNT-BOUND" {
      $many = [Collections.Generic.List[object]]::new()
      foreach ($index in 1..257) {
        $many.Add((New-Claim "COUNT-$index" "count-mutant-$index"))
      }
      $receipt.claims = @($many)
    }
    "C14-OBJECT-MEMBER-BOUND" {
      foreach ($index in 1..257) { $receipt.claims[0].preservedVariables["member$index"] = $index }
      $receipt.claims[0].candidate.inputs = Insert-TestPointer $receipt.claims[0].preservedVariables `
        $receipt.claims[0].governingVariable.pointer $true
      $receipt.claims[0].bypassMutant.inputs = Insert-TestPointer $receipt.claims[0].preservedVariables `
        $receipt.claims[0].governingVariable.pointer $false
    }
    "C15-SHORT-STRING-BOUND" { $receipt.subject.batteryId = "x" * 513 }
    "C16-OBSERVATION-BOUND" {
      $receipt.claims[0].candidate.expectation.observation = "x" * 4097
      $receipt.claims[0].candidate.result.observation = "x" * 4097
    }
    "C17-NUMBER-CANONICAL" {
      $receipt.claims[0].preservedVariables.numberMarker = "number-marker"
      $receipt.claims[0].candidate.inputs = Insert-TestPointer $receipt.claims[0].preservedVariables `
        $receipt.claims[0].governingVariable.pointer $true
      $receipt.claims[0].bypassMutant.inputs = Insert-TestPointer $receipt.claims[0].preservedVariables `
        $receipt.claims[0].governingVariable.pointer $false
      $rawTransform = {
        param($json)
        $json.Replace('"numberMarker":"number-marker"', '"numberMarker":1.0')
      }
    }
    "C18-CLAIMS-NONEMPTY" { $receipt.claims = @() }
    "C19-GUARD-ID-REQUIRED" { $receipt.claims[0].guardId = " " }
    "C20-GUARD-ID-UNIQUE" {
      $second = New-Claim $GuardId "$MutantId-second"
      $receipt.claims = @($receipt.claims[0], $second)
    }
    "C21-MUTANT-ID-REQUIRED" { $receipt.claims[0].bypassMutant.id = " " }
    "C22-MUTANT-ID-UNIQUE" {
      $second = New-Claim "$GuardId-second" $MutantId
      $receipt.claims = @($receipt.claims[0], $second)
    }
    "C25-ONE-LEAF-DIFF" {
      $receipt.claims[0].governingVariable.bypassValue = $true
      $receipt.claims[0].bypassMutant.inputs = Copy-Map $receipt.claims[0].candidate.inputs
    }
    "C26-PRESERVED-PROJECTION" {
      $receipt.claims[0].candidate.inputs.sharedChanged = "same"
      $receipt.claims[0].bypassMutant.inputs.sharedChanged = "same"
    }
    "C27-CANDIDATE-EXECUTED" { $receipt.claims[0].candidate.executed = $false }
    "C28-MUTANT-EXECUTED" { $receipt.claims[0].bypassMutant.executed = $false }
    "C29-CANDIDATE-EXPECTATION-RESULT" { $receipt.claims[0].candidate.result.observation = "DIFFERENT" }
    "C30-MUTANT-EXPECTATION-RESULT" { $receipt.claims[0].bypassMutant.result.observation = "DIFFERENT" }
    "C31-CANDIDATE-GREEN" {
      $red = [ordered]@{ testOutcome = "fail"; observation = "CANDIDATE RED"; failureSignature = "candidate-red" }
      $receipt.claims[0].candidate.expectation = Copy-Map $red
      $receipt.claims[0].candidate.result = Copy-Map $red
    }
    "C32-MUTANT-RED" {
      $green = [ordered]@{ testOutcome = "pass"; observation = "MUTANT GREEN"; failureSignature = $null }
      $receipt.claims[0].bypassMutant.expectation = Copy-Map $green
      $receipt.claims[0].bypassMutant.result = Copy-Map $green
    }
    "C34-SIGNATURE-REQUIRED" {
      $receipt.claims[0].failureSignature = ""
      $receipt.claims[0].bypassMutant.expectation.failureSignature = ""
      $receipt.claims[0].bypassMutant.result.failureSignature = ""
    }
    "C35-SIGNATURE-MATCH" {
      $receipt.claims[0].bypassMutant.expectation.failureSignature = "different-signature"
      $receipt.claims[0].bypassMutant.result.failureSignature = "different-signature"
    }
    "C36-ENUM-CLOSED" {
      $receipt.claims[0].candidate.expectation.testOutcome = "unknown"
      $receipt.claims[0].candidate.result.testOutcome = "unknown"
    }
  }

  $json = $receipt | ConvertTo-Json -Compress -Depth 100
  if ($rawTransform) { $json = & $rawTransform $json }
  [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
  $codeByGuard = @{
    "C06-JSON-DUPLICATE-MEMBER" = "DUPLICATE_JSON_MEMBER"
    "C07-SCHEMA-VERSION" = "UNSUPPORTED_SCHEMA_VERSION"
    "C08-UNKNOWN-ROOT" = "UNKNOWN_PROPERTY"
    "C09-UNKNOWN-NESTED" = "UNKNOWN_PROPERTY"
    "C10-WRONG-TYPE" = "WRONG_TYPE"
    "C12-DEPTH-BOUND" = "DEPTH_LIMIT_EXCEEDED"
    "C13-CLAIM-COUNT-BOUND" = "CLAIM_COUNT_LIMIT_EXCEEDED"
    "C14-OBJECT-MEMBER-BOUND" = "OBJECT_MEMBER_LIMIT_EXCEEDED"
    "C15-SHORT-STRING-BOUND" = "SHORT_STRING_LIMIT_EXCEEDED"
    "C16-OBSERVATION-BOUND" = "STRING_LIMIT_EXCEEDED"
    "C17-NUMBER-CANONICAL" = "NUMBER_NOT_CANONICAL"
    "C18-CLAIMS-NONEMPTY" = "CLAIMS_EMPTY"
    "C19-GUARD-ID-REQUIRED" = "GUARD_ID_REQUIRED"
    "C20-GUARD-ID-UNIQUE" = "GUARD_ID_DUPLICATE"
    "C21-MUTANT-ID-REQUIRED" = "MUTANT_ID_REQUIRED"
    "C22-MUTANT-ID-UNIQUE" = "MUTANT_ID_DUPLICATE"
    "C23-GOVERNING-POINTER" = "GOVERNING_POINTER_INVALID"
    "C25-ONE-LEAF-DIFF" = "GOVERNING_VARIABLE_NOT_ISOLATED"
    "C26-PRESERVED-PROJECTION" = "PRESERVED_VARIABLES_CHANGED"
    "C27-CANDIDATE-EXECUTED" = "CANDIDATE_NOT_EXECUTED"
    "C28-MUTANT-EXECUTED" = "MUTANT_NOT_EXECUTED"
    "C29-CANDIDATE-EXPECTATION-RESULT" = "CANDIDATE_EXPECTATION_RESULT_MISMATCH"
    "C30-MUTANT-EXPECTATION-RESULT" = "MUTANT_EXPECTATION_RESULT_MISMATCH"
    "C31-CANDIDATE-GREEN" = "CANDIDATE_NOT_PASS"
    "C32-MUTANT-RED" = "MUTANT_NOT_FAIL"
    "C34-SIGNATURE-REQUIRED" = "FAILURE_SIGNATURE_REQUIRED"
    "C35-SIGNATURE-MATCH" = "FAILURE_SIGNATURE_MISMATCH"
    "C36-ENUM-CLOSED" = "UNKNOWN_ENUM"
  }
  return [pscustomobject]@{ path = $Path; code = $codeByGuard[$GuardId] }
}

function New-MutatedChecker([string]$GuardId) {
  $source = Get-Content -LiteralPath $checker -Raw
  $needle = "  `"$GuardId`" = `$true"
  Assert-Test (@([regex]::Matches($source, [regex]::Escape($needle))).Count -eq 1) `
    "mutant $GuardId did not match exactly one production guard switch"
  $mutated = $source.Replace($needle, "  `"$GuardId`" = `$false")
  $path = Join-Path $testRoot ("mutated-" + $GuardId + ".ps1")
  [IO.File]::WriteAllText($path, $mutated, [Text.UTF8Encoding]::new($false))
  return $path
}

function Invoke-ManifestSuite([string]$Head) {
  $applied = 0
  $killed = 0
  $witnessed = 0
  foreach ($row in $manifest) {
    $witnessPath = Join-Path $testRoot ("witness-" + $row.id + ".json")
    $witness = New-Witness $row.id $row.mutant $Head $witnessPath
    [void](Assert-Rejected $checker $witness.path $Head $witness.code)
    $mutatedChecker = New-MutatedChecker $row.id
    $applied += 1
    [void](Assert-Accepted $mutatedChecker $witness.path $Head "retained-all-other-guards witness $($row.id)")
    $killed += 1
    $witnessed += 1
    Write-Host "CLAIM $($row.id) candidate=PASS mutant=$($row.mutant):FAIL signature=MUTANT_KILLED:$($row.mutant) witness=SATISFIED"
  }
  return [pscustomobject]@{
    applied = $applied
    killed = $killed
    survivors = $applied - $killed
    notApplied = $manifest.Count - $applied
    advertised = $manifest.Count
    witnessed = $witnessed
    unwitnessed = $manifest.Count - $witnessed
  }
}

function Write-SuiteResult([string]$Head, [string]$OutPath, $CompletedSummary = $null) {
  Assert-Test (-not [string]::IsNullOrWhiteSpace($OutPath)) "ReceiptClaims requires -SuiteResultOut"
  $artifactRoot = [IO.Path]::GetFullPath((Join-Path $controllerRoot ".orchestrator/artifacts"))
  $resolvedOut = [IO.Path]::GetFullPath((Join-Path $controllerRoot $OutPath))
  Assert-Test ((Split-Path -Parent $resolvedOut).TrimEnd("\", "/") -ceq $artifactRoot.TrimEnd("\", "/")) `
    "suite result must be an immediate child of .orchestrator/artifacts"
  if (Test-Path -LiteralPath $resolvedOut) { Remove-Item -LiteralPath $resolvedOut -Force }

  $summary = if ($null -ne $CompletedSummary) { $CompletedSummary } else { Invoke-ManifestSuite $Head }
  Assert-Test ($summary.applied -eq 34 -and $summary.killed -eq 34 -and
    $summary.survivors -eq 0 -and $summary.notApplied -eq 0 -and
    $summary.witnessed -eq 34 -and $summary.unwitnessed -eq 0) "checker suite did not reach 34/34"

  $claims = foreach ($row in $manifest) { New-Claim $row.id $row.mutant }
  $result = [ordered]@{
    schemaVersion = "fail-closed-guard-suite-result/v1"
    subject = [ordered]@{ controllerHead = $Head }
    suite = [ordered]@{ id = "checker"; expectedClaimCount = 34 }
    execution = [ordered]@{
      runId = "checker-" + [guid]::NewGuid().ToString("N")
      executed = $true
      outcome = "pass"
    }
    claims = @($claims)
  }
  New-Item -ItemType Directory -Path $artifactRoot -Force | Out-Null
  $temporary = Join-Path $artifactRoot (".checker-" + [guid]::NewGuid().ToString("N") + ".tmp")
  try {
    [IO.File]::WriteAllText(
      $temporary,
      ($result | ConvertTo-Json -Depth 100),
      [Text.UTF8Encoding]::new($false)
    )
    Move-Item -LiteralPath $temporary -Destination $resolvedOut
  } finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
  }
  Write-Output "PASS checker suite artifact path=$resolvedOut runId=$($result.execution.runId) head=$Head claims=34"
}

function Invoke-AllControls([string]$Head) {
  $validPath = Join-Path $testRoot "valid.json"
  $valid = New-Receipt @((New-Claim "valid-subset" "valid-subset-mutant")) $Head
  Write-Receipt $valid $validPath
  [void](Assert-Accepted $checker $validPath $Head "minimal valid nonempty subset")

  foreach ($case in @(
      [ordered]@{ name = "candidate-string"; arm = "candidate"; value = "True" },
      [ordered]@{ name = "candidate-integer"; arm = "candidate"; value = 1 },
      [ordered]@{ name = "mutant-string"; arm = "mutant"; value = "True" },
      [ordered]@{ name = "mutant-integer"; arm = "mutant"; value = 1 }
    )) {
    $wrongExecuted = Copy-Map $valid
    if ($case.arm -ceq "candidate") {
      $wrongExecuted.claims[0].candidate.executed = $case.value
    } else {
      $wrongExecuted.claims[0].bypassMutant.executed = $case.value
    }
    $wrongExecutedPath = Join-Path $testRoot ("executed-wrong-type-" + $case.name + ".json")
    Write-Receipt $wrongExecuted $wrongExecutedPath
    $wrongExecutedResult = Assert-Rejected $checker $wrongExecutedPath $Head "WRONG_TYPE"
    Assert-Test ($wrongExecutedResult.output -notmatch "(?:CANDIDATE|MUTANT)_NOT_EXECUTED") `
      "$($case.name) did not use the wrong-type taxonomy"
  }
  Write-Output "PASS executed wrong-type controls string=True integer=1 arms=candidate/mutant"

  $numericObject = New-Receipt @(
    (New-Claim "numeric-object-member" "numeric-object-member-mutant" "/guards/2026/enabled")
  ) $Head
  $numericObjectPath = Join-Path $testRoot "numeric-object-member.json"
  Write-Receipt $numericObject $numericObjectPath
  [void](Assert-Accepted $checker $numericObjectPath $Head "numeric RFC 6901 object member")

  $arrayTraversal = Copy-Map $numericObject
  $arrayTraversal.claims[0].governingVariable.pointer = "/guards/0/enabled"
  $arrayTraversal.claims[0].preservedVariables.guards = @([ordered]@{ baseline = "preserved" })
  $arrayTraversal.claims[0].candidate.inputs = Copy-Map $arrayTraversal.claims[0].preservedVariables
  $arrayTraversal.claims[0].candidate.inputs.guards[0].enabled = $true
  $arrayTraversal.claims[0].bypassMutant.inputs = Copy-Map $arrayTraversal.claims[0].preservedVariables
  $arrayTraversal.claims[0].bypassMutant.inputs.guards[0].enabled = $false
  $arrayTraversalPath = Join-Path $testRoot "array-traversal.json"
  Write-Receipt $arrayTraversal $arrayTraversalPath
  $arrayResult = Assert-Rejected $checker $arrayTraversalPath $Head "PRESERVED_VARIABLES_CHANGED"
  Assert-Test ($arrayResult.output -notmatch "GOVERNING_POINTER_INVALID") `
    "array traversal was rejected from numeric token spelling instead of container shape"

  $collision = Copy-Map $numericObject
  $collision.claims[0].preservedVariables.guards = [ordered]@{
    "2026" = [ordered]@{ enabled = "preserved" }
  }
  $collision.claims[0].candidate.inputs = Copy-Map $collision.claims[0].preservedVariables
  $collision.claims[0].candidate.inputs.guards["2026"].enabled = $true
  $collision.claims[0].bypassMutant.inputs = Copy-Map $collision.claims[0].preservedVariables
  $collision.claims[0].bypassMutant.inputs.guards["2026"].enabled = $false
  $collisionPath = Join-Path $testRoot "pointer-collision.json"
  Write-Receipt $collision $collisionPath
  $collisionResult = Assert-Rejected $checker $collisionPath $Head "PRESERVED_VARIABLES_CHANGED"
  Assert-Test ($collisionResult.output -notmatch "GOVERNING_POINTER_INVALID") `
    "object-member collision was rejected as invalid pointer syntax"

  foreach ($invalidPointer in @(
      [ordered]@{ name = "root"; value = "/" },
      [ordered]@{ name = "empty-segment"; value = "/guards//enabled" },
      [ordered]@{ name = "array-append"; value = "/guards/-/enabled" },
      [ordered]@{ name = "malformed-escape"; value = "/guards/~2/enabled" },
      [ordered]@{ name = "over-bound"; value = "/" + ("x" * 510) + "/y" }
    )) {
    $invalid = Copy-Map $numericObject
    $invalid.claims[0].governingVariable.pointer = $invalidPointer.value
    $invalidPath = Join-Path $testRoot ("pointer-" + $invalidPointer.name + ".json")
    Write-Receipt $invalid $invalidPath
    [void](Assert-Rejected $checker $invalidPath $Head "GOVERNING_POINTER_INVALID")
  }

  $maxPointer = "/" + ("x" * 509) + "/y"
  Assert-Test ($maxPointer.Length -eq 512) "max pointer fixture is not 512 characters"
  $maxBound = New-Receipt @(
    (New-Claim "max-pointer-bound" "max-pointer-bound-mutant" $maxPointer)
  ) $Head
  $maxBoundPath = Join-Path $testRoot "pointer-max-bound.json"
  Write-Receipt $maxBound $maxBoundPath
  [void](Assert-Accepted $checker $maxBoundPath $Head "512-character pointer bound")
  Write-Output "PASS pointer controls numeric-object=array-safe collision-safe root/empty/dash/escape/bounds"

  $ordered = Copy-Map $valid
  $ordered.claims[0].candidate.result = [ordered]@{
    failureSignature = $null
    observation = "PASS"
    testOutcome = "pass"
  }
  $orderedPath = Join-Path $testRoot "object-order.json"
  Write-Receipt $ordered $orderedPath
  [void](Assert-Accepted $checker $orderedPath $Head "object-member order canonical equality")

  $casePath = Join-Path $testRoot "case-sensitive.json"
  $case = Copy-Map $valid
  $case.claims[0].candidate.result.observation = "pass"
  Write-Receipt $case $casePath
  [void](Assert-Rejected $checker $casePath $Head "CANDIDATE_EXPECTATION_RESULT_MISMATCH")

  $unicodePath = Join-Path $testRoot "unicode.json"
  $unicode = Copy-Map $valid
  $unicode.claims[0].candidate.expectation.observation = [string][char]0x00e9
  $unicode.claims[0].candidate.result.observation = "e$([char]0x0301)"
  Write-Receipt $unicode $unicodePath
  [void](Assert-Rejected $checker $unicodePath $Head "CANDIDATE_EXPECTATION_RESULT_MISMATCH")

  $sameValuePath = Join-Path $testRoot "N24.json"
  $same = Copy-Map $valid
  $same.claims[0].governingVariable.bypassValue = $true
  $same.claims[0].bypassMutant.inputs = Copy-Map $same.claims[0].candidate.inputs
  Write-Receipt $same $sameValuePath
  [void](Assert-Rejected $checker $sameValuePath $Head "GOVERNING_VARIABLE_NOT_ISOLATED")
  Write-Output "NEGATIVE N24-SAME-GOVERNING-VALUES rejected uncounted"

  $sameResultPath = Join-Path $testRoot "N33.json"
  $sameResult = Copy-Map $valid
  $sameResult.claims[0].bypassMutant.expectation = Copy-Map $sameResult.claims[0].candidate.expectation
  $sameResult.claims[0].bypassMutant.result = Copy-Map $sameResult.claims[0].candidate.result
  Write-Receipt $sameResult $sameResultPath
  [void](Assert-Rejected $checker $sameResultPath $Head "SAME_RESULT_EVIDENCE")
  Write-Output "NEGATIVE N33-SAME-RESULT-EVIDENCE rejected uncounted"

  foreach ($position in @("root", "subject", "claim", "governing", "candidate", "mutant", "expectation", "result")) {
    $authority = Copy-Map $valid
    switch ($position) {
      "root" { $authority.complete = $true }
      "subject" { $authority.subject.expectedGuardCount = 1 }
      "claim" { $authority.claims[0].requiredGuardIds = @("valid-subset") }
      "governing" { $authority.claims[0].governingVariable.complete = $true }
      "candidate" { $authority.claims[0].candidate.expectedGuardCount = 1 }
      "mutant" { $authority.claims[0].bypassMutant.requiredGuardIds = @("valid-subset") }
      "expectation" { $authority.claims[0].candidate.expectation.complete = $true }
      "result" { $authority.claims[0].bypassMutant.result.expectedGuardCount = 1 }
    }
    $path = Join-Path $testRoot ("N37-" + $position + ".json")
    Write-Receipt $authority $path
    [void](Assert-Rejected $checker $path $Head "UNKNOWN_PROPERTY")
  }

  $inert = Copy-Map $valid
  $inert.claims[0].preservedVariables.complete = $true
  $inert.claims[0].preservedVariables.expectedGuardCount = 999
  $inert.claims[0].preservedVariables.requiredGuardIds = @("not-authority")
  $inert.claims[0].candidate.inputs = Insert-TestPointer $inert.claims[0].preservedVariables `
    $inert.claims[0].governingVariable.pointer $true
  $inert.claims[0].bypassMutant.inputs = Insert-TestPointer $inert.claims[0].preservedVariables `
    $inert.claims[0].governingVariable.pointer $false
  $inertPath = Join-Path $testRoot "N37-data-map-inert.json"
  Write-Receipt $inert $inertPath
  [void](Assert-Accepted $checker $inertPath $Head "authority-like data-map names")
  Write-Output "NEGATIVE N37-COMPLETENESS-SELF-DECLARATION rejected structural/inert data-map/subset accepted uncounted"

  $schemaText = Get-Content -LiteralPath (Join-Path $PSScriptRoot "fail-closed-guard-evidence.schema.json") -Raw
  Assert-Test ($schemaText -notmatch '"complete"\s*:|"expectedGuardCount"\s*:|"requiredGuardIds"\s*:') `
    "schema has completeness authority"
  Write-Output "PASS schema has no completeness authority"
  Write-Output "PASS token/case/order/Unicode/bounds/closure and N24/N33/N37 controls"
}

try {
  Assert-Test ((Test-Path -LiteralPath $checker -PathType Leaf)) "checker is missing"
  $liveHead = Get-LiveHead
  if (-not $ExpectedControllerHead) { $ExpectedControllerHead = $liveHead }
  Assert-Test ($ExpectedControllerHead -ceq $liveHead) `
    "expected controller head $ExpectedControllerHead does not equal live HEAD $liveHead"
  Assert-Test ($manifest.Count -eq 34) "checker manifest count is not 34"

  switch ($Scenario) {
    "All" {
      Invoke-AllControls $ExpectedControllerHead
      Write-Output "PASS fail-closed checker All"
    }
    "BypassMutants" {
      $summary = Invoke-ManifestSuite $ExpectedControllerHead
      Assert-Test ($summary.applied -eq 34 -and $summary.killed -eq 34 -and
        $summary.survivors -eq 0 -and $summary.notApplied -eq 0) "mutation summary is not 34/34"
      Write-Output "PASS checker mutation summary applied=34 killed=34 survivors=0 not-applied=0"
      if ($SuiteResultOut) { Write-SuiteResult $ExpectedControllerHead $SuiteResultOut $summary }
    }
    "ManifestSatisfiability" {
      $summary = Invoke-ManifestSuite $ExpectedControllerHead
      Assert-Test ($summary.advertised -eq 34 -and $summary.witnessed -eq 34 -and
        $summary.unwitnessed -eq 0) "manifest satisfiability is not 34/34"
      Write-Output "PASS checker satisfiability advertised=34 witnessed=34 unwitnessed=0"
    }
    "ReceiptClaims" {
      Write-SuiteResult $ExpectedControllerHead $SuiteResultOut
    }
  }
} finally {
  if (Test-Path -LiteralPath $testRoot) {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd("\", "/")
    if ((Split-Path -Parent $resolved).TrimEnd("\", "/") -ne $temp -or
        (Split-Path -Leaf $resolved) -notlike "fail-closed-guard-evidence-test-*") {
      throw "refusing unsafe checker-test cleanup target: $resolved"
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
  }
}
