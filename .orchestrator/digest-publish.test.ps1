[CmdletBinding()]param()
$ErrorActionPreference='Stop';$root=Join-Path ([IO.Path]::GetTempPath()) ('digest-test-'+[guid]::NewGuid().ToString('N'))
function Assert-Digest([bool]$c,[string]$m){if(-not$c){throw "ASSERTION FAILED: $m"}}
try{New-Item -ItemType Directory -Path $root|Out-Null;$log=Join-Path $root 'dispatch.jsonl';$cost=Join-Path $root 'cost.jsonl';$now=[datetimeoffset]::UtcNow
  $rows=@(
    [ordered]@{ts=$now.AddMinutes(-5).ToString('o');kind='dispatch';issue=4388;lane='lane-a'},
    [ordered]@{ts=$now.AddMinutes(-4).ToString('o');kind='enqueue';pr=9001},
    [ordered]@{ts=$now.AddMinutes(-3).ToString('o');kind='breaker-open';issue=1;pr=2},
    [ordered]@{ts=$now.AddMinutes(-2).ToString('o');kind='decision-filed';issue=4388},
    [ordered]@{ts=$now.AddMinutes(-1).ToString('o');kind='deploy-verified';outcome='PASS'}
  );[IO.File]::WriteAllLines($log,@($rows|ForEach-Object{$_|ConvertTo-Json -Compress}),[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($cost,([ordered]@{ts=$now.ToString('o');usd=12.5}|ConvertTo-Json -Compress)+"`n",[Text.UTF8Encoding]::new($false))
  $waiting=Join-Path $root 'waiting-on-todd.psd1';[IO.File]::WriteAllText($waiting,"@{ Repo = 'synthetic/chase-sets'; PinnedIssue = 909229; Assignee = 'synthetic-todd'; DoneWindowDays = 7 }",[Text.UTF8Encoding]::new($false))
  $body=&(Join-Path $PSScriptRoot 'digest-publish.ps1') -Tracking 4388 -DryRun -DispatchLog $log -CostLedger $cost -WaitingOnToddConfig $waiting|Out-String
  Assert-Digest ($body.Contains('**Waiting on Todd:** #909229 lists every packaged operator action') -and -not $body.Contains('Open for Todd')) 'digest does not link the synthetic pinned Waiting-on-Todd issue'
  foreach($bad in @((Join-Path $root 'absent.psd1'),$cost)){$refused=$false;try{& (Join-Path $PSScriptRoot 'digest-publish.ps1') -Tracking 4388 -DryRun -DispatchLog $log -CostLedger $cost -WaitingOnToddConfig $bad|Out-Null}catch{$refused=$true};Assert-Digest $refused 'digest rendered without a pinned Waiting-on-Todd issue'}
  Assert-Digest ($body-match'Merge queue \| 1'-and$body-match'Lanes \| 1 active'-and$body-match'Real deploy \| PASS'-and$body-match'Open breakers \| 1'-and$body-match'12\.50'-and$body-match'#4388') 'digest omitted bounded lifecycle or spend evidence'
  [IO.File]::AppendAllText($log,'{malformed'+"`n",[Text.UTF8Encoding]::new($false));$failed=$false;try{& (Join-Path $PSScriptRoot 'digest-publish.ps1') -Tracking 4388 -DryRun -DispatchLog $log -CostLedger $cost -WaitingOnToddConfig $waiting|Out-Null}catch{$failed=$true};Assert-Digest $failed 'malformed lifecycle history was rendered as success'
  Write-Output 'PASS digest renders lifecycle, deploy, breaker, decision, queue, lane, daily spend and pinned Waiting-on-Todd link evidence'
}finally{if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}}
