param(
  [string]$EvidenceDirectory=(Join-Path ([IO.Path]::GetTempPath()) 'controller-ci-sharding-proof'),
  [string]$HostedEvidenceDirectory=(Join-Path $PSScriptRoot '../../.orchestrator/logs/controller-8661-hosted-gate-g1.evidence')
)
[Diagnostics.Process]::GetCurrentProcess().PriorityClass='BelowNormal'
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'controller-ci.ps1') -Mode Library
. (Join-Path $PSScriptRoot 'controller-ci-compose-durations.ps1') -Mode Library
[void][IO.Directory]::CreateDirectory($EvidenceDirectory)
function Get-Refusal([scriptblock]$Body) {
  try { & $Body | Out-Null; return $null } catch { return $_.Exception.Message }
}
function Refuses([scriptblock]$Body, [string]$Expected) {
  $message=Get-Refusal $Body
  Assert-Ci ($null -ne $message) "negative control accepted: $Expected"
  Assert-Ci ($message.Contains($Expected)) "negative control refused by another guard: $message"
}
function New-PassReceipts($Plan, [object[]]$Items, [int]$Count) {
  return @(0..($Count-1) | ForEach-Object {
    $n=$_
    @{schemaVersion='controller-ci-shard/v1';shard=$n;controllerHead=$Plan.controllerHead;checkoutHead=$Plan.checkoutHead;productSha=$Plan.productSha;planSha256=$Plan.planSha256
      results=@($Items | Where-Object shard -EQ $n | ForEach-Object {@{identity=$_.identity;result='PASS';exitCode=0;elapsedMs=10L;startedUtc='2026-10-04T21:00:00Z';finishedUtc='2026-10-04T21:00:01Z';provenance=@{kind='execution'}}})}
  })
}

# Legacy plans (no shardCount) keep the original ten-receipt contract.
$inventory = @(0..22 | ForEach-Object { [pscustomobject]@{identity="test:fixture-$_.ps1";restriction=$null} })
$selected = New-CiAssignments $inventory '' -ShardCount $CiLegacyShardCount
Assert-Ci ($selected.Count -eq 23 -and @($selected | Group-Object shard).Count -eq 10) 'ten-way legacy assignment'
Refuses { New-CiAssignments $inventory 'missing' } 'unknown requested item'
Refuses { New-CiAssignments $inventory 'test:fixture-1.ps1,test:fixture-1.ps1' } 'duplicate requested item'
$plan = @{controllerHead=('a'*40);checkoutHead=('b'*40);productSha=('c'*40);planSha256=('d'*64);selected=$selected}
$parts = New-PassReceipts $plan $selected 10
$merged = Merge-CiResults $plan $parts
Assert-Ci ($merged.Count -eq 23) 'complete merge'
Refuses { Merge-CiResults $plan $parts[0..8] } 'exact plan shardCount receipts required'
$parts[0].planSha256='wrong'
Refuses { Merge-CiResults $plan $parts } 'shard identity mismatch'
$parts[0].planSha256=$plan.planSha256
$parts[0].results[0].exitCode=1
Refuses { Merge-CiResults $plan $parts } 'inconsistent result/exitCode'
$parts[0].results[0].exitCode=0
$parts[0].results[0].result='LOCAL_ONLY';$parts[0].results[0].exitCode=125
Refuses { Merge-CiResults $plan $parts } 'unauthorized exclusion'
$selected[0].restriction=@{classification='LOCAL_ONLY';reason='synthetic host-only fixture'}
$merged = Merge-CiResults $plan $parts
Assert-Ci ($merged.Count -eq 23 -and @($merged | Where-Object result -CEQ 'LOCAL_ONLY').Count -eq 1) 'explicit local-only merge'
$parts[0].results[0].identity='test:extra.ps1'
Refuses { Merge-CiResults $plan $parts } 'extra/duplicate result'
Write-Output 'PASS controller CI legacy assignment, missing/duplicate/extra identities, digest, exit/result and exclusion controls'

