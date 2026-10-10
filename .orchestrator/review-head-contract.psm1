$ErrorActionPreference = "Stop"
function Get-ObservedLaneValue($Row, [string]$Name) {
  if ($null -ne $Row -and $null -ne $Row.PSObject.Properties[$Name]) { return $Row.$Name }
  return $null
}

function ConvertTo-ObservedLaneUtc([string]$Value) {
  $parsed = [datetimeoffset]::MinValue
  if ($Value -cnotmatch '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,7})?(?:Z|\+00:00)$' -or
      -not [datetimeoffset]::TryParse($Value, [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::None, [ref]$parsed)) {
    throw 'OBSERVED_TIME_INVALID: an explicit parseable UTC instant is required'
  }
  return $parsed.UtcDateTime
}

function Test-ObservedLaneTerminal([string]$Kind) {
  return $Kind -cin @('lane-complete','lane-blocked','review-complete','decision-resolved','verify-complete','repair-complete')
}

function Get-ObservedLaneTime($Row) {
  $value = if ([string]$Row.kind -ceq 'dispatch') { Get-ObservedLaneValue $Row 'observedStartAt' }
    elseif (Test-ObservedLaneTerminal ([string]$Row.kind)) { Get-ObservedLaneValue $Row 'observedEndAt' }
    else { $null }
  if ($null -eq $value) { $value = $Row.ts }
  if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) { return $null }
  if ($value -is [datetime]) { return $value.ToUniversalTime() }
  return [datetime]::Parse([string]$value, [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)
}

function Assert-ObservedLaneFields($Row, [datetime]$Now) {
  if (Test-LaneTimeObservation $Row) { Assert-LaneTimeObservationFields $Row $Now; return }
  $start = $null -ne $Row.PSObject.Properties['observedStartAt']
  $end = $null -ne $Row.PSObject.Properties['observedEndAt']
  $evidence = $null -ne $Row.PSObject.Properties['observedEvidence']
  if (-not ($start -or $end -or $evidence)) { return }
  if ($end -and -not (Test-ObservedLaneTerminal ([string]$Row.kind))) { throw 'OBSERVED_END_KIND_INVALID: observed end requires a terminal kind' }
  if ($start -and [string]$Row.kind -cne 'dispatch') { throw 'OBSERVED_START_KIND_INVALID: observed start requires dispatch' }
  if (-not ($start -or $end)) { throw 'OBSERVED_TIME_REQUIRED: evidence requires an observed time' }
  if (-not $evidence -or [string]$Row.observedEvidence -cnotmatch '^(report-mtime|transcript-ctime|transcript-lastwrite):\S[^\r\n]*$') {
    throw 'OBSERVED_EVIDENCE_REQUIRED: an evidence citation is required'
  }
  if ([string]::IsNullOrWhiteSpace([string](Get-ObservedLaneValue $Row 'lane'))) { throw 'OBSERVED_LANE_REQUIRED: a lane is required' }
  $value = if ($start) { $Row.observedStartAt } else { $Row.observedEndAt }
  $at = ConvertTo-ObservedLaneUtc ([string]$value)
  if ($at -gt $Now) { throw 'OBSERVED_TIME_FUTURE: observed time is after now' }
  $written = [datetime]::Parse([string]$Row.ts, [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)
  if ($at -gt $written) { throw 'OBSERVED_TIME_AFTER_ROW: observed time is after the row timestamp' }
}

function Assert-ObservedLaneHistory($Row, $History) {
  $start = $null -ne $Row.PSObject.Properties['observedStartAt']
  $end = $null -ne $Row.PSObject.Properties['observedEndAt']
  if (-not ($start -or $end)) { return }
  if (-not $History.complete -and $History.reason -cne 'HISTORY_MISSING') { throw "OBSERVED_HISTORY_INVALID: $($History.reason)" }
  $attemptField = if (Get-ObservedLaneValue $Row 'attemptId') { 'attemptId' }
    elseif (Get-ObservedLaneValue $Row 'reviewerAttempt') { 'reviewerAttempt' }
    else { $null }
  $prior = @($History.rows | ForEach-Object value | Where-Object {
    [string](Get-ObservedLaneValue $_ 'lane') -ceq [string]$Row.lane -and
      (-not $attemptField -or -not (Get-ObservedLaneValue $_ $attemptField) -or
        [string](Get-ObservedLaneValue $_ $attemptField) -ceq [string](Get-ObservedLaneValue $Row $attemptField))
  })
  $at = Get-ObservedLaneTime $Row
  if ($start) {
    foreach ($previous in $prior) {
      try { $previousAt = ConvertTo-ObservedLaneUtc ([string](Get-ObservedLaneValue $previous 'ts')) }
      catch { throw 'OBSERVED_HISTORY_INVALID: prior lane timestamp is not a UTC instant' }
      if ($at -lt $previousAt) { throw 'OBSERVED_START_BEFORE_PRIOR_ROW: observed start is before a prior lane row' }
    }
  } else {
    try {
      $dispatch = @($prior | Where-Object { Test-LaneTimeLaunch $_ } |
        Sort-Object -Stable { ConvertTo-ObservedLaneUtc ([string](Get-ObservedLaneValue $_ 'ts')) } | Select-Object -Last 1)
    } catch { throw 'OBSERVED_HISTORY_INVALID: dispatch timestamp is not a UTC instant' }
    if ($dispatch.Count -ne 1) { throw 'OBSERVED_DISPATCH_REQUIRED: latest lane dispatch is required' }
    try { $dispatchedAt = Get-ObservedLaneTime $dispatch[0] }
    catch { throw 'OBSERVED_HISTORY_INVALID: dispatch observation is invalid' }
    if ($at -lt $dispatchedAt) { throw 'OBSERVED_END_BEFORE_DISPATCH: observed end is before the dispatch observation' }
  }
}

function Test-LaneTimeObservation($Row) {
  return $null -ne $Row -and ($Row.kind -ceq 'lane-time-correction' -or $Row.observationSchema -cin @('lane-time-correction/v1','lane-time-harvest/v1'))
}

function Assert-LaneTimeKeys($Object, [string[]]$Required, [string[]]$Optional = @()) {
  if ($Object -isnot [pscustomobject]) { throw 'LANE_TIME_SCHEMA_INVALID: object required' }
  $names = @($Object.PSObject.Properties | ForEach-Object Name)
  if (@($Required | Where-Object { $_ -cnotin $names }).Count -or
      @($names | Where-Object { $_ -cnotin ($Required + $Optional) }).Count) {
    throw 'LANE_TIME_SCHEMA_INVALID: missing or unknown fields'
  }
}

function Get-LaneTimeHash([byte[]]$Bytes) {
  return ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes))).ToLowerInvariant()
}

function ConvertFrom-LaneTimeJson([string]$Text) {
  $document = [System.Text.Json.JsonDocument]::Parse($Text)
  try {
    $pending = [Collections.Generic.Stack[System.Text.Json.JsonElement]]::new()
    $pending.Push($document.RootElement)
    while ($pending.Count) {
      $element = $pending.Pop()
      if ($element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($property in $element.EnumerateObject()) {
          if (-not $names.Add($property.Name)) { throw 'LANE_TIME_SOURCE_INVALID: duplicate field' }
          $pending.Push($property.Value)
        }
      } elseif ($element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
        foreach ($item in $element.EnumerateArray()) { $pending.Push($item) }
      }
    }
  } finally { $document.Dispose() }
  return ,(ConvertFrom-Json -InputObject $Text -DateKind String -NoEnumerate)
}

function Read-LaneTimeCapture([string]$Path) {
  try {
    $full = [IO.Path]::GetFullPath($Path)
    $file = Get-Item -LiteralPath $full -ErrorAction Stop
    if ($file.Length -gt 33554432 -or $file.PSIsContainer) { throw 'capture size/type' }
    $bytes = [IO.File]::ReadAllBytes($full)
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    $entries = ConvertFrom-LaneTimeJson $text
    if ($entries -isnot [array]) { throw 'capture must be an array' }
    return [pscustomobject]@{ path=$full; sha256=(Get-LaneTimeHash $bytes); entries=$entries }
  } catch { throw "LANE_TIME_SOURCE_INVALID: $($_.Exception.Message)" }
}

function Get-LaneTimeAttempts($Row) {
  $attempts = [ordered]@{}
  $fields = @('attemptId','reviewerAttempt','authorAttempt')
  foreach ($property in $Row.PSObject.Properties) {
    if ($property.Name -match 'attempt' -and $property.Name -cnotin $fields) {
      throw 'LANE_TIME_ATTEMPT_INVALID: unsupported attempt identity'
    }
  }
  foreach ($field in $fields) {
    if ($null -ne $Row.PSObject.Properties[$field]) {
      if ($Row.$field -isnot [string] -or $Row.$field -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,255}$') {
        throw 'LANE_TIME_ATTEMPT_INVALID: malformed attempt identity'
      }
      $attempts[$field] = $Row.$field
    }
  }
  return [pscustomobject]$attempts
}

function Test-LaneTimeLaunch($Row) {
  return [string](Get-ObservedLaneValue $Row 'kind') -ceq 'dispatch' -and
    -not (Get-ObservedLaneValue $Row 'dispatchRoutingSchema')
}

function Get-LaneTimeHistoryIndex($History) {
  if ($null -ne $History.PSObject.Properties['laneTimeIndex']) { return $History.laneTimeIndex }
  $byLane=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
  $byRaw=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
  foreach($entry in $History.rows) {
    $hash=[string]$entry.rawSha256
    if(-not $byRaw.ContainsKey($hash)){$byRaw[$hash]=[Collections.Generic.List[object]]::new()}
    $byRaw[$hash].Add($entry)
    $row=$entry.value
    if($null -eq $row -or $null -eq $row.PSObject.Properties['lane']){continue}
    $lane=[string]$row.lane
    if(-not $byLane.ContainsKey($lane)){$byLane[$lane]=[Collections.Generic.List[object]]::new()}
    $byLane[$lane].Add($entry)
  }
  $index=[pscustomobject]@{byLane=$byLane;byRaw=$byRaw}
  $History|Add-Member laneTimeIndex $index -Force
  return $index
}

function Get-LaneTimeLaneRows($History,[string]$Lane) {
  $index=Get-LaneTimeHistoryIndex $History
  if($index.byLane.ContainsKey($Lane)){return $index.byLane[$Lane].ToArray()}
}

function Get-LaneTimeLaneHistoryHash($History, [string]$Lane) {
  $identities = @(Get-LaneTimeLaneRows $History $Lane | Where-Object {
    -not (Test-LaneTimeObservation $_.value)
  } | ForEach-Object rawSha256)
  return Get-LaneTimeHash ([Text.Encoding]::UTF8.GetBytes(($identities -join "`n")))
}

function Get-LaneTimeDispatchTarget($Entry, $History) {
  return [pscustomobject][ordered]@{
    rawSha256=[string]$Entry.rawSha256; ts=[string]$Entry.value.ts
    attempts=(Get-LaneTimeAttempts $Entry.value)
    laneHistorySha256=(Get-LaneTimeLaneHistoryHash $History ([string]$Entry.value.lane))
  }
}

function Assert-LaneTimeObservationFields($Row, [datetime]$Now) {
  $correction = [string](Get-ObservedLaneValue $Row 'kind') -ceq 'lane-time-correction'
  $timeField = if ($correction) { 'observedStartAt' } else { 'observedEndAt' }
  Assert-LaneTimeKeys $Row @('ts','kind','issue','lane','observationSchema','dispatchTarget','sourceCapture','observedEvidence',$timeField)
  $schema = if ($correction) { 'lane-time-correction/v1' } else { 'lane-time-harvest/v1' }
  if ($Row.observationSchema -cne $schema -or (-not $correction -and $Row.kind -cne 'lane-complete') -or
      -not (Test-WholeNumber $Row.issue 1) -or $Row.issue -gt [int]::MaxValue -or
      $Row.lane -isnot [string] -or $Row.lane -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$') {
    throw 'LANE_TIME_SCHEMA_INVALID: observation kind/identity'
  }
  Assert-LaneTimeKeys $Row.dispatchTarget @('rawSha256','ts','attempts','laneHistorySha256')
  foreach ($field in @('rawSha256','laneHistorySha256')) {
    if ($Row.dispatchTarget.$field -isnot [string] -or $Row.dispatchTarget.$field -cnotmatch '^[a-f0-9]{64}$') {
      throw 'LANE_TIME_TARGET_INVALID: SHA-256 required'
    }
  }
  Assert-LaneTimeKeys $Row.dispatchTarget.attempts @() @('attemptId','reviewerAttempt','authorAttempt')
  [void](Get-LaneTimeAttempts $Row.dispatchTarget.attempts)
  Assert-LaneTimeKeys $Row.sourceCapture @('path','sha256','lane','startField','endField','dispatchField')
  $source = $Row.sourceCapture
  if ($source.path -isnot [string] -or -not [IO.Path]::IsPathFullyQualified($source.path) -or
      $source.path -cne [IO.Path]::GetFullPath($source.path) -or
      $source.sha256 -isnot [string] -or $source.sha256 -cnotmatch '^[a-f0-9]{64}$' -or
      $source.lane -cne $Row.lane -or $source.startField -cnotin @('transcriptCreatedUtc','dispatchRowUtc') -or
      $source.endField -cne 'reportMtimeUtc' -or $source.dispatchField -cne 'dispatchRowUtc' -or
      ($correction -and $source.startField -cne 'transcriptCreatedUtc')) {
    throw 'LANE_TIME_SOURCE_INVALID: closed capture identity required'
  }
  $prefix = if ($correction) { 'transcript-ctime' } else { 'report-mtime' }
  $field = if ($correction) { $source.startField } else { $source.endField }
  if ($Row.observedEvidence -isnot [string] -or $Row.observedEvidence -cne "${prefix}:$($source.path)#$($Row.lane).$field") {
    throw 'LANE_TIME_SOURCE_INVALID: citation does not bind selected field'
  }
  foreach ($value in @($Row.ts,$Row.dispatchTarget.ts,$Row.$timeField)) {
    if ($value -isnot [string]) { throw 'OBSERVED_TIME_INVALID: string UTC required' }
    $at = ConvertTo-ObservedLaneUtc $value
    if ($at -gt $Now) { throw 'OBSERVED_TIME_FUTURE: observation row or target is future' }
  }
  if ((ConvertTo-ObservedLaneUtc $Row.$timeField) -gt (ConvertTo-ObservedLaneUtc $Row.ts)) {
    throw 'OBSERVED_TIME_AFTER_ROW: observed time is after the row timestamp'
  }
}

function Get-LaneTimeSignature($Row) {
  $ordered = [ordered]@{kind=$Row.kind;issue=$Row.issue;lane=$Row.lane;schema=$Row.observationSchema}
  foreach ($field in @('rawSha256','ts','laneHistorySha256')) { $ordered[$field]=$Row.dispatchTarget.$field }
  $ordered.attempts=Get-LaneTimeAttempts $Row.dispatchTarget.attempts
  foreach ($field in @('path','sha256','lane','startField','endField','dispatchField')) { $ordered["source-$field"]=$Row.sourceCapture.$field }
  $ordered.time=if ($Row.kind -ceq 'lane-time-correction') { $Row.observedStartAt } else { $Row.observedEndAt }
  $ordered.evidence=$Row.observedEvidence
  return $ordered | ConvertTo-Json -Compress -Depth 8
}

