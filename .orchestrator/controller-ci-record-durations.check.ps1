$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'controller-ci-record-durations.ps1') -Library
function Refuses-Record([scriptblock]$Body){$refused=$false;try{&$Body|Out-Null}catch{$refused=$true};Assert-Ci $refused 'recorder bypass survived'}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('ci-record-check-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
try{
  & git -C $temp init -q
  & git -C $temp config user.name Synthetic
  & git -C $temp config user.email synthetic@example.invalid
  & git -C $temp config core.autocrlf false
  $unicode='caf'+[char]0xe9+' '+[char]0x96ea
  foreach($ending in @('lf','crlf')){foreach($final in @($false,$true)){
    $text=$unicode+"`n"+'last'+$(if($final){"`n"}else{''})
    if($ending-ceq'crlf'){$text=$text.Replace("`n","`r`n")}
    $name="$ending-$final.ps1"
    [IO.File]::WriteAllText((Join-Path $temp $name),$text,[Text.UTF8Encoding]::new($false))
  }}
  [void][IO.Directory]::CreateDirectory((Join-Path $temp '.orchestrator'))
  foreach($entry in @{'source.test.ps1'='# sibling.test.ps1';'sibling.test.ps1'='# retained proof';'other.test.ps1'='# unrelated proof';'.orchestrator/runtime.ps1'='# runtime';'.orchestrator/controller-ci-planning.ps1'='# planning'}.GetEnumerator()){
    [IO.File]::WriteAllText((Join-Path $temp $entry.Key),$entry.Value,[Text.UTF8Encoding]::new($false))
  }
  & git -C $temp add .
  & git -C $temp commit -qm synthetic
  Assert-Ci ($LASTEXITCODE-eq0) 'recorder fixture commit failed'
  $head=(Get-CiHead $temp)
  $oldEncoding=$OutputEncoding;$oldConsole=[Console]::OutputEncoding
  try{
    $observed=@(foreach($encoding in @([Text.UTF8Encoding]::new($false),[Text.Encoding]::GetEncoding(437))){
      $OutputEncoding=$encoding;[Console]::OutputEncoding=$encoding
      foreach($name in @('lf-False.ps1','crlf-False.ps1','lf-True.ps1','crlf-True.ps1')){Get-CiBlobDigest $temp $head $name}
    })
  }finally{$OutputEncoding=$oldEncoding;[Console]::OutputEncoding=$oldConsole}
  Assert-Ci ($observed[0]-ceq$observed[1]-and$observed[2]-ceq$observed[3]-and$observed[0]-cne$observed[2]) 'line endings or final newline corrupted'
  Assert-Ci (($observed[0..3]-join',')-ceq($observed[4..7]-join',')) 'console encoding changed blob digest'
  Assert-Ci ($observed[0]-ceq(Get-CiTextDigest ([Text.Encoding]::UTF8.GetBytes($unicode+"`n"+'last')))) 'non-ASCII source digest corrupted'
  Refuses-Record {Get-CiBlobDigest $temp $head 'missing.ps1'}
  Refuses-Record {Get-CiBlobDigest $temp ('f'*40) 'lf-False.ps1'}
  $plan=@{checkoutHead=$head;controllerHead=$head;runnerHead=('b'*40);productSha=('c'*40)
    executionItems=@(@{identity='test:encoding';path='lf-False.ps1';restriction=$null})}
  $result=@{controllerHead=$head;ci=@{checkoutHead=$head;runnerHead=$plan.runnerHead;productSha=$plan.productSha
    planSha256=('d'*64);runId='123';executionResults=@(@{identity='test:encoding';result='PASS';exitCode=0;elapsedMs=1234;finishedUtc='2026-10-23T00:00:00Z'})}}
  $record=@(New-CiDurationRecords $plan $result ('d'*64) $temp)[0]
  Assert-Ci ($record.elapsedMs-eq1234-and$record.recordedAtUtc-ceq'2026-10-23T00:00:00Z'-and$record.runId-ceq'123'-and
    $record.checkoutHead-ceq$head-and$record.runnerHead-ceq$plan.runnerHead-and$record.productSha-ceq$plan.productSha-and
    $record.planSha256-ceq('d'*64)-and$record.sourceSha256-ceq$observed[0]) 'measured provenance changed'
  $result.ci.planSha256='wrong';Refuses-Record {New-CiDurationRecords $plan $result ('d'*64) $temp}
  # -Append keeps the profile's shardCount: function controls, a carry-dropping
  # mutant, and an end-to-end append through the recorder entrypoint.
  $r1=[ordered]@{identity='test:a';runId='1';planSha256='p1';elapsedMs=1}
  $r2=[ordered]@{identity='test:a';runId='2';planSha256='p2';elapsedMs=2}
  $withCount={param($Count) [pscustomobject]@{schemaVersion='controller-ci-durations/v1';shardCount=$Count;records=@($r1)}}
  $kept=New-CiDurationProfile (& $withCount 32) @($r1,$r2)
  Assert-Ci ($kept.shardCount-is[int]-and$kept.shardCount-eq32-and@($kept.records).Count-eq2) 'append dropped shardCount or mis-merged records'
  $absent=New-CiDurationProfile ([pscustomobject]@{schemaVersion='controller-ci-durations/v1';records=@($r1)}) @($r2)
  Assert-Ci (-not$absent.ContainsKey('shardCount')-and@($absent.records).Count-eq2) 'append invented a shardCount'
  Assert-Ci (-not(New-CiDurationProfile $null @($r1)).ContainsKey('shardCount')) 'fresh profile invented a shardCount'
  foreach($bad in @(40,'32',15)){Refuses-Record {New-CiDurationProfile (& $withCount $bad) @($r1)}}
  $profileDefinition=(Get-Command New-CiDurationProfile).Definition
  $carry='if($null-ne$Existing-and$null-ne$Existing.shardCount){$profileOut.shardCount=Get-CiShardCount @{shardCount=$Existing.shardCount}}'
  Assert-Ci ($profileDefinition.Contains($carry,[StringComparison]::Ordinal)) 'shardCount carry mutation target missing'
  & {
    . ([scriptblock]::Create("function New-CiDurationProfile {`n$($profileDefinition.Replace($carry,''))`n}"))
    Refuses-Record {Assert-Ci ((New-CiDurationProfile (& $withCount 32) @($r1)).shardCount-eq32) 'shardCount-dropping mutant accepted'}
  }
  $e2e=Join-Path $temp '.git/ci-record-e2e';[void][IO.Directory]::CreateDirectory($e2e)
  $e2ePlanPath=Join-Path $e2e 'plan.json';Write-CiJson $plan $e2ePlanPath
  $e2eDigest=(Get-FileHash -LiteralPath $e2ePlanPath -Algorithm SHA256).Hash.ToLowerInvariant()
  $e2eResult=@{controllerHead=$head;ci=@{checkoutHead=$head;runnerHead=$plan.runnerHead;productSha=$plan.productSha
    planSha256=$e2eDigest;runId='124';executionResults=@(@{identity='test:encoding';result='PASS';exitCode=0;elapsedMs=4321;finishedUtc='2026-10-23T00:00:00Z'})}}
  $e2eResultPath=Join-Path $e2e 'final.json';Write-CiJson $e2eResult $e2eResultPath
  $e2eProfilePath=Join-Path $e2e 'durations.json';Write-CiJson (& $withCount 32) $e2eProfilePath
  $e2eOut=@(& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'controller-ci-record-durations.ps1') -RecordPlanPath $e2ePlanPath -ResultPath $e2eResultPath -OutputPath $e2eProfilePath -Append -RepositoryRoot $temp 2>&1)
  Assert-Ci ($LASTEXITCODE-eq0) "end-to-end append failed: $($e2eOut -join ' ')"
  $appended=Read-CiTimingProfile $e2eProfilePath
  Assert-Ci ($appended.shardCount-eq32-and@($appended.records).Count-eq2-and@($appended.records)[1].elapsedMs-eq4321) 'end-to-end -Append dropped shardCount or the new record'
  Write-Output 'PASS append keeps shardCount: function keeps 32, adds none when absent or fresh, refuses 40/"32"/15; carry-dropping mutant red; end-to-end -Append through the recorder keeps shardCount=32 and adds the new record'
  $item=[pscustomobject]@{identity='test:maximum';path='lf-False.ps1';restriction=$null}
  $low=[pscustomobject]@{identity=$item.identity;elapsedMs=1000;recordedAtUtc='2026-10-23T00:00:00Z';sourceSha256=$observed[0];sourceSetSha256='fixture'}
  $high=$low|Select-Object *;$high.elapsedMs=9000;$high.recordedAtUtc='2026-10-23T00:01:00Z'
  $profile=@{records=@($low,$high)};$now=[datetimeoffset]'2026-10-23T01:00:00Z'
  $estimate=Get-CiEstimatedDuration $item $profile $temp $now 'fixture'
  Assert-Ci ($estimate.elapsedMs-eq9000-and$estimate.source-ceq'recorded') 'two-record maximum weighting failed'
  $profile.records=@($high,$low)
  Assert-Ci ((Get-CiEstimatedDuration $item $profile $temp $now 'fixture').elapsedMs-eq9000) 'maximum weighting depends on record order'
  $definition=(Get-Command Get-CiEstimatedDuration).Definition
  $needle='($fresh|Measure-Object -Maximum)'
  Assert-Ci ($definition.Contains($needle,[StringComparison]::Ordinal)) 'weighting mutation target missing'
  $mutant=$definition.Replace($needle,'($fresh|Measure-Object -Minimum)')
  & {
    . ([scriptblock]::Create("function Get-CiEstimatedDuration {`n$mutant`n}"))
    Refuses-Record {Assert-Ci ((Get-CiEstimatedDuration $item $profile $temp $now 'fixture').elapsedMs-eq9000) 'minimum-weight mutant accepted low sample'}
  }
  $old=$high|Select-Object *;$old.elapsedMs=999999;$old.recordedAtUtc='2026-09-01T00:00:00Z'
  $wrong=$high|Select-Object *;$wrong.elapsedMs=999999;$wrong.sourceSha256='f'*64
  $profile.records=@($low,$high,$old,$wrong)
  Assert-Ci ((Get-CiEstimatedDuration $item $profile $temp $now 'fixture').elapsedMs-eq9000) 'expired/mismatched source contaminated maximum'
  $before=Get-CiTimingSourceSetDigest $temp $head 'source.test.ps1'
  foreach($name in @('other.test.ps1','.orchestrator/controller-ci-planning.ps1')){[IO.File]::AppendAllText((Join-Path $temp $name),' changed')}
  & git -C $temp add .; & git -C $temp commit -qm unrelated
  $unrelated=Get-CiTimingSourceSetDigest $temp (Get-CiHead $temp) 'source.test.ps1'
  Assert-Ci ($before-ceq$unrelated) 'unrelated proof/planning invalidated timing'
  [IO.File]::AppendAllText((Join-Path $temp 'sibling.test.ps1'),' changed')
  & git -C $temp add .; & git -C $temp commit -qm sibling
  $sibling=Get-CiTimingSourceSetDigest $temp (Get-CiHead $temp) 'source.test.ps1'
  Assert-Ci ($sibling-cne$unrelated) 'retained proof sibling did not invalidate timing'
  [IO.File]::AppendAllText((Join-Path $temp '.orchestrator/runtime.ps1'),' changed')
  & git -C $temp add .; & git -C $temp commit -qm runtime
  Assert-Ci ((Get-CiTimingSourceSetDigest $temp (Get-CiHead $temp) 'source.test.ps1')-cne$sibling) 'runtime dependency did not invalidate timing'
  Write-Output 'PASS maximum weighting: low=1000 high=9000 planned=9000, reverse order stable, minimum-weight mutant red; expired/source-mismatch excluded; runtime and retained sibling changes invalidate'
  Write-Output 'PASS recorder exact blob bytes, UTF-8/non-UTF-8 consoles, non-ASCII, CRLF/LF, final-newline distinction, unchanged provenance and unreadable-blob refusals'
}finally{
  $resolved=[IO.Path]::GetFullPath($temp)
  Assert-Ci ((Split-Path -Parent $resolved)-ceq[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')) 'unsafe recorder fixture cleanup'
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
