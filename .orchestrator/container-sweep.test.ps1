[CmdletBinding()]param([string]$EvidenceRoot = [IO.Path]::GetTempPath(), [switch]$KeepEvidence)
$ErrorActionPreference = 'Stop'
[Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal'
. (Join-Path $PSScriptRoot 'container-sweep.ps1')
$root = Join-Path ([IO.Path]::GetFullPath($EvidenceRoot)) ('container-sweep-test-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
$script:passed = 0
function Assert-Sweep([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "ASSERTION FAILED: $Message" } }
function Pass([string]$Name) { $script:passed++; Write-Output "PASS $Name" }
function Invoke-TestGit([string]$At, [string[]]$Arguments) {
  $out = @(& git -c user.name=sweep-test -c user.email=sweep-test@localhost -c core.autocrlf=false -C $At @Arguments 2>&1)
  if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $($out -join "`n")" }
  (@($out) -join "`n").Trim()
}
function Write-TestFile([string]$Path, [string]$Text) { [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path)); [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false)) }
function Set-TestAge([string]$Path, [double]$Hours) {
  $when = [datetime]::UtcNow.AddHours(-$Hours)
  $options = [IO.EnumerationOptions]@{ AttributesToSkip = 0; RecurseSubdirectories = $true; IgnoreInaccessible = $false }
  foreach ($entry in @([IO.DirectoryInfo]::new($Path).EnumerateFileSystemInfos('*', $options))) {
    if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
    $entry.LastWriteTimeUtc = $when
  }
  [IO.Directory]::SetLastWriteTimeUtc($Path, $when)
  $dotGit = Join-Path $Path '.git'
  if ([IO.File]::Exists($dotGit) -and ([IO.File]::ReadAllText($dotGit).Trim() -match '^gitdir:\s*(?<dir>.+)$')) {
    $admin = $Matches.dir.Trim()
    foreach ($name in @('HEAD', 'index', 'logs\HEAD')) { $file = Join-Path $admin $name; if ([IO.File]::Exists($file)) { [IO.File]::SetLastWriteTimeUtc($file, $when) } }
  }
}
function Set-TestRefAge([string]$Repository, [string]$Branch, [double]$Hours) {
  $common = Invoke-TestGit $Repository @('rev-parse', '--git-common-dir'); if (-not [IO.Path]::IsPathRooted($common)) { $common = Join-Path $Repository $common }
  [IO.File]::SetLastWriteTimeUtc((Join-Path $common ('logs\refs\heads\' + $Branch.Replace('/', '\'))), [datetime]::UtcNow.AddHours(-$Hours))
}
function New-TestWorktree([string]$Repository, [string]$Name, [string[]]$Extra = @()) {
  $path = Join-Path $script:container $Name
  # Options precede the path and the commit-ish follows it.
  $options = @($Extra | Select-Object -SkipLast 1); $commitish = @($Extra | Select-Object -Last 1)
  Invoke-TestGit $Repository (@('worktree', 'add') + $options + @($path) + $commitish) | Out-Null
  $path
}
function Find-TestItem([object[]]$Items, [string]$Key) {
  @($Items | Where-Object { ($_.path -and (Split-Path -Leaf $_.path) -ceq $Key) -or $_.branch -ceq $Key -or $_.name -ceq $Key -or ($_.number -and "$($_.number)" -ceq $Key) })[0]
}
function Get-TestRow($Report, [string]$Phase, [string]$Key) { Find-TestItem @($Report.phases[$Phase].rows) $Key }
function Get-TestResult($Report, [string]$Phase, [string]$Key) { Find-TestItem @($Report.phases[$Phase].results) $Key }
function Assert-TestReasons($Report, [string]$Phase, [Collections.IDictionary]$Expected, [scriptblock]$Select) {
  foreach ($pair in $Expected.GetEnumerator()) {
    $row = if ($Select) { & $Select $Report $pair.Key } else { Get-TestRow $Report $Phase $pair.Key }
    Assert-Sweep ($null -ne $row -and $row.reasonCode -ceq $pair.Value) "$Phase $($pair.Key) expected $($pair.Value) actual $($row.reasonCode)"
  }
}
function New-TestPrNode([int]$Number, [string]$State, [string]$Head, [string]$Oid, [hashtable]$Extra = @{}) {
  $node = [ordered]@{ number = $Number; state = $State; isDraft = $false; title = "synthetic $Number"; headRefName = $Head; headRefOid = $Oid; baseRefName = 'main'
    updatedAt = [datetime]::UtcNow.AddDays(-30).ToString('o'); closedAt = $null; mergedAt = $null; labels = @{ nodes = @() }; closingIssuesReferences = @{ nodes = @() } }
  foreach ($key in $Extra.Keys) { $node[$key] = $Extra[$key] }
  [pscustomobject]$node
}
function Get-TestCensus {
  if ($script:censusBroken) { return ConvertTo-SweepPrCensus @() }
  $nodes = @($script:prs | ForEach-Object { $_ | ConvertTo-Json -Depth 8 | ConvertFrom-Json -DateKind String })
  $page = [pscustomobject]@{ data = [pscustomobject]@{ repository = [pscustomobject]@{ pullRequests = [pscustomobject]@{
          totalCount = $nodes.Count; nodes = $nodes; pageInfo = [pscustomobject]@{ hasNextPage = $false; endCursor = $null } } } } }
  ConvertTo-SweepPrCensus @($page)
}
function Get-TestResolvers {
  @{
    Ownership = { param($Runtime, $Temp, $Container) [pscustomobject]@{ health = [pscustomobject]@{ status = $script:ownershipStatus }; activeLanes = @($script:activeLanes) } }
    ProcessTexts = { @($script:processTexts) }
    PrCensus = { param($Repository) Get-TestCensus }
    Issues = { param([int[]]$Numbers) $h = @{}; foreach ($n in $Numbers) { $m = if ($script:issueMilestones.ContainsKey($n)) { $script:issueMilestones[$n] } else { 7001 }; $h[$n] = [pscustomobject]@{ number = $n; milestone = [pscustomobject]@{ number = $m } } }; $h }
    OpenPrCount = { param($Repository, $Branch) $script:openPrCount }
    PrView = { param($Number) $node = @($script:prs | Where-Object { $_.number -eq $Number })[0]; [pscustomobject]@{ state = $node.state; isDraft = $node.isDraft; headRefOid = $node.headRefOid; updatedAt = $node.updatedAt } }
    PrClose = { param($Number, $Comment) $script:closed.Add([pscustomobject]@{ number = $Number; comment = $Comment }); 0 }
    ScheduledTasks = { @($script:tasks) }
    UnregisterTask = { param($Name) $script:unregistered.Add($Name); $script:tasks = @($script:tasks | Where-Object { $_.name -cne $Name }) }
    Docker = { param([string[]]$Arguments, [int]$TimeoutMs) $script:dockerCalls.Add(($Arguments -join ' ')); & $script:dockerResponder $Arguments }
    SandboxGc = { param($ProductRoot) $script:dockerCalls.Add('sandbox-gc'); [pscustomobject]@{ exitCode = 0; stdout = 'gc ok'; stderr = '' } }
    StartHidden = { param($ScriptPath, $Arguments, $Out, $Err) $script:hidden.Add(($Arguments -join ' ')); [pscustomobject]@{ Id = 4242 } }
  }
}
function New-TestContext([string[]]$Phases) {
  $resolvers = Get-SweepDefaultResolvers
  $overrides = Get-TestResolvers
  foreach ($key in $overrides.Keys) { $resolvers[$key] = $overrides[$key] }
  New-SweepContext -ContainerRoot $script:container -Phases $Phases -Resolvers $resolvers
}
function Reset-TestState {
  $script:ownershipStatus = 'ok'; $script:activeLanes = @(); $script:processTexts = @('c:\windows\system32\svchost.exe'); $script:censusBroken = $false
  $script:issueMilestones = @{ 1010 = 7002; 4006 = 7002 }; $script:openPrCount = 0
  $script:closed = [Collections.Generic.List[object]]::new(); $script:unregistered = [Collections.Generic.List[string]]::new()
  $script:dockerCalls = [Collections.Generic.List[string]]::new(); $script:hidden = [Collections.Generic.List[string]]::new()
  $script:dockerResponder = { param($Arguments) [pscustomobject]@{ exitCode = 1; stdout = ''; stderr = 'synthetic docker down' } }
}
function Invoke-TestSweep([string[]]$Phases, [switch]$Apply, [scriptblock]$BeforeAct) {
  Invoke-ContainerSweep -ContainerRoot $script:container -Apply:$Apply -Phases $Phases -Resolvers (Get-TestResolvers) -BeforeAct $BeforeAct -ScriptPath (Join-Path $PSScriptRoot 'container-sweep.ps1')
}
try {
  [void][IO.Directory]::CreateDirectory($root)
  $script:container = Join-Path $root 'container'; $origin = Join-Path $root 'origin.git'
  [void][IO.Directory]::CreateDirectory($script:container)
  Invoke-TestGit $root @('init', '-q', '--bare', '-b', 'main', $origin) | Out-Null
  $product = Join-Path $script:container 'main'
  Invoke-TestGit $root @('clone', '-q', $origin, $product) | Out-Null
  Write-TestFile (Join-Path $product 'README.md') "product`n"
  Write-TestFile (Join-Path $product '.gitignore') "node_modules/`n"
  Invoke-TestGit $product @('add', '-A') | Out-Null; Invoke-TestGit $product @('commit', '-q', '-m', 'seed') | Out-Null
  Invoke-TestGit $product @('push', '-q', 'origin', 'HEAD:refs/heads/main') | Out-Null; Invoke-TestGit $product @('fetch', '-q', 'origin') | Out-Null
  Write-TestFile (Join-Path $script:container '.gitignore') "/*/`n!/.orchestrator/`n/.orchestrator/*`n"
  Invoke-TestGit $script:container @('init', '-q', '-b', 'main') | Out-Null
  Invoke-TestGit $script:container @('add', '.gitignore') | Out-Null; Invoke-TestGit $script:container @('commit', '-q', '-m', 'container seed') | Out-Null
  $runtime = Join-Path $script:container '.orchestrator'
  $registerText = @"
## 1. Ownership register
| Scope | Owner | Notes |
| --- | --- | --- |
| chase-sets milestone 7002 (Synthetic platform) | platform | synthetic, seat ``chase-sets/20260901-registered-seat`` |
| every other chase-sets milestone, issue, PR, worktree, and the merge queue | incumbent | synthetic |
## 2. Route
"@
  $registerPath = Join-Path $runtime 'platform-handoff.md'
  Write-TestFile $registerPath $registerText
  Write-TestFile (Join-Path $runtime 'dispatch-log.jsonl') ''
  Write-TestFile (Join-Path $runtime 'container-sweep.keep') "# synthetic`n20260901-keep-me`n"
  $base = Invoke-TestGit $product @('rev-parse', 'origin/main')

  # ------------------------------------------------------------ worktrees
  $wt = [ordered]@{}
  $wt.landed = New-TestWorktree $product '20260901-1001-landed' @('-b', 'codex/1001-landed', 'origin/main')
  $wt.unmerged = New-TestWorktree $product '20260901-1002-unmerged' @('-b', 'codex/1002-unmerged', 'origin/main')
  Write-TestFile (Join-Path $wt.unmerged 'feature.txt') "unique`n"; Invoke-TestGit $wt.unmerged @('add', '-A') | Out-Null; Invoke-TestGit $wt.unmerged @('commit', '-q', '-m', 'unique') | Out-Null
  $unmergedHead = Invoke-TestGit $wt.unmerged @('rev-parse', 'HEAD')
  $wt.dirty = New-TestWorktree $product '20260901-1003-dirty' @('-b', 'codex/1003-dirty', 'origin/main')
  Write-TestFile (Join-Path $wt.dirty 'README.md') "product changed`n"; Write-TestFile (Join-Path $wt.dirty 'notes\untracked.txt') "keep me`n"
  Write-TestFile (Join-Path $wt.dirty 'node_modules\pkg\index.js') "ignored`n"
  $wt.recent = New-TestWorktree $product '20260901-1004-recent' @('--detach', $unmergedHead)
  $wt.locked = New-TestWorktree $product '20260901-1005-locked' @('--lock', '--detach', 'origin/main')
  $wt.platform = New-TestWorktree $product '20260901-1006-platform-seat' @('--detach', 'origin/main')
  $wt.live = New-TestWorktree $product '20260901-1007-live' @('--detach', 'origin/main')
  $wt.openpr = New-TestWorktree $product '20260901-1008-openpr' @('-b', 'codex/1008-openpr', 'origin/main')
  $wt.dirtyrecent = New-TestWorktree $product '20260901-1009-dirtyrecent' @('--detach', 'origin/main')
  Write-TestFile (Join-Path $wt.dirtyrecent 'scratch.txt') "wip`n"
  $wt.lane = New-TestWorktree $product 'lane-01' @('--detach', 'origin/main')
  $wt.platformissue = New-TestWorktree $product '20260901-1010-milestone7002' @('--detach', 'origin/main')
  $wt.merged = New-TestWorktree $product '20260901-1011-merged' @('-b', 'codex/1011-merged', 'origin/main')
  Write-TestFile (Join-Path $wt.merged 'merged.txt') "merged`n"; Invoke-TestGit $wt.merged @('add', '-A') | Out-Null; Invoke-TestGit $wt.merged @('commit', '-q', '-m', 'merged head') | Out-Null
  $mergedHead = Invoke-TestGit $wt.merged @('rev-parse', 'HEAD')
  $wt.registered = New-TestWorktree $product '20260901-registered-seat' @('--detach', 'origin/main')
  $containerHead = Invoke-TestGit $script:container @('rev-parse', 'HEAD')
  $wt.controller = New-TestWorktree $script:container '20260901-controller-seat' @('--detach', $containerHead)
  $seatPath = Join-Path $runtime 'logs\synthetic\seat'
  Invoke-TestGit $script:container @('worktree', 'add', '--detach', $seatPath, $containerHead) | Out-Null
  foreach ($path in $wt.Values) { Set-TestAge $path 240 }
  Set-TestAge $seatPath 240
  Set-TestAge $wt.recent 10
  Set-TestAge $wt.dirtyrecent 72
  $openPrNode = New-TestPrNode 9001 'OPEN' 'codex/1008-openpr' ('e' * 40)
  $mergedNode = New-TestPrNode 9002 'MERGED' 'codex/1011-merged' $mergedHead
  $script:prs = @($openPrNode, $mergedNode)
  $productCount = @(Get-ReclamationWorktrees $product).Count
  $liveText = ('"pwsh.exe" -File "' + (Join-Path $wt.live 'scripts\task.ps1') + '"').ToLowerInvariant()

  Reset-TestState; $script:processTexts = @('c:\windows\system32\svchost.exe', $liveText)
  $report = Invoke-TestSweep @('worktrees')
  Assert-TestReasons $report 'worktrees' ([ordered]@{
      '20260901-1001-landed' = 'clean-in-base'; '20260901-1002-unmerged' = 'clean-unmerged-preserved'; '20260901-1003-dirty' = 'dirty-idle-snapshot'
      '20260901-1004-recent' = 'recent'; '20260901-1005-locked' = 'locked'; '20260901-1006-platform-seat' = 'platform-seat-suspected'; '20260901-1007-live' = 'live-owner'
      '20260901-1008-openpr' = 'open-pr-head'; '20260901-1009-dirtyrecent' = 'dirty-recent'; 'lane-01' = 'persistent-checkout'
      '20260901-1010-milestone7002' = 'platform-owned-milestone'; '20260901-1011-merged' = 'clean-merged-pr-head'; '20260901-registered-seat' = 'platform-register-named'
      '20260901-controller-seat' = 'clean-in-base'; 'seat' = 'recent'
    })
  Pass 'worktree-decisions-cover-every-reason'
  Assert-Sweep (@(Get-ReclamationWorktrees $product).Count -eq $productCount -and @($report.phases.worktrees.results).Count -eq 0) 'report mode never mutates'
  $adminBefore = Get-SweepAdminNewest $wt.landed
  $again = Invoke-TestSweep @('worktrees')
  Assert-Sweep ((Get-TestRow $again 'worktrees' '20260901-1001-landed').reasonCode -ceq 'clean-in-base' -and (Get-SweepAdminNewest $wt.landed) -eq $adminBefore) 'inventory does not refresh the index or reset idle'
  Pass 'report-mode-read-only-and-idle-stable'

  foreach ($status in @('partial', 'unknown')) {
    Reset-TestState; $script:ownershipStatus = $status
    $blocked = Invoke-TestSweep @('worktrees', 'branches', 'directories') -Apply
    foreach ($phaseName in @('worktrees', 'branches', 'directories')) {
      Assert-Sweep (@($blocked.phases[$phaseName].rows | Where-Object { $_.reasonCode -cne 'ownership-unknown' }).Count -eq 0) "ownership $status retains every $phaseName row"
    }
    Assert-Sweep (@(Get-ReclamationWorktrees $product).Count -eq $productCount) "ownership $status mutates nothing"
  }
  Reset-TestState; $script:censusBroken = $true
  $blocked = Invoke-TestSweep @('worktrees')
  Assert-Sweep (@($blocked.phases.worktrees.rows | Where-Object { $_.reasonCode -cne 'pr-census-unknown' }).Count -eq 0) 'incomplete PR census retains every worktree'
  Reset-TestState; Write-TestFile $registerPath 'malformed register'
  $blocked = Invoke-TestSweep @('worktrees')
  Assert-Sweep (@($blocked.phases.worktrees.rows | Where-Object { $_.reasonCode -cne 'register-unreadable' }).Count -eq 0) 'unreadable register retains every worktree'
  Write-TestFile $registerPath $registerText
  Reset-TestState; $launchFile = Join-Path $runtime 'dispatch-launch-synthetic.json'; Write-TestFile $launchFile '{'
  $blocked = Invoke-TestSweep @('worktrees')
  Assert-Sweep (@($blocked.phases.worktrees.rows | Where-Object { $_.reasonCode -cne 'ownership-unknown' }).Count -eq 0) 'unreadable launch record retains every worktree'
  Write-TestFile $launchFile (@{ worktree = $wt.landed; branch = 'codex/1001-landed' } | ConvertTo-Json -Compress)
  $launched = Invoke-TestSweep @('worktrees')
  Assert-Sweep ((Get-TestRow $launched 'worktrees' '20260901-1001-landed').reasonCode -ceq 'live-owner') 'launch record makes its worktree live'
  [IO.File]::Delete($launchFile)
  Pass 'global-authority-failures-retain-everything'
  # Revalidation: a change between inventory and action retains the row.
  Reset-TestState; $script:processTexts = @('c:\windows\system32\svchost.exe', $liveText)
  $report = Invoke-TestSweep @('worktrees') -Apply -BeforeAct {
    param($Row)
    if ($Row.path -ceq $wt.landed) { Write-TestFile (Join-Path $wt.landed 'late.txt') 'late' }
    if ($Row.path -ceq $wt.unmerged) { Invoke-TestGit $product @('worktree', 'lock', $wt.unmerged) | Out-Null }
    if ($Row.path -ceq $wt.merged) { $script:processTexts = @($liveText, ($wt.merged + '\x').ToLowerInvariant()) }
  }
  foreach ($case in @(@('became-dirty', '20260901-1001-landed', 'changed-before-apply'), @('became-locked', '20260901-1002-unmerged', 'changed-before-apply'), @('became-live', '20260901-1011-merged', 'live-owner'))) {
    $result = Get-TestResult $report 'worktrees' $case[1]
    Assert-Sweep ($result.result -ceq $case[2] -and [IO.Directory]::Exists((Join-Path $script:container $case[1]))) "revalidation $($case[0]) retained (actual $($result.result))"
    Pass "worktree-revalidation-$($case[0])"
  }
  Invoke-TestGit $product @('worktree', 'unlock', $wt.unmerged) | Out-Null
  [IO.File]::Delete((Join-Path $wt.landed 'late.txt')); Set-TestAge $wt.landed 240; Set-TestAge $wt.unmerged 240
  $dirtyResult = Get-TestResult $report 'worktrees' '20260901-1003-dirty'
  Assert-Sweep ($dirtyResult.result -ceq 'snapshot-removed' -and $dirtyResult.snapshotRef) "dirty worktree snapshot-removed (actual $($dirtyResult.result) $($dirtyResult.error))"
  $snapshotCommit = $dirtyResult.snapshotRef.Split('=')[1]
  $tree = Invoke-TestGit $product @('ls-tree', '-r', '--name-only', $snapshotCommit)
  $readme = Invoke-TestGit $product @('show', "${snapshotCommit}:README.md")
  Assert-Sweep ($tree -match 'notes/untracked.txt' -and $readme -ceq 'product changed' -and $tree -notmatch 'node_modules') 'snapshot holds tracked edits and untracked files, not ignored ones'
  Assert-Sweep ((Invoke-TestGit $product @('rev-parse', "$snapshotCommit^")) -ceq $base) 'snapshot parent is the old HEAD'
  Assert-Sweep (-not [IO.Directory]::Exists($wt.dirty) -and [IO.Directory]::Exists($dirtyResult.trash)) 'dirty worktree moved to trash'
  $controllerResult = Get-TestResult $report 'worktrees' '20260901-controller-seat'
  Assert-Sweep ($controllerResult.result -ceq 'removed' -and -not $controllerResult.preservedRef) 'container seat reachable from container HEAD removed without a preserve ref'
  Assert-Sweep (-not [Environment]::GetEnvironmentVariables().Contains('GIT_INDEX_FILE')) 'snapshot leaves GIT_INDEX_FILE undefined, not empty'
  Pass 'dirty-snapshot-and-container-seat'

  Reset-TestState; $script:processTexts = @('c:\windows\system32\svchost.exe', $liveText)
  $report = Invoke-TestSweep @('worktrees') -Apply
  $landed = Get-TestResult $report 'worktrees' '20260901-1001-landed'
  Assert-Sweep ($landed.result -ceq 'removed' -and $landed.branchResult -ceq 'deleted-exact-sha' -and -not $landed.preservedRef) "landed worktree and branch removed (actual $($landed.result)/$($landed.branchResult))"
  $unmerged = Get-TestResult $report 'worktrees' '20260901-1002-unmerged'
  Assert-Sweep ($unmerged.result -ceq 'removed' -and $unmerged.preservedRef -ceq "refs/reclaimed/$unmergedHead" -and $unmerged.branchResult -ceq 'retained-unmerged') "unmerged worktree removed with preserved ref, branch kept (actual $($unmerged.result)/$($unmerged.branchResult))"
  Assert-Sweep ((Invoke-TestGit $product @('rev-parse', "refs/reclaimed/$unmergedHead")) -ceq $unmergedHead -and (Invoke-TestGit $product @('rev-parse', 'refs/heads/codex/1002-unmerged')) -ceq $unmergedHead) 'unmerged head recoverable'
  $merged = Get-TestResult $report 'worktrees' '20260901-1011-merged'
  Assert-Sweep ($merged.result -ceq 'removed' -and $merged.branchResult -ceq 'deleted-exact-sha') "merged-PR-head worktree and branch removed (actual $($merged.result)/$($merged.branchResult))"
  $registered = @(Get-ReclamationWorktrees $product | ForEach-Object { Split-Path -Leaf $_.path })
  foreach ($kept in @('20260901-1004-recent', '20260901-1005-locked', '20260901-1006-platform-seat', '20260901-1007-live', '20260901-1008-openpr', '20260901-1009-dirtyrecent', 'lane-01', '20260901-1010-milestone7002', '20260901-registered-seat')) {
    Assert-Sweep ($kept -cin $registered) "retained worktree $kept still registered"
  }
  Assert-Sweep ('20260901-1001-landed' -cnotin $registered -and '20260901-1002-unmerged' -cnotin $registered -and '20260901-1011-merged' -cnotin $registered) 'removed worktrees pruned'
  Pass 'worktree-apply-removes-only-reconstructible-work'

  # ------------------------------------------------------------ branches
  foreach ($pair in @(@('codex/2001-at-base', 'origin/main'), @('codex/2002-unmerged', $unmergedHead), @('archive/old', 'origin/main'), @('codex/2003-openbase', 'origin/main'), @('codex/2004-fresh', 'origin/main'), @('codex/2005-live', 'origin/main'))) {
    Invoke-TestGit $product @('branch', $pair[0], $pair[1]) | Out-Null
  }
  foreach ($branch in @('codex/2001-at-base', 'codex/2002-unmerged', 'archive/old', 'codex/2003-openbase', 'codex/2005-live', 'codex/1002-unmerged')) { Set-TestRefAge $product $branch 240 }
  $script:prs = @($openPrNode, $mergedNode, (New-TestPrNode 9003 'OPEN' 'codex/2999-child' ('f' * 40) @{ baseRefName = 'codex/2003-openbase' }))
  Reset-TestState; $script:activeLanes = @([pscustomobject]@{ worktree = ''; branch = 'codex/2005-live' })
  $report = Invoke-TestSweep @('branches') -Apply
  Assert-TestReasons $report 'branches' ([ordered]@{ 'codex/2001-at-base' = 'branch-in-base'; 'codex/2002-unmerged' = 'branch-unmerged'; 'archive/old' = 'protected-branch'; 'codex/2003-openbase' = 'open-pr'; 'codex/2004-fresh' = 'recent'; 'codex/2005-live' = 'live-owner'; 'codex/1002-unmerged' = 'branch-unmerged' }) {
    param($Report, $Key) @($Report.phases.branches.rows | Where-Object { $_.repository -ceq 'product' -and $_.branch -ceq $Key })[0]
  }
  $names = @((Invoke-TestGit $product @('for-each-ref', '--format=%(refname:strip=2)', 'refs/heads/')) -split "`n")
  Assert-Sweep ('codex/2001-at-base' -cnotin $names -and 'codex/2002-unmerged' -cin $names -and 'archive/old' -cin $names -and 'codex/2003-openbase' -cin $names -and 'codex/2004-fresh' -cin $names -and 'codex/2005-live' -cin $names) 'only the in-base branch was deleted'
  Pass 'branch-phase-deletes-only-branches-without-unique-commits'
  # ------------------------------------------------------------ directories
  $dirs = [ordered]@{}
  foreach ($name in @('20260901-orphan-plain', '20260901-keep-me', '20260901-foreign-clone', '20260901-foreign-wt', '20260901-orphan-gitfile', '20260901-recent-dir', '20260901-platform-notes')) {
    $dirs[$name] = Join-Path $script:container $name
    Write-TestFile (Join-Path $dirs[$name] 'a\b\c.txt') "content $name`n"; Write-TestFile (Join-Path $dirs[$name] 'top.txt') "top`n"
  }
  Write-TestFile (Join-Path $dirs['20260901-orphan-plain'] 'node_modules\dep\index.js') "skip`n"
  [void][IO.Directory]::CreateDirectory((Join-Path $dirs['20260901-foreign-clone'] '.git'))
  $foreignAdmin = Join-Path $root 'foreign-admin'; [void][IO.Directory]::CreateDirectory($foreignAdmin)
  Write-TestFile (Join-Path $dirs['20260901-foreign-wt'] '.git') "gitdir: $foreignAdmin`n"
  Write-TestFile (Join-Path $dirs['20260901-orphan-gitfile'] '.git') "gitdir: $(Join-Path $root 'missing-admin')`n"
  foreach ($path in $dirs.Values) { Set-TestAge $path 240 }
  Write-TestFile (Join-Path $dirs['20260901-recent-dir'] 'fresh.txt') "fresh`n"
  Reset-TestState
  $report = Invoke-TestSweep @('directories') -Apply
  Assert-TestReasons $report 'directories' ([ordered]@{ '20260901-orphan-plain' = 'unregistered-directory'; '20260901-keep-me' = 'keep-listed'; '20260901-foreign-clone' = 'foreign-clone'; '20260901-foreign-wt' = 'foreign-worktree'; '20260901-orphan-gitfile' = 'unregistered-directory'; '20260901-recent-dir' = 'recent'; '20260901-platform-notes' = 'platform-seat-suspected' })
  Assert-Sweep (-not @($report.phases.directories.rows | Where-Object { $_.name -cin @('main', 'lane-01', '.orchestrator', '20260901-1004-recent') }).Count) 'registered worktrees, main, lanes and dot directories are not directory rows'
  $plain = Get-TestResult $report 'directories' '20260901-orphan-plain'
  Assert-Sweep ($plain.result -ceq 'archived-removed' -and $plain.entries -eq 2 -and [IO.File]::Exists($plain.archive) -and -not [IO.Directory]::Exists($dirs['20260901-orphan-plain'])) "orphan directory archived with verified entry count (actual $($plain.result) entries=$($plain.entries) $($plain.error))"
  $zip = [IO.Compression.ZipFile]::OpenRead($plain.archive)
  try { $entries = @($zip.Entries | ForEach-Object { $_.FullName }) } finally { $zip.Dispose() }
  Assert-Sweep ('a/b/c.txt' -cin $entries -and 'top.txt' -cin $entries -and -not @($entries | Where-Object { $_ -match 'node_modules' }).Count) 'archive entries are relative and exclude node_modules'
  Assert-Sweep ((Get-TestResult $report 'directories' '20260901-orphan-gitfile').result -ceq 'archived-removed') 'orphan gitfile directory archived'
  foreach ($kept in @('20260901-keep-me', '20260901-foreign-clone', '20260901-foreign-wt', '20260901-recent-dir', '20260901-platform-notes')) { Assert-Sweep ([IO.Directory]::Exists($dirs[$kept])) "directory $kept kept" }
  Pass 'directory-phase-archives-then-removes-orphans-only'

  # ------------------------------------------------------------ remote branches
  $remoteSeed = Join-Path $root 'remote-seed'
  Invoke-TestGit $root @('clone', '-q', $origin, $remoteSeed) | Out-Null
  $remote = [ordered]@{}
  foreach ($branch in @('codex/3001-merged', 'codex/3002-closed-old', 'codex/3003-closed-recent', 'codex/3004-open', 'feature/x', 'codex/3005-pushed-after-close', 'codex/3006-nopr', 'codex/3007-lease')) {
    Write-TestFile (Join-Path $remoteSeed 'remote.txt') "$branch`n"; Invoke-TestGit $remoteSeed @('add', '-A') | Out-Null; Invoke-TestGit $remoteSeed @('commit', '-q', '-m', $branch) | Out-Null
    $remote[$branch] = Invoke-TestGit $remoteSeed @('rev-parse', 'HEAD'); Invoke-TestGit $remoteSeed @('push', '-q', 'origin', "HEAD:refs/heads/$branch") | Out-Null
  }
  $old = [datetime]::UtcNow.AddDays(-20).ToString('o'); $recent = [datetime]::UtcNow.AddDays(-2).ToString('o')
  $script:prs = @(
    (New-TestPrNode 9101 'MERGED' 'codex/3001-merged' $remote['codex/3001-merged']),
    (New-TestPrNode 9102 'CLOSED' 'codex/3002-closed-old' $remote['codex/3002-closed-old'] @{ closedAt = $old }),
    (New-TestPrNode 9103 'CLOSED' 'codex/3003-closed-recent' $remote['codex/3003-closed-recent'] @{ closedAt = $recent }),
    (New-TestPrNode 9104 'OPEN' 'codex/3004-open' $remote['codex/3004-open']),
    (New-TestPrNode 9105 'CLOSED' 'codex/3005-pushed-after-close' ('1' * 40) @{ closedAt = $old }),
    (New-TestPrNode 9107 'CLOSED' 'codex/3007-lease' $remote['codex/3007-lease'] @{ closedAt = $old })
  )
  Reset-TestState
  $report = Invoke-TestSweep @('remote')
  Assert-TestReasons $report 'remote' ([ordered]@{ 'codex/3001-merged' = 'merged-pr-head'; 'codex/3002-closed-old' = 'closed-pr-head-stale'; 'codex/3003-closed-recent' = 'closed-pr-recent'; 'codex/3004-open' = 'open-pr'; 'feature/x' = 'not-lane-branch'; 'codex/3005-pushed-after-close' = 'pushed-after-close'; 'codex/3006-nopr' = 'no-pr'; 'main' = 'protected-branch'; 'codex/3007-lease' = 'closed-pr-head-stale' })
  $leaseRow = Get-TestRow $report 'remote' 'codex/3007-lease'
  Invoke-TestGit $remoteSeed @('checkout', '-q', '-B', 'codex/3007-lease', $remote['codex/3007-lease']) | Out-Null
  Write-TestFile (Join-Path $remoteSeed 'late.txt') "late`n"; Invoke-TestGit $remoteSeed @('add', '-A') | Out-Null; Invoke-TestGit $remoteSeed @('commit', '-q', '-m', 'late push') | Out-Null
  Invoke-TestGit $remoteSeed @('push', '-q', 'origin', 'HEAD:refs/heads/codex/3007-lease') | Out-Null
  $context = New-TestContext @('remote')
  $leaseResult = Invoke-SweepRemoteDeletion $leaseRow $context
  Assert-Sweep ($leaseResult.result -ceq 'changed-before-apply' -and (Invoke-TestGit $root @('--git-dir', $origin, 'rev-parse', '-q', '--verify', 'refs/heads/codex/3007-lease'))) 'a push after inventory refuses the remote delete'
  $script:openPrCount = 1
  Assert-Sweep ((Invoke-SweepRemoteDeletion (Get-TestRow $report 'remote' 'codex/3001-merged') $context).result -ceq 'open-pr-or-unknown') 'a PR opened after inventory refuses the remote delete'
  $script:openPrCount = 0
  $report = Invoke-TestSweep @('remote') -Apply
  $originHeads = Invoke-TestGit $root @('--git-dir', $origin, 'for-each-ref', '--format=%(refname:strip=2)', 'refs/heads/')
  Assert-Sweep ($originHeads -notmatch 'codex/3001-merged' -and $originHeads -notmatch 'codex/3002-closed-old' -and $originHeads -match 'codex/3003-closed-recent' -and $originHeads -match 'codex/3004-open' -and $originHeads -match 'feature/x' -and $originHeads -match 'codex/3006-nopr' -and $originHeads -match 'codex/3007-lease') "only stale merged/closed lane heads deleted on origin: $($originHeads -replace "`n", ' ')"
  Assert-Sweep ((Invoke-TestGit $product @('rev-parse', 'refs/reclaimed/remote/codex/3002-closed-old')) -ceq $remote['codex/3002-closed-old']) 'deleted remote head preserved locally first'
  Pass 'remote-phase-pinned-lease-and-preserved-ref'
  # ------------------------------------------------------------ drafts
  $completed = @{ nodes = @(@{ number = 4001; state = 'CLOSED'; stateReason = 'COMPLETED'; milestone = @{ number = 7001 } }) }
  $script:prs = @(
    (New-TestPrNode 501 'OPEN' 'codex/4001-a' ('a' * 40) @{ isDraft = $true; closingIssuesReferences = $completed }),
    (New-TestPrNode 502 'OPEN' 'codex/4001-b' ('b' * 40) @{ isDraft = $true; title = 'Probe (never merge): x'; closingIssuesReferences = $completed }),
    (New-TestPrNode 503 'OPEN' 'codex/4003-c' ('c' * 40) @{ isDraft = $true; closingIssuesReferences = @{ nodes = @(@{ number = 4003; state = 'OPEN'; stateReason = $null; milestone = $null }) } }),
    (New-TestPrNode 504 'OPEN' 'codex/4004-d' ('d' * 40) @{ isDraft = $true; closingIssuesReferences = @{ nodes = @(@{ number = 4004; state = 'CLOSED'; stateReason = 'NOT_PLANNED'; milestone = $null }) } }),
    (New-TestPrNode 505 'OPEN' 'codex/4001-e' ('e' * 40) @{ isDraft = $true; updatedAt = [datetime]::UtcNow.AddDays(-2).ToString('o'); closingIssuesReferences = $completed }),
    (New-TestPrNode 506 'OPEN' 'codex/4006-f' ('f' * 40) @{ isDraft = $true; closingIssuesReferences = @{ nodes = @(@{ number = 4006; state = 'CLOSED'; stateReason = 'COMPLETED'; milestone = @{ number = 7002 } }) } }),
    (New-TestPrNode 507 'OPEN' 'feature/y' ('1' * 40) @{ isDraft = $true; closingIssuesReferences = $completed }),
    (New-TestPrNode 508 'OPEN' 'codex/4008-h' ('2' * 40) @{ isDraft = $true }),
    (New-TestPrNode 509 'OPEN' 'codex/4001-i' ('3' * 40) @{ closingIssuesReferences = $completed })
  )
  Reset-TestState
  $report = Invoke-TestSweep @('prs') -Apply
  Assert-TestReasons $report 'prs' ([ordered]@{ '501' = 'draft-issue-completed'; '502' = 'never-close-marked'; '503' = 'issue-open-or-not-completed'; '504' = 'issue-open-or-not-completed'; '505' = 'recent'; '506' = 'platform-owned-milestone'; '507' = 'not-lane-branch'; '508' = 'no-closing-issue' })
  Assert-Sweep (-not (Get-TestRow $report 'prs' '509')) 'ready (non-draft) PRs are never draft rows'
  Assert-Sweep ($script:closed.Count -eq 1 -and $script:closed[0].number -eq 501 -and $script:closed[0].comment -match '#4001' -and $script:closed[0].comment -match 'branch is kept') 'only the stale completed-issue draft closed, with comment'
  $script:prs[0].updatedAt = [datetime]::UtcNow.AddDays(-1).ToString('o')
  $closeAgain = Invoke-SweepDraftClose (Get-TestRow $report 'prs' '501') (New-TestContext @('prs'))
  Assert-Sweep ($closeAgain.result -ceq 'changed-before-apply' -and $script:closed.Count -eq 1) 'a draft touched after inventory is not closed'
  Pass 'draft-phase-closes-only-stale-completed-drafts'

  # ------------------------------------------------------------ scheduled tasks
  $launcher = Join-Path $root 'launch-old.vbs'; Write-TestFile $launcher "' synthetic"
  Reset-TestState
  $task = { param($Name, $State, $LastDays, $NextHours, $RegisteredDays, $Launcher) [pscustomobject]@{ name = $Name; state = $State; lastRunUtc = $(if ($null -ne $LastDays) { [datetime]::UtcNow.AddDays(-$LastDays) }); nextRunUtc = $(if ($null -ne $NextHours) { [datetime]::UtcNow.AddHours($NextHours) }); registeredUtc = $(if ($null -ne $RegisteredDays) { [datetime]::UtcNow.AddDays(-$RegisteredDays) }); launcher = $Launcher } }
  $script:tasks = @(
    (& $task 'chase-sets-lane-old' 'Ready' 13 $null $null $launcher),
    (& $task 'chase-sets-lane-scheduled' 'Ready' 13 1 $null $launcher),
    (& $task 'chase-sets-lane-running' 'Running' 13 $null $null $launcher),
    (& $task 'chase-sets-lane-recent' 'Ready' 1 $null $null $launcher),
    (& $task 'chase-sets-lane-foreign' 'Ready' 13 $null $null 'C:\Program Files\x.vbs'),
    (& $task 'chase-sets-lane-never-ran' 'Ready' $null $null 9 $launcher)
  )
  $report = Invoke-TestSweep @('tasks') -Apply
  Assert-TestReasons $report 'tasks' ([ordered]@{ 'chase-sets-lane-old' = 'one-shot-lane-task-idle'; 'chase-sets-lane-scheduled' = 'scheduled'; 'chase-sets-lane-running' = 'running'; 'chase-sets-lane-recent' = 'recent'; 'chase-sets-lane-foreign' = 'launcher-unrecognized'; 'chase-sets-lane-never-ran' = 'one-shot-lane-task-idle' })
  Assert-Sweep ($script:unregistered.Count -eq 2 -and 'chase-sets-lane-old' -cin $script:unregistered -and 'chase-sets-lane-never-ran' -cin $script:unregistered -and -not [IO.File]::Exists($launcher)) 'only idle one-shot lane tasks unregistered, launcher removed'
  Pass 'task-phase-unregisters-idle-one-shot-lane-tasks'

  # ------------------------------------------------------------ docker
  Reset-TestState
  $report = Invoke-TestSweep @('docker') -Apply
  Assert-Sweep ($report.phases.docker.status -ceq 'docker-unavailable' -and $script:dockerCalls.Count -eq 1) 'docker unavailable skips every docker action'
  Reset-TestState
  $presentIdentity = ConvertTo-SweepSandboxIdentity $wt.recent
  $oldVolume = 'a' * 64; $newVolume = 'b' * 64
  $script:dockerResponder = {
    param($Arguments)
    $joined = $Arguments -join ' '
    $stdout = switch -Regex ($joined) {
      '^version' { '27.0' }
      '^ps ' { "id-orphan|chase-sets-orphan-postgres-1|d:/gone/worktree`nid-present|chase-sets-present-postgres-1|$presentIdentity" }
      '^volume ls' { "$oldVolume`n$newVolume`nnamed-volume" }
      '^volume inspect' { ConvertTo-Json -Depth 4 -InputObject @(@{ Name = $oldVolume; CreatedAt = [datetime]::UtcNow.AddDays(-30).ToString('o'); Labels = $null }, @{ Name = $newVolume; CreatedAt = [datetime]::UtcNow.AddDays(-1).ToString('o'); Labels = @{} }) }
      default { 'Total reclaimed space: 0B' }
    }
    [pscustomobject]@{ exitCode = 0; stdout = $stdout; stderr = '' }
  }
  $report = Invoke-TestSweep @('docker') -Apply
  $calls = @($script:dockerCalls)
  Assert-Sweep ('stop id-orphan' -cin $calls -and 'stop id-present' -cnotin $calls) 'only sandboxes whose worktree is gone are stopped'
  Assert-Sweep ("volume rm $oldVolume" -cin $calls -and "volume rm $newVolume" -cnotin $calls -and -not @($calls | Where-Object { $_ -match '^volume rm named' }).Count) "only idle anonymous volumes removed: $($calls -join ' ; ') rows: $($report.phases.docker.rows | ForEach-Object { "$($_.kind)/$($_.reasonCode)" })"
  Assert-Sweep ('sandbox-gc' -cin $calls -and 'image prune -f' -cin $calls -and 'builder prune -f --filter until=168h' -cin $calls) 'sandbox gc, dangling image and old build cache prune run'
  Assert-Sweep ([array]::IndexOf($calls, 'stop id-orphan') -lt [array]::IndexOf($calls, 'sandbox-gc')) 'orphans stop before sandbox gc'
  Pass 'docker-phase-bounded-to-orphaned-sandbox-state'

  # ------------------------------------------------------------ trash
  $trash = Join-Path $script:container '.trash'
  $outside = Join-Path $root 'outside-target'; Write-TestFile (Join-Path $outside 'sentinel.txt') 'must survive'
  $item = Join-Path $trash '20260901\item'
  Write-TestFile (Join-Path $item 'objects\pack.idx') 'readonly'; [IO.File]::SetAttributes((Join-Path $item 'objects\pack.idx'), [IO.FileAttributes]::ReadOnly)
  New-Item -ItemType Junction -Path (Join-Path $item 'node_modules') -Target $outside | Out-Null
  Reset-TestState
  $started = Start-SweepTrashPurge (New-TestContext @('trash')) (Join-Path $PSScriptRoot 'container-sweep.ps1')
  Assert-Sweep ($started.result -ceq 'started' -and $script:hidden.Count -eq 1 -and $script:hidden[0] -match '-PurgeTrash') 'apply starts one hidden purge'
  $held = [IO.FileStream]::new((Join-Path $trash '.purge.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
  try { Assert-Sweep ((Invoke-SweepTrashPurge $script:container 5).result -ceq 'already-running') 'a held purge lock refuses a second purge' } finally { $held.Dispose() }
  $purge = Invoke-SweepTrashPurge $script:container 5
  Assert-Sweep ($purge.result -ceq 'purged' -and -not [IO.Directory]::Exists((Join-Path $trash '20260901')) -and [IO.File]::Exists((Join-Path $outside 'sentinel.txt'))) "purge removes trash and unlinks junctions without following them (actual $($purge.result) failed=$($purge.failed) $($purge.failures -join '; '))"
  Pass 'trash-purge-reparse-safe'

  # ------------------------------------------------------------ admin lock file
  # Git before 2.31 omits "locked" from worktree porcelain; the admin lock file
  # must still retain the worktree in the reclaimer and the sweep.
  $lockProbe = New-TestWorktree $product '20260901-admin-lock' @('--detach', 'origin/main')
  $common = Invoke-TestGit $product @('rev-parse', '--git-common-dir'); if (-not [IO.Path]::IsPathRooted($common)) { $common = Join-Path $product $common }
  Write-TestFile (Join-Path $common 'worktrees\20260901-admin-lock\locked') 'synthetic hand lock'
  $parsed = @(Get-ReclamationWorktrees $product | Where-Object { (Split-Path -Leaf $_.path) -ceq '20260901-admin-lock' })
  Assert-Sweep ($parsed.Count -eq 1 -and $parsed[0].locked) 'admin lock file marks the worktree locked'
  Assert-Sweep ((Test-ReclamationAdminLocked (Join-Path $root 'no-such-dir')) -eq $false) 'a missing worktree has no admin lock'
  Write-TestFile (Join-Path $root 'bad-gitfile\.git') 'not a gitdir line'
  Assert-Sweep ((Test-ReclamationAdminLocked (Join-Path $root 'bad-gitfile')) -eq $true) 'an unreadable gitfile counts as locked'
  Pass 'admin-lock-file-detected-on-old-git'
  # ------------------------------------------------------------ reclaimer ownership budget
  $script:ownershipCalls = [Collections.Generic.List[object]]::new()
  function Get-LiveDispatchOwnership { param($RuntimeRoot, $TempRoot, $ContainerRoot, [int]$MaxRecords = 64, [int]$DeadlineMs = 5000) $script:ownershipCalls.Add([pscustomobject]@{ max = $MaxRecords; deadline = $DeadlineMs }); [pscustomobject]@{ health = @{ status = 'ok' }; activeLanes = @() } }
  $launchRoot = Join-Path $root 'launch-runtime'; [void][IO.Directory]::CreateDirectory($launchRoot)
  [void](Get-ReclamationLiveOwnership $launchRoot $root $root)
  for ($i = 0; $i -lt 70; $i++) { Write-TestFile (Join-Path $launchRoot "dispatch-launch-$i.json") '{}' }
  [void](Get-ReclamationLiveOwnership $launchRoot $root $root)
  $c = $script:ownershipCalls
  Assert-Sweep ($c.Count -eq 2 -and $c[0].max -eq 64 -and $c[1].max -eq 70 -and $c[0].deadline -eq 60000 -and $c[1].deadline -eq 60000) 'reclaimer ownership census sized to every launch record with a 60s deadline'
  Pass 'reclaimer-ownership-census-budget'

  Write-Output "container-sweep tests: $script:passed passed"
} finally {
  if (-not $KeepEvidence -and [IO.Directory]::Exists($root)) {
    try { Remove-SweepTree $root } catch { Write-Warning "evidence cleanup failed: $($_.Exception.Message)" }
  }
}