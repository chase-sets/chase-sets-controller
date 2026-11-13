[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false, $true)
[Console]::OutputEncoding = $utf8
$checks = 0; $nativeCalls = 0; $comparison = 0
$temporary = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
$retained = -not [string]::IsNullOrWhiteSpace($env:REVIEW_REDUCER_HISTORY_EVIDENCE)
$parent = if ($retained) { [IO.Path]::GetFullPath($env:REVIEW_REDUCER_HISTORY_EVIDENCE) } else { $temporary }
$leaf = 'review-reducer-history-' + [guid]::NewGuid().ToString('N')
$root = Join-Path $parent $leaf
$cli = Join-Path $PSScriptRoot 'review-head-reducer.ps1'
$pr = 491649; $head = 'a' * 40
$sourcePaths = @('review-head-reducer.ps1', 'review-head-contract.psm1', 'dispatch-ledger-reader.psm1',
  'routing-data.ps1', 'contracts/dispatch-history-callers.json', 'dispatch-history-review-reducer.test.ps1') |
  ForEach-Object { Join-Path $PSScriptRoot $_ }
function Json($Value) { ConvertTo-Json -InputObject $Value -Depth 100 -Compress -EscapeHandling EscapeNonAscii }
function Save([string]$Name, $Value) { [IO.File]::WriteAllText((Join-Path $root $Name), (Json $Value), $utf8) }
function Check([bool]$Value, [string]$Message) {
  $script:checks++
  if (-not $Value) { throw "ASSERT: $Message" }
}
function Hash([byte[]]$Bytes) { [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant() }
function Identity([string]$Path) {
  $f = Get-Item -LiteralPath $Path
  [ordered]@{ path = $f.FullName; bytes = $f.Length; mtimeUtcTicks = $f.LastWriteTimeUtc.Ticks
    sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
}
function SourceIdentities { @($sourcePaths | ForEach-Object { Identity $_ }) }
# Compare JSON values recursively, with ordinal object keys and ordered arrays.
# Property order is not JSON identity; no returned leaves are discarded.
function GraphDiff($Actual, $Expected, [string]$At = '$') {
  if ($null -eq $Actual -or $null -eq $Expected) {
    if (-not ($null -eq $Actual -and $null -eq $Expected)) { "$At actual=$(Json $Actual) expected=$(Json $Expected)" }
    return
  }
  $am = $Actual -is [Collections.IDictionary]; $em = $Expected -is [Collections.IDictionary]
  if ($am -or $em) {
    if (-not ($am -and $em)) { "$At object/type actual=$(Json $Actual) expected=$(Json $Expected)"; return }
    foreach ($key in @(@($Actual.Keys) + @($Expected.Keys) | Sort-Object -Unique -CaseSensitive)) {
      if ($key -cnotin @($Actual.Keys) -or $key -cnotin @($Expected.Keys)) {
        "$At.$key missing key actual=$(Json $Actual) expected=$(Json $Expected)"
      } else { GraphDiff $Actual[$key] $Expected[$key] "$At.$key" }
    }
    return
  }
  $aa = $Actual -is [array]; $ea = $Expected -is [array]
  if ($aa -or $ea) {
    if (-not ($aa -and $ea) -or $Actual.Count -ne $Expected.Count) {
      "$At array/type/count actual=$(Json $Actual) expected=$(Json $Expected)"; return
    }
    for ($i = 0; $i -lt $Actual.Count; $i++) { GraphDiff $Actual[$i] $Expected[$i] "$At[$i]" }
    return
  }
  if ((Json $Actual) -cne (Json $Expected)) { "$At actual=$(Json $Actual) expected=$(Json $Expected)" }
}
function Graph($Actual, $Expected, [string]$Name) {
  $a = ConvertFrom-Json -InputObject (Json $Actual) -AsHashtable -DateKind String -Depth 100 -NoEnumerate
  $e = ConvertFrom-Json -InputObject (Json $Expected) -AsHashtable -DateKind String -Depth 100 -NoEnumerate
  $diff = @(GraphDiff $a $e)
  $script:comparison++
  Save ('compare-{0:D3}.json' -f $script:comparison) ([ordered]@{ name = $Name; actual = $a; expected = $e; differences = $diff })
  Check ($diff.Count -eq 0) "$Name full graph differences: $($diff -join '; ')"
}
function Parse([string]$Path) {
  $tokens = $null; $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
  Check ($errors.Count -eq 0) "complete source AST parses: $Path"
  return $ast
}
function BindSource {
  $ast = Parse $cli
  $command = @(Get-Command $cli)[0]
  Check ($command.ScriptBlock.Ast.Extent.Text -ceq $ast.Extent.Text) 'entire external CLI ScriptBlock AST equals entire parsed source'
  $calls = @($ast.FindAll({param($n)
    $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Read-ExactHeadReviewHistory'
  }, $true))
  Check ($calls.Count -eq 1 -and $calls[0].Extent.Text -ceq 'Read-ExactHeadReviewHistory -Path $HistoryPath -MaxRows $MaxHistoryRows -MaxBytes $MaxHistoryBytes') 'literal actual row49 call'
  $tokens = $null; $errors = $null
  [void][Management.Automation.Language.Parser]::ParseInput($calls[0].Extent.Text, [ref]$tokens, [ref]$errors)
  $shape = @($tokens | Where-Object { $_.Kind -notin @('NewLine','LineContinuation','Comment','EndOfInput') } |
    ForEach-Object { "$($_.Kind):$($_.Text)" }) -join "`n"
  $callHash = Hash ($utf8.GetBytes($shape))
  Check ($errors.Count -eq 0 -and $callHash -ceq '45a619348756b9d7affbc1ce03977d7704d384cea56d3ffd3577f9c08c22c5ba') 'literal token call hash'
  $manifest = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'contracts/dispatch-history-callers.json')) | ConvertFrom-Json -AsHashtable
  Graph $manifest.rows[46] ([ordered]@{ path = '.orchestrator/review-head-reducer.ps1'; scope = '<script>'
    api = 'read-exactheadreviewhistory'; ordinal = 1; mode = 'one-pass-stream'; projection = 'dispatch-count/v1'
    peakEnvelope = 'parsed-history'; callSha256 = $callHash }) 'literal rows[46] entire eight-field tuple'
  $module = Import-Module (Join-Path $PSScriptRoot 'review-head-contract.psm1') -Force -PassThru -DisableNameChecking
  $bindings = @()
  foreach ($file in @('review-head-contract.psm1', 'routing-data.ps1', 'dispatch-ledger-reader.psm1')) {
    $path = Join-Path $PSScriptRoot $file; $dependency = Parse $path
    $owner = if ($file -ceq 'dispatch-ledger-reader.psm1') { Get-Module dispatch-ledger-reader } else { $module }
    $functions = @($dependency.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]}, $true))
    foreach ($function in $functions) {
      # Nested functions are contained in their complete outer function AST.
      $ancestor = $function.Parent; $nested = $false
      while ($ancestor) { if ($ancestor -is [Management.Automation.Language.FunctionDefinitionAst]) { $nested = $true; break }; $ancestor = $ancestor.Parent }
      if ($nested) { continue }
      $loaded = & $owner { param($name) (Get-Command $name -CommandType Function).ScriptBlock.Ast.Extent.Text } $function.Name
      Check ($loaded -ceq $function.Extent.Text) "complete loaded dependency AST: $file/$($function.Name)"
      $bindings += [ordered]@{ file = $file; function = $function.Name; astSha256 = Hash ($utf8.GetBytes($loaded)) }
    }
  }
  Save 'source-binding.json' ([ordered]@{ cli = Identity $cli; cliAstSha256 = Hash ($utf8.GetBytes($ast.Extent.Text)); literalCall = $calls[0].Extent.Text; row = $manifest.rows[46]; bindings = $bindings })
}
function Native([string]$Name, [string[]]$Arguments, [int]$ExpectedExit = 0) {
  $si = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })))
  $si.UseShellExecute = $false; $si.CreateNoWindow = $true
  $si.RedirectStandardOutput = $true; $si.RedirectStandardError = $true
  $si.StandardOutputEncoding = $utf8; $si.StandardErrorEncoding = $utf8
  foreach ($argument in $Arguments) { [void]$si.ArgumentList.Add($argument) }
  # Ordinary read-only vocabulary compatibility is sufficient for synthetic receipts.
  # Isolate optional routing reads, not history I/O, from workstation authority.
  $si.Environment['CHASE_SETS_ROUTING_DATA_ROOT'] = Join-Path $root 'no-routing-state'
  $si.Environment['CHASE_SETS_ROUTING_LKG_PATH'] = Join-Path $root 'no-routing-cache.json'
  $before = SourceIdentities
  $inputs = @(Get-ChildItem -LiteralPath $root -File -Filter '*.jsonl' | ForEach-Object { Identity $_.FullName })
  $start = [datetime]::UtcNow; $clock = [Diagnostics.Stopwatch]::StartNew()
  $process = [Diagnostics.Process]::Start($si)
  $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
  $process.WaitForExit()
  $out = $stdout.GetAwaiter().GetResult(); $err = $stderr.GetAwaiter().GetResult(); $code = $process.ExitCode
  $clock.Stop(); $end = [datetime]::UtcNow; $process.Dispose(); $script:nativeCalls++
  $after = SourceIdentities
  $packet = [ordered]@{ name = $Name; executable = $si.FileName; argv = @($si.ArgumentList)
    environment = @{ CHASE_SETS_ROUTING_DATA_ROOT = $si.Environment['CHASE_SETS_ROUTING_DATA_ROOT']; CHASE_SETS_ROUTING_LKG_PATH = $si.Environment['CHASE_SETS_ROUTING_LKG_PATH'] }
    exitCode = $code; startUtc = $start.ToString('o'); endUtc = $end.ToString('o'); wallMs = $clock.Elapsed.TotalMilliseconds
    stdout = $out; stderr = $err; sourceBefore = $before; sourceAfter = $after; inputsBefore = $inputs
    inputsAfter = @(Get-ChildItem -LiteralPath $root -File -Filter '*.jsonl' | ForEach-Object { Identity $_.FullName }) }
  Save ('native-{0:D2}-{1}.json' -f $nativeCalls, $Name) $packet
  Json $packet | Out-Host
  Graph $after $before "$Name all source identities"
  Graph $packet.inputsAfter $inputs "$Name all history identities"
  Check ($code -eq $ExpectedExit) "$Name native exit=$code expected=$ExpectedExit stderr=$err"
  return $packet
}
function InvokeCli([string]$Name, [string]$Path) {
  $packet = Native $Name @('-NoProfile','-NonInteractive','-File',$cli,'-Pr',[string]$pr,'-CurrentHead',$head,'-HistoryPath',$Path)
  Check ($packet.stderr -ceq '') "$Name no native stderr"
  return ConvertFrom-Json -InputObject $packet.stdout -Depth 100 -DateKind String -AsHashtable -NoEnumerate
}
function Receipt([string]$Outcome, [string]$Attempt, [int]$Minute) {
  $block = $Outcome -cne 'PASS'
  $ids = if ($block) { @('F49') } else { @() }
  [ordered]@{ ts = "2026-01-01T00:$('{0:D2}' -f $Minute):00Z"; kind = 'review-complete'; pr = $pr
    receiptSchema = 'exact-head-review-receipt/v1'; reviewedHead = $head; reviewerAttempt = $Attempt; authorAttempt = 'synthetic-author-49'
    reviewContract = 'review-contract/v2'; completeSweep = $true; outcome = $Outcome
    model = 'gpt-5.6-terra'; authorModel = 'gpt-5.6-terra'; findingIds = [object[]]@($ids)
    findings = [ordered]@{ blocking = [int]$block; candidates = [int]$block; nonBlocking = 0 } }
}
function Fingerprint($Receipt) {
  # Independently specified receipt identity tuple. kind is not fingerprinted.
  $tuple = [ordered]@{}
  foreach ($field in @('ts','pr','receiptSchema','reviewedHead','reviewerAttempt','authorAttempt','reviewContract','completeSweep',
      'outcome','model','authorModel','findingIds','findings')) { $tuple[$field] = $Receipt[$field] }
  Hash ($utf8.GetBytes(($tuple | ConvertTo-Json -Compress -Depth 5)))
}
function ReaderAudit([long]$Bytes, [int]$Count) {
  [ordered]@{ pathStatus = 'ok'; bytes = $Bytes; rows = $Count; parsedRows = $Count; malformedRows = 0
    truncated = $false; malformedLineNumbers = @() }
}
function Expected([long]$Bytes, [int]$Count, [string]$State, [string]$Reason, $LatestReceipt = $null) {
  $audit = ReaderAudit $Bytes $Count
  foreach ($item in @(@('controllerReceiptsIgnored',0), @('legacyOrInvalidRelevantReceipts',0), @('malformedExactHeadReceipts',0),
      @('validRelevantReceipts',$Count), @('duplicateReceipts',0), @('validContinuations',0), @('malformedContinuations',0))) { $audit[$item[0]] = $item[1] }
  $audit.uncertainReceipts = @(); $audit.malformedExactHeadReceiptDetails = @()
  $latest = $null
  if ($null -ne $LatestReceipt) {
    $latest = [ordered]@{}
    foreach ($field in @('ts','reviewedHead','outcome','reviewerAttempt','authorAttempt','model','authorModel')) { $latest[$field] = $LatestReceipt[$field] }
    $latest.receiptIdentity = Fingerprint $LatestReceipt
  }
  [ordered]@{ schema = 'exact-head-review-reducer/v1'; state = $State; reason = $Reason; pr = $pr; currentHead = $head; latest = $latest; audit = $audit }
}
function WriteSmall([string]$Name, [string[]]$Lines) {
  $path = Join-Path $root ($Name + '.jsonl')
  [IO.File]::WriteAllText($path, (($Lines -join "`n") + "`n"), $utf8)
  Check ((Get-Item -LiteralPath $path).Length -lt 33554432 -and $Lines.Count -lt 50000) "$Name below both former cliffs"
  return $path
}
function PhysicalProof([string]$Name, [string]$Path, [byte[]]$Bytes, [int]$LfCount, [object[]]$Records) {
  $rows = @($Records | ForEach-Object {
    [ordered]@{ line = $_.line; raw = $_.raw; byteLength = $utf8.GetByteCount($_.raw)
      rawSha256 = Hash ($utf8.GetBytes($_.raw)); value = ConvertFrom-Json -InputObject $_.raw -AsHashtable -DateKind String }
  })
  $known = [ordered]@{ complete = $true; rows = $rows; audit = ReaderAudit $Bytes.Length $rows.Count; reason = 'HISTORY_COMPLETE'
    snapshotLength = $Bytes.Length; snapshotLines = $LfCount; snapshotHash = Hash $Bytes; cursor = $Bytes.Length; partialTrailingRow = $false }
  $actual = Read-ExactHeadReviewHistory -Path $Path
  Graph $actual $known "$Name full supporting history graph including physical line/raw/hash/byte identities"
}
function Restore([string]$Path, [byte[]]$Bytes, $OriginalIdentity) {
  [IO.File]::WriteAllBytes($Path, $Bytes)
  [IO.File]::SetLastWriteTimeUtc($Path, [datetime]::new($OriginalIdentity.mtimeUtcTicks, [DateTimeKind]::Utc))
  Graph (Identity $Path) $OriginalIdentity 'exact restored original path/length/hash/mtime'
  Check ([Convert]::ToBase64String([IO.File]::ReadAllBytes($Path)) -ceq [Convert]::ToBase64String($Bytes)) 'exact original restored bytes'
}
$savedRoutingRoot = $env:CHASE_SETS_ROUTING_DATA_ROOT; $savedLkg = $env:CHASE_SETS_ROUTING_LKG_PATH
$success = $false
try {
  [void][IO.Directory]::CreateDirectory($root)
  $env:CHASE_SETS_ROUTING_DATA_ROOT = Join-Path $root 'no-routing-state'
  $env:CHASE_SETS_ROUTING_LKG_PATH = Join-Path $root 'no-routing-cache.json'
  $sourceBefore = SourceIdentities
  Save 'source-before.json' $sourceBefore
  [void][IO.Directory]::CreateDirectory((Join-Path $root 'source'))
  foreach ($path in $sourcePaths) { [IO.File]::WriteAllBytes((Join-Path $root ('source/' + (Split-Path -Leaf $path))), [IO.File]::ReadAllBytes($path)) }
  # Prove native capture before importing or invoking the candidate.
  $preflight = Native 'capture-preflight' @('-NoProfile','-NonInteractive','-Command',
    '[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);[Console]::Out.Write("out-"+[char]0xe9+"`nTAIL`n");[Console]::Error.Write("err-"+[char]0x3bb+"`nSTDERR-TAIL`n");exit 7') 7
  Check ($preflight.stdout -ceq "out-$([char]0xe9)`nTAIL`n" -and $preflight.stderr -ceq "err-$([char]0x3bb)`nSTDERR-TAIL`n") 'complete UTF8 non-ASCII stdout and stderr preflight'
  BindSource
  $early = Receipt 'BLOCK_FIXABLE' 'synthetic-shared-review-49' 1
  $late = Receipt 'PASS' 'synthetic-shared-review-49' 2
  $appended = Receipt 'BLOCK_REPLAN' 'synthetic-distinct-review-49' 3
  $raw = @($early, $late, $appended) | ForEach-Object { $_ | ConvertTo-Json -Depth 10 -Compress }
  Save 'fixture-receipts.json' ([ordered]@{ early=$early; late=$late; appended=$appended; raw=$raw })
  foreach ($receipt in @($early,$late,$appended)) {
    $validation = Get-ReviewReceiptValidation (ConvertFrom-Json -InputObject ($receipt | ConvertTo-Json -Depth 10) -DateKind String)
    Check $validation.valid "independent ordinary receipt valid: $($receipt.outcome) errors=$($validation.errors -join ',')"
  }
  Check ((Fingerprint $early) -cne (Fingerprint $late) -and $raw[0] -cne $raw[1]) 'distinct receipt fingerprints and raw bytes, same reviewer attempt'
  $small = WriteSmall 'small-complete' @($raw[0],$raw[1])
  $smallGraph = InvokeCli 'small-complete' $small
  Graph $smallGraph (Expected (Get-Item -LiteralPath $small).Length 2 'unknown' 'CONTRADICTORY_ATTEMPT_RECEIPTS') 'independent complete small contradictory oracle'
  $path = Join-Path $root 'private-physical-history.jsonl'
  $writer = [IO.StreamWriter]::new($path, $false, $utf8, 65536)
  try {
    $writer.Write($raw[0] + "`n")
    $padding = (' ' * 700) + "`n"
    for ($i = 0; $i -lt 60000; $i++) { $writer.Write($padding) }
    $writer.Write($raw[1] + "`n")
  } finally { $writer.Dispose() }
  $original = [IO.File]::ReadAllBytes($path); $originalIdentity = Identity $path
  $earlyBytes = $utf8.GetByteCount($raw[0] + "`n"); $lateOffset = $earlyBytes + 60000 * 701
  $lf = [regex]::Matches($utf8.GetString($original), "`n")
  Check ($lf.Count -eq 60002 -and $original.Length -gt 33554432 -and $lateOffset -gt 33554432 -and
    $original[-1] -eq 10 -and [Array]::IndexOf($original,[byte]13) -eq -1) 'complete independently constructed UTF8 LF sparse history crosses both physical cliffs'
  $suffixStart = $lf[$lf.Count - 50000 - 1].Index + 1
  $prefixEnd = [Array]::LastIndexOf($original, [byte]10, 33554431) + 1
  $suffix = [byte[]]::new($original.Length - $suffixStart); [Array]::Copy($original,$suffixStart,$suffix,0,$suffix.Length)
  $prefix = [byte[]]::new($prefixEnd); [Array]::Copy($original,$prefix,$prefix.Length)
  $prefixLines = [regex]::Matches($utf8.GetString($prefix), "`n").Count
  Check ($suffixStart -gt $earlyBytes -and [regex]::Matches($utf8.GetString($suffix), "`n").Count -eq 50000) 'exact original last50000 LF suffix drops early BLOCK only'
  Check ($prefixEnd -le 33554432 -and $prefixEnd -lt $lateOffset -and
    [Array]::IndexOf($original,[byte]10,$prefixEnd) + 1 -gt 33554432) 'maximal complete-line <=32MiB prefix drops late PASS only'
  [IO.File]::WriteAllBytes((Join-Path $root 'original.jsonl'),$original)
  [IO.File]::WriteAllBytes((Join-Path $root 'exact-suffix.jsonl'),$suffix)
  [IO.File]::WriteAllBytes((Join-Path $root 'maximal-prefix.jsonl'),$prefix)
  Save 'geometry.json' ([ordered]@{ original = $originalIdentity; lfLines = $lf.Count; meaningfulRows = 2; whitespaceLines = 60000
    earlyLine = 1; earlyOffset = 0; lateLine = 60002; lateOffset = $lateOffset; suffixStart = $suffixStart
    suffixLength = $suffix.Length; suffixSha256 = Hash $suffix; suffixLateLine = 50000
    prefixEnd = $prefixEnd; prefixLines = $prefixLines; prefixSha256 = Hash $prefix })
  PhysicalProof 'full' $path $original 60002 @(@{line=1;raw=$raw[0]},@{line=60002;raw=$raw[1]})
  $whole = InvokeCli 'full-original' $path
  $fullExpected = ConvertFrom-Json -InputObject (Json $smallGraph) -AsHashtable -DateKind String
  $fullExpected.audit.bytes = $original.Length
  Graph $whole $fullExpected 'whole full CLI versus complete small oracle with only independently known audit.bytes difference'
  Graph (InvokeCli 'full-replay' $path) $whole 'deterministic entire full replay'
  foreach ($cut in @(
      @{name='suffix';bytes=$suffix;raw=$raw[1];receipt=$late;state='authorized';reason='LATEST_EXACT_HEAD_PASS';lines=50000;recordLine=50000},
      @{name='prefix';bytes=$prefix;raw=$raw[0];receipt=$early;state='blocked';reason='LATEST_EXACT_HEAD_BLOCK_FIXABLE';lines=$prefixLines;recordLine=1})) {
    $cutSmall = WriteSmall ($cut.name + '-small') @($cut.raw)
    $oracle = InvokeCli ($cut.name + '-small-complete') $cutSmall
    Graph $oracle (Expected (Get-Item -LiteralPath $cutSmall).Length 1 $cut.state $cut.reason $cut.receipt) ($cut.name + ' independent entire small oracle')
    try {
      [IO.File]::WriteAllBytes($path,$cut.bytes)
      PhysicalProof $cut.name $path $cut.bytes $cut.lines @(@{line=$cut.recordLine;raw=$cut.raw})
      $actual = InvokeCli ($cut.name + '-actual-byte-slice') $path
      $expectedCut = ConvertFrom-Json -InputObject (Json $oracle) -AsHashtable -DateKind String
      $expectedCut.audit.bytes = $cut.bytes.Length
      Graph $actual $expectedCut ($cut.name + ' full default CLI graph with independent physical bytes')
      $semanticDiff = @(GraphDiff $actual $whole)
      Save ($cut.name + '-versus-full.json') ([ordered]@{ actual = $actual; full = $whole; differences = $semanticDiff })
      Check ($actual.state -ceq $cut.state -and $actual.state -cne $whole.state) ($cut.name + ' necessary evidence loss changes actual semantic disposition, not reader refusal')
    } finally { Restore $path $original $originalIdentity }
    Graph (InvokeCli ($cut.name + '-restored-replay') $path) $whole ($cut.name + ' entire restored CLI graph')
  }
  $appendSmall = WriteSmall 'appended-small' $raw
  $appendOracle = InvokeCli 'appended-small-complete' $appendSmall
  Graph $appendOracle (Expected (Get-Item -LiteralPath $appendSmall).Length 3 'unknown' 'CONTRADICTORY_ATTEMPT_RECEIPTS') 'independent entire appended small oracle'
  $frozen = ConvertFrom-Json -InputObject (Json $whole) -AsHashtable -DateKind String
  $frozenBytes = Json $whole
  foreach ($pass in @('append','append-repeat')) {
    try {
      [IO.File]::AppendAllText($path,($raw[2] + "`n"),$utf8)
      $appendBytes = [IO.File]::ReadAllBytes($path)
      Check ($appendBytes.Length -eq $original.Length + $utf8.GetByteCount($raw[2] + "`n")) 'append exact length'
      $originalPrefix = [byte[]]::new($original.Length); [Array]::Copy($appendBytes,$originalPrefix,$original.Length)
      Check ((Hash $originalPrefix) -ceq $originalIdentity.sha256) 'append preserves exact original prefix'
      PhysicalProof $pass $path $appendBytes 60003 @(@{line=1;raw=$raw[0]},@{line=60002;raw=$raw[1]},@{line=60003;raw=$raw[2]})
      $updated = InvokeCli ($pass + '-fresh-default-cli') $path
      $expectedAppend = ConvertFrom-Json -InputObject (Json $appendOracle) -AsHashtable -DateKind String
      $expectedAppend.audit.bytes = $appendBytes.Length
      Graph $updated $expectedAppend ($pass + ' entire appended default CLI graph')
      Graph (InvokeCli ($pass + '-replay') $path) $updated ($pass + ' deterministic appended replay')
      Graph $whole $frozen ($pass + ' prior returned graph stays frozen in this same native harness process')
      Check ((Json $whole) -ceq $frozenBytes) 'captured prior result remains byte-frozen as well as graph-equal'
      Save ($pass + '-changes.json') ([ordered]@{ before = $whole; after = $updated; differences = @(GraphDiff $updated $whole)
        interpretation = 'State and reason remain unknown/CONTRADICTORY_ATTEMPT_RECEIPTS; only complete audit bytes/rows/parsedRows/validRelevantReceipts change. Not a new authorization transition.' })
      [IO.File]::WriteAllBytes((Join-Path $root ($pass + '-complete.jsonl')),$appendBytes)
    } finally { Restore $path $original $originalIdentity }
    Graph (InvokeCli ($pass + '-restored-replay') $path) $whole ($pass + ' entire restored default graph')
  }
  # Cheap ordinary transition control. Same CLI/path/PR/head/defaults before and after append.
  $simple = WriteSmall 'simple-authorized-to-blocked' @($raw[1])
  $simpleOriginal = [IO.File]::ReadAllBytes($simple); $simpleIdentity = Identity $simple
  $beforeSimple = InvokeCli 'simple-authorized' $simple
  Graph $beforeSimple (Expected $simpleOriginal.Length 1 'authorized' 'LATEST_EXACT_HEAD_PASS' $late) 'entire independent authorized graph'
  $simpleOraclePath = WriteSmall 'simple-appended-oracle' @($raw[1],$raw[2])
  $simpleOracle = InvokeCli 'simple-blocked-small-oracle' $simpleOraclePath
  Graph $simpleOracle (Expected (Get-Item -LiteralPath $simpleOraclePath).Length 2 'blocked' 'LATEST_EXACT_HEAD_BLOCK_REPLAN' $appended) 'entire independent blocked append oracle'
  try {
    [IO.File]::AppendAllText($simple,($raw[2] + "`n"),$utf8)
    Graph (InvokeCli 'simple-fresh-blocked-append' $simple) $simpleOracle 'actual authorized-to-blocked append full graph'
    Graph $beforeSimple (Expected $simpleOriginal.Length 1 'authorized' 'LATEST_EXACT_HEAD_PASS' $late) 'simple prior captured graph remains frozen'
  } finally { Restore $simple $simpleOriginal $simpleIdentity }
  Graph (InvokeCli 'simple-restored-authorized' $simple) $beforeSimple 'simple entire restored graph'
  Graph (SourceIdentities) $sourceBefore 'all unchanged sources including entire test after all controls'
  Save 'result.json' ([ordered]@{ checks = $checks; nativeCalls = $nativeCalls; comparisons = $comparison; full = $whole
    fullLf = 60002; fullBytes = $original.Length; appendInterpretation = 'unknown remains unknown; complete audit changes only'
    proofLimit = 'ordinary sparse actual literal49 CLI regression only; not rich-event/memory/downstream/all53/global/battery/release qualification' })
  $success = $true
  Write-Output "PASS review reducer literal row49 checks=$checks nativeCalls=$nativeCalls wholeGraphs=$comparison LF=60002 bytes=$($original.Length) full=contradictory suffix=authorized prefix=blocked append=audit-only simple=authorized-to-blocked; ordinary sparse CLI only, NOT global/all53/battery/release qualification"
} catch {
  Save 'failure.json' ([ordered]@{ error = ($_ | Out-String); checks = $checks; nativeCalls = $nativeCalls; sourcesAtFailure = SourceIdentities
    inputsAtFailure = @(Get-ChildItem -LiteralPath $root -File -Recurse | ForEach-Object { Identity $_.FullName }) })
  Write-Output "RETAINED ordinary failure inputs/source/native evidence: $root"
  throw
} finally {
  $env:CHASE_SETS_ROUTING_DATA_ROOT = $savedRoutingRoot; $env:CHASE_SETS_ROUTING_LKG_PATH = $savedLkg
  if ($success -and -not $retained) {
    $resolved = [IO.Path]::GetFullPath($root)
    if ((Split-Path -Parent $resolved).TrimEnd('\','/') -cne $temporary -or (Split-Path -Leaf $resolved) -cne $leaf -or
        $leaf -cnotmatch '^review-reducer-history-[a-f0-9]{32}$') { throw 'unsafe owned GUID fixture cleanup' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
  }
}
