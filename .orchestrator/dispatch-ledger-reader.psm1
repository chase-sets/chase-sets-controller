# Sole dispatch-history I/O owner. No dependency on reducers or query-ledgers:
# those entrypoints delegate here, including the installed PrefixHistory fold.
function Assert-NonDispatchLedgerPath {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Path)
  $leaf=([IO.Path]::GetFileName($Path) -split ':',2)[0].TrimEnd(' ','.')
  if ([string]::Equals($leaf,'dispatch-log.jsonl',[StringComparison]::OrdinalIgnoreCase)) {
    throw 'DISPATCH_LEDGER_OWNER_REQUIRED'
  }
}

function Get-NonDispatchLedgerPath {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Path)
  dispatch-ledger-reader\Assert-NonDispatchLedgerPath -Path $Path
  return $Path
}

function Open-DispatchLedgerReadStream([string]$Path) {
  return [IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
}

function Initialize-DispatchHistoryStream {
  if ('DispatchHistoryStreaming.ReaderV1' -as [type]) { return }
  $gate=[string]::Intern('DispatchHistoryStreaming.ReaderV1 initialization')
  [Threading.Monitor]::Enter($gate)
  try {
  if ('DispatchHistoryStreaming.ReaderV1' -as [type]) { return }
  Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.Security.Cryptography;
namespace DispatchHistoryStreaming {
  // The owner supplies its already-open shared stream. This class owns no path I/O.
  public sealed class ReaderV1 : IDisposable {
    readonly Stream stream;
    readonly long length, prefixLength;
    readonly byte[] buffer = new byte[65536];
    readonly MemoryStream pending = new MemoryStream();
    readonly Queue<string> lines = new Queue<string>();
    readonly IncrementalHash hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
    readonly IncrementalHash prefixHash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
    readonly UTF8Encoding utf8 = new UTF8Encoding(false, true);
    bool finished, first = true;
    public long BytesRead { get; private set; }
    public long ReadOperations { get; private set; }
    public long SnapshotLength { get; private set; }
    public int SnapshotLines { get; private set; }
    public int PrefixLines { get; private set; }
    public bool PrefixTerminated { get; private set; }
    public bool PartialTrailingRow { get; private set; }
    public bool DecodeFailed { get; private set; }
    public string SnapshotHash { get; private set; }
    public string PrefixHash { get; private set; }
    public ReaderV1(Stream stream, long length, long prefixLength) {
      this.stream = stream; this.length = length; this.prefixLength = prefixLength;
      PrefixTerminated = prefixLength == 0;
    }
    public string ReadLine() {
      while (lines.Count == 0 && !finished) {
        if (BytesRead == length) { Finish(); break; }
        int n = stream.Read(buffer, 0, (int)Math.Min(buffer.Length, length - BytesRead));
        ReadOperations++;
        if (n == 0) throw new EndOfStreamException("history shrank during streaming snapshot");
        int prefixBytes = (int)Math.Max(0, Math.Min(n, prefixLength - BytesRead));
        if (prefixBytes > 0) prefixHash.AppendData(buffer, 0, prefixBytes);
        if (prefixLength > BytesRead && prefixLength <= BytesRead + n)
          PrefixTerminated = buffer[(int)(prefixLength - BytesRead - 1)] == 10;
        BytesRead += n;
        int lastLf = Array.LastIndexOf(buffer, (byte)10, n - 1, n);
        if (lastLf >= 0) {
          pending.Write(buffer, 0, lastLf + 1);
          byte[] committed = pending.ToArray(); pending.SetLength(0);
          hash.AppendData(committed);
          long previousLength = SnapshotLength;
          SnapshotLength += committed.Length;
          string text;
          try { text = utf8.GetString(committed); }
          catch (DecoderFallbackException) {
            // Finish the captured byte pass before choosing the failure reason:
            // strict unterminated-tail refusal precedes UTF-8 decoding errors.
            DecodeFailed = true;
            pending.Write(buffer, lastLf + 1, n - lastLf - 1);
            continue;
          }
          if (first && text.Length > 0 && text[0] == '\ufeff') text = text.Substring(1);
          first = false;
          using (var reader = new StringReader(text)) {
            string line;
            long physicalOffset = previousLength;
            // Prefix boundaries are LF offsets. Count CR/CRLF rows using the
            // same StringReader semantics as the existing snapshot API.
            int charOffset = 0;
            while ((line = reader.ReadLine()) != null) {
              lines.Enqueue(line); SnapshotLines++;
              int end = charOffset;
              while (end < text.Length && text[end] != '\r' && text[end] != '\n') end++;
              if (end < text.Length && text[end++] == '\r' && end < text.Length && text[end] == '\n') end++;
              physicalOffset += utf8.GetByteCount(text.Substring(charOffset, end - charOffset));
              if (previousLength == 0 && charOffset == 0 && committed.Length >= 3 &&
                  committed[0] == 239 && committed[1] == 187 && committed[2] == 191) physicalOffset += 3;
              if (physicalOffset <= prefixLength) PrefixLines++;
              charOffset = end;
            }
          }
          pending.Write(buffer, lastLf + 1, n - lastLf - 1);
        } else pending.Write(buffer, 0, n);
      }
      return lines.Count == 0 ? null : lines.Dequeue();
    }
    void Finish() {
      if (stream.Length < length) throw new IOException("history shrank during streaming snapshot");
      PartialTrailingRow = pending.Length != 0;
      SnapshotHash = Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
      PrefixHash = Convert.ToHexString(prefixHash.GetHashAndReset()).ToLowerInvariant();
      finished = true;
    }
    public void Dispose() { pending.Dispose(); hash.Dispose(); prefixHash.Dispose(); }
  }
}
'@
  } finally { [Threading.Monitor]::Exit($gate) }
}

function Read-DispatchLedgerSnapshot {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Path, [long]$MaxBytes = [long]::MaxValue,
    [switch]$RequireTerminated,[switch]$IncludeUnterminated)
  if ($RequireTerminated -and $IncludeUnterminated) { throw 'INCOMPATIBLE_HISTORY_TERMINATION_OPTIONS' }
  $audit = [ordered]@{pathStatus='unknown';bytes=0;rows=0;parsedRows=0;malformedRows=0;truncated=$false;malformedLineNumbers=@()}
  $result = [pscustomobject]@{complete=$false;reason='HISTORY_UNREADABLE';audit=$audit;bytes=[byte[]]@();lines=[string[]]@()
    snapshotLength=0L;snapshotLines=0;snapshotHash=$null;cursor=0L;partialTrailingRow=$false}
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    $audit.pathStatus='missing';$result.reason='HISTORY_MISSING';return $result
  }
  try {
    $stream=Open-DispatchLedgerReadStream -Path $Path
    try {
      $length=$stream.Length
      $audit.bytes=$length
      if ($length -gt $MaxBytes) {
        $audit.pathStatus='oversize';$audit.truncated=$true;$result.reason='HISTORY_TRUNCATED';return $result
      }
      $bytes=[byte[]]::new($length)
      $stream.ReadExactly($bytes,0,$bytes.Length)
      if ($stream.Length -lt $length) { throw 'history shrank during snapshot' }
      $completeLength=$length
      while ($completeLength -gt 0 -and $bytes[$completeLength-1] -ne 10) { $completeLength-- }
      $result.partialTrailingRow=$completeLength -ne $length
      if ($RequireTerminated -and $result.partialTrailingRow) {
        $audit.pathStatus='unterminated';$result.reason='HISTORY_UNTERMINATED_OR_MOVED';return $result
      }
      # Appends after captured EOF are harmless; a changed complete boundary is not.
      if ($completeLength -gt 0) {
        [void]$stream.Seek($completeLength-1,[IO.SeekOrigin]::Begin)
        if ($stream.ReadByte() -ne 10) { throw 'history boundary changed' }
      }
    } finally { $stream.Dispose() }
    $retainedLength=if ($IncludeUnterminated) { $length } else { $completeLength }
    if ($retainedLength -ne $length) { [Array]::Resize([ref]$bytes,[int]$retainedLength) }
    # Authority reads retain only the LF-committed prefix. Explicit raw-line
    # telemetry may retain captured EOF, still requiring strictly valid UTF-8.
    $text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes)
    if ($text.StartsWith([string][char]0xfeff,[StringComparison]::Ordinal)) { $text=$text.Substring(1) }
    # Preserve StreamReader's row/raw/line-number semantics, including CRLF
    # and isolated CR, without a second file open or a temporary parser file.
    $lineList=[Collections.Generic.List[string]]::new()
    $memory=[IO.StringReader]::new($text)
    try { while ($null -ne ($line=$memory.ReadLine())) { $lineList.Add($line) } }
    finally { $memory.Dispose() }
    $lines=$lineList.ToArray()
    $result.bytes=$bytes;$result.lines=[string[]]@($lines)
    $result.snapshotLength=$retainedLength;$result.cursor=$retainedLength;$result.snapshotLines=@($lines).Count
    $result.snapshotHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    $audit.pathStatus='ok';$result.complete=$true;$result.reason='HISTORY_COMPLETE'
  } catch { $audit.pathStatus='unreadable' }
  return $result
}

