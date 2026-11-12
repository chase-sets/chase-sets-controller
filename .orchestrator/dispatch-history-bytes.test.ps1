[CmdletBinding()]
param([switch]$Native)
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false, $true)
$checks = 0
function Check-BytesHistory([bool]$Value, [string]$Message) {
  $script:checks++
  if (-not $Value) { throw "ASSERT: $Message" }
}
function Write-BytesPacket([string]$Kind, $Value) {
  Write-Output ($Kind + ' ' + (ConvertTo-Json -InputObject $Value -Depth 20 -Compress -EscapeHandling EscapeNonAscii))
}
function Get-BytesHash([byte[]]$Bytes) {
  [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}
function Get-BytesIdentity([byte[]]$Bytes) {
  [ordered]@{ bytes = $Bytes.Length; sha256 = Get-BytesHash $Bytes }
}
function Get-BytesFileIdentity([string]$Path) {
  $f = Get-Item -LiteralPath $Path
  [ordered]@{ path = $f.FullName; bytes = $f.Length; mtimeUtcTicks = $f.LastWriteTimeUtc.Ticks
    sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
}
$sourcePaths = @($PSCommandPath, (Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1'),
  (Join-Path $PSScriptRoot 'contracts/dispatch-history-callers.json'))
function Get-BytesSourceIdentities {
  ConvertTo-Json -InputObject @($sourcePaths | ForEach-Object { Get-BytesFileIdentity $_ }) -Compress
}
function Assert-WholeBytes([byte[]]$Expected, $Actual, [string]$Label) {
  Check-BytesHistory ($Actual -is [byte[]]) "$Label actual return is byte[], not enumerated scalars"
  $equal = [Linq.Enumerable]::SequenceEqual[byte]($Expected, $Actual)
  Write-BytesPacket 'BYTE_EQUALITY' ([ordered]@{ label = $Label; expected = Get-BytesIdentity $Expected
    actual = Get-BytesIdentity $Actual; wholeArrayEqual = $equal
    equality = 'System.Linq.Enumerable.SequenceEqual<byte>'; comparedBytes = $Expected.Length })
  Check-BytesHistory $equal "$Label entire returned byte array equals independently constructed bytes"
}

# Keep full native streams, including failures, without turning byte[] into JSON integers.
if (-not $Native) {
  $before = Get-BytesSourceIdentities
  $info = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })))
  $info.UseShellExecute = $false; $info.CreateNoWindow = $true
  $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
  $info.StandardOutputEncoding = $utf8; $info.StandardErrorEncoding = $utf8
  foreach ($arg in @('-NoProfile', '-NonInteractive', '-File', $PSCommandPath, '-Native')) { [void]$info.ArgumentList.Add($arg) }
  $start = [datetimeoffset]::UtcNow.ToString('o'); $watch = [Diagnostics.Stopwatch]::StartNew()
  $process = $null; $out = ''; $err = ''; $code = $null
  try {
    $process = [Diagnostics.Process]::Start($info)
    $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $out = $stdout.GetAwaiter().GetResult(); $err = $stderr.GetAwaiter().GetResult()
    $code = $process.ExitCode
  } finally {
    $watch.Stop()
    if ($process) { $process.Dispose() }
    $after = Get-BytesSourceIdentities
    Write-BytesPacket 'NATIVE' ([ordered]@{ executable = $info.FileName; arguments = @($info.ArgumentList)
      startedUtc = $start; endedUtc = [datetimeoffset]::UtcNow.ToString('o'); elapsedMs = $watch.Elapsed.TotalMilliseconds
      exitCode = $code; inputsBefore = $before; inputsAfter = $after; stdout = $out; stderr = $err })
  }
  Check-BytesHistory ($before -ceq $after) 'native child preserved all source bytes/hash/length/mtime'
  Check-BytesHistory ($code -eq 0 -and $err -ceq '') "native byte regression failed: exit=$code stderr=$err"
  Check-BytesHistory ($out -match '(?m)^PASS literalRow=13 ') 'native child completed all byte assertions'
  Write-Output 'PASS dispatch bytes literal row13 nativeExit=0; sparse primitive byte-wrapper coverage only, NOT downstream/all53/rich/memory/security/battery/release qualification'
  return
}

