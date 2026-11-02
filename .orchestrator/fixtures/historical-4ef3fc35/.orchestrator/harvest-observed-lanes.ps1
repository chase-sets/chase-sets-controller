<#
.SYNOPSIS
Emit a deterministic observation-only harvest plan; never execute or write it.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$LanesPath,
  [string]$HistoryPath = (Join-Path $PSScriptRoot 'dispatch-log.jsonl'),
  [string]$LoggerPath = (Join-Path $PSScriptRoot 'log-event.ps1'),
  [string]$LedgerPath = ''
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'review-head-contract.psm1') -Force -DisableNameChecking
function Quote-Harvest([string]$Value) { return "'" + $Value.Replace("'", "''") + "'" }
$capture = Read-LaneTimeCapture $LanesPath
$history = Read-ExactHeadReviewHistory -Path $HistoryPath
if (-not $history.complete) { throw "HARVEST_HISTORY_INVALID: $($history.reason)" }
$bytes = [IO.File]::ReadAllBytes([IO.Path]::GetFullPath($HistoryPath))
if ($bytes.Length -and $bytes[-1] -ne 10) { throw 'HARVEST_HISTORY_INVALID: unterminated history' }
$projection = Get-LaneTimeProjection $history
if ($projection.gaps.Count) { throw "HARVEST_HISTORY_INVALID: $($projection.gaps[0])" }
$calls = [Collections.Generic.List[string]]::new()
$refusals = [Collections.Generic.List[string]]::new()
$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$now = [datetime]::UtcNow
foreach ($lane in @($capture.entries | Sort-Object { [string](Get-ObservedLaneValue $_ 'lane') })) {
  $name = Get-ObservedLaneValue $lane 'lane'
  $issue = Get-ObservedLaneValue $lane 'issue'
  if ($name -isnot [string] -or $name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$' -or
      -not (Test-WholeNumber $issue 1) -or $issue -gt [int]::MaxValue -or
      -not $seen.Add($name)) { throw 'HARVEST_INPUT_INVALID: unique lane and positive integer issue required' }
  $end = Get-ObservedLaneValue $lane 'reportMtimeUtc'
  $dispatch = Get-ObservedLaneValue $lane 'dispatchRowUtc'
  $created = Get-ObservedLaneValue $lane 'transcriptCreatedUtc'
  $late = Get-ObservedLaneValue $lane 'lateDispatchRow'
  if ($late -isnot [bool]) { throw 'HARVEST_INPUT_INVALID: lateDispatchRow must be a boolean' }
  if (-not $end -or -not $dispatch -or ($late -and -not $created)) {
    $refusals.Add("HARVEST_EVIDENCE_MISSING: $name"); continue
  }
  $endAt = ConvertTo-ObservedLaneUtc $end
  $dispatchAt = ConvertTo-ObservedLaneUtc $dispatch
  $startAt = if ($late) { ConvertTo-ObservedLaneUtc $created } else { $dispatchAt }
  if ($endAt -gt $now -or $dispatchAt -gt $now -or $startAt -gt $dispatchAt -or $endAt -lt $startAt) {
    throw "HARVEST_TIME_INVALID: $name has inconsistent or future evidence"
  }
  try {
    $targets = @(Get-LaneTimeLaneRows $history $name | Where-Object {
      (Test-LaneTimeLaunch $_.value) -and
        (ConvertTo-ObservedLaneUtc ([string]$_.value.ts)) -eq $dispatchAt
    })
    if ($targets.Count -ne 1) { throw 'LANE_TIME_TARGET_INVALID: missing or ambiguous captured dispatch' }
    $target = Get-LaneTimeDispatchTarget $targets[0] $history
    $source = [pscustomobject][ordered]@{path=$capture.path;sha256=$capture.sha256;lane=$name
      startField=$(if($late){'transcriptCreatedUtc'}else{'dispatchRowUtc'});endField='reportMtimeUtc';dispatchField='dispatchRowUtc'}
    $common = [ordered]@{ts=$now.ToString('o');lane=$name;issue=$issue;dispatchTarget=$target;sourceCapture=$source}
    $planned = [Collections.Generic.List[object]]::new()
    if ($late) {
      $row = [pscustomobject]($common + [ordered]@{kind='lane-time-correction';observationSchema='lane-time-correction/v1'
        observedStartAt=$created;observedEvidence="transcript-ctime:$($capture.path)#${name}.transcriptCreatedUtc"})
      [void](Assert-LaneTimeObservationHistory $row $history $now)
      $planned.Add($row)
    }
    $row = [pscustomobject]($common + [ordered]@{kind='lane-complete';observationSchema='lane-time-harvest/v1'
      observedEndAt=$end;observedEvidence="report-mtime:$($capture.path)#${name}.reportMtimeUtc"})
    [void](Assert-LaneTimeObservationHistory $row $history $now)
    $planned.Add($row)
    foreach ($row in $planned) {
      $call = '& ' + (Quote-Harvest ([IO.Path]::GetFullPath($LoggerPath))) + ' -Log dispatch -Kind ' + $row.kind +
        ' -Lane ' + (Quote-Harvest $name) + " -Issue $issue -NoBoard -ObservationSchema " + (Quote-Harvest $row.observationSchema) +
        ' -LaneTimeTarget ' + (Quote-Harvest ($target | ConvertTo-Json -Compress -Depth 8)) +
        ' -LaneTimeSource ' + (Quote-Harvest ($source | ConvertTo-Json -Compress -Depth 8)) +
        ' -ObservedEvidence ' + (Quote-Harvest $row.observedEvidence)
      $call += if ($row.kind -ceq 'lane-time-correction') { ' -ObservedStartAt ' + (Quote-Harvest $created) }
        else { ' -ObservedEndAt ' + (Quote-Harvest $end) }
      if ($LedgerPath) { $call += ' -OutFile ' + (Quote-Harvest ([IO.Path]::GetFullPath($LedgerPath))) }
      $calls.Add($call)
    }
  } catch { $refusals.Add("HARVEST_REFUSED: ${name}: $($_.Exception.Message)") }
}
foreach ($refusal in $refusals) { Write-Warning $refusal }
Write-Verbose "HARVEST_PLAN calls=$($calls.Count) refusedLanes=$($refusals.Count)"
$calls.ToArray()
