. (Join-Path $PSScriptRoot 'product-census-test-support.ps1')
. (Join-Path $PSScriptRoot 'integration-dispatch-test-support.ps1')

function Copy-CensusController($Fixture) {
  Get-ChildItem -LiteralPath $PSScriptRoot -File | Where-Object Extension -In @('.ps1','.psm1','.cjs','.cs') |
    Copy-Item -Destination $Fixture.runtime
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'contracts') -Destination $Fixture.runtime -Recurse
  # Bind only the product selector in the offline subject to an unmistakably
  # synthetic repository. No real PR/API identity is fabricated. The platform
  # proof constant and every native ownership/Git read are unchanged.
  foreach ($name in @('landed-integration-dispatch.ps1','dispatch-lane.ps1')) {
    $path = Join-Path $Fixture.runtime $name
    $text = [IO.File]::ReadAllText($path)
    $text = $text.Replace("-ceq 'chase-sets/chase-sets'", "-ceq '$SyntheticIntegrationRepository'")
    [IO.File]::WriteAllText($path,$text)
  }
}

function New-CensusIntegrationFixture([string]$Parent) {
  $f = New-CensusFixture $Parent
  Copy-CensusController $f
  [void](New-CensusFixtureOwner $f)
  Publish-SyntheticIntegrationRemote $f.main (Join-Path $Parent 'synthetic-product.git')
  $head = Invoke-CensusFixtureGit $f.product @('rev-parse','HEAD')
  $node = [ordered]@{ number=908185L; headRefOid=$head; headRefName='synthetic/product';
    mergeable='MERGEABLE'; mergeStateStatus='CLEAN'; worktree=$f.product;
    files=@{complete=$true;totalCount=1L;nodes=@(@{path='synthetic.txt'})} }
  $census = @{schemaVersion='landed-integration-census/v1';complete=$true;newBase=$head;
    landed=@{pr=908184L;head=('a'*40);files=@{complete=$true;totalCount=1L;nodes=@(@{path='synthetic.txt'})}};
    openPullRequests=@{complete=$true;totalCount=1L;nodes=@($node)}}
  $history = Join-Path $f.runtime 'synthetic-history.jsonl'
  [IO.File]::WriteAllText($history,'')
  Write-SyntheticIntegrationEligibility $history @($node)
  $api = Write-SyntheticIntegrationAuthority (Join-Path $Parent 'authority.json') @($node) $head
  $fixturePath = Join-Path $Parent 'census.json'
  [IO.File]::WriteAllText($fixturePath,($census | ConvertTo-Json -Depth 12))
  $sink = Join-Path $Parent 'sink.ps1'
  [IO.File]::WriteAllText($sink,@'
param($Harness,$Model,$Effort,$Row,$Placement,$LaneRole,$PromptFile,$Worktree,$Label,$StartRequestIdentity,$StartAcknowledgementPath,$IntegrationTargetPath,$IntegrationAuthorityFixturePath)
$runtime=Split-Path -Parent $StartAcknowledgementPath
[IO.File]::AppendAllText((Join-Path $runtime 'synthetic-calls.txt'),"$Label`n")
$id=[guid]::NewGuid().ToString()
$ack=@{schemaVersion='dispatch-start-ack/v1';requestIdentity=$StartRequestIdentity;label=$Label;launchId=$id;
ownershipRecordPath=(Join-Path $runtime "dispatch-launch-$id.json");worktree=$Worktree;
branch=(& git -C $Worktree branch --show-current).Trim();head=(& git -C $Worktree rev-parse HEAD).Trim();
harness=$Harness;model=$Model;effort=$Effort;row=[long]$Row;placement=$Placement;state='started';childPid=[long]$PID;
childStartIdentity=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')}
[IO.File]::WriteAllText($StartAcknowledgementPath,($ack|ConvertTo-Json -Compress))
'@)
  $f | Add-Member -NotePropertyMembers @{head=$head;node=$node;history=$history;api=$api;fixturePath=$fixturePath;sink=$sink}
  return $f
}

function Invoke-CensusIntegration($Fixture) {
  & (Join-Path $Fixture.runtime 'landed-integration-dispatch.ps1') -Repository $SyntheticIntegrationRepository `
    -LandedPr 908184 -LandedHead ('a'*40) -RuntimeRoot $Fixture.runtime -ContainerRoot $Fixture.container `
    -HistoryPath $Fixture.history -FixturePath $Fixture.fixturePath -IntegrationAuthorityFixturePath $Fixture.api `
    -DispatchScript $Fixture.sink -SynchronousDispatch | ConvertFrom-Json -DateKind String
}

function Test-PlatformSeatProductIntegration {
  $parent = Join-Path ([IO.Path]::GetTempPath()) ('synthetic-census-' + [guid]::NewGuid().ToString('N'))
  try {
    $f = New-CensusIntegrationFixture $parent
    $historySeed = [IO.File]::ReadAllText($f.history)
    foreach ($negative in @('product-endpoint','unreadable-anchor','initial-opt-in')) {
      $dispatch = Join-Path $f.runtime 'landed-integration-dispatch.ps1'
      $source = [IO.File]::ReadAllText($dispatch).Replace("`r`n","`n")
      $config = Join-Path $f.anchor '.git/config'
      $configBytes = [IO.File]::ReadAllBytes($config)
      if ($negative -ceq 'product-endpoint') {
        [void](Invoke-CensusFixtureGit $f.anchor @('config','remote.origin.pushurl','https://github.com/chase-sets/chase-sets.git'))
      } elseif ($negative -ceq 'unreadable-anchor') {
        [IO.File]::AppendAllText($config,"`n[synthetic-unreadable`n")
      } else {
        [IO.File]::WriteAllText($dispatch,$source)
        $old = "}else{`n  `$ownership=Get-LiveDispatchOwnership -RuntimeRoot `$RuntimeRoot -TempRoot ([IO.Path]::GetTempPath()) -ContainerRoot `$ContainerRoot -ProductCensus:(`$Repository -ceq '$SyntheticIntegrationRepository')"
        Set-CensusSourceMutation $f 'landed-integration-dispatch.ps1' $old $old.Replace(" -ProductCensus:(`$Repository -ceq '$SyntheticIntegrationRepository')",'')
      }
      try {
        $refusal=$null
        try { $null=Invoke-CensusIntegration $f } catch { $refusal=$_.Exception.Message }
        Assert-CensusFixture ($refusal -like 'CENSUS_UNKNOWN_ACTIVE_WRITERS*worktree-outside-container:platform-seat*' -and
          -not (Test-Path (Join-Path $f.runtime 'synthetic-calls.txt')) -and
          @(Get-ChildItem $f.runtime -Filter 'integration-owed-*.json').Count -eq 0 -and
          [IO.File]::ReadAllText($f.history) -ceq $historySeed) "initial $negative zero-effects"
        Write-Output "CONTROL initial-$negative REFUSED launch=0 owed=0 history=unchanged"
      } finally {
        [IO.File]::WriteAllBytes($config,$configBytes)
        [IO.File]::WriteAllText($dispatch,$source)
      }
    }
    $result = Invoke-CensusIntegration $f
    Assert-CensusFixture ($result.targets[0].action -ceq 'LAUNCHED' -and
      @(Get-Content (Join-Path $f.runtime 'synthetic-calls.txt')).Count -eq 1 -and
      @(Get-ChildItem $f.runtime -Filter 'integration-owed-*.json').Count -eq 0) 'platform-seat-product-integration/initial-same-branch'
    $before = [IO.File]::ReadAllText($f.history)
    $repeat = Invoke-CensusIntegration $f
    Assert-CensusFixture ([IO.File]::ReadAllText($f.history) -ceq $before -and
      @(Get-Content (Join-Path $f.runtime 'synthetic-calls.txt')).Count -eq 1) 'platform-seat-product-integration/repeat-once'
    Write-Output 'CONTROL platform-seat-product-integration initial/repeat PASS native-platform-same-branch=true launchCount=1 owedCount=0'
  } finally { Remove-CensusFixture $parent }
}

