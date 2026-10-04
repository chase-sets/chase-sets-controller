# Synthetic state for consumer tests. Never reads AgentPools or publishes a
# machine-local cache. Callers own their temporary root and environment cleanup.
function New-RoutingDataFixture {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][object[]]$Families,
    [object[]]$BenchmarkRows=@(),
    [DateTimeOffset]$NowUtc=[DateTimeOffset]::UtcNow
  )
  [void][IO.Directory]::CreateDirectory((Join-Path $Root 'benchmarks'))
  $registry=[ordered]@{
    format='model-registry/v2';generatedAt=$NowUtc.ToString('o')
    source=[ordered]@{statusCheckedAt=$NowUtc.ToString('o')}
    authorityDigest='synthetic-consumer-authority';families=[ordered]@{};models=[ordered]@{}
  }
  foreach ($family in $Families) {
    $historical=@($family.historical | Where-Object { $null -ne $_ })
    $registry.families[$family.name]=[ordered]@{
      provider=$family.provider;current=$family.current;historical=[object[]]$historical
    }
    foreach ($model in @($family.current)+$historical) {
      $usable=[ordered]@{}
      foreach ($effort in @('low','medium','high','xhigh','max')) { $usable[$effort]=@('synthetic-account') }
      $registry.models[$model]=[ordered]@{
        admittedEfforts=@('low','medium','high','xhigh','max');usableAccountsByEffort=$usable
        accounts=@([ordered]@{account='synthetic-account';efforts=@('low','medium','high','xhigh','max')
          stale=$false;usable=$true;disabled=$false;routing='ready'})
      }
    }
  }
  $first=$Families[0]
  $policy=[ordered]@{format='routing-policy/v1';generation=1;approvedBy='synthetic-test';rows=[ordered]@{}}
  foreach ($row in 1..15) {
    $policy.rows["$row"]=[ordered]@{task="synthetic row $row";slots=[ordered]@{
      "$($first.provider).primary"=[ordered]@{family=$first.name;effort='high';placement='provisional'}
    }}
  }
  foreach ($pair in @(@('routing-policy.json',$policy),@('model-registry.json',$registry),
      @('benchmarks/latest.json',[ordered]@{file='synthetic-benchmark.json'}),
      @('benchmarks/synthetic-benchmark.json',[ordered]@{rows=[object[]]@($BenchmarkRows)}))) {
    [IO.File]::WriteAllText((Join-Path $Root $pair[0]),($pair[1]|ConvertTo-Json -Depth 50),[Text.UTF8Encoding]::new($false))
  }
  return [pscustomobject]@{stateRoot=$Root;lkgPath=(Join-Path $Root 'synthetic-lkg.json');policy=$policy;registry=$registry}
}