function Assert-LaneTimeObservationHistory($Row, $History, [datetime]$Now = [datetime]::UtcNow, [switch]$RequireCorrection, [switch]$Persisted) {
  Assert-LaneTimeObservationFields $Row $Now
  if (-not $History.complete) { throw "LANE_TIME_HISTORY_INVALID: $($History.reason)" }
  $target = $Row.dispatchTarget
  $index=Get-LaneTimeHistoryIndex $History
  $matches = @(if($index.byRaw.ContainsKey($target.rawSha256)){$index.byRaw[$target.rawSha256].ToArray()})
  if ($matches.Count -ne 1) { throw 'LANE_TIME_TARGET_INVALID: missing or duplicate raw-row identity' }
  $entry = $matches[0]; $dispatch = $entry.value
  $laneRows = @(Get-LaneTimeLaneRows $History $Row.lane)
  $recorded = @($laneRows | Where-Object {
    (Test-LaneTimeObservation $_.value) -and $_.value.kind -ceq $Row.kind -and
      $_.value.dispatchTarget.rawSha256 -ceq $target.rawSha256
  })
  foreach($prior in $recorded) {
    Assert-LaneTimeObservationFields $prior.value $Now
    if((Get-LaneTimeSignature $prior.value) -cne (Get-LaneTimeSignature $Row)) {
      throw 'LANE_TIME_REPLAY_CONFLICT: conflicting observation replay'
    }
  }
  if($recorded.Count -gt 1){throw 'LANE_TIME_REPLAY_CONFLICT: duplicate recorded observation'}
  if($recorded.Count -eq 1) {
    # Validate recorded facts at their append boundary, not against later reuse.
    # New proposals still use the complete current lane evidence census.
    $laneRows=@($laneRows | Where-Object {$_.line -le $recorded[0].line})
    $History=[pscustomobject]@{complete=$true;reason='HISTORY_COMPLETE';rows=$laneRows}
  }
  if (-not (Test-LaneTimeLaunch $dispatch) -or -not (Test-WholeNumber $dispatch.issue 1) -or $dispatch.lane -cne $Row.lane -or
      $dispatch.issue -ne $Row.issue -or $dispatch.ts -cne $target.ts -or
      ((Get-LaneTimeAttempts $dispatch | ConvertTo-Json -Compress) -cne (Get-LaneTimeAttempts $target.attempts | ConvertTo-Json -Compress))) {
    throw 'LANE_TIME_TARGET_INVALID: lane/issue/time/attempt mismatch'
  }
  if ($target.laneHistorySha256 -cne (Get-LaneTimeLaneHistoryHash $History $Row.lane)) {
    throw 'LANE_TIME_TARGET_STALE: lane evidence changed since planning'
  }
  $written = ConvertTo-ObservedLaneUtc $target.ts
  if ($Persisted) {
    $late = $Row.sourceCapture.startField -ceq 'transcriptCreatedUtc'
    $corrections = @($laneRows | Where-Object {
      $_.value.kind -ceq 'lane-time-correction' -and $_.value.dispatchTarget.rawSha256 -ceq $target.rawSha256
    })
    $start = if ($Row.kind -ceq 'lane-time-correction') { ConvertTo-ObservedLaneUtc $Row.observedStartAt }
      elseif ($late -and $corrections.Count -eq 1) { ConvertTo-ObservedLaneUtc $corrections[0].value.observedStartAt }
      else { Get-ObservedLaneTime $dispatch }
    $end = if ($Row.kind -ceq 'lane-complete') { ConvertTo-ObservedLaneUtc $Row.observedEndAt } else { $start }
    if ($start -gt $written -or $end -lt $start -or $end -gt (ConvertTo-ObservedLaneUtc $Row.ts)) {
      throw 'LANE_TIME_INTERVAL_INVALID: persisted interval/dispatch contradiction'
    }
  } else {
    $capture = Read-LaneTimeCapture $Row.sourceCapture.path
    if ($capture.sha256 -cne $Row.sourceCapture.sha256) { throw 'LANE_TIME_SOURCE_INVALID: capture digest mismatch' }
    $sources = @($capture.entries | Where-Object { [string](Get-ObservedLaneValue $_ 'lane') -ceq $Row.lane })
    if ($sources.Count -ne 1) { throw 'LANE_TIME_SOURCE_INVALID: missing or ambiguous captured lane' }
    $source = $sources[0]
    if (-not (Test-WholeNumber $source.issue 1) -or $source.issue -ne $Row.issue -or
        $source.lateDispatchRow -isnot [bool]) { throw 'LANE_TIME_SOURCE_INVALID: captured issue/flag mismatch' }
    $late = $source.lateDispatchRow
    $startField = if ($late) { 'transcriptCreatedUtc' } else { 'dispatchRowUtc' }
    if ($Row.sourceCapture.startField -cne $startField -or ($Row.kind -ceq 'lane-time-correction' -and -not $late)) {
      throw 'LANE_TIME_SOURCE_INVALID: capture does not support correction'
    }
    $start = ConvertTo-ObservedLaneUtc ([string](Get-ObservedLaneValue $source $startField))
    $end = ConvertTo-ObservedLaneUtc ([string](Get-ObservedLaneValue $source 'reportMtimeUtc'))
    if ((ConvertTo-ObservedLaneUtc ([string]$source.dispatchRowUtc)) -ne $written -or $start -gt $written -or
        $end -lt $start -or $end -gt $Now -or $end -gt (ConvertTo-ObservedLaneUtc $Row.ts)) {
      throw 'LANE_TIME_INTERVAL_INVALID: captured interval/dispatch contradiction'
    }
    $expected = if ($Row.kind -ceq 'lane-time-correction') { $start } else { $end }
    $actual = if ($Row.kind -ceq 'lane-time-correction') { $Row.observedStartAt } else { $Row.observedEndAt }
    if ((ConvertTo-ObservedLaneUtc $actual) -ne $expected) { throw 'LANE_TIME_INTERVAL_INVALID: observation disagrees with captured field' }
  }
  $attempts = @($target.attempts.PSObject.Properties | ForEach-Object Name)
  foreach ($prior in $laneRows) {
    $value = $prior.value
    if (Test-LaneTimeObservation $value) { continue }
    [void](ConvertTo-ObservedLaneUtc ([string]$value.ts))
    $priorAt = Get-ObservedLaneTime $value
    if ($prior.line -lt $entry.line -and $priorAt -gt $start) {
      throw 'LANE_TIME_INTERVAL_INVALID: corrected start precedes earlier lane evidence'
    }
    $otherAttempts = Get-LaneTimeAttempts $value
    $disjoint = @($attempts | Where-Object {
      $null -ne $otherAttempts.PSObject.Properties[$_] -and $otherAttempts.$_ -cne $target.attempts.$_
    }).Count -gt 0
    if (Test-LaneTimeLaunch $value) {
      if ($prior.rawSha256 -cne $target.rawSha256 -and -not $disjoint) {
        throw 'LANE_TIME_TARGET_AMBIGUOUS: conflicting or legacy launch identity'
      }
      if ($prior.rawSha256 -cne $target.rawSha256 -and (Get-ObservedLaneTime $value) -gt $start -and
          (Get-ObservedLaneTime $value) -lt $end) { throw 'LANE_TIME_INTERVAL_INVALID: overlapping subsequent launch' }
    }
    if (Test-ObservedLaneTerminal ([string]$value.kind)) {
      if (-not $disjoint) { throw 'LANE_TIME_TERMINAL_CONFLICT: existing unbound terminal' }
      if ($priorAt -gt $start -and $priorAt -lt $end) {
        throw 'LANE_TIME_INTERVAL_INVALID: overlapping disjoint terminal'
      }
    }
    if (-not $disjoint -and $null -ne (Get-ObservedLaneValue $value 'observedStartAt') -and
        (ConvertTo-ObservedLaneUtc ([string]$value.observedStartAt)) -ne $start) {
      throw 'LANE_TIME_LAUNCH_CONFLICT: canonical launch observation disagrees'
    }
  }
  $already = $false; $hasCorrection = $false
  $signature = Get-LaneTimeSignature $Row
  foreach ($prior in $laneRows) {
    $value = $prior.value
    if (-not (Test-LaneTimeObservation $value)) { continue }
    Assert-LaneTimeObservationFields $value $Now
    if ($value.dispatchTarget.rawSha256 -cne $target.rawSha256) { continue }
    if ($value.kind -ceq 'lane-time-correction') { $hasCorrection=$true }
    if ($value.kind -ceq $Row.kind) {
      if ((Get-LaneTimeSignature $value) -cne $signature) { throw 'LANE_TIME_REPLAY_CONFLICT: conflicting observation replay' }
      if ($already) { throw 'LANE_TIME_REPLAY_CONFLICT: duplicate recorded observation' }
      $already=$true
    } elseif ($value.sourceCapture.sha256 -cne $Row.sourceCapture.sha256 -or
        $value.dispatchTarget.laneHistorySha256 -cne $target.laneHistorySha256) {
      throw 'LANE_TIME_REPLAY_CONFLICT: correction/completion source mismatch'
    }
  }
  if ($RequireCorrection -and $late -and $Row.kind -ceq 'lane-complete' -and -not $hasCorrection) {
    throw 'LANE_TIME_CORRECTION_REQUIRED: late terminal requires its correction first'
  }
  return [pscustomobject]@{ dispatch=$entry; start=$start; end=$end; alreadyRecorded=$already }
}

function Get-LaneTimeProjection($History, [datetime]$Now = [datetime]::UtcNow) {
  $projected = [Collections.Generic.List[object]]::new()
  $gaps = [Collections.Generic.List[string]]::new()
  $starts = @{}
  foreach ($entry in $History.rows) {
    if (-not (Test-LaneTimeObservation $entry.value)) { continue }
    try {
      $binding = Assert-LaneTimeObservationHistory $entry.value $History $Now -RequireCorrection -Persisted
      if ($entry.value.kind -ceq 'lane-time-correction') { $starts[$binding.dispatch.rawSha256]=$entry.value }
    } catch { $gaps.Add("lane-time-invalid:$($entry.line):$(($_.Exception.Message -split ':',2)[0])") }
  }
  $lastLaunch = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
  if($starts.Count){ foreach($entry in $History.rows) {
    $lane = [string](Get-ObservedLaneValue $entry.value 'lane')
    if (Test-LaneTimeLaunch $entry.value) { $lastLaunch[$lane] = $entry; continue }
    if(-not (Test-ObservedLaneTerminal ([string](Get-ObservedLaneValue $entry.value 'kind'))) -or
        (Test-LaneTimeObservation $entry.value)){continue}
    if($lastLaunch.ContainsKey($lane) -and $starts.ContainsKey($lastLaunch[$lane].rawSha256)) {
      $gaps.Add("lane-time-invalid:$($entry.line):LANE_TIME_TERMINAL_CONFLICT")
    }
  } }
  foreach ($entry in $History.rows) {
    $row = $entry.value.PSObject.Copy()
    if ($starts.ContainsKey($entry.rawSha256) -and -not $gaps.Count) {
      $correction = $starts[$entry.rawSha256]
      $row | Add-Member observedStartAt $correction.observedStartAt -Force
      $row | Add-Member observedEvidence $correction.observedEvidence -Force
      $row | Add-Member laneTimeOriginalRaw $entry.raw -Force
      $row | Add-Member laneTimeRawSha256 $entry.rawSha256 -Force
      $row | Add-Member laneTimeSourceCapture $correction.sourceCapture -Force
    }
    $projected.Add($row)
  }
  return [pscustomobject]@{rows=$projected.ToArray();gaps=$gaps.ToArray()}
}

function Assert-LaneTimeTerminalTarget([string]$Path, [string]$Lane) {
  if (-not [IO.File]::Exists($Path)) { return }
  $stream = [IO.File]::OpenRead($Path)
  try {
    if ($stream.Length) {
      [void]$stream.Seek(-1, [IO.SeekOrigin]::End)
      if ($stream.ReadByte() -ne 10) { throw 'OBSERVED_HISTORY_INVALID: unterminated history' }
    }
  } finally { $stream.Dispose() }
  $laneToken = ConvertTo-Json -InputObject $Lane -Compress
  $latest = $null
  $corrected = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($raw in [IO.File]::ReadLines($Path)) {
    if ($raw.IndexOf($laneToken, [StringComparison]::Ordinal) -lt 0) { continue }
    try { $row = ConvertFrom-LaneTimeJson $raw }
    catch { throw 'LANE_TIME_HISTORY_INVALID: malformed lane evidence' }
    if ([string](Get-ObservedLaneValue $row 'lane') -cne $Lane) { continue }
    if (Test-LaneTimeLaunch $row) { $latest = Get-LaneTimeHash ([Text.Encoding]::UTF8.GetBytes($raw)) }
    elseif ($row.kind -ceq 'lane-time-correction') {
      Assert-LaneTimeObservationFields $row ([datetime]::UtcNow)
      [void]$corrected.Add($row.dispatchTarget.rawSha256)
    }
  }
  if ($null -ne $latest -and $corrected.Contains($latest)) {
    throw 'LANE_TIME_TARGET_REQUIRED: corrected terminal must bind its dispatch'
  }
}
$routingLibrary = Join-Path $PSScriptRoot 'routing-data.ps1'
if (-not (Test-Path -LiteralPath $routingLibrary -PathType Leaf)) { $routingLibrary = Join-Path (Get-Location) '.orchestrator/routing-data.ps1' }
if (Test-Path -LiteralPath $routingLibrary -PathType Leaf) { . $routingLibrary -Library }

$script:ReviewReceiptSchema = "exact-head-review-receipt/v1"
$script:ReviewReducerSchema = "exact-head-review-reducer/v1"
$script:ControllerDispatchSchemaV1 = "controller-review-dispatch/v1"
$script:ControllerReceiptSchemaV1 = "controller-review-receipt/v1"
$script:ControllerCorrectionSchema = "controller-review-audit-correction/v1"
$script:ControllerDispatchSchemaV2 = "controller-review-dispatch/v2"
$script:ControllerReceiptSchemaV2 = "controller-review-receipt/v2"
$script:ControllerClassificationSchema = "controller-review-row-classification/v1"
$script:ControllerReductionSchema = "controller-release-reduction/v1"
function Get-ReviewRecordVocabulary {
  $data = $null
  try { $data = Get-RoutingData -ReadOnly } catch { }
  $models = if ($null -ne $data) { @(Get-RoutingModelSet -Registry $data.registry -Scope all) } else { @() }
  # Reader-only compatibility for v2.86 evidence that predates the live
  # registry. This is deliberately not an admission identity.
  $models += 'gpt-5.6-terra'
  [pscustomobject]@{
    models = @($models | Sort-Object -Unique)
    efforts = @('low','medium','high','xhigh','max','minimal')
  }
}
function Get-ReviewSelectableModels([object]$Vocabulary = $null) {
  if ($null -eq $Vocabulary) { $Vocabulary = Get-ReviewRecordVocabulary }
  return @($Vocabulary.models)
}
$script:TerminalReviewOutcomes = @("PASS", "BLOCK_FIXABLE", "BLOCK_REPLAN", "SKIP")
$script:BlockingReviewOutcomes = @("BLOCK_FIXABLE", "BLOCK_REPLAN")

