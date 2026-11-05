[CmdletBinding()]
param([string]$ControllerRoot=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ledger-reader-census.psm1') -Force
$selector='ChaseSets.LedgerCensus.AstSelectionV1' -as [type]
if (-not $selector) { throw 'compiled census AST selector missing' }
Import-Module (Join-Path $PSScriptRoot 'ledger-reader-census.psm1') -Force
if (('ChaseSets.LedgerCensus.AstSelectionV1' -as [type]) -ne $selector) { throw 'selector identity changed on import' }

$queries=@(
  ,@([Management.Automation.Language.AssignmentStatementAst])
  ,@([Management.Automation.Language.ParameterAst])
  ,@([Management.Automation.Language.ForEachStatementAst])
  ,@([Management.Automation.Language.TrapStatementAst])
  ,@([Management.Automation.Language.CommandAst])
  ,@([Management.Automation.Language.FunctionDefinitionAst])
  ,@([Management.Automation.Language.VariableExpressionAst])
  ,@([Management.Automation.Language.StringConstantExpressionAst])
  ,@([Management.Automation.Language.TypeExpressionAst])
  ,@([Management.Automation.Language.InvokeMemberExpressionAst])
  ,@([Management.Automation.Language.StringConstantExpressionAst],[Management.Automation.Language.VariableExpressionAst])
  ,@([Management.Automation.Language.StringConstantExpressionAst],[Management.Automation.Language.ExpandableStringExpressionAst],[Management.Automation.Language.VariableExpressionAst])
  ,@([Management.Automation.Language.InvokeMemberExpressionAst],[Management.Automation.Language.CommandAst],[Management.Automation.Language.StringConstantExpressionAst],[Management.Automation.Language.ExpandableStringExpressionAst])
  ,@([Management.Automation.Language.ExpressionAst])
  ,@([Management.Automation.Language.CommandAst],[Management.Automation.Language.CommandAst])
)
$synthetic=@'
param([string]$Path='receipt.json')
trap { continue }
throw 'inspected source must never execute'
$literal='receipt.json'; $expanded="root/$Path"; $alias=[System.IO.File]
function Outer([string]$Value) {
  foreach($entry in @($Value)) { & 'Get-Content' -LiteralPath $entry }
  function Inner { param($Nested); [IO.File]::ReadAllText($Nested) }
  $block={ param($Scoped); $local:p=$Scoped; Inner $local:p }
  & $block $Value
}
Add-Type 'class Synthetic { string Value; }'
Outer $Path
'@
$sources=@([pscustomobject]@{path='synthetic';source=$synthetic})
$paths=@(& git -C $ControllerRoot ls-files -- '*.ps1' '*.psm1')
if ($LASTEXITCODE -ne 0 -or -not $paths.Count) { throw 'selector test tracked inventory missing' }
# Include real large trees as well as nested synthetic scope and expression roots.
$largest=@($paths | ForEach-Object { Get-Item -LiteralPath (Join-Path $ControllerRoot $_) } | Sort-Object Length -Descending | Select-Object -First 3)
foreach ($file in $largest) { $sources+=[pscustomobject]@{path=$file.Name;source=[IO.File]::ReadAllText($file.FullName)} }
$checks=0;$nodes=0
$originalTime=[timespan]::Zero;$compiledTime=[timespan]::Zero
foreach ($source in $sources) {
  $tokens=$null;$errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseInput($source.source,[ref]$tokens,[ref]$errors)
  if ($errors.Count) { throw "selector source failed parsing: $($source.path)" }
  $roots=@($ast)
  if ($source.path -ceq 'synthetic') {
    $roots+=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -or $node -is [Management.Automation.Language.CommandExpressionAst]},$true))
  }
  foreach ($root in $roots) {
    foreach ($kinds in $queries) {
      $watch=[Diagnostics.Stopwatch]::StartNew()
      $expected=@($root.FindAll({param($node)
        foreach ($kind in $kinds) { if ($node -is $kind) { return $true } }
        return $false
      },$true))
      $originalTime+=$watch.Elapsed
      $watch.Restart()
      $actual=@([ChaseSets.LedgerCensus.AstSelectionV1]::Find($root,[type[]]$kinds))
      $compiledTime+=$watch.Elapsed
      if ($expected.Count -ne $actual.Count) { throw "selector count differs: $($source.path) / $kinds" }
      for ($i=0;$i -lt $expected.Count;$i++) {
        if (-not [object]::ReferenceEquals($expected[$i],$actual[$i])) { throw "selector identity/order differs: $($source.path) / $kinds / $i" }
      }
      $checks++;$nodes+=$actual.Count
    }
  }
}
if ($checks -lt $queries.Count -or $nodes -eq 0) { throw 'selector controls not exercised' }
Write-Output ("PASS ledger AST selection identity/order checks={0} selectedNodes={1} trackedInventory={2} originalMs={3:N1} compiledMs={4:N1}; no timing gate" -f $checks,$nodes,$paths.Count,$originalTime.TotalMilliseconds,$compiledTime.TotalMilliseconds)
