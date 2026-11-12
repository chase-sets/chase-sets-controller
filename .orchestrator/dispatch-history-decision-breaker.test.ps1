[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$checks = 0
$nativeCalls = 0
$root = Join-Path ([IO.Path]::GetTempPath()) ('decision-breaker-history-' + [guid]::NewGuid().ToString('N'))
$utf8 = [Text.UTF8Encoding]::new($false, $true)
function Assert-DecisionHistory([bool]$Value, [string]$Message) {
  $script:checks++
  if (-not $Value) { throw "ASSERT: $Message" }
}
function Get-DecisionHistoryIdentity([string]$Path) {
  $file = Get-Item -LiteralPath $Path
  [ordered]@{ path = $file.FullName; bytes = $file.Length; mtimeUtcTicks = $file.LastWriteTimeUtc.Ticks
    sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
}
function Get-DecisionHistoryInputs {
  @($sourcePaths + @(Get-ChildItem -LiteralPath $root -File | Select-Object -ExpandProperty FullName) |
    ForEach-Object { Get-DecisionHistoryIdentity $_ }) | ConvertTo-Json -Depth 10 -Compress
}
function Invoke-DecisionHistoryNative([string]$Name, [string]$History, [string]$Observed = '', [string]$Mode = 'authority') {
  $job = [ordered]@{ sourceRoot = $PSScriptRoot; history = $History; observed = $Observed; mode = $Mode
    provider = (Join-Path $root 'nonexistent-provider-must-not-run.exe') }
  $jobPath = Join-Path $root 'job.json'
  [IO.File]::WriteAllText($jobPath, ($job | ConvertTo-Json -Compress), $utf8)
  $before = Get-DecisionHistoryInputs
  $info = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })))
  $info.UseShellExecute = $false
  $info.CreateNoWindow = $true
  $info.RedirectStandardOutput = $true
  $info.RedirectStandardError = $true
  foreach ($arg in @('-NoProfile', '-NonInteractive', '-File', $childPath, '-InputPath', $jobPath)) { [void]$info.ArgumentList.Add($arg) }
  $watch = [Diagnostics.Stopwatch]::StartNew()
  $process = [Diagnostics.Process]::Start($info)
  $stdout = $process.StandardOutput.ReadToEndAsync()
  $stderr = $process.StandardError.ReadToEndAsync()
  $process.WaitForExit()
  $watch.Stop()
  $out = $stdout.GetAwaiter().GetResult()
  $err = $stderr.GetAwaiter().GetResult()
  $exitCode = $process.ExitCode
  $process.Dispose()
  $after = Get-DecisionHistoryInputs
  $script:nativeCalls++
  # Full streams and complete input identities survive even when a child fails.
  [ordered]@{ name = $Name; exitCode = $exitCode; elapsedMs = $watch.Elapsed.TotalMilliseconds
    arguments = @($info.ArgumentList); inputsBefore = $before; inputsAfter = $after
    stdout = $out; stderr = $err } | ConvertTo-Json -Compress -Depth 15 | Write-Output | Out-Host
  Assert-DecisionHistory ($before -ceq $after) "$Name changed a source, argument, or private fixture identity"
  Assert-DecisionHistory ($exitCode -eq 0 -and $err -ceq '') "$Name native child failed: exit=$exitCode stderr=$err"
  $payload = $out | ConvertFrom-Json -Depth 100 -DateKind String
  Assert-DecisionHistory ($payload.observedBefore -ceq $payload.observedAfter) "$Name mutated the supplied complete observed argument"
  Assert-DecisionHistory ($payload.historyBefore -ceq $payload.historyAfter) "$Name changed history bytes/length/mtime"
  $payload
}
function Assert-DecisionHistoryWhole($Actual, $Expected, [string]$Message) {
  Assert-DecisionHistory ($Actual.resultJson -ceq $Expected.resultJson) "$Message entire return differs: actual=$($Actual.resultJson) expected=$($Expected.resultJson)"
}