$sourceBefore = Get-BytesSourceIdentities
$readerPath = Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1'
$tokens = $null; $errors = $null
$sourceAst = [Management.Automation.Language.Parser]::ParseFile($readerPath, [ref]$tokens, [ref]$errors)
Check-BytesHistory ($errors.Count -eq 0) 'unchanged actual reader source parses'
$module = Import-Module $readerPath -Force -DisableNameChecking -PassThru
$bindings = @()
foreach ($name in @('Read-DispatchLedgerBytes', 'Read-DispatchLedgerSnapshot')) {
  $definitions = @($sourceAst.FindAll({param($n)
    $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name
  }, $true))
  Check-BytesHistory ($definitions.Count -eq 1) "one complete checkout function AST: $name"
  $command = Get-Command "dispatch-ledger-reader\$name" -CommandType Function
  Check-BytesHistory ($command.Module.Path -ceq $module.Path -and
    [IO.Path]::GetFullPath($module.Path) -ceq [IO.Path]::GetFullPath($readerPath)) "actual module boundary: $name"
  Check-BytesHistory ($command.ScriptBlock.Ast.Extent.Text -ceq $definitions[0].Extent.Text) "complete loaded/source AST equality: $name"
  $bindings += [ordered]@{ name = $name; sourcePath = $readerPath; completeAstEqual = $true
    sourceAstSha256 = Get-BytesHash ($utf8.GetBytes($definitions[0].Extent.Text))
    loadedAstSha256 = Get-BytesHash ($utf8.GetBytes($command.ScriptBlock.Ast.Extent.Text)) }
  if ($name -ceq 'Read-DispatchLedgerBytes') { $wrapperAst = $definitions[0] }
}
$calls = @($wrapperAst.Body.FindAll({param($n)
  $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Read-DispatchLedgerSnapshot'
}, $true))
Check-BytesHistory ($calls.Count -eq 1 -and
  $calls[0].Extent.Text -ceq 'Read-DispatchLedgerSnapshot -Path $Path -RequireTerminated:$RequireTerminated') 'literal row13 actual snapshot dependency call'
$callTokens = $null; $callErrors = $null
[void][Management.Automation.Language.Parser]::ParseInput($calls[0].Extent.Text, [ref]$callTokens, [ref]$callErrors)
$shape = @($callTokens | Where-Object { $_.Kind -notin @('NewLine', 'LineContinuation', 'Comment', 'EndOfInput') } |
  ForEach-Object { "$($_.Kind):$($_.Text)" }) -join "`n"
$callSha = Get-BytesHash ($utf8.GetBytes($shape))
$manifest = [IO.File]::ReadAllText($sourcePaths[2]) | ConvertFrom-Json
$row = $manifest.rows[12]
$expectedRow = [ordered]@{ path = '.orchestrator/dispatch-ledger-reader.psm1'; scope = 'Read-DispatchLedgerBytes'
  api = 'read-dispatchledgersnapshot'; ordinal = 1; mode = 'one-pass-snapshot'; projection = 'captured-bytes+lines'
  peakEnvelope = 'captured-history'; callSha256 = '21cef66d6825258e0914d4ce072b536e86652114687e8dad175e5218e049e91a' }
Check-BytesHistory ($manifest.schemaVersion -ceq 'dispatch-history-callers/v1' -and
  @($row.PSObject.Properties).Count -eq $expectedRow.Count) 'literal manifest index12 row13 schema and full tuple fields'
foreach ($key in $expectedRow.Keys) {
  Check-BytesHistory ($row.$key -ceq $expectedRow[$key]) "literal row13 tuple: $key"
}
Check-BytesHistory ($callErrors.Count -eq 0 -and $callSha -ceq $expectedRow.callSha256) 'row13 full call token SHA256'
Write-BytesPacket 'BINDING' ([ordered]@{ literalRow = 13; manifestIndex = 12; row = $row
  literalCall = $calls[0].Extent.Text; callSha256 = $callSha; functions = $bindings; inputs = $sourceBefore
  invocation = 'Read-DispatchLedgerBytes -Path $path (only; default arguments)' })

