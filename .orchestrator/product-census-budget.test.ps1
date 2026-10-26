param([switch]$Baseline,[ValidateSet('','seam')][string]$Control='')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'dispatch-ownership.ps1')
. (Join-Path $PSScriptRoot 'product-census-integration-test-support.ps1')

# All Git repositories, records and process identities are local synthetic
# fixtures. Only copied budget reads are metered; native proof and authorizers run.
$probe = {
  param($Fixture, $Obligation, $OwnerPath, $Site, $Mode, $Unscoped)
  $script:budgetStats = @{ evaluations=[Collections.Generic.List[object]]::new();
    outcomes=[Collections.Generic.List[string]]::new(); gitMs=0L; calls=0; spawns=0; records=0 }
  $script:nativeBudgetGit = ${function:Invoke-ProductCensusGit}
  $script:nativeBudgetRecord = ${function:Get-ValidatedDispatchOwnershipRecord}
  $script:budgetMode = $Mode
  $script:budgetFixture = $Fixture
  $script:budgetOwnerPath = $OwnerPath
  $script:delayedAnchor = $false
  function script:Get-ValidatedDispatchOwnershipRecord {
    param($RecordPath,$RuntimeRoot,$TempRoot,$DateKindSupported)
    $script:budgetStats.records++
    & $script:nativeBudgetRecord @PSBoundParameters
  }
  function script:Invoke-ProductCensusGit {
    param($Checkout,$Arguments,$Budget)
    $s = $script:budgetStats
    $entry = @($s.evaluations | Where-Object generation -EQ $Budget.watch.restarts)
    if ($entry.Count -eq 0) {
      $entry = @{generation=$Budget.watch.restarts; cap=$Budget.deadline; calls=0; gitMs=0L; charges=0L; reads=[Collections.Generic.List[string]]::new()}
      $s.evaluations.Add($entry)
    } else { $entry = $entry[0] }
    $entry.calls++; $s.calls++
    $Budget.watch.Charge(1); $entry.charges++
    $entry.reads.Add("$Checkout|$($Arguments -join ' ')")
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
      if (($script:budgetMode -eq 'loaded' -and $s.calls -eq 1) -or
          ($script:budgetMode -eq 'persistent' -and $entry.calls -eq 1)) {
        # Exceed the unchanged old deadline once (or once per evaluation).
        $Budget.watch.Charge(5001); $entry.charges+=5001
      }
      if ($script:budgetMode -in @('poisoned-anchor','changed-identity') -and -not $script:delayedAnchor -and
          $Checkout -ceq $script:budgetFixture.anchor -and $Arguments[0] -ceq 'config') {
        $script:delayedAnchor = $true
        if ($script:budgetMode -eq 'changed-identity') {
          $changed=Get-Content -LiteralPath $script:budgetOwnerPath -Raw | ConvertFrom-Json -DateKind String
          $changed.worktree=$script:budgetFixture.seat; $changed.lane='platform-seat'
          Write-DispatchOwnershipRecord $script:budgetOwnerPath $changed
        }
        $Budget.watch.Charge(5001); $entry.charges+=5001
      }
      if ($script:budgetMode -eq 'unknown') { throw 'synthetic-secret-unknown' }
      & $script:nativeBudgetGit $Checkout $Arguments $Budget
    } finally {
      $entry.gitMs += $timer.ElapsedMilliseconds
      $s.gitMs += $timer.ElapsedMilliseconds
    }
  }
  $timer = [Diagnostics.Stopwatch]::StartNew()
  $value = $null; $failure = $null
  try {
    if ($Site -eq 'ownership') {
      $value = Get-LiveDispatchOwnership $Fixture.runtime $Fixture.temp $Fixture.container -ProductCensus:(-not $Unscoped)
    } elseif ($Site -eq 'publication') {
      $value = New-RebaseStart $Obligation $Fixture.runtime $OwnerPath -Prelaunch
    } else {
      $value = Get-RebaseAuthenticatedOwner $Obligation $Fixture.runtime $OwnerPath Prelaunch -ProductCensus:(-not $Unscoped)
    }
  } catch { $failure = $_.Exception.Message }
  [pscustomobject]@{value=$value;failure=$failure;stats=$script:budgetStats;elapsedMs=$timer.ElapsedMilliseconds}
}

