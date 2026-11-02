# Loaded by the R3 production-caller suite. All identities below belong to newly
# created synthetic repositories; no live incident bytes are rewritten as tests.
function Test-8185AuthPartition {
  . (Join-Path $PSScriptRoot 'dispatch-ownership.ps1')
  . (Join-Path $PSScriptRoot 'product-census-integration-test-support.ps1')
  $parent = Join-Path ([IO.Path]::GetTempPath()) ('synthetic-census-' + [guid]::NewGuid().ToString('N'))
  try {
    $f = New-CensusFixture $parent
    Copy-CensusController $f
    $foreign = New-CensusFixtureOwner $f
    $owner = New-CensusFixtureOwner $f $f.product
    $owner.record.state = 'launching'; $owner.record.childPid = $null; $owner.record.childStartIdentity = $null
    Write-DispatchOwnershipRecord $owner.path $owner.record
    $o = [pscustomobject][ordered]@{schemaVersion='landed-integration-owed/v1';landedPr=908184L;landedHead=('a'*40);
      pr=908185L;targetHead=$owner.record.head;newBase=$owner.record.head;branch=$owner.record.branch;
      worktree=$f.product;integrationLane='integration-908184-908185-aaaaaaaa'}
    $owedPath=Join-Path $f.runtime 'integration-owed-908185-aaaaaaaaaaaa.json'
    $owedText=$o | ConvertTo-Json -Compress
    [IO.File]::WriteAllText($owedPath,$owedText)
    $historyPath=Join-Path $f.runtime 'synthetic-auth-history.jsonl'
    [IO.File]::WriteAllText($historyPath,'')
    $modulePath = Join-Path $f.runtime 'landed-integration-evidence.psm1'
    $source = [IO.File]::ReadAllText($modulePath)
    function Auth([switch]$Strict, [string]$Runtime=$f.runtime, [string]$Path=$owner.path) {
      try {
        $value = Get-RebaseAuthenticatedOwner $o $Runtime $Path Prelaunch -ProductCensus:(-not $Strict)
        return $value.launchId
      } catch { return $_.Exception.Message }
      finally {
        Assert-CensusFixture ([IO.File]::ReadAllText($owedPath) -ceq $owedText -and
          [IO.File]::ReadAllText($historyPath) -ceq '' -and
          @(Get-ChildItem $f.runtime -Filter 'integration-rebase-complete-*.json').Count -eq 0) 'auth observations preserve owed/history and never publish completion'
      }
    }
    Import-Module $modulePath -Force -DisableNameChecking
    Assert-CensusFixture ((Auth) -ceq $owner.record.launchId) 'auth native platform partition grants only exact product owner'
    Assert-CensusFixture ((Auth -Strict) -ceq 'OWED_REBASE_OWNER_UNAUTHORIZED: unique owner') 'auth defaults strict'
    $guard = 'if ($proof.proven) { continue }'
    Assert-CensusFixture ([regex]::Matches($source,[regex]::Escape($guard)).Count -eq 1) 'auth branch-only mutant carrier'
    [IO.File]::WriteAllText($modulePath,$source.Replace($guard,'if ($false) { continue }'))
    Import-Module $modulePath -Force -DisableNameChecking
    Assert-CensusFixture ((Auth) -ceq 'OWED_REBASE_OWNER_UNAUTHORIZED: unique owner') 'auth-branch-only killed'
    [IO.File]::WriteAllText($modulePath,$source)
    Import-Module $modulePath -Force -DisableNameChecking
    foreach ($differentWorktree in @($false,$true)) {
      $duplicatePath = $f.product
      if ($differentWorktree) {
        $duplicatePath = Join-Path $f.container 'other-product-seat'
        [void](Invoke-CensusFixtureGit $f.main @('worktree','add','--force','-q',$duplicatePath,$o.branch))
      }
      $duplicate = New-CensusFixtureOwner $f $duplicatePath
      Assert-CensusFixture ((Auth) -ceq 'OWED_REBASE_OWNER_UNAUTHORIZED: unique owner') "same-repo duplicate differentWorktree=$differentWorktree"
      if ($differentWorktree) {
        $old = 'if ($record.branch -ceq $Obligation.branch -and (Get-DispatchProcessIdentityState $record.launcherPid $record.launcherStartIdentity) -ceq ''live'') {'
        Assert-CensusFixture ([regex]::Matches($source,[regex]::Escape($old)).Count -eq 1) 'auth exact-worktree mutant carrier'
        [IO.File]::WriteAllText($modulePath,$source.Replace($old,'if ((Test-DispatchSamePath $record.worktree $Obligation.worktree) -and $record.branch -ceq $Obligation.branch -and (Get-DispatchProcessIdentityState $record.launcherPid $record.launcherStartIdentity) -ceq ''live'') {'))
        Import-Module $modulePath -Force -DisableNameChecking
        Assert-CensusFixture ((Auth) -ceq $owner.record.launchId) 'auth-exact-worktree-only exposes hidden duplicate'
        [IO.File]::WriteAllText($modulePath,$source)
        Import-Module $modulePath -Force -DisableNameChecking
      }
      Remove-Item -LiteralPath $duplicate.path
    }
    $outside = Join-Path $parent 'outside-product'
    [void](Invoke-CensusFixtureGit $f.main @('worktree','add','--force','-q',$outside,$o.branch))
    $duplicate = New-CensusFixtureOwner $f $outside
    Assert-CensusFixture ((Auth) -ceq 'OWED_REBASE_OWNER_UNAUTHORIZED: unique owner') 'outside product counts in uniqueness'
    Remove-Item -LiteralPath $duplicate.path
    [void](Invoke-CensusFixtureGit $f.anchor @('config','remote.origin.pushurl','https://github.com/chase-sets/chase-sets.git'))
    Assert-CensusFixture ((Auth) -ceq 'OWED_REBASE_OWNER_UNAUTHORIZED: unique owner') 'unknown outside proof stays counted'
    [void](Invoke-CensusFixtureGit $f.anchor @('config','--unset-all','remote.origin.pushurl'))
    $other = Join-Path $parent 'other-container'
    $runtime = Join-Path $other '.orchestrator'; $main = Join-Path $other 'main'
    New-Item -ItemType Directory -Path $runtime,$main | Out-Null
    foreach ($repository in @($other,$main)) {
      [void](Invoke-CensusFixtureGit $repository @('init','-q','--initial-branch=main'))
      [void](Invoke-CensusFixtureGit $repository @('config','user.name','Synthetic Other'))
      [void](Invoke-CensusFixtureGit $repository @('config','user.email','synthetic-other@example.invalid'))
      [void](Invoke-CensusFixtureGit $repository @('commit','-q','--allow-empty','-m','synthetic other'))
    }
    foreach ($item in @($owner,$foreign)) {
      $r = $item.record | ConvertTo-Json | ConvertFrom-Json -DateKind String
      $r.promptPath = Join-Path $runtime (Split-Path -Leaf $r.promptPath)
      $r.transcriptPath = Join-Path $runtime (Split-Path -Leaf $r.transcriptPath)
      Write-DispatchOwnershipRecord (Join-Path $runtime (Split-Path -Leaf $item.path)) $r -CreateNew
    }
    Assert-CensusFixture ((Auth -Runtime $runtime -Path (Join-Path $runtime (Split-Path -Leaf $owner.path))) -ceq 'OWED_REBASE_OWNER_UNAUTHORIZED: unique owner') 'F1 runtime-parent product repository mismatch stays strict'
    $guard = '(Test-DispatchSameCanonicalPath $target.commonDir $product.commonDir)'
    Assert-CensusFixture ([regex]::Matches($source,[regex]::Escape($guard)).Count -eq 1) 'F1 governing common-dir guard'
    [IO.File]::WriteAllText($modulePath,$source.Replace($guard,'$true'))
    Import-Module $modulePath -Force -DisableNameChecking
    Assert-CensusFixture ((Auth -Runtime $runtime -Path (Join-Path $runtime (Split-Path -Leaf $owner.path))) -ceq $owner.record.launchId) 'F1 product obligation proof omission unmasked'
    [IO.File]::WriteAllText($modulePath,$source)
    Import-Module $modulePath -Force -DisableNameChecking
    $strictCalls = @(
      '$owner = Get-RebaseAuthenticatedOwner $binding.obligation $Runtime $RecordPath Child',
      '$owner = Get-RebaseAuthenticatedOwner $Obligation $Runtime $RecordPath Launcher',
      '[void](Get-RebaseAuthenticatedOwner $Obligation $Runtime $RecordPath Launcher)'
    )
    foreach ($call in $strictCalls) {
      Assert-CensusFixture ($source.Contains($call + "`n") -or $source.Contains($call + "`r`n")) 'interrupted auth call stays strict'
      $command = [regex]::Match($call,'Get-RebaseAuthenticatedOwner .+? (Child|Launcher)').Value
      $Runtime=$f.runtime; $RecordPath=$owner.path; $Obligation=$o; $binding=@{obligation=$o}
      $refusal=$null
      try { & ([scriptblock]::Create($command)) | Out-Null } catch { $refusal=$_.Exception.Message }
      Assert-CensusFixture ($refusal -ceq 'OWED_REBASE_OWNER_UNAUTHORIZED: unique owner') "strict interrupted production call with proven same-branch platform: $command"
    }
    Assert-CensusFixture ($source.Contains('if ($resumeRecord -and $resumeRecord.schemaVersion -eq 5) { return Complete-InterruptedIntegration $Obligation $Runtime $RecordPath }')) 'v5 completion delegation remains strict'
    Write-Output 'CONTROL 8185 auth partition PASS native-product/live-platform; strict/duplicate-same-worktree/duplicate-other-worktree/outside-product/unknown/runtime-parent-main refuse; MUTANTS auth-branch-only/auth-exact-worktree-only KILLED'
  } finally {
    Import-Module (Join-Path $PSScriptRoot 'landed-integration-evidence.psm1') -Force -DisableNameChecking
    Remove-CensusFixture $parent
  }
}

