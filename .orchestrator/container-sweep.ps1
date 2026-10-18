<#
.SYNOPSIS
Report or apply the ground-truth container sweep (Todd, 2026-10-17).

.DESCRIPTION
Runs after cleanup-orphan-worktree-dirs.ps1. That reclaimer only removes work it
can bind to a dispatch identity; this sweep reclaims the rest on git and
filesystem ground truth, and always keeps a recovery path:

  worktrees    clean and idle 72h (336h under .orchestrator\): moved to .trash,
               unmerged heads kept as refs/reclaimed/<sha>; dirty and idle 168h:
               snapshot commit refs/reclaimed/snapshot/<leaf>-<utc> first.
  branches     local branches with no unique commits (in base or an exact
               merged-PR head) deleted at their exact SHA.
  directories  unregistered container-root directories idle 168h: zipped to
               .archive\reclaimed-dirs (entry count verified), then trashed.
  remote       origin lane branches at an exact merged-PR head, or at the head
               of a PR closed unmerged 336h ago: fetched to
               refs/reclaimed/remote/<branch>, deleted with a pinned lease.
  prs          lane drafts idle 336h whose every closing issue closed as
               completed: closed with a comment, branch kept.
  tasks        one-shot chase-sets-lane-* scheduled tasks idle 168h.
  docker       product sandbox gc, orphaned running sandboxes stopped,
               anonymous unattached volumes idle 168h, dangling images,
               build cache older than 168h.
  trash        hidden background purge of .trash (reparse points unlinked,
               never followed).

Every row retains when it is live (ownership census, launch record or process
command line), locked, persistent (main, lane-NN), platform-owned or
platform-suspected, keep-listed, an open-PR head or base, or unreadable. An
incomplete register, ownership census or PR census skips every phase that
depends on it. Report is the default. -Apply passes every mutation through a
fresh-evidence gate immediately before it acts: the register, dispatch
identity, keep list, ownership census, launch records and process command
lines are re-read; the row's PRs (by head and base branch), issue, worktree
registration and filesystem or docker state are re-queried; and the row's
decision is re-derived with the inventory code. Any difference retains it.
-Apply runs at most every six hours unless -Force.
#>
[CmdletBinding()]
param(
  [switch]$Apply,
  [switch]$Force,
  [switch]$Background,
  [switch]$PurgeTrash,
  [switch]$Json,
  [string]$ReportPath,
  [string]$ContainerRoot = (Split-Path -Parent $PSScriptRoot),
  # Comma-separated values are accepted so -File callers can pass a list.
  [string[]]$Phase = @('worktrees','branches','directories','remote','prs','tasks','docker','trash'),
  [int]$PurgeBudgetMinutes = 45
)

$ErrorActionPreference = 'Stop'
# Dot-sourcing the reclaimer rebinds its own parameters in this scope, so
# capture ours (and the invocation name) first.
$sweepInvocationName = $MyInvocation.InvocationName
$sweepOptions = [pscustomobject]@{
  Apply = [bool]$Apply; Force = [bool]$Force; Background = [bool]$Background; PurgeTrash = [bool]$PurgeTrash
  Json = [bool]$Json; ReportPath = $ReportPath; ContainerRoot = $ContainerRoot; Phase = @($Phase)
  PurgeBudgetMinutes = $PurgeBudgetMinutes; BoundParameters = @{} + $PSBoundParameters
}
. (Join-Path $PSScriptRoot 'cleanup-orphan-worktree-dirs.ps1')

$script:SweepSchema = 'container-sweep-report/v1'
$script:SweepPolicy = [pscustomobject][ordered]@{
  cleanIdleHours = 72
  dirtyIdleHours = 168
  evidenceSeatIdleHours = 336
  directoryIdleHours = 168
  branchRecentHours = 24
  remoteClosedIdleHours = 336
  draftIdleHours = 336
  taskIdleHours = 168
  anonymousVolumeIdleHours = 168
  builderCacheUntil = '168h'
  directoryArchiveMaxBytes = 1GB
  dirtySnapshotMaxBytes = 200MB
  dueHours = 6
  parallelism = 8
}
$script:SweepProtectedBranch = '^(main|master)$|^(archive|salvage|backup)/'
$script:SweepPlatformPattern = '(?i)platform|(^|[/_-])iss-?[0-9]|^plan/'
$script:SweepNeverClosePattern = '(?i)never[ -]?(merge|land)|do[ -]not[ -](merge|close)|\bkeep\b'
$script:SweepLanePattern = '^(codex|claude)/'

function Test-SweepUnder([string]$Path, [string]$Root) {
  if (-not $Path -or -not $Root) { return $false }
  $p = Get-ReclamationPath $Path; $r = Get-ReclamationPath $Root
  $p.Equals($r, [StringComparison]::OrdinalIgnoreCase) -or
    $p.StartsWith($r + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Get-SweepRefSegment([string]$Value) {
  $segment = ($Value -replace '[^A-Za-z0-9._-]', '-').Trim('.', '-')
  if (-not $segment) { $segment = 'unnamed' }
  $segment
}

function Invoke-SweepProcess([string]$File, [string[]]$Arguments, [int]$TimeoutMs = 120000) {
  $psi = [Diagnostics.ProcessStartInfo]::new($File)
  foreach ($argument in $Arguments) { $psi.ArgumentList.Add($argument) }
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false); $psi.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
  try { $process = [Diagnostics.Process]::Start($psi) }
  catch { return [pscustomobject]@{ exitCode = -1; stdout = ''; stderr = $_.Exception.Message; timedOut = $false } }
  try {
    $out = $process.StandardOutput.ReadToEndAsync(); $err = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutMs)) {
      try { $process.Kill($true) } catch {}
      return [pscustomobject]@{ exitCode = -1; stdout = ''; stderr = 'timeout'; timedOut = $true }
    }
    $process.WaitForExit()
    [pscustomobject]@{ exitCode = $process.ExitCode; stdout = $out.GetAwaiter().GetResult(); stderr = $err.GetAwaiter().GetResult(); timedOut = $false }
  } finally { $process.Dispose() }
}

function Invoke-SweepGitEnv([string]$Root, [string[]]$Arguments, [hashtable]$Environment) {
  $saved = @{}
  foreach ($key in $Environment.Keys) { $saved[$key] = [Environment]::GetEnvironmentVariable($key); [Environment]::SetEnvironmentVariable($key, [string]$Environment[$key]) }
  try { Invoke-ReclamationGit $Root $Arguments }
  finally {
    # PowerShell passes $null to a .NET string parameter as "", which would leave
    # GIT_INDEX_FILE defined but empty and send later git commands to a bogus index.
    foreach ($key in $saved.Keys) {
      if ($null -eq $saved[$key]) { [Environment]::SetEnvironmentVariable($key, [NullString]::Value) }
      else { [Environment]::SetEnvironmentVariable($key, $saved[$key]) }
    }
  }
}

# ---------------------------------------------------------------- authority