function Get-ExactHeadReviewContract {
  [pscustomobject][ordered]@{
    receiptSchema = $script:ReviewReceiptSchema
    reducerSchema = $script:ReviewReducerSchema
    maxHistoryBytes = 33554432
    maxHistoryRows = 50000
  }
}

function Test-JsonProperty($Object, [string]$Name) {
  return $null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]
}

function Test-WholeNumber($Value, [int]$Minimum = 0) {
  if ($Value -isnot [byte] -and
      $Value -isnot [int16] -and
      $Value -isnot [int32] -and
      $Value -isnot [int64] -and
      $Value -isnot [uint16] -and
      $Value -isnot [uint32] -and
      $Value -isnot [uint64]) {
    return $false
  }
  try { return [int64]$Value -ge $Minimum } catch { return $false }
}

function Get-OrdinaryReviewPrDomain($Row) {
  if (-not (Test-JsonProperty $Row "pr")) {
    return [pscustomobject][ordered]@{ state = "ambiguous"; value = $null }
  }
  $value = $Row.pr
  if ($value -isnot [byte] -and
      $value -isnot [int16] -and
      $value -isnot [int32] -and
      $value -isnot [int64] -and
      $value -isnot [uint16] -and
      $value -isnot [uint32] -and
      $value -isnot [uint64]) {
    return [pscustomobject][ordered]@{ state = "ambiguous"; value = $null }
  }
  try { $numeric = [int64]$value } catch {
    return [pscustomobject][ordered]@{ state = "ambiguous"; value = $null }
  }
  # Requested PRs are Int32 identities. Values outside that representation are
  # overflow uncertainty, not a domain-separated non-PR identity.
  if ($numeric -lt [int]::MinValue -or $numeric -gt [int]::MaxValue) {
    return [pscustomobject][ordered]@{ state = "ambiguous"; value = $null }
  }
  if ($numeric -lt 1) {
    return [pscustomobject][ordered]@{ state = "explicit-non-pr"; value = $numeric }
  }
  return [pscustomobject][ordered]@{ state = "positive"; value = $numeric }
}

function Test-LegacyNonPrReviewIdentity($Row) {
  # Before exact-head receipts existed, review-complete rows identified an
  # issue but claimed neither a PR nor any exact-head receipt identity. Field
  # presence is the domain boundary; dates, prose, lanes, and model aliases
  # are deliberately irrelevant.
  return (
    (Test-JsonProperty $Row "issue") -and
    (Test-WholeNumber $Row.issue 1) -and
    [int64]$Row.issue -le [int]::MaxValue -and
    -not (Test-JsonProperty $Row "pr") -and
    -not (Test-JsonProperty $Row "receiptSchema") -and
    -not (Test-JsonProperty $Row "reviewedHead") -and
    -not (Test-JsonProperty $Row "reviewerAttempt") -and
    -not (Test-JsonProperty $Row "authorAttempt") -and
    -not (Test-JsonProperty $Row "reviewAuthority") -and
    -not (Test-JsonProperty $Row "controllerHead") -and
    -not (Test-JsonProperty $Row "controllerReviewSchema") -and
    -not (Test-JsonProperty $Row "planningContract") -and
    (-not (Test-JsonProperty $Row "laneRole") -or [string]$Row.laneRole -cne "planning")
  )
}

function Test-PlanningReviewReceiptIdentity($Row) {
  # Planning reviews use reviewedHead as source provenance, not PR authority.
  # Keep the domains disjoint on structured fields so an ordinary receipt
  # cannot escape fail-closed validation merely by adding planning labels.
  return (
    (Test-JsonProperty $Row "laneRole") -and
    [string]$Row.laneRole -ceq "planning" -and
    (Test-JsonProperty $Row "planningContract") -and
    [string]$Row.planningContract -ceq "planning-repair/v1" -and
    -not (Test-JsonProperty $Row "pr") -and
    -not (Test-JsonProperty $Row "receiptSchema") -and
    -not (Test-JsonProperty $Row "reviewContract") -and
    -not (Test-JsonProperty $Row "controllerHead") -and
    -not (Test-JsonProperty $Row "controllerReviewSchema") -and
    -not (Test-JsonProperty $Row "reviewAuthority")
  )
}

function ConvertTo-ReviewInstant([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
  $parsed = [datetimeoffset]::MinValue
  if (-not [datetimeoffset]::TryParse(
      $Value,
      [Globalization.CultureInfo]::InvariantCulture,
      [Globalization.DateTimeStyles]::RoundtripKind,
      [ref]$parsed
    )) {
    return $null
  }
  return $parsed.ToUniversalTime()
}

function Test-AttemptIdentity([string]$Value) {
  return -not [string]::IsNullOrWhiteSpace($Value) -and
    $Value -cmatch "^[A-Za-z0-9][A-Za-z0-9._:/-]{0,255}$"
}

function Get-ReviewReceiptValidation($Row, [object]$Vocabulary = $null) {
  if ($null -eq $Vocabulary) { $Vocabulary = Get-ReviewRecordVocabulary }
  $errors = [Collections.Generic.List[string]]::new()
  $required = @(
    "ts", "kind", "pr", "receiptSchema", "reviewedHead",
    "reviewerAttempt", "authorAttempt", "reviewContract", "completeSweep",
    "outcome", "model", "authorModel", "findingIds", "findings"
  )
  foreach ($field in $required) {
    if (-not (Test-JsonProperty $Row $field)) { $errors.Add("MISSING_$($field.ToUpperInvariant())") }
  }

  $instant = if (Test-JsonProperty $Row "ts") { ConvertTo-ReviewInstant ([string]$Row.ts) } else { $null }
  if ($null -eq $instant) { $errors.Add("INVALID_TS") }
  if ((Test-JsonProperty $Row "kind") -and [string]$Row.kind -cne "review-complete") {
    $errors.Add("INVALID_KIND")
  }
  if ((Test-JsonProperty $Row "receiptSchema") -and
      [string]$Row.receiptSchema -cne $script:ReviewReceiptSchema) {
    $errors.Add("UNSUPPORTED_RECEIPT_SCHEMA")
  }
  if ((Test-JsonProperty $Row "pr") -and
      (-not (Test-WholeNumber $Row.pr 1) -or [int64]$Row.pr -gt [int]::MaxValue)) {
    $errors.Add("INVALID_PR")
  }
  if ((Test-JsonProperty $Row "reviewedHead") -and
      [string]$Row.reviewedHead -cnotmatch "^[a-f0-9]{40}$") {
    $errors.Add("INVALID_REVIEWED_HEAD")
  }

  $reviewerAttempt = if (Test-JsonProperty $Row "reviewerAttempt") { [string]$Row.reviewerAttempt } else { "" }
  $authorAttempt = if (Test-JsonProperty $Row "authorAttempt") { [string]$Row.authorAttempt } else { "" }
  if (-not (Test-AttemptIdentity $reviewerAttempt)) { $errors.Add("INVALID_REVIEWER_ATTEMPT") }
  if (-not (Test-AttemptIdentity $authorAttempt)) { $errors.Add("INVALID_AUTHOR_ATTEMPT") }
  if ((Test-AttemptIdentity $reviewerAttempt) -and
      (Test-AttemptIdentity $authorAttempt) -and
      [string]::Equals($reviewerAttempt, $authorAttempt, [StringComparison]::OrdinalIgnoreCase)) {
    $errors.Add("ATTEMPT_IDENTITIES_NOT_INDEPENDENT")
  }

  if ((Test-JsonProperty $Row "reviewContract") -and
      [string]$Row.reviewContract -cne "review-contract/v2") {
    $errors.Add("INVALID_REVIEW_CONTRACT")
  }
  if ((Test-JsonProperty $Row "completeSweep") -and
      ($Row.completeSweep -isnot [bool] -or $Row.completeSweep -ne $true)) {
    $errors.Add("INCOMPLETE_SWEEP")
  }
  if ((Test-JsonProperty $Row "outcome") -and
      [string]$Row.outcome -cnotin $script:TerminalReviewOutcomes) {
    $errors.Add("INVALID_TERMINAL_DISPOSITION")
  }
  foreach ($modelField in @("model", "authorModel")) {
    if ((Test-JsonProperty $Row $modelField) -and
       [string]$Row.$modelField -cnotin (Get-ReviewSelectableModels $Vocabulary)) {
      $errors.Add("INVALID_$($modelField.ToUpperInvariant())")
    }
  }
  foreach ($effortField in @('effort','authorEffort')) {
    if ((Test-JsonProperty $Row $effortField) -and [string]$Row.$effortField -cnotin $Vocabulary.efforts) {
      $errors.Add("INVALID_$($effortField.ToUpperInvariant())")
    }
  }

  $ids = @()
  if (Test-JsonProperty $Row "findingIds") {
    $findingIdsProperty = $Row.PSObject.Properties["findingIds"]
    if ([object]::ReferenceEquals($null, $findingIdsProperty.Value) -or
        $findingIdsProperty.Value -isnot [array]) {
      $errors.Add("INVALID_FINDING_IDS")
    } else {
      $ids = @($findingIdsProperty.Value)
      if (@($ids | Where-Object { [string]$_ -cnotmatch "^[A-Z][A-Z0-9._-]{0,63}$" }).Count -gt 0) {
        $errors.Add("INVALID_FINDING_ID")
      }
      if (@($ids | Sort-Object -Unique).Count -ne $ids.Count) {
        $errors.Add("DUPLICATE_FINDING_ID")
      }
    }
  }

  $blocking = $null
  if (Test-JsonProperty $Row "findings") {
    foreach ($countField in @("blocking", "candidates", "nonBlocking")) {
      if (-not (Test-JsonProperty $Row.findings $countField)) {
        $errors.Add("MISSING_FINDINGS_$($countField.ToUpperInvariant())")
      } elseif (-not (Test-WholeNumber $Row.findings.$countField 0)) {
        $errors.Add("INVALID_FINDINGS_$($countField.ToUpperInvariant())")
      }
    }
    if (Test-JsonProperty $Row.findings "blocking") { $blocking = [int64]$Row.findings.blocking }
  }
  if ($null -ne $blocking -and $ids.Count -ne $blocking) {
    $errors.Add("FINDING_COUNT_MISMATCH")
  }
  if ((Test-JsonProperty $Row "outcome") -and $null -ne $blocking) {
    if ([string]$Row.outcome -in $script:BlockingReviewOutcomes -and $blocking -lt 1) {
      $errors.Add("BLOCK_WITHOUT_FINDING")
    }
    if ([string]$Row.outcome -notin $script:BlockingReviewOutcomes -and $blocking -ne 0) {
      $errors.Add("NONBLOCK_WITH_BLOCKING_FINDING")
    }
  }

  [pscustomobject][ordered]@{
    valid = $errors.Count -eq 0
    errors = @($errors)
    instant = $instant
  }
}

function Read-ExactHeadReviewHistory(
  [string]$Path,
  [int]$MaxRows = 50000,
  [long]$MaxBytes = 33554432
) {
  $audit = [ordered]@{
    pathStatus = "unknown"
    bytes = 0
    rows = 0
    parsedRows = 0
    malformedRows = 0
    truncated = $false
    malformedLineNumbers = @()
  }
  $rows = [Collections.Generic.List[object]]::new()
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    $audit.pathStatus = "missing"
    return [pscustomobject][ordered]@{ complete = $false; rows = @(); audit = $audit; reason = "HISTORY_MISSING" }
  }
  try {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $audit.bytes = [int64]$item.Length
    if ($item.Length -gt $MaxBytes) {
      $audit.pathStatus = "oversize"
      $audit.truncated = $true
      return [pscustomobject][ordered]@{ complete = $false; rows = @(); audit = $audit; reason = "HISTORY_TRUNCATED" }
    }
    $lineNumber = 0
    $reader = [IO.File]::OpenText($item.FullName)
    try { while ($null -ne ($line = $reader.ReadLine())) {
      $lineNumber += 1
      if ($lineNumber -gt $MaxRows) {
        $audit.truncated = $true
        break
      }
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      $audit.rows += 1
      try {
        # ConvertFrom-Json resolves duplicate names last-wins. Inspect decoded
        # names in the raw row first so normalization cannot create authority.
        $options = [System.Text.Json.JsonDocumentOptions]::new()
        $options.MaxDepth = 1024
        $document = [System.Text.Json.JsonDocument]::Parse($line, $options)
        try {
          $pending = [Collections.Generic.Stack[System.Text.Json.JsonElement]]::new()
          $pending.Push($document.RootElement)
          while ($pending.Count -gt 0) {
            $element = $pending.Pop()
            if ($element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
              $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
              foreach ($property in $element.EnumerateObject()) {
                if (-not $names.Add($property.Name)) { throw 'Duplicate decoded JSON property name' }
                $pending.Push($property.Value)
              }
            } elseif ($element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
              foreach ($item in $element.EnumerateArray()) { $pending.Push($item) }
            }
          }
        } finally { $document.Dispose() }
        $row = $line | ConvertFrom-Json -DateKind String -ErrorAction Stop
        $rawBytes = [Text.UTF8Encoding]::new($false).GetBytes($line)
        $rows.Add([pscustomobject][ordered]@{
          line = $lineNumber
          raw = $line
          byteLength = $rawBytes.Length
          rawSha256 = ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($rawBytes))).ToLowerInvariant()
          value = $row
        })
        $audit.parsedRows += 1
      } catch {
        $audit.malformedRows += 1
        $audit.malformedLineNumbers += $lineNumber
      }
    }
    } finally { $reader.Dispose() }
    $audit.pathStatus = if ($audit.truncated) { "truncated" } elseif ($audit.malformedRows) { "malformed" } else { "ok" }
  } catch {
    $audit.pathStatus = "unreadable"
    return [pscustomobject][ordered]@{ complete = $false; rows = @(); audit = $audit; reason = "HISTORY_UNREADABLE" }
  }
  if ($audit.truncated) {
    return [pscustomobject][ordered]@{ complete = $false; rows = @($rows); audit = $audit; reason = "HISTORY_TRUNCATED" }
  }
  if ($audit.malformedRows -gt 0) {
    return [pscustomobject][ordered]@{ complete = $false; rows = @($rows); audit = $audit; reason = "HISTORY_MALFORMED" }
  }
  [pscustomobject][ordered]@{ complete = $true; rows = @($rows); audit = $audit; reason = "HISTORY_COMPLETE" }
}