$now=[datetimeoffset]'2026-10-04T23:00:00Z'
$root=Join-Path $EvidenceDirectory ('planner-fixture-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$source=Join-Path $root 'fixture.ps1'
[IO.File]::WriteAllText($source,'synthetic source')
$item=[pscustomobject]@{identity='test:timed';path='fixture.ps1';restriction=$null}
$record=[pscustomobject]@{identity=$item.identity;elapsedMs=120000L;recordedAtUtc=$now.AddDays(-1).ToString('o');sourceSha256=(Get-CiSourceDigest $source)}
$profile=[pscustomobject]@{schemaVersion='controller-ci-durations/v1';records=@($record)}
Assert-Ci ((Get-CiEstimatedDuration $item $profile $root $now).elapsedMs -eq 120000) 'recorded elapsedMs not used'
$record.recordedAtUtc=$now.AddDays(-31).ToString('o')
Assert-Ci ((Get-CiEstimatedDuration $item $profile $root $now).source -ceq 'fallback') 'stale record not fallback'
$record.recordedAtUtc=$now.AddDays(1).ToString('o')
Assert-Ci ((Get-CiEstimatedDuration $item $profile $root $now).source -ceq 'fallback') 'future record not fallback'
$record.recordedAtUtc=$now.AddDays(-1).ToString('o')
$record.elapsedMs=-1L
Assert-Ci ((Get-CiEstimatedDuration $item $profile $root $now).source -ceq 'fallback') 'invalid duration not fallback'
$record.elapsedMs=120000L;$record.sourceSha256='a'*64
$stale=Get-CiEstimatedDuration $item $profile $root $now
Assert-Ci ($stale.source -ceq 'stale-recorded' -and $stale.elapsedMs -eq 120000) 'changed source not stale-recorded'
Assert-Ci ((Get-CiEstimatedDuration $item $null $root $now).source -ceq 'fallback') 'missing duration not fallback'
$record.sourceSha256=Get-CiSourceDigest $source
$profile.records=@($record,$record)
Assert-Ci ((Get-CiEstimatedDuration $item $profile $root $now).source -ceq 'fallback') 'ambiguous duration not fallback'
$bad=Join-Path $root 'bad.json';[IO.File]::WriteAllText($bad,'{invalid')
Assert-Ci ($null -eq (Read-CiTimingProfile $bad)) 'malformed profile not fallback'
Assert-Ci ($null -eq (Read-CiTimingProfile (Join-Path $root 'absent.json'))) 'absent profile not fallback'
$tasks=@(1..12 | ForEach-Object {[pscustomobject]@{identity="task-$_";estimatedMs=[long](1000*(13-$_))}})
$balanced=Set-CiBalancedShards $tasks 10
Assert-Ci ($balanced[0].identity -ceq 'task-1' -and $balanced[0].shard -eq 0 -and $balanced[9].shard -eq 9 -and $balanced[10].shard -eq 9 -and $balanced[11].shard -eq 8) 'not longest-processing-time first / least loaded shard'

$manifest=Get-Content (Join-Path $PSScriptRoot 'controller-ci-parts.json') -Raw | ConvertFrom-Json
$required=@($manifest.items | ForEach-Object {[pscustomobject]@{identity=$_.identity;path='fixture.ps1';command='synthetic';arguments=@('-File','fixture.ps1');restriction=$null}})
$partCount=@($manifest.items.parts).Count
$execution=New-CiAssignments $required '' $manifest $null $root $now
Assert-Ci ($execution.Count -eq $partCount -and @($execution.requiredIdentity | Select-Object -Unique).Count -eq $required.Count) 'split inventory mapping'
Assert-Ci ((New-CiAssignments $required $required[0].identity $manifest $null $root $now).Count -eq @($manifest.items[0].parts).Count) 'explicit identity does not expand all its parts'
$plan=@{controllerHead=('a'*40);checkoutHead=('b'*40);productSha=('c'*40);planSha256=('d'*64);shardCount=$CiShardCount;selected=$required;executionItems=$execution}
$parts=New-PassReceipts $plan $execution $CiShardCount
$logical=Merge-CiResults $plan $parts
$firstParts=@($manifest.items[0].parts).Count
Assert-Ci ($logical.Count -eq $required.Count -and @($logical | Where-Object result -CEQ 'PASS').Count -eq $required.Count -and
  @($logical | Where-Object identity -CEQ $required[0].identity)[0].elapsedMs -eq (10*$firstParts)) 'all parts not reconciled to original identities'
$target=@($parts | Where-Object { @($_.results).Count -gt 0 })[0]
$saved=$target.results;$target.results=@()
Refuses { Merge-CiResults $plan $parts } 'shard cardinality mismatch'
$target.results=$saved
$target.results[0].result='FAIL';$target.results[0].exitCode=19
$logical=Merge-CiResults $plan $parts
Assert-Ci (@($logical | Where-Object result -CEQ 'FAIL').Count -eq 1 -and @($logical | Where-Object exitCode -EQ 19).Count -eq 1) 'failed part became required PASS'
$target.results[0].result='PASS';$target.results[0].exitCode=0
$savedId=$target.results[0].identity;$target.results[0].identity='extra'
Refuses { Merge-CiResults $plan $parts } 'extra/duplicate result'
$target.results[0].identity=$savedId
$target.results+=@($target.results[0])
Refuses { Merge-CiResults $plan $parts } 'shard cardinality mismatch'
Write-Output 'PASS controller CI duration/LPT/fallback/part reconciliation focused controls'

# Bounded shard-count refusal matrix. Each control is green on the real
# library; its named bypass mutant changes one guard and must turn it red.
$N=$CiShardCount
function New-CountFixture([int]$ItemCount=12,[int]$Count=$N) {
  # Twelve items leave shards 12..N-1 empty, so receipt-count, range and
  # duplicate controls vary only the receipt set, never item coverage.
  $items=Set-CiBalancedShards @(0..($ItemCount-1) | ForEach-Object {[pscustomobject]@{identity="test:count-$_.ps1";estimatedMs=1000L;restriction=$null}}) $Count
  $plan=@{controllerHead=('a'*40);checkoutHead=('b'*40);productSha=('c'*40);planSha256=('d'*64);shardCount=$Count;selected=$items}
  return @{plan=$plan;receipts=(New-PassReceipts $plan $items $Count)}
}
function New-SplitFixture {
  $tasks=@('one','two') | ForEach-Object {[pscustomobject]@{identity="test:split.ps1#$_";requiredIdentity='test:split.ps1';shard=0}}
  $plan=@{selected=@([pscustomobject]@{identity='test:split.ps1';command='synthetic'});executionItems=$tasks}
  $rows=@($tasks | ForEach-Object {[pscustomobject]@{identity=$_.identity;result='PASS';exitCode=0;elapsedMs=5L;startedUtc='2026-10-04T21:00:00Z';finishedUtc='2026-10-04T21:00:01Z';provenance=@{kind='execution'}}})
  return @{plan=$plan;rows=$rows}
}
function Test-Refusal([scriptblock]$Body, [string]$Expected) {
  $message=Get-Refusal $Body
  return ($null -ne $message -and $message.Contains($Expected))
}
# Calibration-first profile composition (replan review F1): synthetic records only.
function New-DurationRecord([string]$Identity, [long]$Ms, [string]$Run) {
  return [pscustomobject]@{identity=$Identity;elapsedMs=$Ms;recordedAtUtc='2026-10-10T08:30:00Z';sourceSha256=('e'*64);measuredSourceSha256=('e'*64);measuredControllerHead=('f'*40);runId=$Run}
}
function New-CompositionFixture([switch]$Reverse) {
  $cal=@((New-DurationRecord 'test:board-hourly-scale.test.ps1#issue-scan' 200000 '1'),(New-DurationRecord 'test:other.ps1' 1000 '1'),
    (New-DurationRecord 'test:dispatch-routing-data.test.ps1#cases-core' 30000 '1'))
  $old=@((New-DurationRecord 'test:board-hourly-scale.test.ps1#issue-scan' 260000 '2'),(New-DurationRecord 'test:board-hourly-scale.test.ps1' 1043806 '2'),
    (New-DurationRecord 'test:board-hourly-scale.test.ps1#ten-item' 189647 '2'),(New-DurationRecord 'test:dispatch-routing-data.test.ps1' 483700 '2'),
    (New-DurationRecord 'test:other.ps1' 5000 '2'),(New-DurationRecord 'test:landed-integration-dispatch.test.ps1#ownership' 156627 '2'))
  if ($Reverse) { [array]::Reverse($cal); [array]::Reverse($old) }
  return Merge-CiDurationProfiles ([pscustomobject]@{records=$cal}) ([pscustomobject]@{records=$old}) $RemeasuredIdentity
}
$controls=[ordered]@{
  'receipts-n-minus-one'={ $f=New-CountFixture; Test-Refusal { Merge-CiResults $f.plan $f.receipts[0..($N-2)] } 'exact plan shardCount receipts required' }
  'receipt-duplicate-shard'={ $f=New-CountFixture; $f.receipts[$N-1]=$f.receipts[$N-2].Clone(); Test-Refusal { Merge-CiResults $f.plan $f.receipts } 'duplicate/invalid shard' }
  'receipt-out-of-range-shard'={ $f=New-CountFixture; $f.receipts[$N-1].shard=$N; Test-Refusal { Merge-CiResults $f.plan $f.receipts } 'duplicate/invalid shard' }
  'plan-other-count'={ $f=New-CountFixture; $f.plan.shardCount=$N+1; Test-Refusal { Get-CiShardCount $f.plan } 'unsupported plan shardCount' }
  'legacy-plan-merges-ten'={
    $legacy=Set-CiBalancedShards @(0..11 | ForEach-Object {[pscustomobject]@{identity="test:count-$_.ps1";estimatedMs=1000L;restriction=$null}}) $CiLegacyShardCount
    $plan=@{controllerHead=('a'*40);checkoutHead=('b'*40);productSha=('c'*40);planSha256=('d'*64);selected=$legacy}
    $tenMerged=Merge-CiResults $plan (New-PassReceipts $plan $legacy 10)
    @($tenMerged).Count -eq 12 -and (Test-Refusal { Merge-CiResults $plan (New-PassReceipts $plan $legacy $N) } 'exact plan shardCount receipts required')
  }
  'shard-argument-outside-plan'={ $f=New-CountFixture; Test-Refusal { Assert-CiShardArgument $f.plan $N } 'shard outside plan shardCount' }
  'lpt-loads-use-plan-count'={ $t=Set-CiBalancedShards @(0..$N | ForEach-Object {[pscustomobject]@{identity=('t-{0:d2}' -f $_);estimatedMs=1000L}}) $N; @($t.shard | Select-Object -Unique).Count -eq $N -and ($t.shard | Measure-Object -Maximum).Maximum -eq $N-1 }
  'matrix-uses-plan-count'={ $m=New-CiShardMatrix $N; (@($m.include.shard) -join ',') -ceq ((0..($N-1)) -join ',') }
  'part-fail-required-fail'={ $f=New-SplitFixture; $f.rows[1].result='FAIL';$f.rows[1].exitCode=19; $r=ConvertTo-CiRequiredResults $f.plan $f.rows; $r[0].result -ceq 'FAIL' -and $r[0].exitCode -eq 19 }
  'split-local-only'={ $f=New-SplitFixture; $f.rows[1].result='LOCAL_ONLY';$f.rows[1].exitCode=125; Test-Refusal { ConvertTo-CiRequiredResults $f.plan $f.rows } 'split exclusion forbidden' }
  'missing-part'={ $f=New-SplitFixture; Test-Refusal { ConvertTo-CiRequiredResults $f.plan @($f.rows[0]) } 'required item has missing parts' }
  'extra-part'={ $f=New-SplitFixture; $extra=$f.rows[0].PSObject.Copy();$extra.identity='test:split.ps1#three'; Test-Refusal { ConvertTo-CiRequiredResults $f.plan (@($f.rows)+@($extra)) } 'unmapped execution result' }
  'duplicate-part-row'={
    # N+1 items put two in one shard; the duplicate keeps that receipt's cardinality.
    $f=New-CountFixture ($N+1); $s=@($f.receipts | Where-Object { @($_.results).Count -eq 2 })[0]
    $s.results=@($s.results[0],$s.results[0])
    Test-Refusal { Merge-CiResults $f.plan $f.receipts } 'extra/duplicate result'
  }
  'stale-part-record'={
    $splitManifest=[pscustomobject]@{schemaVersion='controller-ci-parts/v1';items=@([pscustomobject]@{identity='test:timed';selector='-Part';parts=@([pscustomobject]@{name='one';weight=1},[pscustomobject]@{name='two';weight=1})})}
    $partRecord=[pscustomobject]@{identity='test:timed#one';elapsedMs=70000L;recordedAtUtc=$now.AddDays(-1).ToString('o');sourceSha256=('a'*64)}
    $p=[pscustomobject]@{schemaVersion='controller-ci-durations/v1';records=@($partRecord)}
    $x=New-CiExecutionItems @([pscustomobject]@{identity='test:timed';path='fixture.ps1';command='synthetic';arguments=@();restriction=$null}) $splitManifest $p $root $now
    $one=@($x | Where-Object identity -CEQ 'test:timed#one')[0]
    $one.timingSource -ceq 'stale-recorded-part' -and $one.estimatedMs -eq 70000
  }
  'calibration-wins'={
    $p=New-CompositionFixture
    $issue=@($p.records | Where-Object identity -CEQ 'test:board-hourly-scale.test.ps1#issue-scan')
    $other=@($p.records | Where-Object identity -CEQ 'test:other.ps1')
    $issue.Count -eq 1 -and $issue[0].elapsedMs -eq 200000 -and $other.Count -eq 1 -and $other[0].elapsedMs -eq 1000 -and $other[0].runId -ceq '1'
  }
  'remeasured-family-superseded'={
    $p=New-CompositionFixture
    @($p.records | Where-Object { $_.identity -cin @('test:board-hourly-scale.test.ps1','test:board-hourly-scale.test.ps1#ten-item','test:dispatch-routing-data.test.ps1') }).Count -eq 0
  }
  'unchanged-part-retained'={
    $p=New-CompositionFixture
    $landed=@($p.records | Where-Object identity -CEQ 'test:landed-integration-dispatch.test.ps1#ownership')
    $landed.Count -eq 1 -and ($landed[0] | ConvertTo-Json -Compress) -ceq ((New-DurationRecord 'test:landed-integration-dispatch.test.ps1#ownership' 156627 '2') | ConvertTo-Json -Compress)
  }
  'composition-input-order'={ ((New-CompositionFixture) | ConvertTo-Json -Depth 5) -ceq ((New-CompositionFixture -Reverse) | ConvertTo-Json -Depth 5) }
  'fallback-ties-input-order'={
    $t=@(0..22 | ForEach-Object {[pscustomobject]@{identity=('task-{0:d2}' -f $_);estimatedMs=30000L}})
    $a=(Set-CiBalancedShards $t $N | ForEach-Object {"$($_.identity):$($_.shard)"}) -join ','
    [array]::Reverse($t)
    $a -ceq ((Set-CiBalancedShards $t $N | ForEach-Object {"$($_.identity):$($_.shard)"}) -join ',')
  }
}
foreach ($value in @($CiLegacyShardCount,($N-1),($N+1),11,19,0,-1,[string]$N,$null,1.5)) {
  Refuses { Get-CiShardCount @{shardCount=$value} } 'unsupported plan shardCount'
}
Assert-Ci ((Get-CiShardCount @{shardCount=$N}) -eq $N -and (Get-CiShardCount @{}) -eq $CiLegacyShardCount -and
  (Get-CiShardCount ([pscustomobject]@{shardCount=[long]$N})) -eq $N -and (Get-CiShardCount ([pscustomobject]@{})) -eq $CiLegacyShardCount) 'plan count readers'
Refuses { Assert-CiShardArgument @{} $CiLegacyShardCount } 'shard outside plan shardCount'
Refuses { Assert-CiShardArgument @{shardCount=$N} -1 } 'shard outside plan shardCount'
$mutants=@(
  @{name='merge-accepts-n-minus-one';control='receipts-n-minus-one';file='controller-ci.ps1';old='Assert-Ci ($Shards.Count -eq $count)';new='Assert-Ci ($Shards.Count -ge $count - 1)'},
  @{name='merge-accepts-duplicate-shard';control='receipt-duplicate-shard';file='controller-ci.ps1';old='$seenShards.Add([int]$part.shard)';new='($seenShards.Add([int]$part.shard) -or $true)'},
  @{name='merge-accepts-out-of-range-shard';control='receipt-out-of-range-shard';file='controller-ci.ps1';old='$part.shard -lt $count';new='$part.shard -le $count'},
  @{name='plan-accepts-other-count';control='plan-other-count';file='controller-ci.ps1';old='$value -eq $CiShardCount';new='$value -gt 0'},
  @{name='legacy-plan-adopts-runner-count';control='legacy-plan-merges-ten';file='controller-ci.ps1';old='if ($null -eq $property) { return $CiLegacyShardCount }';new='if ($null -eq $property) { return $CiShardCount }'},
  @{name='shard-argument-unbounded';control='shard-argument-outside-plan';file='controller-ci.ps1';old='$Number -lt (Get-CiShardCount $Plan)';new='$Number -lt 18'},
  @{name='lpt-ten-literal';control='lpt-loads-use-plan-count';file='controller-ci-planning.ps1';old='$i -lt $ShardCount';new='$i -lt 10'},
  @{name='matrix-ten-literal';control='matrix-uses-plan-count';file='controller-ci.ps1';old='0..($Count - 1)';new='0..9'},
  @{name='part-fail-becomes-pass';control='part-fail-required-fail';file='controller-ci-planning.ps1';old="result=`$(if(`$failed.Count){'FAIL'}else{'PASS'})";new="result='PASS'"},
  @{name='split-local-only-accepted';control='split-local-only';file='controller-ci-planning.ps1';old="Assert-Ci (@(`$rows | Where-Object result -CEQ 'LOCAL_ONLY').Count -eq 0) 'split exclusion forbidden'";new='$null'},
  @{name='missing-part-accepted';control='missing-part';file='controller-ci-planning.ps1';old='Assert-Ci ($rows.Count -eq $tasks.Count)';new='Assert-Ci $true'},
  @{name='extra-part-accepted';control='extra-part';file='controller-ci-planning.ps1';old='Assert-Ci (@($Results | Where-Object { $_.identity -cnotin @($Plan.executionItems.identity) }).Count -eq 0)';new='Assert-Ci $true'},
  @{name='duplicate-part-row-accepted';control='duplicate-part-row';file='controller-ci.ps1';old='$seen.Add([string]$row.identity)';new='($seen.Add([string]$row.identity) -or $true)'},
  @{name='stale-part-falls-to-split-estimate';control='stale-part-record';file='controller-ci-planning.ps1';old="@('recorded','stale-recorded')";new="@('recorded')"},
  @{name='unordered-ties';control='fallback-ties-input-order';file='controller-ci-planning.ps1';old='return [StringComparer]::Ordinal.Compare([string]$a.identity,[string]$b.identity)';new='return 0'},
  @{name='history-overrides-calibration';control='calibration-wins';file='controller-ci-compose-durations.ps1';old=' -or $calibrated.Contains([string]$record.identity)';new=''},
  @{name='remeasured-history-kept';control='remeasured-family-superseded';file='controller-ci-compose-durations.ps1';old='$required -cin $Remeasured -or ';new=''},
  @{name='history-dropped';control='unchanged-part-retained';file='controller-ci-compose-durations.ps1';old='foreach ($record in @($Historical.records))';new='foreach ($record in @())'},
  @{name='composition-unsorted';control='composition-input-order';file='controller-ci-compose-durations.ps1';old='records=@($records | Sort-Object { [string]$_.identity } -Culture ([Globalization.CultureInfo]::InvariantCulture))';new='records=@($records)'}
)
Assert-Ci ((@($mutants.control | Sort-Object) -join ',') -ceq (@($controls.Keys | Sort-Object) -join ',')) 'every refusal control has exactly one named bypass mutant'
$matrix=[Collections.Generic.List[object]]::new()
foreach ($mutant in $mutants) {
  $control=$controls[$mutant.control]
  $green=try { [bool](& $control) } catch { $false }
  Assert-Ci $green "control red on the real library: $($mutant.control)"
  $dir=Join-Path $EvidenceDirectory ('mutant-'+$mutant.name)
  [void][IO.Directory]::CreateDirectory($dir)
  foreach ($file in @('controller-ci.ps1','controller-ci-planning.ps1','controller-ci-compose-durations.ps1')) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $dir -Force }
  $path=Join-Path $dir $mutant.file
  $text=[IO.File]::ReadAllText($path)
  Assert-Ci (([regex]::Matches($text,[regex]::Escape($mutant.old))).Count -eq 1) "bypass mutant seam $($mutant.name)"
  [IO.File]::WriteAllText($path,$text.Replace($mutant.old,$mutant.new))
  $mutantRunner=Join-Path $dir 'controller-ci.ps1'
  $mutantComposer=Join-Path $dir 'controller-ci-compose-durations.ps1'
  $mutantGreen=& { . $mutantRunner -Mode Library; . $mutantComposer -Mode Library; try { [bool](& $control) } catch { $false } }
  Assert-Ci (-not $mutantGreen) "bypass mutant survived: $($mutant.name)"
  $matrix.Add([ordered]@{control=$mutant.control;mutant=$mutant.name;file=$mutant.file;real='green';mutated='red'})
  Write-Output "PASS refusal control=$($mutant.control) bypass-mutant=$($mutant.name) red"
}

