param([string]$EvidenceDirectory=(Join-Path $PSScriptRoot 'logs/controller-8661-ci-sharding-g1'))
[Diagnostics.Process]::GetCurrentProcess().PriorityClass='BelowNormal'
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'controller-ci.ps1') -Mode Library
function Refuses([scriptblock]$Body) {
  $refused=$false
  try { & $Body | Out-Null } catch { $refused=$true }
  Assert-Ci $refused 'negative control accepted'
}
$inventory = @(0..22 | ForEach-Object { [pscustomobject]@{identity="test:fixture-$_.ps1";restriction=$null} })
$selected = New-CiAssignments $inventory ''
Assert-Ci ($selected.Count -eq 23 -and @($selected | Group-Object shard).Count -eq 10) 'ten-way assignment'
Refuses { New-CiAssignments $inventory 'missing' }
Refuses { New-CiAssignments $inventory 'test:fixture-1.ps1,test:fixture-1.ps1' }
$plan = @{controllerHead=('a'*40);checkoutHead=('b'*40);productSha=('c'*40);planSha256=('d'*64);selected=$selected}
$parts = @(0..9 | ForEach-Object {
  $number=$_
  @{schemaVersion='controller-ci-shard/v1';shard=$number;controllerHead=$plan.controllerHead;checkoutHead=$plan.checkoutHead
    productSha=$plan.productSha;planSha256=$plan.planSha256
    results=@($selected | Where-Object shard -EQ $number | ForEach-Object { @{identity=$_.identity;result='PASS';exitCode=0} })}
})
$merged = Merge-CiResults $plan $parts
Assert-Ci ($merged.Count -eq 23) 'complete merge'
Refuses { Merge-CiResults $plan $parts[0..8] }
$parts[0].planSha256='wrong'
Refuses { Merge-CiResults $plan $parts }
$parts[0].planSha256=$plan.planSha256
$parts[0].results[0].exitCode=1
Refuses { Merge-CiResults $plan $parts }
$parts[0].results[0].exitCode=0
$parts[0].results[0].result='LOCAL_ONLY';$parts[0].results[0].exitCode=125
Refuses { Merge-CiResults $plan $parts }
$selected[0].restriction=@{classification='LOCAL_ONLY';reason='synthetic host-only fixture'}
$merged = Merge-CiResults $plan $parts
Assert-Ci ($merged.Count -eq 23 -and @($merged | Where-Object result -CEQ 'LOCAL_ONLY').Count -eq 1) 'explicit local-only merge'
$parts[0].results[0].identity='test:extra.ps1'
Refuses { Merge-CiResults $plan $parts }
Write-Output 'PASS controller CI assignment, missing/duplicate/extra identities, digest, exit/result and exclusion controls'

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
Assert-Ci ((Get-CiEstimatedDuration $item $profile $root $now).source -ceq 'fallback') 'changed source not fallback'
Assert-Ci ((Get-CiEstimatedDuration $item $null $root $now).source -ceq 'fallback') 'missing duration not fallback'
$record.sourceSha256=Get-CiSourceDigest $source
$profile.records=@($record,$record)
Assert-Ci ((Get-CiEstimatedDuration $item $profile $root $now).source -ceq 'fallback') 'ambiguous duration not fallback'
$bad=Join-Path $root 'bad.json';[IO.File]::WriteAllText($bad,'{invalid')
Assert-Ci ($null -eq (Read-CiTimingProfile $bad)) 'malformed profile not fallback'
Assert-Ci ($null -eq (Read-CiTimingProfile (Join-Path $root 'absent.json'))) 'absent profile not fallback'
$tasks=@(0..22 | ForEach-Object {[pscustomobject]@{identity=('task-{0:d2}' -f $_);estimatedMs=60000L}})
$first=Set-CiBalancedShards $tasks
$signature=($first | ForEach-Object {"$($_.identity):$($_.shard)"}) -join ','
[array]::Reverse($tasks)
$second=Set-CiBalancedShards $tasks
Assert-Ci ((($second | ForEach-Object {"$($_.identity):$($_.shard)"}) -join ',') -ceq $signature) 'fallback/tie plan depends on input order'
$tasks=@(1..12 | ForEach-Object {[pscustomobject]@{identity="task-$_";estimatedMs=[long](1000*(13-$_))}})
$balanced=Set-CiBalancedShards $tasks
Assert-Ci ($balanced[0].identity -ceq 'task-1' -and $balanced[0].shard -eq 0 -and $balanced[9].shard -eq 9 -and $balanced[10].shard -eq 9 -and $balanced[11].shard -eq 8) 'not longest-processing-time first / least loaded shard'

$manifest=Get-Content (Join-Path $PSScriptRoot 'controller-ci-parts.json') -Raw | ConvertFrom-Json
$required=@($manifest.items | ForEach-Object {[pscustomobject]@{identity=$_.identity;path='fixture.ps1';command='synthetic';arguments=@('-File','fixture.ps1');restriction=$null}})
$execution=New-CiAssignments $required '' $manifest $null $root $now
Assert-Ci ($execution.Count -eq 10 -and @($execution.requiredIdentity | Select-Object -Unique).Count -eq 2) 'split inventory mapping'
Assert-Ci (@(New-CiAssignments $required $required[0].identity $manifest $null $root $now).Count -eq 5) 'explicit identity does not expand all its parts'
$plan=@{controllerHead=('a'*40);checkoutHead=('b'*40);productSha=('c'*40);planSha256=('d'*64);selected=$required;executionItems=$execution}
$parts=@(0..9 | ForEach-Object {
  $n=$_
  @{schemaVersion='controller-ci-shard/v1';shard=$n;controllerHead=$plan.controllerHead;checkoutHead=$plan.checkoutHead;productSha=$plan.productSha;planSha256=$plan.planSha256
    results=@($execution | Where-Object shard -EQ $n | ForEach-Object {@{identity=$_.identity;result='PASS';exitCode=0;elapsedMs=10L;startedUtc='2026-10-04T21:00:00Z';finishedUtc='2026-10-04T21:00:01Z';provenance=@{kind='execution'}}})}
})
$logical=Merge-CiResults $plan $parts
Assert-Ci ($logical.Count -eq 2 -and @($logical | Where-Object result -CEQ 'PASS').Count -eq 2 -and $logical[0].elapsedMs -eq 50) 'all parts not reconciled to original identities'
$saved=$parts[0].results;$parts[0].results=@()
Refuses { Merge-CiResults $plan $parts }
$parts[0].results=$saved
$parts[0].results[0].result='FAIL';$parts[0].results[0].exitCode=19
$logical=Merge-CiResults $plan $parts
Assert-Ci (@($logical | Where-Object result -CEQ 'FAIL').Count -eq 1 -and @($logical | Where-Object exitCode -EQ 19).Count -eq 1) 'failed part became required PASS'
$parts[0].results[0].result='PASS';$parts[0].results[0].exitCode=0
$savedId=$parts[0].results[0].identity;$parts[0].results[0].identity='extra'
Refuses { Merge-CiResults $plan $parts }
$parts[0].results[0].identity=$savedId
$parts[0].results+=@($parts[0].results[0])
Refuses { Merge-CiResults $plan $parts }
Write-CiJson @{outcome='PASS';priority='BelowNormal';controls=@('legacy-merge','LPT','ordinal-ties','missing-stale-invalid-source-fallback','split-required-mapping','missing-extra-duplicate-parts','part-failure-preserved')} (Join-Path $EvidenceDirectory 'planner-proof.json')
Write-Output 'PASS controller CI duration/LPT/fallback/part reconciliation focused controls'
