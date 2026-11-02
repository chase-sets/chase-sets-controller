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

function Invoke-CensusSourceMutant([string]$Name, [string]$Old, [string]$New, [scriptblock]$Probe, [string]$Parent) {
  $text = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'dispatch-ownership.ps1'))
  Assert-CensusFixture (([regex]::Matches($text,[regex]::Escape($Old))).Count -eq 1) "single mutation $Name"
  $subject = Join-Path $Parent "$Name.ps1"
  [IO.File]::WriteAllText($subject,$text.Replace($Old,$New))
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
      $duplicate = New-CensusFixtureOwner $f
      $good = Get-CensusFixtureProjection $f
      Assert-CensusFixture ($good.health.status -ceq 'partial' -and
        @($good.health.diagnostics | Where-Object code -CEQ 'duplicate-live-ownership').Count -eq 1) 'platform duplicate worktree'
    } finally { Remove-CensusFixture $parent }
  }
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
