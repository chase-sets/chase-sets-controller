[CmdletBinding()]
param(
  [string]$ContainerRoot = (Split-Path -Parent $PSScriptRoot),
  [string]$FactsPath = "",
  [string]$FactsOut = "",
  [string]$ObservationLog = "",
  [string]$NowUtc = "",
  [string]$CycleId = "",
  [string]$LandingCapturePath = "",
  [switch]$NoRecord,
  [switch]$Summary
)

# velocity-report/v1 (#8207). Read-only reducer over GitHub and dispatch-log
# facts. It raises exactly two alarms, FLOOR and DROUGHT; everything else is
# diagnostic context. Incomplete facts yield UNKNOWN, never OK.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 3.0
. (Join-Path $PSScriptRoot 'merge-hold-state.ps1')
Import-Module (Join-Path $PSScriptRoot 'review-head-contract.psm1') -Force -DisableNameChecking

$script:VelocityRepo = "chase-sets/chase-sets"
$script:FloorLanes = 2
$script:FloorRunMinutes = 60
$script:FloorGraceHours = 2
$script:FloorRearmHours = 4
$script:DroughtHours = 48
$script:DroughtGraceHours = 4
$script:StaleAttemptHours = 8
$script:DecisionHeavyCount = 3
$script:VelocityPolicy = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'velocity-policy.psd1')
$script:TerminalKinds = @("lane-complete", "lane-blocked", "review-complete", "repair-complete", "verify-complete", "decision-resolved")

function ConvertTo-VelocityUtc([object]$Value) {
  if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
  if ($Value -is [datetime]) { return ([datetime]$Value).ToUniversalTime() }
  return [datetime]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)
}

function Format-VelocityUtc([datetime]$Value) {
  return $Value.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ", [Globalization.CultureInfo]::InvariantCulture)
}

function Test-VelocityProductIssue($Issue, [int[]]$PlatformMilestones, [int[]]$ControllerIssues = @()) {
  if ($null -eq $Issue) { return $false }
  $milestone = Get-VelocityValue $Issue 'milestone'
  if ($null -eq $milestone -or -not (Get-VelocityValue $milestone 'committed' $false) -or
    [string](Get-VelocityValue $milestone 'state') -cne 'OPEN' -or
    [string](Get-VelocityValue $milestone 'track') -cnotin $script:VelocityPolicy.ProductTracks -or
    $PlatformMilestones -contains [int]$milestone.number -or
    $script:VelocityPolicy.ControllerEvidenceMilestones -contains [int]$milestone.number) { return $false }
  if ($ControllerIssues -contains [int]$Issue.number -or [string](Get-VelocityValue $Issue 'title') -match '^\[controller\]') { return $false }
  return @($Issue.labels) -cnotcontains 'status:parked' -and
    [string](Get-VelocityValue $Issue 'terminalState' 'none') -cin @('none', 'reentered')
}

function Get-VelocityControllerIssues([object[]]$Rows, [datetime]$Now) {
  $Rows = (Get-VelocityDispatchRows $Rows).rows
  $map = Get-VelocityLaneIssueMap $Rows
  return @($Rows | Where-Object {
    $at = Get-ObservedLaneTime $_
    # Ownership is durable; only metric observations have a seven-day window.
    $_.kind -cin @('dispatch', 'review-complete') -and $null -ne $at -and $at -le $Now -and
      ([string](Get-VelocityValue $_ 'reviewTarget') -ceq 'controller' -or
       (Test-HoldInteger (Get-VelocityValue $_ 'controllerIssue')) -or
       (Get-VelocityValue $_ 'controllerIssue') -ceq $true -or
       [string](Get-VelocityValue $_ 'lane') -cmatch '^controller-' -or
       [string](Get-VelocityValue $_ 'label') -cmatch '^controller-')
  } | ForEach-Object {
    $controllerIssue = Get-VelocityValue $_ 'controllerIssue'
    $issue = Get-VelocityValue $_ 'issue'
    $explicitMarker = [string](Get-VelocityValue $_ 'reviewTarget') -ceq 'controller' -or
      (Test-HoldInteger $controllerIssue) -or $controllerIssue -ceq $true
    $prefixes = @(@((Get-VelocityValue $_ 'label'), (Get-VelocityValue $_ 'lane')) | ForEach-Object {
      $match = [regex]::Match([string]$_, '^controller-([1-9][0-9]*)(?:-|$)')
      $number = 0
      if ($match.Success -and [int]::TryParse($match.Groups[1].Value, [ref]$number)) { $number }
    } | Sort-Object -Unique)
    if (Test-HoldInteger $controllerIssue) { [int]$controllerIssue }
    $resolved = if (Test-HoldInteger $issue) { [int]$issue } else {
      $entry = $map[[string](Get-VelocityValue $_ 'label' (Get-VelocityValue $_ 'lane' ''))]
      if ($null -ne $entry) { [int]$entry.issue } else { $null }
    }
    # A reusable numbered seat owns its number, not a foreign product attempt.
    if ($null -ne $resolved -and ($explicitMarker -or $prefixes.Count -eq 0 -or $prefixes -contains $resolved)) { $resolved }
    elseif ($prefixes.Count -eq 1) { $prefixes[0] }
  } | Sort-Object -Unique)
}

function Test-VelocityReadyIssue($Issue, [int[]]$PlatformMilestones, [int[]]$ControllerIssues = @(), [switch]$AllowReentry) {
  $labels = @($Issue.labels | ForEach-Object { [string]$_ })
  $candidate = $Issue
  if ($AllowReentry) { $candidate=$Issue.PSObject.Copy();$candidate.terminalState='reentered' }
  if (-not (Test-VelocityProductIssue $candidate $PlatformMilestones $ControllerIssues)) { return $false }
  if (@($labels | Where-Object { $_.StartsWith("status:", [StringComparison]::Ordinal) -or $_ -ceq "decision" }).Count -gt 0) { return $false }
  if ($null -eq $Issue.milestone -or -not [bool]$Issue.milestone.committed) { return $false }
  if ($PlatformMilestones -contains [int]$Issue.milestone.number) { return $false }
  return ([int]$Issue.openBlockers -eq 0)
}

function Get-VelocityValue($Value,[string]$Name,$Default=$null) {
  if($null -ne $Value -and $null -ne $Value.PSObject.Properties[$Name]){return $Value.$Name}
  return $Default
}

function Get-VelocityDispatchRows([object[]]$Rows,[switch]$HistoryRows) {
  $valid=[Collections.Generic.List[object]]::new()
  $gaps=[Collections.Generic.List[string]]::new()
  $legacy=[Collections.Generic.List[int]]::new()
  $nonPositiveIssues=[Collections.Generic.List[int]]::new()
  $history=[Collections.Generic.List[object]]::new()
  $hasLaneTimeObservation=$false
  $index=0
  foreach($entry in $Rows){
    $index++
    $row=if($HistoryRows){$entry.value}else{$entry}
    if(Test-LaneTimeObservation $row){$hasLaneTimeObservation=$true}
    $line=if($HistoryRows){[int]$entry.line}else{[int](Get-VelocityValue $row 'line' $index)}
    $raw = if ($HistoryRows) { [string](Get-VelocityValue $entry 'raw' '') } else { [string](Get-VelocityValue $row 'laneTimeOriginalRaw' '') }
    if ($raw) { $row = $raw | ConvertFrom-Json -DateKind String }
    elseif ($null -ne $row) {
      $rawRow=$row.PSObject.Copy()
      $rawRow.PSObject.Properties.Remove('line')
      $raw=$rawRow | ConvertTo-Json -Compress -Depth 64
    }
    $ts=Get-VelocityValue $row 'ts'
    $kind=Get-VelocityValue $row 'kind'
    $parsed=[datetimeoffset]::MinValue
    $validTime=$ts -is [datetime] -or ($ts -is [string] -and
      $ts -cmatch '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,7})?(?:Z|[+-]\d\d:\d\d)$' -and
      [datetimeoffset]::TryParse($ts,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$parsed))
    $reason=if(-not $validTime){'timestamp'}elseif($kind -isnot [string] -or [string]::IsNullOrWhiteSpace($kind)){'kind'}else{$null}
    if (-not $reason) {
      try { Assert-ObservedLaneFields $row ([datetime]::UtcNow) }
      catch { $reason = ($_.Exception.Message -split ':',2)[0] }
    }
    if($reason){
      $consumerFields=@('kind','issue','pr','outcome','integrationAuthoritySchema','authorityState')
      if(-not $validTime -and @($consumerFields|Where-Object{$null -ne $row -and $null -ne $row.PSObject.Properties[$_]}).Count -eq 0){
        $legacy.Add($line)
      }else{$gaps.Add("dispatch-row-invalid:${line}:$reason")}
      continue
    }
    $issue=Get-VelocityValue $row 'issue'
    if(($issue -is [int] -or $issue -is [long]) -and $issue -le 0){$nonPositiveIssues.Add($line)}
    $history.Add([pscustomobject]@{line=$line;raw=$raw;rawSha256=(Get-LaneTimeHash ([Text.Encoding]::UTF8.GetBytes($raw)));value=$row})
  }
  if(-not $hasLaneTimeObservation) {
    foreach($entry in $history){
      $row=$entry.value
      if($HistoryRows){$row=$row.PSObject.Copy();$row|Add-Member line $entry.line -Force}
      $valid.Add($row)
    }
    return [pscustomobject]@{rows=$valid.ToArray();gaps=$gaps.ToArray();legacyDispatchRows=$legacy.ToArray();nonPositiveIssueDispatchRows=$nonPositiveIssues.ToArray()}
  }
  $projection=Get-LaneTimeProjection ([pscustomobject]@{complete=($gaps.Count -eq 0);reason='VELOCITY_HISTORY_INVALID';rows=$history.ToArray()})
  foreach($gap in $projection.gaps){$gaps.Add($gap)}
  for($i=0;$i -lt $projection.rows.Count;$i++){
    $row=$projection.rows[$i]
    $row|Add-Member line $history[$i].line -Force
    $row|Add-Member laneTimeOriginalRaw $history[$i].raw -Force
    $row|Add-Member laneTimeRawSha256 $history[$i].rawSha256 -Force
    $valid.Add($row)
  }
  return [pscustomobject]@{rows=$valid.ToArray();gaps=$gaps.ToArray();legacyDispatchRows=$legacy.ToArray();nonPositiveIssueDispatchRows=$nonPositiveIssues.ToArray()}
}

