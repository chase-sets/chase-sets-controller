[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$checks = 0
$nativeCalls = 0
$utf8 = [Text.UTF8Encoding]::new($false, $true)
$temporary = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
$root = Join-Path $temporary ('rebase-lines-history-' + [guid]::NewGuid().ToString('N'))
function Assert-RebaseHistory([bool]$Value, [string]$Message) {
  $script:checks++
  if (-not $Value) { throw "ASSERT: $Message" }
}
function Get-RebaseHistoryIdentity([string]$Path) {
  $file = Get-Item -LiteralPath $Path
  [ordered]@{ path = $file.FullName; bytes = $file.Length; mtimeUtcTicks = $file.LastWriteTimeUtc.Ticks
    sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
}
function Get-RebaseHistoryInputs {
  ConvertTo-Json -InputObject @($sourcePaths + @(Get-ChildItem -LiteralPath $root -File | Select-Object -ExpandProperty FullName) |
    ForEach-Object { Get-RebaseHistoryIdentity $_ }) -Depth 10 -Compress
}
function Invoke-RebaseHistoryNative([string]$Name, [string]$History) {
  $jobPath = Join-Path $root 'job.json'
  [IO.File]::WriteAllText($jobPath, ([ordered]@{ sourceRoot = $PSScriptRoot; history = $History } | ConvertTo-Json -Compress), $utf8)
  $before = Get-RebaseHistoryInputs
  $info = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })))
  $info.UseShellExecute = $false
  $info.CreateNoWindow = $true
  $info.RedirectStandardOutput = $true
  $info.RedirectStandardError = $true
  foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $childPath, '-InputPath', $jobPath)) { [void]$info.ArgumentList.Add($argument) }
  $clock = [Diagnostics.Stopwatch]::StartNew()
  $process = $null; $out = ''; $err = ''; $exitCode = $null
  try {
    $process = [Diagnostics.Process]::Start($info)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $out = $stdout.GetAwaiter().GetResult()
    $err = $stderr.GetAwaiter().GetResult()
    $exitCode = $process.ExitCode
  } finally {
    $clock.Stop()
    if ($process) { $process.Dispose() }
    $after = Get-RebaseHistoryInputs
    $script:nativeCalls++
    # The full streams and identities are emitted before any failure assertion.
    [ordered]@{ name = $Name; executable = $info.FileName; arguments = @($info.ArgumentList)
      exitCode = $exitCode; elapsedMs = $clock.Elapsed.TotalMilliseconds; inputsBefore = $before; inputsAfter = $after
      stdout = $out; stderr = $err } | ConvertTo-Json -Depth 15 -Compress | Write-Output | Out-Host
  }
  Assert-RebaseHistory ($before -ceq $after) "$Name changed source, argument, or fixture identity"
  Assert-RebaseHistory ($exitCode -eq 0 -and $err -ceq '') "$Name native child failed: exit=$exitCode stderr=$err"
  $payload = $out | ConvertFrom-Json -Depth 100 -DateKind String
  Assert-RebaseHistory ($payload.historyBefore -ceq $payload.historyAfter) "$Name changed history bytes/length/mtime"
  return $payload
}
function Assert-RebaseHistoryWhole($Actual, $Expected, [string]$Message) {
  Assert-RebaseHistory ($Actual.resultJson -ceq $Expected.resultJson) "$Message entire sequence differs: actual=$($Actual.resultJson) expected=$($Expected.resultJson)"
}
function Get-RebaseHistoryRawLines([byte[]]$Bytes) {
  @($utf8.GetString($Bytes).Split([char]10) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}
function Write-RebaseHistorySmall([string]$Path, [string[]]$Lines) {
  [IO.File]::WriteAllText($Path, (($Lines -join "`n") + "`n"), $utf8)
  Assert-RebaseHistory ((Get-Item -LiteralPath $Path).Length -lt 33554432 -and $Lines.Count -lt 50000) 'small complete oracle stays below both former cliffs'
}

try {
  [void][IO.Directory]::CreateDirectory($root)
  $sourcePaths = @('landed-integration-evidence.psm1', 'dispatch-ownership.ps1', 'dispatch-ledger-reader.psm1',
    'integration-dispatch-contract.ps1', 'routing-data.ps1', 'contracts/dispatch-history-callers.json',
    'dispatch-history-rebase-lines.test.ps1') | ForEach-Object { Join-Path $PSScriptRoot $_ }
  $sourceBefore = ConvertTo-Json -InputObject @($sourcePaths | ForEach-Object { Get-RebaseHistoryIdentity $_ }) -Depth 10 -Compress
  $manifest = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'contracts/dispatch-history-callers.json')) | ConvertFrom-Json
  $row = $manifest.rows[21]
  Assert-RebaseHistory ($row.path -ceq '.orchestrator/landed-integration-evidence.psm1' -and
    $row.scope -ceq 'Read-RebaseJsonLines' -and $row.api -ceq 'read-dispatchledgerlines' -and $row.ordinal -eq 1 -and
    $row.callSha256 -ceq '8275497c8e0b74b2b817bc6c2d60995bf93856b23e5d6ef5c069da40d6ef775a') 'literal manifest row22 identity'
  $childPath = Join-Path $root 'native-caller.ps1'
  $child = @'
