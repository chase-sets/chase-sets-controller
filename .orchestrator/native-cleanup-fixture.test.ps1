$ErrorActionPreference = 'Stop'
$errors = $null
$fixture = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'invoke-heavy-verifier.test.ps1'), [ref]$null, [ref]$errors)
if ($errors.Count) { throw 'ordinary verifier test must parse' }
$writes = @($fixture.FindAll({ param($node)
  $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
    $node.Expression.Extent.Text -ceq '[IO.File]' -and $node.Member.Value -ceq 'WriteAllText' -and
    $node.Arguments.Count -eq 2 -and $node.Arguments[0].Extent.Text -ceq '$driver'
}, $true))
if ($writes.Count -ne 1) { throw 'expected one actual native cleanup driver definition' }
$driver = [Management.Automation.Language.Parser]::ParseInput($writes[0].Arguments[1].SafeGetValue(), [ref]$null, [ref]$errors)
if ($errors.Count) { throw 'actual native cleanup driver must parse' }
$loaders = @($driver.EndBlock.Statements | Where-Object {
  $_ -is [Management.Automation.Language.ForEachStatementAst] -and $_.Variable.Extent.Text -ceq '$definition'
})
if ($loaders.Count -ne 1) { throw 'expected one actual driver function loader' }
$verifier = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'invoke-heavy-verifier.ps1'), [ref]$null, [ref]$errors)
if ($errors.Count) { throw 'actual verifier must parse' }
& {
  param($ast, $loader)
  . ([scriptblock]::Create($loader))
  foreach ($name in @('Invoke-NativeLaunch', 'Stop-ExactVerifierProcess', 'Invoke-HeavyAdmissionCensus', 'Enter-HeavyAdmissionPriority', 'Exit-HeavyAdmissionPriority')) {
    $loaded = Get-Command $name -CommandType Function -ErrorAction SilentlyContinue
    if (-not $loaded) { throw "actual native cleanup driver omits verifier helper $name" }
    $definitions = @($ast.FindAll({ param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
    }, $false))
    if ($definitions.Count -ne 1 -or $loaded.ScriptBlock.Ast.Extent.Text -cne $definitions[0].Extent.Text) {
      throw "driver must load the exact actual verifier helper $name"
    }
  }
  $script:entered = 0; $script:restored = 0; $script:restoreOkay = $true
  function Enter-HeavyAdmissionPriority { $script:entered++ }
  function Exit-HeavyAdmissionPriority { $script:restored++; return $script:restoreOkay }
  $output = @(Invoke-HeavyAdmissionCensus { 'inert action output' })
  if ($output.Count -ne 1 -or $output[0] -cne 'inert action output') { throw 'actual census helper must preserve action output' }
  $reason = $null
  try { Invoke-HeavyAdmissionCensus { throw 'inert action failure' } } catch { $reason = $_.Exception.Message }
  if ($reason -cne 'inert action failure') { throw 'actual census helper must preserve action failure' }
  $script:restoreOkay = $false
  $reason = $null; $output = @()
  try { $output = @(Invoke-HeavyAdmissionCensus { 'must not escape failed restoration' }) } catch { $reason = $_.Exception.Message }
  if ($reason -cne 'heavy-verifier: admission priority restoration could not be proven' -or $output.Count) {
    throw 'actual census helper must withhold output when restoration fails'
  }
  if ($script:entered -ne 3 -or $script:restored -ne 3) { throw 'each inert action must enter and restore exactly once' }
} $verifier $loaders[0].Extent.Text
Write-Output 'PASS actual native cleanup driver includes exact verifier census/priority helpers; output, action error and restoration refusal preserved with inert priority callbacks; no native launch or cleanup execution'
