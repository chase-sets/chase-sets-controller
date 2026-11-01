[CmdletBinding()]
param(
  [string]$ControllerRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'

function Assert-Fixture([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "HISTORICAL_FIXTURE_MANIFEST: $Message" }
}

function Get-FixtureEntries([string]$FixtureRoot, [string]$Name) {
  $readmePath = Join-Path $FixtureRoot 'README.md'
  Assert-Fixture (Test-Path -LiteralPath $readmePath -PathType Leaf) "$Name README is missing"

  $lines = [IO.File]::ReadAllLines($readmePath)
  $entries = [Collections.Generic.List[object]]::new()
  foreach ($line in $lines) {
    if ($line -notlike '- *') { continue }
    $match = [regex]::Match($line, '^- (?<path>\.orchestrator/[A-Za-z0-9._/-]+?)\s*\| blob `(?<blob>[0-9a-f]{40})`$')
    Assert-Fixture $match.Success "$Name has a malformed manifest entry: $line"
    $entries.Add([pscustomobject]@{ path = $match.Groups['path'].Value; blob = $match.Groups['blob'].Value })
  }
  Assert-Fixture ($entries.Count -gt 0) "$Name manifest has no file entries"
  $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($entry in $entries) {
    Assert-Fixture $paths.Add($entry.path) "$Name manifest duplicates $($entry.path)"
    $resolved = [IO.Path]::GetFullPath((Join-Path $FixtureRoot $entry.path))
    $root = [IO.Path]::GetFullPath($FixtureRoot).TrimEnd('\', '/') + '\'
    Assert-Fixture $resolved.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) "$Name manifest path escapes fixture root: $($entry.path)"
  }
  return $entries.ToArray()
}

function Get-FixtureFiles([string]$FixtureRoot) {
  return @(Get-ChildItem -LiteralPath $FixtureRoot -File -Recurse | ForEach-Object {
    [IO.Path]::GetRelativePath($FixtureRoot, $_.FullName).Replace('\', '/')
  } | Where-Object { $_ -cne 'README.md' -and $_ -cne '.gitattributes' })
}

function Get-GitBlobHash([string]$ControllerRoot, [string]$Path) {
  $output = @(& git.exe -C $ControllerRoot hash-object --no-filters -- ([IO.Path]::GetFullPath($Path)) 2>&1)
  Assert-Fixture ($LASTEXITCODE -eq 0 -and $output.Count -eq 1 -and $output[0] -cmatch '^[0-9a-f]{40}$') "git hash-object failed for $Path"
  return $output[0].Trim()
}

function Test-FixtureManifest([string]$ControllerRoot, [string]$FixtureRoot, [string]$Name) {
  $entries = @(Get-FixtureEntries $FixtureRoot $Name)
  $actualFiles = @(Get-FixtureFiles $FixtureRoot)
  Assert-Fixture ((@($actualFiles | Sort-Object) -join ',') -ceq (@($entries.path | Sort-Object) -join ',')) "$Name manifest read set is not closed"

  foreach ($entry in $entries) {
    $path = Join-Path $FixtureRoot $entry.path
    Assert-Fixture (Test-Path -LiteralPath $path -PathType Leaf) "$Name manifest file is missing: $($entry.path)"
    $actual = Get-GitBlobHash $ControllerRoot $path
    Assert-Fixture ($actual -ceq $entry.blob) "$Name blob mismatch for $($entry.path): expected=$($entry.blob) actual=$actual"
  }
  return $entries
}

function New-TempCopy([string]$Source, [string]$TempRoot, [string]$Name) {
  $destination = Join-Path $TempRoot $Name
  Copy-Item -LiteralPath $Source -Destination $destination -Recurse
  return $destination
}

$controllerRoot = [IO.Path]::GetFullPath($ControllerRoot)
$fixtureRoot = Join-Path $controllerRoot '.orchestrator/fixtures'
$fixtureNames = @('historical-b3b4ac2', 'historical-aa62899')
$validated = [ordered]@{}
foreach ($name in $fixtureNames) {
  $validated[$name] = @(Test-FixtureManifest $controllerRoot (Join-Path $fixtureRoot $name) $name)
  Write-Output "PASS $name manifest files=$($validated[$name].Count) closedReadSet=true gitBlobHashes=true"
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('historical-fixture-manifest-' + [guid]::NewGuid().ToString('N'))
try {
  [IO.Directory]::CreateDirectory($tempRoot) | Out-Null

  $removedRoot = New-TempCopy (Join-Path $fixtureRoot 'historical-b3b4ac2') $tempRoot 'removed-file'
  $removedEntry = $validated['historical-b3b4ac2'][0]
  Remove-Item -LiteralPath (Join-Path $removedRoot $removedEntry.path) -Force
  $removedRefused = $false
  try { Test-FixtureManifest $controllerRoot $removedRoot 'historical-b3b4ac2 removed-file' | Out-Null } catch { $removedRefused = $true }
  Assert-Fixture $removedRefused 'removed-file mutation was accepted'
  Write-Output "PASS negative removed-file refused=true path=$($removedEntry.path)"

  $mutatedRoot = New-TempCopy (Join-Path $fixtureRoot 'historical-aa62899') $tempRoot 'one-byte-mutation'
  $mutatedEntry = $validated['historical-aa62899'][0]
  $mutatedPath = Join-Path $mutatedRoot $mutatedEntry.path
  $bytes = [IO.File]::ReadAllBytes($mutatedPath)
  Assert-Fixture ($bytes.Length -gt 0) 'one-byte mutation target is empty'
  $bytes[$bytes.Length - 1] = $bytes[$bytes.Length - 1] -bxor 0x01
  [IO.File]::WriteAllBytes($mutatedPath, $bytes)
  $mutatedRefused = $false
  try { Test-FixtureManifest $controllerRoot $mutatedRoot 'historical-aa62899 one-byte-mutation' | Out-Null } catch { $mutatedRefused = $true }
  Assert-Fixture $mutatedRefused 'one-byte mutation was accepted'
  Write-Output "PASS negative one-byte-mutation refused=true path=$($mutatedEntry.path)"
} finally {
  $resolved = [IO.Path]::GetFullPath($tempRoot)
  $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
  Assert-Fixture ((Split-Path -Parent $resolved) -ceq $tempParent) 'unsafe temporary cleanup path'
  if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}

Write-Output 'PASS historical fixture manifest validation: public-only, closed read sets, raw Git blob hashes, and fail-closed negatives'
