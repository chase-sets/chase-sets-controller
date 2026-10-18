# Synthetic local topology only. The production URL is configuration input;
# no fixture fetches from or pushes to that endpoint.
function Invoke-CensusFixtureGit([string]$Path, [string[]]$Arguments) {
  $output = @(& git -C $Path @Arguments 2>&1)
  if ($LASTEXITCODE) { throw "synthetic Git failed: $($Arguments[0])" }
  return ($output -join "`n").Trim()
}

function New-CensusFixture([string]$Parent, [string]$AnchorSource='platform', [switch]$SeparateSeat, [switch]$AnchorSubdirectory) {
  $container = Join-Path $Parent 'container'
  $runtime = Join-Path $container '.orchestrator'
  $temp = Join-Path $Parent 'temp'
  $main = Join-Path $container 'main'
  $anchor = Join-Path $Parent 'orchestration-platform'
  New-Item -ItemType Directory -Path $runtime, $temp, $main | Out-Null
  $anchorRepo = if ($AnchorSubdirectory) { $Parent } else { $anchor }
  $repos = @($container, $main)
  if ($AnchorSource -ceq 'platform') { New-Item -ItemType Directory $anchorRepo -Force | Out-Null; $repos += $anchorRepo }
  foreach ($repo in $repos) {
    [void](Invoke-CensusFixtureGit $repo @('init','-q','--initial-branch=main'))
    [void](Invoke-CensusFixtureGit $repo @('config','user.name','Synthetic Census'))
    [void](Invoke-CensusFixtureGit $repo @('config','user.email','synthetic-census@example.invalid'))
    [void](Invoke-CensusFixtureGit $repo @('commit','-q','--allow-empty','-m','synthetic root'))
  }
  if ($AnchorSource -cne 'platform') {
    $source = if ($AnchorSource -ceq 'product') { $main } else { $container }
    [void](Invoke-CensusFixtureGit $source @('worktree','add','-q','-b','synthetic/anchor',$anchor,'HEAD'))
  }
  if ($AnchorSubdirectory) { New-Item -ItemType Directory $anchor | Out-Null }
  [void](Invoke-CensusFixtureGit $anchor @('remote','add','origin','https://github.com/todd-skelton/orchestration-platform.git'))
  $seat = Join-Path $Parent 'platform-seat'
  if ($SeparateSeat) {
    [void](Invoke-CensusFixtureGit $Parent @('clone','-q',$anchor,$seat))
    [void](Invoke-CensusFixtureGit $seat @('remote','set-url','origin','https://github.com/todd-skelton/orchestration-platform.git'))
    [void](Invoke-CensusFixtureGit $seat @('checkout','-q','-b','synthetic/product'))
  } else {
    [void](Invoke-CensusFixtureGit $anchor @('worktree','add','-q','-b','synthetic/product',$seat,'HEAD'))
  }
  $product = Join-Path $container 'product-seat'
  $productBranch = if ($AnchorSource -ceq 'product') { 'synthetic/product-owner' } else { 'synthetic/product' }
  [void](Invoke-CensusFixtureGit $main @('worktree','add','-q','-b',$productBranch,$product,'HEAD'))
  return [pscustomobject]@{ parent=$Parent; container=$container; runtime=$runtime; temp=$temp; main=$main; anchor=$anchor; seat=$seat; product=$product }
}

