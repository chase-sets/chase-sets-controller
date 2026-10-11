[CmdletBinding()]
param([string]$LauncherPath=(Join-Path $PSScriptRoot 'dispatch-lane.ps1'),
  [ValidateSet('all','policy','current','admission','explicit','lkg','evidence','ledger-readers','capacity-shadow','capacity-active','capacity-validation','capacity-matrix','capacity-history','capacity-override','capacity-exemptions','capacity-logger')][string]$Case='all',
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
      foreach($toward in @('claude','codex')) {foreach($k in 0..4) {foreach($row in 1..15) {foreach($onToward in @($false,$true)) {
        $f=Copy-Forecast;$f.balance.toward=$toward;$f.balance.steps=$k;Set-Forecast $f
        $from=if($onToward){$toward}elseif($toward -ceq 'claude'){'codex'}else{'claude'}
        $model=if($from -ceq 'codex'){'gpt-6.1-sol'}else{'claude-opus-5-5'}
        $p=Plan @{Harness=$from;Model=$model;Effort='high';Placement='provisional';Row=$row}
        $order=if($toward -ceq 'claude'){@(13,10,4,5)}else{@(3,13,10,4)}
        $flip=-not $onToward -and $row -in @($order | Select-Object -First $k)
        Assert-True (($null -ne $p.capacityFlip) -eq $flip -and $p.harness -ceq $(if($flip){$toward}else{$from})) "matrix $toward k=$k row=$row on=$onToward"
        if($flip){
          $effort=if($toward -ceq 'claude'){switch($row){13{'low'} 10{'medium'} 4{'medium'} 5{'high'}}}else{if($row -in @(3,13)){'medium'}else{'high'}}
          $slot=if($toward -ceq 'codex' -and $row -eq 3){'codex.fallback'}else{"$toward.primary"}
          Assert-True ($p.routing.effort -ceq $effort -and $p.routing.slot -ceq $slot -and $p.capacityFlip.to.effort -ceq $effort) 'own row effort and slot'
        }
        $count++
      }}}}
      Write-Output "PASS capacity matrix cases=$count (150 off-toward + 150 on-toward; reversal included)"
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
          Write-History @($base,$review)
          Assert-True ($null -ne (Plan $explicit).capacityFlip) "no-patch reviewer remains eligible $schema indirect=$indirect"
          $review.reviewerPatch=$true;Write-History @($base,$review)
          Assert-True ((Plan $explicit).capacityFlipSkip -ceq 'REVIEWER_INDEPENDENCE') "patched reviewer joins author history $schema indirect=$indirect"
          foreach($invalid in @($null,'unknown-model','astra',@('gpt-6-astra'),42)) {
            $bad=$review.Clone();$bad[$modelField]=$invalid;Write-History @($base,$bad)
            Assert-True ((Plan $explicit).capacityFlipSkip -ceq 'REVIEWER_HISTORY_UNKNOWN') "invalid patch author refuses $schema"
          }
          $bad=$review.Clone();$bad.Remove($modelField);Write-History @($base,$bad)
          Assert-True ((Plan $explicit).capacityFlipSkip -ceq 'REVIEWER_HISTORY_UNKNOWN') "missing patch author refuses $schema"
          $bad=$review.Clone();$bad.reviewerPatch='true';Write-History @($base,$bad)
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
      foreach($extra in @(@{LaneRole='review'},@{LaneRole='planning'},@{LaneRole='review';Row=0},@{WatchdogRelaunchCount=1},@{ResumeOfLaunchId=[guid]::NewGuid().ToString()})) {
        $args=$explicit.Clone();foreach($key in $extra.Keys){$args[$key]=$extra[$key]}
        Assert-Unchanged (Plan $args) 'not-evaluated'
      }
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
      foreach($changes in @(@{CapacityForecastStatus='shadow'},@{CapacityForecastStatus='absent'},@{CapacityDecisionDigest='bad'},@{CapacityFlipSkip='REVIEWER_INDEPENDENCE'},@{Effort='high'},@{Row='13'},@{RoutingSlot='explicit'},@{LaneRole='planning'},@{LaneRole='review'})) {
        $args=$base.Clone();foreach($key in $changes.Keys){$args[$key]=$changes[$key]};$errorMessage=''
        try{& $logger @args|Out-Null}catch{$errorMessage=$_.Exception.Message}
        Assert-True ($errorMessage.Contains('CAPACITY_EVIDENCE_INVALID')) 'logger status/route consistency'
      }
      $args=$base.Clone();$args.CapacityFlip=$base.CapacityFlip|ConvertTo-Json -Depth 8|ConvertFrom-Json -DateKind String
      $args.CapacityFlip.to.slot='claude.fallback';$args.RoutingSlot='claude.fallback';$errorMessage=''
      try{& $logger @args|Out-Null}catch{$errorMessage=$_.Exception.Message}
      Assert-True ($errorMessage.Contains('CAPACITY_EVIDENCE_INVALID')) 'logger refuses self-consistent but wrong own policy slot'
      Write-Output 'PASS capacity real logger nested closure and status/route consistency'
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
    'capacity-validation','capacity-matrix','capacity-history','capacity-override','capacity-exemptions','capacity-logger')
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
      @{name='non-prefix-flip';file='routing-data.ps1';case='capacity-matrix';old='$Selection.row -notin @($order | Select-Object -First $steps)';new='$false'},
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
