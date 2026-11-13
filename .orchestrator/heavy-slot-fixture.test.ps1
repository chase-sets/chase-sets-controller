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
$selectors = @($controls[0].FindAll({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$anchor'}, $true))
Assert-Fixture ($selectors.Count -eq 1) 'one real admission anchor selector'
$candidate = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'invoke-heavy-verifier.ps1'))
$candidateAst = [Management.Automation.Language.Parser]::ParseInput($candidate, [ref]$null, [ref]$null)
$statement = @($candidateAst.FindAll({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Extent.Text.StartsWith('$before = Get-HeavyCallerAncestry ', [StringComparison]::Ordinal)}, $true))
Assert-Fixture ($statement.Count -eq 1) 'one complete current ancestry assignment'
function Select-ActualAnchor([string]$Source, [bool]$Baseline) {
  $sourceText = $Source; $case = @{Baseline=$Baseline}
  return & ([scriptblock]::Create($selectors[0].Extent.Text + "`n" + '$anchor'))
}
$anchor = Select-ActualAnchor $candidate $false
Assert-Fixture ($anchor -ceq $statement[0].Extent.Text) 'real builder anchors after every ancestry argument'
$baseline = Read-CensusBaselineFixture 'invoke-heavy-verifier.ps1'
$baselineAnchor = Select-ActualAnchor $baseline $true
Assert-Fixture ($baselineAnchor -ceq '$beforeCensus = [ChaseSets.HeavyAdmission.NestedOwnerServer]::CaptureDispatchCensus($runtimeRoot)') 'historical admission anchor stays unchanged'
function Get-HeavyCallerAncestry { $script:received = @($args); return @{} }
$rootPid=1; $rootStart='inert'; $oldestLaunch=0; $candidatePids=@(1)
$records=@{foreign=[pscustomobject]@{label='inert-foreign'}}
$assignment=$statement[0].Extent.Text
$modified=$assignment.Replace($anchor, $anchor + "`n# inert no-output barrier`n")
$output=@(& ([scriptblock]::Create($modified)))
Assert-Fixture ($output.Count -eq 0 -and $received.Count -eq 5 -and $received[4].label -ceq 'inert-foreign') 'actual candidate anchor preserves dispatch-record argument without stray output'
$extended=$candidate.Replace($assignment, $assignment + ' -FutureArgument inert')
Assert-Fixture ((Select-ActualAnchor $extended $false) -ceq ($assignment + ' -FutureArgument inert')) 'future trailing arguments remain inside the statement anchor'
foreach ($invalid in @($candidate.Replace('function Get-HeavyCallerObservation(', 'function MissingObservation('),
    $candidate.Replace($assignment, $assignment + "`n" + $assignment), 'function Get-HeavyCallerObservation {')) {
  $refused=$false
  try { Select-ActualAnchor $invalid $false | Out-Null } catch { $refused=$_.Exception.Message.Contains('CENSUS_ADMISSION_ANCHOR') }
  Assert-Fixture $refused 'missing, ambiguous or malformed candidate statement fails closed'
}
Write-Output 'PASS pinned census fixtures and real admission anchor: complete arguments, no stray output, baseline unchanged; native execution NOT_RUN'
