[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string]$CheckerResultPath,

  [Parameter(Mandatory)]
  [string]$ProductionResultPath,

  [Parameter(Mandatory)]
  [string]$BatteryResultPath,

  [Parameter(Mandatory)]
  [string]$ExpectedControllerHead,

  [Parameter(Mandatory)]
  [string]$ReceiptOut
)

$ErrorActionPreference = "Stop"
$controllerRoot = Split-Path -Parent $PSScriptRoot
$checker = Join-Path $PSScriptRoot "fail-closed-guard-evidence.ps1"
$partitions = [ordered]@{
  "checker" = @(
    "C01-RECEIPT-MISSING", "C02-RECEIPT-UNREADABLE", "C03-RECEIPT-EMPTY",
    "C04-UTF8-INVALID", "C05-JSON-MALFORMED", "C06-JSON-DUPLICATE-MEMBER",
    "C07-SCHEMA-VERSION", "C08-UNKNOWN-ROOT", "C09-UNKNOWN-NESTED",
    "C10-WRONG-TYPE", "C11-FILE-SIZE-BOUND", "C12-DEPTH-BOUND",
    "C13-CLAIM-COUNT-BOUND", "C14-OBJECT-MEMBER-BOUND",
    "C15-SHORT-STRING-BOUND", "C16-OBSERVATION-BOUND",
    "C17-NUMBER-CANONICAL", "C18-CLAIMS-NONEMPTY",
    "C19-GUARD-ID-REQUIRED", "C20-GUARD-ID-UNIQUE",
    "C21-MUTANT-ID-REQUIRED", "C22-MUTANT-ID-UNIQUE",
    "C23-GOVERNING-POINTER", "C25-ONE-LEAF-DIFF",
    "C26-PRESERVED-PROJECTION", "C27-CANDIDATE-EXECUTED",
    "C28-MUTANT-EXECUTED", "C29-CANDIDATE-EXPECTATION-RESULT",
    "C30-MUTANT-EXPECTATION-RESULT", "C31-CANDIDATE-GREEN",
    "C32-MUTANT-RED", "C34-SIGNATURE-REQUIRED",
    "C35-SIGNATURE-MATCH", "C36-ENUM-CLOSED"
  )
  "issue-6254-production" = @(
    "LP-B1-B2-EVENT-ORDER", "LP-B3-EXACT-HEAD", "LP-B3-CLEAR-ANY-OPEN",
    "LP-D2-RUN-IDENTITY", "LP-D3-COMMIT-BOUND", "LP-D4-WORKFLOW-IDENTITY",
    "LP-D5-OWNING-JOB", "LP-D6-JOB-CONCLUSION", "LP-D7-JOB-TAXONOMY",
    "LP-D8-RESOLVER-ONLY", "LP-D10-REPORT-ONLY", "LP-D15-RUN-LIST-EXIT",
    "LP-F1-EXECUTED-UNRECOGNIZED", "LP-ZERO-STEPS", "LP-EXECUTED-RED-DEMOTED",
    "LP-BREAKER-REPAIR-FRONTIER-DEFAULT-REFUSE"
  )
  "release-battery" = @(
    "BATTERY-CHECKER-REQUIRED",
    "BATTERY-6254-DISCRIMINATOR-REQUIRED"
  )
}

$expectedCounts = [ordered]@{
  "checker" = 34
  "issue-6254-production" = 16
  "release-battery" = 2
}

function Stop-Aggregate([string]$Code) {
  throw "FAIL fail-closed-guard-evidence-aggregate: $Code"
}

function Resolve-InputPath([string]$Path) {
  if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
  return [IO.Path]::GetFullPath((Join-Path $controllerRoot $Path))
}

function Assert-ExactKeys($Map, [string[]]$Keys, [string]$SuiteId) {
  if ($Map -isnot [Collections.IDictionary]) {
    Stop-Aggregate "AGGREGATE_SUITE_INCONSISTENT:$SuiteId"
  }
  $expected = [Collections.Generic.HashSet[string]]::new($Keys, [StringComparer]::Ordinal)
  if ($Map.Count -ne $Keys.Count) {
    Stop-Aggregate "AGGREGATE_SUITE_INCONSISTENT:$SuiteId"
  }
  foreach ($key in $Map.Keys) {
    if ($key -isnot [string] -or -not $expected.Contains([string]$key)) {
      Stop-Aggregate "AGGREGATE_SUITE_INCONSISTENT:$SuiteId"
    }
  }
}