function New-CensusFixtureOwner($Fixture, [string]$Worktree=$Fixture.seat,
  [string]$LaunchId=([guid]::NewGuid().ToString())) {
  $label = "synthetic-$LaunchId"
  $record = [pscustomobject][ordered]@{
    schemaVersion=4; launchId=$LaunchId; laneRole='implementation'
    promptPath=(Join-Path $Fixture.runtime "dispatch-heavy-verifier-$LaunchId.prompt.txt")
    reviewIsolationRoot=$null; launcherPid=$PID
    launcherStartIdentity=(Get-DispatchProcessStartIdentity $PID)
    recordedAt=[DateTime]::UtcNow.ToString('o'); state='started'; childPid=$PID
    childStartIdentity=(Get-DispatchProcessStartIdentity $PID)
    worktree=$Worktree; lane=(Split-Path -Leaf $Worktree); identityMode='branch'
    branch=(Invoke-CensusFixtureGit $Worktree @('branch','--show-current'))
    head=(Invoke-CensusFixtureGit $Worktree @('rev-parse','HEAD'))
    label=$label; transcriptPath=(Join-Path $Fixture.runtime "$label.jsonl")
  }
  [IO.File]::WriteAllText($record.transcriptPath,"{`"type`":`"item.completed`"}`n")
  $path = Join-Path $Fixture.runtime "dispatch-launch-$LaunchId.json"
  Write-DispatchOwnershipRecord $path $record -CreateNew
  return [pscustomobject]@{ path=$path; record=$record }
}

function Get-CensusFixtureProjection($Fixture, [switch]$Unscoped) {
  $arguments = @{}
  # The same assertion runs against the pre-change reducer, not a fake result.
  if (-not $Unscoped -and (Get-Command Get-LiveDispatchOwnership).Parameters.ContainsKey('ProductCensus')) {
    $arguments.ProductCensus = $true
  }
  Get-LiveDispatchOwnership $Fixture.runtime $Fixture.temp $Fixture.container @arguments
}

function Assert-CensusFixture([bool]$Condition, [string]$Name) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Name" }
}

function Remove-CensusFixture([string]$Parent) {
  $resolved = [IO.Path]::GetFullPath($Parent)
  if ((Split-Path -Parent $resolved) -ne [IO.Path]::GetTempPath().TrimEnd('\','/') -or
      (Split-Path -Leaf $resolved) -notlike 'synthetic-census-*') { throw 'unsafe fixture cleanup' }
  if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}

# #9619 deterministic budget meter: the Stopwatch members the production budget
# reads (Restart, ElapsedMilliseconds), advanced only by Charge(), so a metered
# verdict never depends on elapsed real time. The census Git reader also turns
# the remaining budget into a real-time process wait; metered, that one wait
# ends on the Git process's exit or on a capture reader completing at its fixed
# bound. Nothing drains a full capture, so that Git may never exit: the meter
# stops and reaps the owned Git tree, and the unchanged git-output-bound refusal
# runs.
# The harness swaps only those three budget reads in a subject otherwise
# byte-identical to dispatch-ownership.ps1; the deadline, retry and fail-closed
# reasons run unchanged, and production keeps its Stopwatch.
function New-DeterministicBudgetMeter {
  $meter = [pscustomobject]@{ charged = 0L; restarts = 0; processWaits = 0; reaps = [Collections.Generic.List[object]]::new() }
  $meter | Add-Member -MemberType ScriptProperty -Name ElapsedMilliseconds -Value { $this.charged }
  $meter | Add-Member -MemberType ScriptMethod -Name Restart -Value { $this.charged = 0L; $this.restarts += 1 }
  $meter | Add-Member -MemberType ScriptMethod -Name Charge -Value { param([long]$Milliseconds) $this.charged += $Milliseconds }
  $meter | Add-Member -MemberType ScriptMethod -Name WaitForProcess -Value {
    param($Process, $Reads, $Bounds)
    $exit = $Process.WaitForExitAsync()
    # The wait set is taken before the exit/full-capture check: a reader that
    # completes before the check is judged by it, and one that completes after
    # it is still in the set WaitAny wakes on. A reader at EOF leaves the set.
    while ($true) {
      $pending = [Threading.Tasks.Task[]]@(@($exit) + @($Reads | Where-Object { -not $_.IsCompleted }))
      if ($exit.IsCompleted -or @(0,1 | Where-Object { $Reads[$_].IsCompletedSuccessfully -and $Reads[$_].Result -eq $Bounds[$_] }).Count) { break }
      [void][Threading.Tasks.Task]::WaitAny($pending)
    }
    if (-not $Process.HasExited) { $this.reaps.Add([pscustomobject]@{ tree = @(Stop-CensusFixtureGitTree $Process) }) }
    $this.processWaits += 1
    $Process.HasExited
  }
  return $meter
}

# Stops a census Git whose capture is full, with its descendants, and returns
# once each has exited. Git for Windows' cmd\git.exe wrapper runs the real git
# as its child, and a wrapper-only Kill() leaves that child holding both capture
# pipes. Until it is stopped, a Git blocked on a full pipe can neither exit nor
# spawn, so the tree read first is the whole tree, and each descendant is pinned
# by its handle while it still holds its id: no stop or wait reaches a reused id.
function Stop-CensusFixtureGitTree($Process) {
  $rows = @(Get-CimInstance Win32_Process -Property ProcessId,ParentProcessId,CreationDate -ErrorAction Stop)
  $tree = @($rows | Where-Object ProcessId -EQ $Process.Id)
  for ($i = 0; $i -lt $tree.Count; $i++) {
    $tree += @($rows | Where-Object { $_.ParentProcessId -eq $tree[$i].ProcessId -and $_.CreationDate -gt $tree[$i].CreationDate })
  }
  $descendants = @(foreach ($row in @($tree | Select-Object -Skip 1)) {
    $member = Get-Process -Id $row.ProcessId -ErrorAction SilentlyContinue
    if ($member) { [void]$member.Handle; $member }
  })
  $Process.Kill(); foreach ($member in $descendants) { $member.Kill() }
  $Process.WaitForExit(); foreach ($member in $descendants) { $member.WaitForExit(); $member.Dispose() }
  return @($tree | Select-Object ProcessId, CreationDate)
}

function ConvertTo-DeterministicBudgetSubject([string]$Source) {
  $clock = '[Diagnostics.Stopwatch]::new()'; $wait = '$process.WaitForExit([int]$remaining)'
  $meteredWait = '$deterministicBudgetMeter.WaitForProcess($process,@($outRead,$errRead),@($stdout.Length,$stderr.Length))'
  Assert-CensusFixture (([regex]::Matches($Source,[regex]::Escape($clock))).Count -eq 2 -and
    ([regex]::Matches($Source,[regex]::Escape($wait))).Count -eq 1) 'deterministic meter replaces exactly the two budget clocks and the one budget wait'
  $metered = $Source.Replace($wait,$meteredWait).Replace($clock,'$deterministicBudgetMeter')
  Assert-CensusFixture ($metered.Replace($meteredWait,$wait).Replace('$deterministicBudgetMeter',$clock) -ceq $Source) 'deterministic subject differs only at the budget reads'
  return $metered
}

# Runs $Probe with the metered subject in scope, after at most one source
# mutation. A projection run outside it finds no meter and fails closed.
function Invoke-DeterministicBudget([scriptblock]$Probe, [string]$MutationOld, [string]$MutationNew) {
  $deterministicBudgetRoot = Join-Path ([IO.Path]::GetTempPath()) ('synthetic-census-' + [guid]::NewGuid().ToString('N'))
  [void][IO.Directory]::CreateDirectory($deterministicBudgetRoot)
  try {
    $deterministicBudgetSource = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'dispatch-ownership.ps1'))
    if ($MutationOld) {
      Assert-CensusFixture (([regex]::Matches($deterministicBudgetSource,[regex]::Escape($MutationOld))).Count -eq 1) 'single deterministic-budget mutation'
      $deterministicBudgetSource = $deterministicBudgetSource.Replace($MutationOld,$MutationNew)
    }
    $deterministicBudgetSubject = Join-Path $deterministicBudgetRoot 'deterministic-budget.ps1'
    [IO.File]::WriteAllText($deterministicBudgetSubject,(ConvertTo-DeterministicBudgetSubject $deterministicBudgetSource))
    $deterministicBudgetMeter = New-DeterministicBudgetMeter
    & { . $deterministicBudgetSubject; & $Probe }
  } finally { Remove-CensusFixture $deterministicBudgetRoot }
}

function Invoke-CensusSourceMutant([string]$Name, [string]$Old, [string]$New, [scriptblock]$Probe, [string]$Parent) {
  $text = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'dispatch-ownership.ps1'))
  Assert-CensusFixture (([regex]::Matches($text,[regex]::Escape($Old))).Count -eq 1) "single mutation $Name"
  $subject = Join-Path $Parent "$Name.ps1"
  [IO.File]::WriteAllText($subject,(ConvertTo-DeterministicBudgetSubject $text.Replace($Old,$New)))
  & { . $subject; & $Probe }
}

function Assert-CensusOutside($Result, [string]$Reason, [string]$Name) {
  $outside = @($Result.health.diagnostics | Where-Object code -CEQ 'worktree-outside-container')
  Assert-CensusFixture ($Result.health.status -ceq 'partial' -and $Result.activeLanes.Count -eq 0 -and
    $outside.Count -eq 1 -and $outside[0].lane -ceq 'platform-seat' -and $outside[0].reason -ceq $Reason -and
    @($Result.health.diagnostics | Where-Object code -CEQ 'worktree-outside-product-repository').Count -eq 0 -and
    ($Result.health.diagnostics | ConvertTo-Json -Compress) -notmatch 'synthetic-secret|github|https:') $Name
}

function Test-ProductCensusProofMatrix([switch]$SkipPairs) {
  $pairs = @(
    @{ name='bypass-platform-common-dir-proof'; reason='platform-common-dir'; topology=@{SeparateSeat=$true};
      old='if (-not (Test-DispatchSameCanonicalPath $seat.commonDir $Anchors.anchor.commonDir))'; new='if ($false)' },
    @{ name='bypass-platform-endpoint-proof'; reason='platform-endpoint'; topology=@{};
      setup={ param($f) [void](Invoke-CensusFixtureGit $f.seat @('config','--worktree','remote.origin.pushurl','https://github.com/chase-sets/chase-sets.git')) };
      old="if (`$url -notmatch '\A(?:https://github\.com/|git@github\.com:)todd-skelton/orchestration-platform(?:\.git)?\z')"; new='if ($false)' },
    @{ name='bypass-product-veto'; reason='product-common-dir'; topology=@{AnchorSource='product'};
      old='if (Test-DispatchSameCanonicalPath $seat.commonDir $Anchors.product.commonDir)'; new='if ($false)' },
    @{ name='bypass-container-meta-veto'; reason='container-meta-common-dir'; topology=@{AnchorSource='meta'};
      old='if (Test-DispatchSameCanonicalPath $seat.commonDir $Anchors.meta.commonDir)'; new='if ($false)' },
    @{ name='origin-only-endpoint-enumeration'; reason='platform-endpoint'; topology=@{};
      setup={ param($f) [void](Invoke-CensusFixtureGit $f.seat @('config','--worktree','remote.second.url','https://github.com/chase-sets/chase-sets.git')) };
      old='foreach ($remote in $remotes) {'; new="foreach (`$remote in @('origin')) {" },
    @{ name='bypass-anchor-toplevel'; reason='anchor-toplevel'; topology=@{AnchorSubdirectory=$true};
      old='if (-not (Test-DispatchSameCanonicalPath $anchor.topLevel (Get-DispatchCanonicalExistingPath $anchorPath)))'; new='if ($false)' },
    @{ name='bypass-branch-remote-proof'; reason='branch-remote'; topology=@{};
      setup={ param($f) [void](Invoke-CensusFixtureGit $f.seat @('config','--worktree','branch.synthetic/product.pushRemote',(Join-Path $f.parent 'synthetic-bare.git'))) };
      old="  `$config = Invoke-ProductCensusGit `$Checkout @('config','--get-regexp','^(branch\..*\.(remote|pushremote)|remote\.pushdefault)$') `$Budget";
      new='  return # mutant skips the branch-remote read' }
  )
  foreach ($pair in $(if ($SkipPairs) { @() } else { $pairs })) {
    $parent = Join-Path ([IO.Path]::GetTempPath()) ('synthetic-census-' + [guid]::NewGuid().ToString('N'))
    try {
      $topology = $pair.topology
      $f = New-CensusFixture $parent @topology
      [void](Invoke-CensusFixtureGit $f.anchor @('config','extensions.worktreeConfig','true'))
      # Keep both proof readers green before changing exactly one clause input.
      $owner = New-CensusFixtureOwner $f
      if ($pair.setup) { & $pair.setup $f }
      $result = Get-CensusFixtureProjection $f
      Assert-CensusOutside $result $pair.reason "product-census-outside-proof-matrix/$($pair.name)"
      $mutant = Invoke-CensusSourceMutant $pair.name $pair.old $pair.new { Get-CensusFixtureProjection $f } $parent
      Assert-CensusFixture ($mutant.health.status -ceq 'ok' -and $mutant.activeLanes.Count -eq 0 -and
        @($mutant.health.diagnostics | Where-Object code -CEQ 'worktree-outside-product-repository').Count -eq 1) "unmasked mutant $($pair.name)"
      Write-Output "CONTROL product-census-outside-proof-matrix/$($pair.name) PASS; MUTANT $($pair.name) KILLED candidate=partial mutant=ok frozen-inputs=true"
    } finally { Remove-CensusFixture $parent }
  }
  $parent = Join-Path ([IO.Path]::GetTempPath()) ('synthetic-census-' + [guid]::NewGuid().ToString('N'))
  try {
    $f = New-CensusFixture $parent
    $owner = New-CensusFixtureOwner $f
    $good = Get-CensusFixtureProjection $f
    Assert-CensusFixture ($good.health.status -ceq 'ok') 'relative-path positive'
    $mutant = Invoke-CensusSourceMutant 'bypass-relative-path-resolution' '$Path = Join-Path $Checkout $Path' '$Path = Join-Path (Get-Location).Path $Path' { Get-CensusFixtureProjection $f } $parent
    Assert-CensusFixture ($mutant.health.status -ceq 'partial') 'relative-path mutant killed'
    Write-Output 'CONTROL relative-common-dir PASS; MUTANT bypass-relative-path-resolution KILLED candidate=ok mutant=partial'
    [void](Invoke-CensusFixtureGit $f.anchor @('config','extensions.worktreeConfig','true'))
    foreach ($checkout in @($f.anchor,$f.seat)) {
      foreach ($scope in @('--local','--worktree')) {
        foreach ($key in @('branch.synthetic/product.remote','branch.synthetic/product.pushRemote','remote.pushDefault')) {
          [void](Invoke-CensusFixtureGit $checkout @('config',$scope,$key,(Join-Path $parent 'synthetic-bare.git')))
          Assert-CensusOutside (Get-CensusFixtureProjection $f) 'branch-remote' "platform-seat-url-valued-branch-remote/$scope/$key"
          $mutant = Invoke-CensusSourceMutant $pairs[-1].name $pairs[-1].old $pairs[-1].new { Get-CensusFixtureProjection $f } $parent
          Assert-CensusFixture ($mutant.health.status -ceq 'ok') "branch-remote isolated bypass/$scope/$key"
          [void](Invoke-CensusFixtureGit $checkout @('config',$scope,'--unset-all',$key))
          Assert-CensusFixture ((Get-CensusFixtureProjection $f).health.status -ceq 'ok') "branch-remote restored/$scope/$key"
        }
      }
    }
    Write-Output 'CONTROL platform-seat-url-valued-branch-remote PASS seat/anchor local/worktree all-three-keys; MUTANT bypass-branch-remote-proof KILLED for each'
    foreach ($url in @('https://synthetic-secret@github.com/todd-skelton/orchestration-platform.git',
      'https://github.com:443/todd-skelton/orchestration-platform','https://github.com/todd-skelton/orchestration-platform?x',
      'https://github.com/todd-skelton/orchestration-platform#x','https://github.com/todd-skelton/orchestration-platform/extra',
      'ssh://git@github.com/todd-skelton/orchestration-platform.git','file:///synthetic-secret')) {
      [void](Invoke-CensusFixtureGit $f.seat @('config','--worktree','remote.origin.url',$url))
      Assert-CensusOutside (Get-CensusFixtureProjection $f) 'platform-endpoint' 'malformed-unsupported-secret-free-endpoint'
    }
    [void](Invoke-CensusFixtureGit $f.seat @('config','--worktree','--unset-all','remote.origin.url'))
    foreach ($name in @('GIT_DIR','GIT_COMMON_DIR','GIT_CONFIG_COUNT','GIT_CONFIG_GLOBAL')) {
      $prior = [Environment]::GetEnvironmentVariable($name)
      try {
        [Environment]::SetEnvironmentVariable($name,'synthetic-secret')
        Assert-CensusOutside (Get-CensusFixtureProjection $f) 'git-environment' "inherited-$name"
      } finally {
        if ($null -eq $prior) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
        else { [Environment]::SetEnvironmentVariable($name,$prior) }
      }
    }
    foreach ($state in @('{"type":"turn.completed"}', '{not-json}')) {
      [IO.File]::WriteAllText($owner.record.transcriptPath,$state)
      $attemptProjection = Get-CensusFixtureProjection $f
      Assert-CensusFixture ($attemptProjection.health.status -ceq 'ok') "foreign terminal/unknown transcript nonblocking: $($attemptProjection.health | ConvertTo-Json -Compress -Depth 5)"
    }
    [IO.File]::WriteAllText($owner.record.transcriptPath,"{`"type`":`"item.completed`"}`n")
    $register = Join-Path $f.runtime 'platform-handoff.md'
    New-Item -ItemType Directory $register | Out-Null
    Assert-CensusFixture ((Get-CensusFixtureProjection $f).health.status -ceq 'ok') 'unreadable-register independent ownership'
    $mutant = Invoke-CensusSourceMutant 'reducer-reads-register' '$productAnchors = @{}' "`$productAnchors = @{}; [void][IO.File]::ReadAllText((Join-Path `$RuntimeRoot 'platform-handoff.md'))" {
      try { Get-CensusFixtureProjection $f | Out-Null; 'accepted' } catch { 'refused' }
    } $parent
    Assert-CensusFixture ($mutant -ceq 'refused') 'reducer-reads-register killed'
    Write-Output 'CONTROL endpoint-grammar/Git-env/foreign-attempt/unreadable-register PASS; MUTANT reducer-reads-register KILLED'
  } finally { Remove-CensusFixture $parent }

  $duplicateOrders = [Collections.Generic.List[string]]::new()
  foreach ($platformFirst in @($true,$false)) {
    $parent = Join-Path ([IO.Path]::GetTempPath()) ('synthetic-census-' + [guid]::NewGuid().ToString('N'))
    try {
      $f = New-CensusFixture $parent
      $ids = @('00000000-0000-0000-0000-000000000001','ffffffff-ffff-ffff-ffff-ffffffffffff')
      $foreign = New-CensusFixtureOwner $f $f.seat $ids[[int](-not $platformFirst)]
      $product = New-CensusFixtureOwner $f $f.product $ids[[int]$platformFirst]
      $foreign.record.label = $product.record.label
      $foreign.record.transcriptPath = $product.record.transcriptPath
      Write-DispatchOwnershipRecord $foreign.path $foreign.record
      $good = Get-CensusFixtureProjection $f
      Assert-CensusFixture ($good.health.status -ceq 'partial' -and
        @($good.health.diagnostics | Where-Object code -CEQ 'duplicate-live-transcript').Count -eq 1) "platform-seat-shares-product-transcript/$platformFirst"
      $mutant = Invoke-CensusSourceMutant 'skip-platform-duplicate-registration' '$seenTranscripts.Add($transcriptPath)' '$(if ($platformSeat) { -not $seenTranscripts.Contains($transcriptPath) } else { $seenTranscripts.Add($transcriptPath) })' { Get-CensusFixtureProjection $f } $parent
      Assert-CensusFixture ($mutant.health.status -ceq $(if ($platformFirst) {'ok'} else {'partial'})) "platform duplicate mutant/$platformFirst"
      Write-Output "CONTROL platform-seat-shares-product-transcript platformFirst=$platformFirst PASS; MUTANT skip-platform-duplicate-registration result=$($mutant.health.status)"
      Remove-Item -LiteralPath $product.path -Force
      # Fixed IDs on the far side of the foreign record: both orders, every run.
      $duplicateIds = @('00000000-0000-0000-0000-000000000002','ffffffff-ffff-ffff-ffff-fffffffffffe')
      $duplicate = New-CensusFixtureOwner $f $f.seat $duplicateIds[[int]$platformFirst]
      $good = Get-CensusFixtureProjection $f
      Assert-CensusFixture ($good.health.status -ceq 'partial' -and
        @($good.health.diagnostics | Where-Object code -CEQ 'duplicate-live-ownership').Count -eq 1) 'platform duplicate worktree'
      # The reducer examines records in Sort-Object order of their paths.
      $duplicateOrders.Add($(if (@(@($foreign.path,$duplicate.path) | Sort-Object)[0] -ceq $foreign.path) {'foreign-first'} else {'duplicate-first'}))
      Write-Output "CONTROL platform-duplicate-worktree order=$($duplicateOrders[-1]) PASS"
    } finally { Remove-CensusFixture $parent }
  }
  Assert-CensusFixture (@($duplicateOrders | Sort-Object -Unique).Count -eq 2) 'platform duplicate worktree runs both record orders'
}

function Test-ProductCensusFleetAdmission {
  $parent = Join-Path ([IO.Path]::GetTempPath()) ('synthetic-census-' + [guid]::NewGuid().ToString('N'))
  try {
    $f = New-CensusFixture $parent
    [void](New-CensusFixtureOwner $f)
    Import-Module (Join-Path $PSScriptRoot 'fleet-exclusive-admission.psm1') -Force -DisableNameChecking
    $message = $null
    try { Assert-FleetExclusiveLaneCensusVacant -RuntimeRoot $f.runtime -TempRoot $f.temp -ContainerRoot $f.container | Out-Null }
    catch { $message = $_.Exception.Message }
    Assert-CensusFixture ($message -like 'ADMISSION_DENIED*diagnostics=worktree-outside-container') 'fleet-platform-seat-remains-unscoped'
    $text = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'dispatch-ownership.ps1'))
    Assert-CensusFixture ($text.Contains('[switch]$ProductCensus,')) 'default scoped mutant match'
    [IO.File]::WriteAllText((Join-Path $parent 'dispatch-ownership.ps1'),$text.Replace('[switch]$ProductCensus,','[switch]$ProductCensus = $true,'))
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fleet-exclusive-admission.psm1') -Destination $parent
    Import-Module (Join-Path $parent 'fleet-exclusive-admission.psm1') -Force -DisableNameChecking
    $mutant = Assert-FleetExclusiveLaneCensusVacant -RuntimeRoot $f.runtime -TempRoot $f.temp -ContainerRoot $f.container
    Assert-CensusFixture ($mutant.health.status -ceq 'ok') 'default-scoped-projection unmasked'
    Write-Output 'CONTROL fleet-platform-seat-remains-unscoped PASS ADMISSION_DENIED diagnostics=worktree-outside-container; MUTANT default-scoped-projection KILLED admitted=true'
  } finally {
    Import-Module (Join-Path $PSScriptRoot 'fleet-exclusive-admission.psm1') -Force -DisableNameChecking
    Remove-CensusFixture $parent
  }
}

function Test-ProductCensusNativeBoundaries {
  $parent = Join-Path ([IO.Path]::GetTempPath()) ('synthetic-census-' + [guid]::NewGuid().ToString('N'))
  try {
    $f = New-CensusFixture $parent
    $owner = New-CensusFixtureOwner $f
    $original = $owner.record | ConvertTo-Json -Compress
    foreach ($kind in @('product-worktree','product-clone','alias','immutable-attached','immutable-wrong-head')) {
      $record = $original | ConvertFrom-Json -DateKind String
      switch ($kind) {
        'product-worktree' {
          $path = Join-Path $parent 'outside-product'
          [void](Invoke-CensusFixtureGit $f.main @('worktree','add','--force','-q',$path,'synthetic/product'))
          $record.worktree=$path; $record.lane=Split-Path -Leaf $path
        }
        'product-clone' {
          $path = Join-Path $parent 'outside-clone'
          [void](Invoke-CensusFixtureGit $parent @('clone','-q',$f.main,$path))
          [void](Invoke-CensusFixtureGit $path @('remote','set-url','origin','https://github.com/todd-skelton/orchestration-platform.git'))
          $record.worktree=$path; $record.lane=Split-Path -Leaf $path
        }
        'alias' {
          $path=Join-Path $parent 'alias-seat'
          New-Item -ItemType Junction -Path $path -Target $f.seat | Out-Null
          $record.worktree=$path; $record.lane='alias-seat'
        }
        'immutable-attached' { $record.identityMode='immutable-head'; $record.branch=$null }
        'immutable-wrong-head' {
          [void](Invoke-CensusFixtureGit $f.seat @('checkout','-q','--detach','HEAD'))
          [void](Invoke-CensusFixtureGit $f.seat @('commit','-q','--allow-empty','-m','synthetic detached advance'))
          $record.identityMode='immutable-head'; $record.branch=$null
        }
      }
      Write-DispatchOwnershipRecord $owner.path $record
      $result=Get-CensusFixtureProjection $f
      Assert-CensusFixture ($result.health.status -ceq 'partial' -and $result.activeLanes.Count -eq 0 -and
        @($result.health.diagnostics | Where-Object code -CEQ 'worktree-outside-product-repository').Count -eq 0) "native boundary $kind refuses without advisory"
      Write-Output "CONTROL native-outside-$kind REFUSED codes=$((@($result.health.diagnostics.code)) -join ',')"
    }
    $record.head=Invoke-CensusFixtureGit $f.seat @('rev-parse','HEAD')
    Write-DispatchOwnershipRecord $owner.path $record
    Assert-CensusFixture ((Get-CensusFixtureProjection $f).health.status -ceq 'ok') 'immutable exact detached platform accepts'
    [void](Invoke-CensusFixtureGit $f.seat @('checkout','-q','synthetic/product'))
    Write-DispatchOwnershipRecord $owner.path ($original | ConvertFrom-Json -DateKind String)
    [void](Invoke-CensusFixtureGit $f.seat @('commit','-q','--allow-empty','-m','synthetic branch advance'))
    Assert-CensusFixture ((Get-CensusFixtureProjection $f).health.status -ceq 'ok') 'attached platform head advancement remains valid'
    foreach ($key in @('insteadOf','pushInsteadOf')) {
      $configKey="url.https://github.com/chase-sets/chase-sets.git.$key"
      [void](Invoke-CensusFixtureGit $f.anchor @('config',$configKey,'https://github.com/todd-skelton/orchestration-platform.git'))
      Assert-CensusOutside (Get-CensusFixtureProjection $f) 'platform-endpoint' "effective $key endpoint refuses"
      [void](Invoke-CensusFixtureGit $f.anchor @('config','--unset-all',$configKey))
    }
    [void](Invoke-CensusFixtureGit $f.anchor @('remote','add','second','git@github.com:todd-skelton/orchestration-platform.git'))
    Assert-CensusFixture ((Get-CensusFixtureProjection $f).health.status -ceq 'ok') 'multiple same-identity remotes accept'
    [void](Invoke-CensusFixtureGit $f.anchor @('remote','remove','origin'))
    Assert-CensusOutside (Get-CensusFixtureProjection $f) 'origin-missing' 'missing origin refuses'
    [void](Invoke-CensusFixtureGit $f.anchor @('remote','remove','second'))
    Assert-CensusOutside (Get-CensusFixtureProjection $f) 'remote-enumeration' 'empty remotes refuse'
    [void](Invoke-CensusFixtureGit $f.anchor @('remote','add','origin','https://github.com/todd-skelton/orchestration-platform.git'))
    foreach ($checkout in @($f.anchor,$f.main,$f.container)) {
      $config=Join-Path $checkout '.git/config'
      $bytes=[IO.File]::ReadAllBytes($config)
      try {
        [IO.File]::AppendAllText($config,"`n[synthetic-invalid`n")
        Assert-CensusOutside (Get-CensusFixtureProjection $f) 'git-identity' 'unreadable native repository config refuses'
      } finally { [IO.File]::WriteAllBytes($config,$bytes) }
    }
    Assert-CensusFixture ((Get-CensusFixtureProjection $f).health.status -ceq 'ok') 'native config restored accepts'
    Write-Output 'CONTROL native detached/advanced/effective-fetch-push-rewrites/origin/anchor-product-meta-unreadable PASS'
  } finally { Remove-CensusFixture $parent }
}

function Test-ProductCensusProjection {
  $parent = Join-Path ([IO.Path]::GetTempPath()) ('synthetic-census-' + [guid]::NewGuid().ToString('N'))
  try {
    $f = New-CensusFixture $parent
    $owner = New-CensusFixtureOwner $f
    $scoped = Get-CensusFixtureProjection $f
    Assert-CensusFixture ($scoped.health.status -ceq 'ok' -and $scoped.activeLanes.Count -eq 0 -and
      $scoped.health.counts.examined -eq 1 -and $scoped.health.counts.inactive -eq 1 -and
      @($scoped.health.diagnostics | Where-Object code -CEQ 'worktree-outside-product-repository').Count -eq 1) 'product-census-platform-seat'
    $unscoped = Get-CensusFixtureProjection $f -Unscoped
    Assert-CensusFixture ($unscoped.health.status -ceq 'partial' -and
      @($unscoped.health.diagnostics | Where-Object code -CEQ 'worktree-outside-container').Count -eq 1 -and
      @($unscoped.health.diagnostics | Where-Object code -CEQ 'worktree-outside-product-repository').Count -eq 0) 'product-census-platform-seat-unscoped'
    Write-Output 'CONTROL product-census-platform-seat PASS native-owner=true synthetic-topology=true'
  } finally {
    Remove-CensusFixture $parent
  }
}

# #9619 AC1 census-git-latency-injection: a fixed real delay on every census Git
# call pushes each projection's Git work past the unchanged 5000 ms budget. On a
# real clock product-census-platform-seat fails; metered, its verdict holds.
function Test-CensusGitLatencyInjection([int]$DelayMs = 500) {
  $nativeCensusGit = ${function:Invoke-ProductCensusGit}
  $injection = [Collections.Generic.List[object]]::new()
  function Invoke-ProductCensusGit([string]$Checkout, [string[]]$Arguments, $Budget) {
    $evaluation = @($injection | Where-Object { [object]::ReferenceEquals($_.budget,$Budget) })
    if ($evaluation.Count -eq 0) { $evaluation = @([pscustomobject]@{ budget=$Budget; calls=0 }); $injection.Add($evaluation[0]) }
    $evaluation[0].calls += 1
    [Threading.Thread]::Sleep($DelayMs)
    & $nativeCensusGit $Checkout $Arguments $Budget
  }
  Test-ProductCensusProjection
  $injectedMs = @($injection | ForEach-Object { $_.calls * $DelayMs })
  Assert-CensusFixture ($injection.Count -ge 1 -and @($injectedMs | Where-Object { $_ -le 5000 }).Count -eq 0) 'census-git-latency-injection exceeds the 5000 ms budget in every projection'
  Write-Output "CONTROL census-git-latency-injection PASS evaluations=$($injection.Count) gitCalls=$(@($injection.calls) -join ',') delayMs=$DelayMs injectedMs=$($injectedMs -join ',') budgetMs=5000"
}

# #9619 census-git-output-bound: real Git writes far past the fixed 65537-char
# capture bound, on stdout (a 1 MiB config value) and on stderr (4000
# ambiguous-refname warnings from rev-list). Nothing drains a full capture, so
# that Git cannot exit; metered, the census evaluation still completes with the
# unchanged git-output-bound refusal and leaves no owned Git process running.
function Test-CensusGitOutputBound {
  $parent = Join-Path ([IO.Path]::GetTempPath()) ('synthetic-census-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory $parent | Out-Null
  try {
    foreach ($arguments in @(@('init','-q','--initial-branch=main'),@('config','user.name','Synthetic Census'),
        @('config','user.email','synthetic-census@example.invalid'),@('config','core.warnAmbiguousRefs','true'),
        @('commit','-q','--allow-empty','-m','synthetic root'),@('branch','s'),@('tag','s'))) {
      [void](Invoke-CensusFixtureGit $parent $arguments)
    }
    $config = Join-Path $parent 'synthetic-large-git-config'
    [IO.File]::WriteAllText($config,"[synthetic]`nvalue=$('x' * 1048576)`n")
    foreach ($case in @(@{ stream='stdout'; arguments=@('config','--file',$config,'--get','synthetic.value') },
        @{ stream='stderr'; arguments=@('rev-list','--count') + @('s') * 4000 })) {
      $priorReaps = $deterministicBudgetMeter.reaps.Count
      $reason = try {
        [void](Invoke-ProductCensusEvaluation { param($budget) Invoke-ProductCensusGit $parent $case.arguments $budget }); 'accepted'
      } catch { $_.Exception.Message }
      $reaped = @($deterministicBudgetMeter.reaps | Select-Object -Skip $priorReaps)
      $owned = @($reaped.tree)
      $running = @(Get-CimInstance Win32_Process -Property ProcessId,CreationDate,ThreadCount -ErrorAction Stop | Where-Object {
        $row = $_; $row.ThreadCount -ne 0 -and @($owned | Where-Object { $_.ProcessId -eq $row.ProcessId -and $_.CreationDate -eq $row.CreationDate }).Count })
      Assert-CensusFixture ($reason -ceq 'git-output-bound' -and $reaped.Count -eq 1 -and $owned.Count -ge 1 -and $running.Count -eq 0) "census-git-output-bound/$($case.stream)"
      Write-Output "CONTROL census-git-output-bound/$($case.stream) PASS refused=$reason reapedTree=$($owned.Count) running=$($running.Count)"
    }
  } finally { Remove-CensusFixture $parent }
}

# #9619 census-git-wait-schedule: the metered wait's lost-wakeup control. A
# synthetic Git (no operating-system process) completes one capture, stdout or
# stderr, at a fixed point of WaitForProcess: while the wait set reads its
# IsCompleted ("snapshot"), or just after the exit/full-capture check reads it
# ("check"). A full capture must be read, and its Git reaped, before the wait
# blocks; an EOF capture or a plain exit must end the wait on the exit with no
# reap. A wait that blocks with a full capture unread never wakes for real Git:
# the observer records it as stranded and only then exits the synthetic Git, so
# the control fails instead of hanging.
function Invoke-CensusGitWaitSchedule([string]$Kind, [string]$Stream, [string]$Point) {
  if (-not ('CensusGitWaitSchedule' -as [type])) {
    Add-Type -TypeDefinition @'
using System.Threading;
using System.Threading.Tasks;

public sealed class CensusGitWaitCapture {
  internal CensusGitWaitSchedule Schedule;
  internal int Index;
  internal readonly TaskCompletionSource<int> Read = new TaskCompletionSource<int>(TaskCreationOptions.RunContinuationsAsynchronously);
  public bool IsCompleted { get { Schedule.Reach(Index, "snapshot"); return Read.Task.IsCompleted; } }
  public bool IsCompletedSuccessfully { get { bool completed = Read.Task.IsCompletedSuccessfully; Schedule.Reach(Index, "check"); return completed; } }
  public int Result { get { Schedule.Observe(Index); return Read.Task.Result; } }
  public static implicit operator Task(CensusGitWaitCapture capture) { return capture.Read.Task; }
}

public sealed class CensusGitWaitSchedule {
  readonly Thread owner = Thread.CurrentThread;
  readonly Thread observer;
  readonly TaskCompletionSource<bool> exit = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
  readonly int stream, count;
  readonly string point;
  readonly bool full;
  volatile bool reached, observed, stranded, reaped;
  public readonly CensusGitWaitCapture[] Reads;

  public CensusGitWaitSchedule(int stream, string point, int count, int bound) {
    this.stream = stream; this.point = point; this.count = count; full = count == bound;
    Reads = new[] { new CensusGitWaitCapture { Schedule = this, Index = 0 }, new CensusGitWaitCapture { Schedule = this, Index = 1 } };
    observer = new Thread(Watch) { IsBackground = true };
    observer.Start();
  }
  public bool Stranded { get { return stranded; } }
  public bool Reaped { get { return reaped; } }
  public bool HasExited { get { return exit.Task.IsCompleted; } }
  public Task WaitForExitAsync() { return exit.Task; }
  public void Reap() { reaped = true; exit.TrySetResult(true); }
  public void Release() { exit.TrySetResult(true); observer.Join(); }

  internal void Reach(int index, string at) {
    if (reached || index != stream || at != point) return;
    if (count >= 0) Reads[index].Read.SetResult(count);
    reached = true;
  }
  internal void Observe(int index) { if (reached && index == stream) observed = true; }

  // From the scheduled point on, a full capture must be read before the owner
  // blocks; blocking first strands the wait. Otherwise Git exits once awaited.
  void Watch() {
    while (!reached && !exit.Task.IsCompleted) Thread.Yield();
    while (!(full && observed) && !exit.Task.IsCompleted && (owner.ThreadState & ThreadState.WaitSleepJoin) == 0) Thread.Yield();
    if (full && observed) return;
    if (exit.TrySetResult(true)) stranded = full;
  }
}
'@
  }
  function Stop-CensusFixtureGitTree($Process) {
    if ($Process -isnot [CensusGitWaitSchedule]) { throw 'synthetic-only reap' }
    $Process.Reap()
  }
  $bound = 65537
  $count = switch ($Kind) { 'full' { $bound } 'eof' { $bound - 1 } 'exit' { -1 } }
  $meter = New-DeterministicBudgetMeter
  $schedule = [CensusGitWaitSchedule]::new([int]($Stream -ceq 'stderr'), $Point, $count, $bound)
  try { $returned = $meter.WaitForProcess($schedule, $schedule.Reads, @($bound,$bound)) }
  finally { $schedule.Release() }
  [pscustomobject]@{ returned=$returned; stranded=$schedule.Stranded; reaped=$schedule.Reaped; reaps=$meter.reaps.Count; waits=$meter.processWaits }
}

function Test-CensusGitWaitSchedule {
  foreach ($kind in @('full','eof','exit')) {
    $reap = $kind -ceq 'full'
    $legs = foreach ($stream in @('stdout','stderr')) {
      foreach ($point in @('snapshot','check')) {
        $wait = Invoke-CensusGitWaitSchedule $kind $stream $point
        Assert-CensusFixture ($wait.returned -eq $true -and -not $wait.stranded -and $wait.reaped -eq $reap -and
          $wait.reaps -eq [int]$reap -and $wait.waits -eq 1) "census-git-wait-schedule/$kind/$stream/$point returned=$($wait.returned) stranded=$($wait.stranded) reaps=$($wait.reaps)"
        "$stream/$point"
      }
    }
    Write-Output "CONTROL census-git-wait-schedule/$kind PASS reaps=$([int]$reap) stranded=False legs=$($legs -join ',')"
  }
}
