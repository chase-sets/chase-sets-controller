[CmdletBinding()]
param([string]$LauncherPath=(Join-Path $PSScriptRoot 'dispatch-lane.ps1'),
  [ValidateSet('all','policy','current','admission','explicit','lkg','evidence','ledger-readers')][string]$Case='all',
  [string]$EvidenceDir)
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
function Invoke-Case([string]$Name){
  Reset-Fixture
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
      Assert-True ($ledger.dispatchRoutingSchema-ceq'watchdog-dispatch-routing/v2'-and$ledger.policyGeneration-eq9-and
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
  $cases=@('policy','current','admission','explicit','lkg','evidence','ledger-readers')
  foreach($name in $cases){if($Case-ceq'all'-or$Case-ceq$name){Invoke-Case $name}}
  if($Case-ceq'all'){
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
} finally {
  $env:CHASE_SETS_ROUTING_DATA_ROOT=$oldRoot;$env:CHASE_SETS_ROUTING_LKG_PATH=$oldLkg
  $resolved=[IO.Path]::GetFullPath($root)
  if((Split-Path -Parent $resolved).TrimEnd('\','/') -cne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/') -or
      (Split-Path -Leaf $resolved)-notlike'dispatch-routing-data-*'){throw 'unsafe fixture cleanup'}
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
