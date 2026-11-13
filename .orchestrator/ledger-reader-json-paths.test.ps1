$ErrorActionPreference='Stop'
$root=Join-Path ([IO.Path]::GetTempPath()) ('ledger-json-paths-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$script:checks=0
function Check([bool]$Condition,[string]$Message) {
  $script:checks++
  if(-not $Condition){throw "ASSERTION FAILED: $Message"}
}
function Write-Json([string]$Path,$Value) {
  [IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
}
function Invoke-Isolated([string]$Name,[hashtable]$Arguments,[string]$RedirectLeaf='', [string]$RedirectPath='') {
  $worker=[powershell]::Create()
  try {
    [void]$worker.AddScript({
      param($Entry,$Arguments,$RedirectLeaf,$RedirectPath)
      $ErrorActionPreference='Stop'
      $global:aliasReads=0
      # The publisher derives its two paths. Redirect only the selected leaf,
      # never the owner import, to exercise refusal before publication.
      function Join-Path {
        param($Path,$ChildPath)
        if($RedirectLeaf -and $ChildPath -ceq $RedirectLeaf){return $RedirectPath}
        Microsoft.PowerShell.Management\Join-Path -Path $Path -ChildPath $ChildPath
      }
      function Test-Path {
        param($LiteralPath,$PathType='Any')
        if($RedirectPath -and $LiteralPath -ceq $RedirectPath){return $true}
        Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath -PathType $PathType
      }
      function Get-Content {
        param($LiteralPath,[switch]$Raw)
        if($RedirectPath -and $LiteralPath -ceq $RedirectPath){
          $global:aliasReads++
          throw 'UNGUARDED_NATIVE_READ'
        }
        Microsoft.PowerShell.Management\Get-Content -LiteralPath $LiteralPath -Raw:$Raw
      }
      & $Entry @Arguments
    }).AddArgument((Join-Path $PSScriptRoot $Name)).AddArgument($Arguments).AddArgument($RedirectLeaf).AddArgument($RedirectPath)
    $output=@();$failure=''
    try {$output=@($worker.Invoke())}catch{$failure=$_.Exception.Message}
    return [pscustomobject]@{
      output=$output
      errors=$failure+($worker.Streams.Error|Out-String)
      aliasReads=$worker.Runspace.SessionStateProxy.GetVariable('aliasReads')
    }
  } finally {$worker.Dispose()}
}
try {
  $now=[datetime]'2030-01-01T12:00:00Z'
  $hold=[ordered]@{schema='merge-hold-state/v1';revision=1;initializedAt='2030-01-01T12:00:00Z';records=@()}
  $holdPath=Join-Path $root 'merge-hold-state.json'
  Write-Json $holdPath $hold
  $read=Invoke-Isolated 'merge-hold-state.ps1' @{HoldPath=$holdPath;HoldNow=$now}
  Check (-not $read.errors -and ($read.output|ConvertFrom-Json).status -ceq 'KNOWN') 'genuine merge hold validates'

  $pagination=[ordered]@{
    pagination=[ordered]@{schemaVersion='github-pagination/v1';mode='all-pages';complete=$true;truncated=$false;pageCount=1;itemCount=0}
    items=@()
  }
  $rule=[ordered]@{name='synthetic rule';repository='synthetic/fixture';issueNumber=1}
  $request=[ordered]@{
    schemaVersion='premise-freshness-request/v1'
    candidate=[ordered]@{
      decision=[ordered]@{repository='synthetic/fixture';issueNumber=2;filingInstant='2030-01-01T12:01:00Z'}
      analysisInstant='2030-01-01T12:00:00Z';premiseRules=@($rule)
    }
    authority=@([ordered]@{
      schemaVersion='premise-freshness-authority/v1';available=$true
      repository=[ordered]@{nameWithOwner='synthetic/fixture'}
      repositoryOwner=[ordered]@{login='synthetic'};premiseRule=$rule
      issue=[ordered]@{number=1;html_url='https://example.invalid/issue/1'}
      comments=$pagination;bodyEdits=$pagination;supersedingDecisions=$pagination
    })
  }
  $requestPath=Join-Path $root 'request.json'
  Write-Json $requestPath $request
  $read=Invoke-Isolated 'premise-freshness.ps1' @{RequestPath=$requestPath}
  Check (-not $read.errors -and ($read.output|ConvertFrom-Json).verdict -ceq 'adopt') 'genuine premise request adopts'

  $fixture=[ordered]@{schema='review-queue-health-fixture/v1';scenarios=[ordered]@{
    synthetic=[ordered]@{complete=$true;reason='GITHUB_QUEUE_COMPLETE';prs=@()}
  }}
  $fixturePath=Join-Path $root 'authority.json'
  Write-Json $fixturePath $fixture
  $history=Join-Path $root 'dispatch-log.jsonl'
  [IO.File]::WriteAllText($history,'')
  $queueArgs=@{AuthorityFixture=$fixturePath;AuthorityScenario='synthetic';HistoryPath=$history;SkipRemoteProbes=$true}
  $read=Invoke-Isolated 'review-queue-health.ps1' $queueArgs
  Check (-not $read.errors -and ($read.output|ConvertFrom-Json).status -ceq 'healthy') 'genuine queue fixture validates without remote probes'

  $spec=[ordered]@{label='synthetic';attemptId='synthetic-attempt';launchId=[guid]::NewGuid().ToString();worktree='synthetic';branch='synthetic';head=('a'*40)}
  $specLeaf='watchdog-lane-synthetic.json';$oldLeaf='watchdog-host-hold-synthetic.json'
  Write-Json (Join-Path $root $specLeaf) $spec
  $publisherArgs=@{State='HELD';RuntimeRoot=$root;Label='synthetic'}
  $read=Invoke-Isolated 'watchdog-host-hold.ps1' $publisherArgs
  Check (-not $read.errors -and ($read.output|ConvertFrom-Json).state -ceq 'HELD') 'genuine watchdog spec publishes hold'
  $publisherArgs.State='RELEASED'
  $read=Invoke-Isolated 'watchdog-host-hold.ps1' $publisherArgs
  Check (-not $read.errors -and ($read.output|ConvertFrom-Json).state -ceq 'RELEASED') 'genuine watchdog previous hold releases'

  $dispatch=Join-Path $root 'dispatch-log.jsonl'
  $aliases=@($dispatch,(Join-Path $root 'DISPATCH-LOG.JSONL'),(Join-Path $root './dispatch-log.jsonl'),
    (Join-Path $root 'dispatch-log.jsonl.'),(Join-Path $root 'dispatch-log.jsonl '),(Join-Path $root 'dispatch-log.jsonl:synthetic'))
  foreach($alias in $aliases){
    # Valid payloads make an unguarded read observable, not a coincidental JSON refusal.
    Write-Json $alias $hold
    Check (([IO.File]::ReadAllText($alias)|ConvertFrom-Json).schema -ceq 'merge-hold-state/v1') "merge alias contains readable valid authority: $alias"
    $read=Invoke-Isolated 'merge-hold-state.ps1' @{HoldPath=$alias;HoldNow=$now}
    $result=$read.output|ConvertFrom-Json
    Check (-not $read.errors -and $result.status -ceq 'UNKNOWN' -and $result.reason -ceq 'HOLD_STATE_UNVERIFIED') "merge hold dispatch alias refuses: $alias"

    Write-Json $dispatch $request
    $read=Invoke-Isolated 'premise-freshness.ps1' @{RequestPath=$alias} '' $alias
    $result=$read.output|ConvertFrom-Json
    Check (-not $read.errors -and $result.verdict -ceq 'refuse' -and $result.reason -ceq 'REQUEST_MALFORMED' -and $read.aliasReads -eq 0) "premise dispatch alias refuses before native read: $alias"

    Write-Json $dispatch $fixture
    $badQueue=$queueArgs.Clone();$badQueue.AuthorityFixture=$alias
    $read=Invoke-Isolated 'review-queue-health.ps1' $badQueue '' $alias
    Check ($read.errors -match 'review-queue fixture is missing or malformed' -and $read.aliasReads -eq 0) "queue dispatch alias preserves fixture error before native read: $alias"

    foreach($leaf in @($specLeaf,$oldLeaf)){
      $read=Invoke-Isolated 'watchdog-host-hold.ps1' $publisherArgs $leaf $alias
      Check ($read.errors -match 'DISPATCH_LEDGER_OWNER_REQUIRED' -and $read.aliasReads -eq 0) "watchdog $leaf dispatch alias refuses before native read: $alias"
    }
  }
  Write-Output "PASS ledger-reader-json-paths checks=$script:checks"
} finally {
  $resolved=[IO.Path]::GetFullPath($root)
  if((Split-Path -Parent $resolved).TrimEnd('\','/') -cne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/') -or
    (Split-Path -Leaf $resolved) -notlike 'ledger-json-paths-*'){throw 'unsafe JSON path fixture cleanup'}
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
