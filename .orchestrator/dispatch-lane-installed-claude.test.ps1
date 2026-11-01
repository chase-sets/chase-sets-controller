param(
  [ValidateSet('portable','local-smoke')][string]$Part = '',
  [switch]$ValidatorOnly
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'suite-parts.ps1')
Assert-SuiteSelection $Part @('portable','local-smoke') $PSBoundParameters @()
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('dispatch-lane-installed-claude-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
  $fixture = Join-Path $PSScriptRoot 'fixtures/claude-help/help.txt'
  $manifest = Join-Path $PSScriptRoot 'fixtures/claude-help/README.md'
  if (-not $Part -or $Part -ceq 'portable') {
    if (-not (Test-Path -LiteralPath $fixture -PathType Leaf) -or -not (Test-Path -LiteralPath $manifest -PathType Leaf)) { throw 'CLAUDE_HELP_FIXTURE: pinned help fixture is missing' }
    $expected = Get-Content -Raw -LiteralPath $fixture
    $hash = (Get-FileHash -LiteralPath $fixture -Algorithm SHA256).Hash.ToLowerInvariant()
    if ((Get-Content -Raw -LiteralPath $manifest) -notmatch [regex]::Escape($hash)) { throw 'CLAUDE_HELP_FIXTURE: manifest hash mismatch' }
    if ($ValidatorOnly) { Write-Output "PASS installed Claude fixture validator fixtureSha256=$hash"; return }
  } else {
    if (-not (Test-Path -LiteralPath $fixture -PathType Leaf)) { throw 'CLAUDE_HELP_FIXTURE: pinned help fixture is missing' }
    $expected = Get-Content -Raw -LiteralPath $fixture
    $hash = (Get-FileHash -LiteralPath $fixture -Algorithm SHA256).Hash.ToLowerInvariant()
  }
  $prompt = Join-Path $testRoot 'prompt.txt'; Set-Content -LiteralPath $prompt -Value 'fixture prompt'
  $worktree = Join-Path $testRoot 'worktree'; New-Item -ItemType Directory -Path $worktree | Out-Null
  & git -C $worktree init -q --initial-branch=fixture
  & git -C $worktree config user.name fixture
  & git -C $worktree config user.email fixture@example.invalid
  Set-Content -LiteralPath (Join-Path $worktree 'seed.txt') -Value seed
  & git -C $worktree add seed.txt; & git -C $worktree commit -qm seed
  $fake = Join-Path $testRoot 'fake.exe'; Set-Content -LiteralPath $fake -Value ''
  if (-not $Part -or $Part -ceq 'portable') {
    # Poison native Claude lookup before the hosted plan and proof. The only
    # executable accepted by dispatch-lane is this inert test override; a live
    # Get-Command claude or launch in this part must fail closed.
    $gitExe = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $oldPath = $env:PATH
    try {
      $env:PATH = "$(Split-Path -Parent $gitExe);$PSHOME;$testRoot"
      $plan = & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'dispatch-lane.ps1') -Harness claude -Model claude-opus-5-5 -Effort xhigh -Row 7 -Placement provisional -LaneRole implementation -PromptFile $prompt -Worktree $worktree -Label fixture -DryRun -ExecutablePath $fake | ConvertFrom-Json
      $options = @($plan.arguments | Where-Object { $_ -is [string] -and $_ -cmatch '^--[A-Za-z][A-Za-z0-9-]*$' } | Select-Object -Unique)
      $options += '--disallowedTools'
      foreach ($option in @($options | Select-Object -Unique)) {
        if ($expected -notmatch "(?m)^$([regex]::Escape([string]$option))$" -and
            $expected -notmatch "(?m)^$([regex]::Escape([string]$option))\s") {
          throw "CLAUDE_HELP_FIXTURE: pinned help fixture lacks Claude argv option $option"
        }
      }
    } finally {
      $env:PATH = $oldPath
    }
    Write-Output "PASS hosted Claude help fixture argv options checked fixtureSha256=$hash"
  }
  if (-not $Part -or $Part -ceq 'local-smoke') {
    $plan = & pwsh -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'dispatch-lane.ps1') -Harness claude -Model claude-opus-5-5 -Effort xhigh -Row 7 -Placement provisional -LaneRole implementation -PromptFile $prompt -Worktree $worktree -Label fixture -DryRun -ExecutablePath $fake | ConvertFrom-Json
    $claude = Get-Command claude -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $out = Join-Path $testRoot 'help.out'; $err = Join-Path $testRoot 'help.err'
    $p = Start-Process -FilePath $claude.Source -ArgumentList @($plan.arguments + '--help') -WindowStyle Hidden -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) { throw "CLAUDE_HELP_FIXTURE: installed Claude --help exit $($p.ExitCode)" }
    $actual = Get-Content -Raw -LiteralPath $out
    if ($actual -notmatch '--disallowedTools') { throw 'CLAUDE_HELP_FIXTURE: hosted option check missing --disallowedTools' }
    # Bind the pinned fixture to the installed CLI: every option the hosted
    # part trusts must be documented by the real --help output.
    $fixtureOptions = @([regex]::Matches($expected, '(?m)^(--[A-Za-z][A-Za-z0-9-]*)\s*$') | ForEach-Object { $_.Groups[1].Value })
    if ($fixtureOptions.Count -eq 0) { throw 'CLAUDE_HELP_FIXTURE: pinned help fixture lists no options' }
    foreach ($option in $fixtureOptions) {
      if ($actual -notmatch "(?m)^\s*(-[A-Za-z], )?$([regex]::Escape($option))(\s|,|=|$)") {
        throw "CLAUDE_HELP_FIXTURE: installed Claude --help does not document fixture option $option"
      }
    }
    Write-Output "PASS installed Claude hosted help option check fixtureSha256=$hash"
  }
} finally {
  if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
