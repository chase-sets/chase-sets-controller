[CmdletBinding()]
param(
  [string]$ControllerRoot = (Split-Path -Parent $PSScriptRoot),
  [string]$ExpectedControllerHead = '',
  [string]$QueryScriptPath,
  [string]$LoggerScriptPath,
  [string]$EvidenceRoot = (Join-Path ([IO.Path]::GetTempPath()) ('dispatch-count-policy-'+[guid]::NewGuid().ToString('N'))),
  [ValidateSet('F1','F2','F3')][string]$RegressionOnly,
  [switch]$SkipMutants
)
$ErrorActionPreference = 'Stop'
$removeEvidence = -not $PSBoundParameters.ContainsKey('EvidenceRoot')
if ($ExpectedControllerHead) {
  $actualHead=(& git -C $ControllerRoot rev-parse HEAD | Out-String).Trim()
  if ($LASTEXITCODE -ne 0 -or $actualHead -cne $ExpectedControllerHead) { throw 'ExpectedControllerHead does not match the controller checkout' }
}
try {
$runtime = Join-Path $ControllerRoot '.orchestrator'
$query = Join-Path $runtime 'controller-skills/milestone-orchestrator/scripts/query-ledgers.ps1'
if ($QueryScriptPath) { $query=$QueryScriptPath }
$logger = Join-Path $runtime 'log-event.ps1'
if ($LoggerScriptPath) { $logger=$LoggerScriptPath }
$skillPath = Join-Path $runtime 'controller-skills/milestone-orchestrator/SKILL.md'
$scratch = Join-Path $EvidenceRoot ('fixtures-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
$historyPath = Join-Path $scratch 'synthetic.jsonl'
$script:failures = 0
$script:checks = 0
$script:effects = 0
function gh { $script:effects++; throw 'forbidden GitHub call in fixture mode' }
function Invoke-RestMethod { $script:effects++; throw 'forbidden network call in fixture mode' }
function Invoke-WebRequest { $script:effects++; throw 'forbidden network call in fixture mode' }
function Start-Process { $script:effects++; throw 'forbidden launch in fixture mode' }
function dispatch-lane.ps1 { $script:effects++; throw 'forbidden dispatch in fixture mode' }
function Assert-Policy([bool]$Value, [string]$Message) {
  $script:checks++
  if (-not $Value) { throw "ASSERTION FAILED: $Message" }
}
function Case([string]$Name, [scriptblock]$Body) {
  try { & $Body; Write-Output "PASS $Name" }
  catch { $script:failures++; Write-Output "FAIL ${Name}: $($_.Exception.Message)" }
}
function Seed([int]$Count) {
  $rows = @(for ($i=0; $i -lt $Count; $i++) {
    @{kind='dispatch';issue=908527;lane="synthetic-$i";laneRole=@('implementation','planning','review')[$i % 3];ts='2020-01-01T00:00:00Z'}
  })
  [IO.File]::WriteAllText($historyPath, (($rows | ForEach-Object { $_ | ConvertTo-Json -Compress }) -join "`n") + "`n")
}
function Add-Row($Row) { [IO.File]::AppendAllText($historyPath, ($Row | ConvertTo-Json -Depth 10 -Compress) + "`n") }
function Query([string]$Candidate='open', [string]$Authority='clear') {
  $before = (Get-FileHash $historyPath).Hash
  $result = & $query -DispatchIssue 908527 -DispatchCandidateState $Candidate -DispatchAuthority $Authority -DispatchLogPath $historyPath -RuntimeRoot $runtime | ConvertFrom-Json
  Assert-Policy ((Get-FileHash $historyPath).Hash -ceq $before) 'query must not mutate history'
  return $result
}
function Payload([string]$Phase, [string]$Dispatch='', [string]$Disposition='', [string]$Final='') {
  $p = [ordered]@{schemaVersion='dispatch-count-decision/v1';id='dispatch-count-908527-v1';phase=$Phase;count=15;lane='synthetic-decision-908527';transcript='synthetic-decision-908527.jsonl'}
  if ($Dispatch) { $p.dispatchReceiptIdentity=$Dispatch }
  if ($Disposition) { $p.disposition=$Disposition }
  if ($Final) { $p.finalReceiptIdentity=$Final }
  return ($p | ConvertTo-Json -Compress)
}
function Record([string]$Phase, [string]$Dispatch='', [string]$Disposition='', [string]$Final='') {
  $kind = if ($Phase -cin @('CLAIMED','ACKNOWLEDGED')) {'decision-filed'} else {'decision-resolved'}
  & $logger -Log dispatch -Kind $kind -Issue 908527 -DispatchDecision (Payload $Phase $Dispatch $Disposition $Final) -OutFile $historyPath -NoBoard | Out-Null
}
function Ack {
  Add-Row @{kind='dispatch';issue=908527;lane='synthetic-decision-908527';transcript='synthetic-decision-908527.jsonl';laneRole='planning'}
  $h=Read-ExactHeadReviewHistory $historyPath
  $id=$h.rows[-1].rawSha256
  Record ACKNOWLEDGED $id
  return $id
}
function Refused([scriptblock]$Body) {
  $before=(Get-FileHash $historyPath).Hash
  $refused=$false
  try { & $Body } catch { $refused=$true }
  Assert-Policy $refused 'invalid transition must be refused'
  Assert-Policy ((Get-FileHash $historyPath).Hash -ceq $before) 'refusal must preserve bytes'
}
function Test-Text([string]$Text) {
  $rules=@{
    7=@('At 15 or more dispatches without any confirmed canonical landing', 'only at the pre-dispatch moment', 'query-ledgers.ps1 -DispatchIssue', 'Never sweep closed, tracking-only or non-candidate issues', 'four-implementation-attempt ceiling remains unchanged')
    11=@('Pending and final are once-only steady states', 'log-event.ps1 -DispatchDecision', 'CLAIMED', 'ACKNOWLEDGED', 'FINAL', 'APPLYING', 'APPLIED', 'never launch a second threshold decision', 'Replan is planning work, not another decision lane', 'counsel/operator gates and Todd-only authority remain binding')
  }
  foreach ($number in $rules.Keys) {
    $section=[regex]::Match($Text,"(?ms)^## $number\..*?(?=^## \d+\.|\z)").Value -replace '\s+',' '
    foreach ($rule in $rules[$number]) { if (-not $section.Contains($rule,[StringComparison]::Ordinal)) { return $false } }
  }
  return $true
}

if (-not $RegressionOnly -or $RegressionOnly -ceq 'F1') {
Case 'F1-canonical-non-authority-rows' {
  # Verbatim canonical snapshot rows 1 and 18807 from the governing review.
  $legacy='{"at":"2026-07-16T18:15:30.1349648Z","task":"diagnose Platform Deploy run 29515204198 Deploy Staging failure","lane":"claude-agent","model":"sonnet-5","effort":"high","routingRow":10}'
  $sentinel='{"ts":"2026-09-16T14:58:23.742Z","kind":"dispatch","issue":0,"lane":"platform-iss162-pressure-r1","laneRole":"review","harness":"claude","model":"claude-opus-5","effort":"high","row":"8","placement":"provisional","transcript":"platform-iss162-pressure-r1.jsonl","outcome":"RUNNING","note":"Initial ordinary nativeDB planning pressure at90acd4c; PID15596; no native implementation authority. ExpectedUSD unknown."}'
  foreach ($prefix in @($legacy,$sentinel,'{"kind":"landed","issue":-1}')) {
    Case "F1-row-$prefix" {
    Seed 15
    [IO.File]::WriteAllText($historyPath,$prefix+"`n"+[IO.File]::ReadAllText($historyPath))
    $r=Query
    Assert-Policy ($r.state -ceq 'DUE' -and $r.dispatchCount -eq 15) 'legacy/sentinel non-authority must not poison a positive issue'
    Record CLAIMED
    Assert-Policy ((Query).state -ceq 'PENDING') 'logger accepts CLAIMED over canonical non-authority'
    }
  }
  foreach($bad in @('[]','[{}]','{"kind":null}','{"kind":17}','{"kind":"dispatch","issue":"908528"}',
      '{"kind":"dispatch","issue":1.5}','{"dispatchDecision":{}}','{"kind":"dispatch","issue":0,"dispatchDecision":{}}')) {
    Seed 15; [IO.File]::AppendAllText($historyPath,$bad+"`n")
    Assert-Policy ((Query).state -ceq 'UNKNOWN') "ambiguous history still refuses: $bad"
  }
}
}
if (-not $RegressionOnly -or $RegressionOnly -ceq 'F2') {
Case 'F2-query-and-writer-parse-outside-synthetic-lock' {
  $isolated=Join-Path $scratch 'synthetic-runtime'
  $scripts=Join-Path $isolated 'controller-skills/milestone-orchestrator/scripts'
  New-Item -ItemType Directory -Path $scripts -Force | Out-Null
  Copy-Item -LiteralPath $query -Destination (Join-Path $scripts 'query-ledgers.ps1')
  Copy-Item -LiteralPath $logger -Destination (Join-Path $isolated 'log-event.ps1')
  Copy-Item -LiteralPath (Join-Path $runtime 'routing-data.ps1') -Destination $isolated
  $mutexName='Global\ChaseSetsOrchLog-SYNTHETIC-8527-'+[guid]::NewGuid().ToString('N')
  $lockSource=[IO.File]::ReadAllText((Join-Path $runtime 'orchestration-log-lock.psm1')).Replace('Global\ChaseSetsOrchLog',$mutexName)
  [IO.File]::WriteAllText((Join-Path $isolated 'orchestration-log-lock.psm1'),$lockSource)
  $started=Join-Path $isolated 'parse-started'
  $release=Join-Path $isolated 'parse-release'
  $trace=Join-Path $isolated 'parse-bytes'
  $reader=[IO.File]::ReadAllText((Join-Path $runtime 'review-head-contract.psm1'))
  $pause=@'
  [IO.File]::AppendAllText('__TRACE__',([IO.FileInfo]::new($Path).Length.ToString())+"`n")
  if (-not [IO.File]::Exists('__STARTED__')) {
    [IO.File]::WriteAllText('__STARTED__','prefix parser entered')
    $deadline=[datetime]::UtcNow.AddSeconds(10)
    while (-not [IO.File]::Exists('__RELEASE__') -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
    if (-not [IO.File]::Exists('__RELEASE__')) { throw 'synthetic parse handshake expired' }
  }
'@
  $pause=$pause.Replace('__STARTED__',$started.Replace("'","''")).Replace('__RELEASE__',$release.Replace("'","''")).Replace('__TRACE__',$trace.Replace("'","''"))
  $reader=$reader.Replace('  $audit = [ordered]@{',$pause+"`n  `$audit = [ordered]@{")
  [IO.File]::WriteAllText((Join-Path $isolated 'review-head-contract.psm1'),$reader)
  foreach ($mode in @('query','query-append','logger','logger-tail','logger-rewrite','logger-unterminated')) {
    Case "F2-$mode" {
    Seed 15
    $initialLength=(Get-Item -LiteralPath $historyPath).Length
    foreach($marker in @($started,$release,$trace)){if(Test-Path -LiteralPath $marker){Remove-Item -LiteralPath $marker}}
    $shell=[powershell]::Create()
    $mutex=[Threading.Mutex]::new($false,$mutexName)
    $owned=$false; $acquired=$false
    try {
      [void]$shell.AddScript({param($root,$path,$mode,$payload)
        if($mode -clike 'query*') {
          & (Join-Path $root 'controller-skills/milestone-orchestrator/scripts/query-ledgers.ps1') -DispatchIssue 908527 -DispatchCandidateState open -DispatchAuthority clear -DispatchLogPath $path -RuntimeRoot $root
        } else {
          & (Join-Path $root 'log-event.ps1') -Log dispatch -Kind decision-filed -Issue 908527 -DispatchDecision $payload -OutFile $path -NoBoard
        }
      }).AddArgument($isolated).AddArgument($historyPath).AddArgument($mode).AddArgument((Payload CLAIMED))
      $pending=$shell.BeginInvoke()
      $deadline=[datetime]::UtcNow.AddSeconds(10)
      while(-not (Test-Path -LiteralPath $started) -and -not $pending.IsCompleted -and [datetime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 20}
      Assert-Policy (Test-Path -LiteralPath $started) "$mode enters the instrumented prefix parser"
      $timer=[Diagnostics.Stopwatch]::StartNew()
      $owned=$mutex.WaitOne([timespan]::FromMilliseconds(200)); $acquired=$owned
      Write-Output "F2 $mode concurrent writer acquired=$acquired waitMs=$($timer.ElapsedMilliseconds)"
      if($owned -and $mode -ceq 'logger-tail'){Add-Row @{kind='dispatch';issue=908527}}
      if($owned -and $mode -ceq 'query-append'){Add-Row @{kind='dispatch';issue=908527}}
      if($owned -and $mode -ceq 'logger-rewrite'){[IO.File]::WriteAllText($historyPath,[IO.File]::ReadAllText($historyPath).Replace('synthetic-0','synthetic-X'))}
      if($owned -and $mode -ceq 'logger-unterminated'){[IO.File]::AppendAllText($historyPath,'{"kind":"dispatch"}')}
      $before=[IO.File]::ReadAllText($historyPath)
      if($owned){$mutex.ReleaseMutex();$owned=$false}
      [IO.File]::WriteAllText($release,'release synthetic prefix parse')
      Assert-Policy ($pending.AsyncWaitHandle.WaitOne(10000)) "$mode finishes its bounded foreground probe"
      $invokeError=$null
      try { $output=$shell.EndInvoke($pending) } catch { $invokeError=$_ }
      Assert-Policy $acquired "$mode prefix parse must not hold the writer mutex"
      $parseBytes=@(Get-Content -LiteralPath $trace)
      if($mode -cin @('logger','logger-tail')) {
        $tailLength=[Text.Encoding]::UTF8.GetByteCount($before)-$initialLength
        Assert-Policy ($parseBytes.Count -eq 2 -and [long]$parseBytes[0] -eq $initialLength -and [long]$parseBytes[1] -eq $tailLength) 'locked parser sees only appended tail, never the prefix again'
      }
      if($mode -clike 'query*') {
        Assert-Policy (($output | Out-String | ConvertFrom-Json).state -ceq 'DUE') 'unlocked query remains complete'
      } elseif($mode -cin @('logger-tail','logger-rewrite','logger-unterminated')) {
        Assert-Policy (($shell.HadErrors -or $null -ne $invokeError) -and [IO.File]::ReadAllText($historyPath) -ceq $before) 'appended or changed history refuses stale claim without writing'
      } else {
        Assert-Policy (-not $shell.HadErrors -and [IO.File]::ReadAllText($historyPath).Contains('dispatchDecision')) 'logger accepts valid claim after unlocked prefix parse'
      }
    } finally {
      [IO.File]::WriteAllText($release,'release on failure')
      if($owned){$mutex.ReleaseMutex()}; $mutex.Dispose()
      $shell.Dispose()
    }
    }
  }
}
}
if (-not $RegressionOnly -or $RegressionOnly -ceq 'F3') {
Case 'F3-default-scratch-lifecycle' {
  $testPath=Join-Path $runtime 'dispatch-count-policy.test.ps1'
  $tokens=$null; $errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseFile($testPath,[ref]$tokens,[ref]$errors)
  $default=$ast.ParamBlock.Parameters.Where({$_.Name.VariablePath.UserPath -ceq 'EvidenceRoot'})[0].DefaultValue.Extent.Text
  Assert-Policy (-not $default.Contains('D:/Users/ToddS')) 'default scratch must not target a host lane evidence directory'
  # Exercise the real initialization/finally with test bodies inert, not a second suite run.
  $source=[IO.File]::ReadAllText($testPath)
  $caseFunction=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Case'},$true)
  $source=$source.Remove($caseFunction.Body.Extent.StartOffset,$caseFunction.Body.Extent.Text.Length).Insert($caseFunction.Body.Extent.StartOffset,'{ }')
  $probe=Join-Path $scratch 'scratch-lifecycle.ps1'; [IO.File]::WriteAllText($probe,$source)
  $result=& pwsh -NoProfile -File $probe -ControllerRoot $ControllerRoot -SkipMutants
  Assert-Policy ($LASTEXITCODE -eq 0) 'default lifecycle probe exits cleanly'
  $line=@($result | Where-Object {$_ -like 'dispatch-count-policy checks=*'})[-1]
  $created=($line -split ' evidence=',2)[1]
  Assert-Policy ($created -and -not (Test-Path -LiteralPath (Split-Path -Parent $created))) 'default temp root removed in finally'
  $retained=Join-Path $scratch 'explicit-evidence'
  $result=& pwsh -NoProfile -File $probe -ControllerRoot $ControllerRoot -EvidenceRoot $retained -SkipMutants
  $created=(@($result | Where-Object {$_ -like 'dispatch-count-policy checks=*'})[-1] -split ' evidence=',2)[1]
  Assert-Policy ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $created)) 'explicit evidence retains fixtures'
}
}
if (-not $RegressionOnly) {
Case 'dispatch-14-15-boundary' {
  Seed 14; $r=Query; Assert-Policy ($r.state -ceq 'BELOW_THRESHOLD' -and $r.dispatchCount -eq 14) '14 must not trigger'
  Seed 15; $r=Query; Assert-Policy ($r.state -ceq 'DUE' -and $r.action -ceq 'CLAIM_DECISION') '15 must request one decision'
  Seed 95; $r=Query; Assert-Policy ($r.state -ceq 'DUE' -and $r.dispatchCount -eq 95) 'over-threshold all-history count'
}
Case 'dispatch-role-and-alias-counting' {
  Seed 14
  Add-Row @{kind='dispatch';dispatchRoutingSchema='watchdog-dispatch-routing/v2';lane='alias'}
  Add-Row @{kind='dispatch';issue=908528}
  Add-Row @{kind='decision-filed';issue=908527}
  Add-Row @{kind='review-complete';issue=0;pr=0;model='gpt-5.6-sol';outcome='PASS'}
  Assert-Policy ((Query).dispatchCount -eq 14) 'aliases, other issues and non-dispatch rows excluded'
  Add-Row @{kind='dispatch';issue=908527;laneRole='review'}
  Assert-Policy ((Query).state -ceq 'DUE') 'every role counts'
}
Case 'dispatch-landed-control' {
  Seed 15; Add-Row @{kind='lane-complete';issue=908527;outcome='landed'}
  Assert-Policy ((Query).state -ceq 'DUE') 'lane-complete is not landing'
  Add-Row @{kind='landed';issue=908527;pr=918527;head=('a'*40)}
  for($i=0;$i -lt 16;$i++){Add-Row @{kind='dispatch';issue=908527}}
  Assert-Policy ((Query).state -ceq 'LANDED') 'any historical confirmed landing suppresses'
  Seed 15; Add-Row @{kind='landed';issue=908528;pr=918528;head=('b'*40)}
  Assert-Policy ((Query).state -ceq 'DUE') 'unrelated landing does not suppress'
}
Case 'dispatch-backlog-no-sweep' {
  Seed 95
  foreach($state in @('closed','tracking-only','not-candidate')) { Assert-Policy ((Query $state).state -ceq 'INELIGIBLE') "no sweep $state" }
  Assert-Policy ((Query 'unknown').state -ceq 'UNKNOWN') 'unknown candidate is not eligible'
}
Case 'dispatch-decision-once-pending-final-restart' {
  Seed 15
  & pwsh -NoProfile -File $logger -Log dispatch -Kind decision-filed -Issue 908527 -DispatchDecision (Payload CLAIMED) -OutFile $historyPath -NoBoard | Out-Null
  Assert-Policy ($LASTEXITCODE -eq 0) 'real CLI producer accepts the issue without rounding/coercing malformed identity'
  foreach($i in 1..3){$r=Query; Assert-Policy ($r.state -ceq 'PENDING' -and $r.action -ceq 'RECONCILE_DECISION' -and $r.decision.id -ceq 'dispatch-count-908527-v1') 'claim interruption/restart preserves identity'}
  $r=& pwsh -NoProfile -File $query -DispatchIssue 908527 -DispatchCandidateState open -DispatchAuthority clear -DispatchLogPath $historyPath -RuntimeRoot $runtime | ConvertFrom-Json
  Assert-Policy ($LASTEXITCODE -eq 0 -and $r.state -ceq 'PENDING') 'fresh host process recovers pending claim'
  Refused { Record CLAIMED }
  $dispatch=Ack
  Assert-Policy ((Query).state -ceq 'PENDING') 'acknowledged is not FINAL'
  Record FINAL $dispatch REPLAN
  foreach($i in 1..3){Assert-Policy ((Query).action -ceq 'CLAIM_APPLICATION') 'final never requests another decision'}
  Refused { Record FINAL $dispatch PARK }
  Seed 15; Record CLAIMED
  Add-Row @{kind='dispatch';issue=908527;lane='synthetic-decision-908527';transcript='synthetic-decision-908527.jsonl';laneRole='planning'}
  Assert-Policy ((Query).action -ceq 'RECONCILE_DECISION') 'launch before ack interruption never relaunches'
  Add-Row @{kind='dispatch';issue=908527;lane='synthetic-decision-908527';transcript='synthetic-decision-908527.jsonl';laneRole='planning'}
  Assert-Policy ((Query).state -ceq 'UNKNOWN') 'ambiguous launches cannot supply ack authority'
}
Case 'dispatch-final-disposition-and-authority-controls' {
  foreach($outcome in @('REPLAN','PARK')) {
    Seed 15; Record CLAIMED; $dispatch=Ack; Record FINAL $dispatch $outcome
    $r=Query; $final=$r.finalReceiptIdentity
    Assert-Policy ($r.state -ceq 'FINAL' -and $r.decision.disposition -ceq $outcome) 'final disposition is explicit'
    Assert-Policy ($r.applicationId -ceq "dispatch-count-908527-v1-$($outcome.ToLowerInvariant())") 'effect identity is stable across claim and restart'
    Record APPLYING $dispatch $outcome $final
    foreach($i in 1..3){Assert-Policy ((Query).action -ceq 'RECONCILE_APPLICATION') 'application crash cannot blindly repeat effect'}
    Record APPLIED $dispatch $outcome $final
    foreach($i in 1..3){Assert-Policy ((Query).action -ceq 'NONE') 'applied steady state'}
    Refused { Record APPLYING $dispatch $outcome $final }
  }
  foreach($authority in @('terminal-park','attempt-ceiling','counsel','operator','todd','unknown')) {
    Seed 15; $r=Query 'open' $authority
    Assert-Policy ($r.action -ceq 'NONE' -and $r.requiresOrdinaryAdmission -eq $true) "authority $authority must win"
    Record CLAIMED; $dispatch=Ack; Record FINAL $dispatch REPLAN
    Assert-Policy ((Query 'open' $authority).action -ceq 'NONE') "final cannot override $authority"
  }
  # Any accidental effect in the query fails the query calls above, not just this counter.
  Assert-Policy ($script:effects -eq 0) 'fixture queries dispatch/mutate nothing'
}
Case 'dispatch-incomplete-history-controls' {
  Seed 15
  . $query -Library
  $h=Read-ExactHeadReviewHistory -Path $historyPath -MaxRows 14
  $r=Get-DispatchCountDecision -History $h -Issue 908527 -CandidateState open -Authority clear
  Assert-Policy ($r.state -ceq 'UNKNOWN' -and $null -eq $r.dispatchCount) 'decisive 15th row beyond cap cannot report below threshold'
  $h=Read-ExactHeadReviewHistory -Path $historyPath -MaxBytes 10
  Assert-Policy ((Get-DispatchCountDecision $h 908527 open clear).state -ceq 'UNKNOWN') 'byte cap'
  foreach($tail in @('{bad json', '{"kind":"landed","issue":908527}', '{"kind":"decision-resolved","issue":908527,"dispatchDecision":{}}', '{"kind":"dispatch","issue":908527,"issue":908528}', '[]')) {
    Seed 15; [IO.File]::AppendAllText($historyPath,$tail+"`n")
    $r=Query; Assert-Policy ($r.state -ceq 'UNKNOWN' -and $null -eq $r.dispatchCount) "malformed authority $tail"
  }
  Seed 15; [IO.File]::WriteAllText($historyPath,[IO.File]::ReadAllText($historyPath).TrimEnd("`n"))
  Assert-Policy ((Query).state -ceq 'UNKNOWN') 'unterminated tail'
  Seed 15; Record CLAIMED
  Refused { Record FINAL ('a'*64) REPLAN }
  Refused { Record ACKNOWLEDGED ('a'*64) }
  Refused { Record APPLIED ('a'*64) PARK ('b'*64) }
  Seed 14; Refused { Record CLAIMED }
  Seed 16; Refused { Record CLAIMED }
  Seed 15
  Refused { & $logger -Log dispatch -Kind decision-filed -Issue 908527 -DispatchDecision ((Payload CLAIMED).Replace('"count":15','"count":15,"count":15')) -OutFile $historyPath -NoBoard }
  $before=[IO.File]::ReadAllText($historyPath)
  $p=Payload CLAIMED | ConvertFrom-Json; $p.phase='FINAL'; $p | Add-Member dispatchReceiptIdentity ('a'*64); $p | Add-Member disposition REPLAN
  Add-Row @{kind='decision-resolved';issue=908527;dispatchDecision=$p}
  Assert-Policy ((Query).state -ceq 'UNKNOWN') 'unpaired final is not complete'
  [IO.File]::WriteAllText($historyPath,$before)
}
Case 'dispatch-policy-and-guard-omission-mutants' {
  $text=[IO.File]::ReadAllText($skillPath)
  Assert-Policy (Test-Text $text) 'sections 7/11 must bind real query and lifecycle'
  foreach($clause in @('At 15 or more dispatches without any confirmed canonical landing','Pending and final are once-only steady states')) {
    Assert-Policy (-not (Test-Text ($text.Replace($clause,'')))) "policy omission killed: $clause"
    Write-Output "KILLED policy: $clause"
  }
}
if (-not $SkipMutants -and $script:failures -eq 0) {
  Case 'dispatch-scripted-guard-omission-mutants' {
    $source=[IO.File]::ReadAllText($query)
    $mutants=@(
      @('threshold', '$count -ge 15', '$count -ge 16'),
      @('event-kind', '$row.kind -ceq ''dispatch''', '$row.kind -cin @(''dispatch'',''decision-filed'')'),
      @('landing', '} elseif ($landed) {', '} elseif ($false) {'),
      @('idempotency', '} elseif ($null -ne $decision) {', '} elseif ($false) {'),
      @('completeness', '-or -not $History.complete', '-or $false'),
      @('candidate', "if (`$CandidateState -cin @('closed','tracking-only','not-candidate'))", 'if ($false)'),
      @('authority', "} elseif (`$Authority -cne 'clear') {", '} elseif ($false) {'),
      @('legacy-non-authority', "if (`$null -eq `$row.PSObject.Properties['kind'] -and -not `$hasDecision) { continue }", 'if ($false) { continue }'),
      @('sentinel-non-authority', 'if (-not $hasDecision -and ($row.issue -is [int] -or $row.issue -is [long]) -and $row.issue -lt 1) { continue }', 'if ($false) { continue }')
    )
    foreach($m in $mutants) {
      Assert-Policy ($m.Count -eq 3) 'mutant has name, target and replacement'
      $changed=$source.Replace($m[1],$m[2])
      Assert-Policy ($changed -cne $source) "mutant target found: $($m[0])"
      $tokens=$null; $errors=$null
      [void][Management.Automation.Language.Parser]::ParseInput($changed,[ref]$tokens,[ref]$errors)
      Assert-Policy ($errors.Count -eq 0) "mutant parses: $($m[0])"
      $path=Join-Path $scratch ("mutant-$($m[0]).ps1")
      [IO.File]::WriteAllText($path,$changed)
      $log=Join-Path $scratch ("mutant-$($m[0]).log")
      & pwsh -NoProfile -File $PSCommandPath -ControllerRoot $ControllerRoot -EvidenceRoot $scratch -QueryScriptPath $path -SkipMutants *> $log
      Assert-Policy ($LASTEXITCODE -eq 1) "mutant survived: $($m[0])"
      Assert-Policy ([IO.File]::ReadAllText($log).Contains('ASSERTION FAILED:')) "mutant must fail an assertion, not crash: $($m[0])"
      Write-Output "KILLED runtime: $($m[0]) log=$log"
    }
    $writer=[IO.File]::ReadAllText($logger)
    $changed=$writer.Replace('if ($dispatchDecisionPresent) { & {','if ($false) { & {')
    Assert-Policy ($changed -cne $writer) 'writer omission target exists'
    # Relocate only this synthetic mutant's existing dependency paths, never a live writer.
    $changed=$changed.Replace('$PSScriptRoot',("'"+$runtime.Replace("'","''")+"'"))
    $path=Join-Path $scratch 'mutant-writer-transition.ps1'
    $log=Join-Path $scratch 'mutant-writer-transition.log'
    [IO.File]::WriteAllText($path,$changed)
    & pwsh -NoProfile -File $PSCommandPath -ControllerRoot $ControllerRoot -EvidenceRoot $scratch -LoggerScriptPath $path -SkipMutants *> $log
    Assert-Policy ($LASTEXITCODE -eq 1 -and [IO.File]::ReadAllText($log).Contains('ASSERTION FAILED: invalid transition must be refused')) 'writer omission must fail refusal assertion'
    Write-Output "KILLED runtime: writer-transition log=$log"
  }
}
Write-Output "dispatch-count-policy checks=$script:checks failures=$script:failures evidence=$scratch"
}
if ($RegressionOnly) { Write-Output "dispatch-count-regression $RegressionOnly checks=$script:checks failures=$script:failures evidence=$scratch" }
if($script:failures){exit 1}
} finally {
  if ($removeEvidence -and (Test-Path -LiteralPath $EvidenceRoot)) {
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    $owned=[IO.Path]::GetFullPath($EvidenceRoot)
    if (-not $owned.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($owned) -notmatch '^dispatch-count-policy-[a-f0-9]{32}$') { throw 'scratch cleanup escaped the owned temp root' }
    Remove-Item -LiteralPath $owned -Recurse -Force
  }
}
