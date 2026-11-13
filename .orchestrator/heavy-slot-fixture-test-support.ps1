function Read-CensusBaselineFixture(
  [ValidateSet('heavy-nested-owner.cs','invoke-heavy-verifier.ps1')][string]$Name,
  [string]$FixtureRoot = (Join-Path $PSScriptRoot 'fixtures/historical-census-before-7958/.orchestrator')
) {
  $pins = @{
    'heavy-nested-owner.cs' = '006b4fe44619c001436b65ab5fc73fd083933513'
    'invoke-heavy-verifier.ps1' = '2242ae39894776c45709e4a5ecb67eeba536ee60'
  }
  $bytes = [IO.File]::ReadAllBytes((Join-Path $FixtureRoot $Name))
  $hash = [Security.Cryptography.IncrementalHash]::CreateHash('SHA1')
  try {
    $hash.AppendData([Text.Encoding]::ASCII.GetBytes("blob $($bytes.Length)`0"))
    $hash.AppendData($bytes)
    $actual = [Convert]::ToHexString($hash.GetHashAndReset()).ToLowerInvariant()
  } finally { $hash.Dispose() }
  if ($actual -cne $pins[$Name]) { throw "CENSUS_BASELINE_FIXTURE: blob mismatch for $Name" }
  return [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
}
