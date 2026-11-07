[CmdletBinding()]param([switch]$QualificationOnly)
$ErrorActionPreference='Stop';$root=Join-Path ([IO.Path]::GetTempPath()) ('digest-test-'+[guid]::NewGuid().ToString('N'))
function Assert-Digest([bool]$c,[string]$m){if(-not$c){throw "ASSERTION FAILED: $m"}}
function Test-DigestCallerQualification([string]$FixtureRoot,[string]$Waiting) {
  $directory=Join-Path $FixtureRoot 'qualification'
  [void][IO.Directory]::CreateDirectory($directory)
  $oracle=Join-Path $directory 'oracle.jsonl';$large=Join-Path $directory 'dispatch-log.jsonl'
  $prefix=Join-Path $directory 'prefix-32mib.jsonl';$suffix=Join-Path $directory 'suffix-50000.jsonl'
  $cost=Join-Path $directory 'cost.jsonl';$utf8=[Text.UTF8Encoding]::new($false)
  [IO.File]::WriteAllText($cost,'',$utf8)
  function Invoke-QualifiedDigest([string]$Path,[string]$Phase) {
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $text=& pwsh -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'digest-publish.ps1') `
      -Tracking 909126 -Repo synthetic/chase-sets -DryRun -DispatchLog $Path -CostLedger $cost -WaitingOnToddConfig $Waiting 2>&1 | Out-String
    $code=$LASTEXITCODE;$timer.Stop()
    Write-Host "CLI phase=$Phase childExit=$code elapsedSeconds=$($timer.Elapsed.TotalSeconds.ToString('F3',[Globalization.CultureInfo]::InvariantCulture))"
    Write-Host $text
    Assert-Digest ($code -eq 0) "actual digest CLI failed in $Phase with exit $code"
    return $text
  }
  $padding='{"ts":"2026-01-01T00:00:00Z","kind":"synthetic-padding"}'
  $widePadding='{"ts":"2026-01-01T00:00:00Z","kind":"synthetic-padding","note":"'+('x'*640)+'"}'
  # These future-dated events must stay outside the intentional last-500 window.
  $early=@(
    '{"ts":"2099-01-01T00:00:00Z","kind":"dispatch","lane":"synthetic-early"}',
    '{"ts":"2099-01-01T00:00:01Z","kind":"enqueue","pr":909999}',
    '{"ts":"2099-01-01T00:00:02Z","kind":"deploy-verified","outcome":"SYNTHETIC-EARLY-EXCLUDED"}',
    '{"ts":"2099-01-01T00:00:03Z","kind":"breaker-open","issue":909999,"pr":909999}',
    '{"ts":"2099-01-01T00:00:04Z","kind":"decision-filed","issue":909999}'
  )
  $events=@{
    0='{"ts":"2026-01-02T00:00:00Z","kind":"enqueue","pr":909001}'
    20='{"ts":"2026-01-02T00:00:01Z","kind":"dispatch","lane":"synthetic-window"}'
    21='{"ts":"2026-01-02T00:00:02Z","kind":"enqueue","pr":909002}'
    22='{"ts":"2026-01-02T00:00:03Z","kind":"deploy-verified","outcome":"SYNTHETIC-WINDOW"}'
    23='{"ts":"2026-01-02T00:00:04Z","kind":"breaker-open","issue":909126,"pr":909003}'
    24='{"ts":"2026-01-02T00:00:05Z","kind":"decision-filed","issue":909126}'
  }
  $earlyBytes=0L;foreach($line in $early){$earlyBytes+=$utf8.GetByteCount($line+"`n")}
  $paddingBytes=$utf8.GetByteCount($widePadding+"`n")
  $prefixPadding=[int][math]::Floor((33554432L-$earlyBytes)/$paddingBytes)
  $writers=@();$windowWriter=$null;$prefixWriter=$null;$largeWriter=$null
  try {
    $largeWriter=[IO.StreamWriter]::new($large,$false,$utf8,65536);$writers+=,$largeWriter
    $prefixWriter=[IO.StreamWriter]::new($prefix,$false,$utf8,65536);$writers+=,$prefixWriter
    $windowWriter=[IO.StreamWriter]::new($oracle,$false,$utf8,65536);$writers+=,$windowWriter
    foreach($writer in $writers){$writer.NewLine="`n"}
    foreach($line in $early){$largeWriter.WriteLine($line);$prefixWriter.WriteLine($line)}
    for($i=0;$i -lt 50000;$i++){
      $largeWriter.WriteLine($widePadding)
      if($i -lt $prefixPadding){$prefixWriter.WriteLine($widePadding)}
    }
    for($i=0;$i -lt 500;$i++){
      $line=if($events.ContainsKey($i)){$events[$i]}else{$padding}
      $largeWriter.WriteLine($line);$windowWriter.WriteLine($line)
    }
  } finally {foreach($writer in $writers){$writer.Dispose()}}
  # Retaining 50,000 suffix lines is equivalent here, not a negative mutant:
  # the real caller itself intentionally selects only the final 500 lines.
  $reader=[IO.StreamReader]::new($large,$utf8);$suffixWriter=$null;$physicalRows=0;$suffixRows=0
  try {
    $suffixWriter=[IO.StreamWriter]::new($suffix,$false,$utf8,65536);$suffixWriter.NewLine="`n"
    while($null -ne ($line=$reader.ReadLine())){
      $physicalRows++
      if($physicalRows -gt 505){$suffixWriter.WriteLine($line);$suffixRows++}
    }
  } finally {$reader.Dispose();if($suffixWriter){$suffixWriter.Dispose()}}
  $length=(Get-Item -LiteralPath $large).Length;$prefixLength=(Get-Item -LiteralPath $prefix).Length
  Assert-Digest ($physicalRows -eq 50505 -and $length -gt 33554432 -and $suffixRows -eq 50000) 'qualification fixture did not cross both history cliffs'
  Assert-Digest ($prefixLength -le 33554432 -and $prefixLength+$paddingBytes -gt 33554432 -and $prefixPadding -lt 50000) 'prefix discriminator is not the maximal line-complete 32MiB prefix'
  Write-Output "FIXTURE large physicalRows=$physicalRows bytes=$length oraclePhysicalRows=500 oracleBytes=$((Get-Item -LiteralPath $oracle).Length) prefixPhysicalRows=$($early.Count+$prefixPadding) prefixBytes=$prefixLength suffixPhysicalRows=$suffixRows suffixBytes=$((Get-Item -LiteralPath $suffix).Length)"
  $expected=Invoke-QualifiedDigest $oracle 'oracle'
  Assert-Digest ($expected.Contains('**Cycle digest') -and $expected.Contains('2026-01-02T00:00:05Z') -and
    $expected.Contains('| Merge queue | 2 lifecycle-confirmed |') -and $expected.Contains('| Lanes | 1 active |') -and
    $expected.Contains('| Real deploy | SYNTHETIC-WINDOW |') -and $expected.Contains('| Open breakers | 1 |') -and
    $expected.Contains('**Open decisions:** #909126') -and $expected.Contains('| Spend today | `$0.00 |') -and
    $expected.Contains('**Waiting on Todd:** #909229') -and -not $expected.Contains('909999')) 'small complete-window oracle lost meaningful lifecycle fields'
  $actual=Invoke-QualifiedDigest $large 'large'
  Assert-Digest ([string]::Equals($actual,$expected,[StringComparison]::Ordinal)) 'whole rendered large-history result differs from the complete final-500 oracle'
  $suffixBody=Invoke-QualifiedDigest $suffix 'suffix-50000-equivalent'
  Assert-Digest ([string]::Equals($suffixBody,$expected,[StringComparison]::Ordinal)) 'last-50000 suffix should preserve the intentional final-500 result'
  $cutoff=Invoke-QualifiedDigest $prefix 'prefix-32mib-expected-negative'
  Assert-Digest (-not [string]::Equals($cutoff,$expected,[StringComparison]::Ordinal) -and
    $cutoff.Contains('| Merge queue | 0 lifecycle-confirmed |') -and $cutoff.Contains('| Lanes | 0 active |') -and
    $cutoff.Contains('| Real deploy | unknown |') -and $cutoff.Contains('| Open breakers | 0 |') -and
    $cutoff.Contains('**Open decisions:** none.')) 'line-complete 32MiB cutoff did not discriminate lost final-window evidence'
  Write-Output 'COMPARISON whole rendered text equal; no normalization; early events excluded; KILLED expected-negative prefix-32MiB; suffix-50000 correctly equivalent; NOT raw-byte/BOM or memory evidence'
  $snapshots=@()
  foreach($path in @($oracle,$large)){
    $info=Get-Item -LiteralPath $path;$saved=$path+'.saved'
    $snapshots+=,[pscustomobject]@{path=$path;saved=$saved;hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
      length=$info.Length;creation=$info.CreationTimeUtc;write=$info.LastWriteTimeUtc;access=$info.LastAccessTimeUtc}
    [IO.File]::Copy($path,$saved)
  }
  $append=@(
    '{"ts":"2026-01-03T00:00:00Z","kind":"dequeue","pr":909001}',
    '{"ts":"2026-01-03T00:00:01Z","kind":"dequeue","pr":909002}',
    '{"ts":"2026-01-03T00:00:02Z","kind":"complete","lane":"synthetic-window"}',
    '{"ts":"2026-01-03T00:00:03Z","kind":"deploy-verified","outcome":"SYNTHETIC-APPENDED"}',
    '{"ts":"2026-01-03T00:00:04Z","kind":"breaker-clear","issue":909126,"pr":909003}',
    '{"ts":"2026-01-03T00:00:05Z","kind":"decision-resolved","issue":909126}'
  )
  try {
    foreach($path in @($oracle,$large)){[IO.File]::AppendAllText($path,($append -join "`n")+"`n",$utf8)}
    $appendedOracle=Invoke-QualifiedDigest $oracle 'oracle-append'
    $appendedLarge=Invoke-QualifiedDigest $large 'large-append'
    Assert-Digest ([string]::Equals($appendedLarge,$appendedOracle,[StringComparison]::Ordinal) -and
      -not [string]::Equals($appendedLarge,$expected,[StringComparison]::Ordinal) -and
      $appendedLarge.Contains('2026-01-03T00:00:05Z') -and $appendedLarge.Contains('| Merge queue | 0 lifecycle-confirmed |') -and
      $appendedLarge.Contains('| Lanes | 0 active |') -and $appendedLarge.Contains('| Real deploy | SYNTHETIC-APPENDED |') -and
      $appendedLarge.Contains('| Open breakers | 0 |') -and $appendedLarge.Contains('**Open decisions:** none.')) 'append lost complete rendered-result continuity or lifecycle transitions'
    Write-Output "APPEND rows=6 largePhysicalRows=$($physicalRows+6) largeBytes=$((Get-Item -LiteralPath $large).Length) oraclePhysicalRows=506 oracleBytes=$((Get-Item -LiteralPath $oracle).Length) wholeResultEqual=True changed=True"
  } finally {
    foreach($snapshot in $snapshots){
      [IO.File]::Copy($snapshot.saved,$snapshot.path,$true)
      Assert-Digest ((Get-Item -LiteralPath $snapshot.path).Length -eq $snapshot.length -and
        (Get-FileHash -LiteralPath $snapshot.path -Algorithm SHA256).Hash -ceq $snapshot.hash) 'fixture bytes were not restored'
      [IO.File]::SetCreationTimeUtc($snapshot.path,$snapshot.creation)
      [IO.File]::SetLastWriteTimeUtc($snapshot.path,$snapshot.write)
      [IO.File]::SetLastAccessTimeUtc($snapshot.path,$snapshot.access)
      $restored=Get-Item -LiteralPath $snapshot.path
      Assert-Digest ($restored.CreationTimeUtc -eq $snapshot.creation -and $restored.LastWriteTimeUtc -eq $snapshot.write -and
        $restored.LastAccessTimeUtc -eq $snapshot.access) 'fixture timestamps were not restored'
      Write-Output "RESTORED fixture=$([IO.Path]::GetFileName($snapshot.path)) bytes=$($snapshot.length) sha256=$($snapshot.hash) creationWriteAccessUtcEqual=True"
    }
  }
  $replay=Invoke-QualifiedDigest $large 'large-restored-replay'
  Assert-Digest ([string]::Equals($replay,$expected,[StringComparison]::Ordinal)) 'restored large history did not replay the entire initial digest'
  Write-Output 'PASS digest actual CLI above both cliffs: complete final-500 oracle, cutoff/suffix distinction, append and restored replay; bounded qualification only, NOT all callers or bounded-memory proof'
}
try{New-Item -ItemType Directory -Path $root|Out-Null;$log=Join-Path $root 'dispatch.jsonl';$cost=Join-Path $root 'cost.jsonl';$now=[datetimeoffset]::UtcNow
  $rows=@(
    [ordered]@{ts=$now.AddMinutes(-5).ToString('o');kind='dispatch';issue=4388;lane='lane-a'},
    [ordered]@{ts=$now.AddMinutes(-4).ToString('o');kind='enqueue';pr=9001},
    [ordered]@{ts=$now.AddMinutes(-3).ToString('o');kind='breaker-open';issue=1;pr=2},
    [ordered]@{ts=$now.AddMinutes(-2).ToString('o');kind='decision-filed';issue=4388},
    [ordered]@{ts=$now.AddMinutes(-1).ToString('o');kind='deploy-verified';outcome='PASS'}
  );[IO.File]::WriteAllLines($log,@($rows|ForEach-Object{$_|ConvertTo-Json -Compress}),[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($cost,([ordered]@{ts=$now.ToString('o');usd=12.5}|ConvertTo-Json -Compress)+"`n",[Text.UTF8Encoding]::new($false))
  $waiting=Join-Path $root 'waiting-on-todd.psd1';[IO.File]::WriteAllText($waiting,"@{ Repo = 'synthetic/chase-sets'; PinnedIssue = 909229; Assignee = 'synthetic-todd'; DoneWindowDays = 7 }",[Text.UTF8Encoding]::new($false))
  Test-DigestCallerQualification $root $waiting
  if($QualificationOnly){return}
  $body=&(Join-Path $PSScriptRoot 'digest-publish.ps1') -Tracking 4388 -DryRun -DispatchLog $log -CostLedger $cost -WaitingOnToddConfig $waiting|Out-String
  Assert-Digest ($body.Contains('**Waiting on Todd:** #909229 lists every packaged operator action') -and -not $body.Contains('Open for Todd')) 'digest does not link the synthetic pinned Waiting-on-Todd issue'
  # SYNTHETIC refused-sync and absent-assignment controls (#9228 F1): the digest
  # carries no synchronization evidence, so it links the pinned issue but never
  # asserts that Todd is assigned. A read-only stub stands in for GitHub.
  $stub=Join-Path $root 'fake-gh.ps1';[IO.File]::WriteAllText($stub,'if($args.Count -ne 2 -or $args[0] -cne ''api''){exit 1};[ordered]@{number=[int](($args[1] -split ''/'')[-1]);body=''SYNTHETIC hand-written Waiting-on-Todd body'';assignees=@()}|ConvertTo-Json -Compress',[Text.UTF8Encoding]::new($false))
  $sync=@{Config=$waiting;StatePath=(Join-Path $root 'state/waiting-on-todd.json');GhCommand=$stub;DryRun=$true};$refusal=$null
  try{& (Join-Path $PSScriptRoot 'waiting-on-todd.ps1') @sync -DispatchLog $log|Out-Null}catch{$refusal=$_.Exception.Message}
  Assert-Digest ("$refusal".StartsWith('WAITING_ON_TODD_UNSEEDED') -and -not(Test-Path -LiteralPath (Join-Path $root 'state'))) "synthetic unseeded sync was not refused: '$refusal'"
  $absent=Join-Path $root 'absent-assignment.jsonl';Copy-Item -LiteralPath $log -Destination $absent
  & (Join-Path $PSScriptRoot 'log-event.ps1') -Log dispatch -Kind todd-action -ActionId 'synthetic-absent-assignment' -Issue 909232 -ActionState now -Action 'SYNTHETIC step whose assignment is absent' -ActionTime 'synthetic minutes' -Unblocks '#909233' -OutFile $absent -NoBoard|Out-Null
  $planned=(& (Join-Path $PSScriptRoot 'waiting-on-todd.ps1') @sync -DispatchLog $absent|Out-String)|ConvertFrom-Json
  Assert-Digest ((@($planned.adds)-join',') -ceq '909232' -and $planned.dryRun) 'synthetic Now issue was not left unassigned by the dry-run sync'
  $absentBody=&(Join-Path $PSScriptRoot 'digest-publish.ps1') -Tracking 4388 -DryRun -DispatchLog $absent -CostLedger $cost -WaitingOnToddConfig $waiting|Out-String
  foreach($control in @(@{name='refused-sync';text=$body},@{name='absent-assignment';text=$absentBody})){
    Assert-Digest ($control.text.Contains('**Waiting on Todd:** #909229 lists every packaged operator action.') -and $control.text -notmatch '(?i)assign') "$($control.name) digest asserts an assignment no synchronization evidence supports"
  }
  foreach($bad in @((Join-Path $root 'absent.psd1'),$cost)){$refused=$false;try{& (Join-Path $PSScriptRoot 'digest-publish.ps1') -Tracking 4388 -DryRun -DispatchLog $log -CostLedger $cost -WaitingOnToddConfig $bad|Out-Null}catch{$refused=$true};Assert-Digest $refused 'digest rendered without a pinned Waiting-on-Todd issue'}
  Assert-Digest ($body-match'Merge queue \| 1'-and$body-match'Lanes \| 1 active'-and$body-match'Real deploy \| PASS'-and$body-match'Open breakers \| 1'-and$body-match'12\.50'-and$body-match'#4388') 'digest omitted bounded lifecycle or spend evidence'
  [IO.File]::AppendAllText($log,'{malformed'+"`n",[Text.UTF8Encoding]::new($false));$failed=$false;try{& (Join-Path $PSScriptRoot 'digest-publish.ps1') -Tracking 4388 -DryRun -DispatchLog $log -CostLedger $cost -WaitingOnToddConfig $waiting|Out-Null}catch{$failed=$true};Assert-Digest $failed 'malformed lifecycle history was rendered as success'
  Write-Output 'PASS digest renders lifecycle, deploy, breaker, decision, queue, lane, daily spend and pinned Waiting-on-Todd link evidence without unsupported assignment claims'
}finally{
  $full=[IO.Path]::GetFullPath($root)
  if((Split-Path -Parent $full).TrimEnd('\','/') -cne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/') -or
    (Split-Path -Leaf $full) -cnotmatch '^digest-test-[a-f0-9]{32}$'){throw 'unsafe digest fixture cleanup'}
  if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}
  Write-Output "CLEANUP privateGuidRootRemoved=$(-not(Test-Path -LiteralPath $full))"
}
