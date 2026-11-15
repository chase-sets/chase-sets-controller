$ErrorActionPreference = 'Stop'
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'invoke-heavy-verifier.test.ps1'), [ref]$null, [ref]$errors)
if ($errors.Count) { throw 'ordinary verifier test must parse' }
$wrappers = @($ast.FindAll({ param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-RoleWrapper'
}, $true))
if ($wrappers.Count -ne 1) { throw 'expected one actual role fixture wrapper' }
$statements = @($wrappers[0].Body.EndBlock.Statements)
$launches = @($statements | Where-Object {
  $_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -ceq '$child' -and
    $_.Right.Extent.Text -ceq '[Diagnostics.Process]::Start($start)'
})
if ($launches.Count -ne 1) { throw 'expected one actual role fixture child launch boundary' }
$setup = @($statements | Where-Object {
  $_ -is [Management.Automation.Language.AssignmentStatementAst] -and
    $_.Extent.StartOffset -lt $launches[0].Extent.StartOffset -and $_.Left.Extent.Text.StartsWith('$start', [StringComparison]::Ordinal)
})
$source = $setup.Extent.Text -join "`n"
$nativeTree = Join-Path ([IO.Path]::GetTempPath()) ('inert-role-source-' + [guid]::NewGuid().ToString('N'))
$parentRoot = $env:CHASE_SETS_CONTROLLER_ROOT
function Assert-RoleFixtureSource([string]$Setup, [string]$nativeTree) {
  $start = $null
  . ([scriptblock]::Create($Setup))
  if ($start -isnot [Diagnostics.ProcessStartInfo] -or $start.Environment['CHASE_SETS_CONTROLLER_ROOT'] -cne $nativeTree) {
    throw 'actual role fixture must bind its child controller source to the committed native fixture tree'
  }
  if ($env:CHASE_SETS_CONTROLLER_ROOT -cne $parentRoot) { throw 'role fixture source binding must not change the parent environment' }
}
Assert-RoleFixtureSource $source $nativeTree
$bindings = @($setup | Where-Object { $_.Left.Extent.Text -ceq '$start.Environment[''CHASE_SETS_CONTROLLER_ROOT'']' })
if ($bindings.Count -ne 1) { throw 'expected one explicit child-local role source binding' }
foreach ($replacement in @('', '$start.Environment[''CHASE_SETS_CONTROLLER_ROOT''] = ''foreign-source''')) {
  $reason = $null
  try { Assert-RoleFixtureSource ($source.Replace($bindings[0].Extent.Text, $replacement)) $nativeTree } catch { $reason = $_.Exception.Message }
  if ($reason -cne 'actual role fixture must bind its child controller source to the committed native fixture tree') {
    throw 'missing or foreign controller source binding must fail the actual child setup proof'
  }
}
if ($env:CHASE_SETS_CONTROLLER_ROOT -cne $parentRoot -or (Test-Path -LiteralPath $nativeTree)) {
  throw 'inert role source proof must leave the parent and filesystem unchanged'
}
Write-Output 'PASS actual role child setup binds its committed fixture source without changing the parent; missing and foreign source mutants refuse; no process, admission, Job, signal or filesystem write'
