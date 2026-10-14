# capacity-pacing.ps1 (#9316): per-provider new-lane allowance from account
# headroom, time to reset and measured burn. AC1 budgets and the Fable cap,
# AC2 allowance from a registry-mapped census, AC3 burn measurement with the
# 168-hour clip, AC4 unknown handling and byte-identical replay, plus the
# plain-floor, clip-ignored, Fable-cap-omitted and exhausted-summed mutants.
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
}

try {
  # --- AC1: lane budget rounding, binding window, Fable cap ----------------------
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
  Assert-Pacing ($claude.fableLaneBudget -eq 4) 'AC1 Fable capped to floor(9/2) = 4'
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
  Assert-Pacing ($r.providers.claude.fableLaneBudget -eq 4) 'AC2 Fable budget is independent of live lanes'
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
  Assert-Mutant 'fable-cap-omitted' '[Math]::Min($fableRounded, [Math]::Floor($laneBudget / 2))' '$fableRounded' {
    param($Mutant)
    Assert-Pacing ((Invoke-Pacing $case5 @{} $Mutant).data.providers.claude.fableLaneBudget -eq 4) 'mutant Fable cap omitted keeps AC1 cap 4'
  }
  Assert-Mutant 'exhausted-summed' "if (`$status -ceq 'exhausted') { `$entry.reason = 'ACCOUNT_EXHAUSTED'; return `$result }" "if (`$status -ceq 'exhausted') { `$status = 'available' }" {
    param($Mutant)
    Assert-Pacing ((Invoke-Pacing $casePartialExhausted @{} $Mutant).data.providers.claude.laneBudget -eq 9) 'mutant exhausted summed keeps AC2 budget 9'
  }
  Assert-Mutant 'unknown-authorizes' "if (`$overall -cne 'ok') { 0 }" 'if ($false) { 0 }' {
    param($Mutant)
    Assert-Pacing ((Invoke-Pacing $caseNoCensus @{} $Mutant).data.providers.claude.newLaneAllowance -eq 0) 'mutant unknown authorizes keeps AC4 zero'
  }
  Write-Output "PASS capacity-pacing assertions=$($script:assertions) mutants=$($script:mutants) survivors=0"
} finally {
  $env:CHASE_SETS_ROUTING_DATA_ROOT = $oldRoot; $env:CHASE_SETS_ROUTING_LKG_PATH = $oldLkg
  $resolved = [IO.Path]::GetFullPath($root)
  if ((Split-Path -Parent $resolved).TrimEnd('\', '/') -cne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\', '/') -or
      (Split-Path -Leaf $resolved) -notlike 'capacity-pacing-test-*') { throw 'unsafe capacity-pacing cleanup target' }
  if ([IO.Directory]::Exists($resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
