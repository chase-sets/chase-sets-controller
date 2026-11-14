$ErrorActionPreference = 'Stop'
$source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'long-product-gate.test.ps1'))
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$errors)
if ($errors.Count) { throw 'ordinary long-gate test must parse' }
foreach ($name in @('Assert-True', 'Invoke-CheckedGit', 'Write-Text', 'New-ControllerScriptFixture', 'New-LongGateFixture')) {
  $definition = @($ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
  }, $true))
  if ($definition.Count -ne 1) { throw "expected one actual fixture helper: $name" }
  . ([scriptblock]::Create($definition[0].Extent.Text))
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('long-gate-fixture-' + [guid]::NewGuid().ToString('N'))
try {
  $controllerRoot = Join-Path $root 'controller'
  $runtime = Join-Path $controllerRoot '.orchestrator'
  [void][IO.Directory]::CreateDirectory($runtime)
  Invoke-CheckedGit $controllerRoot @('init', '--initial-branch=synthetic/parent') | Out-Null
  Invoke-CheckedGit $controllerRoot @('config', 'user.name', 'Long Gate Fixture Test') | Out-Null
  Invoke-CheckedGit $controllerRoot @('config', 'user.email', 'long-gate-fixture@example.invalid') | Out-Null
  Write-Text (Join-Path $controllerRoot 'parent.txt') 'parent'
  Invoke-CheckedGit $controllerRoot @('add', '--', 'parent.txt') | Out-Null
  Invoke-CheckedGit $controllerRoot @('commit', '-m', 'parent') | Out-Null
  $before = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'invoke-heavy-verifier.ps1'))
  [IO.File]::WriteAllText((Join-Path $runtime 'invoke-heavy-verifier.ps1'), $before)
  $fixture = Join-Path $controllerRoot 'fixture'
  [void][IO.Directory]::CreateDirectory($fixture)
  $copiedRuntime = New-ControllerScriptFixture $fixture
  $after = [IO.File]::ReadAllText((Join-Path $copiedRuntime 'invoke-heavy-verifier.ps1'))
  $copiedAst = [Management.Automation.Language.Parser]::ParseInput($after, [ref]$null, [ref]$errors)
  Assert-True (-not $errors.Count) 'copied verifier remains valid PowerShell'
  $injections = @($copiedAst.EndBlock.Statements | Where-Object {
    $_ -is [Management.Automation.Language.IfStatementAst] -and
      $_.Clauses[0].Item1.Extent.Text -ceq '$Gate -ceq ''test:scripts''' -and
      $_.Extent.Text.Contains('fixture-heavy-child.ps1')
  })
  Assert-True ($injections.Count -eq 1) 'exactly one inert test-scripts command injection'
  $ownerGate = @($copiedAst.EndBlock.Statements | Where-Object {
    $_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -ceq '$ownerGate'
  })
  Assert-True ($ownerGate.Count -eq 1 -and $injections[0].Extent.EndOffset -lt $ownerGate[0].Extent.StartOffset) 'fixture command is set before owner gate and admission'
  $withoutInjection = $after.Remove($injections[0].Extent.StartOffset, $ownerGate[0].Extent.StartOffset - $injections[0].Extent.StartOffset)
  Assert-True ($withoutInjection.Replace("`r`n", "`n") -ceq $before.Replace("`r`n", "`n")) 'all real verifier bytes other than the fixture injection are preserved'
  Assert-True ([IO.File]::Exists((Join-Path $copiedRuntime 'fixture-heavy-child.ps1'))) 'inert child script is materialized but never launched'
  Write-Output 'PASS actual long-gate fixture initialization at current verifier seam; command injected once, remaining verifier preserved; no child or admission run'
  . (Join-Path $PSScriptRoot 'dispatch-ownership.ps1')
  $lanes = @('lane-24', 'lane-25', 'lane-26' | ForEach-Object { New-LongGateFixture $fixture $_ })
  $snapshot = Get-DispatchGitIdentitySnapshot @($lanes.worktree) $fixture
  foreach ($lane in $lanes) {
    $identity = $snapshot[(Get-DispatchCanonicalExistingPath $lane.worktree)]
    Assert-True ($identity.status -ceq 'ok' -and $identity.head -ceq $lane.head -and $identity.branch -ceq $lane.branch) 'actual batch census finds the exact fixture lane under a repository ancestor'
  }
  $unregistered = Join-Path $fixture 'unregistered'
  [void][IO.Directory]::CreateDirectory($unregistered)
  Invoke-CheckedGit $unregistered @('init', '--initial-branch=synthetic/unregistered') | Out-Null
  Invoke-CheckedGit $unregistered @('config', 'user.name', 'Long Gate Fixture Test') | Out-Null
  Invoke-CheckedGit $unregistered @('config', 'user.email', 'long-gate-fixture@example.invalid') | Out-Null
  Write-Text (Join-Path $unregistered 'seed.txt') 'unregistered'
  Invoke-CheckedGit $unregistered @('add', '--', 'seed.txt') | Out-Null
  Invoke-CheckedGit $unregistered @('commit', '-m', 'unregistered') | Out-Null
  $refused = Get-DispatchGitIdentitySnapshot @($unregistered) $fixture
  Assert-True ($refused[(Get-DispatchCanonicalExistingPath $unregistered)].status -ceq 'failed') 'actual batch census still refuses an unregistered standalone repository'
  Write-Output 'PASS actual batch census binds every fixture lane and refuses unregistered repositories; no child or admission run'
} finally {
  $resolved = [IO.Path]::GetFullPath($root)
  if ((Split-Path -Parent $resolved).TrimEnd('\','/') -cne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/') -or (Split-Path -Leaf $resolved) -notlike 'long-gate-fixture-*') { throw 'unsafe fixture cleanup' }
  if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