function Invoke-BudgetProbe($Fixture,$Obligation,$OwnerPath,[string]$Source,[string]$Site,[string]$Mode,[switch]$Unscoped) {
  $module = Import-Module (Join-Path $Source 'landed-integration-evidence.psm1') -Force -PassThru -DisableNameChecking
  try { & $module $probe $Fixture $Obligation $OwnerPath $Site $Mode $Unscoped.IsPresent }
  finally { Remove-Module $module }
}
function Write-BudgetMeasurement($Result,[string]$Site,[string]$Mode) {
  $s=$Result.stats
  Write-Output ("MEASURED " + (@{site=$Site;mode=$Mode;gitSegmentMs=$s.gitMs;wholeCallMs=$Result.elapsedMs;
    evaluations=$s.evaluations.Count;gitCalls=$s.calls;gitSpawns=$s.spawns;recordReads=$s.records;records=2;seats=2;
    signal='exact git-deadline only';evaluationCaps=@($s.evaluations | ForEach-Object cap);
    evaluationGitMs=@($s.evaluations | ForEach-Object gitMs);evaluationCharges=@($s.evaluations | ForEach-Object charges);
    generations=@($s.evaluations | ForEach-Object generation);refusedOutcomes=@($s.outcomes)} | ConvertTo-Json -Compress))
}
function Assert-BudgetResult($Result,[string]$Site,[string]$Mode,[int]$Evaluations) {
  Assert-CensusFixture ($Result.stats.evaluations.Count -eq $Evaluations) "$Site/$Mode allowance evaluations=$Evaluations"
  Assert-CensusFixture (@($Result.stats.evaluations | Where-Object cap -NE 5000).Count -eq 0) "$Site/$Mode finite per-evaluation cap"
  for($i=0;$i-lt$Result.stats.evaluations.Count;$i++){
    $entry=$Result.stats.evaluations[$i]
    $crossing=($Mode-ceq'persistent')-or($i-eq0-and$Mode-in@('loaded','poisoned-anchor','changed-identity'))
    $expected=$entry.calls+$(if($crossing){5001}else{0})
    Assert-CensusFixture ($entry.charges-eq$expected-and$entry.generation-eq($i+1)) "$Site/$Mode exact charges and restart generation"
  }
  if ($Mode -in @('loaded','poisoned-anchor','persistent')) {
    $expectedRefusals=if ($Mode -eq 'persistent') {2} else {1}
    Assert-CensusFixture ($Result.stats.outcomes.Count -eq $expectedRefusals -and
      @($Result.stats.outcomes | Where-Object { $_ -cne 'git-deadline' }).Count -eq 0) "$Site/$Mode only deadline acquired allowance"
  }
  if ($Mode -in @('quiet','loaded','poisoned-anchor')) {
    if ($Site -eq 'ownership') {
      Assert-CensusFixture ($Result.value.health.status -ceq 'ok' -and $Result.value.activeLanes.Count -eq 1) "$Site/$Mode admitted"
    } else { Assert-CensusFixture ($null -eq $Result.failure -and $null -ne $Result.value) "$Site/$Mode admitted: $($Result.failure)" }
  } elseif ($Mode -eq 'persistent') {
    if ($Site -eq 'ownership') {
      Assert-CensusFixture ($Result.value.health.status -ceq 'partial' -and
        @($Result.value.health.diagnostics | Where-Object code -CEQ 'product-census-git-deadline').Count -eq 1) "$Site/$Mode named deadline"
      Assert-CensusFixture ((Get-DispatchBlockingDiagnostics $Result.value) -match 'product-census-git-deadline:') "$Site/$Mode integration refusal formatter"
    } else { Assert-CensusFixture ($Result.failure -ceq 'OWED_REBASE_PRODUCT_CENSUS_GIT_DEADLINE') "$Site/$Mode named deadline: $($Result.failure)" }
  } else {
    if ($Site -eq 'ownership') { Assert-CensusFixture ($Result.value.health.status -ceq 'partial') "$Site/$Mode refused" }
    else { Assert-CensusFixture ($Result.failure -like 'OWED_REBASE_OWNER_UNAUTHORIZED*') "$Site/$Mode unauthorized: $($Result.failure)" }
  }
  $output = @{failure=$Result.failure;diagnostics=$Result.value.health.diagnostics} | ConvertTo-Json -Depth 8 -Compress
  Assert-CensusFixture ($output -notmatch 'synthetic-secret|https:|github') "$Site/$Mode secret-free"
}

