# Derived storage only. A structurally valid checkpoint is NOT ledger authority:
# the sole dispatch reader must still verify the canonical prefix hash and LF.
Import-Module (Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1') -Global -DisableNameChecking -ErrorAction Stop
$script:CheckpointSchema = 'dispatch-history-checkpoint/v1'
$script:CheckpointMutexWaitMs = 2000
# The owner accepts JSON depth 1024; stored metadata adds a few container levels.
$script:CheckpointMaxDepth = 1032

function ConvertTo-CheckpointJson {
  param([AllowNull()]$Value)
  # Use the command's serializer without its public -Depth 100 parameter ceiling.
  $context = [Microsoft.PowerShell.Commands.JsonObject+ConvertToJsonContext]::new($script:CheckpointMaxDepth,$false,$true)
  return [Microsoft.PowerShell.Commands.JsonObject]::ConvertToJson($Value,[ref]$context)
}

function ConvertFrom-CheckpointProjectionJson {
  param([string]$Raw)
  # Match the sole owner's PowerShell numeric and top-level array semantics.
  $value = $Raw | ConvertFrom-Json -DateKind String -ErrorAction Stop
  return ,$value
}

function Get-CheckpointIdentity {
  param([string]$Path)
  $full = [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path))
  if ($IsWindows) { $full = $full.ToUpperInvariant() }
  $key = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($full))).ToLowerInvariant()
  return @{sourcePath=$full; sourceKey=$key; path=(Join-Path ([IO.Path]::GetDirectoryName($full)) ".dispatch-history-checkpoint.d/$key.json")}
}

function Get-DispatchHistoryCheckpointPath {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Path)
  return (Get-CheckpointIdentity $Path).path
}

