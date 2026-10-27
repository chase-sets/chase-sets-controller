[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateSet('HELD','RELEASED')][string]$State,
  [Parameter(Mandatory)][string]$RuntimeRoot,
  [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$')][string]$Label
)
$ErrorActionPreference='Stop'
$runtime=[IO.Path]::GetFullPath($RuntimeRoot).TrimEnd('\','/')
$specPath=Join-Path $runtime "watchdog-lane-$Label.json"
$holdPath=Join-Path $runtime "watchdog-host-hold-$Label.json"
if(-not(Test-Path -LiteralPath $specPath -PathType Leaf)){throw 'WATCHDOG_HOST_HOLD_SPEC_MISSING'}
$spec=Get-Content -LiteralPath $specPath -Raw|ConvertFrom-Json -DateKind String -ErrorAction Stop
$required=@('label','attemptId','launchId','worktree','branch','head')
foreach($key in $required){if($null -eq $spec.PSObject.Properties[$key]-or[string]::IsNullOrWhiteSpace([string]$spec.$key)){throw 'WATCHDOG_HOST_HOLD_SPEC_UNKNOWN'}}
if([string]$spec.label-cne$Label-or[string]$spec.launchId-cnotmatch'^[a-f0-9-]{36}$'-or[string]$spec.head-cnotmatch'^[a-f0-9]{40}$'){throw 'WATCHDOG_HOST_HOLD_SPEC_UNKNOWN'}
$holdId=[guid]::NewGuid().ToString()
if($State-ceq'RELEASED'){
  if(-not(Test-Path -LiteralPath $holdPath -PathType Leaf)){throw 'WATCHDOG_HOST_HOLD_RELEASE_WITHOUT_HOLD'}
  $old=Get-Content -LiteralPath $holdPath -Raw|ConvertFrom-Json -DateKind String -ErrorAction Stop
  if($old.schemaVersion-cne'watchdog-host-hold/v1'-or$old.state-cne'HELD'-or$old.label-cne$Label-or$old.attemptId-cne[string]$spec.attemptId-or$old.launchId-cne[string]$spec.launchId-or$old.holdId-cnotmatch'^[a-f0-9-]{36}$'){throw 'WATCHDOG_HOST_HOLD_RELEASE_UNKNOWN'}
  $holdId=[string]$old.holdId
}
$record=[ordered]@{schemaVersion='watchdog-host-hold/v1';authority='host';state=$State;holdId=$holdId;label=$Label;attemptId=[string]$spec.attemptId;launchId=[string]$spec.launchId;worktree=[string]$spec.worktree;branch=[string]$spec.branch;head=[string]$spec.head;recordedAt=[datetimeoffset]::UtcNow.ToString('o')}
$temporary="$holdPath.$([guid]::NewGuid().ToString('N')).tmp"
[IO.File]::WriteAllText($temporary,($record|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
try{[IO.File]::Move($temporary,$holdPath,$true)}finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue}}
Write-Output ($record|ConvertTo-Json -Compress)
