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
}finally{if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}}
