[CmdletBinding()]param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'merge-hold-state.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('synthetic-hold-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
$path=Join-Path $root 'merge-hold-state.json'
$now=[datetime]'2030-01-01T12:00:00Z'
$script:assertions=0
function Check([bool]$Value,[string]$Name) { $script:assertions++;if(-not $Value){throw "ASSERTION FAILED: held-authority-boundaries/$Name"} }
function Refused([scriptblock]$Body,[string]$Name) { $threw=$false;try{& $Body|Out-Null}catch{$threw=$true};Check $threw $Name }
try {
  Check ((Read-MergeHoldState $path $now).status -ceq 'UNKNOWN') 'missing is unknown'
  Refused { Update-MergeHoldState -Path $path -Action Initialize -Now $now -ExpectedRevision 0 } 'initialization needs reconciliation'
  $s=Update-MergeHoldState -Path $path -Action Initialize -Now $now -ExpectedRevision 0 -Reconciled
  Check ($s.revision -eq 1 -and (Read-MergeHoldState $path $now).status -ceq 'KNOWN') 'initialized empty'
  $take=@{Path=$path;Action='Take';Now=$now;ExpectedRevision=1;ArmedWindowId='synthetic-window';HoldId='synthetic-hold-1';Issue=908526;Scope='queue';ExpiresAt=$now.AddHours(2);Armed=$true}
  $s=Update-MergeHoldState @take
  Check ($s.revision -eq 2 -and (Read-MergeHoldState $path $now).active.Count -eq 1) 'take'
  Refused { Update-MergeHoldState @take } 'stale revision'
  $bad=$take.Clone();$bad.ExpectedRevision=2;$bad.HoldId='synthetic-hold-2';$bad.ExpiresAt=$now.AddHours(2).AddSeconds(1)
  Refused { Update-MergeHoldState @bad } 'two-hour ceiling'
  $bad.ExpiresAt=$now.AddHours(1);$bad.Armed=$false
  Refused { Update-MergeHoldState @bad } 'unarmed'
  $s=Update-MergeHoldState -Path $path -Action Disarm -Now $now.AddMinutes(2) -ExpectedRevision 2 -ArmedWindowId synthetic-window
  Check ($s.records[0].releasedAt -ne $null -and (Read-MergeHoldState $path $now.AddMinutes(2)).active.Count -eq 0) 'disarm releases'
  $take.ExpectedRevision=3;$take.Now=$now.AddMinutes(3);$take.HoldId='synthetic-hold-2';$take.ArmedWindowId='synthetic-window-2'
  $s=Update-MergeHoldState @take
  Refused { Update-MergeHoldState -Path $path -Action Lift -Now $now.AddMinutes(4) -ExpectedRevision 3 -HoldId synthetic-hold-1 } 'stale lift cannot clear rearm'
  Check ((Read-MergeHoldState $path $now.AddMinutes(4)).active[0].holdId -ceq 'synthetic-hold-2') 'rearm retained'
  $before=[IO.File]::ReadAllText($path)
  Check ((Read-MergeHoldState $path $now.AddDays(1)).active.Count -eq 0) 'day-after inert'
  Check ([IO.File]::ReadAllText($path) -ceq $before) 'expiry never lifts or writes'
  $valid=$before|ConvertFrom-Json -DateKind String
  foreach($case in @('empty','extra','duplicate','future','duration','scope','partial','revision','release-order','init-order','prs')) {
    $v=$before|ConvertFrom-Json -DateKind String
    switch($case) {
      empty {$v=[pscustomobject]@{}}
      extra {$v.records[0]|Add-Member extra $true}
      duplicate {$v.records+=@($v.records[0])}
      future {$v.records[1].takenAt='2031-01-01T12:00:00Z'}
      duration {$v.records[1].expiresAt='2030-01-02T12:00:00Z'}
      scope {$v.records[1].scope='all'}
      partial {$v.records[1].PSObject.Properties.Remove('releasedAt')}
      revision {$v.revision=0}
      'release-order' {$v.records[0].releasedAt='2029-01-01T12:00:00Z'}
      'init-order' {$v.initializedAt='2030-01-01T12:01:00Z'}
      prs {$v.records[1].scope='prs';$v.records[1]|Add-Member prs @(0)}
    }
    [IO.File]::WriteAllText($path,($v|ConvertTo-Json -Depth 20))
    Check ((Read-MergeHoldState $path $now.AddMinutes(4)).status -ceq 'UNKNOWN') $case
  }
  [IO.File]::WriteAllText($path,$before)
  $s=Update-MergeHoldState -Path $path -Action Lift -ExpectedRevision 4 -Now $now.AddMinutes(4) -HoldId synthetic-hold-2
  Check ($s.records[1].takenAt -ceq $valid.records[1].takenAt -and $s.records[1].expiresAt -ceq $valid.records[1].expiresAt) 'lift retains times'
  $workers=@();$handles=@()
  try {
    foreach($id in @('synthetic-race-a','synthetic-race-b')){
      $worker=[powershell]::Create()
      [void]$worker.AddScript({param($source,$path,$id,$instant)
        . $source
        try {Update-MergeHoldState -Path $path -Action Take -ExpectedRevision 5 -Now $instant -Armed -ArmedWindowId synthetic-race -HoldId $id -Issue 908526 -Scope prs -Prs @(908527) -ExpiresAt $instant.AddHours(1)|Out-Null;'won'}catch{$_.Exception.Message}
      }).AddArgument((Join-Path $PSScriptRoot 'merge-hold-state.ps1')).AddArgument($path).AddArgument($id).AddArgument($now.AddMinutes(5))
      $workers+=@($worker);$handles+=@($worker.BeginInvoke())
    }
    $results=@(for($i=0;$i -lt $workers.Count;$i++){$workers[$i].EndInvoke($handles[$i])})
    Check (@($results|Where-Object{$_ -ceq 'won'}).Count -eq 1 -and @($results|Where-Object{$_ -ceq 'HOLD_REVISION_CONFLICT'}).Count -eq 1) 'serialized concurrent takes have exactly one winner'
    Check ((Read-MergeHoldState $path $now.AddMinutes(5)).state.revision -eq 6) 'race increments revision exactly once'
  } finally {foreach($worker in $workers){$worker.Dispose()}}
  Refused {Update-MergeHoldState -Path $path -Action Take -ExpectedRevision 6 -Now $now.AddMinutes(6) -Armed -ArmedWindowId synthetic-next -HoldId synthetic-next -Issue 908526 -ExpiresAt $now.AddHours(1)} 'different active window requires disarm'
  $duplicate=$before.Replace('"revision": 4','"revision": 4, "revision": 4')
  [IO.File]::WriteAllText($path,$duplicate)
  Check ((Read-MergeHoldState $path $now.AddMinutes(5)).status -ceq 'UNKNOWN') 'duplicate JSON keys fail closed'
  Write-Output "PASS merge-hold-state synthetic assertions=$script:assertions"
} finally {
  if([IO.Path]::GetFullPath($root).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $root -Recurse -Force}
}
