[CmdletBinding()]
param(
  [Alias('Action')][ValidateSet('Read','Initialize','Take','Lift','Disarm')][string]$HoldAction='Read',
  [Alias('Path')][string]$HoldPath=(Join-Path $PSScriptRoot 'merge-hold-state.json'),
  [Alias('ExpectedRevision')][long]$HoldExpectedRevision=-1,
  [Alias('Reconciled')][switch]$HoldReconciled,
  [Alias('Armed')][switch]$HoldArmed,
  [Alias('ArmedWindowId')][string]$HoldArmedWindowId,
  [string]$HoldId,
  [Alias('Issue')][int]$HoldIssue,
  [Alias('Scope')][ValidateSet('queue','prs')][string]$HoldScope='queue',
  [Alias('Prs')][int[]]$HoldPrs=@(),
  [Alias('ExpiresAt')][datetime]$HoldExpiresAt,
  [Alias('Now')][datetime]$HoldNow=[datetime]::UtcNow
)
$ErrorActionPreference='Stop'

function Test-HoldKeys($Value,[string[]]$Keys) {
  if($null -eq $Value -or $Value -isnot [pscustomobject]){return $false}
  $actual=@($Value.PSObject.Properties.Name)
  return $actual.Count -eq $Keys.Count -and @($actual|Where-Object{$_ -cnotin $Keys}).Count -eq 0
}
function Test-HoldInteger($Value,[long]$Minimum=1) {
  return ($Value -is [int] -or $Value -is [long]) -and $Value -ge $Minimum
}
function Test-HoldInstant($Value) {
  if($Value -isnot [string] -or $Value -cnotmatch '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,7})?Z$'){return $false}
  $parsed=[datetime]::MinValue
  return [datetime]::TryParse($Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed)
}
function Test-HoldIdentity($Value) { return $Value -is [string] -and $Value -cmatch '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,255}$' }
function ConvertTo-HoldUtc($Value) { return ([datetimeoffset]::Parse([string]$Value,[Globalization.CultureInfo]::InvariantCulture)).UtcDateTime }
function ConvertFrom-HoldJson([string]$Raw) {
  # ConvertFrom-Json alone accepts repeated keys. Never normalize ambiguous authority.
  $doc=[System.Text.Json.JsonDocument]::Parse($Raw)
  try {
    function Assert-HoldJson($Element) {
      if($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object){
        $keys=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($p in $Element.EnumerateObject()){if(-not $keys.Add($p.Name)){throw 'DUPLICATE_KEY'};Assert-HoldJson $p.Value}
      } elseif($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array){foreach($v in $Element.EnumerateArray()){Assert-HoldJson $v}}
    }
    Assert-HoldJson $doc.RootElement
  } finally {$doc.Dispose()}
  return ConvertFrom-Json -InputObject $Raw -DateKind String -Depth 64
}
function Test-MergeHoldState($State,[datetime]$Now) {
  try {
  $Now=$Now.ToUniversalTime()
  if(-not (Test-HoldKeys $State @('schema','revision','initializedAt','records')) -or
    $State.schema -cne 'merge-hold-state/v1' -or -not (Test-HoldInteger $State.revision) -or
    -not (Test-HoldInstant $State.initializedAt) -or (ConvertTo-HoldUtc $State.initializedAt) -gt $Now -or $State.records -isnot [array]){return $false}
  $ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  $previous=ConvertTo-HoldUtc $State.initializedAt
  foreach($r in $State.records){
    $keys=@('holdId','scope','issue','armedWindowId','takenAt','expiresAt','releasedAt')
    if($r.PSObject.Properties['scope'] -and $r.scope -ceq 'prs'){$keys+=@('prs')}
    if(-not (Test-HoldKeys $r $keys) -or -not (Test-HoldIdentity $r.holdId) -or -not $ids.Add($r.holdId) -or
      $r.scope -cnotin @('queue','prs') -or -not (Test-HoldInteger $r.issue) -or $r.issue -gt [int]::MaxValue -or
      -not (Test-HoldIdentity $r.armedWindowId) -or -not (Test-HoldInstant $r.takenAt) -or -not (Test-HoldInstant $r.expiresAt)){return $false}
    $take=ConvertTo-HoldUtc $r.takenAt;$expiry=ConvertTo-HoldUtc $r.expiresAt
    if($take -gt $Now -or $take -lt $previous -or $expiry -le $take -or $expiry -gt $take.AddHours(2)){return $false}
    $previous=$take
    if($null -ne $r.releasedAt -and (-not (Test-HoldInstant $r.releasedAt) -or (ConvertTo-HoldUtc $r.releasedAt) -lt $take -or (ConvertTo-HoldUtc $r.releasedAt) -gt $Now)){return $false}
    if($r.scope -ceq 'prs'){
      if($r.prs -isnot [array] -or $r.prs.Count -eq 0 -or @($r.prs|Sort-Object -Unique).Count -ne $r.prs.Count){return $false}
      foreach($p in $r.prs){if(-not (Test-HoldInteger $p) -or $p -gt [int]::MaxValue){return $false}}
    }
  }
  return $true
  } catch { return $false }
}
function Read-MergeHoldState([string]$Path,[datetime]$Now) {
  $Now=$Now.ToUniversalTime()
  try {
    $state=ConvertFrom-HoldJson ([IO.File]::ReadAllText($Path))
    if(-not (Test-MergeHoldState $state $Now)){throw 'MALFORMED'}
    return [pscustomobject]@{status='KNOWN';reason='VALIDATED';state=$state;active=@($state.records|Where-Object{$null -eq $_.releasedAt -and (ConvertTo-HoldUtc $_.takenAt) -le $Now -and $Now -lt (ConvertTo-HoldUtc $_.expiresAt)})}
  } catch {return [pscustomobject]@{status='UNKNOWN';reason='HOLD_STATE_UNVERIFIED';state=$null;active=@()}}
}
function Invoke-WithHoldFileLock([string]$Path,[scriptblock]$Body) {
  $full=[IO.Path]::GetFullPath($Path)
  $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($full.ToLowerInvariant())))
  $mutex=[Threading.Mutex]::new($false,"ChaseSetsHold_$hash")
  $owned=$false
  try {
    try{$owned=$mutex.WaitOne([timespan]::FromSeconds(10))}catch [Threading.AbandonedMutexException]{$owned=$true}
    if(-not $owned){throw 'HOLD_STATE_BUSY'}
    & $Body
  } finally {if($owned){$mutex.ReleaseMutex()};$mutex.Dispose()}
}
function Write-HoldAtomicJson([string]$Path,$Value) {
  $full=[IO.Path]::GetFullPath($Path)
  [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full))|Out-Null
  $temp=$full+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
  try {
    [IO.File]::WriteAllText($temp,($Value|ConvertTo-Json -Depth 64),[Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temp,$full,$true)
  } finally {if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}
function Update-MergeHoldState {
  [CmdletBinding()]param([string]$Path,[string]$Action,[long]$ExpectedRevision,[datetime]$Now=[datetime]::UtcNow,[switch]$Reconciled,[switch]$Armed,[string]$ArmedWindowId,[string]$HoldId,[int]$Issue,[string]$Scope='queue',[int[]]$Prs=@(),[datetime]$ExpiresAt)
  Invoke-WithHoldFileLock $Path {
    if($Action -ceq 'Initialize'){
      if(-not $Reconciled -or $ExpectedRevision -ne 0 -or [IO.File]::Exists($Path)){throw 'HOLD_RECONCILIATION_REQUIRED'}
      $state=[pscustomobject]@{schema='merge-hold-state/v1';revision=1L;initializedAt=$Now.ToUniversalTime().ToString('o');records=@()}
    } else {
      $read=Read-MergeHoldState $Path $Now
      if($read.status -cne 'KNOWN'){throw 'HOLD_STATE_UNVERIFIED'}
      $state=$read.state
      if($ExpectedRevision -ne $state.revision -or $state.revision -eq [long]::MaxValue){throw 'HOLD_REVISION_CONFLICT'}
      switch -CaseSensitive ($Action) {
        Take {
          if(-not $Armed -or -not (Test-HoldIdentity $ArmedWindowId) -or @($state.records|Where-Object holdId -CEQ $HoldId).Count){throw 'HOLD_ARMED_IDENTITY_REQUIRED'}
          if(@($read.active|Where-Object armedWindowId -CNE $ArmedWindowId).Count){throw 'HOLD_PREVIOUS_WINDOW_NOT_DISARMED'}
          $record=[ordered]@{holdId=$HoldId;scope=$Scope;issue=$Issue;armedWindowId=$ArmedWindowId;takenAt=$Now.ToUniversalTime().ToString('o');expiresAt=$ExpiresAt.ToUniversalTime().ToString('o');releasedAt=$null}
          if($Scope -ceq 'prs'){$record.prs=@($Prs)}elseif($Prs.Count){throw 'HOLD_QUEUE_HAS_NO_PR_LIST'}
          $state.records+=@([pscustomobject]$record)
        }
        Lift {
          $matches=@($state.records|Where-Object holdId -CEQ $HoldId)
          if($matches.Count -ne 1 -or $null -ne $matches[0].releasedAt){throw 'HOLD_LIFT_IDENTITY_MISMATCH'}
          $matches[0].releasedAt=$Now.ToUniversalTime().ToString('o')
        }
        Disarm {
          if(-not (Test-HoldIdentity $ArmedWindowId)){throw 'HOLD_WINDOW_REQUIRED'}
          foreach($record in $state.records){if($record.armedWindowId -ceq $ArmedWindowId -and $null -eq $record.releasedAt){$record.releasedAt=$Now.ToUniversalTime().ToString('o')}}
        }
        default {throw 'HOLD_ACTION_UNSUPPORTED'}
      }
      $state.revision++
    }
    if(-not (Test-MergeHoldState $state $Now)){throw 'HOLD_STATE_INVALID'}
    Write-HoldAtomicJson $Path $state
    return $state
  }
}
if($MyInvocation.InvocationName -ne '.'){
  if($HoldAction -ceq 'Read'){Read-MergeHoldState $HoldPath $HoldNow|ConvertTo-Json -Depth 64}
  else {Update-MergeHoldState -Action $HoldAction -Path $HoldPath -ExpectedRevision $HoldExpectedRevision -Now $HoldNow -Reconciled:$HoldReconciled -Armed:$HoldArmed -ArmedWindowId $HoldArmedWindowId -HoldId $HoldId -Issue $HoldIssue -Scope $HoldScope -Prs $HoldPrs -ExpiresAt $HoldExpiresAt|ConvertTo-Json -Depth 64}
}
