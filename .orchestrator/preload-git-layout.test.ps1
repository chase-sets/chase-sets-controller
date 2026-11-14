$ErrorActionPreference = 'Stop'
function Get-FixtureFunction([string]$Path, [string]$Name) {
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
  $found = @($ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $Name
  }, $true))
  if ($errors.Count -or $found.Count -ne 1) { throw "expected unique parsed function: $Name" }
  return $found[0]
}
$fixture = Join-Path $PSScriptRoot 'heavy-admission-preload.test.ps1'
foreach ($name in @('Invoke-RepoGit', 'Initialize-AdmissionGitFixtures')) {
  . ([scriptblock]::Create((Get-FixtureFunction $fixture $name).Extent.Text))
}
. ([scriptblock]::Create((Get-FixtureFunction (Join-Path $PSScriptRoot 'dispatch-ownership.ps1') 'Get-DispatchGitIdentitySnapshot').Extent.Text))
# Only native canonical-path plumbing is inert. The unchanged production
# snapshot and real fixture setup use actual Git; no admission helper is run.
function Get-DispatchCanonicalRoot([string]$Path) { return [IO.Path]::GetFullPath($Path).TrimEnd('\', '/') }
function Get-DispatchCanonicalExistingPath([string]$Path) {
  if (Test-Path -LiteralPath $Path) { return Get-DispatchCanonicalRoot $Path }
  return $null
}
function Get-DispatchGitIdentity { throw 'unexpected per-candidate Git fallback' }
$root = Join-Path ([IO.Path]::GetTempPath()) ('preload-git-layout-' + [guid]::NewGuid().ToString('N'))
try {
  $container = Join-Path $root 'container with spaces'
  $laneA = Join-Path $container 'lane-a'
  $laneB = Join-Path $container 'lane-b'
  foreach ($path in @($laneA, $laneB)) { [void][IO.Directory]::CreateDirectory($path) }
  Initialize-AdmissionGitFixtures $container @($laneA, $laneB)
  $derived = Join-Path $container 'derived-lane'
  Invoke-RepoGit $laneA @('worktree', 'add', '-b', 'codex/derived-lane', $derived) | Out-Null
  $role = Get-FixtureFunction $fixture 'Test-PreloadRoleEligibility'
  $head = @($role.Body.EndBlock.Statements | Where-Object {
    $_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -ceq '$head'
  })
  if ($head.Count -ne 1) { throw 'expected role setup boundary before native admission' }
  $prefix = @($role.Body.EndBlock.Statements | Where-Object {
    $_.Extent.EndOffset -lt $head[0].Extent.StartOffset
  } | ForEach-Object { $_.Extent.Text }) -join "`n"
  function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
  . ([scriptblock]::Create($prefix))
  $requested = @((Join-Path $container 'main'), $laneA, $laneB, $derived, $tree)
  $snapshot = Get-DispatchGitIdentitySnapshot $requested $container
  foreach ($path in $requested) {
    $branch = Invoke-RepoGit $path @('branch', '--show-current')
    $commit = Invoke-RepoGit $path @('rev-parse', 'HEAD')
    $entry = $snapshot[$path]
    if ($entry.status -cne 'ok' -or $entry.worktree -cne $path -or
        $entry.branch -cne $branch -or $entry.head -cne $commit) { throw "fixture absent or mismatched in real registry: $path" }
  }
  $clone = Join-Path $container 'independent-review-clone'
  Invoke-RepoGit $laneA @('clone', '--quiet', $laneA, $clone) | Out-Null
  $missing = Get-DispatchGitIdentitySnapshot @($derived, $clone) $container
  if ($missing[$derived].status -cne 'ok' -or $missing[$clone].status -cne 'failed') { throw 'independent-clone omission control did not fail closed' }
  $bad = Join-Path $root 'original-layout'
  $badMain = Join-Path $bad 'main'
  $badLane = Join-Path $bad 'lane-a'
  $badDerived = Join-Path $bad 'derived-lane'
  foreach ($path in @($badMain, $badLane)) { [void][IO.Directory]::CreateDirectory($path) }
  Invoke-RepoGit $badLane @('init', '--initial-branch=codex/lane-a') | Out-Null
  Invoke-RepoGit $badLane @('-c', 'user.name=Inert fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--allow-empty', '-m', 'original layout') | Out-Null
  Invoke-RepoGit $badLane @('worktree', 'add', '-b', 'codex/derived-lane', $badDerived) | Out-Null
  Invoke-RepoGit $badMain @('init', '--initial-branch=synthetic-passthrough') | Out-Null
  $unborn = Get-DispatchGitIdentitySnapshot @($badDerived) $bad
  if ($unborn[$badDerived].status -cne 'failed') { throw 'original independent unborn-main layout did not fail closed' }
  Write-Output 'PASS actual preload main/two lanes/derived/review setup matches Git snapshot; unborn-main and independent-clone controls refused; no native admission'
} finally {
  $full = [IO.Path]::GetFullPath($root)
  $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
  if ((Split-Path -Parent $full).TrimEnd('\', '/') -cne $temp -or
      (Split-Path -Leaf $full) -notlike 'preload-git-layout-*') { throw 'unsafe owned fixture cleanup' }
  if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
}
