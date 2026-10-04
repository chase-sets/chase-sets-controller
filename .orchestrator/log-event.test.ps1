[CmdletBinding()]param([switch]$AuthorityOnly,[switch]$RetiredOnly,[switch]$StrictOnly,[switch]$BoardOnly)
$ErrorActionPreference='Stop';$logger=Join-Path $PSScriptRoot 'log-event.ps1';$root=Join-Path ([IO.Path]::GetTempPath()) ('log-event-test-'+[guid]::NewGuid().ToString('N'))
. (Join-Path $PSScriptRoot 'routing-data-test-support.ps1')
$routingTestScope=Enter-RoutingDataTestScope
function Assert-Log([bool]$c,[string]$m){if(-not$c){throw "ASSERTION FAILED: $m"}}
function Assert-Refused([scriptblock]$Body,[string]$Pattern){$message='';try{&$Body}catch{$message=$_.Exception.Message};Assert-Log ($message-match$Pattern) "expected refusal $Pattern, observed $message"}
function Test-StrictControllerWriter {
  Import-Module (Join-Path $PSScriptRoot 'review-head-contract.psm1') -Force -DisableNameChecking
  $failures=[Collections.Generic.List[string]]::new()
  function Check-Strict([string]$Name,[scriptblock]$Body) {
    try { & $Body; Write-Output "PASS $Name" }
    catch { $failures.Add("${Name}: $($_.Exception.Message)"); Write-Output "FAIL ${Name}: $($_.Exception.Message)" }
  }
  $strictLog=Join-Path $root 'strict.jsonl'
  $seed=[Text.Encoding]::UTF8.GetBytes("{`"kind`":`"synthetic-history`"}`r`n`n")
  $base=@{Log='dispatch';Issue=908064;ControllerHead=('a'*40);Lane='synthetic-8064-review';LaneRole='review';Harness='codex';Model='gpt-6.1-sol';AuthorModel='gpt-6-astra';Effort='high';Row='11';Placement='provisional';Transcript='synthetic-8064.jsonl';ReviewerAttempt='synthetic-reviewer';AuthorAttempt='synthetic-author';ReviewAuthority='governing';OutFile=$strictLog;NoBoard=$true}
  $terminal=@{Outcome='PASS';ReviewContract='review-contract/v2';CompleteSweep=$true;Blocking=0;Candidates=0;NonBlocking=0}
  $templates=@{}
  foreach($kind in @('dispatch','review-complete')) {
    [IO.File]::WriteAllBytes($strictLog,$seed)
    $args=$base.Clone();$args.Kind=$kind
    if($kind-ceq'review-complete'){foreach($key in $terminal.Keys){$args[$key]=$terminal[$key]}}
    & $logger @args | Out-Null
    $templates[$kind]=(Get-Content $strictLog -Tail 1)|ConvertFrom-Json -DateKind String
    Assert-Log ((Get-ControllerReviewRowClassification $templates[$kind]).valid) 'synthetic baseline must classify valid'
  }
  foreach($kind in @('dispatch','review-complete')) {
    $historical=$templates[$kind].PSObject.Copy();$historical.effort='minimal'
    Assert-Log ((Get-ControllerReviewRowClassification $historical).valid) 'v2.86 minimal-effort controller evidence must remain readable'
    $historical.effort='ultra'
    Assert-Log (-not (Get-ControllerReviewRowClassification $historical).valid) 'controller evidence must refuse efforts outside the closed vocabulary'
  }
  # These writer-admitted values are red at the pinned baseline. Expected codes
  # come from the authoritative classifier applied to the same varied final row.
  $newCases=@(
    @{Field='Placement';Value='override-Todd'}, @{Field='Effort';Value='High'},
    @{Field='Row';Value='0'}, @{Field='Row';Value='16'}, @{Field='Row';Value='not-a-row'}, @{Field='Row';Value='2147483648'},
    @{Field='Harness';Value='Codex'}, @{Field='ReviewAuthority';Value='Governing'}, @{Field='ControllerHead';Value=('A'*40)},
    @{Field='Lane';Value="synthetic`nlane"}, @{Field='Lane';Value=('x'*1025)},
    @{Field='Transcript';Value="synthetic`rtranscript"}, @{Field='Transcript';Value=('x'*1025)}
  )
  foreach($kind in @('dispatch','review-complete')) {
    $label=if($kind-ceq'dispatch'){'strict-dispatch-refuses-classifier-invalid'}else{'strict-terminal-refuses-classifier-invalid'}
    $cases=@($newCases)
    if($kind-ceq'review-complete'){$cases+=@(@{Field='Outcome';Value='SKIP'},@{Field='Outcome';Value='pass'},@{Field='ReviewContract';Value='Review-contract/v2'})}
    foreach($case in $cases) {
      Check-Strict "$label/$($case.Field)/$($cases.IndexOf($case))" {
        $args=$base.Clone();$args.Kind=$kind
        if($kind-ceq'review-complete'){foreach($key in $terminal.Keys){$args[$key]=$terminal[$key]}}
        $args[$case.Field]=$case.Value
        $row=$templates[$kind]|ConvertTo-Json -Depth 20|ConvertFrom-Json -DateKind String
        $row.($case.Field)=$case.Value
        $expected=@((Get-ControllerReviewRowClassification $row).errors)
        Assert-Log ($expected.Count-gt0) 'matrix input is not classifier-invalid'
        [IO.File]::WriteAllBytes($strictLog,$seed)
        $message='';try{& $logger @args|Out-Null}catch{$message=$_.Exception.Message}
        foreach($code in $expected){Assert-Log ($message.Contains($code)) "expected-code=$code observed-message=$message"}
        Assert-Log ([Linq.Enumerable]::SequenceEqual($seed,[IO.File]::ReadAllBytes($strictLog))) 'refusal changed ledger bytes, length or newline'
        Write-Output "CONTROL $kind $($case.Field) expected-code=$($expected-join',') observed-code=$($expected-join',') bytes=$($seed.Length)"
      }
    }
  }
  # Already-refused controls exercise the existing parameter/preflight boundary,
  # not the new guard; retain its diagnostics rather than claiming baseline-red.
  $earlyCases=@(
    @{Field='Model';RowField='reviewerModel';Value='not-a-model';Pattern='exact selectable model'},
    @{Field='AuthorModel';RowField='authorModel';Value='not-a-model';Pattern='exact selectable model'},
    @{Field='ReviewerAttempt';RowField='reviewerAttempt';Value='bad attempt';Pattern='validate argument'},
    @{Field='AuthorAttempt';RowField='authorAttempt';Value='bad attempt';Pattern='validate argument'},
    @{Field='ReviewerAttempt';RowField='reviewerAttempt';Value='synthetic-author';Pattern='distinct attempts'},
    @{Field='ReviewAuthority';RowField='reviewAuthority';Value='unknown';Pattern='validate argument'},
    @{Field='Issue';RowField='issue';Value=0;Pattern='positive -Issue'}
  )
  foreach($kind in @('dispatch','review-complete')) {
    $cases=@($earlyCases)
    if($kind-ceq'review-complete'){$cases+=@(
      @{Field='ReviewContract';RowField='reviewContract';Value='invalid';Pattern='validate argument'},
      @{Field='CompleteSweep';RowField='completeSweep';Value=$false;Pattern='CompleteSweep'},
      @{Field='Candidates';RowField='findings.candidates';Value=10001;Pattern='bounded'},
      @{Field='NonBlocking';RowField='findings.nonBlocking';Value=-1;Pattern='bounded'},
      @{Field='FindingIds';RowField='findingIds';Value=@('bad');Pattern='stable uppercase'},
      @{Field='FindingIds';RowField='findingIds';Value=@('F1','F1');Pattern='duplicate'},
      @{Field='Outcome';RowField='outcome';Value='BLOCK_REPLAN';Pattern='one stable -FindingIds'}
    )}
    foreach($case in $cases){Check-Strict "already-refused/$kind/$($case.Field)/$($cases.IndexOf($case))" {
      $parameters=$base.Clone();$parameters.Kind=$kind
      if($kind-ceq'review-complete'){foreach($key in $terminal.Keys){$parameters[$key]=$terminal[$key]}}
      $parameters[$case.Field]=$case.Value
      $row=$templates[$kind]|ConvertTo-Json -Depth 20|ConvertFrom-Json -DateKind String
      if($case.RowField.StartsWith('findings.')){$row.findings.($case.RowField.Split('.')[1])=$case.Value}else{$row.($case.RowField)=$case.Value}
      $expected=@((Get-ControllerReviewRowClassification $row).errors)
      Assert-Log ($expected.Count-gt0) 'early-control field is not classifier-invalid'
      [IO.File]::WriteAllBytes($strictLog,$seed)
      Assert-Refused {& $logger @parameters|Out-Null} $case.Pattern
      Assert-Log ([Linq.Enumerable]::SequenceEqual($seed,[IO.File]::ReadAllBytes($strictLog))) 'early refusal changed ledger bytes'
      Write-Output "CONTROL already-refused classifier-code=$($expected-join',') existing-diagnostic=$($case.Pattern)"
    }}
  }
  foreach($placement in @('override-Todd','override-todd','measured','provisional')) {
    [IO.File]::WriteAllBytes($strictLog,$seed)
    $parameters=$base.Clone();$parameters.Placement=$placement
    foreach($kind in @('dispatch','review-complete')) {
      Check-Strict "strict-placement-case-controls/$kind/$placement" {
        $parameters.Kind=$kind
        if($kind-ceq'review-complete'){foreach($key in $terminal.Keys){$parameters[$key]=$terminal[$key]}}
        if($placement-ceq'override-Todd'){
          Assert-Refused {& $logger @parameters|Out-Null} 'INVALID_PLACEMENT'
          Assert-Log ([Linq.Enumerable]::SequenceEqual($seed,[IO.File]::ReadAllBytes($strictLog))) "$kind uppercase changed ledger"
        }else{
          & $logger @parameters|Out-Null
          $h=Read-ExactHeadReviewHistory $strictLog
          Assert-Log ((Get-ControllerReviewRowClassification $h.rows[-1]).valid) "$kind $placement invalid after append"
          $r=Reduce-ControllerReleaseReview -Issue $base.Issue -ControllerHead $base.ControllerHead -Mode strict-v1 -History $h
          Assert-Log ($r.state-ceq$(if($kind-ceq'dispatch'){'in-flight'}else{'authorized'})) "$kind $placement reduced to $($r.state)"
        }
      }
    }
  }
  Check-Strict 'ordinary-author-uppercase-preserved' {
    [IO.File]::WriteAllBytes($strictLog,$seed)
    & $logger -Log dispatch -Kind dispatch -Issue 908064 -Lane synthetic-author -LaneRole implementation -Harness codex -Model gpt-6-astra -Effort high -Row 7 -Placement override-Todd -Transcript synthetic-author.jsonl -OutFile $strictLog -NoBoard|Out-Null
    $row=(Get-Content $strictLog -Tail 1)|ConvertFrom-Json -DateKind String
    Assert-Log ($row.placement-ceq'override-Todd'-and$row.model-ceq'gpt-6-astra'-and$row.row-ceq'7'-and-not(Get-ControllerReviewRowClassification $row).strict) 'ordinary author tuple changed'
  }
  Check-Strict 'skip-strict-classifier-before-append' {
    $mutantRoot=Join-Path $root 'skip-strict-classifier-before-append';New-Item -ItemType Directory $mutantRoot|Out-Null
    foreach($file in @('log-event.ps1','orchestration-log-lock.psm1','review-head-contract.psm1','routing-data.ps1')){Copy-Item (Join-Path $PSScriptRoot $file) $mutantRoot}
    $mutant=Join-Path $mutantRoot 'log-event.ps1';$source=[IO.File]::ReadAllText($mutant)
    $anchor='if ($strictController -and -not $controllerCorrection) {'
    Assert-Log ($source.Split(@($anchor),[StringSplitOptions]::None).Count-eq2) 'strict classifier bypass anchor must occur exactly once'
    [IO.File]::WriteAllText($mutant,$source.Replace($anchor,'if ($false) {'))
    foreach($kind in @('dispatch','review-complete')) {
      foreach($case in @(@{Field='Placement';Value='override-Todd'},@{Field='Effort';Value='High'})) {
        $parameters=$base.Clone();$parameters.Kind=$kind;$parameters[$case.Field]=$case.Value
        if($kind-ceq'review-complete'){foreach($key in $terminal.Keys){$parameters[$key]=$terminal[$key]}}
        [IO.File]::WriteAllBytes($strictLog,$seed)
        & $mutant @parameters|Out-Null
        $h=Read-ExactHeadReviewHistory $strictLog
        Assert-Log ($h.rows.Count-eq2-and(Get-Content $strictLog).Count-eq3) 'bypass did not append exactly one row'
        $codes=@((Get-ControllerReviewRowClassification $h.rows[-1]).errors)
        Assert-Log ($codes.Count-eq1-and$codes[0]-ceq$(if($case.Field-ceq'Placement'){'INVALID_PLACEMENT'}else{'INVALID_EFFORT'})) 'bypass failed for unrelated input'
        $after=[IO.File]::ReadAllBytes($strictLog)
        Assert-Log ([Linq.Enumerable]::SequenceEqual($seed,[byte[]]$after[0..($seed.Length-1)])) 'bypass changed existing prefix'
        [IO.File]::WriteAllBytes($strictLog,$seed)
        Assert-Refused {& $logger @parameters|Out-Null} $codes[0]
        Assert-Log ([Linq.Enumerable]::SequenceEqual($seed,[IO.File]::ReadAllBytes($strictLog))) 'candidate changed same-input ledger'
        Write-Output "CONTROL skip-strict-classifier-before-append $kind $($case.Field): mutant appended=1; candidate=$($codes[0]) appended=0"
      }
    }
  }
  Assert-Log ($failures.Count-eq0) ($failures-join"`n")
}
function Test-BoardLogger {
  $entryBoardSync = $env:ORCH_BOARD_SYNC
  $env:ORCH_BOARD_SYNC = '1'
  try {
  . (Join-Path $PSScriptRoot 'board-reconcile.test.ps1') -FunctionsOnly
  foreach ($case in @('NoBoard','issue-less','disabled','failure')) {
    $caseRoot = Join-Path $root "board-bypass-$case"; [void][IO.Directory]::CreateDirectory($caseRoot)
    $caseLog = Join-Path $caseRoot 'dispatch.jsonl'
    $marker = Join-Path $caseRoot 'board-called'
    $failure = Join-Path $caseRoot 'board.ps1'
    [IO.File]::WriteAllText($failure, "[IO.File]::WriteAllText('$($marker.Replace("'","''"))','called'); throw 'synthetic board failure'")
    $parameters = @{ Log = 'dispatch'; Kind = 'lane-complete'; LaneRole = 'implementation'; OutFile = $caseLog; BoardScript = $failure }
    if ($case -ne 'issue-less') { $parameters.Issue = 908548 }
    if ($case -eq 'NoBoard') { $parameters.NoBoard = $true }
    $env:ORCH_BOARD_SYNC = if ($case -eq 'disabled') { '0' } else { '1' }
    $warnings = @()
    & $logger @parameters -WarningVariable warnings -WarningAction SilentlyContinue | Out-Null
    $rows = @(Get-Content $caseLog | ConvertFrom-Json)
    Assert-Log ($rows.Count -eq 1 -and $rows[0].kind -eq 'lane-complete') "$case committed append survives"
    Assert-Log ((Test-Path $marker) -eq ($case -eq 'failure')) "$case board invocation/zero-history bypass"
    Assert-Log (($warnings.Count -gt 0) -eq ($case -eq 'failure')) "$case fail-open warning"
    Write-Output "PASS board-bookkeeping-$case append=1"
  }
  $env:ORCH_BOARD_SYNC = '1'
  $forward = Join-Path $root 'forward.ps1'; $capture = Join-Path $root 'forward.json'
  [IO.File]::WriteAllText($forward, "param(`$Issue,`$EventKind,`$LaneRole,`$Outcome,`$ReviewAuthority,`$Pr)`n[IO.File]::WriteAllText('$($capture.Replace("'","''"))',(`$PSBoundParameters | ConvertTo-Json))")
  $previousBoardSync = $env:ORCH_BOARD_SYNC
  try {
    $env:ORCH_BOARD_SYNC = '0'
    $suppressedLog = Join-Path $root 'board-suppressed.jsonl'
    & $logger -Log dispatch -Kind lane-complete -Issue 908478 -LaneRole implementation -Pr 909478 -OutFile $suppressedLog -BoardScript $forward | Out-Null
    Assert-Log (-not (Test-Path $capture)) 'ORCH_BOARD_SYNC=0 suppresses board projection'
    $suppressedRows = @(Get-Content $suppressedLog | ConvertFrom-Json)
    Assert-Log ($suppressedRows.Count -eq 1 -and $suppressedRows[0].kind -eq 'lane-complete' -and $suppressedRows[0].pr -eq 909478) 'ORCH_BOARD_SYNC=0 preserves the event append'
    Write-Output 'PASS ORCH_BOARD_SYNC=0 suppresses projection and preserves append'
  } finally { $env:ORCH_BOARD_SYNC = $previousBoardSync }
  try {
    Remove-Item Env:ORCH_BOARD_SYNC -ErrorAction SilentlyContinue
    & $logger -Log dispatch -Kind lane-complete -Issue 908478 -LaneRole implementation -Pr 909478 -OutFile (Join-Path $root 'board-forward.jsonl') -BoardScript $forward | Out-Null
  } finally { $env:ORCH_BOARD_SYNC = $previousBoardSync }
  Assert-Log ((Get-Content $capture -Raw | ConvertFrom-Json).Pr -eq 909478) 'positive Pr forwarded to board-set'
  Write-Output 'PASS positive Pr forwarding'
  foreach ($kind in @('dispatch', 'review-complete')) {
    foreach ($outcome in $(if ($kind -eq 'dispatch') { @('') } else { @('PASS','BLOCK_FIXABLE','BLOCK_REPLAN') })) {
      foreach ($withPr in @($false, $true)) {
        $f = New-BoardFixture (Join-Path $root "board-$kind-$outcome-$withPr") @((New-BoardItem 908478))
        $null = Add-BoardAttempt $f 908478 'implementation'
        $null = Add-BoardAttempt $f 908478 'review' 'review'
        $wrapper = Join-Path $f.root 'board.ps1'
        $board = Join-Path $PSScriptRoot 'board-set.ps1'
        [IO.File]::WriteAllText($wrapper, "param(`$Issue,`$EventKind,`$LaneRole,`$Outcome,`$ReviewAuthority,`$Pr)`n& '$($board.Replace("'","''"))' @PSBoundParameters -DispatchLog '$($f.log.Replace("'","''"))' -GhCommand '$($f.gh.Replace("'","''"))' -Strict")
        $parameters = @{ Log='dispatch'; Kind=$kind; Issue=908478; Lane='synthetic-review'; LaneRole='review'; Transcript='review.jsonl'
          Harness='codex'; Model='gpt-6.1-sol'; AuthorModel='gpt-6-astra'; Effort='high'; Row='11'; Placement='provisional'
          ControllerHead=('a'*40); ReviewerAttempt='synthetic-reviewer'; AuthorAttempt='synthetic-author'; ReviewAuthority='governing'
          OutFile=$f.log; BoardScript=$wrapper }
        if ($withPr) { $parameters.Pr = 909478 }
        if ($kind -eq 'review-complete') {
          $parameters.Outcome=$outcome; $parameters.ReviewContract='review-contract/v2'; $parameters.CompleteSweep=$true
          $parameters.Blocking=0; $parameters.Candidates=0; $parameters.NonBlocking=0
          if ($outcome -like 'BLOCK*') { $parameters.Blocking=1; $parameters.Candidates=1; $parameters.FindingIds=@('F1') }
          if ($outcome -eq 'BLOCK_FIXABLE') { $parameters.RepairOwner='author' }
          if ($outcome -eq 'BLOCK_REPLAN') { $parameters.RepairOwner='planning-repair' }
        }
        $warnings = @()
        $previousBoardSync = $env:ORCH_BOARD_SYNC
        try {
          Remove-Item Env:ORCH_BOARD_SYNC -ErrorAction SilentlyContinue
          & $logger @parameters -WarningVariable warnings | Out-Null
        } finally { $env:ORCH_BOARD_SYNC = $previousBoardSync }
        Assert-Log ($warnings.Count -eq 0) "real logger board path did not fail open: $warnings"
        $items = @(Get-Content $f.data -Raw | ConvertFrom-Json)
        Assert-Log ($items[0].status.name -eq 'In lane') "concurrent implementation survives $kind/$outcome/Pr=$withPr"
        Assert-Log ((Get-BoardCalls $f 'mutation').Count -eq 0) 'review never demotes live implementation'
        Write-Output "PASS real logger concurrent implementation + $kind/$outcome/Pr=$withPr"
      }
    }
  }
  } finally { $env:ORCH_BOARD_SYNC = $entryBoardSync }
}
try{New-Item -ItemType Directory -Path $root|Out-Null;$log=Join-Path $root 'events.jsonl';$head='a'*40
  $snapshot=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'controller-skills/model-routing/capability-matrix.json') | ConvertFrom-Json
  $fixture=New-RoutingMatrixFixture -Root (Join-Path $root 'routing-state') -Snapshot $snapshot -BenchmarkRows @(New-RoutingCostBenchmarkRows)
  $env:CHASE_SETS_ROUTING_DATA_ROOT=$fixture.stateRoot;$env:CHASE_SETS_ROUTING_LKG_PATH=$fixture.lkgPath
  if(-not $AuthorityOnly -and -not $RetiredOnly -and -not $StrictOnly){
    $boardSyncBeforeTest = $env:ORCH_BOARD_SYNC
    Test-BoardLogger
    Assert-Log ($env:ORCH_BOARD_SYNC -ceq $boardSyncBeforeTest) 'board tests restore ambient ORCH_BOARD_SYNC'
    if($BoardOnly){return}
  }
  if(-not $AuthorityOnly -and -not $RetiredOnly){Test-StrictControllerWriter;if($StrictOnly){return}}
  foreach($model in @('gpt-5.6-luna','gpt-5.6-terra','gpt-5.6-sol','claude-opus-5','claude-sonnet-5','gpt-6-sol')){
    Assert-Refused {& $logger -Log dispatch -Kind dispatch -Issue 8156 -Lane synthetic -LaneRole implementation -Harness $(if($model-like'claude-*'){'claude'}else{'codex'}) -Model $model -Effort high -Row 4 -Placement provisional -Transcript synthetic.jsonl -OutFile $log -NoBoard|Out-Null} "$model.*retired"
    Assert-Log (-not(Test-Path $log)) "retired $model wrote a row"
  }
  foreach($field in @('Model','AuthorModel')){
    $retiredArgs=@{Log='dispatch';Kind='verify-complete';Outcome='PASS';Model='claude-sonnet-5-5';AuthorModel='gpt-6.1-sol';OutFile=$log;NoBoard=$true}
    $retiredArgs[$field]='claude-sonnet-5'
    Assert-Refused {& $logger @retiredArgs|Out-Null} 'claude-sonnet-5.*retired'
    Assert-Log (-not(Test-Path $log)) "retired Sonnet $field wrote a terminal row"
    $retiredArgs=@{Log='dispatch';Kind='verify-complete';Outcome='PASS';Model='claude-sonnet-5-5';AuthorModel='gpt-6.1-sol';OutFile=$log;NoBoard=$true}
    $retiredArgs[$field]='gpt-6-sol'
    Assert-Refused {& $logger @retiredArgs|Out-Null} 'gpt-6-sol.*retired'
    Assert-Log (-not(Test-Path $log)) "retired Sol 6 $field wrote a terminal row"
  }
  if($RetiredOnly){Write-Output 'PASS retired dispatch and terminal selectors refused without writing';return}
  # Synthetic authority lifecycle, through the sole producer, never live history.
  $authorityLog=Join-Path $root 'synthetic-authority.jsonl'
  $binding=@{Log='dispatch';Kind='rule-change';IntegrationAuthoritySchema='landed-integration-authority/v1';Pr=908132;Issue=908130;TargetBranch='synthetic/terminal';LineageRoot='synthetic/lineage';TargetHead=$head;OutFile=$authorityLog}
  & $logger @binding -AuthorityState ELIGIBLE | Out-Null
  Import-Module (Join-Path $PSScriptRoot 'review-head-contract.psm1') -Force -DisableNameChecking
  function Read-Authority { Reduce-LandedIntegrationAuthority -History (Read-ExactHeadReviewHistory $authorityLog) -Pr 908132 -Branch 'synthetic/terminal' -Head $head }
  Assert-Log ((Read-Authority).state-ceq'ELIGIBLE') 'initial exact-head eligibility missing'
  Assert-Refused {& $logger @binding -AuthorityState ELIGIBLE|Out-Null} 'AUTHORITY_DUPLICATE'
  $citation=@{AuthorityIssue=908130;AuthorityCommentId=9000000001;OperatorAuthority='Todd:908130#9000000001';Note='Synthetic ruling read 2026-09-23T00:00:00Z: terminal stop'}
  & $logger @binding @citation -AuthorityState STOP | Out-Null
  $stop=(Read-ExactHeadReviewHistory $authorityLog).rows[-1].rawSha256
  & $logger @binding -AuthorityState ELIGIBLE | Out-Null
  Assert-Log ((Read-Authority).state-ceq'STOP'-and(Read-Authority).authorityRows[0]-ceq$stop) 'STOP-only window must accept ELIGIBLE but never admit'
  $citation.AuthorityCommentId=9000000002;$citation.OperatorAuthority='Todd:908130#9000000002';$citation.Note='Synthetic ruled planning-repair/v1 release read 2026-09-23T00:00:01Z'
  & $logger @binding @citation -AuthorityState RELEASE -Supersedes $stop | Out-Null
  Assert-Log ((Read-Authority).state-ceq'UNKNOWN') 'RELEASE alone admitted'
  & $logger @binding -AuthorityState ELIGIBLE | Out-Null
  Assert-Log ((Read-Authority).state-ceq'ELIGIBLE') 'same-head null-pair re-entry refused'
  Assert-Refused {& $logger @binding -AuthorityState ELIGIBLE|Out-Null} 'AUTHORITY_DUPLICATE'
  Assert-Refused {& $logger @binding @citation -AuthorityState RELEASE -Supersedes $stop|Out-Null} 'AUTHORITY_INVALID_RELEASE'
  $validLines=@(Get-Content $authorityLog)
  $before=[IO.File]::ReadAllText($authorityLog)
  foreach($changes in @(@{Kind='dispatch'},@{Model='gpt-6-astra'},@{TargetHead=('A'*40)},@{Pr=1.5},@{Issue=1.5},@{AuthorityIssue=1},@{Supersedes=('a'*64)},@{AuthorityState='stop'},@{IntegrationDispatchSchema='landed-integration-dispatch/v1'})){
    $bad=$binding.Clone();$bad.AuthorityState='ELIGIBLE';foreach($key in $changes.Keys){$bad[$key]=$changes[$key]}
    Assert-Refused {& $logger @bad|Out-Null} 'authority|AUTHORITY'
    Assert-Log ([IO.File]::ReadAllText($authorityLog)-ceq$before) 'invalid producer mutated history'
  }
  # Replay controls alter synthetic rows only; append order, not timestamp, governs.
  function Replay-Authority($Lines){[IO.File]::WriteAllLines($authorityLog,[string[]]$Lines);Read-Authority}
  $i=0;$inverted=@($validLines|ForEach-Object{$v=$_|ConvertFrom-Json -DateKind String;$v.ts=[datetimeoffset]::Parse('2000-01-01T00:00:00Z').AddSeconds(-$i++).ToString('o');$v|ConvertTo-Json -Compress})
  $release=$inverted[3]|ConvertFrom-Json -DateKind String
  $release.supersedes=([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($inverted[1])))).ToLowerInvariant()
  $inverted[3]=$release|ConvertTo-Json -Compress
  Assert-Log ((Replay-Authority $inverted).state-ceq'ELIGIBLE') 'timestamp ordering changed causal release'
  # Hash references bind raw bytes, so use original STOP bytes for causal controls.
  [IO.File]::WriteAllLines($authorityLog,[string[]]$validLines)
  $h=Read-ExactHeadReviewHistory $authorityLog
  Assert-Log ((Reduce-LandedIntegrationAuthority $h 908132 'synthetic/terminal' ('b'*40)).state-ceq'UNKNOWN') 'stale head admitted'
  $newHeadRow=$validLines[4]|ConvertFrom-Json -DateKind String;$newHeadRow.targetHead='b'*40
  Assert-Log ((Replay-Authority @($validLines+($newHeadRow|ConvertTo-Json -Compress))).state-ceq'UNKNOWN') 'older head eligibility survived a newer live row'
  foreach($case in @('missing','cross-pr','cross-branch','duplicate','reversed','extra','date-only','wrong-kind','mixed-schema','missing-schema','fractional-issue')){
    $release=$validLines[3]|ConvertFrom-Json -DateKind String
    $lines=@($validLines)
    switch($case){
      'missing' {$release.supersedes='f'*64}
      'cross-pr' {$release.pr=908133}
      'cross-branch' {$release.targetBranch='synthetic/other'}
      'duplicate' {$lines+= $validLines[3]}
      'reversed' {$lines=@($validLines[3],$validLines[1],$validLines[4])}
      'extra' {$release|Add-Member extra @{} }
      'date-only' {$release.ts='2026-09-23'}
      'wrong-kind' {$release.kind='dispatch'}
      'mixed-schema' {$release|Add-Member receiptSchema 'exact-head-review-receipt/v1'}
      'missing-schema' {$release.PSObject.Properties.Remove('integrationAuthoritySchema')}
      'fractional-issue' {$release.issue=1.5}
    }
    if($case-notin@('duplicate','reversed')){$lines[3]=$release|ConvertTo-Json -Compress}
    $reduced=Replay-Authority $lines
    if($case-in@('cross-pr','cross-branch')){
      Assert-Log ($reduced.state-ceq'STOP') "$case released another target"
      $other=Reduce-LandedIntegrationAuthority (Read-ExactHeadReviewHistory $authorityLog) $release.pr $release.targetBranch $head
      Assert-Log ($other.state-ceq'UNKNOWN'-and-not$other.globalUnknown) "$case not scoped invalid"
    }else{Assert-Log ($reduced.state-ceq'UNKNOWN'-and-not$reduced.globalUnknown) "$case did not fail scoped closed"}
  }
  foreach($line in @('{bad','{"integrationAuthoritySchema":"landed-integration-authority/v1","pr":1,"pr":2}', '{"integrationAuthoritySchema":"landed-integration-authority/v1","pr":null}')){
    $r=Replay-Authority @($validLines+$line);Assert-Log ($r.state-ceq'UNKNOWN'-and$r.globalUnknown) 'global uncertain history admitted'
  }
  [IO.File]::WriteAllLines($authorityLog,[string[]]$validLines)
  $h=Read-ExactHeadReviewHistory $authorityLog -MaxRows 1
  Assert-Log ((Reduce-LandedIntegrationAuthority $h 908132 'synthetic/terminal' $head).globalUnknown) 'capped history admitted'
  $h=Read-ExactHeadReviewHistory $authorityLog
  Assert-Log ((Reduce-ExactHeadReview -Pr 908132 -CurrentHead $head -History $h).state-ceq'unknown') 'binding fabricated review authority'
  $stop2=$validLines[1]|ConvertFrom-Json -DateKind String
  $stop2.authorityCommentId=9000000003L;$stop2.operatorAuthority='Todd:908130#9000000003';$stop2.targetHead='b'*40
  $multi=Replay-Authority @($validLines[1],($stop2|ConvertTo-Json -Compress),$validLines[4])
  Assert-Log ($multi.state-ceq'STOP'-and$multi.authorityRows.Count-eq2) 'not all active STOP hashes survived a head change and later ELIGIBLE'
  $modulePath=Join-Path $PSScriptRoot 'review-head-contract.psm1';$moduleSource=[IO.File]::ReadAllText($modulePath)
  $anchor='if ($active.Count) {'
  Assert-Log ($moduleSource.Contains($anchor)) 'STOP precedence mutant anchor missing'
  $mutantPath=Join-Path $root 'synthetic-stop-precedence.psm1';[IO.File]::WriteAllText($mutantPath,$moduleSource.Replace($anchor,'if ($false) {'))
  $mutant=Import-Module $mutantPath -Force -PassThru -DisableNameChecking
  try{
    $wrong=& $mutant {param($h,$head) Reduce-LandedIntegrationAuthority $h 908132 'synthetic/terminal' $head} (Read-ExactHeadReviewHistory $authorityLog) $head
    Assert-Log ($wrong.state-ceq'ELIGIBLE') 'STOP precedence bypass did not fail the paired STOP control'
  }finally{Remove-Module $mutant;Import-Module $modulePath -Force -DisableNameChecking}
  [IO.File]::WriteAllLines($authorityLog,[string[]]$validLines)
  $unrelated=$binding.Clone();$unrelated.TargetBranch='synthetic/unrelated'
  & $logger @unrelated @citation -AuthorityState STOP|Out-Null
  Assert-Refused {& $logger @binding -AuthorityState ELIGIBLE|Out-Null} 'AUTHORITY_DUPLICATE'
  Write-Output 'CONTROL AUTHORITY_STOP_PRECEDENCE bypass REJECTED; all-active-stops and target-local duplicate window PASS'
  $telemetry=Join-Path $root 'synthetic-telemetry';New-Item -ItemType Directory $telemetry|Out-Null
  $telemetryHistory=Join-Path $telemetry 'dispatch-log.jsonl'
  $boardMarker=Join-Path $root 'board-called';$boardStub=Join-Path $root 'board-stub.ps1'
  Set-Content $boardStub "[IO.File]::WriteAllText('$($boardMarker.Replace("'","''"))','called')"
  $boardBinding=$binding.Clone();$boardBinding.OutFile=$telemetryHistory;$boardBinding.BoardScript=$boardStub
  $previousBoardSync = $env:ORCH_BOARD_SYNC
  try {
    Remove-Item Env:ORCH_BOARD_SYNC -ErrorAction SilentlyContinue
    & $logger @boardBinding -AuthorityState ELIGIBLE|Out-Null
  } finally { $env:ORCH_BOARD_SYNC = $previousBoardSync }
  Assert-Log (-not(Test-Path $boardMarker)) 'authority row invoked board even with explicit BoardScript'
  $costLedger=Join-Path $root 'synthetic-cost.jsonl'
  $cost=& (Join-Path $PSScriptRoot 'cost-harvest.ps1') -TranscriptDir $telemetry -Ledger $costLedger -Json|ConvertFrom-Json
  Assert-Log ($cost.harvestedNow-eq0-and$cost.transcriptsTotal-eq0) 'rule-change authority became a costed run'
  $matrix=Join-Path $root 'synthetic-matrix.json'
  Set-Content $matrix '{"version":"synthetic","configs":[],"dimensions":[]}'
  $matrixResult=& (Join-Path $PSScriptRoot 'matrix-refresh.ps1') -Matrix $matrix -CostLedger $costLedger -DispatchLog $telemetryHistory -DryRun -Json|ConvertFrom-Json
  Assert-Log ($matrixResult.runsWithCost-eq0-and$matrixResult.rowsCosted-eq0-and$matrixResult.effortIdentity.reviewRowsResolved-eq0) 'authority row became matrix evidence'
  Write-Output 'CONTROL terminal-stop-day-after-and-authorized-transition PASS; terminal-authority-unknown-and-false-release PASS'
  if($AuthorityOnly){return}
  & $logger -Log dispatch -Kind dispatch -Issue 4388 -Lane lane-a -LaneRole implementation -Harness codex -Model gpt-6.1-sol -Effort medium -Row 4 -Placement provisional -Transcript lane-a.jsonl -OutFile $log -NoBoard|Out-Null
  $routing=@{Log='dispatch';Kind='dispatch';DispatchRoutingSchema='watchdog-dispatch-routing/v1';DispatchAttemptId='synthetic-attempt';DispatchLabel='synthetic-label';Lane='lane-a';LaneRole='implementation';Transcript='synthetic-label.jsonl';Harness='codex';Model='gpt-6.1-sol';Effort='high';Row='4';Placement='measured';DispatchWorktree=$root;DispatchBranch='synthetic/branch';DispatchHead=$head;OutFile=$log;NoBoard=$true};&$logger @routing|Out-Null;$routingRow=(Get-Content $log -Tail 1)|ConvertFrom-Json -DateKind String;Assert-Log ($routingRow.dispatchRoutingSchema-ceq'watchdog-dispatch-routing/v1'-and$routingRow.attemptId-ceq'synthetic-attempt'-and$routingRow.worktree-ceq[IO.Path]::GetFullPath($root)) 'closed watchdog dispatch-routing provenance was not produced canonically';$routingMissing=$routing.Clone();$routingMissing.Remove('DispatchHead');Assert-Refused {&$logger @routingMissing|Out-Null} 'requires closed'
  foreach($kind in @('bookkeeping','note','flow-snapshot')){Assert-Refused {&$logger -Log dispatch -Kind $kind -Issue 4388 -OutFile $log -NoBoard|Out-Null} 'not canonical'}
  $ordinary=@{Log='dispatch';Kind='review-complete';Pr=9001;Outcome='PASS';Model='gpt-6.1-sol';AuthorModel='gpt-6.1-sol';ReviewedHead=$head;ReviewerAttempt='review-lane-a';AuthorAttempt='author-lane-a';ReviewContract='review-contract/v2';CompleteSweep=$true;Blocking=0;Candidates=0;NonBlocking=0;OutFile=$log;NoBoard=$true}
  &$logger @ordinary|Out-Null
  $strictBase=@{Log='dispatch';Issue=4388;ControllerHead=$head;Lane='review-lane-4388';LaneRole='review';Harness='codex';Model='gpt-6.1-sol';AuthorModel='gpt-6.1-sol';Effort='high';Row='11';Placement='measured';Transcript='review-lane-4388.jsonl';ReviewerAttempt='reused-review';AuthorAttempt='reused-author';ReviewAuthority='governing';OutFile=$log;NoBoard=$true}
  &$logger @strictBase -Kind dispatch|Out-Null
  &$logger @strictBase -Kind review-complete -Outcome PASS -ReviewContract review-contract/v2 -CompleteSweep -Blocking 0 -Candidates 0 -NonBlocking 0|Out-Null
  $foreign=$strictBase.Clone();$foreign.Issue=4400;$foreign.ControllerHead='b'*40;$foreign.Lane='review-lane-4400';$foreign.Transcript='review-lane-4400.jsonl'
  &$logger @foreign -Kind dispatch|Out-Null
  Assert-Log (@(Get-Content -LiteralPath $log).Count-eq6) 'historical attempt reuse on a distinct lane/issue was rejected or rewrote history'
  $planning=@{Log='dispatch';Kind='review-complete';Issue=7735;Lane='planning-7735-review';LaneRole='planning';Harness='codex';Model='gpt-6.1-sol';AuthorModel='claude-opus-5-5';Effort='high';Row='8';Placement='measured';Transcript='planning-7735-review.jsonl';Outcome='BLOCK_REPLAN';PlanningContract='planning-repair/v1';CompleteSweep=$true;ReviewedHead=('6'*40);ReviewerAttempt='planning-review-7735';AuthorAttempt='planning-author-7735';Blocking=1;Candidates=1;NonBlocking=0;FindingIds='F1';RepairOwner='planning-repair';OutFile=$log;NoBoard=$true}
  &$logger @planning|Out-Null;$planningRow=(Get-Content -LiteralPath $log -Tail 1)|ConvertFrom-Json -DateKind String
  Assert-Log ($planningRow.laneRole-ceq'planning'-and$planningRow.planningContract-ceq'planning-repair/v1'-and$planningRow.reviewedHead-ceq('6'*40)-and$null-eq$planningRow.PSObject.Properties['pr']-and$null-eq$planningRow.PSObject.Properties['receiptSchema']-and$null-eq$planningRow.PSObject.Properties['reviewContract']) 'planning review source provenance claimed ordinary PR authority'
  $planningPr=$planning.Clone();$planningPr.Pr=7735;Assert-Refused {&$logger @planningPr|Out-Null} 'refuses PR'
  $planningOrdinary=$planning.Clone();$planningOrdinary.Remove('PlanningContract');$planningOrdinary.ReviewContract='review-contract/v2';Assert-Refused {&$logger @planningOrdinary|Out-Null} 'requires both'
  $planningWrongRole=$planning.Clone();$planningWrongRole.LaneRole='review';Assert-Refused {&$logger @planningWrongRole|Out-Null} 'requires both'
  $stall=@{Log='dispatch';Kind='landing-stall';Pr=9001;LandingHead=$head;RefusalReason='DEPLOY_UNHEALTHY';PassReceiptIdentity=('c'*64);ActualEnqueueResult='confirmed';ActualEnqueueReason='DIRECT_ENQUEUE_CONFIRMED';ActualEnqueueEntryId='MQE_SYNTHETIC';OutFile=$log;NoBoard=$true}
  &$logger @stall|Out-Null;$row=(Get-Content -LiteralPath $log -Tail 1)|ConvertFrom-Json -DateKind String
  Assert-Log ($row.landingStallSchema-ceq'landing-stall/v1'-and$row.refusalReason-ceq'DEPLOY_UNHEALTHY'-and$row.enqueue.attempted-eq$true-and$row.enqueue.result-ceq'confirmed'-and$row.enqueue.expectedHeadOid-ceq$head-and$row.enqueue.jump-eq$false) 'landing-stall did not atomically retain refusal and actual enqueue result'
  $missing=$stall.Clone();$missing.Remove('ActualEnqueueResult');Assert-Refused {&$logger @missing|Out-Null} 'actual enqueue result'
  $noEntry=$stall.Clone();$noEntry.Remove('ActualEnqueueEntryId');Assert-Refused {&$logger @noEntry|Out-Null} 'requires its actual queue entry id'
  # Synthetic historical generic dispatch and independently structured terminal.
  # Replay immutable historical bytes only in an isolated log. No live append.
  Import-Module (Join-Path $PSScriptRoot 'review-head-contract.psm1') -Force -DisableNameChecking
  $auditLog=Join-Path $root 'audit-replay.jsonl'
  $originals=@(Get-Content (Join-Path $PSScriptRoot 'fixtures/controller-review-7978-originals.jsonl'))
  $generic=$originals[0]|ConvertFrom-Json -DateKind String
  $terminal=$originals[1]|ConvertFrom-Json -DateKind String
  function Write-AuditReplay($Rows) {
    [IO.File]::WriteAllLines($auditLog, [string[]]$Rows, [Text.UTF8Encoding]::new($false))
  }
  Write-AuditReplay $originals
  $history=Read-ExactHeadReviewHistory $auditLog
  Assert-Log ($history.rows.Count-eq2-and$history.rows[0].rawSha256-ceq'79135c2de2c9e1346471243bd53ca85adf161670271f38086b56318e73733cf3'-and$history.rows[1].rawSha256-ceq'6321dd4b64a51e50594ce806bf99b212fe88befd0a7e02c2ec40216503141153') 'native original row hashes changed'
  $uncorrected=Reduce-ControllerReleaseReview -Issue 7978 -ControllerHead $terminal.controllerHead -Mode strict-v1 -History $history
  Assert-Log ($uncorrected.reason-ceq'STRICT_PAIR_CONFLICT') 'generic dispatch must not supply strict authority by default'
  # Historical #7978 audit identity remains readable, but a new correction
  # cannot write its retired reviewer selector.
  $correction=@{Log='dispatch';Kind='controller-review-audit-correction';Model=$terminal.reviewerModel;AuthorModel=$terminal.authorModel;OutFile=$auditLog;NoBoard=$true}
  $originalBytes=[IO.File]::ReadAllBytes($auditLog)
  Assert-Refused {&$logger @correction|Out-Null} 'gpt-5.6-sol.*retired'
  Assert-Log ([Linq.Enumerable]::SequenceEqual([byte[]]$originalBytes,[byte[]][IO.File]::ReadAllBytes($auditLog))) 'retired correction changed historical bytes'
  $syntheticGeneric=[ordered]@{ts='2001-01-01T00:00:00.000Z';kind='dispatch';issue=900001;lane='synthetic-review';laneRole='review';harness='codex';model='gpt-6.1-sol';effort='high';row='11';placement='measured';transcript='synthetic-review.jsonl'}
  $syntheticTerminal=$terminal.PSObject.Copy()
  $syntheticTerminal.reviewerModel='gpt-6.1-sol'
  $syntheticTerminal.ts='2001-01-01T00:01:00.000Z';$syntheticTerminal.issue=900001;$syntheticTerminal.controllerHead='c'*40
  $syntheticTerminal.lane='synthetic-review';$syntheticTerminal.transcript='synthetic-review.jsonl';$syntheticTerminal.authorAttempt='synthetic-author';$syntheticTerminal.reviewerAttempt='synthetic-reviewer'
  Write-AuditReplay @(($syntheticGeneric|ConvertTo-Json -Compress),($syntheticTerminal|ConvertTo-Json -Compress -Depth 10))
  $syntheticHistory=Read-ExactHeadReviewHistory $auditLog
  $request=@{Log='dispatch';Kind='controller-review-audit-correction';Issue=900001;ControllerHead=('c'*40);Lane='synthetic-review';LaneRole='review';Transcript='synthetic-review.jsonl';Harness='codex';Model='gpt-6.1-sol';AuthorModel=$syntheticTerminal.authorModel;Effort='high';Row='11';Placement='measured';AuthorAttempt='synthetic-author';ReviewerAttempt='synthetic-reviewer';ReviewAuthority=$terminal.reviewAuthority;OperatorAuthority='Todd:synthetic-unapproved';OutFile=$auditLog;NoBoard=$true}
  $request.OriginalDispatchRawSha256=$syntheticHistory.rows[0].rawSha256;$request.OriginalTerminalRawSha256=$syntheticHistory.rows[1].rawSha256
  Assert-Refused {&$logger @request|Out-Null} 'AUDIT_CORRECTION_NOT_AUTHORIZED'
  Assert-Log ((Read-ExactHeadReviewHistory $auditLog).rows.Count-eq2) 'generic synthetic pair gained correction authority'
  Write-Output 'PASS historical #7978 replay is immutable; new retired correction refused; synthetic correction unauthorized'
  # #8110 dispatch-only audit correction. A dangling malformed strict dispatch row
  # (override-Todd placement, no terminal, no successor) is cleared under explicit
  # Todd authority with no terminal hash at all; every refusal appends nothing.
  $danglingLog=Join-Path $root 'dangling-8110.jsonl'
  $danglingHead='e'*40
  $dangling=[ordered]@{ts=[datetimeoffset]::UtcNow.AddMinutes(-5).ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'");kind='dispatch';controllerReviewSchema='controller-review-dispatch/v1';issue=8103;controllerHead=$danglingHead;authorAttempt='goal-8110-author';reviewerAttempt='goal-8110-reviewer-r1';reviewAuthority='governing';lane='controller-8110-review-r1';transcript='controller-8110-review-r1.jsonl';reviewerModel='gpt-6.1-sol';authorModel='gpt-6.1-sol';effort='high';row='11';placement='override-Todd';harness='codex'}
  $danglingRaw=$dangling|ConvertTo-Json -Compress
  function Copy-Ordered($Source){$copy=[ordered]@{};foreach($k in $Source.Keys){$copy[$k]=$Source[$k]};$copy}
  $successor=Copy-Ordered $dangling;$successor.ts=[datetimeoffset]::UtcNow.AddMinutes(-4).ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'");$successor.reviewerAttempt='goal-8110-reviewer-r2';$successor.lane='controller-8110-review-r2';$successor.transcript='controller-8110-review-r2.jsonl';$successor.placement='measured'
  $successorRaw=$successor|ConvertTo-Json -Compress
  $matchingTerminal=Copy-Ordered $dangling;$matchingTerminal.ts=[datetimeoffset]::UtcNow.AddMinutes(-4).ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'");$matchingTerminal.kind='review-complete';$matchingTerminal.controllerReviewSchema='controller-review-receipt/v1';$matchingTerminal.placement='measured'
  $matchingTerminal.reviewContract='review-contract/v2';$matchingTerminal.completeSweep=$true;$matchingTerminal.outcome='PASS';$matchingTerminal.findingIds=@();$matchingTerminal.findings=[ordered]@{blocking=0;candidates=0;nonBlocking=0}
  $matchingTerminalRaw=$matchingTerminal|ConvertTo-Json -Compress -Depth 10
  function Write-DanglingReplay($Rows){[IO.File]::WriteAllLines($danglingLog,[string[]]$Rows,[Text.UTF8Encoding]::new($false))}
  Write-DanglingReplay @($danglingRaw)
  $danglingHistory=Read-ExactHeadReviewHistory $danglingLog
  $danglingHash=$danglingHistory.rows[0].rawSha256
  $stuck=Reduce-ControllerReleaseReview -Issue 8103 -ControllerHead $danglingHead -Mode strict-v1 -History $danglingHistory
  Assert-Log ($stuck.state-ceq'indeterminate'-and$stuck.reason-ceq'MALFORMED_RELEVANT_STRICT_ROW'-and$stuck.audit.invalidRows[0].dangling-eq$true) 'dangling override-Todd row did not fail closed as dangling'
  $clear=@{Log='dispatch';Kind='controller-review-audit-correction';Issue=8103;ControllerHead=$danglingHead;Lane=$dangling.lane;LaneRole='review';Transcript=$dangling.transcript;Harness='codex';Model='gpt-6.1-sol';AuthorModel='gpt-6.1-sol';Effort='high';Row='11';Placement='override-todd';AuthorAttempt='goal-8110-author';ReviewerAttempt='goal-8110-reviewer-r1';ReviewAuthority='governing';OriginalDispatchRawSha256=$danglingHash;OperatorAuthority='Todd:synthetic-8110-test-ruling';OutFile=$danglingLog;NoBoard=$true}
  foreach($case in @('missing-authority','malformed-authority','missing-dispatch-hash','wrong-dispatch-hash','sentinel-terminal-hash','wrong-lane','wrong-transcript','wrong-issue','wrong-head','target-valid-row','target-has-terminal','target-has-successor','ambiguous-target','unterminated')){
    Write-DanglingReplay @($danglingRaw)
    $request=$clear.Clone()
    switch($case){
      'missing-authority' {$request.Remove('OperatorAuthority')}
      'malformed-authority' {$request.OperatorAuthority='synthetic-not-todd'}
      'missing-dispatch-hash' {$request.Remove('OriginalDispatchRawSha256')}
      'wrong-dispatch-hash' {$request.OriginalDispatchRawSha256='e'*64}
      'sentinel-terminal-hash' {$request.OriginalTerminalRawSha256='0'*64}
      'wrong-lane' {$request.Lane='synthetic-other-lane'}
      'wrong-transcript' {$request.Transcript='synthetic-other.jsonl'}
      'wrong-issue' {$request.Issue=900001}
      'wrong-head' {$request.ControllerHead='d'*40}
      'target-valid-row' {Write-DanglingReplay @($successorRaw);$request.OriginalDispatchRawSha256=(Read-ExactHeadReviewHistory $danglingLog).rows[0].rawSha256;$request.Lane=$successor.lane;$request.Transcript=$successor.transcript;$request.ReviewerAttempt=$successor.reviewerAttempt;$request.Placement='measured'}
      'target-has-terminal' {Write-DanglingReplay @($danglingRaw,$matchingTerminalRaw)}
      'target-has-successor' {Write-DanglingReplay @($danglingRaw,$successorRaw)}
      'ambiguous-target' {Write-DanglingReplay @($danglingRaw,$danglingRaw)}
      'unterminated' {[IO.File]::WriteAllText($danglingLog,[IO.File]::ReadAllText($danglingLog).TrimEnd("`r","`n"),[Text.UTF8Encoding]::new($false))}
    }
    $unchanged=[Convert]::ToBase64String([IO.File]::ReadAllBytes($danglingLog))
    Assert-Refused {&$logger @request|Out-Null} 'audit correction|AuditCorrection|OperatorAuthority'
    Assert-Log ($unchanged-ceq[Convert]::ToBase64String([IO.File]::ReadAllBytes($danglingLog))) "dispatch-only correction refusal $case changed history"
    Write-Output "PASS dispatch-only audit correction refusal: $case (zero append)"
  }
  Write-DanglingReplay @($danglingRaw)
  $danglingPrefix=[IO.File]::ReadAllBytes($danglingLog)
  $clearBefore=[datetimeoffset]::UtcNow
  &$logger @clear|Out-Null
  $clearedHistory=Read-ExactHeadReviewHistory $danglingLog
  $clearedBytes=[IO.File]::ReadAllBytes($danglingLog)
  Assert-Log ([Convert]::ToBase64String($danglingPrefix)-ceq[Convert]::ToBase64String($clearedBytes[0..($danglingPrefix.Length-1)])) 'dispatch-only correction rewrote the original bytes'
  $clearedRow=$clearedHistory.rows[1].value
  Assert-Log ($clearedHistory.rows.Count-eq2-and$clearedRow.kind-ceq'controller-review-audit-correction'-and$clearedRow.controllerReviewSchema-ceq'controller-review-audit-correction/v1'-and
    $null-eq$clearedRow.PSObject.Properties['originalTerminalRawSha256']-and$clearedRow.originalDispatchRawSha256-ceq$danglingHash-and$clearedRow.operatorAuthority-ceq'Todd:synthetic-8110-test-ruling'-and
    $clearedRow.placement-ceq'override-todd'-and[datetimeoffset]::Parse($clearedRow.ts)-ge$clearBefore.AddMilliseconds(-1)) 'dispatch-only correction row was not a current-time closed row naming the dispatch alone'
  $cleared=Reduce-ControllerReleaseReview -Issue 8103 -ControllerHead $danglingHead -Mode strict-v1 -History $clearedHistory
  Assert-Log ($cleared.state-ceq'indeterminate'-and$cleared.reason-ceq'NO_STRICT_REVIEW_HISTORY'-and$cleared.census.invalidConflict-eq0-and$null-eq$cleared.selected-and
    $cleared.audit.danglingCorrections.Count-eq1-and$cleared.audit.danglingCorrections[0].originalPhysicalLine-eq1-and$cleared.audit.danglingCorrections[0].rawSha256-ceq$clearedHistory.rows[1].rawSha256) 'cleared dangling row did not become reachable, or the clearance granted authority'
  $clearedUnchanged=[Convert]::ToBase64String($clearedBytes)
  Assert-Refused {&$logger @clear|Out-Null} 'AUDIT_CORRECTION_DUPLICATE'
  Assert-Log ($clearedUnchanged-ceq[Convert]::ToBase64String([IO.File]::ReadAllBytes($danglingLog))) 'duplicate dispatch-only correction mutated history'
  Write-DanglingReplay @($danglingRaw,$clearedHistory.rows[1].raw,$successorRaw)
  $relaunch=Reduce-ControllerReleaseReview -Issue 8103 -ControllerHead $danglingHead -Mode strict-v1 -History (Read-ExactHeadReviewHistory $danglingLog) -DispatchTuple ([pscustomobject]$successor)
  Assert-Log ($relaunch.state-ceq'in-flight'-and$relaunch.reason-ceq'STRICT_ATTEMPT_IN_FLIGHT') 'a relaunch on a fresh lane after clearance is not admitted in flight'
  Write-Output 'PASS #8110 dispatch-only audit correction: dangling row cleared under Todd authority, no terminal fabricated, every refusal appends nothing'
  Write-Output 'PASS log-event lifecycle-only kinds, closed watchdog routing provenance, requested/strict/planning receipts, lane identity, and atomic landing-stall enqueue record'
}finally{
  $resolved=[IO.Path]::GetFullPath($root);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
  if((Split-Path -Parent $resolved).TrimEnd('\','/')-cne$temp-or(Split-Path -Leaf $resolved)-notlike'log-event-test-*'){throw 'unsafe log event cleanup root'}
  if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
  Exit-RoutingDataTestScope $routingTestScope
}
