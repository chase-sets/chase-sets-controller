[CmdletBinding()]
param(
  [ValidateSet('Library','Plan','Shard','Merge')][string]$Mode = 'Library',
  [string]$ControllerRoot,
  [string]$ProductSha,
  [string]$Items = '',
  [ValidateSet('full','impact')][string]$Scope = 'full',
  [string]$PlanPath,
  [string]$OutputDirectory,
  [ValidateRange(0,9)][int]$Shard = 0
)
$ErrorActionPreference = 'Stop'

function Assert-Ci([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "CONTROLLER_CI: $Message" }
}

function Write-CiJson($Value, [string]$Path) {
  [void][IO.Directory]::CreateDirectory((Split-Path -Parent ([IO.Path]::GetFullPath($Path))))
  [IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 40) + "`n"), [Text.UTF8Encoding]::new($false))
}

function Get-CiHead([string]$Root) {
  $value = @(& git -C $Root rev-parse HEAD 2>&1) -join ''
  Assert-Ci ($LASTEXITCODE -eq 0 -and $value -cmatch '^[a-f0-9]{40}$') 'unreadable checkout head'
  return $value
}

function Get-CiSourceHead([string]$Root, [string]$CheckoutHead) {
  $body = @(& git -C $Root show -s --format=%B $CheckoutHead) -join "`n"
  Assert-Ci ($LASTEXITCODE -eq 0) 'unreadable snapshot trailer'
  $trailers = [regex]::Matches($body, '(?m)^Source-Controller-Head: ([a-f0-9]{40})\s*$')
  Assert-Ci ($trailers.Count -le 1) 'ambiguous source trailer'
  if ($trailers.Count -eq 1) { return $trailers[0].Groups[1].Value }
  return $CheckoutHead
}

function Get-CiRestriction([string]$Identity, [string]$Root) {
  # Exclusions describe host resources, never a failing assertion or timing.
  if ($Identity -ceq 'test:codex-launch-boundary.test.ps1') {
    return @{ classification='LOCAL_ONLY'; reason='Pinned installed Codex native sandbox executable and host boundary profile; model CLI execution prohibited.' }
  }
  if ($Identity -ceq 'test:dispatch-lane.test.ps1') {
    return @{ classification='LOCAL_ONLY'; reason='Installed Claude CLI --help probe, excluded historical fixtures, and native carrier host fleet probe.'; notHermetic=$true }
  }
  if ($Identity -cin @('test:dispatch-ownership.test.ps1','test:rebase-integration.test.ps1',
      'test:lane-stall-watchdog.test.ps1','test:landed-integration-r3.test.ps1')) {
    return @{ classification='LOCAL_ONLY'; reason='Native carrier reads parent host fleet via interrupted-integration-test-support.ps1:45,149,206,533,535; depends on excluded historical commit b3b4ac2.'; notHermetic=$true }
  }
  $history = @{
    'discriminator:issue-6289' = @('50e3695074960ed988996860ff9bf8a45d6b8bea','e396120d26a766e467e0d01052939d6abf945e21')
    'discriminator:issue-6289-bounded-probe' = @('1031c527aeb3705e7738f8d7a18cb7b04dba81f8')
  }
  if ($history.ContainsKey($Identity)) {
    foreach ($head in $history[$Identity]) {
      & git -C $Root cat-file -e "$head`^{commit}" 2>$null
      if ($LASTEXITCODE -ne 0) {
        return @{ classification='LOCAL_ONLY'; reason="Exact historical fixture $head exists only in private container history; not published after secret-scan findings." }
      }
    }
  }
  return $null
}