function New-RoutingMatrixFixture {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)]$Snapshot,[object[]]$BenchmarkRows=@())
  # Keep retired matrix rows linked to the family whose current model replaced
  # them. The watchdog derives retired route identities from those families;
  # putting each retired
  # spelling in an unrelated synthetic family makes a valid historical worker
  # look like an unknown route and masks that contract.
  $familyByModel=@{
    'gpt-6-astra'='astra';'gpt-6.1-sol'='sol';'gpt-6-sol'='sol';
    'gpt-6-luna'='luna';'gpt-5.6-luna'='luna';'gpt-5.6-sol'='sol';
    'claude-fable-5-1'='fable';'claude-fable-5'='fable';
    'claude-opus-5-5'='opus';'claude-opus-5'='opus';
    'claude-sonnet-5-5'='sonnet';'claude-sonnet-5'='sonnet'
  }
  $groupsByFamily=@{}
  $index=0
  foreach($group in @($Snapshot.configs | Group-Object model)){
    $index++
    $name=if($familyByModel.ContainsKey([string]$group.Name)){[string]$familyByModel[[string]$group.Name]}else{"fixture-family-$index"}
    if(-not $groupsByFamily.ContainsKey($name)){$groupsByFamily[$name]=[Collections.Generic.List[object]]::new()}
    $groupsByFamily[$name].Add($group)
  }
  $families=@();$familyIndex=0
  foreach($name in @($groupsByFamily.Keys | Sort-Object)){
    $familyIndex++
    $groups=@($groupsByFamily[$name])
    $currentGroup=@($groups | Where-Object { @($_.Group | Where-Object historicalOnly -NE $true).Count -gt 0 } | Select-Object -First 1)
    $current=if($currentGroup.Count -eq 1){[string]$currentGroup[0].Name}else{"synthetic-current-$familyIndex"}
    $historical=@($groups | Where-Object { [string]$_.Name -cne $current } | ForEach-Object { [string]$_.Name })
    $families += [pscustomobject]@{
      name=$name;provider=[string]$groups[0].Group[0].harness;current=$current;historical=[object[]]$historical
    }
  }
  $fixture=New-RoutingDataFixture -Root $Root -Families $families -BenchmarkRows $BenchmarkRows
  # Synthetic rows mirror the reviewed routing-policy shape without copying
  # model IDs.  This gives every historical watchdog control a retained family
  # route while keeping resolution data-driven through family/current lookup.
  $rowSlots=@{
    1=@{ 'codex.primary'=@{family='luna';effort='low';placement='provisional'} }
    2=@{ 'codex.primary'=@{family='sol';effort='medium';placement='provisional'} }
    3=@{ 'claude.primary'=@{family='opus';effort='medium';placement='override-Todd'};'codex.fallback'=@{family='sol';effort='medium';placement='provisional'} }
    4=@{ 'codex.primary'=@{family='sol';effort='high';placement='provisional'};'claude.primary'=@{family='opus';effort='medium';placement='override-Todd'} }
    5=@{ 'codex.primary'=@{family='sol';effort='high';placement='provisional'};'claude.primary'=@{family='opus';effort='high';placement='override-Todd'} }
    6=@{ 'claude.primary'=@{family='opus';effort='high';placement='provisional'};'codex.primary'=@{family='astra';effort='high';placement='provisional'};'codex.fallback'=@{family='sol';effort='high';placement='provisional'} }
    7=@{ 'codex.primary'=@{family='astra';effort='high';placement='reserve'};'claude.primary'=@{family='fable';effort='high';placement='reserve'} }
    8=@{ 'claude.primary'=@{family='opus';effort='high';placement='provisional'};'codex.fallback'=@{family='sol';effort='high';placement='provisional'} }
    9=@{ 'codex.primary'=@{family='sol';effort='high';placement='provisional'};'claude.primary'=@{family='opus';effort='high';placement='override-Todd'} }
    10=@{ 'codex.primary'=@{family='sol';effort='high';placement='provisional'};'claude.primary'=@{family='opus';effort='medium';placement='override-Todd'} }
    11=@{ 'codex.primary'=@{family='sol';effort='high';placement='provisional'};'claude.fallback'=@{family='opus';effort='high';placement='provisional'} }
    12=@{ 'claude.primary'=@{family='opus';effort='medium';placement='override-Todd'};'codex.fallback'=@{family='sol';effort='high';placement='provisional'} }
    13=@{ 'codex.primary'=@{family='sol';effort='medium';placement='provisional'};'claude.primary'=@{family='opus';effort='low';placement='override-Todd'} }
    14=@{ 'claude.primary'=@{family='fable';effort='medium';placement='reserve'};'codex.fallback'=@{family='astra';effort='high';placement='reserve'} }
    15=@{ 'claude.primary'=@{family='fable';effort='high';placement='reserve'};'codex.fallback'=@{family='astra';effort='high';placement='reserve'} }
  }
  $available=@($families | ForEach-Object { [string]$_.name })
  foreach($row in 1..15){
    $slots=[ordered]@{}
    foreach($slot in $rowSlots[$row].GetEnumerator()){
      if($slot.Value.family -cin $available){$slots[[string]$slot.Key]=[ordered]@{family=[string]$slot.Value.family;effort=[string]$slot.Value.effort;placement=[string]$slot.Value.placement}}
    }
    $fixture.policy.rows[[string]$row].slots=$slots
  }
  [IO.File]::WriteAllText((Join-Path $Root 'routing-policy.json'),($fixture.policy|ConvertTo-Json -Depth 50),[Text.UTF8Encoding]::new($false))
  return $fixture
}

