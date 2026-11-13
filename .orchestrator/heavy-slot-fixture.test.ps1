$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'heavy-slot-fixture-test-support.ps1')
function Assert-Fixture($Condition, [string]$Message) { if (-not $Condition) { throw "ASSERTION FAILED: $Message" } }
foreach ($name in @('heavy-nested-owner.cs','invoke-heavy-verifier.ps1')) {
  $source = Read-CensusBaselineFixture $name
  Assert-Fixture ($source.Length -gt 10000 -and $source.Contains('CaptureDispatchCensus')) "$name is the genuine original census implementation"
}
$temp = Join-Path ([IO.Path]::GetTempPath()) ('census-fixture-' + [guid]::NewGuid().ToString('N'))
try {
  [void][IO.Directory]::CreateDirectory($temp)
  $name = 'heavy-nested-owner.cs'
  $missing = $false
  try { Read-CensusBaselineFixture $name $temp | Out-Null } catch { $missing = $true }
  Assert-Fixture $missing 'missing fixture fails closed'
  $path = Join-Path $temp $name
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot "fixtures/historical-census-before-7958/.orchestrator/$name") -Destination $path
  $bytes = [IO.File]::ReadAllBytes($path); $bytes[$bytes.Length - 1] = $bytes[$bytes.Length - 1] -bxor 1
  [IO.File]::WriteAllBytes($path, $bytes)
  $changed = $false
  try { Read-CensusBaselineFixture $name $temp | Out-Null } catch { $changed = $_.Exception.Message.Contains('blob mismatch') }
  Assert-Fixture $changed 'one-byte mutation fails closed'
} finally {
  $parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
  Assert-Fixture ((Split-Path -Parent ([IO.Path]::GetFullPath($temp))) -ceq $parent) 'cleanup remains in owned temp root'
  if (Test-Path $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
$suite = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'heavy-slot.test.ps1'))
$ast = [Management.Automation.Language.Parser]::ParseInput($suite, [ref]$null, [ref]$null)
$controls = @($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Invoke-CensusControls'}, $true))
Assert-Fixture ($controls.Count -eq 1) 'one ordinary census control'
$body = $controls[0].Extent.Text
Assert-Fixture (-not $body.Contains('git -C $controllerRoot show') -and ([regex]::Matches($body, 'Read-CensusBaselineFixture')).Count -eq 2) 'both original census baseline legs use pinned public fixtures instead of private history'
Write-Output 'PASS pinned census fixture originals, missing/one-byte negatives and both ordinary baseline legs; native execution NOT_RUN'