function Set-CensusSourceMutation($Fixture, [string]$File, [string]$Old, [string]$New) {
  $path = Join-Path $Fixture.runtime $File
  $source = [IO.File]::ReadAllText($path)
  Assert-CensusFixture ([regex]::Matches($source,[regex]::Escape($Old)).Count -eq 1) "single source mutation $File"
  [IO.File]::WriteAllText($path,$source.Replace($Old,$New))
}

function Test-PlatformSeatRetainedIntegration([switch]$OtherBranch, [string]$Mutant='') {
  $parent = Join-Path ([IO.Path]::GetTempPath()) ('synthetic-census-' + [guid]::NewGuid().ToString('N'))
  try {
    $f = New-CensusIntegrationFixture $parent
    if ($OtherBranch) {
      [void](Invoke-CensusFixtureGit $f.seat @('branch','-m','synthetic/platform-other'))
      $file = @(Get-ChildItem $f.runtime -Filter 'dispatch-launch-*.json')[0]
      $owner = Get-ValidatedDispatchOwnershipRecord $file.FullName $f.runtime ([IO.Path]::GetTempPath())
      $owner.branch = 'synthetic/platform-other'
      Write-DispatchOwnershipRecord $file.FullName $owner
    }
    [void](Invoke-CensusFixtureGit $f.main @('commit','-q','--allow-empty','-m','synthetic main advancement'))
    [void](Invoke-CensusFixtureGit $f.main @('push','-q','origin','main'))
    [void](Invoke-CensusFixtureGit $f.main @('fetch','-q','origin','main'))
    $newBase = Invoke-CensusFixtureGit $f.main @('rev-parse','HEAD')
    $census = Get-Content -LiteralPath $f.fixturePath -Raw | ConvertFrom-Json
    $census.newBase = $newBase
    [IO.File]::WriteAllText($f.fixturePath,($census | ConvertTo-Json -Depth 12))
    [void](Write-SyntheticIntegrationAuthority $f.api @($f.node) $newBase)
    $obligation = [ordered]@{schemaVersion='landed-integration-owed/v1';landedPr=908184L;landedHead=('a'*40);
      pr=908185L;targetHead=$f.head;newBase=$newBase;branch='synthetic/product';worktree=$f.product;
      integrationLane='integration-908184-908185-aaaaaaaa'}
    $owed = Join-Path $f.runtime 'integration-owed-908185-aaaaaaaaaaaa.json'
    [IO.File]::WriteAllText($owed,($obligation | ConvertTo-Json -Compress))
    $projection = Get-CensusFixtureProjection $f
    Assert-CensusFixture ($projection.health.status -ceq 'ok' -and $projection.activeLanes.Count -eq 0) 'retained native census is healthy'
    $authSites = @{
      'auth-branch-only' = @('if ($proof.proven) { continue }','if ($false) { continue }')
      'auth-child' = @("`$(if(`$Prelaunch){'Prelaunch'}else{'Child'}) -ProductCensus", "`$(if(`$Prelaunch){'Prelaunch'}else{'Child'}) -ProductCensus:`$Prelaunch")
      'auth-complete' = @('$owner = Get-RebaseAuthenticatedOwner $Obligation $Runtime $RecordPath Launcher -ProductCensus', '$owner = Get-RebaseAuthenticatedOwner $Obligation $Runtime $RecordPath Launcher')
      'auth-complete-recheck' = @('[void](Get-RebaseAuthenticatedOwner $Obligation $Runtime $RecordPath Launcher -ProductCensus)', '[void](Get-RebaseAuthenticatedOwner $Obligation $Runtime $RecordPath Launcher)')
    }
    if ($authSites.ContainsKey($Mutant)) {
      Set-CensusSourceMutation $f 'landed-integration-evidence.psm1' $authSites[$Mutant][0] $authSites[$Mutant][1]
    } elseif ($Mutant -in @('handoff-before','handoff-after')) {
      $n = if ($Mutant -ceq 'handoff-before') { 1 } else { 2 }
      $old = "function Get-HandoffOwnership{`n  `$ownership=Get-LiveDispatchOwnership"
      $path = Join-Path $f.runtime 'landed-integration-dispatch.ps1'
      $source = [IO.File]::ReadAllText($path).Replace("`r`n","`n")
      [IO.File]::WriteAllText($path,$source)
      Set-CensusSourceMutation $f 'landed-integration-dispatch.ps1' $old "function Get-HandoffOwnership{`n  `$script:censusCalls++; `$ownership=Get-LiveDispatchOwnership"
      $old = "`$script:censusCalls++; `$ownership=Get-LiveDispatchOwnership -RuntimeRoot `$RuntimeRoot -TempRoot ([IO.Path]::GetTempPath()) -ContainerRoot `$ContainerRoot -ProductCensus:(`$Repository -ceq '$SyntheticIntegrationRepository')"
      Set-CensusSourceMutation $f 'landed-integration-dispatch.ps1' $old $old.Replace("-ProductCensus:(`$Repository -ceq '$SyntheticIntegrationRepository')", "-ProductCensus:((`$Repository -ceq '$SyntheticIntegrationRepository') -and `$script:censusCalls -ne $n)")
    }
    if ($Mutant) {
      $historyBefore = [IO.File]::ReadAllText($f.history)
      $refusal = $null
      try { $null = Invoke-CensusIntegration $f } catch { $refusal = $_.Exception.Message }
      Assert-CensusFixture ($refusal -and (Test-Path $owed) -and
        [IO.File]::ReadAllText($f.history) -ceq $historyBefore -and
        @(Get-ChildItem $f.runtime -Filter 'integration-rebase-complete-*.json').Count -eq 0 -and
        @(Get-ChildItem $f.runtime -Filter 'dispatch-launch-*.json').Count -eq 1) "retained per-site mutant $Mutant preserves pending/history/platform-owner"
      Write-Output "MUTANT $Mutant KILLED native-retained refusal=$refusal owed=retained completion=absent history=unchanged"
      return
    }
    $result = Invoke-CensusIntegration $f
    Assert-CensusFixture ($result.targets[0].action -ceq 'OWED_ACTIVE_WRITER' -and
      $result.targets[0].handoff -ceq 'NO_OWNER_CLAIM' -and -not (Test-Path $owed)) 'platform-seat-product-integration/retained-advanced-same-branch'
    Write-Output "CONTROL platform-seat-product-integration/retained-advanced PASS otherBranch=$OtherBranch"
  } finally { Remove-CensusFixture $parent }
}

