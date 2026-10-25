param([switch]$ValidatorOnly)
$ErrorActionPreference = 'Stop'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('dispatch-lane-installed-claude-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
  $fixture = Join-Path $PSScriptRoot 'fixtures/claude-help/help.txt'
  $manifest = Join-Path $PSScriptRoot 'fixtures/claude-help/README.md'
  if (-not (Test-Path -LiteralPath $fixture -PathType Leaf) -or -not (Test-Path -LiteralPath $manifest -PathType Leaf)) { throw 'CLAUDE_HELP_FIXTURE: pinned help fixture is missing' }
  $expected = Get-Content -Raw -LiteralPath $fixture
  $hash = (Get-FileHash -LiteralPath $fixture -Algorithm SHA256).Hash.ToLowerInvariant()
  if ((Get-Content -Raw -LiteralPath $manifest) -notmatch [regex]::Escape($hash)) { throw 'CLAUDE_HELP_FIXTURE: manifest hash mismatch' }
  if ($ValidatorOnly) { Write-Output "PASS installed Claude fixture validator fixtureSha256=$hash"; return }
  $prompt = Join-Path $testRoot 'prompt.txt'; Set-Content -LiteralPath $prompt -Value 'fixture prompt'
  $worktree = Join-Path $testRoot 'worktree'; New-Item -ItemType Directory -Path $worktree | Out-Null
  & git -C $worktree init -q --initial-branch=fixture
  & git -C $worktree config user.name fixture
  & git -C $worktree config user.email fixture@example.invalid
  Set-Content -LiteralPath (Join-Path $worktree 'seed.txt') -Value seed
  & git -C $worktree add seed.txt; & git -C $worktree commit -qm seed
  $fake = Join-Path $testRoot 'fake.exe'; Set-Content -LiteralPath $fake -Value ''
  $plan = & pwsh -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'dispatch-lane.ps1') -Harness claude -Model claude-opus-5-5 -Effort xhigh -Row 7 -Placement provisional -LaneRole implementation -PromptFile $prompt -Worktree $worktree -Label fixture -DryRun -ExecutablePath $fake | ConvertFrom-Json
  $claude = Get-Command claude -CommandType Application -ErrorAction Stop | Select-Object -First 1
  $out = Join-Path $testRoot 'help.out'; $err = Join-Path $testRoot 'help.err'
  $p = Start-Process -FilePath $claude.Source -ArgumentList @($plan.arguments + '--help') -WindowStyle Hidden -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
  $p.WaitForExit()
  if ($p.ExitCode -ne 0) { throw "CLAUDE_HELP_FIXTURE: installed Claude --help exit $($p.ExitCode)" }
  $actual = Get-Content -Raw -LiteralPath $out
  if ($actual -notmatch '--disallowedTools') { throw 'CLAUDE_HELP_FIXTURE: hosted option check missing --disallowedTools' }
  Write-Output "PASS installed Claude hosted help option check fixtureSha256=$hash"
} finally {
  if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
