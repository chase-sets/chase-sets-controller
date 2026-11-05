# Sole dispatch-history I/O owner. No dependency on reducers or query-ledgers:
# those entrypoints delegate here, including the installed PrefixHistory fold.
function Read-DispatchLedgerSnapshot {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Path, [long]$MaxBytes = [long]::MaxValue,
    [switch]$RequireTerminated)
  $audit = [ordered]@{pathStatus='unknown';bytes=0;rows=0;parsedRows=0;malformedRows=0;truncated=$false;malformedLineNumbers=@()}
  $result = [pscustomobject]@{complete=$false;reason='HISTORY_UNREADABLE';audit=$audit;bytes=[byte[]]@();lines=[string[]]@()
    snapshotLength=0L;snapshotLines=0;snapshotHash=$null;cursor=0L;partialTrailingRow=$false}
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    $audit.pathStatus='missing';$result.reason='HISTORY_MISSING';return $result
  }
  try {
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
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
    if ($completeLength -ne $length) { [Array]::Resize([ref]$bytes,[int]$completeLength) }
    # Decode only the complete prefix, never half of a multi-byte UTF-8 scalar.
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
    $result.snapshotLength=$completeLength;$result.cursor=$completeLength;$result.snapshotLines=@($lines).Count
    $result.snapshotHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    $audit.pathStatus='ok';$result.complete=$true;$result.reason='HISTORY_COMPLETE'
  } catch { $audit.pathStatus='unreadable' }
  return $result
}

function Read-DispatchLedgerLines {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Path,[switch]$RequireTerminated)
  $snapshot=Read-DispatchLedgerSnapshot -Path $Path -RequireTerminated:$RequireTerminated
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
  param([Parameter(Mandatory)][string]$Path,$PrefixHistory=$null,[int]$MaxRows=50000,
    [long]$MaxBytes=33554432,[switch]$RequireTerminated)
  if ($null -ne $PrefixHistory -and -not $PrefixHistory.complete) { return $PrefixHistory }
  $snapshot=Read-DispatchLedgerSnapshot -Path $Path -MaxBytes $MaxBytes -RequireTerminated:$RequireTerminated
  $audit=$snapshot.audit
  $rows=[Collections.Generic.List[object]]::new()
  $reason=$snapshot.reason
  $complete=$snapshot.complete
  if ($complete) {
    $prefixLength=0L;$prefixLines=0
    if ($null -ne $PrefixHistory) {
      $prefixLength=[long]$PrefixHistory.snapshotLength;$prefixLines=[int]$PrefixHistory.snapshotLines
      $valid=$prefixLength -ge 0 -and $prefixLength -le $snapshot.snapshotLength -and $prefixLines -ge 0
      if ($valid) {
        $hash=[Security.Cryptography.SHA256]::Create()
        try { $prefixHash=[Convert]::ToHexString($hash.ComputeHash($snapshot.bytes,0,$prefixLength)).ToLowerInvariant() }
        finally { $hash.Dispose() }
        $valid=$prefixHash -ceq $PrefixHistory.snapshotHash -and ($prefixLength -eq 0 -or $snapshot.bytes[$prefixLength-1] -eq 10)
        $actualLines=0
        for ($i=0L;$i -lt $prefixLength;$i++) {
          if ($snapshot.bytes[$i] -eq 10) { $actualLines++ }
          elseif ($snapshot.bytes[$i] -eq 13) {
            $actualLines++
            if ($i+1 -lt $prefixLength -and $snapshot.bytes[$i+1] -eq 10) { $i++ }
          }
        }
        $valid=$valid -and $actualLines -eq $prefixLines
      }
      if (-not $valid) { $complete=$false;$reason='HISTORY_UNTERMINATED_OR_MOVED';$audit.pathStatus='moved' }
      else {
        foreach ($row in $PrefixHistory.rows) { $rows.Add($row) }
        $audit.rows=$PrefixHistory.audit.rows;$audit.parsedRows=$PrefixHistory.audit.parsedRows
      }
    }
    if ($complete -and $prefixLines -gt $MaxRows) { $complete=$false;$audit.truncated=$true;$reason='HISTORY_TRUNCATED' }
    if ($complete) {
      # Re-homed installed PrefixHistory fold: parse only the tail, retaining
      # global line identity, raw row hash and the existing byte/physical-row caps.
      for ($index=$prefixLines;$index -lt $snapshot.lines.Count;$index++) {
        $lineNumber=$index+1
        if ($lineNumber -gt $MaxRows) { $audit.truncated=$true;break }
        $line=$snapshot.lines[$index]
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
        } catch { $audit.malformedRows++;$audit.malformedLineNumbers+= $lineNumber }
      }
      $audit.pathStatus=if ($audit.truncated) {'truncated'} elseif ($audit.malformedRows) {'malformed'} else {'ok'}
      if ($audit.truncated) { $complete=$false;$reason='HISTORY_TRUNCATED' }
      elseif ($audit.malformedRows) { $complete=$false;$reason='HISTORY_MALFORMED' }
    }
  }
  return [pscustomobject][ordered]@{complete=$complete;rows=$rows.ToArray();audit=$audit;reason=$reason
    snapshotLength=$snapshot.snapshotLength;snapshotLines=$snapshot.snapshotLines;snapshotHash=$snapshot.snapshotHash
    cursor=$snapshot.cursor;partialTrailingRow=$snapshot.partialTrailingRow}
}

Export-ModuleMember -Function Read-DispatchLedgerSnapshot,Read-DispatchLedgerLines,Read-DispatchLedgerBytes,Read-DispatchCountHistory
