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

$bindingPaths = @('scripts/verify-static-scoped.mjs','scripts/verify-static-surfaces.mjs',
  'scripts/change-scope.mjs','scripts/e2e-suites.mjs','scripts/lib/repo.mjs',
  'scripts/lib/risk-policy-v1.mjs','scripts/lib/heavy-slot.mjs')
$binding = @($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Invoke-CurrentBindingControls'}, $true))
Assert-Fixture ($binding.Count -eq 1) 'one ordinary current binding control'
$copies = @($binding[0].Body.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.ForEachStatementAst] -and $_.Variable.Extent.Text -ceq '$relative' })
Assert-Fixture ($copies.Count -eq 1) 'one actual product dependency copy loop'
$actualPaths = @(& ([scriptblock]::Create($copies[0].Condition.Extent.Text)))
Assert-Fixture (($actualPaths -join ',') -ceq ($bindingPaths -join ',')) 'ordinary copy loop retains all seven original product paths'
Assert-Fixture ($copies[0].Body.Extent.Text.Contains('Read-CurrentBindingFixture $relative') -and
  -not $binding[0].Extent.Text.Contains('git -C $product show') -and
  $binding[0].Extent.Text.Contains("Read-CurrentBindingFixture '.orchestrator/invoke-heavy-verifier.ps1'")) 'both ordinary product and original-wrapper legs use pinned fixtures'
$bindingTemp = Join-Path ([IO.Path]::GetTempPath()) ('binding-fixture-' + [guid]::NewGuid().ToString('N'))
try {
  [void][IO.Directory]::CreateDirectory($bindingTemp)
  # Execute the ordinary copy loop, but none of its native admission controls.
  $worktree = Join-Path $bindingTemp 'copy'
  function Assert-True($Condition, [string]$Message) { Assert-Fixture $Condition $Message }
  & ([scriptblock]::Create($copies[0].Extent.Text))
  foreach ($relative in @($bindingPaths) + @('.orchestrator/invoke-heavy-verifier.ps1')) {
    $sourcePath = Join-Path $PSScriptRoot "fixtures/historical-current-binding/$relative"
    $raw = [IO.File]::ReadAllBytes($sourcePath)
    $decoded = Read-CurrentBindingFixture $relative
    Assert-Fixture ([Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes($decoded)) -ceq
      [Convert]::ToBase64String($raw)) "$relative decodes and reencodes the exact original raw bytes"
    if ($bindingPaths -ccontains $relative) {
      Assert-Fixture ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $worktree $relative))) -ceq
        [Convert]::ToBase64String($raw)) "$relative ordinary copy preserves the exact original raw bytes"
    }
    $missing = $false
    try { Read-CurrentBindingFixture $relative (Join-Path $bindingTemp 'missing') | Out-Null } catch { $missing = $true }
    Assert-Fixture $missing "$relative missing input fails closed"
    $mutantPath = Join-Path $bindingTemp "mutant/$relative"
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $mutantPath))
    $raw[$raw.Length - 1] = $raw[$raw.Length - 1] -bxor 1
    [IO.File]::WriteAllBytes($mutantPath, $raw)
    $refused = $false
    try { Read-CurrentBindingFixture $relative (Join-Path $bindingTemp 'mutant') | Out-Null } catch { $refused = $_.Exception.Message.Contains('blob mismatch') }
    Assert-Fixture $refused "$relative one-byte mutation fails closed"
  }
  $invalidPath = $false
  try { Read-CurrentBindingFixture '../invoke-heavy-verifier.ps1' | Out-Null } catch { $invalidPath = $true }
  Assert-Fixture $invalidPath 'out-of-inventory fixture path fails closed'
} finally {
  $parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
  Assert-Fixture ((Split-Path -Parent ([IO.Path]::GetFullPath($bindingTemp))) -ceq $parent) 'binding cleanup remains in owned temp root'
  if (Test-Path $bindingTemp) { Remove-Item -LiteralPath $bindingTemp -Recurse -Force }
}
Write-Output 'PASS current-binding fixtures: eight original blobs, actual seven-file copy, exact raw bytes, missing/mutated/foreign input refusals; native execution NOT_RUN'

$packageWrites = @($ast.FindAll({param($n)
  $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
  $n.Member.Value -ceq 'WriteAllText' -and $n.Arguments.Count -eq 3 -and
  $n.Arguments[1] -is [Management.Automation.Language.StringConstantExpressionAst] -and
  $n.Arguments[1].Value.Contains('"name":"heavy-slot-fixture"')
}, $true))
Assert-Fixture ($packageWrites.Count -eq 1) 'one actual gate-matrix package fixture'
$matrixPackage = $packageWrites[0].Arguments[1].Value | ConvertFrom-Json
$pin = @($candidateAst.FindAll({param($n)
  $n -is [Management.Automation.Language.AssignmentStatementAst] -and
  $n.Left.Extent.Text -ceq '$canonicalRecordScriptExpected'
}, $true))
Assert-Fixture ($pin.Count -eq 1) 'one production canonical-record command pin'
$expectedCommand = $pin[0].Right.Expression.Value
Assert-Fixture ($expectedCommand -and $matrixPackage.scripts.'test:canonical-record' -ceq $expectedCommand) 'ordinary matrix fixture satisfies the unchanged production command pin'
$matrixPackage.scripts.PSObject.Properties.Remove('test:canonical-record')
Assert-Fixture ($matrixPackage.scripts.'test:canonical-record' -cne $expectedCommand) 'missing canonical command fails the fixture contract'
Write-Output 'PASS ordinary gate-matrix package matches unchanged canonical-record script pin; missing command refuses'
