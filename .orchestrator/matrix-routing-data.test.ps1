[CmdletBinding()]
param([string]$RefreshPath=(Join-Path $PSScriptRoot 'matrix-refresh.ps1'),
  [ValidateSet('all','dynamic','identities','evidence','fail-closed')][string]$Case='all',
  [string]$EvidenceDir)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'routing-data-test-support.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('matrix-routing-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$oldRoot=$env:CHASE_SETS_ROUTING_DATA_ROOT;$oldLkg=$env:CHASE_SETS_ROUTING_LKG_PATH
function Assert-True([bool]$Value,[string]$Message) { if(-not $Value){throw "ASSERTION FAILED: $Message"} }
function Write-Json([string]$Path,$Value) { [IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 60),[Text.UTF8Encoding]::new($false)) }
function Reset-Fixture {
  $script:fixture=New-RoutingDataFixture -Root (Join-Path $root 'state') -Families @(
    [pscustomobject]@{name='alpha';provider='codex';current='gpt-99-alpha';historical=@('gpt-98-alpha')})
  $env:CHASE_SETS_ROUTING_DATA_ROOT=$fixture.stateRoot;$env:CHASE_SETS_ROUTING_LKG_PATH=$fixture.lkgPath
  if([IO.File]::Exists($fixture.lkgPath)){[IO.File]::Delete($fixture.lkgPath)}
  $script:matrixPath=Join-Path $root 'matrix.json';$script:ledgerPath=Join-Path $root 'ledger.jsonl';$script:dispatchPath=Join-Path $root 'dispatch.jsonl'
  Write-Json $matrixPath ([ordered]@{configs=@(
    [ordered]@{id='gpt-99-alpha/high';model='gpt-99-alpha';effort='high';harness='codex'},
    [ordered]@{id='gpt-98-alpha/high';model='gpt-98-alpha';effort='high';harness='codex';historicalOnly=$true;selectable=$false})})
  $now=[DateTimeOffset]::UtcNow.ToString('o')
  [IO.File]::WriteAllLines($ledgerPath,@(
    ([ordered]@{ts=$now;transcript='1-gpt-99-alpha--high-task.jsonl';model='gpt-99-alpha';usd=2}|ConvertTo-Json -Compress),
    ([ordered]@{ts=$now;transcript='2-gpt-98-alpha--high-task.jsonl';model='gpt-98-alpha';usd=7}|ConvertTo-Json -Compress)))
  [IO.File]::WriteAllText($dispatchPath,'')
}
function Refresh {
  try { $script:lastRefreshOutput=& $RefreshPath -Matrix $matrixPath -CostLedger $ledgerPath -DispatchLog $dispatchPath -Json | ConvertFrom-Json }
  catch { throw "ASSERTION FAILED: fixture refresh unexpectedly refused: $($_.Exception.Message)" }
  return Get-Content -LiteralPath $matrixPath | ConvertFrom-Json -DateKind String
}
function Expect-Refusal([string]$Reason) {
  $before=(Get-FileHash -LiteralPath $matrixPath).Hash;$message=$null
  try { & $RefreshPath -Matrix $matrixPath -CostLedger $ledgerPath -DispatchLog $dispatchPath -Json | Out-Null }
  catch { $message=$_.Exception.Message }
  Assert-True ($message -and $message.Contains($Reason)) "expected $Reason refusal; actual=$message"
  Assert-True ((Get-FileHash -LiteralPath $matrixPath).Hash -ceq $before) 'refusal must leave matrix byte-identical'
}
function Invoke-Case([string]$Name) {
  Reset-Fixture
  switch($Name){
    dynamic {
      $m=Refresh
      Assert-True ($m.configs[0].measured.n -eq 1 -and $m.configs[1].measured.usdPerRun -eq 7) 'initial current and historical filename evidence'
      $registry=Get-Content (Join-Path $fixture.stateRoot 'model-registry.json') | ConvertFrom-Json -AsHashtable -DateKind String
      $registry.families.alpha.current='gpt-100-alpha';$registry.families.alpha.historical+=@('gpt-99-alpha')
      $registry.models['gpt-100-alpha']=$registry.models['gpt-99-alpha']
      Write-Json (Join-Path $fixture.stateRoot 'model-registry.json') $registry
      Write-Json $matrixPath $m
      Add-Content -LiteralPath $ledgerPath -Value ([ordered]@{ts=[DateTimeOffset]::UtcNow.ToString('o');transcript='3-gpt-100-alpha--high-new.jsonl';model='gpt-100-alpha';usd=11}|ConvertTo-Json -Compress)
      $m=Refresh
      $successor=@($m.configs | Where-Object id -ceq 'gpt-100-alpha/high')
      Assert-True ($successor.Count -eq 1 -and $successor[0].measured.n -eq 1 -and $successor[0].measured.usdPerRun -eq 11) 'new registry current selector resolves filename without reinstall'
      Assert-True ($m.configs[0].measured.usdPerRun -eq 2 -and $m.configs[1].measured.usdPerRun -eq 7) 'successor never inherits historical measurements'
    }
    identities {
      $m=Refresh
      $m.configs[1].historicalOnly=$true;$m.configs[1].selectable=$true
      Write-Json $matrixPath $m
      Expect-Refusal historical-only
      Reset-Fixture
      $m=Get-Content $matrixPath|ConvertFrom-Json
      $m.configs += [pscustomobject]@{id='gpt-101-unlisted/high';model='gpt-101-unlisted';effort='high';harness='codex'}
      Write-Json $matrixPath $m
      Expect-Refusal 'must be exactly'
    }
    evidence {
      $policy=Get-Content (Join-Path $fixture.stateRoot 'routing-policy.json') | ConvertFrom-Json -AsHashtable
      $policy.generation=19;Write-Json (Join-Path $fixture.stateRoot 'routing-policy.json') $policy
      $m=Refresh
      Assert-True ($m.measuredAt.policyGeneration -eq 19) 'generation comes from policy data'
      Assert-True ($script:lastRefreshOutput.policyGeneration -eq 19 -and -not $script:lastRefreshOutput.usedLastKnownGood) 'fresh output carries policy generation and source flag'
      Assert-True ($m.measuredAt.registryAuthorityDigest -ceq 'synthetic-consumer-authority') 'registry digest recorded'
      Assert-True (-not $m.measuredAt.usedLastKnownGood) 'fresh evidence is not LKG'
      $registry=Get-Content (Join-Path $fixture.stateRoot 'model-registry.json') | ConvertFrom-Json -AsHashtable -DateKind String
      $registry.generatedAt=[DateTimeOffset]::UtcNow.AddHours(-4).ToString('o')
      Write-Json (Join-Path $fixture.stateRoot 'model-registry.json') $registry
      $m=Refresh
      Assert-True ($m.measuredAt.usedLastKnownGood -and $m.measuredAt.routingSourceReason -ceq 'REGISTRY_STALE_GENERATED_AT') 'stale read carries flagged LKG and named source reason'
      Assert-True ($script:lastRefreshOutput.usedLastKnownGood -and $script:lastRefreshOutput.routingSourceReason -ceq 'REGISTRY_STALE_GENERATED_AT') 'LKG flag is present in output, not only the matrix'
    }
    fail-closed {
      [IO.File]::Delete((Join-Path $fixture.stateRoot 'model-registry.json'))
      Expect-Refusal 'ROUTING_DATA_REFUSED:ROUTING_DATA_MISSING:NO_VALID_LKG'
    }
  }
  Write-Output "PASS matrix-routing-data case=$Name"
}
try {
  if($Case -ne 'all'){Invoke-Case $Case;return}
  foreach($name in @('dynamic','identities','evidence','fail-closed')){Invoke-Case $name}
  $source=[IO.File]::ReadAllText($RefreshPath)
  $mutants=@(
    @{name='freeze-registry-set';case='dynamic';find='$registryModelSet = @(Get-RoutingModelSet $routingData.registry)';replace='$registryModelSet = @("gpt-99-alpha","gpt-98-alpha")'},
    @{name='freeze-filename-set';case='dynamic';find='$exactSelectors = @($registryModelSet | ForEach-Object { [regex]::Escape($_) }) -join ''|''';replace='$exactSelectors = ''gpt-99-alpha|gpt-98-alpha'''},
    @{name='admit-unlisted';case='identities';find='$registryModelSet -ccontains $canon';replace='$true'},
    @{name='admit-history';case='identities';find='$existing.PSObject.Properties[''selectable''] -and $existing.selectable -eq $true';replace='$false'},
    @{name='drop-generation';case='evidence';find='policyGeneration = $routingData.policyGeneration';replace='policyGeneration = 1'},
    @{name='drop-digest';case='evidence';find='registryAuthorityDigest = $routingData.registryAuthorityDigest';replace='registryAuthorityDigest = "wrong-digest"'},
    @{name='drop-lkg';case='evidence';find='usedLastKnownGood = $routingData.usedLastKnownGood';replace='usedLastKnownGood = $false'},
    @{name='ignore-missing';case='fail-closed';find='$routingData = Get-RoutingData -ReadOnly:$DryRun';replace='try { $routingData = Get-RoutingData -ReadOnly:$DryRun } catch { $routingData = [pscustomobject]@{registry=[pscustomobject]@{families=[pscustomobject]@{}}} }'}
  )
  if(-not $EvidenceDir){$EvidenceDir=Join-Path $root 'mutants'}
  [void][IO.Directory]::CreateDirectory($EvidenceDir)
  foreach($mutant in $mutants){
    Assert-True ($source.Contains($mutant.find)) "mutation seam $($mutant.name)"
    $runtime=Join-Path $EvidenceDir $mutant.name;[void][IO.Directory]::CreateDirectory($runtime)
    foreach($dependency in @('routing-data.ps1','controller-install-lock.psm1','review-head-contract.psm1')){
      Copy-Item -LiteralPath (Join-Path $PSScriptRoot $dependency) -Destination (Join-Path $runtime $dependency)
    }
    $mutatedPath=Join-Path $runtime 'matrix-refresh.ps1'
    [IO.File]::WriteAllText($mutatedPath,$source.Replace($mutant.find,$mutant.replace),[Text.UTF8Encoding]::new($false))
    $log=Join-Path $runtime 'child.log'
    & pwsh -NoProfile -NonInteractive -File $PSCommandPath -RefreshPath $mutatedPath -Case $mutant.case *> $log
    $exitCode=$LASTEXITCODE
    Assert-True ($exitCode -eq 1 -and [IO.File]::ReadAllText($log).Contains('ASSERTION FAILED')) "discriminating mutant $($mutant.name) exit=$exitCode"
    $receipt=[ordered]@{name=$mutant.name;case=$mutant.case;exitCode=$exitCode;source=$mutatedPath;log=$log;command="pwsh -NoProfile -NonInteractive -File $PSCommandPath -RefreshPath $mutatedPath -Case $($mutant.case)"}
    Add-Content -LiteralPath (Join-Path $EvidenceDir 'results.jsonl') -Value ($receipt|ConvertTo-Json -Compress)
    Write-Output "PASS mutant-red name=$($mutant.name) exit=$exitCode"
  }
  Write-Output 'PASS matrix-routing-data cases=4 discriminating-mutants=8'
} finally {
  $env:CHASE_SETS_ROUTING_DATA_ROOT=$oldRoot;$env:CHASE_SETS_ROUTING_LKG_PATH=$oldLkg
  $resolvedRoot=[IO.Path]::GetFullPath($root)
  $tempPrefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
  if(-not $resolvedRoot.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'unsafe matrix routing cleanup root'}
  Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
}