# Receipts written before shardCount existed re-merge unchanged as ten shards.
$remerge=[Collections.Generic.List[object]]::new()
foreach ($run in @('B','H')) {
  $planPath=Join-Path $HostedEvidenceDirectory "$run-plan/plan.json"
  Assert-Ci (Test-Path -LiteralPath $planPath -PathType Leaf) "retained $run plan unavailable: $planPath"
  $retained=Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json -Depth 40 -DateKind String
  Assert-Ci ($null -eq $retained.PSObject.Properties['shardCount']) "retained $run plan predates shardCount"
  $retained | Add-Member -NotePropertyName planSha256 -NotePropertyValue (Get-FileHash -LiteralPath $planPath -Algorithm SHA256).Hash.ToLowerInvariant()
  $receipts=@(Get-ChildItem -LiteralPath (Join-Path $HostedEvidenceDirectory "$run-result") -Filter shard.json -Recurse -File | ForEach-Object {
    Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -Depth 40 -DateKind String })
  $final=Get-Content -LiteralPath (Join-Path $HostedEvidenceDirectory "$run-result/final.json") -Raw | ConvertFrom-Json -Depth 40 -DateKind String
  $again=Merge-CiResults $retained $receipts
  $fields=@('identity','result','exitCode','elapsedMs','startedUtc','finishedUtc')
  Assert-Ci (($again | Select-Object $fields | ConvertTo-Json -Compress) -ceq ($final.results | Select-Object $fields | ConvertTo-Json -Compress)) "retained $run receipts did not re-merge unchanged"
  Refuses { Merge-CiResults $retained $receipts[0..8] } 'exact plan shardCount receipts required'
  $counts=@{receipts=$receipts.Count;required=@($again).Count;pass=@($again | Where-Object result -CEQ 'PASS').Count
    fail=@($again | Where-Object result -CEQ 'FAIL').Count;localOnly=@($again | Where-Object result -CEQ 'LOCAL_ONLY').Count}
  $remerge.Add([ordered]@{run=$run;plan=$planPath;planSha256=$retained.planSha256;counts=$counts})
  Write-Output "PASS retained $run re-merge receipts=$($counts.receipts) required=$($counts.required) pass=$($counts.pass) fail=$($counts.fail) localOnly=$($counts.localOnly)"
}
Write-CiJson @{outcome='PASS';priority='BelowNormal';shardCount=$N;legacyShardCount=$CiLegacyShardCount;refusalMatrix=@($matrix);remerge=@($remerge)
  controls=@('legacy-merge','LPT','ordinal-ties','missing-stale-invalid-source-fallback','split-required-mapping','missing-extra-duplicate-parts','part-failure-preserved')} (Join-Path $EvidenceDirectory 'planner-proof.json')
Write-Output "PASS controller CI bounded shardCount=$N refusal matrix controls=$($matrix.Count), legacy ten-shard re-merge of retained B/H' receipts"
