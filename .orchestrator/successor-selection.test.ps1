$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('successor-selection-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root) | Out-Null
. (Join-Path $PSScriptRoot 'routing-data-test-support.ps1')
$routingTestScope=Enter-RoutingDataTestScope
$oldRoutingRoot=$env:CHASE_SETS_ROUTING_DATA_ROOT;$oldRoutingLkg=$env:CHASE_SETS_ROUTING_LKG_PATH
function Check([bool]$Value,[string]$Message) { if (-not $Value) { throw $Message } }
function Refuses([scriptblock]$Body,[string]$Pattern) {
  $caught=$null;try { & $Body | Out-Null } catch { $caught="$_" }
  Check ($null-ne$caught-and$caught-match$Pattern) "Expected $Pattern; got $caught"
}
try {
  $models=@('gpt-6.1-sol','gpt-6-luna','claude-opus-5-5','claude-sonnet-5-5')
  $retired=@('gpt-5.6-sol','gpt-5.6-luna','claude-opus-5','claude-sonnet-5','gpt-6-sol')
  $sourceMatrix=Join-Path $PSScriptRoot 'controller-skills/model-routing/capability-matrix.json'
  $m=Get-Content $sourceMatrix -Raw|ConvertFrom-Json
  $routingFixture=New-RoutingMatrixFixture -Root (Join-Path $root 'routing-state') -Snapshot $m -BenchmarkRows @(New-RoutingCostBenchmarkRows)
  $env:CHASE_SETS_ROUTING_DATA_ROOT=$routingFixture.stateRoot;$env:CHASE_SETS_ROUTING_LKG_PATH=$routingFixture.lkgPath
  # AST-extracted filename functions run with the same synthetic registry set.
  $registryModelSet=@(foreach($family in $routingFixture.registry.families.Values){$family.current;foreach($old in $family.historical){$old}})
  foreach($model in $models){
    $configs=@($m.configs|Where-Object model -CEQ $model)
    Check ($configs.Count-eq5) "$model must have five qualified routing rungs"
    foreach($c in $configs){
      Check ($c.id-ceq"$model/$($c.effort)"-and$c.selectable-and$c.placement-ceq$(if($model-ceq'claude-sonnet-5-5'){'override-Todd'}else{'provisional'})) 'successor configuration identity/placement'
      Check (-not$c.PSObject.Properties['measured']-and-not$c.PSObject.Properties['adjudicated']) 'successor inherited generated evidence'
      foreach($d in $m.dimensions){
        $cell=$d.cells.PSObject.Properties[$c.id].Value
        Check ($null-ne$cell-and$null-eq$cell.score-and$null-eq$cell.src-and-not$cell.PSObject.Properties['veto']) 'successor inherited capability evidence/veto'
      }
    }
  }
  foreach($old in $retired){
    $configs=@($m.configs|Where-Object model -CEQ $old)
    Check ($configs.Count-gt0-and@($configs|Where-Object { $_.historicalOnly -cne $true -or $_.selectable -eq $true }).Count-eq0) 'retired configs lost or selectable'
    Check ($null-ne$m.effortLadders.PSObject.Properties[$old]) 'retired effort history lost'
  }
  Check ($m.coverage.configs-eq$m.configs.Count-and$m.coverage.cellsPossible-eq($m.configs.Count*$m.dimensions.Count)) 'coverage drift'
  $hostDimension=@($m.dimensions|Where-Object id -CEQ 'orchestration')[0]
  Check ($hostDimension.operatorSelectionRequired-eq$true-and-not$hostDimension.PSObject.Properties['neverProvisional']) 'host selection must remain operator-controlled without rejecting successor evidence labels'
  Check ($hostDimension.registeredHostArms.default-ceq'sol61-high (codex harness)') 'host metadata default is not versioned successor'
  Check (($hostDimension.registeredHostArms.registered -join '|')-ceq'sonnet55-high (claude harness)|opus55-high (claude harness)|astra-high (codex harness)') 'host metadata registered arms drift'
  Check ($hostDimension.governingEvidence.StartsWith('row-9 operator-controlled host selection;')-and$hostDimension.registeredHostArms.rule-ceq'Row-9 rotation is operator-controlled: only when Todd requests it, never on daily, session, or spend thresholds. Exactly one active orchestrator; the lease records identity only and never excludes a new host on freshness.') 'host metadata reinstates automatic rotation or exclusion'
  Write-Output 'PASS successor empty evidence, retired history, effort ladders and coverage'
  $snapshot=$m.benchmarkRebalance20260928
  Check ($snapshot.fetchedAt-ceq'2026-09-28'-and$snapshot.configurations.Count-eq14-and$snapshot.basis-match'v4.3.2') 'September 28 authored snapshot missing or wrong benchmark version'
  Check (@($snapshot.configurations|Where-Object {$_.id-like'claude-*'-and-not$_.defaultProviderFallback}).Count-eq0) 'Claude Default Fallback limitation lost'
  $medium=@($snapshot.configurations|Where-Object id -CEQ 'claude-sonnet-5-5/medium')[0]
  Check ($medium.index-eq40.7-and$medium.terminalBench4Percent-eq29.8-and$medium.firstAnswerTokenSeconds-eq0.71) 'Sonnet medium benchmark snapshot changed'
  $quota=$snapshot.quota
  Check (($quota.rows-join',')-ceq'3,13'-and$quota.challenger-ceq'claude-sonnet-5-5/high'-and$quota.incumbent-ceq'claude-opus-5-5/medium'-and$quota.placement-ceq'provisional'-and$quota.determinateOutcomesPerRow-eq20-and$quota.mechanicalFailureStop-eq2) 'Sonnet quota identity, scope, placement or stopping rule drift'
  Check ($snapshot.officialSonnet.inputUsdPerMTok-eq2-and$snapshot.officialSonnet.outputUsdPerMTok-eq10-and$snapshot.officialSonnet.cacheReadUsdPerMTok-eq0.2-and$snapshot.officialSonnet.cacheWrite5mUsdPerMTok-eq2.5-and$snapshot.officialSonnet.cacheWrite1hUsdPerMTok-eq4) 'verified Sonnet prices drift'
  $skill=Get-Content (Join-Path $PSScriptRoot 'controller-skills/model-routing/SKILL.md') -Raw
  foreach($row in @(3,13)){
    $rowText=@($skill-split"`n"|Where-Object {$_-match"^\| $row \|"})[0]
    Check ($rowText-match'every third Claude dispatch otherwise going to Opus 5.5 medium'-and$rowText-match"n=20 determinate row-$row outcomes \(provisional\)"-and$rowText-match"no worse than Opus 5.5 medium on row $row once both have n>=20"-and$rowText-match'two consecutive mechanical failures') "row $row lacks the written quota contract"
  }
  Check ($skill-notmatch'UNVERIFIED') 'unverified Sonnet price placeholder remains'
  Write-Output 'PASS September 28 authored benchmark snapshot, verified prices and written same-row challenger quotas'

  $repo=Join-Path $root 'repo'
  & git init --quiet $repo
  & git -C $repo -c user.name=Synthetic -c user.email=synthetic@example.invalid commit --allow-empty -m synthetic --quiet
  Check ($LASTEXITCODE-eq0) 'synthetic git fixture'
  $prompt=Join-Path $root 'prompt.txt';[IO.File]::WriteAllText($prompt,'Synthetic routing test; never launch a model.')
  $launch=Join-Path $PSScriptRoot 'dispatch-lane.ps1'
  $launchArgs=@{Effort='high';LaneRole='implementation';Row=4;Placement='provisional';PromptFile=$prompt;Worktree=$repo;Label='synthetic-successor';DryRun=$true;ExecutablePath=(Get-Process -Id $PID).Path;TestRuntimeRoot=$root;TestTempRoot=$root}
  foreach($model in $models){
    $harness=if($model-like'claude-*'){'claude'}else{'codex'}
    $launchArgs.Placement=if($model-ceq'claude-sonnet-5-5'){'override-Todd'}else{'provisional'}
    $launchArgs.Row=if($model-ceq'claude-sonnet-5-5'){3}else{4}
    # Harness effort admission is distinct from row-specific implementation eligibility.
    $launchArgs.LaneRole=if($model-ceq'claude-sonnet-5-5'){'planning'}else{'implementation'}
    foreach($effort in @('low','medium','high','xhigh','max')){
      $launchArgs.Effort=$effort
      $plan=& $launch @launchArgs -Harness $harness -Model $model|ConvertFrom-Json
      Check (@($plan.arguments)-ccontains$model) 'exact successor not forwarded'
      $expected=if($harness-ceq'codex'){"model_reasoning_effort=$effort"}else{$effort}
      Check (@($plan.arguments)-ccontains$expected) 'effort not forwarded'
    }
    foreach($effort in @('minimal','none','ultra')){
      $launchArgs.Effort=$effort;Refuses { & $launch @launchArgs -Harness $harness -Model $model } 'EFFORT_NOT_ADMITTED|ValidateSet|does not belong'
    }
    $launchArgs.Effort='high';$launchArgs.Placement='measured'
    Refuses { & $launch @launchArgs -Harness $harness -Model $model } 'successor placement is (provisional|override-Todd)'
    if($model-ceq'claude-sonnet-5-5'){
      $launchArgs.Placement='override-todd';Refuses { & $launch @launchArgs -Harness $harness -Model $model } 'successor placement is override-Todd'
      $launchArgs.Placement='override-Todd'
      $launchArgs.LaneRole='implementation'
      foreach($row in @(1,2,4,5,6,7,8,9,11,12,14,15)){ $launchArgs.Row=$row;Refuses { & $launch @launchArgs -Harness $harness -Model $model } 'only on rows 3, 10 and 13' }
      foreach($row in @(3,10,13)){
        $launchArgs.Row=$row;$launchArgs.Placement=if($row-eq10){'override-Todd'}else{'provisional'}
        $plan=& $launch @launchArgs -Harness $harness -Model $model|ConvertFrom-Json
        Check (@($plan.arguments)-ccontains$model) "Sonnet 5.5 high row $row refused"
        foreach($badPlacement in @('measured','Provisional','override-todd',$(if($row-eq10){'provisional'}else{'override-Todd'}))){
          $launchArgs.Placement=$badPlacement;Refuses { & $launch @launchArgs -Harness $harness -Model $model } 'successor placement is'
        }
        $launchArgs.Placement='override-Todd'
        foreach($badEffort in @('low','xhigh','max',$(if($row-eq10){'medium'}else{'high'}))){
          $launchArgs.Effort=$badEffort;Refuses { & $launch @launchArgs -Harness $harness -Model $model } 'implementation requires|successor placement is'
        }
        $launchArgs.Effort='high'
      }
      foreach($role in @('review','planning')){
        $launchArgs.LaneRole=$role;$launchArgs.Row=0;$launchArgs.Effort='medium';$launchArgs.Placement='override-Todd'
        $plan=& $launch @launchArgs -Harness $harness -Model $model|ConvertFrom-Json
        Check ($plan.laneRole-ceq$role) "Sonnet Row 0 $role envelope refused"
      }
      $launchArgs.LaneRole='review'
      foreach($row in @(11,12)){$launchArgs.Row=$row;Refuses { & $launch @launchArgs -Harness $harness -Model $model } 'not an admitted.*reviewer'}
      $launchArgs.Row=0
      Refuses { & $launch @launchArgs -Harness $harness -Model $model -ReviewTarget controller } 'not an admitted.*reviewer'
    }
    $launchArgs.Placement='provisional';$launchArgs.Row=4;$launchArgs.LaneRole='implementation'
  }
  foreach($model in $retired+@('sol','gpt-6','gpt-6.1-sol-future','claude-opus-5-5-future')){
    $harness=if($model-like'claude-*'){'claude'}else{'codex'}
    Refuses { & $launch @launchArgs -Harness $harness -Model $model } 'EXPLICIT_HISTORICAL_OR_RETIRED_MODEL|EXPLICIT_MODEL_NOT_CURRENT'
  }
  Refuses { & $launch @launchArgs -Harness claude -Model gpt-6.1-sol } 'MODEL_HARNESS_MISMATCH'
  Write-Output 'PASS exact successor DryRun forwarding and retired/alias/effort/harness admission controls'

  foreach($entry in @(
    @(3,'claude-opus-5-5','low'),@(3,'claude-opus-5-5','medium'),@(3,'claude-opus-5-5','high'),@(3,'gpt-6.1-sol','medium'),
    @(4,'claude-opus-5-5','medium'),@(5,'claude-opus-5-5','medium'),@(10,'claude-opus-5-5','medium'),
    @(13,'gpt-6.1-sol','medium'),@(13,'claude-opus-5-5','low'),@(13,'claude-opus-5-5','medium'),
    @(3,'claude-sonnet-5-5','medium'),@(13,'claude-sonnet-5-5','medium')
  )){
    $launchArgs.Row=$entry[0];$launchArgs.Effort=$entry[2];$launchArgs.Placement='override-Todd'
    $harness=if($entry[1]-like'claude-*'){'claude'}else{'codex'}
    $plan=& $launch @launchArgs -Harness $harness -Model $entry[1]|ConvertFrom-Json
    $expected=if($harness-ceq'codex'){"model_reasoning_effort=$($entry[2])"}else{$entry[2]}
    Check ($plan.harness-ceq$harness-and$plan.laneRole-ceq'implementation'-and@($plan.arguments)-ccontains$entry[1]-and@($plan.arguments)-ccontains$expected) 'benchmark policy route not admitted/forwarded by real dispatcher'
  }
  $launchArgs.Row=4;$launchArgs.Effort='high';$launchArgs.Placement='provisional'
  Write-Output 'PASS 12 benchmark policy dispatch plans preserve exact model, effort and harness'

  Import-Module (Join-Path $PSScriptRoot 'lease-contract.psm1') -Force -DisableNameChecking
  foreach($tuple in @(@('sol61-high','gpt-6.1-sol','codex'),@('opus55-high','claude-opus-5-5','claude'),@('sonnet55-high','claude-sonnet-5-5','claude'))){
    $lease=Join-Path $root "$($tuple[0]).json"
    $hostPlan=& (Join-Path $PSScriptRoot 'start-host-trial.ps1') -Arm $tuple[0] -Holder synthetic-successor-host -Lease $lease|Out-String
    Check ($hostPlan.Contains($tuple[1])-and-not(Test-Path $lease)) 'host arm identity or side effect'
    $at=[datetimeoffset]'2026-09-22T12:00:00Z'
    $oldModel=if($tuple[2]-ceq'codex'){'gpt-5.6-sol'}elseif($tuple[0]-ceq'sonnet55-high'){'claude-sonnet-5'}else{'claude-opus-5'}
    Refuses { Acquire-OrchestrationLease -Path $lease -Holder synthetic-old-host -Harness $tuple[2] -Model $oldModel -Effort high -NowUtc $at } 'retired|host-model-invalid'
    $historical=[ordered]@{version='orchestration-lease/v2';holder='synthetic-old-host';harness=$tuple[2];model=$oldModel;effort='high';acquiredAt='2026-09-22T12:00:00.000Z';renewedAt='2026-09-22T12:00:00.000Z'}
    [IO.File]::WriteAllText($lease,($historical|ConvertTo-Json -Compress))
    $historicalRead=Read-OrchestrationLease -Path $lease -ObservedAtUtc $at
    Check ($historicalRead.record.model-ceq$oldModel) "historical host identity invalidated ($oldModel status=$($historicalRead.status) diagnostics=$($historicalRead.diagnostics -join ','))"
    Refuses { Renew-OrchestrationLease -Path $lease -Holder synthetic-old-host -Harness $tuple[2] -Model $oldModel -Effort high -NowUtc $at.AddMinutes(1) } 'retired|host-model-invalid'
    $new=Acquire-OrchestrationLease -Path $lease -Holder synthetic-new-host -Harness $tuple[2] -Model $tuple[1] -Effort high -NowUtc $at.AddMinutes(2)
    Check ($new.record.model-ceq$tuple[1]) 'successor identity missing'
  }
  foreach($arm in @('sol-high','opus5-high','sonnet5-high')){Refuses { & (Join-Path $PSScriptRoot 'start-host-trial.ps1') -Arm $arm } 'ValidateSet|does not belong'}

  $history=Join-Path $root 'reviews.jsonl';$logger=Join-Path $PSScriptRoot 'log-event.ps1'
  foreach($model in $models){
    & $logger -Log dispatch -Kind review-complete -Issue 9900 -Pr 9901 -Model $model -AuthorModel gpt-6.1-sol -AuthorEffort medium -Effort high -Row 11 -Placement provisional -Outcome PASS -ReviewContract review-contract/v2 -CompleteSweep -ReviewedHead ('a'*40) -ReviewerAttempt "synthetic-$model" -AuthorAttempt synthetic-historical-author -Blocking 0 -Candidates 0 -NonBlocking 0 -RepairOwner none -OutFile $history -NoBoard|Out-Null
  }
  $r=& (Join-Path $PSScriptRoot 'review-head-reducer.ps1') -Pr 9901 -CurrentHead ('a'*40) -HistoryPath $history|ConvertFrom-Json
  Check ($r.state-ceq'authorized') 'historical/successor receipt readback failed'
  $historicalReceipt=Get-Content $history -Tail 1|ConvertFrom-Json
  $historicalReceipt.model='claude-sonnet-5'
  $historicalReceipt.authorModel='claude-sonnet-5'
  $historicalReceipt.reviewerAttempt='synthetic-retired-sonnet'
  $historicalPath=Join-Path $root 'historical-sonnet-review.jsonl'
  [IO.File]::WriteAllText($historicalPath,($historicalReceipt|ConvertTo-Json -Compress -Depth 20))
  $beforeHash=(Get-FileHash $historicalPath).Hash
  $r=& (Join-Path $PSScriptRoot 'review-head-reducer.ps1') -Pr 9901 -CurrentHead ('a'*40) -HistoryPath $historicalPath|ConvertFrom-Json
  Check ($r.state-ceq'authorized'-and(Get-FileHash $historicalPath).Hash-ceq$beforeHash) 'historical Sonnet receipt unreadable or rewritten'
  Write-Output 'PASS versioned host arms, pinned host identity, and historical/successor exact-head receipts'

  $transcripts=Join-Path $root 'transcripts';[IO.Directory]::CreateDirectory($transcripts)|Out-Null
  $ambiguousNames=@(
    '9920-sol6--high-sol61--medium','9921-sol61--medium-sol6--high',
    '9922-gpt-6-sol--high-gpt-6.1-sol--medium',
    '9923-gpt-6.1-sol--medium-gpt-6-sol--high',
    '9924-sol61--high-sol61--medium','9925-gpt-6.1-sol--high-sol61--medium'
  )
  foreach($name in @('9900-sol61--high','9901-gpt-6.1-sol--medium','9909-sol6--high','9902-luna6--medium','9903-gpt-6-luna--high','9904-sol-high','9905-gpt-6.1-sol-future','9906-sol6-future','9907-gpt-6-luna-future','9908-GPT-6-SOL--future','9912-gpt-6x1-sol--high','9913-sol610--high','9914-GPT-6.1-SOL--high')+$ambiguousNames){
    $p=Join-Path $transcripts "$name.jsonl"
    [IO.File]::WriteAllText($p,'{"type":"turn.completed","usage":{"input_tokens":100000,"output_tokens":10000}}')
    (Get-Item $p).LastWriteTimeUtc=[datetime]'2026-09-29T13:00:00Z'
  }
  $ledger=Join-Path $root 'ledger.jsonl'
  foreach($effort in @('low','medium','high','xhigh','max')){
    $name=if($effort-ceq'xhigh'){"9910-claude-sonnet-5-5--$effort"}else{"9910-sonnet55--$effort"}
    $p=Join-Path $transcripts "$name.jsonl"
    $terminal=if($effort-ceq'high'){'{"type":"turn.completed","usage":{"input_tokens":100000,"cached_input_tokens":20000,"output_tokens":10000}}'}else{'{"type":"result","total_cost_usd":7.25,"duration_ms":1000}'}
    [IO.File]::WriteAllText($p,('{"type":"system","subtype":"init","model":"claude-sonnet-5-5"}'+"`n"+$terminal))
    (Get-Item $p).LastWriteTimeUtc=[datetime]'2026-09-28T13:00:00Z'
  }
  $oldSonnet=Join-Path $transcripts '9911-sonnet5-medium-history.jsonl'
  [IO.File]::WriteAllText($oldSonnet,('{"type":"system","subtype":"init","model":"claude-sonnet-5"}'+"`n"+'{"type":"result","total_cost_usd":19,"duration_ms":1000}'))
  (Get-Item $oldSonnet).LastWriteTimeUtc=[datetime]'2026-09-22T13:00:00Z'
  $pricingCases=@(
    @{name='9930-sol61--high';model='gpt-6.1-sol';input=100000;read=100000;write=0;output=0;lower=0.01;upper=0.01;tier='short-exact'},
    @{name='9931-sol6--high';model='gpt-6-sol';input=100000;read=100000;write=0;output=0;lower=0.02;upper=0.02;tier='short-exact'},
    @{name='9932-sol61--high';model='gpt-6.1-sol';input=300000;read=300000;write=0;output=0;lower=0.03;upper=0.06;tier='request-tier-unknown-conservative-long'},
    @{name='9933-sol6--high';model='gpt-6-sol';input=300000;read=300000;write=0;output=0;lower=0.06;upper=0.12;tier='request-tier-unknown-conservative-long'},
    @{name='9934-sol61--high';model='gpt-6.1-sol';input=100000;read=20000;write=10000;output=10000;lower=0.267;upper=0.267;tier='short-exact'},
    @{name='9935-sol6--high';model='gpt-6-sol';input=100000;read=20000;write=10000;output=10000;lower=0.269;upper=0.269;tier='short-exact'},
    @{name='9936-sol61--high';model='gpt-6.1-sol';input=300000;read=20000;write=10000;output=10000;lower=0.667;upper=1.284;tier='request-tier-unknown-conservative-long'}
  )
  foreach($case in $pricingCases){
    $p=Join-Path $transcripts "$($case.name).jsonl"
    [IO.File]::WriteAllText($p,("{""type"":""turn.completed"",""usage"":{""input_tokens"":$($case.input),""cached_input_tokens"":$($case.read),""cache_write_input_tokens"":$($case.write),""output_tokens"":$($case.output)}}"))
    (Get-Item $p).LastWriteTimeUtc=[datetime]'2026-09-29T13:00:00Z'
  }
  & (Join-Path $PSScriptRoot 'cost-harvest.ps1') -TranscriptDir $transcripts -Ledger $ledger -Force|Out-Null
  $costs=@(Get-Content $ledger|ForEach-Object{$_|ConvertFrom-Json -DateKind String})
  foreach($case in $pricingCases){
    $cost=@($costs|Where-Object transcript -CEQ "$($case.name).jsonl")[0]
    Check ($cost.model-ceq$case.model-and$cost.pricingContextTier-ceq$case.tier-and$cost.usdLower-eq$case.lower-and$cost.usdUpper-eq$case.upper-and$cost.usd-eq$case.upper) "billed cached pricing/bounds changed: $($case.name)"
    Check ($null-eq$cost.usdCurrentLower-and$null-eq$cost.usdCurrentUpper-and$null-eq$cost.usdCurrent-and$cost.routingCostSource-ceq'BENCHMARK_CONTEXT_CACHE_RATES_UNAVAILABLE') 'benchmark standard rates invented cache or long-context normalization'
  }
  foreach($cost in $costs){
    if($cost.transcript-match'^993[0-6]-'){continue}
    if($cost.transcript-match'future|gpt-6x1|sol610'-or$cost.transcript-cmatch'GPT-6\.1-SOL'-or$cost.transcript-replace'\.jsonl$',''-cin$ambiguousNames){Check ($null-eq$cost.model-and$null-eq$cost.usdCurrent) "unsupported or ambiguous selector attributed: $($cost.transcript) model=$($cost.model)";continue}
    if($cost.model-ceq'claude-sonnet-5-5'){
      $expected=if($cost.transcript-match'--high$|--high\.jsonl$'){0.264}else{7.25}
      Check ([math]::Abs($cost.usd-$expected)-lt0.00001) 'Sonnet 5.5 billed cache/native cost wrong'
      Check ($(if($expected-eq0.264){$null-eq$cost.usdCurrent}else{$cost.usdCurrent-eq$cost.usd})) 'Sonnet normalized unknown or native reported USD changed'
      if($expected-eq0.264){Check ($cost.billedPriceEffectiveUtc-match'^2026-09-28'-and$cost.currentPriceInPerM-eq2-and$cost.currentPriceOutPerM-eq10) 'Sonnet price era wrong'}
      continue
    }
    if($cost.model-ceq'claude-sonnet-5'){Check ($cost.usd-eq19-and$cost.usdCurrent-eq19) 'Sonnet 5 history repriced';continue}
    $expected=if($cost.model-ceq'gpt-6.1-sol'-or$cost.model-ceq'gpt-6-sol'){0.3}elseif($cost.model-ceq'gpt-6-luna'){0.015}elseif($cost.model-ceq'gpt-5.6-sol'){0.8}else{throw 'missing price identity'}
    Check ([math]::Abs($cost.usd-$expected)-lt0.00001-and$null-eq$cost.usdCurrent-and$cost.routingCostSource-ceq'BENCHMARK_CONTEXT_CACHE_RATES_UNAVAILABLE') 'new/legacy billed price or current unknown changed'
  }
  function Write-SyntheticNormalizedLedger([string]$Source,[string]$Destination) {
    # Matrix identity coverage uses independently labeled synthetic normalized
    # costs. Harvest assertions above and cost-routing-data.test.ps1 separately
    # prove that real missing price authority never becomes normalization.
    $rows=@(Get-Content -LiteralPath $Source | ForEach-Object { $_ | ConvertFrom-Json })
    foreach($r in $rows){if($null-ne$r.usd-and$null-eq$r.usdCurrent){$r.usdCurrent=$r.usd;$r.routingCostSource='synthetic-normalized-identity-fixture'}}
    [IO.File]::WriteAllLines($Destination,@($rows|ForEach-Object {$_|ConvertTo-Json -Compress -Depth 10}))
  }
  $matrixLedger=Join-Path $root 'synthetic-normalized-matrix-ledger.jsonl'
  Write-SyntheticNormalizedLedger $ledger $matrixLedger
  $matrix=Join-Path $root 'matrix.json';Copy-Item $sourceMatrix $matrix
  $dispatch=Join-Path $root 'dispatch.jsonl';[IO.File]::WriteAllText($dispatch,'')
  $ambiguousLedger=Join-Path $root 'ambiguous-ledger.jsonl'
  $ambiguousCosts=@($costs|Where-Object {($_.transcript-replace'\.jsonl$','')-cin$ambiguousNames})
  Check ($ambiguousCosts.Count-eq$ambiguousNames.Count) 'ambiguous control ledger incomplete'
  [IO.File]::WriteAllLines($ambiguousLedger,@($ambiguousCosts|ForEach-Object {$_|ConvertTo-Json -Compress -Depth 4}))
  $ambiguousMatrix=Join-Path $root 'ambiguous-matrix.json';Copy-Item $sourceMatrix $ambiguousMatrix
  & (Join-Path $PSScriptRoot 'matrix-refresh.ps1') -Matrix $ambiguousMatrix -CostLedger $ambiguousLedger -DispatchLog $dispatch|Out-Null
  $ambiguousRefresh=Get-Content $ambiguousMatrix -Raw|ConvertFrom-Json
  Check (@($ambiguousRefresh.configs|Where-Object {$_.model-ceq'gpt-6.1-sol'-and$_.PSObject.Properties['measured']}).Count-eq0) 'ambiguous names manufactured Sol 6.1 measured evidence'
  Check ($ambiguousRefresh.measuredAt.effortIdentity.byTranscriptName-eq0) 'ambiguous names supplied filename effort'
  $nativeDir=Join-Path $root 'native-identity';[IO.Directory]::CreateDirectory($nativeDir)|Out-Null
  $nativeName='9940-sol6--high-sol61--medium.jsonl'
  [IO.File]::WriteAllText((Join-Path $nativeDir $nativeName),('{"type":"system","subtype":"init","model":"gpt-6.1-sol"}' + "`n" + '{"type":"turn.completed","usage":{"input_tokens":100000,"output_tokens":0}}'))
  (Get-Item (Join-Path $nativeDir $nativeName)).LastWriteTimeUtc=[datetime]'2026-09-29T13:00:00Z'
  $nativeLedger=Join-Path $root 'native-ledger.jsonl'
  & (Join-Path $PSScriptRoot 'cost-harvest.ps1') -TranscriptDir $nativeDir -Ledger $nativeLedger -Force|Out-Null
  Check ((Get-Content $nativeLedger|ConvertFrom-Json).model-ceq'gpt-6.1-sol') 'exact native model lost to ambiguous filename'
  $nativeMatrixLedger=Join-Path $root 'synthetic-normalized-native-ledger.jsonl'
  Write-SyntheticNormalizedLedger $nativeLedger $nativeMatrixLedger
  $nativeMatrix=Join-Path $root 'native-matrix.json';Copy-Item $sourceMatrix $nativeMatrix
  & (Join-Path $PSScriptRoot 'matrix-refresh.ps1') -Matrix $nativeMatrix -CostLedger $nativeMatrixLedger -DispatchLog $dispatch|Out-Null
  Check (@((Get-Content $nativeMatrix -Raw|ConvertFrom-Json).configs|Where-Object {$_.model-ceq'gpt-6.1-sol'-and$_.PSObject.Properties['measured']}).Count-eq0) 'native model borrowed conflicting filename effort'
  [IO.File]::WriteAllText((Join-Path $nativeDir 'dispatch-log.jsonl'),('{"kind":"dispatch","transcript":"'+$nativeName+'","model":"gpt-6.1-sol","effort":"high"}'))
  $dispatchMatrix=Join-Path $root 'dispatch-matrix.json';Copy-Item $sourceMatrix $dispatchMatrix
  & (Join-Path $PSScriptRoot 'matrix-refresh.ps1') -Matrix $dispatchMatrix -CostLedger $nativeMatrixLedger -DispatchLog (Join-Path $nativeDir 'dispatch-log.jsonl')|Out-Null
  Check ((@((Get-Content $dispatchMatrix -Raw|ConvertFrom-Json).configs|Where-Object id -CEQ 'gpt-6.1-sol/high')[0]).measured.n-eq1) 'independent exact dispatch effort lost'
  foreach($spec in @(@('cost-harvest.ps1','Get-NameFacts'),@('matrix-refresh.ps1','Get-EffortFromTranscriptName'))){
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $spec[0]),[ref]$tokens,[ref]$errors)
    $wanted=$spec[1]
    $functions=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $wanted},$true))
    Check ($errors.Count-eq0-and$functions.Count-eq1) "cannot inspect filename grammar $wanted"
    . ([scriptblock]::Create($functions[0].Extent.Text))
  }
  # Complete union of both filename grammars. The Sol 6.1 synonyms use a
  # different effort from the anchor, so even their duplicate model is ambiguous.
  $modernTokens=@('gpt-6-astra','astra6','gpt-6.1-sol','sol61','gpt-6-sol','sol6','gpt-6-luna','luna6','claude-opus-5-5','opus55','claude-sonnet-5-5','sonnet55','claude-fable-5-1','fable51')
  $historicalCodexTokens=@('gpt-5.6-sol','gpt-5.6-terra','gpt-5.6-luna','sol','terra','luna')
  $legacyClaudeTokens=@('opus5','sonnet5','fable5','fable5.1','fable51')
  $selectorLabels=@($modernTokens|ForEach-Object { "${_}--high" }) + @($historicalCodexTokens+$legacyClaudeTokens|ForEach-Object { "${_}-high" })
  Check ($selectorLabels.Count-eq25) 'filename selector census incomplete'
  foreach($label in $selectorLabels){
    foreach($name in @("9888-synthetic-$label-sol61--medium.jsonl","9888-synthetic-sol61--medium-$label.jsonl")){
      Check (-not(Get-NameFacts $name).model-and-not(Get-EffortFromTranscriptName $name 'gpt-6.1-sol')) "filename grammars diverged: $name"
    }
  }
  Write-Output 'PASS complete Codex/Claude filename selector census in both orders'
  $legacyMixedCases=@(foreach($label in @('opus5-high','sonnet5-medium','fable5-high','fable5.1-high','fable51-high')){
    @{name="9888-synthetic-$label-sol61--medium";model=$null}
    @{name="9888-synthetic-sol61--medium-$label";model=$null}
  })
  $conflictCases=@(
    @{name='9950-sol6--high-sol61--medium';model=$null},
    @{name='9951-sol61--medium-sol6--high';model=$null},
    @{name='9952-sol-high-sol61--medium';model=$null},
    @{name='9953-sol6--high';model='gpt-6.1-sol'},
    @{name='9954-opus55--high-sol61--medium';model=$null},
    @{name='9955-sol6--high-sol61--medium';model=$null;dispatch='gpt-6.1-sol'},
    @{name='9957-gpt-6.1-sol--medium-gpt-6-sol--high';model=$null},
    @{name='9958-sol61--high-sol61--medium';model=$null},
    @{name='9959-sol61--medium-sol-high';model=$null},
    @{name='9960-gpt-5.6-sol-high-sol61--medium';model=$null},
    @{name='9961-sol61--medium-gpt-5.6-sol-high';model=$null},
    @{name='9962-claude-opus-5-5--high-sol61--medium';model=$null},
    @{name='9963-sol61--medium-claude-sonnet-5-5--high';model=$null},
    @{name='9964-claude-fable-5-1--high-sol61--medium';model=$null},
    @{name='9965-gpt-6x1-sol--high';model='gpt-6.1-sol'},
    @{name='9966-GPT-6.1-SOL--high';model='gpt-6.1-sol'},
    @{name='9967-sol610--high';model='gpt-6.1-sol'},
    @{name='9968-sol6-future--high';model='gpt-6.1-sol'}
  )
  foreach($case in @($conflictCases)+$legacyMixedCases){
    $dir=Join-Path $root $case.name;[IO.Directory]::CreateDirectory($dir)|Out-Null
    $file=$case.name+'.jsonl'
    $rows=@()
    if($case.model){$rows+='{"type":"system","subtype":"init","model":"'+$case.model+'"}'}
    $rows+='{"type":"turn.completed","usage":{"input_tokens":100000,"output_tokens":10000}}'
    $path=Join-Path $dir $file;[IO.File]::WriteAllLines($path,$rows)
    (Get-Item $path).LastWriteTimeUtc=[datetime]'2026-09-29T13:00:00Z'
    $caseDispatch=Join-Path $dir 'dispatch-log.jsonl'
    $dispatchRow=if($case.dispatch){'{"kind":"dispatch","transcript":"'+$file+'","model":"'+$case.dispatch+'"}'}else{''}
    [IO.File]::WriteAllText($caseDispatch,$dispatchRow)
    $caseLedger=Join-Path $dir 'cost-ledger.jsonl'
    & (Join-Path $PSScriptRoot 'cost-harvest.ps1') -TranscriptDir $dir -Ledger $caseLedger -Force|Out-Null
    $caseCost=Get-Content $caseLedger|ConvertFrom-Json
    $expectedModel=if($case.model){$case.model}elseif($case.dispatch){$case.dispatch}else{$null}
    Check ($caseCost.model-ceq$expectedModel) "conflicting filename supplied a model: $file"
    $caseMatrixLedger=Join-Path $dir 'synthetic-normalized-ledger.jsonl'
    Write-SyntheticNormalizedLedger $caseLedger $caseMatrixLedger
    $caseMatrix=Join-Path $dir 'matrix.json';Copy-Item $sourceMatrix $caseMatrix
    & (Join-Path $PSScriptRoot 'matrix-refresh.ps1') -Matrix $caseMatrix -CostLedger $caseMatrixLedger -DispatchLog $caseDispatch|Out-Null
    $result=Get-Content $caseMatrix -Raw|ConvertFrom-Json
    Check ($result.measuredAt.effortIdentity.byTranscriptName-eq0-and@($result.configs|Where-Object {$_.model-ceq'gpt-6.1-sol'-and$_.PSObject.Properties['measured']}).Count-eq0) "conflicting filename supplied successor effort: $file"
    if(-not$case.model-and-not$case.dispatch){Check (-not$result.measuredAt.byModel.PSObject.Properties['gpt-6.1-sol']) "conflicting filename supplied successor model sample: $file"}
    if($case.model){Check (@($result.measuredAt.byModel|Get-Member -MemberType NoteProperty -Name 'gpt-6.1-sol').Count-eq1) 'native model-level telemetry lost'}
  }
  Write-Output 'PASS isolated mixed-selector, historical, Claude, and native/model-effort conflicts'
  & (Join-Path $PSScriptRoot 'matrix-refresh.ps1') -Matrix $matrix -CostLedger $matrixLedger -DispatchLog $dispatch|Out-Null
  $refreshed=Get-Content $matrix -Raw|ConvertFrom-Json
  Check (@($costs|Where-Object model -CEQ 'gpt-6-sol').Count-eq4-and@($costs|Where-Object model -CEQ 'gpt-6.1-sol').Count-eq6) 'Sol 6.1 and historical Sol 6 transcript attribution crossed'
  foreach($authored in @('benchmarkRebalance20260923','benchmarkRebalance20260928','benchmarkRebalance20260929')){
    Check (($refreshed.$authored|ConvertTo-Json -Depth 30 -Compress)-ceq($m.$authored|ConvertTo-Json -Depth 30 -Compress)) "refresh rewrote authored $authored snapshot"
  }
  foreach($id in @('gpt-6.1-sol/high','gpt-6.1-sol/medium','gpt-6-sol/high','gpt-6-luna/high','gpt-6-luna/medium','gpt-5.6-sol/high')){
    $config=$refreshed.configs|Where-Object id -CEQ $id
    $expectedN=if($id-ceq'gpt-6.1-sol/high'){5}elseif($id-ceq'gpt-6-sol/high'){4}else{1}
    Check ($config.measured.n-eq$expectedN-and$config.measured.basis-ceq'model+effort') "effort attribution crossed versions: $id"
  }
  Check (-not($refreshed.configs|Where-Object id -CEQ 'gpt-6.1-sol/max').PSObject.Properties['measured']) 'unobserved effort inherited evidence'
  foreach($effort in @('low','medium','high','xhigh','max')){
    $config=$refreshed.configs|Where-Object id -CEQ "claude-sonnet-5-5/$effort"
    Check ($config.measured.n-eq1-and$config.measured.basis-ceq'model+effort') "Sonnet effort attribution missing/crossed: $effort"
  }
  $historicalConfig=$refreshed.configs|Where-Object id -CEQ 'claude-sonnet-5/medium'
  Check ($historicalConfig.measured.n-eq1-and$historicalConfig.measured.usdPerRun-eq19-and$historicalConfig.historicalOnly-and-not$historicalConfig.selectable) 'historical Sonnet evidence lost or transferred'
  $retiredConfig=@($refreshed.configs|Where-Object id -CEQ 'gpt-5.6-sol/high')[0]
  $retiredConfig|Add-Member -NotePropertyName selectable -NotePropertyValue $true
  [IO.File]::WriteAllText($matrix,($refreshed|ConvertTo-Json -Depth 100))
  Refuses { & (Join-Path $PSScriptRoot 'matrix-refresh.ps1') -Matrix $matrix -CostLedger $ledger -DispatchLog $dispatch -DryRun|Out-Null } 'historical-only.*cannot be selectable'
  Write-Output 'PASS exact filename attribution, successor prices, historical prices, and isolated refresh evidence'
} finally {
  $env:CHASE_SETS_ROUTING_DATA_ROOT=$oldRoutingRoot;$env:CHASE_SETS_ROUTING_LKG_PATH=$oldRoutingLkg
  $full=[IO.Path]::GetFullPath($root);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
  if((Split-Path -Parent $full).TrimEnd('\','/')-cne$temp){throw 'unsafe temporary cleanup'}
  Remove-Item -LiteralPath $full -Recurse -Force
  Exit-RoutingDataTestScope $routingTestScope
}