function Test-LandedIntegrationAuthorityRow($Row) {
  $required = @('ts','kind','integrationAuthoritySchema','pr','issue','targetBranch','lineageRoot','targetHead','authorityState','authorityIssue','authorityCommentId','operatorAuthority')
  $names = @($Row.PSObject.Properties.Name)
  if (@($required | Where-Object { $_ -cnotin $names }).Count -or
      @($names | Where-Object { $_ -cnotin ($required + @('supersedes','note')) }).Count) { return $false }
  if ($Row.kind -cne 'rule-change' -or $Row.integrationAuthoritySchema -cne 'landed-integration-authority/v1' -or
      (Get-OrdinaryReviewPrDomain $Row).state -cne 'positive' -or
      -not (Test-WholeNumber $Row.issue 1) -or $Row.issue -gt [int]::MaxValue) { return $false }
  foreach ($key in @('targetBranch','lineageRoot')) {
    if ($Row.$key -isnot [string] -or $Row.$key -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}$') { return $false }
  }
  if ($Row.ts -isnot [string] -or $Row.ts -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,7})?(Z|[+-]\d{2}:\d{2})$' -or $null -eq (ConvertTo-ReviewInstant $Row.ts) -or
      $Row.targetHead -isnot [string] -or $Row.targetHead -cnotmatch '^[a-f0-9]{40}$' -or
      $Row.authorityState -cnotin @('STOP','ELIGIBLE','RELEASE')) { return $false }
  $pair = $null -ne $Row.authorityIssue -or $null -ne $Row.authorityCommentId
  if ($pair) {
    if (-not (Test-WholeNumber $Row.authorityIssue 1) -or $Row.authorityIssue -gt [int]::MaxValue -or
        -not (Test-WholeNumber $Row.authorityCommentId 1) -or $Row.operatorAuthority -isnot [string] -or
        $Row.operatorAuthority -cne "Todd:$($Row.authorityIssue)#$($Row.authorityCommentId)") { return $false }
  } elseif ($Row.authorityState -cne 'ELIGIBLE' -or $null -ne $Row.operatorAuthority) { return $false }
  if ($Row.authorityState -ceq 'RELEASE') {
    if ($Row.supersedes -isnot [string] -or $Row.supersedes -cnotmatch '^[a-f0-9]{64}$') { return $false }
  } elseif (Test-JsonProperty $Row 'supersedes') { return $false }
  if ((Test-JsonProperty $Row 'note') -and $Row.note -isnot [string]) { return $false }
  return $true
}

function Reduce-LandedIntegrationAuthority($History, [int]$Pr, [string]$Branch, [string]$Head) {
  $result = [ordered]@{ state='UNKNOWN'; reason='NO_EXACT_HEAD_ELIGIBLE'; globalUnknown=$false; authorityRows=@() }
  if (-not $History.complete) {
    $result.reason = [string]$History.reason
    $result.globalUnknown = $History.reason -cne 'HISTORY_MISSING'
    return [pscustomobject]$result
  }
  $target = [Collections.Generic.List[object]]::new()
  foreach ($entry in $History.rows) {
    $row = $entry.value
    $claimsAuthority = @('integrationAuthoritySchema','authorityState','authorityIssue','authorityCommentId') |
      Where-Object { Test-JsonProperty $row $_ }
    if (-not $claimsAuthority) { continue }
    if ((Get-OrdinaryReviewPrDomain $row).state -cne 'positive' -or
        $row.targetBranch -isnot [string] -or $row.targetBranch -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}$') {
      $result.globalUnknown=$true; $result.reason='CENSUS_UNKNOWN_AUTHORITY_ROW'
      $result.authorityRows=@($entry.rawSha256); return [pscustomobject]$result
    }
    if ($row.pr -eq $Pr -and $row.targetBranch -ceq $Branch) { $target.Add($entry) }
  }
  $result.authorityRows = @($target | ForEach-Object { $_.rawSha256 })
  if (@($target | Where-Object { -not (Test-LandedIntegrationAuthorityRow $_.value) }).Count) {
    $result.reason='CENSUS_UNKNOWN_AUTHORITY_ROW'; return [pscustomobject]$result
  }
  $stops = @($target | Where-Object { $_.value.authorityState -ceq 'STOP' })
  $stopsByHash = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
  foreach ($stop in $stops) {
    if (-not $stopsByHash.ContainsKey($stop.rawSha256)) { $stopsByHash[$stop.rawSha256]=[Collections.Generic.List[object]]::new() }
    $stopsByHash[$stop.rawSha256].Add($stop)
  }
  $released = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($release in @($target | Where-Object { $_.value.authorityState -ceq 'RELEASE' })) {
    $matches = $stopsByHash[$release.value.supersedes]
    if ($matches.Count -ne 1 -or $matches[0].line -ge $release.line -or -not $released.Add($release.value.supersedes)) {
      $result.reason='CENSUS_UNKNOWN_AUTHORITY_ROW'; return [pscustomobject]$result
    }
  }
  $active = @($stops | Where-Object { -not $released.Contains($_.rawSha256) })
  if ($active.Count) {
    $result.state='STOP'; $result.reason='TERMINAL_AUTHORITY_STOP'
    $result.authorityRows=@($active | ForEach-Object { $_.rawSha256 }); return [pscustomobject]$result
  }
  $lastTransition = 0
  foreach ($entry in $target) {
    if ($entry.value.authorityState -cin @('STOP','RELEASE')) { $lastTransition = [math]::Max($lastTransition, $entry.line) }
  }
  $eligible = @($target | Where-Object { $_.value.authorityState -ceq 'ELIGIBLE' -and $_.line -gt $lastTransition } | Sort-Object line -Descending)
  if ($eligible.Count -and $eligible[0].value.targetHead -ceq $Head) {
    $result.state='ELIGIBLE'; $result.reason='EXACT_HEAD_ELIGIBLE'; $result.authorityRows=@($eligible[0].rawSha256)
  }
  return [pscustomobject]$result
}