$temporary = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
$root = Join-Path $temporary ('dispatch-bytes-history-' + [guid]::NewGuid().ToString('N'))
$path = Join-Path $root 'dispatch-log.jsonl'
try {
  [void][IO.Directory]::CreateDirectory($root)
  $first = '{"ts":"2026-01-01T00:00:00Z","kind":"dispatch","lane":"ordinary-first","issue":126,"note":"beginning-' + [char]0x03bb + '"}' + "`n"
  $last = '{"ts":"2026-11-01T00:00:00Z","kind":"dispatch","lane":"ordinary-last","issue":126,"note":"ending-' + [char]0x00e9 + '"}' + "`n"
  $later = '{"ts":"2026-11-07T00:00:00Z","kind":"dispatch","lane":"ordinary-appended","issue":126,"note":"later-' + [char]0x96ea + '"}' + "`n"
  $firstBytes = $utf8.GetBytes($first); $lastBytes = $utf8.GetBytes($last); $laterBytes = $utf8.GetBytes($later)
  $fillerRows = 53000; $spaces = 640; $filler = $utf8.GetBytes((' ' * $spaces) + "`n")
  $original = [byte[]]::new($firstBytes.Length + $fillerRows * $filler.Length + $lastBytes.Length)
  [Buffer]::BlockCopy($firstBytes, 0, $original, 0, $firstBytes.Length)
  for ($i = 0; $i -lt $fillerRows; $i++) {
    [Buffer]::BlockCopy($filler, 0, $original, ($firstBytes.Length + $i * $filler.Length), $filler.Length)
  }
  [Buffer]::BlockCopy($lastBytes, 0, $original, ($original.Length - $lastBytes.Length), $lastBytes.Length)
  $lf = [Collections.Generic.List[int]]::new()
  $offset = [Array]::IndexOf($original, [byte]10)
  while ($offset -ge 0) {
    $lf.Add($offset)
    $offset = [Array]::IndexOf($original, [byte]10, ($offset + 1))
  }
  Check-BytesHistory ($lf.Count -eq 53002 -and $lf.Count -gt 50000 -and $original.Length -gt 33554432 -and
    $lf[$lf.Count - 1] -eq $original.Length - 1 -and [Array]::IndexOf($original, [byte]13) -eq -1) 'physical full history exceeds both cliffs, UTF8 with LF-only complete lines'
  [void]($first.TrimEnd("`n") | ConvertFrom-Json)
  [void]($last.TrimEnd("`n") | ConvertFrom-Json)
  [void]($later.TrimEnd("`n") | ConvertFrom-Json)
  [IO.File]::WriteAllBytes($path, $original)
  $originalIdentity = Get-BytesFileIdentity $path
  $originalIdentityJson = ConvertTo-Json -InputObject $originalIdentity -Compress
  $originalTime = [IO.File]::GetLastWriteTimeUtc($path)
  Write-BytesPacket 'RECIPE' ([ordered]@{ encoding = 'strict UTF8 without BOM'; firstLine = $first; lastLine = $last
    appendLine = $later; fillerRows = $fillerRows; fillerSpaceBytes = $spaces; fillerTerminatorByte = 10
    concatenation = 'UTF8(firstLine) + 53000 * (640 ASCII spaces + LF) + UTF8(lastLine)'
    fullPhysicalLfLines = $lf.Count; meaningfulOriginalRecords = 2; original = $originalIdentity
    appendBytes = Get-BytesIdentity $laterBytes; coverage = 'sparse primitive byte-wrapper only' })
  Assert-WholeBytes $original ([IO.File]::ReadAllBytes($path)) 'independent-original-on-disk'
  $frozen = Read-DispatchLedgerBytes -Path $path
  Assert-WholeBytes $original $frozen 'full-original-default-wrapper'
  $replay = Read-DispatchLedgerBytes -Path $path
  Assert-WholeBytes $original $replay 'full-original-default-replay'

  $suffixStart = $lf[$lf.Count - 50000 - 1] + 1
  $prefixLength = [Array]::LastIndexOf($original, [byte]10, 33554431, 33554432) + 1
  Check-BytesHistory ($prefixLength -gt 0 -and $prefixLength -le 33554432 -and
    [Array]::IndexOf($original, [byte]10, $prefixLength) + 1 -gt 33554432) 'maximal whole-line original prefix at 32MiB'
  foreach ($cut in @('last-50000-LF', 'maximal-32MiB-prefix')) {
    $start = if ($cut -ceq 'last-50000-LF') { $suffixStart } else { 0 }
    $length = if ($cut -ceq 'last-50000-LF') { $original.Length - $start } else { $prefixLength }
    $cutBytes = [byte[]]::new($length)
    [Buffer]::BlockCopy($original, $start, $cutBytes, 0, $length)
    $cutLines = @($lf | Where-Object { $_ -ge $start -and $_ -lt ($start + $length) }).Count
    Check-BytesHistory ($cutBytes[-1] -eq 10 -and $length -lt $original.Length -and
      ($cut -cne 'last-50000-LF' -or $cutLines -eq 50000)) "$cut exact original slice geometry"
    try {
      [IO.File]::WriteAllBytes($path, $cutBytes)
      Write-BytesPacket 'CUT' ([ordered]@{ name = $cut; originalOffset = $start; length = $length
        physicalLfLines = $cutLines; expected = Get-BytesIdentity $cutBytes; file = Get-BytesFileIdentity $path })
      Assert-WholeBytes $cutBytes ([IO.File]::ReadAllBytes($path)) "$cut-exact-original-slice-on-disk"
      $actualCut = Read-DispatchLedgerBytes -Path $path
      Assert-WholeBytes $cutBytes $actualCut "$cut-default-wrapper"
      $differs = -not [Linq.Enumerable]::SequenceEqual[byte]($original, $actualCut)
      Write-BytesPacket 'DIFFERENT_FROM_FULL' ([ordered]@{ label = $cut; wholeArrayDifferent = $differs })
      Check-BytesHistory $differs "$cut entire output differs from full history"
    } finally {
      [IO.File]::WriteAllBytes($path, $original)
      [IO.File]::SetLastWriteTimeUtc($path, $originalTime)
      $restored = Get-BytesFileIdentity $path
      Write-BytesPacket 'RESTORE' ([ordered]@{ after = $cut; file = $restored })
      Check-BytesHistory ((ConvertTo-Json -InputObject $restored -Compress) -ceq $originalIdentityJson) "$cut original bytes/hash/length/mtime restored"
      Assert-WholeBytes $original ([IO.File]::ReadAllBytes($path)) "$cut-restored-disk"
    }
    $restoredReturn = Read-DispatchLedgerBytes -Path $path
    Assert-WholeBytes $original $restoredReturn "$cut-restored-entire-default-return"
  }

  $appended = [byte[]]::new($original.Length + $laterBytes.Length)
  [Buffer]::BlockCopy($original, 0, $appended, 0, $original.Length)
  [Buffer]::BlockCopy($laterBytes, 0, $appended, $original.Length, $laterBytes.Length)
  for ($pass = 1; $pass -le 2; $pass++) {
    try {
      [IO.File]::AppendAllText($path, $later, $utf8)
      Write-BytesPacket 'APPEND' ([ordered]@{ pass = $pass; originalOffset = $original.Length
        appendedRecord = Get-BytesIdentity $laterBytes; expected = Get-BytesIdentity $appended
        file = Get-BytesFileIdentity $path; physicalLfLines = $lf.Count + 1 })
      Assert-WholeBytes $appended ([IO.File]::ReadAllBytes($path)) "append-$pass-independent-entire-disk"
      $updated = Read-DispatchLedgerBytes -Path $path
      Assert-WholeBytes $appended $updated "append-$pass-fresh-entire-default-return"
      Check-BytesHistory (-not [Linq.Enumerable]::SequenceEqual[byte]($original, $updated)) "append-$pass distinct full updated output"
      Assert-WholeBytes $original $frozen "append-$pass-previous-return-remains-frozen-same-process"
      $updatedReplay = Read-DispatchLedgerBytes -Path $path
      Assert-WholeBytes $appended $updatedReplay "append-$pass-deterministic-default-replay"
      Assert-WholeBytes $appended $updated "append-$pass-prior-appended-return-also-frozen"
    } finally {
      [IO.File]::WriteAllBytes($path, $original)
      [IO.File]::SetLastWriteTimeUtc($path, $originalTime)
      $restored = Get-BytesFileIdentity $path
      Write-BytesPacket 'RESTORE' ([ordered]@{ after = "append-$pass"; file = $restored })
      Check-BytesHistory ((ConvertTo-Json -InputObject $restored -Compress) -ceq $originalIdentityJson) "append-$pass original bytes/hash/length/mtime restored"
      Assert-WholeBytes $original ([IO.File]::ReadAllBytes($path)) "append-$pass-restored-entire-disk"
    }
    $restoredReturn = Read-DispatchLedgerBytes -Path $path
    Assert-WholeBytes $original $restoredReturn "append-$pass-restored-entire-default-return"
    Assert-WholeBytes $original $frozen "append-$pass-original-return-still-frozen-after-restore"
  }
  Check-BytesHistory ($sourceBefore -ceq (Get-BytesSourceIdentities)) 'native test preserved all source bytes/hash/length/mtime'
  Write-Output "PASS literalRow=13 checks=$checks physicalLfLines=$($lf.Count) fullBytes=$($original.Length) appendBytes=$($appended.Length); sparse primitive wrapper only, NOT downstream/all53/rich/memory/security/battery/release qualification"
} finally {
  $resolved = [IO.Path]::GetFullPath($root)
  if ((Split-Path -Parent $resolved).TrimEnd('\', '/') -cne $temporary -or
    (Split-Path -Leaf $resolved) -cnotmatch '^dispatch-bytes-history-[a-f0-9]{32}$') { throw 'unsafe owned fixture cleanup' }
  if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
  Check-BytesHistory (-not (Test-Path -LiteralPath $resolved)) 'owned GUID fixture removed'
  Write-Output 'CLEANUP privateGuidRootRemoved=True'
}
