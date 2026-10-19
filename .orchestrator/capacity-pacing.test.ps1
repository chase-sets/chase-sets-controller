# capacity-pacing.ps1 (#9316): per-provider new-lane allowance from account
# headroom, time to reset and measured burn. AC1 budgets and the Fable window,
# AC2 allowance from a registry-mapped census, AC3 burn measurement with the
# 168-hour clip, AC4 unknown handling and byte-identical replay, the F1/F2
# status boundary (every consumed window field validated, account identity
# required and unique per provider), plus the plain-floor, clip-ignored,
# Fable-share-cap-restored, exhausted-summed, unknown-authorizes mutants and one
# deletion mutant per F1 field check and for the F2 identity/duplicate checks.
param([string]$LegacyReducerPath)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'routing-data-test-support.ps1')
$reducer = Join-Path $PSScriptRoot 'capacity-pacing.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('capacity-pacing-test-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$oldRoot = $env:CHASE_SETS_ROUTING_DATA_ROOT; $oldLkg = $env:CHASE_SETS_ROUTING_LKG_PATH
$script:assertions = 0; $script:mutants = 0
$utf8 = [Text.UTF8Encoding]::new($false)

function Assert-Pacing([bool]$Condition, [string]$Message) {
  $script:assertions += 1
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}
function Assert-Near([double]$Actual, [double]$Expected, [string]$Message) {
  Assert-Pacing ([Math]::Abs($Actual - $Expected) -lt 0.0000015) "$Message (actual $Actual expected $Expected)"
}
function Write-Json([string]$Path, $Value) { [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 30), $utf8) }
function Format-Instant([DateTimeOffset]$Value) { return $Value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'") }

# The issue's captured dispatch moment is the fixed clock for every case.
$now = [DateTimeOffset]::Parse('2026-10-10T20:20:02Z', [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
$nowText = Format-Instant $now
$fixture = New-RoutingDataFixture -Root (Join-Path $root 'state') -NowUtc $now -Families @(
  [pscustomobject]@{name='astra';provider='codex';current='gpt-6-astra';historical=@()},
  [pscustomobject]@{name='sol';provider='codex';current='gpt-6.1-sol';historical=@()},
  [pscustomobject]@{name='fable';provider='claude';current='claude-fable-5-1';historical=@()},
  [pscustomobject]@{name='opus';provider='claude';current='claude-opus-5-5';historical=@()})
$env:CHASE_SETS_ROUTING_DATA_ROOT = $fixture.stateRoot; $env:CHASE_SETS_ROUTING_LKG_PATH = $fixture.lkgPath
$forecastPath = Join-Path $fixture.stateRoot 'capacity-forecast.json'

function Set-Forecast([double]$ClaudeDemand, [double]$CodexDemand, [double]$GeneratedMinutesAgo = 1, [double]$StaleAfterMinutes = 14) {
  $generated = $now.AddMinutes(-$GeneratedMinutesAgo)
  Write-Json $forecastPath ([ordered]@{
    format='capacity-forecast/v1'; generatedAt=(Format-Instant $generated); staleAfter=(Format-Instant ($generated.AddMinutes($StaleAfterMinutes)))
    mode='active'; decisionDigest='0123456789abcdef'
    providers=[ordered]@{codex=[ordered]@{state='normal';demand=[ordered]@{last168h=$CodexDemand}};claude=[ordered]@{state='spend';demand=[ordered]@{last168h=$ClaudeDemand}}}
    balance=[ordered]@{toward=$null;steps=0}; decision=[ordered]@{modelWindowStates=[ordered]@{claude=[ordered]@{Fable='spend'};codex=[ordered]@{}}}
  })
}
function Clear-Forecast { if ([IO.File]::Exists($forecastPath)) { [IO.File]::Delete($forecastPath) } }

function Reset-At($Hours) { if ($null -eq $Hours) { return $null } ; return $now.AddHours([double]$Hours).ToUnixTimeMilliseconds() }
function New-ClaudeAccount([string]$Id, [string]$Status, [double]$FiveUsed, $FiveResetHours, [double]$WeeklyUsed, $WeeklyResetHours, [double]$FableUsed, $FableResetHours, [bool]$Disabled = $false, [bool]$UsageStale = $false) {
  [ordered]@{
    id=$Id; provider='claude'; disabled=$Disabled; status=$Status; usageStale=$UsageStale; usageUpdatedAt=(Format-Instant $now.AddMinutes(-1))
    quotaWindows=@(
      [ordered]@{id='limit:0';scope='All models';used=$FiveUsed;resetAt=(Reset-At $FiveResetHours);common=$true;durationSeconds=18000;label='5-hour'},
      [ordered]@{id='limit:1';scope='All models';used=$WeeklyUsed;resetAt=(Reset-At $WeeklyResetHours);common=$true;durationSeconds=604800;label='Weekly'},
      [ordered]@{id='limit:2';scope='Fable';used=$FableUsed;resetAt=(Reset-At $FableResetHours);common=$false;durationSeconds=604800;label='Weekly'})
  }
}
function New-CodexAccount([string]$Id, [string]$Status, [double]$Used, $ResetHours) {
  [ordered]@{
    id=$Id; provider='codex'; disabled=$false; status=$Status; usageStale=$false; usageUpdatedAt=(Format-Instant $now.AddMinutes(-1))
    quotaWindows=@([ordered]@{id='codex:primary_window';scope='Codex';used=$Used;resetAt=(Reset-At $ResetHours);common=$true;durationSeconds=604800;label='Weekly'})
  }
}
function New-Status([object[]]$Accounts, $CheckedAt = $null) {
  return [ordered]@{accounts=[object[]]$Accounts;checkedAt=$(if($null -ne $CheckedAt){$CheckedAt}else{Format-Instant $now.AddMinutes(-1)});error=$null}
}
# F1/F2 fixtures: a fresh 5-hour-binding Claude account (22% used, weekly 10%,
# Fable 40%), the same account identified by name only, and a status that adds
# two healthy Codex accounts so a malformed Claude input must also zero Codex.
function New-Claude5 { return New-ClaudeAccount 'claude-a' 'available' 22 5 10 87 40 7 }
function New-Named([string]$Name) { $a = New-Claude5; $a.Remove('id'); $a.name = $Name; return $a }
function New-StatusWith([object[]]$ClaudeAccounts) {
  return New-Status ([object[]]$ClaudeAccounts + @((New-CodexAccount 'codex-x' 'available' 2 160), (New-CodexAccount 'codex-y' 'available' 10 150)))
}
# AC1 shapes: three Claude accounts, one available with 78 remaining on its
# binding weekly window (reset in 87 h), two exhausted. The 5-hour variant moves
# the binding window to limit:0 (used 22, reset in 5 h) with a 7-hour Fable
# window at 40% used.
$exhaustedB = New-ClaudeAccount 'claude-b' 'exhausted' 0 $null 100 50 10 50
$exhaustedC = New-ClaudeAccount 'claude-c' 'exhausted' 0 $null 100 60 0 60
$claude87 = New-Status @((New-ClaudeAccount 'claude-a' 'available' 2 3 22 87 27 87), $exhaustedB, $exhaustedC)
$claude5 = New-Status @((New-ClaudeAccount 'claude-a' 'available' 22 5 10 87 40 7), $exhaustedB, $exhaustedC)
$mixed = New-Status @((New-ClaudeAccount 'claude-a' 'available' 22 5 10 87 40 7), $exhaustedB, $exhaustedC,
  (New-CodexAccount 'codex-x' 'available' 2 160), (New-CodexAccount 'codex-y' 'available' 10 150))

function New-Case([string]$Name, $Status, [object[]]$Lanes = @(), [string]$CensusHealth = 'ok') {
  $dir = Join-Path $root $Name; [void][IO.Directory]::CreateDirectory($dir)
  $case = [ordered]@{dir=$dir;status=(Join-Path $dir 'status.json');census=(Join-Path $dir 'census.json');log=(Join-Path $dir 'dispatch-log.jsonl')}
  if ($null -ne $Status) { Write-Json $case.status $Status }
  Write-Json $case.census ([ordered]@{activeLanes=[object[]]$Lanes;health=[ordered]@{status=$CensusHealth}})
  [IO.File]::WriteAllText($case.log, '', $utf8)
  return $case
}
function New-Lane([string]$Family, [string]$Slot = $null) {
  $lane = [ordered]@{lane=('lane-' + [guid]::NewGuid().ToString('N').Substring(0, 8));head=('a' * 40);family=$Family}
  if ($Slot) { $lane.slot = $Slot }
  return $lane
}
function Add-DispatchRow($Case, [string]$Family, [double]$StartHoursAgo, [string]$Transcript, $LastWriteHoursAgo) {
  $row = [ordered]@{ts=(Format-Instant $now.AddHours(-$StartHoursAgo));kind='dispatch';lane="lane-$Transcript";family=$Family;harness=$(if($Family -cin @('fable','opus')){'claude'}else{'codex'});transcript="$Transcript.jsonl";issue=9316}
  [IO.File]::AppendAllText($Case.log, ($row | ConvertTo-Json -Compress) + "`n", $utf8)
  if ($null -ne $LastWriteHoursAgo) {
    $path = Join-Path $Case.dir "$Transcript.jsonl"
    [IO.File]::WriteAllText($path, '{"type":"synthetic"}' + "`n", $utf8)
    [IO.File]::SetLastWriteTimeUtc($path, $now.AddHours(-[double]$LastWriteHoursAgo).UtcDateTime)
  }
}
function Invoke-Pacing($Case, [hashtable]$Extra = @{}, [string]$ScriptPath = $reducer) {
  $parameters = @{StateRoot=$fixture.stateRoot;LkgPath=$fixture.lkgPath;NowUtc=$nowText;StatusPath=$Case.status;CensusPath=$Case.census;DispatchLogPath=$Case.log}
  foreach ($key in $Extra.Keys) { if ($null -eq $Extra[$key]) { $parameters.Remove($key) } else { $parameters[$key] = $Extra[$key] } }
  $raw = (& $ScriptPath @parameters) -join "`n"
  return [pscustomobject]@{raw=$raw;data=($raw | ConvertFrom-Json -Depth 30 -DateKind String)}
}
function Assert-AllZero($Data, [string]$Message) {
  Assert-Pacing ($Data.status -ceq 'unknown') "$Message status unknown"
  foreach ($provider in @('claude', 'codex')) {
    $p = $Data.providers.$provider
    Assert-Pacing ($p.newLaneAllowance -eq 0 -and $p.laneBudget -eq 0) "$Message $provider allowance zero"
  }
  Assert-Pacing ($Data.providers.claude.fableLaneBudget -eq 0) "$Message fable budget zero"
}
function Assert-Mutant([string]$Name, [string]$Old, [string]$New, [scriptblock]$Probe) {
  # The probe asserts the correct value against a mutated copy of the reducer
  # (with its library siblings) and must fail its own assertion.
  $script:mutants += 1
  $source = [IO.File]::ReadAllText($reducer).Replace("`r`n", "`n")
  Assert-Pacing ($source.Contains($Old)) "mutation seam $Name"
  $dir = Join-Path $root "mutant-$Name"; [void][IO.Directory]::CreateDirectory($dir)
  Get-ChildItem -LiteralPath $PSScriptRoot -File | Where-Object Extension -In @('.ps1', '.psm1', '.cjs') | Copy-Item -Destination $dir
  $mutantPath = Join-Path $dir 'capacity-pacing.ps1'
  [IO.File]::WriteAllText($mutantPath, $source.Replace($Old, $New), $utf8)
  $failure = $null
  try { & $Probe $mutantPath | Out-Null } catch { $failure = $_.Exception.Message }
  if ($null -eq $failure) { throw "MUTANT SURVIVED: $Name" }
  if (-not $failure.StartsWith('ASSERTION FAILED:', [StringComparison]::Ordinal)) { throw "MUTANT PROBE BROKEN: ${Name}: $failure" }
  Write-Output "KILLED $Name"
}

function Set-PaceForecast([scriptblock]$Change = {}) {
  $registry = $fixture.registry | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable -DateKind String
  $registry.generatedAt = Format-Instant $now; $registry.source.statusCheckedAt = Format-Instant $now
  Write-Json (Join-Path $fixture.stateRoot 'model-registry.json') $registry
  Set-Forecast 0.03294 0.02298
  $f = Get-Content -Raw -LiteralPath $forecastPath | ConvertFrom-Json -AsHashtable -DateKind String
  # Target facts from #9737's 2026-10-15T22:37Z capture, with synthetic
  # non-target precursor steps. No test reads or rewrites AgentPools state.
  foreach ($provider in @('codex','claude')) {
    $codex = $provider -ceq 'codex'
    $rates = if ($codex) { @(0.02087,0.02091,0.02096,0.02401,0.02433,0.03101) } else { @(0.02724,0.0346) }
    $steps = @(for ($i=0; $i -lt $rates.Count; $i++) { [ordered]@{credits=($i+1);reachable=$true;unitsPerHour=$rates[$i]} })
    $f.providers[$provider].pace = [ordered]@{
      computedAt=(Format-Instant $now.AddMinutes(-2))
      atDemand=[ordered]@{unitsPerHour=$(if($codex){0.02298}else{0.03294});usedUnits=$(if($codex){15.71}else{11.54});lostUnits=$(if($codex){7}else{1});creditsUsed=$(if($codex){3}else{1});creditsLapsing=$(if($codex){3}else{1});shortHours=0;firstShortAt=$null}
      fullUse=$(if($codex){$null}else{[ordered]@{unitsPerHour=0.0346}})
      then=$(if($codex){$null}else{[ordered]@{from='2026-10-21T13:35:29Z';unitsPerHour=0.01786}})
      steps=$steps
    }
    $f.providers[$provider].supply = [ordered]@{creditExpiries=@($(if($codex){'2026-10-22T20:45:49Z'}else{'2026-10-22T16:00:00Z'}))}
  }
  & $Change $f
  Write-Json $forecastPath $f
}
function Get-LegacyPacingJson($Data) {
  $copy = $Data | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable -DateKind String
  foreach ($provider in @('codex','claude')) {
    foreach ($field in @('paceSource','targetUnitsPerHour','paceBudget','creditsLapsing','nextCreditExpiry')) { $copy.providers[$provider].Remove($field) }
  }
  return ($copy | ConvertTo-Json -Depth 20).Replace("`r`n", "`n")
}
function Assert-NoPaceRaise($Case, [string]$Source) {
  $withPace = Invoke-Pacing $Case
  if ($LegacyReducerPath) {
    $legacy = Invoke-Pacing $Case @{} $LegacyReducerPath
    Assert-Pacing ((Get-LegacyPacingJson $withPace.data) -ceq $legacy.raw) "9737 AC3 $Source byte-identical to supplied #9316 reducer"
  }
  $f = Get-Content -Raw -LiteralPath $forecastPath | ConvertFrom-Json -AsHashtable -DateKind String
  foreach ($provider in @('codex','claude')) { $f.providers[$provider].Remove('pace') }
  Write-Json $forecastPath $f
  $withoutPace = Invoke-Pacing $Case
  foreach ($provider in @('codex','claude')) {
    $p = $withPace.data.providers.$provider
    Assert-Pacing ($p.paceSource -ceq $Source -and $null -eq $p.targetUnitsPerHour -and $p.paceBudget -eq 0) "9737 AC3 $provider $Source never raises"
  }
  Assert-Pacing ((Get-LegacyPacingJson $withPace.data) -ceq (Get-LegacyPacingJson $withoutPace.data)) "9737 AC3 $Source legacy fields byte-identical"
  Write-Output "PASS 9737 AC3 providers=codex,claude paceSource=$Source legacy-fields=identical baseline=$([bool]$LegacyReducerPath)"
}

try {
  # #9737 failing-first controls are independent, so a baseline run exposes
  # every changed AC rather than stopping at the first missing output field.
  $legacyNow = $now; $legacyNowText = $nowText
  $now = [DateTimeOffset]::Parse('2026-10-15T22:37:30Z'); $nowText = Format-Instant $now
  $paceCase = New-Case '9737-pace' (New-Status @(
    (New-ClaudeAccount 'claude-a' 'available' 2 3 22 87 0 1),
    (New-CodexAccount 'codex-a' 'available' 22 87)))
  $paceTwo = New-Case '9737-two-live' (Get-Content -Raw -LiteralPath $paceCase.status | ConvertFrom-Json -DateKind String) @((New-Lane 'sol'),(New-Lane 'sol'))
  $paceFailures = @()
  foreach ($ac in @('AC1','AC2','AC3','AC4')) {
    try {
      Set-PaceForecast
      switch ($ac) {
        'AC1' {
          $r = (Invoke-Pacing $paceCase).data
          Assert-Pacing ($r.providers.codex.targetUnitsPerHour -eq 0.03101 -and $r.providers.codex.paceBudget -eq 3) '9737 AC1 codex last reachable step / default burn'
          Assert-Pacing ($r.providers.claude.targetUnitsPerHour -eq 0.0346 -and $r.providers.claude.paceBudget -eq 2) '9737 AC1 claude fullUse / default burn'
          # Refresh the forecast and status clock together at the then boundary.
          $savedNow = $now; $savedText = $nowText
          try {
            $now = [DateTimeOffset]::Parse('2026-10-21T13:35:29Z'); $nowText = Format-Instant $now
            Set-PaceForecast
            $thenCase = New-Case '9737-then' (New-Status @((New-ClaudeAccount 'claude-a' 'available' 2 3 22 87 0 1)))
            $r = (Invoke-Pacing $thenCase).data
            Assert-Pacing ($r.providers.claude.targetUnitsPerHour -eq 0.01786 -and $r.providers.claude.paceBudget -eq 1) '9737 AC1 then applies at from'
            $after = (Invoke-Pacing $thenCase @{NowUtc=(Format-Instant $now.AddSeconds(1))}).data
            Assert-Pacing ($after.providers.claude.targetUnitsPerHour -eq 0.01786) '9737 AC1 then applies after from'
          } finally { $now = $savedNow; $nowText = $savedText }
          Set-PaceForecast { param($f) $f.providers.codex.pace.steps += @{credits=7;reachable=$false;unitsPerHour=$null} }
          Assert-Pacing ((Invoke-Pacing $paceCase).data.providers.codex.targetUnitsPerHour -eq 0.03101) '9737 AC1 unreachable tail is not the target'
          Set-PaceForecast {param($f) $f.providers.codex.pace.steps[-1].unitsPerHour=0.0225}
          Assert-Pacing ((Invoke-Pacing $paceCase).data.providers.codex.paceBudget -eq 3) '9737 AC1 half lane rounds up'
        }
        'AC2' {
          $r = (Invoke-Pacing $paceCase).data
          Assert-Pacing ($r.providers.codex.laneBudget -eq 2 -and $r.providers.codex.newLaneAllowance -eq 2) "9737 AC2 headroom 1 pace 3 live 0 capped at 2 (status=$($r.status) reason=$($r.providers.codex.reason) budget=$($r.providers.codex.laneBudget) allowance=$($r.providers.codex.newLaneAllowance))"
          $r = (Invoke-Pacing $paceTwo).data
          Assert-Pacing ($r.providers.codex.laneBudget -eq 3 -and $r.providers.codex.newLaneAllowance -eq 1) '9737 AC2 live 2 allows budget 3'
          Assert-Pacing ($r.providers.claude.fableLaneBudget -eq $r.providers.claude.fableLaneBudgetUncapped) '9737 AC2 Fable reports only its own window capacity'
          $highHeadroom = New-Case '9737-headroom-preserved' (New-Status @((New-ClaudeAccount 'claude-a' 'available' 22 5 10 87 0 1)))
          Assert-Pacing ((Invoke-Pacing $highHeadroom).data.providers.claude.laneBudget -eq 9) '9737 AC2 pace never lowers the headroom budget'
          $empty = New-Case '9737-no-account' (New-Status @())
          $r = (Invoke-Pacing $empty).data
          foreach ($provider in @('codex','claude')) { Assert-Pacing ($r.providers.$provider.reason -ceq 'NO_AVAILABLE_ACCOUNT' -and $r.providers.$provider.laneBudget -eq 0 -and $r.providers.$provider.newLaneAllowance -eq 0) "9737 AC2 $provider no available account" }
          Assert-AllZero (Invoke-Pacing (New-Case '9737-unknown' $null)).data '9737 AC2 unknown with valid pace'
          $badCensus = New-Case '9737-census-unknown' (Get-Content -Raw -LiteralPath $paceCase.status | ConvertFrom-Json -DateKind String) @() 'partial'
          $r = (Invoke-Pacing $badCensus).data
          Assert-Pacing ($r.providers.codex.newLaneAllowance -eq 0 -and $r.providers.claude.fableLaneBudget -eq 0) '9737 AC2 unknown census never authorizes'
        }
        'AC3' {
          foreach ($pair in @(
            @('no-lapsing-credits',{param($f) foreach($p in 'codex','claude'){$f.providers[$p].pace.atDemand.creditsLapsing=0}}),
            @('absent',{param($f) foreach($p in 'codex','claude'){$f.providers[$p].Remove('pace')}}),
            @('stale',{param($f) foreach($p in 'codex','claude'){$f.providers[$p].pace.computedAt=Format-Instant $now.AddMinutes(-15).AddMilliseconds(-1)}}),
            @('invalid',{param($f) foreach($p in 'codex','claude'){$f.providers[$p].pace.steps[0].unitsPerHour='bad'}}),
            @('invalid',{param($f) $f.mode='shadow'}),
            @('stale',{param($f) $f.staleAfter=Format-Instant $now.AddSeconds(-1);$f.generatedAt=Format-Instant $now.AddMinutes(-10)}),
            @('invalid',{param($f) foreach($p in 'codex','claude'){$f.providers[$p].pace.computedAt=Format-Instant $now.AddSeconds(1)}}),
            @('invalid',{param($f) foreach($p in 'codex','claude'){$f.providers[$p].pace.atDemand.creditsLapsing=-1}}),
            @('invalid',{param($f) foreach($p in 'codex','claude'){$f.providers[$p].pace.steps[0].reachable='true'}}),
            @('invalid',{param($f) foreach($p in 'codex','claude'){$f.providers[$p].pace.atDemand.usedUnits=$true}}),
            @('invalid',{param($f) foreach($p in 'codex','claude'){$f.providers[$p].pace.fullUse=@{unitsPerHour='bad'}}}),
            @('invalid',{param($f) foreach($p in 'codex','claude'){$f.providers[$p].pace.then=@{from='bad';unitsPerHour=0.1}}}))) {
            Set-PaceForecast $pair[1]
            Assert-NoPaceRaise $paceCase $pair[0]
          }
          Set-PaceForecast {param($f) foreach($p in 'codex','claude'){$f.providers[$p].pace.computedAt=Format-Instant $now.AddMinutes(-15)}}
          Assert-Pacing ((Invoke-Pacing $paceCase).data.providers.codex.paceSource -ceq 'pace') '9737 AC3 exactly 15 minutes remains valid'
        }
        'AC4' {
          $first = Invoke-Pacing $paceCase; $second = Invoke-Pacing $paceCase
          Assert-Pacing ($first.raw -ceq $second.raw -and $first.data.format -ceq 'capacity-pacing/v1') '9737 AC4 byte-identical replay'
          foreach ($provider in @('codex','claude')) {
            $p = $first.data.providers.$provider
            foreach ($field in @('paceSource','targetUnitsPerHour','paceBudget','creditsLapsing','nextCreditExpiry')) { Assert-Pacing ($null -ne $p.PSObject.Properties[$field]) "9737 AC4 $provider output field $field" }
            Assert-Pacing ($p.paceSource -ceq 'pace' -and $p.creditsLapsing -eq $(if($provider -ceq 'codex'){3}else{1}) -and $p.nextCreditExpiry -ceq $(if($provider -ceq 'codex'){'2026-10-22T20:45:49Z'}else{'2026-10-22T16:00:00Z'})) "9737 AC4 $provider diagnostics"
          }
        }
      }
      Write-Output "PASS 9737 $ac"
    } catch { $paceFailures += $_.Exception.Message; Write-Output "FAIL 9737 ${ac}: $($_.Exception.Message)" }
  }
  if ($paceFailures.Count -eq 0) {
    Set-PaceForecast
    Assert-Mutant '9737-AC1-last-step-ignored' '$lastReachable = [double]$rate' 'if ($null -eq $lastReachable) { $lastReachable = [double]$rate }' {
      param($Mutant)
      Assert-Pacing ((Invoke-Pacing $paceCase @{} $Mutant).data.providers.codex.targetUnitsPerHour -eq 0.03101) '9737 AC1 last reachable step'
    }
    Assert-Mutant '9737-AC1-fullUse-ignored' '[double]$fullUse.unitsPerHour } else { $lastReachable }' '0.01 } else { $lastReachable }' {
      param($Mutant)
      Assert-Pacing ((Invoke-Pacing $paceCase @{} $Mutant).data.providers.claude.targetUnitsPerHour -eq 0.0346) '9737 AC1 fullUse selected'
    }
    Set-PaceForecast {param($f) $f.providers.codex.pace.steps[-1].unitsPerHour=0.0225}
    Assert-Mutant '9737-AC1-pace-floor' '[Math]::Floor($target / $Burn + 0.5)' '[Math]::Floor($target / $Burn)' {
      param($Mutant)
      Assert-Pacing ((Invoke-Pacing $paceCase @{} $Mutant).data.providers.codex.paceBudget -eq 3) '9737 AC1 half lane rounds up'
    }
    Set-PaceForecast
    Assert-Mutant '9737-AC2-step-cap-omitted' '[Math]::Min($pace.paceBudget, $liveLanes + 2)' '$pace.paceBudget' {
      param($Mutant)
      Assert-Pacing ((Invoke-Pacing $paceCase @{} $Mutant).data.providers.codex.laneBudget -eq 2) '9737 AC2 two-lane cap'
    }
    Assert-Mutant '9737-AC2-raise-omitted' "`$overall -ceq 'ok' -and `$available -gt 0 -and `$pace.paceSource -ceq 'pace'" '$false' {
      param($Mutant)
      Assert-Pacing ((Invoke-Pacing $paceTwo @{} $Mutant).data.providers.codex.laneBudget -eq 3) '9737 AC2 pace raise'
    }
    Assert-Mutant '9737-AC2-no-account-authorizes' '$available -gt 0 -and $pace.paceSource' '$pace.paceSource' {
      param($Mutant)
      Assert-Pacing ((Invoke-Pacing $empty @{} $Mutant).data.providers.codex.laneBudget -eq 0) '9737 AC2 no account never raises'
    }
    Assert-Mutant '9737-AC4-fields-omitted' 'paceSource=$pace.paceSource;targetUnitsPerHour=$pace.targetUnitsPerHour;paceBudget=$pace.paceBudget' 'targetUnitsPerHour=$pace.targetUnitsPerHour;paceBudget=$pace.paceBudget' {
      param($Mutant)
      Assert-Pacing ($null -ne (Invoke-Pacing $paceCase @{} $Mutant).data.providers.codex.PSObject.Properties['paceSource']) '9737 AC4 additive fields'
    }
    Assert-Mutant '9737-AC4-replay-nondeterministic' 'nowUtc=(Format-PacingInstant $now)' 'nowUtc=([guid]::NewGuid().ToString())' {
      param($Mutant)
      Assert-Pacing ((Invoke-Pacing $paceCase @{} $Mutant).raw -ceq (Invoke-Pacing $paceCase @{} $Mutant).raw) '9737 AC4 replay'
    }
    Set-PaceForecast {param($f) foreach($p in 'codex','claude'){$f.providers[$p].pace.atDemand.creditsLapsing=0}}
    Assert-Mutant '9737-AC3-zero-lapses-raises' "if (`$entry.creditsLapsing -eq 0) { `$entry.paceSource='no-lapsing-credits'; return `$entry }" '' {
      param($Mutant)
      Assert-Pacing ($null -eq (Invoke-Pacing $paceCase @{} $Mutant).data.providers.codex.targetUnitsPerHour) '9737 AC3 no lapses no target'
    }
    Set-PaceForecast {param($f) foreach($p in 'codex','claude'){$f.providers[$p].pace.computedAt=Format-Instant $now.AddMinutes(-16)}}
    Assert-Mutant '9737-AC3-stale-raises' "if ((`$Now - `$computed).TotalMinutes -gt 15) { `$entry.paceSource='stale'; return `$entry }" '' {
      param($Mutant)
      Assert-Pacing ($null -eq (Invoke-Pacing $paceCase @{} $Mutant).data.providers.codex.targetUnitsPerHour) '9737 AC3 stale pace no target'
    }
    Set-PaceForecast {param($f) foreach($p in 'codex','claude'){$f.providers[$p].pace.steps[0].unitsPerHour='0.1'}}
    Assert-Mutant '9737-AC3-step-number-unchecked' 'if (-not (Test-PacingFiniteNumber $rate) -or [double]$rate -lt 0) { return $entry }' 'if ($false) { return $entry }' {
      param($Mutant)
      Assert-Pacing ($null -eq (Invoke-Pacing $paceCase @{} $Mutant).data.providers.codex.targetUnitsPerHour) '9737 AC3 numeric strings rejected'
    }
    Set-PaceForecast {param($f) $f.mode='shadow'}
    Assert-Mutant '9737-AC3-shadow-raises' "if (`$Forecast.status -cne 'in-force') { return `$entry }" "if (`$Forecast.status -cnotin @('in-force','shadow')) { return `$entry }" {
      param($Mutant)
      Assert-Pacing ($null -eq (Invoke-Pacing $paceCase @{} $Mutant).data.providers.codex.targetUnitsPerHour) '9737 AC3 shadow no target'
    }
    $now = [DateTimeOffset]::Parse('2026-10-21T13:35:29Z'); $nowText = Format-Instant $now
    Set-PaceForecast
    Assert-Mutant '9737-AC1-then-ignored' 'if ($null -ne $then -and $Now -ge $thenFrom)' 'if ($false)' {
      param($Mutant)
      Assert-Pacing ((Invoke-Pacing $thenCase @{} $Mutant).data.providers.claude.targetUnitsPerHour -eq 0.01786) '9737 AC1 then selected'
    }
    Write-Output 'PASS 9737 AC1-AC4 mutants=13 survivors=0'
  }
  $now = $legacyNow; $nowText = $legacyNowText
  Write-Json (Join-Path $fixture.stateRoot 'model-registry.json') $fixture.registry
  if ($paceFailures.Count -gt 0) { throw "9737 failing controls: $($paceFailures.Count)" }

  # --- AC1: lane budget rounding, binding window, Fable capacity ----------------------
  Clear-Forecast
  $case87 = New-Case 'ac1-87h' $claude87
  $r = (Invoke-Pacing $case87).data
  Assert-Pacing ($r.format -ceq 'capacity-pacing/v1' -and $r.nowUtc -ceq $nowText -and $r.status -ceq 'ok') 'AC1 envelope'
  Assert-Pacing ($r.config.reserve -eq 0.1 -and $r.config.defaultBurnPerLaneHour.claude -eq 0.015 -and $r.config.defaultBurnPerLaneHour.codex -eq 0.009 -and $r.config.minLaneHours -eq 24 -and $r.config.windowHours -eq 168) 'AC1 config echoed'
  $claude = $r.providers.claude
  Assert-Pacing ($claude.burnPerLaneHour -eq 0.015 -and $claude.burnSource -ceq 'default' -and $claude.burnReason -ceq 'FORECAST_ABSENT') 'AC1 default burn without a forecast'
  $a = @($claude.accounts | Where-Object account -ceq 'claude-a')[0]
  Assert-Pacing ($a.contributes -and $a.windowId -ceq 'limit:1' -and $a.used -eq 22) 'AC1 binding window is the highest-used common window'
  Assert-Near $a.hours 87 'AC1 hours to reset from millisecond resetAt'
  Assert-Near $a.headroom 0.78 'AC1 headroom'
  Assert-Near $a.lanes (0.68 / (0.015 * 87)) 'AC1 account lanes'
  Assert-Pacing ($claude.laneBudget -eq 1) 'AC1 floor(0.68/(0.015*87)+0.5) = 1'
  Assert-Pacing ($claude.newLaneAllowance -eq 1 -and $claude.liveLanes -eq 0 -and $null -eq $claude.reason) 'AC1 allowance with no live lanes'
  foreach ($id in @('claude-b', 'claude-c')) {
    $x = @($claude.accounts | Where-Object account -ceq $id)[0]
    Assert-Pacing (-not $x.contributes -and $x.reason -ceq 'ACCOUNT_EXHAUSTED' -and $x.lanes -eq 0) "AC1 exhausted $id contributes 0"
  }
  Assert-Pacing ($claude.availableAccounts -eq 1 -and $claude.fableLaneBudget -eq 0) 'AC1 one available account; Fable 0.63/(0.015*87) rounds to 0'
  Assert-Pacing ($r.providers.codex.newLaneAllowance -eq 0 -and $r.providers.codex.reason -ceq 'NO_AVAILABLE_ACCOUNT' -and $null -eq $r.providers.codex.fableLaneBudget) 'AC1 provider without accounts'

  $case5 = New-Case 'ac1-5h' $claude5
  $r = (Invoke-Pacing $case5).data
  $claude = $r.providers.claude
  $a = @($claude.accounts | Where-Object account -ceq 'claude-a')[0]
  Assert-Pacing ($a.windowId -ceq 'limit:0' -and $a.used -eq 22) 'AC1 5-hour window binds when it is the highest used'
  Assert-Near $a.hours 5 'AC1 five hours to reset'
  Assert-Pacing ($claude.laneBudget -eq 9) 'AC1 floor(0.68/0.075+0.5) = 9'
  $fable = @($claude.fableAccounts | Where-Object account -ceq 'claude-a')[0]
  Assert-Pacing ($fable.windowId -ceq 'limit:2' -and $fable.used -eq 40) 'AC1 Fable window is the Fable-scoped window'
  Assert-Near $fable.hours 7 'AC1 Fable hours'
  Assert-Pacing ($claude.fableLaneBudgetUncapped -eq 5) 'AC1 Fable floor(0.50/0.105+0.5) = 5'
  Assert-Pacing ($claude.fableLaneBudget -eq 5) 'AC1 Fable window capacity 5 is not capped by Claude share'
  $caseLapsed = New-Case 'ac1-lapsed' (New-Status @((New-ClaudeAccount 'claude-a' 'available' 22 -1 10 87 40 7)))
  $r = (Invoke-Pacing $caseLapsed).data
  $a = @($r.providers.claude.accounts | Where-Object account -ceq 'claude-a')[0]
  Assert-Pacing ($a.windowId -ceq 'limit:0' -and $a.hours -eq 1 -and $r.providers.claude.laneBudget -eq 45) 'AC1 a reset in the past floors hours at 1'

  # --- AC2: allowance = budget - live lanes mapped through the registry ----------
  $caseCensus = New-Case 'ac2-census' $mixed @((New-Lane 'fable'), (New-Lane 'opus'), (New-Lane 'sol'))
  $r = (Invoke-Pacing $caseCensus).data
  Assert-Pacing ($r.providers.claude.laneBudget -eq 9 -and $r.providers.claude.liveLanes -eq 2 -and $r.providers.claude.newLaneAllowance -eq 7) 'AC2 claude allowance 9-2'
  $codex = $r.providers.codex
  Assert-Near (@($codex.accounts | Where-Object account -ceq 'codex-x')[0].lanes) (0.88 / (0.009 * 160)) 'AC2 codex-x lanes'
  Assert-Near (@($codex.accounts | Where-Object account -ceq 'codex-y')[0].lanes) (0.80 / (0.009 * 150)) 'AC2 codex-y lanes'
  Assert-Pacing ($codex.laneBudget -eq 1 -and $codex.liveLanes -eq 1 -and $codex.newLaneAllowance -eq 0 -and $null -eq $codex.reason) 'AC2 codex allowance floors at 0 with 1-1'
  Assert-Pacing ($r.providers.claude.fableLaneBudget -eq 5) 'AC2 Fable budget is independent of live lanes'
  $caseOver = New-Case 'ac2-over' $mixed @(1..12 | ForEach-Object { New-Lane 'opus' })
  $r = (Invoke-Pacing $caseOver).data
  Assert-Pacing ($r.providers.claude.liveLanes -eq 12 -and $r.providers.claude.newLaneAllowance -eq 0 -and $r.providers.codex.newLaneAllowance -eq 1) 'AC2 allowance floors at 0 over budget; idle codex gets 1'
  $caseSlot = New-Case 'ac2-slot' $mixed @((New-Lane 'legacy-family' 'claude.primary'))
  $r = (Invoke-Pacing $caseSlot).data
  Assert-Pacing ($r.status -ceq 'ok' -and $r.providers.claude.liveLanes -eq 1) 'AC2 unmapped family falls back to the slot provider'
  $caseUnmapped = New-Case 'ac2-unmapped' $mixed @((New-Lane 'legacy-family'))
  $r = (Invoke-Pacing $caseUnmapped).data
  Assert-Pacing ($r.status -ceq 'unknown' -and $r.censusStatus -ceq 'unknown' -and $r.censusReason -ceq 'CENSUS_FAMILY_UNMAPPED' -and $r.providers.claude.newLaneAllowance -eq 0 -and $r.providers.codex.newLaneAllowance -eq 0 -and $r.providers.claude.reason -ceq 'CENSUS_UNKNOWN') 'AC2 unmappable lane never authorizes'
  $caseAll = New-Case 'ac2-exhausted' (New-Status @($exhaustedB, $exhaustedC, (New-CodexAccount 'codex-x' 'exhausted' 100 20)))
  $r = (Invoke-Pacing $caseAll).data
  foreach ($provider in @('claude', 'codex')) {
    $p = $r.providers.$provider
    Assert-Pacing ($p.laneBudget -eq 0 -and $p.newLaneAllowance -eq 0 -and $p.availableAccounts -eq 0 -and $p.reason -ceq 'NO_AVAILABLE_ACCOUNT') "AC2 all-exhausted $provider"
  }
  Assert-Pacing ($r.status -ceq 'ok') 'AC2 all-exhausted is a known state, not unknown'
  # An exhausted verdict overrides the percentages: an exhausted account whose
  # windows still show headroom must contribute 0, never be summed.
  $exhaustedPartial = New-ClaudeAccount 'claude-p' 'exhausted' 50 5 30 87 0 87
  $casePartialExhausted = New-Case 'ac2-exhausted-partial' (New-Status @((New-ClaudeAccount 'claude-a' 'available' 22 5 10 87 40 7), $exhaustedPartial))
  $r = (Invoke-Pacing $casePartialExhausted).data
  $x = @($r.providers.claude.accounts | Where-Object account -ceq 'claude-p')[0]
  Assert-Pacing (-not $x.contributes -and $x.reason -ceq 'ACCOUNT_EXHAUSTED' -and $r.providers.claude.laneBudget -eq 9 -and $r.providers.claude.availableAccounts -eq 1) 'AC2 exhausted account with visible headroom is not summed'
  $disabled =New-ClaudeAccount 'claude-d' 'available' 0 $null 0 100 0 100 $true
  $stale = New-ClaudeAccount 'claude-s' 'available' 0 $null 0 100 0 100 $false $true
  $unknown = New-ClaudeAccount 'claude-u' 'unknown' 0 $null 0 100 0 100
  $noReset = New-ClaudeAccount 'claude-r' 'available' 5 $null 5 $null 0 $null
  $caseAccounts = New-Case 'ac2-accounts' (New-Status @($disabled, $stale, $unknown, $noReset))
  $r = (Invoke-Pacing $caseAccounts).data
  foreach ($pair in @(@('claude-d', 'ACCOUNT_DISABLED'), @('claude-s', 'ACCOUNT_STALE'), @('claude-u', 'ACCOUNT_UNKNOWN'), @('claude-r', 'RESET_UNKNOWN'))) {
    $x = @($r.providers.claude.accounts | Where-Object account -ceq $pair[0])[0]
    Assert-Pacing (-not $x.contributes -and $x.reason -ceq $pair[1] -and $x.lanes -eq 0) "AC2 $($pair[0]) is $($pair[1])"
  }
  Assert-Pacing ($r.providers.claude.laneBudget -eq 0 -and $r.providers.claude.reason -ceq 'NO_AVAILABLE_ACCOUNT') 'AC2 disabled, stale, unknown and reset-less accounts contribute 0'
  $tie = New-ClaudeAccount 'claude-t' 'available' 0 $null 0 100 0 100
  $caseTie = New-Case 'ac2-tie' (New-Status @($tie))
  $r = (Invoke-Pacing $caseTie).data
  $x = @($r.providers.claude.accounts | Where-Object account -ceq 'claude-t')[0]
  Assert-Pacing ($x.contributes -and $x.windowId -ceq 'limit:1' -and $x.hours -eq 100) 'AC2 an equal-used tie binds the latest known reset'
  Assert-Near $x.lanes (0.9 / (0.015 * 100)) 'AC2 fresh account lanes'

  # --- AC3: burn measured from the dispatch log and transcripts -------------------
  Set-Forecast 0.01 0.02
  $caseBurn = New-Case 'ac3-burn' $claude5
  Add-DispatchRow $caseBurn 'fable' 30 't1' 2          # 28 h inside the window
  Add-DispatchRow $caseBurn 'opus' 200 't2' 150        # started before the window: clipped to 18 h
  Add-DispatchRow $caseBurn 'opus' 10 't3' $null       # transcript missing: skipped
  Add-DispatchRow $caseBurn 'fable' 20 't1' $null      # relaunch row on the same transcript: not double counted
  Add-DispatchRow $caseBurn 'sol' 5 't4' 1             # 4 codex lane-hours: below the 24-hour minimum
  $r = (Invoke-Pacing $caseBurn).data
  $claude = $r.providers.claude
  Assert-Near $claude.laneHours 46 'AC3 claude lane-hours clipped to the 168-hour window'
  Assert-Pacing ($claude.burnSource -ceq 'measured' -and $null -eq $claude.burnReason) 'AC3 burn measured at 46 lane-hours'
  Assert-Near $claude.burnPerLaneHour (0.01 * 168 / 46) 'AC3 burn = demand.last168h*168 / lane-hours'
  Assert-Pacing ($claude.demandUnitsPerHour -eq 0.01 -and $r.forecastStatus -ceq 'in-force') 'AC3 demand recorded'
  Assert-Pacing ($r.laneHours.transcriptsMissing -eq 1 -and $r.laneHours.duplicates -eq 1 -and $r.laneHours.counted -eq 3 -and $r.laneHours.rows -eq 5) 'AC3 missing transcript skipped and relaunch deduplicated'
  Assert-Pacing ($claude.laneBudget -eq 4) 'AC3 measured burn flows into the budget: floor(0.68/(0.036522*5)+0.5) = 4'
  $codex = $r.providers.codex
  Assert-Near $codex.laneHours 4 'AC3 codex lane-hours'
  Assert-Pacing ($codex.burnSource -ceq 'default' -and $codex.burnReason -ceq 'LANE_HOURS_BELOW_MINIMUM' -and $codex.burnPerLaneHour -eq 0.009) 'AC3 below 24 lane-hours uses the default'
  Set-Forecast 0.01 0.02 20 14
  $r = (Invoke-Pacing $caseBurn).data
  Assert-Pacing ($r.forecastStatus -ceq 'stale' -and $r.providers.claude.burnSource -ceq 'default' -and $r.providers.claude.burnReason -ceq 'FORECAST_STALE' -and $r.providers.claude.burnPerLaneHour -eq 0.015) 'AC3 stale forecast uses the default'
  Assert-Pacing ($r.status -ceq 'ok' -and $r.providers.claude.laneBudget -eq 9) 'AC3 a stale forecast never makes status unknown'
  [IO.File]::WriteAllText($forecastPath, '{"format":"capacity-forecast/v1"', $utf8)
  $r = (Invoke-Pacing $caseBurn).data
  Assert-Pacing ($r.forecastStatus -ceq 'malformed' -and $r.providers.claude.burnReason -ceq 'FORECAST_MALFORMED') 'AC3 malformed forecast uses the default'
  Set-Forecast 0 0.02
  $r = (Invoke-Pacing $caseBurn).data
  Assert-Pacing ($r.providers.claude.burnSource -ceq 'default' -and $r.providers.claude.burnReason -ceq 'BURN_NONPOSITIVE') 'AC3 zero demand never divides by zero'
  Set-Forecast 0.01 0.02
  $caseNoLog = New-Case 'ac3-nolog' $claude5
  [IO.File]::Delete($caseNoLog.log)
  $r = (Invoke-Pacing $caseNoLog).data
  Assert-Pacing ($r.laneHours.status -ceq 'unknown' -and $r.laneHours.reason -ceq 'DISPATCH_LOG_MISSING' -and $r.providers.claude.burnReason -ceq 'LANE_HOURS_BELOW_MINIMUM' -and $r.status -ceq 'ok') 'AC3 missing dispatch log uses the default'

  # --- AC4: unknown status never authorizes; replay is byte-identical -------------
  $caseMissing = New-Case 'ac4-missing' $null
  $r = (Invoke-Pacing $caseMissing).data
  Assert-Pacing ($r.statusSource -ceq 'fixture' -and $r.statusReason -ceq 'STATUS_UNREACHABLE' -and @($r.reasons) -ccontains 'STATUS_UNREACHABLE') 'AC4 missing status fixture is unreachable'
  Assert-AllZero $r 'AC4 unreachable fixture'
  Assert-Pacing ($r.providers.claude.reason -ceq 'STATUS_UNKNOWN' -and $r.providers.codex.reason -ceq 'STATUS_UNKNOWN' -and @($r.providers.claude.accounts).Count -eq 0) 'AC4 unknown provider reason'
  $r = (Invoke-Pacing $caseMissing @{StatusPath=$null;StatusUrl='http://127.0.0.1:1/api/status'}).data
  Assert-Pacing ($r.statusSource -ceq 'live' -and $r.statusReason -ceq 'STATUS_UNREACHABLE') 'AC4 unreachable live endpoint'
  Assert-AllZero $r 'AC4 unreachable live'
  $malformed = @(
    @('not-json', 'not json'),
    @('accounts-string', '{"accounts":"nope","checkedAt":"' + (Format-Instant $now) + '","error":null}'),
    @('error-set', (New-Status @() | ConvertTo-Json -Depth 10).Replace('"error": null', '"error": "status unavailable"')),
    @('account-no-disabled', (New-Status @([ordered]@{id='x';provider='claude';status='available';quotaWindows=@()}) | ConvertTo-Json -Depth 10)),
    @('window-not-object', (New-Status @([ordered]@{id='x';provider='claude';disabled=$false;status='available';quotaWindows=@('limit:1')}) | ConvertTo-Json -Depth 10)),
    @('no-checked-at', '{"accounts":[],"error":null}'))
  foreach ($pair in $malformed) {
    $c = New-Case "ac4-$($pair[0])" $null
    [IO.File]::WriteAllText($c.status, $pair[1], $utf8)
    $r = (Invoke-Pacing $c).data
    Assert-Pacing ($r.statusReason -ceq 'STATUS_MALFORMED') "AC4 $($pair[0]) is malformed"
    Assert-AllZero $r "AC4 $($pair[0])"
  }

  # --- AC4 F1: every consumed window field is validated, never skipped or clamped
  # The 5-hour window binds, so a defect on the nonbinding weekly window is one
  # the budget would otherwise skip silently. Codex is healthy in every case.
  $f1Cases = @{}
  foreach ($pair in @(
      @('weekly-used-string', { $a = New-Claude5; $a.quotaWindows[1].used = 'synthetic-invalid-number'; @($a) }),
      @('weekly-used-missing', { $a = New-Claude5; $a.quotaWindows[1].Remove('used'); @($a) }),
      @('weekly-used-bool', { $a = New-Claude5; $a.quotaWindows[1].used = $true; @($a) }),
      @('weekly-used-over-100', { $a = New-Claude5; $a.quotaWindows[1].used = 100.5; @($a) }),
      @('binding-used-negative', { $a = New-Claude5; $a.quotaWindows[0].used = -90; @($a) }),
      @('weekly-common-string', { $a = New-Claude5; $a.quotaWindows[1].common = 'synthetic-invalid-boolean'; @($a) }),
      @('weekly-common-missing', { $a = New-Claude5; $a.quotaWindows[1].Remove('common'); @($a) }),
      @('fable-scope-number', { $a = New-Claude5; $a.quotaWindows[2].scope = 7; @($a) }),
      @('weekly-scope-missing', { $a = New-Claude5; $a.quotaWindows[1].Remove('scope'); @($a) }),
      @('weekly-reset-string', { $a = New-Claude5; $a.quotaWindows[1].resetAt = 'synthetic-invalid-instant'; @($a) }),
      @('weekly-reset-missing', { $a = New-Claude5; $a.quotaWindows[1].Remove('resetAt'); @($a) }),
      @('weekly-reset-negative', { $a = New-Claude5; $a.quotaWindows[1].resetAt = -1; @($a) }),
      @('weekly-reset-bool', { $a = New-Claude5; $a.quotaWindows[1].resetAt = $false; @($a) }),
      @('available-windows-missing', { $a = New-Claude5; $a.Remove('quotaWindows'); @($a) }),
      @('available-windows-null', { $a = New-Claude5; $a.quotaWindows = $null; @($a) }),
      @('stale-windows-missing', { $s = New-ClaudeAccount 'claude-s' 'available' 0 $null 0 100 0 100 $false $true; $s.Remove('quotaWindows'); @((New-Claude5), $s) }),
      @('exhausted-used-string', { $b = New-ClaudeAccount 'claude-b' 'exhausted' 0 $null 100 50 10 50; $b.quotaWindows[1].used = 'synthetic-invalid-number'; @((New-Claude5), $b) }))) {
    $c = New-Case "ac4-f1-$($pair[0])" (New-StatusWith @(& $pair[1]))
    $f1Cases[$pair[0]] = $c
    $r = (Invoke-Pacing $c).data
    Assert-Pacing ($r.statusReason -ceq 'STATUS_MALFORMED' -and @($r.reasons) -ccontains 'STATUS_MALFORMED') "AC4 F1 $($pair[0]) is malformed"
    Assert-AllZero $r "AC4 F1 $($pair[0])"
    Assert-Pacing ($r.providers.codex.reason -ceq 'STATUS_UNKNOWN' -and $r.providers.codex.availableAccounts -eq 0) "AC4 F1 $($pair[0]) zeroes the healthy codex provider"
  }
  $codexBad = New-CodexAccount 'codex-x' 'available' 2 160; $codexBad.quotaWindows[0].used = 'synthetic-invalid-number'
  $r = (Invoke-Pacing (New-Case 'ac4-f1-codex-used-string' (New-Status @((New-Claude5), $codexBad)))).data
  Assert-Pacing ($r.statusReason -ceq 'STATUS_MALFORMED' -and $r.providers.claude.reason -ceq 'STATUS_UNKNOWN') 'AC4 F1 a malformed codex window zeroes the healthy claude provider'
  Assert-AllZero $r 'AC4 F1 malformed codex window'
  # Controls: a null reset is legitimately unknown; an account that cannot
  # contribute may omit its windows; 0 and 100 are valid percentages.
  $a = New-Claude5; $a.quotaWindows[1].resetAt = $null
  $r = (Invoke-Pacing (New-Case 'ac4-f1-weekly-reset-null' (New-StatusWith @($a)))).data
  Assert-Pacing ($r.status -ceq 'ok' -and $r.providers.claude.laneBudget -eq 9 -and $r.providers.claude.fableLaneBudget -eq 5 -and $r.providers.codex.newLaneAllowance -eq 1) 'AC4 F1 a null reset on the nonbinding window is valid'
  $a = New-Claude5; $a.quotaWindows[0].resetAt = $null
  $r = (Invoke-Pacing (New-Case 'ac4-f1-binding-reset-null' (New-StatusWith @($a)))).data
  $x = @($r.providers.claude.accounts | Where-Object account -ceq 'claude-a')[0]
  Assert-Pacing ($r.status -ceq 'ok' -and -not $x.contributes -and $x.reason -ceq 'RESET_UNKNOWN' -and $r.providers.claude.laneBudget -eq 0 -and $r.providers.claude.reason -ceq 'NO_AVAILABLE_ACCOUNT' -and $r.providers.codex.newLaneAllowance -eq 1) 'AC4 F1 a null reset on the binding window stays RESET_UNKNOWN, not malformed'
  $b = New-ClaudeAccount 'claude-b' 'exhausted' 0 $null 100 50 10 50; $b.Remove('quotaWindows')
  $d = New-ClaudeAccount 'claude-d' 'available' 0 $null 0 100 0 100 $true; $d.quotaWindows = $null
  $r = (Invoke-Pacing (New-Case 'ac4-f1-noncontributing-no-windows' (New-StatusWith @((New-Claude5), $b, $d)))).data
  Assert-Pacing ($r.status -ceq 'ok' -and $r.providers.claude.laneBudget -eq 9 -and $r.providers.claude.availableAccounts -eq 1) 'AC4 F1 exhausted and disabled accounts may omit their windows'
  foreach ($pair in @(@('claude-b', 'ACCOUNT_EXHAUSTED'), @('claude-d', 'ACCOUNT_DISABLED'))) {
    $x = @($r.providers.claude.accounts | Where-Object account -ceq $pair[0])[0]
    Assert-Pacing (-not $x.contributes -and $x.reason -ceq $pair[1] -and $x.lanes -eq 0) "AC4 F1 $($pair[0]) without windows is $($pair[1])"
  }
  $a = New-Claude5; $a.quotaWindows[0].used = 100; $a.quotaWindows[1].used = 0
  $r = (Invoke-Pacing (New-Case 'ac4-f1-used-bounds' (New-StatusWith @($a)))).data
  $x = @($r.providers.claude.accounts | Where-Object account -ceq 'claude-a')[0]
  Assert-Pacing ($r.status -ceq 'ok' -and $x.contributes -and $x.used -eq 100 -and $x.headroom -eq 0 -and $x.lanes -eq 0 -and $r.providers.claude.laneBudget -eq 0) 'AC4 F1 used 0 and 100 are valid bounds; a fully used window yields 0 lanes'

  # --- AC4 F2: account identity is required and unique per (provider, id) ----
  $f2Cases = @{}
  foreach ($pair in @(
      @('duplicate-exact', { $a = New-Claude5; @($a, $a) }),
      @('duplicate-conflicting', { @((New-Claude5), (New-ClaudeAccount 'claude-a' 'available' 50 5 90 87 0 7)) }),
      @('duplicate-across-states', { @((New-Claude5), (New-ClaudeAccount 'claude-a' 'exhausted' 0 $null 100 50 10 50)) }),
      @('duplicate-name-fallback', { @((New-Named 'claude-n'), (New-Named 'claude-n')) }),
      @('identity-missing', { $a = New-Claude5; $a.Remove('id'); @($a) }),
      @('identity-id-number', { $a = New-Claude5; $a.id = 42; $a.name = 'claude-n'; @($a) }),
      @('identity-id-null', { $a = New-Claude5; $a.id = $null; $a.name = 'claude-n'; @($a) }),
      @('identity-id-blank', { $a = New-Claude5; $a.id = ' '; @($a) }))) {
    $c = New-Case "ac4-f2-$($pair[0])" (New-StatusWith @(& $pair[1]))
    $f2Cases[$pair[0]] = $c
    $r = (Invoke-Pacing $c).data
    Assert-Pacing ($r.statusReason -ceq 'STATUS_MALFORMED') "AC4 F2 $($pair[0]) is malformed"
    Assert-AllZero $r "AC4 F2 $($pair[0])"
    Assert-Pacing ($r.providers.codex.reason -ceq 'STATUS_UNKNOWN' -and $r.providers.codex.availableAccounts -eq 0) "AC4 F2 $($pair[0]) zeroes the healthy codex provider"
  }
  $r = (Invoke-Pacing (New-Case 'ac4-f2-duplicate-codex' (New-Status @((New-Claude5), (New-CodexAccount 'codex-x' 'available' 2 160), (New-CodexAccount 'codex-x' 'available' 2 160))))).data
  Assert-Pacing ($r.statusReason -ceq 'STATUS_MALFORMED' -and $r.providers.claude.reason -ceq 'STATUS_UNKNOWN') 'AC4 F2 a duplicate codex identity zeroes the healthy claude provider'
  Assert-AllZero $r 'AC4 F2 duplicate codex identity'
  # Positive controls: distinct accounts stay additive and are never deduplicated.
  $r = (Invoke-Pacing (New-Case 'ac4-f2-distinct' (New-StatusWith @((New-Claude5), (New-ClaudeAccount 'claude-a2' 'available' 22 5 10 87 40 7))))).data
  Assert-Pacing ($r.status -ceq 'ok' -and $r.providers.claude.availableAccounts -eq 2 -and $r.providers.claude.laneBudget -eq 18 -and $r.providers.claude.newLaneAllowance -eq 18 -and $r.providers.codex.newLaneAllowance -eq 1) 'AC4 F2 two distinct accounts are additive: 9+9 = 18'
  Assert-Pacing ($r.providers.claude.fableLaneBudgetUncapped -eq 10 -and $r.providers.claude.fableLaneBudget -eq 10) 'AC4 F2 two distinct accounts: Fable floor(9.52+0.5) = 10 without a share cap'
  $r = (Invoke-Pacing (New-Case 'ac4-f2-distinct-names' (New-StatusWith @((New-Named 'claude-n1'), (New-Named 'claude-n2'))))).data
  Assert-Pacing ($r.status -ceq 'ok' -and $r.providers.claude.laneBudget -eq 18 -and ((@($r.providers.claude.accounts | ForEach-Object account) -join ',') -ceq 'claude-n1,claude-n2')) 'AC4 F2 name is the identity only when no id is supplied'
  $r = (Invoke-Pacing (New-Case 'ac4-f2-cross-provider' (New-Status @((New-Claude5), (New-CodexAccount 'claude-a' 'available' 2 160))))).data
  Assert-Pacing ($r.status -ceq 'ok' -and $r.providers.claude.laneBudget -eq 9 -and $r.providers.codex.laneBudget -eq 1) 'AC4 F2 identity is (provider, id): the same id on another provider is distinct'

  $caseStale = New-Case 'ac4-stale' (New-Status @((New-ClaudeAccount 'claude-a' 'available' 22 5 10 87 40 7)) (Format-Instant $now.AddMinutes(-31)))
  $r = (Invoke-Pacing $caseStale).data
  Assert-Pacing ($r.statusReason -ceq 'STATUS_STALE') 'AC4 status older than 30 minutes is stale'
  Assert-AllZero $r 'AC4 stale'
  $caseFuture = New-Case 'ac4-future' (New-Status @((New-ClaudeAccount 'claude-a' 'available' 22 5 10 87 40 7)) (Format-Instant $now.AddMinutes(10)))
  $r = (Invoke-Pacing $caseFuture).data
  Assert-Pacing ($r.statusReason -ceq 'STATUS_STALE') 'AC4 status from the future is stale'
  Assert-AllZero $r 'AC4 future'
  $caseFresh = New-Case 'ac4-fresh' (New-Status @((New-ClaudeAccount 'claude-a' 'available' 22 5 10 87 40 7)) (Format-Instant $now.AddMinutes(-29)))
  $r = (Invoke-Pacing $caseFresh).data
  Assert-Pacing ($r.status -ceq 'ok' -and $r.providers.claude.laneBudget -eq 9) 'AC4 status within 30 minutes is fresh'
  $caseNoCensus = New-Case 'ac4-nocensus' $claude5
  [IO.File]::Delete($caseNoCensus.census)
  $r = (Invoke-Pacing $caseNoCensus).data
  Assert-Pacing ($r.status -ceq 'unknown' -and $r.censusStatus -ceq 'unknown' -and $r.censusReason.StartsWith('CENSUS_UNAVAILABLE') -and $r.providers.claude.newLaneAllowance -eq 0 -and $r.providers.codex.newLaneAllowance -eq 0 -and $r.providers.claude.fableLaneBudget -eq 0) 'AC4 missing census never authorizes'
  Assert-Pacing ($r.providers.claude.laneBudget -eq 9 -and $r.providers.claude.reason -ceq 'CENSUS_UNKNOWN') 'AC4 budget stays visible while the census is unknown'
  $casePartial = New-Case 'ac4-partial' $claude5 @() 'partial'
  $r = (Invoke-Pacing $casePartial).data
  Assert-Pacing ($r.censusReason -ceq 'CENSUS_UNHEALTHY' -and $r.providers.claude.newLaneAllowance -eq 0) 'AC4 partial census never authorizes'
  $first = Invoke-Pacing $caseBurn
  $second = Invoke-Pacing $caseBurn
  Assert-Pacing ([string]::Equals($first.raw, $second.raw, [StringComparison]::Ordinal) -and $first.raw.Length -gt 200) 'AC4 replay with the same inputs and -NowUtc is byte-identical'
  $outFile = Join-Path $caseBurn.dir 'out.json'
  [void](Invoke-Pacing $caseBurn @{OutFile=$outFile})
  $written = [IO.File]::ReadAllBytes($outFile)
  Assert-Pacing ($written.Length -gt 200 -and -not ($written[0] -eq 0xEF -and $written[1] -eq 0xBB) -and ([Text.Encoding]::UTF8.GetString($written)) -ceq ($first.raw.Replace("`r`n", "`n") + "`n")) 'AC4 -OutFile writes the same document, LF, without a BOM'
  $refused = $null
  try { [void](Invoke-Pacing $caseBurn @{NowUtc='2026-10-10 20:20'}) } catch { $refused = $_.Exception.Message }
  Assert-Pacing ($null -ne $refused -and $refused.Contains('PACING_INSTANT_INVALID')) 'AC4 a non-ISO -NowUtc is refused, never defaulted'

  # --- Mutants -------------------------------------------------------------------
  Assert-Mutant 'plain-floor' '[Math]::Floor($sum + 0.5)' '[Math]::Floor($sum)' {
    param($Mutant)
    Assert-Pacing ((Invoke-Pacing $case87 @{} $Mutant).data.providers.claude.laneBudget -eq 1) 'mutant plain floor keeps AC1 budget 1'
  }
  Assert-Mutant 'clip-ignored' '$start = if ($item.start -lt $windowStart) { $windowStart } else { $item.start }' '$start = $item.start' {
    param($Mutant)
    Assert-Near (Invoke-Pacing $caseBurn @{} $Mutant).data.providers.claude.burnPerLaneHour (0.01 * 168 / 46) 'mutant clip ignored keeps AC3 burn'
  }
  Assert-Mutant 'fable-share-cap-restored' 'else { $fableRounded }' 'else { [int][Math]::Min($fableRounded, [Math]::Floor($laneBudget / 2)) }' {
    param($Mutant)
    Assert-Pacing ((Invoke-Pacing $case5 @{} $Mutant).data.providers.claude.fableLaneBudget -eq 5) 'mutant share cap must not reduce Fable window capacity'
  }

  Assert-Mutant 'exhausted-summed' "if (`$status -ceq 'exhausted') { `$entry.reason = 'ACCOUNT_EXHAUSTED'; return `$result }" "if (`$status -ceq 'exhausted') { `$status = 'available' }" {
    param($Mutant)
    Assert-Pacing ((Invoke-Pacing $casePartialExhausted @{} $Mutant).data.providers.claude.laneBudget -eq 9) 'mutant exhausted summed keeps AC2 budget 9'
  }
  Assert-Mutant 'unknown-authorizes' "if (`$overall -cne 'ok') { 0 }" 'if ($false) { 0 }' {
    param($Mutant)
    Assert-Pacing ((Invoke-Pacing $caseNoCensus @{} $Mutant).data.providers.claude.newLaneAllowance -eq 0) 'mutant unknown authorizes keeps AC4 zero'
  }
  # F1/F2 deletion mutants: dropping any one field, identity or duplicate check
  # must let its malformed case back through as ok.
  function Assert-DeletionMutant([string]$Name, [string]$Check, $Case) {
    Assert-Mutant $Name $Check '' {
      param($Mutant)
      Assert-Pacing ((Invoke-Pacing $Case @{} $Mutant).data.status -ceq 'unknown') "mutant $Name keeps AC4 unknown"
    }.GetNewClosure()
  }
  Assert-DeletionMutant 'window-fields-optional' "foreach (`$name in @('common', 'scope', 'used', 'resetAt')) { if (-not (Test-PacingHasProperty `$Window `$name)) { return `$false } }" $f1Cases['weekly-reset-missing']
  Assert-DeletionMutant 'window-common-unchecked' "if ((Get-PacingProperty `$Window 'common') -isnot [bool]) { return `$false }" $f1Cases['weekly-common-string']
  Assert-DeletionMutant 'window-scope-unchecked' "if ((Get-PacingProperty `$Window 'scope') -isnot [string]) { return `$false }" $f1Cases['fable-scope-number']
  Assert-DeletionMutant 'window-used-unchecked' 'if (-not (Test-PacingFiniteNumber $used)) { return $false }' $f1Cases['weekly-used-bool']
  Assert-DeletionMutant 'window-used-range-unchecked' 'if ([double]$used -lt 0 -or [double]$used -gt 100) { return $false }' $f1Cases['binding-used-negative']
  Assert-DeletionMutant 'window-reset-unchecked' 'if ($null -ne $reset -and $null -eq (Get-PacingWindowReset $Window)) { return $false }' $f1Cases['weekly-reset-string']
  Assert-DeletionMutant 'available-windows-optional' "if (-not (Get-PacingProperty `$account 'disabled') -and (Get-PacingProperty `$account 'status') -ceq 'available') { return `$result }" $f1Cases['available-windows-missing']
  Assert-DeletionMutant 'identity-optional' 'if ($null -eq $identity) { return $result }' $f2Cases['identity-missing']
  Assert-DeletionMutant 'duplicate-identity-summed' 'if ($identities.ContainsKey($identityKey)) { return $result }' $f2Cases['duplicate-exact']
  Write-Output "PASS capacity-pacing assertions=$($script:assertions) mutants=$($script:mutants) survivors=0"
} finally {
  $env:CHASE_SETS_ROUTING_DATA_ROOT = $oldRoot; $env:CHASE_SETS_ROUTING_LKG_PATH = $oldLkg
  $resolved = [IO.Path]::GetFullPath($root)
  if ((Split-Path -Parent $resolved).TrimEnd('\', '/') -cne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\', '/') -or
      (Split-Path -Leaf $resolved) -notlike 'capacity-pacing-test-*') { throw 'unsafe capacity-pacing cleanup target' }
  if ([IO.Directory]::Exists($resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
