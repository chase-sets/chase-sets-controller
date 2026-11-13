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
