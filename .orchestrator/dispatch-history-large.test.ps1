[CmdletBinding()]
param([switch]$UpperBoundDiagnostic,[switch]$CheckpointOnly)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'review-head-contract.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1') -DisableNameChecking
if($CheckpointOnly){Import-Module (Join-Path $PSScriptRoot 'dispatch-history-checkpoint.psm1') -DisableNameChecking}
. (Join-Path $PSScriptRoot 'controller-skills/milestone-orchestrator/scripts/query-ledgers.ps1') -Library -RuntimeRoot $PSScriptRoot
$temporary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$root=Join-Path $temporary ('dispatch-history-large-'+[guid]::NewGuid().ToString('N'))
$failures=[Collections.Generic.List[string]]::new()
function Assert-Large([bool]$Condition,[string]$Message) {
  if(-not $Condition) { throw $Message }
}
function Check-Large([string]$Name,[scriptblock]$Body) {
  try { & $Body; Write-Output "PASS $Name" }
  catch { $failures.Add("${Name}: $($_.Exception.Message)"); Write-Output "FAIL ${Name}: $($_.Exception.Message)" }
}
function Get-RawHash([string]$Raw) {
  [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Raw))).ToLowerInvariant()
}
function Read-LargeHistory([string]$Reader,[string]$Path,[switch]$RequireTerminated) {
  switch -CaseSensitive ($Reader) {
    'owner' {
      $metrics=$null
      $history=dispatch-ledger-reader\Read-DispatchCountHistory -Path $Path -RequireTerminated:$RequireTerminated -ReadMetrics ([ref]$metrics)
      if($history.complete) {
        Assert-Large ($metrics.readPasses -eq 1 -and $metrics.bytesRead -eq $history.audit.bytes -and
          $metrics.boundaryProbes -eq $(if($history.snapshotLength -gt 0){1}else{0})) 'owner payload reread, incomplete pass or missing LF boundary probe'
        if($history.audit.bytes -gt 33554432){Write-Output "METRICS owner bytesRead=$($metrics.bytesRead) readPasses=$($metrics.readPasses) parsedRows=$($history.audit.parsedRows)" | Write-Host}
      }
      return $history
    }
    'exact-head' { Read-ExactHeadReviewHistory -Path $Path -RequireTerminated:$RequireTerminated }
    'checkpoint' {
      $metrics=$null
      $history=Read-CheckpointedDispatchHistory -Path $Path -RequireTerminated:$RequireTerminated -ReadMetrics ([ref]$metrics)
      if($history.complete -and $history.audit.bytes -gt 33554432){
        Assert-Large ($metrics.readPasses -eq 1 -and $metrics.bytesRead -eq $history.audit.bytes -and
          $metrics.rebuilds -eq [int]($phase -eq 0) -and $metrics.publications -eq 1 -and
          $metrics.tailParsedRows -eq $(if($phase -eq 0){50001}else{1})) 'checkpoint reread, reparsed prefix or failed durable publication'
        Write-Output "METRICS checkpoint bytesRead=$($metrics.bytesRead) passes=$($metrics.readPasses) tailParsedRows=$($metrics.tailParsedRows) rebuilds=$($metrics.rebuilds) publications=$($metrics.publications)" | Write-Host
      }
      return $history
    }
    'query' { Read-DispatchCountHistory -Path $Path -RequireTerminated:$RequireTerminated }
    default { throw 'unknown real reader entrypoint' }
  }
}
try {
  [void][IO.Directory]::CreateDirectory($root)
  $readers=if($CheckpointOnly){@('checkpoint')}else{@('owner','exact-head','query')}
  $issue=908126
  $negativePath=Join-Path $root 'negative.jsonl'
  foreach($reader in $readers) {
    Check-Large "$reader/missing" {
      $history=Read-LargeHistory $reader (Join-Path $root 'missing.jsonl') -RequireTerminated
      Assert-Large (-not $history.complete -and $history.reason -ceq 'HISTORY_MISSING') 'missing history gained authority'
      Assert-Large ((Get-DispatchCountDecision $history $issue open clear).state -ceq 'UNKNOWN') 'missing history gained count authority'
    }
    foreach($raw in @('{broken','{"a":1,"\u0061":2}')) {
      Check-Large "$reader/malformed/$raw" {
        [IO.File]::WriteAllText($negativePath,$raw+"`n",[Text.UTF8Encoding]::new($false))
        $history=Read-LargeHistory $reader $negativePath -RequireTerminated
        Assert-Large (-not $history.complete -and $history.reason -ceq 'HISTORY_MALFORMED' -and
          $history.audit.malformedRows -eq 1 -and $history.audit.malformedLineNumbers[0] -eq 1) 'malformed/duplicate input gained authority'
        Assert-Large ((Get-DispatchCountDecision $history $issue open clear).state -ceq 'UNKNOWN') 'malformed history gained count authority'
      }
    }
    Check-Large "$reader/partial-tail" {
      [IO.File]::WriteAllText($negativePath,"{}`n{`"kind`":`"dispatch`"",[Text.UTF8Encoding]::new($false))
      $strict=Read-LargeHistory $reader $negativePath -RequireTerminated
      Assert-Large (-not $strict.complete -and $strict.reason -ceq 'HISTORY_UNTERMINATED_OR_MOVED') 'strict partial tail gained authority'
      $prefix=Read-LargeHistory $reader $negativePath
      Assert-Large ($prefix.complete -and $prefix.partialTrailingRow -and $prefix.audit.parsedRows -eq 1 -and
        $prefix.rows.Count -eq 1 -and $prefix.rows[0].line -eq 1 -and $prefix.cursor -eq 3) 'non-strict read did not defer partial tail'
      Assert-Large ((Get-DispatchCountDecision $prefix $issue open clear).state -ceq 'UNKNOWN') 'partial history gained count authority'
    }
  }

  $path=Join-Path $root 'dispatch-log.jsonl'
  $dispatchRaw='{"kind":"dispatch","issue":908126,"lane":"synthetic-large"}'
  $paddingRaw='{"padding":"'+('x'*33554432)+'"}'
  $dispatchHash=Get-RawHash $dispatchRaw
  $emptyHash=Get-RawHash '{}'
  $paddingHash=Get-RawHash $paddingRaw
  $writer=[IO.StreamWriter]::new($path,$false,[Text.UTF8Encoding]::new($false),65536)
  try {
    for($i=0;$i -lt 50000;$i++) {
      if($i -lt 14) { $writer.Write($dispatchRaw);$writer.Write("`n") }
      else { $writer.Write("{}`n") }
    }
    $writer.Write($paddingRaw);$writer.Write("`n")
  } finally { $writer.Dispose() }
  $length=(Get-Item -LiteralPath $path).Length
  Assert-Large ($length -gt 33554432) 'fixture did not cross byte cliff'
  Write-Output "FIXTURE bytes=$length LF-complete-rows=50001 dispatches=14 sha256=$((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant())"
  Write-Output "IDENTITY dispatchRawSha256=$dispatchHash emptyRawSha256=$emptyHash paddingRawSha256=$paddingHash"
  $appended=[Collections.Generic.List[string]]::new()
  $priorOwner=$null
  for($phase=0;$phase -le 2;$phase++) {
    if($phase -gt 0) {
      # Exercise the real writer's root-keyed mutex, append opener, durable flush
      # and close. OutFile plus NoBoard confines every effect to this GUID root.
      $raw=& (Join-Path $PSScriptRoot 'log-event.ps1') -Log dispatch -Kind dispatch -Issue $issue `
        -Lane "synthetic-large-$phase" -LaneRole implementation -Transcript "synthetic-large-$phase.jsonl" -OutFile $path -NoBoard
      Assert-Large ($raw -is [string]) 'logger did not return exactly one raw JSON row'
      $appended.Add((Get-RawHash $raw))
      $beforeLength=$length
      $length += [Text.Encoding]::UTF8.GetByteCount($raw+[Environment]::NewLine)
      Assert-Large ((Get-Item -LiteralPath $path).Length -eq $length) 'append length mismatch'
      $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
      try {
        [void]$stream.Seek($beforeLength,[IO.SeekOrigin]::Begin)
        $tail=[byte[]]::new($length-$beforeLength)
        $stream.ReadExactly($tail,0,$tail.Length)
        Assert-Large ([Text.Encoding]::UTF8.GetString($tail) -ceq $raw+[Environment]::NewLine) 'logger append was not persisted byte-for-byte'
      } finally { $stream.Dispose() }
      Write-Output "APPEND transaction=$phase bytes=$length rawSha256=$($appended[-1])"
    }
    $expectedRows=50001+$phase
    $expectedCount=14+$phase
    $expectedState=if($phase -eq 0) {'BELOW_THRESHOLD'} else {'DUE'}
    $snapshotHash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    foreach($reader in $readers) {
      Check-Large "$reader/large/phase-$phase" {
        $history=Read-LargeHistory $reader $path -RequireTerminated
        Write-Output "OBSERVED reader=$reader phase=$phase complete=$($history.complete) reason=$($history.reason) parsedRows=$($history.audit.parsedRows)"
        Assert-Large ($history.complete -and $history.reason -ceq 'HISTORY_COMPLETE') "expected HISTORY_COMPLETE; observed $($history.reason)"
        Assert-Large ($history.audit.parsedRows -eq $expectedRows -and $history.rows.Count -eq $expectedRows -and
          $history.snapshotLines -eq $expectedRows -and -not $history.audit.truncated -and -not $history.partialTrailingRow) 'LF-complete parsedRows/row count mismatch'
        Assert-Large ($history.cursor -eq $length -and $history.snapshotLength -eq $length -and
          $history.snapshotHash -ceq $snapshotHash) 'snapshot length/hash mismatch'
        for($index=0;$index -lt $expectedRows;$index++) {
          $expectedHash=if($index -lt 14) {$dispatchHash} elseif($index -lt 50000) {$emptyHash}
            elseif($index -eq 50000) {$paddingHash} else {$appended[$index-50001]}
          Assert-Large ($history.rows[$index].line -eq $index+1 -and $history.rows[$index].rawSha256 -ceq $expectedHash) "line/rawSha256 discontinuity at row $($index+1)"
        }
        $decision=Get-DispatchCountDecision $history $issue open clear
        Assert-Large ($decision.dispatchCount -eq $expectedCount -and $decision.state -ceq $expectedState -and
          $decision.reason -ceq 'DISPATCH_THRESHOLD' -and $decision.action -ceq $(if($phase -eq 0){'NONE'}else{'CLAIM_DECISION'})) 'count decision lost append continuity'
        if($reader -ceq 'owner') {
          if($null -ne $priorOwner) {
            $foldMetrics=$null
            $fold=dispatch-ledger-reader\Read-DispatchCountHistory -Path $path -PrefixHistory $priorOwner -RequireTerminated -ReadMetrics ([ref]$foldMetrics)
            Assert-Large ($foldMetrics.readPasses -eq 1 -and $foldMetrics.bytesRead -eq $length -and
              $foldMetrics.boundaryProbes -eq 1 -and $foldMetrics.tailParsedRows -eq 1 -and
              $foldMetrics.prefixRows -eq $priorOwner.audit.parsedRows) 'PrefixHistory reread or reparsed immutable prefix'
            Assert-Large ($fold.complete -and $fold.audit.parsedRows -eq $expectedRows -and $fold.rows.Count -eq $expectedRows) 'real PrefixHistory fold refused large append'
            for($index=0;$index -lt $expectedRows;$index++) {
              Assert-Large ($fold.rows[$index].line -eq $history.rows[$index].line -and
                $fold.rows[$index].rawSha256 -ceq $history.rows[$index].rawSha256) "PrefixHistory identity differs at row $($index+1)"
            }
            Assert-Large ((Get-DispatchCountDecision $fold $issue open clear | ConvertTo-Json -Depth 8 -Compress) -ceq
              ($decision | ConvertTo-Json -Depth 8 -Compress)) 'PrefixHistory count decision differs from full read'
          }
          $script:priorOwner=$history
        }
        Write-Output "CONTINUITY reader=$reader phase=$phase rows=$expectedRows dispatchCount=$expectedCount state=$expectedState snapshotSha256=$snapshotHash"
      }
    }
    if($UpperBoundDiagnostic -and $phase -eq 0) {
      # Explicit bounds are a diagnostic upper-bound control only. They never
      # replace or relax the default-cap assertions above, including their RED.
      foreach($reader in @('owner','exact-head')) {
        $timer=[Diagnostics.Stopwatch]::StartNew()
        $diagnostic=$null
        try {
          $diagnostic=if($reader -ceq 'owner') {
            dispatch-ledger-reader\Read-DispatchCountHistory -Path $path -MaxBytes ([long]::MaxValue) -MaxRows ([int]::MaxValue) -RequireTerminated
          } else {
            Read-ExactHeadReviewHistory -Path $path -MaxBytes ([long]::MaxValue) -MaxRows ([int]::MaxValue) -RequireTerminated
          }
          $timer.Stop()
          Write-Output "DIAGNOSTIC explicit-upper-bound reader=$reader readSeconds=$($timer.Elapsed.TotalSeconds.ToString('F3',[Globalization.CultureInfo]::InvariantCulture)) complete=$($diagnostic.complete) reason=$($diagnostic.reason) parsedRows=$($diagnostic.audit.parsedRows) rows=$($diagnostic.rows.Count) NOT_CANDIDATE_PASS"
          Assert-Large ($diagnostic.complete -and $diagnostic.audit.parsedRows -eq 50001 -and $diagnostic.rows.Count -eq 50001) 'upper-bound history incomplete'
          for($index=0;$index -lt 50001;$index++) {
            $expectedHash=if($index -lt 14){$dispatchHash}elseif($index -lt 50000){$emptyHash}else{$paddingHash}
            Assert-Large ($diagnostic.rows[$index].line -eq $index+1 -and $diagnostic.rows[$index].rawSha256 -ceq $expectedHash) "upper-bound line/raw identity mismatch at row $($index+1)"
          }
          Assert-Large ($diagnostic.snapshotHash -ceq $snapshotHash -and $diagnostic.cursor -eq $length) 'upper-bound snapshot identity mismatch'
          $decision=Get-DispatchCountDecision $diagnostic $issue open clear
          Assert-Large ($decision.state -ceq 'BELOW_THRESHOLD' -and $decision.dispatchCount -eq 14) 'upper-bound decision mismatch'
          Write-Output "DIAGNOSTIC explicit-upper-bound reader=$reader identitiesVerified=50001 snapshotSha256=$snapshotHash dispatchCount=14 state=BELOW_THRESHOLD NOT_CANDIDATE_PASS"
        } catch {
          $timer.Stop()
          Write-Output "DIAGNOSTIC explicit-upper-bound reader=$reader elapsedSeconds=$($timer.Elapsed.TotalSeconds) error=$($_.Exception.Message) NOT_CANDIDATE_PASS"
        } finally { $diagnostic=$null }
      }
    }
  }
  if($failures.Count) { throw "FAILED $($failures.Count) checks: $($failures -join '; ')" }
  Write-Output "PASS private large-history readers=$($readers -join ',') identity and two-append count continuity"
} finally {
  $full=[IO.Path]::GetFullPath($root)
  if((Split-Path -Parent $full).TrimEnd('\','/') -cne $temporary.TrimEnd('\','/') -or
      (Split-Path -Leaf $full) -cnotmatch '^dispatch-history-large-[a-f0-9]{32}$') { throw 'unsafe private fixture cleanup' }
  if(Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
  Write-Output "CLEANUP privateGuidRootRemoved=$(-not (Test-Path -LiteralPath $full))"
}
