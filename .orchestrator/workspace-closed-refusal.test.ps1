$ErrorActionPreference = 'Stop'
$verifier = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'invoke-heavy-verifier.ps1'))
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($verifier, [ref]$null, [ref]$errors)
if ($errors.Count) { throw 'actual verifier must parse' }
$guards = @($ast.EndBlock.Statements | Where-Object {
  $_ -is [Management.Automation.Language.IfStatementAst] -and
    $_.Clauses[0].Item1.Extent.Text -ceq '-not $isManifestReplay'
})
if ($guards.Count -ne 1) { throw 'expected one actual early closed-route guard' }
$guard = [scriptblock]::Create("[CmdletBinding()]`nparam([string]`$WorkspaceDbTest)`n`$isManifestReplay = `$false`n" + $guards[0].Extent.Text)
$fixture = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'workspace-db-test.test.ps1'))
$fixtureAst = [Management.Automation.Language.Parser]::ParseInput($fixture, [ref]$null, [ref]$errors)
if ($errors.Count) { throw 'ordinary workspace DB test must parse' }
$cases = @($fixtureAst.FindAll({ param($node)
  $node -is [Management.Automation.Language.HashtableAst] -and
    $node.Extent.Text.StartsWith("@{Name='unknown-workspace';", [StringComparison]::Ordinal)
}, $true))
if ($cases.Count -ne 1) { throw 'expected one actual unknown-workspace fixture case' }
$case = $cases[0].SafeGetValue()
if ($case.Extra[0] -cne '-WorkspaceDbTest') { throw 'unknown-workspace case must target the DB route' }
$reason = $null
try { & $guard -WorkspaceDbTest $case.Extra[1] } catch { $reason = $_.Exception.Message }
if ($reason -cne 'heavy-verifier: invalid closed route value') { throw 'actual guard must reject the foreign workspace with its exact closed refusal' }
if ($reason -notmatch [regex]::Escape($case.Text)) { throw 'actual early refusal must match the ordinary fixture diagnostic' }
foreach ($invalid in @('', '@chase-sets/payments-extra', '@CHASE-SETS/PAYMENTS')) {
  $reason = $null
  try { & $guard -WorkspaceDbTest $invalid } catch { $reason = $_.Exception.Message }
  if ($reason -cne 'heavy-verifier: invalid closed route value') { throw 'empty, prefix and case variants must remain closed' }
}
& $guard -WorkspaceDbTest '@chase-sets/payments'
Write-Output 'PASS actual early guard refuses unknown/empty/prefix/case workspaces, accepts exact Payments and matches the ordinary diagnostic; no admission or child'
