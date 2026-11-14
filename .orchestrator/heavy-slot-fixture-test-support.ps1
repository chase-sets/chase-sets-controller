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

function Read-CurrentBindingFixture(
  [ValidateSet('scripts/verify-static-scoped.mjs','scripts/verify-static-surfaces.mjs',
    'scripts/change-scope.mjs','scripts/e2e-suites.mjs','scripts/lib/repo.mjs',
    'scripts/lib/risk-policy-v1.mjs','scripts/lib/heavy-slot.mjs',
    '.orchestrator/invoke-heavy-verifier.ps1')][string]$Relative,
  [string]$FixtureRoot = (Join-Path $PSScriptRoot 'fixtures/historical-current-binding')
) {
  $pins = @{
    'scripts/verify-static-scoped.mjs' = 'bb77106882a590253500d446ff431510b94e37c8'
    'scripts/verify-static-surfaces.mjs' = '2e09c0db0d328846596cfd3586ea7d6f4582b896'
    'scripts/change-scope.mjs' = 'bb07241ebd9865a9753e057f652a514bf3c38fbe'
    'scripts/e2e-suites.mjs' = '5ec9ff849d3f4dbc1c79ec9db8ae7fb12424adcb'
    'scripts/lib/repo.mjs' = '5be342b36d2f9eb5855853859082f8028f7cc043'
    'scripts/lib/risk-policy-v1.mjs' = '70a865109d246d4c9287a0b1224b2f9e9ec0ad12'
    'scripts/lib/heavy-slot.mjs' = '30327bd78fe8eb15130f63faafee42172b4d8eed'
    '.orchestrator/invoke-heavy-verifier.ps1' = '3d1a71ebd741e78cb018e16e758971272ba31fb7'
  }
  $bytes = [IO.File]::ReadAllBytes((Join-Path $FixtureRoot $Relative))
  $hash = [Security.Cryptography.IncrementalHash]::CreateHash('SHA1')
  try {
    $hash.AppendData([Text.Encoding]::ASCII.GetBytes("blob $($bytes.Length)`0"))
    $hash.AppendData($bytes)
    $actual = [Convert]::ToHexString($hash.GetHashAndReset()).ToLowerInvariant()
  } finally { $hash.Dispose() }
  if ($actual -cne $pins[$Relative]) { throw "CURRENT_BINDING_FIXTURE: blob mismatch for $Relative" }
  return [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
}

function Get-CensusAdmissionAnchor([string]$Source, [switch]$Baseline) {
  if ($Baseline) { return '$beforeCensus = [ChaseSets.HeavyAdmission.NestedOwnerServer]::CaptureDispatchCensus($runtimeRoot)' }
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseInput($Source, [ref]$null, [ref]$errors)
  if ($errors.Count) { throw 'CENSUS_ADMISSION_ANCHOR: source does not parse' }
  $functions = @($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Get-HeavyCallerObservation'}, $true))
  if ($functions.Count -ne 1) { throw 'CENSUS_ADMISSION_ANCHOR: expected one observation function' }
  $assignments = @($functions[0].Body.FindAll({param($n)
    $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$before' -and
      @($n.Right.FindAll({param($c) $c -is [Management.Automation.Language.CommandAst] -and $c.GetCommandName() -ceq 'Get-HeavyCallerAncestry'}, $true)).Count -eq 1
  }, $true))
  if ($assignments.Count -ne 1) { throw 'CENSUS_ADMISSION_ANCHOR: expected one ancestry assignment' }
  return $assignments[0].Extent.Text
}