function Assert-TokenClosure(
  [System.Text.Json.JsonElement]$Element,
  [int]$Depth,
  [string]$SuiteId
) {
  if ($Depth -gt 32) { Stop-Aggregate "AGGREGATE_SUITE_INCONSISTENT:$SuiteId" }
  switch ($Element.ValueKind) {
    ([System.Text.Json.JsonValueKind]::Object) {
      $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
      $count = 0
      foreach ($property in $Element.EnumerateObject()) {
        $count += 1
        if (-not $names.Add($property.Name) -or $count -gt 256) {
          Stop-Aggregate "AGGREGATE_SUITE_INCONSISTENT:$SuiteId"
        }
        Assert-TokenClosure $property.Value ($Depth + 1) $SuiteId
      }
    }
    ([System.Text.Json.JsonValueKind]::Array) {
      foreach ($item in $Element.EnumerateArray()) {
        Assert-TokenClosure $item ($Depth + 1) $SuiteId
      }
    }
    ([System.Text.Json.JsonValueKind]::String) {
      if ($Element.GetString().Length -gt 4096) {
        Stop-Aggregate "AGGREGATE_SUITE_INCONSISTENT:$SuiteId"
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
        Stop-Aggregate "AGGREGATE_SUITE_INCONSISTENT:$SuiteId"
      }
    }
  }
}

function Read-Suite([string]$Path, [string]$ExpectedSuiteId) {
  $resolved = Resolve-InputPath $Path
  if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
    Stop-Aggregate "AGGREGATE_SUITE_MISSING:$ExpectedSuiteId"
  }
  try {
    $bytes = [IO.File]::ReadAllBytes($resolved)
    if ($bytes.Length -lt 1 -or $bytes.Length -gt 1MB) {
      Stop-Aggregate "AGGREGATE_SUITE_INCONSISTENT:$ExpectedSuiteId"
    }
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    $options = [System.Text.Json.JsonDocumentOptions]::new()
    $options.MaxDepth = 2048
    $document = [System.Text.Json.JsonDocument]::Parse($text, $options)
    try {
      Assert-TokenClosure $document.RootElement 1 $ExpectedSuiteId
    } finally {
      $document.Dispose()
    }
    $suite = $text | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
  } catch {
    if ($_.Exception.Message -match "^FAIL fail-closed-guard-evidence-aggregate:") { throw }
    Stop-Aggregate "AGGREGATE_SUITE_INCONSISTENT:$ExpectedSuiteId"
  }

  Assert-ExactKeys $suite @("schemaVersion", "subject", "suite", "execution", "claims") $ExpectedSuiteId
  Assert-ExactKeys $suite.subject @("controllerHead") $ExpectedSuiteId
  Assert-ExactKeys $suite.suite @("id", "expectedClaimCount") $ExpectedSuiteId
  Assert-ExactKeys $suite.execution @("runId", "executed", "outcome") $ExpectedSuiteId
  if ([string]$suite.schemaVersion -cne "fail-closed-guard-suite-result/v1" -or
      [string]$suite.suite.id -cne $ExpectedSuiteId -or
      $suite.suite.expectedClaimCount -isnot [long] -or
      [long]$suite.suite.expectedClaimCount -ne [long]$expectedCounts[$ExpectedSuiteId] -or
      $suite.execution.executed -isnot [bool] -or
      $suite.execution.executed -cne $true -or
      [string]$suite.execution.outcome -cne "pass" -or
      [string]::IsNullOrWhiteSpace([string]$suite.execution.runId) -or
      ([string]$suite.execution.runId).Length -gt 512 -or
      $suite.claims -isnot [Array] -or
      @($suite.claims).Count -ne [int]$expectedCounts[$ExpectedSuiteId]) {
    Stop-Aggregate "AGGREGATE_SUITE_INCONSISTENT:$ExpectedSuiteId"
  }
  if ([string]$suite.subject.controllerHead -cne $ExpectedControllerHead) {
    Stop-Aggregate "AGGREGATE_HEAD_MISMATCH:$ExpectedSuiteId"
  }
  return $suite
}

function Assert-Partition($Suite, [string]$SuiteId) {
  $actual = [string[]]@($Suite.claims | ForEach-Object { [string]$_.guardId })
  $expected = [string[]]@($partitions[$SuiteId])
  [Array]::Sort($actual, [StringComparer]::Ordinal)
  [Array]::Sort($expected, [StringComparer]::Ordinal)
  if ($actual.Count -ne $expected.Count) {
    Stop-Aggregate "AGGREGATE_SUITE_INCONSISTENT:$SuiteId"
  }
  for ($index = 0; $index -lt $expected.Count; $index++) {
    if ($actual[$index] -cne $expected[$index]) {
      Stop-Aggregate "AGGREGATE_SUITE_INCONSISTENT:$SuiteId"
    }
  }
}

function Assert-SuiteClaims($Suite, [string]$SuiteId) {
  $temporary = Join-Path ([IO.Path]::GetTempPath()) (
    "fail-closed-suite-validation-" + [guid]::NewGuid().ToString("N") + ".json"
  )
  try {
    $receipt = [ordered]@{
      schemaVersion = "fail-closed-guard-evidence/v1"
      subject = [ordered]@{
        controllerHead = $ExpectedControllerHead
        batteryId = "suite-validation:$SuiteId"
      }
      claims = @($Suite.claims)
    }
    [IO.File]::WriteAllText(
      $temporary,
      ($receipt | ConvertTo-Json -Depth 100),
      [Text.UTF8Encoding]::new($false)
    )
    try {
      $output = & $checker -ReceiptPath $temporary -ExpectedControllerHead $ExpectedControllerHead 2>&1 |
        Out-String
      if ($output -notmatch "^PASS fail-closed-guard-evidence") {
        Stop-Aggregate "AGGREGATE_SUITE_INCONSISTENT:$SuiteId"
      }
    } catch {
      Stop-Aggregate "AGGREGATE_SUITE_INCONSISTENT:$SuiteId"
    }
  } finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
  }
}