function Add-8185PlatformSibling([string]$Case,[string]$Runtime,[string]$Repository,[string]$Branch) {
  . (Join-Path $PSScriptRoot 'dispatch-ownership.ps1')
  . (Join-Path $PSScriptRoot 'product-census-integration-test-support.ps1')
  $parent = Split-Path -Parent $Case
  $anchor = Join-Path $parent 'orchestration-platform'
  $seat = Join-Path $parent ('platform-' + (Split-Path -Leaf $Case))
  foreach ($path in @($Case,$anchor)) {
    if (-not (Test-Path (Join-Path $path '.git'))) {
      New-Item -ItemType Directory -Path $path -Force | Out-Null
      [void](Invoke-CensusFixtureGit $path @('init','-q','--initial-branch=main'))
      [void](Invoke-CensusFixtureGit $path @('config','user.name','Synthetic Platform'))
      [void](Invoke-CensusFixtureGit $path @('config','user.email','synthetic-platform@example.invalid'))
      [void](Invoke-CensusFixtureGit $path @('commit','-q','--allow-empty','-m','synthetic root'))
    }
  }
  if (-not (Invoke-CensusFixtureGit $anchor @('remote'))) {
    [void](Invoke-CensusFixtureGit $anchor @('remote','add','origin','https://github.com/todd-skelton/orchestration-platform.git'))
  }
  [void](Invoke-CensusFixtureGit $anchor @('worktree','add','-q','-b',$Branch,$seat,'HEAD'))
  [void](Invoke-CensusFixtureGit $Repository @('worktree','add','-q',(Join-Path $Case 'main'),'main'))
  $f = [pscustomobject]@{runtime=$Runtime;container=$Case;seat=$seat;temp=[IO.Path]::GetTempPath()}
  [void](New-CensusFixtureOwner $f)
  Copy-CensusController $f
}

