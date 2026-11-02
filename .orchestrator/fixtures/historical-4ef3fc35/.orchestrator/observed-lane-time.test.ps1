[CmdletBinding()]
param(
  [string]$Revision = '',
  [string]$ScaleHistoryPath = '',
  [ValidateSet('', 'ignore-observed-end', 'ignore-observed-start','ignore-correction-start','double-count-correction',
    'skip-attempt-binding','accept-end-before-start','accept-conflicting-replay','accept-prior-attempt-overlap')][string]$Mutant = '',
  [ValidateSet('all', 'end', 'start', 'logger', 'harvest','correction','repair')][string]$Scenario = 'all'
)

$ErrorActionPreference = 'Stop'
[Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal'
$root = Join-Path ([IO.Path]::GetTempPath()) ('synthetic-8615-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$failures = [Collections.Generic.List[string]]::new()
function Assert-Observed([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}
function Check([string]$Name, [scriptblock]$Body) {
  try { & $Body; Write-Output "PASS $Name" }
  catch { $failures.Add("${Name}: $($_.Exception.Message)"); Write-Output "FAIL ${Name}: $($_.Exception.Message)" }
}
function Write-Fixture($Rows) {
  $text = (@($Rows | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 16 }) -join "`n") + "`n"
  [IO.File]::WriteAllText($ledger, $text, [Text.UTF8Encoding]::new($false))
}
function Refused([hashtable]$Parameters, [string]$Code) {
  $before = [IO.File]::ReadAllBytes($ledger)
  $message = ''
  try { & $logger -Log dispatch -OutFile $ledger -NoBoard @Parameters | Out-Null }
  catch { $message = $_.Exception.Message }
  Assert-Observed ($message.Contains($Code)) "expected $Code, got $message"
  Assert-Observed ([Linq.Enumerable]::SequenceEqual($before, [IO.File]::ReadAllBytes($ledger))) 'refusal changed ledger bytes'
}
$scope = $null
try {
  $subject = Join-Path $root 'subject'
  [void][IO.Directory]::CreateDirectory($subject)
  $controller = Split-Path -Parent $PSScriptRoot
  if ($Revision) {
    $archive = Join-Path $root 'subject.zip'
    & git -C $controller archive --format=zip "--output=$archive" $Revision -- .orchestrator
    Assert-Observed ($LASTEXITCODE -eq 0) 'baseline archive failed'
    Expand-Archive -LiteralPath $archive -DestinationPath $subject
  } else {
    $paths = @(& git -C $controller ls-files -- .orchestrator)
    Assert-Observed ($LASTEXITCODE -eq 0) 'source inventory failed'
    $paths += @('.orchestrator/harvest-observed-lanes.ps1')
    foreach ($path in @($paths | Sort-Object -Unique)) {
      $sourcePath = Join-Path $controller $path
      if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { continue }
      $destination = Join-Path $subject $path
      [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
      [IO.File]::Copy($sourcePath, $destination)
    }
  }
  $scripts = Join-Path $subject '.orchestrator'
  $module = Join-Path $scripts 'orchestration-log-lock.psm1'
  [IO.File]::WriteAllText($module, ([IO.File]::ReadAllText($module).Replace('Global\ChaseSetsOrchLog', ('Local\Synthetic8615-' + [guid]::NewGuid().ToString('N')))))
  $logger = Join-Path $scripts 'log-event.ps1'
  $source = [IO.File]::ReadAllText($logger)
  $needle = '$eventTs = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd''T''HH:mm:ss.fff''Z''")'
  Assert-Observed ($source.Contains($needle)) 'machine timestamp seam absent'
  [IO.File]::WriteAllText($logger, $source.Replace($needle, '$eventTs = ''2026-10-04T18:00:00.000Z'''))
  if ($Mutant -cin @('ignore-observed-end','ignore-observed-start')) {
    $timePath = Join-Path $scripts 'review-head-contract.psm1'
    $source = [IO.File]::ReadAllText($timePath)
    $field = if ($Mutant -ceq 'ignore-observed-end') { 'observedEndAt' } else { 'observedStartAt' }
    $needle = "Get-ObservedLaneValue `$Row '$field'"
    Assert-Observed ($source.Contains($needle)) "$Mutant seam absent"
    [IO.File]::WriteAllText($timePath, $source.Replace($needle, "Get-ObservedLaneValue `$Row 'ignored-$field'"))
  }
  if ($Mutant -and $Mutant -cnotin @('ignore-observed-end','ignore-observed-start')) {
    $timePath=Join-Path $scripts 'review-head-contract.psm1'
    $source=[IO.File]::ReadAllText($timePath)
    switch ($Mutant) {
      'ignore-correction-start' {
        $needle='$row | Add-Member observedStartAt $correction.observedStartAt -Force'
        $replacement='$row | Add-Member observedStartAt $row.ts -Force'
      }
      'skip-attempt-binding' {
        $needle='$entry = $matches[0]; $dispatch = $entry.value'
        $replacement=$needle + '; $target.attempts = Get-LaneTimeAttempts $dispatch'
      }
      'accept-end-before-start' { $needle='$end -lt $start'; $replacement='$false' }
      'accept-prior-attempt-overlap' {
        $needle='if ($prior.line -lt $entry.line -and $priorAt -gt $start)'
        $replacement='if ($false)'
        $terminalNeedle='if ($priorAt -gt $start -and $priorAt -lt $end)'
        Assert-Observed ($source.Contains($terminalNeedle)) 'disjoint terminal mutant seam absent'
        $source=$source.Replace($terminalNeedle,'if ($false)')
      }
      'accept-conflicting-replay' {
        $needle='if ((Get-LaneTimeSignature $value) -cne $signature)'
        $replacement='if ($false)'
      }
      'double-count-correction' {
        $timePath=Join-Path $scripts 'velocity-metrics.ps1'
        $source=[IO.File]::ReadAllText($timePath)
        $needle='$totals.product += $hours'
        $replacement='$totals.product += $hours; if ($boundEnds.ContainsKey($identity)) { $totals.product += $hours }'
      }
    }
    Assert-Observed ($source.Contains($needle)) "$Mutant seam absent"
    if($Mutant -ceq 'accept-conflicting-replay'){
      $early='if((Get-LaneTimeSignature $prior.value) -cne (Get-LaneTimeSignature $Row))'
      Assert-Observed ($source.Contains($early)) 'early replay mutant seam absent'
      $source=$source.Replace($early,'if($false)')
    }
    [IO.File]::WriteAllText($timePath,$source.Replace($needle,$replacement))
  }
  . (Join-Path $scripts 'routing-data-test-support.ps1')
  $scope = Enter-RoutingDataTestScope
  . (Join-Path $scripts 'velocity-metrics.ps1')
  $now = ConvertTo-VelocityUtc '2026-10-04T18:00:00Z'
  $issue = [pscustomobject]@{number=908615;title='Synthetic product';labels=@();terminalState='none';milestone=[pscustomobject]@{number=148;committed=$true;track='commerce';state='OPEN'}}
  $dispatch = [pscustomobject]@{ts='2026-10-04T10:00:00Z';kind='dispatch';lane='synthetic-8615';issue=908615}
  $terminal = [pscustomobject]@{ts='2026-10-04T17:00:00Z';kind='lane-complete';lane='synthetic-8615';observedEndAt='2026-10-04T12:00:00Z';observedEvidence='report-mtime:synthetic-report.md'}
  function Hours($Rows) {
    Get-VelocityLaneHours ([pscustomobject]@{dispatchRows=@($Rows);issueDetails=[pscustomobject]@{'908615'=$issue};productIssues=@($issue);platformMilestones=@()}) $now @{} @()
  }
  if ($Scenario -cin @('all','end')) {
    Check 'late-end-exact-hours' { Assert-Observed ((Hours @($dispatch,$terminal)).productHours -eq 2) 'dispatch..observedEnd must be exactly 2h, not 7h' }
    Check 'late-terminal-crosses-next-dispatch-write-order' {
      $next=$dispatch.PSObject.Copy();$next.ts='2026-10-04T14:00:00Z'
      Assert-Observed ((Hours @($dispatch,$next,$terminal)).productHours -eq 2) 'observed terminal must close the earlier dispatch, not the later one'
    }
    Check 'terminal-action-observed-time' {
      $action=$terminal.PSObject.Copy();$action.kind='decision-resolved';$action|Add-Member note 'velocity:DROUGHT'
      Assert-Observed ((Get-VelocityActionTime ([pscustomobject]@{dispatchRows=@($action)}) 'DROUGHT' $now.AddHours(-8)) -eq $now.AddHours(-6)) 'action must use observed end'
      Assert-Observed ($null -eq (Get-VelocityActionTime ([pscustomobject]@{dispatchRows=@($action)}) 'DROUGHT' $now.AddHours(-2))) 'late logging must not act on a later alarm'
    }
    Check 'legacy-end-fallback' { $legacy=$terminal.PSObject.Copy();$legacy.PSObject.Properties.Remove('observedEndAt');$legacy.PSObject.Properties.Remove('observedEvidence');Assert-Observed ((Hours @($dispatch,$legacy)).productHours -eq 7) 'legacy ts fallback changed' }
  }
  if ($Scenario -cin @('all','start')) {
    $late=$dispatch.PSObject.Copy();$late.ts='2026-10-04T11:00:00Z';$late|Add-Member observedStartAt '2026-10-04T10:00:00Z';$late|Add-Member observedEvidence 'transcript-ctime:synthetic.jsonl'
    Check 'late-start-exact-hours' { Assert-Observed ((Hours @($late,$terminal)).productHours -eq 2) 'observedStart..observedEnd must be exactly 2h, not 1h' }
    Check 'lane-map-observed-start' { Assert-Observed ((Get-VelocityLaneIssueMap @($late))['synthetic-8615'].startedAt -eq $now.AddHours(-8)) 'lane-map age must use observed start' }
    Check 'window-clipping' { $late.observedStartAt='2026-10-01T10:00:00Z';Assert-Observed ((Hours @($late,$terminal)).productHours -eq 42) '48h clipping must use observed start' }
  }
  $ledger = Join-Path $root 'private-ledger.jsonl'
  if ($Scenario -cin @('all','logger')) {
    Check 'writer-end-preserves-ts-evidence-and-prefix' {
      Write-Fixture @($dispatch)
      $prefix=[IO.File]::ReadAllText($ledger)
      & $logger -Log dispatch -Kind lane-complete -Lane synthetic-8615 -ObservedEndAt '2026-10-04T12:00:00Z' -ObservedEvidence 'report-mtime:synthetic-report.md' -OutFile $ledger -NoBoard | Out-Null
      $row=Get-Content $ledger -Tail 1|ConvertFrom-Json -DateKind String
      Assert-Observed ($row.ts -ceq '2026-10-04T18:00:00.000Z') 'ts was rewritten'
      Assert-Observed ($row.observedEndAt -ceq '2026-10-04T12:00:00Z' -and $row.observedEvidence -ceq 'report-mtime:synthetic-report.md') 'observed end/evidence absent'
      Assert-Observed ([IO.File]::ReadAllText($ledger).StartsWith($prefix)) 'prefix changed'
    }
    Check 'writer-start-and-end-before-dispatch-ts' {
      [IO.File]::WriteAllText($ledger,'')
      & $logger -Log dispatch -Kind dispatch -Issue 908615 -Lane synthetic-8615 -ObservedStartAt '2026-10-04T10:00:00Z' -ObservedEvidence 'transcript-ctime:synthetic.jsonl' -OutFile $ledger -NoBoard | Out-Null
      & $logger -Log dispatch -Kind lane-complete -Lane synthetic-8615 -ObservedEndAt '2026-10-04T12:00:00Z' -ObservedEvidence 'report-mtime:synthetic-report.md' -OutFile $ledger -NoBoard | Out-Null
      $rows=@(Get-Content $ledger|ForEach-Object{$_|ConvertFrom-Json -DateKind String})
      Assert-Observed ($rows.Count -eq 2 -and (Hours $rows).productHours -eq 2) 'end before machine dispatch ts must bind to observed start'
    }
    foreach($case in @(
      @{Name='future';Field='ObservedEndAt';Value='2999-10-04T12:00:00Z';Code='OBSERVED_TIME_FUTURE'},
      @{Name='before-dispatch';Field='ObservedEndAt';Value='2026-10-04T09:00:00Z';Code='OBSERVED_END_BEFORE_DISPATCH'},
      @{Name='unparsable';Field='ObservedEndAt';Value='garbage';Code='OBSERVED_TIME_INVALID'},
      @{Name='non-UTC';Field='ObservedEndAt';Value='2026-10-04T12:00:00-05:00';Code='OBSERVED_TIME_INVALID'},
      @{Name='future-start';Field='ObservedStartAt';Value='2999-10-04T12:00:00Z';Code='OBSERVED_TIME_FUTURE'},
      @{Name='unparsable-start';Field='ObservedStartAt';Value='garbage';Code='OBSERVED_TIME_INVALID'},
      @{Name='start-before-prior';Field='ObservedStartAt';Value='2026-10-04T09:00:00Z';Code='OBSERVED_START_BEFORE_PRIOR_ROW'}
    )) {
      Check "refusal-$($case.Name)" {
        Write-Fixture @($dispatch)
        $args=@{Kind=$(if($case.Field -ceq 'ObservedStartAt'){'dispatch'}else{'lane-complete'});Lane='synthetic-8615';ObservedEvidence='report-mtime:synthetic-report.md'}
        $args[$case.Field]=$case.Value
        Refused $args $case.Code
      }
    }
    Check 'refusal-missing-evidence' { Write-Fixture @($dispatch);Refused @{Kind='lane-complete';Lane='synthetic-8615';ObservedEndAt='2026-10-04T12:00:00Z'} 'OBSERVED_EVIDENCE_REQUIRED' }
    Check 'refusal-start-missing-evidence' { Write-Fixture @($dispatch);Refused @{Kind='dispatch';Lane='synthetic-8615';ObservedStartAt='2026-10-04T12:00:00Z'} 'OBSERVED_EVIDENCE_REQUIRED' }
    Check 'refusal-non-terminal' { Write-Fixture @($dispatch);Refused @{Kind='enqueue';Lane='synthetic-8615';ObservedEndAt='2026-10-04T12:00:00Z';ObservedEvidence='report-mtime:synthetic'} 'OBSERVED_END_KIND_INVALID' }
    Check 'refusal-start-non-dispatch' { Write-Fixture @($dispatch);Refused @{Kind='lane-complete';Lane='synthetic-8615';ObservedStartAt='2026-10-04T12:00:00Z';ObservedEvidence='report-mtime:synthetic'} 'OBSERVED_START_KIND_INVALID' }
    Check 'refusal-no-dispatch' { Write-Fixture @([pscustomobject]@{ts=$dispatch.ts;kind='gc'});Refused @{Kind='lane-complete';Lane='synthetic-8615';ObservedEndAt='2026-10-04T12:00:00Z';ObservedEvidence='report-mtime:synthetic'} 'OBSERVED_DISPATCH_REQUIRED' }
    Check 'latest-dispatch-not-first' { $latest=$dispatch.PSObject.Copy();$latest.ts='2026-10-04T13:00:00Z';Write-Fixture @($dispatch,$latest);Refused @{Kind='lane-complete';Lane='synthetic-8615';ObservedEndAt='2026-10-04T12:00:00Z';ObservedEvidence='report-mtime:synthetic'} 'OBSERVED_END_BEFORE_DISPATCH' }
    Check 'refusal-after-row-timestamp' { Write-Fixture @($dispatch);Refused @{Kind='dispatch';Lane='synthetic-8615';ObservedStartAt='2026-10-04T18:00:00.001Z';ObservedEvidence='transcript-ctime:synthetic'} 'OBSERVED_TIME_AFTER_ROW' }
    Check 'refusal-incomplete-history' { [IO.File]::WriteAllText($ledger,"{broken`n");Refused @{Kind='lane-complete';Lane='synthetic-8615';ObservedEndAt='2026-10-04T12:00:00Z';ObservedEvidence='report-mtime:synthetic'} 'OBSERVED_HISTORY_INVALID' }
    Check 'refusal-unterminated-history' { [IO.File]::WriteAllText($ledger,($dispatch|ConvertTo-Json -Compress));Refused @{Kind='lane-complete';Lane='synthetic-8615';ObservedEndAt='2026-10-04T12:00:00Z';ObservedEvidence='report-mtime:synthetic'} 'OBSERVED_HISTORY_INVALID' }
    Check 'invalid-observation-is-velocity-gap' {
      $invalid=$terminal.PSObject.Copy();$invalid.observedEndAt='garbage'
      $filtered=Get-VelocityDispatchRows @($invalid)
      Assert-Observed ($filtered.rows.Count -eq 0 -and $filtered.gaps[0] -ceq 'dispatch-row-invalid:1:OBSERVED_TIME_INVALID') 'invalid observation fabricated valid velocity facts'
    }
    Check 'refusal-existing-late-dispatch-harvest' {
      $late=$dispatch.PSObject.Copy();$late.ts='2026-10-04T13:00:00Z';Write-Fixture @($late)
      Refused @{Kind='dispatch';Lane='synthetic-8615';ObservedStartAt='2026-10-04T10:00:00Z';ObservedEvidence='transcript-ctime:synthetic'} 'OBSERVED_START_BEFORE_PRIOR_ROW'
      Refused @{Kind='lane-complete';Lane='synthetic-8615';ObservedEndAt='2026-10-04T12:00:00Z';ObservedEvidence='report-mtime:synthetic'} 'OBSERVED_END_BEFORE_DISPATCH'
    }
    foreach($kind in @('lane-blocked','decision-resolved','verify-complete','repair-complete')) {
      Check "writer-terminal-$kind" {
        Write-Fixture @($dispatch)
        & $logger -Log dispatch -Kind $kind -Lane synthetic-8615 -ObservedEndAt '2026-10-04T12:00:00Z' -ObservedEvidence 'report-mtime:synthetic' -OutFile $ledger -NoBoard | Out-Null
        $row=Get-Content $ledger -Tail 1|ConvertFrom-Json -DateKind String
        Assert-Observed ($row.kind -ceq $kind -and (Get-ObservedLaneTime $row) -eq $now.AddHours(-6)) 'terminal observation lost'
      }
    }
    Check 'strict-review-observed-times-preserve-authority' {
      [IO.File]::WriteAllText($ledger,'')
      $base=@{Log='dispatch';Issue=908615;ControllerHead=('a'*40);Lane='synthetic-8615';LaneRole='review';Harness='codex';Model='gpt-6.1-sol';AuthorModel='gpt-6-astra';Effort='high';Row='11';Placement='provisional';Transcript='synthetic-8615.jsonl';ReviewerAttempt='synthetic-reviewer';AuthorAttempt='synthetic-author';ReviewAuthority='governing';OutFile=$ledger;NoBoard=$true}
      & $logger @base -Kind dispatch -ObservedStartAt '2026-10-04T10:00:00Z' -ObservedEvidence 'transcript-ctime:synthetic' | Out-Null
      & $logger @base -Kind review-complete -ObservedEndAt '2026-10-04T12:00:00Z' -ObservedEvidence 'report-mtime:synthetic' -Outcome PASS -ReviewContract review-contract/v2 -CompleteSweep -Blocking 0 -Candidates 0 -NonBlocking 0 | Out-Null
      $history=Read-ExactHeadReviewHistory $ledger
      foreach($record in $history.rows){Assert-Observed ((Get-ControllerReviewRowClassification $record).valid) 'strict observed row must remain closed and valid'}
      Assert-Observed ((Reduce-ControllerReleaseReview -Issue 908615 -ControllerHead ('a'*40) -Mode strict-v1 -History $history).state -ceq 'authorized') 'observations changed governing authority'
    }
    Check 'attempt-scoped-start-ordering' {
      $prior=$dispatch.PSObject.Copy();$prior.ts='2026-10-04T17:00:00Z';$prior|Add-Member attemptId 'synthetic-prior-attempt'
      Write-Fixture @($prior)
      $row=[pscustomobject]@{ts='2026-10-04T18:00:00Z';kind='dispatch';lane=$dispatch.lane;attemptId='synthetic-current-attempt';observedStartAt='2026-10-04T10:00:00Z';observedEvidence='transcript-ctime:synthetic'}
      Assert-ObservedLaneHistory $row (Read-ExactHeadReviewHistory $ledger)
      $row.attemptId='synthetic-prior-attempt'
      $message='';try{Assert-ObservedLaneHistory $row (Read-ExactHeadReviewHistory $ledger)}catch{$message=$_.Exception.Message}
      Assert-Observed ($message.Contains('OBSERVED_START_BEFORE_PRIOR_ROW')) 'same-attempt start ordering was bypassed'
    }
  }
  if ($Scenario -cin @('all','harvest')) {
    Check 'harvest-deterministic-evidence-only' {
      $inputPath=Join-Path $root "synthetic lane's list.json"
      $lanes=@(
        @{lane='synthetic-normal';issue=908615;dispatchRowUtc=$dispatch.ts;reportMtimeUtc=$terminal.observedEndAt;transcriptCreatedUtc=$dispatch.ts;lateDispatchRow=$false},
        @{lane='synthetic-late';issue=908616;dispatchRowUtc='2026-10-04T13:00:00Z';reportMtimeUtc=$terminal.observedEndAt;transcriptCreatedUtc=$dispatch.ts;lateDispatchRow=$true},
        @{lane='synthetic-missing';issue=908617;dispatchRowUtc=$dispatch.ts;reportMtimeUtc=$null;transcriptCreatedUtc=$null;lateDispatchRow=$false}
      )
      [IO.File]::WriteAllText($inputPath,($lanes|ConvertTo-Json))
      $harvester=Join-Path $scripts 'harvest-observed-lanes.ps1'
      Write-Fixture @([pscustomobject]@{ts=$dispatch.ts;kind='dispatch';lane='synthetic-normal';issue=908615},
        [pscustomobject]@{ts='2026-10-04T13:00:00Z';kind='dispatch';lane='synthetic-late';issue=908616})
      $first=@(& $harvester -LanesPath $inputPath -HistoryPath $ledger -LedgerPath $ledger)
      $second=@(& $harvester -LanesPath $inputPath -HistoryPath $ledger -LedgerPath $ledger)
      Assert-Observed (($first -join "`n") -ceq ($second -join "`n")) 'harvest is not deterministic'
      Assert-Observed (($first -join "`n").Contains('-ObservedEndAt ''2026-10-04T12:00:00Z''')) 'report mtime was not used'
      Assert-Observed (($first -join "`n").Contains('-ObservedStartAt ''2026-10-04T10:00:00Z''')) 'late dispatch transcript creation was not emitted'
      Assert-Observed (-not ($first -join "`n").Contains('synthetic-missing')) 'missing evidence emitted a call'
      Assert-Observed (-not (Test-Path (Join-Path $scripts 'dispatch-log.jsonl'))) 'harvester wrote a ledger'
    }
  }
  if ($Scenario -cin @('all','correction','repair')) {
    $harvester=Join-Path $scripts 'harvest-observed-lanes.ps1'
    $capturePath=Join-Path $root "synthetic correction's capture.json"
    $late=[pscustomobject][ordered]@{ts='2026-10-04T13:00:00Z';kind='dispatch';lane='synthetic-8615';issue=908615}
    $captureEntry=[pscustomobject][ordered]@{lane=$late.lane;issue=$late.issue;dispatchRowUtc=$late.ts
      reportMtimeUtc='2026-10-04T12:00:00Z';transcriptCreatedUtc='2026-10-04T10:00:00Z';lateDispatchRow=$true}
    function Save-Capture($Entry, [string]$Path=$capturePath) {
      [IO.File]::WriteAllText($Path,(ConvertTo-Json -InputObject @($Entry) -Depth 16))
    }
    function Plan-Correction($Rows=@($late),$Entry=$captureEntry) {
      Write-Fixture $Rows; Save-Capture $Entry
      return @(& $harvester -LanesPath $capturePath -HistoryPath $ledger -LedgerPath $ledger)
    }
    function Apply-Plan([string[]]$Calls) {
      foreach($call in $Calls){ & ([scriptblock]::Create($call)) | Out-Null }
    }
    function Correction-Parameters($Entry=$captureEntry,[string]$Path=$capturePath) {
      Save-Capture $Entry $Path
      $history=Read-ExactHeadReviewHistory $ledger
      $capture=Read-LaneTimeCapture $Path
      $target=Get-LaneTimeDispatchTarget $history.rows[0] $history
      $source=[pscustomobject]@{path=$capture.path;sha256=$capture.sha256;lane=$Entry.lane
        startField='transcriptCreatedUtc';endField='reportMtimeUtc';dispatchField='dispatchRowUtc'}
      return @{Kind='lane-time-correction';Issue=$Entry.issue;Lane=$Entry.lane;ObservationSchema='lane-time-correction/v1'
        LaneTimeTarget=($target|ConvertTo-Json -Compress -Depth 8);LaneTimeSource=($source|ConvertTo-Json -Compress)
        ObservedStartAt=$Entry.transcriptCreatedUtc;ObservedEvidence="transcript-ctime:$($capture.path)#$($Entry.lane).transcriptCreatedUtc"}
    }
    if ($Scenario -cne 'repair') { Check 'existing-correction-exact-hours' {
      if ($Revision) {
        Save-Capture $captureEntry; Write-Fixture @($late)
        $plan=@(& $harvester -LanesPath $capturePath)
      } else { $plan=Plan-Correction }
      Assert-Observed (($plan -join "`n").Contains('-Kind lane-time-correction') -and
        -not ($plan -join "`n").Contains('-Kind dispatch')) 'existing launch must be corrected, never dispatched again'
      $prefix=[IO.File]::ReadAllText($ledger)
      Apply-Plan $plan
      $rows=@(Get-Content $ledger | ForEach-Object {$_|ConvertFrom-Json -DateKind String})
      $hours=Hours $rows
      Assert-Observed ($hours.productHours -eq 2 -and $hours.unattributedOpenLanes -eq 0) 'corrected existing launch must be exactly 2h, with no phantom open lane'
      Assert-Observed ($rows.Count -eq 3 -and @($rows|Where-Object kind -CEQ dispatch).Count -eq 1 -and
        @($rows|Where-Object kind -CEQ lane-complete).Count -eq 1) 'correction created duplicate launch/terminal'
      Assert-Observed ([IO.File]::ReadAllText($ledger).StartsWith($prefix)) 'correction rewrote original prefix'
      $projected=(Get-VelocityDispatchRows $rows).rows
      $original=@($projected|Where-Object kind -CEQ dispatch)[0]
      Assert-Observed ($original.ts -ceq $late.ts -and $original.laneTimeSourceCapture.sha256 -cmatch '^[a-f0-9]{64}$') 'projection dropped original timestamp/source annotation'
      Assert-Observed ((Get-VelocityLaneIssueMap $rows)[$late.lane].startedAt -eq $now.AddHours(-8)) 'lane age ignored correction'
    } }
    if ($Scenario -cin @('all','repair')) {
      Check 'recorded-capture-independent-terminal-and-velocity' {
        $other=[pscustomobject]@{ts=$late.ts;kind='dispatch';lane='synthetic-unrelated';issue=908615}
        $plan=Plan-Correction @($late,$other);Apply-Plan $plan
        $proposal=Correction-Parameters
        Remove-Item -LiteralPath $capturePath
        & $logger -Log dispatch -Kind lane-complete -Lane $other.lane -OutFile $ledger -NoBoard | Out-Null
        $review=@{Log='dispatch';Issue=908615;ControllerHead=('a'*40);Lane='synthetic-retained-review';LaneRole='review'
          Harness='codex';Model='gpt-6.1-sol';AuthorModel='gpt-6-astra';Effort='high';Row='11';Placement='provisional'
          Transcript='synthetic-retained-review.jsonl';ReviewerAttempt='synthetic-reviewer';AuthorAttempt='synthetic-author'
          ReviewAuthority='governing';OutFile=$ledger;NoBoard=$true}
        & $logger @review -Kind dispatch | Out-Null
        & $logger @review -Kind review-complete -Outcome PASS -ReviewContract review-contract/v2 -CompleteSweep -Blocking 0 -Candidates 0 -NonBlocking 0 | Out-Null
        $history=Read-ExactHeadReviewHistory $ledger
        Assert-Observed ((Reduce-ControllerReleaseReview -Issue 908615 -ControllerHead ('a'*40) -Mode strict-v1 -History $history).state -ceq 'authorized') 'missing capture blocked governing receipt'
        $rows=@($history.rows|ForEach-Object value)
        $filtered=Get-VelocityDispatchRows $rows
        $corrected=@($rows|Where-Object lane -CEQ $late.lane)
        Assert-Observed ($filtered.gaps.Count -eq 0 -and (Hours $corrected).productHours -eq 2) 'missing capture invalidated recorded exact 2h interval'
        Refused $proposal 'LANE_TIME_SOURCE_INVALID'
        Save-Capture $captureEntry
        [IO.File]::AppendAllText($capturePath,' ')
        Assert-Observed ((Hours $corrected).productHours -eq 2) 'modified capture invalidated persisted facts'
      }
      foreach ($shape in @('prior-terminal','prior-launch','later-disjoint-terminal')) {
        Check "prior-attempt-overlap-refused-$shape" {
          $first=[pscustomobject]@{ts='2026-10-04T09:00:00Z';kind='dispatch';lane=$late.lane;issue=908615;attemptId='synthetic-a0'}
          $done=[pscustomobject]@{ts='2026-10-04T11:00:00Z';kind='lane-complete';lane=$late.lane;attemptId='synthetic-a0'}
          $target=$late.PSObject.Copy();$target|Add-Member attemptId 'synthetic-a1'
          $rows=@($first,$done,$target)
          if ($shape -ceq 'prior-launch') { $first.ts='2026-10-04T12:30:00Z';$rows=@($first,$target) }
          if ($shape -ceq 'later-disjoint-terminal') { $rows=@($first,$target,$done) }
          $plan=@(Plan-Correction $rows)
          Assert-Observed ($plan.Count -eq 0) 'overlapping prior attempt emitted harvest calls'
          $warnings=@();$plan=@(& $harvester -LanesPath $capturePath -HistoryPath $ledger -LedgerPath $ledger -WarningVariable warnings -WarningAction SilentlyContinue)
          Assert-Observed (($warnings -join ' ').Contains('HARVEST_REFUSED') -and ($warnings -join ' ').Contains('LANE_TIME_INTERVAL_INVALID')) 'overlap plan must name interval refusal'
          $args=Correction-Parameters
          $history=Read-ExactHeadReviewHistory $ledger
          $entry=@($history.rows|Where-Object {$_.value.attemptId -ceq 'synthetic-a1'})[0]
          $args.LaneTimeTarget=(Get-LaneTimeDispatchTarget $entry $history)|ConvertTo-Json -Compress -Depth 8
          Refused $args 'LANE_TIME_INTERVAL_INVALID'
        }
      }
      Check 'ordinary-terminal-zero-full-history-calls' {
        $timePath=Join-Path $scripts 'review-head-contract.psm1'
        $original=[IO.File]::ReadAllText($timePath)
        $probe=[IO.Path]::Combine($root,'full-history-calls.txt').Replace("'","''")
        $source=$original.Replace('  $audit = [ordered]@{', "  [IO.File]::AppendAllText('$probe', 'read' + [Environment]::NewLine)`n  `$audit = [ordered]@{")
        $needle='function Get-LaneTimeProjection($History, [datetime]$Now = [datetime]::UtcNow) {'
        Assert-Observed ($source.Contains($needle) -and $source -cne $original) 'full-history instrumentation seams absent'
        $source=$source.Replace($needle,$needle + "`n  [IO.File]::AppendAllText('$probe', 'projection' + [Environment]::NewLine)")
        try {
          [IO.File]::WriteAllText($timePath,$source)
          Write-Fixture @($late)
          & $logger -Log dispatch -Kind lane-complete -Lane synthetic-ordinary -OutFile $ledger -NoBoard | Out-Null
          $calls=@(if(Test-Path $probe){Get-Content $probe})
          Assert-Observed ($calls.Count -eq 0) "ordinary terminal full-history calls=$($calls -join ',')"
          Write-Output 'MEASURE ordinary terminal Read-ExactHeadReviewHistory=0 Get-LaneTimeProjection=0'
        } finally { [IO.File]::WriteAllText($timePath,$original) }
      }
      if (-not $Revision) { Check 'observation-classifier-exact-schema' {
        $row=[pscustomobject]@{kind='dispatch';observationSchema='synthetic-other/v1';dispatchTarget='synthetic';sourceCapture='synthetic'}
        Assert-Observed (-not (Test-LaneTimeObservation $row)) 'unrelated observation fields classified as lane time'
        $row.observationSchema='lane-time-harvest/v1'
        Assert-Observed (Test-LaneTimeObservation $row) 'exact harvest schema not classified'
        $row.observationSchema='synthetic-other/v1';$row.kind='lane-time-correction'
        Assert-Observed (Test-LaneTimeObservation $row) 'correction kind must remain closed-schema validated'
      } }
      if (-not $Revision -and -not $Mutant) {
        Check 'ordinary-terminal-scale-and-contention' {
          # Keep the synthetic correction prefix in a large realistic ledger.
          $plan=Plan-Correction;Apply-Plan $plan
          if ($ScaleHistoryPath) {
            [IO.File]::AppendAllText($ledger,[IO.File]::ReadAllText($ScaleHistoryPath))
          } else {
            $writer=[IO.StreamWriter]::new($ledger,$true,[Text.UTF8Encoding]::new($false))
            try {
              for($i=0;$i -lt 26000;$i++) {
                $row=[ordered]@{ts='2026-10-03T10:00:00Z';kind=$(if($i%2){'lane-complete'}else{'dispatch'})
                  lane=('synthetic-scale-'+[int][math]::Floor($i/2));issue=908615;attemptId=('synthetic-attempt-'+$i)
                  model='gpt-6.1-sol';effort='high';row='4';placement='provisional';transcript='synthetic-scale.jsonl'
                  note=('synthetic realistic routing and lifecycle evidence '*3)}
                $writer.WriteLine(($row|ConvertTo-Json -Compress))
              }
            } finally { $writer.Dispose() }
          }
          $rows=([IO.File]::ReadAllLines($ledger)).Length
          Assert-Observed ($rows -ge 25000 -and $rows -le 30000) 'scale fixture must be approximately 26k rows'
          $timer=[Diagnostics.Stopwatch]::StartNew()
          & $logger -Log dispatch -Kind lane-complete -Lane synthetic-scale-unobserved -OutFile $ledger -NoBoard | Out-Null
          $timer.Stop();$ordinary=$timer.Elapsed.TotalSeconds
          Assert-Observed ($ordinary -lt 10) "ordinary scale append exceeded 10s bound: $ordinary"
          $timePath=Join-Path $scripts 'review-head-contract.psm1'
          $original=[IO.File]::ReadAllText($timePath)
          $marker=Join-Path $root 'private-lock-held.txt'
          $needle='  $laneToken = ConvertTo-Json -InputObject $Lane -Compress'
          Assert-Observed ($original.Contains($needle)) 'lane-scoped contention seam absent'
          $source=$original.Replace($needle,"  [IO.File]::WriteAllText('$($marker.Replace("'","''"))','held')`n  Start-Sleep -Milliseconds 1000`n"+$needle)
          $holder=$null
          try {
            [IO.File]::WriteAllText($timePath,$source)
            $holder=Start-Job -ScriptBlock {
              param($Logger,$Ledger)
              $ErrorActionPreference='Stop'
              [Diagnostics.Process]::GetCurrentProcess().PriorityClass='BelowNormal'
              $timer=[Diagnostics.Stopwatch]::StartNew()
              & $Logger -Log dispatch -Kind lane-complete -Lane synthetic-scale-holder -OutFile $Ledger -NoBoard | Out-Null
              "MEASURE holder terminal seconds=$([math]::Round($timer.Elapsed.TotalSeconds,3)) APPENDED"
            } -ArgumentList $logger,$ledger
            $wait=[Diagnostics.Stopwatch]::StartNew()
            while(-not (Test-Path $marker) -and $wait.Elapsed.TotalSeconds -lt 10){Start-Sleep -Milliseconds 50}
            Assert-Observed (Test-Path $marker) 'holder did not enter private writer lock'
            $timer.Restart()
            & $logger -Log dispatch -Kind dispatch -Issue 908615 -Lane synthetic-scale-waiter -OutFile $ledger -NoBoard | Out-Null
            $timer.Stop();$waiter=$timer.Elapsed.TotalSeconds
            Assert-Observed ($waiter -lt 10) "concurrent dispatch exceeded 10s bound: $waiter"
            Assert-Observed ($null -ne (Wait-Job $holder -Timeout 10)) 'private holder exceeded 10s completion bound'
            Receive-Job $holder -ErrorAction Stop
            Assert-Observed ($holder.State -ceq 'Completed') 'private holder failed'
            Assert-Observed (@(Select-String -LiteralPath $ledger -SimpleMatch 'synthetic-scale-holder').Count -eq 1 -and
              @(Select-String -LiteralPath $ledger -SimpleMatch 'synthetic-scale-waiter').Count -eq 1) 'contending writer row lost'
            Write-Output "MEASURE rows=$rows ordinarySeconds=$([math]::Round($ordinary,3)) concurrentDispatchSeconds=$([math]::Round($waiter,3)) both APPENDED"
          } finally {
            if($holder){if($holder.State -ceq 'Running'){Stop-Job $holder};Remove-Job $holder -Force}
            [IO.File]::WriteAllText($timePath,$original)
          }
        }
      }
    }
    if (-not $Revision -and $Scenario -cne 'repair') {
      Check 'partial-and-exact-replay-no-write' {
        $plan=Plan-Correction
        Apply-Plan @($plan[0]); $partial=[IO.File]::ReadAllBytes($ledger)
        $result=& ([scriptblock]::Create($plan[0]))
        Assert-Observed ($result -ceq 'LANE_TIME_ALREADY_RECORDED: no row appended') 'correction replay is not visibly no-write'
        Assert-Observed ([Linq.Enumerable]::SequenceEqual($partial,[IO.File]::ReadAllBytes($ledger))) 'partial replay changed bytes'
        Apply-Plan $plan; $complete=[IO.File]::ReadAllBytes($ledger)
        Apply-Plan $plan
        Assert-Observed ([Linq.Enumerable]::SequenceEqual($complete,[IO.File]::ReadAllBytes($ledger))) 'complete replay appended duplicate rows'
        $history=Read-ExactHeadReviewHistory $ledger
        Assert-Observed ($history.rows.Count -eq 3) 'replay created another interval'
      }
      Check 'wrong-attempt-refused' {
        Write-Fixture @($late);$args=Correction-Parameters
        $target=$args.LaneTimeTarget|ConvertFrom-Json -DateKind String
        $target.attempts|Add-Member attemptId 'synthetic-wrong-attempt'
        $args.LaneTimeTarget=$target|ConvertTo-Json -Compress -Depth 8
        Refused $args 'LANE_TIME_TARGET_INVALID'
      }
      Check 'before-observed-start-refused' {
        Write-Fixture @($late);$bad=$captureEntry.PSObject.Copy();$bad.reportMtimeUtc='2026-10-04T09:00:00Z'
        Refused (Correction-Parameters $bad) 'LANE_TIME_INTERVAL_INVALID'
      }
      Check 'conflicting-replay-refused' {
        $plan=Plan-Correction;Apply-Plan @($plan[0])
        $otherPath=Join-Path $root 'synthetic-alternate-capture.json'
        Refused (Correction-Parameters $captureEntry $otherPath) 'LANE_TIME_REPLAY_CONFLICT'
      }
      Check 'target-source-and-closed-schema-refusals' {
        foreach($case in @('hash','ts','lane','issue','digest','nested-target','nested-source','source-field','unknown-top','fractional-issue')) {
          Write-Fixture @($late);$args=Correction-Parameters
          $target=$args.LaneTimeTarget|ConvertFrom-Json -DateKind String
          $source=$args.LaneTimeSource|ConvertFrom-Json -DateKind String
          $code='LANE_TIME_TARGET_INVALID'
          switch($case){
            hash {$target.rawSha256='a'*64}
            ts {$target.ts='2026-10-04T13:01:00Z'}
            lane {$args.Lane='synthetic-wrong-lane';$code='LANE_TIME_SOURCE_INVALID'}
            issue {$args.Issue=908616}
            digest {$source.sha256='a'*64;$code='LANE_TIME_SOURCE_INVALID'}
            nested-target {$target.attempts|Add-Member unknown 'bad';$code='LANE_TIME_SCHEMA_INVALID'}
            nested-source {$source|Add-Member unknown 'bad';$code='LANE_TIME_SCHEMA_INVALID'}
            source-field {$source.startField='transcriptLastwriteUtc';$code='LANE_TIME_SOURCE_INVALID'}
            unknown-top {$args.Outcome='PASS';$code='LANE_TIME_SCHEMA_INVALID'}
            fractional-issue {$args.Issue=908615.5;$code='LANE_TIME_SCHEMA_INVALID'}
          }
          $args.LaneTimeTarget=$target|ConvertTo-Json -Compress -Depth 8
          $args.LaneTimeSource=$source|ConvertTo-Json -Compress
          Refused $args $code
        }
      }
      Check 'capture-facts-and-history-refusals' {
        foreach($case in @('issue','dispatch','launch','future','non-UTC','missing-report','missing-start','ambiguous-source','duplicate-target','malformed','unterminated')) {
          Write-Fixture @($late);$args=Correction-Parameters
          $bad=$captureEntry.PSObject.Copy();$code='LANE_TIME_SOURCE_INVALID'
          switch($case){
            issue {$bad.issue=908616}
            dispatch {$bad.dispatchRowUtc='2026-10-04T13:01:00Z';$code='LANE_TIME_INTERVAL_INVALID'}
            launch {
              $launch=$late.PSObject.Copy();$launch|Add-Member observedStartAt '2026-10-04T11:00:00Z'
              $launch|Add-Member observedEvidence 'transcript-ctime:synthetic-canonical-launch'
              Write-Fixture @($launch);$args=Correction-Parameters;$code='LANE_TIME_LAUNCH_CONFLICT'
            }
            future {$bad.reportMtimeUtc='2999-10-04T12:00:00Z';$code='LANE_TIME_INTERVAL_INVALID'}
            non-UTC {$bad.transcriptCreatedUtc='2026-10-04T10:00:00-05:00';$code='OBSERVED_TIME_INVALID'}
            missing-report {$bad.reportMtimeUtc=$null;$code='OBSERVED_TIME_INVALID'}
            missing-start {$bad.transcriptCreatedUtc=$null;$code='OBSERVED_TIME_INVALID'}
            ambiguous-source {Save-Capture @($bad,$bad)}
            duplicate-target {Write-Fixture @($late,$late);$code='LANE_TIME_TARGET_INVALID'}
            malformed {[IO.File]::AppendAllText($ledger,"{broken`n");$code='LANE_TIME_HISTORY_INVALID'}
            unterminated {[IO.File]::WriteAllText($ledger,($late|ConvertTo-Json -Compress));$code='OBSERVED_HISTORY_INVALID'}
          }
          if($case -cnotin @('launch','duplicate-target','malformed','unterminated')){
            if($case -cne 'ambiguous-source'){Save-Capture $bad}
            $source=$args.LaneTimeSource|ConvertFrom-Json;$source.sha256=(Read-LaneTimeCapture $capturePath).sha256
            $args.LaneTimeSource=$source|ConvertTo-Json -Compress
          }
          Refused $args $code
        }
      }
      Check 'stale-plan-and-existing-terminal-refused' {
        $plan=Plan-Correction
        $next=$late.PSObject.Copy();$next.ts='2026-10-04T14:00:00Z';$next|Add-Member attemptId 'synthetic-next-attempt'
        [IO.File]::AppendAllText($ledger,($next|ConvertTo-Json -Compress)+"`n")
        $before=[IO.File]::ReadAllBytes($ledger);$message=''
        try{Apply-Plan $plan}catch{$message=$_.Exception.Message}
        Assert-Observed ($message.Contains('LANE_TIME_TARGET_STALE')) 'stale planned target was closed'
        Assert-Observed ([Linq.Enumerable]::SequenceEqual($before,[IO.File]::ReadAllBytes($ledger))) 'stale plan changed bytes'
        $existing=[pscustomobject]@{ts='2026-10-04T14:00:00Z';kind='lane-complete';lane=$late.lane}
        Write-Fixture @($late,$existing)
        Refused (Correction-Parameters) 'LANE_TIME_TERMINAL_CONFLICT'
      }
      Check 'unbound-terminal-refused-and-later-reuse-preserved' {
        $plan=Plan-Correction;Apply-Plan $plan
        Refused @{Kind='lane-complete';Lane=$late.lane} 'LANE_TIME_TARGET_REQUIRED'
        $next=[pscustomobject]@{ts='2026-10-04T14:00:00Z';kind='dispatch';lane=$late.lane;issue=908615;attemptId='synthetic-later-reuse'}
        $done=[pscustomobject]@{ts='2026-10-04T15:00:00Z';kind='lane-complete';lane=$late.lane;attemptId=$next.attemptId}
        [IO.File]::AppendAllText($ledger,($next|ConvertTo-Json -Compress)+"`n"+($done|ConvertTo-Json -Compress)+"`n")
        $rows=@(Get-Content $ledger|ForEach-Object{$_|ConvertFrom-Json -DateKind String})
        $hours=Hours $rows
        Assert-Observed ($hours.productHours -eq 3 -and $hours.unattributedOpenLanes -eq 0) 'later reuse retroactively invalidated recorded correction'
        Apply-Plan $plan
        Assert-Observed ((Read-ExactHeadReviewHistory $ledger).rows.Count -eq 5) 'replay after later reuse duplicated recorded interval'
        $plan=Plan-Correction;Apply-Plan $plan
        [IO.File]::AppendAllText($ledger,($done|ConvertTo-Json -Compress)+"`n")
        $rows=@(Get-Content $ledger|ForEach-Object{$_|ConvertFrom-Json -DateKind String})
        Assert-Observed ($null -eq (Hours $rows).productShare) 'unbound poisoned terminal became healthy share'
      }
      Check 'distinct-attempts-equal-time-and-routing-pairing' {
        $first=$late.PSObject.Copy();$first|Add-Member attemptId 'synthetic-first-attempt'
        $next=$late.PSObject.Copy();$next.ts='2026-10-04T12:00:00Z';$next|Add-Member attemptId 'synthetic-next-attempt'
        $done=[pscustomobject]@{ts='2026-10-04T15:00:00Z';kind='lane-complete';lane=$late.lane;attemptId='synthetic-next-attempt'}
        $route=$first.PSObject.Copy();$route|Add-Member dispatchRoutingSchema 'watchdog-dispatch-routing/v1'
        $plan=Plan-Correction @($first,$route,$next,$done)
        Assert-Observed ($plan.Count -eq 2) 'distinct bound attempt plan refused'
        Apply-Plan $plan
        $rows=@(Get-Content $ledger|ForEach-Object{$_|ConvertFrom-Json -DateKind String})
        $hours=Hours $rows
        Assert-Observed ($hours.productHours -eq 5 -and $hours.unattributedOpenLanes -eq 0) 'bound end closed next attempt, tie changed pairing, or routing counted twice'
      }
      Check 'share-window-and-poisoned-correction-gap' {
        $plan=Plan-Correction;Apply-Plan $plan
        $other=[pscustomobject]@{ts='2026-10-04T10:00:00Z';kind='dispatch';lane='synthetic-controller';issue=908616}
        $done=[pscustomobject]@{ts='2026-10-04T11:00:00Z';kind='lane-complete';lane=$other.lane}
        $rows=@(Get-Content $ledger|ForEach-Object{$_|ConvertFrom-Json -DateKind String})+@($other,$done)
        $hours=Hours $rows
        Assert-Observed ($hours.productHours -eq 2 -and $hours.otherHours -eq 1 -and $hours.productShare -eq 0.667) 'mixed share oracle must be 2/(2+1)'
        $clipped=$captureEntry.PSObject.Copy();$clipped.transcriptCreatedUtc='2026-10-01T10:00:00Z'
        $plan=Plan-Correction @($late) $clipped;Apply-Plan $plan
        $rows=@(Get-Content $ledger|ForEach-Object{$_|ConvertFrom-Json -DateKind String})
        Assert-Observed ((Hours $rows).productHours -eq 42) 'correction ignored 48h clipping'
        $rows[1].dispatchTarget.attempts|Add-Member unknown 'poison'
        $filtered=Get-VelocityDispatchRows $rows
        $hours=Hours $rows
        Assert-Observed ($filtered.gaps.Count -gt 0 -and $null -eq $hours.productShare) 'malformed correction became trustworthy partial share'
      }
      Check 'correction-authority-neutral' {
        Write-Fixture @($late); Save-Capture $captureEntry
        $review=@{Log='dispatch';Issue=908615;ControllerHead=('a'*40);Lane='synthetic-controller-review';LaneRole='review'
          Harness='codex';Model='gpt-6.1-sol';AuthorModel='gpt-6-astra';Effort='high';Row='11';Placement='provisional'
          Transcript='synthetic-review.jsonl';ReviewerAttempt='synthetic-reviewer';AuthorAttempt='synthetic-author'
          ReviewAuthority='governing';OutFile=$ledger;NoBoard=$true}
        & $logger @review -Kind dispatch | Out-Null
        & $logger @review -Kind review-complete -Outcome PASS -ReviewContract review-contract/v2 -CompleteSweep -Blocking 0 -Candidates 0 -NonBlocking 0 | Out-Null
        $review.Remove('ControllerHead');$review.Lane='synthetic-ordinary-review';$review.Pr=908615;$review.ReviewedHead='a'*40
        & $logger @review -Kind review-complete -Outcome PASS -ReviewContract review-contract/v2 -CompleteSweep -Blocking 0 -Candidates 0 -NonBlocking 0 | Out-Null
        $before=Read-ExactHeadReviewHistory $ledger
        $plan=@(& $harvester -LanesPath $capturePath -HistoryPath $ledger -LedgerPath $ledger)
        Apply-Plan $plan
        $history=Read-ExactHeadReviewHistory $ledger
        $ordinaryBefore=Reduce-ExactHeadReview -Pr 908615 -CurrentHead ('a'*40) -History $before
        $ordinaryAfter=Reduce-ExactHeadReview -Pr 908615 -CurrentHead ('a'*40) -History $history
        $controllerBefore=Reduce-ControllerReleaseReview -Issue 908615 -ControllerHead ('a'*40) -Mode strict-v1 -History $before
        $controllerAfter=Reduce-ControllerReleaseReview -Issue 908615 -ControllerHead ('a'*40) -Mode strict-v1 -History $history
        Assert-Observed ($ordinaryBefore.state -ceq $ordinaryAfter.state -and $ordinaryBefore.reason -ceq $ordinaryAfter.reason -and
          $controllerBefore.state -ceq $controllerAfter.state -and $controllerBefore.reason -ceq $controllerAfter.reason) 'telemetry correction created review authority'
        Assert-Observed ($ordinaryBefore.state -ceq 'authorized' -and $controllerBefore.state -ceq 'authorized') 'positive authority control did not reach PASS'
        $unreviewed=Reduce-ExactHeadReview -Pr 908616 -CurrentHead ('b'*40) -History $history
        Assert-Observed ($unreviewed.state -cne 'authorized') 'correction manufactured unreviewed PASS'
      }
    }
  }
  if ($failures.Count) { throw "$($failures.Count) observed-time checks failed" }
  Write-Output "PASS observed-lane-time scenario=$Scenario mutant=$Mutant"
} finally {
  if ($scope) { Exit-RoutingDataTestScope $scope }
  $absolute=[IO.Path]::GetFullPath($root)
  Assert-Observed ($absolute.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $absolute -Leaf).StartsWith('synthetic-8615-')) 'cleanup outside private root'
  Remove-Item -LiteralPath $absolute -Recurse -Force
}