if ($ExpectedControllerHead -cnotmatch "^[a-f0-9]{40}$") {
  Stop-Aggregate "AGGREGATE_LIVE_HEAD_MOVED"
}
$liveHead = (& git -C $controllerRoot rev-parse HEAD 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $liveHead -cne $ExpectedControllerHead) {
  Stop-Aggregate "AGGREGATE_LIVE_HEAD_MOVED"
}
if (-not (Test-Path -LiteralPath $checker -PathType Leaf)) {
  Stop-Aggregate "AGGREGATE_SUITE_INCONSISTENT:checker"
}

$inputs = [ordered]@{
  "checker" = Resolve-InputPath $CheckerResultPath
  "issue-6254-production" = Resolve-InputPath $ProductionResultPath
  "release-battery" = Resolve-InputPath $BatteryResultPath
}
$present = @($inputs.Values | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }).Count
if ($present -eq 0) { Stop-Aggregate "AGGREGATE_SUITES_NOT_EXECUTED" }

$suites = [ordered]@{}
foreach ($suiteId in $inputs.Keys) {
  $suites[$suiteId] = Read-Suite $inputs[$suiteId] $suiteId
  Assert-SuiteClaims $suites[$suiteId] $suiteId
}

$runIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($suiteId in $suites.Keys) {
  if (-not $runIds.Add([string]$suites[$suiteId].execution.runId)) {
    Stop-Aggregate "AGGREGATE_SUITE_INCONSISTENT:$suiteId"
  }
}

$guardIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$mutantIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($suiteId in $suites.Keys) {
  foreach ($claim in @($suites[$suiteId].claims)) {
    $guardId = [string]$claim.guardId
    if ([string]::IsNullOrWhiteSpace($guardId) -or -not $guardIds.Add($guardId)) {
      Stop-Aggregate "AGGREGATE_CLAIM_DUPLICATE:$guardId"
    }
    $mutantId = [string]$claim.bypassMutant.id
    if ([string]::IsNullOrWhiteSpace($mutantId) -or -not $mutantIds.Add($mutantId)) {
      Stop-Aggregate "AGGREGATE_SUITE_INCONSISTENT:$suiteId"
    }
  }
}

foreach ($suiteId in $suites.Keys) {
  Assert-Partition $suites[$suiteId] $suiteId
}

$receipt = [ordered]@{
  schemaVersion = "fail-closed-guard-evidence/v1"
  subject = [ordered]@{
    controllerHead = $ExpectedControllerHead
    batteryId = "issue-6254-fail-closed-guard-evidence/$([long]$expectedCounts['checker'] + [long]$expectedCounts['issue-6254-production'] + [long]$expectedCounts['release-battery'])"
  }
  claims = @(
    $suites["checker"].claims
    $suites["issue-6254-production"].claims
    $suites["release-battery"].claims
  )
}

$resolvedOut = if ([IO.Path]::IsPathRooted($ReceiptOut)) {
  [IO.Path]::GetFullPath($ReceiptOut)
} else {
  [IO.Path]::GetFullPath((Join-Path $controllerRoot $ReceiptOut))
}
$outDirectory = Split-Path -Parent $resolvedOut
$artifactRoot = [IO.Path]::GetFullPath((Join-Path $controllerRoot ".orchestrator/artifacts"))
if ($outDirectory.TrimEnd("\", "/") -cne $artifactRoot.TrimEnd("\", "/")) {
  Stop-Aggregate "AGGREGATE_RECEIPT_PATH_INVALID"
}
New-Item -ItemType Directory -Path $outDirectory -Force | Out-Null
$temporary = Join-Path $outDirectory (".aggregate-" + [guid]::NewGuid().ToString("N") + ".tmp")
try {
  [IO.File]::WriteAllText(
    $temporary,
    ($receipt | ConvertTo-Json -Compress -Depth 100),
    [Text.UTF8Encoding]::new($false)
  )
  $checkerOutput = & $checker -ReceiptPath $temporary -ExpectedControllerHead $ExpectedControllerHead 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0 -or $checkerOutput -notmatch "^PASS fail-closed-guard-evidence") {
    Stop-Aggregate "AGGREGATE_SUITE_INCONSISTENT:checker"
  }
  [IO.File]::Move($temporary, $resolvedOut, $true)
} finally {
  if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
}

$aggregateCount = [long]$expectedCounts['checker'] + [long]$expectedCounts['issue-6254-production'] + [long]$expectedCounts['release-battery']
Write-Output "PASS fail-closed aggregate path=$resolvedOut head=$ExpectedControllerHead claims=$aggregateCount checker=$($expectedCounts['checker']) production=$($expectedCounts['issue-6254-production']) battery=$($expectedCounts['release-battery'])"
