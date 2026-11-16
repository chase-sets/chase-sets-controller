$ErrorActionPreference = 'Stop'
function Assert-True($Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

$source = Get-Content (Join-Path $PSScriptRoot 'heavy-admission-preload.test.ps1') -Raw
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) 'preload suite parses'
$outer = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })
Assert-True ($outer.Count -eq 1) 'one outer routing-scope try'
$outer = $outer[0]
$nativeTry = $outer.Finally.Statements[0]
Assert-True ($nativeTry -is [Management.Automation.Language.TryStatementAst]) 'native guard retains unconditional routing-scope cleanup'
$nativeBody = $nativeTry.Body
if ($nativeBody.Statements[0] -is [Management.Automation.Language.IfStatementAst]) {
  $nativeBody = $nativeBody.Statements[0].Clauses[0].Item2
}
$initializers = @($ast.EndBlock.Statements | Where-Object {
  $_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -ceq '$admissionFailure'
})
$initializer = ($initializers | ForEach-Object { $_.Extent.Text }) -join "`n"

# Run the real catch/finally control flow with inert bodies, not the fixture's
# process launch/stop paths. A setup failure occurs before the helper exists.
$body = @'
{
  if ($Scenario -ceq 'setup-failure') { throw 'original setup failure' }
  function Invoke-InertNativeGuard {
    if ($Scenario -ceq 'guard-failure') { throw 'native guard failure' }
    $state.guards++
  }
  if ($Scenario -ceq 'body-failure') { throw 'original body failure' }
  if ($Scenario -ceq 'selector-return') { return 'selected' }
}
'@
$guard = '{ $state.guardAttempts++; Invoke-InertNativeGuard }'
$control = $outer.Extent.Text
foreach ($replacement in @(
    @{ extent = $nativeBody.Extent; text = $guard },
    @{ extent = $outer.Body.Extent; text = $body }
  ) | Sort-Object { $_.extent.StartOffset } -Descending) {
  $offset = $replacement.extent.StartOffset - $outer.Extent.StartOffset
  $control = $control.Remove($offset, $replacement.extent.EndOffset - $replacement.extent.StartOffset).Insert($offset, $replacement.text)
}
$control = [scriptblock]::Create("$initializer`n$control")
foreach ($Scenario in @('setup-failure', 'body-failure', 'success', 'selector-return', 'guard-failure')) {
  $state = @{ cleanup = 0; guards = 0; guardAttempts = 0 }
  $observed = $null
  $output = @()
  $admissionFailure = 'inherited failure'
  function Exit-RoutingDataTestScope($Scope) { $state.cleanup++ }
  try { $output = @(& $control) } catch { $observed = $_.Exception.Message }
  Assert-True ($state.cleanup -eq 1) "$Scenario restores routing scope once"
  switch ($Scenario) {
    'setup-failure' {
      Assert-True ($observed -ceq 'original setup failure') 'setup failure is not masked by an undefined native-guard helper'
      Assert-True ($state.guardAttempts -eq 0) 'failed setup does not start secondary native guard proof'
    }
    'body-failure' {
      Assert-True ($observed -ceq 'original body failure') 'body failure remains the reported error'
      Assert-True ($state.guardAttempts -eq 0) 'failed body does not start secondary native guard proof'
    }
    'guard-failure' {
      Assert-True ($observed -ceq 'native guard failure' -and $state.guardAttempts -eq 1) 'native guard failure still fails an otherwise successful suite'
    }
    default {
      Assert-True ($null -eq $observed -and $state.guards -eq 1) "$Scenario still executes native guard proof"
      if ($Scenario -ceq 'selector-return') {
        Assert-True ($output.Count -eq 1 -and $output[0] -ceq 'selected') 'selector return survives finalization'
      }
    }
  }
  Write-Host "PASS preload finalizer $Scenario"
}