function ConvertTo-HistoricalBudgetSubject([string]$Source,[ValidateSet('ownership','authentication')][string]$Site) {
  $clock='[Diagnostics.Stopwatch]::StartNew()'
  $wait='$process.WaitForExit([int]$remaining)'
  $replacement='$($deterministicBudgetMeter.Restart(); $deterministicBudgetMeter)'
  $meteredWait='$deterministicBudgetMeter.WaitForProcess($process,@($outRead,$errRead),@($stdout.Length,$stderr.Length))'
  $waits=if($Site -ceq 'ownership'){1}else{0}
  Assert-CensusFixture ([regex]::Matches($Source,[regex]::Escape($clock)).Count -eq 1 -and
    [regex]::Matches($Source,[regex]::Escape('[Diagnostics.Stopwatch]::new()')).Count -eq 0 -and
    [regex]::Matches($Source,[regex]::Escape($wait)).Count -eq $waits) "historical $Site clock/wait anchors"
  $converted=$Source.Replace($clock,$replacement).Replace($wait,$meteredWait)
  Assert-CensusFixture ($converted.Replace($replacement,$clock).Replace($meteredWait,$wait) -ceq $Source) "historical $Site inverse diff"
  return $converted
}

function Test-BudgetSeam {
  $ownership=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'dispatch-ownership.ps1'))
  $auth=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'landed-integration-evidence.psm1'))
  $converted=ConvertTo-DeterministicBudgetSubject $ownership
  [void](ConvertTo-CensusAuthBudgetSubject $auth)
  foreach($site in @('ownership','authentication')){
    $sample='[Diagnostics.Stopwatch]::StartNew()'+$(if($site-ceq'ownership'){'; $process.WaitForExit([int]$remaining)'}else{''})
    [void](ConvertTo-HistoricalBudgetSubject $sample $site)
    foreach($bad in @($sample.Replace('[Diagnostics.Stopwatch]::StartNew()','0'),($sample+'; [Diagnostics.Stopwatch]::StartNew()'))){
      $failure=$null;try{[void](ConvertTo-HistoricalBudgetSubject $bad $site)}catch{$failure=$_.Exception.Message}
      Assert-CensusFixture ($failure -ceq "ASSERTION FAILED: historical $site clock/wait anchors") "historical $site missing/duplicate refusal"
    }
    if($site-ceq'ownership'){
      foreach($bad in @($sample.Replace('$process.WaitForExit([int]$remaining)','0'),($sample+'; $process.WaitForExit([int]$remaining)'))){
        $failure=$null;try{[void](ConvertTo-HistoricalBudgetSubject $bad $site)}catch{$failure=$_.Exception.Message}
        Assert-CensusFixture ($failure-ceq'ASSERTION FAILED: historical ownership clock/wait anchors') 'historical missing/duplicate wait refusal'
      }
    }
  }
  foreach($pair in @(@($ownership,'[Diagnostics.Stopwatch]::new()','ownership'),@($auth,'[Diagnostics.Stopwatch]::new()','authentication'))){
    foreach($bad in @($pair[0].Replace($pair[1],'0'),($pair[0]+$pair[1]))){
      $failure=$null;try{if($pair[2]-ceq'ownership'){[void](ConvertTo-DeterministicBudgetSubject $bad)}else{[void](ConvertTo-CensusAuthBudgetSubject $bad)}}catch{$failure=$_.Exception.Message}
      Assert-CensusFixture ($null -ne $failure) "$($pair[2]) missing/duplicate refusal"
    }
  }
  & {
    $deterministicBudgetMeter=New-DeterministicBudgetMeter
    . ([scriptblock]::Create($converted))
    function Replay([int]$Charge,[int]$CpuWork=0,[switch]$Persistent){
      $observed=[Collections.Generic.List[object]]::new();$failure=$null
      try{Invoke-ProductCensusEvaluation {
        param($b)
        $b.watch.Restart();$b.watch.Charge(1)
        for($i=0;$i-lt$CpuWork;$i++){$null=[Math]::Sqrt($i)}
        if($Persistent-or$observed.Count-eq0){$b.watch.Charge($Charge)}
        $observed.Add(@{generation=$b.watch.restarts;charged=$b.watch.ElapsedMilliseconds;cap=$b.deadline})
        if($b.watch.ElapsedMilliseconds-ge$b.deadline){throw 'git-deadline'}
      }|Out-Null}catch{$failure=$_.Exception.Message}
      return @{rows=$observed;failure=$failure}
    }
    function Assert-Replay($Replay){
      Assert-CensusFixture ($Replay.rows.Count-eq2) 'seam loaded evaluation count=2'
      Assert-CensusFixture ($Replay.rows[0].charged-eq5002-and$Replay.rows[1].charged-eq1) 'seam charged readings'
    }
    $fast=Replay 5001;$busy=Replay 5001 10000
    Assert-CensusFixture ($fast.rows.Count-eq2-and$busy.rows.Count-eq2-and$fast.rows[0].charged-eq5002-and$busy.rows[0].charged-eq5002-and$fast.rows[1].charged-eq1-and$busy.rows[1].charged-eq1) 'seam same-charge opposite-CPU replay'
    Assert-CensusFixture ($fast.rows[1].generation-eq($fast.rows[0].generation+1)) 'seam restart generation'
    Assert-CensusFixture ((Replay 4998).rows.Count-eq1-and(Replay 4999).rows.Count-eq2) 'seam exact cap boundary'
    Assert-Replay $fast;Assert-Replay $busy
    $killed=$null;try{Assert-Replay (Replay 0)}catch{$killed=$_.Exception.Message}
    Assert-CensusFixture ($killed-ceq'ASSERTION FAILED: seam loaded evaluation count=2') 'seam dropped charge own-guard kill'
    Write-Output 'MUTANT budget-seam drop-charge KILLED guard=evaluation-count'
    $saved=$deterministicBudgetMeter
    $deterministicBudgetMeter=New-DeterministicBudgetMeter
    $deterministicBudgetMeter | Add-Member -NotePropertyName wall -NotePropertyValue ([Diagnostics.Stopwatch]::StartNew())
    $deterministicBudgetMeter | Add-Member -Force -MemberType ScriptProperty -Name ElapsedMilliseconds -Value {$this.wall.ElapsedMilliseconds}
    $killed=$null;try{Assert-Replay (Replay 5001)}catch{$killed=$_.Exception.Message}
    Assert-CensusFixture ($killed-cin@('ASSERTION FAILED: seam loaded evaluation count=2','ASSERTION FAILED: seam charged readings')) 'seam clock leak own-guard kill'
    $deterministicBudgetMeter=$saved
    Write-Output 'MUTANT budget-seam clock-leak KILLED guard=charged-replay-census'
    $needle='$evaluation -lt 2';Assert-CensusFixture ($converted.Contains($needle)) 'seam retry mutant anchor'
    . ([scriptblock]::Create($converted.Replace($needle,'$evaluation -lt 3')))
    $calls=@{count=0};try{Invoke-ProductCensusEvaluation {param($b)$calls.count++;throw 'git-deadline'}|Out-Null}catch{}
    # The terminal guard must be the one variable changed to allow a third arm.
    Assert-CensusFixture ($calls.count-eq2) 'loop inflation alone cannot bypass terminal retry guard'
    $persistent=Replay 5001 -Persistent
    Assert-CensusFixture ($persistent.failure-ceq'git-deadline'-and$persistent.rows.Count-eq2) 'seam persistent terminal refusal'
    . ([scriptblock]::Create($converted.Replace('$evaluation -eq 1','$evaluation -eq 2')))
    $mutant=Replay 5001 -Persistent
    $killed=$null;try{Assert-CensusFixture ($mutant.failure-ceq'git-deadline'-and$mutant.rows.Count-eq2) 'seam persistent terminal refusal'}catch{$killed=$_.Exception.Message}
    Assert-CensusFixture ($killed-ceq'ASSERTION FAILED: seam persistent terminal refusal') 'seam extra-retry own-guard kill'
    Write-Output 'MUTANT budget-seam extra-retry KILLED guard=terminal-refusal'
  }
  Write-Output 'PASS product-census-budget seam anchors/inverse-diff/restarts/cap-boundaries/replay/mutants; fixtures=0 Git=0 processes=0'
}