function Get-ReceiptFingerprint($Row) {
  $canonical = [ordered]@{
    ts = [string]$Row.ts
    pr = [int64]$Row.pr
    receiptSchema = [string]$Row.receiptSchema
    reviewedHead = [string]$Row.reviewedHead
    reviewerAttempt = [string]$Row.reviewerAttempt
    authorAttempt = [string]$Row.authorAttempt
    reviewContract = [string]$Row.reviewContract
    completeSweep = [bool]$Row.completeSweep
    outcome = [string]$Row.outcome
    model = [string]$Row.model
    authorModel = [string]$Row.authorModel
    findingIds = @($Row.findingIds | ForEach-Object { [string]$_ })
    findings = [ordered]@{
      blocking = [int64]$Row.findings.blocking
      candidates = [int64]$Row.findings.candidates
      nonBlocking = [int64]$Row.findings.nonBlocking
    }
  }
  $bytes = [Text.Encoding]::UTF8.GetBytes(($canonical | ConvertTo-Json -Compress -Depth 5))
  [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Get-RebaseOnlyContinuationValidation($Row) {
  $errors = [Collections.Generic.List[string]]::new()
  $expected = @(
    "ts", "kind", "continuationSchema", "pr", "reviewedHead", "newHead",
    "predecessorHead", "newBase", "sourcePassReceiptIdentity", "integrationLane", "reviewedBase",
    "patchPairs", "rangeDiff", "conflictResolution"
  )
  $actual = @($Row.PSObject.Properties.Name)
  if ($actual.Count -ne $expected.Count -or @($expected | Where-Object { $_ -cnotin $actual }).Count -gt 0) {
    $errors.Add("ROW_SHAPE_NOT_CLOSED")
  }
  $instant = if (Test-JsonProperty $Row "ts") { ConvertTo-ReviewInstant ([string]$Row.ts) } else { $null }
  if ($null -eq $instant) { $errors.Add("INVALID_TS") }
  if ([string]$Row.kind -cne "repair-complete") { $errors.Add("INVALID_KIND") }
  if ([string]$Row.continuationSchema -cne "rebase-only-continuation/v1") { $errors.Add("UNSUPPORTED_CONTINUATION_SCHEMA") }
  if (-not (Test-WholeNumber $Row.pr 1) -or [int64]$Row.pr -gt [int]::MaxValue) { $errors.Add("INVALID_PR") }
  foreach ($field in @("reviewedHead", "predecessorHead", "newHead", "newBase", "reviewedBase")) {
    if ([string]$Row.$field -cnotmatch '^[a-f0-9]{40}$') { $errors.Add("INVALID_$($field.ToUpperInvariant())") }
  }
  if ([string]$Row.predecessorHead -ceq [string]$Row.newHead -or
      [string]$Row.newBase -ceq [string]$Row.newHead) { $errors.Add("INVALID_REBASE_IDENTITY") }
  if ([string]$Row.sourcePassReceiptIdentity -cnotmatch '^[a-f0-9]{64}$') { $errors.Add("INVALID_SOURCE_PASS_IDENTITY") }
  if ([string]$Row.integrationLane -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$') { $errors.Add("INVALID_INTEGRATION_LANE") }
  if ([string]$Row.rangeDiff -cne "semantic-patch-equivalent") { $errors.Add("PATCH_RANGE_NOT_EQUIVALENT") }
  if ($Row.conflictResolution -isnot [bool] -or $Row.conflictResolution -ne $false) { $errors.Add("CONFLICT_RESOLUTION_REQUIRES_DELTA") }
  if ($Row.patchPairs -isnot [array] -or @($Row.patchPairs).Count -lt 1) {
    $errors.Add("PATCH_PAIRS_EMPTY_OR_INVALID")
  } else {
    $reviewedCommits = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $newCommits = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($pair in @($Row.patchPairs)) {
      $pairKeys = @($pair.PSObject.Properties.Name)
      $requiredPairKeys = @("reviewedCommit","newCommit","reviewedPatchId","newPatchId")
      if ($pairKeys.Count -ne 4 -or @($requiredPairKeys | Where-Object { $_ -cnotin $pairKeys }).Count -gt 0) {
        $errors.Add("PATCH_PAIR_SHAPE_NOT_CLOSED")
        continue
      }
      foreach ($field in @("reviewedCommit","newCommit","reviewedPatchId","newPatchId")) {
        if ([string]$pair.$field -cnotmatch '^[a-f0-9]{40}$') { $errors.Add("INVALID_PATCH_PAIR_$($field.ToUpperInvariant())") }
      }
      if ([string]$pair.reviewedPatchId -cne [string]$pair.newPatchId) { $errors.Add("PATCH_ID_CHANGED") }
      if (-not $reviewedCommits.Add([string]$pair.reviewedCommit) -or -not $newCommits.Add([string]$pair.newCommit)) {
        $errors.Add("DUPLICATE_PATCH_COMMIT")
      }
    }
  }
  [pscustomobject][ordered]@{ valid=$errors.Count -eq 0; errors=@($errors); instant=$instant }
}

function New-ReviewReduction(
  [string]$State,
  [string]$Reason,
  [int]$Pr,
  [string]$CurrentHead,
  $Latest,
  $Audit
) {
  [pscustomobject][ordered]@{
    schema = $script:ReviewReducerSchema
    state = $State
    reason = $Reason
    pr = $Pr
    currentHead = $CurrentHead
    latest = $Latest
    audit = $Audit
  }
}

function Reduce-ExactHeadReview(
  [int]$Pr,
  [string]$CurrentHead,
  $History
) {
  if ($Pr -lt 1) {
    return New-ReviewReduction "unknown" "INVALID_REQUEST_PR" $Pr $CurrentHead $null $History.audit
  }
  if ($CurrentHead -cnotmatch "^[a-f0-9]{40}$") {
    return New-ReviewReduction "unknown" "INVALID_CURRENT_HEAD" $Pr $CurrentHead $null $History.audit
  }
  if (-not $History.complete) {
    return New-ReviewReduction "unknown" $History.reason $Pr $CurrentHead $null $History.audit
  }

  $recordVocabulary = Get-ReviewRecordVocabulary
  $valid = [Collections.Generic.List[object]]::new()
  $uncertain = [Collections.Generic.List[object]]::new()
  $malformedExact = [Collections.Generic.List[object]]::new()
  $quarantinedNonPr = [Collections.Generic.List[object]]::new()
  $quarantinedNonPrCount = 0
  $quarantinedOtherPr = [Collections.Generic.List[object]]::new()
  $quarantinedOtherPrCount = 0
  $maxQuarantineDetails = 64
  $controllerReceipts = 0
  $planningReceiptCount = 0
  $planningReceipts = [Collections.Generic.List[object]]::new()
  $legacyReceipts = 0
  $continuations = [Collections.Generic.List[object]]::new()
  $malformedContinuations = [Collections.Generic.List[object]]::new()
  foreach ($entry in @($History.rows)) {
    $row = $entry.value
    $claimsContinuation = (Test-JsonProperty $row "continuationSchema") -or
      ((Test-JsonProperty $row "kind") -and [string]$row.kind -ceq "repair-complete" -and
        ((Test-JsonProperty $row "newHead") -or (Test-JsonProperty $row "sourcePassReceiptIdentity")))
    if ($claimsContinuation) {
      $prDomain = Get-OrdinaryReviewPrDomain $row
      if ($prDomain.state -ceq "explicit-non-pr") {
        $quarantinedNonPrCount += 1
        continue
      }
      if ($prDomain.state -ceq "ambiguous") {
        $uncertain.Add([pscustomobject][ordered]@{line=$entry.line;instant=$null;errors=@("AMBIGUOUS_CONTINUATION_PR_IDENTITY")})
        continue
      }
      if ([int64]$prDomain.value -ne $Pr) {
        $quarantinedOtherPrCount += 1
        continue
      }
      $validation = Get-RebaseOnlyContinuationValidation $row
      $candidate = [pscustomobject][ordered]@{
        line=$entry.line; instant=$validation.instant; row=$row; fingerprint=[string]$entry.rawSha256
      }
      if ($validation.valid) { $continuations.Add($candidate) }
      else {
        $candidate | Add-Member -NotePropertyName errors -NotePropertyValue @($validation.errors)
        $malformedContinuations.Add($candidate)
      }
      continue
    }
    if (-not (Test-JsonProperty $row "kind") -or [string]$row.kind -cne "review-complete") { continue }
    if (Test-JsonProperty $row "controllerHead") {
      $controllerReceipts += 1
      continue
    }
    if (Test-PlanningReviewReceiptIdentity $row) {
      $planningReceiptCount += 1
      if ($planningReceipts.Count -lt $maxQuarantineDetails) {
        $planningReceipts.Add([pscustomobject][ordered]@{
          line = $entry.line
          issue = if (Test-JsonProperty $row "issue") { $row.issue } else { $null }
          reviewedHead = if (Test-JsonProperty $row "reviewedHead") { [string]$row.reviewedHead } else { $null }
          reason = "PLANNING_REPAIR_RECEIPT"
        })
      }
      continue
    }
    if (Test-LegacyNonPrReviewIdentity $row) {
      $quarantinedNonPrCount += 1
      if ($quarantinedNonPr.Count -lt $maxQuarantineDetails) {
        $quarantinedNonPr.Add([pscustomobject][ordered]@{
          line = $entry.line
          pr = $null
          reason = "LEGACY_NON_PR_NON_EXACT_HEAD_REVIEW"
        })
      }
      continue
    }
    $claimsPlanningReview =
      ((Test-JsonProperty $row "laneRole") -and [string]$row.laneRole -ceq "planning") -or
      (Test-JsonProperty $row "planningContract")
    $prDomain = Get-OrdinaryReviewPrDomain $row
    if ($prDomain.state -ceq "explicit-non-pr") {
      $quarantinedNonPrCount += 1
      if ($quarantinedNonPr.Count -lt $maxQuarantineDetails) {
        $quarantinedNonPr.Add([pscustomobject][ordered]@{
          line = $entry.line
          pr = [int64]$prDomain.value
          reason = "EXPLICIT_NON_POSITIVE_PR"
        })
      }
      continue
    }
    if ($prDomain.state -ceq "ambiguous" -and -not $claimsPlanningReview) {
      $uncertain.Add([pscustomobject][ordered]@{
        line = $entry.line
        instant = $null
        errors = @("AMBIGUOUS_PR_IDENTITY")
      })
      continue
    }
    # An incomplete planning identity that also carries exact-head fields is a
    # malformed authority claim, not an unrelated non-PR row. Keep #7759's
    # domain discriminator fail closed while ambiguous claimed exact-head rows
    # remain fail-closed uncertainty.
    $rowPr = if ($prDomain.state -ceq "ambiguous") { [int64]$Pr } else { [int64]$prDomain.value }
    if ($rowPr -ne $Pr) {
      $quarantinedOtherPrCount += 1
      if ($quarantinedOtherPr.Count -lt $maxQuarantineDetails) {
        $quarantinedOtherPr.Add([pscustomobject][ordered]@{ line=$entry.line; pr=$rowPr; reason="OTHER_POSITIVE_PR" })
      }
      continue
    }

    $validation = Get-ReviewReceiptValidation $row $recordVocabulary
    if (-not $validation.valid) {
      $invalidEntry = [pscustomobject][ordered]@{
        line = $entry.line
        instant = $validation.instant
        errors = @($validation.errors)
      }
      $claimsExactHeadSchema =
        (Test-JsonProperty $row "receiptSchema") -or
        (Test-JsonProperty $row "reviewedHead") -or
        (Test-JsonProperty $row "reviewerAttempt") -or
        (Test-JsonProperty $row "authorAttempt")
      if ($claimsExactHeadSchema) {
        $malformedExact.Add($invalidEntry)
      } else {
        $legacyReceipts += 1
        $uncertain.Add($invalidEntry)
      }
      continue
    }
    $valid.Add([pscustomobject][ordered]@{
      line = $entry.line
      instant = $validation.instant
      row = $row
      fingerprint = Get-ReceiptFingerprint $row
    })
  }

  $audit = [ordered]@{}
  foreach ($property in $History.audit.GetEnumerator()) { $audit[$property.Key] = $property.Value }
  $audit.controllerReceiptsIgnored = $controllerReceipts
  $audit.legacyOrInvalidRelevantReceipts = $legacyReceipts
  $audit.malformedExactHeadReceipts = $malformedExact.Count
  $audit.validRelevantReceipts = $valid.Count
  $audit.duplicateReceipts = 0
  $audit.validContinuations = $continuations.Count
  $audit.malformedContinuations = $malformedContinuations.Count
  $audit.uncertainReceipts = @($uncertain | ForEach-Object {
      [ordered]@{ line = $_.line; errors = @($_.errors) }
    })
  $audit.malformedExactHeadReceiptDetails = @($malformedExact | ForEach-Object {
      [ordered]@{ line = $_.line; errors = @($_.errors) }
    })
  if ($planningReceiptCount -gt 0) {
    $audit.planningReceiptsIgnored = $planningReceiptCount
    $audit.planningReceiptDetails = @($planningReceipts | ForEach-Object {
        [ordered]@{ line = $_.line; issue = $_.issue; reviewedHead = $_.reviewedHead; reason = $_.reason }
      })
    $audit.planningReceiptDetailsTruncated = $planningReceiptCount -gt $planningReceipts.Count
  }
  if ($quarantinedNonPrCount -gt 0) {
    $audit.quarantinedNonPrReceipts = $quarantinedNonPrCount
    $audit.quarantinedNonPrReceiptDetails = @($quarantinedNonPr | ForEach-Object {
        [ordered]@{ line = $_.line; pr = $(if ($null -eq $_.pr) { $null } else { [int64]$_.pr }); reason = $_.reason }
      })
    $audit.quarantinedNonPrReceiptDetailsTruncated = $quarantinedNonPrCount -gt $quarantinedNonPr.Count
  }
  if ($quarantinedOtherPrCount -gt 0) {
    $audit.quarantinedOtherPrReceipts = $quarantinedOtherPrCount
    $audit.quarantinedOtherPrReceiptDetails = @($quarantinedOtherPr | ForEach-Object {
        [ordered]@{ line=$_.line; pr=$_.pr; reason=$_.reason }
      })
    $audit.quarantinedOtherPrReceiptDetailsTruncated = $quarantinedOtherPrCount -gt $quarantinedOtherPr.Count
  }

  if ($malformedExact.Count -gt 0) {
    return New-ReviewReduction "unknown" "MALFORMED_EXACT_HEAD_RECEIPT" $Pr $CurrentHead $null $audit
  }
  if ($malformedContinuations.Count -gt 0) {
    $audit.malformedContinuationDetails = @($malformedContinuations | ForEach-Object { [ordered]@{line=$_.line;errors=@($_.errors)} })
    return New-ReviewReduction "unknown" "MALFORMED_REBASE_ONLY_CONTINUATION" $Pr $CurrentHead $null $audit
  }

  $deduplicated = [Collections.Generic.List[object]]::new()
  foreach ($group in @($valid | Group-Object fingerprint)) {
    $deduplicated.Add($group.Group[0])
    $audit.duplicateReceipts += $group.Count - 1
  }

  foreach ($attemptGroup in @($deduplicated | Group-Object { $_.row.reviewerAttempt })) {
    if ($attemptGroup.Count -gt 1) {
      return New-ReviewReduction "unknown" "CONTRADICTORY_ATTEMPT_RECEIPTS" $Pr $CurrentHead $null $audit
    }
  }

  $latestValidInstant = @($deduplicated | Sort-Object instant -Descending | Select-Object -First 1).instant
  $unboundedUncertainty = @($uncertain | Where-Object {
      $null -eq $_.instant -or $null -eq $latestValidInstant -or $_.instant -ge $latestValidInstant
    })
  if ($unboundedUncertainty.Count -gt 0) {
    $audit.uncertainLines = @($unboundedUncertainty | ForEach-Object { $_.line })
    return New-ReviewReduction "unknown" "RELEVANT_RECEIPT_UNVERIFIABLE" $Pr $CurrentHead $null $audit
  }

  if ($deduplicated.Count -eq 0) {
    $reason = if ($legacyReceipts -gt 0) { "LEGACY_RECEIPTS_ONLY" } else { "NO_REVIEW_HISTORY" }
    return New-ReviewReduction "unknown" $reason $Pr $CurrentHead $null $audit
  }

  $exact = @($deduplicated | Where-Object { [string]$_.row.reviewedHead -ceq $CurrentHead })
  if ($exact.Count -eq 0) {
    $deduplicatedContinuations = @($continuations | Group-Object fingerprint | ForEach-Object { $_.Group[0] })
    $currentContinuations = @($deduplicatedContinuations | Where-Object { [string]$_.row.newHead -ceq $CurrentHead })
    if ($currentContinuations.Count -eq 0) {
      return New-ReviewReduction "stale" "CURRENT_HEAD_HAS_NO_TERMINAL_REVIEW" $Pr $CurrentHead $null $audit
    }
    if ($currentContinuations.Count -ne 1) {
      return New-ReviewReduction "unknown" "CONTINUATION_AUTHORITY_AMBIGUOUS" $Pr $CurrentHead $null $audit
    }
    $continuation = $currentContinuations[0]
    $sourceHead = [string]$continuation.row.reviewedHead
    $sourceIdentity = [string]$continuation.row.sourcePassReceiptIdentity
    $sourceCandidates = @($deduplicated | Where-Object {
      [string]$_.row.reviewedHead -ceq $sourceHead
    })
    if ($sourceCandidates.Count -eq 0) {
      return New-ReviewReduction "unknown" "CONTINUATION_SOURCE_PASS_MISSING" $Pr $CurrentHead $null $audit
    }
    $sourceLatestInstant = ($sourceCandidates | Sort-Object instant -Descending | Select-Object -First 1).instant
    $sourceLatest = @($sourceCandidates | Where-Object { $_.instant.Ticks -eq $sourceLatestInstant.Ticks })
    if ($sourceLatest.Count -ne 1 -or [string]$sourceLatest[0].row.outcome -cne "PASS" -or
        [string]$sourceLatest[0].fingerprint -cne $sourceIdentity -or
        $continuation.instant -le $sourceLatest[0].instant) {
      return New-ReviewReduction "unknown" "CONTINUATION_SOURCE_PASS_UNQUALIFIED" $Pr $CurrentHead $null $audit
    }

    $sameSource = @($deduplicatedContinuations | Where-Object {
      [string]$_.row.reviewedHead -ceq $sourceHead -and
      [string]$_.row.sourcePassReceiptIdentity -ceq $sourceIdentity
    })
    foreach ($fork in @($sameSource | Group-Object { [string]$_.row.predecessorHead })) {
      if ($fork.Count -ne 1) {
        return New-ReviewReduction "unknown" "CONTINUATION_CHAIN_AMBIGUOUS" $Pr $CurrentHead $null $audit
      }
    }
    $chain = [Collections.Generic.List[object]]::new()
    $seenHeads = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $cursor = $CurrentHead
    while ($cursor -cne $sourceHead) {
      if (-not $seenHeads.Add($cursor)) {
        return New-ReviewReduction "unknown" "CONTINUATION_CHAIN_CYCLIC" $Pr $CurrentHead $null $audit
      }
      $hop = @($sameSource | Where-Object { [string]$_.row.newHead -ceq $cursor })
      if ($hop.Count -eq 0) {
        return New-ReviewReduction "unknown" "CONTINUATION_PREDECESSOR_MISSING" $Pr $CurrentHead $null $audit
      }
      if ($hop.Count -ne 1) {
        return New-ReviewReduction "unknown" "CONTINUATION_CHAIN_AMBIGUOUS" $Pr $CurrentHead $null $audit
      }
      $chain.Insert(0,$hop[0])
      $cursor = [string]$hop[0].row.predecessorHead
      if ($cursor -cnotmatch '^[a-f0-9]{40}$') {
        return New-ReviewReduction "unknown" "CONTINUATION_PREDECESSOR_INVALID" $Pr $CurrentHead $null $audit
      }
    }
    $priorInstant = $sourceLatest[0].instant
    $priorPatchIds = $null
    foreach ($hop in @($chain)) {
      if ($hop.instant -le $priorInstant) {
        return New-ReviewReduction "unknown" "CONTINUATION_CHAIN_ORDER_INVALID" $Pr $CurrentHead $null $audit
      }
      $reviewedPatchIds = @($hop.row.patchPairs | ForEach-Object { [string]$_.reviewedPatchId })
      $newPatchIds = @($hop.row.patchPairs | ForEach-Object { [string]$_.newPatchId })
      if ($null -ne $priorPatchIds -and
          ($reviewedPatchIds.Count -ne $priorPatchIds.Count -or
           (Compare-Object -ReferenceObject $priorPatchIds -DifferenceObject $reviewedPatchIds -SyncWindow 0).Count -ne 0)) {
        return New-ReviewReduction "unknown" "CONTINUATION_CHAIN_PATCH_CHANGED" $Pr $CurrentHead $null $audit
      }
      $priorPatchIds = $newPatchIds
      $priorInstant = $hop.instant
    }
    $latestSummary = [ordered]@{
      ts = [string]$continuation.row.ts
      reviewedHead = [string]$sourceLatest[0].row.reviewedHead
      authorizedHead = $CurrentHead
      outcome = "PASS"
      reviewerAttempt = [string]$sourceLatest[0].row.reviewerAttempt
      authorAttempt = [string]$sourceLatest[0].row.authorAttempt
      model = [string]$sourceLatest[0].row.model
      authorModel = [string]$sourceLatest[0].row.authorModel
      receiptIdentity = [string]$sourceLatest[0].fingerprint
      authorityKind = "rebase-only-continuation"
      continuationIdentity = [string]$continuation.fingerprint
      continuationHops = $chain.Count
      predecessorHead = [string]$continuation.row.predecessorHead
      integrationLane = [string]$continuation.row.integrationLane
      newBase = [string]$continuation.row.newBase
    }
    return New-ReviewReduction "authorized" "QUALIFIED_REBASE_ONLY_CONTINUATION" $Pr $CurrentHead $latestSummary $audit
  }

  $latestInstant = ($exact | Sort-Object instant -Descending | Select-Object -First 1).instant
  $atLatestInstant = @($exact | Where-Object { $_.instant.Ticks -eq $latestInstant.Ticks })
  $latestOutcomes = @($atLatestInstant | ForEach-Object { [string]$_.row.outcome } | Sort-Object -Unique)
  if ($latestOutcomes.Count -gt 1) {
    return New-ReviewReduction "unknown" "TERMINAL_ORDER_AMBIGUOUS" $Pr $CurrentHead $null $audit
  }
  $latest = $atLatestInstant | Sort-Object fingerprint | Select-Object -First 1
  $latestSummary = [ordered]@{
    ts = [string]$latest.row.ts
    reviewedHead = [string]$latest.row.reviewedHead
    outcome = [string]$latest.row.outcome
    reviewerAttempt = [string]$latest.row.reviewerAttempt
    authorAttempt = [string]$latest.row.authorAttempt
    model = [string]$latest.row.model
    authorModel = [string]$latest.row.authorModel
    receiptIdentity = [string]$latest.fingerprint
  }
  switch ([string]$latest.row.outcome) {
    "PASS" { return New-ReviewReduction "authorized" "LATEST_EXACT_HEAD_PASS" $Pr $CurrentHead $latestSummary $audit }
    "BLOCK_FIXABLE" { return New-ReviewReduction "blocked" "LATEST_EXACT_HEAD_BLOCK_FIXABLE" $Pr $CurrentHead $latestSummary $audit }
    "BLOCK_REPLAN" { return New-ReviewReduction "blocked" "LATEST_EXACT_HEAD_BLOCK_REPLAN" $Pr $CurrentHead $latestSummary $audit }
    "SKIP" { return New-ReviewReduction "blocked" "LATEST_EXACT_HEAD_SKIP" $Pr $CurrentHead $latestSummary $audit }
    default { return New-ReviewReduction "unknown" "LATEST_TERMINAL_UNRECOGNIZED" $Pr $CurrentHead $latestSummary $audit }
  }
}

function Test-ControllerClosedKeys($Value, [string[]]$Expected) {
  if ($null -eq $Value -or $Value -is [string]) { return $false }
  $actual = @($Value.PSObject.Properties.Name)
  if ($actual.Count -ne $Expected.Count) { return $false }
  foreach ($name in $Expected) { if ($name -cnotin $actual) { return $false } }
  return $true
}

function Test-ControllerUtcInstant($Value) {
  if ($Value -isnot [string] -or $Value -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$') { return $false }
  $parsed = [datetimeoffset]::MinValue
  return [datetimeoffset]::TryParseExact(
    $Value,
    "yyyy-MM-dd'T'HH:mm:ss.fff'Z'",
    [cultureinfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::AssumeUniversal,
    [ref]$parsed
  ) -and $parsed.Offset -eq [timespan]::Zero
}

function Get-ControllerReviewRowClassification($Entry, [object]$Vocabulary = $null) {
   if ($null -eq $Vocabulary) { $Vocabulary = Get-ReviewRecordVocabulary }
  $row = if (Test-JsonProperty $Entry "value") { $Entry.value } else { $Entry }
  $line = if (Test-JsonProperty $Entry "line") { [int]$Entry.line } else { 0 }
  $rawSha = if (Test-JsonProperty $Entry "rawSha256") { [string]$Entry.rawSha256 } else {
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($row | ConvertTo-Json -Compress -Depth 20))
    ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))).ToLowerInvariant()
  }
  $errors = [Collections.Generic.List[string]]::new(); $correctionVariant = $null
  $schema = if (Test-JsonProperty $row "controllerReviewSchema") { [string]$row.controllerReviewSchema } else { "" }
  $kind = if (Test-JsonProperty $row "kind") { [string]$row.kind } else { "" }
  $strictSchemas = @(
    $script:ControllerDispatchSchemaV1, $script:ControllerReceiptSchemaV1, $script:ControllerCorrectionSchema,
    $script:ControllerDispatchSchemaV2, $script:ControllerReceiptSchemaV2
  )
  $claimsStrict = Test-JsonProperty $row "controllerReviewSchema"
  $claimsLegacy = -not $claimsStrict -and (Test-JsonProperty $row "controllerHead") -and $kind -in @("dispatch", "review-complete")
  $rowKind = if ($claimsStrict) {
    if ($schema -ceq $script:ControllerCorrectionSchema) { "correction" }
    elseif ($schema -in @($script:ControllerDispatchSchemaV1, $script:ControllerDispatchSchemaV2) -or $kind -ceq "dispatch") { "dispatch" }
    elseif ($schema -in @($script:ControllerReceiptSchemaV1, $script:ControllerReceiptSchemaV2) -or $kind -ceq "review-complete") { "receipt" }
    else { "strict-unknown" }
  } elseif ($claimsLegacy) { "legacy" } else { "other" }
  $version = if ($schema -in @($script:ControllerDispatchSchemaV2, $script:ControllerReceiptSchemaV2)) { "v2" } elseif ($schema -in @($script:ControllerDispatchSchemaV1, $script:ControllerReceiptSchemaV1, $script:ControllerCorrectionSchema)) { "v1" } elseif ($claimsLegacy) { "legacy" } else { "none" }

  if ($claimsStrict) {
    if ($schema -cnotin $strictSchemas) { $errors.Add("UNSUPPORTED_CONTROLLER_REVIEW_SCHEMA") }
    $baseKeys = @(
      "ts","kind","controllerReviewSchema","issue","controllerHead","authorAttempt","reviewerAttempt",
      "reviewAuthority","lane","transcript","reviewerModel","authorModel","effort","row","placement","harness"
    )
    if ($version -ceq "v2") { $baseKeys += "stage" }
    $expected = @($baseKeys)
    $routingKeys = @('policyGeneration','registryAuthorityDigest','family','slot','usedLastKnownGood')
    $routingPresent = @($routingKeys | Where-Object { Test-JsonProperty $row $_ })
    if ($routingPresent.Count -gt 0) {
      if ($routingPresent.Count -ne $routingKeys.Count) { $errors.Add('ROUTING_EVIDENCE_INVALID') }
      $expected += $routingKeys
    }
    if ($version -ceq 'v2' -and $routingPresent.Count -ne $routingKeys.Count) { $errors.Add('ROUTING_EVIDENCE_REQUIRED_FOR_V2') }
    if ($rowKind -ceq "receipt") { $expected += @("reviewContract","completeSweep","outcome","findingIds","findings") }
    $observedKeys = @('observedStartAt','observedEndAt','observedEvidence')
    $observedPresent = @($observedKeys | Where-Object { Test-JsonProperty $row $_ })
    if ($observedPresent.Count) {
      $expected += $observedPresent
      try { Assert-ObservedLaneFields $row ([datetime]::UtcNow) }
      catch { $errors.Add(($_.Exception.Message -split ':',2)[0]) }
    }
    if ($rowKind -ceq "correction") { $correctionVariant = if (Test-JsonProperty $row "originalTerminalRawSha256") { "pair" } else { "dispatch-only" }; $expected += @("originalDispatchRawSha256","operatorAuthority"); if ($correctionVariant -ceq "pair") { $expected += "originalTerminalRawSha256" } }
    if (-not (Test-ControllerClosedKeys $row $expected)) { $errors.Add("ROW_SHAPE_NOT_CLOSED") }
    if ($rowKind -ceq "strict-unknown" -or $kind -cne $(if ($rowKind -ceq "correction") { "controller-review-audit-correction" } elseif ($rowKind -ceq "dispatch") { "dispatch" } else { "review-complete" })) { $errors.Add("KIND_SCHEMA_MISMATCH") }
    if (-not (Test-ControllerUtcInstant $row.ts)) { $errors.Add("INVALID_TS") }
    if (-not (Test-WholeNumber $row.issue 1) -or [int64]$row.issue -gt [int]::MaxValue) { $errors.Add("INVALID_ISSUE") }
    if ([string]$row.controllerHead -cnotmatch '^[a-f0-9]{40}$') { $errors.Add("INVALID_CONTROLLER_HEAD") }
    if (-not (Test-AttemptIdentity ([string]$row.authorAttempt))) { $errors.Add("INVALID_AUTHOR_ATTEMPT") }
    if (-not (Test-AttemptIdentity ([string]$row.reviewerAttempt))) { $errors.Add("INVALID_REVIEWER_ATTEMPT") }
    if ([string]::Equals([string]$row.authorAttempt, [string]$row.reviewerAttempt, [StringComparison]::OrdinalIgnoreCase)) { $errors.Add("ATTEMPTS_NOT_DISTINCT") }
    if ([string]$row.reviewAuthority -cnotin @("governing","shadow","advisory")) { $errors.Add("INVALID_AUTHORITY") }
    foreach ($textField in @("lane","transcript")) {
      $text = [string]$row.$textField
      if ([string]::IsNullOrWhiteSpace($text) -or $text.Length -gt 1024 -or $text -match '[\r\n]') { $errors.Add("INVALID_$($textField.ToUpperInvariant())") }
    }
    foreach ($modelField in @("reviewerModel","authorModel")) {
       if ([string]$row.$modelField -cnotin (Get-ReviewSelectableModels $Vocabulary)) { $errors.Add("INVALID_$($modelField.ToUpperInvariant())") }
    }
    if ([string]$row.effort -cnotin $Vocabulary.efforts) { $errors.Add("INVALID_EFFORT") }
    $routingRow = 0
    if (-not [int]::TryParse([string]$row.row, [ref]$routingRow) -or $routingRow -lt 1 -or $routingRow -gt 15) { $errors.Add("INVALID_ROW") }
    if ([string]$row.placement -cnotmatch '^(measured|provisional|override-[a-z0-9._-]+)$') { $errors.Add("INVALID_PLACEMENT") }
    if ([string]$row.harness -cnotin @("codex","claude")) { $errors.Add("INVALID_HARNESS") }
    if ($routingPresent.Count -eq $routingKeys.Count) {
      if (-not (Test-WholeNumber $row.policyGeneration 1)) { $errors.Add('INVALID_POLICY_GENERATION') }
      if ([string]$row.registryAuthorityDigest -cnotmatch '^[a-zA-Z0-9._:-]{1,128}$') { $errors.Add('INVALID_REGISTRY_AUTHORITY_DIGEST') }
      if ([string]$row.family -cnotmatch '^[a-z0-9][a-z0-9._-]{0,63}$') { $errors.Add('INVALID_ROUTING_FAMILY') }
      if ([string]$row.slot -cnotmatch '^(explicit|(codex|claude)\.(primary|fallback))$') { $errors.Add('INVALID_ROUTING_SLOT') }
      if ($row.usedLastKnownGood -isnot [bool]) { $errors.Add('INVALID_ROUTING_LKG') }
    }
    if ($version -ceq "v2" -and [string]$row.stage -cne "review") { $errors.Add("INVALID_STAGE") }
    if ($rowKind -ceq "correction") {
      # A correction row names either a dispatch+terminal pair (both original
      # hashes) or a dangling dispatch row alone (dispatch hash only). The
      # variant is the key shape itself; neither admits a sentinel terminal hash.
      $hashFields = if ($correctionVariant -ceq "pair") { @('originalDispatchRawSha256','originalTerminalRawSha256') } else { @('originalDispatchRawSha256') }
      foreach ($field in $hashFields) {
        if ([string]$row.$field -cnotmatch '^[a-f0-9]{64}$') { $errors.Add("INVALID_$field") }
      }
      if ([string]$row.operatorAuthority -cnotmatch '^Todd:[A-Za-z0-9][A-Za-z0-9._:/#-]{0,255}$') { $errors.Add('INVALID_OPERATOR_AUTHORITY') }
    }
    if ($rowKind -ceq "receipt") {
      if ([string]$row.reviewContract -cne "review-contract/v2") { $errors.Add("INVALID_REVIEW_CONTRACT") }
      if ($row.completeSweep -isnot [bool] -or $row.completeSweep -ne $true) { $errors.Add("INCOMPLETE_SWEEP") }
      if ([string]$row.outcome -cnotin @("PASS","BLOCK_FIXABLE","BLOCK_REPLAN")) { $errors.Add("INVALID_OUTCOME") }
      if (-not (Test-ControllerClosedKeys $row.findings @("blocking","candidates","nonBlocking"))) { $errors.Add("FINDINGS_SHAPE_NOT_CLOSED") }
      foreach ($countField in @("blocking","candidates","nonBlocking")) {
        if (-not (Test-WholeNumber $row.findings.$countField 0) -or [int64]$row.findings.$countField -gt 10000) { $errors.Add("INVALID_$($countField.ToUpperInvariant())") }
      }
      if ($row.findingIds -isnot [array]) { $errors.Add("INVALID_FINDING_IDS") }
      else {
        $ids = @($row.findingIds)
        if (@($ids | Where-Object { [string]$_ -cnotmatch '^[A-Z][A-Z0-9._-]{0,63}$' }).Count -gt 0) { $errors.Add("INVALID_FINDING_ID") }
        if (@($ids | Sort-Object -Unique).Count -ne $ids.Count) { $errors.Add("DUPLICATE_FINDING_ID") }
        if ($ids.Count -ne [int64]$row.findings.blocking) { $errors.Add("FINDING_COUNT_MISMATCH") }
      }
      if ([string]$row.outcome -ceq "PASS" -and [int64]$row.findings.blocking -ne 0) { $errors.Add("PASS_WITH_BLOCKING_FINDING") }
      if ([string]$row.outcome -in @("BLOCK_FIXABLE","BLOCK_REPLAN") -and [int64]$row.findings.blocking -lt 1) { $errors.Add("BLOCK_WITHOUT_FINDING") }
    }
  }

  [pscustomobject][ordered]@{
    schemaVersion = $script:ControllerClassificationSchema
    physicalLine = $line
    rowKind = $rowKind
    version = $version
    correctionVariant = $correctionVariant
    strict = $claimsStrict
    legacy = $claimsLegacy
    valid = $errors.Count -eq 0
    errors = @($errors)
    issue = if (Test-JsonProperty $row "issue") { $row.issue } else { $null }
    controllerHead = if (Test-JsonProperty $row "controllerHead") { [string]$row.controllerHead } else { $null }
    authorAttempt = if (Test-JsonProperty $row "authorAttempt") { [string]$row.authorAttempt } else { $null }
    reviewerAttempt = if (Test-JsonProperty $row "reviewerAttempt") { [string]$row.reviewerAttempt } else { $null }
    reviewAuthority = if (Test-JsonProperty $row "reviewAuthority") { [string]$row.reviewAuthority } else { $null }
    rawSha256 = $rawSha
  }
}

function Get-ControllerTupleKey($Row) {
  @(
    [string]$Row.issue, [string]$Row.controllerHead, [string]$Row.authorAttempt, [string]$Row.reviewerAttempt,
    [string]$Row.reviewAuthority, [string]$Row.lane, [string]$Row.transcript, [string]$Row.reviewerModel,
    [string]$Row.authorModel, [string]$Row.effort, [string]$Row.row, [string]$Row.placement,
    [string]$Row.harness, $(if (Test-JsonProperty $Row "stage") { [string]$Row.stage } else { "" }),
    # v2 routing authority is part of the exact dispatch/terminal join.  Keep
    # empty slots for v1 rows so legacy history remains readable and joins on
    # the original tuple continue to work.
    $(if (Test-JsonProperty $Row "policyGeneration") { [string]$Row.policyGeneration } else { "" }),
    $(if (Test-JsonProperty $Row "registryAuthorityDigest") { [string]$Row.registryAuthorityDigest } else { "" }),
    $(if (Test-JsonProperty $Row "family") { [string]$Row.family } else { "" }),
    $(if (Test-JsonProperty $Row "slot") { [string]$Row.slot } else { "" }),
    $(if (Test-JsonProperty $Row "usedLastKnownGood") { [string]$Row.usedLastKnownGood } else { "" })
  ) -join "`u{001f}"
}

function Get-ControllerReviewClassifiedHistory {
  [CmdletBinding()]
  param([Parameter(Mandatory)]$History, [switch]$IncludeLegacy, $Vocabulary)
  if ($null -eq $Vocabulary) { $Vocabulary = Get-ReviewRecordVocabulary }
  foreach ($entry in $History.rows) {
    $row = $entry.value
    # Inspect decoded properties, not raw tokens: escaped names and values,
    # unsupported schema claims and global blocking-head receipts must survive.
    # The complete reader still validates every byte/row and retains all hashes
    # for correction joins. Legacy bridges deliberately classify every row.
    if ($IncludeLegacy -or (Test-JsonProperty $row 'controllerReviewSchema')) {
      [pscustomobject]@{ entry=$entry; classification=(Get-ControllerReviewRowClassification $entry $Vocabulary) }
    }
  }
}

function Test-ControllerDanglingDispatchRow($Entry, $History, [int]$Before = 0, [object]$Vocabulary = $null) {
  if ($null -eq $Vocabulary) { $Vocabulary = Get-ReviewRecordVocabulary }
  # A dangling row is a malformed strict dispatch row that never became a pair:
  # no terminal row matches it (at any physical line, so a later receipt still
  # fails closed) and no valid strict dispatch on the same (issue, controllerHead)
  # succeeded it. When judged for a correction, only successors that precede the
  # correction row count; the relaunch that follows a cleared row is expected.
  $classification = Get-ControllerReviewRowClassification $Entry $Vocabulary
  if (-not $classification.strict -or $classification.valid -or $classification.rowKind -cne 'dispatch') { return $false }
  if ($null -eq $classification.issue -or [string]$classification.controllerHead -cnotmatch '^[a-f0-9]{40}$') { return $false }
  $row = $Entry.value
  $rowLine = [int]$Entry.line
  foreach ($other in @($History.rows)) {
    $otherLine = [int]$other.line
    if ($otherLine -eq $rowLine) { continue }
    $value = $other.value
    $otherKind = if (Test-JsonProperty $value 'kind') { [string]$value.kind } else { '' }
    $otherSchema = if (Test-JsonProperty $value 'controllerReviewSchema') { [string]$value.controllerReviewSchema } else { '' }
    if ($otherKind -ceq 'review-complete' -or $otherSchema -cin @($script:ControllerReceiptSchemaV1, $script:ControllerReceiptSchemaV2)) {
      foreach ($field in @('lane','transcript','reviewerAttempt')) {
        if ((Test-JsonProperty $row $field) -and (Test-JsonProperty $value $field) -and
            -not [string]::IsNullOrWhiteSpace([string]$row.$field) -and [string]$value.$field -ceq [string]$row.$field) { return $false }
      }
      if ((Get-ControllerTupleKey $value) -ceq (Get-ControllerTupleKey $row)) { return $false }
    }
    if ($otherLine -gt $rowLine -and ($Before -le 0 -or $otherLine -lt $Before) -and $otherSchema) {
      $otherClass = Get-ControllerReviewRowClassification $other $Vocabulary
      if ($otherClass.valid -and $otherClass.rowKind -ceq 'dispatch' -and $otherClass.issue -eq $classification.issue -and
          $otherClass.controllerHead -ceq $classification.controllerHead) { return $false }
    }
  }
  return $true
}

function Get-ControllerDanglingDispatchCorrectionValidation($Entry, $History, [object]$Vocabulary = $null) {
  if ($null -eq $Vocabulary) { $Vocabulary = Get-ReviewRecordVocabulary }
  # Dispatch-only variant: the correction names one malformed strict dispatch row
  # by its raw hash and clears it from the fail-closed set. It projects nothing,
  # never supplies a terminal, and never grants authority. Todd authority is
  # carried on the row itself and validated by the classifier.
  $result = [ordered]@{ valid=$false; reason='AUDIT_CORRECTION_INVALID'; dispatch=$null; terminal=$null }
  $classification = Get-ControllerReviewRowClassification $Entry $Vocabulary
  if (-not $History.complete -or -not $classification.valid -or $classification.rowKind -cne 'correction' -or
      $classification.correctionVariant -cne 'dispatch-only') { return [pscustomobject]$result }
  $row = $Entry.value
  $dispatches = @($History.rows | Where-Object { $_.rawSha256 -ceq $row.originalDispatchRawSha256 })
  if ($dispatches.Count -ne 1) { $result.reason='AUDIT_ORIGINAL_COUNT'; return [pscustomobject]$result }
  $dispatch = $dispatches[0]
  foreach ($originalEntry in @($dispatch, $Entry)) {
    $raw = if ($originalEntry.raw) { $originalEntry.raw } else { $originalEntry.value | ConvertTo-Json -Compress -Depth 20 }
    try {
      $document = [System.Text.Json.JsonDocument]::Parse([string]$raw)
      try {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($property in $document.RootElement.EnumerateObject()) {
          if (-not $names.Add($property.Name)) { $result.reason='AUDIT_DUPLICATE_KEY'; return [pscustomobject]$result }
        }
      } finally { $document.Dispose() }
    } catch { return [pscustomobject]$result }
  }
  $hash = ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes([string]$dispatch.raw)))).ToLowerInvariant()
  if ($hash -cne $dispatch.rawSha256) { $result.reason='AUDIT_ORIGINAL_HASH_MISMATCH'; return [pscustomobject]$result }
  # Only a malformed strict dispatch row on the correction's own (issue, head)
  # and lane/transcript is eligible. A valid row, a receipt, a row on another
  # head, or a row that has a terminal is never cleared.
  $dispatchClass = Get-ControllerReviewRowClassification $dispatch $Vocabulary
  $original = $dispatch.value
  if (-not $dispatchClass.strict -or $dispatchClass.valid -or $dispatchClass.rowKind -cne 'dispatch' -or
      $dispatchClass.issue -ne $row.issue -or $dispatchClass.controllerHead -cne $row.controllerHead) { $result.reason='AUDIT_DISPATCH_MISMATCH'; return [pscustomobject]$result }
  foreach ($field in @('lane','transcript')) {
    if (-not (Test-JsonProperty $original $field) -or [string]$original.$field -cne [string]$row.$field) { $result.reason='AUDIT_DISPATCH_MISMATCH'; return [pscustomobject]$result }
  }
  if (-not (Test-ControllerDanglingDispatchRow $dispatch $History ([int]$Entry.line) $Vocabulary)) { $result.reason='AUDIT_ORIGINAL_NOT_DANGLING'; return [pscustomobject]$result }
  if ([int]$dispatch.line -ge [int]$Entry.line -or
      ((Test-ControllerUtcInstant $original.ts) -and [datetimeoffset]::Parse($original.ts) -ge [datetimeoffset]::Parse($row.ts))) { $result.reason='AUDIT_ORIGINAL_NOT_CAUSAL'; return [pscustomobject]$result }
  $corrections = @($History.rows | Where-Object {
    $_.value.controllerReviewSchema -ceq $script:ControllerCorrectionSchema -and
    $_.value.originalDispatchRawSha256 -ceq $row.originalDispatchRawSha256
  })
  if ($corrections.Count -ne 1 -or $corrections[0].line -ne $Entry.line) { $result.reason='AUDIT_CORRECTION_DUPLICATE'; return [pscustomobject]$result }
  $result.valid=$true; $result.reason='AUDIT_DANGLING_DISPATCH_BOUND'; $result.dispatch=$dispatch
  return [pscustomobject]$result
}