function Test-7926CompletedRebase([string[]]$Modes=@('prospective','platform','platform-complete','platform-complete-recheck','late-owed','legacy','skip-release','review','planning','foreign-release')) {
  Import-Module (Join-Path $PSScriptRoot 'landed-integration-evidence.psm1') -Force -DisableNameChecking
  $root=Join-Path $fixtureRoot 'synthetic-7926'
  New-Item -ItemType Directory -Path $root | Out-Null
  $proofCount=0
  function Proof([bool]$Condition,[string]$Name) {
    Assert-True $Condition $Name
    $script:rebaseProofCount++
    Write-Output "PROOF 7926 $Name"
  }
  $script:rebaseProofCount=0
  function Native([string]$Repo,[string[]]$Arguments) {
    $Arguments=@($Arguments | Where-Object { $_ -cne '--path-format=absolute' })
    $output=@(& git -C $Repo @Arguments 2>&1);$code=$LASTEXITCODE
    if($code -ne 0){throw "synthetic git $($Arguments -join ' ') exit=$code $($output -join "`n")"}
    $value=($output -join "`n").Trim()
    if ($Arguments -contains '--git-path' -and -not [IO.Path]::IsPathFullyQualified($value)) { return [IO.Path]::GetFullPath((Join-Path $Repo $value)) }
    return $value
  }
  function Run-Process([string]$Script,[string[]]$Arguments,[string]$Stem) {
    $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=(Join-Path $PSHOME 'pwsh.exe');$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    foreach($arg in @('-NoProfile','-NonInteractive','-File',$Script)+$Arguments){[void]$psi.ArgumentList.Add($arg)}
    $p=[Diagnostics.Process]::Start($psi)
    try{$out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync();$p.WaitForExit();$text=$out.GetAwaiter().GetResult();$errorText=$err.GetAwaiter().GetResult();[IO.File]::WriteAllText("$Stem.stdout",$text);[IO.File]::WriteAllText("$Stem.stderr",$errorText);[IO.File]::WriteAllText("$Stem.exit",[string]$p.ExitCode);return [pscustomobject]@{exit=$p.ExitCode;stdout=$text;stderr=$errorText}}finally{$p.Dispose()}
  }
  function Movement-Counts([string]$Path) {
    $starts=@(Get-Content -LiteralPath $Path | ForEach-Object { $_ | ConvertFrom-Json -DateKind String } | Where-Object { $_.event -ceq 'start' })
    [ordered]@{rebase=@($starts|Where-Object{$_.argv -contains 'rebase' -and $_.argv -notcontains '--continue'}).Count;continuation=@($starts|Where-Object{$_.argv -contains 'rebase' -and $_.argv -contains '--continue'}).Count;push=@($starts|Where-Object{$_.argv -contains 'push'}).Count}
  }
  $harness=Join-Path $root 'synthetic-execution-harness.ps1'
  [IO.File]::WriteAllText($harness,@'
$ErrorActionPreference='Stop'
$cfg=Get-Content -Raw $env:SYNTHETIC_7926_CONFIG | ConvertFrom-Json -DateKind String
Set-Location $cfg.worktree
[void][Console]::In.ReadToEnd()
function Emit($Id,$Command,$Output,$Code) {
  [ordered]@{type='item.completed';item=[ordered]@{id=$Id;type='command_execution';command=$Command;aggregated_output=$Output;exit_code=[long]$Code;status=$(if($Code -eq 0){'completed'}else{'failed'})}} | ConvertTo-Json -Compress -Depth 8
}
function Invoke-SyntheticHarnessGit([string[]]$Arguments) {
  $output=@(& git @Arguments 2>&1);$code=$LASTEXITCODE
  if($code -ne 0){throw "synthetic Git exit=$code $output"}
  return ($output -join "`n").Trim()
}
if ($cfg.lateOwed) { [IO.File]::WriteAllText($cfg.owedPath,$cfg.owedJson) }
$args=@('-NoProfile','-NonInteractive','-File',$cfg.rebase,'-Pr',[string]$cfg.pr,'-ReviewedHead',$cfg.original,'-NewBase',$cfg.base,'-SourcePassReceiptIdentity','ABSENT_REVIEW_REQUIRED','-IntegrationLane',$cfg.lane,'-Worktree',$cfg.worktree,'-HistoryPath',$cfg.history)
if (-not $cfg.legacy) { $args+=@('-RuntimeRoot',$cfg.runtime) }
$output=@(& pwsh @args 2>&1);$code=$LASTEXITCODE
Emit 'synthetic-conflict' ($args -join ' ') ($output -join "`n") $code
if($code -ne 2){throw "expected actual native conflict, got $code"}
[IO.File]::WriteAllText((Join-Path $cfg.worktree 'conflict.txt'),'synthetic composed base and feature')
[void](Invoke-SyntheticHarnessGit @('add','conflict.txt'))
$env:GIT_EDITOR='true'
$output=@(& git rebase --continue 2>&1);$code=$LASTEXITCODE
Emit 'synthetic-finish' 'git rebase --continue' (($output -join "`n")+"`nRAW_REBASE_CONTINUE_EXIT=$code") $code
if($code -ne 0){throw 'synthetic conflict did not finish'}
$result=Invoke-SyntheticHarnessGit @('rev-parse','HEAD');$tree=Invoke-SyntheticHarnessGit @('rev-parse','HEAD^{tree}')
$remote=(Invoke-SyntheticHarnessGit @('ls-remote','--heads','origin',"refs/heads/$($cfg.branch)")).Split("`t")[0]
$pushCommand="git push --force-with-lease=$($cfg.branch):$($cfg.original) origin HEAD:$($cfg.branch) result=$result"
$output=@(& git push "--force-with-lease=$($cfg.branch):$($cfg.original)" origin "HEAD:$($cfg.branch)" 2>&1);$code=$LASTEXITCODE
Emit 'synthetic-push' $pushCommand ("PREPUSH_HEAD=$result`nPREPUSH_TREE=$tree`nOBSERVED_LS_REMOTE=$remote`n"+($output -join "`n")+"`nRAW_PUSH_EXIT=$code") $code
if($code -ne 0){throw 'synthetic publication failed'}
$remote=(Invoke-SyntheticHarnessGit @('ls-remote','--heads','origin',"refs/heads/$($cfg.branch)")).Split("`t")[0]
$branch=Invoke-SyntheticHarnessGit @('branch','--show-current')
& git merge-base --is-ancestor $cfg.base HEAD
$code=$LASTEXITCODE
Emit 'synthetic-probe' "git ls-remote origin; git merge-base --is-ancestor $($cfg.base) HEAD" "HEAD=$result`nTREE=$tree`nBRANCH=$branch`nREMOTE_HEAD=$remote`nBASE_ANCESTOR_EXIT=$code" $code
[IO.File]::WriteAllText($cfg.resultPath,([ordered]@{head=$result;tree=$tree;remote=$remote}|ConvertTo-Json -Compress))
if ($cfg.foreignRelease) {
  $ownerPath=@(Get-ChildItem -LiteralPath $cfg.runtime -Filter 'dispatch-launch-*.json' -File)[0].FullName
  $foreign=Get-Content -Raw $ownerPath|ConvertFrom-Json -DateKind String
  $foreign.childPid=[long]2147483000
  [IO.File]::WriteAllText($ownerPath,($foreign|ConvertTo-Json -Compress))
}
exit $code
'@)
  $launcherRunner=Join-Path $root 'launch.ps1'
  [IO.File]::WriteAllText($launcherRunner,@'
$cfg=Get-Content -Raw $env:SYNTHETIC_7926_CONFIG | ConvertFrom-Json -DateKind String
& $cfg.dispatch -Harness codex -Model gpt-6-astra -Effort high -Row 7 -Placement override-Todd -LaneRole $cfg.role -PromptFile $cfg.prompt -Worktree $cfg.worktree -Label $cfg.label -ExecutablePath (Join-Path $PSHOME 'pwsh.exe') -TestArgumentList @('-NoProfile','-NonInteractive','-File',$cfg.harness) -TestRuntimeRoot $cfg.runtime
exit $LASTEXITCODE
'@)
  $originalProducer = $producer
  foreach($mode in $Modes) {
    $producer = $originalProducer
    $case=Join-Path $root $mode;$runtime=Join-Path $case 'runtime';$repo=Join-Path $case 'lane';$remote=Join-Path $case 'remote.git'
    New-Item -ItemType Directory -Path $runtime,$repo | Out-Null
    $trace=Join-Path $case 'native-git-trace.jsonl';$env:GIT_TRACE2_EVENT=$trace
    [void](Native $repo @('init','-q','--initial-branch=main'));[void](Native $repo @('config','user.name','Synthetic 7926'));[void](Native $repo @('config','user.email','synthetic-7926@example.invalid'))
    [IO.File]::WriteAllText((Join-Path $repo 'conflict.txt'),'synthetic ancestor');[void](Native $repo @('add','.'));[void](Native $repo @('commit','-qm','synthetic common'))
    $oldBase=Native $repo @('rev-parse','HEAD');$branch="synthetic/7926-$mode"
    [void](Native $repo @('checkout','-qb',$branch));[IO.File]::WriteAllText((Join-Path $repo 'conflict.txt'),'synthetic feature');[void](Native $repo @('commit','-qam','synthetic feature'))
    $original=Native $repo @('rev-parse','HEAD')
    [void](Native $repo @('checkout','-q','main'));[void](Native $repo @('checkout','-qb',"synthetic/landed-$mode"))
    [IO.File]::WriteAllText((Join-Path $repo 'conflict.txt'),'synthetic landed');[void](Native $repo @('commit','-qam','synthetic landed'))
    $landed=Native $repo @('rev-parse','HEAD');[void](Native $repo @('checkout','-q','main'));[void](Native $repo @('merge','--no-ff','-m','synthetic landed merge',"synthetic/landed-$mode"))
    $base=Native $repo @('rev-parse','HEAD');[void](Native $repo @('checkout','-q',$branch))
    [void](Native $repo @('init','--bare',$remote));[void](Native $repo @('remote','add','origin',$remote));[void](Native $repo @('push','origin',"HEAD:refs/heads/$branch"))
    $pr=[long]992601;$landedPr=[long]992600;$lane="integration-$landedPr-$pr-$($landed.Substring(0,8))"
    Proof ($landed -cne $base -and (Native $repo @('diff','--name-only',$oldBase,$landed)) -ceq 'conflict.txt' -and (Native $repo @('diff','--name-only',$oldBase,$original)) -ceq 'conflict.txt') "$mode distinct landed source/base and actual intersecting census file"
    $owed=[ordered]@{schemaVersion='landed-integration-owed/v1';landedPr=$landedPr;landedHead=$landed;pr=$pr;targetHead=$original;newBase=$base;branch=$branch;worktree=$repo;integrationLane=$lane}
    $owedPath=Join-Path $runtime "integration-owed-$pr-$($landed.Substring(0,12)).json";$owedJson=$owed|ConvertTo-Json -Compress
    if($mode -ne 'late-owed'){[IO.File]::WriteAllText($owedPath,$owedJson)}
    $history=Join-Path $runtime 'dispatch-log.jsonl';$prompt=Join-Path $runtime 'synthetic.prompt.txt';[IO.File]::WriteAllText($prompt,"Synthetic integration $pr $original $base $branch $repo")
    $dispatch=Join-Path $PSScriptRoot 'dispatch-lane.ps1';$rebase=Join-Path $PSScriptRoot 'rebase-integration.ps1'
    if ($mode -like 'platform*') {
      Add-8185PlatformSibling $case $runtime $repo $branch
      $dispatch=Join-Path $runtime 'dispatch-lane.ps1';$rebase=Join-Path $runtime 'rebase-integration.ps1'
      $producer=Join-Path $runtime 'landed-integration-dispatch.ps1'
      if ($mode -ne 'platform') {
        . (Join-Path $PSScriptRoot 'product-census-integration-test-support.ps1')
        $old = if ($mode -ceq 'platform-complete') { '$owner = Get-RebaseAuthenticatedOwner $Obligation $Runtime $RecordPath Launcher -ProductCensus' } else { '[void](Get-RebaseAuthenticatedOwner $Obligation $Runtime $RecordPath Launcher -ProductCensus)' }
        Set-CensusSourceMutation ([pscustomobject]@{runtime=$runtime}) 'landed-integration-evidence.psm1' $old $old.Replace(' -ProductCensus','')
      }
    }
    if($mode -in @('legacy','skip-release')) {
      $baseline=Join-Path $case 'baseline';New-Item -ItemType Directory -Path $baseline | Out-Null
      # Execute the immutable installed baseline callers, with their complete
      # runtime dependencies, solely against this case's synthetic roots.
      Copy-Item -Path (Join-Path $PSScriptRoot '*') -Destination $baseline -Recurse -Exclude 'controller-skills','artifacts','logs'
      foreach($name in $(if($mode -eq 'legacy'){@('dispatch-lane.ps1','rebase-integration.ps1','landed-integration-consume.ps1')}else{@()})) {
        $bytes=@(& git -C (Split-Path -Parent $PSScriptRoot) show "177f2d55176d122b267444c3de240927f98285ff:.orchestrator/$name")
        if($LASTEXITCODE -ne 0){throw 'immutable baseline unavailable'}
        [IO.File]::WriteAllText((Join-Path $baseline $name),($bytes -join "`n"))
      }
      $dispatch=Join-Path $baseline 'dispatch-lane.ps1';$rebase=Join-Path $baseline 'rebase-integration.ps1'
      if($mode -eq 'skip-release') {
        $text=[IO.File]::ReadAllText($dispatch);$release='        & $consumer @consumerArguments | Out-Null'
        Assert-True ([regex]::Matches($text,[regex]::Escape($release)).Count -eq 1) 'release omission exact carrier'
        [IO.File]::WriteAllText($dispatch,$text.Replace($release,'        $null=$true <# skip-release-capture bypass #>'))
      }
    }
    $label="synthetic-7926-$mode";$resultPath=Join-Path $case 'result.json'
    $cfg=[ordered]@{dispatch=$dispatch;rebase=$rebase;harness=$harness;pr=$pr;original=$original;base=$base;branch=$branch;worktree=$repo;runtime=$runtime;history=$history;prompt=$prompt;label=$label;lane=$lane;role=$(if($mode -in @('review','planning')){$mode}else{'implementation'});foreignRelease=($mode -eq 'foreign-release');lateOwed=($mode -eq 'late-owed');legacy=($mode -eq 'legacy');owedPath=$owedPath;owedJson=$owedJson;resultPath=$resultPath}
    $configPath=Join-Path $case 'config.json';[IO.File]::WriteAllText($configPath,($cfg|ConvertTo-Json -Compress));$env:SYNTHETIC_7926_CONFIG=$configPath
    $execution=Run-Process $launcherRunner @() (Join-Path $case 'execution')
    if ($mode -in @('review','planning')) {
      $native=Movement-Counts $trace;$transcript=[IO.File]::ReadAllText((Join-Path $runtime "$label.jsonl"))
      Proof ($execution.exit -ne 0 -and $transcript.Contains('OWED_REBASE_OWNER_UNAUTHORIZED') -and $native.rebase -eq 0 -and $native.continuation -eq 0 -and $native.push -eq 1 -and (Native $repo @('rev-parse','HEAD')) -ceq $original -and [IO.File]::ReadAllText($owedPath) -ceq $owedJson) "production $mode dispatcher child refused before native rebase or publication"
      continue
    }
    if(-not(Test-Path $resultPath)){throw "7926 $mode execution failed: $($execution.stdout) $($execution.stderr)"}
    $result=Get-Content -Raw $resultPath|ConvertFrom-Json -DateKind String
    Proof ($result.head -cne $original -and $result.remote -ceq $result.head -and (Native $repo @('merge-base',$base,$result.head)) -ceq $base) "$mode actual conflicting Git/bare-remote result"
    Proof ([IO.File]::ReadAllText($owedPath) -ceq $owedJson) "$mode original owed immutable through release"
    $identity=Get-RebaseObligationIdentity $owed
    $completionPath=Join-Path $runtime "integration-rebase-complete-$identity.json"
    $movementBefore=Movement-Counts $trace
    Proof ($movementBefore.rebase -eq 1 -and $movementBefore.continuation -eq 1 -and $movementBefore.push -eq 2) "$mode native Git command counts: rebase=1 continue=1 push=2 (setup plus result)"
    if ($mode -like 'platform*') {
      if ($mode -ceq 'platform') {
        Proof ($execution.exit -eq 0 -and (Test-Path $completionPath) -and @(Get-ChildItem $runtime -Filter 'integration-owed-ack-v3-*.json').Count -eq 1) '8185 native dispatch Prelaunch/Child/Complete/recheck all progress with same-branch platform owner'
      } else {
        Proof ($execution.exit -ne 0 -and $execution.stderr.Contains('OWED_REBASE_OWNER_UNAUTHORIZED: unique owner') -and -not (Test-Path $completionPath) -and @(Get-ChildItem $runtime -Filter 'integration-owed-ack-v3-*.json').Count -eq 0) "8185 per-site $mode mutant KILLED native completion refused owed retained"
      }
      continue
    }
    if($mode -eq 'foreign-release') {
      $records=@(Get-ChildItem -LiteralPath $runtime -Filter 'dispatch-launch-*.json' -File)
      $foreign=if($records.Count -eq 1){Get-Content -Raw $records[0].FullName|ConvertFrom-Json -DateKind String}else{$null}
      Proof ($execution.exit -ne 0 -and $foreign.childPid -eq 2147483000 -and -not(Test-Path $completionPath) -and @(Get-ChildItem $runtime -Filter 'integration-owed-ack-v3-*.json').Count -eq 0) 'actual release refuses changed child identity and preserves the foreign owner record'
      continue
    }
    if($mode -eq 'skip-release') {
      Proof ($execution.exit -eq 0 -and -not(Test-Path $completionPath) -and @(Get-ChildItem $runtime -Filter 'integration-owed-ack-v3-*.json').Count -eq 0 -and $result.remote -ceq $result.head) 'candidate versus skip-release-capture bypass: actual published child result has no completion or ack without release hook'
      continue
    }
    $fixture=Join-Path $case 'census.json'
    Write-SyntheticFixture $fixture ([pscustomobject]@{path=$repo;branch=$branch;target=$original;base=$base}) $landedPr $landed $pr $result.head 'conflict.txt' -AuthorityHistory $history
    $producerArgs=@('-LandedPr',[string]$landedPr,'-LandedHead',$landed,'-RuntimeRoot',$runtime,'-ContainerRoot',$case,'-HistoryPath',$history,'-Repository',$SyntheticIntegrationRepository,'-FixturePath',$fixture)
    if($mode -eq 'legacy') {
      Proof ($execution.exit -ne 0 -and $execution.stderr.Contains('OWED_INTEGRATION_TARGET_HEAD_NOT_ANCESTOR') -and -not(Test-Path $completionPath)) 'legacy immutable baseline reproduces original release failure'
      Add-8185PlatformSibling $case $runtime $repo $branch
      $producer=Join-Path $runtime 'landed-integration-dispatch.ps1'
      $watchdogPath=Join-Path $runtime "watchdog-lane-$label.json";$watchdog=Get-Content -Raw $watchdogPath|ConvertFrom-Json -DateKind String
      $routing=@(Get-Content $history|ForEach-Object{$_|ConvertFrom-Json -DateKind String}|Where-Object{$_.dispatchRoutingSchema -ceq 'watchdog-dispatch-routing/v1'})[0]
      $acceptPath=Join-Path $runtime "integration-owed-accept-$identity-$($watchdog.launchId).json"
      $references=@()
      foreach($path in @($watchdogPath,$history,$acceptPath,$prompt,(Join-Path $runtime "$label.jsonl"))) {
        $hash=Get-RebaseHash ([IO.File]::ReadAllBytes($path))
        $recordIdentity=if($path -ceq $watchdogPath){Get-RebaseRecordIdentity $watchdog}elseif($path -ceq $history){Get-RebaseRecordIdentity $routing}elseif($path -ceq $acceptPath){Get-RebaseRecordIdentity (Get-Content -Raw $path|ConvertFrom-Json -DateKind String)}else{$hash}
        $references+=[ordered]@{path=$path;sha256=$hash;recordIdentity=$recordIdentity}
      }
      $recovery=[ordered]@{obligationIdentity=$identity;executionLaunchId=$watchdog.launchId;resultHead=$result.head;resultTree=$result.tree;evidence=$references}
      $recoveryPath=Join-Path $case 'recovery-input.json';[IO.File]::WriteAllText($recoveryPath,($recovery|ConvertTo-Json -Compress -Depth 8))
      $refused=Run-Process $producer $producerArgs (Join-Path $case 'missing-proof')
      Proof ($refused.exit -ne 0 -and (Test-Path $owedPath) -and -not(Test-Path $completionPath)) 'legacy missing adoption proof preserves pending'
      $producerArgs+=@('-RecoverCompletedRebasePath',$recoveryPath)
      $reportPath=Join-Path $runtime 'synthetic-author-report.json'
      $historicalOwner=[ordered]@{launchId=$watchdog.launchId;recordPath=$watchdog.ownershipRecordPath;launcherPid=$watchdog.launcherPid;launcherStartIdentity=$watchdog.launcherStartIdentity;childPid=$watchdog.childPid;childStartIdentity=$watchdog.childStartIdentity;laneRole=$watchdog.laneRole;identityMode='branch';branch=$watchdog.branch;worktree=$watchdog.worktree;head=$watchdog.head}
      [IO.File]::WriteAllText($reportPath,([ordered]@{owner=$historicalOwner;finishedBy=$watchdog.updatedAt}|ConvertTo-Json -Compress -Depth 8))
      $reportHash=Get-RebaseHash ([IO.File]::ReadAllBytes($reportPath));$reportRecovery=[ordered]@{obligationIdentity=$identity;executionLaunchId=$watchdog.launchId;resultHead=$result.head;resultTree=$result.tree;evidence=@([ordered]@{path=$reportPath;sha256=$reportHash;recordIdentity=$reportHash})}
      $validRecoveryBytes=[IO.File]::ReadAllBytes($recoveryPath);[IO.File]::WriteAllText($recoveryPath,($reportRecovery|ConvertTo-Json -Compress -Depth 8))
      $reportCandidate=Run-Process $producer $producerArgs (Join-Path $case 'report-authority-candidate')
      Proof ($reportCandidate.exit -ne 0 -and -not(Test-Path $completionPath) -and (Test-Path $owedPath)) 'author report with actual synthetic execution fields is not completion authority'
      $reportSubject=Join-Path $case 'report-is-authority';New-Item -ItemType Directory -Path $reportSubject|Out-Null
      foreach($name in @('integration-dispatch-contract.ps1','dispatch-ownership.ps1','fleet-exclusive-admission.psm1','review-head-contract.psm1','landed-integration-dispatch.ps1','landed-integration-consume.ps1','log-event.ps1','orchestration-log-lock.psm1','routing-data.ps1')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $reportSubject}
      Copy-Item -LiteralPath $producer -Destination (Join-Path $reportSubject 'landed-integration-dispatch.ps1') -Force
      $moduleText=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'landed-integration-evidence.psm1'))
      $recoveryGuard='function Get-RebaseRecoveryEvidence($References,$Obligation,[string]$Runtime,[string]$Launch,[string]$Result,[string]$Tree,[switch]$Retained) {'
      Assert-True ($moduleText.Contains($recoveryGuard)) 'report authority bypass carrier'
      [IO.File]::WriteAllText((Join-Path $reportSubject 'landed-integration-evidence.psm1'),$moduleText.Replace($recoveryGuard,"$recoveryGuard`n  if (@(`$References).Count -eq 1) { return Read-RebaseJson `$References[0].path } <# report-is-authority bypass #>"))
      $historyBytes=[IO.File]::ReadAllBytes($history)
      $reportBypass=Run-Process (Join-Path $reportSubject 'landed-integration-dispatch.ps1') $producerArgs (Join-Path $case 'report-authority-bypass')
      Proof ($reportBypass.exit -eq 0 -and (Test-Path $completionPath) -and -not(Test-Path $owedPath)) 'candidate versus report-is-authority bypass discriminates author report shortcut'
      [IO.File]::WriteAllBytes($history,$historyBytes);[IO.File]::WriteAllText($owedPath,$owedJson);[IO.File]::WriteAllBytes($recoveryPath,$validRecoveryBytes)
      Remove-Item -LiteralPath $completionPath
      Get-ChildItem $runtime -Filter 'integration-owed-ack-v3-*.json' | Remove-Item -Force
      $authModule = Join-Path $runtime 'landed-integration-evidence.psm1'
      $authSource = [IO.File]::ReadAllText($authModule)
      foreach ($call in @('$owner=Get-RebaseAuthenticatedOwner $Obligation $Runtime $RecordPath Prelaunch -ProductCensus','[void](Get-RebaseAuthenticatedOwner $Obligation $Runtime $RecordPath Prelaunch -ProductCensus)')) {
        Proof ([regex]::Matches($authSource,[regex]::Escape($call)).Count -eq 1) '8185 adoption single call-site carrier'
        [IO.File]::WriteAllText($authModule,$authSource.Replace($call,$call.Replace(' -ProductCensus','')))
        $beforeHistory = [IO.File]::ReadAllText($history)
        $refusedAuth=Run-Process $producer $producerArgs (Join-Path $case ('adoption-site-' + [guid]::NewGuid().ToString('N')))
        Proof ($refusedAuth.exit -ne 0 -and $refusedAuth.stderr.Contains('OWED_REBASE_OWNER_UNAUTHORIZED: unique owner') -and (Test-Path $owedPath) -and -not (Test-Path $completionPath) -and [IO.File]::ReadAllText($history) -ceq $beforeHistory) "8185 adoption per-site mutant KILLED: $call"
        [IO.File]::WriteAllText($authModule,$authSource)
      }
      $adoption=Run-Process $producer $producerArgs (Join-Path $case 'adoption')
      if($adoption.exit -ne 0){throw "adoption failed: $($adoption.stderr) $($adoption.stdout)"}
      $c=Get-Content -Raw $completionPath|ConvertFrom-Json -DateKind String
      Proof ($c.mode -ceq 'PRODUCER_ADOPTION' -and $c.executionOwner.launchId -ceq $watchdog.launchId -and $c.acknowledgingOwner.launchId -cne $watchdog.launchId -and [datetimeoffset]$c.completedAt -gt [datetimeoffset]$watchdog.updatedAt -and $null -eq $c.startIdentity) 'legacy fresh distinct producer adoption without invented start'
      # Restore only the original exact owed residue to exercise crash replay.
      [IO.File]::WriteAllText($owedPath,$owedJson)
      $recoveredAck=Run-Process $consumer @('-Branch',$branch,'-Worktree',$repo,'-RuntimeRoot',$runtime,'-HistoryPath',$history) (Join-Path $case 'legacy-completion-replay')
      Proof ($recoveredAck.exit -eq 0) 'legacy retained completion recreates acknowledgement for crash replay'
    } else {
      if($execution.exit -ne 0){throw "prospective release failed: $($execution.stderr)"}
      $c=Get-Content -Raw $completionPath|ConvertFrom-Json -DateKind String
      Proof ($c.mode -ceq 'OWNER_RELEASE' -and $c.predecessorHead -ceq $original -and $c.resultTree -ceq $result.tree) "$mode actual launcher completes native child rebase"
      $starts=@(Get-ChildItem $runtime -Filter "integration-rebase-start-$identity-*.json");$conflicts=@(Get-ChildItem $runtime -Filter "integration-rebase-conflict-$identity-*.json")
      $s=Get-Content -Raw $starts[0].FullName|ConvertFrom-Json -DateKind String;$conflict=Get-Content -Raw $conflicts[0].FullName|ConvertFrom-Json -DateKind String
      $beforeText=[IO.File]::ReadAllText((Join-Path $runtime "integration-rebase-bytes-$($s.branchReflogBefore.sha256).bin"))
      Proof ($starts.Count -eq 1 -and $conflicts.Count -eq 1 -and $s.predecessorHead -ceq $original -and $s.oldBase -ceq $oldBase -and $conflict.origHead -ceq $original -and $conflict.onto -ceq $base -and -not $beforeText.Contains($result.head) -and [datetimeoffset]$s.startedAt -le [datetimeoffset]$conflict.capturedAt) "$mode native original/onto and immutable before-log prove capture before movement"
    }
    $nativeBefore=[IO.File]::ReadAllBytes((Native $repo @('rev-parse','--path-format=absolute','--git-path',"logs/refs/heads/$branch")))
    $ackPath=@(Get-ChildItem $runtime -Filter 'integration-owed-ack-v3-*.json')[0].FullName
    $completionBytes=[IO.File]::ReadAllBytes($completionPath);$ackBytes=[IO.File]::ReadAllBytes($ackPath)
    $consumerReplay=Run-Process $consumer @('-Branch',$branch,'-Worktree',$repo,'-RuntimeRoot',$runtime,'-HistoryPath',$history) (Join-Path $case 'consumer-exact')
    Proof ($consumerReplay.exit -eq 0 -and $consumerReplay.stdout.Contains('ACKNOWLEDGED_REPLAY')) "$mode consumer exact v3 replay"
    if ($mode -eq 'prospective') {
      $failedLogger=Join-Path $case 'failed-append.ps1';[IO.File]::WriteAllText($failedLogger,"throw 'SYNTHETIC_7926_APPEND_FAILURE'")
      $failed=Run-Process $producer ($producerArgs+@('-LogScript',$failedLogger)) (Join-Path $case 'append-failure-candidate')
      Proof ($failed.exit -ne 0 -and [IO.File]::ReadAllText($owedPath) -ceq $owedJson -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($ackPath)) -ceq [Convert]::ToBase64String($ackBytes)) 'v3 append failure retains exact owed and acknowledgement'
      $subject=Join-Path $case 'delete-before-terminal';New-Item -ItemType Directory -Path $subject|Out-Null
      foreach($name in @('dispatch-ownership.ps1','fleet-exclusive-admission.psm1','review-head-contract.psm1','landed-integration-evidence.psm1','integration-dispatch-contract.ps1','routing-data.ps1')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $subject}
      $text=[IO.File]::ReadAllText($producer);$guard='    if($alreadySuccessful.Count-eq0){'
      Assert-True ([regex]::Matches($text,[regex]::Escape($guard)).Count -eq 1) 'terminal ordering single mutation carrier'
      $mutant=Join-Path $subject 'landed-integration-dispatch.ps1';[IO.File]::WriteAllText($mutant,$text.Replace($guard,"    Remove-Item -LiteralPath `$owed -Force <# delete-before-terminal bypass #>`n$guard"))
      $bypass=Run-Process $mutant ($producerArgs+@('-LogScript',$failedLogger)) (Join-Path $case 'append-failure-bypass')
      Proof ($bypass.exit -ne 0 -and -not(Test-Path $owedPath)) 'candidate versus delete-before-terminal bypass discriminates append crash'
      [IO.File]::WriteAllText($owedPath,$owedJson)
      Import-Module (Join-Path $PSScriptRoot 'review-head-contract.psm1') -Force -DisableNameChecking
      $review=Reduce-ExactHeadReview -Pr ([int]$pr) -CurrentHead $result.head -History (Read-ExactHeadReviewHistory -Path $history)
      Proof ($review.state -cne 'authorized') 'ack-v3 cannot supply a source PASS to production review reducer'
    }
    $consume=Run-Process $producer $producerArgs (Join-Path $case 'producer-exact')
    Proof ($consume.exit -eq 0 -and -not(Test-Path $owedPath) -and -not(Test-Path $ackPath)) "$mode producer terminal before exact owed and acknowledgement deletion"
    $again=Run-Process $producer $producerArgs (Join-Path $case 'steady')
    $rows=@(Get-Content $history|ForEach-Object{$_|ConvertFrom-Json -DateKind String}|Where-Object{$_.integrationDispatchSchema -cin @('landed-integration-dispatch/v1','landed-integration-dispatch/v2')})
    Proof ($rows[0].integrationDispatchSchema -ceq 'landed-integration-dispatch/v2' -and $rows[0].executionAttribution.model -ceq 'gpt-6-astra' -and $rows[0].executionAttribution.effort -ceq 'high' -and $rows[0].executionAttribution.row -eq 7 -and $rows[0].executionAttribution.launchId -ceq (Read-RebaseCompletion $owed $runtime).executionOwner.launchId) "$mode retains actual native executor attribution"
    Proof ($again.exit -eq 0 -and $rows.Count -eq 1 -and (Get-RebaseHash $nativeBefore) -ceq (Get-RebaseHash ([IO.File]::ReadAllBytes((Native $repo @('rev-parse','--path-format=absolute','--git-path',"logs/refs/heads/$branch")))))) "$mode steady replay zero rebase and one terminal"
    # Recreate the synthetic crash BEFORE terminal, retaining the actual ack bytes.
    $preTerminalHistory=@(Get-Content $history|Where-Object{($_|ConvertFrom-Json -DateKind String).integrationDispatchSchema -cnotin @('landed-integration-dispatch/v1','landed-integration-dispatch/v2')})
    [IO.File]::WriteAllLines($history,[string[]]$preTerminalHistory)
    [IO.File]::WriteAllBytes($ackPath,$ackBytes)
    $ackOnlyConsumer=Run-Process $consumer @('-Branch',$branch,'-Worktree',$repo,'-RuntimeRoot',$runtime,'-HistoryPath',$history) (Join-Path $case 'consumer-ack-only')
    Proof ($ackOnlyConsumer.exit -eq 0 -and $ackOnlyConsumer.stdout.Contains('ACKNOWLEDGED_REPLAY') -and -not(Test-Path $owedPath)) "$mode consumer validates retained acknowledgement without owed residue"
    [IO.File]::WriteAllText((Join-Path $repo 'descendant.txt'),'synthetic descendant');[void](Native $repo @('add','.'));[void](Native $repo @('commit','-qm','synthetic descendant'))
    $descendant=Native $repo @('rev-parse','HEAD');[IO.File]::WriteAllText($owedPath,$owedJson)
    $desc=Run-Process $consumer @('-Branch',$branch,'-Worktree',$repo,'-RuntimeRoot',$runtime,'-HistoryPath',$history) (Join-Path $case 'consumer-descendant')
    $descProducer=Run-Process $producer $producerArgs (Join-Path $case 'producer-descendant')
    Proof ($desc.exit -eq 0 -and $descProducer.exit -eq 0 -and (Native $repo @('rev-parse','HEAD')) -ceq $descendant) "$mode both readers accept Git-proven descendant"
    [IO.File]::WriteAllLines($history,[string[]]$preTerminalHistory)
    [IO.File]::WriteAllBytes($ackPath,$ackBytes)
    [void](Native $repo @('reset','--hard',$original))
    $ackOnlyReset=Run-Process $consumer @('-Branch',$branch,'-Worktree',$repo,'-RuntimeRoot',$runtime,'-HistoryPath',$history) (Join-Path $case 'consumer-ack-only-reset')
    $ackOnlyResetProducer=Run-Process $producer $producerArgs (Join-Path $case 'producer-ack-only-reset')
    Proof ($ackOnlyReset.exit -ne 0 -and $ackOnlyResetProducer.exit -ne 0 -and -not(Test-Path $owedPath)) "$mode both acknowledgement-only readers refuse reset"
    [IO.File]::WriteAllText($owedPath,$owedJson)
    $reset=Run-Process $consumer @('-Branch',$branch,'-Worktree',$repo,'-RuntimeRoot',$runtime,'-HistoryPath',$history) (Join-Path $case 'consumer-reset')
    $resetProducer=Run-Process $producer $producerArgs (Join-Path $case 'producer-reset')
    Proof ($reset.exit -ne 0 -and $resetProducer.exit -ne 0 -and (Test-Path $owedPath)) "$mode both readers refuse reset with residue retained"
    [void](Native $repo @('reset','--hard',$result.head))
    foreach($field in @('resultHead','resultTree','predecessorHead','obligationIdentity')) {
      $bad=[Text.Encoding]::UTF8.GetString($completionBytes)|ConvertFrom-Json -DateKind String
      $bad.$field=if($field -eq 'obligationIdentity'){'f'*64}else{$base}
      [IO.File]::WriteAllText($completionPath,($bad|ConvertTo-Json -Compress -Depth 20))
      $invalid=Run-Process $consumer @('-Branch',$branch,'-Worktree',$repo,'-RuntimeRoot',$runtime,'-HistoryPath',$history) (Join-Path $case "cross-$field")
      Proof ($invalid.exit -ne 0 -and (Test-Path $owedPath)) "$mode cross $field refuses"
    }
    [IO.File]::WriteAllBytes($completionPath,$completionBytes)
    Proof ((Get-RebaseHash ([IO.File]::ReadAllBytes($ackPath))) -ceq (Get-RebaseHash $ackBytes)) "$mode refusal leaves acknowledgement exact bytes"
    if ($mode -eq 'prospective') {
      foreach($field in @('targetHead','newBase','landedHead','landedPr','pr','branch','worktree','integrationLane')) {
        $bad=[Text.Encoding]::UTF8.GetString($completionBytes)|ConvertFrom-Json -DateKind String
        $bad.obligation.$field=switch($field){'landedPr'{[long]992699};'pr'{[long]992698};'branch'{'synthetic/foreign'};'worktree'{Join-Path $case 'foreign'};'integrationLane'{'synthetic-foreign'};default{$oldBase}}
        [IO.File]::WriteAllText($completionPath,($bad|ConvertTo-Json -Compress -Depth 20))
        $invalid=Run-Process $producer $producerArgs (Join-Path $case "cross-obligation-$field")
        Proof ($invalid.exit -ne 0 -and [IO.File]::ReadAllText($owedPath) -ceq $owedJson) "cross obligation $field preserves exact owed"
      }
      foreach($field in @('launchId','launcherPid','launcherStartIdentity','childPid','childStartIdentity','laneRole','identityMode','head')) {
        $bad=[Text.Encoding]::UTF8.GetString($completionBytes)|ConvertFrom-Json -DateKind String
        $bad.executionOwner.$field=switch($field){'launchId'{[guid]::NewGuid().ToString()};'launcherPid'{[long]$PID};'childPid'{[long]$PID};'launcherStartIdentity'{[datetimeoffset]::UtcNow.ToString('o')};'childStartIdentity'{[datetimeoffset]::UtcNow.ToString('o')};'laneRole'{'review'};'identityMode'{'detached'};default{$base}}
        [IO.File]::WriteAllText($completionPath,($bad|ConvertTo-Json -Compress -Depth 20))
        $invalid=Run-Process $consumer @('-Branch',$branch,'-Worktree',$repo,'-RuntimeRoot',$runtime,'-HistoryPath',$history) (Join-Path $case "cross-owner-$field")
        Proof ($invalid.exit -ne 0) "cross execution owner $field refuses"
      }
      [IO.File]::WriteAllBytes($completionPath,$completionBytes)
      $startPath=$starts[0].FullName;$conflictPath=$conflicts[0].FullName
      $startBytes=[IO.File]::ReadAllBytes($startPath);$conflictBytes=[IO.File]::ReadAllBytes($conflictPath)
      [IO.File]::WriteAllBytes((Join-Path $case 'original-start.json'),$startBytes);[IO.File]::WriteAllBytes((Join-Path $case 'original-conflict.json'),$conflictBytes)
      $badStart=[Text.Encoding]::UTF8.GetString($startBytes)|ConvertFrom-Json -DateKind String
      $bad=[Text.Encoding]::UTF8.GetString($completionBytes)|ConvertFrom-Json -DateKind String
      $badStart.startedAt=([datetimeoffset]$bad.completedAt).AddMinutes(1).ToString('o');$bad.startIdentity=Get-RebaseRecordIdentity $badStart
      $badConflict=[Text.Encoding]::UTF8.GetString($conflictBytes)|ConvertFrom-Json -DateKind String;$badConflict.startIdentity=$bad.startIdentity;$badConflict.capturedAt=$badStart.startedAt
      [IO.File]::WriteAllText($startPath,($badStart|ConvertTo-Json -Compress -Depth 20));[IO.File]::WriteAllText($conflictPath,($badConflict|ConvertTo-Json -Compress))
      [IO.File]::WriteAllText($completionPath,($bad|ConvertTo-Json -Compress -Depth 20))
      $badAck=[Text.Encoding]::UTF8.GetString($ackBytes)|ConvertFrom-Json -DateKind String;$badAck.completionIdentity=Get-RebaseRecordIdentity $bad
      [IO.File]::WriteAllText($ackPath,($badAck|ConvertTo-Json -Compress))
      $invalid=Run-Process $consumer @('-Branch',$branch,'-Worktree',$repo,'-RuntimeRoot',$runtime,'-HistoryPath',$history) (Join-Path $case 'finish-before-start')
      Proof ($invalid.exit -ne 0 -and [IO.File]::ReadAllText($owedPath) -ceq $owedJson) 'native finish before start refuses despite recomputed cross-hashes'
      [IO.File]::WriteAllBytes($startPath,$startBytes);[IO.File]::WriteAllBytes($conflictPath,$conflictBytes)
      $bad=[Text.Encoding]::UTF8.GetString($completionBytes)|ConvertFrom-Json -DateKind String;$bad.rebaseProof.branchReflogHash=$s.branchReflogBefore.sha256
      [IO.File]::WriteAllText($completionPath,($bad|ConvertTo-Json -Compress -Depth 20));$badAck.completionIdentity=Get-RebaseRecordIdentity $bad;[IO.File]::WriteAllText($ackPath,($badAck|ConvertTo-Json -Compress))
      $missingTransition=Run-Process $consumer @('-Branch',$branch,'-Worktree',$repo,'-RuntimeRoot',$runtime,'-HistoryPath',$history) (Join-Path $case 'consumer-no-native-transition')
      $missingTransitionProducer=Run-Process $producer $producerArgs (Join-Path $case 'producer-no-native-transition')
      Proof ($missingTransition.exit -ne 0 -and $missingTransitionProducer.exit -ne 0) 'both readers require native branch transition beyond the actual before-log'
      [IO.File]::WriteAllBytes($completionPath,$completionBytes);[IO.File]::WriteAllBytes($ackPath,$ackBytes)
      # Each bypass changes only its named guard. The observed Git repository
      # and the other completion fields stay fixed across the pair.
      $modulePath=Join-Path $PSScriptRoot 'landed-integration-evidence.psm1';$source=[IO.File]::ReadAllText($modulePath)
      $mutantRoot=Join-Path $case 'mutant';New-Item -ItemType Directory -Path $mutantRoot|Out-Null
      Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'dispatch-ownership.ps1'),(Join-Path $PSScriptRoot 'fleet-exclusive-admission.psm1') -Destination $mutantRoot
      $mutantPath=Join-Path $mutantRoot 'landed-integration-evidence.psm1';$check=Join-Path $case 'check-evidence.ps1'
      [IO.File]::WriteAllText($check,@'
param($Module,$Owed,$Runtime,$Ack,$Git='git')
$ErrorActionPreference='Stop'
Import-Module $Module -Force -DisableNameChecking
$o=Get-Content -Raw $Owed|ConvertFrom-Json -DateKind String
$a=Get-Content -Raw $Ack|ConvertFrom-Json -DateKind String
Assert-RebaseAcknowledgement $a $o $Runtime $Git
'@)
      $commonArgs=@('-Owed',$owedPath,'-Runtime',$runtime,'-Ack',$ackPath)
      $resetGuard="[void](Invoke-RebaseEvidenceGit `$Obligation.worktree @('merge-base','--is-ancestor',`$Result,`$head) `$GitExecutable -Empty)"
      Assert-True ($source.Contains($resetGuard)) 'reset guard exact carrier'
      [IO.File]::WriteAllText($mutantPath,$source.Replace($resetGuard,'$null=$true <# accept-reset bypass #>'))
      [void](Native $repo @('reset','--hard',$original))
      $candidate=Run-Process $check (@('-Module',$modulePath)+$commonArgs) (Join-Path $case 'reset-candidate')
      $bypass=Run-Process $check (@('-Module',$mutantPath)+$commonArgs) (Join-Path $case 'reset-bypass')
      Proof ($candidate.exit -ne 0 -and $bypass.exit -eq 0) 'candidate versus accept-reset bypass discriminates actual nonancestor'
      [void](Native $repo @('reset','--hard',$result.head))
      $exitGuard='$code -ne 0 -or ($Empty -and $text)'
      Assert-True ($source.Contains($exitGuard)) 'Git exit guard exact carrier'
      [IO.File]::WriteAllText($mutantPath,$source.Replace($exitGuard,'$Empty -and $text'))
      $gitFailure=Join-Path $case 'nonzero-git.ps1'
      [IO.File]::WriteAllText($gitFailure,"& git @args`n`$code=`$LASTEXITCODE`nif (`$args -contains 'cat-file') { exit 7 }`nexit `$code")
      $candidate=Run-Process $check (@('-Module',$modulePath)+$commonArgs+@('-Git',$gitFailure)) (Join-Path $case 'git-exit-candidate')
      $bypass=Run-Process $check (@('-Module',$mutantPath)+$commonArgs+@('-Git',$gitFailure)) (Join-Path $case 'git-exit-bypass')
      Proof ($candidate.exit -ne 0 -and $bypass.exit -eq 0) 'candidate versus ignore-git-exit bypass discriminates success-looking output'
      $treeGuard="(Invoke-RebaseEvidenceGit `$Obligation.worktree @('rev-parse',`"`$Result^{tree}`") `$GitExecutable) -cne `$Tree -or "
      Assert-True ($source.Contains($treeGuard)) 'result tree guard exact carrier'
      [IO.File]::WriteAllText($mutantPath,$source.Replace($treeGuard,''))
      $bad=[Text.Encoding]::UTF8.GetString($completionBytes)|ConvertFrom-Json -DateKind String;$bad.resultTree=Native $repo @('rev-parse',"$base^{tree}")
      [IO.File]::WriteAllText($completionPath,($bad|ConvertTo-Json -Compress -Depth 20))
      $badAck=[Text.Encoding]::UTF8.GetString($ackBytes)|ConvertFrom-Json -DateKind String;$badAck.completionIdentity=Get-RebaseRecordIdentity $bad
      [IO.File]::WriteAllText($ackPath,($badAck|ConvertTo-Json -Compress))
      $candidate=Run-Process $check (@('-Module',$modulePath)+$commonArgs) (Join-Path $case 'tree-candidate')
      $bypass=Run-Process $check (@('-Module',$mutantPath)+$commonArgs) (Join-Path $case 'tree-bypass')
      Proof ($candidate.exit -ne 0 -and $bypass.exit -eq 0) 'candidate versus base-only-result bypass discriminates independently observed tree'
      [IO.File]::WriteAllBytes($completionPath,$completionBytes);[IO.File]::WriteAllBytes($ackPath,$ackBytes)
      $crossGuard=' -or (Get-RebaseObligationIdentity $c.obligation) -cne $identity'
      Assert-True ($source.Contains($crossGuard)) 'completion obligation cross-binding carrier'
      [IO.File]::WriteAllText($mutantPath,$source.Replace($crossGuard,''))
      $bad=[Text.Encoding]::UTF8.GetString($completionBytes)|ConvertFrom-Json -DateKind String;$bad.obligation.pr=[long]992699
      [IO.File]::WriteAllText($completionPath,($bad|ConvertTo-Json -Compress -Depth 20))
      $badAck=[Text.Encoding]::UTF8.GetString($ackBytes)|ConvertFrom-Json -DateKind String;$badAck.completionIdentity=Get-RebaseRecordIdentity $bad
      [IO.File]::WriteAllText($ackPath,($badAck|ConvertTo-Json -Compress))
      $candidate=Run-Process $check (@('-Module',$modulePath)+$commonArgs) (Join-Path $case 'cross-obligation-candidate')
      $bypass=Run-Process $check (@('-Module',$mutantPath)+$commonArgs) (Join-Path $case 'cross-obligation-bypass')
      Proof ($candidate.exit -ne 0 -and $bypass.exit -eq 0) 'candidate versus cross-obligation bypass discriminates target PR binding'
      [IO.File]::WriteAllBytes($completionPath,$completionBytes);[IO.File]::WriteAllBytes($ackPath,$ackBytes)
      $missingGuard="if (`$null -eq `$c -or `$Ack.completionIdentity -cne (Get-RebaseRecordIdentity `$c) -or `$Ack.predecessorHead -cne `$c.predecessorHead -or `$Ack.resultHead -cne `$c.resultHead -or [datetimeoffset]`$Ack.acknowledgedAt -lt [datetimeoffset]`$c.completedAt) { throw 'OWED_INTEGRATION_ACK_UNKNOWN: completion' }"
      Assert-True ($source.Contains($missingGuard)) 'required completion carrier'
      [IO.File]::WriteAllText($mutantPath,$source.Replace($missingGuard,'$null=$true <# allow-missing-proof bypass #>'))
      Remove-Item -LiteralPath $completionPath
      $candidate=Run-Process $check (@('-Module',$modulePath)+$commonArgs) (Join-Path $case 'missing-proof-candidate')
      $bypass=Run-Process $check (@('-Module',$mutantPath)+$commonArgs) (Join-Path $case 'missing-proof-bypass')
      Proof ($candidate.exit -ne 0 -and $bypass.exit -eq 0) 'candidate versus allow-missing-proof bypass discriminates absent completion'
      [IO.File]::WriteAllBytes($completionPath,$completionBytes)
      $ackSubject=Join-Path $case 'ack-before-proof';New-Item -ItemType Directory -Path $ackSubject|Out-Null
      foreach($name in @('dispatch-ownership.ps1','fleet-exclusive-admission.psm1','review-head-contract.psm1','landed-integration-evidence.psm1','integration-dispatch-contract.ps1','routing-data.ps1')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $ackSubject}
      $consumerText=[IO.File]::ReadAllText($consumer);$ackGuard='    Assert-RebaseAcknowledgement $ack $obligation $runtime $GitExecutable'
      Assert-True ([regex]::Matches($consumerText,[regex]::Escape($ackGuard)).Count -eq 1) 'ack proof ordering mutation carrier'
      $ackMutant=Join-Path $ackSubject 'landed-integration-consume.ps1';[IO.File]::WriteAllText($ackMutant,$consumerText.Replace($ackGuard,"    Write-RebaseRecord `$v3Path `$ack <# ack-before-proof bypass #>`n$ackGuard"))
      $counter=Join-Path $case 'git-observation-count.txt';$env:SYNTHETIC_7926_GIT_COUNT=$counter
      $changingGit=Join-Path $case 'changing-git-observation.ps1'
      [IO.File]::WriteAllText($changingGit,@'
& git @args
$code=$LASTEXITCODE
if ($args -contains 'cat-file') {
  $count=[int][IO.File]::ReadAllText($env:SYNTHETIC_7926_GIT_COUNT)+1
  [IO.File]::WriteAllText($env:SYNTHETIC_7926_GIT_COUNT,[string]$count)
  if ($count -ge 9) { exit 7 }
}
exit $code
'@)
      Remove-Item -LiteralPath $ackPath
      [IO.File]::WriteAllText($counter,'0')
      $candidate=Run-Process $consumer @('-Branch',$branch,'-Worktree',$repo,'-RuntimeRoot',$runtime,'-HistoryPath',$history,'-GitExecutable',$changingGit) (Join-Path $case 'ack-order-candidate')
      $candidateRetained=$candidate.exit -ne 0 -and -not(Test-Path $ackPath)
      [IO.File]::WriteAllText($counter,'0')
      $bypass=Run-Process $ackMutant @('-Branch',$branch,'-Worktree',$repo,'-RuntimeRoot',$runtime,'-HistoryPath',$history,'-GitExecutable',$changingGit) (Join-Path $case 'ack-order-bypass')
      Proof ($candidateRetained -and $bypass.exit -ne 0 -and (Test-Path $ackPath)) 'candidate versus ack-before-proof bypass discriminates changed Git observation before ack write'
      [IO.File]::WriteAllBytes($ackPath,$ackBytes)
      Remove-Item Env:SYNTHETIC_7926_GIT_COUNT -ErrorAction SilentlyContinue
      $extra=[Text.Encoding]::UTF8.GetString($completionBytes).Replace('"publication":{','"publication":{"foreign":true,')
      [IO.File]::WriteAllText($completionPath,$extra)
      $invalid=Run-Process $check (@('-Module',$modulePath)+$commonArgs) (Join-Path $case 'nested-extra')
      Proof ($invalid.exit -ne 0) 'recursive extra keys refuse'
      $duplicate=[Text.Encoding]::UTF8.GetString($completionBytes).Replace('"publication":{','"publication":{"branch":"synthetic/duplicate",')
      [IO.File]::WriteAllText($completionPath,$duplicate)
      $invalid=Run-Process $check (@('-Module',$modulePath)+$commonArgs) (Join-Path $case 'nested-duplicate')
      Proof ($invalid.exit -ne 0) 'recursive duplicate keys refuse'
      [IO.File]::WriteAllBytes($completionPath,$completionBytes)
      $v2Path=$ackPath.Replace('ack-v3-','ack-v2-');[IO.File]::WriteAllBytes($v2Path,$ackBytes)
      $invalid=Run-Process $producer $producerArgs (Join-Path $case 'conflicting-versions')
      Proof ($invalid.exit -ne 0 -and (Test-Path $v2Path) -and (Test-Path $ackPath)) 'conflicting acknowledgement versions refuse without cleanup'
      Remove-Item -LiteralPath $v2Path
      $owner=Write-SyntheticOwner $runtime ([pscustomobject]@{path=$repo;branch=$branch;target=$result.head}) 'synthetic-auth-owner'
      $authCheck=Join-Path $case 'check-actual-owner.ps1'
      [IO.File]::WriteAllText($authCheck,@'
param($Module,$Owed,$Runtime,$Owner)
$ErrorActionPreference='Stop'
Import-Module $Module -Force -DisableNameChecking
$o=Get-Content -Raw $Owed|ConvertFrom-Json -DateKind String
[void](Get-RebaseAuthenticatedOwner $o $Runtime $Owner Prelaunch)
'@)
      $authArgs=@('-Owed',$owedPath,'-Runtime',$runtime,'-Owner',$owner.recordPath)
      $actualGuard='$PID -ne $owner.launcherPid -or (Get-DispatchProcessStartIdentity $PID) -cne $owner.launcherStartIdentity'
      Assert-True ($source.Contains($actualGuard)) 'actual process guard carrier'
      [IO.File]::WriteAllText($mutantPath,$source.Replace($actualGuard,'$false <# borrow-owner bypass #>'))
      $candidate=Run-Process $authCheck (@('-Module',$modulePath)+$authArgs) (Join-Path $case 'borrow-owner-candidate')
      $bypass=Run-Process $authCheck (@('-Module',$mutantPath)+$authArgs) (Join-Path $case 'borrow-owner-bypass')
      Proof ($candidate.exit -ne 0 -and $candidate.stderr.Contains('actual launcher') -and $bypass.exit -eq 0) 'actual subprocess cannot borrow live parent owner; single-guard bypass can'
      $ownerOriginal=[IO.File]::ReadAllBytes($owner.recordPath)
      foreach($badKind in @('wrong-start','wrong-launch','dead','reused','review','planning','observer')) {
        $value=[Text.Encoding]::UTF8.GetString($ownerOriginal)|ConvertFrom-Json -DateKind String
        switch($badKind) {
          'wrong-start' {$value.launcherStartIdentity=[datetimeoffset]::UtcNow.AddDays(-1).ToString('o')}
          'wrong-launch' {$value.launchId=[guid]::NewGuid().ToString()}
          'dead' {$value.launcherPid=[long]2147483000}
          'reused' {$value.launcherStartIdentity=[datetimeoffset]::UtcNow.ToString('o')}
          default {$value.laneRole=$badKind;if($badKind -in @('review','planning')){$value.reviewIsolationRoot=Join-Path ([IO.Path]::GetTempPath()) "chase-sets-$badKind-$($value.launchId)"}}
        }
        [IO.File]::WriteAllText($owner.recordPath,($value|ConvertTo-Json -Compress))
        $invalid=Run-Process $authCheck (@('-Module',$modulePath)+$authArgs) (Join-Path $case "actual-$badKind")
        Proof ($invalid.exit -ne 0) "actual process $badKind owner refuses"
      }
      [IO.File]::WriteAllBytes($owner.recordPath,$ownerOriginal)
      $duplicateOwner=Write-SyntheticOwner $runtime ([pscustomobject]@{path=$repo;branch=$branch;target=$result.head}) 'synthetic-duplicate-owner'
      $invalid=Run-Process $authCheck (@('-Module',$modulePath)+$authArgs) (Join-Path $case 'actual-duplicate')
      Proof ($invalid.exit -ne 0) 'actual duplicate live branch owners refuse'
      Remove-Item -LiteralPath $owner.recordPath,$owner.promptPath,$duplicateOwner.recordPath,$duplicateOwner.promptPath
    }
    $movementAfter=Movement-Counts $trace
    Proof ((Get-RebaseRecordIdentity $movementAfter) -ceq (Get-RebaseRecordIdentity $movementBefore)) "$mode replay/adoption native command delta: rebase=0 continue=0 push=0"
  }
  Remove-Item Env:SYNTHETIC_7926_CONFIG -ErrorAction SilentlyContinue
  Remove-Item Env:GIT_TRACE2_EVENT -ErrorAction SilentlyContinue
  Write-Output "EVIDENCE 7926 production lifecycle proofs=$script:rebaseProofCount synthetic=true baseline=177f2d55176d122b267444c3de240927f98285ff"
}