param([Parameter(Mandatory)][string]$InputPath)
$ErrorActionPreference = 'Stop'
$job = [IO.File]::ReadAllText($InputPath) | ConvertFrom-Json -DateKind String
$modulePath = Join-Path $job.sourceRoot 'landed-integration-evidence.psm1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'actual module parse failure' }
$functionAst = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Read-RebaseJsonLines' }, $true)
if (-not $functionAst) { throw 'literal function absent' }
$calls = @($functionAst.Body.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Read-DispatchLedgerLines' }, $true))
if ($calls.Count -ne 1 -or $calls[0].Extent.Text -cne 'Read-DispatchLedgerLines -Path $Path') { throw 'literal call changed' }
$callTokens = $null; $callErrors = $null
[void][Management.Automation.Language.Parser]::ParseInput($calls[0].Extent.Text, [ref]$callTokens, [ref]$callErrors)
$shape = @($callTokens | Where-Object { $_.Kind -notin @('NewLine', 'LineContinuation', 'Comment', 'EndOfInput') } | ForEach-Object { "$($_.Kind):$($_.Text)" }) -join "`n"
$callHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($shape))).ToLowerInvariant()
if ($callErrors.Count -or $callHash -cne '8275497c8e0b74b2b817bc6c2d60995bf93856b23e5d6ef5c069da40d6ef775a') { throw 'literal AST hash changed' }
function LocalIdentity([string]$Path) {
  $f = Get-Item -LiteralPath $Path
  [ordered]@{ path = $f.FullName; bytes = $f.Length; mtimeUtcTicks = $f.LastWriteTimeUtc.Ticks
    sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() } | ConvertTo-Json -Compress
}
$before = LocalIdentity $job.history
$result = $null
try {
  $module = Import-Module $modulePath -Force -DisableNameChecking -PassThru
  $loaded = & $module { (Get-Command Read-RebaseJsonLines).ScriptBlock.Ast.Extent.Text }
  if ($loaded -cne $functionAst.Extent.Text) { throw 'imported function is not exact actual source' }
  $result = @(& $module { param($path) Read-RebaseJsonLines -Path $path -DispatchHistory } $job.history)
} finally {
  [ordered]@{ literalRow = 22; callSha256 = $callHash; historyBefore = $before; historyAfter = (LocalIdentity $job.history)
    result = $result; resultJson = (ConvertTo-Json -InputObject $result -Depth 100 -Compress) } | ConvertTo-Json -Depth 100 -Compress
}
'@
  [IO.File]::WriteAllText($childPath, $child, $utf8)
  $raw = @(
    '{"id":"early-alpha","instant":"2026-01-01T00:00:00Z","nested":{"map":{"a":null,"b":"001"},"array":[1,"1",null,{"deep":[true,false]}]},"empty":[]}',
    '{"id":"early-beta","nested":{"map":{"x":"null","y":null},"array":[[],{},["beta",2]]},"flag":false}',
    '{"id":"late-gamma","instant":"2026-11-01T00:00:00Z","nested":{"map":{"z":"003"},"array":[null,{"deep":[3,"03"]}]},"empty":{}}',
    '{"id":"late-delta","nested":{"map":{"d":null},"array":["delta",4,{"tail":true}]},"flag":true}'
  )
  $records = @{ 2 = $raw[0]; 10005 = $raw[1]; 50005 = $raw[2]; 60009 = $raw[3] }
  $path = Join-Path $root 'dispatch-log.jsonl'
  $writer = [IO.StreamWriter]::new($path, $false, $utf8)
  $writer.NewLine = "`n"
  try {
    for ($line = 1; $line -le 60010; $line++) {
      $writer.WriteLine($(if ($records.ContainsKey($line)) { $records[$line] } else { ' ' * 700 }))
    }
  } finally { $writer.Dispose() }
  $original = [IO.File]::ReadAllBytes($path)
  $originalIdentity = Get-RebaseHistoryIdentity $path
  $originalIdentityJson = $originalIdentity | ConvertTo-Json -Compress
  $originalTime = [IO.File]::GetLastWriteTimeUtc($path)
  $physicalLines = $utf8.GetString($original).Split([char]10).Length - 1
  Assert-RebaseHistory ($physicalLines -eq 60010 -and $original.Length -gt 33554432 -and
    [Array]::IndexOf($original, [byte]13) -eq -1 -and $original[-1] -eq 10) 'original exceeds both former cliffs with exactly 60010 LF-only terminated lines'
  $small = Join-Path $root 'small.jsonl'
  Write-RebaseHistorySmall $small $raw
  $oracle = Invoke-RebaseHistoryNative 'small-complete' $small
  $independent = ConvertFrom-Json -InputObject ('[' + ($raw -join ',') + ']') -DateKind String -Depth 100
  Assert-RebaseHistory ($oracle.resultJson -ceq (ConvertTo-Json -InputObject $independent -Depth 100 -Compress)) 'small complete sequence equals independent structured JSON array'
  $full = Invoke-RebaseHistoryNative 'full-original' $path
  Assert-RebaseHistoryWhole $full $oracle 'full versus small complete'
  Assert-RebaseHistoryWhole (Invoke-RebaseHistoryNative 'full-replay' $path) $full 'deterministic full replay'

  $suffixStart = $original.Length
  for ($index = 0; $index -le 50000; $index++) { $suffixStart = [Array]::LastIndexOf($original, [byte]10, $suffixStart - 1) }
  $suffixStart++
  $prefixLength = [Array]::LastIndexOf($original, [byte]10, 33554431, 33554432) + 1
  Assert-RebaseHistory ($prefixLength -gt 0 -and $prefixLength -le 33554432 -and
    [Array]::IndexOf($original, [byte]10, $prefixLength) + 1 -gt 33554432) 'prefix is maximal complete LF-line prefix at 32MiB'
  foreach ($cut in @('suffix', 'prefix')) {
    $start = if ($cut -ceq 'suffix') { $suffixStart } else { 0 }
    $length = if ($cut -ceq 'suffix') { $original.Length - $start } else { $prefixLength }
    $cutBytes = [byte[]]::new($length)
    [Array]::Copy($original, $start, $cutBytes, 0, $length)
    $cutLines = $utf8.GetString($cutBytes).Split([char]10).Length - 1
    Assert-RebaseHistory ($cutBytes[-1] -eq 10 -and ($cut -cne 'suffix' -or $cutLines -eq 50000)) "$cut physical cut geometry"
    $retained = @(Get-RebaseHistoryRawLines $cutBytes)
    $cutSmall = Join-Path $root "$cut-small.jsonl"
    Write-RebaseHistorySmall $cutSmall $retained
    $cutOracle = Invoke-RebaseHistoryNative "$cut-small-complete" $cutSmall
    $cutIndependent = ConvertFrom-Json -InputObject ('[' + ($retained -join ',') + ']') -DateKind String -Depth 100
    Assert-RebaseHistory ($cutOracle.resultJson -ceq (ConvertTo-Json -InputObject $cutIndependent -Depth 100 -Compress)) "$cut oracle is exactly retained raw nonempty lines"
    try {
      [IO.File]::WriteAllBytes($path, $cutBytes)
      Assert-RebaseHistory ([Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) -ceq [Convert]::ToBase64String($cutBytes)) "$cut bytes are exact original slice"
      [ordered]@{ cut = $cut; startByte = $start; length = $length; physicalLines = $cutLines
        original = $originalIdentity; retainedRawLines = $retained; cutIdentity = (Get-RebaseHistoryIdentity $path) } | ConvertTo-Json -Depth 15 -Compress | Write-Output
      $observed = Invoke-RebaseHistoryNative "$cut-actual" $path
      Assert-RebaseHistoryWhole $observed $cutOracle "$cut actual versus exact retained-line oracle"
      Assert-RebaseHistory ($observed.resultJson -cne $full.resultJson -and $observed.result.Count -lt $full.result.Count) "$cut causally loses distinct complete records"
      Assert-RebaseHistoryWhole (Invoke-RebaseHistoryNative "$cut-replay" $path) $observed "$cut deterministic replay"
    } finally {
      [IO.File]::WriteAllBytes($path, $original)
      [IO.File]::SetLastWriteTimeUtc($path, $originalTime)
      $restored = Get-RebaseHistoryIdentity $path | ConvertTo-Json -Compress
      Write-Output "RESTORE cut=$cut identity=$restored"
      Assert-RebaseHistory ($restored -ceq $originalIdentityJson) "$cut exact original bytes/hash/length/mtime restored"
    }
    Assert-RebaseHistoryWhole (Invoke-RebaseHistoryNative "$cut-restored-full" $path) $full "$cut restored full output"
    Assert-RebaseHistoryWhole (Invoke-RebaseHistoryNative "$cut-restored-replay" $path) $full "$cut restored deterministic replay"
  }
  $later = '{"id":"appended-epsilon","instant":"2026-11-07T00:00:00Z","nested":{"map":{"later":null},"array":[5,"05",null,{"final":[true,{}]}]},"empty":[]}'
  [IO.File]::AppendAllText($path, $later + "`n", $utf8)
  $appended = [IO.File]::ReadAllBytes($path)
  Assert-RebaseHistory ($appended.Length -eq $original.Length + $utf8.GetByteCount($later + "`n")) 'append adds exactly one complete LF record'
  $prefixBytes = [byte[]]::new($original.Length)
  [Array]::Copy($appended, $prefixBytes, $prefixBytes.Length)
  Assert-RebaseHistory ([Convert]::ToBase64String($prefixBytes) -ceq [Convert]::ToBase64String($original)) 'append preserves every original byte'
  Write-RebaseHistorySmall $small @($raw + $later)
  $updatedOracle = Invoke-RebaseHistoryNative 'append-small-complete' $small
  $updatedIndependent = ConvertFrom-Json -InputObject ('[' + (@($raw + $later) -join ',') + ']') -DateKind String -Depth 100
  Assert-RebaseHistory ($updatedOracle.resultJson -ceq (ConvertTo-Json -InputObject $updatedIndependent -Depth 100 -Compress)) 'updated small oracle equals entire independent appended sequence'
  $updated = Invoke-RebaseHistoryNative 'append-full' $path
  Assert-RebaseHistoryWhole $updated $updatedOracle 'append full versus updated small complete'
  Assert-RebaseHistory ($updated.resultJson -cne $full.resultJson -and $updated.result.Count -eq $full.result.Count + 1) 'append changes whole output with one distinct later object'
  Assert-RebaseHistoryWhole (Invoke-RebaseHistoryNative 'append-replay' $path) $updated 'deterministic append replay'
  $sourceAfter = ConvertTo-Json -InputObject @($sourcePaths | ForEach-Object { Get-RebaseHistoryIdentity $_ }) -Depth 10 -Compress
  Assert-RebaseHistory ($sourceBefore -ceq $sourceAfter) 'all source identities preserved across qualification'
  Write-Output "PASS literalRow=22 checks=$checks nativeCalls=$nativeCalls physicalLines=$physicalLines bytes=$($original.Length) sparseSyntheticGeometry=true NOT_RICH_EVENT_OR_MEMORY_ENVELOPE_PROOF"
} finally {
  $fullRoot = [IO.Path]::GetFullPath($root)
  if ((Split-Path -Parent $fullRoot).TrimEnd('\', '/') -cne $temporary -or
    (Split-Path -Leaf $fullRoot) -cnotmatch '^rebase-lines-history-[a-f0-9]{32}$') { throw 'unsafe private fixture cleanup' }
  if (Test-Path -LiteralPath $fullRoot) {
    $reparsePoints = @(Get-Item -LiteralPath $fullRoot -Force; Get-ChildItem -LiteralPath $fullRoot -Recurse -Force) |
      Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }
    if (@($reparsePoints).Count) { throw 'private fixture cleanup refuses reparse points' }
    Remove-Item -LiteralPath $fullRoot -Recurse -Force
  }
  Assert-RebaseHistory (-not (Test-Path -LiteralPath $fullRoot)) 'private guarded cleanup removed owned root'
  Write-Output 'CLEANUP privateGuidRootRemoved=True'
}