try {
  [void][IO.Directory]::CreateDirectory($root)
  $sourcePaths = @('landing-preflight.ps1', 'review-head-contract.psm1', 'dispatch-ledger-reader.psm1',
    'dispatch-history-decision-breaker.test.ps1') | ForEach-Object { Join-Path $PSScriptRoot $_ }
  $sourceBefore = @($sourcePaths | ForEach-Object { Get-DecisionHistoryIdentity $_ }) | ConvertTo-Json -Depth 10 -Compress
  $childPath = Join-Path $root 'native-caller.ps1'
  # Same exact-source prefix seam as landing-preflight.test.ps1. Only the source
  # root is bound; no function, constant, dependency, or history limit is replaced.
  $child = @'
param([Parameter(Mandatory)][string]$InputPath)
$ErrorActionPreference = 'Stop'
$job = [IO.File]::ReadAllText($InputPath) | ConvertFrom-Json -DateKind String
$sourcePath = Join-Path $job.sourceRoot 'landing-preflight.ps1'
$source = [IO.File]::ReadAllText($sourcePath)
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'production source does not parse' }
$functionAst = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Get-Decision7643BreakerAuthority'}, $true)
if (-not $functionAst) { throw 'literal function missing' }
$calls = @($functionAst.Body.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Read-ExactHeadReviewHistory'}, $true))
if ($calls.Count -ne 1 -or $calls[0].Extent.Text -cne 'Read-ExactHeadReviewHistory -Path $HistoryPath -MaxRows $MaxHistoryRows -MaxBytes $MaxHistoryBytes') { throw 'literal caller identity changed' }
$marker = '$script:currentAdmission = $null'
$index = $source.IndexOf($marker, [StringComparison]::Ordinal)
if ($index -le $functionAst.Extent.EndOffset) { throw 'production prefix boundary missing' }
$prefix = $source.Substring(0, $index)
$prefix = $prefix.Replace('$PSScriptRoot', ("'" + $job.sourceRoot.Replace("'", "''") + "'"))
$expectedBody = $functionAst.Body.Extent.Text.Substring(1, $functionAst.Body.Extent.Text.Length - 2)
$expectedFunction = $functionAst.Extent.Text
$control = __CONTROL_OPEN__
if ($PSBoundParameters.ContainsKey('MaxHistoryRows') -or $PSBoundParameters.ContainsKey('MaxHistoryBytes') -or
    $MaxHistoryRows -ne [int]::MaxValue -or $MaxHistoryBytes -ne [long]::MaxValue) { throw 'history defaults not preserved' }
if ($decision7643BreakerLine -ne 14530) { throw 'physical decision anchor changed' }
if (Test-Path -LiteralPath $GhCommand) { throw 'private nonexistent provider sentinel exists' }
if ((Get-Command Get-Decision7643BreakerAuthority).ScriptBlock.Ast.Extent.Text -cne $expectedFunction) { throw 'loaded function signature/body is not exact source' }
function LocalIdentity([string]$Path) {
  $f = Get-Item -LiteralPath $Path
  [ordered]@{ path = $f.FullName; bytes = $f.Length; mtimeUtcTicks = $f.LastWriteTimeUtc.Ticks
    sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() } | ConvertTo-Json -Compress
}
$historyBefore = LocalIdentity $HistoryPath
$observed = if ($job.observed) { [IO.File]::ReadAllText($job.observed) | ConvertFrom-Json -DateKind String } else { $null }
$observedBefore = ConvertTo-Json -InputObject $observed -Compress -Depth 100
$history = $null
if ($job.mode -ceq 'observe') {
  $history = Read-ExactHeadReviewHistory -Path $HistoryPath
  if (-not $history.complete) { throw 'whole oracle history incomplete' }
  $result = Get-PipelineBreakerObservation $history
} else {
  $result = Get-Decision7643BreakerAuthority $observed
}
[ordered]@{
  result = $result
  resultJson = (ConvertTo-Json -InputObject $result -Depth 100 -Compress)
  observedBefore = $observedBefore
  observedAfter = (ConvertTo-Json -InputObject $observed -Depth 100 -Compress)
  historyBefore = $historyBefore
  historyAfter = (LocalIdentity $HistoryPath)
  history = $history
  bodySha256 = (Get-Sha256 ([Text.Encoding]::UTF8.GetBytes($expectedBody)))
  callSha256 = (Get-Sha256 ([Text.Encoding]::UTF8.GetBytes($calls[0].Extent.Text)))
  maxHistoryRows = $MaxHistoryRows
  maxHistoryBytes = $MaxHistoryBytes
  boundParameters = @($PSBoundParameters.Keys)
} | ConvertTo-Json -Depth 100 -Compress
__CONTROL_CLOSE__
& ([scriptblock]::Create($prefix + $control)) -Pr 7641 -HistoryPath $job.history -GhCommand $job.provider
'@
  # The child contains its own literal here-string, so assemble its delimiters
  # without changing any extracted production text.
  $child = $child.Replace('__CONTROL_OPEN__', "@'").Replace('__CONTROL_CLOSE__', "'@")
  [IO.File]::WriteAllText($childPath, $child, $utf8)

  $open = '{"ts":"2026-09-03T21:47:13.444Z","kind":"breaker-open","issue":7558,"pr":7631,"outcome":"HOSTED_E2E_REQUIRED_FAILURE","breakerScope":"pipeline"}'
  $clear = '{"ts":"2026-09-04T00:00:00.000Z","kind":"breaker-clear","issue":7558,"pr":7631,"outcome":"SYNTHETIC_CLEAR","breakerScope":"pipeline"}'
  $later = '{"ts":"2026-09-05T00:00:00.000Z","kind":"breaker-clear","issue":900001,"pr":900002,"outcome":"SYNTHETIC_DISTINCT_CLEAR","breakerScope":"pipeline"}'
  $smallText = ("`n" * 14529) + $open + "`n" + $clear + "`n"
  $small = Join-Path $root 'small-whole.jsonl'
  $full = Join-Path $root 'private-full.jsonl'
  [IO.File]::WriteAllText($small, $smallText, $utf8)
  $writer = [IO.StreamWriter]::new($full, $false, $utf8, 65536)
  $writer.NewLine = "`n"
  try {
    $writer.Write("`n" * 14529)
    $writer.WriteLine($open)
    $padding = ' ' * 760
    for ($line = 14531; $line -le 60000; $line++) { $writer.WriteLine($padding) }
    $writer.WriteLine($clear)
  } finally { $writer.Dispose() }
  $originalBytes = [IO.File]::ReadAllBytes($full)
  $originalIdentity = Get-DecisionHistoryIdentity $full
  $text = $utf8.GetString($originalBytes)
  $lf = [regex]::Matches($text, "`n")
  Assert-DecisionHistory ($lf.Count -eq 60001 -and $originalBytes.Length -gt 33554432) 'full history exceeds both former cliffs'
  Assert-DecisionHistory ($lf[14528].Index + 1 -eq 14529 -and $text.Substring(14529, $open.Length) -ceq $open) 'genuine original physical anchor is 14530'
  Assert-DecisionHistory ((Get-Item $small).Length -lt 33554432 -and ([regex]::Matches($smallText, "`n")).Count -lt 50000) 'whole oracle below both former cliffs'
  $geometry = [ordered]@{ lfLines = $lf.Count; fullBytes = $originalBytes.Length; anchor = 14530
    clearLine = 60001; clearOffset = $lf[59999].Index + 1 }
  Assert-DecisionHistory ($geometry.clearOffset -gt 33554432) 'late clear is beyond both old cliffs'
  $geometry | ConvertTo-Json -Compress | Out-Host
  $observedPath = Join-Path $root 'observed-healthy.json'
  $observation = Invoke-DecisionHistoryNative 'small-complete-reducer' $small '' 'observe'
  Assert-DecisionHistory ($observation.result.complete -and $observation.result.healthy -and $observation.result.unpairedClears -eq 0) 'actual small reducer supplies complete healthy argument'
  [IO.File]::WriteAllText($observedPath, $observation.resultJson, $utf8)
  $oracle = Invoke-DecisionHistoryNative 'small-whole-authority' $small $observedPath
  $whole = Invoke-DecisionHistoryNative 'full-whole-authority' $full $observedPath
  Assert-DecisionHistoryWhole $whole $oracle 'full versus small exact oracle'
  Assert-DecisionHistory ($whole.result.complete -and $whole.result.reason -ceq 'DECISION_7643_BREAKER_OBSERVED') 'complete function qualification only'
  $row = [ordered]@{ line = 14530; rowSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($utf8.GetBytes($open))).ToLowerInvariant()
    byteLength = $utf8.GetByteCount($open); kind = 'breaker-open'; ts = '2026-09-03T21:47:13.444Z'
    issue = 7558; pr = 7631; outcome = 'HOSTED_E2E_REQUIRED_FAILURE'; breakerScope = 'pipeline' }
  Assert-DecisionHistory (($whole.result.row | ConvertTo-Json -Compress) -ceq ($row | ConvertTo-Json -Compress)) 'all retained row leaves match original raw source identity'

  $suffixStart = $lf[$lf.Count - 50000 - 1].Index + 1
  $suffixBytes = $utf8.GetBytes($text.Substring($suffixStart))
  $prefixEnd = [Array]::LastIndexOf($originalBytes, [byte]10, 33554431) + 1
  $prefixBytes = [byte[]]::new($prefixEnd)
  [Array]::Copy($originalBytes, $prefixBytes, $prefixEnd)
  Assert-DecisionHistory (([regex]::Matches($utf8.GetString($suffixBytes), "`n")).Count -eq 50000 -and $suffixStart -eq $lf[10000].Index + 1) 'actual last 50000 LF physical lines'
  Assert-DecisionHistory ($prefixBytes.Length -le 33554432 -and $originalBytes[$prefixEnd..33554431] -notcontains [byte]10) 'actual maximal complete-line 32MiB prefix'
  $suffixOracle = Join-Path $root 'suffix-small-whole.jsonl'
  [IO.File]::WriteAllText($suffixOracle, ("`n" * 4528) + $open + "`n" + $clear + "`n", $utf8)
  $prefixOracle = Join-Path $root 'prefix-small-whole.jsonl'
  [IO.File]::WriteAllText($prefixOracle, ("`n" * 14529) + $open + "`n", $utf8)
  $suffixExpected = Invoke-DecisionHistoryNative 'suffix-whole-oracle' $suffixOracle $observedPath
  $prefixExpected = Invoke-DecisionHistoryNative 'prefix-whole-oracle' $prefixOracle $observedPath
  Assert-DecisionHistory (-not $suffixExpected.result.complete -and $suffixExpected.result.reason -ceq 'DECISION_7643_BREAKER_ROW_UNAVAILABLE' -and $null -eq $suffixExpected.result.row -and $suffixExpected.result.current.healthy) 'row absence alone refuses while current stays healthy'
  Assert-DecisionHistory (-not $prefixExpected.result.complete -and $prefixExpected.result.reason -ceq 'DECISION_7643_BREAKER_OBSERVED' -and -not $prefixExpected.result.current.healthy -and $prefixExpected.result.current.openRows[0].line -eq 14530) 'retained anchor plus different current refuses'
  foreach ($cut in @(@{ name = 'suffix'; bytes = $suffixBytes; expected = $suffixExpected }, @{ name = 'prefix'; bytes = $prefixBytes; expected = $prefixExpected })) {
    try {
      [IO.File]::WriteAllBytes($full, $cut.bytes)
      $actual = Invoke-DecisionHistoryNative ($cut.name + '-actual-cut') $full $observedPath
      Assert-DecisionHistoryWhole $actual $cut.expected ($cut.name + ' exact counterfactual')
      Assert-DecisionHistory ($actual.resultJson -cne $whole.resultJson) ($cut.name + ' is causal, not equivalent')
    } finally {
      [IO.File]::WriteAllBytes($full, $originalBytes)
      [IO.File]::SetLastWriteTimeUtc($full, [datetime]::new($originalIdentity.mtimeUtcTicks, [DateTimeKind]::Utc))
    }
    Assert-DecisionHistory ((Get-DecisionHistoryIdentity $full | ConvertTo-Json -Compress) -ceq ($originalIdentity | ConvertTo-Json -Compress)) ($cut.name + ' restored exact bytes/hash/length/mtime')
    $restored = Invoke-DecisionHistoryNative ($cut.name + '-restored-whole') $full $observedPath
    Assert-DecisionHistoryWhole $restored $whole ($cut.name + ' restored entire result')
  }
  $openObserved = Invoke-DecisionHistoryNative 'prefix-complete-reducer' $prefixOracle '' 'observe'
  $openObservedPath = Join-Path $root 'observed-open.json'
  [IO.File]::WriteAllText($openObservedPath, $openObserved.resultJson, $utf8)
  $matchedOpen = Invoke-DecisionHistoryNative 'prefix-current-match-control' $prefixOracle $openObservedPath
  Assert-DecisionHistory ($matchedOpen.result.complete -and $matchedOpen.result.reason -ceq 'DECISION_7643_BREAKER_OBSERVED') 'same open current succeeds with matching actual observed argument'
  Assert-DecisionHistory (($matchedOpen.result.current | ConvertTo-Json -Compress -Depth 100) -ceq ($prefixExpected.result.current | ConvertTo-Json -Compress -Depth 100) -and
    ($matchedOpen.result.row | ConvertTo-Json -Compress) -ceq ($whole.result.row | ConvertTo-Json -Compress)) 'mismatch control preserves entire current and selected row'

  # A distinct unpaired clear changes canonical current without introducing a
  # compact/full openRows line difference. No observed return is normalized.
  $appendedSmall = Join-Path $root 'append-small-whole.jsonl'
  [IO.File]::WriteAllText($appendedSmall, $smallText + $later + "`n", $utf8)
  $appendOracle = Invoke-DecisionHistoryNative 'append-whole-oracle-frozen-argument' $appendedSmall $observedPath
  Assert-DecisionHistory (-not $appendOracle.result.complete -and $appendOracle.result.current.healthy -and $appendOracle.result.current.unpairedClears -eq 1) 'distinct appended event causally changes complete current'
  $updated = Invoke-DecisionHistoryNative 'append-complete-reducer' $appendedSmall '' 'observe'
  $updatedPath = Join-Path $root 'observed-appended.json'
  [IO.File]::WriteAllText($updatedPath, $updated.resultJson, $utf8)
  $appendMatched = Invoke-DecisionHistoryNative 'append-matching-whole-oracle' $appendedSmall $updatedPath
  Assert-DecisionHistory $appendMatched.result.complete 'updated actual observed argument matches appended current'
  $appendBaseline = $null
  foreach ($pass in @('append', 'replay')) {
    try {
      [IO.File]::AppendAllText($full, $later + "`n", $utf8)
      $appendIdentity = Get-DecisionHistoryIdentity $full
      $actual = Invoke-DecisionHistoryNative ($pass + '-actual-frozen-argument') $full $observedPath
      Assert-DecisionHistoryWhole $actual $appendOracle ($pass + ' entire changed output')
      $matched = Invoke-DecisionHistoryNative ($pass + '-actual-matching-argument') $full $updatedPath
      Assert-DecisionHistoryWhole $matched $appendMatched ($pass + ' entire matching output')
      if ($pass -ceq 'append') { $appendBaseline = $appendIdentity } else {
        Assert-DecisionHistory ($appendIdentity.sha256 -ceq $appendBaseline.sha256 -and $appendIdentity.bytes -eq $appendBaseline.bytes) 'replay reproduces exact appended bytes'
      }
    } finally {
      [IO.File]::WriteAllBytes($full, $originalBytes)
      [IO.File]::SetLastWriteTimeUtc($full, [datetime]::new($originalIdentity.mtimeUtcTicks, [DateTimeKind]::Utc))
    }
    Assert-DecisionHistory ((Get-DecisionHistoryIdentity $full | ConvertTo-Json -Compress) -ceq ($originalIdentity | ConvertTo-Json -Compress)) ($pass + ' exact restoration')
    $restored = Invoke-DecisionHistoryNative ($pass + '-restored-whole') $full $observedPath
    Assert-DecisionHistoryWhole $restored $whole ($pass + ' whole replay restoration')
  }
  $sourceAfter = @($sourcePaths | ForEach-Object { Get-DecisionHistoryIdentity $_ }) | ConvertTo-Json -Depth 10 -Compress
  Assert-DecisionHistory ($sourceBefore -ceq $sourceAfter) 'all source identities unchanged'
  Write-Output "PASS decision breaker exact literal history caller checks=$checks nativeCalls=$nativeCalls LF=$($lf.Count) bytes=$($originalBytes.Length) anchor=14530; function-only synthetic qualification, NOT live authority/full Report/admission/rich-event memory/all-caller proof"
} finally {
  $fullRoot = [IO.Path]::GetFullPath($root)
  $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
  if ((Split-Path -Parent $fullRoot).TrimEnd('\', '/') -cne $temp -or
      (Split-Path -Leaf $fullRoot) -cnotlike 'decision-breaker-history-*') { throw 'unsafe private fixture cleanup' }
  if (Test-Path -LiteralPath $fullRoot) { Remove-Item -LiteralPath $fullRoot -Recurse -Force }
}