function Read-DispatchLedgerLines {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Path,[switch]$RequireTerminated,[switch]$IncludeUnterminated)
  $snapshot=Read-DispatchLedgerSnapshot -Path $Path -RequireTerminated:$RequireTerminated -IncludeUnterminated:$IncludeUnterminated
  if (-not $snapshot.complete) { throw "dispatch ledger refused: $($snapshot.reason)" }
  return $snapshot.lines
}

function Read-DispatchLedgerBytes {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Path,[switch]$RequireTerminated)
  $snapshot=Read-DispatchLedgerSnapshot -Path $Path -RequireTerminated:$RequireTerminated
  if (-not $snapshot.complete) { throw "dispatch ledger refused: $($snapshot.reason)" }
  return ,$snapshot.bytes
}

function Read-DispatchCountHistory {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Path,$PrefixHistory=$null,[int]$MaxRows=[int]::MaxValue,
    [long]$MaxBytes=[long]::MaxValue,[switch]$RequireTerminated,[ref]$ReadMetrics,
    [ValidateRange(0,[long]::MaxValue)][long]$MaxDeltaBytes=[long]::MaxValue,
    [ValidateRange(0,[int]::MaxValue)][int]$MaxDeltaRows=[int]::MaxValue)
  if ($null -ne $PrefixHistory -and -not $PrefixHistory.complete) { return $PrefixHistory }
  $audit=[ordered]@{pathStatus='unknown';bytes=0;rows=0;parsedRows=0;malformedRows=0;truncated=$false;malformedLineNumbers=@()}
  $metrics=[ordered]@{readPasses=0;bytesRead=0L;readOperations=0L;boundaryProbes=0;tailParsedRows=0;prefixRows=0;capturedLength=0L;prefixStatus='none'}
  $rows=[Collections.Generic.List[object]]::new()
  $reason='HISTORY_UNREADABLE';$complete=$false
  $snapshotLength=0L;$snapshotLines=0;$snapshotHash=$null;$partial=$false
  $stream=$null;$reader=$null
  try {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
      $audit.pathStatus='missing';$reason='HISTORY_MISSING'
    } else {
      Initialize-DispatchHistoryStream
      $stream=Open-DispatchLedgerReadStream -Path $Path
      $length=$stream.Length;$audit.bytes=$length;$metrics.capturedLength=$length
      if ($length -gt $MaxBytes) {
        $audit.pathStatus='oversize';$audit.truncated=$true;$reason='HISTORY_TRUNCATED'
      } else {
        $prefixLength=0L;$prefixLines=0;$prefixValid=$true;$deltaTruncated=$false
        if ($null -ne $PrefixHistory) {
          $metrics.prefixStatus='pending'
          $prefixLength=[long]$PrefixHistory.snapshotLength;$prefixLines=[int]$PrefixHistory.snapshotLines
          $prefixValid=$prefixLength -ge 0 -and $prefixLength -le $length -and $prefixLines -ge 0
          if ($prefixLength -gt $length) { $metrics.prefixStatus='rewound' }
          $deltaTruncated=$prefixValid -and ($length-$prefixLength) -gt $MaxDeltaBytes
          if ($deltaTruncated) { $audit.truncated=$true }
          if ($prefixValid) {
            foreach ($row in $PrefixHistory.rows) { $rows.Add($row) }
            $audit.rows=$PrefixHistory.audit.rows;$audit.parsedRows=$PrefixHistory.audit.parsedRows
            $metrics.prefixRows=$PrefixHistory.audit.parsedRows
          } else { $prefixLength=0L;$prefixLines=0 }
        }
        $reader=[DispatchHistoryStreaming.ReaderV1]::new($stream,$length,$prefixLength)
        $metrics.readPasses=1
        $lineNumber=0;$prefixRowIndex=0
        while ($null -ne ($line=$reader.ReadLine())) {
          $lineNumber++
          if ($lineNumber -gt $MaxRows) { $audit.truncated=$true }
          if ($lineNumber -le $prefixLines) {
            if ($prefixValid -and $null -ne $PrefixHistory) {
              if (-not [string]::IsNullOrWhiteSpace($line)) {
                if ($prefixRowIndex -ge $rows.Count) { $prefixValid=$false }
                else {
                  $cached=$rows[$prefixRowIndex]
                  $rawBytes=[Text.UTF8Encoding]::new($false).GetBytes($line)
                  $rawHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($rawBytes)).ToLowerInvariant()
                  if ($cached.line -ne $lineNumber -or $cached.raw -cne $line -or
                      $cached.byteLength -ne $rawBytes.Length -or $cached.rawSha256 -cne $rawHash) { $prefixValid=$false }
                }
                $prefixRowIndex++
              } elseif ($prefixRowIndex -lt $rows.Count -and $rows[$prefixRowIndex].line -le $lineNumber) { $prefixValid=$false }
            }
            continue
          }
          if ($lineNumber -gt $MaxRows) { continue }
          if ($null -ne $PrefixHistory -and ($deltaTruncated -or -not $prefixValid -or
              ([long]$lineNumber-$prefixLines) -gt $MaxDeltaRows)) { $audit.truncated=$true;continue }
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $audit.rows++
        try {
          $options=[System.Text.Json.JsonDocumentOptions]::new();$options.MaxDepth=1024
          $document=[System.Text.Json.JsonDocument]::Parse($line,$options)
          try {
            $pending=[Collections.Generic.Stack[System.Text.Json.JsonElement]]::new();$pending.Push($document.RootElement)
            while ($pending.Count) {
              $element=$pending.Pop()
              if ($element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
                $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                foreach ($property in $element.EnumerateObject()) {
                  if (-not $names.Add($property.Name)) { throw 'Duplicate decoded JSON property name' }
                  $pending.Push($property.Value)
                }
              } elseif ($element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
                foreach ($item in $element.EnumerateArray()) { $pending.Push($item) }
              }
            }
          } finally { $document.Dispose() }
          $row=$line | ConvertFrom-Json -DateKind String -ErrorAction Stop
          $rawBytes=[Text.UTF8Encoding]::new($false).GetBytes($line)
          $rows.Add([pscustomobject][ordered]@{line=$lineNumber;raw=$line;byteLength=$rawBytes.Length
            rawSha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($rawBytes)).ToLowerInvariant();value=$row})
          $audit.parsedRows++
          $metrics.tailParsedRows++
        } catch { $audit.malformedRows++;$audit.malformedLineNumbers+= $lineNumber }
        }
        $snapshotLength=$reader.SnapshotLength;$snapshotLines=$reader.SnapshotLines
        $snapshotHash=$reader.SnapshotHash;$partial=$reader.PartialTrailingRow
        $metrics.bytesRead=$reader.BytesRead;$metrics.readOperations=$reader.ReadOperations
        $audit.pathStatus=if ($audit.truncated) {'truncated'} elseif ($audit.malformedRows) {'malformed'} else {'ok'}
        $complete=$true;$reason='HISTORY_COMPLETE'
        $prefixByteMismatch=$null -ne $PrefixHistory -and (
          $reader.PrefixHash -cne $PrefixHistory.snapshotHash -or -not $reader.PrefixTerminated)
        $prefixMismatch=$null -ne $PrefixHistory -and (-not $prefixValid -or
          $prefixRowIndex -ne @($PrefixHistory.rows).Count -or
          $prefixByteMismatch -or $reader.PrefixLines -ne $prefixLines)
        if ($null -ne $PrefixHistory -and $metrics.prefixStatus -cne 'rewound') {
          # A later invalid UTF-8 row can suppress decoded rows from the same
          # block. Missing decoded prefix rows then prove neither binding nor
          # corruption; only captured raw bytes can prove a mismatch here.
          $metrics.prefixStatus=if ($reader.DecodeFailed -and -not $prefixByteMismatch) {'unverified'}
            elseif ($prefixMismatch) {'digest-mismatch'} else {'valid'}
        }
        if ($RequireTerminated -and $partial) {
          $complete=$false;$reason='HISTORY_UNTERMINATED_OR_MOVED';$audit.pathStatus='unterminated'
          $rows.Clear();$audit.rows=0;$audit.parsedRows=0;$audit.malformedRows=0;$audit.malformedLineNumbers=@()
          $snapshotLength=0L;$snapshotLines=0;$snapshotHash=$null
        }
        else {
          # Preserve the original single committed-boundary probe, not a second
          # scan. Appends beyond captured EOF still do not affect this snapshot.
          if ($snapshotLength -gt 0) {
            [void]$stream.Seek($snapshotLength-1,[IO.SeekOrigin]::Begin)
            $metrics.boundaryProbes++
            if ($stream.ReadByte() -ne 10) { throw 'history boundary changed' }
          }
          if ($reader.DecodeFailed) { throw 'history UTF8 invalid' }
          if ($prefixMismatch) {
            $complete=$false;$reason='HISTORY_UNTERMINATED_OR_MOVED';$audit.pathStatus='moved'
            $rows.Clear();$audit.rows=0;$audit.parsedRows=0;$audit.malformedRows=0;$audit.malformedLineNumbers=@();$audit.truncated=$false
          } else {
            if ($audit.truncated) { $complete=$false;$reason='HISTORY_TRUNCATED' }
            elseif ($audit.malformedRows) { $complete=$false;$reason='HISTORY_MALFORMED' }
          }
        }
      }
    }
  } catch {
    $complete=$false
    $rows.Clear();$audit.rows=0;$audit.parsedRows=0;$audit.malformedRows=0;$audit.malformedLineNumbers=@()
    $snapshotLength=0L;$snapshotLines=0;$snapshotHash=$null
    if ($_.Exception.Message -ceq 'HISTORY_PREFIX_MOVED') { $reason='HISTORY_UNTERMINATED_OR_MOVED';$audit.pathStatus='moved' }
    else { $reason='HISTORY_UNREADABLE';$audit.pathStatus='unreadable' }
  } finally {
    if ($null -ne $ReadMetrics) { $ReadMetrics.Value=[pscustomobject]$metrics }
    if ($null -ne $reader) { $reader.Dispose() }
    if ($null -ne $stream) { $stream.Dispose() }
  }
  return [pscustomobject][ordered]@{complete=$complete;rows=$rows.ToArray();audit=$audit;reason=$reason
    snapshotLength=$snapshotLength;snapshotLines=$snapshotLines;snapshotHash=$snapshotHash
    cursor=$snapshotLength;partialTrailingRow=$partial}
}