function New-RoutingCostBenchmarkRows {
  # Synthetic standard rates only, independent of the production billed-price
  # history. No fixture invents current long-context or cache authority.
  $rates=@{
    'gpt-5.6-sol'=@(5.0,30.0);'gpt-5.6-terra'=@(2.0,12.0);'gpt-5.6-luna'=@(0.2,1.2)
    'gpt-6-sol'=@(2.0,10.0);'gpt-6.1-sol'=@(2.0,10.0);'gpt-6-luna'=@(0.1,0.5)
    'gpt-6-astra'=@(10.0,50.0);'claude-sonnet-5-5'=@(2.0,10.0)
  }
  foreach($model in $rates.Keys){
    foreach($effort in @('low','medium','high','xhigh','max')){
      [pscustomobject]@{model=$model;effort=$effort;usdPerTask=6.0;pricing=[pscustomobject]@{
        price_1m_input_tokens=$rates[$model][0];price_1m_output_tokens=$rates[$model][1]
      }}
    }
  }
}

function Set-ProductionShapedRoutingRegistry {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Path)
  $bytes=[IO.File]::ReadAllBytes($Path)
  $registry=([Text.Encoding]::UTF8.GetString($bytes)|ConvertFrom-Json -AsHashtable -DateKind String)
  foreach($familyName in @($registry.families.Keys)){
    $family=$registry.families[$familyName]
    if([string]$family.current -ceq 'gpt-5.6-terra'){$registry.families.Remove($familyName);continue}
    $family.historical=@($family.historical|Where-Object{[string]$_ -cne 'gpt-5.6-terra'})
  }
  $registry.models.Remove('gpt-5.6-terra')
  foreach($modelName in @($registry.models.Keys)){
    $model=$registry.models[$modelName]
    $model.admittedEfforts=@($model.admittedEfforts|Where-Object{[string]$_ -cne 'max'})
    if($model.usableAccountsByEffort -is [hashtable]){$model.usableAccountsByEffort.Remove('max')}
    foreach($account in @($model.accounts)){$account.efforts=@($account.efforts|Where-Object{[string]$_ -cne 'max'})}
  }
  [IO.File]::WriteAllText($Path,($registry|ConvertTo-Json -Depth 50),[Text.UTF8Encoding]::new($false))
  return [pscustomobject]@{path=$Path;bytes=$bytes}
}

function Restore-RoutingRegistryBytes {
  [CmdletBinding()]
  param([Parameter(Mandatory)]$Snapshot)
  [IO.File]::WriteAllBytes([string]$Snapshot.path,[byte[]]$Snapshot.bytes)
}

function Enter-RoutingDataTestScope {
  $root=Join-Path ([IO.Path]::GetTempPath()) ('routing-test-scope-'+[guid]::NewGuid().ToString('N'))
  $snapshot=Get-Content (Join-Path $PSScriptRoot 'controller-skills/model-routing/capability-matrix.json') -Raw|ConvertFrom-Json
  $fixture=New-RoutingMatrixFixture -Root $root -Snapshot $snapshot -BenchmarkRows @(New-RoutingCostBenchmarkRows)
  $scope=[pscustomobject]@{root=$root;previousRoot=$env:CHASE_SETS_ROUTING_DATA_ROOT;previousLkg=$env:CHASE_SETS_ROUTING_LKG_PATH}
  $env:CHASE_SETS_ROUTING_DATA_ROOT=$fixture.stateRoot;$env:CHASE_SETS_ROUTING_LKG_PATH=$fixture.lkgPath
  return $scope
}

function Exit-RoutingDataTestScope($Scope) {
  $env:CHASE_SETS_ROUTING_DATA_ROOT=$Scope.previousRoot;$env:CHASE_SETS_ROUTING_LKG_PATH=$Scope.previousLkg
  $resolved=[IO.Path]::GetFullPath($Scope.root)
  if((Split-Path -Parent $resolved).TrimEnd('\','/') -cne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/') -or
      (Split-Path -Leaf $resolved)-notlike'routing-test-scope-*'){throw 'unsafe routing test scope cleanup'}
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
