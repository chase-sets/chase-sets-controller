$SyntheticIntegrationRepository='synthetic-7962-owner/synthetic-7962-repository'
function Write-SyntheticIntegrationEligibility([string]$History, $Nodes) {
  Import-Module (Join-Path $PSScriptRoot 'review-head-contract.psm1') -DisableNameChecking
  foreach($node in $Nodes){
    if($node.headRefName -cnotlike 'synthetic/*'){throw 'SYNTHETIC_AUTHORITY_REQUIRED'}
    if((Reduce-LandedIntegrationAuthority (Read-ExactHeadReviewHistory $History) $node.number $node.headRefName $node.headRefOid).state-ceq'ELIGIBLE'){continue}
    & (Join-Path $PSScriptRoot 'log-event.ps1') -Log dispatch -Kind rule-change -IntegrationAuthoritySchema landed-integration-authority/v1 `
      -Pr $node.number -Issue 908132 -TargetBranch $node.headRefName -LineageRoot synthetic/8132 -TargetHead $node.headRefOid -AuthorityState ELIGIBLE -OutFile $History -NoBoard | Out-Null
  }
}
function Assert-SyntheticIntegrationRepository([string]$Repository) {
  if ($Repository -ceq 'chase-sets/chase-sets' -or $Repository -cne $SyntheticIntegrationRepository) { throw 'SYNTHETIC_REPOSITORY_REQUIRED' }
}

function Assert-SyntheticIntegrationWitnesses([string]$Root) {
  $count=0
  foreach($file in @(Get-ChildItem -LiteralPath $Root -Recurse -File | Where-Object{$_.Name -like 'authority*.json' -or $_.Name -like 'integration-request-*.json' -or $_.Name -like '*.call.json'})) {
    $value=Get-Content -LiteralPath $file.FullName -Raw|ConvertFrom-Json -DateKind String
    if($file.Name -like 'authority*.json') {
      foreach($payload in @($value)) { Assert-SyntheticIntegrationRepository $payload.data.repository.nameWithOwner;Assert-SyntheticIntegrationRepository $payload.data.repository.pullRequest.headRepository.nameWithOwner }
    }else{Assert-SyntheticIntegrationRepository $value.repository}
    $count++
  }
  if($count-eq0){throw 'synthetic authority/request/call witnesses missing'}
  # Direct and native-array fixture callers must explicitly bind the same identity.
  foreach($name in @('landed-integration-dispatch.test.ps1','landed-integration-r3.test.ps1','landed-integration-evidence-test-support.ps1','integration-dispatch-test-support.ps1')){
    foreach($line in Get-Content -LiteralPath (Join-Path $PSScriptRoot $name)){
      if($line -notmatch '\$line -' -and $line -match ' -(Graph)?FixturePath |''-(Graph)?FixturePath'','){
        if($line -notmatch ' -Repository \$SyntheticIntegrationRepository |''-Repository'',\$(SyntheticIntegrationRepository|c\.repository),'){throw "synthetic producer call lacks repository: $name $line"}
      }
    }
  }
  $rejected=$false;try{Assert-SyntheticIntegrationRepository 'chase-sets/chase-sets'}catch{$rejected=$_.Exception.Message-ceq'SYNTHETIC_REPOSITORY_REQUIRED'}
  if(-not$rejected){throw 'real external repository accepted as synthetic'}
  Write-Output "CONTROL 7962/F1-synthetic-authority-request-call-witnesses count=$count realRepository=REJECTED"
}

function Write-SyntheticIntegrationAuthority([string]$Path, $Nodes, [string]$Base, [string]$Repository=$SyntheticIntegrationRepository) {
  Assert-SyntheticIntegrationRepository $Repository
  $payloads = @($Nodes | ForEach-Object {
    [ordered]@{data=[ordered]@{repository=[ordered]@{nameWithOwner=$Repository;ref=[ordered]@{name='main';target=[ordered]@{oid=$Base}};
      pullRequest=[ordered]@{number=[long]$_.number;state='OPEN';headRefName=$_.headRefName;headRefOid=$_.headRefOid;headRepository=[ordered]@{nameWithOwner=$Repository}}}}}
  })
  [IO.File]::WriteAllText($Path,(ConvertTo-Json -InputObject $payloads -Depth 10),[Text.UTF8Encoding]::new($false))
  return $Path
}

function Publish-SyntheticIntegrationRemote([string]$Repository, [string]$Remote) {
  & git init -q --bare $Remote
  if ($LASTEXITCODE -ne 0) { throw 'synthetic bare init failed' }
  & git -C $Repository remote add origin $Remote
  if ($LASTEXITCODE -ne 0) { throw 'synthetic origin failed' }
  & git -C $Repository push -q origin --all
  if ($LASTEXITCODE -ne 0) { throw 'synthetic publication failed' }
  & git -C $Repository fetch -q origin main
  if ($LASTEXITCODE -ne 0) { throw 'synthetic main binding failed' }
}

# Executed by the existing R3 carrier, focused or inside the canonical battery.
function Test-7962NativeControls {
  $caseRoot=Join-Path $fixtureRoot 'synthetic-7962';New-Item -ItemType Directory $caseRoot|Out-Null
  $nativeFailures=[Collections.Generic.List[string]]::new()
  $pwsh=(Get-Command pwsh -CommandType Application|Select-Object -First 1 -ExpandProperty Source)
  $baseline='8106d4e12c4b3329e3b59372366c5a57e8dfacc1';$candidateRoot=Split-Path -Parent $PSScriptRoot
  & git -C $candidateRoot cat-file -e "$baseline^{commit}";if($LASTEXITCODE-ne0){throw 'baseline missing'}
  $zip=Join-Path $caseRoot 'baseline.zip'; & git -C $candidateRoot archive --format=zip "--output=$zip" $baseline .orchestrator
  if($LASTEXITCODE-ne0){throw 'baseline archive failed'}
  Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $caseRoot 'baseline');$baselineRuntime=Join-Path $caseRoot 'baseline/.orchestrator'
  . (Join-Path $PSScriptRoot 'dispatch-ownership.ps1')
  . (Join-Path $PSScriptRoot 'integration-dispatch-contract.ps1')
  Import-Module (Join-Path $PSScriptRoot 'landed-integration-evidence.psm1') -Force -DisableNameChecking
  Import-Module (Join-Path $PSScriptRoot 'review-head-contract.psm1') -Force -DisableNameChecking
  function N([string]$Repo,[string[]]$A){$v=@(& git -C $Repo @A 2>&1);if($LASTEXITCODE-ne0){throw "Git $LASTEXITCODE $A $v"};return ($v-join"`n").Trim()}
  function J([string]$Path,$Value){[IO.File]::WriteAllText($Path,(ConvertTo-Json -InputObject $Value -Depth 30 -Compress),[Text.UTF8Encoding]::new($false))}
  function Check($Condition,[string]$Name){if(-not$Condition){throw "7962 $Name"}}
  function Control([string]$Name,[scriptblock]$Body){try{& $Body;Write-Output "CONTROL 7962/$Name native assertions satisfied"}catch{$nativeFailures.Add("${Name}: $($_.Exception.Message)");Write-Output "CONTROL 7962/$Name FAILED $($_.Exception.Message) $($_.ScriptStackTrace)"}}
  function Begin-Native([string]$Script,[string[]]$A,[string]$Stem){
    $s=[Diagnostics.ProcessStartInfo]::new();$s.FileName=$pwsh;$s.UseShellExecute=$false;$s.CreateNoWindow=$true;$s.RedirectStandardOutput=$true;$s.RedirectStandardError=$true
    foreach($arg in (@('-NoProfile','-NonInteractive','-File',$Script)+$A)){[void]$s.ArgumentList.Add($arg)}
    $p=[Diagnostics.Process]::Start($s);return @{p=$p;out=$p.StandardOutput.ReadToEndAsync();err=$p.StandardError.ReadToEndAsync();stem=$Stem}
  }
  function End-Native($h){
    if(-not$h.p.WaitForExit(45000)){throw "native deadline $($h.stem) PID=$($h.p.Id)"}
    $r=[pscustomobject]@{exit=$h.p.ExitCode;stdout=$h.out.GetAwaiter().GetResult();stderr=$h.err.GetAwaiter().GetResult();pid=$h.p.Id}
    [IO.File]::WriteAllText("$($h.stem).stdout.log",$r.stdout);[IO.File]::WriteAllText("$($h.stem).stderr.log",$r.stderr);J "$($h.stem).exit.json" @{exit=$r.exit;pid=$r.pid};$h.p.Dispose();return $r
  }
  function Run-Native([string]$Script,[string[]]$A,[string]$Stem){
    if('-FixturePath'-cin$A){
      $index=[array]::IndexOf($A,'-Repository');Check ($index-ge0-and$index-lt($A.Count-1)) 'fixture producer repository argument missing'
      Assert-SyntheticIntegrationRepository $A[$index+1];J "$Stem.call.json" @{script=$Script;arguments=$A;repository=$A[$index+1]}
    }
    End-Native (Begin-Native $Script $A $Stem)
  }
  function New-Case([string]$Name){
    $root=Join-Path $caseRoot $Name;$repo=Join-Path $root 'repo';$runtime=Join-Path $root 'runtime';$temp=Join-Path $root 'temp';New-Item -ItemType Directory $repo,$runtime,$temp|Out-Null
    [void](N $repo @('init','-q','--initial-branch=main'));[void](N $repo @('config','user.name','Synthetic 7962'));[void](N $repo @('config','user.email','synthetic7962@example.invalid'))
    [IO.File]::WriteAllText((Join-Path $repo 'seed.txt'),'seed');[void](N $repo @('add','.'));[void](N $repo @('commit','-qm','seed'));[void](N $repo @('checkout','-qb','synthetic/7962'))
    [IO.File]::WriteAllText((Join-Path $repo 'feature.txt'),'feature');[void](N $repo @('add','.'));[void](N $repo @('commit','-qm','feature'));$head=N $repo @('rev-parse','HEAD')
    [void](N $repo @('checkout','-q','main'));[IO.File]::WriteAllText((Join-Path $repo 'main.txt'),'advance');[void](N $repo @('add','.'));[void](N $repo @('commit','-qm','main'));$base=N $repo @('rev-parse','HEAD');[void](N $repo @('checkout','-q','synthetic/7962'))
    Publish-SyntheticIntegrationRemote $repo (Join-Path $root 'remote.git')
    $node=[ordered]@{number=[long]907962;headRefOid=$head;headRefName='synthetic/7962';mergeable='MERGEABLE';mergeStateStatus='CLEAN';worktree=$repo;files=@{complete=$true;totalCount=[long]1;nodes=@(@{path='feature.txt'})}}
    $census=[ordered]@{schemaVersion='landed-integration-census/v1';complete=$true;newBase=$base;activeBranches=@();landed=@{pr=[long]907960;head=('a'*40);files=@{complete=$true;totalCount=[long]1;nodes=@(@{path='feature.txt'})}};openPullRequests=@{complete=$true;totalCount=[long]1;nodes=@($node)}}
    $history=Join-Path $runtime 'dispatch-log.jsonl';[IO.File]::WriteAllText($history,'');J (Join-Path $root 'census.json') $census
    Write-SyntheticIntegrationEligibility $history @($node)
    $repository=$SyntheticIntegrationRepository
    $api=Write-SyntheticIntegrationAuthority (Join-Path $root 'authority.json') @($node) $base $repository
    return [pscustomobject]@{root=$root;repository=$repository;repo=$repo;runtime=$runtime;temp=$temp;head=$head;base=$base;branch='synthetic/7962';node=$node;census=$census;api=$api;history=$history;historySeed=[IO.File]::ReadAllText($history)}
  }
  function New-Subject([string]$Name,[string]$File,[string]$Old,[string]$New){
    $dir=Join-Path $caseRoot "subject-$Name";New-Item -ItemType Directory $dir|Out-Null
    Get-ChildItem -LiteralPath $PSScriptRoot -File|Where-Object{$_.Extension-in@('.ps1','.psm1','.cjs')}|Copy-Item -Destination $dir
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'contracts') -Destination $dir -Recurse
    $path=Join-Path $dir $File;$text=[IO.File]::ReadAllText($path);Check (([regex]::Matches($text,[regex]::Escape($Old))).Count-eq1) "single mutation $Name"
    [IO.File]::WriteAllText($path,$text.Replace($Old,$New));return $path
  }
  function Producer-Args($c,[string]$Wrapper,[switch]$Old){
    Assert-SyntheticIntegrationRepository $c.repository
    $a=@('-Repository',$c.repository,'-LandedPr','907960','-LandedHead',('a'*40),'-HistoryPath',$c.history,'-RuntimeRoot',$c.runtime,'-ContainerRoot',$c.root,'-FixturePath',(Join-Path $c.root 'census.json'),'-DispatchScript',$Wrapper,'-SynchronousDispatch')
    if(-not$Old){$a+=@('-IntegrationAuthorityFixturePath',$c.api)};return ,$a
  }
  function Request($c,[string]$Label='synthetic-bound'){
    Assert-SyntheticIntegrationRepository $c.repository
    $r=[ordered]@{schemaVersion='integration-dispatch-request/v1';requestIdentity=('c'*64);repository=$c.repository;pr=[long]907962;landedPr=[long]907960;landedHead=('a'*40);head=$c.head;newBase=$c.base;branch=$c.branch;worktree=$c.repo;label=$Label;sourceIdentity='ABSENT_REVIEW_REQUIRED';sourceHead='';runtimeRoot=$c.runtime;historyPath=$c.history}
    J (Join-Path $c.runtime "integration-request-$Label.json") $r;[IO.File]::WriteAllText((Join-Path $c.runtime "$Label.prompt.txt"),'Synthetic integration request');return $r
  }
  function Launcher-Runner($c,$r,[string]$Launcher,$Tuple=@('codex','gpt-6-astra','high',7,'override-Todd'),[string[]]$Extra=@()){
    $cfg=Join-Path $c.root ('run-'+[guid]::NewGuid().ToString('N')+'.json');$child=Join-Path $c.root 'body.ps1'
    [IO.File]::WriteAllText($child,'param($Marker);[IO.File]::WriteAllText($Marker,''entered'');Write-Output ''{"type":"turn.completed"}''')
    $p=@{Harness=$Tuple[0];Model=$Tuple[1];Effort=$Tuple[2];Row=$Tuple[3];Placement=$Tuple[4];LaneRole='implementation';PromptFile=(Join-Path $c.runtime "$($r.label).prompt.txt");Worktree=$c.repo;Label=$r.label;StartRequestIdentity=$r.requestIdentity;StartAcknowledgementPath=(Join-Path $c.runtime "dispatch-start-$($r.requestIdentity).json");IntegrationTargetPath=(Join-Path $c.runtime "integration-request-$($r.label).json");IntegrationAuthorityFixturePath=$c.api;ExecutablePath=$pwsh;TestRuntimeRoot=$c.runtime;TestTempRoot=$c.temp;TestArgumentList=@('-NoProfile','-NonInteractive','-File',$child,(Join-Path $c.root 'body.txt'))}
    for($i=0;$i-lt$Extra.Count;$i+=2){$p[$Extra[$i]]=$Extra[$i+1]};J $cfg @{launcher=$Launcher;parameters=$p};$runner=$cfg+'.ps1'
    [IO.File]::WriteAllText($runner,'$c=Get-Content -LiteralPath '''+$cfg.Replace("'","''")+''' -Raw|ConvertFrom-Json -AsHashtable; $p=$c.parameters; & $c.launcher @p; exit $LASTEXITCODE');return $runner
  }
  function Zero-Effects($c){return -not(Test-Path (Join-Path $c.root 'body.txt'))-and@(Get-ChildItem $c.runtime -Filter 'dispatch-launch-*.json').Count-eq0-and@(Get-ChildItem $c.runtime -Filter 'dispatch-start-*.json').Count-eq0-and@(Get-ChildItem $c.runtime -Filter 'watchdog-lane-*.json').Count-eq0-and[IO.File]::ReadAllText($c.history)-ceq$c.historySeed}
  function New-Wrapper($c,[string]$Launcher,[switch]$Helper){
    $config=Join-Path $c.root 'wrapper-config.json';$child=Join-Path $c.root 'native-harness.ps1'
    J $config @{launcher=$Launcher;runtime=$c.runtime;temp=$c.temp;pwsh=$pwsh;helper=[bool]$Helper;body=(Join-Path $c.root 'body.txt');observed=(Join-Path $c.root 'arguments.json')}
    [IO.File]::WriteAllText($child,@'
param($Config)
$ErrorActionPreference='Stop';$c=Get-Content -LiteralPath $Config -Raw|ConvertFrom-Json
[IO.File]::WriteAllText($c.body,'native implementation body entered');$inputText=[Console]::In.ReadToEnd()
if($c.helper){
  $line=@($inputText-split"`r?`n"|Where-Object{$_-like"pwsh '*"});if($line.Count-ne1){throw 'synthetic harness expected one canonical helper command'}
  $t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($line[0],[ref]$t,[ref]$e);$cmd=$ast.EndBlock.Statements[0].PipelineElements[0]
  $a=@($cmd.CommandElements|Select-Object -Skip 1|ForEach-Object{if($_-isnot[Management.Automation.Language.StringConstantExpressionAst]){throw 'nonliteral helper argument'};$_.Value})
  [IO.File]::WriteAllText($c.observed,(ConvertTo-Json -InputObject $a -Compress))
  $s=[Diagnostics.ProcessStartInfo]::new();$s.FileName=$c.pwsh;$s.UseShellExecute=$false;$s.RedirectStandardOutput=$true;$s.RedirectStandardError=$true;$s.CreateNoWindow=$true
  foreach($arg in $a){[void]$s.ArgumentList.Add($arg)};$p=[Diagnostics.Process]::Start($s);$o=$p.StandardOutput.ReadToEndAsync();$e=$p.StandardError.ReadToEndAsync();$p.WaitForExit();$code=$p.ExitCode;$output=$o.GetAwaiter().GetResult()+$e.GetAwaiter().GetResult();$p.Dispose()
  [IO.File]::WriteAllText($c.body+'.helper.log',$output)
  @{type='item.completed';item=@{id='native-helper';type='command_execution';command=$line[0];exit_code=$code;aggregated_output=$output}}|ConvertTo-Json -Depth 5 -Compress
  if($code-ne0){exit $code}
}
'{"type":"turn.completed"}'
'@)
    $wrapper=Join-Path $c.root 'native-launcher-wrapper.ps1';$text=@'
param($Harness,$Model,$Effort,$Row,$Placement,$LaneRole,$PromptFile,$Worktree,$Label,$StartRequestIdentity,$StartAcknowledgementPath,$IntegrationTargetPath,$IntegrationAuthorityFixturePath,$SemanticAttemptId,$WatchdogRelaunchCount,$ResumeOfLaunchId)
$c=Get-Content -LiteralPath '__CONFIG__' -Raw|ConvertFrom-Json
$p=@{Harness=$Harness;Model=$Model;Effort=$Effort;Row=$Row;Placement=$Placement;LaneRole=$LaneRole;PromptFile=$PromptFile;Worktree=$Worktree;Label=$Label;StartRequestIdentity=$StartRequestIdentity;StartAcknowledgementPath=$StartAcknowledgementPath;ExecutablePath=$c.pwsh;TestRuntimeRoot=$c.runtime;TestTempRoot=$c.temp;TestArgumentList=@('-NoProfile','-NonInteractive','-File','__CHILD__','__CONFIG__')}
if($SemanticAttemptId){$p.SemanticAttemptId=$SemanticAttemptId;$p.WatchdogRelaunchCount=$WatchdogRelaunchCount;$p.ResumeOfLaunchId=$ResumeOfLaunchId}
if($IntegrationTargetPath){$p.IntegrationTargetPath=$IntegrationTargetPath;$p.IntegrationAuthorityFixturePath=$IntegrationAuthorityFixturePath}
& $c.launcher @p
exit $LASTEXITCODE
'@
    [IO.File]::WriteAllText($wrapper,$text.Replace('__CONFIG__',$config.Replace("'","''")).Replace('__CHILD__',$child.Replace("'","''")));return $wrapper
  }
  Control 'baseline-late-head-and-Terra' {
    $c=New-Case 'baseline-late-head';[IO.File]::WriteAllText((Join-Path $c.repo 'local.txt'),'unpublished');[void](N $c.repo @('add','.'));[void](N $c.repo @('commit','-qm','local unpublished'));$local=N $c.repo @('rev-parse','HEAD')
    $wrapper=New-Wrapper $c (Join-Path $baselineRuntime 'dispatch-lane.ps1');$r=Run-Native (Join-Path $baselineRuntime 'landed-integration-dispatch.ps1') (Producer-Args $c $wrapper -Old) (Join-Path $c.root 'baseline')
    $ack=@(Get-ChildItem $c.runtime -Filter 'dispatch-start-*.json'|ForEach-Object{Read-RebaseJson $_.FullName})
    Check ($r.exit-ne0-and$r.stderr.Contains('INTEGRATION_DISPATCH_START_ACK_UNKNOWN')-and$ack.Count-eq1-and$ack[0].head-ceq$local-and$ack[0].model-ceq'gpt-5.6-terra'-and(Test-Path (Join-Path $c.root 'body.txt'))) "historical baseline late mismatch $($r.stderr)" # historical fixture
    J (Join-Path $c.root 'baseline-evidence.json') @{baseline=$baseline;requested=$c.head;actual=$local;exit=$r.exit;ack=$ack[0]}
  }
  Control 'producer-native-helper-and-all-identities' {
    $c=New-Case 'native-helper';$wrapper=New-Wrapper $c (Join-Path $PSScriptRoot 'dispatch-lane.ps1') -Helper
    $r=Run-Native (Join-Path $PSScriptRoot 'landed-integration-dispatch.ps1') (Producer-Args $c $wrapper) (Join-Path $c.root 'candidate');Check ($r.exit-eq0) "producer native exit $($r.stderr)"
    $ack=@(Get-ChildItem $c.runtime -Filter 'dispatch-start-*.json'|ForEach-Object{Read-RebaseJson $_.FullName})[0];$spec=Read-RebaseJson (Join-Path $c.runtime "watchdog-lane-$($ack.label).json")
    $rows=@(Get-Content $c.history|ForEach-Object{$_|ConvertFrom-Json -DateKind String})
    foreach($v in @($ack,$spec)+@($rows|Where-Object{-not$_.integrationAuthoritySchema})){Check ($v.harness-ceq'codex'-and$v.model-ceq'gpt-6-astra'-and$v.effort-ceq'high'-and[int]$v.row-eq7-and$v.placement-ceq'override-Todd') 'actual emitted tuple'}
    Check (@($rows|Where-Object{$_.integrationAuthoritySchema-and-not$_.model-and$_.kind-ceq'rule-change'}).Count-eq1) 'synthetic eligibility acquired execution attribution'
    $a=Read-RebaseJson (Join-Path $c.root 'arguments.json');foreach($name in @('-Pr','-ReviewedHead','-NewBase','-SourcePassReceiptIdentity','-IntegrationLane','-Worktree','-RuntimeRoot','-HistoryPath','-NonInteractive')){Check ($name-cin$a) "actual helper missing $name"}
    Check ($a-cnotcontains'-SourcePassReviewedHead') 'absent PASS source head'
    $head=N $c.repo @('rev-parse','HEAD');$remote=N $c.repo @('ls-remote','--refs','origin',"refs/heads/$($c.branch)")
    Check ($head-cne$c.head-and$remote.StartsWith($head)-and[IO.File]::ReadAllText((Join-Path $c.root 'body.txt.helper.log')).Contains('REVIEW_REQUIRED')-and$spec.schemaVersion-ceq'watchdog-lane/v3'-and$spec.integrationRequest.head-ceq$c.head) 'helper publication/review-required result'
    Check (@($rows|Where-Object{$_.continuationSchema}).Count-eq0) 'absent PASS continuation'
  }
  foreach($pair in @('hashed-empty','absent-with-head')){Control "F2-source-pair-$pair-zero-effects" {
    $c=New-Case "source-pair-$pair";$req=Request $c
    if($pair-ceq'hashed-empty'){$req.sourceIdentity='e'*64}else{$req.sourceHead=$c.head}
    J (Join-Path $c.runtime "integration-request-$($req.label).json") $req
    $refs=N $c.repo @('show-ref');$remote=N $c.repo @('ls-remote','--refs','origin')
    $r=Run-Native (Launcher-Runner $c $req (Join-Path $PSScriptRoot 'dispatch-lane.ps1')) @() (Join-Path $c.root 'candidate')
    Check ($r.exit-ne0-and$r.stderr.Contains('INTEGRATION_REQUEST_INVALID')-and(Zero-Effects $c)) 'malformed source pair published owner/child'
    Check ((N $c.repo @('show-ref'))-ceq$refs-and(N $c.repo @('ls-remote','--refs','origin'))-ceq$remote-and-not(N $c.repo @('status','--porcelain=v1'))) 'malformed pair changed Git'
    J (Join-Path $c.root 'zero-effects.json') @{pair=$pair;exit=$r.exit;zeroEffects=(Zero-Effects $c);refs=$refs;remote=$remote}
    if($pair-ceq'hashed-empty'){
      $old="(`$Request.sourceIdentity -cmatch '^[a-f0-9]{64}$' -and `$Request.sourceHead -cnotmatch '^[a-f0-9]{40}$')"
      $subject=New-Subject 'source-pair' 'integration-dispatch-contract.ps1' $old '$false'
      $r=Run-Native (Launcher-Runner $c $req (Join-Path (Split-Path -Parent $subject) 'dispatch-lane.ps1')) @() (Join-Path $c.root 'bypass')
      Check ($r.exit-eq0-and(Test-Path (Join-Path $c.root 'body.txt'))) "source pair guard bypass did not enter body $($r.stderr)"
    }
  }}
  foreach($mode in @('fresh','watchdog')){Control "F2-qualified-source-$mode-exact-helper-head" {
    $c=New-Case "qualified-source-$mode";$sourceHead=$c.head
    $r=Run-Native (Join-Path $PSScriptRoot 'log-event.ps1') @('-Log','dispatch','-Kind','review-complete','-Pr','907962','-ReviewedHead',$sourceHead,'-ReviewerAttempt','synthetic-qualified-review','-AuthorAttempt','synthetic-qualified-author','-ReviewContract','review-contract/v2','-CompleteSweep','-Outcome','PASS','-Model','gpt-6.1-sol','-AuthorModel','gpt-6-astra','-Blocking','0','-Candidates','0','-NonBlocking','0','-RepairOwner','none','-OutFile',$c.history,'-NoBoard') (Join-Path $c.root 'source-pass')
    Check ($r.exit-eq0) "synthetic source receipt $($r.stderr)"
    $source=Reduce-ExactHeadReview -Pr 907962 -CurrentHead $sourceHead -History (Read-ExactHeadReviewHistory -Path $c.history)
    Check ($source.state-ceq'authorized') 'qualified source missing'
    $sourceIdentity=$source.latest.receiptIdentity
    $args=Get-IntegrationHelperArguments 907962 $c.head $c.base $sourceIdentity $sourceHead 'synthetic-first-hop' $c.repo $c.runtime $c.history
    $r=Run-Native (Join-Path $PSScriptRoot 'rebase-integration.ps1') @($args|Select-Object -Skip 4) (Join-Path $c.root 'first-hop')
    Check ($r.exit-eq0-and$r.stdout.Contains('CONTINUATION_LOGGED')) "qualified first hop $($r.stdout) $($r.stderr)"
    $c.head=N $c.repo @('rev-parse','HEAD');Check ($c.head-cne$sourceHead) 'source must differ from current reviewed head'
    [void](N $c.repo @('checkout','-q','main'));[IO.File]::WriteAllText((Join-Path $c.repo 'main-two.txt'),'second advance');[void](N $c.repo @('add','.'));[void](N $c.repo @('commit','-qm','second main'));$c.base=N $c.repo @('rev-parse','HEAD');[void](N $c.repo @('push','-q','origin','main'));[void](N $c.repo @('fetch','-q','origin','main'));[void](N $c.repo @('checkout','-q',$c.branch))
    $c.node.headRefOid=$c.head;$c.census.newBase=$c.base;J (Join-Path $c.root 'census.json') $c.census
    Write-SyntheticIntegrationEligibility $c.history @($c.node)
    [void](Write-SyntheticIntegrationAuthority $c.api @($c.node) $c.base $c.repository)
    $wrapper=New-Wrapper $c (Join-Path $PSScriptRoot 'dispatch-lane.ps1') -Helper
    if($mode-ceq'fresh'){
      $r=Run-Native (Join-Path $PSScriptRoot 'landed-integration-dispatch.ps1') (Producer-Args $c $wrapper) (Join-Path $c.root 'candidate')
      Check ($r.exit-eq0-and$r.stdout.Contains('LAUNCHED')) "qualified fresh launch $($r.stdout) $($r.stderr)"
    }else{
      $req=Request $c;$req.sourceIdentity=$sourceIdentity;$req.sourceHead=$sourceHead;J (Join-Path $c.runtime "integration-request-$($req.label).json") $req
      $runner=Launcher-Runner $c $req (Join-Path $PSScriptRoot 'dispatch-lane.ps1')
      [IO.File]::WriteAllText((Join-Path $c.root 'body.ps1'),'Write-Output ''{"type":"item.completed"}'';[Console]::Error.WriteLine(''stream disconnected'');exit 17')
      $r=Run-Native $runner @() (Join-Path $c.root 'native-death');Check ($r.exit-eq17) 'qualified watchdog native death'
      $r=Run-Native (Join-Path $PSScriptRoot 'lane-stall-watchdog.ps1') @('-Label',$req.label,'-RuntimeRoot',$c.runtime,'-HistoryPath',$c.history,'-DispatchScript',$wrapper,'-IntegrationAuthorityFixturePath',$c.api,'-SynchronousDispatch') (Join-Path $c.root 'watchdog')
      Check ($r.exit-eq0-and$r.stdout.Contains('RELAUNCHED')) "qualified watchdog launch $($r.stdout) $($r.stderr)"
    }
    $a=Read-RebaseJson (Join-Path $c.root 'arguments.json');$sourceIndex=[array]::IndexOf($a,'-SourcePassReviewedHead');$headIndex=[array]::IndexOf($a,'-ReviewedHead')
    Check ($sourceIndex-ge0-and$a[$sourceIndex+1]-ceq$sourceHead-and$headIndex-ge0-and$a[$headIndex+1]-ceq$c.head-and$sourceHead-cne$c.head) 'exact original source head did not reach actual helper'
    $specs=@(Get-ChildItem $c.runtime -Filter 'watchdog-lane-*.json'|ForEach-Object{Read-RebaseJson $_.FullName})
    foreach($spec in $specs){Check ($spec.integrationRequest.sourceHead-ceq$sourceHead-and$spec.integrationRequest.sourceIdentity-ceq$sourceIdentity) 'bound watchdog request lost qualified source'}
    $newHead=N $c.repo @('rev-parse','HEAD');$remote=N $c.repo @('ls-remote','--refs','origin',"refs/heads/$($c.branch)")
    $reduction=Reduce-ExactHeadReview -Pr 907962 -CurrentHead $newHead -History (Read-ExactHeadReviewHistory -Path $c.history)
    Check ($newHead-cne$c.head-and$remote.StartsWith($newHead)-and$reduction.state-ceq'authorized'-and$reduction.latest.continuationHops-eq2-and$reduction.latest.reviewedHead-ceq$sourceHead-and[IO.File]::ReadAllText((Join-Path $c.root 'body.txt.helper.log')).Contains('CONTINUATION_LOGGED')) 'qualified source second-hop/publication result'
    J (Join-Path $c.root 'source-head-oracle.json') @{mode=$mode;sourceIdentity=$sourceIdentity;sourceHead=$sourceHead;reviewedHead=$c.head;newHead=$newHead;arguments=$a;continuationHops=$reduction.latest.continuationHops;remote=$remote}
  }}
  foreach($field in @('harness','model','effort','row','placement')){Control "route-$field-candidate-and-bypass" {
    $c=New-Case "route-$field";$req=Request $c;$tuple=@('codex','gpt-6-astra','high',7,'override-Todd')
    switch($field){harness{$tuple[0]='claude'}model{$tuple[1]='gpt-6.1-sol'}effort{$tuple[2]='medium'}row{$tuple[3]=2}placement{$tuple[4]='measured'}}
    $r=Run-Native (Launcher-Runner $c $req (Join-Path $PSScriptRoot 'dispatch-lane.ps1') $tuple) @() (Join-Path $c.root 'candidate')
    Check ($r.exit-ne0-and$r.stderr.Contains('INTEGRATION_AUTHOR_UNAVAILABLE')-and(Zero-Effects $c)) 'wrong tuple admitted'
    $mutant=New-Subject "route-$field" 'dispatch-lane.ps1' '  Assert-IntegrationAuthor $Harness $Model $Effort $Row $Placement # INTEGRATION_GUARD_ROUTE' '  # independently omitted route guard'
    $r=Run-Native (Launcher-Runner $c $req $mutant $tuple) @() (Join-Path $c.root 'bypass');if($field-ceq'harness'){Check ($r.exit-ne0-and$r.stderr.Contains('MODEL_HARNESS_MISMATCH')-and-not$r.stderr.Contains('INTEGRATION_AUTHOR_UNAVAILABLE')) 'harness bypass crossed integration boundary and reached independent registry guard'}else{Check ($r.exit-eq0-and(Test-Path (Join-Path $c.root 'body.txt'))) "route bypass $field $($r.stderr)"}
  }}
  foreach($state in @('unpublished','dirty','detached','missing-remote','pr-head','remote-base','local-base','github-base','wrong-root')){Control "preflight-$state-native" {
    $c=New-Case "preflight-$state";$wrapper=New-Wrapper $c (Join-Path $PSScriptRoot 'dispatch-lane.ps1')
    switch($state){
      unpublished{[IO.File]::WriteAllText((Join-Path $c.repo 'local.txt'),'unpublished');[void](N $c.repo @('add','.'));[void](N $c.repo @('commit','-qm','unpublished'))}
      dirty{[IO.File]::WriteAllText((Join-Path $c.repo 'dirty.txt'),'dirty')}
      detached{[void](N $c.repo @('checkout','-q','--detach',$c.head))}
      'missing-remote'{[void](N $c.repo @('push','-q','origin','--delete',$c.branch))}
      'pr-head'{$api=Read-RebaseJson $c.api;$api[0].data.repository.pullRequest.headRefOid=$c.base;J $c.api $api}
      'remote-base'{[void](N $c.repo @('push','-q','--force','origin',"$($c.head):refs/heads/main"))}
      'local-base'{[void](N $c.repo @('update-ref','refs/remotes/origin/main',$c.head))}
      'github-base'{$api=Read-RebaseJson $c.api;$api[0].data.repository.ref.target.oid=$c.head;J $c.api $api}
      'wrong-root'{$sub=Join-Path $c.repo 'nested';New-Item -ItemType Directory $sub|Out-Null;$c.census.openPullRequests.nodes[0].worktree=$sub;J (Join-Path $c.root 'census.json') $c.census}
    }
    $before=N $c.repo @('status','--porcelain=v1');$refs=N $c.repo @('show-ref');$remote=N $c.repo @('ls-remote','--refs','origin')
    $r=Run-Native (Join-Path $PSScriptRoot 'landed-integration-dispatch.ps1') (Producer-Args $c $wrapper) (Join-Path $c.root 'candidate')
    Check ($r.exit-ne0-and$r.stderr.Contains('INTEGRATION_TARGET_RECONCILIATION_REQUIRED')-and(Zero-Effects $c)) "preflight $state $($r.stderr)"
    Check ((N $c.repo @('status','--porcelain=v1'))-ceq$before-and(N $c.repo @('show-ref'))-ceq$refs-and(N $c.repo @('ls-remote','--refs','origin'))-ceq$remote) 'refusal changed Git state'
  }}
  Control 'stale-preflight-candidate-and-publication-bypass' {
    $c=New-Case 'stale-preflight';$req=Request $c;$entered=Join-Path $c.root 'entered';$continue=Join-Path $c.root 'continue'
    $extra=@('IntegrationPreflightObservedPath',$entered,'IntegrationPreflightContinuePath',$continue)
    $runner=Launcher-Runner $c $req (Join-Path $PSScriptRoot 'dispatch-lane.ps1') @('codex','gpt-6-astra','high',7,'override-Todd') $extra
    $h=Begin-Native $runner @() (Join-Path $c.root 'candidate');$deadline=[datetime]::UtcNow.AddSeconds(15)
    while(-not(Test-Path $entered)){if($h.p.HasExited-or[datetime]::UtcNow-ge$deadline){throw 'stale barrier not reached'};[Threading.Thread]::Sleep(25)}
    $api=Read-RebaseJson $c.api;$api[0].data.repository.pullRequest.headRefOid=$c.base;J $c.api $api;[IO.File]::WriteAllText($continue,'continue');$r=End-Native $h
    Check ($r.exit-ne0-and$r.stderr.Contains('INTEGRATION_TARGET_RECONCILIATION_REQUIRED')-and(Zero-Effects $c)) 'stale API escaped publication'
    $api[0].data.repository.pullRequest.headRefOid=$c.head;J $c.api $api;Remove-Item -LiteralPath $entered,$continue
    $old='    [void](Assert-IntegrationTarget $worktreeResolved $integrationTarget.branch $integrationTarget.head $integrationTarget.newBase $integrationTarget.repository $integrationTarget.pr $IntegrationAuthorityFixturePath) # INTEGRATION_GUARD_PUBLICATION'
    $mutant=New-Subject 'publication' 'dispatch-lane.ps1' $old '    # independently omitted publication guard'
    $runner=Launcher-Runner $c $req $mutant @('codex','gpt-6-astra','high',7,'override-Todd') $extra
    $h=Begin-Native $runner @() (Join-Path $c.root 'bypass');$deadline=[datetime]::UtcNow.AddSeconds(15)
    while(-not(Test-Path $entered)){if($h.p.HasExited-or[datetime]::UtcNow-ge$deadline){throw 'bypass barrier not reached'};[Threading.Thread]::Sleep(25)}
    $api[0].data.repository.pullRequest.headRefOid=$c.base;J $c.api $api;[IO.File]::WriteAllText($continue,'continue');$r=End-Native $h
    Check ($r.exit-eq0-and(Test-Path (Join-Path $c.root 'body.txt'))) "publication bypass $($r.stderr)"
  }
  foreach($missing in @('-Pr','-ReviewedHead','-NewBase','-SourcePassReceiptIdentity','-IntegrationLane','-Worktree')){Control "helper-missing-$($missing.TrimStart('-'))" {
    $c=New-Case ('missing-'+$missing.TrimStart('-'));$a=Get-IntegrationHelperArguments 907962 $c.head $c.base 'ABSENT_REVIEW_REQUIRED' '' 'synthetic-missing' $c.repo $c.runtime $c.history
    $index=[Array]::IndexOf($a,$missing);Check ($index-ge0) 'argument inventory';$a=@(for($i=0;$i-lt$a.Count;$i++){if($i-ne$index-and$i-ne$index+1){$a[$i]}})
    $r=Run-Native $a[3] @($a|Select-Object -Skip 4) (Join-Path $c.root 'native-parameter-stop')
    Check ($r.exit-ne0-and$r.stderr-match'mandatory parameters|NonInteractive'-and(N $c.repo @('rev-parse','HEAD'))-ceq$c.head-and[IO.File]::ReadAllText($c.history)-ceq$c.historySeed) "missing $missing native binding"
    # The same measurement is present in candidate and bypass. Only the one
    # mandatory declaration differs; native parameter binding owns the guard.
    $parameterName=$missing.TrimStart('-');$helperSource=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'rebase-integration.ps1'))
    $declaration=@($helperSource-split"`r?`n"|Where-Object{$_-match('\$'+[regex]::Escape($parameterName)+'[,\s]')-and$_.Contains('[Parameter(Mandatory)]')})
    Check ($declaration.Count-eq1) "single mandatory declaration $parameterName"
    $subject=Split-Path -Parent (New-Subject ("mandatory-"+$parameterName) 'rebase-integration.ps1' $declaration[0] $declaration[0].Replace('[Parameter(Mandatory)]',''))
    $marker=Join-Path $c.root 'helper-body-entered';$probe="[IO.File]::WriteAllText('$($marker.Replace("'","''"))','entered')`n"
    $entry='$root = [IO.Path]::GetFullPath($Worktree).TrimEnd(''\'',''/'')'
    Check ($helperSource.Contains($entry)) 'exact helper entry instrumentation'
    $candidateHelper=Join-Path $subject 'candidate-helper.ps1';[IO.File]::WriteAllText($candidateHelper,$helperSource.Replace($entry,$probe+$entry))
    $bypassHelper=Join-Path $subject 'rebase-integration.ps1';$mutantSource=[IO.File]::ReadAllText($bypassHelper);[IO.File]::WriteAllText($bypassHelper,$mutantSource.Replace($entry,$probe+$entry))
    $candidate=Run-Native $candidateHelper @($a|Select-Object -Skip 4) (Join-Path $c.root 'instrumented-candidate')
    Check ($candidate.exit-ne0-and-not(Test-Path $marker)) "mandatory candidate body entered $parameterName"
    $bypass=Run-Native $bypassHelper @($a|Select-Object -Skip 4) (Join-Path $c.root 'single-guard-bypass')
    Check (Test-Path $marker) "mandatory bypass did not enter actual helper body $parameterName $($bypass.stderr)"
  }}
  function New-RetainedCase([string]$Name){
    $c=New-Case $Name
    [IO.File]::WriteAllText((Join-Path $c.repo 'local.txt'),'unpublished retained start');[void](N $c.repo @('add','.'));[void](N $c.repo @('commit','-qm','retained local'))
    # Reflogs have second precision; keep the native launch strictly after them.
    [Threading.Thread]::Sleep(1100)
    $wrapper=New-Wrapper $c (Join-Path $baselineRuntime 'dispatch-lane.ps1')
    $child=Join-Path $c.root 'native-harness.ps1';$helper=Join-Path $baselineRuntime 'rebase-integration.ps1'
    $template=@'
param($Config)
$ErrorActionPreference='Stop';$c=Get-Content -LiteralPath $Config -Raw|ConvertFrom-Json
[IO.File]::WriteAllText($c.body,'native parameter-stop body entered')
$body="& '__HELPER__' -PullRequest 907962"
$s=[Diagnostics.ProcessStartInfo]::new();$s.FileName=$c.pwsh;$s.UseShellExecute=$false;$s.CreateNoWindow=$true;$s.RedirectStandardOutput=$true;$s.RedirectStandardError=$true
foreach($a in @('-NoProfile','-NonInteractive','-Command',$body)){[void]$s.ArgumentList.Add($a)}
$p=[Diagnostics.Process]::Start($s);$o=$p.StandardOutput.ReadToEndAsync();$e=$p.StandardError.ReadToEndAsync();$p.WaitForExit();$code=$p.ExitCode;$output=$o.GetAwaiter().GetResult()+$e.GetAwaiter().GetResult();$p.Dispose()
@{type='item.completed';item=@{id='native-parameter';type='command_execution';command=('pwsh -Command "'+$body+'"');exit_code=$code;aggregated_output=$output}}|ConvertTo-Json -Depth 5 -Compress
'{"type":"turn.completed"}'
exit 0
'@
    [IO.File]::WriteAllText($child,$template.Replace('__HELPER__',$helper.Replace("'","''")))
    $r=Run-Native (Join-Path $baselineRuntime 'landed-integration-dispatch.ps1') (Producer-Args $c $wrapper -Old) (Join-Path $c.root 'native-retained-start')
    Check ($r.exit-ne0-and$r.stderr.Contains('INTEGRATION_DISPATCH_START_ACK_UNKNOWN')) "retained native mismatch $($r.stderr)"
    $ackPath=@(Get-ChildItem $c.runtime -Filter 'dispatch-start-*.json')[0].FullName;$ack=Read-RebaseJson $ackPath
    $specPath=Join-Path $c.runtime "watchdog-lane-$($ack.label).json";$spec=Read-RebaseJson $specPath
    Check ($spec.state-ceq'exited'-and$spec.exitCode-eq0-and$ack.head-cne$c.head) 'native exited0 mismatching start'
    return @{c=$c;ackPath=$ackPath;ack=$ack;specPath=$specPath;spec=$spec;wrapper=$wrapper}
  }
  Control 'retained-exited0-parameter-stop-double-replay' {
    $f=New-RetainedCase 'retained-positive';$c=$f.c;$sources=@($f.ackPath,$f.specPath,$f.spec.partialReportPath,$f.spec.originalPromptPath,$c.history)
    $later=$c.node|ConvertTo-Json -Depth 5|ConvertFrom-Json -DateKind String
    $later.number=[long]907963;$later.headRefName='synthetic/later-controller';$later.worktree=Join-Path $c.root 'missing-controller';$later.files.nodes[0].path='.orchestrator/synthetic-controller.ps1';$later.mergeStateStatus='DIRTY'
    $c.census.openPullRequests.nodes=@($c.node,$later);$c.census.openPullRequests.totalCount=[long]2;J (Join-Path $c.root 'census.json') $c.census
    Write-SyntheticIntegrationEligibility $c.history @($later)
    $before=@{};foreach($path in $sources){$before[$path]=Get-RebaseHash ([IO.File]::ReadAllBytes($path))}
    $r=Run-Native (Join-Path $PSScriptRoot 'landed-integration-dispatch.ps1') (Producer-Args $c $f.wrapper) (Join-Path $c.root 'later-census-refusal')
    Check ($r.exit-ne0-and$r.stderr.Contains('CENSUS_UNKNOWN_WORKTREE_907963')-and@(Get-ChildItem $c.runtime -Filter 'integration-start-observation-*.json').Count-eq0) 'later census refusal published an early retained observation'
    $refusedPlan=@(Get-ChildItem $c.runtime -Filter 'integration-plan-*.json'|ForEach-Object{Read-RebaseJson $_.FullName}|Where-Object{$_.targets.Count-eq2})
    Check ($refusedPlan.Count-eq1-and$refusedPlan[0].targets[0].action-ceq'RETAINED_START'-and$refusedPlan[0].targets[1].action-ceq'MISSING_WORKTREE') 'retained-start complete refused plan lost'
    $c.census.openPullRequests.nodes=@($c.node);$c.census.openPullRequests.totalCount=[long]1;J (Join-Path $c.root 'census.json') $c.census
    $r=Run-Native (Join-Path $PSScriptRoot 'landed-integration-dispatch.ps1') (Producer-Args $c $f.wrapper) (Join-Path $c.root 'observe-one')
    Check ($r.exit-eq0-and$r.stdout.Contains('EXITED_START_MISMATCH')) "retained terminal $($r.stdout) $($r.stderr)"
    $observationPath=Join-Path $c.runtime "integration-start-observation-$($f.ack.requestIdentity).json";$first=[IO.File]::ReadAllText($observationPath)
    $r=Run-Native (Join-Path $PSScriptRoot 'landed-integration-dispatch.ps1') (Producer-Args $c $f.wrapper) (Join-Path $c.root 'observe-two')
    Check ($r.exit-eq0-and$r.stdout.Contains('EXITED_START_MISMATCH')-and[IO.File]::ReadAllText($observationPath)-ceq$first) 'double replay changed terminal'
    foreach($path in $sources){Check ((Get-RebaseHash ([IO.File]::ReadAllBytes($path)))-ceq$before[$path]) "retained bytes changed $path"}
    Check ((N $c.repo @('rev-parse','HEAD'))-ceq$f.ack.head-and@(Get-ChildItem $c.runtime -Filter 'dispatch-start-*.json').Count-eq1) 'retained replay moved/relaunched'
    $o=Read-RebaseJson $observationPath;Check ($o.model-ceq'gpt-5.6-terra'-and$o.integrationResult-eq$false-and[datetimeoffset]$o.observedAt-ge[datetimeoffset]$f.spec.updatedAt) 'historical observation backdated or reattributed' # historical fixture
    $o|Add-Member unexpected $true;J $observationPath $o
    $r=Run-Native (Join-Path $PSScriptRoot 'landed-integration-dispatch.ps1') (Producer-Args $c $f.wrapper) (Join-Path $c.root 'crossed-observation')
    Check ($r.exit-eq0-and$r.stdout.Contains('RETAINED_START_PENDING')) 'extra observation key accepted'
  }
  foreach($state in @('live','reused','missing-spec','crossed-launch','crossed-route','truncated','additional-command','git-moved','exit-nonzero')){Control "retained-$state-pending" {
    $f=New-RetainedCase "retained-$state";$c=$f.c
    switch($state){
      live{$f.spec.launcherPid=[long]$PID;$f.spec.launcherStartIdentity=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o');J $f.specPath $f.spec}
      reused{$f.spec.launcherPid=[long]$PID;J $f.specPath $f.spec}
      'missing-spec'{Move-Item -LiteralPath $f.specPath -Destination ($f.specPath+'.retained')}
      'crossed-launch'{$f.spec.launchId=[guid]::NewGuid().ToString();J $f.specPath $f.spec}
      'crossed-route'{$rows=@(Get-Content $c.history|ForEach-Object{$_|ConvertFrom-Json -DateKind String});@($rows|Where-Object{$_.dispatchRoutingSchema-cin@('watchdog-dispatch-routing/v1','watchdog-dispatch-routing/v2','watchdog-dispatch-routing/v3')})[0].head=$c.head;[IO.File]::WriteAllLines($c.history,[string[]]@($rows|ForEach-Object{$_|ConvertTo-Json -Depth 8 -Compress}))}
      truncated{$raw=[IO.File]::ReadAllText($f.spec.partialReportPath);[IO.File]::WriteAllText($f.spec.partialReportPath,$raw.TrimEnd())}
      'additional-command'{$rows=@(Get-Content $f.spec.partialReportPath|ForEach-Object{$_|ConvertFrom-Json});$rows[0].item.command='pwsh -Command "git status; git rebase main"';[IO.File]::WriteAllLines($f.spec.partialReportPath,[string[]]@($rows|ForEach-Object{$_|ConvertTo-Json -Depth 5 -Compress}))}
      'git-moved'{[IO.File]::WriteAllText((Join-Path $c.repo 'later.txt'),'later');[void](N $c.repo @('add','.'));[void](N $c.repo @('commit','-qm','later author'))}
      'exit-nonzero'{$f.spec.exitCode=[long]1;J $f.specPath $f.spec}
    }
    $r=Run-Native (Join-Path $PSScriptRoot 'landed-integration-dispatch.ps1') (Producer-Args $c $f.wrapper) (Join-Path $c.root 'candidate')
    Check ($r.exit-eq0-and$r.stdout.Contains('RETAINED_START_PENDING')-and@(Get-ChildItem $c.runtime -Filter 'integration-start-observation-*.json').Count-eq0-and@(Get-ChildItem $c.runtime -Filter 'dispatch-start-*.json').Count-eq1) "retained $state escaped pending $($r.stdout) $($r.stderr)"
  }}
  Control 'retained-transcript-candidate-and-independent-bypass' {
    $f=New-RetainedCase 'retained-transcript-bypass';$c=$f.c;$rows=@(Get-Content $f.spec.partialReportPath|ForEach-Object{$_|ConvertFrom-Json});$rows[0].item.command='pwsh -Command "git status; git rebase main"';[IO.File]::WriteAllLines($f.spec.partialReportPath,[string[]]@($rows|ForEach-Object{$_|ConvertTo-Json -Depth 5 -Compress}))
    $r=Run-Native (Join-Path $PSScriptRoot 'landed-integration-dispatch.ps1') (Producer-Args $c $f.wrapper) (Join-Path $c.root 'candidate');Check ($r.exit-eq0-and$r.stdout.Contains('RETAINED_START_PENDING')) 'transcript candidate accepted extra effects'
    $mutant=New-Subject 'retained-transcript' 'integration-dispatch-contract.ps1' '    Assert-IntegrationParameterStopTranscript ([IO.File]::ReadAllText($spec.partialReportPath))' '    # independently omitted complete transcript guard'
    $r=Run-Native (Join-Path (Split-Path -Parent $mutant) 'landed-integration-dispatch.ps1') (Producer-Args $c $f.wrapper) (Join-Path $c.root 'bypass')
    Check ($r.exit-eq0-and$r.stdout.Contains('EXITED_START_MISMATCH')) "transcript bypass did not expose unsupported observation $($r.stdout) $($r.stderr)"
  }
  Control 'native-probe-exit-candidate-and-bypass' {
    $dir=Join-Path $caseRoot 'native-exit';New-Item -ItemType Directory $dir|Out-Null
    $runner=Join-Path $dir 'candidate.ps1';$contract=Join-Path $PSScriptRoot 'integration-dispatch-contract.ps1'
    $body='. '''+$contract.Replace("'","''")+''';Invoke-IntegrationProbe '''+$pwsh.Replace("'","''")+''' @(''-NoProfile'',''-NonInteractive'',''-Command'',''Write-Output plausible; exit 23'')'
    [IO.File]::WriteAllText($runner,$body);$r=Run-Native $runner @() (Join-Path $dir 'candidate')
    Check ($r.exit-ne0-and$r.stderr.Contains('exit=23')) 'native nonzero plausible output accepted'
    $old='    if ($process.ExitCode -ne 0) { throw "INTEGRATION_INPUT_UNKNOWN: $Executable exit=$($process.ExitCode) $($err.Result.Trim())" }'
    $mutant=New-Subject 'native-exit' 'integration-dispatch-contract.ps1' $old '    # independently omitted native exit guard'
    [IO.File]::WriteAllText($runner,$body.Replace($contract.Replace("'","''"),$mutant.Replace("'","''")))
    $r=Run-Native $runner @() (Join-Path $dir 'bypass');Check ($r.exit-eq0-and$r.stdout.Trim()-ceq'plausible') 'native exit bypass did not discriminate'
  }
  Control 'fresh-v3-request-reader-and-unavailable-executable' {
    $c=New-Case 'fresh-v3-reader';$req=Request $c
    $runner=Launcher-Runner $c $req (Join-Path $PSScriptRoot 'dispatch-lane.ps1') @('codex','gpt-6-astra','high',7,'override-Todd') @('ExecutablePath',(Join-Path $c.root 'unavailable-author.exe'))
    $r=Run-Native $runner @() (Join-Path $c.root 'unavailable');Check ($r.exit-ne0-and(Zero-Effects $c)) 'unavailable eligible executable launched'
    $runner=Launcher-Runner $c $req (Join-Path $PSScriptRoot 'dispatch-lane.ps1');$r=Run-Native $runner @() (Join-Path $c.root 'fresh');Check ($r.exit-eq0) "fresh v3 native $($r.stderr)"
    $ackPath=Join-Path $c.runtime "dispatch-start-$($req.requestIdentity).json"
    $observation=Get-RetainedIntegrationStart $ackPath $req.requestIdentity $c.node $c.repo $c.runtime $c.history
    J (Join-Path $c.root 'matching-observation.json') $observation
    Check ($observation.action-ceq'RETAINED_STARTED') "matching v3 native reader $($observation.reason)"
    $ackBytes=[IO.File]::ReadAllBytes($ackPath);$routingAck=Read-RebaseJson $ackPath
    foreach($field in @('policyGeneration','registryAuthorityDigest','family','slot','usedLastKnownGood')){
      $partialAck=$routingAck.PSObject.Copy();$partialAck.PSObject.Properties.Remove($field);J $ackPath $partialAck
      $partialObservation=Get-RetainedIntegrationStart $ackPath $req.requestIdentity $c.node $c.repo $c.runtime $c.history
      Check ($partialObservation.action-ceq'RETAINED_START_PENDING') "partial retained routing evidence admitted $field"
    }
    $crossedAck=$routingAck.PSObject.Copy();$crossedAck.slot='codex.primary';J $ackPath $crossedAck
    $crossedObservation=Get-RetainedIntegrationStart $ackPath $req.requestIdentity $c.node $c.repo $c.runtime $c.history
    Check ($crossedObservation.action-ceq'RETAINED_START_PENDING') 'crossed retained routing evidence admitted'
    [IO.File]::WriteAllBytes($ackPath,$ackBytes)
    $specPath=Join-Path $c.runtime "watchdog-lane-$($req.label).json";$spec=Read-RebaseJson $specPath
    $spec.integrationRequest|Add-Member unknown 'refused';J $specPath $spec
    $observation=Get-RetainedIntegrationStart $ackPath $req.requestIdentity $c.node $c.repo $c.runtime $c.history
    Check ($observation.action-ceq'RETAINED_START_PENDING') 'v3 nested extra accepted'
    $r=Run-Native (Join-Path $PSScriptRoot 'lane-stall-watchdog.ps1') @('-Label',$req.label,'-RuntimeRoot',$c.runtime,'-HistoryPath',$c.history) (Join-Path $c.root 'watchdog-crossed')
    Check ($r.exit-ne0-and$r.stderr.Contains('INTEGRATION_REQUEST_INVALID')) 'watchdog accepted changed request contract'
  }
  foreach($state in @('extra','path','moved-request')){Control "request-$state-native" {
    $c=New-Case "request-$state";$req=Request $c
    if($state-ceq'extra'){$req.extra=$true;J (Join-Path $c.runtime "integration-request-$($req.label).json") $req}
    if($state-ceq'path'){$req.runtimeRoot=$c.root;J (Join-Path $c.runtime "integration-request-$($req.label).json") $req}
    if($state-ceq'moved-request'){
      $entered=Join-Path $c.root 'entered';$continue=Join-Path $c.root 'continue';$runner=Launcher-Runner $c $req (Join-Path $PSScriptRoot 'dispatch-lane.ps1') @('codex','gpt-6-astra','high',7,'override-Todd') @('IntegrationPreflightObservedPath',$entered,'IntegrationPreflightContinuePath',$continue)
      $h=Begin-Native $runner @() (Join-Path $c.root 'candidate');$deadline=[datetime]::UtcNow.AddSeconds(15)
      while(-not(Test-Path $entered)){if($h.p.HasExited-or[datetime]::UtcNow-ge$deadline){throw 'request barrier not reached'};[Threading.Thread]::Sleep(25)}
      $req.newBase=$c.head;J (Join-Path $c.runtime "integration-request-$($req.label).json") $req;[IO.File]::WriteAllText($continue,'continue');$r=End-Native $h
    }else{$r=Run-Native (Launcher-Runner $c $req (Join-Path $PSScriptRoot 'dispatch-lane.ps1')) @() (Join-Path $c.root 'candidate')}
    Check ($r.exit-ne0-and$r.stderr.Contains('INTEGRATION_REQUEST')-and(Zero-Effects $c)) "request $state escaped native boundary"
    if($state-ceq'moved-request'){
      $req.newBase=$c.base;J (Join-Path $c.runtime "integration-request-$($req.label).json") $req;Remove-Item -LiteralPath $entered,$continue
      $old="    if ((Get-RebaseRecordIdentity (Read-RebaseJson `$IntegrationTargetPath)) -cne (Get-RebaseRecordIdentity `$integrationTarget)) { throw 'INTEGRATION_REQUEST_MOVED' }"
      $mutant=New-Subject 'request-moved' 'dispatch-lane.ps1' $old '    # independently omitted request immutability guard'
      $runner=Launcher-Runner $c $req $mutant @('codex','gpt-6-astra','high',7,'override-Todd') @('IntegrationPreflightObservedPath',$entered,'IntegrationPreflightContinuePath',$continue)
      $h=Begin-Native $runner @() (Join-Path $c.root 'bypass');$deadline=[datetime]::UtcNow.AddSeconds(15)
      while(-not(Test-Path $entered)){if($h.p.HasExited-or[datetime]::UtcNow-ge$deadline){throw 'request bypass barrier not reached'};[Threading.Thread]::Sleep(25)}
      $req.newBase=$c.head;J (Join-Path $c.runtime "integration-request-$($req.label).json") $req;[IO.File]::WriteAllText($continue,'continue');$r=End-Native $h
      Check ($r.exit-eq0-and(Test-Path (Join-Path $c.root 'body.txt'))) "changed request bypass did not expose stale in-memory launch $($r.stderr)"
    }
  }}
  Control 'native-v3-watchdog-propagation-and-no-fallback' {
    $c=New-Case 'watchdog-v3';$req=Request $c;$runner=Launcher-Runner $c $req (Join-Path $PSScriptRoot 'dispatch-lane.ps1')
    [IO.File]::WriteAllText((Join-Path $c.root 'body.ps1'),'param($Marker);[IO.File]::WriteAllText($Marker,''entered'');Write-Output ''{"type":"item.completed"}'';[Console]::Error.WriteLine(''stream disconnected'');exit 17')
    $r=Run-Native $runner @() (Join-Path $c.root 'native-death');Check ($r.exit-eq17) "native watchdog death $($r.stderr)"
    $wrapper=New-Wrapper $c (Join-Path $PSScriptRoot 'dispatch-lane.ps1')
    $r=Run-Native (Join-Path $PSScriptRoot 'lane-stall-watchdog.ps1') @('-Label',$req.label,'-RuntimeRoot',$c.runtime,'-HistoryPath',$c.history,'-DispatchScript',$wrapper,'-IntegrationAuthorityFixturePath',$c.api,'-SynchronousDispatch') (Join-Path $c.root 'watchdog')
    Check ($r.exit-eq0-and$r.stdout.Contains('RELAUNCHED')) "watchdog native relaunch $($r.stdout) $($r.stderr)"
    $specs=@(Get-ChildItem $c.runtime -Filter 'watchdog-lane-*.json'|ForEach-Object{Read-RebaseJson $_.FullName})
    $resumed=@($specs|Where-Object{$_.relaunchCount-eq1})
    Check ($resumed.Count-eq1-and$resumed[0].schemaVersion-ceq'watchdog-lane/v3'-and$resumed[0].integrationRequest.label-ceq$resumed[0].label-and$resumed[0].model-ceq'gpt-6-astra'-and$resumed[0].row-eq7-and$resumed[0].placement-ceq'override-Todd') 'watchdog lost fixed request/configuration'
    $prompt=[IO.File]::ReadAllText($resumed[0].originalPromptPath);Check ($prompt.Contains($resumed[0].label)-and$prompt.Contains("'-IntegrationLane'")) 'watchdog omitted new label helper arguments'
    $c2=New-Case 'watchdog-unavailable';$req2=Request $c2;$runner=Launcher-Runner $c2 $req2 (Join-Path $PSScriptRoot 'dispatch-lane.ps1')
    [IO.File]::WriteAllText((Join-Path $c2.root 'body.ps1'),'param($Marker);Write-Output ''{"type":"item.completed"}'';[Console]::Error.WriteLine(''provider quota exhausted'');exit 17')
    $r=Run-Native $runner @() (Join-Path $c2.root 'native-quota');Check ($r.exit-eq17) 'native quota fixture'
    $r=Run-Native (Join-Path $PSScriptRoot 'lane-stall-watchdog.ps1') @('-Label',$req2.label,'-RuntimeRoot',$c2.runtime,'-HistoryPath',$c2.history) (Join-Path $c2.root 'watchdog')
    Check ($r.exit-eq0-and$r.stdout.Contains('NO_QUALIFIED_FALLBACK')-and@(Get-ChildItem $c2.runtime -Filter 'watchdog-lane-*.json').Count-eq1) 'unavailable integration author fell back'
  }
  Control 'live-owner-publication-candidate-and-bypass' {
    $c=New-Case 'live-owner';$req=Request $c;$entered=Join-Path $c.root 'entered';$continue=Join-Path $c.root 'continue';$release=Join-Path $c.root 'owner-release'
    $runner=Launcher-Runner $c $req (Join-Path $PSScriptRoot 'dispatch-lane.ps1') @('codex','gpt-6-astra','high',7,'override-Todd') @('IntegrationPreflightObservedPath',$entered,'IntegrationPreflightContinuePath',$continue)
    $target=Begin-Native $runner @() (Join-Path $c.root 'target');$deadline=[datetime]::UtcNow.AddSeconds(15)
    while(-not(Test-Path $entered)){if($target.p.HasExited-or[datetime]::UtcNow-ge$deadline){throw 'owner-race target barrier missing'};[Threading.Thread]::Sleep(25)}
    $ownerReq=Request $c 'synthetic-owner';$ownerReq.requestIdentity='d'*64;J (Join-Path $c.runtime 'integration-request-synthetic-owner.json') $ownerReq
    $ownerRunner=Launcher-Runner $c $ownerReq (Join-Path $PSScriptRoot 'dispatch-lane.ps1')
    [IO.File]::WriteAllText((Join-Path $c.root 'body.ps1'),'Write-Output ''{"type":"item.completed"}'';while(-not(Test-Path -LiteralPath '''+$release.Replace("'","''")+''')){[Threading.Thread]::Sleep(25)}')
    $owner=Begin-Native $ownerRunner @() (Join-Path $c.root 'owner')
    try{
      $deadline=[datetime]::UtcNow.AddSeconds(15);$ownerAck=Join-Path $c.runtime ('dispatch-start-'+('d'*64)+'.json')
      while(-not(Test-Path $ownerAck)){if($owner.p.HasExited-or[datetime]::UtcNow-ge$deadline){throw 'native owner not published'};[Threading.Thread]::Sleep(25)}
      [IO.File]::WriteAllText($continue,'continue');$r=End-Native $target
      Check ($r.exit-ne0-and$r.stderr.Contains('INTEGRATION_OWNER_PENDING')-and-not(Test-Path (Join-Path $c.root 'body.txt'))-and-not$owner.p.HasExited) 'live owner not preserved at mutation boundary'
      $old='    if ($integrationOwners.health.status -cne ''ok'' -or @($integrationOwners.activeLanes | Where-Object { $_.branch -ceq $integrationTarget.branch }).Count) { throw "INTEGRATION_OWNER_PENDING diagnostics=$(Get-DispatchBlockingDiagnostics $integrationOwners)" }'
      $mutant=New-Subject 'live-owner' 'dispatch-lane.ps1' $old '    # independently omitted owner boundary guard'
      $runner=Launcher-Runner $c $req $mutant;$r=Run-Native $runner @() (Join-Path $c.root 'bypass')
      Check ($r.exit-eq0-and(Test-Path (Join-Path $c.root 'body.txt'))-and-not$owner.p.HasExited) "owner bypass did not expose concurrent body $($r.stderr)"
    }finally{[IO.File]::WriteAllText($release,'release');$ownerResult=End-Native $owner;Check ($ownerResult.exit-eq0) 'native owner release'}
  }
  Write-Output "ARTIFACT 7962 retained native Git/bare remotes/process stdout/stderr/numeric exits: $caseRoot"
  if($nativeFailures.Count){throw "7962 native controls failed: $($nativeFailures-join' | ')"}
}