function Test-PlatformSeatNativePublication {
  foreach ($mode in @('candidate','publication','prelaunch','reducer-reads-register')) {
    $parent = Join-Path ([IO.Path]::GetTempPath()) ('synthetic-census-' + [guid]::NewGuid().ToString('N'))
    try {
      $f = New-CensusIntegrationFixture $parent
      $label = 'synthetic-8185-native'
      $request = [ordered]@{schemaVersion='integration-dispatch-request/v1';requestIdentity=('c'*64);
        repository=$SyntheticIntegrationRepository;pr=908185L;landedPr=908184L;landedHead=('a'*40);
        head=$f.head;newBase=$f.head;branch='synthetic/product';worktree=$f.product;label=$label;
        sourceIdentity='ABSENT_REVIEW_REQUIRED';sourceHead='';runtimeRoot=$f.runtime;historyPath=$f.history}
      $requestPath = Join-Path $f.runtime "integration-request-$label.json"
      [IO.File]::WriteAllText($requestPath,($request | ConvertTo-Json -Compress))
      $obligation = [ordered]@{schemaVersion='landed-integration-owed/v1';landedPr=908184L;landedHead=('a'*40);
        pr=908185L;targetHead=$f.head;newBase=$f.head;branch='synthetic/product';worktree=$f.product;
        integrationLane='integration-908184-908185-aaaaaaaa'}
      $owed = Join-Path $f.runtime 'integration-owed-908185-aaaaaaaaaaaa.json'
      [IO.File]::WriteAllText($owed,($obligation | ConvertTo-Json -Compress))
      $prompt = Join-Path $f.runtime "$label.prompt.txt"; [IO.File]::WriteAllText($prompt,'Synthetic native publication')
      $marker = Join-Path $parent 'entered.txt'
      $child = Join-Path $parent 'inert-child.ps1'
      [IO.File]::WriteAllText($child,'param($Marker); [void][Console]::In.ReadToEnd(); [IO.File]::WriteAllText($Marker,''entered''); ''{"type":"turn.completed"}''')
      New-Item -ItemType Directory (Join-Path $f.runtime 'platform-handoff.md') | Out-Null
      if ($mode -ceq 'publication') {
        Set-CensusSourceMutation $f 'dispatch-lane.ps1' " -ProductCensus:(`$integrationTarget.repository -ceq '$SyntheticIntegrationRepository')" ''
      } elseif ($mode -ceq 'prelaunch') {
        Set-CensusSourceMutation $f 'landed-integration-evidence.psm1' "`$(if(`$Prelaunch){'Prelaunch'}else{'Child'}) -ProductCensus" "`$(if(`$Prelaunch){'Prelaunch'}else{'Child'}) -ProductCensus:(-not `$Prelaunch)"
      } elseif ($mode -ceq 'reducer-reads-register') {
        Set-CensusSourceMutation $f 'dispatch-ownership.ps1' '$productAnchors = @{}' '$productAnchors = @{}; try { [void][IO.File]::ReadAllText((Join-Path $RuntimeRoot ''platform-handoff.md'')) } catch { throw ''synthetic unreadable register read'' }'
      }
      $parameters = @{Harness='codex';Model='gpt-6-astra';Effort='high';Row=7;Placement='override-Todd';LaneRole='implementation';
        PromptFile=$prompt;Worktree=$f.product;Label=$label;IntegrationTargetPath=$requestPath;IntegrationAuthorityFixturePath=$f.api;
        StartRequestIdentity=('c'*64);StartAcknowledgementPath=(Join-Path $f.runtime "dispatch-start-$('c'*64).json");
        ExecutablePath=(Join-Path $PSHOME 'pwsh.exe');TestRuntimeRoot=$f.runtime;TestTempRoot=$f.temp;
        TestArgumentList=@('-NoProfile','-NonInteractive','-File',$child,$marker)}
      $config = Join-Path $parent 'launch.json'
      [IO.File]::WriteAllText($config,(@{launcher=(Join-Path $f.runtime 'dispatch-lane.ps1');parameters=$parameters} | ConvertTo-Json -Depth 8))
      $runner = Join-Path $parent 'launch.ps1'
      [IO.File]::WriteAllText($runner,'param($Config); $c=Get-Content -LiteralPath $Config -Raw | ConvertFrom-Json -AsHashtable; $p=$c.parameters; & $c.launcher @p; exit $LASTEXITCODE')
      $output = @(& pwsh -NoProfile -NonInteractive -File $runner $config 2>&1); $code = $LASTEXITCODE
      if ($mode -ceq 'candidate') {
        Assert-CensusFixture ($code -eq 0 -and (Test-Path $marker) -and
          @(Get-ChildItem $f.runtime -Filter 'integration-rebase-prelaunch-*.json').Count -eq 1) "native publication and prelaunch green: $($output -join ' ')"
        Assert-CensusFixture ((Get-CensusFixtureProjection $f -Unscoped).health.status -ceq 'partial') 'native ordinary/vacancy census remains strict'
        Write-Output 'CONTROL native dispatch-lane publication/Prelaunch PASS unreadable-register=true native-platform-owner=true unscoped=partial'
      } else {
        Assert-CensusFixture ($code -ne 0 -and -not (Test-Path $marker) -and (Test-Path $owed)) "native publication mutant $mode refuses: exit=$code output=$($output -join ' ')"
        Write-Output "MUTANT native-$mode KILLED exit=$code child=not-entered owed=retained"
      }
    } finally { Remove-CensusFixture $parent }
  }
}