function New-CiAssignments([object[]]$Inventory, [string]$Selection) {
  $requested = @()
  if (-not [string]::IsNullOrWhiteSpace($Selection)) {
    $requested = @($Selection -split '[,\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    Assert-Ci ($requested.Count -gt 0) 'empty explicit item selection'
    Assert-Ci (@($requested | Select-Object -Unique).Count -eq $requested.Count) 'duplicate requested item'
    foreach ($id in $requested) { Assert-Ci ($id -cin @($Inventory.identity)) "unknown requested item: $id" }
  }
  $selected = @($Inventory | Where-Object { $requested.Count -eq 0 -or $_.identity -cin $requested })
  Assert-Ci ($selected.Count -gt 0) 'empty battery plan'
  Assert-Ci (@($Inventory.identity | Select-Object -Unique).Count -eq $Inventory.Count) 'duplicate inventory identity'
  for ($i=0; $i -lt $selected.Count; $i++) { $selected[$i] | Add-Member -NotePropertyName shard -NotePropertyValue ($i % 10) -Force }
  return ,$selected
}

function Merge-CiResults($Plan, [object[]]$Shards) {
  Assert-Ci ($Shards.Count -eq 10) 'exactly ten shard receipts required'
  $seenShards = [Collections.Generic.HashSet[int]]::new()
  $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  $results = [Collections.Generic.List[object]]::new()
  foreach ($part in $Shards) {
    Assert-Ci ($part.schemaVersion -ceq 'controller-ci-shard/v1') 'shard schema mismatch'
    Assert-Ci ($part.checkoutHead -ceq $Plan.checkoutHead -and $part.controllerHead -ceq $Plan.controllerHead -and
      $part.productSha -ceq $Plan.productSha -and $part.planSha256 -ceq $Plan.planSha256) 'shard identity mismatch'
    Assert-Ci ($part.shard -ge 0 -and $part.shard -lt 10 -and $seenShards.Add([int]$part.shard)) 'duplicate/invalid shard'
    $expected = @($Plan.selected | Where-Object shard -EQ $part.shard)
    Assert-Ci (@($part.results).Count -eq $expected.Count) 'shard cardinality mismatch'
    foreach ($row in $part.results) {
      Assert-Ci ($row.identity -cin @($expected.identity) -and $seen.Add([string]$row.identity)) 'extra/duplicate result'
      Assert-Ci (($row.result -ceq 'PASS' -and $row.exitCode -eq 0) -or
        ($row.result -ceq 'FAIL' -and $row.exitCode -ne 0) -or
        ($row.result -ceq 'LOCAL_ONLY' -and $row.exitCode -eq 125)) 'inconsistent result/exitCode'
      $item = @($expected | Where-Object identity -CEQ $row.identity)[0]
      Assert-Ci (($null -ne $item.restriction) -eq ($row.result -ceq 'LOCAL_ONLY')) 'unauthorized exclusion'
      $results.Add($row)
    }
  }
  Assert-Ci ($seen.Count -eq @($Plan.selected).Count) 'missing item result'
  return ,@($results | Sort-Object identity)
}

if ($Mode -ceq 'Library') { return }
if ($Mode -cin @('Plan','Shard')) {
  Assert-Ci ($env:GITHUB_ACTIONS -ceq 'true' -and $env:RUNNER_ENVIRONMENT -ceq 'github-hosted' -and $IsWindows) 'execution is restricted to fresh GitHub-hosted Windows runners'
  Assert-Ci ([string]::IsNullOrEmpty($env:CHASE_SETS_HEAVY_SLOT_ID)) 'inherited local admission forbidden'
  Assert-Ci ([string]::IsNullOrEmpty($env:CHASE_SETS_BATTERY_IMPACT_PATHS)) 'inherited impact filtering forbidden'
  Assert-Ci ($PSVersionTable.PSVersion.ToString() -ceq '7.6.5') 'PowerShell 7.6.5 required'
  $ControllerRoot = [IO.Path]::GetFullPath($ControllerRoot)
  $checkoutHead = Get-CiHead $ControllerRoot
  $container = Split-Path -Parent $ControllerRoot
  Assert-Ci (-not (Test-Path (Join-Path $container '.orchestrator'))) 'runner contains host runtime state'
  Assert-Ci ($ProductSha -cmatch '^[a-f0-9]{40}$') 'product SHA must be immutable'
  Assert-Ci ((Get-CiHead (Join-Path $container 'main')) -ceq $ProductSha) 'product checkout mismatch'
}
[void][IO.Directory]::CreateDirectory($OutputDirectory)

if ($Mode -ceq 'Plan') {
  # Dot-source the head's own public plan-only entry inside a child scope. This
  # preserves exact argument arrays (including empty arguments) on legacy heads
  # without parsing human PLAN command strings or altering candidate bytes.
  $capture = & {
    param($Root,$Head,$RequestedScope)
    $planLog = @(. (Join-Path $Root '.orchestrator/controller-release-battery.ps1') -ControllerRoot $Root -ExpectedControllerHead $Head -Scope $RequestedScope -ValidatePlanOnly 6>&1)
    Assert-Ci ($null -ne $requiredItems -and $requiredItems.Count -gt 0) 'battery plan-only did not expose its required inventory'
    [pscustomobject]@{ inventory=@($requiredItems); scope=$batteryScope; reason=$scopeReason; log=$planLog; hostIdentity=$hostIdentity }
  } $ControllerRoot $checkoutHead $Scope
  [IO.File]::WriteAllLines((Join-Path $OutputDirectory 'plan.log'), [string[]]@($capture.log | ForEach-Object { "$_" }))
  $inventory = @($capture.inventory | ForEach-Object {
    $item = $_
    [pscustomobject]@{ identity=$item.identity; path=$item.path; command=$item.command
      arguments=@($item.arguments | ForEach-Object { ([string]$_).Replace($ControllerRoot, '{CONTROLLER}') })
      restriction=(Get-CiRestriction $item.identity $ControllerRoot) }
  })
  $selected = New-CiAssignments $inventory $Items
  $plan = [ordered]@{ schemaVersion='controller-ci-plan/v1'; controllerHead=(Get-CiSourceHead $ControllerRoot $checkoutHead)
    checkoutHead=$checkoutHead; productSha=$ProductSha; runnerHead=$env:GITHUB_SHA; inventory=$inventory; selected=$selected
    scope=@{kind=$capture.scope;reason=$capture.reason;baselineHead='';changedCount=0}; hostIdentity=$capture.hostIdentity
    startedUtc=[DateTime]::UtcNow.ToString('o'); requestedScope=$Scope }
  Write-CiJson $plan (Join-Path $OutputDirectory 'plan.json')
  $matrix = @{include=@(0..9 | ForEach-Object { @{shard=$_} })} | ConvertTo-Json -Compress -Depth 5
  Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "matrix=$matrix`ncheckout_head=$checkoutHead"
  Write-Output "PLAN required=$($inventory.Count) selected=$($selected.Count) localOnly=$(@($selected | Where-Object restriction).Count)"
  return
}

$plan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json -Depth 40 -DateKind String
Assert-Ci ($plan.schemaVersion -ceq 'controller-ci-plan/v1') 'plan schema mismatch'
$plan | Add-Member -NotePropertyName planSha256 -NotePropertyValue (Get-FileHash -LiteralPath $PlanPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($Mode -ceq 'Shard') {
  Assert-Ci ($checkoutHead -ceq $plan.checkoutHead -and $ProductSha -ceq $plan.productSha) 'plan checkout mismatch'
  $rows = [Collections.Generic.List[object]]::new()
  $start = [DateTime]::UtcNow
  foreach ($item in @($plan.selected | Where-Object shard -EQ $Shard)) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $started = [DateTime]::UtcNow.ToString('o')
    $logName = ('{0:d3}.log' -f $rows.Count)
    $logPath = Join-Path $OutputDirectory $logName
    if ($null -ne $item.restriction) {
      $exitCode = 125; $result = 'LOCAL_ONLY'
      [IO.File]::WriteAllText($logPath, $item.restriction.reason)
    } else {
      $arguments = @($item.arguments | ForEach-Object { ([string]$_).Replace('{CONTROLLER}', $ControllerRoot) })
      $hostPath = (Get-Process -Id $PID).Path
      Push-Location $ControllerRoot
      try {
        & $hostPath @arguments *> $logPath
        $exitCode = $LASTEXITCODE
      } finally { Pop-Location }
      $result = if ($exitCode -eq 0) { 'PASS' } else { 'FAIL' }
    }
    $clock.Stop()
    $row = [ordered]@{ identity=$item.identity; exitCode=$exitCode; result=$result; fleetLoad='none'
      provenance=@{kind=$(if($result -ceq 'LOCAL_ONLY'){'local-only'}else{'execution'});command=$item.command
        attempt="github-$env:GITHUB_RUN_ID-$env:GITHUB_RUN_ATTEMPT-shard-$Shard"; log=$logName}
      startedUtc=$started; finishedUtc=[DateTime]::UtcNow.ToString('o'); elapsedMs=$clock.ElapsedMilliseconds }
    $rows.Add([pscustomobject]$row)
    Write-Output "RESULT identity=$($row.identity) exitCode=$exitCode result=$result fleetLoad=none startedUtc=$started finishedUtc=$($row.finishedUtc) elapsedMs=$($row.elapsedMs)"
    Write-CiJson @{schemaVersion='controller-ci-shard/v1';controllerHead=$plan.controllerHead;checkoutHead=$checkoutHead
      productSha=$ProductSha;planSha256=$plan.planSha256;shard=$Shard;startedUtc=$start.ToString('o')
      finishedUtc=[DateTime]::UtcNow.ToString('o');elapsedMs=([DateTime]::UtcNow-$start).TotalMilliseconds;results=@($rows)} (Join-Path $OutputDirectory 'shard.json')
  }
  if ($rows.Count -eq 0) {
    Write-CiJson @{schemaVersion='controller-ci-shard/v1';controllerHead=$plan.controllerHead;checkoutHead=$checkoutHead
      productSha=$ProductSha;planSha256=$plan.planSha256;shard=$Shard;startedUtc=$start.ToString('o')
      finishedUtc=[DateTime]::UtcNow.ToString('o');elapsedMs=0;results=@()} (Join-Path $OutputDirectory 'shard.json')
  }
  return
}

$parts = @(Get-ChildItem -LiteralPath $OutputDirectory -Filter shard.json -Recurse -File | ForEach-Object {
  Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -Depth 40 -DateKind String
})
$results = Merge-CiResults $plan $parts
$localOnly = @($plan.selected | Where-Object restriction | ForEach-Object { @{identity=$_.identity;reason=$_.restriction.reason} })
$notHermetic = @($plan.selected | Where-Object { $_.restriction.notHermetic } | ForEach-Object identity)
$notRun = @($plan.inventory | Where-Object { $_.identity -cnotin @($plan.selected.identity) } | ForEach-Object identity)
$outcome = if (@($results | Where-Object result -CEQ 'FAIL').Count) { 'FAIL' }
  elseif ($localOnly.Count -or $notRun.Count) { 'INCOMPLETE_CI' } else { 'PASS' }
$raw = @($results | ForEach-Object { "RESULT identity=$($_.identity) exitCode=$($_.exitCode) result=$($_.result) fleetLoad=none startedUtc=$($_.startedUtc) finishedUtc=$($_.finishedUtc) elapsedMs=$($_.elapsedMs)" }) -join "`n"
$rawPath = Join-Path $OutputDirectory 'controller-ci.log'
[IO.File]::WriteAllText($rawPath,$raw + "`n",[Text.UTF8Encoding]::new($false))
$finished = [DateTime]::UtcNow
$record = [ordered]@{schemaVersion='controller-battery-result/v1';controllerHead=$plan.controllerHead;hostIdentity=$plan.hostIdentity
  fleetLoad='none';scope=$plan.scope;execution=@{mode='github-actions-sharded-file-serial';outcome=$outcome
    startedUtc=$plan.startedUtc;finishedUtc=$finished.ToString('o');elapsedMs=($finished-[DateTime]::Parse($plan.startedUtc).ToUniversalTime()).TotalMilliseconds
    measuredLoadCount=0;requiredCount=@($plan.inventory).Count;executedCount=@($results | Where-Object result -CNE 'LOCAL_ONLY').Count
    reusedCount=0;satisfiedCount=@($results | Where-Object result -CEQ 'PASS').Count;onFailure='all';notRun=$notRun}
  inventory=$plan.inventory;results=$results;rawLog=@{kind='raw-log';relativePath='.orchestrator/artifacts/controller-ci.log'
    byteLength=(Get-Item $rawPath).Length;sha256=(Get-FileHash $rawPath -Algorithm SHA256).Hash.ToLowerInvariant()}
  ci=@{checkoutHead=$plan.checkoutHead;productSha=$plan.productSha;runnerHead=$plan.runnerHead;runId=$env:GITHUB_RUN_ID
    localOnly=$localOnly;notHermetic=$notHermetic;shards=@($parts | Select-Object shard,startedUtc,finishedUtc,elapsedMs)} }
if ($outcome -cne 'PASS') { $record.failureCode="CI_$outcome" }
Write-CiJson $record (Join-Path $OutputDirectory 'final.json')
Write-Output "BATTERY_RESULT outcome=$outcome required=$($plan.inventory.Count) results=$($results.Count) localOnly=$($localOnly.Count)"
if ($outcome -cne 'PASS') { exit 1 }