if($Control -ceq 'seam'){Test-BudgetSeam;return}

$parent = Join-Path ([IO.Path]::GetTempPath()) ('synthetic-census-' + [guid]::NewGuid().ToString('N'))
$failures = [Collections.Generic.List[string]]::new()
try {
  $f = New-CensusFixture $parent
  $platform = New-CensusFixtureOwner $f
  $owner = New-CensusFixtureOwner $f $f.product
  $owner.record.state='launching'; $owner.record.childPid=$null; $owner.record.childStartIdentity=$null
  Write-DispatchOwnershipRecord $owner.path $owner.record
  $ownerBytes=[IO.File]::ReadAllBytes($owner.path)
  $head=Invoke-CensusFixtureGit $f.product @('rev-parse','HEAD')
  $obligation=@{schemaVersion='landed-integration-owed/v1';landedPr=908184L;landedHead=('a'*40);pr=908185L;
    targetHead=$head;newBase=$head;branch='synthetic/product';worktree=$f.product;integrationLane='integration-budget'}
  $owed=Join-Path $f.runtime 'integration-owed-908185-aaaaaaaaaaaa.json'
  [IO.File]::WriteAllText($owed,($obligation|ConvertTo-Json -Compress))
  $source = Join-Path $parent 'subject'
  New-Item -ItemType Directory $source | Out-Null
  foreach ($name in @('dispatch-ownership.ps1','landed-integration-evidence.psm1')) {
    if ($Baseline) {
      $text = (& git -C (Split-Path -Parent $PSScriptRoot) show "f292db3c0c89aba867b7ae10da6fffd0fc2970ee:.orchestrator/$name") -join "`n"
      if ($LASTEXITCODE) { throw 'baseline source unavailable' }
      $site=if($name-ceq'dispatch-ownership.ps1'){'ownership'}else{'authentication'}
      $text=ConvertTo-HistoricalBudgetSubject $text $site
      if($site-ceq'ownership'){$text=(Get-CensusBudgetMeterPrelude)+$text}
      [IO.File]::WriteAllText((Join-Path $source $name),$text)
    } else { Copy-Item (Join-Path $PSScriptRoot $name) $source }
  }
  if(-not$Baseline){
    $p=Join-Path $source 'dispatch-ownership.ps1'
    [IO.File]::WriteAllText($p,((Get-CensusBudgetMeterPrelude)+(ConvertTo-DeterministicBudgetSubject ([IO.File]::ReadAllText($p)))))
    $p=Join-Path $source 'landed-integration-evidence.psm1'
    [IO.File]::WriteAllText($p,(ConvertTo-CensusAuthBudgetSubject ([IO.File]::ReadAllText($p))))
  }
  # Count actual process creation, not calls that fail the pre-spawn deadline.
  $ownershipPath=Join-Path $source 'dispatch-ownership.ps1'
  $instrumented=[IO.File]::ReadAllText($ownershipPath)
  $spawn='$process = [Diagnostics.Process]::Start($start)'
  Assert-CensusFixture ([regex]::Matches($instrumented,[regex]::Escape($spawn)).Count -eq 1) 'one census Git spawn site'
  $instrumented=$instrumented.Replace($spawn,'$script:budgetStats.spawns++; ' + $spawn)
  if (-not $Baseline) {
    $retryGuard="if (`$_.Exception.Message -cne 'git-deadline' -or `$evaluation -eq 1) { throw }"
    Assert-CensusFixture ([regex]::Matches($instrumented,[regex]::Escape($retryGuard)).Count -eq 1) 'one shared retry decision'
    $instrumented=$instrumented.Replace($retryGuard,'$script:budgetStats.outcomes.Add($_.Exception.Message); ' + $retryGuard)
  }
  [IO.File]::WriteAllText($ownershipPath,$instrumented)
  foreach ($site in @('ownership','authentication')) {
    foreach ($mode in @('quiet','loaded','unauthorized','persistent','unknown','poisoned-anchor','changed-identity')) {
      if ($Baseline -and $mode -notin @('quiet','loaded')) { continue }
      try {
        if ($mode -eq 'unauthorized') {
          # Change only owner identity: it now duplicates the foreign seat.
          # All record/process/repository proof remains native and valid.
          $owner.record.worktree=$f.seat; $owner.record.lane='platform-seat'
          Write-DispatchOwnershipRecord $owner.path $owner.record
        }
        $result=Invoke-BudgetProbe $f $obligation $owner.path $source $site $mode
        Write-BudgetMeasurement $result $site $mode
        if ($mode -eq 'quiet') { $quietGitCalls=$result.stats.evaluations[-1].calls }
        if ($Baseline -and $mode -eq 'loaded') {
          Assert-CensusFixture ($result.stats.evaluations.Count -eq 1 -and
            $result.stats.calls-eq1-and$result.stats.spawns-eq0-and$result.stats.evaluations[0].charges-eq5002-and
            (($site -eq 'ownership' -and $result.value.health.status -ceq 'partial'-and
              @($result.value.health.diagnostics|Where-Object { $_.code-ceq'worktree-outside-container'-and$_.reason-ceq'git-deadline' }).Count-eq1) -or
             ($site -eq 'authentication' -and $result.failure -like 'OWED_REBASE_OWNER_UNAUTHORIZED*'))) 'baseline deadline reproduces refusal'
          Write-Output "BASELINE $site loaded REFUSED reason=$($result.failure)"
        } else {
          $count=if ($mode -in @('loaded','persistent','poisoned-anchor','changed-identity')) {2} else {1}
          Assert-BudgetResult $result $site $mode $count
          if ($mode -in @('loaded','poisoned-anchor')) {
            Assert-CensusFixture ($result.stats.evaluations[0].charges -gt 5000 -and
              $result.stats.evaluations[1].reads.Count -eq $quietGitCalls -and
              @($result.stats.evaluations[1].reads | Where-Object { $_ -like "$($f.anchor)|rev-parse*" }).Count -eq 1) "$site fresh complete anchors after deadline"
          }
          Write-Output "CONTROL product-census-budget-$mode $site PASS"
        }
      } catch {
        $failures.Add($_.Exception.Message)
        Write-Output "FAIL $site/$mode $($_.Exception.Message)"
      } finally { [IO.File]::WriteAllBytes($owner.path,$ownerBytes) }
    }
  }
  if ($Baseline) {
    if ($failures.Count) { throw ($failures -join "`n") }
    return
  }
  $result=Invoke-BudgetProbe $f $obligation $owner.path $source publication persistent
  Assert-BudgetResult $result publication persistent 2
  Assert-CensusFixture (@(Get-ChildItem $f.runtime -Filter 'integration-rebase-*').Count -eq 0 -and
    [IO.File]::ReadAllText($owed) -ceq ($obligation|ConvertTo-Json -Compress)) 'integration deadline zero publication/owed unchanged'
  Write-Output 'CONTROL product-census-budget-persistent-deadline integration-publication PASS publication=0'

  foreach ($site in @('ownership','authentication')) {
    $strict=Invoke-BudgetProbe $f $obligation $owner.path $source $site loaded -Unscoped
    Assert-CensusFixture ($strict.stats.evaluations.Count -eq 0 -and
      (($site -eq 'ownership' -and $strict.value.health.status -ceq 'partial') -or
       ($site -eq 'authentication' -and $strict.failure -like 'OWED_REBASE_OWNER_UNAUTHORIZED*'))) "$site strict/unscoped unchanged"
  }
  Write-Output 'CONTROL product-census-budget-shared-rule strict/unscoped PASS no-product-Git=0'

  $ownershipPath=Join-Path $source 'dispatch-ownership.ps1'
  $candidate=[IO.File]::ReadAllText($ownershipPath)
  $old="`$_.Exception.Message -cne 'git-deadline' -or `$evaluation -eq 1"
  Assert-CensusFixture ($candidate.Contains($old)) 'unauthorized mutant exact predicate'
  try {
    [IO.File]::WriteAllText($ownershipPath,$candidate.Replace($old,'$evaluation -eq 1'))
    $owner.record.worktree=$f.seat; $owner.record.lane='platform-seat'
    Write-DispatchOwnershipRecord $owner.path $owner.record
    $mutant=Invoke-BudgetProbe $f $obligation $owner.path $source authentication unauthorized
    $killed=$null
    try { Assert-BudgetResult $mutant authentication unauthorized 1 } catch { $killed=$_.Exception.Message }
    Assert-CensusFixture ($killed -ceq 'ASSERTION FAILED: authentication/unauthorized allowance evaluations=1' -and
      $mutant.stats.evaluations.Count -eq 2 -and $mutant.failure -like 'OWED_REBASE_OWNER_UNAUTHORIZED*' -and
      $mutant.stats.outcomes.Count -eq 2 -and
      @($mutant.stats.outcomes | Where-Object { $_ -cnotlike 'OWED_REBASE_OWNER_UNAUTHORIZED*' }).Count -eq 0) 'unauthorized mutant killed only by allowance assertion'
    Write-Output 'MUTANT product-census-budget-mutant unauthorized-allowance KILLED evaluations=2 expected=1 both-refusals=OWED_REBASE_OWNER_UNAUTHORIZED'
  } catch {
    $failures.Add($_.Exception.Message)
    Write-Output "FAIL unauthorized-allowance mutant $($_.Exception.Message) observed=$($mutant.failure)"
  } finally { [IO.File]::WriteAllText($ownershipPath,$candidate); [IO.File]::WriteAllBytes($owner.path,$ownerBytes) }

  $modulePath=Join-Path $source 'landed-integration-evidence.psm1'
  $candidateModule=[IO.File]::ReadAllText($modulePath)
  $old='return Invoke-ProductCensusEvaluation $evaluate'
  Assert-CensusFixture ($candidateModule.Contains($old)) 'divergent mutant exact shared call'
  try {
    [IO.File]::WriteAllText($modulePath,$candidateModule.Replace($old,'$independentMeter=New-DeterministicBudgetMeter; return & $evaluate @{watch=$independentMeter;deadline=5000}'))
    $mutant=Invoke-BudgetProbe $f $obligation $owner.path $source authentication loaded
    $killed=$null
    try { Assert-BudgetResult $mutant authentication loaded 2 } catch { $killed=$_.Exception.Message }
    Assert-CensusFixture ($killed -ceq 'ASSERTION FAILED: authentication/loaded allowance evaluations=2' -and $mutant.failure-ceq'OWED_REBASE_PRODUCT_CENSUS_GIT_DEADLINE' -and $mutant.stats.evaluations[0].charges-gt5000) 'divergent site mutant killed by shared policy assertion'
    Write-Output 'MUTANT product-census-budget-shared-rule divergent-site KILLED evaluations=1 expected=2'
  } catch {
    $failures.Add($_.Exception.Message)
    Write-Output "FAIL divergent-site mutant $($_.Exception.Message)"
  } finally { [IO.File]::WriteAllText($modulePath,$candidateModule) }

  # #8594: a caller's Trace2 target never reaches census Git children (the R3
  # fixture exports one per case), while the caller's own Git keeps writing it.
  # The kill is the inherited trace itself, not elapsed time.
  $candidate=[IO.File]::ReadAllText($ownershipPath)
  $traceDrop="foreach (`$name in @(`$start.Environment.Keys)) { if (`$name -like 'GIT_TRACE2*') { [void]`$start.Environment.Remove(`$name) } }"
  Assert-CensusFixture ([regex]::Matches($candidate,[regex]::Escape($traceDrop)).Count -eq 1) 'one census Trace2 drop'
  function Get-CensusTraceObservation([string]$Trace) {
    $env:GIT_TRACE2_EVENT=$Trace
    try {
      $probeResult=Invoke-BudgetProbe $f $obligation $owner.path $source authentication quiet
      [void](Invoke-CensusFixtureGit $f.product @('rev-parse','HEAD'))
    } finally { Remove-Item Env:GIT_TRACE2_EVENT -ErrorAction SilentlyContinue }
    $starts=@(Get-Content -LiteralPath $Trace | ForEach-Object { $_ | ConvertFrom-Json -DateKind String } | Where-Object event -CEQ 'start')
    [pscustomobject]@{result=$probeResult;census=@($starts | Where-Object { $_.argv -contains '--no-optional-locks' }).Count
      caller=@($starts | Where-Object { $_.argv -notcontains '--no-optional-locks' -and $_.argv -contains 'rev-parse' }).Count}
  }
  function Assert-CensusTraceDropped($Observed) {
    Assert-CensusFixture ($Observed.result.stats.spawns -gt 0 -and $Observed.census -eq 0) "census Git dropped inherited Trace2 spawns=$($Observed.result.stats.spawns) traced=$($Observed.census)"
  }
  $priorTrace=$env:GIT_TRACE2_EVENT
  try {
    $observed=Get-CensusTraceObservation (Join-Path $parent 'trace2-candidate.jsonl')
    Assert-CensusTraceDropped $observed
    Assert-CensusFixture ($observed.caller -eq 1) "caller Git kept its Trace2 witness traced=$($observed.caller)"
    Assert-CensusFixture ($null -eq $observed.result.failure -and $null -ne $observed.result.value) "trace2 isolation admitted: $($observed.result.failure)"
    Write-Output "CONTROL product-census-trace2-isolation authentication PASS censusSpawns=$($observed.result.stats.spawns) censusTraced=0 callerTraced=1"
    [IO.File]::WriteAllText($ownershipPath,$candidate.Replace($traceDrop,''))
    $mutant=Get-CensusTraceObservation (Join-Path $parent 'trace2-mutant.jsonl')
    $killed=$null
    try { Assert-CensusTraceDropped $mutant } catch { $killed=$_.Exception.Message }
    Assert-CensusFixture ($killed -clike 'ASSERTION FAILED: census Git dropped inherited Trace2 spawns=*' -and $mutant.census -gt 0 -and $mutant.caller -eq 1) 'inherited-Trace2 mutant killed only by isolation assertion'
    Write-Output "MUTANT product-census-trace2-isolation inherited-trace KILLED censusTraced=$($mutant.census) censusSpawns=$($mutant.result.stats.spawns)"
  } catch {
    $failures.Add($_.Exception.Message)
    Write-Output "FAIL trace2-isolation $($_.Exception.Message)"
  } finally {
    [IO.File]::WriteAllText($ownershipPath,$candidate)
    if ($null -ne $priorTrace) { $env:GIT_TRACE2_EVENT=$priorTrace }
  }

  # Derive refusal membership from the actual proof/auth AST, not a second
  # hand-maintained reason vocabulary. Unknown/malformed variants also refuse.
  $module=Import-Module $modulePath -Force -PassThru -DisableNameChecking
  try {
    & $module {
      $script:budgetStats=@{outcomes=[Collections.Generic.List[string]]::new()}
      $reasons=@(${function:Test-ProductCensusPlatformSeat}.Ast.FindAll({param($n)
        $n -is [Management.Automation.Language.StringConstantExpressionAst]
      },$true) | ForEach-Object Value | Where-Object { $_ -and $_ -cne 'git-deadline' })
      $reasons+=@(${function:Assert-RebaseOwner}.Ast.FindAll({param($n)
        $n -is [Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -like 'OWED_REBASE_OWNER_UNAUTHORIZED*'
      },$true) | ForEach-Object Value)
      $reasons+=@('GIT-DEADLINE','git-deadline ','synthetic-secret-unknown')
      foreach ($reason in @($reasons | Sort-Object -Unique)) {
        $calls=@{count=0}; $failure=$null
        try { Invoke-ProductCensusEvaluation {param($b) $calls.count++; throw $reason} } catch { $failure=$_.Exception.Message }
        if ($calls.count -ne 1 -or $failure -cne $reason) { throw 'non-deadline outcome acquired allowance' }
      }
      $calls=@{count=0}; $caps=[Collections.Generic.List[int]]::new()
      try { Invoke-ProductCensusEvaluation {param($b) $calls.count++; $caps.Add($b.deadline); throw 'git-deadline'} 7 } catch {
        if ($_.Exception.Message -cne 'git-deadline') { throw }
      }
      if ($calls.count -ne 2 -or @($caps | Where-Object {$_ -ne 7}).Count) { throw 'smaller caller bound not preserved' }
    }
  } finally { Remove-Module $module }
  Write-Output 'CONTROL product-census-budget-shared-rule source-derived-nondeadline/unknown/smaller-cap PASS'
  if ($failures.Count) { throw ($failures -join "`n") }
  Write-Output 'PASS product-census-budget'
} finally { Remove-CensusFixture $parent }
