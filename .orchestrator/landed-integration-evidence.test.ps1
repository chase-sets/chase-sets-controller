# #128 equivalence and work-removal controls for the interrupted-resume
# internals Get-InterruptedIntegrationState and Assert-InterruptedIntegrationReplay.
# Base is the installed controller-v2.133 module; candidate is this checkout.
# Every case drives both with the same native input and requires the same
# return value or throw message. One mutant per cut must differ from base, and
# a comparison mutant shows what the one normalized case still catches.
# Native Git processes are counted from GIT_TRACE2_EVENT per call; timing is
# reported only and never gates.
param([string]$BaselineHead='a992290ef1f6cfd528af84ee01cd109eb25697bf')
$ErrorActionPreference='Stop'
function Assert-True($Condition,[string]$Message){if(-not$Condition){throw "ASSERTION FAILED: $Message"}}
$root=Join-Path ([IO.Path]::GetTempPath()) ('landed-evidence-128-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
$imported=@()
try {
  function Fx([string]$Repo,[string[]]$Arguments,[switch]$AllowFailure) {
    $output=@(& git -C $Repo @Arguments 2>&1);$code=$LASTEXITCODE
    if($code-ne0-and-not$AllowFailure){throw "fixture git $($Arguments -join ' ') exit=$code $($output -join "`n")"}
    return ($output -join "`n").Trim()
  }
  # Base arm: the exact installed module bytes, imported under a distinct name.
  $baseRoot=Join-Path $root 'base';$archive=Join-Path $root 'base.zip'
  [void](Fx (Split-Path -Parent $PSScriptRoot) @('archive','--format=zip','-o',$archive,$BaselineHead,'.orchestrator'))
  [IO.Compression.ZipFile]::ExtractToDirectory($archive,$baseRoot)
  $baseDir=Join-Path $baseRoot '.orchestrator'
  Copy-Item -LiteralPath (Join-Path $baseDir 'landed-integration-evidence.psm1') -Destination (Join-Path $baseDir 'landed-integration-evidence-base128.psm1')
  $candidateSource=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'landed-integration-evidence.psm1'))
  $nl=if($candidateSource.Contains("`r`n")){"`r`n"}else{"`n"}
  $candidateCopy=Join-Path $root 'candidate';[IO.Directory]::CreateDirectory($candidateCopy)|Out-Null
  foreach($name in @('dispatch-ownership.ps1','integration-dispatch-contract.ps1','routing-data.ps1')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $candidateCopy}
  function New-Arm([string]$Name,[string]$Path){ $module=Import-Module $Path -Force -DisableNameChecking -PassThru; $script:imported+=$module; [pscustomobject]@{name=$Name;module=$module} }
  function New-Mutant([string]$Name,[string]$Old,[string]$New) {
    Assert-True (([regex]::Matches($candidateSource,[regex]::Escape($Old))).Count-eq1) "mutant $Name anchor must occur exactly once"
    $path=Join-Path $candidateCopy "landed-integration-evidence-$Name.psm1"
    [IO.File]::WriteAllText($path,$candidateSource.Replace($Old,$New),[Text.UTF8Encoding]::new($false))
    New-Arm "mutant-$Name" $path
  }
  $base=New-Arm 'base' (Join-Path $baseDir 'landed-integration-evidence-base128.psm1')
  $candidate=New-Arm 'candidate' (Join-Path $PSScriptRoot 'landed-integration-evidence.psm1')
  Assert-True ((Get-FileHash -LiteralPath (Join-Path $baseDir 'landed-integration-evidence.psm1')).Hash-ne(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'landed-integration-evidence.psm1')).Hash) 'base and candidate module bytes differ'
  # Cut 1 (one --git-path read) and cut 2 (one pick rev-parse).
  $pathMutant=New-Mutant 'git-path-map' 'if ($null -ne $gitPaths) { $gitPaths[$other] }' 'if ($null -ne $gitPaths) { $gitPaths[''sequencer''] }'
  $pickMutant=New-Mutant 'pick-order' '  return ,$commits' '  return ,@($commits[($commits.Count-1)..0])'
  # The scratch replay identity: a different email changes the second-pick stop.
  $identityMutant=New-Mutant 'scratch-identity' "@('config','user.email','integration-proof@example.invalid')" "@('config','user.email','other-proof@example.invalid')"
  # The dropped cut 3 (clone -c): it appends to a clone template's identity
  # where the restored clone + git config replaces it.
  $cloneConfigMutant=New-Mutant 'clone-config' ("    [void](Get-InterruptedIntegrationGitBytes `$source @('clone','--shared','--no-checkout','--',`$source,`$temporary))"+$nl+"    [void](Get-InterruptedIntegrationGitBytes `$temporary @('config','user.name','Interrupted integration scratch proof'))"+$nl+"    [void](Get-InterruptedIntegrationGitBytes `$temporary @('config','user.email','integration-proof@example.invalid'))"+$nl) ("    [void](Get-InterruptedIntegrationGitBytes `$source @('clone','--shared','--no-checkout','-c','user.name=Interrupted integration scratch proof','-c','user.email=integration-proof@example.invalid','--',`$source,`$temporary))"+$nl)
  # Comparison control: reverses the captured output lines of every failed git
  # call that Invoke-RebaseEvidenceGit turns into a refusal.
  $orderMutant=New-Mutant 'refusal-order' '  $text = ($output -join "`n").Trim()' '  $text = $(if ($code -ne 0) { (@($output[($output.Count-1)..0]) -join "`n").Trim() } else { ($output -join "`n").Trim() })'

  $traceIndex=0
  function Invoke-Arm($Arm,[scriptblock]$Body,[object[]]$Arguments) {
    $script:traceIndex++
    $trace=Join-Path $root "trace-$($script:traceIndex)";[IO.Directory]::CreateDirectory($trace)|Out-Null
    $env:GIT_TRACE2_EVENT=$trace
    $clock=[Diagnostics.Stopwatch]::StartNew()
    try { $value=@(& $Arm.module $Body @Arguments); $outcome='RETURN '+(ConvertTo-Json -InputObject $value -Compress -Depth 10) }
    catch { $outcome='THROW '+$_.Exception.Message }
    finally { $clock.Stop(); Remove-Item Env:GIT_TRACE2_EVENT -ErrorAction SilentlyContinue }
    $processes=0
    foreach($file in @(Get-ChildItem -LiteralPath $trace -File)){
      $first=[IO.File]::ReadLines($file.FullName)|Select-Object -First 1
      if(-not(($first|ConvertFrom-Json).sid.Contains('/'))){$processes++}
    }
    [pscustomobject]@{outcome=($outcome -replace 'integration-resume-proof-[a-f0-9]{32}','integration-resume-proof-<scratch>');processes=$processes;ms=$clock.Elapsed.TotalMilliseconds}
  }
  # Invoke-RebaseEvidenceGit merges native stdout and stderr (2>&1). For an
  # unresolvable pick, rev-parse echoes the revision on stdout and refuses on
  # stderr, and the echo lands at a varying place among the stderr lines between
  # runs of the same base code. Only for that case, and only that one echo line,
  # is moved to a fixed place; the stderr lines keep their order and every other
  # outcome is compared exactly.
  function Get-CaseOutcome([string]$Outcome,[string]$PickRevision) {
    if(-not$PickRevision){return $Outcome}
    $prefix='THROW OWED_REBASE_PROOF_INVALID: git rev-parse exit=128 output='
    if(-not$Outcome.StartsWith($prefix,[StringComparison]::Ordinal)){return 'UNNORMALIZED '+$Outcome}
    $lines=@($Outcome.Substring($prefix.Length) -split "`n")
    if(@($lines|Where-Object{$_ -ceq $PickRevision}).Count-ne1){return 'UNNORMALIZED '+$Outcome}
    return $prefix+"[stdout]$PickRevision[stderr]"+(@($lines|Where-Object{$_ -cne $PickRevision}) -join "`n")
  }
  # The prior normalization (every git refusal as a sorted line set), kept only
  # to show that it would have hidden the refusal-order mutant.
  function Get-PriorSortedOutcome([string]$Outcome) {
    if($Outcome -cmatch '(?s)^(THROW OWED_REBASE_PROOF_INVALID: git \S+ exit=\d+ output=)(.*)$'){return $Matches[1]+((@($Matches[2] -split "`n")|Sort-Object -CaseSensitive) -join "`n")}
    return $Outcome
  }
  $stateBody={param($w) Get-InterruptedIntegrationState $w}
  $replayBody={param($o,$s) Assert-InterruptedIntegrationReplay $o $s}

  # A canonical native first stop: conflict on the first pick unless -StopAtSecond.
  function New-Stop([string]$Name,[int]$Commits=2,[switch]$Linked,[switch]$StopAtSecond,[switch]$ApplyBackend) {
    $repo=Join-Path $root "$Name-repo";[IO.Directory]::CreateDirectory($repo)|Out-Null
    foreach($a in @(@('init','-q','--initial-branch=main'),@('config','user.name','Synthetic 128'),@('config','user.email','synthetic-128@example.invalid'),@('config','commit.gpgsign','false'))){[void](Fx $repo $a)}
    [IO.File]::WriteAllText((Join-Path $repo 'conflict.txt'),"synthetic base`n");[void](Fx $repo @('add','.'));[void](Fx $repo @('commit','-qm','synthetic base'))
    $baseCommit=Fx $repo @('rev-parse','HEAD')
    [void](Fx $repo @('branch','synthetic/128'))
    [IO.File]::WriteAllText((Join-Path $repo 'conflict.txt'),"synthetic landed`n");[void](Fx $repo @('commit','-qam','synthetic landed'))
    $newBase=Fx $repo @('rev-parse','HEAD')
    $work=$repo
    if($Linked){$work=Join-Path $root "$Name-linked";[void](Fx $repo @('worktree','add','-q',$work,'synthetic/128'))}else{[void](Fx $repo @('checkout','-q','synthetic/128'))}
    for($i=1;$i-le$Commits;$i++){
      $conflicts=if($StopAtSecond){$i-eq2}else{$i-eq1}
      if($conflicts){[IO.File]::WriteAllText((Join-Path $work 'conflict.txt'),"synthetic feature`n")}else{[IO.File]::WriteAllText((Join-Path $work "pending-$i.txt"),"synthetic pending $i`n")}
      [void](Fx $work @('add','.'));[void](Fx $work @('commit','-qm',"synthetic feature $i"))
    }
    $targetHead=Fx $work @('rev-parse','HEAD')
    # The stop is made with the scratch replay's own identity and flags so a
    # second-pick stop is reproducible under a fixed committer date.
    $rebase=@('-c','user.name=Interrupted integration scratch proof','-c','user.email=integration-proof@example.invalid','-c','core.hooksPath=NUL','-c','rerere.enabled=false','rebase')
    if($ApplyBackend){$rebase+='--apply'}
    [void](Fx $work ($rebase+@('--onto',$newBase,$baseCommit)) -AllowFailure)
    Assert-True ((Fx $work @('ls-files','--unmerged')) -ne '') "$Name fixture stopped on a native conflict"
    [pscustomobject]@{name=$Name;work=$work;rebase=(Fx $work @('rev-parse','--path-format=absolute','--git-path','rebase-merge'));obligation=[pscustomobject]@{worktree=$work;branch='synthetic/128';targetHead=$targetHead;newBase=$newBase};baseCommit=$baseCommit;picks=$Commits}
  }
  $env:GIT_COMMITTER_DATE='2026-10-01T00:00:00Z'
  $main=New-Stop 'main'
  $linked=New-Stop 'linked' -Linked
  $ten=New-Stop 'ten' 10
  $second=New-Stop 'second' 3 -StopAtSecond
  # Paths with spaces and non-ASCII characters, for a main and a linked worktree.
  $wide=New-Stop "wide $([char]0xE9) $([char]0x540D)"
  $wideLinked=New-Stop "wide linked $([char]0xFC) $([char]0x540D)" -Linked
  # A real apply-backend stop, and a real am session (rebase-apply) left on top
  # of a merge-backend stop.
  $applyStop=New-Stop 'apply-backend' -ApplyBackend
  Assert-True (Test-Path -LiteralPath (Fx $applyStop.work @('rev-parse','--path-format=absolute','--git-path','rebase-apply/rebasing')) -PathType Leaf) 'apply-backend fixture is a real rebase-apply stop'
  $am=New-Stop 'am-session'
  $patch=Join-Path $root 'am-session.patch'
  [IO.File]::WriteAllText($patch,(Fx $am.work @('format-patch','-1','--stdout',$am.obligation.newBase))+"`n")
  [void](Fx $am.work @('am',$patch) -AllowFailure)
  Assert-True (Test-Path -LiteralPath (Fx $am.work @('rev-parse','--path-format=absolute','--git-path','rebase-apply/applying')) -PathType Leaf) 'am-session fixture left a real active rebase-apply state'
  Assert-True (Test-Path -LiteralPath $am.rebase -PathType Container) 'am-session fixture kept its merge-backend stop'
  $plain=Join-Path $root 'plain';[IO.Directory]::CreateDirectory($plain)|Out-Null
  foreach($a in @(@('init','-q','--initial-branch=main'),@('config','user.name','Synthetic 128'),@('config','user.email','synthetic-128@example.invalid'),@('config','commit.gpgsign','false'))){[void](Fx $plain $a)}
  [IO.File]::WriteAllText((Join-Path $plain 'a.txt'),"synthetic`n");[void](Fx $plain @('add','.'));[void](Fx $plain @('commit','-qm','synthetic'))
  $detached=Join-Path $root 'detached';[void](Fx $plain @('worktree','add','-q','--detach',$detached,'HEAD'))
  $notRepo=Join-Path $root 'not-a-repo';[IO.Directory]::CreateDirectory($notRepo)|Out-Null
  $unborn=Join-Path $root 'unborn';[IO.Directory]::CreateDirectory($unborn)|Out-Null;[void](Fx $unborn @('init','-q','--initial-branch=main'))
  [void](& git -C $unborn rev-parse --verify -q HEAD 2>$null);Assert-True ($LASTEXITCODE -ne 0) 'unborn fixture has an unborn HEAD'

  $results=[Collections.Generic.List[object]]::new()
  $mutantRuns=[Collections.Generic.List[object]]::new()
  $lastBase=$null
  function Compare-Case([string]$Kind,[string]$Case,[scriptblock]$Body,[object[]]$Arguments,[object[]]$Mutants,[int]$ExpectedSaving=-1,[string]$PickRevision) {
    $b=Invoke-Arm $base $Body $Arguments
    $c=Invoke-Arm $candidate $Body $Arguments
    $bo=Get-CaseOutcome $b.outcome $PickRevision;$co=Get-CaseOutcome $c.outcome $PickRevision
    if($PickRevision){Assert-True (-not$bo.StartsWith('UNNORMALIZED')) "$Kind $Case base outcome is the unresolvable-pick refusal: $($b.outcome)"}
    Assert-True ($bo-ceq$co) "$Kind $Case candidate output equals base`n base: $bo`n cand: $co"
    if($ExpectedSaving-ge0){Assert-True (($b.processes-$c.processes)-eq$ExpectedSaving) "$Kind $Case native Git processes fall by exactly $ExpectedSaving (base=$($b.processes) candidate=$($c.processes))"}
    $row=[ordered]@{kind=$Kind;case=$Case;outcome=$bo;baseProcesses=$b.processes;candidateProcesses=$c.processes;baseMs=[Math]::Round($b.ms,1);candidateMs=[Math]::Round($c.ms,1)}
    foreach($m in @($Mutants|Where-Object{$null-ne$_})){
      $mo=(Invoke-Arm $m $Body $Arguments).outcome
      $equal=((Get-CaseOutcome $mo $PickRevision)-ceq$bo)
      $row[$m.name]=$equal
      $script:mutantRuns.Add([pscustomobject]@{mutant=$m.name;case="$Kind/$Case";equal=$equal;priorEqual=((Get-PriorSortedOutcome $mo)-ceq(Get-PriorSortedOutcome $b.outcome))})
    }
    $script:results.Add([pscustomobject]$row)
    $script:lastBase=$bo
    $short=if($bo.Length-gt150){$bo.Substring(0,150)+'...'}else{$bo}
    Write-Output "CASE 128 $Kind $Case EQUAL base=$($b.processes) candidate=$($c.processes) git processes; ms base=$([Math]::Round($b.ms)) candidate=$([Math]::Round($c.ms)); $short"
  }
  function With-File([string]$Path,$Content,[scriptblock]$Action){
    $had=Test-Path -LiteralPath $Path;$saved=if($had){[IO.File]::ReadAllBytes($Path)}else{$null}
    try{ if($null-eq$Content){[IO.File]::Delete($Path)}else{[IO.File]::WriteAllText($Path,$Content)}; & $Action }
    finally{ if($had){[IO.File]::WriteAllBytes($Path,$saved)}elseif(Test-Path -LiteralPath $Path){[IO.File]::Delete($Path)} }
  }
  # Each mutant also runs on the case that discriminates it; it must differ there.
  $stateMutants=@()
  # Return class: a full state, for a main and a linked worktree, 2 and 10 picks, and an untracked dirty entry.
  Compare-Case state 'valid-main' $stateBody @($main.work) @($pickMutant) (6+$main.picks-1)
  Compare-Case state 'valid-linked' $stateBody @($linked.work) $stateMutants (6+$linked.picks-1)
  Compare-Case state 'valid-ten-picks' $stateBody @($ten.work) $stateMutants (6+$ten.picks-1)
  Compare-Case state 'valid-second-pick-stop' $stateBody @($second.work) $stateMutants (6+$second.picks-1)
  With-File (Join-Path $main.work 'untracked.txt') "synthetic untracked`n" { Compare-Case state 'valid-untracked-dirty' $stateBody @($main.work) $stateMutants (6+$main.picks-1) }
  Compare-Case state 'wide-path-main' $stateBody @($wide.work) $stateMutants (6+$wide.picks-1)
  Compare-Case state 'wide-path-linked' $stateBody @($wideLinked.work) $stateMutants (6+$wideLinked.picks-1)
  With-File (Join-Path $wideLinked.work "dirty $([char]0xE4) $([char]0x540D).txt") "synthetic untracked`n" { Compare-Case state 'wide-path-untracked-dirty' $stateBody @($wideLinked.work) $stateMutants (6+$wideLinked.picks-1) }
  # Throw classes, in source order.
  Compare-Case state 'not-a-repository' $stateBody @($notRepo) $stateMutants
  Compare-Case state 'unborn-head' $stateBody @($unborn) $stateMutants
  Compare-Case state 'attached-branch' $stateBody @($plain) $stateMutants
  Compare-Case state 'detached-without-rebase' $stateBody @($detached) $stateMutants
  Compare-Case state 'apply-backend-stop' $stateBody @($applyStop.work) $stateMutants
  foreach($operation in @('rebase-apply','MERGE_HEAD','CHERRY_PICK_HEAD','REVERT_HEAD','sequencer')){
    $marker=Fx $linked.work @('rev-parse','--path-format=absolute','--git-path',$operation)
    if($operation-cin@('rebase-apply','sequencer')){[IO.Directory]::CreateDirectory($marker)|Out-Null}else{[IO.File]::WriteAllText($marker,"$($linked.obligation.newBase)`n")}
    try{ Compare-Case state "conflicting-$operation" $stateBody @($linked.work) $(if($operation-ceq'MERGE_HEAD'){@($pathMutant)}else{@()}) }
    finally{ if($operation-cin@('rebase-apply','sequencer')){[IO.Directory]::Delete($marker)}else{[IO.File]::Delete($marker)} }
  }
  Compare-Case state 'conflicting-real-am-session' $stateBody @($am.work) @($pathMutant)
  With-File (Join-Path $main.rebase 'done') $null { Compare-Case state 'missing-done' $stateBody @($main.work) $stateMutants }
  $blob=Fx $main.work @('rev-parse',"$($main.baseCommit):conflict.txt")
  With-File (Join-Path $main.rebase 'onto') $blob { Compare-Case state 'onto-not-commit' $stateBody @($main.work) @($orderMutant) }
  $todoPath=Join-Path $main.rebase 'git-rebase-todo';$donePath=Join-Path $main.rebase 'done'
  $todo=[IO.File]::ReadAllText($todoPath);$done=[IO.File]::ReadAllText($donePath)
  With-File $todoPath ("exec git status`n"+$todo) { Compare-Case state 'noncanonical-todo' $stateBody @($main.work) $stateMutants }
  With-File $todoPath ("pick deadbeef0 synthetic missing`n"+$todo) { Compare-Case state 'unresolvable-pick' $stateBody @($main.work) @($orderMutant) -PickRevision 'deadbeef0^{commit}' }
  With-File $todoPath $done { With-File $donePath $todo { Compare-Case state 'reordered-history' $stateBody @($main.work) $stateMutants } }
  $donePick=($done -split "`n")[0].Split(' ')[1]
  [void](Fx $main.work @('update-ref',"refs/heads/$donePick",$main.obligation.newBase))
  try{ Compare-Case state 'ambiguous-pick-warning' $stateBody @($main.work) $stateMutants }
  finally{ [void](Fx $main.work @('update-ref','-d',"refs/heads/$donePick")) }
  # Return class: replay success (first-pick and identity-dependent second-pick stops).
  $mainState=& $base.module $stateBody $main.work
  $linkedState=& $base.module $stateBody $linked.work
  $secondState=& $base.module $stateBody $second.work
  $wideState=& $base.module $stateBody $wide.work
  $wideLinkedState=& $base.module $stateBody $wideLinked.work
  $replayMutants=@()
  Compare-Case replay 'valid-main' $replayBody @($main.obligation,$mainState) $replayMutants (6+$main.picks-1)
  Compare-Case replay 'valid-linked' $replayBody @($linked.obligation,$linkedState) $replayMutants (6+$linked.picks-1)
  Compare-Case replay 'valid-second-pick-identity' $replayBody @($second.obligation,$secondState) @($identityMutant) (6+$second.picks-1)
  Compare-Case replay 'wide-path-main' $replayBody @($wide.obligation,$wideState) $replayMutants (6+$wide.picks-1)
  Compare-Case replay 'wide-path-linked' $replayBody @($wideLinked.obligation,$wideLinkedState) $replayMutants (6+$wideLinked.picks-1)
  # A clone template that already defines user.name and user.email. Its
  # post-checkout hook copies the scratch clone's config when the replay checks
  # out, so the scratch config itself is part of the compared outcome.
  $template=Join-Path $root 'clone-template';[IO.Directory]::CreateDirectory((Join-Path $template 'hooks'))|Out-Null
  [IO.File]::WriteAllText((Join-Path $template 'config'),"[user]`n`tname = Template Person 128`n`temail = template-128@example.invalid`n[template128]`n`tmarker = applied`n")
  [IO.File]::WriteAllText((Join-Path $template 'hooks/post-checkout'),'#!/bin/sh'+"`n"+'cat "$(git rev-parse --git-dir)/config" > "$LANDED128_SCRATCH_CONFIG"'+"`n")
  $scratchConfig=(Join-Path $root 'scratch-config.txt').Replace('\','/')
  $templateReplayBody={param($o,$s,$templateDir,$capture)
    if(Test-Path -LiteralPath $capture){[IO.File]::Delete($capture)}
    $env:GIT_TEMPLATE_DIR=$templateDir;$env:LANDED128_SCRATCH_CONFIG=$capture
    try{ $replay=try{'RETURN '+(ConvertTo-Json -InputObject @(Assert-InterruptedIntegrationReplay $o $s) -Compress)}catch{'THROW '+$_.Exception.Message} }
    finally{ Remove-Item Env:GIT_TEMPLATE_DIR,Env:LANDED128_SCRATCH_CONFIG -ErrorAction SilentlyContinue }
    [ordered]@{replay=$replay;scratchConfig=$(if(Test-Path -LiteralPath $capture){[IO.File]::ReadAllText($capture)}else{'<no scratch config captured>'})}
  }
  Compare-Case replay 'template-identity' $templateReplayBody @($second.obligation,$secondState,$template,$scratchConfig) @($cloneConfigMutant) (6+$second.picks-1)
  Assert-True ($lastBase.Contains('marker = applied') -and $lastBase.Contains('name = Interrupted integration scratch proof') -and $lastBase.Contains('email = integration-proof@example.invalid') -and -not $lastBase.Contains('Template Person 128') -and -not $lastBase.Contains('template-128@example.invalid') -and $lastBase.Contains('"replay":"RETURN')) "template replay: base scratch config took the clone template and replaced its identity: $lastBase"
  Assert-True ($null -eq $env:GIT_TEMPLATE_DIR) 'clone template is scoped to the template case'
  # Throw classes.
  $changed=[ordered]@{};foreach($k in $mainState.Keys){$changed[$k]=$mainState[$k]};$changed.metadataSha256='0'*64
  Compare-Case replay 'state-differs' $replayBody @($main.obligation,$changed) $replayMutants
  $clean=[pscustomobject]@{worktree=$main.work;branch='synthetic/128';targetHead=$main.obligation.targetHead;newBase=$main.baseCommit}
  Compare-Case replay 'no-canonical-conflict' $replayBody @($clean,$mainState) $replayMutants
  $missingTarget=[pscustomobject]@{worktree=$main.work;branch='synthetic/128';targetHead=('f'*40);newBase=$main.obligation.newBase}
  Compare-Case replay 'checkout-refused' $replayBody @($missingTarget,$mainState) $replayMutants
  $missingSource=[pscustomobject]@{worktree=(Join-Path $root 'missing-source');branch='synthetic/128';targetHead=$main.obligation.targetHead;newBase=$main.obligation.newBase}
  Compare-Case replay 'clone-refused' $replayBody @($missingSource,$mainState) $replayMutants
  Compare-Case replay 'not-a-repository-source' $replayBody @([pscustomobject]@{worktree=$notRepo;branch='synthetic/128';targetHead=$main.obligation.targetHead;newBase=$main.obligation.newBase},$mainState) $replayMutants
  Compare-Case replay 'unborn-source' $replayBody @([pscustomobject]@{worktree=$unborn;branch='synthetic/128';targetHead=$main.obligation.targetHead;newBase=$main.obligation.newBase},$mainState) $replayMutants

  # Each mutant changes the output of every case it runs on relative to base (RED).
  $allMutants=@($pathMutant,$pickMutant,$identityMutant,$cloneConfigMutant,$orderMutant)
  foreach($m in $allMutants){
    $ran=@($mutantRuns|Where-Object{$_.mutant-ceq$m.name})
    $red=@($ran|Where-Object{-not$_.equal})
    Assert-True ($ran.Count-gt0-and$red.Count-eq$ran.Count) "$($m.name) mutant changes the output of every case it runs on"
    Write-Output "MUTANT 128 $($m.name) RED on $($red.Count) case(s): $(@($red|ForEach-Object{$_.case}) -join ', ')"
  }
  # The refusal-order mutant includes a non-pick refusal; the prior sorted-line
  # normalization would have called every one of its runs equal.
  $orderRuns=@($mutantRuns|Where-Object{$_.mutant-ceq$orderMutant.name})
  Assert-True (@($orderRuns|Where-Object{$_.case-ceq'state/onto-not-commit'}).Count-eq1) 'refusal-order mutant runs on a non-pick refusal'
  Assert-True (@($orderRuns|Where-Object{$_.priorEqual}).Count-eq$orderRuns.Count) 'the prior sorted-line normalization would have hidden every refusal-order run'
  Write-Output "CONTROL 128 refusal-order: RED under the narrowed comparison, hidden by the prior sorted-line normalization, on $($orderRuns.Count) case(s): $(@($orderRuns|ForEach-Object{$_.case}) -join ', ')"
  $classes=@($results|ForEach-Object{ if($_.outcome.StartsWith('RETURN')){"$($_.kind) RETURN"}else{"$($_.kind) $(($_.outcome -split ':')[0])"} }|Sort-Object -Unique)
  Write-Output "PASS 128 interrupted-resume internals: $($results.Count) cases equal to base $($BaselineHead.Substring(0,8)) across classes [$($classes -join '; ')]; $($allMutants.Count) mutants RED; exact native Git process savings asserted on every valid case"
} finally {
  Remove-Item Env:GIT_TRACE2_EVENT -ErrorAction SilentlyContinue
  Remove-Item Env:GIT_COMMITTER_DATE -ErrorAction SilentlyContinue
  Remove-Item Env:GIT_TEMPLATE_DIR -ErrorAction SilentlyContinue
  Remove-Item Env:LANDED128_SCRATCH_CONFIG -ErrorAction SilentlyContinue
  foreach($module in $imported){Remove-Module $module -Force -ErrorAction SilentlyContinue}
  $resolved=[IO.Path]::GetFullPath($root);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
  if((Split-Path -Parent $resolved).TrimEnd('\','/')-ne$temp-or(Split-Path -Leaf $resolved)-notmatch'^landed-evidence-128-[a-f0-9]{32}$'){throw "unsafe cleanup $resolved"}
  Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
}