function Get-VelocityLaneIssueMap([object[]]$Rows,[int[]]$KnownIssues=@()) {
  $nodes=@{};$aliases=@{};$seatHistory=@{}
  foreach($row in @((Get-VelocityDispatchRows $Rows).rows|Sort-Object -Stable {Get-ObservedLaneTime $_})) {
    if([string]$row.kind -cne 'dispatch'){continue}
    $lane=[string](Get-VelocityValue $row 'lane' '')
    $label=[string](Get-VelocityValue $row 'label' $lane)
    if(-not $label){continue}
    if(-not $nodes.ContainsKey($label)){$nodes[$label]=@{issues=@();links=@();prefix=$null;startedAt=(Get-ObservedLaneTime $row);invalid=$false;route=$null}}
    $node=$nodes[$label]
    if((Get-ObservedLaneTime $row) -gt $node.startedAt){$node.startedAt=Get-ObservedLaneTime $row}
    if(Get-VelocityValue $row 'dispatchRoutingSchema'){$node.route=$row}
    $issue=Get-VelocityValue $row 'issue'
    if($null -ne $issue){
      if(Test-HoldInteger $issue){$node.issues+=@([int]$issue)}else{$node.invalid=$true}
    } else {
      $attempt=[string](Get-VelocityValue $row 'attemptId' '')
      if($attempt -and $attempt -cne $label){$node.links+=@($attempt)}
      if($label -cmatch '-c[1-9][0-9]*$' -and $seatHistory.ContainsKey($lane)){
        $node.links+=@($seatHistory[$lane]|Where-Object{$_ -cne $label})
      }
      $prefix=[regex]::Match($label,'^([1-9][0-9]*)-')
      if($prefix.Success -and $KnownIssues -contains $prefix.Groups[1].Value -and $label -cnotmatch '-c[0-9]+$'){
        # Only a canonical issue in this census can supply an absent annotation.
        $node.prefix=[int]$prefix.Groups[1].Value
      }
    }
    if($lane){
      if($label -cne $lane){$aliases[$lane]=$label}
      if(-not $seatHistory.ContainsKey($lane)){$seatHistory[$lane]=@()}
      $seatHistory[$lane]+= @($label)
    }
    $worktree=[string](Get-VelocityValue $row 'worktree' '')
    if($worktree){$aliases[[IO.Path]::GetFullPath($worktree).TrimEnd('\','/')]=$label;$aliases[(Split-Path -Leaf $worktree)]=$label}
  }
  function Resolve-VelocityNode([string]$Key,[string[]]$Stack=@()) {
    if($Stack -ccontains $Key -or -not $nodes.ContainsKey($Key)){return $null}
    $n=$nodes[$Key]
    if($n.invalid){return $null}
    $issues=@($n.issues|Sort-Object -Unique)
    if($issues.Count -gt 1){return $null}
    if($issues.Count -eq 0){
      foreach($link in @($n.links|Sort-Object -Unique)){
        $resolved=Resolve-VelocityNode $link @($Stack+$Key)
        if($null -eq $resolved){return $null}
        $issues+=@($resolved.issue)
      }
      $issues=@($issues|Sort-Object -Unique)
      if($issues.Count -eq 0 -and $n.links.Count -eq 0 -and $null -ne $n.prefix){$issues=@($n.prefix)}
    }
    if($issues.Count -ne 1){return $null}
    return [pscustomobject]@{issue=[int]$issues[0];startedAt=$n.startedAt;label=$Key;route=$n.route}
  }
  $result=@{}
  foreach($key in $nodes.Keys){$entry=Resolve-VelocityNode $key;if($null -ne $entry){$result[$key]=$entry}}
  foreach($key in $aliases.Keys){$entry=Resolve-VelocityNode $aliases[$key];if($null -ne $entry){$result[$key]=$entry}else{$result.Remove($key)}}
  return $result
}

function Get-VelocityIssue($Facts, [int]$Issue) {
  $key = [string]$Issue
  $open = @($Facts.productIssues | Where-Object { [int]$_.number -eq $Issue })
  if ($open.Count -gt 0) { return $open[0] }
  $details = Get-VelocityValue $Facts 'issueDetails'
  return Get-VelocityValue $details $key
}

function Get-VelocityProductMerges($Facts, [datetime]$Now, [int[]]$ControllerIssues) {
  return @($Facts.merges | Where-Object {
    (ConvertTo-VelocityUtc $_.mergedAt) -le $Now -and @($_.issues | Where-Object {
      $issue = Get-VelocityIssue $Facts ([int]$_.number)
      if ($null -eq $issue) { $issue = $_ }
      Test-VelocityProductIssue $issue @($Facts.platformMilestones) $ControllerIssues
    }).Count -gt 0
  } | Sort-Object { ConvertTo-VelocityUtc $_.mergedAt })
}

function Test-VelocityCheckProvenance($Value) {
  if(-not (Test-HoldKeys $Value @('nodeType','databaseId','status','conclusion','completedAt','producer'))){return $false}
  if($Value.nodeType -ceq 'StatusContext'){
    return $null -eq $Value.databaseId -and $null -eq $Value.conclusion -and $null -eq $Value.completedAt -and $null -eq $Value.producer -and
      $Value.status -cin @('ERROR','EXPECTED','FAILURE','PENDING','SUCCESS')
  }
  if($Value.nodeType -cne 'CheckRun' -or -not (Test-HoldInteger $Value.databaseId) -or
    -not (Test-HoldKeys $Value.producer @('appDatabaseId','workflowDatabaseId')) -or
    -not (Test-HoldInteger $Value.producer.appDatabaseId) -or -not (Test-HoldInteger $Value.producer.workflowDatabaseId)){return $false}
  if($Value.status -ceq 'COMPLETED'){
    return (Test-HoldInstant $Value.completedAt) -and $Value.conclusion -cin @('ACTION_REQUIRED','CANCELLED','FAILURE','NEUTRAL','SKIPPED','STALE','STARTUP_FAILURE','SUCCESS','TIMED_OUT')
  }
  return $Value.status -cin @('IN_PROGRESS','PENDING','QUEUED','REQUESTED','WAITING') -and $null -eq $Value.completedAt -and $null -eq $Value.conclusion
}

function Test-VelocityLandingRecord($Record) {
  try {
  if(-not (Test-HoldKeys $Record @('repository','pr','headOid','observedAt','queueEntryId','reviewReduction','requiredCheckAuthority','nonHoldPrerequisites')) -or
    $Record.repository -isnot [string] -or $Record.repository -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or
    -not (Test-HoldInteger $Record.pr) -or $Record.pr -gt [int]::MaxValue -or $Record.headOid -isnot [string] -or $Record.headOid -cnotmatch '^[a-f0-9]{40}$' -or
    -not (Test-HoldInstant $Record.observedAt) -or ($null -ne $Record.queueEntryId -and ($Record.queueEntryId -isnot [string] -or $Record.queueEntryId -cnotmatch '^[A-Za-z0-9_=-]+$'))){return $false}
  $r=$Record.reviewReduction
  if(-not (Test-HoldKeys $r @('schema','currentHead','state','reason','latest')) -or $r.schema -cne 'velocity-review-reduction/v1' -or
    $r.currentHead -cne $Record.headOid -or $r.state -cnotin @('authorized','blocked','stale','unknown') -or $r.reason -isnot [string] -or -not $r.reason){return $false}
  if($null -ne $r.latest){
    if(-not (Test-HoldKeys $r.latest @('receiptIdentity','outcome','authorizedHead')) -or $r.latest.receiptIdentity -cnotmatch '^[a-f0-9]{64}$' -or
      $r.latest.outcome -cnotin @('PASS','BLOCK_FIXABLE','BLOCK_REPLAN','SKIP') -or $r.latest.authorizedHead -cnotmatch '^[a-f0-9]{40}$'){return $false}
  }
  if($r.state -ceq 'authorized' -and ($null -eq $r.latest -or $r.latest.outcome -cne 'PASS' -or $r.latest.authorizedHead -cne $Record.headOid)){return $false}
  $c=$Record.requiredCheckAuthority
  if(-not (Test-HoldKeys $c @('schema','protectionObserved','requiresStatusChecks','requiredNames','exactHead','totalCount','returnedCount','complete','reductions')) -or
    $c.schema -cne 'velocity-required-check-authority/v1' -or $c.complete -isnot [bool] -or $c.protectionObserved -isnot [bool] -or
    $c.requiresStatusChecks -isnot [bool] -or $c.requiredNames -isnot [array] -or $c.reductions -isnot [array] -or
    $c.exactHead -cne $Record.headOid -or -not (Test-HoldInteger $c.totalCount 0) -or -not (Test-HoldInteger $c.returnedCount 0) -or
    ($c.complete -and $c.totalCount -ne $c.returnedCount) -or @($c.requiredNames|Sort-Object -Unique).Count -ne $c.requiredNames.Count -or
    $c.reductions.Count -ne $c.requiredNames.Count){return $false}
  $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach($name in $c.requiredNames){if($name -isnot [string] -or [string]::IsNullOrWhiteSpace($name)){return $false}}
  foreach($reduction in $c.reductions){
    if(-not (Test-HoldKeys $reduction @('schemaVersion','requiredName','status','reason','matchCount','selected','superseded')) -or
      $reduction.schemaVersion -cne 'required-check-reducer/v1' -or $reduction.requiredName -cnotin $c.requiredNames -or -not $names.Add($reduction.requiredName) -or
      $reduction.status -cnotin @('eligible','refused','unknown') -or $reduction.reason -isnot [string] -or -not $reduction.reason -or
      -not (Test-HoldInteger $reduction.matchCount 0) -or $reduction.superseded -isnot [array]){return $false}
    if($null -ne $reduction.selected -and -not (Test-VelocityCheckProvenance $reduction.selected)){return $false}
    foreach($p in $reduction.superseded){if(-not (Test-VelocityCheckProvenance $p)){return $false}}
    if($null -ne $reduction.selected -and (1+$reduction.superseded.Count) -ne $reduction.matchCount){return $false}
    if($null -ne $reduction.selected){
      $selected=$reduction.selected
      $ids=[Collections.Generic.HashSet[long]]::new()
      if($selected.nodeType -ceq 'StatusContext' -and $reduction.superseded.Count -ne 0){return $false}
      if($selected.nodeType -ceq 'CheckRun'){
        [void]$ids.Add($selected.databaseId)
        foreach($old in $reduction.superseded){
          if($old.nodeType -cne 'CheckRun' -or -not $ids.Add($old.databaseId) -or $old.status -cne 'COMPLETED' -or
            $old.producer.appDatabaseId -ne $selected.producer.appDatabaseId -or $old.producer.workflowDatabaseId -ne $selected.producer.workflowDatabaseId -or
            (ConvertTo-HoldUtc $old.completedAt) -gt (ConvertTo-HoldUtc $selected.completedAt)){return $false}
          if($old.conclusion -cne 'SUCCESS' -or $selected.conclusion -cne 'SUCCESS'){
            if((ConvertTo-HoldUtc $old.completedAt) -ge (ConvertTo-HoldUtc $selected.completedAt) -or $old.databaseId -ge $selected.databaseId){return $false}
          }
        }
      }
    }
    if($reduction.status -ceq 'eligible'){
      if($null -eq $reduction.selected -or ($reduction.selected.nodeType -ceq 'CheckRun' -and
          ($reduction.selected.status -cne 'COMPLETED' -or $reduction.selected.conclusion -cnotin @('SUCCESS','NEUTRAL','SKIPPED'))) -or
        ($reduction.selected.nodeType -ceq 'StatusContext' -and $reduction.selected.status -cne 'SUCCESS')){return $false}
    }
  }
  $n=$Record.nonHoldPrerequisites
  if(-not (Test-HoldKeys $n @('schema','complete','status','reason','blocker','deploy','breaker','base','changeScope')) -or
    $n.schema -cne 'velocity-non-hold-prerequisites/v1' -or $n.complete -isnot [bool] -or $n.status -cnotin @('eligible','refused','unknown') -or
    $n.reason -isnot [string] -or -not $n.reason -or
    -not (Test-HoldKeys $n.blocker @('complete','openCount')) -or $n.blocker.complete -isnot [bool] -or -not (Test-HoldInteger $n.blocker.openCount 0) -or
    -not (Test-HoldKeys $n.deploy @('complete','status','conclusion')) -or $n.deploy.complete -isnot [bool] -or
    ($null -ne $n.deploy.status -and $n.deploy.status -cnotin @('completed','queued','in_progress','waiting','pending','requested')) -or
    ($null -ne $n.deploy.conclusion -and $n.deploy.conclusion -cnotin @('success','failure','cancelled','skipped','neutral','timed_out','action_required','stale','startup_failure')) -or
    -not (Test-HoldKeys $n.breaker @('complete','healthy')) -or $n.breaker.complete -isnot [bool] -or $n.breaker.healthy -isnot [bool] -or
    -not (Test-HoldKeys $n.base @('name','headOid')) -or $n.base.name -isnot [string] -or
    ($null -ne $n.base.headOid -and $n.base.headOid -cnotmatch '^[a-f0-9]{40}$') -or
    -not (Test-HoldKeys $n.changeScope @('proven','classification','head')) -or $n.changeScope.proven -isnot [bool] -or
    $n.changeScope.classification -cnotin @('deployable','non-deployable') -or $n.changeScope.head -cne $Record.headOid){return $false}
  if($n.status -ceq 'eligible' -and (-not $n.complete -or $r.state -cne 'authorized' -or -not $c.complete -or
      -not $c.protectionObserved -or -not $c.requiresStatusChecks -or $c.requiredNames.Count -eq 0 -or
      @($c.reductions|Where-Object status -CNE 'eligible').Count -or -not $n.blocker.complete -or $n.blocker.openCount -ne 0 -or
      -not $n.deploy.complete -or $n.deploy.status -cne 'completed' -or $n.deploy.conclusion -cne 'success' -or -not $n.breaker.complete)){return $false}
  return $true
  } catch { return $false }
}

function ConvertTo-VelocityLandingRecord($Record) {
  # A new outcome cannot authorize this PR or discard its siblings. Validate
  # every other nested field before reducing only that outcome to UNKNOWN.
  try {
    $latest=$Record.reviewReduction.latest
    if($null -ne $latest -and $latest.outcome -is [string] -and $latest.outcome -and
        $latest.outcome -cnotin @('PASS','BLOCK_FIXABLE','BLOCK_REPLAN','SKIP')){
      $copy=$Record|ConvertTo-Json -Depth 64|ConvertFrom-Json -DateKind String
      $copy.reviewReduction.latest.outcome='PASS'
      if(-not (Test-VelocityLandingRecord $copy)){return $Record}
      $copy.reviewReduction.state='unknown';$copy.reviewReduction.reason='REVIEW_OUTCOME_UNKNOWN';$copy.reviewReduction.latest=$null
      $copy.nonHoldPrerequisites.complete=$false;$copy.nonHoldPrerequisites.status='unknown';$copy.nonHoldPrerequisites.reason='REVIEW_OUTCOME_UNKNOWN'
      return $copy
    }
  } catch {}
  return $Record
}

function Write-VelocityLandingCapture([string]$Path,[string]$CycleId,[datetime]$StartedAt,[object[]]$Reports,[datetime]$CompletedAt=[datetime]::UtcNow) {
  $capture=[pscustomobject]@{schema='velocity-landing-capture/v1';cycleId=$CycleId;startedAt=$StartedAt.ToUniversalTime().ToString('o');completedAt=$CompletedAt.ToUniversalTime().ToString('o');complete=$true;records=@($Reports|ForEach-Object{ConvertTo-VelocityLandingRecord $_.velocityLanding})}
  if(-not (Test-VelocityLandingCapture $capture $CycleId $CompletedAt)){throw 'VELOCITY_CAPTURE_INVALID'}
  Invoke-WithHoldFileLock $Path {Write-HoldAtomicJson $Path $capture}
  return $capture
}

function Test-VelocityLandingCapture($Capture,[string]$CycleId,[datetime]$Now) {
  try {
  if(-not (Test-HoldKeys $Capture @('schema','cycleId','startedAt','completedAt','complete','records')) -or
    $Capture.schema -cne 'velocity-landing-capture/v1' -or -not (Test-HoldIdentity $Capture.cycleId) -or $Capture.cycleId -cne $CycleId -or
    $Capture.complete -isnot [bool] -or -not $Capture.complete -or $Capture.records -isnot [array] -or
    -not (Test-HoldInstant $Capture.startedAt) -or -not (Test-HoldInstant $Capture.completedAt) -or
    (ConvertTo-HoldUtc $Capture.startedAt) -gt (ConvertTo-HoldUtc $Capture.completedAt) -or (ConvertTo-HoldUtc $Capture.completedAt) -gt $Now.ToUniversalTime() -or
    ($Now.ToUniversalTime()-(ConvertTo-HoldUtc $Capture.startedAt)).TotalMinutes -gt 5){return $false}
  $keys=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach($record in $Capture.records){
    $r=ConvertTo-VelocityLandingRecord $record
    if(-not (Test-VelocityLandingRecord $r) -or -not $keys.Add("$($r.repository)/$($r.pr)") -or
      (ConvertTo-HoldUtc $r.observedAt) -lt (ConvertTo-HoldUtc $Capture.startedAt) -or (ConvertTo-HoldUtc $r.observedAt) -gt (ConvertTo-HoldUtc $Capture.completedAt)){return $false}
  }
  return $true
  } catch { return $false }
}

function Read-VelocityLandingCapture([string]$Path,[string]$CycleId,[datetime]$Now) {
  try{$c=ConvertFrom-HoldJson ([IO.File]::ReadAllText($Path));if(Test-VelocityLandingCapture $c $CycleId $Now){return $c}}catch{}
  return $null
}

function Get-VelocityLaneHours($Facts, [datetime]$Now, [hashtable]$LaneMap, [string[]]$ActiveLanes) {
  $dispatch = Get-VelocityDispatchRows @($Facts.dispatchRows)
  if ($dispatch.gaps.Count) {
    return [pscustomobject]@{productHours=$null;otherHours=$null;productShare=$null;unattributedOpenLanes=$null;gaps=$dispatch.gaps}
  }
  $controllerIssues = @(Get-VelocityControllerIssues $dispatch.rows $Now)
  $windowStart = $Now.AddHours(-48)
  $rows = @($dispatch.rows | Sort-Object -Stable { Get-ObservedLaneTime $_ })
  $boundEnds = @{}
  foreach ($row in $rows) {
    if ([string](Get-VelocityValue $row 'observationSchema') -ceq 'lane-time-harvest/v1') {
      $boundEnds[$row.dispatchTarget.rawSha256] = $row
    }
  }
  $totals = [ordered]@{ product = 0.0; other = 0.0; unattributedOpenLanes = 0 }
  $nextByLane = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
  for ($i = $rows.Count - 1; $i -ge 0; $i--) {
    $row = $rows[$i]
    if (Get-VelocityValue $row 'dispatchRoutingSchema') { continue }
    if ([string](Get-VelocityValue $row 'observationSchema') -ceq 'lane-time-harvest/v1') { continue }
    if ($null -eq $row.PSObject.Properties["lane"] -or [string]::IsNullOrWhiteSpace([string]$row.lane)) { continue }
    $lane = [string]$row.lane
    $next = $null
    [void]$nextByLane.TryGetValue($lane,[ref]$next)
    $identity = [string](Get-VelocityValue $row 'laneTimeRawSha256')
    if ($boundEnds.ContainsKey($identity)) { $next=$boundEnds[$identity] }
    if ([string]$row.kind -ceq 'dispatch' -or $script:TerminalKinds -ccontains [string]$row.kind) { $nextByLane[$lane] = $row }
    if ([string]$row.kind -cne 'dispatch' -or $null -eq (Get-VelocityValue $row 'issue')) { continue }
    $start = Get-ObservedLaneTime $row
    if ($null -eq $next) {
      if ($ActiveLanes -cnotcontains $lane -and $start -ge $Now.AddDays(-7) -and $start -le $Now) { $totals.unattributedOpenLanes += 1 }
      continue
    }
    if ([string]$next.kind -cne 'lane-complete') { continue }
    $end = Get-ObservedLaneTime $next
    $clipStart = if ($start -lt $windowStart) { $windowStart } else { $start }
    if ($end -le $clipStart) { continue }
    $hours = ($end - $clipStart).TotalHours
    if (Test-VelocityProductIssue (Get-VelocityIssue $Facts ([int]$row.issue)) @($Facts.platformMilestones) $controllerIssues) { $totals.product += $hours } else { $totals.other += $hours }
  }
  $sum = $totals.product + $totals.other
  return [pscustomobject][ordered]@{
    productHours = [math]::Round($totals.product, 2)
    otherHours = [math]::Round($totals.other, 2)
    productShare = $(if ($sum -gt 0) { [math]::Round($totals.product / $sum, 3) } else { $null })
    unattributedOpenLanes = $totals.unattributedOpenLanes
  }
}

function Get-VelocityActionTime($Facts, [string]$AlarmId, [datetime]$Since) {
  $token = "velocity:$AlarmId"
  $hits = @($Facts.dispatchRows | Where-Object {
      $ts = Get-ObservedLaneTime $_
      $note = if ($null -ne $_.PSObject.Properties["note"]) { [string]$_.note } else { "" }
      $ts -ge $Since -and $note.Contains($token, [StringComparison]::Ordinal)
    } | Sort-Object { Get-ObservedLaneTime $_ })
  if ($hits.Count -eq 0) { return $null }
  return Get-ObservedLaneTime $hits[-1]
}

function Get-VelocityReport($Facts, [datetime]$Now, [object[]]$Observations) {
  $now = $Now.ToUniversalTime()
  $dispatch=Get-VelocityDispatchRows @($Facts.dispatchRows)
  $Facts=$Facts.PSObject.Copy()
  $Facts.dispatchRows=$dispatch.rows
  $complete = [bool]$Facts.complete
  $gaps = @($Facts.gaps)+@($dispatch.gaps)
  if($dispatch.gaps.Count){$complete=$false}
  $holdState=Get-VelocityValue $Facts 'holdState'
  $holdKnown=Test-MergeHoldState $holdState $now
  if(-not $holdKnown){$complete=$false;$gaps+=@('merge-hold-state-unverified')}
  $activeHolds=@(if($holdKnown){$holdState.records|Where-Object{$null -eq $_.releasedAt -and $now -lt (ConvertTo-HoldUtc $_.expiresAt)}})
  $capture=Get-VelocityValue $Facts 'landingCapture'
  $captureKnown=Test-VelocityLandingCapture $capture ([string](Get-VelocityValue $Facts 'cycleId' '')) $now
  if(-not $captureKnown){$complete=$false;$gaps+=@('landing-capture-unverified')}
  $platform = @($Facts.platformMilestones | ForEach-Object { [int]$_ })
  $controllerIssues = @(Get-VelocityControllerIssues $Facts.dispatchRows $now)
  $openProductIssues = @($Facts.productIssues | Where-Object { Test-VelocityProductIssue $_ $platform $controllerIssues } | ForEach-Object { [int]$_.number })

  $productMerges = @(Get-VelocityProductMerges $Facts $now $controllerIssues)
  $lastMerge = if ($productMerges.Count) { ConvertTo-VelocityUtc $productMerges[-1].mergedAt } else { $null }
  $hoursSince = if ($null -ne $lastMerge) { [math]::Round(($now - $lastMerge).TotalHours, 1) } else { $null }

  $weekStart = $now.AddDays(-7)
  $recent = @($Facts.merges | Where-Object { (ConvertTo-VelocityUtc $_.mergedAt) -ge $weekStart })
  $unlinked = @($recent | Where-Object { @($_.issues | Where-Object { @($_.kinds).Count -gt 0 }).Count -eq 0 })
  $productRecent = @($productMerges | Where-Object { (ConvertTo-VelocityUtc $_.mergedAt) -ge $weekStart })
  # Kind labels do not define product work. No milestone-move diagnostic existed;
  # retain the v1 key, but retire the late kind-relabel diagnostic.
  $lateRelabels = @()

  $activeLanes = @($Facts.activeLanes | ForEach-Object { [string]$_.lane })
  $landingRowsByPr=@{}
  foreach($row in $Facts.dispatchRows){
    if($row.kind -cnotin @('enqueue','landed','deploy-verified','dequeue')){continue}
    $prNumber=Get-VelocityValue $row 'pr'
    if(-not (Test-HoldInteger $prNumber)){continue}
    $key=[string]$prNumber
    if(-not $landingRowsByPr.ContainsKey($key)){$landingRowsByPr[$key]=[Collections.Generic.List[object]]::new()}
    $landingRowsByPr[$key].Add($row)
  }
  $laneMap = Get-VelocityLaneIssueMap @($Facts.dispatchRows) @($Facts.productIssues|ForEach-Object{[int]$_.number})
  $flowing = [Collections.Generic.SortedSet[int]]::new()
  $unresolvedLanes=@()
  $terminalParked=@($Facts.productIssues|Where-Object{[string](Get-VelocityValue $_ 'terminalState' 'none') -cnotin @('none','reentered')}|ForEach-Object{[pscustomobject]@{issue=[int]$_.number;state=[string]$_.terminalState}})
  $terminalIssues=@($terminalParked|ForEach-Object{[int]$_.issue})
  $held=@();$heldIssues=[Collections.Generic.HashSet[int]]::new()
  $staleAttempts = @()
  foreach ($active in @($Facts.activeLanes)) {
    $key=[string](Get-VelocityValue $active 'label' ([string]$active.lane))
    $entry = $laneMap[$key]
    if($null -ne $entry -and $null -ne $active.PSObject.Properties['launchHead']){
      $route=$entry.route
      if($null -eq $route -or [string](Get-VelocityValue $route 'head') -cne [string]$active.launchHead -or
        [string](Get-VelocityValue $route 'worktree') -ine [string]$active.worktree -or
        (Get-ObservedLaneTime $route) -lt (ConvertTo-VelocityUtc $active.startedAt)){$entry=$null}
      if($null -ne $entry -and $active.laneRole -cin @('review','repair')){
        $linked=@($Facts.productPrs|Where-Object{@($_.issues) -contains $entry.issue})
        if($linked.Count -gt 0 -and @($linked|Where-Object{[string](Get-VelocityValue $_ 'headOid') -ceq $active.launchHead}).Count -eq 0){$entry=$null}
      }
    }
    if ($null -eq $entry) {
      $started=ConvertTo-VelocityUtc (Get-VelocityValue $active 'startedAt')
      $age=if($null -ne $started){($now-$started).TotalMinutes}else{$null}
      $unresolvedLanes+=@([pscustomobject]@{lane=[string]$active.lane;label=$key;minutes=$age;reason='launch-issue-unresolved'})
      $complete=$false
      $gaps+=@(if($null -eq $age -or $age -gt 10){"launch-issue-unresolved:$key"}else{"launch-issue-resolution-pending:$key"})
      continue
    }
    if ($openProductIssues -notcontains $entry.issue) { continue }
    if($terminalIssues -contains $entry.issue){continue}
    [void]$flowing.Add($entry.issue)
    if ([string]$active.laneRole -ceq "implementation") {
      $lastProgress = $entry.startedAt
      foreach ($pr in @($Facts.productPrs | Where-Object { @($_.issues) -contains $entry.issue })) {
        $pushed = ConvertTo-VelocityUtc $pr.headCommittedAt
        if ($null -ne $pushed -and $pushed -gt $lastProgress) { $lastProgress = $pushed }
      }
      $idle = ($now - $lastProgress).TotalHours
      if ($idle -ge $script:StaleAttemptHours) {
        $staleAttempts += [pscustomobject][ordered]@{ issue = $entry.issue; lane = [string]$active.lane; hoursWithoutPush = [math]::Round($idle, 1) }
      }
    }
  }
  $holdAmbiguousPrs = [Collections.Generic.HashSet[string]]::new()
  foreach ($pr in @($Facts.productPrs)) {
    if (@($pr.issues | Where-Object { $openProductIssues -contains [int]$_ }).Count -eq 0) { continue }
    $landing=$null
    if($captureKnown){$landing=@($capture.records|Where-Object{$_.pr -eq $pr.pr -and $_.repository -ceq [string](Get-VelocityValue $pr 'repository')}|ForEach-Object{ConvertTo-VelocityLandingRecord $_})|Select-Object -First 1}
    $captureValid=$captureKnown -and $null -ne $landing -and (Test-VelocityLandingRecord $landing) -and
      $landing.reviewReduction.reason -cne 'REVIEW_OUTCOME_UNKNOWN' -and
      $landing.pr -eq $pr.pr -and $landing.repository -ceq [string](Get-VelocityValue $pr 'repository') -and
      $landing.headOid -ceq [string](Get-VelocityValue $pr 'headOid') -and (ConvertTo-HoldUtc $landing.observedAt) -le $now -and
      ($now-(ConvertTo-HoldUtc $landing.observedAt)).TotalMinutes -le 5 -and
      (($pr.inMergeQueue -and $landing.queueEntryId -ceq [string](Get-VelocityValue $pr 'queueEntryId')) -or (-not $pr.inMergeQueue -and $null -eq $landing.queueEntryId))
    if(-not $captureValid -or -not $landing.requiredCheckAuthority.complete -or -not $landing.nonHoldPrerequisites.complete){
      $complete=$false;$gaps+=@("landing-capture-unknown:$($pr.pr)")
    }
    $applicable=@($activeHolds|Where-Object{$_.scope -ceq 'queue' -or $_.prs -contains [int]$pr.pr})
    if($captureValid -and $applicable.Count -gt 0){[void]$holdAmbiguousPrs.Add([string]$pr.pr)}
    $readyLinked=@($Facts.productIssues|Where-Object{@($pr.issues) -contains [int]$_.number -and $terminalIssues -notcontains [int]$_.number -and (Test-VelocityReadyIssue $_ $platform $controllerIssues)})
    $isHeld=$holdKnown -and $captureValid -and $landing.nonHoldPrerequisites.complete -and $landing.nonHoldPrerequisites.status -ceq 'eligible' -and
      $landing.reviewReduction.state -ceq 'authorized' -and -not $pr.isDraft -and $readyLinked.Count -gt 0 -and $applicable.Count -gt 0
    if($isHeld){
      if(@($held|Where-Object pr -EQ $pr.pr).Count -eq 0){$held+=@([pscustomobject]@{pr=[int]$pr.pr;headOid=$landing.headOid;holdIds=@($applicable.holdId|Sort-Object -Unique);issues=@($readyLinked.number|Sort-Object -Unique)})}
      foreach($issue in $readyLinked){[void]$heldIssues.Add([int]$issue.number)}
    }
    $greenWait=$captureValid -and -not $isHeld -and $holdKnown -and $pr.ciState -ceq 'SUCCESS' -and -not $pr.inMergeQueue -and -not $pr.isDraft -and
      @($landingRowsByPr[[string]$pr.pr]|Where-Object{
        if($null -eq $_){return $false}
        $at=ConvertTo-VelocityUtc $_.ts
        $rowHead=Get-VelocityValue $_ 'head'
        $dequeued=@($landingRowsByPr[[string]$pr.pr]|Where-Object{
          $_.kind -ceq 'dequeue' -and [string](Get-VelocityValue $_ 'repository' $pr.repository) -ceq $pr.repository -and
            (ConvertTo-VelocityUtc $_.ts) -ge $at -and (ConvertTo-VelocityUtc $_.ts) -le $now
        }).Count -gt 0
        $_.kind -cin @('enqueue','landed') -and (Get-VelocityValue $_ 'pr') -eq $pr.pr -and
          -not $dequeued -and
          ($null -eq $rowHead -or [string]$rowHead -ceq [string]$pr.headOid) -and $at -le $now -and
          $at -ge (ConvertTo-VelocityUtc $pr.headCommittedAt) -and
          [string](Get-VelocityValue $_ 'repository' $pr.repository) -ceq $pr.repository
      }).Count -gt 0
    if (([bool]$pr.inMergeQueue -and -not $isHeld -and $holdKnown -and $captureValid) -or @("PENDING", "EXPECTED") -contains [string]$pr.ciState -or $greenWait) {
      foreach ($issue in @($pr.issues)) { if($openProductIssues -contains [int]$issue -and $terminalIssues -notcontains [int]$issue){[void]$flowing.Add([int]$issue)} }
    }
  }
  # Landed rows establish pending deploy, never deployment success. A verified
  # deploy or the 24-hour bound returns the issue to ordinary classification.
  $landingIssues=[Collections.Generic.SortedSet[int]]::new()
  foreach($merge in @($Facts.merges)){
    $mergedAt=ConvertTo-VelocityUtc $merge.mergedAt
    if($null -eq $mergedAt -or $mergedAt -gt $now -or ($now-$mergedAt).TotalHours -ge 24){continue}
    $mergeRows=@($landingRowsByPr[[string]$merge.pr]|Where-Object{$null -ne $_})
    $landed=@($mergeRows|Where-Object{$_.kind -ceq 'landed' -and (ConvertTo-VelocityUtc $_.ts) -le $now}|Sort-Object {ConvertTo-VelocityUtc $_.ts}|Select-Object -Last 1)
    if($landed.Count -eq 0){continue}
    $verified=@($mergeRows|Where-Object{$_.kind -ceq 'deploy-verified' -and (ConvertTo-VelocityUtc $_.ts) -ge $mergedAt -and (ConvertTo-VelocityUtc $_.ts) -le $now})
    if($verified.Count -gt 0){continue}
    foreach($issue in @($merge.issues)){
      $number=[int]$issue.number
      if($openProductIssues -contains $number -and $terminalIssues -notcontains $number){
        [void]$landingIssues.Add($number);[void]$flowing.Add($number)
      }
    }
  }
  $ready = @($Facts.productIssues | Where-Object { $terminalIssues -notcontains [int]$_.number -and (Test-VelocityReadyIssue $_ $platform $controllerIssues) } | ForEach-Object { [int]$_.number } | Sort-Object)
  $readyIdle = @(if($unresolvedLanes.Count -eq 0){$ready | Where-Object { -not $flowing.Contains($_) -and -not $heldIssues.Contains($_) }})

  $floorProofIssues = [Collections.Generic.SortedSet[int]]::new($flowing)
  $floorGapsKnown = $true
  if (-not $complete) {
    foreach ($gap in $gaps) {
      if ($gap -cin @('landing-capture-unverified','merge-hold-state-unverified') -or
        ($gap -cmatch '\Alanding-capture-unknown:([1-9][0-9]*)\z' -and -not $holdAmbiguousPrs.Contains($Matches[1])) -or
        $gap -cmatch '\Alaunch-issue-(?:unresolved|resolution-pending):[^\r\n]+\z') { continue }
      # Only these issue-keyed label projections are isolated from other
      # issues' flow. Open-issue connections also affect PR-wide hold state.
      $issueNumber = 0
      if ($gap -cmatch '\A(?:merged-issue-labels-incomplete|issue-details-labels-incomplete):([1-9][0-9]*)\z' -and
        [int]::TryParse($Matches[1], [ref]$issueNumber)) {
        [void]$floorProofIssues.Remove($issueNumber)
      } else {
        $floorGapsKnown = $false
        $floorProofIssues.Clear()
        break
      }
    }
  }
  $floorState = if (-not $floorGapsKnown) { "UNKNOWN" }
    elseif ($floorProofIssues.Count -ge $script:FloorLanes) { "MET" }
    elseif (-not $complete) { "UNKNOWN" }
    elseif ($readyIdle.Count -ge 1 -or $held.Count -gt 0) { "UNMET" }
    else { "MET" }

  $dayStart = $now.AddHours(-24)
  $decisionHeavy = @($Facts.dispatchRows | Where-Object {
      [string]$_.kind -ceq "decision-filed" -and $null -ne $_.PSObject.Properties["issue"] -and $null -ne $_.issue -and (ConvertTo-VelocityUtc $_.ts) -ge $dayStart
    } | Group-Object { [int]$_.issue } | Where-Object { $_.Count -ge $script:DecisionHeavyCount } |
    ForEach-Object { [pscustomobject][ordered]@{ issue = [int]$_.Name; decisionLanes24h = $_.Count } })

  $alarms = @()
  if ($complete) {
    $series = @(@($Observations) + @([pscustomobject]@{ ts = (Format-VelocityUtc $now); floorState = $floorState }) |
      Where-Object { $null -ne $_ } | Sort-Object { ConvertTo-VelocityUtc $_.ts })
    $run = @()
    for ($k = $series.Count - 1; $k -ge 0; $k--) {
      if ([string]$series[$k].floorState -cne "UNMET") { break }
      $run += $series[$k]
    }
    if ($run.Count -ge 2) {
      $onset = ConvertTo-VelocityUtc $run[-1].ts
      if (($now - $onset).TotalMinutes -ge $script:FloorRunMinutes) {
        $raisedAt = $onset.AddMinutes($script:FloorRunMinutes)
        $since = if ($now.AddHours(-$script:FloorRearmHours) -gt $onset) { $now.AddHours(-$script:FloorRearmHours) } else { $onset }
        $acted = Get-VelocityActionTime $Facts "FLOOR" $since
        $alarms += [pscustomobject][ordered]@{
          id = "FLOOR"; onset = (Format-VelocityUtc $onset); raisedAt = (Format-VelocityUtc $raisedAt)
          actedAt = $(if ($null -ne $acted) { Format-VelocityUtc $acted } else { $null })
          unacted = ($null -eq $acted -and ($now - $raisedAt).TotalHours -ge $script:FloorGraceHours)
          detail = "flowing product issues $($flowing.Count) < $($script:FloorLanes); ready idle: $($readyIdle -join ','); held PRs: $(@($held|ForEach-Object pr) -join ','); holds: $(@($held|ForEach-Object holdIds|Sort-Object -Unique) -join ','); host action: dispatch/backfill idle work or unblock the named hold through section 8"
        }
      }
    }
    $droughtHours = if ($null -ne $hoursSince) { $hoursSince } else { [double]::PositiveInfinity }
    if ($droughtHours -ge $script:DroughtHours) {
      $periodStart = if ($null -ne $lastMerge) {
        $periods = [math]::Floor(($droughtHours - $script:DroughtHours) / $script:DroughtHours)
        $lastMerge.AddHours($script:DroughtHours * (1 + $periods))
      } else { $now.AddHours(-$script:DroughtHours) }
      $acted = Get-VelocityActionTime $Facts "DROUGHT" $periodStart
      $alarms += [pscustomobject][ordered]@{
        id = "DROUGHT"; onset = $(if ($null -ne $lastMerge) { Format-VelocityUtc ($lastMerge.AddHours($script:DroughtHours)) } else { $null })
        raisedAt = (Format-VelocityUtc $periodStart)
        actedAt = $(if ($null -ne $acted) { Format-VelocityUtc $acted } else { $null })
        unacted = ($null -eq $acted -and ($now - $periodStart).TotalHours -ge $script:DroughtGraceHours)
        detail = "no kind:product merge for $(if ($null -ne $hoursSince) { "$hoursSince h (last $(Format-VelocityUtc $lastMerge))" } else { 'the whole lookback' })"
      }
    }
  }

  $status = if (-not $complete) { "UNKNOWN" } elseif ($alarms.Count -gt 0) { "ALARM" } else { "OK" }
  $laneHours = Get-VelocityLaneHours $Facts $now $laneMap $activeLanes
  if ($dispatch.gaps.Count) {
    $laneHours = [pscustomobject]@{productHours=$null;otherHours=$null;productShare=$null;unattributedOpenLanes=$null;gaps=$dispatch.gaps}
  }
  return [pscustomobject][ordered]@{
    schema = "velocity-report/v1"
    productDefinitionVersion = $script:VelocityPolicy.ProductDefinitionVersion
    now = (Format-VelocityUtc $now)
    status = $status
    factsComplete = $complete
    gaps = @($gaps|Sort-Object -Unique)
    metrics = [pscustomobject][ordered]@{
      lastProductMergeAt = $(if ($null -ne $lastMerge) { Format-VelocityUtc $lastMerge } else { $null })
      hoursSinceProductMerge = $hoursSince
      merges7d = $recent.Count
      productMerges7d = $productRecent.Count
      unlinkedMerges7d = $unlinked.Count
      unlinkedRatio7d = $(if ($recent.Count -gt 0) { [math]::Round($unlinked.Count / $recent.Count, 3) } else { $null })
      flowingProductIssues = @($flowing)
      floorProofIssues = @($floorProofIssues)
      landingProductIssues = @($landingIssues)
      readyProductIssues = $ready
      readyNotInFlight = $readyIdle
      heldProductPrs = $held
      heldCount = $held.Count
      floorState = $floorState
      ownershipStatus = [string]$Facts.ownershipStatus
    }
    alarms = $alarms
    diagnostics = [pscustomobject][ordered]@{
      legacyDispatchRows = @(@(Get-VelocityValue $Facts 'legacyDispatchRows' @())+@($dispatch.legacyDispatchRows)|Sort-Object -Unique)
      nonPositiveIssueDispatchRows = @(@(Get-VelocityValue $Facts 'nonPositiveIssueDispatchRows' @())+@($dispatch.nonPositiveIssueDispatchRows)|Sort-Object -Unique)
      staleAttempts = $staleAttempts
      terminalParkedIssues = $terminalParked
      unresolvedLanes = $unresolvedLanes
      decisionHeavyIssues = $decisionHeavy
      laneHours48h = $laneHours
      lateProductRelabels = $lateRelabels
    }
  }
}

function Read-VelocityObservations([string]$Path, [datetime]$Now) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
  $cutoff = $Now.AddHours(-48)
  return @(Get-Content -LiteralPath $Path -ErrorAction Stop | ForEach-Object {
      try { $_ | ConvertFrom-Json } catch { $null }
    } | Where-Object { $null -ne $_ -and $null -ne $_.PSObject.Properties["ts"] -and (ConvertTo-VelocityUtc $_.ts) -ge $cutoff })
}

function Invoke-VelocityGraphQL([string]$Query, [hashtable]$Variables) {
  $arguments = @("api", "graphql", "-f", "query=$Query")
  foreach ($key in $Variables.Keys) {
    if ($null -ne $Variables[$key]) { $arguments += @("-f", "$key=$($Variables[$key])") }
  }
  $raw = & gh @arguments 2>&1
  if ($LASTEXITCODE -ne 0) { throw "gh graphql failed: $(($raw | Out-String).Trim())" }
  $parsed = ($raw | Out-String) | ConvertFrom-Json
  if ($null -ne $parsed.PSObject.Properties["errors"] -and $null -ne $parsed.errors) { throw "gh graphql returned errors" }
  return $parsed.data
}

function Invoke-VelocitySearch([string]$SearchQuery, [string]$Fields) {
  $query = 'query($q:String!,$c:String){search(query:$q,type:ISSUE,first:100,after:$c){issueCount pageInfo{hasNextPage endCursor} nodes{' + $Fields + '}}}'
  $nodes = @()
  $cursor = $null
  do {
    $data = Invoke-VelocityGraphQL $query @{ q = $SearchQuery; c = $cursor }
    $nodes += @($data.search.nodes)
    $cursor = $data.search.pageInfo.endCursor
  } while ([bool]$data.search.pageInfo.hasNextPage)
  if ($nodes.Count -ne [int]$data.search.issueCount) {
    throw "search '$SearchQuery' returned $($nodes.Count) of $($data.search.issueCount)"
  }
  return $nodes
}

function Invoke-VelocityOpenIssues {
  # Repository connections have no search API's 1,000-result ceiling.
  $query = 'query($c:String){repository(owner:"chase-sets",name:"chase-sets"){issues(states:OPEN,first:100,after:$c){totalCount pageInfo{hasNextPage endCursor} nodes{number title body labels(first:30){totalCount pageInfo{hasNextPage endCursor} nodes{name}} milestone{number state description} blockedBy(first:30){totalCount pageInfo{hasNextPage endCursor} nodes{id state}}}}}}'
  $nodes = @(); $cursor = $null; $expected = $null
  do {
    $data = Invoke-VelocityGraphQL $query @{c=$cursor}
    $connection = $data.repository.issues
    if ($null -eq $expected) { $expected = [int]$connection.totalCount }
    if ([int]$connection.totalCount -ne $expected) { throw 'open issue census changed during pagination' }
    $nodes += @($connection.nodes)
    $next = $connection.pageInfo.endCursor
    if ($connection.pageInfo.hasNextPage -and ([string]::IsNullOrWhiteSpace($next) -or $next -ceq $cursor)) { throw 'open issue cursor did not advance' }
    $cursor = $next
  } while ([bool]$connection.pageInfo.hasNextPage)
  if ($nodes.Count -ne $expected -or @($nodes | ForEach-Object number | Sort-Object -Unique).Count -ne $expected) {
    throw "open issue census returned $($nodes.Count) of $expected or duplicate identities"
  }
  return $nodes
}

function Complete-VelocityIssueConnections($Issue, [string[]]$Connections = @('labels')) {
  # Bound each nested connection independently; a refusal remains a facts gap.
  $pageLimit = 100
  foreach ($name in $Connections) {
    if ($name -cnotin @('labels', 'blockedBy')) { throw "unsupported issue connection:$name" }
    $connection = $Issue.$name
    $expected = [int]$connection.totalCount
    $nodes = @($connection.nodes)
    $pageInfo = Get-VelocityValue $connection 'pageInfo'
    # Without pagination metadata the existing caller-specific count checks
    # retain their named incomplete-connection refusals.
    if ($null -eq $pageInfo) { continue }
    if ($nodes.Count -eq $expected -and -not (Get-VelocityValue $pageInfo 'hasNextPage' $false)) { continue }
    $identity = if ($name -ceq 'labels') { 'name' } else { 'id' }
    $fields = if ($name -ceq 'labels') { 'name' } else { 'id state' }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $cursors = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($node in $nodes) {
      $key = [string](Get-VelocityValue $node $identity)
      if (-not $key -or -not $seen.Add($key)) { throw "issue-connection-identity-invalid:$($Issue.number):$name" }
    }
    $query = 'query($c:String){repository(owner:"chase-sets",name:"chase-sets"){issue(number:' + [int]$Issue.number + '){number ' + $name + '(first:30,after:$c){totalCount pageInfo{hasNextPage endCursor} nodes{' + $fields + '}}}}}'
    $pages = 1
    while (Get-VelocityValue $pageInfo 'hasNextPage' $false) {
      if ($pages -ge $pageLimit) { throw "issue-connection-page-cap-exceeded:$($Issue.number):$name" }
      $cursor = [string](Get-VelocityValue $pageInfo 'endCursor')
      if ([string]::IsNullOrWhiteSpace($cursor) -or -not $cursors.Add($cursor)) { throw "issue-connection-cursor-invalid:$($Issue.number):$name" }
      $data = Invoke-VelocityGraphQL $query @{c=$cursor}
      $page = $data.repository.issue
      if ($null -eq $page -or $page.number -ne $Issue.number) { throw "issue-connection-unresolved:$($Issue.number):$name" }
      $next = $page.$name
      if ([int]$next.totalCount -ne $expected) { throw "issue-connection-census-changed:$($Issue.number):$name" }
      $pageInfo = $next.pageInfo
      if ($pageInfo.hasNextPage -isnot [bool]) { throw "issue-connection-page-info-invalid:$($Issue.number):$name" }
      foreach ($node in @($next.nodes)) {
        $key = [string](Get-VelocityValue $node $identity)
        if (-not $key -or -not $seen.Add($key)) { throw "issue-connection-identity-invalid:$($Issue.number):$name" }
        $nodes += $node
      }
      $pages++
    }
    if ($nodes.Count -ne $expected) { throw "issue-connection-incomplete:$($Issue.number):$name" }
    # Publish only a completely observed connection; retain the caller's checks.
    $Issue.$name = [pscustomobject]@{totalCount=$expected;nodes=$nodes;pageInfo=$pageInfo}
  }
}

function Get-VelocityOutcomeCommitted([string]$Description) {
  $outcome = Get-VelocityOutcome $Description
  return $null -ne $outcome -and [string](Get-VelocityValue $outcome 'status') -ceq 'committed'
}

function Get-VelocityOutcome([string]$Description) {
  if ([string]::IsNullOrEmpty($Description)) { return $null }
  $match = [regex]::Match($Description, '<!--\s*outcome:\s*(\{[^}]*\})\s*-->')
  if (-not $match.Success) { return $null }
  try { return ($match.Groups[1].Value | ConvertFrom-Json) } catch { return $null }
}

function ConvertTo-VelocityIssue($Issue) {
  $labels = @($Issue.labels.nodes | ForEach-Object { [string]$_.name })
  $milestone = Get-VelocityValue $Issue 'milestone'
  $outcome = if ($null -ne $milestone) { Get-VelocityOutcome ([string]$milestone.description) } else { $null }
  return [pscustomobject][ordered]@{
    number = [int]$Issue.number; title = [string]$Issue.title; labels = $labels
    milestone = $(if ($null -ne $milestone) {
      [pscustomobject]@{number=[int]$milestone.number;state=[string]$milestone.state;
        committed=([string](Get-VelocityValue $outcome 'status') -ceq 'committed');track=[string](Get-VelocityValue $outcome 'track')}
    } else { $null })
    terminalState = if ($labels -ccontains 'status:needs-replan' -or $labels -ccontains 'status:parked') { 'parked' }
      elseif ([string]$Issue.body -match '<!--\s*(?:terminal-park|parked)\b') { 'unknown' } else { 'none' }
  }
}

function Get-VelocityPrIssueReferences($Pr, [object[]]$Rows, [datetime]$Now, [string[]]$FallbackKinds = @('enqueue')) {
  $references=@($Pr.closingIssuesReferences.nodes | ForEach-Object { [int]$_.number })
  foreach($match in [regex]::Matches([string](Get-VelocityValue $Pr 'body'), '(?i)\b(?:refs|close[sd]?|fix(?:es|ed)?|resolve[sd]?)\s+#([1-9][0-9]*)\b')) {
    $number=0
    if([int]::TryParse($match.Groups[1].Value,[ref]$number)){$references+=@($number)}
  }
  # Lifecycle rows attribute only otherwise unreferenced PRs. They never
  # supply queue, deploy, review or landing authority.
  if($references.Count -eq 0) {
    $references=@($Rows | Where-Object {
      $at=ConvertTo-VelocityUtc (Get-VelocityValue $_ 'ts')
      [string](Get-VelocityValue $_ 'kind') -cin $FallbackKinds -and
        [string](Get-VelocityValue $_ 'pr') -ceq [string]$Pr.number -and $null -ne $at -and $at -le $Now -and
        [string](Get-VelocityValue $_ 'issue') -cmatch '^[1-9][0-9]*$' -and
        [string](Get-VelocityValue $_ 'repository' $Pr.repository.nameWithOwner) -ceq $Pr.repository.nameWithOwner
    } | ForEach-Object {
      $number=0
      if([int]::TryParse([string]$_.issue,[ref]$number)){$number}
    })
  }
  return @($references | Sort-Object -Unique)
}

function Get-VelocityFacts([string]$Container, [datetime]$Now, [string]$CycleId='', [string]$LandingCapturePath='') {
  $gaps = @()
  $facts = [ordered]@{
    schema = "velocity-facts/v1"; collectedAt = (Format-VelocityUtc $Now); complete = $false; gaps = @()
    platformMilestones = @(); merges = @(); lastProductMergeAt = $null; productIssues = @(); productPrs = @()
    activeLanes = @(); ownershipStatus = "unknown"; dispatchRows = @(); issueKinds = [ordered]@{}; issueDetails = [ordered]@{}; holdState=$null;cycleId=$CycleId;landingCapture=$null
  }
  $hold=Read-MergeHoldState (Join-Path $Container '.orchestrator/merge-hold-state.json') $Now
  if($hold.status -ceq 'KNOWN'){$facts.holdState=$hold.state}else{$gaps+=@('merge-hold-state-unverified')}
  if(-not $LandingCapturePath){$LandingCapturePath=Join-Path $Container '.orchestrator/logs/velocity-landing-capture.json'}
  $capture=Read-VelocityLandingCapture $LandingCapturePath $CycleId $Now
  $facts.landingCapture=$capture
  if($null -eq $capture){$gaps+=@('landing-capture-unverified')}

  $handoff = Join-Path $Container ".orchestrator/platform-handoff.md"
  try {
    $facts.platformMilestones = @(Get-Content -LiteralPath $handoff -ErrorAction Stop | ForEach-Object {
        $m = [regex]::Match($_, '^\|\s*chase-sets milestone (\d+)[^|]*\|\s*platform\s*\|')
        if ($m.Success) { [int]$m.Groups[1].Value }
      })
  } catch { $gaps += "platform-register-unreadable" }

  try {
    $issues = Invoke-VelocityOpenIssues
    foreach ($issue in $issues) { Complete-VelocityIssueConnections $issue @('labels', 'blockedBy') }
    $facts.productIssues = @($issues | ForEach-Object {
        $issue = ConvertTo-VelocityIssue $_
        $issue | Add-Member openBlockers @($_.blockedBy.nodes | Where-Object { [string]$_.state -ceq 'OPEN' }).Count
        $issue
      })
    foreach($issue in $issues){if($issue.labels.totalCount -ne @($issue.labels.nodes).Count -or $issue.blockedBy.totalCount -ne @($issue.blockedBy.nodes).Count){$gaps+=@("issue-connections-incomplete:$($issue.number)")}}
  } catch { $gaps += "product-issues: $($_.Exception.Message)" }

  $logPath = Join-Path $Container ".orchestrator/dispatch-log.jsonl"
  $authorityHistory=$null
  try {
    # Full history retains origins of still-live attempts beyond seven days.
    # The diagnostics retain their own unchanged 24/48-hour clipping windows.
    Import-Module (Join-Path $PSScriptRoot 'review-head-contract.psm1') -Force -DisableNameChecking
    $authorityHistory=Read-ExactHeadReviewHistory -Path $logPath
    if(-not $authorityHistory.complete){throw $authorityHistory.reason}
    $dispatch=Get-VelocityDispatchRows @($authorityHistory.rows) -HistoryRows
    $facts.dispatchRows=$dispatch.rows
    $facts.legacyDispatchRows=$dispatch.legacyDispatchRows
    $facts.nonPositiveIssueDispatchRows=$dispatch.nonPositiveIssueDispatchRows
    $gaps+=@($dispatch.gaps)
  } catch { $gaps += "dispatch-log: $($_.Exception.Message)" }
  $controllerIssues = @(Get-VelocityControllerIssues $facts.dispatchRows $Now)

  try {
    $issueFields = 'number title body labels(first:30){totalCount pageInfo{hasNextPage endCursor} nodes{name}} milestone{number state description}'
    $since = $Now.AddDays(-30).ToString("yyyy-MM-dd", [Globalization.CultureInfo]::InvariantCulture)
    $prs = @(Invoke-VelocitySearch "repo:$script:VelocityRepo is:pr is:merged merged:>=$since" ("... on PullRequest{number body repository{nameWithOwner} mergedAt closingIssuesReferences(first:5){totalCount nodes{" + $issueFields + "}}}"))
    $references=@{};$mergeIssues=@{}
    foreach($pr in $prs){
      if((Get-VelocityValue $pr 'body') -isnot [string]){$gaps+=@("merged-pr-body-incomplete:$($pr.number)")}
      if($pr.closingIssuesReferences.totalCount -ne @($pr.closingIssuesReferences.nodes).Count){$gaps+=@("merged-pr-connections-incomplete:$($pr.number)")}
      $mergedAt=ConvertTo-VelocityUtc $pr.mergedAt
      if($null -eq $mergedAt -or $mergedAt -gt $Now){throw "invalid merge time:$($pr.number)"}
      $references[[int]$pr.number]=@(Get-VelocityPrIssueReferences $pr $facts.dispatchRows $Now @('enqueue','landed'))
      foreach($issue in @($pr.closingIssuesReferences.nodes)){$mergeIssues[[int]$issue.number]=$issue}
    }
    # Body/lifecycle references can name closed issues, absent from the open
    # product census. Resolve their milestone and ownership inputs in bulk.
    $needed=@($references.Values | ForEach-Object { $_ } | Sort-Object -Unique | Where-Object { -not $mergeIssues.ContainsKey([int]$_) })
    for($offset=0;$offset -lt $needed.Count;$offset+=50){
      $chunk=@($needed[$offset..([math]::Min($offset+49,$needed.Count-1))])
      $selections=($chunk | ForEach-Object { "i$($_): issue(number:$($_)){$issueFields}" }) -join ' '
      $repo=$script:VelocityRepo.Split('/')
      $data=Invoke-VelocityGraphQL ('query{repository(owner:"'+$repo[0]+'",name:"'+$repo[1]+'"){'+$selections+'}}') @{}
      foreach($number in $chunk){
        $node=Get-VelocityValue $data.repository "i$number"
        if($null -eq $node -or $node.number -ne $number){throw "merged issue unresolved:$number"}
        $mergeIssues[[int]$number]=$node
      }
    }
    foreach ($issue in $mergeIssues.Values) { Complete-VelocityIssueConnections $issue }
    foreach($issue in $mergeIssues.Values){if($issue.labels.totalCount -ne @($issue.labels.nodes).Count){$gaps+=@("merged-issue-labels-incomplete:$($issue.number)")}}
    $facts.merges=@($prs | ForEach-Object {
      $pr=$_
      [pscustomobject][ordered]@{
        pr=[int]$pr.number;mergedAt=[string]$pr.mergedAt
        issues=@($references[[int]$pr.number] | ForEach-Object {
          $issue=$mergeIssues[[int]$_]
          $labels=@($issue.labels.nodes | ForEach-Object { [string]$_.name })
          $projected = ConvertTo-VelocityIssue $issue
          $projected | Add-Member kinds @($labels | Where-Object { $_.StartsWith('kind:',[StringComparison]::Ordinal) })
          $projected | Add-Member productLabeledAt $null
          $facts.issueDetails[[string]$issue.number] = $projected
          $projected
        })
      }
    })
  } catch { $gaps += "merged-prs: $($_.Exception.Message)" }

  try {
    $open = Invoke-VelocitySearch "repo:$script:VelocityRepo is:pr is:open" '... on PullRequest{number body repository{nameWithOwner} headRefOid isDraft mergeQueueEntry{id state} commits(last:1){nodes{commit{oid committedDate statusCheckRollup{state}}}} closingIssuesReferences(first:5){totalCount nodes{number labels(first:30){totalCount pageInfo{hasNextPage endCursor} nodes{name}}}}}'
    foreach ($pr in $open) { foreach ($issue in $pr.closingIssuesReferences.nodes) { Complete-VelocityIssueConnections $issue } }
    $facts.productPrs = @($open | ForEach-Object {
        $pr=$_
        $references=@(Get-VelocityPrIssueReferences $pr $facts.dispatchRows $Now)
        $productIssues = @($facts.productIssues | Where-Object { $references -contains [int]$_.number -and (Test-VelocityProductIssue $_ @($facts.platformMilestones) $controllerIssues) } | ForEach-Object { [int]$_.number } | Sort-Object -Unique)
        if ($productIssues.Count -gt 0) {
          $commit = @($_.commits.nodes)[0].commit
          [pscustomobject][ordered]@{
            pr = [int]$_.number; issues = $productIssues; isDraft = [bool]$_.isDraft
            repository=[string]$_.repository.nameWithOwner;headOid=[string]$_.headRefOid
            queueEntryId=$(if($null -ne $_.mergeQueueEntry){[string]$_.mergeQueueEntry.id}else{$null})
            velocityLanding=$(if($null -ne $capture){$p=$_;@($capture.records|Where-Object{$_.repository -ceq $p.repository.nameWithOwner -and $_.pr -eq $p.number -and $_.headOid -ceq $p.headRefOid})|Select-Object -First 1}else{$null})
            inMergeQueue = ($null -ne $_.mergeQueueEntry)
            ciState = $(if ($null -ne $commit.statusCheckRollup) { [string]$commit.statusCheckRollup.state } else { "NONE" })
            headCommittedAt = [string]$commit.committedDate
          }
        }
      })
    foreach($p in $open){
      if((Get-VelocityValue $p 'body') -isnot [string]){$gaps+=@("pr-body-incomplete:$($p.number)")}
      if($p.closingIssuesReferences.totalCount -ne @($p.closingIssuesReferences.nodes).Count -or
        @($p.closingIssuesReferences.nodes|Where-Object{$_.labels.totalCount -ne @($_.labels.nodes).Count}).Count -or
        @($p.commits.nodes).Count -ne 1 -or $p.commits.nodes[0].commit.oid -cne $p.headRefOid){$gaps+=@("pr-connections-incomplete:$($p.number)")}
    }
  } catch { $gaps += "open-prs: $($_.Exception.Message)" }

  try {
    . (Join-Path $Container ".orchestrator/dispatch-ownership.ps1")
    $runtime = Join-Path $Container '.orchestrator'
    $candidateCount = @([IO.Directory]::EnumerateFiles($runtime, 'dispatch-launch-*.json', [IO.SearchOption]::TopDirectoryOnly)).Count
    $ownership = Get-LiveDispatchOwnership $runtime ([IO.Path]::GetTempPath()) $Container -DeadlineMs 30000 -MaxRecords ([math]::Max(64, $candidateCount))
    $facts.ownershipStatus = [string]$ownership.health.status
    if($facts.ownershipStatus -cne 'ok'){$gaps+=@('ownership-not-complete')}
    $facts.activeLanes = @($ownership.activeLanes | ForEach-Object {
      $record=Get-Content -LiteralPath $_.ownershipRecordPath -Raw|ConvertFrom-Json -DateKind String
      if($record.launchId -cne $_.launchId){throw 'ownership changed while projecting'}
      [pscustomobject][ordered]@{lane=[string]$_.lane;laneRole=[string]$_.laneRole;label=[string]$record.label;worktree=[string]$_.worktree;head=[string]$_.head;launchHead=[string]$record.head;startedAt=[string]$record.recordedAt;launchId=[string]$_.launchId}
    })
  } catch { $gaps += "ownership: $($_.Exception.Message)" }

  try {
    # Detached launches record "pid N" in the dispatch note without an
    # ownership record. Count one live only while no terminal row follows it and
    # the process started within its launch window (PID-reuse guard).
    $known = @{}
    foreach ($lane in @($facts.activeLanes)) { $known[[string]$lane.lane] = $true }
    $rows = @($facts.dispatchRows | Sort-Object -Stable { Get-ObservedLaneTime $_ })
    for ($i = 0; $i -lt $rows.Count; $i++) {
      $row = $rows[$i]
      if ([string]$row.kind -cne "dispatch" -or $null -eq $row.PSObject.Properties["note"] -or $null -eq $row.PSObject.Properties["lane"]) { continue }
      $pidMatch = [regex]::Match([string]$row.note, '\bpid (\d+)\b')
      if (-not $pidMatch.Success -or $known.ContainsKey([string]$row.lane)) { continue }
      $closed = $false
      for ($j = $i + 1; $j -lt $rows.Count; $j++) {
        if ($null -ne $rows[$j].PSObject.Properties["lane"] -and [string]$rows[$j].lane -ceq [string]$row.lane -and
            ($script:TerminalKinds -contains [string]$rows[$j].kind -or [string]$rows[$j].kind -ceq "dispatch")) { $closed = $true; break }
      }
      if ($closed) { continue }
      $process = Get-Process -Id ([int]$pidMatch.Groups[1].Value) -ErrorAction SilentlyContinue
      if ($null -eq $process) { continue }
      try { $processStart = $process.StartTime } catch { continue }
      if ($null -eq $processStart) { continue }
      $started = $processStart.ToUniversalTime()
      $ts = Get-ObservedLaneTime $row
      if ($started -lt $ts.AddMinutes(-15) -or $started -gt $ts.AddMinutes(2)) { continue }
      $role = if ($null -ne $row.PSObject.Properties["laneRole"]) { [string]$row.laneRole } else { "" }
      $facts.activeLanes += [pscustomobject][ordered]@{ lane = [string]$row.lane; laneRole = $role; source = "dispatch-pid";startedAt=(Format-VelocityUtc $ts) }
      $known[[string]$row.lane] = $true
    }
  } catch { $gaps += "dispatch-pid-lanes: $($_.Exception.Message)" }

  $laneMap=Get-VelocityLaneIssueMap @($facts.dispatchRows) @($facts.productIssues | ForEach-Object { [int]$_.number })
  $stopsByIssue=@{};$authorityByIssue=@{}
  foreach($row in $facts.dispatchRows){
    $issueNumber=Get-VelocityValue $row 'issue'
    if(-not (Test-HoldInteger $issueNumber)){continue}
    $key=[string]$issueNumber
    if([string](Get-VelocityValue $row 'outcome' '') -cin @('REPLAN_REQUIRED','REPLAN_REPLACED','PARKED_DECISION','TERMINAL_PARK')){
      if(-not $stopsByIssue.ContainsKey($key)){$stopsByIssue[$key]=[Collections.Generic.List[object]]::new()}
      $stopsByIssue[$key].Add($row)
    }
    if($null -ne (Get-VelocityValue $row 'integrationAuthoritySchema') -or $null -ne (Get-VelocityValue $row 'authorityState')){
      if(-not $authorityByIssue.ContainsKey($key)){$authorityByIssue[$key]=[Collections.Generic.List[object]]::new()}
      $authorityByIssue[$key].Add($row)
    }
  }
  foreach($issue in $facts.productIssues){
    $stops=@($stopsByIssue[[string]$issue.number]|Where-Object{$null -ne $_}|Sort-Object{Get-ObservedLaneTime $_})
    if($stops.Count -gt 0){
      $issue.terminalState='parked'
      $reentry=@($facts.activeLanes|Where-Object{
        $key=[string](Get-VelocityValue $_ 'label' $_.lane)
        $entry=$laneMap[$key]
        $null -ne $entry -and $entry.issue -eq $issue.number -and $_.laneRole -ceq 'implementation' -and
          (ConvertTo-VelocityUtc (Get-VelocityValue $_ 'startedAt')) -gt (Get-ObservedLaneTime $stops[-1])
      })
      if($reentry.Count -eq 1 -and (Test-VelocityReadyIssue $issue @($facts.platformMilestones) $controllerIssues -AllowReentry)){$issue.terminalState='reentered'}
    }
    $authorityRows=@($authorityByIssue[[string]$issue.number]|Where-Object{$null -ne $_})
    foreach($target in @($authorityRows|Group-Object{ "$(Get-VelocityValue $_ 'pr')/$(Get-VelocityValue $_ 'targetBranch')" })){
      $row=$target.Group[-1]
      try{
        $current=@($facts.productPrs|Where-Object pr -EQ $row.pr)
        $head=if($current.Count -eq 1){$current[0].headOid}else{$row.targetHead}
        $terminal=Reduce-LandedIntegrationAuthority $authorityHistory ([int]$row.pr) ([string]$row.targetBranch) ([string]$head)
        if($terminal.state -ceq 'STOP'){$issue.terminalState='parked'}
        elseif($terminal.state -cne 'ELIGIBLE'){$issue.terminalState='unknown'}
      }catch{$issue.terminalState='unknown'}
    }
  }

  try {
    $known = @{}
    foreach ($issue in @($facts.productIssues)) { $known[[int]$issue.number] = $true }
    foreach ($key in $facts.issueDetails.Keys) { $known[[int]$key] = $true }
    $needed = @($facts.dispatchRows | Where-Object { $null -ne $_.PSObject.Properties["issue"] -and $null -ne $_.issue -and [int]$_.issue -gt 0 } |
      ForEach-Object { [int]$_.issue } | Sort-Object -Unique | Where-Object { -not $known.ContainsKey($_) })
    for ($offset = 0; $offset -lt $needed.Count; $offset += 50) {
      $chunk = @($needed[$offset..([math]::Min($offset + 49, $needed.Count - 1))])
      $selections = ($chunk | ForEach-Object { "i$($_): issueOrPullRequest(number:$($_)){... on Issue{number title body labels(first:30){totalCount pageInfo{hasNextPage endCursor} nodes{name}} milestone{number state description}}}" }) -join " "
      $data = Invoke-VelocityGraphQL ('query{repository(owner:"chase-sets",name:"chase-sets"){' + $selections + '}}') @{}
      foreach ($n in $chunk) {
        $node = $data.repository."i$n"
        if ($null -ne $node -and $null -ne (Get-VelocityValue $node 'number')) {
          Complete-VelocityIssueConnections $node
          if ($node.labels.totalCount -ne @($node.labels.nodes).Count) { $gaps += "issue-details-labels-incomplete:$n" }
          $facts.issueDetails["$n"] = ConvertTo-VelocityIssue $node
        }
        $facts.issueKinds["$n"] = @(if ($null -ne $node -and $null -ne (Get-VelocityValue $node 'labels')) { $node.labels.nodes | ForEach-Object { [string]$_.name } | Where-Object { $_.StartsWith("kind:", [StringComparison]::Ordinal) } })
      }
    }
  } catch { $gaps += "issue-kinds: $($_.Exception.Message)" }

  $facts.issueKinds = [pscustomobject]$facts.issueKinds
  $facts.issueDetails = [pscustomobject]$facts.issueDetails
  $productMerges = @(Get-VelocityProductMerges ([pscustomobject]$facts) $Now $controllerIssues)
  if ($productMerges.Count -gt 0) { $facts.lastProductMergeAt=[string]$productMerges[-1].mergedAt }
  $facts.gaps = @($gaps)
  $facts.complete = ($gaps.Count -eq 0)
  return [pscustomobject]$facts
}

if ($MyInvocation.InvocationName -ne ".") {
  $container = [IO.Path]::GetFullPath($ContainerRoot)
  $now = if ([string]::IsNullOrWhiteSpace($NowUtc)) { [datetime]::UtcNow } else { ConvertTo-VelocityUtc $NowUtc }
  $observationPath = if ([string]::IsNullOrWhiteSpace($ObservationLog)) { Join-Path $container ".orchestrator/logs/velocity-observations.jsonl" } else { $ObservationLog }
  $facts = if ([string]::IsNullOrWhiteSpace($FactsPath)) { Get-VelocityFacts $container $now $CycleId $LandingCapturePath } else { Get-Content -LiteralPath $FactsPath -Raw | ConvertFrom-Json -DateKind String }
  if (-not [string]::IsNullOrWhiteSpace($FactsOut)) {
    [IO.File]::WriteAllText($FactsOut, ($facts | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
  }
  $report = Get-VelocityReport $facts $now (Read-VelocityObservations $observationPath $now)
  if (-not $NoRecord -and $report.factsComplete) {
    $observation = [ordered]@{
      ts = $report.now; floorState = $report.metrics.floorState
      flowing = @($report.metrics.flowingProductIssues).Count; readyNotInFlight = @($report.metrics.readyNotInFlight).Count
      hoursSinceProductMerge = $report.metrics.hoursSinceProductMerge; status = $report.status
    }
    [IO.Directory]::CreateDirectory((Split-Path -Parent $observationPath)) | Out-Null
    [IO.File]::AppendAllText($observationPath, ($observation | ConvertTo-Json -Compress) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
  }
  if ($Summary) {
    $alarmText = (@($report.alarms | ForEach-Object { "$($_.id)$(if ($_.unacted) { '(UNACTED)' } elseif ($_.actedAt) { '(acted)' } else { '(open)' })" }) -join ",")
    Write-Output ("VELOCITY {0} floor={1} flowing={2} readyIdle={3} hoursSinceProductMerge={4} alarms=[{5}] held={6} heldPrs={7} holds={8} terminalParked={9} gaps=[{10}] legacyDispatchRows={11} nonPositiveIssueDispatchRows={12}" -f $report.status, $report.metrics.floorState,
      (@($report.metrics.flowingProductIssues) -join ","), (@($report.metrics.readyNotInFlight) -join ","), $report.metrics.hoursSinceProductMerge, $alarmText,
      $report.metrics.heldCount,(@($report.metrics.heldProductPrs|ForEach-Object pr)-join ','),(@($report.metrics.heldProductPrs|ForEach-Object holdIds|Sort-Object -Unique)-join ','),
      (@($report.diagnostics.terminalParkedIssues|ForEach-Object issue)-join ','),($report.gaps -join ','),@($report.diagnostics.legacyDispatchRows).Count,@($report.diagnostics.nonPositiveIssueDispatchRows).Count)
    foreach($alarm in $report.alarms){Write-Output "$($alarm.id): $($alarm.detail)"}
  } else {
    Write-Output ($report | ConvertTo-Json -Depth 8)
  }
}