function Get-NonDispatchLedgerStream {
  [CmdletBinding()]
  param([Parameter(Mandatory)][IO.FileStream]$Stream)
  # Read the exact CLR type and FileStream.Name for ordinary classification.
  # In-process code is trusted; these reads are not a security boundary.
  if ([object].GetMethod('GetType').Invoke($Stream,$null) -ne [IO.FileStream]) { throw 'NON_DISPATCH_FILE_STREAM_REQUIRED' }
  $path=[IO.FileStream].GetProperty('Name').GetValue($Stream)
  if (-not [IO.Path]::IsPathFullyQualified($path)) { throw 'NON_DISPATCH_FILE_STREAM_REQUIRED' }
  dispatch-ledger-reader\Assert-NonDispatchLedgerPath -Path $path
  return $Stream
}

function Get-LedgerMemoryBytes {
  [CmdletBinding()]
  param([Parameter(Mandatory)][IO.MemoryStream]$Stream)
  # Copy through CLR ToArray rather than an ordinary instance member override.
  # This is a correctness control, not a boundary against trusted in-process code.
  if ([object].GetMethod('GetType').Invoke($Stream,$null) -ne [IO.MemoryStream]) { throw 'NATIVE_MEMORY_STREAM_REQUIRED' }
  return ,([IO.MemoryStream].GetMethod('ToArray', [type[]]@()).Invoke($Stream,$null))
}

Export-ModuleMember -Function Assert-NonDispatchLedgerPath,Get-NonDispatchLedgerPath,Get-NonDispatchLedgerStream,Get-LedgerMemoryBytes,Read-DispatchLedgerSnapshot,Read-DispatchLedgerLines,Read-DispatchLedgerBytes,Read-DispatchCountHistory