function Get-ControllerAuditCorrectionValidation($Entry, $History, [object]$Vocabulary = $null) {
  if ($null -eq $Vocabulary) { $Vocabulary = Get-ReviewRecordVocabulary }
  $result = [ordered]@{ valid=$false; reason='AUDIT_CORRECTION_INVALID'; dispatch=$null; terminal=$null }
  $classification = Get-ControllerReviewRowClassification $Entry $Vocabulary
  if (-not $History.complete -or -not $classification.valid -or $classification.rowKind -cne 'correction') { return [pscustomobject]$result }
  if ($classification.correctionVariant -ceq 'dispatch-only') { return Get-ControllerDanglingDispatchCorrectionValidation $Entry $History $Vocabulary }
  $row = $Entry.value
  if ($row.issue -ne 7978 -or $row.controllerHead -cne '7e256a9dfa52ee907a1585e2989e8475858a1224' -or
      $row.originalDispatchRawSha256 -cne '79135c2de2c9e1346471243bd53ca85adf161670271f38086b56318e73733cf3' -or
      $row.originalTerminalRawSha256 -cne '6321dd4b64a51e50594ce806bf99b212fe88befd0a7e02c2ec40216503141153' -or
      $row.operatorAuthority -cne 'Todd:https://github.com/chase-sets/chase-sets/issues/7972#issuecomment-5657749132') {
    $result.reason='AUDIT_CORRECTION_NOT_AUTHORIZED'; return [pscustomobject]$result
  }
  $dispatches = @($History.rows | Where-Object { $_.rawSha256 -ceq $row.originalDispatchRawSha256 })
  $terminals = @($History.rows | Where-Object { $_.rawSha256 -ceq $row.originalTerminalRawSha256 })
  if ($dispatches.Count -ne 1 -or $terminals.Count -ne 1) { $result.reason='AUDIT_ORIGINAL_COUNT'; return [pscustomobject]$result }
  $dispatch = $dispatches[0]; $terminal = $terminals[0]
  foreach ($originalEntry in @($dispatch, $terminal, $Entry)) {
    $raw = if ($originalEntry.raw) { $originalEntry.raw } else { $originalEntry.value | ConvertTo-Json -Compress -Depth 20 }
    try {
      $document = [System.Text.Json.JsonDocument]::Parse([string]$raw)
      try {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($property in $document.RootElement.EnumerateObject()) {
          if (-not $names.Add($property.Name)) { $result.reason='AUDIT_DUPLICATE_KEY'; return [pscustomobject]$result }
        }
      } finally { $document.Dispose() }
    } catch { return [pscustomobject]$result }
  }
  $terminalClass = Get-ControllerReviewRowClassification $terminal $Vocabulary
  if (-not $terminalClass.valid -or $terminalClass.rowKind -cne 'receipt' -or $terminalClass.version -cne 'v1' -or
      (Get-ControllerTupleKey $terminal.value) -cne (Get-ControllerTupleKey $row)) { $result.reason='AUDIT_TERMINAL_MISMATCH'; return [pscustomobject]$result }
  # Only the two pinned original byte strings are eligible. The ruling supplies
  # their missing link, never the generic row's note or a configurable allowlist.
  $original = $dispatch.value
  foreach ($originalEntry in @($dispatch, $terminal)) {
    $hash = ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes([string]$originalEntry.raw)))).ToLowerInvariant()
    if ($hash -cne $originalEntry.rawSha256) { $result.reason='AUDIT_ORIGINAL_HASH_MISMATCH'; return [pscustomobject]$result }
  }
  foreach ($field in @('issue','lane','transcript','harness','effort','row','placement')) {
    if (-not (Test-JsonProperty $original $field) -or [string]$original.$field -cne [string]$row.$field) { $result.reason='AUDIT_DISPATCH_MISMATCH'; return [pscustomobject]$result }
  }
  if ($original.model -cne $row.reviewerModel) { $result.reason='AUDIT_DISPATCH_MISMATCH'; return [pscustomobject]$result }
  $matchingDispatches = @($History.rows | Where-Object {
    $_.value.kind -ceq 'dispatch' -and $_.value.issue -eq $row.issue -and
    $_.value.lane -ceq $row.lane -and $_.value.transcript -ceq $row.transcript
  })
  $matchingTerminals = @($History.rows | Where-Object {
    $_.value.kind -ceq 'review-complete' -and $_.value.issue -eq $row.issue -and
    $_.value.lane -ceq $row.lane -and $_.value.transcript -ceq $row.transcript
  })
  if ($matchingDispatches.Count -ne 1 -or $matchingTerminals.Count -ne 1) { $result.reason='AUDIT_ORIGINAL_AMBIGUOUS'; return [pscustomobject]$result }
  if (-not (Test-ControllerUtcInstant $original.ts) -or
      $dispatch.line -ge $terminal.line -or $terminal.line -ge $Entry.line -or
      [datetimeoffset]::Parse($original.ts) -ge [datetimeoffset]::Parse($terminal.value.ts) -or
      [datetimeoffset]::Parse($terminal.value.ts) -ge [datetimeoffset]::Parse($row.ts)) { $result.reason='AUDIT_ORIGINAL_NOT_CAUSAL'; return [pscustomobject]$result }
  $corrections = @($History.rows | Where-Object {
    $_.value.controllerReviewSchema -ceq $script:ControllerCorrectionSchema -and
    ($_.value.originalDispatchRawSha256 -ceq $row.originalDispatchRawSha256 -or
     $_.value.originalTerminalRawSha256 -ceq $row.originalTerminalRawSha256 -or
     (Get-ControllerTupleKey $_.value) -ceq (Get-ControllerTupleKey $row))
  })
  if ($corrections.Count -ne 1 -or $corrections[0].line -ne $Entry.line) { $result.reason='AUDIT_CORRECTION_DUPLICATE'; return [pscustomobject]$result }
  $result.valid=$true; $result.reason='AUDIT_CORRECTION_BOUND'; $result.dispatch=$dispatch; $result.terminal=$terminal
  return [pscustomobject]$result
}

