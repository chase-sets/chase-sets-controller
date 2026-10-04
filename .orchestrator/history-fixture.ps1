# Historical controller sources as tracked test data (#8580). A consumer that
# used to read a retired commit from private container history now reads
# fixtures/history/<commit>.json: the exact blob bytes of every file it reads,
# plus zero-byte placeholders for paths whose existence alone is checked. The
# fixture carries the commit, each file's Git blob id and SHA-256, so anyone
# holding the history can verify it with `git cat-file`; no checkout needs the
# commit itself. Assertions are unchanged: a missing or altered fixture fails
# the same way an unavailable commit did.
function Get-HistoryFixturePath([string]$Commit) {
  if ($Commit -cnotmatch '^[a-f0-9]{40}$') { throw "history fixture: a full commit id is required: $Commit" }
  return Join-Path $PSScriptRoot "fixtures/history/$Commit.json"
}

function Read-HistoryFixture([string]$Commit) {
  $path = Get-HistoryFixturePath $Commit
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "history fixture missing for $Commit`: $path" }
  $fixture = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 6 -DateKind String
  if ($fixture.schemaVersion -cne 'controller-history-fixture/v1' -or [string]$fixture.commit -cne $Commit) {
    throw "history fixture identity differs for $Commit`: $path"
  }
  return $fixture
}

function Get-HistoryFixtureEntryBytes($Entry) {
  if ([string]$Entry.mode -cne 'read') { throw "history fixture $($Entry.path) holds no bytes (mode=$($Entry.mode))" }
  $bytes = [Text.UTF8Encoding]::new($false).GetBytes([string]$Entry.content)
  $sha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
  if ($sha -cne [string]$Entry.sha256 -or $bytes.Length -ne [int64]$Entry.bytes) { throw "history fixture bytes differ for $($Entry.path)" }
  return ,$bytes
}

# Exact bytes of one historical file (mode read), e.g. a retired script that a
# discriminator materializes as a named bypass variant.
function Get-HistoryFixtureBytes([string]$Commit, [string]$RelativePath) {
  $fixture = Read-HistoryFixture $Commit
  $relative = $RelativePath.Replace('\', '/')
  $entries = @($fixture.files | Where-Object { [string]$_.path -ceq $relative })
  if ($entries.Count -ne 1) { throw "history fixture $Commit does not hold $relative" }
  return ,(Get-HistoryFixtureEntryBytes $entries[0])
}

function Get-HistoryFixtureText([string]$Commit, [string]$RelativePath) {
  return [Text.UTF8Encoding]::new($false, $true).GetString((Get-HistoryFixtureBytes $Commit $RelativePath))
}

# Materializes every fixture file below $Destination (read: exact bytes;
# existence-only: an empty file) and returns the read manifest.
function Expand-HistoryFixture([string]$Commit, [string]$Destination) {
  $fixture = Read-HistoryFixture $Commit
  $manifest = [Collections.Generic.List[object]]::new()
  foreach ($entry in @($fixture.files)) {
    $relative = [string]$entry.path
    if ($relative -cnotmatch '^\.orchestrator/[A-Za-z0-9._/-]+$' -or $relative.Contains('/../') -or $relative.Contains('//')) { throw "history fixture path refused: $relative" }
    $target = Join-Path $Destination ($relative -replace '/', [IO.Path]::DirectorySeparatorChar)
    [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null
    switch ([string]$entry.mode) {
      'read' { [IO.File]::WriteAllBytes($target, (Get-HistoryFixtureEntryBytes $entry)) }
      'existence-only' { [IO.File]::WriteAllBytes($target, [byte[]]@()) }
      default { throw "history fixture mode refused: $($entry.mode) for $relative" }
    }
    $manifest.Add([pscustomobject][ordered]@{ path = $relative; mode = [string]$entry.mode; blob = [string]$entry.blob; sha256 = [string]$entry.sha256 })
  }
  return [pscustomobject][ordered]@{ commit = $Commit; destination = $Destination; files = @($manifest) }
}
