[CmdletBinding()]param()
$ErrorActionPreference='Stop';$root=Join-Path ([IO.Path]::GetTempPath()) ('board-reconcile-test-'+[guid]::NewGuid().ToString('N'))
function Assert-Board([bool]$c,[string]$m){if(-not$c){throw "ASSERTION FAILED: $m"}}
try{New-Item -ItemType Directory -Path $root|Out-Null
  $gh=Join-Path $root 'gh.ps1';[IO.File]::WriteAllText($gh,@'
if($args[0]-eq'variable'){Write-Output 'PVT_SYNTHETIC';exit 0}
if($args[0]-eq'api'){Write-Output (Get-Content -LiteralPath $env:BOARD_RECONCILE_ITEMS -Raw);exit 0}
exit 1
'@,[Text.UTF8Encoding]::new($false))
  $payload=[ordered]@{data=[ordered]@{node=[ordered]@{items=[ordered]@{pageInfo=[ordered]@{hasNextPage=$false;endCursor=$null};nodes=@([ordered]@{id='PVTI_4388';status=[ordered]@{name='In lane'};content=[ordered]@{number=4388;state='OPEN';closedByPullRequestsReferences=[ordered]@{nodes=@()}}})}}}}
  $items=Join-Path $root 'items.json';[IO.File]::WriteAllText($items,($payload|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false));$env:BOARD_RECONCILE_ITEMS=$items
  $log=Join-Path $root 'dispatch.jsonl';$now=[datetimeoffset]::UtcNow
  [IO.File]::WriteAllText($log,([ordered]@{ts=$now.AddHours(-3).ToString('o');kind='dispatch';issue=4388;lane='lane-a'}|ConvertTo-Json -Compress)+"`n",[Text.UTF8Encoding]::new($false))
  $live=&(Join-Path $PSScriptRoot 'board-reconcile.ps1') -DispatchLog $log -GhCommand $gh|ConvertFrom-Json -DateKind String
  Assert-Board (@($live.findings).Count-eq0-and$live.lifecycleRows-eq1) 'latest dispatch did not preserve active lane state'
  [IO.File]::AppendAllText($log,([ordered]@{ts=$now.AddHours(-2.9).ToString('o');kind='lane-complete';issue=4388;lane='lane-a'}|ConvertTo-Json -Compress)+"`n",[Text.UTF8Encoding]::new($false))
  $terminal=&(Join-Path $PSScriptRoot 'board-reconcile.ps1') -DispatchLog $log -GhCommand $gh|ConvertFrom-Json -DateKind String
  Assert-Board (@($terminal.findings).Count-eq1-and$terminal.findings[0].finding-ceq'stale-lane-state') 'terminal lifecycle row did not release stale board state'
  $missing=&(Join-Path $PSScriptRoot 'board-reconcile.ps1') -DispatchLog (Join-Path $root 'missing.jsonl') -GhCommand $gh|ConvertFrom-Json -DateKind String
  Assert-Board ($missing.findings[0].finding-ceq'insufficient-evidence') 'missing lifecycle history did not fail closed'
  Write-Output 'PASS board reconciliation derives active/dead lane state from lifecycle telemetry and fails closed without it'
}finally{Remove-Item Env:\BOARD_RECONCILE_ITEMS -ErrorAction SilentlyContinue;if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}}