function New-ControllerReleaseReduction($Value) {
  $identityBytes = [Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Compress -Depth 30))
  $identity = ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($identityBytes))).ToLowerInvariant()
  $result = [ordered]@{}
  foreach ($property in $Value.GetEnumerator()) { $result[$property.Key] = $property.Value }
  $result.identitySha256 = $identity
  [pscustomobject]$result
}

function Reduce-ControllerReleaseReview {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][ValidateRange(1,[int]::MaxValue)][int]$Issue,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string]$ControllerHead,
    [Parameter(Mandatory)][ValidateSet("legacy-h1","legacy-h2","strict-v1","strict-v2")][string]$Mode,
    [Parameter(Mandatory)]$History,
    $DispatchTuple
  )
  $census = [ordered]@{
    governing = [ordered]@{ pass=0; blockFixable=0; blockReplan=0; inFlight=0 }
    shadow = [ordered]@{ pass=0; blockFixable=0; blockReplan=0; inFlight=0 }
    advisory = [ordered]@{ pass=0; blockFixable=0; blockReplan=0; inFlight=0 }
    legacy = 0
    duplicateReplay = 0
    invalidConflict = 0
  }
  $audit = [ordered]@{ historyComplete=[bool]$History.complete; historyReason=[string]$History.reason; rows=@($History.audit.rows); malformedRows=@($History.audit.malformedRows) }
  $base = [ordered]@{ schemaVersion=$script:ControllerReductionSchema; mode=$Mode; state="indeterminate"; reason="UNREDUCED"; issue=$Issue; controllerHead=$ControllerHead; selected=$null; blockingHeads=@(); census=$census; audit=$audit }
  if (-not $History.complete) { $base.reason=[string]$History.reason; return New-ControllerReleaseReduction $base }

  $recordVocabulary = Get-ReviewRecordVocabulary
  $classified = @(Get-ControllerReviewClassifiedHistory -History $History -IncludeLegacy:($Mode -like 'legacy-*') -Vocabulary $recordVocabulary)
  if ($Mode -like "legacy-*") {
    if (($Mode -ceq "legacy-h1" -and $Issue -ne 6348) -or ($Mode -ceq "legacy-h2" -and $Issue -ne 6335)) { $base.reason="LEGACY_PHASE_ISSUE_MISMATCH"; return New-ControllerReleaseReduction $base }
    if (@($classified | Where-Object { $_.classification.strict }).Count -gt 0) { $base.reason="STRICT_ROW_PRESENT_DURING_LEGACY_BRIDGE"; return New-ControllerReleaseReduction $base }
    $crossIssue=@($classified|Where-Object{$_.classification.legacy-and$_.classification.controllerHead-ceq$ControllerHead-and$_.entry.value.PSObject.Properties['laneRole']-and$_.entry.value.laneRole-ceq'review'-and$_.classification.issue-ne$Issue})
    if($crossIssue.Count-gt0){$base.reason="CROSS_ISSUE_CONFLICT";return New-ControllerReleaseReduction $base}
    $family = @($classified | Where-Object { $_.classification.legacy -and $_.classification.issue -eq $Issue -and $_.classification.controllerHead -ceq $ControllerHead })
    $dispatches = @($family | Where-Object { $_.entry.value.kind -ceq "dispatch" })
    $receipts = @($family | Where-Object { $_.entry.value.kind -ceq "review-complete" })
    if ($dispatches.Count -ne 1) { $base.reason="DISPATCH_COUNT"; return New-ControllerReleaseReduction $base }
    if ($receipts.Count -ne 1) { $base.reason="TERMINAL_COUNT"; return New-ControllerReleaseReduction $base }
    $dispatch=$dispatches[0].entry; $receipt=$receipts[0].entry
    if ([int]$dispatch.line -ge [int]$receipt.line) { $base.reason="ROW_ORDER"; return New-ControllerReleaseReduction $base }
    $tuple=@("issue","lane","laneRole","harness","model","authorModel","effort","row","placement","transcript","controllerHead")
    foreach($name in $tuple){if(-not(Test-JsonProperty $dispatch.value $name)-or-not(Test-JsonProperty $receipt.value $name)-or[string]$dispatch.value.$name-cne[string]$receipt.value.$name){$base.reason="TUPLE_$($name.ToUpperInvariant())";return New-ControllerReleaseReduction $base}}
    if($dispatch.value.laneRole-cne"review"){$base.reason="TUPLE_LANE_ROLE";return New-ControllerReleaseReduction $base}
    if($receipt.value.reviewContract-cne"review-contract/v2"){$base.reason="REVIEW_CONTRACT";return New-ControllerReleaseReduction $base}
    if($receipt.value.completeSweep-cne$true){$base.reason="COMPLETE_SWEEP";return New-ControllerReleaseReduction $base}
    if($receipt.value.outcome-cne"PASS"){$base.reason="TERMINAL_OUTCOME";return New-ControllerReleaseReduction $base}
    if(-not(Test-JsonProperty $receipt.value "findings")){$base.reason="FINDINGS_MISSING";return New-ControllerReleaseReduction $base}
    if(-not(Test-ControllerClosedKeys $receipt.value.findings @("blocking","candidates","nonBlocking"))){$base.reason="FINDINGS_SHAPE";return New-ControllerReleaseReduction $base}
    if(-not(Test-WholeNumber $receipt.value.findings.blocking 0)-or[int64]$receipt.value.findings.blocking-ne0){$base.reason="BLOCKING_COUNT";return New-ControllerReleaseReduction $base}
    if(-not(Test-WholeNumber $receipt.value.findings.candidates 0)-or[int64]$receipt.value.findings.candidates-ne0){$base.reason="CANDIDATE_COUNT";return New-ControllerReleaseReduction $base}
    if(-not(Test-WholeNumber $receipt.value.findings.nonBlocking 0)-or[int64]$receipt.value.findings.nonBlocking-gt10000){$base.reason="NON_BLOCKING_COUNT";return New-ControllerReleaseReduction $base}
    if(-not(Test-ControllerUtcInstant $dispatch.value.ts)-or-not(Test-ControllerUtcInstant $receipt.value.ts)-or
       [datetimeoffset]::Parse([string]$dispatch.value.ts)-ge[datetimeoffset]::Parse([string]$receipt.value.ts)){$base.reason="UTC_ORDER";return New-ControllerReleaseReduction $base}
    foreach($field in @("lane","transcript")){
      $reuse=@($classified|Where-Object{$_.classification.legacy-and$_.entry.value.PSObject.Properties[$field]-and[string]$_.entry.value.$field-ceq[string]$dispatch.value.$field-and($_.classification.issue-ne$Issue-or$_.classification.controllerHead-cne$ControllerHead)})
      if($reuse.Count-gt0){$base.reason="$($field.ToUpperInvariant())_REUSE";return New-ControllerReleaseReduction $base}
    }
    $base.state="authorized";$base.reason="LEGACY_BRIDGE_PASS";$census.legacy=1
    $base.selected=[ordered]@{dispatchLine=[int]$dispatch.line;dispatchRawSha256=[string]$dispatch.rawSha256;terminalLine=[int]$receipt.line;terminalRawSha256=[string]$receipt.rawSha256;lane=[string]$dispatch.value.lane;transcript=[string]$dispatch.value.transcript}
    return New-ControllerReleaseReduction $base
  }

  $expectedVersion = if($Mode-ceq"strict-v2"){"v2"}else{"v1"}
  # Dispatch-only corrections bind first. Each must name one dangling malformed
  # strict dispatch row on this (issue, controllerHead) under Todd authority; an
  # unbound one fails closed with its binding reason. A cleared row leaves the
  # fail-closed set and nothing else: no projection, no pair, no authority.
  $danglingCorrections=@($classified|Where-Object{$_.classification.strict-and$_.classification.valid-and$_.classification.rowKind-ceq'correction'-and$_.classification.correctionVariant-ceq'dispatch-only'-and$_.classification.issue-eq$Issue-and$_.classification.controllerHead-ceq$ControllerHead})
  $clearedDanglingLines=@()
  if($danglingCorrections.Count-gt0){$audit.danglingCorrections=@()}
  foreach($correction in $danglingCorrections){
    $binding=Get-ControllerAuditCorrectionValidation $correction.entry $History $recordVocabulary
    if(-not$binding.valid){$base.reason=$binding.reason;$census.invalidConflict+=1;return New-ControllerReleaseReduction $base}
    $audit.danglingCorrections=@($audit.danglingCorrections)+@([ordered]@{
      physicalLine=$correction.entry.line;ts=$correction.entry.value.ts;rawSha256=$correction.entry.rawSha256
      originalDispatchRawSha256=$binding.dispatch.rawSha256;originalPhysicalLine=[int]$binding.dispatch.line
      operatorAuthority=$correction.entry.value.operatorAuthority
    })
    $clearedDanglingLines+=[int]$binding.dispatch.line
  }
  $relevantInvalid=@($classified|Where-Object{
    if(-not$_.classification.strict-or$_.classification.valid){return $false}
    return $_.classification.issue-eq$Issue-and$_.classification.controllerHead-ceq$ControllerHead-and[int]$_.classification.physicalLine-notin$clearedDanglingLines
  })
  if($relevantInvalid.Count-gt0){
    $census.invalidConflict=$relevantInvalid.Count
    $audit.invalidRows=@($relevantInvalid|ForEach-Object{[ordered]@{line=$_.classification.physicalLine;errors=@($_.classification.errors);dangling=[bool](Test-ControllerDanglingDispatchRow $_.entry $History 0 $recordVocabulary)}})
    $base.reason="MALFORMED_RELEVANT_STRICT_ROW";return New-ControllerReleaseReduction $base
  }
  $valid=@($classified|Where-Object{$_.classification.strict-and$_.classification.valid})
  $candidate=@($valid|Where-Object{$_.classification.issue-eq$Issue-and$_.classification.controllerHead-ceq$ControllerHead})
  if(@($candidate|Where-Object{$_.classification.version-cne$expectedVersion}).Count-gt0){$base.reason="STRICT_VERSION_MISMATCH";return New-ControllerReleaseReduction $base}
  if ($null -ne $DispatchTuple) {
    $tupleClass = Get-ControllerReviewRowClassification $DispatchTuple $recordVocabulary
    $launchRows = @($candidate | Where-Object {
      $_.entry.value.lane -ceq $DispatchTuple.lane -or $_.entry.value.transcript -ceq $DispatchTuple.transcript
    })
    if (-not $tupleClass.valid -or $tupleClass.rowKind -cne 'dispatch' -or $tupleClass.version -cne $expectedVersion -or
        $DispatchTuple.issue -ne $Issue -or $DispatchTuple.controllerHead -cne $ControllerHead -or
        $launchRows.Count -ne 1 -or $launchRows[0].classification.rowKind -cne 'dispatch' -or
        (Get-ControllerTupleKey $launchRows[0].entry.value) -cne (Get-ControllerTupleKey $DispatchTuple) -or
        [datetimeoffset]::Parse($launchRows[0].entry.value.ts) -gt [datetimeoffset]::UtcNow) {
      $base.reason='STRICT_PRELAUNCH_TUPLE_REQUIRED'; return New-ControllerReleaseReduction $base
    }
  }
  $corrections = @($candidate | Where-Object { $_.classification.rowKind -ceq 'correction' -and $_.classification.correctionVariant -cne 'dispatch-only' })
  $candidate = @($candidate | Where-Object { $_.classification.rowKind -cne 'correction' })
  if ($corrections.Count -gt 0) { $audit.corrections = @() }
  foreach ($correction in $corrections) {
    $binding = Get-ControllerAuditCorrectionValidation $correction.entry $History $recordVocabulary
    if (-not $binding.valid) { $base.reason=$binding.reason; $census.invalidConflict+=1; return New-ControllerReleaseReduction $base }
    # Projection only. Audit retains the original physical row and hash plus
    # the current-time correction. No strict dispatch is appended or backdated.
    $projection = $binding.terminal.value.PSObject.Copy()
    $projectedClass = (Get-ControllerReviewRowClassification $binding.terminal $recordVocabulary).PSObject.Copy()
    $projectedClass.rowKind='dispatch'; $projectedClass.rawSha256=$binding.dispatch.rawSha256
    $candidate += [pscustomobject]@{
      entry=[pscustomobject]@{line=$binding.dispatch.line;value=$projection}; classification=$projectedClass
      correctionRawSha256=$correction.entry.rawSha256
    }
    $audit.corrections = @($audit.corrections) + @([ordered]@{
      physicalLine=$correction.entry.line; ts=$correction.entry.value.ts; rawSha256=$correction.entry.rawSha256
      originalDispatchRawSha256=$binding.dispatch.rawSha256; originalTerminalRawSha256=$binding.terminal.rawSha256
      operatorAuthority=$correction.entry.value.operatorAuthority
    })
  }
  $blockingHeads=@($valid|Where-Object{$_.classification.rowKind-ceq"receipt"-and$_.classification.reviewAuthority-ceq"governing"-and[string]$_.entry.value.outcome-in@("BLOCK_FIXABLE","BLOCK_REPLAN")}|ForEach-Object{$_.classification.controllerHead}|Sort-Object -Unique)
  $base.blockingHeads=@($blockingHeads)
  $groups=@($candidate|Group-Object{Get-ControllerTupleKey $_.entry.value})
  if($groups.Count-eq0){$base.reason="NO_STRICT_REVIEW_HISTORY";return New-ControllerReleaseReduction $base}
  $governingPass=0;$governingBlock=0;$inFlight=0
  $selectedRows=[Collections.Generic.List[object]]::new()
  $selectedGoverningPass=$null
  foreach($group in $groups){
    $dispatches=@($group.Group|Where-Object{$_.classification.rowKind-ceq"dispatch"}|Group-Object{$_.classification.rawSha256}|ForEach-Object{$census.duplicateReplay+=$_.Count-1;$_.Group[0]})
    $receipts=@($group.Group|Where-Object{$_.classification.rowKind-ceq"receipt"}|Group-Object{$_.classification.rawSha256}|ForEach-Object{$census.duplicateReplay+=$_.Count-1;$_.Group[0]})
    if($dispatches.Count-ne1-or$receipts.Count-gt1){$census.invalidConflict+=1;$base.reason="STRICT_PAIR_CONFLICT";return New-ControllerReleaseReduction $base}
    $dispatch=$dispatches[0];$authority=[string]$dispatch.classification.reviewAuthority
    $selectedRows.Add([ordered]@{kind=$(if($dispatch.correctionRawSha256){'audit-corrected-dispatch'}else{'dispatch'});physicalLine=[int]$dispatch.entry.line;rawSha256=[string]$dispatch.classification.rawSha256})
    if($receipts.Count-eq0){$census[$authority].inFlight+=1;$inFlight+=1;continue}
    $receipt=$receipts[0]
    if([int]$receipt.entry.line-le[int]$dispatch.entry.line){$census.invalidConflict+=1;$base.reason="STRICT_TERMINAL_NOT_CAUSAL";return New-ControllerReleaseReduction $base}
    $bucket=switch([string]$receipt.entry.value.outcome){"PASS"{"pass"};"BLOCK_FIXABLE"{"blockFixable"};"BLOCK_REPLAN"{"blockReplan"}}
    $selectedRows.Add([ordered]@{kind="review-complete";physicalLine=[int]$receipt.entry.line;rawSha256=[string]$receipt.classification.rawSha256})
    $census[$authority][$bucket]+=1
    if($authority-ceq"governing"-and$bucket-ceq"pass"){
      $governingPass+=1
      if($null-eq$selectedGoverningPass){$selectedGoverningPass=[ordered]@{dispatchRawSha256=[string]$dispatch.classification.rawSha256;terminalRawSha256=[string]$receipt.classification.rawSha256;lane=[string]$dispatch.entry.value.lane;transcript=[string]$dispatch.entry.value.transcript}}
    }
    if($authority-ceq"governing"-and$bucket-ne"pass"){$governingBlock+=1}
  }
  if($inFlight-gt0){$base.state="in-flight";$base.reason="STRICT_ATTEMPT_IN_FLIGHT"}
  elseif($governingBlock-gt0){$base.state="blocked";$base.reason="GOVERNING_BLOCK"}
  elseif($governingPass-lt1){$base.reason="NO_GOVERNING_PASS"}
  else{$base.state="authorized";$base.reason="GOVERNING_PASS"}
  $base.selected=[ordered]@{projectionMode=$Mode;candidateRows=$candidate.Count;governingPass=$governingPass;governingBlock=$governingBlock;governingPair=$selectedGoverningPass;rows=@($selectedRows)}
  New-ControllerReleaseReduction $base
}