function Get-SweepProcessTexts {
  $texts = [Collections.Generic.List[string]]::new()
  foreach ($process in @(Get-CimInstance Win32_Process -Property ProcessId, CommandLine, ExecutablePath -ErrorAction Stop)) {
    foreach ($text in @($process.CommandLine, $process.ExecutablePath)) {
      if ($text) { $texts.Add(([string]$text).Replace('/', '\').ToLowerInvariant()) }
    }
  }
  @($texts)
}

function Test-SweepTextMentionsPath([string[]]$Texts, [string]$Path) {
  $needle = (Get-ReclamationPath $Path).Replace('/', '\').ToLowerInvariant()
  foreach ($text in $Texts) {
    $at = 0
    while (($at = $text.IndexOf($needle, $at, [StringComparison]::Ordinal)) -ge 0) {
      $end = $at + $needle.Length
      if ($end -ge $text.Length -or $text[$end] -in @('\', '"', "'", ' ', ';', ',', '|')) { return $true }
      $at = $end
    }
  }
  $false
}

function Get-SweepLaunchRecords([string]$RuntimeRoot) {
  $paths = [Collections.Generic.List[string]]::new(); $branches = [Collections.Generic.List[string]]::new(); $complete = $true
  foreach ($file in @([IO.Directory]::EnumerateFiles($RuntimeRoot, 'dispatch-launch-*.json', [IO.SearchOption]::TopDirectoryOnly))) {
    try {
      $record = [IO.File]::ReadAllText($file) | ConvertFrom-Json -DateKind String
      if ($record.worktree) { $paths.Add((Get-ReclamationPath ([string]$record.worktree))) }
      if ($record.branch) { $branches.Add([string]$record.branch) }
    } catch [IO.FileNotFoundException] { continue } catch { $complete = $false }
  }
  [pscustomobject]@{ complete = $complete; paths = @($paths); branches = @($branches) }
}

function Get-SweepKeepList([string]$RuntimeRoot, [string]$ContainerRoot) {
  $keep = [Collections.Generic.List[string]]::new()
  foreach ($name in @('container-sweep.keep', 'container-sweep.local.keep')) {
    $file = Join-Path $RuntimeRoot $name
    if (-not [IO.File]::Exists($file)) { continue }
    foreach ($line in [IO.File]::ReadAllLines($file)) {
      $entry = $line.Trim()
      if (-not $entry -or $entry.StartsWith('#')) { continue }
      $path = if ([IO.Path]::IsPathRooted($entry)) { $entry } else { Join-Path $ContainerRoot $entry }
      $keep.Add((Get-ReclamationPath $path))
    }
  }
  @($keep)
}

function ConvertTo-SweepPrCensus([object[]]$Pages) {
  $unknown = [pscustomobject]@{ complete = $false; nodes = @(); byHeadName = @{}; openHeadNames = @{}; openBaseNames = @{}; openHeadOids = @{}; mergedHeadOids = @{} }
  if (-not $Pages.Count) { return $unknown }
  $nodes = [Collections.Generic.List[object]]::new(); $total = $null; $seen = [Collections.Generic.HashSet[int]]::new()
  for ($i = 0; $i -lt $Pages.Count; $i++) {
    $connection = $Pages[$i].data.repository.pullRequests
    if ($Pages[$i].errors -or $null -eq $connection -or $null -eq $connection.totalCount -or $connection.nodes -isnot [array]) { return $unknown }
    if ($null -ne $total -and $total -ne [int]$connection.totalCount) { return $unknown }
    $total = [int]$connection.totalCount
    if ($connection.pageInfo.hasNextPage -ne ($i -lt $Pages.Count - 1)) { return $unknown }
    foreach ($node in $connection.nodes) {
      if (-not $seen.Add([int]$node.number) -or [string]$node.headRefOid -cnotmatch '^[0-9a-f]{40}$') { return $unknown }
      $nodes.Add($node)
    }
  }
  if ($nodes.Count -ne $total) { return $unknown }
  New-SweepCensusIndex @($nodes)
}

function New-SweepCensusIndex([object[]]$Nodes) {
  $census = [pscustomobject]@{ complete = $true; nodes = @($Nodes); byHeadName = @{}; openHeadNames = @{}; openBaseNames = @{}; openHeadOids = @{}; mergedHeadOids = @{} }
  foreach ($node in $Nodes) {
    $name = [string]$node.headRefName
    if (-not $census.byHeadName.ContainsKey($name)) { $census.byHeadName[$name] = [Collections.Generic.List[object]]::new() }
    $census.byHeadName[$name].Add($node)
    if ([string]$node.state -ceq 'OPEN') {
      $census.openHeadNames[$name] = [int]$node.number; $census.openHeadOids[[string]$node.headRefOid] = [int]$node.number
      $census.openBaseNames[[string]$node.baseRefName] = [int]$node.number
    } elseif ([string]$node.state -ceq 'MERGED') { $census.mergedHeadOids[[string]$node.headRefOid] = [int]$node.number }
  }
  $census
}

$script:SweepPrFields = 'number state isDraft title headRefName headRefOid baseRefName updatedAt closedAt mergedAt labels(first:10){nodes{name}} closingIssuesReferences(first:10){nodes{number state stateReason milestone{number}}}'

function Get-SweepPrCensus([string]$Repository) {
  $slug = Get-ReclamationRepositorySlug $Repository
  if (-not $slug) { return ConvertTo-SweepPrCensus @() }
  $parts = $slug.Split('/')
  $query = 'query($owner:String!,$name:String!,$endCursor:String){repository(owner:$owner,name:$name){pullRequests(first:100,after:$endCursor,orderBy:{field:CREATED_AT,direction:DESC}){totalCount nodes{' + $script:SweepPrFields + '} pageInfo{hasNextPage endCursor}}}}'
  $PSNativeCommandUseErrorActionPreference = $false
  $raw = @(& gh api graphql --paginate --slurp -f "query=$query" -F "owner=$($parts[0])" -F "name=$($parts[1])" 2>$null)
  if ($LASTEXITCODE -ne 0) { return ConvertTo-SweepPrCensus @() }
  try { ConvertTo-SweepPrCensus @(($raw -join "`n") | ConvertFrom-Json -DateKind String) } catch { ConvertTo-SweepPrCensus @() }
}

function Get-SweepBranchPrs([string]$Repository, [string]$Branch) {
  # Every PR headed by the branch and every open PR based on it, or $null when
  # the answer is incomplete. A branch with more than 100 of either retains.
  $slug = Get-ReclamationRepositorySlug $Repository
  if (-not $slug) { return $null }
  $parts = $slug.Split('/')
  $query = 'query($owner:String!,$name:String!,$branch:String!){repository(owner:$owner,name:$name){head:pullRequests(first:100,headRefName:$branch){totalCount nodes{' + $script:SweepPrFields + '}} base:pullRequests(first:100,baseRefName:$branch,states:OPEN){totalCount nodes{' + $script:SweepPrFields + '}}}}'
  $PSNativeCommandUseErrorActionPreference = $false
  $raw = @(& gh api graphql -f "query=$query" -F "owner=$($parts[0])" -F "name=$($parts[1])" -f "branch=$Branch" 2>$null)
  if ($LASTEXITCODE -ne 0) { return $null }
  try { $page = ($raw -join "`n") | ConvertFrom-Json -DateKind String } catch { return $null }
  if ($page.errors -or $null -eq $page.data.repository) { return $null }
  $nodes = [Collections.Generic.List[object]]::new()
  foreach ($connection in @($page.data.repository.head, $page.data.repository.base)) {
    if ($null -eq $connection -or $null -eq $connection.totalCount -or $connection.nodes -isnot [array] -or [int]$connection.totalCount -ne $connection.nodes.Count) { return $null }
    foreach ($node in $connection.nodes) { if ([string]$node.headRefOid -cnotmatch '^[0-9a-f]{40}$') { return $null }; $nodes.Add($node) }
  }
  $unique = @($nodes | Group-Object { [int]$_.number } | ForEach-Object { $_.Group[0] })
  [pscustomobject]@{ nodes = $unique }
}

function Get-SweepPrNode([int]$Number) {
  $query = 'query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){' + $script:SweepPrFields + '}}}'
  $PSNativeCommandUseErrorActionPreference = $false
  $raw = @(& gh api graphql -f "query=$query" -F 'owner=chase-sets' -F 'name=chase-sets' -F "number=$Number" 2>$null)
  if ($LASTEXITCODE -ne 0) { return $null }
  try { $page = ($raw -join "`n") | ConvertFrom-Json -DateKind String } catch { return $null }
  if ($page.errors) { return $null }
  $page.data.repository.pullRequest
}

function Get-SweepIssueNumber([string]$Leaf, [string]$Branch, $DispatchEntry) {
  if ($DispatchEntry -and [string]$DispatchEntry.attemptId -cmatch '^(?<n>[1-9][0-9]*)(?:-|$)') { return [int]$Matches.n }
  foreach ($name in @($Branch, [string]$DispatchEntry.branch)) {
    if ($name -cmatch '^(?:codex|claude)/(?<n>[1-9][0-9]*)-') { return [int]$Matches.n }
  }
  if ($Leaf -cmatch '^[0-9]{8}-(?<n>[1-9][0-9]{2,5})(?:-|$)') { return [int]$Matches.n }
  0
}

function Get-SweepPlatformReason($Context, [string]$Path, [string]$Branch, [int]$Issue) {
  $leaf = if ($Path) { Split-Path -Leaf $Path } else { '' }
  if ($leaf -match $script:SweepPlatformPattern -or $Branch -match $script:SweepPlatformPattern) { return 'platform-seat-suspected' }
  if ($Path -and $Context.registerText) {
    # Match the container-relative path as a path token, so a generic leaf such
    # as "seat" does not match register prose.
    $relative = [IO.Path]::GetRelativePath($Context.container, $Path)
    if (-not $relative.StartsWith('..')) {
      $segments = @($relative -split '[\\/]' | Where-Object { $_ } | ForEach-Object { [regex]::Escape($_) })
      $pattern = '(?i)(?:^|[\\/`\s"''(])' + ($segments -join '[\\/]') + '(?![A-Za-z0-9._-])'
      if ([regex]::IsMatch($Context.registerText, $pattern)) { return 'platform-register-named' }
    }
  }
  if ($Issue) {
    if (-not $Context.issues.ContainsKey($Issue)) { return 'issue-unreadable' }
    $record = $Context.issues[$Issue]
    if ($null -eq $record -or 'milestone' -cnotin @($record.PSObject.Properties.Name)) { return 'issue-unreadable' }
    if ($null -ne $record.milestone -and [int]$record.milestone.number -in @($Context.register.milestones)) { return 'platform-owned-milestone' }
  }
  $null
}

function Test-SweepLive($Context, [string]$Path, [string]$Branch) {
  if ($Path) {
    foreach ($live in $Context.livePaths) { if (Test-SweepUnder $live $Path) { return $true } }
    if (Test-SweepTextMentionsPath $Context.processTexts $Path) { return $true }
  }
  ($Branch -and $Context.liveBranches.Contains($Branch))
}

function New-SweepContext {
  param(
    [string]$ContainerRoot, [string[]]$Phases, [hashtable]$Resolvers
  )
  $container = Get-ReclamationPath $ContainerRoot
  $runtime = Join-Path $container '.orchestrator'
  $now = & $Resolvers.Now
  $stamp = $now.ToString('yyyyMMdd')
  $context = [pscustomobject][ordered]@{
    container = $container; runtime = $runtime; now = $now; policy = $script:SweepPolicy
    trashRoot = Join-Path $container ".trash\$stamp"; archiveRoot = Join-Path $container ".archive\reclaimed-dirs\$stamp"
    tempRoot = Get-ReclamationPath ([IO.Path]::GetTempPath())
    register = Get-ReclamationRegister $runtime; registerText = ''
    dispatch = $null; ownership = $null; ownershipHealthy = $false; launch = $null
    livePaths = [Collections.Generic.List[string]]::new(); liveBranches = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    processTexts = @(); processObservedAt = [datetime]::MinValue; keep = @()
    keepComplete = $false; dispatchStamp = ''
    prCensus = (ConvertTo-SweepPrCensus @()); issues = @{}; repositories = @(); resolvers = $Resolvers
  }
  try { $context.registerText = [IO.File]::ReadAllText((Join-Path $runtime 'platform-handoff.md')) } catch { $context.registerText = '' }
  Update-SweepDispatch $context
  Update-SweepKeep $context
  Update-SweepLiveness $context -Ownership
  $context.repositories = @(
    [pscustomobject]@{ identity = 'container-meta'; root = $container; bases = @('refs/heads/main', 'HEAD') }
  )
  $product = Join-Path $container 'main'
  if ([IO.Directory]::Exists($product)) {
    $context.repositories += [pscustomobject]@{ identity = 'product'; root = (Get-ReclamationPath $product); bases = @('refs/remotes/origin/main') }
  }
  if (@($Phases | Where-Object { $_ -in @('worktrees', 'branches', 'remote', 'prs') }).Count -and $context.repositories.Count -eq 2) {
    try { $context.prCensus = & $Resolvers.PrCensus $product } catch { $context.prCensus = ConvertTo-SweepPrCensus @() }
  }
  $context
}

function Update-SweepLiveness($Context, [switch]$Ownership) {
  $resolvers = $Context.resolvers
  if ($Ownership) {
    try { $Context.ownership = & $resolvers.Ownership $Context.runtime $Context.tempRoot $Context.container } catch { $Context.ownership = $null }
    try { $Context.launch = Get-SweepLaunchRecords $Context.runtime } catch { $Context.launch = [pscustomobject]@{ complete = $false; paths = @(); branches = @() } }
    $Context.ownershipHealthy = $null -ne $Context.ownership -and [string]$Context.ownership.health.status -ceq 'ok' -and $Context.launch.complete
    $Context.livePaths.Clear(); $Context.liveBranches.Clear()
    foreach ($lane in @($Context.ownership.activeLanes)) {
      if ($lane.worktree) { $Context.livePaths.Add((Get-ReclamationPath ([string]$lane.worktree))) }
      if ($lane.branch) { [void]$Context.liveBranches.Add([string]$lane.branch) }
    }
    foreach ($path in $Context.launch.paths) { $Context.livePaths.Add($path) }
    foreach ($branch in $Context.launch.branches) { [void]$Context.liveBranches.Add($branch) }
  }
  try { $Context.processTexts = @(& $resolvers.ProcessTexts) } catch { $Context.processTexts = $null; $Context.ownershipHealthy = $false }
  $Context.processObservedAt = [datetime]::UtcNow
}

function Update-SweepKeep($Context) {
  try { $Context.keep = @(Get-SweepKeepList $Context.runtime $Context.container); $Context.keepComplete = $true }
  catch { $Context.keep = @(); $Context.keepComplete = $false }
}

function Update-SweepDispatch($Context) {
  # The dispatch log is large; re-read it only when its size or write time moved.
  $stamp = try {
    $info = [IO.FileInfo]::new((Join-Path $Context.runtime 'dispatch-log.jsonl'))
    if ($info.Exists) { "$($info.Length)|$($info.LastWriteTimeUtc.Ticks)" } else { 'missing' }
  } catch { 'unreadable' }
  if ($null -ne $Context.dispatch -and $Context.dispatch.complete -and $stamp -ceq $Context.dispatchStamp) { return }
  $Context.dispatch = Get-ReclamationDispatch $Context.runtime; $Context.dispatchStamp = $stamp
}

function Update-SweepAuthority($Context) {
  # The fresh-evidence gate every apply helper passes immediately before it
  # mutates: re-read the register, dispatch identity, keep list, ownership
  # census, launch records and process command lines. Returns the global block.
  $Context.register = Get-ReclamationRegister $Context.runtime
  try { $Context.registerText = [IO.File]::ReadAllText((Join-Path $Context.runtime 'platform-handoff.md')) } catch { $Context.registerText = '' }
  Update-SweepDispatch $Context
  Update-SweepKeep $Context
  Update-SweepLiveness $Context -Ownership
  Get-SweepGlobalBlock $Context -NeedsOwnership
}

function Update-SweepIssue($Context, [int]$Number) {
  if ($Number -le 0) { return }
  [void]$Context.issues.Remove($Number)
  Resolve-SweepIssues $Context @($Number)
}

function Get-SweepFreshCensus($Context, [string]$Branch) {
  # Re-query the PRs headed by or based on one branch and overlay them on the
  # inventory census; $null (retain) when either is unknown. The census is the
  # product repository's, so container-meta rows are checked against it too.
  if (-not $Context.prCensus.complete) { return $null }
  if (-not $Branch) { return $Context.prCensus }
  $product = @($Context.repositories | Where-Object { $_.identity -ceq 'product' })[0]
  if (-not $product) { return $null }
  $fresh = try { & $Context.resolvers.BranchPrs $product.root $Branch } catch { $null }
  if ($null -eq $fresh) { return $null }
  $numbers = [Collections.Generic.HashSet[int]]::new()
  foreach ($node in @($fresh.nodes)) { [void]$numbers.Add([int]$node.number) }
  $kept = @($Context.prCensus.nodes | Where-Object { -not $numbers.Contains([int]$_.number) -and [string]$_.headRefName -cne $Branch -and -not ([string]$_.state -ceq 'OPEN' -and [string]$_.baseRefName -ceq $Branch) })
  New-SweepCensusIndex (@($kept) + @($fresh.nodes))
}

function Get-SweepGlobalBlock($Context, [switch]$NeedsCensus, [switch]$NeedsOwnership) {
  if (-not $Context.register.complete) { return 'register-unreadable' }
  if (-not $Context.dispatch.complete) { return 'identity-unreadable' }
  if (-not $Context.keepComplete) { return 'keep-unreadable' }
  if ($NeedsOwnership -and -not $Context.ownershipHealthy) { return 'ownership-unknown' }
  if ($NeedsCensus -and -not $Context.prCensus.complete) { return 'pr-census-unknown' }
  $null
}

function Resolve-SweepIssues($Context, [int[]]$Numbers) {
  $missing = @($Numbers | Where-Object { $_ -gt 0 -and -not $Context.issues.ContainsKey($_) } | Sort-Object -Unique)
  if (-not $missing.Count) { return }
  try { $batch = & $Context.resolvers.Issues $missing } catch { $batch = @{} }
  foreach ($number in $missing) { $Context.issues[$number] = $batch[$number] }
}
# ---------------------------------------------------------------- worktrees

function Get-SweepAdminNewest([string]$Path) {
  # Read before any git command: status refreshes the index and would reset idle.
  $newest = [datetime]::MinValue
  try {
    $dotGit = Join-Path $Path '.git'
    if (-not [IO.File]::Exists($dotGit)) { return $newest }
    $line = ([IO.File]::ReadAllText($dotGit)).Trim()
    if ($line -notmatch '^gitdir:\s*(?<dir>.+)$') { return $newest }
    $gitDir = $Matches.dir.Trim()
    if (-not [IO.Path]::IsPathRooted($gitDir)) { $gitDir = Join-Path $Path $gitDir }
    foreach ($name in @('HEAD', 'index', 'logs\HEAD')) {
      $file = Join-Path $gitDir $name
      if ([IO.File]::Exists($file)) { $time = [IO.File]::GetLastWriteTimeUtc($file); if ($time -gt $newest) { $newest = $time } }
    }
  } catch {}
  $newest
}

function Get-SweepWorktreeFacts([string]$Path, [string]$Head, [string]$RepositoryRoot, [string[]]$Bases, [datetime]$Cutoff, [datetime]$Now) {
  $facts = [ordered]@{ exists = $false; statusReadable = $false; dirty = $false; statusText = ''; untrackedBytes = 0L; idleComplete = $false; newestWriteUtc = $null; idleHours = $null; inBase = $false }
  if (-not [IO.Directory]::Exists($Path)) { return [pscustomobject]$facts }
  $facts.exists = $true
  $admin = Get-SweepAdminNewest $Path
  $idle = Get-ReclamationIdle $Path $Cutoff
  if ($idle.complete) {
    $tree = if ($idle.state -ceq 'recent') { $Now } elseif ($idle.newestWriteUtc) { [datetime]::Parse($idle.newestWriteUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() } else { [datetime]::MinValue }
    $newest = if ($admin -gt $tree) { $admin } else { $tree }
    $facts.idleComplete = $true
    $facts.newestWriteUtc = if ($idle.state -ceq 'recent') { 'recent' } else { $newest.ToString('o') }
    $facts.idleHours = [Math]::Round(($Now - $newest).TotalHours, 2)
  }
  $status = Invoke-ReclamationGit $Path @('--no-optional-locks', '-c', 'core.quotePath=false', 'status', '--porcelain=v1', '--untracked-files=all')
  if ($status.exitCode -eq 0) {
    $facts.statusReadable = $true; $facts.statusText = $status.text; $facts.dirty = [bool]$status.text
    if ($facts.dirty) {
      foreach ($line in @($status.output | Where-Object { $_.StartsWith('?? ') })) {
        $file = Join-Path $Path $line.Substring(3).Trim('"')
        if ([IO.File]::Exists($file)) { $facts.untrackedBytes += ([IO.FileInfo]::new($file)).Length }
      }
    }
  }
  foreach ($base in $Bases) {
    if ((Invoke-ReclamationGit $RepositoryRoot @('merge-base', '--is-ancestor', $Head, $base)).exitCode -eq 0) { $facts.inBase = $true; break }
  }
  [pscustomobject]$facts
}

function Get-SweepWorktreeDecision($Row, $Context) {
  # Pure: every input is already on the row or the context.
  $policy = $Context.policy
  $threshold = if ($Row.evidenceSeat) { $policy.evidenceSeatIdleHours } elseif ($Row.facts.dirty) { $policy.dirtyIdleHours } else { $policy.cleanIdleHours }
  if ($Row.evidenceSeat -and $Row.facts.dirty) { $threshold = [Math]::Max($policy.evidenceSeatIdleHours, $policy.dirtyIdleHours) }
  $reason = if ($Row.globalBlock) { $Row.globalBlock }
    elseif ($Row.persistent) { 'persistent-checkout' }
    elseif (-not $Row.insideRoots) { 'outside-sweep-roots' }
    elseif ($Row.live) { 'live-owner' }
    elseif ($Row.locked) { 'locked' }
    elseif ($Row.keep) { 'keep-listed' }
    elseif ($Row.platform) { $Row.platform }
    elseif ($Row.openPr) { $Row.openPr }
    elseif (-not $Row.facts) { 'facts-unread' }
    elseif (-not $Row.facts.exists) { 'directory-missing' }
    elseif (-not $Row.facts.statusReadable) { 'status-unreadable' }
    elseif (-not $Row.facts.idleComplete) { 'idle-unreadable' }
    elseif ($Row.facts.idleHours -lt $threshold) { if ($Row.facts.dirty) { 'dirty-recent' } else { 'recent' } }
    elseif ($Row.facts.dirty -and $Row.facts.untrackedBytes -gt $policy.dirtySnapshotMaxBytes) { 'dirty-snapshot-too-large' }
    else { $null }
  $action = 'retain'
  if (-not $reason) {
    if ($Row.facts.dirty) { $action = 'snapshot-remove'; $reason = 'dirty-idle-snapshot' }
    elseif ($Row.facts.inBase) { $action = 'remove'; $reason = 'clean-in-base' }
    elseif ($Row.mergedPr) { $action = 'remove'; $reason = 'clean-merged-pr-head' }
    else { $action = 'remove'; $reason = 'clean-unmerged-preserved' }
  }
  [pscustomobject]@{ action = $action; reasonCode = $reason; thresholdHours = $threshold }
}

function Get-SweepWorktreeRows($Context, [string]$GlobalBlock) {
  $rows = [Collections.Generic.List[object]]::new()
  foreach ($repository in $Context.repositories) {
    foreach ($worktree in @(Get-ReclamationWorktrees $repository.root)) {
      if (Test-ReclamationSamePath $worktree.path $repository.root) { continue }
      $leaf = Split-Path -Leaf $worktree.path
      $entry = if ($Context.dispatch.paths.ContainsKey($worktree.path)) { $Context.dispatch.paths[$worktree.path] } else { $null }
      $issue = Get-SweepIssueNumber $leaf $worktree.branch $entry
      $rows.Add([pscustomobject][ordered]@{
          kind = 'worktree'; repository = $repository.identity; repositoryRoot = $repository.root; bases = $repository.bases
          path = $worktree.path; head = $worktree.head; branch = $worktree.branch; detached = $worktree.detached; locked = $worktree.locked
          issue = $issue; globalBlock = $GlobalBlock
          persistent = ($leaf -cmatch '^lane-[0-9]+$' -or (Test-ReclamationSamePath $worktree.path (Join-Path $Context.container 'main')))
          insideRoots = ((Test-ReclamationInside $worktree.path $Context.container) -or (Test-SweepUnder $worktree.path $Context.tempRoot))
          evidenceSeat = (Test-SweepUnder $worktree.path $Context.runtime)
          live = $false; keep = $false; platform = $null; openPr = $null; mergedPr = $null; facts = $null; action = 'retain'; reasonCode = $null
        })
    }
  }
  Resolve-SweepIssues $Context @($rows | ForEach-Object { $_.issue })
  foreach ($row in $rows) { Set-SweepWorktreeGuards $row $Context $Context.prCensus }
  # Facts are expensive (status and an idle walk); gather them only for rows the
  # cheap guards have not already retained.
  $pending = @($rows | Where-Object { -not ($_.globalBlock -or $_.persistent -or -not $_.insideRoots -or $_.live -or $_.locked -or $_.keep -or $_.platform -or $_.openPr) })
  $factsByPath = Get-SweepFactsParallel $Context $pending
  foreach ($row in $rows) {
    if ($factsByPath.ContainsKey($row.path)) { $row.facts = $factsByPath[$row.path] }
    $decision = Get-SweepWorktreeDecision $row $Context
    $row.action = $decision.action; $row.reasonCode = $decision.reasonCode
  }
  @($rows)
}

function Set-SweepWorktreeGuards($Row, $Context, $Census) {
  # The cheap keep-class guards, shared by inventory and the pre-mutation gate.
  $Row.live = Test-SweepLive $Context $Row.path $Row.branch
  $Row.keep = @($Context.keep | Where-Object { Test-SweepUnder $Row.path $_ }).Count -gt 0
  $Row.platform = Get-SweepPlatformReason $Context $Row.path $Row.branch $Row.issue
  $Row.openPr = $null; $Row.mergedPr = $null
  if ($Census.complete) {
    if ($Row.branch -and $Census.openHeadNames.ContainsKey($Row.branch)) { $Row.openPr = 'open-pr-head' }
    elseif ($Census.openHeadOids.ContainsKey($Row.head)) { $Row.openPr = 'open-pr-head' }
    elseif ($Row.branch -and $Census.openBaseNames.ContainsKey($Row.branch)) { $Row.openPr = 'open-pr-base' }
    if ($Census.mergedHeadOids.ContainsKey($Row.head)) { $Row.mergedPr = $Census.mergedHeadOids[$Row.head] }
  }
}

function Get-SweepFactsParallel($Context, [object[]]$Rows) {
  $result = @{}
  if (-not $Rows.Count) { return $result }
  $cutoff = $Context.now.AddHours(-$Context.policy.cleanIdleHours)
  $definitions = @{}
  foreach ($name in @('Get-ReclamationPath', 'Invoke-ReclamationGit', 'Get-ReclamationIdle', 'Get-SweepAdminNewest', 'Get-SweepWorktreeFacts')) {
    $definitions[$name] = (Get-Item "Function:$name").ScriptBlock.ToString()
  }
  $now = $Context.now
  $gathered = $Rows | ForEach-Object -ThrottleLimit $Context.policy.parallelism -Parallel {
    foreach ($pair in ($using:definitions).GetEnumerator()) { Set-Item "Function:$($pair.Key)" ([scriptblock]::Create($pair.Value)) }
    $row = $_
    try { $facts = Get-SweepWorktreeFacts $row.path $row.head $row.repositoryRoot $row.bases $using:cutoff $using:now }
    catch { $facts = $null }
    [pscustomobject]@{ path = $row.path; facts = $facts }
  }
  foreach ($item in @($gathered)) { if ($null -ne $item.facts) { $result[$item.path] = $item.facts } }
  $result
}

function Move-SweepToTrash($Context, [string]$Path) {
  [void][IO.Directory]::CreateDirectory($Context.trashRoot)
  $destination = Join-Path $Context.trashRoot ((Split-Path -Leaf $Path) + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  [IO.Directory]::Move($Path, $destination)
  $destination
}

function New-SweepSnapshot([string]$Path, [string]$RepositoryRoot, [string]$Head, [string]$RefName, [string]$Message) {
  $index = Join-Path ([IO.Path]::GetTempPath()) ('container-sweep-index-' + [guid]::NewGuid().ToString('N'))
  $identity = @{ GIT_AUTHOR_NAME = 'container-sweep'; GIT_AUTHOR_EMAIL = 'container-sweep@localhost'; GIT_COMMITTER_NAME = 'container-sweep'; GIT_COMMITTER_EMAIL = 'container-sweep@localhost' }
  try {
    $environment = @{ GIT_INDEX_FILE = $index }
    if ((Invoke-SweepGitEnv $Path @('read-tree', $Head) $environment).exitCode -ne 0) { throw 'snapshot read-tree failed' }
    if ((Invoke-SweepGitEnv $Path @('add', '-A', '--', '.') $environment).exitCode -ne 0) { throw 'snapshot add failed' }
    $tree = Invoke-SweepGitEnv $Path @('write-tree') $environment
    if ($tree.exitCode -ne 0 -or $tree.text -cnotmatch '^[0-9a-f]{40}$') { throw 'snapshot write-tree failed' }
  } finally { if ([IO.File]::Exists($index)) { [IO.File]::Delete($index) } }
  $commit = Invoke-SweepGitEnv $RepositoryRoot @('commit-tree', $tree.text, '-p', $Head, '-m', $Message) $identity
  if ($commit.exitCode -ne 0 -or $commit.text -cnotmatch '^[0-9a-f]{40}$') { throw 'snapshot commit-tree failed' }
  if ((Invoke-ReclamationGit $RepositoryRoot @('update-ref', $RefName, $commit.text, ('0' * 40))).exitCode -ne 0) { throw 'snapshot ref failed' }
  $commit.text
}

function Get-SweepGateResult($Fresh, $Row) {
  # A fresh decision equal to the inventory decision returns $null (act);
  # otherwise the fresh retain reason, or changed-before-apply.
  if ($Fresh.action -ceq $Row.action -and $Fresh.reasonCode -ceq $Row.reasonCode) { return $null }
  if ($Fresh.action -ceq 'retain' -and $Fresh.reasonCode) { return [string]$Fresh.reasonCode }
  'changed-before-apply'
}

function Invoke-SweepWorktreeRemoval($Row, $Context) {
  $outcome = [ordered]@{ path = $Row.path; repository = $Row.repository; head = $Row.head; branch = $Row.branch; reasonCode = $Row.reasonCode; result = 'changed-before-apply'; preservedRef = $null; snapshotRef = $null; trash = $null; branchResult = 'retained' }
  try {
    $block = Update-SweepAuthority $Context
    if ($block) { $outcome.result = $block; return [pscustomobject]$outcome }
    $current = @(Get-ReclamationWorktrees $Row.repositoryRoot | Where-Object { Test-ReclamationSamePath $_.path $Row.path })
    if ($current.Count -ne 1 -or $current[0].head -cne $Row.head -or $current[0].branch -cne $Row.branch -or $current[0].locked) { return [pscustomobject]$outcome }
    $fresh = Get-SweepWorktreeFacts $Row.path $Row.head $Row.repositoryRoot $Row.bases $Context.now.AddHours(-$Context.policy.cleanIdleHours) ([datetime]::UtcNow)
    if ($fresh.statusText -cne $Row.facts.statusText -or $fresh.newestWriteUtc -cne $Row.facts.newestWriteUtc) { return [pscustomobject]$outcome }
    $census = Get-SweepFreshCensus $Context $Row.branch
    if ($null -eq $census) { $outcome.result = 'pr-census-unknown'; return [pscustomobject]$outcome }
    $probe = $Row.PSObject.Copy(); $probe.globalBlock = $null; $probe.locked = $false; $probe.facts = $fresh
    $entry = if ($Context.dispatch.paths.ContainsKey($Row.path)) { $Context.dispatch.paths[$Row.path] } else { $null }
    $probe.issue = Get-SweepIssueNumber (Split-Path -Leaf $Row.path) $Row.branch $entry
    Update-SweepIssue $Context $probe.issue
    $probe.insideRoots = ((Test-ReclamationInside $Row.path $Context.container) -or (Test-SweepUnder $Row.path $Context.tempRoot))
    Set-SweepWorktreeGuards $probe $Context $census
    $gate = Get-SweepGateResult (Get-SweepWorktreeDecision $probe $Context) $Row
    if ($gate) { $outcome.result = $gate; return [pscustomobject]$outcome }
    if (-not $fresh.inBase) {
      $ref = "refs/reclaimed/$($Row.head)"
      if ((Invoke-ReclamationGit $Row.repositoryRoot @('update-ref', $ref, $Row.head)).exitCode -ne 0) { $outcome.result = 'preserve-ref-failed'; return [pscustomobject]$outcome }
      $outcome.preservedRef = $ref
    }
    if ($Row.action -ceq 'snapshot-remove') {
      $ref = "refs/reclaimed/snapshot/$(Get-SweepRefSegment (Split-Path -Leaf $Row.path))-$([datetime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))"
      $commit = New-SweepSnapshot $Row.path $Row.repositoryRoot $Row.head $ref "container-sweep snapshot of $($Row.path) (branch $($Row.branch)) at $($Row.head)"
      $outcome.snapshotRef = "$ref=$commit"
      $after = Invoke-ReclamationGit $Row.path @('--no-optional-locks', '-c', 'core.quotePath=false', 'status', '--porcelain=v1', '--untracked-files=all')
      if ($after.exitCode -ne 0 -or $after.text -cne $Row.facts.statusText) { $outcome.result = 'changed-after-snapshot'; $outcome.error = "status before: $($Row.facts.statusText) | after: $($after.text)"; return [pscustomobject]$outcome }
    }
    $sameVolume = [IO.Path]::GetPathRoot($Row.path).Equals([IO.Path]::GetPathRoot($Context.trashRoot), [StringComparison]::OrdinalIgnoreCase)
    if ($sameVolume) {
      try { $outcome.trash = Move-SweepToTrash $Context $Row.path }
      catch { $outcome.result = 'in-use'; return [pscustomobject]$outcome }
    } else {
      $arguments = @('worktree', 'remove'); if ($Row.action -ceq 'snapshot-remove') { $arguments += '--force' }
      if ((Invoke-ReclamationGit $Row.repositoryRoot ($arguments + @('--', $Row.path))).exitCode -ne 0) { $outcome.result = 'git-worktree-remove-failed'; return [pscustomobject]$outcome }
    }
    $outcome.result = if ($Row.action -ceq 'snapshot-remove') { 'snapshot-removed' } else { 'removed' }
  } catch { $outcome.result = 'error'; $outcome.error = $_.Exception.Message }
  [pscustomobject]$outcome
}

function Complete-SweepWorktreeRemovals($Context, [object[]]$Outcomes, [object[]]$Rows) {
  foreach ($repository in $Context.repositories) { [void](Invoke-ReclamationGit $repository.root @('worktree', 'prune')) }
  foreach ($outcome in @($Outcomes | Where-Object { $_.result -in @('removed', 'snapshot-removed') })) {
    $row = @($Rows | Where-Object { $_.path -ceq $outcome.path })[0]
    $still = @(Get-ReclamationWorktrees $row.repositoryRoot | Where-Object { Test-ReclamationSamePath $_.path $row.path })
    if ($still.Count) { $outcome.result = 'still-registered-after-prune'; continue }
    if (-not $row.branch -or $row.branch -match $script:SweepProtectedBranch) { continue }
    if (-not ($row.facts.inBase -or $row.mergedPr)) { $outcome.branchResult = 'retained-unmerged'; continue }
    # The branch goes through the branch phase's own decision and gate. Its
    # recency is the removed worktree's idle time: that worktree held the branch.
    $repository = @($Context.repositories | Where-Object { $_.identity -ceq $row.repository })[0]
    $branchRow = New-SweepBranchRow $repository $row.branch $row.head $Context $null
    $branchRow.refAgeSource = 'worktree-idle'; $branchRow.refAgeHours = [double]$row.facts.idleHours
    Resolve-SweepIssues $Context @($branchRow.issue)
    Set-SweepBranchEvidence $branchRow $Context $Context.prCensus
    if ($branchRow.action -cne 'delete') { $outcome.branchResult = "retained-$($branchRow.reasonCode)"; continue }
    $outcome.branchResult = (Invoke-SweepBranchDeletion $branchRow $Context).result
  }
}
# ---------------------------------------------------------------- branches

function Get-SweepBranchDecision($Row, $Context, $Census) {
  $census = if ($Census) { $Census } else { $Context.prCensus }
  $reason = if ($Row.globalBlock) { $Row.globalBlock }
    elseif ($Row.branch -match $script:SweepProtectedBranch) { 'protected-branch' }
    elseif ($Row.live) { 'live-owner' }
    elseif ($Row.platform) { $Row.platform }
    elseif ($census.openHeadNames.ContainsKey($Row.branch) -or $census.openHeadOids.ContainsKey($Row.head) -or $census.openBaseNames.ContainsKey($Row.branch)) { 'open-pr' }
    elseif ($Row.refAgeHours -lt $Context.policy.branchRecentHours) { 'recent' }
    else { $null }
  if ($reason) { return [pscustomobject]@{ action = 'retain'; reasonCode = $reason } }
  if ($Row.inBase) { return [pscustomobject]@{ action = 'delete'; reasonCode = 'branch-in-base' } }
  if ($census.mergedHeadOids.ContainsKey($Row.head)) { return [pscustomobject]@{ action = 'delete'; reasonCode = 'branch-merged-pr-head' } }
  [pscustomobject]@{ action = 'retain'; reasonCode = 'branch-unmerged' }
}

function Get-SweepRefAgeHours([string]$RepositoryRoot, [string]$Branch, [datetime]$Now) {
  # --path-format=absolute needs git 2.31; resolve a relative common dir ourselves.
  $common = Invoke-ReclamationGit $RepositoryRoot @('rev-parse', '--git-common-dir')
  if ($common.exitCode -ne 0) { return 0 }
  $commonDir = if ([IO.Path]::IsPathRooted($common.text)) { $common.text } else { Join-Path $RepositoryRoot $common.text }
  $log = Join-Path $commonDir ('logs\refs\heads\' + $Branch.Replace('/', '\'))
  if (-not [IO.File]::Exists($log)) { return [double]::MaxValue }
  ($Now - [IO.File]::GetLastWriteTimeUtc($log)).TotalHours
}

function New-SweepBranchRow($Repository, [string]$Branch, [string]$Head, $Context, [string]$GlobalBlock) {
  $entry = if ($Context.dispatch.branches.ContainsKey($Branch)) { $Context.dispatch.branches[$Branch] } else { $null }
  [pscustomobject][ordered]@{
    kind = 'branch'; repository = $Repository.identity; repositoryRoot = $Repository.root; bases = $Repository.bases; branch = $Branch; head = $Head
    issue = (Get-SweepIssueNumber '' $Branch $entry); globalBlock = $GlobalBlock; live = $false; platform = $null
    refAgeHours = 0.0; refAgeSource = 'reflog'; inBase = $false; action = 'retain'; reasonCode = $null
  }
}

function Set-SweepBranchEvidence($Row, $Context, $Census) {
  # Shared by inventory and the pre-mutation gate.
  $Row.live = $Context.liveBranches.Contains($Row.branch)
  $Row.platform = Get-SweepPlatformReason $Context '' $Row.branch $Row.issue
  $Row.inBase = $false
  if (-not $Row.globalBlock -and $Row.branch -notmatch $script:SweepProtectedBranch) {
    if ($Row.refAgeSource -ceq 'reflog') { $Row.refAgeHours = [Math]::Round((Get-SweepRefAgeHours $Row.repositoryRoot $Row.branch $Context.now), 2) }
    foreach ($base in $Row.bases) {
      if ((Invoke-ReclamationGit $Row.repositoryRoot @('merge-base', '--is-ancestor', $Row.head, $base)).exitCode -eq 0) { $Row.inBase = $true; break }
    }
  }
  $decision = Get-SweepBranchDecision $Row $Context $Census
  $Row.action = $decision.action; $Row.reasonCode = $decision.reasonCode
}

function Get-SweepBranchRows($Context, [string]$GlobalBlock) {
  $rows = [Collections.Generic.List[object]]::new()
  foreach ($repository in $Context.repositories) {
    $checked = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($worktree in @(Get-ReclamationWorktrees $repository.root)) { if ($worktree.branch) { [void]$checked.Add($worktree.branch) } }
    foreach ($branch in @(Get-ReclamationBranches $repository.root)) {
      if ($checked.Contains($branch.branch)) { continue }
      $rows.Add((New-SweepBranchRow $repository $branch.branch $branch.head $Context $GlobalBlock))
    }
  }
  Resolve-SweepIssues $Context @($rows | ForEach-Object { $_.issue })
  foreach ($row in $rows) { Set-SweepBranchEvidence $row $Context $Context.prCensus }
  @($rows)
}

function Invoke-SweepBranchDeletion($Row, $Context) {
  $outcome = [ordered]@{ repository = $Row.repository; branch = $Row.branch; head = $Row.head; reasonCode = $Row.reasonCode; result = 'changed-before-apply' }
  $block = Update-SweepAuthority $Context
  if ($block) { $outcome.result = $block; return [pscustomobject]$outcome }
  $tip = Invoke-ReclamationGit $Row.repositoryRoot @('rev-parse', '-q', '--verify', "refs/heads/$($Row.branch)")
  if ($tip.exitCode -ne 0 -or $tip.text -cne $Row.head) { return [pscustomobject]$outcome }
  if (@(Get-ReclamationWorktrees $Row.repositoryRoot | Where-Object { $_.branch -ceq $Row.branch }).Count) { $outcome.result = 'checked-out'; return [pscustomobject]$outcome }
  $census = Get-SweepFreshCensus $Context $Row.branch
  if ($null -eq $census) { $outcome.result = 'pr-census-unknown'; return [pscustomobject]$outcome }
  $probe = $Row.PSObject.Copy(); $probe.globalBlock = $null
  $entry = if ($Context.dispatch.branches.ContainsKey($Row.branch)) { $Context.dispatch.branches[$Row.branch] } else { $null }
  $probe.issue = Get-SweepIssueNumber '' $Row.branch $entry
  Update-SweepIssue $Context $probe.issue
  Set-SweepBranchEvidence $probe $Context $census
  $gate = Get-SweepGateResult $probe $Row
  if ($gate) { $outcome.result = $gate; return [pscustomobject]$outcome }
  $delete = Invoke-ReclamationGit $Row.repositoryRoot @('update-ref', '--no-deref', '-d', "refs/heads/$($Row.branch)", $Row.head)
  $outcome.result = if ($delete.exitCode -eq 0) { 'deleted-exact-sha' } else { 'exact-ref-delete-failed' }
  [pscustomobject]$outcome
}

# ---------------------------------------------------------------- directories

function Get-SweepDirectoryFacts([string]$Path, [Nullable[datetime]]$Cutoff, [datetime]$Now, [scriptblock]$OnFile) {
  $facts = [ordered]@{ complete = $false; recent = $false; newestWriteUtc = $null; idleHours = $null; files = 0; bytes = 0L; reparsePoints = 0 }
  $options = [IO.EnumerationOptions]@{ AttributesToSkip = 0; IgnoreInaccessible = $false; RecurseSubdirectories = $false }
  try {
    $root = [IO.DirectoryInfo]::new($Path)
    $newest = $root.LastWriteTimeUtc
    $stack = [Collections.Generic.Stack[IO.DirectoryInfo]]::new(); $stack.Push($root)
    while ($stack.Count) {
      $directory = $stack.Pop()
      if ($directory.LastWriteTimeUtc -gt $newest) { $newest = $directory.LastWriteTimeUtc }
      foreach ($entry in $directory.EnumerateFileSystemInfos('*', $options)) {
        if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { $facts.reparsePoints++; continue }
        if ($entry -is [IO.DirectoryInfo]) { if ($entry.Name -cne 'node_modules') { $stack.Push($entry) }; continue }
        $facts.files++; $facts.bytes += $entry.Length
        if ($entry.LastWriteTimeUtc -gt $newest) { $newest = $entry.LastWriteTimeUtc }
        if ($OnFile) { & $OnFile $entry ([IO.Path]::GetRelativePath($Path, $entry.FullName)) }
      }
      if ($null -ne $Cutoff -and $newest -gt $Cutoff) { $facts.recent = $true; break }
    }
    $facts.complete = $true
    $facts.newestWriteUtc = $newest.ToString('o'); $facts.idleHours = [Math]::Round(($Now - $newest).TotalHours, 2)
  } catch { $facts.complete = $false }
  [pscustomobject]$facts
}

function Get-SweepRegisteredPaths($Context) {
  $registered = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($repository in $Context.repositories) { foreach ($worktree in @(Get-ReclamationWorktrees $repository.root)) { [void]$registered.Add($worktree.path) } }
  $registered
}

function Get-SweepDirectoryRow([IO.DirectoryInfo]$Directory, $Context, [string]$GlobalBlock, $Registered) {
  # One container-root directory, or $null when it is not a directory row.
  # Shared by inventory and the pre-mutation gate.
  $name = $Directory.Name
  if ($name.StartsWith('.') -or $name -ceq 'main' -or $name -cmatch '^lane-[0-9]+$') { return $null }
  $path = Get-ReclamationPath $Directory.FullName
  if ($Registered.Contains($path)) { return $null }
  $row = [ordered]@{ kind = 'directory'; path = $path; name = $name; gitKind = 'none'; facts = $null; action = 'retain'; reasonCode = $null }
  $dotGit = Join-Path $path '.git'
  if ([IO.Directory]::Exists($dotGit)) { $row.gitKind = 'clone' }
  elseif ([IO.File]::Exists($dotGit)) {
    $row.gitKind = 'gitfile-orphan'
    try {
      $line = ([IO.File]::ReadAllText($dotGit)).Trim()
      if ($line -match '^gitdir:\s*(?<dir>.+)$') {
        $gitDir = $Matches.dir.Trim(); if (-not [IO.Path]::IsPathRooted($gitDir)) { $gitDir = Join-Path $path $gitDir }
        if ([IO.Directory]::Exists($gitDir)) { $row.gitKind = 'gitfile-registered' }
      }
    } catch { $row.gitKind = 'gitfile-unreadable' }
  }
  $platform = Get-SweepPlatformReason $Context $path '' 0
  $row.reasonCode = if ($GlobalBlock) { $GlobalBlock }
    elseif ($Directory.Attributes -band [IO.FileAttributes]::ReparsePoint) { 'reparse-point' }
    elseif ($row.gitKind -ceq 'clone') { 'foreign-clone' }
    elseif ($row.gitKind -ceq 'gitfile-registered') { 'foreign-worktree' }
    elseif ($row.gitKind -ceq 'gitfile-unreadable') { 'gitfile-unreadable' }
    elseif (@($Context.keep | Where-Object { Test-SweepUnder $path $_ }).Count) { 'keep-listed' }
    elseif (Test-SweepLive $Context $path '') { 'live-owner' }
    elseif ($platform) { $platform }
    else { $null }
  if (-not $row.reasonCode) {
    $row.facts = Get-SweepDirectoryFacts $path $Context.now.AddHours(-$Context.policy.directoryIdleHours) $Context.now $null
    $row.reasonCode = if (-not $row.facts.complete) { 'idle-unreadable' }
      elseif ($row.facts.recent -or $row.facts.idleHours -lt $Context.policy.directoryIdleHours) { 'recent' }
      elseif ($row.facts.bytes -gt $Context.policy.directoryArchiveMaxBytes) { 'too-large-to-archive' }
      else { $row.action = 'archive-remove'; 'unregistered-directory' }
  }
  [pscustomobject]$row
}

function Get-SweepDirectoryRows($Context, [string]$GlobalBlock) {
  $registered = Get-SweepRegisteredPaths $Context
  $rows = [Collections.Generic.List[object]]::new()
  foreach ($directory in @([IO.DirectoryInfo]::new($Context.container).EnumerateDirectories())) {
    $row = Get-SweepDirectoryRow $directory $Context $GlobalBlock $registered
    if ($row) { $rows.Add($row) }
  }
  @($rows)
}

function Invoke-SweepDirectoryArchive($Row, $Context) {
  $outcome = [ordered]@{ path = $Row.path; reasonCode = $Row.reasonCode; result = 'changed-before-apply'; archive = $null; entries = 0; trash = $null }
  if (-not [IO.Directory]::Exists($Row.path)) { return [pscustomobject]$outcome }
  $block = Update-SweepAuthority $Context
  if ($block) { $outcome.result = $block; return [pscustomobject]$outcome }
  $registered = try { Get-SweepRegisteredPaths $Context } catch { $null }
  if ($null -eq $registered) { $outcome.result = 'worktree-inventory-unreadable'; return [pscustomobject]$outcome }
  if ($registered.Contains($Row.path)) { $outcome.result = 'registered'; return [pscustomobject]$outcome }
  $fresh = try { Get-SweepDirectoryRow ([IO.DirectoryInfo]::new($Row.path)) $Context $null $registered } catch { $null }
  if ($null -eq $fresh) { return [pscustomobject]$outcome }
  $gate = Get-SweepGateResult $fresh $Row
  if ($gate) { $outcome.result = $gate; return [pscustomobject]$outcome }
  if ($fresh.facts.newestWriteUtc -cne $Row.facts.newestWriteUtc -or $fresh.facts.files -ne $Row.facts.files) { return [pscustomobject]$outcome }
  [void][IO.Directory]::CreateDirectory($Context.archiveRoot)
  $archive = Join-Path $Context.archiveRoot "$($Row.name).zip"
  if ([IO.File]::Exists($archive)) { $archive = Join-Path $Context.archiveRoot "$($Row.name)-$([guid]::NewGuid().ToString('N').Substring(0, 8)).zip" }
  $partial = "$archive.partial"
  $zip = $null
  try {
    $zip = [IO.Compression.ZipFile]::Open($partial, [IO.Compression.ZipArchiveMode]::Create)
    $state = @{ zip = $zip; written = 0 }
    $facts = Get-SweepDirectoryFacts $Row.path $null ([datetime]::UtcNow) {
      param($File, $Relative)
      [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($state.zip, $File.FullName, $Relative.Replace('\', '/'), [IO.Compression.CompressionLevel]::Optimal)
      $state.written++
    }
    $zip.Dispose(); $zip = $null
    if (-not $facts.complete -or $facts.newestWriteUtc -cne $Row.facts.newestWriteUtc -or $facts.files -ne $Row.facts.files) { [IO.File]::Delete($partial); return [pscustomobject]$outcome }
    $read = [IO.Compression.ZipFile]::OpenRead($partial)
    try { $outcome.entries = $read.Entries.Count } finally { $read.Dispose() }
    if ($outcome.entries -ne $facts.files -or $state.written -ne $facts.files) { [IO.File]::Delete($partial); $outcome.result = 'archive-verify-failed'; return [pscustomobject]$outcome }
    [IO.File]::Move($partial, $archive); $outcome.archive = $archive
    try { $outcome.trash = Move-SweepToTrash $Context $Row.path } catch { $outcome.result = 'in-use'; return [pscustomobject]$outcome }
    $outcome.result = 'archived-removed'
  } catch {
    if ($zip) { $zip.Dispose() }
    if ([IO.File]::Exists($partial)) { [IO.File]::Delete($partial) }
    $outcome.result = 'archive-failed'; $outcome.error = $_.Exception.Message
  }
  [pscustomobject]$outcome
}

# ---------------------------------------------------------------- remote branches

function Get-SweepRemoteDecision($Row, $Context, $Census) {
  $census = if ($Census) { $Census } else { $Context.prCensus }; $policy = $Context.policy
  $reason = if ($Row.globalBlock) { $Row.globalBlock }
    elseif ($Row.branch -match $script:SweepProtectedBranch) { 'protected-branch' }
    elseif ($Row.branch -notmatch $script:SweepLanePattern) { 'not-lane-branch' }
    elseif ($Row.live) { 'live-owner' }
    elseif ($Row.platform) { $Row.platform }
    elseif ($Row.checkedOut) { 'checked-out' }
    elseif ($census.openHeadNames.ContainsKey($Row.branch) -or $census.openBaseNames.ContainsKey($Row.branch) -or $census.openHeadOids.ContainsKey($Row.head)) { 'open-pr' }
    else { $null }
  if ($reason) { return [pscustomobject]@{ action = 'retain'; reasonCode = $reason } }
  $prs = if ($census.byHeadName.ContainsKey($Row.branch)) { @($census.byHeadName[$Row.branch]) } else { @() }
  if (@($prs | Where-Object { [string]$_.state -ceq 'MERGED' -and [string]$_.headRefOid -ceq $Row.head }).Count) { return [pscustomobject]@{ action = 'delete'; reasonCode = 'merged-pr-head' } }
  if (@($prs | Where-Object { [string]$_.state -ceq 'MERGED' }).Count) { return [pscustomobject]@{ action = 'retain'; reasonCode = 'pushed-after-merge' } }
  if (-not $prs.Count) { return [pscustomobject]@{ action = 'retain'; reasonCode = 'no-pr' } }
  $closed = @($prs | Where-Object { [string]$_.state -ceq 'CLOSED' -and $_.closedAt } | Sort-Object { [datetime]::Parse([string]$_.closedAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) } -Descending)
  if (-not $closed.Count) { return [pscustomobject]@{ action = 'retain'; reasonCode = 'pr-state-unknown' } }
  if ([string]$closed[0].headRefOid -cne $Row.head) { return [pscustomobject]@{ action = 'retain'; reasonCode = 'pushed-after-close' } }
  $closedAt = [datetime]::Parse([string]$closed[0].closedAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
  if (($Context.now - $closedAt).TotalHours -lt $policy.remoteClosedIdleHours) { return [pscustomobject]@{ action = 'retain'; reasonCode = 'closed-pr-recent' } }
  [pscustomobject]@{ action = 'delete'; reasonCode = 'closed-pr-head-stale' }
}

function Get-SweepCheckedOut($Repository) {
  $checked = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($worktree in @(Get-ReclamationWorktrees $Repository)) { if ($worktree.branch) { [void]$checked.Add($worktree.branch) } }
  $checked
}

function Set-SweepRemoteEvidence($Row, $Context, $Census, $Checked) {
  # Shared by inventory and the pre-mutation gate.
  $Row.live = $Context.liveBranches.Contains($Row.branch)
  $Row.checkedOut = $Checked.Contains($Row.branch)
  $Row.platform = Get-SweepPlatformReason $Context '' $Row.branch $Row.issue
  $decision = Get-SweepRemoteDecision $Row $Context $Census
  $Row.action = $decision.action; $Row.reasonCode = $decision.reasonCode
}

function Get-SweepRemoteRows($Context, [string]$GlobalBlock) {
  $product = @($Context.repositories | Where-Object { $_.identity -ceq 'product' })[0]
  if (-not $product) { return @() }
  $heads = try { & $Context.resolvers.LsRemote $product.root } catch { $null }
  if ($null -eq $heads) { return @([pscustomobject]@{ kind = 'remote'; branch = ''; head = ''; action = 'retain'; reasonCode = 'remote-unreadable' }) }
  $checked = Get-SweepCheckedOut $product.root
  $rows = @(foreach ($head in @($heads)) {
      [pscustomobject][ordered]@{ kind = 'remote'; repositoryRoot = $product.root; branch = $head.branch; head = $head.sha; issue = (Get-SweepIssueNumber '' $head.branch $null)
        globalBlock = $GlobalBlock; live = $false; checkedOut = $false; platform = $null; action = 'retain'; reasonCode = $null }
    })
  Resolve-SweepIssues $Context @($rows | ForEach-Object { $_.issue })
  foreach ($row in $rows) { Set-SweepRemoteEvidence $row $Context $Context.prCensus $checked }
  $rows
}

function Invoke-SweepRemoteDeletion($Row, $Context) {
  $outcome = [ordered]@{ branch = $Row.branch; head = $Row.head; reasonCode = $Row.reasonCode; result = 'changed-before-apply'; preservedRef = $null }
  $block = Update-SweepAuthority $Context
  if ($block) { $outcome.result = $block; return [pscustomobject]$outcome }
  $census = Get-SweepFreshCensus $Context $Row.branch
  if ($null -eq $census) { $outcome.result = 'pr-census-unknown'; return [pscustomobject]$outcome }
  $checked = try { Get-SweepCheckedOut $Row.repositoryRoot } catch { $null }
  if ($null -eq $checked) { $outcome.result = 'worktree-inventory-unreadable'; return [pscustomobject]$outcome }
  Update-SweepIssue $Context $Row.issue
  $probe = $Row.PSObject.Copy(); $probe.globalBlock = $null
  Set-SweepRemoteEvidence $probe $Context $census $checked
  $gate = Get-SweepGateResult $probe $Row
  if ($gate) { $outcome.result = $gate; return [pscustomobject]$outcome }
  $ref = "refs/reclaimed/remote/$($Row.branch)"
  [void](Invoke-ReclamationGit $Row.repositoryRoot @('fetch', '--no-tags', '--quiet', 'origin', "+refs/heads/$($Row.branch):$ref"))
  $saved = Invoke-ReclamationGit $Row.repositoryRoot @('rev-parse', '-q', '--verify', $ref)
  if ($saved.exitCode -ne 0 -or $saved.text -cne $Row.head) { return [pscustomobject]$outcome }
  $outcome.preservedRef = $ref
  $push = Invoke-ReclamationGit $Row.repositoryRoot @('push', '--porcelain', "--force-with-lease=refs/heads/$($Row.branch):$($Row.head)", 'origin', ":refs/heads/$($Row.branch)")
  $outcome.result = if ($push.exitCode -eq 0) { 'deleted-pinned-lease' } else { 'lease-refused-or-failed' }
  [pscustomobject]$outcome
}

# ---------------------------------------------------------------- draft PRs

function Get-SweepDraftDecision($Node, $Context) {
  $labels = @($Node.labels.nodes | ForEach-Object { [string]$_.name })
  $issues = @($Node.closingIssuesReferences.nodes)
  $updated = [datetime]::Parse([string]$Node.updatedAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
  $platform = Get-SweepPlatformReason $Context '' ([string]$Node.headRefName) 0
  $reason = if ($Context.draftBlock) { $Context.draftBlock }
    elseif ([string]$Node.headRefName -notmatch $script:SweepLanePattern) { 'not-lane-branch' }
    elseif ([string]$Node.title -match $script:SweepNeverClosePattern -or @($labels | Where-Object { $_ -match $script:SweepNeverClosePattern }).Count) { 'never-close-marked' }
    elseif ($Context.liveBranches.Contains([string]$Node.headRefName)) { 'live-owner' }
    elseif ($platform) { $platform }
    elseif (($Context.now - $updated).TotalHours -lt $Context.policy.draftIdleHours) { 'recent' }
    elseif (-not $issues.Count) { 'no-closing-issue' }
    elseif (@($issues | Where-Object { [string]$_.state -cne 'CLOSED' -or [string]$_.stateReason -cne 'COMPLETED' }).Count) { 'issue-open-or-not-completed' }
    elseif (@($issues | Where-Object { $null -ne $_.milestone -and [int]$_.milestone.number -in @($Context.register.milestones) }).Count) { 'platform-owned-milestone' }
    else { $null }
  if ($reason) { return [pscustomobject]@{ action = 'retain'; reasonCode = $reason } }
  [pscustomobject]@{ action = 'close'; reasonCode = 'draft-issue-completed' }
}

function Get-SweepDraftRows($Context, [string]$GlobalBlock) {
  $Context | Add-Member -NotePropertyName draftBlock -NotePropertyValue $GlobalBlock -Force
  @(foreach ($node in @($Context.prCensus.nodes | Where-Object { [string]$_.state -ceq 'OPEN' -and $_.isDraft -eq $true })) {
      $decision = Get-SweepDraftDecision $node $Context
      [pscustomobject][ordered]@{ kind = 'draft-pr'; number = [int]$node.number; headRefName = [string]$node.headRefName; headRefOid = [string]$node.headRefOid
        updatedAt = [string]$node.updatedAt; issues = @($node.closingIssuesReferences.nodes | ForEach-Object { [int]$_.number }); action = $decision.action; reasonCode = $decision.reasonCode }
    })
}

function Invoke-SweepDraftClose($Row, $Context) {
  $outcome = [ordered]@{ number = $Row.number; reasonCode = $Row.reasonCode; result = 'changed-before-apply' }
  $block = Update-SweepAuthority $Context
  if ($block) { $outcome.result = $block; return [pscustomobject]$outcome }
  $view = try { & $Context.resolvers.PrView $Row.number } catch { $null }
  if ($null -eq $view -or [string]$view.state -cne 'OPEN' -or $view.isDraft -ne $true -or [string]$view.headRefOid -cne $Row.headRefOid -or [string]$view.updatedAt -cne $Row.updatedAt) { return [pscustomobject]$outcome }
  # The fresh node carries title, labels and closing issues; re-derive the
  # whole decision from it and the refreshed liveness and register.
  $Context | Add-Member -NotePropertyName draftBlock -NotePropertyValue $null -Force
  $gate = Get-SweepGateResult (Get-SweepDraftDecision $view $Context) $Row
  if ($gate) { $outcome.result = $gate; return [pscustomobject]$outcome }
  $issueList = ($Row.issues | ForEach-Object { "#$_" }) -join ', '
  $comment = "Closed by the container sweep: this draft has been idle for 14+ days and its closing issue $issueList closed as completed. The branch is kept; reopen the PR to resume."
  $code = try { & $Context.resolvers.PrClose $Row.number $comment } catch { -1 }
  $outcome.result = if ($code -eq 0) { 'closed-with-comment' } else { 'close-failed' }
  [pscustomobject]$outcome
}

# ---------------------------------------------------------------- scheduled tasks

function Get-SweepTaskDecision($Task, $Context) {
  $idleFrom = if ($Task.lastRunUtc) { $Task.lastRunUtc } else { $Task.registeredUtc }
  $reason = if ([string]$Task.state -ceq 'Running') { 'running' }
    elseif ($Task.nextRunUtc) { 'scheduled' }
    elseif (-not $Task.launcher -or -not (Test-SweepUnder $Task.launcher $Context.tempRoot) -or $Task.launcher -notmatch '(?i)\.vbs$') { 'launcher-unrecognized' }
    elseif ($null -eq $idleFrom) { 'idle-unknown' }
    elseif (($Context.now - $idleFrom).TotalHours -lt $Context.policy.taskIdleHours) { 'recent' }
    else { $null }
  if ($reason) { return [pscustomobject]@{ action = 'retain'; reasonCode = $reason } }
  [pscustomobject]@{ action = 'unregister'; reasonCode = 'one-shot-lane-task-idle' }
}

function Get-SweepScheduledTasks {
  @(foreach ($task in @(Get-ScheduledTask -TaskName 'chase-sets-lane-*' -ErrorAction SilentlyContinue)) {
      $info = $task | Get-ScheduledTaskInfo
      $launcher = $null
      $action = @($task.Actions)[0]
      if ($action -and [string]$action.Arguments -match '"(?<path>[^"]+\.vbs)"') { $launcher = $Matches.path }
      $last = if ($info.LastRunTime -and $info.LastRunTime.Year -gt 2000) { $info.LastRunTime.ToUniversalTime() } else { $null }
      $next = if ($info.NextRunTime) { $info.NextRunTime.ToUniversalTime() } else { $null }
      $registered = $null; if ($task.Date) { try { $registered = ([datetime]$task.Date).ToUniversalTime() } catch {} }
      [pscustomobject]@{ name = $task.TaskName; state = [string]$task.State; lastRunUtc = $last; nextRunUtc = $next; registeredUtc = $registered; launcher = $launcher }
    })
}

function Get-SweepTaskRows($Context) {
  @(foreach ($task in @(& $Context.resolvers.ScheduledTasks)) {
      $decision = Get-SweepTaskDecision $task $Context
      [pscustomobject][ordered]@{ kind = 'scheduled-task'; name = $task.name; state = $task.state; lastRunUtc = $task.lastRunUtc; launcher = $task.launcher; action = $decision.action; reasonCode = $decision.reasonCode }
    })
}

function Invoke-SweepTaskRemoval($Row, $Context) {
  $outcome = [ordered]@{ name = $Row.name; reasonCode = $Row.reasonCode; result = 'changed-before-apply'; launcherDeleted = $false }
  $fresh = @(& $Context.resolvers.ScheduledTasks | Where-Object { $_.name -ceq $Row.name })
  if ($fresh.Count -ne 1 -or (Get-SweepTaskDecision $fresh[0] $Context).action -cne 'unregister') { return [pscustomobject]$outcome }
  try { & $Context.resolvers.UnregisterTask $Row.name } catch { $outcome.result = 'unregister-failed'; $outcome.error = $_.Exception.Message; return [pscustomobject]$outcome }
  if ($Row.launcher -and [IO.File]::Exists($Row.launcher) -and (Test-SweepUnder $Row.launcher $Context.tempRoot)) { [IO.File]::Delete($Row.launcher); $outcome.launcherDeleted = $true }
  $outcome.result = 'unregistered'
  [pscustomobject]$outcome
}
# ---------------------------------------------------------------- docker

function ConvertTo-SweepSandboxIdentity([string]$Path) {
  # Mirrors scripts/lib/sandbox.mjs normalizeSandboxWorktreeIdentity.
  ([IO.Path]::GetFullPath($Path)).Replace('\', '/').TrimEnd('/').ToLowerInvariant()
}

$script:SweepSandboxOwner = 'local-worktree-v1'

function Get-SweepSandboxIdentities($Context) {
  $registered = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  $product = @($Context.repositories | Where-Object { $_.identity -ceq 'product' })[0]
  if ($product) { foreach ($worktree in @(Get-ReclamationWorktrees $product.root)) { [void]$registered.Add((ConvertTo-SweepSandboxIdentity $worktree.path)) } }
  $registered
}

function Get-SweepSandboxRow([string]$Id, [string]$Name, [string]$Worktree, $Registered, $Context) {
  # Shared by inventory and the pre-mutation gate. A sandbox whose worktree
  # label names a live path (a lane re-created there) is retained.
  $reason = if (-not $Worktree) { 'worktree-label-missing' }
    elseif ($Registered.Contains($Worktree) -or [IO.Directory]::Exists($Worktree)) { 'worktree-present' }
    elseif (Test-SweepLive $Context $Worktree.Replace('/', '\') '') { 'live-owner' }
    else { 'worktree-gone' }
  [pscustomobject]@{ kind = 'sandbox-container'; id = $Id; name = $Name; worktree = $Worktree; action = $(if ($reason -ceq 'worktree-gone') { 'stop' } else { 'retain' }); reasonCode = $reason }
}

function Get-SweepVolumeRow($Volume, $Context) {
  # $null.PSObject still enumerates properties, so test for null labels first.
  $labels = if ($null -eq $Volume.Labels) { @() } else { @($Volume.Labels.PSObject.Properties | Where-Object { $_.Name -cne 'com.docker.volume.anonymous' }) }
  $created = [datetime]::MinValue
  [void][datetime]::TryParse([string]$Volume.CreatedAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$created)
  $old = $created -gt [datetime]::MinValue -and ($Context.now - $created).TotalHours -ge $Context.policy.anonymousVolumeIdleHours
  $reason = if ($labels.Count) { 'labelled' } elseif (-not $old) { 'recent' } else { 'anonymous-unattached-idle' }
  [pscustomobject]@{ kind = 'anonymous-volume'; id = [string]$Volume.Name; created = [string]$Volume.CreatedAt; action = $(if ($reason -ceq 'anonymous-unattached-idle') { 'remove' } else { 'retain' }); reasonCode = $reason }
}

function Get-SweepDanglingVolumes($Context) {
  # Anonymous dangling volume ids, or $null when docker cannot say.
  $dangling = & $Context.resolvers.Docker @('volume', 'ls', '-q', '--filter', 'dangling=true') 30000
  if ($dangling.exitCode -ne 0) { return $null }
  # The comma keeps an empty list distinct from $null (unknown).
  return , @($dangling.stdout -split "`r?`n" | Where-Object { $_ -cmatch '^[0-9a-f]{64}$' })
}

function Test-SweepDockerFresh($Row, $Context) {
  # Fresh-evidence gate for one docker row: $null to act, else the retain reason.
  $docker = $Context.resolvers.Docker
  $block = Update-SweepAuthority $Context
  if ($block) { return $block }
  if ($Row.kind -ceq 'sandbox-container') {
    $format = '{{.State.Running}}|{{index .Config.Labels "com.chase-sets.sandbox.owner"}}|{{index .Config.Labels "com.chase-sets.sandbox.worktree"}}'
    $inspect = & $docker @('inspect', '--format', $format, $Row.id) 30000
    if ($inspect.exitCode -ne 0) { return 'inspect-failed' }
    $running, $owner, $worktree = ([string]$inspect.stdout).Trim().Split('|', 3)
    if ($running -cne 'true') { return 'not-running' }
    if ($owner -cne $script:SweepSandboxOwner -or $worktree -cne $Row.worktree) { return 'labels-changed' }
    $registered = try { Get-SweepSandboxIdentities $Context } catch { $null }
    if ($null -eq $registered) { return 'worktree-inventory-unreadable' }
    return (Get-SweepGateResult (Get-SweepSandboxRow $Row.id $Row.name $worktree $registered $Context) $Row)
  }
  $ids = Get-SweepDanglingVolumes $Context
  if ($null -eq $ids) { return 'volume-list-failed' }
  if ($Row.id -cnotin $ids) { return 'volume-attached' }
  $inspect = & $docker @('volume', 'inspect', $Row.id) 30000
  if ($inspect.exitCode -ne 0) { return 'inspect-failed' }
  $volume = try { @($inspect.stdout | ConvertFrom-Json -DateKind String)[0] } catch { $null }
  if ($null -eq $volume -or [string]$volume.Name -cne $Row.id -or [string]$volume.CreatedAt -cne $Row.created) { return 'changed-before-apply' }
  Get-SweepGateResult (Get-SweepVolumeRow $volume $Context) $Row
}

function Invoke-SweepDocker($Context, [switch]$Apply, [scriptblock]$BeforeAct) {
  $result = [ordered]@{ status = 'ok'; rows = @(); results = @(); commands = @() }
  $docker = $Context.resolvers.Docker
  $probe = & $docker @('version', '--format', '{{.Server.Version}}') 20000
  if ($probe.exitCode -ne 0) { $result.status = 'docker-unavailable'; return [pscustomobject]$result }
  $registered = Get-SweepSandboxIdentities $Context
  $product = @($Context.repositories | Where-Object { $_.identity -ceq 'product' })[0]
  $rows = [Collections.Generic.List[object]]::new()
  $running = & $docker @('ps', '--no-trunc', '--filter', "label=com.chase-sets.sandbox.owner=$script:SweepSandboxOwner", '--filter', 'status=running', '--format', '{{.ID}}|{{.Names}}|{{.Label "com.chase-sets.sandbox.worktree"}}') 30000
  if ($running.exitCode -eq 0) {
    foreach ($line in @($running.stdout -split "`r?`n" | Where-Object { $_ })) {
      $id, $name, $worktree = $line.Split('|', 3)
      $rows.Add((Get-SweepSandboxRow $id $name $worktree $registered $Context))
    }
  } else { $result.status = 'container-list-failed' }
  $anonymous = Get-SweepDanglingVolumes $Context
  if ($null -ne $anonymous -and $anonymous.Count) {
    $inspect = & $docker (@('volume', 'inspect') + $anonymous) 60000
    if ($inspect.exitCode -eq 0) {
      foreach ($volume in @($inspect.stdout | ConvertFrom-Json -DateKind String)) { $rows.Add((Get-SweepVolumeRow $volume $Context)) }
    }
  }
  $result.rows = @($rows)
  if (-not $Apply) { return [pscustomobject]$result }
  $results = [Collections.Generic.List[object]]::new()
  foreach ($row in @($rows | Where-Object { $_.action -ceq 'stop' })) {
    if ($BeforeAct) { & $BeforeAct $row }
    $gate = Test-SweepDockerFresh $row $Context
    if ($gate) { $results.Add([pscustomobject]@{ kind = $row.kind; id = $row.id; result = $gate }); continue }
    $stop = & $docker @('stop', $row.id) 120000
    $results.Add([pscustomobject]@{ kind = $row.kind; id = $row.id; result = $(if ($stop.exitCode -eq 0) { 'stopped' } else { 'stop-failed' }) })
  }
  # sandbox gc and the two prunes choose their own targets inside the daemon at
  # call time (gc by its own ownership rules, image prune only dangling images,
  # builder prune only cache older than the filter); the gate here is that the
  # daemon still answers and the ownership census is still healthy.
  $daemonGate = {
    $block = Update-SweepAuthority $Context
    if ($block) { return $block }
    if ((& $docker @('version', '--format', '{{.Server.Version}}') 20000).exitCode -ne 0) { return 'docker-unavailable' }
    $null
  }
  if ($product) {
    $gate = & $daemonGate
    if ($gate) { $results.Add([pscustomobject]@{ kind = 'sandbox-gc'; result = $gate }) }
    else {
      $gc = & $Context.resolvers.SandboxGc $product.root
      $results.Add([pscustomobject]@{ kind = 'sandbox-gc'; result = $(if ($gc.exitCode -eq 0) { 'ok' } else { 'failed' }); output = ([string]$gc.stdout + [string]$gc.stderr).Trim() })
    }
  }
  foreach ($row in @($rows | Where-Object { $_.action -ceq 'remove' })) {
    if ($BeforeAct) { & $BeforeAct $row }
    $gate = Test-SweepDockerFresh $row $Context
    if ($gate) { $results.Add([pscustomobject]@{ kind = $row.kind; id = $row.id; result = $gate }); continue }
    $remove = & $docker @('volume', 'rm', $row.id) 60000
    $results.Add([pscustomobject]@{ kind = $row.kind; id = $row.id; result = $(if ($remove.exitCode -eq 0) { 'removed' } else { 'remove-failed' }) })
  }
  foreach ($command in @(@('image', 'prune', '-f'), @('builder', 'prune', '-f', '--filter', "until=$($Context.policy.builderCacheUntil)"))) {
    $kind = $command[0..1] -join '-'
    $gate = & $daemonGate
    if ($gate) { $results.Add([pscustomobject]@{ kind = $kind; result = $gate }); continue }
    $run = & $docker $command 600000
    $results.Add([pscustomobject]@{ kind = $kind; result = $(if ($run.exitCode -eq 0) { 'ok' } else { 'failed' }); output = (([string]$run.stdout -split "`r?`n" | Where-Object { $_ -match 'reclaimed' }) -join ' ') })
  }
  $result.results = @($results)
  [pscustomobject]$result
}

# ---------------------------------------------------------------- trash

function Remove-SweepTree([string]$Path) {
  $attributes = [IO.File]::GetAttributes($Path)
  if ($attributes -band [IO.FileAttributes]::ReparsePoint) {
    # Unlink only; never follow a junction or symlink out of the trash.
    if ($attributes -band [IO.FileAttributes]::Directory) { [IO.Directory]::Delete($Path, $false) } else { [IO.File]::Delete($Path) }
    return
  }
  if (-not ($attributes -band [IO.FileAttributes]::Directory)) {
    if ($attributes -band [IO.FileAttributes]::ReadOnly) { [IO.File]::SetAttributes($Path, $attributes -band -bnot [IO.FileAttributes]::ReadOnly) }
    [IO.File]::Delete($Path); return
  }
  try { [IO.Directory]::Delete($Path, $true); return } catch [UnauthorizedAccessException] {} catch [IO.IOException] {}
  $options = [IO.EnumerationOptions]@{ AttributesToSkip = 0; IgnoreInaccessible = $false; RecurseSubdirectories = $false }
  $stack = [Collections.Generic.Stack[string]]::new(); $stack.Push($Path)
  while ($stack.Count) {
    $directory = $stack.Pop()
    $own = [IO.File]::GetAttributes($directory)
    if ($own -band [IO.FileAttributes]::ReadOnly) { [IO.File]::SetAttributes($directory, $own -band -bnot [IO.FileAttributes]::ReadOnly) }
    foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($directory, '*', $options)) {
      $entryAttributes = [IO.File]::GetAttributes($entry)
      if ($entryAttributes -band [IO.FileAttributes]::ReparsePoint) {
        if ($entryAttributes -band [IO.FileAttributes]::Directory) { [IO.Directory]::Delete($entry, $false) } else { [IO.File]::Delete($entry) }
      } elseif ($entryAttributes -band [IO.FileAttributes]::Directory) { $stack.Push($entry) }
      elseif ($entryAttributes -band [IO.FileAttributes]::ReadOnly) { [IO.File]::SetAttributes($entry, $entryAttributes -band -bnot [IO.FileAttributes]::ReadOnly) }
    }
  }
  [IO.Directory]::Delete($Path, $true)
}

function Invoke-SweepTrashPurge([string]$ContainerRoot, [int]$BudgetMinutes) {
  $trash = Join-Path (Get-ReclamationPath $ContainerRoot) '.trash'
  if (-not [IO.Directory]::Exists($trash)) { return [pscustomobject]@{ result = 'empty'; removed = 0; failed = 0; remaining = 0 } }
  $lock = $null
  try { $lock = [IO.FileStream]::new((Join-Path $trash '.purge.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
  catch { return [pscustomobject]@{ result = 'already-running'; removed = 0; failed = 0; remaining = $null } }
  try {
    $deadline = [datetime]::UtcNow.AddMinutes($BudgetMinutes); $removed = 0; $failed = [Collections.Generic.List[string]]::new()
    foreach ($bucket in @([IO.Directory]::GetDirectories($trash))) {
      if ([IO.File]::GetAttributes($bucket) -band [IO.FileAttributes]::ReparsePoint) { [IO.Directory]::Delete($bucket, $false); continue }
      foreach ($item in @([IO.Directory]::GetFileSystemEntries($bucket))) {
        if ([datetime]::UtcNow -gt $deadline) { break }
        if (-not (Test-SweepUnder $item $trash)) { continue }
        try { Remove-SweepTree $item; $removed++ } catch { $failed.Add("$item :: $($_.Exception.Message)") }
      }
      if (-not @([IO.Directory]::GetFileSystemEntries($bucket)).Count) { [IO.Directory]::Delete($bucket, $false) }
      if ([datetime]::UtcNow -gt $deadline) { break }
    }
    $remaining = @([IO.Directory]::GetDirectories($trash) | ForEach-Object { [IO.Directory]::GetFileSystemEntries($_) }).Count
    [pscustomobject]@{ result = $(if ($remaining) { 'budget-exhausted' } else { 'purged' }); removed = $removed; failed = $failed.Count; failures = @($failed | Select-Object -First 20); remaining = $remaining }
  } finally { $lock.Dispose() }
}

function Start-SweepTrashPurge($Context, [string]$ScriptPath) {
  $trash = Join-Path $Context.container '.trash'
  $pending = if ([IO.Directory]::Exists($trash)) { @([IO.Directory]::GetDirectories($trash) | ForEach-Object { [IO.Directory]::GetFileSystemEntries($_) }).Count } else { 0 }
  if (-not $pending) { return [pscustomobject]@{ result = 'empty'; pending = 0 } }
  try { $probe = [IO.FileStream]::new((Join-Path $trash '.purge.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None); $probe.Dispose() }
  catch { return [pscustomobject]@{ result = 'already-running'; pending = $pending } }
  $logs = Join-Path $Context.runtime 'logs'; [void][IO.Directory]::CreateDirectory($logs)
  $process = & $Context.resolvers.StartHidden $ScriptPath @('-PurgeTrash', '-ContainerRoot', $Context.container) (Join-Path $logs 'container-sweep-purge.out.txt') (Join-Path $logs 'container-sweep-purge.err.txt')
  [pscustomobject]@{ result = 'started'; pending = $pending; pid = $process.Id }
}

function Start-SweepHidden([string]$ScriptPath, [string[]]$Arguments, [string]$OutPath, [string]$ErrPath) {
  # Todd: background jobs never open console windows.
  $pwsh = (Get-Process -Id $PID).Path
  Start-Process -FilePath $pwsh -ArgumentList (@('-NoProfile', '-NonInteractive', '-File', $ScriptPath) + $Arguments) -WindowStyle Hidden -RedirectStandardOutput $OutPath -RedirectStandardError $ErrPath -PassThru
}

# ---------------------------------------------------------------- orchestration

function Get-SweepDefaultResolvers {
  @{
    Now = { [datetime]::UtcNow }
    Ownership = { param($Runtime, $Temp, $Container) Get-ReclamationLiveOwnership $Runtime $Temp $Container }
    ProcessTexts = { Get-SweepProcessTexts }
    PrCensus = { param($Repository) Get-SweepPrCensus $Repository }
    Issues = { param([int[]]$Numbers) Get-ReclamationIssueBatch $Numbers }
    LsRemote = {
      param($Repository)
      $list = Invoke-ReclamationGit $Repository @('ls-remote', '--heads', 'origin')
      if ($list.exitCode -ne 0) { return $null }
      @(foreach ($line in $list.output) { if ($line -cmatch '^(?<sha>[0-9a-f]{40})\trefs/heads/(?<branch>.+)$') { [pscustomobject]@{ sha = $Matches.sha; branch = $Matches.branch } } })
    }
    BranchPrs = { param($Repository, $Branch) Get-SweepBranchPrs $Repository $Branch }
    PrView = { param($Number) Get-SweepPrNode $Number }
    PrClose = {
      param($Number, $Comment)
      $PSNativeCommandUseErrorActionPreference = $false
      [void](& gh pr close $Number -R chase-sets/chase-sets --comment $Comment 2>&1)
      $LASTEXITCODE
    }
    ScheduledTasks = { Get-SweepScheduledTasks }
    UnregisterTask = { param($Name) Unregister-ScheduledTask -TaskName $Name -Confirm:$false -ErrorAction Stop }
    Docker = {
      param([string[]]$Arguments, [int]$TimeoutMs)
      $exe = (Get-Command docker -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
      if (-not $exe) { return [pscustomobject]@{ exitCode = -1; stdout = ''; stderr = 'docker not found'; timedOut = $false } }
      Invoke-SweepProcess $exe $Arguments $TimeoutMs
    }
    SandboxGc = {
      param($ProductRoot)
      $node = (Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
      if (-not $node) { return [pscustomobject]@{ exitCode = -1; stdout = ''; stderr = 'node not found'; timedOut = $false } }
      Invoke-SweepProcess $node @((Join-Path $ProductRoot 'scripts\sandbox.mjs'), 'gc') 600000
    }
    StartHidden = { param($ScriptPath, $Arguments, $OutPath, $ErrPath) Start-SweepHidden $ScriptPath $Arguments $OutPath $ErrPath }
  }
}

function Invoke-ContainerSweep {
  param(
    [string]$ContainerRoot, [switch]$Apply,
    [string[]]$Phases = @('worktrees', 'branches', 'directories', 'remote', 'prs', 'tasks', 'docker', 'trash'),
    [hashtable]$Resolvers = @{}, [scriptblock]$BeforeAct, [string]$ScriptPath = $PSCommandPath
  )
  $timer = [Diagnostics.Stopwatch]::StartNew(); $durations = [ordered]@{}
  $resolved = Get-SweepDefaultResolvers
  foreach ($key in $Resolvers.Keys) { $resolved[$key] = $Resolvers[$key] }
  $context = New-SweepContext -ContainerRoot $ContainerRoot -Phases $Phases -Resolvers $resolved
  $durations.context = $timer.Elapsed.TotalMilliseconds
  $report = [ordered]@{
    schemaVersion = $script:SweepSchema; mode = $(if ($Apply) { 'apply' } else { 'report' }); containerRoot = $context.container
    observedAt = $context.now.ToString('o'); policy = $context.policy
    authority = [ordered]@{
      registerComplete = [bool]$context.register.complete; platformMilestones = @($context.register.milestones); dispatchComplete = [bool]$context.dispatch.complete
      ownershipHealth = [string]$context.ownership.health.status; launchRecordsComplete = [bool]$context.launch.complete
      activeLanes = @($context.ownership.activeLanes).Count; prCensusComplete = [bool]$context.prCensus.complete; prCount = @($context.prCensus.nodes).Count
    }
    phases = [ordered]@{}; summary = [ordered]@{}; durationsMs = $durations
  }
  $gitBlock = Get-SweepGlobalBlock $context -NeedsCensus -NeedsOwnership
  if ($Apply -and -not $gitBlock -and $Phases -contains 'worktrees') {
    foreach ($repository in $context.repositories) { [void](Invoke-ReclamationGit $repository.root @('worktree', 'prune')) }
  }
  $phase = {
    param([string]$Name, [object[]]$Rows, [scriptblock]$Act)
    $results = [Collections.Generic.List[object]]::new()
    $targets = @($Rows | Where-Object { $_.action -cne 'retain' })
    if ($Apply -and $Act) {
      foreach ($row in $targets) {
        # Test seam: anything that changes after inventory lands here, before
        # the helper's own fresh-evidence gate.
        if ($BeforeAct) { & $BeforeAct $row }
        $results.Add((& $Act $row))
      }
    }
    $report.phases[$Name] = [ordered]@{ rows = @($Rows); results = @($results) }
    $retained = [ordered]@{}
    foreach ($group in @($Rows | Where-Object { $_.action -ceq 'retain' } | Group-Object reasonCode | Sort-Object Count -Descending)) { $retained[[string]$group.Name] = $group.Count }
    $report.summary[$Name] = [ordered]@{
      rows = @($Rows).Count; actionable = $targets.Count
      acted = @($results | Where-Object { $_.result -match '^(removed|snapshot-removed|deleted|archived-removed|closed-with-comment|unregistered)' }).Count
      retainedBy = $retained
    }
    $durations[$Name] = $timer.Elapsed.TotalMilliseconds
  }
  if ($Phases -contains 'worktrees') {
    $rows = @(Get-SweepWorktreeRows $context $gitBlock)
    & $phase 'worktrees' $rows { param($Row) Invoke-SweepWorktreeRemoval $Row $context }
    if ($Apply) { Complete-SweepWorktreeRemovals $context @($report.phases.worktrees.results) $rows }
  }
  if ($Phases -contains 'branches') { & $phase 'branches' @(Get-SweepBranchRows $context $gitBlock) { param($Row) Invoke-SweepBranchDeletion $Row $context } }
  if ($Phases -contains 'directories') {
    $directoryBlock = Get-SweepGlobalBlock $context -NeedsOwnership
    & $phase 'directories' @(Get-SweepDirectoryRows $context $directoryBlock) { param($Row) Invoke-SweepDirectoryArchive $Row $context }
  }
  if ($Phases -contains 'remote') { & $phase 'remote' @(Get-SweepRemoteRows $context $gitBlock) { param($Row) Invoke-SweepRemoteDeletion $Row $context } }
  if ($Phases -contains 'prs') { & $phase 'prs' @(Get-SweepDraftRows $context $gitBlock) { param($Row) Invoke-SweepDraftClose $Row $context } }
  if ($Phases -contains 'tasks') { & $phase 'tasks' @(Get-SweepTaskRows $context) { param($Row) Invoke-SweepTaskRemoval $Row $context } }
  if ($Phases -contains 'docker') {
    $docker = Invoke-SweepDocker $context -Apply:$Apply -BeforeAct $BeforeAct
    $report.phases.docker = $docker
    $report.summary.docker = [ordered]@{ status = $docker.status; rows = @($docker.rows).Count; actionable = @($docker.rows | Where-Object { $_.action -cne 'retain' }).Count; acted = @($docker.results | Where-Object { $_.result -in @('stopped', 'removed') }).Count }
    $durations.docker = $timer.Elapsed.TotalMilliseconds
  }
  if ($Phases -contains 'trash') {
    $report.phases.trash = if ($Apply) { Start-SweepTrashPurge $context $ScriptPath } else { [pscustomobject]@{ result = 'report-only' } }
    $report.summary.trash = $report.phases.trash
  }
  $durations.total = $timer.Elapsed.TotalMilliseconds
  [pscustomobject]$report
}

function Format-SweepSummary($Report) {
  $lines = [Collections.Generic.List[string]]::new()
  $lines.Add("container-sweep $($Report.mode): register=$($Report.authority.registerComplete) ownership=$($Report.authority.ownershipHealth) prCensus=$($Report.authority.prCensusComplete) activeLanes=$($Report.authority.activeLanes)")
  foreach ($name in $Report.summary.Keys) {
    $s = $Report.summary[$name]
    if ($name -ceq 'trash') { $lines.Add("  trash: $($s.result) pending=$($s.pending)"); continue }
    if ($name -ceq 'docker') { $lines.Add("  docker: $($s.status) actionable=$($s.actionable) acted=$($s.acted)"); continue }
    $retained = if ($s.retainedBy) { ($s.retainedBy.GetEnumerator() | Select-Object -First 6 | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ' } else { '' }
    $lines.Add("  ${name}: rows=$($s.rows) actionable=$($s.actionable) acted=$($s.acted) retained: $retained")
  }
  @($lines)
}

if ($sweepInvocationName -cne '.') {
  $o = $sweepOptions
  $phases = @($o.Phase | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  $unknownPhases = @($phases | Where-Object { $_ -cnotin @('worktrees', 'branches', 'directories', 'remote', 'prs', 'tasks', 'docker', 'trash') })
  if ($unknownPhases.Count) { throw "unknown -Phase value(s): $($unknownPhases -join ', ')" }
  if ($o.PurgeTrash) { Invoke-SweepTrashPurge $o.ContainerRoot $o.PurgeBudgetMinutes | ConvertTo-Json -Depth 4; return }
  $container = Get-ReclamationPath $o.ContainerRoot
  $runtime = Join-Path $container '.orchestrator'
  $logs = Join-Path $runtime 'logs'
  if ($o.Background) {
    [void][IO.Directory]::CreateDirectory($logs)
    $arguments = [Collections.Generic.List[string]]::new()
    foreach ($pair in $o.BoundParameters.GetEnumerator()) {
      if ($pair.Key -in @('Background', 'Json')) { continue }
      if ($pair.Value -is [switch] -or $pair.Value -is [bool]) { if ($pair.Value) { $arguments.Add("-$($pair.Key)") }; continue }
      $arguments.Add("-$($pair.Key)"); $arguments.Add((@($pair.Value) -join ','))
    }
    $stamp = [datetime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $process = Start-SweepHidden $PSCommandPath @($arguments) (Join-Path $logs "container-sweep-$stamp.out.txt") (Join-Path $logs "container-sweep-$stamp.err.txt")
    Write-Output "container-sweep: started hidden background run pid=$($process.Id)"
    return
  }
  $lockPath = Join-Path $runtime 'container-sweep.lock'
  try { $lock = [IO.FileStream]::new($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
  catch { Write-Output 'container-sweep: another run holds the lock; nothing to do'; return }
  try {
    $statePath = Join-Path $runtime 'container-sweep-state.json'
    if ($o.Apply -and -not $o.Force -and [IO.File]::Exists($statePath)) {
      try {
        $state = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json -DateKind String
        $last = [datetime]::Parse([string]$state.lastAppliedUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        if (([datetime]::UtcNow - $last).TotalHours -lt $script:SweepPolicy.dueHours) { Write-Output "container-sweep: not due (last apply $($last.ToString('o'))); pass -Force to run now"; return }
      } catch {}
    }
    $report = Invoke-ContainerSweep -ContainerRoot $container -Apply:$o.Apply -Phases $phases -ScriptPath $PSCommandPath
    $path = if ($o.ReportPath) { $o.ReportPath } elseif ($o.Apply) { Join-Path $logs "container-sweep-$([datetime]::UtcNow.ToString('yyyyMMddTHHmmssZ')).json" } else { $null }
    if ($path) { Write-ReclamationReport $path $report }
    if ($o.Apply) { Write-ReclamationReport $statePath ([pscustomobject]@{ lastAppliedUtc = [datetime]::UtcNow.ToString('o'); report = $path }) }
    if ($o.Json) { $report | ConvertTo-Json -Depth 20 } else { Format-SweepSummary $report; if ($path) { "report: $path" } }
  } finally { $lock.Dispose() }
}
