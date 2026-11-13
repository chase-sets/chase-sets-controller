# Runtime-only support for explicit historical dispatch decision reconciliation.
[CmdletBinding()]
param(
  [object]$DispatchIssue,
  [ValidateSet('open','closed','tracking-only','not-candidate','unknown')]
  [string]$DispatchCandidateState = 'unknown',
  [ValidateSet('clear','terminal-park','attempt-ceiling','counsel','operator','todd','unknown')]
  [string]$DispatchAuthority = 'unknown',
  [string]$DispatchLogPath,
  [string]$RuntimeRoot = $PSScriptRoot,
  [Parameter(DontShow)][switch]$Library
)
$ErrorActionPreference = 'Stop'

function Test-DispatchCountInteger($Value) {
  return ($Value -is [int] -or $Value -is [long]) -and $Value -gt 0 -and $Value -le [int]::MaxValue
}

function Get-DispatchCountDecision($History, $Issue, [string]$CandidateState, [string]$Authority) {
  $result = [ordered]@{schemaVersion='dispatch-count-query/v1';issue=$Issue;state='UNKNOWN';action='NONE'
    reason='HISTORY_INVALID';dispatchCount=$null;decision=$null;finalReceiptIdentity=$null;applicationId=$null;requiresOrdinaryAdmission=$true}
  if (-not (Test-DispatchCountInteger $Issue) -or $History.complete -isnot [bool] -or -not $History.complete) {
    return [pscustomobject]$result
  }
  $count=0; $landed=$false; $decision=$null; $finalIdentity=$null
  $dispatches=@{}
  $decisionDispatchCount=0
  foreach ($entry in $History.rows) {
    $row=$entry.value
    if ($null -eq $row -or $row -isnot [pscustomobject] -or
        ($entry.raw -is [string] -and -not $entry.raw.TrimStart().StartsWith('{'))) { return [pscustomobject]$result }
    $hasDecision=$null -ne $row.PSObject.Properties['dispatchDecision']
    if ($null -eq $row.PSObject.Properties['kind'] -and -not $hasDecision) { continue }
    if ($row.kind -isnot [string]) { return [pscustomobject]$result }
    if ($row.kind -cnotin @('dispatch','landed') -and -not $hasDecision) { continue }
    $hasIssue=$null -ne $row.PSObject.Properties['issue']
    if (-not $hasDecision -and ($row.issue -is [int] -or $row.issue -is [long]) -and $row.issue -lt 1) { continue }
    if (($hasIssue -and -not (Test-DispatchCountInteger $row.issue)) -or ($hasDecision -and -not $hasIssue)) {
      return [pscustomobject]$result
    }
    if (-not $hasIssue -or $row.issue -ne $Issue) { continue }
    if ($row.kind -ceq 'dispatch') {
      $count++; $dispatches[$entry.rawSha256]=$row
      if ($null -ne $decision -and $row.lane -ceq $decision.lane -and $row.transcript -ceq $decision.transcript) {
        $decisionDispatchCount++
        if ($decisionDispatchCount -gt 1) { return [pscustomobject]$result }
      }
    }
    if ($row.kind -ceq 'landed') {
      if (-not (Test-DispatchCountInteger $row.pr) -or $row.head -isnot [string] -or $row.head -cnotmatch '^[a-f0-9]{40}$') {
        return [pscustomobject]$result
      }
      $landed=$true
    }
    if (-not $hasDecision) { continue }
    $d=$row.dispatchDecision
    if ($d -isnot [pscustomobject]) { return [pscustomobject]$result }
    # FINAL dispositions are step-back verdicts (4388/6022146271); PARK is refused.
    $fields=@('schemaVersion','id','phase','count','lane','transcript')
    if ($d.phase -cne 'CLAIMED') { $fields+='dispatchReceiptIdentity' }
    if ($d.phase -cin @('FINAL','APPLYING','APPLIED')) { $fields+='disposition' }
    if ($d.phase -cin @('APPLYING','APPLIED')) { $fields+='finalReceiptIdentity' }
    $names=@($d.PSObject.Properties.Name)
    if (@($fields | Where-Object { $_ -cnotin $names }).Count -or @($names | Where-Object { $_ -cnotin $fields }).Count -or
        $d.schemaVersion -cne 'dispatch-count-decision/v1' -or $d.id -cne "dispatch-count-$Issue-v1" -or
        $d.phase -cnotin @('CLAIMED','ACKNOWLEDGED','FINAL','APPLYING','APPLIED') -or
        -not (Test-DispatchCountInteger $d.count) -or $d.count -lt 15 -or
        $d.lane -isnot [string] -or $d.lane -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$' -or
        $d.transcript -isnot [string] -or $d.transcript -cnotmatch '^[^\r\n]{1,1024}$') { return [pscustomobject]$result }
    $expectedKind=if ($d.phase -cin @('CLAIMED','ACKNOWLEDGED')) {'decision-filed'} else {'decision-resolved'}
    if ($row.kind -cne $expectedKind) { return [pscustomobject]$result }
    if ($d.phase -ceq 'CLAIMED') {
      if ($null -ne $decision -or $landed -or $d.count -ne $count) { return [pscustomobject]$result }
      $dispatches=@{}
    } else {
      if ($null -eq $decision -or $d.id -cne $decision.id -or $d.count -ne $decision.count -or
          $d.lane -cne $decision.lane -or $d.transcript -cne $decision.transcript) { return [pscustomobject]$result }
      $previous=@{ACKNOWLEDGED='CLAIMED';FINAL='ACKNOWLEDGED';APPLYING='FINAL';APPLIED='APPLYING'}
      if ($decision.phase -cne $previous[$d.phase]) { return [pscustomobject]$result }
      if ($d.dispatchReceiptIdentity -isnot [string] -or $d.dispatchReceiptIdentity -cnotmatch '^[a-f0-9]{64}$') { return [pscustomobject]$result }
      $dispatch=$dispatches[$d.dispatchReceiptIdentity]
      if ($decisionDispatchCount -ne 1 -or $null -eq $dispatch -or $dispatch.lane -cne $d.lane -or $dispatch.transcript -cne $d.transcript -or
          $dispatch.laneRole -cnotin @('planning','review','decision')) { return [pscustomobject]$result }
      if ($d.phase -cne 'ACKNOWLEDGED' -and $d.dispatchReceiptIdentity -cne $decision.dispatchReceiptIdentity) { return [pscustomobject]$result }
      if ($d.phase -cin @('FINAL','APPLYING','APPLIED') -and $d.disposition -cnotin @('CONTINUE','REPLAN','WAIT','PRODUCT_QUESTION','RECOMMEND_NOT_COMPLETING')) { return [pscustomobject]$result }
      if ($d.phase -cin @('APPLYING','APPLIED') -and
          ($d.disposition -cne $decision.disposition -or $d.finalReceiptIdentity -cne $finalIdentity)) { return [pscustomobject]$result }
    }
    $decision=$d
    if ($d.phase -ceq 'FINAL') { $finalIdentity=$entry.rawSha256 }
  }
  $result.dispatchCount=$count; $result.decision=$decision; $result.finalReceiptIdentity=$finalIdentity
  if ($null -ne $decision -and $decision.phase -cin @('FINAL','APPLYING','APPLIED')) {
    $result.applicationId="$($decision.id)-$($decision.disposition.ToLowerInvariant())"
  }
  if ($CandidateState -cin @('closed','tracking-only','not-candidate')) {
    $result.state='INELIGIBLE'; $result.reason='NOT_PRE_DISPATCH_CANDIDATE'
  } elseif ($CandidateState -cne 'open' -or $Authority -ceq 'unknown') {
    $result.reason='ADMISSION_UNKNOWN'
  } elseif ($Authority -cne 'clear') {
    $result.state='AUTHORITY_HOLD'; $result.reason=$Authority
  } elseif ($landed) {
    $result.state='LANDED'; $result.reason='CANONICAL_LANDING'
  } elseif ($null -ne $decision) {
    $result.reason='EXISTING_DECISION'
    switch -CaseSensitive ($decision.phase) {
      { $_ -cin @('CLAIMED','ACKNOWLEDGED') } { $result.state='PENDING'; $result.action='RECONCILE_DECISION' }
      'FINAL' { $result.state='FINAL'; $result.action='CLAIM_APPLICATION' }
      'APPLYING' { $result.state='APPLYING'; $result.action='RECONCILE_APPLICATION' }
      'APPLIED' { $result.state='APPLIED' }
    }
  } elseif ($count -ge 15) {
    $result.state='DUE'; $result.action='CLAIM_DECISION'; $result.reason='DISPATCH_THRESHOLD'
  } else {
    $result.state='BELOW_THRESHOLD'; $result.reason='DISPATCH_THRESHOLD'
  }
  return [pscustomobject]$result
}