Export-ModuleMember -Function @(
  "Get-ObservedLaneValue",
  "Get-ObservedLaneTime",
  "ConvertTo-ObservedLaneUtc",
  "Assert-ObservedLaneFields",
  "Assert-ObservedLaneHistory",
  "Test-LaneTimeObservation",
  "Test-ObservedLaneTerminal",
  "Get-LaneTimeLaneRows",
  "Get-LaneTimeHash",
  "ConvertFrom-LaneTimeJson",
  "Read-LaneTimeCapture",
  "Get-LaneTimeDispatchTarget",
  "Test-LaneTimeLaunch",
  "Assert-LaneTimeObservationFields",
  "Assert-LaneTimeObservationHistory",
  "Assert-LaneTimeTerminalTarget",
  "Get-LaneTimeProjection",
  "Get-ReviewRecordVocabulary",
  "Get-ExactHeadReviewContract",
  "Get-ReviewReceiptValidation",
  "Read-ExactHeadReviewHistory",
  "Reduce-LandedIntegrationAuthority",
  "Reduce-ExactHeadReview",
  "Get-ControllerReviewRowClassification",
  "Get-ControllerReviewClassifiedHistory",
  "Get-ControllerAuditCorrectionValidation",
  "Reduce-ControllerReleaseReview",
  "Test-WholeNumber",
  "Get-OrdinaryReviewPrDomain",
  "Test-PlanningReviewReceiptIdentity",
  "ConvertTo-ReviewInstant"
)