function Assert-CheckpointKeys {
  param([System.Text.Json.JsonElement]$Element,[string[]]$Keys)
  if ($Element.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { throw 'CHECKPOINT_OBJECT_REQUIRED' }
  $names = @($Element.EnumerateObject() | ForEach-Object Name)
  if ($names.Count -ne $Keys.Count) { throw 'CHECKPOINT_FIELDS_INVALID' }
  foreach ($key in $Keys) { if ($key -cnotin $names) { throw 'CHECKPOINT_FIELDS_INVALID' } }
}

function Assert-CheckpointJsonNames {
  param([System.Text.Json.JsonElement]$Element)
  $pending = [Collections.Generic.Stack[System.Text.Json.JsonElement]]::new()
  $pending.Push($Element)
  while ($pending.Count) {
    $next = $pending.Pop()
    if ($next.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
      # PowerShell property lookup is case-insensitive. Reject case aliases too.
      $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
      foreach ($property in $next.EnumerateObject()) {
        if (-not $names.Add($property.Name)) { throw 'CHECKPOINT_DUPLICATE_PROPERTY' }
        $pending.Push($property.Value)
      }
    } elseif ($next.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
      foreach ($item in $next.EnumerateArray()) { $pending.Push($item) }
    }
  }
}

function Get-CheckpointInteger {
  param([System.Text.Json.JsonElement]$Element)
  $number = 0L
  if ($Element.ValueKind -ne [System.Text.Json.JsonValueKind]::Number -or
      -not $Element.TryGetInt64([ref]$number) -or $number -lt 0) { throw 'CHECKPOINT_INTEGER_INVALID' }
  return $number
}

function Assert-CheckpointEnvelope {
  param([System.Text.Json.JsonElement]$Root,$Identity)
  Assert-CheckpointJsonNames $Root
  Assert-CheckpointKeys $Root @('schemaVersion','sourcePath','sourceKey','reducerVersion','contractVersion',
    'complete','snapshotLength','snapshotLines','snapshotHash','cursor','rows','audit','partialTrailingRow')
  foreach ($field in @('schemaVersion','sourcePath','sourceKey','reducerVersion','contractVersion','snapshotHash')) {
    if ($Root.GetProperty($field).ValueKind -ne [System.Text.Json.JsonValueKind]::String) { throw 'CHECKPOINT_STRING_INVALID' }
  }
  if ($Root.GetProperty('schemaVersion').GetString() -cne $script:CheckpointSchema) { return 'version' }
  if ($Root.GetProperty('sourcePath').GetString() -cne $Identity.sourcePath -or
      $Root.GetProperty('sourceKey').GetString() -cne $Identity.sourceKey) { throw 'CHECKPOINT_IDENTITY_MISMATCH' }
  foreach ($field in @('reducerVersion','contractVersion')) {
    if ([string]::IsNullOrWhiteSpace($Root.GetProperty($field).GetString())) { throw 'CHECKPOINT_VERSION_INVALID' }
  }
  if ($Root.GetProperty('complete').ValueKind -ne [System.Text.Json.JsonValueKind]::True) { throw 'CHECKPOINT_INCOMPLETE' }
  if ($Root.GetProperty('partialTrailingRow').ValueKind -notin @([System.Text.Json.JsonValueKind]::True,[System.Text.Json.JsonValueKind]::False)) { throw 'CHECKPOINT_BOOLEAN_INVALID' }
  $length = Get-CheckpointInteger ($Root.GetProperty('snapshotLength'))
  $cursor = Get-CheckpointInteger ($Root.GetProperty('cursor'))
  $lines = Get-CheckpointInteger ($Root.GetProperty('snapshotLines'))
  $hash = $Root.GetProperty('snapshotHash').GetString()
  if ($cursor -ne $length -or $hash -cnotmatch '^[a-f0-9]{64}$' -or $lines -gt $cursor -or
      (($cursor -eq 0) -ne ($lines -eq 0))) { throw 'CHECKPOINT_BOUNDARY_INVALID' }
  if ($cursor -eq 0 -and $hash -cne 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855') { throw 'CHECKPOINT_EMPTY_HASH_INVALID' }
  $rows = $Root.GetProperty('rows')
  if ($rows.ValueKind -ne [System.Text.Json.JsonValueKind]::Array) { throw 'CHECKPOINT_ROWS_INVALID' }
  $audit = $Root.GetProperty('audit')
  Assert-CheckpointKeys $audit @('pathStatus','bytes','rows','parsedRows','malformedRows','truncated','malformedLineNumbers')
  if ($audit.GetProperty('pathStatus').ValueKind -ne [System.Text.Json.JsonValueKind]::String -or
      $audit.GetProperty('pathStatus').GetString() -cne 'ok' -or
      $audit.GetProperty('truncated').ValueKind -ne [System.Text.Json.JsonValueKind]::False -or
      $audit.GetProperty('malformedLineNumbers').ValueKind -ne [System.Text.Json.JsonValueKind]::Array -or
      $audit.GetProperty('malformedLineNumbers').GetArrayLength() -ne 0) { throw 'CHECKPOINT_AUDIT_INVALID' }
  $bytes = Get-CheckpointInteger ($audit.GetProperty('bytes'))
  if ((Get-CheckpointInteger ($audit.GetProperty('rows'))) -ne $rows.GetArrayLength() -or
      (Get-CheckpointInteger ($audit.GetProperty('parsedRows'))) -ne $rows.GetArrayLength() -or
      (Get-CheckpointInteger ($audit.GetProperty('malformedRows'))) -ne 0 -or $bytes -lt $cursor -or
      ($Root.GetProperty('partialTrailingRow').GetBoolean() -ne ($bytes -gt $cursor))) { throw 'CHECKPOINT_AUDIT_INVALID' }
  $prior = 0L
  $remaining = $cursor - $lines
  $utf8 = [Text.UTF8Encoding]::new($false,$true)
  foreach ($row in $rows.EnumerateArray()) {
    Assert-CheckpointKeys $row @('line','raw','rawSha256','byteLength','value')
    $line = Get-CheckpointInteger ($row.GetProperty('line'))
    if ($line -le $prior -or $line -gt $lines) { throw 'CHECKPOINT_LINE_INVALID' }
    $prior = $line
    foreach ($field in @('raw','rawSha256')) {
      if ($row.GetProperty($field).ValueKind -ne [System.Text.Json.JsonValueKind]::String) { throw 'CHECKPOINT_ROW_STRING_INVALID' }
    }
    $raw = $row.GetProperty('raw').GetString()
    if ([string]::IsNullOrWhiteSpace($raw) -or $raw.Contains("`n") -or $raw.Contains("`r")) { throw 'CHECKPOINT_RAW_INVALID' }
    $rawBytes = $utf8.GetBytes($raw)
    $byteLength = Get-CheckpointInteger ($row.GetProperty('byteLength'))
    $rawHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($rawBytes)).ToLowerInvariant()
    if ($byteLength -ne $rawBytes.Length -or $row.GetProperty('rawSha256').GetString() -cne $rawHash -or
        $byteLength -gt $remaining) { throw 'CHECKPOINT_RAW_IDENTITY_INVALID' }
    $remaining -= $byteLength
    # Generic JSON equivalence checks the untrusted stored value against raw;
    # this is not a ledger read, line splitter, or dispatch reducer.
    $options = [System.Text.Json.JsonDocumentOptions]::new(); $options.MaxDepth = 1024
    $rawDocument = [System.Text.Json.JsonDocument]::Parse($raw,$options)
    try {
      Assert-CheckpointJsonNames $rawDocument.RootElement
      $normalized = ConvertFrom-CheckpointProjectionJson $raw
      $nodeOptions = [System.Text.Json.JsonDocumentOptions]::new(); $nodeOptions.MaxDepth = $script:CheckpointMaxDepth
      $rawNode = [System.Text.Json.Nodes.JsonNode]::Parse((ConvertTo-CheckpointJson $normalized),$null,$nodeOptions)
      $valueNode = [System.Text.Json.Nodes.JsonNode]::Parse($row.GetProperty('value').GetRawText(),$null,$nodeOptions)
      if (-not [System.Text.Json.Nodes.JsonNode]::DeepEquals($rawNode,$valueNode)) { throw 'CHECKPOINT_VALUE_MISMATCH' }
    } finally { $rawDocument.Dispose() }
  }
  return 'valid'
}

function Read-CheckpointFile {
  param($Identity)
  $result = [pscustomobject]@{state='invalid';checkpoint=$null;path=$Identity.path;reason='CHECKPOINT_INVALID'}
  $stream = $null; $reader = $null; $document = $null
  try {
    # Replacement can hold a write-access handle. Read access remains read-only;
    # symmetric read/write/delete sharing permits its atomic rename transition.
    $openClock = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
      try {
        $stream = [IO.File]::Open((dispatch-ledger-reader\Get-NonDispatchLedgerPath -Path $Identity.path),[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        break
      } catch [IO.IOException] {
        # ReplaceFile can briefly deny opens even with compatible share flags.
        # Retry only that Windows sharing violation, never corruption, absence,
        # permission failures or arbitrary I/O errors; exclusive locks still refuse.
        if (-not $IsWindows -or $_.Exception.GetBaseException().HResult -ne -2147024864 -or $openClock.ElapsedMilliseconds -ge 250) { throw }
        [Threading.Thread]::Sleep(5)
      }
    }
    $reader = [IO.StreamReader]::new($stream,[Text.UTF8Encoding]::new($false,$true),$false)
    $json = $reader.ReadToEnd()
    $options = [System.Text.Json.JsonDocumentOptions]::new(); $options.MaxDepth = $script:CheckpointMaxDepth
    $document = [System.Text.Json.JsonDocument]::Parse($json,$options)
    $result.state = Assert-CheckpointEnvelope $document.RootElement $Identity
    if ($result.state -eq 'valid') {
      $result.checkpoint = ConvertFrom-Json -InputObject $json -AsHashtable -DateKind String -Depth $script:CheckpointMaxDepth -ErrorAction Stop
      foreach ($row in $result.checkpoint.rows) {
        $row.value = ConvertFrom-CheckpointProjectionJson $row.raw
      }
      $result.reason = 'CHECKPOINT_STRUCTURALLY_VALID'
    } else { $result.reason = 'CHECKPOINT_SCHEMA_VERSION' }
  } catch [IO.FileNotFoundException] { $result.state='missing'; $result.reason='CHECKPOINT_MISSING'
  } catch [IO.DirectoryNotFoundException] { $result.state='missing'; $result.reason='CHECKPOINT_MISSING'
  } catch [IO.IOException] { $result.state='invalid'; $result.reason='CHECKPOINT_UNREADABLE'
  } catch [UnauthorizedAccessException] { $result.state='invalid'; $result.reason='CHECKPOINT_UNREADABLE'
  } catch { $result.state='invalid'; $result.checkpoint=$null; $result.reason='CHECKPOINT_INVALID'
  } finally {
    if ($null -ne $document) { $document.Dispose() }
    if ($null -ne $reader) { $reader.Dispose() } elseif ($null -ne $stream) { $stream.Dispose() }
  }
  return $result
}

function Read-DispatchHistoryCheckpoint {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Path,[string]$ReducerVersion='dispatch-count/v1',[string]$ContractVersion='dispatch-history/v1')
  $result = Read-CheckpointFile (Get-CheckpointIdentity $Path)
  if ($result.state -eq 'valid' -and ($result.checkpoint.reducerVersion -cne $ReducerVersion -or $result.checkpoint.contractVersion -cne $ContractVersion)) {
    $result.state='version'; $result.checkpoint=$null; $result.reason='CHECKPOINT_VERSION_MISMATCH'
  }
  return $result
}

function Publish-DispatchHistoryCheckpoint {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)]$History,
    [string]$ReducerVersion='dispatch-count/v1',[string]$ContractVersion='dispatch-history/v1')
  $identity = Get-CheckpointIdentity $Path
  $result = [pscustomobject]@{published=$false;reason='CHECKPOINT_PUBLISH_FAILED';path=$identity.path}
  $document = $null; $mutex = $null; $locked = $false; $temporary = $null; $temporaryOwned = $false
  try {
    $envelope = [ordered]@{schemaVersion=$script:CheckpointSchema;sourcePath=$identity.sourcePath;sourceKey=$identity.sourceKey
      reducerVersion=$ReducerVersion;contractVersion=$ContractVersion;complete=$History.complete
      snapshotLength=$History.snapshotLength;snapshotLines=$History.snapshotLines;snapshotHash=$History.snapshotHash;cursor=$History.cursor
      rows=@($History.rows);audit=$History.audit;partialTrailingRow=$History.partialTrailingRow}
    $json = ConvertTo-CheckpointJson $envelope
    $options = [System.Text.Json.JsonDocumentOptions]::new(); $options.MaxDepth = $script:CheckpointMaxDepth
    $document = [System.Text.Json.JsonDocument]::Parse($json,$options)
    if ((Assert-CheckpointEnvelope $document.RootElement $identity) -ne 'valid') { throw 'CHECKPOINT_INVALID' }
    # Freeze the validated input before waiting; caller-owned objects may change.
    $envelope = ConvertFrom-Json -InputObject $json -AsHashtable -DateKind String -Depth $script:CheckpointMaxDepth -ErrorAction Stop
    $name = 'ChaseSets.DispatchHistoryCheckpoint.' + $identity.sourceKey
    if ($IsWindows) { $name = 'Local\' + $name }
    $mutex = [Threading.Mutex]::new($false,$name)
    try { $locked = $mutex.WaitOne($script:CheckpointMutexWaitMs) }
    catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { $result.reason='CHECKPOINT_MUTEX_TIMEOUT'; return $result }
    $existing = Read-CheckpointFile $identity
    if ($existing.reason -eq 'CHECKPOINT_UNREADABLE') { $result.reason='CHECKPOINT_UNREADABLE'; return $result }
    if ($existing.state -eq 'valid') {
      if ($existing.checkpoint.cursor -gt $envelope.cursor) { $result.reason='CHECKPOINT_CURSOR_REGRESSION'; return $result }
      if ($existing.checkpoint.cursor -eq $envelope.cursor) {
        $oldProjection = [ordered]@{}; $newProjection = [ordered]@{}
        foreach ($field in @('snapshotLength','snapshotLines','snapshotHash','cursor','rows','audit','partialTrailingRow')) {
          $oldProjection[$field]=$existing.checkpoint[$field]; $newProjection[$field]=$envelope[$field]
        }
        $oldNode = [System.Text.Json.Nodes.JsonNode]::Parse((ConvertTo-CheckpointJson $oldProjection),$null,$options)
        $newNode = [System.Text.Json.Nodes.JsonNode]::Parse((ConvertTo-CheckpointJson $newProjection),$null,$options)
        if (-not [System.Text.Json.Nodes.JsonNode]::DeepEquals($oldNode,$newNode)) { $result.reason='CHECKPOINT_EQUAL_CURSOR_CONFLICT'; return $result }
      }
    }
    $directory = [IO.Path]::GetDirectoryName($identity.path)
    [void][IO.Directory]::CreateDirectory($directory)
    $temporary = Join-Path $directory ($identity.sourceKey + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $bytes = [Text.UTF8Encoding]::new($false,$true).GetBytes($json)
    $file = [IO.File]::Open((dispatch-ledger-reader\Get-NonDispatchLedgerPath -Path $temporary),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    $temporaryOwned = $true
    try { $file.Write($bytes,0,$bytes.Length); $file.Flush($true) } finally { $file.Dispose() }
    # Same-directory rename/replace is atomic. Delete races fail closed or leave
    # a complete replacement; the next caller can bootstrap after root deletion.
    if ([IO.File]::Exists($identity.path)) {
      try { [IO.File]::Replace($temporary,$identity.path,[System.Management.Automation.Language.NullString]::Value) }
      catch [IO.FileNotFoundException] { [IO.File]::Move($temporary,$identity.path) }
    } else { [IO.File]::Move($temporary,$identity.path) }
    $result.published=$true; $result.reason='CHECKPOINT_PUBLISHED'
  } catch { $result.reason='CHECKPOINT_PUBLISH_FAILED'
  } finally {
    if ($null -ne $document) { $document.Dispose() }
    if ($temporaryOwned) { try { [IO.File]::Delete($temporary) } catch {} }
    if ($locked) { $mutex.ReleaseMutex() }
    if ($null -ne $mutex) { $mutex.Dispose() }
  }
  return $result
}

Export-ModuleMember -Function Get-DispatchHistoryCheckpointPath,Read-DispatchHistoryCheckpoint,Publish-DispatchHistoryCheckpoint
