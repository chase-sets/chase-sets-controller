[CmdletBinding()]
param([string]$ControllerRoot=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'dispatch-history-callers.psm1') -Force
$root=Join-Path ([IO.Path]::GetTempPath()) ('dispatch-callers-'+[guid]::NewGuid().ToString('N'))
$checks=0
function Check([bool]$Value,[string]$Message){$script:checks++;if(-not $Value){throw "ASSERT: $Message"}}
function Refuses([scriptblock]$Body,[string]$Message){$failed=$false;try{& $Body|Out-Null}catch{$failed=$true};Check $failed $Message}
try {
  [void][IO.Directory]::CreateDirectory($root)
  $source='function Watch {param($Path);dispatch-history-checkpoint\Read-CheckpointedDispatchHistory -Path $Path}'
  [IO.File]::WriteAllText((Join-Path $root 'reader.ps1'),$source)
  [IO.File]::WriteAllText((Join-Path $root 'reader.test.ps1'),$source)
  & git -C $root init -q
  if($LASTEXITCODE){throw 'fixture init failed'}
  & git -C $root add reader.ps1 reader.test.ps1
  if($LASTEXITCODE){throw 'fixture track failed'}
  & git -C $root -c user.name=Synthetic -c user.email=synthetic@example.invalid commit -qm callers
  if($LASTEXITCODE){throw 'fixture commit failed'}
  $manifest=Join-Path $root 'callers.json'
  $row=[ordered]@{path='reader.ps1';scope='Watch';api='read-checkpointeddispatchhistory';ordinal=1
    mode='checkpoint';projection='dispatch-count/v1';peakEnvelope='projection+delta'
    callSha256='c7f838b9b71838bb99fb44ccf619c24891a0d04195973c81f56625d88d61da49'}
  $declaration=[ordered]@{schemaVersion='dispatch-history-callers/v1';rows=@($row)}
  $json=$declaration|ConvertTo-Json -Depth 8
  [IO.File]::WriteAllText($manifest,$json)
  $baseline=Get-DispatchHistoryCallerCensus -Root $root -ManifestPath $manifest
  Check ($baseline.complete -and $baseline.rows.Count -eq 1 -and $baseline.testRows.Count -eq 1 -and $baseline.scanned -eq 2) 'complete tracked production and report-only test inventory'
  Check ($baseline.manifestSha256 -ceq [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($json))).ToLowerInvariant()) 'captured manifest identity accompanies inventory'
  $mutants=[ordered]@{
    extra=($source+';function Extra {Read-DispatchLedgerBytes -Path $Path}')
    oldBound=$source.Replace('-Path $Path','-Path $Path -MaxDeltaBytes 33554432')
    removed=$source.Replace('dispatch-history-checkpoint\Read-CheckpointedDispatchHistory -Path $Path','Write-Output no-read')
    wrongModule=$source.Replace('dispatch-history-checkpoint\','other\')
    changedScope=$source.Replace('function Watch','function Other')
    duplicate=($source+';'+$source)
  }
  foreach($name in $mutants.Keys){
    $c=Get-DispatchHistoryCallerCensus -Root $root -ManifestPath $manifest -SourceOverride @{'reader.ps1'=$mutants[$name]}
    Check (-not $c.complete -and $c.violations.Count -gt 0) "killed caller mutation $name"
    "KILLED caller=$name violations=$($c.violations.Count)"
  }
  $comments=$source.Replace(' -Path '," <# same call`nchanged layout #> -Path ")
  Check (Get-DispatchHistoryCallerCensus -Root $root -ManifestPath $manifest -SourceOverride @{'reader.ps1'=$comments}).complete 'comments and line layout do not change call identity'
  Refuses {Get-DispatchHistoryCallerCensus -Root $root -ManifestPath $manifest -SourceOverride @{'untracked.ps1'=$source}} 'untracked overrides refuse'
  Refuses {Get-DispatchHistoryCallerCensus -Root $root -ManifestPath $manifest -SourceOverride @{'reader.ps1'='function {'}} 'parse failure refuses'
  foreach($bad in @(
      $json.Replace('"checkpoint"','"one-pass-stream"'),
      $json.Replace('"dispatch-count/v1"','"captured-bytes"'),
      $json.Replace('"projection+delta"','"captured-history"'),
      $json.Replace('"ordinal": 1','"ordinal": 0'),
      $json.Replace('"schemaVersion":','"unexpected": true,"schemaVersion":'),
      $json.Replace('"schemaVersion":','"schemaVersion": "duplicate","schemaVersion":'),
      ($declaration|ConvertTo-Json -Depth 8).Replace('"rows": [','"rows": [null,'))) {
    [IO.File]::WriteAllText($manifest,$bad)
    Refuses {Get-DispatchHistoryCallerCensus -Root $root -ManifestPath $manifest} 'malformed or misleading manifest refuses'
  }
  $declaration.rows=@($row,$row)
  [IO.File]::WriteAllText($manifest,($declaration|ConvertTo-Json -Depth 8))
  Refuses {Get-DispatchHistoryCallerCensus -Root $root -ManifestPath $manifest} 'duplicate declaration refuses'
  $real=Get-DispatchHistoryCallerCensus -Root $ControllerRoot
  Check ($real.complete -and $real.rows.Count -gt 0 -and $real.scanned -eq $real.total) 'actual tracked caller manifest matches'
  $watch=@($real.rows|Where-Object path -CEQ '.orchestrator/lane-stall-watchdog.ps1')
  Check ($watch.Count -eq 4 -and @($watch|Where-Object {$_.mode -cne 'checkpoint' -or $_.projection -cne 'dispatch-count/v1' -or $_.peakEnvelope -cne 'projection+delta'}).Count -eq 0) 'all four watchdog checkpoint callers declared'
  "PASS dispatch caller inventory checks=$checks production=$($real.rows.Count) watchdogCheckpoint=$($watch.Count) tests=$($real.testRows.Count); static call coverage, NOT all-row abovecliff qualification"
} finally {
  $full=[IO.Path]::GetFullPath($root)
  if((Split-Path -Parent $full).TrimEnd('\','/') -cne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/') -or (Split-Path -Leaf $full) -cnotlike 'dispatch-callers-*'){throw 'unsafe fixture cleanup'}
  if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}
}
