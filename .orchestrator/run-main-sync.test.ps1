[CmdletBinding()]
param([string]$SourcePath = (Join-Path $PSScriptRoot 'run-main-sync.ps1'), [switch]$FailureOnly)
$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('main-sync-test-' + [guid]::NewGuid().ToString('N'))
$powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
function Assert-Sync($Value, [string]$Message) { if (-not $Value) { throw "ASSERTION FAILED: $Message" } }
function Git([string]$Directory, [string[]]$Arguments) {
  $result = @(& git.exe -C $Directory @Arguments 2>&1)
  if ($LASTEXITCODE) { throw "fixture git failed: $($result -join ' ')" }
  return ($result -join "`n")
}
function Run-Sync([string]$Probe = 'empty') {
  $wrapper = Join-Path $root 'runner.ps1'
  $mock = switch ($Probe) {
    'busy' { "function Get-CimInstance { [pscustomobject]@{ProcessId=123} }" }
    'unknown' { "function Get-CimInstance { throw 'process inventory unavailable' }" }
    default { 'function Get-CimInstance { }' }
  }
  [IO.File]::WriteAllText($wrapper, $mock + "`n& '$($source.Replace("'","''"))' -ProjectRoot '$($root.Replace("'","''"))' -MutexName 'main-sync-test-$([guid]::NewGuid().ToString('N'))'`nexit `$LASTEXITCODE", [Text.UTF8Encoding]::new($false))
  $output = @(& $powershell -NoProfile -NonInteractive -File $wrapper 2>&1)
  return [pscustomobject]@{code=$LASTEXITCODE; output=($output -join "`n")}
}
function Plant-Lock([int]$Minutes) {
  [IO.File]::WriteAllText($script:lockPath, '')
  [IO.File]::SetCreationTimeUtc($script:lockPath, [DateTime]::UtcNow.AddMinutes(-$Minutes))
  [IO.File]::SetLastWriteTimeUtc($script:lockPath, [DateTime]::UtcNow.AddMinutes(-$Minutes))
}
try {
  [void][IO.Directory]::CreateDirectory((Join-Path $root '.orchestrator'))
  $source = Join-Path $root '.orchestrator/run-main-sync.ps1'
  Copy-Item -LiteralPath $SourcePath -Destination $source
  if ($FailureOnly) {
    [IO.File]::WriteAllText((Join-Path $root 'UPDATE_MAIN_FROM_ORIGIN.ps1'), 'exit 17')
    $r = Run-Sync
    Assert-Sync ($r.code -eq 17) "sync failure reaches task: expected17 actual=$($r.code)"
    'PASS sync failure reaches task'
    return
  }
  $remote = Join-Path $root 'remote.git'; [void][IO.Directory]::CreateDirectory($remote)
  Git $remote @('init','--bare','--initial-branch=main') | Out-Null
  $seed = Join-Path $root 'seed'; [void][IO.Directory]::CreateDirectory($seed)
  Git $seed @('init','--initial-branch=main') | Out-Null
  Git $seed @('config','user.email','fixture@example.invalid') | Out-Null
  Git $seed @('config','user.name','Fixture') | Out-Null
  [IO.File]::WriteAllText((Join-Path $seed 'value.txt'), 'first')
  Git $seed @('add','value.txt') | Out-Null; Git $seed @('commit','-m','first') | Out-Null
  Git $seed @('remote','add','origin',$remote) | Out-Null; Git $seed @('push','origin','main') | Out-Null
  Git $root @('clone',$remote,'main') | Out-Null
  $main = Join-Path $root 'main'
  $first = Git $main @('rev-parse','HEAD')
  [IO.File]::WriteAllText((Join-Path $seed 'value.txt'), 'second')
  Git $seed @('add','value.txt') | Out-Null; Git $seed @('commit','-m','second') | Out-Null
  Git $seed @('push','origin','main') | Out-Null
  $second = Git $seed @('rev-parse','HEAD')
  $updater = Join-Path $root 'UPDATE_MAIN_FROM_ORIGIN.ps1'
  # Exercise the real worker with a finite, non-destructive updater in a real
  # disposable Git repository; never run the product updater or change ACLs.
  [IO.File]::WriteAllText($updater, @'
$main = Join-Path $PSScriptRoot 'main'
git -C $main fetch origin
if ($LASTEXITCODE) { exit $LASTEXITCODE }
git -C $main merge --ff-only origin/main
exit $LASTEXITCODE
'@, [Text.UTF8Encoding]::new($false))
  $script:lockPath = Join-Path $main '.git/index.lock'
  Plant-Lock 1
  $r = Run-Sync
  Assert-Sync ($r.code -eq 0 -and (Test-Path $lockPath) -and (Git $main @('rev-parse','HEAD')) -ceq $first) 'fresh lock is retained and sync skipped'
  Plant-Lock 20
  [IO.File]::SetLastWriteTimeUtc($script:lockPath, [DateTime]::UtcNow)
  $r = Run-Sync
  Assert-Sync ($r.code -eq 0 -and (Test-Path $lockPath) -and (Git $main @('rev-parse','HEAD')) -ceq $first) 'recently modified old lock is retained'
  Plant-Lock 20
  $r = Run-Sync 'busy'
  Assert-Sync ($r.code -eq 0 -and (Test-Path $lockPath) -and (Git $main @('rev-parse','HEAD')) -ceq $first) 'running Git process retains old lock and skips'
  $r = Run-Sync 'unknown'
  Assert-Sync ($r.code -ne 0 -and (Test-Path $lockPath)) 'unknown process inventory fails closed with nonzero status'
  $held = [IO.File]::Open($lockPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
  try { $r = Run-Sync } finally { $held.Dispose() }
  Assert-Sync ($r.code -eq 0 -and (Test-Path $lockPath) -and (Git $main @('rev-parse','HEAD')) -ceq $first) 'open lock is retained even with no observed Git process'
  $r = Run-Sync
  Assert-Sync ($r.code -eq 0 -and -not (Test-Path $lockPath) -and (Git $main @('rev-parse','HEAD')) -ceq $second) 'stale unused lock is removed and actual repository fast-forwards'
  $statusPath = Join-Path $root '.orchestrator/main-sync-status.json'
  $status = Get-Content $statusPath -Raw | ConvertFrom-Json
  Assert-Sync ($status.outcome -ceq 'success' -and $status.lastSuccessAt -and -not $status.lastError) 'successful sync records timestamp and clears last error'
  $lastSuccess = $status.lastSuccessAt
  [IO.File]::WriteAllText($updater, "[Console]::Error.WriteLine('synthetic sync failure'); exit 17")
  $r = Run-Sync
  $status = Get-Content $statusPath -Raw | ConvertFrom-Json
  Assert-Sync ($r.code -eq 17 -and $status.outcome -ceq 'failed' -and $status.lastError -match 'code 17' -and $status.lastSuccessAt -ceq $lastSuccess) 'child failure reaches scheduled-task exit and preserves last success with error'
  Assert-Sync ((Get-Content $statusPath).Count -eq 1) 'status is one-line JSON'
  Assert-Sync ((Get-Content (Join-Path $root '.orchestrator/main-sync.log') -Raw).Contains('synthetic sync failure')) 'actual child error remains in log'
  $vbs = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'run-main-sync.vbs'))
  Assert-Sync ($vbs.Contains('WScript.Quit exitCode')) 'scheduled VBS launcher propagates worker exit unchanged'
  'PASS main sync: real stale-lock fast-forward, fresh/busy/unknown refusal, exact child exit and durable one-line status; production updater NOT_RUN'
} finally {
  $parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
  Assert-Sync ((Split-Path -Parent ([IO.Path]::GetFullPath($root))) -ceq $parent) 'cleanup stays inside owned temporary root'
  if (Test-Path $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