function Read-DispatchCountHistory([string]$Path, $PrefixHistory = $null) {
  $failure=[pscustomobject]@{complete=$false;rows=@();audit=@{bytes=0};reason='HISTORY_UNREADABLE'}
  $snapshot=$null
  try {
    if ($null -ne $PrefixHistory -and -not $PrefixHistory.complete) { return $PrefixHistory }
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    try {
      $length=$stream.Length
      $failure.audit.bytes=$length
      if ($length -gt 33554432) { $failure.reason='HISTORY_TRUNCATED'; return $failure }
      $prefixLength=if ($null -ne $PrefixHistory) { [long]$PrefixHistory.snapshotLength } else { 0L }
      $failure.reason='HISTORY_UNTERMINATED_OR_MOVED'
      if ($length -lt $prefixLength) { return $failure }
      $bytes=[byte[]]::new($length)
      $stream.ReadExactly($bytes,0,$bytes.Length)
      if ($stream.Length -lt $length -or ($length -gt 0 -and $bytes[-1] -ne 10)) { return $failure }
      # Appends after captured EOF are harmless; a short read or changed boundary is not.
      if ($length -gt 0) {
        [void]$stream.Seek($length-1,[IO.SeekOrigin]::Begin)
        if ($stream.ReadByte() -ne 10) { return $failure }
      }
    } finally { $stream.Dispose() }
    $hash=[Security.Cryptography.SHA256]::Create()
    try {
      if ($null -ne $PrefixHistory) {
        $prefixHash=[Convert]::ToHexString($hash.ComputeHash($bytes,0,$prefixLength)).ToLowerInvariant()
        if ($prefixHash -cne $PrefixHistory.snapshotHash -or ($prefixLength -gt 0 -and $bytes[$prefixLength-1] -ne 10)) { return $failure }
      }
      $snapshotHash=[Convert]::ToHexString($hash.ComputeHash($bytes)).ToLowerInvariant()
    } finally { $hash.Dispose() }
    # The shared strict parser still owns malformed/duplicate JSON and row caps.
    # Only the tail is parsed while the logger holds the append mutex.
    $snapshot=[IO.Path]::GetTempFileName()
    $copy=[IO.File]::OpenWrite($snapshot)
    try { $copy.Write($bytes,$prefixLength,$bytes.Length-$prefixLength) } finally { $copy.Dispose() }
    $prefixLines=if ($null -ne $PrefixHistory) { $PrefixHistory.snapshotLines } else { 0 }
    $tailLines=[IO.File]::ReadAllLines($snapshot).Length
    if ($prefixLines+$tailLines -gt 50000) { $failure.reason='HISTORY_TRUNCATED'; return $failure }
    $history=Read-ExactHeadReviewHistory -Path $snapshot
    if (-not $history.complete) { return $history }
    if ($null -ne $PrefixHistory) {
      foreach ($row in $history.rows) { $row.line+=$prefixLines }
      $history.rows=@($PrefixHistory.rows)+@($history.rows)
      $history.audit.rows+=$PrefixHistory.audit.rows
      $history.audit.parsedRows+=$PrefixHistory.audit.parsedRows
    }
    $history.audit.bytes=$length
    $history | Add-Member snapshotLength $length
    $history | Add-Member snapshotLines ($prefixLines+$tailLines)
    $history | Add-Member snapshotHash $snapshotHash
    return $history
  } catch { return $failure }
  finally { if ($null -ne $snapshot) { [IO.File]::Delete($snapshot) } }
}

if ($Library) { return }
if (-not $PSBoundParameters.ContainsKey('DispatchIssue')) { throw 'DispatchIssue is required' }
if ($DispatchIssue -is [string] -and $DispatchIssue -cmatch '^[1-9][0-9]{0,9}$') {
  $DispatchIssue=[long]$DispatchIssue
}
Import-Module (Join-Path $RuntimeRoot 'review-head-contract.psm1') -Force -DisableNameChecking
$path=if ($DispatchLogPath) {$DispatchLogPath} else {Join-Path $RuntimeRoot 'dispatch-log.jsonl'}
$history=Read-DispatchCountHistory $path
Get-DispatchCountDecision $history $DispatchIssue $DispatchCandidateState $DispatchAuthority | ConvertTo-Json -Depth 6
