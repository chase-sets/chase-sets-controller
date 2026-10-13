[CmdletBinding()]
param([string]$HarvestPath=(Join-Path $PSScriptRoot 'cost-harvest.ps1'),
  [string]$RefreshPath=(Join-Path $PSScriptRoot 'matrix-refresh.ps1'),
  [ValidateSet('all','prices','identities','efforts','evidence','unavailable','unknown-rates','normalization')][string]$Case='all',
  [string]$EvidenceDir)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'routing-data-test-support.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('cost-routing-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$oldRoot=$env:CHASE_SETS_ROUTING_DATA_ROOT;$oldLkg=$env:CHASE_SETS_ROUTING_LKG_PATH
function Assert-True([bool]$Value,[string]$Message) { if(-not $Value){throw "ASSERTION FAILED: $Message"} }
function Write-Json([string]$Path,$Value) { [IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 60),[Text.UTF8Encoding]::new($false)) }
function Reset-Fixture {
  $script:fixture=New-RoutingDataFixture -Root (Join-Path $root 'state') -Families @(
    [pscustomobject]@{name='alpha';provider='codex';current='gpt-99-alpha';historical=@('gpt-5.6-sol')},
    [pscustomobject]@{name='beta';provider='codex';current='gpt-99-beta';historical=@()}) -BenchmarkRows @(
    [pscustomobject]@{model='gpt-99-alpha';effort='high';usdPerTask=6.0;pricing=[pscustomobject]@{price_1m_input_tokens=2.0;price_1m_output_tokens=10.0}},
    [pscustomobject]@{model='gpt-99-alpha';effort='medium';usdPerTask=3.0;pricing=[pscustomobject]@{price_1m_input_tokens=2.0;price_1m_output_tokens=10.0}},
    [pscustomobject]@{model='gpt-5.6-sol';effort='high';usdPerTask=8.0;pricing=[pscustomobject]@{price_1m_input_tokens=5.0;price_1m_output_tokens=30.0}})
  $env:CHASE_SETS_ROUTING_DATA_ROOT=$fixture.stateRoot;$env:CHASE_SETS_ROUTING_LKG_PATH=$fixture.lkgPath
  if([IO.File]::Exists($fixture.lkgPath)){[IO.File]::Delete($fixture.lkgPath)}
  $script:transcriptRoot=Join-Path $root ([guid]::NewGuid().ToString('N'))
  [void][IO.Directory]::CreateDirectory($transcriptRoot)
  $script:ledgerPath=Join-Path $transcriptRoot 'cost-ledger.jsonl'
  $script:snapshotPath=Join-Path $fixture.stateRoot 'benchmarks/synthetic-benchmark.json'
  $script:registryPath=Join-Path $fixture.stateRoot 'model-registry.json'
  $script:policyPath=Join-Path $fixture.stateRoot 'routing-policy.json'
  $script:dispatchPath=Join-Path $transcriptRoot 'dispatch-log.jsonl'
  [IO.File]::WriteAllText($dispatchPath,'')
}
function New-Transcript([string]$Name,[string]$NativeModel,[nullable[double]]$ReportedUsd) {
  $lines=@()
  if($NativeModel){$lines+='{"type":"system","subtype":"init","model":"'+$NativeModel+'"}'}
  if($null-ne$ReportedUsd){$lines+='{"type":"result","subtype":"success","total_cost_usd":'+$ReportedUsd+'}'}
  else {$lines+='{"type":"turn.completed","usage":{"input_tokens":10000,"cached_input_tokens":2000,"cache_write_input_tokens":1000,"output_tokens":1000,"reasoning_output_tokens":500}}'}
  [IO.File]::WriteAllLines((Join-Path $transcriptRoot $Name),$lines)
}
function Harvest {
  try { & $HarvestPath -TranscriptDir $transcriptRoot -Ledger $ledgerPath | Out-Null }
  catch { throw "ASSERTION FAILED: fixture harvest unexpectedly refused: $($_.Exception.Message)" }
  $map=@{}
  foreach($line in Get-Content -LiteralPath $ledgerPath){$r=$line|ConvertFrom-Json -DateKind String;$map[$r.transcript]=$r}
  return $map
}
function Assert-NoNormalization($Row) {
  Assert-True ($null-eq$Row.usdCurrent-and$null-eq$Row.usdCurrentLower-and$null-eq$Row.usdCurrentUpper) 'missing context/cache authority must never become normalized USD'
}
function Invoke-Case([string]$Name) {
  Reset-Fixture
  $file='1234-gpt-99-alpha--high-task.jsonl'
  New-Transcript $file
  switch($Name){
    prices {
      $r=(Harvest)[$file]
      Assert-True ($r.model-ceq'gpt-99-alpha'-and$r.effort-ceq'high'-and$r.benchmarkUsdPerTask-eq6-and$r.currentPriceInPerM-eq2-and$r.currentPriceOutPerM-eq10) 'initial exact benchmark prices'
      Assert-True ($null-eq$r.usd-and$r.costSource-ceq'tokens-no-billed-price') 'new model has no invented effective-dated billing'
      $snapshot=Get-Content $snapshotPath|ConvertFrom-Json -AsHashtable
      $snapshot.rows[0].usdPerTask=12.0;$snapshot.rows[0].pricing.price_1m_input_tokens=7.0;$snapshot.rows[0].pricing.price_1m_output_tokens=19.0
      Write-Json $snapshotPath $snapshot
      $r=(Harvest)[$file]
      Assert-True ($r.benchmarkUsdPerTask-eq12-and$r.currentPriceInPerM-eq7-and$r.currentPriceOutPerM-eq19) 'same-size transcript reprices from changed snapshot with no force, reinstall or script edit'
      $before=@(Get-Content $ledgerPath).Count
      [void](Harvest)
      Assert-True (@(Get-Content $ledgerPath).Count-eq$before) 'unchanged snapshot and transcript remain idempotent'
      $next=Join-Path $fixture.stateRoot 'benchmarks/synthetic-next.json';$snapshot.rows[0].usdPerTask=15.0;Write-Json $next $snapshot
      Write-Json (Join-Path $fixture.stateRoot 'benchmarks/latest.json') @{file='synthetic-next.json'}
      $r=(Harvest)[$file]
      Assert-True ($r.benchmarkUsdPerTask-eq15-and$r.benchmarkSnapshot-ceq'synthetic-next.json') 'latest pointer controls exact snapshot, not a frozen filename'
      Assert-NoNormalization $r
    }
    identities {
      $snapshot=Get-Content $snapshotPath|ConvertFrom-Json -AsHashtable
      $snapshot.rows+=@(@{model='gpt-100-alpha';effort='high';usdPerTask=11.0;pricing=@{price_1m_input_tokens=4.0;price_1m_output_tokens=20.0}})
      Write-Json $snapshotPath $snapshot
      $new='1235-gpt-100-alpha--high-task.jsonl';New-Transcript $new
      Assert-True ($null-eq(Harvest)[$new].model) 'benchmark catalog alone never establishes filename model identity'
      $registry=Get-Content $registryPath|ConvertFrom-Json -AsHashtable -DateKind String
      $registry.families.alpha.current='gpt-100-alpha';$registry.families.alpha.historical+=@('gpt-99-alpha')
      $registry.models['gpt-100-alpha']=$registry.models['gpt-99-alpha']
      Write-Json $registryPath $registry
      $unlisted='1236-gpt-101-alpha--high-task.jsonl';New-Transcript $unlisted
      $rows=Harvest
      Assert-True ($rows[$new].model-ceq'gpt-100-alpha'-and$rows[$new].benchmarkUsdPerTask-eq11) 'registry-current swap adds exact filename identity without reinstall'
      Assert-True ($rows[$file].model-ceq'gpt-99-alpha'-and$rows[$file].benchmarkUsdPerTask-eq6) 'historical exact identity remains readable without relabeling or successor pricing'
      Assert-True ($null-eq$rows[$unlisted].model-and$rows[$unlisted].routingCostSource-ceq'tokens-no-model') 'unlisted version cannot become filename price authority'
      foreach($entry in $registry.models.Values){foreach($effort in @($entry.usableAccountsByEffort.Keys)){$entry.usableAccountsByEffort[$effort]=@()}}
      Write-Json $registryPath $registry
      $r=(Harvest)[$new]
      Assert-True ($r.benchmarkUsdPerTask-eq11) 'read-only historical price telemetry is roster membership, not new-work admission'
    }
    efforts {
      $medium='1235-gpt-99-alpha--medium-task.jsonl';New-Transcript $medium
      $bare='1236-gpt-99-alpha.jsonl';New-Transcript $bare
      $unnamed='1237-synthetic-bound.jsonl';New-Transcript $unnamed
      $binding=@{kind='dispatch';transcript=$unnamed;model='gpt-99-alpha';effort='high'}
      [IO.File]::WriteAllText($dispatchPath,($binding|ConvertTo-Json -Compress))
      $rows=Harvest
      Assert-True ($rows[$file].benchmarkUsdPerTask-eq6-and$rows[$medium].benchmarkUsdPerTask-eq3) 'per-task price never crosses exact efforts'
      Assert-True ($null-eq$rows[$bare].benchmarkUsdPerTask-and$rows[$bare].currentPriceInPerM-eq2) 'unresolved effort keeps only unanimous standard rates, never guesses per-task USD'
      Assert-True ($rows[$unnamed].effort-ceq'high'-and$rows[$unnamed].benchmarkUsdPerTask-eq6) 'exact dispatch binding supplies effort'
      $binding.effort='medium';[IO.File]::WriteAllText($dispatchPath,($binding|ConvertTo-Json -Compress))
      $r=(Harvest)[$unnamed]
      Assert-True ($r.effort-ceq'medium'-and$r.benchmarkUsdPerTask-eq3) 'binding change invalidates same-size cached harvest without force'
      [IO.File]::WriteAllLines($dispatchPath,@(($binding|ConvertTo-Json -Compress),(@{kind='dispatch';transcript=$unnamed;model='gpt-99-alpha';effort='high'}|ConvertTo-Json -Compress)))
      $r=(Harvest)[$unnamed]
      Assert-True ($null-eq$r.effort-and$null-eq$r.benchmarkUsdPerTask) 'conflicting effort bindings remain unknown without discarding known model'
      $native='1238-gpt-99-beta--high-task.jsonl';New-Transcript $native 'gpt-99-alpha'
      $r=(Harvest)[$native]
      Assert-True ($r.model-ceq'gpt-99-alpha'-and$null-eq$r.effort-and$null-eq$r.benchmarkUsdPerTask) 'native model never borrows a different filename model effort'
    }
    evidence {
      $policy=Get-Content $policyPath|ConvertFrom-Json -AsHashtable;$policy.generation=41;Write-Json $policyPath $policy
      $r=(Harvest)[$file]
      Assert-True ($r.policyGeneration-eq41-and$r.registryAuthorityDigest-ceq'synthetic-consumer-authority'-and-not$r.usedLastKnownGood-and$null-eq$r.routingSourceReason) 'fresh cost evidence carries exact policy and registry authority'
      $registry=Get-Content $registryPath|ConvertFrom-Json -AsHashtable -DateKind String;$registry.generatedAt=[DateTimeOffset]::UtcNow.AddHours(-4).ToString('o');Write-Json $registryPath $registry
      $r=(Harvest)[$file]
      Assert-True ($r.usedLastKnownGood-and$r.routingSourceReason-ceq'REGISTRY_STALE_GENERATED_AT'-and$r.policyGeneration-eq41-and$r.benchmarkUsdPerTask-eq6) 'stale registry uses visibly flagged validated LKG'
      [IO.File]::Delete($registryPath)
      $r=(Harvest)[$file]
      Assert-True ($r.usedLastKnownGood-and$r.routingSourceReason-ceq'ROUTING_DATA_MISSING'-and$r.benchmarkUsdPerTask-eq6) 'missing source uses LKG without hiding reason'
      [IO.File]::WriteAllText($registryPath,'{invalid')
      $r=(Harvest)[$file]
      Assert-True ($r.usedLastKnownGood-and$r.routingSourceReason-ceq'ROUTING_DATA_UNPARSEABLE') 'unparsable source uses flagged LKG'
    }
    unavailable {
      $historical='1235-gpt-5.6-sol--high-task.jsonl';New-Transcript $historical
      $native='1236-synthetic-reported.jsonl';New-Transcript $native 'gpt-99-alpha' 1.234
      $before=Harvest
      [IO.File]::Delete($registryPath);[IO.File]::Delete($fixture.lkgPath)
      $rows=Harvest
      Assert-True ($rows[$historical].usd-eq$before[$historical].usd-and$rows[$historical].usd-gt0-and$rows[$historical].costSource-ceq'token-derived-short-exact') 'source loss does not destroy effective-dated billed facts'
      Assert-True ($rows[$native].usd-eq1.234-and$rows[$native].usdCurrent-eq1.234-and$rows[$native].routingCostSource-ceq'stream-json') 'source loss preserves native reported USD authority'
      Assert-True ($rows[$historical].routingSourceReason-ceq'ROUTING_DATA_REFUSED:ROUTING_DATA_MISSING:NO_VALID_LKG'-and-not$rows[$historical].usedLastKnownGood-and$null-eq$rows[$historical].benchmarkUsdPerTask-and$null-eq$rows[$historical].currentPriceInPerM) 'no valid source gives named degraded telemetry, never old standard rates'
      Assert-NoNormalization $rows[$historical]
    }
    unknown-rates {
      $bare='1235-gpt-99-alpha.jsonl';New-Transcript $bare
      $snapshot=Get-Content $snapshotPath|ConvertFrom-Json -AsHashtable;$snapshot.rows[0].pricing.price_1m_input_tokens=$true;Write-Json $snapshotPath $snapshot
      $r=(Harvest)[$file]
      Assert-True ($r.benchmarkPricingReason-ceq'BENCHMARK_STANDARD_PRICE_INVALID'-and$null-eq$r.currentPriceInPerM-and$r.benchmarkUsdPerTask-eq6) 'invalid standard rate cannot erase independent task price or become numeric authority'
      $snapshot.rows[0].pricing.price_1m_input_tokens=7.0;Write-Json $snapshotPath $snapshot
      $r=(Harvest)[$bare]
      Assert-True ($r.benchmarkPricingReason-ceq'BENCHMARK_STANDARD_PRICE_AMBIGUOUS'-and$null-eq$r.currentPriceInPerM-and$null-eq$r.benchmarkUsdPerTask) 'conflicting same-model standard rates never guess effort'
      $snapshot.rows=@();Write-Json $snapshotPath $snapshot
      $r=(Harvest)[$file]
      Assert-True ($r.benchmarkPricingReason-ceq'BENCHMARK_CONFIGURATION_UNPRICED'-and$null-eq$r.currentPriceInPerM-and$null-eq$r.benchmarkUsdPerTask) 'fresh missing configuration price does not revive older cached price'
      Assert-NoNormalization $r
    }
    normalization {
      $historical='1235-sol-high-task.jsonl';New-Transcript $historical
      $native='1236-gpt-99-alpha--high-reported.jsonl';New-Transcript $native 'gpt-99-alpha' 2.5
      $rows=Harvest
      Assert-NoNormalization $rows[$historical]
      Assert-True ($rows[$historical].usd-gt0-and$rows[$historical].routingCostSource-ceq'BENCHMARK_CONTEXT_CACHE_RATES_UNAVAILABLE') 'known billed USD stays separate from unavailable normalization'
      $matrix=Join-Path $root 'matrix.json'
      Write-Json $matrix @{configs=@(
        @{id='gpt-99-alpha/high';model='gpt-99-alpha';effort='high';harness='codex'},
        @{id='gpt-5.6-sol/high';model='gpt-5.6-sol';effort='high';harness='codex';historicalOnly=$true;selectable=$false})}
      try { & $RefreshPath -Matrix $matrix -CostLedger $ledgerPath -DispatchLog $dispatchPath -Json | Out-Null }
      catch { throw "ASSERTION FAILED: fixture matrix unexpectedly refused: $($_.Exception.Message)" }
      $m=Get-Content $matrix|ConvertFrom-Json
      Assert-True ($m.measuredAt.unknownRoutingCostRuns-eq2-and$m.measuredAt.runsWithCost-eq1-and$m.measuredAt.totalUsd-eq2.5) 'matrix records unknown normalization without falling back to billed USD'
      Assert-True (-not$m.configs[1].PSObject.Properties['measured']-and$m.configs[0].measured.n-eq1) 'unknown cost supplies no measured cost sample while native reported cost remains readable'
    }
  }
  Write-Output "PASS cost-routing-data case=$Name"
}
try {
  if($Case-ne'all'){Invoke-Case $Case;return}
  $cases=@('prices','identities','efforts','evidence','unavailable','unknown-rates','normalization')
  foreach($name in $cases){Invoke-Case $name}
  $mutants=@(
    @{name='freeze-task-price';case='prices';find='$result.usdPerTask = $price.usdPerTask';replace='$result.usdPerTask = 6.0'},
    @{name='freeze-token-rate';case='prices';find='$result.inputPerM = $rates[0].input';replace='$result.inputPerM = 2.0'},
    @{name='freeze-price-cache';case='prices';find='$already[$t.Name].routingPricingIdentity -ceq $routingPricingIdentity';replace='$true'},
    @{name='freeze-binding-cache';case='efforts';find='$already[$t.Name].dispatchBindingIdentity -ceq $bindingIdentity';replace='$true'},
    @{name='freeze-filename-set';case='identities';find='$exactSelectors = @($exactModelSet | ForEach-Object { [regex]::Escape($_) }) -join ''|''';replace='$exactSelectors = ''gpt-99-alpha|gpt-5\.6-sol'''},
    @{name='ignore-registry-price-identity';case='identities';find='registryModels=$registryModelSet';replace='registryModels=@()'},
    @{name='guess-task-effort';case='efforts';find='if ($Effort) {';replace='if (-not $Effort) { $Effort = "high" }; if ($Effort) {'},
    @{name='drop-generation';case='evidence';find='policyGeneration = $(if ($routingData) { $routingData.policyGeneration } else { $null })';replace='policyGeneration = 1'},
    @{name='drop-digest';case='evidence';find='registryAuthorityDigest = $(if ($routingData) { $routingData.registryAuthorityDigest } else { $null })';replace='registryAuthorityDigest = "wrong"'},
    @{name='drop-lkg';case='evidence';find='usedLastKnownGood = $(if ($routingData) { $routingData.usedLastKnownGood } else { $false })';replace='usedLastKnownGood = $false'},
    @{name='hide-source-loss';case='unavailable';find='routingSourceReason = $(if ($routingData) { $routingData.sourceReason } else { $routingSourceReason })';replace='routingSourceReason = $null'},
    @{name='admit-invalid-rate';case='unknown-rates';find='$rate -is [bool]';replace='$false'},
    @{name='guess-normalization';case='normalization';find='$facts.usd = $facts.usdUpper';replace='$facts.usd = $facts.usdUpper; $facts.usdCurrent = $facts.usdUpper'},
    @{name='matrix-billed-fallback';case='normalization';matrix=$true;find='-not $r.PSObject.Properties[''usdCurrent''] -and $null -ne $r.usd';replace='$null -ne $r.usd'}
  )
  if(-not$EvidenceDir){$EvidenceDir=Join-Path $root 'mutants'}
  [void][IO.Directory]::CreateDirectory($EvidenceDir)
  foreach($mutant in $mutants){
    $subject=if($mutant.matrix){$RefreshPath}else{$HarvestPath}
    $source=[IO.File]::ReadAllText($subject)
    Assert-True ($source.Contains($mutant.find)) "mutation seam $($mutant.name)"
    $runtime=Join-Path $EvidenceDir $mutant.name;[void][IO.Directory]::CreateDirectory($runtime)
    foreach($dependency in @('routing-data.ps1','orchestration-log-lock.psm1','controller-install-lock.psm1','review-head-contract.psm1')){
      Copy-Item -LiteralPath (Join-Path $PSScriptRoot $dependency) -Destination (Join-Path $runtime $dependency)
    }
    $mutated=Join-Path $runtime (Split-Path -Leaf $subject)
    [IO.File]::WriteAllText($mutated,$source.Replace($mutant.find,$mutant.replace),[Text.UTF8Encoding]::new($false))
    $log=Join-Path $runtime 'child.log'
    $childArgs=@('-NoProfile','-NonInteractive','-File',$PSCommandPath,'-Case',$mutant.case,
      '-HarvestPath',$(if($mutant.matrix){$HarvestPath}else{$mutated}),'-RefreshPath',$(if($mutant.matrix){$mutated}else{$RefreshPath}))
    & pwsh @childArgs *> $log
    $code=$LASTEXITCODE
    Assert-True ($code-eq1-and[IO.File]::ReadAllText($log).Contains('ASSERTION FAILED')) "discriminating mutant $($mutant.name) exit=$code"
    Add-Content -LiteralPath (Join-Path $EvidenceDir 'results.jsonl') -Value ([ordered]@{name=$mutant.name;case=$mutant.case;exitCode=$code;source=$mutated;log=$log;arguments=$childArgs}|ConvertTo-Json -Compress)
    Write-Output "PASS mutant-red name=$($mutant.name) exit=$code"
  }
  Write-Output "PASS cost-routing-data cases=$($cases.Count) discriminating-mutants=$($mutants.Count)"
} finally {
  $env:CHASE_SETS_ROUTING_DATA_ROOT=$oldRoot;$env:CHASE_SETS_ROUTING_LKG_PATH=$oldLkg
  $resolved=[IO.Path]::GetFullPath($root);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
  if((Split-Path -Parent $resolved).TrimEnd('\','/')-cne$temp-or(Split-Path -Leaf $resolved)-notlike'cost-routing-*'){throw 'unsafe cost routing cleanup root'}
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