function Test-PlatformSeatLiveProductOwner {
  $parent = Join-Path ([IO.Path]::GetTempPath()) ('synthetic-census-' + [guid]::NewGuid().ToString('N'))
  try {
    $f = New-CensusIntegrationFixture $parent
    $owner = New-CensusFixtureOwner $f $f.product
    $history = [IO.File]::ReadAllText($f.history)
    $result = Invoke-CensusIntegration $f
    Assert-CensusFixture ($result.targets[0].action -ceq 'HANDOFF_RETRYABLE' -and
      @(Get-ChildItem $f.runtime -Filter 'dispatch-launch-*.json').Count -eq 2 -and
      @(Get-ChildItem $f.runtime -Filter 'integration-owed-*.json').Count -eq 1 -and
      -not (Test-Path (Join-Path $f.runtime 'synthetic-calls.txt')) -and
      [IO.File]::ReadAllText($f.history) -ceq $history) 'live product owner receives owed without duplicate or foreign completion'
    $owed = @(Get-ChildItem $f.runtime -Filter 'integration-owed-*.json')[0]
    $owedBytes = [IO.File]::ReadAllText($owed.FullName)
    $result = Invoke-CensusIntegration $f
    Assert-CensusFixture ($result.targets[0].action -ceq 'HANDOFF_RETRYABLE' -and
      [IO.File]::ReadAllText($owed.FullName) -ceq $owedBytes -and [IO.File]::ReadAllText($f.history) -ceq $history) 'live owner repeated pending is immutable'
    $sourcePath = Join-Path $f.runtime 'landed-integration-dispatch.ps1'
    $source = [IO.File]::ReadAllText($sourcePath).Replace("`r`n","`n")
    [IO.File]::WriteAllText($sourcePath,$source)
    $old = "function Get-HandoffOwnership{`n  `$ownership=Get-LiveDispatchOwnership -RuntimeRoot `$RuntimeRoot -TempRoot ([IO.Path]::GetTempPath()) -ContainerRoot `$ContainerRoot -ProductCensus:(`$Repository -ceq '$SyntheticIntegrationRepository')"
    Set-CensusSourceMutation $f 'landed-integration-dispatch.ps1' $old $old.Replace(" -ProductCensus:(`$Repository -ceq '$SyntheticIntegrationRepository')",'')
    $refusal = $null
    try { $null=Invoke-CensusIntegration $f } catch { $refusal=$_.Exception.Message }
    Assert-CensusFixture ($refusal -like 'CENSUS_UNKNOWN_ACTIVE_WRITERS*worktree-outside-container:platform-seat*' -and
      [IO.File]::ReadAllText($owed.FullName) -ceq $owedBytes -and [IO.File]::ReadAllText($f.history) -ceq $history) 'live-owner handoff opt-in mutant killed'
    Write-Output 'CONTROL live-product-owner PASS owed/repeat retained foreign-cannot-complete no-duplicate-writer; MUTANT live-owner-handoff KILLED'
  } finally { Remove-CensusFixture $parent }
}
