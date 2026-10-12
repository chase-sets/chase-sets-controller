[CmdletBinding()]
param([string]$LauncherPath=(Join-Path $PSScriptRoot 'dispatch-lane.ps1'),
  [ValidateSet('all','policy','current','admission','explicit','lkg','evidence','ledger-readers','capacity-shadow','capacity-active','capacity-validation','capacity-matrix','capacity-history','capacity-override','capacity-exemptions','capacity-logger','capacity-reserve','capacity-roles','capacity-continuation')][string]$Case='all',
  [string]$EvidenceDir,[switch]$CapacityMutantsOnly)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'routing-data-test-support.ps1')
. (Join-Path $PSScriptRoot 'dispatch-ownership.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('dispatch-routing-data-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$oldRoot=$env:CHASE_SETS_ROUTING_DATA_ROOT;$oldLkg=$env:CHASE_SETS_ROUTING_LKG_PATH
function Assert-True([bool]$Value,[string]$Message){if(-not $Value){throw "ASSERTION FAILED: $Message"}}
function Write-Json([string]$Path,$Value){[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 60),[Text.UTF8Encoding]::new($false))}
function Write-State {
  Write-Json (Join-Path $fixture.stateRoot 'routing-policy.json') $fixture.policy
  Write-Json (Join-Path $fixture.stateRoot 'model-registry.json') $fixture.registry
}
function Reset-Fixture {
  $script:fixture=New-RoutingDataFixture -Root (Join-Path $root 'state') -Families @(
    [pscustomobject]@{name='alpha';provider='codex';current='gpt-99-alpha';historical=@('gpt-99-old')},
    [pscustomobject]@{name='beta';provider='claude';current='claude-99-beta';historical=@()},
    [pscustomobject]@{name='gamma';provider='codex';current='gpt-99-gamma';historical=@()})
  foreach($row in 1..15){
    $fixture.policy.rows["$row"].slots['claude.fallback']=[ordered]@{family='beta';effort='medium';placement='override-synthetic'}
  }
  Write-State
  if([IO.File]::Exists($fixture.lkgPath)){[IO.File]::Delete($fixture.lkgPath)}
  $env:CHASE_SETS_ROUTING_DATA_ROOT=$fixture.stateRoot;$env:CHASE_SETS_ROUTING_LKG_PATH=$fixture.lkgPath
}
function Plan([hashtable]$Extra=@{}) {
  $parameters=@{Harness='codex';Row=4;LaneRole='implementation';PromptFile=$prompt;Worktree=$repo
    Label=('plan-'+[guid]::NewGuid().ToString('N'));DryRun=$true;ExecutablePath=(Join-Path $PSHOME 'pwsh.exe');TestRuntimeRoot=$runtime;TestTempRoot=$providerTemp}
  foreach($key in $Extra.Keys){$parameters[$key]=$Extra[$key]}
  try { return (& $LauncherPath @parameters | ConvertFrom-Json -DateKind String) }
  catch { throw "ASSERTION FAILED: fixture plan unexpectedly refused: $($_.Exception.Message)" }
}
function Refuses([hashtable]$Extra,[string]$Reason){
  $message='';try{Plan $Extra | Out-Null}catch{$message=$_.Exception.Message}
  Assert-True ($message.Contains($Reason)) "expected $Reason observed $message"
}
function Set-Forecast($Forecast) { Write-Json (Join-Path $fixture.stateRoot 'capacity-forecast.json') $Forecast }
function Set-FableWindow($State) { $f=Copy-Forecast;$f.decision.modelWindowStates.claude.Fable=$State;Set-Forecast $f;return $f }
function Assert-Unchanged($Plan,[string]$Status) {
  Assert-True ($Plan.harness -ceq 'codex' -and $Plan.routing.model -ceq 'gpt-6.1-sol' -and $Plan.routing.effort -ceq 'high') "unchanged route for $Status"
  Assert-True ($Plan.capacityForecastStatus -ceq $Status -and $null -eq $Plan.capacityDecisionDigest -and
    $null -eq $Plan.capacityFlip -and $null -eq $Plan.capacityShadowFlip -and $null -eq $Plan.capacityFlipSkip) "null diagnostics for $Status"
}
function Copy-Forecast { return ($script:validForecast | ConvertTo-Json -Depth 20 | ConvertFrom-Json -DateKind String) }
function Write-History([object[]]$Rows) {
  $lines=@($Rows | ForEach-Object {$_ | ConvertTo-Json -Depth 30 -Compress})
  [IO.File]::WriteAllText((Join-Path $runtime 'dispatch-log.jsonl'),$(if($lines.Count){($lines -join "`n")+"`n"}else{''}))
}
function Test-CapacityCases([string]$Name) {
  $explicit=@{Model='gpt-6.1-sol';Effort='high';Placement='provisional'}
  switch($Name) {
    'capacity-validation' {
      [IO.File]::Delete((Join-Path $fixture.stateRoot 'capacity-forecast.json'));Assert-Unchanged (Plan $explicit) 'absent'
      foreach($path in @('format','mode','decisionDigest','generatedAt','staleAfter','providers','providers.codex','providers.claude',
          'providers.codex.state','providers.claude.state','balance','balance.toward','balance.steps')) {
        foreach($operation in @('missing','type')) {
          $f=Copy-Forecast;$parts=$path.Split('.');$parent=$f
          for($i=0;$i -lt $parts.Count-1;$i++){$parent=$parent.($parts[$i])}
          if($operation -ceq 'missing'){$parent.PSObject.Properties.Remove($parts[-1])}else{$parent.($parts[-1])=@('bad')}
          Set-Forecast $f;Assert-Unchanged (Plan $explicit) 'malformed'
        }
      }
      $localGenerated=[DateTimeOffset]::Now.AddMinutes(-1)
      $localExpiry=$localGenerated.AddMinutes(11).ToString('o',[cultureinfo]::InvariantCulture)
      $variants=@(
        @{format='other'},@{mode='paused'},@{decisionDigest='ABCDEF0123456789'},@{decisionDigest='short'},
        @{generatedAt='2026-10-02'},@{generatedAt='not-a-time'},
        @{generatedAt=$localGenerated.ToString('yyyy-MM-ddTHH:mm:ss.fffffff',[cultureinfo]::InvariantCulture);staleAfter=$localExpiry},
        @{generatedAt=$localGenerated.ToString('yyyy-MM-dd HH:mm:ss.fffffffzzz',[cultureinfo]::InvariantCulture);staleAfter=$localExpiry},
        @{generatedAt=[DateTimeOffset]::UtcNow.AddMinutes(5).ToString('o')},
        @{staleAfter=$validForecast.generatedAt},@{staleAfter=[DateTimeOffset]::UtcNow.AddMinutes(-5).ToString('o')},
        @{staleAfter=[DateTimeOffset]::UtcNow.AddHours(1).ToString('o')})
      foreach($changes in $variants) {
        $f=Copy-Forecast;foreach($key in $changes.Keys){$f.$key=$changes[$key]};Set-Forecast $f
        Assert-Unchanged (Plan $explicit) 'malformed'
      }
      foreach($steps in @(-1,1.5,'3',5,$null,$true)){$f=Copy-Forecast;$f.balance.steps=$steps;Set-Forecast $f;Assert-Unchanged (Plan $explicit) 'malformed'}
      foreach($direction in @('other',1,$false)){$f=Copy-Forecast;$f.balance.toward=$direction;Set-Forecast $f;Assert-Unchanged (Plan $explicit) 'malformed'}
      $f=Copy-Forecast;$f.providers.codex.state='other';Set-Forecast $f;Assert-Unchanged (Plan $explicit) 'malformed'
      $f=Copy-Forecast;$f.providers=@($f.providers);Set-Forecast $f;Assert-Unchanged (Plan $explicit) 'malformed'
      [IO.File]::WriteAllText((Join-Path $fixture.stateRoot 'capacity-forecast.json'),('['+($validForecast|ConvertTo-Json -Depth 20 -Compress)+']'))
      Assert-Unchanged (Plan $explicit) 'malformed'
      [IO.File]::WriteAllText((Join-Path $fixture.stateRoot 'capacity-forecast.json'),'{bad');Assert-Unchanged (Plan $explicit) 'malformed'
      $f=Copy-Forecast;$instant=[DateTimeOffset]::UtcNow;$f.generatedAt=$instant.AddMinutes(-15).ToString('o');$f.staleAfter=$instant.ToString('o')
      $f.mode='shadow';$f.providers.codex.state='unknown';Set-Forecast $f;Assert-Unchanged (Plan $explicit) 'stale'
      $f.decisionDigest='bad';Set-Forecast $f;Assert-Unchanged (Plan $explicit) 'malformed'
      $f=Copy-Forecast;$f.mode='shadow';$f.providers.claude.state='unknown';Set-Forecast $f;Assert-Unchanged (Plan $explicit) 'unknown'
      $f=Copy-Forecast;$f.balance.toward=$null;Set-Forecast $f;$p=Plan $explicit
      Assert-True ($p.capacityForecastStatus -ceq 'in-force' -and $p.capacityDecisionDigest -ceq $f.decisionDigest -and $null -eq $p.capacityFlip -and $p.harness -ceq 'codex') 'explicit null toward is valid no change'
      . (Join-Path (Split-Path -Parent $LauncherPath) 'routing-data.ps1') -Library
      $f=Copy-Forecast;Set-Forecast $f
      Assert-True ((Get-CapacityForecast -StateRoot $fixture.stateRoot -NowUtc ([DateTimeOffset]::Parse($f.staleAfter))).status -ceq 'stale') 'stale equality'
      Write-Output 'PASS capacity validation missing/type/boundary/precedence controls'
    }
    'capacity-matrix' {
      $count=0
      # Fixture rows with a Claude slot and that slot's effort; rows 1/2 have none and skip SLOT_NOT_ADMITTED.
      $claudeEffort=@{3='medium';4='medium';5='high';6='high';7='high';8='high';9='high';10='medium';11='high';12='medium';13='low';14='medium';15='high'}
      foreach($toward in @('claude','codex')) {foreach($k in 0..4) {foreach($row in 1..15) {foreach($onToward in @($false,$true)) {
        $f=Copy-Forecast;$f.balance.toward=$toward;$f.balance.steps=$k;Set-Forecast $f
        $from=if($onToward){$toward}elseif($toward -ceq 'claude'){'codex'}else{'claude'}
        $model=if($from -ceq 'codex'){'gpt-6.1-sol'}else{'claude-opus-5-5'}
        $p=Plan @{Harness=$from;Model=$model;Effort='high';Placement=$(if($from -ceq 'codex'){'provisional'}else{'override-Todd'});Row=$row}
        # Toward Claude every off-toward row with an admitted own Claude slot flips once steps >= 1;
        # toward Codex the ordered prefix still bounds the first k rows.
        $flip=if($toward -ceq 'claude'){-not $onToward -and $k -ge 1 -and $claudeEffort.ContainsKey($row)}else{-not $onToward -and $row -in @(@(3,13,10,4) | Select-Object -First $k)}
        Assert-True (($null -ne $p.capacityFlip) -eq $flip -and $p.harness -ceq $(if($flip){$toward}else{$from})) "matrix $toward k=$k row=$row on=$onToward"
        if($toward -ceq 'claude' -and -not $onToward -and $k -ge 1 -and -not $claudeEffort.ContainsKey($row)){Assert-True ($p.capacityFlipSkip -ceq 'SLOT_NOT_ADMITTED') "row $row without an own Claude slot skips"}
        if($onToward){Assert-True ($p.capacityForecastStatus -ceq 'in-force' -and $null -eq $p.capacityFlipSkip) "on-toward $toward row=$row keeps its route without a skip"}
        if($flip){
          $effort=if($toward -ceq 'claude'){$claudeEffort[$row]}else{if($row -in @(3,13)){'medium'}else{'high'}}
          $slot=if($toward -ceq 'codex'){if($row -eq 3){'codex.fallback'}else{'codex.primary'}}elseif($row -eq 11){'claude.fallback'}else{'claude.primary'}
          $placement=if($toward -ceq 'claude'){'override-Todd'}else{'provisional'}
          Assert-True ($p.routing.effort -ceq $effort -and $p.routing.slot -ceq $slot -and $p.capacityFlip.to.effort -ceq $effort -and
            $p.capacityFlip.to.placement -ceq $placement -and $p.routing.placement -ceq $placement -and $p.capacityFlip.steps -eq $k) "own row effort, slot and ruled placement $toward row=$row"
        }
        $count++
      }}}}
      Write-Output "PASS capacity matrix cases=$count (150 off-toward + 150 on-toward; every row toward Claude, prefix toward Codex)"
    }
    'capacity-history' {
      $branch=(& git -C $repo branch --show-current).Trim()
      $base=@{kind='dispatch';branch=$branch;attemptId='synthetic-author';model='gpt-6.1-sol';laneRole='implementation'}
      Write-History @($base);Assert-True ($null -ne (Plan $explicit).capacityFlip) 'complete Sol-only history admits Astra reviewer'
      $duplicate='{"kind":"dispatch","branch":'+($branch|ConvertTo-Json -Compress)+',"model":"gpt-6-astra","model":"gpt-6.1-sol"}'+"`n"
      [IO.File]::WriteAllText((Join-Path $runtime 'dispatch-log.jsonl'),$duplicate)
      Assert-True ((Plan $explicit).capacityFlipSkip -ceq 'REVIEWER_HISTORY_UNKNOWN') 'duplicate identity members cannot erase an author'
      Write-History @($base)
      $fixture.registry.models['gpt-6-astra'].usableAccountsByEffort.high=@();Write-State
      Assert-True ((Plan $explicit).capacityFlipSkip -ceq 'REVIEWER_INDEPENDENCE') 'unadmitted independent reviewer skips'
      $fixture.registry.models['gpt-6-astra'].usableAccountsByEffort.high=@('synthetic-account');Write-State
      foreach($toward in @('claude','codex')) {
        $f=Copy-Forecast;$f.balance.toward=$toward;Set-Forecast $f
        $args=if($toward -ceq 'claude'){$explicit}else{@{Harness='claude';Model='claude-opus-5-5';Effort='medium';Placement='override-Todd'}}
        foreach($variant in @('generic','v1','v2','v3','repair','continuation')) {
          $author=@{kind='dispatch';branch=$branch;attemptId='synthetic-other';model='gpt-6-astra';laneRole='implementation'}
          if($variant -like 'v*'){$author.dispatchRoutingSchema="watchdog-dispatch-routing/$variant"}
          if($variant -in @('repair','continuation')){$author.Remove('branch');$author.attemptId='synthetic-author';$author.kind=if($variant -eq 'repair'){'repair-complete'}else{'continuation'}}
          Write-History @($base,$author)
          Assert-True ((Plan $args).capacityFlipSkip -ceq 'REVIEWER_INDEPENDENCE') "complete $variant Astra history excludes reviewer toward $toward"
        }
      }
      Set-Forecast (Copy-Forecast)
      foreach($schema in @('ordinary','controller-review-receipt/v1','controller-review-receipt/v2')) {
        foreach($indirect in @($false,$true)) {
          $review=@{kind='review-complete';branch=$branch;authorAttempt='synthetic-author';authorModel='gpt-6.1-sol';laneRole='review';reviewerPatch=$false}
          $modelField=if($schema -ceq 'ordinary'){'model'}else{'reviewerModel'}
          if($schema -cne 'ordinary'){$review.controllerReviewSchema=$schema}
          $review[$modelField]='gpt-6-astra'
          if($indirect){$review.Remove('branch')}
          $reviewDispatch=@{kind='dispatch';laneRole='review';branch=$branch;model='gpt-6-astra';attemptId='synthetic-reviewer';transcript='synthetic-reviewer.jsonl'}
          $review.transcript='synthetic-reviewer.jsonl'
          if($schema -ceq 'ordinary') {
            Write-History @($base,$review)
            Assert-True ((Plan $explicit).capacityFlipSkip -ceq 'REVIEWER_HISTORY_UNKNOWN') 'unattributed model-bearing completion remains unknown'
          }
          Write-History @($base,$reviewDispatch,$review)
          Assert-True ($null -ne (Plan $explicit).capacityFlip) "no-patch reviewer remains eligible $schema indirect=$indirect"
          $review.reviewerPatch=$true;Write-History @($base,$reviewDispatch,$review)
          Assert-True ((Plan $explicit).capacityFlipSkip -ceq 'REVIEWER_INDEPENDENCE') "patched reviewer joins author history $schema indirect=$indirect"
          foreach($invalid in @($null,'unknown-model','astra',@('gpt-6-astra'),42)) {
            $bad=$review.Clone();$bad[$modelField]=$invalid;Write-History @($base,$reviewDispatch,$bad)
            Assert-True ((Plan $explicit).capacityFlipSkip -ceq 'REVIEWER_HISTORY_UNKNOWN') "invalid patch author refuses $schema"
          }
          $bad=$review.Clone();$bad.Remove($modelField);Write-History @($base,$reviewDispatch,$bad)
          Assert-True ((Plan $explicit).capacityFlipSkip -ceq 'REVIEWER_HISTORY_UNKNOWN') "missing patch author refuses $schema"
          $bad=$review.Clone();$bad.reviewerPatch='true';Write-History @($base,$reviewDispatch,$bad)
          Assert-True ((Plan $explicit).capacityFlipSkip -ceq 'REVIEWER_HISTORY_UNKNOWN') "nonboolean patch flag refuses $schema"
        }
      }
      foreach($bad in @(
        @{kind='dispatch';branch=$branch;model='unknown-model'},@{kind='unclassifiable';branch=$branch;model='gpt-6-astra'},
        @{kind='dispatch';branch=$branch},@{kind='dispatch';branch=$branch;model='gpt-6.1-sol';historyComplete=$false},
        @{kind='dispatch';branch=$branch;model='gpt-6.1-sol';partial=$true},
        @{kind='dispatch';branch='unrelated';attemptId='synthetic-author';model='gpt-6.1-sol'})) {
        Write-History @($base,$bad);Assert-True ((Plan $explicit).capacityFlipSkip -ceq 'REVIEWER_HISTORY_UNKNOWN') 'unknown/partial/ambiguous history skips'
      }
      [IO.File]::WriteAllText((Join-Path $runtime 'dispatch-log.jsonl'),'{partial')
      Assert-True ((Plan $explicit).capacityFlipSkip -ceq 'REVIEWER_HISTORY_UNKNOWN') 'malformed complete ledger refuses'
      [IO.File]::Delete((Join-Path $runtime 'dispatch-log.jsonl'))
      Assert-True ((Plan $explicit).capacityFlipSkip -ceq 'REVIEWER_HISTORY_UNKNOWN') 'missing complete ledger refuses'
      Write-History @($base)
      $fixture.registry.models['claude-opus-5-5'].usableAccountsByEffort.medium=@();Write-State
      Assert-True ((Plan $explicit).capacityFlipSkip -ceq 'SLOT_NOT_ADMITTED') 'target fall-through is not a flip'
      Write-Output 'PASS capacity complete-history and slot admission controls'
    }
    'capacity-override' {
      $f=Copy-Forecast;$f.balance.steps=3;Set-Forecast $f
      foreach($automatic in @($false,$true)) {
        $args=if($automatic){@{}}else{$explicit.Clone()}
        $p=Plan $args;Assert-True ($p.harness -ceq 'claude' -and $p.routing.effort -ceq 'medium') 'ordinary explicit and automatic flip'
        $claim=@{authority='Todd:synthetic-authority';branch=(& git -C $repo branch --show-current).Trim();head=(& git -C $repo rev-parse HEAD).Trim()
          row=4;harness='codex';model='gpt-6.1-sol';effort='high';placement='provisional'}
        $args.ToddRouteOverride=$claim | ConvertTo-Json -Compress
        $p=Plan $args;Assert-Unchanged $p 'not-evaluated';Assert-True ($p.routing.placement -ceq 'provisional') 'bound Todd override exact placement'
        foreach($field in $claim.Keys.Clone()) {
          $copy=$claim.Clone();$copy.Remove($field);$args.ToddRouteOverride=$copy|ConvertTo-Json -Compress;Refuses $args 'TODD_ROUTE_OVERRIDE_INVALID'
        }
        foreach($field in @('branch','head','harness','model','effort','placement')) {
          $copy=$claim.Clone();$copy[$field]='mismatch';$args.ToddRouteOverride=$copy|ConvertTo-Json -Compress;Refuses $args 'TODD_ROUTE_OVERRIDE_MISMATCH'
        }
        $args.Remove('ToddRouteOverride');$f.mode='shadow';Set-Forecast $f;$p=Plan $args
        Assert-True ($p.harness -ceq 'codex' -and $null -eq $p.capacityFlip -and $null -ne $p.capacityShadowFlip) 'both paths shadow inert'
        $f.mode='active';Set-Forecast $f
      }
      $p=Plan @{Model='gpt-6.1-sol';Effort='high';Placement='override-Todd'}
      Assert-True ($p.harness -ceq 'claude') 'standing Todd placement is not per-artifact override'
      Write-Output 'PASS capacity override precedence and bad bindings'
    }
    'capacity-exemptions' {
      # Row 0, relaunches and launch resumes stay exempt before the forecast is read.
      foreach($extra in @(@{LaneRole='review';Row=0},@{LaneRole='planning';Row=0},@{WatchdogRelaunchCount=1},@{ResumeOfLaunchId=[guid]::NewGuid().ToString()})) {
        $args=$explicit.Clone();foreach($key in $extra.Keys){$args[$key]=$extra[$key]}
        Assert-Unchanged (Plan $args) 'not-evaluated'
      }
      # Planning and review lanes are eligible; without a bound issue or a named review artifact their history is unknown and the skip grants nothing.
      foreach($extra in @(@{LaneRole='review';Row=11},@{LaneRole='planning';Row=8},@{LaneRole='review';Row=11;Issue=900001})) {
        $args=$explicit.Clone();foreach($key in $extra.Keys){$args[$key]=$extra[$key]}
        $p=Plan $args
        Assert-True ($p.harness -ceq 'codex' -and $p.routing.model -ceq 'gpt-6.1-sol' -and $p.capacityForecastStatus -ceq 'in-force' -and
          $null -eq $p.capacityFlip -and $p.capacityFlipSkip -ceq 'REVIEWER_HISTORY_UNKNOWN') "role lane without issue or artifact skips history-unknown ($($extra.LaneRole))"
      }
      # Already-Claude selections are never flipped and keep the host's history check.
      $p=Plan @{Harness='claude';Model='claude-opus-5-5';Effort='medium';Placement='override-Todd'}
      Assert-True ($p.harness -ceq 'claude' -and $p.routing.model -ceq 'claude-opus-5-5' -and $p.capacityForecastStatus -ceq 'in-force' -and
        $null -eq $p.capacityFlip -and $null -eq $p.capacityFlipSkip) 'already-Claude selection is not flipped'
      $label='synthetic-capacity-resume';$request='a'*64;$ackPath=Join-Path $runtime "dispatch-start-$request.json"
      & $LauncherPath -Harness codex -Model gpt-6.1-sol -Effort high -Placement provisional -Row 4 -LaneRole implementation `
        -WatchdogRelaunchCount 1 -SemanticAttemptId synthetic-resume -StartRequestIdentity $request -StartAcknowledgementPath $ackPath `
        -PromptFile $prompt -Worktree $repo -Label $label -ExecutablePath (Join-Path $PSHOME 'pwsh.exe') `
        -TestRuntimeRoot $runtime -TestTempRoot $providerTemp -TestArgumentList @('-NoProfile','-NonInteractive','-Command','Write-Output SYNTHETIC_CAPACITY_RESUME') | Out-Null
      $ack=Get-Content $ackPath -Raw|ConvertFrom-Json -DateKind String
      $record=Get-Content (Join-Path $runtime 'dispatch-log.jsonl') -Tail 1|ConvertFrom-Json -DateKind String
      Assert-True ($ack.harness -ceq 'codex' -and $ack.model -ceq 'gpt-6.1-sol' -and $ack.effort -ceq 'high' -and
        $record.capacityForecastStatus -ceq 'not-evaluated' -and $record.attemptId -ceq 'synthetic-resume') 'relaunch acknowledgement matches unchanged route and semantic attempt'
      Write-Output 'PASS capacity role/row/relaunch exemptions'
    }
    'capacity-logger' {
      $p=Plan $explicit
      $base=@{Log='dispatch';Kind='dispatch';DispatchRoutingSchema='watchdog-dispatch-routing/v3';DispatchAttemptId='synthetic-capacity'
        DispatchLabel='synthetic-capacity';Lane='repo';LaneRole='implementation';Transcript='synthetic-capacity.jsonl';Harness=$p.harness
        Model=$p.routing.model;Effort=$p.routing.effort;Row='4';Placement=$p.routing.placement;DispatchWorktree=$repo
        DispatchBranch=(& git -C $repo branch --show-current).Trim();DispatchHead=(& git -C $repo rev-parse HEAD).Trim()
        PolicyGeneration=1;RegistryAuthorityDigest=$p.routing.registryAuthorityDigest;RoutingFamily=$p.routing.family;RoutingSlot=$p.routing.slot;UsedLastKnownGood=$false
        CapacityForecastStatus=$p.capacityForecastStatus;CapacityDecisionDigest=$p.capacityDecisionDigest;CapacityFlip=$p.capacityFlip
        CapacityShadowFlip=$null;CapacityFlipSkip=$null;OutFile=(Join-Path $root 'capacity-log.jsonl');NoBoard=$true}
      $logger=Join-Path (Split-Path -Parent $LauncherPath) 'log-event.ps1'
      & $logger @base | Out-Null
      $record=Get-Content $base.OutFile -Tail 1 | ConvertFrom-Json -DateKind String
      Assert-True ((Test-DispatchRoutingLedgerEvidence $record) -and @($record.PSObject.Properties).Count -eq 26) 'real logger v3 round trip and five fields'
      foreach($field in @('capacityForecastStatus','capacityDecisionDigest','capacityFlip','capacityShadowFlip','capacityFlipSkip')){
        $copy=$record|ConvertTo-Json -Depth 10|ConvertFrom-Json -DateKind String;$copy.PSObject.Properties.Remove($field)
        Assert-True (-not(Test-DispatchRoutingLedgerEvidence $copy)) "retained v3 refuses missing $field"
      }
      $copy=$record|ConvertTo-Json -Depth 10|ConvertFrom-Json -DateKind String;$copy|Add-Member extra 'unexpected'
      Assert-True (-not(Test-DispatchRoutingLedgerEvidence $copy)) 'retained v3 refuses extra field'
      foreach($path in @('row','toward','steps','from','to','from.harness','from.family','from.effort','from.slot','to.harness','to.family','to.effort','to.slot','to.placement')) {
        foreach($operation in @('missing','type','extra')) {
          $args=$base.Clone();$flip=$base.CapacityFlip | ConvertTo-Json -Depth 8 | ConvertFrom-Json -DateKind String
          $parts=$path.Split('.');$parent=$flip;for($i=0;$i -lt $parts.Count-1;$i++){$parent=$parent.($parts[$i])}
          switch($operation){missing{$parent.PSObject.Properties.Remove($parts[-1])} type{$parent.($parts[-1])=@('bad')} extra{$parent|Add-Member extra 'bad'}}
          $args.CapacityFlip=$flip;$errorMessage='';try{& $logger @args|Out-Null}catch{$errorMessage=$_.Exception.Message}
          Assert-True ($errorMessage.Contains('CAPACITY_EVIDENCE_INVALID')) "logger recursive refusal $path $operation"
        }
      }
      foreach($changes in @(@{CapacityForecastStatus='shadow'},@{CapacityForecastStatus='absent'},@{CapacityDecisionDigest='bad'},@{CapacityFlipSkip='REVIEWER_INDEPENDENCE'},@{Effort='high'},@{Row='13'},@{RoutingSlot='explicit'},@{Placement='provisional'})) {
        $args=$base.Clone();foreach($key in $changes.Keys){$args[$key]=$changes[$key]};$errorMessage=''
        try{& $logger @args|Out-Null}catch{$errorMessage=$_.Exception.Message}
        Assert-True ($errorMessage.Contains('CAPACITY_EVIDENCE_INVALID')) "logger status/route consistency $($changes.Keys -join ',')"
      }
      # A Claude flip is Todd-placed: the own-slot check requires override-Todd, not the slot's own placement literal.
      $args=$base.Clone();$args.CapacityFlip=$base.CapacityFlip|ConvertTo-Json -Depth 8|ConvertFrom-Json -DateKind String
      $args.CapacityFlip.to.placement='provisional';$args.Placement='provisional';$errorMessage=''
      try{& $logger @args|Out-Null}catch{$errorMessage=$_.Exception.Message}
      Assert-True ($errorMessage.Contains('CAPACITY_EVIDENCE_INVALID')) 'logger refuses a Claude flip that is not override-Todd'
      # v3 is the routing row for every role; planning and review flip rows are accepted and validated.
      foreach($role in @('planning','review')) {
        $args=$base.Clone();$args.LaneRole=$role;$args.DispatchLabel="synthetic-capacity-$role";$args.DispatchAttemptId="synthetic-capacity-$role";$args.Transcript="synthetic-capacity-$role.jsonl"
        & $logger @args | Out-Null
        $roleRecord=Get-Content $base.OutFile -Tail 1 | ConvertFrom-Json -DateKind String
        Assert-True ($roleRecord.laneRole -ceq $role -and $roleRecord.dispatchRoutingSchema -ceq 'watchdog-dispatch-routing/v3' -and
          $roleRecord.placement -ceq 'override-Todd' -and (Test-DispatchRoutingLedgerEvidence $roleRecord)) "real logger accepts a $role v3 flip row"
      }
      # Toward Claude every row is eligible (#9282): the real logger and the v3 reader accept a row-11 flip that the superseded Claude prefix [13,10,4,5] refused.
      $args11=$explicit.Clone();$args11.Row=11;$p11=Plan $args11
      Assert-True ($null -ne $p11.capacityFlip -and $p11.capacityFlip.row -eq 11) 'row 11 flips toward Claude'
      $args=$base.Clone();$args.DispatchLabel='synthetic-capacity-row11';$args.DispatchAttemptId='synthetic-capacity-row11';$args.Transcript='synthetic-capacity-row11.jsonl'
      $args.Row='11';$args.Harness=$p11.harness;$args.Model=$p11.routing.model;$args.Effort=$p11.routing.effort;$args.Placement=$p11.routing.placement
      $args.RoutingFamily=$p11.routing.family;$args.RoutingSlot=$p11.routing.slot;$args.CapacityDecisionDigest=$p11.capacityDecisionDigest;$args.CapacityFlip=$p11.capacityFlip
      $errorMessage='';try{& $logger @args | Out-Null}catch{$errorMessage=$_.Exception.Message}
      Assert-True ($errorMessage -ceq '') "real logger accepts a row-11 Claude flip: $errorMessage"
      $row11=Get-Content $base.OutFile -Tail 1 | ConvertFrom-Json -DateKind String
      Assert-True ($row11.row -ceq '11' -and $row11.placement -ceq 'override-Todd' -and $row11.capacityFlip.row -eq 11 -and (Test-DispatchRoutingLedgerEvidence $row11)) 'real logger accepts a row-11 Claude flip outside the superseded prefix'
      # A role row dispatched without placement carries the logger's closed placementSource; the v3 reader admits only that closed shape.
      $args=$base.Clone();$args.LaneRole='planning';$args.DispatchLabel='synthetic-capacity-row0';$args.DispatchAttemptId='synthetic-capacity-row0';$args.Transcript='synthetic-capacity-row0.jsonl'
      $args.Row='0';$args.Placement='';$args.DispatchBranch='';$args.CapacityForecastStatus='not-evaluated';$args.CapacityDecisionDigest=$null;$args.CapacityFlip=$null
      & $logger @args | Out-Null
      $row0=Get-Content $base.OutFile -Tail 1 | ConvertFrom-Json -DateKind String
      Assert-True ($null -eq $row0.placement -and $row0.placementSource -ceq 'row-0-explicit' -and (Test-DispatchRoutingLedgerEvidence $row0)) 'v3 reader admits a row-0 planning row with its closed placementSource'
      foreach($schema in @('watchdog-dispatch-routing/v1','watchdog-dispatch-routing/v2')) {
        Assert-True (@(Get-DispatchRoutingLedgerKeys $schema $row0) -cnotcontains 'placementSource') "$schema closed keys do not admit v3-only placementSource"
      }
      foreach($mutation in @(@{placementSource='non-implementation-unspecified'},@{placementSource='bogus'},@{placementSource=$null},@{placement='provisional'},@{laneRole='implementation'})) {
        $copy=$row0|ConvertTo-Json -Depth 10|ConvertFrom-Json -DateKind String;foreach($key in $mutation.Keys){$copy.$key=$mutation[$key]}
        Assert-True (-not (Test-DispatchRoutingLedgerEvidence $copy)) "v3 reader refuses placementSource shape $($mutation.Keys -join ',')"
      }
      $args=$base.Clone();$args.CapacityFlip=$base.CapacityFlip|ConvertTo-Json -Depth 8|ConvertFrom-Json -DateKind String
      $args.CapacityFlip.to.slot='claude.fallback';$args.RoutingSlot='claude.fallback';$errorMessage=''
      try{& $logger @args|Out-Null}catch{$errorMessage=$_.Exception.Message}
      Assert-True ($errorMessage.Contains('CAPACITY_EVIDENCE_INVALID')) 'logger refuses self-consistent but wrong own policy slot'
      Write-Output 'PASS capacity real logger nested closure and status/route consistency'
    }
    'capacity-reserve' {
      # AC1 reserve rows: Astra-routed rows 7/14/15 with empty history flip to their own Fable slot only while
      # decision.modelWindowStates.claude.Fable is spend/normal; every other window refuses SLOT_NOT_ADMITTED.
      $branch=(& git -C $repo branch --show-current).Trim()
      $astra=@{Model='gpt-6-astra';Effort='high';Placement='override-Todd'}
      $script:validForecast.balance.steps=1;Set-Forecast (Copy-Forecast)
      $fableEffort=@{7='high';14='medium';15='high'}
      foreach($state in @('spend','normal')) {
        [void](Set-FableWindow $state)
        foreach($row in @(7,14,15)) {
          $p=Plan ($astra+@{Row=$row})
          Assert-True ($p.harness -ceq 'claude' -and $p.routing.model -ceq 'claude-fable-5-1' -and $p.routing.effort -ceq $fableEffort[$row] -and
            $p.routing.slot -ceq 'claude.primary' -and $p.routing.placement -ceq 'override-Todd' -and $p.capacityFlip.to.placement -ceq 'override-Todd' -and
            $p.capacityFlip.to.family -ceq 'fable' -and $p.capacityFlip.steps -eq 1) "reserve row $row flips to Fable under window $state"
        }
      }
      foreach($state in @('conserve','unknown','other','',42,$true,@('spend'),$null)) {
        [void](Set-FableWindow $state)
        foreach($row in @(7,14,15)) { Assert-True ((Plan ($astra+@{Row=$row})).capacityFlipSkip -ceq 'SLOT_NOT_ADMITTED') "reserve row $row refuses window [$state]" }
      }
      foreach($path in @('decision','decision.modelWindowStates','decision.modelWindowStates.claude','decision.modelWindowStates.claude.Fable')) {
        foreach($operation in @('missing','array','scalar')) {
          $f=Copy-Forecast;$parts=$path.Split('.');$parent=$f
          for($i=0;$i -lt $parts.Count-1;$i++){$parent=$parent.($parts[$i])}
          switch($operation){missing{$parent.PSObject.Properties.Remove($parts[-1])} array{$parent.($parts[-1])=@('spend')} scalar{$parent.($parts[-1])='spend'}}
          if($operation -ceq 'scalar' -and $path -ceq 'decision.modelWindowStates.claude.Fable'){continue}
          Set-Forecast $f
          Assert-True ((Plan ($astra+@{Row=7})).capacityFlipSkip -ceq 'SLOT_NOT_ADMITTED') "reserve row 7 refuses malformed window $path/$operation"
        }
      }
      Set-Forecast (Copy-Forecast)
      # Fable is never another row's target even where a policy puts it there, and the ruled window never admits a non-Fable reserve slot.
      $fixture.policy.rows['9'].slots['claude.primary']=[ordered]@{family='fable';effort='high';placement='reserve'};Write-State
      Assert-True ((Plan ($astra+@{Row=9})).capacityFlipSkip -ceq 'SLOT_NOT_ADMITTED') 'Fable on a non-reserve row is never a target'
      $fixture.policy.rows['9'].slots['claude.primary']=[ordered]@{family='opus';effort='high';placement='reserve'};Write-State
      Assert-True ((Plan ($astra+@{Row=9})).capacityFlipSkip -ceq 'SLOT_NOT_ADMITTED') 'a non-Fable reserve slot still refuses'
      $fixture.policy.rows['9'].slots['claude.primary']=[ordered]@{family='opus';effort='high';placement='override-Todd'};Write-State
      # Genuine Sol and Opus authors, or a recorded unused ladder, leave no independent reviewer; one of them alone does.
      $sol=@{kind='dispatch';branch=$branch;attemptId='synthetic-sol';model='gpt-6.1-sol';laneRole='implementation'}
      $opus=@{kind='dispatch';branch=$branch;attemptId='synthetic-opus';model='claude-opus-5-5';laneRole='implementation'}
      Write-History @($sol);Assert-True ($null -ne (Plan ($astra+@{Row=7})).capacityFlip) 'Sol author alone leaves Opus as reviewer'
      Write-History @($opus);Assert-True ($null -ne (Plan ($astra+@{Row=7})).capacityFlip) 'Opus author alone leaves Sol as reviewer'
      Write-History @($sol,$opus);Assert-True ((Plan ($astra+@{Row=7})).capacityFlipSkip -ceq 'REVIEWER_INDEPENDENCE') 'Sol and Opus authors exhaust reviewers'
      Write-History @(@{kind='dispatch';branch=$branch;attemptId='synthetic-ladder';model='gpt-6.1-sol';laneRole='implementation';unusedAuthorModels=@('claude-opus-5-5')})
      Assert-True ((Plan ($astra+@{Row=14})).capacityFlipSkip -ceq 'REVIEWER_INDEPENDENCE') 'recorded unused ladder exhausts reviewers'
      # One Fable attempt per artifact: a Fable author already in the branch history refuses the reserve.
      Write-History @(@{kind='dispatch';branch=$branch;attemptId='synthetic-fable';model='claude-fable-5-1';laneRole='implementation'})
      Assert-True ((Plan ($astra+@{Row=15})).capacityFlipSkip -ceq 'SLOT_NOT_ADMITTED') 'second Fable attempt on the artifact refuses'
      Write-History @()
      # steps 0 and the Codex direction are unchanged.
      $f=Copy-Forecast;$f.balance.steps=0;Set-Forecast $f
      $p=Plan ($astra+@{Row=7});Assert-True ($p.harness -ceq 'codex' -and $p.capacityForecastStatus -ceq 'in-force' -and $null -eq $p.capacityFlip -and $null -eq $p.capacityFlipSkip) 'steps 0 flips nothing'
      $f=Copy-Forecast;$f.balance.toward='codex';Set-Forecast $f
      foreach($row in @(7,14,15)) {
        $p=Plan @{Harness='claude';Model='claude-fable-5-1';Effort='high';Placement='override-Todd';Row=$row}
        Assert-True ($p.harness -ceq 'claude' -and $null -eq $p.capacityFlip -and $null -eq $p.capacityFlipSkip) "toward Codex row $row stays outside the prefix"
      }
      Write-Output 'PASS capacity reserve rows, Fable window, exhaustion and single-attempt controls'
    }
    'capacity-roles' {
      # AC2/AC3: planning and review flips are judged per artifact on a lineage copied from real
      # review-complete shapes (planning dispatch, host repair bookkeeping, read-only brief review,
      # implementation dispatch, exact-head review receipt, and a multi-issue lane whose other row
      # must stay another artifact's history).
      $f=Copy-Forecast;$f.balance.steps=1;Set-Forecast $f
      $issue=900042
      function New-Lineage([string]$BriefAuthor,[string]$CodeAuthor,[hashtable]$Extra=@{}) {
        $rows=@(
          @{kind='dispatch';laneRole='planning';issue=$issue;branch="codex/$issue-brief-repair-r1";attemptId="$issue-brief-repair-r1";model=$BriefAuthor;row='8';transcript="$issue-brief-repair-r1.jsonl"},
          @{kind='repair-complete';laneRole='planning';issue=$issue;lane="host-$issue-publish";outcome='REPAIR_IN_PLACE'},
          @{kind='dispatch';laneRole='review';issue=$issue;branch='';attemptId="$issue-brief-review-r1";model='gpt-6.1-sol';row='11';transcript='shared-briefs-review-r1.jsonl'},
          @{kind='lane-complete';issue=$issue;lane="$issue-brief-review-r1";model='gpt-6.1-sol';row='11'},
          @{kind='dispatch';laneRole='implementation';issue=$issue;branch="codex/$issue-impl-g1";attemptId="$issue-impl-g1";model=$CodeAuthor;row='7';transcript="$issue-impl-g1.jsonl"},
          @{kind='review-complete';laneRole='review';issue=$issue;authorAttempt="$issue-impl-g1";authorModel=$CodeAuthor;model='gpt-6.1-sol';reviewerPatch=$false;reviewContract='review-contract/v2';outcome='PASS';lane="$issue-exact-head-review-r1";transcript="$issue-exact-head-review-r1.jsonl"},
          @{kind='dispatch';laneRole='implementation';issue=900043;branch='codex/900043-impl-g1';attemptId='900043-impl-g1';model='claude-opus-5-5';row='4';transcript='shared-briefs-review-r1.jsonl'})
        foreach($key in $Extra.Keys){$rows+=$Extra[$key]}
        Write-History $rows
      }
      $review=@{LaneRole='review';Row=11;Model='gpt-6.1-sol';Effort='high';Placement='provisional';Issue=$issue}
      $planning=@{LaneRole='planning';Row=8;Model='gpt-6.1-sol';Effort='high';Placement='provisional';Issue=$issue}
      # Code review of a Codex-authored branch flips to the row's Opus slot although Opus authored the brief; the brief review of that brief refuses Opus.
      New-Lineage 'claude-opus-5-5' 'gpt-6-astra'
      $p=Plan ($review+@{ReviewArtifact='code'})
      Assert-True ($p.harness -ceq 'claude' -and $p.routing.model -ceq 'claude-opus-5-5' -and $p.routing.slot -ceq 'claude.fallback' -and $p.routing.placement -ceq 'override-Todd' -and $p.capacityFlip.row -eq 11) 'code review flips despite brief-only Opus authorship'
      Assert-True ((Plan ($review+@{ReviewArtifact='brief'})).capacityFlipSkip -ceq 'REVIEWER_INDEPENDENCE') 'brief review refuses the brief author'
      Assert-True ((Plan $planning).capacityFlipSkip -ceq 'REVIEWER_INDEPENDENCE') 'planning refuses a model that planned the issue'
      # Opus authored the code: code review refuses, brief review (Astra brief) flips, planning refuses.
      New-Lineage 'gpt-6-astra' 'claude-opus-5-5'
      Assert-True ((Plan ($review+@{ReviewArtifact='code'})).capacityFlipSkip -ceq 'REVIEWER_INDEPENDENCE') 'code review refuses the code author'
      Assert-True ($null -ne (Plan ($review+@{ReviewArtifact='brief'})).capacityFlip) 'brief review flips when Opus only authored code'
      Assert-True ((Plan $planning).capacityFlipSkip -ceq 'REVIEWER_INDEPENDENCE') 'planning refuses a model that implemented the issue'
      # A later implementation attempt is code authorship through its dispatch row alone, before any receipt names it; it is not brief authorship.
      New-Lineage 'gpt-6-astra' 'gpt-6-astra' @{second=@{kind='dispatch';laneRole='implementation';issue=$issue;branch="codex/$issue-impl-g2";attemptId="$issue-impl-g2";model='claude-opus-5-5';row='7';transcript="$issue-impl-g2.jsonl"}}
      Assert-True ((Plan ($review+@{ReviewArtifact='code'})).capacityFlipSkip -ceq 'REVIEWER_INDEPENDENCE') 'code review refuses a dispatched later-attempt author before any receipt'
      Assert-True ($null -ne (Plan ($review+@{ReviewArtifact='brief'})).capacityFlip) 'a dispatched code attempt is not brief authorship'
      # Astra planned and authored: planning flips to Opus 5.5 high on row 8 with override-Todd and the real logger accepts the planning v3 row.
      New-Lineage 'gpt-6-astra' 'gpt-6-astra'
      $p=Plan $planning
      Assert-True ($p.harness -ceq 'claude' -and $p.routing.model -ceq 'claude-opus-5-5' -and $p.routing.effort -ceq 'high' -and $p.routing.slot -ceq 'claude.primary' -and
        $p.routing.placement -ceq 'override-Todd' -and $p.capacityFlip.row -eq 8 -and $p.laneRole -ceq 'planning') 'planning flips to Opus 5.5 high on row 8'
      $logger=Join-Path (Split-Path -Parent $LauncherPath) 'log-event.ps1'
      $planningLog=Join-Path $root 'capacity-planning-log.jsonl'
      & $logger -Log dispatch -Kind dispatch -DispatchRoutingSchema watchdog-dispatch-routing/v3 -DispatchAttemptId synthetic-planning -DispatchLabel synthetic-planning -Lane repo -LaneRole planning -Issue $issue `
        -Transcript synthetic-planning.jsonl -Harness $p.harness -Model $p.routing.model -Effort $p.routing.effort -Row '8' -Placement $p.routing.placement -DispatchWorktree $repo `
        -DispatchBranch (& git -C $repo branch --show-current).Trim() -DispatchHead (& git -C $repo rev-parse HEAD).Trim() -PolicyGeneration 1 -RegistryAuthorityDigest $p.routing.registryAuthorityDigest `
        -RoutingFamily $p.routing.family -RoutingSlot $p.routing.slot -UsedLastKnownGood $false -CapacityForecastStatus $p.capacityForecastStatus -CapacityDecisionDigest $p.capacityDecisionDigest `
        -CapacityFlip $p.capacityFlip -CapacityShadowFlip $null -CapacityFlipSkip $null -OutFile $planningLog -NoBoard | Out-Null
      $planningRow=Get-Content $planningLog -Tail 1 | ConvertFrom-Json -DateKind String
      Assert-True ($planningRow.laneRole -ceq 'planning' -and $planningRow.issue -eq $issue -and $planningRow.placement -ceq 'override-Todd' -and (Test-DispatchRoutingLedgerEvidence $planningRow)) 'real logger accepts the planning flip row'
      # Two complete planning branches are not unknown; partial history or no -Issue is.
      New-Lineage 'gpt-6-astra' 'gpt-6-astra' @{second=@{kind='dispatch';laneRole='planning';issue=$issue;branch="codex/$issue-brief-repair-r2";attemptId="$issue-brief-repair-r2";model='gpt-6-astra';row='8';transcript="$issue-brief-repair-r2.jsonl"}}
      Assert-True ($null -ne (Plan $planning).capacityFlip) 'two complete planning branches are not unknown'
      New-Lineage 'gpt-6-astra' 'gpt-6-astra' @{partial=@{kind='dispatch';laneRole='planning';issue=$issue;branch="codex/$issue-brief-repair-r2";model='gpt-6-astra';partial=$true}}
      Assert-True ((Plan $planning).capacityFlipSkip -ceq 'REVIEWER_HISTORY_UNKNOWN') 'partial planning history is unknown'
      New-Lineage 'gpt-6-astra' 'gpt-6-astra'
      $noIssue=$planning.Clone();$noIssue.Remove('Issue')
      Assert-True ((Plan $noIssue).capacityFlipSkip -ceq 'REVIEWER_HISTORY_UNKNOWN') 'planning without -Issue is unknown'
      Assert-True ((Plan $review).capacityFlipSkip -ceq 'REVIEWER_HISTORY_UNKNOWN') 'review without a named artifact is unknown'
      # SYNTHETIC multi-issue planning completion: dispatch belongs to A, but
      # the role-bearing lifecycle row is the only authorship evidence for B.
      Write-History @(
        @{kind='dispatch';laneRole='planning';issue=900041;model='claude-opus-5-5';transcript='synthetic-multi-issue-plan.jsonl'},
        @{kind='lane-complete';laneRole='planning';issue=$issue;model='claude-opus-5-5';transcript='synthetic-multi-issue-plan.jsonl';outcome='REGISTERED'})
      Assert-True ((Plan $planning).capacityFlipSkip -ceq 'REVIEWER_INDEPENDENCE') 'multi-issue lifecycle planner remains an author'
      Assert-True ((Plan ($review+@{ReviewArtifact='brief'})).capacityFlipSkip -ceq 'REVIEWER_INDEPENDENCE') 'multi-issue brief cannot flip to its planner'
      Assert-True ($null -ne (Plan ($review+@{ReviewArtifact='code'})).capacityFlip) 'multi-issue brief author is not a code author'
      Write-History @(@{kind='lane-complete';laneRole='planning';issue=$issue;model='claude-opus-5-5';outcome='BLOCK_FIXABLE_REPAIRED_IN_BODY'})
      Assert-True ((Plan $planning).capacityFlipSkip -ceq 'REVIEWER_INDEPENDENCE') 'in-body lifecycle repair without transcript is authorship'
      Assert-True ((Plan ($review+@{ReviewArtifact='brief'})).capacityFlipSkip -ceq 'REVIEWER_INDEPENDENCE') 'in-body brief repair excludes that reviewer'
      Write-History @(@{kind='lane-complete';laneRole='implementation';issue=$issue;model='claude-opus-5-5';outcome='REGISTERED'})
      Assert-True ((Plan ($review+@{ReviewArtifact='code'})).capacityFlipSkip -ceq 'REVIEWER_INDEPENDENCE') 'implementation lifecycle contributes code authorship'
      # Actual repairs, not verdicts. Every recognized role-less/review repair
      # contributes brief authorship unless its positive PR identifies code.
      . (Join-Path (Split-Path -Parent $LauncherPath) 'routing-data.ps1') -Library
      foreach($outcome in @('REPAIR_IN_PLACE','REPAIR_IN_PLACE_READY','REPAIRED','REPAIRED_IN_PLACE','REPLACED',
          'REPLAN_REPLACED','BLOCK_FIXABLE_REPAIRED','BLOCK_FIXABLE_REPAIRED_IN_BODY','ISSUE_BODIES_REPAIRED',
          'COMPILE_REPAIRED','PLANNING_REPAIR_COMPLETE','SOURCE_REPAIRED_REVIEW_PENDING')) {
        foreach($role in @('','review')) {
          $repair=@{kind='lane-complete';laneRole=$role;issue=$issue;model='claude-opus-5-5';outcome=$outcome}
          Assert-True ((Get-CapacityAuthorArtifact ([pscustomobject]$repair)) -ceq 'brief') "$role $outcome contributes brief repair"
          $repair.pr=900044
          Assert-True ((Get-CapacityAuthorArtifact ([pscustomobject]$repair)) -ceq 'code') "$role $outcome positive PR contributes code repair"
          $repair.kind='repair-complete';$repair.Remove('pr')
          Assert-True ((Get-CapacityAuthorArtifact ([pscustomobject]$repair)) -ceq 'brief') "$role $outcome completed repair contributes brief"
          if($role -ceq 'review') {
            $repair.reviewerPatch='true'
            Assert-True ((Get-CapacityAuthorArtifact ([pscustomobject]$repair)) -ceq 'unknown') 'repair outcome does not bypass malformed patch flag'
          }
        }
      }
      foreach($outcome in @('PASS','REPAIR_REQUIRED','RECOMMEND_NOT_COMPLETING','REPAIR_STARTED','REPAIR_AUTHORIZED')) {
        $completion=@{kind='lane-complete';laneRole='review';issue=$issue;model='claude-opus-5-5';outcome=$outcome;transcript='synthetic-readonly-review.jsonl'}
        Write-History @($completion)
        Assert-True ((Plan $planning).capacityFlipSkip -ceq 'REVIEWER_HISTORY_UNKNOWN') "$outcome without attributed lineage remains unknown"
        Write-History @(@{kind='dispatch';laneRole='review';issue=$issue;model='claude-opus-5-5';transcript='synthetic-readonly-review.jsonl'},$completion)
        Assert-True ($null -ne (Plan $planning).capacityFlip) "$outcome with its own review dispatch is not authorship"
      }
      # SYNTHETIC planning-review receipt: planning is the reviewed artifact,
      # not the reviewer's author role. Its own dispatch supplies lineage.
      $reviewDispatch=@{kind='dispatch';laneRole='review';issue=$issue;model='claude-opus-5-5';transcript='synthetic-planning-review.jsonl'}
      $planningReceipt=@{kind='review-complete';laneRole='planning';planningContract='planning-repair/v1';issue=$issue;
        model='claude-opus-5-5';authorModel='gpt-6-astra';outcome='BLOCK_FIXABLE';transcript='synthetic-planning-review.jsonl'}
      foreach($route in @($planning,($review+@{ReviewArtifact='brief'}))) {
        Write-History @($reviewDispatch,$planningReceipt)
        $p=Plan $route
        Assert-True ($null -ne $p.capacityFlip -and $p.routing.model -ceq 'claude-opus-5-5' -and $p.routing.effort -ceq 'high') 'read-only planning receipt with attributed review dispatch allows Opus flip'
        $patch=$planningReceipt.Clone();$patch.reviewerPatch=$true
        Write-History @($reviewDispatch,$patch)
        Assert-True ((Plan $route).capacityFlipSkip -ceq 'REVIEWER_INDEPENDENCE') 'planning receipt reviewer patch remains brief authorship'
        $repair=$planningReceipt.Clone();$repair.outcome='BLOCK_FIXABLE_REPAIRED_IN_BODY'
        Write-History @($reviewDispatch,$repair)
        Assert-True ((Plan $route).capacityFlipSkip -ceq 'REVIEWER_INDEPENDENCE') 'planning receipt repaired outcome remains brief authorship'
        Write-History @($planningReceipt)
        Assert-True ((Plan $route).capacityFlipSkip -ceq 'REVIEWER_HISTORY_UNKNOWN') 'planning receipt without attributed dispatch remains unknown'
      }
      Assert-True ((Get-CapacityAuthorArtifact ([pscustomobject]$patch)) -eq $null) 'planning receipt patch uses CAPACITY_GUARD_PATCH_AUTHOR'
      $repair.pr=900044
      Assert-True ((Get-CapacityAuthorArtifact ([pscustomobject]$repair)) -ceq 'code') 'planning receipt repaired positive PR contributes code'
      $contractOnly=$planningReceipt.Clone();$contractOnly.Remove('laneRole')
      Assert-True ((Get-CapacityAuthorArtifact ([pscustomobject]$contractOnly)) -ceq 'lifecycle') 'planning contract without role remains review lifecycle'
      $malformedPatch=$planningReceipt.Clone();$malformedPatch.reviewerPatch='true'
      Write-History @($reviewDispatch,$malformedPatch)
      Assert-True ((Plan $planning).capacityFlipSkip -ceq 'REVIEWER_HISTORY_UNKNOWN') 'planning receipt malformed patch flag remains unknown'
      # Reviewer patches are authorship for the reviewed artifact only; a reviewer patch on the code excludes that reviewer from code review, not from the brief.
      New-Lineage 'gpt-6-astra' 'gpt-6-astra' @{patch=@{kind='review-complete';laneRole='review';issue=$issue;authorAttempt="$issue-impl-g1";authorModel='gpt-6-astra';model='claude-opus-5-5';reviewerPatch=$true;reviewContract='review-contract/v2';outcome='BLOCK_FIXABLE';lane="$issue-exact-head-review-r2";transcript="$issue-exact-head-review-r2.jsonl"}}
      Assert-True ((Plan ($review+@{ReviewArtifact='code'})).capacityFlipSkip -ceq 'REVIEWER_INDEPENDENCE') 'code reviewer patch is code authorship'
      Assert-True ($null -ne (Plan ($review+@{ReviewArtifact='brief'})).capacityFlip) 'code reviewer patch is not brief authorship'
      New-Lineage 'gpt-6-astra' 'gpt-6-astra' @{patch=@{kind='repair-complete';laneRole='review';issue=$issue;model='claude-opus-5-5';reviewerPatch=$true;lane='shared-briefs-review-r1';transcript='shared-briefs-review-r1.jsonl'}}
      Assert-True ((Plan ($review+@{ReviewArtifact='brief'})).capacityFlipSkip -ceq 'REVIEWER_INDEPENDENCE') 'reviewer brief repair is brief authorship'
      Assert-True ($null -ne (Plan ($review+@{ReviewArtifact='code'})).capacityFlip) 'reviewer brief repair is not code authorship'
      # Fable is never a planning or review target: a row-7 planning lane and a row-7 review refuse SLOT_NOT_ADMITTED.
      New-Lineage 'gpt-6-astra' 'gpt-6-astra'
      Assert-True ((Plan @{LaneRole='planning';Row=7;Model='gpt-6-astra';Effort='high';Placement='override-Todd';Issue=$issue}).capacityFlipSkip -ceq 'SLOT_NOT_ADMITTED') 'planning never flips to Fable'
      Assert-True ((Plan @{LaneRole='review';Row=7;Model='gpt-6-astra';Effort='high';Placement='override-Todd';Issue=$issue;ReviewArtifact='code'}).capacityFlipSkip -ceq 'SLOT_NOT_ADMITTED') 'review never flips to Fable'
      # Planning never falls back to Fable when Opus is unadmitted: the flip is refused.
      $fixture.registry.models['claude-opus-5-5'].usableAccountsByEffort.high=@();Write-State
      $p=Plan $planning;Assert-True ($p.capacityFlipSkip -ceq 'SLOT_NOT_ADMITTED' -and $p.harness -ceq 'codex') 'unadmitted Opus planning target refuses without a Fable fallback'
      $fixture.registry.models['claude-opus-5-5'].usableAccountsByEffort.high=@('synthetic-account');Write-State
      Write-Output 'PASS capacity role flips per artifact (planning, brief review, code review)'
    }
    'capacity-continuation' {
      # The resolver's closed continuation mirror must equal the watchdog's closed quota/session table.
      . (Join-Path (Split-Path -Parent $LauncherPath) 'routing-data.ps1') -Library
      $watchdogSource=[IO.File]::ReadAllText((Join-Path (Split-Path -Parent $LauncherPath) 'lane-stall-watchdog.ps1'))
      $tableStart=$watchdogSource.IndexOf('$fallback=@{');$tableEnd=$watchdogSource.IndexOf('# One policy move per lineage',$tableStart)
      Assert-True ($tableStart -ge 0 -and $tableEnd -gt $tableStart) 'watchdog closed table located'
      $watchdogTable=@{}
      foreach($m in [regex]::Matches($watchdogSource.Substring($tableStart,$tableEnd-$tableStart),"'(\d+\|[a-z]+/[a-z]+)'\s*=\s*@\('(codex|claude)','([a-z]+)'")) { $watchdogTable[$m.Groups[1].Value]=$m.Groups[3].Value }
      Assert-True ($watchdogTable.Count -eq $script:CapacityClosedContinuations.Count -and $watchdogTable.Count -ge 20) "closed table entries watchdog=$($watchdogTable.Count) mirror=$($script:CapacityClosedContinuations.Count)"
      foreach($key in $watchdogTable.Keys) { Assert-True ($script:CapacityClosedContinuations[$key] -ceq $watchdogTable[$key]) "closed continuation $key" }
      # The target route's continuation is excluded, nothing else: row 6 Opus high continues as Sol, row 8 follows the
      # policy slot (Sol), rows 9/11/12 have no continuation, and the Codex direction excludes the Sol route's Opus continuation.
      $f=Copy-Forecast;$f.balance.steps=1;Set-Forecast $f
      $astra=@{Model='gpt-6-astra';Effort='high';Placement='override-Todd'}
      Assert-True ((Plan ($astra+@{Row=6})).capacityFlipSkip -ceq 'REVIEWER_INDEPENDENCE') 'row 6 from Astra: Opus target with Sol continuation leaves no reviewer'
      Assert-True ($null -ne (Plan @{Model='gpt-6.1-sol';Effort='high';Placement='provisional';Row=6}).capacityFlip) 'row 6 from Sol: Astra remains the reviewer'
      Assert-True ((Plan ($astra+@{Row=8})).capacityFlipSkip -ceq 'REVIEWER_INDEPENDENCE') 'row 8 from Astra: policy-slot Sol continuation leaves no reviewer'
      foreach($row in @(9,11,12)) { Assert-True ($null -ne (Plan ($astra+@{Row=$row})).capacityFlip) "row $row from Astra: no continuation, Sol remains" }
      $f=Copy-Forecast;$f.balance.toward='codex';$f.balance.steps=1;Set-Forecast $f
      Assert-True ($null -ne (Plan @{Harness='claude';Model='claude-opus-5-5';Effort='medium';Placement='override-Todd';Row=3}).capacityFlip) 'toward Codex row 3: Opus continuation already excluded, Astra remains'
      Write-History @(@{kind='dispatch';branch=(& git -C $repo branch --show-current).Trim();attemptId='synthetic-astra';model='gpt-6-astra';laneRole='implementation'})
      Assert-True ((Plan @{Harness='claude';Model='claude-opus-5-5';Effort='medium';Placement='override-Todd';Row=3}).capacityFlipSkip -ceq 'REVIEWER_INDEPENDENCE') 'toward Codex row 3 with an Astra author exhausts reviewers'
      Write-History @()
      Write-Output 'PASS capacity route continuation mirror and exclusion'
    }
  }
}
function Invoke-Case([string]$Name){
  Reset-Fixture
  if ($Name -like 'capacity-*') {
    $snapshot=Get-Content (Join-Path $PSScriptRoot 'controller-skills/model-routing/capability-matrix.json') -Raw | ConvertFrom-Json
    $script:fixture=New-RoutingMatrixFixture -Root (Join-Path $root 'capacity-state') -Snapshot $snapshot
    $env:CHASE_SETS_ROUTING_DATA_ROOT=$fixture.stateRoot;$env:CHASE_SETS_ROUTING_LKG_PATH=$fixture.lkgPath
    [IO.File]::WriteAllText((Join-Path $runtime 'dispatch-log.jsonl'),'')
    $now=[DateTimeOffset]::UtcNow
    $script:validForecast=[ordered]@{
      format='capacity-forecast/v1';mode=$(if($Name -eq 'capacity-shadow'){'shadow'}else{'active'})
      generatedAt=$now.AddMinutes(-1).ToString('o');staleAfter=$now.AddMinutes(14).ToString('o');decisionDigest='0123456789abcdef'
      providers=@{codex=@{state='conserve'};claude=@{state='spend'}};balance=@{toward='claude';steps=4}
      decision=@{modelWindowStates=@{claude=@{Fable='spend'};codex=@{}}}
    }
    Set-Forecast $validForecast
    if($Name -cnotin @('capacity-active','capacity-shadow')){Test-CapacityCases $Name;return}
    $p=Plan @{Model='gpt-6.1-sol';Effort='high';Placement='provisional'}
    if($Name -eq 'capacity-shadow') {
      Assert-True ($p.harness -ceq 'codex' -and $p.routing.model -ceq 'gpt-6.1-sol' -and $p.routing.effort -ceq 'high') 'shadow preserves exact route'
      Assert-True ($p.capacityForecastStatus -ceq 'shadow' -and $null -eq $p.capacityFlip -and
        $p.capacityShadowFlip.to.effort -ceq 'medium' -and $p.capacityShadowFlip.to.slot -ceq 'claude.primary' -and
        $p.capacityDecisionDigest -ceq '0123456789abcdef') 'capacity shadow emits own-slot decision without applying it'
    } else {
      Assert-True ($p.harness -ceq 'claude' -and $p.routing.model -ceq 'claude-opus-5-5' -and
        $p.routing.effort -ceq 'medium' -and $p.capacityForecastStatus -ceq 'in-force' -and $p.capacityFlip.row -eq 4) 'capacity active applies own row effort to ordinary explicit route'
    }
    $label="synthetic-$Name"
    $syntheticCommand=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('Write-Output ''{"type":"result","subtype":"success","is_error":false,"result":"SYNTHETIC_CAPACITY_CHILD"}'''))
    & $LauncherPath -Harness codex -Model gpt-6.1-sol -Effort high -Placement provisional -Row 4 -LaneRole implementation `
      -PromptFile $prompt -Worktree $repo -Label $label -ExecutablePath (Join-Path $PSHOME 'pwsh.exe') `
      -TestRuntimeRoot $runtime -TestTempRoot $providerTemp -TestArgumentList @('-NoProfile','-NonInteractive','-EncodedCommand',$syntheticCommand) | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) 'synthetic capacity child completes under its harness audit'
    $rows=@(Get-Content (Join-Path $runtime 'dispatch-log.jsonl')|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json -DateKind String})
    Assert-True ($rows.Count -eq 1 -and $rows[0].dispatchRoutingSchema -ceq 'watchdog-dispatch-routing/v3' -and
      $rows[0].harness -ceq $p.harness -and $rows[0].capacityForecastStatus -ceq $p.capacityForecastStatus -and
      (Test-DispatchRoutingLedgerEvidence $rows[0])) 'exactly one valid v3 row matches DryRun capacity decision'
    $spec=Get-Content (Join-Path $runtime "watchdog-lane-$label.json") -Raw|ConvertFrom-Json -DateKind String
    Assert-True ($spec.model -ceq $p.routing.model -and $spec.effort -ceq $p.routing.effort -and $spec.harness -ceq $p.harness) 'watchdog envelope synchronized with active/shadow dispatch'
    Assert-True ((Get-FileHash (Join-Path $runtime "$label.capacity-forecast.json")).Hash -ceq
      (Get-FileHash (Join-Path $fixture.stateRoot 'capacity-forecast.json')).Hash) 'capture retains exact consumed forecast bytes'
    Write-Output "PASS dispatch routing $Name"
    return
  }
  switch($Name){
    'policy' {
      $a=Plan
      $fixture.policy.generation=2
      $fixture.policy.rows['4'].slots['codex.primary']=[ordered]@{family='gamma';effort='medium';placement='provisional'}
      Write-State
      $b=Plan
      Assert-True ($a.routing.model-ceq'gpt-99-alpha'-and$b.routing.model-ceq'gpt-99-gamma'-and
        $b.routing.effort-ceq'medium'-and$b.routing.placement-ceq'provisional'-and$b.routing.policyGeneration-eq2) 'policy generation changes dispatch model, effort and placement without reinstall'
      Refuses @{Placement='measured'} 'ROUTING_PLACEMENT_MISMATCH'
      $fixture.policy.rows['4'].slots['codex.primary'].placement='reserve';Write-State
      Refuses @{} 'ROUTING_PLACEMENT_UNSUPERVISED'
    }
    'current' {
      $a=Plan
      $fixture.registry.families.alpha.current='gpt-99-alpha-next'
      $fixture.registry.families.alpha.historical=@('gpt-99-old','gpt-99-alpha')
      $fixture.registry.models['gpt-99-alpha-next']=$fixture.registry.models['gpt-99-alpha']
      Write-State
      foreach($row in @(2,4,7,8,11,12,13)){
        $b=Plan @{Row=$row}
        Assert-True ($a.routing.model-ceq'gpt-99-alpha'-and$b.routing.model-ceq'gpt-99-alpha-next'-and
          @($b.arguments)-ccontains'gpt-99-alpha-next') "family current changes row $row launch arguments"
      }
    }
    'admission' {
      $fixture.registry.models['gpt-99-alpha'].admittedEfforts=@('medium');Write-State
      $a=Plan
      Assert-True ($a.harness-ceq'claude'-and$a.routing.model-ceq'claude-99-beta'-and$a.routing.slot-ceq'claude.fallback') 'unadmitted effort takes other family slot'
      Reset-Fixture
      $fixture.registry.models['gpt-99-alpha'].usableAccountsByEffort.high=@();Write-State
      $b=Plan
      Assert-True ($b.routing.family-ceq'beta') 'no usable account takes other family slot'
      $fixture.registry.models['claude-99-beta'].usableAccountsByEffort.medium=@();Write-State
      Refuses @{} 'REGISTRY_NO_USABLE_ACCOUNTS'
    }
    'explicit' {
      $a=Plan @{Model='gpt-99-alpha';Effort='medium';Placement='override-Todd'}
      Assert-True ($a.routing.slot-ceq'explicit'-and$a.routing.effort-ceq'medium') 'explicit registry current configuration remains supported'
      Refuses @{Model='gpt-99-old';Effort='high'} 'EXPLICIT_HISTORICAL_OR_RETIRED_MODEL'
      Refuses @{Model='gpt-99-alpha'} 'supplied together'
      $fixture.registry.models['gpt-99-alpha'].admittedEfforts=@('medium');Write-State
      Refuses @{Model='gpt-99-alpha';Effort='high'} 'EFFORT_NOT_ADMITTED'
    }
    'lkg' {
      [void](Plan)
      [IO.File]::Delete((Join-Path $fixture.stateRoot 'model-registry.json'))
      $b=Plan
      Assert-True ($b.routing.usedLastKnownGood-eq$true-and$b.routing.sourceReason-ceq'ROUTING_DATA_MISSING') 'dispatch output flags cached authority'
      [IO.File]::Delete($fixture.lkgPath)
      Refuses @{} 'NO_VALID_LKG'
    }
    'evidence' {
      $fixture.policy.generation=9;$fixture.registry.authorityDigest='dispatch-fixture-digest';Write-State
      $plan=Plan
      $label='evidence-'+[guid]::NewGuid().ToString('N')
      try {
        & $LauncherPath -Harness codex -Row 4 -LaneRole implementation -PromptFile $prompt -Worktree $repo -Label $label `
          -ExecutablePath (Join-Path $PSHOME 'pwsh.exe') -TestRuntimeRoot $runtime -TestTempRoot $providerTemp `
          -TestArgumentList @('-NoProfile','-NonInteractive','-Command','Write-Output SYNTHETIC_ROUTING_CHILD') | Out-Null
      } catch { throw "ASSERTION FAILED: selected evidence did not reach the foreground child: $($_.Exception.Message)" }
      Assert-True ($LASTEXITCODE-eq0) 'synthetic foreground child completes'
      $ledger=Get-Content (Join-Path $runtime 'dispatch-log.jsonl') -Tail 1 | ConvertFrom-Json -DateKind String
      Assert-True ($ledger.dispatchRoutingSchema-ceq'watchdog-dispatch-routing/v3'-and$ledger.policyGeneration-eq9-and
        $ledger.registryAuthorityDigest-ceq'dispatch-fixture-digest'-and$ledger.family-ceq'alpha'-and
        $ledger.slot-ceq'codex.primary'-and$ledger.usedLastKnownGood-eq$false-and$ledger.model-ceq$plan.routing.model) 'dispatch ledger carries exact selection evidence'
    }
    'ledger-readers' {
      $legacy=[pscustomobject]@{dispatchRoutingSchema='watchdog-dispatch-routing/v1'}
      Assert-True ((Test-DispatchRoutingLedgerEvidence $legacy)-and@(Get-DispatchRoutingLedgerKeys $legacy.dispatchRoutingSchema).Count-eq16) 'historical ledger schema remains readable'
      $row=[pscustomobject]@{dispatchRoutingSchema='watchdog-dispatch-routing/v2';policyGeneration=[long]2;registryAuthorityDigest='test';family='alpha';slot='explicit';usedLastKnownGood=$false}
      Assert-True ((Test-DispatchRoutingLedgerEvidence $row)-and@(Get-DispatchRoutingLedgerKeys $row.dispatchRoutingSchema).Count-eq21) 'v2 reader admits closed evidence fields'
      foreach($field in @('policyGeneration','registryAuthorityDigest','family','slot','usedLastKnownGood')){
        $copy=$row|ConvertTo-Json|ConvertFrom-Json -DateKind String;$copy.PSObject.Properties.Remove($field)
        Assert-True (-not(Test-DispatchRoutingLedgerEvidence $copy)) "v2 reader refuses missing $field"
      }
    }
  }
  Write-Output "PASS dispatch routing $Name"
}
try {
  $repo=Join-Path $root 'repo';$runtime=Join-Path $root 'runtime';$providerTemp=Join-Path $root 'provider-temp'
  [void][IO.Directory]::CreateDirectory($runtime);[void][IO.Directory]::CreateDirectory($providerTemp)
  & git init --quiet $repo
  & git -C $repo -c user.name=Synthetic -c user.email=synthetic@example.invalid commit --allow-empty -m synthetic --quiet
  Assert-True ($LASTEXITCODE-eq0) 'synthetic repository initialized'
  $prompt=Join-Path $root 'prompt.txt';[IO.File]::WriteAllText($prompt,'Synthetic dispatch routing test; never launch a model.')
  $cases=@('policy','current','admission','explicit','lkg','evidence','ledger-readers','capacity-shadow','capacity-active',
    'capacity-validation','capacity-matrix','capacity-history','capacity-override','capacity-exemptions','capacity-logger',
    'capacity-reserve','capacity-roles','capacity-continuation')
  if(-not $CapacityMutantsOnly){foreach($name in $cases){if($Case-ceq'all'-or$Case-ceq$name){Invoke-Case $name}}}
  if($Case-ceq'all' -and -not $CapacityMutantsOnly){
    $source=[IO.File]::ReadAllText($LauncherPath)
    $mutants=@(
      @{name='freeze-row';case='policy';old='Resolve-RoutingSelection -Row $Row -Harness $Harness -Slot';new='Resolve-RoutingSelection -Row 3 -Harness $Harness -Slot'},
      @{name='freeze-current';case='current';old='$Model = [string]$dispatchRouting.model';new='$Model = "gpt-99-alpha"'},
      @{name='admit-history';case='explicit';old='-Model $Model -Effort $Effort -StateRoot';new='-Model "gpt-99-alpha" -Effort $Effort -StateRoot'},
      @{name='drop-lkg';case='lkg';old='$dispatchRouting = Resolve-DispatchRouting';new='$dispatchRouting = Resolve-DispatchRouting; $dispatchRouting.usedLastKnownGood = $false'},
      @{name='drop-generation';case='evidence';old='-PolicyGeneration $dispatchRouting.policyGeneration';new='-PolicyGeneration 1'},
      @{name='drop-digest';case='evidence';old='-RegistryAuthorityDigest $dispatchRouting.registryAuthorityDigest';new='-RegistryAuthorityDigest "wrong-digest"'},
      @{name='drop-family';case='evidence';old='-RoutingFamily $dispatchRouting.family';new='-RoutingFamily "wrong-family"'},
      @{name='drop-slot';case='evidence';old='-RoutingSlot $dispatchRouting.slot';new='-RoutingSlot "explicit"'})
    $evidence=if($EvidenceDir){[IO.Path]::GetFullPath($EvidenceDir)}else{Join-Path $root 'mutants'}
    [void][IO.Directory]::CreateDirectory($evidence)
    foreach($m in $mutants){
      Assert-True ($source.Contains($m.old)) "mutation seam $($m.name)"
      $dir=Join-Path $evidence $m.name;[void][IO.Directory]::CreateDirectory($dir)
      Get-ChildItem -LiteralPath (Split-Path -Parent $LauncherPath) -File | Where-Object Extension -In @('.ps1','.psm1','.cjs') | Copy-Item -Destination $dir
      Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'contracts') -Destination $dir -Recurse
      $mutant=Join-Path $dir 'dispatch-lane.ps1';[IO.File]::WriteAllText($mutant,$source.Replace($m.old,$m.new))
      $log=Join-Path $dir 'child.log';$arguments=@('-NoProfile','-NonInteractive','-File',$PSCommandPath,'-LauncherPath',$mutant,'-Case',$m.case)
      & pwsh @arguments *> $log;$exit=$LASTEXITCODE
      Assert-True ($exit-eq1-and([IO.File]::ReadAllText($log)).Contains('ASSERTION FAILED')) "discriminating mutant $($m.name)"
      $receipt=[ordered]@{name=$m.name;case=$m.case;exit=$exit;source=$mutant;log=$log;arguments=$arguments}
      [IO.File]::AppendAllText((Join-Path $evidence 'results.jsonl'),(($receipt|ConvertTo-Json -Compress)+[Environment]::NewLine))
      Write-Output "PASS dispatch routing mutant=$($m.name) exit=$exit"
    }
    Write-Output "PASS dispatch-routing-data cases=$($cases.Count) discriminating-mutants=$($mutants.Count)"
  }
  if($Case -ceq 'all') {
    $capacityMutants=@(
      @{name='override-omission';file='routing-data.ps1';case='capacity-override';old='if ($Exempt) { return $result }';new='if ($false) { return $result }'},
      @{name='non-prefix-flip';file='routing-data.ps1';case='capacity-matrix';old="`$toward -ceq 'codex' -and `$Selection.row -notin @(@(3,13,10,4) | Select-Object -First `$steps)";new='$false'},
      @{name='claude-prefix-restored';file='routing-data.ps1';case='capacity-matrix';old="if (`$toward -ceq 'codex' -and `$Selection.row -notin @(@(3,13,10,4) | Select-Object -First `$steps)) { return `$result }";new="`$order=if(`$toward -ceq 'claude'){@(13,10,4,5)}else{@(3,13,10,4)};if (`$Selection.row -notin @(`$order | Select-Object -First `$steps)) { return `$result }"},
      @{name='ruled-placement-omitted';file='routing-data.ps1';case='capacity-matrix';old="if (`$toward -ceq 'claude') { `$target.placement='override-Todd' }";new='if ($false) { }'},
      @{name='blanket-sol-opus-restored';file='routing-data.ps1';case='capacity-reserve';old='if ($continuation) { [void]$excluded.Add($continuation) }';new='foreach($family in @(''sol'',''opus'')){[void]$excluded.Add([string]$data.registry.families.PSObject.Properties[$family].Value.current)}'},
      @{name='continuation-omitted';file='routing-data.ps1';case='capacity-continuation';old='if ($continuation) { [void]$excluded.Add($continuation) }';new=''},
      @{name='fable-window-omitted';file='routing-data.ps1';case='capacity-reserve';old="(Get-CapacityFableWindowState `$f) -cnotin @('spend','normal')";new='$false'},
      @{name='fable-once-omitted';file='routing-data.ps1';case='capacity-reserve';old="if ((Get-RoutingModelIdentity `$data.registry `$model).family -ceq 'fable')";new='if ($false)'},
      @{name='fable-role-omitted';file='routing-data.ps1';case='capacity-roles';old="if (`$LaneRole -cne 'implementation' -or `$Selection.row -notin @(7,14,15) -or";new="if (`$Selection.row -notin @(7,14,15) -or"},
      @{name='artifact-author-omitted';file='routing-data.ps1';case='capacity-roles';old='} elseif (@($history.models) -ccontains [string]$target.model) {';new='} elseif ($false) {'},
      @{name='lifecycle-brief-author-omitted';file='routing-data.ps1';case='capacity-roles';old="if (`$role -ceq 'planning' -and -not `$planningReceipt) { return 'brief' } # CAPACITY_LIFECYCLE_BRIEF";new="if (`$role -ceq 'planning') { return `$null } # MUTANT"},
      @{name='planning-receipt-authorship-restored';file='routing-data.ps1';case='capacity-roles';old="if (`$role -ceq 'planning' -and -not `$planningReceipt) { return 'brief' } # CAPACITY_LIFECYCLE_BRIEF";new="if (`$role -ceq 'planning') { return 'brief' } # MUTANT"},
      @{name='lifecycle-code-author-omitted';file='routing-data.ps1';case='capacity-roles';old="if (`$role -ceq 'implementation') { return 'code' } # CAPACITY_LIFECYCLE_CODE";new="if (`$role -ceq 'implementation') { return `$null } # MUTANT"},
      @{name='code-exclusion-dropped';file='routing-data.ps1';case='capacity-roles';old="    if (`$role -ceq 'implementation') { return 'code' }`n    if (`$role -ceq 'planning') { return 'brief' }`n    if (`$role -ceq 'review') { return `$null }";new="    if (`$role -ceq 'implementation') { return `$null }`n    if (`$role -ceq 'planning') { return 'brief' }`n    if (`$role -ceq 'review') { return `$null }"},
      @{name='brief-authors-merged';file='routing-data.ps1';case='capacity-roles';old="    if (`$role -ceq 'planning') { return 'brief' }`n    if (`$role -ceq 'review') { return `$null }";new="    if (`$role -ceq 'planning') { return 'code' }`n    if (`$role -ceq 'review') { return `$null }"},
      @{name='other-artifact-followed';file='routing-data.ps1';case='capacity-roles';old='-and $rowIssue.Value -ne $Issue){continue} # CAPACITY_GUARD_OTHER_ARTIFACT';new='-and $false){continue} # MUTANT'},
      @{name='artifact-required-omitted';file='routing-data.ps1';case='capacity-exemptions';old="-or -not `$historyArguments.Artifact) { `$result.capacityFlipSkip='REVIEWER_HISTORY_UNKNOWN';return `$result }";new=") { `$result.capacityFlipSkip='REVIEWER_HISTORY_UNKNOWN';return `$result }; if(-not `$historyArguments.Artifact){`$historyArguments.Artifact='code'}"},
      @{name='role-row-rule-omitted';file='dispatch-ownership.ps1';case='capacity-logger';old="if(`$flip.toward -ceq 'codex' -and `$flip.row -notin @(@(3,13,10,4) | Select-Object -First `$flip.steps)){return `$false}";new='if($flip.row -notin @(@(13,10,4,5) | Select-Object -First $flip.steps)){return $false}'},
      @{name='logger-ruled-placement-omitted';file='log-event.ps1';case='capacity-logger';old="if(`$proposed.toward -ceq 'claude'){`$own.placement='override-Todd'}";new=''},
      @{name='shadow-applied';file='routing-data.ps1';case='capacity-shadow';old="if (`$inputForecast.status -ceq 'shadow')";new='if ($false)'},
      @{name='own-row-effort';file='routing-data.ps1';case='capacity-active';old='$result.selection=$target';new='$target.effort="high";$result.selection=$target'},
      @{name='drop-generic-author';file='routing-data.ps1';case='capacity-history';old='$authors.Add($e.model) # CAPACITY_GUARD_GENERIC_HISTORY';new='if($e.dispatchRoutingSchema){$authors.Add($e.model)} # MUTANT'},
      @{name='drop-patched-reviewer';file='routing-data.ps1';case='capacity-history';old='if ($e.reviewerPatch) { # CAPACITY_GUARD_PATCH_AUTHOR';new='if ($false) { # MUTANT'},
      @{name='partial-history-admitted';file='routing-data.ps1';case='capacity-history';old='$e.historyComplete -eq $false';new='$false'},
      @{name='duplicate-author-erased';file='routing-data.ps1';case='capacity-history';old='if(-not $members.Add($property.Name)){return $unknown}';new='[void]$members.Add($property.Name)'},
      @{name='unknown-history-admitted';file='routing-data.ps1';case='capacity-history';old='if (-not $history.complete)';new='if ($false)'},
      @{name='reviewer-exclusion-omitted';file='routing-data.ps1';case='capacity-history';old='-not $excluded.Contains($model) -and';new=''},
      @{name='nested-validator-omitted';file='dispatch-ownership.ps1';case='capacity-logger';old='function Test-DispatchCapacityEvidence($Record) {';new='function Test-DispatchCapacityEvidence($Record) { return $true'},
      @{name='duration-omitted';file='routing-data.ps1';case='capacity-validation';old='$generated -gt $NowUtc -or $expires -le $generated -or ($expires-$generated).TotalMinutes -gt 15';new='$false'})
    # Each validity leg has its own reachable omission; malformed controls do
    # not count a parse failure or an unrelated refusal as a killed guard.
    $capacityMutants+=@(
      @{name='digest-omitted';file='routing-data.ps1';case='capacity-validation';old="`$f.decisionDigest -isnot [string] -or `$f.decisionDigest -cnotmatch '^[a-f0-9]{16}$'";new='$false'},
      @{name='mode-omitted';file='routing-data.ps1';case='capacity-validation';old="`$f.mode -isnot [string] -or `$f.mode -cnotin @('active','shadow')";new='$false'},
      @{name='format-omitted';file='routing-data.ps1';case='capacity-validation';old="`$f.format -isnot [string] -or `$f.format -cne 'capacity-forecast/v1'";new='$false'},
      @{name='object-omitted';file='routing-data.ps1';case='capacity-validation';old='if ($object -is [array] -or -not (Test-RoutingObject $object))';new='if ($false)'},
      @{name='provider-state-omitted';file='routing-data.ps1';case='capacity-validation';old="`$f.providers.`$provider.state -isnot [string] -or`r`n          `$f.providers.`$provider.state -cnotin @('conserve','normal','spend','unknown')";new='$false'},
      @{name='stale-omitted';file='routing-data.ps1';case='capacity-validation';old='if ($NowUtc -ge $expires)';new='if ($false)'},
      @{name='unknown-omitted';file='routing-data.ps1';case='capacity-validation';old="if (`$f.providers.codex.state -ceq 'unknown' -or `$f.providers.claude.state -ceq 'unknown')";new='if ($false)'},
      @{name='steps-integer-omitted';file='routing-data.ps1';case='capacity-validation';old='$f.balance.steps -isnot [long] -or';new=''},
      @{name='toward-presence-omitted';file='routing-data.ps1';case='capacity-validation';old="`$null -eq `$f.balance.PSObject.Properties['toward'] -or";new=''})
    $capacityMutants+=@(
      @{name='steps-upper-omitted';file='routing-data.ps1';case='capacity-validation';old='-or $f.balance.steps -gt 4';new=''},
      @{name='steps-lower-omitted';file='routing-data.ps1';case='capacity-validation';old='-or $f.balance.steps -lt 0';new=''},
      @{name='instant-syntax-omitted';file='routing-data.ps1';case='capacity-validation';old="`$Value -cnotmatch '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|[+-]\d\d:\d\d)$' -or";new=''})
    $evidence=if($EvidenceDir){[IO.Path]::GetFullPath($EvidenceDir)}else{Join-Path $root 'capacity-mutants'}
    [void][IO.Directory]::CreateDirectory($evidence)
    foreach($m in $capacityMutants){
      $source=[IO.File]::ReadAllText((Join-Path (Split-Path -Parent $LauncherPath) $m.file)).Replace("`r`n","`n")
      $old=$m.old.Replace("`r`n","`n");Assert-True ($source.Contains($old)) "capacity mutation seam $($m.name)"
      $dir=Join-Path $evidence $m.name;[void][IO.Directory]::CreateDirectory($dir)
      Get-ChildItem -LiteralPath (Split-Path -Parent $LauncherPath) -File | Where-Object Extension -In @('.ps1','.psm1','.cjs') | Copy-Item -Destination $dir
      Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'contracts') -Destination $dir -Recurse -Force
      [IO.File]::WriteAllText((Join-Path $dir $m.file),$source.Replace($old,$m.new))
      $log=Join-Path $dir 'child.log'
      & pwsh -NoProfile -NonInteractive -File $PSCommandPath -LauncherPath (Join-Path $dir 'dispatch-lane.ps1') -Case $m.case *> $log
      $code=$LASTEXITCODE
      Assert-True ($code -eq 1 -and ([IO.File]::ReadAllText($log)).Contains('ASSERTION FAILED:')) "capacity mutant killed $($m.name) exit=$code"
      [IO.File]::AppendAllText((Join-Path $evidence 'capacity-results.jsonl'),(([ordered]@{name=$m.name;case=$m.case;exit=$code;log=$log}|ConvertTo-Json -Compress)+"`n"))
      Write-Output "PASS capacity mutant=$($m.name) exit=$code"
    }
  }
} finally {
  $env:CHASE_SETS_ROUTING_DATA_ROOT=$oldRoot;$env:CHASE_SETS_ROUTING_LKG_PATH=$oldLkg
  $resolved=[IO.Path]::GetFullPath($root)
  if((Split-Path -Parent $resolved).TrimEnd('\','/') -cne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/') -or
      (Split-Path -Leaf $resolved)-notlike'dispatch-routing-data-*'){throw 'unsafe fixture cleanup'}
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
