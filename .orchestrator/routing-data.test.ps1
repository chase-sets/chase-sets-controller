[CmdletBinding()]
param([string]$ResolverPath=(Join-Path $PSScriptRoot 'routing-data.ps1'),[string]$Case='all',[string]$EvidenceDir)
$ErrorActionPreference='Stop'
. $ResolverPath -Library
$cases=@('policy','current','admission','stale-registry','stale-status','future-registry','future-status',
  'missing-policy','missing-registry','unparseable-policy','unparseable-registry',
  'missing-latest','missing-snapshot','unparseable-latest','unparseable-snapshot',
  'explicit','evidence','cache','price','zero-accounts','account-authority','cache-publication','model-set')
$root=Join-Path ([IO.Path]::GetTempPath()) ('routing-data-test-'+[guid]::NewGuid().ToString('N'))
$now=[DateTimeOffset]'2026-09-30T12:00:00Z'
[IO.Directory]::CreateDirectory((Join-Path $root 'benchmarks'))|Out-Null
function Assert-True([bool]$Value,[string]$Message){if(-not $Value){throw "ASSERTION FAILED: $Message"}}
function Assert-Equal($Actual,$Expected,[string]$Message){Assert-True ([string]$Actual -ceq [string]$Expected) "$Message (actual=$Actual expected=$Expected)"}
function Assert-Refused([scriptblock]$Action,[string]$Reason){
  $caught=$null
  try{& $Action|Out-Null}catch{$caught=$_}
  Assert-True ($null-ne$caught-and$caught.Exception.Message.Contains($Reason)) "expected refusal $Reason; got $caught"
}
function Write-Fixture {
  [IO.File]::WriteAllText((Join-Path $root 'routing-policy.json'),($script:policy|ConvertTo-Json -Depth 40),[Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText((Join-Path $root 'model-registry.json'),($script:registry|ConvertTo-Json -Depth 40),[Text.UTF8Encoding]::new($false))
}
function New-Model([string]$Effort,[string]$Account){
  return [ordered]@{admittedEfforts=@($Effort);usableAccountsByEffort=[ordered]@{$Effort=@($Account)}
    accounts=@([ordered]@{account=$Account;efforts=@($Effort);stale=$false;usable=$true;disabled=$false;routing='ready'})}
}
function Reset-Fixture {
  $script:policy=[ordered]@{format='routing-policy/v1';generation=1;approvedBy='fixture';rows=[ordered]@{}}
  foreach($i in 1..15){$script:policy.rows["$i"]=[ordered]@{task="row $i";slots=[ordered]@{
    'codex.primary'=[ordered]@{family='alpha';effort='high';placement='provisional'}
    'claude.fallback'=[ordered]@{family='beta';effort='medium';placement='override-Todd'}}}}
  $script:registry=[ordered]@{format='model-registry/v2';generatedAt=$now.ToString('o');source=[ordered]@{statusCheckedAt=$now.ToString('o')}
    authorityDigest='fixture-digest-1';families=[ordered]@{
      alpha=[ordered]@{provider='codex';current='model-a';historical=@('model-a-old')}
      beta=[ordered]@{provider='claude';current='model-b';historical=@()}
      gamma=[ordered]@{provider='codex';current='model-c';historical=@()}}
    models=[ordered]@{'model-a'=(New-Model high account-a);'model-b'=(New-Model medium account-b)
      'model-c'=(New-Model medium account-c);'model-a-old'=(New-Model high account-old)}}
  Write-Fixture
  [IO.File]::WriteAllText((Join-Path $root 'benchmarks/latest.json'),'{"file":"aa-fixture.json"}')
  [IO.File]::WriteAllText((Join-Path $root 'benchmarks/aa-fixture.json'),'{"rows":[{"model":"model-a","effort":"high","usdPerTask":0.32,"pricing":{"price_1m_input_tokens":2,"price_1m_output_tokens":10}},{"model":"model-b","effort":"medium","usdPerTask":1.3}]}')
  $script:lkg=Join-Path $root 'lkg.json'
  if([IO.File]::Exists($lkg)){[IO.File]::Delete($lkg)}
}
function Resolve-Fixture {
  param([int]$Row=4,[string]$Model,[string]$Effort,[switch]$ReadOnly)
  Resolve-RoutingSelection -Row $Row -Harness codex -StateRoot $root -LkgPath $lkg -NowUtc $now -Model $Model -Effort $Effort -ReadOnly:$ReadOnly
}
function Invoke-Case([string]$Name){
  Reset-Fixture
  switch($Name){
    'policy' {
      $before=[IO.File]::ReadAllText($ResolverPath)
      Assert-Equal (Resolve-Fixture).model model-a 'initial policy'
      $script:policy.generation=2
      $script:policy.rows['4'].slots.'codex.primary'=[ordered]@{family='gamma';effort='medium';placement='measured'}
      Write-Fixture
      $r=Resolve-Fixture
      Assert-Equal $r.model model-c 'generation remaps family'
      Assert-Equal $r.effort medium 'generation remaps effort'
      Assert-Equal $r.placement measured 'generation remaps placement'
      Assert-Equal $r.policyGeneration 2 'new generation recorded'
      Assert-Equal ([IO.File]::ReadAllText($ResolverPath)) $before 'no script edit or reinstall'
    }
    'current' {
      $script:registry.families.alpha.current='model-a-next'
      $script:registry.families.alpha.historical+=@('model-a')
      $script:registry.models['model-a-next']=New-Model high account-next
      Write-Fixture
      foreach($row in @(4,7,8,11,12)){Assert-Equal (Resolve-Fixture -Row $row).model model-a-next "family swap affects row $row"}
    }
    'admission' {
      $script:registry.models.'model-a'.admittedEfforts=@();Write-Fixture
      $r=Resolve-Fixture
      Assert-Equal $r.model model-b 'unadmitted effort falls back'
      Assert-Equal $r.family beta 'fallback keyed by family'
      Assert-Equal $r.slot claude.fallback 'fallback slot'
      Assert-Equal $r.harness claude 'cross-harness fallback'
      $script:registry.models.'model-a'.admittedEfforts=@('high')
      $script:registry.models.'model-a'.usableAccountsByEffort.high=@();Write-Fixture
      Assert-Equal (Resolve-Fixture).model model-b 'no usable accounts falls back'
      $script:registry.models.'model-b'.usableAccountsByEffort.medium=@();Write-Fixture
      Assert-Refused {Resolve-Fixture} REGISTRY_NO_USABLE_ACCOUNTS
      $script:registry.models.'model-a'.admittedEfforts=@()
      $script:registry.models.'model-b'.admittedEfforts=@();Write-Fixture
      Assert-Refused {Resolve-Fixture} NO_QUALIFIED_FALLBACK
    }
    'explicit' {
      Assert-Refused {Resolve-Fixture -Model model-a-old -Effort high} EXPLICIT_HISTORICAL_OR_RETIRED_MODEL
      Assert-Refused {Resolve-Fixture -Model unknown-model -Effort high} EXPLICIT_MODEL_NOT_CURRENT
      Assert-Refused {Resolve-Fixture -Model model-b -Effort medium} MODEL_HARNESS_MISMATCH
      Assert-Refused {Resolve-Fixture -Model model-a -Effort low} EFFORT_NOT_ADMITTED
      Assert-Refused {Resolve-Fixture -Model model-a} ROUTING_EXPLICIT_INCOMPLETE
      Assert-Equal (Resolve-Fixture -Model model-a -Effort high).slot explicit 'explicit current id'
      $r=Resolve-Fixture -Row 0 -Model model-a -Effort high
      Assert-Equal $r.row 0 'explicit review/planning envelope keeps row zero'
      Assert-True ($null-eq$r.placement) 'explicit unqualified envelope never guesses placement'
      Assert-Refused {Resolve-Fixture -Row 0} ROUTING_ROW_REQUIRED
    }
    'evidence' {
      $r=Resolve-Fixture
      Assert-Equal $r.policyGeneration 1 'policy evidence'
      Assert-Equal $r.registryAuthorityDigest fixture-digest-1 'registry evidence'
      Assert-Equal $r.family alpha 'family evidence'
      Assert-Equal $r.slot codex.primary 'slot evidence'
      Assert-True (-not $r.usedLastKnownGood) 'fresh evidence not LKG'
    }
    'cache' {
      $null=Resolve-Fixture
      $script:registry.generatedAt=$now.AddHours(-4).ToString('o');Write-Fixture
      $cache=Read-RoutingJson $lkg
      $cache.payload.policy.generation=999
      [IO.File]::WriteAllText($lkg,($cache|ConvertTo-Json -Depth 40))
      Assert-Refused {Resolve-Fixture} NO_VALID_LKG
      Reset-Fixture
      $null=Resolve-Fixture
      $script:registry.generatedAt=$now.AddHours(-4).ToString('o');Write-Fixture
      $cache=Read-RoutingJson $lkg
      $cache.payload.validatedAt=$now.AddMinutes(4).ToString('o')
      $cache.payload.registry.generatedAt=$now.AddMinutes(8).ToString('o')
      $cache.payload.registry.source.statusCheckedAt=$now.AddMinutes(8).ToString('o')
      $cache.sha256=Get-RoutingPayloadDigest $cache.payload
      [IO.File]::WriteAllText($lkg,($cache|ConvertTo-Json -Depth 40))
      Assert-Refused {Resolve-Fixture} NO_VALID_LKG
      Reset-Fixture
      $null=Resolve-Fixture -ReadOnly
      Assert-True (-not [IO.File]::Exists($lkg)) 'read-only resolution never writes cache'
      $oldRoot=$env:CHASE_SETS_ROUTING_DATA_ROOT;$oldLkg=$env:CHASE_SETS_ROUTING_LKG_PATH
      try{
        $env:CHASE_SETS_ROUTING_DATA_ROOT=Join-Path $root 'missing-env-root'
        $env:CHASE_SETS_ROUTING_LKG_PATH=Join-Path $root 'missing-env-cache.json'
        . $ResolverPath -Library -StateRoot $root -LkgPath $lkg
        $configured=$null
        try{$configured=Get-RoutingData -NowUtc $now}catch{}
        Assert-True ($null-ne$configured) 'library root overrides missing fixture environment root'
        Assert-Equal $configured.stateRoot $root 'dot-sourced input root remains configured'
        Assert-Equal $configured.lkgPath $lkg 'dot-sourced cache path remains configured'
      }finally{
        $env:CHASE_SETS_ROUTING_DATA_ROOT=$oldRoot;$env:CHASE_SETS_ROUTING_LKG_PATH=$oldLkg
      }
    }
    'account-authority' {
      $script:registry.models.'model-a'.accounts[0].stale=$true
      Write-Fixture
      Assert-Refused {Resolve-Fixture} ROUTING_DATA_INVALID_ACCOUNT_AUTHORITY
    }
    'price' {
      Assert-Equal (Resolve-Fixture).expectedUsdPerTask 0.32 'benchmark exact configuration price'
      [IO.File]::WriteAllText((Join-Path $root 'benchmarks/aa-fixture.json'),'{"rows":[{"model":"model-a","effort":"high","usdPerTask":4.5}]}')
      Assert-Equal (Resolve-Fixture).expectedUsdPerTask 4.5 'benchmark refresh needs no reinstall'
    }
    'model-set' {
      $data=Get-RoutingData -StateRoot $root -LkgPath $lkg -NowUtc $now -ReadOnly
      Assert-Equal ((Get-RoutingModelSet $data.registry -Scope current)-join ',') 'model-a,model-b,model-c' 'current-only allowlist'
      Assert-Equal ((Get-RoutingModelSet $data.registry -Scope historical)-join ',') 'model-a-old' 'historical-only allowlist'
      Assert-Equal ((Get-RoutingModelSet $data.registry)-join ',') 'model-a,model-a-old,model-b,model-c' 'complete evidence allowlist'
      Assert-Equal ((Get-RoutingModelSet $data.registry -Scope current -Harness codex)-join ',') 'model-a,model-c' 'Codex current allowlist'
      Assert-Equal ((Get-RoutingModelSet $data.registry -Harness claude)-join ',') 'model-b' 'Claude evidence allowlist'
    }
    'zero-accounts' {
      $null=Resolve-Fixture
      foreach($model in $script:registry.models.Values){
        foreach($key in @($model.usableAccountsByEffort.Keys)){$model.usableAccountsByEffort[$key]=@()}
        foreach($account in $model.accounts){$account.stale=$true;$account.usable=$false}
      }
      Write-Fixture
      Assert-Refused {Resolve-Fixture} REGISTRY_NO_USABLE_ACCOUNTS
      $script:registry.generatedAt=$now.AddHours(-4).ToString('o');Write-Fixture
      Assert-Refused {Resolve-Fixture} REGISTRY_NO_USABLE_ACCOUNTS
      Assert-True (Get-RoutingData -StateRoot $root -LkgPath $lkg -NowUtc $now).usedLastKnownGood 'LKG does not revive older accounts'
    }
    'cache-publication' {
      $null=Resolve-Fixture
      $cached=[IO.File]::ReadAllText($lkg)
      foreach($model in $script:registry.models.Values){
        foreach($key in @($model.usableAccountsByEffort.Keys)){$model.usableAccountsByEffort[$key]=@()}
      }
      Write-Fixture
      $held=[IO.File]::Open($lkg,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
      try{
        Assert-Refused {Resolve-Fixture} ROUTING_LKG_WRITE_FAILED
        Assert-Equal ([IO.File]::ReadAllText($lkg)) $cached 'failed publication preserves the old cache bytes'
        Assert-Refused {Resolve-Fixture -ReadOnly} REGISTRY_NO_USABLE_ACCOUNTS
      }finally{$held.Dispose()}
      Assert-Refused {Resolve-Fixture} REGISTRY_NO_USABLE_ACCOUNTS
      Assert-True ([IO.File]::ReadAllText($lkg)-cne$cached) 'successful fresh publication replaces older account authority'
    }
    default {
      $null=Resolve-Fixture
      $reason=''
      switch($Name){
        'stale-registry' {$script:registry.generatedAt=$now.AddHours(-4).ToString('o');$reason='REGISTRY_STALE_GENERATED_AT'}
        'stale-status' {$script:registry.source.statusCheckedAt=$now.AddHours(-4).ToString('o');$reason='REGISTRY_STALE_STATUS'}
        'future-registry' {$script:registry.generatedAt=$now.AddMinutes(6).ToString('o');$reason='REGISTRY_TIMESTAMP_FUTURE'}
        'future-status' {$script:registry.source.statusCheckedAt=$now.AddMinutes(6).ToString('o');$reason='REGISTRY_TIMESTAMP_FUTURE'}
        'missing-policy' {$reason='ROUTING_DATA_MISSING'}
        'missing-registry' {$reason='ROUTING_DATA_MISSING'}
        'unparseable-policy' {$reason='ROUTING_DATA_UNPARSEABLE'}
        'unparseable-registry' {$reason='ROUTING_DATA_UNPARSEABLE'}
        'missing-latest' {$reason='ROUTING_DATA_MISSING'}
        'missing-snapshot' {$reason='ROUTING_DATA_MISSING'}
        'unparseable-latest' {$reason='ROUTING_DATA_UNPARSEABLE'}
        'unparseable-snapshot' {$reason='ROUTING_DATA_UNPARSEABLE'}
        default {throw "unknown case $Name"}
      }
      Write-Fixture
      $invalidPath=switch(($Name -split '-')[1]){
        'policy' {Join-Path $root 'routing-policy.json'}
        'registry' {Join-Path $root 'model-registry.json'}
        'latest' {Join-Path $root 'benchmarks/latest.json'}
        'snapshot' {Join-Path $root 'benchmarks/aa-fixture.json'}
      }
      if($Name-like'missing-*'){[IO.File]::Delete($invalidPath)}
      if($Name-like'unparseable-*'){[IO.File]::WriteAllText($invalidPath,'{')}
      $cacheBefore=[IO.File]::ReadAllText($lkg)
      $r=Resolve-Fixture
      Assert-True $r.usedLastKnownGood "$Name flagged LKG"
      Assert-Equal $r.sourceReason $reason "$Name source reason"
      Assert-Equal $r.model model-a "$Name LKG selection"
      Assert-Equal $r.policyGeneration 1 "$Name cached generation"
      Assert-Equal $r.registryAuthorityDigest fixture-digest-1 "$Name cached digest"
      Assert-Equal ([IO.File]::ReadAllText($lkg)) $cacheBefore "$Name cannot rewrite LKG"
      [IO.File]::Delete($lkg)
      Assert-Refused {Resolve-Fixture} NO_VALID_LKG
    }
  }
  Write-Output "PASS routing-data case=$Name"
}
try{
  if($Case-ne'all'){Invoke-Case $Case;return}
  foreach($name in $cases){Invoke-Case $name}
  $source=[IO.File]::ReadAllText($ResolverPath)
  $mutants=@(
    @{name='freeze-policy';case='policy';needle='$Model=$candidateModel;$Effort=[string]$candidate.Value.effort';replacement='$Model="model-a";$Effort=[string]$candidate.Value.effort'},
    @{name='freeze-policy-effort';case='policy';needle='$Effort=[string]$candidate.Value.effort';replacement='$Effort="high"'},
    @{name='freeze-policy-placement';case='policy';needle='$placement=[string]$candidate.Value.placement';replacement='$placement="provisional"'},
    @{name='freeze-current';case='current';needle='$Model=$candidateModel;$Effort=[string]$candidate.Value.effort';replacement='$Model="model-a";$Effort=[string]$candidate.Value.effort'},
    @{name='ignore-effort';case='admission';needle='if ($entry.Value.admittedEfforts -cnotcontains $Effort)';replacement='if ($false)'},
    @{name='ignore-accounts';case='admission';needle='if ($null -eq $accounts -or @($accounts.Value).Count -eq 0)';replacement='if ($false)'},
    @{name='ignore-stale-registry';case='stale-registry';needle='if (($NowUtc - $generated).TotalHours -gt 3)';replacement='if ($false)'},
    @{name='ignore-stale-status';case='stale-status';needle='if (($NowUtc - $checked).TotalHours -gt 3)';replacement='if ($false)'},
    @{name='ignore-future-registry';case='future-registry';needle='if ($generated -gt $NowUtc.AddMinutes(5) -or $checked -gt $NowUtc.AddMinutes(5))';replacement='if ($false)'},
    @{name='ignore-future-status';case='future-status';needle='if ($generated -gt $NowUtc.AddMinutes(5) -or $checked -gt $NowUtc.AddMinutes(5))';replacement='if ($false)'},
    @{name='missing-policy-unflagged';case='missing-policy';needle='$usedLkg = $true';replacement='$usedLkg = $false'},
    @{name='missing-registry-unflagged';case='missing-registry';needle='$usedLkg = $true';replacement='$usedLkg = $false'},
    @{name='invalid-policy-unflagged';case='unparseable-policy';needle='$usedLkg = $true';replacement='$usedLkg = $false'},
    @{name='invalid-registry-unflagged';case='unparseable-registry';needle='$usedLkg = $true';replacement='$usedLkg = $false'},
    @{name='missing-latest-unflagged';case='missing-latest';needle='$usedLkg = $true';replacement='$usedLkg = $false'},
    @{name='missing-snapshot-unflagged';case='missing-snapshot';needle='$usedLkg = $true';replacement='$usedLkg = $false'},
    @{name='invalid-latest-unflagged';case='unparseable-latest';needle='$usedLkg = $true';replacement='$usedLkg = $false'},
    @{name='invalid-snapshot-unflagged';case='unparseable-snapshot';needle='$usedLkg = $true';replacement='$usedLkg = $false'},
    @{name='admit-history';case='explicit';needle='if (-not $identity.current)';replacement='if ($false)'},
    @{name='drop-generation';case='evidence';needle='policyGeneration=$data.policyGeneration;registryAuthorityDigest=$data.registryAuthorityDigest';replacement='policyGeneration=0;registryAuthorityDigest=$data.registryAuthorityDigest'},
    @{name='drop-digest';case='evidence';needle='policyGeneration=$data.policyGeneration;registryAuthorityDigest=$data.registryAuthorityDigest';replacement='policyGeneration=$data.policyGeneration;registryAuthorityDigest="missing"'},
    @{name='ignore-cache-hash';case='cache';needle='$cache.sha256 -cne (Get-RoutingPayloadDigest $payload)';replacement='$false'},
    @{name='ignore-cache-clock';case='cache';needle="if (`$currentClockReason -cin @('REGISTRY_TIMESTAMP_FUTURE','REGISTRY_TIMESTAMP_INVALID'))";replacement='if ($false)'},
    @{name='ignore-library-root';case='cache';needle='$script:RoutingConfiguredStateRoot = $StateRoot';replacement='$script:RoutingConfiguredStateRoot = ""'},
    @{name='ignore-account-stale';case='account-authority';needle='-or $accounts[0].stale -or';replacement='-or $false -or'},
    @{name='freeze-price';case='price';needle='expectedUsdPerTask=$(if ($price) { $price.usdPerTask } else { $null })';replacement='expectedUsdPerTask=0.32'},
    @{name='ignore-cache-publication';case='cache-publication';needle="catch { throw 'ROUTING_LKG_WRITE_FAILED' }";replacement='catch {}'},
    @{name='cache-only-usable';case='zero-accounts';needle='if (-not $ReadOnly -and -not $usedLkg) {';replacement='if (-not $ReadOnly -and -not $usedLkg -and (Get-RoutingAdmissionReason $registry "model-a" "high") -ne "REGISTRY_NO_USABLE_ACCOUNTS") {'},
    @{name='history-in-current-set';case='model-set';needle="if (`$Scope -cne 'current')";replacement='if ($true)'},
    @{name='history-missing-from-all';case='model-set';needle="if (`$Scope -cne 'current')";replacement="if (`$Scope -ceq 'historical')"},
    @{name='ignore-model-set-harness';case='model-set';needle='if ($Harness -and $family.Value.provider -cne $Harness)';replacement='if ($false)'}
  )
  foreach($mutant in $mutants){
    Assert-True ($source.Contains($mutant.needle)) "mutant needle found: $($mutant.name)"
    $path=Join-Path $root "$($mutant.name).ps1"
    [IO.File]::WriteAllText($path,$source.Replace($mutant.needle,$mutant.replacement),[Text.UTF8Encoding]::new($false))
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=(Get-Process -Id $PID).Path;$start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    foreach($arg in @('-NoProfile','-NonInteractive','-File',$PSCommandPath,'-ResolverPath',$path,'-Case',$mutant.case)){[void]$start.ArgumentList.Add($arg)}
    $process=[Diagnostics.Process]::Start($start)
    try{
      $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
      if(-not $process.WaitForExit(20000)){$process.Kill($true);$process.WaitForExit();throw "mutant timeout: $($mutant.name)"}
      $outText=$stdout.GetAwaiter().GetResult();$errText=$stderr.GetAwaiter().GetResult()
      $output=$outText+$errText
      if($EvidenceDir){
        [IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($EvidenceDir))|Out-Null
        $retainedResolver=[IO.Path]::GetFullPath((Join-Path $EvidenceDir ($mutant.name+'.resolver.ps1')))
        [IO.File]::WriteAllText($retainedResolver,[IO.File]::ReadAllText($path))
        [IO.File]::WriteAllText((Join-Path $EvidenceDir ($mutant.name+'.stdout.log')),$outText)
        [IO.File]::WriteAllText((Join-Path $EvidenceDir ($mutant.name+'.stderr.log')),$errText)
        [pscustomobject]@{name=$mutant.name;case=$mutant.case;exitCode=$process.ExitCode
          resolverEvidence=$retainedResolver
          command=('pwsh -NoProfile -NonInteractive -File '+$PSCommandPath+' -ResolverPath '+$path+' -Case '+$mutant.case)
          replayCommand=('pwsh -NoProfile -NonInteractive -File '+$PSCommandPath+' -ResolverPath '+$retainedResolver+' -Case '+$mutant.case)}|
          ConvertTo-Json -Compress|Add-Content -LiteralPath (Join-Path $EvidenceDir 'results.jsonl')
      }
      Assert-True ($process.ExitCode-ne0-and$output.Contains('ASSERTION FAILED')) "mutant must fail assertion: $($mutant.name), exit=$($process.ExitCode), output=$output"
      Write-Output "PASS mutant-red name=$($mutant.name) case=$($mutant.case) exit=$($process.ExitCode)"
    }finally{$process.Dispose()}
  }
  Write-Output "PASS routing-data cases=$($cases.Count) discriminating-mutants=$($mutants.Count)"
}finally{
  $resolved=[IO.Path]::GetFullPath($root)
  $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
  if(-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)-or(Split-Path -Leaf $resolved)-notlike'routing-data-test-*'){throw 'unsafe fixture cleanup'}
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
